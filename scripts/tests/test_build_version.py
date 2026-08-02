from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ROOT


class BuildVersionTests(unittest.TestCase):
    def run_version_script(self, tag: str | None = None) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(
                ["git", "init", "--initial-branch", "main"],
                cwd=repository,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "GitX Tests"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "gitx-tests@example.invalid"],
                cwd=repository,
                check=True,
            )
            (repository / "tracked.txt").write_text("content\n")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repository, check=True)
            subprocess.run(
                ["git", "commit", "-m", "Initial"],
                cwd=repository,
                check=True,
                capture_output=True,
                text=True,
            )
            if tag is not None:
                subprocess.run(["git", "tag", tag], cwd=repository, check=True)

            info_plist = repository / "Info.plist"
            with info_plist.open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleShortVersionString": "0",
                        "CFBundleVersion": "0",
                    },
                    stream,
                )
            environment = os.environ.copy()
            environment.update(
                {
                    "TARGET_BUILD_DIR": str(repository),
                    "INFOPLIST_PATH": info_plist.name,
                }
            )
            subprocess.run(
                [str(ROOT / "scripts" / "set_build_version.sh")],
                cwd=repository,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            with info_plist.open("rb") as stream:
                return plistlib.load(stream)

    def test_tagless_checkout_uses_zero_version_fallback(self) -> None:
        info = self.run_version_script()

        self.assertTrue(str(info["CFBundleVersion"]).startswith("0.0.1 ["))
        self.assertEqual(
            info["CFBundleBuildVersion"],
            info["CFBundleShortVersionString"],
        )

    def test_tagged_checkout_preserves_release_version(self) -> None:
        info = self.run_version_script("v2.4.6")

        self.assertTrue(str(info["CFBundleVersion"]).startswith("2.4.6.1 ["))

    def test_xcode_build_phase_invokes_the_checked_in_script(self) -> None:
        project = (ROOT / "GitX.xcodeproj" / "project.pbxproj").read_text()
        script = ROOT / "scripts" / "set_build_version.sh"

        self.assertIn("${SRCROOT}/scripts/set_build_version.sh", project)
        self.assertNotIn("LATEST_TAG=$(git describe", project)
        self.assertTrue(os.access(script, os.X_OK))
