"""普通 NTFS 卷镜像的有界读取。只接受用户单选并明确同意。

不挂载、不修复、不写回镜像。父路径来自已读到的 MFT 文件名链，不是完整目录索引或卷健康证明。
正在进行的读取不能被强制打断；预算在记录之间生效。
"""

from __future__ import annotations

import hashlib
import os
import stat
import struct
import time
import uuid
from pathlib import Path

from gaojiling.errors import AppError

ALLOWED_SUFFIXES = {".ntfs", ".img", ".raw", ".dd"}
DEFAULT_BUDGET = {"records": 4096, "bytes": 64 * 1024 * 1024, "seconds": 10, "extract": 16 * 1024 * 1024}


def _nofollow_open(path: Path):
    if path.is_symlink():
        raise AppError("镜像路径是符号链接，已拒绝。")
    flags = os.O_RDONLY
    for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
        flags |= getattr(os, name, 0)
    try:
        handle = os.open(path, flags)
    except OSError as error:
        raise AppError(f"无法只读打开镜像：{error}") from error
    info = os.fstat(handle)
    if not stat.S_ISREG(info.st_mode):
        os.close(handle)
        raise AppError("只能分析普通文件镜像，不会打开原始设备。")
    return handle, info


def _identity(info) -> dict:
    return {
        "device": int(info.st_dev), "inode": int(getattr(info, "st_ino", 0)),
        "size": int(info.st_size), "mtime": getattr(info, "st_mtime_ns", int(info.st_mtime * 1e9)),
    }


def _fixup(record: bytearray) -> bool:
    if len(record) < 8 or record[0:4] not in (b"FILE", b"BAAD"):
        return False
    offset, count = struct.unpack_from("<HH", record, 4)
    if count < 2 or offset + count * 2 > len(record):
        return False
    check = record[offset:offset + 2]
    for index in range(1, count):
        end = index * 512 - 2
        if end + 2 > len(record) or record[end:end + 2] != check:
            return False
        record[end:end + 2] = record[offset + index * 2:offset + (index + 1) * 2]
    return True


def _u64(data, offset):
    return struct.unpack_from("<Q", data, offset)[0]


def _name(data) -> tuple[int, int, str]:
    parent = _u64(data, 0)
    length = data[64]
    text = data[66:66 + length * 2].decode("utf-16le", errors="replace")
    return parent & 0xFFFFFFFFFFFF, (parent >> 48) & 0xFFFF, text


def _attributes(record: bytes) -> list[dict]:
    if len(record) < 22:
        raise AppError("镜像结构异常：记录过短。未执行修复。")
    first = struct.unpack_from("<H", record, 20)[0]
    offset = first
    found = []
    for _ in range(256):
        if offset + 8 > len(record):
            raise AppError("镜像结构异常：属性越过记录。未执行修复。")
        kind, length = struct.unpack_from("<II", record, offset)
        if kind == 0xFFFFFFFF:
            return found
        if length < 24 or offset + length > len(record):
            raise AppError("镜像结构异常：属性长度无效。未执行修复。")
        nonresident = record[offset + 8]
        name_length = record[offset + 9]
        name_offset = struct.unpack_from("<H", record, offset + 10)[0]
        flags = struct.unpack_from("<H", record, offset + 12)[0]
        named = ""
        if name_length:
            start = offset + name_offset
            named = record[start:start + name_length * 2].decode("utf-16le", errors="replace")
        value = b""
        runs = b""
        real_size = None
        if nonresident == 0:
            value_length = struct.unpack_from("<I", record, offset + 16)[0]
            value_offset = struct.unpack_from("<H", record, offset + 20)[0]
            value = record[offset + value_offset:offset + value_offset + value_length]
        else:
            real_size = _u64(record, offset + 48)
            run_offset = struct.unpack_from("<H", record, offset + 32)[0]
            runs = record[offset + run_offset:offset + length]
        found.append({"kind": kind, "flags": flags, "name": named, "resident": nonresident == 0,
                      "value": value, "runs": runs, "realSize": real_size})
        offset += length
    raise AppError("镜像结构异常：单记录属性超过 256 个。未执行修复。")


def _run_extent(runs: bytes) -> tuple[int, int] | None:
    if not runs or runs[0] == 0:
        return None
    length_size = runs[0] & 0x0F
    offset_size = runs[0] >> 4
    cursor = 1
    if length_size == 0 or offset_size == 0 or cursor + length_size + offset_size >= len(runs):
        return None
    length = int.from_bytes(runs[cursor:cursor + length_size], "little")
    cursor += length_size
    raw = runs[cursor:cursor + offset_size]
    offset = int.from_bytes(raw, "little")
    if raw[-1] & 0x80:
        offset -= 1 << (offset_size * 8)
    if runs[cursor + offset_size] not in (0,):
        # 多段或稀疏，不把它说成一个可安全提取的普通流。
        if runs[cursor + offset_size] != 0:
            return None
    return offset, length


def analyze_image(path: Path, consent: bool, budget: dict | None = None, cancelled=lambda: False) -> dict:
    if not consent:
        raise AppError("需要单独同意后才会读取镜像内容。选择文件本身不会开始解析。")
    path = Path(path)
    if path.suffix.lower() not in ALLOWED_SUFFIXES:
        raise AppError("只接受 .ntfs、.img、.raw 或 .dd 普通文件。")
    limits = dict(DEFAULT_BUDGET)
    if budget:
        limits.update(budget)
    if not 1 <= limits["records"] <= 4096 or not 512 <= limits["bytes"] <= 64 * 1024 * 1024 or not 0 < limits["seconds"] <= 30:
        raise AppError("记录、读取或时间预算不在允许范围。")
    handle, info = _nofollow_open(path)
    started = time.monotonic()
    read_bytes = 0
    warnings = ["父路径只来自本次读到的 MFT 文件名引用，不是完整目录，也不是卷一致性证明。"]
    try:
        boot = os.read(handle, 512)
        read_bytes += len(boot)
        if len(boot) < 512 or boot[3:11] != b"NTFS    ":
            raise AppError("不是可识别的普通 NTFS 引导扇区。未执行修复。")
        bps = struct.unpack_from("<H", boot, 11)[0]
        spc = boot[13]
        if bps not in {512, 1024, 2048, 4096} or spc == 0:
            raise AppError("镜像结构异常：扇区或簇大小不受支持。未执行修复。")
        cluster = bps * spc
        mft_cluster = struct.unpack_from("<Q", boot, 48)[0]
        raw_record = struct.unpack_from("<b", boot, 64)[0]
        record_size = 1 << (-raw_record) if raw_record < 0 else raw_record * cluster
        if record_size not in {1024, 4096}:
            raise AppError("镜像结构异常：MFT 记录大小不受支持。未执行修复。")
        entries = []
        names = {}
        offset = mft_cluster * cluster
        examined = 0
        partial = False
        file_size = int(info.st_size)
        for slot in range(limits["records"]):
            if cancelled() or time.monotonic() - started >= limits["seconds"] or read_bytes >= limits["bytes"]:
                partial = True
                warnings.append("已达到协作预算。正在进行的读取不能被提前打断，已读到的记录仍然保留。")
                break
            position = offset + slot * record_size
            if position >= file_size:
                warnings.append("镜像文件在后续 MFT 记录之前结束。未出现的记录不会被说成空目录或健康的卷。")
                break
            if position + record_size > file_size:
                partial = True
                warnings.append("镜像在一条 MFT 记录中间结束。这不是完整卷。")
                break
            try:
                os.lseek(handle, position, os.SEEK_SET)
                blob = os.read(handle, record_size)
            except OSError as error:
                partial = True
                warnings.append(f"记录 {slot} 无法读取：{error}")
                break
            read_bytes += len(blob)
            examined += 1
            if len(blob) < record_size:
                partial = True
                warnings.append("镜像在 MFT 前提前结束。这不是完整卷。")
                break
            record = bytearray(blob)
            if record[0:4] != b"FILE" or not _fixup(record):
                continue
            flags = struct.unpack_from("<H", record, 22)[0]
            if flags & 1 == 0:
                continue
            sequence = struct.unpack_from("<H", record, 16)[0]
            try:
                attributes = _attributes(bytes(record))
            except AppError as error:
                warnings.append(f"记录 {slot}：{error}")
                continue
            file_names = []
            data = []
            for attribute in attributes:
                if attribute["kind"] == 0x30 and attribute["resident"] and len(attribute["value"]) >= 66:
                    parent, parent_seq, text = _name(attribute["value"])
                    file_names.append({"parent": parent, "parentSequence": parent_seq, "name": text})
                if attribute["kind"] == 0x80:
                    data.append(attribute)
            if not file_names:
                continue
            chosen = file_names[0]
            stream_names = [item["name"] for item in data if item["name"]]
            reason = None
            resident = None
            for item in data:
                if item["name"]:
                    continue
                if item["flags"] & 0x0001:
                    reason = "压缩数据流不提取"
                elif item["flags"] & 0x4000:
                    reason = "加密数据流不提取"
                elif item["flags"] & 0x8000:
                    reason = "稀疏数据流不提取"
                elif item["resident"]:
                    resident = item["value"]
                else:
                    reason = "非常驻数据流本次只记录，不提取"
            if flags & 2:
                reason = "目录不提取"
            if stream_names and resident is None:
                reason = reason or "命名流不提取"
            entry = {
                "id": f"{slot}:{sequence}",
                "recordNumber": slot,
                "sequence": sequence,
                "name": chosen["name"],
                "parent": chosen["parent"],
                "parentSequence": chosen["parentSequence"],
                "isDirectory": bool(flags & 2),
                "logicalBytes": len(resident) if resident is not None else None,
                "streamNames": stream_names,
                "canExtract": resident is not None and reason is None and not (flags & 2),
                "extractionUnavailableReason": reason,
                "resident": resident,
            }
            names[slot] = entry
            entries.append(entry)
        for entry in entries:
            components = []
            seen = set()
            current = entry
            resolved = True
            while current and current["recordNumber"] != 5 and current["name"] not in {".", ""}:
                if current["recordNumber"] in seen:
                    resolved = False
                    break
                seen.add(current["recordNumber"])
                components.append(current["name"])
                parent = names.get(current["parent"])
                if parent is None or (parent["sequence"] and current["parentSequence"] not in {0, parent["sequence"]}):
                    resolved = False
                    break
                current = parent
                if len(components) > 256:
                    resolved = False
                    break
            if resolved and current is not None:
                entry["pathComponents"] = list(reversed(components))
                entry["pathState"] = "已核父引用"
            else:
                entry["pathComponents"] = None
                entry["pathState"] = "父路径未解析"
                entry["canExtract"] = False
                entry["extractionUnavailableReason"] = entry["extractionUnavailableReason"] or "父路径未解析，不提取"
            entry.pop("resident", None)
            entry.pop("parent", None)
            entry.pop("parentSequence", None)
        after = os.fstat(handle)
        unchanged = _identity(info) == _identity(after)
        if not unchanged:
            warnings.append("分析期间镜像身份发生变化，结果只代表开始时读到的字节。")
        source_sha = None
        hash_scope = "文件超过读取预算，未计算完整哈希。"
        if unchanged and file_size <= limits["bytes"]:
            os.lseek(handle, 0, os.SEEK_SET)
            hasher = hashlib.sha256()
            remaining = file_size
            while remaining:
                chunk = os.read(handle, min(1024 * 1024, remaining))
                if not chunk:
                    break
                hasher.update(chunk)
                remaining -= len(chunk)
                read_bytes += len(chunk)
            if remaining == 0:
                source_sha = hasher.hexdigest()
                hash_scope = "整个普通文件的 SHA-256；不包含镜像以外的文件。"
        status = "部分" if partial or not unchanged else "完成"
        return {
            "schemaVersion": 1,
            "id": str(uuid.uuid4()).upper(),
            "imageName": path.name,
            "sourcePath": str(path),
            "sourceBytes": int(info.st_size),
            "inspectedBytes": read_bytes,
            "sourceSHA256": source_sha,
            "hashScope": hash_scope,
            "format": "NTFS",
            "status": status,
            "complete": status == "完成",
            "directoryInventory": False,
            "entries": [{key: value for key, value in entry.items() if key != "resident"} for entry in entries],
            "warnings": warnings,
            "examinedRecordSlots": examined,
            "recordSlotLimit": limits["records"],
            "identity": _identity(info),
            "_handle_closed": True,
        }
    finally:
        os.close(handle)


def extract(path: Path, analysis: dict, entry_id: str, destination: Path, confirm: bool):
    if not confirm:
        raise AppError("需要逐项确认后才提取。")
    if not analysis.get("complete"):
        raise AppError("不完整的镜像分析不能提取。")
    entry = next((item for item in analysis["entries"] if item["id"] == entry_id), None)
    if entry is None or not entry.get("canExtract"):
        raise AppError(entry.get("extractionUnavailableReason") if entry else "没有这条可提取记录。")
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise AppError("目标已存在，未覆盖原件。")
    # 重新解析这一条记录，避免使用分析对象里没有保留的字节。
    fresh = analyze_image(path, True)
    if fresh["identity"] != analysis["identity"]:
        raise AppError("镜像身份已变化，未提取。")
    again = next((item for item in fresh["entries"] if item["id"] == entry_id and item.get("canExtract")), None)
    if again is None:
        raise AppError("记录已变化，未提取。")
    handle, info = _nofollow_open(path)
    try:
        if _identity(info) != analysis["identity"]:
            raise AppError("镜像身份已变化，未提取。")
        bps = 512
        os.lseek(handle, 0, os.SEEK_SET)
        boot = os.read(handle, 512)
        bps = struct.unpack_from("<H", boot, 11)[0]
        spc = boot[13]
        cluster = bps * spc
        mft_cluster = struct.unpack_from("<Q", boot, 48)[0]
        raw_record = struct.unpack_from("<b", boot, 64)[0]
        record_size = 1 << (-raw_record) if raw_record < 0 else raw_record * cluster
        os.lseek(handle, mft_cluster * cluster + entry["recordNumber"] * record_size, os.SEEK_SET)
        blob = bytearray(os.read(handle, record_size))
        if not _fixup(blob):
            raise AppError("记录校验失败，未提取。")
        payload = b""
        for attribute in _attributes(bytes(blob)):
            if attribute["kind"] == 0x80 and attribute["resident"] and not attribute["name"] and attribute["flags"] == 0:
                payload = attribute["value"]
                break
        else:
            raise AppError("没有可提取的普通默认数据流。")
        if len(payload) > DEFAULT_BUDGET["extract"]:
            raise AppError("超过 16 MiB，未提取。")
        destination.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        flags |= getattr(os, "O_BINARY", 0)
        out = os.open(destination, flags, 0o600)
        try:
            os.write(out, payload)
        finally:
            os.close(out)
        digest = hashlib.sha256(payload).hexdigest()
        return {"bytes": len(payload), "sha256": digest, "path": str(destination),
                "message": "已提取到新文件。没有修改镜像，也没有覆盖已有目标。"}
    finally:
        os.close(handle)
