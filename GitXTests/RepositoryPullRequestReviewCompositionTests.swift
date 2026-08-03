import ForgeKit
import Foundation
import GitHubForgeAdapter
import XCTest

@MainActor
final class RepositoryPullRequestReviewCompositionTests: XCTestCase {
    func testLoadBuildsCompleteWorkspaceAcrossPaginatedDeduplicatedThreadsAndComments() async throws {
        let fixture = try ReviewCompositionFixture()
        let threadCursor = try ForgePageCursor("thread-page-2")
        let commentCursor = try ForgePageCursor("comment-page-2")
        let firstComment = try fixture.comment("comment-1")
        let secondComment = try fixture.comment("comment-2")
        let firstThread = try fixture.thread(
            "thread-1",
            comments: [firstComment],
            nextCursor: commentCursor,
            totalCount: 2
        )
        let duplicateThread = try fixture.thread("thread-1", comments: [firstComment])
        let secondThread = try fixture.thread("thread-2", comments: [])
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            threadOutcomes: [
                .value(fixture.readResult(
                    ForgePage(items: [firstThread], nextCursor: threadCursor, totalCount: 2),
                    completeness: .partial
                )),
                .value(fixture.readResult(
                    ForgePage(items: [duplicateThread, secondThread], totalCount: 2)
                )),
            ],
            commentOutcomes: [
                .value(fixture.readResult(
                    ForgePage(items: [firstComment, secondComment], totalCount: 2)
                )),
            ]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertEqual(workspace.identity, fixture.identity)
        XCTAssertEqual(workspace.displayedHead, fixture.head.commit)
        XCTAssertEqual(workspace.base, fixture.base)
        XCTAssertEqual(workspace.title, "Native composition review")
        XCTAssertEqual(workspace.fetchedAt, fixture.now)
        XCTAssertTrue(workspace.isMutationStateFresh)
        XCTAssertEqual(workspace.threads.map(\.presentation.thread.id), [firstThread.id, secondThread.id])
        guard case let .available(comments) = workspace.threads[0].presentation.thread.comments else {
            return XCTFail("Expected the complete comment connection")
        }
        XCTAssertEqual(comments.items.map(\.id), [firstComment.id, secondComment.id])
        XCTAssertNil(comments.nextCursor)
        let requestedThreadCursors = await read.requestedThreadCursors()
        let requestedCommentCursors = await read.requestedCommentCursors()
        XCTAssertEqual(requestedThreadCursors, [nil, threadCursor])
        XCTAssertEqual(requestedCommentCursors, [commentCursor])
    }

    func testDeletedHeadRepositoryLoadsFreshWorkspaceAndPreservesSafeActionSurfaces() async throws {
        let fixture = try ReviewCompositionFixture()
        let deletedHead = ForgePullRequestHead(
            repository: nil,
            name: fixture.head.name,
            commit: fixture.head.commit
        )
        let allowedOperations: Set<ForgeOperation> = [
            .closePullRequest,
            .updatePullRequestBranch,
            .mergePullRequest,
            .enterMergeQueue,
            .submitCommentReview,
            .publishInlineReviewComment,
            .deleteHeadBranch,
        ]
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(pullRequestHead: deletedHead)
        )
        let merge = try fixture.mergeSnapshot(
            pullRequestHead: deletedHead,
            allowedOperations: allowedOperations
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: merge
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            allowedOperations: allowedOperations
        )

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(workspace.isMutationStateFresh)
        XCTAssertNil(workspace.mutationContext.head.repository)
        XCTAssertEqual(workspace.displayedHead, fixture.head.commit)
        XCTAssertNil(workspace.headBranchDeletionSnapshot)
        XCTAssertFalse(workspace.canOfferHeadBranchDeletionAfterMerge)
        guard case .available = ForgePullRequestLifecyclePolicy.decision(
            context: workspace.mutationContext,
            action: .close
        ) else {
            return XCTFail("Closing a deleted-head Pull Request should remain available")
        }
        XCTAssertEqual(
            ForgePullRequestLifecyclePolicy.decision(
                context: workspace.mutationContext,
                action: .updateBranch,
                canUpdateBranch: true
            ),
            .unavailable(.updateBranchUnavailable)
        )
        guard case .available = ForgePullRequestMergeQueuePolicy.decision(
            snapshot: workspace.mergeSnapshot,
            action: .enter
        ) else {
            return XCTFail("Merge queue should not require the deleted head repository")
        }

        let fresh = try await harness.service.freshMergeSnapshot(identity: fixture.identity)
        XCTAssertNil(fresh.context.head.repository)
        guard case let .available(confirmation) = ForgePullRequestMergePolicy.confirmationDecision(
            snapshot: fresh,
            method: .merge
        ) else {
            return XCTFail("Merge confirmation should not require the deleted head repository")
        }
        XCTAssertNil(confirmation.headReference.repository)
    }

    func testNestedCommentPaginationAloneExplainsPartialThreadResult() async throws {
        let fixture = try ReviewCompositionFixture()
        let commentCursor = try ForgePageCursor("nested-comment-page-2")
        let firstComment = try fixture.comment("comment-1")
        let secondComment = try fixture.comment("comment-2")
        let thread = try fixture.thread(
            "thread-1",
            comments: [firstComment],
            nextCursor: commentCursor,
            totalCount: 2
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            threadOutcomes: [.value(fixture.readResult(
                ForgePage(items: [thread], totalCount: 1),
                completeness: .partial
            ))],
            commentOutcomes: [.value(fixture.readResult(
                ForgePage(items: [secondComment], totalCount: 2)
            ))]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(workspace.isMutationStateFresh)
        guard case let .available(comments) = workspace.threads.first?.presentation.thread.comments else {
            return XCTFail("Expected fully paginated nested comments")
        }
        XCTAssertEqual(comments.items.map(\.id), [firstComment.id, secondComment.id])
        XCTAssertNil(comments.nextCursor)
        let requestedCommentCursors = await read.requestedCommentCursors()
        XCTAssertEqual(requestedCommentCursors, [commentCursor])
    }

    func testLoadCompletesCursorDrivenDetailsWithoutTreatingPaginationAsFailure() async throws {
        let fixture = try ReviewCompositionFixture()
        let timelineCursor = try ForgePageCursor("timeline-page-2")
        let checkCursor = try ForgePageCursor("check-page-2")
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            detailsOutcomes: [
                .value(fixture.detailsResult(
                    timelineCursor: timelineCursor,
                    checkCursor: checkCursor,
                    completeness: .partial
                )),
                .value(fixture.detailsResult(
                    checkCursor: checkCursor,
                    completeness: .partial
                )),
                .value(fixture.detailsResult(
                    timelineCursor: timelineCursor,
                    completeness: .partial
                )),
            ]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(workspace.isMutationStateFresh)
        let requests = await read.requestedDetailsCursors()
        XCTAssertEqual(requests.map { $0.timeline }, [nil, timelineCursor, nil])
        XCTAssertEqual(requests.map { $0.check }, [nil, nil, checkCursor])
    }

    func testCheckPaginationReplacesOverlappingChecksByStableIdentity() throws {
        let fixture = try ReviewCompositionFixture()
        let checkID = try ForgeObjectID(forge: fixture.repository.forge, value: "check-1")
        let running = try fixture.check(
            id: checkID,
            name: "build",
            summary: "Running",
            state: .running
        )
        let succeeded = try fixture.check(
            id: checkID,
            name: "build",
            summary: "Passed",
            state: .succeeded
        )
        let idlessRunning = try fixture.check(
            name: "legacy-status",
            summary: "Running",
            state: .running
        )
        let idlessFailed = try fixture.check(
            name: "legacy-status",
            summary: "Failed",
            state: .failed
        )
        let checks = RepositoryPullRequestCheckPagination.merging(
            [running, idlessRunning],
            with: [succeeded, idlessFailed]
        )

        XCTAssertEqual(checks, [succeeded, idlessFailed])
    }

    func testRepeatedThreadAndCommentCursorsStopPaginationAndMarkWorkspaceStale() async throws {
        let fixture = try ReviewCompositionFixture()
        let threadCursor = try ForgePageCursor("repeated-thread")
        let commentCursor = try ForgePageCursor("repeated-comment")
        let first = try fixture.comment("comment-1")
        let second = try fixture.comment("comment-2")
        let thread = try fixture.thread(
            "thread-1",
            comments: [first],
            nextCursor: commentCursor,
            totalCount: 3
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            threadOutcomes: [
                .value(fixture.readResult(
                    ForgePage(items: [thread], nextCursor: threadCursor, totalCount: 1)
                )),
                .value(fixture.readResult(
                    ForgePage(items: [], nextCursor: threadCursor, totalCount: 1)
                )),
            ],
            commentOutcomes: [
                .value(fixture.readResult(
                    ForgePage(items: [first, second], nextCursor: commentCursor, totalCount: 3)
                )),
            ]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertFalse(workspace.isMutationStateFresh)
        let requestedThreadCursors = await read.requestedThreadCursors()
        let requestedCommentCursors = await read.requestedCommentCursors()
        XCTAssertEqual(requestedThreadCursors, [nil, threadCursor])
        XCTAssertEqual(requestedCommentCursors, [commentCursor])
        guard case let .available(comments) = workspace.threads[0].presentation.thread.comments else {
            return XCTFail("Expected known comments to be retained as partial")
        }
        XCTAssertEqual(comments.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(comments.totalCount, 3)
    }

    func testPartialRefreshPreservesOnlySameHeadLastGoodThreads() async throws {
        let fixture = try ReviewCompositionFixture()
        let firstThread = try fixture.thread("thread-1", comments: [fixture.comment("comment-1")])
        let missingThread = try fixture.thread("thread-2", comments: [fixture.comment("comment-2")])
        let changedThread = try fixture.thread("thread-1", comments: [fixture.comment("comment-new")])
        let oldDetails = try fixture.detailsResult(head: fixture.head)
        let newHead = ForgeBranchReference(
            repository: fixture.repository,
            name: fixture.head.name,
            commit: fixture.changedHead
        )
        let newDetails = try fixture.detailsResult(head: newHead)
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            detailsOutcomes: [.value(oldDetails), .value(oldDetails), .value(newDetails)],
            threadOutcomes: [
                .value(fixture.readResult(ForgePage(items: [firstThread, missingThread]))),
                .value(fixture.readResult(
                    ForgePage(items: [changedThread]),
                    completeness: .partial
                )),
                .value(fixture.readResult(
                    ForgePage(items: [changedThread]),
                    completeness: .partial
                )),
            ]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        let initial = try await harness.service.loadWorkspace(identity: fixture.identity)
        let sameHeadPartial = try await harness.service.loadWorkspace(identity: fixture.identity)
        let changedHeadPartial = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(initial.isMutationStateFresh)
        XCTAssertEqual(initial.threads.count, 2)
        XCTAssertFalse(sameHeadPartial.isMutationStateFresh)
        XCTAssertEqual(
            Set(sameHeadPartial.threads.map(\.presentation.thread.id)),
            Set([firstThread.id, missingThread.id])
        )
        XCTAssertFalse(changedHeadPartial.isMutationStateFresh)
        XCTAssertEqual(changedHeadPartial.displayedHead, fixture.changedHead)
        XCTAssertEqual(changedHeadPartial.threads.map(\.presentation.thread.id), [changedThread.id])
    }

    func testLoadRejectsReadOwnershipMismatch() async throws {
        let fixture = try ReviewCompositionFixture()
        let wrongOwnership = try GitHubReadOwnership(
            credential: fixture.replacementCredential,
            repository: fixture.repository
        )
        let details = try fixture.detailsResult(ownership: wrongOwnership)
        let read = try ReviewReadAdapterStub(fixture: fixture, detailsOutcomes: [.value(details)])
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)

        await assertThrows(RepositoryPullRequestReviewServiceError.invalidWorkspace) {
            try await harness.service.loadWorkspace(identity: fixture.identity)
        }
        let threadCallCount = await read.threadCallCount()
        XCTAssertEqual(threadCallCount, 0)
    }

    func testOlderOverlappingLoadCannotReplaceNewerWorkspace() async throws {
        let fixture = try ReviewCompositionFixture()
        let oldDetails = try fixture.detailsResult()
        let newHead = ForgeBranchReference(
            repository: fixture.repository,
            name: fixture.head.name,
            commit: fixture.changedHead
        )
        let newDetails = try fixture.detailsResult(head: newHead)
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            detailsOutcomes: [.value(oldDetails), .value(newDetails)]
        )
        let harness = try ReviewCompositionHarness(fixture: fixture, read: read)
        await read.holdNextDetailsRequest()

        let older = Task {
            try await harness.service.loadWorkspace(identity: fixture.identity)
        }
        await read.waitForDetailsRequests(1)
        let newer = try await harness.service.loadWorkspace(identity: fixture.identity)
        XCTAssertEqual(newer.displayedHead, fixture.changedHead)

        await read.releaseHeldDetailsRequest()
        do {
            _ = try await older.value
            XCTFail("Expected the superseded load to be cancelled")
        } catch is CancellationError {
            // Expected: the older result never becomes the service's last-good workspace.
        }
    }

    func testRebindDuringHeldLoadRejectsOldRepositoryResult() async throws {
        let fixture = try ReviewCompositionFixture()
        let read = try ReviewReadAdapterStub(fixture: fixture)
        let binding = try fixture.binding()
        let bindingBox = LockedReviewBindingBox(binding)
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            currentBinding: { bindingBox.value }
        )
        await read.holdNextDetailsRequest()

        let load = Task {
            try await harness.service.loadWorkspace(identity: fixture.identity)
        }
        await read.waitForDetailsRequests(1)
        bindingBox.value = nil
        await read.releaseHeldDetailsRequest()

        await assertThrows(RepositoryPullRequestReviewServiceError.invalidWorkspace) {
            try await load.value
        }
        let threadCallCount = await read.threadCallCount()
        XCTAssertEqual(threadCallCount, 0)
    }

    func testMergePreflightMustAgreeWithDetailsAndRetainsOnlySameHeadSnapshot() async throws {
        let fixture = try ReviewCompositionFixture()
        let read = try ReviewReadAdapterStub(fixture: fixture)
        let matching = try fixture.mergeSnapshot(
            allowedOperations: [.mergePullRequest],
            warnings: [.checksPending]
        )
        let mismatching = try fixture.mergeSnapshot(
            updatedAt: fixture.now.addingTimeInterval(1),
            allowedOperations: [.mergePullRequest]
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            mergeSnapshots: [matching, mismatching]
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            allowedOperations: [.mergePullRequest]
        )

        let initial = try await harness.service.loadWorkspace(identity: fixture.identity)
        let stale = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(initial.isMutationStateFresh)
        XCTAssertEqual(initial.mergeSnapshot.warnings, [.checksPending])
        XCTAssertFalse(stale.isMutationStateFresh)
        XCTAssertEqual(stale.mergeSnapshot, initial.mergeSnapshot)
        let mergeSnapshotCallCount = await mutation.mergeSnapshotCallCount()
        XCTAssertEqual(mergeSnapshotCallCount, 2)
    }

    func testCompleteRefreshConsumesOnlyUnknownOutcomesForExactPullRequestScope() async throws {
        let fixture = try ReviewCompositionFixture()
        let otherNumber = try ForgeItemNumber(43)
        let exact = try fixture.unknownRecord(operation: .closePullRequest, number: fixture.number)
        let other = try fixture.unknownRecord(operation: .markPullRequestReady, number: otherNumber)
        let unknown = UnknownOutcomeSpy(records: [exact, other])
        let harness = try ReviewCompositionHarness(fixture: fixture, unknownOutcomes: unknown)

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(workspace.isMutationStateFresh)
        let queries = await unknown.queries()
        let consumptions = await unknown.consumptions()
        XCTAssertEqual(queries.count, 16)
        XCTAssertTrue(queries.allSatisfy { $0.scope == .pullRequest(fixture.number) })
        XCTAssertEqual(
            consumptions,
            [UnknownOutcomeSpy.Request(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .closePullRequest,
                scope: .pullRequest(fixture.number)
            )]
        )
        let remainingRecords = await unknown.remainingRecords()
        XCTAssertEqual(remainingRecords, [other])
    }

    func testIncompleteRefreshDoesNotConsumeUnknownOutcome() async throws {
        let fixture = try ReviewCompositionFixture()
        let exact = try fixture.unknownRecord(operation: .closePullRequest, number: fixture.number)
        let unknown = UnknownOutcomeSpy(records: [exact])
        let partialDetails = try fixture.detailsResult(completeness: .partial)
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            detailsOutcomes: [.value(partialDetails)]
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            unknownOutcomes: unknown
        )

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertFalse(workspace.isMutationStateFresh)
        let consumptions = await unknown.consumptions()
        let remainingRecords = await unknown.remainingRecords()
        XCTAssertTrue(consumptions.isEmpty)
        XCTAssertEqual(remainingRecords, [exact])
    }

    func testEveryReviewOperationUsesExactAuthorizationAndBalancedPullRequestLifecycle() async throws {
        let fixture = try ReviewCompositionFixture()
        let lifecycle = MutationLifecycleSpy()
        let local = LocalReviewServiceSpy()
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            local: local,
            lifecycle: lifecycle
        )
        _ = try await harness.service.loadWorkspace(identity: fixture.identity)

        let inline = try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.number,
            displayedHead: fixture.head.commit,
            anchor: fixture.anchor,
            bodyMarkdown: "Inline"
        )
        _ = try await harness.service.publishInlineReview(inline)
        let reply = try ForgeReviewThreadReplyPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.number,
            threadID: fixture.threadID,
            bodyMarkdown: "Reply"
        )
        _ = try await harness.service.replyToReviewThread(reply)
        try await harness.service.setReviewThreadResolution(
            identity: fixture.identity,
            threadID: fixture.threadID,
            mutation: .resolve
        )
        try await harness.service.setReviewThreadResolution(
            identity: fixture.identity,
            threadID: fixture.threadID,
            mutation: .unresolve
        )
        for kind in ForgeFormalReviewKind.allCases {
            let submission = try ForgeFormalReviewSubmission(
                accountID: fixture.accountID,
                repository: fixture.repository,
                pullRequest: fixture.number,
                displayedHead: fixture.head.commit,
                kind: kind,
                bodyMarkdown: kind == .requestChanges ? "Please revise" : ""
            )
            _ = try await harness.service.submitFormalReview(submission)
        }
        let context = try fixture.mutationContext(allowedOperations: Set(ForgeOperation.allCases))
        for action in ForgePullRequestLifecycleAction.allCases {
            _ = try await harness.service.performLifecycle(
                ForgePullRequestLifecycleRequest(context: context, action: action)
            )
        }
        let mergeSnapshot = try fixture.mergeSnapshot(allowedOperations: [.mergePullRequest])
        let mergeConfirmation = ForgePullRequestMergeConfirmation(snapshot: mergeSnapshot, method: .merge)
        _ = try await harness.service.mergePullRequest(
            ForgePullRequestMergeRequest(confirmation: mergeConfirmation)
        )
        let enter = try XCTUnwrap(try availableQueueRequest(snapshot: fixture.mergeSnapshot(
            allowedOperations: [.enterMergeQueue],
            queueState: .notQueued
        ), action: .enter))
        _ = try await harness.service.changeMergeQueue(enter)
        let leave = try XCTUnwrap(try availableQueueRequest(snapshot: fixture.mergeSnapshot(
            allowedOperations: [.leaveMergeQueue],
            queueState: .queued
        ), action: .leave))
        _ = try await harness.service.changeMergeQueue(leave)

        let expected: [ForgeOperation] = [
            .publishInlineReviewComment,
            .replyToReviewThread,
            .resolveReviewThread,
            .unresolveReviewThread,
            .submitApproveReview,
            .submitCommentReview,
            .submitRequestChangesReview,
            .markPullRequestReady,
            .convertPullRequestToDraft,
            .closePullRequest,
            .reopenPullRequest,
            .updatePullRequestBranch,
            .mergePullRequest,
            .enterMergeQueue,
            .leaveMergeQueue,
        ]
        let mutationOperations = await harness.mutation.mutationOperations()
        let requestedMutationOperations = await harness.dependencies.requestedMutationOperations()
        XCTAssertEqual(mutationOperations, expected)
        XCTAssertEqual(requestedMutationOperations, expected)
        XCTAssertEqual(lifecycle.registeredMutations().map(\.operation), expected)
        XCTAssertTrue(lifecycle.registeredMutations().allSatisfy {
            $0.accountID == fixture.accountID
                && $0.repository == fixture.repository
                && $0.scope == .pullRequest(fixture.number)
                && $0.startedAt == fixture.now
        })
        XCTAssertEqual(Set(lifecycle.finishedRegistrationIDs()), Set(lifecycle.registeredMutations().map(\.registrationID)))
        let fetchedBranches = local.fetchedBranches()
        XCTAssertEqual(fetchedBranches, [fixture.head])
    }

    func testDestructivePreflightsDoNotRegisterAndDeleteRegistersOnceAfterRevalidation() async throws {
        let fixture = try ReviewCompositionFixture()
        let lifecycle = MutationLifecycleSpy()
        let local = LocalReviewServiceSpy(checkedOutHeads: [nil, nil, nil, nil])
        let mergedSnapshot = try fixture.mergeSnapshot(
            state: .merged,
            allowedOperations: [.deleteHeadBranch]
        )
        let deletionSnapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergedSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(state: .merged)
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: mergedSnapshot,
            defaultDeletionSnapshot: deletionSnapshot
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            local: local,
            lifecycle: lifecycle,
            allowedOperations: [.deleteHeadBranch]
        )

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)
        XCTAssertTrue(workspace.isMutationStateFresh)
        XCTAssertTrue(lifecycle.registeredMutations().isEmpty)
        _ = try await harness.service.freshMergeSnapshot(identity: fixture.identity)
        _ = try await harness.service.freshHeadBranchDeletionSnapshot(identity: fixture.identity)
        XCTAssertTrue(lifecycle.registeredMutations().isEmpty)

        let freshWorkspace = try await harness.service.loadWorkspace(identity: fixture.identity)
        let snapshot = try XCTUnwrap(freshWorkspace.headBranchDeletionSnapshot)
        let request = try XCTUnwrap(availableDeletionRequest(snapshot))
        try await harness.service.deleteHeadBranch(request)

        let mutationOperations = await mutation.mutationOperations()
        XCTAssertEqual(mutationOperations, [.deleteHeadBranch])
        XCTAssertEqual(lifecycle.registeredMutations().map(\.operation), [.deleteHeadBranch])
        XCTAssertEqual(lifecycle.registeredMutations().map(\.scope), [.pullRequest(fixture.number)])
        XCTAssertEqual(lifecycle.finishedRegistrationIDs().count, 1)
    }

    func testDeletionSnapshotPreservesCheckedOutSafetyConflictReportedByLocalService() async throws {
        let fixture = try ReviewCompositionFixture()
        let local = LocalReviewServiceSpy(checkedOutHeads: [fixture.head.commit])
        let mergeSnapshot = try fixture.mergeSnapshot(
            state: .merged,
            allowedOperations: [.deleteHeadBranch]
        )
        let adapterSnapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(state: .merged)
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: mergeSnapshot,
            defaultDeletionSnapshot: adapterSnapshot
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            local: local,
            allowedOperations: [.deleteHeadBranch]
        )

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)
        let snapshot = try XCTUnwrap(workspace.headBranchDeletionSnapshot)

        XCTAssertEqual(snapshot, ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: true
        ))
    }

    func testForkHeadSkipsOptionalDeletePreflightWithoutMakingWorkspaceStale() async throws {
        let fixture = try ReviewCompositionFixture()
        let forkHead = ForgeBranchReference(
            repository: fixture.otherRepository,
            name: fixture.head.name,
            commit: fixture.head.commit
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(head: forkHead)
        )
        let merge = try fixture.mergeSnapshot(
            head: forkHead,
            allowedOperations: [.deleteHeadBranch]
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: merge
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            allowedOperations: [.deleteHeadBranch]
        )

        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)

        XCTAssertTrue(workspace.isMutationStateFresh)
        XCTAssertNil(workspace.headBranchDeletionSnapshot)
        let deletionSnapshotCallCount = await mutation.deletionSnapshotCallCount()
        XCTAssertEqual(deletionSnapshotCallCount, 0)
    }

    func testDeleteRevalidatesWorkspaceBeforeDispatch() async throws {
        let fixture = try ReviewCompositionFixture()
        let lifecycle = MutationLifecycleSpy()
        let local = LocalReviewServiceSpy(checkedOutHeads: [nil, nil])
        let mergedSnapshot = try fixture.mergeSnapshot(
            state: .merged,
            allowedOperations: [.deleteHeadBranch]
        )
        let deletionSnapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergedSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(state: .merged)
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: mergedSnapshot,
            defaultDeletionSnapshot: deletionSnapshot
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            local: local,
            lifecycle: lifecycle,
            allowedOperations: [.deleteHeadBranch]
        )
        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)
        let snapshot = try XCTUnwrap(workspace.headBranchDeletionSnapshot)
        let valid = try XCTUnwrap(availableDeletionRequest(snapshot))
        let otherHead = ForgeBranchReference(
            repository: fixture.repository,
            name: fixture.head.name,
            commit: fixture.changedHead
        )
        let otherContext = try fixture.mutationContext(
            state: .merged,
            head: otherHead,
            allowedOperations: [.deleteHeadBranch]
        )
        let staleSnapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: ForgePullRequestMergeSnapshot(
                context: otherContext,
                viewerCanMerge: true,
                enabledMethods: [.merge]
            ),
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        let stale = try XCTUnwrap(availableDeletionRequest(staleSnapshot))

        await assertThrows(RepositoryPullRequestReviewServiceError.stalePullRequest) {
            try await harness.service.deleteHeadBranch(stale)
        }
        let rejectedOperations = await mutation.mutationOperations()
        XCTAssertTrue(rejectedOperations.isEmpty)
        XCTAssertTrue(lifecycle.registeredMutations().isEmpty)

        try await harness.service.deleteHeadBranch(valid)
        let completedOperations = await mutation.mutationOperations()
        XCTAssertEqual(completedOperations, [.deleteHeadBranch])
    }

    func testDeleteFailsClosedWhenCheckedOutHeadCannotBeValidated() async throws {
        let fixture = try ReviewCompositionFixture()
        let lifecycle = MutationLifecycleSpy()
        let local = LocalReviewServiceSpy(
            checkedOutHeads: [nil],
            checkedOutHeadErrorAtCall: 2
        )
        let mergedSnapshot = try fixture.mergeSnapshot(
            state: .merged,
            allowedOperations: [.deleteHeadBranch]
        )
        let deletionSnapshot = ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergedSnapshot,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            defaultDetails: fixture.detailsResult(state: .merged)
        )
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            defaultMergeSnapshot: mergedSnapshot,
            defaultDeletionSnapshot: deletionSnapshot
        )
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            mutation: mutation,
            local: local,
            lifecycle: lifecycle,
            allowedOperations: [.deleteHeadBranch]
        )
        let workspace = try await harness.service.loadWorkspace(identity: fixture.identity)
        let snapshot = try XCTUnwrap(workspace.headBranchDeletionSnapshot)
        let request = try XCTUnwrap(availableDeletionRequest(snapshot))

        await assertThrows(RepositoryPullRequestReviewServiceError.unsafeLocalEdit) {
            try await harness.service.deleteHeadBranch(request)
        }

        let mutationOperations = await mutation.mutationOperations()
        XCTAssertTrue(mutationOperations.isEmpty)
        XCTAssertTrue(lifecycle.registeredMutations().isEmpty)
    }

    func testTerminationPendingRejectsMutationBeforeAdapterDispatch() async throws {
        let fixture = try ReviewCompositionFixture()
        let lifecycle = MutationLifecycleSpy(registerError: .terminationPending)
        let harness = try ReviewCompositionHarness(fixture: fixture, lifecycle: lifecycle)
        _ = try await harness.service.loadWorkspace(identity: fixture.identity)

        await assertThrows(ForgeMutationQuitCoordinatorError.terminationPending) {
            try await harness.service.setReviewThreadResolution(
                identity: fixture.identity,
                threadID: fixture.threadID,
                mutation: .resolve
            )
        }

        let mutationOperations = await harness.mutation.mutationOperations()
        XCTAssertTrue(mutationOperations.isEmpty)
        XCTAssertTrue(lifecycle.registeredMutations().isEmpty)
        XCTAssertTrue(lifecycle.finishedRegistrationIDs().isEmpty)
    }

    func testSuccessfulMutationReturnsStaleWorkspaceWhenAuthoritativeRefreshFails() async throws {
        let fixture = try ReviewCompositionFixture()
        let read = try ReviewReadAdapterStub(
            fixture: fixture,
            detailsOutcomes: [
                .value(fixture.detailsResult()),
                .failure(.offline),
            ]
        )
        let lifecycle = MutationLifecycleSpy()
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            read: read,
            lifecycle: lifecycle
        )
        _ = try await harness.service.loadWorkspace(identity: fixture.identity)
        let publication = try ForgeInlineReviewPublication(
            accountID: fixture.accountID,
            repository: fixture.repository,
            pullRequest: fixture.number,
            displayedHead: fixture.head.commit,
            anchor: fixture.anchor,
            bodyMarkdown: "Ship it"
        )

        let workspace = try await harness.service.publishInlineReview(publication)

        XCTAssertFalse(workspace.isMutationStateFresh)
        XCTAssertEqual(workspace.displayedHead, fixture.head.commit)
        let mutationOperations = await harness.mutation.mutationOperations()
        let successCount = await harness.dependencies.successCount()
        XCTAssertEqual(mutationOperations, [.publishInlineReviewComment])
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(lifecycle.finishedRegistrationIDs().count, 1)
    }

    func testSuccessfulUpdateBranchReturnsStaleWorkspaceWhenLocalFetchFails() async throws {
        let fixture = try ReviewCompositionFixture()
        let local = LocalReviewServiceSpy(fetchError: .offline)
        let harness = try ReviewCompositionHarness(fixture: fixture, local: local)
        _ = try await harness.service.loadWorkspace(identity: fixture.identity)
        let context = try fixture.mutationContext(allowedOperations: [.updatePullRequestBranch])

        let workspace = try await harness.service.performLifecycle(
            ForgePullRequestLifecycleRequest(context: context, action: .updateBranch)
        )

        XCTAssertFalse(workspace.isMutationStateFresh)
        let fetchedBranches = local.fetchedBranches()
        let mutationOperations = await harness.mutation.mutationOperations()
        XCTAssertEqual(fetchedBranches, [fixture.head])
        XCTAssertEqual(mutationOperations, [.updatePullRequestBranch])
    }

    func testMutationErrorsMapOfflineCooldownAndServerRateLimitAndBalanceLifecycle() async throws {
        let fixture = try ReviewCompositionFixture()
        let cooldown = fixture.now.addingTimeInterval(30)
        let rateLimit = fixture.metadata(
            statusCode: 429,
            headers: ["retry-after": "60"]
        )
        let cases: [(GitHubMutationError, RepositoryPullRequestReviewServiceError)] = [
            (.offline, .offline),
            (.cooldown(until: cooldown), .rateLimited(until: cooldown)),
            (.rateLimited(rateLimit), .rateLimited(until: fixture.now.addingTimeInterval(60))),
        ]

        for (adapterError, expected) in cases {
            let lifecycle = MutationLifecycleSpy()
            let mutation = ReviewMutationAdapterStub(
                fixture: fixture,
                failures: [.resolveReviewThread: adapterError]
            )
            let harness = try ReviewCompositionHarness(
                fixture: fixture,
                mutation: mutation,
                lifecycle: lifecycle
            )
            _ = try await harness.service.loadWorkspace(identity: fixture.identity)

            await assertThrows(expected) {
                try await harness.service.setReviewThreadResolution(
                    identity: fixture.identity,
                    threadID: fixture.threadID,
                    mutation: .resolve
                )
            }

            XCTAssertEqual(lifecycle.registeredMutations().count, 1)
            XCTAssertEqual(lifecycle.finishedRegistrationIDs().count, 1)
            let failureCount = await harness.dependencies.failureCount()
            XCTAssertEqual(failureCount, 1)
        }
    }

    func testAuthorizationRecoveryErrorsRemainTypedAcrossReviewComposition() async throws {
        let fixture = try ReviewCompositionFixture()
        let cases = [
            ReviewAuthorizationRecoveryTestFixture.samlError(at: fixture.now),
            ReviewAuthorizationRecoveryTestFixture.installationError(at: fixture.now),
        ]

        for expected in cases {
            let lifecycle = MutationLifecycleSpy()
            let mutation = ReviewMutationAdapterStub(
                fixture: fixture,
                failures: [.resolveReviewThread: expected]
            )
            let harness = try ReviewCompositionHarness(
                fixture: fixture,
                mutation: mutation,
                lifecycle: lifecycle
            )
            _ = try await harness.service.loadWorkspace(identity: fixture.identity)

            await assertThrows(expected) {
                try await harness.service.setReviewThreadResolution(
                    identity: fixture.identity,
                    threadID: fixture.threadID,
                    mutation: .resolve
                )
            }

            let mutationOperations = await mutation.mutationOperations()
            let failureCount = await harness.dependencies.failureCount()
            XCTAssertEqual(mutationOperations, [.resolveReviewThread])
            XCTAssertEqual(failureCount, 1)
            XCTAssertEqual(lifecycle.registeredMutations().count, 1)
            XCTAssertEqual(lifecycle.finishedRegistrationIDs().count, 1)
        }
    }

    func testPostDispatchMutationOwnershipMismatchIsOutcomeUnknown() async throws {
        let fixture = try ReviewCompositionFixture()
        let mutation = ReviewMutationAdapterStub(
            fixture: fixture,
            resultOwnershipOperation: .unresolveReviewThread
        )
        let lifecycle = MutationLifecycleSpy()
        let harness = try ReviewCompositionHarness(
            fixture: fixture,
            mutation: mutation,
            lifecycle: lifecycle
        )
        _ = try await harness.service.loadWorkspace(identity: fixture.identity)

        await assertThrows(RepositoryPullRequestReviewServiceError.outcomeUnknown) {
            try await harness.service.setReviewThreadResolution(
                identity: fixture.identity,
                threadID: fixture.threadID,
                mutation: .resolve
            )
        }

        let mutationOperations = await mutation.mutationOperations()
        let failureCount = await harness.dependencies.failureCount()
        XCTAssertEqual(mutationOperations, [.resolveReviewThread])
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(lifecycle.finishedRegistrationIDs().count, 1)
    }

    private func availableQueueRequest(
        snapshot: ForgePullRequestMergeSnapshot,
        action: ForgePullRequestMergeQueueAction
    ) -> ForgePullRequestMergeQueueRequest? {
        guard case let .available(request) = ForgePullRequestMergeQueuePolicy.decision(
            snapshot: snapshot,
            action: action
        ) else { return nil }
        return request
    }

    private func availableDeletionRequest(
        _ snapshot: ForgeHeadBranchDeletionSnapshot
    ) -> ForgeHeadBranchDeletionRequest? {
        guard case let .available(request) = ForgeHeadBranchDeletionPolicy.decision(
            snapshot: snapshot,
            mergeWasQueued: false
        ) else { return nil }
        return request
    }

    private func assertThrows<T: Equatable & Error, Value>(
        _ expected: T,
        _ expression: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? T, expected, file: file, line: line)
        }
    }
}

private struct ReviewCompositionHarness {
    let service: RepositoryPullRequestReviewProductionService
    let dependencies: ReviewDependencyProviderStub
    let mutation: ReviewMutationAdapterStub

    init(
        fixture: ReviewCompositionFixture,
        read: ReviewReadAdapterStub? = nil,
        mutation: ReviewMutationAdapterStub? = nil,
        local: LocalReviewServiceSpy = LocalReviewServiceSpy(),
        lifecycle: MutationLifecycleSpy? = nil,
        unknownOutcomes: UnknownOutcomeSpy? = nil,
        allowedOperations: Set<ForgeOperation> = [],
        currentBinding: (@Sendable () -> ForgeRepositoryBinding?)? = nil
    ) throws {
        let read = try read ?? ReviewReadAdapterStub(fixture: fixture)
        let mutation = mutation ?? ReviewMutationAdapterStub(fixture: fixture)
        let dependencies = ReviewDependencyProviderStub(
            fixture: fixture,
            read: read,
            mutation: mutation,
            allowedOperations: allowedOperations
        )
        service = try RepositoryPullRequestReviewProductionService(
            binding: fixture.binding(),
            dependencies: dependencies,
            localService: local,
            mutationLifecycle: lifecycle,
            unknownOutcomes: unknownOutcomes,
            currentBinding: currentBinding,
            now: { fixture.now }
        )
        self.dependencies = dependencies
        self.mutation = mutation
    }
}

private struct ReviewCompositionFixture: Sendable {
    let now = Date(timeIntervalSince1970: 1000)
    let repository: ForgeRepositoryIdentity
    let otherRepository: ForgeRepositoryIdentity
    let accountID: ForgeAccountID
    let credential: ForgeCredentialReference
    let replacementCredential: ForgeCredentialReference
    let account: ForgeAccount
    let number = try! ForgeItemNumber(42)
    let head: ForgeBranchReference
    let base: ForgeBranchReference
    let changedHead = try! ForgeCommitID(String(repeating: "d", count: 40))
    let identity: RepositoryPullRequestReviewIdentity
    let threadID: ForgeObjectID
    let anchor: ForgeReviewAnchor

    init() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        otherRepository = try ForgeRepositoryIdentity(forge: forge, owner: "other", name: "gitx")
        accountID = try ForgeAccountID(forge: forge, value: "review-composition")
        credential = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("composition-token"),
            generation: ForgeCredentialGeneration(1)
        )
        replacementCredential = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("replacement-token"),
            generation: ForgeCredentialGeneration(2)
        )
        account = try ForgeAccount(
            id: accountID,
            login: "octocat",
            currentCredential: ForgeCredentialMetadata(
                reference: credential,
                source: .fineGrainedPersonalAccessToken
            )
        )
        head = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("feature/review"),
            commit: ForgeCommitID(String(repeating: "a", count: 40))
        )
        base = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("main"),
            commit: ForgeCommitID(String(repeating: "b", count: 40))
        )
        identity = try RepositoryPullRequestReviewIdentity(
            accountID: accountID,
            repository: repository,
            number: number
        )
        threadID = try ForgeObjectID(forge: forge, value: "thread-1")
        anchor = try ForgeReviewAnchor(
            path: ForgeFilePath("Sources/Review.swift"),
            subject: .line,
            side: .right,
            line: 10
        )
    }

    func binding() throws -> ForgeRepositoryBinding {
        try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: accountID
        )
    }

    func comment(_ value: String) throws -> ForgeReviewComment {
        try ForgeReviewComment(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: value),
            bodyMarkdown: value,
            createdAt: now,
            updatedAt: now,
            author: .unavailable(.notRequested)
        )
    }

    func thread(
        _ value: String,
        comments: [ForgeReviewComment],
        nextCursor: ForgePageCursor? = nil,
        totalCount: Int? = nil
    ) throws -> ForgeReviewThread {
        try ForgeReviewThread(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: value),
            isResolved: false,
            isOutdated: false,
            anchor: .available(anchor),
            comments: .available(ForgePage(
                items: comments,
                nextCursor: nextCursor,
                totalCount: totalCount
            ))
        )
    }

    func summary(
        head: ForgeBranchReference? = nil,
        pullRequestHead: ForgePullRequestHead? = nil,
        state: ForgePullRequestState = .open,
        isDraft: Bool = false,
        updatedAt: Date? = nil
    ) throws -> ForgePullRequestSummary {
        try ForgePullRequestSummary(
            repository: repository,
            number: number,
            state: state,
            isDraft: isDraft,
            title: "Native composition review",
            author: .available(.deleted),
            head: .available(
                pullRequestHead ?? ForgePullRequestHead(reference: head ?? self.head)
            ),
            base: .available(base),
            createdAt: now.addingTimeInterval(-100),
            updatedAt: updatedAt ?? now,
            labels: .available([]),
            checkRollup: .available(.succeeded),
            reviewRollup: .available(.approved)
        )
    }

    func detailsResult(
        head: ForgeBranchReference? = nil,
        pullRequestHead: ForgePullRequestHead? = nil,
        state: ForgePullRequestState = .open,
        checks: [ForgeCheck] = [],
        timelineCursor: ForgePageCursor? = nil,
        checkCursor: ForgePageCursor? = nil,
        completeness: GitHubReadCompleteness = .complete,
        ownership: GitHubReadOwnership? = nil
    ) throws -> GitHubReadResult<ForgePullRequestDetailsPage> {
        let summary = try summary(
            head: head,
            pullRequestHead: pullRequestHead,
            state: state
        )
        let details = try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available("Review body"),
            assignees: .available([]),
            milestone: .available(nil),
            reviewers: .available([]),
            linkedIssues: .available([]),
            mergeability: .available(.mergeable),
            checks: .available(checks),
            timeline: .available(ForgePage(
                items: [],
                nextCursor: timelineCursor,
                totalCount: 0
            ))
        )
        return readResult(
            ForgePullRequestDetailsPage(details: details, nextCheckCursor: checkCursor),
            completeness: completeness,
            ownership: ownership
        )
    }

    func check(
        id: ForgeObjectID? = nil,
        name: String,
        summary: String,
        state: ForgeCheckState
    ) throws -> ForgeCheck {
        try ForgeCheck(
            repository: repository,
            id: id,
            kind: .check,
            name: name,
            summary: summary,
            state: state
        )
    }

    func readResult<Value: Sendable>(
        _ value: Value,
        completeness: GitHubReadCompleteness = .complete,
        ownership: GitHubReadOwnership? = nil
    ) -> GitHubReadResult<Value> {
        GitHubReadResult(
            value: value,
            completeness: completeness,
            problems: [],
            response: metadata(),
            ownership: ownership ?? (try! GitHubReadOwnership(
                credential: credential,
                repository: repository
            ))
        )
    }

    func mutationContext(
        state: ForgePullRequestState = .open,
        head: ForgeBranchReference? = nil,
        pullRequestHead: ForgePullRequestHead? = nil,
        updatedAt: Date? = nil,
        allowedOperations: Set<ForgeOperation> = []
    ) throws -> ForgePullRequestMutationContext {
        try ForgePullRequestMutationContext(
            accountID: accountID,
            repository: repository,
            number: number,
            state: state,
            isDraft: false,
            head: pullRequestHead ?? ForgePullRequestHead(reference: head ?? self.head),
            base: base,
            updatedAt: updatedAt ?? now,
            allowedOperations: allowedOperations
        )
    }

    func mergeSnapshot(
        state: ForgePullRequestState = .open,
        head: ForgeBranchReference? = nil,
        pullRequestHead: ForgePullRequestHead? = nil,
        updatedAt: Date? = nil,
        allowedOperations: Set<ForgeOperation> = [],
        warnings: Set<ForgePullRequestMergeWarning> = [],
        queueState: ForgePullRequestMergeQueueState = .notQueued
    ) throws -> ForgePullRequestMergeSnapshot {
        try ForgePullRequestMergeSnapshot(
            context: mutationContext(
                state: state,
                head: head,
                pullRequestHead: pullRequestHead,
                updatedAt: updatedAt,
                allowedOperations: allowedOperations
            ),
            viewerCanMerge: true,
            enabledMethods: Set(ForgePullRequestMergeMethod.allCases),
            warnings: warnings,
            queueState: queueState
        )
    }

    func authorization(_ operation: ForgeOperation) throws -> GitHubMutationAuthorization {
        let key = ForgeCapabilityKey(
            credential: credential,
            repository: repository,
            operation: operation
        )
        return try GitHubMutationAuthorization(key: key, capability: .verified(.knownAuthority))
    }

    func metadata(
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> GitHubResponseMetadata {
        GitHubResponseMetadata(
            statusCode: statusCode,
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: statusCode,
                headers: headers,
                receivedAt: now
            )
        )
    }

    func mutationValue() throws -> GitHubPullRequestMutationValue {
        try GitHubPullRequestMutationValue(
            id: ForgeObjectID(forge: repository.forge, value: "pull-request-42"),
            repository: repository,
            number: number,
            state: .open,
            isDraft: false,
            title: "Native composition review",
            bodyMarkdown: "Review body",
            head: head,
            base: base,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now,
            closedAt: nil,
            mergedAt: nil
        )
    }

    func unknownRecord(
        operation: ForgeOperation,
        number: ForgeItemNumber
    ) throws -> ForgeUnknownMutationOutcomeRecord {
        let mutation = try ForgeInFlightMutation(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: .pullRequest(number),
            startedAt: now
        )
        return try ForgeUnknownMutationOutcomeRecord(
            mutation: mutation,
            recordedAt: now.addingTimeInterval(1)
        )
    }
}

private enum DetailsOutcome: Sendable {
    case value(GitHubReadResult<ForgePullRequestDetailsPage>)
    case failure(RepositoryPullRequestReviewServiceError)
}

private enum ThreadOutcome: Sendable {
    case value(GitHubReadResult<ForgePage<ForgeReviewThread>>)
    case failure(RepositoryPullRequestReviewServiceError)
}

private enum CommentOutcome: Sendable {
    case value(GitHubReadResult<ForgePage<ForgeReviewComment>>)
    case failure(RepositoryPullRequestReviewServiceError)
}

private actor ReviewReadAdapterStub: ForgeGitHubPullRequestReviewReading {
    private let fixture: ReviewCompositionFixture
    private let defaultDetails: GitHubReadResult<ForgePullRequestDetailsPage>
    private var detailsOutcomes: [DetailsOutcome]
    private var threadOutcomes: [ThreadOutcome]
    private var commentOutcomes: [CommentOutcome]
    private var detailsCursors: [(timeline: ForgePageCursor?, check: ForgePageCursor?)] = []
    private var threadCursors: [ForgePageCursor?] = []
    private var commentCursors: [ForgePageCursor?] = []
    private var detailsRequestCount = 0
    private var detailsRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shouldHoldNextDetailsRequest = false
    private var heldDetailsRequest: CheckedContinuation<Void, Never>?

    init(
        fixture: ReviewCompositionFixture,
        defaultDetails: GitHubReadResult<ForgePullRequestDetailsPage>? = nil,
        detailsOutcomes: [DetailsOutcome] = [],
        threadOutcomes: [ThreadOutcome] = [],
        commentOutcomes: [CommentOutcome] = []
    ) throws {
        self.fixture = fixture
        self.defaultDetails = try defaultDetails ?? fixture.detailsResult()
        self.detailsOutcomes = detailsOutcomes
        self.threadOutcomes = threadOutcomes
        self.commentOutcomes = commentOutcomes
    }

    func pullRequestDetails(
        repository _: ForgeRepositoryIdentity,
        number _: ForgeItemNumber,
        timelinePageSize _: Int,
        timelineAfter: ForgePageCursor?,
        checkPageSize _: Int,
        checkAfter: ForgePageCursor?
    ) async throws -> GitHubReadResult<ForgePullRequestDetailsPage> {
        detailsCursors.append((timelineAfter, checkAfter))
        detailsRequestCount += 1
        let readyWaiters = detailsRequestWaiters.filter { detailsRequestCount >= $0.0 }
        detailsRequestWaiters.removeAll { detailsRequestCount >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        let outcome = detailsOutcomes.isEmpty ? DetailsOutcome.value(defaultDetails) : detailsOutcomes.removeFirst()
        if shouldHoldNextDetailsRequest {
            shouldHoldNextDetailsRequest = false
            await withCheckedContinuation { heldDetailsRequest = $0 }
        }
        switch outcome {
        case let .value(value): return value
        case let .failure(error): throw error
        }
    }

    func reviewThreads(
        repository _: ForgeRepositoryIdentity,
        pullRequestNumber _: ForgeItemNumber,
        pageSize _: Int,
        after: ForgePageCursor?,
        initialCommentCount _: Int
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewThread>> {
        threadCursors.append(after)
        guard !threadOutcomes.isEmpty else {
            return try fixture.readResult(ForgePage(items: []))
        }
        switch threadOutcomes.removeFirst() {
        case let .value(value): return value
        case let .failure(error): throw error
        }
    }

    func reviewThreadComments(
        repository _: ForgeRepositoryIdentity,
        threadID _: ForgeObjectID,
        pageSize _: Int,
        after: ForgePageCursor?
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewComment>> {
        commentCursors.append(after)
        guard !commentOutcomes.isEmpty else {
            return try fixture.readResult(ForgePage(items: []))
        }
        switch commentOutcomes.removeFirst() {
        case let .value(value): return value
        case let .failure(error): throw error
        }
    }

    func requestedThreadCursors() -> [ForgePageCursor?] {
        threadCursors
    }

    func requestedDetailsCursors() -> [(timeline: ForgePageCursor?, check: ForgePageCursor?)] {
        detailsCursors
    }

    func requestedCommentCursors() -> [ForgePageCursor?] {
        commentCursors
    }

    func threadCallCount() -> Int {
        threadCursors.count
    }

    func holdNextDetailsRequest() {
        shouldHoldNextDetailsRequest = true
    }

    func waitForDetailsRequests(_ count: Int) async {
        if detailsRequestCount >= count {
            return
        }
        await withCheckedContinuation { detailsRequestWaiters.append((count, $0)) }
    }

    func releaseHeldDetailsRequest() {
        heldDetailsRequest?.resume()
        heldDetailsRequest = nil
    }
}

private actor ReviewMutationAdapterStub: ForgeGitHubPullRequestReviewMutationExecuting {
    private let fixture: ReviewCompositionFixture
    private var failures: [ForgeOperation: GitHubMutationError]
    private var mergeSnapshots: [ForgePullRequestMergeSnapshot]
    private let defaultMergeSnapshot: ForgePullRequestMergeSnapshot
    private let defaultDeletionSnapshot: ForgeHeadBranchDeletionSnapshot
    private let resultOwnershipOperation: ForgeOperation?
    private var operations: [ForgeOperation] = []
    private var mergeSnapshotCalls = 0
    private var deletionSnapshotCalls = 0

    init(
        fixture: ReviewCompositionFixture,
        failures: [ForgeOperation: GitHubMutationError] = [:],
        mergeSnapshots: [ForgePullRequestMergeSnapshot] = [],
        defaultMergeSnapshot: ForgePullRequestMergeSnapshot? = nil,
        defaultDeletionSnapshot: ForgeHeadBranchDeletionSnapshot? = nil,
        resultOwnershipOperation: ForgeOperation? = nil
    ) {
        self.fixture = fixture
        self.failures = failures
        self.mergeSnapshots = mergeSnapshots
        let merge = defaultMergeSnapshot ?? (try! fixture.mergeSnapshot())
        self.defaultMergeSnapshot = merge
        self.defaultDeletionSnapshot = defaultDeletionSnapshot ?? ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: merge,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        )
        self.resultOwnershipOperation = resultOwnershipOperation
    }

    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        try begin(authorization.key.operation)
        return try result(
            GitHubReviewMutationReceipt(
                repository: publication.repository,
                pullRequest: publication.pullRequest,
                objectID: ForgeObjectID(forge: fixture.repository.forge, value: "inline-comment"),
                displayedHead: publication.displayedHead
            ),
            authorization: authorization
        )
    }

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        try begin(authorization.key.operation)
        return result(
            GitHubReviewMutationReceipt(
                repository: publication.repository,
                pullRequest: publication.pullRequest,
                objectID: publication.threadID
            ),
            authorization: authorization
        )
    }

    func setReviewThreadResolution(
        accountID _: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        try begin(authorization.key.operation)
        return result(
            GitHubReviewMutationReceipt(
                repository: repository,
                pullRequest: pullRequest,
                objectID: threadID,
                isResolved: mutation == .resolve
            ),
            authorization: authorization
        )
    }

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        try begin(authorization.key.operation)
        return try result(
            GitHubReviewMutationReceipt(
                repository: submission.repository,
                pullRequest: submission.pullRequest,
                objectID: ForgeObjectID(forge: fixture.repository.forge, value: "formal-review"),
                displayedHead: submission.displayedHead
            ),
            authorization: authorization
        )
    }

    func performLifecycle(
        _: ForgePullRequestLifecycleRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
        try begin(authorization.key.operation)
        return try result(fixture.mutationValue(), authorization: authorization)
    }

    func freshMergeSnapshot(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        pullRequest _: ForgeItemNumber,
        operation _: ForgeOperation,
        authorization _: GitHubMutationAuthorization
    ) async throws -> ForgePullRequestMergeSnapshot {
        mergeSnapshotCalls += 1
        return mergeSnapshots.isEmpty ? defaultMergeSnapshot : mergeSnapshots.removeFirst()
    }

    func mergePullRequest(
        _: ForgePullRequestMergeRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
        try begin(authorization.key.operation)
        return try result(fixture.mutationValue(), authorization: authorization)
    }

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubMergeQueueReceipt> {
        try begin(authorization.key.operation)
        return try result(
            GitHubMergeQueueReceipt(
                repository: request.repository,
                pullRequest: request.number,
                entryID: ForgeObjectID(forge: fixture.repository.forge, value: "queue-entry"),
                action: request.action
            ),
            authorization: authorization
        )
    }

    func freshHeadBranchDeletionSnapshot(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        pullRequest _: ForgeItemNumber,
        branch _: ForgeRefName,
        expectedHead _: ForgeCommitID,
        hasCheckedOutSafetyConflict: Bool,
        authorization _: GitHubMutationAuthorization
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        deletionSnapshotCalls += 1
        return ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: defaultDeletionSnapshot.mergeSnapshot,
            isSameRepository: defaultDeletionSnapshot.isSameRepository,
            isDefaultBranch: defaultDeletionSnapshot.isDefaultBranch,
            isProtected: defaultDeletionSnapshot.isProtected,
            viewerCanDelete: defaultDeletionSnapshot.viewerCanDelete,
            hasCheckedOutSafetyConflict: hasCheckedOutSafetyConflict
        )
    }

    func deleteHeadBranch(
        _ request: ForgeHeadBranchDeletionRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubHeadBranchDeletionReceipt> {
        try begin(authorization.key.operation)
        return result(
            GitHubHeadBranchDeletionReceipt(
                repository: request.repository,
                branch: request.branch,
                deletedHead: request.expectedHead
            ),
            authorization: authorization
        )
    }

    func mutationOperations() -> [ForgeOperation] {
        operations
    }

    func mergeSnapshotCallCount() -> Int {
        mergeSnapshotCalls
    }

    func deletionSnapshotCallCount() -> Int {
        deletionSnapshotCalls
    }

    private func begin(_ operation: ForgeOperation) throws {
        operations.append(operation)
        if let error = failures[operation] {
            throw error
        }
    }

    private func result<Value: Sendable>(
        _ value: Value,
        authorization: GitHubMutationAuthorization
    ) -> GitHubMutationResult<Value> {
        GitHubMutationResult(
            value: value,
            response: fixture.metadata(),
            ownership: GitHubMutationOwnership(
                credential: fixture.credential,
                repository: fixture.repository,
                operation: resultOwnershipOperation ?? authorization.key.operation
            )
        )
    }
}

private actor ReviewDependencyProviderStub: ForgeGitHubPullRequestReviewDependencyProviding {
    private let fixture: ReviewCompositionFixture
    private let read: ReviewReadAdapterStub
    private let mutation: ReviewMutationAdapterStub
    private let allowedOperations: Set<ForgeOperation>
    private var mutationOperations: [ForgeOperation] = []
    private var successes = 0
    private var failures = 0

    init(
        fixture: ReviewCompositionFixture,
        read: ReviewReadAdapterStub,
        mutation: ReviewMutationAdapterStub,
        allowedOperations: Set<ForgeOperation>
    ) {
        self.fixture = fixture
        self.read = read
        self.mutation = mutation
        self.allowedOperations = allowedOperations
    }

    func reviewReadContext(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        operations _: Set<ForgeOperation>
    ) async throws -> ForgeGitHubPullRequestReviewReadContext {
        ForgeGitHubPullRequestReviewReadContext(
            account: fixture.account,
            credential: fixture.credential,
            environment: .available,
            allowedOperations: allowedOperations,
            readAdapter: read
        )
    }

    func reviewMutationContext(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestReviewMutationContext {
        mutationOperations.append(operation)
        return try ForgeGitHubPullRequestReviewMutationContext(
            account: fixture.account,
            credential: fixture.credential,
            authorization: fixture.authorization(operation),
            readAdapter: read,
            mutationAdapter: mutation
        )
    }

    func recordSuccess(
        _: GitHubResponseMetadata,
        context _: ForgeGitHubPullRequestReviewMutationContext
    ) async {
        successes += 1
    }

    func recordFailure(
        _: GitHubMutationError,
        context _: ForgeGitHubPullRequestReviewMutationContext
    ) async {
        failures += 1
    }

    func requestedMutationOperations() -> [ForgeOperation] {
        mutationOperations
    }

    func successCount() -> Int {
        successes
    }

    func failureCount() -> Int {
        failures
    }
}

// swift6-safety-justification: the lock serializes all mutable lifecycle-spy state.
private final class MutationLifecycleSpy: ForgeMutationLifecycleCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let registerError: ForgeMutationQuitCoordinatorError?
    private var registered: [ForgeInFlightMutation] = []
    private var finished: [UUID] = []

    init(registerError: ForgeMutationQuitCoordinatorError? = nil) {
        self.registerError = registerError
    }

    func register(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope,
        startedAt: Date
    ) throws -> ForgeMutationRegistration {
        if let registerError {
            throw registerError
        }
        let mutation = try ForgeInFlightMutation(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope,
            startedAt: startedAt
        )
        lock.lock()
        registered.append(mutation)
        lock.unlock()
        return ForgeMutationRegistration(mutation: mutation)
    }

    func finish(_ registration: ForgeMutationRegistration) -> Bool {
        lock.lock()
        finished.append(registration.mutation.registrationID)
        lock.unlock()
        return true
    }

    func registeredMutations() -> [ForgeInFlightMutation] {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    func finishedRegistrationIDs() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private actor UnknownOutcomeSpy: RepositoryPullRequestReviewUnknownOutcomeReconciling {
    struct Request: Hashable, Sendable {
        let accountID: ForgeAccountID
        let repository: ForgeRepositoryIdentity
        let operation: ForgeOperation
        let scope: ForgeUnknownMutationOutcomeScope
    }

    private var records: [ForgeUnknownMutationOutcomeRecord]
    private var queryValues: [Request] = []
    private var consumptionValues: [Request] = []

    init(records: [ForgeUnknownMutationOutcomeRecord]) {
        self.records = records
    }

    func unknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        let request = Request(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope
        )
        queryValues.append(request)
        return records.filter {
            $0.accountID == accountID
                && $0.repository == repository
                && $0.operation == operation
                && $0.scope == scope
        }
    }

    func consumeUnknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        let request = Request(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope
        )
        consumptionValues.append(request)
        let consumed = records.filter {
            $0.accountID == accountID
                && $0.repository == repository
                && $0.operation == operation
                && $0.scope == scope
        }
        let consumedIDs = Set(consumed.map(\.registrationID))
        records.removeAll { consumedIDs.contains($0.registrationID) }
        return consumed
    }

    func queries() -> [Request] {
        queryValues
    }

    func consumptions() -> [Request] {
        consumptionValues
    }

    func remainingRecords() -> [ForgeUnknownMutationOutcomeRecord] {
        records
    }
}

// swift6-safety-justification: the lock serializes all mutable spy state used across test tasks.
private final nonisolated class LocalReviewServiceSpy: RepositoryPullRequestLocalReviewServing, @unchecked Sendable {
    private let lock = NSLock()
    private var checkedOutHeads: [ForgeCommitID?]
    private let checkedOutHeadErrorAtCall: Int?
    private var checkedOutHeadCallCount = 0
    private let fetchError: RepositoryPullRequestReviewServiceError?
    private var fetched: [ForgeBranchReference] = []

    init(
        checkedOutHeads: [ForgeCommitID?] = [],
        checkedOutHeadErrorAtCall: Int? = nil,
        fetchError: RepositoryPullRequestReviewServiceError? = nil
    ) {
        self.checkedOutHeads = checkedOutHeads
        self.checkedOutHeadErrorAtCall = checkedOutHeadErrorAtCall
        self.fetchError = fetchError
    }

    func reanchorCandidates(
        for _: ForgeReviewContext,
        currentHead _: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate] {
        []
    }

    func checkedOutHead() async throws -> ForgeCommitID? {
        let result = lock.withLock { () -> (shouldThrow: Bool, head: ForgeCommitID?) in
            checkedOutHeadCallCount += 1
            let shouldThrow = checkedOutHeadCallCount == checkedOutHeadErrorAtCall
            let head = shouldThrow || checkedOutHeads.isEmpty ? nil : checkedOutHeads.removeFirst()
            return (shouldThrow, head)
        }
        if result.shouldThrow {
            throw RepositoryPullRequestReviewServiceError.unsafeLocalEdit
        }
        return result.head
    }

    func applySuggestedChange(_: ForgeSuggestedChange) async throws {}

    func fetchBase(_ base: ForgeBranchReference) async throws {
        lock.withLock {
            fetched.append(base)
        }
        if let fetchError {
            throw fetchError
        }
    }

    func checkOutBase(_: ForgeBranchReference) async throws {}

    func fetchedBranches() -> [ForgeBranchReference] {
        lock.withLock { fetched }
    }
}

// swift6-safety-justification: the lock serializes the binding used by sendable test closures.
private final nonisolated class LockedReviewBindingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ForgeRepositoryBinding?

    init(_ value: ForgeRepositoryBinding?) {
        storedValue = value
    }

    var value: ForgeRepositoryBinding? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
