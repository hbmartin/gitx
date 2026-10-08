from __future__ import annotations

import pathlib
import tempfile
import argparse
import json
import unittest
from unittest import mock

from support import load_script


class CoverageTransactionTests(unittest.TestCase):
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
        current = {"evidence": {"status": "valid"}, "toolchain": {"xcode": "27"}, "invocation": {"configuration": "Debug"}}
        self.assertTrue(coverage.compatible_comparison(current, current))
        self.assertFalse(coverage.compatible_comparison(current, current | {"invocation": {"configuration": "Release"}}))
        self.assertFalse(coverage.compatible_comparison(current, {"toolchain": current["toolchain"], "invocation": current["invocation"]}))
