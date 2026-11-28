"""Stage Windows icon resources, version metadata, and redistribution notices."""

from importlib import metadata
from pathlib import Path
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaojiling.version import BUILD, MARKETING, display


# Tray/caption (16), taskbar (20/24), system large (32), and Explorer (48),
# rasterized from the original at each common scale rather than enlarged later.
ICON_SIZES = (16, 20, 24, 25, 28, 30, 32, 35, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256)


def stage_icons(build: Path):
    with Image.open(ROOT.parent / "Assets" / "AppIcon.png") as image:
        original = image.convert("RGBA")
    # The shared artwork includes transparent space for macOS. Crop to its
    # visible plate on Windows and retain the original corners and lettering.
    plate = original.getchannel("A").point(lambda alpha: 255 if alpha >= 128 else 0).getbbox()
    if plate is None:
        raise ValueError("The source icon has no visible plate")
    brand = original.crop(plate)
    brand.save(build / "AppIcon.png")
    sizes = [(size, size) for size in ICON_SIZES]
    remove_halo = [0] * 4 + list(range(4, 256))
    frames = []
    for size in sizes:
        frame = brand.resize(size, Image.Resampling.LANCZOS)
        # Suppress faint resampling halos in the transparent corners.
        frame.putalpha(frame.getchannel("A").point(remove_halo))
        frames.append(frame)
    brand.save(build / "AppIcon.ico", sizes=sizes, append_images=frames)


def main(build: Path):
    stage_icons(build)
    (build / "help.txt").write_bytes((ROOT / "README.md").read_bytes())

    major, minor = map(int, MARKETING.split("."))
    version = f"({major}, {minor}, {BUILD}, 0)"
    (build / "FileVersion.txt").write_text(f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers={version}, prodvers={version}, mask=0x3f, flags=0,
    OS=0x40004, fileType=0x1, subtype=0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('040904b0', [
    StringStruct('CompanyName', 'GaoSeries'),
    StringStruct('FileDescription', 'GaoJiLing'),
    StringStruct('FileVersion', '{display()}'),
    StringStruct('ProductName', 'GaoJiLing'),
    StringStruct('ProductVersion', '{display()}')])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])]
)""", encoding="utf-8")

    notices = [(ROOT.parent / "THIRD-PARTY-NOTICES.txt").read_text(encoding="utf-8")]
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        notices.append("CPython\n\n" + python_license.read_text(encoding="utf-8", errors="replace"))
    for name in ("pyinstaller", "pywebview", "pythonnet", "clr_loader", "bottle", "typing_extensions", "proxy-tools", "cffi"):
        distribution = metadata.distribution(name)
        for entry in distribution.files or ():
            if entry.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")) and ".dist-info/" in entry.as_posix():
                body = entry.locate().read_text(encoding="utf-8", errors="replace")
                notices.append(f"{name} {distribution.version}\n\n{body}")
    (build / "ThirdPartyNotices.txt").write_text("\n\n".join(notices), encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
