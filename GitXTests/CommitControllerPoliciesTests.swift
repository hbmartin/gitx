import XCTest

final class CommitControllerPoliciesTests: XCTestCase {
    func testRemotePresentationUsesExistingPrecedenceAndPushEligibility() {
        let sorted = PBCommitRemotePresentationPolicy.sortedRemoteNames(["zebra", "Origin", "backup"])
        XCTAssertEqual(sorted, ["backup", "Origin", "zebra"])
        XCTAssertFalse(PBCommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: sorted,
            previousSelection: "Origin",
            isBranch: true
        ))
        XCTAssertTrue(PBCommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: sorted,
            previousSelection: "missing",
            isBranch: true
        ))

        let previous = PBCommitRemotePresentationPolicy.presentation(
            remoteNames: sorted,
            previousSelection: "zebra",
            trackingRemoteName: "backup",
            isBranch: true
        )
        XCTAssertEqual(previous.selectedRemoteName, "zebra")
        XCTAssertTrue(previous.canPush)

        let tracking = PBCommitRemotePresentationPolicy.presentation(
            remoteNames: sorted,
            previousSelection: "missing",
            trackingRemoteName: "backup",
            isBranch: true
        )
        XCTAssertEqual(tracking.selectedRemoteName, "backup")

        let origin = PBCommitRemotePresentationPolicy.presentation(
            remoteNames: ["backup", "origin"],
            previousSelection: nil,
            trackingRemoteName: nil,
            isBranch: false
        )
        XCTAssertEqual(origin.selectedRemoteName, "origin")
        XCTAssertFalse(origin.canPush)

        let first = PBCommitRemotePresentationPolicy.presentation(
            remoteNames: ["backup", "zebra"],
            previousSelection: nil,
            trackingRemoteName: "missing",
            isBranch: true
        )
        XCTAssertEqual(first.selectedRemoteName, "backup")
    }

    func testRemotePresentationHandlesNoRemotesBoundary() {
        let presentation = PBCommitRemotePresentationPolicy.presentation(
            remoteNames: [],
            previousSelection: "origin",
            trackingRemoteName: "origin",
            isBranch: true
        )
        XCTAssertEqual(presentation.remoteNames, [])
        XCTAssertNil(presentation.selectedRemoteName)
        XCTAssertFalse(presentation.canPush)
        XCTAssertFalse(PBCommitRemotePresentationPolicy.shouldResolveTrackingRemote(
            remoteNames: [],
            previousSelection: nil,
            isBranch: true
        ))
    }

    func testSubmissionPolicyPreservesValidationOrderAndMessageBoundary() {
        XCTAssertEqual(plan(merge: true, staged: 0, messageLength: 0).disposition, .mergeInProgress)
        XCTAssertEqual(plan(staged: 0, messageLength: 0).disposition, .noStagedChanges)
        XCTAssertEqual(plan(staged: 1, messageLength: 2).disposition, .messageTooShort)
        XCTAssertEqual(plan(staged: 1, messageLength: 3).disposition, .accepted)
    }

    func testSubmissionPolicyArmsOnlyACompletePushIntent() {
        XCTAssertTrue(plan(pushEnabled: true, pushRequested: true, isBranch: true, remote: "origin")
            .shouldArmPendingPush)
        XCTAssertFalse(plan(pushEnabled: false, pushRequested: true, isBranch: true, remote: "origin")
            .shouldArmPendingPush)
        XCTAssertFalse(plan(pushEnabled: true, pushRequested: false, isBranch: true, remote: "origin")
            .shouldArmPendingPush)
        XCTAssertFalse(plan(pushEnabled: true, pushRequested: true, isBranch: false, remote: "origin")
            .shouldArmPendingPush)
        XCTAssertFalse(plan(pushEnabled: true, pushRequested: true, isBranch: true, remote: "")
            .shouldArmPendingPush)
        XCTAssertFalse(plan(pushEnabled: true, pushRequested: true, isBranch: true, remote: nil)
            .shouldArmPendingPush)
    }

    func testWorkflowStateConsumesAndClearsPendingPush() {
        let state = PBCommitWorkflowState()
        let branch = PBGitRef(string: "refs/heads/main")
        XCTAssertNil(state.consumePendingPush())

        state.arm(branchRef: branch, remoteName: "origin")
        XCTAssertEqual(state.pendingBranchRef, branch)
        XCTAssertEqual(state.pendingRemoteName, "origin")
        let plan = state.consumePendingPush()
        XCTAssertEqual(plan?.branchRef, branch)
        XCTAssertEqual(plan?.remoteName, "origin")
        XCTAssertNil(state.pendingBranchRef)
        XCTAssertNil(state.pendingRemoteName)

        state.pendingBranchRef = branch
        state.pendingRemoteName = ""
        XCTAssertNil(state.consumePendingPush())
        XCTAssertNil(state.pendingBranchRef)
        XCTAssertNil(state.pendingRemoteName)
    }

    func testWorkflowStateKeepsSuccessfulOnlyPushPreferencePendingWithSubmission() {
        let state = PBCommitWorkflowState()

        state.beginSubmission(pushChoice: true, canRemember: true)
        XCTAssertEqual(state.pendingRememberedPushChoice, true)

        state.clear()
        XCTAssertNil(state.pendingRememberedPushChoice)

        state.beginSubmission(pushChoice: true, canRemember: false)
        XCTAssertNil(state.pendingRememberedPushChoice)
    }

    func testMessagePolicyAddsDeduplicatesAndPreservesAmendThreshold() {
        let added = PBCommitMessagePolicy.messageByAddingSignOff(
            to: "Subject",
            userName: "A User",
            userEmail: "a@example.invalid"
        )
        XCTAssertTrue(added.didAddSignOff)
        XCTAssertEqual(added.message, "Subject\n\nSigned-off-by: A User <a@example.invalid>")

        let duplicate = PBCommitMessagePolicy.messageByAddingSignOff(
            to: added.message,
            userName: "A User",
            userEmail: "a@example.invalid"
        )
        XCTAssertFalse(duplicate.didAddSignOff)
        XCTAssertEqual(duplicate.message, added.message)
        XCTAssertEqual(
            PBCommitMessagePolicy.messageByAddingSignOff(
                to: "",
                userName: "A User",
                userEmail: "a@example.invalid"
            ).message,
            "\n\nSigned-off-by: A User <a@example.invalid>"
        )

        XCTAssertTrue(PBCommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: ""))
        XCTAssertTrue(PBCommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: "123"))
        XCTAssertFalse(PBCommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: "1234"))
        XCTAssertTrue(PBCommitMessagePolicy.shouldReplaceMessageForAmend(currentMessage: "😀"))
    }

    func testSelectionPolicyHandlesEmptyAndShrinkingLists() {
        XCTAssertEqual(PBCommitSelectionPolicy.selectionIndex(currentIndex: 2, arrangedCount: 5), 2)
        XCTAssertEqual(PBCommitSelectionPolicy.selectionIndex(currentIndex: 4, arrangedCount: 2), 1)
        XCTAssertEqual(PBCommitSelectionPolicy.selectionIndex(currentIndex: NSNotFound, arrangedCount: 3), 2)
        XCTAssertEqual(PBCommitSelectionPolicy.selectionIndex(currentIndex: 0, arrangedCount: 0), NSNotFound)
    }

    private func plan(
        merge: Bool = false,
        staged: Int = 1,
        messageLength: Int = 3,
        pushEnabled: Bool = false,
        pushRequested: Bool = false,
        isBranch: Bool = true,
        remote: String? = "origin"
    ) -> PBCommitSubmissionPlan {
        PBCommitSubmissionPolicy.plan(
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
