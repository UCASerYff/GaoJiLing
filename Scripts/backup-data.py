#!/usr/bin/env python3
"""Private, verified upgrade backup; never put its output in a release package."""
import argparse
import contextlib
import ctypes
import functools
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import time
import uuid

IDENTIFIER = "com.gaoseries.GaoJiLing"
DATA = Path.home() / "Library/Application Support/GaoSeries/GaoJiLing"
BACKUPS = DATA.parent / "GaoJiLing-Backups"
DB_FILES = {"monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"}
# Darwin SDK sys/fcntl.h: O_SEARCH = O_EXEC | O_DIRECTORY. Python does not
# expose O_SEARCH on macOS. This permits exact known Trash paths without listing.
O_SEARCH = 0x40000000 | os.O_DIRECTORY
DATALESS = getattr(stat, "SF_DATALESS", 0x40000000)
UNINSTALL_MARKER = b"GaoJiLing.UninstallJournal.v1\n"

def extended_attributes(fd, output=None):
    # Darwin provides these fd variants; this Python build has no os.*xattr.
    system = ctypes.CDLL(None, use_errno=True)
    system.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    system.flistxattr.restype = ctypes.c_ssize_t
    system.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    system.fgetxattr.restype = ctypes.c_ssize_t
    system.fsetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    def sized(call):
        length = call(None, 0)
        if length < 0: raise OSError(ctypes.get_errno(), "无法读取扩展属性")
        if length > 16 * 1024 * 1024: raise RuntimeError("扩展属性超过备份预算")
        buffer = ctypes.create_string_buffer(length or 1)
        actual = call(buffer, length)
        if actual != length: raise RuntimeError("扩展属性在读取时变化")
        return buffer.raw[:length]
    names = sized(lambda buffer, count: system.flistxattr(fd, buffer, count, 0))
    result = {}
    for name in names.split(b"\0"):
        if not name: continue
        value = sized(lambda buffer, count: system.fgetxattr(fd, name, buffer, count, 0, 0))
        result[os.fsdecode(name)] = hashlib.sha256(value).hexdigest()
        if output is not None and system.fsetxattr(output, name, value, len(value), 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "无法保存扩展属性")
    return result

def no_materialization(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        system = ctypes.CDLL(None, use_errno=True)
        previous = system.getiopolicy_np(3, 1)
        if previous < 0 or system.setiopolicy_np(3, 1, 1) != 0:
            raise RuntimeError("无法禁止云占位文件下载，停止备份")
        try:
            return function(*args, **kwargs)
        finally:
            if system.setiopolicy_np(3, 1, previous) != 0:
                raise RuntimeError("无法恢复文件访问策略，备份未确认")
    return wrapped

def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_flags)

def checked_stat(name, fd):
    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if info.st_flags & DATALESS: raise RuntimeError("云端占位文件不可备份，未触发下载")
    return info

@contextlib.contextmanager
def directory_fd(path, read=False):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise RuntimeError("备份路径不是规范绝对路径")
    fd = os.open("/", O_SEARCH | os.O_NOFOLLOW)
    try:
        for index, part in enumerate(path.parts[1:]):
            before = checked_stat(part, fd)
            if not stat.S_ISDIR(before.st_mode): raise RuntimeError("父路径含链接或特殊文件")
            flags = os.O_RDONLY | os.O_DIRECTORY if read and index == len(path.parts) - 2 else O_SEARCH
            child = os.open(part, flags | os.O_NOFOLLOW, dir_fd=fd)
            after = os.fstat(child)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino) or after.st_flags & DATALESS:
                os.close(child); raise RuntimeError("父目录在打开时被替换")
            os.close(fd); fd = child
        yield fd
    finally:
        os.close(fd)

def safe_lstat(path):
    path = Path(path)
    with directory_fd(path.parent) as fd: return checked_stat(path.name, fd)

def optional_stat(path):
    try: return safe_lstat(path)
    except FileNotFoundError: return None

def read_regular(path, limit=None):
    path = Path(path)
    with directory_fd(path.parent) as parent:
        before = checked_stat(path.name, parent)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise RuntimeError("文件不是独立普通文件")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            if signature(before) != signature(os.fstat(fd)): raise RuntimeError("文件在打开时改变")
            data = bytearray()
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk: break
                data.extend(chunk)
                if limit is not None and len(data) > limit: raise RuntimeError("记录超过允许大小")
            if signature(before) != signature(os.fstat(fd)) or len(data) != before.st_size:
                raise RuntimeError("文件在读取时改变")
            return bytes(data)
        finally: os.close(fd)

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()

def file_digest(path):
    return tree_manifest(Path(path))[""]["sha256"]

def tree_manifest(path, allow_links=False, copy_to=None, exclude=()):
    """Bounded nofollow walk. Regular data is copied through pinned FDs;
    app framework links are copied as link text, never as their target contents.
    """
    path = Path(path); result = {}; count = 0
    root_info = safe_lstat(path)
    if stat.S_ISLNK(root_info.st_mode): raise RuntimeError("恢复根项目不能是链接")
    def walk(parent, name, relative, target):
        nonlocal count
        count += 1
        if count > 1_000_000 or len(Path(relative).parts) > 64: raise RuntimeError("备份树超过安全预算，未标记完成")
        before = checked_stat(name, parent)
        if before.st_dev != root_info.st_dev or before.st_uid not in (0, os.getuid()):
            raise RuntimeError("备份树跨卷或含其他用户的文件")
        mode = stat.S_IMODE(before.st_mode)
        if stat.S_ISLNK(before.st_mode):
            if not allow_links or not relative: raise RuntimeError("资料含链接，不能跟随备份")
            text = os.readlink(name, dir_fd=parent)
            if signature(before) != signature(checked_stat(name, parent)): raise RuntimeError("链接在读取时改变")
            result[relative] = {"type": "link", "target": text}
            if target is not None: os.symlink(text, target)
            return
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                if signature(before) != signature(os.fstat(fd)): raise RuntimeError("目录在打开时改变")
                if target is not None: target.mkdir(mode=0o700)
                with contextlib.ExitStack() as stack:
                    output = stack.enter_context(directory_fd(target)) if target is not None else None
                    attributes = extended_attributes(fd, output)
                result[relative] = {"type": "directory", "mode": mode, "xattrs": attributes}
                for child in sorted(os.listdir(fd)):
                    if not relative and child in exclude: continue
                    walk(fd, child, str(Path(relative) / child) if relative else child, target / child if target is not None else None)
                if signature(before) != signature(os.fstat(fd)): raise RuntimeError("目录在备份时改变")
                if target is not None:
                    os.chmod(target, mode); os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
            finally: os.close(fd)
            return
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise RuntimeError("资料含硬链接或特殊文件")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        out = None
        try:
            if signature(before) != signature(os.fstat(fd)): raise RuntimeError("文件在打开时改变")
            if target is not None: out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            checksum = hashlib.sha256(); size = 0
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk: break
                checksum.update(chunk); size += len(chunk)
                if out is not None:
                    offset = 0
                    while offset < len(chunk):
                        wrote = os.write(out, chunk[offset:])
                        if wrote <= 0: raise RuntimeError("备份文件未完整写入")
                        offset += wrote
            attributes = extended_attributes(fd, out)
            if signature(before) != signature(os.fstat(fd)) or size != before.st_size:
                raise RuntimeError("文件在备份期间改变")
            result[relative] = {"type": "file", "mode": mode, "sha256": checksum.hexdigest(), "xattrs": attributes}
            if out is not None:
                os.fchmod(out, mode); os.utime(out, ns=(before.st_atime_ns, before.st_mtime_ns)); os.fsync(out)
        finally:
            if out is not None: os.close(out)
            os.close(fd)
    with directory_fd(path.parent) as parent:
        walk(parent, path.name, "", Path(copy_to) if copy_to is not None else None)
    return result

def row_digest(row, columns):
    normalized = list(row)
    if "payload" in columns:
        index = columns.index("payload")
        try: normalized[index] = json.loads(normalized[index])
        except (ValueError, TypeError): pass
    return digest(normalized)

def manifest(directory, exclude=()):
    if not stat.S_ISDIR(safe_lstat(directory).st_mode):
        raise RuntimeError("资料目录不存在或不是普通目录；不会按空资料覆盖")
    result = tree_manifest(directory, exclude=exclude)
    return {name: value["sha256"] for name, value in result.items() if value["type"] == "file" and name not in exclude}

def records(directory):
    file = directory / "monitor.sqlite"
    before = optional_stat(file)
    if before is None or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid():
        raise RuntimeError("原数据库缺失，未创建空数据库或覆盖资料")
    for name in ("monitor.sqlite-wal", "monitor.sqlite-shm"):
        sidecar = optional_stat(directory / name)
        if sidecar is not None and (not stat.S_ISREG(sidecar.st_mode) or sidecar.st_nlink != 1 or sidecar.st_uid != os.getuid()):
            raise RuntimeError("数据库事务文件不是当前用户的独立普通文件")
    db = sqlite3.connect(file.as_uri() + "?mode=ro", uri=True)
    try:
        db.execute("BEGIN")
        if db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("数据库完整性检查失败，未继续安装")
        tables = {}
        for name in ("samples", "events", "sessions", "preferences"):
            columns = [row[1] for row in db.execute("PRAGMA table_info(" + name + ")")]
            if not columns:
                raise RuntimeError("数据库结构缺失，未作为空资料处理")
            tables[name] = {}
            for row in db.execute("SELECT * FROM " + name):
                result = {"digest": row_digest(row, columns), "time": row[columns.index("t")] if "t" in columns else None}
                if name == "sessions":
                    payload = json.loads(row[columns.index("payload")])
                    if isinstance(payload, dict) and "start" in payload and payload.get("end") is None:
                        # Match the app's documented interrupted-task recovery only.
                        observed = payload.get("lastObserved")
                        if observed is None:
                            sample = db.execute("SELECT t FROM samples WHERE t>=? ORDER BY t DESC LIMIT 1", (payload["start"] + 978307200,)).fetchone()
                            observed = sample[0] - 978307200 if sample else payload["start"]
                        expected = dict(payload, end=max(payload["start"], observed), interrupted=True)
                        alternate = list(row); alternate[columns.index("payload")] = json.dumps(expected)
                        result["interruptedDigest"] = row_digest(alternate, columns)
                tables[name][str(row[0])] = result
        setting = db.execute("SELECT payload FROM preferences WHERE id=1").fetchone()
        retention = json.loads(setting[0]).get("retentionDays", 7) if setting else 7
        schema = digest(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall())
        after = safe_lstat(file)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("数据库在核验期间被替换")
        return {"tables": tables, "retention": retention, "schema": schema}
    finally:
        db.rollback()
        db.close()

def defaults():
    data = subprocess.check_output(["defaults", "export", IDENTIFIER, "-"], stderr=subprocess.DEVNULL)
    plistlib.loads(data)  # Fail on unreadable or malformed preferences.
    return data

def object_manifest(path):
    if path.is_symlink(): raise RuntimeError("恢复项目不能是链接")
    if path.is_dir(): return manifest(path)
    if path.is_file(): return {"": file_digest(path)}
    raise RuntimeError("恢复项目不是普通文件或目录")

def validated_state(source, relative, key, marker=None, marker_content=None, maximum=16 * 1024 * 1024):
    path = source / relative
    marked = marker is not None and optional_stat(source / marker) is not None
    if marked:
        marker_info = safe_lstat(source / marker)
        if marker_info.st_uid != os.getuid() or marker_info.st_mode & 0o077 or read_regular(source / marker, 128) != marker_content:
            raise RuntimeError("初始化标记损坏或权限异常，停止升级")
    if optional_stat(path) is None:
        if marked: raise RuntimeError("已初始化的状态记录丢失，停止升级")
        return None
    info = safe_lstat(path)
    if info.st_uid != os.getuid() or info.st_mode & 0o077: raise RuntimeError("状态文件归属或私有权限异常")
    value = json.loads(read_regular(path, maximum))
    if not isinstance(value, dict) or type(value.get(key)) is not int or value[key] != 1:
        raise RuntimeError("状态记录损坏或版本不受支持，停止升级")
    return value

def storage_state(value):
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1:
        raise RuntimeError("存储分析记录版本无效")
    exclusions, history = value.get("exclusions"), value.get("history")
    if not isinstance(exclusions, list) or len(exclusions) > 256 or not isinstance(history, list) or len(history) > 30:
        raise RuntimeError("存储分析资料结构不完整")
    for path in exclusions: absolute_path(path)
    identifiers = set()
    for item in history:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not 0 < len(item["id"].encode()) <= 256 or item["id"] in identifiers:
            raise RuntimeError("存储分析历史标识无效")
        if type(item.get("date")) not in (int, float) or not math.isfinite(item["date"]) or type(item.get("totalBytes")) is not int or item["totalBytes"] < 0 or type(item.get("complete")) is not bool:
            raise RuntimeError("存储分析历史内容无效")
        if item.get("scope") != "开发环境": absolute_path(item.get("scope"))
        identifiers.add(item["id"])
    return value

def verify_storage_history(previous, current, earliest):
    previous, current = storage_state(previous), storage_state(current)
    if {k: v for k, v in previous.items() if k != "history"} != {k: v for k, v in current.items() if k != "history"}:
        raise RuntimeError("原存储分析设置或未知字段改变")
    old = previous["history"]; new = current["history"]
    known = {item["id"] for item in old}
    added = [item for item in new if item["id"] not in known]
    if new != (old + added)[-30:]: raise RuntimeError("原存储分析历史被覆盖或非正常淘汰")
    latest = max([earliest - 978307200] + [item["date"] for item in old])
    for item in added:
        if set(item) != {"id", "date", "totalBytes", "scope", "complete"} or not latest <= item["date"] <= time.time() - 978307200 + 5:
            raise RuntimeError("新增存储分析历史时间或格式无效")
        latest = item["date"]

def application_path(path, home):
    roots = (Path("/Applications"), home / "Applications")
    return path.suffix == ".app" and any(path.is_relative_to(root) and path != root for root in roots) and not any(p.endswith(".app") for p in path.parts[:-1])

def absolute_path(value):
    if not isinstance(value, str) or not value.startswith("/") or "\0" in value:
        raise RuntimeError("恢复记录路径无效")
    path = Path(value)
    if ".." in path.parts or str(path) != value: raise RuntimeError("恢复路径未规范化")
    return path

def original_allowed(receipt, app, home):
    original = absolute_path(receipt["original"])
    owner = receipt["owner"]
    if not isinstance(owner, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", owner):
        raise RuntimeError("恢复归属标识无效")
    if owner.startswith("com.gaoseries."): raise RuntimeError("不能处理搞系列恢复路径")
    if app is not None:
        if owner != app["bundleID"] or owner.startswith("com.apple.") or owner == "cn.mendao.launcher":
            raise RuntimeError("受保护应用不能作为卸载实物")
        app_path = absolute_path(app["path"])
        if not application_path(app_path, home) or app_path.name.startswith("搞"):
            raise RuntimeError("卸载应用路径不在允许范围")
        if receipt["itemKind"] == "application":
            if original != app_path or receipt["footprint"]["identity"] != app["identity"]:
                raise RuntimeError("卸载应用身份与批次不符")
            return original, True
        if receipt["itemKind"] != "cache": raise RuntimeError("未知卸载项目类型")
        valid = original == home / "Library/Caches" / owner
    else:
        category = receipt["category"]
        if category == "应用缓存": valid = original == home / "Library/Caches" / owner
        elif category == "旧轮转日志":
            valid = original.parent == home / "Library/Logs" / owner and re.search(r"\.log\.[A-Za-z0-9_-]+(?:\.gz)?$", original.name) is not None
        elif category == "开发工具缓存":
            rules = {"developer.npm": ".npm/_cacache", "developer.pip": "Library/Caches/pip", "developer.pypoetry": "Library/Caches/pypoetry", "developer.homebrew": "Library/Caches/Homebrew", "developer.gradle": ".gradle/caches"}
            valid = owner in rules and original == home / rules[owner]
        elif category == "Xcode 构建":
            derived = home / "Library/Developer/Xcode/DerivedData"
            parts = original.relative_to(derived).parts if original.is_relative_to(derived) else ()
            valid = owner == "com.apple.dt.Xcode" and ((len(parts) == 1 and parts[0] in ("ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex")) or (len(parts) == 3 and parts[1] == "Build" and parts[2] in ("Intermediates.noindex", "Products")))
        else: valid = False
    if not valid: raise RuntimeError("恢复原路径不在对应引擎白名单")
    return original, False

def validated_identity(value, uid_required=False):
    keys = ("device", "inode", "kind", "uid") if uid_required else ("device", "inode", "kind")
    if not isinstance(value, dict) or any(type(value.get(key)) is not int or value[key] < 0 for key in keys):
        raise RuntimeError("恢复项目身份格式无效")
    if value["kind"] not in (stat.S_IFREG, stat.S_IFDIR): raise RuntimeError("恢复项目身份类型无效")

def validated_receipt_shape(receipt, uninstall):
    if not isinstance(receipt, dict): raise RuntimeError("恢复项目格式无效")
    uuid.UUID(receipt["id"]); uuid.UUID(receipt["itemID"])
    footprint = receipt["footprint"]
    if not isinstance(footprint, dict) or type(footprint.get("bytes")) is not int or footprint["bytes"] < 0 or type(footprint.get("entries")) is not int or footprint["entries"] <= 0 or type(footprint.get("newest")) not in (int, float) or not math.isfinite(footprint["newest"]) or not isinstance(footprint.get("digest"), str) or not re.fullmatch(r"[0-9a-f]{64}", footprint["digest"]):
        raise RuntimeError("恢复项目快照格式无效")
    validated_identity(footprint["identity"], uid_required=uninstall)
    if uninstall:
        validated_identity(receipt["parentIdentity"], uid_required=True)
        if footprint["identity"]["kind"] != stat.S_IFDIR or receipt["parentIdentity"]["kind"] != stat.S_IFDIR or receipt["parentIdentity"]["device"] != footprint["identity"]["device"]:
            raise RuntimeError("卸载原父目录身份无效")

@no_materialization
def recovery_objects(source, home):
    """Every pending receipt must resolve to an identity-checked entity.
    Missing data is a blocking error, never an empty successful backup.
    """
    source, home = Path(source), Path(home)
    objects = {}
    storage = validated_state(source, "Storage/analysis-state.json", "version", "Storage.initialized", b"GaoJiLing.StorageAnalysis.1\n")
    if storage is not None: storage_state(storage)
    exchange = validated_state(source, "Exchange/inbox.json", "version", "Exchange.initialized", b"GaoActionInboxV1\n")
    if exchange is not None and (not isinstance(exchange.get("records"), list) or len(exchange["records"]) > 256):
        raise RuntimeError("交接记录内容无效")
    maintenance = validated_state(source, "Maintenance/state.json", "schemaVersion", "Maintenance.initialized", b"GaoJiLing.Maintenance.v1\n", maximum=1_048_576)
    if optional_stat(source / "Maintenance") is not None and maintenance is None:
        raise RuntimeError("维护资料目录存在但状态文件丢失，停止升级")
    if maintenance is not None:
        required = {"appExitEnabled": bool, "appExitPaused": bool, "rules": list, "protectedBundleIDs": list,
                    "batteryRule": dict, "visibleMetricIDs": list, "records": list}
        if any(type(maintenance.get(k)) is not v for k, v in required.items()): raise RuntimeError("维护资料结构不完整")
    for module, prefix in (("Cleanup", "GaoJiLing-"), ("Uninstall", "GaoJiLing-Uninstall-")):
        ledger = validated_state(source, module + "/journal.json", "version",
            "Uninstall.initialized" if module == "Uninstall" else None,
            UNINSTALL_MARKER if module == "Uninstall" else None)
        stage_root = home / ("Library/Caches/.GaoJiLing-" + module + "Stage")
        if ledger is None:
            if optional_stat(stage_root) is not None:
                with directory_fd(stage_root, read=True) as fd:
                    if os.listdir(fd): raise RuntimeError("恢复记录缺失但存在暂存实物，停止升级")
            continue
        if not isinstance(ledger.get("batches"), list): raise RuntimeError("恢复记录批次格式无效")
        receipt_ids, batch_ids = set(), set()
        for batch in ledger["batches"]:
            batch_id = str(uuid.UUID(batch["id"]))
            if batch_id in batch_ids: raise RuntimeError("恢复批次 UUID 重复")
            batch_ids.add(batch_id)
            if batch.get("date") is not None and (type(batch["date"]) not in (int, float) or not math.isfinite(batch["date"])):
                raise RuntimeError("恢复批次日期无效")
            if not isinstance(batch.get("receipts"), list): raise RuntimeError("恢复批次项目格式无效")
            app = batch.get("app") if module == "Uninstall" else None
            if module == "Uninstall" and not isinstance(app, dict): raise RuntimeError("卸载批次缺少应用身份")
            if app is not None:
                validated_identity(app.get("identity"), uid_required=True)
                if batch.get("date") is None or not all(isinstance(app.get(key), str) for key in ("path", "name", "bundleID", "version", "metadataHash")) or not re.fullmatch(r"[0-9a-f]{64}", app["metadataHash"]) or app.get("protectedReason") is not None or app.get("vendorUninstallReason") is not None:
                    raise RuntimeError("卸载应用记录损坏")
            for receipt in batch["receipts"]:
                validated_receipt_shape(receipt, module == "Uninstall")
                identifier = str(uuid.UUID(receipt["id"])).upper()
                if identifier in receipt_ids: raise RuntimeError("恢复项目 UUID 重复")
                receipt_ids.add(identifier)
                name = prefix + identifier
                stage = absolute_path(receipt["stage"])
                if stage != stage_root / name: raise RuntimeError("恢复暂存路径无效")
                original, allow_links = original_allowed(receipt, app, home)
                if receipt["state"] in ("restored", "untouched"): continue
                if receipt["state"] not in ("prepared", "staged", "trashing", "trashed"):
                    raise RuntimeError("恢复状态无效，停止升级")
                identity = receipt["footprint"]["identity"]
                expected_uid = identity.get("uid", os.getuid())
                if expected_uid not in ((0, os.getuid()) if allow_links else (os.getuid(),)):
                    raise RuntimeError("恢复项目所有者不受支持")
                if any(type(identity.get(key)) is not int or identity[key] < 0 for key in ("device", "inode")):
                    raise RuntimeError("恢复项目身份无效")
                paths = [stage]
                if receipt.get("trash"):
                    trash = absolute_path(receipt["trash"])
                    per_volume = trash.parent.name == str(os.getuid()) and trash.parent.parent.name == ".Trashes"
                    if (trash.parent != home / ".Trash" and not per_volume) or not trash.name.startswith(name):
                        raise RuntimeError("恢复废纸篓位置无效")
                    paths.append(trash)
                # All states allow the original only when its exact identity is
                # still there (crash after rollback/restore before journal save).
                matches = []
                for path in paths:
                    info = optional_stat(path)
                    if info is None: continue
                    if info.st_dev != identity["device"] or info.st_ino != identity["inode"] or info.st_uid != expected_uid:
                        raise RuntimeError("恢复实物身份改变，停止升级")
                    matches.append((path, info))
                if not matches:
                    info = optional_stat(original)
                    if info is not None and (info.st_dev, info.st_ino, info.st_uid) == (identity["device"], identity["inode"], expected_uid):
                        matches.append((original, info))
                if not matches:
                    if module == "Cleanup":
                        continue
                    raise RuntimeError("待恢复实物缺失或原路径冲突；请先在应用内恢复/核对 Finder 废纸篓，未标记备份完成")
                if len(matches) != 1: raise RuntimeError("恢复实物出现多个位置，停止升级")
                path, info = matches[0]
                if stat.S_ISLNK(info.st_mode) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                    raise RuntimeError("恢复根实物类型无效")
                if module == "Uninstall" and not stat.S_ISDIR(info.st_mode): raise RuntimeError("卸载恢复实物不是目录")
                if info.st_dev != safe_lstat(home).st_dev: raise RuntimeError("恢复项目不在当前用户暂存区所在卷")
                objects[str(path)] = {"format": 2, "allowLinks": allow_links, "identity": {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid},
                                      "tree": tree_manifest(path, allow_links=allow_links)}
    return objects

def sqlite_snapshot(source, destination):
    original = source / "monitor.sqlite"
    before = safe_lstat(original)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1: raise RuntimeError("数据库不是独立普通文件")
    with contextlib.closing(sqlite3.connect(original.as_uri() + "?mode=ro", uri=True)) as incoming:
        with contextlib.closing(sqlite3.connect(destination / "monitor.sqlite")) as outgoing:
            incoming.backup(outgoing)
            if outgoing.execute("PRAGMA quick_check").fetchone()[0] != "ok": raise RuntimeError("数据库快照核验失败")
            outgoing.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            outgoing.execute("PRAGMA journal_mode=DELETE")
    after = safe_lstat(original)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError("数据库在快照期间被替换")
    os.chmod(destination / "monitor.sqlite", 0o600)
    with directory_fd(destination) as parent:
        fd = os.open("monitor.sqlite", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        try: os.fsync(fd); os.fsync(parent)
        finally: os.close(fd)

@no_materialization
def make_backup(source, destination, preferences, home=None):
    started_at = time.time()
    plistlib.loads(preferences)
    baseline = records(source)
    before = manifest(source, exclude=DB_FILES)
    recovery = recovery_objects(source, home or Path.home())
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    data_tree = tree_manifest(source, exclude=DB_FILES)
    copied_tree = tree_manifest(source, copy_to=destination / "Data", exclude=DB_FILES)
    sqlite_snapshot(source, destination / "Data")
    if copied_tree != data_tree or tree_manifest(source, exclude=DB_FILES) != data_tree or tree_manifest(destination / "Data", exclude=DB_FILES) != data_tree:
        raise RuntimeError("备份期间资料变化或校验失败，保留原资料和备份，停止安装")
    if records(destination / "Data") != baseline or records(source) != baseline:
        raise RuntimeError("备份数据库摘要不一致，停止安装")
    for name, content in recovery.items():
        path = Path(name)
        target = destination / "RecoveryObjects" / hashlib.sha256(name.encode()).hexdigest()
        target.parent.mkdir(mode=0o700, exist_ok=True)
        copied = tree_manifest(path, allow_links=content["allowLinks"], copy_to=target)
        if copied != content["tree"] or tree_manifest(path, allow_links=content["allowLinks"]) != content["tree"] or tree_manifest(target, allow_links=content["allowLinks"]) != content["tree"]:
            raise RuntimeError("清理恢复实物备份校验失败，停止安装")
    if manifest(source, exclude=DB_FILES) != before or recovery_objects(source, home or Path.home()) != recovery:
        raise RuntimeError("资料或恢复记录在备份期间变化，停止安装")
    (destination / "preferences.plist").write_bytes(preferences)
    (destination / "baseline.json").write_text(json.dumps({"data": baseline, "files": before, "recovery": recovery, "startedAt": started_at}, ensure_ascii=False))
    for path in destination.iterdir():
        if path.is_file():
            path.chmod(0o600)
    (destination / "VERIFIED").write_text("Complete data, attachments, database integrity and preferences verified.\n")
    (destination / "VERIFIED").chmod(0o600)
    return destination

@no_materialization
def verify_update(backup, source, preferences):
    if not (backup / "VERIFIED").is_file():
        raise RuntimeError("未找到已核验备份，停止清理旧程序")
    old = json.loads((backup / "baseline.json").read_text())
    current = records(source)
    baseline = old["data"]
    if current["schema"] != baseline["schema"] or current["retention"] != baseline["retention"]:
        raise RuntimeError("资料结构或保留设置发生意外变化")
    now = time.time()
    cutoff = now - max(1, min(30, baseline["retention"])) * 86400
    yesterday = now - 86400
    minima = {}
    for row in baseline["tables"]["samples"].values():
        stamp = row["time"]
        if cutoff <= stamp < yesterday:
            minute = int(stamp / 60)
            minima[minute] = min(minima.get(minute, stamp), stamp)
    for name, rows in baseline["tables"].items():
        for key, row in rows.items():
            stamp = row["time"]
            if name in ("samples", "events") and stamp < cutoff:
                continue
            if name == "samples" and stamp < yesterday and minima[int(stamp / 60)] != stamp:
                continue
            accepted = [row["digest"]]
            if name == "sessions" and "interruptedDigest" in row: accepted.append(row["interruptedDigest"])
            if current["tables"][name].get(key, {}).get("digest") not in accepted:
                raise RuntimeError("原历史、任务或设置未通过保留核验")
    for name, checksum in old["files"].items():
        if name in ("monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"):
            continue  # SQLite is validated by rows while new observations are appended.
        file = source / name
        if name == "Storage/analysis-state.json" and file_digest(file) != checksum:
            prior = read_regular(backup / "Data" / name, 16 * 1024 * 1024)
            if hashlib.sha256(prior).hexdigest() != checksum: raise RuntimeError("原存储分析备份未通过摘要校验")
            verify_storage_history(json.loads(prior), json.loads(read_regular(file, 16 * 1024 * 1024)),
                                   old.get("startedAt", (backup / "VERIFIED").stat().st_mtime))
            continue
        if not file.is_file() or file.is_symlink() or file_digest(file) != checksum:
            raise RuntimeError("原附件或恢复资料未通过保留核验")
    for name, content in old.get("recovery", {}).items():
        if content.get("format") == 2:
            info = safe_lstat(Path(name)); identity = content["identity"]
            valid = (info.st_dev, info.st_ino, info.st_uid) == (identity["device"], identity["inode"], identity["uid"])
            valid = valid and tree_manifest(Path(name), allow_links=content["allowLinks"]) == content["tree"]
        else: valid = object_manifest(Path(name)) == content  # pre-V1.10 backups
        if not valid:
            raise RuntimeError("原清理恢复实物未通过保留核验")
    previous = plistlib.loads((backup / "preferences.plist").read_bytes())
    current_defaults = plistlib.loads(preferences)
    for key, value in previous.items():
        if key.startswith("GaoJiLing.EdgeHandle.") and current_defaults.get(key) != value:
            raise RuntimeError("原唤起条设置未通过保留核验")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-version")
    parser.add_argument("--to-version")
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        verify_update(args.verify, DATA, defaults())
        print("PASS: 原资料、全部附件、历史、任务、设置与数据库完整性核验通过；安全备份保留。")
    else:
        if subprocess.run(["pgrep", "-x", "GaoJiLing"], stdout=subprocess.DEVNULL).returncode == 0:
            raise RuntimeError("请先正常退出搞机灵，再建立稳定备份")
        if not args.from_version or not args.to_version:
            parser.error("缺少更新前后版本")
        if not all(re.fullmatch(r"[0-9]+\.[0-9]{2}", version) for version in (args.from_version, args.to_version)):
            parser.error("版本必须为 1.00 格式")
        BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
        if BACKUPS.is_symlink():
            raise RuntimeError("备份目录不能是符号链接")
        name = "V" + args.from_version + "-before-V" + args.to_version + "-" + time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(3).hex()
        target = make_backup(DATA, BACKUPS / name, defaults())
        print(str(target))

if __name__ == "__main__":
    main()
