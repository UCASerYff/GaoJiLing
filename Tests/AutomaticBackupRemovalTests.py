#!/usr/bin/env python3
"""Source-level regression checks for the no-automatic-backup contract."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AutomaticBackupRemovalTests(unittest.TestCase):
    def test_restore_does_not_create_a_recovery_backup(self):
        source = (ROOT / "Sources/MonitorStore.swift").read_text()
        restore = source.split("func restoreFullBackup()", 1)[1].split("func clearSavedData", 1)[0]
        self.assertNotIn("exportBackup", restore)
        self.assertNotIn("恢复前安全备份", restore)
        self.assertNotIn("recoveryFile", restore)
        self.assertIn("restoreBackup(backup)", restore)

    def test_manual_export_remains_available(self):
        source = (ROOT / "Sources/MonitorStore.swift").read_text()
        export = source.split("func exportFullBackup()", 1)[1].split("func restoreFullBackup", 1)[0]
        self.assertIn("exportBackup", export)
        self.assertIn("NSSavePanel", export)

    def test_installer_has_no_automatic_backup_or_rollback_archive(self):
        installer = (ROOT / "Scripts/install.sh").read_text()
        for forbidden in ("backup-data.py", "GaoJiLing-Backups", "ProgramRollback", " archive ", "restore-original"):
            self.assertNotIn(forbidden, installer)
        self.assertFalse((ROOT / "Scripts/backup-data.py").exists())

    def test_installer_unregisters_the_old_path_only_after_moving_it(self):
        installer = (ROOT / "Scripts/install.sh").read_text()
        replacement = installer.split('OLD_IDENTITY="$(python3', 1)[1].split(
            'python3 "$SAFETY" move-app --app "$NEW_APP"', 1
        )[0]
        self.assertNotIn('unregister_exact "$DESTINATION"', replacement)
        self.assertIn(
            'python3 "$SAFETY" move-app --app "$DESTINATION" --output "$OLD_APP"',
            replacement,
        )
        self.assertIn('unregister-exact --app "$OLD_APP"', installer)

    def test_settings_do_not_promise_an_automatic_backup(self):
        settings = (ROOT / "Sources/SettingsView.swift").read_text()
        self.assertNotIn("并先自动备份当前数据", settings)
        self.assertIn("不会自动备份当前数据", settings)
        self.assertIn("导出完整备份", settings)


if __name__ == "__main__":
    unittest.main()
