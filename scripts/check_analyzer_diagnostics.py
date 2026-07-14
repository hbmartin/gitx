#!/usr/bin/env python3
"""Reject analyzer findings and enforce an exact, shrinking compiler-warning baseline."""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import sys
from typing import NamedTuple


DIAGNOSTIC = re.compile(
    r"^(?P<path>.+?):(?P<line>\d+):(?P<column>\d+): "
    r"(?P<severity>warning|error): (?P<message>.+)$"
)
COMPILER_WARNING = re.compile(r"\s*\[(?P<category>-W[^]]+)\]$")


class WarningFingerprint(NamedTuple):
    path: str
    category: str
    message: str


class Diagnostic(NamedTuple):
    path: str
    line: int
    column: int
    severity: str
    message: str
    category: str | None

    @property
    def fingerprint(self) -> WarningFingerprint | None:
        if self.category is None:
            return None
        return WarningFingerprint(self.path, self.category, self.message)


def normalize_first_party_path(path: str) -> str | None:
    normalized = path.replace("\\", "/")
    for prefix in ("Classes", "GitXTests", "GitXUITests"):
        if normalized.startswith(f"{prefix}/"):
            return normalized
        marker = f"/{prefix}/"
        if marker in normalized:
            return f"{prefix}/{normalized.split(marker, 1)[1]}"
    return None


def parse_diagnostics(contents: str) -> list[Diagnostic]:
    diagnostics: set[Diagnostic] = set()
    for line in contents.splitlines():
        match = DIAGNOSTIC.match(line)
        if not match:
            continue
        path = normalize_first_party_path(match.group("path"))
        if path is None:
            continue
        raw_message = match.group("message")
        category_match = COMPILER_WARNING.search(raw_message)
        category = category_match.group("category") if category_match else None
        message = COMPILER_WARNING.sub("", raw_message).strip()
        diagnostics.add(
            Diagnostic(
                path=path,
                line=int(match.group("line")),
                column=int(match.group("column")),
                severity=match.group("severity"),
                message=message,
                category=category,
            )
        )
    return sorted(diagnostics)


def warning_counts(diagnostics: list[Diagnostic]) -> collections.Counter[WarningFingerprint]:
    counts: collections.Counter[WarningFingerprint] = collections.Counter()
    for diagnostic in diagnostics:
        if diagnostic.severity == "warning" and diagnostic.fingerprint is not None:
            counts[diagnostic.fingerprint] += 1
    return counts


def analyzer_findings(diagnostics: list[Diagnostic]) -> list[Diagnostic]:
    return [
        diagnostic
        for diagnostic in diagnostics
        if diagnostic.severity == "error" or diagnostic.category is None
    ]


def load_warning_baseline(path: pathlib.Path) -> collections.Counter[WarningFingerprint]:
    payload = json.loads(path.read_text())
    if payload.get("version") != 2:
        raise ValueError(f"Unsupported warning baseline version in {path}; expected version 2")
    counts: collections.Counter[WarningFingerprint] = collections.Counter()
    for warning in payload.get("warnings", []):
        fingerprint = WarningFingerprint(
            path=warning["path"],
            category=warning["category"],
            message=warning["message"],
        )
        counts[fingerprint] += int(warning.get("count", 1))
    return counts


def baseline_payload(counts: collections.Counter[WarningFingerprint]) -> dict[str, object]:
    warnings: list[dict[str, object]] = []
    for fingerprint, count in sorted(counts.items()):
        warnings.append(
            {
                "path": fingerprint.path,
                "category": fingerprint.category,
                "message": fingerprint.message,
                "count": count,
            }
        )
    return {"version": 2, "warnings": warnings}


def compare_warning_baseline(
    *,
    current: collections.Counter[WarningFingerprint] | dict[WarningFingerprint, int],
    baseline: collections.Counter[WarningFingerprint] | dict[WarningFingerprint, int],
) -> list[str]:
    failures: list[str] = []
    all_fingerprints = sorted(set(current) | set(baseline))
    for fingerprint in all_fingerprints:
        current_count = current.get(fingerprint, 0)
        baseline_count = baseline.get(fingerprint, 0)
        label = f"{fingerprint.path}: {fingerprint.message} [{fingerprint.category}]"
        if current_count > baseline_count:
            failures.append(
                f"New warning: {label} occurs {current_count} time(s), baseline allows {baseline_count}"
            )
        elif current_count < baseline_count:
            failures.append(
                f"Stale warning baseline: {label} occurs {current_count} time(s), baseline records {baseline_count}; ratchet it down"
            )
    return failures


def format_diagnostic(diagnostic: Diagnostic) -> str:
    suffix = f" [{diagnostic.category}]" if diagnostic.category else ""
    return (
        f"{diagnostic.path}:{diagnostic.line}:{diagnostic.column}: "
        f"{diagnostic.severity}: {diagnostic.message}{suffix}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=pathlib.Path)
    parser.add_argument(
        "--baseline",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("xcode-warning-budget.json"),
    )
    parser.add_argument(
        "--print-baseline",
        action="store_true",
        help="Print an exact version-2 baseline for the current compiler warnings.",
    )
    args = parser.parse_args()

    diagnostics = parse_diagnostics(args.log.read_text(errors="replace"))
    findings = analyzer_findings(diagnostics)
    current_warnings = warning_counts(diagnostics)

    if args.print_baseline:
        print(json.dumps(baseline_payload(current_warnings), indent=2))
        return 1 if findings else 0

    baseline = load_warning_baseline(args.baseline)
    baseline_failures = compare_warning_baseline(current=current_warnings, baseline=baseline)

    category_counts: collections.Counter[str] = collections.Counter()
    for fingerprint, count in current_warnings.items():
        category_counts[fingerprint.category] += count
    for category, count in sorted(category_counts.items()):
        print(f"{category}: {count} exact-baseline warning(s)")

    if findings:
        print(f"Found {len(findings)} first-party analyzer finding(s) or error(s):", file=sys.stderr)
        for finding in findings:
            print(format_diagnostic(finding), file=sys.stderr)
    if baseline_failures:
        print("Compiler warning baseline mismatch:", file=sys.stderr)
        for failure in baseline_failures:
            print(f"- {failure}", file=sys.stderr)

    if findings or baseline_failures:
        return 1

    print(f"Analyzer passed; {sum(current_warnings.values())} exact-baseline compiler warning(s) remain.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
