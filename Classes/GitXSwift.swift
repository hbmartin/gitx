// GitXSwift.swift
//
// Placeholder that activates the Swift compiler for the GitX target.
// Actual Swift source files will be added here incrementally as
// Objective-C files are converted one by one.
//
// Swift can call any Objective-C symbol that is imported in
// Classes/GitX-Bridging-Header.h
// Objective-C can call any Swift symbol that is visible in
// GitX-Swift.h  (generated automatically by the build system)

/// Chooses repository revisions in the order used to resolve image content.
@objc(PBImageRevisionPolicy)
final nonisolated class ImageRevisionPolicy: NSObject, Sendable { // swiftlint:disable:this unused_declaration
    @objc(revisionsForCommitSHA:parentSHA:workingState:)
    static func revisions( // swiftlint:disable:this unused_declaration
        commitSHA: String,
        parentSHA: String?,
        workingState: Bool
    ) -> [String] {
        guard !workingState, !commitSHA.isEmpty else { return [] }
        return [commitSHA, parentSHA].compactMap { $0 }
    }
}

/// Immutable commit metadata captured before history rendering leaves the main thread.
@objc(PBCommitRenderInput)
final nonisolated class CommitRenderInput: NSObject, Sendable { // swiftlint:disable:this unused_declaration
    @objc let sha: String
    @objc let parentSHA: String?
    @objc let shortName: String
    @objc let title: String
    @objc let imageRevisions: [String]

    @objc(initWithSHA:parentSHA:shortName:subject:author:authorDate:)
    init(
        sha: String,
        parentSHA: String?,
        shortName: String,
        subject: String,
        author: String,
        authorDate: String
    ) {
        self.sha = sha
        self.parentSHA = parentSHA
        self.shortName = shortName
        title = "\(shortName)  \(subject)\n\(author) — \(authorDate)"
        imageRevisions = ImageRevisionPolicy.revisions(
            commitSHA: sha,
            parentSHA: parentSHA,
            workingState: false
        )
    }
}

/// Avoids replacing a visible Working State document when only its refresh notification changed.
@objc(PBWorkingStateRefreshPolicy)
final nonisolated class WorkingStateRefreshPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(shouldReplaceDisplayedDiff:renderedDiff:)
    static func shouldReplaceDisplayedDiff( // swiftlint:disable:this unused_declaration
        _ displayedDiff: String?,
        renderedDiff: String
    ) -> Bool {
        displayedDiff != renderedDiff
    }
}

/// Shared performance budgets for repository view switching and Working State feedback.
@objc(PBPerformanceBudgets)
final nonisolated class PerformanceBudgets: NSObject { // swiftlint:disable:this unused_declaration
    @objc static let warmViewSwitchP95Seconds = 0.050
    @objc static let mainThreadBlockSeconds = 0.016
    @objc static let cachedWorkingStateFeedbackSeconds = 0.050
    @objc static let freshWorkingStateP95Seconds = 0.250
    @objc static let representativeChangedFileCount = 500
    @objc static let representativeDiffByteCount = 1_048_576
    @objc static let stressChangedFileCount = 5000
    @objc static let stressDiffByteCount = 10_485_760
}

/// A rendered Working State model retained only by its repository window.
@objc(PBWorkingStateDiffSnapshot)
final class WorkingStateDiffSnapshot: NSObject { // swiftlint:disable:this unused_declaration
    @objc let sections: [[String: Any]]
    @objc let renderedDiff: String

    init(sections: [[String: Any]], renderedDiff: String) {
        self.sections = sections
        self.renderedDiff = renderedDiff
    }
}

/// Keeps one memory-only Working State snapshot for each diff layout.
@objc(PBWorkingStateDiffCache)
final class WorkingStateDiffCache: NSObject { // swiftlint:disable:this unused_declaration
    private var snapshots: [Int: WorkingStateDiffSnapshot] = [:]

    @objc(snapshotForLayout:)
    func snapshot(forLayout layout: Int) -> WorkingStateDiffSnapshot? {
        snapshots[layout]
    }

    @objc(storeSections:renderedDiff:layout:)
    func store(sections: [[String: Any]], renderedDiff: String, layout: Int) {
        snapshots[layout] = WorkingStateDiffSnapshot(
            sections: sections,
            renderedDiff: renderedDiff
        )
    }

    @objc func removeAll() {
        snapshots.removeAll()
    }
}

/// A single layer-backed surface for the transient search-wrap indicator.
@objc(PBRewindOverlayView)
final class RewindOverlayView: NSView { // swiftlint:disable:this unused_declaration
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PBRewindOverlayView is created programmatically")
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.5).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.5).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
    }
}

/// Supplies the refresh-on-focus preference to Objective-C controllers.
@objc(PBRepositoryRefreshPolicy)
final nonisolated class RepositoryRefreshPolicy: NSObject { // swiftlint:disable:this unused_declaration
    static let refreshOnApplicationFocusKey = "PBRefreshOnApplicationFocus"

    @objc(shouldRefreshAfterApplicationActivation)
    static func shouldRefreshAfterApplicationActivation() -> Bool { // swiftlint:disable:this unused_declaration
        shouldRefreshAfterApplicationActivation(userDefaults: .standard)
    }

    @objc(shouldRefreshStatCacheAfterApplicationActivation)
    static func shouldRefreshStatCacheAfterApplicationActivation() -> Bool { // swiftlint:disable:this unused_declaration
        !shouldRefreshAfterApplicationActivation()
    }

    static func shouldRefreshAfterApplicationActivation(userDefaults: UserDefaults) -> Bool {
        userDefaults.bool(forKey: refreshOnApplicationFocusKey)
    }
}

/// Decides whether a refs refresh should keep following the checked-out branch.
@objc(PBHistoryRefreshSelectionPolicy)
final nonisolated class HistoryRefreshSelectionPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(shouldFollowCheckedOutBranchWithStageSelected:viewedRef:previousHeadRef:)
    // Called through PBHistoryRefreshSelectionPolicy's Objective-C selector.
    // swiftlint:disable:next unused_declaration
    static func shouldFollowCheckedOutBranch(
        stageSelected: Bool,
        viewedRef: String?,
        previousHeadRef: String?
    ) -> Bool {
        !stageSelected && viewedRef != nil && viewedRef == previousHeadRef
    }
}

/// Keeps reference-action eligibility and menu wording out of AppKit controllers.
@objc(PBReferenceActionPolicy)
final nonisolated class ReferenceActionPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(canPushRefishTypeToNamedRemote:)
    static func canPushToNamedRemote(refishType: String?) -> Bool { // swiftlint:disable:this unused_declaration
        [kGitXBranchType, kGitXTagType].contains(refishType)
    }

    @objc(canDeleteRefishType:)
    static func canDelete(refishType: String?) -> Bool { // swiftlint:disable:this unused_declaration
        [kGitXBranchType, kGitXRemoteType, kGitXRemoteBranchType, kGitXTagType].contains(refishType)
    }

    @objc(deletionMenuTitleForRefName:isRemote:)
    // swiftlint:disable:next unused_declaration
    static func deletionMenuTitle(
        refName: String,
        isRemote: Bool
    ) -> String {
        let format = isRemote
            ? NSLocalizedString(
                "Remove “%@”…",
                comment: "Contextual menu item to remove a local remote or remote-tracking ref"
            )
            : NSLocalizedString(
                "Delete “%@”…",
                comment: "Contextual menu item to delete a local ref (e.g. branch)"
            )
        return String(format: format, refName)
    }

    @objc(deletionConfirmationTitleForRefishType:shortName:)
    // swiftlint:disable:next unused_declaration
    static func deletionConfirmationTitle(
        refishType: String,
        shortName: String
    ) -> String {
        let format = usesRemovalTerminology(refishType: refishType)
            ? NSLocalizedString(
                "Remove %@ '%@'?",
                comment: "Confirmation title for removing a local remote or remote-tracking ref"
            )
            : NSLocalizedString(
                "Delete %@ '%@'?",
                comment: "Confirmation title for deleting a local branch or tag"
            )
        return String(format: format, refishType, shortName)
    }

    @objc(deletionConfirmationMessageForRefishType:shortName:)
    // swiftlint:disable:next unused_declaration
    static func deletionConfirmationMessage(
        refishType: String,
        shortName: String
    ) -> String {
        switch refishType {
        case kGitXRemoteBranchType:
            return NSLocalizedString(
                "This removes only the local remote-tracking branch. The branch on the remote server is left unchanged.",
                comment: "Explanation shown before removing a remote-tracking branch"
            )
        case kGitXRemoteType:
            return NSLocalizedString(
                "This removes the remote configuration and its local remote-tracking branches. Branches on the remote server are left unchanged.",
                comment: "Explanation shown before removing a remote configuration"
            )
        default:
            let format = NSLocalizedString(
                "Are you sure you want to delete the %@ '%@'?",
                comment: "Explanation shown before deleting a local branch or tag"
            )
            return String(format: format, refishType, shortName)
        }
    }

    @objc(deletionConfirmationButtonTitleForRefishType:)
    // swiftlint:disable:next unused_declaration
    static func deletionConfirmationButtonTitle(
        refishType: String
    ) -> String {
        usesRemovalTerminology(refishType: refishType)
            ? NSLocalizedString("Remove", comment: "Remove remote ref alert - default button")
            : NSLocalizedString("Delete", comment: "Delete local ref alert - default button")
    }

    private static func usesRemovalTerminology(refishType: String) -> Bool {
        [kGitXRemoteType, kGitXRemoteBranchType].contains(refishType)
    }
}

/// Plans configured-remote changes while preserving nodes backed by tracking refs.
@objc(PBRemoteSidebarSyncPlan)
final nonisolated class RemoteSidebarSyncPlan: NSObject, Sendable { // swiftlint:disable:this unused_declaration
    @objc let namesToAdd: [String]
    @objc let namesToRemove: [String]

    private init(namesToAdd: [String], namesToRemove: [String]) {
        self.namesToAdd = namesToAdd
        self.namesToRemove = namesToRemove
    }

    @objc(planWithConfiguredRemoteNames:existingRemoteNames:nonEmptyRemoteNames:)
    // swiftlint:disable:next unused_declaration
    static func make(
        configuredRemoteNames: [String],
        existingRemoteNames: [String],
        nonEmptyRemoteNames: [String]
    ) -> RemoteSidebarSyncPlan {
        let configured = Set(configuredRemoteNames)
        let existing = Set(existingRemoteNames)
        let nonEmpty = Set(nonEmptyRemoteNames)
        return RemoteSidebarSyncPlan(
            namesToAdd: sorted(configured.subtracting(existing)),
            namesToRemove: sorted(existing.subtracting(configured).subtracting(nonEmpty))
        )
    }

    private static func sorted(_ names: Set<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Canonicalizes persisted Git defaults before the Objective-C facade stores them.
@objc(PBGitDefaultsPolicy)
final nonisolated class GitDefaultsPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(validatedAutoFetchScopeRawValue:)
    // swiftlint:disable:next unused_declaration
    static func validatedAutoFetchScope(
        rawValue: Int
    ) -> Int {
        let validRange = PBAutoFetchScope.none.rawValue ... PBAutoFetchScope.openAndRecentRepositories.rawValue
        return validRange.contains(rawValue) ? rawValue : PBAutoFetchScope.none.rawValue
    }

    @objc(repositoryDefaultsKeyForURL:)
    // swiftlint:disable:next unused_declaration
    static func repositoryDefaultsKey(
        for repositoryURL: URL
    ) -> String {
        repositoryURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
