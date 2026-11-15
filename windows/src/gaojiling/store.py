"""本地监控库。表结构与 Mac 版 monitor.sqlite 相同。

读取失败时不删除、不重建、不用空库覆盖。设置行无法解码时不写回。
较早采样的降采样与 Mac 的 prune SQL 一致：满 24 小时后的每一分钟只留最早一条真实采样。
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.jsonutil import dumps
from gaojiling.timeutil import check_unix, cocoa_to_unix, now_unix, unix_to_cocoa

_TABLES = ("samples", "events", "sessions", "preferences")
_CREATE = """
CREATE TABLE samples(t REAL PRIMARY KEY, payload TEXT NOT NULL);
CREATE TABLE events(id TEXT PRIMARY KEY, t REAL NOT NULL, payload TEXT NOT NULL);
CREATE TABLE sessions(id TEXT PRIMARY KEY, t REAL NOT NULL, payload TEXT NOT NULL);
CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL);
"""


def default_settings() -> dict:
    return {
        "edgeEnabled": True,
        "edge": "right",
        "edgeDelay": 0.45,
        "sampleInterval": 2.0,
        "retentionDays": 7,
        "launchAtLogin": False,
        "notificationsEnabled": False,
        "appearance": "system",
        "showSensors": True,
        "menuBarCPU": True,
        "hotkeyChoice": "g",
    }


def default_panel() -> dict:
    return {"verticalRatio": 0.5, "horizontalRatio": None, "displayId": ""}


def normalize_settings(raw: dict) -> dict:
    settings = default_settings()
    settings.update({key: raw[key] for key in settings if key in raw})
    if settings["edge"] not in {"left", "right"}:
        raise AppError("设置选项无效。")
    if settings["appearance"] not in {"system", "light", "dark"}:
        raise AppError("设置选项无效。")
    if settings["hotkeyChoice"] not in {"g", "m"}:
        raise AppError("设置选项无效。")
    for key in ("edgeEnabled", "launchAtLogin", "notificationsEnabled", "showSensors", "menuBarCPU"):
        if not isinstance(settings[key], bool):
            raise AppError("设置选项无效。")
    delay = float(settings["edgeDelay"])
    interval = float(settings["sampleInterval"])
    days = int(settings["retentionDays"])
    if not 0.2 <= delay <= 1.5 or not 1 <= interval <= 10 or not 1 <= days <= 30:
        raise AppError("设置选项无效。")
    settings["edgeDelay"] = delay
    settings["sampleInterval"] = interval
    settings["retentionDays"] = days
    return settings


def _date_field(value, field: str) -> float:
    """Payload 里的日期是 Cocoa 秒；也接受已经是 Unix 秒的内部对象。"""
    number = float(value)
    if number < 0:
        # Cocoa 秒在 2001 年之后的正常记录不会为负到 Unix 1900 以下太多。
        # 2001 年之前的 Cocoa 负值换算后仍须落在 1900–3000。
        return check_unix(cocoa_to_unix(number), field)
    # 大于 1e11 不可能是 Cocoa 或 Unix 秒。2001 之后的 Cocoa 与 Unix 会重叠，
    # 存盘时统一写 Cocoa。读 Mac 库时日期是 Cocoa。内部调用 encode 前已是 Unix，
    # 由 encode 函数转换，这里只处理已编码的 payload。
    return check_unix(cocoa_to_unix(number), field)


def encode_sample(sample: dict) -> str:
    processes = []
    for process in (sample.get("processes") or [])[:6]:
        item = {
            "name": process["name"],
            "cpuPercent": process.get("cpuPercent") if process.get("cpuAvailable") is not False else 0,
            "memoryBytes": process.get("memoryBytes") or 0,
            "pids": process.get("pids") or [],
        }
        for key in ("path", "groupID", "bundleID", "availabilityReason", "cpuAvailable"):
            if process.get(key) is not None:
                item[key] = process[key]
        if process.get("identities"):
            item["identities"] = process["identities"]
        if process.get("observedAt") is not None:
            item["observedAt"] = unix_to_cocoa(process["observedAt"])
        processes.append(item)
    ordered = sorted(processes, key=lambda item: (-(item.get("cpuPercent") or 0), -(item.get("memoryBytes") or 0)))[:6]
    payload = {
        "timestamp": unix_to_cocoa(sample["timestamp"]),
        "cpuPercent": sample.get("cpuPercent"),
        "corePercents": [],
        "memoryUsed": sample.get("memoryUsed"),
        "memoryTotal": sample.get("memoryTotal"),
        "memoryCompressed": sample.get("memoryCompressed"),
        "swapUsed": sample.get("swapUsed"),
        "memoryPressure": sample.get("memoryPressure") or "未知",
        "networkDown": sample.get("networkDown"),
        "networkUp": sample.get("networkUp"),
        "diskRead": sample.get("diskRead"),
        "diskWrite": sample.get("diskWrite"),
        "diskFree": sample.get("diskFree"),
        "diskTotal": sample.get("diskTotal"),
        "gpuPercent": sample.get("gpuPercent"),
        "cpuTemperature": sample.get("cpuTemperature"),
        "cpuPower": sample.get("cpuPower"),
        "gpuPower": sample.get("gpuPower"),
        "fanRPM": sample.get("fanRPM"),
        "batteryPercent": sample.get("batteryPercent"),
        "batteryCharging": bool(sample.get("batteryCharging") or False),
        "batteryHealth": sample.get("batteryHealth"),
        "batteryCycles": sample.get("batteryCycles"),
        "uptime": sample.get("uptime"),
        "processCount": sample.get("processCount"),
        "thermalState": sample.get("thermalState") or "未知",
        "processes": ordered,
    }
    return dumps(payload)


def decode_sample(payload: str) -> dict:
    raw = json.loads(payload)
    sample = {
        "timestamp": _date_field(raw["timestamp"], "采样时间"),
        "cpuPercent": raw.get("cpuPercent"),
        "memoryUsed": raw.get("memoryUsed"),
        "memoryTotal": raw.get("memoryTotal"),
        "memoryCompressed": raw.get("memoryCompressed"),
        "swapUsed": raw.get("swapUsed"),
        "memoryPressure": raw.get("memoryPressure") or "未知",
        "networkDown": raw.get("networkDown"),
        "networkUp": raw.get("networkUp"),
        "diskRead": raw.get("diskRead"),
        "diskWrite": raw.get("diskWrite"),
        "diskFree": raw.get("diskFree"),
        "diskTotal": raw.get("diskTotal"),
        "gpuPercent": raw.get("gpuPercent"),
        "cpuTemperature": raw.get("cpuTemperature"),
        "batteryPercent": raw.get("batteryPercent"),
        "batteryCharging": bool(raw.get("batteryCharging") or False),
        "batteryHealth": raw.get("batteryHealth"),
        "batteryCycles": raw.get("batteryCycles"),
        "uptime": raw.get("uptime"),
        "processCount": raw.get("processCount"),
        "thermalState": raw.get("thermalState") or "未知",
        "processes": [],
    }
    for process in raw.get("processes") or []:
        item = {
            "name": process.get("name") or "",
            "cpuPercent": process.get("cpuPercent"),
            "memoryBytes": process.get("memoryBytes") or 0,
            "pids": process.get("pids") or [],
            "path": process.get("path"),
            "groupID": process.get("groupID"),
            "bundleID": process.get("bundleID"),
            "availabilityReason": process.get("availabilityReason"),
            "cpuAvailable": process.get("cpuAvailable"),
        }
        if process.get("observedAt") is not None:
            item["observedAt"] = _date_field(process["observedAt"], "进程时间")
        sample["processes"].append(item)
    return sample


def encode_event(event: dict) -> str:
    return dumps({
        "id": event["id"],
        "date": unix_to_cocoa(event["date"]),
        "title": event["title"],
        "detail": event["detail"],
        "severity": event["severity"],
        "kind": event["kind"],
    })


def decode_event(payload: str) -> dict:
    raw = json.loads(payload)
    return {
        "id": raw["id"],
        "date": _date_field(raw["date"], "事件时间"),
        "title": raw.get("title") or "",
        "detail": raw.get("detail") or "",
        "severity": raw.get("severity") or "",
        "kind": raw.get("kind") or "",
    }


def encode_session(session: dict) -> str:
    payload = {
        "id": session["id"],
        "name": session["name"],
        "start": unix_to_cocoa(session["start"]),
        "end": unix_to_cocoa(session["end"]) if session.get("end") is not None else None,
        "peakCPU": session.get("peakCPU") or 0,
        "peakMemory": session.get("peakMemory") or 0,
        "peakTemperature": session.get("peakTemperature"),
        "sampleCount": session.get("sampleCount") or 0,
        "cpuTotal": session.get("cpuTotal") or 0,
        "lastObserved": unix_to_cocoa(session["lastObserved"]) if session.get("lastObserved") is not None else None,
        "interrupted": session.get("interrupted"),
    }
    return dumps(payload)


def decode_session(payload: str) -> dict:
    raw = json.loads(payload)
    session = {
        "id": raw["id"],
        "name": raw.get("name") or "",
        "start": _date_field(raw["start"], "任务开始时间"),
        "end": _date_field(raw["end"], "任务结束时间") if raw.get("end") is not None else None,
        "peakCPU": raw.get("peakCPU") or 0,
        "peakMemory": raw.get("peakMemory") or 0,
        "peakTemperature": raw.get("peakTemperature"),
        "sampleCount": raw.get("sampleCount") or 0,
        "cpuTotal": raw.get("cpuTotal") or 0,
        "lastObserved": _date_field(raw["lastObserved"], "任务观测时间") if raw.get("lastObserved") is not None else None,
        "interrupted": raw.get("interrupted"),
    }
    return session


class MonitorStore:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "monitor.sqlite"
        self.panel_path = self.directory / "panel.json"
        self.status = None
        self.settings_writable = True
        self.db = None
        self.settings = default_settings()
        self.panel = default_panel()
        self._open()
        self._load_panel()

    def _open(self):
        companions = [self.directory / "monitor.sqlite-wal", self.directory / "monitor.sqlite-shm"]
        if not self.path.exists() and any(path.exists() for path in companions):
            self.status = "历史数据暂时无法读取，原文件已保留：主库缺失但存在 WAL 或 SHM。"
            return
        existed = self.path.exists()
        if existed:
            try:
                header = self.path.read_bytes()[:16]
            except OSError as error:
                self.status = f"历史数据暂时无法读取，原文件已保留：{error}"
                return
            if not header.startswith(b"SQLite format 3\x00"):
                self.status = "历史数据暂时无法读取，原文件已保留：这不是可读的 SQLite 主库。"
                return
        try:
            connection = sqlite3.connect(self.path, check_same_thread=False)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA busy_timeout=1500")
        except sqlite3.Error as error:
            self.status = f"历史数据暂时无法读取，原文件已保留：{error}"
            return
        try:
            if existed:
                names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if not set(_TABLES).issubset(names):
                    connection.close()
                    self.status = "历史数据暂时无法读取，原文件已保留：资料表与搞机灵不一致。"
                    return
            else:
                connection.executescript(_CREATE)
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("PRAGMA synchronous=NORMAL")
                connection.commit()
            self.db = connection
            self._load_settings()
            self._close_interrupted_sessions()
        except (sqlite3.Error, OSError, json.JSONDecodeError, ValueError, AppError) as error:
            self.status = f"历史数据暂时无法读取，原文件已保留：{error}"
            try:
                connection.close()
            except sqlite3.Error:
                pass
            self.db = None

    def _load_settings(self):
        row = self.db.execute("SELECT payload FROM preferences WHERE id=1").fetchone()
        if row is None:
            self.settings = default_settings()
            self._write_settings()
            return
        try:
            self.settings = normalize_settings(json.loads(row["payload"]))
        except (json.JSONDecodeError, AppError, TypeError, ValueError) as error:
            self.settings_writable = False
            self.settings = default_settings()
            self.status = f"设置读取失败，原数据已保留：{error}"

    def _write_settings(self):
        if not self.settings_writable or self.db is None:
            raise AppError("原设置读取异常，暂不覆盖。请先备份数据并检查数据库。")
        payload = dumps(self.settings)
        self.db.execute("INSERT OR REPLACE INTO preferences(id,payload) VALUES(1,?)", (payload,))
        self.db.commit()

    def update_settings(self, changes: dict) -> dict:
        if not self.settings_writable:
            raise AppError("原设置读取异常，暂不覆盖。请先备份数据并检查数据库。")
        merged = dict(self.settings)
        merged.update(changes)
        self.settings = normalize_settings(merged)
        self._write_settings()
        return self.settings

    def _load_panel(self):
        if not self.panel_path.exists():
            self.panel = default_panel()
            self.panel_writable = True
            return
        try:
            raw = json.loads(self.panel_path.read_text(encoding="utf-8"))
            panel = default_panel()
            if "verticalRatio" in raw:
                panel["verticalRatio"] = float(raw["verticalRatio"])
            if "horizontalRatio" in raw and raw["horizontalRatio"] is not None:
                panel["horizontalRatio"] = float(raw["horizontalRatio"])
            if "displayId" in raw:
                panel["displayId"] = str(raw["displayId"])[:256]
            if not 0 <= panel["verticalRatio"] <= 1:
                raise AppError("竖向位置无效")
            if panel["horizontalRatio"] is not None and not 0 <= panel["horizontalRatio"] <= 1:
                raise AppError("横向位置无效")
            self.panel = panel
        except (OSError, json.JSONDecodeError, AppError, TypeError, ValueError) as error:
            self.panel_writable = False
            self.panel = default_panel()
            extra = f"面板位置读取失败，原文件已保留：{error}"
            self.status = extra if not self.status else self.status + " " + extra
        else:
            self.panel_writable = True
        if not hasattr(self, "panel_writable"):
            self.panel_writable = True

    def save_panel(self, panel: dict):
        if getattr(self, "panel_writable", True) is False:
            raise AppError("面板位置读取失败，原文件已保留，未覆盖。")
        current = dict(self.panel)
        # 没有横向偏好时，不用侧边默认值把它写进去。
        if "horizontalRatio" in panel:
            current["horizontalRatio"] = panel["horizontalRatio"]
        if "verticalRatio" in panel:
            current["verticalRatio"] = panel["verticalRatio"]
        if "displayId" in panel:
            current["displayId"] = panel["displayId"]
        if current["horizontalRatio"] is not None:
            current["horizontalRatio"] = min(max(float(current["horizontalRatio"]), 0), 1)
        current["verticalRatio"] = min(max(float(current["verticalRatio"]), 0), 1)
        text = dumps(current)
        temporary = self.panel_path.with_name(".panel-write-" + uuid.uuid4().hex)
        temporary.write_text(text, encoding="utf-8")
        temporary.replace(self.panel_path)
        self.panel = current

    def _close_interrupted_sessions(self):
        rows = self.db.execute("SELECT payload FROM sessions").fetchall()
        for row in rows:
            session = decode_session(row["payload"])
            if session.get("end") is not None:
                continue
            last = self.db.execute(
                "SELECT payload FROM samples WHERE t >= ? ORDER BY t DESC LIMIT 1", (session["start"],)
            ).fetchone()
            observed = session.get("lastObserved")
            if last is not None:
                observed = decode_sample(last["payload"])["timestamp"]
            end = session["start"] if observed is None else max(session["start"], observed)
            session["end"] = end
            session["interrupted"] = True
            self.db.execute(
                "INSERT OR REPLACE INTO sessions(id,t,payload) VALUES(?,?,?)",
                (session["id"], session["start"], encode_session(session)),
            )
        self.db.commit()

    def require(self):
        if self.db is None:
            raise AppError(self.status or "历史数据暂时无法读取，原文件已保留。")

    def add_sample(self, sample: dict):
        self.require()
        stamp = check_unix(sample["timestamp"], "采样时间")
        sample = dict(sample)
        sample["timestamp"] = stamp
        self.db.execute(
            "INSERT OR REPLACE INTO samples(t,payload) VALUES(?,?)",
            (stamp, encode_sample(sample)),
        )
        self.db.commit()
        self.prune()

    def add_event(self, event: dict):
        self.require()
        event = dict(event)
        event.setdefault("id", str(uuid.uuid4()).upper())
        event["date"] = check_unix(event["date"], "事件时间")
        self.db.execute(
            "INSERT OR REPLACE INTO events(id,t,payload) VALUES(?,?,?)",
            (event["id"], event["date"], encode_event(event)),
        )
        self.db.commit()
        return event

    def save_session(self, session: dict):
        self.require()
        self.db.execute(
            "INSERT OR REPLACE INTO sessions(id,t,payload) VALUES(?,?,?)",
            (session["id"], session["start"], encode_session(session)),
        )
        self.db.commit()

    def history(self, since: float, until: float | None = None) -> list[dict]:
        self.require()
        until = now_unix() + 1 if until is None else until
        rows = self.db.execute(
            "SELECT payload FROM samples WHERE t >= ? AND t <= ? ORDER BY t", (since, until)
        ).fetchall()
        return [decode_sample(row["payload"]) for row in rows]

    def events(self, limit: int | None = None) -> list[dict]:
        self.require()
        sql = "SELECT payload FROM events ORDER BY t DESC, id"
        if limit:
            sql += f" LIMIT {int(limit)}"
        return [decode_event(row["payload"]) for row in self.db.execute(sql)]

    def sessions(self) -> list[dict]:
        self.require()
        return [decode_session(row["payload"]) for row in self.db.execute("SELECT payload FROM sessions ORDER BY t DESC, id")]

    def counts(self) -> dict:
        if self.db is None:
            return {"samples": None, "events": None, "sessions": None}
        return {
            "samples": self.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0],
            "events": self.db.execute("SELECT COUNT(*) FROM events").fetchone()[0],
            "sessions": self.db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0],
        }

    def clear(self, scope: str, before: float | None = None) -> int:
        self.require()
        table = {"samples": "samples", "events": "events", "sessions": "sessions"}.get(scope)
        if table is None:
            raise AppError("未知的清理类别。")
        if before is None:
            cursor = self.db.execute(f"DELETE FROM {table}")
        else:
            cutoff = check_unix(before, "清理截止时间")
            cursor = self.db.execute(f"DELETE FROM {table} WHERE t < ?", (cutoff,))
        self.db.commit()
        return cursor.rowcount

    def replace_backup(self, samples: list[dict], events: list[dict], sessions: list[dict], settings: dict | None):
        self.require()
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self.db.execute("DELETE FROM samples")
            self.db.execute("DELETE FROM events")
            self.db.execute("DELETE FROM sessions")
            for sample in samples:
                self.db.execute("INSERT INTO samples(t,payload) VALUES(?,?)", (sample["timestamp"], encode_sample(sample)))
            for event in events:
                self.db.execute("INSERT INTO events(id,t,payload) VALUES(?,?,?)", (event["id"], event["date"], encode_event(event)))
            for session in sessions:
                self.db.execute(
                    "INSERT INTO sessions(id,t,payload) VALUES(?,?,?)",
                    (session["id"], session["start"], encode_session(session)),
                )
            if settings is not None:
                if not self.settings_writable:
                    raise AppError("原设置读取异常，暂不覆盖。")
                self.settings = normalize_settings(settings)
                self.db.execute("INSERT OR REPLACE INTO preferences(id,payload) VALUES(1,?)", (dumps(self.settings),))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def prune(self, now: float | None = None):
        self.require()
        moment = now_unix() if now is None else now
        days = min(30, max(1, int(self.settings["retentionDays"])))
        cutoff = moment - days * 86400
        yesterday = moment - 86400
        self.db.execute("DELETE FROM samples WHERE t < ?", (cutoff,))
        self.db.execute("DELETE FROM events WHERE t < ?", (cutoff,))
        self.db.execute(
            """
            DELETE FROM samples WHERE t < ? AND t NOT IN (
                SELECT MIN(t) FROM samples WHERE t < ? GROUP BY CAST(t/60 AS INTEGER)
            )
            """,
            (yesterday, yesterday),
        )
        self.db.commit()

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None
