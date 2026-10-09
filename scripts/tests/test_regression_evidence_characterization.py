from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest

from support import ROOT  # Adds the repository scripts to the import path.
import report_xcresult
import workflow_session as session


class RegressionEvidenceCharacterizationTests(unittest.TestCase):
    def test_result_walk_preserves_bundle_and_configuration_scopes(self):
        case = {"nodeType": "Test Case", "nodeIdentifier": "PolicyTests/testBoundary()", "result": "Skipped"}
        bundle = {"nodeType": "Unit test bundle", "name": "GitXTests", "children": [
            {"nodeType": "Test Plan Configuration", "name": "Release", "children": [case]}]}
        visited = list(report_xcresult.walk(bundle))
        self.assertEqual(visited[-1], (case, "GitXTests"))
        self.assertEqual(case["result"], "Skipped")

    def test_failure_under_a_repetition_retains_the_actual_assertion(self):
        case = {"nodeType": "Test Case", "nodeIdentifier": "PolicyTests/testBoundary()", "result": "Failed", "children": [
            {"nodeType": "Repetition", "children": [{"nodeType": "Failure Message", "name": "PolicyTests.swift:12: wrong destination"}]}]}
        bundle = {"nodeType": "Unit test bundle", "name": "GitXTests", "children": [case]}
        failures = report_xcresult.collect_failures({"testNodes": [bundle]})
        self.assertEqual(len(failures), 1)
        self.assertEqual((failures[0].target, failures[0].test, failures[0].message),
                         ("GitXTests", "PolicyTests/testBoundary()", "wrong destination"))

    def test_input_identity_detects_source_and_policy_changes_but_not_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            (root / "scripts").mkdir()
            policy = root / "scripts/policy.json"
            policy.write_text('{"mode":"advisory"}\n')
            before = session.inputs(root)
            (root / "artifacts").mkdir()
            (root / "artifacts/report.json").write_text(json.dumps({"status": "incomplete"}))
            self.assertEqual(session.changed_inputs(before, session.inputs(root)), [])
            policy.write_text('{"mode":"changed"}\n')
            self.assertIn("source", session.changed_inputs(before, session.inputs(root)))


if __name__ == "__main__":
    unittest.main()
