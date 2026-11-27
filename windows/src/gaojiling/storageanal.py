"""存储分析只读元数据。不读取文件内容，不跟随符号链接，不跨卷，不提供删除。

排除目录只影响这一次分析。分配空间不是可释放空间。未完成扫描不能拿来和完整扫描比增减。
"""

from __future__ import annotations

import hashlib
import os
import stat
import time
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import allocation, blocked, checked_stat, directory_entries, local_path

DOCUMENT_EXTENSIONS = {
    "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "pdf", "xls", "xlsx", "ods",
    "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "tex", "bib",
}


def dev_targets(home: Path, system: str) -> tuple[list[dict], list[str]]:
    home = Path(home)
    local = home / "AppData" / "Local"
    roaming = home / "AppData" / "Roaming"
    if system == "darwin":
        pairs = [
            ("Xcode", home / "Library" / "Developer" / "Xcode"),
            ("Node.js", home / ".npm"),
            ("Python", home / "Library" / "Caches" / "pip"),
            ("Gradle", home / ".gradle"),
            ("Maven", home / ".m2"),
            ("Android", home / "Library" / "Android"),
            ("Homebrew", home / "Library" / "Caches" / "Homebrew"),
            ("编辑器", home / "Library" / "Application Support" / "Code"),
        ]
    else:
        pairs = [
            ("Node.js", local / "npm-cache"),
            ("Node.js", roaming / "npm"),
            ("Python", local / "pip"),
            ("Poetry", local / "pypoetry"),
            ("Gradle", home / ".gradle"),
            ("Maven", home / ".m2"),
            ("Android", local / "Android"),
            ("编辑器", roaming / "Code"),
        ]
    docker = local / "Docker" if system != "darwin" else home / "Library" / "Containers" / "com.docker.docker"
    notes = []
    targets = [{"label": label, "path": path, "descend": True} for label, path in pairs]
    targets.append({"label": "Docker", "path": docker, "descend": False})
    notes.append("Docker 虚拟机目录不进入。已安装环境、模型和虚拟磁盘只展示占用，不当作垃圾，也不会删除。")
    if system != "darwin":
        notes.append("Windows 没有 Xcode 与 Homebrew 目录，这两项不列出。")
    return targets, notes


def _suggestion(path: Path, logical: int) -> str:
    name = path.name.lower()
    if name in {"node_modules", "caches", "cache", "_cacache"} or "cache" in name:
        return "缓存目录。这里只给出查看建议，不能在存储分析里删除。"
    if logical >= 100 * 1024 * 1024:
        return "较大的本地文件。分配空间可能与磁盘容量口径不同，不能累加为可释放空间。"
    return "仅供查看。"


def analyze(scope: Path, exclusions: list[str] | None = None, budget: dict | None = None,
            cancelled=lambda: False, clock=None) -> dict:
    root = local_path(scope)
    root_info = checked_stat(root)
    if not stat.S_ISDIR(root_info.st_mode):
        raise AppError("请选择一个本机普通目录。")
    limits = {"entries": 100_000, "depth": 64, "seconds": 20, "nodes": 5_000} | (budget or {})
    now = clock or time.monotonic
    started = now()
    notes = [
        "只读取名称、层级和系统报告的文件分配空间。硬链接只计一次。",
        "云端占位、权限不足和扫描预算都会让结果保持未完成。",
        "排除目录只跳过存储分析，不改变清理页的范围。",
    ]
    skipped = dict.fromkeys(("symlink", "placeholder", "cross", "unreadable", "excluded", "duplicate"), 0)
    large = []
    seen = set()
    excluded_paths = {local_path(item) for item in exclusions or [] if item}
    visited = 0
    stop_reason = None

    def checkpoint():
        nonlocal stop_reason
        if cancelled():
            stop_reason = "分析已取消。当前文件系统调用不能被强制打断。"
        elif now() - started >= limits["seconds"]:
            stop_reason = "达到扫描时间预算。"
        elif visited >= min(limits["nodes"], limits["entries"]):
            stop_reason = "已达到目录树节点或条目上限。"
        return stop_reason is None

    def walk(path: Path, depth: int) -> dict | None:
        nonlocal visited
        if not checkpoint():
            return None
        visited += 1
        node = {
            "name": path.name or str(path),
            "path": str(path),
            "allocatedBytes": 0, "logicalBytes": 0, "fileCount": 0, "directoryCount": 0,
            "kind": "未知", "complete": True, "children": [],
        }

        def omit(reason, label):
            skipped[reason] += 1
            node.update(skipped=True, skipReason=label, suggestion=label, complete=reason in {"duplicate", "excluded"})
            return node

        if path != root and (path in excluded_paths or any(parent in excluded_paths for parent in path.parents)):
            return omit("excluded", "排除目录")
        try:
            info = os.lstat(path)
        except OSError:
            return omit("unreadable", "目录或文件元数据无法读取")
        kind = blocked(info)
        if kind:
            return omit(kind, "云端占位" if kind == "placeholder" else "符号链接或重解析点")
        if info.st_dev != root_info.st_dev:
            return omit("cross", "跨卷")
        directory = stat.S_ISDIR(info.st_mode)
        if not directory and not stat.S_ISREG(info.st_mode):
            return omit("unreadable", "非常规文件")
        key = (info.st_dev, info.st_ino)
        if info.st_ino and key in seen:
            return omit("duplicate", "已计入同一实物")
        if info.st_ino:
            seen.add(key)
        node["kind"] = "目录" if directory else "文件"
        try:
            node["allocatedBytes"] = allocation(path, info)
        except (OSError, AppError):
            skipped["unreadable"] += 1
            node.update(complete=False, skipReason="系统未能读取分配空间")
        if directory:
            node["directoryCount"] = 1
            try:
                with directory_entries(path, info) as iterator:
                    for item in iterator:
                        if depth >= limits["depth"]:
                            node.update(complete=False, skipReason="达到目录深度上限")
                            break
                        child = walk(path / item.name, depth + 1)
                        if child is None:
                            node.update(complete=False, skipReason=stop_reason)
                            break
                        node["children"].append(child)
                        node["complete"] = node["complete"] and child["complete"]
                        for key in ("allocatedBytes", "logicalBytes", "fileCount", "directoryCount"):
                            node[key] += child[key]
            except (OSError, AppError):
                skipped["unreadable"] += 1
                node.update(complete=False, skipReason="目录无法读取或发生变化")
            node["children"].sort(key=lambda child: child["name"].casefold())
        else:
            node["logicalBytes"] = max(0, int(info.st_size))
            node["fileCount"] = 1
        node["suggestion"] = _suggestion(path, node["logicalBytes"])
        if not directory and node["logicalBytes"] >= 100 * 1024 * 1024 and len(large) < 200:
            large.append(node)
        return node

    tree = walk(root, 0)
    was_cancelled = bool(cancelled())
    complete = bool(tree and tree["complete"] and not was_cancelled)
    if stop_reason:
        notes.append(stop_reason)
    if not complete:
        notes.append("这次扫描未完成，不能把它的合计当成整个范围，也不能画成实际增减。")
    scope_parts = [os.path.normcase(str(root)), *sorted(os.path.normcase(str(item)) for item in excluded_paths)]
    scope_key = hashlib.sha256("\0".join(scope_parts).encode("utf-8")).hexdigest()
    entries = [{key: value for key, value in node.items() if key != "children"}
               for node in tree["children"] if not node.get("skipped")] if tree else []
    return {
        "scope": str(root),
        "scopeKey": scope_key,
        "complete": complete,
        "cancelled": was_cancelled,
        "notes": notes,
        "tree": tree,
        "entries": entries,
        "largeFiles": large,
        "skipped": skipped,
        "source": "本地元数据",
    }


def analyze_dev(home: Path, system: str, **kwargs) -> dict:
    targets, notes = dev_targets(home, system)
    parts = []
    complete = True
    now = kwargs.get("clock") or time.monotonic
    limits = kwargs.get("budget") or {}
    deadline = now() + limits.get("seconds", 20)
    cancelled = kwargs.get("cancelled", lambda: False)
    for target in targets:
        path = target["path"]
        remaining = deadline - now()
        if remaining <= 0 or cancelled():
            notes.append("开发环境分析在达到时间预算或取消后结束。")
            complete = False
            break
        try:
            info = checked_stat(local_path(path))
            if not stat.S_ISDIR(info.st_mode):
                raise AppError("目录类型无法核实")
            if not target["descend"]:
                parts.append({
                    "label": target["label"], "path": str(path), "present": True, "complete": True,
                    "tree": {"name": path.name, "path": str(path), "allocatedBytes": allocation(path, info),
                             "logicalBytes": 0, "fileCount": 0, "directoryCount": 1, "children": []},
                    "note": "未进入该目录。虚拟机磁盘不在这次分析里。",
                })
                continue
            result = analyze(path, **(kwargs | {"budget": limits | {"seconds": remaining}}))
        except FileNotFoundError:
            parts.append({"label": target["label"], "path": str(path), "present": False, "complete": True, "tree": None})
            continue
        except (OSError, AppError):
            complete = False
            parts.append({"label": target["label"], "path": str(path), "present": None, "complete": False, "tree": None,
                          "notes": ["无法读取目录元数据、权限不足或存在重解析点。"]})
            continue
        complete = complete and result["complete"]
        parts.append({"label": target["label"], "path": str(path), "present": True, "complete": result["complete"],
                      "tree": result["tree"], "notes": result["notes"]})
    return {"kind": "dev", "complete": complete, "cancelled": bool(cancelled()), "parts": parts, "notes": notes,
            "scopeKey": "dev:" + hashlib.sha256(str(Path(home)).encode("utf-8")).hexdigest()}


def compare_history(history: list[dict], scope_key: str) -> dict:
    same = [item for item in history if item.get("scopeKey") == scope_key]
    recent = same[-30:]
    complete = [item for item in recent if item.get("complete")]
    delta = None
    if len(complete) >= 2:
        delta = complete[-1].get("allocatedBytes", 0) - complete[-2].get("allocatedBytes", 0)
    return {
        "kept": len(recent),
        "completeCount": len(complete),
        "deltaAllocatedBytes": delta,
        "partialOmitted": len(recent) - len(complete),
        "note": "只比较同一范围最近 30 次里的完整扫描。部分扫描不画成实际增减。",
    }
