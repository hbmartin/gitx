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
