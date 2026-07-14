from __future__ import annotations

import unittest

from support import load_script


class AnalyzerDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_analyzer_diagnostics.py")

    def test_new_warning_is_not_hidden_by_an_existing_category_budget(self) -> None:
        existing = self.module.WarningFingerprint(
            path="Classes/Legacy.m",
            category="-Wdeprecated-declarations",
            message="'oldAPI' is deprecated",
        )
        replacement = self.module.WarningFingerprint(
            path="Classes/NewCode.m",
            category="-Wdeprecated-declarations",
            message="'differentOldAPI' is deprecated",
        )

        failures = self.module.compare_warning_baseline(
            current={replacement: 1},
            baseline={existing: 1},
        )

        self.assertTrue(any("new warning" in failure.lower() for failure in failures))

    def test_removed_warning_requires_baseline_ratchet(self) -> None:
        old = self.module.WarningFingerprint(
            path="Classes/Legacy.m",
            category="-Wdeprecated-declarations",
            message="'oldAPI' is deprecated",
        )

        failures = self.module.compare_warning_baseline(current={}, baseline={old: 1})

        self.assertTrue(any("stale" in failure.lower() for failure in failures))

    def test_parser_normalizes_first_party_paths_and_ignores_column_changes(self) -> None:
        first = (
            "/tmp/build/GitX/Classes/Legacy.m:10:2: warning: "
            "'oldAPI' is deprecated [-Wdeprecated-declarations]"
        )
        moved = (
            "/tmp/build/GitX/Classes/Legacy.m:42:17: warning: "
            "'oldAPI' is deprecated [-Wdeprecated-declarations]"
        )

        first_diagnostic = self.module.parse_diagnostics(first)[0]
        moved_diagnostic = self.module.parse_diagnostics(moved)[0]

        self.assertEqual(first_diagnostic.fingerprint, moved_diagnostic.fingerprint)
        self.assertEqual(first_diagnostic.fingerprint.path, "Classes/Legacy.m")

        test_diagnostic = self.module.parse_diagnostics(
            "/tmp/build/GitX/GitXTests/GitXCoreTests.m:12:4: warning: "
            "test warning [-Wunused-variable]"
        )[0]
        self.assertEqual(test_diagnostic.path, "GitXTests/GitXCoreTests.m")

    def test_parser_uses_source_directory_nearest_the_file(self) -> None:
        diagnostic = self.module.parse_diagnostics(
            "/Users/Classes/workspace/gitx/Classes/Legacy.m:10:2: warning: "
            "'oldAPI' is deprecated [-Wdeprecated-declarations]"
        )[0]

        self.assertEqual(diagnostic.path, "Classes/Legacy.m")


if __name__ == "__main__":
    unittest.main()
