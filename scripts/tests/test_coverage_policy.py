from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


class CoveragePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_coverage.py")

    def test_policy_is_loaded_from_checked_in_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "coverage.json"
            path.write_text(
                '{"version": 1, "target": "GitX.app", '
                '"minimumLineCoverage": 0.5, "files": {"Classes/A.m": 0.75}}'
            )

            policy = self.module.load_policy(path)

        self.assertEqual(policy.target, "GitX.app")
        self.assertEqual(policy.minimum_line_coverage, 0.5)
        self.assertEqual(policy.files, {"Classes/A.m": 0.75})

    def test_coverage_regressions_fail_against_the_policy(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={"Classes/A.m": 0.75},
        )

        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.49,
            file_coverage={"Classes/A.m": 0.74},
        )

        self.assertEqual(len(failures), 2)

    def test_new_source_file_requires_an_explicit_policy_floor(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={"Classes/A.m": 0.75},
        )

        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.5,
            file_coverage={"Classes/A.m": 0.75, "Classes/NewFeature.swift": 0.0},
        )

        self.assertEqual(
            failures,
            ["Coverage policy is missing Classes/NewFeature.swift"],
        )

    def test_external_dependency_source_does_not_require_a_policy_floor(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={"Classes/A.m": 0.75},
        )

        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.5,
            file_coverage={
                "Classes/A.m": 0.75,
                "External/Dependency.m": 0.0,
            },
        )

        self.assertEqual(failures, [])

    def test_recording_improvements_never_lowers_a_floor(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={"Classes/A.m": 0.75, "Classes/B.m": 0.8},
        )

        ratcheted = self.module.ratchet_policy(
            policy,
            target_coverage=0.6,
            file_coverage={"Classes/A.m": 0.9, "Classes/B.m": 0.7},
        )

        self.assertEqual(ratcheted.minimum_line_coverage, 0.6)
        self.assertEqual(ratcheted.files["Classes/A.m"], 0.9)
        self.assertEqual(ratcheted.files["Classes/B.m"], 0.8)

    def test_recording_improvements_adds_new_first_party_sources(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={"Classes/A.m": 0.75},
        )

        ratcheted = self.module.ratchet_policy(
            policy,
            target_coverage=0.5,
            file_coverage={
                "Classes/A.m": 0.75,
                "Classes/NewFeature.swift": 0.87659,
                "External/Dependency.m": 0.0,
            },
        )

        self.assertEqual(ratcheted.files["Classes/NewFeature.swift"], 0.8765)
        self.assertNotIn("External/Dependency.m", ratcheted.files)

    def test_coverage_floor_does_not_underflow_four_decimal_value(self) -> None:
        self.assertEqual(self.module.coverage_floor(0.0003), 0.0003)

    def test_weighted_group_preserves_a_split_file_floor(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={},
            groups={
                "Split surface": self.module.CoverageGroup(
                    minimum_line_coverage=0.75,
                    files=("Classes/A.swift", "Classes/B.swift"),
                )
            },
        )

        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.5,
            file_coverage={
                "Classes/A.swift": 1.0,
                "Classes/B.swift": 0.5,
            },
            file_line_counts={
                "Classes/A.swift": (3, 3),
                "Classes/B.swift": (1, 2),
            },
        )

        self.assertEqual(failures, [])

    def test_weighted_group_regression_fails(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={},
            groups={
                "Split surface": self.module.CoverageGroup(
                    minimum_line_coverage=0.8,
                    files=("Classes/A.swift", "Classes/B.swift"),
                )
            },
        )

        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.5,
            file_coverage={
                "Classes/A.swift": 1.0,
                "Classes/B.swift": 0.0,
            },
            file_line_counts={
                "Classes/A.swift": (3, 3),
                "Classes/B.swift": (0, 2),
            },
        )

        self.assertEqual(
            failures,
            ["Split surface coverage regressed to 60.00%; minimum is 80.00%"],
        )

    def test_group_coverage_reports_weighted_value_and_missing_files(self) -> None:
        group = self.module.CoverageGroup(
            minimum_line_coverage=0.8,
            files=("Classes/A.swift", "Classes/B.swift"),
        )

        self.assertEqual(
            self.module.group_coverage(
                group,
                {
                    "Classes/A.swift": (3, 3),
                    "Classes/B.swift": (1, 2),
                },
            ),
            0.8,
        )
        self.assertEqual(
            self.module.group_coverage(group, {"Classes/A.swift": (3, 3)}),
            None,
        )

    def test_recording_improvements_does_not_create_individual_group_file_floors(self) -> None:
        policy = self.module.CoveragePolicy(
            target="GitX.app",
            minimum_line_coverage=0.5,
            files={
                "Classes/Tracked.swift": 0.75,
                "Classes/A.swift": 0.75,
                "Classes/B.swift": 0.75,
            },
            groups={
                "Split surface": self.module.CoverageGroup(
                    minimum_line_coverage=0.75,
                    files=("Classes/A.swift", "Classes/B.swift"),
                )
            },
        )

        ratcheted = self.module.ratchet_policy(
            policy,
            target_coverage=0.6,
            file_coverage={
                "Classes/Tracked.swift": 0.8,
                "Classes/A.swift": 1.0,
                "Classes/B.swift": 0.5,
                "Classes/NewFeature.swift": 0.9,
            },
            file_line_counts={
                "Classes/A.swift": (3, 3),
                "Classes/B.swift": (1, 2),
            },
        )

        self.assertNotIn("Classes/A.swift", ratcheted.files)
        self.assertNotIn("Classes/B.swift", ratcheted.files)
        self.assertEqual(ratcheted.files["Classes/NewFeature.swift"], 0.9)
        self.assertEqual(ratcheted.groups["Split surface"].minimum_line_coverage, 0.8)

    def test_relative_source_path_uses_source_directory_nearest_the_file(self) -> None:
        relative = self.module.relative_source_path(
            "/Users/Classes/workspace/gitx/Classes/A.m",
            pathlib.Path("/tmp/gitx"),
        )

        self.assertEqual(relative, "Classes/A.m")


if __name__ == "__main__":
    unittest.main()
