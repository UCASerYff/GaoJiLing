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

    def make(self, confirmed=None):
        return backup.make_backup(self.data, self.target, self.preferences, home=self.root, confirmed_missing_cleanup=confirmed)

    def verify(self, confirmed=None):
        return backup.verify_update(self.target, self.data, self.preferences, home=self.root, confirmed_missing_cleanup=confirmed)

    def write_private(self, path, value):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps(value)); path.chmod(0o600)

    def cleanup_fixture(self, missing=True, identifier=None):
        identifier = identifier or str(uuid.uuid4()).upper()
        stage = self.root / "Library/Caches/.GaoJiLing-CleanupStage" / ("GaoJiLing-" + identifier)
        stage.parent.mkdir(parents=True, exist_ok=True)
        stage.write_bytes(b"synthetic pending log")
        info = stage.stat()
        receipt = {"id": identifier, "itemID": str(uuid.uuid4()), "state": "staged", "stage": str(stage),
            "original": str(self.root / "Library/Logs/com.example.backup/old.log.1"), "owner": "com.example.backup", "category": "旧轮转日志",
            "footprint": {"identity": {"device": info.st_dev, "inode": info.st_ino, "kind": 32768}, "digest": "a" * 64,
                          "bytes": info.st_blocks * 512, "newest": info.st_mtime, "entries": 1}}
        ledger = {"version": 1, "batches": [{"id": str(uuid.uuid4()), "receipts": [receipt]}]}
        self.write_private(self.data / "Cleanup/journal.json", ledger)
        if missing: stage.unlink()
        policy = {"version": 1, "reason": "userConfirmedExternalRemoval", "receiptIDs": [identifier]}
        return stage, receipt, ledger, policy

    def duplicate_fixture(self, location="trash"):
        scope = self.root / "Samples"
        scope.mkdir()
        original, keeper = scope / "candidate.bin", scope / "keeper.bin"
        original.write_bytes(b"exact duplicate fixture" * 40); keeper.write_bytes(original.read_bytes())
        info = original.stat(); parent = scope.stat()
        def directory_identity(value): return {"device": value.st_dev, "inode": value.st_ino, "uid": value.st_uid}
        identity = {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid, "mode": info.st_mode,
            "linkCount": info.st_nlink, "byteCount": info.st_size, "allocatedBytes": info.st_blocks * 512,
            "mtimeSeconds": info.st_mtime_ns // 1_000_000_000, "mtimeNanoseconds": info.st_mtime_ns % 1_000_000_000,
            "ctimeSeconds": info.st_ctime_ns // 1_000_000_000, "ctimeNanoseconds": info.st_ctime_ns % 1_000_000_000}
        identifier = str(uuid.uuid4()).upper()
        stage = self.root / "Library/Caches/.GaoJiLing-DuplicateStage" / ("GaoJiLing-Duplicate-" + identifier)
        trash = self.root / ".Trash" / stage.name
        receipt = {"id": identifier, "itemID": "synthetic-file-identity", "original": str(original), "keeper": str(keeper),
            "stage": str(stage), "identity": identity, "sha256": hashlib.sha256(original.read_bytes()).hexdigest(),
            "parentIdentity": directory_identity(parent), "state": "prepared"}
        actual = original
        if location in ("stage", "trash"):
            actual = stage if location == "stage" else trash
            actual.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            original.rename(actual); receipt["state"] = "staged" if location == "stage" else "trashed"
            if location == "trash": receipt["trash"] = str(trash)
        ledger = {"version": 1, "batches": [{"id": str(uuid.uuid4()), "date": self.now - 978307200,
            "scope": str(scope), "scopeIdentity": directory_identity(parent), "receipts": [receipt]}]}
        self.write_private(self.data / "Duplicates/journal.json", ledger)
        marker = self.data / "Duplicates.initialized"
        marker.write_bytes(backup.DUPLICATE_MARKER); marker.chmod(0o600)
        return actual, receipt, ledger

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

    def test_missing_cleanup_entity_also_blocks_upgrade(self):
        identifier = str(uuid.uuid4()).upper()
        stage = self.root / "Library/Caches/.GaoJiLing-CleanupStage" / ("GaoJiLing-" + identifier)
        stage.parent.mkdir(parents=True)
        stage.write_bytes(b"synthetic pending log")
        info = stage.stat()
        (self.data / "Cleanup").mkdir()
        journal = {"version": 1, "batches": [{"id": str(uuid.uuid4()), "receipts": [{"id": identifier,
            "itemID": str(uuid.uuid4()), "state": "staged", "stage": str(stage),
            "original": str(self.root / "Library/Logs/com.example.backup/old.log.1"), "owner": "com.example.backup", "category": "旧轮转日志",
            "footprint": {"identity": {"device": info.st_dev, "inode": info.st_ino, "kind": 32768}, "digest": "a" * 64,
                          "bytes": info.st_blocks * 512, "newest": info.st_mtime, "entries": 1}}]}]}
        (self.data / "Cleanup/journal.json").write_text(json.dumps(journal))
        (self.data / "Cleanup/journal.json").chmod(0o600)
        stage.unlink()
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

    def test_exact_confirmed_cleanup_missing_is_retained_as_unrecoverable(self):
        _, receipt, _, policy = self.cleanup_fixture()
        journal = (self.data / "Cleanup/journal.json").read_bytes()
        destination, missing = self.make(policy)
        self.assertEqual(destination, self.target)
        self.assertEqual(len(missing), 1)
        self.assertFalse(missing[0]["recoverable"])
        self.assertEqual(missing[0]["receipt"], receipt)
        self.assertEqual(missing[0]["expectedIdentity"]["inode"], receipt["footprint"]["identity"]["inode"])
        self.assertTrue(all(not item["exists"] for item in missing[0]["locations"]))
        baseline = json.loads((self.target / "baseline.json").read_text())
        self.assertEqual(baseline["missingCleanup"], missing)
        self.assertEqual((self.target / "Data/Cleanup/journal.json").read_bytes(), journal)
        self.assertEqual((self.data / "Cleanup/journal.json").read_bytes(), journal)
        self.assertIn("externally removed Cleanup receipts: 1", (self.target / "VERIFIED").read_text())
        self.assertEqual(self.verify(policy), missing)
        with self.assertRaises(RuntimeError): self.verify()

    def test_confirmation_requires_exact_missing_receipt_set(self):
        stage, _, _, policy = self.cleanup_fixture()
        unknown = dict(policy, receiptIDs=[str(uuid.uuid4()).upper()])
        extra = dict(policy, receiptIDs=policy["receiptIDs"] + [str(uuid.uuid4()).upper()])
        for altered in (unknown, extra):
            with self.subTest(kind=altered):
                with self.assertRaises(RuntimeError): self.make(altered)
                self.assertFalse(self.target.exists())
        # A confirmation cannot convert a replacement at the exact stage path
        # into a missing original, even if it contains identical bytes.
        stage.write_bytes(b"synthetic pending log")
        with self.assertRaises(RuntimeError): self.make(policy)
        self.assertFalse(self.target.exists())

    def test_confirmation_schema_and_private_file_are_strict(self):
        _, _, _, policy = self.cleanup_fixture()
        path = self.root / "consent.json"
        self.write_private(path, policy)
        self.assertEqual(backup.load_confirmed_missing(path), backup.confirmed_missing_policy(policy))
        malformed = [dict(policy, version=True), dict(policy, version=2), dict(policy, reason="ignore"),
            dict(policy, receiptIDs=[]), dict(policy, receiptIDs=["not-a-uuid"]),
            dict(policy, receiptIDs=policy["receiptIDs"] * 2), dict(policy, extra=True)]
        for value in malformed:
            self.write_private(path, value)
            with self.assertRaises(RuntimeError): backup.load_confirmed_missing(path)
        self.write_private(path, policy); path.chmod(0o644)
        with self.assertRaises(RuntimeError): backup.load_confirmed_missing(path)
        path.chmod(0o600)
        alias = self.root / "consent-link.json"; alias.symlink_to(path)
        with self.assertRaises(RuntimeError): backup.load_confirmed_missing(alias)
        path.write_text('{"version":1,"version":1,"reason":"userConfirmedExternalRemoval","receiptIDs":[]}')
        with self.assertRaises(RuntimeError): backup.load_confirmed_missing(path)

    def test_confirmation_does_not_allow_other_modules_or_new_missing(self):
        _, _, ledger, policy = self.cleanup_fixture()
        trash, _, _ = self.uninstall_fixture(linked=False)
        backup.shutil.rmtree(trash)
        with self.assertRaises(RuntimeError): self.make(policy)
        self.assertFalse(self.target.exists())
        backup.shutil.rmtree(self.data / "Uninstall"); (self.data / "Uninstall.initialized").unlink()
        another = dict(ledger["batches"][0]["receipts"][0])
        another["id"] = str(uuid.uuid4()).upper(); another["itemID"] = str(uuid.uuid4())
        another["stage"] = str(self.root / "Library/Caches/.GaoJiLing-CleanupStage" / ("GaoJiLing-" + another["id"]))
        ledger["batches"][0]["receipts"].append(another)
        self.write_private(self.data / "Cleanup/journal.json", ledger)
        with self.assertRaises(RuntimeError): self.make(policy)
        self.assertFalse(self.target.exists())

    def test_missing_confirmation_never_adopts_new_original_object(self):
        _, receipt, _, policy = self.cleanup_fixture()
        original = Path(receipt["original"])
        original.parent.mkdir(parents=True); original.write_bytes(b"new unrelated original")
        _, missing = self.make(policy)
        observation = next(item for item in missing[0]["locations"] if item["path"] == str(original))
        self.assertTrue(observation["exists"])
        self.assertNotEqual(observation["inode"], receipt["footprint"]["identity"]["inode"])
        self.assertFalse((self.target / "RecoveryObjects").exists())
        self.verify(policy)
        original.write_bytes(b"changed unrelated original")
        with self.assertRaises(RuntimeError): self.verify(policy)

    def test_missing_receipt_or_location_change_after_backup_blocks_verify(self):
        stage, _, ledger, policy = self.cleanup_fixture()
        self.make(policy)
        ledger["batches"][0]["receipts"][0]["state"] = "restored"
        self.write_private(self.data / "Cleanup/journal.json", ledger)
        with self.assertRaises(RuntimeError): self.verify(policy)
        ledger["batches"][0]["receipts"][0]["state"] = "staged"
        self.write_private(self.data / "Cleanup/journal.json", ledger)
        stage.write_bytes(b"new unrelated stage")
        with self.assertRaises(RuntimeError): self.verify(policy)

    def test_missing_location_change_during_copy_never_marks_verified(self):
        _, receipt, _, policy = self.cleanup_fixture()
        original = Path(receipt["original"])
        walk = backup.tree_manifest
        def copy_and_change(*args, **kwargs):
            result = walk(*args, **kwargs)
            if kwargs.get("copy_to") == self.target / "Data":
                original.parent.mkdir(parents=True); original.write_bytes(b"new object")
            return result
        with patch.object(backup, "tree_manifest", side_effect=copy_and_change):
            with self.assertRaises(RuntimeError): self.make(policy)
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_duplicate_recovery_file_and_marker_are_copied_verified(self):
        actual, receipt, _ = self.duplicate_fixture()
        journal = (self.data / "Duplicates/journal.json").read_bytes()
        _, missing = self.make()
        self.assertEqual(missing, [])
        copied = next((self.target / "RecoveryObjects").iterdir())
        self.assertEqual(hashlib.sha256(copied.read_bytes()).hexdigest(), receipt["sha256"])
        self.assertEqual((self.target / "Data/Duplicates.initialized").read_bytes(), backup.DUPLICATE_MARKER)
        self.assertEqual((self.target / "Data/Duplicates/journal.json").read_bytes(), journal)
        self.verify()
        copied.write_bytes(b"backup corrupted")
        with self.assertRaises(RuntimeError): self.verify()
        self.assertTrue(actual.exists())

    def test_duplicate_prepared_original_is_backed_without_moving_it(self):
        actual, _, _ = self.duplicate_fixture(location="original")
        identity = actual.stat().st_ino
        self.make(); self.verify()
        self.assertEqual(actual.stat().st_ino, identity)
        self.assertEqual(len(list((self.target / "RecoveryObjects").iterdir())), 1)

    def test_duplicate_missing_entity_and_orphan_stage_block_backup(self):
        actual, _, _ = self.duplicate_fixture(location="stage")
        contents = actual.read_bytes(); actual.unlink()
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())
        actual.write_bytes(contents)
        (self.data / "Duplicates/journal.json").unlink()
        with self.assertRaises(RuntimeError): self.make()
        (self.data / "Duplicates.initialized").unlink()
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_marker_bad_future_and_incomplete_schema_fail_closed(self):
        _, _, ledger = self.duplicate_fixture()
        path, marker = self.data / "Duplicates/journal.json", self.data / "Duplicates.initialized"
        for value in (dict(ledger, version=2), dict(ledger, unexpected=True), {"version": 1}, {"version": True, "batches": []}):
            self.write_private(path, value)
            with self.assertRaises(RuntimeError): self.make()
        self.write_private(path, ledger)
        marker.write_bytes(b"wrong marker")
        with self.assertRaises(RuntimeError): self.make()
        marker.write_bytes(backup.DUPLICATE_MARKER); marker.chmod(0o644)
        with self.assertRaises(RuntimeError): self.make()
        marker.chmod(0o600); path.unlink()
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_receipt_paths_types_and_identity_are_strict(self):
        _, receipt, ledger = self.duplicate_fixture()
        path = self.data / "Duplicates/journal.json"
        original = json.loads(json.dumps(receipt))
        changes = [dict(original, original=str(self.root / "outside.bin")),
            dict(original, keeper=str(self.root / "outside-keeper.bin")),
            dict(original, keeper="/" + original["keeper"]),
            dict(original, stage=str(self.root / "wrong-stage")),
            dict(original, trash=str(self.root / ".Trash/not-a-receipt")),
            dict(original, state="unknown"), dict(original, sha256="a" * 63),
            dict(original, identity=dict(original["identity"], linkCount=2)),
            dict(original, identity=dict(original["identity"], uid=os.getuid() + 1)),
            dict(original, identity=dict(original["identity"], mode=16384)),
            dict(original, identity=dict(original["identity"], mtimeNanoseconds=1_000_000_000)),
            dict(original, parentIdentity=dict(original["parentIdentity"], uid=os.getuid() + 1)),
            dict(original, extra=True)]
        for changed in changes:
            ledger["batches"][0]["receipts"] = [changed]; self.write_private(path, ledger)
            with self.assertRaises(RuntimeError): self.make()
            self.assertFalse(self.target.exists())

    def test_duplicate_protected_document_database_and_app_paths_block(self):
        _, receipt, ledger = self.duplicate_fixture()
        scope = Path(ledger["batches"][0]["scope"])
        for protected in (scope / "notes.txt", scope / "data.sqlite", scope / "Foo.app/file.bin", scope / ".git/data.bin",
                          scope / "Library/data.bin", scope / "GaoSeries/data.bin", scope / "搞app/data.bin",
                          self.root / "Documents/data.bin", self.root / "Desktop/data.bin", self.root / "Downloads/data.bin"):
            receipt["original"] = str(protected)
            ledger["batches"][0]["scope"] = str(self.root)
            self.write_private(self.data / "Duplicates/journal.json", ledger)
            with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_replacement_hardlink_and_metadata_change_block(self):
        actual, _, _ = self.duplicate_fixture(location="stage")
        moved = actual.with_name("moved-away")
        actual.rename(moved); actual.write_bytes(moved.read_bytes())
        with self.assertRaises(RuntimeError): self.make()
        actual.unlink(); moved.rename(actual)
        hardlink = self.root / "hardlink"; os.link(actual, hardlink)
        with self.assertRaises(RuntimeError): self.make()
        hardlink.unlink()
        actual.chmod(0o400)
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_same_inode_same_metadata_wrong_content_is_rejected(self):
        actual, receipt, _ = self.duplicate_fixture(location="stage")
        before = actual.stat()
        with actual.open("r+b") as output: output.write(b"x")
        os.utime(actual, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(actual.stat().st_ino, receipt["identity"]["inode"])
        self.assertEqual(actual.stat().st_size, receipt["identity"]["byteCount"])
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_cloud_cross_volume_and_linked_parent_are_rejected(self):
        actual, receipt, ledger = self.duplicate_fixture(location="stage")
        real_stat = backup.os.stat
        class CloudInfo:
            st_flags = backup.DATALESS
        def cloud_stat(name, *args, **kwargs):
            if str(name) == actual.name: return CloudInfo()
            return real_stat(name, *args, **kwargs)
        with patch.object(backup.os, "stat", side_effect=cloud_stat):
            with self.assertRaises(RuntimeError): self.make()
        fake_device = receipt["identity"]["device"] + 1
        receipt["identity"]["device"] = fake_device
        receipt["parentIdentity"]["device"] = fake_device
        ledger["batches"][0]["scopeIdentity"]["device"] = fake_device
        self.write_private(self.data / "Duplicates/journal.json", ledger)
        with self.assertRaises(RuntimeError): self.make()
        receipt["identity"]["device"] -= 1; receipt["parentIdentity"]["device"] -= 1; ledger["batches"][0]["scopeIdentity"]["device"] -= 1
        self.write_private(self.data / "Duplicates/journal.json", ledger)
        real = actual.parent.with_name("real-stage")
        actual.parent.rename(real); actual.parent.symlink_to(real)
        with self.assertRaises(RuntimeError): self.make()
        self.assertFalse(self.target.exists())

    def test_duplicate_record_changes_and_new_missing_after_backup_block_verify(self):
        actual, receipt, ledger = self.duplicate_fixture()
        self.make(); self.verify()
        actual.unlink()
        with self.assertRaises((RuntimeError, FileNotFoundError)): self.verify()
        receipt["state"] = "restored"
        self.write_private(self.data / "Duplicates/journal.json", ledger)
        with self.assertRaises(RuntimeError): self.verify()

    def test_cleanup_confirmation_never_exempts_duplicate_missing_entity(self):
        actual, duplicate, _ = self.duplicate_fixture()
        _, _, _, policy = self.cleanup_fixture(identifier=duplicate["id"])
        actual.unlink()
        with self.assertRaises(RuntimeError): self.make(policy)
        self.assertFalse(self.target.exists())

    def test_duplicate_completed_records_preserve_journal_without_claiming_recovery(self):
        actual, receipt, ledger = self.duplicate_fixture()
        actual.unlink(); receipt["state"] = "restored"
        self.write_private(self.data / "Duplicates/journal.json", ledger)
        self.make(); self.verify()
        self.assertFalse((self.target / "RecoveryObjects").exists())
        self.assertEqual(json.loads((self.target / "Data/Duplicates/journal.json").read_text()), ledger)

    def test_duplicate_unknown_stage_entity_is_preserved_and_blocks_backup(self):
        actual, _, _ = self.duplicate_fixture(location="stage")
        orphan = actual.with_name("GaoJiLing-Duplicate-" + str(uuid.uuid4()).upper())
        orphan.write_bytes(b"unarchived object")
        with self.assertRaises(RuntimeError): self.make()
        self.assertEqual(orphan.read_bytes(), b"unarchived object")
        self.assertFalse(self.target.exists())

if __name__ == "__main__":
    unittest.main()
