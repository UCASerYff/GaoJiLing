#!/usr/bin/env python3
"""Real SQLite WAL fixtures; never open the installed app's database."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import BackupTests as fixtures

backup = fixtures.backup


class SQLiteIsolationTests(unittest.TestCase):
    setUp = fixtures.BackupTests.setUp
    tearDown = fixtures.BackupTests.tearDown
    make = fixtures.BackupTests.make
    verify = fixtures.BackupTests.verify

    def leave_committed_wal(self):
        # No live writer survives this process. An abrupt close leaves the same
        # static WAL/SHM lifecycle that live-writer-only tests did not cover.
        code = '''import os,sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("INSERT INTO sessions VALUES(?,?,?)",("committed-wal-only",1,'{"retained":true}'))
db.commit()
os._exit(0)
'''
        subprocess.run([sys.executable, "-B", "-c", code, str(self.data / "monitor.sqlite")], check=True)
        self.assertGreater((self.data / "monitor.sqlite-wal").stat().st_size, 0)

    def test_quiescent_committed_wal_backup_preserves_every_source_byte_attribute_and_identity(self):
        self.leave_committed_wal()
        before = backup.sqlite_metadata(self.data)
        tree = backup.data_tree_state(self.data)
        connect = backup.sqlite3.connect
        connections = []
        def isolated_only(path, *args, **kwargs):
            value = str(path); connections.append(value)
            self.assertFalse(value.startswith(str(self.data)) or value.startswith(self.data.as_uri()))
            self.assertIn(".noindex/", value)
            return connect(path, *args, **kwargs)
        with patch.object(backup.sqlite3, "connect", side_effect=isolated_only):
            self.make(); self.verify()
            self.assertIn("committed-wal-only", backup.records(self.target / "Data")["tables"]["sessions"])
        self.assertTrue(connections)
        self.assertEqual(before, backup.sqlite_metadata(self.data))
        self.assertEqual(tree, backup.data_tree_state(self.data))

    def test_missing_shm_is_created_only_in_private_input(self):
        self.leave_committed_wal()
        (self.data / "monitor.sqlite-shm").unlink()
        before = backup.sqlite_metadata(self.data)
        self.make(); self.verify()
        self.assertFalse((self.data / "monitor.sqlite-shm").exists())
        self.assertEqual(before, backup.sqlite_metadata(self.data))
        self.assertIn("committed-wal-only", backup.records(self.target / "Data")["tables"]["sessions"])

    def test_cleanly_closed_wal_header_and_repeated_read_validation_do_not_create_source_sidecars(self):
        with fixtures.sqlite3.connect(self.data / "monitor.sqlite") as db:
            db.execute("PRAGMA journal_mode=WAL")
        db.close()
        before = backup.sqlite_metadata(self.data)
        first = backup.records(self.data)
        self.assertEqual(first, backup.records(self.data))
        self.make(); self.verify()
        self.assertEqual(before, backup.sqlite_metadata(self.data))

    def test_source_main_wal_or_shm_content_changes_are_all_refused(self):
        self.leave_committed_wal()
        copy = backup.copy_data_tree
        for name in sorted(backup.DB_FILES):
            path = self.data / name; raw = path.read_bytes()
            changed = False
            def change_source(*args, **kwargs):
                nonlocal changed
                result = copy(*args, **kwargs)
                if not changed:
                    changed = True
                    with path.open("r+b") as file:
                        file.seek(-1, os.SEEK_END); file.write(bytes([raw[-1] ^ 1]))
                return result
            with self.subTest(name=name), patch.object(backup, "copy_data_tree", side_effect=change_source):
                with self.assertRaises(RuntimeError): backup.records(self.data)
            path.write_bytes(raw)

    def test_source_sidecar_appearance_disappearance_or_same_content_replacement_is_refused(self):
        self.leave_committed_wal()
        copy = backup.copy_data_tree
        shm = self.data / "monitor.sqlite-shm"; original = shm.read_bytes()
        for operation in ("remove", "replace", "appear"):
            if not shm.exists(): shm.write_bytes(original)
            if operation == "appear": shm.unlink()
            changed = False
            def change_source(*args, **kwargs):
                nonlocal changed
                result = copy(*args, **kwargs)
                if not changed:
                    changed = True
                    if operation in ("remove", "replace"): shm.unlink()
                    if operation in ("replace", "appear"): shm.write_bytes(original)
                return result
            # Pin the old inode to prevent the replacement reusing it.
            pin = shm.open("rb") if shm.exists() else None
            try:
                with self.subTest(operation=operation), patch.object(backup, "copy_data_tree", side_effect=change_source):
                    with self.assertRaises((RuntimeError, FileNotFoundError)): backup.records(self.data)
            finally:
                if pin: pin.close()
                if not shm.exists(): shm.write_bytes(original)

    def test_isolated_input_corruption_is_refused_before_sqlite_opens(self):
        copy = backup.copy_data_tree
        def corrupt_copy(*args, **kwargs):
            result = copy(*args, **kwargs)
            destination = Path(args[1])
            if destination.name == "monitor.sqlite": destination.write_bytes(b"corrupt private input")
            return result
        before = backup.sqlite_metadata(self.data)
        with patch.object(backup, "copy_data_tree", side_effect=corrupt_copy):
            with self.assertRaises(RuntimeError): backup.records(self.data)
        self.assertEqual(before, backup.sqlite_metadata(self.data))


if __name__ == "__main__":
    unittest.main()
