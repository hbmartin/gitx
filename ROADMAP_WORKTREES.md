# Worktree roadmap

GitX can already open linked worktrees, derive their common Git directory, and
watch their working directories.  The branch-deletion change in this release
also delegates local deletion to `git branch -D`, which protects a branch that
is checked out by any linked worktree.  This document intentionally does not
add a worktree feature or new worktree UI.

## Phase 1 — discovery contract

- Require one documented minimum Git version for all worktree commands.
- Add a `GitXCore` parser for `git worktree list --porcelain`, with fixtures
  for the main worktree, linked worktrees, bare repositories, locked entries,
  malformed records, paths containing Unicode, and detached HEADs.
- Load that model on a background service.  A read failure leaves existing
  sidebar data visible and reports a diagnostic log rather than blocking a
  repository window.

## Phase 2 — presentation and refresh

- Watch the common Git directory as well as each working directory so a ref
  change in one worktree refreshes its siblings.
- Present a Worktrees sidebar group with a restrained Snow Leopard-style label
  color.  Selecting an entry opens its working directory in a repository
  window; it never checks out that entry's branch in the current worktree.
- Preserve selection by worktree identity across refreshes and show a clear
  detached/locked state without inventing a synthetic branch.

## Phase 3 — lifecycle commands

- Add, remove, lock, unlock, prune, and repair operations through a dedicated
  service, with command eligibility and destructive confirmations extracted
  from the controller.
- Use Git's own protections for checked-out branches and surface its error
  text.  Never remove a directory until Git confirms the matching worktree
  operation succeeded.
- Cover parser decisions in `GitXCore`, command construction with isolated
  local repositories, and the critical sidebar/opening workflow with an
  accessibility-driven UI test and diagnostic screenshot attachment.
