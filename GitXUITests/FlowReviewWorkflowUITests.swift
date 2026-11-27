import XCTest

/// View ▸ Flow Review drives the Flow tab's review, and its choices survive a relaunch.
@MainActor
// swift6-safety-justification: XCTest owns the case; UI and fixture state are confined to the main actor.
final class FlowReviewWorkflowUITests: XCTestCase, @unchecked Sendable {
    private static let subject = "Review shipping totals"
    private let workspace = GitXUITestFixtureWorkspace(prefix: "gitx-flow-review")
    private var application: XCUIApplication?

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest invokes teardown on the main thread.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false {
                screenshot("FlowReview-Failure")
            }
            application?.terminate()
            application = nil
            workspace.removeAll()
        }
        super.tearDown()
    }

    func testFlowReviewMenuDrivesTheReviewAndItsChoicesSurviveARelaunch() throws {
        let repository = try makeFixture()
        let home = try workspace.makeIsolatedHome()
        var app = try launch(repository, home: home)
        try showFlow(in: app)

        let noise = app.popUpButtons["FlowDelta.Review.Noise"]
        XCTAssertEqual(noise.value as? String, "Hide Cosmetic Changes", "Cosmetic noise is hidden by default")
        XCTAssertTrue(app.buttons["FlowDelta.Review.HiddenNoise"].waitForExistence(timeout: 5))
        screenshot("FlowReview-Default-Hides-Cosmetic-Noise")

        let presentation = app.segmentedControls["FlowDelta.Review.Presentation"]
        choose("GitX.FlowReview.Calls", in: app)
        wait(for: presentation.buttons["Calls"], "selected == true")
        screenshot("FlowReview-Calls-From-Menu")
        app.typeKey("1", modifierFlags: [.control, .command])
        wait(for: presentation.buttons["Delta"], "selected == true")

        choose("GitX.FlowReview.ShowAllChanges", in: app)
        wait(for: noise, "value == 'Show All Changes'")
        choose("GitX.FlowReview.GroupByConcern", in: app)
        let grouping = app.checkBoxes["FlowDelta.Review.GroupByConcern"]
        wait(for: grouping, "value == 1")
        screenshot("FlowReview-Grouped-By-Concern")

        choose("GitX.FlowReview.StartWalkthrough", in: app)
        let step = app.staticTexts["FlowDelta.Review.Walkthrough.Step"]
        wait(for: step, "value BEGINSWITH 'Step 1 of'")
        app.typeKey("]", modifierFlags: [.control, .command])
        wait(for: step, "value BEGINSWITH 'Step 2 of'")
        screenshot("FlowReview-Walkthrough-Next-Step")
        app.typeKey("[", modifierFlags: [.control, .command])
        wait(for: step, "value BEGINSWITH 'Step 1 of'")
        app.buttons["FlowDelta.Review.Walkthrough.Done"].click()

        app.typeKey("e", modifierFlags: [.shift, .command])
        let format = app.popUpButtons["History.Flow.ExportFormat"]
        XCTAssertTrue(format.waitForExistence(timeout: 10), "Export Flow Report… shows a save sheet with a format")
        XCTAssertEqual(format.value as? String, "Markdown")
        screenshot("FlowReview-Export-Sheet")
        app.typeKey(.escape, modifierFlags: [])
        wait(for: format, "exists == false")

        waitForSavedPreference("PBHistoryFlowGroupsByConcern", in: home)
        app.terminate()

        app = try launch(repository, home: home)
        try showFlow(in: app)
        wait(for: app.popUpButtons["FlowDelta.Review.Noise"], "value == 'Show All Changes'")
        wait(for: app.checkBoxes["FlowDelta.Review.GroupByConcern"], "value == 1")
        screenshot("FlowReview-Choices-Restored-After-Relaunch")
    }

    // MARK: Helpers

    private func showFlow(in app: XCUIApplication) throws {
        let commitList = app.windows.firstMatch.tables["CommitList"]
        XCTAssertTrue(commitList.waitForExistence(timeout: 20))
        let commit = commitList.tableRows.containing(.staticText, identifier: Self.subject).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        commit.click()
        app.typeKey("3", modifierFlags: [.option, .command])
        wait(for: app.staticTexts["FlowDelta.Review.Summary"], "value CONTAINS 'function delta'", timeout: 30)
    }

    private func choose(_ identifier: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["View"].click()
        let flowReview = app.menuItems["GitX.View.FlowReview"]
        XCTAssertTrue(flowReview.waitForExistence(timeout: 5))
        flowReview.click()
        let item = app.menuItems[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(identifier) is missing")
        XCTAssertTrue(item.isEnabled, "\(identifier) is disabled")
        item.click()
    }

    private func wait(for element: XCUIElement, _ format: String, timeout: TimeInterval = 10) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed, "\(element) never matched \(format)")
    }

    /// Waits until GitX has written `key` to its preferences in `home`, so terminating cannot lose it.
    private func waitForSavedPreference(_ key: String, in home: URL) {
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let files = (try? FileManager.default.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
            return files.contains { NSDictionary(contentsOf: $0)?[key] != nil }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed, "GitX never saved \(key)")
    }

    private func makeFixture() throws -> URL {
        let repository = try workspace.makeDirectory(named: "repository")
        try workspace.git(["init", "-b", "main"], in: repository)
        try workspace.git(["config", "user.name", "GitX Flow Review"], in: repository)
        try workspace.git(["config", "user.email", "flow-review@example.invalid"], in: repository)
        try write(
            """
            func shippingTotal(_ items: [Int], priority: Bool) -> Int {
                var total = 0
                for item in items {
                    total += item
                }
                if priority { total += 10 }
                return total
            }

            func legacyDiscount(_ total: Int) -> Int { total > 100 ? 10 : 0 }
            """,
            to: "Shipping.swift",
            in: repository
        )
        try write(
            """
            def price(items):
                total = 0
                for item in items:
                    total += item
                return total
            """,
            to: "pricing.py",
            in: repository
        )
        try workspace.git(["add", "."], in: repository)
        try workspace.git(["commit", "-m", "Add shipping totals"], in: repository)
        try write(
            """
            func shippingTotal(_ items: [Int], priority: Bool) -> Int {
                guard !items.isEmpty else { return 0 }
                var total = 0
                for item in items {
                    total += item
                }
                if (priority) { total += 15 }
                return total
            }

            func auditOrder(_ items: [Int]) {
                for item in items { print(item) }
            }
            """,
            to: "Shipping.swift",
            in: repository
        )
        try write(
            """
            def price(items):
                total = 0
                for item in items:
                    total += item
                discount = total // 10
                return total - discount
            """,
            to: "pricing.py",
            in: repository
        )
        try workspace.git(["commit", "-am", Self.subject], in: repository)
        return repository
    }

    private func write(_ text: String, to name: String, in repository: URL) throws {
        try (text + "\n").write(to: repository.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func launch(_ repository: URL, home: URL) throws -> XCUIApplication {
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

    private func screenshot(_ name: String) {
        guard let application else { return }
        let attachment = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
