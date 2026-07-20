@testable import GitXCore
import XCTest

final class CommitPolicyTests: XCTestCase {
    func testRemotePresentationUsesExistingPrecedence() {
        let names = CommitRemotePresentationPolicy.sortedRemoteNames(["zebra", "Origin", "backup"])
        XCTAssertEqual(names, ["backup", "Origin", "zebra"])
        XCTAssertFalse(CommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: names,
            previousSelection: "Origin",
            isBranch: true
        ))
        XCTAssertTrue(CommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: names,
            previousSelection: "missing",
            isBranch: true
        ))
        XCTAssertTrue(CommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: names,
            previousSelection: nil,
            isBranch: true
        ))
        XCTAssertEqual(
            CommitRemotePresentationPolicy.presentation(
                remoteNames: names,
                previousSelection: nil,
                trackingRemoteName: "backup",
                isBranch: true
            ),
            CommitRemotePresentation(remoteNames: names, selectedRemoteName: "backup", canPush: true)
        )
        XCTAssertEqual(
            CommitRemotePresentationPolicy.presentation(
                remoteNames: ["backup", "origin"],
                previousSelection: nil,
                trackingRemoteName: nil,
                isBranch: false
            ).selectedRemoteName,
            "origin"
        )
        XCTAssertEqual(
            CommitRemotePresentationPolicy.presentation(
                remoteNames: [],
                previousSelection: "origin",
                trackingRemoteName: "origin",
                isBranch: true
            ),
            CommitRemotePresentation(remoteNames: [], selectedRemoteName: nil, canPush: false)
        )
    }

    func testRemotePresentationPreservesSelectionAndFallsBackToFirstRemote() {
        XCTAssertEqual(
            CommitRemotePresentationPolicy.presentation(
                remoteNames: ["backup", "upstream"],
                previousSelection: "upstream",
                trackingRemoteName: "backup",
                isBranch: true
            ),
            CommitRemotePresentation(
                remoteNames: ["backup", "upstream"],
                selectedRemoteName: "upstream",
                canPush: true
            )
        )
        XCTAssertEqual(
            CommitRemotePresentationPolicy.presentation(
                remoteNames: ["backup", "upstream"],
                previousSelection: nil,
                trackingRemoteName: "missing",
                isBranch: true
            ),
            CommitRemotePresentation(
                remoteNames: ["backup", "upstream"],
                selectedRemoteName: "backup",
                canPush: true
            )
        )
    }

    func testSubmissionPolicyPreservesValidationAndPushBoundaries() {
        XCTAssertEqual(plan(merge: true, staged: 0, messageLength: 0).disposition, .mergeInProgress)
        XCTAssertEqual(plan(staged: 0, messageLength: 0).disposition, .noStagedChanges)
        XCTAssertEqual(plan(staged: 1, messageLength: 2).disposition, .messageTooShort)
        XCTAssertEqual(plan(staged: 1, messageLength: 3).disposition, .accepted)
        XCTAssertTrue(plan(
            pushEnabled: true,
            pushRequested: true,
            isBranch: true,
            remote: "origin"
        ).shouldArmPendingPush)
        XCTAssertFalse(plan(
            pushEnabled: true,
            pushRequested: true,
            isBranch: false,
            remote: "origin"
        ).shouldArmPendingPush)
        XCTAssertFalse(plan(
            pushEnabled: true,
            pushRequested: true,
            isBranch: true,
            remote: ""
        ).shouldArmPendingPush)
        XCTAssertFalse(plan(
            pushEnabled: true,
            pushRequested: true,
            isBranch: true,
            remote: nil
        ).shouldArmPendingPush)
    }

    private func plan(
        merge: Bool = false,
        staged: Int = 1,
        messageLength: Int = 3,
        pushEnabled: Bool = false,
        pushRequested: Bool = false,
        isBranch: Bool = true,
        remote: String? = "origin"
    ) -> CommitSubmissionPlan {
        CommitSubmissionPolicy.plan(
            mergeInProgress: merge,
            stagedCount: staged,
            messageLength: messageLength,
            pushEnabled: pushEnabled,
            pushRequested: pushRequested,
            isBranch: isBranch,
            remoteName: remote
        )
    }
}
