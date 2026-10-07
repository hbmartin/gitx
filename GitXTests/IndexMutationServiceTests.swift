import XCTest

final class IndexMutationServiceTests: XCTestCase {
    private final class ScriptedRepository: PBGitRepository {
        private let script: String

        init(script: String) {
            self.script = script
            super.init()
        }

        override func task(withArguments _: [Any]?) -> PBTask {
            // The production runner calls the repository's Objective-C task factory.
            PBTask(launchPath: "/bin/sh", arguments: ["-c", script], inDirectory: nil)
        }
    }

    func testNativeRunnerPreservesBinaryInputAndAppliesExplicitEnvironment() throws {
        let repository = ScriptedRepository(script: "printf '%s:' \"$GITX_INDEX_TEST_VALUE\"; cat")
        let runner = IndexRepositoryCommandRunner(repository: repository)
        let input = Data("one\0two\n".utf8)

        let output = try XCTUnwrap(runner.output(withArguments: ["test-input"], inputData: input,
                                                 environment: ["GITX_INDEX_TEST_VALUE": "environment"]))

        XCTAssertEqual(Data(output.utf8), Data("environment:one\0two\n".utf8))
        withExtendedLifetime(repository) {}
    }

    func testNativeRunnerReturnsEmptyStringForNonUTF8CommandOutputInBothInputModes() throws {
        let repository = ScriptedRepository(script: "printf '\\377'")
        let runner = IndexRepositoryCommandRunner(repository: repository)

        XCTAssertEqual(try runner.output(withArguments: ["test-output"], input: nil, environment: nil), "")
        XCTAssertEqual(try runner.output(withArguments: ["test-output"], inputData: nil, environment: nil), "")
        withExtendedLifetime(repository) {}
    }

    private final class CommandRunnerFake: NSObject, PBIndexBinaryCommandRunning {
        struct Call {
            let arguments: [String]
            let input: String?
            let inputData: Data?
            let environment: [String: Any]?
        }

        var results: [Result<String, Error>] = []
        var resetHelp = ""
        var literalVersion = ""
        var resetHelpError: NSError?
        private(set) var calls: [Call] = []

        func output(
            withArguments arguments: [String],
            input: String?,
            environment: [String: Any]?
        ) throws -> String {
            calls.append(Call(arguments: arguments, input: input, inputData: input.map { Data($0.utf8) }, environment: environment))
            if arguments == ["reset", "-h"] {
                if let resetHelpError {
                    throw resetHelpError
                }
                return resetHelp
            }
            if arguments == ["--literal-pathspecs", "--version"] {
                return literalVersion
            }
            return try results.isEmpty ? "" : results.removeFirst().get()
        }

        func output(withArguments arguments: [String], inputData: Data?, environment: [String: Any]?) throws -> String {
            calls.append(Call(arguments: arguments, input: inputData.flatMap { String(data: $0, encoding: .utf8) }, inputData: inputData, environment: environment))
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

    func testServiceDoesNotRetainClosedRepositoryAndCommandsFailNormally() throws {
        var repository: PBGitRepository? = PBGitRepository()
        weak let releasedRepository = repository
        let service = try PBIndexMutationService(repository: XCTUnwrap(repository))
        repository = nil
        XCTAssertNil(releasedRepository, "Index services must not retain a closed repository or its watcher")

        var error: NSError?
        XCTAssertFalse(service.stageRawPaths([Data("tracked.txt".utf8)], error: &error))
        XCTAssertEqual(error?.domain, "PBGitIndexCommandError")
        XCTAssertEqual(error?.code, 1)
        XCTAssertTrue(error?.localizedDescription.contains("repository closed") == true)

        error = nil
        XCTAssertNil(service.diff(forPath: "tracked.txt", status: 1, hasStagedChanges: true,
                                  staged: true, parentTree: "HEAD", contextLines: 3, error: &error))
        XCTAssertEqual(error?.domain, "PBGitIndexCommandError")

        error = nil
        XCTAssertNil(service.diff(forPath: "new.txt", status: 0, hasStagedChanges: false,
                                  staged: false, parentTree: "HEAD", contextLines: 3, error: &error))
        XCTAssertEqual(error?.domain, "PBGitIndexMutationError")
        XCTAssertEqual(error?.code, 1)
        XCTAssertTrue(service.stagePaths([], error: nil), "An empty selection remains a successful no-op")
    }

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

    func testStageStopsAtSecondChunkFailureAndReturnsThatError() {
        let runner = CommandRunnerFake()
        runner.results = [.success(""), .failure(commandError), .success("")]
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let paths = (0 ... 2000).map { "chunk-\($0).txt" }
        var error: NSError?

        XCTAssertFalse(service.stagePaths(paths, error: &error))

        XCTAssertEqual(error, commandError)
        XCTAssertEqual(runner.calls.count, 2, "The third chunk must not run after the second fails")
        XCTAssertEqual(runner.calls[0].input?.filter { $0 == "\0" }.count, 1000)
        XCTAssertEqual(runner.calls[1].input?.filter { $0 == "\0" }.count, 1000)
        XCTAssertTrue(runner.calls[0].input?.hasPrefix("chunk-0.txt\0") == true)
        XCTAssertTrue(runner.calls[1].input?.hasPrefix("chunk-1000.txt\0") == true)
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
        XCTAssertEqual(runner.calls.last?.arguments, ["reset", "--quiet", "HEAD^", "--", "one.txt"])
    }

    func testUnstageRejectsUnsafeLiteralNamesWhenCapabilitiesCannotBeEstablished() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?

        XCTAssertFalse(service.unstagePaths(["ordinary.txt", ":(glob)*"], parentTree: "HEAD", error: &error))
        XCTAssertNotNil(error)
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--quiet") },
                       "Unsafe selections must be rejected before any mutating reset chunk")
    }

    func testLegacyUnstageRejectsMetacharactersInsideUnicodeGraphemes() {
        for name in ["*️⃣.md", "*́.md", "?́.txt", "[́name].txt"] {
            let runner = CommandRunnerFake()
            let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
            XCTAssertFalse(service.unstagePaths([name], parentTree: "HEAD", error: nil), name)
            XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--quiet") })
        }
    }

    func testLegacyUnstageKeepsBOMBytesInArgument() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        XCTAssertTrue(service.unstagePaths(["\u{FEFF}notes"], parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls.last?.arguments.last, "\u{FEFF}notes")
    }

    func testDiscardUsesNulDelimitedInputAndReportsFailure() {
        let runner = CommandRunnerFake()
        runner.results = [.success(""), .failure(commandError)]
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)

        XCTAssertTrue(service.discardPaths(["one.txt", "two ü.txt"], error: nil))
        var error: NSError?
        XCTAssertFalse(service.discardPaths(["blocked.txt"], error: &error))

        XCTAssertEqual(runner.calls[0].input, "one.txt\0two ü.txt\0")
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

    func testDiffInsertsIgnoreWhitespaceFlagAfterContext() {
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
                contextLines: 3,
                ignoreWhitespace: true,
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
                contextLines: 3,
                ignoreWhitespace: true,
                error: nil
            ),
            "unstaged"
        )

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["diff-index", "-U3", "-w", "--cached", "HEAD^", "--", "partial.txt"],
                ["diff-files", "-U3", "-w", "--", "partial.txt"],
            ]
        )
    }

    func testModernUnstageUsesLiteralNulInputForOrdinaryAndRawNamesAndCachesProbe() {
        let runner = CommandRunnerFake()
        runner.resetHelpError = NSError(domain: "PBTask", code: 129, userInfo: [
            PBTaskTerminationStatusKey: 129,
            PBTaskTerminationOutputKey: "usage: git reset [--pathspec-from-file=<file>] [--pathspec-file-nul]",
        ])
        runner.literalVersion = "git version 2.50.0"
        let repository = PBGitRepository()
        let service = PBIndexMutationService(repository: repository, runner: runner)
        let invalid = Data([0x66, 0xFF])
        XCTAssertTrue(service.unstageRawPaths([Data("ordinary.txt".utf8), invalid], parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls.last?.arguments, [
            "--literal-pathspecs", "reset", "--quiet", "HEAD",
            "--pathspec-from-file=-", "--pathspec-file-nul", "--",
        ])
        var expected = Data("ordinary.txt\0".utf8)
        expected.append(invalid)
        expected.append(0)
        XCTAssertEqual(runner.calls.last?.inputData, expected)
        XCTAssertEqual(runner.calls.first?.environment?["LC_ALL"] as? String, "C")
        XCTAssertTrue(service.unstagePaths(["second.txt"], parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls.filter { $0.arguments == ["reset", "-h"] }.count, 1)
        XCTAssertEqual(runner.calls.last?.inputData, Data("second.txt\0".utf8))
        withExtendedLifetime(repository) {}
    }

    func testOlderGitWithLiteralCapabilityUsesSafeArgvForMagicWildcardAndBackslashNames() {
        let runner = CommandRunnerFake()
        runner.resetHelp = "usage: git reset [--mixed]"
        runner.literalVersion = "git version 1.9.0"
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let paths = [":(glob)*", "star*.txt", "question?.txt", "bracket[one].txt", "back\\slash.txt"]
        XCTAssertTrue(service.unstagePaths(paths, parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls.last?.arguments, ["--literal-pathspecs", "reset", "--quiet", "HEAD", "--"] + paths)
        XCTAssertNil(runner.calls.last?.input)
    }

    func testUnknownOrPartialCapabilitiesRejectEntireUnsafeSelectionBeforeAnyChunk() {
        for help in [
            "",
            "usage: git reset --pathspec-from-file=<file>",
            "usage: git reset --pathspec-file-nul",
            "--pathspec-from-file=<file> --pathspec-file-nul",
        ] {
            let runner = CommandRunnerFake()
            runner.resetHelp = help
            runner.literalVersion = "git version 2.50.0"
            let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
            var error: NSError?
            let paths = (0 ... 1000).map { Data("ordinary-\($0).txt".utf8) } + [Data([0xFF])]
            XCTAssertFalse(service.unstageRawPaths(paths, parentTree: "HEAD", error: &error))
            XCTAssertEqual(error?.code, 4)
            XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--quiet") })
        }
        let runner = CommandRunnerFake()
        runner.resetHelp = "usage: git reset --pathspec-from-file=<file> --pathspec-file-nul"
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        XCTAssertFalse(service.unstageRawPaths([Data([0xFF])], parentTree: "HEAD", error: nil))
        XCTAssertTrue(service.unstagePaths(["plain.txt"], parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls.last?.arguments, ["reset", "--quiet", "HEAD", "--", "plain.txt"])
    }

    func testRawStageAndDiscardPreserveInvalidBytesAndValidateAllPathsBeforeMutation() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let raw = Data([0x66, 0xFF])
        XCTAssertTrue(service.stageRawPaths([raw], error: nil))
        XCTAssertEqual(runner.calls.last?.inputData, Data([0x66, 0xFF, 0]))
        XCTAssertTrue(service.discardRawPaths([raw, Data("literal*.txt".utf8)], error: nil))
        var expected = raw
        expected.append(0)
        expected.append(contentsOf: "literal*.txt".utf8)
        expected.append(0)
        XCTAssertEqual(runner.calls.last?.inputData, expected)
        let before = runner.calls.count
        var error: NSError?
        XCTAssertFalse(service.stageRawPaths([Data("safe".utf8), Data()], error: &error))
        XCTAssertFalse(service.discardRawPaths([Data("safe".utf8), Data([0])], error: &error))
        XCTAssertFalse(service.unstageRawPaths([Data([0])], parentTree: "HEAD", error: &error))
        XCTAssertEqual(error?.code, 2)
        XCTAssertEqual(runner.calls.count, before)
        XCTAssertTrue(service.discardRawPaths([], error: nil))
    }

    func testRawDiffNeverResolvesInvalidBytesThroughAnEscapedDisplayName() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?
        XCTAssertNil(service.diff(forRawPath: Data([0x66, 0xFF]), displayPath: "f\\xFF",
                                  status: 1, hasStagedChanges: false, staged: false, parentTree: "HEAD",
                                  contextLines: 3, ignoreWhitespace: false, error: &error))
        XCTAssertEqual(error?.code, 3)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testStringOnlyRunnerPrevalidatesAllChunksWithoutLossyFallback() {
        final class StringOnlyRunner: NSObject, PBIndexCommandRunning {
            var calls = 0
            var input: String?
            func output(withArguments _: [String], input: String?, environment _: [String: Any]?) throws -> String {
                calls += 1
                self.input = input
                return ""
            }

            func data(withArguments _: [String], completion: @escaping (Data?, Error?) -> Void) {
                completion(nil, nil)
            }
        }
        let runner = StringOnlyRunner()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let mixed = (0 ... 1000).map { Data("ordinary-\($0).txt".utf8) } + [Data([0xFF])]
        XCTAssertFalse(service.stageRawPaths(mixed, error: nil))
        XCTAssertFalse(service.discardRawPaths(mixed, error: nil))
        XCTAssertFalse(service.unstageRawPaths(mixed, parentTree: "HEAD", error: nil))
        XCTAssertEqual(runner.calls, 0)
        XCTAssertTrue(service.stagePaths(["ordinary ü.txt"], error: nil))
        XCTAssertEqual(runner.input, "ordinary ü.txt\0")
    }

    func testUnsafeUTF8DiffRequiresEstablishedLiteralCapability() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?
        XCTAssertNil(service.diff(forPath: "wild*.txt", status: 1, hasStagedChanges: false, staged: false,
                                  parentTree: "HEAD", contextLines: 3, error: &error))
        XCTAssertEqual(error?.code, 4)
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("diff-files") })
        let supported = CommandRunnerFake()
        supported.literalVersion = "git version 1.9.0"
        supported.results = [.success("literal diff")]
        let literalService = PBIndexMutationService(repository: PBGitRepository(), runner: supported)
        XCTAssertEqual(literalService.diff(forPath: "wild*.txt", status: 1, hasStagedChanges: false, staged: false,
                                           parentTree: "HEAD", contextLines: 3, error: nil), "literal diff")
        XCTAssertEqual(supported.calls.last?.arguments, ["--literal-pathspecs", "diff-files", "-U3", "--", "wild*.txt"])
    }

    func testLiteralCommandBuilderKeepsOrdinaryNamesCompatibleWithoutProbingGit() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        let path = "nested/ordinary ü.txt"

        XCTAssertEqual(service.literalArguments(forRawPath: Data(path.utf8), commandArguments: ["blame", "-p"], error: nil),
                       ["blame", "-p", "--", path])
        XCTAssertEqual(service.literalArguments(forRawPath: Data(path.utf8), commandArguments: ["log", "--follow"], error: nil),
                       ["log", "--follow", "--", path])
        XCTAssertTrue(runner.calls.isEmpty, "Ordinary paths remain available on supported older Git executables")
    }

    func testLiteralCommandBuilderPreservesMetacharacterNamesAndCachesModernCapability() {
        let runner = CommandRunnerFake()
        runner.literalVersion = "git version 2.42.0"
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        for path in ["wild*.txt", "question?.txt", "bracket[1].txt", ":(glob)*", "back\\slash.txt"] {
            XCTAssertEqual(service.literalArguments(forRawPath: Data(path.utf8), commandArguments: ["blame", "-p"], error: nil),
                           ["--literal-pathspecs", "blame", "-p", "--", path])
            XCTAssertEqual(service.literalArguments(forRawPath: Data(path.utf8), commandArguments: ["log", "--follow"], error: nil),
                           ["--literal-pathspecs", "log", "--follow", "--", path])
        }
        XCTAssertEqual(runner.calls.map(\.arguments), [["reset", "-h"], ["--literal-pathspecs", "--version"]])
    }

    func testLiteralCommandBuilderRejectsUnsupportedMetacharactersBeforeLaunchingCommands() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        for path in ["wild*.txt", ":(glob)*", "back\\slash.txt"] {
            var error: NSError?
            XCTAssertNil(service.literalArguments(forRawPath: Data(path.utf8), commandArguments: ["blame", "-p"], error: &error))
            XCTAssertEqual(error?.domain, "PBGitIndexMutationError")
            XCTAssertEqual(error?.code, 4)
            XCTAssertTrue(error?.localizedDescription.contains("cannot safely address") == true)
        }
        XCTAssertEqual(runner.calls.map(\.arguments), [["reset", "-h"], ["--literal-pathspecs", "--version"]],
                       "Only capability probes may run for unsupported filenames")
    }

    func testLiteralCommandBuilderRejectsInvalidIdentityBeforeAnyProbe() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        for rawPath in [Data([0xFF]), Data(), Data("embedded\0nul".utf8)] {
            var error: NSError?
            XCTAssertNil(service.literalArguments(forRawPath: rawPath, commandArguments: ["log"], error: &error))
            XCTAssertEqual(error?.code, 5)
        }
        XCTAssertTrue(runner.calls.isEmpty, "Escaped display labels cannot become an executable filename")
    }

    func testExternalDiffUsesOnlyStrictIdentityAndEstablishedLiteralArguments() {
        let runner = CommandRunnerFake()
        let service = PBIndexMutationService(repository: PBGitRepository(), runner: runner)
        var error: NSError?
        XCTAssertNil(service.diffToolArguments(forRawPath: Data([0xFF]), staged: false, error: &error))
        XCTAssertEqual(error?.code, 5)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(service.diffToolArguments(forRawPath: Data("ordinary.txt".utf8), staged: true, error: nil),
                       ["difftool", "-y", "--no-prompt", "--cached", "--", "ordinary.txt"])
        XCTAssertNil(service.diffToolArguments(forRawPath: Data("wild*.txt".utf8), staged: false, error: nil))
        let modern = CommandRunnerFake()
        modern.literalVersion = "git version 2.50.0"
        let modernService = PBIndexMutationService(repository: PBGitRepository(), runner: modern)
        XCTAssertEqual(modernService.diffToolArguments(forRawPath: Data("wild*.txt".utf8), staged: false, error: nil),
                       ["--literal-pathspecs", "difftool", "-y", "--no-prompt", "--", "wild*.txt"])
    }

    func testCapabilityCacheIdentityTracksSymlinkTargetReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXCapabilityIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("git-target")
        let link = directory.appendingPathComponent("configured-git")
        try Data("old executable".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let old = PBIndexGitExecutableIdentity.identity(forPath: link.path)
        XCTAssertEqual(old, PBIndexGitExecutableIdentity.identity(forPath: target.path))
        try FileManager.default.removeItem(at: target)
        try Data("replacement executable with new capabilities".utf8).write(to: target)
        XCTAssertNotEqual(old, PBIndexGitExecutableIdentity.identity(forPath: link.path))
        try FileManager.default.removeItem(at: target)
        XCTAssertNotEqual(old, PBIndexGitExecutableIdentity.identity(forPath: link.path))
    }

    func testCapabilityCacheIdentityIncludesFractionalTargetModificationTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXCapabilityTime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("git-target")
        try Data("executable".utf8).write(to: target)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000.125)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_000.875)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: target.path)
        let first = PBIndexGitExecutableIdentity.identity(forPath: target.path)
        try FileManager.default.setAttributes([.modificationDate: secondDate], ofItemAtPath: target.path)
        let actualDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date)
        XCTAssertEqual(actualDate.timeIntervalSince1970, secondDate.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNotEqual(first, PBIndexGitExecutableIdentity.identity(forPath: target.path),
                          "In-place executable updates within one second invalidate cached capabilities")
    }
}
