# FlowDelta 0.3.2 GitX integration

Date: 2026-11-27

GitX moves from FlowDelta 0.2.2 to [0.3.2](https://github.com/hbmartin/FlowDelta/tree/0.3.2) (revision `d0290e6`). 0.3.0 closed FlowDelta M2 and shipped the M3 review features GitX shows. 0.3.1 and 0.3.2 fix the defects found in review of 0.3.0 and 0.3.1, and GitX pinned neither earlier release. 0.3.2 also keeps Swift `self.` and JSX text edits out of the noise that GitX hides by default. FlowDelta's own gates are recorded in its [M3 validation record](https://github.com/hbmartin/FlowDelta/blob/0.3.2/notes/014-m3-validation.md), its [0.3.1 notes](https://github.com/hbmartin/FlowDelta/blob/0.3.2/notes/015-0.3.1-review-fixes.md) and its [0.3.2 notes](https://github.com/hbmartin/FlowDelta/blob/0.3.2/notes/016-0.3.2-review-fixes.md).

## What changed in GitX

- **Pin and boundary.** The project requires FlowDelta exactly 0.3.2, `Package.resolved` pins revision `d0290e6020f25389c5df625b2832b213cb683d64`, and GitX links FlowDeltaExport in addition to Core, Analysis, Git and UI. `scripts/check_flowdelta_boundary.py` now also fails when the requirement is a range, when `Package.resolved` disagrees with it, when the project or workspace references a local FlowDelta checkout, or when GitX links a product outside that set. Its tests build each failing project in a temporary directory.
- **Revision provider.** FlowDelta's `GitCLIRevisionProvider` accepts a git executable, skips the unsupported side of a rename and terminates git when cancelled, including after git closes its output. GitX keeps `HistoryFlowRevisionProvider` because it also checks a blob's size before reading it and terminates git once output or error output passes a fixed limit.
- **Review preferences.** `GitXCore.HistoryFlowReviewPreferences` stores presentation, slice, noise level, grouping and export format as Application Preferences (`PBHistoryFlowPresentation`, `PBHistoryFlowSliceDirection`, `PBHistoryFlowNoiseLevel`, `PBHistoryFlowGroupsByConcern`, `PBHistoryFlowExportFormat`). Missing or unknown values fall back one by one, and the default hides cosmetic noise while FlowDelta keeps the "N hidden — Show" link visible. The Flow adapter applies them to each report as host changes, and saves only the changes FlowDelta reports as the user's, so applying preferences never writes them back. Since 0.3.1, FlowDelta draws and reports a slice only from a node selected in the delta graph. The saved slice is turned on after each report appears and is drawn from the next node the user selects. The saved slice changes only while a node is selected in the delta graph, so choices made before then keep it.
- **View ▸ Flow Review.** Every item sends `performHistoryFlowCommand:` with a `HistoryFlowCommand` tag. `PBGitHistoryController` routes the action to the Flow adapter through `supplementalTargetForAction:sender:`, so the menu works while the commit list or another History control has focus. `HistoryFlowCommandPolicy` decides which items are enabled and checked: everything is disabled while the Flow tab is hidden or shows no report, presentations need a function, slices need a node selected in the delta graph, and walkthrough steps follow the step on screen. Choosing the checked slice again hides it.

  | Command | Shortcut |
  | --- | --- |
  | Delta, Before / After, Calls | ⌃⌘1, ⌃⌘2, ⌃⌘3 |
  | Forward Slice, Backward Slice | ⌃⌘↓, ⌃⌘↑ |
  | Show All Changes, Hide Formatting, Hide Cosmetic Changes, Group by Concern | — |
  | Start Walkthrough, Next Step, Previous Step | —, ⌃⌘], ⌃⌘[ |
  | Copy Flow Report As ▸ Markdown, JSON, Mermaid | — |
  | Export Flow Report… | ⇧⌘E |

- **Copy and export.** `FlowDeltaReviewCommands.swift` is the only file that imports FlowDeltaExport. Reports render off the main actor with the review's noise level and grouping. Export uses a save sheet with a Format pop-up that renames the file (`Flow <base>..<target>.md|json|mmd`) and remembers the chosen format. Copy and export announce completion to VoiceOver and present failures on the window.
- **Diagnostics.** Flow diagnostics carry FlowDelta's diagnostic code, and the incomplete-analysis banner adds one plain explanation per kind of problem: resource limits, partial parses and internal errors.
- **Summary.** Since 0.3.0, FlowDelta counts "1 file" and "1 function delta" in the singular; the History Flow tests follow.

## Validation

Before this note was written:

- Xcode resolved the workspace strictly from `Package.resolved` (`-onlyUsePackageVersionsFromResolvedFile`) to FlowDelta 0.3.2 at `d0290e6`.
- `scripts/check_flowdelta_boundary.py` and its 10 tests passed.

The complete verification profile runs on the committed candidate, which includes this note:

- static checks;
- Debug and Release builds;
- correctness with coverage, plus the core and ForgeKit packages;
- the address, undefined-behavior and thread sanitizers;
- UI, performance and the analyzer;
- the final Debug app.

Any change to a tracked file invalidates that evidence, so its results are recorded in the pull request description, not here.
