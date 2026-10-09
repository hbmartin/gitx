import XCTest

@MainActor
final class StagingDiffPaneControllerTests: XCTestCase {
    // swift6-safety-justification: Immutable status fixtures and lock-protected command counts are shared only with the serial producer/writer queues.
    private final nonisolated class StatusRunner: NSObject, PBIndexRawOutputCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var statusCommands = 0
        private var diffCommands = 0
        private var treeCommands = 0

        var counts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return [statusCommands, diffCommands, treeCommands]
        }

        func rawOutput(withArguments arguments: [String], environment: [String: Any]?) throws -> Data {
            XCTAssertEqual(environment?["GIT_OPTIONAL_LOCKS"] as? String, "0")
            lock.lock(); statusCommands += 1; lock.unlock()
            if arguments.contains("diff-files") {
                let paths = arguments.dropFirst((arguments.firstIndex(of: "--") ?? arguments.count) + 1)
                return Data(paths.map { ":100644 100644 \(String(repeating: "a", count: 40)) \(String(repeating: "0", count: 40)) M\0\($0)\0" }.joined().utf8)
            }
            return Data()
        }

        func output(withArguments arguments: [String], input _: String?, environment _: [String: Any]?) throws -> String {
            lock.lock(); defer { lock.unlock() }
            XCTAssertFalse(arguments.contains("-z"), "Status must use the runner's byte output")
            if arguments.first == "rev-parse" {
                treeCommands += 1
                return "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
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
        func testDiscardRevalidationUsesInjectedByteRunnerAndBatchesStatusFor300Files() async throws {
            let repository = LifetimeRepository(onDeinit: {})
            let runner = StatusRunner()
            let files = (0 ..< 300).map { index in
                let file = PBChangedFile(path: "selected-\(index).txt")
                file.status = .MODIFIED
                file.hasUnstagedChanges = true
                return file
            }
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: files)
            XCTAssertEqual(runner.counts, [6, 600, 2])
        }
    #endif

    // swift6-safety-justification: The repository crosses only into the serial producer queue,
    // and its immutable deinit callback is safe to invoke from whichever queue releases it.
    private final nonisolated class LifetimeRepository: PBGitRepository, @unchecked Sendable {
        private let onDeinit: @Sendable () -> Void

        init(onDeinit: @escaping @Sendable () -> Void) {
            self.onDeinit = onDeinit
            super.init()
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
