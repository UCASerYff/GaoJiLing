"""已安装应用的只读清单，以及用户明确选定的独立目录的废纸篓事务。

不执行厂商卸载命令，不改注册表，不删除偏好、共享组件或搞系列资料。
"""

from __future__ import annotations

import json
import hashlib
import os
import stat
import time
import uuid
from pathlib import Path

from gaojiling.errors import AppError
from gaojiling.filemeta import blocked, checked_stat, identity, local_path
from gaojiling.filesafety import atomic_text, owned_by_current_user, rename_exclusive

PROTECTED_NAMES = ("gaojiling", "gaoseries", "搞系列", "搞机灵", "搞图", "搞文", "搞档", "搞音", "搞盘", "搞扫描", "搞字幕")
_PACKAGE_EXTENSIONS = {".exe", ".dll", ".pyd", ".ocx", ".mui", ".manifest", ".pak", ".rcc", ".qm", ".mo", ".ttf", ".otf"}
_PACKAGE_DOCS = {"license", "license.txt", "license.md", "readme", "readme.txt", "readme.md", "copying", "notice.txt"}
_PRIVATE_DIRS = {"data", "userdata", "user data", "profile", "profiles", "settings", "config", "preferences", "documents",
                 "projects", "downloads", "logs", "log", "cache", "caches", "saves", "backup", "backups"}


def is_protected(name: str, path: str) -> str | None:
    context = f"{name} {path}".lower()
    if any(word in context for word in PROTECTED_NAMES) or "com.gaoseries" in context or "com.apple" in context:
        return "系统或搞系列应用受保护"
    if not path:
        return None
    candidate = Path(path)
    parts = {part.casefold() for part in candidate.parts[1:]}
    if parts & {"appdata", "desktop", "documents", "downloads", "pictures", "music", "videos", "onedrive",
                "dropbox", "icloud drive", "$recycle.bin", "system volume information", "windowsapps",
                "programdata", "program files", "program files (x86)", "windows", "system32"}:
        return "系统、用户资料或共享目录受保护"
    roots = [Path.home(), Path("/System"), Path("/usr"), Path("/Library")]
    roots += [Path(value) for key in ("WINDIR", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA")
              if (value := os.getenv(key))]
    if candidate in roots or any(candidate.is_relative_to(root) for root in roots[1:]):
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
                            if not isinstance(display, str) or not display:
                                continue
                            location, location_kind = _query(item, "InstallLocation")
                            publisher, _ = _query(item, "Publisher")
                            uninstall, _ = _query(item, "UninstallString")
                            if isinstance(location, str):
                                if location_kind == winreg.REG_EXPAND_SZ:
                                    location = os.path.expandvars(location)
                                location = location.strip().strip('"')
                            apps.append({
                                "id": str(uuid.uuid5(uuid.NAMESPACE_OID, f"{int(hive)}:{key_path}:{name}")).upper(),
                                "name": display,
                                "path": location if isinstance(location, str) else "",
                                "publisher": publisher if isinstance(publisher, str) else "",
                                "uninstallString": uninstall if isinstance(uninstall, str) else "",
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


def _pe_image(path):
    if os.name != "nt":
        return True  # Non-Windows is used only for isolated transaction fixtures.
    import ctypes as ct
    from ctypes import wintypes as wt
    from gaojiling.winmetrics import bind, kernel

    binary = wt.DWORD()
    check = bind(kernel(), "GetBinaryTypeW", wt.BOOL, wt.LPCWSTR, ct.POINTER(wt.DWORD))
    return bool(check(str(path), ct.byref(binary)) and binary.value in {0, 6})


def _portable_snapshot(folder, validate):
    root = checked_stat(folder)
    if not stat.S_ISDIR(root.st_mode) or not root.st_ino:
        raise AppError("请选择可核对身份的普通程序目录。")
    digest = hashlib.sha256()
    executables = set()
    count = 0
    primary = False
    total = 0

    def walk(path, relative, depth):
        nonlocal count, primary, total
        count += 1
        if count > 30_000 or depth > 40:
            raise AppError("程序目录超过复核上限，未列为候选。")
        info = os.lstat(path)
        if (blocked(info) or info.st_dev != root.st_dev or not info.st_ino
                or not owned_by_current_user(path, info)):
            raise AppError("目录包含其他用户的对象、挂载点或云端占位，先使用厂商提供的卸载方式。")
        if stat.S_ISDIR(info.st_mode):
            if validate and depth and path.name.casefold() in _PRIVATE_DIRS:
                raise AppError("目录含应用资料、偏好或缓存，先使用厂商提供的卸载方式。")
            digest.update(json.dumps([relative, identity(info)], ensure_ascii=True, sort_keys=True).encode("ascii"))
            with os.scandir(path) as children:
                names = sorted(entry.name for entry in children)
            for name in names:
                walk(path / name, name if not relative else relative + "/" + name, depth + 1)
            return
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise AppError("目录含特殊文件或硬链接，未列为候选。")
        name, extension = path.name.casefold(), path.suffix.casefold()
        if validate and extension not in _PACKAGE_EXTENSIONS and not (depth == 1 and name in _PACKAGE_DOCS):
            raise AppError("目录有无法确认属于程序包的文件。请先把文档、偏好及业务资料分开管理。")
        if extension == ".exe":
            if validate and any(word in path.stem.casefold() for word in ("uninstall", "updater", "driver", "service", "setup", "helper")):
                raise AppError("程序带有安装、驱动、服务或后台组件，请使用厂商卸载方式。")
            executables.add(name)
            if depth == 1 and validate:
                primary = primary or _pe_image(path)
        total += info.st_size
        digest.update(json.dumps([relative, identity(info)], ensure_ascii=True, sort_keys=True).encode("ascii"))

    walk(folder, "", 0)
    if validate and not primary:
        raise AppError("未找到可核实的 Windows 主程序，只能选择独立便携程序目录。")
    return {"identity": identity(root), "digest": digest.hexdigest(), "entries": count, "bytes": total,
            "executables": sorted(executables)}


class AppInventory:
    def __init__(self, journal_dir: Path, trash, catalog=None):
        self.journal_dir = local_path(Path(journal_dir))
        self.trash = trash
        self.catalog = catalog
        self.journal_path = self.journal_dir / "journal.json"
        self.failure = None
        self.journal = {"version": 1, "batches": []}
        self.plan = {}
        self._load()

    def _load(self):
        try:
            if not os.path.lexists(self.journal_path):
                if self.journal_dir.exists() and any(self.journal_dir.iterdir()):
                    raise AppError("记录目录非空且记录缺失")
                return
            info = checked_stat(local_path(self.journal_path))
            if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
                raise AppError("记录文件属性不受支持")
            data = json.loads(self.journal_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("batches"), list):
                raise AppError("版本无法识别")
            for batch in data["batches"]:
                if not isinstance(batch["id"], str) or not isinstance(batch["receipts"], list):
                    raise AppError("批次格式无效")
                for receipt in batch["receipts"]:
                    if (not isinstance(receipt["id"], str) or not isinstance(receipt["original"], str)
                            or not isinstance(receipt["inode"], int) or not isinstance(receipt["device"], int)
                            or receipt["state"] not in {"prepared", "staged", "trashing", "trashed", "restored", "untouched"}):
                        raise AppError("回执格式无效")
            self.journal = data
        except (OSError, ValueError, TypeError, KeyError, AppError) as error:
            self.failure = AppError(f"卸载恢复记录无法读取，已停止操作：{error}")

    def _save(self):
        if self.failure:
            raise self.failure
        self.journal_dir.mkdir(parents=True, exist_ok=True)
        checked_stat(local_path(self.journal_dir))
        atomic_text(self.journal_path, json.dumps(self.journal, ensure_ascii=False, indent=2))

    def _catalog(self):
        return self.catalog if self.catalog is not None else list_windows_uninstall()

    def history(self):
        if self.failure:
            return []
        rows = []
        for batch in reversed(self.journal["batches"]):
            kept = [receipt for receipt in batch["receipts"] if receipt["state"] != "untouched"]
            if not kept:
                continue
            pending = sum(receipt["state"] != "restored" for receipt in kept)
            date = batch.get("date")
            rows.append({
                "id": batch["id"], "date": date, "dateKnown": date is not None, "itemCount": len(kept),
                "restorableCount": pending, "bytes": sum((receipt.get("footprint") or {}).get("bytes", 0) for receipt in kept),
                "summary": f"{pending} 项待核实恢复。" if pending else "此批次已恢复。",
            })
        return rows

    def refresh(self) -> dict:
        if self.failure:
            raise self.failure
        apps = list(self._catalog())
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
                "movable": False,
                "reason": reason,
                "uninstallString": app.get("uninstallString") or "",
            }
            self.plan[item["id"]] = item
            listed.append(item)
        return {"apps": listed, "notes": ["候选默认不选。业务资料、偏好、钥匙串和共享组件都保留。", "不能承诺卸载后没有任何残留。"]}

    def add_portable(self, path: Path, name: str | None = None) -> dict:
        if self.failure:
            raise self.failure
        folder = local_path(Path(path))
        self._check_destination(folder, name or folder.name)
        snapshot = _portable_snapshot(folder, validate=True)
        item = {
            "id": str(uuid.uuid4()).upper(),
            "name": name or folder.name,
            "path": str(folder),
            "kind": "portable",
            "movable": True,
            "uninstallString": "",
            "bytes": snapshot["bytes"],
            "entryCount": snapshot["entries"],
            "reason": None,
            "selected": False,
        }
        self.plan[item["id"]] = dict(item, footprint=snapshot)
        return item

    def _check_destination(self, folder, name):
        protected = is_protected(name, str(folder))
        if protected or len(folder.parts) < 3 or self.journal_dir.is_relative_to(folder):
            raise AppError(protected or "卷根和应用资料目录不能移动。")
        if os.name == "nt":
            import ctypes as ct
            from ctypes import wintypes as wt
            from gaojiling.winmetrics import bind, kernel

            drive_type = bind(kernel(), "GetDriveTypeW", wt.UINT, wt.LPCWSTR)
            if drive_type(folder.anchor) != 3:  # DRIVE_FIXED
                raise AppError("仅支持能够核实回收路径的本机固定卷。")
        for entry in self._catalog():
            install = entry.get("path")
            if entry.get("kind") != "registered" or not install or not Path(install).is_absolute():
                continue
            try:
                target = local_path(Path(install))
            except AppError:
                continue
            if len(target.parts) > 1 and (folder.is_relative_to(target) or target.is_relative_to(folder)):
                raise AppError("目录和已安装应用路径重叠，请使用 Windows 或厂商的卸载方式。")

    def uninstall(self, ids: list[str], running=None) -> dict:
        if self.failure:
            raise self.failure
        if not ids:
            raise AppError("没有选中的应用。")
        batch = {"id": str(uuid.uuid4()).upper(), "date": time.time(), "receipts": []}
        removed, failed = [], []
        from gaojiling.processes import process_running_under

        check_running = running or process_running_under
        for item_id in dict.fromkeys(ids):
            item = self.plan.get(item_id)
            if item is None:
                failed.append({"itemID": item_id, "message": "清单已失效，请重新读取。"})
                continue
            if not item["movable"]:
                failed.append({"itemID": item_id, "message": item["reason"] or "这项不能由本程序移动。"})
                continue
            folder = Path(item["path"])
            footprint = item["footprint"]
            expected = footprint["identity"]
            stage = folder.with_name(".GaoJiLing-UninstallStage-" + uuid.uuid4().hex)
            receipt = None

            def require_stopped(path):
                active = (check_running(str(path), footprint["executables"]) if check_running is process_running_under
                          else check_running(str(path)))
                if active is not False:
                    reason = "应用仍在运行" if active else "无法确认应用或后台进程已经退出"
                    raise AppError(reason + "，已停止。")

            try:
                self._check_destination(folder, item["name"])
                require_stopped(folder)
                if _portable_snapshot(folder, validate=True) != footprint:
                    raise AppError("程序目录在复核后发生变化。请重新选择。")
                receipt = {"id": item_id, "name": item["name"], "original": str(folder),
                           "inode": expected["inode"], "device": expected["device"], "stage": str(stage),
                           "footprint": footprint, "trash": None, "state": "prepared"}
                batch["receipts"].append(receipt)
                if batch not in self.journal["batches"]:
                    self.journal["batches"].append(batch)
                self._save()
                require_stopped(folder)
                rename_exclusive(folder, stage, expected)
                receipt["state"] = "staged"
                self._save()
                require_stopped(stage)
                if _portable_snapshot(stage, validate=False) != footprint:
                    raise AppError("暂存后目录身份或资料已变化，未回收。")
                receipt["state"] = "trashing"
                self._save()
                destination = local_path(Path(self.trash(stage)))
                receipt["trash"] = str(destination)
                if os.path.lexists(stage) or identity(checked_stat(destination)) != expected:
                    raise AppError("未能核实回收后的程序目录身份。")
                receipt["state"] = "trashed"
                self._save()
                removed.append(item_id)
                self.plan.pop(item_id, None)
            except (OSError, AppError) as error:
                failed.append({"itemID": item_id, "message": str(error)})
                if receipt is not None:
                    try:
                        if os.path.lexists(stage) and not os.path.lexists(folder):
                            rename_exclusive(stage, folder, expected)
                            receipt["state"] = "restored"
                        elif receipt["state"] == "prepared" and identity(checked_stat(folder)) == expected:
                            receipt["state"] = "untouched"
                        self._save()
                    except (OSError, AppError):
                        pass
        return {"removedIDs": removed, "failed": failed, "batchID": batch["id"],
                "message": f"已核实 {len(removed)} 项进入回收站。{len(failed)} 项需检查。回收站仍占用磁盘空间。"}

    def restore(self, batch_id: str | None = None) -> dict:
        if self.failure:
            raise self.failure
        restored, failed = [], []
        for batch in reversed(self.journal["batches"]):
            if (batch_id and batch["id"] != batch_id
                    or not any(receipt["state"] not in {"restored", "untouched"} for receipt in batch["receipts"])):
                continue
            for receipt in batch["receipts"]:
                if receipt["state"] in {"restored", "untouched"}:
                    continue
                try:
                    original = local_path(Path(receipt["original"]))
                    source_value = receipt.get("trash") or receipt.get("stage")
                    source = local_path(Path(source_value)) if source_value else None
                    if (source is None or not os.path.lexists(source)) and os.path.lexists(original):
                        existing = checked_stat(original)
                        if (existing.st_dev, existing.st_ino) == (receipt["device"], receipt["inode"]):
                            receipt["state"] = "untouched" if receipt["state"] == "prepared" else "restored"
                            self._save()
                            continue
                    if not source_value:
                        raise AppError("原回执未记录可核实的恢复来源。")
                    if is_protected(receipt.get("name") or original.name, str(original)):
                        raise AppError("记录的原位置属于保护范围。")
                    if os.path.lexists(original):
                        raise AppError("原位置已有新文件，未覆盖。")
                    info = checked_stat(source)
                    if int(info.st_dev) != receipt["device"] or int(info.st_ino) != receipt["inode"]:
                        raise AppError("目录身份已变化，未覆盖。")
                    footprint = receipt.get("footprint")
                    if footprint and _portable_snapshot(source, validate=False) != footprint:
                        raise AppError("目录内容或归属已变化，未覆盖。")
                    if not stat.S_ISDIR(info.st_mode) or not owned_by_current_user(source, info):
                        raise AppError("恢复来源不是已核实的本人目录。")
                    rename_exclusive(source, original, identity(info))
                    receipt["state"] = "restored"
                    self._save()
                    restored.append(receipt["id"])
                except (OSError, AppError) as error:
                    failed.append({"itemID": receipt["id"], "message": str(error)})
            break
        return {"restored": restored, "failed": failed}
