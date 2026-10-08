#!/usr/bin/env python3
"""Private, verified upgrade backup; never put its output in a release package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import time
import uuid

IDENTIFIER = "com.gaoseries.GaoJiLing"
DATA = Path.home() / "Library/Application Support/GaoSeries/GaoJiLing"
BACKUPS = DATA.parent / "GaoJiLing-Backups"

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()

def file_digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()

def row_digest(row, columns):
    normalized = list(row)
    if "payload" in columns:
        index = columns.index("payload")
        try: normalized[index] = json.loads(normalized[index])
        except (ValueError, TypeError): pass
    return digest(normalized)

def manifest(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise RuntimeError("资料目录不存在或不是普通目录；不会按空资料覆盖")
    result = {}
    for path in sorted(directory.rglob("*")):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise RuntimeError("资料包含链接或特殊文件，需要先核对完整备份范围")
        if path.is_file():
            result[str(path.relative_to(directory))] = file_digest(path)
    return result

def records(directory):
    file = directory / "monitor.sqlite"
    if not file.is_file() or file.is_symlink():
        raise RuntimeError("原数据库缺失，未创建空数据库或覆盖资料")
    db = sqlite3.connect(file.as_uri() + "?mode=ro", uri=True)
    try:
        db.execute("BEGIN")
        if db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("数据库完整性检查失败，未继续安装")
        tables = {}
        for name in ("samples", "events", "sessions", "preferences"):
            columns = [row[1] for row in db.execute("PRAGMA table_info(" + name + ")")]
            if not columns:
                raise RuntimeError("数据库结构缺失，未作为空资料处理")
            tables[name] = {}
            for row in db.execute("SELECT * FROM " + name):
                result = {"digest": row_digest(row, columns), "time": row[columns.index("t")] if "t" in columns else None}
                if name == "sessions":
                    payload = json.loads(row[columns.index("payload")])
                    if isinstance(payload, dict) and "start" in payload and payload.get("end") is None:
                        # Match the app's documented interrupted-task recovery only.
                        observed = payload.get("lastObserved")
                        if observed is None:
                            sample = db.execute("SELECT t FROM samples WHERE t>=? ORDER BY t DESC LIMIT 1", (payload["start"] + 978307200,)).fetchone()
                            observed = sample[0] - 978307200 if sample else payload["start"]
                        expected = dict(payload, end=max(payload["start"], observed), interrupted=True)
                        alternate = list(row); alternate[columns.index("payload")] = json.dumps(expected)
                        result["interruptedDigest"] = row_digest(alternate, columns)
                tables[name][str(row[0])] = result
        setting = db.execute("SELECT payload FROM preferences WHERE id=1").fetchone()
        retention = json.loads(setting[0]).get("retentionDays", 7) if setting else 7
        schema = digest(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall())
        return {"tables": tables, "retention": retention, "schema": schema}
    finally:
        db.rollback()
        db.close()

def defaults():
    data = subprocess.check_output(["defaults", "export", IDENTIFIER, "-"], stderr=subprocess.DEVNULL)
    plistlib.loads(data)  # Fail on unreadable or malformed preferences.
    return data

def object_manifest(path):
    if path.is_symlink(): raise RuntimeError("恢复项目不能是链接")
    if path.is_dir(): return manifest(path)
    if path.is_file(): return {"": file_digest(path)}
    raise RuntimeError("恢复项目不是普通文件或目录")

def recovery_objects(source, home):
    """Only this product's identity-checked receipts, never the whole Trash."""
    journal = source / "Cleanup/journal.json"
    if not journal.exists(): return {}
    if journal.is_symlink(): raise RuntimeError("清理恢复记录不能是链接")
    ledger = json.loads(journal.read_text())
    if ledger.get("version") != 1 or not isinstance(ledger.get("batches"), list):
        raise RuntimeError("清理恢复记录无法识别，停止升级")
    stage_root = home / "Library/Caches/.GaoJiLing-CleanupStage"
    trash_root = home / ".Trash"
    objects = {}
    for batch in ledger["batches"]:
        for receipt in batch["receipts"]:
            if receipt["state"] in ("restored", "untouched"): continue
            if receipt["state"] not in ("prepared", "staged", "trashing", "trashed"):
                raise RuntimeError("清理恢复状态无效，停止升级")
            identifier = str(uuid.UUID(receipt["id"])).upper()
            name = "GaoJiLing-" + identifier
            stage = Path(receipt["stage"])
            if stage != stage_root / name: raise RuntimeError("清理暂存路径无效")
            paths = [stage]
            if receipt.get("trash"):
                trash = Path(receipt["trash"])
                per_volume = trash.parent.name == str(os.getuid()) and trash.parent.parent.name == ".Trashes"
                if (trash.parent != trash_root and not per_volume) or not trash.name.startswith(name): raise RuntimeError("清理废纸篓路径无效")
                paths.append(trash)
            elif receipt["state"] == "trashing" and trash_root.exists():
                # Recover the unique receipt after a crash between Trash and save.
                paths.extend(path for path in trash_root.iterdir() if path.name.startswith(name))
            for path in paths:
                if not path.exists() and not path.is_symlink(): continue
                if path.resolve() != path: raise RuntimeError("恢复项目路径含链接，停止升级")
                info = path.lstat(); identity = receipt["footprint"]["identity"]
                if info.st_uid != os.getuid() or info.st_dev != identity["device"] or info.st_ino != identity["inode"]:
                    raise RuntimeError("恢复项目身份发生变化，停止升级")
                objects[str(path)] = object_manifest(path)
    return objects

def make_backup(source, destination, preferences, home=None):
    plistlib.loads(preferences)
    baseline = records(source)
    before = manifest(source)
    recovery = recovery_objects(source, home or Path.home())
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    shutil.copytree(source, destination / "Data", copy_function=shutil.copy2, symlinks=False)
    if manifest(source) != before or manifest(destination / "Data") != before:
        raise RuntimeError("备份期间资料变化或校验失败，保留原资料和备份，停止安装")
    if records(destination / "Data") != baseline:
        raise RuntimeError("备份数据库摘要不一致，停止安装")
    for name, content in recovery.items():
        path = Path(name)
        target = destination / "RecoveryObjects" / hashlib.sha256(name.encode()).hexdigest()
        target.parent.mkdir(mode=0o700, exist_ok=True)
        if path.is_dir(): shutil.copytree(path, target, copy_function=shutil.copy2)
        else: shutil.copy2(path, target)
        if object_manifest(path) != content or object_manifest(target) != content:
            raise RuntimeError("清理恢复实物备份校验失败，停止安装")
    if manifest(source) != before:
        raise RuntimeError("资料或恢复记录在备份期间变化，停止安装")
    (destination / "preferences.plist").write_bytes(preferences)
    (destination / "baseline.json").write_text(json.dumps({"data": baseline, "files": before, "recovery": recovery}, ensure_ascii=False))
    for path in destination.iterdir():
        if path.is_file():
            path.chmod(0o600)
    (destination / "VERIFIED").write_text("Complete data, attachments, database integrity and preferences verified.\n")
    (destination / "VERIFIED").chmod(0o600)
    return destination

def verify_update(backup, source, preferences):
    if not (backup / "VERIFIED").is_file():
        raise RuntimeError("未找到已核验备份，停止清理旧程序")
    old = json.loads((backup / "baseline.json").read_text())
    current = records(source)
    baseline = old["data"]
    if current["schema"] != baseline["schema"] or current["retention"] != baseline["retention"]:
        raise RuntimeError("资料结构或保留设置发生意外变化")
    now = time.time()
    cutoff = now - max(1, min(30, baseline["retention"])) * 86400
    yesterday = now - 86400
    minima = {}
    for row in baseline["tables"]["samples"].values():
        stamp = row["time"]
        if cutoff <= stamp < yesterday:
            minute = int(stamp / 60)
            minima[minute] = min(minima.get(minute, stamp), stamp)
    for name, rows in baseline["tables"].items():
        for key, row in rows.items():
            stamp = row["time"]
            if name in ("samples", "events") and stamp < cutoff:
                continue
            if name == "samples" and stamp < yesterday and minima[int(stamp / 60)] != stamp:
                continue
            accepted = [row["digest"]]
            if name == "sessions" and "interruptedDigest" in row: accepted.append(row["interruptedDigest"])
            if current["tables"][name].get(key, {}).get("digest") not in accepted:
                raise RuntimeError("原历史、任务或设置未通过保留核验")
    for name, checksum in old["files"].items():
        if name in ("monitor.sqlite", "monitor.sqlite-wal", "monitor.sqlite-shm"):
            continue  # SQLite is validated by rows while new observations are appended.
        file = source / name
        if not file.is_file() or file.is_symlink() or file_digest(file) != checksum:
            raise RuntimeError("原附件或恢复资料未通过保留核验")
    for name, content in old.get("recovery", {}).items():
        if object_manifest(Path(name)) != content:
            raise RuntimeError("原清理恢复实物未通过保留核验")
    previous = plistlib.loads((backup / "preferences.plist").read_bytes())
    current_defaults = plistlib.loads(preferences)
    for key, value in previous.items():
        if key.startswith("GaoJiLing.EdgeHandle.") and current_defaults.get(key) != value:
            raise RuntimeError("原唤起条设置未通过保留核验")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-version")
    parser.add_argument("--to-version")
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        verify_update(args.verify, DATA, defaults())
        print("PASS: 原资料、全部附件、历史、任务、设置与数据库完整性核验通过；安全备份保留。")
    else:
        if subprocess.run(["pgrep", "-x", "GaoJiLing"], stdout=subprocess.DEVNULL).returncode == 0:
            raise RuntimeError("请先正常退出搞机灵，再建立稳定备份")
        if not args.from_version or not args.to_version:
            parser.error("缺少更新前后版本")
        if not all(re.fullmatch(r"[0-9]+\.[0-9]{2}", version) for version in (args.from_version, args.to_version)):
            parser.error("版本必须为 1.00 格式")
        BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
        if BACKUPS.is_symlink():
            raise RuntimeError("备份目录不能是符号链接")
        name = "V" + args.from_version + "-before-V" + args.to_version + "-" + time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(3).hex()
        target = make_backup(DATA, BACKUPS / name, defaults())
        print(str(target))

if __name__ == "__main__":
    main()
