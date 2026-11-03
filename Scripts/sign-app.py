#!/usr/bin/env python3
"""Single-component production signer. No ad-hoc fallback or deep re-signing."""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

IDENTITY = "A15B2B2D22B018CBC842063C9A8A589946647524"
TEAM = "5G96498KGJ"
BID = "com.gaoseries.GaoJiLing"
REQUIREMENT = 'identifier "' + BID + '" and anchor apple generic and certificate leaf[subject.OU] = "' + TEAM + '"'
spec = importlib.util.spec_from_file_location("gjl_sign_safety", Path(__file__).with_name("release-safety.py"))
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def check_identity():
    result = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    rows = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', result.stdout, re.M)
    if not any(key.upper() == IDENTITY and name.startswith("Apple Development:") for key, name in rows):
        raise RuntimeError("已授权 Apple Development 有效私钥身份不可用；不降级 ad-hoc，不更换身份")


def describe(app):
    detail = run(["/usr/bin/codesign", "-dvv", str(app)])
    text = detail.stdout + detail.stderr
    match = re.search(r"flags=0x([0-9a-fA-F]+)", text)
    ent = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True)
    if ent.returncode != 0:
        raise RuntimeError("无法读取原 entitlements，不猜空权限")
    raw = ent.stdout
    if not raw.strip() and b"<?xml" in ent.stderr:
        raw = ent.stderr[ent.stderr.index(b"<?xml"):]
        end = raw.find(b"</plist>")
        if end >= 0:
            raw = raw[:end + len(b"</plist>")]
    entitlements = plistlib.loads(raw) if raw.strip() else {}
    if not isinstance(entitlements, dict) or match is None:
        raise RuntimeError("原签名权限或 flags 无效")
    return text, int(match.group(1), 16), entitlements


def inventory(app):
    tree = safety.backup.tree_manifest(app, allow_links=True)
    macho = []
    magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for name, row in tree.items():
        if row["type"] == "file" and safety.backup.read_regular(app / name)[:4] in magic:
            macho.append(name)
    if macho != ["Contents/MacOS/GaoJiLing"]:
        raise RuntimeError("MachO 库存不再是单一已核主程序；须逐组件计划，禁止 deep 重签")
    return tree


def sign(app, new_build=False):
    check_identity()
    safety.require_noindex(app)
    if safety.info(app).get("CFBundleIdentifier") != BID:
        raise RuntimeError("程序标识不符")
    before = inventory(app)
    if new_build:
        probe = subprocess.run(["/usr/bin/codesign", "-dvv", str(app)], capture_output=True, text=True)
        if probe.returncode == 0:
            # Apple Silicon's linker may embed an ad-hoc MachO signature.
            # It is not a previously sealed distribution bundle.
            text, flags, entitlements = describe(app)
            if "Signature=adhoc" not in text or (app / "Contents/_CodeSignature").exists():
                raise RuntimeError("新编译入口不重签已有正式签名包")
        elif "not signed at all" in probe.stdout + probe.stderr:
            flags, entitlements = 0, {}
        else:
            raise RuntimeError("未明确识别新编译签名状态，不把读取失败当空权限")
    else:
        _, flags, entitlements = describe(app)
    # Ad-hoc / freshly linker-signed bits describe the old signing mode,
    # rather than runtime protections to carry into a certificate signature.
    expected_flags = flags & ~0x2
    if new_build:
        expected_flags &= ~0x20000
    with tempfile.TemporaryDirectory(prefix="gjl-entitlements-", suffix=".noindex", dir="/private/tmp") as temporary:
        command = ["/usr/bin/codesign", "--force", "--sign", IDENTITY, "--identifier", BID,
                   "--timestamp=none", "--options", hex(expected_flags), "--requirements", "=designated => " + REQUIREMENT]
        if entitlements:
            path = Path(temporary) / "entitlements.plist"
            path.write_bytes(plistlib.dumps(entitlements)); os.chmod(path, 0o600)
            command += ["--entitlements", str(path)]
        run(command + [str(app)])
    safety.signature_valid(app)
    text, actual_flags, actual_entitlements = describe(app)
    requirement = run(["/usr/bin/codesign", "-d", "-r-", str(app)])
    lines = [x.split("designated =>", 1)[1].strip() for x in (requirement.stdout + requirement.stderr).splitlines() if "designated =>" in x]
    if not re.search(r"^TeamIdentifier=" + TEAM + r"$", text, re.M) or "Authority=Apple Development:" not in text or lines != [REQUIREMENT] or actual_flags != expected_flags or actual_entitlements != entitlements:
        raise RuntimeError("实际 Team、完整DR、flags 或 entitlements 不符，保留候选，不安装")
    after = inventory(app)
    allowed = {"Contents/MacOS/GaoJiLing", "Contents/_CodeSignature", "Contents/_CodeSignature/CodeResources"}
    if (set(before) ^ set(after)) - (allowed if new_build else set()) or any(before[name] != after.get(name) for name in before if name not in allowed):
        raise RuntimeError("签名过程改动非签名资源，保留候选，不安装")
    return text, requirement.stdout + requirement.stderr


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--check-identity", action="store_true")
    p.add_argument("--app", type=Path)
    p.add_argument("--new-build", action="store_true", help="Only a just-compiled, explicitly unsigned application")
    args = p.parse_args()
    if args.app:
        sign(args.app.absolute(), new_build=args.new_build)
        print("PASS: Apple Development Team " + TEAM + "; stable DR; original entitlements/flags retained")
    elif args.check_identity:
        check_identity()
        print("PASS: authorized signing identity available")
    else:
        p.error("选择 --check-identity 或 --app")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit("停止签名：" + str(error))
