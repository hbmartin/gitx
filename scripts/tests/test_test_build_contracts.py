import unittest
import json
import pathlib
import shutil
import subprocess
import tempfile
from unittest import mock
from support import ROOT
import check_test_build_contracts as contracts


class TestBuildContractTests(unittest.TestCase):
    def settings(self):
        return [{"target": name, "buildSettings": {"ENABLE_TESTABILITY": "YES",
                "HEADER_SEARCH_PATHS": "External/objective-git/External/libgit2/include"}}
                for name in ("GitX", "GitXTests", "GitXUITests")]

    def test_missing_import_and_visibility_fail_before_execution(self):
        settings = self.settings()
        contracts.validate_settings(settings, ROOT)
        settings[1]["buildSettings"]["HEADER_SEARCH_PATHS"] = "Classes"
        with self.assertRaisesRegex(ValueError, "import-path"):
            contracts.validate_settings(settings, ROOT)
        settings = self.settings()
        settings[0]["buildSettings"]["ENABLE_TESTABILITY"] = "NO"
        with self.assertRaisesRegex(ValueError, "testability"):
            contracts.validate_settings(settings, ROOT)
        with self.assertRaisesRegex(ValueError, "actual app"):
            contracts.validate_settings(self.settings()[:2], ROOT)

    def test_shared_source_and_plan_membership(self):
        contracts.validate_membership(ROOT)

    def test_settings_probe_preserves_resolved_packages_when_a_newer_version_is_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resolved = root / "Package.resolved"
            resolved.write_text('{"version": "0.8.0"}')

            def resolver(command, **_):
                if not {"-onlyUsePackageVersionsFromResolvedFile", "-disableAutomaticPackageResolution"}.intersection(command):
                    resolved.write_text('{"version": "0.9.0"}')
                return subprocess.CompletedProcess(command, 0, json.dumps(self.settings()), "")

            with mock.patch.object(contracts.session, "ROOT", root), \
                 mock.patch.object(contracts.verification, "resolve_developer_dir", return_value=root), \
                 mock.patch.object(contracts, "validate_membership"), \
                 mock.patch.object(contracts.session, "cache_paths", return_value={"derivedData": "products", "sourcePackages": "packages"}), \
                 mock.patch.object(contracts.subprocess, "run", side_effect=resolver):
                self.assertEqual(contracts.main(), 0)
            self.assertEqual(json.loads(resolved.read_text())["version"], "0.8.0")

    @unittest.skipUnless(shutil.which("xcrun"), "Local Xcode compiler required")
    def test_debug_release_compiled_consumers_reject_import_and_visibility_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            library = root / "Library.swift"
            library.write_text("public func visible() {}\nfunc hidden() {}\n")
            consumer = root / "Consumer.swift"
            for configuration, optimization in (("Debug", "-Onone"), ("Release", "-O")):
                command = ["xcrun", "swiftc", optimization, "-module-name", "GitXBoundaryProbe", "-emit-module",
                           "-emit-module-path", str(root / "GitXBoundaryProbe.swiftmodule"), str(library)]
                subprocess.run(command, check=True, capture_output=True)
                consumer.write_text("import GitXBoundaryProbe\nvisible()\n")
                compile_consumer = ["xcrun", "swiftc", optimization, "-typecheck", "-I", str(root), str(consumer)]
                self.assertEqual(subprocess.run(compile_consumer, capture_output=True).returncode, 0, configuration)
                consumer.write_text("import GitXMissingImportProbe\n")
                self.assertNotEqual(subprocess.run(compile_consumer, capture_output=True).returncode, 0, configuration)
                consumer.write_text("@testable import GitXBoundaryProbe\nhidden()\n")
                self.assertNotEqual(subprocess.run(compile_consumer, capture_output=True).returncode, 0, configuration)
                subprocess.run(command + ["-enable-testing"], check=True, capture_output=True)
                self.assertEqual(subprocess.run(compile_consumer, capture_output=True).returncode, 0, configuration)
