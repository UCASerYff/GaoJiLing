"""完整 JSON 资料。SHA-256 是完整性校验，不是签名。恢复前不制作自动备份。"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.jsonutil import dumps
from gaojiling.sessioncompare import BACKUP_PREFIX, DETAIL_LIMIT, validate_detail
from gaojiling.store import decode_event, decode_sample, decode_session, normalize_settings
from gaojiling.timeutil import check_unix, cocoa_to_unix, unix_to_cocoa
from gaojiling.version import MARKETING

MAX_BYTES = 256 * 1_048_576
_VERSION = re.compile(r"^[0-9]{1,6}\.[0-9]{2}$")


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _sample_backup(sample: dict) -> dict:
    processes = []
    for process in sample.get("processes") or []:
        item = {
            "cpuPercent": 0 if process.get("cpuAvailable") is False and process.get("cpuPercent") is None else process.get("cpuPercent") or 0,
            "memoryBytes": process.get("memoryBytes") or 0,
            "name": process["name"],
            "pids": process.get("pids") or [],
        }
        for key in ("availabilityReason", "bundleID", "cpuAvailable", "groupID", "path", "memoryAvailabilityReason"):
            if process.get(key) is not None:
                item[key] = process[key]
        if process.get("identities"):
            item["identities"] = process["identities"]
        if process.get("observedAt") is not None:
            item["observedAt"] = unix_to_cocoa(process["observedAt"])
        processes.append(item)
    return {
        "batteryCharging": bool(sample.get("batteryCharging") or False),
        "batteryCycles": sample.get("batteryCycles"),
        "batteryHealth": sample.get("batteryHealth"),
        "batteryPercent": sample.get("batteryPercent"),
        "corePercents": sample.get("corePercents") or [],
        "cpuPercent": sample.get("cpuPercent"),
        "cpuPower": sample.get("cpuPower"),
        "cpuTemperature": sample.get("cpuTemperature"),
        "diskFree": sample.get("diskFree"),
        "diskRead": sample.get("diskRead"),
        "diskTotal": sample.get("diskTotal"),
        "diskWrite": sample.get("diskWrite"),
        "fanRPM": sample.get("fanRPM"),
        "gpuPercent": sample.get("gpuPercent"),
        "gpuPower": sample.get("gpuPower"),
        "memoryCompressed": sample.get("memoryCompressed"),
        "memoryPressure": sample.get("memoryPressure") or "未知",
        "memoryTotal": sample.get("memoryTotal"),
        "memoryUsed": sample.get("memoryUsed"),
        "networkDown": sample.get("networkDown"),
        "networkUp": sample.get("networkUp"),
        "processCount": sample.get("processCount"),
        "processes": processes,
        "swapUsed": sample.get("swapUsed"),
        "thermalState": sample.get("thermalState") or "未知",
        "timestamp": unix_to_cocoa(sample["timestamp"]),
        "uptime": sample.get("uptime"),
    }


def _event_backup(event: dict) -> dict:
    return {
        "date": unix_to_cocoa(event["date"]),
        "detail": event.get("detail") or "",
        "id": event["id"].upper(),
        "kind": event["kind"],
        "severity": event["severity"],
        "title": event["title"],
    }


def _session_backup(session: dict) -> dict:
    return {
        "cpuTotal": session.get("cpuTotal") or 0,
        "end": unix_to_cocoa(session["end"]) if session.get("end") is not None else None,
        "id": session["id"].upper(),
        "interrupted": session.get("interrupted"),
        "lastObserved": unix_to_cocoa(session["lastObserved"]) if session.get("lastObserved") is not None else None,
        "name": session["name"],
        "peakCPU": session.get("peakCPU") or 0,
        "peakMemory": session.get("peakMemory") or 0,
        "peakTemperature": session.get("peakTemperature"),
        "sampleCount": session.get("sampleCount") or 0,
        "start": unix_to_cocoa(session["start"]),
    }


def build_backup(samples, events, sessions, settings, auxiliary, exported_at: float, app_version: str = MARKETING) -> dict:
    document = {
        "appVersion": app_version,
        "auxiliaryPreferences": auxiliary or None,
        "dateEncoding": "secondsSince2001-01-01T00:00:00Z",
        "events": [_event_backup(event) for event in events],
        "exportedAt": unix_to_cocoa(exported_at),
        "format": "com.gaoseries.GaoJiLing.backup",
        "samples": [_sample_backup(sample) for sample in samples],
        "schemaVersion": 1,
        "sessions": [_session_backup(session) for session in sessions],
        "settings": settings,
        "sha256": "",
    }
    document["sha256"] = _sha(dumps(document))
    return document


def backup_bytes(document: dict) -> bytes:
    return dumps(document).encode("utf-8")


def _text(value, limit: int, field: str, allow_empty: bool = True):
    if not isinstance(value, str) or len(value.encode("utf-8")) > limit or "\0" in value:
        raise AppError(f"完整资料校验失败：{field}为空、过长或包含无效字符。")
    if not allow_empty and not value.strip():
        raise AppError(f"完整资料校验失败：{field}为空、过长或包含无效字符。")


def _number(value, field: str, low=0.0, high=float("inf")):
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise AppError(f"完整资料校验失败：{field}不是有效数值。") from None
    if number != number or number == float("inf") or not low <= number <= high:
        raise AppError(f"完整资料校验失败：{field}不是有效数值。")
    return number


def validate_backup(raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise AppError("完整资料校验失败：这不是搞机灵的完整资料。")
    if raw.get("format") != "com.gaoseries.GaoJiLing.backup":
        raise AppError("完整资料校验失败：这不是搞机灵的完整资料。")
    if raw.get("schemaVersion") != 1:
        raise AppError(f"此备份使用资料格式 V{raw.get('schemaVersion')}，当前应用尚不支持。")
    if raw.get("dateEncoding") != "secondsSince2001-01-01T00:00:00Z":
        raise AppError("完整资料校验失败：日期编码不受支持。")
    if not isinstance(raw.get("appVersion"), str) or not _VERSION.fullmatch(raw["appVersion"]):
        raise AppError("完整资料校验失败：应用版本号无效。")
    check_unix(cocoa_to_unix(raw.get("exportedAt")), "导出时间")
    samples = raw.get("samples") or []
    events = raw.get("events") or []
    sessions = raw.get("sessions") or []
    if len(samples) > 500_000 or len(events) > 100_000 or len(sessions) > 100_000:
        raise AppError("完整资料校验失败：记录数量超出完整资料的支持范围。")
    settings = raw.get("settings")
    if settings is not None:
        normalize_settings(settings)
    auxiliary = raw.get("auxiliaryPreferences")
    if auxiliary is not None:
        if not isinstance(auxiliary, dict) or len(auxiliary) > 64:
            raise AppError("完整资料校验失败：附加偏好设置数量异常。")
        for key, value in auxiliary.items():
            _text(str(key), 256, "附加偏好名称", allow_empty=False)
            _text(str(value), 16384, "附加偏好值")
    seen = set()
    decoded_samples = []
    for sample in samples:
        stamp = check_unix(cocoa_to_unix(sample["timestamp"]), "采样时间")
        if stamp in seen:
            raise AppError("完整资料校验失败：存在重复的采样时间。")
        seen.add(stamp)
        if sample.get("cpuPercent") is not None:
            _number(sample["cpuPercent"], "CPU 百分比", 0, 100)
        for key, label, high in (
            ("gpuPercent", "GPU 百分比", 100),
            ("batteryPercent", "电量", 100),
            ("batteryHealth", "电池健康", 100),
            ("cpuTemperature", "CPU 温度", 300),
        ):
            if sample.get(key) is not None:
                low = -100 if key == "cpuTemperature" else 0
                _number(sample[key], label, low, high)
        for key in ("memoryUsed", "memoryTotal", "memoryCompressed", "swapUsed", "diskFree", "diskTotal", "uptime"):
            if sample.get(key) is not None:
                _number(sample.get(key), "系统计量")
        if sample.get("memoryUsed") is not None and sample.get("memoryTotal") is not None and sample["memoryUsed"] > sample["memoryTotal"]:
            raise AppError("完整资料校验失败：系统计量的数量或容量不一致。")
        if sample.get("diskFree") is not None and sample.get("diskTotal") is not None and sample["diskFree"] > sample["diskTotal"]:
            raise AppError("完整资料校验失败：系统计量的数量或容量不一致。")
        groups = set()
        for process in sample.get("processes") or []:
            _text(process.get("name", ""), 4096, "应用名称", allow_empty=False)
            group = process.get("groupID") or process.get("path") or process["name"]
            _text(group, 32768, "应用标识", allow_empty=False)
            if group in groups:
                raise AppError("完整资料校验失败：应用排行包含重复标识。")
            groups.add(group)
            _number(process.get("cpuPercent", 0), "应用 CPU", 0, 100)
        decoded_samples.append(decode_sample(dumps({**sample, "timestamp": sample["timestamp"]})))
    decoded_events = []
    event_ids = set()
    for event in events:
        if event.get("id") in event_ids:
            raise AppError("完整资料校验失败：存在重复的事件编号。")
        event_ids.add(event.get("id"))
        _text(event.get("title", ""), 4096, "事件标题", False)
        _text(event.get("detail", ""), 65536, "事件详情")
        decoded_events.append(decode_event(dumps(event)))
    decoded_sessions = []
    session_ids = set()
    for session in sessions:
        if session.get("id") in session_ids:
            raise AppError("完整资料校验失败：存在重复的任务编号。")
        session_ids.add(session.get("id"))
        _text(session.get("name", ""), 4096, "任务名称", False)
        start = check_unix(cocoa_to_unix(session["start"]), "任务开始时间")
        if session.get("end") is not None and check_unix(cocoa_to_unix(session["end"]), "任务结束时间") < start:
            raise AppError("完整资料校验失败：任务结束时间早于开始时间。")
        count = int(session.get("sampleCount") or 0)
        total = _number(session.get("cpuTotal") or 0, "任务 CPU 累计")
        if count < 0 or total > count * 100 + 0.0001:
            raise AppError("完整资料校验失败：任务采样计数与累计数值不一致。")
        _number(session.get("peakCPU") or 0, "任务 CPU 峰值", 0, 100)
        decoded_sessions.append(decode_session(dumps(session)))
    digest = raw.get("sha256")
    content = dict(raw)
    content["sha256"] = ""
    # 只保留声明过的顶层字段，与 Swift 结构重新编码的结果比较。
    allowed = {
        "format", "schemaVersion", "dateEncoding", "appVersion", "exportedAt", "samples",
        "events", "sessions", "settings", "auxiliaryPreferences", "sha256",
    }
    content = {key: content[key] for key in content if key in allowed}
    if not isinstance(digest, str) or len(digest) != 64 or digest != _sha(dumps(content)):
        raise AppError("备份 SHA-256 校验不符，文件可能损坏或已被修改。")
    details = _comparison_details(decoded_sessions, auxiliary or {})
    return {
        "samples": decoded_samples,
        "events": decoded_events,
        "sessions": decoded_sessions,
        "settings": normalize_settings(settings) if settings is not None else None,
        "auxiliary": auxiliary,
        "sessionDetails": details,
    }


def _comparison_details(sessions, auxiliary):
    keys = [key for key in auxiliary if key.startswith(BACKUP_PREFIX)]
    if not keys:
        return {}
    if len(keys) > DETAIL_LIMIT:
        raise AppError("完整资料中的任务比较明细数量异常。")
    by_key = {BACKUP_PREFIX + item["id"].upper(): item for item in sessions if item.get("end") is not None}
    details = {}
    for key in keys:
        item = by_key.get(key)
        try:
            detail = json.loads(auxiliary[key])
        except (json.JSONDecodeError, TypeError, RecursionError):
            raise AppError("完整资料中的任务比较明细无效。") from None
        if item is None or not validate_detail(detail, item["end"] - item["start"]):
            raise AppError("完整资料中的任务比较明细与会话不匹配。")
        details[item["id"]] = detail
    return details


def load_backup(path: Path) -> dict:
    file = Path(path)
    try:
        size = file.stat().st_size
    except OSError as error:
        raise AppError(f"完整资料校验失败：{error}") from error
    if size > MAX_BYTES:
        raise AppError("无法处理超过 256 MB 的备份文件；原数据保持不变。")
    try:
        raw = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AppError(f"完整资料校验失败：{error}") from error
    return validate_backup(raw)
