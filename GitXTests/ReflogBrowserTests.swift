import AppKit
@testable import GitX
import GitXCore
import XCTest

@MainActor
final class ReflogBrowserTests: XCTestCase {
    func testClosingAndReleasingBrowserLetsAnAdmittedHardResetFinish() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "second\n")
        try fixture.git(["commit", "-am", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
        defer { try? gate.open() }
        var controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: gate.context)
        })) as ReflogBrowserController?
        weak let released = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller?.closeView(); window.close() }
        window.contentView = try XCTUnwrap(controller).view
        window.makeKeyAndOrderFront(nil)
        controller?.updateView()
        try await waitUntilIdle(XCTUnwrap(controller))
        try control("Events", in: XCTUnwrap(controller), as: NSTableView.self).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntilIdle(XCTUnwrap(controller))
        _ = try await preview(.hard, browser: (controller: XCTUnwrap(controller), window: window, repository: repository))
        try dismissSheet(window, response: .alertFirstButtonReturn)
        await waitUntil { self.sheetButton("Discard Changes and Reset", window: window) != nil }
        try dismissSheet(window, response: .alertSecondButtonReturn)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let admitted = try XCTUnwrap(controller?.operation)
        controller?.closeView()
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        controller = nil
        try gate.open()
        await admitted.value
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "initial\n")
        await waitUntil { released == nil }
        XCTAssertNil(released)
    }

    func testUnsafeResetDisplaysTheObservedHeadAndValidatedBackup() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["commit", "--allow-empty", "-m", "validated preview"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
        defer { try? gate.open() }
        let browser = try await presentedBrowser(fixture, row: 1, serviceFactory: { try RepositoryReflogService(repository: $0, context: gate.context) })
        defer { browser.controller.closeView(); browser.window.close() }
        _ = try await preview(.soft, browser: browser)
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        try fixture.git(["commit", "--allow-empty", "-m", "external writer"])
        let observed = try fixture.git(["rev-parse", "HEAD"])
        try gate.open()
        await waitUntilIdle(browser.controller)
        let message = try control("Details", in: browser.controller, as: NSTextView.self).string
        XCTAssertTrue(message.contains(previous))
        XCTAssertTrue(message.contains(observed))
        XCTAssertTrue(message.contains("validated commit only"))
        XCTAssertTrue(message.contains("recovery/"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
        try attachScreenshot(of: browser.window, named: "Unsafe reset identifies observed HEAD and retained validated backup")
    }

    func testNativeBrowserLoadsUnreachableDetailsAndCopiesPinnedCommit() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "replacement\n")
        try fixture.git(["commit", "--amend", "-am", "replacement"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        defer { controller.closeView() }
        _ = controller.view
        controller.updateView()
        await waitUntilIdle(controller)
        let table = try control("Events", in: controller, as: NSTableView.self)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(try control("Reference", in: controller, as: NSPopUpButton.self).numberOfItems, 2)
        XCTAssertTrue(try control("Status", in: controller, as: NSTextField.self).stringValue.contains("2 events"))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await waitUntilIdle(controller)
        let details = try control("Details", in: controller, as: NSTextView.self)
        XCTAssertTrue(details.string.contains("initial"))
        XCTAssertTrue(details.string.contains(original))
        let copy = try control("Copy", in: controller, as: NSButton.self)
        copy.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), original)
        try control("Compare", in: controller, as: NSButton.self).performClick(nil)
        await waitUntilIdle(controller)
        XCTAssertTrue(details.string.contains("tracked.txt"))
        XCTAssertTrue(details.string.contains("replacement"))
        XCTAssertTrue(controller.firstResponder() === table)
    }

    func testClosingBrowserRevokesControlsAndDiscardsLateLoads() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        _ = controller.view
        controller.updateView()
        controller.closeView()
        controller.closeView()
        for identifier in ["Reference", "Refresh", "LoadMore", "Cancel", "Copy", "Compare", "CreateBranch", "Reset"] {
            let control = try control(identifier, in: controller, as: NSControl.self)
            XCTAssertFalse(control.isEnabled)
            XCTAssertNil(control.target)
        }
        XCTAssertNil(try control("Events", in: controller, as: NSTableView.self).delegate)
        controller.refresh(nil)
        XCTAssertEqual(try control("Events", in: controller, as: NSTableView.self).numberOfRows, 0)
    }

    func testEmptyReflogExplainsRetentionAndDisablesRecovery() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["reflog", "expire", "--expire=all", "--all"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        defer { controller.closeView() }
        _ = controller.view
        controller.updateView()
        await waitUntilIdle(controller)
        XCTAssertTrue(try control("Status", in: controller, as: NSTextField.self).stringValue.contains("no retained events"))
        XCTAssertFalse(try control("Reset", in: controller, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("LoadMore", in: controller, as: NSButton.self).isEnabled)
    }

    func testRecoveryBranchSheetUsesCapturedCommitAndRejectsClosedOwner() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        let browser = try await presentedBrowser(fixture)
        defer { browser.controller.closeView(); browser.window.close() }
        try control("CreateBranch", in: browser.controller, as: NSButton.self).performClick(nil)
        let name = try sheetControl("BranchName", window: browser.window, as: NSTextField.self)
        name.stringValue = "recovery/from-sheet"
        // A new reflog event must not redirect the captured selection.
        try fixture.git(["commit", "--allow-empty", "-m", "new HEAD"])
        let current = try fixture.git(["rev-parse", "HEAD"])
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { !browser.controller.isBusy && (try? self.control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Created recovery/from-sheet.")) == true }
        await waitUntilIdle(browser.controller)
        XCTAssertEqual(try fixture.git(["rev-parse", "recovery/from-sheet"]), original)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), current)
        XCTAssertTrue(try control("Reference", in: browser.controller, as: NSPopUpButton.self).itemTitles.contains("recovery/from-sheet"))
        XCTAssertEqual(try control("Events", in: browser.controller, as: NSTableView.self).numberOfRows, 2)
        try control("CreateBranch", in: browser.controller, as: NSButton.self).performClick(nil)
        try sheetControl("BranchName", window: browser.window, as: NSTextField.self).stringValue = "recovery/closed-owner"
        browser.controller.closeView()
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { browser.window.attachedSheet == nil }
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/closed-owner"]), "")
    }

    func testEveryResetModeFlowsThroughPreviewAndPreservesBackup() async throws {
        for mode in ReflogResetMode.allCases {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let target = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "second\n")
            try fixture.git(["commit", "-am", "second"])
            let previous = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "staged\n")
            try fixture.git(["add", "tracked.txt"])
            try fixture.write("tracked.txt", "working\n")
            let browser = try await presentedBrowser(fixture, row: 1)
            defer { browser.controller.closeView(); browser.window.close() }
            let paths = try await preview(mode, browser: browser)
            XCTAssertTrue(paths.string.contains("tracked.txt"))
            try dismissSheet(browser.window, response: .alertFirstButtonReturn)
            if mode == .hard {
                await waitUntil { self.sheetButton("Discard Changes and Reset", window: browser.window) != nil }
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
                try dismissSheet(browser.window, response: .alertSecondButtonReturn)
            }
            await waitUntil { !browser.controller.isBusy && (try? self.control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Reset complete.")) == true }
            await waitUntilIdle(browser.controller)
            XCTAssertTrue(try control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Reset complete."))
            XCTAssertEqual(try control("Events", in: browser.controller, as: NSTableView.self).numberOfRows, 3)
            XCTAssertTrue(try control("Reference", in: browser.controller, as: NSPopUpButton.self).itemTitles.contains { $0.hasPrefix("recovery/") })
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
            XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
            XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), mode == .soft ? "staged" : "initial")
            XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), mode == .hard ? "initial\n" : "working\n")
        }
    }

    func testDiscardCancellationAndChangedPreviewNeverReset() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["commit", "--allow-empty", "-m", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "keep\n")
        let browser = try await presentedBrowser(fixture, row: 1)
        defer { browser.controller.closeView(); browser.window.close() }
        _ = try await preview(.hard, browser: browser)
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { self.sheetButton("Discard Changes and Reset", window: browser.window) != nil }
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { browser.window.attachedSheet == nil }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "keep\n")
        _ = try await preview(.mixed, browser: browser)
        try fixture.write("tracked.txt", "changed during confirmation\n")
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { browser.controller.status?.contains("changed") == true }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]), "")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "changed during confirmation\n")
    }

    func testSidebarAndViewMenuRetainReflogAcrossPassiveRepositoryRefreshes() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        owner.showReflog(nil)
        let browser = try XCTUnwrap(owner.value(forKey: "contentController") as? ReflogBrowserController)
        await waitUntilIdle(browser)
        XCTAssertTrue(sidebar.isReflogSelected)
        let item = try XCTUnwrap(sidebar.selectedItem())
        let outline = try XCTUnwrap(sidebar.sourceView)
        XCTAssertTrue(sidebar.outlineView(outline, shouldSelectItem: item))
        XCTAssertEqual(sidebar.outlineView(outline, viewFor: nil, item: item)?.accessibilityIdentifier(), "GitX.Sidebar.Reflog")
        let menu = NSMenuItem(title: "Reflog", action: #selector(GitX.PBGitWindowController.showReflog(_:)), keyEquivalent: "")
        XCTAssertTrue(owner.validateMenuItem(menu))
        XCTAssertEqual(menu.state, .on)
        let historyMenu = NSMenuItem(title: "History", action: #selector(GitX.PBGitWindowController.showHistoryView(_:)), keyEquivalent: "")
        XCTAssertTrue(owner.validateMenuItem(historyMenu))
        XCTAssertEqual(historyMenu.state, .off)
        sidebar.reloadSidebarPresentation()
        XCTAssertTrue(sidebar.isReflogSelected)
        _ = sidebar.perform(NSSelectorFromString("forgeAccessDidChange:"), with: Notification(name: Notification.Name("PBRepositoryForgeAccountDidChange")))
        XCTAssertTrue(sidebar.isReflogSelected)
        autoreleasepool {
            repository.willChangeValue(forKey: "currentBranch")
            repository.didChangeValue(forKey: "currentBranch")
        }
        XCTAssertTrue(sidebar.isReflogSelected)
        browser.refresh(nil)
        sidebar.reloadSidebarAfterReferencesChange()
        XCTAssertTrue(sidebar.isReflogSelected)
        XCTAssertTrue(browser.status?.contains("repository changed") == true)
        XCTAssertFalse(browser.isBusy)
        owner.showReflog(nil)
        await waitUntilIdle(browser)
        XCTAssertTrue(owner.value(forKey: "contentController") as? ReflogBrowserController === browser)
        owner.showHistoryView(nil)
        XCTAssertFalse(sidebar.isReflogSelected)
        XCTAssertTrue(owner.validateMenuItem(menu))
        XCTAssertEqual(menu.state, .off)
        let row = outline.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntilIdle(browser)
        XCTAssertTrue(sidebar.isReflogSelected)
        owner.close()
        sidebar.showReflog()
        owner.showReflog(nil)
        XCTAssertFalse(try control("Reset", in: browser, as: NSButton.self).isEnabled)
    }

    func testBrowserAllocatesSpareWindowHeightToTheSplitView() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let browser = try await presentedBrowser(fixture)
        defer { browser.controller.closeView(); browser.window.close() }
        let root = browser.controller.view
        root.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertGreaterThan(split.frame.height, root.bounds.height * 0.65,
                             "The event list and details should receive spare height, rather than stretching the footer")
        for pane in split.arrangedSubviews {
            XCTAssertGreaterThan(pane.frame.height, split.bounds.height * 0.3,
                                 "Both panes should be readable before the user adjusts the divider")
        }
        XCTAssertLessThan(try control("Status", in: browser.controller, as: NSTextField.self).frame.height, 24)
    }

    private typealias PresentedBrowser = (controller: ReflogBrowserController, window: NSWindow, repository: GitX.PBGitRepository)

    private func presentedBrowser(_ fixture: ReflogGitFixture, row: Int = 0,
                                  serviceFactory: @escaping (GitX.PBGitRepository) throws -> RepositoryReflogService = { try RepositoryReflogService(repository: $0) }) async throws -> PresentedBrowser
    {
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: serviceFactory))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.orderFront(nil)
        controller.updateView()
        await waitUntilIdle(controller)
        try control("Events", in: controller, as: NSTableView.self).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntilIdle(controller)
        return (controller, window, repository)
    }

    private func preview(_ mode: ReflogResetMode, browser: PresentedBrowser) async throws -> NSTextView {
        try control("Reset", in: browser.controller, as: NSButton.self).performClick(nil)
        let modes = try sheetControl("ResetMode", window: browser.window, as: NSPopUpButton.self)
        XCTAssertEqual(modes.indexOfSelectedItem, 0)
        try modes.selectItem(at: XCTUnwrap(ReflogResetMode.allCases.firstIndex(of: mode)))
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { self.find("ResetPreview", in: browser.window.attachedSheet?.contentView) != nil }
        return try sheetControl("ResetPreview", window: browser.window, as: NSTextView.self)
    }

    private func dismissSheet(_ window: NSWindow, response: NSApplication.ModalResponse) throws {
        try window.endSheet(XCTUnwrap(window.attachedSheet), returnCode: response)
    }

    private func sheetButton(_ title: String, window: NSWindow) -> NSButton? {
        func button(in view: NSView?) -> NSButton? {
            if let value = view as? NSButton, value.title == title {
                return value
            }
            return view?.subviews.lazy.compactMap { button(in: $0) }.first
        }
        return button(in: window.attachedSheet?.contentView)
    }

    private func sheetControl<Value: NSView>(_ identifier: String, window: NSWindow, as _: Value.Type) throws -> Value {
        try XCTUnwrap(find(identifier, in: window.attachedSheet?.contentView) as? Value)
    }

    private func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // swift6-safety-justification: AppKit test predicates are evaluated on the main thread.
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    private func waitUntilIdle(_ controller: ReflogBrowserController) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // swift6-safety-justification: AppKit test predicates are evaluated on the main thread.
            MainActor.assumeIsolated { !controller.isBusy }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    private func control<Value: NSView>(_ identifier: String, in controller: ReflogBrowserController, as type: Value.Type) throws -> Value {
        try XCTUnwrap(find(identifier, in: controller.view) as? Value)
    }

    private func find(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == "GitX.Reflog." + identifier {
            return view
        }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}
