from __future__ import annotations

import unittest

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
            added_lines={"Classes/Legacy.h": ["- (void)refresh;"]},
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
            added_lines={"Classes/Modern.h": ["- (NSArray *)items;"]},
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
            added_lines={"Classes/Modern.h": ["- (BOOL)load:(NSError **)error;"]},
        )

        self.assertTrue(any("error out-parameter" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
