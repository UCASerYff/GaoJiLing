#!/usr/bin/env python3
"""Targeted release-safety tests. No app is launched or registered.

Archive tests use only synthetic bundles inside a private .noindex fixture.
Installer tests execute a fixture copy after replacing every system/app path;
all process, launch, mount, signing and registry commands are mandatory stubs.
"""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_safety_tested", HERE / "release-safety.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


def make_app(root, version="1.12"):
    app = root / "搞机灵.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": safety.IDENTIFIER, "CFBundleShortVersionString": version,
        "CFBundleVersion": version.replace(".", ""), "CFBundleExecutable": "GaoJiLing"}))
    (app / "Contents/MacOS/GaoJiLing").write_bytes(b"SYNTHETIC, NEVER EXECUTED " + version.encode())
    (app / "Contents/MacOS/GaoJiLing").chmod(0o755)
    return app


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gaojiling-release-test-", suffix=".noindex", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.app = make_app(self.root)
        # Synthetic byte-only bundles are never signed/launched. Signing is
        # mandatory in production; this narrowly replaces only that oracle.
        self.signing = mock.patch.object(safety, "signature_valid")
        self.signing.start()
        self.addCleanup(self.signing.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self):
        return safety.archive_program(self.app, self.root / "ProgramRollback")

    def test_roundtrip_modes_links_xattrs_and_independent_recovery_tools(self):
        resources = self.app / "Contents/Resources"
        resources.mkdir(mode=0o750)
        (resources / "actual").write_bytes(b"synthetic attachment\x00")
        (resources / "link").symlink_to("actual")
        subprocess.run(["/usr/bin/xattr", "-w", "com.gaoseries.release-test", "synthetic", str(resources / "actual")], check=True)
        receipt = self.archive()
        baseline, _ = safety.load_receipt(receipt)
        self.assertEqual(baseline["destination"], "/Applications/搞机灵.app")
        safety.verify_program(receipt, self.app)
        self.assertFalse(list(receipt.parent.rglob("*.app")))
        recovery = self.root / "new-recovery.noindex"
        recovery.mkdir()
        output = recovery / self.app.name
        # Use the preserved recovery tool, independent of the project path.
        result = subprocess.run([sys.executable, str(receipt.parent / "release-safety.py"), "extract",
                                 "--receipt", str(receipt), "--output", str(output)],
                                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(safety.backup.tree_manifest(output, allow_links=True), baseline["tree"])
        self.assertTrue((output / "Contents/Resources/link").is_symlink())
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)

    def test_archive_corruption_blocks_extract_without_output(self):
        receipt = self.archive()
        archive = receipt.parent / "previous-program.zip"
        archive.write_bytes(archive.read_bytes() + b"corrupted")
        with self.assertRaisesRegex(RuntimeError, "摘要"):
            safety.extract(receipt, self.root / "recovered.app")
        self.assertFalse((self.root / "recovered.app").exists())

    def test_old_program_change_blocks_verified_removal(self):
        receipt = self.archive()
        (self.app / "Contents/MacOS/GaoJiLing").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "收据"):
            safety.verify_program(receipt, self.app)

    def test_recovery_tool_change_blocks_verification(self):
        receipt = self.archive()
        (receipt.parent / "backup-data.py").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "恢复工具"):
            safety.verify_program(receipt, self.app)

    def test_extract_never_overwrites(self):
        receipt = self.archive()
        with self.assertRaisesRegex(RuntimeError, "已存在"):
            safety.extract(receipt, self.app)

    def test_real_noindex_ancestor_required(self):
        with tempfile.TemporaryDirectory(prefix="gaojiling-indexed-test-", dir="/private/tmp") as root:
            indexed = Path(root)
            disguise = indexed / "disguise.noindex"
            disguise.symlink_to(indexed)
            with self.assertRaisesRegex(RuntimeError, "noindex"):
                safety.require_noindex(disguise / "搞机灵.app")
        safety.require_noindex(self.app)

    def test_hardlink_cannot_be_archived_as_an_independent_file(self):
        os.link(self.app / "Contents/MacOS/GaoJiLing", self.root / "hardlink")
        with self.assertRaisesRegex(RuntimeError, "硬链接"):
            self.archive()
        self.assertFalse((self.root / "ProgramRollback").exists())

    def retained_archive(self, change=None):
        destination = mock.patch.object(safety, "DESTINATION", self.app)
        destination.start()
        self.addCleanup(destination.stop)
        actual = safety.backup.tree_manifest
        def simulated_root_macl(path, *args, **kwargs):
            result = actual(path, *args, **kwargs)
            # Never create/write com.apple.macl. Inject only the manifest
            # oracle for this known OS archive gap, using real fixture files.
            if Path(path).name == self.app.name:
                if any(part.startswith("program-check-") for part in Path(path).parts):
                    if change: change(result)
                else:
                    result[""]["xattrs"]["com.apple.macl"] = "synthetic-system-attribute-digest"
            return result
        patch = mock.patch.object(safety.backup, "tree_manifest", side_effect=simulated_root_macl)
        patch.start()
        self.addCleanup(patch.stop)
        return self.archive()

    def test_sole_root_macl_predicate_rejects_every_other_difference(self):
        expected = {"": {"type": "directory", "mode": 0o755,
                         "xattrs": {"com.apple.macl": "m", "provenance": "p"}},
                    "file": {"type": "file", "mode": 0o644, "sha256": "f", "xattrs": {}},
                    "link": {"type": "link", "target": "file"}}
        restored = json.loads(json.dumps(expected))
        del restored[""]["xattrs"]["com.apple.macl"]
        self.assertTrue(safety.only_root_macl_missing(expected, restored))
        variants = []
        for change in (lambda v: v[""]["xattrs"].update(provenance="changed"),
                       lambda v: v[""]["xattrs"].update(extra="x"),
                       lambda v: v[""]["xattrs"].clear(),
                       lambda v: v[""]["xattrs"].update({"com.apple.macl": "changed"}),
                       lambda v: v["file"].update(mode=0o600),
                       lambda v: v["link"].update(target="elsewhere"),
                       lambda v: v.update(extra={"type": "directory"}),
                       lambda v: v.pop("file"),
                       lambda v: v[""].update(mode=0o700),
                       lambda v: v[""].update(type="file")):
            variant = json.loads(json.dumps(restored)); change(variant); variants.append(variant)
        for variant in variants:
            self.assertFalse(safety.only_root_macl_missing(expected, variant), variant)
        self.assertFalse(safety.only_root_macl_missing({}, {}))
        self.assertFalse(safety.only_root_macl_missing(expected, expected))

    def test_original_prepared_is_not_verified_until_same_inode_is_retained(self):
        attribute_file = Path("Contents/MacOS/GaoJiLing")
        subprocess.run(["/usr/bin/xattr", "-w", "com.gaoseries.release-test", "synthetic user attribute", str(self.app / attribute_file)], check=True)
        before = self.app.stat()
        receipt = self.retained_archive()
        value, _ = safety.load_receipt(receipt)
        self.assertEqual(value["format"], 2)
        self.assertEqual(value["archiveRole"], "supplemental-only")
        self.assertTrue(self.app.exists())
        self.assertTrue((receipt.parent / "PREPARED.json").is_file())
        self.assertFalse((receipt.parent / "VERIFIED").exists())
        retained = safety.original_path(receipt)
        self.assertFalse(retained.exists())
        safety.preserve_original(receipt, self.app)
        self.assertFalse(self.app.exists())
        self.assertEqual(retained.stat().st_ino, before.st_ino)
        self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.gaoseries.release-test", str(retained / attribute_file)]).rstrip(b"\n"), b"synthetic user attribute")
        self.assertTrue((receipt.parent / "VERIFIED").is_file())
        safety.verify_program(receipt, retained)
        safety.restore_original(receipt)
        self.assertEqual(self.app.stat().st_ino, before.st_ino)
        safety.verify_program(receipt, self.app)

    def test_unknown_archive_difference_or_signature_failure_never_prepares_format2(self):
        with self.assertRaisesRegex(RuntimeError, "不是唯一根"):
            self.retained_archive(lambda value: value["Contents/MacOS/GaoJiLing"].update(mode=0o600))
        self.assertTrue(self.app.exists())
        self.assertFalse((self.root / "ProgramRollback/receipt.json").exists())
        self.assertFalse((self.root / "ProgramRollback/VERIFIED").exists())

    def test_signing_error_is_not_converted_to_archive_gap(self):
        with mock.patch.object(safety, "signature_valid", side_effect=subprocess.CalledProcessError(1, "synthetic codesign")):
            with self.assertRaises(subprocess.CalledProcessError): self.archive()
        self.assertTrue(self.app.exists())
        self.assertFalse((self.root / "ProgramRollback").exists())

    def test_format2_missing_or_changed_original_never_falls_back_to_zip(self):
        receipt = self.retained_archive()
        with self.assertRaisesRegex(RuntimeError, "禁止解包"):
            safety.extract(receipt, self.root / "recovered.app")
        safety.preserve_original(receipt, self.app)
        retained = safety.original_path(receipt)
        hidden = retained.with_name("held.app")
        retained.rename(hidden)
        with self.assertRaises(FileNotFoundError): safety.restore_original(receipt)
        self.assertFalse(self.app.exists())
        hidden.rename(retained)
        (retained / "Contents/MacOS/GaoJiLing").write_bytes(b"unexpected content")
        with self.assertRaisesRegex(RuntimeError, "收据"): safety.restore_original(receipt)
        self.assertFalse(self.app.exists())

    def test_valid_original_can_restore_when_supplemental_zip_is_corrupt(self):
        receipt = self.retained_archive()
        safety.preserve_original(receipt, self.app)
        (receipt.parent / "previous-program.zip").write_bytes(b"supplemental zip unavailable")
        safety.restore_original(receipt)
        safety.verify_program(receipt, self.app)

    def test_original_move_refuses_collisions_and_wrong_identity(self):
        receipt = self.retained_archive()
        retained = safety.original_path(receipt)
        retained.mkdir()
        sentinel = retained / "unknown"; sentinel.write_text("do not overwrite")
        with self.assertRaises(OSError): safety.preserve_original(receipt, self.app)
        self.assertTrue(self.app.exists()); self.assertEqual(sentinel.read_text(), "do not overwrite")
        self.assertFalse((receipt.parent / "VERIFIED").exists())
        with self.assertRaisesRegex(RuntimeError, "身份"):
            safety.move_program(self.app, self.root / "elsewhere.app", "1:2:3")
        self.assertTrue(self.app.exists())

    def test_original_restore_refuses_unknown_official_and_restores_after_postmove_error(self):
        receipt = self.retained_archive()
        before = self.app.stat().st_ino
        actual_move = safety.move_program
        def moved_then_error(*args, **kwargs):
            actual_move(*args, **kwargs)
            raise OSError("synthetic fsync error after rename")
        with mock.patch.object(safety, "move_program", side_effect=moved_then_error):
            with self.assertRaises(OSError): safety.preserve_original(receipt, self.app)
        self.assertFalse((receipt.parent / "VERIFIED").exists())
        unknown = make_app(self.root, version="9.99")
        with self.assertRaisesRegex(RuntimeError, "同时存在"): safety.restore_original(receipt)
        self.assertTrue(unknown.exists()); self.assertTrue(safety.original_path(receipt).exists())
        shutil.rmtree(unknown)
        safety.restore_original(receipt)
        self.assertEqual(self.app.stat().st_ino, before)

    def test_original_rename_rejects_cross_volume_without_moving(self):
        target = self.root / "retained.app"
        actual = safety.os.fstat
        counts = iter([False, True])
        def other_device(fd):
            value = actual(fd)
            if next(counts):
                class DifferentVolume:
                    st_dev = value.st_dev + 1
                return DifferentVolume()
            return value
        # Only directory device reads in move_program are replaced. directory_fd
        # itself also uses fstat, so pin its already-real fixture FDs explicitly.
        import contextlib
        @contextlib.contextmanager
        def real_parent(path, read=False):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
            try: yield fd
            finally: os.close(fd)
        identity = safety.app_identity(self.app)
        with mock.patch.object(safety.backup, "directory_fd", side_effect=real_parent), mock.patch.object(safety.os, "fstat", side_effect=other_device):
            with self.assertRaisesRegex(RuntimeError, "同卷"): safety.move_program(self.app, target, identity)
        self.assertTrue(self.app.exists()); self.assertFalse(target.exists())

    def test_format2_rejects_forged_source_and_container_identity(self):
        receipt = self.retained_archive()
        raw = receipt.read_bytes()
        value = json.loads(raw)
        for source in ("relative.app", str(self.root / "foreign.app")):
            with self.subTest(source=source):
                changed = json.loads(raw); changed["sourcePath"] = source
                receipt.write_text(json.dumps(changed))
                with self.assertRaisesRegex(RuntimeError, "收据无效"): safety.load_receipt(receipt)
        for key in ("device", "inode", "uid", "gid", "mode"):
            with self.subTest(container=key):
                changed = json.loads(raw); changed["original"]["container"][key] += 1
                receipt.write_text(json.dumps(changed))
                with self.assertRaisesRegex(RuntimeError, "容器"): safety.load_receipt(receipt)
        receipt.write_bytes(raw)
        container = receipt.parent / "Program.noindex"
        container.chmod(0o750)
        with self.assertRaisesRegex(RuntimeError, "0700"): safety.preserve_original(receipt, self.app)
        container.chmod(0o700)
        held = container.with_name("Held.noindex")
        container.rename(held); container.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, "容器"): safety.load_receipt(receipt)
        container.rmdir(); held.rename(container)
        container.rename(held); container.symlink_to(held)
        with self.assertRaises((OSError, RuntimeError)): safety.load_receipt(receipt)
        container.unlink(); held.rename(container)
        self.assertEqual(safety.load_receipt(receipt)[0], value)
        self.assertTrue(self.app.exists())
        self.assertFalse((receipt.parent / "VERIFIED").exists())

    def test_move_rechecks_open_container_fd_before_rename(self):
        receipt = self.retained_archive()
        value, _ = safety.load_receipt(receipt)
        target = safety.original_path(receipt)
        pin = value["original"]["container"]
        for key in ("device", "inode", "uid", "gid", "mode"):
            with self.subTest(container=key):
                changed = dict(pin); changed[key] += 1
                with self.assertRaisesRegex(RuntimeError, "FD 身份改变"):
                    safety.move_program(self.app, target, safety.app_identity(self.app), target_parent=changed)
                self.assertTrue(self.app.exists()); self.assertFalse(target.exists())
        safety.preserve_original(receipt, self.app)
        changed = dict(pin); changed["inode"] += 1
        with self.assertRaisesRegex(RuntimeError, "FD 身份改变"):
            safety.move_program(target, self.app, value["original"]["identity"], source_parent=changed)
        self.assertTrue(target.exists()); self.assertFalse(self.app.exists())

    def test_marker_failure_after_retention_still_restores_original_and_location(self):
        receipt = self.retained_archive()
        before = safety.app_identity(self.app)
        actual = safety.write_json
        def fail_verified(path, value):
            if Path(path).name == "VERIFIED": raise OSError("synthetic marker write failure")
            return actual(path, value)
        with mock.patch.object(safety, "write_json", side_effect=fail_verified):
            with self.assertRaisesRegex(OSError, "marker"): safety.preserve_original(receipt, self.app)
        self.assertFalse(self.app.exists())
        self.assertEqual(safety.app_identity(safety.original_path(receipt)), before)
        self.assertFalse((receipt.parent / "VERIFIED").exists())
        safety.restore_original(receipt)
        self.assertEqual(safety.app_identity(self.app), before)
        state = json.loads((receipt.parent / "RESTORED.json").read_bytes())
        self.assertEqual(state["authority"], str(self.app))
        self.assertEqual(state["status"], "restored-original")
        self.assertFalse(safety.original_path(receipt).exists())
        safety.restore_original(receipt)  # Matching durable authority is idempotent.

    def test_unmoved_original_restore_persists_actual_authority(self):
        receipt = self.retained_archive()
        before = safety.app_identity(self.app)
        safety.restore_original(receipt)
        state = json.loads((receipt.parent / "RESTORED.json").read_bytes())
        self.assertEqual(state["authority"], str(self.app))
        self.assertEqual(state["identity"], before)
        self.assertEqual(state["status"], "original-remained-installed")
        self.assertFalse((receipt.parent / "VERIFIED").exists())

    def test_restore_record_failure_returns_file_first_and_reports_location(self):
        receipt = self.retained_archive()
        safety.preserve_original(receipt, self.app)
        before = safety.app_identity(safety.original_path(receipt))
        actual = safety.write_json
        def fail_restored(path, value):
            if Path(path).name == "RESTORED.json": raise OSError("synthetic disk full")
            return actual(path, value)
        with mock.patch.object(safety, "write_json", side_effect=fail_restored):
            with self.assertRaisesRegex(RuntimeError, "原件已恢复.*恢复位置记录未能持久化"):
                safety.restore_original(receipt)
        self.assertEqual(safety.app_identity(self.app), before)
        self.assertFalse(safety.original_path(receipt).exists())
        self.assertFalse((receipt.parent / "RESTORED.json").exists())
        safety.restore_original(receipt)
        self.assertEqual(json.loads((receipt.parent / "RESTORED.json").read_bytes())["authority"], str(self.app))

    def test_zip_traversal_and_symlink_descendants_rejected(self):
        for entries in (("搞机灵.app/../outside",), ("搞机灵.app/link", "搞机灵.app/link/child")):
            path = self.root / "hostile.zip"
            with zipfile.ZipFile(path, "w") as archive:
                for name in entries:
                    item = zipfile.ZipInfo(name)
                    item.create_system = 3
                    item.external_attr = ((stat.S_IFLNK | 0o777) if name.endswith("/link") else (stat.S_IFREG | 0o600)) << 16
                    archive.writestr(item, b"../../outside")
            with self.assertRaises(RuntimeError):
                safety.validate_zip(path, self.app.name)

    def test_registry_parser_matches_identifier_and_exact_path(self):
        dump = "\nbundle id: Other\npath: /Applications/Other.app (0x11)\nidentifier: com.example.Other\n-----\nbundle id: 搞机灵\npath: /Applications/搞机灵.app (0x12)\nidentifier: com.gaoseries.GaoJiLing\n-----\nbundle id: 搞机灵\npath: /private/tmp/old.noindex/搞机灵.app (0x13)\nidentifier: com.gaoseries.GaoJiLing\n"
        self.assertEqual(safety.registry_paths(dump), ["/Applications/搞机灵.app", "/private/tmp/old.noindex/搞机灵.app"])

    def test_empty_and_unavailable_views_cannot_pass_for_an_installed_app(self):
        base = {"inaccessible": [], "copies": [{"path": str(safety.DESTINATION), "noindex": False}],
                "spotlight": [], "launchServices": [],
                "visibility": {"spotlight": {"status": "emptyForIdentifier"}, "launchServices": {"status": "unavailable"}}}
        self.assertTrue(safety.audit_issues(base))
        self.assertTrue(safety.audit_issues(base, final=True))
        base["spotlight"] = base["launchServices"] = [str(safety.DESTINATION)]
        base["visibility"]["launchServices"]["status"] = "observable"
        base["visibility"]["spotlight"]["status"] = "observable"
        self.assertEqual(safety.audit_issues(base, final=True), [])
        base["launchServices"].append("/deleted/GaoJiLing.app")
        self.assertTrue(safety.audit_issues(base, final=True))

    def test_unavailable_queries_still_produce_structured_evidence(self):
        unavailable = subprocess.CompletedProcess([], 1, b"", b"synthetic permission failure")
        with mock.patch.object(safety.subprocess, "run", return_value=unavailable), mock.patch.object(safety, "DESTINATION", self.app), mock.patch.object(safety, "LEGACY_PATHS", ()):
            audit = safety.collect_audit(self.root, [])
        self.assertEqual(audit["visibility"]["spotlight"]["status"], "unavailable")
        self.assertEqual(audit["visibility"]["launchServices"]["status"], "unavailable")

    def test_stop_program_ignores_other_path_and_uid_and_rechecks_start(self):
        executable = str(safety.DESTINATION / 'Contents/MacOS/GaoJiLing')
        snapshots = {10: (10, 501, 100, 1, executable),
                     20: (20, 501, 100, 2, '/Applications/Other.app/Contents/MacOS/GaoJiLing'),
                     30: (30, 502, 100, 3, executable)}
        sent = []
        def terminate(pid, value):
            sent.append((pid, value))
            snapshots.pop(pid)
        safety.stop_program(inspect=snapshots.get, candidates=lambda: list(snapshots), send=terminate, uid=501)
        self.assertEqual(sent, [(10, signal.SIGTERM)])
        self.assertIn(20, snapshots)
        self.assertIn(30, snapshots)
        changed = iter([(10, 501, 100, 1, executable), (10, 501, 200, 1, executable)])
        sent.clear()
        with self.assertRaisesRegex(RuntimeError, '身份改变'):
            safety.stop_program(inspect=lambda _: next(changed), candidates=lambda: [10],
                                send=lambda *value: sent.append(value), uid=501)
        self.assertEqual(sent, [])

    def test_stop_program_never_force_kills_or_stops_a_restarted_instance(self):
        executable = str(safety.DESTINATION / 'Contents/MacOS/GaoJiLing')
        identity = (10, 501, 100, 1, executable)
        sent, clock = [], iter([0, 5])
        with self.assertRaisesRegex(RuntimeError, '未强杀'):
            safety.stop_program(inspect=lambda _: identity, candidates=lambda: [10],
                                send=lambda *value: sent.append(value), now=lambda: next(clock),
                                wait=lambda _: None, uid=501)
        self.assertEqual(sent, [(10, signal.SIGTERM)])
        snapshots, ids = {}, iter([[10], [20]])
        def inspect(pid):
            return identity if pid == 10 and not snapshots else (20, 501, 200, 2, executable) if pid == 20 else None
        def terminate(*_): snapshots['stopped'] = True
        with self.assertRaisesRegex(RuntimeError, '重新启动'):
            safety.stop_program(inspect=inspect, candidates=lambda: next(ids), send=terminate, uid=501)


class UnregisterObservationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gaojiling-unregister-test-', suffix='.noindex', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.app = make_app(self.root)
        self.witness = {'identifier': 'com.example.SyntheticWitness', 'path': '/Applications/SyntheticWitness.app'}
        self.baseline = self.root / 'before.json'
        self.baseline.write_text(json.dumps({'format': 1, 'identifier': safety.IDENTIFIER, 'issues': [],
                                            'launchServices': [str(safety.DESTINATION)],
                                            'launchServicesWitnesses': [safety.backup.digest(self.witness)]}))
        self.record = self.root / 'unregistration.jsonl'

    def tearDown(self):
        self.temporary.cleanup()

    def dump(self, paths, witness=True):
        records = [self.witness] if witness else []
        records += [{'identifier': safety.IDENTIFIER, 'path': path} for path in paths]
        return '\n-----\n'.join('bundle id: Synthetic\npath: ' + item['path'] + '\nidentifier: ' + item['identifier'] + '\n' for item in records)

    def invoke(self, dumps, command_code=0, expected=None, wait=None):
        values, calls, last = iter(dumps), [], [None]
        def run(command, **kwargs):
            calls.append(command)
            if command[1] == '-dump':
                last[0] = next(values, last[0])
                return subprocess.CompletedProcess(command, 0, last[0], '')
            self.assertEqual(command, [safety.LSREGISTER, '-u', str(self.app)])
            return subprocess.CompletedProcess(command, command_code, '', 'synthetic -10814' if command_code else '')
        safety.unregister_registration(self.app, self.baseline, self.record, expected_identity=expected, run=run, wait=wait or (lambda _: None))
        return calls, json.loads(self.record.read_text().splitlines()[-1])

    def test_unregistered_mirror_is_observed_twice_and_never_unregistered(self):
        observed = self.dump([str(safety.DESTINATION)])
        calls, event = self.invoke([observed, observed])
        self.assertTrue(all(command[1] == '-dump' for command in calls))
        self.assertEqual(event['status'], 'alreadyAbsent')
        self.assertFalse(event['commandIssued'])

    def test_registered_path_error_with_residual_is_a_failure(self):
        observed = self.dump([str(safety.DESTINATION), str(self.app)])
        with self.assertRaisesRegex(RuntimeError, '仍有'):
            self.invoke([observed, observed], command_code=1)
        event = json.loads(self.record.read_text())
        self.assertEqual(event['commandReturncode'], 1)
        self.assertEqual(event['status'], 'failed')
        self.assertIn(str(self.app), event['afterPaths'])

    def test_zero_command_code_with_residual_is_still_a_failure(self):
        observed = self.dump([str(safety.DESTINATION), str(self.app)])
        with self.assertRaisesRegex(RuntimeError, '仍有'):
            self.invoke([observed, observed])

    def test_nonzero_command_only_passes_when_observable_recheck_proves_absence(self):
        before = self.dump([str(safety.DESTINATION), str(self.app)])
        after = self.dump([str(safety.DESTINATION)])
        calls, event = self.invoke([before, after], command_code=1)
        self.assertEqual(sum(command[1] == '-u' for command in calls), 1)
        self.assertEqual(event['status'], 'absentAfterCommandError')
        self.assertEqual(event['commandReturncode'], 1)

    def test_empty_handler_only_and_restricted_views_never_mean_already_absent(self):
        handler = 'handler id: synthetic\nidentifier: ' + safety.IDENTIFIER + '\npath: ' + str(self.app) + '\n'
        for observed in ('', handler, self.dump([str(safety.DESTINATION)], witness=False)):
            with self.subTest(observed=observed[:20]):
                self.record.unlink(missing_ok=True)
                with self.assertRaisesRegex(RuntimeError, '视图'):
                    self.invoke([observed])
                event = json.loads(self.record.read_text())
                self.assertEqual(event['status'], 'failed')
                self.assertNotIn('commandIssued', event)

    def test_empty_recheck_after_command_cannot_report_success(self):
        before = self.dump([str(safety.DESTINATION), str(self.app)])
        with self.assertRaisesRegex(RuntimeError, '视图'):
            self.invoke([before, ''])
        self.assertEqual(json.loads(self.record.read_text())['status'], 'failed')

    def test_registration_appearing_during_absence_observation_is_removed(self):
        absent = self.dump([str(safety.DESTINATION)])
        appeared = self.dump([str(safety.DESTINATION), str(self.app)])
        calls, event = self.invoke([absent, appeared, absent])
        self.assertEqual(sum(command[1] == '-u' for command in calls), 1)
        self.assertEqual(event['status'], 'unregistered')

    def test_pinned_damaged_new_program_does_not_require_its_info_to_be_readable(self):
        identity = safety.app_identity(self.app)
        (self.app / 'Contents/Info.plist').write_bytes(b'damaged Info')
        before = self.dump([str(safety.DESTINATION), str(self.app)])
        after = self.dump([str(safety.DESTINATION)])
        _, event = self.invoke([before, after], expected=identity)
        self.assertEqual(event['status'], 'unregistered')

    def test_delayed_reappearance_after_successful_unregistration_is_failure(self):
        present = self.dump([str(safety.DESTINATION), str(self.app)])
        absent = self.dump([str(safety.DESTINATION)])
        with self.assertRaisesRegex(RuntimeError, '重新出现'):
            self.invoke([present, absent, absent, present])
        event = json.loads(self.record.read_text())
        self.assertEqual(event['commandReturncode'], 0)
        self.assertEqual(event['status'], 'failed')
        self.assertEqual(event['snapshots'][-1]['stage'], 'after-command+5s')
        self.assertTrue(self.app.is_dir())

    def test_launch_disabled_raw_record_is_preserved_not_filtered(self):
        dump = self.dump([str(safety.DESTINATION), str(self.app)])
        dump += 'bundle flags: has-display-name launch-disabled (0000000000000082)\nreg date: synthetic\ninode: 12345\n'
        self.assertIn(str(self.app), safety.registry_paths(dump))
        details = safety.registry_record_details(dump)
        self.assertTrue(any('launch-disabled' in item.get('bundle flags','') and item['path']==str(self.app) for item in details))

    def test_wait_replacement_of_pinned_source_refuses_u_and_preserves_both_objects(self):
        identity=safety.app_identity(self.app)
        held=self.root/'held-original.app'
        changed=[]
        def replace_during_wait(_):
            if changed:return
            self.app.rename(held);make_app(self.root,'9.99');changed.append(True)
        absent=self.dump([str(safety.DESTINATION)])
        calls=[]
        def run(command,**kwargs):
            calls.append(command)
            self.assertEqual(command,[safety.LSREGISTER,'-dump'])
            return subprocess.CompletedProcess(command,0,absent,'')
        with self.assertRaisesRegex(RuntimeError,'身份'):
            safety.unregister_registration(self.app,self.baseline,self.record,expected_identity=identity,
                                           run=run,wait=replace_during_wait)
        self.assertTrue(changed)
        self.assertTrue(all(c==[safety.LSREGISTER,'-dump'] for c in calls))
        self.assertTrue(self.app.exists());self.assertTrue(held.exists())
        self.assertEqual(safety.app_identity(held),identity)
        event=json.loads(self.record.read_text().splitlines()[-1])
        self.assertEqual(event['status'],'failed')
        self.assertNotIn('commandIssued',event)


class StagedSourceProofTests(unittest.TestCase):
    """Exercise real staged-proof guards with synthetic bundles and fake LS."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gaojiling-staged-proof-', suffix='.noindex', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.apps = self.root / 'Applications'; self.apps.mkdir()
        self.destination = self.apps / '搞机灵.app'
        self.work = self.apps / '.GaoJiLing-install-fixture.noindex'; self.work.mkdir(mode=0o700)
        stage_parent = self.work / 'New.noindex'; stage_parent.mkdir(mode=0o700)
        self.stage = make_app(stage_parent, '1.13')
        self.install_record = self.root / 'Install-V1.13-fixture.noindex'; self.install_record.mkdir(mode=0o700)
        self.receipt = self.install_record / 'staged-new.json'
        self.baseline = self.install_record / 'before.json'
        self.record = self.install_record / 'unregistration.jsonl'
        self.identity = safety.app_identity(self.stage)
        self.destination_patch = mock.patch.object(safety, 'DESTINATION', self.destination)
        self.destination_patch.start(); self.addCleanup(self.destination_patch.stop)
        self.signing = mock.patch.object(safety, 'signature_valid')
        self.signing.start(); self.addCleanup(self.signing.stop)
        self.checksum = safety.record_staged(self.stage, self.work, self.install_record, self.identity)
        witness = {'identifier': 'com.example.SyntheticWitness', 'path': '/Applications/SyntheticWitness.app'}
        self.witness = witness
        self.baseline.write_text(json.dumps({'format':1,'identifier':safety.IDENTIFIER,'issues':[],
                                            'launchServices':[str(self.destination)],
                                            'launchServicesWitnesses':[safety.backup.digest(witness)]}))
        self.calls = []
        self.registered = [str(self.destination),str(self.stage)]

    def tearDown(self):
        self.temporary.cleanup()

    def fake_ls(self, command, **kwargs):
        self.calls.append(command)
        if command == [safety.LSREGISTER,'-dump']:
            rows = [self.witness]+[{'identifier':safety.IDENTIFIER,'path':p} for p in self.registered]
            dump = '\n-----\n'.join('bundle id: Synthetic\npath: '+r['path']+'\nidentifier: '+r['identifier']+'\n' for r in rows)
            return subprocess.CompletedProcess(command,0,dump,'')
        self.assertEqual(command,[safety.LSREGISTER,'-u',str(self.stage)])
        self.registered.remove(str(self.stage))
        return subprocess.CompletedProcess(command,0,'','')

    def invoke(self, current=None):
        return safety.unregister_staged_source(self.receipt,self.checksum,current or self.destination,
                                               self.identity,self.baseline,self.record,run=self.fake_ls,wait=lambda _:None)

    def move_new(self, failed=False):
        current = self.destination
        if failed:
            parent=self.work/'Failed.noindex';parent.mkdir(mode=0o700);current=parent/'搞机灵.app'
        safety.move_program(self.stage,current,self.identity)
        return current

    def test_real_proof_removes_only_historical_source_after_move_to_formal(self):
        self.move_new(); self.invoke()
        self.assertEqual(self.registered,[str(self.destination)])
        self.assertEqual(safety.app_identity(self.destination),self.identity)
        self.assertFalse(any(c==[safety.LSREGISTER,'-u',str(self.destination)] for c in self.calls))
        event=json.loads(self.record.read_text().splitlines()[-1])
        self.assertEqual(event['sourceProof']['currentLocation'],str(self.destination))

    def test_real_proof_accepts_exact_new_inode_at_failed_path(self):
        current=self.move_new(failed=True);self.invoke(current)
        self.assertEqual(safety.app_identity(current),self.identity)
        self.assertEqual(self.registered,[str(self.destination)])

    def test_tampered_or_forged_receipt_never_issues_ls_command(self):
        self.move_new();raw=self.receipt.read_bytes()
        self.receipt.write_bytes(raw+b' ')
        with self.assertRaisesRegex(RuntimeError,'摘要'):self.invoke()
        self.assertEqual(self.calls,[])
        for field,value in (('sourcePath',str(self.root/'foreign.app')),('identity','1:2:3'),('destination',str(self.root/'elsewhere.app'))):
            with self.subTest(field=field):
                forged=json.loads(raw);forged[field]=value
                payload=json.dumps(forged).encode();self.receipt.write_bytes(payload)
                self.checksum=hashlib.sha256(payload).hexdigest()
                with self.assertRaisesRegex(RuntimeError,'不符'):self.invoke()
                self.assertEqual(self.calls,[])
                self.assertTrue(self.work.exists());self.assertTrue(self.destination.exists())

    def test_unknown_source_occupant_is_not_unregistered_or_removed(self):
        self.move_new();unknown=make_app(self.stage.parent,'9.99')
        with self.assertRaisesRegex(RuntimeError,'历史暂存源仍有对象'):self.invoke()
        self.assertEqual(self.calls,[])
        self.assertTrue(unknown.exists());self.assertEqual(safety.app_identity(self.destination),self.identity)

    def test_wrong_current_inode_is_not_unregistered_or_removed(self):
        self.move_new();held_parent=self.work/'Held.noindex';held_parent.mkdir(mode=0o700)
        held=held_parent/'搞机灵.app';safety.move_program(self.destination,held,self.identity)
        unknown=make_app(self.apps,'9.99')
        with self.assertRaisesRegex(RuntimeError,'原暂存对象'):self.invoke()
        self.assertEqual(self.calls,[])
        self.assertTrue(unknown.exists());self.assertEqual(safety.app_identity(held),self.identity)


# The stub has a hard fixture boundary before every simulated operation. Its
# interpreter is fixed; it never falls through to a real same-named command.
STUB = r'''import hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, sys, tempfile, zipfile
root = pathlib.Path(os.environ['GAO_RELEASE_FIXTURE']).resolve()
assert root.name.endswith('.noindex') and str(root).startswith('/private/tmp/gaojiling-script-test-')
scenario = os.environ['GAO_RELEASE_SCENARIO']
retained_mode = scenario.startswith('retained-')
if retained_mode: scenario = scenario[len('retained-'):]
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
def bounded(value):
    path = pathlib.Path(value).absolute()
    assert path == root or root in path.parents, ('outside fixture', name, value)
    return path
def value(flag): return args[args.index(flag) + 1]
def tree(path):
    return {str(p.relative_to(path)): p.read_bytes().hex() for p in path.rglob('*') if p.is_file()}
def inode_key(path):
    details = path.lstat()
    return ':'.join(map(str, (details.st_dev, details.st_ino)))
def identity(path):
    details = path.lstat()
    return ':'.join(map(str, (details.st_dev, details.st_ino, details.st_uid)))
def quit(code=0): sys.exit(code)
def move_fixture(source, target):
    source, target = bounded(source), bounded(target)
    moving_old = source == root / 'Applications/搞机灵.app' and ('Old.noindex' in str(target) or 'Program.noindex' in str(target))
    moving_new = 'New.noindex' in str(source) and target == root / 'Applications/搞机灵.app'
    if scenario == 'move-old-before-fail' and moving_old: quit(1)
    assert not target.exists() and not target.is_symlink(), ('would overwrite fixture object', target)
    moved_identity = inode_key(source)
    source.rename(target)
    # The synthetic registry deliberately follows watched inodes, including
    # an original moved into the long-term Program.noindex container.
    state, watched = root / 'registry-state.json', root / 'registry-watched-inodes.json'
    registered, values = json.loads(state.read_text()), set(json.loads(watched.read_text()))
    # A staged path can remain in LS even after its inode has moved to the
    # formal/failed path. This must be closed through its durable receipt.
    keep_stage_ghost = 'New.noindex' in str(source) and scenario in ('moved-new-ghost', 'failed-new-ghost')
    if str(source) in registered and not keep_stage_ghost: registered.remove(str(source))
    if moved_identity in values or moving_new:
        values.add(moved_identity)
        if str(target) not in registered: registered.append(str(target))
    state.write_text(json.dumps(registered)); watched.write_text(json.dumps(sorted(values)))
    if scenario == 'failed-bad-info' and 'Failed.noindex' in str(target):
        (target / 'Contents/Info.plist').write_bytes(b'damaged synthetic new Info; pinned identity still valid')
    if scenario == 'move-old-term' and moving_old: os.kill(os.getppid(), signal.SIGTERM)
    if scenario == 'verify-fail-repeat-term' and 'Failed.noindex' in str(target): os.kill(os.getppid(), signal.SIGTERM)
    if (scenario == 'move-old-after-fail' and moving_old) or (scenario == 'move-new-after-fail' and moving_new): quit(1)
with (root / 'calls.jsonl').open('a') as log: log.write(json.dumps([name, args]) + '\n')
if name == 'python3':
    script = bounded(args.pop(0))
    if script.name == 'backup-data.py':
        if '--verify' in args: quit(1 if scenario in ('verify-fail', 'verify-fail-old-unregister-fail', 'verify-fail-repeat-term', 'failed-unregister-fail', 'failed-unregister-empty', 'failed-bad-info', 'failed-new-ghost') else 0)
        if scenario == 'backup-fail': quit(1)
        target = root / 'DataBackup'
        target.mkdir()
        (target / 'VERIFIED').write_text('synthetic data backup')
        print(target)
        quit()
    assert script.name == 'release-safety.py'
    action = args.pop(0)
    if action == 'stop-program': quit()
    if action in ('unregister-exact', 'unregister-staged-source'):
        baseline, record = bounded(value('--baseline')), bounded(value('--record'))
        assert baseline.is_file()
        if action == 'unregister-staged-source':
            receipt = bounded(value('--receipt')); raw = receipt.read_bytes(); item = json.loads(raw)
            assert hashlib.sha256(raw).hexdigest() == value('--receipt-sha256')
            app = bounded(item['sourcePath']); current = bounded(value('--moved-to'))
            assert not app.exists() and not app.is_symlink()
            assert current in (root / 'Applications/搞机灵.app', bounded(item['work']) / 'Failed.noindex/搞机灵.app')
            assert item['identity'] == value('--expected-identity') == identity(current)
            assert baseline.parent == record.parent == bounded(item['installRecord'])
        else:
            app = bounded(value('--app'))
            if '--expected-identity' in args: assert value('--expected-identity') == identity(app)
            else: assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'com.gaoseries.GaoJiLing'
        if 'New.noindex' in str(app) and scenario == 'stage-u-empty':
            event = {'path': str(app), 'status': 'failed', 'error': 'synthetic restricted stage view'}
            with record.open('a') as log: log.write(json.dumps(event) + '\n')
            quit(1)
        registered = json.loads((root / 'registry-state.json').read_text())
        event = {'path': str(app), 'beforePaths': registered, 'status': 'failed'}
        if scenario == 'empty-unregister-view' or (scenario == 'old-unregister-empty' and 'Old.noindex' in str(app)) or (scenario == 'failed-unregister-empty' and 'Failed.noindex' in str(app)):
            event['error'] = 'synthetic restricted empty view'
            with record.open('a') as log: log.write(json.dumps(event) + '\n')
            quit(1)
        if str(app) not in registered:
            event.update(status='alreadyAbsent', commandIssued=False)
            code = 0
        else:
            result = subprocess.run([str(root / 'Stubs/lsregister'), '-u', str(app)])
            after = json.loads((root / 'registry-state.json').read_text())
            event.update(commandIssued=True, commandReturncode=result.returncode, afterPaths=after)
            code = 1 if str(app) in after else 0
            if not code: event['status'] = 'unregistered' if result.returncode == 0 else 'absentAfterCommandError'
        with record.open('a') as log: log.write(json.dumps(event) + '\n')
        if scenario == 'unregister-term' and app == root / 'Applications/搞机灵.app': os.kill(os.getppid(), signal.SIGTERM)
        quit(code)
    if action == 'record-staged':
        app, work, install_record = bounded(value('--app')), bounded(value('--work')), bounded(value('--install-record'))
        assert app == work / 'New.noindex/搞机灵.app' and identity(app) == value('--expected-identity')
        receipt = install_record / 'staged-new.json'; assert not receipt.exists()
        item = {'sourcePath': str(app), 'work': str(work), 'installRecord': str(install_record), 'identity': identity(app)}
        raw = (json.dumps(item) + '\n').encode(); receipt.write_bytes(raw)
        if scenario == 'stage-prepare-term': os.kill(os.getppid(), signal.SIGTERM)
        print(hashlib.sha256(raw).hexdigest()); quit()
    if action in ('workdir', 'recorddir'):
        parent = bounded(value('--parent')); parent.mkdir(parents=True, exist_ok=True)
        print(tempfile.mkdtemp(prefix=value('--prefix'), suffix='.noindex', dir=parent)); quit()
    if action == 'check-noindex':
        path = bounded(args[0])
        quit(0 if any(p.name.endswith('.noindex') for p in path.parent.resolve().parents) or path.parent.resolve().name.endswith('.noindex') else 1)
    if action == 'identity':
        path = bounded(value('--app')); info = path.lstat()
        observed = identity(path)
        if '--expected' in args: assert value('--expected') == observed
        else: print(observed)
        quit()
    if action == 'audit':
        target = bounded(value('--output'))
        final = '--final' in args
        fail = (scenario == 'preflight-empty' and target.name == 'before.json') or (scenario == 'final-empty' and final)
        registered = json.loads((root / 'registry-state.json').read_text())
        official = str(root / 'Applications/搞机灵.app')
        fail = fail or (final and registered != [official]) or any(path != official for path in registered)
        target.write_text(json.dumps({'synthetic': True, 'issues': ['empty-view'] if fail else []}))
        quit(3 if fail else 0)
    if action == 'archive':
        source = bounded(value('--app')); target = bounded(value('--directory'))
        if scenario == 'archive-fail' or scenario.startswith('stage-u-'): quit(1)
        target.mkdir()
        contents = tree(source)
        with zipfile.ZipFile(target / 'previous-program.zip', 'w') as z:
            for path, data in contents.items(): z.writestr(path, bytes.fromhex(data))
        receipt = target / 'receipt.json'
        item = {'tree': contents, 'format': 2 if retained_mode else 1, 'sourcePath': str(source), 'identity': identity(source)}
        if retained_mode:
            (target / 'Program.noindex').mkdir(mode=0o700)
            (target / 'PREPARED.json').write_text('synthetic pending original')
        else: (target / 'VERIFIED').write_text('synthetic roundtrip')
        receipt.write_text(json.dumps(item))
        print(receipt); quit()
    if action in ('receipt-format', 'original-path', 'preserve-original', 'restore-original', 'record-plan'):
        receipt = bounded(value('--receipt')); item = json.loads(receipt.read_text())
        original = receipt.parent / 'Program.noindex/搞机灵.app'
        official = bounded(item['sourcePath'])
        if action == 'receipt-format': print(item['format'])
        elif action == 'original-path': assert item['format'] == 2; print(original)
        elif action == 'record-plan':
            target = bounded(value('--record')); assert not target.exists()
            old = bounded(value('--original-path'))
            if item['format'] == 2: assert old == original
            target.write_text(json.dumps({'receipt': str(receipt), 'originalPath': str(old), 'format': item['format']}))
        elif action == 'preserve-original':
            assert bounded(value('--app')) == official and identity(official) == item['identity'] and tree(official) == item['tree']
            move_fixture(official, original)
            if scenario == 'marker-fail': quit(1)
            (receipt.parent / 'VERIFIED').write_text(json.dumps({'authority': str(original), 'identity': item['identity']}))
        else:
            assert item['format'] == 2
            if official.exists(): assert not original.exists() and identity(official) == item['identity'] and tree(official) == item['tree']
            else:
                assert identity(original) == item['identity'] and tree(original) == item['tree']
                move_fixture(original, official)
            (receipt.parent / 'RESTORED.json').write_text(json.dumps({'authority': str(official), 'identity': identity(official)}))
        quit()
    if action == 'move-app':
        source, target = bounded(value('--app')), bounded(value('--output'))
        assert identity(source) == value('--expected-identity')
        move_fixture(source, target); quit()
    if action in ('verify', 'extract'):
        receipt = bounded(value('--receipt')); contents = json.loads(receipt.read_text())['tree']
        if action == 'verify':
            target = bounded(value('--app')); assert tree(target) == contents
            item = json.loads(receipt.read_text())
            if item['format'] == 2: assert identity(target) == item['identity']
        else:
            target = bounded(value('--output')); assert not target.exists()
            for path, data in contents.items():
                item = target / path; item.parent.mkdir(parents=True, exist_ok=True); item.write_bytes(bytes.fromhex(data))
        quit()
    raise AssertionError(('unexpected safety action', action))
elif name == 'PlistBuddy':
    key = args[1].split(':', 1)[1]
    print(plistlib.loads(bounded(args[2]).read_bytes())[key]); quit()
elif name == 'lsregister':
    assert args[0] in ('-u', '-f'); bounded(args[1])
    state = root / 'registry-state.json'; registered = json.loads(state.read_text())
    if args[0] == '-f':
        if scenario == 'register-fail': quit(1)
        if args[1] not in registered: registered.append(args[1])
        watched = root / 'registry-watched-inodes.json'
        values = set(json.loads(watched.read_text())); values.add(inode_key(pathlib.Path(args[1]))); watched.write_text(json.dumps(sorted(values)))
        if scenario == 'retire-original-missing' and retained_mode:
            original = root / 'DataBackup/ProgramRollback/Program.noindex/搞机灵.app'
            if original.exists(): original.rename(original.with_name('held.app'))
    else:
        if args[1] not in registered: print('synthetic -10814 from spotlight', file=sys.stderr); quit(1)
        if scenario in ('unregister-fail', 'formal-reappears') and args[1] == str(root / 'Applications/搞机灵.app'): quit(1)
        if scenario == 'stage-u-error' and 'New.noindex' in args[1]: quit(1)
        if scenario in ('old-unregister-fail', 'verify-fail-old-unregister-fail') and ('Old.noindex' in args[1] or 'Program.noindex' in args[1]): quit(1)
        if scenario == 'failed-unregister-fail' and 'Failed.noindex' in args[1]: quit(1)
        residual = scenario == 'unregister-zero-residual' or (scenario == 'old-unregister-zero-residual' and 'Old.noindex' in args[1]) or (scenario == 'stage-u-zero-residual' and 'New.noindex' in args[1])
        if not residual: registered.remove(args[1])
    state.write_text(json.dumps(registered)); quit()
elif name == 'codesign':
    assert args[:2] == ['--verify', '--strict']; path = bounded(args[-1])
    if scenario == 'source-signature-fail' and 'Mount.noindex' in str(path): quit(1)
    if scenario == 'installed-signature-fail' and path == root / 'Applications/搞机灵.app':
        version = plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        if version == '1.13': quit(1)
    if scenario in ('stage-tampered-receipt', 'stage-unknown-source', 'stage-wrong-current') and path == root / 'Applications/搞机灵.app' and not (root / 'injected-stage-change').exists():
        version = plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        if version == '1.13':
            (root / 'injected-stage-change').write_text(scenario)
            receipt = next((root / 'Home').rglob('staged-new.json')); item = json.loads(receipt.read_bytes())
            if scenario == 'stage-tampered-receipt': receipt.write_bytes(receipt.read_bytes()+b' ')
            elif scenario == 'stage-unknown-source':
                unknown = bounded(item['sourcePath']); unknown.mkdir(); (unknown / 'unknown-occupant').write_text('must retain')
            else:
                held = bounded(item['work']) / 'Held-new.noindex'; held.mkdir()
                path.rename(held / path.name)
                shutil.copytree(root / 'Source/搞机灵.app', path)
                (path / 'unknown-occupant').write_text('different new inode; must retain')
    quit()
elif name == 'hdiutil':
    if args[0] == 'attach':
        target = bounded(value('-mountpoint')); bounded(args[-1])
        shutil.copytree(root / 'Source' / '搞机灵.app', target / '搞机灵.app'); quit()
    assert args[0] == 'detach'; target = bounded(args[-1])
    if scenario == 'detach-fail': quit(1)
    for item in target.iterdir(): shutil.rmtree(item) if item.is_dir() else item.unlink()
    quit()
elif name == 'ditto':
    source, target = map(bounded, args); shutil.copytree(source, target)
    if 'New.noindex' in str(target):
        state = root / 'registry-state.json'; registered = json.loads(state.read_text())
        if str(target) not in registered: registered.append(str(target))
        state.write_text(json.dumps(registered))
    quit()
elif name in ('pkill', 'pgrep'):
    assert args[-1] == 'GaoJiLing'; quit(1)
elif name == 'open':
    raise AssertionError('Default/static install must never launch an app')
elif name == 'sleep': quit()
elif name == 'shasum': quit()
elif name in ('rm', 'mv', 'mkdir', 'find'):
    paths = [bounded(arg) for arg in args if not arg.startswith('-')]
    if name == 'rm':
        for path in paths:
            registered = json.loads((root / 'registry-state.json').read_text())
            assert not any(path == pathlib.Path(value) or path in pathlib.Path(value).parents for value in registered), ('would delete registered app and create ghost', path)
            if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
            elif path.exists() or path.is_symlink(): path.unlink()
    elif name == 'mv':
        assert len(paths) == 2
        move_fixture(*paths)
    elif name == 'mkdir':
        for path in paths: path.mkdir(parents='-p' in args, exist_ok='-p' in args)
    else: raise AssertionError('Default install must defer old-package deletion')
    quit()
else: raise AssertionError(('unexpected stub command', name))
'''


class InstallerFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gaojiling-script-test-", suffix=".noindex", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.project = self.root / "Project"
        (self.project / "Scripts").mkdir(parents=True)
        (self.project / "Release").mkdir()
        (self.project / "VERSION").write_text("1.13\n")
        (self.project / "Release/GaoJiLing-1.13.dmg").write_bytes(b"synthetic package")
        self.apps = self.root / "Applications"
        self.apps.mkdir()
        self.installed = make_app(self.apps)
        self.original_identity = safety.app_identity(self.installed)
        (self.root / 'registry-state.json').write_text(json.dumps([str(self.installed)]))
        details = self.installed.lstat()
        (self.root / 'registry-watched-inodes.json').write_text(json.dumps([':'.join(map(str, (details.st_dev, details.st_ino)))]))
        (self.root / "Source").mkdir()
        make_app(self.root / "Source", version="1.13")
        self.stub = self.root / "Stubs"
        self.stub.mkdir()
        target = self.stub / "stub.py"
        target.write_text("#!" + sys.executable + "\n" + STUB)
        target.chmod(0o700)
        guarded = ('python3', 'PlistBuddy', 'lsregister', 'codesign', 'hdiutil', 'ditto',
                   'pkill', 'pgrep', 'open', 'sleep', 'shasum', 'rm', 'mv', 'mkdir', 'find')
        for name in guarded:
            (self.stub / name).symlink_to(target)
        original = (HERE / "install.sh").read_text()
        script = original.replace(str(safety.LSREGISTER), str(self.stub / 'lsregister'))
        script = script.replace('/usr/libexec/PlistBuddy', str(self.stub / 'PlistBuddy'))
        script = script.replace('/Applications', str(self.apps)).replace('$HOME', '$FIXTURE_HOME')
        # Prove fixture path replacement and every mutable system command stub
        # before the copied installer is ever evaluated by zsh.
        self.assertNotIn('"/Applications/', script)
        self.assertNotIn('/System/Library/', script)
        self.assertNotIn('/usr/libexec/', script)
        self.assertNotIn('$HOME', script)
        for name in guarded:
            self.assertEqual((self.stub / name).resolve(), target)
        (self.project / "Scripts/install.sh").write_text(script)
        for name in ('backup-data.py', 'release-safety.py'):
            (self.project / "Scripts" / name).write_text('# Only the mandatory python3 stub can dispatch this placeholder.\n')

    def tearDown(self):
        self.temporary.cleanup()

    def run_install(self, scenario, extra=()):
        environment = {**os.environ, 'PATH': str(self.stub) + ':/usr/bin:/bin',
                       'FIXTURE_HOME': str(self.root / 'Home'), 'GAO_RELEASE_FIXTURE': str(self.root),
                       'GAO_RELEASE_SCENARIO': scenario, 'PYTHONDONTWRITEBYTECODE': '1'}
        result = subprocess.run(['/bin/zsh', str(self.project / 'Scripts/install.sh'), *extra],
                                env=environment, capture_output=True, text=True)
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertFalse(any(name == 'open' for name, _ in calls), result.stdout + result.stderr)
        self.assertTrue(all(args[0] in ('-u', '-f') for name, args in calls if name == 'lsregister'))
        return result, calls

    def installed_version(self):
        return plistlib.loads((self.installed / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']

    def assert_work_clean(self):
        self.assertEqual(list(self.apps.glob('.GaoJiLing-install-*')), [])
        self.assertEqual(list(self.apps.rglob('*.app')), [self.installed])

    def test_default_install_archives_old_program_and_cleans_expanded_copies(self):
        result, calls = self.run_install('success')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.13')
        self.assert_work_clean()
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertFalse(list((self.root / 'DataBackup').rglob('*.app')))
        self.assertIn('未自动启动或运行冒烟', result.stdout)
        self.assertTrue(any(name == 'hdiutil' and args[0] == 'detach' for name, args in calls))
        self.assertFalse(any(name == 'lsregister' and args[0] == '-u' and 'Mount.noindex' in args[1] for name, args in calls))
        events = [json.loads(line) for path in (self.root / 'Home').rglob('unregistration.jsonl') for line in path.read_text().splitlines()]
        self.assertTrue(any('Mount.noindex' in event['path'] and event['status'] == 'alreadyAbsent' and not event['commandIssued'] for event in events))
        self.assertTrue(any(name == 'lsregister' and args[0] == '-u' and 'Old.noindex' in args[1] for name, args in calls))
        self.assertEqual(json.loads((self.root / 'registry-state.json').read_text()), [str(self.installed)])

    def test_precise_missing_cleanup_policy_forwarded_to_backup_and_verify(self):
        policy = self.root / 'exact-missing-policy.json'
        policy.write_text('synthetic policy dispatched unchanged')
        result, calls = self.run_install('success', ('--no-launch', '--confirmed-missing-cleanup', str(policy)))
        self.assertEqual(result.returncode, 0, result.stderr)
        backup_calls = [args for name, args in calls if name == 'python3' and Path(args[0]).name == 'backup-data.py']
        self.assertEqual(len(backup_calls), 2)
        for args in backup_calls:
            self.assertEqual(args[-2:], ['--confirmed-missing-cleanup', str(policy)])
        self.assert_work_clean()

    def retained_receipt(self):
        return self.root / 'DataBackup/ProgramRollback/receipt.json'

    def assert_retained_original_restored(self, result, expected_status=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertEqual(safety.app_identity(self.installed), self.original_identity)
        self.assertFalse((self.retained_receipt().parent / 'Program.noindex/搞机灵.app').exists())
        state = json.loads((self.retained_receipt().parent / 'RESTORED.json').read_text())
        self.assertEqual(state['authority'], str(self.installed))
        self.assertEqual(state['identity'], self.original_identity)
        if expected_status is not None: self.assertEqual(state['status'], expected_status)

    def test_format2_static_success_keeps_original_inode_outside_disposable_work(self):
        result, calls = self.run_install('retained-success', ('--defer-cleanup',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.13')
        retained = self.retained_receipt().parent / 'Program.noindex/搞机灵.app'
        self.assertEqual(safety.app_identity(retained), self.original_identity)
        self.assertTrue((self.retained_receipt().parent / 'VERIFIED').is_file())
        self.assertFalse((self.retained_receipt().parent / 'RESTORED.json').exists())
        self.assert_work_clean()
        self.assertFalse(any(name == 'rm' and any(Path(arg) == retained or Path(arg) in retained.parents for arg in args if not arg.startswith('-')) for name, args in calls))
        self.assertTrue(any(name == 'python3' and args[1] == 'preserve-original' for name, args in calls))
        self.assertTrue(any(name == 'python3' and args[1] == 'record-plan' for name, args in calls))
        self.assertEqual(json.loads((self.root / 'registry-state.json').read_text()), [str(self.installed)])

    def test_format2_failure_before_original_move_records_unmoved_authority(self):
        result, calls = self.run_install('retained-move-old-before-fail')
        self.assert_retained_original_restored(result)
        self.assertFalse((self.retained_receipt().parent / 'VERIFIED').exists())
        self.assertFalse(any(name == 'python3' and args[1] == 'extract' for name, args in calls))
        self.assert_work_clean()

    def test_format2_marker_failure_after_original_move_restores_same_inode(self):
        result, calls = self.run_install('retained-marker-fail')
        self.assert_retained_original_restored(result)
        self.assertFalse((self.retained_receipt().parent / 'VERIFIED').exists())
        self.assertFalse(any(name == 'python3' and args[1] == 'extract' for name, args in calls))
        self.assert_work_clean()

    def test_format2_failure_after_new_install_restores_same_original_inode(self):
        result, calls = self.run_install('retained-verify-fail')
        self.assert_retained_original_restored(result)
        self.assertTrue((self.retained_receipt().parent / 'VERIFIED').is_file())
        self.assertTrue(any(name == 'python3' and args[1] == 'move-app' and 'New.noindex' in args[args.index('--app') + 1] for name, args in calls))
        self.assert_work_clean()

    def test_format2_old_registration_error_does_not_block_original_restoration(self):
        result, calls = self.run_install('retained-verify-fail-old-unregister-fail')
        self.assert_retained_original_restored(result)
        self.assertTrue(any(name == 'lsregister' and args[0] == '-u' and 'Program.noindex' in args[1] for name, args in calls))
        self.assertIn('继续恢复文件', result.stderr)
        self.assert_work_clean()

    def test_format2_missing_authority_blocks_retirement_and_work_deletion(self):
        result, calls = self.run_install('retained-retire-original-missing')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.13')
        work = list(self.apps.glob('.GaoJiLing-install-*.noindex'))
        self.assertEqual(len(work), 1)
        self.assertTrue((self.retained_receipt().parent / 'Program.noindex/held.app').is_dir())
        self.assertFalse(any(name == 'rm' and str(work[0]) in args for name, args in calls))
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_preservation_failure_restores_old_program_and_keeps_backups(self):
        result, _ = self.run_install('verify-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue((self.root / 'DataBackup/VERIFIED').exists())
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').exists())
        self.assert_work_clean()
        self.assertTrue(list((self.root / 'Home').rglob('ROLLBACK')))

    def test_backup_and_archive_failure_leave_old_program(self):
        result, _ = self.run_install('archive-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()
        self.assertTrue((self.root / 'DataBackup/VERIFIED').exists())

    def test_preflight_empty_view_blocks_before_mount_or_stop(self):
        result, calls = self.run_install('preflight-empty')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(name in ('hdiutil', 'pkill', 'pgrep') for name, _ in calls))
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_final_empty_view_is_incomplete_with_no_expanded_old_copy(self):
        result, _ = self.run_install('final-empty')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.13')
        self.assertNotIn('唯一入口核验通过', result.stdout)
        self.assert_work_clean()
        self.assertTrue(list((self.root / 'Home').rglob('after.json')))

    def test_detach_failure_cannot_report_success_or_delete_mount(self):
        result, _ = self.run_install('detach-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        work = list(self.apps.glob('.GaoJiLing-install-*.noindex'))
        self.assertEqual(len(work), 1)
        self.assertTrue((work[0] / 'Mount.noindex/搞机灵.app').is_dir())
        self.assertIn('未能卸载', result.stderr)
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_registration_failure_is_not_silently_reported_as_success(self):
        result, _ = self.run_install('register-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('唯一入口核验通过', result.stdout)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertTrue(list((self.root / 'Home').rglob('ROLLBACK')))
        work = list(self.apps.glob('.GaoJiLing-install-*.noindex'))
        self.assertEqual(len(work), 1)
        self.assertTrue((work[0] / 'Failed.noindex/搞机灵.app').is_dir())
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_failure_before_first_rename_keeps_original_in_place(self):
        result, calls = self.run_install('move-old-before-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()
        self.assertFalse(any(name == 'python3' and len(args) > 1 and args[1] == 'extract' for name, args in calls))

    def test_failure_after_first_rename_restores_official_entry(self):
        result, _ = self.run_install('move-old-after-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_failure_after_new_rename_restores_official_entry(self):
        result, _ = self.run_install('move-new-after-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_source_signature_failure_still_detaches_and_cleans(self):
        result, calls = self.run_install('source-signature-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue(any(name == 'hdiutil' and args[0] == 'detach' for name, args in calls))
        self.assert_work_clean()

    def test_installed_signature_failure_can_restore_verified_old_program(self):
        result, _ = self.run_install('installed-signature-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_term_after_old_rename_restores_official_entry(self):
        result, _ = self.run_install('move-old-term')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_term_during_staging_keeps_original_and_cleans_registered_stage(self):
        result, _ = self.run_install('stage-prepare-term')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_repeated_term_during_rollback_cannot_leave_official_path_empty(self):
        result, _ = self.run_install('verify-fail-repeat-term')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assert_work_clean()

    def test_old_formal_unregistration_is_no_longer_a_pre_move_gate(self):
        result, calls = self.run_install('unregister-fail')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.13')
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertFalse(any(name == 'lsregister' and args == ['-u', str(self.installed)] for name, args in calls))
        self.assert_work_clean()

    def test_formal_rediscovery_does_not_block_retaining_original(self):
        result, calls = self.run_install('retained-formal-reappears')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed_version(), '1.13')
        retained = self.retained_receipt().parent / 'Program.noindex/搞机灵.app'
        self.assertEqual(safety.app_identity(retained), self.original_identity)
        self.assertFalse(any(name == 'lsregister' and args == ['-u', str(self.installed)] for name, args in calls))
        self.assert_work_clean()

    def test_registered_unmoved_new_is_unregistered_before_work_deletion(self):
        result, calls = self.run_install('archive-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(safety.app_identity(self.installed), self.original_identity)
        stage_u = [i for i,(name,args) in enumerate(calls) if name=='lsregister' and args[0]=='-u' and 'New.noindex' in args[1]]
        work_rm = [i for i,(name,args) in enumerate(calls) if name=='rm' and any('.GaoJiLing-install-' in a and a.endswith('.noindex') for a in args)]
        self.assertEqual(len(stage_u), 1)
        self.assertTrue(work_rm and stage_u[0] < work_rm[-1])
        self.assertEqual(json.loads((self.root/'registry-state.json').read_text()), [str(self.installed)])
        self.assert_work_clean()

    def assert_stage_failure_keeps_work(self, scenario, command_expected):
        result, calls = self.run_install(scenario)
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        work = list(self.apps.glob('.GaoJiLing-install-*.noindex'))
        self.assertEqual(len(work),1)
        self.assertTrue((work[0]/'New.noindex/搞机灵.app').is_dir())
        stage_u = [args for name,args in calls if name=='lsregister' and args[0]=='-u' and 'New.noindex' in args[1]]
        self.assertEqual(bool(stage_u), command_expected)
        self.assertFalse(any(name=='rm' and str(work[0]) in args for name,args in calls))
        self.assertEqual(safety.app_identity(self.installed), self.original_identity)

    def test_stage_unregistration_error_with_residual_keeps_work(self):
        self.assert_stage_failure_keeps_work('stage-u-error', True)

    def test_stage_unregistration_empty_view_keeps_work_without_command(self):
        self.assert_stage_failure_keeps_work('stage-u-empty', False)

    def test_stage_unregistration_zero_with_residual_keeps_work(self):
        self.assert_stage_failure_keeps_work('stage-u-zero-residual', True)

    def test_moved_new_ghost_is_removed_without_unregistering_new_formal_path(self):
        result, calls = self.run_install('retained-moved-new-ghost')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue(any(name=='python3' and args[1]=='unregister-staged-source' for name,args in calls))
        formal_f = [i for i,(name,args) in enumerate(calls) if name=='lsregister' and args==['-f',str(self.installed)]]
        stage_u = [i for i,(name,args) in enumerate(calls) if name=='lsregister' and args[0]=='-u' and 'New.noindex' in args[1]]
        self.assertTrue(formal_f and stage_u and formal_f[-1] < stage_u[0])
        self.assertFalse(any(name=='lsregister' and args==['-u',str(self.installed)] for name,args in calls))
        self.assertEqual(safety.app_identity(self.retained_receipt().parent/'Program.noindex/搞机灵.app'),self.original_identity)
        self.assertEqual(json.loads((self.root/'registry-state.json').read_text()),[str(self.installed)])
        self.assert_work_clean()

    def test_rollback_to_failed_keeps_new_ghost_until_old_is_restored(self):
        result,calls=self.run_install('failed-new-ghost')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(safety.app_identity(self.installed),self.original_identity)
        formal_f=[i for i,(name,args) in enumerate(calls) if name=='lsregister' and args==['-f',str(self.installed)]]
        stage_u=[i for i,(name,args) in enumerate(calls) if name=='lsregister' and args[0]=='-u' and 'New.noindex' in args[1]]
        failed_u=[i for i,(name,args) in enumerate(calls) if name=='lsregister' and args[0]=='-u' and 'Failed.noindex' in args[1]]
        self.assertTrue(formal_f and stage_u and failed_u and formal_f[-1] < stage_u[0] < failed_u[0])
        self.assertEqual(json.loads((self.root/'registry-state.json').read_text()),[str(self.installed)])
        self.assert_work_clean()

    def assert_invalid_stage_proof_keeps_work(self, scenario):
        result,calls=self.run_install(scenario)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        work=list(self.apps.glob('.GaoJiLing-install-*.noindex'));self.assertEqual(len(work),1)
        self.assertFalse(any(name=='lsregister' and args[0]=='-u' and 'New.noindex' in args[1] for name,args in calls))
        self.assertFalse(any(name=='rm' and str(work[0]) in args for name,args in calls))
        return work[0]

    def test_tampered_stage_receipt_refuses_unregistration_and_work_deletion(self):
        self.assert_invalid_stage_proof_keeps_work('stage-tampered-receipt')

    def test_unknown_stage_source_occupant_refuses_unregistration_and_work_deletion(self):
        work=self.assert_invalid_stage_proof_keeps_work('stage-unknown-source')
        self.assertEqual((work/'New.noindex/搞机灵.app/unknown-occupant').read_text(),'must retain')

    def test_different_current_new_inode_refuses_unregistration_and_work_deletion(self):
        work=self.assert_invalid_stage_proof_keeps_work('stage-wrong-current')
        self.assertTrue((work/'Held-new.noindex/搞机灵.app').is_dir())
        self.assertTrue((self.installed/'unknown-occupant').is_file())

    def test_empty_unregistration_view_blocks_without_issuing_unregistration(self):
        result, calls = self.run_install('empty-unregister-view')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertFalse(any(name == 'lsregister' and args[0] == '-u' for name, args in calls))
        self.assertEqual(len(list(self.apps.glob('.GaoJiLing-install-*.noindex'))), 1)
        self.assertIn('未完成', result.stderr)

    def test_moved_old_unregistration_error_retains_noindex_program_instead_of_ghost(self):
        result, calls = self.run_install('old-unregister-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.13')
        work = list(self.apps.glob('.GaoJiLing-install-*.noindex'))
        self.assertEqual(len(work), 1)
        old = work[0] / 'Old.noindex/搞机灵.app'
        self.assertEqual(plistlib.loads((old / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.12')
        self.assertIn(str(old), json.loads((self.root / 'registry-state.json').read_text()))
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertFalse(any(name == 'rm' and args[-1] in (str(old), str(work[0])) for name, args in calls))
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_moved_old_empty_view_retains_the_program_without_issuing_its_unregistration(self):
        result, calls = self.run_install('old-unregister-empty')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.13')
        old = next(self.apps.glob('.GaoJiLing-install-*.noindex')) / 'Old.noindex/搞机灵.app'
        self.assertTrue(old.is_dir())
        self.assertFalse(any(name == 'lsregister' and args[0] == '-u' and args[1] == str(old) for name, args in calls))
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_moved_old_zero_return_with_residual_preserves_work(self):
        result, _ = self.run_install('old-unregister-zero-residual')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.13')
        old = next(self.apps.glob('.GaoJiLing-install-*.noindex')) / 'Old.noindex/搞机灵.app'
        self.assertTrue(old.is_dir())
        self.assertIn(str(old), json.loads((self.root / 'registry-state.json').read_text()))

    def test_failed_program_following_inode_is_unregistered_after_old_restoration(self):
        result, calls = self.run_install('verify-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        failed_calls = [index for index,(name,args) in enumerate(calls) if name == 'lsregister' and args[0] == '-u' and 'Failed.noindex' in args[1]]
        restored_registration = [index for index,(name,args) in enumerate(calls) if name == 'lsregister' and args == ['-f', str(self.installed)]]
        self.assertEqual(len(failed_calls), 1)
        self.assertTrue(restored_registration and restored_registration[-1] < failed_calls[0])
        self.assertEqual(json.loads((self.root / 'registry-state.json').read_text()), [str(self.installed)])
        self.assert_work_clean()

    def test_failed_program_with_bad_info_uses_pinned_identity_for_moved_path_cleanup(self):
        result, calls = self.run_install('failed-bad-info')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        helper_calls = [args for name,args in calls if name == 'python3' and len(args)>1 and args[1]=='unregister-exact' and any('Failed.noindex' in arg for arg in args)]
        self.assertEqual(len(helper_calls), 1)
        self.assertIn('--expected-identity', helper_calls[0])
        self.assertFalse(any(name in ('PlistBuddy','codesign') and 'Failed.noindex' in args[-1] for name,args in calls))
        self.assert_work_clean()

    def test_failed_program_unregistration_error_retains_noindex_scene_after_old_restored(self):
        result, calls = self.run_install('failed-unregister-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        work = next(self.apps.glob('.GaoJiLing-install-*.noindex'))
        failed = work / 'Failed.noindex/搞机灵.app'
        self.assertTrue(failed.is_dir())
        self.assertIn(str(failed), json.loads((self.root / 'registry-state.json').read_text()))
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertFalse(any(name=='rm' and args[-1] in (str(work),str(failed)) for name,args in calls))
        self.assertNotIn('唯一入口核验通过', result.stdout)

    def test_failed_program_empty_view_retains_noindex_scene(self):
        result, calls = self.run_install('failed-unregister-empty')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        failed = next(self.apps.glob('.GaoJiLing-install-*.noindex')) / 'Failed.noindex/搞机灵.app'
        self.assertTrue(failed.is_dir())
        self.assertFalse(any(name=='lsregister' and args[0]=='-u' and args[1]==str(failed) for name,args in calls))

    def test_first_install_rollback_cleans_moved_failed_inode_without_old_program(self):
        shutil.rmtree(self.installed)
        (self.root / 'registry-state.json').write_text('[]')
        (self.root / 'registry-watched-inodes.json').write_text('[]')
        result, calls = self.run_install('installed-signature-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.installed.exists())
        self.assertTrue(any(name=='lsregister' and args[0]=='-u' and 'Failed.noindex' in args[1] for name,args in calls))
        self.assertEqual(list(self.apps.glob('.GaoJiLing-install-*')), [])
        self.assertEqual(json.loads((self.root / 'registry-state.json').read_text()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
