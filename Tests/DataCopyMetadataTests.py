#!/usr/bin/env python3
"""Isolated copy/restore metadata tests; no installed app or personal data."""
import base64
import hashlib
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import BackupTests as fixtures

backup = fixtures.backup


class DataCopyMetadataTests(unittest.TestCase):
    setUp = fixtures.BackupTests.setUp
    tearDown = fixtures.BackupTests.tearDown
    make = fixtures.BackupTests.make
    verify = fixtures.BackupTests.verify
    write_private = fixtures.BackupTests.write_private
    duplicate_fixture = fixtures.BackupTests.duplicate_fixture
    uninstall_fixture = fixtures.BackupTests.uninstall_fixture

    def provenance_fixture(self):
        """Inject only per-inode OS-assigned bytes; all real checks still run."""
        original = backup.extended_attributes
        self.overrides = {}
        def attributes(fd, output=None, provenance=None, data_copy=False):
            result = original(fd, output, provenance, data_copy)
            info = os.fstat(fd)
            raw = self.overrides.get(info.st_ino, ("synthetic-os-provenance:" + str(info.st_ino)).encode())
            result[backup.PROVENANCE] = hashlib.sha256(raw).hexdigest()
            if provenance is not None:
                provenance.clear()
                provenance.update(base64=base64.b64encode(raw).decode(), byteCount=len(raw),
                                  sha256=hashlib.sha256(raw).hexdigest())
            return result
        return patch.object(backup, "extended_attributes", side_effect=attributes)

    def test_copy_and_restore_record_distinct_raw_provenance_without_changing_source(self):
        with self.provenance_fixture():
            original = backup.data_tree_state(self.data)
            metadata = backup.copy_data_tree(self.data, self.root / "Copy")
            self.assertNotEqual(metadata["sourceTree"], metadata["copyTree"])
            self.assertTrue(backup.data_copy_equivalent(metadata["sourceTree"], metadata["copyTree"]))
            backup.verify_data_copy(metadata, self.root / "Copy", source=self.data, source_identity=True)
            restored = backup.copy_data_tree(self.root / "Copy", self.root / "Restored")
            backup.verify_data_copy(restored, self.root / "Restored", source=self.root / "Copy", source_identity=True)
            self.assertNotEqual(restored["sourceProvenance"], restored["copyProvenance"])
            self.assertEqual(original, backup.data_tree_state(self.data))
            for evidence in (metadata, restored):
                backup.validate_provenance(evidence["sourceTree"], evidence["sourceProvenance"])
                backup.validate_provenance(evidence["copyTree"], evidence["copyProvenance"])

    def test_full_backup_and_recovery_objects_use_their_own_exact_copy_tree(self):
        actual, _, _ = self.duplicate_fixture()
        with self.provenance_fixture():
            original = backup.data_tree_state(actual)
            self.make(); self.verify()
            baseline = json.loads((self.target / "baseline.json").read_text())
            metadata = baseline["copyMetadata"]["recovery"][str(actual)]
            self.assertNotEqual(metadata["sourceTree"], metadata["copyTree"])
            self.assertEqual(original, backup.data_tree_state(actual))
            copied = next((self.target / "RecoveryObjects").iterdir())
            self.overrides[copied.stat().st_ino] = b"changed-after-verification"
            with self.assertRaises(RuntimeError): self.verify()

    def test_logical_sqlite_snapshot_records_all_fixed_metadata_and_checks_backup_rows(self):
        with self.provenance_fixture():
            original = backup.sqlite_metadata(self.data)
            self.make(); self.verify()
            evidence = json.loads((self.target / "baseline.json").read_text())["copyMetadata"]["sqlite"]
            self.assertEqual(evidence["kind"], "logicalSQLiteSnapshot")
            self.assertEqual(evidence["source"], original)
            self.assertEqual(set(evidence["copy"]), backup.DB_FILES)
            self.assertFalse(evidence["source"]["monitor.sqlite-wal"]["present"])
            self.assertFalse(evidence["copy"]["monitor.sqlite-shm"]["present"])
            self.assertNotEqual(evidence["source"]["monitor.sqlite"]["provenance"], evidence["copy"]["monitor.sqlite"]["provenance"])
            # Change rows while keeping the saved stat metadata view fixed:
            # the logical database check must independently detect the change.
            with fixtures.sqlite3.connect(self.target / "Data/monitor.sqlite") as db:
                db.execute("DELETE FROM events")
            metadata = backup.sqlite_metadata
            def prior_copy(path):
                if path == self.target / "Data": return evidence["copy"]
                return metadata(path)
            with patch.object(backup, "sqlite_metadata", side_effect=prior_copy):
                with self.assertRaises(RuntimeError): self.verify()
            self.assertEqual(backup.sqlite_metadata(self.data), original)

    def test_source_provenance_change_during_copy_is_refused(self):
        walk = backup.tree_manifest
        def change(*args, **kwargs):
            result = walk(*args, **kwargs)
            if kwargs.get("copy_to") == self.target / "Data":
                self.overrides[self.data.stat().st_ino] = b"source-changed"
            return result
        with self.provenance_fixture(), patch.object(backup, "tree_manifest", side_effect=change):
            with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_equal_content_source_inode_replacement_is_refused(self):
        walk = backup.tree_manifest
        def change(*args, **kwargs):
            result = walk(*args, **kwargs)
            if kwargs.get("copy_to") == self.target / "Data":
                path = self.data / "Recovery/合成附件.bin"
                raw = path.read_bytes(); path.unlink(); path.write_bytes(raw)
            return result
        with patch.object(backup, "tree_manifest", side_effect=change):
            with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_recovery_child_identity_replacement_after_backup_is_refused(self):
        actual, _, _ = self.uninstall_fixture(linked=False)
        self.make(); self.verify()
        before = backup.tree_manifest(actual, allow_links=True)
        path = actual / "Contents/resource"
        old_identity = path.stat().st_ino
        # Keep the old inode allocated so the replacement cannot reuse it.
        with path.open("rb") as pinned:
            raw = pinned.read(); path.unlink(); path.write_bytes(raw)
            self.assertNotEqual(path.stat().st_ino, old_identity)
        self.assertEqual(backup.tree_manifest(actual, allow_links=True), before)
        with self.assertRaises(RuntimeError): self.verify()

    def test_other_attributes_modes_content_and_entries_remain_strict(self):
        tree = {"": {"type": "file", "mode": 0o600, "sha256": "a" * 64,
                     "xattrs": {backup.PROVENANCE: "p", "com.apple.macl": "m", "com.apple.quarantine": "q", "com.example.test": "t"}}}
        for name in ("com.apple.macl", "com.apple.quarantine", "com.example.test"):
            for operation in ("change", "remove"):
                other = json.loads(json.dumps(tree))
                if operation == "change": other[""]["xattrs"][name] = "changed"
                else: del other[""]["xattrs"][name]
                self.assertFalse(backup.data_copy_equivalent(tree, other))
        for field, value in (("mode", 0o644), ("sha256", "b" * 64)):
            other = json.loads(json.dumps(tree)); other[""][field] = value
            self.assertFalse(backup.data_copy_equivalent(tree, other))
        other = json.loads(json.dumps(tree)); other[""]["xattrs"]["new.attribute"] = "new"
        self.assertFalse(backup.data_copy_equivalent(tree, other))
        self.assertFalse(backup.data_copy_equivalent(tree, {}))

    def test_real_other_attribute_copy_corruption_is_refused(self):
        library = fixtures.ctypes.CDLL(None, use_errno=True)
        library.fsetxattr.argtypes = [fixtures.ctypes.c_int, fixtures.ctypes.c_char_p,
            fixtures.ctypes.c_void_p, fixtures.ctypes.c_size_t, fixtures.ctypes.c_uint32, fixtures.ctypes.c_int]
        walk = backup.tree_manifest
        def corrupt_copy(*args, **kwargs):
            result = walk(*args, **kwargs)
            if kwargs.get("copy_to") == self.target / "Data":
                fd = os.open(self.target / "Data/Recovery/合成附件.bin", os.O_RDONLY)
                try: self.assertEqual(library.fsetxattr(fd, b"com.example.GaoJiLingFixture", b"unexpected", 10, 0, 0), 0)
                finally: os.close(fd)
            return result
        with patch.object(backup, "tree_manifest", side_effect=corrupt_copy):
            with self.assertRaises(RuntimeError): self.make()
        self.assertFalse((self.target / "VERIFIED").exists())

    def test_absent_provenance_evidence_and_legacy_backup_compatibility(self):
        tree = {"": {"type": "file", "mode": 0o600, "sha256": "f", "xattrs": {}}}
        backup.validate_provenance(tree, {"": None})
        with self.assertRaises(RuntimeError): backup.validate_provenance(tree, {})
        with self.assertRaises(RuntimeError): backup.validate_provenance(tree, {"": {}})
        self.make()
        path = self.target / "baseline.json"
        old = json.loads(path.read_text()); old.pop("copyMetadata")
        path.write_text(json.dumps(old)); self.verify()

    def test_provenance_evidence_corruption_and_copy_content_changes_are_refused(self):
        with self.provenance_fixture():
            metadata = backup.copy_data_tree(self.data, self.root / "Copy")
            corrupt = json.loads(json.dumps(metadata))
            corrupt["sourceProvenance"][""]["base64"] = base64.b64encode(b"forged").decode()
            with self.assertRaises(RuntimeError): backup.verify_data_copy(corrupt, self.root / "Copy")
            (self.root / "Copy/Recovery/合成附件.bin").write_bytes(b"changed")
            with self.assertRaises(RuntimeError): backup.verify_data_copy(metadata, self.root / "Copy")


if __name__ == "__main__":
    unittest.main()
