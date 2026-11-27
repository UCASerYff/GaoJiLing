"""Per-user sign-in shortcut. Isolated runs never access Windows startup settings."""

from __future__ import annotations

import base64
import os
from pathlib import Path
import subprocess
import sys
import uuid

from gaojiling.errors import AppError


SHORTCUT_NAME = "GaoJiLing Startup.lnk"
_SHORTCUT_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($env:GAOJILING_SHORTCUT)
if ($env:GAOJILING_LINK_OPERATION -eq 'read') {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    Write-Output $link.TargetPath
    Write-Output $link.Arguments
} else {
    $link.TargetPath = $env:GAOJILING_EXE
    $link.Arguments = '--startup'
    $link.Description = 'GaoJiLing'
    $link.Save()
}
"""


def _link_command(path: Path, executable: Path, operation: str) -> str:
    powershell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    script = base64.b64encode(_SHORTCUT_SCRIPT.encode("utf-16-le")).decode("ascii")
    env = {**os.environ, "GAOJILING_SHORTCUT": str(path), "GAOJILING_EXE": str(executable),
           "GAOJILING_LINK_OPERATION": operation}
    result = subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-EncodedCommand", script],
                            env=env, capture_output=True, timeout=12, check=True,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    return result.stdout.decode("utf-8").strip()


def _startup_directory() -> Path:
    from ctypes import OleDLL, POINTER, byref, c_void_p, c_wchar_p, cast, windll
    from ctypes.wintypes import HANDLE

    folder = (uuid.UUID("b97d20bb-f46a-4c97-ba10-5e3608430854").bytes_le)
    from ctypes import c_ubyte

    identifier = (c_ubyte * len(folder)).from_buffer_copy(folder)
    target = c_void_p()
    get_folder = OleDLL("shell32").SHGetKnownFolderPath
    get_folder.argtypes = (POINTER(c_ubyte), c_void_p, HANDLE, POINTER(c_void_p))
    get_folder(identifier, None, None, byref(target))
    release = windll.ole32.CoTaskMemFree
    release.argtypes = (c_void_p,)
    try:
        return Path(cast(target, c_wchar_p).value)
    finally:
        release(target)


class Startup:
    def __init__(self, executable: Path | None = None, directory: Path | None = None, link_command=_link_command):
        self.executable = executable
        self.link = directory / SHORTCUT_NAME if directory else None
        self.link_command = link_command
        self.reason = None if self.link else "仅安装版使用默认资料目录启动时可设置登录启动。"
        self._verified = None

    @classmethod
    def for_launch(cls, default_data: bool):
        from gaojiling.version import BUNDLE_ID

        if os.name != "nt" or not default_data or not getattr(sys, "frozen", False):
            return cls()
        executable = Path(sys.executable).resolve()
        try:
            import winreg

            # The MSI publishes its exact install directory as a component keypath.
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Software\\GaoSeries\\" + BUNDLE_ID) as key:
                registered, _ = winreg.QueryValueEx(key, "InstallDirectory")
            if executable.name.casefold() != "gaojiling.exe" or Path(registered).resolve() != executable.parent:
                return cls()
            return cls(executable, _startup_directory())
        except FileNotFoundError:
            return cls()
        except (OSError, ValueError) as error:
            instance = cls()
            instance.reason = f"Windows 未能读取本应用的启动登记：{error}"
            return instance

    def _registered(self) -> bool:
        if not self.link.exists() and not self.link.is_symlink():
            return False
        info = self.link.lstat()
        if not self.link.is_file() or self.link.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
            raise AppError("启动文件夹内有同名但归属未确认的条目，原条目保留。")
        signature = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if signature == self._verified:
            return True
        parts = self.link_command(self.link, self.executable, "read").splitlines()
        if len(parts) != 2 or Path(parts[0]).resolve() != self.executable or parts[1] != "--startup":
            raise AppError("启动文件夹内有同名但归属未确认的条目，原条目保留。")
        self._verified = signature
        return True

    def _approved(self):
        if os.name != "nt":
            return None
        import winreg

        try:
            key_path = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path) as key:
                value, value_type = winreg.QueryValueEx(key, SHORTCUT_NAME)
        except FileNotFoundError:
            return None
        if value_type == winreg.REG_BINARY and value:
            if value[0] in (3, 7):
                return False
            if value[0] in (2, 6):
                return True
        return None

    def status(self) -> dict:
        if self.link is None:
            return {"available": False, "enabled": False, "reason": self.reason}
        try:
            registered = self._registered()
            blocked = registered and self._approved() is False
            return {"available": True, "enabled": registered and not blocked, "registered": registered,
                    "reason": "登录启动已被系统停用，请在 Windows 设置 → 应用 → 启动中调整。" if blocked else None}
        except (AppError, OSError, UnicodeError, subprocess.SubprocessError) as error:
            return {"available": False, "enabled": False, "reason": str(error)}

    def set_enabled(self, enabled: bool):
        if self.link is None:
            raise AppError(self.reason)
        try:
            exists = self._registered()
            if enabled == exists:
                return
            if not enabled:
                self.link.unlink()
                self._verified = None
                return
            temporary = self.link.parent / ("GaoJiLing-" + uuid.uuid4().hex + ".lnk")
            try:
                self.link_command(temporary, self.executable, "write")
                temporary.rename(self.link)  # Windows refuses a race against another named entry.
            finally:
                temporary.unlink(missing_ok=True)
        except (OSError, UnicodeError, subprocess.SubprocessError) as error:
            raise AppError(f"Windows 未能修改登录启动：{error}") from error
