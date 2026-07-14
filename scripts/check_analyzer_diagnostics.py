#!/usr/bin/env python3
"""Enforce analyzer findings and a shrinking budget for compiler warnings."""

from __future__ import annotations

import collections
import json
import pathlib
import re
import sys


DIAGNOSTIC = re.compile(
    r"^(?P<path>.+?/Classes/.+?):(?P<line>\d+):(?P<column>\d+): "
    r"(?P<severity>warning|error): (?P<message>.+)$"
)
COMPILER_WARNING = re.compile(r"\[(?P<category>-W[^]]+)\]$")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <xcodebuild.log>", file=sys.stderr)
        return 2

    log_path = pathlib.Path(sys.argv[1])
    diagnostics: dict[tuple[str, str, str, str], str] = {}
    for line in log_path.read_text(errors="replace").splitlines():
        match = DIAGNOSTIC.match(line)
        if not match:
            continue
        key = (
            str(pathlib.Path(match.group("path"))),
            match.group("line"),
            match.group("severity"),
            match.group("message"),
        )
        diagnostics[key] = line

    if not diagnostics:
        print("No first-party Xcode diagnostics found.")
        return 0

    analyzer_findings: list[str] = []
    compiler_warnings: collections.Counter[str] = collections.Counter()
    for key, line in diagnostics.items():
        severity = key[2]
        message = key[3]
        compiler_match = COMPILER_WARNING.search(message)
        if severity == "error" or not compiler_match:
            analyzer_findings.append(line)
        else:
            compiler_warnings[compiler_match.group("category")] += 1

    budget_path = pathlib.Path(__file__).with_name("xcode-warning-budget.json")
    budgets = json.loads(budget_path.read_text())
    exceeded: list[str] = []
    for category, count in sorted(compiler_warnings.items()):
        budget = budgets.get(category, 0)
        print(f"{category}: {count}/{budget}")
        if count > budget:
            exceeded.append(f"{category}: found {count}, budget is {budget}")

    if analyzer_findings:
        print(f"Found {len(analyzer_findings)} first-party analyzer finding(s) or error(s):", file=sys.stderr)
        for line in sorted(analyzer_findings):
            print(line, file=sys.stderr)
    if exceeded:
        print("Compiler warning budget exceeded:", file=sys.stderr)
        for line in exceeded:
            print(line, file=sys.stderr)

    if analyzer_findings or exceeded:
        return 1

    print(f"Analyzer passed; {sum(compiler_warnings.values())} budgeted compiler warning(s) remain.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
