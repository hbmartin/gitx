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

**Unverified Write**:
A repository capability whose write authority cannot be proven from Credential metadata but may be tested by an explicitly confirmed user operation. It is neither verified permission nor automatic authorization.
_Avoid_: Allowed, missing permission

**Forge Repository Binding**:
The per-user association among a local repository's Git remote, its Forge Repository, and the preferred Forge Account.
_Avoid_: Remote, account mapping

**Primary Forge Repository**:
The canonical Forge Repository identity for a local repository, which remains stable when the currently selected remote changes and supplies the Pull Requests, Issues, Check Rollups, and Review Rollups GitX presents.
_Avoid_: Current remote, tracking remote

**Pull Request**:
A proposed integration of changes from a head branch into a base branch on a Forge.
_Avoid_: Change request, merge request

**Update Branch**:
A separate, explicitly confirmed Pull Request action that asks the Forge to merge the current base branch into the head branch, then refreshes Forge state and local remote-tracking state. It is never performed automatically as part of Merge.
_Avoid_: Sync branch, automatic update

**Forge Overlay**:
Cached Forge state presented alongside local Git state without replacing or blocking it.
_Avoid_: Git state, remote tracking data

**Check Rollup**:
The normalized Forge result for all known checks associated with one commit or Pull Request: Succeeded, Failed, Running, Attention Required, or Neutral.
_Avoid_: Build status, CI status

**Review Rollup**:
The aggregate Forge review decision for a Pull Request: Approved, Changes Requested, Review Required, or No Decision. Personal review attention is a separate state.
_Avoid_: Review status, my review

**Review Thread**:
A sequence of Pull Request review comments anchored to a file, line, or contiguous same-side line range. A thread may be unresolved, resolved, or outdated independently of its comments.
_Avoid_: Conversation, timeline thread

**Suggested Change**:
A structured replacement proposed in a Review Thread. GitX may apply it as an unstaged edit only when the Pull Request head is checked out, the target file has no uncommitted edits, and the original context matches exactly.
_Avoid_: Patch, automatic commit

**Attention Inbox**:
GitX's account-wide, locally tracked collection of current actionable Pull Request, review, check, mention, and assignment states derived from Forge data. Its seen state belongs to GitX and does not claim to reproduce or modify the Forge's notification inbox.
_Avoid_: GitHub Notifications, notification mirror

**Attention Item**:
One current actionable state in the Attention Inbox, identified independently of the comments or checks from which GitX derived it.
_Avoid_: Notification event, activity-log entry

**Watched Forge Repository**:
A Forge Repository that a user has explicitly included in an account's Attention Inbox. Opening or binding a repository in GitX adds it to the watched set; the user may remove it in Preferences.
_Avoid_: GitHub watched repository, subscribed repository

**Forge Draft**:
Unpublished Forge-authored text that GitX autosaves for one exact Forge Account and destination until it is published, discarded, expired, or removed with the account.
_Avoid_: Draft Pull Request, exported draft
