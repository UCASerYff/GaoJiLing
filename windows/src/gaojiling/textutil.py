"""显示与 CSV 口径。CPU 文案在基线不可用时不显示 0。"""

import re


def bytes_text(value) -> str:
    if value is None:
        return "—"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "—"
    if number != number or number <= 0 or number == float("inf"):
        return "0 KB"
    units = ["KB", "MB", "GB", "TB"]
    size = number
    # 与常见二进制显示接近：先按 1024 降到 KB 以上。
    size /= 1024
    for unit in units:
        if size < 1024 or unit == units[-1]:
            if size >= 100 or unit == "KB":
                return f"{size:.0f} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.0f} TB"


def rate_text(value) -> str:
    if value is None:
        return "—"
    return bytes_text(value) + "/s"


def percent_text(value, available=True) -> str:
    if not available or value is None:
        return "不可用"
    return f"{float(value):.0f}%"


def duration_text(seconds: float) -> str:
    whole = max(0, int(seconds))
    if whole >= 3600:
        return f"{whole // 3600}小时{(whole % 3600) // 60}分"
    if whole >= 60:
        return f"{whole // 60}分{whole % 60}秒"
    return f"{whole}秒"


def csv_field(value: str) -> str:
    text = "" if value is None else str(value)
    trimmed = text.strip()
    safe = "'" + text if trimmed[:1] in {"=", "+", "-", "@"} else text
    return '"' + safe.replace('"', '""') + '"'


def csv_file(rows: list[list[str]]) -> bytes:
    body = "\r\n".join(",".join(csv_field(cell) for cell in row) for row in rows) + "\r\n"
    return ("\ufeff" + body).encode("utf-8")


_BUNDLE = re.compile(r"^[A-Za-z0-9_-]+$")


def valid_bundle_id(value: str) -> bool:
    parts = value.split(".")
    return len(parts) >= 2 and all(part and _BUNDLE.fullmatch(part) for part in parts)
