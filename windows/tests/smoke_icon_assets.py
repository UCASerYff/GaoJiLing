"""Check exact packaged brand frames and Win32 icon loading across common DPI sizes."""

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import struct
import sys

import pefile
from PIL import Image
from PyInstaller.archive.readers import CArchiveReader


_ICON_HEADER = struct.Struct("<HHH")
_FILE_ENTRY = struct.Struct("<BBBBHHII")
_GROUP_ENTRY = struct.Struct("<BBBBHHIH")
_WINDOWS = Path(__file__).resolve().parents[1]


def icon_entries(contents, entry_type):
    reserved, kind, count = _ICON_HEADER.unpack_from(contents)
    assert reserved == 0 and kind == 1 and count
    for index in range(count):
        width, height, _, _, _, bits, length, value = entry_type.unpack_from(
            contents, _ICON_HEADER.size + index * entry_type.size,
        )
        yield (width or 256, height or 256), bits, length, value


def file_frames(path):
    contents = path.read_bytes()
    frames = {}
    for size, bits, length, offset in icon_entries(contents, _FILE_ENTRY):
        assert size not in frames and bits == 32
        payload = contents[offset:offset + length]
        assert len(payload) == length
        frames[size] = payload
    return frames


def pe_resources(image, resource_type):
    for kind in image.DIRECTORY_ENTRY_RESOURCE.entries:
        if kind.id != resource_type:
            continue
        for name in kind.directory.entries:
            translations = name.directory.entries
            assert len(translations) == 1
            data = translations[0].data.struct
            yield name.id, image.get_data(data.OffsetToData, data.Size)


def executable_frames(path):
    with pefile.PE(str(path), fast_load=True) as image:
        image.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_RESOURCE"]])
        resources = dict(pe_resources(image, 3))  # RT_ICON
        groups = list(pe_resources(image, 14))  # RT_GROUP_ICON
        assert len(groups) == 1, f"Expected one packaged brand icon group in {path.name}"
        frames = {}
        for size, bits, length, resource in icon_entries(groups[0][1], _GROUP_ENTRY):
            assert size not in frames and bits == 32 and len(resources[resource]) == length
            frames[size] = resources[resource]
        return frames


class IconInfo(ctypes.Structure):
    _fields_ = [("icon", wintypes.BOOL), ("x", wintypes.DWORD), ("y", wintypes.DWORD),
                ("mask", wintypes.HBITMAP), ("color", wintypes.HBITMAP)]


class Bitmap(ctypes.Structure):
    _fields_ = [("type", wintypes.LONG), ("width", wintypes.LONG), ("height", wintypes.LONG),
                ("row_bytes", wintypes.LONG), ("planes", wintypes.WORD), ("bits", wintypes.WORD),
                ("pixels", ctypes.c_void_p)]


def api(library, name, result, *arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function


def window_icon_bitmap(icon):
    user = ctypes.WinDLL("user32", use_last_error=True)
    gdi = ctypes.WinDLL("gdi32", use_last_error=True)
    read_icon = api(user, "GetIconInfo", wintypes.BOOL, wintypes.HICON, ctypes.POINTER(IconInfo))
    read_bitmap = api(gdi, "GetObjectW", ctypes.c_int, wintypes.HGDIOBJ, ctypes.c_int, ctypes.c_void_p)
    read_bits = api(gdi, "GetBitmapBits", wintypes.LONG, wintypes.HBITMAP, wintypes.LONG, ctypes.c_void_p)
    delete = api(gdi, "DeleteObject", wintypes.BOOL, wintypes.HGDIOBJ)
    info = IconInfo()
    if not read_icon(icon, ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        bitmap = Bitmap()
        handle = info.color or info.mask
        assert read_bitmap(handle, ctypes.sizeof(bitmap), ctypes.byref(bitmap))
        pixels = ctypes.create_string_buffer(bitmap.row_bytes * bitmap.height)
        assert read_bits(handle, len(pixels), pixels) == len(pixels)
        size = bitmap.width, bitmap.height if info.color else bitmap.height // 2
        return size, pixels.raw
    finally:
        for handle in (info.mask, info.color):
            if handle:
                delete(handle)


def verify_device_sizes(icon_path, frames):
    sys.path.insert(0, str(_WINDOWS / "src"))
    from gaojiling import win32 as win

    for dpi in (96, 120, 144, 168, 192):
        for base in (16, 20, 24, 32, 48):
            physical = (base * dpi + 48) // 96
            assert (physical, physical) in frames, f"No exact frame for {base} DIPs at {dpi} DPI"
        small = win.icon_dimensions(dpi, small=True)
        large = win.icon_dimensions(dpi, small=False)
        assert small == (16 * dpi // 96,) * 2 and large == (32 * dpi // 96,) * 2
        for size in (small, large):
            icon = win.load_sized_icon(icon_path, size)
            if not icon:
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                assert window_icon_bitmap(icon)[0] == size
            finally:
                win.destroy_icon(icon)
        print(f"{dpi * 100 // 96}% ({dpi} DPI): app loader returns exact small {small[0]}x{small[1]}"
              f" and large {large[0]}x{large[1]} package frames.")


def bundled_asset(path, name):
    archive = CArchiveReader(str(path))
    entries = [entry for entry in archive.toc if entry.replace("\\", "/") == "gaojiling_assets/" + name]
    assert len(entries) == 1, f"Missing unique {name} in {path.name}"
    return archive.extract(entries[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ico", type=Path)
    parser.add_argument("executable", type=Path, nargs="+")
    args = parser.parse_args()
    icon = args.ico.resolve(strict=True)
    frames = file_frames(icon)
    assert {(128, 128), (256, 256)} <= frames.keys()
    with Image.open(icon) as image:
        assert image.format == "ICO" and image.info["sizes"] == frames.keys()
        for size in frames:
            frame = image.ico.getimage(size).convert("RGBA")
            assert frame.size == size and frame.getchannel("A").getextrema() == (0, 255)
    original = (_WINDOWS.parent / "Assets" / "AppIcon.png").read_bytes()
    contents = icon.read_bytes()
    for item in args.executable:
        path = item.resolve(strict=True)
        assert executable_frames(path) == frames, f"PE icon differs in {path.name}"
        assert bundled_asset(path, "AppIcon.ico") == contents, f"Runtime icon differs in {path.name}"
        assert bundled_asset(path, "AppIcon.png") == original, f"Brand PNG differs in {path.name}"
        print(f"{path.name}: {len(frames)} PE frames and bundled ICO match output; original brand PNG matches.")
    verify_device_sizes(icon, frames)
    print("DPI-specific Win32 API requests used; the physical display setting did not change.")


if __name__ == "__main__":
    main()
