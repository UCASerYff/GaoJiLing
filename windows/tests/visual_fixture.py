"""Serve the real Windows UI against a new synthetic workspace for screen checks."""
import argparse
import math
import time
import uuid
from pathlib import Path
from unittest.mock import patch

from gaojiling.metrics import reading
from gaojiling.service import Service
from gaojiling.web import serve


def fixture(when, index):
    gib = 2**30
    mib = 2**20
    cpu = 34 + 12 * math.sin(index / 4) + 7 * math.sin(index * 1.3)
    memory = (13.7 + 1.2 * math.sin(index / 7)) * gib
    sample = {
        "timestamp": when, "cpuPercent": cpu, "corePercents": [cpu] * 12,
        "memoryUsed": memory, "memoryTotal": 32 * gib, "memoryPressure": "正常",
        "diskFree": 327 * gib, "diskTotal": 930 * gib, "diskRead": 19 * mib, "diskWrite": 6 * mib,
        "networkDown": 3.6 * mib, "networkUp": .42 * mib, "gpuPercent": 18.2,
        "cpuTemperature": None, "fanRPM": None, "uptime": 18165, "batteryPercent": 76,
        "batteryCharging": False, "thermalState": "正常",
    }
    sample["readings"] = {
        "cpu": reading(cpu, "%", when, "隔离样本 · GetSystemTimes"),
        "memory": reading(memory, "B", when, "隔离样本 · GlobalMemoryStatusEx"),
        "diskFree": reading(sample["diskFree"], "B", when, "隔离样本 · GetDiskFreeSpaceEx"),
        "networkDown": reading(sample["networkDown"], "B/s", when, "隔离样本 · GetIfTable2"),
        "gpu": reading(18.2, "%", when, "隔离样本 · Windows PDH"),
        "temperature": reading(None, "°C", when, "固件", "该设备未提供 CPU 温度"),
        "thermalState": reading("正常", "", when, "隔离样本 · Windows PDH"),
    }
    sample["processes"] = [
        {"name": name, "cpuPercent": percent, "memoryBytes": usage * mib, "pids": [index + 101], "cpuAvailable": True}
        for index, (name, percent, usage) in enumerate([
            ("渲染测试", 21.4, 1764), ("素材预览", 8.2, 710), ("音频转码", 4.6, 474), ("文件校验", 1.2, 115)
        ])
    ]
    return sample


def add_comparison_sessions(service, when):
    runs = (
        ("批处理 · 首次", when - 4500, 115, (40, 42, 44, 46, 48, 50), 8, 3),
        ("批处理 · 复测", when - 4000, 79, (20, 25, 30, 35, 40, 45), 10, 1),
    )
    for name, start, duration, cpu_readings, memory_gib, weight in runs:
        clock = start
        previous_sample = None
        with patch("gaojiling.service.now_unix", side_effect=lambda: clock):
            service.start_session(name)
            for index, (elapsed, cpu) in enumerate(zip((5, 15, 25, 52, 62, 72), cpu_readings)):
                clock = start + elapsed
                sample = fixture(clock, index)
                memory = round((memory_gib - 1 + index / 5) * 2**30)
                sample.update(cpuPercent=cpu, memoryUsed=memory, corePercents=[cpu] * 12,
                              processBaselineAt=previous_sample)
                sample["readings"]["cpu"] = reading(cpu, "%", clock, "隔离会话样本")
                sample["readings"]["memory"] = reading(memory, "B", clock, "隔离会话样本")
                sample["processes"] = [
                    {"name": title, "groupID": "package:" + slug, "observedAt": clock, "pids": [pid],
                     "cpuPercent": base + weight * index, "cpuAvailable": True, "memoryBytes": memory_mib * 2**20}
                    for title, slug, pid, base, memory_mib in (
                        ("报表工作进程", "report", 121, 13, 760), ("消息分发进程", "queue", 122, 6, 320),
                    )
                ]
                service.sample_once(sample)
                previous_sample = clock
            clock = start + duration
            service.stop_session()
    start = when - 3700
    service.store.save_session({"id": str(uuid.uuid4()), "name": "旧任务 · 无采样", "start": start, "end": start + 45,
                                "peakCPU": 0, "peakMemory": 0, "peakTemperature": None,
                                "sampleCount": 0, "cpuTotal": 0, "interrupted": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("port", type=int, nargs="?", help="Loopback port when serving the fixture")
    parser.add_argument("--comparison", action="store_true", help="Add two measured tasks and one older task without samples")
    parser.add_argument("--seed-only", action="store_true", help="Write the fixture for a packaged launcher and exit")
    args = parser.parse_args()
    if args.port is None and not args.seed_only:
        parser.error("a port is required unless using --seed-only")
    args.workspace.mkdir()
    scope = args.workspace / "素材"
    scope.mkdir()
    for name in ("导出", "中间文件", "输入"):
        nested = scope / name
        nested.mkdir()
        (nested / "fixture.bin").write_bytes(bytes(range(256)) * (256 if name == "导出" else 96))
    service = Service(args.workspace / "data", home=args.workspace, collector=object())
    service.hardware = "x64 · 12 个逻辑处理器"
    when = time.time()
    if args.comparison:
        add_comparison_sessions(service, when)
    for i in range(48):
        if i not in {24, 25, 26, 27, 28}:
            service.sample_once(fixture(when - (47 - i) * 10, i))
    service.store.add_event({"date": when - 125, "title": "CPU 持续高负载", "detail": "合成事件，用于检查回看定位和时间标记。",
                             "severity": "提醒", "kind": "cpu"})
    for title, seconds, average, highest, memory in (("素材导出", 745, 43, 82, 18), ("更新后回归", 275, 27, 68, 12)):
        start = when - 6750 - seconds
        service.store.save_session({"id": str(uuid.uuid4()), "name": title, "start": start, "end": start + seconds,
                                    "peakCPU": highest, "peakMemory": memory * 2**30, "peakTemperature": None,
                                    "sampleCount": 20, "cpuTotal": average * 20, "lastObserved": start + seconds,
                                    "interrupted": False})
    try:
        if not args.seed_only:
            with serve(service, port=args.port)[0] as server:
                server.serve_forever()
    finally:
        service.close()


if __name__ == "__main__":
    main()
