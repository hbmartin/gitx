# Worktree support

The behavior reference is upstream GitX commit
[`5baf2894c453b8e3e63d4a247ecb6626cd80fe54`](https://github.com/gitx/gitx/tree/5baf2894c453b8e3e63d4a247ecb6626cd80fe54).
Worktrees require **Git 2.48 or later**. This feature gate is checked
asynchronously for the selected executable and refreshed when Git preferences
change; ordinary repository operations keep their existing Git minimum.

## Phase 1 — discovery and lifecycle values

`GitXCore` owns immutable, Sendable worktree snapshots, strict NUL-delimited
porcelain parsing, version and menu eligibility, command arguments, force-retry
classification, folder suggestions, and administrative-link inspection. Unknown
porcelain fields are ignored; a malformed record fails the complete discovery.
Path and branch identities preserve UTF-8 bytes, including Unicode and newlines.

The dedicated repository service runs Git through `PBTask`, coalesces refreshes,
rejects stale completions, cancels discovery on close, and publishes changed
snapshots on the main thread. Discovery failure keeps the last successful data
and logs the cause. Lifecycle mutations share a FIFO for the common Git
directory; each checkout retains its own index writer.

## Phase 2 — presentation and refresh

The expanded **Worktrees** group follows **Branches** and excludes the current
checkout. Branches owned by another checkout appear there without duplicate
Branches rows. Labels distinguish branches, detached HEADs and bare repositories;
tooltips and accessibility help include paths, lock/prune reasons and link state.
Upstream's template icon, lock badge, unavailable dimming and restrained history
label color are retained, with the current branch's existing visual priority.

**Single click browses branch history. Double-click or Open Worktree opens or
activates that checkout**, through this fork's repository opening coordinator.
Held branch labels in history use the same opening behavior. Selection is
restored by canonical worktree identity without initiating navigation.

FSEvents watches common Git metadata alongside local Git and working directories.
Shared references, registrations and sibling HEAD changes refresh affected
windows; sibling indexes do not refresh local status. Activation snapshots
include worktrees when continuous watching is disabled.

## Phase 3 — lifecycle flows

Add supports an existing local branch or a new branch at current HEAD, with
upstream folder suggestions. Git owns directory removal. Ordinary removal is
confirmed first; only upstream's force-eligible refusals offer a separately
confirmed **Remove Anyway**. The branch is retained and Git errors are surfaced.
Lock, unlock, reveal, locate and repair follow upstream's lifecycle interactions.
Prune previews Git's dry-run report and is blocked until moved nested worktrees
are repaired.

Absolute and relative links are matched through Git administrative backlinks.
Repair is offered once per window, defaults to relative links only when known
existing links uniformly use them, and is verified by rereading state.

## Intentional adaptations and verification

This fork uses its native history surface and existing Swift coordinators rather
than upstream's web history implementation. AppKit and responder wiring remain
in the existing controllers. The small sidebar cell is Swift with its Objective-C
runtime name and weak nib outlet preserved; revision drawing and FSEvents remain
Objective-C with narrow Swift decision extractions.

NUL-delimited discovery and complete metadata-path reads preserve unusual paths.
A copied repository whose worktrees link into another existing repository is
reported, and repair is refused to preserve those foreign links: isolated Git
experiments showed repair could otherwise rewrite the original checkout's link.

Preparation coverage, characterization commits, local red/green results and
final verification evidence are recorded in [WORKTREE_VERIFICATION.md](WORKTREE_VERIFICATION.md).
New regressions use Swift XCTest, isolated Git repositories, AppKit tests and
accessibility UI journeys with fresh diagnostic screenshot attachments.
