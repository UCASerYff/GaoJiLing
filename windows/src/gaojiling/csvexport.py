"""监控 CSV。UTF-8 BOM、CRLF，公式前缀会被中和。"""

from gaojiling.textutil import csv_file
from gaojiling.timeutil import iso


def _number(value) -> str:
    if value is None:
        return ""
    return f"{float(value):.2f}"


def history_csv(samples: list[dict]) -> bytes:
    rows = [["时间", "CPU百分比", "内存字节", "总内存字节", "内存压力", "压缩内存字节", "Swap字节", "下载字节每秒", "上传字节每秒", "磁盘读字节每秒", "磁盘写字节每秒", "磁盘剩余字节", "GPU百分比", "温度摄氏度", "电池百分比"]]
    for sample in samples:
        rows.append([
            iso(sample["timestamp"]), _number(sample.get("cpuPercent")), _number(sample.get("memoryUsed")),
            _number(sample.get("memoryTotal")), sample.get("memoryPressure") or "", _number(sample.get("memoryCompressed")),
            _number(sample.get("swapUsed")), _number(sample.get("networkDown")), _number(sample.get("networkUp")),
            _number(sample.get("diskRead")), _number(sample.get("diskWrite")), _number(sample.get("diskFree")),
            _number(sample.get("gpuPercent")), _number(sample.get("cpuTemperature")), _number(sample.get("batteryPercent")),
        ])
    return csv_file(rows)


def events_csv(events: list[dict]) -> bytes:
    rows = [["时间", "标题", "详细信息", "级别", "类型"]]
    for event in events:
        rows.append([iso(event["date"]), event.get("title") or "", event.get("detail") or "", event.get("severity") or "", event.get("kind") or ""])
    return csv_file(rows)


def sessions_csv(sessions: list[dict]) -> bytes:
    rows = [["任务名称", "开始时间", "结束时间", "时长秒", "平均CPU百分比", "峰值CPU百分比", "峰值内存字节", "峰值温度摄氏度", "采样数量", "是否中断"]]
    for session in sessions:
        end = session.get("end")
        duration = 0 if end is None else max(0, end - session["start"])
        count = session.get("sampleCount") or 0
        average = (session.get("cpuTotal") or 0) / count if count else 0
        rows.append([
            session.get("name") or "", iso(session["start"]), iso(end) if end is not None else "", _number(duration),
            _number(average), _number(session.get("peakCPU")), _number(session.get("peakMemory")),
            _number(session.get("peakTemperature")), str(count), "是" if session.get("interrupted") else "否",
        ])
    return csv_file(rows)
