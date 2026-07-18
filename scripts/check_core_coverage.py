#!/usr/bin/env python3
"""Enforce and ratchet GitXCore source coverage from SwiftPM's codecov JSON."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from typing import NamedTuple


class CoreCoveragePolicy(NamedTuple):
    target: str
    minimum_line_coverage: float
    files: dict[str, float]


def load_policy(path: pathlib.Path) -> CoreCoveragePolicy:
    payload = json.loads(path.read_text())
    if payload.get("version") != 1:
        raise ValueError(f"Unsupported coverage policy version in {path}")
    return CoreCoveragePolicy(
        target=payload["target"],
        minimum_line_coverage=float(payload["minimumLineCoverage"]),
        files={name: float(value) for name, value in payload.get("files", {}).items()},
    )


def coverage_floor(value: float) -> float:
    return math.floor(value * 10_000 + 1e-9) / 10_000


def extract_coverage(
    report: dict[str, object],
    source_root: pathlib.Path,
) -> tuple[float, dict[str, float]]:
    payloads = report.get("data", [])
    if not payloads:
        raise ValueError("SwiftPM coverage data was not found")
    root = source_root.resolve()
    files: dict[str, float] = {}
    covered_lines = 0
    executable_lines = 0
    for item in payloads[0].get("files", []):
        path = pathlib.Path(item["filename"]).resolve()
        try:
            relative = str(path.relative_to(root))
        except ValueError:
            continue
        lines = item["summary"]["lines"]
        covered_lines += int(lines["covered"])
        executable_lines += int(lines["count"])
        files[relative] = float(lines["percent"]) / 100
    if not files or executable_lines == 0:
        raise ValueError(f"No covered Swift sources were found under {source_root}")
    return covered_lines / executable_lines, files


def evaluate_coverage(
    policy: CoreCoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
) -> list[str]:
    failures: list[str] = []
    if target_coverage < policy.minimum_line_coverage:
        failures.append(
            f"{policy.target} coverage regressed to {target_coverage:.2%}; "
            f"minimum is {policy.minimum_line_coverage:.2%}"
        )
    for path, minimum in sorted(policy.files.items()):
        actual = file_coverage.get(path)
        if actual is None:
            failures.append(f"Missing coverage for {path}")
        elif actual < minimum:
            failures.append(f"{path} coverage regressed to {actual:.2%}; minimum is {minimum:.2%}")
    for path in sorted(file_coverage.keys() - policy.files.keys()):
        failures.append(f"Coverage policy is missing {path}")
    return failures


def ratchet_policy(
    policy: CoreCoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
) -> CoreCoveragePolicy:
    files = {
        path: max(policy.files.get(path, 0), coverage_floor(actual))
        for path, actual in file_coverage.items()
    }
    return CoreCoveragePolicy(
        target=policy.target,
        minimum_line_coverage=max(policy.minimum_line_coverage, coverage_floor(target_coverage)),
        files=files,
    )


def policy_payload(policy: CoreCoveragePolicy) -> dict[str, object]:
    return {
        "version": 1,
        "target": policy.target,
        "minimumLineCoverage": policy.minimum_line_coverage,
        "files": dict(sorted(policy.files.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("codecov_json", type=pathlib.Path)
    parser.add_argument(
        "--policy",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "GitXCore" / "coverage-baseline.json",
    )
    parser.add_argument("--record-improvements", action="store_true")
    args = parser.parse_args()
    source_root = pathlib.Path(__file__).resolve().parent.parent / "GitXCore" / "Sources" / "GitXCore"

    try:
        policy = load_policy(args.policy)
        target_coverage, file_coverage = extract_coverage(
            json.loads(args.codecov_json.read_text()),
            source_root,
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    if args.record_improvements:
        policy = ratchet_policy(
            policy,
            target_coverage=target_coverage,
            file_coverage=file_coverage,
        )
        args.policy.write_text(json.dumps(policy_payload(policy), indent=2) + "\n")
        print(f"Raised coverage floors in {args.policy}")

    print(f"{policy.target}: {target_coverage:.2%} (minimum {policy.minimum_line_coverage:.2%})")
    failures = evaluate_coverage(
        policy,
        target_coverage=target_coverage,
        file_coverage=file_coverage,
    )
    if failures:
        print("Core coverage gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
