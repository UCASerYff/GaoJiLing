#!/usr/bin/env python3
"""Read independent macOS marketing and bundle build versions."""

import argparse
from pathlib import Path
import plistlib
import re


ROOT = Path(__file__).resolve().parent.parent


def read_version(root=ROOT):
    marketing_file, build_file = root / "VERSION", root / "BUILD"
    if marketing_file.is_symlink() or build_file.is_symlink():
        raise ValueError("VERSION 和 BUILD 不能是符号链接")
    marketing = marketing_file.read_text(encoding="ascii").strip()
    build = build_file.read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", marketing):
        raise ValueError("VERSION 必须为 1.00 格式")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("BUILD 必须为独立的正整数")
    return marketing, build


def verify_plist(path, version):
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != version:
        raise ValueError("Info.plist 的版本或构建号与 VERSION / BUILD 不一致")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", type=Path)
    arguments = parser.parse_args()
    try:
        release = read_version()
        if arguments.info_plist:
            verify_plist(arguments.info_plist, release)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from None
    print(*release)
