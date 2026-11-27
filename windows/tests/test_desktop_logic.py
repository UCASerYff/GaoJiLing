import json
from pathlib import Path

import pytest

from gaojiling.autostart import Startup
from gaojiling.errors import AppError


def test_startup_uses_only_its_shortcut_and_reports_windows_policy(tmp_path, monkeypatch):
    executable = (tmp_path / "GaoJiLing.exe").resolve()
    startup_directory = tmp_path / "isolated-startup"
    startup_directory.mkdir()

    def link_command(link: Path, target: Path, operation: str):
        if operation == "write":
            link.write_text(json.dumps([str(target), "--startup"]), encoding="utf-8")
        else:
            return "\n".join(json.loads(link.read_text(encoding="utf-8")))

    startup = Startup(executable, startup_directory, link_command)
    monkeypatch.setattr(startup, "_approved", lambda: None)
    assert startup.status() == {"available": True, "enabled": False, "registered": False, "reason": None}
    startup.set_enabled(True)
    assert startup.status()["enabled"] is True
    monkeypatch.setattr(startup, "_approved", lambda: False)
    assert startup.status()["registered"] is True and startup.status()["enabled"] is False
    startup.set_enabled(False)
    assert not list(startup_directory.iterdir())

    foreign = json.dumps([str(tmp_path / "OtherApp.exe"), "--startup"])
    startup.link.write_text(foreign, encoding="utf-8")
    for requested in (True, False):
        with pytest.raises(AppError, match="归属未确认"):
            startup.set_enabled(requested)
        assert startup.link.read_text(encoding="utf-8") == foreign


def test_floating_rounding_hit_and_content_height():
    pytest.importorskip("tkinter")
    from gaojiling.floating import content_height, get_processes, rounded_contains

    area = (100, 100, 398, 470)
    assert not rounded_contains(area, (101, 101), 20)
    assert rounded_contains(area, (100, 125), 20)
    assert rounded_contains(area, (200, 100), 20)
    assert not rounded_contains(area, (498, 200), 20)
    sample = {"processes": [{"cpuPercent": None}, {"cpuPercent": 6.7}, {"cpuPercent": 1.3}, {"cpuPercent": 0}]}
    assert [item["cpuPercent"] for item in get_processes(sample)] == [6.7, 1.3, 0]
    standard = content_height(sample, {"showSensors": False}, None)
    assert content_height(sample, {"showSensors": True}, {"name": "fixture"}) == standard + 115
