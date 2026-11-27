"""Bounded duplicate-content analysis and journaled selection, movement and recovery."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import allocation, blocked, checked_stat, directory_entries, identity, local_path, open_regular
from gaojiling.filesafety import atomic_text, owned_by_current_user, rename_exclusive

PROTECTED_EXTENSIONS = {
    "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "pages", "pdf", "xls", "xlsx", "ods",
    "numbers", "csv", "tsv", "ppt", "pptx", "odp", "key", "tex", "bib", "ris", "sqlite",
    "sqlite3", "db", "db3", "keychain", "keychain-db", "pem", "pfx", "kdbx", "wal", "shm",
}
LIMITS = {"entries": 100_000, "files": 20_000, "depth": 64, "seconds": 60, "bytes": 4 * 1024 ** 3}
STAGE_NAME = ".GaoJiLing-DuplicateStage"
CHUNK = 1 << 20


def _windows_special_folders(home):
    if os.name != "nt" or home != Path.home():
        return ()

    import ctypes

    search = ctypes.windll.shell32.SHGetKnownFolderPath
    release = ctypes.windll.ole32.CoTaskMemFree
    release.argtypes = [ctypes.c_void_p]
    result = []
    for folder in ("fdd39ad0-238f-46af-adb4-6c85480369c7", "374de290-123f-4565-9164-39c4925e467b",
                   "b4bfcc3a-db2c-424c-b029-7fe99a87c641"):
        key = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(folder).bytes_le)
        output = ctypes.c_wchar_p()
        if search(ctypes.byref(key), 0x4000, None, ctypes.byref(output)) == 0:
            try:
                if output.value:
                    result.append(Path(output.value))
            finally:
                release(ctypes.cast(output, ctypes.c_void_p))
    return tuple(result)


def protection_reason(path: Path, home: Path, special=()) -> str | None:
    parts = {part.casefold() for part in path.parts}
    folders = ("Documents", "Downloads", "Desktop", "文档", "下载", "桌面", "AppData", ".ssh", ".gnupg")
    if any(path.is_relative_to(root) for root in (*special, *(home / folder for folder in folders))):
        return "个人文稿、下载、桌面、应用资料或凭据。"
    if any(part in {"gaoseries", "搞app"} or part.startswith("com.gaoseries.") for part in parts):
        return "搞系列程序或资料。"
    if parts & {".git", ".svn", "$recycle.bin", "system volume information", "users", "public"}:
        if parts & {".git", ".svn", "$recycle.bin", "system volume information", "public"} or not path.is_relative_to(home):
            return "版本库、系统或其他用户的共享/业务位置。"
    if path.suffix.casefold().lstrip(".") in PROTECTED_EXTENSIONS or path.name.casefold().endswith(("-wal", "-shm")):
        return "文档、业务数据库或凭据。"
    system = (os.environ.get("SystemRoot"), os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)"),
              os.environ.get("ProgramData")) if os.name == "nt" else ("/System", "/usr", "/bin", "/sbin", "/Library", "/Applications")
    if any(value and path.is_relative_to(Path(value)) for value in system):
        return "系统和已安装程序目录。"
    return None


class BudgetSpent(AppError):
    pass


class ReadBudget:
    def __init__(self, cancelled=lambda: False):
        self.used = 0
        self.cancelled = cancelled
        self.deadline = time.monotonic() + LIMITS["seconds"]

    def checkpoint(self):
        if self.cancelled() or time.monotonic() >= self.deadline:
            raise BudgetSpent("分析已取消或达到协作时间预算。")

    def read(self, fd, length):
        self.checkpoint()
        if length > LIMITS["bytes"] - self.used:
            raise BudgetSpent("内容读取达到 4 GiB 上限。")
        data = os.read(fd, length)
        self.used += len(data)
        if len(data) != length:
            raise AppError("文件内容提前结束。")
        return data


@contextmanager
def _open(path: Path, expected: dict | None = None):
    fd, info = open_regular(path)
    try:
        initial = identity(info)
        if expected is not None and initial != expected:
            raise AppError("文件身份、大小或修改时间已变化。")
        yield fd, info.st_size
        if identity(os.fstat(fd)) != initial or identity(checked_stat(path)) != initial:
            raise AppError("读取期间文件身份、大小或修改时间已变化。")
    finally:
        os.close(fd)


def _segment(item, budget):
    size = item["proof"]["size"]
    with _open(item["path"], item["proof"]) as (fd, _):
        digest = hashlib.sha256(budget.read(fd, min(65536, size)))
        if size > 65536:
            os.lseek(fd, size - 65536, os.SEEK_SET)
            digest.update(budget.read(fd, 65536))
    return digest.digest()


def _sha(path, budget, proof=None):
    digest = hashlib.sha256()
    with _open(path, proof) as (fd, size):
        for offset in range(0, size, CHUNK):
            digest.update(budget.read(fd, min(CHUNK, size - offset)))
    return digest.hexdigest()


def _equal(left, right, size, budget, checksum=None):
    digest = hashlib.sha256() if checksum else None
    with _open(left["path"], left["proof"]) as (a, _), _open(right["path"], right["proof"]) as (b, _):
        for offset in range(0, size, CHUNK):
            length = min(CHUNK, size - offset)
            expected = budget.read(a, length)
            if expected != budget.read(b, length):
                return False
            if digest is not None:
                digest.update(expected)
    return digest is None or digest.hexdigest() == checksum


class DuplicateEngine:
    def __init__(self, journal_dir: Path, stage_dir: Path, home: Path, trash, clock=None):
        self.journal_dir = Path(journal_dir)
        self.stage_dir = Path(stage_dir)
        self.home = local_path(home)
        self._special_folders = _windows_special_folders(self.home)
        self.trash = trash
        self.clock = clock or time.time
        self.marker = self.journal_dir / "Duplicates.initialized"
        self.journal_path = self.journal_dir / "journal.json"
        self.failure = None
        self.journal = {"version": 1, "batches": []}
        self.result = None
        self._proofs = {}
        self._lock = threading.RLock()
        self._load()

    def _load(self):
        directory = self.journal_dir
        try:
            marker = os.path.lexists(self.marker)
            journal = os.path.lexists(self.journal_path)
            if directory.exists():
                checked_stat(local_path(directory))
                if any(item not in {self.marker, self.journal_path} for item in directory.iterdir()):
                    raise AppError("重复文件记录目录含未声明文件。")
            if marker != journal:
                raise AppError("重复文件初始化标记与记录不一致。")
            if not journal:
                return
            checked_stat(local_path(self.marker))
            with _open(local_path(self.journal_path)) as (fd, size):
                if size > 16 << 20:
                    raise AppError("重复文件恢复记录超过 16 MiB。")
                data = json.loads(os.read(fd, size).decode("utf-8"))
            if data["version"] != 1 or not isinstance(data["batches"], list):
                raise AppError("恢复记录版本无法识别。")
            for batch in data["batches"]:
                if not isinstance(batch["id"], str) or not isinstance(batch["receipts"], list):
                    raise AppError("恢复记录批次格式无法识别。")
                for record in batch["receipts"]:
                    if (not all(isinstance(record[key], str) for key in ("id", "original", "stage", "sha256"))
                            or record["state"] not in {"prepared", "staged", "trashed", "restored"}):
                        raise AppError("恢复记录明细格式无法识别。")
            self.journal = data
        except (OSError, ValueError, KeyError, TypeError, AppError) as error:
            self.failure = AppError(f"重复文件恢复记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        try:
            payload = json.dumps(self.journal, ensure_ascii=False, indent=2)
            if len(payload.encode("utf-8")) > 16 << 20:
                raise AppError("重复文件恢复记录超过 16 MiB。")
            self.journal_dir.mkdir(parents=True, exist_ok=True)
            checked_stat(local_path(self.journal_dir))
            if not self.marker.exists():
                with self.marker.open("x", encoding="utf-8") as marker:
                    marker.write("initialized\n")
                    marker.flush()
                    os.fsync(marker.fileno())
            atomic_text(self.journal_path, payload)
        except (OSError, AppError) as error:
            self.failure = AppError(f"无法持久保存重复文件恢复记录：{error}")
            raise self.failure from error

    def history(self) -> list[dict]:
        with self._lock:
            if self.failure:
                raise self.failure
            return [
                {"id": item["id"], "date": item.get("date"),
                 "pending": sum(row["state"] != "restored" for row in item["receipts"]),
                 "restored": sum(row["state"] == "restored" for row in item["receipts"]),
                 "bytes": sum((row.get("identity") or {}).get("size", 0) for row in item["receipts"])}
                for item in reversed(self.journal["batches"])
            ]

    def scan(self, scope: Path, confirm_read: bool, cancelled=lambda: False) -> dict:
        if not confirm_read:
            raise AppError("需要另行确认才会读取文件内容。")
        with self._lock:
            if self.failure:
                raise self.failure
            self.result = None
            self._proofs = {}
            return self._scan(scope, cancelled)

    def _scan(self, scope, cancelled):
        root = local_path(scope)
        root_info = checked_stat(root)
        if not stat.S_ISDIR(root_info.st_mode):
            raise AppError("请选择一个本机普通目录。")
        budget = ReadBudget(cancelled)
        files = {}
        notes = ["仅比较独立实物的完整文件字节。硬链接只计一次。相似图片不在分析范围。"]
        complete = True
        skipped = 0
        visited = 0

        def visit(path, depth):
            nonlocal complete, skipped, visited
            budget.checkpoint()
            if visited >= LIMITS["entries"] or len(files) >= LIMITS["files"]:
                raise BudgetSpent("重复分析达到条目或文件数预算。")
            if path == self.stage_dir or path.name == STAGE_NAME or path == self.journal_dir:
                return
            visited += 1
            try:
                info = os.lstat(path)
                if blocked(info) or info.st_dev != root_info.st_dev or not info.st_ino:
                    raise AppError("跳过云端占位、链接、跨卷或不可核实的文件身份。")
                if stat.S_ISDIR(info.st_mode):
                    if depth >= LIMITS["depth"]:
                        raise AppError("达到目录深度上限。")
                    with directory_entries(path, info) as iterator:
                        for item in iterator:
                            visit(path / item.name, depth + 1)
                elif stat.S_ISREG(info.st_mode) and info.st_size:
                    physical = (info.st_dev, info.st_ino)
                    if physical not in files:
                        files[physical] = {"id": str(uuid.uuid4()).upper(), "path": path, "proof": identity(info),
                                           "links": info.st_nlink, "mtime": info.st_mtime}
            except BudgetSpent:
                raise
            except (OSError, AppError):
                skipped += 1
                complete = False

        groups = []
        try:
            visit(root, 0)
            sizes = {}
            for item in files.values():
                sizes.setdefault(item["proof"]["size"], []).append(item)
            for size, same_size in sizes.items():
                if len(same_size) < 2:
                    continue
                segments = {}
                for item in same_size:
                    try:
                        digest = _segment(item, budget)
                    except BudgetSpent:
                        raise
                    except (OSError, AppError):
                        skipped += 1
                        complete = False
                    else:
                        segments.setdefault(digest, []).append(item)
                for matching in segments.values():
                    if len(matching) < 2:
                        continue
                    hashes = {}
                    try:
                        for item in matching:
                            digest = _sha(item["path"], budget, item["proof"])
                            hashes.setdefault(digest, []).append(item)
                        for digest, hashed in hashes.items():
                            if len(hashed) < 2:
                                continue
                            matched = [hashed[0]]
                            for other in hashed[1:]:
                                if _equal(matched[0], other, size, budget):
                                    matched.append(other)
                                else:
                                    complete = False
                            if len(matched) > 1:
                                group = self._group(digest, size, matched, budget)
                                groups.append(group)
                                if any(item["allocatedBytes"] is None for item in group["files"]):
                                    complete = False
                                    if "系统未返回部分副本的分配空间。" not in notes:
                                        notes.append("系统未返回部分副本的分配空间。")
                    except BudgetSpent:
                        raise
                    except (OSError, AppError):
                        skipped += 1
                        complete = False
        except BudgetSpent as error:
            notes.append(str(error))
            complete = False
        was_cancelled = bool(cancelled())
        if was_cancelled:
            complete = False
        if not complete:
            notes.append("分析未完成。无法读取、已变化或超出预算的项目已跳过，移动功能暂不可用。")
        self.result = {
            "id": str(uuid.uuid4()).upper(), "scope": str(root), "device": int(root_info.st_dev),
            "inode": int(root_info.st_ino), "complete": complete, "cancelled": was_cancelled,
            "groups": groups, "notes": notes,
            "skipped": skipped, "contentBytesRead": budget.used,
        }
        return self.result

    def _group(self, digest, size, matched, budget):
        keeper = min(matched, key=lambda item: (item["mtime"], item["path"]))
        records = []
        for item in matched:
            budget.checkpoint()
            self._proofs[item["id"]] = item
            reason = protection_reason(item["path"], self.home, self._special_folders)
            if reason is None and item["links"] > 1:
                reason = "同一实物有多个硬链接。"
            allocated = None
            try:
                info = checked_stat(item["path"])
                if identity(info) == item["proof"]:
                    allocated = allocation(item["path"], info)
                    if reason is None and not owned_by_current_user(item["path"], info):
                        reason = "文件所有者不是当前用户或无法核实。"
            except (OSError, AppError):
                reason = reason or "文件所有权或分配空间无法核实。"
            records.append({"id": item["id"], "path": str(item["path"]), "name": item["path"].name,
                            "sha256": digest, "protectionReason": reason, "selected": False,
                            "linkCount": item["links"], "logicalBytes": size, "allocatedBytes": allocated})
        return {"id": digest, "sha256": digest, "byteCount": size,
                "suggestedKeeperID": keeper["id"], "files": records}

    def move(self, selected_ids: list[str]) -> dict:
        with self._lock:
            return self._move(selected_ids)

    def _move(self, selected_ids):
        if self.failure:
            raise self.failure
        result = self.result
        if not result or not result["complete"]:
            raise AppError("只有完整分析结果可以移动。")
        if not selected_ids:
            raise AppError("没有选中副本。")
        chosen = set(selected_ids)
        if not chosen <= self._proofs.keys():
            raise AppError("选中条目不属于当前分析。")
        scope = local_path(result["scope"])
        scope_info = checked_stat(scope)
        if (scope_info.st_dev, scope_info.st_ino) != (result["device"], result["inode"]):
            raise AppError("已确认的目录身份发生变化。")
        batch = {"id": str(uuid.uuid4()).upper(), "date": self.clock(), "receipts": []}
        removed = []
        failed = []
        budget = ReadBudget()
        for group in result["groups"]:
            group_files = [item for item in group["files"] if not item.get("moved")]
            moving = [item for item in group_files if item["id"] in chosen]
            if not moving:
                continue
            keepers = [self._proofs[item["id"]] for item in group_files if item["id"] not in chosen]
            if not keepers:
                failed.append({"itemID": group["id"], "message": "每组至少保留一个实物。"})
                continue
            for item in moving:
                try:
                    proof = self._proofs[item["id"]]
                    source = proof["path"]
                    if (item.get("protectionReason") or protection_reason(source, self.home, self._special_folders)
                            or not source.is_relative_to(scope)):
                        raise AppError(item.get("protectionReason") or "该文件不在当前允许的范围内。")
                    current = checked_stat(source)
                    if current.st_nlink != 1:
                        raise AppError("源文件出现新的硬链接。")
                    if not owned_by_current_user(source, current):
                        raise AppError("文件所有者不是当前用户或无法核实。")
                    witness = None
                    for keeper in keepers:
                        try:
                            matches = _equal(proof, keeper, group["byteCount"], budget, group["sha256"])
                        except BudgetSpent:
                            raise
                        except (OSError, AppError):
                            continue
                        if matches:
                            witness = keeper
                            break
                    if witness is None:
                        raise AppError("源文件或准备保留的实物已变化。")
                    with _open(witness["path"], witness["proof"]):
                        stage_dir = self._stage_location(source)
                        stage = stage_dir / (item["id"] + source.suffix)
                        receipt = {"id": item["id"], "original": str(source), "stage": str(stage), "trash": None,
                                   "sha256": item["sha256"], "identity": proof["proof"], "state": "prepared"}
                        if not batch["receipts"]:
                            self.journal["batches"].append(batch)
                        batch["receipts"].append(receipt)
                        self._save()
                        rename_exclusive(source, stage, expected=proof["proof"])
                        receipt["state"] = "staged"
                        self._save()
                        item["moved"] = True
                    destination = local_path(self.trash(stage))
                    if identity(checked_stat(destination)) != proof["proof"] or os.path.lexists(stage):
                        raise AppError("无法核实系统回收站中的副本，保留恢复记录。")
                    receipt.update(trash=str(destination), state="trashed")
                    self._save()
                    removed.append(item["id"])
                except (OSError, AppError) as error:
                    failed.append({"itemID": item["id"], "message": str(error)})
                    if self.failure:
                        break
            if self.failure:
                break
        if not removed and not failed:
            raise AppError("没有可移动的副本，请重新分析。")
        return {"removedIDs": removed, "failed": failed, "batchID": batch["id"] if batch["receipts"] else None,
                "message": f"回收站已核实 {len(removed)} 项，另有 {len(failed)} 项未完成。"}

    def _stage_location(self, source):
        private = local_path(self.stage_dir)
        base_info = checked_stat(private.parent)
        stage = private if checked_stat(source).st_dev == base_info.st_dev else source.parent / STAGE_NAME
        stage.mkdir(exist_ok=True)
        if not stat.S_ISDIR(checked_stat(stage).st_mode):
            raise AppError("无法核实用于恢复的暂存目录。")
        return stage

    def restore(self, batch_id: str | None = None) -> dict:
        with self._lock:
            return self._restore(batch_id)

    def _restore(self, batch_id):
        if self.failure:
            raise self.failure
        restored, failed = [], []
        budget = ReadBudget()
        for batch in reversed(self.journal["batches"]):
            if batch_id and batch["id"] != batch_id:
                continue
            for receipt in batch["receipts"]:
                if receipt["state"] == "restored":
                    continue
                try:
                    source = local_path(receipt.get("trash") or receipt["stage"])
                    original = local_path(receipt["original"])
                    if os.path.lexists(original):
                        raise AppError("原位置已有新文件，未覆盖。")
                    current = checked_stat(source)
                    checked_stat(original.parent)
                    if not owned_by_current_user(source, current):
                        raise AppError("暂存文件的所有者无法核实。")
                    proof = receipt.get("identity") or identity(current)
                    if _sha(source, budget, proof) != receipt["sha256"]:
                        raise AppError("暂存内容已变化，未恢复。")
                    rename_exclusive(source, original, expected=proof)
                    receipt["state"] = "restored"
                    self._save()
                    restored.append(receipt["id"])
                except (OSError, AppError) as error:
                    failed.append({"itemID": receipt["id"], "message": str(error)})
                    if self.failure:
                        break
            break
        return {"restored": restored, "failed": failed,
                "message": f"已恢复 {len(restored)} 项，另有 {len(failed)} 项未完成。"}
