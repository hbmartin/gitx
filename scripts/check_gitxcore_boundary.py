#!/usr/bin/env python3
"""Reject dependencies that would make GitXCore require the application host."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ALLOWED_IMPORTS = {"Foundation"}
FORBIDDEN_PATTERNS = {
    "application framework": re.compile(r"^\s*import\s+(AppKit|Cocoa|WebKit)\b", re.MULTILINE),
    "application target": re.compile(r"^\s*import\s+GitX\b", re.MULTILINE),
    "global defaults": re.compile(r"\bUserDefaults\s*\.\s*standard\b"),
    "global notifications": re.compile(r"\bNotificationCenter\s*\.\s*default\b"),
    "process execution": re.compile(r"\bProcess\s*\("),
    "application singleton": re.compile(r"\bNSApplication\b|\bNSApp\b"),
}


def imported_modules(source: str) -> set[str]:
    return set(re.findall(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", source, re.MULTILINE))


def boundary_failures(source_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    for path in sorted(source_root.rglob("*.swift")):
        source = path.read_text()
        relative = path.relative_to(source_root)
        for module in sorted(imported_modules(source) - ALLOWED_IMPORTS):
            failures.append(f"{relative}: imports disallowed module {module}")
        for description, pattern in FORBIDDEN_PATTERNS.items():
            if pattern.search(source):
                failures.append(f"{relative}: contains {description}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source_root",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "GitXCore" / "Sources",
    )
    args = parser.parse_args()

    failures = boundary_failures(args.source_root)
    if failures:
        print("GitXCore boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"GitXCore boundary check passed ({args.source_root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
