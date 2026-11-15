"""全机 CPU 以 0–100% 计算。第一次采样没有基线时不把 CPU 写成 0。

传感器读不到就保持不可用。Windows 上的内存压力是可用内存比例的估算，并在来源里写明。
"""

from __future__ import annotations

import os
import time


def _unavailable(reason: str) -> dict:
    return {"value": None, "reason": reason}


class MetricCollector:
    def __init__(self):
        self.previous_cpu = None
        self.previous_net = None
        self.previous_disk = None
        self.previous_processes = None
        self.previous_at = None

    def sample(self) -> dict:
        import sys
        if sys.platform == "win32":
            return self._windows()
        if sys.platform.startswith("linux"):
            return self._linux()
        return self._empty("当前平台没有已实现的采样器")

    def _empty(self, reason: str) -> dict:
        return {
            "timestamp": time.time(),
            "cpuPercent": None,
            "cpuReason": reason,
            "memoryUsed": None,
            "memoryTotal": None,
            "memoryCompressed": None,
            "swapUsed": None,
            "memoryPressure": "未知",
            "networkDown": None,
            "networkUp": None,
            "diskRead": None,
            "diskWrite": None,
            "diskFree": None,
            "diskTotal": None,
            "gpuPercent": None,
            "cpuTemperature": None,
            "batteryPercent": None,
            "batteryCharging": False,
            "uptime": None,
            "processCount": None,
            "thermalState": "未知",
            "processes": [],
            "sensorReason": reason,
        }

    def _rates(self, current_net, current_disk, now: float):
        down = up = read = write = None
        if self.previous_net is not None and self.previous_at and now > self.previous_at:
            elapsed = now - self.previous_at
            down = max(0, (current_net[0] - self.previous_net[0]) / elapsed)
            up = max(0, (current_net[1] - self.previous_net[1]) / elapsed)
        if self.previous_disk is not None and self.previous_at and now > self.previous_at:
            elapsed = now - self.previous_at
            read = max(0, (current_disk[0] - self.previous_disk[0]) / elapsed)
            write = max(0, (current_disk[1] - self.previous_disk[1]) / elapsed)
        self.previous_net = current_net
        self.previous_disk = current_disk
        return down, up, read, write

    def _linux(self) -> dict:
        now = time.time()
        cpu_total, cpu_idle = _linux_cpu()
        mem = _linux_mem()
        processes, cpu_times = _linux_processes()
        net = _linux_net()
        disk = _linux_disk()
        usage = None
        reason = "初次 CPU 基线不可用"
        if self.previous_cpu and self.previous_at and now > self.previous_at:
            total = cpu_total - self.previous_cpu[0]
            idle = cpu_idle - self.previous_cpu[1]
            if total > 0:
                usage = max(0.0, min(100.0, (total - idle) / total * 100))
                reason = None
                elapsed = now - self.previous_at
                cores = os.cpu_count() or 1
                for process in processes:
                    previous = self.previous_processes.get(process["pid"]) if self.previous_processes else None
                    if previous is None:
                        process["cpuAvailable"] = False
                        process["cpuPercent"] = None
                        process["availabilityReason"] = "初次 CPU 基线不可用"
                    else:
                        delta = cpu_times[process["pid"]] - previous
                        process["cpuPercent"] = max(0.0, min(100.0, delta / elapsed / cores * 100))
                        process["cpuAvailable"] = True
        else:
            for process in processes:
                process["cpuAvailable"] = False
                process["cpuPercent"] = None
                process["availabilityReason"] = "初次 CPU 基线不可用"
        self.previous_cpu = (cpu_total, cpu_idle)
        self.previous_processes = cpu_times
        self.previous_at = now
        down, up, read, write = self._rates(net, disk, now)
        free_disk, total_disk = _linux_disk_space()
        battery = _linux_battery()
        pressure = "未知"
        if mem["total"] and mem["available"] is not None:
            ratio = mem["available"] / mem["total"]
            pressure = "正常" if ratio > 0.2 else "偏高" if ratio > 0.1 else "严重"
        return {
            "timestamp": now,
            "cpuPercent": usage,
            "cpuReason": reason,
            "memoryUsed": mem["used"],
            "memoryTotal": mem["total"],
            "memoryCompressed": None,
            "swapUsed": mem["swap"],
            "memoryPressure": pressure,
            "memorySource": "Linux /proc/meminfo。压力按可用内存比例估算，不是 macOS 内存压力。压缩内存不可用。",
            "networkDown": down,
            "networkUp": up,
            "diskRead": read,
            "diskWrite": write,
            "diskFree": free_disk,
            "diskTotal": total_disk,
            "gpuPercent": None,
            "cpuTemperature": None,
            "batteryPercent": battery.get("percent"),
            "batteryCharging": battery.get("charging") or False,
            "uptime": _linux_uptime(),
            "processCount": len(processes),
            "thermalState": "未知",
            "processes": processes,
            "sensorReason": "此平台没有已验证的温度、风扇、GPU 或功率接口，不填 0。",
        }


def _linux_cpu():
    parts = open("/proc/stat", encoding="utf-8").readline().split()
    numbers = [float(item) for item in parts[1:]]
    idle = numbers[3] + (numbers[4] if len(numbers) > 4 else 0)
    return sum(numbers), idle


def _linux_mem():
    info = {}
    for line in open("/proc/meminfo", encoding="utf-8"):
        key, _, rest = line.partition(":")
        info[key] = int(rest.strip().split()[0]) * 1024
    total = info.get("MemTotal") or 0
    available = info.get("MemAvailable")
    swap = max(0, (info.get("SwapTotal") or 0) - (info.get("SwapFree") or 0))
    used = None if available is None or not total else max(0, total - available)
    return {"total": total or None, "available": available, "used": used, "swap": swap}


def _linux_processes():
    cores = os.cpu_count() or 1
    processes = []
    times = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            stat = open(f"/proc/{pid}/stat", encoding="utf-8").read()
            command = open(f"/proc/{pid}/comm", encoding="utf-8").read().strip()
            start = float(stat.rsplit(")", 1)[1].split()[19])
            fields = stat.rsplit(")", 1)[1].split()
            utime = float(fields[11])
            stime = float(fields[12])
            rss_pages = float(fields[21])
        except (OSError, IndexError, ValueError):
            continue
        path = None
        try:
            path = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            pass
        clk = os.sysconf("SC_CLK_TCK")
        page = os.sysconf("SC_PAGE_SIZE")
        times[pid] = (utime + stime) / clk
        processes.append({
            "pid": pid,
            "name": command or str(pid),
            "path": path,
            "memoryBytes": rss_pages * page,
            "pids": [pid],
            "groupID": path or command,
            "identities": [[pid, start / clk, os.getuid()]],
            "cpuPercent": None,
            "cpuAvailable": False,
        })
    # 按路径合并，CPU 在有基线后才填。
    grouped = {}
    for process in processes:
        key = process["groupID"] or process["name"]
        current = grouped.get(key)
        if current is None:
            grouped[key] = process
        else:
            current["memoryBytes"] += process["memoryBytes"]
            current["pids"].extend(process["pids"])
            current["identities"].extend(process["identities"])
    return list(grouped.values()), times


def _linux_net():
    received = transmitted = 0
    for line in open("/proc/net/dev", encoding="utf-8").readlines()[2:]:
        name, _, rest = line.partition(":")
        if name.strip() == "lo":
            continue
        parts = rest.split()
        received += int(parts[0])
        transmitted += int(parts[8])
    return received, transmitted


def _linux_disk():
    read = write = 0
    for line in open("/proc/diskstats", encoding="utf-8"):
        parts = line.split()
        if len(parts) < 14 or parts[2].startswith("loop") or parts[2].startswith("ram"):
            continue
        if any(char.isdigit() for char in parts[2]):
            continue
        read += int(parts[5]) * 512
        write += int(parts[9]) * 512
    return read, write


def _linux_disk_space():
    info = os.statvfs("/")
    total = info.f_frsize * info.f_blocks
    free = info.f_frsize * info.f_bavail
    return free, total


def _linux_uptime():
    try:
        return float(open("/proc/uptime", encoding="utf-8").read().split()[0])
    except (OSError, ValueError):
        return None


def _linux_battery():
    root = "/sys/class/power_supply"
    if not os.path.isdir(root):
        return {"percent": None, "charging": False}
    for name in os.listdir(root):
        base = os.path.join(root, name)
        try:
            kind = open(os.path.join(base, "type"), encoding="utf-8").read().strip()
        except OSError:
            continue
        if kind != "Battery":
            continue
        try:
            capacity = int(open(os.path.join(base, "capacity"), encoding="utf-8").read().strip())
            status = open(os.path.join(base, "status"), encoding="utf-8").read().strip()
        except (OSError, ValueError):
            return {"percent": None, "charging": False}
        if not 0 <= capacity <= 100:
            return {"percent": None, "charging": False}
        return {"percent": capacity, "charging": status == "Charging"}
    return {"percent": None, "charging": False}


def _windows(self) -> dict:
    # 绑定到类。放在模块级会在导入时就要求 ctypes 结构，Linux 测试不需要执行它。
    return _windows_sample(self)


MetricCollector._windows = _windows


def _windows_sample(collector: MetricCollector) -> dict:
    import ctypes
    from ctypes import wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

    def ticks(value: FILETIME) -> int:
        return (value.high << 32) + value.low

    idle, kernel, user = FILETIME(), FILETIME(), FILETIME()
    if not ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
        cpu_now = None
    else:
        cpu_now = (ticks(kernel) + ticks(user), ticks(idle))
    now = time.time()
    usage = None
    reason = "初次 CPU 基线不可用"
    if collector.previous_cpu and cpu_now and collector.previous_at and now > collector.previous_at:
        total = cpu_now[0] - collector.previous_cpu[0]
        idle_delta = cpu_now[1] - collector.previous_cpu[1]
        if total > 0:
            usage = max(0.0, min(100.0, (total - idle_delta) / total * 100))
            reason = None
    collector.previous_cpu = cpu_now
    collector.previous_at = now
    from gaojiling.memory import _windows_snapshot
    memory = _windows_snapshot() or {}
    free_disk, total_disk = _windows_disk()
    battery = _windows_battery()
    return {
        "timestamp": now,
        "cpuPercent": usage,
        "cpuReason": reason,
        "memoryUsed": memory.get("used"),
        "memoryTotal": memory.get("total"),
        "memoryCompressed": None,
        "swapUsed": memory.get("swap"),
        "memoryPressure": memory.get("pressure") or "未知",
        "memorySource": memory.get("source"),
        "networkDown": None,
        "networkUp": None,
        "diskRead": None,
        "diskWrite": None,
        "diskFree": free_disk,
        "diskTotal": total_disk,
        "gpuPercent": None,
        "cpuTemperature": None,
        "batteryPercent": battery.get("percent"),
        "batteryCharging": battery.get("charging") or False,
        "uptime": ctypes.windll.kernel32.GetTickCount64() / 1000,
        "processCount": None,
        "thermalState": "未知",
        "processes": _windows_processes(),
        "sensorReason": "没有已验证的温度、风扇、GPU 或功率接口，不填 0。进程 CPU 需要两次采样；第一次不显示 0。",
    }


def _windows_disk():
    import ctypes
    free = ctypes.c_ulonglong()
    total = ctypes.c_ulonglong()
    if not ctypes.windll.kernel32.GetDiskFreeSpaceExW("C:\\", ctypes.byref(free), ctypes.byref(total), None):
        return None, None
    return int(free.value), int(total.value)


def _windows_battery():
    import ctypes
    from ctypes import wintypes

    class SYSTEM_POWER_STATUS(ctypes.Structure):
        _fields_ = [
            ("ACLineStatus", ctypes.c_byte), ("BatteryFlag", ctypes.c_byte),
            ("BatteryLifePercent", ctypes.c_byte), ("SystemStatusFlag", ctypes.c_byte),
            ("BatteryLifeTime", wintypes.DWORD), ("BatteryFullLifeTime", wintypes.DWORD),
        ]

    status = SYSTEM_POWER_STATUS()
    if not ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(status)):
        return {"percent": None, "charging": False}
    if status.BatteryFlag == 128 or status.BatteryLifePercent == 255:
        return {"percent": None, "charging": False}
    percent = int(status.BatteryLifePercent)
    if not 0 <= percent <= 100:
        return {"percent": None, "charging": False}
    return {"percent": percent, "charging": status.ACLineStatus == 1 and status.BatteryFlag & 8 == 8}


def _windows_processes():
    """进程表第一次没有 CPU 基线。这里只列名称和内存，CPU 留空。"""
    import ctypes
    from ctypes import wintypes
    TH32CS_SNAPPROCESS = 0x00000002

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
            ("szExeFile", ctypes.c_wchar * 260),
        ]

    snapshot = ctypes.windll.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        return []
    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(entry)
    found = []
    try:
        ok = ctypes.windll.kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            found.append({
                "pid": int(entry.th32ProcessID),
                "name": entry.szExeFile,
                "path": None,
                "memoryBytes": 0,
                "pids": [int(entry.th32ProcessID)],
                "groupID": entry.szExeFile,
                "cpuPercent": None,
                "cpuAvailable": False,
                "availabilityReason": "Windows 进程列表只核对名称。没有打开进程句柄，CPU 不填 0。",
            })
            ok = ctypes.windll.kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        ctypes.windll.kernel32.CloseHandle(snapshot)
    return found[:40]
