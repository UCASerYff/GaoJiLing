import os
import subprocess
from pathlib import Path

import pytest

from gaojiling.filemeta import checked_stat
from gaojiling.filesafety import owned_by_current_user


@pytest.fixture
def own_fixture_files(tmp_path):
    def ensure(*paths):
        for path in paths:
            path = Path(os.path.abspath(path))
            assert path != tmp_path and path.is_relative_to(tmp_path)
            info = checked_stat(path)
            if owned_by_current_user(path, info):
                continue
            if os.name == "nt":
                from gaojiling.winmetrics import current_owner_sid

                # Elevated Windows runners may give new files to Administrators.
                # Set ownership on each named synthetic object only.
                sid = current_owner_sid()
                assert sid, "Cannot determine the test user's Windows SID"
                icacls = Path(os.environ["SystemRoot"]) / "System32" / "icacls.exe"
                result = subprocess.run([str(icacls), str(path), "/setowner", f"*{sid}", "/L", "/Q"],
                                        capture_output=True, timeout=15)
                assert result.returncode == 0, f"Could not set fixture owner for {path.name}"
            assert owned_by_current_user(path, checked_stat(path)), f"Unexpected fixture owner for {path.name}"
    return ensure
