"""全机 CPU 以 0–100% 计算。第一次采样没有基线时不把 CPU 写成 0。

传感器读不到就保持不可用。Windows 上的内存压力是可用内存比例的估算，并在来源里写明。
"""

from __future__ import annotations

import os
import ntpath
import sys
import threading
import time


def reading(value, unit, timestamp, source, reason="本次读取不可用"):
    return {
        "value": value, "unit": unit, "timestamp": timestamp, "source": source,
        "availabilityReason": reason if value is None else None, "isStale": False,
    }


def _cpu_delta(previous, current):
    if previous is None or current is None:
        return None, None
    total = current[0] - previous[0]
    idle = current[1] - previous[1]
    if total <= 0 or not 0 <= idle <= total:
        return None, None
    return (total - idle) / total * 100, total


def _network_rates(previous, current, elapsed):
    if previous is None or current is None or elapsed <= 0 or previous.keys() != current.keys():
        return None, None
    down = up = 0
    for interface, (received, sent) in current.items():
        before = previous[interface]
        if received < before[0] or sent < before[1]:
            return None, None
        down += received - before[0]
        up += sent - before[1]
    return (down / elapsed, up / elapsed) if current else (None, None)


def _group_processes(inventory, previous, capacity_ticks, now):
    baselines, groups = {}, {}
    for process in inventory or []:
        pid, started, owner = process["pid"], process["startTicks"], process["ownerSID"]
        path, package = process["path"], process["packageFamily"]
        key = "package:" + package.casefold() if package else ntpath.normcase(path) if path else f"pid:{pid}"
        group = groups.setdefault(key, {
            "pid": pid, "name": process["name"], "path": path, "groupID": key, "pids": [],
            "identities": [], "cpuPercent": 0.0, "cpuAvailable": True, "memoryBytes": 0,
            "observedAt": now, "availabilityReason": None, "memoryAvailabilityReason": None,
        })
        group["pids"].append(pid)
        if started is not None and owner is not None and process["cpuTicks"] is not None:
            identity = (pid, started, owner)
            group["identities"].append({"pid": pid, "startTime": started, "ownerSID": owner})
            baselines[identity] = process["cpuTicks"]
            before = previous.get(identity)
            if capacity_ticks and before is not None and process["cpuTicks"] >= before:
                group["cpuPercent"] += (process["cpuTicks"] - before) / capacity_ticks * 100
            else:
                group["availabilityReason"] = "等待完整 CPU 基线采样"
        else:
            group["availabilityReason"] = "进程身份或 CPU 时间不可读取"
        memory = process["memoryBytes"]
        if memory is None:
            group["memoryAvailabilityReason"] = "进程工作集不可读取"
        else:
            group["memoryBytes"] += memory
    for group in groups.values():
        group["cpuAvailable"] = group["availabilityReason"] is None
        group["cpuPercent"] = min(100.0, group["cpuPercent"]) if group["cpuAvailable"] else None
        if group["memoryAvailabilityReason"] is not None:
            group["memoryBytes"] = None
    return sorted(groups.values(), key=lambda item: (
        item["cpuPercent"] is None, -(item["cpuPercent"] or 0), -(item["memoryBytes"] or 0),
        item["name"].casefold(), item["groupID"],
    )), baselines


class MetricCollector:
    def __init__(self):
        self._lock = threading.RLock()
        self._performance = None
        self._last_readings = {}
        self.previous_cpu = None
        self.previous_net = None
        self.previous_disk = None
        self.previous_processes = None
        self.previous_at = None
        self.previous_core_times = None
        self.previous_core_count = None

    def reset(self):
        with self._lock:
            if self._performance is not None:
                self._performance.close()
            self._last_readings.clear()
            self.previous_cpu = self.previous_net = self.previous_disk = self.previous_processes = self.previous_at = None
            self.previous_core_times = self.previous_core_count = None

    def sample(self) -> dict:
        with self._lock:
            if sys.platform == "win32":
                return self._windows()
            if sys.platform.startswith("linux"):
                return self._linux()
            return self._empty("当前平台没有已实现的采样器")

    def _windows(self):
        from gaojiling import winmetrics as native
        from gaojiling.memory import _windows_snapshot
        from gaojiling.winbattery import battery_snapshot

        now = time.time()
        at = time.monotonic()
        elapsed = at - self.previous_at if self.previous_at is not None else 0
        if elapsed > 15 or elapsed < 0:
            self.reset()
            elapsed = 0
        api = native.kernel()
        logical_processors = api.GetActiveProcessorCount(0xFFFF)
        cpu_now = native.cpu_times() if 0 < logical_processors <= 64 else None
        core_times = native.logical_cpu_times(logical_processors)
        same_topology = self.previous_core_count == logical_processors
        usage, capacity = _cpu_delta(self.previous_cpu if same_topology else None, cpu_now)
        counter = self._performance
        if counter is None:
            counter = self._performance = native.PerformanceCounters()
        ready = counter.collect()
        cores = native.core_percentages(counter.array("cores")) if ready and elapsed else []
        if len(cores) != logical_processors:
            cores = []
        if not cores and core_times and self.previous_core_times and same_topology:
            resolved = [_cpu_delta(old, new)[0] for old, new in zip(self.previous_core_times, core_times)]
            if len(resolved) == logical_processors and None not in resolved:
                cores = resolved
        cpu_source = "Windows GetSystemTimes · 全机 0–100%"
        if logical_processors > 64:
            usage = counter.value("cpu") if ready and elapsed else None
            cpu_source = "Windows PDH Processor Information(_Total) · 所有处理器组"
            capacity = elapsed * 10_000_000 * logical_processors if elapsed and same_topology else None
        cpu_reason = "等待有效 CPU 基线采样" if not elapsed else "本次 CPU 计数不可用或发生变化"
        inventory = native.process_inventory()
        groups, baselines = _group_processes(inventory, self.previous_processes or {}, capacity, now)
        network = native.network_counters()
        down, up = _network_rates(self.previous_net, network, elapsed)
        self.previous_at, self.previous_cpu = at, cpu_now
        self.previous_core_times, self.previous_core_count = core_times, logical_processors
        self.previous_net, self.previous_processes = network, baselines
        memory = _windows_snapshot() or {}
        free, total = native.boot_disk()
        battery = battery_snapshot(now, reading)
        disk_read = counter.value("diskRead", uncapped=True) if ready and elapsed else None
        disk_write = counter.value("diskWrite", uncapped=True) if ready and elapsed else None
        gpu = native.busiest_gpu_engine(counter.array("gpu")) if ready and elapsed else None
        zones = [
            {"name": name, "reading": reading(value - 273.15, "°C", now, "Windows PDH Thermal Zone Information")}
            for name, value in (counter.array("zones").items() if ready else [])
            if 173.0 <= value <= 473.2
        ]
        throttling = [int(value) for value in (counter.array("throttle").values() if ready else [])]
        thermal = ("热节流" if any(value & 1 for value in throttling) else "未检测到热节流") if throttling else None
        network_source = "Windows GetIfTable2：活动物理网卡字节计数差值"
        sensor_reason = "Windows 未提供经验证的跨机型 CPU 温度、转速或功率读数。热区数据按固件上报。"
        network_reason = "等待可比的网卡基线" if network else "活动物理网卡计数不可用"
        sample_readings = {
            "cpu": reading(usage, "%", now, cpu_source, cpu_reason),
            "memory": reading(memory.get("used"), "bytes", now, "Windows GlobalMemoryStatusEx"),
            "compressed": reading(None, "bytes", now, "Windows", "无通用已验证的压缩字节接口"),
            "swap": reading(memory.get("swap"), "bytes", now, "Windows EnumPageFilesW：分页文件实际在用页"),
            "pressure": reading(memory.get("pressure"), "level", now, "Windows GlobalMemoryStatusEx：按物理内存负载估算"),
            "gpu": reading(gpu, "%", now, "Windows PDH GPU Engine：最忙物理引擎", "等待 GPU 基线或驱动未提供可读计数"),
            "temperature": reading(None, "°C", now, "Windows", "固件热区不提供已核实的 CPU 封装温度"),
            "cpuPower": reading(None, "W", now, "Windows", "无通用已验证的 CPU 功率接口"),
            "gpuPower": reading(None, "W", now, "Windows", "无通用已验证的 GPU 功率接口"),
            "diskFree": reading(free, "bytes", now, "Windows GetDiskFreeSpaceExW：系统卷调用用户可用容量"),
            "diskRead": reading(disk_read, "bytes/s", now, "Windows PDH PhysicalDisk(_Total)", "等待磁盘计数基线或计数器不可读"),
            "diskWrite": reading(disk_write, "bytes/s", now, "Windows PDH PhysicalDisk(_Total)", "等待磁盘计数基线或计数器不可读"),
            "networkDown": reading(down, "bytes/s", now, network_source, network_reason),
            "networkUp": reading(up, "bytes/s", now, network_source, network_reason),
            "thermalState": reading(thermal, "", now, "Windows PDH Thermal Zone Information", "平台未报告可读的固件热节流状态"),
        }
        for key, current in sample_readings.items():
            if current["value"] is not None:
                self._last_readings[key] = current
            elif key in self._last_readings:
                last = self._last_readings[key]
                sample_readings[key] = dict(last, isStale=True, availabilityReason=current["availabilityReason"])
        return {
            "timestamp": now, "cpuPercent": usage, "cpuReason": cpu_reason if usage is None else None,
            "corePercents": cores, "logicalProcessorCount": logical_processors or None,
            "memoryUsed": memory.get("used"), "memoryTotal": memory.get("total"),
            "memoryCompressed": None, "memoryPressure": memory.get("pressure") or "未知",
            "memorySource": memory.get("source"), "swapUsed": memory.get("swap"),
            "networkDown": down, "networkUp": up, "diskRead": disk_read, "diskWrite": disk_write,
            "diskFree": free, "diskTotal": total, "gpuPercent": gpu, "cpuTemperature": None,
            "cpuPower": None, "gpuPower": None, "fanRPM": None,
            "batteryPercent": battery["percent"]["value"], "batteryCharging": battery["charging"]["value"],
            "batteryHealth": battery["healthPercent"]["value"], "batteryCycles": battery["cycles"]["value"],
            "batterySnapshot": battery, "uptime": api.GetTickCount64() / 1000,
            "processCount": len(inventory) if inventory is not None else None,
            "processes": groups, "processSource": "Windows GetProcessTimes（全机 0–100%）与 K32GetProcessMemoryInfo（工作集含共享页）",
            "thermalState": thermal or "未知", "thermalZones": zones, "readings": sample_readings,
            "fanDescriptors": [], "fanReason": "Windows 未提供经验证的通用实时风扇转速接口",
            "sensorReason": sensor_reason,
        }

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
