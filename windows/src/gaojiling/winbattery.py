"""Read system battery status and optional fields from the battery class."""

from __future__ import annotations

import ctypes as ct
from ctypes import wintypes as wt
from functools import lru_cache

from gaojiling.winmetrics import Guid, INVALID_HANDLE, SystemPowerStatus, bind, kernel


_BATTERY_INTERFACE = Guid(0x72631E54, 0x78A4, 0x11D0, (0xBC, 0xF7, 0, 0xAA, 0, 0xB7, 0xB3, 0x2A))
_QUERY_TAG = 0x00294040
_QUERY_INFORMATION = 0x00294044
_QUERY_STATUS = 0x0029404C
_UNKNOWN = 0xFFFFFFFF
_POWER_SOURCE = "Windows GetSystemPowerStatus"
_DEVICE_SOURCE = "Windows 电池类 IOCTL（由固件提供）"


class InterfaceData(ct.Structure):
    _fields_ = [("size", wt.DWORD), ("guid", Guid), ("flags", wt.DWORD), ("reserved", ct.c_size_t)]


class InterfaceDetail(ct.Structure):
    _fields_ = [("size", wt.DWORD), ("path", wt.WCHAR)]


class BatteryInformation(ct.Structure):
    _fields_ = [
        ("capabilities", wt.DWORD), ("technology", ct.c_ubyte), ("reserved", ct.c_ubyte * 3),
        ("chemistry", ct.c_ubyte * 4), ("design", wt.DWORD), ("full", wt.DWORD),
        ("alert1", wt.DWORD), ("alert2", wt.DWORD), ("bias", wt.DWORD), ("cycles", wt.DWORD),
    ]


class BatteryQuery(ct.Structure):
    _fields_ = [("tag", wt.DWORD), ("level", ct.c_int), ("atRate", wt.LONG)]


class BatteryWaitStatus(ct.Structure):
    _fields_ = [
        ("tag", wt.DWORD), ("timeout", wt.DWORD), ("power", wt.DWORD),
        ("lowCapacity", wt.DWORD), ("highCapacity", wt.DWORD),
    ]


class BatteryStatus(ct.Structure):
    _fields_ = [("power", wt.DWORD), ("capacity", wt.DWORD), ("voltage", wt.DWORD), ("rate", wt.LONG)]


@lru_cache(maxsize=1)
def _setup_api():
    dll = ct.WinDLL("setupapi", use_last_error=True)
    guid, entry = ct.POINTER(Guid), ct.POINTER(InterfaceData)
    bind(dll, "SetupDiGetClassDevsW", wt.HANDLE, guid, wt.LPCWSTR, wt.HWND, wt.DWORD)
    bind(dll, "SetupDiEnumDeviceInterfaces", wt.BOOL, wt.HANDLE, ct.c_void_p, guid, wt.DWORD, entry)
    bind(dll, "SetupDiGetDeviceInterfaceDetailW", wt.BOOL, wt.HANDLE, entry, ct.c_void_p,
         wt.DWORD, ct.POINTER(wt.DWORD), ct.c_void_p)
    bind(dll, "SetupDiDestroyDeviceInfoList", wt.BOOL, wt.HANDLE)
    return dll


def _battery_device(handle, ioctl):
    def query(code, arguments, output):
        length = wt.DWORD()
        if ioctl(handle, code, ct.byref(arguments), ct.sizeof(arguments), ct.byref(output),
                 ct.sizeof(output), ct.byref(length), None) and length.value == ct.sizeof(output):
            return output
        return None

    tag = query(_QUERY_TAG, wt.DWORD(0), wt.DWORD())
    if not tag or not tag.value:
        return None
    info = query(_QUERY_INFORMATION, BatteryQuery(tag.value, 0, 0), BatteryInformation())
    if info is None or not info.capabilities & 0x80000000 or info.capabilities & 0x20000000:
        return None  # Exclude short-term UPS and other non-system batteries.
    temperature = query(_QUERY_INFORMATION, BatteryQuery(tag.value, 2, 0), wt.DWORD())
    temperature_c = None
    if temperature is not None and 1730 <= temperature.value <= 4732:
        temperature_c = temperature.value / 10 - 273.15
    status = query(_QUERY_STATUS, BatteryWaitStatus(tag.value, 0, 0, 0, 0), BatteryStatus())
    minutes = None
    if (status is not None and status.power & 0x4 and 0 < status.rate <= 0x7FFFFFFF
            and 0 < info.full < _UNKNOWN and 0 <= status.capacity <= info.full):
        minutes = (info.full - status.capacity) / status.rate * 60
    return {
        "design": info.design if 0 < info.design < _UNKNOWN else None,
        "full": info.full if 0 < info.full < _UNKNOWN else None,
        "relative": bool(info.capabilities & 0x40000000),
        "cycles": info.cycles if 0 < info.cycles < _UNKNOWN else None,
        "temperature": temperature_c,
        "minutes": minutes,
    }


def _battery_devices():
    setup = _setup_api()
    system = kernel()
    create_file = bind(system, "CreateFileW", wt.HANDLE, wt.LPCWSTR, wt.DWORD, wt.DWORD,
                       ct.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE)
    ioctl = bind(system, "DeviceIoControl", wt.BOOL, wt.HANDLE, wt.DWORD, ct.c_void_p, wt.DWORD,
                 ct.c_void_p, wt.DWORD, ct.POINTER(wt.DWORD), ct.c_void_p)
    guid = ct.byref(_BATTERY_INTERFACE)
    devices = setup.SetupDiGetClassDevsW(guid, None, None, 0x12)  # DIGCF_DEVICEINTERFACE | DIGCF_PRESENT
    if devices == INVALID_HANDLE:
        return [], "无法枚举电池设备"
    result = []
    failed = False
    try:
        for index in range(32):
            entry = InterfaceData(ct.sizeof(InterfaceData))
            if not setup.SetupDiEnumDeviceInterfaces(devices, None, guid, index, ct.byref(entry)):
                failed |= ct.get_last_error() != 259  # ERROR_NO_MORE_ITEMS
                break
            required = wt.DWORD()
            get_detail = setup.SetupDiGetDeviceInterfaceDetailW
            get_detail(devices, ct.byref(entry), None, 0, ct.byref(required), None)
            if not ct.sizeof(InterfaceDetail) <= required.value <= 32768:
                failed = True
                continue
            path_buffer = ct.create_string_buffer(required.value)
            InterfaceDetail.from_buffer(path_buffer).size = 8 if ct.sizeof(ct.c_void_p) == 8 else 6
            if not get_detail(devices, ct.byref(entry), path_buffer, required.value, None, None):
                failed = True
                continue
            path = ct.wstring_at(ct.addressof(path_buffer) + InterfaceDetail.path.offset)
            # The query IOCTLs require FILE_READ_ACCESS. Never open the
            # device with write access or send battery mutation requests.
            handle = create_file(path, 0x80000000, 3, None, 3, 0, None)
            if handle == INVALID_HANDLE:
                failed = True
                continue
            try:
                battery = _battery_device(handle, ioctl)
                if battery:
                    result.append(battery)
            finally:
                system.CloseHandle(handle)
        else:
            failed = True
    finally:
        setup.SetupDiDestroyDeviceInfoList(devices)
    return result, ("电池设备权限不足或详细信息读取不完整" if failed else "固件未提供此字段")


def battery_snapshot(now, reading):
    status = SystemPowerStatus()
    power_ok = bool(kernel().GetSystemPowerStatus(ct.byref(status)))
    present = charging = percent = external = to_empty = None
    if power_ok:
        external = {0: False, 1: True}.get(status.external)
        if status.batteryFlags != 255:
            present = not bool(status.batteryFlags & 0x80)
            charging = bool(status.batteryFlags & 8) if present else None
        if present is not False and 0 <= status.percent <= 100:
            percent = status.percent
            present = True
        if present and external is False and status.secondsToEmpty != _UNKNOWN:
            to_empty = status.secondsToEmpty / 60

    devices, device_reason = _battery_devices() if present is not False else ([], "系统报告无电池")
    if devices:
        present = True
    health = cycles = temperature = to_full = None
    if len(devices) == 1 and device_reason == "固件未提供此字段":
        device = devices[0]
        if device["design"] is not None and device["full"] is not None:
            health = min(100.0, device["full"] / device["design"] * 100)
        cycles = device["cycles"]
        temperature = device["temperature"]
        to_full = device["minutes"]
    elif len(devices) > 1 and device_reason == "固件未提供此字段":
        if all(device["design"] and device["full"] and not device["relative"] for device in devices):
            health = min(100.0, sum(d["full"] for d in devices) / sum(d["design"] for d in devices) * 100)
        temperatures = [d["temperature"] for d in devices if d["temperature"] is not None]
        temperature = max(temperatures) if len(temperatures) == len(devices) else None
        device_reason = "有多块电池；缺项无可靠合并值"
    power_reason = "Windows 未返回此电池字段" if power_ok else "Windows 电源状态读取失败"
    return {
        "timestamp": now,
        "present": reading(present, "boolean", now, _POWER_SOURCE, power_reason),
        "percent": reading(percent, "%", now, _POWER_SOURCE, power_reason),
        "externalPower": reading(external, "boolean", now, _POWER_SOURCE, power_reason),
        "charging": reading(charging, "boolean", now, _POWER_SOURCE, power_reason),
        "healthPercent": reading(health, "%", now, _DEVICE_SOURCE + "，满充容量 / 设计容量", device_reason),
        "healthCondition": reading(None, "", now, _DEVICE_SOURCE, "Windows 未提供通用电池健康等级"),
        "cycles": reading(cycles, "次", now, _DEVICE_SOURCE, device_reason),
        "temperature": reading(temperature, "°C", now, _DEVICE_SOURCE + "，多块时取最高值", device_reason),
        "minutesToEmpty": reading(to_empty, "分钟", now, _POWER_SOURCE, power_reason),
        "minutesToFull": reading(to_full, "分钟", now, _DEVICE_SOURCE + "，按当前充电速率估算", device_reason),
    }
