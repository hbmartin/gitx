import AppKit

// Objective-C controller wiring calls these policies through GitX-Swift.h.
// swiftlint:disable unused_declaration

@objc(PBCommitRemotePresentation)
final nonisolated class CommitRemotePresentation: NSObject {
    @objc let remoteNames: [String]
    @objc let selectedRemoteName: String?
    @objc let canPush: Bool

    init(remoteNames: [String], selectedRemoteName: String?, canPush: Bool) {
        self.remoteNames = remoteNames
        self.selectedRemoteName = selectedRemoteName
        self.canPush = canPush
    }
}

@objc(PBCommitRemotePresentationPolicy)
final nonisolated class CommitRemotePresentationPolicy: NSObject {
    @objc(sortedRemoteNames:)
    static func sortedRemoteNames(_ remoteNames: [String]) -> [String] {
        remoteNames.sorted { left, right in
            left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    @objc(shouldResolveTrackingRemoteForRemoteNames:previousSelection:isBranch:)
    static func shouldResolveTrackingRemote(
        remoteNames: [String],
        previousSelection: String?,
        isBranch: Bool
    ) -> Bool {
        isBranch && !remoteNames.isEmpty && !remoteNames.contains(previousSelection ?? "")
    }

    @objc(presentationForRemoteNames:previousSelection:trackingRemoteName:isBranch:)
    static func presentation(
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

@objc(PBCommitSubmissionDisposition)
enum CommitSubmissionDisposition: Int {
    case accepted
    case mergeInProgress
    case noStagedChanges
    case messageTooShort
}

@objc(PBCommitSubmissionPlan)
final nonisolated class CommitSubmissionPlan: NSObject {
    @objc let disposition: CommitSubmissionDisposition
    @objc let shouldArmPendingPush: Bool

    init(disposition: CommitSubmissionDisposition, shouldArmPendingPush: Bool) {
        self.disposition = disposition
        self.shouldArmPendingPush = shouldArmPendingPush
    }
}

@objc(PBCommitSubmissionPolicy)
final nonisolated class CommitSubmissionPolicy: NSObject {
    @objc(planForMergeInProgress:stagedCount:messageLength:pushEnabled:pushRequested:isBranch:remoteName:)
    static func plan(
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

        let shouldArmPendingPush = disposition == .accepted
            && pushEnabled
            && pushRequested
            && isBranch
            && !(remoteName?.isEmpty ?? true)
        return CommitSubmissionPlan(
            disposition: disposition,
            shouldArmPendingPush: shouldArmPendingPush
        )
    }
}

@objc(PBCommitPushPlan)
final nonisolated class CommitPushPlan: NSObject {
    @objc let branchRef: PBGitRef
    @objc let remoteName: String

    init(branchRef: PBGitRef, remoteName: String) {
        self.branchRef = branchRef
        self.remoteName = remoteName
    }
}

@objc(PBCommitWorkflowState)
final nonisolated class CommitWorkflowState: NSObject {
    @objc var pendingBranchRef: PBGitRef?
    @objc var pendingRemoteName: String?
    @objc var pendingRememberedPushChoice: NSNumber?

    @objc(beginSubmissionWithPushChoice:canRemember:)
    func beginSubmission(pushChoice: Bool, canRemember: Bool) {
        pendingRememberedPushChoice = canRemember ? NSNumber(value: pushChoice) : nil
    }

    @objc(armWithBranchRef:remoteName:)
    func arm(branchRef: PBGitRef, remoteName: String) {
        pendingBranchRef = branchRef
        pendingRemoteName = remoteName
        NSLog("[GitX] Armed commit-and-push workflow")
    }

    @objc(clear)
    func clear() {
        if pendingBranchRef != nil || pendingRemoteName != nil || pendingRememberedPushChoice != nil {
            NSLog("[GitX] Cleared pending commit-and-push workflow")
        }
        pendingBranchRef = nil
        pendingRemoteName = nil
        pendingRememberedPushChoice = nil
    }

    @objc(consumePendingPush)
    func consumePendingPush() -> CommitPushPlan? {
        defer { clear() }
        guard let pendingBranchRef,
              let pendingRemoteName,
              !pendingRemoteName.isEmpty
        else { return nil }
        NSLog("[GitX] Consuming pending commit-and-push workflow")
        return CommitPushPlan(branchRef: pendingBranchRef, remoteName: pendingRemoteName)
    }
}

/// Rehosts the nib's lower Commit area into files-above/message-below split views.
@objc(PBCommitLayoutCoordinator)
final class CommitLayoutCoordinator: NSObject {
    private static let autosaveName = "CommitComposer"

    @objc(configureOuterSplitView:commitMessageView:unstagedTable:stagedTable:)
    static func configure(
        outerSplitView: NSSplitView,
        commitMessageView: NSTextView,
        unstagedTable: NSTableView,
        stagedTable: NSTableView
    ) {
        unstagedTable.allowsMultipleSelection = true
        stagedTable.allowsMultipleSelection = true

        guard let messagePane = commitMessageView.enclosingScrollView?.superview else {
            NSLog("[GitX] Commit layout could not find the message pane")
            return
        }
        if let existing = messagePane.superview as? NSSplitView,
           existing.autosaveName == autosaveName
        {
            return
        }
        guard let fileSplitView = messagePane.superview as? NSSplitView,
              outerSplitView.subviews.contains(fileSplitView)
        else {
            NSLog("[GitX] Commit layout could not find the staging split view")
            return
        }

        let composerSplitView = NSSplitView(frame: fileSplitView.frame)
        let savedFramesKey = "NSSplitView Subview Frames \(autosaveName)"
        let hadSavedFrames = UserDefaults.standard.object(forKey: savedFramesKey) != nil
        composerSplitView.autosaveName = autosaveName
        composerSplitView.dividerStyle = .thin
        composerSplitView.isVertical = false
        composerSplitView.autoresizingMask = [.width, .height]

        messagePane.removeFromSuperview()
        outerSplitView.replaceSubview(fileSplitView, with: composerSplitView)
        composerSplitView.addSubview(fileSplitView)
        composerSplitView.addSubview(messagePane)
        composerSplitView.adjustSubviews()

        if !hadSavedFrames {
            let fileRowHeight = max(100, composerSplitView.bounds.height * 0.45)
            composerSplitView.setPosition(fileRowHeight, ofDividerAt: 0)
        } else {
            composerSplitView.pb_restoreAutosavedPositions()
        }
        NSLog("[GitX] Configured full-width commit message row")
    }
}

@objc(PBCommitMessageResult)
final nonisolated class CommitMessageResult: NSObject {
    @objc let message: String
    @objc let didAddSignOff: Bool

    init(message: String, didAddSignOff: Bool) {
        self.message = message
        self.didAddSignOff = didAddSignOff
    }
}

@objc(PBCommitMessagePolicy)
final nonisolated class CommitMessagePolicy: NSObject {
    @objc(messageByAddingSignOffToMessage:userName:userEmail:)
    static func messageByAddingSignOff(
        to message: String,
        userName: String,
        userEmail: String
    ) -> CommitMessageResult {
        let format = NSLocalizedString(
            "Signed-off-by: %@ <%@>",
            comment: "Signed off message format. Most likely this should not be localised."
        )
        let signOff = String(format: format, userName, userEmail)
        guard !message.contains(signOff) else {
            return CommitMessageResult(message: message, didAddSignOff: false)
        }
        return CommitMessageResult(message: "\(message)\n\n\(signOff)", didAddSignOff: true)
    }

    @objc(shouldReplaceMessageForAmendWithCurrentMessage:)
    static func shouldReplaceMessageForAmend(currentMessage: String) -> Bool {
        currentMessage.utf16.count <= 3
    }
}

@objc(PBCommitSelectionPolicy)
final nonisolated class CommitSelectionPolicy: NSObject {
    @objc(selectionIndexForCurrentIndex:arrangedCount:)
    static func selectionIndex(currentIndex: Int, arrangedCount: Int) -> Int {
        guard arrangedCount > 0 else { return NSNotFound }
        return min(currentIndex, arrangedCount - 1)
    }
}

// swiftlint:enable unused_declaration
