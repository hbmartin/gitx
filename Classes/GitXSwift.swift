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

import Cocoa

/// Supplies the refresh-on-focus preference to Objective-C controllers.
@objc(PBRepositoryRefreshPolicy)
final class RepositoryRefreshPolicy: NSObject { // swiftlint:disable:this unused_declaration
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

/// Tracks repository snapshots for Objective-C window controllers.
@objc(PBRepositoryFocusRefreshTracker)
final class RepositoryFocusRefreshTracker: NSObject { // swiftlint:disable:this unused_declaration
    private var previousSnapshotComponents: [Data]?

    @objc(shouldRefreshForSnapshotComponents:)
    func shouldRefresh(for snapshotComponents: [Data]) -> Bool { // swiftlint:disable:this unused_declaration
        defer { previousSnapshotComponents = snapshotComponents }
        guard let previousSnapshotComponents else { return false }
        return previousSnapshotComponents != snapshotComponents
    }

    @objc
    func reset() {
        previousSnapshotComponents = nil
    }
}

/// Decides whether a refs refresh should keep following the checked-out branch.
@objc(PBHistoryRefreshSelectionPolicy)
final class HistoryRefreshSelectionPolicy: NSObject { // swiftlint:disable:this unused_declaration
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
final class ReferenceActionPolicy: NSObject { // swiftlint:disable:this unused_declaration
    @objc(canPushRefishTypeToNamedRemote:)
    static func canPushToNamedRemote(refishType: String?) -> Bool { // swiftlint:disable:this unused_declaration
        [kGitXBranchType, kGitXTagType].contains(refishType)
    }

    @objc(canDeleteRefishType:)
    static func canDelete(refishType: String?) -> Bool { // swiftlint:disable:this unused_declaration
        [kGitXBranchType, kGitXRemoteType, kGitXRemoteBranchType, kGitXTagType].contains(refishType)
    }

    @objc(deletionMenuTitleForRefName:isRemote:)
    static func deletionMenuTitle(
        refName: String,
        isRemote: Bool
    ) -> String { // swiftlint:disable:this unused_declaration
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
    static func deletionConfirmationTitle(
        refishType: String,
        shortName: String
    ) -> String { // swiftlint:disable:this unused_declaration
        let verb = usesRemovalTerminology(refishType: refishType) ? "Remove" : "Delete"
        return "\(verb) \(refishType) '\(shortName)'?"
    }

    @objc(deletionConfirmationMessageForRefishType:shortName:)
    static func deletionConfirmationMessage(
        refishType: String,
        shortName: String
    ) -> String { // swiftlint:disable:this unused_declaration
        switch refishType {
        case kGitXRemoteBranchType:
            return "This removes only the local remote-tracking branch. "
                + "The branch on the remote server is left unchanged."
        case kGitXRemoteType:
            return "This removes the remote configuration and its local remote-tracking branches. "
                + "Branches on the remote server are left unchanged."
        default:
            return "Are you sure you want to delete the \(refishType) '\(shortName)'?"
        }
    }

    @objc(deletionConfirmationButtonTitleForRefishType:)
    static func deletionConfirmationButtonTitle(
        refishType: String
    ) -> String { // swiftlint:disable:this unused_declaration
        usesRemovalTerminology(refishType: refishType)
            ? NSLocalizedString("Remove", comment: "Remove remote ref alert - default button")
            : NSLocalizedString("Delete", comment: "Delete local ref alert - default button")
    }

    private static func usesRemovalTerminology(refishType: String) -> Bool {
        [kGitXRemoteType, kGitXRemoteBranchType].contains(refishType)
    }
}
