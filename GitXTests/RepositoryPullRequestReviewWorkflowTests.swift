import ForgeKit
import XCTest

@MainActor
final class RepositoryPullRequestReviewWorkflowTests: XCTestCase {
    func testThreadPresenterKeepsExactAnchorOutdatedMarkerTombstonesAndReadOnlyReactions() throws {
        let fixture = try ReviewAppFixture()
        let row = try RepositoryReviewThreadPresenter.present(fixture.threadRecord(outdated: true))

        XCTAssertTrue(row.isOutdated)
        XCTAssertTrue(row.usesBestEffortLocalAnchor)
        XCTAssertEqual(row.anchorText, "Sources/File.swift:20")
        XCTAssertTrue(row.accessibilityLabel.contains("outdated"))
        XCTAssertTrue(row.accessibilityLabel.contains("exact local context match"))
        XCTAssertEqual(row.comments.map(\.bodyMarkdown), ["Please revise", nil, nil, nil])
        XCTAssertEqual(row.comments.map(\.statusText), [nil, "Minimized: Off-topic", "Deleted comment", "Comment unavailable"])
        XCTAssertEqual(row.comments.first?.reactionsText, "👀 1  👍 2")
        XCTAssertTrue(row.suggestedChanges.isEmpty)

        let optimistic = RepositoryReviewThreadResolutionPresenter.present(.optimistic(
            mutation: .resolve,
            priorValue: false,
            undoDeadline: fixture.now.addingTimeInterval(8)
        ))
        XCTAssertTrue(optimistic.isResolved)
        XCTAssertTrue(optimistic.canUndo)
        XCTAssertEqual(
            RepositoryReviewThreadResolutionPresenter.present(.unknownOutcome(lastKnownValue: false)),
            RepositoryReviewThreadResolutionPresentation(isResolved: false, canUndo: false)
        )

        let unavailableRow = try RepositoryReviewThreadPresenter.present(
            fixture.threadRecord(reportedCommentCount: 5)
        )
        XCTAssertNil(unavailableRow.comments.last?.id)
        XCTAssertEqual(unavailableRow.comments.last?.statusText, "Deleted or unavailable comment")

        let deletedRange = ForgeReviewAnchor(
            path: fixture.path,
            subject: .line,
            side: .left,
            startSide: .left,
            startLine: 9,
            line: 10,
            originalStartLine: 19,
            originalLine: 20
        )
        XCTAssertEqual(
            RepositoryReviewThreadPresenter.anchorDescription(deletedRange),
            "Sources/File.swift:19–20"
        )

        let collapsedAndResolved = row.updating(isExpanded: false, isResolved: true)
        XCTAssertFalse(collapsedAndResolved.isExpanded)
        XCTAssertTrue(collapsedAndResolved.isResolved)
        XCTAssertEqual(collapsedAndResolved.title, "Resolved review thread")
        XCTAssertTrue(collapsedAndResolved.accessibilityLabel.hasPrefix("Resolved review thread"))
    }

    func testThreadPresenterNeverRevealsAuthoritativelyMinimizedCommentWhenMapsAreMissing() throws {
        let fixture = try ReviewAppFixture()
        let comment = try ForgeReviewComment(
            repository: fixture.repository,
            id: ForgeObjectID(forge: fixture.repository.forge, value: "minimized-model-comment"),
            bodyMarkdown: "Hidden provider content",
            createdAt: fixture.now,
            updatedAt: fixture.now,
            author: .unavailable(.partialResponse),
            isMinimized: true,
            minimizedReason: "Abuse",
            reactions: [ForgeReviewReactionSummary(kind: .eyes, count: 2, viewerReacted: false)]
        )
        let thread = try ForgeReviewThread(
            repository: fixture.repository,
            id: fixture.threadID,
            isResolved: false,
            isOutdated: false,
            anchor: .available(fixture.anchor),
            comments: .available(ForgePage(items: [comment]))
        )
        let record = try RepositoryPullRequestReviewThreadRecord(
            pullRequest: fixture.number,
            presentation: ForgeReviewThreadPresentation(
                thread: thread,
                commentVisibility: [:],
                commentReactions: [:]
            )
        )

        let row = RepositoryReviewThreadPresenter.present(record)

        XCTAssertNil(row.comments.first?.bodyMarkdown)
        XCTAssertEqual(row.comments.first?.statusText, "Minimized: Abuse")
        XCTAssertEqual(row.comments.first?.reactionsText, "👀 2")
    }

    func testUnavailableCommentConnectionRendersOneExplicitTombstone() throws {
        let fixture = try ReviewAppFixture()
        let source = try fixture.threadRecord().presentation.thread
        let unavailable = ForgeReviewThread(
            repository: source.repository,
            id: source.id,
            isResolved: source.isResolved,
            isOutdated: source.isOutdated,
            anchor: source.anchor,
            comments: .unavailable(.partialResponse)
        )

        XCTAssertEqual(
            try RepositoryPullRequestReviewPartialDataPolicy.markingCommentsPartial(in: unavailable),
            unavailable
        )
        let record = try RepositoryPullRequestReviewThreadRecord(
            pullRequest: fixture.number,
            presentation: ForgeReviewThreadPresentation(
                thread: unavailable,
                commentVisibility: [:]
            )
        )
        let comments = RepositoryReviewThreadPresenter.present(record).comments
        XCTAssertEqual(comments.count, 1)
        XCTAssertNil(comments[0].id)
        XCTAssertNil(comments[0].bodyMarkdown)
        XCTAssertEqual(comments[0].statusText, "Comments unavailable")
        XCTAssertNil(comments[0].reactionsText)
    }

    func testPartialDataPoliciesPreserveEveryKnownCommentAndMissingThread() throws {
        let fixture = try ReviewAppFixture()
        let existing = try fixture.threadRecord()
        let source = existing.presentation.thread
        guard case let .available(page) = source.comments else {
            return XCTFail("Expected available fixture comments")
        }

        let merged = RepositoryPullRequestReviewPartialDataPolicy.mergingKnownComments(
            fresh: [page.items[1]],
            previous: source
        )
        XCTAssertEqual(
            merged.map(\.id),
            [page.items[1].id, page.items[0].id, page.items[2].id, page.items[3].id]
        )

        let preserved = try RepositoryPullRequestReviewPartialDataPolicy.preservingMissingThreads(
            fresh: [],
            previous: [existing]
        )
        XCTAssertEqual(preserved.count, 1)
        guard case let .available(preservedPage) = preserved[0].comments else {
            return XCTFail("Expected retained comments to be explicitly partial")
        }
        XCTAssertEqual(preservedPage.items.map(\.id), page.items.map(\.id))
        XCTAssertEqual(preservedPage.totalCount, page.items.count + 1)
    }

    func testLocalRefreshPolicyRefreshesOnlyAfterUpdateBranch() throws {
        let fixture = try ReviewAppFixture()
        let updatedHead = ForgeBranchReference(
            repository: fixture.repository,
            name: fixture.head.name,
            commit: fixture.newHead
        )

        for action in ForgePullRequestLifecycleAction.allCases {
            XCTAssertEqual(
                RepositoryPullRequestReviewLocalRefreshPolicy.remoteTrackingBranch(
                    after: action,
                    updatedHead: updatedHead
                ),
                action == .updateBranch ? updatedHead : nil
            )
        }
    }

    func testLoadRejectsCrossIdentityWorkspaceAndInstallsExactWorkspace() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        try await load(session)
        XCTAssertEqual(session.workspace?.identity, fixture.identity)
        XCTAssertEqual(session.workspace?.threads.count, 1)

        let wrong = try fixture.workspace(identity: fixture.otherIdentity)
        let wrongService = FakeReviewMutationService(workspaces: [wrong])
        let wrongSession = RepositoryPullRequestReviewSession(identity: fixture.identity, service: wrongService)
        let failed = expectation(description: "wrong identity rejected")
        wrongSession.onStateChange = { state in
            if case let .failed(message) = state,
               message == RepositoryPullRequestReviewServiceError.invalidWorkspace.localizedDescription
            {
                failed.fulfill()
            }
        }
        wrongSession.load()
        await fulfillment(of: [failed])
        wrongSession.onStateChange = nil
        XCTAssertNil(wrongSession.workspace)
    }

    func testOfflineAndRateLimitedRefreshesKeepLastGoodWorkspaceExplicitlyStale() async throws {
        let fixture = try ReviewAppFixture()
        let failures: [RepositoryPullRequestReviewServiceError] = [
            .offline,
            .rateLimited(until: fixture.now.addingTimeInterval(60)),
        ]

        for failure in failures {
            let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
            let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
            try await load(session)
            await service.failNextLoad(with: failure)
            let stale = expectation(description: "last-good workspace retained after \(failure)")
            session.onStateChange = { state in
                guard case let .stale(workspace, message) = state,
                      message == failure.localizedDescription,
                      workspace.isMutationStateFresh == false
                else { return }
                stale.fulfill()
            }

            session.load()
            await fulfillment(of: [stale])
            session.onStateChange = nil

            let retainedWorkspace = try XCTUnwrap(session.workspace)
            XCTAssertEqual(retainedWorkspace.displayedHead, fixture.oldHead)
            XCTAssertFalse(retainedWorkspace.isMutationStateFresh)
            await XCTAssertThrowsErrorAsync(try await session.performLifecycle(.close)) {
                XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
            }
            let lifecycleActions = await service.lifecycleActions()
            XCTAssertTrue(lifecycleActions.isEmpty)
        }

        let initialFailureService = FakeReviewMutationService(workspaces: [])
        await initialFailureService.failNextLoad(with: .offline)
        let initialFailure = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: initialFailureService
        )
        let failed = expectation(description: "initial offline load failed without invented data")
        initialFailure.onStateChange = { state in
            if case .failed = state {
                failed.fulfill()
            }
        }
        initialFailure.load()
        await fulfillment(of: [failed])
        initialFailure.onStateChange = nil
        XCTAssertNil(initialFailure.workspace)
    }

    func testRefreshPreservesLastGoodWorkspaceAsStaleUntilReplacementArrives() async throws {
        let fixture = try ReviewAppFixture()
        let initial = try fixture.workspace()
        let replacement = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [initial, replacement])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        try await load(session)

        await service.holdNextLoadCall()
        session.load()
        await service.waitForLoadCalls(2)

        guard case let .stale(refreshing, message) = session.state else {
            return XCTFail("Expected last-good Pull Request state to remain visible while refreshing")
        }
        XCTAssertEqual(refreshing.displayedHead, fixture.oldHead)
        XCTAssertFalse(refreshing.isMutationStateFresh)
        XCTAssertEqual(message, "Refreshing Pull Request…")
        await XCTAssertThrowsErrorAsync(try await session.performLifecycle(.close)) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }

        await service.releaseHeldLoad()
        try await waitForWorkspace(session, state: .open)
        XCTAssertEqual(session.workspace?.displayedHead, fixture.newHead)
        XCTAssertTrue(session.workspace?.isMutationStateFresh == true)
    }

    func testStaleLastGoodWorkspaceDisablesEveryWriteAndLocalMutation() async throws {
        let fixture = try ReviewAppFixture()
        let initial = try fixture.workspace(deletion: true)
        let service = FakeReviewMutationService(
            workspaces: [initial],
            freshMergeSnapshots: [initial.mergeSnapshot]
        )
        let drafts = FakeReviewDraftStore()
        let local = FakeLocalReviewService(
            candidates: [],
            checkedOutHead: fixture.oldHead,
            contents: "before\nlet old = true\nafter\n"
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        let confirmation = try await session.prepareMerge(method: .merge)

        await service.failNextLoad(with: .offline)
        let stale = expectation(description: "workspace became stale")
        session.onStateChange = { state in
            if case let .stale(_, message) = state,
               message == RepositoryPullRequestReviewServiceError.offline.localizedDescription
            {
                stale.fulfill()
            }
        }
        session.load()
        await fulfillment(of: [stale])
        session.onStateChange = nil

        try await assertStale(await session.prepareInlinePublication(
            context: fixture.reviewContext(head: fixture.oldHead),
            anchor: fixture.anchor,
            bodyMarkdown: "Never save"
        ))
        try await assertStale(await session.reply(
            threadID: fixture.threadID,
            bodyMarkdown: "Never reply"
        ))
        try await assertStale(await session.submitFormalReview(
            kind: .comment,
            bodyMarkdown: "Never review"
        ))
        try await assertStale(await session.applySuggestedChange(fixture.suggestedChange))
        try await assertStale(await session.performLifecycle(.close))
        try await assertStale(await session.prepareMerge(method: .merge))
        try await assertStale(await session.confirmMerge(
            confirmation,
            title: nil,
            message: nil,
            deleteHeadBranchChoice: false
        ))
        try await assertStale(await session.changeMergeQueue(.enter))
        try await assertStale(await session.deleteHeadBranch())
        try await assertStale(await session.fetchBase())
        try await assertStale(await session.checkOutBase())
        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)

        let inline = await service.inlinePublications()
        let replies = await service.replyPublications()
        let formalReviews = await service.formalReviews()
        let lifecycle = await service.lifecycleActions()
        let merges = await service.mergeRequests()
        let queue = await service.queueActions()
        let deletions = await service.deletionRequests()
        let resolutions = await service.resolutionMutations()
        let freshMerges = await service.freshMergeCallCount()
        let freshDeletions = await service.freshDeletionCallCount()
        let savedDrafts = await drafts.savedBodies()
        let fetches = await local.fetches()
        let checkouts = await local.checkouts()
        XCTAssertTrue(inline.isEmpty)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(formalReviews.isEmpty)
        XCTAssertTrue(lifecycle.isEmpty)
        XCTAssertTrue(merges.isEmpty)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(deletions.isEmpty)
        XCTAssertTrue(resolutions.isEmpty)
        XCTAssertEqual(freshMerges, 1)
        XCTAssertEqual(freshDeletions, 0)
        XCTAssertTrue(savedDrafts.isEmpty)
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertTrue(checkouts.isEmpty)
    }

    func testCancelledLoadThatIgnoresCancellationCannotOverwriteNewerWorkspace() async throws {
        let fixture = try ReviewAppFixture()
        let old = try fixture.workspace()
        let newest = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [old, newest])
        await service.holdNextLoadCall()
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)

        session.load()
        await service.waitForLoadCalls(1)
        session.load()
        await service.waitForLoadCalls(2)
        try await waitForWorkspace(session, state: .open)
        XCTAssertEqual(session.workspace?.displayedHead, fixture.newHead)

        let staleWorkspaceWasInstalled = expectation(description: "cancelled workspace stayed discarded")
        staleWorkspaceWasInstalled.isInverted = true
        session.onStateChange = { state in
            if case let .loaded(workspace) = state, workspace.displayedHead == fixture.oldHead {
                staleWorkspaceWasInstalled.fulfill()
            }
        }
        await service.releaseHeldLoad()
        await fulfillment(of: [staleWorkspaceWasInstalled], timeout: 0.1)
        session.onStateChange = nil
        XCTAssertEqual(session.workspace?.displayedHead, fixture.newHead)
    }

    func testInlinePublicationIsImmediateAndHeadChangeRequiresExplicitExactReanchor() async throws {
        let fixture = try ReviewAppFixture()
        let newWorkspace = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [newWorkspace, newWorkspace])
        let drafts = FakeReviewDraftStore()
        let local = try FakeLocalReviewService(
            candidates: [fixture.reanchorCandidate(head: fixture.newHead)],
            checkedOutHead: fixture.newHead,
            contents: "before\nlet old = true\nafter\n"
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)

        let pendingValue = try await session.prepareInlinePublication(
            context: fixture.reviewContext(head: fixture.oldHead),
            anchor: fixture.anchor,
            bodyMarkdown: "Publish immediately"
        )
        let pending = try XCTUnwrap(pendingValue)
        XCTAssertEqual(pending.proposedAnchor, fixture.localAnchor)
        let initialPublications = await service.inlinePublications()
        XCTAssertTrue(initialPublications.isEmpty)

        try await session.confirmReanchor(pending)
        let publications = await service.inlinePublications()
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications[0].displayedHead, fixture.newHead)
        XCTAssertEqual(publications[0].anchor, fixture.localAnchor)
        let savedInlineBodies = await drafts.savedBodies()
        let deletedInlineDrafts = await drafts.deleteCount()
        XCTAssertEqual(savedInlineBodies, ["Publish immediately", "Publish immediately"])
        XCTAssertEqual(deletedInlineDrafts, 2)

        let ambiguousLocal = try FakeLocalReviewService(
            candidates: [
                fixture.reanchorCandidate(head: fixture.newHead),
                fixture.reanchorCandidate(head: fixture.newHead, line: 40),
            ],
            checkedOutHead: fixture.newHead,
            contents: ""
        )
        let blocked = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: ambiguousLocal
        )
        try await load(blocked)
        await XCTAssertThrowsErrorAsync(try await blocked.prepareInlinePublication(
            context: fixture.reviewContext(head: fixture.oldHead),
            anchor: fixture.anchor,
            bodyMarkdown: "Never guess"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .ambiguousAnchor)
        }

        await XCTAssertThrowsErrorAsync(try await blocked.prepareInlinePublication(
            context: fixture.reviewContext(head: fixture.newHead, isTruncated: true),
            anchor: fixture.anchor,
            bodyMarkdown: "Never publish truncated context"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .truncatedAnchor)
        }
        let foreignContext = try ForgeReviewContext(
            repository: fixture.otherRepository,
            pullRequest: fixture.number,
            displayedHead: fixture.newHead,
            path: fixture.path,
            lines: ["let old = true"]
        )
        await XCTAssertThrowsErrorAsync(try await blocked.prepareInlinePublication(
            context: foreignContext,
            anchor: fixture.anchor,
            bodyMarkdown: "Never cross repository identity"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedRepository)
        }
    }

    func testInlineDraftIsDurableBeforeReanchorConfirmation() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [workspace])
        let drafts = FakeReviewDraftStore()
        let local = try FakeLocalReviewService(
            candidates: [fixture.reanchorCandidate(head: fixture.newHead)],
            checkedOutHead: fixture.newHead,
            contents: ""
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        let context = try fixture.reviewContext(head: fixture.oldHead)

        let pending = try await session.prepareInlinePublication(
            context: context,
            anchor: fixture.anchor,
            bodyMarkdown: "Keep this exact draft"
        )

        XCTAssertNotNil(pending)
        let preserved = try await session.loadInlineDraft(context: context, anchor: fixture.anchor)
        XCTAssertEqual(preserved, "Keep this exact draft")
        let publications = await service.inlinePublications()
        XCTAssertTrue(publications.isEmpty)
    }

    func testInlineDraftIdentityRejectsFileAndForeignAnchorsAndUsesLeftCoordinates() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        let context = try ForgeReviewContext(
            repository: fixture.repository,
            pullRequest: fixture.number,
            displayedHead: fixture.oldHead,
            path: fixture.path,
            lines: ["old first", "old second"]
        )
        let left = ForgeReviewAnchor(
            path: fixture.path,
            subject: .line,
            side: .left,
            startSide: .left,
            startLine: 9,
            line: 10,
            originalStartLine: 19,
            originalLine: 20
        )

        try await session.saveInlineDraft(context: context, anchor: left, bodyMarkdown: "Left draft")
        let identities = await drafts.savedIdentities()
        let identity = try XCTUnwrap(identities.last)
        guard case let .inlineReview(_, _, _, selection) = identity.destination else {
            return XCTFail("Expected an inline-review draft identity")
        }
        XCTAssertEqual(selection, try ForgeLineSelection(start: 19, end: 20))

        await XCTAssertThrowsErrorAsync(try await session.saveInlineDraft(
            context: context,
            anchor: ForgeReviewAnchor(path: fixture.path, subject: .file),
            bodyMarkdown: "Invalid file anchor"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .anchorUnavailable)
        }
        let foreign = try ForgeReviewContext(
            repository: fixture.otherRepository,
            pullRequest: fixture.number,
            displayedHead: fixture.oldHead,
            path: fixture.path,
            lines: ["foreign"]
        )
        await XCTAssertThrowsErrorAsync(try await session.saveInlineDraft(
            context: foreign,
            anchor: ForgeReviewAnchor(path: fixture.path, subject: .line, side: .right, line: 1),
            bodyMarkdown: "Foreign"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedRepository)
        }
    }

    func testReplyRejectsThreadAbsentFromFreshWorkspaceBeforeDraftOrServiceCall() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        let absentThreadID = try ForgeObjectID(
            forge: fixture.repository.forge,
            value: "thread-absent"
        )

        await XCTAssertThrowsErrorAsync(try await session.reply(
            threadID: absentThreadID,
            bodyMarkdown: "Never publish"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedPullRequest)
        }
        let replies = await service.replyPublications()
        let savedBodies = await drafts.savedBodies()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(savedBodies.isEmpty)
    }

    func testDelayedReanchorConfirmationRechecksFreshMutationEligibility() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [workspace])
        let drafts = FakeReviewDraftStore()
        let local = try FakeLocalReviewService(
            candidates: [fixture.reanchorCandidate(head: fixture.newHead)],
            checkedOutHead: fixture.newHead,
            contents: ""
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        let pendingValue = try await session.prepareInlinePublication(
            context: fixture.reviewContext(head: fixture.oldHead),
            anchor: fixture.anchor,
            bodyMarkdown: "Preserve while stale"
        )
        let pending = try XCTUnwrap(pendingValue)
        await service.failNextLoad(with: .offline)
        let stale = expectation(description: "refresh failure retained stale workspace")
        session.onStateChange = { state in
            if case let .stale(_, message) = state,
               message == RepositoryPullRequestReviewServiceError.offline.localizedDescription
            {
                stale.fulfill()
            }
        }
        session.load()
        await fulfillment(of: [stale])
        session.onStateChange = nil

        await XCTAssertThrowsErrorAsync(try await session.confirmReanchor(pending)) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }
        let publications = await service.inlinePublications()
        let savedBodies = await drafts.savedBodies()
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(savedBodies, ["Preserve while stale"])
    }

    func testReplyPublishesImmediatelyAndFormalReviewRefetchesHeadWhilePreservingDraft() async throws {
        let fixture = try ReviewAppFixture()
        let initial = try fixture.workspace()
        let changed = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [initial, changed])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)

        try await session.reply(threadID: fixture.threadID, bodyMarkdown: "Immediate reply")
        let replies = await service.replyPublications()
        let deletedReplyDrafts = await drafts.deleteCount()
        XCTAssertEqual(replies.map(\.bodyMarkdown), ["Immediate reply"])
        XCTAssertEqual(deletedReplyDrafts, 1)

        await XCTAssertThrowsErrorAsync(try await session.submitFormalReview(
            kind: .requestChanges,
            bodyMarkdown: "Head-bound review"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
        }
        let reviews = await service.formalReviews()
        let savedReviewBodies = await drafts.savedBodies()
        let deletedReviewDrafts = await drafts.deleteCount()
        XCTAssertTrue(reviews.isEmpty)
        XCTAssertEqual(savedReviewBodies.last, "Head-bound review")
        XCTAssertEqual(deletedReviewDrafts, 1, "The failed formal review draft must remain")
        XCTAssertEqual(session.workspace?.displayedHead, fixture.newHead)
    }

    func testFormalReviewPinsDraftAndSubmissionToExplicitlyConfirmedHead() async throws {
        let fixture = try ReviewAppFixture()
        let initial = try fixture.workspace()
        let refreshed = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(workspaces: [initial, refreshed, refreshed])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)

        let initialDraft = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)
        XCTAssertEqual(initialDraft, "")
        try await session.saveFormalReviewDraft(bodyMarkdown: "Draft for the displayed head")

        let installedNewHead = expectation(description: "background refresh installed a new head")
        session.onStateChange = { state in
            if case let .loaded(workspace) = state, workspace.displayedHead == fixture.newHead {
                installedNewHead.fulfill()
            }
        }
        session.load()
        await fulfillment(of: [installedNewHead])
        session.onStateChange = nil

        try await session.saveFormalReviewDraft(bodyMarkdown: "Still bound to the old head")
        await XCTAssertThrowsErrorAsync(try await session.submitFormalReview(
            kind: .comment,
            bodyMarkdown: "Must be confirmed again"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
        }
        let loadCallsBeforeConfirmation = await service.loadCalls()
        let prematureReviews = await service.formalReviews()
        let savedDisplayedHeads = await drafts.savedDisplayedHeads()
        XCTAssertEqual(loadCallsBeforeConfirmation, 2, "A changed local head must stop before preflight")
        XCTAssertTrue(prematureReviews.isEmpty)
        XCTAssertEqual(savedDisplayedHeads, [fixture.oldHead, fixture.oldHead])

        let refreshedDraft = try await session.loadFormalReviewDraft(displayedHead: fixture.newHead)
        XCTAssertEqual(refreshedDraft, "")
        try await session.submitFormalReview(
            displayedHead: fixture.newHead,
            kind: .comment,
            bodyMarkdown: "Confirmed on the refreshed head"
        )

        let reviews = await service.formalReviews()
        XCTAssertEqual(reviews.map(\.displayedHead), [fixture.newHead])
        XCTAssertEqual(reviews.map(\.bodyMarkdown), ["Confirmed on the refreshed head"])
    }

    func testFormalReviewRejectsHeadThatWasNotTheExplicitlyPreparedSheetHead() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        _ = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)

        await XCTAssertThrowsErrorAsync(try await session.saveFormalReviewDraft(
            displayedHead: fixture.newHead,
            bodyMarkdown: "Wrong head"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
        }
        await XCTAssertThrowsErrorAsync(try await session.submitFormalReview(
            displayedHead: fixture.newHead,
            kind: .approve,
            bodyMarkdown: "Wrong head"
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .displayedHeadChanged)
        }

        let savedBodies = await drafts.savedBodies()
        let reviews = await service.formalReviews()
        let loadCalls = await service.loadCalls()
        XCTAssertTrue(savedBodies.isEmpty)
        XCTAssertTrue(reviews.isEmpty)
        XCTAssertEqual(loadCalls, 1)
    }

    func testFormalReviewRefetchRechecksExactCapabilityAndPreservesDraft() async throws {
        let fixture = try ReviewAppFixture()
        var allowed = Set(ForgeOperation.allCases)
        allowed.remove(.submitApproveReview)
        let initial = try fixture.workspace()
        let restricted = try fixture.workspace(allowedOperations: allowed)
        let service = FakeReviewMutationService(workspaces: [initial, restricted])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)
        _ = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)

        await XCTAssertThrowsErrorAsync(try await session.submitFormalReview(
            displayedHead: fixture.oldHead,
            kind: .approve,
            bodyMarkdown: "Preserve after permission change"
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .unavailable)
        }

        let reviews = await service.formalReviews()
        let savedBodies = await drafts.savedBodies()
        XCTAssertTrue(reviews.isEmpty)
        XCTAssertEqual(savedBodies, ["Preserve after permission change"])
        let refreshedWorkspace = try XCTUnwrap(session.workspace)
        XCTAssertFalse(refreshedWorkspace.mutationContext.allowedOperations.contains(
            .submitApproveReview
        ))
    }

    func testPublishedReplyRemainsSuccessfulWhenLocalDraftCleanupFails() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let drafts = FakeReviewDraftStore()
        await drafts.failDeletes(with: .unavailable)
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)

        try await session.reply(threadID: fixture.threadID, bodyMarkdown: "Exactly once")

        let replies = await service.replyPublications()
        XCTAssertEqual(replies.map(\.bodyMarkdown), ["Exactly once"])
        XCTAssertNotNil(session.workspace)
    }

    func testReplyRechecksCapabilityAfterDurableDraftSave() async throws {
        let fixture = try ReviewAppFixture()
        var allowed = Set(ForgeOperation.allCases)
        allowed.remove(.replyToReviewThread)
        let initial = try fixture.workspace()
        let restricted = try fixture.workspace(allowedOperations: allowed)
        let service = FakeReviewMutationService(workspaces: [initial, restricted])
        let drafts = FakeReviewDraftStore()
        await drafts.holdNextSave()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        try await load(session)

        let reply = Task { @MainActor in
            try await session.reply(threadID: fixture.threadID, bodyMarkdown: "Durable before recheck")
        }
        await drafts.waitForSaveCalls(1)
        session.load()
        try await waitForWorkspace(session, state: .open)
        await drafts.releaseHeldSave()

        await XCTAssertThrowsErrorAsync(try await reply.value) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .unavailable)
        }
        let replies = await service.replyPublications()
        let savedBodies = await drafts.savedBodies()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(savedBodies, ["Durable before recheck"])
    }

    func testWorkspaceRejectsDuplicateDraftStateThatDisagreesWithMutationContext() throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()

        XCTAssertThrowsError(try RepositoryPullRequestReviewWorkspace(
            identity: workspace.identity,
            displayedHead: workspace.displayedHead,
            base: workspace.base,
            title: workspace.title,
            isDraft: true,
            threads: workspace.threads,
            reviewers: workspace.reviewers,
            mutationContext: workspace.mutationContext,
            mergeSnapshot: workspace.mergeSnapshot,
            canUpdateBranch: workspace.canUpdateBranch,
            fetchedAt: workspace.fetchedAt
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedPullRequest)
        }
    }

    func testWorkspaceAndThreadRecordsRejectInconsistentDerivedMutationState() throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()

        XCTAssertThrowsError(try RepositoryPullRequestReviewWorkspace(
            identity: workspace.identity,
            displayedHead: workspace.displayedHead,
            base: workspace.base,
            title: workspace.title,
            isDraft: workspace.isDraft,
            threads: workspace.threads,
            reviewers: workspace.reviewers,
            mutationContext: workspace.mutationContext,
            mergeSnapshot: workspace.mergeSnapshot,
            headBranchDeletionSnapshot: workspace.headBranchDeletionSnapshot,
            canUpdateBranch: true,
            fetchedAt: workspace.fetchedAt
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }

        let wrongHeadSuggestion = try ForgeSuggestedChange(
            repository: fixture.repository,
            pullRequest: fixture.number,
            displayedHead: fixture.newHead,
            path: fixture.path,
            originalText: "old",
            replacementText: "new"
        )
        let wrongHeadRecord = try fixture.threadRecord(suggestedChanges: [wrongHeadSuggestion])
        XCTAssertThrowsError(try RepositoryPullRequestReviewWorkspace(
            identity: workspace.identity,
            displayedHead: workspace.displayedHead,
            base: workspace.base,
            title: workspace.title,
            isDraft: workspace.isDraft,
            threads: [wrongHeadRecord],
            reviewers: workspace.reviewers,
            mutationContext: workspace.mutationContext,
            mergeSnapshot: workspace.mergeSnapshot,
            headBranchDeletionSnapshot: workspace.headBranchDeletionSnapshot,
            canUpdateBranch: false,
            fetchedAt: workspace.fetchedAt
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .mismatchedPullRequest)
        }

        let otherPath = try ForgeFilePath("Sources/Other.swift")
        XCTAssertThrowsError(try fixture.threadRecord(
            outdated: true,
            exactOutdatedLocalAnchor: ForgeReviewAnchor(
                path: otherPath,
                subject: .line,
                side: .right,
                line: 20
            )
        )) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .invalidContext)
        }
    }

    func testResolveReconcilesAuthoritativelyAndFailureRestoresPriorValue() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [
            fixture.workspace(),
            fixture.workspace(threadIsResolved: true),
        ])
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            now: { fixture.now },
            undoInterval: 8
        )
        try await load(session)

        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)
        await service.waitForResolutionCalls(1)
        await service.waitForLoadCalls(2)
        XCTAssertEqual(
            session.resolutionStates[fixture.threadID],
            .optimistic(mutation: .resolve, priorValue: false, undoDeadline: fixture.now.addingTimeInterval(8))
        )
        session.expireResolutionUndo(threadID: fixture.threadID, at: fixture.now.addingTimeInterval(8))
        XCTAssertEqual(session.resolutionStates[fixture.threadID], .confirmed(isResolved: true))

        await service.failNextResolution(with: .authoritative("Denied"))
        session.setResolution(threadID: fixture.threadID, mutation: .unresolve, at: fixture.now)
        await service.waitForResolutionCalls(2)
        await service.waitForResolutionFailureDelivered()
        XCTAssertEqual(session.resolutionStates[fixture.threadID], .confirmed(isResolved: true))
        let resolutionMutations = await service.resolutionMutations()
        XCTAssertEqual(resolutionMutations, [.resolve, .unresolve])
    }

    func testCancelledResolutionGenerationCannotOverwriteNewerUndoWithUnknownOutcome() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [
            fixture.workspace(),
            fixture.workspace(threadIsResolved: false),
        ])
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            now: { fixture.now },
            undoInterval: 8
        )
        try await load(session)
        await service.holdNextResolutionCall()

        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)
        await service.waitForResolutionCalls(1)
        session.undoResolution(threadID: fixture.threadID, at: fixture.now.addingTimeInterval(2))

        let inverseDispatchedEarly = expectation(description: "inverse resolution waited for its predecessor")
        inverseDispatchedEarly.isInverted = true
        let prematureWaiter = Task {
            await service.waitForResolutionCalls(2)
            guard !Task.isCancelled else { return }
            inverseDispatchedEarly.fulfill()
        }
        await fulfillment(of: [inverseDispatchedEarly], timeout: 0.1)
        prematureWaiter.cancel()

        let staleOutcomeWasPublished = expectation(description: "stale unknown outcome was ignored")
        staleOutcomeWasPublished.isInverted = true
        session.onOutcomeUnknown = { staleOutcomeWasPublished.fulfill() }
        await service.releaseHeldResolution(with: .outcomeUnknown)
        await service.waitForResolutionCalls(2)
        await service.waitForLoadCalls(2)
        await fulfillment(of: [staleOutcomeWasPublished], timeout: 0.1)
        session.onOutcomeUnknown = nil

        XCTAssertEqual(
            session.resolutionStates[fixture.threadID],
            .optimistic(
                mutation: .unresolve,
                priorValue: true,
                undoDeadline: fixture.now.addingTimeInterval(8)
            )
        )
        let mutations = await service.resolutionMutations()
        let loadCalls = await service.loadCalls()
        XCTAssertEqual(mutations, [.resolve, .unresolve])
        XCTAssertEqual(loadCalls, 2, "Only the successful inverse receives an authoritative reconciliation")
        session.expireResolutionUndo(threadID: fixture.threadID, at: fixture.now.addingTimeInterval(8))
        XCTAssertEqual(session.resolutionStates[fixture.threadID], .confirmed(isResolved: false))
    }

    func testResolutionAuthoritativeMismatchReplacesOptimismWithoutRetrying() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [
            fixture.workspace(),
            fixture.workspace(threadIsResolved: false),
        ])
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            now: { fixture.now },
            undoInterval: 8
        )
        try await load(session)
        let mismatch = expectation(description: "authoritative mismatch surfaced")
        session.onMutationError = { message in
            if message == "GitHub reported a different review-thread resolution state." {
                mismatch.fulfill()
            }
        }

        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)
        await service.waitForResolutionCalls(1)
        await service.waitForLoadCalls(2)
        await fulfillment(of: [mismatch])
        session.onMutationError = nil

        XCTAssertEqual(session.resolutionStates[fixture.threadID], .confirmed(isResolved: false))
        let mutations = await service.resolutionMutations()
        let loadCalls = await service.loadCalls()
        XCTAssertEqual(mutations, [.resolve])
        XCTAssertEqual(loadCalls, 2)
    }

    func testResolutionSuccessWithFailedReconciliationStaysAcknowledgedAndMarksWorkspaceStale() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            now: { fixture.now },
            undoInterval: 8
        )
        try await load(session)
        let failure = expectation(description: "authoritative refresh failure surfaced")
        var unknownWasPublished = false
        session.onMutationError = { message in
            if message == RepositoryPullRequestReviewServiceError.unavailable.localizedDescription {
                failure.fulfill()
            }
        }
        session.onOutcomeUnknown = { unknownWasPublished = true }

        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)
        await service.waitForResolutionCalls(1)
        await service.waitForLoadCalls(2)
        await fulfillment(of: [failure])
        session.onMutationError = nil
        session.onOutcomeUnknown = nil

        XCTAssertEqual(
            session.resolutionStates[fixture.threadID],
            .confirmed(isResolved: true)
        )
        guard case let .stale(workspace, message) = session.state else {
            return XCTFail("Expected the acknowledged mutation to preserve a stale workspace")
        }
        XCTAssertFalse(workspace.isMutationStateFresh)
        XCTAssertEqual(message, RepositoryPullRequestReviewServiceError.unavailable.localizedDescription)
        XCTAssertFalse(unknownWasPublished)
        let mutations = await service.resolutionMutations()
        XCTAssertEqual(mutations, [.resolve])
    }

    func testResolutionSuccessWithStaleReconciliationKeepsReceiptAcknowledged() async throws {
        let fixture = try ReviewAppFixture()
        let staleReconciliation = try fixture.workspace(threadIsResolved: false)
            .markingMutationStateFresh(false)
        let service = try FakeReviewMutationService(workspaces: [
            fixture.workspace(),
            staleReconciliation,
        ])
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            now: { fixture.now },
            undoInterval: 8
        )
        try await load(session)
        let failure = expectation(description: "stale reconciliation surfaced")
        var unknownWasPublished = false
        session.onMutationError = { message in
            if message == RepositoryPullRequestReviewServiceError.stalePullRequest.localizedDescription {
                failure.fulfill()
            }
        }
        session.onOutcomeUnknown = { unknownWasPublished = true }

        session.setResolution(threadID: fixture.threadID, mutation: .resolve, at: fixture.now)
        await service.waitForResolutionCalls(1)
        await service.waitForLoadCalls(2)
        await fulfillment(of: [failure])
        session.onMutationError = nil
        session.onOutcomeUnknown = nil

        XCTAssertEqual(session.resolutionStates[fixture.threadID], .confirmed(isResolved: true))
        guard case let .stale(workspace, message) = session.state else {
            return XCTFail("Expected the partial reconciliation to remain stale")
        }
        XCTAssertFalse(workspace.isMutationStateFresh)
        XCTAssertEqual(message, RepositoryPullRequestReviewServiceError.stalePullRequest.localizedDescription)
        XCTAssertFalse(unknownWasPublished)
        let mutations = await service.resolutionMutations()
        XCTAssertEqual(mutations, [.resolve])
    }

    func testSuggestedChangeRequiresExactCheckedOutCleanContextAndWritesOneUnstagedEdit() async throws {
        let fixture = try ReviewAppFixture()
        let service = try FakeReviewMutationService(workspaces: [fixture.workspace()])
        let local = FakeLocalReviewService(
            candidates: [],
            checkedOutHead: fixture.oldHead,
            contents: "before\nlet old = true\nafter\n"
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local
        )
        try await load(session)

        try await session.applySuggestedChange(fixture.suggestedChange)
        let appliedWrites = await local.writes()
        XCTAssertEqual(
            appliedWrites,
            [.init(path: fixture.path, contents: "before\nlet new = true\nafter\n")]
        )

        await local.setEditedFiles([fixture.path])
        await XCTAssertThrowsErrorAsync(try await session.applySuggestedChange(fixture.suggestedChange)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .uncommittedTargetFile)
        }
        let unchangedWrites = await local.writes()
        XCTAssertEqual(unchangedWrites.count, 1)
    }

    func testProductionSuggestedChangeServiceRevalidatesAndWritesInsideOneSerializedOperation() async throws {
        let fixture = try ReviewAppFixture()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent(fixture.path.value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data("before\nlet old = true\nafter\n".utf8).write(to: fileURL)
        let runner = AtomicSuggestedChangeGitRunner(head: fixture.oldHead, status: "")
        let local = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: temporaryDirectory
        )

        try await local.applySuggestedChange(fixture.suggestedChange)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "before\nlet new = true\nafter\n"
        )
        XCTAssertEqual(runner.commands, [
            ["rev-parse", "--verify", "HEAD"],
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", fixture.path.value],
        ])

        let dirtyRunner = AtomicSuggestedChangeGitRunner(
            head: fixture.oldHead,
            status: " M \(fixture.path.value)\0"
        )
        let dirty = RepositoryPullRequestLocalReviewService(
            runner: dirtyRunner,
            workingDirectory: temporaryDirectory
        )
        await XCTAssertThrowsErrorAsync(try await dirty.applySuggestedChange(fixture.suggestedChange)) {
            XCTAssertEqual($0 as? ForgeReviewMutationError, .uncommittedTargetFile)
        }
    }

    func testProductionSuggestedChangeServiceRejectsTargetAndAncestorSymlinksBeforeReadOrWrite() async throws {
        let fixture = try ReviewAppFixture()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourcesDirectory = temporaryDirectory.appendingPathComponent("Sources", isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent(fixture.path.value)
        let outsideURL = outsideDirectory.appendingPathComponent("Outside.swift")
        try FileManager.default.createDirectory(
            at: sourcesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try Data("before\nlet old = true\nafter\n".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: outsideURL)
        let runner = AtomicSuggestedChangeGitRunner(head: fixture.oldHead, status: "")
        let local = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: temporaryDirectory
        )

        await XCTAssertThrowsErrorAsync(try await local.contents(of: fixture.path)) {
            self.assertUnsafeLocalEdit($0)
        }
        await XCTAssertThrowsErrorAsync(
            try await local.writeUnstaged(contents: "must not be written", to: fixture.path)
        ) {
            self.assertUnsafeLocalEdit($0)
        }
        await XCTAssertThrowsErrorAsync(try await local.applySuggestedChange(fixture.suggestedChange)) {
            self.assertUnsafeLocalEdit($0)
        }
        XCTAssertEqual(
            try String(contentsOf: outsideURL, encoding: .utf8),
            "before\nlet old = true\nafter\n"
        )

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: sourcesDirectory)
        let linkedSources = outsideDirectory.appendingPathComponent("LinkedSources", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedSources, withIntermediateDirectories: true)
        let linkedFile = linkedSources.appendingPathComponent("File.swift")
        try Data("before\nlet old = true\nafter\n".utf8).write(to: linkedFile)
        try FileManager.default.createSymbolicLink(
            at: sourcesDirectory,
            withDestinationURL: linkedSources
        )

        await XCTAssertThrowsErrorAsync(try await local.applySuggestedChange(fixture.suggestedChange)) {
            self.assertUnsafeLocalEdit($0)
        }
        XCTAssertEqual(
            try String(contentsOf: linkedFile, encoding: .utf8),
            "before\nlet old = true\nafter\n"
        )
    }

    func testProductionSuggestedChangeServiceRejectsNonRegularTargetBeforeReadOrWrite() async throws {
        let fixture = try ReviewAppFixture()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent(fixture.path.value, isDirectory: true)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let runner = AtomicSuggestedChangeGitRunner(head: fixture.oldHead, status: "")
        let local = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: temporaryDirectory
        )

        await XCTAssertThrowsErrorAsync(try await local.contents(of: fixture.path)) {
            self.assertUnsafeLocalEdit($0)
        }
        await XCTAssertThrowsErrorAsync(
            try await local.writeUnstaged(contents: "must not be written", to: fixture.path)
        ) {
            self.assertUnsafeLocalEdit($0)
        }
        await XCTAssertThrowsErrorAsync(try await local.applySuggestedChange(fixture.suggestedChange)) {
            self.assertUnsafeLocalEdit($0)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testLifecycleQueueDeleteAndPostMergeActionsStaySeparateAndExplicit() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(canUpdateBranch: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let service = FakeReviewMutationService(workspaces: [open], mutationWorkspace: merged)
        let local = FakeLocalReviewService(
            candidates: [],
            checkedOutHead: fixture.oldHead,
            contents: ""
        )
        let preferences = FakeMutationPreferences()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            preferences: preferences
        )
        try await load(session)

        await XCTAssertThrowsErrorAsync(try await session.fetchBase()) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }
        await XCTAssertThrowsErrorAsync(try await session.checkOutBase()) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }

        try await session.performLifecycle(.updateBranch)
        let lifecycleActions = await service.lifecycleActions()
        let mergesAfterUpdate = await service.mergeRequests()
        XCTAssertEqual(lifecycleActions, [.updateBranch])
        XCTAssertTrue(mergesAfterUpdate.isEmpty, "Update Branch must never merge")

        // Install an open workspace again so queue entry remains independently eligible.
        await service.enqueueWorkspace(open)
        session.load()
        try await waitForWorkspace(session, state: .open)
        try await session.changeMergeQueue(.enter)
        let queueActions = await service.queueActions()
        let deletionsAfterQueue = await service.deletionRequests()
        let deletionPreflightsAfterQueue = await service.freshDeletionCallCount()
        XCTAssertEqual(queueActions, [.enter])
        XCTAssertTrue(deletionsAfterQueue.isEmpty, "Queue entry never schedules deletion")
        XCTAssertEqual(deletionPreflightsAfterQueue, 0, "Queue entry must not even preflight deletion")

        await service.enqueueWorkspace(merged)
        session.load()
        try await waitForWorkspace(session, state: .merged)
        // Branch deletion reconciles immediately; keep a fresh merged result
        // available so the separate local post-merge actions remain enabled.
        await service.enqueueWorkspace(merged)
        try await session.deleteHeadBranch()
        try await waitForWorkspace(session, state: .merged)
        let explicitDeletions = await service.deletionRequests()
        let explicitDeletionPreflights = await service.freshDeletionCallCount()
        let explicitDeleteChoices = await preferences.deleteChoices()
        XCTAssertEqual(explicitDeletions.map(\.branch), [fixture.head.name])
        XCTAssertEqual(explicitDeletionPreflights, 1)
        XCTAssertTrue(explicitDeleteChoices.contains(true))

        try await session.fetchBase()
        let fetches = await local.fetches()
        let checkoutsAfterFetch = await local.checkouts()
        XCTAssertEqual(fetches, [fixture.base])
        XCTAssertTrue(checkoutsAfterFetch.isEmpty, "Fetch must not change checkout")
        try await session.checkOutBase()
        let explicitCheckouts = await local.checkouts()
        XCTAssertEqual(explicitCheckouts, [fixture.base])
    }

    func testHeadDeletionDispatchRechecksExactWorkspaceAndLocalCheckout() throws {
        let fixture = try ReviewAppFixture()
        let openWorkspace = try fixture.workspace(deletion: true)
        let openSnapshot = try XCTUnwrap(openWorkspace.headBranchDeletionSnapshot)
        XCTAssertTrue(RepositoryPullRequestHeadDeletionOfferPolicy.canOfferAfterMerge(openSnapshot))
        XCTAssertFalse(RepositoryPullRequestHeadDeletionOfferPolicy.canOfferAfterMerge(
            ForgeHeadBranchDeletionSnapshot(
                mergeSnapshot: openSnapshot.mergeSnapshot,
                isSameRepository: openSnapshot.isSameRepository,
                isDefaultBranch: openSnapshot.isDefaultBranch,
                isProtected: openSnapshot.isProtected,
                viewerCanDelete: openSnapshot.viewerCanDelete,
                hasCheckedOutSafetyConflict: true
            )
        ))

        let workspace = try fixture.workspace(state: .merged, deletion: true)
        let snapshot = try XCTUnwrap(workspace.headBranchDeletionSnapshot)
        guard case let .available(request) = ForgeHeadBranchDeletionPolicy.decision(
            snapshot: snapshot,
            mergeWasQueued: false
        ) else {
            return XCTFail("Expected an available exact deletion request")
        }

        XCTAssertNoThrow(try RepositoryPullRequestHeadDeletionDispatchPolicy.validate(
            request: request,
            workspace: workspace,
            checkedOutHead: fixture.newHead
        ))
        XCTAssertThrowsError(try RepositoryPullRequestHeadDeletionDispatchPolicy.validate(
            request: request,
            workspace: workspace,
            checkedOutHead: fixture.oldHead
        )) {
            XCTAssertEqual(
                $0 as? RepositoryPullRequestReviewServiceError,
                .authoritative("The checked-out branch cannot be deleted")
            )
        }
        let changed = try fixture.workspace(state: .merged, head: fixture.newHead, deletion: true)
        XCTAssertThrowsError(try RepositoryPullRequestHeadDeletionDispatchPolicy.validate(
            request: request,
            workspace: changed,
            checkedOutHead: nil
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }
    }

    func testUnknownLifecycleOutcomeReconcilesWithoutAutomaticRetry() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [open, open])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        try await load(session)
        await service.failNextLifecycle(with: .outcomeUnknown)
        let reconciliationStarted = expectation(description: "unknown lifecycle outcome reconciles")
        session.onOutcomeUnknown = { reconciliationStarted.fulfill() }

        await XCTAssertThrowsErrorAsync(try await session.performLifecycle(.close)) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .outcomeUnknown)
        }

        await fulfillment(of: [reconciliationStarted])
        session.onOutcomeUnknown = nil
        await service.waitForLoadCalls(2)
        let actions = await service.lifecycleActions()
        XCTAssertEqual(actions, [.close], "Unknown outcomes must never retry a mutation")
    }

    func testMergeRefetchesTwiceStopsRaceRecordsPreferencesAndKeepsDeletionFailureSeparate() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(deletion: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let snapshot = open.mergeSnapshot
        let service = FakeReviewMutationService(
            workspaces: [open],
            mutationWorkspace: merged,
            freshMergeSnapshots: [snapshot, snapshot]
        )
        let preferences = FakeMutationPreferences()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            preferences: preferences
        )
        try await load(session)

        let confirmation = try await session.prepareMerge(method: .squash)
        try await session.confirmMerge(
            confirmation,
            title: "Squashed title",
            message: "Squashed message",
            deleteHeadBranchChoice: true
        )
        let freshMergeCalls = await service.freshMergeCallCount()
        let mergeRequests = await service.mergeRequests()
        let preferredMethods = await preferences.mergeMethods()
        let deleteChoices = await preferences.deleteChoices()
        let deletionRequests = await service.deletionRequests()
        XCTAssertEqual(freshMergeCalls, 2)
        XCTAssertEqual(mergeRequests.first?.confirmation.method, .squash)
        XCTAssertEqual(preferredMethods, [.squash])
        XCTAssertEqual(deleteChoices, [true])
        XCTAssertTrue(deletionRequests.isEmpty, "Merge and branch deletion are distinct mutations")

        let changedSnapshot = try fixture.workspace(head: fixture.newHead).mergeSnapshot
        let racingService = FakeReviewMutationService(
            workspaces: [open],
            freshMergeSnapshots: [snapshot, changedSnapshot]
        )
        let racing = RepositoryPullRequestReviewSession(identity: fixture.identity, service: racingService)
        try await load(racing)
        let staleConfirmation = try await racing.prepareMerge(method: .merge)
        await XCTAssertThrowsErrorAsync(try await racing.confirmMerge(
            staleConfirmation,
            title: "Title",
            message: "Message",
            deleteHeadBranchChoice: false
        )) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .staleConfirmation)
        }
        let racingMergeRequests = await racingService.mergeRequests()
        XCTAssertTrue(racingMergeRequests.isEmpty)

        let unknownService = FakeReviewMutationService(
            workspaces: [open, open],
            freshMergeSnapshots: [snapshot, snapshot],
            mergeError: .outcomeUnknown
        )
        let unknown = RepositoryPullRequestReviewSession(identity: fixture.identity, service: unknownService)
        try await load(unknown)
        let unknownConfirmation = try await unknown.prepareMerge(method: .merge)
        let reconciled = expectation(description: "unknown merge schedules one reconciliation refresh")
        unknown.onOutcomeUnknown = { reconciled.fulfill() }
        await XCTAssertThrowsErrorAsync(try await unknown.confirmMerge(
            unknownConfirmation,
            title: "Title",
            message: "Message",
            deleteHeadBranchChoice: false
        )) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .outcomeUnknown)
        }
        await fulfillment(of: [reconciled])
        unknown.onOutcomeUnknown = nil
        await unknownService.waitForLoadCalls(2)
        let unknownMergeRequests = await unknownService.mergeRequests()
        XCTAssertEqual(unknownMergeRequests.count, 1, "Unknown outcomes are never retried")
    }

    private func load(_ session: RepositoryPullRequestReviewSession) async throws {
        let loaded = expectation(description: "workspace loaded")
        session.onStateChange = { state in
            if case .loaded = state {
                loaded.fulfill()
            }
        }
        session.load()
        await fulfillment(of: [loaded])
        session.onStateChange = nil
        _ = try XCTUnwrap(session.workspace)
    }

    private func waitForWorkspace(
        _ session: RepositoryPullRequestReviewSession,
        state: ForgePullRequestState
    ) async throws {
        if case let .loaded(workspace) = session.state,
           workspace.mutationContext.state == state
        {
            return
        }
        let loaded = expectation(description: "workspace reached \(state.rawValue)")
        session.onStateChange = { value in
            if case let .loaded(workspace) = value, workspace.mutationContext.state == state {
                loaded.fulfill()
            }
        }
        await fulfillment(of: [loaded])
        session.onStateChange = nil
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ handler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            handler(error)
        }
    }

    private func assertStale<T>(_ expression: @autoclosure () async throws -> T) async {
        await XCTAssertThrowsErrorAsync(try await expression()) {
            XCTAssertEqual($0 as? RepositoryPullRequestReviewServiceError, .stalePullRequest)
        }
    }

    private func assertUnsafeLocalEdit(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            error as? RepositoryPullRequestReviewServiceError,
            .unsafeLocalEdit,
            file: file,
            line: line
        )
        XCTAssertEqual(
            error.localizedDescription,
            RepositoryPullRequestReviewServiceError.unsafeLocalEdit.localizedDescription,
            file: file,
            line: line
        )
    }
}

struct ReviewAppFixture: Sendable {
    let now = Date(timeIntervalSince1970: 1000)
    let repository: ForgeRepositoryIdentity
    let otherRepository: ForgeRepositoryIdentity
    let accountID: ForgeAccountID
    let otherAccountID: ForgeAccountID
    let number = try! ForgeItemNumber(42)
    let oldHead = try! ForgeCommitID(String(repeating: "a", count: 40))
    let newHead = try! ForgeCommitID(String(repeating: "b", count: 40))
    let baseCommit = try! ForgeCommitID(String(repeating: "c", count: 40))
    let path = try! ForgeFilePath("Sources/File.swift")
    let head: ForgeBranchReference
    let base: ForgeBranchReference
    let identity: RepositoryPullRequestReviewIdentity
    let otherIdentity: RepositoryPullRequestReviewIdentity
    let threadID: ForgeObjectID
    let anchor: ForgeReviewAnchor
    let localAnchor: ForgeReviewAnchor
    let suggestedChange: ForgeSuggestedChange

    init() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        otherRepository = try ForgeRepositoryIdentity(forge: forge, owner: "other", name: "gitx")
        accountID = try ForgeAccountID(forge: forge, value: "account")
        otherAccountID = try ForgeAccountID(forge: forge, value: "other-account")
        head = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("feature/review"),
            commit: oldHead
        )
        base = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("main"),
            commit: baseCommit
        )
        identity = try RepositoryPullRequestReviewIdentity(
            accountID: accountID,
            repository: repository,
            number: number
        )
        otherIdentity = try RepositoryPullRequestReviewIdentity(
            accountID: otherAccountID,
            repository: otherRepository,
            number: number
        )
        threadID = try ForgeObjectID(forge: forge, value: "thread-1")
        anchor = ForgeReviewAnchor(path: path, subject: .line, side: .right, line: 10)
        localAnchor = ForgeReviewAnchor(path: path, subject: .line, side: .right, line: 20)
        suggestedChange = try ForgeSuggestedChange(
            repository: repository,
            pullRequest: number,
            displayedHead: oldHead,
            path: path,
            originalText: "let old = true",
            replacementText: "let new = true"
        )
    }

    func reviewContext(head: ForgeCommitID, isTruncated: Bool = false) throws -> ForgeReviewContext {
        try ForgeReviewContext(
            repository: repository,
            pullRequest: number,
            displayedHead: head,
            path: path,
            lines: ["let old = true"],
            isTruncated: isTruncated
        )
    }

    func reanchorCandidate(head: ForgeCommitID, line: Int = 20) throws -> ForgeReviewReanchorCandidate {
        try ForgeReviewReanchorCandidate(
            repository: repository,
            pullRequest: number,
            displayedHead: head,
            anchor: ForgeReviewAnchor(path: path, subject: .line, side: .right, line: line),
            contextLines: ["let old = true"]
        )
    }

    func threadRecord(
        outdated: Bool = false,
        reportedCommentCount: Int? = nil,
        isResolved: Bool = false,
        displayedHead: ForgeCommitID? = nil,
        exactOutdatedLocalAnchor: ForgeReviewAnchor? = nil,
        suggestedChanges: [ForgeSuggestedChange]? = nil
    ) throws -> RepositoryPullRequestReviewThreadRecord {
        let commentIDs = try (1 ... 4).map {
            try ForgeObjectID(forge: repository.forge, value: "comment-\($0)")
        }
        let comments = (0 ..< 4).map { index in
            ForgeReviewComment(
                repository: repository,
                id: commentIDs[index],
                bodyMarkdown: index == 0 ? "Please revise" : "Hidden",
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index)),
                author: .unavailable(.partialResponse)
            )
        }
        let thread = try ForgeReviewThread(
            repository: repository,
            id: threadID,
            isResolved: isResolved,
            isOutdated: outdated,
            anchor: .available(anchor),
            comments: .available(ForgePage(
                items: comments,
                totalCount: reportedCommentCount
            ))
        )
        let presentation = try ForgeReviewThreadPresentation(
            thread: thread,
            commentVisibility: [
                commentIDs[0]: .ordinary,
                commentIDs[1]: .minimized(reason: "Off-topic"),
                commentIDs[2]: .deleted,
                commentIDs[3]: .unavailable,
            ],
            commentReactions: [commentIDs[0]: [
                ForgeReviewReactionSummary(kind: .thumbsUp, count: 2, viewerReacted: false),
                ForgeReviewReactionSummary(kind: .eyes, count: 1, viewerReacted: false),
            ]]
        )
        let selectedHead = displayedHead ?? oldHead
        let selectedSuggestion = try ForgeSuggestedChange(
            repository: repository,
            pullRequest: number,
            displayedHead: selectedHead,
            path: path,
            originalText: suggestedChange.originalText,
            replacementText: suggestedChange.replacementText
        )
        return try RepositoryPullRequestReviewThreadRecord(
            pullRequest: number,
            presentation: presentation,
            exactOutdatedLocalAnchor: outdated ? (exactOutdatedLocalAnchor ?? localAnchor) : nil,
            suggestedChanges: suggestedChanges ?? (outdated ? [] : [selectedSuggestion])
        )
    }

    func workspace(
        identity: RepositoryPullRequestReviewIdentity? = nil,
        state: ForgePullRequestState = .open,
        head: ForgeCommitID? = nil,
        canUpdateBranch: Bool = false,
        deletion: Bool = false,
        threadIsResolved: Bool = false,
        allowedOperations: Set<ForgeOperation> = Set(ForgeOperation.allCases)
    ) throws -> RepositoryPullRequestReviewWorkspace {
        let selectedIdentity = identity ?? self.identity
        let selectedRepository = selectedIdentity.repository
        let selectedHead = ForgeBranchReference(
            repository: selectedRepository,
            name: self.head.name,
            commit: head ?? oldHead
        )
        let selectedBase = ForgeBranchReference(
            repository: selectedRepository,
            name: base.name,
            commit: base.commit
        )
        let context = try ForgePullRequestMutationContext(
            accountID: selectedIdentity.accountID,
            repository: selectedRepository,
            number: selectedIdentity.number,
            state: state,
            isDraft: false,
            head: selectedHead,
            base: selectedBase,
            updatedAt: now,
            allowedOperations: allowedOperations
        )
        var warnings: Set<ForgePullRequestMergeWarning> = [.checksPending]
        if canUpdateBranch {
            warnings.insert(.branchBehind)
        }
        let merge = ForgePullRequestMergeSnapshot(
            context: context,
            viewerCanMerge: true,
            enabledMethods: Set(ForgePullRequestMergeMethod.allCases),
            warnings: warnings,
            queueState: .notQueued
        )
        let deletionSnapshot = deletion ? ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: merge,
            isSameRepository: true,
            isDefaultBranch: false,
            isProtected: false,
            viewerCanDelete: true,
            hasCheckedOutSafetyConflict: false
        ) : nil
        return try RepositoryPullRequestReviewWorkspace(
            identity: selectedIdentity,
            displayedHead: selectedHead.commit,
            base: selectedBase,
            title: "Native review",
            isDraft: false,
            threads: selectedRepository == repository ? [threadRecord(
                isResolved: threadIsResolved,
                displayedHead: selectedHead.commit
            )] : [],
            reviewers: .available([]),
            mutationContext: context,
            mergeSnapshot: merge,
            headBranchDeletionSnapshot: deletionSnapshot,
            canUpdateBranch: canUpdateBranch,
            fetchedAt: now
        )
    }
}

actor FakeReviewMutationService: RepositoryPullRequestReviewMutationServing {
    private var workspaces: [RepositoryPullRequestReviewWorkspace]
    private var lastWorkspace: RepositoryPullRequestReviewWorkspace?
    private var mutationWorkspace: RepositoryPullRequestReviewWorkspace?
    private var freshSnapshots: [ForgePullRequestMergeSnapshot]
    private var mergeError: RepositoryPullRequestReviewServiceError?
    private var loadError: RepositoryPullRequestReviewServiceError?
    private var loadCallCount = 0
    private var shouldHoldNextLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var loadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var inlineValues: [ForgeInlineReviewPublication] = []
    private var replyValues: [ForgeReviewThreadReplyPublication] = []
    private var replyWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var formalValues: [ForgeFormalReviewSubmission] = []
    private var resolutionValues: [ForgeReviewThreadResolutionMutation] = []
    private var resolutionError: RepositoryPullRequestReviewServiceError?
    private var shouldHoldNextResolution = false
    private var heldResolution: CheckedContinuation<Void, Error>?
    private var resolutionFailureCount = 0
    private var resolutionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resolutionFailureWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleValues: [ForgePullRequestLifecycleRequest] = []
    private var lifecycleError: RepositoryPullRequestReviewServiceError?
    private var lifecycleWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var mergeValues: [ForgePullRequestMergeRequest] = []
    private var mergeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var queueValues: [ForgePullRequestMergeQueueRequest] = []
    private var queueWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var deletionValues: [ForgeHeadBranchDeletionRequest] = []
    private var deletionError: RepositoryPullRequestReviewServiceError?
    private var deletionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var formalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var inlineWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var deletionSnapshot: ForgeHeadBranchDeletionSnapshot?
    private var freshDeletionCalls = 0
    private var freshCalls = 0

    init(
        workspaces: [RepositoryPullRequestReviewWorkspace],
        mutationWorkspace: RepositoryPullRequestReviewWorkspace? = nil,
        freshMergeSnapshots: [ForgePullRequestMergeSnapshot] = [],
        mergeError: RepositoryPullRequestReviewServiceError? = nil,
        deletionError: RepositoryPullRequestReviewServiceError? = nil
    ) {
        self.workspaces = workspaces
        self.mutationWorkspace = mutationWorkspace
        freshSnapshots = freshMergeSnapshots
        self.mergeError = mergeError
        self.deletionError = deletionError
        deletionSnapshot = mutationWorkspace?.headBranchDeletionSnapshot
    }

    func loadWorkspace(identity _: RepositoryPullRequestReviewIdentity) async throws -> RepositoryPullRequestReviewWorkspace {
        loadCallCount += 1
        resumeLoadWaiters()
        if let loadError {
            self.loadError = nil
            throw loadError
        }
        guard !workspaces.isEmpty else { throw RepositoryPullRequestReviewServiceError.unavailable }
        let workspace = workspaces.removeFirst()
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            await withCheckedContinuation { heldLoad = $0 }
        }
        lastWorkspace = workspace
        return workspace
    }

    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        inlineValues.append(publication)
        resumeWaiters(&inlineWaiters, count: inlineValues.count)
        return try resultWorkspace()
    }

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        replyValues.append(publication)
        resumeWaiters(&replyWaiters, count: replyValues.count)
        return try resultWorkspace()
    }

    func setReviewThreadResolution(
        identity _: RepositoryPullRequestReviewIdentity,
        threadID _: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation
    ) async throws {
        resolutionValues.append(mutation)
        resumeResolutionWaiters()
        if shouldHoldNextResolution {
            shouldHoldNextResolution = false
            try await withCheckedThrowingContinuation { heldResolution = $0 }
            return
        }
        if let resolutionError {
            self.resolutionError = nil
            resolutionFailureCount += 1
            resolutionFailureWaiters.forEach { $0.resume() }
            resolutionFailureWaiters.removeAll()
            throw resolutionError
        }
    }

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        formalValues.append(submission)
        resumeWaiters(&formalWaiters, count: formalValues.count)
        return try resultWorkspace()
    }

    func performLifecycle(
        _ request: ForgePullRequestLifecycleRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        lifecycleValues.append(request)
        resumeWaiters(&lifecycleWaiters, count: lifecycleValues.count)
        if let lifecycleError {
            self.lifecycleError = nil
            throw lifecycleError
        }
        return try resultWorkspace()
    }

    func freshMergeSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgePullRequestMergeSnapshot {
        freshCalls += 1
        guard !freshSnapshots.isEmpty else { throw RepositoryPullRequestReviewServiceError.unavailable }
        return freshSnapshots.removeFirst()
    }

    func mergePullRequest(
        _ request: ForgePullRequestMergeRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        mergeValues.append(request)
        resumeWaiters(&mergeWaiters, count: mergeValues.count)
        if let mergeError {
            throw mergeError
        }
        return try resultWorkspace()
    }

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        queueValues.append(request)
        resumeWaiters(&queueWaiters, count: queueValues.count)
        return try resultWorkspace()
    }

    func freshHeadBranchDeletionSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        freshDeletionCalls += 1
        guard let deletionSnapshot else { throw RepositoryPullRequestReviewServiceError.unavailable }
        return deletionSnapshot
    }

    func deleteHeadBranch(_ request: ForgeHeadBranchDeletionRequest) async throws {
        deletionValues.append(request)
        resumeWaiters(&deletionWaiters, count: deletionValues.count)
        if let deletionError {
            self.deletionError = nil
            throw deletionError
        }
    }

    func enqueueWorkspace(_ workspace: RepositoryPullRequestReviewWorkspace) {
        workspaces.append(workspace)
    }

    func inlinePublications() -> [ForgeInlineReviewPublication] {
        inlineValues
    }

    func replyPublications() -> [ForgeReviewThreadReplyPublication] {
        replyValues
    }

    func formalReviews() -> [ForgeFormalReviewSubmission] {
        formalValues
    }

    func resolutionMutations() -> [ForgeReviewThreadResolutionMutation] {
        resolutionValues
    }

    func lifecycleActions() -> [ForgePullRequestLifecycleAction] {
        lifecycleValues.map(\.action)
    }

    func mergeRequests() -> [ForgePullRequestMergeRequest] {
        mergeValues
    }

    func queueActions() -> [ForgePullRequestMergeQueueAction] {
        queueValues.map(\.action)
    }

    func deletionRequests() -> [ForgeHeadBranchDeletionRequest] {
        deletionValues
    }

    func freshMergeCallCount() -> Int {
        freshCalls
    }

    func freshDeletionCallCount() -> Int {
        freshDeletionCalls
    }

    func loadCalls() -> Int {
        loadCallCount
    }

    func holdNextResolutionCall() {
        shouldHoldNextResolution = true
    }

    func holdNextLoadCall() {
        shouldHoldNextLoad = true
    }

    func releaseHeldLoad() {
        heldLoad?.resume()
        heldLoad = nil
    }

    func releaseHeldResolution(with error: RepositoryPullRequestReviewServiceError? = nil) {
        guard let heldResolution else { return }
        self.heldResolution = nil
        if let error {
            heldResolution.resume(throwing: error)
        } else {
            heldResolution.resume()
        }
    }

    func failNextResolution(with error: RepositoryPullRequestReviewServiceError) {
        resolutionError = error
    }

    func failNextLifecycle(with error: RepositoryPullRequestReviewServiceError) {
        lifecycleError = error
    }

    func failNextLoad(with error: RepositoryPullRequestReviewServiceError) {
        loadError = error
    }

    func waitForResolutionCalls(_ count: Int) async {
        if resolutionValues.count >= count {
            return
        }
        await withCheckedContinuation { resolutionWaiters.append((count, $0)) }
    }

    func waitForResolutionFailureDelivered() async {
        if resolutionFailureCount > 0 {
            return
        }
        await withCheckedContinuation { resolutionFailureWaiters.append($0) }
    }

    func waitForLoadCalls(_ count: Int) async {
        if loadCallCount >= count {
            return
        }
        await withCheckedContinuation { loadWaiters.append((count, $0)) }
    }

    func waitForInlineCalls(_ count: Int) async {
        if inlineValues.count >= count {
            return
        }
        await withCheckedContinuation { inlineWaiters.append((count, $0)) }
    }

    func waitForReplyCalls(_ count: Int) async {
        if replyValues.count >= count {
            return
        }
        await withCheckedContinuation { replyWaiters.append((count, $0)) }
    }

    func waitForFormalCalls(_ count: Int) async {
        if formalValues.count >= count {
            return
        }
        await withCheckedContinuation { formalWaiters.append((count, $0)) }
    }

    func waitForLifecycleCalls(_ count: Int) async {
        if lifecycleValues.count >= count {
            return
        }
        await withCheckedContinuation { lifecycleWaiters.append((count, $0)) }
    }

    func waitForMergeCalls(_ count: Int) async {
        if mergeValues.count >= count {
            return
        }
        await withCheckedContinuation { mergeWaiters.append((count, $0)) }
    }

    func waitForQueueCalls(_ count: Int) async {
        if queueValues.count >= count {
            return
        }
        await withCheckedContinuation { queueWaiters.append((count, $0)) }
    }

    func waitForDeletionCalls(_ count: Int) async {
        if deletionValues.count >= count {
            return
        }
        await withCheckedContinuation { deletionWaiters.append((count, $0)) }
    }

    private func resultWorkspace() throws -> RepositoryPullRequestReviewWorkspace {
        if let mutationWorkspace {
            return mutationWorkspace
        }
        if let lastWorkspace {
            return lastWorkspace
        }
        if let workspace = workspaces.first {
            return workspace
        }
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    private func resumeResolutionWaiters() {
        let ready = resolutionWaiters.filter { resolutionValues.count >= $0.0 }
        resolutionWaiters.removeAll { resolutionValues.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeLoadWaiters() {
        let ready = loadWaiters.filter { loadCallCount >= $0.0 }
        loadWaiters.removeAll { loadCallCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

actor FakeReviewDraftStore: RepositoryPullRequestDraftPersisting {
    private var bodies: [String] = []
    private var identities: [ForgeDraftIdentity] = []
    private var deletes = 0
    private var values: [ForgeDraftIdentity: ForgeDraft] = [:]
    private var deleteFailure: RepositoryPullRequestReviewServiceError?
    private var shouldHoldNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?
    private var saveWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft? {
        values[identity]
    }

    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws {
        bodies.append(content.body)
        identities.append(identity)
        values[identity] = try ForgeDraft(
            identity: identity,
            content: content,
            createdAt: values[identity]?.createdAt ?? date,
            lastActivityAt: date
        )
        let ready = saveWaiters.filter { identities.count >= $0.0 }
        saveWaiters.removeAll { identities.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if shouldHoldNextSave {
            shouldHoldNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
    }

    func delete(identity: ForgeDraftIdentity) async throws {
        if let deleteFailure {
            throw deleteFailure
        }
        deletes += 1
        values[identity] = nil
    }

    func failDeletes(with error: RepositoryPullRequestReviewServiceError) {
        deleteFailure = error
    }

    func holdNextSave() {
        shouldHoldNextSave = true
    }

    func waitForSaveCalls(_ count: Int) async {
        if identities.count >= count {
            return
        }
        await withCheckedContinuation { saveWaiters.append((count, $0)) }
    }

    func releaseHeldSave() {
        heldSave?.resume()
        heldSave = nil
    }

    func savedBodies() -> [String] {
        bodies
    }

    func savedDisplayedHeads() -> [ForgeCommitID?] {
        identities.map(\.displayedPullRequestHead)
    }

    func savedIdentities() -> [ForgeDraftIdentity] {
        identities
    }

    func deleteCount() -> Int {
        deletes
    }
}

actor FakeLocalReviewService: RepositoryPullRequestLocalReviewServing {
    struct Write: Equatable, Sendable {
        let path: ForgeFilePath
        let contents: String
    }

    private let candidates: [ForgeReviewReanchorCandidate]
    private let selectedHead: ForgeCommitID?
    private var editedFiles: Set<ForgeFilePath> = []
    private var currentContents: String
    private var writeValues: [Write] = []
    private var fetchValues: [ForgeBranchReference] = []
    private var checkoutValues: [ForgeBranchReference] = []
    private var writeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var fetchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var checkoutWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(candidates: [ForgeReviewReanchorCandidate], checkedOutHead: ForgeCommitID?, contents: String) {
        self.candidates = candidates
        selectedHead = checkedOutHead
        currentContents = contents
    }

    func reanchorCandidates(
        for _: ForgeReviewContext,
        currentHead _: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate] {
        candidates
    }

    func checkedOutHead() async throws -> ForgeCommitID? {
        selectedHead
    }

    func filesWithUncommittedEdits() async throws -> Set<ForgeFilePath> {
        editedFiles
    }

    func contents(of _: ForgeFilePath) async throws -> String {
        currentContents
    }

    func writeUnstaged(contents: String, to path: ForgeFilePath) async throws {
        currentContents = contents
        writeValues.append(Write(path: path, contents: contents))
        resumeWaiters(&writeWaiters, count: writeValues.count)
    }

    func applySuggestedChange(_ change: ForgeSuggestedChange) async throws {
        switch ForgeSuggestedChangePolicy.decision(
            change: change,
            checkedOutHead: selectedHead,
            filesWithUncommittedEdits: editedFiles,
            currentContents: currentContents
        ) {
        case let .apply(updatedContents):
            try await writeUnstaged(contents: updatedContents, to: change.path)
        case let .unavailable(error):
            throw error
        }
    }

    func fetchBase(_ base: ForgeBranchReference) async throws {
        fetchValues.append(base)
        resumeWaiters(&fetchWaiters, count: fetchValues.count)
    }

    func checkOutBase(_ base: ForgeBranchReference) async throws {
        checkoutValues.append(base)
        resumeWaiters(&checkoutWaiters, count: checkoutValues.count)
    }

    func setEditedFiles(_ values: Set<ForgeFilePath>) {
        editedFiles = values
    }

    func writes() -> [Write] {
        writeValues
    }

    func fetches() -> [ForgeBranchReference] {
        fetchValues
    }

    func checkouts() -> [ForgeBranchReference] {
        checkoutValues
    }

    func waitForWrites(_ count: Int) async {
        if writeValues.count >= count {
            return
        }
        await withCheckedContinuation { writeWaiters.append((count, $0)) }
    }

    func waitForFetches(_ count: Int) async {
        if fetchValues.count >= count {
            return
        }
        await withCheckedContinuation { fetchWaiters.append((count, $0)) }
    }

    func waitForCheckouts(_ count: Int) async {
        if checkoutValues.count >= count {
            return
        }
        await withCheckedContinuation { checkoutWaiters.append((count, $0)) }
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

actor FakeMutationPreferences: RepositoryPullRequestMutationPreferencePersisting {
    private var methods: [ForgePullRequestMergeMethod] = []
    private var choices: [Bool] = []
    func preferredMergeMethod(
        repository _: ForgeRepositoryIdentity,
        enabled _: Set<ForgePullRequestMergeMethod>
    ) async -> ForgePullRequestMergeMethod? {
        methods.last
    }

    func recordSuccessfulMerge(repository _: ForgeRepositoryIdentity, method: ForgePullRequestMergeMethod) async {
        methods.append(method)
    }

    func rememberedDeleteBranchChoice(repository _: ForgeRepositoryIdentity) async -> Bool {
        choices.last ?? false
    }

    func recordSuccessfulDeleteBranchChoice(repository _: ForgeRepositoryIdentity, selected: Bool) async {
        choices.append(selected)
    }

    func mergeMethods() -> [ForgePullRequestMergeMethod] {
        methods
    }

    func deleteChoices() -> [Bool] {
        choices
    }
}

// swift6-safety-justification: `lock` protects the only mutable field and immutable scripted responses are Sendable.
private final class AtomicSuggestedChangeGitRunner: RepositoryPullRequestGitCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let head: ForgeCommitID
    private let status: String
    private var recordedCommands: [[String]] = []

    init(head: ForgeCommitID, status: String) {
        self.head = head
        self.status = status
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func run(_ arguments: [String]) throws -> String {
        lock.lock()
        recordedCommands.append(arguments)
        lock.unlock()
        switch arguments.first {
        case "rev-parse":
            return head.value
        case "status":
            return status
        default:
            throw RepositoryPullRequestReviewServiceError.unavailable
        }
    }
}
