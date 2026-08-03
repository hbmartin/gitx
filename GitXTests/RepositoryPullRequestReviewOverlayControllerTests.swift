import AppKit
import ForgeKit
import XCTest

@MainActor
final class RepositoryPullRequestReviewOverlayControllerTests: XCTestCase {
    func testDestructiveConfirmationStateRejectsOverlapAndMakesRecoveryGenerationsSingleUse() throws {
        var state = RepositoryDestructiveConfirmationState()

        let initial = try XCTUnwrap(state.begin())
        XCTAssertEqual(initial, 1)
        XCTAssertTrue(state.isInFlight)
        XCTAssertNil(state.begin(), "An overlapping button action must not start")

        state.finish(initial)
        XCTAssertFalse(state.isInFlight)
        let retry = try XCTUnwrap(state.begin(retrying: initial))
        XCTAssertEqual(retry, 2, "A matching recovery token starts a new generation")
        XCTAssertNil(state.begin(retrying: initial), "The consumed token cannot overlap its retry")

        state.finish(retry)
        XCTAssertNil(state.begin(retrying: initial), "A consumed recovery token remains stale")
        let replacement = try XCTUnwrap(state.begin())
        XCTAssertEqual(replacement, 3)
        state.invalidate()
        XCTAssertFalse(state.isInFlight)
        XCTAssertEqual(state.generation, 4)
        XCTAssertNil(state.begin(retrying: replacement), "Invalidation makes retained callbacks stale")
    }

    func testRendersNativeThreadStatesActionsAndExpandedThreadCanCollapseAndExpand() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(canUpdateBranch: true, deletion: true)
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let router = OverlayRecordingRouter()
        let controller = RepositoryPullRequestReviewOverlayController(session: session, router: router)
        let container = NSStackView(views: [controller.view, controller.reviewOverlayView])
        container.orientation = .vertical
        let window = makeWindow(content: container)
        NSLayoutConstraint.activate([
            controller.view.widthAnchor.constraint(equalTo: container.widthAnchor),
            controller.reviewOverlayView.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])

        controller.start()
        await service.waitForLoadCalls(1)
        await waitUntil("loaded review thread") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value,
                in: controller.reviewOverlayView
            ) != nil
        }

        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.reviewers,
            in: controller.view
        ))
        let lifecycleAction = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.lifecyclePrefix
                + ForgePullRequestLifecycleAction.updateBranch.rawValue,
            in: controller.view
        ))
        window.setContentSize(NSSize(width: 420, height: 720))
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.view.frame.height, lifecycleAction.frame.height)
        let lifecycleFrame = lifecycleAction.convert(lifecycleAction.bounds, to: controller.view)
        XCTAssertTrue(
            controller.view.bounds.contains(lifecycleFrame),
            "Action bounds \(controller.view.bounds) must fully contain lifecycle frame \(lifecycleFrame)"
        )
        let thread = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value,
            in: controller.reviewOverlayView
        ))
        controller.reviewOverlayView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(thread.frame.height, 0)
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ))
        let mergeQueue = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeQueue,
            in: controller.view
        ) as? NSButton)
        XCTAssertEqual(mergeQueue.accessibilityLabel(), "Enter Merge Queue")
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Reactions.0",
            in: controller.reviewOverlayView
        ))
        let commentMarkdown = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Comment.0.Markdown",
            in: controller.reviewOverlayView
        ) as? ForgeMarkdownNativeView)
        XCTAssertTrue(commentMarkdown.textView.string.contains("Please revise"))
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Reply.WritePreview",
            in: controller.reviewOverlayView
        ))
        XCTAssertTrue(allText(in: controller.reviewOverlayView).contains("Minimized: Off-topic"))
        XCTAssertTrue(allText(in: controller.reviewOverlayView).contains("Deleted comment"))
        XCTAssertTrue(allText(in: controller.reviewOverlayView).contains("Comment unavailable"))
        for index in 1 ... 3 {
            XCTAssertNotNil(descendant(
                identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                    + fixture.threadID.value + ".Comment.\(index).Status",
                in: controller.reviewOverlayView
            ))
        }

        let commentID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Comment.0"
        XCTAssertNotNil(descendant(identifier: commentID, in: controller.reviewOverlayView))
        let toggleID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Toggle"
        let toggle = try XCTUnwrap(descendant(identifier: toggleID, in: controller.reviewOverlayView) as? NSButton)
        toggle.performClick(nil)
        XCTAssertNil(descendant(identifier: commentID, in: controller.reviewOverlayView))
        let expand = try XCTUnwrap(descendant(identifier: toggleID, in: controller.reviewOverlayView) as? NSButton)
        expand.performClick(nil)
        XCTAssertNotNil(descendant(identifier: commentID, in: controller.reviewOverlayView))

        try attachScreenshot(of: window, named: "GitHub Pull Request review threads and actions")
        controller.detach()
    }

    func testCompletedOverlayTasksSelfPruneAcrossRenderingDraftsAndActions() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace], mutationWorkspace: workspace)
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView

        controller.start()
        await service.waitForLoadCalls(1)
        let closeIdentifier = RepositoryPullRequestReviewAccessibility.lifecyclePrefix
            + ForgePullRequestLifecycleAction.close.rawValue
        await waitUntil("loaded review actions") {
            self.descendant(identifier: closeIdentifier, in: controller.view) != nil
        }
        await waitUntil("initial presentation tasks to self-prune") {
            controller.trackedTaskCountForProductProof == 0
        }

        controller.select(anchor: fixture.anchor, contextLines: ["let old = true"], isTruncated: false)
        XCTAssertGreaterThan(controller.trackedTaskCountForProductProof, 0)
        await waitUntil("draft presentation task to self-prune") {
            controller.trackedTaskCountForProductProof == 0
        }

        let close = try XCTUnwrap(descendant(identifier: closeIdentifier, in: controller.view) as? NSButton)
        close.performClick(nil)
        await service.waitForLifecycleCalls(1)
        await waitUntil("completed action task to self-prune") {
            controller.trackedTaskCountForProductProof == 0
        }

        controller.detach()
        XCTAssertEqual(controller.trackedTaskCountForProductProof, 0)
    }

    func testReviewThreadScrollDocumentExpandsAndCanRevealSuggestedChange() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        let window = makeWindow(content: controller.reviewOverlayView)
        window.setContentSize(NSSize(width: 420, height: 220))
        controller.start()
        await service.waitForLoadCalls(1)
        let suggestionID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Suggestion.0.Apply"
        await waitUntil("suggested change action") {
            self.descendant(identifier: suggestionID, in: controller.reviewOverlayView) != nil
        }

        window.layoutIfNeeded()
        controller.reviewOverlayView.layoutSubtreeIfNeeded()
        let threadScroll = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threads,
            in: controller.reviewOverlayView
        ) as? NSScrollView)
        let threadDocument = try XCTUnwrap(threadScroll.documentView)
        let suggestedChange = try XCTUnwrap(descendant(
            identifier: suggestionID,
            in: controller.reviewOverlayView
        ))
        let thread = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value,
            in: controller.reviewOverlayView
        ))
        threadDocument.layoutSubtreeIfNeeded()
        thread.layoutSubtreeIfNeeded()
        let suggestedChangeFrame = suggestedChange.convert(suggestedChange.bounds, to: threadDocument)
        let threadFrame = thread.convert(thread.bounds, to: threadDocument)
        XCTAssertTrue(threadDocument.isFlipped)
        XCTAssertGreaterThan(
            threadDocument.frame.height,
            threadScroll.contentView.bounds.height,
            "document=\(threadDocument.frame) fitting=\(threadDocument.fittingSize) "
                + "children=\(threadDocument.subviews.map { ($0.frame, $0.fittingSize) })"
        )
        XCTAssertTrue(
            threadDocument.bounds.contains(suggestedChangeFrame),
            "Document bounds \(threadDocument.bounds) must contain suggestion \(suggestedChangeFrame)"
        )
        XCTAssertGreaterThan(
            threadFrame.width,
            threadDocument.bounds.width * 0.9,
            "Thread \(threadFrame) must receive the scroll document's usable width \(threadDocument.bounds)"
        )
        XCTAssertTrue(
            threadDocument.bounds.contains(threadFrame),
            "Document bounds \(threadDocument.bounds) must contain thread \(threadFrame)"
        )
        threadScroll.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, suggestedChangeFrame.midY - (threadScroll.contentView.bounds.height / 2))
        ))
        threadScroll.reflectScrolledClipView(threadScroll.contentView)
        XCTAssertTrue(threadScroll.contentView.documentVisibleRect.intersects(suggestedChangeFrame))
        controller.detach()
    }

    func testExplicitBranchDeletionReconcilesAndRemovesDestructiveControl() async throws {
        let fixture = try ReviewAppFixture()
        let beforeDeletion = try fixture.workspace(state: .merged, deletion: true)
        let afterDeletion = try fixture.workspace(state: .merged, deletion: false)
        let service = FakeReviewMutationService(
            workspaces: [beforeDeletion, afterDeletion],
            mutationWorkspace: beforeDeletion
        )
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = makeWindow(content: controller.view)
        controller.start()
        await service.waitForLoadCalls(1)
        await waitUntil("explicit branch deletion action") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch,
                in: controller.view
            ) != nil
        }

        let delete = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch,
            in: controller.view
        ) as? NSButton)
        delete.performClick(nil)
        let confirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
            in: controller.view
        ) as? NSButton)
        confirm.performClick(nil)
        await service.waitForDeletionCalls(1)
        await service.waitForLoadCalls(2)
        await waitUntil("removed destructive branch deletion action") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch,
                in: controller.view
            ) == nil
        }
        controller.detach()
    }

    func testReplyInlineAndFormalEditorsRenderSanitizedMarkdownPreviews() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let router = OverlayRecordingRouter()
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: router
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply"
        await waitUntil("Markdown reply editor") {
            self.descendant(identifier: replyID, in: controller.reviewOverlayView) != nil
        }
        let replyPreview = try assertSanitizedPreview(
            editorID: replyID,
            in: controller.reviewOverlayView
        )
        let replyLink = try XCTUnwrap(linkURLs(in: replyPreview.textView.attributedString()).first)
        XCTAssertTrue(replyPreview.activateLink(replyLink))
        guard case let .native(destination) = try XCTUnwrap(router.markdownTargets.first) else {
            return XCTFail("Expected central native Markdown routing")
        }
        XCTAssertEqual(destination.kind, .pullRequest)

        controller.select(anchor: fixture.anchor, contextLines: ["let old = true"], isTruncated: false)
        try assertSanitizedPreview(
            editorID: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        )

        _ = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)
        let review = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        review.performClick(nil)
        await waitUntil("formal Markdown editor") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.formalReviewSubmit,
                in: controller.view
            ) as? NSButton)?.isEnabled == true
        }
        try assertSanitizedPreview(
            editorID: RepositoryPullRequestReviewAccessibility.formalReviewBody,
            in: controller.view
        )
        controller.detach()
    }

    func testReviewMarkdownUsesUpdatedRepositoryDefaultBranchInsteadOfDisplayedHeadOrAnchorPath() async throws {
        let fixture = try ReviewAppFixture()
        let thread = try fixture.threadRecord(firstCommentBody: "[Guide](docs/guide.md)")
        let workspace = try replacingThreads(
            in: fixture.workspace(),
            with: [thread]
        )
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let router = OverlayRecordingRouter()
        let localBranch = try ForgeRefName("feature/local")
        let fetchedDefaultBranch = try ForgeRefName("trunk")
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: router,
            defaultRevision: .branch(localBranch)
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply"
        await waitUntil("review Markdown rendered using the initial context") {
            self.descendant(identifier: replyID, in: controller.reviewOverlayView) != nil
        }

        controller.updateDefaultRevision(.branch(fetchedDefaultBranch))

        let comment = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Comment.0.Markdown",
            in: controller.reviewOverlayView
        ) as? ForgeMarkdownNativeView)
        let expectedURL = "https://github.com/hbmartin/gitx/blob/trunk/docs/guide.md"
        try assertRoutesMarkdownLink(comment, through: router, to: expectedURL)
        let relativeMarkdown = "[Guide](docs/guide.md)"
        let replyPreview = try assertSanitizedPreview(
            editorID: replyID,
            in: controller.reviewOverlayView,
            markdown: relativeMarkdown
        )
        try assertRoutesMarkdownLink(replyPreview, through: router, to: expectedURL)

        controller.select(anchor: fixture.anchor, contextLines: ["let old = true"], isTruncated: false)
        let inlinePreview = try assertSanitizedPreview(
            editorID: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView,
            markdown: relativeMarkdown
        )
        try assertRoutesMarkdownLink(inlinePreview, through: router, to: expectedURL)

        _ = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)
        let review = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        review.performClick(nil)
        await waitUntil("formal Markdown editor uses fetched default branch") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.formalReviewSubmit,
                in: controller.view
            ) as? NSButton)?.isEnabled == true
        }
        let formalPreview = try assertSanitizedPreview(
            editorID: RepositoryPullRequestReviewAccessibility.formalReviewBody,
            in: controller.view,
            markdown: relativeMarkdown
        )
        try assertRoutesMarkdownLink(formalPreview, through: router, to: expectedURL)
        controller.detach()
    }

    func testInitiallyCollapsedThreadCanExpand() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try replacingThreadExpansion(
            in: fixture.workspace(),
            with: .collapsed
        )
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let toggleID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Toggle"
        await waitUntil("collapsed review thread") {
            self.descendant(identifier: toggleID, in: controller.reviewOverlayView) != nil
        }
        let commentID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Comment.0"
        XCTAssertNil(descendant(identifier: commentID, in: controller.reviewOverlayView))
        let toggle = try XCTUnwrap(descendant(identifier: toggleID, in: controller.reviewOverlayView) as? NSButton)
        toggle.performClick(nil)
        XCTAssertNotNil(descendant(identifier: commentID, in: controller.reviewOverlayView))
        controller.detach()
    }

    func testMutationControlsFailClosedForMissingCapabilities() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(allowedOperations: [.replyToReviewThread])
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply.Publish"
        await waitUntil("review controls") {
            self.descendant(identifier: replyID, in: controller.reviewOverlayView) != nil
        }

        let reply = try XCTUnwrap(descendant(identifier: replyID, in: controller.reviewOverlayView) as? NSButton)
        XCTAssertTrue(reply.isEnabled)
        let resolve = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Resolve",
            in: controller.reviewOverlayView
        ) as? NSButton)
        XCTAssertFalse(resolve.isEnabled)
        let formal = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        XCTAssertFalse(formal.isEnabled)
        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ) as? NSButton)
        XCTAssertFalse(merge.isEnabled)

        controller.select(anchor: fixture.anchor, contextLines: ["let new = true"], isTruncated: false)
        let publish = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePublish,
            in: controller.reviewOverlayView
        ) as? NSButton)
        XCTAssertFalse(publish.isEnabled)
        controller.detach()
    }

    func testResolutionStateUpdatesOnlyItsControlsAndPreservesReplyEditor() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let prefix = RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value
        let reply = try XCTUnwrap(descendant(identifier: prefix + ".Reply", in: controller.reviewOverlayView) as? NSTextView)
        reply.string = "Keep this unsaved reply intact"
        let initialResolve = try XCTUnwrap(descendant(
            identifier: prefix + ".Resolve",
            in: controller.reviewOverlayView
        ) as? NSButton)

        session.onResolutionChange?(fixture.threadID, .confirmed(isResolved: false))
        let unchangedResolve = try XCTUnwrap(descendant(
            identifier: prefix + ".Resolve",
            in: controller.reviewOverlayView
        ) as? NSButton)
        XCTAssertTrue(
            initialResolve === unchangedResolve,
            "Repeated resolution delivery must not churn the representative AppKit hierarchy"
        )

        session.onResolutionChange?(
            fixture.threadID,
            .optimistic(
                mutation: .resolve,
                priorValue: false,
                undoDeadline: fixture.now.addingTimeInterval(8)
            )
        )

        let updatedReply = try XCTUnwrap(descendant(
            identifier: prefix + ".Reply",
            in: controller.reviewOverlayView
        ) as? NSTextView)
        XCTAssertTrue(reply === updatedReply)
        XCTAssertEqual(updatedReply.string, "Keep this unsaved reply intact")
        XCTAssertEqual(
            (descendant(identifier: prefix + ".Resolve", in: controller.reviewOverlayView) as? NSButton)?.title,
            "Unresolve"
        )
        XCTAssertNotNil(descendant(identifier: prefix + ".Undo", in: controller.reviewOverlayView))
        controller.detach()
    }

    func testOptimisticResolutionUndoRemainsContainedAfterNarrowLayout() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let prefix = RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value
        await waitUntil("confirmed resolution controls") {
            self.descendant(identifier: prefix + ".Resolve", in: controller.reviewOverlayView) != nil
        }

        let reply = try XCTUnwrap(descendant(
            identifier: prefix + ".Reply.Publish",
            in: controller.reviewOverlayView
        ) as? NSButton)
        let resolve = try XCTUnwrap(descendant(
            identifier: prefix + ".Resolve",
            in: controller.reviewOverlayView
        ) as? NSButton)
        let resolutionRow = try XCTUnwrap(resolve.superview)
        let controlsRow = try XCTUnwrap(resolutionRow.superview)
        let initialSingleLineWidth = ceil(reply.fittingSize.width + 6 + resolutionRow.fittingSize.width + 1)
        controlsRow.removeFromSuperview()
        let narrowContainer = NSView(frame: NSRect(x: 0, y: 0, width: initialSingleLineWidth, height: 120))
        narrowContainer.addSubview(controlsRow)
        NSLayoutConstraint.activate([
            controlsRow.leadingAnchor.constraint(equalTo: narrowContainer.leadingAnchor),
            controlsRow.topAnchor.constraint(equalTo: narrowContainer.topAnchor),
            controlsRow.widthAnchor.constraint(equalTo: narrowContainer.widthAnchor),
        ])
        let window = makeWindow(content: narrowContainer)
        window.setContentSize(NSSize(width: initialSingleLineWidth, height: 120))
        window.layoutIfNeeded()
        narrowContainer.layoutSubtreeIfNeeded()
        let confirmedHeight = controlsRow.frame.height

        session.onResolutionChange?(
            fixture.threadID,
            .optimistic(
                mutation: .resolve,
                priorValue: false,
                undoDeadline: fixture.now.addingTimeInterval(8)
            )
        )
        window.layoutIfNeeded()
        narrowContainer.layoutSubtreeIfNeeded()

        let undo = try XCTUnwrap(descendant(
            identifier: prefix + ".Undo",
            in: controlsRow
        ) as? NSButton)
        let updatedResolutionRow = try XCTUnwrap(undo.superview)
        let resolutionRect = updatedResolutionRow.convert(updatedResolutionRow.bounds, to: controlsRow)
        let undoRect = undo.convert(undo.bounds, to: controlsRow)
        XCTAssertGreaterThan(controlsRow.frame.height, confirmedHeight)
        XCTAssertTrue(controlsRow.bounds.contains(
            resolutionRect
        ), "controls=\(controlsRow.bounds) resolution=\(resolutionRect)")
        XCTAssertTrue(
            controlsRow.bounds.contains(undoRect),
            "controls=\(controlsRow.bounds) undo=\(undoRect)"
        )
        controller.detach()
    }

    func testInlineReplyAndHeadBoundFormalDraftsAutosaveAndRestoreAfterRerender() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace, workspace])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts
        )
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply"
        await waitUntil("reply draft editor") {
            self.descendant(identifier: replyID, in: controller.reviewOverlayView) != nil
        }
        controller.select(
            anchor: fixture.anchor,
            contextLines: ["let new = true"],
            isTruncated: false
        )
        let inline = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        let reply = try XCTUnwrap(descendant(identifier: replyID, in: controller.reviewOverlayView) as? NSTextView)
        inline.string = "Head-bound inline draft"
        inline.didChangeText()
        reply.string = "Immediate reply draft"
        reply.didChangeText()
        await drafts.waitForSaveCalls(2)

        controller.start()
        await service.waitForLoadCalls(2)
        await waitUntil("restored inline and reply drafts") {
            let restoredInline = self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
                in: controller.reviewOverlayView
            ) as? NSTextView
            let restoredReply = self.descendant(identifier: replyID, in: controller.reviewOverlayView) as? NSTextView
            return restoredInline?.string == "Head-bound inline draft"
                && restoredReply?.string == "Immediate reply draft"
        }

        // Pin the sheet to the exact displayed head before typing, matching
        // the production sheet's asynchronous preparation boundary.
        _ = try await session.loadFormalReviewDraft(displayedHead: fixture.oldHead)
        let review = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        review.performClick(nil)
        let formal = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewBody,
            in: controller.view
        ) as? NSTextView)
        formal.string = "Head-bound formal review"
        formal.didChangeText()
        await drafts.waitForSaveCalls(3)
        let cancel = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewCancel,
            in: controller.view
        ) as? NSButton)
        cancel.performClick(nil)
        review.performClick(nil)
        await waitUntil("restored formal review draft") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.formalReviewBody,
                in: controller.view
            ) as? NSTextView)?.string == "Head-bound formal review"
        }
        let restoredInline = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        let restoredReply = try XCTUnwrap(descendant(identifier: replyID, in: controller.reviewOverlayView) as? NSTextView)
        let inlineDiscard = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineDiscard,
            in: controller.reviewOverlayView
        ) as? NSButton)
        let replyDiscard = try XCTUnwrap(descendant(
            identifier: replyID + ".Discard",
            in: controller.reviewOverlayView
        ) as? NSButton)
        let formalDiscard = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewDiscard,
            in: controller.view
        ) as? NSButton)
        inlineDiscard.performClick(nil)
        replyDiscard.performClick(nil)
        formalDiscard.performClick(nil)
        await drafts.waitForDeleteCalls(3)
        await waitUntil("explicit discard clears exact drafts and closes the formal sheet") {
            restoredInline.string.isEmpty
                && restoredReply.string.isEmpty
                && self.descendant(
                    identifier: RepositoryPullRequestReviewAccessibility.formalReviewSheet,
                    in: controller.view
                ) == nil
        }
        controller.detach()
    }

    func testFailedFormalDraftDiscardKeepsDurableTextAvailableToReopen() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts
        )
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)
        let review = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        review.performClick(nil)
        await waitUntil("loaded formal draft discard control") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.formalReviewDiscard,
                in: controller.view
            ) as? NSButton)?.isEnabled == true
        }
        let editor = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewBody,
            in: controller.view
        ) as? NSTextView)
        editor.string = "Preserve after local deletion failure"
        editor.didChangeText()
        await drafts.waitForSaveCalls(1)
        await drafts.failDeletes(with: .unavailable)
        let discard = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReviewDiscard,
            in: controller.view
        ) as? NSButton)
        discard.performClick(nil)
        await waitUntil("failed discard message") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.message,
                in: controller.view
            ) != nil
        }

        let restoredReview = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.formalReview,
            in: controller.view
        ) as? NSButton)
        restoredReview.performClick(nil)
        await waitUntil("restored formal draft after failed discard") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.formalReviewBody,
                in: controller.view
            ) as? NSTextView)?.string == "Preserve after local deletion failure"
        }
        controller.detach()
    }

    func testSuccessfulReanchorClearsComposerAndStaleConfirmationCannotPublishTwice() async throws {
        let fixture = try ReviewAppFixture()
        let oldWorkspace = try fixture.workspace()
        let newWorkspace = try fixture.workspace(head: fixture.newHead)
        let service = FakeReviewMutationService(
            workspaces: [oldWorkspace, newWorkspace],
            mutationWorkspace: newWorkspace
        )
        let local = try FakeLocalReviewService(
            candidates: [fixture.reanchorCandidate(head: fixture.newHead)],
            checkedOutHead: fixture.newHead,
            contents: "before\nlet old = true\nafter\n"
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local,
            drafts: FakeReviewDraftStore()
        )
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        await waitUntil("old-head review workspace") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.threads,
                in: controller.reviewOverlayView
            ) != nil
        }
        controller.select(
            anchor: fixture.anchor,
            contextLines: ["let old = true"],
            isTruncated: false
        )

        controller.start()
        await service.waitForLoadCalls(2)
        await waitUntil("new-head review workspace") {
            (self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.inlinePublish,
                in: controller.reviewOverlayView
            ) as? NSButton)?.isEnabled == true
        }
        let body = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        body.string = "Publish once after re-anchor"
        let publish = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePublish,
            in: controller.reviewOverlayView
        ) as? NSButton)
        publish.performClick(nil)
        await waitUntil("explicit re-anchor confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.inlineReanchor,
                in: controller.reviewOverlayView
            ) != nil
        }
        let confirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineReanchor,
            in: controller.reviewOverlayView
        ) as? NSButton)
        confirm.performClick(nil)
        await service.waitForInlineCalls(1)
        await waitUntil("cleared successful re-anchor composer") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.inlinePanel,
                in: controller.reviewOverlayView
            ) == nil
        }

        confirm.performClick(nil)
        await Task.yield()
        let publications = await service.inlinePublications()
        XCTAssertEqual(publications.count, 1)
        XCTAssertNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineReanchor,
            in: controller.reviewOverlayView
        ))
        controller.detach()
    }

    func testUpdateBranchUsesFreshDistinctConfirmationSheetAndCancelNeverMutates() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(canUpdateBranch: true)
        let service = FakeReviewMutationService(
            workspaces: [workspace, workspace, workspace],
            mutationWorkspace: workspace
        )
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)
        let actionID = RepositoryPullRequestReviewAccessibility.lifecyclePrefix
            + ForgePullRequestLifecycleAction.updateBranch.rawValue
        await waitUntil("Update Branch action") {
            self.descendant(identifier: actionID, in: controller.view) != nil
        }

        let firstAction = try XCTUnwrap(descendant(identifier: actionID, in: controller.view) as? NSButton)
        firstAction.performClick(nil)
        await service.waitForLoadCalls(2)
        await waitUntil("fresh Update Branch confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.updateBranchSheet,
                in: controller.view
            ) != nil
        }
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.updateBranchConfirm,
            in: controller.view
        ))
        let cancel = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.updateBranchCancel,
            in: controller.view
        ) as? NSButton)
        cancel.performClick(nil)
        let actionsAfterCancel = await service.lifecycleActions()
        XCTAssertTrue(actionsAfterCancel.isEmpty)

        let secondAction = try XCTUnwrap(descendant(identifier: actionID, in: controller.view) as? NSButton)
        secondAction.performClick(nil)
        await service.waitForLoadCalls(3)
        await waitUntil("second fresh Update Branch confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.updateBranchConfirm,
                in: controller.view
            ) != nil
        }
        let confirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.updateBranchConfirm,
            in: controller.view
        ) as? NSButton)
        confirm.performClick(nil)
        await service.waitForLifecycleCalls(1)
        let lifecycleActions = await service.lifecycleActions()
        let mergeRequests = await service.mergeRequests()
        XCTAssertEqual(lifecycleActions, [.updateBranch])
        XCTAssertTrue(mergeRequests.isEmpty)
        controller.detach()
    }

    func testRememberedMergeAndDeleteDefaultsNeverOverwriteLiveUserSelections() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(deletion: true)
        let service = FakeReviewMutationService(
            workspaces: [workspace],
            mutationWorkspace: workspace,
            freshMergeSnapshots: [workspace.mergeSnapshot]
        )
        let preferences = HoldingMutationPreferences()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            preferences: preferences
        )
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)
        await preferences.waitForPreferredRequest()

        let method = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeMethod,
            in: controller.view
        ) as? NSPopUpButton)
        method.selectItem(withTitle: "Squash and Merge")
        try NSApp.sendAction(XCTUnwrap(method.action), to: method.target, from: method)
        await preferences.releasePreferred(.merge)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(method.titleOfSelectedItem, "Squash and Merge")

        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ) as? NSButton)
        merge.performClick(nil)
        await waitUntil("merge confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeDeleteBranch,
                in: controller.view
            ) != nil
        }
        await preferences.waitForDeleteRequest()
        let delete = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeDeleteBranch,
            in: controller.view
        ) as? NSButton)
        XCTAssertEqual(delete.state, .off)
        delete.performClick(nil)
        XCTAssertEqual(delete.state, .on)
        await preferences.releaseDelete(false)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(delete.state, .on)
        controller.detach()
    }

    func testRebaseConfirmationShowsExactReadOnlyPullRequestHeadAndBaseSummary() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(
            workspaces: [workspace],
            freshMergeSnapshots: [workspace.mergeSnapshot]
        )
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)

        let method = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeMethod,
            in: controller.view
        ) as? NSPopUpButton)
        method.selectItem(withTitle: "Rebase and Merge")
        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ) as? NSButton)
        merge.performClick(nil)

        await waitUntil("exact rebase summary") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeSummary,
                in: controller.view
            ) != nil
        }
        let summary = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeSummary,
            in: controller.view
        ) as? NSTextField)
        let confirmation = ForgePullRequestMergeConfirmation(
            snapshot: workspace.mergeSnapshot,
            method: .rebase
        )
        let expected = try RepositoryPullRequestRebaseSummaryPresenter.text(
            XCTUnwrap(confirmation.rebaseSummary)
        )
        XCTAssertEqual(summary.stringValue, expected)
        XCTAssertEqual(summary.accessibilityLabel(), expected)
        XCTAssertFalse(summary.isEditable)
        XCTAssertTrue(summary.isSelectable)
        XCTAssertTrue(summary.stringValue.contains(fixture.oldHead.value))
        XCTAssertTrue(summary.stringValue.contains(fixture.baseCommit.value))
        XCTAssertNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeTitle,
            in: controller.view
        ))
        XCTAssertNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeMessage,
            in: controller.view
        ))
        controller.detach()
    }

    func testDestructiveConfirmationButtonsDisableAndDispatchOnlyOnceWhilePending() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(deletion: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let mergeService = FakeReviewMutationService(
            workspaces: [open],
            mutationWorkspace: merged,
            freshMergeSnapshots: [open.mergeSnapshot, open.mergeSnapshot]
        )
        await mergeService.holdNextMerge()
        let mergeController = RepositoryPullRequestReviewOverlayController(
            session: RepositoryPullRequestReviewSession(identity: fixture.identity, service: mergeService),
            router: OverlayRecordingRouter()
        )
        _ = mergeController.view
        mergeController.start()
        await mergeService.waitForLoadCalls(1)
        let mergeAction = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: mergeController.view
        ) as? NSButton)
        mergeAction.performClick(nil)
        await waitUntil("merge confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
                in: mergeController.view
            ) != nil
        }
        let mergeConfirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
            in: mergeController.view
        ) as? NSButton)
        let mergeCancel = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeCancel,
            in: mergeController.view
        ) as? NSButton)

        mergeConfirm.performClick(nil)
        mergeConfirm.performClick(nil)
        XCTAssertFalse(mergeConfirm.isEnabled)
        XCTAssertFalse(mergeCancel.isEnabled)
        mergeCancel.performClick(nil)
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
            in: mergeController.view
        ))
        await mergeService.waitForMergeCalls(1)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let heldMergeRequests = await mergeService.mergeRequests()
        XCTAssertEqual(heldMergeRequests.count, 1)
        await mergeService.releaseHeldMerge()
        await waitUntil("merge confirmation closes") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
                in: mergeController.view
            ) == nil
        }
        mergeController.detach()

        let deletionService = FakeReviewMutationService(
            workspaces: [merged],
            mutationWorkspace: merged
        )
        await deletionService.holdNextDeletion()
        let deletionController = RepositoryPullRequestReviewOverlayController(
            session: RepositoryPullRequestReviewSession(identity: fixture.identity, service: deletionService),
            router: OverlayRecordingRouter()
        )
        _ = deletionController.view
        deletionController.start()
        await deletionService.waitForLoadCalls(1)
        let deleteAction = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch,
            in: deletionController.view
        ) as? NSButton)
        deleteAction.performClick(nil)
        await waitUntil("delete confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
                in: deletionController.view
            ) != nil
        }
        let deleteConfirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
            in: deletionController.view
        ) as? NSButton)
        let deleteCancel = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Cancel",
            in: deletionController.view
        ) as? NSButton)

        deleteConfirm.performClick(nil)
        deleteConfirm.performClick(nil)
        XCTAssertFalse(deleteConfirm.isEnabled)
        XCTAssertFalse(deleteCancel.isEnabled)
        deleteCancel.performClick(nil)
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
            in: deletionController.view
        ))
        await deletionService.waitForDeletionCalls(1)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let heldDeletionRequests = await deletionService.deletionRequests()
        XCTAssertEqual(heldDeletionRequests.count, 1)
        await deletionService.releaseHeldDeletion()
        await waitUntil("delete confirmation closes") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
                in: deletionController.view
            ) == nil
        }
        deletionController.detach()
    }

    func testMergeAuthorizationRecoveryCannotOverlapAReplacementConfirmation() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(deletion: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let service = FakeReviewMutationService(
            workspaces: [open],
            mutationWorkspace: merged,
            freshMergeSnapshots: Array(repeating: open.mergeSnapshot, count: 4)
        )
        await service.failNextMerge(with: ReviewAuthorizationRecoveryTestFixture.samlError(at: fixture.now))
        let recoveryOffered = expectation(description: "merge authorization recovery offered")
        var retryAction: (@MainActor () -> Void)?
        let controller = RepositoryPullRequestReviewOverlayController(
            session: RepositoryPullRequestReviewSession(identity: fixture.identity, service: service),
            router: OverlayRecordingRouter(),
            authorizationRecoveryHandler: { error, retry in
                guard GitHubAuthorizationRecoveryPresentation.make(error: error)?.kind == .saml else {
                    return false
                }
                retryAction = retry
                recoveryOffered.fulfill()
                return true
            }
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)
        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ) as? NSButton)
        merge.performClick(nil)
        await waitUntil("merge confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
                in: controller.view
            ) != nil
        }
        let confirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
            in: controller.view
        ) as? NSButton)

        confirm.performClick(nil)
        await fulfillment(of: [recoveryOffered])
        await service.waitForMergeCalls(1)
        await service.holdNextMerge()

        confirm.performClick(nil)
        await service.waitForMergeCalls(2)
        retryAction?()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let mergeRequests = await service.mergeRequests()
        let maximumConcurrentMerges = await service.maximumConcurrentMergeCalls()
        XCTAssertEqual(mergeRequests.count, 2)
        XCTAssertEqual(maximumConcurrentMerges, 1)
        await service.releaseHeldMerge()
        await waitUntil("replacement merge confirmation completes") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
                in: controller.view
            ) == nil
        }
        retryAction?()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let requestsAfterObsoleteRetry = await service.mergeRequests()
        XCTAssertEqual(requestsAfterObsoleteRetry.count, 2)
        controller.detach()
    }

    func testDetachedControllerRejectsStoredDestructiveRecoveryRetries() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(deletion: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let authorizationError = ReviewAuthorizationRecoveryTestFixture.samlError(at: fixture.now)

        let mergeService = FakeReviewMutationService(
            workspaces: [open],
            mutationWorkspace: merged,
            freshMergeSnapshots: [open.mergeSnapshot, open.mergeSnapshot]
        )
        await mergeService.failNextMerge(with: authorizationError)
        let mergeRecoveryOffered = expectation(description: "merge recovery callback stored")
        var mergeRetry: (@MainActor () -> Void)?
        let mergeController = RepositoryPullRequestReviewOverlayController(
            session: RepositoryPullRequestReviewSession(identity: fixture.identity, service: mergeService),
            router: OverlayRecordingRouter(),
            authorizationRecoveryHandler: { _, retry in
                mergeRetry = retry
                mergeRecoveryOffered.fulfill()
                return true
            }
        )
        _ = mergeController.view
        mergeController.start()
        await mergeService.waitForLoadCalls(1)
        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: mergeController.view
        ) as? NSButton)
        merge.performClick(nil)
        await waitUntil("merge confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
                in: mergeController.view
            ) != nil
        }
        let mergeConfirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
            in: mergeController.view
        ) as? NSButton)
        mergeConfirm.performClick(nil)
        await fulfillment(of: [mergeRecoveryOffered])
        await mergeService.waitForMergeCalls(1)

        mergeRetry?()
        mergeController.detach()
        await Task.yield()
        XCTAssertEqual(mergeController.trackedTaskCountForProductProof, 0)
        let mergeRequests = await mergeService.mergeRequests()
        XCTAssertEqual(mergeRequests.count, 1, "Detach must cancel a queued merge retry before it starts")

        let deletionService = FakeReviewMutationService(
            workspaces: [merged],
            mutationWorkspace: merged
        )
        await deletionService.failNextDeletion(with: authorizationError)
        let deletionRecoveryOffered = expectation(description: "branch deletion recovery callback stored")
        var deletionRetry: (@MainActor () -> Void)?
        let deletionController = RepositoryPullRequestReviewOverlayController(
            session: RepositoryPullRequestReviewSession(identity: fixture.identity, service: deletionService),
            router: OverlayRecordingRouter(),
            authorizationRecoveryHandler: { _, retry in
                deletionRetry = retry
                deletionRecoveryOffered.fulfill()
                return true
            }
        )
        _ = deletionController.view
        deletionController.start()
        await deletionService.waitForLoadCalls(1)
        let delete = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch,
            in: deletionController.view
        ) as? NSButton)
        delete.performClick(nil)
        await waitUntil("delete confirmation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
                in: deletionController.view
            ) != nil
        }
        let deleteConfirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranch + ".Confirm",
            in: deletionController.view
        ) as? NSButton)
        deleteConfirm.performClick(nil)
        await fulfillment(of: [deletionRecoveryOffered])
        await deletionService.waitForDeletionCalls(1)

        deletionController.detach()
        deletionRetry?()
        await Task.yield()
        XCTAssertEqual(deletionController.trackedTaskCountForProductProof, 0)
        let deletionRequests = await deletionService.deletionRequests()
        XCTAssertEqual(deletionRequests.count, 1, "A detached controller must not repeat branch deletion")
    }

    func testMergeDeletionFailurePreservesMergeAndOffersBrowserAndSuccessfulRetry() async throws {
        let fixture = try ReviewAppFixture()
        let open = try fixture.workspace(deletion: true)
        let merged = try fixture.workspace(state: .merged, deletion: true)
        let service = FakeReviewMutationService(
            workspaces: [open],
            mutationWorkspace: merged,
            freshMergeSnapshots: [open.mergeSnapshot, open.mergeSnapshot],
            deletionError: .authoritative("Protected after merge")
        )
        let router = OverlayRecordingRouter()
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(session: session, router: router)
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)
        let merge = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.merge,
            in: controller.view
        ) as? NSButton)
        merge.performClick(nil)
        await waitUntil("merge delete choice") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.mergeDeleteBranch,
                in: controller.view
            ) != nil
        }
        let deleteChoice = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeDeleteBranch,
            in: controller.view
        ) as? NSButton)
        deleteChoice.performClick(nil)
        XCTAssertEqual(deleteChoice.state, .on)
        let confirm = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.mergeConfirm,
            in: controller.view
        ) as? NSButton)
        confirm.performClick(nil)
        await service.waitForMergeCalls(1)
        await service.waitForDeletionCalls(1)
        await waitUntil("post-merge deletion recovery") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranchRetry,
                in: controller.view
            ) != nil
        }
        XCTAssertEqual(session.workspace?.mutationContext.state, .merged)

        let openBrowser = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranchOpenInBrowser,
            in: controller.view
        ) as? NSButton)
        openBrowser.performClick(nil)
        XCTAssertEqual(router.destinations, [merged.browserDestination])

        await service.enqueueWorkspace(merged)
        let retry = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.deleteBranchRetry,
            in: controller.view
        ) as? NSButton)
        retry.performClick(nil)
        await service.waitForDeletionCalls(2)
        await waitUntil("cleared deletion recovery after retry") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.deleteBranchRetry,
                in: controller.view
            ) == nil
        }
        let mergeRequests = await service.mergeRequests()
        let deletionRequests = await service.deletionRequests()
        let queueActions = await service.queueActions()
        XCTAssertEqual(mergeRequests.count, 1)
        XCTAssertEqual(deletionRequests.count, 2)
        XCTAssertTrue(queueActions.isEmpty)
        controller.detach()
    }

    func testSuccessfulPostMergeLocalActionsNotifyRepositoryModelRefreshHooks() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(state: .merged)
        let service = FakeReviewMutationService(workspaces: [workspace])
        let local = FakeLocalReviewService(
            candidates: [],
            checkedOutHead: fixture.oldHead,
            contents: ""
        )
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local
        )
        var completions: [String] = []
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter(),
            onFetchBaseCompletion: { completions.append("fetch") },
            onCheckOutBaseCompletion: { completions.append("checkout") }
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)

        let fetch = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.fetchBase,
            in: controller.view
        ) as? NSButton)
        fetch.performClick(nil)
        await waitUntil("post-merge fetch completion") { completions == ["fetch"] }

        let checkout = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.checkOutBase,
            in: controller.view
        ) as? NSButton)
        checkout.performClick(nil)
        await waitUntil("post-merge checkout completion") { completions == ["fetch", "checkout"] }

        let fetches = await local.postMergeFetches()
        let checkouts = await local.checkouts()
        XCTAssertEqual(fetches, [workspace.base])
        XCTAssertEqual(checkouts, [workspace.base])
        controller.detach()
    }

    func testFailedPostMergeLocalActionsDoNotNotifyRepositoryModelRefreshHooks() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace(state: .merged)
        let service = FakeReviewMutationService(workspaces: [workspace])
        let local = FailingPostMergeLocalReviewService()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            localService: local
        )
        var completions: [String] = []
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter(),
            onFetchBaseCompletion: { completions.append("fetch") },
            onCheckOutBaseCompletion: { completions.append("checkout") }
        )
        _ = controller.view
        controller.start()
        await service.waitForLoadCalls(1)

        let fetch = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.fetchBase,
            in: controller.view
        ) as? NSButton)
        fetch.performClick(nil)
        await waitUntil("failed post-merge fetch") {
            self.allText(in: controller.view).contains(FailingPostMergeLocalReviewService.fetchMessage)
        }
        XCTAssertTrue(completions.isEmpty)

        let checkout = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.checkOutBase,
            in: controller.view
        ) as? NSButton)
        checkout.performClick(nil)
        await waitUntil("failed post-merge checkout") {
            self.allText(in: controller.view).contains(FailingPostMergeLocalReviewService.checkoutMessage)
        }
        XCTAssertTrue(completions.isEmpty)
        controller.detach()
    }

    func testRapidReplyAndInlineClicksDispatchOncePerDestination() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace], mutationWorkspace: workspace)
        let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter()
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply"
        await waitUntil("reply controls") {
            self.descendant(identifier: replyID + ".Publish", in: controller.reviewOverlayView) != nil
        }
        let replyEditor = try XCTUnwrap(descendant(identifier: replyID, in: controller.reviewOverlayView) as? NSTextView)
        replyEditor.string = "One immediate reply"
        let reply = try XCTUnwrap(descendant(
            identifier: replyID + ".Publish",
            in: controller.reviewOverlayView
        ) as? NSButton)
        reply.performClick(nil)
        reply.performClick(nil)
        await service.waitForReplyCalls(1)
        await Task.yield()
        let replies = await service.replyPublications()
        XCTAssertEqual(replies.count, 1)

        await waitUntil("reply reconciliation") {
            self.descendant(identifier: replyID + ".Publish", in: controller.reviewOverlayView) != nil
        }
        controller.select(anchor: fixture.anchor, contextLines: ["let old = true"], isTruncated: false)
        let inlineEditor = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        inlineEditor.string = "One immediate inline comment"
        let inline = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePublish,
            in: controller.reviewOverlayView
        ) as? NSButton)
        inline.performClick(nil)
        inline.performClick(nil)
        await service.waitForInlineCalls(1)
        await Task.yield()
        let inlinePublications = await service.inlinePublications()
        XCTAssertEqual(inlinePublications.count, 1)
        controller.detach()
    }

    func testReplySAMLRecoveryPreservesDraftAndRetriesExactMutationOnlyAfterConfirmation() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace], mutationWorkspace: workspace)
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        await service.failNextReply(with: ReviewAuthorizationRecoveryTestFixture.samlError(at: fixture.now))
        let offered = expectation(description: "reply SAML recovery offered")
        var retryAction: (@MainActor () -> Void)?
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter(),
            authorizationRecoveryHandler: { error, retry in
                guard GitHubAuthorizationRecoveryPresentation.make(error: error)?.kind == .saml else {
                    return false
                }
                retryAction = retry
                offered.fulfill()
                return true
            }
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        let replyID = RepositoryPullRequestReviewAccessibility.threadPrefix
            + fixture.threadID.value + ".Reply"
        await waitUntil("reply recovery controls") {
            self.descendant(identifier: replyID + ".Publish", in: controller.reviewOverlayView) != nil
        }
        let editor = try XCTUnwrap(descendant(
            identifier: replyID,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        let body = "Preserve this exact reply"
        editor.string = body
        let publish = try XCTUnwrap(descendant(
            identifier: replyID + ".Publish",
            in: controller.reviewOverlayView
        ) as? NSButton)

        publish.performClick(nil)
        await fulfillment(of: [offered])

        let callsBeforeRetry = await service.replyPublications()
        let savedBeforeRetry = await drafts.savedBodies()
        let deletesBeforeRetry = await drafts.deleteCount()
        XCTAssertEqual(callsBeforeRetry.map(\.bodyMarkdown), [body])
        XCTAssertEqual(savedBeforeRetry, [body])
        XCTAssertEqual(deletesBeforeRetry, 0)
        XCTAssertTrue(session.workspace?.isMutationStateFresh == true)

        retryAction?()
        await service.waitForReplyCalls(2)
        await drafts.waitForDeleteCalls(1)

        let callsAfterRetry = await service.replyPublications()
        XCTAssertEqual(callsAfterRetry.map(\.bodyMarkdown), [body, body])
        XCTAssertEqual(callsAfterRetry.map(\.threadID), [fixture.threadID, fixture.threadID])
        controller.detach()
    }

    func testInlineInstallationRecoveryRetriesCapturedContextAfterSelectionClears() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace], mutationWorkspace: workspace)
        let drafts = FakeReviewDraftStore()
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service,
            drafts: drafts,
            now: { fixture.now }
        )
        await service.failNextInline(
            with: ReviewAuthorizationRecoveryTestFixture.installationError(at: fixture.now)
        )
        let offered = expectation(description: "inline installation recovery offered")
        var retryAction: (@MainActor () -> Void)?
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: OverlayRecordingRouter(),
            authorizationRecoveryHandler: { error, retry in
                guard GitHubAuthorizationRecoveryPresentation.make(error: error)?.kind == .installation else {
                    return false
                }
                retryAction = retry
                offered.fulfill()
                return true
            }
        )
        _ = controller.view
        _ = controller.reviewOverlayView
        controller.start()
        await service.waitForLoadCalls(1)
        controller.select(anchor: fixture.anchor, contextLines: ["let old = true"], isTruncated: false)
        let editor = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlineBody,
            in: controller.reviewOverlayView
        ) as? NSTextView)
        let body = "Preserve this exact inline comment"
        editor.string = body
        let publish = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePublish,
            in: controller.reviewOverlayView
        ) as? NSButton)

        publish.performClick(nil)
        await fulfillment(of: [offered])

        let callsBeforeRetry = await service.inlinePublications()
        let savedBeforeRetry = await drafts.savedBodies()
        let deletesBeforeRetry = await drafts.deleteCount()
        XCTAssertEqual(callsBeforeRetry.map(\.bodyMarkdown), [body])
        XCTAssertEqual(savedBeforeRetry, [body])
        XCTAssertEqual(deletesBeforeRetry, 0)
        controller.clearSelection()

        retryAction?()
        await service.waitForInlineCalls(2)
        await drafts.waitForDeleteCalls(1)

        let callsAfterRetry = await service.inlinePublications()
        XCTAssertEqual(callsAfterRetry.map(\.bodyMarkdown), [body, body])
        XCTAssertEqual(callsAfterRetry.map(\.anchor), [fixture.anchor, fixture.anchor])
        XCTAssertEqual(callsAfterRetry.map(\.displayedHead), [fixture.oldHead, fixture.oldHead])
        controller.detach()
    }

    func testGenericAndUnknownLifecycleFailuresNeverOfferRecoveryOrRetryMutation() async throws {
        let fixture = try ReviewAppFixture()
        let cases: [(RepositoryPullRequestReviewServiceError, Bool)] = [
            (.authoritative("GitHub rejected Close"), false),
            (.outcomeUnknown, true),
        ]

        for (failure, reconcilesUnknownOutcome) in cases {
            let workspace = try fixture.workspace()
            let service = FakeReviewMutationService(workspaces: [workspace, workspace])
            await service.failNextLifecycle(with: failure)
            let session = RepositoryPullRequestReviewSession(identity: fixture.identity, service: service)
            var recoveryPresentationCount = 0
            let controller = RepositoryPullRequestReviewOverlayController(
                session: session,
                router: OverlayRecordingRouter(),
                authorizationRecoveryHandler: { error, _ in
                    guard GitHubAuthorizationRecoveryPresentation.make(error: error) != nil else {
                        return false
                    }
                    recoveryPresentationCount += 1
                    return true
                }
            )
            _ = controller.view
            controller.start()
            await service.waitForLoadCalls(1)
            let closeID = RepositoryPullRequestReviewAccessibility.lifecyclePrefix
                + ForgePullRequestLifecycleAction.close.rawValue
            await waitUntil("Close action") {
                (self.descendant(identifier: closeID, in: controller.view) as? NSButton)?.isEnabled == true
            }
            let close = try XCTUnwrap(descendant(identifier: closeID, in: controller.view) as? NSButton)

            close.performClick(nil)
            await service.waitForLifecycleCalls(1)
            if reconcilesUnknownOutcome {
                await service.waitForLoadCalls(2)
            }
            await waitUntil("non-recoverable lifecycle error") {
                self.allText(in: controller.view).contains(failure.localizedDescription)
            }

            let actions = await service.lifecycleActions()
            let loadCalls = await service.loadCalls()
            XCTAssertEqual(recoveryPresentationCount, 0)
            XCTAssertEqual(actions, [.close], "No failure may automatically retry the mutation")
            XCTAssertEqual(loadCalls, reconcilesUnknownOutcome ? 2 : 1)
            controller.detach()
        }
    }

    func testHostReusesExactSessionMapsSelectionFailClosedAndPlacesDelayedAnchorsOnceStable() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace])
        await service.holdNextLoadCall()
        let applicationSession = RepositoryPullRequestReviewApplicationSession(
            service: service,
            localService: UnavailableRepositoryPullRequestLocalReviewService(),
            drafts: NullRepositoryPullRequestDraftStore(),
            preferences: NullRepositoryPullRequestMutationPreferenceStore()
        )
        let router = OverlayRecordingRouter()
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: applicationSession,
            accountID: fixture.accountID,
            router: router
        )
        let pullRequest = try summary(fixture: fixture)
        let firstActionView = host.actionView(for: pullRequest)
        XCTAssertTrue(firstActionView === host.actionView(for: pullRequest))

        let patch = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -10,1 +10,1 @@
        -let old = true
        +let new = true
        """
        let nativeView = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        nativeView.textView.string = patch
        host.install(
            in: nativeView,
            pullRequest: pullRequest,
            diff: RepositoryLocalPullRequestDiff(
                title: "Local changes",
                patch: patch,
                cacheIdentifier: "m3-review-overlay-test"
            )
        )
        await service.waitForLoadCalls(1)
        let selectedRange = (patch as NSString).range(of: "+let new = true")
        let storage = try XCTUnwrap(nativeView.textView.textStorage)
        XCTAssertNil(storage.attribute(
            .backgroundColor,
            at: selectedRange.location,
            effectiveRange: nil
        ))

        await service.releaseHeldLoad()
        await waitUntil("delayed server anchor highlight") {
            storage.attribute(
                .backgroundColor,
                at: selectedRange.location,
                effectiveRange: nil
            ) != nil
        }
        XCTAssertNotNil(storage.attribute(
            .underlineStyle,
            at: selectedRange.location,
            effectiveRange: nil
        ))

        nativeView.textView.setSelectedRange(selectedRange)
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: nativeView.textView
        )
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePanel,
            in: nativeView
        ))

        nativeView.textView.setSelectedRange((patch as NSString).range(of: "diff --git"))
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: nativeView.textView
        )
        XCTAssertNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePanel,
            in: nativeView
        ))

        // Repeated storage processing must be a bounded no-op rather than
        // recursively re-entering attribute placement.
        for _ in 0 ..< 5 {
            NotificationCenter.default.post(
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
        XCTAssertNotNil(storage.attribute(
            .backgroundColor,
            at: selectedRange.location,
            effectiveRange: nil
        ))

        host.detach()
        XCTAssertNil(storage.attribute(
            .backgroundColor,
            at: selectedRange.location,
            effectiveRange: nil
        ))
        XCTAssertFalse(firstActionView === host.actionView(for: pullRequest))
        host.detach()
    }

    func testHostRefreshReusesSessionAndRepositoryFailureCannotBeOverwrittenByInFlightLoad() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try fixture.workspace()
        let service = FakeReviewMutationService(workspaces: [workspace, workspace])
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: RepositoryPullRequestReviewApplicationSession(
                service: service,
                localService: UnavailableRepositoryPullRequestLocalReviewService(),
                drafts: NullRepositoryPullRequestDraftStore(),
                preferences: NullRepositoryPullRequestMutationPreferenceStore()
            ),
            accountID: fixture.accountID,
            router: OverlayRecordingRouter()
        )
        let pullRequest = try summary(fixture: fixture)
        let actionView = host.actionView(for: pullRequest)
        await service.waitForLoadCalls(1)
        let mergeID = RepositoryPullRequestReviewAccessibility.merge
        await waitUntil("loaded host mutation controls") {
            (self.descendant(identifier: mergeID, in: actionView) as? NSButton)?.isEnabled == true
        }

        await service.holdNextLoadCall()
        host.refresh()
        await service.waitForLoadCalls(2)
        await waitUntil("stale host mutation controls") {
            (self.descendant(identifier: mergeID, in: actionView) as? NSButton)?.isEnabled == false
        }
        XCTAssertTrue(allText(in: actionView).contains("Showing stale review data"))
        XCTAssertTrue(actionView === host.actionView(for: pullRequest))
        let refreshLoadCalls = await service.loadCalls()
        XCTAssertEqual(refreshLoadCalls, 2)

        host.failClosedAfterRepositoryRefresh("Repository list refresh unavailable")
        await waitUntil("repository failure remains visibly stale") {
            self.allText(in: actionView).contains("Repository list refresh unavailable")
                && (self.descendant(identifier: mergeID, in: actionView) as? NSButton)?.isEnabled == false
        }

        await service.releaseHeldLoad()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let finalLoadCalls = await service.loadCalls()
        XCTAssertEqual(finalLoadCalls, 2)
        XCTAssertTrue(allText(in: actionView).contains("Repository list refresh unavailable"))
        XCTAssertFalse(try XCTUnwrap(descendant(identifier: mergeID, in: actionView) as? NSButton).isEnabled)
        host.detach()
    }

    func testOverlappingDuplicateHighlightsRestoreEveryOriginalTextAttributeLosslessly() async throws {
        let fixture = try ReviewAppFixture()
        let record = try fixture.threadRecord()
        let workspace = try replacingThreads(in: fixture.workspace(), with: [record, record])
        let service = FakeReviewMutationService(workspaces: [workspace])
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: RepositoryPullRequestReviewApplicationSession(
                service: service,
                localService: UnavailableRepositoryPullRequestLocalReviewService(),
                drafts: NullRepositoryPullRequestDraftStore(),
                preferences: NullRepositoryPullRequestMutationPreferenceStore()
            ),
            accountID: fixture.accountID,
            router: OverlayRecordingRouter()
        )
        let pullRequest = try summary(fixture: fixture)
        _ = host.actionView(for: pullRequest)
        let patch = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -10,1 +10,1 @@
        -let old = true
        +let new = true
        """
        let highlightedRange = (patch as NSString).range(of: "+let new = true")
        let nativeView = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        nativeView.textView.string = patch
        let storage = try XCTUnwrap(nativeView.textView.textStorage)
        storage.addAttributes([
            .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.3),
            .foregroundColor: NSColor.systemGreen,
            .underlineColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.double.rawValue,
            .kern: 1.5,
        ], range: highlightedRange)
        let original = NSAttributedString(attributedString: storage)

        host.install(
            in: nativeView,
            pullRequest: pullRequest,
            diff: RepositoryLocalPullRequestDiff(
                title: "Overlapping review highlights",
                patch: patch,
                cacheIdentifier: "m3-overlapping-highlight-test"
            )
        )
        await service.waitForLoadCalls(1)
        await waitUntil("deduplicated review highlight") {
            (storage.attribute(
                .backgroundColor,
                at: highlightedRange.location,
                effectiveRange: nil
            ) as? NSColor) != NSColor.systemPurple.withAlphaComponent(0.3)
        }

        host.detach()
        XCTAssertTrue(storage.isEqual(to: original))
    }

    func testOutdatedThreadWithoutExactLocalMatchNeverHighlightsHistoricalServerAnchor() async throws {
        let fixture = try ReviewAppFixture()
        let source = try fixture.threadRecord(outdated: true)
        let unplaced = try RepositoryPullRequestReviewThreadRecord(
            pullRequest: source.pullRequest,
            presentation: source.presentation,
            exactOutdatedLocalAnchor: nil,
            suggestedChanges: []
        )
        let workspace = try replacingThreads(in: fixture.workspace(), with: [unplaced])
        let service = FakeReviewMutationService(workspaces: [workspace])
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: RepositoryPullRequestReviewApplicationSession(
                service: service,
                localService: UnavailableRepositoryPullRequestLocalReviewService(),
                drafts: NullRepositoryPullRequestDraftStore(),
                preferences: NullRepositoryPullRequestMutationPreferenceStore()
            ),
            accountID: fixture.accountID,
            router: OverlayRecordingRouter()
        )
        let pullRequest = try summary(fixture: fixture)
        _ = host.actionView(for: pullRequest)
        let patch = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -10,1 +10,1 @@
        -let old = true
        +let new = true
        """
        let serverAnchorRange = (patch as NSString).range(of: "+let new = true")
        let nativeView = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        nativeView.textView.string = patch
        host.install(
            in: nativeView,
            pullRequest: pullRequest,
            diff: RepositoryLocalPullRequestDiff(
                title: "Outdated review",
                patch: patch,
                cacheIdentifier: "m3-outdated-unplaced-test"
            )
        )
        await service.waitForLoadCalls(1)
        await waitUntil("outdated thread presentation") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.threadPrefix + fixture.threadID.value,
                in: nativeView
            ) != nil
        }

        XCTAssertNil(nativeView.textView.textStorage?.attribute(
            .backgroundColor,
            at: serverAnchorRange.location,
            effectiveRange: nil
        ))
        XCTAssertNotNil(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.threadPrefix
                + fixture.threadID.value + ".Outdated",
            in: nativeView
        ))
        host.detach()
    }

    func testHostPlacesInteractiveThreadsInlineInAnchorOrderWithAccessibleState() async throws {
        let fixture = try ReviewAppFixture()
        let source = try fixture.threadRecord()
        let fileRecord = try replacingThread(
            source,
            id: "thread-file",
            anchor: ForgeReviewAnchor(path: fixture.path, subject: .file)
        )
        let rangeRecord = try replacingThread(
            source,
            id: "thread-range",
            anchor: ForgeReviewAnchor(
                path: fixture.path,
                subject: .line,
                side: .right,
                startSide: .right,
                startLine: 9,
                line: 10
            )
        )
        let outdatedRecord = try replacingThread(
            source,
            id: "thread-outdated",
            anchor: fixture.anchor,
            isOutdated: true,
            exactOutdatedLocalAnchor: ForgeReviewAnchor(
                path: fixture.path,
                subject: .line,
                side: .right,
                line: 11
            )
        )
        let workspace = try replacingThreads(
            in: fixture.workspace(),
            with: [outdatedRecord, rangeRecord, fileRecord]
        )
        let service = FakeReviewMutationService(workspaces: [workspace])
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: RepositoryPullRequestReviewApplicationSession(
                service: service,
                localService: UnavailableRepositoryPullRequestLocalReviewService(),
                drafts: NullRepositoryPullRequestDraftStore(),
                preferences: NullRepositoryPullRequestMutationPreferenceStore()
            ),
            accountID: fixture.accountID,
            router: OverlayRecordingRouter()
        )
        let pullRequest = try summary(fixture: fixture)
        _ = host.actionView(for: pullRequest)
        let patch = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -8,3 +8,4 @@
         before
        -let old = true
        +let first = true
        +let second = true
         after
        """
        let nativeView = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 720))
        nativeView.textView.string = patch
        host.install(
            in: nativeView,
            pullRequest: pullRequest,
            diff: RepositoryLocalPullRequestDiff(
                title: "Inline review threads",
                patch: patch,
                cacheIdentifier: "m3-inline-thread-placement-test"
            )
        )
        await service.waitForLoadCalls(1)
        let prefix = RepositoryPullRequestReviewAccessibility.threadPrefix
        await waitUntil("all anchored inline thread cards") {
            ["thread-file", "thread-range", "thread-outdated"].allSatisfy {
                self.descendant(identifier: prefix + $0, in: nativeView.textView) != nil
            }
        }

        let fileView = try XCTUnwrap(descendant(identifier: prefix + "thread-file", in: nativeView.textView))
        let rangeView = try XCTUnwrap(descendant(identifier: prefix + "thread-range", in: nativeView.textView))
        let outdatedView = try XCTUnwrap(descendant(
            identifier: prefix + "thread-outdated",
            in: nativeView.textView
        ))
        XCTAssertTrue(fileView.superview === nativeView.textView)
        XCTAssertTrue(rangeView.superview === nativeView.textView)
        XCTAssertTrue(outdatedView.superview === nativeView.textView)
        XCTAssertLessThan(fileView.frame.minY, rangeView.frame.minY)
        XCTAssertLessThan(rangeView.frame.minY, outdatedView.frame.minY)
        XCTAssertFalse(fileView.accessibilityLabel()?.isEmpty ?? true)
        XCTAssertNotNil(descendant(identifier: prefix + "thread-outdated.Outdated", in: outdatedView))
        XCTAssertTrue(allText(in: outdatedView).contains("Minimized: Off-topic"))
        XCTAssertTrue(allText(in: outdatedView).contains("Deleted comment"))
        XCTAssertTrue(allText(in: outdatedView).contains("Comment unavailable"))
        XCTAssertEqual(
            descendants(in: nativeView).filter {
                $0.accessibilityIdentifier() == prefix + "thread-file"
            }.count,
            1
        )

        host.detach()
    }

    func testHostUsesExactNativeSelectionRangeForRepeatedDiffLine() async throws {
        let fixture = try ReviewAppFixture()
        let workspace = try replacingThreads(in: fixture.workspace(), with: [])
        let service = FakeReviewMutationService(workspaces: [workspace])
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: RepositoryPullRequestReviewApplicationSession(
                service: service,
                localService: UnavailableRepositoryPullRequestLocalReviewService(),
                drafts: NullRepositoryPullRequestDraftStore(),
                preferences: NullRepositoryPullRequestMutationPreferenceStore()
            ),
            accountID: fixture.accountID,
            router: OverlayRecordingRouter()
        )
        let pullRequest = try summary(fixture: fixture)
        _ = host.actionView(for: pullRequest)
        let firstPatch = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -0,0 +1 @@
        +let repeated = true
        """
        let patch = firstPatch + "\n" + firstPatch.replacingOccurrences(
            of: "File.swift",
            with: "Other.swift"
        )
        let nativeView = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        nativeView.textView.string = patch
        host.install(
            in: nativeView,
            pullRequest: pullRequest,
            diff: RepositoryLocalPullRequestDiff(
                title: "Repeated inline selection",
                patch: patch,
                cacheIdentifier: "m3-repeated-inline-selection-test"
            )
        )
        await service.waitForLoadCalls(1)

        let source = patch as NSString
        let first = source.range(of: "+let repeated = true")
        let second = source.range(
            of: "+let repeated = true",
            options: [],
            range: NSRange(location: NSMaxRange(first), length: source.length - NSMaxRange(first))
        )
        nativeView.textView.setSelectedRange(second)
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: nativeView.textView
        )

        await waitUntil("repeated-line inline composer") {
            self.descendant(
                identifier: RepositoryPullRequestReviewAccessibility.inlinePanel,
                in: nativeView
            ) != nil
        }
        let composer = try XCTUnwrap(descendant(
            identifier: RepositoryPullRequestReviewAccessibility.inlinePanel,
            in: nativeView
        ) as? NSBox)
        XCTAssertTrue(composer.title.contains("Sources/Other.swift"))
        XCTAssertTrue(composer.accessibilityLabel()?.contains("Sources/Other.swift") == true)
        host.detach()
    }

    // MARK: - Fixtures

    private func replacingThreadExpansion(
        in workspace: RepositoryPullRequestReviewWorkspace,
        with expansion: ForgeReviewThreadExpansion
    ) throws -> RepositoryPullRequestReviewWorkspace {
        let threads = try workspace.threads.map { record in
            let source = record.presentation
            let presentation = try ForgeReviewThreadPresentation(
                thread: source.thread,
                expansion: expansion,
                commentVisibility: source.commentVisibility,
                commentReactions: source.commentReactions
            )
            return try RepositoryPullRequestReviewThreadRecord(
                pullRequest: record.pullRequest,
                presentation: presentation,
                exactOutdatedLocalAnchor: record.exactOutdatedLocalAnchor,
                suggestedChanges: record.suggestedChanges
            )
        }
        return try replacingThreads(in: workspace, with: threads)
    }

    private func replacingThread(
        _ record: RepositoryPullRequestReviewThreadRecord,
        id: String,
        anchor: ForgeReviewAnchor,
        isOutdated: Bool = false,
        exactOutdatedLocalAnchor: ForgeReviewAnchor? = nil
    ) throws -> RepositoryPullRequestReviewThreadRecord {
        let source = record.presentation
        let thread = try ForgeReviewThread(
            repository: source.thread.repository,
            id: ForgeObjectID(forge: source.thread.repository.forge, value: id),
            isResolved: source.thread.isResolved,
            isOutdated: isOutdated,
            anchor: .available(anchor),
            comments: source.thread.comments
        )
        let presentation = try ForgeReviewThreadPresentation(
            thread: thread,
            expansion: source.expansion,
            commentVisibility: source.commentVisibility,
            commentReactions: source.commentReactions
        )
        return try RepositoryPullRequestReviewThreadRecord(
            pullRequest: record.pullRequest,
            presentation: presentation,
            exactOutdatedLocalAnchor: exactOutdatedLocalAnchor,
            suggestedChanges: []
        )
    }

    private func replacingThreads(
        in workspace: RepositoryPullRequestReviewWorkspace,
        with threads: [RepositoryPullRequestReviewThreadRecord]
    ) throws -> RepositoryPullRequestReviewWorkspace {
        try RepositoryPullRequestReviewWorkspace(
            identity: workspace.identity,
            displayedHead: workspace.displayedHead,
            base: workspace.base,
            title: workspace.title,
            isDraft: workspace.isDraft,
            threads: threads,
            reviewers: workspace.reviewers,
            mutationContext: workspace.mutationContext,
            mergeSnapshot: workspace.mergeSnapshot,
            headBranchDeletionSnapshot: workspace.headBranchDeletionSnapshot,
            canUpdateBranch: workspace.canUpdateBranch,
            isMutationStateFresh: workspace.isMutationStateFresh,
            fetchedAt: workspace.fetchedAt
        )
    }

    private func summary(fixture: ReviewAppFixture) throws -> ForgePullRequestSummary {
        try ForgePullRequestSummary(
            repository: fixture.repository,
            number: fixture.number,
            state: .open,
            isDraft: false,
            title: "Native review",
            author: .unavailable(.notRequested),
            head: .available(ForgePullRequestHead(reference: fixture.head)),
            base: .available(fixture.base),
            createdAt: fixture.now,
            updatedAt: fixture.now,
            labels: .available([]),
            checkRollup: .available(.running),
            reviewRollup: .available(.reviewRequired)
        )
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pull Request Review Harness"
        window.contentView = content
        window.layoutIfNeeded()
        return window
    }

    private func descendant(identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func allText(in root: NSView) -> String {
        ([root] + root.subviews.flatMap { descendants(in: $0) })
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
    }

    @discardableResult
    private func assertSanitizedPreview(
        editorID: String,
        in root: NSView,
        markdown: String = "**bold** ![secret](file:///etc/passwd) [PR](https://github.com/hbmartin/gitx/pull/7)",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ForgeMarkdownNativeView {
        let editor = try XCTUnwrap(
            descendant(identifier: editorID, in: root) as? NSTextView,
            file: file,
            line: line
        )
        editor.string = markdown
        let control = try XCTUnwrap(
            descendant(identifier: editorID + ".WritePreview", in: root) as? NSSegmentedControl,
            file: file,
            line: line
        )
        control.selectedSegment = 1
        try NSApp.sendAction(XCTUnwrap(control.action), to: control.target, from: control)
        let previewContainer = try XCTUnwrap(
            descendant(identifier: editorID + ".Preview", in: root),
            file: file,
            line: line
        )
        let preview = try XCTUnwrap(
            descendants(in: previewContainer).first { $0 is ForgeMarkdownNativeView }
                as? ForgeMarkdownNativeView,
            file: file,
            line: line
        )
        if markdown.contains("**bold**") {
            XCTAssertTrue(preview.textView.string.contains("bold"), file: file, line: line)
            XCTAssertTrue(preview.textView.string.contains("▧ Image: secret"), file: file, line: line)
            XCTAssertFalse(preview.textView.string.contains("file:///etc/passwd"), file: file, line: line)
        }
        return preview
    }

    private func linkURLs(in value: NSAttributedString) -> [URL] {
        var links: [URL] = []
        value.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: value.length)
        ) { candidate, _, _ in
            if let url = candidate as? URL {
                links.append(url)
            }
        }
        return links
    }

    private func assertRoutesMarkdownLink(
        _ view: ForgeMarkdownNativeView,
        through router: OverlayRecordingRouter,
        to expectedURL: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let link = try XCTUnwrap(
            linkURLs(in: view.textView.attributedString()).first,
            file: file,
            line: line
        )
        XCTAssertTrue(view.activateLink(link), file: file, line: line)
        guard case let .native(destination) = try XCTUnwrap(
            router.markdownTargets.last,
            file: file,
            line: line
        ) else {
            return XCTFail("Expected a native Markdown destination", file: file, line: line)
        }
        XCTAssertEqual(
            try ForgeDestinationURLCodec.url(for: destination).absoluteString,
            expectedURL,
            file: file,
            line: line
        )
    }

    private func descendants(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants(in: $0) }
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func attachScreenshot(of window: NSWindow, named name: String) throws {
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        let screenshot = NSImage(size: contentView.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FailingPostMergeLocalReviewService: RepositoryPullRequestLocalReviewServing {
    static let fetchMessage = "Post-merge fetch failed"
    static let checkoutMessage = "Post-merge checkout failed"

    func reanchorCandidates(
        for _: ForgeReviewContext,
        currentHead _: ForgeCommitID
    ) async throws -> [ForgeReviewReanchorCandidate] {
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    func checkedOutHead() async throws -> ForgeCommitID? {
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    func applySuggestedChange(_: ForgeSuggestedChange) async throws {
        throw RepositoryPullRequestReviewServiceError.unavailable
    }

    func fetchBase(_: ForgeBranchReference) async throws {
        throw RepositoryPullRequestReviewServiceError.authoritative(Self.fetchMessage)
    }

    func checkOutBase(_: ForgeBranchReference) async throws {
        throw RepositoryPullRequestReviewServiceError.authoritative(Self.checkoutMessage)
    }
}

@MainActor
private final class OverlayRecordingRouter: RepositoryPullRequestReviewRouting, ForgeMarkdownNavigationRouting {
    private(set) var destinations: [ForgeDestination] = []
    private(set) var markdownTargets: [ForgeMarkdownLinkTarget] = []
    private(set) var browserURLs: [URL] = []

    func openInBrowser(_ destination: ForgeDestination) {
        destinations.append(destination)
    }

    func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget) {
        markdownTargets.append(target)
    }

    func openMarkdownLinkInBrowser(_ url: URL) {
        browserURLs.append(url)
    }
}

private actor HoldingMutationPreferences: RepositoryPullRequestMutationPreferencePersisting {
    private var preferredContinuation: CheckedContinuation<ForgePullRequestMergeMethod?, Never>?
    private var preferredRequested = false
    private var preferredWaiters: [CheckedContinuation<Void, Never>] = []
    private var deleteContinuation: CheckedContinuation<Bool, Never>?
    private var deleteRequested = false
    private var deleteWaiters: [CheckedContinuation<Void, Never>] = []

    func preferredMergeMethod(
        repository _: ForgeRepositoryIdentity,
        enabled _: Set<ForgePullRequestMergeMethod>
    ) async -> ForgePullRequestMergeMethod? {
        preferredRequested = true
        preferredWaiters.forEach { $0.resume() }
        preferredWaiters.removeAll()
        return await withCheckedContinuation { preferredContinuation = $0 }
    }

    func recordSuccessfulMerge(
        repository _: ForgeRepositoryIdentity,
        method _: ForgePullRequestMergeMethod
    ) async {}

    func rememberedDeleteBranchChoice(repository _: ForgeRepositoryIdentity) async -> Bool {
        deleteRequested = true
        deleteWaiters.forEach { $0.resume() }
        deleteWaiters.removeAll()
        return await withCheckedContinuation { deleteContinuation = $0 }
    }

    func recordSuccessfulDeleteBranchChoice(
        repository _: ForgeRepositoryIdentity,
        selected _: Bool
    ) async {}

    func waitForPreferredRequest() async {
        if preferredRequested {
            return
        }
        await withCheckedContinuation { preferredWaiters.append($0) }
    }

    func releasePreferred(_ method: ForgePullRequestMergeMethod?) {
        preferredContinuation?.resume(returning: method)
        preferredContinuation = nil
    }

    func waitForDeleteRequest() async {
        if deleteRequested {
            return
        }
        await withCheckedContinuation { deleteWaiters.append($0) }
    }

    func releaseDelete(_ choice: Bool) {
        deleteContinuation?.resume(returning: choice)
        deleteContinuation = nil
    }
}
