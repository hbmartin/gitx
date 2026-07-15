# Diff view scrolling performance investigation

Date: 2026-07-15
Branch: `codex/streamline-patch-rendering`

## Executive summary

Commit `5a851d8c` (`Streamline patch rendering`, 2026-07-14) caused the reported regression. It made two related changes to the native diff view:

1. It removed the cumulative 200 KiB large-patch gate, so large documents were always rendered in full.
2. It added HighlightKit token attributes to each changed line by highlighting the old and new sides of every hunk.

Rendering all content was an intentional usability improvement. Applying thousands of token-level foreground-color runs to that content was the scrolling problem. TextKit had more attributed glyph runs to resolve and draw whenever the viewport moved.

The fix keeps the complete diff, line backgrounds, intraline emphasis, links, and staging/discard controls. It omits only token-level source syntax colors when the combined UTF-8 size of the displayed diff sections exceeds 200 KiB. Small and medium documents retain syntax highlighting.

The final 220,660-byte benchmark fixture averaged approximately 53 ms for 40 forced viewport draws, within approximately 3 ms of the plain-text control measured in the corrected comparison. The initial regressed syntax path averaged approximately 79 ms. The initial and final fixtures differ in size, so those numbers should not be presented as a precise percentage improvement; the useful result is that the larger fixed workload is close to the plain control.

## User-visible impact

Before the regression, GitX stopped after a cumulative 200 KiB and offered a `Render patch…` action. The regression removed that interruption, but large Swift diffs then carried thousands of HighlightKit attributes. Once the document had been rendered, navigating it repeatedly paid the drawing cost of those attributes.

After this fix:

- every line of a large diff is still present and scrollable;
- additions, removals, hunk headers, intraline changes, and actions retain their diff-specific styling;
- token-level source syntax colors are retained when the whole displayed document is at or below 200 KiB;
- larger documents use a deliberately simpler set of attributes;
- one diagnostic log records the byte count when lightweight rendering is selected.

The limit is calculated once for the entire document, not once per file. This matters because stage and history views can combine several selected files or sections. Two individually sub-200 KiB sections can still produce a document large enough to regress scrolling.

## Investigation

### Code archaeology

The relevant rendering path is:

1. Controllers and file views prepare dictionaries containing section title, diff text, path, and context.
2. `PBNativeContentView.showDiffSections` renders the dictionaries on a user-initiated background queue.
3. `renderDiffText` parses file headers and hunks, builds an `NSMutableAttributedString`, and applies source, diff, intraline, and link attributes.
4. The completed attributed string is installed in the `NSTextView` on the main queue if its render generation is still current.

`git blame`, `git log`, and a parent-to-child diff isolated `5a851d8c`. Its new `syntaxHighlightsForHunkLines` method constructs old and new source buffers, runs each through HighlightKit, then copies attributed substrings back to changed lines. The same commit deleted `PBNativeLargePatchThreshold`, `approvedLargeSections`, and the cumulative gating branch in `showDiffSections`.

The existing generation check prevents obsolete work from being presented. It does not cancel HighlightKit work that has already started; that is a separate follow-up opportunity.

### Reproduction and measurement

A native AppKit benchmark was added to the explicit performance test plan. It:

- creates a real `PBNativeContentView` and `NSWindow`;
- renders a deterministic synthetic Swift diff;
- verifies the document is larger than the viewport;
- scrolls to 40 deterministic positions;
- forces each viewport through `cacheDisplay(in:to:)` into an `NSBitmapImageRep` so the measured block includes drawing rather than only changing a clip-view origin;
- warms the view twice before XCTest measurement;
- asserts the 220,660-byte fixture actually selects the over-budget lightweight path.

The test records a repeatable workload but currently has no checked-in `.xcbaseline`. Xcode reports `baselineAverage` as empty, so it does not yet fail automatically on a timing regression.

### Benchmark results

Times below are averages for one 40-viewport workload on the same development Mac. XCTest's cold first sample is included.

| Experiment | Diff size / shape | Average |
| --- | --- | ---: |
| Regressed Swift syntax path | 3,000 changed-line pairs, approximately 145 KiB | 79.17 ms |
| Plain `.txt` control | Same initial fixture | 52.11 ms |
| `allowsNonContiguousLayout = true` candidate | Same initial fixture | 151.9 ms |
| Fixed lightweight path | Greater than 200 KiB | 56.12 ms |
| Plain control | Same corrected greater-than-200-KiB fixture | 53.15 ms |
| Noncontiguous-layout candidate | Same corrected fixture | 104.07 ms |
| Final committed performance test | 4,500 changed-line pairs, 220,660 bytes | 52.82 ms |

Artifacts created during the investigation:

- `build/DiffScrollDrawComparison.xcresult`
- `build/DiffScrollLargeComparison.xcresult`
- `build/DiffScrollFinalPerformance.xcresult`

These result bundles are local build artifacts and are not checked into the repository.

### Rejected TextKit experiment

Apple documents `NSLayoutManager.allowsNonContiguousLayout` as allowing layout to occur around the visible content rather than always from the beginning of the document. It was a plausible optimization for large text storage. In this view's deterministic random-navigation workload it was substantially slower: approximately 152 ms on the initial fixture and 104 ms on the corrected fixture. It was therefore rejected.

References:

- [Apple: `allowsNonContiguousLayout`](https://developer.apple.com/documentation/appkit/nslayoutmanager/allowsnoncontiguouslayout)
- [Apple: `NSLayoutManager`](https://developer.apple.com/documentation/appkit/nslayoutmanager)
- [Apple Text System overview: layout manager](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextLayout/Concepts/LayoutManager.html)

This result is workload-specific; it does not imply that noncontiguous layout is generally harmful. It means enabling it without changing this view's document and navigation architecture did not solve this regression.

## Fix design

The threshold decision was extracted into the existing Swift `PBHighlighting` value/utility type:

- `shouldHighlightDiff(byteCount:)` owns the 200 KiB policy;
- the Objective-C rendering view calls that policy through its generated-compatible bridge;
- `showDiffSections` calculates one overflow-saturating total across all section text;
- the resulting Boolean is passed into each section render;
- over-budget hunks use the existing diff colors without invoking HighlightKit.

The sum saturates at `NSUIntegerMax` on overflow, which safely selects the lightweight path rather than wrapping into the syntax-enabled range.

The policy deliberately uses the raw bytes of every displayed section, including non-highlightable and collapsed content. That is conservative and predictable for responsiveness, but it can remove syntax color from a small code section shown beside a large plain-text or collapsed section. It should be tuned only with representative measurements.

## Test strategy and red/green evidence

New XCTest coverage includes:

- characterization that a large native diff produces a scrollable document and can reach its end;
- a boundary test proving 200 KiB is included and 200 KiB + 1 byte is excluded;
- a regression test proving a single over-budget Swift diff retains diff coloring while omitting token-level syntax attributes;
- an aggregate regression test with two individually sub-budget Swift sections whose combined size is 245,761 bytes;
- assertions that both the first and second aggregate sections use lightweight coloring, preventing a progressive or per-section implementation from passing accidentally;
- the permanent real-AppKit scrolling performance workload described above;
- the pre-existing small-diff test proving syntax and diff coloring still compose below the limit.

The aggregate test failed before the document-wide fix because each section was highlighted independently. Its red result is stored in `build/DiffScrollAggregateRed.xcresult`; the passing focused result is in `build/DiffScrollAggregateGreen.xcresult`. No intentionally failing test was committed.

Final verification:

- correctness plan: 80 tests, 0 failures (`build/DiffScrollFinal.xcresult`);
- performance plan: 3 tests, 0 failures (`build/DiffScrollFinalPerformance.xcresult`);
- coverage enforcement passed;
- overall line coverage increased from a 27.57% floor to 27.65%;
- `PBNativeContentView.m` line coverage increased from a 58.45% floor to 59.16%;
- `PBHighlighting.swift` remains at 100%;
- pinned SwiftFormat and SwiftLint passed;
- changed-line Objective-C formatting passed;
- repository static verification passed;
- clean deep Clang analysis passed with the exact existing 16-warning baseline;
- SwiftLint analysis passed with zero violations.

The displayed coverage values were 27.66% overall and 59.17% for `PBNativeContentView.m`; checked-in floors are truncated conservatively by the coverage policy.

## Objective-C-to-Swift assessment

`PBNativeContentView.m` was substantively edited, so conversion was assessed. The GitX conversion policy requires at least 90% implementation line coverage plus explicit normal, failure, and boundary coverage before conversion. Final line coverage is 59.17%, so converting this rendering view in the same change would violate the safety gate.

The low-risk part of the decision logic was instead kept in the existing, 100%-covered Swift `PBHighlighting` type. Full view conversion is deferred until the remaining parser, action, image, collapse, and generation behaviors are characterized sufficiently.

## Real-app verification

The exact Debug app was run against a temporary Git repository containing a 4,500-pair, approximately 220 KiB Swift diff. In the Stage view:

- the diagnostic log confirmed that the lightweight path was selected for the over-budget document;
- the top of the document showed the expected removed lines and stage/discard actions;
- dragging directly to the bottom showed the final added lines through line 4,499;
- returning to the middle showed the expected removed section;
- the app returned to its normal event loop and idle CPU after rendering.

Direct real-app control was used because the attempted XCUITest launch was blocked before the scenario by a macOS foreground-activation restriction. That infrastructure failure did not occur in the app flow and no XCUITest workaround was retained.

## Commits

- `d4d9c3c3` — characterize large native diff scrolling
- `b68d50f2` — add the lightweight large-diff policy and performance coverage
- `3358c540` — ratchet initial coverage gains
- `6d63b993` — document the Objective-C-only Swift bridge for analysis
- `fc52808f` — apply the budget to the whole combined document
- `e7a9dde4` — ratchet aggregate-test coverage gains
- `3a05b908` — apply canonical Objective-C selector formatting

## Follow-ups

1. Establish an Xcode performance baseline after repeated measurements on a stable, otherwise idle runner. Until then, the performance test provides comparable metrics but is not an automatic timing gate.
2. Profile actual trackpad scrolling with Instruments on several representative repositories, including long lines, many files, mixed file types, and several medium sections.
3. Revisit the 200 KiB limit using those measurements. Consider highlighted-byte estimates rather than raw document bytes only if the added policy complexity has measurable user value.
4. Investigate cancellation or coalescing of obsolete background renders. Generation checks prevent stale presentation but do not stop already-running parsing or HighlightKit work.
5. Consider a viewport-oriented or incremental highlighting architecture before revisiting noncontiguous layout or TextKit 2. That is a broader design change, not a regression fix.
6. Increase `PBNativeContentView` behavioral coverage toward 90%, then reassess converting it to Swift under the repository conversion workflow.
7. Investigate the macOS XCUITest foreground-activation failure separately so performance scenarios can eventually include repeatable end-to-end UI navigation.
8. Consider reducing the accessibility cost of exposing an enormous `NSTextView` value. Full accessibility-state collection was intermittently slow during visual diagnostics even though direct scrolling remained responsive.
