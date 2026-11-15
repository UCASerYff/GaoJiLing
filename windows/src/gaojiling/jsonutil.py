"""与 Swift JSONEncoder（sortedKeys、省略空可选、斜杠不转义、非 ASCII 转 \\u）对齐的编码器。

摘要对编码后的结构计算，不把原始文件字节直接当签名。日期由调用方先换成 Cocoa 秒。
"""

import json
import math


def dumps(value) -> str:
    return _emit(value)


def _emit(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("数值不是有限数")
        if value.is_integer() and abs(value) < 2**53:
            return str(int(value))
        return format(value, ".16g")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True, separators=(",", ":"))
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(_emit(item) for item in value) + "]"
    if isinstance(value, dict):
        parts = []
        for key in sorted(value):
            item = value[key]
            if item is None:
                continue
            parts.append(_emit(str(key)) + ":" + _emit(item))
        return "{" + ",".join(parts) + "}"
    raise TypeError(f"无法编码 {type(value).__name__}")
