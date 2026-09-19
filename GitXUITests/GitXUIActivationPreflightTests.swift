import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test-case lifetime, while all mutable application and fixture state is confined to the main actor.
final class GitXUIActivationPreflightTests: XCTestCase, @unchecked Sendable {
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
                retainScreenshot(named: "UI-Activation-Preflight-Failure")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "UI-Activation-Preflight-Accessibility-Hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let state = XCTAttachment(
                    string: "applicationState=\(app.state.rawValue)\nfixtures=\(temporaryDirectories.map(\.path).joined(separator: "\n"))"
                )
                state.name = "UI-Activation-Preflight-State"
                state.lifetime = .keepAlways
                add(state)
            }
            activeApplication?.terminate()
            activeApplication = nil
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            temporaryDirectories.removeAll()
        }
        super.tearDown()
    }

    func testRepositoryWindowActivates() throws {
        NSLog("[GitXUIActivationPreflightTests] preparing deterministic repository fixture")
        let repository = try makeRepositoryFixture()
        let isolatedHome = try makeDirectory(named: "home")
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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Uncommitted Changes"].waitForExistence(timeout: 15))
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-ui-preflight-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let selectedGit = URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/git")
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

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum GitFixtureError: Error {
        case commandFailed([String], String)
    }
}
