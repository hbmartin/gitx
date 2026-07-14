# Coverage, Commits, and Verification

Use this reference for uncovered behavior, coverage ratcheting, conversion preparation, shared plan selection, and final handoff. Inspect the current repository scripts, `Mintfile`, scheme, and test plans before running commands; they are authoritative.

## Contents

- Green test-first history
- Coverage workflow
- Objective-C conversion gate
- Verification matrix
- Static and dependency checks
- Stable application build
- Failure handling and reporting

## Green test-first history

For an uncovered area, create a preparation commit containing passing characterization XCTest for the current implementation. Include directly required test seams or header interoperability modernization only when the applicable repo-local conversion skill assigns them to that preparation commit.

After the preparation commit:

1. Write the regression or new-behavior expectation.
2. Run it against the unchanged implementation and confirm the expected failure.
3. Implement the behavior until the focused test passes.
4. Commit the expectation and implementation together.

Do not commit the intentionally failing intermediate state. When focused coverage already proves the affected contract, use the local red-green cycle and omit an artificial characterization commit.

## Coverage workflow

Produce a fresh `.xcresult` bundle from the correctness plan with coverage enabled. Run the canonical checker:

```sh
scripts/check_coverage.py <result.xcresult>
```

After a real increase, raise checked-in floors:

```sh
scripts/check_coverage.py <result.xcresult> --record-improvements
```

Review the baseline diff. The ratchet must retain the target floor, retain every measured file floor that did not improve, raise measured floors that did improve, and never conceal a missing file. Do not lower a floor, delete a tracked file, or change rounding to make a regression pass without explicit approval.

The checker ratchets only paths already present in the baseline. For a conversion candidate that is not tracked, inspect the raw `xccov` report, confirm that the exact source path reaches the gate, add that path to the baseline at the measured floor using the precision policy currently implemented by the checker, and run the plain checker before proceeding. Do not expect `--record-improvements` to discover a file.

For ordinary behavior changes, require:

- complete XCTest coverage of the affected normal, failure, and boundary behavior;
- no violation of the current app or file floors;
- a recorded floor increase when the checker observes one;
- an explanation when the changed code cannot contribute executable coverage.

Avoid treating a rounded app-wide percentage as the only signal. Report affected-file coverage and the checked-in ratchet diff.

## Objective-C conversion gate

Before production Objective-C moves to Swift, require all of the following:

- at least 90% line coverage for the implementation file;
- explicit XCTest for normal behavior;
- explicit XCTest for failures and recovery that the API supports;
- explicit XCTest for admitted boundary cases;
- passing characterization tests against the Objective-C implementation;
- no lowered app or file floor.

If the file is below 90%, stop conversion work after the green characterization preparation and add coverage until the gate is met. If unreachable, generated, or trivial glue prevents 90%, ask for an explicit, narrow exception; do not grant one implicitly.

When the conversion replaces `Path/File.m` with `Path/File.swift`, treat a missing old path as an expected signal that the baseline key still needs a deliberate one-for-one migration. Inspect the raw `xccov` report to prove that the new path is present, replace only the old key with the new key, and initially preserve the exact old numeric floor. Run the plain checker against a fresh result before using `--record-improvements`; the checker cannot infer renames, and ratcheting while a stale key remains can rewrite the baseline before reporting the missing-file failure. After the plain check passes, record improvements, inspect the diff, and run the plain check again. Use the repo-local conversion skill for the full compatibility and verification workflow.

## Verification matrix

Inspect the scheme and every shared `.xctestplan` before use. The current intended roles are:

| Risk or change | Required verification |
| --- | --- |
| Any feature or bug fix | Focused XCTest during development; full correctness plan with coverage after the feature commit |
| Controller, view, binding, responder-chain, accessibility, or end-to-end workflow | Relevant app-hosted XCTest and UI plan; diagnostic screenshot attachment for new feature or visible UI change |
| Performance-sensitive algorithm or operation | Correctness plan plus the performance plan |
| Pointer, C, Core Foundation, ownership, buffer, or unsafe-memory behavior | Correctness plan plus Address/Undefined Behavior Sanitizers |
| Queue, callback, task, notification, or shared-state behavior | Correctness plan plus Thread Sanitizer |
| Objective-C, Objective-C++, C-facing, ownership, or nullability edit | Static verification plus Clang analyzer |
| Swift edit | Static verification plus pinned SwiftLint and SwiftFormat |
| Test-plan, scheme, workflow, or verification-script edit | Validate syntax, inspect test membership, and exercise the affected command path |

Use explicit test-plan arguments and a unique result bundle path. Do not rely on the selected Xcode plan. Keep correctness, UI, performance, and sanitizer execution separate. Add every new test class to the correct shared plan and verify discovery by running it.

## Static and dependency checks

Run repository scripts rather than reconstructing their internals. Use `scripts/verify_static.sh` with the appropriate base. Use the analyzer script for relevant Objective-C and C-family changes. Run SwiftLint and SwiftFormat only through `scripts/run_pinned_tool.sh`; obtain exact versions from `Mintfile` and never substitute a globally installed version silently.

Treat header interoperability, SwiftLint, and analyzer baselines as shrinking debt. Remove stale entries in the same change that fixes the underlying issue. Do not add broad exclusions where an exact baseline entry is possible.

Do not add a third-party test framework, snapshot library, linter, dead-code analyzer, reporting service, or wrapper task runner without explicit approval. Existing repository infrastructure is the default.

## Stable application build

After post-commit verification succeeds, build the Debug app so the final bundle is exactly:

```text
/Volumes/ExtStor/gitx/build/GitX.app
```

Use the current workspace and `GitX` scheme, direct Derived Data to the repository's ignored `build/` area, and set the final configuration output so this path is refreshed. Confirm the bundle exists after the build and corresponds to the final commit; do not report a stale pre-change bundle.

## Failure handling and reporting

When a required check fails, fix within scope and rerun the failed check plus anything invalidated by the fix. Preserve `.xcresult` and analyzer artifacts when they help diagnosis. Never weaken a plan, sanitizer, warning baseline, or coverage floor merely to make the task green.

Report exact plans and scripts run, pass/fail outcome, coverage before and after, baseline changes, screenshots attached, stable app path, and any skipped conditional check with its rationale.
