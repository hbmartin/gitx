# Modularization Follow-ups: Defects and UX

These observations were discovered while extracting `GitXCore`. They are intentionally not behavior changes in the modularization work.

## Defects

1. **Sidebar branch-change selection can use `NSNotFound`.** The `currentBranch` observer rebuilds an index set directly from `selectedRow`. When there is no selection, `-1` crosses into an unsigned index and can produce an invalid selection request. Preserve no-selection explicitly and clamp restored rows after reload.
2. **Sidebar edit validation emits a stray log.** `outlineView:shouldEditTableColumn:item:` logs `hi` whenever the item is a submodule even though editing is always rejected. Remove the debug log.
3. **The search recents separator has the title-item tag.** The separator after the recents placeholder is tagged `NSSearchFieldRecentsTitleMenuItemTag`. Leave the separator untagged so AppKit sees exactly one recents title item.
4. **Raw and path search preserve empty whitespace arguments.** Splitting on every whitespace character emits empty Git arguments for repeated spaces. Replace this with a documented tokenizer, with explicit tests for quoting, escaping, Unicode whitespace, and intentionally empty arguments.
5. **Terminal and remote choosers ignore their presenting window.** Several paths accept an `NSWindow` but call `runModal`; the Raycast directory expression runs the same app-modal call in both branches. Use sheets when a window exists and complete the action asynchronously.
6. **Two relative-date implementations coexist.** Both `.m` and `.swift` implementations are present while only the Objective-C implementation is built. Finish the tested migration or remove the unbuilt duplicate so ownership is unambiguous.

## Suggested UX Fixes

1. Use the glossary consistently: **Application Preferences**, **Repository Configuration**, and **Repository View State**. The current repository panel and remote alerts still say “Repository Settings.”
2. Make repository-configuration validation field-specific. Select the relevant tab, focus the invalid field or text line, and show the line number beside the control instead of only presenting a generic error.
3. Preserve search intent visibly. A raw/path search should show how its text was tokenized or reject malformed quoting before starting Git.
4. Keep sidebar selection stable when branches reload. If the selected ref disappears, select the current branch or nearest surviving item and announce the change for VoiceOver.
5. Use sheet-based terminal, remote, and folder selection so the originating repository window remains visually and behaviorally associated with the choice.

## Structural Debt

- Sidebar and history-search controllers still combine Cocoa wiring, menus, selection restoration, and task lifecycle. Continue moving decisions into `GitXCore`, then split wiring into focused Objective-C categories only when private state can remain explicit.
- Application preference change notifications are still global. A typed event adapter would improve test isolation, but it should follow measured need rather than become a general event framework.
- ObjectiveGit and Sparkle dominate clean workspace builds; package extraction alone cannot remove their fixed cost.
