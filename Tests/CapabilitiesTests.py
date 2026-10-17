#!/usr/bin/env python3
"""Check the shipped capability/UTI contract with private build fixtures."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/make-capabilities.py"
spec = importlib.util.spec_from_file_location("make_capabilities", SCRIPT)
capabilities = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capabilities)


class CapabilitiesTests(unittest.TestCase):
    def info(self, version="1.09"):
        return {"CFBundleIdentifier": capabilities.BUNDLE_ID, "CFBundleShortVersionString": version,
                "CFBundleVersion": version.replace(".", ""), "CFBundleExecutable": "GaoJiLing"}

    def test_version_and_identity_track_build_inputs(self):
        for version in ("1.09", "1.10", "1.99", "2.00"):
            result, plist = capabilities.resources(version, self.info(version))
            self.assertEqual(result["appVersion"], plist["CFBundleShortVersionString"])
            self.assertEqual(result["bundleID"], plist["CFBundleIdentifier"])
            self.assertEqual(result["schemaVersion"], 1)
        for version in ("1.9", "1.100", "1.10\nextra", "nan"):
            with self.assertRaises(ValueError): capabilities.resources(version, self.info(version))
        with self.assertRaises(ValueError): capabilities.resources("1.10", self.info("1.09"))
        with self.assertRaises(ValueError): capabilities.resources("1.09", dict(self.info(), CFBundleIdentifier="com.example.other"))

    def test_only_implemented_parameter_and_reference_contracts(self):
        document, _ = capabilities.resources("1.09", self.info())
        actions = {item["action"]: item for item in document["actions"]}
        self.assertEqual(set(actions), {"storage.inspect", "cleanup.review", "apps.uninstall.review"})
        for name, action in actions.items():
            self.assertIs(action["supportsItems"], False)
            self.assertEqual(action["supportsReferences"], name != "cleanup.review")
            self.assertIs(action["requiresUserConfirmation"], True)
            schema = action["parametersSchema"]
            self.assertEqual(schema["type"], "object")
            self.assertIs(schema["additionalProperties"], False)
            self.assertEqual(schema["required"], [])
            self.assertEqual(set(schema["properties"]), {"mode"} if name == "storage.inspect" else set())
        self.assertEqual(actions["storage.inspect"]["parametersSchema"]["properties"]["mode"]["enum"], ["metadata", "duplicates"])
        self.assertEqual(actions["storage.inspect"]["referencesSchema"]["items"]["properties"]["kind"]["const"], "directory")
        self.assertEqual(actions["apps.uninstall.review"]["referencesSchema"]["items"]["properties"]["kind"]["const"], "application")
        self.assertEqual(actions["cleanup.review"]["referencesSchema"]["maxItems"], 0)
        self.assertTrue(actions["cleanup.review"]["reviewOnly"] and actions["apps.uninstall.review"]["reviewOnly"])

    def test_imported_package_is_alternate_and_preserves_other_declarations(self):
        original = self.info()
        original["CFBundleDocumentTypes"] = [{"CFBundleTypeName": "Existing", "LSItemContentTypes": ["com.example.existing"]}]
        original["UTImportedTypeDeclarations"] = [{"UTTypeIdentifier": "com.example.existing"}]
        _, plist = capabilities.resources("1.09", original)
        _, repeated = capabilities.resources("1.09", plist)
        self.assertEqual(plist, repeated)
        self.assertEqual(plist["CFBundleDocumentTypes"][0], original["CFBundleDocumentTypes"][0])
        entry = plist["CFBundleDocumentTypes"][1]
        self.assertEqual(entry["LSHandlerRank"], "Alternate")
        self.assertEqual(entry["CFBundleTypeRole"], "Viewer")
        self.assertIs(entry["LSTypeIsPackage"], True)
        self.assertEqual(entry["LSItemContentTypes"], ["com.gaoseries.action-package"])
        uti = plist["UTImportedTypeDeclarations"][1]
        self.assertEqual(uti["UTTypeConformsTo"], ["com.apple.package"])
        self.assertEqual(uti["UTTypeTagSpecification"], {"public.filename-extension": ["gaoaction"]})
        self.assertNotIn("UTExportedTypeDeclarations", plist)

    def test_command_generates_shippable_resources_and_refuses_bad_build(self):
        with tempfile.TemporaryDirectory(prefix="gaojiling-capability-tests-", dir="/private/tmp") as directory:
            root = Path(directory); version = root / "VERSION"; plist = root / "Info.plist"; output = root / "GaoCapabilities.json"
            version.write_text("1.10\n"); plist.write_bytes(plistlib.dumps(self.info("1.10")))
            args = [sys.executable, str(SCRIPT), "--version-file", str(version), "--info-plist", str(plist), "--output", str(output)]
            subprocess.run(args, check=True, capture_output=True)
            actual = json.loads(output.read_bytes()); actual_plist = plistlib.loads(plist.read_bytes())
            self.assertEqual(actual["appVersion"], "1.10")
            self.assertEqual(actual_plist["CFBundleDocumentTypes"][0]["LSHandlerRank"], "Alternate")
            old_output, old_plist = output.read_bytes(), plist.read_bytes()
            version.write_text("1.11\n")
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), old_output); self.assertEqual(plist.read_bytes(), old_plist)
            version.write_text("1.10\n"); output.unlink()
            protected = root / "unrelated"; protected.write_bytes(b"keep"); output.symlink_to(protected)
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            self.assertEqual(protected.read_bytes(), b"keep")


if __name__ == "__main__": unittest.main()
