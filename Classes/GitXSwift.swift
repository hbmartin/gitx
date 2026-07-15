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
