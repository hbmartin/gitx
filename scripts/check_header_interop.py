#!/usr/bin/env python3
"""Enforce a shrinking Objective-C header interoperability debt baseline."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from collections.abc import Iterable


RAW_COLLECTION = re.compile(r"\b(?:NSArray|NSDictionary|NSSet|NSOrderedSet)\s*\*")
ERROR_OUT_PARAMETER = re.compile(r"\bNSError\s*\*\s*(?:__autoreleasing\s*)?\*")
NULLABILITY_MARKERS = ("nullable", "_Nullable")


def run(*args: str, cwd: pathlib.Path) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


def load_baseline(path: pathlib.Path) -> tuple[set[str], set[str]]:
    payload = json.loads(path.read_text())
    if payload.get("version") != 1:
        raise ValueError(f"Unsupported header baseline version in {path}")
    return set(payload["unannotatedHeaders"]), set(payload.get("excludedHeaders", []))


def has_nullability_region(contents: str) -> bool:
    return "NS_ASSUME_NONNULL_BEGIN" in contents and "NS_ASSUME_NONNULL_END" in contents


def evaluate_headers(
    *,
    headers: dict[str, str],
    baseline: set[str],
    changed_headers: set[str],
    added_lines: dict[str, list[str]],
) -> list[str]:
    failures: list[str] = []
    current_debt = {path for path, contents in headers.items() if not has_nullability_region(contents)}

    for path in sorted(current_debt - baseline):
        failures.append(f"{path} adds untracked nullability debt; add an NS_ASSUME_NONNULL region")
    for path in sorted(baseline - current_debt):
        failures.append(f"{path} is no longer nullability debt; remove it from the checked-in baseline")
    for path in sorted(changed_headers & current_debt):
        failures.append(f"{path} was modified and must add NS_ASSUME_NONNULL_BEGIN/END")

    for path in sorted(changed_headers):
        for line_number, line in enumerate(added_lines.get(path, []), start=1):
            if RAW_COLLECTION.search(line):
                failures.append(
                    f"{path} added a raw collection declaration ({line.strip()}); add lightweight generics"
                )
            if ERROR_OUT_PARAMETER.search(line) and not any(marker in line for marker in NULLABILITY_MARKERS):
                failures.append(
                    f"{path} added an error out-parameter without explicit nullable annotations ({line.strip()})"
                )

    return failures


def changed_paths(root: pathlib.Path, merge_base: str) -> set[str]:
    tracked = run(
        "git",
        "diff",
        "--diff-filter=ACMR",
        "--name-only",
        merge_base,
        cwd=root,
    ).splitlines()
    untracked = run("git", "ls-files", "--others", "--exclude-standard", cwd=root).splitlines()
    return {path for path in tracked + untracked if path}


def added_source_lines(root: pathlib.Path, merge_base: str, path: str) -> list[str]:
    file_path = root / path
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", path],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    ).returncode == 0
    if not tracked:
        return file_path.read_text(errors="replace").splitlines() if file_path.is_file() else []

    diff = run("git", "diff", "--unified=0", merge_base, "--", path, cwd=root)
    lines: list[str] = []
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
    return lines


def first_party_headers(root: pathlib.Path, excluded: Iterable[str]) -> dict[str, str]:
    excluded_set = set(excluded)
    headers: dict[str, str] = {}
    for path in sorted((root / "Classes").rglob("*.h")):
        relative = str(path.relative_to(root))
        if relative not in excluded_set:
            headers[relative] = path.read_text(errors="replace")
    return headers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("merge_base")
    parser.add_argument(
        "--baseline",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("header-interop-baseline.json"),
    )
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    baseline, excluded = load_baseline(args.baseline)
    headers = first_party_headers(root, excluded)
    changed = changed_paths(root, args.merge_base)
    changed_headers = {path for path in changed if path in headers}
    added_lines = {
        path: added_source_lines(root, args.merge_base, path)
        for path in changed_headers
    }

    failures = evaluate_headers(
        headers=headers,
        baseline=baseline,
        changed_headers=changed_headers,
        added_lines=added_lines,
    )
    if failures:
        print("Objective-C header interoperability check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    annotated = len(headers) - len(baseline)
    print(f"Header interoperability baseline: {annotated}/{len(headers)} annotated; {len(baseline)} debt entries remain.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
