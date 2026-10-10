"""Characterize verification completion before adding commit-triggered cleanup."""
from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from support import ROOT
import dev_workflow as workflow
import workflow_session as session


class WorkflowCompletionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/verification-config.json").write_text('{"artifactRoot": "artifacts/verification"}')
        self.current = {"root": str(self.root), "head": "commit", "source": "source",
                        "dependencies": "dependencies", "plans": "plans"}
        self.commands = [("correctness", ["fixture-test"]), ("stage-debug", ["fixture-build"])]
        leases = mock.MagicMock()
        leases.__enter__.return_value.environment.return_value = os.environ.copy()
        leases.__enter__.return_value.descriptors.return_value = ()
        leases.__enter__.return_value.wait_seconds = 0
        for patch in (
            mock.patch.object(session, "ROOT", self.root),
            mock.patch.object(session, "inputs", return_value=self.current),
            mock.patch.object(session, "cache_paths", return_value={"toolchain": "fixture"}),
            mock.patch.object(session, "Leases", return_value=leases),
            mock.patch.object(workflow, "full_profile", return_value=self.commands),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def run_verification(self, statuses=(0, 0), checks=None):
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture"] +
                                             (["--check", checks] if checks else []))
        with mock.patch.object(session, "supervise", side_effect=statuses) as execute:
            code = workflow.verify(args)
        receipt = json.loads((self.root / "artifacts/verification/fixture/workflow.json").read_text())
        return code, receipt, execute

    def test_full_success_records_valid_delivery_and_staged_product(self):
        app = self.root / "build/GitX.app"
        app.mkdir(parents=True)
        (app / "binary").write_bytes(b"fixture")
        code, receipt, execute = self.run_verification()
        self.assertEqual(code, 0)
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(receipt["evidenceStatus"], "valid")
        self.assertTrue(receipt["deliveryEligible"])
        self.assertEqual(receipt["scope"], "full")
        self.assertEqual(receipt["steps"][-1]["outputs"][str(app)], session.tree_identity(app))
        self.assertEqual(execute.call_count, 2)

    def test_partial_success_is_not_delivery_eligible(self):
        code, receipt, execute = self.run_verification((0,), "correctness")
        self.assertEqual(code, 0)
        self.assertEqual(receipt["status"], "passed")
        self.assertFalse(receipt["deliveryEligible"])
        self.assertEqual(receipt["scope"], "partial")
        self.assertEqual(execute.call_count, 1)

    def test_feedback_reports_selected_and_executed_checks_without_delivery(self):
        args = workflow.parser().parse_args(["verify", "--profile", "feedback", "--run-id", "fixture"])
        with mock.patch.object(workflow.feedback, "changed_paths", return_value=("base", ["Classes/View.swift"])), \
                mock.patch.object(session, "supervise", return_value=0):
            self.assertEqual(workflow.verify(args), 0)
        receipt = json.loads((self.root / "artifacts/verification/fixture/workflow.json").read_text())
        self.assertFalse(receipt["deliveryEligible"])
        self.assertEqual(receipt["scope"], "partial")
        self.assertEqual(receipt["selectedChecks"], ["correctness"])
        self.assertEqual(receipt["executedChecks"], ["correctness"])
        self.assertEqual(receipt["reusedChecks"], [])
        self.assertGreaterEqual(receipt["steps"][0]["durationSeconds"], 0)

    def test_failed_check_preserves_failure_and_stops_before_staging(self):
        code, receipt, execute = self.run_verification((9,))
        self.assertEqual(code, 9)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["steps"][0]["exitCode"], 9)
        self.assertEqual(execute.call_count, 1)
        self.assertNotIn("finishedAt", receipt)

    def test_commit_during_verification_invalidates_success(self):
        def statuses():
            self.current = self.current | {"head": "new-commit"}
            yield 0
        with mock.patch.object(session, "inputs", side_effect=lambda root: self.current):
            code, receipt, execute = self.run_verification(statuses())
        self.assertEqual(code, 76)
        self.assertEqual(receipt["steps"][0]["evidenceStatus"], "invalid")
        self.assertEqual(execute.call_count, 1)

    def test_cleanup_preview_interface_exists(self):
        args = workflow.parser().parse_args(["cleanup", "preview"])
        self.assertEqual(args.action, "preview")

    def test_cleanup_failure_does_not_change_successful_verification(self):
        app = self.root / "build/GitX.app"
        app.mkdir(parents=True)
        (app / "binary").write_bytes(b"fixture")
        with mock.patch.object(workflow.cleanup, "run_cleanup", side_effect=OSError("cleanup failed")):
            code, receipt, _ = self.run_verification()
        self.assertEqual(code, 0)
        self.assertEqual(receipt["status"], "passed")
        self.assertTrue(receipt["deliveryEligible"])

    def test_preview_mode_runs_after_verification_is_published_and_leases_are_released(self):
        app = self.root / "build/GitX.app"
        app.mkdir(parents=True)
        (app / "binary").write_bytes(b"fixture")
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture", "--cleanup-mode", "preview"])
        lease = session.Leases.return_value
        def preview(root):
            value = json.loads((self.root / "artifacts/verification/fixture/workflow.json").read_text())
            self.assertEqual(value["status"], "passed")
            lease.__exit__.assert_called_once()
            return {"status": "preview"}
        with mock.patch.object(session, "supervise", return_value=0), \
                mock.patch.object(workflow.cleanup, "preview", side_effect=preview) as inspect, \
                mock.patch.object(workflow.cleanup, "run_cleanup") as remove:
            self.assertEqual(workflow.verify(args), 0)
        inspect.assert_called_once()
        remove.assert_not_called()

    def test_changed_immutable_result_invalidates_an_otherwise_successful_workflow(self):
        artifact = self.root / "artifacts/verification"
        result = artifact / "first/Results.xcresult"
        result.mkdir(parents=True)
        (result / "data").write_text("original")
        child = artifact / "first/receipt.json"
        child.write_text(json.dumps({"evidence": {"status": "valid", "results": {str(result): session.tree_identity(result)}}}))
        def execute(command, **kwargs):
            if command == ["fixture-test"]:
                child_id = kwargs["env"]["GITX_SESSION_ID"]
                path = artifact / child_id / "receipt.json"
                path.parent.mkdir()
                path.write_bytes(child.read_bytes())
            else:
                (result / "data").write_text("tampered")
            return 0
        args = workflow.parser().parse_args(["verify", "--run-id", "fixture"])
        with mock.patch.object(session, "supervise", side_effect=execute), mock.patch.object(workflow.cleanup, "run_cleanup") as prune:
            self.assertEqual(workflow.verify(args), 76)
        prune.assert_not_called()
        self.assertFalse(json.loads((artifact / "fixture/workflow.json").read_text())["deliveryEligible"])

    def test_partial_verification_does_not_invoke_cleanup(self):
        with mock.patch.object(workflow.cleanup, "run_cleanup") as prune:
            self.run_verification((0,), "correctness")
        prune.assert_not_called()


if __name__ == "__main__":
    unittest.main()
