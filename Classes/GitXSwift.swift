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

@objc(PBRepositoryRefreshPolicy)
final class RepositoryRefreshPolicy: NSObject {
    static let refreshOnApplicationFocusKey = "PBRefreshOnApplicationFocus"

    @objc(shouldRefreshAfterApplicationActivation)
    static func shouldRefreshAfterApplicationActivation() -> Bool {
        shouldRefreshAfterApplicationActivation(userDefaults: .standard)
    }

    static func shouldRefreshAfterApplicationActivation(userDefaults: UserDefaults) -> Bool {
        userDefaults.bool(forKey: refreshOnApplicationFocusKey)
    }
}

@objc(PBRepositoryFocusRefreshTracker)
final class RepositoryFocusRefreshTracker: NSObject {
    private var previousSnapshotComponents: [Data]?

    @objc(shouldRefreshForSnapshotComponents:)
    func shouldRefresh(for snapshotComponents: [Data]) -> Bool {
        defer { previousSnapshotComponents = snapshotComponents }
        guard let previousSnapshotComponents else { return false }
        return previousSnapshotComponents != snapshotComponents
    }

    @objc
    func reset() {
        previousSnapshotComponents = nil
    }
}
