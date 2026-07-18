#!/usr/bin/env python3
"""Measure local cold and warm Debug builds against checked-in ceilings."""

from __future__ import annotations

import argparse
import json
import pathlib
import platform
import shutil
import statistics
import subprocess
import sys
import time
from typing import NamedTuple


COLD_CEILING_SECONDS = 108.23
WARM_CEILING_SECONDS = 19.55


class BuildSample(NamedTuple):
    run: int
    cold_seconds: float
    warm_seconds: float


def medians(samples: list[BuildSample]) -> tuple[float, float]:
    return (
        statistics.median(sample.cold_seconds for sample in samples),
        statistics.median(sample.warm_seconds for sample in samples),
    )


def threshold_failures(
    cold_median: float,
    warm_median: float,
    *,
    cold_ceiling: float = COLD_CEILING_SECONDS,
    warm_ceiling: float = WARM_CEILING_SECONDS,
) -> list[str]:
    failures: list[str] = []
    if cold_median > cold_ceiling:
        failures.append(
            f"Cold-build median {cold_median:.2f}s exceeds the {cold_ceiling:.2f}s ceiling"
        )
    if warm_median > warm_ceiling:
        failures.append(
            f"Warm-build median {warm_median:.2f}s exceeds the {warm_ceiling:.2f}s ceiling"
        )
    return failures


def captured(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    return result.stdout.strip() or result.stderr.strip() or "unavailable"


def environment_fingerprint() -> dict[str, str]:
    return {
        "architecture": platform.machine(),
        "macOS": captured(["sw_vers", "-productVersion"]),
        "xcode": captured(["xcodebuild", "-version"]).replace("\n", " "),
        "hardware": captured(["sysctl", "-n", "machdep.cpu.brand_string"]),
    }


def run_build(command: list[str], log_path: pathlib.Path) -> float:
    start = time.monotonic()
    with log_path.open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, text=True)
    elapsed = time.monotonic() - start
    if result.returncode != 0:
        raise RuntimeError(f"Build failed; see {log_path}")
    return elapsed


def build_command(
    root: pathlib.Path,
    derived_data: pathlib.Path,
    source_packages: pathlib.Path,
) -> list[str]:
    return [
        "xcodebuild",
        "build",
        "-workspace",
        str(root / "GitX.xcworkspace"),
        "-scheme",
        "GitX",
        "-configuration",
        "Debug",
        "-derivedDataPath",
        str(derived_data),
        "-clonedSourcePackagesDirPath",
        str(source_packages),
        "CODE_SIGNING_ALLOWED=NO",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path("build/BuildBenchmark/results.json"),
    )
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be at least 1")

    root = pathlib.Path(__file__).resolve().parent.parent
    output = args.output if args.output.is_absolute() else root / args.output
    benchmark_root = output.parent
    logs = benchmark_root / "logs"
    derived_data = benchmark_root / "DerivedData"
    source_packages = benchmark_root / "SourcePackages"
    logs.mkdir(parents=True, exist_ok=True)
    source_packages.mkdir(parents=True, exist_ok=True)

    resolve_command = [
        "xcodebuild",
        "-resolvePackageDependencies",
        "-workspace",
        str(root / "GitX.xcworkspace"),
        "-scheme",
        "GitX",
        "-clonedSourcePackagesDirPath",
        str(source_packages),
    ]
    subprocess.run(resolve_command, check=True)

    samples: list[BuildSample] = []
    command = build_command(root, derived_data, source_packages)
    for index in range(1, args.runs + 1):
        shutil.rmtree(derived_data, ignore_errors=True)
        cold = run_build(command, logs / f"run-{index}-cold.log")
        warm = run_build(command, logs / f"run-{index}-warm.log")
        sample = BuildSample(run=index, cold_seconds=cold, warm_seconds=warm)
        samples.append(sample)
        print(f"Run {index}/{args.runs}: cold {cold:.2f}s, warm {warm:.2f}s")

    cold_median, warm_median = medians(samples)
    failures = threshold_failures(cold_median, warm_median)
    report = {
        "version": 1,
        "environment": environment_fingerprint(),
        "gitRevision": captured(["git", "-C", str(root), "rev-parse", "HEAD"]),
        "ceilings": {
            "coldSeconds": COLD_CEILING_SECONDS,
            "warmSeconds": WARM_CEILING_SECONDS,
        },
        "medians": {
            "coldSeconds": round(cold_median, 3),
            "warmSeconds": round(warm_median, 3),
        },
        "samples": [sample._asdict() for sample in samples],
        "passed": not failures,
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Median: cold {cold_median:.2f}s, warm {warm_median:.2f}s")
    print(f"Report: {output}")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
