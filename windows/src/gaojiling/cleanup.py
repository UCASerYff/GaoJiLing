"""限定范围的缓存与轮转日志。候选默认不移动；确认后才写入恢复记录并移入废纸篓。

不读取普通文件内容，不跟随符号链接，不到保留期不进入目录。移入废纸篓的字节数不是已释放空间。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import uuid
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import allocation, blocked, checked_stat, identity, local_path
from gaojiling.filesafety import atomic_text, owned_by_current_user, rename_exclusive, stat_alloc
from gaojiling.textutil import valid_bundle_id

CACHE_AGE = 7 * 24 * 60 * 60
LOG_AGE = 30 * 24 * 60 * 60
MAX_ENTRIES = 100_000
_LOG_NAME = re.compile(r"\.log\.(?:[0-9][0-9._-]*(?:\.(?:gz|bz2|xz))?|gz|bz2|xz|old)$", re.IGNORECASE)
_XCODE_ROOTS = {"ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"}
_SKIP_PREFIXES = ("com.apple.", "com.gaoseries.", "com.microsoft.")


def roots_for(home: Path, layout: str) -> dict:
    home = Path(home)
    if layout == "darwin":
        return {
            "caches": home / "Library" / "Caches",
            "logs": home / "Library" / "Logs",
            "derived": home / "Library" / "Developer" / "Xcode" / "DerivedData",
            "dev": [
                ("developer.npm", home / ".npm" / "_cacache"),
                ("developer.pip", home / "Library" / "Caches" / "pip"),
                ("developer.pypoetry", home / "Library" / "Caches" / "pypoetry"),
                ("developer.homebrew", home / "Library" / "Caches" / "Homebrew"),
                ("developer.gradle", home / ".gradle" / "caches"),
            ],
            "xcode": "com.apple.dt.Xcode",
            "nested_logs": False,
        }
    local = home / "AppData" / "Local"
    roaming = home / "AppData" / "Roaming"
    return {
        "caches": None,
        "logs": None,
        "derived": None,
        "known": [
            ("windows.google.chrome", local / "Google" / "Chrome" / "User Data" / "Default" / "Cache"),
            ("windows.google.chrome", local / "Google" / "Chrome" / "User Data" / "Default" / "Code Cache"),
            ("windows.microsoft.vscode", roaming / "Code" / "Cache"),
            ("windows.microsoft.vscode", roaming / "Code" / "CachedData"),
        ],
        "dev": [
            ("developer.npm", local / "npm-cache" / "_cacache"),
            ("developer.pip", local / "pip" / "Cache"),
            ("developer.pypoetry", local / "pypoetry" / "Cache"),
            ("developer.gradle", home / ".gradle" / "caches"),
        ],
        "xcode": None,
        "nested_logs": True,
    }


def _skipped_name(name: str) -> bool:
    lowered = name.lower()
    if lowered in {"com.apple", "com.gaoseries", "com.microsoft"}:
        return True
    return lowered.startswith(_SKIP_PREFIXES) or not valid_bundle_id(name)


class CleanupEngine:
    def __init__(self, home: Path, journal_dir: Path, stage_dir: Path, layout: str,
                 running, owner_lookup, trash, clock=None):
        self.home = Path(home)
        self.journal_dir = Path(journal_dir)
        self.stage_dir = Path(stage_dir)
        self.layout = layout
        self.roots = roots_for(self.home, layout)
        self.running = running
        self.owner_lookup = owner_lookup
        self.trash_action = trash
        self.clock = clock or (lambda: __import__("time").time())
        self.plan = {}
        self.failure = None
        self.journal = {"version": 1, "batches": []}
        self._load()

    def _load(self):
        path = self.journal_dir / "journal.json"
        try:
            if self.journal_dir.exists() and not path.exists() and any(self.journal_dir.iterdir()):
                raise AppError("清理目录已有文件但没有恢复记录，已停止，不会当作空记录。")
            if not os.path.lexists(path):
                return
            info = checked_stat(local_path(path))
            if not stat.S_ISREG(info.st_mode) or info.st_size > 32 * 1024 * 1024:
                raise AppError("恢复记录文件属性不受支持")
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("batches"), list):
                raise AppError("版本无法识别")
            for batch in data["batches"]:
                if not isinstance(batch["id"], str) or not isinstance(batch["receipts"], list):
                    raise AppError("清理批次格式无效")
                for receipt in batch["receipts"]:
                    if (not isinstance(receipt["itemID"], str) or not isinstance(receipt["footprint"], dict)
                            or not isinstance(receipt["footprint"]["digest"], str)
                            or not isinstance(receipt["footprint"]["bytes"], int)
                            or not isinstance(receipt["footprint"]["inode"], int)
                            or not isinstance(receipt["footprint"]["device"], int)
                            or any(not isinstance(receipt[key], str) for key in ("original", "stage", "state", "category"))):
                        raise AppError("清理回执格式无效")
            self.journal = data
        except (OSError, ValueError, TypeError, KeyError, AppError) as error:
            self.failure = AppError(f"清理恢复记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        self.journal_dir.mkdir(parents=True, exist_ok=True)
        checked_stat(local_path(self.journal_dir))
        atomic_text(self.journal_dir / "journal.json", json.dumps(self.journal, ensure_ascii=False, indent=2))

    def history(self) -> list[dict]:
        if self.failure:
            return []
        rows = []
        for batch in reversed(self.journal["batches"]):
            receipts = [item for item in batch["receipts"] if item["state"] != "untouched"]
            if not receipts:
                continue
            pending = [item for item in receipts if item["state"] != "restored"]
            when = batch.get("date")
            summary = f"{len(pending)} 项待尝试恢复，恢复时不会覆盖原位置的新文件。" if pending else "此批次已恢复。"
            if when is None:
                summary = "早期记录，未记录时间。" + summary
            rows.append({
                "id": batch["id"],
                "date": when,
                "dateKnown": when is not None,
                "itemCount": len(receipts),
                "bytes": sum(item["footprint"]["bytes"] for item in receipts),
                "restorableCount": len(pending),
                "summary": summary,
            })
        return rows

    def scan(self, cancelled=lambda: False) -> dict:
        if self.failure:
            raise self.failure
        self.plan = {}
        items = []
        skipped = 0
        notes = [
            "只检查归属明确、相关进程已退出且达到保留期的缓存或轮转日志。",
            "com.apple、com.gaoseries、com.microsoft 目录不列入候选。",
            "旧轮转日志至少保留 30 天，移走后不能重新生成。",
            "占用是分配空间估算。移入废纸篓仍占空间，不能当成已经释放的磁盘容量。",
            "扫描在两次目录读取之间才能停下，不能打断已经发出的系统调用。",
        ]
        if self.layout == "windows":
            notes.append("仅检查核实安装归属的 Chrome 和 VS Code 指定缓存，以及已知开发工具缓存。没有核实的 Windows 轮转日志路径。")
        now = self.clock()

        def children(root: Path):
            nonlocal skipped
            if cancelled():
                return []
            try:
                names = []
                checked_stat(local_path(root))
                with os.scandir(root) as iterator:
                    for entry in iterator:
                        if blocked(entry.stat(follow_symlinks=False)):
                            skipped += 1
                            continue
                        names.append(entry.name)
                        if len(names) > MAX_ENTRIES:
                            notes.append(f"{root} 条目超过上限，已跳过。")
                            return []
                return sorted(names)
            except FileNotFoundError:
                return []
            except (OSError, AppError):
                notes.append(f"{root} 无法安全读取，已跳过。")
                return []

        def consider(path: Path, owner: str, category: str, age: float, check_installed: bool):
            nonlocal skipped
            if cancelled():
                return
            try:
                path = local_path(path)
                info = checked_stat(path)
                expect_dir = category != "旧轮转日志"
                if expect_dir and not stat.S_ISDIR(info.st_mode):
                    skipped += 1
                    return
                if not expect_dir and not stat.S_ISREG(info.st_mode):
                    skipped += 1
                    return
                if now - info.st_mtime < age:
                    skipped += 1
                    return
                if not owned_by_current_user(path, info):
                    skipped += 1
                    return
                if not expect_dir and info.st_nlink != 1:
                    skipped += 1
                    return
                self._inactive(owner, check_installed)
                footprint = self._snapshot(path, info.st_dev, expect_dir, cancelled)
                if now - footprint["newest"] < age:
                    skipped += 1
                    return
                item = {
                    "id": str(uuid.uuid4()).upper(),
                    "category": category,
                    "name": path.name,
                    "displayPath": str(path),
                    "bytes": footprint["bytes"],
                    "reason": "超过 30 天的历史日志，不可重新生成" if category == "旧轮转日志" else "至少 7 天未修改；所属应用已退出",
                }
                self.plan[item["id"]] = {
                    "item": item, "path": path, "owner": owner, "footprint": footprint, "age": age,
                    "checkInstalled": check_installed,
                }
                items.append(item)
            except (AppError, OSError):
                skipped += 1

        for owner, path in self.roots.get("known", ()):
            consider(path, owner, "应用缓存", CACHE_AGE, True)
        caches = self.roots["caches"]
        if caches and caches.is_dir() and not caches.is_symlink():
            for name in children(caches):
                if _skipped_name(name):
                    skipped += 1
                    continue
                consider(caches / name, name, "应用缓存", CACHE_AGE, True)
        for owner, path in self.roots["dev"]:
            if cancelled():
                break
            consider(path, owner, "开发工具缓存", CACHE_AGE, False)
        logs = self.roots["logs"]
        if logs and logs.is_dir() and not logs.is_symlink():
            for owner in children(logs):
                if _skipped_name(owner) or self.owner_lookup(owner) is not True or self.running(owner) is not False:
                    skipped += 1
                    continue
                directory = logs / owner / "Logs" if self.roots["nested_logs"] else logs / owner
                for name in children(directory):
                    if not _LOG_NAME.search(name):
                        skipped += 1
                        continue
                    consider(directory / name, owner, "旧轮转日志", LOG_AGE, True)
        xcode = self.roots["xcode"]
        derived = self.roots["derived"]
        if xcode and derived and not cancelled() and self.owner_lookup(xcode) is True and self.running(xcode) is False:
            for name in children(derived):
                project = derived / name
                if name in _XCODE_ROOTS:
                    consider(project, xcode, "Xcode 构建", CACHE_AGE, True)
                elif not name.startswith("."):
                    for leaf in ("Intermediates.noindex", "Products"):
                        consider(project / "Build" / leaf, xcode, "Xcode 构建", CACHE_AGE, True)
        if cancelled():
            notes.append("扫描已取消，仅保留已完成检查的项目。未完成扫描不能当成全部缓存。")
        items.sort(key=lambda item: item["bytes"], reverse=True)
        return {"items": items, "notes": notes, "skippedCount": skipped, "complete": not cancelled()}

    def trash(self, ids: list[str], cancelled=lambda: False) -> dict:
        if self.failure:
            raise self.failure
        removed, skipped, failed = [], [], []
        moved = 0
        if not ids:
            return self._report(removed, moved, skipped, failed, "未选择项目。", None, False)
        batch = {"id": str(uuid.uuid4()).upper(), "date": self.clock(), "receipts": []}
        self.journal["batches"].append(batch)
        self._save()
        for item_id in ids:
            if cancelled():
                skipped.append({"itemID": item_id, "message": "操作已取消。"})
                continue
            candidate = self.plan.get(item_id)
            if candidate is None:
                skipped.append({"itemID": item_id, "message": "扫描结果已失效，请重新扫描。"})
                continue
            prepared = False
            try:
                self._inactive(candidate["owner"], candidate["checkInstalled"])
                current = self._snapshot(candidate["path"], candidate["footprint"]["device"], candidate["item"]["category"] != "旧轮转日志", cancelled)
                if current != candidate["footprint"]:
                    raise AppError("文件在扫描后发生变化，已跳过。")
                if self.clock() - current["newest"] < candidate["age"]:
                    raise AppError("项目未达到保留期限。")
                self.stage_dir.mkdir(parents=True, exist_ok=True)
                if checked_stat(local_path(self.stage_dir)).st_dev != candidate["footprint"]["device"]:
                    raise AppError("暂存目录不在同一磁盘，已跳过。")
                receipt_id = str(uuid.uuid4()).upper()
                stage = self.stage_dir / f"GaoJiLing-{receipt_id}"
                receipt = {
                    "id": receipt_id, "itemID": item_id, "original": str(candidate["path"]),
                    "stage": str(stage), "trash": None, "owner": candidate["owner"],
                    "category": candidate["item"]["category"], "footprint": candidate["footprint"],
                    "state": "prepared",
                }
                batch["receipts"].append(receipt)
                prepared = True
                self._save()
                self._inactive(candidate["owner"], candidate["checkInstalled"])
                rename_exclusive(candidate["path"], stage, candidate["footprint"]["identity"])
                receipt["state"] = "staged"
                self._save()
                self._inactive(candidate["owner"], candidate["checkInstalled"])
                if self._snapshot(stage, candidate["footprint"]["device"], candidate["item"]["category"] != "旧轮转日志", cancelled) != candidate["footprint"]:
                    raise AppError("移动期间文件发生变化，已停止并尝试放回。")
                receipt["state"] = "trashing"
                self._save()
                destination = Path(self.trash_action(stage))
                receipt["trash"] = str(destination)
                if os.path.lexists(stage) or identity(checked_stat(local_path(destination))) != candidate["footprint"]["identity"]:
                    raise AppError("回收位置无法核实，已保留待恢复记录。")
                receipt["state"] = "trashed"
                self._save()
                removed.append(item_id)
                moved += candidate["footprint"]["bytes"]
                self.plan.pop(item_id, None)
            except Exception as error:
                issue = {"itemID": item_id, "message": str(error)}
                (failed if prepared else skipped).append(issue)
                if prepared:
                    self._try_put_back(batch["receipts"][-1])
        message = f"已将 {len(removed)} 项移入废纸篓；这些文件仍占磁盘空间，可使用恢复。这不是已释放的磁盘空间。"
        return self._report(removed, moved, skipped, failed, message, batch["id"], cancelled())

    def restore(self, batch_id: str | None = None) -> dict:
        if self.failure:
            raise self.failure
        chosen = None
        for batch in reversed(self.journal["batches"]):
            if batch_id and batch["id"] != batch_id:
                continue
            if any(item["state"] not in {"restored", "untouched"} for item in batch["receipts"]):
                chosen = batch
                break
        if chosen is None:
            return self._report([], 0, [], [], "没有可恢复的清理记录。", batch_id, False)
        restored, skipped, failed = [], [], []
        for receipt in chosen["receipts"]:
            if receipt["state"] in {"restored", "untouched"}:
                continue
            try:
                source = local_path(Path(receipt["trash"] or receipt["stage"]))
                original = local_path(Path(receipt["original"]))
                if not os.path.lexists(source):
                    raise AppError("废纸篓或暂存中已找不到原项目。")
                if os.path.lexists(original):
                    raise AppError("原位置已有新文件，未覆盖。")
                current = self._snapshot(source, receipt["footprint"]["device"], receipt["category"] != "旧轮转日志",
                                         lambda: False, legacy="identity" not in receipt["footprint"])
                if current["digest"] != receipt["footprint"]["digest"]:
                    raise AppError("内容或身份已变化，未覆盖。")
                rename_exclusive(source, original, current["identity"])
                receipt["state"] = "restored"
                self._save()
                restored.append(receipt["itemID"])
            except Exception as error:
                failed.append({"itemID": receipt["itemID"], "message": str(error)})
        return self._report(restored, 0, skipped, failed, f"已尝试恢复 {len(restored)} 项。未能恢复的项目仍留在记录中。", chosen["id"], False)

    def _try_put_back(self, receipt: dict):
        stage = Path(receipt["stage"])
        original = Path(receipt["original"])
        if not os.path.lexists(stage):
            try:
                info = checked_stat(local_path(original))
                if (info.st_dev, info.st_ino) == (receipt["footprint"]["device"], receipt["footprint"]["inode"]):
                    receipt["state"] = "untouched"
                    self._save()
            except (OSError, AppError):
                pass
            return
        try:
            if os.path.lexists(original):
                raise AppError("原位置已占用")
            rename_exclusive(stage, original, receipt["footprint"]["identity"])
            receipt["state"] = "restored"
            self._save()
        except (OSError, AppError):
            receipt["state"] = "staged"
            self._save()

    def _inactive(self, owner: str, check_installed: bool):
        if check_installed and self.owner_lookup(owner) is not True:
            raise AppError("无法确认所属应用，已跳过。")
        active = self.running(owner)
        if active is None:
            raise AppError("无法确认应用及后台进程状态，已跳过。")
        if active:
            raise AppError("所属应用或后台进程正在运行，已跳过。")

    def _snapshot(self, path: Path, device: int, expect_dir: bool, cancelled, legacy=False) -> dict:
        digest = hashlib.sha256()
        total = 0
        newest = 0.0
        count = 0

        def record(path, info, relative: str):
            nonlocal total, newest
            alloc = allocation(path, info) if os.name == "nt" and not legacy and stat.S_ISREG(info.st_mode) else stat_alloc(info)
            total += alloc
            newest = max(newest, info.st_mtime)
            line = f"{relative}|{info.st_dev}|{info.st_ino}|{info.st_mode}|{info.st_size}|{alloc}|{info.st_mtime_ns}\n"
            digest.update(line.encode("utf-8"))

        def walk(current: Path, relative: str, depth: int):
            nonlocal count
            if cancelled():
                raise AppError("扫描已取消。")
            count += 1
            if count > MAX_ENTRIES or depth > 64:
                raise AppError("项目目录过大或过深，已跳过。")
            info = os.lstat(current)
            if blocked(info):
                raise AppError("项目含链接、挂载点或云端占位，已跳过。")
            if info.st_dev != device:
                raise AppError("项目跨磁盘，已跳过。")
            if not owned_by_current_user(current, info):
                raise AppError("项目归属其他用户，已跳过。")
            if stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    raise AppError("项目含硬链接，已跳过。")
                record(current, info, relative)
                return
            if not stat.S_ISDIR(info.st_mode):
                raise AppError("项目含特殊文件，已跳过。")
            record(current, info, relative)
            with os.scandir(current) as iterator:
                names = sorted(entry.name for entry in iterator)
            for name in names:
                child = current / name
                walk(child, name if not relative else relative + "/" + name, depth + 1)

        info = checked_stat(local_path(path))
        if expect_dir and not stat.S_ISDIR(info.st_mode):
            raise AppError("候选已不是目录。")
        walk(path, "", 0)
        return {
            "device": int(info.st_dev),
            "inode": int(info.st_ino),
            "identity": identity(info),
            "digest": digest.hexdigest(),
            "bytes": total,
            "newest": newest,
            "entries": count,
        }

    @staticmethod
    def _report(removed, moved, skipped, failed, message, batch_id, cancelled):
        return {
            "removedIDs": removed,
            "movedBytes": moved,
            "skipped": skipped,
            "failed": failed,
            "message": message,
            "batchID": batch_id,
            "cancelled": cancelled,
        }
