#!/usr/bin/env python3
"""Enforce and ratchet coverage for handwritten ForgeKit package sources."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import subprocess
import sys
from typing import NamedTuple


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    pathlib.PurePosixPath("ForgeKit/Sources/ForgeKit"),
    pathlib.PurePosixPath("ForgeKit/Sources/GitHubForgeAdapter"),
)
GENERATED_ROOT = pathlib.PurePosixPath(
    "ForgeKit/Sources/GitHubForgeAdapter/Generated"
)
REQUIRED_MINIMUM = 0.95
TEST_PRODUCTS = ("ForgeKitTests", "GitHubForgeAdapterTests")
GIT_OBJECT_ID = re.compile(r"[0-9a-f]{40,64}")


class ForgeCoveragePolicy(NamedTuple):
    target: str
    minimum_line_coverage: float
    files: dict[str, float]


def unique_artifact(paths: list[pathlib.Path], description: str) -> pathlib.Path:
    if len(paths) != 1:
        rendered = ", ".join(str(path) for path in paths) or "none"
        raise ValueError(
            f"Expected exactly one {description}; found {len(paths)}: {rendered}"
        )
    return paths[0]


def swiftpm_coverage_artifacts(
    scratch_path: pathlib.Path,
) -> tuple[pathlib.Path, list[pathlib.Path]]:
    if not scratch_path.is_dir():
        raise ValueError(f"SwiftPM scratch path does not exist: {scratch_path}")

    profile = unique_artifact(
        [
            path
            for path in scratch_path.rglob("default.profdata")
            if path.is_file() and path.parent.name == "codecov"
        ],
        "SwiftPM code-coverage profile",
    )
    products: list[pathlib.Path] = []
    for name in TEST_PRODUCTS:
        product = unique_artifact(
            [
                path
                for path in scratch_path.rglob(name)
                if path.is_file()
                and path.parent.name == "MacOS"
                and len(path.parents) >= 3
                and path.parents[2].name == f"{name}.xctest"
            ],
            f"{name}.xctest executable",
        )
        products.append(product)
    return profile, products


def export_swiftpm_coverage(
    scratch_path: pathlib.Path,
) -> tuple[dict[str, object], str]:
    profile, products = swiftpm_coverage_artifacts(scratch_path)
    command = [
        "xcrun",
        "llvm-cov",
        "export",
        str(products[0]),
        "-object",
        str(products[1]),
        f"-instr-profile={profile}",
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise ValueError(f"Could not run combined ForgeKit llvm-cov export: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise ValueError(
            f"Combined ForgeKit llvm-cov export exited with status "
            f"{result.returncode}{suffix}"
        )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("Combined ForgeKit llvm-cov export returned invalid JSON") from error
    return report, result.stdout


def coverage_floor(value: float) -> float:
    return math.floor(value * 10_000 + 1e-9) / 10_000


def is_relative_to(path: pathlib.PurePosixPath, parent: pathlib.PurePosixPath) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def is_handwritten_source(relative_path: str) -> bool:
    path = pathlib.PurePosixPath(relative_path)
    return (
        path.suffix == ".swift"
        and any(is_relative_to(path, source_root) for source_root in SOURCE_ROOTS)
        and not is_relative_to(path, GENERATED_ROOT)
    )


def coverage_value(value: object, description: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{description} must be a finite number between 0 and 1")
    result = float(value)
    if not math.isfinite(result) or not 0 <= result <= 1:
        raise ValueError(f"{description} must be a finite number between 0 and 1")
    return result


def policy_from_payload(payload: object, source: str) -> ForgeCoveragePolicy:
    if not isinstance(payload, dict):
        raise ValueError(f"ForgeKit coverage policy in {source} must be a JSON object")
    if payload.get("version") != 1:
        raise ValueError(f"Unsupported ForgeKit coverage policy version in {source}")
    target = payload.get("target")
    if not isinstance(target, str) or not target:
        raise ValueError(f"ForgeKit coverage policy in {source} has an invalid target")
    minimum = coverage_value(
        payload.get("minimumLineCoverage"),
        f"{source} aggregate floor",
    )
    if minimum < REQUIRED_MINIMUM:
        raise ValueError(
            f"{source} lowers the ForgeKit aggregate floor below {REQUIRED_MINIMUM:.0%}"
        )
    raw_files = payload.get("files", {})
    if not isinstance(raw_files, dict) or not all(
        isinstance(name, str) for name in raw_files
    ):
        raise ValueError(f"ForgeKit coverage files in {source} must be a JSON object")
    files = {
        name: coverage_value(value, f"{source} floor for {name}")
        for name, value in raw_files.items()
    }
    invalid_paths = sorted(path for path in files if not is_handwritten_source(path))
    if invalid_paths:
        raise ValueError(
            f"{source} tracks non-handwritten ForgeKit sources: {', '.join(invalid_paths)}"
        )
    low_floors = sorted(name for name, value in files.items() if value < REQUIRED_MINIMUM)
    if low_floors:
        raise ValueError(
            f"{source} lowers per-file floors below {REQUIRED_MINIMUM:.0%}: "
            + ", ".join(low_floors)
        )
    return ForgeCoveragePolicy(
        target=target,
        minimum_line_coverage=minimum,
        files=files,
    )


def load_policy(path: pathlib.Path) -> ForgeCoveragePolicy:
    return policy_from_payload(json.loads(path.read_text()), str(path))


def run_git(repository_root: pathlib.Path, arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise ValueError(f"Could not inspect ForgeKit coverage history: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise ValueError(
            "Could not inspect ForgeKit coverage history with "
            f"git {' '.join(arguments)}{suffix}"
        )
    return result.stdout


def checked_in_ancestor_policies(
    repository_root: pathlib.Path,
    policy_path: pathlib.Path,
    *,
    revision: str = "HEAD",
) -> list[ForgeCoveragePolicy]:
    root = repository_root.resolve()
    try:
        relative = policy_path.resolve().relative_to(root).as_posix()
    except ValueError:
        return []

    if run_git(root, ["rev-parse", "--is-inside-work-tree"]).strip() != "true":
        raise ValueError(f"Cannot inspect ancestor floors outside a Git worktree: {root}")
    if run_git(root, ["rev-parse", "--is-shallow-repository"]).strip() != "false":
        raise ValueError(
            "Cannot prove ForgeKit coverage floors are nondecreasing from a shallow Git checkout"
        )
    revision_id = run_git(root, ["rev-parse", "--verify", f"{revision}^{{commit}}"]).strip()
    if GIT_OBJECT_ID.fullmatch(revision_id) is None:
        raise ValueError(f"Git returned an invalid coverage-history revision: {revision_id!r}")

    raw_revisions = run_git(
        root,
        ["log", "--format=%H", revision_id, "--", relative],
    ).splitlines()
    revisions: list[str] = []
    for object_id in raw_revisions:
        if GIT_OBJECT_ID.fullmatch(object_id) is None:
            raise ValueError(f"Git returned an invalid coverage-history object: {object_id!r}")
        if object_id not in revisions:
            revisions.append(object_id)

    policies: list[ForgeCoveragePolicy] = []
    for object_id in revisions:
        tree_paths = run_git(
            root,
            ["ls-tree", "--name-only", "--full-tree", object_id, "--", relative],
        ).splitlines()
        if relative not in tree_paths:
            continue
        contents = run_git(root, ["show", f"{object_id}:{relative}"])
        try:
            payload = json.loads(contents)
        except json.JSONDecodeError as error:
            raise ValueError(
                f"Malformed ancestor ForgeKit coverage policy at {object_id}:{relative}"
            ) from error
        policies.append(
            policy_from_payload(payload, f"{object_id}:{relative}")
        )
    return policies


def maximum_ancestor_policy(
    policies: list[ForgeCoveragePolicy],
    *,
    target: str,
) -> ForgeCoveragePolicy | None:
    if not policies:
        return None
    files: dict[str, float] = {}
    for policy in policies:
        for path, floor in policy.files.items():
            files[path] = max(files.get(path, REQUIRED_MINIMUM), floor)
    return ForgeCoveragePolicy(
        target=target,
        minimum_line_coverage=max(policy.minimum_line_coverage for policy in policies),
        files=files,
    )


def ancestor_floor_failures(
    policy: ForgeCoveragePolicy,
    ancestor_policies: list[ForgeCoveragePolicy],
    *,
    applicable_files: set[str],
) -> list[str]:
    maximum = maximum_ancestor_policy(ancestor_policies, target=policy.target)
    if maximum is None:
        return []
    failures: list[str] = []
    if policy.minimum_line_coverage < maximum.minimum_line_coverage:
        failures.append(
            f"{policy.target} aggregate floor was lowered from "
            f"{maximum.minimum_line_coverage:.2%} to {policy.minimum_line_coverage:.2%}"
        )
    for path in sorted(applicable_files):
        previous = maximum.files.get(path)
        if previous is None:
            continue
        current = policy.files.get(path)
        if current is None:
            failures.append(
                f"Coverage policy removed the ancestor floor {previous:.2%} for {path}"
            )
        elif current < previous:
            failures.append(
                f"{path} floor was lowered from {previous:.2%} to {current:.2%}"
            )
    return failures


def expected_sources(repository_root: pathlib.Path) -> set[str]:
    expected: set[str] = set()
    for source_root in SOURCE_ROOTS:
        directory = repository_root / pathlib.Path(source_root)
        if not directory.is_dir():
            continue
        for path in directory.rglob("*.swift"):
            relative = path.relative_to(repository_root).as_posix()
            if is_handwritten_source(relative):
                expected.add(relative)
    return expected


def extract_coverage(
    report: dict[str, object],
    repository_root: pathlib.Path,
) -> tuple[float, dict[str, float]]:
    payloads = report.get("data", [])
    if not payloads:
        raise ValueError("SwiftPM coverage data was not found")

    root = repository_root.resolve()
    covered_lines = 0
    executable_lines = 0
    files: dict[str, float] = {}
    for item in payloads[0].get("files", []):
        raw_path = pathlib.Path(item["filename"])
        try:
            relative = raw_path.resolve().relative_to(root).as_posix()
        except ValueError:
            continue
        if not is_handwritten_source(relative):
            continue
        lines = item["summary"]["lines"]
        covered = int(lines["covered"])
        executable = int(lines["count"])
        if executable == 0:
            raise ValueError(f"No executable coverage lines were found for {relative}")
        covered_lines += covered
        executable_lines += executable
        files[relative] = covered / executable

    expected = expected_sources(repository_root)
    if not expected:
        raise ValueError(f"No handwritten ForgeKit sources were found under {repository_root}")
    missing = sorted(expected - files.keys())
    if missing:
        raise ValueError("Coverage data is missing handwritten sources: " + ", ".join(missing))
    if executable_lines == 0:
        raise ValueError("ForgeKit coverage data contained no executable handwritten lines")
    return covered_lines / executable_lines, files


def evaluate_coverage(
    policy: ForgeCoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
) -> list[str]:
    failures: list[str] = []
    aggregate_floor = max(REQUIRED_MINIMUM, policy.minimum_line_coverage)
    if target_coverage < aggregate_floor:
        failures.append(
            f"{policy.target} coverage regressed to {target_coverage:.2%}; "
            f"minimum is {aggregate_floor:.2%}"
        )
    for path, actual in sorted(file_coverage.items()):
        minimum = max(REQUIRED_MINIMUM, policy.files.get(path, REQUIRED_MINIMUM))
        if actual < minimum:
            failures.append(
                f"{path} coverage regressed to {actual:.2%}; minimum is {minimum:.2%}"
            )
        if path not in policy.files:
            failures.append(f"Coverage policy is missing {path}")
    for path in sorted(policy.files.keys() - file_coverage.keys()):
        failures.append(f"Missing coverage for {path}")
    return failures


def record_blockers(
    policy: ForgeCoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
) -> list[str]:
    failures: list[str] = []
    aggregate_floor = max(REQUIRED_MINIMUM, policy.minimum_line_coverage)
    if target_coverage < aggregate_floor:
        failures.append(
            f"{policy.target} coverage is {target_coverage:.2%}; "
            f"cannot record below {aggregate_floor:.2%}"
        )
    for path, actual in sorted(file_coverage.items()):
        minimum = max(REQUIRED_MINIMUM, policy.files.get(path, REQUIRED_MINIMUM))
        if actual < minimum:
            failures.append(
                f"{path} coverage is {actual:.2%}; cannot record below {minimum:.2%}"
            )
    for path in sorted(policy.files.keys() - file_coverage.keys()):
        failures.append(f"Cannot remove missing tracked coverage file {path}")
    return failures


def ratchet_policy(
    policy: ForgeCoveragePolicy,
    *,
    target_coverage: float,
    file_coverage: dict[str, float],
) -> ForgeCoveragePolicy:
    return ForgeCoveragePolicy(
        target=policy.target,
        minimum_line_coverage=max(
            REQUIRED_MINIMUM,
            policy.minimum_line_coverage,
            coverage_floor(target_coverage),
        ),
        files={
            path: max(
                REQUIRED_MINIMUM,
                policy.files.get(path, REQUIRED_MINIMUM),
                coverage_floor(actual),
            )
            for path, actual in sorted(file_coverage.items())
        },
    )


def policy_payload(policy: ForgeCoveragePolicy) -> dict[str, object]:
    return {
        "version": 1,
        "target": policy.target,
        "minimumLineCoverage": policy.minimum_line_coverage,
        "files": dict(sorted(policy.files.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("codecov_json", nargs="?", type=pathlib.Path)
    parser.add_argument(
        "--swiftpm-scratch-path",
        type=pathlib.Path,
        help=(
            "export coverage from both ForgeKitTests and "
            "GitHubForgeAdapterTests in this SwiftPM scratch directory"
        ),
    )
    parser.add_argument(
        "--combined-output",
        type=pathlib.Path,
        help="write the combined llvm-cov JSON for CI diagnostics",
    )
    parser.add_argument(
        "--policy",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("forgekit-coverage-baseline.json"),
    )
    parser.add_argument("--record-improvements", action="store_true")
    args = parser.parse_args()

    if (args.codecov_json is None) == (args.swiftpm_scratch_path is None):
        parser.error(
            "provide either codecov_json or --swiftpm-scratch-path, but not both"
        )
    if args.combined_output is not None and args.swiftpm_scratch_path is None:
        parser.error("--combined-output requires --swiftpm-scratch-path")

    try:
        policy = load_policy(args.policy)
        ancestor_policies = checked_in_ancestor_policies(ROOT, args.policy)
        lowering_failures = ancestor_floor_failures(
            policy,
            ancestor_policies,
            applicable_files=expected_sources(ROOT),
        )
        if lowering_failures:
            print("ForgeKit coverage floors were lowered:", file=sys.stderr)
            for failure in lowering_failures:
                print(f"- {failure}", file=sys.stderr)
            return 1
        if args.swiftpm_scratch_path is not None:
            report, raw_report = export_swiftpm_coverage(args.swiftpm_scratch_path)
            if args.combined_output is not None:
                args.combined_output.parent.mkdir(parents=True, exist_ok=True)
                args.combined_output.write_text(raw_report)
        else:
            report = json.loads(args.codecov_json.read_text())
        target_coverage, file_coverage = extract_coverage(
            report,
            ROOT,
        )
    except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1

    if args.record_improvements:
        blockers = record_blockers(
            policy,
            target_coverage=target_coverage,
            file_coverage=file_coverage,
        )
        if blockers:
            print("ForgeKit coverage floors were not recorded:", file=sys.stderr)
            for failure in blockers:
                print(f"- {failure}", file=sys.stderr)
            return 1
        policy = ratchet_policy(
            policy,
            target_coverage=target_coverage,
            file_coverage=file_coverage,
        )
        args.policy.write_text(json.dumps(policy_payload(policy), indent=2) + "\n")
        print(f"Raised ForgeKit coverage floors in {args.policy}")

    print(
        f"{policy.target}: {target_coverage:.2%} "
        f"(minimum {policy.minimum_line_coverage:.2%})"
    )
    for path, actual in sorted(file_coverage.items()):
        minimum = policy.files.get(path, REQUIRED_MINIMUM)
        print(f"{path}: {actual:.2%} (minimum {minimum:.2%})")

    failures = evaluate_coverage(
        policy,
        target_coverage=target_coverage,
        file_coverage=file_coverage,
    )
    if failures:
        print("ForgeKit coverage gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
