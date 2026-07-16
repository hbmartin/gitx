import XCTest

final class IndexRefreshCoordinatorTests: XCTestCase {
    private final class CommandRunnerFake: NSObject, PBIndexCommandRunning {
        struct Call {
            let arguments: [String]
            let completion: (Data?, Error?) -> Void
        }

        private let lock = NSLock()
        private var storedCalls: [Call] = []
        var onRequest: ((Int) -> Void)?

        func output(
            withArguments _: [String],
            input _: String?,
            environment _: [String: Any]?
        ) throws -> String {
            ""
        }

        func data(
            withArguments arguments: [String],
            completion: @escaping (Data?, Error?) -> Void
        ) {
            lock.lock()
            storedCalls.append(Call(arguments: arguments, completion: completion))
            let count = storedCalls.count
            let handler = onRequest
            lock.unlock()
            handler?(count)
        }

        var arguments: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return storedCalls.map(\.arguments)
        }

        func complete(_ index: Int, data: Data? = Data(), error: Error? = nil) {
            lock.lock()
            let completion = storedCalls[index].completion
            lock.unlock()
            completion(data, error)
        }
    }

    func testSuccessfulRefreshParsesAllComponentsAndDeliversOnMainThread() {
        let runner = CommandRunnerFake()
        let commandsStarted = expectation(description: "three commands started")
        commandsStarted.expectedFulfillmentCount = 3
        runner.onRequest = { _ in commandsStarted.fulfill() }
        let statusesDelivered = expectation(description: "statuses delivered")
        statusesDelivered.expectedFulfillmentCount = 3
        let resultDelivered = expectation(description: "result delivered")
        let idleDelivered = expectation(description: "idle delivered")
        var statuses: [(Bool, String)] = []
        var refreshResult: PBIndexRefreshResult?
        let coordinator = PBIndexRefreshCoordinator(
            runner: runner,
            parser: PBIndexStatusParser(),
            statusHandler: { success, message in
                XCTAssertTrue(Thread.isMainThread)
                statuses.append((success, message))
                statusesDelivered.fulfill()
            },
            resultHandler: { result in
                XCTAssertTrue(Thread.isMainThread)
                refreshResult = result
                resultDelivered.fulfill()
            },
            idleHandler: {
                XCTAssertTrue(Thread.isMainThread)
                idleDelivered.fulfill()
            }
        )

        coordinator.refreshBareRepository(false, parentTree: "HEAD^")
        wait(for: [commandsStarted], timeout: 2)

        XCTAssertEqual(
            runner.arguments,
            [
                ["ls-files", "--others", "--exclude-standard", "-z"],
                ["diff-index", "--cached", "-z", "HEAD^"],
                ["diff-files", "-z"],
            ]
        )
        let oldSHA = String(repeating: "1", count: 40)
        let newSHA = String(repeating: "2", count: 40)
        runner.complete(0, data: Data("folder/spaced ü.txt\0".utf8))
        runner.complete(
            1,
            data: Data(":100644 100644 \(oldSHA) \(newSHA) M\0tracked.txt\0".utf8)
        )
        runner.complete(2)

        wait(for: [statusesDelivered, resultDelivered, idleDelivered], timeout: 2)
        XCTAssertEqual(statuses.map(\.0), [true, true, true])
        XCTAssertEqual(statuses.map(\.1), ["ls-files success", "diff-index success", "diff-files success"])
        XCTAssertEqual(refreshResult?.untracked?["folder/spaced ü.txt"]?.status, 0)
        XCTAssertEqual(refreshResult?.staged?["tracked.txt"]?.commitBlobSHA, oldSHA)
        XCTAssertEqual(refreshResult?.unstaged?.count, 0)
    }

    func testCommandAndParseFailuresProduceNilComponentsAndFailureStatuses() {
        let runner = CommandRunnerFake()
        let commandsStarted = expectation(description: "commands started")
        commandsStarted.expectedFulfillmentCount = 3
        runner.onRequest = { _ in commandsStarted.fulfill() }
        let statusesDelivered = expectation(description: "statuses delivered")
        statusesDelivered.expectedFulfillmentCount = 3
        let resultDelivered = expectation(description: "result delivered")
        var statuses: [(Bool, String)] = []
        var refreshResult: PBIndexRefreshResult?
        let coordinator = PBIndexRefreshCoordinator(
            runner: runner,
            parser: PBIndexStatusParser(),
            statusHandler: { success, message in
                statuses.append((success, message))
                statusesDelivered.fulfill()
            },
            resultHandler: { result in
                refreshResult = result
                resultDelivered.fulfill()
            },
            idleHandler: {}
        )

        coordinator.refreshBareRepository(false, parentTree: "HEAD")
        wait(for: [commandsStarted], timeout: 2)
        runner.complete(0, error: NSError(domain: "test", code: 1))
        runner.complete(1, data: Data([0xFF]))
        runner.complete(2)

        wait(for: [statusesDelivered, resultDelivered], timeout: 2)
        XCTAssertEqual(statuses.map(\.0), [false, false, true])
        XCTAssertEqual(statuses.map(\.1), ["ls-files failed", "diff-index failed", "diff-files success"])
        XCTAssertNil(refreshResult?.untracked)
        XCTAssertNil(refreshResult?.staged)
        XCTAssertEqual(refreshResult?.unstaged?.count, 0)
    }

    func testOverlappingRequestsCoalesceIntoOneTrailingReplayUsingLatestParentTree() {
        let runner = CommandRunnerFake()
        let firstCommands = expectation(description: "first commands")
        firstCommands.expectedFulfillmentCount = 3
        let replayCommands = expectation(description: "replay commands")
        replayCommands.expectedFulfillmentCount = 3
        runner.onRequest = { count in
            if count <= 3 {
                firstCommands.fulfill()
            } else {
                replayCommands.fulfill()
            }
        }
        let resultsDelivered = expectation(description: "two results")
        resultsDelivered.expectedFulfillmentCount = 2
        let idleDelivered = expectation(description: "one idle transition")
        let coordinator = PBIndexRefreshCoordinator(
            runner: runner,
            parser: PBIndexStatusParser(),
            statusHandler: { _, _ in },
            resultHandler: { _ in resultsDelivered.fulfill() },
            idleHandler: { idleDelivered.fulfill() }
        )

        coordinator.refreshBareRepository(false, parentTree: "HEAD")
        wait(for: [firstCommands], timeout: 2)
        coordinator.refreshBareRepository(false, parentTree: "first-pending")
        coordinator.refreshBareRepository(false, parentTree: "latest-pending")
        runner.complete(0)
        runner.complete(1)
        runner.complete(2)

        wait(for: [replayCommands], timeout: 2)
        XCTAssertEqual(runner.arguments[4], ["diff-index", "--cached", "-z", "latest-pending"])
        runner.complete(3)
        runner.complete(4)
        runner.complete(5)

        wait(for: [resultsDelivered, idleDelivered], timeout: 2)
        XCTAssertEqual(runner.arguments.count, 6)
    }

    func testBareRefreshCompletesWithoutLaunchingCommands() {
        let runner = CommandRunnerFake()
        let resultDelivered = expectation(description: "bare result")
        let idleDelivered = expectation(description: "bare idle")
        var refreshResult: PBIndexRefreshResult?
        let coordinator = PBIndexRefreshCoordinator(
            runner: runner,
            parser: PBIndexStatusParser(),
            statusHandler: { _, _ in XCTFail("Bare refresh must not emit command status") },
            resultHandler: { result in
                refreshResult = result
                resultDelivered.fulfill()
            },
            idleHandler: { idleDelivered.fulfill() }
        )

        coordinator.refreshBareRepository(true, parentTree: "empty")

        wait(for: [resultDelivered, idleDelivered], timeout: 2)
        XCTAssertTrue(runner.arguments.isEmpty)
        XCTAssertNil(refreshResult?.staged)
        XCTAssertNil(refreshResult?.unstaged)
        XCTAssertNil(refreshResult?.untracked)
    }

    func testStatCacheRefreshSkipsBareRepositoryAndCompletesOnMainThread() {
        let runner = CommandRunnerFake()
        let commandStarted = expectation(description: "stat cache command")
        runner.onRequest = { _ in commandStarted.fulfill() }
        let completed = expectation(description: "stat cache completion")
        let coordinator = PBIndexRefreshCoordinator(
            runner: runner,
            parser: PBIndexStatusParser(),
            statusHandler: { _, _ in },
            resultHandler: { _ in },
            idleHandler: {}
        )

        coordinator.refreshStatCache(forBareRepository: true) {
            XCTFail("Bare repositories must not refresh their stat cache")
        }
        XCTAssertTrue(runner.arguments.isEmpty)

        coordinator.refreshStatCache(forBareRepository: false) {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        wait(for: [commandStarted], timeout: 2)
        XCTAssertEqual(
            runner.arguments[0],
            ["update-index", "-q", "--unmerged", "--ignore-missing", "--refresh"]
        )
        runner.complete(0, error: NSError(domain: "test", code: 2))

        wait(for: [completed], timeout: 2)
    }
}
