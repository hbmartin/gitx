# Build Performance Follow-ups

## Current Local Contract

Run:

```sh
scripts/benchmark_build.py
```

The script records five paired cold and no-op warm Debug builds, environment details, individual logs, and JSON results under `build/BuildBenchmark/`. The non-regression ceilings are the pre-modularization local medians:

- cold Debug build: `108.23s`;
- no-op warm Debug build: `19.55s`.

This is a local feedback threshold, not a CI timing gate. Compare medians only on the same machine and toolchain class. Debug builds use DWARF without a dSYM; Release continues to produce a dSYM.

The first post-modularization run on 2026-07-18 (Apple M2 Pro, macOS 26.5.1, Xcode 26.6) passed with `61.11s` cold and `4.82s` warm medians. These are evidence of the current change, not tighter permanent ceilings; gather more runs before ratcheting thresholds.

## Deferred Dependency Work

1. Measure ObjectiveGit and Sparkle target/script duration separately from GitX compilation.
2. Add accurate script-phase inputs and outputs where upstream build logic permits it.
3. Evaluate prebuilt or cached dependency products only after reproducibility and symbolication requirements are written down.
4. Measure whether `build-for-testing` plus `test-without-building` improves repeated app-hosted test loops.
5. Inspect the app version script, which currently runs every build, and make it dependency-aware without producing stale version metadata.
6. Revisit package product type and linkage only with binary-size, launch-time, and incremental-build measurements.

Do not modify `External/` as part of these experiments. Keep dependency changes separate from core ownership changes so regressions remain attributable.
