# Swift 6 Migration Roadmap

## Decision

Migrate GitX to Swift 6 language mode incrementally while retaining XCTest for all tests. This roadmap does **not** adopt Swift Testing. Objective-C tests, AppKit/UI automation, performance metrics, existing test infrastructure, and the desired incremental migration are all served by XCTest.

The migration has two separate axes:

- toolchain adoption: build with the pinned Xcode/Swift compiler;
- language-mode adoption: enable stricter Swift 6 checking target by target.

Using a Swift 6 compiler does not require enabling Swift 6 language mode immediately.

## Phase 0: Reproducible Baseline

- Keep CI and documented local development on a pinned Xcode version.
- Keep SwiftLint and SwiftFormat pinned through `Mintfile`.
- Require a clean build, XCTest run, analyzer run, and warning baseline before changing concurrency settings.
- Record the current `SWIFT_VERSION`, strict-concurrency, upcoming-feature, and warnings-as-errors settings for every target.
- Keep generated Swift interfaces and Objective-C bridging headers out of unrelated migration commits.

Exit condition: the same revision produces the same compiler/linter result locally and in CI.

## Phase 1: Prepare APIs in Existing Language Mode

- Turn on targeted upcoming-feature and concurrency warnings one category at a time in CI, initially without making them errors.
- Make ownership and isolation explicit at boundaries: immutable values should be `Sendable`; UI work should be main-actor isolated; mutable shared services should have one documented synchronization owner.
- Replace implicit shared mutable state in new Swift code with injected dependencies.
- Modernize Objective-C headers as they are touched: nullability regions, lightweight generics, and explicit nullable delegates, outlets, return values, and error out-parameters.
- Reduce imported implicitly-unwrapped optionals before tightening Swift checking.
- Prefer completion handlers with documented queue behavior until an async conversion can be isolated and tested.

Do not scatter `@unchecked Sendable`, `nonisolated(unsafe)`, or blanket `@preconcurrency` annotations merely to silence diagnostics. Each exception needs a comment naming the synchronization or compatibility guarantee and a follow-up issue.

Exit condition: new or edited Swift code introduces no new strict-concurrency warnings, and Objective-C interop debt continues to shrink.

## Phase 2: Establish the Foundation-Only Boundary

Create the `GitXCore` and hostless XCTest targets described in [future_work.md](future_work.md). Pure value types and policies are the safest first Swift 6 surface because they do not inherit AppKit isolation or Objective-C mutability.

- Enable complete concurrency checking on `GitXCore` first.
- Run its XCTest target in parallel and randomized order.
- Use injected clocks/calendars and immutable fixtures.
- Require `Sendable` for values that cross task or actor boundaries; do not require it for values that never cross one.

Exit condition: `GitXCore` builds cleanly with complete checking and has no unsafe concurrency suppressions.

## Phase 3: Isolate AppKit and Adapters

- Treat AppKit views, controllers, documents, and UI delegates as main-actor-owned.
- Annotate the narrowest useful surface rather than marking the entire application main-actor-isolated by default.
- Keep Objective-C callbacks at adapter boundaries. Hop to the main actor deliberately before changing UI state.
- Replace callback races with explicit state machines/use-case objects before converting them to async APIs.
- Audit notification observers, KVO/Cocoa Bindings, timers, file watchers, dispatch callbacks, and ObjectiveGit completion handlers for queue assumptions.
- Keep tests that instantiate AppKit in the app-hosted XCTest target and make their main-thread requirement explicit.

Exit condition: UI-bound Swift files have an understandable isolation model, and compiler warnings no longer depend on broad compatibility annotations.

## Phase 4: Per-Target Swift 6 Language Mode

Adopt language mode in this order:

1. `GitXCore` and its hostless XCTest bundle.
2. Small leaf Swift adapters with no controller ownership.
3. App-hosted unit-test Swift support, if introduced.
4. The GitX app target after all of its current Swift files are clean.
5. UI and performance test targets last; they remain XCTest.

Make each target change a focused commit. A target advances only when its tests, static checks, analyzer, and sanitizer plans remain green. Do not mix a language-mode flip with behavior changes or broad formatting.

## Phase 5: Warnings as Errors and Ratchet

- Make Swift warnings errors in CI once the app target has no warning baseline.
- Keep local Debug builds practical; CI is the authoritative clean-build gate.
- Treat new unsafe concurrency escape hatches like warning debt: exact checked-in entries with owner, rationale, and removal condition.
- Remove compatibility flags and suppression entries as dependencies and Objective-C headers improve.
- Re-run Address/Undefined Behavior and Thread Sanitizer plans after each isolation milestone.

Exit condition: all first-party targets use Swift 6 language mode, CI has zero unbudgeted warnings, and unsafe exceptions are explicit and shrinking.

## Test Strategy During Migration

- XCTest remains the only test framework.
- Preserve Objective-C XCTest coverage for Objective-C exception behavior and legacy interop.
- Use hostless XCTest for Foundation-only values.
- Use app-hosted XCTest for AppKit and ObjectiveGit integration.
- Use XCUITest for a small set of accessibility-driven workflows.
- Use XCTest performance APIs and `XCTMetric`; performance tests run in their own plan.
- Do not perform screenshot comparison testing as part of this roadmap.

Every migration slice begins with characterization tests when coverage is absent. Coverage floors must not be lowered to accommodate the migration.

## Diagnostic Triage Rules

When the compiler reports a concurrency problem, prefer fixes in this order:

1. Make the value immutable or keep it within one isolation domain.
2. Move UI ownership to the main actor.
3. Pass a value snapshot instead of sharing a mutable object.
4. Introduce an actor or existing lock owner when shared mutation is real.
5. Wrap a legacy callback behind a small adapter with documented queue behavior.
6. Use a temporary compatibility annotation only with a concrete reason and removal plan.

## Explicit Non-Goals

- No Swift Testing adoption.
- No wholesale rewrite of working Objective-C.
- No automatic conversion of controllers without first extracting their decision logic.
- No simultaneous replacement of ObjectiveGit or AppKit.
- No requirement that every class be an actor or every protocol be `Sendable`.
