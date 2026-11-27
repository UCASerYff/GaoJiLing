"""Local filesystem objects and metadata, without following reparse points."""

from __future__ import annotations

import os
import re
import stat
from contextlib import contextmanager
from pathlib import Path

from gaojiling.errors import AppError

OFFLINE_ATTRIBUTES = 0x1000 | 0x40000 | 0x400000
REPARSE_POINT = 0x400
RESERVED = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?\Z", re.I)


def local_path(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    if os.name == "nt":
        import ctypes

        if (not re.fullmatch(r"[A-Za-z]:", path.drive)
                or any(":" in part or part.endswith((" ", ".")) or RESERVED.fullmatch(part) for part in path.parts[1:])
                or ctypes.windll.kernel32.GetDriveTypeW(path.anchor) not in {2, 3, 5, 6}):
            raise AppError("只接受本机普通文件或目录路径。设备、网络和命名流路径不支持。")
    return path


def blocked(info: os.stat_result) -> str | None:
    attributes = getattr(info, "st_file_attributes", 0)
    if attributes & OFFLINE_ATTRIBUTES:
        return "placeholder"
    if attributes & REPARSE_POINT or stat.S_ISLNK(info.st_mode):
        return "symlink"
    return None


def identity(info: os.stat_result) -> dict:
    return {"device": int(info.st_dev), "inode": int(info.st_ino),
            "size": int(info.st_size), "mtime": int(info.st_mtime_ns)}


def checked_stat(path: Path) -> os.stat_result:
    for component in (*reversed(path.parents), path):
        info = os.lstat(component)
        if blocked(info):
            raise AppError("路径含符号链接、挂载点、重解析点或云端占位，已跳过。")
    return info


def _windows_handle(path: Path, access: int, share: int):
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    create.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.GetFileInformationByHandleEx.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    # OPEN_REPARSE_POINT, BACKUP_SEMANTICS and OPEN_NO_RECALL keep the operation metadata-only
    # until the handle has been checked and support directories for metadata queries.
    handle = create(str(path), access, share, None, 3, 0x00200000 | 0x02000000 | 0x00100000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    tag = (wintypes.DWORD * 2)()
    if not kernel.GetFileInformationByHandleEx(handle, 9, tag, ctypes.sizeof(tag)) or tag[0] & (REPARSE_POINT | OFFLINE_ATTRIBUTES):
        kernel.CloseHandle(handle)
        raise AppError("无法确认文件不是重解析点或云端占位，已跳过。")
    return kernel, handle


def open_regular(path: Path) -> tuple[int, os.stat_result]:
    path = local_path(path)
    before = checked_stat(path)
    if not stat.S_ISREG(before.st_mode):
        raise AppError("只读取本机普通文件。")
    if os.name == "nt":
        import msvcrt

        kernel, handle = _windows_handle(path, 0x80000000, 1)
        try:
            fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
        except Exception:
            kernel.CloseHandle(handle)
            raise
    else:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        after = os.fstat(fd)
        current = checked_stat(path)
        if not stat.S_ISREG(after.st_mode) or identity(after) != identity(before) or identity(current) != identity(after):
            raise AppError("文件身份或内容在打开期间已变化。")
        return fd, after
    except Exception:
        os.close(fd)
        raise


@contextmanager
def directory_entries(path: Path, expected: os.stat_result):
    before = identity(expected)
    current = checked_stat(path)
    if not stat.S_ISDIR(current.st_mode) or identity(current) != before:
        raise AppError("目录在枚举前发生变化。")
    if os.name == "nt":
        kernel, handle = _windows_handle(path, 0x80, 1 | 2)
        try:
            with os.scandir(path) as entries:
                yield entries
        finally:
            kernel.CloseHandle(handle)
    else:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            if identity(os.fstat(fd)) != before:
                raise AppError("目录在打开时发生变化。")
            with os.scandir(fd) as entries:
                yield entries
        finally:
            os.close(fd)
    if identity(checked_stat(path)) != before:
        raise AppError("目录在枚举时发生变化。")


def allocation(path: Path, info: os.stat_result) -> int:
    if os.name != "nt":
        return max(0, int(getattr(info, "st_blocks", 0)) * 512)

    import ctypes

    class StandardInfo(ctypes.Structure):
        _fields_ = [("allocation_size", ctypes.c_longlong), ("end_of_file", ctypes.c_longlong),
                    ("number_of_links", ctypes.c_ulong), ("delete_pending", ctypes.c_ubyte),
                    ("directory", ctypes.c_ubyte)]

    kernel, handle = _windows_handle(path, 0x80, 1 | 2 | 4)
    try:
        details = StandardInfo()
        if not kernel.GetFileInformationByHandleEx(handle, 1, ctypes.byref(details), ctypes.sizeof(details)):
            raise ctypes.WinError(ctypes.get_last_error())
        if identity(os.lstat(path)) != identity(info) or details.delete_pending:
            raise AppError("读取分配空间期间文件身份已变化。")
        return max(0, int(details.allocation_size))
    finally:
        kernel.CloseHandle(handle)
