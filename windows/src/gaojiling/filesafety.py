"""路径与原子替换。不保留被替换文件的副本。"""

from __future__ import annotations

import os
import stat
import uuid
from pathlib import Path
from functools import lru_cache

from gaojiling.errors import AppError
from gaojiling.filemeta import checked_stat, identity, local_path


def same_volume(left: Path, right: Path) -> bool:
    try:
        return os.lstat(left).st_dev == os.lstat(right).st_dev
    except OSError:
        return False


@lru_cache(maxsize=1)
def _security_api():
    import ctypes as ct
    from ctypes import wintypes as wt
    from gaojiling.winmetrics import bind

    api = ct.WinDLL("advapi32", use_last_error=True)
    ptr = ct.POINTER(ct.c_void_p)
    bind(api, "GetSecurityInfo", wt.DWORD, wt.HANDLE, wt.DWORD, wt.DWORD, ptr, ptr, ptr, ptr, ptr)
    bind(api, "ConvertSidToStringSidW", wt.BOOL, ct.c_void_p, ct.POINTER(wt.LPWSTR))
    return api


def owned_by_current_user(path, info):
    if os.name != "nt":
        return info.st_uid == os.getuid()

    import ctypes as ct
    from ctypes import wintypes as wt
    from gaojiling.filemeta import _windows_handle
    from gaojiling.winmetrics import current_owner_sid, kernel

    wanted = current_owner_sid()
    if not wanted:
        return False
    owner, security = ct.c_void_p(), ct.c_void_p()
    _, handle = _windows_handle(path, 0x20000, 7)  # READ_CONTROL
    api = _security_api()
    try:
        if api.GetSecurityInfo(handle, 1, 1, ct.byref(owner), None, None, None, ct.byref(security)) != 0:
            return False
        if not owner:
            return False
        name = wt.LPWSTR()
        if not api.ConvertSidToStringSidW(owner, ct.byref(name)):
            return False
        try:
            return name.value == wanted
        finally:
            kernel().LocalFree(ct.cast(name, wt.HLOCAL))
    finally:
        if security:
            kernel().LocalFree(security)
        kernel().CloseHandle(handle)


def is_symlink(path: Path) -> bool:
    try:
        return Path(path).is_symlink()
    except OSError:
        return False


def rename_exclusive(source: Path, destination: Path, expected: dict | None = None):
    """将经过核实的对象移动到空目标；Windows 使用已核实的源和目标目录句柄。"""
    source, destination = local_path(source), local_path(destination)
    reference = identity(checked_stat(source))
    if expected is not None and reference != expected:
        raise AppError("移动前项目身份或内容已变化，已停止。")
    if os.path.lexists(destination):
        raise AppError("原位置已有文件，未覆盖。")
    if os.name == "nt":
        _rename_windows(source, destination, reference)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.rename(source, destination)
    if os.path.lexists(source) or identity(checked_stat(destination)) != reference:
        raise AppError("移动后身份未确认，已停止。")


def _rename_windows(source, destination, expected):
    import ctypes as ct
    from ctypes import wintypes as wt
    import msvcrt
    from gaojiling.filemeta import _windows_handle
    from gaojiling.winmetrics import bind

    parent_before = checked_stat(destination.parent)
    if not stat.S_ISDIR(parent_before.st_mode) or parent_before.st_dev != expected["device"]:
        raise AppError("目标目录不可用或跨卷，未移动。")
    api, source_handle = _windows_handle(source, 0x10080, 3)  # DELETE | FILE_READ_ATTRIBUTES
    try:
        source_fd = msvcrt.open_osfhandle(source_handle, os.O_RDONLY | os.O_BINARY)
    except OSError:
        api.CloseHandle(source_handle)
        raise
    try:
        if identity(os.fstat(source_fd)) != expected or identity(checked_stat(source)) != expected:
            raise AppError("移动前项目身份或内容已变化，已停止。")
        _, parent_handle = _windows_handle(destination.parent, 0xA0, 3)  # FILE_READ_ATTRIBUTES | FILE_TRAVERSE
        try:
            parent_fd = msvcrt.open_osfhandle(parent_handle, os.O_RDONLY | os.O_BINARY)
        except OSError:
            api.CloseHandle(parent_handle)
            raise
        try:
            parent_after = os.fstat(parent_fd)
            parent_current = checked_stat(destination.parent)
            parent_identity = (parent_before.st_dev, parent_before.st_ino)
            if any((info.st_dev, info.st_ino) != parent_identity for info in (parent_after, parent_current)):
                raise AppError("移动前目标目录已变化，已停止。")

            full_name = str(destination)
            encoded_length = len(full_name.encode("utf-16le"))

            class RenameInfo(ct.Structure):
                _fields_ = [("replace", wt.DWORD), ("root", wt.HANDLE), ("length", wt.DWORD),
                            ("name", wt.WCHAR * (encoded_length // 2 + 1))]

            data = RenameInfo(0, None, encoded_length, full_name)
            move = bind(api, "SetFileInformationByHandle", wt.BOOL, wt.HANDLE, ct.c_int, ct.c_void_p, wt.DWORD)
            if not move(source_handle, 3, ct.byref(data), ct.sizeof(data)):  # FileRenameInfo
                error = ct.get_last_error()
                if error in {80, 183}:
                    raise AppError("原位置已有文件，未覆盖。")
                raise ct.WinError(error)
        finally:
            os.close(parent_fd)
    finally:
        os.close(source_fd)


def atomic_text(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".write-{uuid.uuid4().hex}")
    created = False
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            created = True
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if created:
            temporary.unlink(missing_ok=True)


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
    from gaojiling.recycle import recycle
    return recycle(path)


def stat_alloc(info: os.stat_result) -> int:
    blocks = getattr(info, "st_blocks", None)
    if blocks is None:
        return max(0, int(info.st_size))
    return max(0, int(blocks) * 512)
