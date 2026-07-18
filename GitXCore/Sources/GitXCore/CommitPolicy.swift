import Foundation

public struct CommitRemotePresentation: Equatable, Sendable {
    public let remoteNames: [String]
    public let selectedRemoteName: String?
    public let canPush: Bool

    public init(remoteNames: [String], selectedRemoteName: String?, canPush: Bool) {
        self.remoteNames = remoteNames
        self.selectedRemoteName = selectedRemoteName
        self.canPush = canPush
    }
}

public enum CommitRemotePresentationPolicy {
    public static func sortedRemoteNames(_ remoteNames: [String]) -> [String] {
        remoteNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public static func shouldResolveTrackingRemote(
        remoteNames: [String],
        previousSelection: String?,
        isBranch: Bool
    ) -> Bool {
        isBranch && !remoteNames.isEmpty && !remoteNames.contains(previousSelection ?? "")
    }

    public static func presentation(
        remoteNames: [String],
        previousSelection: String?,
        trackingRemoteName: String?,
        isBranch: Bool
    ) -> CommitRemotePresentation {
        guard !remoteNames.isEmpty else {
            return CommitRemotePresentation(remoteNames: [], selectedRemoteName: nil, canPush: false)
        }

        let selectedRemoteName: String
        if let previousSelection, remoteNames.contains(previousSelection) {
            selectedRemoteName = previousSelection
        } else if isBranch, let trackingRemoteName, remoteNames.contains(trackingRemoteName) {
            selectedRemoteName = trackingRemoteName
        } else if remoteNames.contains("origin") {
            selectedRemoteName = "origin"
        } else {
            selectedRemoteName = remoteNames[0]
        }

        return CommitRemotePresentation(
            remoteNames: remoteNames,
            selectedRemoteName: selectedRemoteName,
            canPush: isBranch
        )
    }
}

public enum CommitSubmissionDisposition: Int, Sendable {
    case accepted
    case mergeInProgress
    case noStagedChanges
    case messageTooShort
}

public struct CommitSubmissionPlan: Equatable, Sendable {
    public let disposition: CommitSubmissionDisposition
    public let shouldArmPendingPush: Bool

    public init(disposition: CommitSubmissionDisposition, shouldArmPendingPush: Bool) {
        self.disposition = disposition
        self.shouldArmPendingPush = shouldArmPendingPush
    }
}

public enum CommitSubmissionPolicy {
    public static func plan(
        mergeInProgress: Bool,
        stagedCount: Int,
        messageLength: Int,
        pushEnabled: Bool,
        pushRequested: Bool,
        isBranch: Bool,
        remoteName: String?
    ) -> CommitSubmissionPlan {
        let disposition: CommitSubmissionDisposition
        if mergeInProgress {
            disposition = .mergeInProgress
        } else if stagedCount == 0 {
            disposition = .noStagedChanges
        } else if messageLength < 3 {
            disposition = .messageTooShort
        } else {
            disposition = .accepted
        }

        return CommitSubmissionPlan(
            disposition: disposition,
            shouldArmPendingPush: disposition == .accepted
                && pushEnabled
                && pushRequested
                && isBranch
                && !(remoteName?.isEmpty ?? true)
        )
    }
}
