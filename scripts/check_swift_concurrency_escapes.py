#!/usr/bin/env python3
"""Reject undocumented Swift concurrency and type-safety escape hatches."""

from __future__ import annotations

import argparse
import pathlib
import re
from collections.abc import Iterable


ROOT = pathlib.Path(__file__).resolve().parents[1]
JUSTIFICATION_MARKER = "swift6-safety-justification:"
ESCAPE_PATTERNS = (
    re.compile(r"@unchecked\s+Sendable"),
    re.compile(r"nonisolated\s*\(\s*unsafe\s*\)"),
    re.compile(r"@preconcurrency\b"),
    re.compile(r"\bassumeIsolated\b"),
    re.compile(r"\bunsafeBitCast\b"),
    re.compile(r"@retroactive\b"),
)


def swift_files(paths: Iterable[pathlib.Path]) -> Iterable[pathlib.Path]:
    for path in paths:
        if path.is_file() and path.suffix == ".swift":
            yield path
        elif path.is_dir():
            yield from sorted(path.rglob("*.swift"))


def scan(paths: Iterable[pathlib.Path]) -> list[tuple[pathlib.Path, int, str]]:
    findings: list[tuple[pathlib.Path, int, str]] = []
    for path in swift_files(paths):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            for pattern in ESCAPE_PATTERNS:
                match = pattern.search(line)
                if match is None:
                    continue
                context = lines[max(0, index - 2) : index + 1]
                if not any(JUSTIFICATION_MARKER in candidate for candidate in context):
                    findings.append((path, index + 1, match.group(0)))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        type=pathlib.Path,
        default=[ROOT / "Classes", ROOT / "GitXTests"],
    )
    args = parser.parse_args()

    findings = scan(args.paths)
    for path, line, escape in findings:
        try:
            display_path = path.relative_to(ROOT)
        except ValueError:
            display_path = path
        print(
            f"{display_path}:{line}: '{escape}' requires a nearby "
            f"'{JUSTIFICATION_MARKER}' comment"
        )

    if findings:
        print(f"Found {len(findings)} undocumented Swift safety escape(s).")
        return 1

    print("Swift concurrency escape-hatch check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
