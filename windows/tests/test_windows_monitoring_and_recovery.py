import os
import shutil
import sys
import time
from pathlib import Path

import pytest

from gaojiling.apps import AppInventory
from gaojiling.cleanup import CleanupEngine
from gaojiling.errors import AppError
from gaojiling.events import BatteryNoticeDetector, EventDetector
from gaojiling.filesafety import rename_exclusive
from gaojiling.metrics import _cpu_delta, _group_processes, _network_rates, reading
from gaojiling.store import MonitorStore, default_settings, normalize_settings
from gaojiling.winmetrics import busiest_gpu_engine


def _process(pid, start, cpu, image="C:\\Portable\\Tool.exe", owner="owner", memory=28):
    return {"pid": pid, "name": "Tool.exe", "startTicks": start, "cpuTicks": cpu,
            "path": image, "ownerSID": owner, "memoryBytes": memory, "packageFamily": None}


def test_grouped_total_machine_cpu_needs_matching_process_identities():
    assert _cpu_delta((100, 50), (500, 200)) == (62.5, 400)
    assert _cpu_delta((100, 50), (120, 90)) == (None, None)
    first = [_process(1, 8, 10), _process(2, 9, 10, "C:\\PORTABLE\\Tool.exe")]
    rows, baseline = _group_processes(first, {}, None, 300)
    assert len(rows) == 1 and rows[0]["memoryBytes"] == 56 and rows[0]["cpuPercent"] is None
    second = [_process(1, 8, 30), _process(2, 9, 70), _process(3, 3, 9, None, None, None)]
    rows, _ = _group_processes(second, baseline, 400, 301)
    assert rows[0]["cpuPercent"] == 20 and rows[0]["pids"] == [1, 2]
    assert rows[1]["cpuPercent"] is None and rows[1]["memoryBytes"] is None
    changed = [_process(1, 8, 30), _process(2, 15, 70)]
    rows, _ = _group_processes(changed, baseline, 400, 302)
    assert rows[0]["cpuPercent"] is None


def test_interface_change_never_becomes_a_traffic_spike():
    assert _network_rates({1: (10, 20)}, {1: (50, 30)}, 2) == (20, 5)
    assert _network_rates({1: (10, 20)}, {2: (100, 300)}, 2) == (None, None)
    assert _network_rates({1: (10, 20)}, {1: (9, 30)}, 2) == (None, None)
    assert _network_rates({}, {}, 2) == (None, None)


def test_gpu_uses_the_busiest_physical_engine_after_aggregating_processes():
    gpu = {
        "pid_5_luid_0x0_0x5_phys_0_eng_1_engtype_3D": 38,
        "pid_6_luid_0x0_0x5_phys_0_eng_1_engtype_3D": 30,
        "pid_5_luid_0x0_0x5_phys_0_eng_2_engtype_Copy": 15,
        "pid_7_luid_0x0_0x7_phys_0_eng_1_engtype_3D": 50,
        "unknown": 100,
    }
    assert busiest_gpu_engine(gpu) == 68
    assert busiest_gpu_engine({"unknown": 99}) is None


def test_battery_notices_latch_through_unavailable_readings_and_rearm_after_hysteresis():
    settings = default_settings()
    settings["batteryNoticesEnabled"] = True
    detector = BatteryNoticeDetector()

    def snapshot(percent, temperature=None, charging=False, timestamp=10):
        return {key: reading(value, "", timestamp, "fixture") for key, value in {
            "present": True, "percent": percent, "temperature": temperature, "charging": charging,
        }.items()}

    assert [notice["id"] for notice in detector.evaluate(snapshot(10, 50), settings, 10)] == ["low", "heat"]
    assert detector.evaluate(snapshot(None), settings, 11) == []
    assert detector.evaluate(snapshot(10, 50), settings, 12) == []
    assert detector.evaluate(snapshot(85, 50, charging=True), settings, 60) == []
    assert [notice["id"] for notice in detector.evaluate(snapshot(85, 40, charging=True, timestamp=60), settings, 60)] == ["high"]
    assert [notice["id"] for notice in detector.evaluate(snapshot(10, 50, timestamp=62), settings, 62)] == ["low", "heat"]


def test_event_does_not_infer_zero_free_space_or_swap_from_missing_counters():
    detector = EventDetector()
    for stamp in range(1, 66, 5):
        assert detector.evaluate({"timestamp": stamp, "diskTotal": 1000}) == []
    assert not detector.evaluate({"timestamp": 66, "swapUsed": 600_000_000})
    top = [{"name": "first", "cpuPercent": 10}, {"name": "highest", "cpuPercent": 40}, {"name": "last", "cpuPercent": 20}]
    for stamp in (70, 80, 90):
        assert detector.evaluate({"timestamp": stamp, "cpuPercent": 90, "processes": top}) == []
    events = detector.evaluate({"timestamp": 100, "cpuPercent": 90, "processes": top})
    assert len(events) == 1 and "highest" in events[0]["detail"]


def test_windows_sources_extend_old_settings_and_preserve_known_vs_unknown_history(tmp_path):
    assert normalize_settings({"appearance": "dark"})["batteryNoticesEnabled"] is False
    for invalid in ({"batteryLowPercent": 51}, {"batteryHighTemperature": True}, {"visibleMetricIDs": ["cpu", "cpu"]}):
        with pytest.raises(AppError):
            normalize_settings(invalid)
    store = MonitorStore(tmp_path / "monitor")
    try:
        stamp = time.time()
        store.add_sample({"timestamp": stamp, "corePercents": [0, 10], "networkDown": 0, "processes": [
            {"name": "unknown", "cpuPercent": None, "memoryBytes": None},
            {"name": "known", "cpuPercent": 0, "memoryBytes": 0},
        ]})
        result = store.history(stamp - 1)[0]
        assert result["corePercents"] == [0, 10] and result["networkDown"] == 0
        assert result["processes"][0]["name"] == "known"
        assert result["processes"][0]["cpuPercent"] == result["processes"][0]["memoryBytes"] == 0
        assert result["processes"][1]["cpuPercent"] is None and result["processes"][1]["memoryBytes"] is None
    finally:
        store.close()


def _fixture_trash(tmp_path):
    trash = tmp_path / "bin"
    trash.mkdir()

    def move(path):
        target = trash / path.name
        rename_exclusive(path, target)
        return target
    return move


@pytest.fixture
def isolated_portable_root(tmp_path, monkeypatch):
    # The test runner's private temp directory sits below production AppData.
    # Allow only the isolated fixture paths and keep the production guard in
    # effect everywhere outside them.
    from gaojiling import apps

    protected = apps.is_protected
    monkeypatch.setattr(apps, "is_protected", lambda name, path:
                        None if Path(path).is_relative_to(tmp_path) else protected(name, path))
    return tmp_path


def test_portable_uninstall_rejects_user_data_and_restores_only_same_directory(isolated_portable_root):
    tmp_path = isolated_portable_root
    source = tmp_path / "Portable"
    source.mkdir()
    executable = source / "Fixture.exe"
    shutil.copyfile(sys.executable, executable)
    document = source / "project.docx"
    document.write_text("fixture", encoding="utf-8")
    engine = AppInventory(tmp_path / "journal", _fixture_trash(tmp_path), catalog=[])
    with pytest.raises(AppError, match="程序包"):
        engine.add_portable(source)
    document.unlink()
    item = engine.add_portable(source)
    assert item["selected"] is False and item["entryCount"] == 2
    report = engine.uninstall([item["id"]], lambda _path: False)
    assert report["removedIDs"] == [item["id"]]
    assert engine.history()[0]["restorableCount"] == 1
    source.mkdir()
    assert engine.restore(report["batchID"])["failed"]
    source.rmdir()
    reopened = AppInventory(tmp_path / "journal", engine.trash, catalog=[])
    assert reopened.restore(report["batchID"])["restored"] == [item["id"]]
    assert executable.read_bytes() == Path(sys.executable).read_bytes()
    assert reopened.history()[0]["restorableCount"] == 0


def test_portable_uninstall_rechecks_process_state_after_staging(isolated_portable_root):
    tmp_path = isolated_portable_root
    source = tmp_path / "Portable"
    source.mkdir()
    shutil.copyfile(sys.executable, source / "Fixture.exe")
    called = []

    def never_trash(path):
        called.append(path)
        pytest.fail("recycle must not run with uncertain process status")

    engine = AppInventory(tmp_path / "journal", never_trash, catalog=[])
    item = engine.add_portable(source)
    probes = iter([False, False, None])
    report = engine.uninstall([item["id"]], lambda _path: next(probes))
    assert report["removedIDs"] == [] and report["failed"]
    assert source.is_dir() and called == []


def test_windows_cleanup_scans_exact_owned_caches_and_rolls_back_recycle_failure(tmp_path):
    home = tmp_path / "home"
    local = home / "AppData" / "Local"
    source = local / "Google" / "Chrome" / "User Data" / "Default" / "Cache"
    source.mkdir(parents=True)
    (source / "sample").write_text("fixture", encoding="utf-8")
    other = local / "UnknownVendor"
    other.mkdir()
    old = time.time() - 9 * 86400
    for path in (source / "sample", source, other):
        os.utime(path, (old, old))

    def refused(_):
        raise AppError("fixture Windows recycle refused")

    engine = CleanupEngine(home, tmp_path / "journal", tmp_path / "stage", "windows",
                           running=lambda _owner: False, owner_lookup=lambda _owner: True, trash=refused)
    items = engine.scan()["items"]
    assert [Path(item["displayPath"]) for item in items] == [source]
    report = engine.trash([items[0]["id"]])
    assert report["removedIDs"] == [] and report["failed"]
    assert (source / "sample").read_text(encoding="utf-8") == "fixture" and other.exists()
