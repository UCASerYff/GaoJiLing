from pathlib import Path
import sys

from gaojiling.errors import AppError


def asset_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "gaojiling_assets"
    return Path(__file__).resolve().parent / "assets"


def guide_path() -> Path:
    if getattr(sys, "frozen", False):
        return asset_root() / "help.txt"
    return Path(__file__).resolve().parents[2] / "README.md"


def read_asset(name: str) -> bytes:
    path = asset_root() / name
    if name == "AppIcon.png" and not path.is_file():
        path = Path(__file__).resolve().parents[3] / "Assets" / name
        if path.is_file():
            return path.read_bytes()
    if path.parent != asset_root() or not path.is_file():
        raise AppError("没有这个页面资源。")
    return path.read_bytes()
