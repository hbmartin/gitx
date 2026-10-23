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
    static func assertSortAndRemoteRouting(
        repository: NSObject,
        afterClose: Bool,
        alphabeticalReferences: [String],
        recentReferences: [String]
    ) throws {
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
        defer { sidebar.closeView() }
        _ = sidebar.view
        let outline = try XCTUnwrap(sidebar.sourceView)
        let branches = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "BRANCHES" })
        outline.expandItem(branches)
        let requested = try XCTUnwrap(branches.sortedChildren.first { $0.revSpecifier?.simpleRef() == alphabeticalReferences.first })
        let row = outline.row(forItem: requested)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Selection publishes the revision and may rebuild the sidebar synchronously.
        let currentBranches = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "BRANCHES" })
        let retainedRows = currentBranches.sortedChildren
        let selected = try XCTUnwrap(sidebar.selectedItem())
        XCTAssertEqual(selected.revSpecifier?.simpleRef(), alphabeticalReferences.first)
        let revision = repository.currentBranch
        func displayedReferences() throws -> [String] {
            let currentBranches = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "BRANCHES" })
            return sidebar.visibleChildren(for: currentBranches).compactMap { $0.revSpecifier?.simpleRef() }
                .filter { alphabeticalReferences.contains($0) }
        }
        XCTAssertNotEqual(alphabeticalReferences, recentReferences, "The fixture must distinguish sorting policies")
        XCTAssertEqual(try displayedReferences(), alphabeticalReferences)
        let recorder = RemoteRoutingRecorder()
        XCTAssertTrue(recorder.responds(to: #selector(RemoteRoutingRecorder.addRemote(_:))))
        let previousResponder = sidebar.nextResponder
        sidebar.nextResponder = recorder
        defer { sidebar.nextResponder = previousResponder }
        let notifications = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("PBBranchSidebarSettingsDidChangeNotification"), object: nil, queue: nil
        ) { _ in notifications.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let remoteControls = try XCTUnwrap(sidebar.value(forKey: "remoteControls") as? NSSegmentedControl)
        XCTAssertTrue(remoteControls.target === sidebar)
        XCTAssertNotNil(remoteControls.action)
        let extraControls: [NSControl] = [NSButton(), NSButton()]
        for control in extraControls {
            control.target = sidebar
            control.action = NSSelectorFromString("toggleBranchSort:")
            control.isHidden = true
        }
        sidebar.view.addSubview(extraControls[0])
        try XCTUnwrap(sidebar.sourceListControlsView).addSubview(extraControls[1])
        if afterClose {
            sidebar.closeView()
            for control in extraControls + [remoteControls] {
                XCTAssertNil(control.target)
                XCTAssertNil(control.action)
                XCTAssertFalse(control.isEnabled)
            }
        }

        sidebar.toggleBranchSort(sidebar)
        let presentation = try XCTUnwrap(sidebar.value(forKey: "branchPresentation") as? GitX.BranchSidebarPresentation)
        XCTAssertEqual(presentation.usesRecentSorting, !afterClose)
        XCTAssertEqual(GitX.ApplicationSettings.branchSort, afterClose ? .alphabetical : .recentCommit)
        XCTAssertEqual(defaults.integer(forKey: "PBBranchSortMode"), GitX.ApplicationSettings.branchSort.rawValue)
        XCTAssertEqual(notifications.withLock { $0 }, afterClose ? 0 : 1)
        XCTAssertEqual(try displayedReferences(), afterClose ? alphabeticalReferences : recentReferences)
        XCTAssertTrue(repository.currentBranch === revision)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), selected.revSpecifier?.simpleRef())
        if afterClose {
            XCTAssertEqual(currentBranches.sortedChildren.map(ObjectIdentifier.init), retainedRows.map(ObjectIdentifier.init))
            XCTAssertTrue(sidebar.selectedItem() === selected)
        }
        // Outside a momentary mouse-tracking event AppKit reports -1 even after
        // selectedSegment is assigned. Model the clicked state for this programmatic
        // dispatch, then restore the nib's actual momentary behavior.
        let trackingMode = remoteControls.trackingMode
        XCTAssertEqual(trackingMode, .momentary)
        remoteControls.trackingMode = .selectOne
        defer { remoteControls.trackingMode = trackingMode }
        remoteControls.selectedSegment = 0
        XCTAssertEqual(remoteControls.selectedSegment, 0)
        XCTAssertEqual(remoteControls.isEnabled, !afterClose)
        // A closed direct invocation must be refused even with a valid recipient.
        sidebar.nextResponder = recorder
        XCTAssertTrue(sidebar.nextResponder === recorder)
        if afterClose {
            sidebar.fetchPullPushAction(remoteControls)
        } else {
            XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(remoteControls.action), to: remoteControls.target, from: remoteControls))
        }
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
