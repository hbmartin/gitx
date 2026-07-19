# GitX Repository History

GitX presents immutable repository history alongside the repository's mutable working state. These terms distinguish revisions, selections, and comparisons consistently across History, Tree, and Commit views.

## Language

**Commit**:
An immutable Git revision stored in the repository object database.
_Avoid_: Revision when specifically referring to a stored commit

**Working State**:
The mutable combination of staged, unstaged, untracked, and deleted content in a repository checkout.
_Avoid_: Working commit, fake commit

**Uncommitted Changes**:
The selectable History entry that represents the current Working State rather than a Commit.
_Avoid_: Dirty commit, working-tree commit

**History View**:
The repository perspective for inspecting immutable Commits alongside the selectable Uncommitted Changes entry.
_Avoid_: History mode, revisions view

**Commit View**:
The repository perspective for staging Working State changes and composing the next Commit.
_Avoid_: Stage view, commit mode

**Sequential Diff**:
The ordered presentation of each selected Commit's own patch, from oldest to newest.
_Avoid_: Combined diff, aggregate diff

**Combined Diff**:
The single net patch spanning the first parent of the oldest selected Commit through the newest selected Commit on one ancestry path.
_Avoid_: Sequential diff, merge diff

**File Mode**:
One of Source, Blame, History, or Diff used to inspect selected files in the Tree view.
_Avoid_: Tab, scope

**Scheduled Fetch**:
A noninteractive background fetch performed for repositories selected by the global auto-refresh scope.
_Avoid_: Pull, background sync

**Recent Repository**:
A previously opened repository offered for reopening from GitX's welcome experience.
_Avoid_: Recent, repo

**Initializable Folder**:
An existing folder that is not inside a Git repository and has no `.git` metadata, which GitX may offer to initialize as a repository.
_Avoid_: Invalid repository, empty repository

**Application Preferences**:
Choices that apply across GitX regardless of which repository is open.
_Avoid_: Global settings, app configuration

**Repository Configuration**:
Repository-owned choices that travel with or describe one Git repository.
_Avoid_: Repository preferences, repository settings

**Repository View State**:
Per-user presentation state remembered separately for each repository.
_Avoid_: Repository configuration, repository preferences

## Forge Integration

**Forge**:
A hosted collaboration service endpoint identified by its scheme and host, such as `https://github.com`.
_Avoid_: Provider, vendor

**Forge Kind**:
The family of link and API semantics implemented by a Forge, such as GitHub, GitLab, or Bitbucket.
_Avoid_: Forge, host

**Forge Repository**:
A repository hosted by a Forge and identified within that Forge by its owner and name.
_Avoid_: Local repository, Git remote

**Forge Account**:
A user identity authenticated with one Forge. A Forge Account has one current Credential.
_Avoid_: Git account, credential

**Credential**:
The single current authorization for a Forge Account, sourced from a GitHub App, GitHub CLI, or personal access token.
_Avoid_: Account, identity

**Forge Repository Binding**:
The per-user association among a local repository's Git remote, its Forge Repository, and the preferred Forge Account.
_Avoid_: Remote, account mapping

**Primary Forge Repository**:
The stable Forge Repository whose repository-level Pull Requests, Issues, checks, and reviews GitX presents for a local repository.
_Avoid_: Current remote, tracking remote

**Pull Request**:
A proposed integration of changes from a head branch into a base branch on a Forge.
_Avoid_: Change request, merge request

**Forge Overlay**:
Cached Forge state presented alongside local Git state without replacing or blocking it.
_Avoid_: Git state, remote tracking data

**Check Rollup**:
The normalized Forge result for all known checks associated with one commit or Pull Request: Succeeded, Failed, Running, Attention Required, or Neutral.
_Avoid_: Build status, CI status

**Review Rollup**:
The aggregate Forge review decision for a Pull Request: Approved, Changes Requested, Review Required, or No Decision. Personal review attention is a separate state.
_Avoid_: Review status, my review
