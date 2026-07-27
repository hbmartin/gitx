from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

from support import ROOT


class ReleaseTaskTests(unittest.TestCase):
    @property
    def task(self) -> pathlib.Path:
        return ROOT / "mise-tasks" / "release"

    def test_release_task_is_executable(self) -> None:
        self.assertTrue(self.task.is_file())
        self.assertTrue(os.access(self.task, os.X_OK))

    def test_release_task_has_valid_bash_syntax(self) -> None:
        subprocess.run(["bash", "-n", self.task], check=True)

    def test_release_task_documents_the_single_command_and_artifacts(self) -> None:
        result = subprocess.run(
            [self.task, "--help"],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("mise run release", result.stdout)
        self.assertNotIn("x86_64", result.stdout)
        self.assertNotIn("universal", result.stdout)
        self.assertNotIn("GITX_RELEASE_ARCH", result.stdout)
        self.assertIn("Developer ID", result.stdout)
        self.assertIn("GitX-arm64.zip", result.stdout)
        self.assertIn("GitX-arm64.dmg", result.stdout)

    def test_release_task_rejects_architecture_arguments(self) -> None:
        for arch in ("x86_64", "arm64", "universal"):
            with self.subTest(arch=arch):
                result = subprocess.run(
                    [self.task, arch],
                    check=False,
                    capture_output=True,
                    text=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Unknown argument: {arch}", result.stderr)

    def test_release_check_validates_export_options(self) -> None:
        result = subprocess.run(
            [self.task, "--check"],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("Export options plist passed validation", result.stdout)

    def test_release_check_rejects_a_missing_development_team(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mock_xcodebuild = pathlib.Path(directory) / "xcodebuild"
            mock_xcodebuild.write_text(
                "#!/bin/sh\n"
                "cat <<'EOF'\n"
                "    CODE_SIGN_STYLE = Automatic\n"
                "    ENABLE_HARDENED_RUNTIME = YES\n"
                "    PRODUCT_BUNDLE_IDENTIFIER = net.phere.GitX\n"
                "EOF\n"
            )
            mock_xcodebuild.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{directory}:{environment['PATH']}"

            result = subprocess.run(
                [self.task, "--check"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release has no DEVELOPMENT_TEAM", result.stderr)


if __name__ == "__main__":
    unittest.main()
