"""已安装应用的只读清单，以及用户明确选定的独立目录的废纸篓事务。

不执行厂商卸载命令，不改注册表，不删除偏好、共享组件或搞系列资料。
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filesafety import atomic_text, rename_exclusive

PROTECTED_NAMES = ("gaojiling", "搞机灵", "gaoseries", "搞系列")


def is_protected(name: str, path: str) -> str | None:
    context = f"{name} {path}".lower()
    if any(word in context for word in PROTECTED_NAMES) or "com.gaoseries" in context or "com.apple" in context:
        return "系统或搞系列应用受保护"
    lowered = path.lower()
    for root in ("c:\\windows", "c:\\program files", "c:\\program files (x86)", "/system", "/usr", "/library"):
        if lowered == root or lowered.startswith(root + "\\") or lowered.startswith(root + "/"):
            return "系统目录不移动"
    return None


def list_windows_uninstall() -> list[dict]:
    import sys
    if sys.platform != "win32":
        return []
    import winreg
    roots = [
        (winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_LOCAL_MACHINE, r"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_LOCAL_MACHINE, r"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
    ]
    apps = []
    for hive, key_path in roots:
        try:
            with winreg.OpenKey(hive, key_path) as root:
                count = winreg.QueryInfoKey(root)[0]
                for index in range(count):
                    try:
                        name = winreg.EnumKey(root, index)
                        with winreg.OpenKey(root, name) as item:
                            display, _ = _query(item, "DisplayName")
                            if not display:
                                continue
                            location, _ = _query(item, "InstallLocation")
                            uninstall, _ = _query(item, "UninstallString")
                            apps.append({
                                "id": name,
                                "name": display,
                                "path": location or "",
                                "uninstallString": uninstall or "",
                                "kind": "registered",
                                "movable": False,
                                "reason": "注册表里的应用走厂商卸载命令。这里只展示命令，不代为执行，也不删除残留。",
                            })
                    except OSError:
                        continue
        except OSError:
            continue
    return apps


def _query(key, name):
    import winreg
    try:
        return winreg.QueryValueEx(key, name)
    except OSError:
        return None, None


class AppInventory:
    def __init__(self, journal_dir: Path, trash, catalog=None):
        self.journal_dir = Path(journal_dir)
        self.trash = trash
        self.catalog = catalog
        self.journal_path = self.journal_dir / "journal.json"
        self.failure = None
        self.journal = {"version": 1, "batches": []}
        self.plan = {}
        self._load()

    def _load(self):
        if not self.journal_path.exists():
            if self.journal_dir.exists() and any(self.journal_dir.iterdir()):
                self.failure = AppError("应用管理记录目录不空但没有 journal.json，已停止。")
            return
        try:
            data = json.loads(self.journal_path.read_text(encoding="utf-8"))
            if data.get("version") != 1:
                raise AppError("版本无法识别")
            self.journal = data
        except (OSError, json.JSONDecodeError, AppError) as error:
            self.failure = AppError(f"卸载恢复记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        self.journal_dir.mkdir(parents=True, exist_ok=True)
        atomic_text(self.journal_path, json.dumps(self.journal, ensure_ascii=False, indent=2))

    def refresh(self) -> dict:
        if self.failure:
            raise self.failure
        apps = list(self.catalog) if self.catalog is not None else list_windows_uninstall()
        self.plan = {}
        listed = []
        for app in apps:
            reason = is_protected(app.get("name") or "", app.get("path") or "") or app.get("reason")
            item = {
                "id": app.get("id") or str(uuid.uuid4()).upper(),
                "name": app.get("name") or "",
                "path": app.get("path") or "",
                "kind": app.get("kind") or "portable",
                "selected": False,
                "movable": bool(app.get("movable")) and reason is None,
                "reason": reason,
                "uninstallString": app.get("uninstallString") or "",
            }
            self.plan[item["id"]] = item
            listed.append(item)
        return {"apps": listed, "notes": ["候选默认不选。业务资料、偏好、钥匙串和共享组件都保留。", "不能承诺卸载后没有任何残留。"]}

    def add_portable(self, path: Path, name: str | None = None) -> dict:
        folder = Path(path)
        if not folder.is_dir() or folder.is_symlink():
            raise AppError("只能选择一个普通目录。")
        item = {
            "id": str(uuid.uuid4()).upper(),
            "name": name or folder.name,
            "path": str(folder),
            "kind": "portable",
            "movable": True,
            "uninstallString": "",
        }
        reason = is_protected(item["name"], item["path"])
        item["reason"] = reason
        item["movable"] = reason is None
        item["selected"] = False
        self.plan[item["id"]] = item
        return item

    def uninstall(self, ids: list[str], running) -> dict:
        if self.failure:
            raise self.failure
        if not ids:
            raise AppError("没有选中的应用。")
        batch = {"id": str(uuid.uuid4()).upper(), "receipts": []}
        removed, failed = [], []
        for item_id in ids:
            item = self.plan.get(item_id)
            if item is None:
                failed.append({"itemID": item_id, "message": "清单已失效，请重新读取。"})
                continue
            if not item["movable"]:
                failed.append({"itemID": item_id, "message": item["reason"] or "这项不能由本程序移动。"})
                continue
            active = running(item["path"])
            if active is None:
                failed.append({"itemID": item_id, "message": "无法确认是否仍在运行，已停止。"})
                continue
            if active:
                failed.append({"itemID": item_id, "message": "应用仍在运行，已停止。"})
                continue
            folder = Path(item["path"])
            try:
                info = os.lstat(folder)
                receipt = {"id": item_id, "original": str(folder), "inode": int(info.st_ino), "device": int(info.st_dev),
                           "trash": None, "state": "prepared"}
                batch["receipts"].append(receipt)
                if batch not in self.journal["batches"]:
                    self.journal["batches"].append(batch)
                self._save()
                if running(item["path"]) is not False:
                    raise AppError("移动前运行状态已变化，未移动。")
                destination = Path(self.trash(folder))
                receipt["trash"] = str(destination)
                receipt["state"] = "trashed"
                self._save()
                removed.append(item_id)
            except Exception as error:
                failed.append({"itemID": item_id, "message": str(error)})
        return {"removedIDs": removed, "failed": failed, "batchID": batch["id"],
                "message": "已把选中的独立目录移入废纸篓。注册表、快捷方式和共享组件未改动，也不代表磁盘空间已经释放。"}

    def restore(self, batch_id: str | None = None) -> dict:
        if self.failure:
            raise self.failure
        restored, failed = [], []
        for batch in reversed(self.journal["batches"]):
            if batch_id and batch["id"] != batch_id:
                continue
            for receipt in batch["receipts"]:
                if receipt.get("state") == "restored":
                    continue
                source = Path(receipt.get("trash") or "")
                original = Path(receipt["original"])
                try:
                    if not source.exists():
                        raise AppError("废纸篓里已找不到该目录。")
                    if original.exists() or original.is_symlink():
                        raise AppError("原位置已有新文件，未覆盖。")
                    info = os.lstat(source)
                    if int(info.st_dev) != receipt["device"] or int(info.st_ino) != receipt["inode"]:
                        raise AppError("目录身份已变化，未覆盖。")
                    rename_exclusive(source, original)
                    receipt["state"] = "restored"
                    self._save()
                    restored.append(receipt["id"])
                except Exception as error:
                    failed.append({"itemID": receipt["id"], "message": str(error)})
            break
        return {"restored": restored, "failed": failed}
