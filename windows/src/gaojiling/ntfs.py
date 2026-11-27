"""Bounded, read-only inspection of ordinary NTFS volume image files."""

from __future__ import annotations

import hashlib
import os
import stat
import struct
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import checked_stat, identity, local_path, open_regular

ALLOWED_SUFFIXES = {".ntfs", ".img", ".raw", ".dd"}
DEFAULT_BUDGET = {"records": 4096, "bytes": 64 << 20, "seconds": 10, "extract": 16 << 20}
READ_CHUNK = 1 << 20


class BudgetExceeded(AppError):
    pass


class Image:
    def __init__(self, fd, info, limits, cancelled):
        self.fd = fd
        self.info = info
        self.limits = limits
        self.cancelled = cancelled
        self.deadline = time.monotonic() + limits["seconds"]
        self.used = 0

    def checkpoint(self, length=0):
        if self.cancelled() or time.monotonic() >= self.deadline or self.used + length > self.limits["bytes"]:
            raise BudgetExceeded("已达到取消、时间或读取预算，保留已读取的记录。")

    def read(self, offset, length):
        self.checkpoint(length)
        if offset < 0 or offset + length > self.info.st_size:
            raise AppError("读取范围超出普通镜像文件。")
        os.lseek(self.fd, offset, os.SEEK_SET)
        data = os.read(self.fd, length)
        self.used += len(data)
        if len(data) != length:
            raise AppError("镜像读取提前结束。")
        return data


@dataclass(frozen=True)
class Stream:
    logical: int
    initialized: int
    resident: bytes | None = None
    runs: tuple[tuple[int, int], ...] = ()

    def read(self, image: Image, offset: int, length: int):
        if offset + length > self.initialized:
            raise AppError("所选数据流的范围尚未初始化。")
        if self.resident is not None:
            return self.resident[offset:offset + length]
        result = bytearray()
        for physical, extent_bytes in self.runs:
            if offset >= extent_bytes:
                offset -= extent_bytes
                continue
            count = min(length - len(result), extent_bytes - offset)
            result.extend(image.read(physical + offset, count))
            if len(result) == length:
                return bytes(result)
            offset = 0
        raise AppError("数据运行不能覆盖所选范围。")


def _boot(image: Image, boot: bytes) -> dict:
    sector, sectors_per_cluster = struct.unpack_from("<HB", boot, 11)
    if sector not in (512, 1024, 2048, 4096) or not 0 < sectors_per_cluster <= 128 or sectors_per_cluster & (sectors_per_cluster - 1):
        raise AppError("NTFS 扇区或簇大小不受支持。")
    cluster = sector * sectors_per_cluster
    volume_bytes = struct.unpack_from("<Q", boot, 40)[0] * sector
    mft_cluster, mirror_cluster = struct.unpack_from("<QQ", boot, 48)
    size_code = struct.unpack_from("<b", boot, 64)[0]
    record = 1 << -size_code if size_code < 0 else size_code * cluster
    clusters = volume_bytes // cluster
    if not sector <= record <= 65536 or record & (record - 1) or record % sector:
        raise AppError("MFT 记录大小不受支持。")
    if not 0 < volume_bytes <= min(image.info.st_size, 1 << 40):
        raise AppError("NTFS 声明的卷大小超出镜像或 1 TiB 上限。")
    if not 0 < mft_cluster < clusters or not 0 < mirror_cluster < clusters or mft_cluster * cluster + record > volume_bytes:
        raise AppError("MFT 或镜像位置超出 NTFS 卷。")
    return {"bytesPerSector": sector, "sectorBytes": sector, "sectorsPerCluster": sectors_per_cluster,
            "clusterBytes": cluster, "volumeBytes": volume_bytes,
            "volumeClusters": clusters, "recordBytes": record, "mftCluster": mft_cluster}


def _nonresident(attr: bytes, geometry: dict) -> Stream:
    low, high, run_offset, compression = struct.unpack_from("<QQHH", attr, 16)
    allocated, logical, initialized = struct.unpack_from("<QQQ", attr, 40)
    clusters = geometry["volumeClusters"]
    cluster_bytes = geometry["clusterBytes"]
    if low != 0 or high >= clusters or not 64 <= run_offset < len(attr) or compression or not initialized <= logical <= allocated:
        raise AppError("非常驻数据流的 VCN、运行偏移或初始化范围无效。")
    runs = []
    logical_clusters = 0
    physical = 0
    for _ in range(128):
        if run_offset >= len(attr):
            break
        marker = attr[run_offset]
        run_offset += 1
        if marker == 0:
            if runs and logical_clusters == high + 1 and allocated == logical_clusters * cluster_bytes:
                return Stream(logical, initialized, runs=tuple(
                    (start * cluster_bytes, count * cluster_bytes) for start, count in runs))
            break
        count_width = marker & 0xF
        offset_width = marker >> 4
        delta_offset = run_offset + count_width
        end = delta_offset + offset_width
        if not (1 <= count_width <= 8 and 1 <= offset_width <= 8 and end <= len(attr)):
            raise AppError("不支持稀疏运行或无效的 NTFS 运行字段。")
        count = int.from_bytes(attr[run_offset:delta_offset], "little")
        physical += int.from_bytes(attr[delta_offset:end], "little", signed=True)
        if not count or not 0 <= physical <= clusters - count or logical_clusters + count > high + 1:
            raise AppError("NTFS 数据运行超出卷或 VCN 范围。")
        if any(start < physical + count and physical < start + prior_count for start, prior_count in runs):
            raise AppError("NTFS 数据运行物理范围重叠。")
        runs.append((physical, count))
        logical_clusters += count
        run_offset = end
    raise AppError("NTFS 数据运行未终止，或分配长度与 VCN 不符。")


def _record(blob: bytes, slot: int, geometry: dict):
    sector = geometry["sectorBytes"]
    record = bytearray(blob)
    usa, count = struct.unpack_from("<HH", record, 4)
    if record[:4] != b"FILE" or not 48 <= usa <= len(record) - count * 2 or usa % 2 or count != len(record) // sector + 1:
        raise AppError("MFT 记录头或扇区修正表无效。")
    fix = record[usa:usa + 2]
    for index in range(1, count):
        end = index * sector
        if record[end - 2:end] != fix:
            raise AppError("MFT 记录扇区校验失败。")
        record[end - 2:end] = record[usa + index * 2:usa + (index + 1) * 2]
    sequence, links, start, record_flags, used, allocated, base = struct.unpack_from("<HHHHIIQ", record, 16)
    if not record_flags & 1:
        return None
    if (not sequence or slot != struct.unpack_from("<I", record, 44)[0] or allocated != len(record)
            or not usa + count * 2 <= start <= used - 4 or used > allocated or start % 8):
        raise AppError("MFT 记录编号、序列或属性边界无效。")
    if base:
        raise AppError("扩展 MFT 记录需拼接 ATTRIBUTE_LIST，本次跳过。")

    stream = None
    names = []
    streams = []
    features = set()
    version = None
    size = None
    for _ in range(256):
        if start + 4 > used:
            break
        kind = struct.unpack_from("<I", record, start)[0]
        if kind == 0xFFFFFFFF:
            return (sequence, bool(record_flags & 2), links, names, streams, features, stream, size, version)
        if not 0x10 <= kind <= 0x100 or kind % 16 or start + 24 > used:
            raise AppError("NTFS 属性类型或属性头无效。")
        length, external, name_size, name_at, flags = struct.unpack_from("<IBBHH", record, start + 4)
        header = 64 if external else 24
        if external not in (0, 1) or length < header or length % 8 or start + length > used:
            raise AppError("NTFS 属性长度越界。")
        attr = bytes(record[start:start + length])
        start += length
        name_end = name_at + name_size * 2 if name_size else 0
        if name_size and (name_at < header or name_end > length):
            raise AppError("命名流名称超出属性范围。")
        try:
            name = attr[name_at:name_end].decode("utf-16-le") if name_size else ""
        except UnicodeDecodeError as error:
            raise AppError("属性名称含无效的 UTF-16。") from error
        for mask, feature in ((1, "compressed"), (0x4000, "encrypted"), (0x8000, "sparse")):
            if flags & mask:
                features.add(feature)
        if flags & ~0xC001:
            features.add("unknownFlags")
        if kind == 0x20:
            features.add("attributeList")
        if kind == 0xC0:
            features.add("reparsePoint")
        if kind == 0x80:
            if name in streams:
                raise AppError("重复的 NTFS 数据流；本次不拼接属性段。")
            streams.append(name)
            if name:
                features.add("namedStream")
        if external:
            if kind == 0x80 and not name:
                size = struct.unpack_from("<Q", attr, 48)[0]
                if not flags:
                    stream = _nonresident(attr, geometry)
            continue
        value_size, value_at = struct.unpack_from("<IH", attr, 16)
        if not max(header, name_end) <= value_at <= length - value_size:
            raise AppError("驻留属性值越界。")
        value = attr[value_at:value_at + value_size]
        if kind == 0x80 and not name:
            size = len(value)
            stream = Stream(size, size, resident=value)
        if kind == 0x70 and len(value) == 12:
            version = f"{value[8]}.{value[9]}"
        if kind == 0x10 and len(value) in (48, 72):
            _file_features(features, struct.unpack_from("<I", value, 32)[0])
        if kind == 0x30:
            if len(value) < 68 or value[65] > 3 or len(value) != 66 + value[64] * 2:
                raise AppError("FILE_NAME 属性长度或命名空间无效。")
            try:
                title = value[66:].decode("utf-16-le")
            except UnicodeDecodeError as error:
                raise AppError("文件名含无效的 UTF-16。") from error
            parent = struct.unpack_from("<Q", value)[0]
            if not parent >> 48 or not title or any(char in title for char in "/\\\0") or title == ".." or (title == "." and slot != 5):
                raise AppError("FILE_NAME 含不支持的名称或父引用。")
            names.append((title, value[65], parent & 0xFFFFFFFFFFFF, parent >> 48))
            _file_features(features, struct.unpack_from("<I", value, 56)[0])
    raise AppError("MFT 属性缺少终止符或超过 256 项。")


def _file_features(features: set, flags: int):
    for mask, feature in ((0x200, "sparse"), (0x400, "reparsePoint"), (0x800, "compressed"), (0x4000, "encrypted")):
        if flags & mask:
            features.add(feature)


def _inspect(image: Image, name: str) -> tuple[dict, dict]:
    boot = image.read(0, 512)
    if boot[510:] != b"\x55\xaa":
        raise AppError("引导扇区结束签名无效。")
    if boot[3:11] == b"-FVE-FS-":
        return ({"imageName": name, "format": "BitLocker", "status": "不支持后续解析", "complete": False,
                 "directoryInventory": False, "geometry": None, "entries": [], "examinedRecordSlots": 0,
                 "recordSlotLimit": image.limits["records"], "summary": "识别到 BitLocker 标识，已停止解析。",
                 "warnings": ["依据引导扇区 OEM 标识识别，未检查加密元数据。"],
                 "features": [{"feature": "BitLocker", "state": "identified", "detail": "识别到 OEM 标识"}]}, {})
    if boot[3:11] != b"NTFS    ":
        raise AppError("不是可识别的普通 NTFS 引导扇区。镜像应从卷引导扇区开始。")
    geometry = _boot(image, boot)
    record_size = geometry["recordBytes"]
    first_offset = geometry["mftCluster"] * geometry["clusterBytes"]
    first = _record(image.read(first_offset, record_size), 0, geometry)
    mft = first[6] if first and not first[5] else None
    if not mft or not mft.runs or mft.runs[0][0] != first_offset or mft.runs[0][1] < record_size:
        raise AppError("MFT 首记录没有可用的普通非常驻默认数据流。")
    if not record_size <= mft.initialized <= mft.logical or mft.initialized % record_size or mft.logical % record_size:
        raise AppError("MFT 数据长度与记录大小不一致。")
    geometry["declaredMFTBytes"] = mft.logical
    slots = mft.initialized // record_size
    last = min(slots, image.limits["records"])
    warnings = ["只检查有界 MFT 记录前缀。父路径来自本次读取的文件名引用。"]
    entries = {}
    contents = {}
    scope_limited = slots > last or mft.initialized != mft.logical
    partial = False
    if scope_limited:
        warnings.append("MFT 存在超出记录预算或尚未初始化的范围。")
    examined = 0
    names_bytes = 0
    for slot in range(last):
        try:
            image.checkpoint()
            blob = None if slot == 0 else mft.read(image, slot * record_size, record_size)
            examined += 1
            if blob is not None and not any(blob):
                continue
            parsed = first if slot == 0 else _record(blob, slot, geometry)
        except BudgetExceeded as error:
            warnings.append(str(error))
            partial = True
            break
        except (AppError, OSError) as error:
            if len(warnings) < 31:
                warnings.append(f"MFT 记录 {slot} 未解析：{error}")
            partial = True
            continue
        if parsed is None:
            continue
        sequence, directory, links, names, streams, flags, stream, size, version = parsed
        if version is not None and (slot != 3 or version != "3.1"):
            raise AppError(f"不支持的 NTFS 版本或卷信息位置：{version}。")
        preferred = next((item for item in names if item[1] in (1, 3)), names[0] if names else None)
        name_text = preferred[0] if preferred else f"（记录 {slot}，无已解析文件名）"
        shown_streams = [value or "（默认数据流）" for value in streams]
        names_bytes += len(name_text.encode()) + sum(len(value.encode()) for value in shown_streams)
        if names_bytes > 1 << 20:
            warnings.append("报告名称和数据流字段已达到 1 MiB 上限。")
            partial = True
            break
        entry_id = f"{slot}:{sequence}"
        reason = None
        if directory:
            reason = "目录不作为单个文件提取。"
        elif slot < 16 or name_text.startswith("$"):
            reason = "NTFS 系统元数据只展示。"
        elif flags:
            reason = "含命名流、压缩、加密、稀疏、重解析点、扩展属性或未知标志。"
        elif stream is None:
            reason = "缺少可读取的普通默认数据流。"
        elif stream.initialized != stream.logical:
            reason = "默认数据流未完全初始化。"
        elif stream.logical > image.limits["extract"]:
            reason = "超过单文件提取预算（最多 16 MiB）。"
        entries[slot] = {"id": entry_id, "recordNumber": slot, "sequence": sequence, "name": name_text,
                         "isDirectory": directory, "logicalBytes": size, "hardLinkCount": links,
                         "observedNameCount": len(names), "streamNames": shown_streams, "flags": sorted(flags),
                         "extractionUnavailableReason": reason, "_parent": preferred[2:] if preferred else None}
        if reason is None:
            contents[entry_id] = stream

    def observed_path(slot, seen):
        if slot in seen or len(seen) >= 128:
            return None
        entry = entries[slot]
        parent = entry["_parent"]
        if slot == 5:
            return [] if entry["isDirectory"] and entry["name"] == "." and parent == (5, entry["sequence"]) else None
        if parent is None:
            return None
        up = entries.get(parent[0])
        if up is None or not up["isDirectory"] or up["sequence"] != parent[1]:
            return None
        prefix = observed_path(parent[0], {*seen, slot})
        return prefix + [entry["name"]] if prefix is not None else None

    path_bytes = 0
    unresolved = False
    for slot, entry in entries.items():
        path = observed_path(slot, set()) if path_bytes <= 4 << 20 else None
        if path is not None:
            path_bytes += sum(len(part.encode()) + 1 for part in path)
            if path_bytes > 4 << 20:
                warnings.append("报告路径字段已达到 4 MiB 上限。")
                partial = True
                path = None
        unresolved |= path is None
        if path is None and entry["extractionUnavailableReason"] is None:
            entry["extractionUnavailableReason"] = "父路径未解析。"
        parent = entry["_parent"]
        entry.update(pathComponents=path, parentID=entries[parent[0]]["id"] if path and parent else None,
                     pathState="已核父引用" if path is not None else "父路径未解析",
                     canExtract=entry["extractionUnavailableReason"] is None)
    if unresolved:
        warnings.append("未核实的父路径已单列。")
    for entry in entries.values():
        entry.pop("_parent")
        if partial and entry["canExtract"]:
            entry["canExtract"] = False
            entry["extractionUnavailableReason"] = "分析未完成。"
    features = [
        {"feature": title, "state": "identified", "detail": "在此次检查范围内发现"}
        for name, title in (("namedStream", "命名数据流"), ("compressed", "压缩"), ("encrypted", "EFS"),
                            ("sparse", "稀疏"), ("reparsePoint", "重解析点"), ("attributeList", "ATTRIBUTE_LIST"))
        if any(name in row["flags"] for row in entries.values())
    ]
    return ({"imageName": name, "format": "NTFS",
             "status": "部分" if partial else ("有界前缀" if scope_limited else "完成"),
             "summary": f"已检查 {examined} 个 MFT 记录槽，列出 {len(entries)} 个在用记录。",
             "complete": not partial, "directoryInventory": False, "geometry": geometry, "entries": list(entries.values()),
             "warnings": warnings, "features": features, "examinedRecordSlots": examined,
             "recordSlotLimit": image.limits["records"]}, contents)


def _unchanged(path, image):
    expected = identity(image.info)
    return identity(os.fstat(image.fd)) == expected == identity(checked_stat(path))


def _hash(image):
    hasher = hashlib.sha256()
    size = image.info.st_size
    for offset in range(0, size, READ_CHUNK):
        hasher.update(image.read(offset, min(READ_CHUNK, size - offset)))
    return hasher.hexdigest()


def _validate(path):
    path = local_path(path)
    if path.suffix.lower() not in ALLOWED_SUFFIXES:
        raise AppError("只接受 .ntfs、.img、.raw 或 .dd 普通文件。")
    return path


def analyze_image(path: Path, consent: bool, budget: dict | None = None, cancelled=lambda: False) -> dict:
    if not consent:
        raise AppError("需要单独同意后才会读取镜像内容。选择文件本身不会开始解析。")
    path = _validate(path)
    limits = DEFAULT_BUDGET | (budget or {})
    if not (1 <= limits["records"] <= 4096 and 512 <= limits["bytes"] <= 64 << 20
            and 0 < limits["seconds"] <= 30 and 0 < limits["extract"] <= 16 << 20):
        raise AppError("记录、读取、时间或提取预算不在允许范围。")
    fd, info = open_regular(path)
    image = Image(fd, info, limits, cancelled)
    try:
        result, _ = _inspect(image, path.name)
        digest = None
        hash_scope = "超过完整哈希的 16 MiB 或剩余读取预算。"
        if info.st_size <= min(16 << 20, limits["bytes"] - image.used):
            try:
                digest = _hash(image)
                hash_scope = "整个普通镜像文件的 SHA-256。"
            except BudgetExceeded:
                hash_scope = "完整哈希达到协作预算。"
        if not _unchanged(path, image):
            raise AppError("分析期间镜像身份发生变化，已停止。")
        was_cancelled = bool(cancelled())
        if was_cancelled:
            result.update(status="已取消", complete=False)
            for entry in result["entries"]:
                if entry["canExtract"]:
                    entry.update(canExtract=False, extractionUnavailableReason="分析已取消。")
        return result | {"schemaVersion": 1, "id": str(uuid.uuid4()).upper(), "sourcePath": str(path),
                         "sourceBytes": info.st_size, "inspectedBytes": image.used, "sourceSHA256": digest,
                         "hashScope": hash_scope, "identity": identity(info), "sourceUnchanged": True,
                         "directoryInventoryComplete": False, "cancelled": was_cancelled,
                         "writeCapabilities": {"mount": False, "format": False, "repair": False, "write": False}}
    finally:
        os.close(fd)


def extract(path: Path, analysis: dict, entry_id: str, destination: Path, confirm: bool):
    if not confirm:
        raise AppError("需要逐项确认后才提取。")
    if not analysis.get("complete"):
        raise AppError("不完整的镜像分析不能提取。")
    entry = next((item for item in analysis["entries"] if item["id"] == entry_id), None)
    if entry is None or not entry["canExtract"]:
        raise AppError(entry["extractionUnavailableReason"] if entry else "没有这条可提取记录。")
    path = _validate(path)
    destination = local_path(destination)
    if not stat.S_ISDIR(checked_stat(destination.parent).st_mode):
        raise AppError("提取目的地的上级必须是现有普通目录。")
    if os.path.lexists(destination):
        raise AppError("目标已存在，未覆盖原件。")
    fd, info = open_regular(path)
    image = Image(fd, info, DEFAULT_BUDGET, lambda: False)
    try:
        if identity(info) != analysis["identity"]:
            raise AppError("镜像身份已变化，未提取。")
        current, contents = _inspect(image, path.name)
        again = next((item for item in current["entries"] if item["id"] == entry_id), None)
        if not current["complete"] or again != entry or entry_id not in contents:
            raise AppError("重新读取后条目、路径或数据流发生变化。")
        if analysis.get("sourceSHA256") and _hash(image) != analysis["sourceSHA256"]:
            raise AppError("镜像内容与分析时的全文件 SHA-256 不同。")
        stream = contents[entry_id]
        temporary = destination.with_name(f".gaojiling-extract-{uuid.uuid4().hex}")
        digest = hashlib.sha256()
        try:
            with temporary.open("xb") as output:
                for offset in range(0, stream.logical, READ_CHUNK):
                    payload = stream.read(image, offset, min(READ_CHUNK, stream.logical - offset))
                    output.write(payload)
                    digest.update(payload)
                output.flush()
                os.fsync(output.fileno())
            if not _unchanged(path, image):
                raise AppError("镜像身份已变化，未提取。")
            checked_stat(destination.parent)
            if os.name == "nt":
                os.rename(temporary, destination)
            else:
                os.link(temporary, destination)
        except FileExistsError as error:
            raise AppError("目标已存在，未覆盖原件。") from error
        finally:
            temporary.unlink(missing_ok=True)
        return {"bytes": stream.logical, "sha256": digest.hexdigest(), "path": str(destination),
                "message": "已提取所选普通默认数据流到新文件。"}
    finally:
        os.close(fd)
