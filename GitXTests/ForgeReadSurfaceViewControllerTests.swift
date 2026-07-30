import AppKit
import ForgeKit
import UserNotifications
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

    func testReadListRendersEveryColumnRefreshesAndRoutesTheSelectedRow() async throws {
        let issue = try ReadFixture.issue(number: 17)
        let page = ForgeReadSurfacePage(
            items: [.issue(issue)],
            totalCount: 1,
            fetchedAt: ReadFixture.date(1)
        )
        let service = try FakeReadService(
            pages: [page, page],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .issue(ReadFixture.issueDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let router = RecordingDestinationRouter()
        let controller = try makeController(kind: .issues, service: service, router: router)
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall()
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)
        for column in table.tableColumns {
            let cell = table.view(atColumn: table.column(withIdentifier: column.identifier), row: 0, makeIfNecessary: true)
            XCTAssertNotNil(cell, "Every visible list column must provide an AppKit cell")
            XCTAssertFalse(cell?.accessibilityLabel()?.isEmpty ?? true)
        }
        XCTAssertFalse(table.delegate?.tableView?(table, shouldSelectRow: 1) ?? true)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await service.waitForDetailsCall()
        try NSApp.sendAction(XCTUnwrap(table.doubleAction), to: table.target, from: table)
        XCTAssertEqual(router.nativeDestinations, try [.issue(ReadFixture.repository(), issue.number)])

        let refresh = try XCTUnwrap(descendant(identifier: "ForgeReadRefresh", in: controller.view) as? NSButton)
        refresh.performClick(nil)
        await service.waitForListCall(count: 2)
        await settleMainActor()
        XCTAssertEqual(service.listCalls.count, 2)
        controller.refresh()
        await service.waitForListCall(count: 3)
        await settleMainActor()
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testInspectorRendersRichPresentationAndRoutesEveryContinuationAction() throws {
        let markdown = RecordingMarkdownRenderer()
        let avatars = RecordingAvatarRenderer()
        let router = RecordingDestinationRouter()
        let controller = try ForgeReadInspectorViewController(
            markdownRenderer: markdown,
            avatarRenderer: avatars,
            destinationRouter: router,
            defaultRevision: .branch(ForgeRefName("main"))
        )
        let item = try ForgeRepositoryItem.pullRequest(ReadFixture.pullRequest())
        let referenced = try ForgeDestination.issue(ReadFixture.repository(), ForgeItemNumber(17))
        let presentation = try ForgeReadInspectorPresentation(
            item: item,
            title: "Rich native inspector",
            subtitle: "Pull Request #42 • Open",
            author: ReadFixture.actor(),
            metadata: [
                ForgeReadInspectorMetadata(title: "Author", value: "Ari Engineer", isUnavailable: false),
                ForgeReadInspectorMetadata(title: "Checks", value: "Unavailable", isUnavailable: true),
            ],
            bodyMarkdown: "## Body",
            bodyUnavailableMessage: nil,
            timeline: [
                ForgeReadTimelinePresentation(
                    id: ForgeObjectID(forge: item.repository.forge, value: "timeline-rich"),
                    actor: "Ari Engineer",
                    occurredAt: ReadFixture.date(3),
                    summary: "referenced an issue",
                    markdown: "Timeline body",
                    destination: referenced
                ),
                ForgeReadTimelinePresentation(
                    id: ForgeObjectID(forge: item.repository.forge, value: "timeline-plain"),
                    actor: "Deleted user",
                    occurredAt: ReadFixture.date(4),
                    summary: "changed the title",
                    markdown: nil,
                    destination: nil
                ),
            ],
            timelineUnavailableMessage: nil,
            nextTimelineCursor: ForgePageCursor("timeline-next"),
            nextCheckCursor: ForgePageCursor("checks-next"),
            freshnessMessage: "Showing partial cached data"
        )
        var loadedTimeline = 0
        var loadedChecks = 0
        controller.onLoadMoreTimeline = { loadedTimeline += 1 }
        controller.onLoadMoreChecks = { loadedChecks += 1 }

        controller.apply(presentation)
        XCTAssertEqual(avatars.displayedLogins, ["ari"])
        XCTAssertEqual(markdown.renderedMarkdown, ["## Body", "Timeline body"])
        let browser = try XCTUnwrap(descendant(identifier: "ForgeInspectorOpenInBrowser", in: controller.view) as? NSButton)
        browser.performClick(nil)
        XCTAssertEqual(router.browserDestinations, [item.destination])

        let timelineButton = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorLoadMoreTimeline", in: controller.view) as? NSButton
        )
        let checksButton = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorLoadMoreChecks", in: controller.view) as? NSButton
        )
        timelineButton.performClick(nil)
        checksButton.performClick(nil)
        XCTAssertEqual(loadedTimeline, 1)
        XCTAssertEqual(loadedChecks, 1)

        let referencedButton = try XCTUnwrap(
            descendants(in: controller.view)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "View Referenced Item" }
        )
        referencedButton.performClick(nil)
        XCTAssertEqual(router.nativeDestinations, [referenced])

        controller.showContinuationLoading(.checks)
        XCTAssertFalse(timelineButton.isEnabled)
        XCTAssertFalse(checksButton.isEnabled)
        XCTAssertNotNil(descendant(identifier: "ForgeInspectorContinuationProgress", in: controller.view))
        controller.showContinuationError("The next page was unavailable")
        XCTAssertTrue(timelineButton.isEnabled)
        XCTAssertTrue(checksButton.isEnabled)
        XCTAssertNotNil(descendant(identifier: "ForgeInspectorContinuationError", in: controller.view))

        try controller.apply(ForgeReadInspectorPresentation(
            item: .issue(ReadFixture.issue(number: 18)),
            title: "No optional details",
            subtitle: "Issue #18 • Open",
            author: nil,
            metadata: [],
            bodyMarkdown: nil,
            bodyUnavailableMessage: "Body unavailable",
            timeline: [],
            timelineUnavailableMessage: "Timeline unavailable",
            nextTimelineCursor: nil,
            nextCheckCursor: nil,
            freshnessMessage: nil
        ))
        XCTAssertNotNil(descendant(identifier: "ForgeInspectorBodyUnavailable", in: controller.view))
        XCTAssertNotNil(descendant(identifier: "ForgeInspectorTimelineUnavailable", in: controller.view))
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
        await waitUntil("initial Attention entries") {
            !session.entryStates.isEmpty
        }
        await settleMainActor()

        let table = try XCTUnwrap(descendant(identifier: "ForgeAttentionTable", in: controller.view) as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(session.entryStates.first?.scope, .currentRepository)
        XCTAssertEqual(session.entryStates.first?.visibility, .unseenOnly)
        XCTAssertEqual(session.entryStates.first?.sortOrder, .newestFirst)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntil("selected Attention item to be marked open") {
            session.markedOpen == [session.entry.record.item.id]
        }
        await waitUntil("selected Attention item details") {
            !session.readService.detailsCalls.isEmpty
        }
        await settleMainActor()
        XCTAssertEqual(session.markedOpen, [session.entry.record.item.id])

        let timelineContinuation = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorLoadMoreTimeline", in: controller.view) as? NSButton
        )
        timelineContinuation.performClick(nil)
        await session.readService.waitForDetailsCall(count: 2)
        await settleMainActor()
        XCTAssertEqual(session.readService.detailsCalls.last?.timelineCursor?.value, "attention-timeline")

        session.readService.detailsError = ReadFixture.failure("Check continuation unavailable")
        let checkContinuation = try XCTUnwrap(
            descendant(identifier: "ForgeInspectorLoadMoreChecks", in: controller.view) as? NSButton
        )
        checkContinuation.performClick(nil)
        await session.readService.waitForDetailsCall(count: 3)
        await waitUntil("Attention check continuation error") {
            self.descendant(identifier: "ForgeInspectorContinuationError", in: controller.view) != nil
        }

        let markUnseen = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkUnseen", in: controller.view) as? NSButton
        )
        markUnseen.performClick(nil)
        await waitUntil("selected Attention item to be marked unseen") {
            session.markedUnseen == [session.entry.record.item.id]
        }
        XCTAssertEqual(session.markedUnseen, [session.entry.record.item.id])

        let markAll = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkAllSeen", in: controller.view) as? NSButton
        )
        markAll.performClick(nil)
        await waitUntil("visible Attention items to be marked seen") {
            session.markAllStates.last?.scope == .currentRepository
        }
        XCTAssertEqual(session.markAllStates.last?.scope, .currentRepository)

        let scope = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionScope", in: controller.view) as? NSPopUpButton
        )
        scope.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(scope.action), to: scope.target, from: scope)
        await waitUntil("all-repositories Attention scope") {
            session.entryStates.last?.scope == .all
        }
        XCTAssertEqual(session.entryStates.last?.scope, .all)

        controller.open(session.entry.record.item.id)
        await waitUntil("Attention native route to reveal active items") {
            session.entryStates.contains {
                $0.scope == .all && $0.visibility == .active
            }
        }
        XCTAssertTrue(session.entryStates.contains {
            $0.scope == .all && $0.visibility == .active
        })

        for column in table.tableColumns {
            let cell = table.view(atColumn: table.column(withIdentifier: column.identifier), row: 0, makeIfNecessary: true)
            XCTAssertNotNil(cell, "Every Attention column must provide an AppKit cell")
        }
        try NSApp.sendAction(XCTUnwrap(table.doubleAction), to: table.target, from: table)
        XCTAssertEqual(router.nativeDestinations, [session.entry.record.item.destination])

        let visibility = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionVisibility", in: controller.view) as? NSPopUpButton
        )
        visibility.selectItem(at: 0)
        try NSApp.sendAction(XCTUnwrap(visibility.action), to: visibility.target, from: visibility)
        await waitUntil("unseen Attention visibility") {
            session.entryStates.last?.visibility == .unseenOnly
        }

        let sort = try XCTUnwrap(descendant(identifier: "ForgeAttentionSort", in: controller.view) as? NSPopUpButton)
        sort.selectItem(at: 1)
        try NSApp.sendAction(XCTUnwrap(sort.action), to: sort.target, from: sort)
        await waitUntil("oldest-first Attention sort") {
            session.entryStates.last?.sortOrder == .oldestFirst
        }
        XCTAssertEqual(session.entryStates.last?.sortOrder, .oldestFirst)

        let kinds = try XCTUnwrap(descendant(identifier: "ForgeAttentionKinds", in: controller.view) as? NSPopUpButton)
        let reviewRequests = try XCTUnwrap(kinds.menu?.items.first { $0.representedObject as? String == ForgeAttentionKind.reviewRequest.rawValue })
        try NSApp.sendAction(XCTUnwrap(reviewRequests.action), to: reviewRequests.target, from: reviewRequests)
        await waitUntil("review-request Attention filter toggle") {
            session.entryStates.last?.kinds.contains(.reviewRequest) == false
        }
        XCTAssertFalse(session.entryStates.last?.kinds.contains(.reviewRequest) ?? true)

        let columns = try XCTUnwrap(descendant(identifier: "ForgeAttentionColumns", in: controller.view) as? NSPopUpButton)
        let author = try XCTUnwrap(columns.menu?.items.first { $0.representedObject as? String == ForgeAttentionColumn.author.rawValue })
        try NSApp.sendAction(XCTUnwrap(author.action), to: author.target, from: author)
        await waitUntil("Attention author column toggle") {
            session.entryStates.last?.columns.contains(.author) == false
        }
        XCTAssertFalse(session.entryStates.last?.columns.contains(.author) ?? true)

        let refresh = try XCTUnwrap(descendant(identifier: "ForgeAttentionRefresh", in: controller.view) as? NSButton)
        let entriesBeforeRefresh = session.entryStates.count
        refresh.performClick(nil)
        await waitUntil("explicit Attention refresh") {
            session.refreshCount >= 1 && session.entryStates.count > entriesBeforeRefresh
        }
        let entriesBeforeNotification = session.entryStates.count
        NotificationCenter.default.post(name: .forgeAttentionInboxDidChange, object: nil)
        await waitUntil("Attention inbox-change reload") {
            session.entryStates.count > entriesBeforeNotification
        }

        try attachScreenshot(of: window, named: "GitHub Attention native inbox and inspector")
    }

    func testAttentionNotificationActionsAndUnavailableDatabaseErrorRemainExplicit() {
        XCTAssertEqual(
            ForgeAttentionNotificationDelivery.action(for: "PBForgeAttention.Open"),
            .open
        )
        XCTAssertEqual(
            ForgeAttentionNotificationDelivery.action(for: UNNotificationDefaultActionIdentifier),
            .open
        )
        XCTAssertEqual(
            ForgeAttentionNotificationDelivery.action(for: "PBForgeAttention.MarkSeen"),
            .markSeen
        )
        XCTAssertNil(ForgeAttentionNotificationDelivery.action(for: "PBForgeAttention.Unknown"))
        XCTAssertEqual(
            RepositoryAttentionSessionError.databaseUnavailable.localizedDescription,
            "Forge data is unavailable for this session. Local Git remains available."
        )
    }

    func testAttentionSurfaceMakesCachedAndFailureStatesActionable() async throws {
        let originalState = ApplicationSettings.attentionViewState
        defer { ApplicationSettings.attentionViewState = originalState }
        ApplicationSettings.attentionViewState = ForgeAttentionViewState(
            scope: .all,
            visibility: .active,
            sortOrder: .oldestFirst,
            columns: [.title]
        )
        let session = try FakeAttentionSession()
        session.lastRefreshErrorDescription = "Network unavailable"
        session.mutationError = ReadFixture.failure("Mutation unavailable")
        let controller = try ForgeAttentionViewController(
            session: session,
            markdownRenderer: RecordingMarkdownRenderer(),
            avatarRenderer: RecordingAvatarRenderer(),
            destinationRouter: RecordingDestinationRouter(),
            defaultRevision: .branch(ForgeRefName("main"))
        )
        _ = makeWindow(controller)
        controller.viewDidAppear()
        await waitUntil("cached Attention rows") { !session.entryStates.isEmpty }
        await settleMainActor()

        let status = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionStatus", in: controller.view) as? NSTextField
        )
        XCTAssertEqual(status.stringValue, "Showing cached Attention. Network unavailable")
        controller.open(session.entry.record.item.id)
        await waitUntil("already-active Attention route reload") { session.entryStates.count >= 2 }

        let table = try XCTUnwrap(descendant(identifier: "ForgeAttentionTable", in: controller.view) as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntil("Attention inspector mutation failure") {
            self.descendant(identifier: "ForgeInspectorError", in: controller.view) != nil
        }
        let markUnseen = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkUnseen", in: controller.view) as? NSButton
        )
        markUnseen.performClick(nil)
        await waitUntil("mark-unseen failure") { status.stringValue == "Mutation unavailable" }
        let markAll = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionMarkAllSeen", in: controller.view) as? NSButton
        )
        markAll.performClick(nil)
        await waitUntil("mark-all-seen failure") { status.stringValue == "Mutation unavailable" }

        let kinds = try XCTUnwrap(descendant(identifier: "ForgeAttentionKinds", in: controller.view) as? NSPopUpButton)
        let mention = try XCTUnwrap(kinds.menu?.items.first {
            $0.representedObject as? String == ForgeAttentionKind.mention.rawValue
        })
        try NSApp.sendAction(XCTUnwrap(mention.action), to: mention.target, from: mention)
        await waitUntil("Attention kind removal") { session.entryStates.count >= 3 }
        try NSApp.sendAction(XCTUnwrap(mention.action), to: mention.target, from: mention)
        await waitUntil("Attention kind restoration") { session.entryStates.last?.kinds.contains(.mention) == true }

        let columns = try XCTUnwrap(
            descendant(identifier: "ForgeAttentionColumns", in: controller.view) as? NSPopUpButton
        )
        let title = try XCTUnwrap(columns.menu?.items.first {
            $0.representedObject as? String == ForgeAttentionColumn.title.rawValue
        })
        try NSApp.sendAction(XCTUnwrap(title.action), to: title.target, from: title)
        await waitUntil("last Attention column remains visible") {
            ApplicationSettings.attentionViewState.columns == [.title]
        }

        let invalidKind = NSMenuItem(title: "Invalid", action: nil, keyEquivalent: "")
        invalidKind.representedObject = "invalid-kind"
        _ = controller.perform(NSSelectorFromString("toggleKind:"), with: invalidKind)
        let invalidColumn = NSMenuItem(title: "Invalid", action: nil, keyEquivalent: "")
        invalidColumn.representedObject = "invalid-column"
        _ = controller.perform(NSSelectorFromString("toggleColumn:"), with: invalidColumn)
        XCTAssertNil(controller.tableView(table, viewFor: nil, row: 0))

        session.entriesError = ReadFixture.failure("Inbox unavailable")
        NotificationCenter.default.post(name: .forgeAttentionInboxDidChange, object: nil)
        await waitUntil("Attention reload failure") {
            status.stringValue == "Couldn’t load Attention. Inbox unavailable"
        }
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testPullRequestInspectorRoutesEditCheckoutAndRendersLocalChangesWithAccessibleControls() async throws {
        let summary = try ReadFixture.pullRequest()
        let service = try FakeReadService(
            pages: [ForgeReadSurfacePage(
                items: [.pullRequest(summary)],
                fetchedAt: ReadFixture.date(1)
            )],
            details: ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(ReadFixture.pullRequestDetails()),
                fetchedAt: ReadFixture.date(2)
            )
        )
        let provider = StubPullRequestChangesProvider(diff: RepositoryLocalPullRequestDiff(
            title: "Changes from main to read-surface",
            patch: "diff --git a/file b/file\n+native",
            cacheIdentifier: "local-pr-42"
        ))
        var edited: ForgePullRequestEditableSnapshot?
        var checkedOut: ForgePullRequestSummary?
        let controller = try ForgeReadSurfaceViewController(
            kind: .pullRequests,
            defaultRevision: .branch(ForgeRefName("main")),
            service: service,
            markdownRenderer: RecordingMarkdownRenderer(),
            avatarRenderer: RecordingAvatarRenderer(),
            destinationRouter: RecordingDestinationRouter(),
            pullRequestChangesProvider: provider,
            onEditPullRequest: { snapshot, _ in edited = snapshot },
            onCheckoutPullRequest: { checkedOut = $0 }
        )
        let window = makeWindow(controller)
        controller.viewDidAppear()
        await service.waitForListCall()
        await settleMainActor()
        let table = try XCTUnwrap(descendant(identifier: "ForgeReadTable", in: controller.view) as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await service.waitForDetailsCall()
        await settleMainActor()

        let edit = try XCTUnwrap(descendant(identifier: "GitX.PullRequest.Edit", in: controller.view) as? NSButton)
        let checkout = try XCTUnwrap(
            descendant(identifier: "GitX.PullRequest.Checkout", in: controller.view) as? NSButton
        )
        edit.performClick(nil)
        checkout.performClick(nil)
        XCTAssertEqual(edited?.number, summary.number)
        XCTAssertEqual(checkedOut?.number, summary.number)

        let mode = try XCTUnwrap(
            descendant(identifier: "GitX.PullRequest.InspectorMode", in: controller.view) as? NSSegmentedControl
        )
        mode.selectedSegment = 1
        try NSApp.sendAction(XCTUnwrap(mode.action), to: mode.target, from: mode)
        await settleMainActor()
        let changes = try XCTUnwrap(descendant(identifier: "GitX.PullRequest.LocalChanges", in: controller.view))
        XCTAssertEqual(changes.accessibilityIdentifier(), "GitX.PullRequest.LocalChanges")
        try attachScreenshot(of: window, named: "GitHub Pull Request local Changes inspector")
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

    private func descendants(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(in: $0) }
    }

    private func settleMainActor() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
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
            try? await Task.sleep(nanoseconds: 10_000_000)
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

private struct StubPullRequestChangesProvider: RepositoryPullRequestChangesProviding {
    let diff: RepositoryLocalPullRequestDiff

    func changes(
        repository _: ForgeRepositoryIdentity,
        base _: ForgeBranchReference,
        head _: ForgeBranchReference
    ) async throws -> RepositoryLocalPullRequestDiff {
        diff
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
    var detailsError: Error?
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
        guard detailsResponses.count > 1 else {
            return detailsResponses[0]
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
    var entriesError: Error?
    var mutationError: Error?
    private(set) var entryStates: [ForgeAttentionViewState] = []
    private(set) var markedOpen: [ForgeAttentionItemID] = []
    private(set) var markedUnseen: [ForgeAttentionItemID] = []
    private(set) var markAllStates: [ForgeAttentionViewState] = []
    private(set) var refreshCount = 0

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
        let details = try ForgeReadSurfaceDetailsSnapshot(
            details: .pullRequest(ReadFixture.pullRequestDetails(
                timelineID: "attention-initial",
                timelineCursor: ForgePageCursor("attention-timeline"),
                checkCursor: ForgePageCursor("attention-checks")
            )),
            fetchedAt: ReadFixture.date(5)
        )
        let timelineContinuation = try ForgeReadSurfaceDetailsSnapshot(
            details: .pullRequest(ReadFixture.pullRequestDetails(
                timelineID: "attention-next"
            )),
            fetchedAt: ReadFixture.date(6)
        )
        let checkContinuation = try ForgeReadSurfaceDetailsSnapshot(
            details: .pullRequest(ReadFixture.pullRequestDetails(
                timelineID: "attention-check-page"
            )),
            fetchedAt: ReadFixture.date(7)
        )
        readService = try FakeReadService(
            pages: [],
            details: details,
            continuationDetails: [timelineContinuation, checkContinuation]
        )
    }

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry] {
        entryStates.append(state)
        if let entriesError {
            throw entriesError
        }
        return [entry]
    }

    func markOpen(_ itemID: ForgeAttentionItemID) async throws {
        markedOpen.append(itemID)
        if let mutationError {
            throw mutationError
        }
    }

    func markUnseen(_ itemID: ForgeAttentionItemID) async throws {
        markedUnseen.append(itemID)
        if let mutationError {
            throw mutationError
        }
    }

    func markAllSeen(state: ForgeAttentionViewState) async throws {
        markAllStates.append(state)
        if let mutationError {
            throw mutationError
        }
    }

    func refreshNow() async {
        refreshCount += 1
    }

    func makeReadService(for _: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing {
        readService
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
        timelineCursor: ForgePageCursor? = nil,
        checkCursor: ForgePageCursor? = nil
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
        return ForgePullRequestDetailsPage(details: details, nextCheckCursor: checkCursor)
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
