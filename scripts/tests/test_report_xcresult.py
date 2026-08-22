from __future__ import annotations

import contextlib
import io
import unittest

from support import load_script


reporter = load_script("report_xcresult.py")


def failure_message(name: str) -> dict:
    return {"nodeType": "Failure Message", "name": name}


def test_case(identifier: str, result: str, messages: list[str]) -> dict:
    return {
        "nodeType": "Test Case",
        "nodeIdentifier": identifier,
        "name": identifier,
        "result": result,
        "children": [failure_message(message) for message in messages],
    }


def payload(cases: list[dict], bundle: str = "GitXTests") -> dict:
    return {
        "testNodes": [
            {
                "nodeType": "Test Plan",
                "name": "GitX",
                "children": [
                    {
                        "nodeType": "Unit test bundle",
                        "name": bundle,
                        "children": cases,
                    }
                ],
            }
        ]
    }


class ParseFailureMessageTests(unittest.TestCase):
    def test_extracts_file_and_line(self) -> None:
        parsed = reporter.parse_failure_message("GitXSwiftFeatureTests.swift:221: XCTAssertEqual failed: (1)")

        self.assertEqual(parsed, ("GitXSwiftFeatureTests.swift", 221, "XCTAssertEqual failed: (1)"))

    def test_tolerates_message_without_location(self) -> None:
        parsed = reporter.parse_failure_message("The test runner failed to initialize.")

        self.assertEqual(parsed, (None, None, "The test runner failed to initialize."))

    def test_does_not_treat_a_bare_colon_as_a_location(self) -> None:
        parsed = reporter.parse_failure_message("Underlying Error: Timed out")

        self.assertEqual(parsed, (None, None, "Underlying Error: Timed out"))

    def test_does_not_treat_prose_with_spaces_as_a_location(self) -> None:
        message = "Timed out at 12:30: waiting for overlay"

        parsed = reporter.parse_failure_message(message)

        self.assertEqual(parsed, (None, None, message))


class CollectFailuresTests(unittest.TestCase):
    def test_reports_only_failed_cases(self) -> None:
        document = payload(
            [
                test_case("SuiteA/testPasses()", "Passed", []),
                test_case("SuiteA/testFails()", "Failed", ["File.swift:12: boom"]),
            ]
        )

        failures = reporter.collect_failures(document)

        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0].test, "SuiteA/testFails()")
        self.assertEqual(failures[0].target, "GitXTests")
        self.assertEqual((failures[0].file, failures[0].line), ("File.swift", 12))

    def test_records_a_failure_without_any_message(self) -> None:
        failures = reporter.collect_failures(payload([test_case("SuiteA/testFails()", "Failed", [])]))

        self.assertEqual(len(failures), 1)
        self.assertIsNone(failures[0].file)
        self.assertIn("without a message", failures[0].message)

    def test_caps_messages_per_test_and_notes_the_remainder(self) -> None:
        messages = [f"File.swift:{index}: boom" for index in range(1, 6)]

        failures = reporter.collect_failures(payload([test_case("S/t()", "Failed", messages)]), max_per_test=2)

        self.assertEqual(len(failures), 3)
        self.assertIn("and 3 more failure(s)", failures[-1].message)

    def test_clamps_a_nonpositive_cap_to_one_message(self) -> None:
        messages = [f"File.swift:{index}: boom" for index in range(1, 4)]

        failures = reporter.collect_failures(payload([test_case("S/t()", "Failed", messages)]), max_per_test=0)

        self.assertEqual(len(failures), 2)
        self.assertEqual((failures[0].file, failures[0].line), ("File.swift", 1))
        self.assertIn("and 2 more failure(s)", failures[-1].message)


class RunnerFailureTests(unittest.TestCase):
    def test_adds_failures_missing_from_the_test_tree(self) -> None:
        summary = {
            "testFailures": [
                {
                    "testIdentifierString": "Runner encountered an error",
                    "targetName": "GitXUITests",
                    "failureText": "Timed out while enabling automation mode.",
                }
            ]
        }

        failures = reporter.collect_runner_failures(summary, seen_tests=set())

        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0].target, "GitXUITests")

    def test_skips_failures_already_reported_by_the_test_tree(self) -> None:
        summary = {"testFailures": [{"testIdentifierString": "S/t()", "failureText": "boom"}]}

        self.assertEqual(reporter.collect_runner_failures(summary, seen_tests={"S/t()"}), [])


class FormattingTests(unittest.TestCase):
    def test_truncates_to_the_limit(self) -> None:
        self.assertEqual(reporter.truncate("a" * 20, 5), "aaaaa ...")

    def test_collapses_whitespace_without_a_limit(self) -> None:
        self.assertEqual(reporter.truncate("a\n  b", None), "a b")

    def test_reports_a_clean_bundle(self) -> None:
        self.assertEqual(reporter.format_report([], 100), "No failing tests.")

    def test_groups_messages_under_each_test(self) -> None:
        failures = reporter.collect_failures(
            payload([test_case("S/t()", "Failed", ["File.swift:1: first", "File.swift:2: second"])])
        )

        report = reporter.format_report(failures, 100)

        self.assertIn("1 failing test(s), 2 failure message(s)", report)
        self.assertEqual(report.count("S/t()"), 1)
        self.assertIn("File.swift:1: first", report)


class ParseArgumentsTests(unittest.TestCase):
    def reject(self, *arguments: str) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            reporter.parse_arguments(["bundle.xcresult", *arguments])

    def test_rejects_a_nonpositive_message_cap(self) -> None:
        self.reject("--max-per-test", "0")
        self.reject("--max-per-test", "-2")

    def test_rejects_a_nonpositive_character_limit(self) -> None:
        self.reject("--max-chars", "0")

    def test_accepts_positive_limits(self) -> None:
        arguments = reporter.parse_arguments(["bundle.xcresult", "--max-per-test", "1", "--max-chars", "10"])

        self.assertEqual((arguments.max_per_test, arguments.max_chars), (1, 10))


class ExecutedAnyTestTests(unittest.TestCase):
    def test_counts_a_populated_run_as_executed(self) -> None:
        self.assertTrue(reporter.executed_any_test({"totalTestCount": 65, "passedTests": 65}))

    def test_treats_an_empty_bundle_as_not_executed(self) -> None:
        self.assertFalse(reporter.executed_any_test({"totalTestCount": 0, "passedTests": 0}))

    def test_treats_a_bundle_without_counts_as_not_executed(self) -> None:
        self.assertFalse(reporter.executed_any_test({}))

    def test_falls_back_to_individual_counts(self) -> None:
        self.assertTrue(reporter.executed_any_test({"skippedTests": 3}))


class ResolveTests(unittest.TestCase):
    def test_expands_an_unambiguous_basename(self) -> None:
        failure = reporter.Failure("GitXTests", "S/t()", "File.swift", 3, "boom")

        resolved = reporter.resolve(failure, {"File.swift": "GitXTests/File.swift"})

        self.assertEqual(resolved.file, "GitXTests/File.swift")

    def test_leaves_an_unknown_basename_alone(self) -> None:
        failure = reporter.Failure("GitXTests", "S/t()", "File.swift", 3, "boom")

        self.assertEqual(reporter.resolve(failure, {}).file, "File.swift")

    def test_preserves_a_reported_path_instead_of_matching_its_basename(self) -> None:
        failure = reporter.Failure("GitXTests", "S/t()", "ThirdParty/File.swift", 3, "boom")

        resolved = reporter.resolve(failure, {"File.swift": "GitXTests/File.swift"})

        self.assertEqual(resolved.file, "ThirdParty/File.swift")

    def test_ignores_failures_without_a_file(self) -> None:
        failure = reporter.Failure("GitXTests", "S/t()", None, None, "boom")

        self.assertIsNone(reporter.resolve(failure, {"File.swift": "x/File.swift"}).file)


if __name__ == "__main__":
    unittest.main()
