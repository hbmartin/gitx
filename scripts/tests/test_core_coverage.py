from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


class CoreCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_core_coverage.py")

    def test_extracts_only_package_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / "Sources" / "GitXCore"
            root.mkdir(parents=True)
            source = root / "Policy.swift"
            report = {
                "data": [{
                    "files": [
                        {
                            "filename": str(source),
                            "summary": {"lines": {"covered": 9, "count": 10, "percent": 90}},
                        },
                        {
                            "filename": str(root.parent.parent / "Tests" / "PolicyTests.swift"),
                            "summary": {"lines": {"covered": 100, "count": 100, "percent": 100}},
                        },
                    ]
                }]
            }

            target, files = self.module.extract_coverage(report, root)

        self.assertEqual(target, 0.9)
        self.assertEqual(files, {"Policy.swift": 0.9})

    def test_regression_and_new_file_fail(self) -> None:
        policy = self.module.CoreCoveragePolicy("GitXCore", 0.9, {"Policy.swift": 0.95})
        failures = self.module.evaluate_coverage(
            policy,
            target_coverage=0.89,
            file_coverage={"Policy.swift": 0.94, "New.swift": 1.0},
        )
        self.assertEqual(len(failures), 3)

    def test_ratchet_never_lowers_existing_floor(self) -> None:
        policy = self.module.CoreCoveragePolicy("GitXCore", 0.9, {"Policy.swift": 0.95})
        ratcheted = self.module.ratchet_policy(
            policy,
            target_coverage=0.92,
            file_coverage={"Policy.swift": 0.94, "New.swift": 0.87659},
        )
        self.assertEqual(ratcheted.minimum_line_coverage, 0.92)
        self.assertEqual(ratcheted.files["Policy.swift"], 0.95)
        self.assertEqual(ratcheted.files["New.swift"], 0.8765)


if __name__ == "__main__":
    unittest.main()
