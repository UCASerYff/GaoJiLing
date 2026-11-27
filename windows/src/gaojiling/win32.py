"""Win32 desktop APIs used by the non-activating monitor and notification icon."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
import os


user = c.WinDLL("user32", use_last_error=True)
shell = c.WinDLL("shell32", use_last_error=True)
kernel = c.WinDLL("kernel32", use_last_error=True)
gdi = c.WinDLL("gdi32", use_last_error=True)
shcore = c.WinDLL("shcore", use_last_error=True)

LR_LOADFROMFILE = 0x10
WM_COMMAND, WM_HOTKEY, WM_TRAY = 0x111, 0x312, 0x803B
WM_CONTEXTMENU, WM_RBUTTONUP = 0x7B, 0x205
WM_LBUTTONUP, NIN_SELECT, NIN_KEYSELECT = 0x202, 0x400, 0x401
SW_HIDE, SW_SHOWNOACTIVATE = 0, 4
SWP_NOACTIVATE, SWP_NOOWNERZORDER = 0x10, 0x200
WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE = 0x80, 0x08000000
GWLP_EXSTYLE = -20
MODIFIERS = 0x4003  # MOD_ALT | MOD_CONTROL | MOD_NOREPEAT
ROOT = 2
NOTIFY_ID = 1

WNDCALL = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
HOOKCALL = c.WINFUNCTYPE(c.c_ssize_t, c.c_int, w.WPARAM, w.LPARAM)
ENUMWINDOWS = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)


def _api(dll, name, result, *args):
    function = getattr(dll, name)
    function.restype = result
    function.argtypes = args
    return function


class WindowClass(c.Structure):
    _fields_ = [("style", w.UINT), ("callback", WNDCALL), ("classExtra", c.c_int),
                ("windowExtra", c.c_int), ("module", w.HINSTANCE), ("icon", w.HICON),
                ("cursor", w.HANDLE), ("brush", w.HBRUSH), ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]


class MouseEvent(c.Structure):
    _fields_ = [("point", w.POINT), ("mouseData", w.DWORD), ("flags", w.DWORD),
                ("time", w.DWORD), ("extraInfo", c.c_size_t)]


class MonitorInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("monitor", w.RECT), ("work", w.RECT),
                ("flags", w.DWORD), ("name", w.WCHAR * 32)]


class Guid(c.Structure):
    _fields_ = [("bytes", c.c_ubyte * 16)]


class NotifyData(c.Structure):
    _fields_ = [("size", w.DWORD), ("hwnd", w.HWND), ("id", w.UINT), ("flags", w.UINT),
                ("message", w.UINT), ("icon", w.HICON), ("tip", w.WCHAR * 128),
                ("state", w.DWORD), ("stateMask", w.DWORD), ("info", w.WCHAR * 256),
                ("version", w.UINT), ("title", w.WCHAR * 64), ("infoFlags", w.DWORD),
                ("guid", Guid), ("balloonIcon", w.HICON)]


class NotifyIdentifier(c.Structure):
    _fields_ = [("size", w.DWORD), ("hwnd", w.HWND), ("id", w.UINT), ("guid", Guid)]


module_handle = _api(kernel, "GetModuleHandleW", w.HMODULE, w.LPCWSTR)
create_mutex = _api(kernel, "CreateMutexW", w.HANDLE, c.c_void_p, w.BOOL, w.LPCWSTR)
close_handle = _api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
register_class = _api(user, "RegisterClassW", w.ATOM, c.POINTER(WindowClass))
unregister_class = _api(user, "UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)
create_window = _api(user, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                     c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p)
destroy_window = _api(user, "DestroyWindow", w.BOOL, w.HWND)
def_window_proc = _api(user, "DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
find_window = _api(user, "FindWindowW", w.HWND, w.LPCWSTR, w.LPCWSTR)
post_message = _api(user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
register_message = _api(user, "RegisterWindowMessageW", w.UINT, w.LPCWSTR)
register_hotkey = _api(user, "RegisterHotKey", w.BOOL, w.HWND, c.c_int, w.UINT, w.UINT)
unregister_hotkey = _api(user, "UnregisterHotKey", w.BOOL, w.HWND, c.c_int)
set_hook = _api(user, "SetWindowsHookExW", w.HANDLE, c.c_int, HOOKCALL, w.HINSTANCE, w.DWORD)
unhook = _api(user, "UnhookWindowsHookEx", w.BOOL, w.HANDLE)
next_hook = _api(user, "CallNextHookEx", c.c_ssize_t, w.HANDLE, c.c_int, w.WPARAM, w.LPARAM)
get_key = _api(user, "GetAsyncKeyState", c.c_short, c.c_int)
get_cursor = _api(user, "GetCursorPos", w.BOOL, c.POINTER(w.POINT))
get_ancestor = _api(user, "GetAncestor", w.HWND, w.HWND, w.UINT)
get_style = _api(user, "GetWindowLongPtrW", c.c_ssize_t, w.HWND, c.c_int)
set_style = _api(user, "SetWindowLongPtrW", c.c_ssize_t, w.HWND, c.c_int, c.c_ssize_t)
set_window_pos = _api(user, "SetWindowPos", w.BOOL, w.HWND, w.HWND, c.c_int, c.c_int, c.c_int,
                      c.c_int, w.UINT)
show_window = _api(user, "ShowWindow", w.BOOL, w.HWND, c.c_int)
is_iconic = _api(user, "IsIconic", w.BOOL, w.HWND)
set_region = _api(user, "SetWindowRgn", c.c_int, w.HWND, w.HANDLE, w.BOOL)
rounded_region = _api(gdi, "CreateRoundRectRgn", w.HANDLE, c.c_int, c.c_int, c.c_int,
                      c.c_int, c.c_int, c.c_int)
delete_object = _api(gdi, "DeleteObject", w.BOOL, w.HANDLE)
enum_windows = _api(user, "EnumWindows", w.BOOL, ENUMWINDOWS, w.LPARAM)
window_text = _api(user, "GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
window_pid = _api(user, "GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))
window_visible = _api(user, "IsWindowVisible", w.BOOL, w.HWND)
set_foreground = _api(user, "SetForegroundWindow", w.BOOL, w.HWND)
monitor_nearest = _api(user, "MonitorFromPoint", w.HANDLE, w.POINT, w.DWORD)
get_monitor = _api(user, "GetMonitorInfoW", w.BOOL, w.HANDLE, c.POINTER(MonitorInfo))
get_dpi = _api(shcore, "GetDpiForMonitor", w.LONG, w.HANDLE, c.c_int, c.POINTER(w.UINT), c.POINTER(w.UINT))
ENUMMONITORS = c.WINFUNCTYPE(w.BOOL, w.HANDLE, w.HDC, c.POINTER(w.RECT), w.LPARAM)
enum_monitors = _api(user, "EnumDisplayMonitors", w.BOOL, w.HDC, c.POINTER(w.RECT), ENUMMONITORS, w.LPARAM)
load_icon = _api(user, "LoadIconW", w.HICON, w.HINSTANCE, c.c_void_p)
load_image = _api(user, "LoadImageW", w.HANDLE, w.HINSTANCE, w.LPCWSTR, w.UINT, c.c_int, c.c_int, w.UINT)
destroy_icon = _api(user, "DestroyIcon", w.BOOL, w.HICON)
create_menu = _api(user, "CreatePopupMenu", w.HMENU)
append_menu = _api(user, "AppendMenuW", w.BOOL, w.HMENU, w.UINT, c.c_size_t, w.LPCWSTR)
track_menu = _api(user, "TrackPopupMenu", w.UINT, w.HMENU, w.UINT, c.c_int, c.c_int, c.c_int, w.HWND, c.c_void_p)
destroy_menu = _api(user, "DestroyMenu", w.BOOL, w.HMENU)
notify_icon = _api(shell, "Shell_NotifyIconW", w.BOOL, w.DWORD, c.POINTER(NotifyData))
notify_rect = _api(shell, "Shell_NotifyIconGetRect", w.LONG, c.POINTER(NotifyIdentifier), c.POINTER(w.RECT))
button_messages = {0x201: (0, True), 0x202: (0, False), 0x204: (1, True), 0x205: (1, False),
                   0x207: (2, True), 0x208: (2, False), 0x20B: (3, True), 0x20C: (3, False)}


def setup_dpi():
    # Do this before creating a single HWND, including the hidden command window.
    try:
        _api(user, "SetProcessDpiAwarenessContext", w.BOOL, w.HANDLE)(-4)
    except AttributeError:
        _api(shcore, "SetProcessDpiAwareness", w.LONG, c.c_int)(2)
    _api(shell, "SetCurrentProcessExplicitAppUserModelID", w.LONG, w.LPCWSTR)("com.gaoseries.GaoJiLing")


def cursor():
    point = w.POINT()
    get_cursor(c.byref(point))
    return point.x, point.y


def pressed_buttons():
    return sum(1 << index for index, key in enumerate((1, 2, 4, 5, 6)) if get_key(key) < 0)


def monitor(handle):
    info = MonitorInfo(size=c.sizeof(MonitorInfo))
    if not get_monitor(handle, c.byref(info)):
        raise c.WinError(c.get_last_error())
    dpi_x, dpi_y = w.UINT(96), w.UINT(96)
    result = get_dpi(handle, 0, c.byref(dpi_x), c.byref(dpi_y))
    scale = dpi_x.value / 96 if result == 0 else 1
    bounds = info.work
    visible = dict(x=0.0, y=0.0, width=(bounds.right - bounds.left) / scale,
                   height=(bounds.bottom - bounds.top) / scale)
    return info.name, (bounds.left, bounds.top), visible, scale


def current_monitor(point):
    return monitor(monitor_nearest(w.POINT(*point), 2))


def named_monitor(name):
    if not name:
        return None
    result = []

    @ENUMMONITORS
    def callback(handle, _dc, _rect, _params):
        info = monitor(handle)
        if info[0] == name:
            result.append(info)
            return False
        return True

    enum_monitors(None, None, callback, 0)
    return result[0] if result else None


def tk_window(widget):
    content = widget.winfo_id()
    return get_ancestor(content, ROOT) or content


def no_activate(hwnd):
    set_style(hwnd, GWLP_EXSTYLE, get_style(hwnd, GWLP_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)


def show_rect(hwnd, rect, radius):
    x, y, width, height = rect
    set_window_pos(hwnd, -1, x, y, width, height, SWP_NOACTIVATE | SWP_NOOWNERZORDER)
    region = rounded_region(0, 0, width + 1, height + 1, radius * 2, radius * 2)
    if region and not set_region(hwnd, region, True):
        delete_object(region)
    show_window(hwnd, SW_SHOWNOACTIVATE)


def find_view(process_id: int, title: str):
    matches = []

    @ENUMWINDOWS
    def callback(hwnd, _param):
        pid = w.DWORD()
        window_pid(hwnd, c.byref(pid))
        if pid.value == process_id and window_visible(hwnd):
            buffer = c.create_unicode_buffer(512)
            window_text(hwnd, buffer, len(buffer))
            if buffer.value.startswith(title):
                matches.append(hwnd)
                return False
        return True

    enum_windows(callback, 0)
    return matches[0] if matches else None


def new_icon(path):
    if path and os.path.isfile(path):
        icon = load_image(None, str(path), 1, 0, 0, LR_LOADFROMFILE | 0x40)
        if icon:
            return icon, True
    return load_icon(None, 32512), False


class Tray:
    def __init__(self, hwnd, icon):
        self.hwnd = hwnd
        self.icon, self.owns_icon = new_icon(icon)
        self.available = False
        self.version4 = False
        self.tip = "搞机灵"
        self.register()

    def _data(self):
        return NotifyData(size=c.sizeof(NotifyData), hwnd=self.hwnd, id=NOTIFY_ID)

    def register(self):
        data = self._data()
        data.flags = 1 | 2 | 4 | 0x80
        data.message = WM_TRAY
        data.icon = self.icon
        data.tip = self.tip[:100]
        self.available = bool(notify_icon(0, c.byref(data)))
        if self.available:
            data.version = 4
            self.version4 = bool(notify_icon(4, c.byref(data)))

    def tooltip(self, tip):
        if tip != self.tip:
            self.tip = tip
            data = self._data()
            data.flags = 4 | 0x80
            data.tip = tip[:100]
            notify_icon(1, c.byref(data))

    def notify(self, title, detail):
        data = self._data()
        data.flags = 0x10
        # Bound UTF-16 length, including supplementary characters.
        data.title = title.encode("utf-16-le")[:120].decode("utf-16-le", errors="ignore")
        data.info = detail.encode("utf-16-le")[:490].decode("utf-16-le", errors="ignore")
        data.infoFlags = 1 | 0x80  # NIIF_INFO | NIIF_RESPECT_QUIET_TIME
        return self.available and bool(notify_icon(1, c.byref(data)))

    def contains(self, x, y):
        identifier = NotifyIdentifier(size=c.sizeof(NotifyIdentifier), hwnd=self.hwnd, id=NOTIFY_ID)
        rect = w.RECT()
        return notify_rect(c.byref(identifier), c.byref(rect)) == 0 and rect.left <= x < rect.right and rect.top <= y < rect.bottom

    def close(self):
        notify_icon(2, c.byref(self._data()))
        if self.owns_icon:
            destroy_icon(self.icon)
