"""采样频率与异常事件。间隙超过 15 秒会清空持续计时，不把休眠时间补进阈值。"""

from __future__ import annotations

from gaojiling.textutil import bytes_text, percent_text


def sampling_interval(preferred: float, visible: bool, panel_visible: bool, recording: bool,
                      history_required: bool, rules_enabled: bool) -> float:
    base = min(10.0, max(1.0, preferred)) if preferred == preferred and preferred not in (float("inf"), float("-inf")) else 2.0
    if visible or panel_visible or recording or rules_enabled:
        return base
    return max(base, 5.0 if history_required else 10.0)


class EventDetector:
    def __init__(self):
        self.since = {}
        self.last = {}
        self.swap_baseline = None
        self.previous = None

    def reset(self):
        self.since.clear()
        self.last.clear()
        self.swap_baseline = None
        self.previous = None

    def evaluate(self, sample: dict) -> list[dict]:
        stamp = sample["timestamp"]
        if self.previous is not None and stamp - self.previous > 15:
            self.reset()
        self.previous = stamp
        result = []

        def check(key, active, delay, title, detail, severity="提醒"):
            if not active:
                self.since.pop(key, None)
                return
            self.since.setdefault(key, stamp)
            if stamp - self.since[key] < delay or stamp - self.last.get(key, -1e100) < 600:
                return
            self.last[key] = stamp
            result.append({"date": stamp, "title": title, "detail": detail, "severity": severity, "kind": key})

        top = None
        for process in sample.get("processes") or []:
            if process.get("cpuAvailable") is False:
                continue
            if top is None or process.get("cpuPercent") or 0 > top.get("cpuPercent") or 0:
                top = process
        if top:
            process_detail = f"此时 {top['name']} 使用全机 CPU 的 {percent_text(top.get('cpuPercent'))}。这是同一时段的观测，不代表已确定卡顿原因。"
        else:
            process_detail = "可在回看中查看同一时段的指标。"
        cpu = sample.get("cpuPercent")
        check("cpu", cpu is not None and cpu >= 85, 30, "CPU 持续繁忙", "全机 CPU 连续 30 秒超过 85%。" + process_detail)
        check("memory", sample.get("memoryPressure") in {"偏高", "紧张", "警告", "严重"}, 20, "内存压力升高",
              f"内存压力已持续 20 秒偏高。当前压缩内存 {bytes_text(sample.get('memoryCompressed'))}，Swap {bytes_text(sample.get('swapUsed'))}。", "关注")
        total = sample.get("diskTotal") or 0
        free = sample.get("diskFree") or 0
        check("disk", total > 0 and free < min(10 * 1073741824, total * 0.05), 0, "磁盘空间不足",
              f"启动磁盘剩余 {bytes_text(free)}。建议检查不再需要的大文件。", "关注")
        check("thermal", sample.get("thermalState") in {"严重", "危急"}, 20, "系统散热压力升高",
              f"系统报告散热状态为“{sample.get('thermalState')}”，持续超过 20 秒。可检查正在运行的高负载任务。", "关注")
        if self.swap_baseline and stamp - self.swap_baseline["timestamp"] >= 60:
            grown = (sample.get("swapUsed") or 0) - (self.swap_baseline.get("swapUsed") or 0)
            check("swap", grown > 536870912, 0, "Swap 快速增长",
                  f"过去约一分钟 Swap 增加 {bytes_text(grown)}。结合内存压力和应用排行判断是否影响当前工作。")
            self.swap_baseline = sample
        elif self.swap_baseline is None:
            self.swap_baseline = sample
        return result
