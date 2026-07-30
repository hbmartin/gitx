import AppKit
import ForgeKit
import XCTest

@MainActor
final class HistoryForgeOverlayPresentationTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 2_000_000)

    func testCheckRollupPresentsEveryProviderNeutralState() throws {
        let cases: [(ForgeCheckRollup, String, String)] = [
            (.succeeded, "✓ Passed", "Check Rollup succeeded"),
            (.failed, "✕ Failed", "Check Rollup failed"),
            (.running, "● Running", "Check Rollup running"),
            (.attentionRequired, "! Attention", "Check Rollup needs attention"),
            (.neutral, "— Neutral", "Check Rollup neutral"),
        ]

        for (rollup, text, accessibility) in cases {
            let presentation = try HistoryForgeBadgePresenter.present(.value(snapshot(
                checkRollup: .available(rollup),
                pullRequests: .available(ForgePage(items: []))
            )))
            XCTAssertEqual(presentation.checkText, text)
            XCTAssertEqual(presentation.checkAccessibilityLabel, accessibility)
            XCTAssertFalse(presentation.isLoading)
        }
    }

    func testBadgesDistinguishInitialLoadingUnavailableEmptyAndCachedLoading() throws {
        let initial = HistoryForgeBadgePresenter.present(.loading(previous: nil))
        XCTAssertEqual(initial.checkText, "…")
        XCTAssertEqual(initial.pullRequestText, "…")
        XCTAssertTrue(initial.isLoading)

        let unavailable = HistoryForgeBadgePresenter.present(.unavailable(.authenticationRequired))
        XCTAssertEqual(unavailable, HistoryForgeBadgePresenter.unavailable)

        let cached = try snapshot(
            checkRollup: .available(.failed),
            pullRequests: .available(ForgePage(items: []))
        )
        let refreshing = HistoryForgeBadgePresenter.present(.loading(previous: cached))
        XCTAssertEqual(refreshing.checkText, "✕ Failed")
        XCTAssertEqual(refreshing.pullRequestText, "—")
        XCTAssertTrue(refreshing.isLoading)
    }

    func testPullRequestBadgeSortsNumbersAndUsesProviderTotalCount() throws {
        let page = try ForgePage(items: [pullRequest(number: 41), pullRequest(number: 7)], totalCount: 4)
        let presentation = HistoryForgeBadgePresenter.present(.value(snapshot(
            checkRollup: .unavailable(.permissionDenied),
            pullRequests: .available(page)
        )))

        XCTAssertEqual(presentation.checkText, "—")
        XCTAssertEqual(presentation.pullRequestText, "#7 +3")
        XCTAssertEqual(
            presentation.pullRequestAccessibilityLabel,
            "4 associated Pull Requests, beginning with number 7"
        )
    }

    func testRepositoryFactsPresentCompletePartialStaleAndUnavailableSections() throws {
        let facts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(ForgeRefName("main")),
            description: .available("Native GitHub integration"),
            topics: .available(["macos", "git"]),
            visibility: .available(.public),
            isArchived: .available(false),
            forkRelationship: .available(.standalone)
        )
        let current = RepositoryFactsPresenter.present(.value(RepositoryForgeOverlaySnapshot(
            value: facts,
            fetchedAt: fetchedAt,
            isPartial: false,
            isStale: false
        )))
        XCTAssertEqual(current.subtitle, "hbmartin/gitx")
        XCTAssertEqual(current.rows.map(\.value), [
            "main", "Native GitHub integration", "macos, git", "Public", "Active", "Standalone",
        ])
        XCTAssertFalse(current.isLoading)

        let degraded = RepositoryFactsPresenter.present(.loading(previous: RepositoryForgeOverlaySnapshot(
            value: facts,
            fetchedAt: fetchedAt,
            isPartial: true,
            isStale: true
        )))
        XCTAssertEqual(degraded.subtitle, "Stale cached data · Partial response · Refreshing")
        XCTAssertTrue(degraded.isLoading)

        let unavailableFacts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .unavailable(.permissionDenied),
            description: .available(nil),
            topics: .available([]),
            visibility: .unavailable(.partialResponse),
            isArchived: .available(true),
            forkRelationship: .unavailable(.notRequested)
        )
        let unavailableRows = RepositoryFactsPresenter.present(.value(RepositoryForgeOverlaySnapshot(
            value: unavailableFacts,
            fetchedAt: fetchedAt,
            isPartial: true,
            isStale: false
        )))
        XCTAssertEqual(unavailableRows.rows.map(\.value), [
            "Unavailable", "None", "None", "Unavailable", "Archived", "Unavailable",
        ])
    }

    func testRepositoryFactsUnavailableReasonsRemainActionable() {
        let cases: [(ForgeReadUnavailableReason, String)] = [
            (.authenticationRequired, "Sign in and choose an Account"),
            (.unsupported, "Native facts are unavailable"),
            (.permissionDenied, "Repository access is required"),
            (.notRequested, "Waiting for Forge data"),
            (.partialResponse, "Repository facts are unavailable"),
        ]
        for (reason, subtitle) in cases {
            let presentation = RepositoryFactsPresenter.present(
                RepositoryForgeOverlayValueState<ForgeRepositoryFacts>.unavailable(reason)
            )
            XCTAssertEqual(presentation.subtitle, subtitle)
            XCTAssertTrue(presentation.rows.isEmpty)
            XCTAssertFalse(presentation.isLoading)
        }
    }

    func testRepositoryFactsInspectorDiagnosticScreenshot() throws {
        let facts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(ForgeRefName("main")),
            description: .available("Native GitHub integration for GitX"),
            topics: .available(["macos", "git", "appkit"]),
            visibility: .available(.public),
            isArchived: .available(false),
            forkRelationship: .available(.standalone)
        )
        let view = RepositoryFactsInspectorView(frame: NSRect(x: 0, y: 0, width: 258, height: 360))
        view.setExpanded(true)
        view.apply(RepositoryFactsPresenter.present(.loading(previous: RepositoryForgeOverlaySnapshot(
            value: facts,
            fetchedAt: fetchedAt,
            isPartial: true,
            isStale: true
        ))))
        try attachScreenshot(
            of: view,
            named: "Milestone 1 - History Repository Facts Inspector - Partial Refresh"
        )
    }

    func testCollapsedRepositoryFactsInspectorHasValidLayoutAndPersistsExpansion() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let history = NSSplitView()
        history.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(history)
        NSLayoutConstraint.activate([
            history.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            history.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            history.topAnchor.constraint(equalTo: root.topAnchor),
            history.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        var persistedVisibility: Bool?
        let controller = RepositoryFactsInspectorController(isExpanded: false) {
            persistedVisibility = $0
        }

        controller.install(in: root)
        root.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(root.subviews.compactMap { $0 as? RepositoryFactsInspectorView }.first)
        XCTAssertEqual(panel.frame.width, 34)
        XCTAssertFalse(panel.hasAmbiguousLayout)

        panel.collapseButton.performClick(nil)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(persistedVisibility, true)
        XCTAssertEqual(panel.frame.width, 258)
        XCTAssertFalse(panel.hasAmbiguousLayout)
    }

    private var repository: ForgeRepositoryIdentity {
        try! ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private var commit: ForgeCommitID {
        try! ForgeCommitID("0123456789abcdef0123456789abcdef01234567")
    }

    private func snapshot(
        checkRollup: ForgeReadSection<ForgeCheckRollup>,
        pullRequests: ForgeReadSection<ForgePage<ForgePullRequestSummary>>
    ) -> RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay> {
        RepositoryForgeOverlaySnapshot(
            value: ForgeHistoryOverlay(
                repository: repository,
                commit: commit,
                checkRollup: checkRollup,
                pullRequests: pullRequests
            ),
            fetchedAt: fetchedAt,
            isPartial: false,
            isStale: false
        )
    }

    private func pullRequest(number: Int) throws -> ForgePullRequestSummary {
        try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(number),
            state: .open,
            isDraft: false,
            title: "Pull Request \(number)",
            author: .unavailable(.notRequested),
            head: .unavailable(.notRequested),
            base: .unavailable(.notRequested),
            createdAt: fetchedAt,
            updatedAt: fetchedAt,
            labels: .unavailable(.notRequested),
            checkRollup: .unavailable(.notRequested),
            reviewRollup: .unavailable(.notRequested)
        )
    }

    private func attachScreenshot(of view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let screenshot = NSImage(size: view.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
