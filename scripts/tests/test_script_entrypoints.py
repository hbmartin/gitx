from __future__ import annotations

import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
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
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        self.install_sleeping_executable(app_contents / "MacOS" / "GitX")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
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
                return process, session_directory, temporary_root
            time.sleep(0.02)
        process.kill()
        process.communicate(timeout=2)
        self.fail("run_app.sh did not start both test processes")

    @staticmethod
    def process_is_running(pid: int) -> bool:
        status = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True
        ).stdout.strip()
        return bool(status) and "Z" not in status

    @staticmethod
    def terminate_pid(pid: int) -> None:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

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

        self.assertNotEqual(result.returncode, 0)
        receipt = self.receipt("invalid-explicit-toolchain")
        self.assertEqual(
            receipt["toolchain"]["developerDir"],
            str(self.root / "Missing-Xcode.app" / "Contents" / "Developer"),
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
        executable = self.root / "GitX"
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
        recorded_process = subprocess.Popen([self.root / "GitX", "60"])
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

    def test_run_app_launches_use_unique_forge_storage_roots(self) -> None:
        script = self.install_script("run_app.sh")
        self.install_mock_peekaboo()
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitX"
        app_binary.parent.mkdir(parents=True)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
        forge_roots = self.root / "forge-roots.txt"
        app_binary.write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$GITX_UITEST_FORGE_STORAGE_ROOT\" >>'{forge_roots}'\n"
            "exec /bin/sleep 60\n"
        )
        app_binary.chmod(0o755)
        log = self.bin / "log"
        log.write_text("#!/bin/bash\nexec /bin/sleep 60\n")
        log.chmod(0o755)
        environment = self.environment | {"TMPDIR": str(temporary_root)}
        sessions: list[dict[str, str]] = []

        try:
            for _ in range(2):
                subprocess.run(
                    [script, "--no-build", "--repo", str(repository), "--timeout", "2"],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=10,
                )
                session = dict(
                    line.split("=", maxsplit=1)
                    for line in (self.root / "build" / "Logs" / "run-app" / "session.txt")
                    .read_text()
                    .splitlines()
                )
                sessions.append(session)
                os.kill(int(session["app_pid"]), signal.SIGTERM)
                os.kill(int(session["log_pid"]), signal.SIGTERM)
                time.sleep(0.1)
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
                    try:
                        os.kill(int(session[key]), signal.SIGTERM)
                    except ProcessLookupError:
                        pass

        homes = [session["isolated_home"] for session in sessions]
        roots = forge_roots.read_text().splitlines()
        self.assertEqual(len(set(homes)), 2)
        self.assertEqual(len(set(roots)), 2)
        self.assertEqual(
            roots,
            [f"{home}/Library/Application Support/GitX/Forge" for home in homes],
        )
        self.assertFalse((self.root / "build" / "Logs" / "run-app" / "session.txt").exists())

    def test_run_app_cleans_an_isolated_home_when_launch_fails(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitX"
        app_binary.parent.mkdir(parents=True)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
        app_binary.write_text("#!/bin/bash\nexit 1\n")
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
                self.assertIn("owns the runtime session", result.stderr)
                self.assertTrue(self.process_is_running(app_pid))
                self.assertTrue(self.process_is_running(log_pid))
                self.assertEqual((session_directory / "session.txt").read_text(), session)
                self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)

    def test_run_app_interrupt_preserves_home_when_app_pid_record_is_missing(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "app.pid").unlink()

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertTrue(self.process_is_running(app_pid))
            self.assertTrue((session_directory / "session.txt").exists())
            self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_interrupt_preserves_home_when_app_pid_record_is_unverifiable(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "app.pid").write_text(f"{app_pid}\n")

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertTrue(self.process_is_running(app_pid))
            self.assertTrue((session_directory / "session.txt").exists())
            self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_run_app_interrupt_preserves_home_when_log_pid_record_is_missing(self) -> None:
        process, session_directory, temporary_root = self.start_pending_run_app_launch()
        app_pid = int((session_directory / "app.pid").read_text().split("\t", maxsplit=1)[0])
        log_pid = int((session_directory / "logstream.pid").read_text().split("\t", maxsplit=1)[0])
        self.addCleanup(self.terminate_pid, app_pid)
        self.addCleanup(self.terminate_pid, log_pid)
        (session_directory / "logstream.pid").unlink()

        try:
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=10)
            self.assertTrue(self.process_is_running(log_pid))
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
        self.install_sleeping_executable(app_contents / "MacOS" / "GitX")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
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
        log_pid = int(recorded_pid.read_text())
        self.addCleanup(self.terminate_pid, log_pid)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.process_is_running(log_pid))
        self.assertEqual(len(list(temporary_root.glob("gitx-run-app-home.*"))), 1)
        self.assertFalse((self.root / "build" / "Logs" / "run-app" / "session.txt").exists())

    def test_run_app_removes_home_when_log_exits_before_identity_can_be_recorded(self) -> None:
        script = self.install_script("run_app.sh")
        temporary_root = self.root / "runtime-tmp"
        temporary_root.mkdir()
        repository = self.root / "fixture-repo"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        app_contents = self.root / "build" / "GitX.app" / "Contents"
        app_binary = app_contents / "MacOS" / "GitX"
        app_binary.parent.mkdir(parents=True)
        app_binary.write_text("#!/bin/bash\nexit 0\n")
        app_binary.chmod(0o755)
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
        log = self.bin / "log"
        log.write_text("#!/bin/bash\nexit 0\n")
        log.chmod(0o755)
        ps = self.bin / "ps"
        ps.write_text(
            "#!/bin/bash\n"
            "if [[ \"$*\" == *'lstart='* ]]; then\n"
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
            timeout=10,
        )

        self.assertEqual(result.returncode, 1)
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
        self.install_sleeping_executable(app_contents / "MacOS" / "GitX")
        with (app_contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "net.phere.GitX.Tests"}, handle)
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


if __name__ == "__main__":
    unittest.main()
