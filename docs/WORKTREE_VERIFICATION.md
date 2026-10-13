# Worktree implementation verification

## Characterization before Swift extraction

Verified run ID: workflow-1fc493ff44ec

The Debug and Release consumer builds passed before conversion. The focused
correctness run passed 13 tests, covering the existing sidebar badge, revision
cell rendering and label hit boundaries, and repository watcher lifecycle.

- Sidebar cell implementation: 16/16 lines (100%).
- Revision cell implementation: 292/316 lines (92.405%).
- Repository watcher implementation: 231/241 lines (95.851%).

The focused result is preparation evidence only. It does not ratchet the
complete correctness coverage floors or replace final full verification.

Consumer receipts:

- `artifacts/verification/workflow-1fc493ff44ec-debug-test-build-6934cb60/receipt.json`
- Release and focused correctness receipts are referenced by
  `artifacts/verification/workflow-1fc493ff44ec/workflow.json`.

Coverage result:
`artifacts/verification/workflow-1fc493ff44ec-correctness-e5b70398/Results/GitX.xcresult`.

The small sidebar cell retains its `PBSidebarTableViewCell` runtime name,
`checkedOutImageView` weak nib outlet, inherited frame/coder initialization,
and `isCheckedOut` selector. The larger revision cell retains its C graph and
AppKit drawing; only its reference color decision moves into Swift. The watcher
retains FSEvents ownership and callback wiring; only path ownership decisions
move into Swift.

## Core feature and local regression evidence

- `ab30f16a`: parser, immutable snapshots, version gating, lifecycle policies and
  administrative-link inspection, developed from local failing expectations.
- `74be273b`: boundary coverage and core floor ratchet. The latest full core suite
  passes 42 tests at 99.74% displayed aggregate coverage (99.73% truncated policy
  floor). Worktree parsing and values cover 110/111 lines (99.10%); link inspection
  and lifecycle policies cover 100%. The remaining parser region is the
  short-circuit fallback after a successful branch-prefix check.
- `workflow-c22247dd56c3`: the canonical full core check passes all 42 tests and
  its coverage gate using only the permitted Foundation import.
- `workflow-1be8a978052d`: host preflight passed; the new lock/unavailable badge
  expectation failed at the missing lock image before the Swift replacement.
- `artifacts/worktree-bare-open-red.log`: bare-checkout opening expectation failed
  before aligning eligibility with upstream's worktree double-click behavior.
- `artifacts/worktree-repair-match-red.log`: a selected folder belonging to another
  repository must be rejected before invoking Git repair. Administrative-link
  matching and isolated lifecycle tests now prove its links remain unchanged.
- `workflow-82e4e4ff9e9c`: changing the selected Git preference exposed the cached
  startup executable. The worktree service now reads that preference through its
  existing `PBTask` process path; old and unavailable executables disable the
  feature and a newer executable restores it.
- `workflow-12eb7dab57bc`: native regression expectations failed for missing
  accessibility identifiers/help on AppKit's exposed text fields and history
  colors when the graph cell's controller outlet is absent.
- `workflow-5aeb27e8c86c`: 20 focused native tests pass, including those regressions,
  normal/failure lifecycle sheets, cross-window refresh, startup history mounting,
  moved relative links, copied repositories, and real document activation.
- `workflow-ca927ec80627`: activation preflight and both worktree accessibility
  journeys pass. They prove history browsing, correct checkout opening, activation
  of an existing window, unchanged checkout HEADs, and ordinary/force removal with
  branch retention. Window queries use checkout titles and the Window menu when
  the newly opened checkout covers the original window.
- `workflow-fff3c2b7a41e`: canonical static checks pass, including pinned
  SwiftFormat/SwiftLint, architecture and header boundaries, resources and all
  579 verification-script tests.
- `workflow-pr87-complete-correctness-1`: the unfiltered run executed 1,772 tests,
  exposing a null Swift virtual getter call in a queued worktree repair callback
  on an Objective-C-imported window-controller subclass. The runner attributed
  that crash to the active Raycast test. Its coverage remains diagnostic only.
- `workflow-0945abaeab9f`: 97 focused tests pass after making the internal repair
  state final, including a direct subclass delegate regression, the complete
  Swift feature class, held-history-label dispatch, sidebar menus and cache/path
  lookup boundaries. Existing staging layout actions also pass their new
  selection and menu-state characterization.
- `workflow-db02b2b9aab8`: both accessibility journeys and activation preflight
  pass with an explicit front-window assertion for activating an existing
  checkout.

Fresh target-window UI screenshots are exported under
`artifacts/diagnostics/worktree-ui-green/`; AppKit lifecycle sheet attachments
remain in the native result bundles. These are diagnostic attachments, without
pixel comparisons.

The generated consumer interface was checked at the verified Debug build's
`DerivedSources/GitX-Swift.h` (under the canonical correctness DerivedData cache).
The runtime class and selector checks remain part of native verification.

Final native, UI, analyzer, sanitizer, performance and complete coverage receipts
are produced under `artifacts/verification/` by the canonical full profile after
the integrated feature commit. Focused results do not admit lowering or
ratcheting complete-app floors.

The planned authoritative combined delivery receipt is
`artifacts/verification/workflow-pr87-worktrees-final/workflow.json`.
Its recorded status determines completion; this planned path does not claim a
successful full run before that run finishes.
