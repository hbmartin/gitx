# Separate Test Plans and Execution Policy

## Principle

Prefer explicit `.xctestplan` files and explicit CI commands over one implicit “run everything” configuration. Each plan should answer four questions in version control: which tests run, what environment they receive, which diagnostics are enabled, and when the plan is required.

Plans are execution policy, not merely Xcode UI state. Changes to a plan should receive the same review as changes to workflow YAML.

## Planned Suite Boundaries

| Plan | Contents | Coverage | Frequency | Failure policy |
| --- | --- | --- | --- | --- |
| `GitX` | Fast app-hosted unit and integration XCTest; excludes performance classes | On | Every push and pull request | Required |
| `GitXCore` | Future hostless Foundation-only XCTest | On, reported separately | Every push and pull request | Required |
| `GitXUI` | Accessibility-driven XCUITest workflows | Off | Dedicated UI-capable runner or explicit invocation | Required where runner support exists |
| `GitXPerformance` | Stable XCTest performance benchmarks only | Off | Scheduled and manual | Detect/report regressions; do not mix with correctness timing |
| `GitXAddressUndefined` | Unit/integration tests with Address and Undefined Behavior Sanitizers | Off | Scheduled and manual | Required on scheduled hardening run |
| `GitXThreadSanitizer` | Unit/integration tests with Thread Sanitizer | Off | Scheduled and manual | Required on scheduled hardening run |

Address Sanitizer and Thread Sanitizer remain separate because their instrumentation is incompatible. UI and performance tests stay out of sanitizer plans unless a specific investigation warrants the cost.

## Execution Policies

### Correctness tests

- Use XCTest throughout the repository.
- Enable code coverage only for correctness plans.
- Run independent tests in parallel and randomized order when the target is proven safe.
- Keep integration tests explicit by class or target so they can be split later without renaming test methods.
- Never make performance assertions inside a correctness test.
- Save the `.xcresult` bundle on failure and enforce the checked-in coverage floors from that bundle.

### UI tests

- Launch with a deterministic locale, language, persistence state, and animation policy.
- Query controls by accessibility identifier and type.
- Wait on observable predicates or `waitForExistence`; fixed sleeps are prohibited.
- Keep test-owned repositories and defaults isolated per test.
- Retain screenshots as diagnostic attachments only. Do not add pixel or screenshot comparison testing.
- Run separately from the default plan so UI runner permissions cannot block unit feedback.

### Performance tests

- Use XCTest `measureBlock:`/metrics and prebuild fixtures outside the measured block.
- Measure deterministic CPU/memory work, not network access, UI animation, arbitrary sleep, or first-time tool installation.
- Keep a small representative dataset checked in or construct it deterministically.
- Run a warm-up when first-use caches would otherwise dominate the signal.
- Store the result bundle as a scheduled-run artifact. Establish baselines only after enough runs on the same runner class to understand variance.
- Treat large sustained regressions as actionable; do not tune thresholds from a single noisy run.

### Sanitizer tests

- Use the same correctness tests under separate plan configurations.
- Upload result bundles even when `xcodebuild` fails.
- Do not weaken sanitizer settings to preserve a warning or finding baseline; sanitizer findings have a zero budget.

## Local Commands

The canonical forms are:

```sh
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitX -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXUI -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXPerformance -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXAddressUndefined -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXThreadSanitizer -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
```

Use a unique `-resultBundlePath` in CI. Do not rely on whichever plan is currently selected in a developer's scheme editor.

## Change Policy

- Adding a test class requires assigning it to the appropriate explicit plan.
- Moving a test between plans requires a short rationale in the change description.
- Lowering coverage or weakening a diagnostic requires explicit user approval and a documented time-bounded exception.
- Removing a warning, header-debt entry, or coverage gap must ratchet its checked-in baseline in the same change.
- New plans must be shared in `GitX.xcscheme`, validated as JSON, invoked explicitly in CI or documented as local-only, and added to this matrix.
- CI must pin Xcode and all externally installed analysis/format tools.

## Future Split

When `GitXCoreTests` exists, split CI into a fast hostless job and an app-hosted integration job. Build-for-testing/test-without-building may then be introduced if measurements show a real improvement. The first priority is clear ownership and reproducibility, not maximizing the number of jobs.
