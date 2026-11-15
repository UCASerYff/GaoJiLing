"""把各模块串成一个本地服务。测试可以关掉采样线程并注入采集器。"""

from __future__ import annotations

import os
import threading
import time
import uuid
from pathlib import Path

from gaojiling.apps import AppInventory
from gaojiling.backup import backup_bytes, build_backup, load_backup
from gaojiling.cleanup import CleanupEngine
from gaojiling.csvexport import events_csv, history_csv, sessions_csv
from gaojiling.duplicates import DuplicateEngine
from gaojiling.errors import AppError
from gaojiling.events import EventDetector, sampling_interval
from gaojiling.exchange import ExchangeInbox
from gaojiling.exitpolicy import ExitPolicy
from gaojiling.filesafety import send_to_trash
from gaojiling.geometry import PanelAutoCollapse, dragging_handle, handle_frame, horizontal_ratio, panel_placement, vertical_ratio
from gaojiling.memory import release_own, snapshot as memory_snapshot, system_cache_report
from gaojiling.processes import tool_running
from gaojiling.metrics import MetricCollector
from gaojiling.network import diagnose
from gaojiling.ntfs import analyze_image, extract
from gaojiling.storageanal import analyze, analyze_dev, compare_history
from gaojiling.store import MonitorStore
from gaojiling.timeutil import now_unix
from gaojiling.version import display
from gaojiling.volumes import WindowsVolumeProvider, collect as collect_volumes


def default_data_dir() -> Path:
    if os.name == "nt":
        root = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        return Path(root) / "GaoSeries" / "GaoJiLing"
    return Path.home() / ".local" / "share" / "GaoSeries" / "GaoJiLing"


def _write_new(path: Path, data: bytes):
    if path.exists() or path.is_symlink():
        raise AppError("目标已存在，未覆盖。")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class Service:
    def __init__(self, data_dir: Path, home: Path | None = None, collector=None, start_sampling: bool = False,
                 layout: str | None = None, trash=None, volume_provider=None, app_catalog=None):
        self.data_dir = Path(data_dir)
        self.home = Path(home) if home else Path.home()
        self.store = MonitorStore(self.data_dir)
        self.collector = collector or MetricCollector()
        self.detector = EventDetector()
        self.latest = None
        self.paused = False
        self.active = None
        self.message = self.store.status
        self.cleanup = CleanupEngine(
            self.home, self.data_dir / "Cleanup", self.data_dir / "CleanupStage",
            layout or ("windows" if os.name == "nt" else "darwin"),
            running=tool_running, owner_lookup=lambda owner: None, trash=trash or send_to_trash,
        )
        self.duplicates = DuplicateEngine(self.data_dir / "Duplicates", self.data_dir / "DuplicateStage", self.home, trash or send_to_trash)
        self.apps = AppInventory(self.data_dir / "Uninstall", trash or send_to_trash, catalog=app_catalog)
        self.exchange = ExchangeInbox(self.data_dir / "Exchange")
        self.exit_policy = ExitPolicy()
        self.exit_rules = []
        self.exit_enabled = False
        self.panel_state = PanelAutoCollapse()
        self.storage_history = []
        self.network_checks = []
        self.last_cleanup = None
        self.last_storage = None
        self.last_duplicates = None
        self.last_apps = None
        self.last_volumes = None
        self.last_ntfs = None
        self.volume_provider = volume_provider
        self.ntfs_result = None
        self._stop = threading.Event()
        self._thread = None
        if start_sampling:
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()

    def close(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        self.store.close()

    def _loop(self):
        while not self._stop.is_set():
            if not self.paused:
                try:
                    self.sample_once()
                except AppError as error:
                    self.message = error.message
            interval = sampling_interval(
                self.store.settings["sampleInterval"], True, False, self.active is not None,
                self.store.db is not None, self.exit_enabled,
            )
            self._stop.wait(interval)

    def sample_once(self, sample: dict | None = None) -> dict:
        current = sample or self.collector.sample()
        current["timestamp"] = current.get("timestamp") or now_unix()
        self.latest = current
        if self.store.db is not None:
            self.store.add_sample(current)
            for event in self.detector.evaluate(current):
                self.store.add_event(event)
        if self.active is not None:
            cpu = current.get("cpuPercent")
            if cpu is not None:
                self.active["peakCPU"] = max(self.active["peakCPU"], cpu)
                self.active["cpuTotal"] += cpu
                self.active["sampleCount"] += 1
            memory = current.get("memoryUsed")
            if memory is not None:
                self.active["peakMemory"] = max(self.active["peakMemory"], memory)
            self.active["lastObserved"] = current["timestamp"]
            self.store.save_session(self.active)
        return current

    def set_paused(self, paused: bool):
        self.paused = bool(paused)
        if paused:
            self.detector.reset()

    def start_session(self, name: str) -> dict:
        title = (name or "").strip()
        if not title or len(title) > 200:
            raise AppError("请填写任务名称。")
        if self.active is not None:
            raise AppError("已有任务正在记录。")
        self.active = {
            "id": str(uuid.uuid4()).upper(), "name": title, "start": now_unix(), "end": None,
            "peakCPU": 0, "peakMemory": 0, "peakTemperature": None, "sampleCount": 0, "cpuTotal": 0,
            "lastObserved": None, "interrupted": None,
        }
        self.store.save_session(self.active)
        return self.active

    def stop_session(self) -> dict:
        if self.active is None:
            raise AppError("没有正在记录的任务。")
        self.active["end"] = self.active.get("lastObserved") or self.active["start"]
        self.active["interrupted"] = False
        self.store.save_session(self.active)
        finished = self.active
        self.active = None
        return finished

    def state(self) -> dict:
        since = now_unix() - 86400
        history = self.store.history(since) if self.store.db is not None else []
        interval = self.store.settings["sampleInterval"]
        gap_list = []
        for left, right in zip(history, history[1:]):
            if right["timestamp"] - left["timestamp"] > max(15, interval * 3):
                gap_list.append({"after": left["timestamp"], "before": right["timestamp"]})
        counts = self.store.counts()
        return {
            "version": display(),
            "message": self.message,
            "paused": self.paused,
            "settings": self.store.settings,
            "panel": self.store.panel,
            "latest": self.latest,
            "history": history[-180:],
            "gaps": gap_list,
            "events": self.store.events(100) if self.store.db is not None else [],
            "sessions": self.store.sessions() if self.store.db is not None else [],
            "activeSession": self.active,
            "counts": counts,
            "cleanup": self.cleanup.history(),
            "cleanupItems": (self.last_cleanup or {}).get("items", []),
            "cleanupNotes": (self.last_cleanup or {}).get("notes", []),
            "storage": self._public_storage(),
            "duplicates": self.last_duplicates,
            "apps": (self.last_apps or {}).get("apps", []),
            "volumes": self.last_volumes,
            "ntfs": self._public_ntfs(),
            "network": self.network_checks,
            "exitRules": self.exit_rules,
            "exchange": [{"id": item["id"], "action": item["manifest"]["action"], "phase": item["phase"], "outcome": item.get("outcome")} for item in self.exchange.records],
        }

    def update_settings(self, changes: dict):
        return self.store.update_settings(changes)

    def export_csv(self, kind: str, path: Path):
        if kind == "history":
            data = history_csv(self.store.history(0))
        elif kind == "events":
            data = events_csv(self.store.events())
        elif kind == "sessions":
            data = sessions_csv(self.store.sessions())
        else:
            raise AppError("未知的导出类别。")
        _write_new(Path(path), data)
        return {"path": str(path), "message": "已导出 CSV。文件含本机名称和时间，请自行保管。"}

    def export_backup(self, path: Path):
        auxiliary = {}
        if self.store.panel.get("horizontalRatio") is not None:
            auxiliary["GaoJiLing.EdgeHandle.horizontalRatio"] = str(self.store.panel["horizontalRatio"])
        auxiliary["GaoJiLing.EdgeHandle.verticalRatio"] = str(self.store.panel["verticalRatio"])
        if self.store.panel.get("displayId"):
            auxiliary["GaoJiLing.EdgeHandle.displayId"] = self.store.panel["displayId"]
        document = build_backup(self.store.history(0), self.store.events(), self.store.sessions(), self.store.settings, auxiliary, now_unix())
        _write_new(Path(path), backup_bytes(document))
        return {"path": str(path), "message": "已导出完整资料。恢复不会自动备份当前数据。"}

    def restore_backup(self, path: Path, confirm: bool):
        if not confirm:
            raise AppError("恢复会替换当前监控记录，且不会自动备份当前数据。请先确认。")
        if self.active is not None:
            raise AppError("请先结束正在记录的任务。")
        loaded = load_backup(Path(path))
        self.store.replace_backup(loaded["samples"], loaded["events"], loaded["sessions"], loaded["settings"])
        auxiliary = loaded.get("auxiliary") or {}
        # 没有横向偏好时，不用侧边选择覆盖已经保存的横向位置。
        if "GaoJiLing.EdgeHandle.horizontalRatio" in auxiliary or "GaoJiLing.EdgeHandle.verticalRatio" in auxiliary:
            panel = {}
            if "GaoJiLing.EdgeHandle.horizontalRatio" in auxiliary:
                panel["horizontalRatio"] = float(auxiliary["GaoJiLing.EdgeHandle.horizontalRatio"])
            if "GaoJiLing.EdgeHandle.verticalRatio" in auxiliary:
                panel["verticalRatio"] = float(auxiliary["GaoJiLing.EdgeHandle.verticalRatio"])
            if "GaoJiLing.EdgeHandle.displayId" in auxiliary:
                panel["displayId"] = auxiliary["GaoJiLing.EdgeHandle.displayId"]
            self.store.save_panel(panel)
        self.detector.reset()
        return {"message": "已从所选文件恢复。这次没有自动备份被替换的数据。清理、卸载和重复文件记录未改动。"}

    def clear_data(self, scope: str, before: float | None = None):
        deleted = self.store.clear(scope, before)
        return {"deleted": deleted, "message": "只清除了所选类别。任务、设置或其他类别未一起删除。" if scope != "sessions" else "已清除所选任务记录。"}

    def cleanup_scan(self):
        self.last_cleanup = self.cleanup.scan()
        return self.last_cleanup

    def cleanup_trash(self, ids, confirm: bool):
        if not confirm:
            raise AppError("需要确认后才会移入废纸篓。")
        return self.cleanup.trash(ids)

    def cleanup_restore(self, batch_id=None):
        return self.cleanup.restore(batch_id)

    def storage_scan(self, mode: str, path: str | None = None, exclusions=None):
        if mode == "dev":
            result = analyze_dev(self.home, "windows" if os.name == "nt" else "darwin", exclusions=exclusions or [])
            allocated = 0
            for part in result["parts"]:
                tree = part.get("tree") or {}
                allocated += tree.get("allocatedBytes") or 0
            summary = {"scopeKey": result["scopeKey"], "complete": result["complete"], "allocatedBytes": allocated, "at": now_unix()}
        elif mode == "directory":
            if not path:
                raise AppError("请选择要分析的目录。")
            result = analyze(Path(path), exclusions or [])
            summary = {"scopeKey": result["scopeKey"], "complete": result["complete"],
                       "allocatedBytes": (result.get("tree") or {}).get("allocatedBytes") or 0, "at": now_unix()}
        else:
            raise AppError("未知的分析范围。")
        self.storage_history.append(summary)
        self.storage_history = self.storage_history[-30:]
        result["trend"] = compare_history(self.storage_history, summary["scopeKey"])
        self.last_storage = result
        self._last_storage = result
        return result

    def storage_csv(self, path: Path):
        result = self.last_storage
        if not result:
            raise AppError("还没有分析结果。")
        rows = [["路径", "分配字节", "逻辑字节", "文件数", "说明"]]
        for entry in result.get("entries") or []:
            rows.append([entry.get("path") or "", str(entry.get("allocatedBytes") or 0), str(entry.get("logicalBytes") or 0),
                         str(entry.get("fileCount") or 0), "未完成" if not result.get("complete") else ""])
        from gaojiling.textutil import csv_file
        _write_new(Path(path), csv_file(rows))
        return {"path": str(path), "message": "CSV 含个人路径，只保存在所选位置。"}

    def duplicate_scan(self, path: str, confirm_read: bool):
        self.last_duplicates = self.duplicates.scan(Path(path), confirm_read)
        return self.last_duplicates

    def duplicate_move(self, ids, confirm: bool):
        if not confirm:
            raise AppError("需要确认后才会移动副本。")
        return self.duplicates.move(ids)

    def volumes(self):
        provider = self.volume_provider
        if provider is None and os.name == "nt":
            provider = WindowsVolumeProvider()
        if provider is None:
            raise AppError("这个环境没有 Windows 卷枚举。不会把缺失写成 0。")
        self.last_volumes = collect_volumes(provider)
        return self.last_volumes

    def ntfs(self, path: str, consent: bool):
        self.ntfs_result = analyze_image(Path(path), consent)
        self.last_ntfs = self._public_ntfs()
        return self.last_ntfs

    def _public_ntfs(self):
        if not self.ntfs_result:
            return None
        public = dict(self.ntfs_result)
        public.pop("identity", None)
        return public

    def _public_storage(self):
        result = self.last_storage
        if not result:
            return None
        if result.get("kind") == "dev":
            return {"kind": "dev", "complete": result.get("complete"), "notes": result.get("notes"),
                    "parts": [{"label": part.get("label"), "path": part.get("path"), "present": part.get("present"),
                               "complete": part.get("complete"),
                               "allocatedBytes": (part.get("tree") or {}).get("allocatedBytes")} for part in result.get("parts") or []]}
        return {"kind": "directory", "complete": result.get("complete"), "scope": result.get("scope"),
                "notes": result.get("notes"), "trend": result.get("trend"),
                "entries": (result.get("entries") or [])[:40]}

    def ntfs_extract(self, entry_id: str, destination: str, confirm: bool):
        if self.ntfs_result is None:
            raise AppError("请先分析镜像。")
        return extract(Path(self.ntfs_result["sourcePath"]), self.ntfs_result, entry_id, Path(destination), confirm)

    def network(self, host: str):
        self.network_checks = diagnose(host)
        return self.network_checks

    def memory_own(self):
        return release_own()

    def memory_system(self):
        if memory_snapshot() is None:
            from gaojiling.memory import missing_report
            return missing_report()
        return system_cache_report()

    def geometry(self, visible: dict, pointer: dict, grab: dict, size: dict | None = None):
        frame = dragging_handle(pointer, grab, visible)
        edge = "left" if frame["x"] - visible["x"] <= 32 else "right"
        panel = None
        if size:
            anchor = handle_frame(visible, edge, vertical_ratio(frame, visible), horizontal_ratio(frame, visible))
            panel = panel_placement(anchor, size, visible, self.store.settings["edge"])
        return {"handle": frame, "verticalRatio": vertical_ratio(frame, visible), "horizontalRatio": horizontal_ratio(frame, visible), "panel": panel}

