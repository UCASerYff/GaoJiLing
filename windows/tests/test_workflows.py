import json
import sqlite3
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaojiling.errors import AppError
from gaojiling.service import Service
from gaojiling.timeutil import now_unix
from gaojiling.web import dispatch, serve
from gaojiling.store import MonitorStore
from test_windows_port import _manifest, _sample


def test_cancel_exit_keeps_sampling_and_accepting_exit_finishes_the_same_task(tmp_path):
    service = Service(tmp_path / "data", home=tmp_path, collector=object())
    session = service.start_session("托盘退出测试")

    def cancel(name):
        assert name == session["name"]
        with pytest.raises(AppError, match="工作正在进行"):
            with service.mutation():
                pytest.fail("an operation must not start during the confirmation")
        service.sample_once(_sample(now_unix()))
        return False

    try:
        assert not service.prepare_shutdown(cancel)
        assert not service.stopping and service.active["id"] == session["id"]
        assert service.active["sampleCount"] == 1
        assert service.prepare_shutdown(lambda _name: True)
        assert service.stopping and service.active is None
        with pytest.raises(AppError, match="正在退出"):
            with service.mutation():
                pytest.fail("an operation must not start when stopping")
    finally:
        service.close()
    reopened = MonitorStore(tmp_path / "data")
    try:
        saved = reopened.sessions()[0]
        assert saved["id"] == session["id"] and saved["end"] and saved["interrupted"] is False
    finally:
        reopened.close()


def test_exit_waits_for_existing_work_and_leaves_task_active_if_save_failed(tmp_path, monkeypatch):
    service = Service(tmp_path, home=tmp_path, collector=object())
    service.start_session("保存失败测试")

    def fail(_):
        raise sqlite3.OperationalError("fixture write failed")

    try:
        with service.job("cleanup"), pytest.raises(AppError, match="工作正在进行"):
            service.prepare_shutdown()
        monkeypatch.setattr(service.store, "save_session", fail)
        with pytest.raises(AppError, match="任务未能保存"):
            service.prepare_shutdown()
        assert not service.stopping and service.active is not None
    finally:
        service.close()


def test_history_task_and_export_through_http(tmp_path):
    service = Service(tmp_path / "data", home=tmp_path, collector=object())
    current = now_unix()
    sample = {**_sample(current - 1), "memoryUsed": 20, "memoryTotal": 80}
    service.sample_once(sample)
    http, token = serve(service, background=True)
    base = f"http://127.0.0.1:{http.server_address[1]}"
    headers = {"X-Gao-Token": token, "Content-Type": "application/json"}

    def post(path, payload):
        request = Request(base + path, data=json.dumps(payload).encode(), headers=headers)
        with urlopen(request, timeout=5) as response:
            return json.load(response)

    try:
        point = post("/api/history", {"after": current - 3600, "before": current})["history"][0]
        assert point["memoryPercent"] == 25
        task = post("/api/session/start", {"name": "isolated fixture"})["session"]
        post("/api/pause", {"paused": True})
        ended = post("/api/session/stop", {})["session"]
        assert ended["end"] >= task["start"] and ended["interrupted"] is False
        export = tmp_path / "isolated.csv"
        post("/api/export", {"kind": "sessions", "path": str(export), "sessionId": task["id"]})
        assert "isolated fixture" in export.read_text(encoding="utf-8-sig")
        with pytest.raises(HTTPError) as unconfirmed:
            post("/api/data/clear", {"scope": "sessions"})
        assert unconfirmed.value.code == 400
        with pytest.raises(HTTPError) as get_denied:
            urlopen(Request(base + "/api/session/stop", headers=headers), timeout=5)
        assert get_denied.value.code == 405
        assert post("/api/data/clear", {"scope": "sessions", "confirm": True})["deleted"] == 1
    finally:
        http.shutdown()
        http.server_close()
        service.close()


def test_review_runs_matching_scope_once_and_exports_business_result(tmp_path):
    data = tmp_path / "data"
    source = tmp_path / "folder"
    source.mkdir()
    (source / "note.bin").write_bytes(b"isolated")
    service = Service(data, home=tmp_path, collector=object())
    message = _manifest(
        "storage.inspect", parameters={"mode": "metadata"},
        references=[{"id": "folder-1", "kind": "directory", "displayName": "Synthetic",
                     "fileURL": source.as_uri()}],
    )
    try:
        request_id = service.exchange.receive(message)["id"]
        result = dispatch(service, "POST", "/api/exchange/open", {"id": request_id})
        assert result["status"] == "pending"
        assert service.exchange.records[0]["outcome"] is None
        dispatch(service, "POST", "/api/exchange/approve", {"id": request_id})
        with pytest.raises(AppError, match="目录"):
            service.storage_scan("directory", str(tmp_path), review_id=request_id)
        report = service.storage_scan("directory", str(source), review_id=request_id)
        assert report["complete"] and report["reviewFinished"]
        assert report["tree"]["fileCount"] == 1
        with pytest.raises(AppError, match="尚未执行"):
            service.storage_scan("directory", str(source), review_id=request_id)
        with pytest.raises(AppError, match="没有这个接口"):
            dispatch(service, "POST", "/api/exchange/finish", {"id": request_id, "status": "completed"})
        exported = tmp_path / "out.gaoaction"
        service.exchange_export(request_id, exported)
        document = json.loads((exported / "manifest.json").read_text(encoding="utf-8"))
        assert document["inReplyTo"] == request_id
        assert document["status"] == "completed"
        assert document["provenance"]["scope"]["referenceID"] == "folder-1"
        assert document["provenance"]["statistics"]["files"] == 1
        assert (exported / "payload").is_dir()
        interrupted = service.exchange.receive(_manifest())["id"]
        service.exchange.approve(interrupted)
        service.exchange.begin(interrupted, "cleanup.review")
    finally:
        service.close()
    reopened = Service(data, home=tmp_path, collector=object())
    try:
        assert reopened.exchange._record(interrupted)["outcome"]["errorCode"] == "interrupted"
        assert reopened.storage_scan("directory", str(source))["trend"]["completeCount"] == 2
    finally:
        reopened.close()


def test_operation_cancellation_is_cooperative(tmp_path):
    service = Service(tmp_path, home=tmp_path, collector=object())
    started = threading.Event()
    observed = threading.Event()

    def run():
        with service.job("storage") as cancelled:
            started.set()
            stop = threading.Event()
            for _ in range(1000):
                if cancelled():
                    observed.set()
                    return
                stop.wait(.005)

    worker = threading.Thread(target=run)
    worker.start()
    try:
        assert started.wait(3)
        assert service.cancel("storage")["ok"]
        assert observed.wait(3)
    finally:
        service.cancel("storage")
        worker.join()
        service.close()
