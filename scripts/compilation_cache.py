#!/usr/bin/env python3
"""Native Xcode compilation-cache policy and measured qualification."""
from __future__ import annotations

import argparse
import json
import math
import platform
import re
import statistics
import sys

import workflow_session as session


def policy(mode, toolchain, architecture, configuration, instrumentation, action, config):
    if mode not in {"auto", "on", "off"}:
        raise ValueError("Compilation cache must be auto, on, or off")
    version = re.search(r"Xcode (\d+)(?:\.(\d+))?", toolchain)
    build = re.search(r"Build version (\S+)", toolchain)
    context = {"xcodeBuild": build[1] if build else None, "architecture": architecture,
               "configuration": configuration, "instrumentation": instrumentation, "action": action}
    supported = bool(version and int(version[1]) >= 26)
    if action in {"test:core", "test:forgekit"}:
        enabled, reason = False, "not-applicable-package"
    elif mode == "off":
        enabled, reason = False, "explicit-off"
    elif not supported:
        if mode == "on":
            raise ValueError("Native compilation caching requires a supported Xcode 26+ toolchain")
        enabled, reason = False, "unsupported-toolchain"
    elif mode == "on":
        enabled, reason = True, "explicit-experiment"
    else:
        validated = config.get("compilationCache", {}).get("validated", [])
        enabled = context in validated
        reason = "validated-context" if enabled else "not-validated"
    return {"version": 1, "requested": mode, "enabled": enabled, "supported": supported,
            "reason": reason, "context": context}


def qualify(off, on, hits, *, cold_ceiling=108.23, warm_ceiling=19.55):
    failures = []
    if len(off) < 5 or len(on) < 5 or len(off) != len(on):
        failures.append("At least five paired samples are required")
    if not hits:
        failures.append("No compilation cache hits observed")
    if not off or not on:
        return {"passed": False, "failures": failures + ["Missing build samples"]}
    if any(type(row.get(key)) not in (int, float) or not math.isfinite(row[key]) or row[key] <= 0
           for rows in (off, on) for row in rows for key in ("cold", "warm")):
        return {"passed": False, "failures": failures + ["Invalid build durations"]}
    medians = {mode: {key: statistics.median(row[key] for row in rows) for key in ("cold", "warm")}
               for mode, rows in (("off", off), ("on", on))}
    improvement = 1 - medians["on"]["cold"] / medians["off"]["cold"]
    regression = medians["on"]["warm"] / medians["off"]["warm"] - 1
    if improvement < .1:
        failures.append("Fresh-build median improvement is below 10%")
    if regression > .05:
        failures.append("Warm-build median regression exceeds 5%")
    if medians["on"]["cold"] > cold_ceiling or medians["on"]["warm"] > warm_ceiling:
        failures.append("Existing build ceilings were exceeded")
    return {"passed": not failures, "failures": failures, "medians": medians,
            "coldImprovement": improvement, "warmRegression": regression, "cacheHits": hits}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--instrumentation", default="plain")
    parser.add_argument("--action", default="build")
    parser.add_argument("--developer-dir")
    args = parser.parse_args()
    try:
        toolchain = session.cache_paths(developer=args.developer_dir)["toolchain"]
        config = json.loads((session.ROOT / "scripts/verification-config.json").read_text())
        print(json.dumps(policy(args.mode, toolchain, platform.machine(), args.configuration,
                                args.instrumentation, args.action, config)))
        return 0
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
