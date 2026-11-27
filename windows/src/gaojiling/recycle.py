"""Shell-only Recycle Bin operations, with a verified recovery destination."""

from __future__ import annotations

import ctypes as ct
import os
import stat
import uuid
from ctypes import wintypes as wt
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import checked_stat, identity, local_path
from gaojiling.winmetrics import Guid, bind


_CLS_FILE_OP = "3ad05575-8857-4850-9277-11b85bdb8e09"
_IID_FILE_OP = "947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"
_IID_SHELL_ITEM = "43826d1e-e718-42ee-bc55-a1e261c37bfe"
_SINK_IFACES = {
    uuid.UUID("00000000-0000-0000-c000-000000000046").bytes_le,  # IUnknown
    uuid.UUID("04b0f1a7-9490-44bc-96e1-4296a31252e2").bytes_le,
}
_E_ABORT = -2147467260
_E_NOINTERFACE = -2147467262
_RECYCLE_TRANSFER = 0x80  # TSF_DELETE_RECYCLE_IF_POSSIBLE
_RECYCLE_FLAGS = (
    0x0004       # FOF_SILENT
    | 0x0010     # FOF_NOCONFIRMATION; review already occurred in the app
    | 0x0040     # FOF_ALLOWUNDO
    | 0x0400     # FOF_NOERRORUI
    | 0x2000     # FOF_NO_CONNECTED_ELEMENTS
    | 0x80000    # FOFX_RECYCLEONDELETE
    | 0x100000   # FOFX_EARLYFAILURE
)
_PTR = ct.c_void_p
_RESULT = wt.LONG


def _guid(text):
    return ct.byref(Guid.from_buffer_copy(uuid.UUID(text).bytes_le))


def _call(obj, index, result, arguments, *values):
    table = ct.cast(obj, ct.POINTER(ct.POINTER(_PTR))).contents
    function = ct.WINFUNCTYPE(result, _PTR, *arguments)(table[index])
    return function(obj, *values)


def _must(result, operation):
    if result < 0:
        raise AppError(f"{operation}（0x{result & 0xFFFFFFFF:08X}）。")


def _shell_path(item, ole, scheme):
    result = _PTR()
    if _call(item, 5, _RESULT, (wt.DWORD, ct.POINTER(_PTR)), scheme, ct.byref(result)) < 0 or not result:
        return None
    try:
        return Path(ct.wstring_at(result))
    finally:
        ole.CoTaskMemFree(result)


def _recovery_path(item, ole, source, expected):
    for scheme in (0x80058000, 0x80028000):  # SIGDN_FILESYSPATH / DESKTOPABSOLUTEPARSING
        destination = _shell_path(item, ole, scheme)
        if not destination or not destination.is_absolute():
            continue
        destination = local_path(destination)
        if (destination.drive.casefold() != source.drive.casefold()
                or len(destination.parts) != 4 or destination.parts[1].casefold() != "$recycle.bin"
                or not destination.name.startswith("$R")):
            continue
        try:
            if identity(checked_stat(destination)) == expected:
                return destination
        except (OSError, AppError):
            continue
    return None


class _ProgressSink:
    def __init__(self, source, expected, ole):
        self.destination = None
        self.error = None
        self.refcount = 1
        self.callbacks = []

        def callback(function, arguments=(), result=_RESULT):
            typed = ct.WINFUNCTYPE(result, _PTR, *arguments)(function)
            self.callbacks.append(typed)
            return ct.cast(typed, _PTR)

        def query(this, iid, output):
            if iid and output and ct.string_at(iid, 16) in _SINK_IFACES:
                output[0] = this
                self.refcount += 1
                return 0
            if output:
                output[0] = None
            return _E_NOINTERFACE

        def add_ref(_this):
            self.refcount += 1
            return self.refcount

        def release(_this):
            self.refcount -= 1
            return self.refcount

        def okay(_this, *_args):
            return 0

        def pre_delete(_this, flags, item):
            try:
                if not flags & _RECYCLE_TRANSFER:
                    raise AppError("该磁盘或系统策略未确认使用回收站，已停止。")
                actual = _shell_path(item, ole, 0x80058000)
                if actual is None or actual != source or identity(checked_stat(source)) != expected:
                    raise AppError("回收前项目身份已变化，已停止。")
                return 0
            except (AppError, OSError) as error:
                self.error = str(error)
                return _E_ABORT

        def post_delete(_this, _flags, _item, status, new_item):
            if status < 0 or not new_item:
                self.error = f"Windows 未确认已回收（0x{status & 0xFFFFFFFF:08X}）。"
                return 0
            try:
                self.destination = _recovery_path(new_item, ole, source, expected)
            except (AppError, OSError):
                self.destination = None
            if self.destination is None:
                self.error = "Windows 回收站未返回可核实的恢复位置，请在系统回收站检查该批次。"
            return 0

        flags, item, path = wt.DWORD, _PTR, wt.LPCWSTR
        methods = [
            callback(query, (_PTR, ct.POINTER(_PTR))),
            callback(add_ref, result=wt.ULONG),
            callback(release, result=wt.ULONG),
            callback(okay),  # StartOperations
            callback(okay, (_RESULT,)),
            callback(okay, (flags, item, path)),
            callback(okay, (flags, item, path, _RESULT, item)),
            callback(okay, (flags, item, item, path)),
            callback(okay, (flags, item, item, path, _RESULT, item)),
            callback(okay, (flags, item, item, path)),
            callback(okay, (flags, item, item, path, _RESULT, item)),
            callback(pre_delete, (flags, item)),
            callback(post_delete, (flags, item, _RESULT, item)),
            callback(okay, (flags, item, path)),
            callback(okay, (flags, item, path, path, flags, _RESULT, item)),
            callback(okay, (wt.UINT, wt.UINT)),
            callback(okay), callback(okay), callback(okay),
        ]
        self.table = (_PTR * len(methods))(*methods)
        self.instance = ct.pointer(ct.cast(self.table, ct.POINTER(_PTR)))


def recycle(path: Path) -> Path:
    path = local_path(path)
    before = checked_stat(path)
    if (not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode)) or len(path.parts) < 3
            or any(part.casefold() == "$recycle.bin" for part in path.parts)):
        raise AppError("只将已复核的普通文件或目录移入回收站。")
    expected = identity(before)
    ole = ct.WinDLL("ole32")
    shell = ct.WinDLL("shell32")
    bind(ole, "CoInitializeEx", _RESULT, _PTR, wt.DWORD)
    bind(ole, "CoUninitialize", None)
    bind(ole, "CoTaskMemFree", None, _PTR)
    create = bind(ole, "CoCreateInstance", _RESULT, ct.POINTER(Guid), _PTR, wt.DWORD,
                  ct.POINTER(Guid), ct.POINTER(_PTR))
    parse = bind(shell, "SHCreateItemFromParsingName", _RESULT, wt.LPCWSTR, _PTR,
                 ct.POINTER(Guid), ct.POINTER(_PTR))
    _must(ole.CoInitializeEx(None, 2), "无法初始化 Windows 回收接口")  # COINIT_APARTMENTTHREADED
    operation, item = _PTR(), _PTR()
    sink = _ProgressSink(path, expected, ole)
    try:
        _must(create(_guid(_CLS_FILE_OP), None, 1, _guid(_IID_FILE_OP), ct.byref(operation)), "Windows 回收接口不可用")
        _must(parse(str(path), None, _guid(_IID_SHELL_ITEM), ct.byref(item)), "无法复核待回收项目")
        _must(_call(operation, 5, _RESULT, (wt.DWORD,), _RECYCLE_FLAGS), "无法设定只回收")
        _must(_call(operation, 18, _RESULT, (_PTR, _PTR), item, ct.cast(sink.instance, _PTR)), "无法提交待回收项目")
        result = _call(operation, 21, _RESULT, ())
        if sink.error:
            raise AppError(sink.error)
        _must(result, "移入回收站失败")
        aborted = wt.BOOL()
        _must(_call(operation, 22, _RESULT, (ct.POINTER(wt.BOOL),), ct.byref(aborted)), "无法核实回收结果")
        if aborted.value or sink.destination is None or os.path.lexists(path):
            raise AppError("回收站未确认完成，已保留恢复记录。")
        return sink.destination
    finally:
        for obj in (item, operation):
            if obj:
                _call(obj, 2, wt.ULONG, ())
        ole.CoUninitialize()
