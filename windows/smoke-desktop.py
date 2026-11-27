"""Exercise the Windows notification-area lifecycle on a private inactive desktop."""

from __future__ import annotations

import argparse
from contextlib import closing, redirect_stderr, redirect_stdout
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.request
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaojiling import win32 as win
from gaojiling.appwindow import PROCESS, READY
from gaojiling.desktop import _EXPLORER_RESTART, _TRAY_OPEN, _TRAY_QUIT, _WINDOW_CLASS
from gaojiling.ownedview import _ProcessInfo, _StartupInfo
from gaojiling.version import MARKETING, display


def until(read, message, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = read()
        if value:
            return value
        time.sleep(0.12)
    raise AssertionError(message)


def process_waited(handle):
    wait = win._api(win.kernel, "WaitForSingleObject", win.w.DWORD, win.w.HANDLE, win.w.DWORD)
    return wait(handle, 0) == 0


def desktop_name(handle):
    name = c.create_unicode_buffer(256)
    size = win.w.DWORD()
    read = win._api(win.user, "GetUserObjectInformationW", win.w.BOOL, win.w.HANDLE, c.c_int,
                    c.c_void_p, win.w.DWORD, c.POINTER(win.w.DWORD))
    if not read(handle, 2, name, c.sizeof(name), c.byref(size)):  # UOI_NAME
        raise c.WinError(c.get_last_error())
    return name.value


def verify_inactive(desktop):
    thread_id = win._api(win.kernel, "GetCurrentThreadId", win.w.DWORD)
    thread_desktop = win._api(win.user, "GetThreadDesktop", win.w.HANDLE, win.w.DWORD)
    assert desktop_name(thread_desktop(thread_id())) == desktop, "Test controller is on the wrong desktop"
    input_desktop = win._api(win.user, "OpenInputDesktop", win.w.HANDLE, win.w.DWORD, win.w.BOOL, win.w.DWORD)
    close_desktop = win._api(win.user, "CloseDesktop", win.w.BOOL, win.w.HANDLE)
    current = input_desktop(0, False, 1)
    if current:
        try:
            assert desktop_name(current) != desktop, "The private test desktop unexpectedly has input focus"
        finally:
            close_desktop(current)


def run_isolated(scratch, arguments):
    name = "GaoJiLingSmoke-" + uuid.uuid4().hex
    create_desktop = win._api(win.user, "CreateDesktopW", win.w.HANDLE, win.w.LPCWSTR, win.w.LPCWSTR,
                              c.c_void_p, win.w.DWORD, win.w.DWORD, c.c_void_p)
    close_desktop = win._api(win.user, "CloseDesktop", win.w.BOOL, win.w.HANDLE)
    create_process = win._api(win.kernel, "CreateProcessW", win.w.BOOL, win.w.LPCWSTR, win.w.LPWSTR,
                              c.c_void_p, c.c_void_p, win.w.BOOL, win.w.DWORD, c.c_void_p, win.w.LPCWSTR,
                              c.POINTER(_StartupInfo), c.POINTER(_ProcessInfo))
    wait = win._api(win.kernel, "WaitForSingleObject", win.w.DWORD, win.w.HANDLE, win.w.DWORD)
    get_exit = win._api(win.kernel, "GetExitCodeProcess", win.w.BOOL, win.w.HANDLE, c.POINTER(win.w.DWORD))
    # Request the window, menu, hook, enumerate and object rights. This harness never switches desktops.
    desktop = create_desktop(name, None, None, 0, 0xCF, None)
    if not desktop:
        raise c.WinError(c.get_last_error())
    info = _ProcessInfo()
    try:
        startup = _StartupInfo(size=c.sizeof(_StartupInfo), desktop=name)
        line = c.create_unicode_buffer(subprocess.list2cmdline([
            sys.executable, str(Path(__file__).resolve()), "--_desktop", name, "--_scratch", str(scratch), *arguments,
        ]))
        if not create_process(sys.executable, line, None, None, False, 0x08000000, None,
                              str(ROOT), c.byref(startup), c.byref(info)):
            raise c.WinError(c.get_last_error())
        if wait(info.process, 220000) != 0:
            kill_process_tree(info.pid)
            raise AssertionError("The private desktop controller timed out")
        result = win.w.DWORD()
        if not get_exit(info.process, c.byref(result)):
            raise c.WinError(c.get_last_error())
        output = scratch / "smoke.log"
        if output.is_file():
            sys.stdout.write(output.read_text(encoding="utf-8"))
            sys.stdout.flush()
        return result.value
    finally:
        for handle in (info.thread, info.process):
            if handle:
                win.close_handle(handle)
        close_desktop(desktop)


def kill_process_tree(pid):
    utility = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "taskkill.exe"
    subprocess.run([str(utility), "/PID", str(pid), "/T", "/F"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def port_closed(port):
    with socket.socket() as sock:
        sock.settimeout(.35)
        return sock.connect_ex(("127.0.0.1", port)) != 0


def identity_for(data):
    path = os.path.normcase(str(data.resolve())).encode("utf-8")
    return "GaoJiLing." + hashlib.sha256(path).hexdigest()[:24]


class LocalApp:
    def __init__(self, launcher, data, *options):
        self.port = available_port()
        self.url = f"http://127.0.0.1:{self.port}/"
        self.arguments = [*launcher, "--data-dir", str(data), "--port", str(self.port), *options]
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.token = None
        self.process = subprocess.Popen(self.arguments)

    def connect(self):
        def page():
            if self.process.poll() is not None:
                raise RuntimeError(f"GaoJiLing exited early ({self.process.returncode})")
            try:
                with self.opener.open(self.url, timeout=0.5) as response:
                    return response.read().decode("utf-8")
            except OSError:
                return None

        body = until(page, "Local desktop server did not initialize", 45)
        self.token = re.search(r'name="gao-token" content="([^"]+)"', body)[1]
        return self.api("state")

    def api(self, action, data=None):
        headers = {"X-Gao-Token": self.token, "Content-Type": "application/json"}
        body = None if data is None else json.dumps(data).encode("utf-8")
        request = urllib.request.Request(self.url + "api/" + action, data=body, headers=headers)
        with self.opener.open(request, timeout=7) as response:
            return json.load(response)

    def port_closed(self):
        return port_closed(self.port)

    def close(self):
        if self.process.poll() is None:
            kill_process_tree(self.process.pid)
            self.process.wait(10)


def window_pid(hwnd):
    pid = win.w.DWORD()
    win.window_pid(hwnd, c.byref(pid))
    return pid.value


def ready_webview_windows(data):
    for marker in data.glob("DesktopWebView/window-*/" + READY):
        try:
            pid = int((marker.parent / PROCESS).read_text(encoding="ascii"))
        except (OSError, ValueError):
            continue
        yield marker.parent, pid


_READ_WEBVIEW_DOM = r"""
const [url, predicate] = process.argv.slice(1);
const socket = new WebSocket(url);
const timeout = setTimeout(() => process.exit(3), 11000);
socket.addEventListener("error", () => process.exit(4));
socket.addEventListener("open", () => {
  const expression = "new Promise(resolve => { const expire = Date.now() + 7000; function check() {"
    + "if (" + predicate + ") resolve(true); else if (Date.now() >= expire) resolve(false);"
    + "else setTimeout(check, 100); } check(); })";
  socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate",
    params: { expression, awaitPromise: true, returnByValue: true } }));
});
socket.addEventListener("message", (message) => {
  const record = JSON.parse(message.data);
  if (record.id !== 1) return;
  clearTimeout(timeout);
  socket.close();
  process.exit(record.result?.result?.value === true ? 0 : 2);
});
"""


def verify_webview_dom(data, app, hwnd, address, predicate, label):
    pid = window_pid(hwnd)
    signals = next((path for path, process in ready_webview_windows(data) if process == pid), None)
    assert signals is not None, f"{label} did not report a native WebView2 HWND and ready marker"

    def private_target():
        for metadata in signals.rglob("DevToolsActivePort"):
            try:
                port = int(metadata.read_text(encoding="ascii").splitlines()[0])
                with app.opener.open(f"http://127.0.0.1:{port}/json/list", timeout=0.5) as response:
                    targets = json.load(response)
                for target in targets:
                    if target.get("url") != address or target.get("type") != "page":
                        continue
                    endpoint = urlsplit(target["webSocketDebuggerUrl"])
                    if endpoint.scheme == "ws" and endpoint.hostname == "127.0.0.1" and endpoint.port == port:
                        return endpoint.geturl()
            except (OSError, ValueError, IndexError):
                pass
        return None

    target = until(private_target, f"No WebView2 target for the isolated {label} runtime", 20)
    result = subprocess.run(["node", "-e", _READ_WEBVIEW_DOM, target, predicate],
                            creationflags=subprocess.CREATE_NO_WINDOW, timeout=15, check=False)
    assert result.returncode == 0, f"The WebView2 {label} window did not render the expected app content"
    assert win.window_visible(hwnd), f"The WebView2 {label} HWND closed before verification"
    print(f"Verified native WebView2 {label}: visible process HWND, ready marker and rendered app DOM.", flush=True)
    return urlsplit(target).port


def owned_handle(hwnd):
    open_process = win._api(win.kernel, "OpenProcess", win.w.HANDLE, win.w.DWORD, win.w.BOOL, win.w.DWORD)
    handle = open_process(0x100000, False, window_pid(hwnd))  # SYNCHRONIZE
    if not handle:
        raise c.WinError(c.get_last_error())
    return handle


def shell_icon_rect(host):
    identifier = win.NotifyIdentifier(size=c.sizeof(win.NotifyIdentifier), hwnd=host, id=win.NOTIFY_ID)
    rectangle = win.w.RECT()
    return win.notify_rect(c.byref(identifier), c.byref(rectangle)) == 0


def dispatch_host(host, message, wparam=0, lparam=0):
    send = win._api(win.user, "SendMessageTimeoutW", c.c_ssize_t,
                    win.w.HWND, win.w.UINT, win.w.WPARAM, win.w.LPARAM, win.w.UINT, win.w.UINT,
                    c.POINTER(c.c_size_t))
    returned = c.c_size_t()
    if not send(host, message, wparam, lparam, 0x2, 3000, c.byref(returned)):
        raise OSError(c.get_last_error(), f"Private HWND did not dispatch 0x{message:X}")


def dialog_answer(host, answer):
    dialog = until(lambda: win.find_view(window_pid(host), "退出搞机灵"), "Quit confirmation was not shown")
    get_item = win._api(win.user, "GetDlgItem", win.w.HWND, win.w.HWND, c.c_int)
    assert get_item(dialog, 1) and get_item(dialog, 2), "Quit confirmation did not provide both choices"
    assert win.post_message(dialog, win.WM_COMMAND, answer, get_item(dialog, answer))
    until(lambda: not win.window_visible(dialog), "Quit confirmation did not close")


def check_hotkey(app):
    desktop = app.api("state")["desktop"]
    if not desktop["hotkeyRegistered"] and desktop["hotkey"] == "Ctrl+Alt+G":
        # Registration is session-wide. Only the test's private preference may change.
        app.api("settings", {"hotkeyChoice": "m"})
        print("The default global shortcut did not register; using the supported alternate in the isolated profile.", flush=True)
    return until(lambda: app.api("state")["desktop"].get("hotkeyRegistered"), "Global hotkey was not registered")


def open_floating_panel(host, strip, app):
    dispatch_host(host, win.WM_HOTKEY, 1)
    try:
        panel = until(lambda: win.find_view(window_pid(host), "搞机灵监控面板"),
                      "The inactive desktop did not expose the floating panel", 8)
    except AssertionError as error:
        state = app.api("state")
        print(f"{error}; desktop status: {state['message']!r}; strip visible: {bool(win.window_visible(strip))}", flush=True)
        return None
    assert panel != strip and win.get_style(panel, win.GWLP_EXSTYLE) & win.WS_EX_NOACTIVATE
    return panel


def read_saved_session(data, session_id):
    with closing(sqlite3.connect((data / "monitor.sqlite").as_uri() + "?mode=ro", uri=True)) as database:
        row = database.execute("SELECT payload FROM sessions WHERE id=?", (session_id,)).fetchone()
    assert row, "Session is missing from the isolated on-disk database"
    return json.loads(row[0])


def assert_exit(app, data, host, saved_id, hotkey, handles, windows):
    assert app.process.wait(35) == 0, "Quit returned a failing process exit code"
    until(lambda: all(process_waited(handle) for handle in handles), "Owned GUI processes survived explicit exit")
    until(app.port_closed, "The loopback port remained reachable after exit")
    assert not win.find_window(_WINDOW_CLASS, identity_for(data))
    assert all(not win.window_visible(hwnd) for hwnd in windows if hwnd)
    assert not shell_icon_rect(host), "The shell retained a rectangle after exit"
    assert win.register_hotkey(None, 41, win.MODIFIERS, ord(hotkey[-1])), "The global hotkey remained occupied after exit"
    win.unregister_hotkey(None, 41)
    saved = read_saved_session(data, saved_id)
    assert saved["end"] is not None and saved["interrupted"] is False


def startup_probe(data, launcher):
    app = LocalApp(launcher, data, "--startup")
    handle = None
    try:
        state = app.connect()
        host = until(lambda: win.find_window(_WINDOW_CLASS, identity_for(data)), "Startup notification owner missing")
        handle = owned_handle(host)
        strip = until(lambda: win.find_view(window_pid(host), "搞机灵唤起条"), "Startup floating strip missing")
        hotkey = check_hotkey(app)
        assert hotkey and state["desktop"]["available"]
        panel = open_floating_panel(host, strip, app)
        print(f"Startup entry verified strip HWND and registered global hotkey; floating panel verified: {bool(panel)}", flush=True)
        task = app.api("session/start", {"name": "隔离退出验收"})["session"]
        assert app.api("shutdown", {}).get("pending")
        dialog_answer(host, 2)
        state = app.api("state")
        assert state["activeSession"]["id"] == task["id"] and not state["paused"]
        assert read_saved_session(data, task["id"]).get("end") is None
        assert app.api("shutdown", {}).get("pending")
        dialog_answer(host, 1)
        assert_exit(app, data, host, task["id"], state["desktop"]["hotkey"], (handle,), (strip, panel))
        print("Explicit native confirmation Cancel preserved the recording; OK saved it and released the process, "
              "port, HWNDs and global hotkey.", flush=True)
    finally:
        app.close()
        if handle:
            win.close_handle(handle)


def smoke(data, launcher, cli, require_webview2=False, require_edge_fallback=False):
    app = LocalApp(launcher, data)
    handles = []
    webview_ports = []
    name = identity_for(data)
    main_title = f"搞机灵 V{MARKETING}"
    overview_dom = ('document.querySelector(".page-header h1")?.textContent.trim() === "概览"'
                    ' && document.querySelector(".viewport .section-title")?.textContent.trim() === "资源占用"')

    def tracked_window(title):
        matches = []
        for _path, pid in ready_webview_windows(data):
            hwnd = win.find_view(pid, title)
            if hwnd:
                matches.append(hwnd)
        if not matches and not require_webview2 and app.api("state")["desktop"]["view"] == "edge-app":
            window_class = win._api(win.user, "GetClassNameW", c.c_int, win.w.HWND, win.w.LPWSTR, c.c_int)
            caption = "搞机灵 " + display() if title == main_title else title

            @win.ENUMWINDOWS
            def edge(hwnd, _):
                kind, label = c.create_unicode_buffer(64), c.create_unicode_buffer(256)
                if (win.window_visible(hwnd) and window_class(hwnd, kind, len(kind)) and kind.value == "Chrome_WidgetWin_1"
                        and win.window_text(hwnd, label, len(label)) and label.value.startswith(caption)):
                    matches.append(hwnd)
                return True

            win.enum_windows(edge, 0)
        assert len(matches) <= 1, f"Duplicate windows with title {title}"
        return matches[0] if matches else None

    try:
        state = app.connect()
        assert state["desktop"]["available"], state["desktop"]
        host = until(lambda: win.find_window(_WINDOW_CLASS, name), "Notification owner HWND was not found")
        handles.append(owned_handle(host))
        expected_view = "a native WebView2" if require_webview2 else "an owned native or Edge"
        main = until(lambda: tracked_window(main_title), f"Normal entry did not open {expected_view} main window", 55)
        handles.append(owned_handle(main))
        backend = app.api("state")["desktop"]["view"]
        print(f"Main window backend: {backend}", flush=True)
        if require_webview2:
            assert backend == "webview2"
            webview_ports.append(verify_webview_dom(data, app, main, app.url, overview_dom, "main view"))
        if require_edge_fallback:
            assert backend == "edge-app", "The isolated missing-runtime probe did not exercise Edge fallback"
        strip = until(lambda: win.find_view(window_pid(host), "搞机灵唤起条"), "The desktop strip was not shown")
        hotkey = check_hotkey(app)
        assert hotkey
        registered = app.api("state")["desktop"]["trayAvailable"]
        rectangle = shell_icon_rect(host)
        print(f"Shell_NotifyIcon registration accepted: {registered}; icon rectangle observable: {rectangle}", flush=True)

        # Model loss of the isolated icon, then target only its TaskbarCreated listener.
        # Actual Explorer is never stopped, restarted or modified by this harness.
        identifier = win.NotifyData(size=c.sizeof(win.NotifyData), hwnd=host, id=win.NOTIFY_ID)
        deleted = bool(win.notify_icon(2, c.byref(identifier))) if rectangle else False
        if deleted:
            until(lambda: not shell_icon_rect(host), "Removed tray icon still had a shell rectangle")
        dispatch_host(host, _EXPLORER_RESTART)
        if rectangle:
            until(lambda: shell_icon_rect(host), "Targeted TaskbarCreated did not restore the icon")
        print(f"Targeted TaskbarCreated delivered; observable removal and re-add: {deleted}", flush=True)

        panel = open_floating_panel(host, strip, app)
        if panel:
            dispatch_host(host, win.WM_HOTKEY, 1)
            until(lambda: not win.window_visible(panel), "The second hotkey did not collapse the floating panel")

        task = app.api("session/start", {"name": "隔离托盘验收"})["session"]
        closed_view = main, window_pid(main)
        assert win.post_message(main, 0x10, 0, 0)  # WM_CLOSE closes only the view.
        until(lambda: not win.window_visible(main), "Closing the main window did not dismiss it")
        latest = until(lambda: app.api("state")["latest"], "The monitor did not produce an initial sample")
        last = latest["timestamp"]
        until(lambda: app.api("state")["latest"]["timestamp"] > last, "Sampling stopped when the main window closed", 15)
        assert app.api("state")["activeSession"]["id"] == task["id"]
        assert win.find_window(_WINDOW_CLASS, name) == host
        if rectangle:
            assert shell_icon_rect(host), "Closing the window removed the notification icon"

        # Exactly one branch matches the negotiated notification protocol.
        dispatch_host(host, win.WM_TRAY, 0, win.NIN_SELECT | (win.NOTIFY_ID << 16))
        dispatch_host(host, win.WM_TRAY, win.NOTIFY_ID, win.WM_LBUTTONUP)
        reopened = until(lambda: tracked_window(main_title), "Tray selection did not reopen the native main window", 42)
        handles.append(owned_handle(reopened))
        if require_webview2:
            assert (reopened, window_pid(reopened)) != closed_view, "Tray activation did not create a replacement window"
            webview_ports.append(verify_webview_dom(data, app, reopened, app.url, overview_dom,
                                                   "main view reopened by tray selection"))
        # In fallback mode post WM_CLOSE immediately after the first observed
        # Edge HWND, before the host necessarily observes it in its own poll.
        closed_view = reopened, window_pid(reopened)
        assert win.post_message(reopened, 0x10, 0, 0)
        until(lambda: not win.window_visible(reopened), "The reopened main window did not close")
        dispatch_host(host, win.WM_COMMAND, _TRAY_OPEN)
        reopened = until(lambda: tracked_window(main_title), "The tray menu did not reopen the main window", 42)
        handles.append(owned_handle(reopened))
        if require_webview2:
            assert (reopened, window_pid(reopened)) != closed_view, "Tray menu did not create a replacement window"
            webview_ports.append(verify_webview_dom(data, app, reopened, app.url, overview_dom,
                                                   "main view reopened by tray menu"))
        secondary = subprocess.run(app.arguments, timeout=35)
        assert secondary.returncode == 0, "A second launch did not forward to the original instance"
        time.sleep(0.6)
        assert tracked_window(main_title) == reopened and win.find_window(_WINDOW_CLASS, name) == host
        if rectangle:
            assert shell_icon_rect(host), "A forwarded launch lost the original tray icon"

        app.api("desktop/settings", {"tab": "data"})
        settings = until(lambda: tracked_window("搞机灵设置"), "Native settings did not open", 42)
        handles.append(owned_handle(settings))
        assert reopened != settings and app.api("state")["desktop"]["view"] in {"webview2", "edge-app"}
        if require_edge_fallback:
            assert app.api("state")["desktop"]["view"] == "edge-app"
        if require_webview2:
            assert app.api("state")["desktop"]["view"] == "webview2"
            webview_ports.append(verify_webview_dom(
                data, app, settings, app.url + "?settings=1&tab=data",
                'document.querySelector(".settings-body h2")?.textContent.trim() === "数据"'
                ' && document.querySelector(".settings-body .section-title")?.textContent.trim().length > 0',
                "data settings",
            ))

        dispatch_host(host, win.WM_COMMAND, _TRAY_QUIT)
        dialog_answer(host, 2)
        state = app.api("state")
        assert state["activeSession"]["id"] == task["id"] and not state["paused"]
        assert read_saved_session(data, task["id"]).get("end") is None
        assert tracked_window(main_title) == reopened

        # Use the other existing explicit exit entry to prove it uses the same confirmation.
        assert app.api("shutdown", {}).get("pending")
        dialog_answer(host, 2)
        assert app.api("state")["activeSession"]["id"] == task["id"]
        panel = open_floating_panel(host, strip, app)
        dispatch_host(host, win.WM_COMMAND, _TRAY_QUIT)
        dialog_answer(host, 1)
        assert_exit(app, data, host, task["id"], state["desktop"]["hotkey"], handles, (reopened, settings, strip, panel))
        if require_webview2:
            until(lambda: all(port_closed(port) for port in webview_ports), "A private WebView2 debugging endpoint survived exit")
            print("All four ephemeral WebView2 debugging endpoints closed after explicit exit.", flush=True)
        print("Normal native entry, background sampling and recording after WM_CLOSE, tray and menu reopen, "
              "forwarded second launch, Cancel and saved Quit, and HWND/process/hotkey/port cleanup verified.", flush=True)
    finally:
        app.close()
        for handle in handles:
            win.close_handle(handle)

    cli_data = data.parent / "cli"
    headless = LocalApp(cli, cli_data, "--serve", "--no-browser")
    try:
        assert not headless.connect()["desktop"]["available"]
        assert not win.find_window(_WINDOW_CLASS, identity_for(cli_data))
        assert headless.api("shutdown", {}) == {"ok": True}
        assert headless.process.wait(20) == 0 and headless.port_closed()
    finally:
        headless.close()
    print("CLI --serve --no-browser created no notification-owner window and shut down normally.", flush=True)


def launchers(args):
    if args.exe:
        exe = args.exe.resolve(strict=True)
        sibling = exe.with_name("GaoJiLing-cli.exe")
        return [str(exe)], [str(sibling if sibling.is_file() else exe)]
    return [sys.executable, str(ROOT / "launch.py")], [sys.executable, str(ROOT / "launch_cli.py")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--startup-probe", action="store_true", help="Check the background login entry and native quit without opening the main view.")
    mode.add_argument("--require-webview2", action="store_true", help="Require the native WebView2 window and rendered local app content; requires Node.js 22+.")
    mode.add_argument("--require-edge-fallback", action="store_true", help="Point only the test process at an empty WebView2 runtime folder and require the private Edge fallback.")
    parser.add_argument("--_desktop", help=argparse.SUPPRESS)
    parser.add_argument("--_scratch", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    directory = ROOT / "build"
    if args._desktop:
        if (not re.fullmatch("GaoJiLingSmoke-[0-9a-f]{32}", args._desktop) or args._scratch is None
                or args._scratch.resolve().parent != directory.resolve()
                or not args._scratch.name.startswith("desktop-smoke-")):
            parser.error("Invalid private desktop controller")
        with (args._scratch / "smoke.log").open("w", encoding="utf-8") as output, redirect_stdout(output), redirect_stderr(output):
            try:
                verify_inactive(args._desktop)
                # Any external-browser fallback returns quietly and cannot invoke a shared browser.
                os.environ["BROWSER"] = f'"{Path(sys.executable).as_posix()}" -c pass %s'
                if args.require_webview2:
                    os.environ["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = (
                        "--remote-debugging-port=0 --remote-debugging-address=127.0.0.1"
                    )
                if args.require_edge_fallback:
                    empty_runtime = args._scratch / "empty-webview2-runtime"
                    empty_runtime.mkdir()
                    os.environ["WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"] = str(empty_runtime)
                launcher, cli = launchers(args)
                data = args._scratch / "data"
                if args.startup_probe:
                    startup_probe(data, launcher)
                else:
                    smoke(data, launcher, cli, require_webview2=args.require_webview2,
                          require_edge_fallback=args.require_edge_fallback)
            except BaseException:
                traceback.print_exc()
                return 1
        return 0
    if not sys.platform.startswith("win"):
        parser.error("This smoke requires Windows")
    if args.require_webview2 and not shutil.which("node"):
        parser.error("--require-webview2 requires Node.js with WebSocket support")
    directory.mkdir(exist_ok=True)
    options = ["--exe", str(args.exe.resolve(strict=True))] if args.exe else []
    if args.startup_probe:
        options.append("--startup-probe")
    if args.require_webview2:
        options.append("--require-webview2")
    if args.require_edge_fallback:
        options.append("--require-edge-fallback")
    scratch = tempfile.TemporaryDirectory(prefix="desktop-smoke-", dir=directory)
    try:
        return run_isolated(Path(scratch.name), options)
    finally:
        # Job teardown releases Chromium's isolated profile handles asynchronously.
        for attempt in range(32):
            try:
                scratch.cleanup()
                break
            except PermissionError:
                if attempt == 31:
                    raise
                time.sleep(0.25)


if __name__ == "__main__":
    raise SystemExit(main())
