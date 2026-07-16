from __future__ import annotations

import pathlib
import subprocess
import unittest
from unittest import mock

from support import load_script


class HeaderInteropTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_header_interop.py")

    def test_changed_debt_header_requires_nullability(self) -> None:
        failures = self.module.evaluate_headers(
            headers={"Classes/Legacy.h": "@interface Legacy : NSObject\n@end\n"},
            baseline={"Classes/Legacy.h"},
            changed_headers={"Classes/Legacy.h"},
            added_lines={"Classes/Legacy.h": [(2, "- (void)refresh;")]},
        )

        self.assertTrue(any("NS_ASSUME_NONNULL" in failure for failure in failures))

    def test_stale_debt_entry_must_be_removed(self) -> None:
        failures = self.module.evaluate_headers(
            headers={
                "Classes/Modernized.h": (
                    "NS_ASSUME_NONNULL_BEGIN\n"
                    "@interface Modernized : NSObject\n"
                    "@end\n"
                    "NS_ASSUME_NONNULL_END\n"
                )
            },
            baseline={"Classes/Modernized.h"},
            changed_headers=set(),
            added_lines={},
        )

        self.assertTrue(any("remove" in failure.lower() for failure in failures))

    def test_added_raw_collection_declaration_is_rejected(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "- (NSArray *)items;\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
        )
        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={"Classes/Modern.h": [(3, "- (NSArray *)items;")]},
        )

        self.assertTrue(any("lightweight generics" in failure for failure in failures))

    def test_added_error_out_parameter_requires_explicit_nullability(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "- (BOOL)load:(NSError **)error;\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
        )
        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={"Classes/Modern.h": [(3, "- (BOOL)load:(NSError **)error;")]},
        )

        self.assertTrue(any("error out-parameter" in failure for failure in failures))

    def test_added_source_lines_keeps_code_beginning_with_double_plus(self) -> None:
        diff = "\n".join(
            [
                "diff --git a/Classes/Modern.h b/Classes/Modern.h",
                "--- a/Classes/Modern.h",
                "+++ b/Classes/Modern.h",
                "@@ -1,0 +2 @@",
                "+++index;",
            ]
        )
        tracked = subprocess.CompletedProcess(args=[], returncode=0)

        with (
            mock.patch.object(self.module.subprocess, "run", return_value=tracked),
            mock.patch.object(self.module, "run", return_value=diff),
        ):
            lines = self.module.added_source_lines(
                pathlib.Path("/tmp/repository"),
                "merge-base",
                "Classes/Modern.h",
            )

        self.assertEqual(lines, [(2, "++index;")])

    def test_line_comment_does_not_trigger_raw_collection_check(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "// Legacy implementation returned NSArray * here.\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
        )

        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={
                "Classes/Modern.h": [(3, "// Legacy implementation returned NSArray * here.")]
            },
        )

        self.assertEqual(failures, [])

    def test_line_comment_cannot_supply_error_parameter_nullability(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "- (BOOL)load:(NSError **)error; // nullable error in legacy code\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
        )

        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={
                "Classes/Modern.h": [
                    (3, "- (BOOL)load:(NSError **)error; // nullable error in legacy code")
                ]
            },
        )

        self.assertTrue(any("error out-parameter" in failure for failure in failures))

    def test_added_declaration_must_be_inside_nullability_region(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
            "- (NSString *)lateTitle;\n"
        )

        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={"Classes/Modern.h": [(5, "- (NSString *)lateTitle;")]},
        )

        self.assertTrue(any("Classes/Modern.h:5" in failure for failure in failures))
        self.assertTrue(any("nullability region" in failure for failure in failures))

    def test_explicitly_annotated_declaration_can_be_outside_region(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_BEGIN\n"
            "@interface Modern : NSObject\n"
            "@end\n"
            "NS_ASSUME_NONNULL_END\n"
            "- (NSString * _Nullable)optionalLateTitle;\n"
        )

        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={
                "Classes/Modern.h": [(5, "- (NSString * _Nullable)optionalLateTitle;")]
            },
        )

        self.assertEqual(failures, [])

    def test_reversed_nullability_markers_do_not_form_a_region(self) -> None:
        header = (
            "NS_ASSUME_NONNULL_END\n"
            "@interface Modern : NSObject\n"
            "- (void)refresh;\n"
            "@end\n"
            "NS_ASSUME_NONNULL_BEGIN\n"
        )

        failures = self.module.evaluate_headers(
            headers={"Classes/Modern.h": header},
            baseline=set(),
            changed_headers={"Classes/Modern.h"},
            added_lines={"Classes/Modern.h": [(3, "- (void)refresh;")]},
        )

        self.assertTrue(any("correctly ordered" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
