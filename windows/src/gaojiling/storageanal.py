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
from gaojiling.filesafety import stat_alloc, within

DOCUMENT_EXTENSIONS = {
    "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "pdf", "xls", "xlsx", "ods",
    "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "tex", "bib",
}


def dev_targets(home: Path, system: str) -> list[dict]:
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
    root = Path(scope)
    if not root.is_dir() or root.is_symlink():
        raise AppError("请选择一个本机普通目录。符号链接不会被当作分析根。")
    limits = {"entries": 100_000, "depth": 64, "seconds": 20, "nodes": 5_000}
    if budget:
        limits.update(budget)
    started = (clock or time.monotonic)()
    now = clock or time.monotonic
    root_info = os.lstat(root)
    notes = [
        "只读取名称、层级和分配空间，不打开文件内容，不跟随符号链接，不跨卷。",
        "云端占位、权限不足和扫描预算都会让结果保持未完成。",
        "排除目录只跳过存储分析，不改变清理页的范围。",
    ]
    skipped = {"symlink": 0, "cross": 0, "unreadable": 0, "excluded": 0}
    complete = True
    entries = []
    large = []
    visited = 0

    def expired():
        return cancelled() or now() - started >= limits["seconds"] or visited >= limits["entries"]

    def excluded(path: Path) -> bool:
        for item in exclusions or []:
            if not item:
                continue
            other = Path(item)
            if path == other or within(path, other):
                return True
        return False

    def walk(path: Path, depth: int) -> dict | None:
        nonlocal visited, complete
        if expired():
            complete = False
            return None
        visited += 1
        try:
            info = os.lstat(path)
        except OSError:
            skipped["unreadable"] += 1
            complete = False
            return None
        if stat.S_ISLNK(info.st_mode):
            skipped["symlink"] += 1
            complete = False
            return None
        if info.st_dev != root_info.st_dev:
            skipped["cross"] += 1
            complete = False
            return None
        if excluded(path) and path != root:
            skipped["excluded"] += 1
            return {"name": path.name, "path": str(path), "allocatedBytes": 0, "logicalBytes": 0,
                    "fileCount": 0, "directoryCount": 0, "skipped": True, "children": []}
        if not stat.S_ISDIR(info.st_mode):
            logical = max(0, int(info.st_size))
            allocated = stat_alloc(info)
            if logical >= 100 * 1024 * 1024 and len(large) < 200:
                large.append({"name": path.name, "path": str(path), "logicalBytes": logical, "allocatedBytes": allocated,
                              "suggestion": _suggestion(path, logical)})
            return {"name": path.name, "path": str(path), "allocatedBytes": allocated, "logicalBytes": logical,
                    "fileCount": 1, "directoryCount": 0, "children": []}
        children = []
        allocated = stat_alloc(info)
        logical = 0
        files = 0
        directories = 1
        try:
            with os.scandir(path) as iterator:
                names = sorted(entry.name for entry in iterator)
        except OSError:
            skipped["unreadable"] += 1
            complete = False
            names = []
        for name in names:
            if len(entries) >= limits["nodes"]:
                complete = False
                notes.append("节点数量达到上限，更深的目录没有全部展开。")
                break
            if depth >= limits["depth"]:
                complete = False
                break
            child = walk(path / name, depth + 1)
            if child is None:
                continue
            if not child.get("skipped"):
                allocated += child["allocatedBytes"]
                logical += child["logicalBytes"]
                files += child["fileCount"]
                directories += child["directoryCount"]
            if depth < 2:
                children.append({key: child[key] for key in ("name", "path", "allocatedBytes", "logicalBytes", "fileCount", "directoryCount")})
        node = {
            "name": path.name or str(path),
            "path": str(path),
            "allocatedBytes": allocated,
            "logicalBytes": logical,
            "fileCount": files,
            "directoryCount": directories,
            "children": children,
            "suggestion": _suggestion(path, logical),
        }
        if depth <= 1:
            entries.append(node)
        return node

    tree = walk(root, 0)
    if cancelled():
        complete = False
        notes.append("分析已取消。当前文件系统调用不能被强制打断。")
    if not complete:
        notes.append("这次扫描未完成，不能把它的合计当成整个范围，也不能画成实际增减。")
    scope_key = hashlib.sha256(str(root).encode("utf-8")).hexdigest()
    return {
        "scope": str(root),
        "scopeKey": scope_key,
        "complete": complete and tree is not None,
        "cancelled": bool(cancelled()),
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
    for target in targets:
        path = target["path"]
        if not path.exists() or path.is_symlink():
            parts.append({"label": target["label"], "path": str(path), "present": False, "complete": True, "tree": None})
            continue
        if not target["descend"]:
            info = os.lstat(path)
            parts.append({
                "label": target["label"], "path": str(path), "present": True, "complete": True,
                "tree": {"name": path.name, "path": str(path), "allocatedBytes": stat_alloc(info),
                         "logicalBytes": max(0, int(info.st_size)), "fileCount": 0, "directoryCount": 1, "children": []},
                "note": "未进入该目录。虚拟机磁盘不在这次分析里。",
            })
            continue
        result = analyze(path, **kwargs)
        complete = complete and result["complete"]
        parts.append({"label": target["label"], "path": str(path), "present": True, "complete": result["complete"], "tree": result["tree"], "notes": result["notes"]})
    return {"kind": "dev", "complete": complete, "parts": parts, "notes": notes, "scopeKey": "dev:" + hashlib.sha256(str(Path(home)).encode("utf-8")).hexdigest()}


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
