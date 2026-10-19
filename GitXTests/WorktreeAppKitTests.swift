import AppKit
import GitXCore
import XCTest

@MainActor
func activateWorktreeTestApplication(file: StaticString = #filePath, line: UInt = #line) async {
    // Launch Services models an explicit user return even when macOS declines self-activation.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    do {
        let application = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        XCTAssertEqual(application.processIdentifier, ProcessInfo.processInfo.processIdentifier, "Activate the existing test host", file: file, line: line)
    } catch {
        XCTFail("Could not activate the test host: \(error)", file: file, line: line)
    }
}

@MainActor
final class WorktreeAppKitTests: XCTestCase {
    func testRepairOfferThroughObjectiveCImportedSubclassKeepsWindowState() {
        let controller = RepairWindowControllerFixture(window: nil)
        let initiallyLoaded = controller.isWindowLoaded
        _ = controller.perform(NSSelectorFromString("windowDidBecomeMain:"), with: Notification(name: NSWindow.didBecomeMainNotification))
        XCTAssertEqual(controller.isWindowLoaded, initiallyLoaded)
        XCTAssertNil(controller.window)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let loaded = RepairWindowControllerFixture(window: window)
        _ = loaded.perform(NSSelectorFromString("windowDidBecomeMain:"), with: Notification(name: NSWindow.didBecomeMainNotification, object: window))
        XCTAssertTrue(loaded.window === window)
        XCTAssertNil(window.attachedSheet)
    }

    func testSidebarNestedBranchReferencesReuseOneFolderAndPreserveHierarchy() throws {
        let branches = PBSourceViewItem.groupItem(withTitle: "Branches")
        let unrelatedRevision = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/main"))
        let firstRevision = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/feature/topic10"))
        let secondRevision = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/feature/topic2"))
        branches.addRev(unrelatedRevision, toPath: ["main"])
        let unrelatedItem = try XCTUnwrap(branches.findRev(unrelatedRevision))
        branches.addRev(firstRevision, toPath: ["feature", "topic10"])
        let sharedFolder = try XCTUnwrap(branches.sortedChildren.first { $0.title == "feature" })
        let firstItem = try XCTUnwrap(sharedFolder.findRev(firstRevision))
        XCTAssertEqual(sharedFolder.sortedChildren, [firstItem])

        branches.addRev(secondRevision, toPath: ["feature", "topic2"])
        let secondItem = try XCTUnwrap(branches.findRev(secondRevision))
        let folders = branches.sortedChildren.filter { $0.title == "feature" }
        XCTAssertEqual(folders.count, 1, "Adding a sibling branch must reuse the existing sidebar folder")
        XCTAssertTrue(folders.first === sharedFolder)
        XCTAssertFalse(firstItem === secondItem)
        XCTAssertEqual(branches.sortedChildren.map(\.title), ["feature", "main"])
        XCTAssertEqual(sharedFolder.sortedChildren.map(\.title), ["topic2", "topic10"])
        XCTAssertEqual(sharedFolder.sortedChildren, [secondItem, firstItem])
        XCTAssertEqual(sharedFolder.sortedChildren.compactMap { $0.ref()?.ref }.map { Data($0.utf8) }, [Data("refs/heads/feature/topic2".utf8), Data("refs/heads/feature/topic10".utf8)])
        XCTAssertTrue(sharedFolder.parent === branches)
        XCTAssertTrue(firstItem.parent === sharedFolder)
        XCTAssertTrue(secondItem.parent === sharedFolder)
        XCTAssertTrue(branches.findRev(firstRevision) === firstItem)
        XCTAssertTrue(branches.findRev(secondRevision) === secondItem)
        XCTAssertTrue(branches.findRev(unrelatedRevision) === unrelatedItem)
        XCTAssertEqual(unrelatedItem.title, "main")
        XCTAssertEqual(unrelatedItem.ref()?.ref, "refs/heads/main")
        XCTAssertTrue(unrelatedItem.parent === branches)

        let sortedRoots = branches.sortedChildren
        let sortedNestedBranches = sharedFolder.sortedChildren
        branches.addChild(nil)
        XCTAssertEqual(branches.sortedChildren, sortedRoots)
        XCTAssertEqual(sharedFolder.sortedChildren, sortedNestedBranches)
        XCTAssertTrue(sharedFolder.parent === branches)
        XCTAssertTrue(unrelatedItem.parent === branches)
        XCTAssertTrue(firstItem.parent === sharedFolder)
        XCTAssertTrue(secondItem.parent === sharedFolder)
        XCTAssertTrue(branches.findRev(secondRevision) === secondItem)
    }

    func testExplicitBranchSelectionReturnsMountedContentToHistoryWithoutCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let window = PBGitWindowController()
        window.repository = repository
        await showForegroundWindow(window)
        defer { window.close(); service.cancel() }
        await waitUntil { window.historyViewController?.view.window === window.window }
        let history = try XCTUnwrap(window.historyViewController)
        let sidebar = try XCTUnwrap(window.sidebarViewController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let main = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }
            .first { $0.title == "BRANCHES" }?.sortedChildren.first)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let content = try XCTUnwrap(PBViewController(repository: repository, superController: window))
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = window.perform(NSSelectorFromString("changeContentController:"), with: content)
        XCTAssertTrue(content.view.window === window.window)

        outline.deselectAll(nil)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: main)), byExtendingSelection: false)
        sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        XCTAssertTrue(history.view.window === window.window)
        XCTAssertNil(content.view.window)
        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        _ = window.perform(NSSelectorFromString("changeContentController:"), with: content)
        _ = sidebar.perform(NSSelectorFromString("reloadSidebarPresentation"))
        XCTAssertTrue(history.view.window === window.window)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        _ = window.perform(NSSelectorFromString("changeContentController:"), with: content)
        let viewedRevision = try XCTUnwrap(repository.currentBranch)
        let action = NSSelectorFromString("returnToHistory:")
        XCTAssertTrue(window.responds(to: action))
        XCTAssertTrue(NSApp.sendAction(action, to: window, from: nil))
        XCTAssertTrue(history.view.window === window.window)
        XCTAssertNil(content.view.window)
        XCTAssertTrue(repository.currentBranch === viewedRevision)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), "refs/heads/main")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testNormalBranchSidebarMenusDispatchCopyAfterConstructionReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let branchName = "characterized-copy"
        let refName = "refs/heads/\(branchName)"
        _ = try fixture.git(["branch", branchName])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let refs = try fixture.git(["show-ref", "--head"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let branches = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "BRANCHES" })
        let branch = try XCTUnwrap(branches.sortedChildren.first { $0.revSpecifier?.simpleRef() == refName })
        XCTAssertFalse(branch is PBSourceViewGitWorktreeItem)
        let row = outline.row(forItem: branch)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
        let actionMenu = try XCTUnwrap(actionButton.menu)
        let contextMenu = autoreleasepool { sidebar.menu(forRow: row) }
        autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }

        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems.map { $0 as NSPasteboardWriting })
        }
        for menu in [contextMenu, actionMenu] {
            let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Branch Name" })
            let action = try XCTUnwrap(copy.action)
            XCTAssertEqual(action, NSSelectorFromString("copyBranchName:"))
            XCTAssertTrue(copy.isEnabled)
            XCTAssertNotNil(copy.target, "The action target must remain alive after menu construction returns")
            XCTAssertEqual((copy.representedObject as? PBGitRef)?.ref, refName)
            pasteboard.clearContents()
            pasteboard.setString("unchanged sentinel", forType: .string)
            let changeCount = pasteboard.changeCount
            XCTAssertTrue(NSApp.sendAction(action, to: copy.target, from: copy))
            XCTAssertEqual(pasteboard.string(forType: .string), branchName)
            XCTAssertGreaterThan(pasteboard.changeCount, changeCount)
        }
        XCTAssertEqual(repository.currentBranch?.simpleRef(), refName)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
    }

    func testHealthyWorktreeMenusDispatchUnlockWithoutLoadingHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        _ = try fixture.git(["worktree", "lock", "--reason", "characterized", fixture.linked.path])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let originalMetadata = try registrationMetadata(administrative)
        let originalRefs = try fixture.git(["show-ref", "--head"])
        let originalMainHead = try fixture.git(["rev-parse", "HEAD"])
        let originalLinkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = RepairWindowControllerFixture(windowNibName: "RepositoryWindow")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        controller.window = window
        controller.repository = repository
        window.orderFront(nil)
        defer { controller.close(); service.cancel() }
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(controller.historyViewController)
        let sidebar = try XCTUnwrap(PBGitSidebarController(repository: repository, superController: controller))
        _ = sidebar.view
        XCTAssertNil(controller.historyViewController, "Loading the sidebar must not require History")
        let row = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(row, in: sidebar)
        let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
        let actionMenu = try XCTUnwrap(actionButton.menu)

        for usesActionMenu in [false, true] {
            if usesActionMenu {
                _ = try fixture.git(["worktree", "lock", "--reason", "characterized-again", fixture.linked.path])
                service.refresh()
                await waitUntil { service.worktree(forBranch: "refs/heads/topic")?.isLocked == true }
            }
            let selected = try worktreeItem(in: sidebar, at: fixture.linked.path)
            XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, selected.identity)
            let outline = try XCTUnwrap(sidebar.sourceView)
            let selectedRow = outline.row(forItem: selected)
            XCTAssertGreaterThanOrEqual(selectedRow, 0)
            let menu: NSMenu
            if usesActionMenu {
                autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }
                menu = actionMenu
            } else {
                menu = autoreleasepool { sidebar.menu(forRow: selectedRow) }
            }
            let unlockItems = menu.items.filter { $0.action == NSSelectorFromString("unlockWorktree:") }
            XCTAssertEqual(unlockItems.count, 1)
            let unlock = try XCTUnwrap(unlockItems.first)
            XCTAssertTrue(unlock.isEnabled)
            XCTAssertNil(unlock.target, "Lifecycle actions continue through the responder chain")
            XCTAssertEqual((unlock.representedObject as? PBGitWorktree)?.path, selected.worktree.path)
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("checkout:") || $0.action == NSSelectorFromString("deleteRef:") })
            XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(unlock.action), to: controller, from: unlock))
            await waitUntil { service.worktree(forBranch: "refs/heads/topic")?.isLocked == false }
            XCTAssertFalse(FileManager.default.fileExists(atPath: administrative.appendingPathComponent("locked").path))
            XCTAssertEqual(try registrationMetadata(administrative), originalMetadata)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), originalRefs)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalMainHead)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), originalLinkedHead)
            XCTAssertNil(controller.historyViewController, "Menu dispatch must not load History")
            XCTAssertNil(window.attachedSheet)
        }
    }

    func testDuplicateBranchWorktreeMenusTargetTheClickedCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let duplicate = fixture.root.appendingPathComponent("duplicate-topic")
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        _ = try fixture.git(["worktree", "add", "--force", duplicate.path, "topic"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let initialFirst = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let clickedPath = WorktreePaths.identity(initialFirst.path) == WorktreePaths.identity(fixture.linked.path) ? duplicate : fixture.linked
        _ = try fixture.git(["worktree", "lock", "--reason", "keep-first-locked", initialFirst.path])
        service.refresh()
        await waitUntil { service.worktree(forBranch: "refs/heads/topic")?.isLocked == true }
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let first = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertNotEqual(WorktreePaths.identity(first.path), WorktreePaths.identity(clickedPath.path))
        XCTAssertTrue(first.isLocked)
        let clicked = try worktreeItem(in: sidebar, at: clickedPath.path)
        try selectWorktree(clicked, in: sidebar)
        let current = try worktreeItem(in: sidebar, at: clickedPath.path)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, current.identity)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let row = outline.row(forItem: current)
        XCTAssertGreaterThanOrEqual(row, 0)
        let actionMenu = try XCTUnwrap((sidebar.value(forKey: "actionButton") as? NSPopUpButton)?.menu)
        let contextMenu = autoreleasepool { sidebar.menu(forRow: row) }
        autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }
        for menu in [contextMenu, actionMenu] {
            for selectorName in ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "removeWorktree:"] {
                let matching = menu.items.filter { $0.action == NSSelectorFromString(selectorName) }
                XCTAssertEqual(matching.count, 1, selectorName)
                let item = matching.first
                XCTAssertTrue(item?.isEnabled == true, selectorName)
                XCTAssertEqual((item?.representedObject as? PBGitWorktree).map { WorktreePaths.identity($0.path) }, current.identity, selectorName)
                XCTAssertNil(item?.target)
            }
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("unlockWorktree:") })
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("checkout:") || $0.action == NSSelectorFromString("deleteRef:") })
        }
        guard let lock = contextMenu.items.first(where: { $0.action == NSSelectorFromString("lockWorktree:") }) else { return }
        let firstAdministrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: URL(fileURLWithPath: first.path)).trimmingCharacters(in: .whitespacesAndNewlines))
        let selectedAdministrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: clickedPath).trimmingCharacters(in: .whitespacesAndNewlines))
        let firstLock = try Data(contentsOf: firstAdministrative.appendingPathComponent("locked"))
        let firstMetadata = try registrationMetadata(firstAdministrative)
        let selectedMetadata = try registrationMetadata(selectedAdministrative)
        XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(lock.action), to: controller, from: lock))
        let sheet = try await waitForSheet(in: window, containing: "Lock")
        XCTAssertTrue(sheetText(sheet).contains(WorktreePaths.canonical(clickedPath.path)))
        let reason = try XCTUnwrap(descendants(sheet.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Reason (optional)" })
        reason.stringValue = "clicked-duplicate"
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { service.worktrees.first { WorktreePaths.identity($0.path) == current.identity }?.isLocked == true && window.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: firstAdministrative.appendingPathComponent("locked")), firstLock)
        XCTAssertEqual(try String(contentsOf: selectedAdministrative.appendingPathComponent("locked"), encoding: .utf8), "clicked-duplicate\n")
        XCTAssertEqual(try registrationMetadata(firstAdministrative), firstMetadata)
        XCTAssertEqual(try registrationMetadata(selectedAdministrative), selectedMetadata)
        try attachScreenshot(of: window, named: "Worktrees-Clicked-Duplicate-Branch")
    }

    func testSidebarReferenceMenusDispatchCopyWithoutLoadingHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["branch", "ordinary-copy"])
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let refs = try fixture.git(["show-ref", "--head"])
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        defer { service.cancel() }
        let sidebar = try XCTUnwrap(PBGitSidebarController(repository: repository, superController: nil))
        _ = sidebar.view
        XCTAssertNil(sidebar.windowController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let actionMenu = try XCTUnwrap((sidebar.value(forKey: "actionButton") as? NSPopUpButton)?.menu)
        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer { pasteboard.clearContents(); pasteboard.writeObjects(originalItems.map { $0 as NSPasteboardWriting }) }
        for branchName in ["ordinary-copy", "topic"] {
            let expectedRef = "refs/heads/" + branchName
            let item: PBSourceViewItem
            if branchName == "topic" {
                item = try worktreeItem(in: sidebar, at: fixture.linked.path)
            } else {
                let branches = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "BRANCHES" })
                item = try XCTUnwrap(sourceItems(branches).first { $0.revSpecifier?.simpleRef() == expectedRef })
            }
            var parents: [PBSourceViewItem] = []
            var parent = item.parent
            while let current = parent {
                parents.append(current)
                parent = current.parent
            }
            for parent in parents.reversed() {
                outline.expandItem(parent)
            }
            let visibleRow = outline.row(forItem: item)
            XCTAssertGreaterThanOrEqual(visibleRow, 0, expectedRef)
            guard visibleRow >= 0 else { continue }
            outline.deselectAll(nil)
            outline.selectRowIndexes(IndexSet(integer: visibleRow), byExtendingSelection: false)
            sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
            let selected = try XCTUnwrap(sidebar.selectedItem())
            XCTAssertEqual(selected.revSpecifier?.simpleRef(), expectedRef)
            let row = outline.row(forItem: selected)
            XCTAssertGreaterThanOrEqual(row, 0)
            let contextMenu = autoreleasepool { sidebar.menu(forRow: row) }
            autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }
            for menu in [contextMenu, actionMenu] {
                let copies = menu.items.filter { $0.action == NSSelectorFromString("copyBranchName:") }
                XCTAssertEqual(copies.count, 1, branchName)
                guard let copy = copies.first else { continue }
                XCTAssertTrue(copy.isEnabled)
                XCTAssertNotNil(copy.target)
                XCTAssertEqual((copy.representedObject as? PBGitRef)?.ref, expectedRef)
                pasteboard.clearContents()
                pasteboard.setString("unchanged sentinel", forType: .string)
                XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(copy.action), to: copy.target, from: copy))
                XCTAssertEqual(pasteboard.string(forType: .string), branchName)
            }
        }
        XCTAssertNil(sidebar.windowController)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
    }

    func testCapturedWorktreeSynchronizationKeepsItsOriginAfterBothSameOIDRowsChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let second = fixture.root.appendingPathComponent("second-detached")
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Pinned old worktree history"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let latestOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", capturedOID, "-m", "Latest worktree history"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
        _ = try fixture.git(["worktree", "add", "--detach", second.path, capturedOID])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let first = try worktreeItem(in: sidebar, at: fixture.linked.path)
        let clicked = try worktreeItem(in: sidebar, at: second.path)
        try selectWorktree(first, in: sidebar)
        await waitUntil { history.selectedCommits.first?.sha == capturedOID }
        let capturedRevision = try XCTUnwrap(repository.currentBranch)
        try selectWorktree(clicked, in: sidebar)
        XCTAssertTrue(repository.currentBranch === capturedRevision, "Equal OIDs do not replace the viewed revision")
        let renderedOIDs = history.webCommits.map(\.sha)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        _ = try fixture.git(["checkout", "--detach", latestOID], in: fixture.linked)
        _ = try fixture.git(["checkout", "--detach", latestOID], in: second)
        service.refresh()
        await waitUntil {
            let linked = service.worktrees.filter { !$0.isMain }
            return linked.count == 2 && linked.allSatisfy { ($0.value(forKey: "HEAD") as? String) == latestOID }
        }
        await waitUntil {
            guard let group = sidebar.items.compactMap({ $0 as? PBSourceViewItem }).first(where: { $0.title == "WORKTREES" }) else { return false }
            let identities = Set([WorktreePaths.identity(fixture.linked.path), WorktreePaths.identity(second.path)])
            let rows = group.sortedChildren.compactMap { $0 as? PBSourceViewGitWorktreeItem }.filter { identities.contains($0.identity) }
            return rows.count == 2 && rows.allSatisfy { $0.revSpecifier?.parameters == [latestOID + "^{commit}"] }
        }
        let outline = try XCTUnwrap(sidebar.sourceView)
        await waitUntil {
            let identities = Set([WorktreePaths.identity(fixture.linked.path), WorktreePaths.identity(second.path)])
            let outlined = (0 ..< outline.numberOfRows).compactMap { outline.item(atRow: $0) as? PBSourceViewGitWorktreeItem }.filter { identities.contains($0.identity) }
            return outlined.count == 2 && outlined.allSatisfy { $0.revSpecifier?.parameters == [latestOID + "^{commit}"] }
        }
        let selectedBeforeSynchronization = try XCTUnwrap(sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)
        XCTAssertEqual(selectedBeforeSynchronization.revSpecifier?.parameters, [latestOID + "^{commit}"], "The selected outlined row must expose the published captured HEAD before synchronization")
        XCTAssertTrue(repository.currentBranch === capturedRevision)
        XCTAssertTrue(alternate.view.window === window)
        XCTAssertEqual(selectedBeforeSynchronization.identity, clicked.identity)
        sidebar.selectCurrentBranch()
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        XCTAssertTrue(repository.currentBranch === capturedRevision)
        XCTAssertTrue(alternate.view.window === window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(history.selectedCommits.first?.sha, capturedOID)
        XCTAssertEqual(history.webCommits.map(\.sha), renderedOIDs)
        let others = try XCTUnwrap(sidebar.value(forKey: "others") as? PBSourceViewItem)
        XCTAssertFalse(sourceItems(others).contains { $0.revSpecifier === capturedRevision }, "Synchronizing the selected checkout must not add its stale captured revision to Other")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), latestOID)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: second).trimmingCharacters(in: .whitespacesAndNewlines), latestOID)
    }

    func testSelectedLinkedMainWorktreeDoesNotFollowTheRepositoryCheckoutDuringPassiveReferencesReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["branch", "elsewhere"])
        _ = try fixture.git(["worktree", "add", "--force", fixture.linked.path, "main"])
        let originalMainOID = try fixture.git(["rev-parse", "HEAD"])
        let linkedHead = try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked)
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(administrative)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let clicked = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(clicked, in: sidebar)
        await waitUntil { history.selectedCommits.first?.sha == originalMainOID.trimmingCharacters(in: .whitespacesAndNewlines) }
        let viewedRevision = try XCTUnwrap(repository.currentBranch)
        XCTAssertEqual(viewedRevision.simpleRef(), "refs/heads/main")
        let selectedOID = history.selectedCommits.first?.sha
        let renderingInput = history.webCommits.map(\.sha)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        _ = try fixture.git(["checkout", "elsewhere"])
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"]), "refs/heads/elsewhere\n")
        repository.reloadRefs()
        await waitUntil { repository.headRef()?.simpleRef() == "refs/heads/elsewhere" }
        XCTAssertEqual(repository.headRef()?.simpleRef(), "refs/heads/elsewhere", "The probe must use GitX's refreshed HEAD snapshot, not only raw Git output")
        sidebar.reloadSidebarAfterReferencesChange()
        XCTAssertTrue(repository.currentBranch === viewedRevision, "The selected linked checkout must not follow another checkout's HEAD")
        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/main")
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        XCTAssertTrue(alternate.view.window === window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(history.selectedCommits.first?.sha, selectedOID)
        XCTAssertEqual(history.webCommits.map(\.sha), renderingInput)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"]), "refs/heads/elsewhere\n")
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked), linkedHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalMainOID)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
    }

    func testReturnToHistoryAdoptsLatestCapturedCheckoutWhileDeepLinksKeepTheirTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let refName = "refs/gitx/return-history"
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Return old symbolic history"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let latestOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", capturedOID, "-m", "Return latest symbolic history"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
        _ = try fixture.git(["update-ref", refName, capturedOID])
        _ = try fixture.git(["symbolic-ref", "HEAD", refName], in: fixture.linked)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let clicked = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(clicked, in: sidebar)
        await waitUntil { history.selectedCommits.first?.sha == capturedOID }
        let oldRevision = try XCTUnwrap(repository.currentBranch)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        _ = try fixture.git(["update-ref", refName, latestOID])
        service.refresh()
        await waitUntil { (service.worktrees.first { WorktreePaths.identity($0.path) == clicked.identity }?.value(forKey: "HEAD") as? String) == latestOID }
        await waitUntil {
            guard let selected = sidebar.selectedItem() as? PBSourceViewGitWorktreeItem else { return false }
            return selected.identity == clicked.identity && selected.revSpecifier?.parameters == [latestOID + "^{commit}"]
        }
        XCTAssertTrue(repository.currentBranch === oldRevision)
        XCTAssertTrue(alternate.view.window === window)
        let historyAction = NSMenuItem(title: "History", action: NSSelectorFromString("returnToHistory:"), keyEquivalent: "1")
        let action = try XCTUnwrap(historyAction.action)
        let responds = controller.responds(to: action)
        XCTAssertTrue(responds, "The explicit History command must have its own responder entry point")
        guard responds else { return }
        let dispatched = NSApp.sendAction(action, to: controller, from: historyAction)
        XCTAssertTrue(dispatched, "The explicit History command must have its own responder entry point")
        guard dispatched else { return }
        await waitUntil { history.view.window === window && history.selectedCommits.first?.sha == latestOID }
        let latestRevision = try XCTUnwrap(repository.currentBranch)
        XCTAssertEqual(latestRevision.parameters, [latestOID + "^{commit}"])
        XCTAssertEqual(latestRevision.description, "HEAD → " + refName + " (" + latestOID + ")")
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        XCTAssertNil(alternate.view.window)
        await waitUntil { self.descendants(history.view).compactMap { $0 as? NSTextView }.contains { $0.accessibilityIdentifier() == "NativeContentText" && $0.string.contains("Return latest symbolic history") && !$0.string.contains("Loading diff…") } }
        try attachScreenshot(of: window, named: "Worktrees-Explicit-Return-Latest-History")
        XCTAssertTrue(controller.openForgeRevision(capturedOID))
        await waitUntil { history.selectedCommits.first?.sha == capturedOID }
        XCTAssertTrue(repository.currentBranch === latestRevision, "Selecting a deep-linked commit must not adopt another history origin")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), latestOID)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), refName)
    }

    func testPruneMenuUsesFreshDiscoveryWhenHealthySnapshotHasBecomeStale() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let originalMetadata = try registrationMetadata(administrative)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let group = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        let outline = try XCTUnwrap(sidebar.sourceView)
        XCTAssertTrue(service.worktrees.allSatisfy(\.folderExists))
        try FileManager.default.removeItem(at: fixture.linked)
        // No await or event-loop drain: published discovery still says healthy.
        XCTAssertTrue(service.worktrees.allSatisfy(\.folderExists))
        let expectedReport = try fixture.git(["worktree", "prune", "--dry-run", "--verbose"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(expectedReport.isEmpty)
        let contextMenu = sidebar.menu(forRow: outline.row(forItem: group))
        let prune = try XCTUnwrap(contextMenu.items.first { $0.title == "Prune Worktrees…" })
        XCTAssertTrue(prune.isEnabled, "A supported repository must be allowed to request an authoritative preview")
        XCTAssertEqual(prune.action, NSSelectorFromString("pruneWorktrees:"))
        if let action = prune.action {
            XCTAssertTrue(NSApp.sendAction(action, to: controller, from: prune))
        } else {
            // The baseline red must still prove the independent backend preview.
            controller.pruneWorktrees(nil)
        }
        let preview = try await waitForSheet(in: window, containing: "Prune")
        XCTAssertTrue(sheetText(preview).contains(expectedReport))
        try attachScreenshot(of: preview, named: "Worktrees-Prune-Fresh-From-Stale-Healthy-Snapshot")
        window.endSheet(preview, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(try registrationMetadata(administrative), originalMetadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(FileManager.default.fileExists(atPath: administrative.path))
    }

    func testMissingGitfileRepairRequiresSeparateDefaultCancelReclaimConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let gitfile = fixture.linked.appendingPathComponent(".git")
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let originalMetadata = try registrationMetadata(administrative)
        let originalHead = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        try FileManager.default.removeItem(at: gitfile)
        service.refresh()
        await waitUntil { service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
        let style = try await waitForSheet(in: window, containing: "Absolute Paths")
        window.endSheet(style, returnCode: .alertFirstButtonReturn)
        await waitUntil { FileManager.default.fileExists(atPath: gitfile.path) || window.attachedSheet.map { self.descendants($0.contentView).contains { ($0 as? NSButton)?.title == "Reclaim" } } == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path), "A missing ownership anchor must not be reconstructed before separate reclaim consent")
        guard let consent = window.attachedSheet else { return }
        let reclaim = try XCTUnwrap(descendants(consent.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Reclaim" })
        let cancel = try XCTUnwrap(descendants(consent.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        let cancelCell = try XCTUnwrap(cancel.cell as? NSButtonCell)
        XCTAssertTrue(consent.defaultButtonCell === cancelCell)
        XCTAssertEqual(reclaim.keyEquivalent, "")
        XCTAssertTrue(reclaim.hasDestructiveAction)
        XCTAssertTrue(sheetText(consent).contains(WorktreePaths.canonical(fixture.linked.path)))
        try attachScreenshot(of: consent, named: "Worktrees-Reclaim-Missing-Link-Default-Cancel")
        window.endSheet(consent, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        XCTAssertEqual(try registrationMetadata(administrative), originalMetadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)
        controller.repairWorktreeLinks(nil)
        let nextStyle = try await waitForSheet(in: window, containing: "Absolute Paths")
        window.endSheet(nextStyle, returnCode: .alertFirstButtonReturn)
        let nextConsent = try await waitForSheet(in: window, containing: "Reclaim")
        window.endSheet(nextConsent, returnCode: .alertFirstButtonReturn)
        await waitUntil { FileManager.default.fileExists(atPath: gitfile.path) && service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == false && window.attachedSheet == nil }
        XCTAssertEqual(try registrationMetadata(administrative), originalMetadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), WorktreePaths.canonical(administrative.path))
    }

    func testChangedRepairOwnershipRenewsConsentAndRequiresAnotherExplicitRepairClick() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let gitfile = fixture.linked.appendingPathComponent(".git")
        let originalGitfile = try Data(contentsOf: gitfile)
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(administrative)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let gate = PruneTaskGate(fixture: fixture)
        let service = try await installPruneService(in: repository, gate: gate)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === window }
        try FileManager.default.removeItem(at: gitfile)
        service.refresh()
        await waitUntil { service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
        let style = try await waitForSheet(in: window, containing: "Absolute Paths")
        window.endSheet(style, returnCode: .alertFirstButtonReturn)
        let initialConsent = try await waitForSheet(in: window, containing: "Reclaim")
        XCTAssertFalse(gate.repairWasRequested)

        // A competing, controlled restoration changes the ownership evidence
        // without changing the registration or checkout directory identities.
        try originalGitfile.write(to: gitfile)
        window.endSheet(initialConsent, returnCode: .alertFirstButtonReturn)
        let renewed = try await waitForSheet(in: window, containing: "Repair")
        XCTAssertTrue(sheetText(renewed).contains("The worktree state changed. Review this updated list and choose Repair again."))
        XCTAssertTrue(sheetText(renewed).contains(WorktreePaths.canonical(fixture.linked.path)))
        XCTAssertFalse(descendants(renewed.contentView).contains { ($0 as? NSButton)?.title == "Reclaim" })
        let action = try XCTUnwrap(descendants(renewed.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Repair" })
        let cancel = try XCTUnwrap(descendants(renewed.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        XCTAssertEqual(action.keyEquivalent, "")
        XCTAssertFalse(action.hasDestructiveAction)
        let cancelCell = try XCTUnwrap(cancel.cell as? NSButtonCell)
        XCTAssertTrue(renewed.defaultButtonCell === cancelCell)
        XCTAssertFalse(gate.repairWasRequested, "The original click must not authorize the renewed plan")
        XCTAssertEqual(try Data(contentsOf: gitfile), originalGitfile)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        try attachScreenshot(of: renewed, named: "Worktrees-Renewed-Repair-Requires-New-Click")
        window.endSheet(renewed, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(gate.repairWasRequested)
        try await operation(.lock(path: fixture.linked.path, reason: "after cancelled renewal"), service: service)
        XCTAssertTrue(service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try Data(contentsOf: gitfile), originalGitfile)
    }

    #if DEBUG
        func testReclaimConsentSurvivesTemporaryHidingButCannotSurviveOwnerReplacement() async throws {
            for hidesWindow in [false, true] {
                let fixture = try Fixture()
                _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
                let gitfile = fixture.linked.appendingPathComponent(".git")
                let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
                let metadata = try registrationMetadata(administrative)
                let head = try fixture.git(["rev-parse", "HEAD"])
                let repository = try RepositoryTestGitRepository(url: fixture.main)
                let alternative = try RepositoryTestGitRepository(url: fixture.main)
                let retired = try XCTUnwrap(repository.worktreeService)
                let alternativeService = try XCTUnwrap(alternative.worktreeService)
                let gate = PruneTaskGate(fixture: fixture)
                let service = try await installPruneService(in: repository, gate: gate)
                let controller = PBGitWindowController()
                controller.repository = repository
                await showForegroundWindow(controller)
                let window = try XCTUnwrap(controller.window)
                addTeardownBlock { @MainActor in
                    controller.close()
                    let services = [retired, service, alternativeService]
                    services.forEach { $0.cancel() }
                    let drained = XCTestExpectation(description: "presentation owner and retired services finish before fixture deletion")
                    drained.expectedFulfillmentCount = services.count
                    services.forEach { $0.drainForTesting { drained.fulfill() } }
                    guard await XCTWaiter.fulfillment(of: [drained], timeout: 15) == .completed else {
                        XCTFail("Retaining presentation fixture because its services did not drain: " + fixture.root.path)
                        return
                    }
                    fixture.cleanup()
                }
                await waitUntil { controller.historyViewController?.view.window === window }
                try FileManager.default.removeItem(at: gitfile)
                service.refresh()
                await waitUntil { service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
                let style = try await waitForSheet(in: window, containing: "Absolute Paths")
                window.endSheet(style, returnCode: .alertFirstButtonReturn)
                let consent = try await waitForSheet(in: window, containing: "Reclaim")
                if hidesWindow {
                    window.orderOut(nil)
                    XCTAssertFalse(window.isVisible)
                    XCTAssertFalse(gate.repairWasRequested)
                    await showForegroundWindow(controller)
                    await waitUntil { window.isVisible }
                    XCTAssertTrue(window.attachedSheet === consent, "Temporary hiding preserves the original consent authority")
                } else {
                    controller.repository = alternative
                    controller.repository = repository
                    XCTAssertTrue(controller.repository === repository)
                }
                if hidesWindow {
                    window.endSheet(consent, returnCode: .alertFirstButtonReturn)
                } else {
                    await waitUntil { window.attachedSheet !== consent }
                    XCTAssertNil(consent.sheetParent, "Owner replacement explicitly revokes the original consent")
                    await drainPruneCallbacks()
                    await waitUntil { window.attachedSheet == nil }
                    XCTAssertFalse(gate.repairWasRequested)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
                    XCTAssertEqual(try registrationMetadata(administrative), metadata)
                    XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
                    controller.repairWorktreeLinks(nil)
                    let freshStyle = try await waitForSheet(in: window, containing: "Absolute Paths")
                    window.endSheet(freshStyle, returnCode: .alertFirstButtonReturn)
                    let freshConsent = try await waitForSheet(in: window, containing: "Reclaim")
                    window.endSheet(freshConsent, returnCode: .alertFirstButtonReturn)
                }
                await waitUntil { FileManager.default.fileExists(atPath: gitfile.path) && window.attachedSheet == nil }
                XCTAssertTrue(gate.repairWasRequested, "A fresh explicit request must still progress through the shared FIFO")
                XCTAssertEqual(try registrationMetadata(administrative), metadata)
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
                XCTAssertEqual(try fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), WorktreePaths.canonical(administrative.path))
            }
        }
    #endif

    func testBranchWorktreeSidebarMenusRetainReferenceActionsAndSafeLifecycleRouting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        _ = try fixture.git(["commit", "--allow-empty", "-m", "Topic-only commit"], in: fixture.linked)
        let topicOID = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["remote", "add", "origin", fixture.root.appendingPathComponent("offline-origin").path])
        _ = try fixture.git(["update-ref", "refs/remotes/origin/topic", topicOID])
        _ = try fixture.git(["branch", "--set-upstream-to", "origin/topic", "topic"])
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let refs = try fixture.git(["show-ref", "--head"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === controller.window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let worktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(worktree, in: sidebar)
        let selectedWorktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, selectedWorktree.identity)
        let selectedRow = outline.row(forItem: selectedWorktree)
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
        let actionMenu = try XCTUnwrap(actionButton.menu)
        let contextMenu = autoreleasepool { sidebar.menu(forRow: selectedRow) }
        autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }
        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems.map { $0 as NSPasteboardWriting })
        }
        let referenceActions = ["copyBranchName:", "createBranch:", "createTag:", "diffWithHEAD:", "merge:", "rebaseHeadBranch:", "resetSoft:", "fetchRemote:", "pullRemote:", "pushDefaultRemoteForRef:"]
        for menu in [contextMenu, actionMenu] {
            for selectorName in referenceActions {
                let selector = NSSelectorFromString(selectorName)
                let item = menu.items.first { $0.action == selector }
                XCTAssertNotNil(item, "A branch-backed worktree must retain \(selectorName) in both sidebar menus")
                guard let item else { continue }
                XCTAssertTrue(item.isEnabled, selectorName)
                XCTAssertEqual((item.representedObject as? PBGitRef)?.ref, "refs/heads/topic", selectorName)
                if selectorName == "copyBranchName:" {
                    XCTAssertNotNil(item.target, "The retained history collaborator must keep Copy alive after construction")
                    pasteboard.clearContents()
                    pasteboard.setString("unchanged sentinel", forType: .string)
                    let changeCount = pasteboard.changeCount
                    XCTAssertTrue(NSApp.sendAction(selector, to: item.target, from: item))
                    XCTAssertEqual(pasteboard.string(forType: .string), "topic")
                    XCTAssertGreaterThan(pasteboard.changeCount, changeCount)
                } else {
                    XCTAssertNil(item.target, "Reference actions must retain responder-chain dispatch")
                }
            }
            for selectorName in ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "removeWorktree:"] {
                let matchingItems = menu.items.filter { $0.action == NSSelectorFromString(selectorName) }
                XCTAssertEqual(matchingItems.count, 1, "Both menu routes must contain exactly one \(selectorName)")
                let item = matchingItems.first
                XCTAssertNotNil(item, selectorName)
                XCTAssertTrue(item?.isEnabled == true, selectorName)
                XCTAssertEqual((item?.representedObject as? PBGitWorktree)?.path, worktree.worktree.path, selectorName)
                XCTAssertNil(item?.target)
            }
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("checkout:") || $0.action == NSSelectorFromString("deleteRef:") })
        }
        let window = try XCTUnwrap(controller.window)
        try attachScreenshot(of: window, named: "Worktrees-Branch-Reference-Actions-Selected")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
    }

    func testWorktreeReferenceAndSettingsRestorationRefreshesControlsWithoutNavigation() async throws {
        for settingsReload in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
            _ = try fixture.git(["remote", "add", "origin", fixture.root.appendingPathComponent("offline-origin").path])
            _ = try fixture.git(["update-ref", "refs/remotes/origin/topic", "HEAD"])
            let mainHead = try fixture.git(["rev-parse", "HEAD"])
            let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
            let refs = try fixture.git(["show-ref", "--head"])
            let porcelain = try fixture.git(["worktree", "list", "--porcelain", "-z"])
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let service = try XCTUnwrap(repository.worktreeService)
            await ready(service)
            let controller = PBGitWindowController()
            controller.repository = repository
            await showForegroundWindow(controller)
            defer { controller.close(); service.cancel() }
            let window = try XCTUnwrap(controller.window)
            await waitUntil { controller.historyViewController?.view.window === window }
            let history = try XCTUnwrap(controller.historyViewController)
            let sidebar = try XCTUnwrap(controller.sidebarViewController)
            let worktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
            try selectWorktree(worktree, in: sidebar)
            let viewedRevision = try XCTUnwrap(repository.currentBranch)
            let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
            let remoteControls = try XCTUnwrap(sidebar.value(forKey: "remoteControls") as? NSSegmentedControl)
            let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
            alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)

            for (cycle, hasUpstream) in [false, true, false].enumerated() {
                if hasUpstream {
                    _ = try fixture.git(["branch", "--set-upstream-to", "origin/topic", "topic"])
                } else if cycle == 2 {
                    _ = try fixture.git(["branch", "--unset-upstream", "topic"])
                }
                actionButton.isEnabled = false
                if settingsReload {
                    sidebar.repositorySettingsDidChange(Notification(name: Notification.Name("PBRepositorySettingsDidChangeNotification"), object: repository))
                } else {
                    repository.reloadRefs()
                }
                // Assert at the synchronous restoration boundary. Unchanged
                // worktree discovery must not be needed to rescue controls.
                XCTAssertTrue(actionButton.isEnabled, "Restoration must finalize the action button")
                for segment in 1 ... 3 {
                    XCTAssertEqual(remoteControls.isEnabled(forSegment: segment), hasUpstream, "Settings reload=\(settingsReload), upstream=\(hasUpstream), segment=\(segment)")
                }
                XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, worktree.identity)
                XCTAssertTrue(repository.currentBranch === viewedRevision)
                XCTAssertTrue(alternate.view.window === window)
                XCTAssertNil(history.view.window)
                XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain", "-z"]), porcelain)
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                try attachScreenshot(of: window, named: "Worktrees-Controls-\(settingsReload ? "Settings" : "Refs")-Upstream-\(cycle)")
            }
            try selectWorktree(worktreeItem(in: sidebar, at: fixture.linked.path), in: sidebar)
            XCTAssertTrue(history.view.window === window)
            XCTAssertNil(alternate.view.window)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
        }
    }

    func testBranchWorktreeMenusUseRetainedReferenceBuilderWithoutHistoryCollaborator() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        defer { service.cancel() }
        await ready(service)
        let sidebar = try XCTUnwrap(PBGitSidebarController(repository: repository, superController: nil))
        _ = sidebar.view
        XCTAssertNil(sidebar.windowController)
        let worktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(worktree, in: sidebar)
        let selectedWorktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, selectedWorktree.identity)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let selectedRow = outline.row(forItem: selectedWorktree)
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
        let actionMenu = try XCTUnwrap(actionButton.menu)
        sidebar.menuNeedsUpdate(actionMenu)
        for menu in [sidebar.menu(forRow: selectedRow), actionMenu] {
            for selectorName in ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "removeWorktree:"] {
                let matchingItems = menu.items.filter { $0.action == NSSelectorFromString(selectorName) }
                XCTAssertEqual(matchingItems.count, 1)
                let item = try XCTUnwrap(matchingItems.first)
                XCTAssertEqual((item.representedObject as? PBGitWorktree)?.path, worktree.worktree.path)
                XCTAssertTrue(item.isEnabled)
                XCTAssertNil(item.target)
            }
            let copy = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("copyBranchName:") })
            XCTAssertNotNil(copy.target)
            XCTAssertEqual((copy.representedObject as? PBGitRef)?.ref, "refs/heads/topic")
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("checkout:") || $0.action == NSSelectorFromString("deleteRef:") })
        }
    }

    func testUnselectedSidebarBeforePopulationHasNoWorktreeGroupMenu() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        defer { service.cancel() }
        await ready(service)
        let sidebar = try XCTUnwrap(PBGitSidebarController(repository: repository, superController: nil))
        let actionButton = NSPopUpButton(frame: .zero, pullsDown: true)
        actionButton.menu = NSMenu()
        sidebar.setValue(actionButton, forKey: "actionButton")
        XCTAssertFalse(sidebar.isViewLoaded)
        XCTAssertNil(sidebar.selectedItem())
        sidebar.updateActionMenu()
        XCTAssertFalse(actionButton.isEnabled)
        let menu = try XCTUnwrap(actionButton.menu)
        sidebar.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.count, 1, "An unselected action menu contains only its icon")
        XCTAssertTrue(applicationMenuItems(menu).isEmpty, "No selection must not be mistaken for a missing Worktrees group")
    }

    func testNonlocalSymbolicWorktreeBrowsesCapturedHistoryWithLifecycleMenus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let refName = "refs/gitx/ui-symbolic"
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Non-local symbolic history"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
        _ = try fixture.git(["update-ref", refName, capturedOID])
        _ = try fixture.git(["symbolic-ref", "HEAD", refName], in: fixture.linked)
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let refs = try fixture.git(["show-ref", "--head"])
        let rawListing = try Data(fixture.git(["worktree", "list", "--porcelain", "-z"]).utf8)
        let parsed = try WorktreeParser.parse(rawListing)
        let record = try XCTUnwrap(parsed.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) })
        XCTAssertEqual(record.headRefName, refName)
        XCTAssertNil(record.branchRefName)
        XCTAssertFalse(record.isDetached)
        XCTAssertEqual(record.head, capturedOID)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let history = try XCTUnwrap(controller.historyViewController)
        let item = try worktreeItem(in: sidebar, at: fixture.linked.path)
        XCTAssertEqual(item.title, "HEAD → \(refName)")
        XCTAssertEqual(item.worktree.headRefName, refName)
        XCTAssertNil(item.worktree.branchRefName)
        XCTAssertNil(service.worktree(forBranch: refName))
        let revision = try XCTUnwrap(item.revSpecifier)
        XCTAssertFalse(revision.isSimpleRef)
        XCTAssertEqual(revision.parameters, [capturedOID + "^{commit}"])
        XCTAssertNil(revision.simpleRef())
        XCTAssertNil(revision.ref())
        XCTAssertEqual(String(describing: revision), "HEAD → \(refName) (\(capturedOID))")
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        try selectWorktree(item, in: sidebar)
        XCTAssertTrue(history.view.window === window)
        XCTAssertNil(alternate.view.window)
        let selectedItem = try worktreeItem(in: sidebar, at: fixture.linked.path)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, selectedItem.identity)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let selectedRow = outline.row(forItem: selectedItem)
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
        let actionMenu = try XCTUnwrap(actionButton.menu)
        sidebar.menuNeedsUpdate(actionMenu)
        for menu in [sidebar.menu(forRow: selectedRow), actionMenu] {
            let applicationItems = applicationMenuItems(menu)
            XCTAssertEqual(applicationItems.count, 5)
            XCTAssertEqual(applicationItems.compactMap(\.action), ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "refreshWorktrees:", "removeWorktree:"].map(NSSelectorFromString))
            for action in applicationItems {
                if action.action == NSSelectorFromString("refreshWorktrees:") {
                    XCTAssertNil(action.representedObject)
                } else {
                    XCTAssertEqual((action.representedObject as? PBGitWorktree)?.path, item.worktree.path)
                }
                XCTAssertNil(action.target)
                XCTAssertTrue(action.isEnabled)
            }
        }
        await waitUntil {
            (history.commitController.arrangedObjects as? [PBGitCommit])?.contains { $0.sha == capturedOID } == true
                && history.selectedCommits.first?.sha == capturedOID
        }
        await waitUntil {
            self.descendants(history.view).compactMap { $0 as? NSTextView }.contains {
                $0.accessibilityIdentifier() == "NativeContentText"
                    && $0.string.contains("Non-local symbolic history")
                    && !$0.string.contains("Loading diff…")
            }
        }
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, item.identity)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), refName)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        try attachScreenshot(of: window, named: "Worktrees-Nonlocal-Symbolic-Captured-History")

        let viewedRevision = try XCTUnwrap(repository.currentBranch)
        let renderedCommitOIDs = history.webCommits.map(\.sha)
        XCTAssertEqual(renderedCommitOIDs, [capturedOID])
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        let updatedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", capturedOID, "-m", "Updated non-local symbolic history"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let published = expectation(description: "new symbolic HEAD captured by discovery")
        let observation = service.observe(\.worktrees) { _, _ in published.fulfill() }
        _ = try fixture.git(["update-ref", refName, updatedOID])
        service.refresh()
        await fulfillment(of: [published], timeout: 10)
        observation.invalidate()
        let updatedItem = try worktreeItem(in: sidebar, at: fixture.linked.path)
        XCTAssertEqual(updatedItem.revSpecifier?.parameters, [updatedOID + "^{commit}"])
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, item.identity)
        XCTAssertTrue(repository.currentBranch === viewedRevision, "Passive publication must preserve the viewed captured revision")
        XCTAssertTrue(alternate.view.window === window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(history.selectedCommits.first?.sha, capturedOID)
        // Worktree publication does not drain the native renderer's separate
        // queue. Preserve its commit input rather than sample a hidden view.
        XCTAssertEqual(history.webCommits.map(\.sha), renderedCommitOIDs)

        try selectWorktree(updatedItem, in: sidebar)
        XCTAssertTrue(history.view.window === window)
        XCTAssertNil(alternate.view.window)
        XCTAssertEqual(try String(describing: XCTUnwrap(repository.currentBranch)), "HEAD → \(refName) (\(updatedOID))")
        await waitUntil {
            (history.commitController.arrangedObjects as? [PBGitCommit])?.contains { $0.sha == updatedOID } == true
                && history.selectedCommits.first?.sha == updatedOID
        }
        await waitUntil {
            self.descendants(history.view).compactMap { $0 as? NSTextView }.contains {
                $0.accessibilityIdentifier() == "NativeContentText"
                    && $0.string.contains("Updated non-local symbolic history")
                    && !$0.string.contains("Loading diff…")
            }
        }
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, item.identity)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), updatedOID)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), refName)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs.replacingOccurrences(of: capturedOID + " " + refName, with: updatedOID + " " + refName))
        try attachScreenshot(of: window, named: "Worktrees-Nonlocal-Symbolic-Updated-Captured-History")
    }

    func testNonlocalTagAndRemoteSymbolicHeadsPreserveNormalReferenceRows() async throws {
        for refName in ["refs/tags/release", "refs/remotes/origin/topic"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            _ = try fixture.git(["remote", "add", "origin", fixture.main.path])
            let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Non-local namespace history"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
            _ = try fixture.git(["update-ref", refName, capturedOID])
            _ = try fixture.git(["symbolic-ref", "HEAD", refName], in: fixture.linked)
            let mainHead = try fixture.git(["rev-parse", "HEAD"])
            let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
            let refs = try fixture.git(["show-ref", "--head"])
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let service = try XCTUnwrap(repository.worktreeService)
            await ready(service)
            let controller = PBGitWindowController()
            controller.repository = repository
            await showForegroundWindow(controller)
            defer { controller.close(); service.cancel() }
            let window = try XCTUnwrap(controller.window)
            await waitUntil { controller.historyViewController?.view.window === window }
            let sidebar = try XCTUnwrap(controller.sidebarViewController)
            let groupTitle = refName.hasPrefix("refs/tags/") ? "TAGS" : "REMOTES"
            let normalGroup = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == groupTitle })
            let normalReference = try XCTUnwrap(sourceItems(normalGroup).first { $0.revSpecifier?.simpleRef() == refName })
            XCTAssertFalse(normalReference is PBSourceViewGitWorktreeItem)
            let normalTitle = normalReference.title
            XCTAssertEqual(normalReference.ref()?.ref, refName)
            let worktree = try worktreeItem(in: sidebar, at: fixture.linked.path)
            XCTAssertEqual(worktree.worktree.headRefName, refName)
            XCTAssertNil(worktree.worktree.branchRefName)
            XCTAssertNil(service.worktree(forBranch: refName))
            XCTAssertNil(repository.path(ofWorktreeHolding: normalReference.ref()))
            try selectWorktree(worktree, in: sidebar)
            let selectedItem = try worktreeItem(in: sidebar, at: fixture.linked.path)
            XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, selectedItem.identity)
            let outline = try XCTUnwrap(sidebar.sourceView)
            let selectedRow = outline.row(forItem: selectedItem)
            XCTAssertGreaterThanOrEqual(selectedRow, 0)
            let currentGroup = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == groupTitle })
            let survivingReference = try XCTUnwrap(sourceItems(currentGroup).first { $0.revSpecifier?.simpleRef() == refName })
            XCTAssertFalse(survivingReference is PBSourceViewGitWorktreeItem)
            XCTAssertEqual(survivingReference.title, normalTitle)
            XCTAssertEqual(survivingReference.ref()?.ref, refName)
            let actionButton = try XCTUnwrap(sidebar.value(forKey: "actionButton") as? NSPopUpButton)
            let remoteControls = try XCTUnwrap(sidebar.value(forKey: "remoteControls") as? NSSegmentedControl)
            XCTAssertTrue(actionButton.isEnabled)
            for segment in 1 ... 3 {
                XCTAssertFalse(remoteControls.isEnabled(forSegment: segment))
            }
            let actionMenu = try XCTUnwrap(actionButton.menu)
            sidebar.menuNeedsUpdate(actionMenu)
            for menu in [sidebar.menu(forRow: selectedRow), actionMenu] {
                let applicationItems = applicationMenuItems(menu)
                XCTAssertEqual(applicationItems.count, 5)
                XCTAssertEqual(applicationItems.compactMap(\.action), ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "refreshWorktrees:", "removeWorktree:"].map(NSSelectorFromString))
                for action in applicationItems {
                    if action.action == NSSelectorFromString("refreshWorktrees:") {
                        XCTAssertNil(action.representedObject)
                    } else {
                        XCTAssertEqual((action.representedObject as? PBGitWorktree)?.path, selectedItem.worktree.path)
                    }
                    XCTAssertNil(action.target)
                    XCTAssertTrue(action.isEnabled)
                }
            }
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            try attachScreenshot(of: window, named: "Worktrees-Symbolic-\(groupTitle)-Reference-Preserved")
        }
    }

    func testZeroCapturedWorktreeHeadsKeepUnavailableHistoryAndLocalUnbornReference() async throws {
        for headLength in [40, 64] {
            for symbolicKind in ["detached", "nonlocal", "local-unborn"] {
                let fixture = try Fixture()
                defer { fixture.cleanup() }
                _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
                let mainHead = try fixture.git(["rev-parse", "HEAD"])
                let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
                let refs = try fixture.git(["show-ref", "--head"])
                let repository = try RepositoryTestGitRepository(url: fixture.main)
                let original = try XCTUnwrap(repository.worktreeService)
                await ready(original)
                original.cancel()
                let zeroOID = String(repeating: "0", count: headLength)
                let headField = symbolicKind == "detached" ? "detached" : "branch \(symbolicKind == "nonlocal" ? "refs/gitx/unavailable" : "refs/heads/unborn")"
                let listing = Data("worktree \(fixture.main.path)\0HEAD \(mainHead.trimmingCharacters(in: .whitespacesAndNewlines))\0branch refs/heads/main\0\0worktree \(fixture.linked.path)\0HEAD \(zeroOID)\0\(headField)\0\0".utf8)
                // The immutable discovery fixture models an admitted zero OID
                // without changing any real checkout or administrative file.
                _ = try WorktreeParser.parse(listing)
                let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                    if arguments == ["worktree", "list", "--porcelain", "-z"] {
                        return FixedWorktreeSnapshotTask(data: listing)
                    }
                    let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: fixture.main.path)
                    GitXTestGitFixture.prepare(task)
                    return task
                }
                repository.setValue(service, forKey: "worktreeService")
                service.start()
                await ready(service)
                let controller = PBGitWindowController()
                controller.repository = repository
                await showForegroundWindow(controller)
                defer { controller.close(); service.cancel() }
                let window = try XCTUnwrap(controller.window)
                await waitUntil { controller.historyViewController?.view.window === window }
                let history = try XCTUnwrap(controller.historyViewController)
                let sidebar = try XCTUnwrap(controller.sidebarViewController)
                let item = try worktreeItem(in: sidebar, at: fixture.linked.path)
                XCTAssertEqual(item.worktree.headRefName, symbolicKind == "detached" ? nil : (symbolicKind == "nonlocal" ? "refs/gitx/unavailable" : "refs/heads/unborn"))
                if symbolicKind == "local-unborn" {
                    XCTAssertEqual(item.revSpecifier?.simpleRef(), "refs/heads/unborn")
                    XCTAssertTrue(item.revSpecifier?.isSimpleRef == true)
                } else {
                    XCTAssertNil(item.revSpecifier, "\(symbolicKind) with a \(headLength)-digit zero HEAD must not browse an invalid commit")
                    if item.revSpecifier == nil {
                        let viewedRevision = try XCTUnwrap(repository.currentBranch)
                        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
                        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
                        try selectWorktree(item, in: sidebar)
                        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, item.identity)
                        XCTAssertTrue(repository.currentBranch === viewedRevision)
                        XCTAssertTrue(alternate.view.window === window)
                        XCTAssertNil(history.view.window)
                    }
                }
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            }
        }
    }

    func testReturningToUnavailableCapturedWorktreeKeepsItsOriginAcrossSubsequentSynchronization() async throws {
        let unavailableHeads = [String(repeating: "0", count: 40), String(repeating: "0", count: 64)]
        for unavailableHead in unavailableHeads {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Available captured history"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
            let mainHead = try fixture.git(["rev-parse", "HEAD"])
            let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
            let refs = try fixture.git(["show-ref", "--head"])
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let original = try XCTUnwrap(repository.worktreeService)
            await ready(original)
            original.cancel()
            var listing = try Data(fixture.git(["worktree", "list", "--porcelain", "-z"]).utf8)
            let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                if arguments == ["worktree", "list", "--porcelain", "-z"] {
                    return FixedWorktreeSnapshotTask(data: listing)
                }
                let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: fixture.main.path)
                GitXTestGitFixture.prepare(task)
                return task
            }
            repository.setValue(service, forKey: "worktreeService")
            service.start()
            await ready(service)
            let controller = PBGitWindowController()
            controller.repository = repository
            await showForegroundWindow(controller)
            defer { controller.close(); service.cancel() }
            let window = try XCTUnwrap(controller.window)
            await waitUntil { controller.historyViewController?.view.window === window }
            let history = try XCTUnwrap(controller.historyViewController)
            let sidebar = try XCTUnwrap(controller.sidebarViewController)
            let clicked = try worktreeItem(in: sidebar, at: fixture.linked.path)
            try selectWorktree(clicked, in: sidebar)
            await waitUntil { history.selectedCommits.first?.sha == capturedOID }
            let capturedRevision = try XCTUnwrap(repository.currentBranch)
            let renderingInputs = history.webCommits.map(\.sha)
            let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
            alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
            let unavailableField = "HEAD \(unavailableHead)\0"
            // Admission changes only the captured history projection. The
            // isolated real checkout, registration and references stay intact.
            listing = Data("worktree \(fixture.main.path)\0HEAD \(mainHead.trimmingCharacters(in: .whitespacesAndNewlines))\0branch refs/heads/main\0\0worktree \(fixture.linked.path)\0\(unavailableField)detached\0\0".utf8)
            service.refresh()
            await waitUntil {
                guard let selected = sidebar.selectedItem() as? PBSourceViewGitWorktreeItem else { return false }
                return selected.identity == clicked.identity && selected.revSpecifier == nil
            }
            XCTAssertTrue(repository.currentBranch === capturedRevision)
            XCTAssertTrue(alternate.view.window === window)
            XCTAssertNil(history.view.window)
            let historyAction = NSMenuItem(title: "History", action: NSSelectorFromString("returnToHistory:"), keyEquivalent: "1")
            let action = try XCTUnwrap(historyAction.action)
            XCTAssertTrue(controller.responds(to: action))
            guard controller.responds(to: action) else { continue }
            XCTAssertTrue(NSApp.sendAction(action, to: controller, from: historyAction))
            XCTAssertTrue(history.view.window === window)
            XCTAssertTrue(repository.currentBranch === capturedRevision)
            XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
            _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
            sidebar.selectCurrentBranch()
            XCTAssertTrue(repository.currentBranch === capturedRevision)
            XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
            XCTAssertTrue(alternate.view.window === window)
            XCTAssertNil(history.view.window)
            XCTAssertEqual(history.selectedCommits.first?.sha, capturedOID)
            XCTAssertEqual(history.webCommits.map(\.sha), renderingInputs)
            let others = try XCTUnwrap(sidebar.value(forKey: "others") as? PBSourceViewItem)
            XCTAssertFalse(sourceItems(others).contains { $0.revSpecifier?.isEqual(capturedRevision) == true }, "An unavailable captured HEAD must retain its checkout association without adding the prior revision to Other")
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        }
    }

    func testWorktreeSnapshotRefreshPreservesMountedContentAndBranchSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let window = PBGitWindowController()
        window.repository = repository
        await showForegroundWindow(window)
        defer { window.close(); service.cancel() }
        await waitUntil { window.historyViewController?.view.window === window.window }
        let history = try XCTUnwrap(window.historyViewController)
        let sidebar = try XCTUnwrap(window.sidebarViewController)
        let viewedBranch = repository.currentBranch?.simpleRef()
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), viewedBranch)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let content = try XCTUnwrap(PBViewController(repository: repository, superController: window))
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = window.perform(NSSelectorFromString("changeContentController:"), with: content)
        XCTAssertTrue(content.view.window === window.window)

        _ = try fixture.git(["worktree", "lock", "--reason", "refresh regression", fixture.linked.path])
        service.refresh()
        await waitUntil {
            service.worktree(forBranch: "refs/heads/topic")?.lockReason == "refresh regression"
                && service.inventoryStatus == WorktreeInventoryStatus.fresh.rawValue
        }

        XCTAssertTrue(service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
        XCTAssertTrue(content.view.window === window.window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), viewedBranch)
        XCTAssertEqual(repository.currentBranch?.simpleRef(), viewedBranch)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testFailedWorktreeRefreshShowsAccessibleWarningAndEqualSnapshotRecoveryClearsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let retired = try XCTUnwrap(repository.worktreeService)
        retired.cancel()
        var failsDiscovery = false
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            if failsDiscovery, arguments.first == "worktree" {
                return PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: fixture.main.path)
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["-C", fixture.main.path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
        repository.setValue(service, forKey: "worktreeService")
        service.start()
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === controller.window }
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let initialItems = sidebar.items.map { $0 as AnyObject }
        let groupRow = try XCTUnwrap((0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? PBSourceViewItem)?.title == "WORKTREES" })
        let initialGroup = try XCTUnwrap(outline.item(atRow: groupRow) as? PBSourceViewItem)
        let initialChildren = initialGroup.sortedChildren
        let initialRows = service.worktrees.map(\.path)
        let selection = sidebar.selectedItem()?.revSpecifier?.simpleRef()
        failsDiscovery = true
        service.refresh()
        await waitUntil { service.isSnapshotStale }
        await waitUntil {
            guard let row = (0 ..< outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? PBSourceViewItem)?.title == "WORKTREES" }),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { return false }
            return cell.toolTip?.contains("Refresh Worktrees") == true && cell.imageView?.image != nil
        }
        let builder = PBHistoryMenuBuilder(repository: repository)
        XCTAssertTrue(builder.menuItemsForWorktreeGroup().contains { $0.title == "Refresh Worktrees" && $0.isEnabled })
        XCTAssertEqual(service.worktrees.map(\.path), initialRows)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), selection)
        try attachScreenshot(of: XCTUnwrap(controller.window), named: "Worktrees-Retained-Stale-Snapshot-Warning")
        failsDiscovery = false
        _ = controller.perform(NSSelectorFromString("refreshWorktrees:"), with: nil)
        await waitUntil { !service.isSnapshotStale }
        XCTAssertEqual(service.worktrees.map(\.path), initialRows)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), selection)
        XCTAssertEqual(sidebar.items.count, initialItems.count)
        for (before, after) in zip(initialItems, sidebar.items) {
            XCTAssertTrue(before === after as AnyObject)
        }
        XCTAssertTrue(outline.item(atRow: groupRow) as? PBSourceViewItem === initialGroup)
        XCTAssertEqual(initialGroup.sortedChildren.count, initialChildren.count)
        for (before, after) in zip(initialChildren, initialGroup.sortedChildren) {
            XCTAssertTrue(before === after)
        }
        try attachScreenshot(of: XCTUnwrap(controller.window), named: "Worktrees-Equal-Snapshot-Recovery")
    }

    func testLifecycleUsesGitProtectsLockedWorktreeAndKeepsBranch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        defer { service.cancel() }
        await ready(service)
        let head = try fixture.git(["rev-parse", "HEAD"])
        try await operation(.addNew(path: fixture.linked.path, branch: "topic"), service: service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertFalse(tree.isCurrent)
        XCTAssertTrue(tree.folderExists)
        try await operation(.lock(path: tree.path, reason: "offline disk"), service: service)
        let locked = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertTrue(locked.isLocked)
        XCTAssertEqual(locked.lockReason, "offline disk")
        do { try await operation(.remove(path: tree.path, force: true), service: service); XCTFail("Locked worktree removed") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        try await operation(.unlock(path: tree.path), service: service)
        try "dirty\n".write(to: fixture.linked.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        do { try await operation(.remove(path: tree.path, force: false), service: service); XCTFail("Dirty worktree removed") } catch {
            XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: (error as NSError).localizedFailureReason ?? ""))
        }
        try await operation(.remove(path: tree.path, force: true), service: service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(try fixture.git(["rev-parse", "refs/heads/topic"]).isEmpty)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        let main = try XCTUnwrap(service.worktrees.first(where: \.isMain))
        do { try await operation(.remove(path: main.path, force: true), service: service); XCTFail("Main removed") } catch {}
        try await operation(.pruneReport, service: service)
        try await operation(.prune, service: service)
    }

    func testSidebarBrowsingMenusAndIdentityRestorationDoNotCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let window = PBGitWindowController()
        window.repository = repository
        await showForegroundWindow(window)
        defer { window.close(); service.cancel() }
        await waitUntil { window.historyViewController?.view.window === window.window }
        let sidebar = try XCTUnwrap(window.sidebarViewController)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let roots = sidebar.items.compactMap { $0 as? PBSourceViewItem }
        let branches = try XCTUnwrap(roots.first { $0.title == "BRANCHES" })
        let group = try XCTUnwrap(roots.first { $0.title == "WORKTREES" })
        XCTAssertEqual(roots.firstIndex(of: group), (roots.firstIndex(of: branches) ?? -1) + 1)
        let item = try XCTUnwrap(group.sortedChildren.first as? PBSourceViewGitWorktreeItem)
        XCTAssertEqual(item.title, "topic")
        XCTAssertTrue(outline.isItemExpanded(group))
        XCTAssertEqual(repository.worktrees.count, service.worktrees.count)
        XCTAssertEqual(repository.path(ofWorktreeHolding: PBGitRef(string: "refs/heads/topic")), service.worktree(forBranch: "refs/heads/topic")?.path)
        XCTAssertNil(repository.path(ofWorktreeHolding: nil))
        XCTAssertNil(repository.path(ofWorktreeHolding: PBGitRef(string: "refs/heads/main")))
        let groupMenu = sidebar.menu(forRow: outline.row(forItem: group))
        XCTAssertEqual(groupMenu.items.map(\.title), ["Add Worktree…", "Prune Worktrees…", "Refresh Worktrees"])
        XCTAssertTrue(groupMenu.items[0].isEnabled)
        XCTAssertTrue(groupMenu.items[1].isEnabled)
        XCTAssertEqual(groupMenu.items[1].action, NSSelectorFromString("pruneWorktrees:"))
        let worktreeMenu = sidebar.menu(forRow: outline.row(forItem: item))
        XCTAssertEqual(worktreeMenu.items.first?.title, "Open Worktree of Branch “topic”")
        let rowCell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: item), makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(rowCell.textField?.accessibilityIdentifier(), "RepositoryWorktreeItem")
        XCTAssertTrue(rowCell.textField?.accessibilityHelp()?.contains(item.worktree.path) ?? false)
        XCTAssertFalse(branches.sortedChildren.contains { $0.revSpecifier?.simpleRef() == "refs/heads/topic" })
        let head = try fixture.git(["rev-parse", "HEAD"])
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
        sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        let actions = NSMenu()
        sidebar.menuNeedsUpdate(actions)
        XCTAssertEqual(actions.items.map(\.title), worktreeMenu.items.map(\.title))
        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/topic")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        _ = try fixture.git(["checkout", "-b", "renamed"], in: fixture.linked)
        let published = expectation(description: "sibling branch update")
        let observation = service.observe(\.worktrees) { _, _ in published.fulfill() }
        service.refresh()
        await fulfillment(of: [published], timeout: 5)
        observation.invalidate()
        let selected = try XCTUnwrap(sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)
        XCTAssertEqual(selected.identity, item.identity)
        XCTAssertEqual(selected.title, "renamed")
        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/topic")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        let heldColor = try XCTUnwrap(PBGitRefLabelColors.color(for: PBGitRef(string: "refs/heads/renamed"), repository: repository).usingColorSpace(.genericRGB))
        XCTAssertEqual(heldColor.redComponent, 0x8F / 256.0, accuracy: 0.001)
        XCTAssertEqual(heldColor.greenComponent, 0xE0 / 256.0, accuracy: 0.001)
        XCTAssertEqual(heldColor.blueComponent, 0xD5 / 256.0, accuracy: 0.001)
        let builder = PBHistoryMenuBuilder(repository: repository)
        let menu = try XCTUnwrap(builder.menuItems(for: PBGitRef(string: "refs/heads/renamed")))
        XCTAssertTrue(menu.contains { $0.title.hasPrefix("Open Worktree of Branch") && $0.isEnabled })
        XCTAssertFalse(menu.contains { $0.title.hasPrefix("Checkout “") })
        XCTAssertTrue(menu.contains { $0.title == "Remove Worktree…" })
        XCTAssertEqual(builder.menuItemsForWorktreeGroup().first?.title, "Add Worktree…")
        XCTAssertFalse(try builder.menuItems(forWorktree: XCTUnwrap(service.worktrees.first(where: \.isMain))).last?.isEnabled ?? true)
        try attachScreenshot(of: outline, named: "Worktrees-AppKit-Selected-Identity")
    }

    func testWrongFolderRepairLeavesForeignRepositoryLinksAlone() async throws {
        let fixture = try Fixture()
        let foreign = try Fixture()
        defer { fixture.cleanup(); foreign.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        _ = try foreign.git(["worktree", "add", "-b", "topic", foreign.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        defer { service.cancel() }
        await ready(service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let link = foreign.linked.appendingPathComponent(".git")
        let original = try Data(contentsOf: link)
        do {
            try await service.repair(worktree: tree, movedTo: foreign.linked.path)
            XCTFail("Wrong folder was accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: link), original)
        XCTAssertNotNil(service.worktree(forBranch: "refs/heads/topic"))
    }

    func testSiblingHeadRefreshesBothWindowsWithoutLocalIndexEvent() async throws {
        let fixture = try Fixture()
        let defaults = UserDefaults.standard
        let oldWatch = defaults.object(forKey: "PBUseRepositoryWatcher")
        let oldFocus = defaults.object(forKey: "PBRefreshOnApplicationFocus")
        defaults.set(true, forKey: "PBUseRepositoryWatcher")
        defaults.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer {
            defaults.set(oldWatch, forKey: "PBUseRepositoryWatcher")
            defaults.set(oldFocus, forKey: "PBRefreshOnApplicationFocus")
            fixture.cleanup()
        }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let main = try RepositoryTestGitRepository(url: fixture.main)
        let linked = try RepositoryTestGitRepository(url: fixture.linked)
        let mainService = try XCTUnwrap(main.worktreeService)
        let linkedService = try XCTUnwrap(linked.worktreeService)
        await ready(mainService); await ready(linkedService)
        let windows = [main, linked].map { repository in
            let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil); return controller
        }
        defer { windows.forEach { $0.close() }; mainService.cancel(); linkedService.cancel() }
        let mainUpdate = expectation(description: "main window sees sibling HEAD")
        let linkedUpdate = expectation(description: "linked window sees its HEAD")
        var sawMain = false
        var sawLinked = false
        let mainObservation = mainService.observe(\.worktrees) { [weak mainService] _, _ in
            // swift6-safety-justification: Worktree snapshot KVO is published on the main thread by the service.
            MainActor.assumeIsolated {
                if !sawMain, mainService?.worktrees.contains(where: { $0.branchRefName == "refs/heads/changed" }) == true {
                    sawMain = true; mainUpdate.fulfill()
                }
            }
        }
        let linkedObservation = linkedService.observe(\.worktrees) { [weak linkedService] _, _ in
            // swift6-safety-justification: Worktree snapshot KVO is published on the main thread by the service.
            MainActor.assumeIsolated {
                if !sawLinked, linkedService?.worktrees.contains(where: { $0.branchRefName == "refs/heads/changed" }) == true {
                    sawLinked = true; linkedUpdate.fulfill()
                }
            }
        }
        let notification = NotificationCenter.default.addObserver(forName: .PBGitRepositoryEvent, object: main, queue: .main) { event in
            let flags = (event.userInfo?[kPBGitRepositoryEventTypeUserInfoKey] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(flags & 8, 0, "Sibling Git changes must not publish the main checkout's index event")
        }
        defer { mainObservation.invalidate(); linkedObservation.invalidate(); NotificationCenter.default.removeObserver(notification) }
        let before = try fixture.git(["rev-parse", "HEAD"])
        _ = try fixture.git(["checkout", "-b", "changed"], in: fixture.linked)
        await fulfillment(of: [mainUpdate, linkedUpdate], timeout: 15)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), before)
        XCTAssertEqual(main.currentBranch?.simpleRef(), "refs/heads/main")
        attachScreenshot(of: windows[0].window?.contentView, named: "Worktrees-Cross-Window-Main")
        attachScreenshot(of: windows[1].window?.contentView, named: "Worktrees-Cross-Window-Linked")
    }

    func testLockRemovalAndPruneSheetsRequireTheirOwnConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let item = NSMenuItem(); item.representedObject = tree
        controller.lockWorktree(item)
        var sheet = try await waitForSheet(in: window, containing: "Lock")
        try attachScreenshot(of: sheet, named: "Worktrees-Lock-Reason-Sheet")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(service.worktree(forBranch: "refs/heads/topic")?.isLocked ?? true)
        controller.lockWorktree(item)
        sheet = try await waitForSheet(in: window, containing: "Lock")
        let field = try XCTUnwrap(descendants(sheet.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Reason (optional)" })
        field.stringValue = "offline disk"
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { service.worktree(forBranch: "refs/heads/topic")?.isLocked == true }
        let locked = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertEqual(locked.lockReason, "offline disk")
        item.representedObject = locked
        controller.removeWorktree(item)
        XCTAssertNil(window.attachedSheet)
        controller.unlockWorktree(item)
        await waitUntil { service.worktree(forBranch: "refs/heads/topic")?.isLocked == false }
        item.representedObject = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        try "dirty\n".write(to: fixture.linked.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        controller.removeWorktree(item)
        sheet = try await waitForSheet(in: window)
        try attachScreenshot(of: sheet, named: "Worktrees-Remove-Confirmation-Sheet")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        controller.removeWorktree(item)
        sheet = try await waitForSheet(in: window)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        sheet = try await waitForSheet(in: window, containing: "Remove Anyway")
        try attachScreenshot(of: sheet, named: "Worktrees-Force-Confirmation-Sheet")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        controller.removeWorktree(item)
        sheet = try await waitForSheet(in: window)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        sheet = try await waitForSheet(in: window, containing: "Remove Anyway")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { service.worktree(forBranch: "refs/heads/topic") == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(try fixture.git(["rev-parse", "refs/heads/topic"]).isEmpty)
        controller.pruneWorktrees(nil)
        sheet = try await waitForSheet(in: window, containing: "Nothing to prune")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        try await operation(.addExisting(path: fixture.linked.path, branch: "topic"), service: service)
        try FileManager.default.removeItem(at: fixture.linked)
        controller.pruneWorktrees(nil)
        sheet = try await waitForSheet(in: window, containing: "Prune these worktrees?")
        XCTAssertTrue(descendants(sheet.contentView).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("linked") })
        try attachScreenshot(of: sheet, named: "Worktrees-Prune-Dry-Run-Sheet")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertNotNil(service.worktree(forBranch: "refs/heads/topic"))
        controller.pruneWorktrees(nil)
        sheet = try await waitForSheet(in: window)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { service.worktree(forBranch: "refs/heads/topic") == nil }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        item.representedObject = try XCTUnwrap(service.worktrees.first(where: \.isMain))
        controller.removeWorktree(item); controller.lockWorktree(item); controller.unlockWorktree(item)
        XCTAssertNil(window.attachedSheet)
        item.representedObject = nil
        controller.removeWorktree(item); controller.lockWorktree(item); controller.openWorktree(item)
        XCTAssertNil(window.attachedSheet)
    }

    func testMovedNestedRepairIsOfferedOnceAndBlocksPruneUntilVerified() async throws {
        let fixture = try Fixture()
        let nested = fixture.main.appendingPathComponent("nested")
        _ = try fixture.git(["worktree", "add", "-b", "nested", nested.path])
        let moved = fixture.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: moved) }
        let movedMain = moved.appendingPathComponent("main")
        let repository = try RepositoryTestGitRepository(url: movedMain)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        XCTAssertTrue(service.worktrees.contains { $0.hasBrokenLink })
        XCTAssertNotNil(service.worktree(forBranch: "refs/heads/nested")?.movedPath)
        let repairMenu = try PBHistoryMenuBuilder(repository: repository).menuItems(forWorktree: XCTUnwrap(service.worktree(forBranch: "refs/heads/nested")))
        XCTAssertTrue(repairMenu.contains { $0.title == "Repair Worktree Links…" && $0.isEnabled })
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        var sheet = try await waitForSheet(in: window, containing: "Absolute Paths")
        XCTAssertEqual(window.attachedSheet?.defaultButtonCell?.title, "Absolute Paths")
        try attachScreenshot(of: sheet, named: "Worktrees-Moved-Nested-Repair-Sheet")
        window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        controller.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        service.refresh()
        await Task.yield()
        XCTAssertNil(window.attachedSheet)
        controller.pruneWorktrees(nil)
        sheet = try await waitForSheet(in: window, containing: "Relative Paths")
        XCTAssertFalse(descendants(sheet.contentView).compactMap { $0 as? NSButton }.contains { $0.title == "Prune" })
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        sheet = try await waitForSheet(in: window, containing: "Repair these worktree links?")
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Cancel")
        XCTAssertTrue(sheetText(sheet).contains(WorktreePaths.canonical(movedMain.appendingPathComponent("nested").path)))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { !service.worktrees.contains { $0.hasBrokenLink } }
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/nested")?.path, WorktreePaths.canonical(movedMain.appendingPathComponent("nested").path))
        let link = try String(contentsOf: movedMain.appendingPathComponent("nested/.git"), encoding: .utf8)
        XCTAssertTrue(link.hasPrefix("gitdir: ../"))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: movedMain), "refs/heads/main\n")
    }

    func testLocatingMovedCheckoutAndCopiedRepositoryProtection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        defer { service.cancel() }
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let moved = fixture.root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: fixture.linked, to: moved)
        try await service.repair(worktree: tree, movedTo: moved.path)
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.path, WorktreePaths.canonical(moved.path))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: moved), "refs/heads/topic\n")
        let copy = fixture.root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: fixture.main, to: copy)
        let copiedRepository = try RepositoryTestGitRepository(url: copy)
        let copiedService = try XCTUnwrap(copiedRepository.worktreeService)
        defer { copiedService.cancel() }
        await ready(copiedService)
        let original = try Data(contentsOf: moved.appendingPathComponent(".git"))
        do { try await copiedService.repairLinks(relativePaths: true); XCTFail("Copy changed foreign links") } catch {}
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(".git")), original)
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.path, WorktreePaths.canonical(moved.path))
    }

    func testSelectedGitPreferenceIsRecheckedWithoutChangingAppMinimum() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let oldGit = fixture.root.appendingPathComponent("old-git")
        try "#!/bin/sh\nfor arg in \"$@\"; do\nif [ \"$arg\" = --version ]; then echo 'git version 2.47.9'; exit 0; fi\ndone\nexec /usr/bin/git \"$@\"\n".write(to: oldGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldGit.path)
        defaults.set(oldGit.path, forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitUntil { service.gitVersion == "git version 2.47.9" }
        XCTAssertFalse(service.isSupported)
        let disabled = PBHistoryMenuBuilder(repository: repository).menuItemsForWorktreeGroup()
        XCTAssertFalse(disabled[0].isEnabled)
        XCTAssertTrue(disabled[0].toolTip?.contains("Git 2.48") ?? false)
        defaults.set(fixture.root.appendingPathComponent("missing-git").path, forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitUntil { service.gitVersion == nil && !service.isSupported }
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitUntil { service.isSupported }
        XCTAssertEqual(service.worktrees.count, 1)
        XCTAssertTrue(PBHistoryMenuBuilder(repository: repository).menuItemsForWorktreeGroup()[0].isEnabled)
    }

    func testAddAndLocateFolderSheetsUseUpstreamSuggestionsAndCancelSafely() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["branch", "feature/topic"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        controller.addWorktree(nil)
        var sheet = try await waitForSheet(in: window)
        try attachScreenshot(of: sheet, named: "Worktrees-New-Branch-Sheet")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(service.worktrees.count, 1)
        controller.addWorktree(nil)
        sheet = try await waitForSheet(in: window)
        let field = try XCTUnwrap(descendants(sheet.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Branch name" })
        field.stringValue = "  new/topic  "
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet is NSSavePanel }
        let newPanel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertEqual(newPanel.nameFieldStringValue, "main-new-topic")
        XCTAssertEqual(newPanel.directoryURL?.resolvingSymlinksInPath(), fixture.root.resolvingSymlinksInPath())
        try attachScreenshot(of: newPanel, named: "Worktrees-New-Folder-Sheet")
        window.endSheet(newPanel, returnCode: .cancel)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(service.worktrees.count, 1)
        let item = NSMenuItem(); item.representedObject = PBGitRef(string: "refs/heads/feature/topic")
        controller.checkOutInNewWorktree(item)
        await waitUntil { window.attachedSheet is NSSavePanel }
        let existingPanel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertEqual(existingPanel.nameFieldStringValue, "main-feature-topic")
        window.endSheet(existingPanel, returnCode: .cancel)
        await waitUntil { window.attachedSheet == nil }
        item.representedObject = repository.headRef()
        controller.checkOutInNewWorktree(item)
        XCTAssertNil(window.attachedSheet)
        try await operation(.addExisting(path: fixture.linked.path, branch: "feature/topic"), service: service)
        item.representedObject = PBGitRef(string: "refs/heads/feature/topic")
        controller.checkOutInNewWorktree(item)
        XCTAssertNil(window.attachedSheet)
        try FileManager.default.removeItem(at: fixture.linked)
        service.refresh()
        await waitUntil { service.worktree(forBranch: "refs/heads/feature/topic")?.folderExists == false }
        item.representedObject = try XCTUnwrap(service.worktree(forBranch: "refs/heads/feature/topic"))
        let locateMenu = try PBHistoryMenuBuilder(repository: repository).menuItems(forWorktree: XCTUnwrap(service.worktree(forBranch: "refs/heads/feature/topic")))
        XCTAssertTrue(locateMenu.contains { $0.title == "Locate Worktree Folder…" && $0.isEnabled })
        XCTAssertTrue(locateMenu.first?.isEnabled ?? false, "Opening an unavailable worktree offers its locate flow")
        controller.openWorktree(item)
        sheet = try await waitForSheet(in: window, containing: "Locate Folder…")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet is NSOpenPanel }
        let locate = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(locate.canChooseDirectories)
        XCTAssertFalse(locate.canChooseFiles)
        XCTAssertEqual(locate.directoryURL?.resolvingSymlinksInPath(), fixture.root.resolvingSymlinksInPath())
        try attachScreenshot(of: locate, named: "Worktrees-Locate-Folder-Sheet")
        window.endSheet(locate, returnCode: .cancel)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertNotNil(service.worktree(forBranch: "refs/heads/feature/topic"))
    }

    func testOpeningHeldBranchActivatesItsDocumentWithoutCheckingOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        _ = try fixture.git(["commit", "--allow-empty", "-m", "topic history"], in: fixture.linked)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let topicHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        var opened: PBGitRepositoryDocument?
        defer { opened?.close(); controller.close(); service.cancel() }
        let item = NSMenuItem(); item.representedObject = PBGitRef(string: "refs/heads/topic")
        repository.currentBranch = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/topic"))
        await waitUntil { controller.historyViewController?.view.window === controller.window }
        let history = try XCTUnwrap(controller.historyViewController)
        let topicSHA = topicHead.trimmingCharacters(in: .whitespacesAndNewlines)
        await waitUntil { (history.commitController.arrangedObjects as? [PBGitCommit])?.contains { $0.sha == topicSHA && ($0.refs?.count ?? 0) > 0 } == true }
        let commits = try XCTUnwrap(history.commitController.arrangedObjects as? [PBGitCommit])
        let row = try XCTUnwrap(commits.firstIndex { $0.sha == topicSHA })
        let referenceIndex = try XCTUnwrap((commits[row].refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.firstIndex { $0.ref == "refs/heads/topic" })
        let table = WorktreeCommitListFake(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        table.testRow = row; table.revisionCell.referenceIndex = Int32(referenceIndex)
        let interactions = try XCTUnwrap(history.commitList.delegate as? PBHistoryTableInteractionCoordinator)
        interactions.didDoubleClickCommitList(table)
        await waitUntil {
            opened = NSDocumentController.shared.documents.compactMap { $0 as? PBGitRepositoryDocument }.first {
                $0.repository.workingDirectoryURL()?.resolvingSymlinksInPath() == fixture.linked.resolvingSymlinksInPath()
            }
            return opened?.windowController()?.window?.isVisible == true
        }
        let document = try XCTUnwrap(opened)
        let openedWindow = try XCTUnwrap(document.windowController()?.window)
        await waitUntil { document.windowController()?.historyViewController?.view.window === openedWindow }
        try attachScreenshot(of: openedWindow, named: "Worktrees-Held-Branch-Opened-Document")
        item.representedObject = service.worktree(forBranch: "refs/heads/topic")
        controller.openWorktree(item)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let group = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        let rowItem = try XCTUnwrap(group.sortedChildren.first as? PBSourceViewGitWorktreeItem)
        let outline = try XCTUnwrap(sidebar.sourceView)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: rowItem)), byExtendingSelection: false)
        sidebar.doubleClicked(sidebar)
        await Task.yield()
        XCTAssertEqual(NSDocumentController.shared.documents.filter { $0 === document }.count, 1)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), topicHead)
        XCTAssertEqual(document.repository.headRef()?.simpleRef(), "refs/heads/topic")
    }

    func testCreatingWorktreesThroughFolderSheetsUsesExistingBranchAndActualHEAD() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        let existingHead = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "existing branch history"])
        _ = try fixture.git(["branch", "existing/topic", existingHead.trimmingCharacters(in: .whitespacesAndNewlines)])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController(); controller.repository = repository; await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        let item = NSMenuItem(); item.representedObject = PBGitRef(string: "refs/heads/existing/topic")
        controller.checkOutInNewWorktree(item)
        await waitUntil { window.attachedSheet is NSSavePanel }
        let existingPanel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertEqual(existingPanel.nameFieldStringValue, "main-existing-topic")
        XCTAssertEqual(existingPanel.url?.lastPathComponent, "main-existing-topic")
        window.endSheet(existingPanel, returnCode: .OK)
        await waitUntil { service.worktree(forBranch: "refs/heads/existing/topic") != nil && window.attachedSheet == nil }
        let existing = try XCTUnwrap(service.worktree(forBranch: "refs/heads/existing/topic"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: existing.path)), existingHead)
        repository.currentBranch = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/existing/topic"))
        controller.addWorktree(nil)
        let alert = try await waitForSheet(in: window)
        let field = try XCTUnwrap(descendants(alert.contentView).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Branch name" })
        field.stringValue = "new/topic"
        window.endSheet(alert, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet is NSSavePanel }
        let newPanel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertEqual(newPanel.nameFieldStringValue, "main-new-topic")
        XCTAssertEqual(newPanel.url?.lastPathComponent, "main-new-topic")
        window.endSheet(newPanel, returnCode: .OK)
        await waitUntil { service.worktree(forBranch: "refs/heads/new/topic") != nil && window.attachedSheet == nil }
        let created = try XCTUnwrap(service.worktree(forBranch: "refs/heads/new/topic"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: created.path)), head)
        XCTAssertNotEqual(existingHead, head)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(repository.currentBranch?.simpleRef(), "refs/heads/existing/topic")
        try attachScreenshot(of: window, named: "Worktrees-Created-Through-Folder-Sheets")
    }

    func testBareMainWorktreeSelectionPreservesViewedRevisionAndReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let bare = fixture.root.appendingPathComponent("bare.git")
        _ = try fixture.git(["clone", "--bare", fixture.main.path, bare.path])
        _ = try fixture.git(["worktree", "add", "-b", "bare-topic", fixture.linked.path, "main"], in: bare)
        let bareRefs = try fixture.git(["show-ref", "--head"], in: bare)
        let linkedRefs = try fixture.git(["show-ref", "--head"], in: fixture.linked)
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let linkedBranch = try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked)
        let repository = try RepositoryTestGitRepository(url: fixture.linked)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let bareItem = try worktreeItem(in: sidebar, at: bare.path)
        XCTAssertEqual(bareItem.title, "Bare repository")
        XCTAssertTrue(bareItem.worktree.isMain)
        XCTAssertNil(bareItem.worktree.branchRefName)
        XCTAssertNil(bareItem.revSpecifier)
        let viewedRevision = try XCTUnwrap(repository.currentBranch)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)

        try selectWorktree(bareItem, in: sidebar)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, bareItem.identity)
        XCTAssertTrue(repository.currentBranch === viewedRevision)
        XCTAssertTrue(alternate.view.window === window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: bare), bareRefs)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: fixture.linked), linkedRefs)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked), linkedBranch)
        let historyAction = NSMenuItem(title: "History", action: NSSelectorFromString("returnToHistory:"), keyEquivalent: "1")
        let action = try XCTUnwrap(historyAction.action)
        XCTAssertTrue(controller.responds(to: action))
        XCTAssertTrue(NSApp.sendAction(action, to: controller, from: historyAction))
        XCTAssertTrue(history.view.window === window)
        XCTAssertNil(alternate.view.window)
        XCTAssertTrue(repository.currentBranch === viewedRevision)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, bareItem.identity)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: bare), bareRefs)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: fixture.linked), linkedRefs)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked), linkedBranch)
    }

    func testDetachedWorktreeSelectionLoadsCapturedHistoryWithoutCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let detachedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Detached-only history"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, detachedOID])
        let detachedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        XCTAssertNotEqual(detachedHead, mainHead)
        XCTAssertFalse(try fixture.git(["for-each-ref", "--format=%(objectname)"]).split(separator: "\n").contains(Substring(detachedOID)))

        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let item = try worktreeItem(in: sidebar, at: fixture.linked.path)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        XCTAssertTrue(alternate.view.window === window)

        try selectWorktree(item, in: sidebar)
        XCTAssertTrue(history.view.window === window)
        XCTAssertNil(alternate.view.window)
        await waitUntil {
            (history.commitController.arrangedObjects as? [PBGitCommit])?.contains { $0.sha == detachedOID } == true
                && history.selectedCommits.first?.sha == detachedOID
        }
        let commits = try XCTUnwrap(history.commitController.arrangedObjects as? [PBGitCommit])
        XCTAssertTrue(commits.contains { $0.sha == detachedOID })
        XCTAssertEqual(history.selectedCommits.first?.sha, detachedOID)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, item.identity)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), detachedHead)
        await waitUntil {
            self.descendants(history.view).compactMap { $0 as? NSTextView }.contains {
                $0.accessibilityIdentifier() == "NativeContentText"
                    && $0.string.contains("Detached-only history")
                    && !$0.string.contains("Loading diff…")
            }
        }
        try attachScreenshot(of: window, named: "Worktrees-Detached-Captured-History")
    }

    func testDetachedWorktreesAtSameCommitPreserveClickedIdentityOnRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let second = fixture.root.appendingPathComponent("second-detached")
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let detachedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Shared detached history"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, detachedOID])
        _ = try fixture.git(["worktree", "add", "--detach", second.path, detachedOID])
        let detachedHead = try fixture.git(["rev-parse", "HEAD"], in: second)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let group = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        let rows = group.sortedChildren.compactMap { $0 as? PBSourceViewGitWorktreeItem }
        XCTAssertEqual(rows.count, 2)
        let sharedRevision = try XCTUnwrap(rows.first?.revSpecifier)
        let defaultMatch = try XCTUnwrap(group.findRev(sharedRevision) as? PBSourceViewGitWorktreeItem)
        let clicked = try XCTUnwrap(rows.first { $0.identity != defaultMatch.identity })

        try selectWorktree(clicked, in: sidebar)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        await waitUntil { history.selectedCommits.first?.sha == detachedOID }
        let capturedRevision = try XCTUnwrap(repository.currentBranch)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        _ = try fixture.git(["worktree", "lock", "--reason", "passive refresh", defaultMatch.worktree.path])
        service.refresh()
        await waitUntil { service.worktrees.first { $0.path == defaultMatch.worktree.path }?.isLocked == true }

        XCTAssertTrue(alternate.view.window === window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        XCTAssertTrue(repository.currentBranch?.isEqual(capturedRevision) == true)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), detachedHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: second), detachedHead)
        try attachScreenshot(of: XCTUnwrap(sidebar.sourceView), named: "Worktrees-Detached-Same-OID-Identity")
    }

    func testChangedPruneCandidatesRequireRenewedSheetConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unapproved = fixture.root.appendingPathComponent("unapproved")
        let moved = fixture.root.appendingPathComponent("saved-unapproved")
        _ = try fixture.git(["worktree", "add", "-b", "approved", fixture.linked.path])
        _ = try fixture.git(["worktree", "add", "-b", "unapproved", unapproved.path])
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let unapprovedHead = try fixture.git(["rev-parse", "HEAD"], in: unapproved)
        let approvedAdmin = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let unapprovedAdmin = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: unapproved)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let approvedBacklink = try Data(contentsOf: approvedAdmin.appendingPathComponent("gitdir"))
        let unapprovedBacklink = try Data(contentsOf: unapprovedAdmin.appendingPathComponent("gitdir"))
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        try FileManager.default.removeItem(at: fixture.linked)
        controller.pruneWorktrees(nil)
        let initial = try await waitForSheet(in: window, containing: "Prune")
        XCTAssertTrue(sheetText(initial).contains(approvedAdmin.lastPathComponent))
        XCTAssertFalse(sheetText(initial).contains(unapprovedAdmin.lastPathComponent))
        try attachScreenshot(of: initial, named: "Worktrees-Prune-Original-Preview")
        try FileManager.default.moveItem(at: unapproved, to: moved)

        window.endSheet(initial, returnCode: .alertFirstButtonReturn)
        await waitUntil {
            guard let updated = window.attachedSheet, updated !== initial else { return false }
            return self.sheetText(updated).contains(unapprovedAdmin.lastPathComponent)
                && self.descendants(updated.contentView).contains { ($0 as? NSButton)?.title == "Prune" }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: approvedAdmin.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unapprovedAdmin.path))
        XCTAssertEqual(try Data(contentsOf: approvedAdmin.appendingPathComponent("gitdir")), approvedBacklink)
        XCTAssertEqual(try Data(contentsOf: unapprovedAdmin.appendingPathComponent("gitdir")), unapprovedBacklink)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: moved), unapprovedHead)
        let updated = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(updated === initial)
        try attachScreenshot(of: updated, named: "Worktrees-Prune-Renewed-Confirmation")
        window.endSheet(updated, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: approvedAdmin.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unapprovedAdmin.path))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: moved), unapprovedHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)

        await showForegroundWindow(controller)
        controller.pruneWorktrees(nil)
        let current = try await waitForSheet(in: window, containing: "Prune")
        XCTAssertTrue(sheetText(current).contains(unapprovedAdmin.lastPathComponent))
        window.endSheet(current, returnCode: .alertFirstButtonReturn)
        await waitUntil {
            !FileManager.default.fileExists(atPath: approvedAdmin.path)
                && !FileManager.default.fileExists(atPath: unapprovedAdmin.path)
                && window.attachedSheet == nil
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
    }

    func testMovedWorktreeWithManagedGitfileSymlinkRequiresManualRepairAndBlocksPrune() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let nested = fixture.main.appendingPathComponent("nested")
        let movedMain = fixture.root.appendingPathComponent("moved-main")
        let movedNested = movedMain.appendingPathComponent("nested")
        let managedGitfile = fixture.root.appendingPathComponent("managed-gitfile")
        _ = try fixture.git(["worktree", "add", "-b", "nested", nested.path])
        let originalAdministrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: nested).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(originalAdministrative)
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let refs = try fixture.git(["show-ref", "--head"])
        let gitfile = nested.appendingPathComponent(".git")
        let originalGitfile = try Data(contentsOf: gitfile)
        try FileManager.default.moveItem(at: gitfile, to: managedGitfile)
        try FileManager.default.createSymbolicLink(at: gitfile, withDestinationURL: managedGitfile)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: gitfile.path)
        try FileManager.default.moveItem(at: fixture.main, to: movedMain)
        let administrativeSuffix = String(originalAdministrative.path.dropFirst(WorktreePaths.canonical(fixture.main.path).count + 1))
        let administrative = movedMain.appendingPathComponent(administrativeSuffix)
        let movedGitfile = movedNested.appendingPathComponent(".git")
        let repository = try RepositoryTestGitRepository(url: movedMain)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let worktree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/nested"))
        XCTAssertEqual(worktree.movedPath.map(WorktreePaths.canonical), WorktreePaths.canonical(movedNested.path))
        XCTAssertFalse(worktree.hasBrokenLink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalAdministrative.path))
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        await drainPruneCallbacks()
        XCTAssertNil(window.attachedSheet)
        if let unexpectedOffer = window.attachedSheet {
            // Keep the red run from confirming a repair it is rejecting.
            window.endSheet(unexpectedOffer, returnCode: .alertThirdButtonReturn)
            await waitUntil { window.attachedSheet == nil }
        }

        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let manualRow = try worktreeItem(in: sidebar, at: worktree.path)
        try selectWorktree(manualRow, in: sidebar)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let actionMenu = try XCTUnwrap((sidebar.value(forKey: "actionButton") as? NSPopUpButton)?.menu)
        let selectedRow = try worktreeItem(in: sidebar, at: worktree.path)
        let rowNumber = outline.row(forItem: selectedRow)
        XCTAssertGreaterThanOrEqual(rowNumber, 0)
        let rowContext = autoreleasepool { sidebar.menu(forRow: rowNumber) }
        autoreleasepool { sidebar.menuNeedsUpdate(actionMenu) }
        var guidanceToDispatch: NSMenuItem?
        for menu in [rowContext, actionMenu] {
            let guidance = menu.items.filter { $0.title == "Show Link Repair Guidance…" }
            XCTAssertEqual(guidance.count, 1, "A moved unsupported link needs an enabled recovery route")
            if let item = guidance.first {
                XCTAssertTrue(item.isEnabled)
                XCTAssertEqual(item.action, NSSelectorFromString("repairWorktreeLinks:"))
                XCTAssertEqual((item.representedObject as? PBGitWorktree)?.path, worktree.path)
                XCTAssertNil(item.target)
                guidanceToDispatch = item
            }
        }
        let group = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        let groupNumber = outline.row(forItem: group)
        XCTAssertGreaterThanOrEqual(groupNumber, 0)
        let groupContext = autoreleasepool { sidebar.menu(forRow: groupNumber) }
        for menu in [groupContext] {
            let guidance = menu.items.filter { $0.title == "Show Link Repair Guidance…" }
            XCTAssertEqual(guidance.count, 1)
            if let item = guidance.first {
                XCTAssertTrue(item.isEnabled)
                XCTAssertEqual(item.action, NSSelectorFromString("repairWorktreeLinks:"))
                XCTAssertNil(item.target)
                guidanceToDispatch = item
            }
            let prune = try XCTUnwrap(menu.items.first { $0.title == "Prune Worktrees…" })
            XCTAssertFalse(prune.isEnabled, "Manual recovery does not authorize pruning moved registration evidence")
        }
        if let guidanceToDispatch {
            XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(guidanceToDispatch.action), to: controller, from: guidanceToDispatch))
            let guidance = try await waitForSheet(in: window)
            XCTAssertTrue(sheetText(guidance).contains("A moved worktree needs manual link repair"))
            XCTAssertTrue(sheetText(guidance).contains(WorktreePaths.canonical(movedNested.path)))
            XCTAssertFalse(descendants(guidance.contentView).contains { ($0 as? NSButton)?.title == "Absolute Paths" || ($0 as? NSButton)?.title == "Prune" })
            try attachScreenshot(of: guidance, named: "Worktrees-Manual-Symlink-Menu-Guidance")
            window.endSheet(guidance, returnCode: .alertFirstButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: movedGitfile.path), destination)
            XCTAssertEqual(try Data(contentsOf: managedGitfile), originalGitfile)
            XCTAssertEqual(try registrationMetadata(administrative), metadata)
        }

        for pruning in [false, true] {
            if pruning {
                controller.pruneWorktrees(nil)
            } else {
                controller.repairWorktreeLinks(nil)
            }
            let notice = try await waitForSheet(in: window)
            let text = sheetText(notice)
            XCTAssertTrue(text.contains("A moved worktree needs manual link repair"))
            XCTAssertTrue(text.contains("Its .git link cannot be replaced safely. Restore a regular Git link file before repairing or pruning:"))
            XCTAssertTrue(text.contains(WorktreePaths.canonical(movedNested.path)))
            let buttons = descendants(notice.contentView).compactMap { $0 as? NSButton }.map(\.title)
            XCTAssertFalse(buttons.contains("Absolute Paths"))
            XCTAssertFalse(buttons.contains("Relative Paths"))
            XCTAssertFalse(buttons.contains("Prune"))
            try attachScreenshot(of: notice, named: pruning ? "Worktrees-Moved-Symlink-Prune-Blocked" : "Worktrees-Moved-Symlink-Manual-Repair")
            window.endSheet(notice, returnCode: buttons.contains("Skip Repair") ? .alertThirdButtonReturn : .alertFirstButtonReturn)
            await waitUntil { window.attachedSheet == nil }

            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: movedGitfile.path), destination)
            XCTAssertEqual(try Data(contentsOf: managedGitfile), originalGitfile)
            XCTAssertEqual(try Data(contentsOf: movedGitfile), originalGitfile)
            XCTAssertEqual(try registrationMetadata(administrative), metadata)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: movedMain), mainHead)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: movedMain), refs)
            XCTAssertEqual(service.worktree(forBranch: "refs/heads/nested")?.movedPath.map(WorktreePaths.canonical), WorktreePaths.canonical(movedNested.path))
        }
    }

    func testMissingWorktreeGitFileOffersSameLocationRepairWithoutCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let mainHead = try fixture.git(["rev-parse", "HEAD"])
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let originalHead = try Data(contentsOf: administrative.appendingPathComponent("HEAD"))
        let originalBacklink = try Data(contentsOf: administrative.appendingPathComponent("gitdir"))
        let link = fixture.linked.appendingPathComponent(".git")
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        defer { controller.close(); service.cancel() }
        let window = try XCTUnwrap(controller.window)
        await waitUntil { controller.historyViewController?.view.window === window }
        try FileManager.default.removeItem(at: link)
        service.refresh()
        await waitUntil {
            service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true
        }
        let broken = try XCTUnwrap(service.worktrees.first { $0.path == WorktreePaths.canonical(fixture.linked.path) && $0.hasBrokenLink })
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let row = try worktreeItem(in: sidebar, at: fixture.linked.path)
        let outline = try XCTUnwrap(sidebar.sourceView)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: row), makeIfNecessary: true) as? NSTableCellView)
        XCTAssertTrue(cell.textField?.accessibilityHelp()?.contains("Broken repository link") == true)
        let automatic = try await waitForSheet(in: window, containing: "Skip Repair")
        XCTAssertFalse(sheetText(automatic).contains("repository was moved"))
        try attachScreenshot(of: automatic, named: "Worktrees-Missing-Link-Repair-Offer")
        window.endSheet(automatic, returnCode: .alertThirdButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("HEAD")), originalHead)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("gitdir")), originalBacklink)

        let item = NSMenuItem()
        item.representedObject = broken
        controller.openWorktree(item)
        let explicit = try await waitForSheet(in: window, containing: "Absolute Paths")
        XCTAssertFalse(sheetText(explicit).contains("repository was moved"))
        XCTAssertTrue(sheetText(explicit).contains(fixture.linked.path))
        window.endSheet(explicit, returnCode: .alertFirstButtonReturn)
        let reclaim = try await waitForSheet(in: window, containing: "Reclaim")
        XCTAssertTrue(sheetText(reclaim).contains(fixture.linked.path))
        window.endSheet(reclaim, returnCode: .alertFirstButtonReturn)
        await waitUntil {
            FileManager.default.fileExists(atPath: link.path)
                && service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == false
                && window.attachedSheet == nil
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked)
            .trimmingCharacters(in: .whitespacesAndNewlines), WorktreePaths.canonical(administrative.path))
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("HEAD")), originalHead)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("gitdir")), originalBacklink)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), mainHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
        try attachScreenshot(of: window, named: "Worktrees-Missing-Link-Repaired")
    }

    func testHistoryReturnKeepsViewedRevisionWhenTheSelectedRegistrationIsNoLongerPublished() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let capturedOID = try fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Removed checkout captured history"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["worktree", "add", "--detach", fixture.linked.path, capturedOID])
        let refs = try fixture.git(["show-ref", "--head"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let origin = try XCTUnwrap(repository.worktreeService)
        await ready(origin)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); origin.cancel() }
        await waitUntil { controller.historyViewController?.view.window === window }
        let history = try XCTUnwrap(controller.historyViewController)
        let sidebar = try XCTUnwrap(controller.sidebarViewController)
        let clicked = try worktreeItem(in: sidebar, at: fixture.linked.path)
        try selectWorktree(clicked, in: sidebar)
        await waitUntil { history.selectedCommits.first?.sha == capturedOID }
        let revision = try XCTUnwrap(repository.currentBranch)
        let renderingInputs = history.webCommits.map(\.sha)
        origin.cancel()
        _ = try fixture.git(["worktree", "remove", fixture.linked.path])
        let gate = PruneTaskGate(fixture: fixture)
        let replacement = PBRepositoryWorktreeService(repository: repository, taskFactory: gate.makeTask)
        defer { replacement.cancel(); repository.setValue(origin, forKey: "worktreeService") }
        // Installing the ready replacement also updates the independently observed freshness state.
        replacement.start()
        await ready(replacement)
        await waitUntil { replacement.worktrees.count == 1 }
        XCTAssertFalse(replacement.worktrees.contains { WorktreePaths.identity($0.path) == clicked.identity })
        repository.setValue(replacement, forKey: "worktreeService")
        XCTAssertTrue(repository.worktreeService === replacement)
        XCTAssertNil(sidebar.selectedItem() as? PBSourceViewGitWorktreeItem, "The accepted replacement inventory removes the obsolete worktree row")
        // Recreate the retained selection boundary explicitly: its UI row outlives its registration.
        let worktrees = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        worktrees.addChild(clicked)
        let outline = try XCTUnwrap(sidebar.sourceView)
        outline.reloadData()
        outline.expandItem(worktrees)
        try selectWorktree(clicked, in: sidebar)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        let alternate = try XCTUnwrap(PBViewController(repository: repository, superController: controller))
        alternate.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        _ = controller.perform(NSSelectorFromString("changeContentController:"), with: alternate)
        let historyAction = NSMenuItem(title: "History", action: NSSelectorFromString("returnToHistory:"), keyEquivalent: "1")
        let action = try XCTUnwrap(historyAction.action)
        XCTAssertTrue(NSApp.sendAction(action, to: controller, from: historyAction))
        XCTAssertTrue(history.view.window === window)
        XCTAssertNil(alternate.view.window)
        XCTAssertTrue(repository.currentBranch === revision)
        XCTAssertEqual((sidebar.selectedItem() as? PBSourceViewGitWorktreeItem)?.identity, clicked.identity)
        XCTAssertEqual(history.selectedCommits.first?.sha, capturedOID)
        XCTAssertEqual(history.webCommits.map(\.sha), renderingInputs)
        let others = try XCTUnwrap(sidebar.value(forKey: "others") as? PBSourceViewItem)
        XCTAssertTrue(sourceItems(others).contains { $0.revSpecifier?.isEqual(revision) == true })
        XCTAssertFalse(gate.repairWasRequested)
        XCTAssertFalse(gate.pruneWasRequested)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
    }

    func testDirectLocateFromAReferenceCancelsWithoutChangingMovedCheckoutOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(administrative)
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let refs = try fixture.git(["show-ref", "--head"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let gate = PruneTaskGate(fixture: fixture)
        let service = try await installPruneService(in: repository, gate: gate)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === window }
        let moved = fixture.root.appendingPathComponent("relocated-topic")
        try FileManager.default.moveItem(at: fixture.linked, to: moved)
        // Keep the captured branch facade alive until the actual public action
        // resolves its sender; no event-loop drain may refresh away that row.
        let sender = NSMenuItem()
        sender.representedObject = PBGitRef(string: "refs/heads/topic")
        let selector = NSSelectorFromString("locateWorktreeFolder:")
        XCTAssertTrue(NSApp.sendAction(selector, to: controller, from: sender))
        await waitUntil { window.attachedSheet is NSOpenPanel }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.directoryURL.map { WorktreePaths.canonical($0.path) }, WorktreePaths.canonical(fixture.root.path))
        window.endSheet(panel, returnCode: .cancel)
        await waitUntil { window.attachedSheet == nil }
        await drainPruneCallbacks()
        XCTAssertFalse(gate.repairWasRequested)
        XCTAssertFalse(gate.pruneWasRequested)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
        try await operation(.pruneReport, service: service)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
    }

    func testPreferredRelativeRepairOffersItsStyleAndReclaimsOnlyAfterExplicitConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let headBytes = try Data(contentsOf: administrative.appendingPathComponent("HEAD"))
        let indexBytes = try Data(contentsOf: administrative.appendingPathComponent("index"))
        let head = try fixture.git(["rev-parse", "HEAD"])
        let refs = try fixture.git(["show-ref", "--head"])
        let gitfile = fixture.linked.appendingPathComponent(".git")
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let gate = PruneTaskGate(fixture: fixture)
        let service = try await installPruneService(in: repository, gate: gate)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === window }
        let stale = Data("gitdir: ../missing-admin\n".utf8)
        try stale.write(to: gitfile)
        service.refresh()
        await waitUntil { service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
        let style = try await waitForSheet(in: window, containing: "Relative Paths")
        let relative = try XCTUnwrap(descendants(style.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Relative Paths" })
        let absolute = try XCTUnwrap(descendants(style.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Absolute Paths" })
        let relativeCell = try XCTUnwrap(relative.cell as? NSButtonCell)
        XCTAssertTrue(style.defaultButtonCell === relativeCell)
        XCTAssertEqual(absolute.keyEquivalent, "")
        XCTAssertFalse(gate.repairWasRequested)
        try attachScreenshot(of: style, named: "Worktrees-Preferred-Relative-Repair-Style")
        window.endSheet(style, returnCode: .alertSecondButtonReturn)
        let consent = try await waitForSheet(in: window, containing: "Reclaim")
        XCTAssertFalse(gate.repairWasRequested)
        XCTAssertEqual(try Data(contentsOf: gitfile), stale)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("HEAD")), headBytes)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("index")), indexBytes)
        window.endSheet(consent, returnCode: .alertFirstButtonReturn)
        await waitUntil { window.attachedSheet == nil && service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == false }
        XCTAssertTrue(gate.repairWasRequested)
        let repaired = try String(contentsOf: gitfile, encoding: .utf8)
        XCTAssertTrue(repaired.hasPrefix("gitdir: ../"))
        let backlink = try String(contentsOf: administrative.appendingPathComponent("gitdir"), encoding: .utf8)
        XCTAssertTrue(backlink.hasPrefix("../"))
        XCTAssertEqual(try fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), WorktreePaths.canonical(administrative.path))
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("HEAD")), headBytes)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("index")), indexBytes)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
    }

    func testHealthyRepairActionDoesNotPresentAConfirmationOrAcquireAWriter() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(administrative)
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let refs = try fixture.git(["show-ref", "--head"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let gate = PruneTaskGate(fixture: fixture)
        let service = try await installPruneService(in: repository, gate: gate)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        await waitUntil { controller.historyViewController?.view.window === window }
        XCTAssertTrue(service.isSupported)
        XCTAssertFalse(service.worktrees.contains(where: \.hasBrokenLink))
        controller.repairWorktreeLinks(nil)
        await drainPruneCallbacks()
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(gate.repairWasRequested)
        XCTAssertFalse(gate.pruneWasRequested)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        try await operation(.lock(path: fixture.linked.path, reason: "after healthy repair no-op"), service: service)
        XCTAssertTrue(service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
    }

    private func worktreeItem(in sidebar: PBGitSidebarController, at path: String) throws -> PBSourceViewGitWorktreeItem {
        let group = try XCTUnwrap(sidebar.items.compactMap { $0 as? PBSourceViewItem }.first { $0.title == "WORKTREES" })
        let item = try XCTUnwrap(group.sortedChildren.compactMap { $0 as? PBSourceViewGitWorktreeItem }
            .first { $0.identity == WorktreePaths.identity(path) })
        sidebar.sourceView?.expandItem(group)
        return item
    }

    func testClosingWindowDuringPruneRejectsLatePreviewResultsAndConfirmationClicks() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for phase in PruneClosePhase.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
            let head = try fixture.git(["rev-parse", "HEAD"])
            let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
            let metadata = try registrationMetadata(administrative)
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let gate = PruneTaskGate(fixture: fixture)
            let service = try await installPruneService(in: repository, gate: gate)
            let controller = PBGitWindowController()
            controller.repository = repository
            await showForegroundWindow(controller)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close(); service.cancel(); gate.report.finish(nil, error: CancellationError()) }
            try FileManager.default.removeItem(at: fixture.linked)
            let report = try Data(fixture.git(WorktreeCommand.pruneReport.arguments).utf8)

            if phase == .preview {
                gate.holdNextReport = true
            }
            controller.pruneWorktrees(nil)
            if phase == .preview {
                await waitUntil { gate.report.isPending }
                XCTAssertNil(window.attachedSheet)
            } else {
                let sheet = try await waitForSheet(in: window, containing: "Prune")
                if phase == .confirmedPreview {
                    gate.holdNextReport = true
                }
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                if phase == .confirmedPreview {
                    await waitUntil { gate.report.isPending }
                }
                // The sheet completion is dispatched asynchronously. Closing
                // here also covers its deferred Prune click before it runs.
            }
            controller.close()
            await waitUntil { !window.isVisible }
            if phase != .deferredClick {
                XCTAssertTrue(gate.report.wasCancelled)
            }
            gate.report.finish(report)
            await drainPruneCallbacks()
            controller.pruneWorktrees(nil)
            await drainPruneCallbacks()

            XCTAssertFalse(gate.pruneWasRequested, "A closed window executed Prune during \(phase)")
            XCTAssertEqual(try registrationMetadata(administrative), metadata)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
            XCTAssertNil(window.attachedSheet)
        }
    }

    func testHiddenWindowRetainsCompletedPrunePreviewUntilTheUserReturns() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let metadata = try registrationMetadata(administrative)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let gate = PruneTaskGate(fixture: fixture)
        let service = try await installPruneService(in: repository, gate: gate)
        let controller = PBGitWindowController()
        controller.repository = repository
        await showForegroundWindow(controller)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel(); gate.report.finish(nil, error: CancellationError()) }
        try FileManager.default.removeItem(at: fixture.linked)
        let report = try Data(fixture.git(WorktreeCommand.pruneReport.arguments).utf8)
        gate.holdNextReport = true
        controller.pruneWorktrees(nil)
        await waitUntil { gate.report.isPending }

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        gate.report.finish(report)
        await drainPruneCallbacks()
        XCTAssertFalse(gate.report.wasCancelled)
        XCTAssertTrue(service.isSupported)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(gate.pruneWasRequested)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        await showForegroundWindow(controller)
        await waitUntil { window.isVisible }
        let freshSheet = try await waitForSheet(in: window, containing: "Prune")
        XCTAssertTrue(sheetText(freshSheet).contains(administrative.lastPathComponent))
        window.endSheet(freshSheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(gate.pruneWasRequested)
        XCTAssertEqual(try registrationMetadata(administrative), metadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testGitCapabilityLossInvalidatesAnOpenPruneConfirmation() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for restoreBeforeConfirmation in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
            let head = try fixture.git(["rev-parse", "HEAD"])
            let administrative = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines))
            let metadata = try registrationMetadata(administrative)
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let gate = PruneTaskGate(fixture: fixture)
            let service = try await installPruneService(in: repository, gate: gate)
            let controller = PBGitWindowController()
            controller.repository = repository
            await showForegroundWindow(controller)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close(); service.cancel() }
            try FileManager.default.removeItem(at: fixture.linked)
            controller.pruneWorktrees(nil)
            let sheet = try await waitForSheet(in: window, containing: "Prune")
            defaults.set(fixture.root.appendingPathComponent("unavailable-git").path, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            await waitUntil { !service.isSupported }
            XCTAssertTrue(window.attachedSheet === sheet)
            if restoreBeforeConfirmation {
                defaults.set("/usr/bin/git", forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
                await waitUntil { service.isSupported }
            }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            await drainPruneCallbacks()
            // Capability recovery cannot revive the earlier token. Both states report the rejection.
            let errorSheet = try await waitForSheet(in: window)
            XCTAssertFalse(errorSheet === sheet)
            XCTAssertFalse(descendants(errorSheet.contentView).contains { ($0 as? NSButton)?.title == "Prune" })
            window.endSheet(errorSheet, returnCode: .alertFirstButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            if !restoreBeforeConfirmation {
                defaults.set("/usr/bin/git", forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
                await waitUntil { service.isSupported }
            }

            XCTAssertFalse(gate.pruneWasRequested)
            XCTAssertEqual(try registrationMetadata(administrative), metadata)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        }
    }

    private func selectWorktree(_ item: PBSourceViewGitWorktreeItem, in sidebar: PBGitSidebarController) throws {
        let outline = try XCTUnwrap(sidebar.sourceView)
        let row = outline.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.deselectAll(nil)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sidebar.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
    }

    private func sheetText(_ sheet: NSWindow) -> String {
        descendants(sheet.contentView).compactMap { view in
            if let field = view as? NSTextField {
                return field.stringValue
            }
            return (view as? NSTextView)?.string
        }.joined(separator: "\n")
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func sourceItems(_ item: PBSourceViewItem) -> [PBSourceViewItem] {
        [item] + item.sortedChildren.flatMap { sourceItems($0) }
    }

    private func applicationMenuItems(_ menu: NSMenu) -> [NSMenuItem] {
        // NSPopUpButton installs its own action on icon and separator items.
        // Their public presentation distinguishes them from application actions.
        menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }
    }

    private func showForegroundWindow(_ controller: PBGitWindowController, file: StaticString = #filePath, line: UInt = #line) async {
        controller.showWindow(nil)
        guard let window = controller.window else { XCTFail("The test window did not load", file: file, line: line); return }
        window.makeKeyAndOrderFront(nil)
        await activateWorktreeTestApplication(file: file, line: line)
        await waitUntil({ NSApp.isActive && (window.isKeyWindow || window.attachedSheet?.isKeyWindow == true) }, file: file, line: line)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func waitForSheet(in window: NSWindow, containing title: String? = nil) async throws -> NSWindow {
        await waitUntil {
            guard let sheet = window.attachedSheet else { return false }
            return title.map { title in self.descendants(sheet.contentView).contains { ($0 as? NSButton)?.title == title || ($0 as? NSTextField)?.stringValue == title } } ?? true
        }
        return try XCTUnwrap(window.attachedSheet)
    }

    private func ready(_ service: PBRepositoryWorktreeService) async {
        if !service.worktrees.isEmpty {
            return
        }
        let snapshot = expectation(description: "worktrees discovered")
        let observation = service.observe(\.worktrees) { _, _ in snapshot.fulfill() }
        await fulfillment(of: [snapshot], timeout: 10)
        observation.invalidate()
        XCTAssertTrue(service.isSupported)
    }

    private func operation(_ command: WorktreeCommand, service: PBRepositoryWorktreeService) async throws {
        switch command {
        case let .addNew(path, branch): _ = try await service.addWorktree(path: path, branch: branch, createBranch: true)
        case let .addExisting(path, branch): _ = try await service.addWorktree(path: path, branch: branch, createBranch: false)
        case let .remove(path, force): _ = try await service.removeWorktree(path: path, force: force)
        case let .lock(path, reason): _ = try await service.lockWorktree(path: path, reason: reason)
        case let .unlock(path): _ = try await service.unlockWorktree(path: path)
        case .pruneReport:
            let prepared = try await service.preparePrunePreview()
            try service.discardPrunePreview(XCTUnwrap(prepared))
        case .prune:
            let prepared = try await service.preparePrunePreview()
            let preview = try XCTUnwrap(prepared)
            if preview.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                service.discardPrunePreview(preview)
                return
            }
            if let updated = try await confirmPrune(service, preview: preview) {
                service.discardPrunePreview(updated)
                XCTFail("Worktree state changed while the fixture confirmed its preview")
            }
        case .repairLinks: XCTFail("Use the typed repair API")
        }
    }

    private final class PruneCompletion {
        var preview: PBWorktreePrunePreview?
        var error: NSError?
    }

    private func confirmPrune(_ service: PBRepositoryWorktreeService, preview: PBWorktreePrunePreview) async throws -> PBWorktreePrunePreview? {
        let done = expectation(description: "prune confirmation returned")
        let result = PruneCompletion()
        enqueue {
            service.prune(confirmedPreview: preview) { updated, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated {
                    result.preview = updated
                    result.error = error as NSError?
                    done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 10)
        if let error = result.error {
            throw error
        }
        return result.preview
    }

    private func enqueue(_ operation: () -> Void) {
        operation()
    }

    private func installPruneService(in repository: PBGitRepository, gate: PruneTaskGate) async throws -> PBRepositoryWorktreeService {
        let original = try XCTUnwrap(repository.worktreeService)
        await ready(original)
        original.cancel()
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: gate.makeTask)
        // This test-only replacement uses the existing repository-owned I/O
        // collaborator; no production injection or controller API is added.
        repository.setValue(service, forKey: "worktreeService")
        XCTAssertTrue(repository.worktreeService === service)
        service.start()
        await ready(service)
        return service
    }

    private func registrationMetadata(_ administrative: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["gitdir", "commondir", "HEAD", "index"].map {
            try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
        })
    }

    private func drainPruneCallbacks() async {
        let drained = expectation(description: "prune callback boundary drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 10)
    }

    private enum PruneClosePhase: CaseIterable, Equatable {
        case preview, confirmedPreview, deferredClick
    }

    private final class PruneTaskGate {
        let fixture: Fixture
        let report = DeferredPruneReportTask()
        var holdNextReport = false
        private var commands: [[String]] = []

        init(fixture: Fixture) {
            self.fixture = fixture
        }

        var pruneWasRequested: Bool {
            commands.contains(WorktreeCommand.prune.arguments)
        }

        var repairWasRequested: Bool {
            commands.contains { Array($0.prefix(2)) == ["worktree", "repair"] }
        }

        func makeTask(_ arguments: [String]) -> PBTask {
            commands.append(arguments)
            if arguments == WorktreeCommand.pruneReport.arguments, holdNextReport {
                holdNextReport = false
                return report
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
    }

    // swift6-safety-justification: The lock guards completion and cancellation, including discovery-queue access.
    private final nonisolated class DeferredPruneReportTask: PBTask, @unchecked Sendable {
        private let lock = NSLock()
        private var callback: ((Data?, Error?) -> Void)?
        private var cancelled = false

        override func perform(on _: DispatchQueue, completionHandler: @escaping (Data?, Error?) -> Void) {
            lock.lock(); callback = completionHandler; lock.unlock()
        }

        override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
            lock.lock(); callback = completionHandler; lock.unlock()
        }

        override func terminate() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        var isPending: Bool {
            lock.lock(); defer { lock.unlock() }; return callback != nil
        }

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        func finish(_ data: Data?, error: Error? = nil) {
            lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
            callback?(data, error)
        }
    }

    // swift6-safety-justification: The discovery payload is immutable and completion has no stored mutable state.
    private final nonisolated class FixedWorktreeSnapshotTask: PBTask, @unchecked Sendable {
        private let data: Data

        init(data: Data) {
            self.data = data
            super.init()
        }

        override var standardOutputTruncated: Bool {
            false
        }

        override var standardErrorTruncated: Bool {
            false
        }

        override func perform(on _: DispatchQueue, completionHandler: @escaping (Data?, Error?) -> Void) {
            completionHandler(data, nil)
        }

        override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
            completionHandler(data, nil)
        }
    }

    /// Keep the compatibility mirror separated from the runtime Swift layout
    /// when AppKit creates a notifying subclass of this imported test fixture.
    private final class RepairWindowControllerFixture: PBHistoryWindowControllerTestBase {}

    private final class WorktreeReferenceCellFake: NSTableCellView {
        var referenceIndex: Int32 = -1
        @objc(indexAtX:)
        // swiftlint:disable:next unused_declaration
        func index(atX _: CGFloat) -> Int32 {
            referenceIndex
        }
    }

    private final class WorktreeCommitListFake: NSTableView {
        var testRow = 0
        let revisionCell = WorktreeReferenceCellFake()
        @objc var mouseDownPoint: NSPoint {
            NSPoint(x: 5, y: 5)
        }

        override func row(at _: NSPoint) -> Int {
            testRow
        }

        override func column(at _: NSPoint) -> Int {
            0
        }

        override func view(atColumn _: Int, row _: Int, makeIfNecessary _: Bool) -> NSView? {
            revisionCell
        }

        override func frameOfCell(atColumn _: Int, row _: Int) -> NSRect {
            NSRect(x: 0, y: 0, width: 300, height: 20)
        }
    }

    private final class Fixture {
        let root: URL
        let main: URL
        let linked: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-app-\(UUID().uuidString)")
            main = root.appendingPathComponent("main"); linked = root.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Worktree Fixture"])
            _ = try git(["config", "user.email", "fixture@gitx.invalid"])
            _ = try git(["commit", "--allow-empty", "-m", "fixture"])
        }

        func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
            let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: (directory ?? main).path)
            GitXTestGitFixture.prepare(task); try task.launch()
            return String(decoding: task.standardOutputData, as: UTF8.self)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
