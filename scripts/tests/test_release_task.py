from __future__ import annotations

import os
import pathlib
import subprocess
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
        result = subprocess.run(
            [self.task, "x86_64"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown argument: x86_64", result.stderr)


if __name__ == "__main__":
    unittest.main()
