#!/usr/bin/env python3
"""Synthetic upgrade fixtures only; never read real application data."""
import importlib.util
import json
import errno
import ctypes
import hashlib
import os
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
        self.assertEqual(backup.manifest(self.data, exclude=backup.DB_FILES), backup.manifest(self.target / "Data", exclude=backup.DB_FILES))
        self.assertEqual(backup.records(self.data), backup.records(self.target / "Data"))
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

    def test_database_parent_and_transaction_links_are_rejected(self):
        original = self.root / "RealData"
        self.data.rename(original); self.data.symlink_to(original)
        with self.assertRaises(RuntimeError): self.make()
        self.data.unlink(); original.rename(self.data)
        (self.data / "monitor.sqlite-wal").symlink_to(self.data / "Recovery/合成附件.bin")
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_change_during_copy_blocks_verified_marker(self):
        original = backup.tree_manifest
        def copy_and_change(*args, **kwargs):
            result = original(*args, **kwargs)
            if kwargs.get("copy_to") == self.target / "Data":
                (self.data / "Recovery/合成附件.bin").write_bytes(b"changed")
            return result
        with patch.object(backup, "tree_manifest", side_effect=copy_and_change):
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
        journal = {"version": 1, "batches": [{"id": str(uuid.uuid4()), "receipts": [{"id": identifier, "itemID": str(uuid.uuid4()), "state": "staged", "stage": str(stage),
            "original": str(self.root / "Library/Logs/com.example.backup/old.log.1"), "owner": "com.example.backup", "category": "旧轮转日志",
            "footprint": {"identity": {"device": info.st_dev, "inode": info.st_ino, "kind": 32768}, "digest": "a" * 64, "bytes": info.st_blocks * 512, "newest": info.st_mtime, "entries": 1}}]}]}
        (self.data / "Cleanup/journal.json").write_text(json.dumps(journal))
        (self.data / "Cleanup/journal.json").chmod(0o600)
        self.make()
        copied = list((self.target / "RecoveryObjects").iterdir())
        self.assertEqual(len(copied), 1)
        self.assertEqual(copied[0].read_bytes(), stage.read_bytes())
        self.verify()
        stage.write_bytes(b"changed")
        with self.assertRaises(RuntimeError): self.verify()

    def uninstall_fixture(self, linked=True):
        identifier = str(uuid.uuid4()).upper()
        original = self.root / "Applications/Fixture.app"
        (original / "Contents").mkdir(parents=True)
        (original / "Contents/resource").write_bytes(b"own app resource")
        outside = self.root / "outside-document"
        outside.write_bytes(b"not part of app")
        if linked: (original / "Contents/external-link").symlink_to(outside)
        info = original.stat()
        identity = {"device": info.st_dev, "inode": info.st_ino, "kind": 16384, "uid": info.st_uid}
        stage = self.root / "Library/Caches/.GaoJiLing-UninstallStage" / ("GaoJiLing-Uninstall-" + identifier)
        stage.parent.mkdir(parents=True, mode=0o700)
        trash = self.root / ".Trash" / stage.name
        trash.parent.mkdir(mode=0o700)
        original.rename(trash)
        app = {"path": str(original), "bundleID": "com.example.uninstallfixture", "identity": identity, "name": "Fixture", "version": "1.0", "metadataHash": "a" * 64}
        parent = original.parent.stat()
        receipt = {"id": identifier, "itemID": str(uuid.uuid4()), "original": str(original), "stage": str(stage), "trash": str(trash),
            "owner": app["bundleID"], "category": "应用程序", "itemKind": "application", "state": "trashed",
            "parentIdentity": {"device": parent.st_dev, "inode": parent.st_ino, "kind": 16384, "uid": parent.st_uid},
            "footprint": {"identity": identity, "digest": "a" * 64, "bytes": 4096, "newest": info.st_mtime, "entries": 3}}
        ledger = {"version": 1, "batches": [{"id": str(uuid.uuid4()), "date": self.now - 978307200, "app": app, "receipts": [receipt]}]}
        (self.data / "Uninstall").mkdir(mode=0o700)
        (self.data / "Uninstall/journal.json").write_text(json.dumps(ledger))
        (self.data / "Uninstall.initialized").write_bytes(backup.UNINSTALL_MARKER)
        (self.data / "Uninstall/journal.json").chmod(0o600)
        (self.data / "Uninstall.initialized").chmod(0o600)
        return trash, outside, ledger

    def test_uninstall_links_are_copied_as_links_and_verified(self):
        trash, outside, _ = self.uninstall_fixture()
        self.make()
        target = next((self.target / "RecoveryObjects").iterdir())
        link = target / "Contents/external-link"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(outside))
        self.assertEqual((target / "Contents/resource").read_bytes(), b"own app resource")
        self.verify()
        (trash / "Contents/external-link").unlink()
        (trash / "Contents/external-link").symlink_to(self.root / "different")
        with self.assertRaises(RuntimeError): self.verify()

    def test_recovery_identity_changed_even_same_bytes_blocks_upgrade(self):
        trash, _, _ = self.uninstall_fixture(linked=False)
        replacement = trash.with_name("moved-away")
        trash.rename(replacement)
        (trash / "Contents").mkdir(parents=True)
        (trash / "Contents/resource").write_bytes(b"own app resource")
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_missing_recovery_entity_is_not_an_empty_backup(self):
        trash, _, _ = self.uninstall_fixture(linked=False)
        backup.shutil.rmtree(trash)
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_initialized_uninstall_missing_journal_blocks_upgrade(self):
        _, _, _ = self.uninstall_fixture()
        (self.data / "Uninstall/journal.json").unlink()
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_bad_and_future_uninstall_records_are_preserved(self):
        _, _, ledger = self.uninstall_fixture()
        path = self.data / "Uninstall/journal.json"
        ledger["version"] = 2; path.write_text(json.dumps(ledger))
        before = path.read_bytes()
        with self.assertRaises(RuntimeError): self.make()
        self.assertEqual(path.read_bytes(), before)
        path.write_text("invalid")
        with self.assertRaises(json.JSONDecodeError): self.make()
        self.assertEqual(path.read_text(), "invalid")

    def test_incomplete_receipt_never_counts_as_a_verified_backup(self):
        _, _, ledger = self.uninstall_fixture()
        del ledger["batches"][0]["receipts"][0]["footprint"]["digest"]
        path = self.data / "Uninstall/journal.json"
        path.write_text(json.dumps(ledger))
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_symlinked_trash_parent_and_bad_owner_are_rejected(self):
        trash, _, ledger = self.uninstall_fixture()
        real = self.root / "real-trash"
        trash.parent.rename(real)
        trash.parent.symlink_to(real)
        with self.assertRaises(RuntimeError): self.make()
        trash.parent.unlink(); real.rename(trash.parent)
        receipt = ledger["batches"][0]["receipts"][0]
        receipt["footprint"]["identity"]["uid"] = os.getuid() + 42
        (self.data / "Uninstall/journal.json").write_text(json.dumps(ledger))
        with self.assertRaises(RuntimeError): self.make()

    def test_initialized_exchange_and_missing_maintenance_fail_closed(self):
        (self.data / "Exchange.initialized").write_bytes(b"GaoActionInboxV1\n")
        (self.data / "Exchange.initialized").chmod(0o600)
        with self.assertRaises(RuntimeError): self.make()
        (self.data / "Exchange.initialized").unlink()
        (self.data / "Maintenance").mkdir()
        with self.assertRaises(RuntimeError): self.make()

    def test_wal_commits_are_in_consistent_sqlite_snapshot(self):
        db = sqlite3.connect(self.data / "monitor.sqlite")
        try:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA wal_autocheckpoint=0")
            db.execute("INSERT INTO sessions VALUES(?,?,?)", ("wal-only", self.now, '{"retained":true}'))
            db.commit()
            self.assertGreater((self.data / "monitor.sqlite-wal").stat().st_size, 0)
            self.make()
            with sqlite3.connect(self.target / "Data/monitor.sqlite") as snapshot:
                self.assertEqual(snapshot.execute("SELECT COUNT(*) FROM sessions WHERE id='wal-only'").fetchone()[0], 1)
                self.assertEqual(snapshot.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertFalse((self.target / "Data/monitor.sqlite-wal").exists())
        finally: db.close()

    def test_storage_marker_preserved_and_missing_state_blocks_backup(self):
        marker = self.data / "Storage.initialized"
        marker.write_bytes(b"GaoJiLing.StorageAnalysis.1\n"); marker.chmod(0o600)
        with self.assertRaises(RuntimeError): self.make()
        (self.data / "Storage").mkdir()
        state = self.data / "Storage/analysis-state.json"
        state.write_text(json.dumps({"version": 1, "exclusions": [], "history": []})); state.chmod(0o600)
        self.make()
        self.assertEqual((self.target / "Data/Storage.initialized").read_bytes(), marker.read_bytes())
        self.verify()

    def test_recovery_extended_attributes_preserved(self):
        trash, _, _ = self.uninstall_fixture(linked=False)
        attribute, value = b"com.example.GaoJiLingFixture", b"synthetic-xattr\x00bytes"
        library = ctypes.CDLL(None, use_errno=True)
        library.fsetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        for path in (trash, trash / "Contents/resource"):
            fd = os.open(path, os.O_RDONLY)
            try: self.assertEqual(library.fsetxattr(fd, attribute, value, len(value), 0, 0), 0)
            finally: os.close(fd)
        self.make()
        copied = next((self.target / "RecoveryObjects").iterdir())
        manifest = backup.tree_manifest(copied)
        for key in ("", "Contents/resource"):
            self.assertEqual(manifest[key]["xattrs"][attribute.decode()], hashlib.sha256(value).hexdigest())
        self.verify()

    def test_storage_history_append_and_oldest_retention_only(self):
        (self.data / "Storage").mkdir()
        path = self.data / "Storage/analysis-state.json"
        old = {"version": 1, "exclusions": [str(self.root / "excluded")], "retainedUnknown": "keep",
               "history": [{"id": str(uuid.uuid4()), "date": self.now - 978307200 - 100 + index,
                            "totalBytes": index, "scope": "开发环境", "complete": True} for index in range(30)]}
        path.write_text(json.dumps(old)); path.chmod(0o600)
        self.make()
        added = {"id": str(uuid.uuid4()), "date": time.time() - 978307200, "totalBytes": 42, "scope": "开发环境", "complete": True}
        current = dict(old, history=old["history"][1:] + [added])
        path.write_text(json.dumps(current)); self.verify()
        for altered in [dict(current, exclusions=[]), dict(current, retainedUnknown="lost"),
                        dict(current, version=2), dict(current, history=current["history"][1:]),
                        dict(current, history=[dict(current["history"][0], totalBytes=999)] + current["history"][1:]),
                        dict(current, history=old["history"][1:] + [dict(added, date=0)])]:
            path.write_text(json.dumps(altered))
            with self.assertRaises(RuntimeError): self.verify()

    def test_disk_full_never_creates_verified_marker(self):
        with patch.object(backup.os, "write", side_effect=OSError(errno.ENOSPC, "synthetic full disk")):
            with self.assertRaises(OSError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

if __name__ == "__main__":
    unittest.main()
