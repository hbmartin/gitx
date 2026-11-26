# Modularization Follow-ups: Defects and UX

These observations were discovered while extracting `GitXCore`. They are intentionally not behavior changes in the modularization work.

## Defects

All six defects are resolved.

1. **Sidebar branch-change selection could use `NSNotFound`.** Resolved by the Swift conversion of `PBGitSidebarController`: the `currentBranch` observer restores selection through `selectCurrentBranch()` and never rebuilds an index set from `selectedRow`.
2. **Sidebar edit validation emitted a stray log.** Resolved by the same conversion; `outlineView(_:shouldEdit:item:)` rejects editing without logging.
3. **The search recents separator had the title-item tag.** Resolved: only the "Recent Searches" item carries `NSSearchFieldRecentsTitleMenuItemTag`.
4. **Raw and path search split on every whitespace character.** Resolved: GitXCore's `HistorySearchArgumentSyntax` tokenizes raw and path searches with single quotes, double quotes, and backslash escapes for whitespace, quotes, and backslash. Repeated whitespace no longer produces empty arguments, and explicitly empty quotes are rejected before Git starts.
5. **Terminal and remote choosers ignored their presenting window.** Resolved: `WindowModalPresenter` presents the terminal, Raycast folder, Raycast replacement, and forge repository choices as sheets on the asking window and completes asynchronously.
6. **Two relative-date implementations coexisted.** Resolved: GitXCore's `RelativeDatePolicy` owns classification and wording, and the Swift `GitXRelativeDateFormatter` adapter is the only app implementation.

## Suggested UX Fixes

All five suggestions are implemented.

1. The repository menu, panel title, View Remote alerts, and Application Preferences text say **Repository Configuration**.
2. Repository Configuration validation selects the tab that owns the invalid value, focuses the control, selects the offending line, and explains the issue beside Save. VoiceOver announces it.
3. A malformed raw or path search starts no Git process. The match field shows a short summary, its tooltip explains the fix, and VoiceOver announces both. Background searches show their parsed Git arguments in the tooltip.
4. When a passive reload removes the viewed reference, the sidebar selects the checked-out branch and announces "<name> no longer exists. Showing <branch>." Mounted content is preserved.
5. Terminal, remote, and folder choices are sheets on the originating repository window.

## Structural Debt

- Sidebar and history-search controllers still combine Cocoa wiring, menus, selection restoration, and task lifecycle. Continue moving decisions into `GitXCore`, then split wiring into focused Objective-C categories only when private state can remain explicit.
- Application preference change notifications are still global. A typed event adapter would improve test isolation, but it should follow measured need rather than become a general event framework.
- ObjectiveGit and Sparkle dominate clean workspace builds; package extraction alone cannot remove their fixed cost.
