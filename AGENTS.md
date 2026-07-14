- The overall aesthetic of the app should be inspired by Mac OS X 10.6 Snow Leopard

### Commit and PR rules
- Never open a PR against the upstream, PR's are always on the hbmartin fork
- When committing, if you made a plan, use that plan as the basis for your commit message (unless it is a test only commit).
- Always open a ready PR (never draft)

### Convert Objective-C files you edit to Swift
- Convert automatically whenever it is low risk and low churn to convert
- Ask about converting whenever it is medium risk or medium churn
- Use the repo-local `$convert-objective-c-to-swift` skill for explicit conversions and whenever substantively editing first-party Objective-C; follow its exclusions, preparation commit, compatibility, and verification workflow.
- Consider how to improve the app structure when working, ask the user when you identify refactoring opportunities for big picture improvements.

### Testing
- Use the repo-local `$gitx-testing` skill whenever changing GitX behavior, fixing a bug, adding or reviewing tests, diagnosing test, coverage, analyzer, sanitizer, or performance failures, changing verification CI or shared test plans, or preparing an Objective-C-to-Swift conversion.
- Track test coverage and ensure it remains high
- If asked to change behavior that lacks meaningful coverage, first add and commit passing characterization tests for the current behavior. Then confirm the new or regression expectation fails locally, implement until it passes, and commit the expectation with the implementation. Never commit an intentionally failing test.
- After committing a feature, run the test suite and ensure all tests pass, and that test coverage has increased.
- Enforce coverage with `scripts/check_coverage.py <result.xcresult>` and the checked-in `scripts/coverage-baseline.json`; after an increase, use `--record-improvements` to raise floors, which must never be lowered without explicit approval.
- Before converting an Objective-C implementation to Swift, require at least 90% line coverage for that implementation and explicit XCTest coverage of normal behavior, failures, and boundary cases. For ordinary feature work, cover the affected behavior completely and ratchet the baseline without requiring unrelated legacy files to reach 90%.
- Keep correctness, UI, performance, and sanitizer execution in explicit shared test plans. XCTest remains the repository's test framework.
- Write new tests in Swift with XCTest when the production API bridges cleanly. Keep Objective-C XCTest for Objective-C exceptions, non-bridging C or macro surfaces, private declarations that should not become production API, or cases where Swift interoperability would create disproportionate churn. Do not convert an existing Objective-C test file merely because it is touched.
- Prefer decision-level XCTest, then focused app-hosted AppKit XCTest, then XCUITest for critical cross-component workflows. UI tests must wait for observable state rather than fixed sleeps.
- New features and visible UI changes require current diagnostic screenshot attachments. Screenshots are diagnostic only; do not add screenshot or pixel comparison testing.
- Do not introduce a new testing or analysis dependency without explicit approval.

### Verification
- Add log statements (more is better) so you can easily inspect real app runtime behavior.
- Run SwiftLint and SwiftFormat at the exact versions in `Mintfile` through `scripts/run_pinned_tool.sh`.
- Treat the Objective-C header baseline, SwiftLint baseline, and exact analyzer-warning baseline as shrinking debt: remove stale entries in the same change that fixes them.
- Treat the current files under `scripts/`, `Mintfile`, and applicable repo-local skills as canonical for verification policy. Ignore planning documents under `docs/` unless the user explicitly asks to use them.
- After tests and verification pass, refresh the final Debug app at `/Volumes/ExtStor/gitx/build/GitX.app` and report that path.

### Controllers
- When changing a controller, extract the affected decision logic into a value type, presenter, or use-case object if that can be done with low churn.
- Views and controllers should retain wiring, responder-chain behavior, accessibility, bindings, and rendering.
- State transformations, parsing, filtering, menu eligibility, push-control state, and retry policies should move out.
- Make small behavior-preserving seam extractions automatically when they are low risk, low churn, and directly support the requested change. Ask before creating a new module or target, redesigning several controllers, introducing application-wide dependency injection, replacing Cocoa Bindings or responder-chain behavior, or otherwise expanding into a broad refactor.

### Headers
- Every added or substantively modified first-party header must have NS_ASSUME_NONNULL_BEGIN/END.
- Any collection declarations touched in that header should gain lightweight generics where the element type is known.
- Explicitly annotate nullable error outputs, delegates, outlets, and optional return values.
- Maintain a checked-in debt allowlist or baseline rather than only a hard-coded count.
- Ratchet the baseline downward whenever a header is modernized.
