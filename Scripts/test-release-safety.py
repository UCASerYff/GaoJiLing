#!/usr/bin/env python3
"""Targeted release-safety tests. No app is launched or registered.

Archive tests use only synthetic bundles inside a private .noindex fixture.
Installer tests execute a fixture copy after replacing every system/app path;
all process, launch, mount, signing and registry commands are mandatory stubs.
"""
import importlib.util
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

    def invoke(self, dumps, command_code=0, expected=None):
        values, calls, last = iter(dumps), [], [None]
        def run(command, **kwargs):
            calls.append(command)
            if command[1] == '-dump':
                last[0] = next(values, last[0])
                return subprocess.CompletedProcess(command, 0, last[0], '')
            self.assertEqual(command, [safety.LSREGISTER, '-u', str(self.app)])
            return subprocess.CompletedProcess(command, command_code, '', 'synthetic -10814' if command_code else '')
        safety.unregister_registration(self.app, self.baseline, self.record, expected_identity=expected, run=run, wait=lambda _: None)
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


# The stub has a hard fixture boundary before every simulated operation. Its
# interpreter is fixed; it never falls through to a real same-named command.
STUB = r'''import hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, sys, tempfile, zipfile
root = pathlib.Path(os.environ['GAO_RELEASE_FIXTURE']).resolve()
assert root.name.endswith('.noindex') and str(root).startswith('/private/tmp/gaojiling-script-test-')
scenario = os.environ['GAO_RELEASE_SCENARIO']
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
def quit(code=0): sys.exit(code)
with (root / 'calls.jsonl').open('a') as log: log.write(json.dumps([name, args]) + '\n')
if name == 'python3':
    script = bounded(args.pop(0))
    if script.name == 'backup-data.py':
        if '--verify' in args: quit(1 if scenario in ('verify-fail', 'verify-fail-repeat-term', 'failed-unregister-fail', 'failed-unregister-empty', 'failed-bad-info') else 0)
        if scenario == 'backup-fail': quit(1)
        target = root / 'DataBackup'
        target.mkdir()
        (target / 'VERIFIED').write_text('synthetic data backup')
        print(target)
        quit()
    assert script.name == 'release-safety.py'
    action = args.pop(0)
    if action == 'stop-program': quit()
    if action == 'unregister-exact':
        app, baseline, record = bounded(value('--app')), bounded(value('--baseline')), bounded(value('--record'))
        assert baseline.is_file()
        if '--expected-identity' in args:
            details = app.lstat()
            assert value('--expected-identity') == ':'.join(map(str, (details.st_dev, details.st_ino, details.st_uid)))
        else:
            assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == 'com.gaoseries.GaoJiLing'
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
    if action in ('workdir', 'recorddir'):
        parent = bounded(value('--parent')); parent.mkdir(parents=True, exist_ok=True)
        print(tempfile.mkdtemp(prefix=value('--prefix'), suffix='.noindex', dir=parent)); quit()
    if action == 'check-noindex':
        path = bounded(args[0])
        quit(0 if any(p.name.endswith('.noindex') for p in path.parent.resolve().parents) or path.parent.resolve().name.endswith('.noindex') else 1)
    if action == 'identity':
        path = bounded(value('--app')); info = path.lstat()
        observed = ':'.join(map(str, (info.st_dev, info.st_ino, info.st_uid)))
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
        if scenario == 'archive-fail': quit(1)
        target.mkdir()
        contents = tree(source)
        with zipfile.ZipFile(target / 'previous-program.zip', 'w') as z:
            for path, data in contents.items(): z.writestr(path, bytes.fromhex(data))
        receipt = target / 'receipt.json'; receipt.write_text(json.dumps({'tree': contents}))
        (target / 'VERIFIED').write_text('synthetic roundtrip')
        print(receipt); quit()
    if action in ('verify', 'extract'):
        receipt = bounded(value('--receipt')); contents = json.loads(receipt.read_text())['tree']
        if action == 'verify': assert tree(bounded(value('--app'))) == contents
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
    else:
        if args[1] not in registered: print('synthetic -10814 from spotlight', file=sys.stderr); quit(1)
        if scenario == 'unregister-fail' and args[1] == str(root / 'Applications/搞机灵.app'): quit(1)
        if scenario == 'old-unregister-fail' and 'Old.noindex' in args[1]: quit(1)
        if scenario == 'failed-unregister-fail' and 'Failed.noindex' in args[1]: quit(1)
        residual = scenario == 'unregister-zero-residual' or (scenario == 'old-unregister-zero-residual' and 'Old.noindex' in args[1])
        if not residual: registered.remove(args[1])
    state.write_text(json.dumps(registered)); quit()
elif name == 'codesign':
    assert args[:2] == ['--verify', '--strict']; path = bounded(args[-1])
    if scenario == 'source-signature-fail' and 'Mount.noindex' in str(path): quit(1)
    if scenario == 'installed-signature-fail' and path == root / 'Applications/搞机灵.app':
        version = plistlib.loads((path / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        if version == '1.13': quit(1)
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
    source, target = map(bounded, args); shutil.copytree(source, target); quit()
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
        moving_old = paths[0] == root / 'Applications/搞机灵.app' and 'Old.noindex' in str(paths[1])
        moving_new = 'New.noindex' in str(paths[0]) and paths[1] == root / 'Applications/搞机灵.app'
        if scenario == 'move-old-before-fail' and moving_old: quit(1)
        moved_identity = inode_key(paths[0])
        paths[0].rename(paths[1])
        # LS can follow an inode after exact -u of its previous path was already
        # observed absent. Keep that watcher until the moved path is unregistered.
        state, watched = root / 'registry-state.json', root / 'registry-watched-inodes.json'
        registered, values = json.loads(state.read_text()), set(json.loads(watched.read_text()))
        if str(paths[0]) in registered: registered.remove(str(paths[0]))
        if moved_identity in values or moving_new:
            values.add(moved_identity)
            if str(paths[1]) not in registered: registered.append(str(paths[1]))
        state.write_text(json.dumps(registered)); watched.write_text(json.dumps(sorted(values)))
        if scenario == 'failed-bad-info' and 'Failed.noindex' in str(paths[1]):
            (paths[1] / 'Contents/Info.plist').write_bytes(b'damaged synthetic new Info; pinned identity still valid')
        if scenario == 'move-old-term' and moving_old: os.kill(os.getppid(), signal.SIGTERM)
        if scenario == 'verify-fail-repeat-term' and 'Failed.noindex' in str(paths[1]): os.kill(os.getppid(), signal.SIGTERM)
        if (scenario == 'move-old-after-fail' and moving_old) or (scenario == 'move-new-after-fail' and moving_new): quit(1)
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

    def test_term_before_first_rename_keeps_original(self):
        result, _ = self.run_install('unregister-term')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

    def test_repeated_term_during_rollback_cannot_leave_official_path_empty(self):
        result, _ = self.run_install('verify-fail-repeat-term')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assert_work_clean()

    def test_real_registration_unregistration_failure_keeps_verified_original(self):
        result, calls = self.run_install('unregister-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assertTrue((self.root / 'DataBackup/ProgramRollback/previous-program.zip').is_file())
        self.assertTrue(list((self.root / 'Home').rglob('ROLLBACK')))
        self.assertFalse(any(name == 'mv' and args[0] == str(self.installed) for name, args in calls))
        self.assert_work_clean()

    def test_zero_unregistration_result_with_residual_also_blocks(self):
        result, _ = self.run_install('unregister-zero-residual')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_version(), '1.12')
        self.assert_work_clean()

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
