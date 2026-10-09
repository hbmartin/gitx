import Darwin
import XCTest

@MainActor
final class StagingDiffPaneControllerTests: XCTestCase {
    // swift6-safety-justification: Immutable status fixtures and lock-protected command counts are shared only with the serial producer/writer queues.
    private final nonisolated class StatusRunner: NSObject, PBIndexRawOutputCommandRunning, @unchecked Sendable {
        let paths: [String]
        let status: String
        let indexOutput: Data?
        init(paths: [String], status: String = "M", indexOutput: Data? = nil) {
            self.paths = paths; self.status = status; self.indexOutput = indexOutput; super.init()
        }

        private let lock = NSLock()
        private var statusCommands = 0
        private var diffCommands = 0
        private var treeCommands = 0
        private var indexObject = String(repeating: "a", count: 40)
        private var treeObject = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        private var staged = false

        func changeIndex() {
            lock.lock(); indexObject = String(repeating: "b", count: 40); lock.unlock()
        }

        func changeTree() {
            lock.lock(); treeObject = String(repeating: "b", count: 40); lock.unlock()
        }

        func changeStaging() {
            lock.lock(); staged = true; lock.unlock()
        }

        var counts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return [statusCommands, diffCommands, treeCommands]
        }

        func rawOutput(withArguments arguments: [String], environment: [String: Any]?) throws -> Data {
            XCTAssertEqual(environment?["GIT_OPTIONAL_LOCKS"] as? String, "0")
            lock.lock(); statusCommands += 1; let object = indexObject; let hasStaged = staged; lock.unlock()
            if arguments.contains("diff-files") {
                return Data(paths.map { ":100644 100644 \(object) \(String(repeating: "0", count: 40)) \(status)\0\($0)\0" }.joined().utf8)
            }
            if arguments.contains("ls-files") {
                return indexOutput ?? Data(paths.map { "100644 \(object) 0\t\($0)\0" }.joined().utf8)
            }
            if arguments.contains("diff-index"), hasStaged {
                return Data(paths.map { ":100644 100644 \(String(repeating: "a", count: 40)) \(object) M\0\($0)\0" }.joined().utf8)
            }
            return Data()
        }

        func output(withArguments arguments: [String], input _: String?, environment _: [String: Any]?) throws -> String {
            lock.lock(); defer { lock.unlock() }
            XCTAssertFalse(arguments.contains("-z"), "Status must use the runner's byte output")
            if arguments.first == "rev-parse" {
                treeCommands += 1
                return treeObject + "\n"
            }
            diffCommands += 1
            return "diff --git a/selected.txt b/selected.txt\n"
        }

        func data(withArguments _: [String], completion: @escaping (Data?, Error?) -> Void) {
            XCTFail("Revalidation must use the synchronous command boundary")
            completion(nil, nil)
        }
    }

    #if DEBUG
        private func snapshotFixture(_ body: (URL, LifetimeRepository, PBChangedFile) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("contents\n".utf8).write(to: directory.appendingPathComponent("selected.txt"))
            let file = PBChangedFile(path: "selected.txt")
            file.status = .MODIFIED; file.hasUnstagedChanges = true
            try await body(directory, LifetimeRepository(directory: directory, onDeinit: {}), file)
        }

        func testDiscardSnapshotRejectsSameSizedContentPermissionsIndexTreeAndStagingChanges() async throws {
            for change in 0 ..< 5 {
                try await snapshotFixture { directory, repository, file in
                    let runner = StatusRunner(paths: [file.path])
                    let url = directory.appendingPathComponent(file.path)
                    let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    do {
                        try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                            do {
                                switch change {
                                case 0:
                                    try Data("mutated!\n".utf8).write(to: url)
                                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                                case 1: try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                                case 2: runner.changeIndex()
                                case 3: runner.changeTree()
                                default: runner.changeStaging()
                                }
                            } catch { XCTFail("Fixture change failed: \(error)") }
                        })
                        XCTFail("A changed discard snapshot was authorized: \(change)")
                    } catch { XCTAssertEqual((error as NSError).code, 8) }
                }
            }
        }

        func testDiscardSnapshotAcceptsBinaryContentsAndRejectsAChangedSymlinkTarget() async throws {
            try await snapshotFixture { directory, repository, file in
                let runner = StatusRunner(paths: [file.path])
                let url = directory.appendingPathComponent(file.path)
                try Data([0, 255, 1, 0]).write(to: url)
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: String(repeating: "x", count: 600))
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                        do {
                            try FileManager.default.removeItem(at: url)
                            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "new target")
                        } catch { XCTFail("Fixture change failed: \(error)") }
                    })
                    XCTFail("A replaced symlink was authorized")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotAcceptsDeletionButRejectsAReappearingFile() async throws {
            try await snapshotFixture { directory, repository, file in
                let runner = StatusRunner(paths: [file.path], status: "D")
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.removeItem(at: url)
                file.status = .DELETED
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                        do { try Data("new contents\n".utf8).write(to: url) }
                        catch { XCTFail("Fixture change failed: \(error)") }
                    })
                    XCTFail("A reappearing file was authorized")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotRejectsMalformedMissingIndexEntriesAndUnsupportedFileKinds() async throws {
            for record in [Data("malformed\0".utf8), Data("invalid metadata\tselected.txt\0".utf8), Data()] {
                try await snapshotFixture { _, repository, file in
                    do {
                        try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path], indexOutput: record), files: [file])
                        XCTFail("Malformed or missing index entry was authorized")
                    } catch { XCTAssertEqual((error as NSError).code, 8) }
                }
            }
            try await snapshotFixture { directory, repository, file in
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.removeItem(at: url)
                XCTAssertEqual(mkfifo(url.path, 0o600), 0)
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file])
                    XCTFail("A FIFO cannot authorize a tracked-file discard")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotSkipsUntrackedAndStagedOnlyRowsAndRequiresAWorkingDirectory() async throws {
            let repository = LifetimeRepository(onDeinit: {})
            let runner = StatusRunner(paths: ["selected.txt"])
            let file = PBChangedFile(path: "selected.txt")
            file.status = .MODIFIED; file.hasStagedChanges = true
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
            file.status = .NEW; file.hasUnstagedChanges = true
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
            XCTAssertEqual(runner.counts, [0, 0, 0])
            file.status = .MODIFIED; file.hasStagedChanges = false
            do {
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                XCTFail("A missing worktree was authorized")
            } catch { XCTAssertEqual((error as NSError).code, 8) }
        }

        func testDiscardSnapshotReportsAnInvalidWorkingDirectory() async throws {
            try await snapshotFixture { directory, _, file in
                let repository = LifetimeRepository(directory: directory.appendingPathComponent(file.path), onDeinit: {})
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file])
                    XCTFail("A regular file cannot be the discard working directory")
                } catch {
                    XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                    XCTAssertEqual((error as NSError).code, Int(ENOTDIR))
                }
            }
        }

        func testDiscardRevalidationUsesInjectedByteRunnerAndBatchesStatusFor300Files() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let paths = (0 ..< 300).map { "selected-\($0).txt" }
            for path in paths {
                try Data("contents\n".utf8).write(to: directory.appendingPathComponent(path))
            }
            let repository = LifetimeRepository(directory: directory, onDeinit: {})
            let runner = StatusRunner(paths: paths)
            let files = (0 ..< 300).map { index in
                let file = PBChangedFile(path: "selected-\(index).txt")
                file.status = .MODIFIED
                file.hasUnstagedChanges = true
                return file
            }
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: files)
            XCTAssertEqual(runner.counts, [6, 0, 2], "Whole-file authorization uses shared byte queries and never decodes a text diff")
        }
    #endif

    // swift6-safety-justification: The repository crosses only into the serial producer queue,
    // and its immutable deinit callback is safe to invoke from whichever queue releases it.
    private final nonisolated class LifetimeRepository: PBGitRepository, @unchecked Sendable {
        private let onDeinit: @Sendable () -> Void
        private let directory: URL?

        init(directory: URL? = nil, onDeinit: @escaping @Sendable () -> Void) {
            self.directory = directory
            self.onDeinit = onDeinit
            super.init()
        }

        override func workingDirectoryURL() -> URL? {
            directory
        }

        override func revisionExists(_ spec: String) -> Bool {
            true
        }

        deinit {
            onDeinit()
        }
    }

    // swift6-safety-justification: XCTest expectations are only fulfilled, and the semaphore
    // synchronizes the sole cross-queue state transition controlled by this test.
    private final nonisolated class BlockingIndexCommandRunner: NSObject, PBIndexCommandRunning, @unchecked Sendable {
        private let producerStarted: XCTestExpectation
        private let producerFinished: XCTestExpectation
        private let parentResolved: XCTestExpectation
        private let gate = DispatchSemaphore(value: 0)

        init(producerStarted: XCTestExpectation, producerFinished: XCTestExpectation, parentResolved: XCTestExpectation) {
            self.producerStarted = producerStarted
            self.producerFinished = producerFinished
            self.parentResolved = parentResolved
            super.init()
        }

        func output(
            withArguments arguments: [String],
            input _: String?,
            environment _: [String: Any]?
        ) throws -> String {
            if arguments.first == "rev-parse" {
                XCTAssertEqual(arguments, ["rev-parse", "--verify", "HEAD^{tree}"])
                parentResolved.fulfill()
                return "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
            }
            producerStarted.fulfill()
            gate.wait()
            producerFinished.fulfill()
            return "diff --git a/queued.txt b/queued.txt\n"
        }

        func data(
            withArguments _: [String],
            completion: @escaping (Data?, Error?) -> Void
        ) {
            XCTFail("queued staging-diff production must not use the asynchronous data path")
            completion(nil, nil)
        }

        func releaseProduction() {
            gate.signal()
        }
    }

    func testDiffPaneOwnsTheRepositoryWithoutACycle() {
        weak var weakRepository: PBGitRepository?
        var pane: PBStagingDiffPaneController?
        autoreleasepool {
            var repository: PBGitRepository? = PBGitRepository()
            weakRepository = repository
            pane = PBStagingDiffPaneController(repository: repository!)
            repository = nil
        }
        XCTAssertNotNil(pane)
        XCTAssertNotNil(
            weakRepository,
            "diff production runs on a background queue after the pane may be torn down and reaches "
                + "the repository through unowned services, so the pane must keep the repository alive"
        )

        autoreleasepool {
            pane = nil
        }
        XCTAssertNil(weakRepository, "releasing the pane must release the repository without a retain cycle")
    }

    func testUntrackedDiffWithoutAWorkingDirectoryShowsTheFailure() {
        let repository = PBGitRepository()
        let pane = PBStagingDiffPaneController(repository: repository)
        let file = PBChangedFile(path: "untracked.txt")
        file.status = .NEW
        file.hasUnstagedChanges = true
        pane.renderRequests([PBStagingDiffRequest(file: file, staged: false)])

        let expected = "The repository has no working directory."
        let deadline = Date().addingTimeInterval(2)
        while !pane.contentView.textView.string.contains(expected), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(pane.contentView.textView.string.contains(expected))
        XCTAssertTrue(pane.contentView.textView.string.contains("untracked.txt"))
    }

    func testQueuedProductionRetainsRepositoryAfterPaneTeardownAndCompletes() async throws {
        let producerStarted = expectation(description: "queued producer started")
        let producerFinished = expectation(description: "queued producer finished")
        let parentResolved = expectation(description: "queued producer resolves its parent through the command boundary")
        let repositoryReleased = expectation(description: "repository released after queued production")
        let runner = BlockingIndexCommandRunner(
            producerStarted: producerStarted,
            producerFinished: producerFinished,
            parentResolved: parentResolved
        )
        weak var weakRepository: PBGitRepository?
        var repository: LifetimeRepository? = LifetimeRepository {
            repositoryReleased.fulfill()
        }
        weakRepository = repository
        var pane: PBStagingDiffPaneController?
        do {
            let initialRepository = try XCTUnwrap(repository)
            pane = PBStagingDiffPaneController(
                repository: initialRepository,
                diffRunner: runner
            )
        }
        let file = PBChangedFile(path: "queued.txt")
        file.status = .MODIFIED
        file.hasUnstagedChanges = true

        pane?.renderRequests([PBStagingDiffRequest(file: file, staged: false)])
        await fulfillment(of: [producerStarted], timeout: 2)

        repository = nil
        pane = nil
        XCTAssertNotNil(
            weakRepository,
            "the queued production closure must keep its repository alive after pane teardown"
        )

        runner.releaseProduction()
        await fulfillment(of: [producerFinished, parentResolved, repositoryReleased], timeout: 2)
        XCTAssertNil(weakRepository)
    }
}
