import AppKit
import ForgeKit
import XCTest

@MainActor
final class ForgeReadSurfaceViewControllerTests: XCTestCase {
    func testNativeAppKitHarnessLoadsListInspectorMarkdownAvatarAndRoutesBrowserAction() async throws {
        let service = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.pullRequest(ReadFixture.pullRequest())],
                totalCount: 1,
                fetchedAt: ReadFixture.date(1)
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(ReadFixture.pullRequestDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let markdown = RecordingMarkdownRenderer()
        let avatars = RecordingAvatarRenderer()
        let router = RecordingDestinationRouter()
        let controller = try makeController(
            kind: .pullRequests,
            service: service,
            markdown: markdown,
            avatars: avatars,
            router: router
        )
        let window = makeWindow(controller)

        controller.viewDidAppear()
        await service.waitForListCall()
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.accessibilityLabel(), "Pull Requests")
        let status = try XCTUnwrap(descendant(identifier: "ForgeReadStatus", in: controller.view) as? NSTextField)
        XCTAssertTrue(status.isHidden)
        let total = try XCTUnwrap(descendant(identifier: "ForgeReadTotal", in: controller.view) as? NSTextField)
        XCTAssertEqual(total.stringValue, "Showing 1 of 1")

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await service.waitForDetailsCall()
        await settleMainActor()

        let title = try XCTUnwrap(descendant(identifier: "ForgeInspectorTitle", in: controller.view) as? NSTextField)
        XCTAssertEqual(title.stringValue, "Native read surface")
        XCTAssertEqual(markdown.renderedMarkdown, [
            "## Summary\n\nNo active images: ![remote](https://example.com/a.png)",
            "A timeline comment",
        ])
        XCTAssertEqual(avatars.displayedLogins, ["ari"])
        let body = try XCTUnwrap(descendant(identifier: "ForgeInspectorBody", in: controller.view))
        XCTAssertEqual(body.accessibilityIdentifier(), "ForgeInspectorBody")

        let browser = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorOpenInBrowser", in: controller.view) as? NSButton
        )
        browser.performClick(nil)
        XCTAssertEqual(router.browserDestinations, try [ForgeDestination.pullRequest(
            ReadFixture.repository(),
            ForgeItemNumber(42)
        )])
        try NSApp.sendAction(XCTUnwrap(table.doubleAction), to: table.target, from: table)
        XCTAssertEqual(router.nativeDestinations, try [ForgeDestination.pullRequest(
            ReadFixture.repository(),
            ForgeItemNumber(42)
        )])

        try attachScreenshot(of: window, named: "GitHub Pull Request native list and inspector")
    }

    func testPaginationAppendsRowsAndHidesLoadMoreAtLastPage() async throws {
        let service = try FakeReadService(
            pages: [
                ForgeReadSurfacePage(
                    items: [.issue(ReadFixture.issue(number: 1))],
                    nextCursor: ForgePageCursor("next"),
                    totalCount: 2,
                    fetchedAt: ReadFixture.date(1)
                ),
                ForgeReadSurfacePage(
                    items: [
                        .issue(ReadFixture.issue(number: 1)),
                        .issue(ReadFixture.issue(number: 2)),
                    ],
                    totalCount: 2,
                    fetchedAt: ReadFixture.date(2)
                ),
            ],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let controller = try makeController(kind: .issues, service: service)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall(count: 1)
        await settleMainActor()

        let loadMore = try XCTUnwrap(descendant(identifier: "ForgeReadLoadMore", in: controller.view) as? NSButton)
        XCTAssertFalse(loadMore.isHidden)
        loadMore.performClick(nil)
        await service.waitForListCall(count: 2)
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertTrue(loadMore.isHidden)
        XCTAssertEqual(service.listCalls.map { $0.cursor?.value }, [nil, "next"])
    }

    func testPendingNativeDestinationOpensAfterItsFirstListPageArrives() async throws {
        let pullRequest = try ReadFixture.pullRequest()
        let service = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.pullRequest(pullRequest)],
                fetchedAt: ReadFixture.date(1)
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(ReadFixture.pullRequestDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let controller = try makeController(kind: .pullRequests, service: service)
        _ = makeWindow(controller)
        XCTAssertTrue(try controller.open(destination: .pullRequest(
            ReadFixture.repository(),
            pullRequest.number
        )))

        controller.viewDidAppear()
        await service.waitForDetailsCall()
        await settleMainActor()

        let title = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorTitle", in: controller.view) as? NSTextField
        )
        XCTAssertEqual(title.stringValue, "Native read surface")
    }

    func testSearchAndStateFilterReloadWithTrimmedInjectedQuery() async throws {
        let service = try FakeReadService(
            pages: [
                ForgeReadSurfacePage(items: [], fetchedAt: ReadFixture.date(1)),
                ForgeReadSurfacePage(items: [], fetchedAt: ReadFixture.date(2)),
                ForgeReadSurfacePage(items: [], fetchedAt: ReadFixture.date(3)),
            ],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let controller = try makeController(kind: .issues, service: service)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall(count: 1)
        await settleMainActor()

        let search = try XCTUnwrap(descendant(identifier: "ForgeReadSearch", in: controller.view) as? NSSearchField)
        search.stringValue = "  regression  "
        try NSApp.sendAction(XCTUnwrap(search.action), to: search.target, from: search)
        await service.waitForListCall(count: 2)
        await settleMainActor()
        XCTAssertEqual(service.listCalls.last?.query.searchText, "regression")

        let filter = try XCTUnwrap(descendant(identifier: "ForgeReadStateFilter", in: controller.view) as? NSPopUpButton)
        filter.selectItem(withTitle: "All")
        try NSApp.sendAction(XCTUnwrap(filter.action), to: filter.target, from: filter)
        await service.waitForListCall(count: 3)
        await settleMainActor()
        XCTAssertEqual(service.listCalls.last?.query.stateFilter, .all)
    }

    func testListFailureAndPartialStalePageRemainExplicitlyVisible() async throws {
        let failing = try FakeReadService(
            pages: [],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            ),
            listError: ReadFixture.failure("Permission denied")
        )
        let failedController = try makeController(kind: .issues, service: failing)
        _ = makeWindow(failedController)
        failedController.viewDidAppear()
        await failing.waitForListCall()
        await settleMainActor()
        let failedStatus = try XCTUnwrap(
            descendant(identifier: "ForgeReadStatus", in: failedController.view) as? NSTextField
        )
        XCTAssertEqual(failedStatus.stringValue, "Couldn’t load Issues. Permission denied")
        XCTAssertFalse(failedStatus.isHidden)

        let stale = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.issue(ReadFixture.issue(number: 3))],
                fetchedAt: ReadFixture.date(1),
                isStale: true,
                isPartial: true
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let staleController = try makeController(kind: .issues, service: stale)
        _ = makeWindow(staleController)
        staleController.viewDidAppear()
        await stale.waitForListCall()
        await settleMainActor()
        let freshness = try XCTUnwrap(
            descendant(identifier: "ForgeReadFreshness", in: staleController.view) as? NSTextField
        )
        XCTAssertTrue(freshness.stringValue.contains("Stale data from"))
        XCTAssertTrue(freshness.stringValue.contains("Some fields are unavailable"))
        XCTAssertFalse(freshness.isHidden)
    }

    func testInspectorFailureStillProvidesReadOnlyBrowserEscapeHatch() async throws {
        let service = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.issue(ReadFixture.issue(number: 8))],
                fetchedAt: ReadFixture.date(1)
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            ),
            detailsError: ReadFixture.failure("Details unavailable")
        )
        let router = RecordingDestinationRouter()
        let controller = try makeController(kind: .issues, service: service, router: router)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall()
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await service.waitForDetailsCall()
        await settleMainActor()

        let error = try XCTUnwrap(descendant(identifier: "ForgeInspectorError", in: controller.view) as? NSTextField)
        XCTAssertEqual(error.stringValue, "Details unavailable")
        let browser = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorOpenInBrowser", in: controller.view) as? NSButton
        )
        browser.performClick(nil)
        XCTAssertEqual(router.browserDestinations, try [.issue(ReadFixture.repository(), ForgeItemNumber(8))])
    }

    func testInspectorLoadsAndMergesTimelineContinuationThroughInjectedService() async throws {
        let initialDetails = try ReadFixture.pullRequestDetails(
            timelineText: "First timeline page",
            timelineID: "timeline-first",
            timelineCursor: ForgePageCursor("timeline-next")
        )
        let continuedDetails = try ReadFixture.pullRequestDetails(
            timelineText: "Second timeline page",
            timelineID: "timeline-second"
        )
        let service = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.pullRequest(ReadFixture.pullRequest())],
                fetchedAt: ReadFixture.date(1)
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(initialDetails),
                fetchedAt: ReadFixture.date(2)
            ),
            continuationDetails: [ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(continuedDetails),
                fetchedAt: ReadFixture.date(3)
            )]
        )
        let markdown = RecordingMarkdownRenderer()
        let controller = try makeController(kind: .pullRequests, service: service, markdown: markdown)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall()
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await service.waitForDetailsCall()
        await settleMainActor()

        let loadMore = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorLoadMoreTimeline", in: controller.view) as? NSButton
        )
        loadMore.performClick(nil)
        await service.waitForDetailsCall(count: 2)
        await settleMainActor()

        XCTAssertEqual(service.detailsCalls.last?.timelineCursor?.value, "timeline-next")
        XCTAssertNil(service.detailsCalls.last?.checkCursor)
        XCTAssertTrue(markdown.renderedMarkdown.contains("First timeline page"))
        XCTAssertTrue(markdown.renderedMarkdown.contains("Second timeline page"))
        XCTAssertNil(descendant(identifier: "ForgeInspectorLoadMoreTimeline", in: controller.view))
    }

    func testSwitchingKindCancelsOldSurfaceStateAndLoadsNewKind() async throws {
        let service = try FakeReadService(
            pages: [
                ForgeReadSurfacePage(
                    items: [.pullRequest(ReadFixture.pullRequest())],
                    fetchedAt: ReadFixture.date(1)
                ),
                ForgeReadSurfacePage(
                    items: [.issue(ReadFixture.issue(number: 10))],
                    fetchedAt: ReadFixture.date(2)
                ),
            ],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let controller = try makeController(kind: .pullRequests, service: service)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall(count: 1)
        await settleMainActor()
        controller.show(kind: .issues)
        await service.waitForListCall(count: 2)
        await settleMainActor()

        XCTAssertEqual(service.listCalls.map(\.kind), [.pullRequests, .issues])
        let title = try XCTUnwrap(descendant(identifier: "ForgeReadListTitle", in: controller.view) as? NSTextField)
        XCTAssertEqual(title.stringValue, "Issues")
        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)
        controller.setVisibleColumns([.number, .title])
        XCTAssertFalse(try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("title"))).isHidden)
        XCTAssertTrue(try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("author"))).isHidden)
    }

    func testAttentionSurfaceLoadsCurrentUnseenNewestAndExercisesSeenControls() async throws {
        let originalState = ApplicationSettings.attentionViewState
        defer { ApplicationSettings.attentionViewState = originalState }
        ApplicationSettings.attentionViewState = ForgeAttentionViewState(
            scope: .currentRepository,
            visibility: .unseenOnly,
            sortOrder: .newestFirst
        )
        let session = try FakeAttentionSession()
        let router = RecordingDestinationRouter()
        let controller = try ForgeAttentionViewController(
            session: session,
            markdownRenderer: RecordingMarkdownRenderer(),
            avatarRenderer: RecordingAvatarRenderer(),
            destinationRouter: router,
            defaultRevision: .branch(ForgeRefName("main"))
        )
        let window = makeWindow(controller)

        controller.viewDidAppear()
        await session.waitForEntriesCall()
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeAttentionTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(session.entryStates.first?.scope, .currentRepository)
        XCTAssertEqual(session.entryStates.first?.visibility, .unseenOnly)
        XCTAssertEqual(session.entryStates.first?.sortOrder, .newestFirst)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await session.waitForMarkOpenCall()
        await session.readService.waitForDetailsCall()
        await session.waitForEntriesCall(count: 2)
        await settleMainActor()
        XCTAssertEqual(session.markedOpen, [session.entry.record.item.id])

        let markUnseen = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkUnseen", in: controller.view) as? NSButton
        )
        markUnseen.performClick(nil)
        await session.waitForMarkUnseenCall()
        await session.waitForEntriesCall(count: 3)
        XCTAssertEqual(session.markedUnseen, [session.entry.record.item.id])

        let markAll = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkAllSeen", in: controller.view) as? NSButton
        )
        markAll.performClick(nil)
        await session.waitForMarkAllCall()
        await session.waitForEntriesCall(count: 4)
        XCTAssertEqual(session.markAllStates.last?.scope, .currentRepository)

        let scope = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionScope", in: controller.view) as? NSPopUpButton
        )
        scope.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(scope.action), to: scope.target, from: scope)
        await session.waitForEntriesCall(count: 5)
        XCTAssertEqual(session.entryStates.last?.scope, .all)

        controller.open(session.entry.record.item.id)
        await session.waitForEntriesCall(count: 6)
        XCTAssertTrue(session.entryStates.contains {
            $0.scope == .all && $0.visibility == .active
        })

        try attachScreenshot(of: window, named: "GitHub Attention native inbox and inspector")
    }

    private func makeController(
        kind: ForgeReadSurfaceKind,
        service: FakeReadService,
        markdown: RecordingMarkdownRenderer = RecordingMarkdownRenderer(),
        avatars: RecordingAvatarRenderer = RecordingAvatarRenderer(),
        router: RecordingDestinationRouter = RecordingDestinationRouter()
    ) throws -> ForgeReadSurfaceViewController {
        try ForgeReadSurfaceViewController(
            kind: kind,
            defaultRevision: .branch(ForgeRefName("main")),
            service: service,
            markdownRenderer: markdown,
            avatarRenderer: avatars,
            destinationRouter: router
        )
    }

    private func makeWindow(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitHub Read Surface Harness"
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? .zero
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

    private func settleMainActor() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
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

@MainActor
private final class FakeReadService: ForgeReadSurfaceServing {
    struct ListCall {
        let kind: ForgeReadSurfaceKind
        let query: ForgeReadSurfaceQuery
        let cursor: ForgePageCursor?
    }

    struct DetailsCall {
        let item: ForgeRepositoryItem
        let timelineCursor: ForgePageCursor?
        let checkCursor: ForgePageCursor?
    }

    private var pages: [ForgeReadSurfacePage]
    private var detailsResponses: [ForgeReadSurfaceDetailsSnapshot]
    private let listError: Error?
    private let detailsError: Error?
    private var listWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var detailsWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var listCalls: [ListCall] = []
    private(set) var detailsCalls: [DetailsCall] = []

    init(
        pages: [ForgeReadSurfacePage],
        details: ForgeReadSurfaceDetailsSnapshot,
        continuationDetails: [ForgeReadSurfaceDetailsSnapshot] = [],
        listError: Error? = nil,
        detailsError: Error? = nil
    ) throws {
        self.pages = pages
        detailsResponses = [details] + continuationDetails
        self.listError = listError
        self.detailsError = detailsError
    }

    func loadItems(
        kind: ForgeReadSurfaceKind,
        query: ForgeReadSurfaceQuery,
        after cursor: ForgePageCursor?
    ) async throws -> ForgeReadSurfacePage {
        listCalls.append(ListCall(kind: kind, query: query, cursor: cursor))
        resumeListWaiters()
        if let listError {
            throw listError
        }
        guard !pages.isEmpty else { return ForgeReadSurfacePage(items: [], fetchedAt: Date()) }
        return pages.removeFirst()
    }

    func loadDetails(
        for item: ForgeRepositoryItem,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeReadSurfaceDetailsSnapshot {
        detailsCalls.append(DetailsCall(item: item, timelineCursor: timelineAfter, checkCursor: checkAfter))
        let waiters = detailsWaiters.filter { detailsCalls.count >= $0.0 }
        detailsWaiters.removeAll { detailsCalls.count >= $0.0 }
        waiters.forEach { $0.1.resume() }
        if let detailsError {
            throw detailsError
        }
        return detailsResponses.removeFirst()
    }

    func waitForListCall(count: Int = 1) async {
        guard listCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            listWaiters.append((count, continuation))
        }
    }

    func waitForDetailsCall(count: Int = 1) async {
        guard detailsCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            detailsWaiters.append((count, continuation))
        }
    }

    private func resumeListWaiters() {
        let ready = listWaiters.filter { listCalls.count >= $0.0 }
        listWaiters.removeAll { listCalls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class FakeAttentionSession: RepositoryAttentionServing {
    let account: ForgeAccount
    let repositoryIdentity: ForgeRepositoryIdentity
    let entry: ForgeAttentionInboxEntry
    let readService: FakeReadService
    var lastRefreshErrorDescription: String?
    private(set) var entryStates: [ForgeAttentionViewState] = []
    private(set) var markedOpen: [ForgeAttentionItemID] = []
    private(set) var markedUnseen: [ForgeAttentionItemID] = []
    private(set) var markAllStates: [ForgeAttentionViewState] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var markOpenWaiters: [CheckedContinuation<Void, Never>] = []
    private var markUnseenWaiters: [CheckedContinuation<Void, Never>] = []
    private var markAllWaiters: [CheckedContinuation<Void, Never>] = []

    init() throws {
        repositoryIdentity = try ReadFixture.repository()
        account = try ReadFixture.account()
        let summary = try ReadFixture.pullRequest()
        let itemID = try ForgeAttentionItemID(
            accountID: account.id,
            repository: repositoryIdentity,
            kind: .reviewRequest,
            subjectID: ForgeAttentionSubjectID("review-42")
        )
        entry = try ForgeAttentionInboxEntry(
            record: ForgeAttentionRecord(
                item: ForgeAttentionItem(
                    id: itemID,
                    destination: .pullRequest(repositoryIdentity, summary.number),
                    becameActionableAt: ReadFixture.date(4)
                ),
                sourceIdentifier: ForgeAttentionSubjectID("review-source-42"),
                sourceOccurredAt: ReadFixture.date(3)
            ),
            subject: .pullRequest(summary)
        )
        readService = try FakeReadService(
            pages: [],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(ReadFixture.pullRequestDetails()),
                fetchedAt: ReadFixture.date(5)
            )
        )
    }

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry] {
        entryStates.append(state)
        let ready = entryWaiters.filter { entryStates.count >= $0.0 }
        entryWaiters.removeAll { entryStates.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return [entry]
    }

    func markOpen(_ itemID: ForgeAttentionItemID) async throws {
        markedOpen.append(itemID)
        let waiters = markOpenWaiters
        markOpenWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markUnseen(_ itemID: ForgeAttentionItemID) async throws {
        markedUnseen.append(itemID)
        let waiters = markUnseenWaiters
        markUnseenWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markAllSeen(state: ForgeAttentionViewState) async throws {
        markAllStates.append(state)
        let waiters = markAllWaiters
        markAllWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func refreshNow() async {}

    func makeReadService(for _: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing {
        readService
    }

    func waitForEntriesCall(count: Int = 1) async {
        guard entryStates.count < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func waitForMarkOpenCall() async {
        guard markedOpen.isEmpty else { return }
        await withCheckedContinuation { markOpenWaiters.append($0) }
    }

    func waitForMarkUnseenCall() async {
        guard markedUnseen.isEmpty else { return }
        await withCheckedContinuation { markUnseenWaiters.append($0) }
    }

    func waitForMarkAllCall() async {
        guard markAllStates.isEmpty else { return }
        await withCheckedContinuation { markAllWaiters.append($0) }
    }
}

@MainActor
private final class RecordingMarkdownRenderer: ForgeReadMarkdownRendering {
    private(set) var renderedMarkdown: [String] = []

    func makeView(markdown: String, context _: ForgeMarkdownContext) -> NSView {
        renderedMarkdown.append(markdown)
        let label = NSTextField(wrappingLabelWithString: "Native Markdown")
        label.setAccessibilityLabel("Sanitized native Markdown")
        return label
    }
}

@MainActor
private final class RecordingAvatarRenderer: ForgeReadAvatarRendering {
    private(set) var displayedLogins: [String] = []

    func makeAvatarView(for actor: ForgeActor, size: NSSize) -> NSView {
        displayedLogins.append(actor.login)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: actor.login)
        return imageView
    }
}

@MainActor
private final class RecordingDestinationRouter: ForgeReadDestinationRouting {
    private(set) var nativeDestinations: [ForgeDestination] = []
    private(set) var browserDestinations: [ForgeDestination] = []

    func openNative(destination: ForgeDestination) {
        nativeDestinations.append(destination)
    }

    func openInBrowser(destination: ForgeDestination) {
        browserDestinations.append(destination)
    }
}

private enum ReadFixture {
    static func failure(_ description: String) -> NSError {
        NSError(domain: "ForgeReadSurfaceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_100_000 + seconds)
    }

    static func repository() throws -> ForgeRepositoryIdentity {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        return try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
    }

    static func account() throws -> ForgeAccount {
        let repository = try repository()
        let accountID = try ForgeAccountID(forge: repository.forge, value: "account-ui")
        return try ForgeAccount(
            id: accountID,
            login: "hbmartin",
            currentCredential: ForgeCredentialMetadata(
                reference: ForgeCredentialReference(
                    accountID: accountID,
                    credentialID: ForgeCredentialID("credential-ui"),
                    generation: ForgeCredentialGeneration(1)
                ),
                source: .fineGrainedPersonalAccessToken
            )
        )
    }

    static func actor() throws -> ForgeActor {
        let repository = try repository()
        return try ForgeActor(
            id: ForgeObjectID(forge: repository.forge, value: "actor-ari"),
            login: "ari",
            displayName: "Ari Engineer",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/42"),
            kind: .person
        )
    }

    static func label() throws -> ForgeLabel {
        let repository = try repository()
        return try ForgeLabel(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: "label-ui"),
            name: "ui",
            color: ForgeLabelColor("4477aa")
        )
    }

    static func pullRequest() throws -> ForgePullRequestSummary {
        let repository = try repository()
        return try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(42),
            state: .open,
            isDraft: false,
            title: "Native read surface",
            author: .available(.actor(actor())),
            head: .available(ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("read-surface"),
                commit: ForgeCommitID("aaaaaaa")
            )),
            base: .available(ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("main"),
                commit: ForgeCommitID("bbbbbbb")
            )),
            createdAt: date(1),
            updatedAt: date(2),
            labels: .available([label()]),
            checkRollup: .available(.succeeded),
            reviewRollup: .available(.approved)
        )
    }

    static func issue(number: Int) throws -> ForgeIssueSummary {
        try ForgeIssueSummary(
            repository: repository(),
            number: ForgeItemNumber(number),
            state: .open,
            title: "Issue \(number)",
            author: .available(.actor(actor())),
            createdAt: date(1),
            updatedAt: date(2),
            labels: .available([label()])
        )
    }

    static func pullRequestDetails(
        timelineText: String = "A timeline comment",
        timelineID: String = "timeline-comment",
        timelineCursor: ForgePageCursor? = nil
    ) throws -> ForgePullRequestDetailsPage {
        let repository = try repository()
        let timelineItem = try ForgeTimelineItem(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: timelineID),
            occurredAt: date(3),
            actor: .actor(actor()),
            event: .comment(bodyMarkdown: timelineText, updatedAt: nil)
        )
        let details = try ForgePullRequestDetails(
            summary: pullRequest(),
            bodyMarkdown: .available("## Summary\n\nNo active images: ![remote](https://example.com/a.png)"),
            assignees: .available([actor()]),
            milestone: .available(nil),
            reviewers: .available([]),
            linkedIssues: .available([]),
            mergeability: .available(.mergeable),
            checks: .available([]),
            timeline: .available(ForgePage(items: [timelineItem], nextCursor: timelineCursor))
        )
        return ForgePullRequestDetailsPage(details: details, nextCheckCursor: nil)
    }

    static func issueDetails() throws -> ForgeIssueDetails {
        try ForgeIssueDetails(
            summary: issue(number: 8),
            bodyMarkdown: .available("Issue body"),
            assignees: .available([]),
            milestone: .available(nil),
            timeline: .available(ForgePage(items: []))
        )
    }
}
