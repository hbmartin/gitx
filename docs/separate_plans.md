# Separate Test Plans and Execution Policy

## Principle

Prefer explicit execution policy over one implicit “run everything” configuration. App-hosted and UI suites use `.xctestplan` files; the local `GitXCore` package uses its canonical SwiftPM command so it remains independent of the application workspace.

Plans are execution policy, not merely Xcode UI state. Changes to a plan should receive the same review as changes to workflow YAML.

## Planned Suite Boundaries

| Plan | Contents | Coverage | Frequency | Failure policy |
| --- | --- | --- | --- | --- |
| `GitX` | Fast app-hosted unit and integration XCTest; excludes performance classes | On | Every push and pull request | Required |
| `GitXCore` SwiftPM job | Hostless Foundation-only XCTest | On, reported separately | Every push and pull request | Required |
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
swift test --package-path GitXCore --enable-code-coverage
python3 scripts/check_core_coverage.py "$(swift test --package-path GitXCore --show-codecov-path)"
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitX -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXUI -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXPerformance -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXAddressUndefined -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
xcodebuild test -workspace GitX.xcworkspace -scheme GitX -testPlan GitXThreadSanitizer -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=-
```

Use a unique `-resultBundlePath` in CI. Do not rely on whichever plan is currently selected in a developer's scheme editor.

## Change Policy

- Adding an app test class requires assigning it to the appropriate explicit plan. Package tests belong to the `GitXCoreTests` SwiftPM target.
- Moving a test between plans requires a short rationale in the change description.
- Lowering coverage or weakening a diagnostic requires explicit user approval and a documented time-bounded exception.
- Removing a warning, header-debt entry, or coverage gap must ratchet its checked-in baseline in the same change.
- New Xcode plans must be shared in `GitX.xcscheme`, validated as JSON, invoked explicitly in CI or documented as local-only, and added to this matrix.
- CI must pin Xcode and all externally installed analysis/format tools.

## Build Reuse

The hostless core job and app-hosted integration job are intentionally separate. Build-for-testing/test-without-building may be introduced later only if repeated measurements show a real improvement. Clear ownership and reproducibility remain more important than maximizing job count.
