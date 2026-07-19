---
name: convert-objective-c-to-swift
description: Safely convert or incrementally extract first-party gitx production Objective-C into Swift while preserving observable behavior and Objective-C interoperability. Use whenever Codex explicitly converts Objective-C, assesses a conversion candidate, or substantively edits a first-party production .m or .h file and a low-risk, low-churn Swift migration is feasible. Support compatibility shims, header modernization, Swift characterization tests, controller logic extraction, and conversion verification. Exclude tests, External dependencies, Objective-C++, generated scripting bridges, process entry points, NSInvocation or message-forwarding code, Objective-C exception-handling code, and archive-sensitive code without frozen fixtures.
---

# Convert Objective-C to Swift

Migrate gitx production code toward Swift without treating compilation as proof of equivalence. Preserve behavior, repair the compatibility surface before converting, and verify the result at the seams where Swift and Objective-C differ.

## Follow the operating contract

- Re-read the repository `AGENTS.md` and obey its testing, controller, header, commit, fork, and stable-build rules.
- Apply this workflow to first-party production code, normally under `Classes/`.
- Exclude `GitXTests/` and `GitXUITests/` from production conversion. Add new tests in Swift when the production API bridges cleanly. Preserve or add Objective-C XCTest for Objective-C exceptions, non-bridging C or macro surfaces, private declarations that should not become production API, or disproportionate Swift-interoperability churn. Never convert an existing test merely because it is touched.
- Exclude `External/` and generated code.
- Announce an automatic conversion in the working plan before editing. Proceed without separate approval only when it remains low risk and low churn.
- Ask for explicit confirmation before combining a conversion with API redesign, concurrency migration, or broad refactoring. State the proposed scope, benefit, and compatibility impact. If the user declines, keep the conversion behavior-preserving.
- Ask about big-picture structural opportunities instead of silently expanding the work.
- Leave the final verified app at `/Volumes/ExtStor/gitx/build/GitX.app`.

## Execute the workflow

### 1. Inspect the candidate and repository state

1. Inspect `git status` and preserve unrelated user changes.
2. Identify the implementation, header, categories or extensions, callers, tests, Xcode target membership, bridging-header imports, nib references, and generated Swift interface.
3. Read [conversion-risks.md](references/conversion-risks.md) before performing a conversion. Use its risk-specific sections during the behavioral diff and verification.
4. Determine whether the requested edit is substantive. Do not inflate a comment-only, formatting-only, generated-file, or emergency compatibility edit into a migration.

Use `rg` and direct project inspection rather than maintaining a separate conversion inventory or risk-scoring script.

### 2. Enforce the high-risk exclusions

Do not automatically convert these categories:

- Objective-C++ (`.mm`)
- generated scripting-bridge sources or headers
- process entry points such as `main.m` and helper-tool mains
- `NSInvocation`, forwarding, or runtime message-dispatch implementations
- Objective-C `@try`, `@catch`, `@finally`, or `@throw` implementations
- archive-sensitive implementations that lack a frozen compatibility fixture

Keep excluded code in Objective-C and complete the requested change there when possible. If the user explicitly requests conversion anyway, explain the specific hazard and require a separate decision before proceeding.

Treat KVO/KVC, bindings, atomics, associated objects, Core Foundation ownership, C callbacks, controllers, nib-connected types, and Objective-C callers as review triggers rather than automatic exclusions. Fix their compatibility requirements, select focused verification, and proceed when the remaining work is controlled.

### 3. Lock in behavior and modernize the header

Check whether existing tests actually execute the behavior being moved; do not infer coverage from a nearby test name or a target-wide percentage.

When coverage is missing:

1. Add characterization tests to a new or existing Swift test source when the production API bridges cleanly. Use Objective-C XCTest for Objective-C exceptions, non-bridging C or macro surfaces, private declarations that should not become production API, or disproportionate Swift-interoperability churn. Do not convert existing Objective-C test sources merely because they are touched.
2. Exercise current Objective-C behavior, including relevant nil, empty, Unicode, numeric-boundary, wrong-type dynamic input, error, ordering, ownership, and serialization cases.
3. Add frozen archives or serialized fixtures before touching archive-sensitive code. Without a fixture, exclude that implementation from conversion.
4. Modernize the affected first-party header in the same preparation change:
   - add `NS_ASSUME_NONNULL_BEGIN` and `NS_ASSUME_NONNULL_END`;
   - add lightweight collection generics when element types are known;
   - annotate nullable errors, delegates, outlets, parameters, and returns explicitly;
   - verify that annotations match implementation behavior rather than expressing aspirations;
   - update or establish `scripts/header-interop-baseline.json` and ratchet it downward by removing the modernized header.
5. Build and run the new tests against the Objective-C implementation.
6. Commit the passing characterization tests and header modernization together as the preparation commit. Stage only conversion-scoped files and base the message on the working plan.

Do not skip header modernization merely because a later full replacement may delete that header. The separate preparation commit records and tests the Objective-C contract that Swift is replacing. If the candidate has no first-party header, record that this step is not applicable.

When focused coverage already exists, reuse it. Still modernize a substantively touched header before relying on its Swift import, and keep that preparation separate from the conversion when it materially changes the imported interface.

For the first Swift test in `GitXTests`, add it to the test target, configure the target for Swift if needed, use `@testable import GitX`, and prove the test discovers and executes before continuing.

### 4. Repair the compatibility surface

Before conversion, locate and account for:

- Objective-C callers and imports
- selectors written as strings, `performSelector`, runtime lookup, or notifications
- KVC/KVO keys, Cocoa bindings, and `dynamic` dispatch
- nib or XIB custom classes, outlets, and actions
- Objective-C runtime class names and generated `GitX-Swift.h` exposure
- delegates, optional protocol requirements, and responder-chain methods
- scripting and pasteboard contracts
- serialization names and formats
- source membership and duplicate-symbol risks

Fix compatibility gaps before moving the implementation. Preserve runtime names with explicit `@objc(...)`, inherit from `NSObject` when required, use `@objc dynamic` only where runtime dispatch is required, and retain Objective-C-compatible headers or thin shims when callers still need them.

Keep `Classes/GitX-Bridging-Header.h` narrow. Import a header only when Swift genuinely consumes it; do not bulk-import first-party or external headers.

Compatibility shims are allowed, but remove Objective-C facades and shims wherever migrating their callers would not cause significant churn. Retain an Objective-C-facing declaration only when it protects a required runtime or interoperability contract or avoids significant caller churn.

### 5. Choose the smallest coherent migration

Prefer incremental extraction while it is the lower-churn option:

- Move parsing, filtering, state transformation, menu eligibility, push-control state, retry policy, formatting decisions, or other decision logic into a Swift value type, presenter, or use-case object.
- Leave controllers and views responsible for wiring, responder-chain behavior, accessibility, bindings, outlets, actions, and rendering.
- Prefer migrating localized callers and deleting the Objective-C facade or category when doing so does not cause significant churn.
- Keep an Objective-C facade or category when removing it would cause significant churn or break a required runtime or interoperability contract.

Use full replacement when the compatibility audit has been completed and necessary fixes are in place. A compatibility shim may remain only for a documented compatibility need or to avoid significant churn. Remove the `.m` implementation from the target only after confirming that Swift owns every replaced symbol and no duplicate implementation remains.

Do not make “no Objective-C callers” or “no shim” prerequisites. Migrate callers or provide compatibility as part of the conversion.

### 6. Implement and manually diff behavior

Translate intent rather than syntax. Compare the Objective-C implementation beside the Swift implementation line by line and account for:

- nullability and implicitly unwrapped imports
- block versus closure capture and retain cycles
- ARC lifetime and Core Foundation ownership
- `NSString`, collection, `NSNumber`, and `Any` bridging
- value versus reference semantics
- KVC/KVO, bindings, selectors, and dynamic dispatch
- atomic-property and queue assumptions
- numeric overflow, signedness, `NSNotFound`, and option sets
- error versus exception behavior
- initializer availability and failure
- `NSObject` equality and hashing
- enum evolution and `@unknown default`
- archive compatibility and runtime names

Use the detailed checks in [conversion-risks.md](references/conversion-risks.md). Inspect the compiler-generated Swift and Objective-C interfaces when import or export behavior matters; do not guess from source spelling.

Update `GitX.xcodeproj/project.pbxproj` deliberately. Add Swift sources to the correct target, remove fully replaced implementations from Sources, preserve needed headers, and avoid unrelated project-file normalization.

### 7. Verify in proportion to risk

Always:

1. Run focused tests while iterating.
2. Run `scripts/verify_static.sh` against the appropriate base.
3. Run the full `GitXTests` suite with code coverage enabled.
4. Run `scripts/check_coverage.py` on the result bundle and compare affected-file coverage before and after conversion.
5. Update `scripts/coverage-baseline.json` when a covered implementation changes from `.m` to `.swift`, preserving or raising the previous floor. Use the checker’s `--record-improvements` mode to ratchet measured floors upward when coverage increases, then review the resulting baseline diff.
6. Build the Debug app with the repository workspace and scheme, setting the final configuration output so the verified app exists at `/Volumes/ExtStor/gitx/build/GitX.app`.
7. Confirm the app bundle exists and is the product of the final commit.

Run additional checks when the conversion introduces the matching risk:

- ASan/UBSan for pointer, C, Core Foundation, or ownership work
- TSan for atomic, queue, callback-ordering, or concurrency-sensitive work
- launch and affected-flow smoke testing for UI, controller, binding, responder-chain, or nib work
- Memory Graph, Instruments, zombies, or `deinit` observation for lifetime or retain-cycle risk
- frozen-fixture decode and round-trip checks for serialization work

Use compiler warnings and static analysis as supporting evidence, not as substitutes for behavioral verification.

### 8. Commit and re-verify

1. Commit the conversion separately from its preparation commit. Stage only conversion-scoped files and use the working plan as the basis for the commit message.
2. After the feature commit, rerun the full test suite, coverage gate, static checks, final stable build, and any selected risk-specific checks.
3. If post-commit verification fails, fix the failure within the conversion scope, update the commit appropriately, and rerun every failed or invalidated check.
4. Do not open a pull request against upstream. Follow the repository instruction to use only the hbmartin fork when publication is explicitly requested.

## Report the result

Summarize:

- whether the migration was incremental or a full replacement;
- which Objective-C surfaces or compatibility shims remain and why;
- the characterization and compatibility work completed before conversion;
- tests, static checks, coverage changes, sanitizer/runtime checks, and UI smoke checks run;
- the stable app path;
- any excluded high-risk code or user-confirmed redesign/refactoring;
- any broader structural opportunity that still needs a user decision.
