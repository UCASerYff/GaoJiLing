#!/usr/bin/env python3
"""Verify macOS version and bundle build metadata with private fixtures."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class VersionTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="gaojiling-version-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        folder = self.root / "Scripts"
        folder.mkdir()
        for name in ("macos_version.py", "bump-version.py"):
            shutil.copyfile(ROOT / "Scripts" / name, folder / name)
        self.version = self.root / "VERSION"
        self.build = self.root / "BUILD"
        self.info = self.root / "Info.plist"

    def fixture(self, version="1.16", build="117"):
        self.version.write_bytes((version + "\n").encode("ascii"))
        self.build.write_bytes((build + "\n").encode("ascii"))

    def command(self, script, *arguments):
        return subprocess.run([sys.executable, "-B", "-X", "utf8", str(self.root / "Scripts" / script), *arguments],
                              capture_output=True, text=True, encoding="utf-8", timeout=20)

    def test_bundle_accepts_same_marketing_version_and_independent_build(self):
        self.fixture()
        for build in ("117", "116", "118", None):
            fields = {"CFBundleShortVersionString": "1.16"}
            if build is not None:
                fields["CFBundleVersion"] = build
            self.info.write_bytes(plistlib.dumps(fields))
            result = self.command("macos_version.py", "--info-plist", str(self.info))
            self.assertEqual(result.returncode == 0, build == "117", result.stderr)
            if build == "117":
                self.assertEqual(result.stdout.strip(), "1.16 117")

    def test_build_only_preserves_marketing_version(self):
        self.fixture(build="116")
        result = self.command("bump-version.py", "--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version.read_bytes(), b"1.16\n")
        self.assertEqual(self.build.read_bytes(), b"117\n")

    def test_normal_increment_carries_marketing_and_advances_independent_build(self):
        for before, after in (("1.00", "1.01"), ("1.09", "1.10"), ("1.99", "2.00")):
            with self.subTest(version=before):
                self.fixture(version=before, build="143")
                result = self.command("bump-version.py")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.version.read_text(encoding="ascii").strip(), after)
                self.assertEqual(self.build.read_bytes(), b"144\n")

    def test_invalid_version_or_build_does_not_change_source_files(self):
        for version, build in (("1.9", "117"), ("1.16", "0"), ("1.16", "117.1"), ("1.16", "0117")):
            with self.subTest(version=version, build=build):
                self.fixture(version, build)
                before = self.version.read_bytes(), self.build.read_bytes()
                self.assertNotEqual(self.command("bump-version.py", "--build-only").returncode, 0)
                self.assertEqual((self.version.read_bytes(), self.build.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
