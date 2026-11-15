"""悬浮条与面板的纯几何、收回状态机。

浏览器里没有 macOS 的屏幕边缘窗口。这些函数保持同一套吸附、宽限和外部点击规则，
供页面里的紧凑面板使用；不能在桌面边缘悬停唤起。
"""

from __future__ import annotations

HIT_WIDTH = 20.0
HIT_HEIGHT = 104.0
VISUAL_WIDTH = 6.0
VISUAL_HEIGHT = 96.0
VERTICAL_INSET = 12.0
SNAP_DISTANCE = 32.0
DRAG_THRESHOLD = 4.0
OPENING_GRACE = 1.2
EXIT_DELAY = 0.15
EDGE_TOLERANCE = 0.5
PANEL_GAP = 8.0
PANEL_INSET = 12.0


def clamp_ratio(ratio: float) -> float:
    if ratio != ratio or ratio in (float("inf"), float("-inf")):
        return 0.5
    return min(max(ratio, 0.0), 1.0)


def _rect(x, y, width, height) -> dict:
    return {"x": float(x), "y": float(y), "width": float(width), "height": float(height)}


def handle_frame(visible: dict, edge: str, vertical_ratio: float, horizontal_ratio: float | None = None) -> dict:
    width = min(HIT_WIDTH, max(visible["width"], 1))
    height = min(HIT_HEIGHT, max(visible["height"] - VERTICAL_INSET * 2, 1))
    travel = max(visible["height"] - height - VERTICAL_INSET * 2, 0)
    ratio = clamp_ratio(horizontal_ratio) if horizontal_ratio is not None else (0.0 if edge == "left" else 1.0)
    x = visible["x"] + ratio * max(visible["width"] - width, 0)
    y = visible["y"] + min(VERTICAL_INSET, max((visible["height"] - height) / 2, 0)) + (1 - clamp_ratio(vertical_ratio)) * travel
    return _rect(x, y, width, height)


def vertical_ratio(frame: dict, visible: dict) -> float:
    travel = max(visible["height"] - frame["height"] - VERTICAL_INSET * 2, 0)
    if travel <= 0:
        return 0.5
    return clamp_ratio(1 - (frame["y"] - visible["y"] - VERTICAL_INSET) / travel)


def horizontal_ratio(frame: dict, visible: dict) -> float:
    travel = max(visible["width"] - frame["width"], 0)
    if travel <= 0:
        return 0.5
    return clamp_ratio((frame["x"] - visible["x"]) / travel)


def nearest_edge(point_x: float, visible: dict) -> str:
    return "left" if point_x < visible["x"] + visible["width"] / 2 else "right"


def dragging_handle(pointer: dict, grab: dict, visible: dict) -> dict:
    frame = handle_frame(visible, "left", 0.5, 0)
    low_y = visible["y"] + min(VERTICAL_INSET, max((visible["height"] - frame["height"]) / 2, 0))
    high_y = max(low_y, visible["y"] + visible["height"] - VERTICAL_INSET - frame["height"])
    frame["x"] = min(max(pointer["x"] - grab["x"], visible["x"]), max(visible["x"], visible["x"] + visible["width"] - frame["width"]))
    frame["y"] = min(max(pointer["y"] - grab["y"], low_y), high_y)
    left = frame["x"] - visible["x"]
    right = visible["x"] + visible["width"] - (frame["x"] + frame["width"])
    if min(left, right) <= SNAP_DISTANCE:
        frame["x"] = visible["x"] if left <= right else max(visible["x"], visible["x"] + visible["width"] - frame["width"])
    return frame


def _usable(visible: dict) -> dict:
    inset = min(PANEL_INSET, max(visible["width"] / 4, 0), max(visible["height"] / 4, 0))
    return _rect(visible["x"] + inset, visible["y"] + inset, max(visible["width"] - inset * 2, 1), max(visible["height"] - inset * 2, 1))


def _fitted(size: dict, bounds: dict) -> dict:
    return {"width": min(max(size["width"], 1), bounds["width"]), "height": min(max(size["height"], 1), bounds["height"])}


def _clamped(value, low, high):
    return min(max(value, low), high)


def panel_placement(anchor: dict, size: dict, visible: dict, preferred_edge: str) -> dict:
    bounds = _usable(visible)
    fitted = _fitted(size, bounds)
    left_docked = abs(anchor["x"] - visible["x"]) <= EDGE_TOLERANCE
    right_docked = abs((anchor["x"] + anchor["width"]) - (visible["x"] + visible["width"])) <= EDGE_TOLERANCE
    rightward = bounds["x"] if left_docked else anchor["x"] + anchor["width"] + PANEL_GAP
    leftward = bounds["x"] + bounds["width"] - fitted["width"] if right_docked else anchor["x"] - PANEL_GAP - fitted["width"]

    def fits(x):
        return x >= bounds["x"] - EDGE_TOLERANCE and x + fitted["width"] <= bounds["x"] + bounds["width"] + EDGE_TOLERANCE

    preferred = "left" if preferred_edge == "left" else "right"
    if left_docked and not right_docked:
        edge = "left"
    elif right_docked and not left_docked:
        edge = "right"
    elif fits(rightward if preferred == "left" else leftward):
        edge = preferred
    elif fits(leftward if preferred == "left" else rightward):
        edge = "right" if preferred == "left" else "left"
    else:
        right_space = bounds["x"] + bounds["width"] - (anchor["x"] + anchor["width"]) - PANEL_GAP
        left_space = anchor["x"] - PANEL_GAP - bounds["x"]
        edge = preferred if right_space == left_space else ("left" if right_space > left_space else "right")
    x = rightward if edge == "left" else leftward
    y = anchor["y"] + anchor["height"] / 2 - fitted["height"] / 2
    frame = _rect(
        _clamped(x, bounds["x"], bounds["x"] + bounds["width"] - fitted["width"]),
        _clamped(y, bounds["y"], bounds["y"] + bounds["height"] - fitted["height"]),
        fitted["width"],
        fitted["height"],
    )
    return {"frame": frame, "edge": edge}


class PanelAutoCollapse:
    def __init__(self):
        self.opened_at = None
        self.outside_since = None
        self.has_entered = False
        self.gesture_buttons = 0
        self.pending_focus_loss = False

    def opened(self, time: float):
        self.opened_at = time
        self.outside_since = None
        self.has_entered = False
        self.gesture_buttons = 0
        self.pending_focus_loss = False

    def closed(self):
        self.opened_at = None
        self.outside_since = None
        self.has_entered = False
        self.gesture_buttons = 0
        self.pending_focus_loss = False

    def mouse_down(self, button: int, inside_panel: bool) -> bool:
        if self.opened_at is None:
            return False
        if not inside_panel:
            return True
        self.has_entered = True
        self.outside_since = None
        mask = self._mask(button)
        if mask:
            self.gesture_buttons |= mask
        return False

    def mouse_up(self, button: int):
        mask = self._mask(button)
        if mask:
            self.gesture_buttons &= ~mask

    def should_collapse_on_focus_loss(self, pressed: int) -> bool:
        if self.opened_at is None:
            return False
        self.gesture_buttons &= pressed
        self.pending_focus_loss = True
        return self.gesture_buttons == 0

    def should_collapse(self, time: float, pointer_inside: bool, pointer_in_bridge: bool = False, pressed: int = 0) -> bool:
        if self.opened_at is None:
            return False
        self.gesture_buttons &= pressed
        if self.pending_focus_loss and self.gesture_buttons == 0:
            return True
        if pointer_inside:
            self.has_entered = True
            self.outside_since = None
            return False
        if self.gesture_buttons != 0 or (not self.has_entered and pointer_in_bridge):
            self.outside_since = None
            return False
        if not self.has_entered and time - self.opened_at < OPENING_GRACE:
            return False
        if self.outside_since is None:
            self.outside_since = time
            return False
        return time - self.outside_since >= EXIT_DELAY

    @staticmethod
    def _mask(button: int):
        if button < 0 or button >= 32:
            return None
        return 1 << button
