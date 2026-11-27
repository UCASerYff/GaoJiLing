"""Build the per-user, x64 Windows Installer package using CPython 3.12's MSI API."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys
import uuid
import warnings

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    import msilib
    from msilib import schema, sequence

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from gaojiling.autostart import SHORTCUT_NAME
from gaojiling.version import BUILD, BUNDLE_ID, MARKETING, display


UPGRADE_CODE = uuid.UUID("cd8b39db-cd72-43fc-ae40-f295ed2ab543")
PRODUCT_VERSION = f"{MARKETING}.{BUILD}"


def code(value):
    return "{" + str(uuid.uuid5(UPGRADE_CODE, value)).upper() + "}"


def file_version(path: Path) -> tuple[str | None, str | None]:
    if path.suffix.casefold() != ".exe":
        return None, None
    read_version = ctypes.WinDLL("msi").MsiGetFileVersionW
    length_pointer = ctypes.POINTER(wintypes.DWORD)
    read_version.argtypes = (wintypes.LPCWSTR, wintypes.LPWSTR, length_pointer,
                             wintypes.LPWSTR, length_pointer)
    read_version.restype = wintypes.UINT
    version = ctypes.create_unicode_buffer(64)
    language = ctypes.create_unicode_buffer(64)
    version_size = wintypes.DWORD(len(version))
    language_size = wintypes.DWORD(len(language))
    result = read_version(str(path), version, ctypes.byref(version_size),
                          language, ctypes.byref(language_size))
    if result != 0 or version.value != f"{PRODUCT_VERSION}.0":
        raise ValueError(f"Unexpected PE file version for {path.name}: {version.value!r} ({result})")
    return version.value, language.value or None


def package(path, files, work):
    path.parent.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    upgrade = "{" + str(UPGRADE_CODE).upper() + "}"
    db = msilib.init_database(str(path), schema, "GaoJiLing", code("version-" + PRODUCT_VERSION),
                               PRODUCT_VERSION, "GaoSeries")
    summary = db.GetSummaryInformation(4)
    summary.SetProperty(msilib.PID_TEMPLATE, "x64;1033")
    summary.SetProperty(msilib.PID_PAGECOUNT, 500)
    # Long filenames, embedded cabinet, non-elevated installation.
    summary.SetProperty(msilib.PID_WORDCOUNT, 10)
    summary.Persist()
    add = lambda table, rows: msilib.add_data(db, table, rows)
    add("Property", [
        ("UpgradeCode", upgrade),
        ("ARPPRODUCTICON", "GaoJiLingIcon.ico"),
        ("ARPINSTALLLOCATION", "[INSTALLDIR]"),
        ("ARPNOMODIFY", "1"),
        ("MSIFASTINSTALL", "3"),
        ("SecureCustomProperties", "GAOISOLATED;INSTALLDIR;GAOOLDVERSION;GAONEWVERSION"),
    ])
    add("LaunchCondition", [
        ('MsiAMD64 AND GAOWINDOWSMAJOR = "#10"', "GaoJiLing requires Windows 10 or 11 x64."),
        ("NOT ALLUSERS", "GaoJiLing is installed for the current user."),
        ("NOT GAONEWVERSION", "A newer version of GaoJiLing is already installed."),
    ])
    add("Upgrade", [
        (upgrade, None, PRODUCT_VERSION, None, 0, None, "GAOOLDVERSION"),
        (upgrade, PRODUCT_VERSION, None, None, 2, None, "GAONEWVERSION"),
    ])
    # MSI's VersionNT64 and WindowsBuild are compatibility values on newer Windows.
    add("AppSearch", [("GAOWINDOWSMAJOR", "GaoWindowsMajor")])
    add("RegLocator", [("GaoWindowsMajor", 2, r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentMajorVersionNumber", 18)])
    actions = {"AppSearch", "FindRelatedProducts", "LaunchConditions", "CostInitialize", "FileCost", "CostFinalize",
               "InstallValidate", "InstallInitialize", "ProcessComponents", "RemoveRegistryValues",
               "RemoveShortcuts", "RemoveFiles", "RemoveFolders", "CreateFolders", "InstallFiles",
               "CreateShortcuts", "WriteRegistryValues", "RegisterUser", "RegisterProduct", "UnpublishFeatures",
               "PublishFeatures", "PublishProduct", "InstallFinalize"}
    installation_order = {"AppSearch": 95, "LaunchConditions": 250}
    add("InstallExecuteSequence", [(action, condition, installation_order.get(action, order))
                                   for action, condition, order in sequence.InstallExecuteSequence if action in actions]
        + [("RemoveExistingProducts", "GAOOLDVERSION", 1510), ("SetInstallLocation", None, 1020)])
    add("InstallUISequence", [(action, condition, installation_order.get(action, order))
                              for action, condition, order in sequence.InstallUISequence
                              if action in {"AppSearch", "FindRelatedProducts", "LaunchConditions", "CostInitialize", "FileCost", "CostFinalize", "ExecuteAction"}])
    add("CustomAction", [("SetInstallLocation", 51, "ARPINSTALLLOCATION", "[INSTALLDIR]")])
    add("Directory", [
        ("TARGETDIR", None, "SourceDir"),
        ("LocalAppDataFolder", "TARGETDIR", "."),
        ("UserPrograms", "LocalAppDataFolder", "Programs"),
        ("VendorFolder", "UserPrograms", "GaoSer~1|GaoSeries"),
        ("INSTALLDIR", "VendorFolder", "GaoJiL~1|GaoJiLing"),
        ("ProgramMenuFolder", "TARGETDIR", "."),
        ("StartupFolder", "TARGETDIR", "."),
    ])
    add("Feature", [("Application", None, "GaoJiLing", "System monitor", 1, 1, "INSTALLDIR", 0)])

    components = []
    records = []
    sources = []
    for index, (item, short_name) in enumerate(files, 1):
        identifier = f"File{index}"
        components.append((identifier, code("file-" + item.name), "INSTALLDIR", 256, None, identifier))
        version, language = file_version(item)
        records.append((identifier, identifier, f"{short_name}|{item.name}", item.stat().st_size,
                        version, language, 0x4000, index))
        sources.append((str(item), identifier))
    components.append(("Registration", code("registration"), "INSTALLDIR", 256 | 4, "NOT GAOISOLATED", "AppRegistration"))
    add("Component", components)
    add("File", records)
    add("FeatureComponents", [("Application", row[0]) for row in components])
    add("Registry", [("AppRegistration", 1, "Software\\GaoSeries\\" + BUNDLE_ID,
                      "InstallDirectory", "[INSTALLDIR]", "Registration")])
    add("Shortcut", [("MainShortcut", "ProgramMenuFolder", "GaoJiLnk|GaoJiLing", "Registration", "[#File1]", None,
                      "GaoJiLing system monitor", None, "GaoJiLingIcon.ico", 0, 1, "INSTALLDIR")])
    add("RemoveFile", [("GaoStartup", "Registration", "GaoSta~1.lnk|" + SHORTCUT_NAME, "StartupFolder", 2)])

    cabinet = work / "payload.cab"
    cabinet.unlink(missing_ok=True)
    msilib.FCICreate(str(cabinet), sources)
    add("Media", [(1, len(records), None, "#Payload.cab", None, None)])
    msilib.add_stream(db, "Payload.cab", str(cabinet))
    icon = work.parent / "AppIcon.ico"
    add("Icon", [("GaoJiLingIcon.ico", msilib.Binary(str(icon)))])
    db.Commit()
    cabinet.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dist", type=Path)
    parser.add_argument("work", type=Path)
    parser.add_argument("notices", type=Path)
    args = parser.parse_args()
    dist = args.dist.resolve()
    output = dist / f"GaoJiLing-{display()}-Windows-x64.msi"
    package(output, [(dist / "GaoJiLing.exe", "GAOJL.EXE"), (dist / "GaoJiLing-cli.exe", "GAOJLCLI.EXE"),
                     (args.notices.resolve(), "NOTICES.TXT")], args.work.resolve())
    print(output.name)
