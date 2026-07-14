#!/usr/bin/env python3
"""Check clang-format only on Objective-C lines changed from a Git base."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(?P<start>\d+)(?:,(?P<count>\d+))? @@")
CONTEXT_LINES = 5


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, capture_output=True, text=True)


def changed_ranges(base: str, path: pathlib.Path) -> list[tuple[int, int]]:
    tracked = run("git", "ls-files", "--error-unmatch", str(path), check=False).returncode == 0
    if not tracked:
        line_count = sum(1 for _ in path.open(errors="replace"))
        return [(1, max(line_count, 1))]

    diff = run("git", "diff", "--unified=0", base, "--", str(path)).stdout
    ranges: list[tuple[int, int]] = []
    for line in diff.splitlines():
        match = HUNK.match(line)
        if not match:
            continue
        start = int(match.group("start"))
        count = int(match.group("count") or "1")
        if count:
            ranges.append((max(1, start - CONTEXT_LINES), start + count - 1 + CONTEXT_LINES))

    merged: list[tuple[int, int]] = []
    for start, end in ranges:
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def main() -> int:
    arguments = sys.argv[1:]
    fix = "--fix" in arguments
    arguments = [argument for argument in arguments if argument != "--fix"]
    if len(arguments) < 2:
        print(f"Usage: {sys.argv[0]} <git-base> [--fix] <file>...", file=sys.stderr)
        return 2

    base, *names = arguments
    failures: list[str] = []
    for name in names:
        path = pathlib.Path(name)
        if not path.is_file():
            continue
        ranges = changed_ranges(base, path)
        if not ranges:
            continue

        command = ["xcrun", "clang-format", "--style=file"]
        if fix:
            command.append("-i")
        else:
            command.extend(("--dry-run", "--Werror"))
        command.extend(f"--lines={start}:{end}" for start, end in ranges)
        result = run(*command, str(path), check=False)
        if not fix and result.returncode:
            failures.append(name)
            print(result.stderr, file=sys.stderr, end="")

    if failures:
        print("Changed Objective-C lines need clang-format:", file=sys.stderr)
        for name in failures:
            print(f"- {name}", file=sys.stderr)
        return 1

    action = "Formatted" if fix else "Checked"
    print(f"{action} changed Objective-C lines.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
