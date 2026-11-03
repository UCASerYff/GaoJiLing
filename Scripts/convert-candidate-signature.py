#!/usr/bin/env python3
"""Explicit one-time conversion under a held build lease; keep original candidate."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


package = load("gjl_existing_package", HERE / "package-existing.py")
signer = load("gjl_stable_signer", HERE / "sign-app.py")
backup = package.backup


@backup.no_materialization
def execute(args):
    plan_path = Path(args.plan)
    raw = backup.read_regular(plan_path, 2 * 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != args.plan_sha256:
        raise RuntimeError("签名转换计划摘要不符")
    plan = json.loads(raw)
    if plan["team"] != signer.TEAM or plan["identity"] != signer.IDENTITY or plan["requirement"] != signer.REQUIREMENT:
        raise RuntimeError("未使用已批准的身份/Team/完整DR")
    for name, expected in plan["toolHashes"].items():
        if name not in {"sign-app.py", "package-existing.py", "convert-candidate-signature.py"} or backup.file_digest(HERE / name) != expected:
            raise RuntimeError("已审签名工具改变")
    old_path = Path(plan["originalBuildReceipt"])
    old, app, old_requirement = package.receipt_and_candidate(old_path, plan["originalBuildReceiptSHA256"], plan["postBuildChanges"])
    old_tree = backup.tree_manifest(app, allow_links=True)
    old_identity = package.safety.app_identity(app)
    output = Path(plan["candidate"]); record = Path(plan["record"])
    package.safety.require_noindex(output); package.safety.require_noindex(record)
    prepared = record.with_name(record.stem + "-prepared.json")
    if output.exists() or output.is_symlink() or record.exists() or record.is_symlink() or prepared.exists() or prepared.is_symlink():
        raise RuntimeError("新签名候选或收据已存在，不重复重签或覆盖")
    with backup.directory_fd(output.parent): pass
    with backup.directory_fd(record.parent): pass
    signer.check_identity()
    evidence = dict(originalCandidate=str(app), originalCandidateIdentity=old_identity,
                    originalTreeSHA256=backup.digest(old_tree), originalBuildReceipt=str(old_path),
                    originalBuildReceiptSHA256=plan["originalBuildReceiptSHA256"], oldRequirement=old_requirement,
                    output=str(output), plan=str(plan_path), planSHA256=args.plan_sha256, status="BEFORE_COPY_AND_SINGLE_SIGN")
    package.safety.write_json(prepared, evidence)
    package.run(["/usr/bin/ditto", str(app), str(output)])
    package.verify_copy(output, old_tree, old_requirement)
    before_macho = {name: row["sha256"] for name, row in signer.inventory(output).items() if name == "Contents/MacOS/GaoJiLing"}
    # This is the sole intentional resource text change, exactly pinned by the plan.
    usage = output / "Contents/Resources/使用说明.txt"
    change = plan["postBuildChanges"]["使用说明.txt"]
    if backup.file_digest(usage) != change["from"] or backup.file_digest(package.ROOT / "使用说明.txt") != change["to"]:
        raise RuntimeError("候选签名说明的旧/新字节不符；原候选未动")
    package.run(["/bin/cp", str(package.ROOT / "使用说明.txt"), str(usage)])
    changed_tree = backup.tree_manifest(output, allow_links=True)
    if old_tree.keys() != changed_tree.keys() or any(old_tree[name] != changed_tree[name] for name in old_tree if name != "Contents/Resources/使用说明.txt"):
        raise RuntimeError("签名前出现说明文件以外的非预期变更")
    signature, requirement = signer.sign(output)
    if package.safety.app_identity(app) != old_identity or backup.tree_manifest(app, allow_links=True) != old_tree:
        raise RuntimeError("原候选或恢复依据在转换中改变")
    result = dict(old)
    result.update(app=str(output), originalBuildReceipt=str(old_path), originalBuildReceiptSHA256=plan["originalBuildReceiptSHA256"],
                  postBuildChanges=plan["postBuildChanges"], signingConversionPlan=str(plan_path), signingConversionPlanSHA256=args.plan_sha256,
                  designatedRequirementOutput=requirement, actualSignatureOutput=signature,
                  executableSHA256=backup.file_digest(output / "Contents/MacOS/GaoJiLing"),
                  originalMachOSHA256=before_macho, convertedTreeSHA256=backup.digest(backup.tree_manifest(output, allow_links=True)),
                  noRecompile=True, conversionSignedOnce=True, originalCandidateKeptAndReverified=True,
                  codesignStrictVerifiedAfterConversion=True,
                  adHocOldPermissionsNotAutomaticallyTransferred=True, developmentTeam=signer.TEAM,
                  status="DEVELOPMENT_CANDIDATE_VERIFIED_NOT_INSTALLED")
    package.safety.write_json(record, result)
    print(json.dumps(dict(candidate=str(output), receipt=str(record), receiptSHA256=backup.file_digest(record),
                          executableSHA256=result["executableSHA256"], requirement=signer.REQUIREMENT), ensure_ascii=False))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--plan", required=True); p.add_argument("--plan-sha256", required=True)
    args = p.parse_args(); os.umask(0o077)
    try:
        execute(args)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit("停止转换；原候选/资料保持，保留新候选现场：" + str(error))
