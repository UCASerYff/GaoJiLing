"""路径与原子替换。不保留被替换文件的副本。"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

from gaojiling.errors import AppError


def same_volume(left: Path, right: Path) -> bool:
    try:
        return os.lstat(left).st_dev == os.lstat(right).st_dev
    except OSError:
        return False


def is_symlink(path: Path) -> bool:
    try:
        return Path(path).is_symlink()
    except OSError:
        return False


def rename_exclusive(source: Path, destination: Path):
    """目标已存在时不覆盖。同一用户的并发替换仍可能发生，调用方要在事后复核身份。"""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise AppError("原位置已有文件，未覆盖。")
    os.rename(source, destination)
    if source.exists() or not destination.exists():
        raise AppError("移动后身份未确认，已停止。")


def atomic_text(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".write-{uuid.uuid4().hex}")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def within(path: Path, scope: Path) -> bool:
    try:
        target = Path(path).resolve()
        root = Path(scope).resolve()
    except OSError:
        return False
    if target == root:
        return False
    try:
        target.relative_to(root)
        return True
    except ValueError:
        return False


def send_to_trash(path: Path) -> Path:
    """把已经暂存好的项目送进系统回收站。失败时不永久删除。"""
    if os.name != "nt":
        raise AppError("当前环境没有废纸篓接口，未移动文件。")
    return _windows_recycle(Path(path))


def _windows_recycle(path: Path) -> Path:
    import ctypes
    from ctypes import wintypes

    class SHFILEOPSTRUCTW(ctypes.Structure):
        _fields_ = [
            ("hwnd", wintypes.HWND),
            ("wFunc", ctypes.c_uint),
            ("pFrom", wintypes.LPCWSTR),
            ("pTo", wintypes.LPCWSTR),
            ("fFlags", ctypes.c_ushort),
            ("fAnyOperationsAborted", wintypes.BOOL),
            ("hNameMappings", ctypes.c_void_p),
            ("lpszProgressTitle", wintypes.LPCWSTR),
        ]

    operation = SHFILEOPSTRUCTW()
    operation.wFunc = 3  # FO_DELETE
    operation.pFrom = str(path) + "\0\0"
    # ALLOWUNDO 才会进回收站。缺少这个标志时，删除是永久的，所以这里固定带上。
    operation.fFlags = 0x0040 | 0x0010 | 0x0004 | 0x0400
    code = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(operation))
    if code != 0 or operation.fAnyOperationsAborted:
        raise AppError(f"未能移入回收站（{code}）。暂存文件会尝试放回，不会改为永久删除。")
    found = _recycled_path(path)
    # 系统已经收下文件。找不到新路径时仍返回原暂存路径，恢复会说明找不到，
    # 而不是在文件已经进回收站之后把这次操作记成失败。
    return found if found is not None else path


def _recycled_path(original: Path) -> Path | None:
    needle = str(original).encode("utf-16le")
    drive = os.environ.get("SYSTEMDRIVE", "C:")
    root = Path(drive + "\\$Recycle.Bin")
    if not root.exists():
        return None
    try:
        folders = [item for item in root.iterdir() if item.is_dir() and not item.is_symlink()]
    except OSError:
        return None
    for folder in folders:
        try:
            entries = [item for item in folder.iterdir() if item.is_file() and not item.is_symlink() and item.name.startswith("$I")]
        except OSError:
            continue
        for info in entries:
            try:
                data = info.read_bytes()
            except OSError:
                continue
            if needle not in data:
                continue
            restored = folder / ("$R" + info.name[2:])
            if restored.exists() and not restored.is_symlink():
                return restored
    return None


def stat_alloc(info: os.stat_result) -> int:
    blocks = getattr(info, "st_blocks", None)
    if blocks is None:
        return max(0, int(info.st_size))
    return max(0, int(blocks) * 512)
