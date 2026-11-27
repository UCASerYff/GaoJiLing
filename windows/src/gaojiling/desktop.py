"""Windows desktop shell. Tk owns the floating HWNDs and the Win32 message pump."""

from __future__ import annotations

from collections import deque
import ctypes as c
import hashlib
import math
import os
from pathlib import Path
from queue import Empty, SimpleQueue
import shutil
import subprocess
import sys
import tempfile
import time
from threading import Event
import tkinter as tk
from tkinter import filedialog
from urllib.parse import urlencode
import webbrowser

from gaojiling.errors import AppError
from gaojiling.appwindow import CLOSE, NAVIGATION, PROCESS, READY
from gaojiling.floating import FOOTER_HEIGHT, WIDTH, PanelContent, byte_size, content_height, percent, rounded_contains
from gaojiling.geometry import (DRAG_THRESHOLD, PANEL_INSET, SNAP_DISTANCE, PanelAutoCollapse,
                              dragging_handle, handle_frame, horizontal_ratio, panel_placement, vertical_ratio)
from gaojiling.resources import asset_root
from gaojiling.version import MARKETING
from gaojiling import win32 as win


_WINDOW_CLASS = "GaoJiLing.Desktop"
_ACTIVATE_MESSAGE = win.register_message("com.gaoseries.GaoJiLing.Activate")
_EXPLORER_RESTART = win.register_message("TaskbarCreated")
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
            if hwnd and win.post_message(hwnd, _ACTIVATE_MESSAGE, 0, 0):
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


def _view_handle(process, signals, key):
    try:
        pid = int((signals / PROCESS).read_text(encoding="ascii"))
    except (OSError, ValueError):
        pid = process.pid
    return win.find_view(pid, "搞机灵设置" if key == "settings" else f"搞机灵 V{MARKETING}")


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
        self.panel_open = False
        self.bridge = None
        self.strip_rect = self.panel_rect = None
        self.strip_down = self.panel_down = None
        self.panel_monitor = self.panel_frame = None
        self.strip_hovered_since = None
        self.reenter_required = False
        self.esc_down = False
        self.tray_click_collapsed = 0.0
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
        self.strip_background = tk.Frame(self.strip, bg="#428c80", cursor="hand2")
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
        if message == win.WM_HOTKEY:
            self.commands.put(self._toggle_panel)
            return 0
        if message == win.WM_TRAY:
            event = lparam & 0xFFFF
            if event in (win.NIN_SELECT, win.NIN_KEYSELECT) or (event == win.WM_LBUTTONUP and not self.tray.version4):
                if time.monotonic() - self.tray_click_collapsed >= 0.6:
                    self.commands.put(self._toggle_panel)
            elif event in (win.WM_CONTEXTMENU, win.WM_RBUTTONUP):
                self.commands.put(self._tray_menu)
            return 0
        if message == _ACTIVATE_MESSAGE:
            self.commands.put(self._show_main)
            return 0
        if message == _EXPLORER_RESTART:
            self.commands.put(self.tray.register)
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
                    if button == 0 and self.tray.contains(*point):
                        self.tray_click_collapsed = time.monotonic()
                    self._close_panel()
            else:
                self.collapse.mouse_up(button)

    def _tray_menu(self):
        entries = (("打开搞机灵", self._show_main), ("显示 / 收起面板", self._toggle_panel),
                   ("继续监控" if self.service.paused else "暂停监控", self._pause),
                   (None, None), ("设置…", self.open_settings), ("导出数据…", lambda: self.open_settings("data")),
                   ("关于搞机灵…", lambda: self.open_settings("about")), (None, None), ("退出搞机灵", self.root.quit))
        menu = win.create_menu()
        if not menu:
            return
        for index, (label, _) in enumerate(entries, 1):
            win.append_menu(menu, 0 if label else 0x800, index, label)
        try:
            win.set_foreground(self.hwnd)
            command = win.track_menu(menu, 0x102, *win.cursor(), 0, self.hwnd, None)
            if 0 < command <= len(entries):
                function = entries[command - 1][1]
                if function:
                    function()
            win.post_message(self.hwnd, 0, 0, 0)
        finally:
            win.destroy_menu(menu)

    def _open_view(self, tab=None):
        target = self.url if tab is None else self.url + "?" + urlencode({"settings": 1, "tab": tab})
        key = "settings" if tab else "main"
        current = self.views.get(key)
        if current and current[0].poll() is None:
            if tab:
                navigation = current[1] / NAVIGATION
                temporary = navigation.with_suffix(".pending")
                temporary.write_text(tab, encoding="ascii")
                temporary.replace(navigation)
            hwnd = _view_handle(current[0], current[1], key)
            if hwnd:
                if win.is_iconic(hwnd):
                    win.show_window(hwnd, 9)
                win.set_foreground(hwnd)
            return
        if current:
            shutil.rmtree(current[1], ignore_errors=True)
            del self.views[key]
        signals = None
        try:
            self.profile.mkdir(parents=True, exist_ok=True)
            signals = Path(tempfile.mkdtemp(dir=self.profile, prefix="window-"))
            launcher = [sys.executable] if getattr(sys, "frozen", False) else [sys.executable, str(Path(sys.argv[0]).resolve())]
            process = subprocess.Popen([*launcher, "--app-window", target, str(signals), self.theme],
                                       env={**os.environ, "PYINSTALLER_RESET_ENVIRONMENT": "1"})
        except OSError:
            if signals:
                shutil.rmtree(signals, ignore_errors=True)
            self._fallback_view(target, tab)
            return
        self.views[key] = (process, signals, time.monotonic() + 25, target)

    def _poll_views(self, now):
        for key, (process, signals, deadline, target) in list(self.views.items()):
            status = process.poll()
            if status is None and ((signals / READY).is_file() or now < deadline):
                continue
            if status is None:
                (signals / CLOSE).touch()
                hwnd = _view_handle(process, signals, key)
                if hwnd:
                    win.post_message(hwnd, 0x10, 0, 0)
            if not (signals / READY).is_file():
                self._fallback_view(target, key == "settings")
            if status is not None:
                shutil.rmtree(signals, ignore_errors=True)
            del self.views[key]

    def _fallback_view(self, target, tab):
        self.view_backend = "edge-app" if self.backend else "browser"
        if not self.backend:
            webbrowser.open(target)
            return
        try:
            size = "1100,780" if tab is None else "760,740"
            subprocess.Popen([str(self.backend), f"--app={target}", f"--user-data-dir={self.profile / 'EdgeApp'}",
                              f"--window-size={size}", "--no-first-run", "--disable-sync", "--disable-background-mode"])
        except OSError as error:
            self.service.message = f"Windows 无法打开独立窗口：{error}"
            webbrowser.open(target)

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
        if rect != self.strip_rect:
            self.strip_background.configure(bg="#58aa9b" if hovered else "#428c80")
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
        height = max(320, content_height(self.service.latest or {}, self.settings, self.service.active) + FOOTER_HEIGHT)
        size = dict(width=min(WIDTH, max(1, visible["width"] - 32)), height=height)
        placement = panel_placement(anchor, size, visible, self.settings["edge"])
        self.panel_monitor, self.panel_frame = monitor, placement["frame"]
        self.panel_open = True
        self.service._panel_visible = True
        self.bridge = self.strip_rect if from_strip else None
        self.collapse.opened(time.monotonic())
        win.show_window(self.strip_hwnd, win.SW_HIDE)
        self.strip_rect = None
        self.last_render_key = None
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
        return self.panel_rect is not None and rounded_contains(self.panel_rect, point, 20 * self.panel_monitor[3])

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
            desired = max(320, content_height(sample, self.settings, active) + FOOTER_HEIGHT)
            frame["height"] = min(desired, max(1, monitor[2]["height"] - 2 * PANEL_INSET))
            frame["y"] = min(frame["y"], max(PANEL_INSET, monitor[2]["height"] - PANEL_INSET - frame["height"]))
        rect = _physical(frame, monitor)
        key = (sample.get("timestamp"), self.theme, paused, busy, active and (active["id"], int(time.time())),
               self.settings.get("showSensors"), int(time.time()) // 5, rect)
        if not force and key == self.last_render_key:
            return
        self.last_render_key = key
        if force or rect != self.panel_rect:
            win.show_rect(self.panel_hwnd, rect, max(1, round(20 * monitor[3])))
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
            self.tray.tooltip("搞机灵" + paused + cpu + memory + "\n单击打开面板，右键更多选项")
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
        self.root.after(33, self._tick)

    def _tick_desktop(self):
        for _ in range(20):
            try:
                command = self.commands.get_nowait()
            except Empty:
                break
            command()
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
            self._close_panel()
            self._close_views()
            if self.shortcut_registered:
                win.unregister_hotkey(self.hwnd, 1)
            self.tray.close()
            win.destroy_window(self.hwnd)
            win.unregister_class(_WINDOW_CLASS, self.module)
            self.root.destroy()

    def _close_views(self):
        for key, (process, signals, _, _) in self.views.items():
            (signals / CLOSE).touch()
            hwnd = _view_handle(process, signals, key)
            if hwnd:
                win.post_message(hwnd, 0x10, 0, 0)
        deadline = time.monotonic() + 12
        for process, signals, _, _ in self.views.values():
            try:
                process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                continue
            shutil.rmtree(signals, ignore_errors=True)

    def request_quit(self):
        self.commands.put(self.root.quit)


def report_error(message):
    ctypes_message_box = win.user.MessageBoxW
    ctypes_message_box.argtypes = (win.w.HWND, win.w.LPCWSTR, win.w.LPCWSTR, win.w.UINT)
    ctypes_message_box(None, str(message), "搞机灵", 0x10)
