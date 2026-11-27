"""Opt-in interactive Windows smoke with a dedicated temporary data directory."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaojiling import win32 as win
from gaojiling.appwindow import PROCESS, READY
from gaojiling.desktop import _ACTIVATE_MESSAGE, _WINDOW_CLASS
from gaojiling.version import MARKETING


def until(read, message, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = read()
        if value:
            return value
        time.sleep(0.15)
    raise AssertionError(message)


def smoke(data: Path, launcher):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen([*launcher, "--startup", "--data-dir", str(data), "--port", str(port)])
    url = f"http://127.0.0.1:{port}/"
    token = None

    def page():
        if process.poll() is not None:
            raise RuntimeError(f"Desktop process exited early ({process.returncode})")
        try:
            with urllib.request.urlopen(url, timeout=0.5) as request:
                return request.read().decode("utf-8")
        except urllib.error.URLError:
            return None

    def api(name, data=None):
        headers = {"X-Gao-Token": token, "Content-Type": "application/json"}
        body = None if data is None else json.dumps(data).encode("utf-8")
        with urllib.request.urlopen(urllib.request.Request(url + "api/" + name, data=body, headers=headers), timeout=7) as response:
            return json.load(response)

    def tracked_window(title):
        for marker in data.glob("DesktopWebView/window-*/" + READY):
            pid = int((marker.parent / PROCESS).read_text(encoding="ascii"))
            hwnd = win.find_view(pid, title)
            if hwnd:
                return hwnd
        return None

    try:
        body = until(page, "Local desktop page did not initialize")
        token = re.search(r'name="gao-token" content="([^"]+)"', body)[1]
        state = api("state")
        print(f"Initial desktop state {state['desktop']}, status {state['message']}", flush=True)
        assert state["desktop"]["available"]
        identity = "GaoJiLing." + hashlib.sha256(os.path.normcase(str(data.resolve())).encode("utf-8")).hexdigest()[:24]
        host = win.find_window(_WINDOW_CLASS, identity)
        assert host
        pid = win.w.DWORD()
        win.window_pid(host, ctypes.byref(pid))
        strip = until(lambda: win.find_view(pid.value, "搞机灵唤起条"), "The desktop strip was not visible")
        foreground = win.user.GetForegroundWindow
        foreground.restype = win.w.HWND
        foreground.argtypes = ()
        previous = foreground()
        win.post_message(host, win.WM_HOTKEY, 1, 0)
        panel = until(lambda: win.find_view(pid.value, "搞机灵监控面板"), "Hotkey did not show the panel")
        assert panel != strip and foreground() == previous, "The panel activated another top-level window"
        win.post_message(host, win.WM_HOTKEY, 1, 0)
        until(lambda: not win.window_visible(panel), "Repeating the hotkey did not collapse the panel")
        assert win.window_visible(strip)

        api("desktop/settings", {"tab": "data"})
        settings = until(lambda: tracked_window("搞机灵设置"), "WebView2 settings window did not load", 30)
        win.post_message(host, _ACTIVATE_MESSAGE, 0, 0)
        main = until(lambda: tracked_window(f"搞机灵 V{MARKETING}"), "WebView2 main window did not load", 30)
        assert settings != main and api("state")["desktop"]["view"] == "webview2"
        api("shutdown", {})
        process.wait(20)
        until(lambda: not win.window_visible(settings) and not win.window_visible(main), "Independent windows survived tray exit")
        print("Desktop strip, non-activating hotkey panel, and native WebView2 main and settings windows verified.")
    finally:
        if process.poll() is None and token:
            try:
                api("shutdown", {})
                process.wait(15)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path)
    args = parser.parse_args()
    launch = [str(args.exe.resolve(strict=True))] if args.exe else [sys.executable, str(ROOT / "launch.py")]
    with tempfile.TemporaryDirectory(prefix="gaojiling-desktop-smoke-") as scratch:
        smoke(Path(scratch), launch)
