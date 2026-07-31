import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test-case lifetime, while all mutable application and fixture state is confined to the main actor.
final class Milestone3WorkflowUITests: XCTestCase, @unchecked Sendable {
    private var temporaryDirectories: [URL] = []
    private var activeApplication: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest invokes teardown on the main thread, where application automation and fixture cleanup are confined.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false, let app = activeApplication {
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "M3-Failure-Screen"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "M3-Failure-Accessibility-Hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            activeApplication?.terminate()
            activeApplication = nil
            removeTemporaryDirectories()
        }
        super.tearDown()
    }

    func testReviewReplyFormalReviewResolveAndUndoJourney() throws {
        let repository = try makeWorkingRepository(name: "review")
        let app = try launch(repository: repository, scenario: "review")
        let activePrefix = "GitX.PullRequest.Review.Thread.m3-active-thread"
        let outdatedPrefix = "GitX.PullRequest.Review.Thread.m3-outdated-thread"
        try requireExists(element(activePrefix, in: app), timeout: 10)
        try requireExists(element(outdatedPrefix, in: app), timeout: 5)
        try requireLabel(
            "Minimized: Off-topic",
            for: element(activePrefix + ".Comment.1.Status", in: app),
            timeout: 5
        )
        try requireLabel(
            "Deleted comment",
            for: element(activePrefix + ".Comment.2.Status", in: app),
            timeout: 5
        )
        try requireLabel(
            "Comment unavailable",
            for: element(activePrefix + ".Comment.3.Status", in: app),
            timeout: 5
        )
        try requireExists(element(outdatedPrefix + ".Outdated", in: app), timeout: 5)
        retainDiagnosticScreenshot(named: "M3-Review-01-Thread-States", of: app.windows.firstMatch, in: app)

        let reply = app.textViews[activePrefix + ".Reply"]
        try requireHittable(reply, timeout: 5)
        reply.click()
        reply.typeText("The exact range now handles the boundary case.")
        try click(app.buttons[activePrefix + ".Reply.Publish"], timeout: 5)
        try requireTextValue("", for: reply, timeout: 10)

        try click(app.buttons["GitX.PullRequest.Review.FormalReview"], timeout: 5)
        try requireExists(element("GitX.PullRequest.Review.FormalReviewSheet", in: app), timeout: 5)
        try click(app.buttons["GitX.PullRequest.Review.FormalReviewSubmit"], timeout: 5)
        try requireGone(element("GitX.PullRequest.Review.FormalReviewSheet", in: app), timeout: 10)

        try click(app.buttons[activePrefix + ".Resolve"], timeout: 5)
        try click(app.buttons[activePrefix + ".Undo"], timeout: 5)
        try requireHittable(app.buttons[activePrefix + ".Resolve"], timeout: 5)
        retainDiagnosticScreenshot(named: "M3-Review-02-Published-Reviewed-Undo", of: app.windows.firstMatch, in: app)
    }

    func testSuggestedChangeAppliesOneUnstagedExactContextEdit() throws {
        let repository = try makeWorkingRepository(name: "suggested-change")
        let app = try launch(repository: repository, scenario: "suggested-change")

        let apply = app.buttons[
            "GitX.PullRequest.Review.Thread.m3-active-thread.Suggestion.0.Apply"
        ]
        try requireHittable(apply, timeout: 10)
        retainDiagnosticScreenshot(named: "M3-Suggested-01-Eligible", of: app.windows.firstMatch, in: app)
        try click(apply, timeout: 5)
        try requireFile(
            repository.appendingPathComponent("M3Suggested.swift"),
            contains: "let answer = 42",
            timeout: 10
        )

        let contents = try String(
            contentsOf: repository.appendingPathComponent("M3Suggested.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("let answer = 42"))
        XCTAssertEqual(
            try git(["diff", "--name-only"], in: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "M3Suggested.swift"
        )
        try requireLabel(
            "Applied one suggested change as an unstaged local edit.",
            for: element("GitX.PullRequest.Review.Message", in: app),
            timeout: 10
        )
        retainDiagnosticScreenshot(named: "M3-Suggested-02-Applied-Unstaged", of: app.windows.firstMatch, in: app)
    }

    func testLifecycleAndExplicitUpdateBranchJourney() throws {
        let repository = try makeWorkingRepository(name: "lifecycle")
        let app = try launch(repository: repository, scenario: "lifecycle")

        let lifecycle = "GitX.PullRequest.Review.Lifecycle."
        try requireHittable(app.buttons[lifecycle + "markReady"], timeout: 10)
        retainDiagnosticScreenshot(named: "M3-Lifecycle-01-Draft", of: app.windows.firstMatch, in: app)

        try click(app.buttons[lifecycle + "markReady"], timeout: 5)
        try requireDisabled(app.buttons[lifecycle + "markReady"], timeout: 10)
        try click(app.buttons[lifecycle + "updateBranch"], timeout: 5)
        try click(app.buttons[lifecycle + "updateBranch.Confirm"], timeout: 5)
        try requireDisabled(app.buttons[lifecycle + "updateBranch"], timeout: 10)
        try click(app.buttons[lifecycle + "close"], timeout: 5)
        try requireHittable(app.buttons[lifecycle + "reopen"], timeout: 10)
        try click(app.buttons[lifecycle + "reopen"], timeout: 5)
        try requireHittable(app.buttons[lifecycle + "close"], timeout: 10)
        try click(app.buttons["GitX.PullRequest.Review.ManageReviewers"], timeout: 5)
        try requireHarnessState("Lifecycle.ReviewersBrowserRouted", in: app, timeout: 10)
        retainDiagnosticScreenshot(named: "M3-Lifecycle-02-Updated-Reopened", of: app.windows.firstMatch, in: app)
    }

    func testMergeMethodsWarningsAndFreshConfirmationJourney() throws {
        let repository = try makeWorkingRepository(name: "merge")
        let app = try launch(repository: repository, scenario: "merge")

        let method = app.popUpButtons["GitX.PullRequest.Review.MergeMethod"]
        try requireHittable(method, timeout: 10)
        method.click()
        try click(app.menuItems["Squash and Merge"], timeout: 5)
        retainDiagnosticScreenshot(named: "M3-Merge-01-Methods-And-Warning", of: app.windows.firstMatch, in: app)

        try click(app.buttons["GitX.PullRequest.Review.Merge"], timeout: 5)
        try requireExists(element("GitX.PullRequest.Review.MergeSheet", in: app), timeout: 5)
        try requireExists(app.staticTexts["GitX.PullRequest.Review.MergeWarnings"], timeout: 5)
        retainDiagnosticScreenshot(named: "M3-Merge-02-Fresh-Confirmation", of: app.windows.firstMatch, in: app)
        try click(app.buttons["GitX.PullRequest.Review.MergeConfirm"], timeout: 5)
        try requireGone(element("GitX.PullRequest.Review.MergeSheet", in: app), timeout: 10)
        try requireHittable(app.buttons["GitX.PullRequest.Review.FetchBase"], timeout: 5)
        retainDiagnosticScreenshot(named: "M3-Merge-03-Succeeded", of: app.windows.firstMatch, in: app)
    }

    func testMergeQueueAndSeparateBranchDeletionJourney() throws {
        let repository = try makeWorkingRepository(name: "queue-delete")
        let app = try launch(repository: repository, scenario: "queue-delete")

        let queue = app.buttons["GitX.PullRequest.Review.MergeQueue"]
        try requireHittable(queue, timeout: 10)
        XCTAssertEqual(queue.label, "Enter Merge Queue")
        retainDiagnosticScreenshot(named: "M3-Queue-01-Explicit-Actions", of: app.windows.firstMatch, in: app)

        try click(queue, timeout: 5)
        try requireLabel("Leave Merge Queue", for: queue, timeout: 10)
        try click(queue, timeout: 5)
        try requireHittable(app.buttons["GitX.PullRequest.Review.DeleteBranch"], timeout: 10)
        try click(app.buttons["GitX.PullRequest.Review.DeleteBranch"], timeout: 5)
        try requireExists(element("GitX.PullRequest.Review.DeleteBranch.Sheet", in: app), timeout: 5)
        try click(app.buttons["GitX.PullRequest.Review.DeleteBranch.Confirm"], timeout: 5)
        try requireGone(element("GitX.PullRequest.Review.DeleteBranch.Sheet", in: app), timeout: 10)
        try requireGone(app.buttons["GitX.PullRequest.Review.DeleteBranch"], timeout: 10)
        retainDiagnosticScreenshot(named: "M3-Queue-02-Merge-Observed-Branch-Deleted", of: app.windows.firstMatch, in: app)
    }

    func testPostMergeFetchThenExplicitCheckoutBaseJourney() throws {
        let fixture = try makePostMergeRepository()
        let app = try launch(repository: fixture.repository, scenario: "post-merge")

        try requireHittable(app.buttons["GitX.PullRequest.Review.FetchBase"], timeout: 10)
        XCTAssertEqual(
            try git(["branch", "--show-current"], in: fixture.repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "feature/milestone-3"
        )
        retainDiagnosticScreenshot(named: "M3-PostMerge-01-Checkout-Unchanged", of: app.windows.firstMatch, in: app)
        try click(app.buttons["GitX.PullRequest.Review.FetchBase"], timeout: 5)
        try requireGit(
            ["rev-parse", "refs/remotes/origin/main"],
            in: fixture.repository,
            equals: git(["rev-parse", "main"], in: fixture.repository),
            timeout: 15
        )
        XCTAssertEqual(
            try git(["branch", "--show-current"], in: fixture.repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "feature/milestone-3"
        )
        try click(app.buttons["GitX.PullRequest.Review.CheckOutBase"], timeout: 5)
        try requireGit(
            ["branch", "--show-current"],
            in: fixture.repository,
            equals: "main\n",
            timeout: 15
        )
        XCTAssertEqual(
            try git(["branch", "--show-current"], in: fixture.repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "main"
        )
        retainDiagnosticScreenshot(named: "M3-PostMerge-02-Base-Checked-Out", of: app.windows.firstMatch, in: app)
    }

    private func launch(repository: URL, scenario: String) throws -> XCUIApplication {
        let isolatedHome = try makeDirectory(name: "isolated-home")
        try FileManager.default.createDirectory(
            at: isolatedHome.appendingPathComponent("Library/Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US_POSIX",
            "-NSAutomaticWindowAnimationsEnabled", "NO",
            "-PBAutoFetchScope", "0",
            "-Suppressed Dialog Warnings", "()",
        ]
        app.launchEnvironment = [
            "CFFIXED_USER_HOME": isolatedHome.path,
            "CFPREFERENCES_AVOID_DAEMON": "1",
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GITX_UITEST_REPO": repository.path,
            "GITX_M3_UITEST": "1",
            "GITX_M3_SCENARIO": scenario,
        ]
        activeApplication = app
        app.launch()
        try requireHarnessState("Ready.\(scenario)", in: app, timeout: 15)
        try requireExists(element("GitX.PullRequest.Review.Actions", in: app), timeout: 10)
        try requireExists(element("GitX.PullRequest.Review.Overlay", in: app), timeout: 10)
        return app
    }

    private func makeWorkingRepository(name: String) throws -> URL {
        let repository = try makeDirectory(name: name)
        _ = try git(["init", "--quiet", "--initial-branch", "main"], in: repository)
        _ = try git(["config", "user.name", "GitX UI Tests"], in: repository)
        _ = try git(["config", "user.email", "ui-tests@gitx.invalid"], in: repository)
        try "Milestone 3 fixture\n".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "let answer = 41\n".write(
            to: repository.appendingPathComponent("M3Suggested.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "README.md", "M3Suggested.swift"], in: repository)
        _ = try git(["commit", "--quiet", "-m", "Milestone 3 fixture"], in: repository)
        _ = try git(["switch", "--quiet", "-c", "feature/milestone-3"], in: repository)
        return repository
    }

    private func makePostMergeRepository() throws -> (repository: URL, remote: URL) {
        let remote = try makeDirectory(name: "post-merge-origin.git")
        _ = try git(["init", "--bare", "--quiet"], in: remote)
        let repository = try makeWorkingRepository(name: "post-merge")
        _ = try git(["switch", "--quiet", "main"], in: repository)
        _ = try git(["remote", "add", "origin", remote.path], in: repository)
        _ = try git(["push", "--quiet", "--set-upstream", "origin", "main"], in: repository)
        _ = try git(["switch", "--quiet", "feature/milestone-3"], in: repository)
        return (repository, remote)
    }

    private func makeDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-m3-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func removeTemporaryDirectories() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let selectedGit = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/git")
        process.executableURL = FileManager.default.isExecutableFile(atPath: selectedGit.path)
            ? selectedGit
            : URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.commandFailed(arguments, result)
        }
        return result
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func requireExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Expected UI element to exist: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireHarnessState(
        _ state: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = element("GitX.M3.Harness.\(state)", in: app)
        let failure = element("GitX.M3.Harness.Failure", in: app)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in expected.exists || failure.exists },
            object: app
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Milestone 3 UI harness did not reach state \(state)", file: file, line: line)
            throw Milestone3UIError.harnessUnavailable
        }
        guard !failure.exists else {
            XCTFail("Milestone 3 UI harness failed: \(failure.label)", file: file, line: line)
            throw Milestone3UIError.harnessUnavailable
        }
    }

    private func requireHittable(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Expected UI element to exist: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
        scrollIntoViewIfNeeded(element)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isHittable
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element to become hittable: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func scrollIntoViewIfNeeded(_ element: XCUIElement) {
        guard let application = activeApplication else { return }
        let outer = application.scrollViews["GitX.M3.Production.ScrollView"]
        let thread = application.scrollViews["GitX.PullRequest.Review.Threads"]
        let scrollViews = element.identifier.hasPrefix("GitX.PullRequest.Review.Thread.")
            ? [thread, outer]
            : [outer]
        for scrollView in scrollViews where scrollView.exists {
            for _ in 0 ..< 16 {
                let viewport = scrollView.frame.insetBy(dx: 3, dy: 3)
                let target = element.frame
                if viewport.contains(target) {
                    if element.isHittable {
                        return
                    }
                    break
                }
                let delta = target.midY > viewport.midY ? -120.0 : 120.0
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
    }

    private func requireTextValue(
        _ expectedValue: String,
        for element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement,
                      element.exists,
                      let value = element.value as? String
                else { return false }
                return value == expectedValue
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element value \(expectedValue.debugDescription): \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireGone(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return !element.exists
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element to disappear: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireDisabled(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && !element.isEnabled
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element to become disabled: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireLabel(
        _ expectedLabel: String,
        for element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.label == expectedLabel
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element label \(expectedLabel.debugDescription): \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireFile(
        _ url: URL,
        contains expectedText: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let url = object as? URL,
                      let contents = try? String(contentsOf: url, encoding: .utf8)
                else { return false }
                return contents.contains(expectedText)
            },
            object: url
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected \(url.path) to contain \(expectedText.debugDescription)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func requireGit(
        _ arguments: [String],
        in repository: URL,
        equals expectedOutput: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let normalizedExpected = expectedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self,
                      let output = try? self.git(arguments, in: repository)
                else { return false }
                return output.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedExpected
            },
            object: repository
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail(
                "Expected git \(arguments.joined(separator: " ")) to equal \(normalizedExpected.debugDescription)",
                file: file,
                line: line
            )
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func click(_ element: XCUIElement, timeout: TimeInterval) throws {
        try requireHittable(element, timeout: timeout)
        try requireEnabled(element, timeout: timeout)
        element.click()
    }

    private func requireEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isEnabled
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element to become enabled: \(element)", file: file, line: line)
            throw Milestone3UIError.elementUnavailable
        }
    }

    private func retainDiagnosticScreenshot(
        named name: String,
        of target: XCUIElement,
        in app: XCUIApplication
    ) {
        let screenshot: XCUIScreenshot
        if target.exists {
            screenshot = target.screenshot()
        } else if app.windows.firstMatch.exists {
            screenshot = app.windows.firstMatch.screenshot()
        } else {
            screenshot = XCUIScreen.main.screenshot()
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum GitFixtureError: Error {
        case commandFailed([String], String)
    }

    private enum Milestone3UIError: Error {
        case elementUnavailable
        case harnessUnavailable
    }
}
