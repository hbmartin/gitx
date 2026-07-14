- Convert Objective-C files you edit to Swift whenever it is low risk and low churn to do so.
- Never open a PR against the upstream, PR's are always on the hbmartin fork
- Leave the final built App at a stable path that the user can consistently open
- The overall aesthetic of the app should be inspired by Mac OS X 10.6 Snow Leopard
- Consider how to improve the app structure when working, ask the user when you identify refactoring opportunities for big picture improvements.
- When committing, if you made a plan, use that plan as the basis for your commit message (unless it is a test only commit).

### Testing
- Track test coverage and ensure it remains high
- If asked to make changes in areas that are not covered by tests, write tests first, commit, and then make the changes.
- After committing a feature, run the test suite and ensure all tests pass, and that test coverage has increased.

### Controllers
- When changing a controller, extract the affected decision logic into a value type, presenter, or use-case object if that can be done with low churn.
- Views and controllers should retain wiring, responder-chain behavior, accessibility, bindings, and rendering.
- State transformations, parsing, filtering, menu eligibility, push-control state, and retry policies should move out.

### Headers
- Every added or substantively modified first-party header must have NS_ASSUME_NONNULL_BEGIN/END.
- Any collection declarations touched in that header should gain lightweight generics where the element type is known.
- Explicitly annotate nullable error outputs, delegates, outlets, and optional return values.
- Maintain a checked-in debt allowlist or baseline rather than only a hard-coded count.
- Ratchet the baseline downward whenever a header is modernized.
