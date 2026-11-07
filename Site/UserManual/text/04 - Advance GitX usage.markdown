### Advance GitX usage


While GitX can be used just fine without ever touching the terminal, some of
it's power can currently only be used through the command line utility.

You can install this utility by choosing "Enable Terminal Usage…" from GitX's menu. This will ask you if GitX is allowed to install the `gitx` utility in `/usr/local/bin`. After you have done this, you can use gitx from the terminal in any Git repository!

To become familiar with this utility, you can read it's short help message:

	Tirana:UserManual pieter$ gitx --help
	Usage: gitx --help
	   or: gitx (--commit|-h)
	   or: gitx <revlist options>

		-h, --help          print this help
		--commit, -c        start GitX in commit mode

	RevList options
		See 'man git-log' and 'man git-rev-list' for options you can pass to gitx

		--all                  show all branches
		<branch>               show specific branch
		 -- <path>             show commits touching paths

As you can see already, `gitx` has some useful options. To quickly start committing, use `gitx -c`.

However, to really make use of all the options, you should read the `git-log` and `git-rev-list` man-pages. Gitx takes most of the commands that normal git utilities also take.

For example, if you want to show commits that change lines with the word 'cool' in it, you can use:

	gitx -Scool

and to see commands that touch only files in the "Documentation" directory, you can use

	gitx -- Documentation

You can also specify which branches gitx should display, for example:

	gitx commit_view log_options --grep="fix" --author=Pieter

will show all commits in the `commit_view` and `log_options` branches that have the word 'fix' in their commit message and which are committed by Pieter.

If you have a lot of commits, you can choose to limit the output. For example,

	gitx -1000

will only show the first 1000 commits. Limiting commits can be useful in other contexts too. For example, if you want to know what you have committed that isn't on the remote yet, you can use

	gitx origin/master..

If there are changes both on a remote and on your local side, you can show them at once with the _symmetric set difference_:

	gitx --left-right origin/master...HEAD

will show commits that are only on your side OR only on the remote side. The `--left-right` options does some other magic: instead of the usual circles GitX uses in the branch lines, it will now use an arrow pointing left for commits only on the left side (that is, in `origin/master`), and an arrow to the right for commits only on the right side. For example, when I issued the same command on this repository, I got:

![Showing --left-right](images/UserManual/left-right.png)

You can also pipe any command that produces a diff to GitX to see its changes.
For example, to compare version 0.5 and version 0.6 of GitX, you can do the following:

	git diff v0.5 v0.6 | gitx

### Recovering commits with the reflog

Choose **View → Reflog** or **Reflog** in the repository sidebar. The default
list is this checkout’s HEAD reflog. Use the reference menu to inspect a local
branch’s reflog. Linked worktrees have separate HEAD reflogs and share branch
reflogs. Events appear newest first with their event time, actor, action, commit,
and subject. **Load More** retrieves the next page; refresh if Git changes the
reflog between pages.

Select an event to inspect its commit, including a commit no longer visible in
History after an amend or reset. **Compare with HEAD**, **Copy Commit Identifier**,
and **Create Recovery Branch…** use that captured commit. Creating a recovery
branch leaves the current checkout in place. Reflogs expire, and GitX cannot
recover objects Git has already removed.

**Reset Current Checkout to This Commit…** offers three modes:

| Mode | HEAD | Staging area | Working files |
|---|---|---|---|
| Soft (default) | Moves to the selected commit | Unchanged | Unchanged |
| Mixed | Moves to the selected commit | Replaced by the selected commit | Unchanged |
| Hard | Moves to the selected commit | Replaced by the selected commit | Replaced by the selected commit |

Review the checkout, target, and affected paths before confirming. Hard reset
also lists tracked edits and obstructing untracked or ignored files. It requires
a separate **Discard Changes and Reset** confirmation. A new, uniquely named
`recovery/…` branch preserves the previous committed history before every reset.
It does **not** back up uncommitted changes, and GitX does not create a stash. If
reset fails after backup creation, GitX identifies the retained recovery branch.

Changes to the repository, HEAD, index, or inspected files invalidate the preview:
open a fresh preview and confirm again. Reset is unavailable in bare repositories,
during unfinished Git operations, or when affected state cannot be inspected
completely. Hard reset also refuses hidden index entries (assume-unchanged or
skip-worktree), changed submodules, staged changes between a file and a submodule,
and nested repositories obstructing target files. Inspect these cases in Terminal
before proceeding.

Submodule working copies are never recursively reset. Git can still create an
empty submodule directory or remove a file or symlink in its way. The hard-reset
preview includes those paths, and changes to them require a fresh preview and
confirmation. Files inside an existing, unchanged submodule directory are preserved.
