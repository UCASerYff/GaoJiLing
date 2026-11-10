#!/usr/bin/env python3
"""Installation identity, data-preservation and unique-entry checks.

No user-data copy, program archive, automatic rollback or registry reset is made.
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
import signal
import stat
import subprocess
import sys
import tempfile
import time

IDENTIFIER = "com.gaoseries.GaoJiLing"
DESTINATION = Path("/Applications/搞机灵.app")
LEGACY_PATHS = ("/Applications/.GaoJiLing-install.app", "/Applications/.GaoJiLing-previous.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DATA = Path.home() / "Library/Application Support/GaoSeries/GaoJiLing"
PREFERENCES = Path.home() / "Library/Preferences/com.gaoseries.GaoJiLing.plist"
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gaojiling_file_safety", HERE / "file-safety.py")
files = importlib.util.module_from_spec(spec)
spec.loader.exec_module(files)


def noindex_parent(path):
    """Resolve ancestors, so a .noindex symlink cannot disguise indexed output."""
    path = Path(path).absolute()
    return any(part.name.endswith(".noindex") for part in path.parent.resolve().parents) or path.parent.resolve().name.endswith(".noindex")


def require_noindex(path):
    if not noindex_parent(path):
        raise RuntimeError("展开程序必须位于真实的 .noindex 容器内")


def info(path):
    path = Path(path)
    if not stat.S_ISDIR(files.safe_lstat(path).st_mode):
        raise RuntimeError("程序不是普通目录")
    value = plistlib.loads(files.read_regular(path / "Contents/Info.plist", 1024 * 1024))
    if value.get("CFBundleIdentifier") != IDENTIFIER:
        raise RuntimeError("程序 Bundle ID 不符")
    return value


def app_identity(path):
    value = files.safe_lstat(path)
    if not stat.S_ISDIR(value.st_mode):
        raise RuntimeError("程序身份不是普通目录")
    return ":".join(str(number) for number in (value.st_dev, value.st_ino, value.st_uid))


class ProcessBSDInfo(ctypes.Structure):
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
            os.kill(pid, 0)
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
    """Normal TERM only, after PID/start/UID and the official executable match."""
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
            raise RuntimeError("本应用仍在退出，未强杀；原程序和资料保留")
        wait(0.2)
    if matching():
        raise RuntimeError("退出期间本应用重新启动，停止替换；未退出新进程")


def write_json(path, value):
    path = Path(path)
    with path.open("x", encoding="utf-8") as output:
        os.chmod(path, 0o600)
        json.dump(value, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    with files.directory_fd(path.parent, read=True) as parent:
        os.fsync(parent)


def signature_valid(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)


def write_private(path, raw):
    with Path(path).open("xb") as output:
        os.chmod(path, 0o600)
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    with files.directory_fd(Path(path).parent, read=True) as parent:
        os.fsync(parent)


def original_metadata(app, manifest):
    result = {}
    for relative in manifest:
        value = files.safe_lstat(Path(app) / relative)
        result[relative] = {"device": value.st_dev, "inode": value.st_ino,
                            "uid": value.st_uid, "gid": value.st_gid,
                            "mode": value.st_mode, "flags": value.st_flags,
                            "nlink": value.st_nlink, "size": value.st_size,
                            "mtimeNs": value.st_mtime_ns}
    return result


def container_metadata(value):
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or stat.S_IMODE(value.st_mode) != 0o700:
        raise RuntimeError("工作容器必须是当前用户拥有的真实 0700 目录")
    return {"device": value.st_dev, "inode": value.st_ino,
            "uid": value.st_uid, "gid": value.st_gid, "mode": stat.S_IMODE(value.st_mode)}


def original_container(path):
    return container_metadata(files.safe_lstat(path))


def move_program(app, output, expected_identity):
    """Same-volume, no-replace rename. Never merge/overwrite an unknown app."""
    app, output = Path(app).absolute(), Path(output).absolute()
    if not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", expected_identity) or app_identity(app) != expected_identity:
        raise RuntimeError("移动前程序身份不符，保留原件")
    if output != DESTINATION:
        require_noindex(output)
    with files.directory_fd(app.parent, read=True) as source, files.directory_fd(output.parent, read=True) as target:
        if os.fstat(source).st_dev != os.fstat(target).st_dev:
            raise RuntimeError("程序必须同卷移动，未复制或替换")
        value = files.checked_stat(app.name, source)
        if ":".join(map(str, (value.st_dev, value.st_ino, value.st_uid))) != expected_identity:
            raise RuntimeError("程序在移动前改变")
        system = ctypes.CDLL(None, use_errno=True)
        system.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        system.renameatx_np.restype = ctypes.c_int
        if system.renameatx_np(source, os.fsencode(app.name), target, os.fsencode(output.name), 0x4) != 0:
            raise OSError(ctypes.get_errno(), "排他移动失败，未覆盖已有程序")
        os.fsync(source)
        os.fsync(target)
    if app_identity(output) != expected_identity:
        raise RuntimeError("移动后程序身份不符，保留现场")
    return output


def staged_paths(work, install_record):
    work, install_record = Path(work).absolute(), Path(install_record).absolute()
    if (work.parent != DESTINATION.parent or not work.name.startswith(".GaoJiLing-install-")
            or not work.name.endswith(".noindex")
            or install_record.parent != work
            or not re.fullmatch(r"Install-V[0-9]+\.[0-9]{2}-.+\.noindex", install_record.name)):
        raise RuntimeError("暂存证明必须绑定本次正式安装的私有目录")
    source = work / "New.noindex" / DESTINATION.name
    require_noindex(source)
    return work, install_record, source


@files.no_materialization
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
    return files.file_digest(path)


def load_staged_receipt(receipt_path, checksum, baseline_path, record_path, expected_identity):
    receipt_path, baseline_path, record_path = (Path(path).absolute() for path in (receipt_path, baseline_path, record_path))
    if (not re.fullmatch(r"[0-9a-f]{64}", checksum)
            or receipt_path != baseline_path.parent / "staged-new.json"
            or baseline_path.name != "before.json" or record_path != baseline_path.parent / "unregistration.jsonl"):
        raise RuntimeError("暂存来源证明未绑定本次安装记录")
    raw = files.read_regular(receipt_path, 1024 * 1024)
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
        if moved_to != DESTINATION:
            raise RuntimeError("暂存程序的当前位置不是本次正式路径")
        try:
            files.safe_lstat(original)
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


def registry_bundle_records(dump):
    result = []
    for record in re.split(r"\n-+\n", dump):
        if re.search(r"^bundle id:", record, re.M) is None:
            continue
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


def registry_record_details(dump):
    result = []
    for block in re.split(r"\n-+\n", dump):
        for item in [item for item in registry_bundle_records(block) if item["identifier"] == IDENTIFIER]:
            value = dict(item)
            for field in ("bundle flags", "reg date", "inode", "exec inode"):
                found = re.search(r"^" + re.escape(field) + r":\s*(.*?)\s*$", block, re.M)
                if found:
                    value[field] = found.group(1)
            result.append(value)
    return result


def registry_witnesses(records):
    records = [item for item in records if item["identifier"] != IDENTIFIER and not any(part.endswith(".noindex") for part in Path(item["path"]).parts)]
    records.sort(key=lambda item: (Path(item["path"]).parent != Path("/Applications"), item["identifier"], item["path"]))
    return sorted({files.digest(item) for item in records[:8]})


def append_event(path, value):
    path = Path(path)
    with files.directory_fd(path.parent):
        if path.exists() and (files.safe_lstat(path).st_uid != os.getuid() or files.safe_lstat(path).st_size > 16 * 1024 * 1024):
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
            raise RuntimeError("待注销程序根身份不符")

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
        baseline = json.loads(files.read_regular(baseline_path, 32 * 1024 * 1024))
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
            available = {files.digest(item) for item in records if item["identifier"] != IDENTIFIER}
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
                    break
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


@files.no_materialization
def user_data_state():
    def root_state(path):
        if files.optional_stat(path) is None:
            return {"exists": False}
        return {"exists": True, "tree": files.tree_manifest(path)}
    return {"format": 1, "purpose": "read-only-preservation-comparison",
            "data": root_state(DATA), "preferences": root_state(PREFERENCES)}


def record_user_data(output):
    write_json(output, user_data_state())


def verify_user_data(baseline_path):
    expected = json.loads(files.read_regular(baseline_path, 256 * 1024 * 1024))
    if expected.get("format") != 1 or expected.get("purpose") != "read-only-preservation-comparison":
        raise RuntimeError("资料核验基线格式无效")
    if user_data_state() != expected:
        raise RuntimeError("安装前后用户资料或偏好发生变化，停止完成安装；未创建或恢复任何备份")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    for name in ("workdir", "recorddir"):
        action = actions.add_parser(name)
        action.add_argument("--parent", required=True, type=Path)
        action.add_argument("--prefix", required=True)
    action = actions.add_parser("check-noindex")
    action.add_argument("path", type=Path)
    action = actions.add_parser("identity")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--expected")
    actions.add_parser("stop-program")
    actions.add_parser("running-program")
    action = actions.add_parser("move-app")
    action.add_argument("--app", required=True, type=Path)
    action.add_argument("--output", required=True, type=Path)
    action.add_argument("--expected-identity", required=True)
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
    action = actions.add_parser("record-user-data")
    action.add_argument("--output", required=True, type=Path)
    action = actions.add_parser("verify-user-data")
    action.add_argument("--baseline", required=True, type=Path)
    args = parser.parse_args()
    if args.action in ("workdir", "recorddir"):
        if args.action == "recorddir":
            args.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with files.directory_fd(args.parent):
            print(tempfile.mkdtemp(prefix=args.prefix, suffix=".noindex", dir=args.parent))
    elif args.action == "check-noindex":
        require_noindex(args.path)
    elif args.action == "identity":
        observed = app_identity(args.app)
        if args.expected is not None:
            if not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", args.expected) or args.expected != observed:
                raise RuntimeError("正式路径已不再是此次核验的新程序，保留现场")
        else:
            info(args.app)
            print(observed)
    elif args.action == "stop-program":
        stop_program()
    elif args.action == "running-program":
        return 0 if matching_program_processes() else 1
    elif args.action == "move-app":
        move_program(args.app, args.output, args.expected_identity)
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
            evidence["observationContract"] = "0/1/5-second independent snapshots; finite-window evidence only"
        evidence["issues"] = [dict(issue, observation=index) for index, snapshot in enumerate(snapshots) for issue in audit_issues(snapshot, final=args.final)]
        write_json(args.output, evidence)
        if evidence["issues"]:
            print("唯一入口核验未完成；逐路径证据：" + str(args.output), file=sys.stderr)
            return 3
    elif args.action == "record-user-data":
        record_user_data(args.output)
    elif args.action == "verify-user-data":
        verify_user_data(args.baseline)
        print("用户资料与偏好保持不变；未创建任何备份")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("停止：" + str(error), file=sys.stderr)
        sys.exit(1)
