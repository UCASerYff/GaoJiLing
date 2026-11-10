#!/usr/bin/env python3
"""Focused install-safety tests using synthetic files only."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_safety_tested", HERE / "release-safety.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class TemporaryTree(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gaojiling-safety-", suffix=".noindex", dir="/private/tmp")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()


class DataPreservationTests(TemporaryTree):
    def setUp(self):
        super().setUp()
        self.data = self.root / "Data"
        self.data.mkdir()
        (self.data / "monitor.sqlite").write_bytes(b"synthetic database")
        (self.data / "monitor.sqlite-wal").write_bytes(b"synthetic wal")
        (self.data / "Cleanup").mkdir()
        (self.data / "Cleanup/journal.json").write_text('{"business":true}')
        self.preferences = self.root / "Preferences.plist"
        self.preferences.write_bytes(b"synthetic preferences")
        self.old_data, self.old_preferences = safety.DATA, safety.PREFERENCES
        safety.DATA, safety.PREFERENCES = self.data, self.preferences
        self.baseline = self.root / "baseline.json"
        safety.record_user_data(self.baseline)

    def tearDown(self):
        safety.DATA, safety.PREFERENCES = self.old_data, self.old_preferences
        super().tearDown()

    def test_unchanged_data_and_preferences_pass_without_copies(self):
        safety.verify_user_data(self.baseline)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["Data", "Preferences.plist", "baseline.json"])

    def test_changed_database_is_rejected(self):
        (self.data / "monitor.sqlite-wal").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "用户资料或偏好"):
            safety.verify_user_data(self.baseline)

    def test_missing_preferences_are_rejected(self):
        self.preferences.unlink()
        with self.assertRaisesRegex(RuntimeError, "用户资料或偏好"):
            safety.verify_user_data(self.baseline)

    def test_business_recovery_journal_is_part_of_current_data(self):
        (self.data / "Cleanup/journal.json").write_text('{"changed":true}')
        with self.assertRaisesRegex(RuntimeError, "用户资料或偏好"):
            safety.verify_user_data(self.baseline)


class MoveAndRegistryTests(TemporaryTree):
    def test_move_preserves_identity_and_never_overwrites(self):
        source_parent = self.root / "Source.noindex"
        target_parent = self.root / "Target.noindex"
        source_parent.mkdir()
        target_parent.mkdir()
        source = source_parent / "搞机灵.app"
        source.mkdir()
        (source / "payload").write_text("synthetic")
        identity = safety.app_identity(source)
        target = target_parent / "搞机灵.app"
        safety.move_program(source, target, identity)
        self.assertFalse(source.exists())
        self.assertEqual(safety.app_identity(target), identity)
        other = source_parent / "搞机灵.app"
        other.mkdir()
        with self.assertRaises(OSError):
            safety.move_program(other, target, safety.app_identity(other))
        self.assertEqual((target / "payload").read_text(), "synthetic")

    def test_registry_parser_ignores_handler_records(self):
        dump = """bundle id: 123\nidentifier: com.gaoseries.GaoJiLing\npath: /Applications/搞机灵.app (0x123)\n"""
        self.assertEqual(safety.registry_bundle_records(dump), [{"identifier": safety.IDENTIFIER, "path": "/Applications/搞机灵.app"}])
        self.assertEqual(safety.registry_bundle_records("handler id: 1\nidentifier: com.gaoseries.GaoJiLing\n"), [])


if __name__ == "__main__":
    unittest.main()
