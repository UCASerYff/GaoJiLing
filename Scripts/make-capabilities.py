#!/usr/bin/env python3
"""Build GaoAction V1 resources from the verified application version."""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile

BUNDLE_ID = "com.gaoseries.GaoJiLing"
PACKAGE_UTI = "com.gaoseries.action-package"


def resources(version, original_info):
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", version):
        raise ValueError("VERSION 必须为 1.00 格式")
    if original_info.get("CFBundleIdentifier") != BUNDLE_ID or original_info.get("CFBundleShortVersionString") != version:
        raise ValueError("Info.plist 的应用标识或版本与构建输入不一致")
    actions = []
    for action, kind in [("storage.inspect", "directory"), ("cleanup.review", None), ("apps.uninstall.review", "application")]:
        properties = {"mode": {"type": "string", "enum": ["metadata", "duplicates"], "default": "metadata",
                              "description": "duplicates 仅预填范围；须本人另行确认本机内容读取，不自动移动文件"}} if action == "storage.inspect" else {}
        actions.append({
            "action": action,
            "parametersSchema": {"type": "object", "properties": properties, "required": [], "additionalProperties": False},
            "supportsItems": False,
            "supportsReferences": kind is not None,
            "referencesSchema": {"type": "array", "minItems": 1 if kind else 0, "maxItems": 1 if kind else 0,
                                 "items": {"type": "object", "properties": {"kind": {"const": kind}}, "required": ["kind"]} if kind else False},
            "requiresUserConfirmation": True,
            "reviewOnly": action != "storage.inspect",
        })
    capabilities = {"schemaVersion": 1, "bundleID": BUNDLE_ID, "appVersion": version, "actions": actions}
    info = copy.deepcopy(original_info)
    documents = info.setdefault("CFBundleDocumentTypes", [])
    imported = info.setdefault("UTImportedTypeDeclarations", [])
    if not isinstance(documents, list) or not isinstance(imported, list):
        raise ValueError("原文档类型声明无效")
    info["CFBundleDocumentTypes"] = [entry for entry in documents if PACKAGE_UTI not in entry.get("LSItemContentTypes", [])] + [{
        "CFBundleTypeName": "GaoAction 动作交接包",
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": [PACKAGE_UTI],
        "LSTypeIsPackage": True,
    }]
    info["UTImportedTypeDeclarations"] = [entry for entry in imported if entry.get("UTTypeIdentifier") != PACKAGE_UTI] + [{
        "UTTypeIdentifier": PACKAGE_UTI,
        "UTTypeDescription": "GaoAction 动作交接包",
        "UTTypeConformsTo": ["com.apple.package"],
        "UTTypeTagSpecification": {"public.filename-extension": ["gaoaction"]},
    }]
    return capabilities, info


def write_atomic(path, contents):
    if path.is_symlink():
        raise ValueError("构建资源不能覆盖符号链接")
    descriptor, temporary = tempfile.mkstemp(prefix=".GaoCapabilities-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents); output.flush(); os.fchmod(output.fileno(), 0o644); os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", type=Path, required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.version_file.is_symlink() or args.info_plist.is_symlink() or args.output.is_symlink():
        raise ValueError("构建输入与输出不能是符号链接")
    version = args.version_file.read_text(encoding="utf-8").strip()
    capabilities, info = resources(version, plistlib.loads(args.info_plist.read_bytes()))
    write_atomic(args.output, (json.dumps(capabilities, ensure_ascii=False, indent=2) + "\n").encode())
    write_atomic(args.info_plist, plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    main()
