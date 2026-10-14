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
