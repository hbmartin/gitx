import unittest
import json
import pathlib
import shutil
import subprocess
import tempfile
import sys
from unittest import mock
from support import ROOT
import check_test_build_contracts as contracts


class TestBuildContractTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'Local Swift runtime required')
    def test_repository_lifetime_token_main_queue_release_is_valid(self):
        self.lifetime_token_probe(release_on_worker=False)

    def lifetime_token_probe(self, *, release_on_worker):
        source = (ROOT / 'Classes/git/IndexCommitCoordinator.swift').read_text()
        prefix = source.split('// swift6-safety-justification: Immutable service ownership', 1)[0]
        program = r'''
typealias IndexCommitEvent = Int
final nonisolated class PBGitRepository: NSObject {
    let released: @Sendable () -> Void
    init(released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { precondition(Thread.isMainThread, "Repository released off main"); released() }
}
func schedule(_ released: @escaping @Sendable () -> Void) {
    let token = RepositoryLifetimeToken(PBGitRepository(released: released))
    if __WORKER__ {
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [token] in
            DispatchQueue.main.async { delivered.signal() }
            precondition(delivered.wait(timeout: .now() + 5) == .success)
            withExtendedLifetime(token) {}
        }
    } else {
        DispatchQueue.main.async { [token] in withExtendedLifetime(token) {} }
    }
}
var context = CFRunLoopSourceContext()
context.perform = { _ in }
let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
CFRunLoopAddSource(CFRunLoopGetMain(), keepAlive, .defaultMode)
let released = DispatchSemaphore(value: 0)
schedule { [released] in released.signal(); CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRunInMode(.defaultMode, 5, false)
precondition(released.wait(timeout: .now()) == .success, "Repository ownership did not drain")
CFRunLoopRemoveSource(CFRunLoopGetMain(), keepAlive, .defaultMode)
print("repository-released-on-main")
'''.replace('__WORKER__', 'true' if release_on_worker else 'false')
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            main = root / 'main.swift'
            main.write_text('import CoreFoundation\n' + prefix + program)
            executable = root / 'lifetime-probe'
            for configuration, optimization in (('Debug', '-Onone'), ('Release', '-O')):
                with self.subTest(configuration=configuration):
                    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', optimization,
                                            str(main), '-o', str(executable)], capture_output=True, text=True, timeout=30)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    completed = subprocess.run([executable], capture_output=True, text=True, timeout=10)
                    self.assertEqual(completed.returncode, 0, completed.stderr[-4096:])
                    self.assertEqual(completed.stdout.strip(), 'repository-released-on-main')

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
