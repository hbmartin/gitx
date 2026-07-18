import XCTest

// swift6-safety-justification: all mutable state is guarded by the private lock.
private final class RepositoryIgnoreErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [Error] = []

    func record(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}

// swift6-safety-justification: this box intentionally stress-tests the production object's synchronized access.
private final class RepositorySettingsConcurrencyBox: @unchecked Sendable {
    let settings: PBRepositoryUISettings

    init(_ settings: PBRepositoryUISettings) {
        self.settings = settings
    }
}

@MainActor
final class RepositoryServiceTests: XCTestCase {
    private final class CommandRunnerFake: NSObject, PBGitCommandRunning {
        var outputResults: [Result<String, Error>] = []
        var launchResults: [Result<Void, Error>] = []
        var lastOutput: String?
        private(set) var outputArguments: [[String]] = []
        private(set) var launchArguments: [[String]] = []

        func output(withArguments arguments: [String]) throws -> String {
            outputArguments.append(arguments)
            return try outputResults.isEmpty ? "" : outputResults.removeFirst().get()
        }

        func launch(withArguments arguments: [String]) throws {
            launchArguments.append(arguments)
            try (launchResults.isEmpty ? .success(()) : launchResults.removeFirst()).get()
        }
    }

    private final class UnknownRefish: NSObject, PBGitRefish {
        func refishName() -> String {
            "refs/unknown"
        }

        func shortName() -> String {
            "unknown"
        }

        func refishType() -> String? {
            nil
        }
    }

    private let commandError = NSError(
        domain: "RepositoryServiceTests",
        code: 42,
        userInfo: [NSLocalizedDescriptionKey: "expected command failure"]
    )

    func testReferenceStoreParsesFirstReferenceAndHandlesBoundaries() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [
            .success("abc refs/heads/main\ndef refs/remotes/origin/main"),
            .success("abc"),
            .failure(commandError),
        ]
        let store = PBRepositoryReferenceStore(repository: repository, runner: runner)

        XCTAssertEqual(store.ref(forName: "main")?.ref, "refs/heads/main")
        XCTAssertNil(store.ref(forName: "incomplete"))
        XCTAssertNil(store.ref(forName: "failure"))
        XCTAssertNil(store.ref(forName: nil))
        XCTAssertEqual(runner.outputArguments, [
            ["show-ref", "main"],
            ["show-ref", "incomplete"],
            ["show-ref", "failure"],
        ])
    }

    func testRemoteServiceBuildsCommandsAndWrapsFailures() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success("origin"), .success("")]
        runner.launchResults = [.success(()), .success(()), .success(()), .failure(commandError)]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)

        XCTAssertEqual(service.remotes(), ["origin"])
        XCTAssertEqual(service.remotes(), [])
        XCTAssertTrue(service.addRemote("origin", withURL: "/tmp/remote", error: nil))
        XCTAssertTrue(service.fetchRemote(for: nil, error: nil))
        var error: NSError?
        let remote = PBGitRef(string: "refs/remotes/origin")
        XCTAssertTrue(service.pullBranch(nil, fromRemote: remote, rebase: true, error: &error))
        XCTAssertFalse(service.pushBranch(nil, toRemote: remote, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Push failed")
        XCTAssertNil(service.lastPushOutput)
        XCTAssertEqual(runner.launchArguments, [
            ["remote", "add", "-f", "origin", "/tmp/remote"],
            ["fetch", "--all"],
            ["pull", "--rebase", "origin"],
            ["push", "origin"],
        ])

        runner.launchResults = [.success(())]
        runner.lastOutput = "remote: Open https://example.test/pull/42"
        error = nil
        XCTAssertTrue(service.pushBranch(nil, toRemote: remote, error: &error))
        XCTAssertEqual(service.lastPushOutput, "remote: Open https://example.test/pull/42")
    }

    func testRemoteServiceReportsDiscoveryPullAndDeleteFailures() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.failure(commandError), .failure(commandError)]
        runner.launchResults = [.failure(commandError), .failure(commandError)]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        let branch = PBGitRef(string: "refs/heads/main")
        let remote = PBGitRef(string: "refs/remotes/origin")

        XCTAssertNil(service.remotes())
        var error: NSError?
        XCTAssertFalse(service.pullBranch(branch, fromRemote: remote, rebase: true, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Pull failed")
        error = nil
        XCTAssertFalse(service.pullBranch(nil, fromRemote: remote, rebase: false, error: &error))
        XCTAssertTrue(error?.localizedFailureReason?.contains("(null)") == true)
        error = nil
        XCTAssertFalse(service.deleteRemote(remote, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Delete remote failed!")
        XCTAssertEqual(runner.launchArguments, [
            ["pull", "--rebase", "origin"],
            ["pull", "origin"],
        ])
        XCTAssertEqual(runner.outputArguments, [["remote"], ["remote", "rm", "origin"]])
    }

    func testMutationServicePreservesReferenceAndPathCommandShapes() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success(""), .success(""), .failure(commandError)]
        let service = PBRepositoryMutationService(repository: repository, runner: runner)
        let main = PBGitRef(string: "refs/heads/main")

        XCTAssertTrue(service.checkoutRefish(main, error: nil))
        XCTAssertFalse(service.checkoutFiles([], from: main, error: nil))
        XCTAssertTrue(service.checkoutFiles(["folder/file.txt"], from: main, error: nil))
        var error: NSError?
        XCTAssertFalse(service.checkoutRefish(UnknownRefish(), error: &error))
        XCTAssertTrue(error?.localizedFailureReason?.contains("(null)") == true)
        XCTAssertEqual(runner.outputArguments, [
            ["checkout", "main"],
            ["checkout", "main", "--", "folder/file.txt"],
            ["checkout", "refs/unknown"],
        ])
    }

    func testStashServicePreservesKeepIndexAndFailureErrors() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success(""), .failure(commandError)]
        let service = PBRepositoryStashService(repository: repository, runner: runner)

        XCTAssertTrue(service.save(withKeepIndex: true, error: nil))
        var error: NSError?
        XCTAssertFalse(service.save(withKeepIndex: false, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Stash save failed!")
        XCTAssertEqual(runner.outputArguments, [
            ["stash", "save", "--keep-index"],
            ["stash", "save", "--no-keep-index"],
        ])
    }
}

@MainActor
// swift6-safety-justification: XCTest owns the test case lifetime, while every mutable access is confined to the main actor.
final class RepositoryIgnoreCharacterizationTests: XCTestCase, @unchecked Sendable {
    private var repositoryURL: URL!
    private var repository: PBGitRepository!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where this repository fixture is confined.
        try MainActor.assumeIsolated {
            repositoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXRepositoryIgnore-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try runGit(["init", "--quiet", "--initial-branch=main"])
            try runGit(["config", "user.name", "GitX Tests"])
            try runGit(["config", "user.email", "gitx-tests@example.invalid"])
            try "tracked\n".write(
                to: repositoryURL.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "--all"])
            try runGit(["commit", "--quiet", "-m", "initial"])
            repository = try PBGitRepository(url: repositoryURL)
        }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where this repository fixture is confined.
        MainActor.assumeIsolated {
            repository?.revisionList?.cleanup()
            repository = nil
            if let repositoryURL {
                try? FileManager.default.removeItem(at: repositoryURL)
            }
            repositoryURL = nil
        }
        super.tearDown()
    }

    func testCreatingIgnoreFilePreservesUnicodeOrderingAndCurrentNewlineBehavior() throws {
        let paths = ["build/", "résumé/雪.tmp", "*.temporary"]

        try repository.ignoreFilePaths(paths)

        let data = try Data(contentsOf: repositoryURL.appendingPathComponent(".gitignore"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "build/\nrésumé/雪.tmp\n*.temporary")
        XCTAssertNotEqual(data.last, Character("\n").asciiValue)
    }

    func testIgnoreWriteReportsErrorWhenIgnorePathIsDirectory() throws {
        let ignoreURL = repositoryURL.appendingPathComponent(".gitignore", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoreURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try repository.ignoreFilePaths(["ignored.txt"])) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoreURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testIgnoreWriteReportsFileCoordinationCancellation() {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.cancel()
        let service = PBRepositoryIgnoreFileService(
            fileURL: ignoreURL,
            fileCoordinator: coordinator
        )

        XCTAssertThrowsError(try service.appendPaths(["ignored.txt"])) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.userCancelled.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoreURL.path))
    }

    func testAppendingUsesExactlyOneSeparatorAndPreservesExistingNewlines() throws {
        let cases = [
            ("existing", "existing\nnew"),
            ("existing\n", "existing\nnew"),
            ("existing\n\n", "existing\n\nnew"),
            ("", "new"),
        ]

        for (existing, expected) in cases {
            try existing.write(to: ignoreURL, atomically: true, encoding: .utf8)

            assertSuccessfulIgnore(["new"])

            XCTAssertEqual(try String(contentsOf: ignoreURL, encoding: .utf8), expected)
        }
    }

    func testAppendingUsesExistingCRLFConventionForSeparatorsAndNewPaths() throws {
        try Data("existing\r\nline".utf8).write(to: ignoreURL, options: .atomic)

        assertSuccessfulIgnore(["résumé/雪.tmp", "*.temporary"])

        XCTAssertEqual(
            try Data(contentsOf: ignoreURL),
            Data("existing\r\nline\r\nrésumé/雪.tmp\r\n*.temporary".utf8)
        )
    }

    func testAppendingPreservesClassicMacNewlinesAndEmptyRequests() throws {
        try Data("existing\rline".utf8).write(to: ignoreURL, options: .atomic)

        assertSuccessfulIgnore(["new"])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), Data("existing\rline\rnew".utf8))

        let existingData = try Data(contentsOf: ignoreURL)
        assertSuccessfulIgnore([])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), existingData)

        try FileManager.default.removeItem(at: ignoreURL)
        assertSuccessfulIgnore([])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), Data())
    }

    func testAppendingPreservesDetectedEncodingAndUnicode() throws {
        try "existing ü".write(to: ignoreURL, atomically: true, encoding: .utf16)
        var originalEncoding = String.Encoding.utf8
        _ = try String(contentsOf: ignoreURL, usedEncoding: &originalEncoding)

        assertSuccessfulIgnore(["résumé/雪.tmp"])

        var updatedEncoding = String.Encoding.utf8
        let updated = try String(contentsOf: ignoreURL, usedEncoding: &updatedEncoding)
        XCTAssertEqual(updatedEncoding, originalEncoding)
        XCTAssertEqual(updated, "existing ü\nrésumé/雪.tmp")
    }

    func testAppendingRereadsExternallyReplacedIgnoreFile() throws {
        try "initial".write(to: ignoreURL, atomically: true, encoding: .utf8)
        assertSuccessfulIgnore(["first"])
        XCTAssertEqual(try String(contentsOf: ignoreURL, encoding: .utf8), "initial\nfirst")

        try Data("external\r\nreplacement".utf8).write(to: ignoreURL, options: .atomic)
        assertSuccessfulIgnore(["second"])

        XCTAssertEqual(
            try Data(contentsOf: ignoreURL),
            Data("external\r\nreplacement\r\nsecond".utf8)
        )
    }

    func testConcurrentAppendsPreserveEveryPath() throws {
        let ignoreURL = repositoryURL.appendingPathComponent(".gitignore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoreURL.path))
        let collector = RepositoryIgnoreErrorCollector()
        let expected = Set((0 ..< 64).map { "concurrent-\($0)" })

        DispatchQueue.concurrentPerform(iterations: expected.count) { index in
            let service = PBRepositoryIgnoreFileService(fileURL: ignoreURL)
            do {
                try service.appendPaths(["concurrent-\(index)"])
            } catch {
                collector.record(error)
            }
        }

        XCTAssertTrue(collector.errors.isEmpty, "\(collector.errors)")
        let lines = try String(contentsOf: ignoreURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, expected.count)
        XCTAssertEqual(Set(lines), expected)
    }

    func testConcurrentRepositorySettingsUpdatesPreserveIndependentFields() {
        let defaultsKey = "PBRepositoryUISettings"
        let defaults = UserDefaults.standard
        let originalSettings = defaults.object(forKey: defaultsKey)
        defer {
            if let originalSettings {
                defaults.set(originalSettings, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let settings = PBRepositoryUISettings(repository: repository)
        settings.pushAfterCommit = false
        settings.hideContainedBranches = false
        let settingsBox = RepositorySettingsConcurrencyBox(settings)

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            if iteration.isMultiple(of: 2) {
                settingsBox.settings.pushAfterCommit = true
            } else {
                settingsBox.settings.hideContainedBranches = true
            }
        }

        let reloaded = PBRepositoryUISettings(repository: repository)
        XCTAssertTrue(reloaded.pushAfterCommit)
        XCTAssertTrue(reloaded.hideContainedBranches)
    }

    func testAtomicWriteFailurePreservesExistingIgnoreContents() throws {
        let original = Data("existing\n".utf8)
        try original.write(to: ignoreURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: repositoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: repositoryURL.path
            )
        }

        let invocation = PBRepositoryIgnoreInvocation.invokeRepository(
            repository,
            paths: ["new"]
        )

        XCTAssertNil(invocation.exception)
        XCTAssertFalse(invocation.success)
        XCTAssertNotNil(invocation.error)
        XCTAssertEqual(try Data(contentsOf: ignoreURL), original)
    }

    func testExternalIgnoreEditRemovesUntrackedRowButRetainsTrackedChange() throws {
        let ignoredPath = "ignored ü.txt"
        try "ignored\n".write(
            to: repositoryURL.appendingPathComponent(ignoredPath),
            atomically: true,
            encoding: .utf8
        )
        try "changed\n".write(
            to: repositoryURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        refreshIndex()
        XCTAssertEqual(Set(repository.index.indexChanges.map(\.path)), [ignoredPath, "tracked.txt"])

        try "\(ignoredPath)\n".write(
            to: repositoryURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        refreshIndex()

        let refreshedChanges = Dictionary(
            uniqueKeysWithValues: repository.index.indexChanges.map { ($0.path, $0) }
        )
        XCTAssertEqual(Set(refreshedChanges.keys), [".gitignore", "tracked.txt"])
        XCTAssertNil(refreshedChanges[ignoredPath])
        XCTAssertTrue(refreshedChanges["tracked.txt"]?.hasUnstagedChanges == true)
    }

    private var ignoreURL: URL {
        repositoryURL.appendingPathComponent(".gitignore")
    }

    private func assertSuccessfulIgnore(
        _ paths: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let invocation = PBRepositoryIgnoreInvocation.invokeRepository(repository, paths: paths)
        XCTAssertNil(invocation.exception, file: file, line: line)
        XCTAssertNil(invocation.error, file: file, line: line)
        XCTAssertTrue(invocation.success, file: file, line: line)
    }

    private func refreshIndex() {
        let refreshed = expectation(description: "index refresh finished")
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(PBGitIndexFinishedIndexRefresh),
            object: repository.index,
            queue: .main
        ) { _ in
            refreshed.fulfill()
        }
        repository.index.refresh()
        wait(for: [refreshed], timeout: 10)
        NotificationCenter.default.removeObserver(token)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "RepositoryIgnoreCharacterizationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
