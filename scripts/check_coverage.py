#!/usr/bin/env python3
"""Enforce ratcheting line-coverage floors from an Xcode result bundle."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys


TARGET_MINIMUM = 0.165
FILE_MINIMUMS = {
    "Classes/Util/PBTask.m": 0.88,
    "Classes/Views/PBNativeContentView.m": 0.25,
    "Classes/git/PBGitBinary.m": 0.60,
    "Classes/git/PBGitGrapher.mm": 0.87,
    "Classes/git/PBGitIndex.m": 0.61,
    "Classes/git/PBGitRef.m": 0.82,
    "Classes/git/PBGitRepository.m": 0.29,
    "Classes/git/PBGitRevSpecifier.m": 0.83,
    "Classes/git/PBWorkingTree.m": 0.56,
}


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <result.xcresult>", file=sys.stderr)
        return 2

    result = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", sys.argv[1]],
        check=True,
        capture_output=True,
        text=True,
    )
    report = json.loads(result.stdout)
    target = next((item for item in report["targets"] if item["name"] == "GitX.app"), None)
    if target is None:
        print("GitX.app coverage was not found.", file=sys.stderr)
        return 1

    failures: list[str] = []
    target_coverage = float(target["lineCoverage"])
    print(f"GitX.app: {target_coverage:.2%} (minimum {TARGET_MINIMUM:.2%})")
    if target_coverage < TARGET_MINIMUM:
        failures.append(f"GitX.app coverage regressed to {target_coverage:.2%}")

    files = {str(pathlib.Path(item["path"])): float(item["lineCoverage"]) for item in target["files"]}
    root = pathlib.Path.cwd()
    for relative_path, minimum in FILE_MINIMUMS.items():
        actual = files.get(str(root / relative_path))
        if actual is None:
            failures.append(f"Missing coverage for {relative_path}")
            continue
        print(f"{relative_path}: {actual:.2%} (minimum {minimum:.2%})")
        if actual < minimum:
            failures.append(f"{relative_path} regressed to {actual:.2%}")

    if failures:
        print("Coverage gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
