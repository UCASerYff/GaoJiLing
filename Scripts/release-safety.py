#!/usr/bin/env python3
"""Private program rollback archives and narrowly scoped installation evidence.

This does not restore user data, modify the Keychain, or reset system registries.
Archive operations reuse the existing nofollow backup-tree verifier unchanged.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

IDENTIFIER = "com.gaoseries.GaoJiLing"
DESTINATION = Path("/Applications/搞机灵.app")
LEGACY_PATHS = ("/Applications/.GaoJiLing-install.app", "/Applications/.GaoJiLing-previous.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gaojiling_backup_tree", HERE / "backup-data.py")
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


def noindex_parent(path):
    """Resolve ancestors, so a .noindex symlink cannot disguise indexed output."""
    path = Path(path).absolute()
    return any(part.name.endswith(".noindex") for part in path.parent.resolve().parents) or path.parent.resolve().name.endswith(".noindex")


def require_noindex(path):
    if not noindex_parent(path):
        raise RuntimeError("展开程序必须位于真实的 .noindex 容器内")


def info(path):
    path = Path(path)
    if not stat.S_ISDIR(backup.safe_lstat(path).st_mode):
        raise RuntimeError("程序不是普通目录")
    value = plistlib.loads(backup.read_regular(path / "Contents/Info.plist", 1024 * 1024))
    if value.get("CFBundleIdentifier") != IDENTIFIER:
        raise RuntimeError("程序 Bundle ID 不符")
    return value


def app_identity(path):
    value = backup.safe_lstat(path)
    if not stat.S_ISDIR(value.st_mode):
        raise RuntimeError("程序身份不是普通目录")
    return ":".join(str(number) for number in (value.st_dev, value.st_ino, value.st_uid))


class ProcessBSDInfo(ctypes.Structure):
    # Darwin sys/proc_info.h, PROC_PIDTBSDINFO (3), macOS 14+.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("startedSeconds", ctypes.c_uint64), ("startedMicroseconds", ctypes.c_uint64)]


def process_snapshot(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    details, path = ProcessBSDInfo(), ctypes.create_string_buffer(4096)
    size = ctypes.sizeof(details)
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(details), size) != size or library.proc_pidpath(pid, path, len(path)) <= 0:
        try:
            os.kill(pid, 0)  # Existence query only; never send a signal here.
        except ProcessLookupError:
            return None
        raise RuntimeError("无法核验同名进程的启动身份与路径，未发送退出信号")
    return (details.pid, details.uid, details.startedSeconds, details.startedMicroseconds, os.fsdecode(path.value))


def named_process_ids():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "GaoJiLing"], capture_output=True)
    if result.returncode not in (0, 1):
        raise RuntimeError("无法枚举本应用进程，停止安装")
    values = result.stdout.split()
    if len(values) > 4096 or any(not value.isdigit() or int(value) <= 0 for value in values):
        raise RuntimeError("同名进程列表无效")
    return sorted({int(value) for value in values})


def matching_program_processes(inspect=process_snapshot, candidates=named_process_ids, uid=None):
    owner = os.getuid() if uid is None else uid
    executable = str(DESTINATION / "Contents/MacOS/GaoJiLing")
    result = []
    for pid in candidates():
        value = inspect(pid)
        if value is not None and value[0] == pid and value[1] == owner and value[4] == executable:
            result.append(value)
    return result


def stop_program(inspect=process_snapshot, candidates=named_process_ids, send=os.kill,
                 now=time.monotonic, wait=time.sleep, uid=None, timeout=4.0):
    """Normal TERM only, after PID/start/UID and the official executable match.

    Other bundles with the same executable name never receive a signal. PID
    identity is checked again immediately before TERM and throughout waiting.
    """
    def matching():
        return matching_program_processes(inspect, candidates, uid)
    selected = matching()
    for value in selected:
        observed = inspect(value[0])
        if observed is None:
            continue
        if observed != value:
            raise RuntimeError("退出前进程身份改变，未发送退出信号")
        try:
            send(value[0], signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = now() + timeout
    while any(inspect(value[0]) == value for value in selected):
        if now() >= deadline:
            raise RuntimeError("本应用仍在退出，未强杀；原程序、资料和安全备份保留")
        wait(0.2)
    if matching():
        raise RuntimeError("退出期间本应用重新启动，停止替换；未退出新进程")


def write_json(path, value):
    path = Path(path)
    # Receipts and audits are private and never replace an existing pointer.
    with path.open("x", encoding="utf-8") as output:
        os.chmod(path, 0o600)
        json.dump(value, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    with backup.directory_fd(path.parent, read=True) as parent:
        os.fsync(parent)


def signature_valid(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)


def write_private(path, raw):
    with Path(path).open("xb") as output:
        os.chmod(path, 0o600)
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    with backup.directory_fd(Path(path).parent, read=True) as parent:
        os.fsync(parent)


def only_root_macl_missing(expected, restored):
    """A narrow diagnostic, never permission to discard/recreate this attribute."""
    if expected.keys() != restored.keys() or "" not in expected:
        return False
    if any(expected[name] != restored[name] for name in expected if name):
        return False
    root = expected[""]
    attributes = root.get("xattrs")
    other = restored[""].get("xattrs")
    if root.get("type") != "directory" or not isinstance(attributes, dict) or not isinstance(other, dict):
        return False
    if "com.apple.macl" not in attributes or "com.apple.macl" in other:
        return False
    reduced = dict(root)
    reduced["xattrs"] = {name: value for name, value in attributes.items() if name != "com.apple.macl"}
    return reduced == restored[""]


def original_metadata(app, manifest):
    # Same inodes are retained, rather than rebuilding ACLs or system metadata.
    # tree_manifest separately checks all content, links, modes and xattrs.
    # Rename necessarily changes the root ctime; neither times nor attributes
    # are written back to make a moved object appear unchanged.
    result = {}
    for relative in manifest:
        value = backup.safe_lstat(Path(app) / relative)
        result[relative] = {"device": value.st_dev, "inode": value.st_ino,
                            "uid": value.st_uid, "gid": value.st_gid,
                            "mode": value.st_mode, "flags": value.st_flags,
                            "nlink": value.st_nlink, "size": value.st_size,
                            "mtimeNs": value.st_mtime_ns}
    return result


def container_metadata(value):
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or stat.S_IMODE(value.st_mode) != 0o700:
        raise RuntimeError("原件容器必须是当前用户拥有的真实 0700 目录")
    return {"device": value.st_dev, "inode": value.st_ino,
            "uid": value.st_uid, "gid": value.st_gid, "mode": stat.S_IMODE(value.st_mode)}


def original_container(path):
    return container_metadata(backup.safe_lstat(path))


def move_program(app, output, expected_identity, *, source_parent=None, target_parent=None):
    """Same-volume, no-replace rename. Never merge/overwrite an unknown app."""
    app, output = Path(app).absolute(), Path(output).absolute()
    if not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", expected_identity) or app_identity(app) != expected_identity:
        raise RuntimeError("移动前程序身份不符，保留原件")
    if output != DESTINATION:
        require_noindex(output)
    with backup.directory_fd(app.parent, read=True) as source, backup.directory_fd(output.parent, read=True) as target:
        if ((source_parent is not None and container_metadata(os.fstat(source)) != source_parent)
                or (target_parent is not None and container_metadata(os.fstat(target)) != target_parent)):
            raise RuntimeError("实际移动的原件容器 FD 身份改变，未移动原件")
        if os.fstat(source).st_dev != os.fstat(target).st_dev:
            raise RuntimeError("程序原件必须同卷移动，未复制或替换")
        value = backup.checked_stat(app.name, source)
        if ":".join(map(str, (value.st_dev, value.st_ino, value.st_uid))) != expected_identity:
            raise RuntimeError("程序在移动前改变")
        system = ctypes.CDLL(None, use_errno=True)
        system.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        system.renameatx_np.restype = ctypes.c_int
        # Darwin sys/stdio.h: RENAME_EXCL=0x4, atomic failure if target exists.
        if system.renameatx_np(source, os.fsencode(app.name), target, os.fsencode(output.name), 0x4) != 0:
            raise OSError(ctypes.get_errno(), "排他移动失败，未覆盖已有程序")
        os.fsync(source)
        os.fsync(target)
    if app_identity(output) != expected_identity:
        raise RuntimeError("移动后原程序身份不符；原件与收据已保留")
    return output


def staged_paths(work, install_record):
    work, install_record = Path(work).absolute(), Path(install_record).absolute()
    if (work.parent != DESTINATION.parent or not work.name.startswith(".GaoJiLing-install-")
            or not work.name.endswith(".noindex")
            or not re.fullmatch(r"Install-V[0-9]+\.[0-9]{2}-.+\.noindex", install_record.name)):
        raise RuntimeError("暂存证明必须绑定本次正式安装的私有目录")
    source = work / "New.noindex" / DESTINATION.name
    require_noindex(source)
    return work, install_record, source


@backup.no_materialization
def record_staged(app, work, install_record, expected_identity):
    work, install_record, source = staged_paths(work, install_record)
    if Path(app).absolute() != source or app_identity(app) != expected_identity:
        raise RuntimeError("暂存程序位置或身份不符，未记录移动证明")
    info(app)
    signature_valid(app)
    root_metadata = original_metadata(app, {"": {}})[""]
    value = {"format": 1, "identifier": IDENTIFIER, "destination": str(DESTINATION),
             "installRecord": str(install_record), "work": str(work), "sourcePath": str(source),
             "identity": expected_identity, "rootMetadata": root_metadata,
             "workContainer": original_container(work), "recordContainer": original_container(install_record),
             "createdAt": time.time()}
    path = install_record / "staged-new.json"
    write_json(path, value)
    if app_identity(app) != expected_identity or original_metadata(app, {"": {}})[""] != root_metadata:
        raise RuntimeError("暂存程序在记录期间改变，未允许移动")
    return backup.file_digest(path)


def load_staged_receipt(receipt_path, checksum, baseline_path, record_path, expected_identity):
    receipt_path, baseline_path, record_path = (Path(path).absolute() for path in (receipt_path, baseline_path, record_path))
    if (not re.fullmatch(r"[0-9a-f]{64}", checksum)
            or receipt_path != baseline_path.parent / "staged-new.json"
            or baseline_path.name != "before.json" or record_path != baseline_path.parent / "unregistration.jsonl"):
        raise RuntimeError("暂存来源证明未绑定本次安装记录")
    raw = backup.read_regular(receipt_path, 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != checksum:
        raise RuntimeError("暂存来源证明摘要不符，未注销")
    value = json.loads(raw)
    work, install_record, source = staged_paths(value.get("work", ""), value.get("installRecord", ""))
    if (value.get("format") != 1 or value.get("identifier") != IDENTIFIER
            or value.get("destination") != str(DESTINATION) or install_record != receipt_path.parent
            or value.get("sourcePath") != str(source) or value.get("identity") != expected_identity
            or not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", expected_identity)
            or original_container(work) != value.get("workContainer")
            or original_container(install_record) != value.get("recordContainer")
            or not isinstance(value.get("rootMetadata"), dict)):
        raise RuntimeError("暂存来源路径、身份或容器不符，未注销")
    return value, source


def unregister_staged_source(receipt_path, checksum, moved_to, expected_identity, baseline_path, record_path,
                            run=subprocess.run, wait=time.sleep):
    value, source = load_staged_receipt(receipt_path, checksum, baseline_path, record_path, expected_identity)
    moved_to = Path(moved_to).absolute()
    def verify_moved_source():
        current, original = load_staged_receipt(receipt_path, checksum, baseline_path, record_path, expected_identity)
        if moved_to not in (DESTINATION, Path(current["work"]) / "Failed.noindex" / DESTINATION.name):
            raise RuntimeError("暂存程序的当前位置不是本次正式路径或失败暂存路径")
        try:
            backup.safe_lstat(original)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("历史暂存源仍有对象，拒绝按缺失源注销")
        if (app_identity(moved_to) != expected_identity
                or original_metadata(moved_to, {"": {}})[""] != current["rootMetadata"]):
            raise RuntimeError("已移动新版不再是完整匹配的原暂存对象，未注销历史源")
        return {"kind": "verified-staged-new-previous-location", "path": str(original),
                "currentLocation": str(moved_to), "identity": expected_identity,
                "receipt": str(Path(receipt_path).absolute()), "receiptSHA256": checksum}
    verify_moved_source()
    unregister_registration(source, baseline_path, record_path, run=run, wait=wait,
                            verified_missing_source=verify_moved_source)


def validate_zip(path, app_name):
    """Reject traversal, special files, and descendants of archive symlinks."""
    links, names = set(), set()
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 1_000_000 or sum(item.file_size for item in entries) > 8 * 1024**3:
            raise RuntimeError("程序归档超过安全预算")
        for item in entries:
            # macOS ditto writes UTF-8 filenames without always setting ZIP's
            # UTF-8 bit; zipfile otherwise decodes those bytes as CP437.
            name = item.filename
            if not item.flag_bits & 0x800:
                try:
                    name = name.encode("cp437").decode("utf-8")
                except UnicodeError as error:
                    raise RuntimeError("程序归档文件名编码无效") from error
            name = name.rstrip("/")
            parts = name.split("/")
            if not name or any(part in ("", ".", "..") for part in parts) or parts[0] not in (app_name, "__MACOSX") or name in names:
                raise RuntimeError("程序归档含不安全路径或重复条目")
            kind = stat.S_IFMT(item.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise RuntimeError("程序归档含特殊文件")
            names.add(name)
            if kind == stat.S_IFLNK:
                links.add(name)
        if any(str(parent) in links for name in names for parent in Path(name).parents):
            raise RuntimeError("程序归档试图在链接内写入")
        if archive.testzip() is not None:
            raise RuntimeError("程序归档 CRC 核验失败")


def load_receipt(path):
    path = Path(path).absolute()
    receipt = json.loads(backup.read_regular(path, 256 * 1024 * 1024))
    if receipt.get("format") not in (1, 2) or receipt.get("identifier") != IDENTIFIER or receipt.get("destination") != str(DESTINATION) or receipt.get("archive") != "previous-program.zip" or receipt.get("appName") != DESTINATION.name:
        raise RuntimeError("程序恢复收据无效")
    archive = path.parent / receipt["archive"]
    if receipt["format"] == 1:
        if backup.file_digest(archive) != receipt.get("archiveSHA256"):
            raise RuntimeError("程序恢复归档摘要不符")
        validate_zip(archive, receipt["appName"])
    else:
        original = receipt.get("original", {})
        if (receipt.get("archiveRole") != "supplemental-only"
                or original.get("relativePath") != "Program.noindex/" + DESTINATION.name
                or not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", original.get("identity", ""))
                or receipt.get("sourcePath") != str(DESTINATION)
                or not isinstance(original.get("metadata"), dict)
                or not only_root_macl_missing(receipt.get("tree", {}), receipt.get("archiveRoundTripTree", {}))):
            raise RuntimeError("原件回滚收据无效，不能降级使用辅助 ZIP")
        authority = path.parent / original["relativePath"]
        require_noindex(authority)
        container = original_container(authority.parent)
        if (container != original.get("container")
                or container["device"] != int(original["identity"].split(":")[0])):
            raise RuntimeError("原件容器身份、权限或同卷条件改变，拒绝移动")
        # The ZIP was checked during preparation, but is not the restoration
        # authority. Its later loss/corruption must not strand a valid original.
    return receipt, archive


@backup.no_materialization
def verify_program(receipt_path, app):
    receipt, _ = load_receipt(receipt_path)
    info(app)
    if backup.tree_manifest(app, allow_links=True) != receipt["tree"]:
        raise RuntimeError("展开回滚程序与核验收据不符")
    for name, checksum in receipt["tools"].items():
        if name not in ("release-safety.py", "backup-data.py") or backup.file_digest(Path(receipt_path).parent / name) != checksum:
            raise RuntimeError("保留的恢复工具摘要不符")
    if receipt["format"] == 2:
        original = receipt["original"]
        if (app_identity(app) != original["identity"]
                or original_metadata(app, receipt["tree"]) != original["metadata"]):
            raise RuntimeError("原件 inode、所有者或完整元数据与收据不符")
        if set(receipt["tools"]) != {"release-safety.py", "backup-data.py"}:
            raise RuntimeError("原件回滚恢复工具不完整")
        signature_valid(app)


def original_path(receipt_path):
    receipt, _ = load_receipt(receipt_path)
    if receipt["format"] != 2:
        raise RuntimeError("该收据不是原件移动恢复格式")
    return Path(receipt_path).absolute().parent / receipt["original"]["relativePath"]


@backup.no_materialization
def preserve_original(receipt_path, app):
    receipt, _ = load_receipt(receipt_path)
    target = original_path(receipt_path)
    if Path(app).absolute() != Path(receipt["sourcePath"]):
        raise RuntimeError("待保留原件位置与持久收据不符")
    verify_program(receipt_path, app)
    move_program(app, target, receipt["original"]["identity"], target_parent=receipt["original"]["container"])
    verify_program(receipt_path, target)
    # PREPARED alone is never a completed backup. Only a verified moved inode
    # earns this marker, and it lives outside the installer's disposable WORK.
    write_json(Path(receipt_path).parent / "VERIFIED", {
        "format": 2, "authorityAtVerification": str(target), "identity": app_identity(target),
        "receiptSHA256": backup.file_digest(receipt_path),
        "treeSHA256": backup.digest(receipt["tree"]), "verifiedAt": time.time(),
        "rootCtimeNs": backup.safe_lstat(target).st_ctime_ns})


@backup.no_materialization
def restore_original(receipt_path):
    receipt, _ = load_receipt(receipt_path)
    source = original_path(receipt_path)
    target = Path(receipt["sourcePath"])
    # A failed preserve may have moved the inode before its final fsync/marker.
    # Recovery relies on actual identity/tree, never a marker or ZIP copy.
    moved = False
    if target.exists() or target.is_symlink():
        if source.exists() or source.is_symlink():
            raise RuntimeError("原位与备份位置同时存在，拒绝覆盖或猜测")
        verify_program(receipt_path, target)
    else:
        verify_program(receipt_path, source)
        move_program(source, target, receipt["original"]["identity"], source_parent=receipt["original"]["container"])
        verify_program(receipt_path, target)
        moved = True
    # VERIFIED records the earlier successful backup, not a live location
    # pointer. RESTORED supersedes that historical location. Files return first,
    # so a full disk or receipt error cannot stop the filesystem restoration.
    state = {"format": 2, "authority": str(target), "identity": app_identity(target),
             "receiptSHA256": backup.file_digest(receipt_path),
             "status": "restored-original" if moved else "original-remained-installed",
             "previousAuthority": str(source), "restoredAt": time.time(),
             "rootCtimeNs": backup.safe_lstat(target).st_ctime_ns}
    marker = Path(receipt_path).parent / "RESTORED.json"
    try:
        if marker.exists() or marker.is_symlink():
            previous = json.loads(backup.read_regular(marker, 1024 * 1024))
            if any(previous.get(key) != state[key] for key in ("format", "authority", "identity", "receiptSHA256")):
                raise RuntimeError("已存在的恢复位置记录不符")
        else:
            write_json(marker, state)
    except (OSError, ValueError, RuntimeError) as error:
        raise RuntimeError("原件已恢复并完整核验于 " + str(target)
                           + "；恢复位置记录未能持久化，须保留现场：" + str(error)) from error
    return target


@backup.no_materialization
def extract(receipt_path, output):
    output = Path(output).absolute()
    require_noindex(output)
    if output.exists() or output.is_symlink():
        raise RuntimeError("恢复输出已存在，拒绝覆盖")
    receipt, archive = load_receipt(receipt_path)
    if receipt["format"] != 1:
        raise RuntimeError("此格式只允许 restore-original 同卷移动原件；ZIP 仅辅助，禁止解包降级恢复")
    # Only an owned private .noindex directory is ever used for extraction.
    with tempfile.TemporaryDirectory(prefix="program-restore-", suffix=".noindex", dir=output.parent) as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
        expanded = Path(temporary) / receipt["appName"]
        info(expanded)
        if backup.tree_manifest(expanded, allow_links=True) != receipt["tree"]:
            raise RuntimeError("程序恢复内容、模式、链接或扩展属性不符")
        if backup.file_digest(archive) != receipt["archiveSHA256"]:
            raise RuntimeError("程序归档在恢复期间变化")
        move_program(expanded, output, app_identity(expanded))
    return output


@backup.no_materialization
def archive_program(app, directory):
    app, directory = Path(app).absolute(), Path(directory).absolute()
    app_info = info(app)
    if app.name != DESTINATION.name:
        raise RuntimeError("回滚程序名称不符")
    baseline = backup.tree_manifest(app, allow_links=True)
    identity = app_identity(app)
    metadata = original_metadata(app, baseline)
    signature_valid(app)
    with backup.directory_fd(directory.parent):
        pass
    directory.mkdir(mode=0o700, exist_ok=False)
    archive = directory / "previous-program.zip"
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    archive.chmod(0o600)
    archive_checksum = backup.file_digest(archive)
    validate_zip(archive, app.name)
    with tempfile.TemporaryDirectory(prefix="program-check-", suffix=".noindex", dir=directory) as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
        expanded = Path(temporary) / app.name
        info(expanded)
        signature_valid(expanded)
        restored = backup.tree_manifest(expanded, allow_links=True)
    if backup.file_digest(archive) != archive_checksum:
        raise RuntimeError("程序归档在核验期间变化")
    retained = baseline != restored
    if retained and not only_root_macl_missing(baseline, restored):
        raise RuntimeError("程序恢复内容、模式、链接或扩展属性不符；不是唯一根 macl 差异")
    if (app_identity(app) != identity or backup.tree_manifest(app, allow_links=True) != baseline
            or original_metadata(app, baseline) != metadata):
        raise RuntimeError("旧程序在归档期间变化，停止安装")
    receipt = {"format": 1, "identifier": IDENTIFIER, "destination": str(DESTINATION),
               "sourcePath": str(app), "appName": app.name,
               "version": app_info.get("CFBundleShortVersionString"),
               "build": app_info.get("CFBundleVersion"), "archive": archive.name,
               "archiveSHA256": archive_checksum, "tree": baseline,
               "createdAt": time.time(), "tools": {}}
    if retained:
        if app != DESTINATION:
            raise RuntimeError("原件回滚只允许固定正式安装路径，未移动旧程序")
        container = directory / "Program.noindex"
        container.mkdir(mode=0o700)
        with backup.directory_fd(container, read=True) as parent:
            if os.fstat(parent).st_dev != backup.safe_lstat(app).st_dev:
                raise RuntimeError("权威原件备份必须与原程序同卷，未移动旧程序")
            os.fsync(parent)
        receipt.update(format=2, archiveRole="supplemental-only", archiveRoundTripTree=restored,
                       original={"relativePath": "Program.noindex/" + app.name,
                                 "identity": identity, "metadata": metadata,
                                 "container": original_container(container),
                                 "sourceRootCtimeNs": backup.safe_lstat(app).st_ctime_ns})
    # A rollback remains usable after future source updates or project moves.
    for name in ("release-safety.py", "backup-data.py"):
        raw = backup.read_regular(HERE / name)
        write_private(directory / name, raw)
        receipt["tools"][name] = backup.file_digest(directory / name)
    receipt_path = directory / "receipt.json"
    write_json(receipt_path, receipt)
    if retained:
        instructions = (
            "格式 2：ZIP 解包唯一缺失根 com.apple.macl，ZIP 仅为辅助，不是完整恢复备份。\n"
            "receipt.json 为不可变计划；PREPARED.json 只表示原位准备，不能视为备份通过。\n"
            "VERIFIED 仅记历史核验：原 inode 当时已移动至 Program.noindex/搞机灵.app。\n"
            "如有 RESTORED.json，其 authority 是随后恢复并完整核验的真实正式位置，优先于历史 VERIFIED。\n"
            "状态记录不能替代实物复核；恢复工具始终核验原位与备份位置，仅允许一个匹配的原件。\n"
            "权威原件的原路径、身份、完整树和元数据记录在收据中；失败时位置可能仍在 sourcePath。\n"
            "先正常退出搞机灵并保存当前程序回滚能力，精确注销待移动程序路径；不要覆盖未知程序。\n"
            "正式路径须为空，或已是收据中的同一原件；禁止从辅助 ZIP 复制或提取来替代原件。\n"
            "python3 release-safety.py restore-original --receipt receipt.json\n"
            "恢复工具只同卷排他移动原件，不回写用户资料、钥匙串、权限或系统属性。\n"
            "恢复后精确登记正式路径，注销本应用已移动路径，重新核对 Spotlight/LaunchServices 唯一入口。\n")
        write_private(directory / "RESTORE.txt", instructions.encode())
        write_json(directory / "PREPARED.json", {"format": 2, "status": "prepared-not-verified",
                   "receiptSHA256": backup.file_digest(receipt_path),
                   "sourcePath": str(app), "authority": str(original_path(receipt_path))})
        verify_program(receipt_path, app)
        return receipt_path
    instructions = (
        "程序回滚归档已解包核验；仅包含程序，不替代完整用户资料备份。\n"
        "恢复时先正常退出搞机灵；用本目录保存的工具和收据解包到新的 .noindex 容器。\n"
        "python3 release-safety.py extract --receipt receipt.json --output /private/tmp/手工恢复.noindex/搞机灵.app\n"
        "输出父目录须先建立。核验签名后，仅替换收据 destination 指定的正式程序；不要覆盖或回写用户资料/钥匙串。\n"
        "保存当前程序回滚能力，精确注销本应用临时登记，删除展开副本并重新核对 Spotlight/LaunchServices。\n")
    write_private(directory / "RESTORE.txt", instructions.encode())
    write_private(directory / "VERIFIED", (receipt["archiveSHA256"] + "\n").encode())
    return receipt_path


def registry_bundle_records(dump):
    result = []
    records = re.split(r"\n-+\n", dump)
    for record in records:
        if re.search(r"^bundle id:", record, re.M) is None:
            continue  # Handler/type/claim records are not application bundles.
        identifier = re.search(r"^identifier:\s*(.*?)\s*$", record, re.M)
        if identifier is None:
            continue
        found = re.search(r"^path:\s*(.*?)\s*$", record, re.M)
        if found is None:
            if identifier.group(1) == IDENTIFIER:
                raise RuntimeError("本应用 LaunchServices 记录缺少路径，无法核验")
            continue
        path = re.sub(r"\s+\(0x[0-9a-fA-F]+\)$", "", found.group(1))
        if not Path(path).is_absolute():
            raise RuntimeError("本应用 LaunchServices 路径无效")
        result.append({"identifier": identifier.group(1), "path": path})
    return result


def registry_paths(dump):
    return sorted({item["path"] for item in registry_bundle_records(dump) if item["identifier"] == IDENTIFIER})


def registry_record_details(dump):
    """Preserve raw flags/dates/inodes as evidence, without interpreting them."""
    result = []
    for block in re.split(r"\n-+\n", dump):
        records = [item for item in registry_bundle_records(block) if item["identifier"] == IDENTIFIER]
        for item in records:
            value = dict(item)
            for field in ("bundle flags", "reg date", "inode", "exec inode"):
                found = re.search(r"^" + re.escape(field) + r":\s*(.*?)\s*$", block, re.M)
                if found:
                    value[field] = found.group(1)
            result.append(value)
    return result


def registry_witnesses(records):
    # Store only hashes of stable, unrelated bundle records. The same baseline
    # must remain visible before absence can be trusted; a sandbox's empty or
    # handler-only dump cannot be mistaken for an already-absent registration.
    records = [item for item in records if item["identifier"] != IDENTIFIER and not any(part.endswith(".noindex") for part in Path(item["path"]).parts)]
    records.sort(key=lambda item: (Path(item["path"]).parent != Path("/Applications"), item["identifier"], item["path"]))
    return sorted({backup.digest(item) for item in records[:8]})


def append_event(path, value):
    path = Path(path)
    with backup.directory_fd(path.parent):
        if path.exists() and (backup.safe_lstat(path).st_uid != os.getuid() or backup.safe_lstat(path).st_size > 16 * 1024 * 1024):
            raise RuntimeError("注销审计记录不可安全追加")
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as output:
            output.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
            output.flush()
            os.fsync(output.fileno())


def unregister_registration(app, baseline_path, record_path, expected_identity=None, run=subprocess.run, wait=time.sleep,
                            verified_missing_source=None):
    app = Path(app).absolute()
    event = {"identifier": IDENTIFIER, "path": str(app), "at": time.time(), "status": "failed", "snapshots": [],
             "observationContract": "0/1/5-second finite observation window; not permanent deletion or launchability proof"}
    def verify_existing_identity():
        if not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", expected_identity) or app_identity(app) != expected_identity:
            raise RuntimeError("待回滚程序根身份不符，未注销")
    try:
        if verified_missing_source is not None:
            proof = verified_missing_source()
            if proof.get("path") != str(app):
                raise RuntimeError("已移动来源证明路径不符，未注销")
            event["sourceProof"] = proof
        elif expected_identity is None:
            info(app)
        else:
            verify_existing_identity()
        baseline = json.loads(backup.read_regular(baseline_path, 32 * 1024 * 1024))
        witnesses = baseline.get("launchServicesWitnesses", [])
        if baseline.get("format") != 1 or baseline.get("identifier") != IDENTIFIER or baseline.get("issues") or not witnesses or not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in witnesses):
            raise RuntimeError("缺少本次可观察 LaunchServices 基线，未注销")
        anchors = set(baseline.get("launchServices", [])) - {str(app)}
        def observe(stage):
            if verified_missing_source is not None:
                verified_missing_source()
            elif expected_identity is not None:
                verify_existing_identity()
            result = run([LSREGISTER, "-dump"], capture_output=True, text=True)
            if result.returncode:
                event["snapshots"].append({"stage": stage, "at": time.time(), "queryReturncode": result.returncode})
                raise RuntimeError("LaunchServices 查询失败，不能判定登记已不存在")
            records = registry_bundle_records(result.stdout)
            available = {backup.digest(item) for item in records if item["identifier"] != IDENTIFIER}
            paths = sorted({item["path"] for item in records if item["identifier"] == IDENTIFIER})
            event["snapshots"].append({"stage": stage, "at": time.time(), "paths": paths,
                                       "recordDetails": registry_record_details(result.stdout),
                                       "witnessesVisible": set(witnesses).issubset(available),
                                       "anchorsVisible": anchors.issubset(paths)})
            if not records or not set(witnesses).issubset(available) or not anchors.issubset(paths):
                raise RuntimeError("LaunchServices 视图为空、受限或与基线不一致，不能判定登记已不存在")
            return paths
        paths = observe("before")
        event["beforePaths"] = paths
        if str(app) not in paths:
            for delay, stage in ((1, "absence+1s"), (4, "absence+5s")):
                wait(delay)
                paths = observe(stage)
                if str(app) in paths:
                    break  # A delayed appearance still needs exact removal.
            if str(app) not in paths:
                event.update(status="alreadyAbsent", afterPaths=paths, commandIssued=False)
                return
        if verified_missing_source is not None:
            verified_missing_source()
        elif expected_identity is not None:
            verify_existing_identity()
        result = run([LSREGISTER, "-u", str(app)], capture_output=True, text=True)
        event.update(commandIssued=True, commandReturncode=result.returncode, commandStderr=result.stderr[:4096])
        for delay, stage in ((0, "after-command"), (1, "after-command+1s"), (4, "after-command+5s")):
            if delay:
                wait(delay)
            paths = observe(stage)
            event["afterPaths"] = paths
            if str(app) in paths:
                raise RuntimeError("本应用精确路径仍有或重新出现 LaunchServices 登记，停止替换")
        event["status"] = "unregistered" if result.returncode == 0 else "absentAfterCommandError"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        event["error"] = str(error)
        raise
    finally:
        append_event(record_path, event)


def collect_audit(project, extra):
    visibility = {}
    def query(source, command):
        try:
            result = subprocess.run(command, capture_output=True)
            if result.returncode:
                visibility[source] = {"status": "unavailable", "returncode": result.returncode,
                                      "error": os.fsdecode(result.stderr[:4096])}
                return b""
            visibility[source] = {"status": "observable"}
            return result.stdout
        except OSError as error:
            visibility[source] = {"status": "unavailable", "error": str(error)}
            return b""
    spotlight = query("spotlight", ["/usr/bin/mdfind", "-0", 'kMDItemCFBundleIdentifier == "' + IDENTIFIER + '"'])
    raw_registry = os.fsdecode(query("launchServices", [LSREGISTER, "-dump"]))
    registry_records = registry_bundle_records(raw_registry)
    registered = sorted({item["path"] for item in registry_records if item["identifier"] == IDENTIFIER})
    indexed = sorted(set(os.fsdecode(part) for part in spotlight.split(b"\0") if part))
    for source, paths in (("spotlight", indexed), ("launchServices", registered)):
        if not paths and visibility[source]["status"] == "observable":
            visibility[source]["status"] = "emptyForIdentifier"
    known = {str(DESTINATION), *LEGACY_PATHS, *extra}
    # Project outputs are checked by exact app bundle, without descending into
    # data backups, symlink directories, .git or app bundles themselves.
    for root, directories, _ in os.walk(project, followlinks=False):
        for name in list(directories):
            path = Path(root) / name
            if name.endswith(".app"):
                try:
                    if info(path).get("CFBundleIdentifier") == IDENTIFIER:
                        known.add(str(path.absolute()))
                except (OSError, ValueError, RuntimeError):
                    if path.name == DESTINATION.name:
                        raise RuntimeError("项目内同名程序无法核验：" + str(path))
                directories.remove(name)
            elif name in (".git", "TestResults") or path.is_symlink():
                directories.remove(name)
    copies, inaccessible = [], []
    for name in sorted(known | set(indexed) | set(registered)):
        path = Path(name)
        if not path.exists() and not path.is_symlink():
            continue
        try:
            value = info(path)
            copies.append({"path": name, "version": value.get("CFBundleShortVersionString"),
                           "noindex": noindex_parent(path)})
        except (OSError, ValueError, RuntimeError) as error:
            inaccessible.append({"path": name, "error": str(error)})
    return {"format": 1, "identifier": IDENTIFIER, "destination": str(DESTINATION),
            "observedAt": time.time(), "spotlight": indexed, "launchServices": registered,
            "copies": copies, "inaccessible": inaccessible, "visibility": visibility,
            "launchServicesWitnesses": registry_witnesses(registry_records),
            "launchServicesRecordDetails": registry_record_details(raw_registry),
            "scope": "Spotlight, LaunchServices, exact installer paths and project app bundles; not a full-disk scan"}


def audit_issues(audit, final=False):
    issues = list(audit["inaccessible"])
    installed = any(item["path"] == str(DESTINATION) for item in audit["copies"])
    for source in ("spotlight", "launchServices"):
        if audit["visibility"][source]["status"] == "unavailable":
            issues.append({"source": source, "error": "查询不可用，无法确认唯一入口"})
        for path in audit[source]:
            if path != str(DESTINATION):
                issues.append({"source": source, "path": path, "error": "非正式安装入口或失效登记须精确查明"})
        if (final or installed) and audit[source] != [str(DESTINATION)]:
            issues.append({"source": source, "error": "正式安装入口尚未唯一可见，索引/登记核验未完成"})
    for item in audit["copies"]:
        if item["path"] != str(DESTINATION) and not item["noindex"]:
            issues.append({"source": "filesystem", "path": item["path"], "error": "可索引的同 Bundle ID 展开副本"})
    if final and not any(item["path"] == str(DESTINATION) for item in audit["copies"]):
        issues.append({"source": "filesystem", "error": "正式安装程序不存在或无法核验"})
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    action = actions.add_parser("workdir")
    action.add_argument("--parent", required=True, type=Path)
    action.add_argument("--prefix", required=True)
    action = actions.add_parser("recorddir")
    action.add_argument("--parent", required=True, type=Path)
    action.add_argument("--prefix", required=True)
    action = actions.add_parser("check-noindex")
    action.add_argument("path", type=Path)
    action = actions.add_parser("identity")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--expected")
    actions.add_parser("stop-program")
    actions.add_parser("running-program")
    action = actions.add_parser("archive")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--directory", required=True, type=Path)
    action = actions.add_parser("extract")
    action.add_argument("--receipt", required=True, type=Path)
    action.add_argument("--output", required=True, type=Path)
    action = actions.add_parser("verify")
    action.add_argument("--receipt", required=True, type=Path)
    action.add_argument("--app", required=True, type=Path)
    for name in ("receipt-format", "original-path", "restore-original"):
        action = actions.add_parser(name)
        action.add_argument("--receipt", required=True, type=Path)
    action = actions.add_parser("preserve-original")
    action.add_argument("--receipt", required=True, type=Path)
    action.add_argument("--app", required=True, type=Path)
    action = actions.add_parser("move-app")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--output", required=True, type=Path)
    action.add_argument("--expected-identity", required=True)
    action = actions.add_parser("record-plan")
    action.add_argument("--receipt", required=True, type=Path)
    action.add_argument("--original-path", required=True, type=Path)
    action.add_argument("--record", required=True, type=Path)
    action = actions.add_parser("record-staged")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--work", required=True, type=Path)
    action.add_argument("--install-record", required=True, type=Path)
    action.add_argument("--expected-identity", required=True)
    action = actions.add_parser("unregister-staged-source")
    action.add_argument("--receipt", required=True, type=Path)
    action.add_argument("--receipt-sha256", required=True)
    action.add_argument("--moved-to", required=True, type=Path)
    action.add_argument("--expected-identity", required=True)
    action.add_argument("--baseline", required=True, type=Path)
    action.add_argument("--record", required=True, type=Path)
    action = actions.add_parser("unregister-exact")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--baseline", required=True, type=Path)
    action.add_argument("--record", required=True, type=Path)
    action.add_argument("--expected-identity")
    action = actions.add_parser("audit")
    action.add_argument("--project", required=True, type=Path)
    action.add_argument("--output", required=True, type=Path)
    action.add_argument("--known-path", action="append", default=[])
    action.add_argument("--final", action="store_true")
    args = parser.parse_args()
    if args.action in ("workdir", "recorddir"):
        if args.action == "recorddir":
            args.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with backup.directory_fd(args.parent):
            print(tempfile.mkdtemp(prefix=args.prefix, suffix=".noindex", dir=args.parent))
    elif args.action == "check-noindex":
        require_noindex(args.path)
    elif args.action == "identity":
        observed = app_identity(args.app)
        if args.expected is not None:
            if not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", args.expected) or args.expected != observed:
                raise RuntimeError("正式路径已不再是此次核验的新程序，保留现场与回滚包")
        else:
            info(args.app)
            print(observed)
    elif args.action == "stop-program":
        stop_program()
    elif args.action == "running-program":
        return 0 if matching_program_processes() else 1
    elif args.action == "archive":
        print(archive_program(args.app, args.directory))
    elif args.action == "extract":
        print(extract(args.receipt, args.output))
    elif args.action == "verify":
        verify_program(args.receipt, args.app)
    elif args.action == "receipt-format":
        print(load_receipt(args.receipt)[0]["format"])
    elif args.action == "original-path":
        print(original_path(args.receipt))
    elif args.action == "preserve-original":
        preserve_original(args.receipt, args.app)
    elif args.action == "restore-original":
        print(restore_original(args.receipt))
    elif args.action == "move-app":
        move_program(args.app, args.output, args.expected_identity)
    elif args.action == "record-plan":
        receipt, _ = load_receipt(args.receipt)
        require_noindex(args.original_path)
        if receipt["format"] == 2 and args.original_path.absolute() != original_path(args.receipt):
            raise RuntimeError("安装恢复指针不符，原程序未移动")
        write_json(args.record, {"format": receipt["format"], "receipt": str(args.receipt.absolute()),
                   "receiptSHA256": backup.file_digest(args.receipt), "sourcePath": receipt["sourcePath"],
                   "authorityPath": str(args.original_path.absolute()), "state": "before-first-rename",
                   "recovery": "move-original" if receipt["format"] == 2 else "verified-archive"})
    elif args.action == "record-staged":
        print(record_staged(args.app, args.work, args.install_record, args.expected_identity))
    elif args.action == "unregister-staged-source":
        unregister_staged_source(args.receipt, args.receipt_sha256, args.moved_to, args.expected_identity,
                                 args.baseline, args.record)
    elif args.action == "unregister-exact":
        unregister_registration(args.app, args.baseline, args.record, args.expected_identity)
    elif args.action == "audit":
        evidence = collect_audit(args.project, args.known_path)
        snapshots = [evidence]
        if args.final:
            for delay in (1, 4):
                time.sleep(delay)
                snapshots.append(collect_audit(args.project, args.known_path))
            evidence = dict(snapshots[-1])
            evidence["observations"] = snapshots
            evidence["observationContract"] = "0/1/5-second independent snapshots; finite-window evidence only, raw record flags are not filtered"
        evidence["issues"] = [dict(issue, observation=index) for index, snapshot in enumerate(snapshots) for issue in audit_issues(snapshot, final=args.final)]
        write_json(args.output, evidence)
        if evidence["issues"]:
            print("唯一入口核验未完成；逐路径证据：" + str(args.output), file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print("停止：" + str(error), file=sys.stderr)
        sys.exit(1)
