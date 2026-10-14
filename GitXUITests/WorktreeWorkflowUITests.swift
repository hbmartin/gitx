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
        let protected = try ["gitdir", "commondir", "HEAD"].map { try Data(contentsOf: registration.appendingPathComponent($0)) }
        let refs = try workspace.git(["show-ref", "--head"], in: main)
        let head = try workspace.git(["rev-parse", "HEAD"], in: main)
        let gitfile = linked.appendingPathComponent(".git")
        try FileManager.default.removeItem(at: gitfile)
        let app = try launch(main)
        XCTAssertTrue(app.sheets.buttons["Repair with Absolute Paths"].waitForExistence(timeout: 15))
        app.sheets.buttons["Repair with Absolute Paths"].click()
        XCTAssertTrue(app.sheets.buttons["Reclaim"].waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        screenshot("Worktrees-Reclaim-Consent-Return-Cancels")
        app.windows.firstMatch.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.sheets)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        XCTAssertEqual(try ["gitdir", "commondir", "HEAD"].map { try Data(contentsOf: registration.appendingPathComponent($0)) }, protected)
        XCTAssertEqual(try workspace.git(["show-ref", "--head"], in: main), refs)
        XCTAssertEqual(try workspace.git(["rev-parse", "HEAD"], in: main), head)
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

    private func launch(_ repository: URL) throws -> XCUIApplication {
        let home = try workspace.makeIsolatedHome()
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US_POSIX", "-NSAutomaticWindowAnimationsEnabled", "NO", "-PBAutoFetchScope", "0"]
        app.launchEnvironment = GitXTestGitEnvironment.isolated(app.launchEnvironment).merging([
            "CFFIXED_USER_HOME": home.path, "CFPREFERENCES_AVOID_DAEMON": "1", "GITX_UITEST_REPO": repository.path,
            "GITX_UITEST_FORGE_STORAGE_ROOT": home.appendingPathComponent("Library/Application Support/GitX/Forge").path,
        ]) { _, value in value }
        application = app; app.launch(); app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private func worktree(_ branch: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "RepositoryWorktreeItem").matching(NSPredicate(format: "label == %@", branch)).firstMatch
    }

    private func screenshot(_ name: String, window: XCUIElement? = nil) {
        guard let target = window ?? application?.windows.firstMatch, target.exists else { return }
        let attachment = XCTAttachment(screenshot: target.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
