"""Mac JSONEncoder 的 Date 是自 2001-01-01 UTC 起的秒数。SQLite 的 t 列仍是 Unix 秒。"""

from datetime import datetime, timezone

COCOA_UNIX = 978307200.0
UNIX_MIN = -2208988800.0  # 1900-01-01
UNIX_MAX = 32503680000.0  # 3000-01-01


def unix_to_cocoa(unix: float) -> float:
    return float(unix) - COCOA_UNIX


def cocoa_to_unix(cocoa: float) -> float:
    return float(cocoa) + COCOA_UNIX


def check_unix(value: float, field: str) -> float:
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")) or not (UNIX_MIN <= number <= UNIX_MAX):
        raise ValueError(f"{field}不在支持的日期范围（1900–3000 年）。")
    return number


def iso(unix: float) -> str:
    return datetime.fromtimestamp(check_unix(unix, "时间"), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_unix() -> float:
    return datetime.now(timezone.utc).timestamp()
