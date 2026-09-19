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
            "printf '%s\\n' \"$@\" >>\"$CAPTURED_ARGUMENTS\"\n"
            "arguments=(\"$@\")\n"
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
            "done\n"
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

        arguments = captured.read_text().splitlines()
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

        arguments = captured.read_text().splitlines()
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

    @staticmethod
    def _terminate_process(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
