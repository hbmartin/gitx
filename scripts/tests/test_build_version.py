from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ROOT, fixture_git_environment
from unittest import mock


class BuildVersionTests(unittest.TestCase):
    def test_fixture_ignores_foreign_checkout_and_signing_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            foreign = Path(directory)
            subprocess.run(["git", "init", "-q", foreign], check=True, env=fixture_git_environment())
            config = (foreign / ".git/config").read_bytes()
            selectors = {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                         "GIT_INDEX_FILE": str(foreign / ".git/foreign-index"),
                         "GIT_CONFIG_PARAMETERS": "'commit.gpgsign=true'"}
            with mock.patch.dict(os.environ, selectors):
                info = self.run_version_script("v2.4.6", dirty=True)
            self.assertTrue(str(info["CFBundleVersion"]).startswith("2.4.6.1 ["))
            self.assertEqual((foreign / ".git/config").read_bytes(), config)
            self.assertFalse((foreign / ".git/foreign-index").exists())

    def run_version_script(self, tag: str | None = None, *, repeat: bool = False, dirty: bool = False) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            fixture_environment = fixture_git_environment()
            subprocess.run(
                ["git", "init", "--initial-branch", "main"],
                cwd=repository,
                env=fixture_environment,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "GitX Tests"],
                cwd=repository,
                env=fixture_environment,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "gitx-tests@example.invalid"],
                cwd=repository,
                env=fixture_environment,
                check=True,
            )
            (repository / "tracked.txt").write_text("content\n")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repository, env=fixture_environment, check=True)
            subprocess.run(
                ["git", "commit", "-m", "Initial"],
                cwd=repository,
                env=fixture_environment,
                check=True,
                capture_output=True,
                text=True,
            )
            if tag is not None:
                subprocess.run(["git", "tag", tag], cwd=repository, env=fixture_environment, check=True)

            info_plist = repository / "Info.plist"
            with info_plist.open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleShortVersionString": "0",
                        "CFBundleVersion": "0",
                    },
                    stream,
                )
            environment = fixture_environment.copy()
            environment.update(
                {
                    "TARGET_BUILD_DIR": str(repository),
                    "INFOPLIST_PATH": info_plist.name,
                }
            )
            if dirty:
                (repository / "tracked.txt").write_text("modified\n")
            subprocess.run(
                [str(ROOT / "scripts" / "set_build_version.sh")],
                cwd=repository,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            if repeat:
                os.utime(info_plist, ns=(123000000000, 123000000000))
                before = info_plist.stat().st_mtime_ns
                contents = info_plist.read_bytes()
                subprocess.run([str(ROOT / "scripts" / "set_build_version.sh")], cwd=repository,
                               env=environment, check=True, capture_output=True, text=True)
                self.assertEqual(info_plist.read_bytes(), contents)
                self.assertEqual(info_plist.stat().st_mtime_ns, before)
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

    def test_unchanged_version_does_not_rewrite_the_plist(self) -> None:
        self.run_version_script("v2.4.6", repeat=True)

    def test_dirty_state_remains_visible_without_repeated_writes(self) -> None:
        info = self.run_version_script(dirty=True, repeat=True)
        self.assertIn("-dirty-main", info["CFBundleBuildVersion"])

    def test_xcode_build_phase_invokes_the_checked_in_script(self) -> None:
        project = (ROOT / "GitX.xcodeproj" / "project.pbxproj").read_text()
        script = ROOT / "scripts" / "set_build_version.sh"

        self.assertIn("${SRCROOT}/scripts/set_build_version.sh", project)
        self.assertNotIn("LATEST_TAG=$(git describe", project)
        self.assertTrue(os.access(script, os.X_OK))
