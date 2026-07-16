import Foundation

// Objective-C controller wiring calls this presenter through GitX-Swift.h.
// swiftlint:disable unused_declaration

@objc(PBCommitMenuFile)
final nonisolated class CommitMenuFile: NSObject {
    @objc let path: String
    @objc let status: Int
    @objc let hasUnstagedChanges: Bool

    @objc(initWithPath:status:hasUnstagedChanges:)
    init(path: String, status: Int, hasUnstagedChanges: Bool) {
        self.path = path
        self.status = status
        self.hasUnstagedChanges = hasUnstagedChanges
    }
}

@objc(PBCommitMenuPresentation)
final nonisolated class CommitMenuPresentation: NSObject {
    @objc let title: String?
    @objc let enabled: Bool
    @objc let updatesHidden: Bool
    @objc let hidden: Bool
    @objc let updatesAlternate: Bool
    @objc let alternate: Bool
    @objc let updatesState: Bool
    @objc let state: Int

    fileprivate init(mutation: CommitMenuMutation) {
        title = mutation.title
        enabled = mutation.enabled
        updatesHidden = mutation.hidden != nil
        hidden = mutation.hidden ?? false
        updatesAlternate = mutation.alternate != nil
        alternate = mutation.alternate ?? false
        updatesState = mutation.state != nil
        state = mutation.state ?? 0
    }
}

private nonisolated struct CommitMenuMutation {
    let title: String?
    let enabled: Bool
    let hidden: Bool?
    let alternate: Bool?
    let state: Int?

    init(
        title: String? = nil,
        enabled: Bool,
        hidden: Bool? = nil,
        alternate: Bool? = nil,
        state: Int? = nil
    ) {
        self.title = title
        self.enabled = enabled
        self.hidden = hidden
        self.alternate = alternate
        self.state = state
    }
}

private nonisolated enum CommitMenuAction: String {
    case stage = "stageFiles:"
    case unstage = "unstageFiles:"
    case discard = "discardFiles:"
    case forceDiscard = "discardFilesForcibly:"
    case trash = "moveToTrash:"
    case open = "openFiles:"
    case ignore = "ignoreFiles:"
    case reveal = "revealInFinder:"
    case amend = "toggleAmendCommit:"
    case prepare = "prepareCommitMessage:"

    init?(selector: Selector?) {
        guard let selector else { return nil }
        self.init(rawValue: NSStringFromSelector(selector))
    }
}

@objc(PBCommitMenuPresenter)
final nonisolated class CommitMenuPresenter: NSObject {
    @objc(presentationForAction:unstagedFiles:stagedFiles:isStagedContext:allowsTrash:isContextualMenu:singleSelectionIsSubmodule:isAmend:prepareHookExists:fallbackEnabled:)
    static func presentation(
        action: Selector?,
        unstagedFiles: [CommitMenuFile],
        stagedFiles: [CommitMenuFile],
        isStagedContext: Bool,
        allowsTrash: Bool,
        isContextualMenu: Bool,
        singleSelectionIsSubmodule: Bool,
        isAmend: Bool,
        prepareHookExists: Bool,
        fallbackEnabled: Bool
    ) -> CommitMenuPresentation {
        let action = CommitMenuAction(selector: action)
        let selectedFiles = isStagedContext ? stagedFiles : unstagedFiles
        let mutation: CommitMenuMutation

        switch action {
        case .stage:
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: unstagedFiles,
                    single: NSLocalizedString("Stage “%@”", comment: "Stage file menu item (single file with name)"),
                    multiple: NSLocalizedString("Stage %i Files", comment: "Stage file menu item (multiple files with number)"),
                    empty: NSLocalizedString("Stage", comment: "Stage file menu item (empty selection)")
                ),
                enabled: !unstagedFiles.isEmpty,
                hidden: contextualValue(isContextualMenu, unstagedFiles.isEmpty)
            )
        case .unstage:
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: stagedFiles,
                    single: NSLocalizedString("Unstage “%@”", comment: "Unstage file menu item (single file with name)"),
                    multiple: NSLocalizedString("Unstage %i Files", comment: "Unstage file menu item (multiple files with number)"),
                    empty: NSLocalizedString("Unstage", comment: "Unstage file menu item (empty selection)")
                ),
                enabled: !stagedFiles.isEmpty,
                hidden: contextualValue(isContextualMenu, stagedFiles.isEmpty)
            )
        case .discard:
            let shouldTrash = shouldTrashInsteadOfDiscard(unstagedFiles)
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: unstagedFiles,
                    single: NSLocalizedString(
                        "Discard changes to “%@”…",
                        comment: "Discard changes menu item (single file with name)"
                    ),
                    multiple: NSLocalizedString(
                        "Discard changes to %i Files…",
                        comment: "Discard changes menu item (multiple files with number)"
                    ),
                    empty: NSLocalizedString("Discard…", comment: "Discard changes menu item (empty selection)")
                ),
                enabled: canDiscard(unstagedFiles),
                hidden: contextualValue(isContextualMenu, shouldTrash)
            )
        case .forceDiscard:
            let shouldHide = shouldTrashInsteadOfDiscard(unstagedFiles)
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: unstagedFiles,
                    single: NSLocalizedString(
                        "Discard changes to “%@”",
                        comment: "Force Discard changes menu item (single file with name)"
                    ),
                    multiple: NSLocalizedString(
                        "Discard changes to  %i Files",
                        comment: "Force Discard changes menu item (multiple files with number)"
                    ),
                    empty: NSLocalizedString("Discard", comment: "Force Discard changes menu item (empty selection)")
                ),
                enabled: canDiscard(unstagedFiles),
                hidden: contextualValue(isContextualMenu, shouldHide),
                alternate: contextualValue(isContextualMenu, !shouldHide)
            )
        case .trash:
            let isVisible = shouldTrashInsteadOfDiscard(unstagedFiles) && allowsTrash
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: unstagedFiles,
                    single: NSLocalizedString("Move “%@” to Trash", comment: "Move to Trash menu item (single file with name)"),
                    multiple: NSLocalizedString("Move %i Files to Trash", comment: "Move to Trash menu item (multiple files with number)"),
                    empty: NSLocalizedString("Move to Trash", comment: "Move to Trash menu item (empty selection)")
                ),
                enabled: canDiscard(unstagedFiles),
                hidden: contextualValue(isContextualMenu, !isVisible)
            )
        case .open:
            mutation = CommitMenuMutation(
                title: openTitle(
                    isContextualMenu: isContextualMenu,
                    files: selectedFiles,
                    singleSelectionIsSubmodule: singleSelectionIsSubmodule
                ),
                enabled: !selectedFiles.isEmpty
            )
        case .ignore:
            let isActive = !selectedFiles.isEmpty && !isStagedContext
            mutation = CommitMenuMutation(
                title: contextualTitle(
                    isContextualMenu,
                    files: selectedFiles,
                    single: NSLocalizedString("Ignore “%@”", comment: "Ignore File menu item (single file with name)"),
                    multiple: NSLocalizedString("Ignore %i Files", comment: "Ignore File menu item (multiple files with number)"),
                    empty: NSLocalizedString("Ignore", comment: "Ignore File menu item (empty selection)")
                ),
                enabled: isActive,
                hidden: contextualValue(isContextualMenu, !isActive)
            )
        case .reveal:
            let isActive = selectedFiles.count == 1
            let title: String? = if isContextualMenu {
                isActive
                    ? String(
                        format: NSLocalizedString(
                            "Reveal “%@” in Finder",
                            comment: "Reveal File in Finder contextual menu item (single file with name)"
                        ),
                        lastPathComponent(selectedFiles[0].path)
                    )
                    : NSLocalizedString(
                        "Reveal in Finder",
                        comment: "Reveal File in Finder contextual menu item (empty selection)"
                    )
            } else {
                nil
            }
            mutation = CommitMenuMutation(
                title: title,
                enabled: isActive,
                hidden: contextualValue(isContextualMenu, !isActive)
            )
        case .amend:
            mutation = CommitMenuMutation(enabled: true, state: isAmend ? 1 : 0)
        case .prepare:
            mutation = CommitMenuMutation(enabled: prepareHookExists)
        case nil:
            mutation = CommitMenuMutation(enabled: fallbackEnabled)
        }

        return CommitMenuPresentation(mutation: mutation)
    }

    private static func canDiscard(_ files: [CommitMenuFile]) -> Bool {
        !files.isEmpty && files.contains(where: \.hasUnstagedChanges)
    }

    private static func shouldTrashInsteadOfDiscard(_ files: [CommitMenuFile]) -> Bool {
        files.allSatisfy { $0.status == 0 }
    }

    private static func contextualValue(_ isContextualMenu: Bool, _ value: Bool) -> Bool? {
        isContextualMenu ? value : nil
    }

    private static func contextualTitle(
        _ isContextualMenu: Bool,
        files: [CommitMenuFile],
        single: String,
        multiple: String,
        empty: String
    ) -> String? {
        guard isContextualMenu else { return nil }
        if files.isEmpty {
            return empty
        }
        if files.count == 1 {
            return String(format: single, lastPathComponent(files[0].path))
        }
        return String(format: multiple, Int32(clamping: files.count))
    }

    private static func openTitle(
        isContextualMenu: Bool,
        files: [CommitMenuFile],
        singleSelectionIsSubmodule: Bool
    ) -> String? {
        guard isContextualMenu, !files.isEmpty else { return nil }
        if files.count == 1, singleSelectionIsSubmodule {
            return String(
                format: NSLocalizedString(
                    "Open Submodule “%@” in GitX",
                    comment: "Open Submodule Repository in GitX menu item (single file with name)"
                ),
                (files[0].path as NSString).standardizingPath
            )
        }
        return contextualTitle(
            true,
            files: files,
            single: NSLocalizedString("Open “%@”", comment: "Open File menu item (single file with name)"),
            multiple: NSLocalizedString("Open %i Files", comment: "Open File menu item (multiple files with number)"),
            empty: NSLocalizedString("Open", comment: "Open File menu item (empty selection)")
        )
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// swiftlint:enable unused_declaration
