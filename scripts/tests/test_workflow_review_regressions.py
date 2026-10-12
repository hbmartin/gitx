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


class WorkflowAttemptRegressionTests(unittest.TestCase):
    setUp = completion.WorkflowCompletionTests.setUp
    run_verification = completion.WorkflowCompletionTests.run_verification

    def test_full_resume_retains_whitespace_and_rejects_duplicate_active_evidence(self):
        app = self.root / 'build/GitX.app'
        app.mkdir(parents=True)
        (app / 'binary').write_text('fixture')
        self.assertEqual(self.run_verification((0,), 'correctness')[0], 0)
        path = self.root / 'artifacts/verification/fixture/workflow.json'
        prior = json.loads(path.read_text())
        prior['steps'].append({'name': 'whitespace', 'status': 'failed', 'receipt': '/missing-feedback.json'})
        for duplicate in (False, True):
            value = json.loads(json.dumps(prior))
            if duplicate: value['steps'].append(value['steps'][0].copy())
            path.write_text(json.dumps(value))
            args = workflow.parser().parse_args(['verify', '--resume', 'fixture', '--cleanup-mode', 'preview'])
            with mock.patch.object(session, 'supervise', return_value=0):
                self.assertEqual(workflow.verify(args), 76 if duplicate else 0)
            resumed = json.loads(path.read_text())
            self.assertEqual(resumed['deliveryEligible'], not duplicate)
            self.assertIn('whitespace', [step['name'] for step in resumed['steps']])

    def test_malformed_resumed_active_profiles_finish_invalid_without_execution(self):
        path = self.root / 'artifacts/verification/fixture/workflow.json'
        for steps in (None, [None], [{'status': 'passed'}], [{'name': []}]):
            with self.subTest(steps=steps):
                session.atomic_json(path, {'schemaVersion': 2, 'runId': 'fixture', 'status': 'failed', 'steps': steps})
                args = workflow.parser().parse_args(['verify', '--resume', 'fixture', '--check', 'correctness'])
                with mock.patch.object(session, 'supervise') as execute:
                    self.assertEqual(workflow.verify(args), 76)
                execute.assert_not_called()
                value = json.loads(path.read_text())
                self.assertEqual(value['status'], 'invalid')
                self.assertFalse(value['deliveryEligible'])

    def test_partial_resume_preserves_unselected_evidence_without_validating_it(self):
        app = self.root / "build/GitX.app"
        app.mkdir(parents=True)
        (app / "binary").write_text("fixture")
        self.assertEqual(self.run_verification()[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        original = json.loads(path.read_text())
        original["steps"].append({"name": "analyze", "status": "failed", "receipt": str(self.root / "missing.json")})
        path.write_text(json.dumps(original))
        (app / "binary").write_text("changed unselected output")
        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(workflow.verify(args), 0)
        execute.assert_not_called()
        value = json.loads(path.read_text())
        self.assertEqual({step["name"] for step in value["steps"]}, {"correctness", "stage-debug", "analyze"})
        self.assertEqual(value["selectedChecks"], ["correctness"])
        self.assertEqual(value["scope"], "partial")
        self.assertFalse(value["deliveryEligible"])
        self.assertEqual(value["reusedChecks"], ["correctness"])

    def test_unreadable_or_malformed_prior_analysis_executes_fresh(self):
        command = [str(self.root / "scripts/xcodebuild.sh"), "analyze"]
        receipt = self.root / "artifacts/verification/prior/receipt.json"
        receipt.parent.mkdir(parents=True)
        workflow_path = self.root / "artifacts/verification/fixture/workflow.json"
        prior = {"name": "analyze", "status": "passed", "evidenceStatus": "valid", "command": command,
                 "toolchain": "fixture", "inputsAfter": self.current, "receipt": str(receipt)}
        malformed = ['{truncated', '[]', 'null', json.dumps({
            "evidence": {"status": "valid", "inputsAfter": self.current, "analyzerScratch": {"path": "/scratch"}},
            "steps": [{"name": "analyze", "status": "passed"}]})]
        for prior_status, contents in [(status, value) for status in ("failed", "passed") for value in malformed]:
            with self.subTest(contents=contents, prior_status=prior_status):
                receipt.write_text(contents)
                session.atomic_json(workflow_path, {"schemaVersion": 2, "runId": "fixture", "status": prior_status,
                    "steps": [prior], "inputsBefore": self.current})
                args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "analyze"])
                with mock.patch.object(workflow, "full_profile", return_value=[("analyze", command)]), \
                        mock.patch.object(session, "entry_resources", return_value=([], {"toolchain": "fixture"})), \
                        mock.patch.object(session, "supervise", return_value=0) as execute:
                    self.assertEqual(workflow.verify(args), 0)
                actual = execute.call_args.args[0]
                self.assertNotIn("--resume-analysis", actual)
                self.assertNotIn("--fresh-on-stale-analysis", actual)
                value = json.loads(workflow_path.read_text())
                self.assertEqual(value["status"], "passed")

    def test_ambiguous_final_cache_ownership_publishes_finished_invalid_receipt(self):
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "supervise", return_value=0), \
                mock.patch.object(session, "workflow_cache_snapshots", side_effect=ValueError("ambiguous cache ownership")), \
                mock.patch.object(workflow.cleanup, "run_cleanup") as cleanup:
            self.assertEqual(workflow.verify(args), 76)
        value = json.loads((self.root / "artifacts/verification/fixture/workflow.json").read_text())
        self.assertEqual(value["status"], "invalid")
        self.assertEqual(value["evidenceStatus"], "invalid")
        self.assertEqual(value["finalCacheProducts"], {})
        self.assertTrue(value["finishedAt"])
        self.assertFalse(value["deliveryEligible"])
        self.assertIn("ambiguous cache ownership", " ".join(value["evidenceProblems"]))
        cleanup.assert_not_called()

    def test_run_ids_cannot_admit_artifact_container_or_parent(self):
        for run_id in [".", "..", ".hidden", "-leading", "../outside", ""]:
            with self.subTest(run_id=run_id):
                args = workflow.parser().parse_args(["verify", "--check", "correctness"])
                args.run_id = run_id
                with mock.patch.object(session, "supervise", return_value=0) as execute:
                    with self.assertRaisesRegex(ValueError, "run ID"):
                        workflow.verify(args)
                execute.assert_not_called()

    def test_resource_probe_failure_finishes_blocked_workflow_before_execution(self):
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture", "--check", "correctness"])
        with mock.patch.object(workflow, "resources_for", side_effect=session.ResourceDefinitionError("toolchain timed out")), \
                mock.patch.object(session, "supervise") as execute:
            self.assertEqual(workflow.verify(args), 2)
        self.assertFalse((self.root / "artifacts/verification/fixture").exists())
        blockers = list((self.root / "artifacts/verification/Coordination").glob("*.json"))
        self.assertEqual(len(blockers), 1)
        value = json.loads(blockers[0].read_text())
        self.assertEqual(value["category"], "resource-definition-unavailable")
        self.assertEqual(value["status"], "blocked")
        self.assertTrue(value["finishedAt"])
        self.assertFalse(value["deliveryEligible"])
        execute.assert_not_called()

    def test_every_pre_admission_blocker_uses_unique_coordination_receipts(self):
        directory = (self.root / 'artifacts/verification/fixture').resolve()
        coordination = directory.parent / 'Coordination'
        owner = {'runId': 'winner', 'pid': 999}
        failures = [session.ResourceBusy(str(path), owner) for path in
                    (directory, self.root / 'DerivedData', self.root / 'SourcePackages', self.root / 'desktop')]
        failures += [session.ResourceDefinitionError('unavailable'),
                     session.ResourceDefinitionError('changed', 'resource-definition-changed')]
        for directory_exists in (False, True):
            if directory_exists: directory.mkdir()
            for failure in failures:
                with self.subTest(exists=directory_exists, failure=str(failure)):
                    previous = set(coordination.glob('*.json'))
                    args = workflow.parser().parse_args(['verify', '--run-id', 'fixture', '--check', 'correctness'])
                    with mock.patch.object(workflow, 'resources_for', side_effect=failure), mock.patch.object(session, 'supervise') as execute:
                        self.assertEqual(workflow.verify(args), 75 if isinstance(failure, session.ResourceBusy) else 2)
                    self.assertEqual(directory.exists(), directory_exists)
                    self.assertFalse((directory / 'workflow.json').exists())
                    created = set(coordination.glob('*.json')) - previous
                    self.assertEqual(len(created), 1)
                    blocker = json.loads(created.pop().read_text())
                    self.assertEqual(blocker['workflowReceipt'], str(directory / 'workflow.json'))
                    execute.assert_not_called()
        # A contender's blocker must not prevent the owner from using the same ID.
        with mock.patch.object(session, 'supervise', return_value=0):
            self.assertEqual(workflow.verify(args), 0)

    def test_post_admission_resource_failure_is_written_before_directory_lease_release(self):
        args = workflow.parser().parse_args(['verify', '--run-id', 'fixture', '--check', 'correctness'])
        path = (self.root / 'artifacts/verification/fixture/workflow.json').resolve()
        released = False
        original = session.atomic_json
        def release(*_):
            nonlocal released
            released = True
        def write(destination, payload):
            if pathlib.Path(destination) == path:
                self.assertFalse(released, 'workflow writes require the directory lease')
            original(destination, payload)
        session.Leases.return_value.__exit__.side_effect = release
        with mock.patch.object(session, 'atomic_json', side_effect=write), \
                mock.patch.object(session, 'supervise', side_effect=session.ResourceBusy('/cache', {'runId': 'other'})):
            self.assertEqual(workflow.verify(args), 75)
        self.assertTrue(released)
        self.assertEqual(json.loads(path.read_text())['status'], 'blocked')

    def test_successful_resume_clears_the_previous_blocker_outcome(self):
        self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        value = json.loads(path.read_text())
        value.update(status="blocked", category="resource-busy", owner={"runId": "other"},
                     resource="/cache", problem="prior blocker", exitCode=75, evidenceProblems=["old problem"])
        path.write_text(json.dumps(value))
        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(workflow.verify(args), 0)
        execute.assert_not_called()
        value = json.loads(path.read_text())
        self.assertEqual(value["status"], "passed")
        for key in ("category", "owner", "resource", "problem", "exitCode", "evidenceProblems"):
            self.assertNotIn(key, value)
        self.assertTrue(value["finishedAt"])

    def test_refresh_retries_release_leases_and_back_off_before_execution(self):
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture", "--check", "correctness", "--wait-for-resources", "1"])
        with mock.patch.object(workflow, "resources_for", side_effect=[["first"], ["next"], ["next"], ["next"]]), \
                mock.patch.object(workflow.time, "sleep") as pause:
            with workflow.selected_leases(args, self.root, self.root / "fixture", {}) as (_, commands, _):
                self.assertEqual(commands, self.commands[:1])
        self.assertEqual(session.Leases.return_value.__exit__.call_count, 2)
        pause.assert_called_once()
        self.assertGreater(pause.call_args.args[0], 0)
        self.assertLessEqual(pause.call_args.args[0], .2)

    def test_resume_cache_admission_errors_finish_invalid_without_execution(self):
        for failure in ("validation-read", "ownership-derivation"):
            with self.subTest(failure=failure):
                path = self.root / "artifacts/verification/fixture/workflow.json"
                if path.exists():
                    path.unlink()
                self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
                value = json.loads(path.read_text())
                if failure == "ownership-derivation":
                    value.pop("finalCacheProducts")
                    path.write_text(json.dumps(value))
                args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
                validate = mock.patch.object(session, "final_cache_problems", side_effect=OSError("cache unreadable")) if failure == "validation-read" else mock.patch.object(session, "final_cache_problems", return_value=[])
                derive = mock.patch.object(session, "workflow_cache_snapshots", side_effect=ValueError("ownership ambiguous")) if failure == "ownership-derivation" else mock.patch.object(session, "workflow_cache_snapshots", wraps=session.workflow_cache_snapshots)
                with validate, derive, mock.patch.object(session, "supervise") as execute, \
                        mock.patch.object(workflow.cleanup, "run_cleanup") as cleanup:
                    self.assertEqual(workflow.verify(args), 76)
                value = json.loads(path.read_text())
                self.assertEqual(value["status"], "invalid")
                self.assertEqual(value["evidenceStatus"], "invalid")
                self.assertTrue(value["finishedAt"])
                self.assertFalse(value["deliveryEligible"])
                self.assertTrue(value["evidenceProblems"])
                execute.assert_not_called()
                cleanup.assert_not_called()

    def test_output_capture_and_validation_errors_finish_invalid_after_command_success(self):
        for failure in ("capture", "validation"):
            with self.subTest(failure=failure):
                path = self.root / "artifacts/verification/fixture/workflow.json"
                if path.exists():
                    path.unlink()
                args = workflow.parser().parse_args(["verify", "--run-id", "fixture", "--check", "stage-debug"])
                values = OSError("output unreadable") if failure == "capture" else [{"file": "identity"}, OSError("output unreadable")]
                with mock.patch.object(session, "tree_identity", side_effect=values), \
                        mock.patch.object(session, "supervise", return_value=0) as execute, \
                        mock.patch.object(workflow.cleanup, "run_cleanup") as cleanup:
                    self.assertEqual(workflow.verify(args), 76)
                value = json.loads(path.read_text())
                self.assertEqual(value["status"], "invalid")
                self.assertTrue(value["finishedAt"])
                self.assertFalse(value["deliveryEligible"])
                self.assertIn("output unreadable", " ".join(value["evidenceProblems"]))
                self.assertEqual(value["executedChecks"], ["stage-debug"])
                self.assertEqual(value["steps"][0]["exitCode"], 0)
                execute.assert_called_once()
                cleanup.assert_not_called()

    def test_unreadable_prior_workflow_output_runs_the_check_fresh(self):
        self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        value = json.loads(path.read_text())
        value["steps"][0]["outputs"] = {"/prior/output": {"file": "identity"}}
        path.write_text(json.dumps(value))
        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "tree_identity", side_effect=OSError("prior output unreadable")), \
                mock.patch.object(session, "supervise", return_value=0) as execute:
            self.assertEqual(workflow.verify(args), 0)
        execute.assert_called_once()
        value = json.loads(path.read_text())
        self.assertEqual(value["executedChecks"], ["correctness"])
        self.assertIn("unreadable", value["steps"][0]["executionReason"])

    def test_unreadable_prior_child_artifact_runs_the_check_fresh(self):
        self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        child = self.root / "prior.json"
        child.write_text(json.dumps({"status": "passed", "evidence": {"status": "valid"}}))
        value = json.loads(path.read_text())
        value["steps"][0]["receipt"] = str(child)
        path.write_text(json.dumps(value))
        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "receipt_artifact_problems", side_effect=OSError("prior artifact unreadable")), \
                mock.patch.object(session, "supervise", return_value=0) as execute:
            self.assertEqual(workflow.verify(args), 0)
        execute.assert_called_once()
        value = json.loads(path.read_text())
        self.assertEqual(value["executedChecks"], ["correctness"])
        self.assertIn("artifacts-unreadable", value["steps"][0]["executionReason"])

    def test_same_run_contention_preserves_owned_receipt_and_records_separate_blocker(self):
        self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        original = json.loads(path.read_text())
        original["producer"] = {"pid": 999, "started": "owner birth", "startedFormat": session.PRODUCER_START_FORMAT}
        owner = {"runId": "fixture", "pid": 999, "receipt": str(path)}
        for prior_status in ("running", "passed"):
            with self.subTest(prior_status=prior_status):
                original["status"] = prior_status
                path.write_text(json.dumps(original))
                before = path.read_bytes()
                coordination = path.parent.parent / "Coordination"
                for resource in (str(path.parent.resolve()), str(self.root / "cache")):
                    with self.subTest(resource=resource):
                        existing = set(coordination.glob("*.json"))
                        session.Leases.return_value.__enter__.side_effect = session.ResourceBusy(resource, owner)
                        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
                        with mock.patch.object(session, "supervise") as execute, \
                                mock.patch.object(session, "workflow_cache_snapshots", side_effect=AssertionError("Cannot read owned evidence before acquiring its lease")):
                            self.assertEqual(workflow.verify(args), 75)
                        self.assertEqual(path.read_bytes(), before)
                        blockers = set(coordination.glob("*.json")) - existing
                        self.assertEqual(len(blockers), 1)
                        blocker_path = blockers.pop()
                        blocker = json.loads(blocker_path.read_text())
                        self.assertEqual(blocker["schemaVersion"], 2)
                        self.assertEqual(blocker["status"], "blocked")
                        self.assertEqual(blocker["exitCode"], 75)
                        self.assertEqual(blocker["category"], "resource-busy")
                        self.assertEqual(blocker["owner"], owner)
                        self.assertEqual(blocker["receipt"], str(blocker_path.resolve()))
                        self.assertEqual(blocker["workflowReceipt"], str(path.resolve()))
                        self.assertEqual(blocker["selectedChecks"], ["correctness"])
                        self.assertEqual(blocker["entry"], str(self.root / "scripts/dev_workflow.py"))
                        self.assertTrue(blocker["finishedAt"])
                        self.assertFalse(blocker["deliveryEligible"])
                        self.assertEqual(blocker["producer"]["pid"], os.getpid())
                        self.assertNotIn("evidence", blocker)
                        execute.assert_not_called()

    def test_resume_resource_definition_failure_preserves_prior_receipt(self):
        self.assertEqual(self.run_verification((0,), "correctness")[0], 0)
        path = self.root / "artifacts/verification/fixture/workflow.json"
        before = path.read_bytes()
        args = workflow.parser().parse_args(["verify", "--resume", "fixture", "--check", "correctness"])
        with mock.patch.object(session, "supervise") as execute, \
                mock.patch.object(workflow, "resources_for", side_effect=session.ResourceDefinitionError("toolchain unavailable")):
            self.assertEqual(workflow.verify(args), 2)
        self.assertEqual(path.read_bytes(), before)
        blockers = list((path.parent.parent / "Coordination").glob("*.json"))
        self.assertEqual(len(blockers), 1)
        blocker = json.loads(blockers[0].read_text())
        self.assertEqual(blocker["schemaVersion"], 2)
        self.assertEqual(blocker["status"], "blocked")
        self.assertEqual(blocker["category"], "resource-definition-unavailable")
        self.assertEqual(blocker["exitCode"], 2)
        self.assertEqual(blocker["workflowReceipt"], str(path.resolve()))
        self.assertEqual(blocker["selectedChecks"], ["correctness"])
        self.assertTrue(blocker["finishedAt"])
        self.assertFalse(blocker["deliveryEligible"])
        self.assertNotIn("owner", blocker)
        execute.assert_not_called()


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
    def test_malformed_prior_scratch_does_not_enter_resource_definitions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text((ROOT / "scripts/verification-config.json").read_text())
            prior = root / "artifacts/verification/prior/receipt.json"
            prior.parent.mkdir(parents=True)
            toolchain = "Xcode 26.6\nBuild version Fixture"
            for path in (["/scratch"], {"path": "/scratch"}, 1, True, ""):
                with self.subTest(path=path):
                    prior.write_text(json.dumps({"evidence": {"analyzerScratch": {"path": path}}}))
                    resources, _ = session.entry_resources("xcodebuild.sh", ["analyze", "--resume-analysis", "prior"], root, toolchain=toolchain)
                    self.assertTrue(all(isinstance(resource, str) and resource for resource in resources))

    def test_uncanonicalizable_prior_scratch_can_reach_fresh_analysis_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text((ROOT / "scripts/verification-config.json").read_text())
            prior = root / "artifacts/verification/prior/receipt.json"
            prior.parent.mkdir(parents=True)
            loop = root / "loop"
            loop.symlink_to(loop)
            for scratch in ("/scratch\0bad", str(loop)):
                with self.subTest(scratch=scratch):
                    prior.write_text(json.dumps({"evidence": {"analyzerScratch": {"path": scratch}}}))
                    resources, _ = session.entry_resources("xcodebuild.sh", ["analyze", "--resume-analysis", "prior", "--fresh-on-stale-analysis"], root,
                                                          toolchain="Xcode 26.6\nBuild version Fixture")
                    self.assertNotIn(scratch, resources)
                    self.assertTrue(all(session.canonical_resource(resource) for resource in resources))

    def test_multi_command_selection_probes_toolchain_once(self):
        commands = workflow.full_profile(ROOT)
        with mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Fixture") as probe:
            workflow.resources_for(commands, ROOT / "artifacts/verification/fixture", ROOT)
        probe.assert_called_once()

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
    def test_live_malformed_birth_metadata_is_uncertain(self):
        for birth in (["birth"], {"birth": True}, 1, True, "", None):
            with self.subTest(birth=birth), mock.patch.object(os, "kill"), \
                    mock.patch.object(session, "process_started", return_value="birth"):
                self.assertEqual(session.producer_state({"pid": 123, "started": birth,
                                                         "startedFormat": session.PRODUCER_START_FORMAT}), "uncertain")

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
