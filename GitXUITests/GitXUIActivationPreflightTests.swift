import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test-case lifetime, while all mutable application and fixture state is confined to the main actor.
final class GitXUIActivationPreflightTests: XCTestCase, @unchecked Sendable {
    private let fixtureWorkspace = GitXUITestFixtureWorkspace(prefix: "gitx-ui-preflight")
    private var activeApplication: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCUITest invokes teardown on the main thread, where application automation and fixture cleanup are confined.
        MainActor.assumeIsolated {
            if testRun?.hasSucceeded == false, let app = activeApplication {
                retainScreenshot(named: "UI-Activation-Preflight-Failure")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "UI-Activation-Preflight-Accessibility-Hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let state = XCTAttachment(
                    string: "applicationState=\(app.state.rawValue)\nfixtures=\(fixtureWorkspace.directories.map(\.path).joined(separator: "\n"))"
                )
                state.name = "UI-Activation-Preflight-State"
                state.lifetime = .keepAlways
                add(state)
            }
            activeApplication?.terminate()
            activeApplication = nil
            fixtureWorkspace.removeAll()
        }
        super.tearDown()
    }

    func testRepositoryWindowActivates() throws {
        NSLog("[GitXUIActivationPreflightTests] preparing deterministic repository fixture")
        let repository = try makeRepositoryFixture()
        let isolatedHome = try fixtureWorkspace.makeIsolatedHome(named: "home")

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
        ]
        activeApplication = app

        NSLog("[GitXUIActivationPreflightTests] launching GitX for %@", repository.path)
        app.launch()
        app.activate()
        let foreground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 15), .completed)
        let repositoryWindow = app.windows["\(repository.lastPathComponent) (branch: main)"]
        XCTAssertTrue(repositoryWindow.waitForExistence(timeout: 20))
        let uncommittedChanges = repositoryWindow.buttons["Uncommitted Changes"]
        XCTAssertTrue(uncommittedChanges.waitForExistence(timeout: 15))
        XCTAssertTrue(uncommittedChanges.isHittable)
        NSLog("[GitXUIActivationPreflightTests] repository window is active and ready")
        retainScreenshot(named: "UI-Activation-Preflight")
    }

    private func makeRepositoryFixture() throws -> URL {
        let repository = try makeDirectory(named: "repository")
        _ = try git(["init", "--quiet", "--initial-branch", "main"], in: repository)
        _ = try git(["config", "user.name", "GitX UI Preflight"], in: repository)
        _ = try git(["config", "user.email", "ui-preflight@gitx.invalid"], in: repository)
        try "fixture\n".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "README.md"], in: repository)
        _ = try git(["commit", "--quiet", "-m", "Fixture"], in: repository)
        return repository
    }

    private func makeDirectory(named name: String) throws -> URL {
        try fixtureWorkspace.makeDirectory(named: name)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        try fixtureWorkspace.git(arguments, in: directory)
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
