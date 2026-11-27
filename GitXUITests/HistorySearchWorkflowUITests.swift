import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the case; UI and fixture state are confined to the main actor.
final class HistorySearchWorkflowUITests: XCTestCase, @unchecked Sendable {
    private let workspace = GitXUITestFixtureWorkspace(prefix: "gitx-history-search")
    private var application: XCUIApplication?

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest invokes teardown on the main thread.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false {
                screenshot("History-Search-Failure")
            }
            application?.terminate()
            application = nil
            workspace.removeAll()
        }
        super.tearDown()
    }

    func testChoosingAModeSavingTheSearchAndRunningItAgainFromTheMenu() throws {
        let app = try launch(makeRepository())
        let mode = app.popUpButtons["GitX.History.SearchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20))
        let field = app.searchFields["GitX.History.SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let matches = app.staticTexts["GitX.History.SearchMatches"]

        // Pick the file path mode in the scope bar and search for one directory.
        mode.click()
        app.menuItems["File path"].click()
        waitForValue(of: mode, toBe: "File path")
        field.click()
        field.typeText("docs/\r")
        waitForValue(of: matches, toBe: "1 match")
        screenshot("History-Search-Path-Mode")

        // Save it under a name.
        openSearchMenu(of: field, in: app)
        app.menuItems["GitX.History.Search.SaveAs"].click()
        let name = app.sheets.textFields["GitX.SavedSearches.Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Documentation")
        screenshot("History-Search-Save-Sheet")
        app.sheets.buttons["GitX.SavedSearches.Save"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        // Change the mode and text, then run the saved search again from the menu.
        mode.click()
        app.menuItems["Subject, Author, SHA"].click()
        waitForValue(of: mode, toBe: "Subject, Author, SHA")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("parser\r")
        waitForValue(of: matches, toBe: "2 matches")
        openSearchMenu(of: field, in: app)
        XCTAssertEqual(app.menuItems["GitX.History.Search.Recent.0"].title, "parser — Subject, Author, SHA")
        XCTAssertEqual(app.menuItems["GitX.History.Search.Recent.1"].title, "docs/ — File path")
        app.menuItems["GitX.History.Search.Saved.Documentation"].click()
        waitForValue(of: mode, toBe: "File path")
        waitForValue(of: matches, toBe: "1 match")
        XCTAssertEqual(field.value as? String, "docs/")

        // The saved search is listed in the Saved Searches sheet.
        openSearchMenu(of: field, in: app)
        app.menuItems["GitX.History.Search.ManageSaved"].click()
        let table = app.sheets.tables["GitX.SavedSearches.Table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(table.staticTexts["File path"].exists || table.textFields["File path"].exists)
        screenshot("History-Search-Saved-Searches-Sheet")
        app.sheets.buttons["GitX.SavedSearches.Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    // MARK: Fixture

    private func makeRepository() throws -> URL {
        let repository = try workspace.makeDirectory(named: "repository")
        try workspace.git(["init", "-b", "main"], in: repository)
        try commit(file: "src/parser.c", contents: "int parse(void);\n", message: "Add parser", in: repository)
        try commit(file: "docs/guide.md", contents: "# Guide\n", message: "Add guide", in: repository)
        try commit(file: "src/parser.c", contents: "int parse(void) { return 0; }\n", message: "Fix parser", in: repository)
        return repository
    }

    private func commit(file: String, contents: String, message: String, in repository: URL) throws {
        let url = repository.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try workspace.git(["add", file], in: repository)
        try workspace.git(["commit", "-m", message], in: repository)
    }

    private func launch(_ repository: URL) throws -> XCUIApplication {
        let home = try workspace.makeIsolatedHome()
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US_POSIX",
            "-NSAutomaticWindowAnimationsEnabled", "NO", "-PBAutoFetchScope", "0",
        ]
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

    // MARK: Helpers

    private func openSearchMenu(of field: XCUIElement, in app: XCUIApplication) {
        let identified = field.buttons["GitX.History.SearchMenuButton"]
        let menuButton = identified.waitForExistence(timeout: 2) ? identified : field.buttons.firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.click()
        XCTAssertTrue(app.menuItems["GitX.History.Search.SaveAs"].waitForExistence(timeout: 5))
    }

    private func waitForValue(of element: XCUIElement, toBe expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            // swift6-safety-justification: XCTest evaluates UI predicates on the main thread.
            MainActor.assumeIsolated { element.exists && (element.value as? String) == expected }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10)
        XCTAssertEqual(result, .completed, "\(element) never showed \(expected); it shows \(String(describing: element.value))", file: file, line: line)
    }

    private func screenshot(_ name: String) {
        guard let application else { return }
        let attachment = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
