import XCTest

@MainActor
// swift6-safety-justification: XCTest owns this case; all application automation and fixture ownership are confined to the main actor.
final class WorktreeWorkflowUITests: XCTestCase, @unchecked Sendable {
    private let workspace = GitXUITestFixtureWorkspace(prefix: "gitx-worktrees")
    private var application: XCUIApplication?

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest calls teardown on the main thread, where UI and fixture state are owned.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false {
                screenshot("Worktrees-Failure")
            }
            application?.terminate(); application = nil; workspace.removeAll()
        }
        super.tearDown()
    }

    func testSelectionBrowsesAndOpeningActivatesCorrectCheckoutWithoutChangingHEAD() throws {
        let (main, linked) = try fixture()
        let mainHead = try workspace.git(["rev-parse", "HEAD"], in: main)
        let linkedHead = try workspace.git(["rev-parse", "HEAD"], in: linked)
        let app = try launch(main)
        let original = app.windows.matching(NSPredicate(format: "title CONTAINS %@", main.lastPathComponent)).firstMatch
        let topic = worktree("topic", in: original)
        XCTAssertTrue(topic.waitForExistence(timeout: 15))
        screenshot("Worktrees-Sidebar-Locked-And-Detached", window: original)
        topic.click()
        let history = original.tables["CommitList"].tableRows.containing(.staticText, identifier: "Worktree topic history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), mainHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: linked), linkedHead)
        topic.doubleClick()
        let opened = app.windows.matching(NSPredicate(format: "title CONTAINS %@", linked.lastPathComponent)).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 15))
        XCTAssertTrue(opened.tables["CommitList"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 2)
        screenshot("Worktrees-Opened-Correct-Checkout", window: opened)
        app.menuBars.menuBarItems["Window"].click()
        let originalWindowItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", main.lastPathComponent)).firstMatch
        XCTAssertTrue(originalWindowItem.waitForExistence(timeout: 5))
        originalWindowItem.click()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: topic)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        topic.rightClick()
        let open = app.menuItems["Open Worktree of Branch “topic”"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Copy Branch Name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Create Tag…"].exists)
        screenshot("Worktrees-Restored-Branch-Menu", window: original)
        open.click()
        let activated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", linked.lastPathComponent), object: app.windows.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [activated], timeout: 5), .completed)
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), mainHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: linked), linkedHead)
    }

    func testRemovalUsesSeparateForceConfirmationKeepsBranchAndHEAD() throws {
        let (main, linked) = try fixture()
        _ = try workspace.git(["worktree", "unlock", linked.path], in: main)
        try "dirty\n".write(to: linked.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let head = try workspace.git(["rev-parse", "HEAD"], in: main)
        let app = try launch(main)
        let topic = worktree("topic", in: app.windows.firstMatch)
        XCTAssertTrue(topic.waitForExistence(timeout: 15))
        topic.rightClick(); app.menuItems["Remove Worktree…"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        screenshot("Worktrees-Ordinary-Removal-Confirmation")
        app.sheets.buttons["Remove"].click()
        XCTAssertTrue(app.sheets.buttons["Remove Anyway"].waitForExistence(timeout: 10))
        screenshot("Worktrees-Force-Removal-Confirmation")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
        topic.rightClick(); app.menuItems["Remove Worktree…"].click()
        XCTAssertTrue(app.sheets.buttons["Remove"].waitForExistence(timeout: 5)); app.sheets.buttons["Remove"].click()
        XCTAssertTrue(app.sheets.buttons["Remove Anyway"].waitForExistence(timeout: 10)); app.sheets.buttons["Remove Anyway"].click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: linked.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(try workspace.git(["rev-parse", "refs/heads/topic"], in: main).isEmpty)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), head)
    }

    func testDuplicateBranchContextMenuLocksOnlyTheClickedCheckout() throws {
        let (main, linked) = try fixture()
        let duplicate = main.deletingLastPathComponent().appendingPathComponent("zzz-duplicate-topic-checkout")
        _ = try workspace.git(["worktree", "add", "--force", duplicate.path, "topic"], in: main)
        let registered = try workspace.git(["worktree", "list", "--porcelain"], in: main)
        let topicRegistrations = registered.components(separatedBy: "\n\n").filter { $0.split(separator: "\n").contains("branch refs/heads/topic") }
        XCTAssertEqual(topicRegistrations.count, 2)
        XCTAssertTrue(topicRegistrations.first?.contains("worktree " + linked.path + "\n") == true)
        let firstLock = try Data(contentsOf: main.appendingPathComponent(".git/worktrees/topic-checkout/locked"))
        let refs = try workspace.git(["show-ref", "--head"], in: main)
        let mainHead = try workspace.git(["rev-parse", "HEAD"], in: main)
        let linkedHead = try workspace.git(["rev-parse", "HEAD"], in: linked)
        let duplicateLink = try Data(contentsOf: duplicate.appendingPathComponent(".git"))
        let app = try launch(main)
        let window = app.windows.firstMatch
        let topicRows = window.outlines.firstMatch.outlineRows.containing(.staticText, identifier: "topic")
        let bothRows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: topicRows)
        XCTAssertEqual(XCTWaiter.wait(for: [bothRows], timeout: 15), .completed)
        // The fixture's original checkout is locked. Its sibling is the only
        // unlocked topic row, independent of tie sorting or AX value spelling.
        let unlockedRow = try XCTUnwrap(topicRows.allElementsBoundByIndex.first { !$0.images["Locked"].exists })
        let selected = unlockedRow.staticTexts.matching(identifier: "RepositoryWorktreeItem").firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 15))
        selected.click()
        selected.rightClick()
        let lock = app.menuItems["Lock Worktree…"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(app.menuItems["Unlock Worktree"].exists)
        XCTAssertTrue(app.menuItems["Remove Worktree…"].isEnabled)
        screenshot("Worktrees-Duplicate-Clicked-Checkout-Context-Menu", window: window)
        lock.click()
        XCTAssertTrue(app.sheets.buttons["Lock"].waitForExistence(timeout: 5))
        let reason = app.sheets.textFields.firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.click()
        reason.typeText("clicked duplicate UI fixture")
        app.sheets.buttons["Lock"].click()
        let lockFile = main.appendingPathComponent(".git/worktrees/zzz-duplicate-topic-checkout/locked")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: lockFile.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: lockFile, encoding: .utf8), "clicked duplicate UI fixture\n")
        XCTAssertEqual(try Data(contentsOf: main.appendingPathComponent(".git/worktrees/topic-checkout/locked")), firstLock)
        XCTAssertEqual(try Data(contentsOf: duplicate.appendingPathComponent(".git")), duplicateLink)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), mainHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: linked), linkedHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: duplicate), linkedHead)
    }

    func testMissingLinkReclaimConsentDefaultsReturnToCancel() throws {
        let (main, linked) = try fixture()
        _ = try workspace.git(["worktree", "unlock", linked.path], in: main)
        let registration = main.appendingPathComponent(".git/worktrees/topic-checkout")
        let contentCanary = linked.appendingPathComponent("reclaim-cancel-canary.txt")
        let content = Data("staged worktree content must survive either cancellation key\n".utf8)
        try content.write(to: contentCanary)
        _ = try workspace.git(["add", "--", contentCanary.lastPathComponent], in: linked)
        let protected = try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: registration.appendingPathComponent($0)) }
        let refs = try workspace.git(["show-ref", "--head"], in: main)
        let head = try workspace.git(["rev-parse", "HEAD"], in: main)
        let gitfile = linked.appendingPathComponent(".git")
        try FileManager.default.removeItem(at: gitfile)
        let app = try launch(main)
        XCTAssertTrue(app.sheets.buttons["Absolute Paths"].waitForExistence(timeout: 15))
        app.sheets.buttons["Absolute Paths"].click()
        XCTAssertTrue(app.sheets.buttons["Reclaim"].waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        screenshot("Worktrees-Reclaim-Consent-Return-Cancels")
        let consent = app.sheets.firstMatch
        XCTAssertTrue(consent.exists)
        XCTAssertTrue(consent.buttons["Cancel"].isEnabled)
        XCTAssertTrue(consent.buttons["Reclaim"].isEnabled)
        consent.typeKey(.return, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.sheets)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        XCTAssertEqual(try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: registration.appendingPathComponent($0)) }, protected)
        XCTAssertEqual(try Data(contentsOf: contentCanary), content)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), head)
    }

    func testLocateMovedCheckoutWaitsForExplicitRepairConsentAfterAnUnrelatedLockSheet() throws {
        let (main, linked) = try fixture()
        let root = main.deletingLastPathComponent()
        let detached = root.appendingPathComponent("detached-checkout")
        let destination = root.appendingPathComponent("actual-destination")
        let topicAdmin = main.appendingPathComponent(".git/worktrees/topic-checkout")
        let detachedAdmin = main.appendingPathComponent(".git/worktrees/detached-checkout")
        _ = try workspace.git(["worktree", "unlock", linked.path], in: main)
        let mainContent = main.appendingPathComponent("main-locate-canary.txt")
        let topicContent = linked.appendingPathComponent("topic-locate-canary.txt")
        let detachedContent = detached.appendingPathComponent("detached-locate-canary.txt")
        try Data("main content survives Locate\n".utf8).write(to: mainContent)
        _ = try workspace.git(["add", "--", mainContent.lastPathComponent], in: main)
        _ = try workspace.git(["commit", "-m", "Main Locate preservation canary"], in: main)
        try Data("staged topic content survives Locate\n".utf8).write(to: topicContent)
        _ = try workspace.git(["add", "--", topicContent.lastPathComponent], in: linked)
        try Data("staged detached content survives Lock and Unlock\n".utf8).write(to: detachedContent)
        _ = try workspace.git(["add", "--", detachedContent.lastPathComponent], in: detached)
        try FileManager.default.moveItem(at: linked, to: destination)
        let protectedURLs = [main.appendingPathComponent(".git/HEAD"), main.appendingPathComponent(".git/index"),
                             topicAdmin.appendingPathComponent("HEAD"), topicAdmin.appendingPathComponent("index"), topicAdmin.appendingPathComponent("commondir"),
                             detachedAdmin.appendingPathComponent("HEAD"), detachedAdmin.appendingPathComponent("index"),
                             detachedAdmin.appendingPathComponent("gitdir"), detachedAdmin.appendingPathComponent("commondir"),
                             destination.appendingPathComponent(".git"), mainContent,
                             destination.appendingPathComponent(topicContent.lastPathComponent), detachedContent]
        let protected = try protectedURLs.map { try Data(contentsOf: $0) }
        let refs = try workspace.git(["show-ref", "--head"], in: main)
        let originalBacklink = try Data(contentsOf: topicAdmin.appendingPathComponent("gitdir"))
        let firstReason = "Locate FIFO barrier"
        let occupantReason = "Unrelated Lock sheet must keep this canary"
        let proxy = try heldWorktreeGitProxy(in: root, detached: detached, reason: firstReason)
        defer {
            try? Data().write(to: proxy.release)
            attachProxyDiagnostics(proxy)
        }
        try preflightGitProxy(proxy)
        let app = try launch(main, gitExecutable: proxy.executable, environment: proxy.environment)
        let window = app.windows.firstMatch
        let detachedRow = window.staticTexts.matching(identifier: "RepositoryWorktreeItem")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Detached HEAD (")).firstMatch
        XCTAssertTrue(detachedRow.waitForExistence(timeout: 15))
        detachedRow.rightClick()
        XCTAssertTrue(app.menuItems["Lock Worktree…"].waitForExistence(timeout: 5))
        app.menuItems["Lock Worktree…"].click()
        XCTAssertTrue(app.sheets.buttons["Lock"].waitForExistence(timeout: 5))
        app.sheets.textFields.firstMatch.click()
        app.sheets.textFields.firstMatch.typeText(firstReason)
        app.sheets.buttons["Lock"].click()
        guard waitForFile(proxy.started) else { return }
        let lockArguments = ["--git-dir=" + main.appendingPathComponent(".git").path, "worktree", "lock", "--reason", firstReason, detached.path]
        XCTAssertEqual(try Data(contentsOf: proxy.lockArguments), nulArguments(lockArguments))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detachedAdmin.appendingPathComponent("locked").path))

        let topic = worktree("topic", in: window)
        XCTAssertTrue(topic.waitForExistence(timeout: 15))
        topic.rightClick()
        XCTAssertTrue(app.menuItems["Locate Worktree Folder…"].waitForExistence(timeout: 5))
        app.menuItems["Locate Worktree Folder…"].click()
        let choose = app.sheets.buttons["Choose"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        app.sheets.firstMatch.typeKey("g", modifierFlags: [.command, .shift])
        let goToFolder = app.sheets.matching(identifier: "GoToWindow").firstMatch
        XCTAssertTrue(goToFolder.waitForExistence(timeout: 10))
        let editor = goToFolder.textFields["PathTextField"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(destination.path)
        editor.typeKey(.return, modifierFlags: [])
        let folderChosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: goToFolder)
        XCTAssertEqual(XCTWaiter.wait(for: [folderChosen], timeout: 10), .completed)
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertTrue(choose.isEnabled)
        screenshot("Worktrees-Locate-Actual-Moved-Folder", window: window)
        // Use the enabled default action without depending on the folder panel's screen geometry.
        app.sheets.firstMatch.typeKey(.return, modifierFlags: [])
        let located = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.sheets)
        XCTAssertEqual(XCTWaiter.wait(for: [located], timeout: 10), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.repairArguments.path), "The earlier real writer must still own admission")

        detachedRow.rightClick()
        XCTAssertTrue(app.menuItems["Lock Worktree…"].waitForExistence(timeout: 5))
        app.menuItems["Lock Worktree…"].click()
        let occupant = app.sheets.containing(.button, identifier: "Lock").firstMatch
        XCTAssertTrue(occupant.waitForExistence(timeout: 5))
        let reason = occupant.textFields.firstMatch
        reason.click()
        reason.typeText(occupantReason)
        try Data().write(to: proxy.release)
        let expectedBacklink = Data((destination.appendingPathComponent(".git").path + "\n").utf8)
        let detachedOutlineRow = window.outlines.firstMatch.outlineRows.containing(.staticText, identifier: detachedRow.label).firstMatch
        let lockedImage = detachedOutlineRow.images["Locked"]
        let lockWasPublished = lockedImage.waitForExistence(timeout: 10)
        XCTAssertTrue(lockWasPublished, "The first real Lock must publish before testing the following Unlock publication")
        guard lockWasPublished else { return }
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertTrue(occupant.exists)
        XCTAssertEqual(reason.value as? String, occupantReason)
        XCTAssertTrue(occupant.buttons["Lock"].exists)
        XCTAssertFalse(app.sheets.buttons["Reclaim"].exists)
        XCTAssertFalse(app.sheets.buttons["Repair"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.repairArguments.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.repairInvocations.path))
        XCTAssertEqual(try Data(contentsOf: topicAdmin.appendingPathComponent("gitdir")), originalBacklink)
        screenshot("Worktrees-Locate-Repair-Awaits-Unrelated-Lock-Sheet", window: window)
        occupant.buttons["Cancel"].click()
        let review = app.sheets.containing(.button, identifier: "Repair").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.buttons["Repair"].isEnabled)
        XCTAssertTrue(review.buttons["Cancel"].isEnabled)
        XCTAssertFalse(review.buttons["Reclaim"].exists)
        let scope = review.staticTexts.allElementsBoundByIndex.map { $0.label + "\n" + ($0.value as? String ?? "") }.joined(separator: "\n")
        XCTAssertTrue(scope.contains("Git will repair links for these worktree folders:\n\n" + main.path + "\n" + destination.path))
        XCTAssertFalse(scope.contains(linked.path))
        XCTAssertFalse(scope.contains(detached.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.repairArguments.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.repairInvocations.path))
        XCTAssertEqual(try Data(contentsOf: topicAdmin.appendingPathComponent("gitdir")), originalBacklink)
        XCTAssertEqual(try protectedURLs.map { try Data(contentsOf: $0) }, protected)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        screenshot("Worktrees-Locate-Exact-Scope-Repair-Approval", window: window)
        review.buttons["Repair"].click()
        guard waitForFile(topicAdmin.appendingPathComponent("gitdir"), matching: expectedBacklink) else { return }
        let repairArguments = ["--git-dir=" + main.appendingPathComponent(".git").path, "worktree", "repair", "--no-relative-paths", main.path, destination.path]
        XCTAssertEqual(try Data(contentsOf: proxy.repairArguments), nulArguments(repairArguments))
        XCTAssertEqual(try Data(contentsOf: proxy.repairInvocations), Data("x".utf8))
        XCTAssertNotEqual(expectedBacklink, originalBacklink)
        let listing = try workspace.git(["worktree", "list", "--porcelain"], in: main)
        XCTAssertTrue(listing.components(separatedBy: "\n\n").contains { $0.hasPrefix("worktree " + destination.path + "\n") && $0.contains("\nbranch refs/heads/topic") })
        XCTAssertFalse(listing.contains("worktree " + linked.path + "\n"))
        XCTAssertEqual(try workspace.git(["rev-parse", "--absolute-git-dir"], in: destination).trimmingCharacters(in: .whitespacesAndNewlines), topicAdmin.path)
        XCTAssertEqual(try protectedURLs.map { try Data(contentsOf: $0) }, protected)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try String(contentsOf: detachedAdmin.appendingPathComponent("locked"), encoding: .utf8), firstReason + "\n")
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.sheets)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 10), .completed)
        detachedRow.rightClick()
        XCTAssertTrue(app.menuItems["Unlock Worktree"].waitForExistence(timeout: 10))
        app.menuItems["Unlock Worktree"].click()
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: detachedAdmin.appendingPathComponent("locked").path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 15), .completed)
        let rowExists = detachedOutlineRow.waitForExistence(timeout: 10)
        XCTAssertTrue(rowExists)
        guard rowExists else { return }
        let published = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: lockedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 10), .completed)
        XCTAssertEqual(app.sheets.count, 0, "A completed following writer must not reveal a deferred repair failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: topicAdmin.appendingPathComponent("locked").path))
        XCTAssertEqual(try protectedURLs.map { try Data(contentsOf: $0) }, protected)
        XCTAssertEqual(try Data(contentsOf: topicAdmin.appendingPathComponent("gitdir")), expectedBacklink)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try Data(contentsOf: proxy.repairInvocations), Data("x".utf8))
    }

    func testExplicitHistoryShortcutAdoptsNewestCapturedDetachedHead() throws {
        let (main, linked) = try fixture()
        let detached = main.deletingLastPathComponent().appendingPathComponent("detached-checkout")
        _ = try workspace.git(["commit", "--allow-empty", "-m", "Old only detached history"], in: detached)
        let captured = try workspace.git(["rev-parse", "HEAD"], in: detached).trimmingCharacters(in: .whitespacesAndNewlines)
        let mainHead = try workspace.git(["rev-parse", "HEAD"], in: main)
        let linkedHead = try workspace.git(["rev-parse", "HEAD"], in: linked)
        let refs = try workspace.git(["show-ref", "--head"], in: main)
        let gitfile = try Data(contentsOf: detached.appendingPathComponent(".git"))
        let app = try launch(main)
        let window = app.windows.firstMatch
        let selected = window.staticTexts.matching(identifier: "RepositoryWorktreeItem")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Detached HEAD (")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 15))
        XCTAssertEqual(selected.label, "Detached HEAD (\(captured.prefix(7)))")
        selected.click()
        let oldHistory = window.tables["CommitList"].tableRows.containing(.staticText, identifier: "Old only detached history").firstMatch
        XCTAssertTrue(oldHistory.waitForExistence(timeout: 10))
        window.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(window.buttons["Uncommitted Changes"].waitForExistence(timeout: 10))
        _ = try workspace.git(["commit", "--allow-empty", "-m", "Newest only detached history"], in: detached)
        let latest = try workspace.git(["rev-parse", "HEAD"], in: detached).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexPaths = [main.appendingPathComponent(".git/index"),
                          main.appendingPathComponent(".git/worktrees/topic-checkout/index"),
                          main.appendingPathComponent(".git/worktrees/detached-checkout/index")]
        let indexes = try indexPaths.map { try Data(contentsOf: $0) }
        window.typeKey("r", modifierFlags: .command)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Detached HEAD (\(latest.prefix(7)))"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 15), .completed)
        XCTAssertTrue(window.buttons["Uncommitted Changes"].exists)
        window.typeKey("1", modifierFlags: .command)
        let latestHistory = window.tables["CommitList"].tableRows.containing(.staticText, identifier: "Newest only detached history").firstMatch
        XCTAssertTrue(latestHistory.waitForExistence(timeout: 10))
        screenshot("Worktrees-Explicit-History-Shortcut-Newest-Detached-Head", window: window)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), mainHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: linked), linkedHead)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: detached).trimmingCharacters(in: .whitespacesAndNewlines), latest)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try Data(contentsOf: detached.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try indexPaths.map { try Data(contentsOf: $0) }, indexes)
    }

    private func fixture() throws -> (URL, URL) {
        let root = try workspace.makeDirectory(named: "fixture")
        let main = root.appendingPathComponent("main-checkout")
        let linked = root.appendingPathComponent("topic-checkout")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try workspace.git(["init", "-b", "main"], in: main)
        _ = try workspace.git(["config", "user.name", "Worktree UI Fixture"], in: main)
        _ = try workspace.git(["config", "user.email", "fixture@gitx.invalid"], in: main)
        _ = try workspace.git(["commit", "--allow-empty", "-m", "Worktree main history"], in: main)
        _ = try workspace.git(["worktree", "add", "-b", "topic", linked.path], in: main)
        _ = try workspace.git(["commit", "--allow-empty", "-m", "Worktree topic history"], in: linked)
        _ = try workspace.git(["worktree", "lock", "--reason", "offline disk", linked.path], in: main)
        _ = try workspace.git(["worktree", "add", "--detach", root.appendingPathComponent("detached-checkout").path, "HEAD"], in: main)
        return (main, linked)
    }

    private func launch(_ repository: URL, gitExecutable: URL? = nil, environment: [String: String] = [:]) throws -> XCUIApplication {
        let home = try workspace.makeIsolatedHome()
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US_POSIX", "-NSAutomaticWindowAnimationsEnabled", "NO", "-PBAutoFetchScope", "0"]
        if let gitExecutable {
            app.launchArguments += ["-gitExecutable", gitExecutable.path]
        }
        app.launchEnvironment = GitXTestGitEnvironment.isolated(app.launchEnvironment).merging([
            "CFFIXED_USER_HOME": home.path, "CFPREFERENCES_AVOID_DAEMON": "1", "GITX_UITEST_REPO": repository.path,
            "GITX_UITEST_FORGE_STORAGE_ROOT": home.appendingPathComponent("Library/Application Support/GitX/Forge").path,
        ]) { _, value in value }.merging(environment) { _, value in value }
        application = app; app.launch(); app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private struct HeldWorktreeGitProxy {
        let executable: URL
        let environment: [String: String]
        let started: URL
        let release: URL
        let lockArguments: URL
        let repairArguments: URL
        let repairInvocations: URL
        let versionDiagnostics: URL
    }

    private func heldWorktreeGitProxy(in root: URL, detached: URL, reason: String) throws -> HeldWorktreeGitProxy {
        // Executable fixtures are bundled before signing, rather than created by
        // the sandboxed UI runner, which cannot execute its generated scripts.
        let executable = try XCTUnwrap(Bundle(for: WorktreeWorkflowUITests.self).url(forResource: "WorktreeGitProxy", withExtension: "sh"))
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let git = URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else {
            throw NSError(domain: "WorktreeWorkflowUIFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "The concrete Xcode Git executable is unavailable: " + git.path])
        }
        let environment = ["GITX_UITEST_WORKTREE_PROXY_ROOT": root.path,
                           "GITX_UITEST_WORKTREE_PROXY_DETACHED": detached.path,
                           "GITX_UITEST_WORKTREE_PROXY_REASON": reason,
                           "GITX_UITEST_WORKTREE_PROXY_GIT": git.path]
        let proxy = HeldWorktreeGitProxy(executable: executable, environment: environment, started: root.appendingPathComponent("writer-started"),
                                         release: root.appendingPathComponent("writer-release"), lockArguments: root.appendingPathComponent("lock-arguments"),
                                         repairArguments: root.appendingPathComponent("repair-arguments"), repairInvocations: root.appendingPathComponent("repair-invocations"),
                                         versionDiagnostics: root.appendingPathComponent("proxy-version-diagnostics"))
        try FileManager.default.createDirectory(at: proxy.versionDiagnostics, withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: proxy.executable.path), "The bundled proxy must preserve its executable permission")
        return proxy
    }

    private func preflightGitProxy(_ proxy: HeldWorktreeGitProxy) throws {
        let process = Process()
        process.executableURL = proxy.executable
        process.arguments = ["--version"]
        process.environment = GitXTestGitEnvironment.isolated().merging(proxy.environment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        attachProxyData(stdout, name: "Worktrees-Proxy-Preflight-stdout")
        attachProxyData(stderr, name: "Worktrees-Proxy-Preflight-stderr")
        attachProxyData(Data(String(process.terminationStatus).utf8), name: "Worktrees-Proxy-Preflight-exit")
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderr, as: UTF8.self))
        let version = String(decoding: stdout, as: UTF8.self)
        XCTAssertTrue(version.hasPrefix("git version "), "The bundled proxy must return the real Git version before launching the app")
        guard process.terminationStatus == 0, version.hasPrefix("git version ") else {
            throw NSError(domain: "WorktreeWorkflowUIFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled Git proxy failed its real --version preflight"])
        }
    }

    private func attachProxyDiagnostics(_ proxy: HeldWorktreeGitProxy) {
        if let data = try? Data(contentsOf: proxy.executable) {
            attachProxyData(data, name: "Worktrees-Proxy-Script")
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: proxy.versionDiagnostics, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let data = try? Data(contentsOf: file) {
                attachProxyData(data, name: "Worktrees-Proxy-Version-" + file.lastPathComponent)
            }
        }
    }

    private func attachProxyData(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nulArguments(_ arguments: [String]) -> Data {
        Data((arguments.joined(separator: "\0") + "\0").utf8)
    }

    private func waitForFile(_ url: URL, matching contents: Data? = nil, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if let contents {
                return (try? Data(contentsOf: url)) == contents
            }
            return FileManager.default.fileExists(atPath: url.path)
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: timeout)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
    }

    private func worktree(_ branch: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "RepositoryWorktreeItem").matching(NSPredicate(format: "label == %@", branch)).firstMatch
    }

    private func screenshot(_ name: String, window: XCUIElement? = nil) {
        guard let target = window ?? application?.windows.firstMatch, target.exists else { return }
        let attachment = XCTAttachment(screenshot: target.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
