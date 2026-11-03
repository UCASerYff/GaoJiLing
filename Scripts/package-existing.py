#!/usr/bin/env python3
"""Package a pinned, already signed candidate. Never compile, sign, launch or install.

The shared workspace caller must hold its Master build lease for --create.
Without --create this performs read-only candidate validation only.
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
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("gjl_package_safety", ROOT / "Scripts/release-safety.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)
backup = safety.backup


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True)


def requirement(app):
    value = run(["/usr/bin/codesign", "-d", "-r-", str(app)])
    lines = [x for x in (value.stdout + value.stderr).splitlines() if "designated =>" in x]
    if len(lines) != 1:
        raise RuntimeError("无法唯一读取候选的完整指定要求")
    return lines[0].strip()


def receipt_and_candidate(path, checksum, approved_changes=None):
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise RuntimeError("必须提供已独立核对的原构建收据 SHA-256")
    raw = backup.read_regular(path, 2 * 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != checksum:
        raise RuntimeError("原构建收据摘要改变，未打包")
    value = json.loads(raw)
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", version) or value.get("version") != version or value.get("build") != version.replace(".", ""):
        raise RuntimeError("构建收据与当前版本/构建号不一致")
    if value.get("bundleID") != safety.IDENTIFIER or not value.get("buildInputsUnchanged"):
        raise RuntimeError("候选身份或原构建输入一致性不符")
    hashes = value.get("buildInputHashes")
    if not isinstance(hashes, dict) or not hashes or len(hashes) > 512:
        raise RuntimeError("原构建图缺失或超过预算")
    changes = approved_changes if approved_changes is not None else value.get("postBuildChanges", {})
    if not isinstance(changes, dict) or set(changes) - {"Scripts/build.sh", "使用说明.txt"}:
        raise RuntimeError("未经明确绑定的构建后改动")
    if changes and approved_changes is None:
        parent = value.get("originalBuildReceipt")
        parent_sha = value.get("originalBuildReceiptSHA256")
        if not parent or not parent_sha:
            raise RuntimeError("新签名收据缺原编译收据关联")
        parent_bytes = backup.read_regular(Path(parent), 2 * 1024 * 1024)
        if hashlib.sha256(parent_bytes).hexdigest() != parent_sha or json.loads(parent_bytes).get("buildInputHashes") != hashes:
            raise RuntimeError("原编译图或关联摘要改变")
    for name, expected in hashes.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise RuntimeError("构建图包含非法路径或摘要")
        if name in changes:
            change = changes[name]
            if set(change) != {"from", "to", "reason"} or change["from"] != expected or not re.fullmatch(r"[0-9a-f]{64}", change["to"]):
                raise RuntimeError("构建后改动摘要未精确绑定")
            expected = change["to"]
        if backup.file_digest(ROOT / relative) != expected:
            raise RuntimeError("候选构建输入已经改变：" + name)
    app = Path(value["app"])
    if not app.is_absolute() or ".." in app.parts or app.name != "搞机灵.app":
        raise RuntimeError("候选必须是精确绝对程序路径")
    safety.require_noindex(app)
    info = plistlib.loads(backup.read_regular(app / "Contents/Info.plist", 1024 * 1024))
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), info.get("CFBundleExecutable")) != (safety.IDENTIFIER, version, value["build"], "GaoJiLing"):
        raise RuntimeError("真实候选 Info 身份不符")
    safety.signature_valid(app)
    if backup.file_digest(app / "Contents/MacOS/GaoJiLing") != value["executableSHA256"]:
        raise RuntimeError("候选可执行文件摘要改变")
    expected = [x.strip() for x in value["designatedRequirementOutput"].splitlines() if "designated =>" in x]
    if len(expected) != 1 or requirement(app) != expected[0]:
        raise RuntimeError("候选的完整指定要求已改变；不重新签名")
    return value, app, expected[0]


def verify_copy(app, tree, expected_requirement):
    safety.require_noindex(app)
    safety.signature_valid(app)
    if requirement(app) != expected_requirement or backup.tree_manifest(app, allow_links=True) != tree:
        raise RuntimeError("打包副本与候选的内容/模式/链接/xattr或指定要求不一致；不豁免差异")


def publish_new_file(source, destination):
    """Same-volume, no-replace file rename; no temporary hardlink exception."""
    with backup.directory_fd(source.parent, read=True) as origin, backup.directory_fd(destination.parent, read=True) as target:
        before = backup.checked_stat(source.name, origin)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid() or before.st_dev != os.fstat(target).st_dev:
            raise RuntimeError("发行文件不是当前用户的同卷独立普通文件")
        fd = os.open(source.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=origin)
        try:
            if backup.signature(os.fstat(fd)) != backup.signature(before):
                raise RuntimeError("发行文件在落盘前改变")
            os.fsync(fd)
        finally:
            os.close(fd)
        system = ctypes.CDLL(None, use_errno=True)
        system.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        system.renameatx_np.restype = ctypes.c_int
        if system.renameatx_np(origin, os.fsencode(source.name), target, os.fsencode(destination.name), 0x4) != 0:
            raise OSError(ctypes.get_errno(), "发行目标已存在或无法排他落盘；未覆盖")
        os.fsync(origin); os.fsync(target)
        after = backup.checked_stat(destination.name, target)
        if (before.st_dev, before.st_ino, before.st_uid) != (after.st_dev, after.st_ino, after.st_uid):
            raise RuntimeError("发行落盘后的文件身份改变，保留实际产物")


@backup.no_materialization
def execute(args):
    receipt = Path(args.receipt)
    if not receipt.is_absolute():
        raise RuntimeError("收据路径必须是规范绝对路径")
    value, app, expected_requirement = receipt_and_candidate(receipt, args.receipt_sha256)
    original_identity = safety.app_identity(app)
    tree = backup.tree_manifest(app, allow_links=True)
    evidence = {"version": value["version"], "build": value["build"], "bundleID": safety.IDENTIFIER,
                "candidate": str(app), "buildReceipt": str(receipt), "buildReceiptSHA256": args.receipt_sha256,
                "candidateIdentity": original_identity, "candidateTreeSHA256": backup.digest(tree),
                "treeComparison": "entry set, file SHA-256, modes, link text and xattr digests; not a claim about all ACL/owner/time metadata",
                "designatedRequirement": expected_requirement, "compiledOrResigned": False,
                "launchedOrInstalled": False}
    if not args.create:
        print(json.dumps(dict(evidence, status="READ_ONLY_CANDIDATE_CHECKED"), ensure_ascii=False))
        return
    record = Path(args.record or "")
    if not record.is_absolute() or ".." in record.parts:
        raise RuntimeError("创建安装包须指定新的私有绝对收据路径")
    safety.require_noindex(record)
    prepared = record.with_name(record.stem + "-prepared.json")
    if record.exists() or record.is_symlink() or prepared.exists() or prepared.is_symlink():
        raise RuntimeError("打包收据已存在，不覆盖")
    with backup.directory_fd(record.parent):
        pass
    release = ROOT / "Release"
    with backup.directory_fd(release):
        pass
    output = release / ("GaoJiLing-" + value["version"] + ".dmg")
    checksum = output.with_name(output.name + ".sha256")
    if output.exists() or output.is_symlink() or checksum.exists() or checksum.is_symlink():
        raise RuntimeError("同版本安装包或校验文件已存在；核对后复用，不覆盖或重签")
    work = Path(tempfile.mkdtemp(prefix=".gaojiling-package-existing-", suffix=".noindex", dir=release))
    os.chmod(work, 0o700)
    mount = work / "Mount.noindex"
    mounted = False
    detach_attempted = False
    keep_work = False
    error = None
    evidence.update(work=str(work), output=str(output), status="PREPARING")
    safety.write_json(prepared, evidence)
    try:
        disk = work / "disk"; disk.mkdir(mode=0o700)
        copy = disk / "搞机灵.app"
        run(["/usr/bin/ditto", str(app), str(copy)])
        verify_copy(copy, tree, expected_requirement)
        os.symlink("/Applications", disk / "Applications")
        run(["/bin/cp", str(copy / "Contents/Resources/使用说明.txt"), str(disk / "使用说明.txt")])
        image = work / output.name
        run(["/usr/bin/hdiutil", "create", "-quiet", "-volname", "搞机灵 V" + value["version"], "-srcfolder", str(disk), "-format", "UDZO", str(image)])
        run(["/usr/bin/hdiutil", "verify", "-quiet", str(image)])
        mount.mkdir(mode=0o700)
        mounted = True  # On uncertain attach failure preserve work until a detach succeeds.
        run(["/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(image)])
        verify_copy(mount / "搞机灵.app", tree, expected_requirement)
        if backup.read_regular(mount / "使用说明.txt") != backup.read_regular(app / "Contents/Resources/使用说明.txt"):
            raise RuntimeError("镜像根使用说明与已签候选不同")
        detach_attempted = True
        run(["/usr/bin/hdiutil", "detach", "-quiet", str(mount)])
        mounted = False
        receipt_and_candidate(receipt, args.receipt_sha256)
        if safety.app_identity(app) != original_identity or backup.tree_manifest(app, allow_links=True) != tree:
            raise RuntimeError("打包期间候选发生变化")
        digest = backup.file_digest(image)
        sha_file = work / "checksum"
        sha_bytes = (digest + "  " + output.name + "\n").encode()
        safety.write_private(sha_file, sha_bytes)
        publish_new_file(image, output)
        evidence["outputPublished"] = True
        publish_new_file(sha_file, checksum)
        with backup.directory_fd(release, read=True) as directory:
            os.fsync(directory)
        if backup.file_digest(output) != digest or backup.read_regular(checksum) != sha_bytes:
            raise RuntimeError("发行文件读回不符；保留实际产物供核对")
        evidence.update(status="PACKAGE_VERIFIED", dmgSHA256=digest, dmgBytes=backup.safe_lstat(output).st_size,
                        sourceCopyAndMountedTreeEqual=True, mountedImageDetached=True)
    except Exception as failure:
        error = failure
        evidence.update(status="PACKAGE_INCOMPLETE", error=str(failure))
    finally:
        if mounted:
            if not detach_attempted:
                try:
                    run(["/usr/bin/hdiutil", "detach", "-quiet", str(mount)])
                    mounted = False
                except Exception as failure:
                    evidence["detachError"] = str(failure)
            if mounted:
                keep_work = True
                evidence["mountedWorkRetained"] = True
                if error is None:
                    error = RuntimeError("安装镜像卸载未确认，保留 .noindex 工作目录")
        if not keep_work:
            try:
                shutil.rmtree(work)
            except Exception as failure:
                keep_work = True
                evidence.update(status="PACKAGE_INCOMPLETE", cleanupError=str(failure))
                if error is None:
                    error = failure
        evidence["workRemoved"] = not keep_work
        safety.write_json(record, evidence)
    print(json.dumps(evidence, ensure_ascii=False))
    if error is not None:
        raise error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--receipt-sha256", required=True)
    parser.add_argument("--create", action="store_true", help="Create a verified DMG under a held workspace build lease")
    parser.add_argument("--record", help="New private .noindex JSON result path, required for --create")
    args = parser.parse_args()
    os.umask(0o077)
    execute(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        print("停止打包：" + str(error), file=sys.stderr)
        sys.exit(1)
