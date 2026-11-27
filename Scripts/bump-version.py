#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import stat
import tempfile
from macos_version import ROOT, read_version


def replace_number(path, value):
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary = tempfile.mkstemp(prefix=".gaojiling-version-", dir=path.parent)
    staged = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(value)
        staged.chmod(mode)
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="递增 macOS 发行版本和独立构建号")
    parser.add_argument("--build-only", action="store_true", help="营销版本对齐时只递增 BUILD")
    arguments = parser.parse_args()
    try:
        version, build = read_version()
        next_build = str(int(build) + 1)
        if arguments.build_only:
            next_version = version
        else:
            major, minor = map(int, version.split("."))
            next_value = major * 100 + minor + 1
            next_version = f"{next_value // 100}.{next_value % 100:02d}"
        build_file = ROOT / "BUILD"
        previous_build = build_file.read_bytes()
        replace_number(build_file, (next_build + "\n").encode("ascii"))
        if next_version != version:
            try:
                replace_number(ROOT / "VERSION", (next_version + "\n").encode("ascii"))
            except OSError:
                replace_number(build_file, previous_build)
                raise
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from None
    print(f"macOS {version} ({build}) → {next_version} ({next_build})")


if __name__ == "__main__":
    main()
