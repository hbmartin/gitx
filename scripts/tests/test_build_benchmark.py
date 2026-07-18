from __future__ import annotations

import unittest

from support import load_script


class BuildBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("benchmark_build.py")

    def test_medians_use_all_samples(self) -> None:
        samples = [
            self.module.BuildSample(1, 120, 20),
            self.module.BuildSample(2, 80, 10),
            self.module.BuildSample(3, 100, 15),
        ]

        self.assertEqual(self.module.medians(samples), (100, 15))

    def test_thresholds_report_each_regression(self) -> None:
        failures = self.module.threshold_failures(
            11,
            6,
            cold_ceiling=10,
            warm_ceiling=5,
        )

        self.assertEqual(len(failures), 2)

    def test_current_or_faster_medians_pass(self) -> None:
        self.assertEqual(
            self.module.threshold_failures(
                self.module.COLD_CEILING_SECONDS,
                self.module.WARM_CEILING_SECONDS,
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
