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
        "-onlyUsePackageVersionsFromResolvedFile",
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
    destination = pathlib.Path(destination).resolve()
    def copy_input(source, target):
        target = pathlib.Path(target)
        if not target.parent.resolve().is_relative_to(destination):
            raise ValueError("Snapshot input leaves the owned checkout: " + str(target))
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            # Replace only the leaf; never follow a clone's link to its referent.
            target.unlink()
        shutil.copy2(source, target, follow_symlinks=False)
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
            elif (source / relative).is_symlink() or (source / relative).is_file():
                copy_input(source / relative, target / relative)
            elif not (source / relative).exists():
                (target / relative).unlink(missing_ok=True)
    clone(root, destination)
    new = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"], env=environment)
    for name in new.split(b"\0"):
        if name and session.build_input_path(os.fsdecode(name)):
            relative = pathlib.Path(os.fsdecode(name))
            copy_input(root / relative, destination / relative)
    external = pathlib.Path("External/objective-git/External")
    for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
        copy_input(root / external / name, destination / external / name)


def edit_probe_path(source, relative):
    source = pathlib.Path(source)
    path = source / relative
    if source.resolve() != source or not path.resolve().is_relative_to(source):
        raise ValueError("Benchmark edit probe leaves the owned source snapshot: " + str(path))
    return path


def cache_hits(log):
    return len(re.findall(r"\bcache hit\b", log.read_text(errors="replace"), re.IGNORECASE))


def reset_products(derived, workspace):
    derived, workspace = pathlib.Path(derived).resolve(), pathlib.Path(workspace).resolve()
    if derived.parent != workspace or derived.name != "DerivedData":
        raise ValueError("Only the benchmark's owned DerivedData may be reset")
    cache = derived / "CompilationCache.noindex"
    preserved = workspace / "PreservedCompilationCache.noindex"
    if cache.exists():
        cache.rename(preserved)
    try:
        if derived.exists():
            shutil.rmtree(derived)
    finally:
        derived.mkdir(parents=True, exist_ok=True)
        if preserved.exists():
            preserved.rename(cache)


def compare_cache(root, output, runs):
    if runs < 5:
        raise ValueError("Cache qualification requires at least five paired runs")
    report = {"version": 2, "scope": "experiment", "deliveryEligible": False,
              "checkout": str(root), "samples": {"off": [], "on": []}, "cacheHits": 0,
              "logs": [], "passed": False, "status": "running"}
    output.parent.mkdir(parents=True, exist_ok=True)
    before = None
    status = 2
    phase = "setup-failed"
    try:
        developer = os.environ.get("GITX_DEVELOPER_DIR") or os.environ.get("DEVELOPER_DIR")
        if not developer:
            configuration = json.loads((root / "scripts/verification-config.json").read_text())
            if not isinstance(configuration, dict) or not isinstance(configuration.get("defaultDeveloperDirectory"), str) or not configuration["defaultDeveloperDirectory"]:
                raise ValueError("Verification configuration requires a defaultDeveloperDirectory path")
            developer = configuration["defaultDeveloperDirectory"]
        toolchain = session.cache_paths(root, developer=developer)["toolchain"]
        policy = compilation_cache.policy("on", toolchain, platform.machine(), "Debug", "plain", "build", {})
        report.update(environment=environment_fingerprint() | {"selectedXcode": toolchain, "developerDir": developer},
                      cacheContext=policy["context"])
        libraries = root / "External/objective-git/External"
        missing = [name for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp")
                   if not (libraries / name).is_file()]
        if missing:
            raise ValueError("Missing generated dependency products: " + ", ".join(missing) +
                             ". Inspect External/objective-git/script/bootstrap prerequisites and prepare "
                             "the existing dependencies explicitly before benchmarking.")
        before = session.inputs(root)
        report["inputsBefore"] = before
        with tempfile.TemporaryDirectory(prefix="gitx-cache-benchmark-", dir=output.parent) as temporary:
            workspace = pathlib.Path(temporary)
            logs = output.parent / ("cache-logs-" + str(time.time_ns()))
            owner = {"runId": logs.name, "pid": os.getpid(), "receipt": str(output), "producer": session.producer_identity()}
            phase = "lease-failed"
            with session.Leases([str(workspace), str(session.LOCK_ROOT / "build-benchmark")], owner) as leases:
                # Sanitize after adding authenticated lease holdings; a union with
                # os.environ would reintroduce foreign checkout selectors.
                environment = session.git_environment(leases.environment()) | {"DEVELOPER_DIR": developer}
                logs.mkdir()
                source = (workspace / "source").resolve()
                phase = "snapshot-failed"
                snapshot_checkout(root, source)
                derived = workspace / "DerivedData"
                packages = workspace / "SourcePackages"
                command = build_command(source, derived, packages)
                command[0] = str(pathlib.Path(developer) / "usr/bin/xcodebuild")
                command += ["-destination", "platform=macOS,arch=" + platform.machine(), "-showBuildTimingSummary"]
                phase = "build-failed"
                def measure(mode, label):
                    log = logs / (label + ".log")
                    report["logs"].append(str(log))
                    started = time.monotonic()
                    with log.open("w") as stream, contextlib.redirect_stdout(stream):
                        result = session.supervise(command + ["COMPILATION_CACHE_ENABLE_CACHING=" + ("YES" if mode == "on" else "NO"),
                                                             "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES"],
                                                   directory=logs / "Diagnostics" / label, timeout=1200, env=environment)
                    if result:
                        raise RuntimeError("Benchmark build failed (exit " + str(result) + "): " + str(log))
                    if mode == "on" and label.endswith("-fresh"):
                        report["cacheHits"] += cache_hits(log)
                    return time.monotonic() - started
                measure("on", "prime")
                for index in range(1, runs + 1):
                    for mode in (("off", "on") if index % 2 else ("on", "off")):
                        reset_products(derived, workspace)
                        sample = {"run": index, "cold": measure(mode, f"{index}-{mode}-fresh"),
                                  "warm": measure(mode, f"{index}-{mode}-warm")}
                        for kind, relative in (("sourceEdit", "Classes/git/IndexSnapshot.swift"), ("headerEdit", "Classes/PBChangedFile.h")):
                            path = edit_probe_path(source, relative)
                            original = path.read_bytes()
                            try:
                                path.write_bytes(original + f"\n// GitX benchmark {index} {mode} {kind}\n".encode())
                                sample[kind] = measure(mode, f"{index}-{mode}-{kind}")
                            finally:
                                path.write_bytes(original)
                        report["samples"][mode].append(sample)
                        print(f"Pair {index}/{runs} {mode}: fresh {sample['cold']:.2f}s; warm {sample['warm']:.2f}s", flush=True)
                report.update(compilation_cache.qualify(report["samples"]["off"], report["samples"]["on"], report["cacheHits"]))
                status = 0 if report["passed"] else 1
                report["status"] = "passed" if report["passed"] else "failed"
                report["category"] = "qualification"
    except session.ResourceBusy as error:
        status = 75
        report.update(status="blocked", category="resource-busy", failures=[str(error)])
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        status = 2 if phase in {"setup-failed", "lease-failed", "snapshot-failed"} else 1
        report.update(status="failed", category=phase, failures=[str(error)])
    finally:
        if before is not None:
            try:
                report["inputsAfter"] = session.inputs(root)
                if session.changed_inputs(before, report["inputsAfter"]):
                    report["passed"] = False
                    report.setdefault("failures", []).append("Source inputs changed during the experiment")
                    report["status"] = "invalid"
                    if status == 0:
                        status = 76
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                report["passed"] = False
                report.setdefault("failures", []).append("Final input evidence unavailable: " + str(error))
                report["status"] = "invalid"
                if status == 0:
                    status = 76
        report["exitCode"] = status
        report["finishedAt"] = session.dt.datetime.now(session.dt.timezone.utc).isoformat()
        session.atomic_json(output, report)
    print("Cache qualification: " + ("passed" if report["passed"] else "failed") + "; report: " + str(output))
    return status


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
        "-onlyUsePackageVersionsFromResolvedFile",
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
