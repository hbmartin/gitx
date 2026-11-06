import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the case; UI and fixture state are confined to the main actor.
final class ReflogWorkflowUITests: XCTestCase, @unchecked Sendable {
    private let workspace = GitXUITestFixtureWorkspace(prefix: "gitx-reflog")
    private var application: XCUIApplication?

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest invokes teardown on the main thread.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false {
                screenshot("Reflog-Failure")
            }
            application?.terminate()
            application = nil
            workspace.removeAll()
        }
        super.tearDown()
    }

    func testRecoveryBranchFromUnreachableReflogEvent() throws {
        let fixture = try makeFixture()
        let app = try launch(fixture.repository)
        try openOriginalEvent(in: app)
        screenshot("Reflog-Unreachable-Commit")
        let create = app.buttons["GitX.Reflog.CreateBranch"]
        waitUntilEnabled(create)
        create.click()
        let name = app.sheets.textFields["GitX.Reflog.BranchName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("recovery/ui-recovered")
        app.sheets.buttons["Create Branch"].click()
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { [workspace] _, _ in
            // swift6-safety-justification: XCTest evaluates AppKit workflow predicates on the main thread.
            MainActor.assumeIsolated {
                (try? workspace.git(["rev-parse", "recovery/ui-recovered"], in: fixture.repository).trimmingCharacters(in: .newlines)) == fixture.original
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 10), .completed)
        XCTAssertEqual(try head(fixture.repository), fixture.current)
        screenshot("Reflog-Recovery-Branch-Created")
    }

    func testHardResetRequiresSeparateDiscardAndPreservesPreviousCommit() throws {
        let fixture = try makeFixture()
        let file = fixture.repository.appendingPathComponent("tracked.txt")
        try "uncommitted edit\n".write(to: file, atomically: true, encoding: .utf8)
        let app = try launch(fixture.repository)
        try openOriginalEvent(in: app)
        try previewHardReset(in: app)
        screenshot("Reflog-Hard-Reset-Preview")
        app.sheets.buttons["Continue…"].click()
        XCTAssertTrue(app.sheets.buttons["Discard Changes and Reset"].waitForExistence(timeout: 5))
        screenshot("Reflog-Explicit-Discard-Confirmation")
        app.sheets.buttons["Cancel"].click()
        XCTAssertEqual(try head(fixture.repository), fixture.current)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "uncommitted edit\n")
        try previewHardReset(in: app)
        app.sheets.buttons["Continue…"].click()
        XCTAssertTrue(app.sheets.buttons["Discard Changes and Reset"].waitForExistence(timeout: 5))
        app.sheets.buttons["Discard Changes and Reset"].click()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { [workspace] _, _ in
            // swift6-safety-justification: XCTest evaluates AppKit workflow predicates on the main thread.
            MainActor.assumeIsolated {
                (try? workspace.git(["rev-parse", "HEAD"], in: fixture.repository).trimmingCharacters(in: .newlines)) == fixture.original
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertEqual(try workspace.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"], in: fixture.repository).trimmingCharacters(in: .newlines), fixture.current)
        screenshot("Reflog-Reset-Completed-With-Backup")
    }

    private func openOriginalEvent(in app: XCUIApplication) throws {
        app.menuBars.menuBarItems["View"].click()
        let command = app.menuItems["Reflog"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
        let table = app.tables["GitX.Reflog.Events"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let event = table.tableRows.containing(.staticText, identifier: "Original recovery commit").firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        event.click()
        waitUntilEnabled(app.buttons["GitX.Reflog.Reset"])
    }

    private func previewHardReset(in app: XCUIApplication) throws {
        let reset = app.buttons["GitX.Reflog.Reset"]
        waitUntilEnabled(reset)
        reset.click()
        let mode = app.sheets.popUpButtons["GitX.Reflog.ResetMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue((mode.value as? String)?.hasPrefix("Soft") == true)
        mode.click()
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.sheets.buttons["Preview Reset"].click()
        XCTAssertTrue(app.sheets.staticTexts["Review Hard Reset"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.buttons["Continue…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.textViews["GitX.Reflog.ResetPreview"].exists)
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func makeFixture() throws -> (repository: URL, original: String, current: String) {
        let repository = try workspace.makeDirectory(named: "repository")
        try workspace.git(["init", "-b", "main"], in: repository)
        try "original\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try workspace.git(["add", "tracked.txt"], in: repository)
        try workspace.git(["commit", "-m", "Original recovery commit"], in: repository)
        let original = try head(repository)
        try "amended\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try workspace.git(["commit", "--amend", "-am", "Amended recovery commit"], in: repository)
        return try (repository, original, head(repository))
    }

    private func head(_ repository: URL) throws -> String {
        try workspace.git(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .newlines)
    }

    private func launch(_ repository: URL) throws -> XCUIApplication {
        let home = try workspace.makeIsolatedHome()
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US_POSIX", "-NSAutomaticWindowAnimationsEnabled", "NO", "-PBAutoFetchScope", "0"]
        app.launchEnvironment = GitXTestGitEnvironment.isolated(app.launchEnvironment).merging([
            "CFFIXED_USER_HOME": home.path, "CFPREFERENCES_AVOID_DAEMON": "1", "GITX_UITEST_REPO": repository.path,
            "GITX_UITEST_FORGE_STORAGE_ROOT": home.appendingPathComponent("Library/Application Support/GitX/Forge").path,
        ]) { _, value in value }
        application = app
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private func screenshot(_ name: String) {
        guard let application else { return }
        let attachment = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
