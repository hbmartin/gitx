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
