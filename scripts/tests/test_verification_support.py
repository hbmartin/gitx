from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
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

    def test_default_developer_directory_ignores_xcode_select_and_beta(self) -> None:
        config = {"defaultDeveloperDirectory": "/Applications/Xcode.app/Contents/Developer"}
        with mock.patch.dict(verification.os.environ, {}, clear=True):
            candidates = verification.developer_dir_candidates(config)

        self.assertEqual(candidates, [pathlib.Path(config["defaultDeveloperDirectory"])])

    def test_explicit_developer_directory_is_authoritative(self) -> None:
        config = {"defaultDeveloperDirectory": "/Applications/Xcode.app/Contents/Developer"}
        environment = {
            "GITX_DEVELOPER_DIR": "/Applications/Explicit.app/Contents/Developer",
            "DEVELOPER_DIR": "/Applications/SelectedBeta.app/Contents/Developer",
        }
        with mock.patch.dict(verification.os.environ, environment, clear=True):
            candidates = verification.developer_dir_candidates(config)

        self.assertEqual(candidates, [pathlib.Path(environment["GITX_DEVELOPER_DIR"])])

    def test_standard_developer_directory_is_authoritative_without_explicit_pin(self) -> None:
        config = {"defaultDeveloperDirectory": "/Applications/Xcode.app/Contents/Developer"}
        environment = {"DEVELOPER_DIR": "/Volumes/Tools/Xcode.app/Contents/Developer"}
        with mock.patch.dict(verification.os.environ, environment, clear=True):
            candidates = verification.developer_dir_candidates(config)

        self.assertEqual(candidates, [pathlib.Path(environment["DEVELOPER_DIR"])])

    def test_unusable_explicit_developer_directory_does_not_fall_back(self) -> None:
        config = {
            "defaultDeveloperDirectory": "/Applications/Xcode.app/Contents/Developer",
            "minimumXcodeVersion": "26.6",
        }
        explicit = pathlib.Path("/Applications/Broken.app/Contents/Developer")
        environment = {
            "GITX_DEVELOPER_DIR": str(explicit),
            "DEVELOPER_DIR": "/Applications/Usable.app/Contents/Developer",
        }
        with mock.patch.dict(verification.os.environ, environment, clear=True), mock.patch.object(
            verification, "xcode_version", return_value=None
        ) as version:
            selected = verification.resolve_developer_dir(config)

        self.assertIsNone(selected)
        version.assert_called_once_with(explicit)


class ReceiptTests(unittest.TestCase):
    def test_working_tree_fingerprint_includes_untracked_file_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            untracked = root / "untracked.txt"
            untracked.write_text("first contents\n")
            first = verification.working_tree_fingerprint(root)

            untracked.write_text("second contents\n")
            second = verification.working_tree_fingerprint(root)

        self.assertNotEqual(first, second)

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

    def test_receipt_step_preserves_missing_target_coverage_as_null(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            receipt = root / "receipt.json"
            result = root / "result.xcresult"
            result.mkdir()
            receipt.write_text('{"steps": [], "artifacts": []}')
            arguments = argparse.Namespace(
                path=receipt,
                name="correctness",
                status="passed",
                exit_code=0,
                duration=2.5,
                command=["xcodebuild", "test"],
                log=None,
                xcresult=str(result),
            )
            summary = subprocess.CompletedProcess(
                [], 0, stdout='{"totalTestCount": 1, "passedTests": 1}', stderr=""
            )
            coverage = subprocess.CompletedProcess(
                [], 0, stdout='{"targets": [{"name": "GitX.app"}]}', stderr=""
            )

            with mock.patch.object(verification, "run", side_effect=[summary, coverage]):
                verification.command_receipt_step(arguments)
            step = json.loads(receipt.read_text())["steps"][0]

        self.assertEqual(step["coverage"], {"target": "GitX.app", "lineCoverage": None})

    def test_finish_discovers_durable_outputs_without_derived_data_internals(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            run_directory = pathlib.Path(directory)
            receipt = run_directory / "receipt.json"
            (run_directory / "Logs").mkdir()
            (run_directory / "Logs" / "build.log").write_text("log")
            (run_directory / "Results" / "test.xcresult" / "Data").mkdir(parents=True)
            (run_directory / "Results" / "test.xcresult" / "Data" / "payload").write_text("opaque")
            (run_directory / "DerivedData").mkdir()
            (run_directory / "DerivedData" / "object.o").write_text("opaque")
            (run_directory / "Products" / "GitXCoreBuild" / "out").mkdir(parents=True)
            (run_directory / "Products" / "GitXCoreBuild" / "out" / "object.o").write_text(
                "opaque"
            )
            (run_directory / "Products" / "GitX.xcarchive" / "Products").mkdir(parents=True)
            (run_directory / "Products" / "GitX.xcarchive" / "Info.plist").write_text("opaque")
            receipt.write_text(
                json.dumps(
                    {
                        "runId": "unit-test",
                        "_startedMonotonic": 0,
                        "artifacts": [],
                    }
                )
            )
            arguments = argparse.Namespace(
                path=receipt,
                status="passed",
                exit_code=0,
            )

            with mock.patch.object(verification, "ROOT", ROOT), mock.patch.object(
                verification, "load_config", return_value={"artifactRoot": "artifacts/verification"}
            ), mock.patch.object(verification, "atomic_json") as atomic_json:
                verification.command_receipt_finish(arguments)

            payload = atomic_json.call_args_list[0].args[1]

        self.assertTrue(any(path.endswith("/Logs/build.log") for path in payload["artifacts"]))
        self.assertTrue(any(path.endswith("/Results/test.xcresult") for path in payload["artifacts"]))
        self.assertTrue(any(path.endswith("/Products/GitX.xcarchive") for path in payload["artifacts"]))
        self.assertFalse(any("DerivedData" in path for path in payload["artifacts"]))
        self.assertFalse(any(path.endswith("/GitXCoreBuild/out/object.o") for path in payload["artifacts"]))
        self.assertFalse(any(path.endswith("/Data/payload") for path in payload["artifacts"]))


class DoctorTests(unittest.TestCase):
    def test_destination_matching_honors_every_requested_component(self) -> None:
        output = """
            { platform: macOS, arch: arm64, id: host, name: This Mac }
            { platform: macOS, arch: x86_64, id: translated, name: Rosetta }
        """

        self.assertTrue(
            verification.destination_is_available("platform=macOS,arch=arm64", output)
        )
        self.assertTrue(
            verification.destination_is_available("generic/platform=macOS", output)
        )
        self.assertFalse(
            verification.destination_is_available("platform=macOS,arch=arm64,name=Rosetta", output)
        )

    def test_destination_discovery_timeout_warns_for_build_mode(self) -> None:
        selected = pathlib.Path("/Applications/Xcode.app/Contents/Developer")
        disk_usage = mock.Mock(free=10_000_000_000)
        with mock.patch.object(verification, "xcode_version", return_value=("26.6", "Test")), mock.patch.object(
            verification.shutil, "which", return_value="/usr/bin/tool"
        ), mock.patch.object(verification.shutil, "disk_usage", return_value=disk_usage), mock.patch.object(
            verification, "git_output", return_value=""
        ), mock.patch.object(
            verification,
            "run",
            side_effect=subprocess.TimeoutExpired(["xcodebuild", "-showdestinations"], 90),
        ):
            payload = verification.doctor_payload(
                "build", selected, "platform=macOS,arch=arm64"
            )

        destination = next(check for check in payload["checks"] if check["name"] == "destination")
        self.assertEqual(destination["status"], "warning")
        self.assertEqual(payload["status"], "passed")

    def test_destination_mismatch_fails_for_build_mode(self) -> None:
        selected = pathlib.Path("/Applications/Xcode.app/Contents/Developer")
        disk_usage = mock.Mock(free=10_000_000_000)
        discovered = subprocess.CompletedProcess(
            [], 0, stdout="{ platform: macOS, arch: arm64 }", stderr=""
        )
        with mock.patch.object(verification, "xcode_version", return_value=("26.6", "Test")), mock.patch.object(
            verification.shutil, "which", return_value="/usr/bin/tool"
        ), mock.patch.object(verification.shutil, "disk_usage", return_value=disk_usage), mock.patch.object(
            verification, "git_output", return_value=""
        ), mock.patch.object(verification, "run", return_value=discovered):
            payload = verification.doctor_payload(
                "build", selected, "platform=macOS,arch=x86_64"
            )

        destination = next(check for check in payload["checks"] if check["name"] == "destination")
        self.assertEqual(destination["status"], "failed")
        self.assertEqual(payload["status"], "failed")

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
    def test_ui_preflight_selects_one_test_excluded_from_full_ui_plan(self) -> None:
        preflight = json.loads((ROOT / "GitXTests" / "GitXUIPreflight.xctestplan").read_text())
        full_ui = json.loads((ROOT / "GitXTests" / "GitXUI.xctestplan").read_text())
        scheme = (ROOT / "GitX.xcodeproj" / "xcshareddata" / "xcschemes" / "GitX.xcscheme").read_text()

        selected = preflight["testTargets"][0]["selectedTests"]
        skipped = full_ui["testTargets"][0]["skippedTests"]
        self.assertEqual(selected, ["GitXUIActivationPreflightTests/testRepositoryWindowActivates()"])
        self.assertEqual(skipped, selected)
        self.assertIn("container:GitXTests/GitXUIPreflight.xctestplan", scheme)

    def test_ui_wrapper_runs_preflight_before_full_plan(self) -> None:
        wrapper = (ROOT / "scripts" / "xcodebuild.sh").read_text()
        preflight = 'xcode_test ui-preflight "$preflight"'
        full_ui = 'xcode_test ui "$plan"'

        self.assertIn(preflight, wrapper)
        self.assertIn(full_ui, wrapper)
        self.assertLess(wrapper.index(preflight), wrapper.index(full_ui))
        self.assertIn("-maximum-test-execution-time-allowance 90", wrapper)

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
