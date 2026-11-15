"""完全相同文件的内容分析。必须另行确认才读取内容。相似图片不在能力内。

只有完整结果可以移动。每组至少保留一个实物，候选默认不选。硬链接只计一次。
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import time
import uuid
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filesafety import atomic_text, rename_exclusive, stat_alloc, within

PROTECTED_EXTENSIONS = {
    "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "pdf", "xls", "xlsx", "ods",
    "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "tex", "bib", "ris", "sqlite",
    "sqlite3", "db", "db3", "keychain", "keychain-db", "wal", "shm",
}
LIMITS = {"entries": 100_000, "files": 20_000, "depth": 64, "seconds": 60, "bytes": 4 * 1024 ** 3}


def protection_reason(path: Path, home: Path) -> str | None:
    text = str(path)
    lowered = text.lower()
    parts = [part.lower() for part in path.parts]
    home_text = str(home)
    for folder in ("Documents", "Downloads", "Desktop", "文档", "下载", "桌面"):
        base = str(Path(home_text) / folder)
        if text == base or text.startswith(base + os.sep):
            return "个人文稿、下载或桌面资料（仅分析，不提供移动）"
    if any(part in {"gaoseries", "搞app"} or part.startswith("com.gaoseries.") for part in parts):
        return "搞系列程序或资料"
    if ".git" in parts or ".svn" in parts:
        return "版本库（仅分析，不提供移动）"
    suffix = path.suffix.lower().lstrip(".")
    if suffix in PROTECTED_EXTENSIONS or path.name.lower().endswith(("-wal", "-shm")):
        return "文档、业务数据库或凭据（仅分析，不提供移动）"
    windows = [os.environ.get("SystemRoot", r"C:\Windows"), os.environ.get("ProgramFiles", r"C:\Program Files"),
               os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")]
    unix = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications"]
    for root in windows + unix:
        if root and (lowered == root.lower() or lowered.startswith(root.lower() + os.sep)):
            return "系统或已安装程序目录"
    return None


def _sha(path: Path, budget: dict) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            if budget["read"] >= LIMITS["bytes"]:
                raise AppError("内容读取达到 4GiB 上限。")
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            budget["read"] += len(chunk)
            digest.update(chunk)
    return digest.hexdigest()


def _segment(path: Path, size: int, budget: dict) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        first = handle.read(min(65536, size))
        budget["read"] += len(first)
        digest.update(first)
        if size > 65536:
            handle.seek(max(0, size - 65536))
            last = handle.read(65536)
            budget["read"] += len(last)
            digest.update(last)
    digest.update(str(size).encode("ascii"))
    return digest.hexdigest()


class DuplicateEngine:
    def __init__(self, journal_dir: Path, stage_dir: Path, home: Path, trash, clock=None):
        self.journal_dir = Path(journal_dir)
        self.stage_dir = Path(stage_dir)
        self.home = Path(home)
        self.trash = trash
        self.clock = clock or time.time
        self.marker = self.journal_dir / "Duplicates.initialized"
        self.journal_path = self.journal_dir / "journal.json"
        self.failure = None
        self.journal = {"version": 1, "batches": []}
        self.result = None
        self._load()

    def _load(self):
        directory = self.journal_dir
        try:
            marker = self.marker.exists()
            journal = self.journal_path.exists()
            extras = []
            if directory.exists():
                extras = [item for item in directory.iterdir() if item not in {self.marker, self.journal_path}]
            if extras:
                raise AppError("重复文件目录里有未声明的文件，已停止。")
            if marker != journal:
                raise AppError("重复文件初始化标记与记录不一致，已停止，不会当作空记录。")
            if not journal:
                return
            data = json.loads(self.journal_path.read_text(encoding="utf-8"))
            if data.get("version") != 1:
                raise AppError("记录版本无法识别")
            self.journal = data
        except (OSError, json.JSONDecodeError, AppError) as error:
            self.failure = AppError(f"重复文件恢复记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        self.journal_dir.mkdir(parents=True, exist_ok=True)
        if not self.marker.exists():
            self.marker.write_text("initialized\n", encoding="utf-8")
        atomic_text(self.journal_path, json.dumps(self.journal, ensure_ascii=False, indent=2))

    def scan(self, scope: Path, confirm_read: bool, cancelled=lambda: False) -> dict:
        if self.failure:
            raise self.failure
        if not confirm_read:
            raise AppError("需要另行确认才会读取文件内容。原元数据分析不会读取内容。")
        root = Path(scope)
        if not root.is_dir() or root.is_symlink():
            raise AppError("请选择一个本机普通目录。")
        started = time.monotonic()
        root_info = os.lstat(root)
        files = []
        seen = {}
        notes = ["相似图片未支持。只有字节完全相同的独立实物才会归组。", "硬链接只计一次实物。"]
        complete = True
        skipped = 0
        visited = 0

        def walk(path: Path, depth: int):
            nonlocal complete, skipped, visited
            if cancelled() or time.monotonic() - started >= LIMITS["seconds"] or visited >= LIMITS["entries"]:
                complete = False
                return
            visited += 1
            try:
                info = os.lstat(path)
            except OSError:
                skipped += 1
                complete = False
                return
            if stat.S_ISLNK(info.st_mode):
                skipped += 1
                complete = False
                return
            if info.st_dev != root_info.st_dev:
                skipped += 1
                complete = False
                return
            if stat.S_ISDIR(info.st_mode):
                if depth >= LIMITS["depth"]:
                    complete = False
                    return
                try:
                    with os.scandir(path) as iterator:
                        names = sorted(entry.name for entry in iterator)
                except OSError:
                    skipped += 1
                    complete = False
                    return
                for name in names:
                    walk(path / name, depth + 1)
                return
            if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
                skipped += 1
                return
            physical = f"{info.st_dev}:{info.st_ino}"
            if info.st_ino == 0:
                physical = f"path:{path}"
                notes.append("此文件系统没有可用的 inode，不能把硬链接合并成一个实物。")
            if physical in seen:
                seen[physical]["paths"].append(str(path))
                return
            if len(files) >= LIMITS["files"]:
                complete = False
                return
            item = {
                "id": str(uuid.uuid4()).upper(),
                "path": str(path),
                "name": path.name,
                "physical": physical,
                "size": int(info.st_size),
                "allocated": stat_alloc(info),
                "mtime": info.st_mtime,
                "paths": [str(path)],
                "protection": protection_reason(path, self.home),
            }
            seen[physical] = item
            files.append(item)

        walk(root, 0)
        budget = {"read": 0}
        by_size = {}
        for item in files:
            by_size.setdefault(item["size"], []).append(item)
        groups = []
        try:
            for size, group in by_size.items():
                if len(group) < 2:
                    continue
                segments = {}
                for item in group:
                    if cancelled() or budget["read"] >= LIMITS["bytes"]:
                        complete = False
                        break
                    item["segment"] = _segment(Path(item["path"]), size, budget)
                    segments.setdefault(item["segment"], []).append(item)
                for segment_group in segments.values():
                    if len(segment_group) < 2:
                        continue
                    hashes = {}
                    for item in segment_group:
                        item["sha256"] = _sha(Path(item["path"]), budget)
                        hashes.setdefault(item["sha256"], []).append(item)
                    for digest, hashed in hashes.items():
                        if len(hashed) < 2:
                            continue
                        first = Path(hashed[0]["path"]).read_bytes()
                        confirmed = [hashed[0]]
                        for other in hashed[1:]:
                            data = Path(other["path"]).read_bytes()
                            budget["read"] += len(data)
                            if data == first and len(data) == size:
                                confirmed.append(other)
                            else:
                                complete = False
                        if len(confirmed) < 2:
                            continue
                        keeper = sorted(confirmed, key=lambda item: (item["mtime"], item["path"]))[0]
                        groups.append({
                            "id": digest,
                            "sha256": digest,
                            "byteCount": size,
                            "suggestedKeeperID": keeper["id"],
                            "files": [{
                                "id": item["id"], "path": item["path"], "name": item["name"], "sha256": digest,
                                "protectionReason": item["protection"], "selected": False,
                                "linkCount": len(item["paths"]),
                            } for item in confirmed],
                        })
        except AppError as error:
            complete = False
            notes.append(str(error))
        if not complete:
            notes.append("结果不完整。未完整分析不能移动文件。")
        self.result = {
            "id": str(uuid.uuid4()).upper(),
            "scope": str(root),
            "device": int(root_info.st_dev),
            "inode": int(root_info.st_ino),
            "complete": complete,
            "groups": groups,
            "notes": notes,
            "skipped": skipped,
            "contentBytesRead": budget["read"],
        }
        return self.result

    def move(self, selected_ids: list[str]) -> dict:
        if self.failure:
            raise self.failure
        result = self.result
        if not result or not result["complete"]:
            raise AppError("只有完整分析结果可以移动。")
        if not selected_ids:
            raise AppError("没有选中副本。候选默认不移动。")
        chosen = set(selected_ids)
        batch = {"id": str(uuid.uuid4()).upper(), "date": self.clock(), "receipts": []}
        removed = []
        failed = []
        for group in result["groups"]:
            ids = [item["id"] for item in group["files"]]
            moving = [item for item in group["files"] if item["id"] in chosen]
            if not moving:
                continue
            if len(moving) >= len(ids):
                failed.append({"itemID": group["id"], "message": "每组至少保留一个实物，未移动这一组。"})
                continue
            for item in moving:
                if item.get("protectionReason"):
                    failed.append({"itemID": item["id"], "message": item["protectionReason"]})
                    continue
                if not within(Path(item["path"]), Path(result["scope"])):
                    failed.append({"itemID": item["id"], "message": "不在已确认的目录内。"})
                    continue
                try:
                    current = _sha(Path(item["path"]), {"read": 0})
                    data = Path(item["path"]).read_bytes()
                    if current != item["sha256"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
                        raise AppError("文件在分析后已变化，原文件未移动。")
                    self.stage_dir.mkdir(parents=True, exist_ok=True)
                    stage = self.stage_dir / item["id"]
                    receipt = {"id": item["id"], "original": item["path"], "stage": str(stage), "trash": None,
                               "sha256": item["sha256"], "state": "prepared"}
                    batch["receipts"].append(receipt)
                    self.journal["batches"].append(batch) if batch not in self.journal["batches"] else None
                    self._save()
                    rename_exclusive(Path(item["path"]), stage)
                    receipt["state"] = "staged"
                    self._save()
                    destination = Path(self.trash(stage))
                    receipt["trash"] = str(destination)
                    receipt["state"] = "trashed"
                    self._save()
                    removed.append(item["id"])
                except Exception as error:
                    failed.append({"itemID": item["id"], "message": str(error)})
        if not removed and not failed:
            raise AppError("没有可移动的副本。")
        return {"removedIDs": removed, "failed": failed, "batchID": batch["id"],
                "message": "已把选中的副本移入废纸篓。这不是已释放的磁盘空间，共享块也不能按候选大小承诺释放量。"}

    def restore(self, batch_id: str | None = None) -> dict:
        if self.failure:
            raise self.failure
        restored, failed = [], []
        for batch in reversed(self.journal["batches"]):
            if batch_id and batch["id"] != batch_id:
                continue
            for receipt in batch["receipts"]:
                if receipt["state"] == "restored":
                    continue
                source = Path(receipt.get("trash") or receipt["stage"])
                original = Path(receipt["original"])
                try:
                    if original.exists() or original.is_symlink():
                        raise AppError("原位置已有新文件，未覆盖。")
                    if _sha(source, {"read": 0}) != receipt["sha256"]:
                        raise AppError("暂存内容已变化，未覆盖。")
                    rename_exclusive(source, original)
                    receipt["state"] = "restored"
                    self._save()
                    restored.append(receipt["id"])
                except Exception as error:
                    failed.append({"itemID": receipt["id"], "message": str(error)})
            break
        return {"restored": restored, "failed": failed, "message": f"已尝试恢复 {len(restored)} 项。"}
