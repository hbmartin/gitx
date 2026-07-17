# Repository view and Working State performance investigation

Date: 2026-07-17
Branch: `codex/comprehensive-settings-toolbar`

## Outcome

History and Commit now remain mounted for the lifetime of their repository window. Switching hides one retained view and reveals the other, restores that view's responder, reuses its toolbar, and does not call `updateView` again. The measured warm switch is **3.73 ms p95**, below both the 50 ms interaction budget and the stricter 16 ms main-thread frame budget.

History's **Uncommitted Changes** row now keeps one memory-only rendered snapshot per diff layout in its repository window. Revisiting it displays cached content synchronously, restores its scroll position, and refreshes Git content in the background. Cached feedback is **1.93 ms p95** against a 50 ms budget.

The representative fresh pipeline runs both Git diff commands and renders 500 changed files producing at least 1 MiB of patch text. It measures **155.49 ms p95** against a 250 ms budget. The separate cold observation is 147.72 ms. A 5,000-file, 10 MiB render measures **787.26 ms** and is report-only.

## Performance budgets

| Interaction | Workload | Budget | Enforcement |
| --- | --- | ---: | --- |
| Warm History ↔ Commit | Both views mounted and toolbars created | ≤ 50 ms p95 | Pull-request performance plan |
| Warm switch main-thread work | Same samples | ≤ 16 ms p95 | Pull-request performance plan |
| Cached Uncommitted Changes feedback | 500 files, at least 1 MiB | ≤ 50 ms p95 | Pull-request performance plan |
| Fresh Uncommitted Changes | Two Git diff processes plus native render; 500 files, at least 1 MiB | ≤ 250 ms p95 | Pull-request performance plan |
| Stress render | 5,000 files, at least 10 MiB | Report only | Attachment, no timing assertion |

The constants live in `PBPerformanceBudgets`. `GitXPerformanceTests` calculates p95 explicitly and fails when a gated budget is exceeded. The GitHub performance job now runs for pull requests as well as scheduled and manually dispatched runs.

## History ↔ Commit hypotheses

### 1. Rebuilding the toolbar on every switch

**Evidence:** The old implementation constructed a new `NSToolbar`, rebuilt every item and status view, assigned it to the window, and triggered AppKit layout on every mode change. Pre-change instrumentation observed approximately 10.9–14.7 ms in the isolated toolbar replacement and 17.8–21.6 ms for representative complete switches. This alone could consume most or all of a 16 ms frame.

**Result:** Confirmed as a major contributor. Each mode now owns one retained toolbar and status view. The focused test proves returning to History installs the identical toolbar object. Warm complete switches now measure 3.73 ms p95.

### 2. Removing and re-adding the controller view

**Evidence:** The old `changeContentController` removed every content subview, added the destination again, and forced AppKit to rebuild its layout and responder state. It also discarded the visible selection, scroll, and focus context at the window boundary.

**Result:** Confirmed. Both controller views now remain children of the content container and only their `hidden` states change. Focus is remembered per controller. The behavior test proves both views remain mounted and only the active one is visible.

### 3. Calling `updateView` on every switch

**Evidence:** The old switch path always called `updateView`. For Commit this starts an index refresh; for History it can trigger repository and presentation work even when the user is merely returning to an already-current view.

**Result:** Confirmed as avoidable work. `updateView` now runs only on first mount. Existing repository notifications and explicit Refresh continue to update retained controllers. The focused spy test proves a History → Commit → History sequence updates each controller exactly once.

### 4. Status observation or responder restoration is intrinsically expensive

**Evidence:** These operations remain in the optimized path, including KVO status wiring and first-responder changes.

**Result:** Not a meaningful bottleneck for this workload. With those operations retained, warm switching remains 3.73 ms p95.

## Uncommitted Changes hypotheses

### 1. There was no cache when navigating away and back

**Evidence:** The old path displayed “Loading changes…”, launched fresh staged and unstaged Git diff tasks, rebuilt sections, and rendered a new attributed document whenever Uncommitted Changes was selected after another history row.

**Result:** Confirmed as the cause of slow revisits. A repository-window cache now retains the last sections, rendered-diff identity, and native attributed result for each layout. Cached feedback is 1.93 ms p95. The cache is not persisted and is cleared with the repository window.

### 2. Git acquisition dominates every refresh

**Evidence:** Working State runs staged and unstaged Git diff commands sequentially. The representative native render alone is 77.19 ms p95, while the Git-plus-render pipeline is 155.49 ms p95. Git acquisition and process overhead therefore account for roughly half of this tracked-file fixture.

**Result:** Confirmed for fresh loads, but already within the 250 ms budget. The commands remain off the main thread. Parallelizing or replacing them would add concurrency and cancellation complexity without being necessary to meet the accepted budget.

### 3. Native diff rendering is too slow for the fresh budget

**Evidence:** The deterministic 500-file, at-least-1-MiB renderer fixture measures 77.19 ms p95 after a separate 77.95 ms cold observation.

**Result:** Rejected for the representative workload. Rendering has headroom inside the end-to-end 250 ms budget.

### 4. Installing a cached attributed document still blocks visible feedback

**Evidence:** The cache test alternates a loading message with immediate restoration of the complete 500-file document, including TextKit installation and saved scroll restoration.

**Result:** Rejected as a bottleneck. That work measures 1.93 ms p95.

### 5. Very large documents need a different architecture

**Evidence:** The 5,000-file, at-least-10-MiB renderer fixture takes 787.26 ms.

**Result:** Plausible beyond the representative budget, but not addressed by this change. The result is intentionally report-only. Cached revisits remain fast after the first render; future work can consider incremental or viewport-oriented rendering if real repositories show this shape frequently.

## Measurements

All final measurements were recorded on the same Mac mini running macOS 26.5.1 with Xcode 26.6 (17F113), using the explicit `GitXPerformance` test plan.

| Measurement | Cold | p95 |
| --- | ---: | ---: |
| Warm History ↔ Commit | Excluded; cold toolbar creation is logged separately | 3.73 ms |
| Cached 500-file / 1-MiB feedback | Cache populated before samples | 1.93 ms |
| Fresh 500-file / 1-MiB native render | 77.95 ms | 77.19 ms |
| Fresh 500-file / 1-MiB Git-plus-render pipeline | 147.72 ms | 155.49 ms |
| Stress 5,000-file / 10-MiB native render | — | 787.26 ms, report-only |

The warm-switch log also observed a 104 ms first History toolbar construction and a 10.47 ms first Commit mount. Those cold costs are intentionally separate from the warm interaction gate.

Local result bundles:

- `build/RepositoryPerformancePlanFinal.xcresult`
- `build/RepositoryCorrectnessCoverageStable.xcresult`
- `build/RepositoryThreadSanitizerFinalPass.xcresult`

## Correctness and state preservation

Focused coverage proves:

- retained views are mounted once and preserve toolbar identity;
- context clicks preserve an existing multi-selection or select only the clicked outside row;
- every safe contextual file action accepts multiple selected files, including plural Reveal in Finder;
- cached Working State content is restored synchronously with its previous scroll position;
- cache entries are scoped by diff layout;
- interactive collapse and reveal actions invalidate only the affected cached presentation before rerendering;
- the Push choice is remembered per repository only after a successful commit;
- an unavailable Push control displays off without erasing the stored choice;
- double-clicking a reachable recent repository opens it, while a missing entry routes to Locate Missing.

The final correctness plan passed 268 tests with 76.82% aggregate `GitX.app` line coverage. The full Thread Sanitizer plan passed 265 tests with no race report; focused sanitizer coverage then passed the three concurrency and deterministic-history tests added during final verification. The pinned static checks and clean-derived analyzer also pass.

The `GitXUI` plan could not initialize its runner on this host: three attempts ended before test discovery with `Timed out while enabling automation mode`. The same macOS automation-service failure prevented the accessibility-driven manual fallback from starting. The app-hosted layout and behavior tests pass, and the UI screenshot attachment remains in the scenario for the next healthy UI-test host; no interactive UI-test pass is claimed here.

## Objective-C-to-Swift assessment

The nib-owning Objective-C controllers remain in Objective-C. `PBGitWindowController.m`, `PBGitCommitController.m`, `PBWebHistoryController.m`, and `PBNativeContentView.m` retain AppKit wiring, responder-chain behavior, cancellation, and rendering installation. Focused decisions were extracted into Swift seams for the memory cache, layout coordination, recent activation, menu policy, settings, and performance budgets.

`PBWebHistoryController.m` and `PBGitTree.m` remain below the conversion skill's 90% line-coverage prerequisite, so full conversions would be unsafe in this change. The high-coverage controllers also were not converted because retaining their nib and responder wiring was the lower-churn design approved for this work.
