# Large Class Decomposition Plan

## Confirmed decisions

- Deliver the work as one ready pull request on the `hbmartin` fork.
- Keep the existing app and test targets; do not create a module or target in this change.
- Extract cohesive Swift seams while retaining the Objective-C Cocoa-facing classes.
- Judge the result by responsibility and dependency direction, not a numeric line limit.
- Preserve observable behavior during extraction. If characterization exposes a defect, prove it with a failing expectation and fix it in a separate green commit.

## Order

1. `PBGitIndex`
2. `PBNativeContentView`
3. `PBGitCommitController`

`PBGitIndex` goes first because it has the strongest coverage floor of the three and owns behavior consumed by the commit and history surfaces. `PBNativeContentView` follows as an independent rendering subsystem whose parsing and presentation seams can be stabilized before the composition layer changes. `PBGitCommitController` goes last because it has the weakest coverage and the largest Cocoa compatibility surface: a XIB owner, bindings, outlets, actions, responder-chain behavior, table delegates, pasteboard behavior, and notifications.

The order is about risk containment, not priority. Every intermediate commit must build and pass its focused tests.

## Cross-cutting constraints

- Preserve the public declarations, Objective-C runtime class names, selectors, notification names, KVO keys, delegate callbacks, and dictionary keys used by current callers.
- Keep `PBGitIndex`, `PBNativeContentView`, and `PBGitCommitController` as Objective-C facades in this change. Do not attempt whole-class Swift replacements.
- Do not replace GCD with actors or `async`/`await`; preserve callback queues, ordering, replay, and cancellation semantics.
- Instantiate new collaborators inside the existing facades. Add injection only at command, filesystem, image-data, or other I/O boundaries needed for deterministic tests; do not introduce application-wide dependency injection.
- Keep AppKit hierarchy construction, outlets, bindings, actions, accessibility, responder behavior, and rendering installation in the view/controller layer.
- Add logging at collaborator boundaries and state transitions without logging commit messages, file contents, patches, credentials, or other repository data.
- Add Swift sources deliberately to the existing `GitX` target and Swift XCTest to the existing `GitXTests` target. Do not alter `External/`.

## Coverage-led commit structure

Each Objective-C implementation must reach at least 90% line coverage, with explicit normal, failure, and boundary XCTest, before moving its behavior into Swift. The checked-in floors are starting evidence rather than current measurements:

| Implementation | Checked-in floor |
| --- | ---: |
| `Classes/git/PBGitIndex.m` | 81.95% |
| `Classes/Views/PBNativeContentView.m` | 64.54% |
| `Classes/Controllers/PBGitCommitController.m` | 16.55% |

For each class:

1. Produce a fresh `GitX` correctness result bundle with coverage and record the actual file coverage.
2. Add passing characterization tests against the Objective-C implementation until the conversion gate is met. Commit those tests before production extraction.
3. Modernize the affected header in the preparation commit. `PBGitCommitController.h` must gain audited nullability and leave `scripts/header-interop-baseline.json`; the other two headers already have nullability regions but still require an annotation audit.
4. Extract one cohesive seam per production commit, keeping focused tests green after each seam.
5. Run the plain coverage checker, record genuine improvements, inspect the baseline diff, and run the plain checker again. Add every new Swift source to `scripts/coverage-baseline.json` at its measured floor; never lower an existing floor.
6. Keep any defect fix separate from the behavior-preserving extraction: first demonstrate the failure locally, then commit the expectation and fix together.

## 1. Decompose `PBGitIndex`

### Resulting ownership

`PBGitIndex` remains the public facade and owns:

- the repository association;
- `PBChangedFile` identity and mutable instances required by Cocoa bindings;
- KVO publication of `indexChanges`;
- existing notifications and their main-thread delivery contracts;
- amend state and compatibility with current callers.

Extract these Swift collaborators in the existing app target:

- `IndexStatusParser`: decode NUL-delimited Git output into typed immutable entries. It owns UTF-8 validation, empty input, status fields, path preservation, and malformed-record failure.
- `IndexSnapshotReducer`: combine staged, unstaged, and untracked entries into one coherent value snapshot. Staged metadata retains precedence for partially staged files. The facade reconciles the value snapshot back into existing `PBChangedFile` identities and publishes one KVO update.
- `IndexRefreshCoordinator`: launch the three existing refresh commands, retain the serial GCD ownership model, coalesce overlapping requests into one trailing replay, and deliver a complete result to the facade. It does not post UI notifications directly.
- `IndexMutationService`: build and execute stage, unstage, discard, patch, and diff operations. It returns typed success/failure results; the facade applies compatible model changes and posts legacy notifications.
- `IndexCommitService`: run prepare-commit-message and commit orchestration, including hooks, parent selection, amend author preservation, signing, `commit-tree`, and `update-ref`. It emits typed progress and terminal outcomes that the facade translates to current notifications.

Introduce one app-internal `IndexCommandRunning` protocol for synchronous output/launch with optional standard input and asynchronous data completion. Its production adapter delegates to the existing `PBGitRepository`/`PBTask` paths; tests use deterministic fakes. `IndexRefreshCoordinator`, `IndexMutationService`, and `IndexCommitService` use that boundary plus immutable request/result values. They must not receive `NSNotificationCenter`, `NSArrayController`, or UI objects.

### Characterization and focused tests

- Parsing: nil/empty data, invalid UTF-8, NUL termination, Unicode and spaced paths, malformed or odd records, additions, modifications, and deletions.
- Snapshot reduction: staged-only, unstaged-only, untracked, deleted, partially staged, partially staged addition, stale entry removal, staged metadata precedence, and stable `PBChangedFile` identity.
- Refresh coordination: bare repositories, success, each command failure, coherent single publication, overlapping requests, one trailing replay, main-thread completion, and stat-cache refresh.
- Mutations: empty input and 1/1000/1001-file chunk boundaries, Unicode paths, stage and unstage failures, discard of tracked versus untracked files, patch newline normalization, forward/reverse application, and staged/unstaged/untracked diff selection.
- Commit pipeline: unborn repository, ordinary and merge-parent commits, amend author/parents/message, configuration failure, pre-commit/commit-msg/post-commit behavior, hook output, signing failure, tree failure, commit-object failure, ref-update failure, temporary message cleanup, and notification payload compatibility.

Add a deterministic performance test for parsing and reducing a large index snapshot. Keep fixture construction outside the measured block.

## 2. Decompose `PBNativeContentView`

### Resulting ownership

`PBNativeContentView` remains the AppKit facade and owns:

- the view, stack, scroll view, text view, accessory view, and constraints;
- render-generation cancellation and main-thread installation into text storage;
- collapsed-file and expanded-image interaction state;
- link clicks, delegate routing, scrolling, and accessibility behavior;
- the existing dictionary-based section and image-source compatibility API.

Extract these Swift collaborators in the existing app target:

- `NativeContentSection`: an immutable typed snapshot adapted from the current dictionary keys at the facade boundary. Missing optional values keep their current fallbacks.
- `DiffDocumentParser`: normalize quoted paths, resolve copy/rename/header paths, split files and hunks, identify line blocks, and retain UTF-16-compatible ranges where attributed strings depend on `NSString` indexing.
- `PartialPatchBuilder`: construct hunk, block, and line patches for stage, unstage, and discard, including reverse mode and no-newline markers.
- `NativeTextRenderer`: build source, blame, and history attributed content plus typed link actions.
- `NativeDiffRenderer`: build diff attributed content, syntax overlays, intra-line emphasis, action links, collapsed sections, and expanded-image placeholders/attachments. Image data comes through a narrow provider preserving the current off-main delegate callback and main-thread AppKit image construction.
- `NativeRenderResult`: return the attributed string and link-action map as one immutable result for generation-checked installation.

Do not change the visible colors, fonts, spacing, action titles, ordering, or the established Snow Leopard-inspired presentation in this refactor.

### Characterization and focused tests

- Section adaptation: missing keys, empty values, ordering, Unicode, source path fallback, blame metadata reuse, author truncation, and history links.
- Diff parsing: ordinary, new, deleted, copied, renamed, quoted, escaped, spaced, and Unicode paths; malformed headers and hunks; multiple files and sections.
- Patch building: hunk, block, and line selection in forward and reverse modes; context conversion; omitted changes; hunk counts; malformed input; adjacent changes; and no-newline marker association.
- Rendering: source, blame, history, empty diff, read-only/staged/unstaged contexts, syntax budget boundary, syntax plus diff coloring, intra-line emphasis, link payloads, and large documents.
- Interaction and concurrency: stale render generations, collapse/expand rerendering, commit and diff delegate actions, image callbacks off the main thread, image attachment construction on the main thread, accessory replacement, scrolling, and view lifetime during queued work.

Retain and run the existing large-diff performance cases. Add parser/patch tests at the pure Swift layer while preserving app-hosted tests for AppKit installation and delegate behavior.

## 3. Decompose `PBGitCommitController`

### Resulting ownership

`PBGitCommitController` remains the XIB owner and owns:

- all outlets, actions, Cocoa bindings, accessibility identifiers, and split-view restoration;
- notification registration/removal and UI application of notification outcomes;
- responder-chain, text-view, menu-delegate, table-delegate/data-source, drag/drop, and pasteboard wiring;
- calls into `PBGitIndex`, window dialogs, workspace actions, and push routing.

Extract these Swift collaborators in the existing app target:

- `CommitRemotePresentationPolicy`: sort remotes and choose the previous, tracking, `origin`, or first remote in the existing precedence order; return enabled state and selection without touching controls.
- `CommitSubmissionPolicy`: decide merge rejection, staged-change eligibility, minimum message length, and whether a pending branch/remote push can be armed. It returns a typed rejection or submission plan; the controller owns localized sheets and invokes the index.
- `CommitWorkflowState`: retain and clear pending push state across success, commit failure, and hook failure, returning the next UI/push transition without owning the window controller.
- `CommitMenuPresenter`: return title, enabled, hidden, alternate, and state values for stage, unstage, discard, trash, open, ignore, reveal, amend, and prepare-message actions. Repository/submodule lookup remains outside the presenter and is supplied as input.
- `CommitMessagePolicy`: build and deduplicate sign-off lines and decide whether an amend notification may replace current text.
- `CommitSelectionPolicy`: calculate post-stage/unstage selection safely for empty and shrinking arranged-object lists.

File opening, Finder reveal, trash, ignore, dialogs, table wiring, and pasteboard archiving remain Cocoa/I/O wiring in `PBGitCommitController` for this pull request. Do not add a file-action coordinator or a generic controller framework.

### Characterization and focused tests

- Real-XIB wiring: repeated `awakeFromNib`, bindings, filters, sort descriptors, table targets/delegates, actions, menus, accessibility identifiers, and first responder.
- Remote presentation: none, one, many, previous selection, tracking remote, `origin` fallback, detached HEAD, and remote changes while the view is open.
- Submission and workflow: merge rejection, no staged changes, short message, verified/forced commit, pending push capture, hook failure retry, commit failure reset, successful commit, post-commit-hook failure, and push routing without a second confirmation.
- Message behavior: missing identity, normal sign-off, duplicate sign-off, selection preservation, prepare-message replacement, and amend replacement thresholds.
- Menu matrix: zero/one/many files; staged versus unstaged table; new/modified/deleted and mixed selections; submodule open title; contextual versus main menu; amend state; and hook availability.
- File and table behavior: open, reveal, trash confirmation/cancel/failure, ignore success/failure, stage/unstage toggle, double-click, safe reselection with an empty list, valid/invalid drag archives, same-table rejection, and cross-table drop.
- Notification/UI transitions: refresh, index update, operation failure, commit progress/success/failure/hook failure, repository events, app activation, busy/editable state, status text, and commit-button eligibility.
- Responder behavior: tab/backtab focus with empty and populated tables.

Use Objective-C app-hosted XCTest only where private selectors, XIB wiring, or Cocoa runtime behavior should not become production API. Test every extracted policy/state type directly in Swift XCTest.

## Verification and acceptance

After each preparation and extraction commit, run the focused tests for the affected class. After the final production commit:

1. Run `scripts/verify_static.sh` against the PR base.
2. Run `scripts/run_analyzer.sh` for Objective-C, nullability, ownership, and generated-interface checks.
3. Run the shared `GitX` correctness plan with coverage into a fresh result bundle.
4. Run `scripts/check_coverage.py`, record genuine improvements with `--record-improvements`, inspect the diff, and rerun the plain checker.
5. Run `GitXUI` because the work changes a view, a XIB controller, bindings, menus, responder behavior, and critical staging/commit workflows. Refresh the staging and history diagnostic screenshot attachments; do not add pixel comparisons.
6. Run `GitXPerformance` for native diff rendering and large index parsing/reduction.
7. Run `GitXThreadSanitizer` for index refresh coordination, render queues, callbacks, notifications, and shared state.
8. Run pinned SwiftFormat and SwiftLint through `scripts/run_pinned_tool.sh`; do not substitute global versions.
9. Inspect the generated Swift/Objective-C interfaces, validate `PBGitCommitView.xib`, and smoke-test source, blame, history, diff, staging, drag/drop, commit, hook failure, amend, and commit-and-push flows.
10. Build and confirm the final Debug app at `/Volumes/ExtStor/gitx/build/GitX.app` from the final commit.

The planned seams do not alter pointer, C, Core Foundation, buffer, or unsafe-memory behavior, so `GitXAddressUndefined` is not part of the required matrix. If implementation would cross one of those boundaries, stop and obtain scope confirmation before proceeding.

Acceptance requires unchanged public compatibility, all required checks passing, at least 90% pre-extraction coverage for each Objective-C implementation, complete coverage of affected behavior after extraction, nondecreasing coverage/header/analyzer baselines, no intentional visual changes, and no new module or target.

## Future modularization thoughts

This decomposition should make a later module boundary possible without creating it prematurely. It complements [Future Work: GitXCore and Hostless Tests](future_work.md).

The best initial `GitXCore` candidates from this work are Foundation-only values and decisions:

- `IndexStatusParser` and `IndexSnapshotReducer`;
- `DiffDocumentParser` and `PartialPatchBuilder`;
- `CommitRemotePresentationPolicy`, `CommitSubmissionPolicy`, `CommitMenuPresenter`, `CommitMessagePolicy`, and `CommitSelectionPolicy`.

They should enter a future module only after their inputs and outputs no longer mention `PBChangedFile`, `PBGitRef`, AppKit types, notifications, mutable controllers, or app-target singletons. Their current app-target extraction is an incubation step: tests and callers can reveal the correct API before it becomes a cross-target contract.

These types should remain in the app layer:

- `PBGitCommitController` and `PBNativeContentView`, because they are AppKit adapters;
- attributed-string, image, control, accessibility, XIB, responder, and pasteboard code;
- `PBGitIndex`, `IndexRefreshCoordinator`, `IndexMutationService`, and `IndexCommitService` while they depend on ObjectiveGit, `PBTask`, filesystem state, hooks, notification compatibility, or repository lifetime.

A later repository-integration module could become worthwhile, but only after `GitXCore` proves the dependency direction and there is measured value from independent builds or tests. Such a module would own Git process execution, ObjectiveGit adapters, hooks, index refresh, and repository mutations while depending on `GitXCore`. It must not depend on the app or AppKit. This is not approved scope for the current work.

Do not create a separate AppKit module merely to move files. Keep UI types in the app until more than one executable genuinely reuses them or build measurements show a concrete benefit.

Before moving an incubated seam into a module, require:

- a stable Foundation-only API demonstrated by current callers;
- hostless XCTest for normal, failure, and boundary behavior;
- no Objective-C runtime, AppKit, ObjectiveGit, task, notification, or singleton dependency;
- an acyclic dependency direction from app/integration code toward the core;
- separate nondecreasing coverage for the hostless target;
- a measured build-time, test-time, reuse, or ownership benefit that justifies the target boundary.

The likely long-term direction is:

```text
GitX.app (AppKit, XIBs, Objective-C compatibility)
    -> repository integration (ObjectiveGit, Git processes, filesystem, hooks)
        -> GitXCore (Foundation values, parsing, reducers, policies)
```

Only `GitXCore` is an established future proposal. The repository-integration layer remains a hypothesis to validate after the current in-target decomposition and the first core extraction.
