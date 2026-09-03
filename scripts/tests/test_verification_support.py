from __future__ import annotations

import argparse
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from support import ROOT, load_script


verification = load_script("verification_support.py")


class VersionTests(unittest.TestCase):
    def test_minimum_version_accepts_patch_and_newer_major_versions(self) -> None:
        self.assertTrue(verification.version_at_least("26.6", "26.6"))
        self.assertTrue(verification.version_at_least("26.6.1", "26.6"))
        self.assertTrue(verification.version_at_least("27.0 beta", "26.6"))

    def test_minimum_version_rejects_older_versions(self) -> None:
        self.assertFalse(verification.version_at_least("26.5", "26.6"))
        self.assertFalse(verification.version_at_least("25.4.1", "26.6"))

    def test_run_ids_reject_path_components(self) -> None:
        arguments = argparse.Namespace(value="../shared")

        self.assertEqual(verification.command_run_id(arguments), 2)


class ReceiptTests(unittest.TestCase):
    def test_secret_arguments_are_redacted_without_recording_the_environment(self) -> None:
        scrubbed = verification.scrub_arguments(
            ["build", "TOKEN=private", "--password", "also-private", "SAFE=value"]
        )

        self.assertEqual(
            scrubbed,
            ["build", "TOKEN=<redacted>", "--password", "<redacted>", "SAFE=value"],
        )

    def test_atomic_json_replaces_a_complete_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "receipt.json"
            verification.atomic_json(path, {"schemaVersion": 1, "status": "running"})
            verification.atomic_json(path, {"schemaVersion": 1, "status": "passed"})

            payload = json.loads(path.read_text())

        self.assertEqual(payload, {"schemaVersion": 1, "status": "passed"})

    def test_artifacts_inside_the_repository_are_recorded_relatively(self) -> None:
        path = ROOT / "artifacts" / "verification" / "run" / "receipt.json"

        self.assertEqual(
            verification.relative_artifact(str(path)),
            "artifacts/verification/run/receipt.json",
        )

    def test_failed_command_step_has_machine_readable_failure_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "receipt.json"
            path.write_text('{"steps": [], "artifacts": []}')
            arguments = argparse.Namespace(
                path=path,
                name="smoke",
                status="failed",
                exit_code=65,
                duration=1.25,
                command=["xcodebuild", "build"],
                log=None,
                xcresult=None,
            )

            verification.command_receipt_step(arguments)
            step = json.loads(path.read_text())["steps"][0]

        self.assertEqual(step["failureCategory"], "command")
        self.assertIsNone(step["testCounts"])
        self.assertIsNone(step["coverage"])


class DoctorTests(unittest.TestCase):
    def test_missing_supported_xcode_is_a_failed_check(self) -> None:
        with mock.patch.object(verification, "resolve_developer_dir", return_value=None), mock.patch.object(
            verification, "developer_dir_candidates", return_value=[]
        ), mock.patch.object(verification.shutil, "which", return_value="/usr/bin/tool"), mock.patch.object(
            verification, "git_output", return_value=""
        ):
            payload = verification.doctor_payload("build")

        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["checks"][0]["name"], "xcode")
        self.assertEqual(payload["checks"][0]["status"], "failed")

    def test_config_names_every_shared_test_plan(self) -> None:
        plans = verification.load_config()["testPlans"]

        self.assertEqual(
            set(plans),
            {
                "correctness",
                "ui-preflight",
                "ui",
                "address-undefined",
                "thread-sanitizer",
                "performance",
            },
        )


class WrapperContractTests(unittest.TestCase):
    def test_wrapper_owns_all_build_output_paths(self) -> None:
        wrapper = (ROOT / "scripts" / "xcodebuild.sh").read_text()

        self.assertIn('run_dir="$root/$artifact_root/$run_id"', wrapper)
        self.assertIn('-derivedDataPath "$derived_data"', wrapper)
        self.assertIn('-resultBundlePath "$result"', wrapper)
        self.assertIn("-clonedSourcePackagesDirPath", wrapper)
        self.assertIn("-archivePath", wrapper)
        self.assertIn("is managed by scripts/xcodebuild.sh", wrapper)

    def test_run_app_uses_the_named_build_preset(self) -> None:
        script = (ROOT / "scripts" / "run_app.sh").read_text()

        self.assertIn("xcodebuild.sh\" build --configuration Debug --stage-app", script)


if __name__ == "__main__":
    unittest.main()
