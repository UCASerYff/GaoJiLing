import json
import os
import sqlite3
import stat
import struct
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaojiling.backup import build_backup, load_backup, validate_backup, MAX_BYTES
from gaojiling.cleanup import CleanupEngine
from gaojiling.csvexport import events_csv, history_csv
from gaojiling.duplicates import DuplicateEngine
from gaojiling.errors import AppError
from gaojiling.events import EventDetector, sampling_interval
from gaojiling.exchange import ExchangeInbox, validate
from gaojiling.exitpolicy import ExitPolicy
from gaojiling.filesafety import send_to_trash
from gaojiling.geometry import PanelAutoCollapse, dragging_handle
from gaojiling.memory import missing_report, own_report, system_cache_report
from gaojiling.network import diagnose, validate_host
from gaojiling.ntfs import analyze_image, extract
from gaojiling.service import Service
from gaojiling.storageanal import analyze, compare_history
from gaojiling.store import MonitorStore
from gaojiling.textutil import csv_field, percent_text
from gaojiling.version import display
from gaojiling.volumes import collect
from gaojiling.web import serve


def test_non_windows_trash_refuses_instead_of_deleting(tmp_path):
    target = tmp_path / "item"
    target.write_text("keep", encoding="utf-8")
    if os.name == "nt":
        return
    with pytest.raises(AppError, match="废纸篓"):
        send_to_trash(target)
    assert target.read_text(encoding="utf-8") == "keep"


def test_version_matches_mac_marketing_version():
    assert display() == "1.16+1"


def test_sampling_interval_slows_down_only_in_the_background():
    assert sampling_interval(2, True, False, False, False, False) == 2
    assert sampling_interval(2, False, False, False, True, False) == 5
    assert sampling_interval(2, False, False, False, False, False) == 10


def test_cpu_text_does_not_show_zero_without_a_baseline():
    assert percent_text(None, available=False) == "不可用"
    assert percent_text(12.2) == "12%"


def test_csv_escapes_formulas_and_uses_bom(tmp_path):
    assert csv_field("  =SUM(A1)") == "\"'  =SUM(A1)\""
    sample = {"timestamp": 1_700_000_000, "cpuPercent": 12.5, "memoryUsed": 1024, "memoryTotal": 2048,
              "memoryPressure": "正常", "memoryCompressed": None, "swapUsed": 0, "diskFree": 10}
    text = history_csv([sample]).decode("utf-8")
    assert text.startswith("\ufeff")
    assert "\r\n" in text
    assert "12.50" in text
    events = events_csv([{"date": 1_700_000_000, "title": "=HYPERLINK(\"x\")", "detail": "说明", "severity": "提醒", "kind": "cpu"}])
    assert b"\r\n" in events
    assert "'=HYPERLINK" in events.decode("utf-8")


def test_unavailable_sensor_is_not_stored_as_zero(tmp_path):
    store = MonitorStore(tmp_path)
    store.add_sample({"timestamp": time.time(), "cpuPercent": None, "memoryUsed": None, "memoryTotal": None,
                      "memoryCompressed": None, "cpuTemperature": None, "memoryPressure": "未知", "thermalState": "未知",
                      "batteryCharging": False, "processes": []})
    saved = store.history(0)[0]
    assert saved["cpuPercent"] is None
    assert saved["cpuTemperature"] is None
    assert saved["memoryCompressed"] is None


def test_backup_roundtrip_and_refuses_a_bad_digest(tmp_path):
    now = 1_700_000_000
    sample = {"timestamp": now, "cpuPercent": 12.5, "memoryUsed": 100, "memoryTotal": 200, "memoryPressure": "正常",
              "swapUsed": 0, "diskFree": 50, "diskTotal": 80, "batteryCharging": False, "thermalState": "未知",
              "uptime": 3, "processCount": 1, "processes": [{"name": "编辑器", "cpuPercent": 1, "memoryBytes": 10, "pids": [4]}]}
    event = {"id": str(uuid.uuid4()).upper(), "date": now, "title": "磁盘空间不足", "detail": "剩余很少", "severity": "关注", "kind": "disk"}
    session = {"id": str(uuid.uuid4()).upper(), "name": "编译", "start": now, "end": now + 5, "peakCPU": 10,
               "peakMemory": 20, "sampleCount": 1, "cpuTotal": 10}
    settings = MonitorStore(tmp_path / "empty").settings
    document = build_backup([sample], [event], [session], settings, {"GaoJiLing.EdgeHandle.verticalRatio": "0.4"}, now)
    path = tmp_path / "backup.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    loaded = load_backup(path)
    assert loaded["samples"][0]["cpuPercent"] == 12.5
    assert loaded["events"][0]["title"] == "磁盘空间不足"
    raw = json.loads(path.read_text(encoding="utf-8"))
    raw["sha256"] = "0" * 64
    with pytest.raises(AppError, match="SHA-256"):
        validate_backup(raw)
    huge = tmp_path / "huge.json"
    with huge.open("wb") as handle:
        handle.truncate(MAX_BYTES + 1)
    with pytest.raises(AppError, match="256"):
        load_backup(huge)


def test_restore_does_not_replace_a_saved_horizontal_position(tmp_path):
    store = MonitorStore(tmp_path)
    store.save_panel({"horizontalRatio": 0.25, "verticalRatio": 0.4})
    service = Service(tmp_path, home=tmp_path, collector=object())
    service.store = store
    document = build_backup([], [], [], store.settings, {"GaoJiLing.EdgeHandle.verticalRatio": "0.8"}, time.time())
    path = tmp_path / "panel.json.bak"
    path.write_bytes(__import__("gaojiling.backup", fromlist=["backup_bytes"]).backup_bytes(document))
    service.restore_backup(path, True)
    assert store.panel["horizontalRatio"] == 0.25
    assert store.panel["verticalRatio"] == 0.8


def test_corrupt_database_and_settings_are_not_replaced(tmp_path):
    broken = tmp_path / "broken"
    broken.mkdir()
    target = broken / "monitor.sqlite"
    target.write_bytes(b"not a database")
    store = MonitorStore(broken)
    assert store.db is None
    assert target.read_bytes() == b"not a database"

    good = tmp_path / "good"
    first = MonitorStore(good)
    first.close()
    connection = sqlite3.connect(good / "monitor.sqlite")
    connection.execute("UPDATE preferences SET payload=?", ("{",))
    connection.commit()
    connection.close()
    reopened = MonitorStore(good)
    assert reopened.settings_writable is False
    with pytest.raises(AppError, match="暂不覆盖"):
        reopened.update_settings({"appearance": "dark"})
    connection = sqlite3.connect(good / "monitor.sqlite")
    assert connection.execute("SELECT payload FROM preferences").fetchone()[0] == "{"


def test_interrupted_session_ends_at_the_last_real_observation(tmp_path):
    store = MonitorStore(tmp_path)
    store.save_session({"id": str(uuid.uuid4()).upper(), "name": "渲染", "start": 1_700_000_000, "end": None,
                        "peakCPU": 1, "peakMemory": 2, "sampleCount": 1, "cpuTotal": 1, "lastObserved": 1_700_000_040})
    store.close()
    reopened = MonitorStore(tmp_path)
    session = reopened.sessions()[0]
    assert session["interrupted"] is True
    assert session["end"] == 1_700_000_040


def test_prune_keeps_one_real_sample_per_old_minute(tmp_path):
    store = MonitorStore(tmp_path)
    now = time.time()
    base = int((now - 2 * 86400) // 60) * 60
    older = now - 8 * 86400
    for stamp in (older, base, base + 10, now - 60):
        store.add_sample({"timestamp": stamp, "cpuPercent": 1, "memoryPressure": "正常", "batteryCharging": False,
                          "memoryUsed": 1, "memoryTotal": 2, "thermalState": "未知", "processes": []})
    kept = [item["timestamp"] for item in store.history(0)]
    assert older not in kept
    assert base in kept
    assert base + 10 not in kept
    assert any(abs(item - (now - 60)) < 1 for item in kept)


def test_clearing_one_category_leaves_the_others(tmp_path):
    service = Service(tmp_path, home=tmp_path, collector=object())
    service.sample_once(_sample(time.time()))
    service.store.add_event({"date": time.time(), "title": "事件", "detail": "d", "severity": "提醒", "kind": "cpu"})
    service.clear_data("events")
    assert service.store.events() == []
    assert service.store.history(0)


def test_events_need_a_sustained_interval_and_reset_after_a_gap():
    detector = EventDetector()
    start = 1_700_000_000
    assert detector.evaluate(_sample(start, cpu=90)) == []
    assert detector.evaluate(_sample(start + 10, cpu=90)) == []
    assert detector.evaluate(_sample(start + 20, cpu=90)) == []
    found = detector.evaluate(_sample(start + 30, cpu=90))
    assert found and found[0]["kind"] == "cpu"
    assert detector.evaluate(_sample(start + 100, cpu=99)) == []


def test_edge_handle_snaps_only_within_32_points():
    visible = {"x": 0, "y": 0, "width": 1000, "height": 800}
    snapped = dragging_handle({"x": 10, "y": 400}, {"x": 0, "y": 0}, visible)
    free = dragging_handle({"x": 100, "y": 400}, {"x": 0, "y": 0}, visible)
    assert snapped["x"] == 0
    assert free["x"] == 100


def test_panel_closes_on_an_outside_click_and_keeps_the_opening_grace():
    panel = PanelAutoCollapse()
    panel.opened(0)
    assert panel.should_collapse(0.2, False) is False
    assert panel.mouse_down(0, False) is True
    panel.opened(0)
    assert panel.should_collapse(1.0, False, pointer_in_bridge=True) is False
    assert panel.should_collapse(1.3, False) is False
    assert panel.should_collapse(1.5, False) is True


def test_exit_policy_skips_unknown_save_state_and_protected_apps():
    policy = ExitPolicy()
    rule = {"id": "rule", "enabled": True, "bundleID": "com.example.timer", "path": "/Apps/Timer.app", "name": "Timer",
            "trigger": "后台时长", "minutes": 1, "cooldownSeconds": 1800, "memoryBytes": 16_777_216}
    observation = {"identity": (10, 5, 501), "bundleID": rule["bundleID"], "path": rule["path"], "isFrontmost": False,
                   "saveState": "unknown", "observedAt": 1000}
    policy.observe([observation], 1000)
    assert policy.evaluate(rule, observation, 1000, 501, True, False)["eligible"] is False
    observation["saveState"] = "clean"
    for moment in (1000, 1020, 1040, 1060):
        observation["observedAt"] = moment
        policy.observe([observation], moment)
    assert policy.evaluate(rule, observation, 1060, 501, True, False)["eligible"] is True
    observation["isFrontmost"] = True
    policy.observe([observation], 1060)
    assert "前台" in policy.evaluate(rule, observation, 1060, 501, True, False)["reason"]
    chrome = dict(rule, bundleID="com.google.chrome", path="/Apps/Chrome.app", name="Chrome")
    observation["bundleID"] = chrome["bundleID"]
    observation["path"] = chrome["path"]
    observation["isFrontmost"] = False
    policy.observe([observation], 1060)
    assert "浏览器" in policy.evaluate(chrome, observation, 1060, 501, True, False)["reason"]


def _sample(stamp, cpu=10):
    return {"timestamp": stamp, "cpuPercent": cpu, "memoryUsed": 100, "memoryTotal": 200, "memoryCompressed": 0,
            "swapUsed": 0, "memoryPressure": "正常", "diskFree": 100, "diskTotal": 200, "batteryCharging": False,
            "thermalState": "未知", "processes": [{"name": "app", "cpuPercent": 3, "cpuAvailable": True, "memoryBytes": 4, "pids": [1]}]}


def _touch(path: Path, age: float):
    moment = time.time() - age
    os.utime(path, (moment, moment))


def test_cleanup_lists_only_old_inactive_caches_and_restores_without_overwrite(tmp_path):
    home = tmp_path / "home"
    cache = home / "Library" / "Caches" / "com.example.tool"
    cache.mkdir(parents=True)
    (cache / "data").write_text("old", encoding="utf-8")
    _touch(cache / "data", 8 * 86400)
    _touch(cache, 8 * 86400)
    apple = home / "Library" / "Caches" / "com.apple.finder"
    apple.mkdir()
    _touch(apple, 8 * 86400)
    link = home / "Library" / "Caches" / "com.example.link"
    link.symlink_to(cache)
    running = {}
    trash_dir = tmp_path / "trash"
    trash_dir.mkdir()

    def trash(path: Path):
        destination = trash_dir / path.name
        os.rename(path, destination)
        return destination

    engine = CleanupEngine(home, tmp_path / "journal", tmp_path / "stage", "darwin",
                           running=lambda owner: running.get(owner, False), owner_lookup=lambda owner: True, trash=trash)
    result = engine.scan()
    names = [item["name"] for item in result["items"]]
    assert "com.example.tool" in names
    assert "com.apple.finder" not in names
    assert "com.example.link" not in names
    running["com.example.tool"] = True
    assert engine.scan()["items"] == []
    running["com.example.tool"] = False
    chosen = engine.scan()["items"][0]["id"]
    report = engine.trash([chosen])
    assert report["removedIDs"] == [chosen]
    assert "不是已释放" in report["message"]
    assert (tmp_path / "journal" / "journal.json").read_text(encoding="utf-8").count("trashed") == 1
    original = home / "Library" / "Caches" / "com.example.tool"
    original.mkdir()
    (original / "new").write_text("new", encoding="utf-8")
    restored = engine.restore(report["batchID"])
    assert restored["failed"]
    assert (original / "new").read_text(encoding="utf-8") == "new"


def test_cleanup_stops_when_the_journal_cannot_be_read(tmp_path):
    journal = tmp_path / "Cleanup"
    journal.mkdir()
    (journal / "journal.json").write_text("{", encoding="utf-8")
    engine = CleanupEngine(tmp_path, journal, tmp_path / "stage", "windows", lambda _owner: False, lambda _owner: True, lambda path: path)
    with pytest.raises(AppError, match="无法读取"):
        engine.scan()
    assert (journal / "journal.json").read_text(encoding="utf-8") == "{"


def test_storage_analysis_does_not_read_file_contents_or_follow_links(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    secret = root / "secret.bin"
    secret.write_bytes(b"SECRET-CONTENTS")
    link = root / "jump"
    link.symlink_to(secret)
    excluded = root / "skip"
    excluded.mkdir()
    (excluded / "big.bin").write_bytes(b"x" * 200_000)
    result = analyze(root, exclusions=[str(excluded)])
    assert "SECRET-CONTENTS" not in json.dumps(result)
    assert result["complete"] is False
    assert result["tree"]["allocatedBytes"] < 200_000
    history = [{"scopeKey": result["scopeKey"], "complete": False, "allocatedBytes": 10},
               {"scopeKey": result["scopeKey"], "complete": True, "allocatedBytes": 20},
               {"scopeKey": result["scopeKey"], "complete": True, "allocatedBytes": 35}]
    trend = compare_history(history, result["scopeKey"])
    assert trend["deltaAllocatedBytes"] == 15
    assert trend["partialOmitted"] == 1


def test_duplicates_keep_one_and_do_not_count_a_hard_link_twice(tmp_path):
    scope = tmp_path / "scope"
    scope.mkdir()
    first = scope / "a.bin"
    second = scope / "b.bin"
    first.write_bytes(b"same-bytes")
    second.write_bytes(b"same-bytes")
    os.utime(first, (1_000, 1_000))
    os.utime(second, (2_000, 2_000))
    linked = scope / "link.bin"
    os.link(first, linked)
    trash_dir = tmp_path / "trash"
    trash_dir.mkdir()

    def trash(path):
        destination = trash_dir / path.name
        os.rename(path, destination)
        return destination

    engine = DuplicateEngine(tmp_path / "dup", tmp_path / "stage", tmp_path, trash)
    with pytest.raises(AppError, match="另行确认"):
        engine.scan(scope, False)
    result = engine.scan(scope, True)
    assert result["complete"] is True
    assert len(result["groups"]) == 1
    assert all(len(item["paths"]) == 1 for item in []) 
    keeper = result["groups"][0]["suggestedKeeperID"]
    moving = [item["id"] for item in result["groups"][0]["files"] if item["id"] != keeper]
    report = engine.move(moving)
    assert report["removedIDs"] == moving
    assert first.exists()
    assert not second.exists()
    second.write_bytes(b"newer")
    restored = engine.restore(report["batchID"])
    assert restored["failed"]
    assert second.read_bytes() == b"newer"


def test_duplicate_scan_with_a_symlink_cannot_move(tmp_path):
    scope = tmp_path / "scope"
    scope.mkdir()
    (scope / "a.bin").write_bytes(b"same-bytes")
    (scope / "b.bin").write_bytes(b"same-bytes")
    (scope / "shortcut").symlink_to(scope / "a.bin")
    engine = DuplicateEngine(tmp_path / "dup", tmp_path / "stage", tmp_path, lambda path: path)
    result = engine.scan(scope, True)
    assert result["complete"] is False
    with pytest.raises(AppError, match="完整"):
        engine.move(["anything"])


def test_volumes_do_not_read_capacity_for_unknown_or_removable_disks():
    class Provider:
        source = "测试"

        def list_volumes(self):
            return ["fixed", "usb", "mystery"]

        def classify(self, volume):
            if volume == "fixed":
                return {"isLocal": True, "isInternal": True, "isRemovable": False, "isEjectable": False, "isNetwork": False}
            if volume == "usb":
                return {"isLocal": True, "isInternal": False, "isRemovable": True, "isEjectable": True, "isNetwork": False}
            return {"isLocal": None, "isInternal": None, "isRemovable": None, "isEjectable": None, "isNetwork": None}

        def details(self, volume):
            assert volume == "fixed"
            return {"name": "系统", "format": "NTFS", "readOnly": False, "totalBytes": 100, "availableBytes": None, "capabilities": []}

    result = collect(Provider())
    assert [item["id"] for item in result["volumes"]] == ["fixed"]
    assert result["volumes"][0]["availableBytes"] is None
    assert "availableBytes" in result["volumes"][0]["unavailableFields"]
    assert result["skipped"]["externalOrRemovable"] == 1
    assert result["skipped"]["unknown"] == 1


def _record(slot, sequence, flags, attributes):
    raw = bytearray(1024)
    raw[0:4] = b"FILE"
    struct.pack_into("<H", raw, 4, 0x30)
    struct.pack_into("<H", raw, 6, 3)
    struct.pack_into("<H", raw, 16, sequence)
    struct.pack_into("<H", raw, 18, 1)
    struct.pack_into("<H", raw, 20, 0x38)
    struct.pack_into("<H", raw, 22, flags | 1)
    cursor = 0x38
    for attribute in attributes:
        raw[cursor:cursor + len(attribute)] = attribute
        cursor += len(attribute)
    struct.pack_into("<I", raw, cursor, 0xFFFFFFFF)
    struct.pack_into("<I", raw, 24, cursor + 4)
    struct.pack_into("<I", raw, 28, 1024)
    raw[0x30:0x32] = b"\xCD\xAB"
    raw[0x32:0x36] = raw[510:512] + raw[1022:1024]
    raw[510:512] = b"\xCD\xAB"
    raw[1022:1024] = b"\xCD\xAB"
    return bytes(raw)


def _resident(kind, value):
    value_offset = 24
    length = (value_offset + len(value) + 7) & ~7
    blob = bytearray(length)
    struct.pack_into("<I", blob, 0, kind)
    struct.pack_into("<I", blob, 4, length)
    struct.pack_into("<I", blob, 16, len(value))
    struct.pack_into("<H", blob, 20, value_offset)
    blob[value_offset:value_offset + len(value)] = value
    return bytes(blob)


def _file_name(parent, sequence, name):
    encoded = name.encode("utf-16le")
    data = bytearray(66 + len(encoded))
    struct.pack_into("<Q", data, 0, parent | (sequence << 48))
    data[64] = len(name)
    data[66:66 + len(encoded)] = encoded
    return bytes(data)


def test_ntfs_image_lists_a_resident_file_and_refuses_to_overwrite(tmp_path):
    records = [b"\x00" * 1024 for _ in range(5)]
    records.append(_record(5, 1, 0x02, [_resident(0x30, _file_name(5, 1, "."))]))
    payload = b"hello-ntfs"
    records.append(_record(6, 1, 0x01, [
        _resident(0x30, _file_name(5, 1, "readme.txt")),
        _resident(0x80, payload),
    ]))
    image = bytearray(4096 + len(records) * 1024)
    image[3:11] = b"NTFS    "
    struct.pack_into("<H", image, 11, 512)
    image[13] = 8
    struct.pack_into("<Q", image, 40, len(image) // 512)
    struct.pack_into("<Q", image, 48, 1)
    struct.pack_into("<b", image, 64, -10)
    image[4096:4096 + len(records) * 1024] = b"".join(records)
    path = tmp_path / "sample.img"
    path.write_bytes(image)
    with pytest.raises(AppError, match="同意"):
        analyze_image(path, False)
    analysis = analyze_image(path, True)
    names = {entry["name"]: entry for entry in analysis["entries"]}
    assert analysis["complete"] is True
    assert analysis["directoryInventory"] is False
    assert names["readme.txt"]["canExtract"] is True
    assert names["readme.txt"]["pathComponents"] == ["readme.txt"]
    destination = tmp_path / "out.bin"
    extracted = extract(path, analysis, names["readme.txt"]["id"], destination, True)
    assert extracted["bytes"] == len(payload)
    assert destination.read_bytes() == payload
    with pytest.raises(AppError, match="已存在"):
        extract(path, analysis, names["readme.txt"]["id"], destination, True)


def test_network_diagnosis_uses_injected_lookups_and_rejects_urls():
    with pytest.raises(AppError):
        validate_host("https://example.com/path")
    checks = diagnose(
        "example.com",
        resolver=lambda host: ["93.184.216.34"] if host == "example.com" else [],
        gateway=lambda: "192.0.2.1",
        probe=lambda ip: (None, f"{ip} · 未收到可确认响应"),
        https=lambda host: (True, 200, 12, None),
    )
    assert checks[1]["success"] is True
    assert checks[-1]["success"] is True


def test_memory_policy_stops_when_the_snapshot_is_missing_and_does_not_purge():
    assert missing_report()["executed"] is False
    assert own_report(None, True, 10)["executed"] is False
    report = system_cache_report()
    assert report["executed"] is False
    assert "purge" in report["message"]


def _manifest(action="cleanup.review", **changes):
    now = datetime.now(timezone.utc)
    document = {
        "schemaVersion": 1, "kind": "request", "requestID": str(uuid.uuid4()).upper(),
        "sourceBundleID": "com.example.sender", "targetBundleID": "com.gaoseries.GaoJiLing",
        "action": action, "createdAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": (now + timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nonce": __import__("base64").b64encode(os.urandom(32)).decode("ascii"),
        "items": [], "references": [], "parameters": {},
    }
    document.update(changes)
    return json.dumps(document).encode("utf-8")


def test_exchange_package_must_contain_only_the_manifest_and_payload(tmp_path):
    inbox = ExchangeInbox(tmp_path / "inbox")
    package = tmp_path / "sample.gaoaction"
    (package / "payload").mkdir(parents=True)
    (package / "manifest.json").write_bytes(_manifest())
    record = inbox.receive_package(package)
    assert record["phase"] == "received"
    (package / "extra.txt").write_text("no", encoding="utf-8")
    with pytest.raises(AppError, match="仅含"):
        inbox.receive_package(package)


def test_exchange_open_is_not_completion_and_replays_are_not_executed_twice(tmp_path):
    inbox = ExchangeInbox(tmp_path)
    payload = _manifest()
    first = inbox.receive(payload)
    second = inbox.receive(payload)
    assert first["id"] == second["id"]
    assert len(inbox.records) == 1
    opened = inbox.open_request(first["id"])
    assert opened["status"] == "pending"
    assert inbox.records[0]["outcome"] is None
    with pytest.raises(AppError, match="不能报告完成"):
        inbox.finish(first["id"], "completed", {"workflowState": "completed", "receiptID": str(uuid.uuid4()).upper(), "itemCount": 1})
    inbox.approve(first["id"])
    done = inbox.finish(first["id"], "completed", {"workflowState": "completed", "receiptID": str(uuid.uuid4()).upper(), "itemCount": 1, "movedBytes": 4, "skippedCount": 0, "failedCount": 0})
    assert done["outcome"]["status"] == "completed"
    mutated = json.loads(payload)
    mutated["nonce"] = __import__("base64").b64encode(os.urandom(32)).decode("ascii")
    with pytest.raises(AppError, match="内容不同"):
        inbox.receive(json.dumps(mutated).encode("utf-8"))
    too_long = _manifest(expiresAt=(datetime.now(timezone.utc) + timedelta(seconds=121)).strftime("%Y-%m-%dT%H:%M:%SZ"))
    with pytest.raises(AppError, match="有效期"):
        validate(too_long)


def test_local_server_requires_a_token_and_can_shut_down(tmp_path):
    service = Service(tmp_path, home=tmp_path, collector=_Collector())
    httpd, token = serve(service, background=True)
    port = httpd.server_address[1]
    base = f"http://127.0.0.1:{port}"
    try:
        page = urllib.request.urlopen(base + "/", timeout=5).read().decode("utf-8")
        assert token in page
        assert "搞机灵" in page
        request = urllib.request.Request(base + "/api/state", headers={"X-Gao-Token": "nope"})
        with pytest.raises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=5)
        assert caught.value.code == 401
        body = json.dumps({"name": "CI smoke"}).encode("utf-8")
        request = urllib.request.Request(base + "/api/session/start", data=body, headers={"X-Gao-Token": token, "Content-Type": "application/json"})
        started = json.loads(urllib.request.urlopen(request, timeout=5).read())
        assert started["session"]["name"] == "CI smoke"
        state = json.loads(urllib.request.urlopen(urllib.request.Request(base + "/api/state", headers={"X-Gao-Token": token}), timeout=5).read())
        assert state["activeSession"]["name"] == "CI smoke"
        urllib.request.urlopen(urllib.request.Request(base + "/api/shutdown", data=b"{}", headers={"X-Gao-Token": token, "Content-Type": "application/json"}), timeout=5)
    finally:
        httpd.shutdown()
        service.close()


class _Collector:
    def sample(self):
        return _sample(time.time(), cpu=5)
