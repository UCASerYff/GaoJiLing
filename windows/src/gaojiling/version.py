"""营销版本与 Mac 版 VERSION 同为 1.16。Windows 构建号单独从 1 起算。"""

MARKETING = "1.16"
BUILD = 2
BUNDLE_ID = "com.gaoseries.GaoJiLing"


def display() -> str:
    return f"{MARKETING}+{BUILD}"
