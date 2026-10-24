#!/usr/bin/env python3
"""Private program rollback archives and narrowly scoped installation evidence.

This does not restore user data, modify the Keychain, or reset system registries.
Archive operations reuse the existing nofollow backup-tree verifier unchanged.
"""
import argparse
import ctypes
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
    if receipt.get("format") != 1 or receipt.get("identifier") != IDENTIFIER or receipt.get("destination") != str(DESTINATION) or receipt.get("archive") != "previous-program.zip" or receipt.get("appName") != DESTINATION.name:
        raise RuntimeError("程序恢复收据无效")
    archive = path.parent / receipt["archive"]
    if backup.file_digest(archive) != receipt.get("archiveSHA256"):
        raise RuntimeError("程序恢复归档摘要不符")
    validate_zip(archive, receipt["appName"])
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


@backup.no_materialization
def extract(receipt_path, output):
    output = Path(output).absolute()
    require_noindex(output)
    if output.exists() or output.is_symlink():
        raise RuntimeError("恢复输出已存在，拒绝覆盖")
    receipt, archive = load_receipt(receipt_path)
    # Only an owned private .noindex directory is ever used for extraction.
    with tempfile.TemporaryDirectory(prefix="program-restore-", suffix=".noindex", dir=output.parent) as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
        expanded = Path(temporary) / receipt["appName"]
        info(expanded)
        if backup.tree_manifest(expanded, allow_links=True) != receipt["tree"]:
            raise RuntimeError("程序恢复内容、模式、链接或扩展属性不符")
        if backup.file_digest(archive) != receipt["archiveSHA256"]:
            raise RuntimeError("程序归档在恢复期间变化")
        expanded.rename(output)
    return output


@backup.no_materialization
def archive_program(app, directory):
    app, directory = Path(app).absolute(), Path(directory).absolute()
    app_info = info(app)
    if app.name != DESTINATION.name:
        raise RuntimeError("回滚程序名称不符")
    baseline = backup.tree_manifest(app, allow_links=True)
    with backup.directory_fd(directory.parent):
        pass
    directory.mkdir(mode=0o700, exist_ok=False)
    archive = directory / "previous-program.zip"
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    archive.chmod(0o600)
    receipt = {"format": 1, "identifier": IDENTIFIER, "destination": str(DESTINATION),
               "sourcePath": str(app), "appName": app.name,
               "version": app_info.get("CFBundleShortVersionString"),
               "build": app_info.get("CFBundleVersion"), "archive": archive.name,
               "archiveSHA256": backup.file_digest(archive), "tree": baseline,
               "createdAt": time.time(), "tools": {}}
    # A rollback remains usable after future source updates or project moves.
    for name in ("release-safety.py", "backup-data.py"):
        raw = backup.read_regular(HERE / name)
        (directory / name).write_bytes(raw)
        (directory / name).chmod(0o600)
        receipt["tools"][name] = backup.file_digest(directory / name)
    receipt_path = directory / "receipt.json"
    write_json(receipt_path, receipt)
    with tempfile.TemporaryDirectory(prefix="program-check-", suffix=".noindex", dir=directory) as temporary:
        extract(receipt_path, Path(temporary) / app.name)
    if backup.tree_manifest(app, allow_links=True) != baseline:
        raise RuntimeError("旧程序在归档期间变化，停止安装")
    (directory / "RESTORE.txt").write_text(
        "程序回滚归档已解包核验；仅包含程序，不替代完整用户资料备份。\n"
        "恢复时先正常退出搞机灵；用本目录保存的工具和收据解包到新的 .noindex 容器。\n"
        "python3 release-safety.py extract --receipt receipt.json --output /private/tmp/手工恢复.noindex/搞机灵.app\n"
        "输出父目录须先建立。核验签名后，仅替换收据 destination 指定的正式程序；不要覆盖或回写用户资料/钥匙串。\n"
        "保存当前程序回滚能力，精确注销本应用临时登记，删除展开副本并重新核对 Spotlight/LaunchServices。\n", encoding="utf-8")
    (directory / "RESTORE.txt").chmod(0o600)
    (directory / "VERIFIED").write_text(receipt["archiveSHA256"] + "\n", encoding="utf-8")
    (directory / "VERIFIED").chmod(0o600)
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


def unregister_registration(app, baseline_path, record_path, expected_identity=None, run=subprocess.run, wait=time.sleep):
    app = Path(app).absolute()
    event = {"identifier": IDENTIFIER, "path": str(app), "at": time.time(), "status": "failed", "snapshots": [],
             "observationContract": "0/1/5-second finite observation window; not permanent deletion or launchability proof"}
    try:
        if expected_identity is None:
            info(app)
        elif not re.fullmatch(r"[0-9]+:[0-9]+:[0-9]+", expected_identity) or app_identity(app) != expected_identity:
            raise RuntimeError("待回滚程序根身份不符，未注销")
        baseline = json.loads(backup.read_regular(baseline_path, 32 * 1024 * 1024))
        witnesses = baseline.get("launchServicesWitnesses", [])
        if baseline.get("format") != 1 or baseline.get("identifier") != IDENTIFIER or baseline.get("issues") or not witnesses or not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in witnesses):
            raise RuntimeError("缺少本次可观察 LaunchServices 基线，未注销")
        anchors = set(baseline.get("launchServices", [])) - {str(app)}
        def observe(stage):
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
