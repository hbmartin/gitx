---
name: gitx-testing
description: Plan, add, run, and review XCTest-based verification for GitX. Use whenever changing GitX behavior, fixing a bug, adding or reviewing tests, diagnosing test, coverage, analyzer, sanitizer, or performance failures, changing shared test plans or CI verification, ratcheting coverage, or preparing and validating an Objective-C-to-Swift conversion. Select Swift or Objective-C XCTest, app-hosted integration tests, XCUITest, performance tests, sanitizers, static analysis, and the stable app build in proportion to risk.
---

# GitX Testing

Protect observable behavior with XCTest, ratcheting coverage, explicit test plans, and risk-based verification. Preserve a green history while making tests durable across the gradual Objective-C-to-Swift migration.

## Establish the repository contract

1. Read `AGENTS.md` and inspect `git status` before planning or editing. Preserve unrelated work.
2. Treat the current files under `scripts/`, `Mintfile`, and applicable repo-local skills as canonical. Inspect them instead of copying command options, tool versions, baselines, or conversion rules from this skill.
3. Inspect the shared `.xctestplan` files and scheme before assigning or running tests. Do not rely on the plan selected in a local Xcode UI.
4. Load `$convert-objective-c-to-swift` whenever substantively editing first-party production Objective-C or explicitly preparing a conversion. Let that skill own migration mechanics and exclusions; keep responsibility here for test design, coverage evidence, and test-plan selection.
5. Do not modify `External/` tests or introduce a testing or analysis dependency without explicit user approval.

Read [references/test-design.md](references/test-design.md) when choosing a seam, test language, fixture, UI strategy, or assertion boundary. Read [references/coverage-and-verification.md](references/coverage-and-verification.md) when work is uncovered, involves a conversion, changes a baseline or test plan, or is ready for final verification.

## Classify the work before editing

Identify the smallest applicable set:

- pure decision or value behavior;
- ObjectiveGit, Git process, filesystem, defaults, notification, or app-hosted integration;
- AppKit wiring, responder-chain, bindings, accessibility, delegate, or data-source behavior;
- end-to-end user workflow;
- performance-sensitive behavior;
- concurrency or shared mutable state;
- pointer, C, Core Foundation, ownership, or unsafe-memory behavior;
- static-analysis, lint, formatting, coverage, or test-infrastructure failure;
- Objective-C behavior being prepared for Swift conversion.

Record the intended XCTest layer, shared plan, coverage evidence, and risk-specific checks in the working plan. If a broad redesign, new module or target, application-wide injection system, or multi-controller restructuring would materially improve testability, explain the opportunity and ask before expanding scope. Make small behavior-preserving seam extractions automatically when they are low risk, low churn, and directly support the requested change.

## Preserve green commit boundaries

When the affected behavior lacks meaningful coverage:

1. Add passing characterization XCTest for the current implementation.
2. Cover the relevant normal behavior, failures, and boundary cases.
3. Run the focused tests and measure affected-file coverage.
4. Commit the green characterization work separately before editing production behavior.
5. Add the new or regression expectation and confirm it fails locally.
6. Implement until the focused test passes; commit the expectation and implementation together.

Never create an intentionally failing commit. If meaningful focused coverage already exists, start with the local red-green cycle without manufacturing a preparation commit.

## Design durable XCTest

- Keep XCTest as the only test framework.
- Write new tests in Swift with XCTest when the production surface bridges cleanly. Use Objective-C XCTest only for Objective-C exceptions, C or macro surfaces that do not bridge, private Objective-C declarations that should not be exposed, or cases where Swift interoperability would create disproportionate churn.
- Do not convert an existing Objective-C test file merely because it is touched. Add a focused Swift XCTest file unless a whole-file test conversion is independently low risk.
- Test observable behavior rather than private call sequences or implementation details.
- Prefer deterministic decision types, presenters, and use-case objects over direct testing of large controllers. Keep AppKit wiring tests focused and app-hosted.
- Use isolated temporary repositories and deterministic local fixtures. Do not depend on network state, user defaults, locale, clock time, or the user's repositories unless explicitly controlled.
- In UI tests, query by accessibility identity and wait for observable state. Never use fixed sleeps.
- Add or refresh diagnostic screenshot attachments for new features and visible UI changes. Never add screenshot or pixel comparison testing.

## Enforce and ratchet coverage

Run correctness tests with coverage into a fresh result bundle, then execute the current `scripts/check_coverage.py <result.xcresult>`.

- Never lower a checked-in floor without explicit user approval.
- When coverage improves, run the checker with `--record-improvements`, inspect the baseline diff, and keep only genuine improvements.
- For ordinary changes, cover the affected behavior completely and ratchet the baseline; do not require an unrelated legacy file to reach 90%.
- Before converting an Objective-C implementation to Swift, require at least 90% line coverage for that implementation plus explicit XCTest of its normal behavior, failures, and boundary cases. Coverage percentage alone is insufficient.
- Track every conversion candidate in the checked-in baseline before conversion. If it is not listed, confirm its coverage in the raw `xccov` report, add it at the measured floor using the current checker's precision policy, and prove the plain checker passes.
- When a conversion changes a covered path from `.m` to `.swift`, deliberately replace the key while preserving the exact old floor, prove the plain checker passes, and only then use `--record-improvements`. The checker cannot infer a rename.

## Verify after the feature commit

After committing production behavior, rerun the full correctness plan with coverage, enforce and record coverage improvements, run static verification, and select every relevant additional plan or check:

- UI plan for controllers, views, bindings, responder behavior, accessibility, or user workflows;
- performance plan for performance-sensitive work;
- Address/Undefined Behavior Sanitizer plan for pointer, C, Core Foundation, ownership, or unsafe-memory work;
- Thread Sanitizer plan for concurrency, callbacks, notifications, tasks, or shared state;
- Clang analyzer for Objective-C, Objective-C++, ownership, C-facing, and nullability changes;
- pinned SwiftLint and SwiftFormat through `scripts/run_pinned_tool.sh` for Swift changes.

Use the exact current plan names, commands, versions, and baselines found in the repository. Remove stale debt entries in the same change that fixes them.

Build the final verified Debug app at `/Volumes/ExtStor/gitx/build/GitX.app`. Confirm that bundle exists and comes from the final commit.

## Report evidence

Summarize:

- tests added and the behavior they protect;
- the green characterization and feature commit boundaries, when applicable;
- focused and full plans or checks run, with results;
- affected-file and app coverage before and after, plus baseline changes;
- diagnostic screenshot attachments added or refreshed for feature/UI work;
- the stable app path;
- any skipped risk-specific check and why;
- any large structural opportunity awaiting a user decision.
