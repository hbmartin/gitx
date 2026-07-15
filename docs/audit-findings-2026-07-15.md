# Audit findings review — 2026-07-15

## Scope and method

This review treats the supplied audit as a set of hypotheses, not as established facts. Each item was checked against the current source on `codex/audit-report-fixes`, focused XCTest coverage, relevant framework behavior, and the built GitX app. The final verification section records the automated and hands-on results.

The verdicts mean:

- **Should be fixed** — the current code has a reproducible defect, an unsafe concurrency/lifecycle contract, or inexpensive defensive hardening with a concrete failure mode.
- **Reject** — the report is outdated, the claimed failure does not follow from the current code, or the proposed change would make failure handling less correct.
- **Requires user feature input** — the report identifies a real tradeoff, but changing it would select product semantics, architecture, or release policy rather than repair an unambiguous defect.

## Verdicts

### Concurrency and task lifecycle

| Finding | Verdict | Evidence and disposition |
| --- | --- | --- |
| FSEvents performs libgit2 status operations on its delivery queue using the repository's shared `GTRepository` | **Should be fixed** | Confirmed. `git_status_should_ignore` and `git_status_file` execute on the watcher's private background queue against the same repository handle used by other app work. The watcher now owns a separate `GTRepository` handle for its queue; the FSEvents queue never dereferences the shared handle. |
| `PBWebHistoryController` reads commit fields on `renderQueue` | **Should be fixed** | The report's specific `git_commit_summary` cache description is partly outdated, but the controller still reads shared `PBGitCommit`/`GTCommit` objects off-main. Render input is now captured as immutable plain values before dispatch. |
| `PBTask` waits for both process exit and pipe EOF | **Should be fixed** | Reproduced with a shell parent that exits while a descendant retains the inherited pipe. A successful parent could previously time out. `PBTask` now allows a bounded 100 ms post-exit drain, then finishes with the parent's real status and buffered output. Regression tests cover successful and failing parents. |
| FSEvents callback can outlive the watcher because its context is unretained | **Should be fixed** | The old raw `__bridge` context did not establish a lifetime contract with asynchronous delivery. The stream now retains a callback context containing a weak watcher; each callback takes a strong local reference before using it. |
| `PBTask launchTask:` waits forever when `timeout <= 0` | **Reject** | This is an explicit public API contract: a non-positive timeout disables the timeout. Production call sites that need a cap provide one. Silently restoring an undocumented hard cap would break callers. |
| `PBTask` uses two synchronization mechanisms and can read output while closing its file handle | **Should be fixed** | The broad “two locks” claim overstates the issue, but the read/forced-close race was real. Output-reader stop, in-flight reads, and deferred close are now coordinated so the handle is not closed under `availableData`. |
| Every repository observes global defaults changes and churns the watcher | **Reject** | The notification is global, but the watcher start/stop paths are idempotent. Unrelated defaults changes cause small preference checks, not stream recreation or correctness loss. |
| `PBGitWindowController` lacks a `dealloc` observer cleanup fallback | **Reject** | The nib wires `windowWillClose:`, callbacks are generation-guarded, and modern notification observers are zeroing. No current use-after-free path was found. Adding a fallback could be harmless, but the report does not establish a defect. |

### Native rendering and history UI

| Finding | Verdict | Evidence and disposition |
| --- | --- | --- |
| The entire diff/blame is one non-wrapping `NSTextView`, with no virtualization | **Requires user feature input** | Architecturally true, but not an unambiguous fix. Prior measurements show the current lightweight large-diff path is fast at its tested size, while non-contiguous TextKit layout was slower. Virtualization would change selection, links, accessibility, and chunk staging and needs an agreed size threshold and UX. |
| Images and attachments are constructed off-main while `renderedCommits` is read unsafely | **Should be fixed** | Confirmed as an AppKit/state-ownership issue, not a libgit2 issue. Image source values are captured on main, subprocess data loading remains in the background, and `NSImage`/attachment construction returns to main. |
| Working State is recreated and reselected on every index update | **Should be fixed** | Confirmed. Object identity changes force content replacement, flashing, and lost viewport/selection. The model is kept stable and equal rendered content no longer replaces the text storage. |
| Dynamic/already-formatted values are passed to `NSLocalizedString` | **Should be fixed** | Confirmed by `genstrings` diagnostics for commit IDs and generated collapse titles. Only literal source strings are localized; already formatted display values are used directly. |
| The rewind panel's `NSBox` and backing layer both draw fill/border | **Should be fixed** | Confirmed as redundant drawing. The overlay now has one rounded layer-backed rendering path. |
| `PBCommitList.menu(for:)` assumes `cell.objectValue` is non-null | **Should be fixed** | Plausible during cell reuse or a transient reload even though normal cells are populated. A guard prevents a context menu from targeting an absent commit. |
| Space-key staging sends an action with a nil delegate | **Should be fixed** | `sendAction(to: nil)` searches the responder chain; it is not a no-op. The table now requires an explicit delegate before dispatching the staging action. |

### Git and staging semantics

| Finding | Verdict | Evidence and disposition |
| --- | --- | --- |
| A staged new file renders as raw blob content instead of an all-additions diff | **Reject** | Outdated. Current staged rendering uses `diff-index --cached`; existing coverage verifies an all-additions patch. This was fixed before this audit branch. |
| Combined Diff silently includes unselected intermediate commits | **Requires user feature input** | Current Combined mode intentionally represents the endpoint range (“oldest through newest”), so ancestry-path changes between selected endpoints are included. Sequential mode shows only selected commits. Disallowing gaps would choose different product semantics and needs confirmation. |
| A staged-then-edited new file shows the whole file as unstaged | **Reject** | Outdated. Raw-content handling is limited to a new file with no staged changes; a staged addition with later edits uses `diff-files` and shows the incremental delta. Existing regression coverage exercises this case. |
| If only the untracked-files query fails, stale untracked entries remain | **Reject** | This is deliberate last-known-good behavior. Clearing the snapshot after the query that supplies it fails would falsely claim untracked files disappeared. The refresh failure is surfaced instead. |

### Migration and dead-code claims

| Finding | Verdict | Evidence and disposition |
| --- | --- | --- |
| `NSAppearance+PBDarkMode.swift` is orphaned | **Should be fixed** | Confirmed: the Swift file was tracked but absent from the build; the Objective-C category is the active implementation and supports dark mode. The orphan and its misleading bridge comment were removed. |
| `PBWebHistoryController.currentOID` is dead | **Should be fixed** | Confirmed by repository-wide reference search; it is removed with the controller cleanup. |
| `PBChangedFile.indexInfo` and the new-file path are dead | **Should be fixed** for `indexInfo`; **reject** for removing new-file semantics | `indexInfo` had no callers and was removed. `PBChangedFileStatus.NEW` remains part of active staging/diff decisions and must stay. The touched header was modernized and removed from the nullability debt baseline. |
| `PBTask` applies `additionalEnvironment` in the initializer | **Should be fixed** | The initializer check was unreachable/misleading because callers set the property afterward. It was removed; the launch-time environment merge remains and is covered. |
| Per-operation debug logs should be removed | **Reject** | The logs are useful runtime evidence for refresh and staging failures, and repository policy explicitly asks for diagnostic logging. They are not unconditional sensitive-data dumps. |
| `PBWebChangesController` manually redeclares `PBRefreshCoalescer` | **Should be fixed** | Confirmed migration residue. The controller now imports the generated Swift interface instead. |

### Tooling, configuration, and tests

| Finding | Verdict | Evidence and disposition |
| --- | --- | --- |
| Coverage policy ignores a newly compiled first-party source file | **Should be fixed** | Confirmed with a red Python unit test. The policy now fails for missing `Classes/*` source entries, ignores external dependencies, and `--record-improvements` adds new first-party files at their measured floors. |
| Shared build settings hard-code a development team and automatic signing | **Requires user feature input** | This is release/signing ownership policy, not a runtime defect. Local verification already uses ad-hoc signing. Changing shared release signing can disrupt maintainers and distribution, so it needs an explicit desired policy. |
| `setAutoFetchScope:` accepts invalid values | **Should be fixed** | Reproduced: an invalid raw value was persisted even though the getter later masked it. A small Swift policy seam validates before storage; tests cover invalid input. |
| Repository defaults keys do not resolve symlinks | **Should be fixed** | Reproduced with real and symlinked repository URLs producing independent preferences. Keys now standardize and resolve symlinks; regression coverage verifies both URLs address the same setting. |
| The uncommitted-tree cache test compares the getter with itself and can pass for nil | **Should be fixed** | Confirmed as vacuous for nil. The test now captures the first tree, asserts non-null, and then checks identity on the second access. |
| Relative-date tests use wall-clock values near bucket boundaries | **Should be fixed** | Confirmed as avoidably fragile. Test timestamps were moved safely inside their expected buckets. |
| All application code must exceed 90% coverage as part of this repair | **Requires user feature input** | Current project-wide coverage is far below 90%; reaching that target is a broad testing program, not a safe tail on this bug-fix batch. This change completely covers new decisions and ratchets all measured floors. The 90% implementation gate remains mandatory before converting an Objective-C implementation to Swift. |

## Objective-C to Swift assessment

The conversion policy was applied to every substantively touched first-party Objective-C implementation. `PBTask` is excluded because its launch path relies on Objective-C exception handling. The watcher and rendering controllers do not meet the required 90% implementation coverage and have C callback/AppKit-nib risk, so full-file conversions would be unsafe. Low-risk decision seams were added in Swift where their APIs bridge cleanly, including persisted-default validation/canonicalization and immutable render input. No broad controller conversion was attempted.

## Verification results

The final committed production code was exercised through the repository's shared plans and through focused real-app interaction:

| Verification | Result |
| --- | --- |
| Correctness (`GitX` test plan) | **117/117 passed** at the stabilized production-code HEAD. Result: `build/AuditFinalGitX.xcresult`. |
| Coverage policy | **Passed** at 34.57% project coverage, up from the previous 34.54% floor. Relevant implementation coverage is `PBTask.m` 93.43%, `PBGitRepositoryWatcher.m` 86.31%, `PBNativeContentView.m` 63.33%, and the Swift policy/render seams 99.09%. The checked-in floors were ratcheted upward. |
| Thread Sanitizer | **117/117 passed**, with no TSan reports. Result: `build/AuditFullThreadSanitizer.xcresult`. |
| Address/Undefined Sanitizers | **117/117 passed**, with no ASan or UBSan reports. Result: `build/AuditFullAddressUndefined.xcresult`. |
| Complete UI plan | **17/17 passed**. Result: `build/AuditGitXUI.xcresult`. |
| Focused final real-app pass | **6/6 passed** against the final production code. It launched and interacted with the actual GitX Debug app to verify history rendering, staged-new-file rendering, preservation of an older selection when Working State appears, multi-commit presentation controls, staging layout, and commit context-menu targeting. Result: `build/AuditFinalUIFocused.xcresult`. |
| Performance plan | **3/3 passed**. Large-diff rendering averaged 0.053 seconds; revision parsing averaged 0.008 seconds; language classification averaged 0.027 seconds. Result: `build/AuditGitXPerformance.xcresult`. |
| Static verification | **Passed**: pinned SwiftFormat 0.62.1, pinned SwiftLint 0.63.2, changed-line Objective-C formatting, header interoperability, plist checks, and all 28 verification-tool tests. |
| Analyzer | **Passed** with no first-party analyzer findings, no SwiftLint analyzer violations, and the exact checked-in baseline of 16 legacy deprecation warnings. |
| Final app | **Build succeeded** and refreshed `/Volumes/ExtStor/gitx/build/GitX.app`. |

Six current diagnostic screenshots were extracted to `build/AuditFinalUIFocusedScreenshots`. Inspection confirmed that the selected commit remains the right-click target, Sequential/Combined controls appear for multiple commits, a staged new file renders as an all-additions patch containing only indexed content, and inserting Working State preserves an older commit selection. The screenshots are diagnostic artifacts and are intentionally not committed.

Direct desktop automation could not attach because macOS presented a new screen-recording/privacy prompt for the Codex Computer Use helper. That same system prompt partially overlays the diagnostic screenshots, but it did not block GitX's accessibility assertions or actions; the real-app XCUITest interaction completed successfully. No claim above relies only on visual appearance: each accepted defect also has focused behavioral coverage or sanitizer evidence.
