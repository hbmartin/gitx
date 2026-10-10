#!/usr/bin/env python3
"""Measure local cold and warm Debug builds against checked-in ceilings."""

from __future__ import annotations

import argparse
import contextlib
import json
import pathlib
import platform
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import tempfile
from typing import NamedTuple

import compilation_cache
import workflow_session as session


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


def snapshot_checkout(root, destination):
    """Copy the checked-out inputs into independent local clones for edit probes."""
    environment = session.git_environment()
    def clone(source, target):
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(source), str(target)],
                       check=True, env=environment)
        revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], env=environment).decode().strip()
        subprocess.run(["git", "-C", str(target), "checkout", "--quiet", "--detach", revision], check=True, env=environment)
        patch = subprocess.check_output(["git", "-C", str(source), "diff", "--binary", "HEAD", "--"], env=environment)
        if patch:
            subprocess.run(["git", "-C", str(target), "apply", "--binary"], input=patch, check=True, env=environment)
        entries = subprocess.check_output(["git", "-C", str(source), "ls-files", "--stage", "-z"], env=environment)
        for entry in entries.split(b"\0"):
            if not entry:
                continue
            metadata, name = entry.split(b"\t", 1)
            relative = pathlib.Path(os.fsdecode(name))
            if metadata.startswith(b"160000 "):
                clone(source / relative, target / relative)
            elif (source / relative).is_file():
                (target / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source / relative, target / relative)
            elif not (source / relative).exists():
                (target / relative).unlink(missing_ok=True)
    clone(root, destination)
    new = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"], env=environment)
    for name in new.split(b"\0"):
        if name and session.build_input_path(os.fsdecode(name)):
            relative = pathlib.Path(os.fsdecode(name))
            (destination / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / relative, destination / relative)
    external = pathlib.Path("External/objective-git/External")
    (destination / external).mkdir(parents=True, exist_ok=True)
    for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
        shutil.copy2(root / external / name, destination / external / name)


def cache_hits(log):
    return len(re.findall(r"\bcache hit\b", log.read_text(errors="replace"), re.IGNORECASE))


def compare_cache(root, output, runs):
    if runs < 5:
        raise ValueError("Cache qualification requires at least five paired runs")
    developer = os.environ.get("GITX_DEVELOPER_DIR") or os.environ.get("DEVELOPER_DIR") or \
        json.loads((root / "scripts/verification-config.json").read_text())["defaultDeveloperDirectory"]
    paths = session.cache_paths(root, developer=developer)
    toolchain = paths["toolchain"]
    policy = compilation_cache.policy("on", toolchain, platform.machine(), "Debug", "plain", "build", {})
    before = session.inputs(root)
    report = {"version": 2, "scope": "experiment", "deliveryEligible": False,
              "inputsBefore": before, "environment": environment_fingerprint() | {"selectedXcode": toolchain, "developerDir": developer},
              "cacheContext": policy["context"],
              "samples": {"off": [], "on": []}, "cacheHits": 0, "logs": [], "passed": False}
    output.parent.mkdir(parents=True, exist_ok=True)
    logs = output.parent / ("cache-logs-" + str(time.time_ns()))
    logs.mkdir()
    with tempfile.TemporaryDirectory(prefix="gitx-cache-benchmark-", dir=output.parent) as temporary:
        workspace = pathlib.Path(temporary)
        source = workspace / "source"
        owner = {"runId": logs.name, "pid": os.getpid(), "receipt": str(output), "producer": session.producer_identity()}
        with session.Leases([str(workspace), str(session.LOCK_ROOT / "build-benchmark")], owner) as leases:
            environment = leases.environment() | session.git_environment() | {"DEVELOPER_DIR": developer}
            snapshot_checkout(root, source)
            derived = workspace / "DerivedData"
            packages = workspace / "SourcePackages"
            command = build_command(source, derived, packages)
            command[0] = str(pathlib.Path(developer) / "usr/bin/xcodebuild")
            command += ["-destination", "platform=macOS,arch=" + platform.machine(), "-showBuildTimingSummary"]
            def measure(mode, label):
                log = logs / (label + ".log")
                started = time.monotonic()
                with log.open("w") as stream, contextlib.redirect_stdout(stream):
                    status = session.supervise(command + ["COMPILATION_CACHE_ENABLE_CACHING=" + ("YES" if mode == "on" else "NO"),
                                                          "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES"],
                                               directory=logs / "Diagnostics" / label, timeout=1200, env=environment)
                report["logs"].append(str(log))
                if status:
                    raise RuntimeError("Benchmark build failed: " + str(log))
                if mode == "on" and label.endswith("-fresh"):
                    report["cacheHits"] += cache_hits(log)
                return time.monotonic() - started
            try:
                # Prime the native cache without deleting any shared Xcode CAS.
                measure("on", "prime")
                for index in range(1, runs + 1):
                    for mode in (("off", "on") if index % 2 else ("on", "off")):
                        shutil.rmtree(derived, ignore_errors=True)
                        sample = {"run": index, "cold": measure(mode, f"{index}-{mode}-fresh"),
                                  "warm": measure(mode, f"{index}-{mode}-warm")}
                        for kind, relative in (("sourceEdit", "Classes/git/IndexSnapshot.swift"), ("headerEdit", "Classes/PBChangedFile.h")):
                            path = source / relative
                            original = path.read_bytes()
                            try:
                                path.write_bytes(original + f"\n// GitX benchmark {index} {mode} {kind}\n".encode())
                                sample[kind] = measure(mode, f"{index}-{mode}-{kind}")
                            finally:
                                path.write_bytes(original)
                        report["samples"][mode].append(sample)
                        print(f"Pair {index}/{runs} {mode}: fresh {sample['cold']:.2f}s; warm {sample['warm']:.2f}s", flush=True)
                report.update(compilation_cache.qualify(report["samples"]["off"], report["samples"]["on"], report["cacheHits"]))
            except RuntimeError as error:
                report["failures"] = [str(error)]
            finally:
                report["inputsAfter"] = session.inputs(root)
                if session.changed_inputs(before, report["inputsAfter"]):
                    report["passed"] = False
                    report.setdefault("failures", []).append("Source inputs changed during the experiment")
                session.atomic_json(output, report)
    print("Cache qualification: " + ("passed" if report["passed"] else "failed") + "; report: " + str(output))
    return 0 if report["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--compare-compilation-cache", action="store_true")
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
    if args.compare_compilation_cache:
        try:
            return compare_cache(root, output, args.runs)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(error, file=sys.stderr)
            return 2
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
