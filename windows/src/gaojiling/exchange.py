"""GaoAction V1 的校验与收件箱。

来源声明和 nonce 不是认证。打开页面只表示 pending，不能当成业务完成。
manifest 1MiB，items 与 references 合计 256，载荷声明 2GiB，有效期 120 秒。
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filesafety import atomic_text
from gaojiling.version import BUNDLE_ID

ACTIONS = {"storage.inspect", "cleanup.review", "apps.uninstall.review"}
PAYLOAD_LIMIT = 2 * 1024 * 1024 * 1024
MANIFEST_LIMIT = 1024 * 1024
_BUNDLE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
_SHA = re.compile(r"^[0-9a-f]{64}$")
_ALLOWED = {
    "schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action",
    "createdAt", "expiresAt", "nonce", "items", "references", "parameters", "inReplyTo",
    "status", "errorCode", "provenance",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _parse_time(value: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise AppError("交接目标、标识或有效期无效")
    text = value[:-1]
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise AppError("交接目标、标识或有效期无效")


def _uuid(value: str) -> str:
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, TypeError, AttributeError):
        raise AppError("交接目标、标识或有效期无效") from None


def validate(data: bytes, now: datetime | None = None, provider_only: bool = True) -> dict:
    if len(data) > MANIFEST_LIMIT:
        raise AppError("manifest 超限或无效")
    try:
        raw = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise AppError("manifest 超限或无效") from None
    if not isinstance(raw, dict) or not set(raw).issubset(_ALLOWED):
        raise AppError("manifest 包含未声明字段")
    if raw.get("schemaVersion") != 1:
        raise AppError("不支持此交接版本")
    moment = now or datetime.now(timezone.utc)
    request_id = _uuid(raw.get("requestID"))
    if raw.get("targetBundleID") != BUNDLE_ID or not _BUNDLE.fullmatch(raw.get("sourceBundleID") or "") or not _BUNDLE.fullmatch(raw.get("targetBundleID") or ""):
        raise AppError("交接目标、标识或有效期无效")
    try:
        nonce = base64.b64decode(raw.get("nonce") or "", validate=True)
    except Exception:
        raise AppError("交接目标、标识或有效期无效") from None
    if len(nonce) != 32:
        raise AppError("交接目标、标识或有效期无效")
    created = _parse_time(raw.get("createdAt"))
    expires = _parse_time(raw.get("expiresAt"))
    if created > moment or moment >= expires or expires <= created or (expires - created).total_seconds() > 120.001:
        raise AppError("交接目标、标识或有效期无效")
    action = raw.get("action")
    known = ACTIONS | {"documents.newText", "ocr.files"}
    if action not in (ACTIONS if provider_only else known):
        raise AppError("本版不支持该动作")
    items = raw.get("items") or []
    references = raw.get("references") or []
    if len(items) + len(references) > 256:
        raise AppError("交接项目超限或重复")
    if len({item.get("id") for item in items}) != len(items) or len({item.get("relativePath") for item in items}) != len(items):
        raise AppError("交接项目超限或重复")
    if len({item.get("id") for item in references}) != len(references):
        raise AppError("交接项目超限或重复")
    total = 0
    for item in items:
        _payload_parts(item.get("relativePath") or "")
        if not item.get("id") or not item.get("uti") or not _SHA.fullmatch(item.get("sha256") or ""):
            raise AppError("附件声明无效或载荷超限")
        size = item.get("byteCount")
        if not isinstance(size, int) or size < 0 or size > PAYLOAD_LIMIT - total:
            raise AppError("附件声明无效或载荷超限")
        total += size
    for ref in references:
        if not ref.get("id") or ref.get("kind") not in {"file", "directory", "application"} or len(ref.get("displayName") or "") > 4096:
            raise AppError("引用格式无效")
        _local_url(ref.get("fileURL") or "")
        if ref.get("sha256") is not None and not _SHA.fullmatch(ref["sha256"]):
            raise AppError("引用摘要无效")
    kind = raw.get("kind")
    if kind == "request":
        if any(raw.get(key) is not None for key in ("inReplyTo", "status", "errorCode", "provenance")):
            raise AppError("请求包含结果专用字段")
        parameters = raw.get("parameters") or {}
        if action == "storage.inspect":
            if items or len(references) != 1 or references[0].get("kind") != "directory" or not set(parameters).issubset({"mode"}):
                raise AppError("存储分析只接受一个目录引用")
            mode = parameters.get("mode")
            if mode is not None and mode not in {"metadata", "duplicates"}:
                raise AppError("不支持此存储分析模式")
        elif action == "cleanup.review":
            if items or references or parameters:
                raise AppError("缓存复核不能接受任意路径或参数")
        elif action == "apps.uninstall.review":
            if items or len(references) != 1 or references[0].get("kind") != "application" or parameters:
                raise AppError("卸载复核只接受一个应用引用")
        else:
            raise AppError("本版不支持该动作")
    elif kind == "result":
        if raw.get("inReplyTo") is None or raw.get("status") not in {"pending", "completed", "partial", "cancelled", "failed", "unsupported"}:
            raise AppError("结果缺少关联、状态或来源说明")
        if raw.get("parameters"):
            raise AppError("结果缺少关联、状态或来源说明")
        validate_outcome(action, raw["status"], raw.get("provenance") or {}, raw.get("errorCode"))
    else:
        raise AppError("manifest 超限或无效")
    raw = dict(raw)
    raw["requestID"] = request_id
    return raw


def validate_outcome(action: str, status: str, provenance: dict, error_code: str | None = None):
    if action not in ACTIONS or not isinstance(provenance, dict):
        raise AppError("结果缺少实际流程状态")
    state = provenance.get("workflowState")
    states = {
        "pending": {"awaitingUser", "executing"},
        "completed": {"completed"},
        "partial": {"partial", "reviewedNoChanges"},
        "cancelled": {"cancelled"},
        "failed": {"failed", "interrupted"},
        "unsupported": {"unsupported", "failed"},
    }
    if state not in states.get(status, set()):
        raise AppError("结果状态与流程状态不一致")
    if error_code is not None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", error_code) or status not in {"failed", "unsupported", "partial", "cancelled"}:
            raise AppError("结果错误代码无效")
    if state == "interrupted" and error_code != "interrupted":
        raise AppError("中断结果缺少明确错误代码")
    if status == "pending" and provenance.get("statistics") is not None:
        raise AppError("尚未确认的分析不能附完成统计")
    if action == "storage.inspect":
        if status in {"completed", "partial"} and not (provenance.get("scope") and "complete" in provenance and provenance.get("statistics")):
            raise AppError("已完成或部分分析缺少范围与实际统计")
        if provenance.get("complete") is True and status != "completed":
            raise AppError("存储完整性与结果状态不一致")
    else:
        if status == "completed":
            if not provenance.get("receiptID") or not provenance.get("itemCount"):
                raise AppError("打开复核页或空结果不能冒充维护完成")
        if status == "pending" and (provenance.get("receiptID") or provenance.get("itemCount") is not None):
            raise AppError("等待复核不能附加执行回执")
        if state == "interrupted" and (provenance.get("receiptID") or provenance.get("itemCount") is not None):
            raise AppError("中断不能猜测已执行数量或伪造回执")


def _payload_parts(path: str):
    parts = path.split("/")
    if len(parts) < 2 or parts[0] != "payload" or any(not part or part in {".", ".."} or "\\" in part or "\0" in part for part in parts):
        raise AppError("附件路径越界")
    return parts


def _local_url(text: str):
    if not text.startswith("file://"):
        raise AppError("引用必须为规范化本机 file URL")
    if any(token in text for token in ("?", "#")):
        raise AppError("引用必须为规范化本机 file URL")
    return text


class ExchangeInbox:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.path = self.directory / "inbox.json"
        self.marker = self.directory / "Exchange.initialized"
        self.failure = None
        self.records = []
        self._load()

    def _load(self):
        try:
            if self.directory.exists():
                names = {item.name for item in self.directory.iterdir()}
                allowed = {"inbox.json", "Exchange.initialized"}
                if not names <= allowed and names:
                    # 私有副本目录可以有请求文件夹。只拒绝既没有标记、目录又不空的情况。
                    if not self.marker.exists() and "inbox.json" not in names:
                        raise AppError("交接目录不空但没有初始化标记，已停止。")
            if self.marker.exists() != self.path.exists() and (self.marker.exists() or self.path.exists()):
                if self.path.exists() and not self.marker.exists():
                    raise AppError("交接记录缺少初始化标记，已停止。")
            if not self.path.exists():
                return
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if data.get("version") != 1 or not isinstance(data.get("records"), list):
                raise AppError("版本无法识别")
            self.records = data["records"]
        except (OSError, json.JSONDecodeError, AppError) as error:
            self.failure = AppError(f"交接记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        self.directory.mkdir(parents=True, exist_ok=True)
        if not self.marker.exists():
            self.marker.write_text("initialized\n", encoding="utf-8")
        atomic_text(self.path, json.dumps({"version": 1, "records": self.records}, ensure_ascii=False, indent=2))

    def receive_package(self, path: Path) -> dict:
        folder = Path(path)
        if folder.is_symlink() or folder.suffix.lower() != ".gaoaction":
            raise AppError("请选择 .gaoaction 目录包")
        try:
            names = {item.name for item in folder.iterdir() if not item.is_symlink()}
        except OSError as error:
            raise AppError(f"无法读取交接包：{error}") from error
        if names != {"manifest.json", "payload"}:
            raise AppError("交接包必须由本用户持有且仅含 manifest.json 与 payload")
        payload = folder / "payload"
        if not payload.is_dir() or payload.is_symlink():
            raise AppError("交接包必须由本用户持有且仅含 manifest.json 与 payload")
        data = (folder / "manifest.json").read_bytes()
        return self.receive(data)

    def receive(self, manifest_bytes: bytes, now: datetime | None = None) -> dict:
        if self.failure:
            raise self.failure
        manifest = validate(manifest_bytes, now=now, provider_only=True)
        if manifest["kind"] != "request":
            raise AppError("本提供方仅接收动作请求，结果请交给原发送方")
        digest = sha256(manifest_bytes)
        for record in self.records:
            if record["id"] == manifest["requestID"]:
                if record["digest"] != digest:
                    raise AppError("相同请求 ID 的内容不同，已拒绝")
                return record
        if len(self.records) >= 256:
            raise AppError("幂等记录已达 256 项，暂停接收新请求；旧记录不会自动删除。")
        record = {
            "id": manifest["requestID"],
            "manifest": manifest,
            "digest": digest,
            "phase": "received",
            "outcome": None,
            "opened": False,
        }
        self.records.append(record)
        self._save()
        return record

    def open_request(self, request_id: str) -> dict:
        record = self._record(request_id)
        record["opened"] = True
        if record["phase"] == "received":
            record["phase"] = "reviewing"
        self._save()
        return {"status": "pending", "workflowState": "awaitingUser", "requestID": request_id,
                "message": "已打开复核。这不是业务完成。"}

    def approve(self, request_id: str) -> dict:
        record = self._record(request_id)
        if record["phase"] not in {"received", "reviewing", "approved"}:
            raise AppError("这个请求当前不能批准。")
        record["phase"] = "approved"
        self._save()
        return record

    def finish(self, request_id: str, status: str, provenance: dict, error_code: str | None = None):
        record = self._record(request_id)
        if record["phase"] not in {"approved", "reviewing", "received"}:
            raise AppError("尚未接收的请求不能写出结果。")
        if status == "completed" and record["phase"] != "approved":
            raise AppError("未批准的请求不能报告完成。")
        validate_outcome(record["manifest"]["action"], status, provenance, error_code)
        if status == "completed" and record["manifest"]["action"] != "storage.inspect":
            if not provenance.get("receiptID"):
                raise AppError("实际移动必须关联回执。")
        record["outcome"] = {"status": status, "provenance": provenance, "errorCode": error_code}
        record["phase"] = "result"
        self._save()
        return record

    def _record(self, request_id: str) -> dict:
        if self.failure:
            raise self.failure
        for record in self.records:
            if record["id"] == request_id:
                return record
        raise AppError("没有这条交接请求。")
