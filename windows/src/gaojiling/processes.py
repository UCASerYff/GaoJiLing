"""用进程名判断已知开发工具是否仍在运行。判断不了就返回 None，调用方必须跳过。"""

from __future__ import annotations

import os
import stat
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import blocked, checked_stat, local_path

_TOOLS = {
    "developer.npm": {"node", "npm", "pnpm", "yarn", "node.exe", "npm.cmd"},
    "developer.pip": {"python", "python3", "pip", "pip3", "python.exe", "pip.exe"},
    "developer.pypoetry": {"poetry", "poetry.exe"},
    "developer.homebrew": {"brew"},
    "developer.gradle": {"java", "javaw", "gradle", "java.exe", "javaw.exe"},
    "com.apple.dt.xcode": {"xcode", "xcodebuild"},
}

_OWNERS = {
    "windows.google.chrome": ("google chrome", {"google llc", "google inc."}, ("chrome.exe", "chrome_crashpad_handler.exe"),
                              (("Google", "Chrome", "Application"),)),
    "windows.microsoft.vscode": ("microsoft visual studio code", {"microsoft corporation"}, ("code.exe",),
                                 (("Microsoft VS Code",), ("Programs", "Microsoft VS Code"))),
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
    from gaojiling.winmetrics import windows_process_entries
    entries = windows_process_entries()
    return {name.casefold() for _, name in entries} if entries is not None else None


def tool_running(owner: str, names: set[str] | None = None):
    expected = _TOOLS.get(owner.lower())
    if not expected:
        return None
    found = process_names() if names is None else names
    if found is None:
        return None
    return any(name.lower() in found for name in expected)


def _registered_owner(owner):
    values = _OWNERS.get(owner)
    if values is None or os.name != "nt":
        return None
    from gaojiling.apps import list_windows_uninstall

    label, publishers, executables, layouts = values
    roots = [Path(value) for key in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA") if (value := os.getenv(key))]
    known_roots = {base.joinpath(*parts) for base in roots for parts in layouts}
    matched = set()
    for item in list_windows_uninstall():
        name, publisher, install = item["name"].casefold(), item["publisher"].casefold(), item["path"]
        if name not in {label, label + " (user)"} or publisher not in publishers or not install:
            continue
        try:
            path = local_path(Path(install))
            info = checked_stat(path / executables[0]) if path in known_roots else None
            if info and stat.S_ISREG(info.st_mode):
                matched.add(path)
        except (OSError, AppError):
            continue
    return matched, set(executables)


def cleanup_owner_installed(owner):
    result = _registered_owner(owner)
    return bool(result[0]) if result is not None else None


def cleanup_owner_running(owner):
    if owner.casefold() in _TOOLS:
        return tool_running(owner)
    result = _registered_owner(owner)
    if result is None or not result[0]:
        return None
    _, names = result
    # Any known executable may touch a user cache, even if this instance runs
    # from a second copy of the same application.
    found = process_names()
    if found is None:
        return None
    return bool(found & names)


def process_running_under(path, executable_names=None):
    """Return None when a process that could belong to this app is inaccessible."""
    if os.name != "nt":
        return None
    from gaojiling.winmetrics import process_inventory

    folder = local_path(Path(path))
    target_names = {name.casefold() for name in executable_names or ()}
    if executable_names is None:
        try:
            checked_stat(folder)
            count = 0

            def stop_walk(error):
                raise error

            for current, directories, files in os.walk(folder, followlinks=False, onerror=stop_walk):
                for name in directories + files:
                    count += 1
                    if count > 100_000 or blocked(os.lstat(Path(current) / name)):
                        return None
                target_names.update(name.casefold() for name in files if name.casefold().endswith(".exe"))
        except (OSError, AppError):
            return None
    rows = process_inventory()
    if rows is None or not target_names:
        return None
    uncertain = False
    for process in rows:
        image = process["path"]
        if image and Path(image).is_relative_to(folder):
            return True
        if process["name"].casefold() in target_names:
            # Even a process launched from another location might have been
            # opened through the old name immediately before a staged rename.
            uncertain = True
    return None if uncertain else False
