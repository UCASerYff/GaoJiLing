"""Independent native WinForms windows backed by the installed WebView2 Runtime."""

from __future__ import annotations

import os
import sys
from pathlib import Path
import tempfile
from threading import Event
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit

from gaojiling.resources import asset_root
from gaojiling.version import MARKETING


READY = "gaojiling-view-ready"
PROCESS = "gaojiling-view-process"
NAVIGATION = "gaojiling-view-tab"
CLOSE = "gaojiling-view-close"
CLOSING = "gaojiling-view-closing"


def run(url: str, signals: Path, dark: bool) -> int:
    if sys.platform != "win32":
        return 2
    address = urlsplit(url)
    if (address.scheme != "http" or address.hostname != "127.0.0.1" or not address.port or address.path != "/"
            or address.username or address.password or address.fragment or not signals.is_dir()):
        return 2
    (signals / PROCESS).write_text(str(os.getpid()), encoding="ascii")
    from gaojiling.win32 import setup_dpi

    setup_dpi()
    import webview
    from webview.platforms import winforms

    if winforms.renderer != "edgechromium":
        return 3
    webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True
    webview.settings["ALLOW_DOWNLOADS"] = False
    preferences = parse_qs(address.query).get("settings") == ["1"]
    title = "搞机灵设置" if preferences else f"搞机灵 V{MARKETING}"
    width, height = (760, 740) if preferences else (1100, 780)
    background = "#1a1d1f" if dark else "#f5f5f1"
    window = webview.create_window(title, url, width=width, height=height, min_size=(480, 440), background_color=background)
    closed = Event()
    window.events.loaded += lambda: (signals / READY).touch()
    window.events.closed += closed.set
    window.events.closing += lambda: (signals / CLOSING).touch()

    def check_commands():
        request = signals / NAVIGATION
        while not closed.wait(0.2):
            if (signals / CLOSE).is_file():
                window.destroy()
                return
            if not preferences:
                continue
            try:
                tab = request.read_text(encoding="ascii").strip()
                request.unlink()
            except (FileNotFoundError, PermissionError):
                continue
            if tab in {"module", "appearance", "data", "about"}:
                query = urlencode({"settings": 1, "tab": tab})
                window.load_url(urlunsplit(address._replace(query=query)))

    icon = asset_root() / "AppIcon.ico"
    with tempfile.TemporaryDirectory(dir=signals, prefix="private-", ignore_cleanup_errors=True) as lifetime:
        profile = str(Path(lifetime) / "WebView2")
        webview.start(check_commands, gui="edgechromium", private_mode=True,
                      storage_path=profile, icon=str(icon) if icon.is_file() else None)
    return 0
