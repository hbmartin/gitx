from __future__ import annotations

import pathlib
import os
import subprocess
import textwrap
import hashlib
import tempfile
import unittest

from distribution_fixture import DistributionFixture
from support import ROOT, load_script


class DistributionTests(unittest.TestCase):
    def homebrew_step(self, directory):
        workflow = (ROOT / ".github/workflows/BuildPR.yml").read_text()
        step = workflow.split("- name: Update Homebrew cask", 1)[1].split("- name:", 1)[0]
        script = textwrap.dedent(step.split("run: |", 1)[1])
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
                              cwd=directory, env=os.environ | {"RELEASE_TAG": "1.2.3"}, capture_output=True, text=True)

    def test_homebrew_hashes_downloaded_dmg_and_writes_its_actual_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "distribution").mkdir()
            (root / "brew/Casks/g").mkdir(parents=True)
            dmg = root / "distribution/HalfDark-arm64.dmg"
            dmg.write_bytes(b"downloaded distribution fixture")
            result = self.homebrew_step(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cask = (root / "brew/Casks/g/gitx.rb").read_text()
            self.assertIn('sha256 "' + hashlib.sha256(dmg.read_bytes()).hexdigest() + '"', cask)
            self.assertIn('version "1.2.3"', cask)

    def test_homebrew_missing_download_fails_before_cask_creation_even_with_root_decoy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "distribution").mkdir()
            (root / "brew/Casks/g").mkdir(parents=True)
            (root / "HalfDark-arm64.dmg").write_bytes(b"stale root artifact")
            result = self.homebrew_step(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "brew/Casks/g/gitx.rb").exists())

    def test_ci_packages_only_after_stapling_and_keeps_diagnostics_without_comparison(self):
        workflow = (ROOT / ".github/workflows/BuildPR.yml").read_text()
        self.assertIn("scripts/package_distribution.sh", workflow)
        self.assertLess(workflow.index('xcrun stapler staple "$APP_PATH"'), workflow.index("scripts/package_distribution.sh"))
        self.assertNotIn("screenShotCompare", workflow)
        self.assertNotIn("Checkout fixed repo snapshot", workflow)
        self.assertIn("scripts/extract_screenshots.py", workflow)
        self.assertIn("name: Upload screenshots", workflow)

    def test_release_validates_original_and_both_packaged_apps(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.release()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            validations = [command[-1] for command in fixture.commands if command[:3] == ["xcrun", "stapler", "validate"]]
            self.assertEqual(len(validations), 3)
            self.assertIn("HalfDark-arm64/Half Dark.app", validations[0])
            self.assertIn("/zip/", validations[1])
            self.assertIn("/mounted-dmg/", validations[2])
            for suffix in ("zip", "dmg", "sha256"):
                self.assertTrue((fixture.output / f"HalfDark-arm64.{suffix}").exists())

    def test_unverified_app_never_reaches_packaging(self):
        for failure in ("signature", "ticket", "gatekeeper"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.release(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(command[:2] == ["hdiutil", "create"] for command in fixture.commands))
                self.assertFalse((fixture.output / "HalfDark-arm64.sha256").exists())

    def test_failed_mounted_payload_validation_detaches_without_publishing_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.release("mounted")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(any(command[:2] == ["hdiutil", "detach"] for command in fixture.commands))
            self.assertFalse((fixture.output / "HalfDark-arm64.sha256").exists())

    def test_direct_packager_validates_input_zip_and_dmg_and_reports_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.package(outputs=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            validations = [command[-1] for command in fixture.commands if command[:3] == ["xcrun", "stapler", "validate"]]
            self.assertEqual(len(validations), 3)
            self.assertEqual(validations[0], str(fixture.root / "Source.app"))
            self.assertIn("/zip/", validations[1])
            self.assertIn("/mounted-dmg/", validations[2])
            outputs = dict(line.split("=", 1) for line in (fixture.root / "outputs").read_text().splitlines())
            self.assertEqual(set(outputs), {"zip_path", "dmg_path", "checksum_path"})
            for path in outputs.values():
                self.assertTrue(pathlib.Path(path).is_file())
            checksums = pathlib.Path(outputs["checksum_path"]).read_text().splitlines()
            self.assertEqual(len(checksums), 2)
            for line in checksums:
                digest, name = line.split("  ", 1)
                artifact = fixture.output / name
                self.assertEqual(digest, hashlib.sha256(artifact.read_bytes()).hexdigest())
            for stage in ("input", "zip", "dmg"):
                self.assertIn(stage + ": verified", result.stdout)

    def test_each_validation_stage_fails_without_publishing_and_releases_mounts(self):
        for stage in ("input", "zip", "dmg"):
            for check in ("signature", "ticket", "gatekeeper"):
                with self.subTest(stage=stage, check=check), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    result = fixture.package(check + ":" + stage, outputs=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(stage + ":", result.stdout + result.stderr)
                    self.assertFalse((fixture.root / "outputs").exists())
                    self.assertFalse(list(fixture.output.glob("HalfDark-*")))
                    self.assertFalse((fixture.root / "mount.json").exists())
                    self.assertFalse(list(fixture.output.glob(".gitx-package.*")))
                    if stage == "input":
                        self.assertFalse(any(command[0] == "ditto" for command in fixture.commands))

    def test_attach_failures_clean_only_confirmed_mounts_and_preserve_original_status(self):
        for failure, status, detaches in (("attach", 13, 0), ("partial-attach", 14, 1), ("unmounted-attach", 14, 1)):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.package(failure)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(sum(command[:2] == ["hdiutil", "detach"] for command in fixture.commands), detaches)
                self.assertFalse(list(fixture.output.iterdir()))
                self.assertFalse((fixture.root / "mount.json").exists())

    def test_unknown_mount_state_and_detach_failure_retain_staging_without_publication(self):
        for failure in ("mount-info", "detach"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.package(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("retained", result.stderr)
                self.assertTrue(list(fixture.output.glob(".gitx-package.*")))
                self.assertFalse(list(fixture.output.glob("HalfDark-*")))

    def test_fixture_python_is_independent_of_the_developer_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            fixture.environment["PATH"] = str(fixture.root / "tools") + ":/usr/bin:/bin:/usr/sbin:/sbin"
            fixture.environment["DEVELOPER_DIR"] = "/fixture/Developer"
            result = fixture.release()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_notarization_fetches_rejection_diagnostics_even_when_submit_fails(self):
        for failure, status in (("notary-invalid", 1), ("notary-invalid,notary-transport", 21)):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.notarize(failure, optimized=True)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertIn("fixture diagnostic", result.stdout)
                self.assertTrue((fixture.root / "notary-logs/notary-submission.json").exists())
                self.assertTrue(any(command[:3] == ["xcrun", "notarytool", "log"] for command in fixture.commands))

    def test_notarization_requires_accepted_well_formed_response_and_id(self):
        for failure in ("", "notary-malformed", "notary-empty", "notary-missing-id", "notary-invalid,notary-log", "notary-log"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.notarize(failure)
                self.assertEqual(result.returncode == 0, failure in ("", "notary-log"), result.stdout + result.stderr)
                if "notary-log" in failure:
                    self.assertIn("Could not fetch", result.stderr)

    def test_screenshot_fallback_ignores_bundle_metadata_and_exports_only_png_data(self):
        extractor = load_script("extract_screenshots.py")
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Result.xcresult"
            attachments = bundle / "Attachments"
            attachments.mkdir(parents=True)
            output = pathlib.Path(directory) / "screenshots"
            output.mkdir()
            (bundle / "Info.plist").write_text("result bundle metadata")
            (attachments / "opaque").write_bytes(b"binary result data")
            (attachments / "misleading.png").write_text("not an image")
            self.assertEqual(extractor.export_via_filesystem(str(bundle), str(output)), 0)
            self.assertFalse(list(output.iterdir()), "A failed test without screenshots must not produce a screenshot artifact")
            png = b"\x89PNG\r\n\x1a\nfixture attachment"
            (attachments / "screen.data").write_bytes(png)
            self.assertEqual(extractor.export_via_filesystem(str(bundle), str(output)), 1)
            self.assertEqual([path.name for path in output.iterdir()], ["screen.png"])
            self.assertEqual((output / "screen.png").read_bytes(), png)

    def test_ci_guards_screenshots_and_publishes_all_packager_outputs(self):
        workflow = (ROOT / ".github/workflows/BuildPR.yml").read_text()
        extract = workflow.split("- name: Extract screenshots", 1)[1].split("- name: Upload screenshots", 1)[0]
        self.assertIn("!cancelled()", extract)
        self.assertIn("steps.ui-tests.outcome != 'skipped'", extract)
        self.assertIn("hashFiles", extract)
        self.assertNotIn("success()", extract)
        upload = workflow.split("- name: Upload screenshots", 1)[1].split("- name: Build project", 1)[0]
        self.assertIn("hashFiles", upload)
        self.assertIn("**/*.png", upload)
        self.assertIn("screenshots-${{ matrix.abi }}/*.png", upload)
        self.assertIn("!cancelled()", upload)
        for output in ("zip_path", "dmg_path", "checksum_path"):
            self.assertIn("steps.package.outputs." + output, workflow)
        self.assertIn("name: HalfDark-arm64-distribution", workflow)
        self.assertIn("distribution/*", workflow)
        self.assertIn("scripts/notarize_distribution.sh", workflow)
        self.assertNotIn("assert result", workflow)


if __name__ == "__main__":
    unittest.main()
