import ForgeKit
@testable import GitX
import Synchronization
import XCTest

@MainActor
private final class RemoteRoutingRecorder: NSResponder {
    private(set) var addRemoteRequests = 0

    @objc func addRemote(_ sender: Any?) {
        addRemoteRequests += 1
    }
}

/// Reach Swift-only navigation through the app module without expanding production selectors.
@MainActor
enum SidebarLifecycleTestSupport {
    static func assertSortAndRemoteRouting(repository: NSObject, afterClose: Bool) throws {
        let repository = try XCTUnwrap(repository as? GitX.PBGitRepository)
        let originalComposition = GitX.ApplicationComposition.shared
        let suite = "GitXTests.SidebarActions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        GitX.ApplicationComposition.setSharedComposition(GitX.ApplicationComposition(
            userDefaults: defaults, automaticallyStartsForgeServices: false
        ))
        defer {
            GitX.ApplicationComposition.setSharedComposition(originalComposition)
            defaults.removePersistentDomain(forName: suite)
        }
        GitX.ApplicationSettings.branchSort = .alphabetical
        let sidebar = try XCTUnwrap(PBGitSidebarController(repository: repository, superController: nil))
        _ = sidebar.view
        let recorder = RemoteRoutingRecorder()
        XCTAssertTrue(recorder.responds(to: #selector(RemoteRoutingRecorder.addRemote(_:))))
        let previousResponder = sidebar.nextResponder
        sidebar.nextResponder = recorder
        defer { sidebar.nextResponder = previousResponder }
        defer { sidebar.closeView() }
        let notifications = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("PBBranchSidebarSettingsDidChangeNotification"), object: nil, queue: nil
        ) { _ in notifications.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        if afterClose {
            sidebar.closeView()
        }

        sidebar.toggleBranchSort(sidebar)
        let presentation = try XCTUnwrap(sidebar.value(forKey: "branchPresentation") as? GitX.BranchSidebarPresentation)
        XCTAssertEqual(presentation.usesRecentSorting, !afterClose)
        XCTAssertEqual(GitX.ApplicationSettings.branchSort, afterClose ? .alphabetical : .recentCommit)
        XCTAssertEqual(defaults.integer(forKey: "PBBranchSortMode"), GitX.ApplicationSettings.branchSort.rawValue)
        XCTAssertEqual(notifications.withLock { $0 }, afterClose ? 0 : 1)
        sidebar.fetchPullPushAction(nil)
        XCTAssertEqual(recorder.addRemoteRequests, afterClose ? 0 : 1)
    }

    static func assertClosedNavigationIsInert(_ owner: NSObject) throws {
        let sidebar = try XCTUnwrap(owner as? GitX.PBGitSidebarController)
        XCTAssertFalse(sidebar.browseSelectedWorktreeHistory())
        let outline = try XCTUnwrap(sidebar.sourceView)
        if let item = sidebar.selectedItem() {
            XCTAssertNil(sidebar.outlineView(outline, viewFor: nil, item: item))
            XCTAssertFalse(sidebar.outlineView(outline, shouldSelectItem: item))
        }
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "fixture", name: "closed-sidebar")
        #if DEBUG
            var attempts = 0
            sidebar.productProofForgeDestinationOpening = { _ in attempts += 1; return true }
            defer { sidebar.productProofForgeDestinationOpening = nil }
        #endif
        XCTAssertFalse(sidebar.openForgeDestination(.repository(repository)))
        #if DEBUG
            XCTAssertEqual(attempts, 0)
        #endif
    }
}
