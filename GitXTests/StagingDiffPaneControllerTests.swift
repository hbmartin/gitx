import XCTest

@MainActor
final class StagingDiffPaneControllerTests: XCTestCase {
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
        private let gate = DispatchSemaphore(value: 0)

        init(producerStarted: XCTestExpectation, producerFinished: XCTestExpectation) {
            self.producerStarted = producerStarted
            self.producerFinished = producerFinished
            super.init()
        }

        func output(
            withArguments _: [String],
            input _: String?,
            environment _: [String: Any]?
        ) throws -> String {
            producerStarted.fulfill()
            gate.wait()
            producerFinished.fulfill()
            return "diff --git a/queued.txt b/queued.txt\n"
        }

        func data(
            withArguments _: [String],
            completion: @escaping (Data?, Error?) -> Void
        ) {
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

    func testQueuedProductionRetainsRepositoryAfterPaneTeardownAndCompletes() async throws {
        let producerStarted = expectation(description: "queued producer started")
        let producerFinished = expectation(description: "queued producer finished")
        let repositoryReleased = expectation(description: "repository released after queued production")
        let runner = BlockingIndexCommandRunner(
            producerStarted: producerStarted,
            producerFinished: producerFinished
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
        await fulfillment(of: [producerFinished, repositoryReleased], timeout: 2)
        XCTAssertNil(weakRepository)
    }
}
