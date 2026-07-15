# Swift 6.2 Migration

GitX's first-party Swift now builds in Swift 6 language mode with the Swift 6.2
concurrency model. The application remains a mixed Objective-C/Swift target;
this migration changes the language and isolation contract of Swift code rather
than rewriting stable Objective-C code.

## Toolchain contract

- CI is pinned to Xcode 26.2, whose bundled compiler is Swift 6.2.3.
- Xcode expresses every Swift 6.x language mode as `SWIFT_VERSION = 6.0`.
  The Xcode pin, not a `6.2` project-setting value, selects the 6.2 compiler.
- The app and app-hosted unit-test targets use complete strict-concurrency
  checking and treat Swift warnings as errors.
- ObjectiveGit's two existing framework-header warning categories are demoted
  from errors only at the Swift importer boundary. First-party Swift warnings
  remain fatal, and the existing Objective-C warning/analyzer baselines remain
  independent.

The migration was also exercised locally with Xcode 26.6 / Swift 6.3.3 because
that is the installed developer toolchain. The Xcode 26.2 CI jobs are the
authoritative exact-version verification. This distinction matters because the
Swift 6.3 line has had executor-restoration regressions around
`nonisolated(nonsending)` and `@concurrent`; GitX currently uses neither an
`@concurrent` function nor a nonisolated async function.

## Project settings

The app target enables:

```text
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_TREAT_WARNINGS_AS_ERRORS = YES
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
SWIFT_APPROACHABLE_CONCURRENCY = YES
```

The unit-test target uses Swift 6, complete checking, warnings as errors, and
Approachable Concurrency. It intentionally keeps the language's nonisolated
default because `XCTestCase` is a nonisolated Objective-C superclass. AppKit
test suites opt into `@MainActor` explicitly.

Debug app and test builds also pass
`-Xfrontend -enable-actor-data-race-checks`. All shared test plans retain Main
Thread Checker coverage; dedicated Address/Undefined Behavior and Thread
Sanitizer plans remain checked in.

## Isolation model

GitX uses a MainActor-first model without forcing background work onto the UI
executor:

- AppKit views and ordinary UI helpers inherit the app target's MainActor
  default. `RefreshCoalescer` is explicitly `@MainActor` because it owns a UI
  invalidation scheduled for the next main-loop turn.
- Immutable render snapshots, decision policies, process-environment assembly,
  and syntax highlighting are explicitly `nonisolated`. Objective-C render and
  task queues call these APIs off-main today, so their Swift contract matches
  their real execution context.
- `CommitRenderInput` and `RemoteSidebarSyncPlan` are immutable `Sendable`
  snapshots.
- `RepositoryRefreshCoordinator` is nonisolated and `Sendable`; all mutable
  debounce state is stored in a checked `Synchronization.Mutex`. Scheduled
  closures and scheduling protocols are `@Sendable`.
- `PBHistoryArrayController` remains nonisolated because `NSArrayController`'s
  override contract is nonisolated even though GitX wires the instance through
  Cocoa Bindings on the main thread.
- Mutable focus-refresh tracking remains MainActor-owned by its window
  controller.

No first-party Swift source currently uses `@unchecked Sendable`,
`nonisolated(unsafe)`, `@preconcurrency`, `assumeIsolated`, `unsafeBitCast`, or
`@retroactive`.

## Enforcement

`scripts/check_swift_concurrency_escapes.py` scans production and test Swift.
Any future safety escape must have a nearby comment containing:

```text
swift6-safety-justification:
```

The justification must name the synchronization or compatibility invariant.
The check runs from `scripts/verify_static.sh`, and policy tests pin the language
mode, concurrency settings, runtime checks, and Xcode 26.2 workflow versions.

## Verification workflow

Migration changes must keep these shared plans green:

```sh
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitX \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXUI \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXPerformance \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXThreadSanitizer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXAddressUndefined \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
```

After the unit plan, enforce and ratchet coverage with
`scripts/check_coverage.py`. Run pinned SwiftFormat and SwiftLint through
`scripts/run_pinned_tool.sh`, then run `scripts/verify_static.sh` and the Clang
analyzer.

The built application must also be exercised directly. At minimum, open a real
repository, render history and a diff, enter the staging view, stage and unstage
a disposable change, and verify watcher-driven refreshes with the Debug actor
checks active.

## Deliberate non-goals

- XCTest remains the repository's test framework; this migration does not adopt
  Swift Testing.
- Stable Objective-C is not converted merely to increase the Swift percentage.
- The app target is not split into new modules in this change. If non-UI Swift
  grows substantially, moving those types into a nonisolated core target is the
  preferred next architectural step.
- Do not add `@concurrent`, actors, or unsafe Sendable conformances as migration
  decoration. Add them only when an observed workload or ownership boundary
  requires them and tests cover the concurrent behavior.
