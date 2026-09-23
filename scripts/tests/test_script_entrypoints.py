from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from support import ROOT


class ScriptEntrypointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.developer_directory = self.root / "Xcode.app" / "Contents" / "Developer"
        self.developer_directory.mkdir(parents=True)
        workspace_data = self.root / "GitX.xcworkspace" / "xcshareddata" / "swiftpm"
        workspace_data.mkdir(parents=True)
        (workspace_data / "Package.resolved").write_text("{}\n")
        test_directory = self.root / "GitXTests"
        test_directory.mkdir()
        for plan in (
            "GitX",
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

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def install_script(self, name: str) -> pathlib.Path:
        destination = self.scripts / name
        shutil.copy2(ROOT / "scripts" / name, destination)
        if name == "xcodebuild.sh":
            for dependency in ("doctor.sh", "verification_support.py", "verification-config.json"):
                shutil.copy2(ROOT / "scripts" / dependency, self.scripts / dependency)
        return destination

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
            "derived=''\n"
            "for ((index = 0; index < ${#arguments[@]}; index++)); do\n"
            "  if [[ \"${arguments[$index]}\" == '-derivedDataPath' ]]; then\n"
            "    derived=${arguments[$((index + 1))]}\n"
            "    app=\"$derived/Build/Products/Debug/GitX.app\"\n"
            "    mkdir -p \"$app/Contents/MacOS\" \"$app/Contents/Resources\"\n"
            "    printf '#!/bin/bash\\n' >\"$app/Contents/MacOS/GitX\"\n"
            "    chmod +x \"$app/Contents/MacOS/GitX\"\n"
            "    printf 'staged\\n' >\"$app/Contents/Resources/fixture.txt\"\n"
            "    /usr/bin/plutil -create xml1 \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/plutil -insert CFBundleExecutable -string GitX \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/plutil -insert CFBundleIdentifier -string com.gitx.test \"$app/Contents/Info.plist\"\n"
            "    /usr/bin/codesign --force --sign - \"$app\" >/dev/null 2>&1\n"
            "  fi\n"
            "  case \"${arguments[$index]}\" in\n"
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
            "fi\n"
            "if [[ \"${MOCK_XCODEBUILD_EXIT_STATUS:-0}\" != 0 && \" $* \" == *' analyze '* ]]; then\n"
            "  exit \"$MOCK_XCODEBUILD_EXIT_STATUS\"\n"
            "fi\n"
        )
        mock.chmod(0o755)
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
        executable = self.root / "GitX"
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
            if argument == "-resultBundlePath"
        ]
        self.assertEqual(len(result_bundles), 2)
        self.assertEqual(len(set(result_bundles)), 2)
        logs = list((self.root / "artifacts" / "verification").glob("*/Logs/raw.log"))
        self.assertEqual(len(logs), 2)

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

    def test_ui_preflight_forwards_non_selection_extras_only(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
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
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

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
        executable = self.root / "GitX"
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

    def test_run_app_stop_refuses_an_unverifiable_legacy_pid_only_record(self) -> None:
        script = self.install_script("run_app.sh")
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        executable = self.root / "GitX"
        executable.symlink_to("/bin/sleep")
        process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, process)
        (session_directory / "app.pid").write_text(f"{process.pid}\n")

        result = subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIsNone(process.poll())
        self.assertFalse((session_directory / "app.pid").exists())
        self.assertIn("process identity cannot be verified", result.stderr)

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


if __name__ == "__main__":
    unittest.main()
