from __future__ import annotations

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
        self.environment = os.environ.copy()
        self.environment["PATH"] = f"{self.bin}:{self.environment['PATH']}"
        self.environment["GITX_DEVELOPER_DIR"] = str(self.developer_directory)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def install_script(self, name: str) -> pathlib.Path:
        destination = self.scripts / name
        shutil.copy2(ROOT / "scripts" / name, destination)
        return destination

    def install_mock_xcodebuild(
        self,
        products_directory: pathlib.Path,
        *,
        version: str = "26.6",
    ) -> pathlib.Path:
        captured_arguments = self.root / "xcodebuild.args"
        mock = self.bin / "xcodebuild"
        mock.write_text(
            "#!/bin/bash\n"
            "if [[ \"${1:-}\" == '-version' ]]; then\n"
            f"  printf 'Xcode {version}\\nBuild version Test\\n'\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\\n' \"$@\" >>\"$CAPTURED_ARGUMENTS\"\n"
            "for argument in \"$@\"; do\n"
            "  if [[ \"$argument\" == '-showBuildSettings' ]]; then\n"
            "    printf '    BUILT_PRODUCTS_DIR = %s\\n' \"$PRODUCTS_DIRECTORY\"\n"
            "  fi\n"
            "done\n"
        )
        mock.chmod(0o755)
        self.environment["CAPTURED_ARGUMENTS"] = str(captured_arguments)
        self.environment["PRODUCTS_DIRECTORY"] = str(products_directory)
        return captured_arguments

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
        self.assertEqual(arguments[-1], "build")

    def test_xcodebuild_wrapper_stages_the_built_application(self) -> None:
        script = self.install_script("xcodebuild.sh")
        products = self.root / "Products"
        source_application = products / "GitX.app"
        source_application.mkdir(parents=True)
        (source_application / "fixture.txt").write_text("staged\n")
        self.install_mock_xcodebuild(products)

        subprocess.run(
            [script, "--raw", "--stage-app", "build"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertEqual((self.root / "build" / "GitX.app" / "fixture.txt").read_text(), "staged\n")

    def test_xcodebuild_wrapper_rejects_an_xcode_older_than_ci(self) -> None:
        script = self.install_script("xcodebuild.sh")
        self.install_mock_xcodebuild(self.root / "Products", version="26.5")

        result = subprocess.run(
            [script, "--raw", "build"],
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("26.6", result.stderr)

    def test_xcodebuild_wrapper_matches_options_as_exact_arguments(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        subprocess.run(
            [script, "--raw", "CUSTOM_TEXT=before -scheme after", "build"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertIn("-scheme", captured.read_text().splitlines())

    def test_xcodebuild_wrapper_uses_unique_logs_and_result_bundles(self) -> None:
        script = self.install_script("xcodebuild.sh")
        captured = self.install_mock_xcodebuild(self.root / "Products")

        for _ in range(2):
            subprocess.run(
                [script, "--raw", "test"],
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
        self.assertEqual(len(list((self.root / "build" / "Logs").glob("xcodebuild-*.log"))), 2)

    def test_xcodebuild_wrapper_propagates_a_staging_copy_failure(self) -> None:
        script = self.install_script("xcodebuild.sh")
        products = self.root / "Products"
        (products / "GitX.app").mkdir(parents=True)
        self.install_mock_xcodebuild(products)
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

    def test_run_app_stop_supports_a_legacy_pid_only_record(self) -> None:
        script = self.install_script("run_app.sh")
        session_directory = self.root / "build" / "Logs" / "run-app"
        session_directory.mkdir(parents=True)
        executable = self.root / "GitX"
        executable.symlink_to("/bin/sleep")
        process = subprocess.Popen([executable, "60"])
        self.addCleanup(self._terminate_process, process)
        (session_directory / "app.pid").write_text(f"{process.pid}\n")

        subprocess.run(
            [script, "--stop"],
            check=True,
            capture_output=True,
            text=True,
            env=self.environment,
        )

        self.assertEqual(process.wait(timeout=2), -15)
        self.assertFalse((session_directory / "app.pid").exists())

    @staticmethod
    def _terminate_process(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
