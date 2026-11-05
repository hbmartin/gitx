from __future__ import annotations

import pathlib
import tempfile
import argparse
import json
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

from support import load_script


class CoverageTransactionTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Darwin case-insensitive volume identity")
    def test_case_aliases_cannot_replace_reports_or_input_evidence(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            if os.pathconf(root, 11):  # Darwin _PC_CASE_SENSITIVE
                self.skipTest("This fixture volume distinguishes case")
            policy = root / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}\n'
            policy.write_bytes(original)
            first, second = root / "report.json", root / "REPORT.JSON"
            for outputs in (["--source-breakdown", str(first), "--propose-improvements", str(second)],
                            ["--source-breakdown", str(root / "POLICY.JSON")],
                            ["--propose-improvements", str(root / "POLICY.JSON")]):
                with self.subTest(outputs=outputs), mock.patch.object(coverage, "xccov_report") as report, contextlib.redirect_stderr(io.StringIO()):
                    status = coverage.main([str(root / "result.xcresult"), "--policy", str(policy), *outputs])
                    self.assertEqual(status, 1)
                    report.assert_not_called()
                    self.assertEqual(policy.read_bytes(), original)
                    self.assertFalse(first.exists())
                    self.assertFalse(second.exists())

    def test_report_outputs_cannot_replace_each_other(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "shared.json"
            original = b"existing report bytes"
            output.write_bytes(original)
            alias = root / "alias.json"
            alias.symlink_to(output)
            policy = root / "policy.json"
            policy.write_text('{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}')
            measurement = {"targets": [{"name": "Half Dark.app", "lineCoverage": 1.0, "files": []}]}
            with mock.patch.object(coverage, "xccov_report", return_value=measurement) as report, mock.patch.object(coverage, "ratchet_evidence", return_value={}), contextlib.redirect_stderr(io.StringIO()):
                status = coverage.main([str(root / "result.xcresult"), "--policy", str(policy), "--source-breakdown", str(output), "--propose-improvements", str(alias)])
            self.assertEqual(status, 1)
            self.assertEqual(output.read_bytes(), original)
            self.assertTrue(alias.is_symlink())
            report.assert_not_called()

    def test_optional_outputs_preserve_historical_receipts_and_their_resolved_targets(self):
        coverage = load_script("check_coverage.py")
        for flag in ("--source-breakdown", "--propose-improvements"):
            for indirect in (False, True):
                with self.subTest(flag=flag, indirect=indirect), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    receipt = root / "artifacts/verification/older/receipt.json"
                    receipt.parent.mkdir(parents=True)
                    original = b'{"historical":"immutable evidence"}\n'
                    destination = root / "external-evidence.json" if indirect else receipt
                    destination.write_bytes(original)
                    if indirect:
                        receipt.symlink_to(destination)
                    policy = root / "policy.json"
                    policy.write_text('{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}')
                    measurement = {"targets": [{"name": "Half Dark.app", "lineCoverage": 1.0, "files": []}]}
                    with mock.patch.object(coverage, "__file__", str(root / "scripts/check_coverage.py")), mock.patch.object(coverage, "xccov_report", return_value=measurement) as report, mock.patch.object(coverage, "ratchet_evidence", return_value={}), mock.patch.object(coverage, "comparison_receipt") as read, contextlib.redirect_stderr(io.StringIO()):
                        status = coverage.main([str(root / "current/Results/result.xcresult"), "--policy", str(policy), flag, str(destination)])
                    self.assertEqual(status, 1)
                    self.assertEqual(receipt.read_bytes(), original)
                    self.assertEqual(destination.read_bytes(), original)
                    report.assert_not_called()
                    read.assert_not_called()

    def test_proposal_preserves_all_explicit_inputs_before_measurement(self):
        coverage = load_script("check_coverage.py")
        for name in ("policy", "bundle", "receipt", "comparison"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                bundle = root / "Results/result.xcresult"
                bundle.mkdir(parents=True)
                paths = {"policy": root / "policy.json", "bundle": bundle / "Info.plist",
                         "receipt": root / "current.json", "comparison": root / "comparison.json"}
                original = b"preserve input bytes"
                for path in paths.values():
                    path.write_bytes(original)
                paths["policy"].write_text('{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}')
                before = {key: path.read_bytes() for key, path in paths.items()}
                with mock.patch.object(coverage, "xccov_report") as report, contextlib.redirect_stderr(io.StringIO()):
                    status = coverage.main([str(bundle), "--policy", str(paths["policy"]), "--receipt", str(paths["receipt"]),
                                            "--compare", str(paths["comparison"]), "--propose-improvements", str(paths[name])])
                self.assertEqual(status, 1)
                self.assertEqual({key: path.read_bytes() for key, path in paths.items()}, before)
                report.assert_not_called()

    def test_distinct_reports_do_not_read_historical_payloads_on_a_passing_measurement(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            history = root / "artifacts/verification/older/receipt.json"
            history.parent.mkdir(parents=True)
            history.write_bytes(b"malformed historical payload must stay unread")
            policy = root / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}\n'
            policy.write_bytes(original)
            breakdown, proposal = root / "breakdown.json", root / "proposal.json"
            measurement = {"targets": [{"name": "Half Dark.app", "lineCoverage": .8, "coveredLines": 8, "executableLines": 10,
                                        "files": [{"path": "/unknown.swift", "lineCoverage": .8, "coveredLines": 8, "executableLines": 10}]}]}
            with mock.patch.object(coverage, "__file__", str(root / "scripts/check_coverage.py")), mock.patch.object(coverage, "xccov_report", return_value=measurement), mock.patch.object(coverage, "ratchet_evidence", return_value={}), mock.patch.object(coverage, "comparison_receipt") as read:
                status = coverage.main([str(root / "current/Results/result.xcresult"), "--policy", str(policy),
                                        "--source-breakdown", str(breakdown), "--propose-improvements", str(proposal)])
            self.assertEqual(status, 0)
            self.assertTrue(json.loads(breakdown.read_text())["supplementalOnly"])
            self.assertEqual(json.loads(proposal.read_text())["candidatePolicy"]["minimumLineCoverage"], .8)
            self.assertEqual(policy.read_bytes(), original)
            self.assertEqual(history.read_bytes(), b"malformed historical payload must stay unread")
            read.assert_not_called()

    def test_malformed_supplemental_counts_fail_normally_without_publishing(self):
        coverage = load_script("check_coverage.py")
        for relative in ("Classes/A.swift", "Unknown.swift"):
            for covered, executable in ((8, 7), (-1, 7), (0, -1)):
                with self.subTest(relative=relative, counts=(covered, executable)), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    policy = root / "policy.json"
                    original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}\n'
                    policy.write_bytes(original)
                    output = root / "breakdown.json"
                    output.write_bytes(b"previous breakdown")
                    proposal = root / "proposal.json"
                    proposal.write_bytes(b"previous proposal")
                    report = {"targets": [{"name": "Half Dark.app", "lineCoverage": 1.0, "files": [
                        {"path": str(root / relative), "lineCoverage": 1.0, "coveredLines": covered, "executableLines": executable}]}]}
                    stderr = io.StringIO()
                    with mock.patch.object(coverage, "xccov_report", return_value=report), contextlib.redirect_stderr(stderr):
                        status = coverage.main([str(root / "result.xcresult"), "--policy", str(policy), "--source-breakdown", str(output), "--propose-improvements", str(proposal)])
                    self.assertEqual(status, 1)
                    self.assertIn("Invalid coverage line counts", stderr.getvalue())
                    self.assertNotIn("Traceback", stderr.getvalue())
                    self.assertEqual(policy.read_bytes(), original)
                    self.assertEqual(output.read_bytes(), b"previous breakdown")
                    self.assertEqual(proposal.read_bytes(), b"previous proposal")

    def test_source_breakdown_refuses_to_overwrite_its_policy_input(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            policy = pathlib.Path(directory) / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.5,"files":{}}\n'
            policy.write_bytes(original)
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": 1.0, "files": []}]}
            with mock.patch.object(coverage, "xccov_report", return_value=report):
                status = coverage.main([directory, "--policy", str(policy), "--source-breakdown", str(policy)])
            self.assertEqual(status, 1)
            self.assertEqual(policy.read_bytes(), original)

    def test_source_breakdown_preserves_bundle_contents_and_the_implicit_receipt(self):
        coverage = load_script("check_coverage.py")
        for name in ("bundle", "implicit-receipt"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                result = root / "run/Results/GitX.xcresult"
                result.mkdir(parents=True)
                output = result / "Info.plist" if name == "bundle" else root / "run/receipt.json"
                original = b"preserve verification evidence"
                output.write_bytes(original)
                policy = root / "policy.json"
                policy.write_text(json.dumps({"version": 1, "target": "Half Dark.app", "minimumLineCoverage": .5, "files": {}}))
                with mock.patch.object(coverage, "xccov_report") as report:
                    status = coverage.main([str(result), "--policy", str(policy), "--source-breakdown", str(output)])
                self.assertEqual(status, 1)
                self.assertEqual(output.read_bytes(), original)
                report.assert_not_called()

    def test_supplemental_breakdown_does_not_bypass_a_failure_or_rewrite_the_policy(self):
        coverage = load_script("check_coverage.py")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            policy = root / "policy.json"
            original = b'{"version":1,"target":"Half Dark.app","minimumLineCoverage":0.9,"files":{}}\n'
            policy.write_bytes(original)
            output = root / "breakdown.json"
            report = {"targets": [{"name": "Half Dark.app", "lineCoverage": .5, "coveredLines": 5,
                                   "executableLines": 10, "files": [{"path": "/unrelated/Unknown.swift",
                                   "coveredLines": 5, "executableLines": 10, "lineCoverage": .5}]}]}
            with mock.patch.object(coverage, "xccov_report", return_value=report), mock.patch.object(coverage, "coverage_diagnostics"):
                status = coverage.main([str(root / "result.xcresult"), "--policy", str(policy), "--source-breakdown", str(output)])
            self.assertEqual(status, 1)
            self.assertEqual(policy.read_bytes(), original)
            result = json.loads(output.read_text())
            self.assertTrue(result["supplementalOnly"])
            self.assertEqual(result["groups"]["other"]["coveredLines"], 5)
            self.assertTrue(result["matchesTargetCounts"])

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
