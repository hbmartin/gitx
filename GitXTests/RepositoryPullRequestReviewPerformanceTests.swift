import AppKit
import ForgeKit
import XCTest

/// Stable Milestone 3 benchmarks run only by the shared performance plan.
/// Fixture construction and asynchronous workspace loading stay outside the
/// measured blocks so the gates isolate native presentation and cached UI work.
@MainActor
final class RepositoryPullRequestReviewPerformanceTests: XCTestCase {
    private enum Budget {
        static let overlayApplication: TimeInterval = 0.016
        static let cachedModeSwitch: TimeInterval = 0.050
        static let sampleCount = 40
        static let threadCount = 40
        static let commentsPerThread = 4
    }

    func testRepresentativeReviewOverlayPresentationAndApplicationMeetMainThreadBudget() async throws {
        let fixture = try ReviewPerformanceFixture(
            threadCount: Budget.threadCount,
            commentsPerThread: Budget.commentsPerThread
        )
        let service = ReviewPerformanceService(workspace: fixture.workspace)
        let session = RepositoryPullRequestReviewSession(
            identity: fixture.identity,
            service: service
        )
        let controller = RepositoryPullRequestReviewOverlayController(
            session: session,
            router: ReviewPerformanceRouter()
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 260)
        controller.reviewOverlayView.frame = NSRect(x: 0, y: 0, width: 760, height: 330)
        let window = NSWindow(
            contentRect: controller.reviewOverlayView.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.reviewOverlayView

        controller.start()
        await service.waitForLoad()
        await waitUntil("representative review workspace is visible") {
            session.workspace?.threads.count == Budget.threadCount
                && controller.reviewOverlayView.accessibilityIdentifier()
                == RepositoryPullRequestReviewAccessibility.overlayRoot
        }

        let representativeThread = try XCTUnwrap(fixture.workspace.threads.first)
        let renderOverlay = try XCTUnwrap(session.onResolutionChange)
        renderOverlay(
            representativeThread.presentation.thread.id,
            .confirmed(isResolved: false)
        )
        controller.reviewOverlayView.layoutSubtreeIfNeeded()

        var samples: [TimeInterval] = []
        for index in 0 ..< Budget.sampleCount {
            samples.append(elapsed {
                // This is the production state observer used for optimistic
                // resolution changes. Alternating the confirmed value forces
                // real control replacement and layout rather than measuring
                // the identical-presentation cache hit.
                renderOverlay(
                    representativeThread.presentation.thread.id,
                    .confirmed(isResolved: index.isMultiple(of: 2))
                )
                controller.reviewOverlayView.layoutSubtreeIfNeeded()
            })
        }

        attachMeasurements(
            "M3 native review overlay: 40 threads and 160 comments",
            samples: samples
        )
        XCTAssertEqual(fixture.workspace.threads.count, Budget.threadCount)
        XCTAssertEqual(
            fixture.commentCount,
            Budget.threadCount * Budget.commentsPerThread
        )
        XCTAssertEqual(
            renderedCommentViewCount(in: controller.reviewOverlayView),
            Budget.threadCount * Budget.commentsPerThread
        )
        XCTAssertTrue(window.contentView === controller.reviewOverlayView)
        XCTAssertLessThanOrEqual(percentile95(samples), Budget.overlayApplication)
        withExtendedLifetime(window) {}
    }

    func testCachedOverviewChangesActionAreaReuseMeetsAffectedViewBudget() async throws {
        let fixture = try ReviewPerformanceFixture(threadCount: 8, commentsPerThread: 2)
        let service = ReviewPerformanceService(workspace: fixture.workspace)
        let applicationSession = RepositoryPullRequestReviewApplicationSession(
            service: service,
            localService: UnavailableRepositoryPullRequestLocalReviewService(),
            drafts: NullRepositoryPullRequestDraftStore(),
            preferences: NullRepositoryPullRequestMutationPreferenceStore()
        )
        let host = RepositoryPullRequestReviewOverlayHost(
            applicationSession: applicationSession,
            accountID: fixture.identity.accountID,
            router: ReviewPerformanceRouter()
        )
        let overview = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 260))
        let changes = NSView(frame: overview.frame)
        let actionView = host.actionView(for: fixture.summary)
        actionView.frame = overview.bounds

        await service.waitForLoad()
        await waitUntil("cached action area is loaded") {
            self.containsText(fixture.workspace.title, in: actionView)
        }

        func moveActionView(to container: NSView) -> NSView {
            let reused = host.actionView(for: fixture.summary)
            reused.removeFromSuperview()
            reused.frame = container.bounds
            container.addSubview(reused)
            container.layoutSubtreeIfNeeded()
            reused.layoutSubtreeIfNeeded()
            return reused
        }

        _ = moveActionView(to: overview)
        _ = moveActionView(to: changes)
        var latestView = actionView
        var samples: [TimeInterval] = []
        for _ in 0 ..< Budget.sampleCount {
            samples.append(elapsed {
                latestView = moveActionView(to: overview)
                latestView = moveActionView(to: changes)
            })
        }

        attachMeasurements(
            "M3 cached Overview-Changes review action-area reuse",
            samples: samples
        )
        XCTAssertTrue(actionView === latestView)
        XCTAssertTrue(latestView.superview === changes)
        XCTAssertLessThanOrEqual(percentile95(samples), Budget.cachedModeSwitch)
    }

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func percentile95(_ samples: [TimeInterval]) -> TimeInterval {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private func attachMeasurements(_ name: String, samples: [TimeInterval]) {
        let milliseconds = samples
            .map { String(format: "%.2f", $0 * 1000) }
            .joined(separator: ", ")
        let attachment = XCTAttachment(
            string: "p95=\(String(format: "%.2f", percentile95(samples) * 1000))ms\n"
                + "samples(ms)=\(milliseconds)"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 2000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting until \(description)")
    }

    private func containsText(_ text: String, in view: NSView) -> Bool {
        if let label = view as? NSTextField, label.stringValue.contains(text) {
            return true
        }
        return view.subviews.contains { containsText(text, in: $0) }
    }

    private func renderedCommentViewCount(in view: NSView) -> Int {
        let identifier = view.accessibilityIdentifier()
        let suffix = identifier.range(of: ".Comment.").map { identifier[$0.upperBound...] }
        let isComment = identifier.hasPrefix(RepositoryPullRequestReviewAccessibility.threadPrefix)
            && suffix?.isEmpty == false
            && suffix?.allSatisfy(\.isNumber) == true
        return (isComment ? 1 : 0) + view.subviews.reduce(into: 0) { count, child in
            count += renderedCommentViewCount(in: child)
        }
    }
}

private struct ReviewPerformanceFixture {
    let identity: RepositoryPullRequestReviewIdentity
    let workspace: RepositoryPullRequestReviewWorkspace
    let summary: ForgePullRequestSummary
    let commentCount: Int

    init(threadCount: Int, commentsPerThread: Int) throws {
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let forge = try ForgeIdentity(
            kind: .github,
            origin: ForgeOrigin(host: "github.com")
        )
        let repository = try ForgeRepositoryIdentity(
            forge: forge,
            owner: "hbmartin",
            name: "gitx"
        )
        let accountID = try ForgeAccountID(forge: forge, value: "performance-account")
        let number = try ForgeItemNumber(42)
        let head = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("feature/native-review-performance"),
            commit: ForgeCommitID(String(repeating: "a", count: 40))
        )
        let base = try ForgeBranchReference(
            repository: repository,
            name: ForgeRefName("main"),
            commit: ForgeCommitID(String(repeating: "b", count: 40))
        )
        let identity = try RepositoryPullRequestReviewIdentity(
            accountID: accountID,
            repository: repository,
            number: number
        )

        var records: [RepositoryPullRequestReviewThreadRecord] = []
        for threadIndex in 0 ..< threadCount {
            let path = try ForgeFilePath("Sources/Feature/File-\(threadIndex % 8).swift")
            var comments: [ForgeReviewComment] = []
            var visibility: [ForgeObjectID: ForgeReviewCommentVisibility] = [:]
            var reactions: [ForgeObjectID: [ForgeReviewReactionSummary]] = [:]
            for commentIndex in 0 ..< commentsPerThread {
                let commentID = try ForgeObjectID(
                    forge: forge,
                    value: "performance-comment-\(threadIndex)-\(commentIndex)"
                )
                comments.append(ForgeReviewComment(
                    repository: repository,
                    id: commentID,
                    bodyMarkdown: "Review comment \(commentIndex) on thread \(threadIndex): "
                        + String(repeating: "representative context ", count: 4),
                    createdAt: now.addingTimeInterval(Double(threadIndex * 10 + commentIndex)),
                    updatedAt: now.addingTimeInterval(Double(threadIndex * 10 + commentIndex)),
                    author: .unavailable(.partialResponse)
                ))
                visibility[commentID] = switch commentIndex % 4 {
                case 1: .minimized(reason: "Off-topic")
                case 2: .deleted
                case 3: .unavailable
                default: .ordinary
                }
                if commentIndex.isMultiple(of: 4) {
                    reactions[commentID] = try [
                        ForgeReviewReactionSummary(
                            kind: .thumbsUp,
                            count: 3,
                            viewerReacted: false
                        ),
                        ForgeReviewReactionSummary(
                            kind: .eyes,
                            count: 1,
                            viewerReacted: false
                        ),
                    ]
                }
            }
            let thread = try ForgeReviewThread(
                repository: repository,
                id: ForgeObjectID(
                    forge: forge,
                    value: "performance-thread-\(threadIndex)"
                ),
                isResolved: threadIndex.isMultiple(of: 3),
                isOutdated: threadIndex.isMultiple(of: 7),
                anchor: .available(ForgeReviewAnchor(
                    path: path,
                    subject: .line,
                    side: .right,
                    line: threadIndex + 1
                )),
                comments: .available(ForgePage(items: comments))
            )
            let presentation = try ForgeReviewThreadPresentation(
                thread: thread,
                expansion: .expanded,
                commentVisibility: visibility,
                commentReactions: reactions
            )
            try records.append(RepositoryPullRequestReviewThreadRecord(
                pullRequest: number,
                presentation: presentation
            ))
        }

        let mutationContext = try ForgePullRequestMutationContext(
            accountID: accountID,
            repository: repository,
            number: number,
            state: .open,
            isDraft: false,
            head: head,
            base: base,
            updatedAt: now,
            allowedOperations: Set(ForgeOperation.allCases)
        )
        let mergeSnapshot = ForgePullRequestMergeSnapshot(
            context: mutationContext,
            viewerCanMerge: true,
            enabledMethods: Set(ForgePullRequestMergeMethod.allCases),
            warnings: [.checksPending],
            queueState: .notQueued
        )
        self.identity = identity
        workspace = try RepositoryPullRequestReviewWorkspace(
            identity: identity,
            displayedHead: head.commit,
            base: base,
            title: "Representative native review performance",
            isDraft: false,
            threads: records,
            reviewers: .available([]),
            mutationContext: mutationContext,
            mergeSnapshot: mergeSnapshot,
            canUpdateBranch: false,
            fetchedAt: now
        )
        summary = try ForgePullRequestSummary(
            repository: repository,
            number: number,
            state: .open,
            isDraft: false,
            title: workspace.title,
            author: .unavailable(.partialResponse),
            head: .available(head),
            base: .available(base),
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now,
            labels: .available([]),
            checkRollup: .available(.running),
            reviewRollup: .unavailable(.partialResponse)
        )
        commentCount = records.reduce(into: 0) { count, record in
            if case let .available(page) = record.presentation.thread.comments {
                count += page.items.count
            }
        }
    }
}

private actor ReviewPerformanceService: RepositoryPullRequestReviewMutationServing {
    private let workspace: RepositoryPullRequestReviewWorkspace
    private var loadCount = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    init(workspace: RepositoryPullRequestReviewWorkspace) {
        self.workspace = workspace
    }

    func loadWorkspace(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        guard identity == workspace.identity else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
        loadCount += 1
        loadWaiters.forEach { $0.resume() }
        loadWaiters.removeAll()
        return workspace
    }

    func waitForLoad() async {
        if loadCount > 0 {
            return
        }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func publishInlineReview(
        _: ForgeInlineReviewPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func replyToReviewThread(
        _: ForgeReviewThreadReplyPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func setReviewThreadResolution(
        identity _: RepositoryPullRequestReviewIdentity,
        threadID _: ForgeObjectID,
        mutation _: ForgeReviewThreadResolutionMutation
    ) async throws {}

    func submitFormalReview(
        _: ForgeFormalReviewSubmission
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func performLifecycle(
        _: ForgePullRequestLifecycleRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func freshMergeSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgePullRequestMergeSnapshot {
        workspace.mergeSnapshot
    }

    func mergePullRequest(
        _: ForgePullRequestMergeRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func changeMergeQueue(
        _: ForgePullRequestMergeQueueRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        workspace
    }

    func freshHeadBranchDeletionSnapshot(
        identity _: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        guard let snapshot = workspace.headBranchDeletionSnapshot else {
            throw RepositoryPullRequestReviewServiceError.unavailable
        }
        return snapshot
    }

    func deleteHeadBranch(_: ForgeHeadBranchDeletionRequest) async throws {}
}

@MainActor
private final class ReviewPerformanceRouter: RepositoryPullRequestReviewRouting {
    func openInBrowser(_: ForgeDestination) {}
}
