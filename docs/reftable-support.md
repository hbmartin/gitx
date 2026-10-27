# Deferred reftable support

Status: documented on October 26, 2026; implementation is deferred. This change
does not update ObjectiveGit or libgit2, enable reftable, or migrate repositories.
Repository scripts and skills remain authoritative for verification policy.

## Current limitation

The fork pins `hbmartin/objective-git` at
`b62d1f8baa9844b1a5c808bd1d35f259d5d7398b`, which uses libgit2 1.9.7
(`49e408b3208bc3093757a1c2db938d3590f3f412`). Native repository access does not
support the reftable reference backend. Selecting a newer command-line Git does
not upgrade the library used by ObjectiveGit.

[Upstream issue #768](https://github.com/gitx/gitx/issues/768) reports this after
`git refs migrate --ref-format=reftable`, suggested by Git when a remote contains
refs differing only by case on a case-insensitive filesystem. Do not suggest
migration as a workaround while this fork lacks native support.

## Dependency integration required

[GitX PR #769](https://github.com/gitx/gitx/pull/769) and
[ObjectiveGit PR #118](https://github.com/gitx/objective-git/pull/118) provide the
reference implementation. Read their final merged changes: the original GitX PR
description contains an earlier caveat about an unavailable backend that differs
from its final tests and documentation.

The upstream ObjectiveGit result is
`f98211712cbe99f706dafaf507a227ee9affd662`, pinning libgit2
`f28579db11737eaa2ced18498e229967a12f1c3f` (`v2.0.0-rc.1`). The release candidate
requires a separate adoption decision; do not silently substitute a moving branch.
Preserve our dependency fork's arm64 build, deployment settings, dependency
configuration, and build fingerprinting rather than replacing its pointer with
upstream's fork.

Wrapper adaptations include the replacement object-hashing API, removed public
pack-only object enum cases, and the removed repository-init flag. Audit every
app consumer against the generated interfaces and build both Debug and Release.
The app assumes SHA-1 object IDs in several C-facing paths; reject SHA-256
repositories explicitly before interpreting or truncating object IDs.

Upstream documents incomplete native reference-transaction and namespace support.
Our commit publication and stash mutations already use the Git executable; prove
those paths continue working and do not replace them with unsupported native
operations. Audit reference refresh and watcher classification for reftable files
under both checkout-specific and shared repository directories.

## Acceptance before enabling support

Use isolated real repositories, with Git 2.45 or newer for reftable fixtures.
An explicit invalid test executable must fail instead of silently skipping.
Never rewrite a user's reference backend as part of opening a repository.

- Discover and open repositories from nested folders, including bare repositories
  and linked worktrees; preserve their reference-storage configuration.
- Read branches, tags, HEAD, detached/unborn states and reflogs through ObjectiveGit.
  Cover case-distinct refs on a case-insensitive filesystem.
- Create, rename and delete refs natively; observe subsequent external Git writes.
- Stage and unstage, commit, amend and publish through the existing transaction
  path; compare actual tree and ref IDs with command-line Git.
- Save, enumerate, apply, pop and drop stashes, including failure/conflict paths.
- Refresh history and shared refs after external changes from the main checkout
  and a linked worktree, without treating a sibling index as the local index.
- Reject SHA-256 repositories with an explicit unsupported-format error, including
  when combined with reftable, before constructing application history objects.
- Retain normal files-backend behavior, coverage floors, sanitizer correctness,
  and the dependency fork's build behavior under the full canonical workflow.

Implement the dependency integration in a reviewed change on the
`hbmartin/objective-git` fork before updating the application's pinned gitlink.
