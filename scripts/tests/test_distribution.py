from __future__ import annotations

import pathlib
import os
import subprocess
import textwrap
import hashlib
import json
import shutil
import tempfile
import unittest
import sys

from distribution_fixture import DistributionFixture
from support import ROOT, load_script


class DistributionTests(unittest.TestCase):
    def homebrew_step(self, directory):
        scripts = pathlib.Path(directory) / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "scripts/distribution_artifact_names.sh", scripts)
        workflow = (ROOT / ".github/workflows/BuildPR.yml").read_text()
        step = workflow.split("- name: Update Homebrew cask", 1)[1].split("- name:", 1)[0]
        script = textwrap.dedent(step.split("run: |", 1)[1])
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-c", script],
                              cwd=directory, env=os.environ | {"RELEASE_TAG": "1.2.3"}, capture_output=True, text=True)

    def test_unrelated_optional_device_metadata_cannot_block_owned_image_cleanup(self):
        for image_path in ("/unrelated/another.dmg", "ram://128000"):
            for device in ("/dev/unrelated", "", 42):
                with self.subTest(image_path=image_path, device=device), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    (fixture.root / "additional-images.json").write_text(json.dumps([{
                        "image-path": image_path,
                        "system-entities": [{"mount-point": "/Volumes/Unrelated", "dev-entry": device}],
                    }]))
                    result = fixture.package()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(list(fixture.output.glob(".gitx-package.*")))
                    self.assertTrue((fixture.output / "HalfDark-arm64.sha256").exists())
                    self.assertEqual([command[2] for command in fixture.commands if command[:2] == ["hdiutil", "detach"]], ["/dev/fixture-disk"])

    def test_unidentified_images_and_malformed_unrelated_mountpoints_remain_unknown(self):
        images = [
            {"system-entities": [{"mount-point": "/Volumes/Unrelated", "dev-entry": "/dev/unrelated"}]},
            {"image-path": "ram://128000", "system-entities": [{"mount-point": 42}]},
            {"image-path": "/unrelated/another.dmg", "system-entities": [{"mount-point": ""}]},
        ]
        for image in images:
            with self.subTest(image=image), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                (fixture.root / "additional-images.json").write_text(json.dumps([image]))
                result = fixture.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Mount state is unknown", result.stderr)
                self.assertTrue(list(fixture.output.glob(".gitx-package.*")))
                self.assertFalse(list(fixture.output.glob("*.sha256")))
                self.assertFalse(any(command[:2] == ["hdiutil", "detach"] for command in fixture.commands))

    def write_distribution(self, root):
        distribution = root / "distribution"
        distribution.mkdir()
        (root / "brew/Casks/g").mkdir(parents=True)
        lines = []
        for suffix in ("zip", "dmg"):
            artifact = distribution / ("HalfDark-arm64." + suffix)
            artifact.write_bytes(("downloaded fixture " + suffix).encode())
            lines.append(hashlib.sha256(artifact.read_bytes()).hexdigest() + "  " + artifact.name)
        manifest = distribution / "HalfDark-arm64.sha256"
        manifest.write_text("\n".join(lines) + "\n")
        return manifest

    def test_homebrew_hashes_downloaded_dmg_and_writes_its_actual_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write_distribution(root)
            dmg = root / "distribution/HalfDark-arm64.dmg"
            result = self.homebrew_step(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cask = (root / "brew/Casks/g/gitx.rb").read_text()
            self.assertIn('sha256 "' + hashlib.sha256(dmg.read_bytes()).hexdigest() + '"', cask)
            self.assertIn('version "1.2.3"', cask)

    def test_homebrew_rejects_invalid_packaged_evidence_before_cask_creation(self):
        for failure in ("missing-manifest", "duplicate-dmg", "malformed-digest", "changed-dmg", "missing-zip"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                manifest = self.write_distribution(root)
                if failure == "missing-manifest":
                    manifest.unlink()
                elif failure == "duplicate-dmg":
                    manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[1] + "\n")
                elif failure == "malformed-digest":
                    manifest.write_text("invalid  HalfDark-arm64.dmg\n")
                elif failure == "changed-dmg":
                    (root / "distribution/HalfDark-arm64.dmg").write_bytes(b"changed after packaging")
                else:
                    (root / "distribution/HalfDark-arm64.zip").unlink()
                result = self.homebrew_step(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "brew/Casks/g/gitx.rb").exists())

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
            self.assertEqual(len(validations), 4)
            self.assertIn("/Notarized/Half Dark.app", validations[0])
            self.assertIn("/.gitx-release-app.", validations[1])
            self.assertIn("/zip/", validations[2])
            self.assertIn("/mounted-dmg/", validations[3])
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

    def test_failed_release_never_promotes_an_unverified_app_or_replaces_previous_app(self):
        for failure in ("signature", "ticket", "gatekeeper", "signature:input", "signature:zip", "mounted"):
            for previous in (False, True):
                with self.subTest(failure=failure, previous=previous), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    final = fixture.output / "HalfDark-arm64/Half Dark.app"
                    if previous:
                        (final / "Contents/MacOS").mkdir(parents=True)
                        (final / "Contents/MacOS/GitX").write_bytes(b"previous verified app")
                    result = fixture.release(failure)
                    self.assertNotEqual(result.returncode, 0)
                    if previous:
                        self.assertEqual((final / "Contents/MacOS/GitX").read_bytes(), b"previous verified app")
                    else:
                        self.assertFalse(final.exists())

    def test_successful_release_promotes_the_validated_app_and_removes_its_private_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            final = fixture.output / "HalfDark-arm64/Half Dark.app"
            (final / "Contents/MacOS").mkdir(parents=True)
            (final / "Contents/MacOS/GitX").write_bytes(b"previous verified app")
            result = fixture.release()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((final / "Contents/MacOS/GitX").read_bytes(), b"#!/bin/sh\nexit 0\n")
            self.assertFalse(list(fixture.output.glob(".gitx-release-*")))

    def test_ambiguous_mount_inventory_retains_staging_and_never_detaches_foreign_devices(self):
        for releasing in (False, True):
            for failure in ("missing-images", "foreign-mount", "empty-image-identity", "conflicting-devices", "duplicate-owned-image", "malformed-entity", "unrelated-conflicting-mount", "empty-owned-device"):
                with self.subTest(releasing=releasing, failure=failure), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    result = fixture.release(failure) if releasing else fixture.package(failure)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("retained", result.stderr)
                    self.assertTrue(list(fixture.output.rglob(".gitx-package.*")))
                    self.assertFalse(any(command[:2] == ["hdiutil", "detach"] for command in fixture.commands))

    def test_successful_detach_must_prove_image_absence_before_cleanup_or_publication(self):
        for releasing in (False, True):
            with self.subTest(releasing=releasing), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.release("detach-still-attached") if releasing else fixture.package("detach-still-attached")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("retained", result.stderr)
                self.assertTrue(list(fixture.output.rglob(".gitx-package.*")))
                self.assertFalse(list(fixture.output.glob("*.sha256")))

    def test_publication_failure_restores_the_complete_previous_artifact_set(self):
        for failing_rename in (1, 2, 3):
            for previous in (False, True):
                with self.subTest(failing_rename=failing_rename, previous=previous), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    fixture.output.mkdir()
                    names = ("HalfDark-arm64.zip", "HalfDark-arm64.dmg", "HalfDark-arm64.sha256")
                    original = {name: ("previous " + name).encode() for name in names} if previous else {}
                    for name, content in original.items(): (fixture.output / name).write_bytes(content)
                    result = fixture.package("publish-failure-" + str(failing_rename), outputs=True)
                    self.assertNotEqual(result.returncode, 0)
                    actual = {name: (fixture.output / name).read_bytes() for name in names if (fixture.output / name).exists()}
                    self.assertEqual(actual, original)
                    self.assertFalse((fixture.root / "outputs").exists())
                    self.assertFalse(list(fixture.output.glob(".gitx-package.*")))

    def test_failed_rollback_retains_original_artifacts_for_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            fixture.output.mkdir()
            names = ("HalfDark-arm64.zip", "HalfDark-arm64.dmg", "HalfDark-arm64.sha256")
            original = {name: ("previous " + name).encode() for name in names}
            for name, content in original.items(): (fixture.output / name).write_bytes(content)
            result = fixture.package("publish-and-restore-failure", outputs=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Could not restore", result.stderr)
            staging, = fixture.output.glob(".gitx-package.*")
            self.assertEqual((staging / "previous" / names[0]).read_bytes(), original[names[0]])
            self.assertEqual((staging / "previous" / names[1]).read_bytes(), original[names[1]])
            self.assertEqual((fixture.output / names[2]).read_bytes(), original[names[2]])
            self.assertFalse((fixture.root / "outputs").exists())

    def test_nonregular_artifact_destinations_preserve_all_previous_outputs(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                fixture.output.mkdir()
                zip_path = fixture.output / "HalfDark-arm64.zip"
                zip_path.write_bytes(b"previous zip")
                blocked = fixture.output / "HalfDark-arm64.dmg"
                sentinel = fixture.root / "unrelated"
                sentinel.write_bytes(b"unrelated content")
                if symlink: blocked.symlink_to(sentinel)
                else: blocked.mkdir()
                result = fixture.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(zip_path.read_bytes(), b"previous zip")
                self.assertEqual(sentinel.read_bytes(), b"unrelated content")
                self.assertTrue(blocked.is_symlink() if symlink else blocked.is_dir())
                self.assertFalse(list(fixture.output.glob(".gitx-package.*")))

    def test_release_promotion_failure_restores_app_and_all_matching_packages(self):
        for failing_rename in (1, 2, 3, 4):
            for previous in (False, True):
                with self.subTest(failing_rename=failing_rename, previous=previous), tempfile.TemporaryDirectory() as directory:
                    fixture = DistributionFixture(pathlib.Path(directory))
                    fixture.output.mkdir()
                    names = ("HalfDark-arm64.zip", "HalfDark-arm64.dmg", "HalfDark-arm64.sha256")
                    original = {name: ("previous " + name).encode() for name in names} if previous else {}
                    final = fixture.output / "HalfDark-arm64/Half Dark.app/Contents/MacOS/GitX"
                    if previous:
                        final.parent.mkdir(parents=True)
                        final.write_bytes(b"previous app")
                    for name, content in original.items(): (fixture.output / name).write_bytes(content)
                    result = fixture.release("release-promotion-failure-" + str(failing_rename))
                    self.assertNotEqual(result.returncode, 0)
                    actual = {name: (fixture.output / name).read_bytes() for name in names if (fixture.output / name).exists()}
                    self.assertEqual(actual, original)
                    if previous: self.assertEqual(final.read_bytes(), b"previous app")
                    else: self.assertFalse(final.exists())
                    self.assertFalse(list(fixture.output.glob(".gitx-release-*")))

    def test_failed_removal_during_release_rollback_keeps_the_original_app_in_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            fixture.output.mkdir()
            app = fixture.output / "HalfDark-arm64/Half Dark.app/Contents/MacOS/GitX"
            app.parent.mkdir(parents=True)
            app.write_bytes(b"previous app")
            for suffix in ("zip", "dmg", "sha256"):
                (fixture.output / f"HalfDark-arm64.{suffix}").write_bytes(b"previous artifact")
            rm = fixture.root / "tools/rm"
            rm.write_text("#!" + sys.executable + "\n" +
                          "import os,pathlib,subprocess,sys\n" +
                          'blocked = pathlib.Path(os.environ["GITX_DISTRIBUTION_FIXTURE"]) / "release/HalfDark-arm64"\n' +
                          'if pathlib.Path(sys.argv[-1]).resolve() == blocked.resolve(): sys.exit(25)\n' +
                          'sys.exit(subprocess.run(["/bin/rm", *sys.argv[1:]]).returncode)\n')
            rm.chmod(0o755)
            result = fixture.release("release-promotion-failure-2")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("could not be restored", result.stderr)
            staging, = fixture.output.glob(".gitx-release-app.*")
            backup = staging / "previous/HalfDark-arm64/Half Dark.app/Contents/MacOS/GitX"
            self.assertTrue(backup.exists(), "A failed cleanup must retain the original app in its recovery backup")
            self.assertEqual(backup.read_bytes(), b"previous app")
            self.assertFalse((fixture.output / "HalfDark-arm64/HalfDark-arm64").exists())

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

    def test_notarization_retries_the_same_submission_after_wait_and_status_transport_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.notarize("notary-retry")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = fixture.commands
            self.assertEqual(sum(command[:3] == ["xcrun", "notarytool", "submit"] for command in commands), 1)
            waits = [command for command in commands if command[:3] == ["xcrun", "notarytool", "wait"]]
            self.assertGreaterEqual(len(waits), 2)
            self.assertTrue(all(command[3] == "12345678-1234-1234-1234-123456789abc" for command in waits))
            self.assertTrue((fixture.root / "notary-logs/notary-info-1.stderr").exists())

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
