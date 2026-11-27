"""Non-activating desktop monitor layout and its native drawing surface."""

from __future__ import annotations

import math
from dataclasses import dataclass
import time
import tkinter as tk
from tkinter import font


WIDTH = 368
PANEL_RADIUS = 16
FOOTER_HEIGHT = 50
PALETTES = {
    "light": {"canvas": "#f3f7f6", "card": "#ffffff", "line": "#dbe8e4", "text": "#132825",
              "muted": "#526764", "accent": "#007b68", "accentBackground": "#e1f1ed",
              "blue": "#3573be", "amber": "#986000", "hover": "#d2e9e3"},
    "dark": {"canvas": "#111b1c", "card": "#182627", "line": "#2e4342", "text": "#e7f3f0",
             "muted": "#a7bcb8", "accent": "#59cdb5", "accentBackground": "#216052",
             "blue": "#84aff1", "amber": "#efb66c", "hover": "#28463f"},
}


@dataclass(frozen=True)
class Box:
    x: float
    y: float
    width: float
    height: float

    @property
    def right(self):
        return self.x + self.width

    @property
    def bottom(self):
        return self.y + self.height

    def contains(self, x, y):
        return self.x <= x < self.right and self.y <= y < self.bottom


@dataclass(frozen=True)
class Layout:
    cpu: Box
    memory: Box
    network: tuple[Box, Box]
    apps: Box
    sensors: Box | None
    task: Box | None
    height: int


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
            digits = 0 if unit == "B" else 1
            return f"{value:.{digits}f} {unit}"
        value /= 1024


def elapsed(start):
    seconds = max(0, int(time.time() - start))
    hours, rest = divmod(seconds, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


def process_cpu(process):
    value = process.get("cpuPercent")
    return value if process.get("cpuAvailable") is not False and has_number(value) else None


def get_processes(sample):
    processes = [item for item in sample.get("processes") or () if isinstance(item, dict)]
    return sorted(processes, key=lambda item: value if (value := process_cpu(item)) is not None else -1,
                  reverse=True)[:3]


def memory_percent(sample):
    used, total = sample.get("memoryUsed"), sample.get("memoryTotal")
    if has_number(used) and used >= 0 and has_number(total) and total > 0:
        return min(100.0, used / total * 100)
    return None


def panel_layout(width, sample, settings, active):
    margin = min(13, width / 8)
    gap = 8
    inner = width - 2 * margin
    cores = sample.get("corePercents")
    row_height = 117 if cores else 105
    if width >= 302:
        cpu = Box(margin, margin, (inner - gap) * 0.56, row_height)
        memory = Box(cpu.right + gap, margin, inner - cpu.width - gap, row_height)
    else:
        cpu = Box(margin, margin, inner, row_height)
        memory = Box(margin, cpu.bottom + gap, inner, 105)
    y = memory.bottom + gap
    if width >= 248:
        half = (inner - gap) / 2
        network = (Box(margin, y, half, 63), Box(margin + half + gap, y, half, 63))
    else:
        network = (Box(margin, y, inner, 63), Box(margin, y + 63 + gap, inner, 63))
    apps = Box(margin, network[-1].bottom + gap, inner, 35 + 24 * max(1, len(get_processes(sample))))
    y = apps.bottom + gap
    sensors = None
    if settings.get("showSensors"):
        sensors = Box(margin, y, inner, 56 if width >= 248 else 108)
        y = sensors.bottom + gap
    task = Box(margin, y, inner, 34) if active else None
    return Layout(cpu, memory, network, apps, sensors, task, round((task.bottom if task else y - gap) + margin))


def content_height(sample, settings, active, width=WIDTH):
    return panel_layout(width, sample, settings, active).height


def footer_layout(width):
    margin = min(13, width / 8)
    opened = min(100 if width >= 300 else 67, width * 0.40)
    paused = min(55, width * 0.26)
    top = (FOOTER_HEIGHT - 30) / 2
    main = Box(width - margin - opened, top, opened, 30)
    pause = Box(main.x - 6 - paused, top, paused, 30)
    return pause, main


def panel_status(sample, paused, busy, now):
    if busy:
        return "处理资料中", "amber"
    if paused:
        return "已暂停", "amber"
    stamp = sample.get("timestamp")
    if not has_number(stamp):
        return "等待采样", "muted"
    if now - stamp > 15:
        return "读数过期", "amber"
    return "实时监控", "accent"


class PanelContent:
    def __init__(self, window, on_pause, on_open, on_start, on_move, on_end):
        self.body = tk.Canvas(window, highlightthickness=0, borderwidth=0)
        self.body.pack(side="top", fill="both", expand=True)
        self.footer = tk.Canvas(window, highlightthickness=0, borderwidth=0)
        self.footer.pack(side="bottom", fill="x", expand=False)
        self.on_pause, self.on_open = on_pause, on_open
        self.on_start, self.on_move, self.on_end = on_start, on_move, on_end
        self.body.bind("<MouseWheel>", self._scroll)
        self.body.bind("<Motion>", self._drag_cursor)
        self.body.bind("<Leave>", lambda _event: self.body.configure(cursor=""))
        self.body.bind("<ButtonPress-1>", self._drag_begin)
        self.body.bind("<B1-Motion>", self._drag_move)
        self.body.bind("<ButtonRelease-1>", self._drag_end)
        self.footer.bind("<Motion>", self._footer_hover)
        self.footer.bind("<Leave>", lambda _event: self._set_footer_target(None))
        self.footer.bind("<ButtonPress-1>", self._footer_press)
        self.footer.bind("<ButtonRelease-1>", self._footer_release)
        families = font.families(window)
        self.text_face = next((face for face in ("Microsoft YaHei UI", "Microsoft YaHei", "DengXian", "SimSun")
                              if face in families), "Segoe UI")
        self.numeric_face = "Segoe UI Variable Text" if "Segoe UI Variable Text" in families else "Segoe UI"
        self.font_cache = {}
        self.width = self.scale = 1
        self.body_visible = 0
        self.layout = self.footer_state = None
        self.hover = self.pressed = None
        self.dragging = False
        self.scroll = tk.Scrollbar(window, orient="vertical", command=self.body.yview, takefocus=False)
        self.body.configure(yscrollcommand=self.scroll.set)

    def reset_view(self):
        self.body.yview_moveto(0)
        self.dragging = False
        self.hover = self.pressed = None

    def _scroll(self, event):
        if self.layout and self.layout.height > self.body_visible and event.delta:
            steps = max(1, round(abs(event.delta) / 120))
            self.body.yview_scroll(-steps if event.delta > 0 else steps, "units")

    def _on_cpu(self, event):
        return self.layout and self.layout.cpu.contains(event.x / self.scale, self.body.canvasy(event.y) / self.scale)

    def _drag_cursor(self, event):
        self.body.configure(cursor="fleur" if self._on_cpu(event) else "")

    def _drag_begin(self, event):
        if self._on_cpu(event):
            self.dragging = True
            self.on_start()

    def _drag_move(self, _event):
        if self.dragging:
            self.on_move()

    def _drag_end(self, _event):
        if self.dragging:
            self.dragging = False
            self.on_end()

    def _footer_target(self, event):
        if not self.footer_state:
            return None
        x, y = event.x / self.scale, event.y / self.scale
        pause, main = footer_layout(self.width)
        if main.contains(x, y):
            return "main"
        if not self.footer_state[2] and pause.contains(x, y):
            return "pause"
        return None

    def _set_footer_target(self, target):
        if target != self.hover:
            self.hover = target
            self.footer.configure(cursor="hand2" if target else "")
            self._draw_footer()

    def _footer_hover(self, event):
        self._set_footer_target(self._footer_target(event))

    def _footer_press(self, event):
        self.pressed = self._footer_target(event)

    def _footer_release(self, event):
        pressed, self.pressed = self.pressed, None
        if pressed and pressed == self._footer_target(event):
            (self.on_pause if pressed == "pause" else self.on_open)()

    def update(self, width, height, scale, sample, settings, active, paused, charts, appearance, busy=False):
        reset_scroll = width != self.width or scale != self.scale
        if scale != self.scale:
            self.font_cache.clear()
        self.width, self.scale, self.color = width, scale, PALETTES[appearance]
        self.layout = panel_layout(width, sample, settings, active)
        self.body_visible = max(1, height - FOOTER_HEIGHT)
        self.body.configure(bg=self.color["canvas"], width=round(width * scale), height=round(self.body_visible * scale),
                            scrollregion=(0, 0, round(width * scale),
                                          round(max(self.layout.height, self.body_visible) * scale)),
                            yscrollincrement=max(1, round(18 * scale)))
        self.footer.configure(bg=self.color["canvas"], height=round(FOOTER_HEIGHT * scale))
        if self.layout.height > self.body_visible:
            self.scroll.configure(bg=self.color["card"], activebackground=self.color["hover"],
                                  troughcolor=self.color["canvas"], borderwidth=0, highlightthickness=0)
            self.scroll.place(relx=1, y=0, anchor="ne", height=round(self.body_visible * scale), width=round(10 * scale))
        else:
            self.scroll.place_forget()
        if reset_scroll:
            self.body.yview_moveto(0)
        self.body.delete("all")
        unavailable = "等待读数" if not sample else "不可用"
        self._draw_cpu(sample, charts, unavailable)
        self._draw_memory(sample, unavailable)
        self._draw_network(sample, charts, unavailable)
        self._draw_apps(sample, unavailable)
        if self.layout.sensors:
            self._draw_sensors(sample, unavailable)
        if self.layout.task:
            self._draw_task(active)
        self.footer_state = (sample, paused, busy)
        self._draw_footer()

    def _draw_cpu(self, sample, charts, unavailable):
        box, canvas = self.layout.cpu, self.body
        self._box(canvas, box, "card")
        x, top, right = box.x + 11, box.y, box.right - 11
        self._text(canvas, x, top + 9, "CPU", 12, "text", bold=True)
        self._text(canvas, right, top + 10, "全机", 10, "muted", anchor="ne")
        cpu = sample.get("cpuPercent")
        self._text(canvas, x, top + 25, percent(cpu), 32, "text", bold=True, max_width=right - x)
        if not has_number(cpu):
            reason = "等待基线" if "基线" in (sample.get("cpuReason") or "") else unavailable
            self._text(canvas, right, top + 34, reason, 11, "muted", anchor="ne", max_width=max(0, right - x - 32))
        trend = charts.get("cpuPercent", ())
        self._chart(x, top + 65, right - x, 20, trend, "accent", maximum=100)
        cores = sample.get("corePercents") or ()
        if cores:
            label = f"{sample.get('logicalProcessorCount') or len(cores)} 逻辑处理器"
            label_width = min(right - x, self._font(label, 10, False).measure(label) / self.scale)
            self._text(canvas, x, top + 96, label, 10, "muted", max_width=right - x)
            if right - x - label_width >= 26:
                self._draw_cores(x + label_width + 7, top + 100, right, cores)

    def _draw_cores(self, x, y, right, cores):
        # Compress high core counts into adjacent buckets so the plot stays legible.
        count = min(len(cores), max(1, int((right - x) // 5)))
        stride = (right - x) / count
        for index in range(count):
            group = cores[index * len(cores) // count:(index + 1) * len(cores) // count]
            readings = [value for value in group if has_number(value)]
            level = sum(readings) / len(readings) if readings else None
            self._bar(x + stride * index, y, stride - 2, level, "accent", height=4)

    def _draw_memory(self, sample, unavailable):
        box, canvas = self.layout.memory, self.body
        self._box(canvas, box, "card")
        x, top, right = box.x + 11, box.y, box.right - 11
        used, total = sample.get("memoryUsed"), sample.get("memoryTotal")
        pressure = sample.get("memoryPressure")
        usage = memory_percent(sample)
        self._text(canvas, x, top + 9, "内存", 12, "text", bold=True)
        if pressure and pressure != "未知" and usage is not None:
            tone = "amber" if pressure in {"偏高", "高", "紧张", "严重"} else "muted"
            self._text(canvas, right, top + 10, pressure, 10, tone, anchor="ne", max_width=right - x - 29)
        self._text(canvas, x, top + 25, byte_size(used) if usage is not None else unavailable,
                   23 if usage is not None else 16, "text" if usage is not None else "muted",
                   bold=True, max_width=right - x)
        self._bar(x, top + 56, right - x, usage, "blue", height=5)
        self._text(canvas, x, top + 66, f"总量 {byte_size(total)}", 10, "muted", max_width=right - x)
        self._text(canvas, x, top + 83, f"分页文件 {byte_size(sample.get('swapUsed'))}", 10, "muted", max_width=right - x)

    def _draw_network(self, sample, charts, unavailable):
        specs = (("↓ 下载", "networkDown", "accent"), ("↑ 上传", "networkUp", "blue"))
        for box, (label, key, color) in zip(self.layout.network, specs):
            self._box(self.body, box, "card")
            x, y, right = box.x + 11, box.y, box.right - 11
            self._text(self.body, x, y + 9, label, 11, "muted", bold=True)
            if right - x >= 95 and "GetIfTable2" in sample.get("readings", {}).get(key, {}).get("source", ""):
                self._text(self.body, right, y + 10, "物理网卡", 10, "muted", anchor="ne")
            rate = sample.get(key)
            known = has_number(rate) and rate >= 0
            label = f"{byte_size(rate)}/s" if known else unavailable
            size = 18 if known else 13
            rate_width = self._font(label, size, True).measure(label) / self.scale
            self._text(self.body, x, y + 30, label, size, "text" if known else "muted",
                       bold=True, max_width=right - x)
            width = min(35, right - x - rate_width - 8)
            if width >= 19 and known:
                self._chart(right - width, y + 30, width, 18, charts.get(key, ()), color)

    def _draw_apps(self, sample, unavailable):
        canvas, box = self.body, self.layout.apps
        self._box(canvas, box, "card")
        x, top, right = box.x + 11, box.y, box.right - 11
        workset_width = min(71, (right - x) * 0.30)
        cpu_right = right - workset_width
        cpu_width = min(51, (right - x) * 0.24)
        name_width = cpu_right - cpu_width - x
        self._text(canvas, x, top + 9, "活跃应用", 12, "text", bold=True, max_width=name_width)
        self._text(canvas, cpu_right, top + 10, "CPU", 10, "muted", anchor="ne", max_width=cpu_width)
        self._text(canvas, right, top + 10, "工作集", 10, "muted", anchor="ne", max_width=workset_width - 4)
        processes = get_processes(sample)
        if not processes:
            self._text(canvas, x, top + 31, "暂无应用读数" if sample else unavailable, 11, "muted", max_width=right - x)
        for index, item in enumerate(processes):
            y = top + 27 + index * 24
            self._line(canvas, x, y, right, y, "line")
            name = str(item.get("name") or "—")
            self._text(canvas, x, y + 5, name, 11, "text", max_width=name_width)
            value = process_cpu(item)
            self._text(canvas, cpu_right, y + 5, percent(value), 11, "accent" if value is not None else "muted",
                       anchor="ne", max_width=cpu_width)
            memory = item.get("memoryBytes")
            if memory is None:
                memory = item.get("memory")
            self._text(canvas, right, y + 5, byte_size(memory), 11, "text", anchor="ne", max_width=workset_width - 5)

    def _draw_sensors(self, sample, unavailable):
        box, canvas = self.layout.sensors, self.body
        self._box(canvas, box, "card")
        temperature = sample.get("cpuTemperature")
        thermal = sample.get("thermalState")
        if thermal == "未检测到热节流":
            thermal = "无热节流"
        if thermal == "未知":
            thermal = None
        battery = sample.get("batteryPercent")
        label = "电池 · 充电" if sample.get("batteryCharging") else "电池"
        disk = sample.get("diskFree")
        third = (label, percent(battery)) if has_number(battery) else ("系统盘可用", byte_size(disk) if has_number(disk) else None)
        values = (("CPU 温度", f"{temperature:.0f} °C" if has_number(temperature) else None),
                  ("热状态", thermal), third)
        columns = 3 if box.height == 56 else 2
        width = box.width / columns
        for index, (label, value) in enumerate(values):
            row, col = divmod(index, columns)
            left, top = box.x + col * width + 11, box.y + row * 52
            if col:
                self._line(canvas, left - 11, top + 11, left - 11, top + 43, "line")
            self._text(canvas, left, top + 8, label, 10, "muted", max_width=width - 20)
            self._text(canvas, left, top + 26, value or unavailable, 14 if value else 11,
                       "text" if value else "muted", bold=bool(value), max_width=width - 20)

    def _draw_task(self, active):
        box, canvas = self.layout.task, self.body
        self._box(canvas, box, "accentBackground")
        x, right = box.x + 11, box.right - 11
        y = box.y + box.height / 2
        clock = elapsed(active["start"])
        time_width = self._font(clock, 11, True).measure(clock) / self.scale
        self._text(canvas, x, y - 7, "任务", 11, "text", bold=True)
        self._text(canvas, x + 30, y - 7, str(active.get("name") or "未命名任务"), 11, "text",
                   max_width=right - time_width - x - 37)
        self._text(canvas, right, y - 7, clock, 11, "text", bold=True, anchor="ne")

    def _draw_footer(self):
        if not self.footer_state:
            return
        sample, paused, busy = self.footer_state
        canvas = self.footer
        canvas.delete("all")
        pause, main = footer_layout(self.width)
        self._line(canvas, 0, 1, self.width, 1, "line")
        status, tone = panel_status(sample, paused, busy, time.time())
        x, y = min(13, self.width / 8), FOOTER_HEIGHT / 2
        self._oval(canvas, Box(x, y - 3, 6, 6), tone)
        self._text(canvas, x + 12, y - 7, status, 11, "text", max_width=pause.x - x - 21)
        if self.width >= 360 and tone == "accent":
            clock = time.strftime("%H:%M", time.localtime(sample["timestamp"]))
            self._text(canvas, pause.x - 9, y - 6, clock, 10, "muted", anchor="ne")
        self._box(canvas, pause, "hover" if self.hover == "pause" and not busy else "card")
        self._text(canvas, pause.x + pause.width / 2, y, "恢复" if paused else "暂停", 11,
                   "muted" if busy else "text", bold=True, anchor="center", max_width=pause.width - 7)
        background = "hover" if self.hover == "main" else "accentBackground"
        self._box(canvas, main, background)
        self._text(canvas, main.x + main.width / 2, y, "打开主窗口 ↗" if self.width >= 300 else "主窗口",
                   11, "text", bold=True, anchor="center", max_width=main.width - 6)

    def _bar(self, x, y, width, value, color, height):
        if width <= 0:
            return
        self._box(self.body, Box(x, y, width, height), "line", radius=height / 2)
        if has_number(value) and value > 0:
            self._box(self.body, Box(x, y, width * min(value, 100) / 100, height), color, radius=height / 2)

    def _chart(self, x, y, width, height, points, color, maximum=None):
        if width <= 0:
            return
        self._line(self.body, x, y + height, x + width, y + height, "line")
        usable = [value for value in points if has_number(value) and value >= 0]
        if not usable:
            return
        ceiling = maximum or max(1, max(usable))
        run = []
        for index, value in enumerate([*points, None]):
            if has_number(value) and value >= 0:
                px = x + width * index / (len(points) - 1) if len(points) > 1 else x + width
                run.extend((px, y + height * (1 - min(ceiling, value) / ceiling)))
            elif run:
                if len(run) >= 4:
                    self.body.create_line(*self._scale(run), fill=self.color[color], width=max(1, self.scale * 1.5))
                else:
                    self._oval(self.body, Box(run[0] - 1.5, run[1] - 1.5, 3, 3), color)
                run.clear()

    def _font(self, label, size, bold):
        family = self.numeric_face if label.isascii() else self.text_face
        key = (family, size, bold)
        if key not in self.font_cache:
            self.font_cache[key] = font.Font(root=self.body, family=family, size=-max(1, round(size * self.scale)),
                                             weight="bold" if bold else "normal")
        return self.font_cache[key]

    def _text(self, canvas, x, y, label, size, color, bold=False, anchor="nw", max_width=None):
        face = self._font(label, size, bold)
        if max_width is not None and face.measure(label) > max_width * self.scale:
            pixels = max_width * self.scale
            if pixels < face.measure("…"):
                return
            # Find a measured prefix so CJK glyphs never cross numeric columns.
            lo, hi = 0, len(label)
            while lo < hi:
                middle = (lo + hi + 1) // 2
                if face.measure(label[:middle] + "…") <= pixels:
                    lo = middle
                else:
                    hi = middle - 1
            label = label[:lo] + "…"
        canvas.create_text(*self._scale((x, y)), text=label, anchor=anchor, fill=self.color[color], font=face)

    def _line(self, canvas, x1, y1, x2, y2, color):
        canvas.create_line(*self._scale((x1, y1, x2, y2)), fill=self.color[color], width=max(1, self.scale))

    def _oval(self, canvas, box, color):
        canvas.create_oval(*self._scale((box.x, box.y, box.right, box.bottom)), fill=self.color[color], outline="")

    def _box(self, canvas, box, color, radius=10):
        x1, y1, x2, y2 = box.x, box.y, box.right, box.bottom
        r = min(radius, box.width / 2, box.height / 2)
        points = (x1+r, y1, x2-r, y1, x2, y1, x2, y1+r, x2, y2-r, x2, y2,
                  x2-r, y2, x1+r, y2, x1, y2, x1, y2-r, x1, y1+r, x1, y1)
        canvas.create_polygon(*self._scale(points), smooth=True, splinesteps=16, fill=self.color[color])

    def _scale(self, points):
        return tuple(self.scale * point for point in points)
