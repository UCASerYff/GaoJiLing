from ctypes import wintypes
import os
import sys
import time
from types import ModuleType, SimpleNamespace

import pytest


pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows desktop lifecycle")


def test_app_window_registers_process_before_probing_webview2(tmp_path, monkeypatch):
    from gaojiling import appwindow, win32

    webview = ModuleType("webview")
    webview.__path__ = []
    platforms = ModuleType("webview.platforms")
    platforms.winforms = SimpleNamespace(renderer="unavailable")
    monkeypatch.setitem(sys.modules, "webview", webview)
    monkeypatch.setitem(sys.modules, "webview.platforms", platforms)
    monkeypatch.setattr(win32, "setup_dpi", lambda: None)

    assert appwindow.run("http://127.0.0.1:8765/", tmp_path, dark=False) == 3
    assert (tmp_path / appwindow.PROCESS).read_text(encoding="ascii") == str(os.getpid())
    assert not (tmp_path / appwindow.READY).exists()


def test_owned_view_contains_descendants_and_closes_only_its_job(tmp_path):
    from gaojiling import ownedview

    marker = tmp_path / "owned-pids"
    script = (
        "import os, subprocess, sys, time\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(30)'])\n"
        "Path(sys.argv[1]).write_text(f'{os.getpid()} {child.pid}', encoding='ascii')\n"
        "time.sleep(30)\n"
    )
    process = ownedview.OwnedView([sys.executable, "-I", "-c", script, str(marker)])
    handles = []
    wait = ownedview.win._api(ownedview.win.kernel, "WaitForSingleObject", wintypes.DWORD, wintypes.HANDLE, wintypes.DWORD)
    try:
        deadline = time.monotonic() + 10
        pids = []
        while time.monotonic() < deadline:
            try:
                pids = [int(pid) for pid in marker.read_text(encoding="ascii").split()]
            except FileNotFoundError:
                pass
            if len(pids) == 2:
                break
            assert process.is_running()
            time.sleep(0.05)
        assert len(pids) == 2 and all(process.owns(pid) for pid in pids)
        assert not process.owns(os.getpid())
        handles = [ownedview._open_process(0x100000, False, pid) for pid in pids]  # SYNCHRONIZE
        assert all(handles)
        process.close()
        assert all(wait(handle, 3000) == 0 for handle in handles)
    finally:
        process.close()
        for handle in handles:
            if handle:
                ownedview.win.close_handle(handle)


def test_repeated_open_waits_for_one_replacement_window(tmp_path, monkeypatch):
    from gaojiling import desktop

    class Process:
        running = True
        closed = False

        def is_running(self):
            return self.running

        def close(self):
            self.closed = True

    host = desktop.Desktop.__new__(desktop.Desktop)
    host.stopping = False
    host.url = "http://127.0.0.1:8765/"
    host.view_backend = "webview2"
    profile = tmp_path / "window"
    profile.mkdir()
    process = Process()
    view = desktop._View(process, profile, host.url, 0, host.view_backend, ready=True)
    host.views = {"main": view}
    monkeypatch.setattr(desktop, "_view_handle", lambda *_: None)
    started = []
    host._launch_view = lambda *arguments: started.append(arguments)
    host._open_view()
    host._open_view()
    assert (profile / desktop.CLOSE).is_file() and not started and not process.closed
    process.running = False
    host._poll_views(time.monotonic())
    assert process.closed and host.views == {} and not profile.exists()
    assert started == [("main", host.url, "webview2")]


@pytest.mark.parametrize("already_open", [False, True])
def test_explicit_open_is_retained_until_edge_readiness_poll(tmp_path, monkeypatch, already_open):
    from gaojiling import desktop

    class Process:
        running = True

        def is_running(self):
            return self.running

        def close(self):
            self.running = False

    host = desktop.Desktop.__new__(desktop.Desktop)
    host.stopping = False
    host.url = "http://127.0.0.1:8765/"
    host.view_backend = "edge-app"
    profile = tmp_path / "edge"
    profile.mkdir()
    process = Process()
    view = desktop._View(process, profile, host.url, time.monotonic() + 25, host.view_backend)
    host.views = {"main": view}
    started = []
    host._launch_view = lambda *arguments: started.append(arguments)
    monkeypatch.setattr(desktop, "_view_handle", lambda *_: None)

    host._open_view()
    host._open_view()
    assert view.reopen == (host.url, "edge-app") and not started
    if already_open:
        activated = []
        monkeypatch.setattr(desktop, "_view_handle", lambda *_: 37)
        monkeypatch.setattr(desktop.win, "is_iconic", lambda _: False)
        monkeypatch.setattr(desktop.win, "set_foreground", activated.append)
        host._poll_views(time.monotonic())
        assert activated == [37] and view.ready and view.reopen is None and not started
        monkeypatch.setattr(desktop, "_view_handle", lambda *_: None)

    process.running = False
    host._poll_views(time.monotonic())
    assert started == ([] if already_open else [("main", host.url, "edge-app")])


def test_edge_window_uses_only_the_owned_visible_edge_window(monkeypatch):
    from gaojiling import ownedview

    win = ownedview.win
    process = ownedview.OwnedView.__new__(ownedview.OwnedView)
    process.owns = lambda pid: pid == 7
    windows = {11: (True, "Chrome_WidgetWin_1", 2), 12: (False, "Chrome_WidgetWin_1", 7),
               13: (True, "OtherWindow", 7), 14: (True, "Chrome_WidgetWin_1", 7)}

    def enumerate_windows(callback, param):
        for hwnd in windows:
            if not callback(hwnd, param):
                break

    def class_name(hwnd, buffer, _size):
        buffer.value = windows[hwnd][1]
        return len(buffer.value)

    def process_id(hwnd, pointer):
        pointer._obj.value = windows[hwnd][2]

    monkeypatch.setattr(win, "enum_windows", enumerate_windows)
    monkeypatch.setattr(win, "window_visible", lambda hwnd: windows[hwnd][0])
    monkeypatch.setattr(ownedview, "_get_window_class", class_name)
    monkeypatch.setattr(win, "window_pid", process_id)
    assert process.edge_window() == 14
