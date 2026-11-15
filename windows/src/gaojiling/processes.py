"""用进程名判断已知开发工具是否仍在运行。判断不了就返回 None，调用方必须跳过。"""

from __future__ import annotations

import os

_TOOLS = {
    "developer.npm": {"node", "npm", "pnpm", "yarn", "node.exe", "npm.cmd"},
    "developer.pip": {"python", "python3", "pip", "pip3", "python.exe", "pip.exe"},
    "developer.pypoetry": {"poetry", "poetry.exe"},
    "developer.homebrew": {"brew"},
    "developer.gradle": {"java", "javaw", "gradle", "java.exe", "javaw.exe"},
    "com.apple.dt.xcode": {"xcode", "xcodebuild"},
}


def process_names() -> set[str] | None:
    try:
        if os.name == "nt":
            return _windows_names()
        names = set()
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                names.add(open(f"/proc/{entry}/comm", encoding="utf-8").read().strip().lower())
            except OSError:
                continue
        return names
    except OSError:
        return None


def _windows_names() -> set[str] | None:
    import ctypes
    from ctypes import wintypes
    snapshot = ctypes.windll.kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        return None

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
            ("szExeFile", ctypes.c_wchar * 260),
        ]

    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(entry)
    names = set()
    try:
        ok = ctypes.windll.kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            names.add(entry.szExeFile.lower())
            ok = ctypes.windll.kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        ctypes.windll.kernel32.CloseHandle(snapshot)
    return names


def tool_running(owner: str, names: set[str] | None = None):
    expected = _TOOLS.get(owner.lower())
    if not expected:
        return None
    found = process_names() if names is None else names
    if found is None:
        return None
    return any(name.lower() in found for name in expected)
