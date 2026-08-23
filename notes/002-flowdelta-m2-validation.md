# FlowDelta M2 GitX validation

Date: 2026-08-04

Validation began only after the M2 integration was assembled, per the requested milestone boundary.

## Package resolution

- `xcodebuild -list -project GitX.xcodeproj` first resolved FlowDelta from `https://github.com/hbmartin/FlowDelta.git` at exact 0.2.1, revision `95d5217`.
- The graph resolved tree-sitter-swift through its semantic `0.7.3-with-generated-files` release and did not include IndexStoreDB or swift-lmdb.
- HighlightKit resolved at exact 0.3.0.

## Results

Results will be recorded here as the focused, correctness, UI, sanitizer, static-analysis, coverage, formatting, screenshot, and final app-build gates complete.

- The first focused History test invocation stopped during build planning because this isolated worktree had not initialized the checked-in Sparkle, ObjectiveGit, and MAKVONotificationCenter submodules. No tests ran. The required submodules (including ObjectiveGit's recursive build inputs) were initialized before retrying the unchanged test selection.
- The initialized Sparkle project exposed its existing `swift-argument-parser` 0.4.3-up-to-1.0 requirement, which conflicted with FlowDelta 0.2.1's exact 1.8.2 dependency before compilation. FlowDelta 0.2.2 widened the compatible CLI dependency, retained all package and CLI validation, and GitX moved its exact pin to the corrected patch release before retrying.
- The complete initialized GitX workspace then resolved FlowDelta exact 0.2.2 at revision `dcb4be3`, HighlightKit exact 0.3.0, and the shared ArgumentParser dependency at 0.5.0 without revision- or branch-based packages in FlowDelta's core graph.
- The next focused invocation reached build planning but Xcode 27 rejected Sparkle's vendored macOS 10.13 subtarget settings because this toolchain supports macOS 12 and newer. GitX already targets macOS 15, so subsequent local verification supplies a workspace-wide `MACOSX_DEPLOYMENT_TARGET=15.0` override rather than modifying the pinned Sparkle submodule.
- The first macOS 15 cold build exposed ObjectiveGit's existing undeclared-output race: its libgit2 script produced `External/libgit2.a`, but the framework linker checked for the archive before the script completed. The archive was present after the stopped build, so the unchanged focused test command was retried against the warmed dependency output.
- The warmed retry then identified ObjectiveGit's two other expected host archives, `External/libssh2.a` and `External/libcrypto.a`, as unstaged. Its documented `script/bootstrap` staged both Homebrew-provided archives (and upgraded the installed `pkgconf` formula from 3.0.4 to 3.0.5) before the next retry.
- The first production-source compilation found two Swift 6 integration errors: AppKit imports `awakeFromNib()` as nonisolated, and History's repository property is optional. The adapter now keeps the override nonisolated while explicitly entering the main actor for observation setup, and passes the optional working-directory URL through the selection policy.
- The app target then built successfully. The focused XCTest target could not reference internal Swift app symbols directly, matching GitX's existing module boundary. The pure selection policy moved into the existing `GitXCore` value layer with package-level decision tests, while the app-hosted History test now verifies the Flow view through its accessibility contract.
- The first focused runtime loaded the XIB class as a module-qualified Swift name instead of the adapter's explicit Objective-C runtime name. The XIB now omits the Swift module qualifier for `PBFlowDeltaAdapterView`, matching GitX's Objective-C-compatible nib class lookup.
- Interface Builder accepts the corrected Flow tab and adapter class. Its remaining notices and warning are unchanged legacy clipping, intrinsic-size, and table-cell outlet diagnostics outside the new tab.
- A warmed focused run launched its app-hosted test binary from DerivedData on the external volume, but the host remained in `dyld` before XCTest injection. That disposable run was stopped and repeated with isolated DerivedData on the internal disk.
- The first internal-disk runtime proved that `PBFlowDeltaAdapterView` loads without an unknown-class warning. Its new test initially searched the inactive tab's detached view hierarchy; the test now selects Flow before asserting the adapter's accessibility contract and persisted tab index.
- The corrected Flow-tab case passed independently (1 test, 0 failures), then the complete app-hosted `HistoryControllerTests` suite passed (53 tests, 0 failures in 124.905 seconds).
- The complete correctness plan ultimately passed with 988 tests and 0 failures in 303.159 seconds. Repeated intermediate green runs were used to make existing high-water coverage floors deterministic rather than lower them.
- The first complete coverage bundles exposed timing-dependent gaps in the repository watcher and Attention authorization product proof. A direct existing-behavior watcher fallback characterization and DEBUG-only Attention product-proof seam made those paths deterministic; the watcher finished at 95.44%, the collaboration controller at 89.78%, and `ForgeAttentionViewController` at 97.60%.
- `scripts/check_coverage.py --record-improvements` raised the aggregate `GitX.app` floor from 89.75% to 89.78%, registered `FlowDeltaAdapters.swift` at 91.25%, and raised other measured floors without lowering any entry. Rechecking the recorded policy passed.
- `scripts/verify_static.sh origin/forge-github` passed with the exact Apollo iOS 2.3.0 CLI from Xcode's resolved package archive. This covered pinned SwiftFormat and strict SwiftLint, offline codegen drift, package boundaries, header interop, Swift concurrency escapes, plist/XIB validation, workflow policy, and 137 script tests.
- The standalone `GitXCore` package passed all 16 tests. Coverage measured 99.24%; `scripts/check_coverage.py --record-improvements` raised its aggregate floor from 99.15% to 99.23% and registered `HistoryFlowSelectionPolicy.swift` at 100% without lowering any floor.
- The shared `GitXUI` plan passed all 35 tests: 22 current diagnostic screenshot cases, 7 Milestone 2 workflows, and 6 Milestone 3 workflows. No screen recording was created, per request.
- The `GitXThreadSanitizer` plan passed all 988 tests with 0 failures in 359.290 seconds and no race report.
- The first complete `GitXAddressUndefined` run reached a Foundation file-presenter deadlock while `ForgeScriptingTests` manually removed an `NSDocument` before closing it. The teardown now asks `NSDocument.close()` to coordinate its own unregistering. The previously hung test passed independently under ASan in 9.406 seconds, and the complete AddressSanitizer + UndefinedBehaviorSanitizer plan then passed all 988 tests with 0 failures in 349.951 seconds and no sanitizer report.
- The `GitXPerformance` plan passed all 18 tests with 0 failures in 17.932 seconds.
- A cold `scripts/run_analyzer.sh` passed Xcode's deep analyzer at the exact 12-warning legacy baseline. Its pinned SwiftLint compiler-log analysis completed all 205 Swift files with 0 violations. An explicit `OSLog` import is narrowly annotated because the compiler requires `Logger` and privacy interpolation while SwiftLint's compiler-log import analysis sees the module transitively.
- Final `scripts/verify_static.sh origin/forge-github` repeated successfully after the analyzer adjustment: 0 SwiftFormat findings across 8 changed Swift files, 0 strict SwiftLint violations across 253 files, all structural policy checks, and all 137 script tests passed.
- The final Debug product rebuilt successfully, passed deep strict code-signature verification, and is available at `build/GitX.app`.
- The rebuilt app opened the sibling `../FlowDelta` repository, selected commit `e9f06adb`, and rendered its parent comparison in the native History Flow tab as 2 Swift files and 3 function deltas. The current diagnostic is attached at `notes/artifacts/m2-history-flow.png`; no screen recording was produced.
