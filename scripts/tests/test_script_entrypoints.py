from __future__ import annotations

import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

from support import ROOT


class ScriptEntrypointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = pathlib.Path(self.temporary_directory.name).resolve()
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # These entrypoint tests model their own desktop. A fixture named GitX
        # from a concurrent suite must not become a competing real application.
        pgrep = self.bin / "pgrep"
        pgrep.write_text(
            '#!/bin/bash\n'
            'if [[ "$*" == "-x GitX" ]]; then\n'
            '  [[ -n "${GITX_TEST_COMPETING_PIDS:-}" ]] || exit 1\n'
            '  printf "%s\\n" "$GITX_TEST_COMPETING_PIDS"\n'
            '  exit 0\n'
            'fi\n'
            'exec /usr/bin/pgrep "$@"\n'
        )
        pgrep.chmod(0o755)
        self.developer_directory = self.root / "Xcode.app" / "Contents" / "Developer"
        self.developer_directory.mkdir(parents=True)
        workspace_data = self.root / "GitX.xcworkspace" / "xcshareddata" / "swiftpm"
        workspace_data.mkdir(parents=True)
        (workspace_data / "Package.resolved").write_text("{}\n")
        test_directory = self.root / "GitXTests"
        test_directory.mkdir()
        for plan in (
            "GitX",
            "GitXHostPreflight",
            "GitXUIPreflight",
            "GitXUI",
            "GitXAddressUndefined",
            "GitXThreadSanitizer",
            "GitXPerformance",
        ):
            (test_directory / f"{plan}.xctestplan").write_text("{}\n")
        self.environment = os.environ.copy()
        self.environment["PATH"] = f"{self.bin}:{self.environment['PATH']}"
        self.environment["GITX_DEVELOPER_DIR"] = str(self.developer_directory)
        # Fixture ownership and fail-fast probes must not inherit a waiting
        # parent coordinator's leases or wait policy.
        for key in ("GITX_RESOURCE_LEASES", "GITX_SESSION_ID", "GITX_GUARDED_ENTRY",
                    "GITX_RESOURCE_WAIT_SECONDS"):
            self.environment.pop(key, None)
        self.environment["GITX_DERIVED_DATA"] = str(self.root / "build/DerivedData")
        self.environment["GITX_SWIFTPM_BUILD_ROOT"] = str(self.root / "build/SwiftPM")
        self.environment["GITX_SOURCE_PACKAGE_CACHE"] = str(self.root / "artifacts/cache/SourcePackages")
        self.fixture_environment = {
            key: value for key, value in self.environment.items() if not key.startswith("GIT_")
        } | {
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false",
            "GIT_CONFIG_KEY_1": "tag.gpgsign", "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "init.templateDir", "GIT_CONFIG_VALUE_2": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "GCM_INTERACTIVE": "never", "LC_ALL": "C",
        }

    def install_script(self, name: str) -> pathlib.Path:
        destination = self.scripts / name
        shutil.copy2(ROOT / "scripts" / name, destination)
        if name == "run_app.sh":
            destination.write_text(destination.read_text().replace("/usr/bin/codesign", "/usr/bin/true")
                                   .replace("/MacOS/GitX", "/MacOS/GitXFixture")
                                   .replace('stop_pid_file "$app_pid_file" GitX', 'stop_pid_file "$app_pid_file" GitXFixture'))
        if name == "observe_app.sh":
            destination.write_text(destination.read_text().replace("GitX | */GitX)", "GitXFixture | */GitXFixture)"))
        shutil.copy2(ROOT / "scripts/workflow_session.py", self.scripts / "workflow_session.py")
        shutil.copy2(ROOT / "scripts/verification-config.json", self.scripts / "verification-config.json")
        # Controlled desktop probe in the copied fixture, never in production.
        session_path = self.scripts / "workflow_session.py"
        session_path.write_text(session_path.read_text().replace("checks = desktop_checks()", "checks = []").replace("def desktop_checks():", "def desktop_checks():\n    return []\n\ndef real_desktop_checks():"))
        session_path.write_text(session_path.read_text().replace('LOCK_ROOT = pathlib.Path.home() / "Library/Caches/GitX/Verification/Locks"', 'LOCK_ROOT = ROOT / "fixture-locks"'))
        if name == "xcodebuild.sh":
            for dependency in ("doctor.sh", "verification_support.py", "verification-config.json", "check_test_build_contracts.py", "compilation_cache.py"):
                shutil.copy2(ROOT / "scripts" / dependency, self.scripts / dependency)
        return destination

    def test_release_test_build_enables_package_testability_only_for_testing(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        for action in ("build", "build-for-testing"):
            subprocess.run(
                [script, "--configuration", "Release", "--run-id", action, "raw", "--", action],
                check=True, capture_output=True, text=True, env=self.environment,
            )
        invocations = captured.read_text().split("__INVOCATION__")
        build = next(value for value in invocations if "\nbuild\n" in value)
        test_build = next(value for value in invocations if "\nbuild-for-testing\n" in value)
        self.assertNotIn("ENABLE_TESTABILITY=YES", build)
        self.assertIn("ENABLE_TESTABILITY=YES", test_build)

    def test_native_startup_and_capture_share_preset_and_raw_supervisor(self) -> None:
        script = self.install_script('xcodebuild.sh')
        # Keep the production wrapper shape and shorten only the copied fixture's
        # backstop so disconnected startup evidence fails promptly.
        script.write_text(script.read_text().replace('7200}\" 120', '7200}\" 2'))
        self.install_mock_xcodebuild(self.root / 'Products')
        mock = self.developer_directory / 'usr/bin/xcodebuild'
        mock.write_text(mock.read_text() + r'''
if [[ " $* " == *" test-without-building "* && " $* " == *" -testPlan GitX "* ]]; then
python3 <<'PYTHON'
import json, os, pathlib
progress = pathlib.Path(os.environ['TEST_RUNNER_GITX_TEST_PROGRESS_DIRECTORY'])
record = {'schemaVersion': 1, 'event': 'bundle-start', 'pid': os.getpid(), 'bundleID': 'net.phere.GitXTests',
          'verificationSession': os.environ['TEST_RUNNER_GITX_VERIFICATION_SESSION'],
          'invocationID': os.environ['TEST_RUNNER_GITX_TEST_INVOCATION_ID']}
(progress / f'startup-{os.getpid()}-a.json').write_text(json.dumps(record))
gate = os.open(os.environ['GITX_TEST_NATIVE_STARTUP_GATE'], os.O_RDONLY)
os.read(gate, 1)
os.close(gate)
import sys
sys.stdout.buffer.write(b'fixture-native-output\n' * 32768)
sys.stdout.buffer.flush()
print('native-startup-fixture-output-complete', flush=True)
PYTHON
fi
''')
        for name, arguments, diagnostic in (
                ('preset', ['test', 'correctness', '-only-testing:GitXTests/ExampleTests'], 'GitX'),
                ('raw', ['raw', '--', 'test', '-testPlan', 'GitX', '-only-testing:GitXTests/ExampleTests'], 'raw-tests')):
            with self.subTest(entrypoint=name):
                run_id = 'inner-native-' + name
                run = self.root / 'artifacts/verification' / run_id
                gate_path = self.root / ('native-startup-gate-' + name)
                os.mkfifo(gate_path)
                environment = dict(self.environment, GITX_TEST_NATIVE_STARTUP_GATE=str(gate_path))
                if name == 'raw':
                    environment['GITX_DERIVED_DATA'] = str(self.root / 'custom native cache/DerivedData')
                manifest = run / 'Diagnostics' / diagnostic / 'diagnostic-owner.json'
                released = False
                with tempfile.TemporaryFile() as transcript:
                    gate = os.open(gate_path, os.O_RDWR | os.O_NONBLOCK)
                    process = None
                    completed = None
                    try:
                        process = subprocess.Popen([script, '--run-id', run_id, *arguments], env=environment,
                                                   stdout=transcript, stderr=subprocess.STDOUT)
                        deadline = time.monotonic() + 20
                        wake = threading.Event()
                        while process.poll() is None and time.monotonic() < deadline:
                            if manifest.exists():
                                state = json.loads(manifest.read_text())
                                if state.get('hostStartup', {}).get('source') == 'xctest-observer' and not released:
                                    os.write(gate, b'1')
                                    released = True
                            wake.wait(.01)
                        completed = process.poll()
                    finally:
                        try:
                            if process is not None:
                                if process.poll() is None:
                                    process.terminate()
                                process.communicate(timeout=10)
                        finally:
                            os.close(gate)
                    transcript.seek(0)
                    output = transcript.read()
                tail = output[-4096:].decode(errors='replace')
                self.assertIsNotNone(completed, 'The canonical wrapper must finish within its backstop: ' + tail)
                self.assertEqual(process.returncode, 0, tail)
                log = run / ('Logs/GitX.log' if name == 'preset' else 'Logs/raw.log')
                canonical = log.read_bytes()
                self.assertEqual(canonical.count(b'fixture-native-output\n'), 32768)
                self.assertIn(b'native-startup-fixture-output-complete', canonical)
                self.assertTrue(released, 'The canonical supervisor must acknowledge native startup before release')
                state = json.loads(manifest.read_text())
                self.assertEqual(state['hostStartup']['source'], 'xctest-observer')
                self.assertIn('outputCapture', state, 'Startup and the authoritative capture share one supervisor')
                self.assertTrue(list((run / 'Logs/Native').glob('*/native-diagnostics.json')))
                self.assertFalse(list((run / 'Logs').glob('*-console.log')))
                receipt = self.receipt(run_id)
                self.assertEqual(receipt['status'], 'passed')
                primary = pathlib.Path(environment['GITX_DERIVED_DATA']).parent / 'Fixtures' / run_id / 'Native'
                fallback = pathlib.Path.home() / 'Library/Caches/GitX/Verification' / hashlib.sha256(str(self.root).encode()).hexdigest()[:16] / 'NativeFallback'
                commands = [step['command'] for step in receipt['steps']
                            if 'build-for-testing' in step['command'] or 'test-without-building' in step['command']]
                self.assertTrue(commands)
                for command in commands:
                    self.assertIn('GITX_TEST_NATIVE_STORAGE_ROOT=' + str(primary), command)
                    self.assertIn('GITX_TEST_NATIVE_FALLBACK_ROOT=' + str(fallback), command)

    def test_native_sandbox_path_overrides_are_rejected_before_owned_output(self):
        script = self.install_script('xcodebuild.sh')
        self.install_mock_xcodebuild(self.root / 'Products')
        for setting in ('GITX_TEST_NATIVE_STORAGE_ROOT', 'GITX_TEST_NATIVE_FALLBACK_ROOT'):
            with self.subTest(setting=setting):
                run_id = 'invalid-native-' + setting.lower()
                result = subprocess.run([script, '--run-id', run_id, 'test', 'correctness', setting + '=/'],
                                        env=self.environment, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('Native diagnostic sandbox paths are managed', result.stderr)
                self.assertFalse((self.root / 'artifacts/verification' / run_id).exists())

    def test_ui_runner_native_write_exceptions_are_scoped_to_test_settings(self):
        key = 'com.apple.security.temporary-exception.files.absolute-path.read-write'
        entitlements = plistlib.loads((ROOT / 'GitXUITests/GitXUITests.entitlements').read_bytes())
        self.assertEqual(entitlements[key], ['/private/tmp/gitx-ui-fixtures/',
                         '$(GITX_TEST_NATIVE_STORAGE_ROOT)/', '$(GITX_TEST_NATIVE_FALLBACK_ROOT)/'])
        production = plistlib.loads((ROOT / 'GitX.entitlements').read_bytes())
        self.assertNotIn(key, production)
        project = (ROOT / 'GitX.xcodeproj/project.pbxproj').read_text()
        for identifier in ('CC00000AA00000A', 'CC00000BA00000B'):
            block = project.split(identifier + ' /*', 1)[1].split('name = ', 1)[0]
            for setting in ('GITX_TEST_NATIVE_STORAGE_ROOT', 'GITX_TEST_NATIVE_FALLBACK_ROOT'):
                self.assertIn(setting + ' = "$(PROJECT_TEMP_DIR)/NativeDiagnostics-Unmanaged";', block)

    def test_xcodebuild_captures_complete_output_before_console_forwarding(self) -> None:
        script = self.install_script('xcodebuild.sh')
        self.install_mock_xcodebuild(self.root / 'Products')
        mock = self.developer_directory / 'usr/bin/xcodebuild'
        mock.write_text(mock.read_text() + '\nif [[ " $* " == *" build "* ]]; then\n'
                        '  printf "raw stdout\\n"\n  printf "raw stderr\\n" >&2\n  exit 9\nfi\n')
        result = subprocess.run([script, '--run-id', 'captured-failure', 'build'],
                                capture_output=True, text=True, env=self.environment, timeout=30)
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        receipt = self.receipt('captured-failure')
        failed = next(step for step in receipt['steps'] if step['exitCode'] == 9)
        log = (self.root / failed['log']).resolve()
        self.assertEqual(log.read_text(), 'raw stdout\nraw stderr\n')
        diagnostic = next((self.root / 'artifacts/verification/captured-failure/Diagnostics').rglob('diagnostic-owner.json'))
        capture = json.loads(diagnostic.read_text())['outputCapture']
        self.assertEqual(capture['path'], str(log))
        self.assertEqual(capture['capturedBytes'], len(b'raw stdout\nraw stderr\n'))

    def test_verification_preserves_resolved_packages_when_a_newer_version_is_available(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        resolved = self.root / "GitX.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        pinned = {"pins": [{"identity": "swift-cmark", "state": {"version": "0.8.0"}}], "version": 3}
        resolved.write_text(json.dumps(pinned))
        (self.root / ".gitignore").write_text("__pycache__/\n")
        subprocess.run(["git", "init", "--quiet", self.root], check=True, env=self.fixture_environment)
        subprocess.run(["git", "-C", self.root, "add", str(resolved)], check=True, env=self.fixture_environment)
        mock = self.developer_directory / "usr/bin/xcodebuild"
        mock.write_text(mock.read_text() +
                        '\nif [[ " $* " != *" -onlyUsePackageVersionsFromResolvedFile "* && '
                        '" $* " != *" -disableAutomaticPackageResolution "* ]]; then\n'
                        '  python3 - "$MOCK_RESOLVED_FILE" <<\'PY\'\n'
                        'import json, pathlib, sys\n'
                        'path = pathlib.Path(sys.argv[1])\n'
                        'data = json.loads(path.read_text())\n'
                        'data["pins"][0]["state"]["version"] = "0.9.0"\n'
                        'path.write_text(json.dumps(data))\n'
                        'PY\nfi\n')
        self.environment["MOCK_RESOLVED_FILE"] = str(resolved)
        for name, arguments in (("build", ["build"]), ("ui", ["test", "ui"]),
                                ("raw-ui", ["raw", "--", "test", "-testPlan", "GitXUI"])):
            with self.subTest(action=name):
                resolved.write_text(json.dumps(pinned))
                result = subprocess.run([script, "--run-id", f"pinned-{name}", *arguments],
                                        capture_output=True, text=True, env=self.environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(resolved.read_text()), pinned)
                self.assertEqual(self.receipt(f"pinned-{name}")["evidence"]["status"], "valid")

    def test_verification_still_rejects_dependency_drift_after_a_successful_build(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        resolved = self.root / "GitX.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        (self.root / ".gitignore").write_text("__pycache__/\n")
        subprocess.run(["git", "init", "--quiet", self.root], check=True, env=self.fixture_environment)
        subprocess.run(["git", "-C", self.root, "add", str(resolved)], check=True, env=self.fixture_environment)
        mock = self.developer_directory / "usr/bin/xcodebuild"
        mock.write_text(mock.read_text() + '\nif [[ " $* " == *" build "* ]]; then\n'
                        '  printf \'{"pins": [{"identity": "swift-cmark", "state": {"version": "0.9.0"}}]}\\n\' > "$MOCK_RESOLVED_FILE"\n'
                        'fi\n')
        self.environment["MOCK_RESOLVED_FILE"] = str(resolved)
        result = subprocess.run([script, "--run-id", "unexpected-dependency-drift", "build"],
                                capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 76, result.stdout + result.stderr)
        coordination = self.root / "artifacts/verification/Coordination/unexpected-dependency-drift.json"
        evidence = json.loads(coordination.read_text())["evidence"]
        self.assertEqual(evidence["status"], "invalid")
        self.assertIn("source", evidence["changedInputs"])

    def test_compilation_cache_mode_is_managed_and_recorded(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        for mode in ("auto", "on", "off"):
            subprocess.run([script, "--compilation-cache", mode, "--run-id", mode, "build"],
                           check=True, capture_output=True, text=True, env=self.environment)
            invocation = captured.read_text().split("__INVOCATION__")[-1]
            enabled = mode == "on"
            self.assertIn("COMPILATION_CACHE_ENABLE_CACHING=" + ("YES" if enabled else "NO"), invocation)
            policy = self.receipt(mode)["invocation"]["compilationCache"]
            self.assertEqual(policy["requested"], mode)
            self.assertEqual(policy["enabled"], enabled)
        rejected = subprocess.run([script, "build", "COMPILATION_CACHE_ENABLE_CACHING=YES"],
                                  capture_output=True, text=True, env=self.environment)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("Use --compilation-cache", rejected.stderr)

    def test_analyzer_profiling_preserves_full_analysis_and_is_partial_evidence(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "check_analyzer_diagnostics.py").write_text("#!/usr/bin/env python3\n")
        calls = self.root / "lint-calls.txt"
        tool = self.scripts / "run_pinned_tool.sh"
        tool.write_text(f"#!/bin/bash\nprintf '%s\\n' \"$PWD|$*\" >>'{calls}'\n"
                        'if [[ " $* " == *" --benchmark "* ]]; then\n'
                        '  for kind in files rules; do printf report >"benchmark_${kind}_2026_10_11_00_00_00.txt"; done\n'
                        'fi\n')
        tool.chmod(0o755)
        subprocess.run([script, "--profile-rules", "--run-id", "profile", "analyze"],
                       check=True, capture_output=True, text=True, env=self.environment)
        invocations = calls.read_text().splitlines()
        self.assertEqual(len(invocations), 3)
        self.assertNotIn("--only-rule", invocations[0])
        self.assertIn("--only-rule unused_declaration --benchmark", invocations[1])
        self.assertIn("--only-rule unused_import --benchmark", invocations[2])
        for invocation in invocations:
            self.assertTrue(invocation.startswith(str(self.root) + "|"))
            self.assertNotIn("--working-directory", invocation)
        for rule in ("unused_declaration", "unused_import"):
            output = self.root / "artifacts/verification/profile/Results/Profiling" / rule
            self.assertEqual(len(list(output.glob("benchmark_*.txt"))), 2)
        self.assertFalse(list(self.root.glob("benchmark_*.txt")))
        receipt = self.receipt("profile")
        self.assertTrue(receipt["invocation"]["analysisProfiling"])
        self.assertFalse(receipt["deliveryEligible"])

    def test_cache_policy_failure_allocates_no_analyzer_output(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "compilation_cache.py").write_text('import sys\nsys.exit(2)\n')
        result = subprocess.run([script, "--run-id", "rejected-policy", "analyze"],
                                capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.root / "artifacts/verification/rejected-policy").exists())
        self.assertFalse(list((self.root / "build").glob("AnalyzerDerivedData.*")))

    def test_analyzer_resume_requires_products_and_reruns_semantic_checks(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "check_analyzer_diagnostics.py").write_text("#!/usr/bin/env python3\n")
        tool = self.scripts / "run_pinned_tool.sh"
        # Keep this input stable across the failed and resumed runs.
        tool.write_text('#!/bin/bash\nexit "${GITX_TEST_LINT_STATUS:-0}"\n')
        tool.chmod(0o755)
        failed = subprocess.run([script, "--run-id", "prior", "analyze"], capture_output=True,
                                text=True, env=self.environment | {"GITX_TEST_LINT_STATUS": "9"})
        self.assertEqual(failed.returncode, 9, failed.stderr)
        prior = self.receipt("prior")
        scratch = pathlib.Path(prior["evidence"]["analyzerScratch"]["path"])
        self.assertTrue(scratch.is_dir())
        subprocess.run([script, "--resume-analysis", "prior", "--run-id", "resumed", "analyze"],
                       check=True, capture_output=True, text=True, env=self.environment)
        receipt = self.receipt("resumed")
        self.assertEqual([step["name"] for step in receipt["steps"]],
                         ["doctor", "analyze", "analyzer-policy", "swiftlint-analyze"])
        self.assertEqual(receipt["steps"][1]["executionReason"], "matching-compiler-evidence")
        native = [call for call in captured.read_text().split("__INVOCATION__") if "\nanalyze\n" in call]
        self.assertEqual(len(native), 1)
        shutil.rmtree(scratch)
        stale = subprocess.run([script, "--resume-analysis", "prior", "--run-id", "stale", "analyze"],
                               capture_output=True, text=True, env=self.environment)
        self.assertEqual(stale.returncode, 2)
        self.assertIn("compiler products are missing or changed", stale.stderr)

    def test_optional_analyzer_recovery_runs_fresh_when_strong_evidence_is_stale(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "check_analyzer_diagnostics.py").write_text("#!/usr/bin/env python3\n")
        tool = self.scripts / "run_pinned_tool.sh"
        tool.write_text('#!/bin/bash\nexit "${GITX_TEST_LINT_STATUS:-0}"\n')
        tool.chmod(0o755)
        for kind in ("toolchain", "invocation", "scratch", "diagnostics", "missing-log", "malformed-log"):
            with self.subTest(kind=kind):
                prior_id = "prior-" + kind
                failed = subprocess.run([script, "--run-id", prior_id, "analyze"], capture_output=True,
                                        text=True, env=self.environment | {"GITX_TEST_LINT_STATUS": "9"})
                self.assertEqual(failed.returncode, 9, failed.stderr)
                prior_path = self.root / "artifacts/verification" / prior_id / "receipt.json"
                prior = json.loads(prior_path.read_text())
                if kind == "toolchain":
                    prior["toolchain"]["xcodeBuild"] = "old-build"
                elif kind == "invocation":
                    prior["invocation"]["scheme"] = "old-scheme"
                elif kind == "scratch":
                    shutil.rmtree(prior["evidence"]["analyzerScratch"]["path"])
                elif kind == "missing-log":
                    next(step for step in prior["steps"] if step["name"] == "analyze").pop("log")
                elif kind == "malformed-log":
                    next(step for step in prior["steps"] if step["name"] == "analyze")["log"] = None
                else:
                    log = next(step["log"] for step in prior["steps"] if step["name"] == "analyze")
                    (self.root / log).write_text("changed diagnostics")
                prior_path.write_text(json.dumps(prior))
                if kind in ("missing-log", "malformed-log"):
                    strict = subprocess.run([script, "--resume-analysis", prior_id,
                                             "--run-id", "strict-" + kind, "analyze"],
                                            capture_output=True, text=True, env=self.environment)
                    self.assertEqual(strict.returncode, 2, strict.stderr)
                    self.assertIn("analysis log is missing or malformed", strict.stderr)
                    self.assertNotIn("Running fresh analysis", strict.stderr)
                resumed = subprocess.run([script, "--resume-analysis", prior_id, "--fresh-on-stale-analysis",
                                          "--run-id", "fresh-" + kind, "analyze"], capture_output=True,
                                         text=True, env=self.environment)
                self.assertEqual(resumed.returncode, 0, resumed.stderr)
                receipt = self.receipt("fresh-" + kind)
                self.assertEqual(receipt["analyzerRecovery"]["status"], "rejected")
                self.assertEqual([step["name"] for step in receipt["steps"]],
                                 ["doctor", "analyze", "analyzer-policy", "swiftlint-analyze"])
                self.assertNotIn("reusedFrom", receipt["steps"][1])
                self.assertEqual(receipt["status"], "passed")
        native = [call for call in captured.read_text().split("__INVOCATION__") if "\nanalyze\n" in call]
        self.assertEqual(len(native), 12, "each rejected recovery must perform fresh compiler analysis")
        failed_fresh = subprocess.run([script, "analyze", "--resume-analysis", "prior-diagnostics",
                                       "--fresh-on-stale-analysis", "--run-id", "fresh-failure"],
                                      capture_output=True, text=True,
                                      env=self.environment | {"GITX_TEST_LINT_STATUS": "9"})
        self.assertEqual(failed_fresh.returncode, 9, failed_fresh.stderr)
        failed_receipt = self.receipt("fresh-failure")
        self.assertEqual(failed_receipt["status"], "failed")
        self.assertEqual(failed_receipt["steps"][-1]["name"], "swiftlint-analyze")
        self.assertFalse(failed_receipt["deliveryEligible"])

    def test_workflow_resume_falls_back_to_fresh_after_toolchain_recovery_rejection(self) -> None:
        self.install_script("xcodebuild.sh")
        coordinator = self.install_script("dev_workflow.py")
        for dependency in ("workflow_records.py", "workflow_cleanup.py", "workflow_feedback.py"):
            shutil.copy2(ROOT / "scripts" / dependency, self.scripts / dependency)
        captured = self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "check_analyzer_diagnostics.py").write_text("#!/usr/bin/env python3\n")
        tool = self.scripts / "run_pinned_tool.sh"
        tool.write_text('#!/bin/bash\nexit "${GITX_TEST_LINT_STATUS:-0}"\n')
        tool.chmod(0o755)
        command = ["python3", str(coordinator), "verify", "--check", "analyze"]
        failed = subprocess.run(command + ["--run-id", "coordinator"], capture_output=True,
                                text=True, env=self.environment | {"GITX_TEST_LINT_STATUS": "9"})
        self.assertEqual(failed.returncode, 9, failed.stderr)
        workflow_path = self.root / "artifacts/verification/coordinator/workflow.json"
        prior_workflow = json.loads(workflow_path.read_text())
        child_path = pathlib.Path(prior_workflow["steps"][0]["receipt"])
        child = json.loads(child_path.read_text())
        child["toolchain"]["xcodeBuild"] = "old-build"
        child_path.write_text(json.dumps(child))
        resumed = subprocess.run(command + ["--resume", "coordinator"], capture_output=True,
                                 text=True, env=self.environment)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        workflow = json.loads(workflow_path.read_text())
        receipt = json.loads(pathlib.Path(workflow["steps"][0]["receipt"]).read_text())
        self.assertEqual(receipt["analyzerRecovery"]["status"], "rejected")
        self.assertIn("toolchain", receipt["analyzerRecovery"]["reason"])
        self.assertEqual(workflow["status"], "passed")
        self.assertEqual(workflow["executedChecks"], ["analyze"])
        self.assertFalse(workflow["deliveryEligible"])
        self.assertNotIn("reusedFrom", next(step for step in receipt["steps"] if step["name"] == "analyze"))
        native = [call for call in captured.read_text().split("__INVOCATION__") if "\nanalyze\n" in call]
        self.assertEqual(len(native), 2)

    def test_canonical_release_tests_allow_locally_signed_framework_loading(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        for command in (["build-tests"], ["test", "correctness", "-only-testing:GitXTests/GitXInteropContractTests"]):
            subprocess.run([script, "--configuration", "Release", *command], check=True,
                           capture_output=True, text=True, env=self.environment)
        tests = [value for value in captured.read_text().split("__INVOCATION__")
                 if "\nbuild-for-testing\n" in value or "\ntest-without-building\n" in value]
        self.assertTrue(tests)
        for invocation in tests:
            self.assertIn("ENABLE_HARDENED_RUNTIME=NO", invocation)
            self.assertIn("CODE_SIGN_IDENTITY=-", invocation)
            self.assertIn("GITX_TEST_NATIVE_STORAGE_ROOT=", invocation)
            self.assertIn("GITX_TEST_NATIVE_FALLBACK_ROOT=", invocation)
        captured.write_text("")
        subprocess.run([script, "--configuration", "Release", "build"], check=True,
                       capture_output=True, text=True, env=self.environment)
        self.assertNotIn("ENABLE_HARDENED_RUNTIME=NO", captured.read_text())
        self.assertNotIn("GITX_TEST_NATIVE_STORAGE_ROOT=", captured.read_text())
        self.assertNotIn("GITX_TEST_NATIVE_FALLBACK_ROOT=", captured.read_text())

    def install_mock_xcodebuild(
        self,
        products_directory: pathlib.Path,
        *,
        version: str = "26.6",
    ) -> pathlib.Path:
        captured_arguments = self.root / "xcodebuild.args"
        mock_directory = self.developer_directory / "usr" / "bin"
        mock_directory.mkdir(parents=True, exist_ok=True)
        mock = mock_directory / "xcodebuild"
        mock.write_text(
            "#!/bin/bash\n"
            "if [[ \"${1:-}\" == '-version' ]]; then\n"
            f"  printf 'Xcode {version}\\nBuild version Test\\n'\n"
            "  exit 0\n"
            "fi\n"
            "printf '__INVOCATION__\\n' >>\"$CAPTURED_ARGUMENTS\"\n"
            "printf '%s\\n' \"$@\" >>\"$CAPTURED_ARGUMENTS\"\n"
            "arguments=(\"$@\")\n"
            "for option in -enableCodeCoverage -enableAddressSanitizer -enableUndefinedBehaviorSanitizer -enableThreadSanitizer; do\n"
            "  count=0\n"
            "  for argument in \"${arguments[@]}\"; do [[ \"$argument\" == \"$option\" || \"$argument\" == \"$option=\"* ]] && count=$((count + 1)); done\n"
            "  if (( count > 1 )); then echo \"duplicate singleton option: $option\" >&2; exit 64; fi\n"
            "done\n"
            "derived=''\n"
            "for ((index = 0; index < ${#arguments[@]}; index++)); do\n"
            "  if [[ \"${arguments[$index]}\" == '-derivedDataPath' ]]; then\n"
            "    derived=${arguments[$((index + 1))]}\n"
            "    if [[ \" $* \" == *' build '* || \" $* \" == *' build-for-testing '* ]]; then\n"
            "    app=\"$derived/Build/Products/Debug/Half Dark.app\"\n"
            "    mkdir -p \"$app/Contents/MacOS\" \"$app/Contents/Resources\"\n"
            "    printf '#!/bin/bash\\n' >\"$app/Contents/MacOS/GitX\"\n"
            "    chmod +x \"$app/Contents/MacOS/GitX\"\n"
            "    printf 'staged\\n' >\"$app/Contents/Resources/fixture.txt\"\n"
            "    /usr/bin/plutil -create xml1 \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/plutil -insert CFBundleExecutable -string GitX \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/plutil -insert CFBundleIdentifier -string com.gitx.test \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/codesign --force --sign - \"$app\" >/dev/null 2>&1\n"
            "    fi\n"
            "  fi\n"
            "  case \"${arguments[$index]}\" in\n"
            "    -resultBundlePath) mkdir -p \"${arguments[$((index + 1))]}\" ;;\n"
            "    CLANG_ANALYZER_OUTPUT_DIR=*)\n"
            "      analyzer_output=${arguments[$index]#*=}\n"
            "      mkdir -p \"$analyzer_output/StaticAnalyzer/GitX/GitX/normal/arm64\"\n"
            "      printf 'analyzer report\\n' >\"$analyzer_output/StaticAnalyzer/GitX/GitX/normal/arm64/report.plist\"\n"
            "      ;;\n"
            "  esac\n"
            "done\n"
            "if [[ \" $* \" == *' -showBuildSettings '* ]]; then\n"
            "  printf '    BUILT_PRODUCTS_DIR = %s/Build/Products/Debug\\n' \"$derived\"\n"
            "fi\n"
            "if [[ \" $* \" == *' -showdestinations '* ]]; then\n"
            "  printf '{ platform: macOS, arch: arm64 }\\n'\n"
            "  printf '{ platform: macOS, arch: x86_64 }\\n'\n"
            "fi\n"
            "if [[ \"${MOCK_XCODEBUILD_EXIT_STATUS:-0}\" != 0 && \" $* \" == *' analyze '* ]]; then\n"
            "  exit \"$MOCK_XCODEBUILD_EXIT_STATUS\"\n"
            "fi\n"
        )
        mock.write_text(mock.read_text() + r'''
if [[ " $* " == *" test-without-building "* ]]; then
python3 - "$@" <<'PYTHON'
import json, os, pathlib, sys
arguments = sys.argv[1:]
plan = arguments[arguments.index('-testPlan') + 1] if '-testPlan' in arguments else 'GitX'
if not (os.environ.get('GITX_TEST_NATIVE_STARTUP_GATE') and plan == 'GitX'):
    progress = pathlib.Path(os.environ['TEST_RUNNER_GITX_TEST_PROGRESS_DIRECTORY'])
    record = {'schemaVersion': 1, 'event': 'bundle-start', 'pid': os.getpid(),
              'bundleID': 'net.phere.GitXUITests' if plan in ('GitXUI', 'GitXUIPreflight') else 'net.phere.GitXTests',
              'verificationSession': os.environ['TEST_RUNNER_GITX_VERIFICATION_SESSION'],
              'invocationID': os.environ['TEST_RUNNER_GITX_TEST_INVOCATION_ID']}
    (progress / f'startup-{os.getpid()}-a.json').write_text(json.dumps(record))
PYTHON
fi
''')
        mock.chmod(0o755)
        xcrun = self.bin / "xcrun"
        if not xcrun.exists():
            xcrun.write_text('#!/bin/bash\nif [[ "$1" == "xcresulttool" ]]; then printf \'{"totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0}\\n\'; else exec /usr/bin/xcrun "$@"; fi\n')
            xcrun.chmod(0o755)
        self.environment["CAPTURED_ARGUMENTS"] = str(captured_arguments)
        self.environment["PRODUCTS_DIRECTORY"] = str(products_directory)
        return captured_arguments

    def receipt(self, run_id: str) -> dict[str, object]:
        path = self.root / "artifacts" / "verification" / run_id / "receipt.json"
        return json.loads(path.read_text())

    def install_mock_ditto(self, exit_status: int) -> None:
        mock = self.bin / "ditto"
        mock.write_text(f"#!/bin/bash\nexit {exit_status}\n")
        mock.chmod(0o755)

    def install_mock_peekaboo(self) -> pathlib.Path:
        mock = self.bin / "peekaboo"
        mock.write_text(
            "#!/bin/bash\n"
            "case \"${1:-} ${2:-}\" in\n"
            "  'list windows')\n"
            "    if [[ -n \"${GITX_TEST_READY_FILE:-}\" && ! -s \"$GITX_TEST_READY_FILE\" ]]; then printf '%s\\n' '{\"success\":true,\"data\":{\"windows\":[]}}'; exit 0; fi\n"
            "    printf '%s\\n' '{\"success\":true,\"data\":{\"windows\":[{\"windowID\":7,\"index\":1,\"title\":\"Welcome\",\"isMainWindow\":false},{\"windowID\":42,\"index\":0,\"title\":\"fixture-repo (branch: main)\",\"isMainWindow\":true}]}}'\n"
            "    ;;\n"
            "  'image --pid')\n"
            "    for ((index = 1; index <= $#; index++)); do\n"
            "      if [[ \"${!index}\" == '--path' ]]; then next=$((index + 1)); output=${!next}; fi\n"
            "    done\n"
            "    [[ \"${PEEKABOO_IMAGE_FAIL:-0}\" == 1 ]] && exit 9\n"
            "    printf 'png' >\"$output\"\n"
            "    ;;\n"
            "  'see --pid')\n"
            "    for ((index = 1; index <= $#; index++)); do\n"
            "      if [[ \"${!index}\" == '--path' ]]; then next=$((index + 1)); output=${!next}; fi\n"
            "    done\n"
            "    printf 'png' >\"$output\"\n"
            "    printf '%s\\n' '{\"success\":true,\"data\":{\"elements\":[{\"role\":\"button\",\"label\":\"Commit\"}]}}'\n"
            "    ;;\n"
            "  'inspect-ui --app-target')\n"
            "    printf '%s\\n' '{\"success\":true,\"data\":{\"role\":\"window\",\"children\":[{\"role\":\"button\",\"label\":\"Commit\"},{\"role\":\"button\",\"label\":\"Push\"}]}}'\n"
            "    ;;\n"
            "  *) exit 64 ;;\n"
            "esac\n"
        )
        mock.chmod(0o755)
        return mock

    def create_live_run_app_session(self) -> tuple[subprocess.Popen[bytes], pathlib.Path]:
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        repository = self.root / "fixture-repo"
        repository.mkdir()
        executable = self.root / "GitXFixture"
        executable.symlink_to("/bin/sleep")
        process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, process)
        start_time = subprocess.run(
            ["ps", "-p", str(process.pid), "-o", "lstart="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        (session_directory / "app.pid").write_text(f"{process.pid}\t{start_time}\n")
        os_log = session_directory / "gitx-oslog.txt"
        stdout = session_directory / "gitx-stdout.txt"
        os_log.write_text("runtime error marker\n")
        stdout.write_text("standard output marker\n")
        (session_directory / "session.txt").write_text(
            f"app_pid={process.pid}\n"
            f"repository={repository}\n"
            f"os_log={os_log}\n"
            f"stdout={stdout}\n"
        )
        return process, session_directory

    def install_sleeping_executable(self, path: pathlib.Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/clang", "-x", "c", "-o", str(path), "-"],
            input=(
                "#include <stdio.h>\n"
                "#include <stdlib.h>\n"
                "#include <string.h>\n"
                "#include <unistd.h>\n"
                "int main(int argc, char **argv) {\n"
                "  (void)argc;\n"
                "  const char *pid_file = getenv(strstr(argv[0], \"GitX\") ? \"GITX_TEST_APP_PID_FILE\" : \"GITX_TEST_PROCESS_PID_FILE\");\n"
                "  if (pid_file) {\n"
                "    FILE *file = fopen(pid_file, \"w\");\n"
                "    if (file) { fprintf(file, \"%d\\n\", getpid()); fclose(file); }\n"
                "  }\n"
                "  sleep(60);\n"
                "  return 0;\n"
                "}\n"
            ),
            text=True,
            check=True,
            capture_output=True,
        )

    def start_pending_run_app_launch(self) -> tuple[subprocess.Popen[bytes], pathlib.Path, pathlib.Path]:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True, env=self.fixture_environment)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        self.install_sleeping_executable(app_contents / "MacOS" / "GitXFixture")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        self.install_sleeping_executable(self.bin / "log")
        peekaboo = self.bin / "peekaboo"
        peekaboo.write_text("#!/bin/bash\nexit 1\n")
        peekaboo.chmod(0o755)
        session_directory = self.root / "build" / "Logs" / "run-app"
        process = subprocess.Popen(
            [script, "--no-build", "--repo", str(repository), "--timeout", "30"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if (session_directory / "app.pid").exists() and (session_directory / "logstream.pid").exists():
                app_record = (session_directory / "app.pid").read_text().strip().split("\t")
                log_record = (session_directory / "logstream.pid").read_text().strip().split("\t")
                session = session_directory / "session.txt"
                if len(app_record) == len(log_record) == 2 and session.exists():
                    facts = dict(line.split("=", 1) for line in session.read_text().splitlines() if "=" in line)
                    if facts.get("app_pid") == app_record[0] and facts.get("log_pid") == log_record[0] and facts.get("isolated_home"):
                        return process, session_directory, temporary_root
            time.sleep(0.02)
        process.kill()
        output, errors = process.communicate(timeout=2)
        self.fail("run_app.sh did not start both test processes: " + (output + errors).decode(errors="replace"))

    @staticmethod
    def process_is_running(pid: int) -> bool:
        status = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True
        ).stdout.strip()
        return bool(status) and "Z" not in status

    @staticmethod
    def terminate_pid(pid: int) -> None:
        # These are fixture-owned PIDs. Wait for observable exit, escalating
        # only while the same process still owns the PID.
        birth = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                               capture_output=True, text=True).stdout.strip()
        if not birth:
            return
        for termination_signal in (signal.SIGTERM, signal.SIGKILL):
            current = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                     capture_output=True, text=True).stdout.strip()
            if current != birth or not ScriptEntrypointTests.process_is_running(pid):
                return
            try:
                os.kill(pid, termination_signal)
            except ProcessLookupError:
                return
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if not ScriptEntrypointTests.process_is_running(pid):
                    return
                current = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                         capture_output=True, text=True).stdout.strip()
                if current != birth:
                    return
                time.sleep(0.02)
        raise AssertionError(f"Fixture process {pid} did not terminate")

    @staticmethod
    def terminate_pid_file(path: pathlib.Path) -> None:
        try:
            pid = int(path.read_text().strip())
        except (FileNotFoundError, ValueError):
            return
        ScriptEntrypointTests.terminate_pid(pid)

    def test_owned_process_cleanup_waits_and_escalates_when_term_is_ignored(self) -> None:
        ready = self.root / "ignoring-term-ready"
        code = ("import pathlib, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"pathlib.Path({str(ready)!r}).write_text('ready'); time.sleep(30)")
        process = subprocess.Popen([sys.executable, "-c", code])
        self.addCleanup(process.wait, timeout=5)
        self.addCleanup(self.terminate_pid, process.pid)
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(ready.exists(), "The owned process must install its TERM handler")
        started = time.monotonic()
        self.terminate_pid(process.pid)
        self.assertFalse(self.process_is_running(process.pid))
        self.assertEqual(process.wait(timeout=1), -signal.SIGKILL)
        self.assertLess(time.monotonic() - started, 5)

    def test_xcodebuild_wrapper_injects_the_documented_defaults(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [script, "--raw", "build"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        build_invocations = [
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "-showdestinations" not in invocation
        ]
        arguments = "\n".join(build_invocations).splitlines()
        self.assertIn("-workspace", arguments)
        self.assertIn("GitX.xcworkspace", arguments)
        self.assertIn("-scheme", arguments)
        self.assertIn("GitX", arguments)
        self.assertIn("-destination", arguments)
        self.assertIn("platform=macOS,arch=arm64", arguments)
        self.assertIn("-derivedDataPath", arguments)
        self.assertIn("build", arguments)
        self.assertEqual(arguments[-1], "CODE_SIGN_IDENTITY=-")

    def test_xcodebuild_wrapper_stages_the_built_application(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [script, "--raw", "--stage-app", "build"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        fixture = self.root / "build" / "GitX.app" / "Contents" / "Resources" / "fixture.txt"
        self.assertEqual(fixture.read_text(), "staged\n")

    def test_xcodebuild_wrapper_rejects_an_xcode_older_than_ci(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products", version="26.5")

        result = subprocess.run(
            [script, "--raw", "--developer-dir", str(self.developer_directory), "build"],
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("26.6", result.stdout + result.stderr)

    def test_xcodebuild_receipt_records_selected_developer_directory_for_doctor(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [
                script,
                "--raw",
                "--run-id",
                "doctor-toolchain-receipt",
                "--developer-dir",
                str(self.developer_directory),
                "build",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        doctor_step = next(
            step
            for step in self.receipt("doctor-toolchain-receipt")["steps"]
            if step["name"] == "doctor"
        )
        command = doctor_step["command"]
        self.assertEqual(
            command[command.index("--developer-dir") + 1],
            str(self.developer_directory),
        )

    def test_explicit_xcode_bundle_path_is_normalized_case_insensitively(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        bundle = self.root / "Pinned-Xcode.APP"
        developer_directory = bundle / "Contents" / "Developer"
        (developer_directory / "usr" / "bin").mkdir(parents=True)
        shutil.copy2(
            self.developer_directory / "usr" / "bin" / "xcodebuild",
            developer_directory / "usr" / "bin" / "xcodebuild",
        )

        subprocess.run(
            [
                script,
                "--raw",
                "--run-id",
                "mixed-case-bundle",
                "--developer-dir",
                str(bundle),
                "build",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        receipt = self.receipt("mixed-case-bundle")
        self.assertEqual(receipt["toolchain"]["developerDir"], str(developer_directory))

    def test_invalid_explicit_xcode_pin_does_not_fall_back_to_environment(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        result = subprocess.run(
            [
                script,
                "--raw",
                "--run-id",
                "invalid-explicit-toolchain",
                "--developer-dir",
                str(self.root / "Missing-Xcode.app"),
                "build",
            ],
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertEqual(result.returncode, 2)
        receipt = json.loads((self.root / "artifacts/verification/Coordination/invalid-explicit-toolchain.json").read_text())
        self.assertEqual(receipt["status"], "blocked")
        self.assertEqual(receipt["category"], "resource-definition-unavailable")
        self.assertIn(str(self.root / "Missing-Xcode.app"), receipt["problem"])
        self.assertFalse((self.root / "artifacts/verification/invalid-explicit-toolchain").exists())

    def test_xcodebuild_wrapper_matches_options_as_exact_arguments(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [script, "--raw", "build", "CUSTOM_TEXT=before -scheme after"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        raw_invocation = next(
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "-showdestinations" not in invocation
        )
        arguments = raw_invocation.splitlines()
        self.assertIn("-scheme", arguments)
        self.assertIn("CUSTOM_TEXT=before -scheme after", arguments)

    def test_xcodebuild_wrapper_uses_unique_logs_and_result_bundles(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        for _ in range(2):
            subprocess.run(
                [script, "--raw", "raw", "--", "test"],
                check=True,
                capture_output=True,
                text=True,
                env=self.environment,
            )

        arguments = captured.read_text().splitlines()
        result_bundles = [
            arguments[index + 1]
            for index, argument in enumerate(arguments[:-1])
            if argument == "-resultBundlePath" and not arguments[index + 1].endswith("raw-host.xcresult")
        ]
        self.assertEqual(len(result_bundles), 2)
        self.assertEqual(len(set(result_bundles)), 2)
        logs = list((self.root / "artifacts" / "verification").glob("*/Logs/raw.log"))
        self.assertEqual(len(logs), 2)

    def test_raw_tests_compile_and_validate_before_bounded_execution(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        subprocess.run(
            [script, "--raw", "--run-id", "raw-protected", "raw", "--", "test", "-testPlan", "GitXThreadSanitizer", "-only-testing:GitXTests/Contract", "CODE_SIGN_IDENTITY=-"],
            check=True, capture_output=True, text=True, env=self.environment,
        )
        invocations = captured.read_text().split("__INVOCATION__")
        host_build = next(value for value in invocations if "\nbuild-for-testing\n" in value and "GitXHostPreflight" in value)
        self.assertIn("-enableThreadSanitizer\nYES", host_build)
        self.assertNotIn("-only-testing:GitXTests/Contract", host_build)
        self.assertIn("CODE_SIGN_IDENTITY=-", host_build)
        suite = next(value for value in invocations if "\ntest-without-building\n" in value and "GitXThreadSanitizer" in value)
        self.assertIn("-only-testing:GitXTests/Contract", suite)
        receipt = self.receipt("raw-protected")
        names = [step["name"] for step in receipt["steps"]]
        self.assertLess(names.index("compile:raw"), names.index("host-preflight"))
        self.assertLess(names.index("signatures"), names.index("raw"))
        self.assertEqual(receipt["evidence"]["status"], "valid")
        execution = next(step for step in receipt["steps"] if step["name"] == "raw")
        supervisor = execution["supervisorCommand"]
        self.assertIn("--startup-timeout", supervisor)
        self.assertIn("--timeout", supervisor)
        self.assertIn("--native-test-root", supervisor)
        separator = supervisor.index("--")
        self.assertEqual(supervisor[separator + 1:], execution["command"])
        self.assertEqual(sum(argument.endswith("workflow_session.py") for argument in supervisor), 1)
        self.assertNotIn("--startup-timeout", execution["command"])

    def test_xcodebuild_wrapper_reuses_shared_derived_data(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        for run_id in ("shared-cache-one", "shared-cache-two"):
            subprocess.run(
                [script, "--raw", "--run-id", run_id, "build"],
                check=True,
                capture_output=True,
                text=True,
                env=self.environment,
            )

        build_invocations = [
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "-showdestinations" not in invocation
        ]
        arguments = "\n".join(build_invocations).splitlines()
        derived_paths = [
            arguments[index + 1]
            for index, argument in enumerate(arguments[:-1])
            if argument == "-derivedDataPath"
        ]
        self.assertEqual(set(derived_paths), {str(self.root / "build" / "DerivedData")})
        self.assertFalse(any((self.root / "artifacts" / "verification").glob("*/DerivedData")))

    def test_analyzer_uses_fresh_per_run_derived_data(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        (self.scripts / "check_analyzer_diagnostics.py").write_text("#!/usr/bin/env python3\n")
        pinned_tool = self.scripts / "run_pinned_tool.sh"
        pinned_tool.write_text("#!/bin/bash\nexit 0\n")
        pinned_tool.chmod(0o755)

        for run_id in ("analyzer-clean-one", "analyzer-clean-two"):
            subprocess.run(
                [script, "--raw", "--run-id", run_id, "analyze"],
                check=True,
                capture_output=True,
                text=True,
                env=self.environment,
            )

        analyzer_invocations = [
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "analyze" in invocation.splitlines()
        ]
        derived_paths = []
        for invocation in analyzer_invocations:
            arguments = invocation.splitlines()
            derived_paths.append(arguments[arguments.index("-derivedDataPath") + 1])
            self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
            self.assertIn("CODE_SIGNING_REQUIRED=NO", arguments)
            self.assertIn("COMPILER_INDEX_STORE_ENABLE=NO", arguments)
        self.assertEqual(len(set(derived_paths)), 2)
        for derived_path in map(pathlib.Path, derived_paths):
            self.assertEqual(derived_path.parent, self.root / "build")
            self.assertTrue(derived_path.name.startswith("AnalyzerDerivedData."))
            self.assertFalse(derived_path.exists())
        for run_id in ("analyzer-clean-one", "analyzer-clean-two"):
            report = (
                self.root
                / "artifacts"
                / "verification"
                / run_id
                / "Results"
                / "Analyzer"
                / "StaticAnalyzer"
                / "GitX"
                / "GitX"
                / "normal"
                / "arm64"
                / "report.plist"
            )
            self.assertEqual(report.read_text(), "analyzer report\n")
            self.assertEqual(self.receipt(run_id)["invocation"]["signingMode"], "disabled")

    def test_failed_analyzer_preserves_path_reports(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        environment = self.environment | {"MOCK_XCODEBUILD_EXIT_STATUS": "65"}

        result = subprocess.run(
            [script, "--raw", "--run-id", "analyzer-failure", "analyze"],
            capture_output=True,
            text=True,
            env=environment,
        )

        report = (
            self.root
            / "artifacts"
            / "verification"
            / "analyzer-failure"
            / "Results"
            / "Analyzer"
            / "StaticAnalyzer"
            / "GitX"
            / "GitX"
            / "normal"
            / "arm64"
            / "report.plist"
        )
        self.assertEqual(result.returncode, 65)
        self.assertEqual(report.read_text(), "analyzer report\n")
        self.assertEqual(self.receipt("analyzer-failure")["status"], "failed")

    def test_raw_respects_explicit_project_scheme_destination_configuration_and_derived_data(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        custom_derived = self.root / "custom-derived"

        subprocess.run(
            [
                script,
                "--raw",
                "raw",
                "--",
                "-project",
                "Other.xcodeproj",
                "-scheme",
                "Other",
                "-destination",
                "platform=macOS,arch=x86_64",
                "-configuration",
                "Release",
                "-derivedDataPath",
                str(custom_derived),
                "build",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        raw_invocation = next(
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "-showdestinations" not in invocation
        )
        arguments = raw_invocation.splitlines()
        self.assertNotIn("-workspace", arguments)
        self.assertEqual(arguments.count("-project"), 1)
        self.assertEqual(arguments.count("-scheme"), 1)
        self.assertEqual(arguments.count("-destination"), 1)
        self.assertEqual(arguments.count("-configuration"), 1)
        self.assertEqual(arguments.count("-derivedDataPath"), 1)

    def test_raw_handles_empty_wrapper_defaults_and_allows_deployment_target_override(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        custom_derived = self.root / "custom-derived"

        subprocess.run(
            [
                script,
                "--raw",
                "raw",
                "--",
                "-workspace",
                "Other.xcworkspace",
                "-scheme",
                "Other",
                "-destination",
                "platform=macOS,arch=x86_64",
                "-configuration",
                "Release",
                "-derivedDataPath",
                str(custom_derived),
                "-clonedSourcePackagesDirPath",
                str(self.root / "custom-packages"),
                "MACOSX_DEPLOYMENT_TARGET=14.0",
                "build",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        raw_invocation = next(
            invocation
            for invocation in captured.read_text().split("__INVOCATION__")
            if invocation.strip() and "-showdestinations" not in invocation
        )
        arguments = raw_invocation.splitlines()
        configured = arguments.index("MACOSX_DEPLOYMENT_TARGET=15.0")
        caller_override = arguments.index("MACOSX_DEPLOYMENT_TARGET=14.0")
        self.assertLess(configured, caller_override)

    def test_focused_correctness_run_skips_the_whole_app_coverage_gate(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [
                script,
                "--raw",
                "--run-id",
                "focused-correctness",
                "test",
                "correctness",
                "-only-testing:GitXTests/ExampleTests",
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        receipt = self.receipt("focused-correctness")
        self.assertEqual(
            receipt["invocation"]["coverageGate"],
            "not-applicable-focused-selection",
        )
        self.assertNotIn("coverage", [step["name"] for step in receipt["steps"]])

    def test_correctness_preserves_caller_compiler_flags_in_probe_and_suite(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        flags = ["OTHER_SWIFT_FLAGS=$(inherited) -DWORKFLOW_CHARACTERIZATION",
                 "OTHER_CFLAGS=$(inherited) -DWORKFLOW_CHARACTERIZATION=1"]
        subprocess.run([script, "--run-id", "compiler-flags", "test", "correctness",
                        "-only-testing:GitXTests/ExampleTests", *flags], check=True,
                       capture_output=True, text=True, env=self.environment)
        builds = [value.splitlines() for value in captured.read_text().split("__INVOCATION__")
                  if "\nbuild-for-testing\n" in value]
        self.assertEqual(len(builds), 2)
        for arguments in builds:
            for setting in ("OTHER_SWIFT_FLAGS", "OTHER_CFLAGS"):
                value = next(argument for argument in arguments if argument.startswith(setting + "="))
                self.assertIn("$(inherited)", value)
                self.assertIn("WORKFLOW_CHARACTERIZATION", value)
        for flag in flags:
            self.assertTrue(any(flag in argument for argument in
                                self.receipt("compiler-flags")["invocation"]["arguments"]))

    def capture_forge_test_environment(self) -> pathlib.Path:
        self.install_mock_xcodebuild(self.root / "Products")
        captured = self.root / "forge-test-environment.jsonl"
        self.environment["CAPTURED_FORGE_ENVIRONMENT"] = str(captured)
        mock = self.developer_directory / "usr/bin/xcodebuild"
        mock.write_text(mock.read_text() + '''
if [[ " $* " == *" test-without-building "* ]]; then
python3 - "$@" <<'PY'
import json, os, pathlib, sys
arguments = sys.argv[1:]
record = {"plan": arguments[arguments.index("-testPlan") + 1],
          "root": os.environ.get("TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT"),
          "diagnostics": os.environ.get("TEST_RUNNER_GITX_TEST_STDERR_DIRECTORY"),
          "progress": os.environ.get("TEST_RUNNER_GITX_TEST_PROGRESS_DIRECTORY"),
          "invocation": os.environ.get("TEST_RUNNER_GITX_TEST_INVOCATION_ID")}
with pathlib.Path(os.environ["CAPTURED_FORGE_ENVIRONMENT"]).open("a") as output:
    output.write(json.dumps(record) + "\\n")
PY
fi
''')
        return captured

    def test_native_verification_uses_cache_capture_and_archives_each_invocation(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        for name, arguments in (("preset", ["test", "correctness", "-only-testing:GitXTests/ExampleTests"]),
                                ("raw", ["raw", "--", "test", "-testPlan", "GitX"])):
            with self.subTest(entrypoint=name):
                result = subprocess.run([script, "--run-id", f"native-stderr-{name}", *arguments],
                                        capture_output=True, text=True, env=self.environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in captured.read_text().splitlines()]
        self.assertEqual(len(records), 4)
        self.assertEqual(len({record["invocation"] for record in records}), 4)
        for record, name in zip(records, ("preset", "preset", "raw", "raw")):
            native = pathlib.Path(record["diagnostics"])
            self.assertTrue(native.is_relative_to(self.root / "build/Fixtures"))
            self.assertFalse(native.is_relative_to(self.root / "artifacts/verification"))
            self.assertFalse(pathlib.Path(record["progress"]).exists(), 'Fully archived inactive scratch is retired')
            archive = self.root / "artifacts/verification" / f"native-stderr-{name}" / "Logs/Native" / record["invocation"]
            self.assertTrue((archive / 'native-diagnostics.json').is_file())
            self.assertFalse(list(archive.parent.parent.glob('*-console.log')))

    def test_release_native_verification_has_progress_without_requesting_app_capture(self):
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        result = subprocess.run([script, "--configuration", "Release", "--run-id", "release-native-progress",
                                 "test", "performance"], capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in captured.read_text().splitlines()]
        self.assertTrue(records)
        self.assertTrue(all(not record['diagnostics'] and record['progress'] and record['invocation'] for record in records))

    def test_native_verification_preserves_explicit_forwarded_forge_store(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        selected = self.root / "Caller Forge Store"
        self.environment["TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT"] = str(selected)
        for name, arguments in (("preset", ["test", "correctness", "-only-testing:GitXTests/ExampleTests"]),
                                ("raw", ["raw", "--", "test", "-testPlan", "GitX"])):
            with self.subTest(entrypoint=name):
                result = subprocess.run([script, "--run-id", f"explicit-forge-{name}", *arguments],
                                        capture_output=True, text=True, env=self.environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in captured.read_text().splitlines()]
        self.assertEqual([record["plan"] for record in records], ["GitXHostPreflight", "GitX"] * 2)
        self.assertTrue(all(record["root"] == str(selected) for record in records))

    def test_native_verification_defaults_to_distinct_run_owned_forge_stores(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        for key in ("TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT", "GITX_UITEST_FORGE_STORAGE_ROOT"):
            self.environment.pop(key, None)
        for name, arguments in (("preset", ["test", "correctness", "-only-testing:GitXTests/ExampleTests"]),
                                ("raw", ["raw", "--", "test", "-testPlan", "GitX"])):
            with self.subTest(entrypoint=name):
                result = subprocess.run([script, "--run-id", f"isolated-forge-{name}", *arguments],
                                        capture_output=True, text=True, env=self.environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in captured.read_text().splitlines()]
        self.assertEqual([record["plan"] for record in records], ["GitXHostPreflight", "GitX"] * 2)
        for record, name in zip(records, ("preset", "preset", "raw", "raw")):
            expected = self.root / "build/Fixtures" / f"isolated-forge-{name}" / "Forge"
            self.assertEqual(record["root"], str(expected))
            self.assertTrue(expected.is_dir())
            self.assertFalse((self.root / "artifacts/verification" / f"isolated-forge-{name}" / "Fixtures").exists())

    def test_native_verification_forwards_an_explicit_application_forge_store(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        selected = self.root / "Application Forge Store"
        self.environment.pop("TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT", None)
        self.environment["GITX_UITEST_FORGE_STORAGE_ROOT"] = str(selected)
        result = subprocess.run([script, "--run-id", "application-forge-store", "test", "correctness",
                                 "-only-testing:GitXTests/ExampleTests"],
                                capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in captured.read_text().splitlines()]
        self.assertEqual(len(records), 2)
        self.assertTrue(all(record["root"] == str(selected) for record in records))

    def test_native_verification_rejects_relative_forge_stores_before_execution(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.capture_forge_test_environment()
        for key in ("TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT", "GITX_UITEST_FORGE_STORAGE_ROOT"):
            environment = self.environment.copy()
            for setting in ("TEST_RUNNER_GITX_UITEST_FORGE_STORAGE_ROOT", "GITX_UITEST_FORGE_STORAGE_ROOT"):
                environment.pop(setting, None)
            environment[key] = "relative-forge"
            with self.subTest(setting=key):
                result = subprocess.run([script, "--run-id", f"invalid-forge-{key.lower()}", "test", "correctness",
                                         "-only-testing:GitXTests/ExampleTests"],
                                        capture_output=True, text=True, env=environment)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Test Forge storage root must be absolute", result.stderr)
        self.assertFalse(captured.exists())
        self.assertFalse((self.root / "relative-forge").exists())

    def test_correctness_records_atomic_counters_for_all_compilation_entrypoints(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        commands = (["build-tests"],
                    ["test", "correctness", "-only-testing:GitXTests/ExampleTests"],
                    ["test", "-testPlan", "GitX", "-only-testing:GitXTests/ExampleTests"],
                    ["raw", "--", "build-for-testing", "-testPlan=GitX"],
                    ["raw", "--", "test", "-only-testing:GitXTests/ExampleTests"])
        for index, command in enumerate(commands):
            with self.subTest(command=command):
                captured.write_text("")
                run_id = f"atomic-{index}"
                subprocess.run([script, "--run-id", run_id, *command], check=True,
                               capture_output=True, text=True, env=self.environment)
                builds = [value.splitlines() for value in captured.read_text().split("__INVOCATION__")
                          if "\nbuild-for-testing\n" in value]
                self.assertTrue(builds)
                for arguments in builds:
                    self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all", arguments)
                    self.assertIn("OTHER_CFLAGS=$(inherited) -fprofile-update=atomic", arguments)
                recorded = self.receipt(run_id)["invocation"]["arguments"]
                self.assertTrue(any("-instrprof-atomic-counter-update-all" in value for value in recorded))
                self.assertTrue(any("-fprofile-update=atomic" in value for value in recorded))

    def test_non_coverage_commands_keep_existing_counter_mode(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        for index, command in enumerate((["build"], ["test", "performance"],
                                         ["test", "address-undefined"], ["test", "thread-sanitizer"],
                                         ["raw", "--", "build-for-testing", "-testPlan", "GitXPerformance"])):
            with self.subTest(command=command):
                captured.write_text("")
                subprocess.run([script, "--run-id", f"non-atomic-{index}", *command], check=True,
                               capture_output=True, text=True, env=self.environment)
                self.assertNotIn("-instrprof-atomic-counter-update-all", captured.read_text())
                self.assertNotIn("-fprofile-update=atomic", captured.read_text())

    def test_performance_lane_enables_only_its_explicit_release_test_support(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")
        subprocess.run([script, "--run-id", "performance-support", "test", "performance"],
                       check=True, capture_output=True, text=True, env=self.environment)
        invocations = [value.splitlines() for value in captured.read_text().split("__INVOCATION__")
                       if "\nbuild-for-testing\n" in value]
        self.assertTrue(invocations)
        for arguments in invocations:
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) GITX_PERFORMANCE_TEST_SUPPORT", arguments)
            self.assertIn("GCC_PREPROCESSOR_DEFINITIONS=$(inherited) GITX_PERFORMANCE_TEST_SUPPORT=1", arguments)
            self.assertNotIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", arguments)
        captured.write_text("")
        subprocess.run([script, "--configuration", "Release", "--run-id", "ordinary-release", "build"],
                       check=True, capture_output=True, text=True, env=self.environment)
        self.assertNotIn("GITX_PERFORMANCE_TEST_SUPPORT", captured.read_text())

    def test_ui_preflight_forwards_non_selection_extras_only(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        result = subprocess.run(
            [
                script,
                "--raw",
                "test",
                "ui",
                "-only-testing",
                "GitXUITests/ExampleTests",
                "-skip-testing:GitXUITests/SkippedTests",
                "CUSTOM_SETTING=YES",
                "-parallel-testing-enabled",
                "NO",
                "-test-timeouts-enabled",
                "CALLER_TIMEOUTS",
                "-default-test-execution-time-allowance=777",
                "-maximum-test-execution-time-allowance",
                "888",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        invocations = captured.read_text().split("__INVOCATION__")
        preflight = next(value for value in invocations if "GitXUIPreflight" in value)
        full_ui = next(value for value in invocations if "GitXUI" in value and "GitXUIPreflight" not in value)
        self.assertNotIn("-only-testing", preflight)
        self.assertNotIn("GitXUITests/ExampleTests", preflight)
        self.assertNotIn("-skip-testing:GitXUITests/SkippedTests", preflight)
        self.assertIn("CUSTOM_SETTING=YES", preflight)
        self.assertIn("-parallel-testing-enabled", preflight)
        self.assertIn("NO", preflight)
        self.assertNotIn("CALLER_TIMEOUTS", preflight)
        self.assertNotIn("-default-test-execution-time-allowance=777", preflight)
        self.assertNotIn("888", preflight)
        self.assertIn("-test-timeouts-enabled\nYES", preflight)
        self.assertIn("-default-test-execution-time-allowance\n60", preflight)
        self.assertIn("-maximum-test-execution-time-allowance\n90", preflight)
        self.assertIn("-only-testing", full_ui)
        self.assertIn("GitXUITests/ExampleTests", full_ui)
        self.assertIn("-skip-testing:GitXUITests/SkippedTests", full_ui)
        self.assertIn("CALLER_TIMEOUTS", full_ui)
        self.assertIn("-default-test-execution-time-allowance=777", full_ui)
        self.assertIn("888", full_ui)

    def test_mock_ui_checks_use_a_distinct_process_name(self) -> None:
        foreign = self.root / "another-suite" / "GitXFixture"
        self.install_sleeping_executable(foreign)
        marker = self.root / "foreign-ready.pid"
        process = subprocess.Popen([foreign], env=self.environment | {"GITX_TEST_APP_PID_FILE": str(marker)})
        self.addCleanup(self._terminate_process, process)
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(marker.exists(), "Foreign fixture did not start")
        real = subprocess.run(["/usr/bin/pgrep", "-x", "GitX"], capture_output=True, text=True)
        self.assertNotIn(str(process.pid), real.stdout.splitlines())
        self.test_ui_preflight_forwards_non_selection_extras_only()

    def test_ui_preflight_still_rejects_a_controlled_competing_process(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        result = subprocess.run([script, "test", "ui"], capture_output=True, text=True,
                                env=self.environment | {"GITX_TEST_COMPETING_PIDS": "12345"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("running GitX pid(s): 12345", result.stdout + result.stderr)

    def test_wrapper_rejects_caller_owned_workspace_scheme_and_test_plan(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        for index, (flag, value) in enumerate((
            ("-workspace", "Other.xcworkspace"),
            ("-scheme", "Other"),
            ("-testPlan", "OtherTests"),
        )):
            result = subprocess.run(
                [script, "--raw", "--run-id", f"managed-argument-{index}", "test", "ui", flag, value],
                check=False,
                capture_output=True,
                text=True,
                env=self.environment,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn(f"{flag} is managed by scripts/xcodebuild.sh", result.stderr)

    def test_xcodebuild_wrapper_records_effective_preset_signing_modes(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        for run_id, command, expected in (
            ("smoke-signing", "smoke", "disabled"),
            ("build-signing", "build", "ad-hoc"),
            ("archive-signing", "archive", "project"),
        ):
            subprocess.run(
                [script, "--raw", "--run-id", run_id, command],
                check=True,
                capture_output=True,
                text=True,
                env=self.environment,
            )
            self.assertEqual(self.receipt(run_id)["invocation"]["signingMode"], expected)

    def test_xcodebuild_wrapper_never_copies_secrets_into_the_receipt_preset(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [script, "--raw", "--run-id", "redacted-preset", "build", "TOKEN=private-value"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )
        receipt = self.receipt("redacted-preset")
        serialized = json.dumps(receipt)

        self.assertEqual(receipt["invocation"]["preset"], "build")
        self.assertNotIn("private-value", serialized)
        self.assertIn("TOKEN=<redacted>", serialized)

    def test_xcodebuild_wrapper_propagates_a_staging_copy_failure(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        self.install_mock_ditto(exit_status=37)

        result = subprocess.run(
            [script, "--raw", "--stage-app", "build"],
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertEqual(result.returncode, 37)
        self.assertNotIn("Staged app:", result.stdout)

    def test_run_app_stop_terminates_a_recorded_process_identity(self) -> None:
        script = self.install_script("run_app.sh")
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        executable = self.root / "GitXFixture"
        executable.symlink_to("/bin/sleep")
        process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, process)
        start_time = subprocess.run(
            ["ps", "-p", str(process.pid), "-o", "lstart="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        (session_directory / "app.pid").write_text(f"{process.pid}\t{start_time}\n")

        subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertEqual(process.wait(timeout=2), -15)
        self.assertFalse((session_directory / "app.pid").exists())

    def test_run_app_stop_without_a_session_is_a_noop(self) -> None:
        script = self.install_script("run_app.sh")

        subprocess.run([script, "--stop"], check=True, capture_output=True, text=True, env=self.environment)

    def test_run_app_stop_cleans_a_stale_pid_and_its_home(self) -> None:
        script = self.install_script("run_app.sh")
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        pid_record = session_directory / "app.pid"
        pid_record.write_text("999999\tThu Jan  1 00:00:00 1970\n")
        session = session_directory / "session.txt"
        session.write_text(f"app_pid=999999\nisolated_home={isolated_home}\n")

        subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertFalse(isolated_home.exists())
        self.assertFalse(pid_record.exists())
        self.assertFalse(session.exists())

    def test_run_app_stop_refuses_an_unverifiable_legacy_pid_only_record(self) -> None:
        script = self.install_script("run_app.sh")
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        executable = self.root / "GitXFixture"
        executable.symlink_to("/bin/sleep")
        process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, process)
        pid_record = session_directory / "app.pid"
        pid_record.write_text(f"{process.pid}\n")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(f"app_pid={process.pid}\nisolated_home={isolated_home}\n")

        result = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(process.poll())
        self.assertTrue(pid_record.exists())
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())
        self.assertIn("process identity cannot be verified", result.stderr)

    def test_run_app_stop_preserves_home_when_recorded_identity_is_stale_but_pid_is_live(self) -> None:
        script = self.install_script("run_app.sh")
        process, session_directory = self.create_live_run_app_session()
        (session_directory / "app.pid").write_text(f"{process.pid}\tThu Jan  1 00:00:00 1970\n")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(session.read_text() + f"isolated_home={isolated_home}\n")

        result = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(process.poll())
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())

    def test_run_app_stop_preserves_home_when_identity_file_names_another_live_app(self) -> None:
        script = self.install_script("run_app.sh")
        identity_process, session_directory = self.create_live_run_app_session()
        recorded_process = subprocess.Popen([self.root / "GitXFixture", "60"])
        self.addCleanup(self._terminate_process, recorded_process)
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(
            session.read_text().replace(f"app_pid={identity_process.pid}", f"app_pid={recorded_process.pid}")
            + f"isolated_home={isolated_home}\n"
        )

        result = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(identity_process.wait(timeout=2), -signal.SIGTERM)
        self.assertIsNone(recorded_process.poll())
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())

    def test_run_app_stop_preserves_home_when_identity_file_names_another_live_log(self) -> None:
        script = self.install_script("run_app.sh")
        _, session_directory = self.create_live_run_app_session()
        executable = self.root / "log"
        executable.symlink_to("/bin/sleep")
        identity_process = subprocess.Popen([executable, "60"])
        recorded_process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, identity_process)
        self.addCleanup(self._terminate_process, recorded_process)
        start_time = subprocess.run(
            ["ps", "-p", str(identity_process.pid), "-o", "lstart="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        (session_directory / "logstream.pid").write_text(f"{identity_process.pid}\t{start_time}\n")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(
            session.read_text() + f"log_pid={recorded_process.pid}\nisolated_home={isolated_home}\n"
        )

        result = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(identity_process.wait(timeout=2), -signal.SIGTERM)
        self.assertIsNone(recorded_process.poll())
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())

    def test_run_app_stop_preserves_a_live_session_when_app_pid_record_is_missing(self) -> None:
        script = self.install_script("run_app.sh")
        process, session_directory = self.create_live_run_app_session()
        (session_directory / "app.pid").unlink()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(session.read_text() + f"isolated_home={isolated_home}\n")

        result = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(process.poll())
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())

    def test_run_app_stop_removes_validated_home_and_session_metadata(self) -> None:
        script = self.install_script("run_app.sh")
        process, session_directory = self.create_live_run_app_session()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(session.read_text() + f"isolated_home={isolated_home}\n")
        environment = self.environment | {"TMPDIR": str(temporary_root)}

        subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
        self.assertFalse(isolated_home.exists())
        self.assertFalse(session.exists())

    def test_run_app_stop_preserves_an_unvalidated_recorded_home(self) -> None:
        script = self.install_script("run_app.sh")
        process, session_directory = self.create_live_run_app_session()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        unvalidated_home = self.root / "do-not-delete"
        unvalidated_home.mkdir()
        session = session_directory / "session.txt"
        session.write_text(session.read_text() + f"isolated_home={unvalidated_home}\n")
        environment = self.environment | {"TMPDIR": str(temporary_root)}

        result = subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
        self.assertTrue(unvalidated_home.exists())
        self.assertFalse(session.exists())
        self.assertIn("Refusing to remove unvalidated runtime home", result.stderr)

    def test_run_app_stop_retains_session_until_validated_home_removal_succeeds(self) -> None:
        script = self.install_script("run_app.sh")
        process, session_directory = self.create_live_run_app_session()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        isolated_home = pathlib.Path(tempfile.mkdtemp(prefix="gitx-run-app-home.", dir=temporary_root))
        session = session_directory / "session.txt"
        session.write_text(session.read_text() + f"isolated_home={isolated_home}\n")
        mock_rm = self.bin / "rm"
        mock_rm.write_text(
            "#!/bin/bash\n"
            "for arg in \"$@\"; do\n"
            "  [[ \"$arg\" == \"${FAIL_REMOVAL_PATH:-}\" ]] && exit 73\n"
            "done\n"
            "exec /bin/rm \"$@\"\n"
        )
        mock_rm.chmod(0o755)
        environment = self.environment | {"TMPDIR": str(temporary_root)}

        failed = subprocess.run(
            [script, "--stop"],
            capture_output=True,
            text=True,
            env=environment | {"FAIL_REMOVAL_PATH": str(isolated_home)},
        )

        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
        self.assertTrue(isolated_home.exists())
        self.assertTrue(session.exists())
        self.assertTrue((session_directory / "app.pid").exists())

        subprocess.run([script, "--stop"], check=True, capture_output=True, text=True, env=environment)

        self.assertFalse(isolated_home.exists())
        self.assertFalse(session.exists())
        self.assertFalse((session_directory / "app.pid").exists())

    def test_run_app_documents_explicit_git_environment_mode(self) -> None:
        script = self.install_script("run_app.sh")
        self.install_mock_xcodebuild(self.root / "Products")
        result = subprocess.run([script, "--help"], check=True, capture_output=True, text=True, env=self.environment)
        self.assertIn("--preserve-git-environment", result.stdout)
        for arguments in ([], ["--repo", "/tmp/existing", "--m2", "push-create"], ["--repo", "/tmp/existing", "--m3", "review"]):
            rejected = subprocess.run([script, "--preserve-git-environment", *arguments], capture_output=True, text=True, env=self.environment)
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("requires --repo", rejected.stderr)

    def test_run_app_launches_use_unique_forge_storage_roots(self) -> None:
        script = self.install_script("run_app.sh")
        self.install_mock_peekaboo()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True, env=self.fixture_environment)
        (repository / "selected.txt").write_text("selected fixture\n")
        foreign = self.root / "foreign-repo"
        foreign.mkdir()
        subprocess.run(["git", "init", "--quiet", foreign], check=True, env=self.fixture_environment)
        (foreign / "foreign.txt").write_text("foreign fixture\n")
        (foreign / "selected.txt").write_text("different foreign contents\n")
        subprocess.run(["git", "-C", foreign, "add", "foreign.txt"], check=True, env=self.fixture_environment)
        foreign_index = foreign / ".git" / "index"
        original_foreign_index = foreign_index.read_bytes()
        selectors = {
            "GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
            "GIT_INDEX_FILE": str(foreign_index), "GIT_COMMON_DIR": str(foreign / ".git"),
            "GIT_OBJECT_DIRECTORY": str(foreign / ".git" / "objects"),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(foreign / ".git" / "objects"),
            "GIT_QUARANTINE_PATH": str(foreign / ".git" / "objects"), "GIT_NAMESPACE": "inherited-namespace",
        }
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitXFixture"
        app_binary.parent.mkdir(parents=True)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        forge_roots = self.root / "forge-roots.txt"
        launch_environment = self.root / "launch-environment.txt"
        mutation_result = self.root / "mutation-result.txt"
        app_binary.write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$GITX_UITEST_FORGE_STORAGE_ROOT\" >>'{forge_roots}'\n"
            f"/usr/bin/env >'{launch_environment}'\n"
            '/usr/bin/git -C "$GITX_UITEST_REPO" add selected.txt\n'
            f"printf '%s\\n' \"$?\" >'{mutation_result}'\n"
            "exec /bin/sleep 60\n"
        )
        app_binary.chmod(0o755)
        log = self.bin / "log"
        log.write_text("#!/bin/bash\nexec /bin/sleep 60\n")
        log.chmod(0o755)
        environment = self.environment | {
            "TMPDIR": str(temporary_root),
            "GIT_CONFIG_PARAMETERS": "'commit.gpgsign=true'",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "init.templateDir",
            "GIT_CONFIG_VALUE_0": str(self.root / "inherited-template"),
            "GIT_INDEX_FILE": str(self.root / "inherited-index"),
            "GIT_AUTHOR_NAME": "Existing Author",
            "GIT_COMMITTER_NAME": "Existing Committer",
            "GIT_CONFIG_GLOBAL": str(self.root / "user.gitconfig"),
            "GIT_CONFIG_SYSTEM": str(self.root / "system.gitconfig"),
            "GIT_ASKPASS": "/custom/askpass",
            "GIT_TERMINAL_PROMPT": "1",
            "GCM_INTERACTIVE": "always",
            "LC_ALL": "en_US.UTF-8",
        }
        environment.update(selectors)
        environment["GITX_TEST_READY_FILE"] = str(mutation_result)
        sessions: list[dict[str, str]] = []
        captured_environments: list[dict[str, str]] = []

        try:
            for preserve in (False, False, True):
                (repository / ".git" / "index").unlink(missing_ok=True)
                mutation_result.unlink(missing_ok=True)
                launch = subprocess.run(
                    [script, "--no-build", "--repo", str(repository), "--timeout", "15"]
                    + (["--preserve-git-environment"] if preserve else []),
                    check=False,
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=30,
                )
                self.assertEqual(foreign_index.read_bytes(), original_foreign_index, f"preserve={preserve}; launcher status={launch.returncode}")
                launch.check_returncode()
                session = dict(
                    line.split("=", maxsplit=1)
                    for line in (self.root / "build" / "Logs" / "run-app" / "session.txt")
                    .read_text()
                    .splitlines()
                )
                sessions.append(session)
                captured_environments.append(dict(
                    line.split("=", maxsplit=1)
                    for line in launch_environment.read_text().splitlines() if "=" in line
                ))
                self.assertTrue(mutation_result.exists(), "Launcher reported readiness before the fixture mutation completed")
                self.assertEqual(mutation_result.read_text().strip(), "0", f"preserve={preserve}")
                self.assertEqual(foreign_index.read_bytes(), original_foreign_index, f"preserve={preserve}")
                self.assertEqual(subprocess.run(["git", "-C", repository, "ls-files"], check=True,
                    capture_output=True, text=True, env=self.fixture_environment).stdout, "selected.txt\n")
                for key in ("app_pid", "log_pid"):
                    self.terminate_pid(int(session[key]))
        finally:
            subprocess.run(
                [script, "--stop"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            for session in sessions:
                for key in ("app_pid", "log_pid"):
                    self.terminate_pid(int(session[key]))

        homes = [session["isolated_home"] for session in sessions]
        roots = forge_roots.read_text().splitlines()
        self.assertEqual(len(set(homes)), 3)
        self.assertEqual(len(set(roots)), 3)
        self.assertEqual(
            roots,
            [f"{home}/Library/Application Support/GitX/Forge" for home in homes],
        )
        captured = captured_environments[0]
        self.assertEqual(captured["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(captured["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(captured["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(captured["GIT_ASKPASS"], "/usr/bin/false")
        self.assertEqual(captured["GCM_INTERACTIVE"], "never")
        self.assertEqual(captured["GIT_CONFIG_SYSTEM"], "/dev/null")
        self.assertEqual(captured["GIT_CONFIG_COUNT"], "3")
        self.assertEqual(captured["GIT_CONFIG_KEY_0"], "commit.gpgsign")
        self.assertEqual(captured["GIT_CONFIG_VALUE_0"], "false")
        self.assertEqual(captured["GIT_CONFIG_KEY_1"], "tag.gpgsign")
        self.assertEqual(captured["GIT_CONFIG_VALUE_1"], "false")
        self.assertEqual(captured["GIT_CONFIG_KEY_2"], "init.templateDir")
        self.assertEqual(captured["GIT_CONFIG_VALUE_2"], "/dev/null")
        self.assertNotIn("GIT_CONFIG_PARAMETERS", captured)
        self.assertNotIn("GIT_INDEX_FILE", captured)
        self.assertEqual(captured["GIT_AUTHOR_NAME"], "GitX Tests")
        self.assertEqual(captured["GIT_COMMITTER_NAME"], "GitX Tests")
        self.assertEqual(captured["LC_ALL"], "C")
        preserved = captured_environments[2]
        for key, value in environment.items():
            if key in selectors:
                for captured in captured_environments: self.assertNotIn(key, captured)
            elif key.startswith("GIT_") or key in ("GCM_INTERACTIVE", "LC_ALL"):
                self.assertEqual(preserved[key], value, key)
        self.assertFalse((self.root / "build" / "Logs" / "run-app" / "session.txt").exists())

    def test_run_app_cleans_an_isolated_home_when_launch_fails(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True, env=self.fixture_environment)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitXFixture"
        app_binary.parent.mkdir(parents=True)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        app_binary.write_text("#!/bin/bash\nfor attempt in {1..200}; do\n    [[ -s $GITX_TEST_PROCESS_PID_FILE ]] && break\n    sleep 0.01\ndone\nexit 1\n")
        app_binary.chmod(0o755)
        self.install_sleeping_executable(self.bin / "log")
        recorded_pid = self.root / "log-process.pid"
        environment = self.environment | {
            "TMPDIR": str(temporary_root),
            "GITX_TEST_PROCESS_PID_FILE": str(recorded_pid),
        }

        result = subprocess.run(
            [script, "--no-build", "--repo", str(repository), "--timeout", "1"],
            capture_output=True,
            text=True,
            env=environment,
            timeout=10,
        )

        self.assertNotEqual(result.returncode, 0)
        log_pid = int(recorded_pid.read_text())
        self.addCleanup(self.terminate_pid, log_pid)
        self.assertFalse(self.process_is_running(log_pid))
        self.assertEqual(list(temporary_root.glob("gitx-run-app-home.*")), [])
        self.assertFalse((self.root / "build" / "Logs" / "run-app" / "session.txt").exists())

    def test_run_app_interrupt_during_startup_stops_app_before_removing_home(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)

            self.assertFalse(self.process_is_running(app_pid))
            self.assertFalse(self.process_is_running(log_pid))
            self.assertEqual(list(temporary_root.glob("gitx-run-app-home.*")), [])
            self.assertFalse((session_directory / "session.txt").exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_concurrent_invocations_cannot_take_over_pending_session(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        script = self.scripts / "run_app.sh"
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        session = (session_directory / "session.txt").read_text()
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        try:
            for arguments in [
                ["--stop"],
                ["--no-build", "--repo", str(self.root / "fixture-repo")],
            ]:
                result = subprocess.run(
                    [script, *arguments],
                    capture_output=True,
                    text=True,
                    env=self.environment | {"TMPDIR": str(temporary_root)},
                    timeout=5,
                )
                self.assertEqual(result.returncode, 75)
                self.assertIn("owning run", result.stderr)
                self.assertIn("receipt", result.stderr)
                self.assertTrue(self.process_is_running(app_pid))
                self.assertTrue(self.process_is_running(log_pid))
                self.assertEqual((session_directory / "session.txt").read_text(), session)
                self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)

    def test_run_app_interrupt_stops_owned_process_and_preserves_unknown_home_when_app_pid_record_is_missing(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "app.pid").unlink()

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertFalse(self.process_is_running(app_pid))
            self.assertTrue((session_directory / "session.txt").exists())
            self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_interrupt_stops_owned_process_and_preserves_unknown_home_when_app_pid_record_is_unverifiable(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "app.pid").write_text(f"{app_pid}\n")

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertFalse(self.process_is_running(app_pid))
            self.assertTrue((session_directory / "session.txt").exists())
            self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_interrupt_stops_owned_process_and_preserves_unknown_home_when_log_pid_record_is_missing(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "logstream.pid").unlink()

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertFalse(self.process_is_running(log_pid))
            self.assertTrue((session_directory / "session.txt").exists())
            self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_preserves_home_when_log_pid_identity_cannot_be_recorded(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        self.install_sleeping_executable(app_contents / "MacOS" / "GitXFixture")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        self.install_sleeping_executable(self.bin / "log")
        recorded_pid = self.root / "log-process.pid"
        ps = self.bin / "ps"
        ps.write_text("#!/bin/bash\n[[ \"$*\" == *'lstart='* ]] && exit 1\nexec /bin/ps \"$@\"\n")
        ps.chmod(0o755)

        result = subprocess.run(
            [script, "--no-build", "--repo", str(repository)],
            capture_output=True,
            text=True,
            env=self.environment | {
                "TMPDIR": str(temporary_root),
                "GITX_TEST_PROCESS_PID_FILE": str(recorded_pid),
            },
            timeout=10,
        )
        deadline = time.monotonic() + 2
        while not recorded_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(recorded_pid.exists(), result.stdout + result.stderr)
        log_pid = int(recorded_pid.read_text())
        self.addCleanup(self.terminate_pid, log_pid)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.process_is_running(log_pid))
        self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        self.assertFalse((self.root / "build" / "Logs" / "run-app" / "session.txt").exists())

    def test_run_app_removes_home_when_log_exits_before_identity_can_be_recorded(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "python"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitXFixture"
        app_binary.parent.mkdir(parents=True)
        app_binary.write_text("#!/bin/bash\nexit 0\n")
        app_binary.chmod(0o755)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        log = self.bin / "log"
        log_pid = self.root / "exiting-log.pid"
        self.addCleanup(self.terminate_pid_file, log_pid)
        identity_probe = self.root / "log-identity-probed"
        log.write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$$\" >'{log_pid}'\n"
            f"for _ in {{1..200}}; do [[ -e '{identity_probe}' ]] && break; sleep 0.01; done\n"
            f"[[ -e '{identity_probe}' ]] || {{ echo 'Identity fixture handshake timed out' >&2; exit 2; }}\n"
            "exit 0\n"
        )
        log.chmod(0o755)
        ps = self.bin / "ps"
        ps.write_text(
            "#!/bin/bash\n"
            "if [[ \"$*\" == *'lstart='* ]]; then\n"
            # Owner identity queries must remain real. This fixture controls
            # only the log's exit-before-identity race, with a marker handshake.
            "  command=$(/bin/ps -p \"$2\" -o command= 2>/dev/null)\n"
            "  executable=${command%% *}\n"
            "  case \"${executable##*/}\" in bash|sh) ;; *) exec /bin/ps \"$@\" ;; esac\n"
            f"  if [[ \"$command\" != *'{log}'* && \"$command\" != *'{script}'* ]]; then exec /bin/ps \"$@\"; fi\n"
            f"  for _ in {{1..200}}; do [[ -s '{log_pid}' ]] && break; sleep 0.01; done\n"
            f"  [[ -s '{log_pid}' && \"$(cat '{log_pid}')\" == \"$2\" ]] || exec /bin/ps \"$@\"\n"
            f"  touch '{identity_probe}'\n"
            "  for _ in {1..200}; do\n"
            "    state=$(/bin/ps -p \"$2\" -o stat= 2>/dev/null)\n"
            "    [[ -z \"$state\" || \"$state\" == *Z* ]] && exit 1\n"
            "    sleep 0.01\n"
            "  done\n"
            "  exit 2\n"
            "fi\n"
            "exec /bin/ps \"$@\"\n"
        )
        ps.chmod(0o755)

        result = subprocess.run(
            [script, "--no-build", "--repo", str(repository)],
            capture_output=True,
            text=True,
            env=self.environment | {"TMPDIR": str(temporary_root)},
            timeout=30,
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(identity_probe.exists(), "The fixture must exercise the log identity failure")
        self.assertIn("Could not record the log stream process identity.", result.stderr)
        self.assertEqual(list(temporary_root.glob("gitx-run-app-home.*")), [])
        session_directory = self.root / "build" / "Logs" / "run-app"
        self.assertFalse((session_directory / "session.txt").exists())
        self.assertFalse((session_directory / "logstream.pid").exists())

    def test_run_app_preserves_home_when_session_record_cannot_be_written(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        self.install_sleeping_executable(app_contents / "MacOS" / "GitXFixture")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark.Tests"}, handle)
        self.install_sleeping_executable(self.bin / "log")
        session_directory = self.root / "build" / "Logs" / "run-app"
        mkdir = self.bin / "mkdir"
        mkdir.write_text(
            "#!/bin/bash\n"
            "/bin/mkdir \"$@\" || exit $?\n"
            "if [[ \"${1:-}\" == '-p' && \"${2:-}\" == \"$GITX_TEST_SESSION_DIR\" ]]; then\n"
            "  /bin/mkdir \"$GITX_TEST_SESSION_DIR/session.txt\"\n"
            "fi\n"
        )
        mkdir.chmod(0o755)
        recorded_pid = self.root / "app-process.pid"

        result = subprocess.run(
            [script, "--no-build", "--repo", str(repository)],
            capture_output=True,
            text=True,
            env=self.environment | {
                "TMPDIR": str(temporary_root),
                "GITX_TEST_APP_PID_FILE": str(recorded_pid),
                "GITX_TEST_SESSION_DIR": str(session_directory),
            },
            timeout=10,
        )
        deadline = time.monotonic() + 2
        while not recorded_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(recorded_pid.exists(), result.stdout + result.stderr)
        app_pid = int(recorded_pid.read_text())
        self.addCleanup(self.terminate_pid, app_pid)
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, log_pid)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.process_is_running(app_pid))
        self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        self.assertTrue((session_directory / "session.txt").is_dir())

    def test_observe_app_logs_remain_available_after_the_app_exits(self) -> None:
        script = self.install_script("observe_app.sh")
        process, _ = self.create_live_run_app_session()
        process.terminate()
        process.wait(timeout=2)

        result = subprocess.run(
            [script, "logs", "error"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIn("runtime error marker", result.stdout)
        self.assertNotIn("standard output marker", result.stdout)

    def test_observe_app_logs_remain_available_after_stop(self) -> None:
        stop_script = self.install_script("run_app.sh")
        observe_script = self.install_script("observe_app.sh")
        process, _ = self.create_live_run_app_session()

        subprocess.run([stop_script, "--stop"], check=True, capture_output=True, text=True, env=self.environment)
        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
        result = subprocess.run(
            [observe_script, "logs", "error"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIn("runtime error marker", result.stdout)
        self.assertNotIn("standard output marker", result.stdout)

    def test_observe_app_identifies_the_recorded_repository_window(self) -> None:
        script = self.install_script("observe_app.sh")
        self.install_mock_peekaboo()
        process, _ = self.create_live_run_app_session()

        result = subprocess.run(
            [script, "id"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIn(f"pid={process.pid}", result.stdout)
        self.assertIn("window_id=42", result.stdout)
        self.assertIn("window_title=fixture-repo (branch: main)", result.stdout)

    def test_observe_app_rejects_a_session_with_a_mismatched_pid(self) -> None:
        script = self.install_script("observe_app.sh")
        self.install_mock_peekaboo()
        _, session_directory = self.create_live_run_app_session()
        session = session_directory / "session.txt"
        session.write_text(session.read_text().replace("app_pid=", "app_pid=999"))

        result = subprocess.run(
            [script, "id"],
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match", result.stderr)

    def test_observe_app_removes_a_stale_image_when_capture_fails(self) -> None:
        script = self.install_script("observe_app.sh")
        self.install_mock_peekaboo()
        _, session_directory = self.create_live_run_app_session()
        output = session_directory / "capture.png"
        output.write_text("stale")
        environment = self.environment.copy()
        environment["PEEKABOO_IMAGE_FAIL"] = "1"

        result = subprocess.run(
            [script, "image", output],
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_observe_app_filters_the_accessibility_tree(self) -> None:
        script = self.install_script("observe_app.sh")
        self.install_mock_peekaboo()
        self.create_live_run_app_session()

        result = subprocess.run(
            [script, "tree", "commit"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIn("Commit", result.stdout)
        self.assertNotIn("Push", result.stdout)

    @staticmethod
    def _terminate_process(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=2)


class VerificationWorkflowTests(unittest.TestCase):
    @staticmethod
    def jobs():
        workflow = (ROOT / '.github/workflows/Verify.yml').read_text().split('\njobs:\n', 1)[1]
        markers = list(re.finditer(r'^  ([a-z][a-z0-9-]+):[ \t]*$', workflow, re.MULTILINE))
        return {marker.group(1): workflow[marker.end():markers[index + 1].start()
                                        if index + 1 < len(markers) else len(workflow)]
                for index, marker in enumerate(markers)}

    def test_native_ci_keeps_complete_check_commands_and_budgets(self):
        commands = [
            'scripts/xcodebuild.sh --run-id "verify-correctness-${{ github.run_id }}-${{ github.run_attempt }}" test correctness',
            'scripts/xcodebuild.sh --run-id "verify-analyze-${{ github.run_id }}-${{ github.run_attempt }}" analyze',
        ]
        for command in commands:
            with self.subTest(command=command):
                matching = [body for body in self.jobs().values() if command in body]
                self.assertEqual(len(matching), 1)
                self.assertIn('runs-on: macos-26', matching[0])
                self.assertIn('timeout-minutes: 75', matching[0])
                self.assertIn('xcode-version: "26.6"', matching[0])

    def test_native_ci_checks_have_independent_jobs_and_a_required_gate(self):
        jobs = self.jobs()
        tests = next(name for name, body in jobs.items() if '"verify-correctness-' in body)
        analyzer = next(name for name, body in jobs.items() if '"verify-analyze-' in body)
        self.assertNotEqual(tests, analyzer, 'Independent checks must not consume the same job budget')
        self.assertIn('needs: toolchain-smoke', jobs[tests])
        self.assertNotIn('needs: [toolchain-smoke, worktree-contracts]', jobs[tests])
        self.assertIn('needs: toolchain-smoke', jobs[analyzer])
        gate = jobs['unit-and-analyze']
        self.assertIn('name: unit tests and analyzer', gate)
        self.assertIn(f'needs: [{tests}, {analyzer}, worktree-contracts]', gate)
        self.assertEqual(gate.count('if: ${{ always() }}'), 2, 'Both the small gate and its result step must survive cancellation')
        self.assertNotIn('!cancelled()', gate)
        self.assertIn('timeout-minutes: 5', gate)
        self.assertIn('needs: toolchain-smoke', jobs['worktree-contracts'])
        self.assertIn("UNIT_RESULT: ${{ needs['unit-tests'].result }}", gate)
        self.assertIn('ANALYSIS_RESULT: ${{ needs.analyzer.result }}', gate)
        self.assertIn("WORKTREE_RESULT: ${{ needs['worktree-contracts'].result }}", gate)

    def test_native_repetitions_include_followup_failures_without_relaxing_limits(self):
        # Structure protection only; hosted results establish actual execution.
        job = self.jobs()['worktree-contracts']
        step = job.split('- name: Repeat the stabilized native CI regressions five times', 1)[1].split('- name:', 1)[0]
        self.assertIn('test correctness -test-iterations 5', step)
        self.assertIn('timeout-minutes: 75', job)
        for selector in [
            'WorktreeAppKitTests/testFailedWorktreeRefreshShowsAccessibleWarningAndEqualSnapshotRecoveryClearsIt',
            'WorktreeAppKitTests/testClosedSidebarPreservesSortAndSuppressesRemoteResponderRouting',
            'WorktreeAppKitTests/testClosingSidebarRevokesPreviouslyIssuedMenusAndRetainedItems',
            'WorktreeRepairSafetyTests/testQueuedGlobalRepairRequiresFreshLocateApprovalWhenMovedDirectoryAliasChanges',
            'IndexCommitServiceTests/testCoordinatorReleasesFinalRepositoryOwnershipOnMainThread',
            'HistoryControllerTests/testAutomaticTreeFallbackPreservesRememberedFileUntilUserSelectsAnother',
            'HistoryControllerTests/testGitTreeFileSizeSupportsConcurrentPreviewLoads',
            'HistoryControllerTests/testSelectionReconciliationWorkingStateStatusAndTreeRestoration',
            'ForgeMarkdownAvatarTests/testAppModuleProductBoundariesReceiveAppHostedCoverage',
        ]:
            with self.subTest(selector=selector):
                self.assertIn('-only-testing:GitXTests/' + selector, step)
        self.assertNotIn('continue-on-error', job)

    def test_required_native_ci_gate_only_accepts_three_successes(self):
        gate = self.jobs()['unit-and-analyze']
        marker = '- name: Require all native verification jobs'
        self.assertIn(marker, gate)
        script = textwrap.dedent(gate.split(marker, 1)[1].split('run: |', 1)[1])
        for tests in ['success', 'failure', 'cancelled', 'skipped', '']:
            for analyzer in ['success', 'failure', 'cancelled', 'skipped', '']:
                for worktrees in ['success', 'failure', 'cancelled', 'skipped', '']:
                    with self.subTest(tests=tests, analyzer=analyzer, worktrees=worktrees):
                        result = subprocess.run(
                            ['/bin/bash', '--noprofile', '--norc', '-e', '-c', script],
                            env={'PATH': os.defpath, 'UNIT_RESULT': tests, 'ANALYSIS_RESULT': analyzer,
                                 'WORKTREE_RESULT': worktrees},
                            capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode == 0, tests == analyzer == worktrees == 'success')

    def test_only_small_required_gate_overrides_workflow_cancellation(self):
        # Source protection for scheduling intent; this does not execute GitHub's scheduler.
        jobs = self.jobs()
        for name in ('unit-tests', 'analyzer', 'worktree-contracts', 'ui'):
            prefix = jobs[name].split('steps:', 1)[0]
            self.assertNotIn('always()', prefix)
        gate = jobs['unit-and-analyze']
        step = gate.split('- name: Require all native verification jobs', 1)[1]
        self.assertIn('if: ${{ always() }}', step.split('run: |', 1)[0])
        self.assertNotIn('continue-on-error', gate)

    def test_native_setup_marker_follows_all_prerequisites_and_keeps_default_success_condition(self):
        for job in ['worktree-contracts', 'ui']:
            with self.subTest(job=job):
                body = self.jobs()[job]
                marker = '- name: Record successful native setup'
                setup = body.split(marker, 1)[1].split('- name:', 1)[0]
                self.assertIn('id: native_setup_ready', setup)
                self.assertIn("run: 'true'", setup)
                self.assertNotIn('if:', setup, 'A failed prerequisite must skip the readiness marker')
                self.assertLess(body.index('- name: Prepare ObjectiveGit'), body.index(marker))
                if job == 'worktree-contracts':
                    self.assertLess(body.index('- name: Install pinned Swift tools'), body.index(marker))
                    first_test = '- name: Execute Release service and runtime contracts'
                else:
                    first_test = '- name: Repeat Locate consent and stabilized UI regressions five times'
                self.assertLess(body.index(marker), body.index(first_test))

    def test_follow_on_predicates_reject_unready_setup_but_preserve_independent_failure_collection(self):
        # This evaluates only the two supported atoms extracted from the workflow,
        # not GitHub's runner or its prerequisite/default-condition implementation.
        steps = [
            ('worktree-contracts', 'Repeat the stabilized native CI regressions five times'),
            ('worktree-contracts', 'Measure Release worktree safety and header update costs'),
            ('ui', 'Run UI plan'),
        ]
        for job, name in steps:
            step = self.jobs()[job].split('- name: ' + name, 1)[1].split('- name:', 1)[0]
            condition = step.split('if: ${{ ', 1)[1].split(' }}', 1)[0]
            self.assertEqual(condition, "!cancelled() && steps.native_setup_ready.outcome == 'success'")
            for setup in ['success', 'failure', 'cancelled', 'skipped', '']:
                for earlier_test in ['success', 'failure', 'cancelled', 'skipped', '']:
                    for cancelled in [False, True]:
                        with self.subTest(job=job, step=name, setup=setup, earlier_test=earlier_test, cancelled=cancelled):
                            atoms = {
                                '!cancelled()': not cancelled,
                                "steps.native_setup_ready.outcome == 'success'": setup == 'success',
                            }
                            actual = all(atoms[atom] for atom in condition.split(' && '))
                            self.assertEqual(actual, setup == 'success' and not cancelled)

    def test_focused_failures_keep_independent_plans_and_artifact_uploads_enabled(self):
        jobs = self.jobs()
        for job, name in [
            ('worktree-contracts', 'Repeat the stabilized native CI regressions five times'),
            ('worktree-contracts', 'Measure Release worktree safety and header update costs'),
            ('ui', 'Run UI plan'),
        ]:
            with self.subTest(job=job, step=name):
                step = jobs[job].split('- name: ' + name, 1)[1].split('- name:', 1)[0]
                self.assertIn("if: ${{ !cancelled() && steps.native_setup_ready.outcome == 'success' }}", step)
                self.assertNotIn('continue-on-error', jobs[job])
        for job, upload in [('worktree-contracts', 'Upload worktree verification results'),
                            ('ui', 'Upload UI result'), ('unit-tests', 'Upload correctness results')]:
            step = jobs[job].split('- name: ' + upload, 1)[1]
            self.assertIn('if: always()', step)
        self.assertIn('needs: toolchain-smoke', jobs['worktree-contracts'])
        self.assertIn('needs: toolchain-smoke', jobs['ui'])


if __name__ == "__main__":
    unittest.main()
