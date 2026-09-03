#!/usr/bin/env python3
"""Keep FlowDelta imports inside GitX's two explicit adapter seams."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ALLOWED_FILES = {
    pathlib.Path("Controllers/FlowDeltaAdapters.swift"),
    pathlib.Path("Controllers/HistoryFlowRevisionProvider.swift"),
}
FLOWDELTA_IMPORT = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*"
    r"import\s+FlowDelta[A-Za-z0-9_]*\b",
    re.MULTILINE,
)


def boundary_failures(source_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    swift_files = sorted(source_root.rglob("*.swift"))
    relative_files = {path.relative_to(source_root) for path in swift_files}

    for required in sorted(ALLOWED_FILES):
        if required not in relative_files:
            failures.append(f"Missing FlowDelta integration seam {required}")

    for path in swift_files:
        relative = path.relative_to(source_root)
        if relative not in ALLOWED_FILES and FLOWDELTA_IMPORT.search(path.read_text()):
            failures.append(f"{relative}: imports FlowDelta outside an approved integration seam")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source_root",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "Classes",
    )
    args = parser.parse_args()

    failures = boundary_failures(args.source_root)
    if failures:
        print("FlowDelta boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"FlowDelta boundary check passed ({args.source_root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
