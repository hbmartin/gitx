from __future__ import annotations

import pathlib
import tempfile
import argparse
import json
import contextlib
import io
import unittest
from unittest import mock

from support import load_script


class CoverageTransactionTests(unittest.TestCase):
    def test_pending_current_evidence_skips_automatic_historical_discovery(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            policy = root / "policy.json"
            policy.write_text(json.dumps({"version": 1, "target": "Half Dark.app", "minimumLineCoverage": .9, "files": {}}))
            receipt = root / "receipt.json"
            receipt.write_text("{}")
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8, "files": []}]}
            with mock.patch.object(coverage, "comparison_receipt", side_effect=[{"evidence": {"status": "pending"}}]) as read, mock.patch.object(coverage, "xccov_report", return_value=report), mock.patch.object(coverage, "coverage_diagnostics"), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(coverage.main([str(root / "result.xcresult"), "--policy", str(policy), "--receipt", str(receipt)]), 1)
            self.assertEqual(read.call_count, 1)

    def test_automatic_history_is_lazy_and_corrupt_history_cannot_break_the_gate(self):
        coverage = load_script("check_coverage.py")
        for floor in [.5, .9]:
            with self.subTest(floor=floor), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                (root / "scripts").mkdir()
                policy = root / "policy.json"
                policy.write_text(json.dumps({"version": 1, "target": "Half Dark.app", "minimumLineCoverage": .5, "files": {"Classes/A.m": floor}}))
                receipt = {"evidence": {"status": "valid", "inputsAfter": {"plans": "plan"}}, "toolchain": "test", "invocation": "test"}
                current = root / "current.json"
                current.write_text(json.dumps(receipt))
                history = root / "artifacts/verification/broken"
                history.mkdir(parents=True)
                incomplete = root / "artifacts/verification/incomplete"
                incomplete.mkdir()
                (incomplete / "receipt.json").write_text(json.dumps(receipt | {"steps": [{"name": "test:correctness", "coverage": {"lineCoverage": .7}}]}))
                # Newest first: corrupt history must be skipped before the
                # compatible record with missing per-file evidence is reached.
                (history / "receipt.json").write_text("{invalid")
                report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8, "files": [{"path": str(root / "Classes/A.m"), "lineCoverage": .8, "coveredLines": 8, "executableLines": 10}]}]}
                with mock.patch.object(coverage, "__file__", str(root / "scripts/check_coverage.py")), mock.patch.object(coverage, "xccov_report", return_value=report) as xccov, mock.patch.object(coverage, "coverage_diagnostics"), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(coverage.main([str(root / "result.xcresult"), "--policy", str(policy), "--receipt", str(current)]), int(floor > .8))
                self.assertEqual(xccov.call_count, 1)

    def test_failed_measurement_leaves_policy_bytes_unchanged(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            policy = pathlib.Path(directory) / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{"Classes/A.m":0.9}}\n'
            policy.write_bytes(original)
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8,
                "files": [{"path": "/tmp/Classes/A.m", "lineCoverage": .8,
                    "coveredLines": 8, "executableLines": 10}]}]}
            with mock.patch.object(coverage, "xccov_report", return_value=report):
                self.assertNotEqual(coverage.main([directory, "--policy", str(policy), "--record-improvements"]), 0)
            self.assertEqual(policy.read_bytes(), original)

    def test_invalid_provenance_never_writes_and_valid_improvement_is_atomic(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            policy = pathlib.Path(directory) / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{"Classes/A.m":0.5}}\n'
            policy.write_bytes(original)
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8,
                "files": [{"path": "/tmp/Classes/A.m", "lineCoverage": .87659,
                    "coveredLines": 87, "executableLines": 100}]}]}
            arguments = [directory, "--policy", str(policy), "--record-improvements"]
            with mock.patch.object(coverage, "xccov_report", return_value=report):
                with mock.patch.object(coverage, "ratchet_evidence", side_effect=ValueError("invalid provenance")):
                    self.assertNotEqual(coverage.main(arguments), 0)
                    self.assertEqual(policy.read_bytes(), original)
                with mock.patch.object(coverage, "ratchet_evidence", return_value={"evidence": {"status": "valid"}}):
                    self.assertEqual(coverage.main(arguments), 0)
            updated = json.loads(policy.read_text())
            self.assertEqual(updated["minimumLineCoverage"], .8)
            self.assertEqual(updated["files"]["Classes/A.m"], .8765)

    def test_instrumentation_comparison_requires_valid_compatible_evidence(self):
        coverage = load_script("check_coverage.py")
        current = {"evidence": {"status": "valid", "inputsAfter": {"plans": "shared-plan-A"}}, "toolchain": {"xcode": "27"}, "invocation": {"configuration": "Debug"}}
        self.assertTrue(coverage.compatible_comparison(current, current))
        self.assertFalse(coverage.compatible_comparison(current, current | {"invocation": {"configuration": "Release"}}))
        self.assertFalse(coverage.compatible_comparison(current, {"toolchain": current["toolchain"], "invocation": current["invocation"]}))
        self.assertFalse(coverage.compatible_comparison(current, current | {"evidence": {"status": "valid", "inputsAfter": {"plans": "shared-plan-B"}}}))

    def test_no_improvement_keeps_existing_policy_inode_and_bytes(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            policy = pathlib.Path(directory) / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.8,"files":{"Classes/A.m":0.8}}\n'
            policy.write_bytes(original)
            inode = policy.stat().st_ino
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8,
                "files": [{"path": "/tmp/Classes/A.m", "lineCoverage": .8, "coveredLines": 8, "executableLines": 10}]}]}
            with mock.patch.object(coverage, "xccov_report", return_value=report), mock.patch.object(coverage, "ratchet_evidence", return_value={}):
                self.assertEqual(coverage.main([directory, "--policy", str(policy), "--record-improvements"]), 0)
            self.assertEqual(policy.read_bytes(), original)
            self.assertEqual(policy.stat().st_ino, inode)

    def test_uncovered_line_diagnostics_support_current_xccov_archive_keys(self):
        coverage = load_script("check_coverage.py")
        policy = coverage.CoveragePolicy("Half Dark.app", .5, {"Classes/A.swift": .9}, {})
        path = str(coverage.session.ROOT / "Classes/A.swift")
        payload = {path: [{"line": 42, "isExecutable": True, "executionCount": 0},
                          {"lineNumber": 44, "isExecutable": True, "executionCount": 0},
                          {"line": 45, "isExecutable": True, "executionCount": 1}]}
        output = io.StringIO()
        response = coverage.subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        with mock.patch.object(coverage.session, "git", return_value=""), mock.patch.object(coverage.subprocess, "run", return_value=response), contextlib.redirect_stderr(output):
            coverage.coverage_diagnostics(policy, {"Classes/A.swift": .8}, {"Classes/A.swift": (8, 10)}, coverage.session.ROOT, pathlib.Path("result"))
        self.assertIn("Uncovered source lines: 42, 44", output.getvalue())
        self.assertNotIn("None", output.getvalue())
