import AppKit
import GitXCore
import XCTest

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

    func testExplicitBranchSelectionReturnsMountedContentToHistoryWithoutCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let window = PBGitWindowController()
        window.repository = repository
        window.showWindow(nil)
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
        controller.showWindow(nil)
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
        controller.showWindow(nil)
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
            controller.showWindow(nil)
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

    func testBranchWorktreeMenusFallBackToLifecycleActionsWithoutHistoryCollaborator() async throws {
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
            XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("copyBranchName:") || $0.action == NSSelectorFromString("checkout:") || $0.action == NSSelectorFromString("deleteRef:") })
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
        controller.showWindow(nil)
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
            XCTAssertEqual(applicationItems.count, 4)
            XCTAssertEqual(applicationItems.compactMap(\.action), ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "removeWorktree:"].map(NSSelectorFromString))
            for action in applicationItems {
                XCTAssertEqual((action.representedObject as? PBGitWorktree)?.path, item.worktree.path)
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
            controller.showWindow(nil)
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
                XCTAssertEqual(applicationItems.count, 4)
                XCTAssertEqual(applicationItems.compactMap(\.action), ["openWorktree:", "revealWorktreeInFinder:", "lockWorktree:", "removeWorktree:"].map(NSSelectorFromString))
                for action in applicationItems {
                    XCTAssertEqual((action.representedObject as? PBGitWorktree)?.path, selectedItem.worktree.path)
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
                controller.showWindow(nil)
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

    func testWorktreeSnapshotRefreshPreservesMountedContentAndBranchSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["worktree", "add", "-b", "topic", fixture.linked.path])
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = try XCTUnwrap(repository.worktreeService)
        await ready(service)
        let window = PBGitWindowController()
        window.repository = repository
        window.showWindow(nil)
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

        let published = expectation(description: "locked sibling snapshot published")
        let observation = service.observe(\.worktrees) { _, _ in published.fulfill() }
        _ = try fixture.git(["worktree", "lock", "--reason", "refresh regression", fixture.linked.path])
        service.refresh()
        await fulfillment(of: [published], timeout: 5)
        observation.invalidate()

        XCTAssertTrue(service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
        XCTAssertTrue(content.view.window === window.window)
        XCTAssertNil(history.view.window)
        XCTAssertEqual(sidebar.selectedItem()?.revSpecifier?.simpleRef(), viewedBranch)
        XCTAssertEqual(repository.currentBranch?.simpleRef(), viewedBranch)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
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
        window.showWindow(nil)
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
        XCTAssertEqual(groupMenu.items.map(\.title), ["Add Worktree…", "Prune Worktrees…"])
        XCTAssertTrue(groupMenu.items[0].isEnabled)
        XCTAssertFalse(groupMenu.items[1].isEnabled)
        XCTAssertTrue(groupMenu.items[1].toolTip?.contains("Every worktree") ?? false)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let item = NSMenuItem(); item.representedObject = tree
        controller.lockWorktree(item)
        var sheet = try await waitForSheet(in: window)
        try attachScreenshot(of: sheet, named: "Worktrees-Lock-Reason-Sheet")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(service.worktree(forBranch: "refs/heads/topic")?.isLocked ?? true)
        controller.lockWorktree(item)
        sheet = try await waitForSheet(in: window)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close(); service.cancel() }
        var sheet = try await waitForSheet(in: window, containing: "Repair with Absolute Paths")
        XCTAssertEqual(window.attachedSheet?.defaultButtonCell?.title, "Repair with Absolute Paths")
        try attachScreenshot(of: sheet, named: "Worktrees-Moved-Nested-Repair-Sheet")
        window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
        await waitUntil { window.attachedSheet == nil }
        controller.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        service.refresh()
        await Task.yield()
        XCTAssertNil(window.attachedSheet)
        controller.pruneWorktrees(nil)
        sheet = try await waitForSheet(in: window, containing: "Repair with Relative Paths")
        XCTAssertFalse(descendants(sheet.contentView).compactMap { $0 as? NSButton }.contains { $0.title == "Prune" })
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
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
        let controller = PBGitWindowController(); controller.repository = repository; controller.showWindow(nil)
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
        controller.showWindow(nil)
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
        controller.showWindow(nil)
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
        controller.showWindow(nil)
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
        controller.showWindow(nil)
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
        controller.showWindow(nil)
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
            XCTAssertFalse(buttons.contains("Repair with Absolute Paths"))
            XCTAssertFalse(buttons.contains("Repair with Relative Paths"))
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
        controller.showWindow(nil)
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
        let explicit = try await waitForSheet(in: window, containing: "Repair with Absolute Paths")
        XCTAssertFalse(sheetText(explicit).contains("repository was moved"))
        XCTAssertTrue(sheetText(explicit).contains(fixture.linked.path))
        window.endSheet(explicit, returnCode: .alertFirstButtonReturn)
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
            controller.showWindow(nil)
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

    func testHiddenWindowDiscardsCompletedPrunePreviewAndCanRequestAFreshPreview() async throws {
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
        controller.showWindow(nil)
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

        controller.showWindow(nil)
        await waitUntil { window.isVisible }
        XCTAssertNil(window.attachedSheet)
        controller.pruneWorktrees(nil)
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
            controller.showWindow(nil)
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
            if restoreBeforeConfirmation {
                // Capability recovery does not revive the consent captured
                // before the executable change. The service rejects its token.
                let errorSheet = try await waitForSheet(in: window)
                XCTAssertFalse(errorSheet === sheet)
                XCTAssertFalse(descendants(errorSheet.contentView).contains { ($0 as? NSButton)?.title == "Prune" })
                window.endSheet(errorSheet, returnCode: .alertFirstButtonReturn)
                await waitUntil { window.attachedSheet == nil }
            } else {
                XCTAssertNil(window.attachedSheet)
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
        case .repairLinks, .repairMoved: XCTFail("Use the typed repair API")
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
