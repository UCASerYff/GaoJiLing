"""Read-only Windows system and process telemetry."""

from __future__ import annotations

import ctypes as ct
import math
import ntpath
import re
from collections import defaultdict
from ctypes import wintypes as wt
from functools import lru_cache


INVALID_HANDLE = ct.c_void_p(-1).value
DWORD_PTR = ct.c_size_t
ULONG64 = ct.c_uint64


def bind(library, name, result, *arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function


class Guid(ct.Structure):
    _fields_ = [("data1", wt.DWORD), ("data2", wt.WORD), ("data3", wt.WORD), ("data4", ct.c_ubyte * 8)]


class ProcessEntry(ct.Structure):
    _fields_ = [
        ("size", wt.DWORD), ("usage", wt.DWORD), ("pid", wt.DWORD), ("defaultHeap", DWORD_PTR),
        ("module", wt.DWORD), ("threads", wt.DWORD), ("parent", wt.DWORD), ("basePriority", wt.LONG),
        ("flags", wt.DWORD), ("name", wt.WCHAR * 260),
    ]


class ProcessMemory(ct.Structure):
    _fields_ = [
        ("size", wt.DWORD), ("pageFaults", wt.DWORD), ("peakWorkingSet", DWORD_PTR),
        ("workingSet", DWORD_PTR), ("quotaPeakPagedPool", DWORD_PTR), ("quotaPagedPool", DWORD_PTR),
        ("quotaPeakNonPagedPool", DWORD_PTR), ("quotaNonPagedPool", DWORD_PTR),
        ("pagefileUsage", DWORD_PTR), ("peakPagefileUsage", DWORD_PTR),
    ]


class TokenUser(ct.Structure):
    _fields_ = [("sid", ct.c_void_p), ("attributes", wt.DWORD)]


class SystemPowerStatus(ct.Structure):
    _fields_ = [
        ("external", ct.c_ubyte), ("batteryFlags", ct.c_ubyte), ("percent", ct.c_ubyte),
        ("systemStatus", ct.c_ubyte), ("secondsToEmpty", wt.DWORD), ("totalSeconds", wt.DWORD),
    ]


@lru_cache(maxsize=1)
def kernel():
    dll = ct.WinDLL("kernel32", use_last_error=True)
    time_pointer = ct.POINTER(wt.FILETIME)
    bind(dll, "CloseHandle", wt.BOOL, wt.HANDLE)
    bind(dll, "CreateToolhelp32Snapshot", wt.HANDLE, wt.DWORD, wt.DWORD)
    bind(dll, "Process32FirstW", wt.BOOL, wt.HANDLE, ct.POINTER(ProcessEntry))
    bind(dll, "Process32NextW", wt.BOOL, wt.HANDLE, ct.POINTER(ProcessEntry))
    bind(dll, "OpenProcess", wt.HANDLE, wt.DWORD, wt.BOOL, wt.DWORD)
    bind(dll, "GetCurrentProcess", wt.HANDLE)
    bind(dll, "QueryFullProcessImageNameW", wt.BOOL, wt.HANDLE, wt.DWORD, wt.LPWSTR, ct.POINTER(wt.DWORD))
    bind(dll, "GetProcessTimes", wt.BOOL, wt.HANDLE, time_pointer, time_pointer, time_pointer, time_pointer)
    bind(dll, "K32GetProcessMemoryInfo", wt.BOOL, wt.HANDLE, ct.POINTER(ProcessMemory), wt.DWORD)
    bind(dll, "GetPackageFamilyName", wt.LONG, wt.HANDLE, ct.POINTER(wt.UINT), wt.LPWSTR)
    bind(dll, "LocalFree", wt.HLOCAL, wt.HLOCAL)
    bind(dll, "GetSystemTimes", wt.BOOL, time_pointer, time_pointer, time_pointer)
    bind(dll, "GetActiveProcessorCount", wt.DWORD, wt.WORD)
    bind(dll, "GetTickCount64", ULONG64)
    bind(dll, "GetWindowsDirectoryW", wt.UINT, wt.LPWSTR, wt.UINT)
    bind(dll, "GetDiskFreeSpaceExW", wt.BOOL, wt.LPCWSTR, ct.POINTER(ULONG64), ct.POINTER(ULONG64), ct.POINTER(ULONG64))
    bind(dll, "GetSystemPowerStatus", wt.BOOL, ct.POINTER(SystemPowerStatus))
    return dll


@lru_cache(maxsize=1)
def _tokens():
    dll = ct.WinDLL("advapi32", use_last_error=True)
    bind(dll, "OpenProcessToken", wt.BOOL, wt.HANDLE, wt.DWORD, ct.POINTER(wt.HANDLE))
    bind(dll, "GetTokenInformation", wt.BOOL, wt.HANDLE, wt.DWORD, ct.c_void_p, wt.DWORD, ct.POINTER(wt.DWORD))
    bind(dll, "ConvertSidToStringSidW", wt.BOOL, ct.c_void_p, ct.POINTER(wt.LPWSTR))
    return dll


def _owner_sid(handle):
    token = wt.HANDLE()
    api = _tokens()
    if not api.OpenProcessToken(handle, 0x0008, ct.byref(token)):  # TOKEN_QUERY
        return None
    try:
        size = wt.DWORD()
        api.GetTokenInformation(token, 1, None, 0, ct.byref(size))  # TokenUser
        if not ct.sizeof(TokenUser) <= size.value <= 1024:
            return None
        buffer = ct.create_string_buffer(size.value)
        if not api.GetTokenInformation(token, 1, buffer, size, ct.byref(size)):
            return None
        sid = wt.LPWSTR()
        if not api.ConvertSidToStringSidW(TokenUser.from_buffer(buffer).sid, ct.byref(sid)):
            return None
        try:
            return sid.value
        finally:
            kernel().LocalFree(ct.cast(sid, wt.HLOCAL))
    finally:
        kernel().CloseHandle(token)


@lru_cache(maxsize=1)
def current_owner_sid():
    return _owner_sid(kernel().GetCurrentProcess())


def windows_process_entries():
    """Return all Tool Help snapshot entries or None if enumeration failed."""
    api = kernel()
    handle = api.CreateToolhelp32Snapshot(0x00000002, 0)  # TH32CS_SNAPPROCESS
    if handle == INVALID_HANDLE:
        return None
    entry = ProcessEntry()
    entry.size = ct.sizeof(entry)
    result = []
    try:
        ok = api.Process32FirstW(handle, ct.byref(entry))
        while ok:
            result.append((entry.pid, entry.name))
            ok = api.Process32NextW(handle, ct.byref(entry))
        return result if ct.get_last_error() == 18 else None  # ERROR_NO_MORE_FILES
    finally:
        api.CloseHandle(handle)


def _ticks(value):
    return (value.dwHighDateTime << 32) | value.dwLowDateTime


def process_inventory(entries=None):
    """Inspect processes with query-only access. Missing fields remain None."""
    entries = windows_process_entries() if entries is None else entries
    if entries is None:
        return None
    api = kernel()
    image = ct.create_unicode_buffer(32768)
    package = ct.create_unicode_buffer(128)
    result = []
    for pid, name in entries:
        if pid == 0:  # Idle is represented in GetSystemTimes rather than as app activity.
            continue
        item = {
            "pid": pid, "name": name or str(pid), "path": None, "startTicks": None, "ownerSID": None,
            "cpuTicks": None, "memoryBytes": None, "packageFamily": None,
        }
        result.append(item)
        handle = api.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            continue
        try:
            size = wt.DWORD(len(image))
            if api.QueryFullProcessImageNameW(handle, 0, image, ct.byref(size)):
                item["path"] = image.value
                item["name"] = ntpath.basename(image.value)
            start, end, system, user = (wt.FILETIME() for _ in range(4))
            if api.GetProcessTimes(handle, ct.byref(start), ct.byref(end), ct.byref(system), ct.byref(user)):
                item["startTicks"] = _ticks(start)
                item["cpuTicks"] = _ticks(system) + _ticks(user)
                item["ownerSID"] = _owner_sid(handle)
            memory = ProcessMemory()
            memory.size = ct.sizeof(memory)
            if api.K32GetProcessMemoryInfo(handle, ct.byref(memory), memory.size):
                item["memoryBytes"] = memory.workingSet
            package_size = wt.UINT(len(package))
            if api.GetPackageFamilyName(handle, ct.byref(package_size), package) == 0:
                item["packageFamily"] = package.value
        finally:
            api.CloseHandle(handle)
    return result


def cpu_times():
    api = kernel()
    idle, system, user = (wt.FILETIME() for _ in range(3))
    if api.GetSystemTimes(ct.byref(idle), ct.byref(system), ct.byref(user)):
        return _ticks(system) + _ticks(user), _ticks(idle)
    return None


class ProcessorTime(ct.Structure):
    _fields_ = [
        ("idle", ct.c_int64), ("system", ct.c_int64), ("user", ct.c_int64),
        ("reserved1", ct.c_int64 * 2), ("reserved2", wt.DWORD),
    ]


@lru_cache(maxsize=1)
def _logical_cpu_query():
    try:
        return bind(ct.WinDLL("ntdll"), "NtQuerySystemInformation", wt.LONG, wt.DWORD, ct.c_void_p,
                    wt.DWORD, ct.POINTER(wt.DWORD))
    except (AttributeError, OSError):
        return None


def logical_cpu_times(logical_processors):
    # Use the documented processor performance class only for per-CPU data
    # when the optional PDH provider is absent. The aggregate is GetSystemTimes.
    if not 0 < logical_processors <= 64 or kernel().GetActiveProcessorCount(0) != logical_processors:
        return None
    query = _logical_cpu_query()
    if query is None:
        return None
    details = (ProcessorTime * logical_processors)()
    length = wt.DWORD()
    if query(8, details, ct.sizeof(details), ct.byref(length)) != 0 or length.value != ct.sizeof(details):
        return None
    return [(item.system + item.user, item.idle) for item in details]


def boot_disk():
    api = kernel()
    windows = ct.create_unicode_buffer(32768)
    if not 0 < api.GetWindowsDirectoryW(windows, len(windows)) < len(windows):
        return None, None
    drive = ntpath.splitdrive(windows.value)[0]
    if not drive or drive.startswith("\\\\"):
        return None, None
    free, total = ULONG64(), ULONG64()
    if not api.GetDiskFreeSpaceExW(drive + "\\", ct.byref(free), ct.byref(total), None):
        return None, None
    return free.value, total.value


class InterfaceRow(ct.Structure):
    _fields_ = [
        ("luid", ULONG64), ("index", wt.DWORD), ("guid", Guid), ("alias", wt.WCHAR * 257),
        ("description", wt.WCHAR * 257), ("physicalLength", wt.DWORD), ("physical", ct.c_ubyte * 32),
        ("permanentPhysical", ct.c_ubyte * 32), ("mtu", wt.DWORD), ("type", wt.DWORD),
        ("tunnel", wt.DWORD), ("media", wt.DWORD), ("physicalMedia", wt.DWORD),
        ("access", wt.DWORD), ("direction", wt.DWORD), ("flags", ct.c_ubyte),
        ("operStatus", wt.DWORD), ("adminStatus", wt.DWORD), ("mediaConnectState", wt.DWORD),
        ("network", Guid), ("connection", wt.DWORD), ("transmitSpeed", ULONG64), ("receiveSpeed", ULONG64),
        ("inOctets", ULONG64), ("inUcastPackets", ULONG64), ("inNUcastPackets", ULONG64),
        ("inDiscards", ULONG64), ("inErrors", ULONG64), ("inUnknown", ULONG64),
        ("inUcastOctets", ULONG64), ("inMulticastOctets", ULONG64), ("inBroadcastOctets", ULONG64),
        ("outOctets", ULONG64), ("outUcastPackets", ULONG64), ("outNUcastPackets", ULONG64),
        ("outDiscards", ULONG64), ("outErrors", ULONG64), ("outUcastOctets", ULONG64),
        ("outMulticastOctets", ULONG64), ("outBroadcastOctets", ULONG64), ("outQueue", ULONG64),
    ]


class InterfaceTable(ct.Structure):
    _fields_ = [("count", wt.DWORD), ("first", InterfaceRow)]


@lru_cache(maxsize=1)
def _ip_helper():
    dll = ct.WinDLL("iphlpapi")
    bind(dll, "GetIfTable2", wt.DWORD, ct.POINTER(ct.POINTER(InterfaceTable)))
    bind(dll, "FreeMibTable", None, ct.c_void_p)
    return dll


def network_counters():
    api = _ip_helper()
    table = ct.POINTER(InterfaceTable)()
    if api.GetIfTable2(ct.byref(table)) != 0 or not table:
        return None
    try:
        if table.contents.count > 4096:
            return None
        address = ct.addressof(table.contents) + InterfaceTable.first.offset
        rows = (InterfaceRow * table.contents.count).from_address(address)
        # Count at the hardware boundary so bridge, VPN and filter layers don't
        # duplicate traffic already counted by the underlying adapter.
        return {
            row.luid: (row.inOctets, row.outOctets)
            for row in rows
            if row.flags & 1 and not row.flags & 2 and row.type not in (24, 131) and row.operStatus == 1
        }
    finally:
        api.FreeMibTable(table)


class FormatValue(ct.Union):
    _fields_ = [("longValue", wt.LONG), ("doubleValue", ct.c_double), ("largeValue", ct.c_int64)]


class PdhValue(ct.Structure):
    _fields_ = [("status", wt.DWORD), ("data", FormatValue)]

    def read(self):
        value = self.data.doubleValue
        return value if self.status in {0, 1} and math.isfinite(value) and value >= 0 else None


class PdhItem(ct.Structure):
    _fields_ = [("name", wt.LPWSTR), ("value", PdhValue)]


class PerformanceCounters:
    _PATHS = {
        "cpu": r"\Processor Information(_Total)\% Processor Time",
        "cores": r"\Processor Information(*)\% Processor Time",
        "diskRead": r"\PhysicalDisk(_Total)\Disk Read Bytes/sec",
        "diskWrite": r"\PhysicalDisk(_Total)\Disk Write Bytes/sec",
        "gpu": r"\GPU Engine(*)\Utilization Percentage",
        "zones": r"\Thermal Zone Information(*)\Temperature",
        "throttle": r"\Thermal Zone Information(*)\Throttle Reasons",
    }

    def __init__(self):
        self.api = ct.WinDLL("pdh")
        handle, uint, ptr_size = wt.HANDLE, wt.DWORD, ct.POINTER(wt.DWORD)
        bind(self.api, "PdhOpenQueryW", uint, wt.LPCWSTR, DWORD_PTR, ct.POINTER(handle))
        bind(self.api, "PdhAddEnglishCounterW", uint, handle, wt.LPCWSTR, DWORD_PTR, ct.POINTER(handle))
        bind(self.api, "PdhAddCounterW", uint, handle, wt.LPCWSTR, DWORD_PTR, ct.POINTER(handle))
        bind(self.api, "PdhCollectQueryData", uint, handle)
        bind(self.api, "PdhGetFormattedCounterValue", uint, handle, uint, ptr_size, ct.POINTER(PdhValue))
        bind(self.api, "PdhGetFormattedCounterArrayW", uint, handle, uint, ptr_size, ptr_size, ct.c_void_p)
        bind(self.api, "PdhCloseQuery", uint, handle)
        self.query = handle()
        self.handles = {}
        self.collects = 0

    def close(self):
        if self.query:
            self.api.PdhCloseQuery(self.query)
        self.query = wt.HANDLE()
        self.handles.clear()
        self.collects = 0

    def collect(self):
        if not self.query and self.api.PdhOpenQueryW(None, 0, ct.byref(self.query)) != 0:
            return False
        if self.collects % 30 == 0:
            for key, path in self._PATHS.items():
                if key not in self.handles:
                    handle = wt.HANDLE()
                    status = self.api.PdhAddEnglishCounterW(self.query, path, 0, ct.byref(handle))
                    if status == 0xC0000BC8:  # PDH_CANNOT_READ_NAME_STRINGS
                        status = self.api.PdhAddCounterW(self.query, path, 0, ct.byref(handle))
                    if status == 0:
                        self.handles[key] = handle
        self.collects += 1
        return self.api.PdhCollectQueryData(self.query) == 0

    def value(self, key, uncapped=False):
        counter = self.handles.get(key)
        if counter is None:
            return None
        value = PdhValue()
        flags = 0x00000200 | (0x00008000 if uncapped else 0)  # PDH_FMT_DOUBLE | PDH_FMT_NOCAP100
        if self.api.PdhGetFormattedCounterValue(counter, flags, None, ct.byref(value)) != 0:
            return None
        return value.read()

    def array(self, key, uncapped=False):
        counter = self.handles.get(key)
        if counter is None:
            return {}
        needed, count = wt.DWORD(), wt.DWORD()
        flags = 0x00000200 | (0x00008000 if uncapped else 0)
        reader = self.api.PdhGetFormattedCounterArrayW
        status = reader(counter, flags, ct.byref(needed), ct.byref(count), None)
        if status != 0x800007D2 or not 0 < needed.value <= 4 * 1024 * 1024:
            return {}
        buffer = ct.create_string_buffer(needed.value)
        if reader(counter, flags, ct.byref(needed), ct.byref(count), buffer) != 0:
            return {}
        if count.value > ct.sizeof(buffer) // ct.sizeof(PdhItem):
            return {}
        return {
            item.name: value for item in (PdhItem * count.value).from_buffer(buffer)
            if item.name and (value := item.value.read()) is not None
        }


_CORE = re.compile(r"(\d+),(\d+)")
_GPU_ENGINE = re.compile(r"pid_\d+_(luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+_eng_\d+)_engtype_.+", re.I)


def core_percentages(values):
    cores = []
    for name, value in values.items():
        match = _CORE.fullmatch(name)
        if match:
            cores.append(((int(match[1]), int(match[2])), min(100.0, value)))
    cores.sort()
    return [value for _, value in cores]


def busiest_gpu_engine(values):
    engines = defaultdict(float)
    for name, value in values.items():
        match = _GPU_ENGINE.fullmatch(name)
        if match:
            engines[match[1].lower()] += value
    return min(100.0, max(engines.values())) if engines else None
