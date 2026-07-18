#!/usr/bin/env python3
"""Enforce and ratchet checked-in line-coverage floors from an Xcode result bundle."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import subprocess
import sys
from typing import NamedTuple


class CoverageGroup(NamedTuple):
    minimum_line_coverage: float
    files: tuple[str, ...]


class CoveragePolicy(NamedTuple):
    target: str
    minimum_line_coverage: float
    files: dict[str, float]
    groups: dict[str, CoverageGroup] = {}


def load_policy(path: pathlib.Path) -> CoveragePolicy:
    payload = json.loads(path.read_text())
    if payload.get("version") != 1:
        raise ValueError(f"Unsupported coverage policy version in {path}")
    groups = {
        name: CoverageGroup(
            minimum_line_coverage=float(value["minimumLineCoverage"]),
            files=tuple(value["files"]),
        )
        for name, value in payload.get("groups", {}).items()
    }
    return CoveragePolicy(
        target=payload["target"],
        minimum_line_coverage=float(payload["minimumLineCoverage"]),
        files={name: float(value) for name, value in payload.get("files", {}).items()},
        groups=groups,
    )


def policy_payload(policy: CoveragePolicy) -> dict[str, object]:
    payload: dict[str, object] = {
        "version": 1,
        "target": policy.target,
        "minimumLineCoverage": policy.minimum_line_coverage,
        "files": dict(sorted(policy.files.items())),
    }
    if policy.groups:
        payload["groups"] = {
            name: {
                "minimumLineCoverage": group.minimum_line_coverage,
                "files": list(group.files),
            }
            for name, group in sorted(policy.groups.items())
        }
    return payload


def coverage_floor(value: float) -> float:
    return math.floor(value * 10_000 + 1e-9) / 10_000


def evaluate_coverage(
    policy: CoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
    file_line_counts: dict[str, tuple[int, int]] | None = None,
) -> list[str]:
    failures: list[str] = []
    if target_coverage < policy.minimum_line_coverage:
        failures.append(
            f"{policy.target} coverage regressed to {target_coverage:.2%}; "
            f"minimum is {policy.minimum_line_coverage:.2%}"
        )
    for relative_path, minimum in sorted(policy.files.items()):
        actual = file_coverage.get(relative_path)
        if actual is None:
            failures.append(f"Missing coverage for {relative_path}")
        elif actual < minimum:
            failures.append(
                f"{relative_path} coverage regressed to {actual:.2%}; minimum is {minimum:.2%}"
            )
    counts = file_line_counts or {}
    for name, group in sorted(policy.groups.items()):
        actual = group_coverage(group, counts)
        if actual is None:
            failures.append(f"Missing coverage for group {name}")
        elif actual < group.minimum_line_coverage:
            failures.append(
                f"{name} coverage regressed to {actual:.2%}; "
                f"minimum is {group.minimum_line_coverage:.2%}"
            )
    grouped_files = {
        path
        for group in policy.groups.values()
        for path in group.files
    }
    for relative_path in sorted(file_coverage.keys() - policy.files.keys()):
        if is_first_party_source(relative_path) and relative_path not in grouped_files:
            failures.append(f"Coverage policy is missing {relative_path}")
    return failures


def group_coverage(
    group: CoverageGroup,
    file_line_counts: dict[str, tuple[int, int]],
) -> float | None:
    covered_lines = 0
    executable_lines = 0
    for path in group.files:
        counts = file_line_counts.get(path)
        if counts is None:
            return None
        covered_lines += counts[0]
        executable_lines += counts[1]
    return covered_lines / executable_lines if executable_lines else None


def is_first_party_source(relative_path: str) -> bool:
    path = pathlib.PurePosixPath(relative_path)
    return (
        bool(path.parts)
        and path.parts[0] == "Classes"
        and path.suffix in {".c", ".cc", ".cpp", ".m", ".mm", ".swift"}
    )


def ratchet_policy(
    policy: CoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
    file_line_counts: dict[str, tuple[int, int]] | None = None,
) -> CoveragePolicy:
    files = {
        path: max(minimum, coverage_floor(file_coverage.get(path, minimum)))
        for path, minimum in policy.files.items()
    }
    for path, actual in file_coverage.items():
        if path not in files and is_first_party_source(path):
            files[path] = coverage_floor(actual)
    counts = file_line_counts or {}
    groups = {
        name: CoverageGroup(
            minimum_line_coverage=max(
                group.minimum_line_coverage,
                coverage_floor(group_coverage(group, counts) or 0),
            ),
            files=group.files,
        )
        for name, group in policy.groups.items()
    }
    return CoveragePolicy(
        target=policy.target,
        minimum_line_coverage=max(
            policy.minimum_line_coverage,
            coverage_floor(target_coverage),
        ),
        files=files,
        groups=groups,
    )


def xccov_report(result_bundle: pathlib.Path) -> dict[str, object]:
    result = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", str(result_bundle)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def relative_source_path(raw_path: str, root: pathlib.Path) -> str | None:
    path = pathlib.Path(raw_path)
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        normalized = raw_path.replace("\\", "/")
        marker = "/Classes/"
        if marker in normalized:
            return f"Classes/{normalized.rsplit(marker, 1)[1]}"
        return None


def extract_coverage(
    report: dict[str, object],
    policy: CoveragePolicy,
    root: pathlib.Path,
) -> tuple[float, dict[str, float], dict[str, tuple[int, int]]]:
    targets = report.get("targets", [])
    target = next((item for item in targets if item.get("name") == policy.target), None)
    if target is None:
        raise ValueError(f"{policy.target} coverage was not found")

    files: dict[str, float] = {}
    line_counts: dict[str, tuple[int, int]] = {}
    for item in target.get("files", []):
        relative = relative_source_path(item["path"], root)
        if relative is not None:
            files[relative] = float(item["lineCoverage"])
            line_counts[relative] = (
                int(item["coveredLines"]),
                int(item["executableLines"]),
            )
    return float(target["lineCoverage"]), files, line_counts


def render_markdown(
    policy: CoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
    file_line_counts: dict[str, tuple[int, int]] | None = None,
) -> str:
    rows = [
        "## GitX coverage",
        "",
        "| Scope | Actual | Floor |",
        "| --- | ---: | ---: |",
        f"| `{policy.target}` | {target_coverage:.2%} | {policy.minimum_line_coverage:.2%} |",
    ]
    for path, minimum in sorted(policy.files.items()):
        actual = file_coverage.get(path)
        actual_text = "missing" if actual is None else f"{actual:.2%}"
        rows.append(f"| `{path}` | {actual_text} | {minimum:.2%} |")
    counts = file_line_counts or {}
    for name, group in sorted(policy.groups.items()):
        actual = group_coverage(group, counts)
        actual_text = "missing" if actual is None else f"{actual:.2%}"
        rows.append(f"| `{name}` | {actual_text} | {group.minimum_line_coverage:.2%} |")
    return "\n".join(rows) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=pathlib.Path)
    parser.add_argument(
        "--policy",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("coverage-baseline.json"),
    )
    parser.add_argument(
        "--record-improvements",
        action="store_true",
        help="Raise checked-in floors to the current measurements without ever lowering them.",
    )
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    policy = load_policy(args.policy)
    try:
        target_coverage, file_coverage, file_line_counts = extract_coverage(
            xccov_report(args.result_bundle),
            policy,
            root,
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    print(f"{policy.target}: {target_coverage:.2%} (minimum {policy.minimum_line_coverage:.2%})")
    for relative_path, minimum in sorted(policy.files.items()):
        actual = file_coverage.get(relative_path)
        if actual is None:
            print(f"{relative_path}: missing (minimum {minimum:.2%})")
        else:
            print(f"{relative_path}: {actual:.2%} (minimum {minimum:.2%})")
    for name, group in sorted(policy.groups.items()):
        actual = group_coverage(group, file_line_counts)
        actual_text = "missing" if actual is None else f"{actual:.2%}"
        print(f"{name}: {actual_text} (minimum {group.minimum_line_coverage:.2%})")

    if args.record_improvements:
        policy = ratchet_policy(
            policy,
            target_coverage=target_coverage,
            file_coverage=file_coverage,
            file_line_counts=file_line_counts,
        )
        args.policy.write_text(json.dumps(policy_payload(policy), indent=2) + "\n")
        print(f"Raised coverage floors in {args.policy}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with pathlib.Path(summary_path).open("a") as summary:
            summary.write(
                render_markdown(
                    policy,
                    target_coverage=target_coverage,
                    file_coverage=file_coverage,
                    file_line_counts=file_line_counts,
                )
            )

    failures = evaluate_coverage(
        policy,
        target_coverage=target_coverage,
        file_coverage=file_coverage,
        file_line_counts=file_line_counts,
    )
    if failures:
        print("Coverage gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
