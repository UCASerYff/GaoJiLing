"""把各模块串成一个本地服务。测试可以关掉采样线程并注入采集器。"""

from __future__ import annotations

import os
import json
import platform
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import unquote, urlsplit

from gaojiling.apps import AppInventory
from gaojiling.backup import backup_bytes, build_backup, load_backup
from gaojiling.cleanup import CleanupEngine
from gaojiling.csvexport import events_csv, history_csv, sessions_csv
from gaojiling.duplicates import DuplicateEngine
from gaojiling.errors import AppError
from gaojiling.events import BatteryNoticeDetector, EventDetector, sampling_interval
from gaojiling.exchange import ExchangeInbox
from gaojiling.exitpolicy import ExitPolicy
from gaojiling.filesafety import atomic_text, send_to_trash
from gaojiling.geometry import PanelAutoCollapse, dragging_handle, handle_frame, horizontal_ratio, panel_placement, vertical_ratio
from gaojiling.memory import release_own, snapshot as memory_snapshot, system_cache_report
from gaojiling.processes import cleanup_owner_installed, cleanup_owner_running
from gaojiling.metrics import MetricCollector
from gaojiling.network import diagnose
from gaojiling.ntfs import analyze_image, extract
from gaojiling.storageanal import analyze, analyze_dev, compare_history
from gaojiling.store import MonitorStore, normalize_settings
from gaojiling.timeutil import now_unix
from gaojiling.version import display
from gaojiling.volumes import WindowsVolumeProvider, collect as collect_volumes


def default_data_dir() -> Path:
    if os.name == "nt":
        root = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        return Path(root) / "GaoSeries" / "GaoJiLing"
    return Path.home() / ".local" / "share" / "GaoSeries" / "GaoJiLing"


def _write_new(path: Path, data: bytes):
    try:
        with path.open("xb") as handle:
            handle.write(data)
    except FileExistsError:
        raise AppError("目标已存在，未覆盖。") from None


class Service:
    def __init__(self, data_dir: Path, home: Path | None = None, collector=None, start_sampling: bool = False,
                 layout: str | None = None, trash=None, volume_provider=None, app_catalog=None):
        self.data_dir = Path(data_dir)
        self.home = Path(home) if home else Path.home()
        self.store = MonitorStore(self.data_dir)
        self.collector = collector or MetricCollector()
        self.detector = EventDetector()
        self.battery_detector = BatteryNoticeDetector()
        self.desktop = None
        self.startup = None
        self.last_export = None
        self.hardware = f"{platform.machine()} · {os.cpu_count() or '未知'} 个逻辑处理器"
        self._interactive = 0.0
        self._panel_visible = False
        self._last_stored = None
        self._data_lock = threading.RLock()
        self._mutation_lock = threading.Lock()
        self._work_guard = threading.Lock()
        self._work = {}
        self.latest = None
        self.paused = False
        self.active = None
        self.message = self.store.status
        self.cleanup = CleanupEngine(
            self.home, self.data_dir / "Cleanup", self.data_dir / "CleanupStage",
            layout or ("windows" if os.name == "nt" else "darwin"),
            running=cleanup_owner_running, owner_lookup=cleanup_owner_installed, trash=trash or send_to_trash,
        )
        self.duplicates = DuplicateEngine(self.data_dir / "Duplicates", self.data_dir / "DuplicateStage", self.home, trash or send_to_trash)
        self.apps = AppInventory(self.data_dir / "Uninstall", trash or send_to_trash, catalog=app_catalog)
        self.exchange = ExchangeInbox(self.data_dir / "Exchange")
        self.exit_policy = ExitPolicy()
        self.exit_rules = []
        self.exit_enabled = False
        self.review_inputs = {}
        self.panel_state = PanelAutoCollapse()
        self.storage_history = []
        self.storage_history_path = self.data_dir / "storage-history.json"
        self.storage_history_writable = True
        self._load_storage_history()
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
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join()
        with self._mutation_lock, self._data_lock:
            self._reset_collector()
            self.store.close()

    @property
    def stopping(self) -> bool:
        return self._stop.is_set()

    @property
    def data_busy(self) -> bool:
        with self._work_guard:
            return self._mutation_lock.locked() or bool(self._work)

    @contextmanager
    def mutation(self):
        if not self._mutation_lock.acquire(blocking=False):
            raise AppError("另一个工作正在进行。")
        try:
            if self.stopping:
                raise AppError("搞机灵正在退出。")
            yield
        finally:
            self._mutation_lock.release()

    def prepare_shutdown(self, confirm_active=None) -> bool:
        """Prevent new mutations, then finalize the task before stopping sampling."""
        if self.stopping:
            return True
        with self.mutation():
            with self._work_guard:
                if self._work:
                    raise AppError("另一个工作正在进行。")
            with self._data_lock:
                name = self.active["name"] if self.active is not None else None
            # Sampling can continue while the user decides. Task mutations are held.
            if name is not None and confirm_active is not None and not confirm_active(name):
                return False
            with self._data_lock:
                if self.active is not None:
                    try:
                        self._stop_session()
                    except sqlite3.Error as error:
                        raise AppError(f"任务未能保存，搞机灵仍在运行。{error}") from error
                self._stop.set()
        return True

    def _reset_collector(self):
        reset = getattr(self.collector, "reset", None)
        if reset:
            reset()

    def _notify(self, notice):
        if self.desktop:
            self.desktop.notify(notice["title"], notice["detail"])

    @contextmanager
    def job(self, kind):
        stop = threading.Event()
        with self._work_guard:
            if self._work:
                raise AppError("另一个工作正在进行。")
            self._work[kind] = stop
        try:
            yield stop.is_set
        finally:
            with self._work_guard:
                self._work.pop(kind, None)

    def cancel(self, kind):
        with self._work_guard:
            stop = self._work.get(kind)
            if stop:
                stop.set()
        return {"ok": bool(stop)}

    def _loop(self):
        while not self._stop.is_set():
            if not self.paused:
                try:
                    self.sample_once()
                except (AppError, OSError) as error:
                    self.message = str(error)
            interval = sampling_interval(
                self.store.settings["sampleInterval"], time.monotonic() - self._interactive <= 12,
                self._panel_visible, self.active is not None,
                self.store.db is not None, self.exit_enabled,
            )
            self._stop.wait(interval)

    def sample_once(self, sample: dict | None = None) -> dict:
        with self._data_lock:
            if self.paused or self.stopping:
                return self.latest
            current = sample if sample is not None else self.collector.sample()
            moment = current["timestamp"] = current.get("timestamp") or now_unix()
            self.latest = current
            if self.store.db is not None:
                if sample is not None or self._last_stored is None or moment - self._last_stored >= 9.5 or moment < self._last_stored:
                    self.store.add_sample(current)
                    self._last_stored = moment
                for event in self.detector.evaluate(current):
                    self.store.add_event(event)
                    if self.store.settings["notificationsEnabled"]:
                        self._notify(event)
            for notice in self.battery_detector.evaluate(current.get("batterySnapshot"), self.store.settings, moment):
                self._notify(notice)
            if self.active is not None:
                cpu = current.get("cpuPercent")
                if cpu is not None:
                    self.active["peakCPU"] = max(self.active["peakCPU"], cpu)
                    self.active["cpuTotal"] += cpu
                    self.active["sampleCount"] += 1
                memory = current.get("memoryUsed")
                if memory is not None:
                    self.active["peakMemory"] = max(self.active["peakMemory"], memory)
                temperature = current.get("cpuTemperature")
                peak = self.active["peakTemperature"]
                if temperature is not None and (peak is None or temperature > peak):
                    self.active["peakTemperature"] = temperature
                self.active["lastObserved"] = moment
                self.store.save_session(self.active)
            return current

    def set_paused(self, paused: bool):
        with self._data_lock:
            self.paused = bool(paused)
            self.detector.reset()
            self.battery_detector.reset()
            self._reset_collector()

    def start_session(self, name: str) -> dict:
        with self._data_lock:
            return self._start_session(name)

    def _start_session(self, name: str) -> dict:
        title = (name or "").strip()
        if not title or len(title) > 200:
            raise AppError("请填写任务名称。")
        if self.active is not None:
            raise AppError("已有任务正在记录。")
        session = {
            "id": str(uuid.uuid4()).upper(), "name": title, "start": now_unix(), "end": None,
            "peakCPU": 0, "peakMemory": 0, "peakTemperature": None, "sampleCount": 0, "cpuTotal": 0,
            "lastObserved": None, "interrupted": None,
        }
        self.store.save_session(session)
        self.active = session
        return session

    def stop_session(self) -> dict:
        with self._data_lock:
            return self._stop_session()

    def _stop_session(self) -> dict:
        if self.active is None:
            raise AppError("没有正在记录的任务。")
        finished = {**self.active, "end": max(self.active["start"], now_unix()), "interrupted": False}
        self.store.save_session(finished)
        self.active = None
        return finished

    def state(self) -> dict:
        with self._data_lock:
            return self._state()

    def _state(self) -> dict:
        since = now_unix() - 1800
        history = self.store.history(since) if self.store.db is not None else []
        interval = self.store.settings["sampleInterval"]
        gap_list = []
        for left, right in zip(history, history[1:]):
            if right["timestamp"] - left["timestamp"] > max(15, interval * 3):
                gap_list.append({"after": left["timestamp"], "before": right["timestamp"]})
        counts = self.store.counts()
        return {
            "version": display(),
            "hardware": self.hardware,
            "desktop": self.desktop.status() if self.desktop else {"available": False},
            "startup": self.startup.status() if self.startup else {"available": False, "reason": "当前运行方式未注册 Windows 登录项。"},
            "dataBytes": self._data_bytes(),
            "lastExport": bool(self.last_export),
            "message": self.message,
            "paused": self.paused,
            "settings": self.store.settings,
            "panel": self.store.panel,
            "latest": self.latest,
            "history": [self._trend_sample(item) for item in history[-180:]],
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
            "duplicateHistory": self.duplicates.history() if hasattr(self.duplicates, "history") else [],
            "apps": (self.last_apps or {}).get("apps", []),
            "uninstallHistory": self.apps.history() if hasattr(self.apps, "history") else [],
            "volumes": self.last_volumes,
            "ntfs": self._public_ntfs(),
            "network": self.network_checks,
            "exitRules": self.exit_rules,
            "exchange": [self._public_request(item) for item in self.exchange.records],
            "reviewInputs": self.review_inputs,
        }

    def update_settings(self, changes: dict):
        with self._data_lock:
            merged = normalize_settings({**self.store.settings, **changes})
            if "launchAtLogin" not in changes or self.startup is None:
                return self.store.update_settings(merged)
            self.store.require()
            if not self.store.settings_writable:
                raise AppError("原设置读取异常，暂不覆盖。")
            before = self.startup.status().get("registered")
            self.startup.set_enabled(merged["launchAtLogin"])
            try:
                return self.store.update_settings(merged)
            except Exception:
                if isinstance(before, bool):
                    self.startup.set_enabled(before)
                raise

    def _data_bytes(self):
        size = 0
        for name in ("monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"):
            try:
                size += (self.data_dir / name).stat().st_size
            except FileNotFoundError:
                continue
            except OSError:
                return None
        return size

    def history_range(self, after, before):
        with self._data_lock:
            return [self._trend_sample(item) for item in self.store.history(float(after), float(before))]

    @staticmethod
    def _trend_sample(item):
        result = {key: item.get(key) for key in ("timestamp", "cpuPercent", "networkDown", "networkUp")}
        memory, total = item.get("memoryUsed"), item.get("memoryTotal")
        result["memoryPercent"] = memory / total * 100 if memory is not None and total else None
        return result

    def export_csv(self, kind: str, path: Path, after=0, before=None, session_id=None):
        after = float(after or 0)
        before = now_unix() + 1 if before is None else float(before)
        with self._data_lock:
            if kind == "history":
                data = history_csv(self.store.history(after, before))
            elif kind == "events":
                data = events_csv([event for event in self.store.events() if after <= event["date"] <= before])
            elif kind == "sessions":
                data = sessions_csv([item for item in self.store.sessions() if item.get("end") is not None
                                     and after <= item["start"] <= before and (not session_id or item["id"] == session_id)])
            else:
                raise AppError("未知的导出类别。")
        _write_new(Path(path), data)
        self.last_export = Path(path)
        return {"path": str(path), "message": "已导出 CSV。文件含本机名称和时间，请自行保管。"}

    def export_backup(self, path: Path):
        with self._data_lock:
            return self._export_backup(path)

    def _export_backup(self, path: Path):
        auxiliary = {}
        if self.store.panel.get("horizontalRatio") is not None:
            auxiliary["GaoJiLing.EdgeHandle.horizontalRatio"] = str(self.store.panel["horizontalRatio"])
        auxiliary["GaoJiLing.EdgeHandle.verticalRatio"] = str(self.store.panel["verticalRatio"])
        if self.store.panel.get("displayId"):
            auxiliary["GaoJiLing.EdgeHandle.displayId"] = self.store.panel["displayId"]
        document = build_backup(self.store.history(0), self.store.events(), self.store.sessions(), self.store.settings, auxiliary, now_unix())
        _write_new(Path(path), backup_bytes(document))
        self.last_export = Path(path)
        return {"path": str(path), "message": "已导出完整资料。恢复不会自动备份当前数据。"}

    def restore_backup(self, path: Path, confirm: bool):
        with self._data_lock:
            return self._restore_backup(path, confirm)

    def _restore_backup(self, path: Path, confirm: bool):
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
        self.battery_detector.reset()
        self._last_stored = None
        return {"message": "已从所选文件恢复。这次没有自动备份被替换的数据。清理、卸载和重复文件记录未改动。"}

    def clear_data(self, scope: str, before: float | None = None):
        if scope == "sessions" and self.active:
            raise AppError("请先结束正在记录的任务。")
        with self._data_lock:
            deleted = self.store.clear(scope, before)
        return {"deleted": deleted, "message": "只清除了所选类别。任务、设置或其他类别未一起删除。" if scope != "sessions" else "已清除所选任务记录。"}

    def cleanup_scan(self):
        with self.job("cleanup") as cancelled:
            self.last_cleanup = self.cleanup.scan(cancelled)
            return self.last_cleanup

    def cleanup_trash(self, ids, confirm: bool, review_id=None):
        if not confirm:
            raise AppError("需要确认后才会移入废纸篓。")
        def run():
            with self.job("cleanup") as cancelled:
                return self.cleanup.trash(ids, cancelled)
        result = self._review_move(review_id, "cleanup.review", run)
        if self.last_cleanup:
            self.last_cleanup["items"] = [item for item in self.last_cleanup["items"] if item["id"] not in result["removedIDs"]]
        return result

    def cleanup_restore(self, batch_id=None):
        return self.cleanup.restore(batch_id)

    def _load_storage_history(self):
        try:
            with self.storage_history_path.open(encoding="utf-8") as handle:
                items = json.load(handle)
            if not isinstance(items, list) or len(items) > 30 or any(
                not isinstance(item, dict) or not isinstance(item.get("scopeKey"), str)
                or not isinstance(item.get("complete"), bool) or not isinstance(item.get("allocatedBytes"), int)
                or not isinstance(item.get("at"), (int, float)) for item in items
            ):
                raise ValueError("占用历史的格式无效")
            self.storage_history = items
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            self.storage_history_writable = False

    def storage_scan(self, mode: str, path: str | None = None, exclusions=None, review_id=None):
        if review_id:
            self._verified_scope(review_id, path, mode, "metadata")
        def run():
            with self.job("storage") as cancelled:
                return self._storage_scan(mode, path, exclusions, cancelled)
        return self._review_storage(review_id, "metadata", run)

    def _storage_scan(self, mode, path, exclusions, cancelled):
        if mode == "dev":
            result = analyze_dev(self.home, "windows" if os.name == "nt" else "darwin", exclusions=exclusions or [], cancelled=cancelled)
            allocated = 0
            for part in result["parts"]:
                tree = part.get("tree") or {}
                allocated += tree.get("allocatedBytes") or 0
            summary = {"scopeKey": result["scopeKey"], "complete": result["complete"], "allocatedBytes": allocated, "at": now_unix()}
        elif mode == "directory":
            if not path:
                raise AppError("请选择要分析的目录。")
            result = analyze(Path(path), exclusions or [], cancelled=cancelled)
            summary = {"scopeKey": result["scopeKey"], "complete": result["complete"],
                       "allocatedBytes": (result.get("tree") or {}).get("allocatedBytes") or 0, "at": now_unix()}
        else:
            raise AppError("未知的分析范围。")
        self.storage_history.append(summary)
        self.storage_history = self.storage_history[-30:]
        if self.storage_history_writable:
            try:
                atomic_text(self.storage_history_path, json.dumps(self.storage_history, ensure_ascii=False))
            except OSError as error:
                result.setdefault("notes", []).append(f"无法保存扫描历史：{error}")
        else:
            result.setdefault("notes", []).append("原占用历史无法读取，请检查资料。此结果仅保留在当前运行中。")
        result["trend"] = compare_history(self.storage_history, summary["scopeKey"])
        self.last_storage = result
        return self._public_storage()

    def storage_csv(self, path: Path):
        result = self.last_storage
        if not result:
            raise AppError("还没有分析结果。")
        rows = [["路径", "分配字节", "逻辑字节", "文件数", "说明"]]
        trees = [part.get("tree") for part in result.get("parts", [])] if result.get("kind") == "dev" else [result.get("tree")]
        pending = [item for item in reversed(trees) if item]
        while pending:
            entry = pending.pop()
            rows.append([entry["path"], str(entry.get("allocatedBytes", "")), str(entry.get("logicalBytes", "")),
                         str(entry.get("fileCount", "")), entry.get("skipReason") or ("未完成" if not result["complete"] else "")])
            pending.extend(reversed(entry.get("children") or []))
        from gaojiling.textutil import csv_file
        _write_new(Path(path), csv_file(rows))
        self.last_export = Path(path)
        return {"path": str(path), "message": "CSV 含个人路径，只保存在所选位置。"}

    def duplicate_scan(self, path: str, confirm_read: bool, review_id=None):
        if review_id:
            self._verified_scope(review_id, path, "directory", "duplicates")
        def run():
            with self.job("duplicates") as cancelled:
                self.last_duplicates = self.duplicates.scan(Path(path), confirm_read, cancelled)
                return self.last_duplicates
        return self._review_storage(review_id, "duplicates", run)

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
        with self.job("ntfs") as cancelled:
            self.ntfs_result = analyze_image(Path(path), consent, cancelled=cancelled)
            self.last_ntfs = self._public_ntfs()
            return self.last_ntfs

    def _public_ntfs(self):
        if not self.ntfs_result:
            return None
        return {key: value for key, value in self.ntfs_result.items() if key not in {"identity", "sourcePath"} and not key.startswith("_")}

    def ntfs_report(self, path):
        result = self._public_ntfs()
        if result is None:
            raise AppError("请先分析镜像。")
        document = {"schemaVersion": 1, "reportType": "ntfs-image", "result": result}
        _write_new(Path(path), json.dumps(document, ensure_ascii=False, indent=2).encode("utf-8"))
        self.last_export = Path(path)
        return {"message": "已导出所选镜像的分析报告。"}

    def _public_storage(self):
        result = self.last_storage
        if not result:
            return None
        if result.get("kind") == "dev":
            return {key: result.get(key) for key in ("kind", "complete", "notes", "parts", "trend")}
        return {"kind": "directory", "complete": result.get("complete"), "scope": result.get("scope"),
                "notes": result.get("notes"), "trend": result.get("trend"),
                "tree": result.get("tree"), "largeFiles": result.get("largeFiles"), "cancelled": result.get("cancelled")}

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

    def app_uninstall(self, ids, confirm, review_id=None):
        if not confirm:
            raise AppError("请确认所选独立应用目录。")
        from gaojiling.processes import process_running_under
        if review_id:
            prepared = self.review_inputs.get(review_id)
            if not prepared or ids != [prepared.get("appId")]:
                raise AppError("所选应用与已复核引用不符。")
            self._local_reference(self.exchange._record(review_id))
        result = self._review_move(review_id, "apps.uninstall.review", lambda: self.apps.uninstall(ids, process_running_under))
        if self.last_apps:
            self.last_apps["apps"] = [item for item in self.last_apps["apps"] if item["id"] not in result["removedIDs"]]
        return result

    def app_add_portable(self, path, name=None):
        app = self.apps.add_portable(path, name)
        self._update_app_rows()
        return {"app": next(item for item in self.last_apps["apps"] if item["id"] == app["id"])}

    def _update_app_rows(self):
        self.last_apps = {"apps": [{key: value for key, value in item.items() if key != "footprint"}
                                   for item in self.apps.plan.values()]}

    def _public_request(self, item):
        manifest = item["manifest"]
        return {"id": item["id"], "action": manifest["action"], "source": manifest["sourceBundleID"],
                "references": manifest.get("references"), "phase": item["phase"], "outcome": item.get("outcome")}

    def review_open(self, request_id):
        result = self.exchange.open_request(request_id)
        return {"request": self._public_request(self.exchange._record(request_id)), **result}

    def _local_reference(self, record):
        text = record["manifest"]["references"][0]["fileURL"]
        url = urlsplit(text)
        if url.netloc or url.scheme != "file" or url.query or url.fragment:
            raise AppError("只接受本机文件引用。")
        name = unquote(url.path)
        if os.name == "nt" and len(name) >= 4 and name[0] == "/" and name[2:4] == ":/":
            name = name[1:]
        local = Path(name)
        if not local.is_absolute() or ".." in local.parts or "\x00" in name or local.anchor.startswith("\\\\"):
            raise AppError("只接受规范的本机绝对路径。")
        for entry in reversed((local, *local.parents)):
            info = entry.lstat()
            if entry.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise AppError("本机引用不能穿过符号链接或重解析目录。")
        return local

    def review_approve(self, request_id):
        record = self.exchange._record(request_id)
        if record["phase"] not in {"reviewing", "approved"}:
            raise AppError("请先打开并核对请求。")
        action = record["manifest"]["action"]
        details = {}
        if action == "storage.inspect":
            path = self._local_reference(record)
            if not path.is_dir():
                raise AppError("引用不是普通目录。")
            identity = path.stat()
            details = {"path": str(path), "mode": (record["manifest"].get("parameters") or {}).get("mode") or "metadata",
                       "device": identity.st_dev, "inode": identity.st_ino}
        if action == "apps.uninstall.review":
            path = self._local_reference(record)
            if path.is_file() and path.suffix.lower() == ".exe":
                path = path.parent
            app = self.app_add_portable(path)["app"]
            details = {"appId": app["id"], "path": str(path)}
        self.exchange.approve(request_id)
        if action == "cleanup.review":
            self.last_cleanup = None
            self.cleanup.plan = {}
        self.review_inputs[request_id] = details
        return details

    def _verified_scope(self, review_id, path, form, mode):
        details = self.review_inputs.get(review_id)
        if not details or form != "directory" or mode != details.get("mode") or path != details.get("path"):
            raise AppError("分析模式或目录与已复核引用不符。")
        record = self.exchange._record(review_id)
        local = self._local_reference(record)
        info = local.stat()
        if str(local) != path or (info.st_dev, info.st_ino) != (details["device"], details["inode"]):
            raise AppError("已复核引用发生变化。")

    def _review_storage(self, request_id, mode, run):
        if not request_id:
            return run()
        self.exchange.begin(request_id, "storage.inspect")
        try:
            result = run()
        except Exception:
            self.exchange.finish(request_id, "failed", {"workflowState": "failed"}, "analysisFailed")
            raise
        if mode == "duplicates":
            groups = result.get("groups") or []
            duplicate_bytes = sum(group["byteCount"] * len(group["files"]) for group in groups)
            allocations = [file.get("allocatedBytes") for group in groups for file in group["files"]]
            if any(item is None for item in allocations):
                self.exchange.finish(request_id, "failed", {"workflowState": "failed", "reason": "未能核验重复文件的本地分配字节。"})
                return {**result, "reviewFinished": True}
            allocated = sum(allocations)
            stats = {"allocatedBytes": allocated, "duplicateGroups": len(groups),
                     "duplicateFiles": sum(len(group["files"]) for group in groups),
                     "duplicateLogicalBytes": duplicate_bytes, "duplicateAllocatedBytes": allocated,
                     "contentBytesRead": result.get("contentBytesRead", 0)}
        else:
            tree = result.get("tree") or {}
            stats = {"allocatedBytes": tree.get("allocatedBytes", 0), "logicalBytes": tree.get("logicalBytes", 0),
                     "files": tree.get("fileCount", 0), "directories": tree.get("directoryCount", 0)}
        complete = bool(result["complete"])
        cancelled = bool(result.get("cancelled"))
        status = "cancelled" if cancelled else ("completed" if complete else "partial")
        reference = self.exchange._record(request_id)["manifest"]["references"][0]
        self.exchange.finish(request_id, status, {"workflowState": status, "mode": mode,
            "scope": {"referenceID": reference["id"], "displayName": reference.get("displayName") or "", "kind": "directory"},
            "complete": complete, "statistics": stats})
        return {**result, "reviewFinished": True}

    def _review_move(self, request_id, action, run):
        if not request_id:
            return run()
        self.exchange.begin(request_id, action)
        try:
            result = run()
        except Exception:
            self.exchange.finish(request_id, "failed", {"workflowState": "failed"}, "operationFailed")
            raise
        count = len(result["removedIDs"])
        failed = len(result.get("failed") or [])
        skipped = len(result.get("skipped") or [])
        remaining = bool(failed or skipped)
        statistics = {"itemCount": count, "movedBytes": result.get("movedBytes", 0)}
        statistics.update({"skippedCount": skipped, "failedCount": failed} if action == "cleanup.review" else {"issueCount": failed + skipped})
        if count:
            status = "partial" if remaining or result.get("cancelled") else "completed"
            provenance = {"workflowState": status, "receiptID": result["batchID"], **statistics}
        elif result.get("cancelled"):
            status, provenance = "cancelled", {"workflowState": "cancelled"}
        elif remaining:
            status, provenance = "failed", {"workflowState": "failed"}
        else:
            status, provenance = "partial", {"workflowState": "reviewedNoChanges", **statistics}
        self.exchange.finish(request_id, status, provenance)
        return {**result, "reviewFinished": True}

    def exchange_export(self, request_id, path):
        result = self.exchange.result_document(request_id)
        destination = Path(path)
        if destination.suffix.lower() == ".gaoaction":
            destination.mkdir(exist_ok=False)
            (destination / "payload").mkdir()
            destination = destination / "manifest.json"
        _write_new(destination, json.dumps(result, ensure_ascii=False, indent=2).encode("utf-8"))
        self.last_export = destination
        return {"message": "已导出与原请求关联的交接结果。"}

    def geometry(self, visible: dict, pointer: dict, grab: dict, size: dict | None = None):
        frame = dragging_handle(pointer, grab, visible)
        edge = "left" if frame["x"] - visible["x"] <= 32 else "right"
        panel = None
        if size:
            anchor = handle_frame(visible, edge, vertical_ratio(frame, visible), horizontal_ratio(frame, visible))
            panel = panel_placement(anchor, size, visible, self.store.settings["edge"])
        return {"handle": frame, "verticalRatio": vertical_ratio(frame, visible), "horizontalRatio": horizontal_ratio(frame, visible), "panel": panel}

