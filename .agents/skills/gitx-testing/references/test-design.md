# XCTest Design for GitX

Use this reference to select test boundaries and durable fixtures. Repository scripts, `Mintfile`, and applicable repo-local skills remain authoritative when guidance conflicts.

## Contents

- Framework and language policy
- Test-layer selection
- Seams for controllers and AppKit
- Fixtures and test doubles
- UI automation and screenshots
- Performance and sanitizer design
- Migration durability

## Framework and language policy

Use XCTest throughout GitX. Do not add Swift Testing, Quick, Nimble, or a snapshot-testing library.

Prefer new Swift XCTest because a test written against the Objective-C compatibility surface can remain unchanged after the implementation moves to Swift. A Swift test also exposes nullability, generics, selector, and generated-interface problems before conversion.

Keep or add Objective-C XCTest when the subject uses Objective-C exception behavior, macros, non-bridging C declarations, or a private test category that should not become production API. Existing Objective-C test files are migration debt, not an invitation for incidental rewrites.

Use `@testable import GitX` for internal Swift behavior when the test target supports it. Import Objective-C through the app module or the narrowest necessary test bridging header. Do not broaden a production header or bridging header solely to reach private implementation details.

## Test-layer selection

| Behavior | First choice | Escalate when |
| --- | --- | --- |
| Parsing, filtering, formatting, eligibility, state transition, retry policy | Swift XCTest against a value type, presenter, or use-case object | The behavior genuinely depends on AppKit or ObjectiveGit identity |
| Git command, repository, filesystem, defaults, notification, or ObjectiveGit integration | App-hosted XCTest with an isolated local fixture | Multiple app components or a launched process must cooperate |
| View/controller wiring, delegate/data source, responder chain, binding, action routing | Focused app-hosted XCTest on the main actor/thread | Only a launched application exposes the behavior reliably |
| Critical workflow spanning windows or components | XCUITest using accessibility identifiers | Never escalate solely to assert pixels |
| CPU, memory, or latency characteristic | XCTest performance test in the performance plan | Do not place timing assertions in correctness tests |
| Memory safety or concurrency | Correctness XCTest under the matching sanitizer plan | Use specialized tools only when the failure requires them |

Keep the lowest layer that proves the contract. A controller unit test is not automatically better than a small XCUITest if the contract is responder-chain or accessibility behavior, and an XCUITest is not a substitute for deterministic decision tests.

## Seams for controllers and AppKit

Keep views and controllers responsible for outlets, actions, bindings, accessibility, responder-chain behavior, delegation, and rendering. Move a state transformation, parser, filter, menu rule, push-control state, or retry policy into a value type, presenter, or use-case object when one focused extraction is low churn.

Use initializer injection for required collaborators and property injection only where AppKit or nib construction requires it. Introduce protocols at I/O, time, persistence, process, or UI boundaries; do not create a protocol for every concrete value.

Avoid mocking `NSWindowController`, `NSViewController`, `NSTableView`, or `NSOutlineView` wholesale. Test an extracted decision directly, or instantiate the narrow real AppKit object in the app-hosted target and assert its observable state. Keep AppKit work on the main actor/thread and let XCTest expectations wait for asynchronous delivery.

GitX is not an `NSDocument` application. Do not import generic `NSDocument` serialization or autosave recommendations into its test strategy.

## Fixtures and test doubles

Prefer a real temporary Git repository over a large mock of Git behavior. Initialize it deterministically, configure a local identity, create only the commits and refs the test needs, avoid network access, and remove it during teardown. Give each test independent paths and defaults so parallel execution can become safe.

Use fakes for narrow collaborators such as clocks, defaults stores, process runners, filesystem boundaries, or callback services. Record only interactions that are part of the observable contract; do not couple tests to incidental call counts.

Cover at least:

- representative normal behavior;
- failure propagation and recovery;
- empty, nil/optional, missing, malformed, and out-of-range inputs that the API admits;
- ordering and identity where Git semantics depend on them;
- Unicode and path behavior where strings cross filesystem or Git boundaries;
- callback queue, cancellation, or repeated-delivery behavior when asynchronous;
- a regression example for each fixed bug.

## UI automation and screenshots

Use stable accessibility identifiers and query by control type. Launch with isolated repositories, preferences, locale, and other state. Wait with `waitForExistence`, predicates, or expectations tied to visible state. Never use a fixed sleep to make a race less visible.

Keep XCUITest focused on critical journeys and contracts that require a launched app. Assert meaningful state before taking a screenshot. For a new feature or visible UI change, add or refresh a named screenshot attachment that helps a human diagnose the result. Keep attachments as artifacts only; do not compare them to golden pixels.

## Performance and sanitizer design

Put stable benchmarks in the shared performance plan. Construct fixtures and warm caches outside the measured block. Measure deterministic CPU or memory work, not network access, arbitrary delays, UI animation, or tool installation. Establish or change a performance baseline only after repeated runs on the same runner class show stable variance.

Run Address/Undefined Behavior Sanitizers for pointer arithmetic, C and Core Foundation boundaries, manual buffers, ownership, or unsafe-memory work. Run Thread Sanitizer for queues, callbacks, tasks, notifications, mutable singletons, or shared state. Sanitizer findings have no accepted warning budget.

## Migration durability

Before Objective-C-to-Swift conversion, test the behavioral contract through the narrowest stable interface. Prefer tests that can run unchanged against both implementations. Explicitly exercise bridging-sensitive behavior: nullability, collection element types, `NSNumber` and `Any`, selectors and runtime names, equality/hash semantics, signedness and sentinel values, error mapping, ownership, and archive compatibility when relevant.

Do not let 90% line coverage hide an untested contract. Require normal, failure, and boundary behavior explicitly, then use the percentage as evidence that the characterization is broad enough for conversion.
