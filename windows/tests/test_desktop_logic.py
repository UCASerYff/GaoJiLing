import json
from pathlib import Path
from types import SimpleNamespace

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
    from gaojiling.floating import PANEL_RADIUS, WIDTH, content_height, panel_layout, rounded_contains

    area = (100, 100, WIDTH, 470)
    assert not rounded_contains(area, (101, 101), PANEL_RADIUS)
    assert rounded_contains(area, (100, 125), PANEL_RADIUS)
    assert rounded_contains(area, (200, 100), PANEL_RADIUS)
    assert not rounded_contains(area, (100 + WIDTH, 200), PANEL_RADIUS)
    sample = {"processes": [{"cpuPercent": 6.7}, {"cpuPercent": 1.3}, {"cpuPercent": 0}]}
    standard = content_height(sample, {"showSensors": False}, None)
    full = panel_layout(WIDTH, sample, {"showSensors": True}, {"name": "fixture"})
    assert full.cpu.right < full.memory.x and full.cpu.y == full.memory.y
    assert full.network[0].right < full.network[1].x and full.network[0].y == full.network[1].y
    assert full.apps.bottom < full.sensors.y < full.task.y < full.height
    assert standard == full.apps.bottom + full.apps.x
    narrow = panel_layout(235, sample, {"showSensors": True}, {"name": "fixture"})
    assert narrow.cpu.bottom < narrow.memory.y < narrow.network[0].y
    assert narrow.network[0].bottom < narrow.network[1].y < narrow.apps.y
    assert narrow.sensors.bottom < narrow.task.y and narrow.height > full.height


def test_floating_reports_zero_and_missing_measurements_separately():
    pytest.importorskip("tkinter")
    from gaojiling.floating import get_processes, memory_percent, panel_status, process_cpu

    sample = {"memoryUsed": 8, "memoryTotal": 32, "timestamp": 100,
              "processes": [{"cpuPercent": 99, "cpuAvailable": False}, {"cpuPercent": 6.7},
                            {"cpuPercent": None}, {"cpuPercent": 0}]}
    assert [process_cpu(item) for item in get_processes(sample)] == [6.7, 0, None]
    assert memory_percent(sample) == 25
    assert memory_percent({"memoryUsed": 0, "memoryTotal": 32}) == 0
    assert memory_percent({"memoryTotal": 32}) is None
    assert panel_status({}, False, False, 100)[0] == "等待采样"
    assert panel_status(sample, False, False, 115)[0] == "实时监控"
    assert panel_status(sample, False, False, 116)[0] == "读数过期"
    assert panel_status(sample, True, False, 116)[0] == "已暂停"
    assert panel_status(sample, True, True, 116)[0] == "处理资料中"


def test_floating_footer_requires_same_enabled_button_at_150_percent():
    pytest.importorskip("tkinter")
    from gaojiling.floating import PanelContent, footer_layout

    panel = PanelContent.__new__(PanelContent)
    panel.width, panel.scale = 265, 1.5
    panel.footer_state = ({}, False, False)
    actions = []
    panel.on_pause = lambda: actions.append("pause")
    panel.on_open = lambda: actions.append("open")
    pause, main = footer_layout(panel.width)
    assert pause.right < main.x

    def event(box):
        return SimpleNamespace(x=round((box.x + 5) * panel.scale), y=round((box.y + 5) * panel.scale))

    panel._footer_press(event(pause))
    panel._footer_release(event(main))
    assert actions == []
    panel._footer_press(event(main))
    panel._footer_release(event(main))
    assert actions == ["open"]
    panel.footer_state = ({}, False, True)
    panel._footer_press(event(pause))
    panel._footer_release(event(pause))
    assert actions == ["open"]
