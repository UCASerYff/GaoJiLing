"""Windows desktop shell. Tk owns the floating HWNDs and the Win32 message pump."""

from __future__ import annotations

from collections import deque
import ctypes as c
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
from queue import Empty, SimpleQueue
import shutil
import sys
import tempfile
import time
from threading import Event
import tkinter as tk
from tkinter import filedialog
from urllib.parse import urlencode
import webbrowser

from gaojiling.errors import AppError
from gaojiling.appwindow import CLOSE, CLOSING, NAVIGATION, PROCESS, READY
from gaojiling.floating import (FOOTER_HEIGHT, PALETTES, PANEL_RADIUS, WIDTH, PanelContent,
                               byte_size, content_height, percent, rounded_contains)
from gaojiling.geometry import (DRAG_THRESHOLD, PANEL_INSET, SNAP_DISTANCE, PanelAutoCollapse,
                              dragging_handle, handle_frame, horizontal_ratio, panel_placement, vertical_ratio)
from gaojiling.resources import asset_root
from gaojiling.ownedview import OwnedView
from gaojiling.version import MARKETING
from gaojiling import win32 as win


_WINDOW_CLASS = "GaoJiLing.Desktop"
_ACTIVATE_MESSAGE = win.register_message("com.gaoseries.GaoJiLing.Activate")
_EXPLORER_RESTART = win.register_message("TaskbarCreated")
_TRAY_OPEN, _TRAY_PANEL, _TRAY_PAUSE, _TRAY_SETTINGS, _TRAY_DATA, _TRAY_ABOUT, _TRAY_QUIT = range(1, 8)
_TABS = {"module", "appearance", "data", "about"}
_PICK_OPTIONS = {
    "directory": ("directory", "选择目录", None),
    "image": ("open", "选择普通 NTFS 卷镜像", (("NTFS 卷镜像", "*.ntfs *.img *.raw *.dd"), ("所有文件", "*.*"))),
    "openJSON": ("open", "打开 JSON 文件", (("JSON", "*.json"),)),
    "saveJSON": ("save", "导出 JSON", (("JSON", "*.json"),)),
    "saveCSV": ("save", "导出 CSV", (("CSV", "*.csv"),)),
    "saveFile": ("save", "提取到新文件", None),
    "exchange": ("directory", "选择 GaoAction 包目录", None),
}


class DesktopInstance:
    """Keep one sampler per data directory and signal its window on second launch."""

    def __init__(self, directory: Path):
        digest = hashlib.sha256(os.path.normcase(str(directory.resolve())).encode("utf-8")).hexdigest()[:24]
        self.name = "GaoJiLing." + digest
        c.set_last_error(0)
        self.handle = win.create_mutex(None, False, "Local\\" + self.name)
        result = c.get_last_error()
        if not self.handle:
            raise c.WinError(result)
        self.existing = result == 183

    def activate(self):
        for _ in range(80):
            hwnd = win.find_window(_WINDOW_CLASS, self.name)
            if hwnd:
                owner = win.w.DWORD()
                win.window_pid(hwnd, c.byref(owner))
                if owner.value:
                    win.allow_foreground(owner.value)
                if win.post_message(hwnd, _ACTIVATE_MESSAGE, 0, 0):
                    return True
            time.sleep(0.1)
        return False

    def close(self):
        win.close_handle(self.handle)


def _desktop_window(root, title):
    window = tk.Toplevel(root, class_="GaoJiLingMonitor")
    window.title(title)
    window.withdraw()
    window.overrideredirect(True)
    window.wm_attributes("-toolwindow", True)
    window.geometry("1x1+0+0")
    window.update_idletasks()
    hwnd = win.tk_window(window)
    win.no_activate(hwnd)
    window.deiconify()
    window.update_idletasks()
    hwnd = win.tk_window(window)
    win.no_activate(hwnd)
    win.show_window(hwnd, win.SW_HIDE)
    return window, hwnd


def _logical(point, monitor):
    _, (left, top), _, dpi = monitor
    return (point[0] - left) / dpi, (point[1] - top) / dpi


def _physical(box, monitor):
    _, (left, top), _, scale = monitor
    return (round(left + box["x"] * scale), round(top + box["y"] * scale),
            max(1, round(box["width"] * scale)), max(1, round(box["height"] * scale)))


def _in_box(point, box):
    return box[0] <= point[0] < box[0] + box[2] and box[1] <= point[1] < box[1] + box[3]


def _bridge(anchor, panel, point):
    """Retain just the horizontal strip-to-panel crossing until real entry."""
    if _in_box(point, anchor):
        return True
    ax, ay, aw, ah = anchor
    px, py, pw, ph = panel
    left, right = (ax + aw, px) if ax < px else (px + pw, ax)
    return left <= point[0] <= right and max(ay, py) <= point[1] < min(ay + ah, py + ph)


def _theme(preference):
    if preference in {"light", "dark"}:
        return preference
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
            light, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
        return "light" if light else "dark"
    except OSError:
        return "light"


def _edge_program():
    import winreg

    key_path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    for root in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(root, key_path) as key:
                path = Path(winreg.QueryValueEx(key, "")[0])
                if path.is_file():
                    return path
        except OSError:
            pass
    for folder in ("ProgramFiles(x86)", "ProgramFiles"):
        base = os.environ.get(folder)
        if base:
            path = Path(base) / "Microsoft" / "Edge" / "Application" / "msedge.exe"
            if path.is_file():
                return path
    return None


@dataclass
class _View:
    process: OwnedView
    signals: Path
    target: str
    deadline: float
    backend: str
    ready: bool = False
    closing: float | None = None
    reopen: tuple[str, str] | None = None
    icons: win.WindowIcons | None = None


def _view_handle(view, key):
    if view.backend == "edge-app":
        return view.process.edge_window()
    try:
        pid = int((view.signals / PROCESS).read_text(encoding="ascii"))
    except (OSError, ValueError):
        return None
    if view.process.owns(pid):
        return win.find_view(pid, "搞机灵设置" if key == "settings" else f"搞机灵 V{MARKETING}")
    return None


class Desktop:
    def __init__(self, service, url, instance_name, isolated=False):
        self.service = service
        self.url = url
        self.instance_name = instance_name
        self.commands = SimpleQueue()
        self.mouse_events = deque(maxlen=128)
        self.collapse = PanelAutoCollapse()
        self.charts = {"cpuPercent": deque(maxlen=45), "networkDown": deque(maxlen=35), "networkUp": deque(maxlen=35)}
        self.shortcut_registered = False
        self.shortcut = None
        self.notification_status = {"state": "ready", "reason": None}
        self.stopping = False
        self.quitting = False
        self.panel_open = False
        self.bridge = None
        self.strip_rect = self.panel_rect = None
        self.strip_down = self.panel_down = None
        self.panel_monitor = self.panel_frame = None
        self.strip_hovered_since = None
        self.reenter_required = False
        self.esc_down = False
        self.next_tray_retry = 0.0
        self.last_tray_click = (0, 0.0)
        self.last_appearance_check = 0.0
        self.last_shell_refresh = 0.0
        self.last_sample_stamp = None
        self.last_render_key = None
        self.last_panel = dict(self.service.store.panel)
        self.last_edge = self.settings.get("edge", "right")
        self.backend = _edge_program()
        root = Path(os.environ.get("LOCALAPPDATA", str(service.data_dir))) / "GaoSeries" / "GaoJiLing" if not isolated else service.data_dir
        self.profile = root / "DesktopWebView"
        self.views = {}
        self.view_backend = "webview2"
        self.icon_path = asset_root() / "AppIcon.ico"

        win.setup_dpi()
        self.root = tk.Tk(className="GaoJiLing")
        self.root.withdraw()
        self.strip, self.strip_hwnd = _desktop_window(self.root, "搞机灵唤起条")
        self.panel, self.panel_hwnd = _desktop_window(self.root, "搞机灵监控面板")
        self.strip_background = tk.Frame(self.strip, bg=PALETTES["light"]["accent"], cursor="hand2")
        self.strip_background.pack(fill="both", expand=True)
        self.strip_background.bind("<ButtonPress-1>", self._begin_strip)
        self.strip_background.bind("<B1-Motion>", lambda _event: self._move_strip())
        self.strip_background.bind("<ButtonRelease-1>", lambda _event: self._finish_strip())
        self.content = PanelContent(self.panel, self._pause, self._show_main,
                                    self._begin_panel, self._move_panel, self._finish_panel)
        self.module = win.module_handle(None)
        self.window_proc = win.WNDCALL(self._window_message)
        desc = win.WindowClass(callback=self.window_proc, module=self.module, name=_WINDOW_CLASS)
        if not win.register_class(c.byref(desc)):
            raise c.WinError(c.get_last_error())
        self.hwnd = win.create_window(0, _WINDOW_CLASS, instance_name, 0, 0, 0, 0, 0,
                                      None, None, self.module, None)
        if not self.hwnd:
            raise c.WinError(c.get_last_error())
        self.tray = win.Tray(self.hwnd, self.icon_path)
        if not self.tray.available:
            self.notification_status = {"state": "unavailable", "reason": "Windows 未接受系统托盘登记。"}
        self.mouse_hook = None
        self.hook_proc = win.HOOKCALL(self._hook_message)
        self.theme = _theme(self.settings.get("appearance"))

    @property
    def settings(self):
        return self.service.store.settings

    def status(self):
        return {"available": bool(self.hwnd and not self.stopping), "trayAvailable": self.tray.available,
                "hotkeyRegistered": self.shortcut_registered, "hotkey": "Ctrl+Alt+" + (self.shortcut or "g").upper(),
                "notificationStatus": self.notification_status, "view": self.view_backend}

    def open_settings(self, tab=None):
        if tab is not None and tab not in _TABS:
            raise AppError("设置页签无效。")
        self.commands.put(lambda: self._open_view(tab or "module"))

    def open_notification_settings(self):
        self.commands.put(lambda: os.startfile("ms-settings:notifications"))

    def reposition(self, reset):
        self.commands.put(lambda: self._reposition(reset))

    def notify(self, title, detail):
        if self.stopping or not self.tray.available:
            return False
        self.notification_status = {"state": "queued", "reason": None}

        def dispatch():
            accepted = self.tray.notify(str(title), str(detail))
            self.notification_status = {"state": "shell-accepted" if accepted else "unavailable",
                                        "reason": "投递受 Windows 通知设置与专注模式影响。" if accepted else "Windows 托盘未接受通知。"}

        self.commands.put(dispatch)
        return True

    def choose(self, kind, suggested=None):
        if kind not in _PICK_OPTIONS:
            raise AppError("文件选择类型无效。")
        if self.stopping:
            raise AppError("桌面窗口正在退出。")
        ready, result = Event(), []

        def choose_path():
            try:
                mode, title, filters = _PICK_OPTIONS[kind]
                options = {"title": title, "parent": self.root}
                if mode == "directory":
                    selected = filedialog.askdirectory(mustexist=True, **options)
                else:
                    if filters:
                        options["filetypes"] = filters
                    if mode == "save" and suggested:
                        options["initialfile"] = Path(str(suggested)).name[:180]
                    if mode == "save" and kind in {"saveJSON", "saveCSV"}:
                        options["defaultextension"] = ".json" if kind == "saveJSON" else ".csv"
                    dialog = filedialog.asksaveasfilename if mode == "save" else filedialog.askopenfilename
                    selected = dialog(**options)
                result.append(str(selected) if selected else None)
            except tk.TclError as error:
                result.append(AppError(f"Windows 未能打开文件选择器：{error}"))
            finally:
                ready.set()

        self.commands.put(choose_path)
        for _ in range(300):
            if ready.wait(1):
                if isinstance(result[0], AppError):
                    raise result[0]
                return result[0]
            if self.stopping:
                break
        raise AppError("文件对话框未返回结果。")

    def _window_message(self, hwnd, message, wparam, lparam):
        if message == win.WM_HOTKEY and wparam == 1:
            self.commands.put(self._toggle_panel)
            return 0
        if message == win.WM_TRAY:
            event = lparam & 0xFFFF
            modern = self.tray.version4
            identifier = (lparam >> 16) & 0xFFFF if modern else wparam
            if identifier != win.NOTIFY_ID:
                return 0
            if event in (win.WM_LBUTTONUP, win.NIN_SELECT):
                previous, last = self.last_tray_click
                now = time.monotonic()
                self.last_tray_click = (event, now)
                # Some Shell versions send both forms for one mouse click.
                if event == previous or now - last > 0.2:
                    self.commands.put(self._show_main)
            elif modern and event == win.NIN_KEYSELECT:
                self.commands.put(self._show_main)
            elif event == (win.WM_CONTEXTMENU if modern else win.WM_RBUTTONUP):
                self.commands.put(self._tray_menu)
            return 0
        if message == win.WM_COMMAND and not lparam and _TRAY_OPEN <= (wparam & 0xFFFF) <= _TRAY_QUIT:
            self.commands.put(lambda: self._tray_command(wparam & 0xFFFF))
            return 0
        if message == _ACTIVATE_MESSAGE:
            self.commands.put(self._show_main)
            return 0
        if message == _EXPLORER_RESTART:
            self.commands.put(self._register_tray)
            return 0
        if message in (0x7E, 0x219):  # display topology and work area
            self.commands.put(self._display_changed)
        if message == 0x218 and wparam == 4:  # PBT_APMSUSPEND
            self.commands.put(self._close_panel)
        return win.def_window_proc(hwnd, message, wparam, lparam)

    def _hook_message(self, code, message, information):
        if code >= 0 and (message == 0x200 or message in win.button_messages):
            event = c.cast(information, c.POINTER(win.MouseEvent)).contents
            point = (event.point.x, event.point.y)
            if message == 0x200:
                if not self.collapse.has_entered and self._inside_panel(point):
                    self.collapse.has_entered = True
            else:
                button, is_down = win.button_messages[message]
                if button == 3 and event.mouseData >> 16 == 2:
                    button = 4
                self.mouse_events.append((point, button, is_down))
        return win.next_hook(None, code, message, information)

    def _process_mouse(self):
        while self.mouse_events:
            point, button, down = self.mouse_events.popleft()
            if not self.panel_open:
                continue
            if down:
                if self.collapse.mouse_down(button, self._inside_panel(point)):
                    self._close_panel()
            else:
                self.collapse.mouse_up(button)

    def _tray_menu(self):
        entries = ((_TRAY_OPEN, "打开 搞机灵"), (_TRAY_PANEL, "显示 / 收起面板"),
                   (_TRAY_PAUSE, "继续监控" if self.service.paused else "暂停监控"),
                   (0, None), (_TRAY_SETTINGS, "设置…"), (_TRAY_DATA, "导出数据…"),
                   (_TRAY_ABOUT, "关于搞机灵…"), (0, None), (_TRAY_QUIT, "退出"))
        menu = win.create_menu()
        if not menu:
            return
        for identifier, label in entries:
            win.append_menu(menu, 0 if label else 0x800, identifier, label)
        try:
            win.set_foreground(self.hwnd)
            win.track_menu(menu, 0x2, *win.cursor(), 0, self.hwnd, None)
            win.post_message(self.hwnd, 0, 0, 0)
        finally:
            win.destroy_menu(menu)

    def _tray_command(self, identifier):
        actions = {
            _TRAY_OPEN: self._show_main, _TRAY_PANEL: self._toggle_panel, _TRAY_PAUSE: self._pause,
            _TRAY_SETTINGS: self.open_settings, _TRAY_DATA: lambda: self.open_settings("data"),
            _TRAY_ABOUT: lambda: self.open_settings("about"), _TRAY_QUIT: self._quit_from_ui,
        }
        actions[identifier]()

    def _register_tray(self):
        self.next_tray_retry = time.monotonic() + 2
        if self.tray.register():
            if self.notification_status["state"] == "unavailable":
                self.notification_status = {"state": "ready", "reason": None}
        else:
            self.notification_status = {"state": "unavailable", "reason": "Windows 暂未接受通知区域图标登记。"}

    def _open_view(self, tab=None):
        if self.stopping:
            return
        target = self.url if tab is None else self.url + "?" + urlencode({"settings": 1, "tab": tab})
        key = "settings" if tab else "main"
        current = self.views.get(key)
        if current and current.process.is_running():
            hwnd = _view_handle(current, key)
            if (current.closing is not None or (current.signals / CLOSING).is_file()
                    or ((current.ready or (current.signals / READY).is_file()) and not hwnd)
                    or (current.backend == "edge-app" and current.target != target)):
                backend = current.reopen[1] if current.reopen else current.backend
                current.reopen = (target, backend)
                self._dismiss_view(key, current)
                return
            if current.backend == "edge-app" and not hwnd:
                # Edge has no ready marker. It may have opened and closed between polls.
                current.reopen = (target, current.backend)
                return
            if tab and current.backend == "webview2":
                navigation = current.signals / NAVIGATION
                temporary = navigation.with_suffix(".pending")
                temporary.write_text(tab, encoding="ascii")
                temporary.replace(navigation)
                current.target = target
            if hwnd:
                if win.is_iconic(hwnd):
                    win.show_window(hwnd, 9)
                win.set_foreground(hwnd)
            return
        if current:
            self._drop_view(key, current)
        self._launch_view(key, target, self.view_backend)

    def _launch_view(self, key, target, backend):
        if backend == "browser" or (backend == "edge-app" and not self.backend):
            self.view_backend = "browser"
            webbrowser.open(target)
            return
        signals = None
        try:
            self.profile.mkdir(parents=True, exist_ok=True)
            signals = Path(tempfile.mkdtemp(dir=self.profile, prefix="window-"))
            if backend == "webview2":
                launcher = [sys.executable] if getattr(sys, "frozen", False) else [sys.executable, str(Path(sys.argv[0]).resolve())]
                process = OwnedView([*launcher, "--app-window", target, str(signals), self.theme],
                                    env={**os.environ, "PYINSTALLER_RESET_ENVIRONMENT": "1"})
            else:
                size = "1100,780" if key == "main" else "760,740"
                process = OwnedView([str(self.backend), f"--app={target}", f"--user-data-dir={signals / 'EdgeApp'}",
                                     f"--window-size={size}", "--no-first-run", "--disable-sync", "--disable-background-mode"])
        except OSError as error:
            if signals:
                shutil.rmtree(signals, ignore_errors=True)
            self.service.message = f"Windows 无法打开独立窗口：{error}"
            self._fallback_view(key, target, backend)
            return
        self.view_backend = backend
        self.views[key] = _View(process, signals, target, time.monotonic() + 25, backend,
                                icons=win.WindowIcons(self.icon_path, browser_owned=backend == "edge-app"))

    def _poll_views(self, now):
        for key, view in list(self.views.items()):
            running = view.process.is_running()
            closing = (view.signals / CLOSING).is_file()
            if view.closing is None:
                hwnd = _view_handle(view, key) if running else None
                view.ready = view.ready or (view.signals / READY).is_file() or bool(view.backend == "edge-app" and hwnd)
                if closing or (view.ready and not hwnd):
                    self._dismiss_view(key, view)
                elif not view.ready and (not running or now >= view.deadline):
                    if view.reopen is None:
                        view.reopen = (view.target, self._next_view_backend(view.backend))
                    self._dismiss_view(key, view)
                elif hwnd:
                    if view.icons:
                        view.icons.update(hwnd, now)
                    if view.reopen is not None:
                        view.reopen = None
                        if win.is_iconic(hwnd):
                            win.show_window(hwnd, 9)
                        win.set_foreground(hwnd)
            if not running or (view.closing is not None and now >= view.closing):
                self._drop_view(key, view)
                if view.reopen:
                    self._launch_view(key, *view.reopen)

    def _next_view_backend(self, backend):
        return "edge-app" if backend == "webview2" and self.backend else "browser"

    def _fallback_view(self, key, target, backend):
        self._launch_view(key, target, self._next_view_backend(backend))

    def _dismiss_view(self, key, view):
        if view.closing is not None:
            return
        view.closing = time.monotonic() + 4
        if view.backend == "webview2":
            try:
                (view.signals / CLOSE).touch()
            except OSError:
                pass
        hwnd = _view_handle(view, key)
        if hwnd:
            win.post_message(hwnd, 0x10, 0, 0)  # WM_CLOSE

    def _drop_view(self, key, view):
        view.process.close()
        if view.icons:
            view.icons.close()
        shutil.rmtree(view.signals, ignore_errors=True)
        del self.views[key]

    def _show_main(self):
        self._close_panel()
        self._open_view()

    def _pause(self):
        if not getattr(self.service, "data_busy", False):
            self.service.set_paused(not self.service.paused)

    def _display_changed(self):
        self._close_panel()
        self.strip_rect = None

    def _reposition(self, reset=False):
        self._close_panel()
        panel = self.service.store.panel
        monitor = win.current_monitor(win.cursor()) if reset else win.named_monitor(panel.get("displayId")) or win.current_monitor(win.cursor())
        self._save_panel({"displayId": monitor[0], "verticalRatio": 0.5 if reset else panel["verticalRatio"],
                          "horizontalRatio": 0.0 if self.settings["edge"] == "left" else 1.0})

    def _save_panel(self, panel):
        try:
            self.service.store.save_panel(panel)
        except (AppError, OSError) as error:
            self.service.message = str(error)

    def _show_strip(self, monitor, frame, hovered=False):
        physical = _physical(frame, monitor)
        scale = monitor[3]
        x, y, width, height = physical
        ink_width = round((7 if hovered else 6) * scale)
        edge_left = frame["x"] <= 0.5
        edge_right = abs(frame["x"] + frame["width"] - monitor[2]["width"]) <= 0.5
        capsule_x = x + round(scale) if edge_left else x + width - ink_width - round(scale) if edge_right else x + (width - ink_width) // 2
        inset = max(1, round(4 * scale))
        rect = (capsule_x, y + inset, max(1, ink_width), max(1, height - 2 * inset))
        # Track the visible physical strip, not its larger geometry anchor.
        color = PALETTES[self.theme]["accent"]
        if self.strip_background.cget("background") != color:
            self.strip_background.configure(bg=color)
        if rect != self.strip_rect:
            win.show_rect(self.strip_hwnd, rect, max(1, ink_width // 2))
            self.strip_rect = rect
        self.strip_anchor = physical

    def _strip_location(self, point):
        panel = self.service.store.panel
        monitor = win.named_monitor(panel.get("displayId")) or win.current_monitor(point) if panel.get("displayId") else self.home_monitor
        return monitor, handle_frame(monitor[2], self.settings["edge"], panel["verticalRatio"], panel["horizontalRatio"])

    def _begin_strip(self, _event):
        point = win.cursor()
        monitor, frame = self._strip_location(point)
        lx, ly = _logical(point, monitor)
        # Physical offset survives transition to a monitor with a different DPI.
        self.strip_down = {"point": point, "offset": ((lx - frame["x"]) * monitor[3], (ly - frame["y"]) * monitor[3]),
                           "moving": False, "monitor": monitor, "frame": frame}

    def _move_strip(self):
        drag = self.strip_down
        if not drag:
            return
        point = win.cursor()
        monitor = win.current_monitor(point)
        if not drag["moving"] and math.dist(point, drag["point"]) < DRAG_THRESHOLD * drag["monitor"][3]:
            return
        x, y = _logical(point, monitor)
        offset_x, offset_y = drag["offset"]
        frame = dragging_handle(dict(x=x, y=y), dict(x=offset_x / monitor[3], y=offset_y / monitor[3]), monitor[2])
        drag.update(moving=True, monitor=monitor, frame=frame)
        self._show_strip(monitor, frame, True)

    def _finish_strip(self):
        drag, self.strip_down = self.strip_down, None
        if drag is None:
            return
        monitor, frame = drag["monitor"], drag["frame"]
        if drag["moving"]:
            self._save_panel({"displayId": monitor[0], "horizontalRatio": horizontal_ratio(frame, monitor[2]),
                              "verticalRatio": vertical_ratio(frame, monitor[2])})
            self.reenter_required = True
        else:
            self._open_panel(monitor, frame, from_strip=True)

    def _open_panel(self, monitor, anchor, from_strip=False):
        visible = monitor[2]
        width = min(WIDTH, max(1, visible["width"] - 32))
        size = dict(width=width, height=content_height(self.service.latest or {}, self.settings,
                                                    self.service.active, width) + FOOTER_HEIGHT)
        placement = panel_placement(anchor, size, visible, self.settings["edge"])
        self.panel_monitor, self.panel_frame = monitor, placement["frame"]
        self.panel_open = True
        self.service._panel_visible = True
        self.bridge = self.strip_rect if from_strip else None
        self.collapse.opened(time.monotonic())
        win.show_window(self.strip_hwnd, win.SW_HIDE)
        self.strip_rect = None
        self.last_render_key = None
        self.content.reset_view()
        self._render_panel(force=True)
        self.mouse_events.clear()
        self.mouse_hook = win.set_hook(14, self.hook_proc, self.module, 0)

    def _close_panel(self):
        if not self.panel_open:
            return
        if self.panel_down:
            self._finish_panel()
        self.panel_open = False
        self.service._panel_visible = False
        self.collapse.closed()
        self.reenter_required = True
        self.strip_hovered_since = None
        if self.mouse_hook:
            win.unhook(self.mouse_hook)
            self.mouse_hook = None
        win.show_window(self.panel_hwnd, win.SW_HIDE)

    def _toggle_panel(self):
        if self.panel_open:
            self._close_panel()
            return
        point = win.cursor()
        monitor = win.current_monitor(point)
        saved_monitor, anchor = self._strip_location(point)
        if saved_monitor[0] != monitor[0]:
            anchor = handle_frame(monitor[2], self.settings["edge"], 0.5)
        self._open_panel(monitor, anchor)

    def _inside_panel(self, point):
        return self.panel_rect is not None and rounded_contains(self.panel_rect, point, PANEL_RADIUS * self.panel_monitor[3])

    def _begin_panel(self):
        if not self.panel_open:
            return
        point = win.cursor()
        x, y, _, _ = self.panel_rect
        self.panel_down = {"point": point, "offset": (point[0] - x, point[1] - y),
                           "scale": self.panel_monitor[3], "moving": False}

    def _move_panel(self):
        drag = self.panel_down
        if not drag:
            return
        point = win.cursor()
        if not drag["moving"] and math.dist(point, drag["point"]) < DRAG_THRESHOLD * drag["scale"]:
            return
        monitor = win.current_monitor(point)
        x, y = _logical(point, monitor)
        offset_x, offset_y = drag["offset"]
        scale = monitor[3]
        width = min(self.panel_frame["width"], max(1, monitor[2]["width"] - 2 * PANEL_INSET))
        height = min(self.panel_frame["height"], max(1, monitor[2]["height"] - 2 * PANEL_INSET))
        right = max(PANEL_INSET, monitor[2]["width"] - PANEL_INSET - width)
        bottom = max(PANEL_INSET, monitor[2]["height"] - PANEL_INSET - height)
        left = min(max(PANEL_INSET, x - offset_x / scale), right)
        if min(abs(left - PANEL_INSET), abs(right - left)) <= SNAP_DISTANCE:
            left = PANEL_INSET if left - PANEL_INSET <= right - left else right
        self.panel_monitor = monitor
        self.panel_frame = dict(x=left, y=min(max(PANEL_INSET, y - offset_y / scale), bottom), width=width, height=height)
        self.bridge = None
        drag["moving"] = True
        self._render_panel(force=True)

    def _finish_panel(self):
        drag, self.panel_down = self.panel_down, None
        if drag and drag["moving"]:
            visible = self.panel_monitor[2]
            frame = self.panel_frame
            handle = handle_frame(visible, "left", 0.5)
            if frame["x"] <= PANEL_INSET + 0.5:
                handle["x"] = 0
            elif frame["x"] + frame["width"] >= visible["width"] - PANEL_INSET - 0.5:
                handle["x"] = visible["width"] - handle["width"]
            else:
                handle["x"] = frame["x"] + (frame["width"] - handle["width"]) / 2
            handle["y"] = frame["y"] + (frame["height"] - handle["height"]) / 2
            self._save_panel({"displayId": self.panel_monitor[0], "horizontalRatio": horizontal_ratio(handle, visible),
                              "verticalRatio": vertical_ratio(handle, visible)})

    def _render_panel(self, force=False):
        if not self.panel_open:
            return
        sample = self.service.latest or {}
        active, paused = self.service.active, self.service.paused
        frame, monitor = self.panel_frame, self.panel_monitor
        busy = getattr(self.service, "data_busy", False)
        if not self.panel_down:
            desired = content_height(sample, self.settings, active, frame["width"]) + FOOTER_HEIGHT
            frame["height"] = min(desired, max(1, monitor[2]["height"] - 2 * PANEL_INSET))
            frame["y"] = min(frame["y"], max(PANEL_INSET, monitor[2]["height"] - PANEL_INSET - frame["height"]))
        rect = _physical(frame, monitor)
        key = (sample.get("timestamp"), self.theme, paused, busy, active and (active["id"], int(time.time())),
               self.settings.get("showSensors"), int(time.time()) // 5, rect)
        if not force and key == self.last_render_key:
            return
        self.last_render_key = key
        if force or rect != self.panel_rect:
            win.show_rect(self.panel_hwnd, rect, max(1, round(PANEL_RADIUS * monitor[3])))
        self.panel_rect = rect
        self.content.update(frame["width"], frame["height"], monitor[3], sample, self.settings, active, paused,
                            self.charts, self.theme, busy=busy)

    def _refresh_shell(self, now):
        sample = self.service.latest or {}
        timestamp = sample.get("timestamp")
        if timestamp is not None and timestamp != self.last_sample_stamp:
            if self.last_sample_stamp is not None and timestamp - self.last_sample_stamp > 15:
                for chart in self.charts.values():
                    chart.append(None)
            for key, chart in self.charts.items():
                chart.append(sample.get(key))
            self.last_sample_stamp = timestamp
        if now - self.last_appearance_check >= 0.8:
            self.theme = _theme(self.settings.get("appearance"))
            self.last_appearance_check = now
        choice = self.settings.get("hotkeyChoice", "g")
        if self.shortcut != choice:
            if self.shortcut_registered:
                win.unregister_hotkey(self.hwnd, 1)
            self.shortcut = choice
            self.shortcut_registered = bool(win.register_hotkey(self.hwnd, 1, win.MODIFIERS, ord(choice.upper())))
        if now - self.last_shell_refresh >= 0.5:
            cpu = f" · CPU {percent(sample.get('cpuPercent'))}" if self.settings.get("menuBarCPU") else ""
            paused = " · 暂停" if self.service.paused else ""
            memory = f" · 内存 {byte_size(sample.get('memoryUsed'))}"
            self.tray.refresh_dpi()
            self.tray.tooltip("搞机灵" + paused + cpu + memory + "\n单击打开主窗口，右键更多选项")
            if not self.tray.available and now >= self.next_tray_retry:
                self._register_tray()
            self._poll_views(now)
            self.last_shell_refresh = now
        if self.last_edge != self.settings["edge"]:
            if self.last_panel == self.service.store.panel:
                self._reposition()
            self.last_edge = self.settings["edge"]
        self.last_panel = dict(self.service.store.panel)

    def _tick(self):
        if self.stopping:
            return
        try:
            self._tick_desktop()
        except (AppError, OSError, tk.TclError) as error:
            self.service.message = f"桌面监控操作失败：{error}"
        if not self.stopping:
            self.root.after(33, self._tick)

    def _tick_desktop(self):
        for _ in range(20):
            try:
                command = self.commands.get_nowait()
            except Empty:
                break
            command()
            if self.stopping:
                return
        self._process_mouse()
        now, point = time.monotonic(), win.cursor()
        self._refresh_shell(now)
        if self.panel_open:
            held = win.pressed_buttons()
            escape = win.get_key(0x1B) < 0
            if escape and not self.esc_down:
                self._close_panel()
            elif self.panel_down and not held & 1:
                self._finish_panel()
            elif not self.panel_down:
                bridge = bool(self.bridge and _bridge(self.bridge, self.panel_rect, point))
                if self.collapse.should_collapse(now, self._inside_panel(point), bridge, held):
                    self._close_panel()
            self.esc_down = escape
            self._render_panel()
            return
        if not self.settings.get("edgeEnabled") and not self.strip_down:
            if self.strip_rect:
                win.show_window(self.strip_hwnd, win.SW_HIDE)
                self.strip_rect = None
            return
        if self.strip_down:
            if not win.pressed_buttons() & 1:
                self._finish_strip()
            return
        monitor, anchor = self._strip_location(point)
        is_hovered = self.strip_rect is not None and rounded_contains(self.strip_rect, point, 3 * monitor[3])
        self._show_strip(monitor, anchor, is_hovered)
        is_hovered = rounded_contains(self.strip_rect, point, 3 * monitor[3])
        if not is_hovered:
            self.strip_hovered_since = None
            self.reenter_required = False
        elif not self.reenter_required:
            if self.strip_hovered_since is None:
                self.strip_hovered_since = now
            elif now - self.strip_hovered_since >= self.settings["edgeDelay"]:
                self._open_panel(monitor, anchor, from_strip=True)

    def run(self, startup=False):
        self.home_monitor = win.current_monitor(win.cursor())
        if not startup:
            self.commands.put(self._open_view)
        self.root.after(0, self._tick)
        try:
            self.root.mainloop()
        finally:
            self.stopping = True
            try:
                self._close_panel()
                win.show_window(self.strip_hwnd, win.SW_HIDE)
                if self.shortcut_registered:
                    win.unregister_hotkey(self.hwnd, 1)
                    self.shortcut_registered = False
                self._close_views()
            finally:
                self.tray.close()
                win.destroy_window(self.hwnd)
                win.unregister_class(_WINDOW_CLASS, self.module)
                self.root.destroy()

    def _close_views(self):
        try:
            for key, view in self.views.items():
                self._dismiss_view(key, view)
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and any(view.process.is_running() for view in self.views.values()):
                time.sleep(0.05)
        except OSError:
            # Losing the ability to query a job must not skip the rest of desktop teardown.
            pass
        finally:
            for key, view in list(self.views.items()):
                self._drop_view(key, view)

    def _quit_from_ui(self):
        if self.stopping or self.quitting:
            return
        self.quitting = True
        try:
            if self.service.prepare_shutdown(self._confirm_active_task):
                self.stopping = True
                self.root.quit()
        except AppError as error:
            self.service.message = str(error)
            win.message_box(self.hwnd, str(error), "退出搞机灵", 0x30)
        finally:
            self.quitting = False

    def _confirm_active_task(self, name):
        return win.message_box(
            self.hwnd,
            f"「{name}」正在记录。退出会结束并保存当前任务。\n\n选择取消可继续记录。",
            "退出搞机灵", 0x121,  # OK / Cancel, question icon, Cancel by default.
        ) == 1

    def request_quit(self):
        self.commands.put(self._quit_from_ui)

    def server_stopped(self):
        self.commands.put(self.root.quit)


def report_error(message):
    win.message_box(None, str(message), "搞机灵", 0x10)
