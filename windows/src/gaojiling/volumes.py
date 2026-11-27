"""本机卷的元数据。外接、可移除、网络和未知卷不读取容量，也不把缺项写成 0。"""

from __future__ import annotations

import ctypes
import json
import re
import subprocess
import sys
import time
import uuid
from ctypes import wintypes
from pathlib import Path


def included(classification: dict) -> bool:
    return (
        classification.get("isLocal") is True
        and classification.get("isInternal") is True
        and classification.get("isRemovable") is False
        and classification.get("isEjectable") is False
        and classification.get("isNetwork") is not True
    )


def collect(provider, clock=None, time_budget: float = 8, maximum: int = 128, cancelled=lambda: False) -> dict:
    now = clock or time.monotonic
    started = now()
    captured = time.time()
    notes = ["只读取已挂载卷的公开元数据，不扫描目录，不打开原始设备。"]
    volumes = []
    skipped = {"externalOrRemovable": 0, "network": 0, "unknown": 0}
    complete = True
    try:
        listed = provider.list_volumes()
    except Exception as error:
        return {
            "complete": False, "cancelled": False, "volumes": [], "skipped": skipped,
            "notes": notes + [f"系统未返回已挂载卷列表，不能当作没有本机卷：{error}"],
            "source": getattr(provider, "source", "未知"), "capturedAt": captured,
        }
    for volume in listed:
        if cancelled() or now() - started >= time_budget or len(volumes) + sum(skipped.values()) >= maximum:
            complete = False
            notes.append("卷枚举达到时间或数量预算，结果未完成。")
            break
        try:
            classification = provider.classify(volume)
        except Exception:
            skipped["unknown"] += 1
            notes.append(f"{volume} 的归属无法确认，未读取容量。")
            continue
        if classification.get("isNetwork") is True:
            skipped["network"] += 1
            continue
        if not included(classification):
            if classification.get("isRemovable") is True or classification.get("isEjectable") is True or classification.get("isInternal") is False:
                skipped["externalOrRemovable"] += 1
            else:
                skipped["unknown"] += 1
                if classification.get("reason"):
                    notes.append(f"{volume}：{classification['reason']}")
            continue
        try:
            if provider.classify(volume) != classification:
                raise RuntimeError("分类变化")
            details = provider.details(volume)
            if provider.classify(volume) != classification:
                raise RuntimeError("读取详情后分类变化")
        except Exception as error:
            skipped["unknown"] += 1
            notes.append(f"{volume} 的详情不能确认，未填入容量：{error}")
            continue
        unavailable = [key for key in ("name", "format", "readOnly", "totalBytes", "availableBytes") if details.get(key) is None]
        volumes.append({
            "id": str(volume),
            "name": details.get("name"),
            "path": str(volume),
            "volumeID": details.get("volumeID"),
            "format": details.get("format"),
            "readOnly": details.get("readOnly"),
            "totalBytes": details.get("totalBytes"),
            "availableBytes": details.get("availableBytes"),
            "unavailableFields": unavailable,
            "capabilities": details.get("capabilities") or [],
            "identitySource": classification.get("source"),
        })
    if cancelled() or getattr(provider, "inventory_limited", False):
        complete = False
    notes.extend(getattr(provider, "notes", ()))
    return {"complete": complete, "cancelled": bool(cancelled()), "volumes": volumes, "skipped": skipped,
            "notes": notes, "source": getattr(provider, "source", "注入的卷信息"), "capturedAt": captured}


_WMI_DISK_MAP = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$disks = @{}
Get-WmiObject Win32_DiskDrive | ForEach-Object {
    if ($null -ne $_.Index) { $disks[[int]$_.Index] = $_ }
}
$partitions = @{}
Get-WmiObject Win32_DiskPartition | ForEach-Object {
    if ($null -ne $_.DiskIndex) { $partitions[$_.__RELPATH] = [int]$_.DiskIndex }
}
$result = @(Get-WmiObject Win32_LogicalDiskToPartition | ForEach-Object {
    $partition = ([System.Management.ManagementPath]::new($_.Antecedent)).RelativePath
    $letter = ([System.Management.ManagementPath]::new($_.Dependent)).RelativePath
    if ($letter -match '^Win32_LogicalDisk\.DeviceID="([A-Za-z]:)"$' -and $partitions.ContainsKey($partition)) {
        $drive = $Matches[1]
        $disk = $disks[$partitions[$partition]]
        if ($null -ne $disk) {
            [PSCustomObject]@{ Drive = $drive; Device = $disk.PNPDeviceID;
                              Interface = $disk.InterfaceType; Capabilities = $disk.Capabilities }
        }
    }
})
ConvertTo-Json -InputObject $result -Compress -Depth 3
"""


class _PropertyKey(ctypes.Structure):
    _fields_ = [("format", ctypes.c_ubyte * 16), ("property", wintypes.DWORD)]


def _device_properties(device: str):
    cfg = ctypes.WinDLL("cfgmgr32", use_last_error=True)
    node = wintypes.DWORD()
    if not device or cfg.CM_Locate_DevNodeW(ctypes.byref(node), ctypes.c_wchar_p(device), 0) != 0:
        return None, []
    guid = uuid.UUID("a45c254e-df1c-4efd-8020-67d146a850e0").bytes_le
    lookup = cfg.CM_Get_DevNode_PropertyW
    lookup.argtypes = [wintypes.DWORD, ctypes.POINTER(_PropertyKey), ctypes.POINTER(wintypes.DWORD),
                       wintypes.LPVOID, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]

    def prop(pid):
        key = _PropertyKey((ctypes.c_ubyte * 16).from_buffer_copy(guid), pid)
        value = ctypes.create_string_buffer(4096)
        kind = wintypes.DWORD()
        size = wintypes.DWORD(ctypes.sizeof(value))
        code = lookup(node, ctypes.byref(key), ctypes.byref(kind), value, ctypes.byref(size), 0)
        return (kind.value, value.raw[:size.value]) if code == 0 else (None, b"")

    policy_kind, policy_raw = prop(33)  # DEVPKEY_Device_RemovalPolicy
    paths_kind, paths_raw = prop(37)  # DEVPKEY_Device_LocationPaths
    policy = int.from_bytes(policy_raw, "little") if policy_kind in (6, 7) and len(policy_raw) == 4 else None
    paths = paths_raw.decode("utf-16-le").rstrip("\0").split("\0") if paths_kind == 0x2012 else []
    return policy, paths


def _physical_classification(row: dict, policy, paths) -> tuple[str, str | None]:
    interface = str(row.get("Interface") or "").upper()
    capabilities = row.get("Capabilities")
    hardware_paths = [path.upper() for path in paths if path]
    external = ("USB", "1394", "THUNDERBOLT", "ISCSI", "PCCARD", "SD(", "SDHOST")
    if (policy in (2, 3) or (capabilities and 7 in capabilities) or interface in external
            or any(any(marker in path for marker in external) for path in hardware_paths)):
        return "external", None
    if (policy == 1 and hardware_paths
            and any(path.startswith("PCIROOT(") for path in hardware_paths)
            and not any("VIRTUAL" in path or "VMBUS" in path for path in hardware_paths)):
        return "internal", None
    return "unknown", "设备需要可核实的 PCI 位置和不可热移除策略，容量未读取。"


class WindowsVolumeProvider:
    source = "Windows WMI / Plug and Play / GetDiskFreeSpaceEx"
    notes = ("以 WMI 分区映射、Plug and Play 设备位置和移除策略排除外接设备。"
             "固定盘类型本身不能确认是内置盘。仅列 Windows 提供盘符的卷。",)

    def __init__(self):
        self._disk_map = {}
        self._mounted = {}
        self._inventory_error = None

    @staticmethod
    def _kernel():
        if sys.platform != "win32":
            raise OSError("不是 Windows")
        return ctypes.WinDLL("kernel32", use_last_error=True)

    def _mount_id(self, volume: str) -> str | None:
        name = ctypes.create_unicode_buffer(256)
        return name.value.casefold() if self._kernel().GetVolumeNameForVolumeMountPointW(volume, name, len(name)) else None

    @property
    def inventory_limited(self):
        return bool(self._inventory_error)

    def _read_disk_map(self):
        directory = ctypes.create_unicode_buffer(32768)
        length = self._kernel().GetSystemDirectoryW(directory, len(directory))
        if not 0 < length < len(directory):
            raise OSError("Windows 系统目录无法读取")
        powershell = Path(directory.value) / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        process = subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-Command", _WMI_DISK_MAP],
                                 stdin=subprocess.DEVNULL, capture_output=True, encoding="utf-8", errors="replace",
                                 timeout=6, creationflags=subprocess.CREATE_NO_WINDOW)
        if process.returncode != 0:
            raise OSError("当前权限无法读取 Windows 系统的卷与物理设备映射")
        rows = json.loads(process.stdout)
        for row in rows:
            letter = row.get("Drive")
            if isinstance(letter, str) and re.fullmatch("[A-Za-z]:", letter):
                self._disk_map.setdefault(letter.upper() + "\\", []).append(row)

    def list_volumes(self):
        kernel = self._kernel()
        drives = ctypes.create_unicode_buffer(128)
        length = kernel.GetLogicalDriveStringsW(len(drives), drives)
        if not 0 < length < len(drives):
            raise OSError("Windows 未返回已挂载盘符")
        listed = [item for item in drives[:length].split("\x00") if item]
        self._mounted = {root: self._mount_id(root) for root in listed if kernel.GetDriveTypeW(root) == 3}
        self._disk_map = {}
        self._inventory_error = None
        if self._mounted:
            try:
                self._read_disk_map()
            except subprocess.TimeoutExpired:
                self._inventory_error = "Windows 卷与物理设备映射查询超时。"
            except (OSError, ValueError):
                self._inventory_error = "当前权限或 Windows 服务状态下无法确认物理设备映射，容量未读取。"
        return listed

    def classify(self, volume: str) -> dict:
        kind = int(self._kernel().GetDriveTypeW(volume))
        if kind == 4:
            return {"isLocal": False, "isInternal": False, "isRemovable": False, "isEjectable": False, "isNetwork": True}
        if kind in (2, 5):
            return {"isLocal": True, "isInternal": False, "isRemovable": True, "isEjectable": True, "isNetwork": False}
        unknown = {"isLocal": kind == 3, "isInternal": None, "isRemovable": None,
                   "isEjectable": None, "isNetwork": False}
        if kind != 3:
            return unknown
        mount = self._mount_id(volume)
        rows = self._disk_map.get(volume.upper(), [])
        if not mount or self._mounted.get(volume) != mount or len(rows) != 1:
            return unknown | {"reason": self._inventory_error or "卷映射变化、多磁盘或无法核实，容量未读取。"}
        row = rows[0]
        disk_kind, reason = _physical_classification(row, *_device_properties(str(row.get("Device") or "")))
        if disk_kind == "unknown":
            return unknown | {"reason": reason}
        internal = disk_kind == "internal"
        return {"isLocal": True, "isInternal": internal, "isRemovable": not internal,
                "isEjectable": not internal, "isNetwork": False, "mountID": mount, "source": "WMI / Plug and Play"}

    def details(self, volume: str) -> dict:
        mount = self._mounted.get(volume)
        if not mount or not included(self.classify(volume)):
            raise OSError("卷归属无法复核")
        kernel = self._kernel()
        free = ctypes.c_ulonglong()
        total = ctypes.c_ulonglong()
        total_free = ctypes.c_ulonglong()
        ok = kernel.GetDiskFreeSpaceExW(mount, ctypes.byref(free), ctypes.byref(total), ctypes.byref(total_free))
        name = ctypes.create_unicode_buffer(256)
        fs = ctypes.create_unicode_buffer(256)
        flags = wintypes.DWORD()
        named = kernel.GetVolumeInformationW(mount, name, len(name), None, None, ctypes.byref(flags), fs, len(fs))
        capabilities = [(0x40000, "命名数据流"), (0x400000, "硬链接"), (0x40, "稀疏文件"), (0x80000, "只读")]
        return {
            "name": (name.value or None) if named else None,
            "volumeID": mount,
            "format": (fs.value or None) if named else None,
            "readOnly": bool(flags.value & 0x80000) if named else None,
            "totalBytes": int(total.value) if ok else None,
            "availableBytes": int(free.value) if ok else None,
            "capabilities": [label for mask, label in capabilities if named and flags.value & mask],
        }
