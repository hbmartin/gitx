# FlowDelta M2 GitX integration record

Started 2026-08-04 on `codex/flowdelta-m2`, based on the published ADR branch. The user's existing `/Volumes/ExtStor/gitx` worktree is intentionally untouched.

## Intended seam

- Add the external `hbmartin/FlowDelta` Swift package with an exact release pin.
- Restrict package imports to `Classes/Controllers/FlowDeltaAdapters.swift`.
- Add a third no-border History tab, **Flow**, and a third Snow Leopard-style segmented-control item.
- Let the Swift adapter observe History selection and perform cancellable analysis for a single real commit against its first parent.
- Render deterministic syntax-derived call edges. FlowDelta's optional IndexStoreDB enrichment lives in a separately resolved extension whose unstable upstream graph is intentionally outside GitX's exact semantic pin.
- Keep Details staging behavior and Tree multi-selection fallback unchanged.
- Persist the selected index through the existing `PBHistorySelectedDetailIndex` key.

## Test boundary

The existing `HistoryControllerTests` already characterize tab selection, persistence, tree fallback, working-state behavior, and real-nib lifecycle. M2 will extend those tests and add decision-level adapter tests plus a UI diagnostic screenshot. Test execution is deferred until the milestone implementation is assembled.

## Package handoff

Implementation was assembled and exercised against the sibling `../FlowDelta` checkout. The first 0.2.0 consumer resolution exposed SwiftPM's rejection of revision-based transitive dependencies in a semantic release. FlowDelta moved its optional IndexStoreDB integration to a separate extension in 0.2.1. Initializing GitX's Sparkle submodule then exposed a shared pre-1.0 ArgumentParser constraint, corrected in FlowDelta 0.2.2. GitX exact-pins that release and HighlightKit 0.3.0; the local development override is not part of the GitX change.
