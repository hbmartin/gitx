import AppKit
@testable import GitX
import XCTest

/// A viewed reference that disappears during a passive reload falls back to the checked-out branch.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every window, sheet and fixture stays on main.
final class SidebarSelectionFallbackTests: XCTestCase, @unchecked Sendable {
    private var announcements: [String] = []
    private var restoreAnnouncer: ((String, Any) -> Void)?

    override nonisolated func setUp() {
        super.setUp()
        // swift6-safety-justification: XCTest invokes this synchronous fixture setup on the main thread.
        MainActor.assumeIsolated { observeAnnouncements() }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCTest invokes this synchronous fixture teardown on the main thread.
        MainActor.assumeIsolated { restoreAnnouncements() }
        super.tearDown()
    }

    private func observeAnnouncements() {
        announcements = []
        restoreAnnouncer = AccessibilityAnnouncer.post
        AccessibilityAnnouncer.post = { [weak self] message, _ in self?.announcements.append(message) }
    }

    private func restoreAnnouncements() {
        if let restoreAnnouncer {
            AccessibilityAnnouncer.post = restoreAnnouncer
        }
        restoreAnnouncer = nil
    }

    func testDeletedViewedBranchFallsBackToTheCheckedOutBranchAndAnnouncesIt() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["branch", "topic"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        await waitUntil { repository.branches.contains { $0.simpleRef() == "refs/heads/topic" } }
        let topic = try XCTUnwrap(repository.branches.first { $0.simpleRef() == "refs/heads/topic" })
        repository.currentBranch = topic
        sidebar.selectCurrentBranch()
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/topic")
        let mountedContent = owner.value(forKey: "contentController") as AnyObject?

        try fixture.git(["branch", "-D", "topic"])
        repository.reloadRefs()
        await waitUntil { repository.currentBranch?.simpleRef() == "refs/heads/main" }

        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(announcements, ["topic no longer exists. Showing main."])
        XCTAssertTrue(owner.value(forKey: "contentController") as AnyObject? === mountedContent)
        try attachScreenshot(of: XCTUnwrap(owner.window), named: "Sidebar-Fallback-To-Checked-Out-Branch")
    }

    func testSurvivingViewedBranchKeepsItsSelectionWithoutAnnouncing() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["branch", "topic"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        await waitUntil { repository.branches.contains { $0.simpleRef() == "refs/heads/topic" } }
        let topic = try XCTUnwrap(repository.branches.first { $0.simpleRef() == "refs/heads/topic" })
        repository.currentBranch = topic
        sidebar.selectCurrentBranch()

        try fixture.git(["branch", "other"])
        repository.reloadRefs()
        await waitUntil { repository.branches.contains { $0.simpleRef() == "refs/heads/other" } }
        sidebar.reloadSidebarAfterReferencesChange()

        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/topic")
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/topic")
        XCTAssertEqual(announcements, [])
    }

    func testDetachedHeadIsShownWhenTheViewedBranchDisappears() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["branch", "topic"])
        try fixture.git(["checkout", "--quiet", "--detach"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        await waitUntil { repository.branches.contains { $0.simpleRef() == "refs/heads/topic" } }
        let topic = try XCTUnwrap(repository.branches.first { $0.simpleRef() == "refs/heads/topic" })
        repository.currentBranch = topic
        sidebar.selectCurrentBranch()

        try fixture.git(["branch", "-D", "topic"])
        repository.reloadRefs()
        await waitUntil { repository.currentBranch?.simpleRef() == "HEAD" }

        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "HEAD")
        XCTAssertEqual(announcements, ["topic no longer exists. Showing HEAD."])
    }

    func testViewedReferenceWithoutACheckedOutReferenceLeavesTheSidebarUnchanged() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        await waitUntil { repository.branches.contains { $0.simpleRef() == "refs/heads/main" } }
        sidebar.selectCurrentBranch()
        let viewed = repository.currentBranch
        let missing = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/deleted-elsewhere"))

        sidebar.fallBackIfViewedReferenceDisappeared(restored: false, viewedRevision: missing, checkedOut: nil)

        XCTAssertTrue(repository.currentBranch === viewed)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(announcements, [])
    }

    func testFailedForgeBindingSaveShowsTheErrorAndKeepsTheChoice() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["remote", "add", "fork", "https://github.com/hbmartin/gitx.git"])
        try fixture.git(["remote", "add", "upstream", "https://github.com/gitx/gitx.git"])
        let originalSave = GitX.PBGitSidebarController.saveForgeBinding
        GitX.PBGitSidebarController.saveForgeBinding = { _, _ in
            throw NSError(domain: "GitXTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The binding could not be saved."])
        }
        defer { GitX.PBGitSidebarController.saveForgeBinding = originalSave }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let window = try XCTUnwrap(owner.window)
        let outline = try XCTUnwrap(owner.sidebarViewController?.sourceView)
        let choiceTitle = "Choose Primary Repository…"
        await waitUntil { self.row(titled: choiceTitle, in: outline) != nil }

        try outline.selectRowIndexes(IndexSet(integer: XCTUnwrap(row(titled: choiceTitle, in: outline))), byExtendingSelection: false)
        await waitUntil { self.sheet(in: window, containing: "Use Repository") != nil }
        try window.endSheet(XCTUnwrap(sheet(in: window, containing: "Use Repository")), returnCode: .alertFirstButtonReturn)
        await waitUntil { self.sheet(in: window, containing: "The binding could not be saved.") != nil }
        let failure = try XCTUnwrap(sheet(in: window, containing: "The binding could not be saved."))

        try attachScreenshot(of: failure, named: "Forge-Binding-Save-Failure")
        XCTAssertEqual(GitX.RepositoryForgeCoordinator(repository: repository).resolveBinding().kind, .requiresChoice)
        XCTAssertNotNil(row(titled: choiceTitle, in: outline))
        window.endSheet(failure, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet == nil }
    }

    private func row(titled title: String, in outline: NSOutlineView) -> Int? {
        (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? PBSourceViewItem)?.title == title }
    }

    private func sheet(in window: NSWindow, containing text: String) -> NSWindow? {
        guard let sheet = window.attachedSheet, texts(in: sheet.contentView).contains(text) else { return nil }
        return sheet
    }

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue
        return (own.map { [$0] } ?? []) + view.subviews.flatMap(texts(in:))
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the sidebar condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
