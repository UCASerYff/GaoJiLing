import json
import sqlite3
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaojiling import service as service_module
from gaojiling.backup import load_backup
from gaojiling.errors import AppError
from gaojiling.service import Service
from gaojiling.sessioncompare import DETAIL_LIMIT, POINT_LIMIT, new_detail, observe, validate_detail
from gaojiling.web import serve


def sample(stamp, cpu=None, memory=None, process_cpu=2, baseline=None):
    return {"timestamp": stamp, "cpuPercent": cpu, "memoryUsed": memory,
            "processBaselineAt": baseline, "processes": [
                {"name": "fixture.exe", "cpuPercent": process_cpu, "cpuAvailable": True,
                 "memoryBytes": 100, "observedAt": stamp, "pids": [1, 2]},
                {"name": "stale.exe", "cpuPercent": 99, "memoryBytes": 999, "observedAt": stamp - 1, "pids": [3]},
            ]}


def test_session_compare_http_uses_exact_saved_runs_and_preserves_them_in_backup(tmp_path, monkeypatch):
    base_time = int(time.time()) - 600
    clock = [base_time]
    monkeypatch.setattr(service_module, "now_unix", lambda: clock[0])
    service = Service(tmp_path / "data", home=tmp_path, collector=object())
    http, token = serve(service, background=True)
    url = f"http://127.0.0.1:{http.server_address[1]}/api/session/compare"

    def compare(identifiers):
        request = Request(url, data=json.dumps({"ids": identifiers}).encode(),
                          headers={"X-Gao-Token": token, "Content-Type": "application/json"})
        with urlopen(request, timeout=5) as response:
            return json.load(response)

    try:
        left = service.start_session("冷启动")
        # Neither a pre-task sample, stale group, nor the first cold-baseline CPU may contribute to its ranking.
        service.sample_once(sample(base_time - 2, 100, 1000, 100, base_time - 3))
        service.sample_once(sample(base_time + 4, 90, 500, 90, base_time - 2))
        service.sample_once(sample(base_time + 9, 30, 650, 20, base_time + 4))
        service.sample_once(sample(base_time + 14, 50, 700, 35, base_time + 9))
        clock[0] += 18
        service.stop_session()

        clock[0] = base_time + 100
        right = service.start_session("热启动")
        service.sample_once(sample(base_time + 104, 0, None, None, base_time + 99))
        service.sample_once(sample(base_time + 108, 0, None, None, base_time + 104))
        with pytest.raises(HTTPError) as error:
            compare([left["id"], right["id"]])
        assert error.value.code == 400
        clock[0] += 12
        service.stop_session()

        result = compare([left["id"], right["id"]])
        first, second = result["sessions"]
        assert [first["id"], second["id"]] == [left["id"], right["id"]]
        assert first["durationSeconds"] == 18 and second["durationSeconds"] == 12
        assert first["cpuAveragePercent"] == pytest.approx(170 / 3)
        assert first["cpuPeakPercent"] == 90 and first["memoryPeakBytes"] == 700
        assert first["sampleCount"] == first["cpuSampleCount"] == first["memorySampleCount"] == 3
        assert (first["sampleStart"], first["sampleEnd"]) == (base_time + 4, base_time + 14)
        assert first["trend"]["source"] == "session"
        assert first["trend"]["points"] == [{"elapsedSeconds": 9, "cpuPercent": 30, "memoryBytes": 650},
                                              {"elapsedSeconds": 14, "cpuPercent": 50, "memoryBytes": 700}]
        assert first["processes"]["sampledAt"] == base_time + 14
        assert first["processes"]["systemCpuPercent"] == 50
        assert first["processes"]["rows"] == [{"name": "fixture.exe", "cpuPercent": 35,
                                               "memoryBytes": 100, "processCount": 2}]
        assert second["cpuAveragePercent"] == second["cpuPeakPercent"] == 0
        assert second["memoryPeakBytes"] is None and not second["processes"]["available"]
        assert result["comparable"] == {"durationSeconds": True, "cpuAveragePercent": True, "cpuPeakPercent": True,
                                        "memoryPeakBytes": False, "processes": False}
        assert compare([right["id"], left["id"]])["sessions"] == [second, first]
        assert "_comparison" not in service.state()["sessions"][0]

        for invalid in (None, [left["id"]], [left["id"], left["id"]], [left["id"], "missing"], [1, right["id"]]):
            with pytest.raises(HTTPError) as error:
                compare(invalid)
            assert error.value.code == 400

        backup = tmp_path / "tasks.json"
        service.export_backup(backup)
        raw = json.loads(backup.read_text(encoding="utf-8"))
        assert raw["schemaVersion"] == 1
        assert {"_comparison", "points"}.isdisjoint(raw["sessions"][0])
        assert all(isinstance(value, str) and len(value) <= 16_384 for value in raw["auxiliaryPreferences"].values())
        assert set(load_backup(backup)["sessionDetails"]) == {left["id"], right["id"]}
        restored = Service(tmp_path / "restored", home=tmp_path, collector=object())
        try:
            restored.restore_backup(backup, True)
            assert restored.compare_sessions([left["id"], right["id"]]) == result
            restored.clear_data("sessions")
            assert not restored.store.comparison_backup([])
            assert restored.store.db.execute("SELECT COUNT(*) FROM session_comparison").fetchone()[0] == 0
        finally:
            restored.close()
    finally:
        http.shutdown()
        http.server_close()
        service.close()


def test_legacy_run_uses_only_retained_history_inside_observed_bounds(tmp_path):
    service = Service(tmp_path / "data", home=tmp_path, collector=object())
    now = int(time.time()) - 60
    old = {"id": "old", "name": "没有该项口径", "start": now - 60, "end": now - 10,
           "lastObserved": now - 29, "peakCPU": 0, "peakMemory": 0, "sampleCount": 0, "interrupted": True}
    other = {"id": "other", "name": "两次已保存", "start": now + 10, "end": now + 30,
             "sampleCount": 2, "cpuTotal": 0, "peakCPU": 0, "peakMemory": 1024, "interrupted": False}
    try:
        service.store.save_session(old)
        service.store.save_session(other)
        for when in (now - 61, now - 57, now - 40, now - 15):
            service.store.add_sample(sample(when, 10, 30, 9, when - 1))
        result = service.compare_sessions(["old", "other"])
        left, right = result["sessions"]
        assert not result["comparable"]["durationSeconds"] and left["durationSeconds"] == 50
        assert left["cpuPeakPercent"] is None and left["memoryPeakBytes"] is None
        assert left["sampleCount"] is None and left["trend"]["source"] == "history"
        assert left["sampleStart"] == now - 57 and left["sampleEnd"] == now - 40
        assert not left["processes"]["available"] and left["processes"]["rows"] == []
        assert right["cpuAveragePercent"] == 0 and right["memoryPeakBytes"] == 1024
        assert not right["trend"]["available"]
    finally:
        service.close()


def test_detail_retention_and_long_runs_are_bounded_and_failed_save_is_atomic(tmp_path, monkeypatch):
    service = Service(tmp_path / "data", home=tmp_path, collector=object())
    now = int(time.time())
    try:
        detail = new_detail()
        for offset in range(0, 7 * 86400, 15):
            observe(detail, now, sample(now + offset, 10, 1, 2, now + offset - 15), now + offset - 15)
        assert detail["sampleCount"] == 7 * 86400 // 15
        assert len(detail["points"]) <= POINT_LIMIT and validate_detail(detail, 7 * 86400)
        assert detail["points"][-1][0] == detail["last"]

        for number in range(DETAIL_LIMIT + 1):
            service.store.save_session({"id": str(number), "name": str(number), "start": now - 10_000 + number,
                                        "end": now, "_comparison": new_detail()})
        assert service.store.counts()["sessions"] == DETAIL_LIMIT + 1
        statements = []
        service.store.db.set_trace_callback(statements.append)
        try:
            result = service.compare_sessions(["0", str(DETAIL_LIMIT)])
        finally:
            service.store.db.set_trace_callback(None)
        reads = [sql for sql in statements if "FROM samples" in sql]
        assert 1 < len(reads) <= POINT_LIMIT and all("LIMIT 1" in sql for sql in reads)
        assert [run["trend"]["source"] for run in result["sessions"]] == ["history", "session"]
        assert len(service.store.comparison_backup(service.store.sessions())) == DETAIL_LIMIT

        session = service.start_session("保存冲突")

        def fail(*_):
            raise sqlite3.OperationalError("fixture write failed")

        monkeypatch.setattr(service.store, "_save_session_detail", fail)
        with pytest.raises(AppError, match="任务未能保存"):
            service.prepare_shutdown(lambda _: True)
        assert service.active["id"] == session["id"] and not service.stopping
        assert service.store.session(session["id"])["end"] is None
    finally:
        service.close()
