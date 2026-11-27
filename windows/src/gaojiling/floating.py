"""Drawing and layout for the compact system monitor."""

from __future__ import annotations

import math
import tkinter as tk
import time


WIDTH = 398
FOOTER_HEIGHT = 49
PALETTES = {
    "light": {"canvas": "#f5f5f1", "card": "#ffffff", "line": "#e6e7e2", "text": "#232726",
              "muted": "#5e6664", "accent": "#297a6e", "accentBackground": "#e8f0eb",
              "blue": "#597dad", "amber": "#c47a2b"},
    "dark": {"canvas": "#1a1d1f", "card": "#25292a", "line": "#333839", "text": "#edf1f0",
             "muted": "#a4aeac", "accent": "#66c2ab", "accentBackground": "#253a37",
             "blue": "#8cb3e8", "amber": "#f0b05c"},
}


def rounded_contains(box, point, radius):
    x, y, width, height = box
    px, py = point
    if not (x <= px < x + width and y <= py < y + height):
        return False
    radius = min(radius, width / 2, height / 2)
    dx = max(x + radius - px, px - (x + width - radius), 0)
    dy = max(y + radius - py, py - (y + height - radius), 0)
    return dx * dx + dy * dy <= radius * radius


def has_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def percent(value):
    return f"{value:.0f}%" if has_number(value) else "—"


def byte_size(value):
    if not has_number(value) or value < 0:
        return "—"
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if value < 1024 or unit == "PB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024


def elapsed(start):
    seconds = max(0, int(time.time() - start))
    hours, rest = divmod(seconds, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


def get_processes(sample):
    processes = [item for item in sample.get("processes", []) if isinstance(item, dict)]
    return sorted(processes, key=lambda item: item["cpuPercent"] if has_number(item.get("cpuPercent")) else -1,
                  reverse=True)[:3]


def content_height(sample, settings, active):
    return 20 + (118 if sample.get("corePercents") else 110) + 12 + 93 + 12 + 58 + 12 + 17 + max(1, len(get_processes(sample))) * 27 + (68 if settings.get("showSensors") else 0) + (47 if active else 0) + 12


class PanelContent:
    def __init__(self, window, on_pause, on_open, on_start, on_move, on_end):
        self.body = tk.Canvas(window, highlightthickness=0, borderwidth=0)
        self.body.pack(side="top", fill="both", expand=True)
        self.footer = tk.Canvas(window, highlightthickness=0, borderwidth=0)
        self.footer.pack(side="bottom", fill="x", expand=False)
        self.body.bind("<MouseWheel>", self._scroll)
        self.body.bind("<ButtonPress-1>", lambda event: on_start() if self.body.canvasy(event.y) < self.scale * 142 else None)
        self.body.bind("<B1-Motion>", lambda _event: on_move())
        self.body.bind("<ButtonRelease-1>", lambda _event: on_end())
        self.footer.bind("<ButtonRelease-1>", self._click_footer)
        self.on_pause = on_pause
        self.on_open = on_open
        self.scale = 1
        self.layout = None
        self.chart_bottom = 0

    def _scroll(self, event):
        if self.layout and self.chart_bottom > self.layout[1] - FOOTER_HEIGHT:
            self.body.yview_scroll(-1 if event.delta > 0 else 1, "units")

    def _click_footer(self, event):
        x = event.x / self.scale
        if self.layout and x >= self.layout[0] - 120:
            self.on_open()
        elif 110 <= x <= 148:
            self.on_pause()

    def update(self, width, height, scale, sample, settings, active, paused, charts, appearance, busy=False):
        previous_shape = self.layout
        self.layout, self.scale, self.color = (width, height, scale), scale, PALETTES[appearance]
        self.chart_bottom = content_height(sample, settings, active)
        self.body.configure(bg=self.color["canvas"], width=round(width * scale),
                            height=round(max(1, height - FOOTER_HEIGHT) * scale),
                            scrollregion=(0, 0, round(width * scale), round(self.chart_bottom * scale)),
                            yscrollincrement=round(24 * scale))
        self.footer.configure(bg=self.color["canvas"], height=round(FOOTER_HEIGHT * scale))
        if previous_shape != self.layout:
            self.body.yview_moveto(0)
        self.body.delete("all")
        self.footer.delete("all")
        self._draw(sample, settings, active, paused, charts, busy)

    def _draw(self, sample, settings, active, paused, charts, busy):
        width, _, _ = self.layout
        x, end = 22, width - 22
        text = self.body
        c = self.color
        cpu = sample.get("cpuPercent")
        unavailable = "不可用" if sample else "等待采样"
        self._text(text, x, 20, "CPU 占用", 11, "muted")
        self._text(text, x, 36, percent(cpu), 51, "text")
        description = "已暂停采样" if paused else ("从容运行" if cpu < 30 else "正在忙碌" if cpu < 75 else "全力以赴") if has_number(cpu) else unavailable
        self._text(text, end, 49, description, 11, "amber" if paused else "accent", anchor="ne")
        cores = sample.get("corePercents") or []
        self._text(text, end, 68, f"{len(cores)} 核心" if cores else f"核心数据{unavailable}", 10, "muted", anchor="ne")
        self._chart(x, 95, end - x, 30, charts.get("cpuPercent", []), "accent")
        if cores:
            size = (end - x) / len(cores)
            for index, core in enumerate(cores):
                left = x + index * size
                self._round(text, left, 133, left + max(0.5, size - 3), 137, 2, "line")
                if has_number(core):
                    self._round(text, left, 133, left + max(0.5, (size - 3) * min(max(core, 0), 100) / 100), 137, 2, "accent")
        y = 150 if cores else 142
        self._round(text, x, y, end, y + 93, 13, "card")
        self._text(text, x + 12, y + 13, "内存", 11, "text", weight="bold")
        total = sample.get("memoryTotal")
        valid_memory = has_number(total) and total > 0
        pressure = sample.get("memoryPressure") if valid_memory else None
        self._text(text, end - 12, y + 13, f"压力 · {pressure}" if pressure else unavailable, 10, "accent", anchor="ne")
        self._text(text, x + 12, y + 34, byte_size(sample.get("memoryUsed")) if valid_memory else "—", 21, "text")
        self._text(text, x + 100, y + 43, f"/ {byte_size(total)}", 11, "muted")
        swap = sample.get("swapUsed")
        self._text(text, end - 12, y + 43, f"Swap {byte_size(swap)}" if swap is not None else f"Swap {unavailable}", 10, "muted", anchor="ne")
        self._bar(x + 12, y + 75, end - x - 24, sample.get("memoryPercent") if valid_memory else None, "blue")
        y += 105
        self._round(text, x, y, end, y + 58, 13, "card")
        half = (end - x) / 2
        self._line(text, x + half, y + 9, x + half, y + 49, "line")
        for left, label, key, ink in ((x + 12, "↓ 下载", "networkDown", "accent"),
                                        (x + half + 12, "↑ 上传", "networkUp", "blue")):
            rate = sample.get(key)
            self._text(text, left, y + 11, label, 11, "muted")
            self._text(text, left, y + 27, f"{byte_size(rate)}/s" if has_number(rate) else "—", 17, "text")
            self._chart(left + max(0, half - 57), y + 30, 32, 18, charts.get(key, []), ink)
        y += 70
        self._text(text, x, y, "活跃应用", 11, "text", weight="bold")
        self._text(text, end, y, "CPU · 全机口径", 10, "muted", anchor="ne")
        y += 17
        processes = get_processes(sample)
        if not processes:
            self._text(text, x, y + 6, "暂未获取应用数据" if sample else "等待应用采样…", 11, "muted")
            y += 27
        for item in processes:
            self._round(text, x, y + 4, x + 18, y + 22, 4, "accentBackground")
            self._text(text, x + 9, y + 13, "▦", 10, "accent", anchor="center")
            name = str(item.get("name") or "—")
            self._text(text, x + 26, y + 6, name if len(name) <= 24 else name[:23] + "…", 11, "text")
            self._text(text, end - 56, y + 6, byte_size(item.get("memoryBytes") or item.get("memory")), 10, "muted", anchor="ne")
            self._text(text, end, y + 6, percent(item.get("cpuPercent")), 11, "accent", anchor="ne")
            y += 27
        if settings.get("showSensors"):
            y += 10
            self._line(text, x, y, end, y, "line")
            temperature = sample.get("cpuTemperature")
            battery = sample.get("batteryPercent")
            label = "电池 · 充电中" if sample.get("batteryCharging") else "电池"
            battery_or_disk = (label, percent(battery)) if has_number(battery) else ("磁盘可用", byte_size(sample.get("diskFree")) if sample.get("diskTotal") else None)
            sensors = (("CPU 温度", f"{temperature:.0f} °C" if has_number(temperature) else None),
                       ("热状态", sample.get("thermalState")), battery_or_disk)
            for index, (label, value) in enumerate(sensors):
                left = x + index * (end - x) / 3
                self._text(text, left, y + 9, label, 11, "muted")
                self._text(text, left, y + 25, value or "—", 16, "text")
                if not value or value == "—":
                    self._text(text, left, y + 44, unavailable, 10, "muted")
            y += 58
        if active:
            self._round(text, x, y + 10, end, y + 44, 8, "accentBackground")
            self._text(text, x + 11, y + 20, "●  " + str(active.get("name", ""))[:26], 11, "accent")
            self._text(text, end - 10, y + 20, elapsed(active["start"]), 11, "accent", anchor="ne")
        footer = self.footer
        self._line(footer, 0, 0, width, 0, "line")
        age = time.time() - sample.get("timestamp", time.time())
        status = "处理资料中" if busy else "已暂停" if paused else ("读数过期" if age > 15 else "实时监控") if sample else "等待采样"
        dot = "amber" if paused else "accent"
        self._round(footer, x, 23, x + 5, 28, 3, dot)
        self._text(footer, x + 10, 19, status, 11, "muted")
        self._text(footer, 129, 25, "▶" if paused else "Ⅱ", 11, "muted" if busy else "text", weight="bold", anchor="center")
        self._text(footer, end, 19, "打开主窗口  ↗", 11, "accent", weight="bold", anchor="ne")

    def _bar(self, x, y, width, value, color):
        self._round(self.body, x, y, x + width, y + 4, 2, "line")
        if has_number(value) and value > 0:
            self._round(self.body, x, y, x + width * min(value, 100) / 100, y + 4, 2, color)

    def _chart(self, x, y, width, height, points, color):
        values = [item for item in points if has_number(item)]
        if len(points) < 2 or not values:
            self._line(self.body, x, y + height, x + width, y + height, "line")
            return
        maximum = max(max(values), 1)
        path = []
        for index, value in enumerate([*points, None]):
            if has_number(value):
                path.extend((x + width * index / (len(points) - 1), y + height - height * value / maximum))
            elif path:
                if len(path) >= 4:
                    self.body.create_line(*self._scale(path), fill=self.color[color], width=max(1, self.scale * 1.4))
                path = []

    def _text(self, canvas, x, y, label, size, color, weight="normal", anchor="nw"):
        canvas.create_text(*self._scale((x, y)), text=label, anchor=anchor, fill=self.color[color],
                           font=("Microsoft YaHei UI", -max(1, round(size * self.scale)), weight))

    def _line(self, canvas, x1, y1, x2, y2, color):
        canvas.create_line(*self._scale((x1, y1, x2, y2)), fill=self.color[color], width=max(1, self.scale))

    def _round(self, canvas, x1, y1, x2, y2, radius, color):
        r = min(radius, max((x2 - x1) / 2, 0), max((y2 - y1) / 2, 0))
        points = (x1+r, y1, x2-r, y1, x2, y1, x2, y1+r, x2, y2-r, x2, y2,
                  x2-r, y2, x1+r, y2, x1, y2, x1, y2-r, x1, y1+r, x1, y1)
        canvas.create_polygon(*self._scale(points), smooth=True, splinesteps=16, fill=self.color[color])

    def _scale(self, points):
        return tuple(self.scale * point for point in points)
