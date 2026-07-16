import XCTest

final class IndexCommitServiceTests: XCTestCase {
    private final class CommandRunnerFake: NSObject, PBIndexCommandRunning {
        struct Call {
            let arguments: [String]
            let input: String?
            let environment: [String: Any]?
        }

        var results: [Result<String, Error>] = []
        private(set) var calls: [Call] = []

        func output(
            withArguments arguments: [String],
            input: String?,
            environment: [String: Any]?
        ) throws -> String {
            calls.append(Call(arguments: arguments, input: input, environment: environment))
            return try results.removeFirst().get()
        }
    }

    private final class HookRunnerFake: NSObject, PBIndexHookRunning {
        struct Call: Equatable {
            let name: String
            let arguments: [String]
        }

        var handlers: [String: ([String]) throws -> Void] = [:]
        private(set) var calls: [Call] = []

        func executeHook(_ name: String, arguments: [String]) throws {
            calls.append(Call(name: name, arguments: arguments))
            try handlers[name]?(arguments)
        }
    }

    private var rootURL: URL!
    private var gitDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        gitDirectory = rootURL.appendingPathComponent("repo.git")
        temporaryDirectory = rootURL.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        rootURL = nil
        gitDirectory = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testPrepareCommitMessageRunsHookTrimsOneNewlineAndCleansTemporaryFile() throws {
        let runner = CommandRunnerFake()
        let hooks = HookRunnerFake()
        hooks.handlers["prepare-commit-msg"] = { arguments in
            try "prepared\n\n".write(toFile: arguments[0], atomically: true, encoding: .utf8)
        }
        let service = makeService(runner: runner, hooks: hooks)

        let message = try service.prepareCommitMessage(
            forAmend: false,
            headSHA: nil,
            existingMessage: nil
        )

        XCTAssertEqual(message, "prepared\n")
        XCTAssertEqual(hooks.calls.count, 1)
        XCTAssertEqual(hooks.calls[0].name, "prepare-commit-msg")
        XCTAssertEqual(hooks.calls[0].arguments.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testPrepareAmendSeedsMessageAndPassesCommitSourceAndSHA() throws {
        let runner = CommandRunnerFake()
        let hooks = HookRunnerFake()
        hooks.handlers["prepare-commit-msg"] = { arguments in
            XCTAssertEqual(try String(contentsOfFile: arguments[0], encoding: .utf8), "old message")
            try "amended".write(toFile: arguments[0], atomically: true, encoding: .utf8)
        }
        let service = makeService(runner: runner, hooks: hooks)

        let message = try service.prepareCommitMessage(
            forAmend: true,
            headSHA: String(repeating: "a", count: 40),
            existingMessage: "old message"
        )

        XCTAssertEqual(message, "amended")
        XCTAssertEqual(
            Array(hooks.calls[0].arguments.dropFirst()),
            ["commit", String(repeating: "a", count: 40)]
        )
    }

    func testPrepareHookFailureIncludesTaskOutputAndCleansTemporaryFile() throws {
        let runner = CommandRunnerFake()
        let hooks = HookRunnerFake()
        hooks.handlers["prepare-commit-msg"] = { _ in throw self.hookError(output: "prepare denied") }
        let service = makeService(runner: runner, hooks: hooks)
        XCTAssertThrowsError(
            try service.prepareCommitMessage(
                forAmend: false,
                headSHA: nil,
                existingMessage: nil
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "prepare-commit-msg hook failed:\nprepare denied")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testVerifiedCommitRunsHooksUsesEditedMessageAndUpdatesHead() {
        let tree = String(repeating: "1", count: 40)
        let commit = String(repeating: "2", count: 40)
        let runner = CommandRunnerFake()
        runner.results = [.success("\(tree)\n"), .success("\(commit)\n"), .success("")]
        let hooks = HookRunnerFake()
        hooks.handlers["commit-msg"] = { arguments in
            try "edited by hook".write(toFile: arguments[0], atomically: true, encoding: .utf8)
        }
        let service = makeService(runner: runner, hooks: hooks)
        var progress: [String] = []

        let result = service.commit(
            with: request(message: "subject\nbody", verify: true, hasHead: true),
            progress: { progress.append($0) }
        )

        XCTAssertEqual(result.kind, .success)
        XCTAssertEqual(result.sha, commit)
        XCTAssertTrue(result.postCommitHookSucceeded)
        XCTAssertEqual(result.message, "Successfully created commit \(commit)")
        XCTAssertEqual(
            progress,
            ["Creating tree", "Creating commit", "Running hooks", "Updating HEAD", "Running post-commit hook"]
        )
        XCTAssertEqual(runner.calls[1].arguments, ["commit-tree", tree, "-p", "HEAD"])
        XCTAssertEqual(runner.calls[1].input, "edited by hook")
        XCTAssertEqual(runner.calls[2].arguments, ["update-ref", "-m", "commit: subject", "HEAD", commit])
        XCTAssertEqual(hooks.calls.map(\.name), ["pre-commit", "commit-msg", "post-commit"])
    }

    func testAmendPreservesParentsEnvironmentAndReportsPostCommitFailure() {
        let tree = String(repeating: "3", count: 40)
        let commit = String(repeating: "4", count: 40)
        let parents = [String(repeating: "5", count: 40), String(repeating: "6", count: 40)]
        let authorDate = Date(timeIntervalSince1970: 1234)
        let runner = CommandRunnerFake()
        runner.results = [.success(tree), .success(commit), .success("")]
        let hooks = HookRunnerFake()
        hooks.handlers["post-commit"] = { _ in throw self.hookError() }
        let service = makeService(runner: runner, hooks: hooks)

        let result = service.commit(
            with: request(
                message: "amended",
                verify: false,
                gpgSign: true,
                amend: true,
                environment: ["GIT_AUTHOR_DATE": authorDate],
                parentSHAs: parents,
                hasHead: true
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.kind, .success)
        XCTAssertFalse(result.postCommitHookSucceeded)
        XCTAssertEqual(result.message, "Post-commit hook failed, but successfully created commit \(commit)")
        XCTAssertEqual(
            runner.calls[1].arguments,
            ["commit-tree", tree, "-p", parents[0], "-p", parents[1], "--gpg-sign"]
        )
        XCTAssertEqual(runner.calls[1].environment?["GIT_AUTHOR_DATE"] as? Date, authorDate)
        XCTAssertEqual(hooks.calls.map(\.name), ["post-commit"])
    }

    func testTreeLookupAndInvalidTreeFailuresAreDistinct() {
        let commandError = NSError(domain: "test", code: 1)
        let failingRunner = CommandRunnerFake()
        failingRunner.results = [.failure(commandError)]
        let failingResult = makeService(runner: failingRunner, hooks: HookRunnerFake()).commit(
            with: request(),
            progress: { _ in }
        )
        let invalidRunner = CommandRunnerFake()
        invalidRunner.results = [.success("not-a-tree")]
        let invalidResult = makeService(runner: invalidRunner, hooks: HookRunnerFake()).commit(
            with: request(),
            progress: { _ in }
        )

        XCTAssertEqual(failingResult.kind, .failure)
        XCTAssertEqual(failingResult.message, "Failed to lookup tree")
        XCTAssertEqual(invalidResult.kind, .failure)
        XCTAssertEqual(invalidResult.message, "Creating tree failed")
    }

    func testVerificationHookFailuresStopBeforeCommitCreation() {
        let tree = String(repeating: "7", count: 40)
        let preRunner = CommandRunnerFake()
        preRunner.results = [.success(tree)]
        let preHooks = HookRunnerFake()
        preHooks.handlers["pre-commit"] = { _ in throw self.hookError(output: "pre denied") }
        let preResult = makeService(runner: preRunner, hooks: preHooks).commit(
            with: request(verify: true),
            progress: { _ in }
        )

        let messageRunner = CommandRunnerFake()
        messageRunner.results = [.success(tree)]
        let messageHooks = HookRunnerFake()
        messageHooks.handlers["commit-msg"] = { _ in throw self.hookError() }
        let messageResult = makeService(runner: messageRunner, hooks: messageHooks).commit(
            with: request(verify: true),
            progress: { _ in }
        )

        XCTAssertEqual(preResult.kind, .hookFailure)
        XCTAssertEqual(preResult.message, "Pre-commit hook failed:\npre denied")
        XCTAssertEqual(preRunner.calls.count, 1)
        XCTAssertEqual(messageResult.kind, .hookFailure)
        XCTAssertEqual(messageResult.message, "Commit-msg hook failed")
        XCTAssertEqual(messageHooks.calls.map(\.name), ["pre-commit", "commit-msg"])
    }

    func testCommitCreationReportsSigningGenericAndInvalidOutputFailures() {
        let tree = String(repeating: "8", count: 40)
        let signingError = NSError(
            domain: "test",
            code: 2,
            userInfo: [PBTaskTerminationOutputKey: "error: cannot run gpg: unavailable"]
        )
        let signingRunner = CommandRunnerFake()
        signingRunner.results = [.success(tree), .failure(signingError)]
        let signingResult = makeService(runner: signingRunner, hooks: HookRunnerFake()).commit(
            with: request(gpgSign: true),
            progress: { _ in }
        )

        let genericRunner = CommandRunnerFake()
        genericRunner.results = [.success(tree), .failure(NSError(domain: "test", code: 3))]
        let genericResult = makeService(runner: genericRunner, hooks: HookRunnerFake()).commit(
            with: request(),
            progress: { _ in }
        )

        let invalidRunner = CommandRunnerFake()
        invalidRunner.results = [.success(tree), .success("short")]
        let invalidResult = makeService(runner: invalidRunner, hooks: HookRunnerFake()).commit(
            with: request(),
            progress: { _ in }
        )

        XCTAssertTrue(signingResult.message.hasPrefix("GPG signing seems to have failed."))
        XCTAssertEqual(genericResult.message, "Could not create a commit object")
        XCTAssertEqual(invalidResult.message, "Could not create a commit object")
    }

    func testUpdateRefFailureStopsBeforePostCommitHook() {
        let tree = String(repeating: "9", count: 40)
        let commit = String(repeating: "a", count: 40)
        let runner = CommandRunnerFake()
        runner.results = [
            .success(tree),
            .success(commit),
            .failure(NSError(domain: "test", code: 4)),
        ]
        let hooks = HookRunnerFake()

        let result = makeService(runner: runner, hooks: hooks).commit(
            with: request(),
            progress: { _ in }
        )

        XCTAssertEqual(result.kind, .failure)
        XCTAssertEqual(result.message, "Could not update HEAD")
        XCTAssertTrue(hooks.calls.isEmpty)
    }

    private func makeService(
        runner: CommandRunnerFake,
        hooks: HookRunnerFake
    ) -> PBIndexCommitService {
        PBIndexCommitService(
            runner: runner,
            hookRunner: hooks,
            gitDirectory: gitDirectory,
            temporaryDirectory: temporaryDirectory
        )
    }

    private func request(
        message: String = "subject",
        verify: Bool = false,
        gpgSign: Bool = false,
        amend: Bool = false,
        environment: [String: Any]? = nil,
        parentSHAs: [String] = [],
        hasHead: Bool = false
    ) -> PBIndexCommitRequest {
        PBIndexCommitRequest(
            message: message,
            verify: verify,
            gpgSign: gpgSign,
            amend: amend,
            environment: environment,
            parentSHAs: parentSHAs,
            hasHead: hasHead
        )
    }

    private func hookError(output: String? = nil) -> NSError {
        let taskError = NSError(
            domain: "task",
            code: 17,
            userInfo: output.map { [PBTaskTerminationOutputKey: $0] } ?? [:]
        )
        return NSError(
            domain: "hook",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: taskError]
        )
    }
}
