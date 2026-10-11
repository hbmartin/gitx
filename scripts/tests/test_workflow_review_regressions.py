"""Regressions for durable workflow attempts and resource admission."""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from support import ROOT
import dev_workflow as workflow
import workflow_session as session
import test_workflow_completion as completion
import test_workflow_guard_characterization as characterization




class WorkflowGuardRegressionTests(unittest.TestCase):
    setUp = characterization.WorkflowGuardCharacterizationTests.setUp

    def test_refresh_change_records_completed_blocker_without_execution(self):
        session.entry_resources.side_effect = [([self.resource], self.paths), ([str(self.root / "changed")], self.paths)]
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(session.guard(self.entry, []), 2)
        value = json.loads(self.receipt.read_text())
        self.assertEqual(value["status"], "blocked")
        self.assertEqual(value["category"], "resource-definition-changed")
        self.assertEqual(value["exitCode"], 2)
        self.assertTrue(value["finishedAt"])
        execute.assert_not_called()
        self.lease.__exit__.assert_called_once()

    def test_toolchain_timeout_is_a_durable_blocker_and_never_executes(self):
        session.entry_resources.side_effect = session.ResourceDefinitionError("toolchain timed out")
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(session.guard(self.entry, []), 2)
        value = json.loads(self.receipt.read_text())
        self.assertEqual(value["category"], "resource-definition-unavailable")
        self.assertEqual(value["status"], "blocked")
        self.assertTrue(value["finishedAt"])
        execute.assert_not_called()

    def test_changed_toolchain_blocks_even_when_explicit_cache_paths_match(self):
        session.entry_resources.side_effect = [([self.resource], self.paths | {"toolchain": "one"}),
                                              ([self.resource], self.paths | {"toolchain": "two"})]
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(session.guard(self.entry, []), 2)
        self.assertEqual(json.loads(self.receipt.read_text())["category"], "resource-definition-changed")
        execute.assert_not_called()


class WorkflowResourceRegressionTests(unittest.TestCase):

    def test_static_only_resources_need_no_native_toolchain_probe(self):
        command = [("static", [str(ROOT / "scripts/verify_static.sh")])]
        with mock.patch.object(session.subprocess, "check_output") as probe:
            self.assertEqual(session.entry_resources("verify_static.sh", [], ROOT), ([], {}))
            self.assertEqual(workflow.resources_for(command, ROOT / "fixture", ROOT), [str(ROOT / "fixture")])
        probe.assert_not_called()

    def test_runtime_only_commands_own_app_and_desktop_without_a_toolchain(self):
        with mock.patch.object(session.subprocess, "check_output", side_effect=FileNotFoundError) as probe:
            for entry, arguments in [("run_app.sh", ["--no-build"]), ("run_app.sh", ["--stop"]),
                                     ("observe_app.sh", ["image"])]:
                with self.subTest(entry=entry, arguments=arguments):
                    resources, paths = session.entry_resources(entry, arguments, ROOT)
                    self.assertEqual(set(resources), {str(ROOT / "build/GitX.app"), f"desktop:{os.getuid()}"})
                    self.assertEqual(paths, {})
        probe.assert_not_called()

    def test_help_and_version_only_requests_do_not_discover_native_resources(self):
        for entry in ("run_app.sh", "observe_app.sh", "xcodebuild.sh", "check_test_build_contracts.py"):
            for arguments in (["--help"], ["-h"], ["--version"]):
                with self.subTest(entry=entry, arguments=arguments), \
                        mock.patch.object(session.subprocess, "check_output", side_effect=FileNotFoundError) as probe:
                    self.assertEqual(session.entry_resources(entry, arguments, ROOT), ([], {}))
                    probe.assert_not_called()

    def test_profile_output_is_an_exclusive_resource(self):
        with mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Fixture"):
            resources, _ = session.entry_resources("xcodebuild.sh", ["--profile-rules", "analyze"], ROOT)
        self.assertIn(str(ROOT.resolve() / "artifacts/verification/.swiftlint-profile-output"), resources)

    def test_interop_probe_reuses_the_toolchain_identity(self):
        with mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Fixture") as probe:
            resources, _ = session.entry_resources("check_test_build_contracts.py", [], ROOT)
        self.assertGreater(len(resources), 3)
        probe.assert_called_once()

    def test_probe_timeout_never_falls_back_to_an_unproven_guard_partition(self):
        with mock.patch.object(session.subprocess, "check_output", side_effect=subprocess.TimeoutExpired("xcodebuild", 15)):
            with self.assertRaisesRegex(session.ResourceDefinitionError, "toolchain"):
                session.entry_resources("xcodebuild.sh", ["build"], ROOT)

    def test_zero_exit_garbage_is_not_a_toolchain_identity(self):
        for output in [b"", b"unrelated command output", b"Xcode fixture\nBuild version Test",
                       b"Xcode 26.6", b"Xcode 26.6\nBuild version unknown",
                       b"prefix Xcode 26.6\nBuild version Test"]:
            with self.subTest(output=output), mock.patch.object(session.subprocess, "check_output", return_value=output):
                with self.assertRaises(session.ResourceDefinitionError):
                    session.entry_resources("xcodebuild.sh", ["build"], ROOT)

    def test_analyzer_run_ids_reject_parent_and_hidden_paths(self):
        for value in ["..", ".", ".hidden", "-leading"]:
            with self.subTest(value=value), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Fixture"):
                with self.assertRaisesRegex(ValueError, "run ID"):
                    session.entry_resources("xcodebuild.sh", ["analyze", "--resume-analysis", value], ROOT)

    def test_missing_legacy_process_can_still_be_proven_abandoned(self):
        with mock.patch.object(os, "kill", side_effect=ProcessLookupError):
            self.assertEqual(session.producer_state({"pid": 123, "started": "legacy"}), "abandoned")

    def test_receipt_cache_derivation_accepts_a_shared_reader_and_identity(self):
        child = {"buildPaths": {"derivedData": "/cache"}, "evidence": {"products": {"bundle": True}}}
        value = {"steps": [{"name": "build", "receipt": "child.json"}], "selectedChecks": ["build"]}
        reader = mock.Mock(return_value=child)
        snapshots = session.workflow_cache_snapshots(value, ROOT, receipt_reader=reader)
        identity = mock.Mock(return_value={"bundle": True})
        value["finalCacheProducts"] = snapshots
        with mock.patch.object(session, "workflow_cache_snapshots") as reread:
            self.assertEqual(session.final_cache_problems(value, ROOT, derived=snapshots, identity=identity), [])
        reread.assert_not_called()
        reader.assert_called_once_with(ROOT / "child.json")
        identity.assert_called_once_with("products", "/cache")


class WorkflowOwnershipRegressionTests(unittest.TestCase):
    def test_producer_identity_is_invariant_and_marks_its_format(self):
        def ps(command, **kwargs):
            environment = kwargs.get("env", os.environ)
            return subprocess.CompletedProcess(command, 0, "birth " + environment.get("TZ", "local"), "")
        with mock.patch.object(session.subprocess, "run", side_effect=ps), mock.patch.object(os, "kill"):
            with mock.patch.dict(os.environ, {"TZ": "America/Los_Angeles", "LC_ALL": "en_US.UTF-8"}):
                owner = session.producer_identity()
            with mock.patch.dict(os.environ, {"TZ": "UTC", "LC_ALL": "C"}):
                self.assertEqual(session.producer_state(owner), "live")
        self.assertEqual(owner["startedFormat"], "ps-lstart-utc-c-v1")

    def test_live_legacy_producer_is_uncertain_without_reconstructable_timezone(self):
        with mock.patch.object(os, "kill"), mock.patch.object(session, "process_started", return_value="birth"):
            self.assertEqual(session.producer_state({"pid": 123, "started": "birth"}), "uncertain")

    def test_default_supervisors_have_distinct_owned_diagnostic_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text('{"artifactRoot":"artifacts/verification"}')
            with mock.patch.object(session, "ROOT", root):
                for run_id in ["first", "second"]:
                    self.assertEqual(session.supervise([sys.executable, "-c", "pass"],
                        env=os.environ | {"GITX_SESSION_ID": run_id}), 0)
            container = root / "artifacts/verification/diagnostics"
            manifests = list(container.glob("owned-*/diagnostic-owner.json"))
            self.assertEqual(len(manifests), 2)
            self.assertEqual({json.loads(path.read_text())["runId"] for path in manifests}, {"first", "second"})
            self.assertFalse((container / "diagnostic-owner.json").exists())


if __name__ == "__main__":
    unittest.main()
