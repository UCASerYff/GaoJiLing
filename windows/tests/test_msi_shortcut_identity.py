from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import warnings

import pytest


@pytest.mark.skipif(sys.platform != "win32", reason="requires Windows Installer")
def test_msi_keeps_start_shortcut_icon_and_matches_runtime_identity(tmp_path, monkeypatch):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        msilib = pytest.importorskip("msilib")
    from PIL import Image
    from gaojiling.version import BUNDLE_ID

    script_path = Path(__file__).resolve().parents[1] / "package_msi.py"
    spec = spec_from_file_location("gaojiling_test_msi_package", script_path)
    packaging = module_from_spec(spec)
    spec.loader.exec_module(packaging)

    # Exercise the real MSI writer with a fixture payload instead of launching an installer.
    executable = tmp_path / "GaoJiLing.exe"
    executable.write_bytes(b"isolated MSI payload")
    monkeypatch.setattr(packaging, "file_version", lambda _: (f"{packaging.PRODUCT_VERSION}.0", "1033"))
    Image.new("RGBA", (32, 32), (0, 0, 0, 255)).save(tmp_path / "AppIcon.ico")
    candidate = tmp_path / "candidate.msi"
    packaging.package(candidate, [(executable, "GAOJL.EXE")], tmp_path / "msi")

    database = msilib.OpenDatabase(str(candidate), msilib.MSIDBOPEN_READONLY)
    view = database.OpenView("SELECT `Shortcut_`, `PropertyKey`, `PropVariantValue` FROM `MsiShortcutProperty`")
    view.Execute(None)
    row = view.Fetch()
    assert (row.GetString(1), row.GetString(2), row.GetString(3)) == ("MainShortcut", "System.AppUserModel.ID", BUNDLE_ID)
    assert view.Fetch() is None
    view.Close()

    view = database.OpenView("SELECT `Target`, `Icon_` FROM `Shortcut` WHERE `Shortcut` = 'MainShortcut'")
    view.Execute(None)
    row = view.Fetch()
    assert (row.GetString(1), row.GetString(2)) == ("[#File1]", "GaoJiLingIcon.ico")
    view.Close()
