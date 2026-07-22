import XCTest

final class IndexMutationServiceTests: XCTestCase {
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
            return try results.isEmpty ? "" : results.removeFirst().get()
        }

        func data(
            withArguments _: [String],
            completion: @escaping (Data?, Error?) -> Void
        ) {
            completion(nil, nil)
        }
    }

    private let commandError = NSError(
        domain: "IndexMutationServiceTests",
        code: 42,
        userInfo: [NSLocalizedDescriptionKey: "expected failure"]
    )

    func testStageChunksPathsAtOneThousandAndPreservesUnicode() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let paths = (0 ... 1000).map { "folder/file-\($0)-ü.txt" }

        XCTAssertTrue(service.stagePaths(paths, error: nil))

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].arguments, ["update-index", "--add", "--remove", "-z", "--stdin"])
        XCTAssertEqual(runner.calls[0].input?.filter { $0 == "\0" }.count, 1000)
        XCTAssertTrue(runner.calls[1].input?.contains("file-1000-ü.txt\0") == true)
    }

    func testEmptyStageAndUnstageAreSuccessfulNoOps() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)

        XCTAssertTrue(service.stagePaths([], error: nil))
        XCTAssertTrue(service.unstagePaths([], parentTree: "HEAD", error: nil))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUnstageBuildsResetCommandAndReturnsRunnerFailure() {
        let runner = CommandRunnerFake()
        runner.results = [.failure(commandError)]
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?

        XCTAssertFalse(service.unstagePaths(["one.txt"], parentTree: "HEAD^", error: &error))

        XCTAssertEqual(error, commandError)
        XCTAssertEqual(runner.calls[0].arguments, ["reset", "--quiet", "HEAD^", "--", "one.txt"])
    }

    func testDiscardUsesNulDelimitedInputAndReportsFailure() {
        let runner = CommandRunnerFake()
        runner.results = [.success(""), .failure(commandError)]
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)

        XCTAssertTrue(service.discardPaths(["one.txt", "two ü.txt"], error: nil))
        var error: NSError?
        XCTAssertFalse(service.discardPaths(["blocked.txt"], error: &error))

        XCTAssertEqual(runner.calls[0].input, "one.txt\0two ü.txt")
        XCTAssertEqual(error, commandError)
    }

    func testPatchNormalizesNewlineAndBuildsForwardAndReverseCommands() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)

        XCTAssertTrue(service.applyPatch("patch", stage: true, reverse: false, error: nil))
        XCTAssertTrue(service.applyPatch("reverse\n", stage: false, reverse: true, error: nil))

        XCTAssertEqual(runner.calls[0].arguments, ["apply", "--unidiff-zero", "--cached"])
        XCTAssertEqual(runner.calls[0].input, "patch\n")
        XCTAssertEqual(runner.calls[1].arguments, ["apply", "--unidiff-zero", "--reverse"])
        XCTAssertEqual(runner.calls[1].input, "reverse\n")
    }

    func testEmptyPatchReturnsInvalidInputWithoutLaunchingGit() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?

        XCTAssertFalse(service.applyPatch("", stage: true, reverse: false, error: &error))

        XCTAssertEqual(error?.domain, "PBGitIndexMutationError")
        XCTAssertEqual(error?.code, 2)
        XCTAssertEqual(error?.localizedDescription, "The patch is empty and cannot be applied.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testDiffSelectsStagedAndTrackedCommands() {
        let runner = CommandRunnerFake()
        runner.results = [.success("staged"), .success("unstaged")]
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)

        XCTAssertEqual(
            service.diff(
                forPath: "partial.txt",
                status: 1,
                hasStagedChanges: true,
                staged: true,
                parentTree: "HEAD^",
                contextLines: 7,
                error: nil
            ),
            "staged"
        )
        XCTAssertEqual(
            service.diff(
                forPath: "partial.txt",
                status: 1,
                hasStagedChanges: true,
                staged: false,
                parentTree: "HEAD^",
                contextLines: 7,
                error: nil
            ),
            "unstaged"
        )

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["diff-index", "-U7", "--cached", "HEAD^", "--", "partial.txt"],
                ["diff-files", "-U7", "--", "partial.txt"],
            ]
        )
    }
}
