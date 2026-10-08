"""Passing contracts for the policies reused by the workflow coordinator."""
from __future__ import annotations

import unittest

from support import load_script


class WorkflowCharacterizationTests(unittest.TestCase):
    def test_ratchet_rounds_down_and_preserves_a_conversion_floor(self):
        coverage = load_script("check_coverage.py")
        policy = coverage.CoveragePolicy("Half Dark.app", .8, {"Classes/Converted.swift": .9}, {})
        candidate = coverage.ratchet_policy(
            policy, target_coverage=.81239,
            file_coverage={"Classes/Converted.swift": .89999},
        )
        self.assertEqual(candidate.minimum_line_coverage, .8123)
        self.assertEqual(candidate.files["Classes/Converted.swift"], .9)
        self.assertTrue(coverage.evaluate_coverage(
            candidate, target_coverage=.81239,
            file_coverage={"Classes/Converted.swift": .89999},
        ))

    def test_missing_policy_path_cannot_be_hidden_by_a_new_path(self):
        coverage = load_script("check_coverage.py")
        policy = coverage.CoveragePolicy("Half Dark.app", .8, {"Classes/Old.m": .9}, {})
        failures = coverage.evaluate_coverage(
            policy, target_coverage=.9, file_coverage={"Classes/New.swift": 1.0},
        )
        self.assertEqual(len(failures), 2)
        self.assertIn("Missing coverage for Classes/Old.m", failures)
