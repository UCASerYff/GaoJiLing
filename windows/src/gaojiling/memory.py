"""内存读数与本进程回收。

Windows 没有 malloc_zone_pressure_relief，也没有对应 /usr/sbin/purge 的固定工具。
读数失败时不执行回收，不把前后差值称作释放量，不为了制造压力去分配内存。
"""

from __future__ import annotations


def missing_report() -> dict:
    return {
        "executed": False,
        "succeeded": False,
        "releasedOwnBytes": None,
        "message": "无法读取当前内存状态，本次未执行回收。请稍后重试。",
    }


def own_report(before: dict | None, api_ok: bool, api_bytes: int | None) -> dict:
    if before is None:
        return missing_report()
    if not api_ok:
        return {
            "executed": True,
            "succeeded": False,
            "releasedOwnBytes": None,
            "before": before,
            "message": "本进程回收调用没有成功。没有改动其他应用，也没有把内存差值当作释放量。",
        }
    if api_bytes is None:
        message = "已请求收缩搞机灵自身的工作集。系统没有返回字节数；前后读数受其他活动影响，不能当作本次释放量。"
    elif api_bytes == 0:
        message = "检查完成，搞机灵当前没有可归还的闲置分配。"
    else:
        message = "已归还搞机灵自身的闲置内存，字节数来自本次调用的返回值，不包含其他应用。"
    return {"executed": True, "succeeded": True, "releasedOwnBytes": api_bytes, "before": before, "message": message}


def system_cache_report() -> dict:
    return {
        "executed": False,
        "succeeded": False,
        "releasedOwnBytes": None,
        "message": "Windows 版不调用系统缓存清理。没有与 macOS /usr/sbin/purge 对应、且可以固定参数执行的本机工具；不会申请管理员权限，也不会分配内存制造压力。",
    }


def snapshot() -> dict | None:
    import sys
    if sys.platform == "win32":
        return _windows_snapshot()
    if sys.platform.startswith("linux"):
        return _linux_snapshot()
    return None


def _linux_snapshot():
    try:
        info = {}
        for line in open("/proc/meminfo", encoding="utf-8"):
            key, _, rest = line.partition(":")
            info[key] = int(rest.strip().split()[0]) * 1024
        total = info.get("MemTotal") or 0
        available = info.get("MemAvailable")
        if total <= 0 or available is None:
            return None
        used = max(0, total - available)
        swap_total = info.get("SwapTotal") or 0
        swap_free = info.get("SwapFree") or 0
        pressure = "正常" if available / total > 0.2 else "偏高" if available / total > 0.1 else "严重"
        return {
            "used": used, "total": total, "free": info.get("MemFree"), "fileCache": info.get("Cached"),
            "compressed": None, "swap": max(0, swap_total - swap_free), "pressure": pressure,
            "source": "Linux /proc/meminfo。压力按可用内存比例估算，不是 macOS 内存压力。",
        }
    except (OSError, ValueError):
        return None


def _windows_snapshot():
    import ctypes
    from ctypes import wintypes

    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
            ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    status = MEMORYSTATUSEX()
    status.dwLength = ctypes.sizeof(status)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        return None
    total = int(status.ullTotalPhys)
    free = int(status.ullAvailPhys)
    if total <= 0:
        return None
    load = int(status.dwMemoryLoad)
    pressure = "正常" if load < 80 else "偏高" if load < 90 else "严重"
    return {
        "used": total - free, "total": total, "free": free, "fileCache": None, "compressed": None,
        "swap": None, "pressure": pressure,
        "source": "Windows GlobalMemoryStatusEx。压力按内存负载估算，不是 macOS 内存压力；文件缓存和压缩内存不可用。",
    }


def release_own() -> dict:
    before = snapshot()
    if before is None:
        return missing_report()
    import sys
    if sys.platform == "win32":
        import ctypes
        handle = ctypes.windll.kernel32.GetCurrentProcess()
        ok = bool(ctypes.windll.kernel32.SetProcessWorkingSetSize(handle, ctypes.c_size_t(-1).value, ctypes.c_size_t(-1).value))
        return own_report(before, ok, None)
    return own_report(before, False, None)
