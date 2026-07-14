# Future Work: GitXCore and Hostless Tests

## Goal

Establish one deliberately small, Foundation-only module named `GitXCore`, plus a hostless `GitXCoreTests` target. The module should hold deterministic domain and presentation decisions that do not require `NSApplication`, AppKit controls, ObjectiveGit, a repository process, or a run loop.

This is an architectural boundary, not a request to move every non-view class. One useful module with strict dependencies is preferable to many premature packages.

## Boundary

`GitXCore` may import:

- `Foundation`
- Swift standard-library modules

It must not import:

- `AppKit` or `Cocoa`
- ObjectiveGit or libgit2
- WebKit
- first-party app targets
- process, file-watcher, user-defaults, notification-center, or singleton implementations

The app may depend on `GitXCore`; `GitXCore` must never depend on the app. Repository I/O belongs behind values supplied to the core or behind small protocols whose concrete implementations remain in the app target.

## First Candidates

Migrate in narrow, behavior-preserving slices rather than moving directories wholesale:

1. Relative-date policy. Separate the calculation from `Formatter`, inject `now` and `Calendar`, and leave the Objective-C-visible `GitXRelativeDateFormatter` as a thin adapter. This removes wall-clock and locale nondeterminism from its tests.
2. Revision-specifier parsing and titles. Represent parameters, path limiters, and simple/complex-ref classification as Foundation values. Keep conversion to `PBGitRef` in the app adapter until ref classification is also independent of Objective-C runtime behavior.
3. Reference-name classification. Branch, tag, remote, stash, and short-name decisions are string transformations and suit a value type. Preserve the existing Objective-C façade while callers migrate.
4. Presentation decisions extracted from controllers: search-mode filtering, history menu eligibility, push-control state, staging eligibility, split limits, retry delays, and similar state transformations. Inputs and outputs should be explicit values rather than AppKit objects.
5. Source-language lookup from `PBHighlighting`. Move extension/name-to-language selection into the core while keeping attributed-string construction and HighlightKit in the app.

Do not initially move repository access, `NSDocument`, mutable ObjectiveGit models, attributed-string rendering, controls, controllers, defaults storage, or task execution.

## Target Shape

Prefer an Xcode framework target in the existing workspace for the first increment:

- `GitXCore.framework`: Swift, Foundation-only, no app host.
- `GitXCoreTests.xctest`: XCTest unit-test bundle with `TEST_HOST` and `BUNDLE_LOADER` unset.
- `GitX.app`: links `GitXCore` and owns all AppKit/Objective-C adapters.
- `GitXTests.xctest`: remains app-hosted for Objective-C, ObjectiveGit, integration, and AppKit tests.

An Xcode target avoids introducing a second dependency-management system while the boundary is still evolving. Reconsider a local Swift package only after the public surface is stable and there is a real reuse or build-time benefit.

Add a static verification check that rejects `import AppKit` and `import Cocoa` beneath the core source directory. The target's link dependencies should also be reviewed in CI so an accidental framework dependency cannot silently weaken the boundary.

## Hostless Test Policy

Continue to use XCTest. Hostless tests should:

- finish without launching GitX or touching `NSApplication.shared`;
- use explicit clocks, calendars, locales, and time zones;
- use table-driven cases for parsers and state transformations;
- use temporary directories only through an injected file-system boundary;
- avoid global defaults and notification state;
- be independent and safe to run in parallel and random order;
- assert values and observable decisions, not calls into adapter implementations.

The default test plan should run `GitXCoreTests` before app-hosted tests. CI should retain separate timing and coverage for the core target so a growing integration suite cannot hide a slow or weak hostless layer.

## Migration Sequence

For each slice:

1. Add characterization tests around current behavior in the existing target.
2. Define the smallest Foundation input and output values.
3. Add equivalent failing tests to `GitXCoreTests`.
4. Implement the core policy, then keep a thin adapter with the existing Objective-C-visible API.
5. Run both suites and compare behavior at the adapter boundary.
6. Move callers gradually; do not combine the extraction with UI or naming redesign.
7. Raise the core coverage floor and delete obsolete characterization tests only when the same contract is covered at the lower layer.

The first milestone should contain only the target, its dependency guard, relative-date policy, and one controller-derived decision. That is enough to prove build, test, coverage, and interop mechanics before broad migration.

## Success Criteria

- `GitXCore` builds without AppKit or ObjectiveGit.
- `GitXCoreTests` runs with no application host and no UI session.
- A representative pure-logic test run completes in seconds.
- New controller decision logic normally enters through a tested core value or use-case object.
- Core coverage has a checked-in, nondecreasing floor distinct from app/integration coverage.
- Existing Objective-C callers retain source-compatible adapters during incremental migration.

## Risks and Guardrails

- Do not create protocol layers around every type. Add a seam only at an I/O, time, persistence, or UI boundary.
- Do not leak `NSColor`, `NSImage`, `NSMenuItem`, `NSIndexPath` UI conventions, ObjectiveGit objects, or mutable controllers into core APIs.
- Do not turn `GitXCore` into a miscellaneous utilities bucket; every public type should express a GitX domain or presentation decision.
- Avoid a large Objective-C-to-Swift rewrite as part of target creation. Move behavior only when tests make the change low risk.
- If a candidate needs a run loop or application host, keep it in `GitXTests` and extract a smaller decision instead.
