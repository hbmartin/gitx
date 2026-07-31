import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test-case lifetime, while all mutable application and fixture state is confined to the main actor.
final class Milestone2WorkflowUITests: XCTestCase, @unchecked Sendable {
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
                screenshot.name = "M2-Failure-Screen"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "M2-Failure-Accessibility-Hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            activeApplication?.terminate()
            activeApplication = nil
            removeTemporaryDirectories()
        }
        super.tearDown()
    }

    func testPushThenCreatePullRequestJourneyUsesExactPersistedIntent() throws {
        let fixture = try makePushFixture()
        let app = try launch(repository: fixture.repository, scenario: "push-create")

        let createAfterPush = app.checkBoxes["GitX.Push.CreatePullRequest"]
        try requireHittable(createAfterPush, timeout: 15)
        XCTAssertTrue(isChecked(createAfterPush))
        retainDiagnosticScreenshot(
            named: "M2-01-Push-Confirmation",
            of: app.sheets.firstMatch,
            in: app
        )
        try click(app.sheets.buttons["Push"], timeout: 5)

        let title = app.textFields["GitX.PullRequest.Title"]
        try requireHittable(title, timeout: 20)
        XCTAssertEqual(title.value as? String, "Milestone 2 deterministic Pull Request")
        let body = app.textViews["GitX.PullRequest.Body"]
        try requireExists(body, timeout: 5)
        XCTAssertEqual(body.value as? String, "Offline XCUITest journey")
        retainDiagnosticScreenshot(
            named: "M2-02-Pull-Request-Exact-Intent",
            of: app.sheets.firstMatch,
            in: app
        )
        try click(app.buttons["GitX.PullRequest.Submit"], timeout: 5)

        try requireHarnessState("Destination.Created", in: app, timeout: 15)
        let nativeDestination = app.descendants(matching: .any)["GitX.M2.NativePullRequestDestination"]
        try requireExists(nativeDestination, timeout: 15)
        let inspectorTitle = app.staticTexts["ForgeInspectorTitle"]
        try requireExists(inspectorTitle, timeout: 15)
        XCTAssertEqual(elementText(inspectorTitle), "Milestone 2 deterministic Pull Request")
        retainDiagnosticScreenshot(
            named: "M2-03-Pull-Request-Created-Native-Destination",
            of: app.windows.firstMatch,
            in: app
        )
        XCTAssertEqual(
            try git(["rev-parse", "--verify", "refs/heads/feature/milestone-2"], in: fixture.remote)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.expectedHead
        )
    }

    func testExistingPullRequestJourneyOpensExactExistingDestination() throws {
        let repository = try makeWorkingRepository(name: "existing-pull-request")
        let app = try launch(repository: repository, scenario: "existing-pull-request")

        try requireExists(app.textFields["GitX.PullRequest.Title"], timeout: 15)
        try click(app.buttons["GitX.PullRequest.Submit"], timeout: 5)
        try requireHarnessState("Destination.Existing", in: app, timeout: 15)
        let nativeDestination = app.descendants(matching: .any)["GitX.M2.NativePullRequestDestination"]
        try requireExists(nativeDestination, timeout: 15)
        let inspectorTitle = app.staticTexts["ForgeInspectorTitle"]
        try requireExists(inspectorTitle, timeout: 15)
        XCTAssertEqual(elementText(inspectorTitle), "Milestone 2 deterministic Pull Request")
        retainDiagnosticScreenshot(
            named: "M2-04-Existing-Pull-Request-Native-Destination",
            of: app.windows.firstMatch,
            in: app
        )
    }

    func testExactCheckoutFetchesOnlyApprovedRefAndSwitchesToNamedBranch() throws {
        let fixture = try makeCheckoutFixture()
        let app = try launch(
            repository: fixture.repository,
            scenario: "exact-checkout",
            additionalEnvironment: [
                "GITX_M2_EXPECTED_HEAD": fixture.expectedHead,
                "GITX_M2_CHECKOUT_REMOTE": "contributor",
                "GITX_M2_CHECKOUT_REMOTE_PATH": fixture.remote.path,
                "GIT_SSH_COMMAND": fixture.sshCommand.path,
            ]
        )

        let inspectorTitle = app.staticTexts["ForgeInspectorTitle"]
        try requireExists(inspectorTitle, timeout: 15)
        XCTAssertEqual(
            elementText(inspectorTitle),
            "Contributor checkout through the native Pull Request inspector"
        )
        let checkout = app.buttons["GitX.PullRequest.Checkout"]
        try requireHittable(checkout, timeout: 5)
        retainDiagnosticScreenshot(
            named: "M2-05-Pull-Request-Overview-And-Checkout",
            of: app.windows.firstMatch,
            in: app
        )
        try click(checkout, timeout: 5)

        let confirm = app.buttons["GitX.PullRequest.CheckoutConfirm"]
        try requireHittable(confirm, timeout: 15)
        retainDiagnosticScreenshot(
            named: "M2-06-Exact-Pull-Request-Checkout-Confirmation",
            of: app.sheets.firstMatch,
            in: app
        )
        try click(confirm, timeout: 5)

        try requireExists(app.staticTexts["Pull Request Checked Out"], timeout: 20)
        retainDiagnosticScreenshot(
            named: "M2-07-Exact-Pull-Request-Checkout-Completed",
            of: app.sheets.firstMatch,
            in: app
        )
        XCTAssertEqual(
            try git(["rev-parse", "--verify", "HEAD"], in: fixture.repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.expectedHead
        )
        XCTAssertEqual(
            try git(["branch", "--show-current"], in: fixture.repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "pr/42"
        )
        XCTAssertEqual(
            try git([
                "for-each-ref", "--format=%(refname)", "refs/remotes/contributor",
            ], in: fixture.repository).split(whereSeparator: \.isNewline).map(String.init),
            ["refs/remotes/contributor/feature"]
        )
        XCTAssertThrowsError(
            try git(["rev-parse", "--verify", "refs/remotes/contributor/decoy-branch"], in: fixture.repository)
        )
        XCTAssertThrowsError(
            try git(["rev-parse", "--verify", "refs/tags/decoy-tag"], in: fixture.repository)
        )
    }

    func testXGitXDeepLinkShowsExplicitMissingObjectChoicesWithoutFetching() throws {
        let repository = try makeWorkingRepository(name: "deep-link")
        try installLocalCanaryRemote(in: repository)
        let missingCommit = String(repeating: "a", count: 40)
        let refsBefore = try references(in: repository)
        let app = try launch(
            repository: repository,
            scenario: "deep-link",
            additionalEnvironment: [
                "GITX_M2_DEEP_LINK": "x-gitx://github.com/gitx/gitx/commit/\(missingCommit)",
            ]
        )

        try requireExists(app.staticTexts["Git Object Is Not Available Locally"], timeout: 15)
        try requireHittable(app.buttons["GitX.DeepLink.Fetch"], timeout: 5)
        try requireHittable(app.buttons["GitX.DeepLink.OpenInBrowser"], timeout: 5)
        retainDiagnosticScreenshot(
            named: "M2-08-Deep-Link-Missing-Object-Choices",
            of: app.sheets.firstMatch,
            in: app
        )
        XCTAssertThrowsError(try git(["cat-file", "-e", "\(missingCommit)^{commit}"], in: repository))
        XCTAssertEqual(try references(in: repository), refsBefore)
        XCTAssertThrowsError(
            try git(["rev-parse", "--verify", "refs/remotes/origin/network-canary"], in: repository)
        )
    }

    func testXGitXDeepLinkWithoutMatchingCheckoutOffersBrowserWithoutCloning() throws {
        let repository = try makeWorkingRepository(name: "deep-link-no-checkout")
        let refsBefore = try references(in: repository)
        let app = try launch(
            repository: repository,
            scenario: "deep-link-no-checkout",
            additionalEnvironment: [
                "GITX_M2_DEEP_LINK": "x-gitx://github.com/gitx/gitx/pull/42",
            ]
        )

        try requireExists(app.staticTexts["No Matching Checkout Is Open"], timeout: 15)
        try requireHittable(app.buttons["GitX.DeepLink.OpenInBrowser"], timeout: 5)
        retainDiagnosticScreenshot(
            named: "M2-09-Deep-Link-No-Matching-Checkout",
            of: app.sheets.firstMatch,
            in: app
        )
        XCTAssertEqual(try references(in: repository), refsBefore)
        XCTAssertEqual(try git(["remote"], in: repository), "")
    }

    func testStagingOffersOneShotCreatePullRequestAfterPushControl() throws {
        let repository = try makeStagingFixture()
        let app = try launch(repository: repository, scenario: "staging-create")

        let createPullRequest = app.checkBoxes["GitX.Staging.CreatePullRequestAfterPush"]
        try requireHittable(createPullRequest, timeout: 15)
        XCTAssertFalse(isChecked(createPullRequest))
        try click(createPullRequest, timeout: 5)
        XCTAssertTrue(isChecked(createPullRequest))
        let push = app.checkBoxes["PushAfterCommit"]
        try requireExists(push, timeout: 5)
        XCTAssertTrue(isChecked(push))
        retainDiagnosticScreenshot(
            named: "M2-10-Staging-One-Shot-Create-Pull-Request",
            of: app.windows.firstMatch,
            in: app
        )
    }

    private func launch(
        repository: URL,
        scenario: String,
        additionalEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
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
            "GITX_M2_UITEST": "1",
            "GITX_M2_SCENARIO": scenario,
        ].merging(additionalEnvironment) { _, value in value }
        activeApplication = app
        app.launch()
        try requireHarnessState("Ready.\(scenario)", in: app, timeout: 15)
        return app
    }

    private func makePushFixture() throws -> (repository: URL, remote: URL, expectedHead: String) {
        let remote = try makeDirectory(name: "push-remote.git")
        _ = try git(["init", "--bare", "--quiet"], in: remote)
        let repository = try makeWorkingRepository(name: "push-source")
        _ = try git([
            "remote", "add", "origin", "https://github.com/contributor/gitx.git",
        ], in: repository)
        _ = try git(["config", "remote.origin.pushurl", remote.path], in: repository)
        _ = try git(["push", "--quiet", "--set-upstream", "origin", "HEAD"], in: repository)
        _ = try git(["switch", "--quiet", "-c", "feature/milestone-2"], in: repository)
        try "second\n".write(
            to: repository.appendingPathComponent("second.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "second.txt"], in: repository)
        _ = try git(["commit", "--quiet", "-m", "Push journey"], in: repository)
        let expectedHead = try git(["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (repository, remote, expectedHead)
    }

    private func makeCheckoutFixture() throws -> (
        repository: URL,
        remote: URL,
        sshCommand: URL,
        expectedHead: String
    ) {
        let contributorRemote = try makeDirectory(name: "contributor.git")
        _ = try git(["init", "--bare", "--quiet"], in: contributorRemote)
        let contributor = try makeWorkingRepository(name: "contributor-source", branch: "feature")
        let expectedHead = try git(["rev-parse", "HEAD"], in: contributor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(["branch", "decoy-branch"], in: contributor)
        _ = try git(["tag", "decoy-tag"], in: contributor)
        _ = try git(["remote", "add", "publish", contributorRemote.path], in: contributor)
        _ = try git([
            "push", "--quiet", "publish", "feature", "decoy-branch", "refs/tags/decoy-tag",
        ], in: contributor)

        let repository = try makeWorkingRepository(name: "checkout-source")
        _ = try git([
            "remote", "add", "contributor", "ssh://git@github.com/contributor/gitx.git",
        ], in: repository)
        let shimDirectory = try makeDirectory(name: "checkout-ssh-shim")
        let sshCommand = shimDirectory.appendingPathComponent("gitx-m2-ssh")
        try """
        #!/bin/sh
        exec /usr/bin/git-upload-pack "$GITX_M2_CHECKOUT_REMOTE_PATH"
        """.write(to: sshCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sshCommand.path
        )
        return (repository, contributorRemote, sshCommand, expectedHead)
    }

    private func makeStagingFixture() throws -> URL {
        let remote = try makeDirectory(name: "staging-remote.git")
        _ = try git(["init", "--bare", "--quiet"], in: remote)
        let repository = try makeWorkingRepository(name: "staging-source")
        _ = try git(["remote", "add", "origin", remote.path], in: repository)
        try "pending\n".write(
            to: repository.appendingPathComponent("pending.txt"),
            atomically: true,
            encoding: .utf8
        )
        return repository
    }

    private func installLocalCanaryRemote(in repository: URL) throws {
        let remote = try makeDirectory(name: "deep-link-canary.git")
        _ = try git(["init", "--bare", "--quiet"], in: remote)
        let source = try makeWorkingRepository(name: "deep-link-canary-source", branch: "network-canary")
        _ = try git(["remote", "add", "publish", remote.path], in: source)
        _ = try git(["push", "--quiet", "publish", "network-canary"], in: source)
        _ = try git(["remote", "add", "origin", remote.path], in: repository)
    }

    private func makeWorkingRepository(name: String, branch: String = "main") throws -> URL {
        let repository = try makeDirectory(name: name)
        _ = try git(["init", "--quiet", "--initial-branch", branch], in: repository)
        _ = try git(["config", "user.name", "GitX UI Tests"], in: repository)
        _ = try git(["config", "user.email", "ui-tests@gitx.invalid"], in: repository)
        try "fixture\n".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "README.md"], in: repository)
        _ = try git(["commit", "--quiet", "-m", "Fixture"], in: repository)
        return repository
    }

    private func makeDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-m2-\(UUID().uuidString)-\(name)", isDirectory: true)
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

    private func references(in repository: URL) throws -> [String] {
        try git(["for-each-ref", "--format=%(refname):%(objectname)"], in: repository)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
    }

    private func requireExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Expected UI element to exist: \(element)", file: file, line: line)
            throw Milestone2UIError.elementUnavailable
        }
    }

    private func requireHarnessState(
        _ state: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = app.descendants(matching: .any)["GitX.M2.Harness.\(state)"]
        let failure = app.descendants(matching: .any)["GitX.M2.Harness.Failure"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in expected.exists || failure.exists },
            object: app
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Milestone 2 UI harness did not reach state \(state)", file: file, line: line)
            throw Milestone2UIError.harnessUnavailable
        }
        guard !failure.exists else {
            XCTFail("Milestone 2 UI harness failed: \(failure.label)", file: file, line: line)
            throw Milestone2UIError.harnessUnavailable
        }
    }

    private func requireHittable(
        _ element: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isHittable
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Expected UI element to become hittable: \(element)", file: file, line: line)
            throw Milestone2UIError.elementUnavailable
        }
    }

    private func click(_ element: XCUIElement, timeout: TimeInterval) throws {
        try requireHittable(element, timeout: timeout)
        element.click()
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

    private func isChecked(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        return element.value as? String == "1"
    }

    private func elementText(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private enum GitFixtureError: Error {
        case commandFailed([String], String)
    }

    private enum Milestone2UIError: Error {
        case elementUnavailable
        case harnessUnavailable
    }
}
