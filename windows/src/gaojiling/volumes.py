"""本机卷的元数据。外接、可移除、网络和未知卷不读取容量，也不把缺项写成 0。"""

from __future__ import annotations

import time


def included(classification: dict) -> bool:
    return (
        classification.get("isLocal") is True
        and classification.get("isInternal") is True
        and classification.get("isRemovable") is False
        and classification.get("isEjectable") is False
        and classification.get("isNetwork") is not True
    )


def collect(provider, clock=None, time_budget: float = 3, maximum: int = 128, cancelled=lambda: False) -> dict:
    now = clock or time.monotonic
    started = now()
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
            "source": getattr(provider, "source", "未知"),
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
            continue
        try:
            if provider.classify(volume) != classification:
                raise RuntimeError("分类变化")
            details = provider.details(volume)
            if not included(provider.classify(volume)):
                raise RuntimeError("读取详情后分类变化")
        except Exception as error:
            skipped["unknown"] += 1
            notes.append(f"{volume} 的详情不能确认，未填入容量：{error}")
            continue
        unavailable = [key for key in ("name", "format", "readOnly", "totalBytes", "availableBytes") if details.get(key) is None]
        volumes.append({
            "id": str(volume),
            "name": details.get("name"),
            "format": details.get("format"),
            "readOnly": details.get("readOnly"),
            "totalBytes": details.get("totalBytes"),
            "availableBytes": details.get("availableBytes"),
            "unavailableFields": unavailable,
            "capabilities": details.get("capabilities") or [],
        })
    if cancelled():
        complete = False
    notes.append("Windows 的 GetDriveType 不能把“报告为固定盘的外接盘”和内置盘分开；可移除、网络、光驱和未知类型不会读取容量。")
    return {"complete": complete, "cancelled": bool(cancelled()), "volumes": volumes, "skipped": skipped,
            "notes": notes, "source": getattr(provider, "source", "注入的卷信息")}


class WindowsVolumeProvider:
    source = "Windows GetDriveType / GetDiskFreeSpaceEx"

    def list_volumes(self):
        import ctypes
        import sys
        if sys.platform != "win32":
            raise OSError("不是 Windows")
        buffer = ctypes.create_unicode_buffer(4096)
        length = ctypes.windll.kernel32.GetLogicalDriveStringsW(4096, buffer)
        if length <= 0:
            raise OSError("GetLogicalDriveStrings 失败")
        raw = buffer[:length]
        return [item for item in raw.split("\x00") if item]

    def classify(self, volume: str) -> dict:
        import ctypes
        import sys
        if sys.platform != "win32":
            raise OSError("不是 Windows")
        kind = int(ctypes.windll.kernel32.GetDriveTypeW(volume))
        # 2 可移除，3 固定，4 网络，5 光驱，6 内存盘，0/1 未知。
        if kind == 3:
            return {"isLocal": True, "isInternal": True, "isRemovable": False, "isEjectable": False, "isNetwork": False}
        if kind == 4:
            return {"isLocal": False, "isInternal": False, "isRemovable": False, "isEjectable": False, "isNetwork": True}
        if kind == 2:
            return {"isLocal": True, "isInternal": False, "isRemovable": True, "isEjectable": True, "isNetwork": False}
        return {"isLocal": None, "isInternal": None, "isRemovable": None, "isEjectable": None, "isNetwork": None}

    def details(self, volume: str) -> dict:
        import ctypes
        from ctypes import wintypes
        free = ctypes.c_ulonglong()
        total = ctypes.c_ulonglong()
        total_free = ctypes.c_ulonglong()
        ok = ctypes.windll.kernel32.GetDiskFreeSpaceExW(volume, ctypes.byref(free), ctypes.byref(total), ctypes.byref(total_free))
        name = ctypes.create_unicode_buffer(256)
        fs = ctypes.create_unicode_buffer(256)
        serial = wintypes.DWORD()
        flags = wintypes.DWORD()
        named = ctypes.windll.kernel32.GetVolumeInformationW(volume, name, 256, ctypes.byref(serial), None, ctypes.byref(flags), fs, 256)
        return {
            "name": name.value or None if named else None,
            "format": fs.value or None if named else None,
            "readOnly": None,
            "totalBytes": int(total.value) if ok else None,
            "availableBytes": int(free.value) if ok else None,
            "capabilities": [],
        }
