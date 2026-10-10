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
import tempfile
import workflow_session as session
from typing import NamedTuple


class CoverageGroup(NamedTuple):
    minimum_line_coverage: float
    files: tuple[str, ...]


class CoveragePolicy(NamedTuple):
    target: str
    minimum_line_coverage: float
    files: dict[str, float]
    groups: dict[str, CoverageGroup]


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
    grouped_files = {
        path
        for group in policy.groups.values()
        for path in group.files
    }
    files = {
        path: max(minimum, coverage_floor(file_coverage.get(path, minimum)))
        for path, minimum in policy.files.items()
        if path not in grouped_files
    }
    for path, actual in file_coverage.items():
        if path not in files and path not in grouped_files and is_first_party_source(path):
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


def improvements_payload(
    original: CoveragePolicy,
    candidate: CoveragePolicy,
) -> dict[str, object]:
    target = None
    if candidate.minimum_line_coverage > original.minimum_line_coverage:
        target = {
            "previous": original.minimum_line_coverage,
            "candidate": candidate.minimum_line_coverage,
        }
    files = {
        path: {
            "previous": original.files.get(path),
            "candidate": minimum,
        }
        for path, minimum in sorted(candidate.files.items())
        if minimum > original.files.get(path, -1)
    }
    groups = {
        name: {
            "previous": original.groups[name].minimum_line_coverage,
            "candidate": group.minimum_line_coverage,
        }
        for name, group in sorted(candidate.groups.items())
        if group.minimum_line_coverage > original.groups[name].minimum_line_coverage
    }
    return {"target": target, "files": files, "groups": groups}


def write_json_atomic(path: pathlib.Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w") as output:
            json.dump(payload, output, indent=2, sort_keys=True)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=pathlib.Path)
    parser.add_argument(
        "--policy",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("coverage-baseline.json"),
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--record-improvements",
        action="store_true",
        help="Raise checked-in floors to the current measurements without ever lowering them.",
    )
    modes.add_argument(
        "--propose-improvements",
        type=pathlib.Path,
        metavar="OUTPUT",
        help="Write a candidate ratchet report without changing the checked-in policy.",
    )
    parser.add_argument("--receipt", type=pathlib.Path, help="Validated complete correctness receipt required for a ratchet.")
    parser.add_argument("--compare", type=pathlib.Path, help="Previous local correctness receipt with compatible instrumentation.")
    parser.add_argument("--base", help="Commit used to classify changed source paths (default: origin/master merge base).")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_arguments(argv)
    if args.record_improvements:
        owner = {"runId": os.environ.get("GITX_SESSION_ID", "coverage-ratchet"), "pid": os.getpid(), "receipt": str(args.receipt)}
        try:
            with session.Leases([str(args.policy)], owner):
                return check(args)
        except session.ResourceBusy as error:
            print(error, file=sys.stderr)
            return 75
    return check(args)


def ratchet_evidence(args):
    path = args.receipt or args.result_bundle.parent.parent / "receipt.json"
    if not path.is_file():
        raise ValueError("Ratchet requires a receipt from a complete local correctness run; historical coverage is reportable only.")
    receipt = json.loads(path.read_text())
    evidence = receipt.get("evidence", {})
    if evidence.get("status") != "valid" or receipt.get("status") != "passed":
        raise ValueError("Ratchet requires a passed receipt with valid provenance.")
    if receipt.get("invocation", {}).get("coverageGate") != "enforced":
        raise ValueError("Ratchet requires complete correctness execution, without focused selections.")
    tests = [step for step in receipt.get("steps", []) if step.get("name") == "test:correctness"]
    if not tests or any(step.get("status") != "passed" or not step.get("testCounts", {}).get("total") or step["testCounts"].get("failed") for step in tests):
        raise ValueError("Ratchet requires successful complete correctness test counts.")
    if session.changed_inputs(evidence["inputsAfter"], session.inputs()):
        raise ValueError("Ratchet source, dependencies, plans or commit changed since execution.")
    result = str(args.result_bundle.resolve().relative_to(session.ROOT))
    recorded = evidence.get("results", {}).get(result)
    if recorded is None or recorded != session.tree_identity(args.result_bundle):
        raise ValueError("Ratchet result identity is missing or changed.")
    derived = receipt.get("buildPaths", {}).get("derivedData")
    if not derived or evidence.get("products") != session.product_identity(derived):
        raise ValueError("Ratchet test products changed since execution.")
    if evidence.get("dependencyProducts") != session.dependency_products():
        raise ValueError("Ratchet dependency products changed since execution.")
    return receipt


def coverage_diagnostics(policy, coverage, counts, root, result, receipt=None, base=None):
    changed = set(session.git(root, "diff", "--name-only", "HEAD").splitlines())
    base = base or session.git(root, "merge-base", "origin/master", "HEAD")
    if base:
        changed.update(session.git(root, "diff", "--name-only", base).splitlines())
    if receipt:
        before = receipt.get("evidence", {}).get("inputsBefore", {}).get("files", {})
        after = session.inputs(root).get("files", {})
        changed.update(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    for path, minimum in sorted(policy.files.items()):
        actual = coverage.get(path)
        if actual is None:
            category = "stale-policy-path" if not (root / path).exists() else "missing-coverage"
            print(f"[{category}] {path}: check source membership and suite instrumentation.", file=sys.stderr)
        elif actual < minimum:
            covered, executable = counts[path]
            print(f"[uncovered-behavior] {path}: {covered}/{executable} lines; {'changed' if path in changed else 'untouched'} source.", file=sys.stderr)
            query = subprocess.run(["xcrun", "xccov", "view", "--archive", "--file", str(root / path), "--json", str(result)], capture_output=True, text=True)
            if query.returncode == 0:
                try:
                    payload = json.loads(query.stdout)
                    records = payload.get(str(root / path), []) if isinstance(payload, dict) else payload
                    uncovered = [str(item.get("line", item.get("lineNumber"))) for item in records if item.get("isExecutable") and item.get("executionCount", 0) == 0 and ("line" in item or "lineNumber" in item)]
                    print("  Uncovered source lines: " + ", ".join(uncovered), file=sys.stderr)
                except (ValueError, TypeError, AttributeError):
                    print("  Uncovered-line detail unavailable; inspect the retained xcresult.", file=sys.stderr)


def compatible_comparison(current, previous):
    if not isinstance(current, dict) or not isinstance(previous, dict):
        return False
    current_evidence, previous_evidence = current.get("evidence"), previous.get("evidence")
    if not isinstance(current_evidence, dict) or not isinstance(previous_evidence, dict):
        return False
    current_inputs, previous_inputs = current_evidence.get("inputsAfter"), previous_evidence.get("inputsAfter")
    if not isinstance(current_inputs, dict) or not isinstance(previous_inputs, dict):
        return False
    current_plans, previous_plans = current_inputs.get("plans"), previous_inputs.get("plans")
    return bool(current_evidence.get("status") == previous_evidence.get("status") == "valid"
        and current_plans is not None and current_plans == previous_plans
        and current.get("toolchain") == previous.get("toolchain")
        and current.get("invocation") == previous.get("invocation"))


def comparison_receipt(path):
    try:
        payload = json.loads(path.read_text())
        if isinstance(payload, dict):
            return payload
    except (OSError, ValueError):
        pass
    print(f"Coverage comparison receipt unavailable: {path}")
    return None


def check(args) -> int:

    root = pathlib.Path(__file__).resolve().parent.parent
    policy = load_policy(args.policy)
    try:
        report = xccov_report(args.result_bundle)
        target_coverage, file_coverage, file_line_counts = extract_coverage(
            report,
            policy,
            root,
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    target = next(item for item in report.get("targets", []) if item.get("name") == policy.target)
    print(f"Exact target lines: {target.get('coveredLines', sum(v[0] for v in file_line_counts.values()))}/{target.get('executableLines', sum(v[1] for v in file_line_counts.values()))}")

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

    failures = evaluate_coverage(policy, target_coverage=target_coverage, file_coverage=file_coverage, file_line_counts=file_line_counts)
    receipt_path = args.receipt or args.result_bundle.parent.parent / "receipt.json"
    receipt = comparison_receipt(receipt_path) if receipt_path.is_file() else None
    comparison_path = args.compare
    if failures and comparison_path is None and receipt and receipt.get("evidence", {}).get("status") == "valid":
        previous_paths = sorted((root / "artifacts/verification").glob("*/receipt.json"), key=lambda path: path.stat().st_mtime, reverse=True)
        for previous_path in previous_paths:
            if previous_path.resolve() == receipt_path.resolve():
                continue
            previous = comparison_receipt(previous_path)
            if compatible_comparison(receipt, previous):
                comparison_path = previous_path
                break
    if comparison_path:
        previous = comparison_receipt(comparison_path)
        if not receipt or not compatible_comparison(receipt, previous):
            print("[instrumentation-difference] Previous run is incompatible; no coverage comparison.")
        else:
            steps = previous.get("steps")
            for step in steps if isinstance(steps, list) else []:
                measurement = step.get("coverage") if isinstance(step, dict) else None
                previous_coverage = measurement.get("lineCoverage") if isinstance(measurement, dict) else None
                if isinstance(previous_coverage, (int, float)) and step.get("name") == "test:correctness":
                    print(f"Compatible previous target coverage: {previous_coverage:.4%}; delta {target_coverage - previous_coverage:+.4%}")
                    if not isinstance(step.get("xcresult"), str):
                        print("Previous file coverage unavailable; retained target comparison only.")
                        continue
                    previous_result = root / step["xcresult"]
                    if previous_result.exists():
                        try:
                            _, previous_files, previous_counts = extract_coverage(xccov_report(previous_result), policy, root)
                            for path, actual in sorted(file_coverage.items()):
                                if actual < policy.files.get(path, 0) and path in previous_files:
                                    print(f"Previous {path}: {previous_counts[path][0]}/{previous_counts[path][1]} lines ({previous_files[path]:.4%}); current {file_line_counts[path][0]}/{file_line_counts[path][1]} ({actual:.4%})")
                        except (ValueError, subprocess.SubprocessError):
                            print("Previous file coverage unavailable; retained target comparison only.")
    if failures:
        coverage_diagnostics(policy, file_coverage, file_line_counts, root, args.result_bundle, receipt, args.base)
    if args.record_improvements and failures:
        print("Coverage validation failed; baseline unchanged.", file=sys.stderr)
        return 1
    if args.record_improvements or args.propose_improvements:
        candidate = ratchet_policy(
            policy,
            target_coverage=target_coverage,
            file_coverage=file_coverage,
            file_line_counts=file_line_counts,
        )
        if args.record_improvements:
            try:
                ratchet_evidence(args)
            except (ValueError, OSError, KeyError) as error:
                print(f"{error} Baseline unchanged.", file=sys.stderr)
                return 1
            proposed_failures = evaluate_coverage(candidate, target_coverage=target_coverage, file_coverage=file_coverage, file_line_counts=file_line_counts)
            if proposed_failures:
                print("Candidate policy failed validation; baseline unchanged.", file=sys.stderr)
                return 1
            if policy_payload(candidate) == policy_payload(policy):
                print("No coverage floor increases; baseline unchanged.")
            else:
                write_json_atomic(args.policy, policy_payload(candidate))
                policy = candidate
                print(f"Raised coverage floors in {args.policy}")
        else:
            assert args.propose_improvements is not None
            if args.propose_improvements.resolve() == args.policy.resolve():
                print("Proposal output must differ from the checked-in policy path.", file=sys.stderr)
                return 2
            write_json_atomic(
                args.propose_improvements,
                {
                    "schemaVersion": 1,
                    "sourcePolicy": str(args.policy),
                    "candidatePolicy": policy_payload(candidate),
                    "improvements": improvements_payload(policy, candidate),
                },
            )
            print(f"Wrote non-mutating coverage proposal to {args.propose_improvements}")

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
