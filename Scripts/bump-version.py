#!/usr/bin/env python3
from pathlib import Path
import re

version = Path(__file__).resolve().parent.parent / "VERSION"
current = version.read_text().strip()
if not re.fullmatch(r"\d+\.\d{2}", current):
    raise SystemExit("VERSION 必须为 1.00 格式")
major, minor = map(int, current.split("."))
next_value = major * 100 + minor + 1
new = f"{next_value // 100}.{next_value % 100:02d}"
version.write_text(new + "\n")
print(f"正式版本：{current} → {new}")
