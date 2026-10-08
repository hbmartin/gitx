import Foundation
import XCTest

final class IndexMutationCoordinatorTests: XCTestCase {
    private final class GateTask: PBTask {
        let action: () throws -> Void
        init(action: @escaping () throws -> Void) {
            self.action = action; super.init()
        }

        override func launch() throws {
            try action()
        }

        override var standardOutputData: Data {
            Data()
        }
    }

    private final class GateRepository: PBGitRepository {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        override func task(withArguments arguments: [Any]?) -> PBTask {
            if (arguments as? [String])?.last == "held" {
                return GateTask { [self] in entered.signal(); _ = release.wait(timeout: .now() + 5) }
            }
            return GateTask {}
        }
    }

    private final class Fake: NSObject, PBIndexBinaryCommandRunning {
        struct Call { let arguments: [String]; let input: Data? }
        var calls: [Call] = []
        var failNext = false
        func output(withArguments arguments: [String], input: String?, environment: [String: Any]?) throws -> String {
            if arguments == ["reset", "-h"] {
                return "usage: git reset --pathspec-from-file --pathspec-file-nul"
            }
            if arguments == ["--literal-pathspecs", "--version"] {
                return "git version test"
            }
            return try output(withArguments: arguments, inputData: input.map { Data($0.utf8) }, environment: environment)
        }

        func output(withArguments arguments: [String], inputData: Data?, environment _: [String: Any]?) throws -> String {
            calls.append(Call(arguments: arguments, input: inputData))
            if failNext {
                failNext = false; throw NSError(domain: "mutation.fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "partial fixture failure"])
            }
            return ""
        }

        func data(withArguments _: [String], completion: @escaping (Data?, Error?) -> Void) {
            completion(Data(), nil)
        }
    }

    // swift6-safety-justification: The immutable runner is passed to a worker; all task gate state is protected by semaphores.
    private final class RunnerTransfer: @unchecked Sendable {
        let runner: IndexRepositoryCommandRunner
        init(_ runner: IndexRepositoryCommandRunner) {
            self.runner = runner
        }
    }

    func testOrderedMixedMutationsCopyInputsAndCompleteExactlyOnceOnMain() {
        let repository = GateRepository()
        let runner = Fake()
        let coordinator = PBIndexMutationCoordinator(repository: repository, service: PBIndexMutationService(repository: repository, runner: runner)) { _ in XCTAssertTrue(Thread.isMainThread) }
        let held = expectation(description: "held writer finishes")
        let transfer = RunnerTransfer(IndexRepositoryCommandRunner(repository: repository))
        DispatchQueue.global().async {
            _ = try? transfer.runner.output(withArguments: ["update-index", "held"], input: nil, environment: nil)
            held.fulfill()
        }
        XCTAssertEqual(repository.entered.wait(timeout: .now() + 2), .success)
        let mutable = NSMutableData(data: Data("first.txt".utf8))
        let stage = PBIndexMutationRequest(stagePaths: [mutable as Data], unstagePaths: [], parentTree: "HEAD")
        mutable.setData(Data("changed.txt".utf8))
        let requests = [stage,
                        PBIndexMutationRequest(stagePaths: [], unstagePaths: [Data("first.txt".utf8)], parentTree: "HEAD"),
                        PBIndexMutationRequest(discardPaths: [Data("first.txt".utf8)]),
                        PBIndexMutationRequest(patch: "fixture patch", stage: true, reverse: false)]
        let completed = expectation(description: "four results delivered once")
        completed.expectedFulfillmentCount = 4
        var order: [Int] = []
        for (position, request) in requests.enumerated() {
            XCTAssertTrue(coordinator.schedule(request: request) { success, error in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(success)
                XCTAssertNil(error)
                order.append(position)
                completed.fulfill()
            })
        }
        XCTAssertTrue(order.isEmpty, "Admission must not block main or claim execution has completed")
        repository.release.signal()
        wait(for: [held, completed], timeout: 5)
        XCTAssertEqual(order, [0, 1, 2, 3])
        XCTAssertEqual(runner.calls.map { $0.arguments.first ?? "" }, ["update-index", "--literal-pathspecs", "checkout-index", "apply"])
        XCTAssertEqual(runner.calls.first?.input, Data("first.txt\0".utf8))
        coordinator.close()
    }

    func testClosureCompletesAdmittedPendingWorkWithoutExecutingIt() {
        let repository = GateRepository()
        let runner = Fake()
        let coordinator = PBIndexMutationCoordinator(repository: repository, service: PBIndexMutationService(repository: repository, runner: runner)) { _ in }
        let held = expectation(description: "held writer finishes")
        let transfer = RunnerTransfer(IndexRepositoryCommandRunner(repository: repository))
        DispatchQueue.global().async {
            _ = try? transfer.runner.output(withArguments: ["update-index", "held"], input: nil, environment: nil)
            held.fulfill()
        }
        XCTAssertEqual(repository.entered.wait(timeout: .now() + 2), .success)
        let completed = expectation(description: "closed pending callback")
        let request = PBIndexMutationRequest(discardPaths: [Data("tracked.txt".utf8)])
        XCTAssertTrue(coordinator.schedule(request: request) { success, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(success)
            XCTAssertEqual((error as NSError?)?.code, 7)
            completed.fulfill()
        })
        coordinator.close()
        XCTAssertFalse(coordinator.schedule(request: request) { _, _ in XCTFail("Rejected work must not execute") })
        repository.release.signal()
        wait(for: [held, completed], timeout: 5)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPartialFailureIsDeliveredAndFollowingAdmissionRecoversToIdle() {
        let repository = PBGitRepository()
        let runner = Fake()
        runner.failNext = true
        var states: [(Int, Int)] = []
        let coordinator = PBIndexMutationCoordinator(repository: repository, service: PBIndexMutationService(repository: repository, runner: runner)) { state in
            XCTAssertTrue(Thread.isMainThread)
            states.append((state.pendingCount, state.activeCount))
        }
        let failed = expectation(description: "failed batch")
        let recovered = expectation(description: "next operation succeeds")
        let path = Data("tracked.txt".utf8)
        XCTAssertTrue(coordinator.schedule(request: PBIndexMutationRequest(stagePaths: [path], unstagePaths: [path], parentTree: "HEAD")) { success, error in
            XCTAssertFalse(success)
            XCTAssertTrue(error?.localizedDescription.contains("partial fixture failure") == true)
            failed.fulfill()
        })
        XCTAssertTrue(coordinator.schedule(request: PBIndexMutationRequest(discardPaths: [path])) { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            recovered.fulfill()
        })
        wait(for: [failed, recovered], timeout: 3)
        XCTAssertTrue(states.contains { $0.0 > 0 })
        XCTAssertTrue(states.contains { $0.1 == 1 })
        XCTAssertEqual(states.last?.0, 0)
        XCTAssertEqual(states.last?.1, 0)
        XCTAssertEqual(runner.calls.count, 3, "The mixed failure still attempts unstaging")
    }

    private final class LifetimeRepository: PBGitRepository {
        let released: () -> Void
        init(released: @escaping () -> Void) {
            self.released = released; super.init()
        }

        deinit { XCTAssertTrue(Thread.isMainThread); released() }
    }

    func testAdmittedWorkRetainsRepositoryThroughCallbackAndReleasesOnMain() {
        let released = expectation(description: "repository released on main")
        let completed = expectation(description: "callback retains repository")
        weak var weakRepository: LifetimeRepository?
        func admit() -> PBIndexMutationCoordinator {
            let repository = LifetimeRepository { released.fulfill() }
            weakRepository = repository
            let runner = Fake()
            let coordinator = PBIndexMutationCoordinator(repository: repository, service: PBIndexMutationService(repository: repository, runner: runner)) { _ in }
            XCTAssertTrue(coordinator.schedule(request: PBIndexMutationRequest(discardPaths: [Data("tracked.txt".utf8)])) { success, _ in
                XCTAssertTrue(success)
                XCTAssertNotNil(weakRepository)
                completed.fulfill()
            })
            return coordinator
        }
        let coordinator = admit()
        wait(for: [completed, released], timeout: 3)
        XCTAssertNil(weakRepository)
        XCTAssertFalse(coordinator.schedule(request: PBIndexMutationRequest(discardPaths: [])) { _, _ in XCTFail("Released repository cannot admit work") })
        coordinator.close()
    }
}
