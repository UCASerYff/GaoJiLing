from pathlib import Path

from gaojiling.errors import AppError


def asset_root() -> Path:
    import sys
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "gaojiling_assets"
    return Path(__file__).resolve().parent / "assets"


def read_asset(name: str) -> bytes:
    path = asset_root() / name
    if path.parent != asset_root() or not path.is_file():
        raise AppError("没有这个页面资源。")
    return path.read_bytes()
