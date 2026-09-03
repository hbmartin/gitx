#!/usr/bin/env python3
"""Print only the failing tests from an Xcode result bundle.

`xcodebuild test` output and the raw `xcresulttool` JSON are both far larger
than the information a reader actually needs after a red run. This reporter
extracts one line per failure: the test identifier, the source location, and
the assertion message.

Usage:
    scripts/report_xcresult.py build/Logs/last-test.xcresult
    scripts/report_xcresult.py --format json result.xcresult
    scripts/report_xcresult.py --full result.xcresult

Exits 1 when the bundle records failures, 0 when it is clean, and 2 when the
bundle cannot be read.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from typing import Iterator, NamedTuple


DEFAULT_MAX_CHARS = 500
DEFAULT_MAX_PER_TEST = 3

# Failure messages arrive as "SomeFile.swift:221: XCTAssertEqual failed: ...".
# The location prefix is optional: runner-level failures carry no source line.
# The file token rejects spaces so prose such as "Timed out at 12:30: waiting"
# is kept as a message rather than misread as a source location.
LOCATION_PATTERN = re.compile(r"^(?P<file>[^\s:]+):(?P<line>\d+):\s*(?P<message>.*)$", re.DOTALL)


class Failure(NamedTuple):
    target: str
    test: str
    file: str | None
    line: int | None
    message: str


def run_xcresulttool(bundle: pathlib.Path, subcommand: str) -> dict:
    """Return parsed JSON from `xcresulttool get test-results <subcommand>`."""
    completed = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            subcommand,
            "--path",
            str(bundle),
            "--format",
            "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"xcresulttool {subcommand} failed")
    return json.loads(completed.stdout)


def parse_failure_message(text: str) -> tuple[str | None, int | None, str]:
    """Split a failure message into its file, line, and remaining message."""
    match = LOCATION_PATTERN.match(text.strip())
    if match is None:
        return None, None, text.strip()
    return match.group("file"), int(match.group("line")), match.group("message").strip()


def walk(node: dict, bundle_name: str = "") -> Iterator[tuple[dict, str]]:
    """Yield every node paired with the test bundle that contains it."""
    if node.get("nodeType") == "Unit test bundle" or node.get("nodeType") == "UI test bundle":
        bundle_name = node.get("name", bundle_name)
    yield node, bundle_name
    for child in node.get("children") or []:
        yield from walk(child, bundle_name)


# Failure messages sit directly under a "Test Case" for a plain run, but one
# level deeper under "Repetition" (-retry-tests-on-failure, -test-iterations),
# "Device", "Test Plan Configuration", or "Arguments" nodes. The bound keeps a
# pathological tree from being walked forever.
FAILURE_MESSAGE_MAX_DEPTH = 4


def failure_messages(node: dict, max_depth: int = FAILURE_MESSAGE_MAX_DEPTH) -> list[str]:
    """Return the distinct failure messages recorded anywhere under a test case."""
    messages: list[str] = []
    seen: set[str] = set()

    def visit(current: dict, depth: int) -> None:
        for child in current.get("children") or []:
            node_type = child.get("nodeType")
            if node_type == "Failure Message":
                text = child.get("name", "")
                if text not in seen:
                    seen.add(text)
                    messages.append(text)
            elif node_type != "Test Case" and depth < max_depth:
                visit(child, depth + 1)

    visit(node, 0)
    return messages


def collect_failures(payload: dict, max_per_test: int = DEFAULT_MAX_PER_TEST) -> list[Failure]:
    """Extract failures from a `get test-results tests` payload."""
    # A non-positive cap would slice nothing (or, negative, from the wrong
    # end) and misstate the "... and N more" remainder.
    max_per_test = max(1, max_per_test)
    failures: list[Failure] = []
    for root in payload.get("testNodes") or []:
        for node, bundle_name in walk(root):
            if node.get("nodeType") != "Test Case" or node.get("result") != "Failed":
                continue
            test = node.get("nodeIdentifier") or node.get("name") or "<unknown test>"
            messages = failure_messages(node)
            if not messages:
                failures.append(Failure(bundle_name, test, None, None, "Test failed without a message"))
                continue
            for text in messages[:max_per_test]:
                path, line, message = parse_failure_message(text)
                failures.append(Failure(bundle_name, test, path, line, message))
            remaining = len(messages) - max_per_test
            if remaining > 0:
                failures.append(
                    Failure(bundle_name, test, None, None, f"... and {remaining} more failure(s) in this test")
                )
    return failures


def collect_runner_failures(summary: dict, seen_tests: set[str]) -> list[Failure]:
    """Recover failures the test tree omits, such as runner start-up errors."""
    failures: list[Failure] = []
    for entry in summary.get("testFailures") or []:
        identifier = entry.get("testIdentifierString") or entry.get("testName") or "<unknown test>"
        if identifier in seen_tests:
            continue
        path, line, message = parse_failure_message(entry.get("failureText", ""))
        failures.append(Failure(entry.get("targetName", ""), identifier, path, line, message))
    return failures


def build_path_index(root: pathlib.Path) -> dict[str, str]:
    """Map each unambiguous source basename to its repository-relative path."""
    completed = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return {}
    index: dict[str, str] = {}
    ambiguous: set[str] = set()
    for line in completed.stdout.splitlines():
        name = line.rsplit("/", 1)[-1]
        if name in index and index[name] != line:
            ambiguous.add(name)
        index[name] = line
    for name in ambiguous:
        index.pop(name, None)
    return index


def resolve(failure: Failure, index: dict[str, str]) -> Failure:
    """Expand a bare basename into a repository-relative path when unambiguous."""
    if failure.file is None or pathlib.PurePath(failure.file).name != failure.file:
        return failure
    resolved = index.get(failure.file)
    if resolved is None:
        return failure
    return failure._replace(file=resolved)


def truncate(message: str, limit: int | None) -> str:
    collapsed = " ".join(message.split())
    if limit is None or len(collapsed) <= limit:
        return collapsed
    return collapsed[:limit].rstrip() + " ..."


def format_report(failures: list[Failure], limit: int | None) -> str:
    if not failures:
        return "No failing tests."
    lines: list[str] = []
    tests = {failure.test for failure in failures}
    lines.append(f"{len(tests)} failing test(s), {len(failures)} failure message(s)")
    current = None
    for failure in failures:
        if failure.test != current:
            current = failure.test
            label = f"{failure.target}: " if failure.target else ""
            lines.append("")
            lines.append(f"{label}{failure.test}")
        if failure.file and failure.line:
            location = f"{failure.file}:{failure.line}: "
        else:
            location = ""
        lines.append(f"  {location}{truncate(failure.message, limit)}")
    return "\n".join(lines)


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def executed_any_test(summary: dict) -> bool:
    """Report whether the bundle records any test at all."""
    counted = summary.get("totalTestCount")
    if isinstance(counted, int) and counted > 0:
        return True
    return any(
        isinstance(summary.get(key), int) and summary[key] > 0
        for key in ("passedTests", "failedTests", "skippedTests", "expectedFailures")
    )


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    # `python3 -OO` strips docstrings, so the description must not rely on one.
    parser = argparse.ArgumentParser(description=next(iter((__doc__ or "").splitlines()), None))
    parser.add_argument("result_bundle", type=pathlib.Path)
    parser.add_argument(
        "--max-chars",
        type=positive_int,
        default=DEFAULT_MAX_CHARS,
        help=f"Truncate each message to this many characters (default {DEFAULT_MAX_CHARS}).",
    )
    parser.add_argument(
        "--max-per-test",
        type=positive_int,
        default=DEFAULT_MAX_PER_TEST,
        help=f"Report at most this many messages per test (default {DEFAULT_MAX_PER_TEST}).",
    )
    parser.add_argument("--full", action="store_true", help="Do not truncate messages.")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    bundle = arguments.result_bundle
    if not bundle.exists():
        print(f"Result bundle not found: {bundle}", file=sys.stderr)
        return 2

    try:
        tests = run_xcresulttool(bundle, "tests")
        summary = run_xcresulttool(bundle, "summary")
    except (RuntimeError, json.JSONDecodeError) as error:
        print(f"Could not read {bundle}: {error}", file=sys.stderr)
        return 2

    failures = collect_failures(tests, arguments.max_per_test)
    failures.extend(collect_runner_failures(summary, {failure.test for failure in failures}))

    index = build_path_index(pathlib.Path(__file__).resolve().parents[1])
    failures = [resolve(failure, index) for failure in failures]

    limit = None if arguments.full else arguments.max_chars
    if arguments.format == "json":
        print(json.dumps([failure._asdict() for failure in failures], indent=2))
    else:
        print(format_report(failures, limit))
    if failures:
        return 1
    if not executed_any_test(summary):
        # A build failure produces a result bundle with no tests in it. Reporting
        # "no failing tests" there would read as success for a run that never ran.
        print(
            "No tests were executed. The build most likely failed; "
            "see build/Logs/last-xcodebuild.log",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
