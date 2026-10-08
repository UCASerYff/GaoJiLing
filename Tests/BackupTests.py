#!/usr/bin/env python3
"""Synthetic upgrade fixtures only; never read real application data."""
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("upgrade_backup", Path(__file__).resolve().parents[1] / "Scripts/backup-data.py")
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gaojiling-backup-fixture-", dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.data = self.root / "Data"
        self.data.mkdir()
        self.target = self.root / "Backup"
        self.preferences = plistlib.dumps({"GaoJiLing.EdgeHandle.horizontal": 0.41, "NSWindow Frame Main": "fixture"})
        self.now = time.time()
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.executescript("CREATE TABLE samples(t REAL PRIMARY KEY,payload TEXT NOT NULL); CREATE TABLE events(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE sessions(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL);")
            db.execute("INSERT INTO samples VALUES(?,?)", (self.now - 10, '{"fixture":true}'))
            db.execute("INSERT INTO events VALUES(?,?,?)", ("event", self.now - 10, '{"fixture":true}'))
            db.execute("INSERT INTO sessions VALUES(?,?,?)", ("session", self.now - 100, '{"fixture":true}'))
            db.execute("INSERT INTO preferences VALUES(1,?)", ('{"retentionDays":7}',))
        (self.data / "Recovery").mkdir()
        (self.data / "Recovery/合成附件.bin").write_bytes(b"fixture-attachment" * 100)

    def tearDown(self):
        self.temp.cleanup()

    def make(self):
        return backup.make_backup(self.data, self.target, self.preferences, home=self.root)

    def verify(self):
        backup.verify_update(self.target, self.data, self.preferences)

    def test_full_backup_integrity_and_new_observations(self):
        self.make()
        self.assertEqual(backup.manifest(self.data), backup.manifest(self.target / "Data"))
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o700)
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("INSERT INTO samples VALUES(?,?)", (self.now, '{"new":true}'))
        self.verify()

    def test_missing_database_does_not_create_empty_data(self):
        (self.data / "monitor.sqlite").unlink()
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())
        self.assertFalse((self.data / "monitor.sqlite").exists())

    def test_corrupt_database_blocks_backup(self):
        (self.data / "monitor.sqlite").write_bytes(b"corrupt fixture")
        with self.assertRaises(sqlite3.DatabaseError): self.make()
        self.assertFalse(self.target.exists())

    def test_symlink_attachment_blocks_verified_marker(self):
        (self.data / "linked").symlink_to(self.data / "Recovery/合成附件.bin")
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_change_during_copy_blocks_verified_marker(self):
        original = backup.shutil.copytree
        def copy_and_change(*args, **kwargs):
            result = original(*args, **kwargs)
            (self.data / "Recovery/合成附件.bin").write_bytes(b"changed")
            return result
        with patch.object(backup.shutil, "copytree", side_effect=copy_and_change):
            with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_missing_or_changed_attachment_fails_verification(self):
        self.make()
        (self.data / "Recovery/合成附件.bin").write_bytes(b"changed")
        with self.assertRaises(RuntimeError): self.verify()

    def test_task_and_position_are_preserved(self):
        self.make()
        altered = plistlib.dumps({"GaoJiLing.EdgeHandle.horizontal": 0.1})
        with self.assertRaises(RuntimeError): backup.verify_update(self.target, self.data, altered)
        with sqlite3.connect(self.data / "monitor.sqlite") as db: db.execute("DELETE FROM sessions")
        with self.assertRaises(RuntimeError): self.verify()

    def test_expected_retention_and_minute_downsampling_are_allowed(self):
        minute = int((self.now - 2 * 86400) / 60) * 60
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.executemany("INSERT INTO samples VALUES(?,?)", [(minute + 1, "first"), (minute + 20, "second"), (self.now - 8 * 86400, "expired")])
        self.make()
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("DELETE FROM samples WHERE t=? OR t=?", (minute + 20, self.now - 8 * 86400))
        self.verify()
        with sqlite3.connect(self.data / "monitor.sqlite") as db: db.execute("DELETE FROM samples WHERE t=?", (minute + 1,))
        with self.assertRaises(RuntimeError): self.verify()

    def test_unverified_backup_is_never_trusted(self):
        self.make()
        (self.target / "VERIFIED").unlink()
        with self.assertRaises(RuntimeError): self.verify()

    def test_expected_interrupted_task_recovery_only(self):
        task = {"name": "fixture", "start": self.now - 100 - 978307200, "lastObserved": self.now - 10 - 978307200}
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("UPDATE sessions SET payload=?", (json.dumps(task),))
        self.make()
        task.update(end=task["lastObserved"], interrupted=True)
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("UPDATE sessions SET payload=?", (json.dumps(task, sort_keys=True),))
        self.verify()
        task["name"] = "unexpected change"
        with sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("UPDATE sessions SET payload=?", (json.dumps(task),))
        with self.assertRaises(RuntimeError): self.verify()

    def test_receipt_recovery_objects_are_copied_and_verified(self):
        identifier = str(uuid.uuid4()).upper()
        stage = self.root / "Library/Caches/.GaoJiLing-CleanupStage" / ("GaoJiLing-" + identifier)
        stage.parent.mkdir(parents=True)
        stage.write_bytes(b"own staged fixture")
        info = stage.stat()
        (self.data / "Cleanup").mkdir()
        journal = {"version": 1, "batches": [{"receipts": [{"id": identifier, "state": "staged", "stage": str(stage),
            "footprint": {"identity": {"device": info.st_dev, "inode": info.st_ino}}}]}]}
        (self.data / "Cleanup/journal.json").write_text(json.dumps(journal))
        self.make()
        copied = list((self.target / "RecoveryObjects").iterdir())
        self.assertEqual(len(copied), 1)
        self.assertEqual(copied[0].read_bytes(), stage.read_bytes())
        self.verify()
        stage.write_bytes(b"changed")
        with self.assertRaises(RuntimeError): self.verify()

if __name__ == "__main__":
    unittest.main()
