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
        XCTAssertEqual(worktreeMenu.items.first?.title, "Open Worktree")
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

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
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
        case .pruneReport: _ = try await service.pruneWorktrees(reportOnly: true)
        case .prune: _ = try await service.pruneWorktrees(reportOnly: false)
        case .repairLinks, .repairMoved: XCTFail("Use the typed repair API")
        }
    }

    private final class RepairWindowControllerFixture: PBGitWindowController {}

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
