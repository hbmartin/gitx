import Foundation
import GitXCore
import XCTest

// swift6-safety-justification: The lock protects every callback, output, and cancellation access, including delivery from the discovery queue.
private final nonisolated class ControlledWorktreeTask: PBTask, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    private var cancelled = false
    private var outputWasTruncated = false
    private var errorWasTruncated = false

    override var standardOutputTruncated: Bool {
        lock.lock(); defer { lock.unlock() }; return outputWasTruncated
    }

    override var standardErrorTruncated: Bool {
        lock.lock(); defer { lock.unlock() }; return errorWasTruncated
    }

    func setTruncationFlags(standardOutput: Bool = false, standardError: Bool = false) {
        lock.lock()
        outputWasTruncated = standardOutput; errorWasTruncated = standardError
        lock.unlock()
    }

    override func perform(on _: DispatchQueue, completionHandler: @escaping (Data?, Error?) -> Void) {
        lock.lock(); callback = completionHandler; lock.unlock()
    }

    override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
        lock.lock(); callback = completionHandler; lock.unlock()
    }

    override func terminate() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    func retainedCallback() -> ((Data?, Error?) -> Void)? {
        lock.lock(); defer { lock.unlock() }; return callback
    }

    func finish(_ data: Data?, error: Error? = nil) {
        lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
        callback?(data, error)
    }
}

// swift6-safety-justification: The lock guards every state transition and waiter; the semaphore is only a bounded failure backstop.
final nonisolated class WorktreeWorkerCheckpoint: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let timeout: TimeInterval
    let entered = XCTestExpectation(description: "utility worker entered its held phase")
    private var waiting = false
    private var released = false
    private var expectedResult = false
    private var timedOut = false
    private var finishedCount = 0
    private var waiters: [XCTestExpectation] = []

    init(timeout: TimeInterval = 60) {
        self.timeout = timeout
        entered.assertForOverFulfill = true
    }

    var didTimeout: Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }; return waiting
    }

    var wasReleased: Bool {
        lock.lock(); defer { lock.unlock() }; return released
    }

    var expectsResult: Bool {
        lock.lock(); defer { lock.unlock() }; return expectedResult
    }

    var deliveryCount: Int {
        lock.lock(); defer { lock.unlock() }; return finishedCount
    }

    func expectResult() {
        lock.lock(); expectedResult = true; lock.unlock()
    }

    func wait() {
        lock.lock(); waiting = true; lock.unlock()
        entered.fulfill()
        let result = semaphore.wait(timeout: .now() + timeout)
        lock.lock(); timedOut = result == .timedOut; waiting = false; lock.unlock()
    }

    func resume() {
        lock.lock()
        let firstRelease = !released
        released = true
        lock.unlock()
        if firstRelease {
            semaphore.signal()
        }
    }

    /// Called by the service after the held worker result is acknowledged on main.
    func finish() {
        lock.lock()
        finishedCount += 1
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.fulfill() }
    }

    /// Each waiter is fresh, so normal assertions and async teardown never re-wait one expectation.
    func finishedExpectation() -> XCTestExpectation {
        let result = XCTestExpectation(description: "utility result handled on main, including cancellation discard")
        result.assertForOverFulfill = true
        lock.lock()
        let finished = finishedCount > 0
        if !finished {
            waiters.append(result)
        }
        lock.unlock()
        if finished {
            result.fulfill()
        }
        return result
    }
}

// swift6-safety-justification: The lock guards counts and waiter registration; each direct XCTest expectation asserts overfulfillment.
private final nonisolated class WorktreeObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, XCTestExpectation)] = []
    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }

    @discardableResult
    func advance() -> Int {
        lock.lock()
        count += 1
        let value = count
        let ready = waiters.filter { $0.0 <= value }.map(\.1)
        waiters.removeAll { $0.0 <= value }
        lock.unlock()
        ready.forEach { $0.fulfill() }
        return value
    }

    func expectation(atLeast target: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "observed at least \(target) worker results")
        expectation.assertForOverFulfill = true
        lock.lock()
        let ready = count >= target
        if !ready {
            waiters.append((target, expectation))
        }
        lock.unlock()
        if ready {
            expectation.fulfill()
        }
        return expectation
    }
}

private final nonisolated class LocatedWorktreeRepository: PBGitRepository {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func gitURL() -> URL? {
        directory
    }
}

@MainActor
private final class WorktreeTaskRecorder {
    struct Request {
        let arguments: [String]
        let task: ControlledWorktreeTask
    }

    private(set) var requests: [Request] = []
    private var nextRequest: (arguments: [String], expectation: XCTestExpectation)?

    func expect(_ arguments: [String]) -> XCTestExpectation {
        XCTAssertNil(nextRequest)
        let requested = XCTestExpectation(description: arguments.joined(separator: " "))
        requested.assertForOverFulfill = true
        nextRequest = (arguments, requested)
        return requested
    }

    func makeTask(_ arguments: [String]) -> PBTask {
        let task = ControlledWorktreeTask()
        requests.append(Request(arguments: arguments, task: task))
        if let requested = nextRequest, requested.arguments == arguments {
            nextRequest = nil
            requested.expectation.fulfill()
        }
        return task
    }

    func task(_ arguments: [String], occurrence: Int = 0) throws -> ControlledWorktreeTask {
        let matching = requests.filter { $0.arguments == arguments }
        return try XCTUnwrap(matching.indices.contains(occurrence) ? matching[occurrence].task : nil)
    }

    var mutations: [[String]] {
        requests.map(\.arguments).filter { $0 != ["--version"] && $0 != ["worktree", "list", "--porcelain", "-z"] }
    }
}

@MainActor
private final class WorktreeMutationFixture {
    struct Service {
        let repository: LocatedWorktreeRepository
        let tasks: WorktreeTaskRecorder
        let service: PBRepositoryWorktreeService
    }

    private let root: URL
    private var services: [Service] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    func makeService() -> Service {
        let repository = LocatedWorktreeRepository(directory: root.appendingPathComponent(".git"))
        let tasks = WorktreeTaskRecorder()
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: tasks.makeTask)
        let fixture = Service(repository: repository, tasks: tasks, service: service)
        services.append(fixture)
        return fixture
    }

    func cleanup() {
        services.forEach { $0.service.cancel() }
        // Even a failed assertion must release an active fake writer and the shared FIFO.
        for request in services.flatMap({ $0.tasks.requests }) {
            request.task.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class WorktreeCompletionRecorder {
    var names: [String] = []
}

@MainActor
private final class WorktreeFacadeFixture {
    let root: URL
    let main: URL
    let linked: URL
    private var services: [WorktreeMutationFixture.Service] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-facade-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"])
        try Data("facade fixture content\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture"])
        _ = try git(["worktree", "add", "-b", "topic", linked.path])
    }

    func makeService(gitDirectory: URL? = nil) -> WorktreeMutationFixture.Service {
        let repository = LocatedWorktreeRepository(directory: gitDirectory ?? main.appendingPathComponent(".git"))
        let tasks = WorktreeTaskRecorder()
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: tasks.makeTask)
        let result = WorktreeMutationFixture.Service(repository: repository, tasks: tasks, service: service)
        services.append(result)
        return result
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        try GitXTestGitFixture.run(arguments, in: directory ?? main).standardOutput
    }

    func listing(at directory: URL? = nil) throws -> Data {
        try Data(git(["worktree", "list", "--porcelain", "-z"], at: directory).utf8)
    }

    func ownershipProof() throws -> [String: Data] {
        let common = main.appendingPathComponent(".git")
        let administrative = try URL(fileURLWithPath: git(["rev-parse", "--absolute-git-dir"], at: linked).trimmingCharacters(in: .newlines))
        var proof = try Dictionary(uniqueKeysWithValues: ["HEAD", "index", "gitdir", "commondir"].map {
            try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
        })
        proof["mainHEAD"] = try Data(contentsOf: common.appendingPathComponent("HEAD"))
        proof["mainIndex"] = try Data(contentsOf: common.appendingPathComponent("index"))
        proof["linkedGitfile"] = try Data(contentsOf: linked.appendingPathComponent(".git"))
        proof["mainContent"] = try Data(contentsOf: main.appendingPathComponent("tracked.txt"))
        proof["linkedContent"] = try Data(contentsOf: linked.appendingPathComponent("tracked.txt"))
        proof["mainOID"] = try Data(git(["rev-parse", "HEAD"]).utf8)
        proof["linkedOID"] = try Data(git(["rev-parse", "HEAD"], at: linked).utf8)
        proof["refs"] = try Data(git(["show-ref", "--head"]).utf8)
        return proof
    }

    func cleanup() {
        services.forEach { $0.service.cancel() }
        for request in services.flatMap({ $0.tasks.requests }) {
            request.task.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class WorktreeServiceTests: XCTestCase {
    private let snapshot = Data("worktree /main\0HEAD abc\0branch refs/heads/main\0\0worktree /linked\0HEAD def\0branch refs/heads/topic\0locked offline disk\0\0".utf8)
    private let discoveryArguments = ["worktree", "list", "--porcelain", "-z"]

    func testCachedRemovalRefusalPreservesConsentAndReleasesFollowingWriter() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        try await startFacade(installed, snapshot: fixture.listing())
        let initial = try fixture.ownershipProof()
        let refused = expectation(description: "cached removal reports Git refusal")
        let following = expectation(description: "following writer reports its result")
        let remove = ["worktree", "remove", fixture.linked.path]
        let lock = ["worktree", "lock", "--reason", "following", fixture.linked.path]
        enqueueRemoval(installed.service, path: fixture.linked.path) { _, error in
            XCTAssertEqual(error?.localizedFailureReason, "fixture refusal")
            refused.fulfill()
        }
        enqueueLock(installed.service, path: fixture.linked.path, reason: "following") { _, error in
            XCTAssertNotNil(error)
            following.fulfill()
        }
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        let removalStarted = installed.tasks.expect(remove)
        try installed.tasks.task(discoveryArguments, occurrence: 1).finish(fixture.listing())
        await fulfillment(of: [removalStarted], timeout: 5)
        XCTAssertEqual(installed.tasks.mutations, [remove])
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 2)
        let next = installed.tasks.expect(lock)
        try installed.tasks.task(remove).finish(nil, error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture refusal"]))
        await fulfillment(of: [refused, next], timeout: 5)
        try installed.tasks.task(lock).finish(nil, error: NSError(domain: "fixture", code: 2))
        await fulfillment(of: [following], timeout: 5)
        XCTAssertEqual(try fixture.ownershipProof(), initial)
        XCTAssertEqual(installed.tasks.mutations, [remove, lock])
    }

    func testInitialMutationRefusalReleasesFollowingWriterAfterInventoryPreflight() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let initialRead = installed.tasks.expect(discoveryArguments)
        installed.service.start()
        try installed.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
        await fulfillment(of: [initialRead], timeout: 5)
        XCTAssertTrue(installed.service.worktrees.isEmpty)
        XCTAssertTrue(installed.service.isSnapshotStale)
        let first = expectation(description: "initial writer refusal delivered")
        let second = expectation(description: "following initial writer refusal delivered")
        enqueueLock(installed.service, reason: "initial") { _, error in
            XCTAssertNotNil(error); first.fulfill()
        }
        enqueueUnlock(installed.service) { _, error in
            XCTAssertNotNil(error); second.fulfill()
        }
        let lock = ["worktree", "lock", "--reason", "initial", "/linked"]
        let unlock = ["worktree", "unlock", "/linked"]
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        let firstStarted = installed.tasks.expect(lock)
        let unlocked = Data(String(decoding: snapshot, as: UTF8.self).replacingOccurrences(of: "locked offline disk\0", with: "").utf8)
        try installed.tasks.task(discoveryArguments, occurrence: 1).finish(unlocked)
        await fulfillment(of: [firstStarted], timeout: 5)
        XCTAssertEqual(installed.tasks.mutations, [lock])
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 2)
        let next = installed.tasks.expect(unlock)
        try installed.tasks.task(lock).finish(nil, error: NSError(domain: "fixture", code: 1))
        await fulfillment(of: [first, next], timeout: 5)
        try installed.tasks.task(unlock).finish(nil, error: NSError(domain: "fixture", code: 2))
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(installed.service.worktrees.count, 2)
        XCTAssertEqual(installed.tasks.mutations, [lock, unlock])
    }

    func testWorktreeNotificationPublishesCompleteRowsAndSuccessfulFreshness() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        try await startFacade(installed, snapshot: fixture.listing())
        _ = try fixture.git(["worktree", "lock", "--reason", "publication fixture", fixture.linked.path])
        let published = expectation(description: "row notification exposes the accepted inventory")
        let observation = installed.service.observe(\.worktrees) { service, _ in
            // swift6-safety-justification: Worktree publication and its KVO callbacks run on the main actor.
            MainActor.assumeIsolated {
                XCTAssertEqual(service.value(forKey: "hasPublishedSnapshot") as? Bool, true)
                XCTAssertEqual(service.value(forKey: "isSnapshotStale") as? Bool, false)
                XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "publication fixture")
                published.fulfill()
            }
        }
        defer { observation.invalidate() }
        installed.service.refresh()
        try installed.tasks.task(discoveryArguments, occurrence: 1).finish(fixture.listing())
        await fulfillment(of: [published], timeout: 5)
    }

    func testInventoryStatusAndFirstSnapshotFlagsExposeCoherentTransitions() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let service = installed.service
        XCTAssertEqual(service.inventoryStatus, WorktreeInventoryStatus.checkingCapability.rawValue)
        let first = expectation(description: "first snapshot flags include the complete inventory")
        let firstObservation = service.observe(\.hasPublishedSnapshot) { service, _ in
            // swift6-safety-justification: Service KVO publication occurs on the main actor.
            MainActor.assumeIsolated {
                XCTAssertEqual(service.worktrees.count, 2)
                XCTAssertFalse(service.isSnapshotStale)
                first.fulfill()
            }
        }
        defer { firstObservation.invalidate() }
        try await startFacade(installed, snapshot: fixture.listing())
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(service.inventoryStatus, WorktreeInventoryStatus.fresh.rawValue)
        let stale = expectation(description: "failed read exposes stale status")
        let recovered = expectation(description: "equal rows recover freshness")
        let statusObservation = service.observe(\.inventoryStatus) { service, _ in
            // swift6-safety-justification: Service KVO publication occurs on the main actor.
            MainActor.assumeIsolated {
                XCTAssertTrue(service.hasPublishedSnapshot)
                XCTAssertEqual(service.worktrees.count, 2)
                if service.inventoryStatus == WorktreeInventoryStatus.stale.rawValue {
                    stale.fulfill()
                }
                if service.inventoryStatus == WorktreeInventoryStatus.fresh.rawValue {
                    recovered.fulfill()
                }
            }
        }
        defer { statusObservation.invalidate() }
        service.refresh()
        XCTAssertEqual(service.inventoryStatus, WorktreeInventoryStatus.updating.rawValue)
        try installed.tasks.task(discoveryArguments, occurrence: 1).finish(nil, error: NSError(domain: "fixture", code: 1))
        await fulfillment(of: [stale], timeout: 5)
        XCTAssertTrue(service.isSnapshotStale)
        service.refresh()
        try installed.tasks.task(discoveryArguments, occurrence: 2).finish(fixture.listing())
        await fulfillment(of: [recovered], timeout: 5)
        service.cancel()
        XCTAssertEqual(service.inventoryStatus, WorktreeInventoryStatus.closed.rawValue)
    }

    func testUnsupportedCapabilityHasItsOwnInventoryStatus() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        installed.service.start()
        try installed.tasks.task(["--version"]).finish(Data("git version 2.47.0".utf8))
        await drainMainQueue()
        XCTAssertEqual(installed.service.inventoryStatus, WorktreeInventoryStatus.unsupported.rawValue)
        XCTAssertFalse(installed.service.hasPublishedSnapshot)
        installed.service.refresh()
        XCTAssertEqual(installed.tasks.requests.count, 1)
    }

    func testNormalAndForcedRemovalRejectExternalCommitsOnBranchAndDetachedHead() async throws {
        for detached in [false, true] {
            for force in [false, true] {
                let fixture = try WorktreeFacadeFixture()
                defer { fixture.cleanup() }
                if detached {
                    _ = try fixture.git(["switch", "--detach"], at: fixture.linked)
                }
                let installed = fixture.makeService()
                try await startFacade(installed, snapshot: fixture.listing())
                _ = try fixture.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "external commit"], at: fixture.linked)
                let head = try fixture.git(["rev-parse", "HEAD"], at: fixture.linked).trimmingCharacters(in: .newlines)
                let rejected = expectation(description: "new HEAD requires a new Remove action")
                enqueueRemoval(installed.service, path: fixture.linked.path, force: force) { _, error in
                    XCTAssertTrue(error?.localizedFailureReason?.contains("Review the refreshed worktree list") == true)
                    rejected.fulfill()
                }
                try installed.tasks.task(discoveryArguments, occurrence: 1).finish(fixture.listing())
                await fulfillment(of: [rejected], timeout: 5)
                XCTAssertTrue(installed.tasks.mutations.isEmpty)
                let row = try XCTUnwrap(installed.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) })
                XCTAssertEqual(row.value(forKey: "HEAD") as? String, head)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
                _ = try fixture.git(["cat-file", "-e", head + "^{commit}"])
            }
        }
    }

    func testFreshnessRecoveryPublishesItsNewRowsBeforeNotifyingObservers() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        try await startFacade(installed, snapshot: fixture.listing())
        let stale = expectation(description: "failed discovery marks retained rows stale")
        let recovery = expectation(description: "freshness recovery includes the newly accepted row")
        let observation = installed.service.observe(\.isSnapshotStale) { service, _ in
            // swift6-safety-justification: Worktree publication and its KVO callbacks run on the main actor.
            MainActor.assumeIsolated {
                if service.isSnapshotStale {
                    stale.fulfill()
                } else {
                    XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "recovered row")
                    recovery.fulfill()
                }
            }
        }
        defer { observation.invalidate() }
        installed.service.refresh()
        try installed.tasks.task(discoveryArguments, occurrence: 1).finish(nil, error: NSError(domain: "fixture", code: 1))
        await fulfillment(of: [stale], timeout: 5)
        _ = try fixture.git(["worktree", "lock", "--reason", "recovered row", fixture.linked.path])
        installed.service.refresh()
        try installed.tasks.task(discoveryArguments, occurrence: 2).finish(fixture.listing())
        await fulfillment(of: [recovery], timeout: 5)
    }

    #if DEBUG
        func testRejectedAndFailedRemovalPreflightRetiresOlderOrdinaryDiscovery() async throws {
            for failsRead in [false, true] {
                let fixture = try WorktreeFacadeFixture()
                defer { fixture.cleanup() }
                let installed = fixture.makeService()
                let initial = try fixture.listing()
                try await startFacade(installed, snapshot: initial)
                installed.service.refresh()
                let ordinary = try installed.tasks.task(discoveryArguments, occurrence: 1)
                _ = try fixture.git(["switch", "-c", "replacement"], at: fixture.linked)
                let rejected = expectation(description: "preflight refuses removal without a write")
                enqueueRemoval(installed.service, path: fixture.linked.path) { _, error in
                    XCTAssertNotNil(error)
                    rejected.fulfill()
                }
                let preflight = try installed.tasks.task(discoveryArguments, occurrence: 2)
                if failsRead {
                    preflight.finish(nil, error: NSError(domain: "fixture", code: 2))
                } else {
                    try preflight.finish(fixture.listing())
                }
                await fulfillment(of: [rejected], timeout: 5)
                XCTAssertTrue(ordinary.wasCancelled)
                ordinary.finish(initial)
                let drained = expectation(description: "late discovery callback and evidence workers drained")
                enqueueDrain(installed.service) { drained.fulfill() }
                await fulfillment(of: [drained], timeout: 5)
                XCTAssertTrue(installed.tasks.mutations.isEmpty)
                if failsRead {
                    XCTAssertTrue(installed.service.isSnapshotStale)
                } else {
                    XCTAssertEqual(installed.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.headRefName, "refs/heads/replacement")
                }
            }
        }
    #endif

    func testUnchangedNormalAndForcedRemovalReconcilesBeforeCompleting() async throws {
        for force in [false, true] {
            let fixture = try WorktreeFacadeFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            let initial = try fixture.listing()
            try await startFacade(installed, snapshot: initial)
            let completed = expectation(description: "unchanged removal reconciles")
            var didComplete = false
            enqueueRemoval(installed.service, path: fixture.linked.path, force: force) { _, error in
                XCTAssertNil(error); didComplete = true; completed.fulfill()
            }
            XCTAssertTrue(installed.tasks.mutations.isEmpty)
            let arguments = ["worktree", "remove"] + (force ? ["--force"] : []) + [fixture.linked.path]
            let started = installed.tasks.expect(arguments)
            try installed.tasks.task(discoveryArguments, occurrence: 1).finish(initial)
            await fulfillment(of: [started], timeout: 5)
            _ = try fixture.git(arguments)
            let reconciled = installed.tasks.expect(discoveryArguments)
            try installed.tasks.task(arguments).finish(Data())
            await fulfillment(of: [reconciled], timeout: 5)
            XCTAssertFalse(didComplete)
            try installed.tasks.task(discoveryArguments, occurrence: 2).finish(fixture.listing())
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(installed.tasks.mutations, [arguments])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
            XCTAssertEqual(installed.service.worktrees.count, 1)
        }
    }

    func testExecutableReplacementDuringRemovalPreflightRejectsWithoutWriting() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        let proxy = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-removal-probe-" + UUID().uuidString)
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try? FileManager.default.removeItem(at: proxy)
        }
        try "#!/bin/sh\nexec /usr/bin/git \"$@\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        defaults.set(proxy.path, forKey: "gitExecutable")
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        try await startFacade(installed, snapshot: fixture.listing())
        let before = try fixture.ownershipProof()
        let rejected = expectation(description: "changed executable rejects removal preflight")
        enqueueRemoval(installed.service, path: fixture.linked.path) { _, error in
            XCTAssertNotNil(error); rejected.fulfill()
        }
        let read = try installed.tasks.task(discoveryArguments, occurrence: 1)
        try "#!/bin/sh\n# replaced while reading\nexec /usr/bin/git \"$@\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        try read.finish(fixture.listing())
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        XCTAssertEqual(try fixture.ownershipProof(), before)
    }

    func testRemovalRereadsExternalChangesWithoutAdoptingNewConsent() async throws {
        for force in [false, true] {
            for change in ["branch", "locked", "missing"] {
                let fixture = try WorktreeFacadeFixture()
                defer { fixture.cleanup() }
                let installed = fixture.makeService()
                try await startFacade(installed, snapshot: fixture.listing())
                if change == "branch" {
                    _ = try fixture.git(["switch", "-c", "replacement"], at: fixture.linked)
                } else if change == "locked" {
                    _ = try fixture.git(["worktree", "lock", fixture.linked.path])
                } else {
                    _ = try fixture.git(["worktree", "remove", fixture.linked.path])
                }
                let refreshed = try fixture.listing()
                let rejected = expectation(description: "changed removal evidence is rejected")
                enqueueRemoval(installed.service, path: fixture.linked.path, force: force) { _, error in
                    XCTAssertTrue(error?.localizedFailureReason?.contains("Review the refreshed worktree list") == true)
                    rejected.fulfill()
                }
                XCTAssertTrue(installed.tasks.mutations.isEmpty)
                let read = try installed.tasks.task(discoveryArguments, occurrence: 1)
                read.finish(refreshed)
                await fulfillment(of: [rejected], timeout: 5)
                XCTAssertTrue(installed.tasks.mutations.isEmpty)
                XCTAssertEqual(try fixture.listing(), refreshed)
                if change != "missing" {
                    XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("tracked.txt")), Data("facade fixture content\n".utf8))
                }
                XCTAssertEqual(Set(installed.service.worktrees.map { WorktreePaths.identity($0.path) }), Set((change == "missing" ? [fixture.main.path] : [fixture.main.path, fixture.linked.path]).map(WorktreePaths.identity)))
                let updated = installed.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }
                if change == "branch" {
                    XCTAssertEqual(updated?.headRefName, "refs/heads/replacement")
                }
                if change == "locked" {
                    XCTAssertEqual(updated?.isLocked, true)
                }
            }
        }
    }

    func testRemovalPreflightFailuresNeverWriteAndReleaseFollowingWriter() async throws {
        for incomplete in [false, true] {
            let fixture = try WorktreeFacadeFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            try await startFacade(installed, snapshot: fixture.listing())
            let before = try fixture.ownershipProof()
            let failed = expectation(description: "failed preflight reports its error")
            let following = expectation(description: "following request progresses")
            enqueueRemoval(installed.service, path: fixture.linked.path) { _, error in
                XCTAssertNotNil(error); failed.fulfill()
            }
            enqueueLock(installed.service, path: fixture.linked.path, reason: "following") { _, error in
                XCTAssertNotNil(error); following.fulfill()
            }
            let read = try installed.tasks.task(discoveryArguments, occurrence: 1)
            let started = installed.tasks.expect(["worktree", "lock", "--reason", "following", fixture.linked.path])
            if incomplete {
                read.setTruncationFlags(standardOutput: true)
                try read.finish(fixture.listing())
            } else {
                read.finish(nil, error: NSError(domain: "fixture-preflight", code: 1))
            }
            await fulfillment(of: [failed], timeout: 5)
            try installed.tasks.task(discoveryArguments, occurrence: 2).finish(fixture.listing())
            await fulfillment(of: [started], timeout: 5)
            XCTAssertFalse(installed.tasks.mutations.contains { $0.starts(with: ["worktree", "remove"]) })
            try installed.tasks.task(["worktree", "lock", "--reason", "following", fixture.linked.path]).finish(nil, error: NSError(domain: "fixture", code: 2))
            await fulfillment(of: [following], timeout: 5)
            XCTAssertEqual(try fixture.ownershipProof(), before)
        }
    }

    func testInitialMutationsWaitForOwnedInventoryAndKeepMissingConsentRejected() async throws {
        let commands: [WorktreeCommand] = [.addExisting(path: "/created", branch: "topic"), .addNew(path: "/created", branch: "new"), .lock(path: "/linked", reason: "initial"), .unlock(path: "/linked"), .remove(path: "/linked", force: false)]
        for command in commands {
            let fixture = try WorktreeMutationFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            let initialRead = installed.tasks.expect(discoveryArguments)
            installed.service.start()
            try installed.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
            await fulfillment(of: [initialRead], timeout: 5)
            let ordinary = try installed.tasks.task(discoveryArguments)
            let completed = expectation(description: "initial mutation finishes after owned inventory")
            let removes: Bool
            if case .remove = command {
                removes = true
            } else {
                removes = false
            }
            enqueueCommand(command, service: installed.service) { _, error in
                if removes {
                    XCTAssertNotNil(error)
                } else {
                    XCTAssertNil(error)
                }
                completed.fulfill()
            }
            XCTAssertTrue(installed.tasks.mutations.isEmpty)
            let preflight = try installed.tasks.task(discoveryArguments, occurrence: 1)
            let records: Data
            if case .unlock = command {
                records = snapshot
            } else {
                records = Data(String(decoding: snapshot, as: UTF8.self).replacingOccurrences(of: "locked offline disk\0", with: "").utf8)
            }
            if removes {
                preflight.finish(records)
                await fulfillment(of: [completed], timeout: 5)
                XCTAssertTrue(installed.tasks.mutations.isEmpty)
            } else {
                let started = installed.tasks.expect(command.arguments)
                preflight.finish(records)
                await fulfillment(of: [started], timeout: 5)
                let reconciled = installed.tasks.expect(discoveryArguments)
                try installed.tasks.task(command.arguments).finish(Data())
                await fulfillment(of: [reconciled], timeout: 5)
                try installed.tasks.task(discoveryArguments, occurrence: 2).finish(records)
                await fulfillment(of: [completed], timeout: 5)
                XCTAssertEqual(installed.tasks.mutations, [command.arguments])
                XCTAssertTrue(ordinary.wasCancelled)
                ordinary.finish(Data("worktree /obsolete\0HEAD old\0branch refs/heads/old\0\0".utf8))
                await drainMainQueue()
                XCTAssertFalse(installed.service.worktrees.contains { $0.path == "/obsolete" })
            }
        }
    }

    func testInitialInventoryFailureReleasesTheNextRequestWithoutWriting() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let initial = installed.tasks.expect(discoveryArguments)
        installed.service.start()
        try installed.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
        await fulfillment(of: [initial], timeout: 5)
        let first = expectation(description: "first initial preflight fails")
        let second = expectation(description: "second initial preflight fails")
        enqueueLock(installed.service, reason: "initial") { _, error in XCTAssertNotNil(error); first.fulfill() }
        enqueueUnlock(installed.service) { _, error in XCTAssertNotNil(error); second.fulfill() }
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        let firstRead = try installed.tasks.task(discoveryArguments, occurrence: 1)
        let nextRead = installed.tasks.expect(discoveryArguments)
        firstRead.finish(nil, error: NSError(domain: "fixture", code: 1))
        await fulfillment(of: [first, nextRead], timeout: 5)
        try installed.tasks.task(discoveryArguments, occurrence: 2).finish(nil, error: NSError(domain: "fixture", code: 2))
        await fulfillment(of: [second], timeout: 5)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
    }

    func testCancelledRemovalPreflightDiscardsLateInventoryAndReleasesFIFO() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await startFacade(first, snapshot: fixture.listing())
        try await startFacade(second, snapshot: fixture.listing())
        let cancelled = expectation(description: "cancelled removal completes once")
        cancelled.assertForOverFulfill = true
        let following = expectation(description: "next service obtains admission")
        enqueueRemoval(first.service, path: fixture.linked.path) { _, error in XCTAssertNotNil(error); cancelled.fulfill() }
        let read = try first.tasks.task(discoveryArguments, occurrence: 1)
        let late = try XCTUnwrap(read.retainedCallback())
        enqueueLock(second.service, path: fixture.linked.path, reason: "following") { _, error in XCTAssertNotNil(error); following.fulfill() }
        let started = second.tasks.expect(["worktree", "lock", "--reason", "following", fixture.linked.path])
        first.service.cancel()
        await fulfillment(of: [cancelled, started], timeout: 5)
        XCTAssertTrue(read.wasCancelled)
        try late(fixture.listing(), nil)
        try read.finish(fixture.listing())
        try second.tasks.task(["worktree", "lock", "--reason", "following", fixture.linked.path]).finish(nil, error: NSError(domain: "fixture", code: 1))
        await fulfillment(of: [following], timeout: 5)
        XCTAssertTrue(first.tasks.mutations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
    }

    func testObjectiveCFacadeEqualityBindsRawSymbolicHeadAcrossUnchangedRefresh() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        let originalRef = "refs/gitx/facade/original"
        let changedRef = "refs/gitx/facade/changed"
        for reference in [originalRef, changedRef] {
            _ = try fixture.git(["update-ref", reference, head])
        }
        _ = try fixture.git(["symbolic-ref", "HEAD", originalRef], at: fixture.linked)
        let initialListing = try fixture.listing()
        let initialProof = try fixture.ownershipProof()
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await startFacade(first, snapshot: initialListing)
        try await startFacade(second, snapshot: initialListing)
        let original = try XCTUnwrap(first.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) })
        let equivalent = try XCTUnwrap(second.service.worktrees.first { $0.path == original.path })
        XCTAssertFalse(original === equivalent, "Independent discoveries create independent NSObject wrappers")
        XCTAssertTrue(original.isEqual(equivalent))
        XCTAssertTrue(equivalent.isEqual(original))
        XCTAssertEqual(original.hash, equivalent.hash)
        XCTAssertTrue(original.isEqual(original))
        XCTAssertFalse(original.isEqual(nil))
        XCTAssertFalse(original.isEqual(NSObject()))
        XCTAssertFalse(original.isEqual(first.service.worktrees.first(where: \.isMain)))
        XCTAssertEqual(original.value(forKey: "HEAD") as? String, head)
        XCTAssertEqual(original.headRefName.map { Data($0.utf8) }, Data(originalRef.utf8))
        XCTAssertNil(original.branchRefName)
        XCTAssertNil(first.service.worktree(forBranch: originalRef))
        let main = try XCTUnwrap(first.service.worktree(forBranch: "refs/heads/main"))
        XCTAssertEqual(main.headRefName, "refs/heads/main")
        XCTAssertEqual(main.branchRefName, main.headRefName)

        let unchangedRequested = first.tasks.expect(discoveryArguments)
        first.service.refresh()
        await fulfillment(of: [unchangedRequested], timeout: 5)
        let coalescedRequested = first.tasks.expect(discoveryArguments)
        first.service.refresh()
        try first.tasks.task(discoveryArguments, occurrence: 1).finish(initialListing)
        // The follow-up can start only after the unchanged snapshot was compared.
        await fulfillment(of: [coalescedRequested], timeout: 5)
        XCTAssertTrue(first.service.worktrees.first { $0.path == original.path } === original)
        XCTAssertTrue(original.isEqual(equivalent))
        XCTAssertEqual(original.hash, equivalent.hash)
        XCTAssertEqual(try fixture.ownershipProof(), initialProof)

        _ = try fixture.git(["symbolic-ref", "HEAD", changedRef], at: fixture.linked)
        let changedProof = try fixture.ownershipProof()
        let changed = expectation(description: "same-commit symbolic target changed")
        let observation = first.service.observe(\.worktrees) { _, _ in changed.fulfill() }
        defer { observation.invalidate() }
        try first.tasks.task(discoveryArguments, occurrence: 2).finish(fixture.listing())
        await fulfillment(of: [changed], timeout: 5)
        let refreshed = try XCTUnwrap(first.service.worktrees.first { $0.path == original.path })
        XCTAssertFalse(refreshed === original)
        XCTAssertFalse(refreshed.isEqual(original), "A different raw symbolic target changes the value even at the same path and commit")
        XCTAssertFalse(original.isEqual(refreshed))
        XCTAssertEqual(refreshed.hash, original.hash, "Hash remains consistent with path identity across unequal metadata snapshots")
        XCTAssertEqual(refreshed.value(forKey: "HEAD") as? String, original.value(forKey: "HEAD") as? String)
        XCTAssertEqual(refreshed.headRefName.map { Data($0.utf8) }, Data(changedRef.utf8))
        XCTAssertEqual(original.headRefName, originalRef, "Published wrappers retain their captured value")
        XCTAssertNil(refreshed.branchRefName)
        XCTAssertEqual(try fixture.ownershipProof(), changedProof)
        XCTAssertEqual(changedProof["refs"], initialProof["refs"])
        XCTAssertEqual(changedProof["mainHEAD"], initialProof["mainHEAD"])
        XCTAssertEqual(changedProof["linkedOID"], initialProof["linkedOID"])
        XCTAssertTrue(first.tasks.mutations.isEmpty)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
    }

    func testObjectiveCFacadeMetadataMatchesRealLocalDetachedPrunableAndBareWorktrees() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let reason = "offline\ndisk"
        _ = try fixture.git(["worktree", "lock", "--reason", reason, fixture.linked.path])
        let detachedPath = fixture.root.appendingPathComponent("detached")
        let missingPath = fixture.root.appendingPathComponent("missing")
        let barePath = fixture.root.appendingPathComponent("bare")
        _ = try fixture.git(["worktree", "add", "--detach", detachedPath.path, "HEAD"])
        _ = try fixture.git(["worktree", "add", "-b", "missing", missingPath.path])
        try FileManager.default.removeItem(at: missingPath)
        _ = try fixture.git(["init", "--bare", barePath.path])
        let listing = try fixture.listing()
        let initialProof = try fixture.ownershipProof()
        let installed = fixture.makeService()
        try await startFacade(installed, snapshot: listing)
        let local = try XCTUnwrap(installed.service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertEqual(local.headRefName, local.branchRefName)
        XCTAssertEqual(local.value(forKey: "HEAD") as? String, try fixture.git(["rev-parse", "HEAD"], at: fixture.linked).trimmingCharacters(in: .newlines))
        XCTAssertEqual((local.value(forKey: "isBare") as? NSNumber)?.boolValue, false)
        XCTAssertEqual((local.value(forKey: "isDetached") as? NSNumber)?.boolValue, false)
        XCTAssertEqual((local.value(forKey: "isPrunable") as? NSNumber)?.boolValue, false)
        XCTAssertNil(local.value(forKey: "prunableReason"))
        XCTAssertEqual(local.value(forKey: "linkStyle") as? NSNumber, NSNumber(value: WorktreeLinkStyle.absolute.rawValue))
        XCTAssertTrue(local.isLocked)
        XCTAssertEqual(local.lockReason, reason)
        XCTAssertTrue(local.folderExists)
        let detached = try XCTUnwrap(installed.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(detachedPath.path) })
        XCTAssertEqual((detached.value(forKey: "isDetached") as? NSNumber)?.boolValue, true)
        XCTAssertEqual((detached.value(forKey: "isBare") as? NSNumber)?.boolValue, false)
        XCTAssertEqual(detached.value(forKey: "HEAD") as? String, local.value(forKey: "HEAD") as? String)
        XCTAssertNil(detached.headRefName)
        XCTAssertNil(detached.branchRefName)
        let missing = try XCTUnwrap(installed.service.worktree(forBranch: "refs/heads/missing"))
        let prunableField = try XCTUnwrap(listing.split(separator: 0).first { $0.starts(with: Data("prunable ".utf8)) })
        let reportedReason = String(decoding: prunableField.dropFirst("prunable ".utf8.count), as: UTF8.self)
        XCTAssertFalse(reportedReason.isEmpty)
        XCTAssertEqual((missing.value(forKey: "isPrunable") as? NSNumber)?.boolValue, true)
        XCTAssertEqual(missing.value(forKey: "prunableReason") as? String, reportedReason)
        XCTAssertFalse(missing.folderExists)
        XCTAssertEqual(missing.value(forKey: "linkStyle") as? NSNumber, NSNumber(value: WorktreeLinkStyle.unknown.rawValue))
        let bare = fixture.makeService(gitDirectory: barePath)
        try await startFacade(bare, snapshot: fixture.listing(at: barePath))
        let bareRecord = try XCTUnwrap(bare.service.worktrees.first)
        XCTAssertEqual(bare.service.worktrees.count, 1)
        XCTAssertTrue(bareRecord.isMain)
        XCTAssertEqual((bareRecord.value(forKey: "isBare") as? NSNumber)?.boolValue, true)
        XCTAssertEqual((bareRecord.value(forKey: "isDetached") as? NSNumber)?.boolValue, false)
        XCTAssertEqual((bareRecord.value(forKey: "isPrunable") as? NSNumber)?.boolValue, false)
        XCTAssertNil(bareRecord.value(forKey: "HEAD"))
        XCTAssertNil(bareRecord.headRefName)
        XCTAssertNil(bareRecord.branchRefName)
        XCTAssertNil(bareRecord.value(forKey: "prunableReason"))
        XCTAssertEqual(try fixture.ownershipProof(), initialProof)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        XCTAssertTrue(bare.tasks.mutations.isEmpty)
    }

    func testCommonDirectoryWritersRunInFIFOAndHoldAdmissionUntilDiscoveryCompletes() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first)
        try await start(second)
        let completions = WorktreeCompletionRecorder()
        let firstCompleted = expectation(description: "first mutation completed")
        let secondCompleted = expectation(description: "second mutation completed")
        let thirdCompleted = expectation(description: "third mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        let thirdArguments = ["worktree", "lock", "--reason", "third", "/linked"]

        enqueueLock(first.service, reason: "first") { output, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(output, "first output"); XCTAssertNil(error)
            completions.names.append("first"); firstCompleted.fulfill()
        }
        enqueueUnlock(second.service) { output, error in
            XCTAssertEqual(output, "second output"); XCTAssertNil(error)
            completions.names.append("second"); secondCompleted.fulfill()
        }
        enqueueLock(first.service, reason: "third") { output, error in
            XCTAssertEqual(output, "third output"); XCTAssertNil(error)
            completions.names.append("third"); thirdCompleted.fulfill()
        }
        XCTAssertEqual(first.tasks.mutations, [firstArguments])
        XCTAssertTrue(second.tasks.mutations.isEmpty)

        let firstDiscovery = first.tasks.expect(discoveryArguments)
        try first.tasks.task(firstArguments).finish(Data("first output".utf8))
        await fulfillment(of: [firstDiscovery], timeout: 5)
        XCTAssertTrue(completions.names.isEmpty)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        XCTAssertEqual(first.tasks.mutations, [firstArguments])
        let secondStarted = second.tasks.expect(secondArguments)
        try first.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [firstCompleted, secondStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["first"])
        XCTAssertEqual(first.tasks.mutations, [firstArguments])

        let secondDiscovery = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data("second output".utf8))
        await fulfillment(of: [secondDiscovery], timeout: 5)
        XCTAssertEqual(completions.names, ["first"])
        XCTAssertEqual(first.tasks.mutations, [firstArguments])
        let thirdStarted = first.tasks.expect(thirdArguments)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [secondCompleted, thirdStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["first", "second"])

        let thirdDiscovery = first.tasks.expect(discoveryArguments)
        try first.tasks.task(thirdArguments).finish(Data("third output".utf8))
        await fulfillment(of: [thirdDiscovery], timeout: 5)
        try first.tasks.task(discoveryArguments, occurrence: 2).finish(snapshot)
        await fulfillment(of: [thirdCompleted], timeout: 5)
        XCTAssertEqual(completions.names, ["first", "second", "third"])
        XCTAssertEqual(first.tasks.mutations, [firstArguments, thirdArguments])
        XCTAssertEqual(second.tasks.mutations, [secondArguments])
    }

    func testQueuedExecutableReplacementReprobesOnceWithoutReplayingRejectedWrites() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        let proxy = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-queued-probe-" + UUID().uuidString)
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            try? FileManager.default.removeItem(at: proxy)
        }
        try "#!/bin/sh\nexec /usr/bin/git \"$@\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        defaults.set(proxy.path, forKey: "gitExecutable")
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let blocker = fixture.makeService()
        let target = fixture.makeService()
        try await start(blocker)
        try await start(target)
        let held = expectation(description: "preceding captured-executable writer drains")
        enqueueLock(blocker.service, reason: "held") { _, _ in held.fulfill() }
        let refused = expectation(description: "queued requests reject their replaced executable")
        refused.expectedFulfillmentCount = 2
        enqueueUnlock(target.service) { _, error in
            XCTAssertTrue(error?.localizedFailureReason?.contains("selected Git") == true)
            refused.fulfill()
        }
        enqueueLock(target.service, reason: "must-not-replay") { _, error in
            XCTAssertNotNil(error)
            refused.fulfill()
        }
        try "#!/bin/sh\n# upgraded in place\nexec /usr/bin/git \"$@\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        let reprobe = target.tasks.expect(["--version"])
        try blocker.tasks.task(["worktree", "lock", "--reason", "held", "/linked"]).finish(Data())
        await fulfillment(of: [held, refused, reprobe], timeout: 5)
        XCTAssertTrue(target.tasks.mutations.isEmpty)
        XCTAssertFalse(target.service.isSupported)
        target.service.refresh()
        XCTAssertEqual(target.tasks.requests.filter { $0.arguments == ["--version"] }.count, 2, "Concurrent rejected requests coalesce the capability probe")
        let discovered = target.tasks.expect(discoveryArguments)
        try target.tasks.task(["--version"], occurrence: 1).finish(Data("git version 2.51.0".utf8))
        await fulfillment(of: [discovered], timeout: 5)
        try target.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await drainMainQueue()
        XCTAssertTrue(target.service.isSupported)
        XCTAssertTrue(target.tasks.mutations.isEmpty, "Checking a replacement never replays a rejected write")
    }

    func testQueuedRemovalRejectsANewerBranchWithoutAdoptingFreshConsent() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let blocker = fixture.makeService()
        let target = fixture.makeService()
        let unlocked = Data(String(decoding: snapshot, as: UTF8.self).replacingOccurrences(of: "locked offline disk\0", with: "").utf8)
        try await start(blocker); try await startFacade(target, snapshot: unlocked)
        XCTAssertFalse(try XCTUnwrap(target.service.worktrees.last).isLocked)
        let blockerDone = expectation(description: "earlier writer drains")
        enqueueLock(blocker.service, reason: "held") { _, error in XCTAssertNil(error); blockerDone.fulfill() }
        let rejected = expectation(description: "queued removal rejects changed branch consent")
        enqueueRemoval(target.service, path: "/linked") { _, error in
            XCTAssertTrue(error?.localizedFailureReason?.contains("Review") == true); rejected.fulfill()
        }
        let discoveryStarted = target.tasks.expect(discoveryArguments)
        target.service.refresh()
        await fulfillment(of: [discoveryStarted], timeout: 5)
        let accepted = expectation(description: "new branch snapshot is accepted before admission")
        let observation = target.service.observe(\.worktrees) { _, _ in accepted.fulfill() }
        defer { observation.invalidate() }
        let changed = Data(String(decoding: unlocked, as: UTF8.self).replacingOccurrences(of: "refs/heads/topic", with: "refs/heads/replacement").utf8)
        try target.tasks.task(discoveryArguments, occurrence: 1).finish(changed)
        await fulfillment(of: [accepted], timeout: 5)
        observation.invalidate()
        XCTAssertFalse(target.service.isSnapshotStale)
        let reconciled = blocker.tasks.expect(discoveryArguments)
        try blocker.tasks.task(["worktree", "lock", "--reason", "held", "/linked"]).finish(Data())
        await fulfillment(of: [reconciled], timeout: 5)
        let preflightStarted = target.tasks.expect(discoveryArguments)
        try blocker.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [blockerDone, preflightStarted], timeout: 5)
        try target.tasks.task(discoveryArguments, occurrence: 2).finish(changed)
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertTrue(target.tasks.mutations.isEmpty, "A fresh cache cannot replace the evidence carried by an older request")
    }

    func testSuccessfulReconciliationSatisfiesEarlierRefreshWithoutAnotherInventory() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        try await start(installed)
        let started = installed.tasks.expect(discoveryArguments)
        installed.service.refresh()
        await fulfillment(of: [started], timeout: 5)
        let retired = try installed.tasks.task(discoveryArguments, occurrence: 1)
        installed.service.refresh()
        let completed = expectation(description: "owned pass satisfies the earlier pending refresh")
        enqueueLock(installed.service, reason: "covers-earlier-read") { _, error in
            XCTAssertNil(error); completed.fulfill()
        }
        let reconciliation = installed.tasks.expect(discoveryArguments)
        try installed.tasks.task(["worktree", "lock", "--reason", "covers-earlier-read", "/linked"]).finish(Data())
        await fulfillment(of: [reconciliation], timeout: 5)
        try installed.tasks.task(discoveryArguments, occurrence: 2).finish(snapshot)
        await fulfillment(of: [completed], timeout: 5)
        await drainMainQueue()
        XCTAssertTrue(retired.wasCancelled)
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 3)
        XCTAssertFalse(installed.service.isSnapshotStale)
        retired.finish(Data("malformed".utf8))
        await drainMainQueue()
        XCTAssertEqual(installed.service.worktrees.count, 2)
    }

    #if DEBUG
        func testReconciliationPreservesEarlierAndConcurrentInvalidationsAndBoundsFailedRecovery() async throws {
            for failsReconciliation in [false, true] {
                let fixture = try WorktreeMutationFixture()
                defer { fixture.cleanup() }
                let installed = fixture.makeService()
                try await start(installed)
                XCTAssertFalse(installed.service.isSnapshotStale)
                let ordinaryStarted = installed.tasks.expect(discoveryArguments)
                installed.service.refresh()
                await fulfillment(of: [ordinaryStarted], timeout: 5)
                let ordinary = try installed.tasks.task(discoveryArguments, occurrence: 1)
                installed.service.refresh() // Pending before reconciliation takes ownership.
                let written = expectation(description: "write completes after reconciliation, including failure")
                enqueueLock(installed.service, reason: "refresh-race") { _, error in
                    XCTAssertEqual(error != nil, failsReconciliation)
                    written.fulfill()
                }
                let reconciling = installed.tasks.expect(discoveryArguments)
                try installed.tasks.task(["worktree", "lock", "--reason", "refresh-race", "/linked"]).finish(Data())
                await fulfillment(of: [reconciling], timeout: 5)
                XCTAssertTrue(ordinary.wasCancelled)
                installed.service.refresh() // Another event while the owned pass is active.
                let recoveryStarted = installed.tasks.expect(discoveryArguments)
                let owned = try installed.tasks.task(discoveryArguments, occurrence: 2)
                if failsReconciliation {
                    owned.finish(nil, error: NSError(domain: "fixture-reconciliation", code: 1))
                } else {
                    owned.finish(snapshot)
                }
                await fulfillment(of: [written, recoveryStarted], timeout: 5)
                XCTAssertEqual(installed.service.worktrees.count, 2, "A failed reread cannot erase the last snapshot")
                let recovery = try installed.tasks.task(discoveryArguments, occurrence: 3)
                let recoveryFailed = expectation(description: "failed recovery reaches its main-thread completion")
                installed.service.lifecycleEventObserver = { event in
                    if event == "worktree.list.failed phase=discovery count=0 category=task" {
                        recoveryFailed.fulfill()
                    }
                }
                defer { installed.service.lifecycleEventObserver = nil }
                recovery.finish(nil, error: NSError(domain: "fixture-recovery", code: 2))
                await fulfillment(of: [recoveryFailed], timeout: 5)
                installed.service.lifecycleEventObserver = nil
                await drainMainQueue()
                XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 4, "A failed recovery must not start an automatic retry loop")
                XCTAssertEqual(installed.service.worktrees.count, 2)
                XCTAssertTrue(installed.service.isSnapshotStale, "A failed recovery retains rows as stale rather than claiming a successful snapshot")
                let manual = installed.tasks.expect(discoveryArguments)
                installed.service.refresh()
                await fulfillment(of: [manual], timeout: 5)
                let published = expectation(description: "a later manual refresh remains usable")
                let observation = installed.service.observe(\.worktrees) { _, _ in published.fulfill() }
                try installed.tasks.task(discoveryArguments, occurrence: 4).finish(Data("worktree /main\0HEAD new\0branch refs/heads/main\0\0".utf8))
                await fulfillment(of: [published], timeout: 5)
                observation.invalidate()
                XCTAssertEqual(installed.service.worktrees.map(\.path), ["/main"])
                XCTAssertFalse(installed.service.isSnapshotStale, "A successful fresh discovery clears stale status")
                ordinary.finish(snapshot)
                await drainMainQueue()
                XCTAssertEqual(installed.service.worktrees.map(\.path), ["/main"], "A late retired discovery cannot restore removed rows")
                XCTAssertEqual(installed.tasks.mutations.count, 1)
            }
        }
    #endif

    #if DEBUG
        func testRetiredDiscoveryWorkerSkipsOwnershipCaptureAndAcknowledgesBeforeCleanup() async throws {
            let fixture = try WorktreeMutationFixture()
            let installed = fixture.makeService()
            let checkpoint = WorktreeWorkerCheckpoint()
            addTeardownBlock { @MainActor in
                checkpoint.resume()
                installed.service.cancel()
                installed.tasks.requests.forEach { $0.task.finish(nil, error: CancellationError()) }
                let drained = XCTestExpectation(description: "retired discovery finishes before deleting its fixture")
                self.enqueueDrain(installed.service) { drained.fulfill() }
                guard await XCTWaiter.fulfillment(of: [drained], timeout: 15) == .completed else {
                    XCTFail("Retaining fixture because its retired worker did not acknowledge cleanup")
                    return
                }
                fixture.cleanup()
            }
            try await start(installed)
            let initialCaptures = installed.service.ownershipCaptureCount
            installed.service.discoveryEvidenceObserver = { checkpoint.wait() }
            let reading = installed.tasks.expect(discoveryArguments)
            installed.service.refresh()
            await fulfillment(of: [reading], timeout: 5)
            try installed.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            XCTAssertTrue(checkpoint.isWaiting)
            installed.service.cancel()
            let drained = expectation(description: "closed discovery result is handled on main")
            var completed = false
            enqueueDrain(installed.service) { completed = true; drained.fulfill() }
            await drainMainQueue()
            XCTAssertFalse(completed)
            checkpoint.resume()
            await fulfillment(of: [drained], timeout: 15)
            XCTAssertFalse(checkpoint.didTimeout)
            XCTAssertEqual(installed.service.ownershipCaptureCount, initialCaptures, "Retired parse results must not start an administrative inventory")
            XCTAssertEqual(installed.service.worktrees.count, 2)
        }
    #endif

    #if DEBUG
        func testReconciliationRetiresEarlierOrdinaryDiscoveryBeforeItCanRepublishRemovedWorktree() async throws {
            let fixture = try WorktreeFacadeFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            let initial = try fixture.listing()
            try await startFacade(installed, snapshot: initial)
            let ordinaryStarted = installed.tasks.expect(discoveryArguments)
            installed.service.refresh()
            await fulfillment(of: [ordinaryStarted], timeout: 5)
            let ordinary = try installed.tasks.task(discoveryArguments, occurrence: 1)
            let removed = expectation(description: "real removal reconciled")
            let removeArguments = ["worktree", "remove", fixture.linked.path]
            enqueueRemoval(installed.service, path: fixture.linked.path) { _, error in
                XCTAssertNil(error)
                removed.fulfill()
            }
            let removalStarted = installed.tasks.expect(removeArguments)
            try installed.tasks.task(discoveryArguments, occurrence: 2).finish(initial)
            await fulfillment(of: [removalStarted], timeout: 5)
            _ = try fixture.git(removeArguments)
            let reconciled = installed.tasks.expect(discoveryArguments)
            try installed.tasks.task(removeArguments).finish(Data())
            await fulfillment(of: [reconciled], timeout: 5)
            // Reconciliation satisfies the earlier refresh. A later invalidation must survive it.
            installed.service.refresh()
            let recoveryStarted = installed.tasks.expect(discoveryArguments)
            try installed.tasks.task(discoveryArguments, occurrence: 3).finish(fixture.listing())
            await fulfillment(of: [removed, recoveryStarted], timeout: 5)
            let recoveryAccepted = expectation(description: "preserved invalidation publishes its follow-up snapshot")
            installed.service.acceptedDiscoveryObserver = { recoveryAccepted.fulfill() }
            try installed.tasks.task(discoveryArguments, occurrence: 4).finish(fixture.listing())
            await fulfillment(of: [recoveryAccepted], timeout: 5)
            installed.service.acceptedDiscoveryObserver = nil
            XCTAssertEqual(installed.service.worktrees.map { WorktreePaths.identity($0.path) }, [WorktreePaths.identity(fixture.main.path)])
            XCTAssertTrue(ordinary.wasCancelled, "Reconciliation must retire any earlier ordinary snapshot")

            // After the automatic follow-up accepts the removal, a late callback
            // from the retired reader cannot restore its row. Manual refresh remains
            // usable as another observable boundary.
            let refreshed = installed.tasks.expect(discoveryArguments)
            ordinary.finish(initial)
            installed.service.refresh()
            await fulfillment(of: [refreshed], timeout: 5)
            XCTAssertEqual(installed.service.worktrees.map { WorktreePaths.identity($0.path) }, [WorktreePaths.identity(fixture.main.path)])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
            XCTAssertEqual(installed.tasks.mutations, [removeArguments])
        }
    #endif

    func testCloseRetainsAdmissionAndDrainsTheActiveWriterThroughReconciliation() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first); try await start(second)
        let drained = expectation(description: "writer reconciles after close")
        drained.assertForOverFulfill = true
        let completed = expectation(description: "following writer completes")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        let completions = WorktreeCompletionRecorder()
        enqueueLock(first.service, reason: "first") { _, error in
            XCTAssertNil(error); completions.names.append("drained"); drained.fulfill()
        }
        enqueueUnlock(second.service) { _, error in XCTAssertNil(error); completed.fulfill() }
        let writer = try first.tasks.task(firstArguments)
        first.service.cancel(); first.service.cancel()
        XCTAssertFalse(writer.wasCancelled)
        XCTAssertTrue(completions.names.isEmpty)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        let reconciled = first.tasks.expect(discoveryArguments)
        writer.finish(Data())
        await fulfillment(of: [reconciled], timeout: 5)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        let nextStarted = second.tasks.expect(secondArguments)
        try first.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [drained, nextStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["drained"])
        let refreshed = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [completed], timeout: 5)
        writer.finish(Data("late success".utf8))
        await drainMainQueue()
        XCTAssertEqual(completions.names, ["drained"])
    }

    func testClippedPostMutationDiscoveryRetainsSnapshotFailsCompletionAndReleasesFIFO() async throws {
        for outputClipped in [true, false] {
            let fixture = try WorktreeMutationFixture()
            defer { fixture.cleanup() }
            let first = fixture.makeService()
            let second = fixture.makeService()
            try await start(first); try await start(second)
            let failed = expectation(description: "clipped discovery refuses reconciliation")
            failed.assertForOverFulfill = true
            let completed = expectation(description: "following writer completes")
            completed.assertForOverFulfill = true
            let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
            let secondArguments = ["worktree", "unlock", "/linked"]
            let completions = WorktreeCompletionRecorder()
            enqueueLock(first.service, reason: "first") { output, error in
                XCTAssertNil(output)
                XCTAssertTrue(error?.localizedFailureReason?.contains("worktree state could not be reread") == true)
                XCTAssertNotNil(error?.userInfo[NSUnderlyingErrorKey])
                completions.names.append("failed"); failed.fulfill()
            }
            enqueueUnlock(second.service) { _, error in
                XCTAssertNil(error); completions.names.append("next"); completed.fulfill()
            }
            let rereading = first.tasks.expect(discoveryArguments)
            try first.tasks.task(firstArguments).finish(Data())
            await fulfillment(of: [rereading], timeout: 5)
            let clipped = try first.tasks.task(discoveryArguments, occurrence: 1)
            clipped.setTruncationFlags(standardOutput: outputClipped, standardError: !outputClipped)
            let nextStarted = second.tasks.expect(secondArguments)
            // Complete-looking porcelain must not become authority when either stream was clipped.
            clipped.finish(Data("worktree /unexpected\0HEAD unexpected\0branch refs/heads/other\0\0".utf8))
            await fulfillment(of: [failed, nextStarted], timeout: 5)
            XCTAssertEqual(first.service.worktrees.map(\.path), ["/main", "/linked"])
            XCTAssertEqual(completions.names, ["failed"])
            let nextDiscovery = second.tasks.expect(discoveryArguments)
            try second.tasks.task(secondArguments).finish(Data())
            await fulfillment(of: [nextDiscovery], timeout: 5)
            try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(completions.names, ["failed", "next"])
        }
    }

    func testFailedMutationPropagatesErrorAndReleasesNextWriterWithoutDiscovery() async throws {
        let fixture = try WorktreeFacadeFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        let initial = try fixture.listing()
        try await startFacade(first, snapshot: initial)
        try await startFacade(second, snapshot: initial)
        let completions = WorktreeCompletionRecorder()
        let failed = expectation(description: "failed mutation completed")
        let completed = expectation(description: "next mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", fixture.linked.path]
        let secondArguments = ["worktree", "unlock", fixture.linked.path]
        enqueueLock(first.service, path: fixture.linked.path, reason: "first") { output, error in
            XCTAssertNil(output)
            XCTAssertEqual(error?.localizedFailureReason, "Git refused lock")
            XCTAssertEqual((error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain, "fixture")
            completions.names.append("failed"); failed.fulfill()
        }
        enqueueUnlock(second.service, path: fixture.linked.path) { _, error in
            XCTAssertNil(error)
            completions.names.append("next"); completed.fulfill()
        }
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        let nextStarted = second.tasks.expect(secondArguments)
        let error = NSError(domain: "fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "Git refused lock"])
        try first.tasks.task(firstArguments).finish(nil, error: error)
        await fulfillment(of: [failed, nextStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["failed"])
        XCTAssertEqual(first.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 1)

        let refreshed = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(initial)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions.names, ["failed", "next"])
    }

    func testCancellingQueuedServiceSkipsItsMutationAndReleasesFollowingWriter() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let cancelled = fixture.makeService()
        let last = fixture.makeService()
        try await start(first)
        try await start(cancelled)
        try await start(last)
        let completions = WorktreeCompletionRecorder()
        let firstCompleted = expectation(description: "first mutation completed")
        let cancelledCompleted = expectation(description: "queued cancellation completed")
        let lastCompleted = expectation(description: "last mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let lastArguments = ["worktree", "unlock", "/linked"]
        enqueueLock(first.service, reason: "first") { _, error in
            XCTAssertNil(error)
            completions.names.append("first"); firstCompleted.fulfill()
        }
        enqueueLock(cancelled.service, reason: "cancelled") { output, error in
            XCTAssertNil(output)
            XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error?.code, NSUserCancelledError)
            completions.names.append("cancelled"); cancelledCompleted.fulfill()
        }
        enqueueUnlock(last.service) { _, error in
            XCTAssertNil(error)
            completions.names.append("last"); lastCompleted.fulfill()
        }
        cancelled.service.cancel()
        XCTAssertTrue(completions.names.isEmpty)
        XCTAssertTrue(cancelled.tasks.mutations.isEmpty)
        XCTAssertTrue(last.tasks.mutations.isEmpty)

        let refreshed = first.tasks.expect(discoveryArguments)
        try first.tasks.task(firstArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        let lastStarted = last.tasks.expect(lastArguments)
        try first.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [firstCompleted, cancelledCompleted, lastStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["first", "cancelled"])
        XCTAssertTrue(cancelled.tasks.mutations.isEmpty)

        let lastDiscovery = last.tasks.expect(discoveryArguments)
        try last.tasks.task(lastArguments).finish(Data())
        await fulfillment(of: [lastDiscovery], timeout: 5)
        try last.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [lastCompleted], timeout: 5)
        XCTAssertEqual(completions.names, ["first", "cancelled", "last"])
    }

    func testCloseDrainsPostMutationDiscoveryKeepsFIFOAndIgnoresLateCompletion() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first); try await start(second)
        let completions = WorktreeCompletionRecorder()
        let drained = expectation(description: "post-write reconciliation survives close")
        let completed = expectation(description: "next mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        enqueueLock(first.service, reason: "first") { _, error in
            XCTAssertNil(error); completions.names.append("drained"); drained.fulfill()
        }
        enqueueUnlock(second.service) { _, error in
            XCTAssertNil(error); completions.names.append("next"); completed.fulfill()
        }
        let refreshed = first.tasks.expect(discoveryArguments)
        try first.tasks.task(firstArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        let reconciliation = try first.tasks.task(discoveryArguments, occurrence: 1)
        first.service.cancel()
        XCTAssertFalse(reconciliation.wasCancelled)
        XCTAssertTrue(completions.names.isEmpty)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        let nextStarted = second.tasks.expect(secondArguments)
        reconciliation.finish(Data("worktree /late\0HEAD late\0branch refs/heads/late\0\0".utf8))
        await fulfillment(of: [drained, nextStarted], timeout: 5)
        XCTAssertEqual(first.service.worktrees.map(\.path), ["/main", "/linked"], "Closed owners do not receive new publications")
        XCTAssertEqual(completions.names, ["drained"])
        reconciliation.finish(snapshot)
        await drainMainQueue()
        XCTAssertEqual(completions.names, ["drained"])
        let secondDiscovery = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data())
        await fulfillment(of: [secondDiscovery], timeout: 5)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions.names, ["drained", "next"])
    }

    func testCoalescesPublishesChangedSnapshotsOnMainAndRetainsFailure() async {
        let repository = PBGitRepository()
        var tasks: [ControlledWorktreeTask] = []
        var requested = expectation(description: "initial discovery")
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            if arguments == ["--version"] {
                return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.48.0"], inDirectory: nil)
            }
            let task = ControlledWorktreeTask(); tasks.append(task); requested.fulfill(); return task
        }
        var publications = 0
        let changed = expectation(description: "snapshot publication")
        let observation = service.observe(\.worktrees) { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            // swift6-safety-justification: The assertion above verifies discovery publishes this KVO callback on the main thread.
            MainActor.assumeIsolated { publications += 1; changed.fulfill() }
        }
        defer { observation.invalidate(); service.cancel() }
        service.start()
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(service.isSupported)
        requested = expectation(description: "one coalesced discovery")
        service.refresh(); service.refresh(); service.refresh()
        XCTAssertEqual(tasks.count, 1)
        tasks[0].finish(snapshot)
        await fulfillment(of: [changed, requested], timeout: 5)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.path, "/linked")
        XCTAssertNil(service.worktree(forBranch: "refs/heads/missing"))
        tasks[1].finish(snapshot)
        await drainMainQueue()
        XCTAssertEqual(publications, 1)
        requested = expectation(description: "failure discovery")
        service.refresh()
        await fulfillment(of: [requested], timeout: 5)
        tasks[2].finish(Data("malformed".utf8))
        await drainMainQueue()
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(publications, 1)
        requested = expectation(description: "Git error discovery")
        service.refresh()
        await fulfillment(of: [requested], timeout: 5)
        tasks[3].finish(nil, error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Git refused discovery"]))
        await drainMainQueue()
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(service.isSnapshotStale)
        let fresh = expectation(description: "identical rows publish independent freshness")
        let freshness = service.observe(\.isSnapshotStale) { value, _ in
            // swift6-safety-justification: Service freshness notifications are delivered on the main queue.
            MainActor.assumeIsolated {
                if !value.isSnapshotStale {
                    fresh.fulfill()
                }
            }
        }
        requested = expectation(description: "equal snapshot recovery")
        service.refresh()
        await fulfillment(of: [requested], timeout: 5)
        tasks[4].finish(snapshot)
        await fulfillment(of: [fresh], timeout: 5)
        freshness.invalidate()
        XCTAssertEqual(publications, 1, "Freshness updates do not manufacture row changes")
        XCTAssertFalse(service.isSnapshotStale)
    }

    func testCancelTerminatesPendingDiscoveryAndRejectsLateCompletion() async {
        let repository = PBGitRepository()
        let task = ControlledWorktreeTask()
        let requested = expectation(description: "discovery requested")
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            if arguments == ["--version"] {
                return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.54.0"], inDirectory: nil)
            }
            requested.fulfill(); return task
        }
        service.start(); service.start()
        await fulfillment(of: [requested], timeout: 5)
        service.refresh(); service.cancel()
        XCTAssertTrue(task.wasCancelled)
        task.finish(snapshot)
        service.refresh()
        await drainMainQueue()
        XCTAssertTrue(service.worktrees.isEmpty)
        XCTAssertNil(service.worktree(forBranch: "refs/heads/topic"))
    }

    func testOldAndUnavailableGitDisableDiscoveryAndExplainMinimum() async {
        for version in ["git version 2.47.9", "not Git"] {
            let repository = PBGitRepository()
            let checked = expectation(description: "version checked")
            let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                XCTAssertEqual(arguments, ["--version"])
                return PBTask(launchPath: "/bin/echo", arguments: [version], inDirectory: nil)
            }
            let observation = service.observe(\.gitVersion) { _, _ in checked.fulfill() }
            service.start()
            await fulfillment(of: [checked], timeout: 5)
            XCTAssertFalse(service.isSupported)
            XCTAssertTrue(service.explanation.contains("Git 2.48"))
            service.refresh(); service.cancel(); observation.invalidate()
        }
    }

    func testWatchOwnershipSeparatesSharedReferencesAndSiblingIndexes() {
        let linked = PBRepositoryWatchPaths(gitDirectory: "/repo/.git/worktrees/one", commonDirectory: "/repo/.git", workingDirectory: "/linked")
        for path in ["/repo/.git/worktrees/one/HEAD", "/repo/.git/worktrees/one/index"] {
            XCTAssertEqual(linked.category(for: path), 1)
        }
        for path in ["/repo/.git/refs/heads/main", "/repo/.git/worktrees/two/HEAD", "/repo/.git/worktrees"] {
            XCTAssertEqual(linked.category(for: path), 2)
        }
        for path in ["/repo/.git/index", "/repo/.git/worktrees/two/index", "/repo/.git/refs/main.lock", "/repo/.git/objects/abc", "/linked-other/file"] {
            XCTAssertEqual(linked.category(for: path), 0)
        }
        XCTAssertEqual(linked.category(for: "/linked/file"), 3)
        let main = PBRepositoryWatchPaths(gitDirectory: "/repo/.git", commonDirectory: "/repo/.git", workingDirectory: "/repo")
        XCTAssertEqual(main.category(for: "/repo/.git/index"), 1)
        XCTAssertEqual(main.category(for: "/repo/.git/worktrees/two/index"), 0)
        XCTAssertEqual(main.category(for: "/repo/.git/worktrees/two/HEAD"), 2)
        XCTAssertEqual(main.category(for: "/repo/.git/refs/main"), 2)
        XCTAssertEqual(main.category(for: "/repo/file"), 3)
        XCTAssertEqual(main.category(for: "/repo/.git/HEAD.lock"), 0)
    }

    func testCapabilityChangePublishesInputsBeforeCancellingAnAdmittedReadAndUsesItsOwnTaskFlags() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for clipped in [(output: false, error: false), (output: true, error: false), (output: false, error: true)] {
            defaults.set("/usr/bin/git", forKey: "gitExecutable")
            let fixture = try WorktreeMutationFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            let service = installed.service
            var previousProbe: ControlledWorktreeTask?
            var previousCallback: ((Data?, Error?) -> Void)?
            try await start(installed, observingInitialProbe: {
                previousProbe = $0
                previousCallback = $0.retainedCallback()
            })
            let obsolete = try XCTUnwrap(previousProbe)
            let lateObsolete = try XCTUnwrap(previousCallback)
            XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 1)
            let reading = installed.tasks.expect(discoveryArguments)
            let readCancelled = expectation(description: "admitted preview cancels once")
            let queuedCancelled = expectation(description: "same-service queued writer cancels once")
            readCancelled.assertForOverFulfill = true
            queuedCancelled.assertForOverFulfill = true
            enqueuePrunePreview(service) { preview, error in
                XCTAssertNil(preview)
                XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
                XCTAssertEqual(error?.code, NSUserCancelledError)
                // A normal client entry point is called synchronously while cancellation is
                // being delivered, before complete() releases the shared FIFO reservation.
                service.refresh()
                readCancelled.fulfill()
            }
            await fulfillment(of: [reading], timeout: 5)
            let oldRead = try installed.tasks.task(discoveryArguments, occurrence: 1)
            enqueueLock(service, reason: "must-cancel-before-launch") { _, error in
                XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
                XCTAssertEqual(error?.code, NSUserCancelledError)
                queuedCancelled.fulfill()
            }
            XCTAssertTrue(installed.tasks.mutations.isEmpty)
            defaults.set("/usr/bin/true", forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            await fulfillment(of: [readCancelled, queuedCancelled], timeout: 5)
            await drainMainQueue()
            let probes = installed.tasks.requests.filter { $0.arguments == ["--version"] }
            XCTAssertEqual(probes.count, 2, "One preference change launches exactly one additional probe")
            XCTAssertTrue(oldRead.wasCancelled)
            XCTAssertTrue(installed.tasks.mutations.isEmpty)
            let current = try installed.tasks.task(["--version"], occurrence: 1)
            let currentComplete = !clipped.output && !clipped.error
            current.setTruncationFlags(standardOutput: clipped.output, standardError: clipped.error)
            obsolete.setTruncationFlags(standardOutput: currentComplete, standardError: currentComplete)
            lateObsolete(Data("git version 1.0.0".utf8), nil)
            await drainMainQueue()
            XCTAssertFalse(service.isSupported, "A real old callback cannot certify the pending current probe")
            XCTAssertNil(service.gitVersion)
            XCTAssertFalse(current.wasCancelled)
            XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 2)
            let version = "git version 2.50.1"
            current.finish(Data(version.utf8))
            await drainMainQueue()
            XCTAssertEqual(service.isSupported, currentComplete)
            XCTAssertEqual(service.gitVersion, currentComplete ? version : nil)
            lateObsolete(Data("git version 1.0.0".utf8), nil)
            oldRead.finish(nil, error: CancellationError())
            await drainMainQueue()
            XCTAssertEqual(service.isSupported, currentComplete)
            XCTAssertEqual(service.gitVersion, currentComplete ? version : nil)
            XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 2)
            // Complete any automatic successful-probe discovery so no fake read remains.
            for request in installed.tasks.requests.filter({ $0.arguments == discoveryArguments }) {
                request.task.finish(snapshot)
            }
            await drainMainQueue()
        }
    }

    func testAvailabilityObserverChangingThePreferenceAgainDoesNotTerminateOrSupersedeTheNewestProbe() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let service = installed.service
        var previousProbe: ControlledWorktreeTask?
        var previousCallback: ((Data?, Error?) -> Void)?
        try await start(installed, observingInitialProbe: {
            previousProbe = $0
            previousCallback = $0.retainedCallback()
        })
        let obsolete = try XCTUnwrap(previousProbe)
        let lateObsolete = try XCTUnwrap(previousCallback)
        let reading = installed.tasks.expect(discoveryArguments)
        let readCancelled = expectation(description: "availability transition cancels admitted read once")
        let queuedCancelled = expectation(description: "availability transition cancels queued writer once")
        readCancelled.assertForOverFulfill = true
        queuedCancelled.assertForOverFulfill = true
        enqueuePrunePreview(service) { preview, error in
            XCTAssertNil(preview)
            XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error?.code, NSUserCancelledError)
            readCancelled.fulfill()
        }
        await fulfillment(of: [reading], timeout: 5)
        let oldRead = try installed.tasks.task(discoveryArguments, occurrence: 1)
        enqueueLock(service, reason: "must-not-launch") { _, error in
            XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error?.code, NSUserCancelledError)
            queuedCancelled.fulfill()
        }
        let reentry = WorktreeCompletionRecorder()
        let changedAgain = expectation(description: "one-shot observer chooses C while B publishes unavailable")
        changedAgain.assertForOverFulfill = true
        let observation = service.observe(\.gitVersion) { observed, _ in
            // swift6-safety-justification: Service availability is published on its main actor.
            MainActor.assumeIsolated {
                guard observed.gitVersion == nil, reentry.names.isEmpty else { return }
                reentry.names.append("changed-once")
                UserDefaults.standard.set("/usr/bin/false", forKey: "gitExecutable")
                service.refresh() // Synchronous existing entry point starts C before B returns.
                changedAgain.fulfill()
            }
        }
        defer { observation.invalidate() }
        defaults.set("/usr/bin/true", forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [changedAgain, readCancelled, queuedCancelled], timeout: 5)
        await drainMainQueue()
        observation.invalidate()
        let probes = installed.tasks.requests.filter { $0.arguments == ["--version"] }
        XCTAssertEqual(probes.count, 2, "Initial probe and C only: superseded B must never launch")
        let current = try installed.tasks.task(["--version"], occurrence: 1)
        XCTAssertFalse(current.wasCancelled, "B must retire only its captured old tasks, never C")
        XCTAssertTrue(oldRead.wasCancelled)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        let discovered = installed.tasks.expect(discoveryArguments)
        current.finish(Data("git version 2.50.3".utf8))
        await fulfillment(of: [discovered], timeout: 5)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, "git version 2.50.3")
        // A superseded callback cannot replace the newest accepted result.
        obsolete.setTruncationFlags(standardOutput: true, standardError: true)
        lateObsolete(Data("git version 1.0.0".utf8), nil)
        oldRead.finish(nil, error: CancellationError())
        try installed.tasks.task(discoveryArguments, occurrence: 2).finish(snapshot)
        await drainMainQueue()
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, "git version 2.50.3")
        XCTAssertEqual(reentry.names, ["changed-once"])
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
    }

    func testAvailabilityObserverClosingTheServiceCancelsReadsWithoutLaunchingAnotherProbe() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let service = installed.service
        try await start(installed)
        let initial = service.worktrees
        let reading = installed.tasks.expect(discoveryArguments)
        let readCancelled = expectation(description: "close during availability cancels admitted read once")
        let queuedCancelled = expectation(description: "close during availability cancels queued writer once")
        readCancelled.assertForOverFulfill = true
        queuedCancelled.assertForOverFulfill = true
        enqueuePrunePreview(service) { preview, error in
            XCTAssertNil(preview)
            XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error?.code, NSUserCancelledError)
            readCancelled.fulfill()
        }
        await fulfillment(of: [reading], timeout: 5)
        let oldRead = try installed.tasks.task(discoveryArguments, occurrence: 1)
        enqueueLock(service, reason: "must-not-launch") { _, error in
            XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error?.code, NSUserCancelledError)
            queuedCancelled.fulfill()
        }
        let reentry = WorktreeCompletionRecorder()
        let closed = expectation(description: "one-shot availability observer closes owner")
        closed.assertForOverFulfill = true
        let observation = service.observe(\.gitVersion) { observed, _ in
            // swift6-safety-justification: Service availability is published on its main actor.
            MainActor.assumeIsolated {
                guard observed.gitVersion == nil, reentry.names.isEmpty else { return }
                reentry.names.append("closed-once")
                service.cancel()
                closed.fulfill()
            }
        }
        defer { observation.invalidate() }
        defaults.set("/usr/bin/true", forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [closed, readCancelled, queuedCancelled], timeout: 5)
        await drainMainQueue()
        observation.invalidate()
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 1,
                       "Close invalidates B before task construction")
        XCTAssertTrue(oldRead.wasCancelled)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        oldRead.finish(snapshot)
        service.refresh()
        service.start()
        await drainMainQueue()
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 1)
        XCTAssertFalse(service.isSupported)
        XCTAssertEqual(service.worktrees, initial)
        XCTAssertEqual(reentry.names, ["closed-once"])
    }

    #if DEBUG
        func testPreferenceFingerprintBurstKeepsMainActorResponsiveAndCoalescesOneLatestCheck() async throws {
            try await assertPreferenceFingerprintHandling(.unchangedBurst)
        }
    #endif

    #if DEBUG
        func testReleasedOldPreferenceFingerprintCannotReplaceAnAcceptedNewGeneration() async throws {
            try await assertPreferenceFingerprintHandling(.replacedGeneration)
        }
    #endif

    #if DEBUG
        func testClosedServiceDiscardsItsReleasedPreferenceFingerprintWithoutLaunchingGit() async throws {
            try await assertPreferenceFingerprintHandling(.closed)
        }
    #endif

    #if DEBUG
        func testClosedServiceDrainDeliversIdleWaitersAsynchronouslyAndExactlyOnce() async throws {
            let fixture = try WorktreeMutationFixture()
            defer { fixture.cleanup() }
            let service = fixture.makeService().service
            service.cancel()
            let drained = WorktreeObservationCounter()
            enqueueDrain(service) { drained.advance() }
            enqueueDrain(service) { drained.advance() }
            XCTAssertEqual(drained.value, 0)
            await fulfillment(of: [drained.expectation(atLeast: 2)], timeout: 5)
            await drainMainQueue()
            XCTAssertEqual(drained.value, 2)
        }
    #endif

    private enum PreferenceFingerprintScenario: Equatable { case unchangedBurst, replacedGeneration, closed }

    @MainActor
    private final class PreferenceFingerprintCleanupState {
        var posted = false
        var burstPosted = false
    }

    #if DEBUG
        private func assertPreferenceFingerprintHandling(_ scenario: PreferenceFingerprintScenario) async throws {
            let fixture = try WorktreeMutationFixture()
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "gitExecutable")
            defaults.set("/usr/bin/git", forKey: "gitExecutable")
            let installed = fixture.makeService()
            let service = installed.service
            let worker = WorktreeWorkerCheckpoint()
            let starts = WorktreeObservationCounter()
            let results = WorktreeObservationCounter()
            let cleanup = PreferenceFingerprintCleanupState()
            let drains = WorktreeObservationCounter()
            addTeardownBlock { @MainActor in
                // Closing before releasing the held worker prevents pending checks
                // from becoming new work. If its first result already ran, a single
                // pending job was scheduled before that result's acknowledgement.
                let expected = cleanup.burstPosted && results.value > 0 ? 2 : 1
                service.cancel()
                worker.resume()
                if cleanup.posted {
                    await self.fulfillment(of: [results.expectation(atLeast: expected)], timeout: 10)
                }
                service.preferenceFingerprintObserver = nil
                service.preferenceFingerprintResultObserver = nil
                service.acceptedDiscoveryObserver = nil
                if !cleanup.posted || results.value >= expected, !worker.isWaiting {
                    fixture.cleanup()
                } else {
                    let path = installed.repository.gitURL()?.deletingLastPathComponent().path ?? "unknown"
                    XCTFail("Preference teardown could not observe terminal drainage; preserving fixture at " + path)
                }
                defaults.set(previous, forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            }
            try await start(installed)
            let initial = service.worktrees
            service.preferenceFingerprintObserver = {
                if starts.advance() == 1 {
                    worker.wait()
                }
            }
            service.preferenceFingerprintResultObserver = {
                if results.advance() == 1 {
                    worker.finish()
                }
            }
            cleanup.posted = true
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            await fulfillment(of: [worker.entered], timeout: 5)
            let mainProgress = expectation(description: "main actor runs while preference fingerprint is held")
            DispatchQueue.main.async { mainProgress.fulfill() }
            await fulfillment(of: [mainProgress], timeout: 5)
            XCTAssertTrue(worker.isWaiting)
            XCTAssertFalse(worker.wasReleased)
            XCTAssertEqual(starts.value, 1)
            XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 1)
            if scenario == .closed {
                service.cancel()
                enqueueDrain(service) { drains.advance() }
                await drainMainQueue()
                XCTAssertEqual(drains.value, 0, "Cancellation must not acknowledge a still-running worker")
            } else {
                if scenario == .replacedGeneration {
                    let requested = installed.tasks.expect(["--version"])
                    defaults.set("/usr/bin/true", forKey: "gitExecutable")
                    // Public entry validation remains fresh even while notification
                    // fingerprinting is held. It certifies a newer generation now.
                    service.refresh()
                    await fulfillment(of: [requested], timeout: 5)
                    let discovered = installed.tasks.expect(discoveryArguments)
                    let accepted = expectation(description: "new generation discovery accepted")
                    service.acceptedDiscoveryObserver = { accepted.fulfill() }
                    try installed.tasks.task(["--version"], occurrence: 1).finish(Data("git version 2.50.3".utf8))
                    await fulfillment(of: [discovered], timeout: 5)
                    try installed.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
                    await fulfillment(of: [accepted], timeout: 5)
                    service.acceptedDiscoveryObserver = nil
                    XCTAssertTrue(service.isSupported)
                    XCTAssertEqual(service.gitVersion, "git version 2.50.3")
                }
                cleanup.burstPosted = true
                for _ in 0 ..< 20 {
                    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
                }
                // These are the known main scheduling blocks enqueued by the
                // synchronous posts above, not a substitute for a worker drain.
                await drainMainQueue()
                XCTAssertTrue(worker.isWaiting)
                XCTAssertEqual(starts.value, 1)
            }
            worker.resume()
            let expectedChecks = scenario == .closed ? 1 : 2
            await fulfillment(of: [results.expectation(atLeast: expectedChecks)], timeout: 10)
            if scenario == .closed {
                await fulfillment(of: [drains.expectation(atLeast: 1)], timeout: 5)
                XCTAssertEqual(drains.value, 1)
            }
            XCTAssertFalse(worker.didTimeout)
            XCTAssertFalse(worker.isWaiting)
            XCTAssertTrue(worker.wasReleased)
            XCTAssertEqual(worker.deliveryCount, 1)
            XCTAssertEqual(starts.value, expectedChecks)
            XCTAssertEqual(results.value, expectedChecks)
            XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count,
                           scenario == .replacedGeneration ? 2 : 1)
            XCTAssertTrue(installed.tasks.mutations.isEmpty)
            XCTAssertEqual(service.worktrees, initial)
            if scenario == .closed {
                let requests = installed.tasks.requests.count
                service.refresh(); service.start()
                XCTAssertEqual(installed.tasks.requests.count, requests)
            } else if scenario == .replacedGeneration {
                XCTAssertTrue(service.isSupported)
                XCTAssertEqual(service.gitVersion, "git version 2.50.3")
            } else {
                XCTAssertTrue(service.isSupported)
                XCTAssertEqual(service.gitVersion, "git version 2.48.0")
                let discovered = installed.tasks.expect(discoveryArguments)
                let accepted = expectation(description: "ordinary discovery remains usable after burst")
                service.acceptedDiscoveryObserver = { accepted.fulfill() }
                service.refresh()
                await fulfillment(of: [discovered], timeout: 5)
                try installed.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
                await fulfillment(of: [accepted], timeout: 5)
                service.acceptedDiscoveryObserver = nil
            }
        }
    #endif

    private func enqueuePrunePreview(_ service: PBRepositoryWorktreeService, completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void) {
        service.preparePrunePreview { preview, error in
            // swift6-safety-justification: The service delivers preview completion on the main queue.
            MainActor.assumeIsolated { completion(preview, error as NSError?) }
        }
    }

    func testAcceptedCapabilityPublicationDoesNotOverwriteAProbeStartedByItsGitVersionObserver() async throws {
        try await characterizeSuccessfulCapabilityPublicationReentry(observeSupported: false)
    }

    func testAcceptedCapabilityPublicationDoesNotOverwriteAProbeStartedByItsAvailabilityObserver() async throws {
        try await characterizeSuccessfulCapabilityPublicationReentry(observeSupported: true)
    }

    private func characterizeSuccessfulCapabilityPublicationReentry(observeSupported: Bool) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let installed = fixture.makeService()
        let service = installed.service
        try await start(installed)
        let initial = service.worktrees
        let initialDiscoveries = installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count
        let versionB = "git version 2.50.2"
        let versionC = "git version 2.50.3"
        let requestedB = installed.tasks.expect(["--version"])
        defaults.set("/usr/bin/true", forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [requestedB], timeout: 5)
        let b = try installed.tasks.task(["--version"], occurrence: 1)
        let lateB = try XCTUnwrap(b.retainedCallback())
        XCTAssertFalse(service.isSupported)
        XCTAssertNil(service.gitVersion)
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count, initialDiscoveries)
        let reentry = WorktreeCompletionRecorder()
        let changedAgain = expectation(description: "one-shot successful publication observer chooses C")
        changedAgain.assertForOverFulfill = true
        let requestedC = installed.tasks.expect(["--version"])
        let observation: NSKeyValueObservation
        if observeSupported {
            observation = service.observe(\.isSupported) { observed, _ in
                // swift6-safety-justification: Service availability is published on its main actor.
                MainActor.assumeIsolated {
                    guard observed.isSupported, reentry.names.isEmpty else { return }
                    reentry.names.append("C")
                    UserDefaults.standard.set("/usr/bin/false", forKey: "gitExecutable")
                    service.refresh()
                    changedAgain.fulfill()
                }
            }
        } else {
            observation = service.observe(\.gitVersion) { observed, _ in
                // swift6-safety-justification: Service availability is published on its main actor.
                MainActor.assumeIsolated {
                    guard observed.gitVersion == versionB, reentry.names.isEmpty else { return }
                    reentry.names.append("C")
                    UserDefaults.standard.set("/usr/bin/false", forKey: "gitExecutable")
                    service.refresh()
                    changedAgain.fulfill()
                }
            }
        }
        defer { observation.invalidate() }
        b.finish(Data(versionB.utf8))
        await fulfillment(of: [changedAgain, requestedC], timeout: 5)
        await drainMainQueue()
        observation.invalidate()
        let current = try installed.tasks.task(["--version"], occurrence: 2)
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 3)
        XCTAssertFalse(current.wasCancelled, "Older B publication must not terminate C")
        XCTAssertFalse(service.isSupported, "Only C's pending probe may decide current availability")
        XCTAssertNil(service.gitVersion, "B cannot overwrite C's unavailable state")
        XCTAssertEqual(service.worktrees, initial)
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
        let beforeCertification = installed.tasks.requests.filter { $0.arguments == discoveryArguments }.count
        XCTAssertEqual(beforeCertification, initialDiscoveries,
                       "Ordinary discovery must not start using C before C is certified")
        // Avoid cascading timeout failures if the RED oracle already observed an
        // uncertified discovery. Fixture cleanup cancels every retained fake task.
        guard beforeCertification == initialDiscoveries else { return }
        let currentDiscovery = installed.tasks.expect(discoveryArguments)
        current.finish(Data(versionC.utf8))
        await fulfillment(of: [currentDiscovery], timeout: 5)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, versionC)
        lateB(Data("git version 1.0.0".utf8), nil)
        await drainMainQueue()
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, versionC)
        XCTAssertFalse(current.wasCancelled)
        XCTAssertEqual(installed.tasks.requests.filter { $0.arguments == ["--version"] }.count, 3)
        try installed.tasks.task(discoveryArguments, occurrence: initialDiscoveries).finish(snapshot)
        await drainMainQueue()
        XCTAssertEqual(reentry.names, ["C"])
        XCTAssertTrue(installed.tasks.mutations.isEmpty)
    }

    #if DEBUG
        private func enqueueDrain(_ service: PBRepositoryWorktreeService, completion: @escaping @MainActor @Sendable () -> Void) {
            service.drainForTesting(completion: completion)
        }
    #endif

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue completion boundary")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    private func start(_ fixture: WorktreeMutationFixture.Service, observingInitialProbe: ((ControlledWorktreeTask) -> Void)? = nil) async throws {
        let requested = fixture.tasks.expect(discoveryArguments)
        let published = expectation(description: "initial worktree snapshot published")
        let observation = fixture.service.observe(\.worktrees) { _, _ in published.fulfill() }
        defer { observation.invalidate() }
        fixture.service.start()
        let probe = try fixture.tasks.task(["--version"])
        observingInitialProbe?(probe)
        probe.finish(Data("git version 2.48.0".utf8))
        await fulfillment(of: [requested], timeout: 5)
        try fixture.tasks.task(discoveryArguments).finish(snapshot)
        await fulfillment(of: [published], timeout: 5)
        XCTAssertTrue(fixture.service.isSupported)
        XCTAssertEqual(fixture.service.worktrees.count, 2)
    }

    private func startFacade(_ fixture: WorktreeMutationFixture.Service, snapshot: Data) async throws {
        let requested = fixture.tasks.expect(discoveryArguments)
        let published = expectation(description: "real Git facade snapshot published")
        let observation = fixture.service.observe(\.worktrees) { _, _ in published.fulfill() }
        defer { observation.invalidate() }
        fixture.service.start()
        try fixture.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
        await fulfillment(of: [requested], timeout: 5)
        try fixture.tasks.task(discoveryArguments).finish(snapshot)
        await fulfillment(of: [published], timeout: 5)
        XCTAssertTrue(fixture.service.isSupported)
        XCTAssertFalse(fixture.service.worktrees.isEmpty)
    }

    /// Calling the completion selectors synchronously preserves immediate FIFO admission;
    /// their imported async alternatives would suspend before the assertions can observe it.
    private func enqueueLock(_ service: PBRepositoryWorktreeService, path: String = "/linked", reason: String, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        service.lockWorktree(path: path, reason: reason) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }

    private func enqueueUnlock(_ service: PBRepositoryWorktreeService, path: String = "/linked", completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        service.unlockWorktree(path: path) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }

    private func enqueueCommand(_ command: WorktreeCommand, service: PBRepositoryWorktreeService, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        switch command {
        case let .lock(path, reason): enqueueLock(service, path: path, reason: reason, completion: completion)
        case let .unlock(path): enqueueUnlock(service, path: path, completion: completion)
        case let .remove(path, force): enqueueRemoval(service, path: path, force: force, completion: completion)
        case let .addExisting(path, branch), let .addNew(path, branch):
            let createsBranch: Bool
            if case .addNew = command {
                createsBranch = true
            } else {
                createsBranch = false
            }
            service.addWorktree(path: path, branch: branch, createBranch: createsBranch) { output, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { completion(output, error as NSError?) }
            }
        default:
            XCTFail("This fixture only enqueues ordinary worktree mutations")
            completion(nil, NSError(domain: "WorktreeFixtureUnsupportedCommand", code: 1))
        }
    }

    private func enqueueRemoval(_ service: PBRepositoryWorktreeService, path: String, force: Bool = false, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        service.removeWorktree(path: path, force: force) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }
}

@MainActor
final class WorktreeRepairSafetyTests: XCTestCase {
    @MainActor
    private final class PruneOwnerState { var isCurrent = true }

    #if DEBUG
        func testReappearedCheckoutRecoversThroughFreshDiscoveryWithoutReplayingRepair() async throws {
            try await assertOwnershipRecovery(.reappearedCheckout)
        }
    #endif

    #if DEBUG
        func testOwnershipCaptureFailurePreservesItsCauseAndRecoversOnTheNextReview() async throws {
            try await assertOwnershipRecovery(.failedCapture)
        }
    #endif

    private enum OwnershipRecoveryScenario { case reappearedCheckout, failedCapture }

    #if DEBUG
        private func assertOwnershipRecovery(_ scenario: OwnershipRecoveryScenario) async throws {
            let fixture = try RepairFixture(label: "ownership-recovery")
            defer { fixture.cleanup() }
            let held = fixture.root.appendingPathComponent("disconnected-checkout")
            let trap = fixture.main.appendingPathComponent(".git/worktrees/unsupported-entry")
            if scenario == .reappearedCheckout {
                try FileManager.default.moveItem(at: fixture.linked, to: held)
            } else {
                let target = fixture.root.appendingPathComponent("opaque-sidecar")
                try Data("opaque\n".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: trap, withDestinationURL: target)
            }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            var repairs = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(),
                                      launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                                          if arguments.starts(with: ["worktree", "repair"]) {
                                              repairs += 1
                                          }
                                          return nil
                                      })
            defer { service.acceptedDiscoveryObserver = nil; service.cancel() }
            try await ready(service)
            XCTAssertEqual(service.worktrees.count, 2, "Valid rows must survive failure to capture repair evidence")
            if scenario == .reappearedCheckout {
                try FileManager.default.moveItem(at: held, to: fixture.linked)
            } else {
                try FileManager.default.removeItem(at: trap)
            }
            let metadata = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let fresh = WorktreeObservationCounter()
            service.acceptedDiscoveryObserver = { fresh.advance() }
            let rejected = await prepareRepairPreview(service)
            let error = try XCTUnwrap(rejected.error)
            XCTAssertNil(rejected.preview)
            XCTAssertEqual(repairs, 0)
            if scenario == .failedCapture {
                let cause = try XCTUnwrap(error.userInfo[NSUnderlyingErrorKey] as? NSError)
                XCTAssertTrue(cause.localizedDescription.contains("not a regular file or directory"), "The original capture failure must remain actionable: \(error)")
                XCTAssertTrue(cause.localizedDescription.contains("unsupported-entry"))
            }
            await fulfillment(of: [fresh.expectation(atLeast: 1)], timeout: 15)
            service.acceptedDiscoveryObserver = nil
            XCTAssertEqual(try self.metadata(in: fixture), metadata)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(repairs, 0, "Recovery must only read; a new request supplies fresh authority")
            let retry = await prepareRepairPreview(service)
            XCTAssertNil(retry.error)
            let preview = try XCTUnwrap(retry.preview)
            XCTAssertFalse(preview.requiresReclaim)
            let repaired = await confirmRepairPreview(service, preview: preview)
            XCTAssertNil(repaired.error)
            XCTAssertNil(repaired.preview)
            XCTAssertEqual(repairs, 1)
            XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).isEmpty)
        }
    #endif

    func testRepairPreviewRequiresExplicitWholePlanReclaimAndPreservesIndependentGitState() async throws {
        for damage in ["missing", "empty", "malformed", "unresolved"] {
            let fixture = try RepairFixture(label: "explicit-reclaim-" + damage)
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            var repairCommands = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments.contains("repair") {
                    repairCommands += 1
                }
                return nil
            })
            defer { service.cancel() }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let metadata = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            let link = fixture.linked.appendingPathComponent(".git")
            switch damage {
            case "missing": try FileManager.default.removeItem(at: link)
            case "empty": try Data().write(to: link)
            case "malformed": try Data("not a gitfile\n".utf8).write(to: link)
            default: try Data(("gitdir: " + fixture.root.appendingPathComponent("missing-administrator").path + "\n").utf8).write(to: link)
            }
            let damaged = FileManager.default.fileExists(atPath: link.path) ? try Data(contentsOf: link) : nil
            let legacy = expectation(description: "legacy wrapper cannot authorize reclaim")
            enqueue { service.repair(worktree: tree, movedTo: fixture.linked.path) { error in XCTAssertNotNil(error); legacy.fulfill() } }
            await fulfillment(of: [legacy], timeout: 10)
            XCTAssertEqual(repairCommands, 0)
            let captured = await prepareRepairPreview(service, worktree: tree, path: fixture.linked.path)
            XCTAssertNil(captured.error)
            let preview = try XCTUnwrap(captured.preview)
            XCTAssertTrue(preview.requiresReclaim)
            XCTAssertEqual(preview.reclaimPaths, [WorktreePaths.canonical(fixture.linked.path)])
            XCTAssertEqual(Set(preview.paths), Set(preview.reclaimPaths))
            XCTAssertEqual(FileManager.default.fileExists(atPath: link.path) ? try Data(contentsOf: link) : nil, damaged)
            XCTAssertEqual(try self.metadata(in: fixture), metadata)
            XCTAssertEqual(repairCommands, 0)
            let confirmed = await confirmRepairPreview(service, preview: preview)
            XCTAssertNil(confirmed.error)
            XCTAssertNil(confirmed.preview)
            XCTAssertEqual(repairCommands, 1)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try self.metadata(in: fixture), metadata)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
            let gitDirectory = try fixture.git(["rev-parse", "--absolute-git-dir"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(gitDirectory, WorktreePaths.canonical(fixture.main.appendingPathComponent(".git/worktrees/linked").path))
            XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).isEmpty)
            let replayed = await confirmRepairPreview(service, preview: preview)
            XCTAssertNotNil(replayed.error)
            XCTAssertNil(replayed.preview)
            XCTAssertEqual(repairCommands, 1)
        }
    }

    func testRepairPreviewsAreServiceBoundSingleUseAndDiscardable() async throws {
        let fixture = try RepairFixture(label: "repair-token")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        var repairs = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: {
            arguments in if arguments.contains("repair") {
                repairs += 1
            }; return nil
        })
        let other = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer { service.cancel(); other.cancel() }
        try await ready(service); try await ready(other)
        let metadata = try metadata(in: fixture)
        let captured = await prepareRepairPreview(service)
        XCTAssertNil(captured.error)
        let preview = try XCTUnwrap(captured.preview)
        XCTAssertFalse(preview.requiresReclaim)
        let crossService = await confirmRepairPreview(other, preview: preview)
        XCTAssertNotNil(crossService.error)
        XCTAssertNil(crossService.preview)
        service.discardRepairPreview(preview)
        service.discardRepairPreview(preview)
        let discarded = await confirmRepairPreview(service, preview: preview)
        XCTAssertNotNil(discarded.error)
        XCTAssertEqual(repairs, 0)
        XCTAssertEqual(try self.metadata(in: fixture), metadata)
        let fresh = await prepareRepairPreview(service, relative: true)
        XCTAssertNil(fresh.error)
        let freshPreview = try XCTUnwrap(fresh.preview)
        let done = await confirmRepairPreview(service, preview: freshPreview)
        XCTAssertNil(done.error)
        XCTAssertNil(done.preview)
        XCTAssertEqual(repairs, 1)
        let replay = await confirmRepairPreview(service, preview: freshPreview)
        XCTAssertNotNil(replay.error)
        XCTAssertEqual(repairs, 1)
        XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).isEmpty)
    }

    func testRepairPreviewRenewsLockEvidenceButRejectsReusedAdministrativeNames() async throws {
        for replacement in [false, true] {
            let fixture = try RepairFixture(label: "repair-renewal")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            var repairs = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: {
                arguments in if arguments.contains("repair") {
                    repairs += 1
                }; return nil
            })
            defer { service.cancel() }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let captured = await prepareRepairPreview(service, worktree: tree, path: fixture.linked.path)
            XCTAssertNil(captured.error)
            let preview = try XCTUnwrap(captured.preview)
            let admin = fixture.main.appendingPathComponent(".git/worktrees/linked")
            if replacement {
                let archive = fixture.root.appendingPathComponent("old-admin")
                try FileManager.default.moveItem(at: admin, to: archive)
                try FileManager.default.copyItem(at: archive, to: admin)
            } else {
                _ = try fixture.git(["worktree", "lock", "--reason", "external lock", fixture.linked.path])
            }
            let metadata = try metadata(in: fixture)
            let link = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let refs = try fixture.git(["show-ref", "--head"])
            let current = await confirmRepairPreview(service, preview: preview)
            XCTAssertEqual(repairs, 0)
            XCTAssertEqual(try self.metadata(in: fixture), metadata)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), link)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            if replacement {
                XCTAssertNotNil(current.error)
                XCTAssertNil(current.preview)
            } else {
                XCTAssertNil(current.error)
                let renewed = try XCTUnwrap(current.preview)
                XCTAssertFalse(renewed === preview)
                let replay = await confirmRepairPreview(service, preview: preview)
                XCTAssertNotNil(replay.error)
                XCTAssertEqual(repairs, 0)
                let approved = await confirmRepairPreview(service, preview: renewed)
                XCTAssertNil(approved.error)
                XCTAssertNil(approved.preview)
                XCTAssertEqual(repairs, 1)
                XCTAssertEqual(try self.metadata(in: fixture), metadata)
            }
            let progressed = expectation(description: "renewal or rejection releases FIFO")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in progressed.fulfill() } }
            await fulfillment(of: [progressed], timeout: 10)
        }
    }

    func testSamePathExecutableUpgradeRechecksCapabilityButCannotReviveOldPruneConsent() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer { defaults.set(previous, forKey: "gitExecutable"); NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults) }
        for change in ["inplace", "atomic", "alias"] {
            let fixture = try RepairFixture(label: "same-path-git-upgrade")
            defer { fixture.cleanup() }
            let executable = fixture.root.appendingPathComponent("selected-git")
            let firstBinary = change == "alias" ? fixture.root.appendingPathComponent("git-before-upgrade") : executable
            try writeVersionedGitProxy(firstBinary, version: "2.50.1", atomic: true)
            if change == "alias" {
                try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: firstBinary)
            }
            defaults.set(executable.path, forKey: "gitExecutable")
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            var versions = 0
            var prunes = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments == ["--version"] {
                    versions += 1; return PBTask(launchPath: executable.path, arguments: arguments, inDirectory: nil)
                }
                if arguments == ["worktree", "prune"] {
                    prunes += 1
                }
                return nil
            })
            defer { service.cancel() }
            try await ready(service)
            XCTAssertEqual(service.gitVersion, "git version 2.50.1")
            try FileManager.default.removeItem(at: fixture.linked)
            let initial = try await service.preparePrunePreview()
            let preview = try XCTUnwrap(initial)
            let metadata = try metadata(in: fixture)
            let before = try WorktreeFileFingerprint.capture(path: executable.path)
            if change == "alias" {
                let upgraded = fixture.root.appendingPathComponent("git-after-upgrade")
                try writeVersionedGitProxy(upgraded, version: "2.50.2", atomic: true)
                try FileManager.default.removeItem(at: executable)
                try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: upgraded)
            } else {
                try writeVersionedGitProxy(executable, version: "2.50.2", atomic: change == "atomic")
            }
            let after = try WorktreeFileFingerprint.capture(path: executable.path)
            XCTAssertNotEqual(before, after)
            XCTAssertEqual(before.identity == after.identity, change == "inplace")
            let rechecked = expectation(description: "same-path changed executable automatically reprobed")
            let observation = service.observe(\.gitVersion) { observed, _ in
                // swift6-safety-justification: Capability observations are delivered on the service’s main queue.
                MainActor.assumeIsolated {
                    if observed.gitVersion == "git version 2.50.2" {
                        rechecked.fulfill()
                    }
                }
            }
            service.refresh()
            await fulfillment(of: [rechecked], timeout: 10)
            observation.invalidate()
            XCTAssertEqual(versions, 2)
            XCTAssertTrue(service.isSupported)
            let oldConsent = await confirmationError(service, preview: preview)
            XCTAssertNotNil(oldConsent)
            XCTAssertEqual(prunes, 0)
            XCTAssertEqual(try self.metadata(in: fixture), metadata)
            let refreshed = try await service.preparePrunePreview()
            let fresh = try XCTUnwrap(refreshed)
            XCTAssertEqual(fresh.report, preview.report)
            let confirmed = await confirmationError(service, preview: fresh)
            XCTAssertNil(confirmed)
            XCTAssertEqual(prunes, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
        }
    }

    func testRepairWithoutAcceptedOwnershipSeedsRequiresRefreshAndLeavesFIFOAvailable() async throws {
        let fixture = try RepairFixture(label: "missing-ownership-seeds")
        defer { fixture.cleanup() }
        let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
        let heldDiscovery = ControlledWorktreeTask()
        let discoveryStarted = expectation(description: "initial discovery is held before any seeds are accepted")
        var repairCommands = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if arguments == ["worktree", "list", "--porcelain", "-z"] {
                discoveryStarted.fulfill(); return heldDiscovery
            }
            if arguments.starts(with: ["worktree", "repair"]) {
                repairCommands += 1
            }
            return nil
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer {
            service.cancel(); following.cancel()
            heldDiscovery.finish(nil, error: CancellationError())
        }
        try await ready(following)
        service.start()
        await fulfillment(of: [discoveryStarted], timeout: 10)
        XCTAssertTrue(service.isSupported)
        XCTAssertTrue(service.worktrees.isEmpty)
        let before = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let rejected = expectation(description: "repair requires an accepted ownership discovery")
        let result = WriterCharacterizationResult()
        enqueue { service.repairLinks(relativePaths: false) { error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { result.error = error as NSError?; rejected.fulfill() }
        } }
        await fulfillment(of: [rejected], timeout: 5)
        let error = try XCTUnwrap(result.error)
        let message = error.localizedDescription + " " + (error.localizedFailureReason ?? "")
        XCTAssertTrue(message.contains("Refresh"), message)
        XCTAssertEqual(repairCommands, 0)
        let progressed = expectation(description: "following real writer uses the same common FIFO")
        enqueue { following.lockWorktree(path: fixture.linked.path, reason: "after missing seeds") { _, error in
            XCTAssertNil(error); progressed.fulfill()
        } }
        await fulfillment(of: [progressed], timeout: 10)
        XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "after missing seeds")
        XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
    }

    #if DEBUG
        func testAcceptedEqualDiscoveryRefreshesOwnershipSeedsForANewRepair() async throws {
            let fixture = try RepairFixture(label: "equal-discovery-fresh-seeds")
            defer { fixture.cleanup() }
            let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
            var repairCommands = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments.starts(with: ["worktree", "repair"]) {
                    repairCommands += 1
                }
                return nil
            })
            defer { service.cancel() }
            try await ready(service)
            let initial = service.worktrees
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            try replaceAdministrativeRegistration(in: fixture)
            XCTAssertEqual(try metadata(in: fixture), before)
            var publications = 0
            let observation = service.observe(\.worktrees) { _, _ in
                // swift6-safety-justification: The service publishes worktree values on its main actor.
                MainActor.assumeIsolated { publications += 1 }
            }
            defer { observation.invalidate() }
            let accepted = expectation(description: "equal discovery still accepts refreshed ownership seeds")
            service.acceptedDiscoveryObserver = { accepted.fulfill() }
            service.refresh()
            await fulfillment(of: [accepted], timeout: 10)
            service.acceptedDiscoveryObserver = nil
            XCTAssertEqual(service.worktrees, initial)
            XCTAssertEqual(publications, 0)
            let completed = expectation(description: "new repair uses the newly accepted administrative identity")
            let selected = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            enqueue { service.repair(worktree: selected, movedTo: selected.path) { error in
                XCTAssertNil(error); completed.fulfill()
            } }
            await fulfillment(of: [completed], timeout: 10)
            XCTAssertEqual(repairCommands, 1)
            XCTAssertEqual(try metadata(in: fixture), before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        }
    #endif

    @MainActor
    private final class RepairOperationCleanupState {
        var repairRequests = 0
        var followingRequested = false
        var successfulCompletionRequired = false
        var completedSuccessfully = false
    }

    #if DEBUG
        func testQueuedRepairRetainsItsSeedsWhileAcceptedEqualDiscoveryUpdatesTheCache() async throws {
            let fixture = try RepairFixture(label: "queued-request-retains-seeds")
            var cleanupRegistered = false
            defer {
                if !cleanupRegistered {
                    fixture.cleanup()
                }
            }
            let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
            let barrier = ControlledWorktreeTask()
            let writerStarted = expectation(description: "earlier writer owns the FIFO before the old request")
            let blocker = makeService(repository: repository, fixture: fixture, blocked: barrier, launched: writerStarted)
            let checkpoint = WorktreeWorkerCheckpoint()
            let starts = WorktreeObservationCounter()
            var repairCommands = 0
            var discoveryRequests = 0
            let cleanup = RepairOperationCleanupState()
            let repairResults = WorktreeObservationCounter()
            let followingResults = WorktreeObservationCounter()
            let service = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
                if arguments == ["worktree", "list", "--porcelain", "-z"] {
                    discoveryRequests += 1
                }
                if arguments.starts(with: ["worktree", "repair"]) {
                    repairCommands += 1
                }
                let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
                GitXTestGitFixture.prepare(task)
                return task
            }, repairPreparationObserver: {
                if starts.advance() == 1 {
                    checkpoint.wait()
                }
            })
            service.repairPreparationResultObserver = { checkpoint.finish() }
            let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
            addTeardownBlock { @MainActor in
                blocker.cancel(); service.cancel(); following.cancel()
                barrier.finish(nil, error: CancellationError())
                checkpoint.resume()
                if checkpoint.expectsResult {
                    await self.fulfillment(of: [checkpoint.finishedExpectation()], timeout: 10)
                }
                if cleanup.repairRequests > 0 {
                    await self.fulfillment(of: [repairResults.expectation(atLeast: cleanup.repairRequests)], timeout: 10)
                }
                if cleanup.followingRequested {
                    await self.fulfillment(of: [followingResults.expectation(atLeast: 1)], timeout: 10)
                }
                let workerDrained = !checkpoint.expectsResult || (checkpoint.deliveryCount > 0 && !checkpoint.isWaiting)
                guard workerDrained, repairResults.value == cleanup.repairRequests,
                      !cleanup.followingRequested || followingResults.value == 1,
                      !cleanup.successfulCompletionRequired || cleanup.completedSuccessfully
                else {
                    XCTFail("Seed-cache teardown could not observe terminal drainage; preserving fixture at " + fixture.root.path)
                    return
                }
                service.repairPreparationResultObserver = nil
                service.acceptedDiscoveryObserver = nil
                fixture.cleanup()
            }
            cleanupRegistered = true
            try await ready(blocker); try await ready(service); try await ready(following)
            let selected = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let initial = service.worktrees
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            let completed = WriterCharacterizationResult()
            let blockerDone = expectation(description: "earlier no-op writer finishes")
            enqueue { blocker.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in
                XCTAssertNil(error); blockerDone.fulfill()
            } }
            await fulfillment(of: [writerStarted], timeout: 5)
            let rejected = expectation(description: "old queued request refuses a replaced registration despite the newer cache")
            checkpoint.expectResult()
            cleanup.repairRequests += 1
            enqueue { service.repair(worktree: selected, movedTo: selected.path) { error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated {
                    defer { repairResults.advance() }
                    completed.error = error as NSError?; completed.names.append("old"); rejected.fulfill()
                }
            } }
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            try replaceAdministrativeRegistration(in: fixture)
            let accepted = expectation(description: "new equal discovery updates only future request seeds")
            service.acceptedDiscoveryObserver = { accepted.fulfill() }
            service.refresh()
            await fulfillment(of: [accepted], timeout: 10)
            service.acceptedDiscoveryObserver = nil
            XCTAssertEqual(service.worktrees, initial)
            let acceptedDiscoveryCount = discoveryRequests
            XCTAssertTrue(checkpoint.isWaiting)
            let progressed = expectation(description: "following real writer advances after old request rejection")
            cleanup.followingRequested = true
            enqueue { following.lockWorktree(path: fixture.linked.path, reason: "after retained seeds") { _, error in
                defer { followingResults.advance() }
                XCTAssertNil(error); progressed.fulfill()
            } }
            checkpoint.resume()
            await fulfillment(of: [checkpoint.finishedExpectation()], timeout: 10)
            XCTAssertEqual(checkpoint.deliveryCount, 1)
            XCTAssertFalse(checkpoint.didTimeout)
            XCTAssertNil(completed.error)
            XCTAssertEqual(repairCommands, 0)
            barrier.finish(Data())
            await fulfillment(of: [blockerDone, rejected, progressed], timeout: 15)
            XCTAssertNotNil(completed.error)
            XCTAssertEqual(completed.names, ["old"])
            XCTAssertEqual(repairCommands, 0)
            let oldRequestDrained = expectation(description: "obsolete recovery origin and all queued callbacks drain")
            enqueue { service.drainForTesting { oldRequestDrained.fulfill() } }
            await fulfillment(of: [oldRequestDrained], timeout: 10)
            XCTAssertEqual(discoveryRequests, acceptedDiscoveryCount, "An obsolete failure cannot invalidate newer accepted ownership evidence or schedule another recovery read")
            service.repairPreparationResultObserver = nil
            let freshDone = expectation(description: "fresh request uses accepted replacement seeds and really repairs")
            let fresh = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            cleanup.repairRequests += 1
            cleanup.successfulCompletionRequired = true
            enqueue { service.repair(worktree: fresh, movedTo: fresh.path) { error in
                defer { repairResults.advance() }
                cleanup.completedSuccessfully = error == nil
                XCTAssertNil(error); freshDone.fulfill()
            } }
            await fulfillment(of: [freshDone], timeout: 10)
            XCTAssertEqual(starts.value, 2)
            XCTAssertEqual(repairCommands, 1)
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        }
    #endif

    private func replaceAdministrativeRegistration(in fixture: RepairFixture) throws {
        let original = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let copied = fixture.root.appendingPathComponent("replacement-administrative-registration")
        let before = try WorktreeFileIdentity.capture(path: original.path)
        // Copy while the original exists: inode reuse cannot make these the same object.
        try FileManager.default.copyItem(at: original, to: copied)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: copied, to: original)
        XCTAssertNotEqual(try WorktreeFileIdentity.capture(path: original.path), before)
    }

    func testCompletedRepairAllowsSameStrayObjectContentChangesAndReconcilesBeforeFollowingWriter() async throws {
        let fixture = try RepairFixture(label: "repair-postwrite-stray-content")
        defer { fixture.cleanup() }
        let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
        let stray = fixture.main.appendingPathComponent(".git/worktrees/.DS_Store")
        let originalStray = Data("before".utf8)
        let changedStray = Data("same object, different byte length after Git completed repair\n".utf8)
        try originalStray.write(to: stray)
        let strayIdentity = try WorktreeFileIdentity.capture(path: stray.path)
        let writer = ControlledWorktreeTask()
        let launched = expectation(description: "approved repair writer admitted")
        var repairArguments: [String]?
        var repairCommands = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if arguments.starts(with: ["worktree", "repair"]) {
                repairArguments = arguments; repairCommands += 1
                launched.fulfill(); return writer
            }
            return nil
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer {
            service.cancel(); following.cancel()
            writer.finish(nil, error: CancellationError())
        }
        try await ready(service); try await ready(following)
        let previewResult = await prepareRepairPreview(service)
        XCTAssertNil(previewResult.error)
        let preview = try XCTUnwrap(previewResult.preview)
        XCTAssertFalse(preview.requiresReclaim)
        let before = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let mainHEAD = try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD"))
        let mainIndex = try Data(contentsOf: fixture.main.appendingPathComponent(".git/index"))
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let mainContent = try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt"))
        let linkedContent = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let completed = expectation(description: "completed real repair reconciles despite incidental stray content changes")
        let progressed = expectation(description: "following writer progresses after successful reconciliation")
        let order = WriterCharacterizationResult()
        enqueue { service.repair(confirmedPreview: preview) { updated, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated {
                XCTAssertNil(updated); order.error = error as NSError?
                order.names.append("repair"); completed.fulfill()
            }
        } }
        await fulfillment(of: [launched], timeout: 10)
        enqueue { following.lockWorktree(path: fixture.linked.path, reason: "after repaired stray") { _, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { XCTAssertNil(error); order.names.append("following"); progressed.fulfill() }
        } }
        XCTAssertTrue(order.names.isEmpty)
        let command = try XCTUnwrap(repairArguments)
        XCTAssertEqual(repairCommands, 1)
        // The fake controls only terminal delivery. Execute its captured command
        // exactly once with real Git before reporting success to the service.
        _ = try fixture.git(command)
        try changedStray.write(to: stray)
        XCTAssertNotEqual(changedStray.count, originalStray.count)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: stray.path), strayIdentity)
        writer.finish(Data())
        await fulfillment(of: [completed, progressed], timeout: 15)
        XCTAssertNil(order.error)
        XCTAssertEqual(order.names, ["repair", "following"])
        XCTAssertEqual(repairCommands, 1)
        XCTAssertEqual(try Data(contentsOf: stray), changedStray)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: stray.path), strayIdentity)
        let administrative = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let forward = try String(contentsOf: fixture.linked.appendingPathComponent(".git"), encoding: .utf8).trimmingCharacters(in: .newlines)
        XCTAssertTrue(forward.hasPrefix("gitdir: "))
        XCTAssertEqual(WorktreePaths.identity(String(forward.dropFirst("gitdir: ".count))), WorktreePaths.identity(administrative.path))
        let backlink = try String(contentsOf: administrative.appendingPathComponent("gitdir"), encoding: .utf8).trimmingCharacters(in: .newlines)
        XCTAssertEqual(WorktreePaths.identity(backlink), WorktreePaths.identity(fixture.linked.appendingPathComponent(".git").path))
        XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD")), mainHEAD)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt")), mainContent)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), linkedContent)
    }

    #if DEBUG
        func testInitialQueuedRepairRecapturesAnAddedUnrelatedSiblingBeforeWriting() async throws {
            try await assertInitialQueuedRepairRecapturesSibling(adding: true)
        }
    #endif

    #if DEBUG
        func testInitialQueuedRepairRecapturesARemovedUnrelatedSiblingBeforeWriting() async throws {
            try await assertInitialQueuedRepairRecapturesSibling(adding: false)
        }
    #endif

    #if DEBUG
        private func assertInitialQueuedRepairRecapturesSibling(adding: Bool) async throws {
            let fixture = try RepairFixture(label: adding ? "initial-added-sibling" : "initial-removed-sibling")
            var cleanupRegistered = false
            defer {
                if !cleanupRegistered {
                    fixture.cleanup()
                }
            }
            let sibling = fixture.root.appendingPathComponent("unrelated-sibling")
            if !adding {
                _ = try fixture.git(["worktree", "add", "-b", "unrelated-sibling", sibling.path])
            }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let barrier = ControlledWorktreeTask()
            let writerStarted = expectation(description: "earlier controlled writer owns the common FIFO")
            let blocker = makeService(repository: repository, fixture: fixture, blocked: barrier, launched: writerStarted)
            let checkpoint = WorktreeWorkerCheckpoint(timeout: 60)
            var repairCommands: [[String]] = []
            let service = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
                if arguments.starts(with: ["worktree", "repair"]) {
                    repairCommands.append(arguments)
                }
                let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
                GitXTestGitFixture.prepare(task)
                return task
            }, repairPreparationObserver: {
                checkpoint.wait()
            })
            service.repairPreparationResultObserver = { checkpoint.finish() }
            let followingArguments = ["worktree", "lock", "--reason", "after sibling recapture", fixture.linked.path]
            var followingCommands = 0
            let cleanup = RepairOperationCleanupState()
            let followingResults = WorktreeObservationCounter()
            let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments == followingArguments {
                    followingCommands += 1
                }
                return nil
            })
            addTeardownBlock { @MainActor in
                blocker.cancel(); service.cancel(); following.cancel()
                barrier.finish(nil, error: CancellationError())
                checkpoint.resume()
                if checkpoint.expectsResult {
                    await self.fulfillment(of: [checkpoint.finishedExpectation()], timeout: 10)
                }
                if cleanup.followingRequested {
                    await self.fulfillment(of: [followingResults.expectation(atLeast: 1)], timeout: 10)
                }
                let workerDrained = !checkpoint.expectsResult || (checkpoint.deliveryCount > 0 && !checkpoint.isWaiting)
                let followingDrained = !cleanup.followingRequested || followingResults.value == 1
                guard workerDrained, followingDrained,
                      !cleanup.successfulCompletionRequired || cleanup.completedSuccessfully
                else {
                    XCTFail("Sibling recapture teardown could not observe terminal drainage; preserving fixture at " + fixture.root.path)
                    return
                }
                service.repairPreparationResultObserver = nil
                fixture.cleanup()
            }
            cleanupRegistered = true
            let initialCount = adding ? 2 : 3
            try await ready(blocker, expectedWorktreeCount: initialCount)
            try await ready(service, expectedWorktreeCount: initialCount)
            try await ready(following, expectedWorktreeCount: initialCount)
            let selected = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let completions = WriterCharacterizationResult()
            let blockerDone = expectation(description: "earlier controlled writer completes")
            let repairDone = expectation(description: "chosen repair recaptures the admitted inventory and completes")
            let followingDone = expectation(description: "following real writer completes after repair")
            enqueue {
                blocker.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in
                    // swift6-safety-justification: The service delivers lifecycle completions on the main queue.
                    MainActor.assumeIsolated {
                        XCTAssertNil(error)
                        completions.names.append("blocker")
                        blockerDone.fulfill()
                    }
                }
            }
            await fulfillment(of: [writerStarted], timeout: 5)
            checkpoint.expectResult()
            cleanup.successfulCompletionRequired = true
            enqueue {
                service.repair(worktree: selected, movedTo: fixture.linked.path) { error in
                    // swift6-safety-justification: The service delivers lifecycle completions on the main queue.
                    MainActor.assumeIsolated {
                        completions.error = error as NSError?
                        cleanup.completedSuccessfully = error == nil
                        completions.names.append("repair")
                        repairDone.fulfill()
                    }
                }
            }
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            if adding {
                _ = try fixture.git(["worktree", "add", "-b", "unrelated-sibling", sibling.path])
            } else {
                _ = try fixture.git(["worktree", "remove", sibling.path])
            }
            XCTAssertEqual(FileManager.default.fileExists(atPath: sibling.path), adding)
            let listing = try fixture.git(["worktree", "list", "--porcelain"])
            XCTAssertEqual(listing.contains("worktree " + WorktreePaths.canonical(sibling.path) + "\n"), adding)
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            cleanup.followingRequested = true
            enqueue {
                following.lockWorktree(path: fixture.linked.path, reason: "after sibling recapture") { _, error in
                    // swift6-safety-justification: The service delivers lifecycle completions on the main queue.
                    MainActor.assumeIsolated {
                        defer { followingResults.advance() }
                        XCTAssertNil(error)
                        completions.names.append("following")
                        followingDone.fulfill()
                    }
                }
            }
            XCTAssertTrue(completions.names.isEmpty)
            XCTAssertTrue(repairCommands.isEmpty)
            XCTAssertEqual(followingCommands, 0)
            checkpoint.resume()
            // This task is an intentional no-op FIFO barrier; the chosen repair and
            // following lock use real Git, so their output and filesystem proof are independent.
            barrier.finish(Data())
            await fulfillment(of: [blockerDone, repairDone, followingDone], timeout: 20)
            await fulfillment(of: [checkpoint.finishedExpectation()], timeout: 10)
            XCTAssertFalse(checkpoint.didTimeout)
            XCTAssertTrue(checkpoint.wasReleased)
            XCTAssertFalse(checkpoint.isWaiting)
            XCTAssertEqual(checkpoint.deliveryCount, 1)
            XCTAssertNil(completions.error)
            XCTAssertEqual(completions.names, ["blocker", "repair", "following"])
            XCTAssertEqual(repairCommands.count, 1)
            XCTAssertEqual(followingCommands, 1)
            XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "after sibling recapture")
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before.filter { !$0.key.hasSuffix("/locked") })
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        }
    #endif

    #if DEBUG
        @MainActor
        private final class HeldRepairPreparationFixture {
            @MainActor
            private final class CommandCounts {
                var repair = 0
                var following = 0
            }

            let fixture: RepairFixture
            let repository: RepositoryTestGitRepository
            let checkpoint: WorktreeWorkerCheckpoint
            let service: PBRepositoryWorktreeService
            let following: PBRepositoryWorktreeService
            private let counts: CommandCounts
            let followingResults = WorktreeObservationCounter()
            let cleanup = RepairOperationCleanupState()
            private(set) var followingRequested = false

            var repairCommands: Int {
                counts.repair
            }

            var followingCommands: Int {
                counts.following
            }

            func lockFollowing(reason: String, completion: @escaping @MainActor (Error?) -> Void) {
                XCTAssertFalse(followingRequested)
                followingRequested = true
                following.lockWorktree(path: fixture.linked.path, reason: reason) { _, error in
                    // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                    MainActor.assumeIsolated {
                        defer { self.followingResults.advance() }
                        completion(error)
                    }
                }
            }

            init(label: String) throws {
                let created = try RepairFixture(label: label)
                fixture = created
                let checkpoint = WorktreeWorkerCheckpoint()
                self.checkpoint = checkpoint
                let counts = CommandCounts()
                self.counts = counts
                do {
                    let repository = try RepositoryTestGitRepository(url: created.main)
                    self.repository = repository
                    func task(_ arguments: [String]) -> PBTask {
                        let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + created.main.appendingPathComponent(".git").path] + arguments, inDirectory: created.main.path)
                        GitXTestGitFixture.prepare(task)
                        return task
                    }
                    let service = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
                        if arguments.starts(with: ["worktree", "repair"]) {
                            counts.repair += 1
                        }
                        return task(arguments)
                    }, repairPreparationObserver: { checkpoint.wait() })
                    self.service = service
                    service.repairPreparationResultObserver = { checkpoint.finish() }
                    following = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
                        if arguments.starts(with: ["worktree", "lock"]) {
                            counts.following += 1
                        }
                        return task(arguments)
                    })
                } catch {
                    created.cleanup()
                    throw error
                }
            }
        }
    #endif

    #if DEBUG
        private func heldRepairPreparationFixture(label: String) async throws -> HeldRepairPreparationFixture {
            let held = try HeldRepairPreparationFixture(label: label)
            // Register before readiness or any test assertions can fail. The shared
            // async teardown owns release, true result drainage, and final deletion.
            addTeardownBlock { @MainActor in
                held.service.cancel(); held.following.cancel()
                held.checkpoint.resume()
                if held.checkpoint.expectsResult {
                    await self.fulfillment(of: [held.checkpoint.finishedExpectation()], timeout: 10)
                }
                if held.followingRequested {
                    await self.fulfillment(of: [held.followingResults.expectation(atLeast: 1)], timeout: 10)
                }
                let workerDrained = !held.checkpoint.expectsResult || (held.checkpoint.deliveryCount > 0 && !held.checkpoint.isWaiting)
                let followingDrained = !held.followingRequested || held.followingResults.value == 1
                guard workerDrained, followingDrained,
                      !held.cleanup.successfulCompletionRequired || held.cleanup.completedSuccessfully
                else {
                    XCTFail("Held repair teardown could not observe terminal drainage; preserving fixture at " + held.fixture.root.path)
                    return
                }
                held.service.repairPreparationResultObserver = nil
                held.fixture.cleanup()
            }
            try await ready(held.service)
            try await ready(held.following)
            return held
        }
    #endif

    #if DEBUG
        func testRepairPreparationKeepsMainActorResponsiveAndReservesFIFOBeforeUtilityCapture() async throws {
            let held = try await heldRepairPreparationFixture(label: "utility-worker-fifo")
            let checkpoint = held.checkpoint
            let service = held.service
            let following = held.following
            let result = RepairCompletion()
            let prepared = expectation(description: "prepared once after worker resumes")
            prepared.assertForOverFulfill = true
            checkpoint.expectResult()
            held.cleanup.successfulCompletionRequired = true
            enqueue { service.prepareRepairLinks(relativePaths: false) { preview, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue.
                MainActor.assumeIsolated {
                    result.preview = preview; result.error = error as NSError?
                    held.cleanup.completedSuccessfully = preview != nil && error == nil
                    prepared.fulfill()
                }
            } }
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            let mainProgress = expectation(description: "main actor continues while inventory worker is held")
            DispatchQueue.main.async { mainProgress.fulfill() }
            await fulfillment(of: [mainProgress], timeout: 5)
            XCTAssertTrue(checkpoint.isWaiting)
            XCTAssertFalse(checkpoint.wasReleased)
            XCTAssertNil(result.preview)
            XCTAssertEqual(held.repairCommands, 0)
            let followingDone = expectation(description: "following writer runs only after preparation releases its reservation")
            enqueue { held.lockFollowing(reason: "after utility capture") { error in XCTAssertNil(error); followingDone.fulfill() } }
            XCTAssertEqual(held.followingCommands, 0)
            checkpoint.resume()
            await fulfillment(of: [prepared, followingDone], timeout: 10)
            await fulfillment(of: [checkpoint.finishedExpectation()], timeout: 10)
            XCTAssertFalse(checkpoint.didTimeout)
            XCTAssertTrue(checkpoint.wasReleased)
            XCTAssertFalse(checkpoint.isWaiting)
            XCTAssertEqual(checkpoint.deliveryCount, 1)
            XCTAssertNil(result.error)
            try service.discardRepairPreview(XCTUnwrap(result.preview))
            XCTAssertEqual(held.followingCommands, 1)
            XCTAssertEqual(held.repairCommands, 0)
            XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "after utility capture")
        }
    #endif

    #if DEBUG
        func testCancellingAdmittedRepairEvidenceReleasesCompletionAndFIFOBeforeWorkerReturns() async throws {
            let held = try await heldRepairPreparationFixture(label: "cancel-held-evidence")
            let fixture = held.fixture
            let checkpoint = held.checkpoint
            let service = held.service
            let following = held.following
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            let result = RepairCompletion()
            var completions = 0
            var completionOwner: NSObject? = NSObject()
            weak let retainedCompletionOwner = completionOwner
            let cancelled = expectation(description: "held preparation cancels exactly once")
            cancelled.assertForOverFulfill = true
            checkpoint.expectResult()
            enqueue {
                service.prepareRepairLinks(relativePaths: false) { [owner = completionOwner] preview, error in
                    // swift6-safety-justification: The service delivers preview completion on the main queue.
                    MainActor.assumeIsolated {
                        withExtendedLifetime(owner) {}
                        result.preview = preview
                        result.error = error as NSError?
                        completions += 1
                        cancelled.fulfill()
                    }
                }
            }
            completionOwner = nil
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            XCTAssertNotNil(retainedCompletionOwner)
            let progressed = expectation(description: "following real writer finishes while evidence worker remains held")
            progressed.assertForOverFulfill = true
            enqueue {
                held.lockFollowing(reason: "following") { error in
                    XCTAssertNil(error)
                    progressed.fulfill()
                }
            }
            XCTAssertEqual(held.followingCommands, 0)
            service.cancel()
            await fulfillment(of: [cancelled, progressed], timeout: 5)
            XCTAssertEqual(completions, 1)
            XCTAssertNil(result.preview)
            XCTAssertEqual(result.error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(result.error?.code, NSUserCancelledError)
            XCTAssertNil(retainedCompletionOwner, "Cancellation must release the deferred completion before its utility worker returns")
            XCTAssertTrue(checkpoint.isWaiting)
            XCTAssertFalse(checkpoint.wasReleased)
            XCTAssertEqual(service.repairPreparationCount, 0)
            XCTAssertEqual(held.repairCommands, 0)
            XCTAssertEqual(held.followingCommands, 1)
            checkpoint.resume()
            await fulfillment(of: [checkpoint.finishedExpectation()], timeout: 5)
            XCTAssertFalse(checkpoint.didTimeout)
            XCTAssertTrue(checkpoint.wasReleased)
            XCTAssertFalse(checkpoint.isWaiting)
            XCTAssertEqual(checkpoint.deliveryCount, 1)
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(service.repairPreparationCount, 0)
            XCTAssertNil(retainedCompletionOwner)
            XCTAssertEqual(held.repairCommands, 0)
            XCTAssertEqual(held.followingCommands, 1)
            XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        }
    #endif

    func testFailedOldExecutableReconciliationStillRefreshesTheSupportedCurrentGeneration() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let fixture = try RepairFixture(label: "old-executable-reconciliation")
        defer { fixture.cleanup() }
        let originalGit = fixture.root.appendingPathComponent("git-a")
        let currentGit = fixture.root.appendingPathComponent("git-b")
        try writeVersionedGitProxy(originalGit, version: "2.50.1", atomic: true)
        try writeVersionedGitProxy(currentGit, version: "2.50.2", atomic: true)
        defaults.set(originalGit.path, forKey: "gitExecutable")
        let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
        let writer = ControlledWorktreeTask()
        let retiredCurrentRead = ControlledWorktreeTask()
        let refreshedCurrentRead = ControlledWorktreeTask()
        let writerStarted = expectation(description: "Git A writer admitted")
        let currentReadStarted = expectation(description: "Git B capability checked and ordinary read pending")
        let replacementReadStarted = expectation(description: "post-write Git B read replaces the retired snapshot")
        [writerStarted, currentReadStarted, replacementReadStarted].forEach { $0.assertForOverFulfill = true }
        let listArguments = ["worktree", "list", "--porcelain", "-z"]
        let lockArguments = ["worktree", "lock", "--reason", "writer A", fixture.linked.path]
        var currentReads = 0
        var requestedReplacement = false
        var commands: [[String]] = []
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            commands.append(arguments)
            if arguments == ["--version"], let selected = defaults.string(forKey: "gitExecutable") {
                return PBTask(launchPath: selected, arguments: ["--version"], inDirectory: nil)
            }
            if arguments == lockArguments {
                writerStarted.fulfill()
                return writer
            }
            if arguments == listArguments, defaults.string(forKey: "gitExecutable") == currentGit.path {
                currentReads += 1
                if currentReads == 1 {
                    currentReadStarted.fulfill()
                    return retiredCurrentRead
                }
                if currentReads == 2 {
                    requestedReplacement = true
                    replacementReadStarted.fulfill()
                    return refreshedCurrentRead
                }
            }
            return nil
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer {
            service.cancel(); following.cancel()
            writer.finish(nil, error: CancellationError())
            retiredCurrentRead.finish(nil, error: CancellationError())
            refreshedCurrentRead.finish(nil, error: CancellationError())
        }
        try await ready(service)
        XCTAssertEqual(service.gitVersion, "git version 2.50.1")
        let initialListing = try Data(fixture.git(listArguments).utf8)
        let protected = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let result = WriterCharacterizationResult()
        let writerDone = expectation(description: "old writer reports reconciliation failure exactly once")
        writerDone.assertForOverFulfill = true
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "writer A") { _, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated {
                result.error = error as NSError?
                result.names.append("writer")
                writerDone.fulfill()
            }
        } }
        await fulfillment(of: [writerStarted], timeout: 5)
        defaults.set(currentGit.path, forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [currentReadStarted], timeout: 10)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, "git version 2.50.2")
        XCTAssertFalse(writer.wasCancelled)
        try await ready(following)
        let followingDone = expectation(description: "following preview proves shared FIFO released after old-context failure")
        followingDone.assertForOverFulfill = true
        enqueue { following.preparePrunePreview { preview, error in
            // swift6-safety-justification: The service delivers preview completion on the main queue.
            MainActor.assumeIsolated {
                XCTAssertNil(error)
                XCTAssertNotNil(preview)
                if let preview {
                    following.discardPrunePreview(preview)
                }
                result.names.append("following")
                followingDone.fulfill()
            }
        } }
        XCTAssertTrue(result.names.isEmpty)
        try FileManager.default.removeItem(at: originalGit)
        _ = try fixture.git(lockArguments)
        writer.finish(Data())
        await fulfillment(of: [writerDone, replacementReadStarted, followingDone], timeout: 10)
        XCTAssertEqual(result.names, ["writer", "following"])
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.localizedFailureReason?.contains("Git completed") == true)
        XCTAssertTrue(retiredCurrentRead.wasCancelled)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, "git version 2.50.2")
        guard requestedReplacement else { return }
        let published = expectation(description: "fresh Git B snapshot publishes the completed writer's lock")
        published.assertForOverFulfill = true
        let observation = service.observe(\.worktrees) { observed, _ in
            // swift6-safety-justification: The service publishes worktree KVO on the main queue.
            MainActor.assumeIsolated {
                if observed.worktree(forBranch: "refs/heads/topic")?.lockReason == "writer A" {
                    published.fulfill()
                }
            }
        }
        defer { observation.invalidate() }
        try refreshedCurrentRead.finish(Data(fixture.git(listArguments).utf8))
        await fulfillment(of: [published], timeout: 10)
        retiredCurrentRead.finish(initialListing)
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "writer A")
        XCTAssertEqual(commands.filter { $0 == lockArguments }.count, 1)
        XCTAssertGreaterThanOrEqual(currentReads, 2)
        XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, protected)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
    }

    func testDefaultDocumentOwnedWriterAndReconciliationKeepTheOriginalGitAfterPreferencesChange() async throws {
        let fixture = try RepairFixture(label: "default-frozen-git")
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer { defaults.set(previous, forKey: "gitExecutable"); NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults) }
        let gate = fixture.root.appendingPathComponent("writer-gate")
        guard mkfifo(gate.path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let started = fixture.root.appendingPathComponent("writer-started")
        let originalReads = fixture.root.appendingPathComponent("original-git-reads")
        let updatedReads = fixture.root.appendingPathComponent("updated-git-reads")
        let originalGit = fixture.root.appendingPathComponent("original-git")
        let updatedGit = fixture.root.appendingPathComponent("updated-git")
        try writeAdmissionGitProxy(originalGit, gate: gate, started: started, listed: originalReads)
        try writeAdmissionGitProxy(updatedGit, gate: nil, started: nil, listed: updatedReads)
        defaults.set(originalGit.path, forKey: "gitExecutable")
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = repository.worktreeService
        defer { releaseAdmissionGate(gate); service.cancel() }
        let initial = expectation(description: "default document-owned worktrees ready")
        let observation = service.observe(\.worktrees) { _, _ in initial.fulfill() }
        if service.worktrees.count == 2 {
            initial.fulfill()
        } else {
            service.start(); service.refresh()
        }
        await fulfillment(of: [initial], timeout: 10)
        observation.invalidate()
        XCTAssertTrue(service.isSupported)
        let initialReads = try String(contentsOf: originalReads, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }.count
        let protected = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let result = WriterCharacterizationResult()
        let first = expectation(description: "original Git writer reconciles after selected executable changes")
        first.assertForOverFulfill = true
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "default frozen writer") { _, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { result.error = error as NSError?; result.names.append("first"); first.fulfill() }
        } }
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: started.path) }, object: nil)
        await fulfillment(of: [admitted], timeout: 10)
        XCTAssertTrue(result.names.isEmpty)
        let checked = expectation(description: "new selected Git is checked while original writer remains admitted")
        let availability = service.observe(\.isSupported) { observed, _ in
            // swift6-safety-justification: Capability changes are published on the service’s main queue.
            MainActor.assumeIsolated {
                if observed.isSupported {
                    checked.fulfill()
                }
            }
        }
        defaults.set(updatedGit.path, forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [checked], timeout: 10)
        availability.invalidate()
        XCTAssertTrue(result.names.isEmpty)
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer { following.cancel() }
        try await ready(following)
        let next = expectation(description: "following writer uses the released FIFO slot")
        enqueue { following.unlockWorktree(path: fixture.linked.path) { _, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { XCTAssertNil(error); result.names.append("following"); next.fulfill() }
        } }
        XCTAssertTrue(result.names.isEmpty)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.releaseAdmissionGate(gate) }, object: nil)
        await fulfillment(of: [released], timeout: 5)
        await fulfillment(of: [first, next], timeout: 10)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.names, ["first", "following"])
        let finalReads = try String(contentsOf: originalReads, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }.count
        XCTAssertGreaterThan(finalReads, initialReads, "Owned reconciliation must execute the original canonical Git, not the newly selected proxy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updatedReads.path), "Ordinary current-generation discovery may use the newly selected executable")
        XCTAssertEqual(try metadata(in: fixture), protected)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
    }

    private func writeAdmissionGitProxy(_ path: URL, gate: URL?, started: URL?, listed: URL) throws {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var script = "#!/bin/sh\nfor argument in \"$@\"; do\n"
        if let gate, let started {
            script += "  if [ \"$argument\" = lock ]; then\n    printf '%s\\n' started > " + quote(started.path) + "\n    /bin/cat " + quote(gate.path) + " >/dev/null\n  fi\n"
        }
        script += "  if [ \"$argument\" = list ]; then printf '%s\\n' list >> " + quote(listed.path) + "; fi\ndone\nexec /usr/bin/git \"$@\"\n"
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    @discardableResult
    private nonisolated func releaseAdmissionGate(_ path: URL) -> Bool {
        let descriptor = open(path.path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return Data("release\n".utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) == $0.count }
    }

    func testTerminalOperationReleasesDocumentOwnedRepositoryAndServiceDespiteRetainedTaskCallback() async throws {
        let fixture = try RepairFixture(label: "terminal-owner-release")
        defer { fixture.cleanup() }
        var repository: RepositoryTestGitRepository? = try RepositoryTestGitRepository(url: fixture.main)
        repository?.worktreeService.cancel()
        let writer = ControlledWorktreeTask()
        let launched = expectation(description: "document-owned service writer admitted")
        var service: PBRepositoryWorktreeService? = try makeService(repository: XCTUnwrap(repository), fixture: fixture, blocked: writer, launched: launched)
        repository?.setValue(service, forKey: "worktreeService")
        XCTAssertTrue(repository?.worktreeService === service)
        try await ready(XCTUnwrap(service))
        let ownership = WeakWorktreeOwnership(repository: repository, service: service)
        let completed = expectation(description: "retained owner is released at terminal completion")
        completed.assertForOverFulfill = true
        let completionState = WriterCharacterizationResult()
        enqueue { service?.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { XCTAssertNil(error); completionState.names.append("completed"); completed.fulfill() }
        } }
        await fulfillment(of: [launched], timeout: 10)
        let lateCallback = try XCTUnwrap(writer.retainedCallback())
        repository = nil
        service = nil
        XCTAssertNotNil(ownership.repository)
        XCTAssertNotNil(ownership.service)
        _ = try fixture.git(["worktree", "lock", "--reason", "held", fixture.linked.path])
        writer.finish(Data())
        await fulfillment(of: [completed], timeout: 10)
        let drained = expectation(description: "terminal main-queue ownership released")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertNil(ownership.repository)
        XCTAssertNil(ownership.service)
        lateCallback(Data("late terminal callback".utf8), nil)
        XCTAssertEqual(completionState.names, ["completed"])
        XCTAssertEqual(try String(contentsOf: fixture.main.appendingPathComponent(".git/worktrees/linked/locked"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "held")
    }

    #if DEBUG
        func testLifecyclePublicEventsExcludePrivateArgumentsAndOutputsFromRealRoutes() async throws {
            let fixture = try RepairFixture(label: "public-log-canaries")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let secretReason = "lock-reason-secret-" + UUID().uuidString
            let secretPath = fixture.root.appendingPathComponent("path-secret-" + UUID().uuidString).path
            let secretBranch = "branch-secret-" + UUID().uuidString
            let secretOutput = "https://alice:credential-secret@gitx.invalid/" + UUID().uuidString
            let failedTask = ControlledWorktreeTask()
            let failureLaunched = expectation(description: "failed route admitted")
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments == ["worktree", "add", "-b", secretBranch, secretPath] {
                    failureLaunched.fulfill(); return failedTask
                }
                return nil
            })
            defer { service.cancel(); failedTask.finish(nil, error: CancellationError()) }
            try await ready(service)
            let recorded = WorktreePublicEventRecorder()
            service.lifecycleEventObserver = { recorded.events.append($0) }
            defer { service.lifecycleEventObserver = nil }
            let locked = expectation(description: "real lock retains exact private execution reason")
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: secretReason) { _, error in XCTAssertNil(error); locked.fulfill() } }
            await fulfillment(of: [locked], timeout: 10)
            XCTAssertEqual(try String(contentsOf: fixture.main.appendingPathComponent(".git/worktrees/linked/locked"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), secretReason)
            let failed = expectation(description: "failed route produces redacted presentation diagnostics")
            enqueue { service.addWorktree(path: secretPath, branch: secretBranch, createBranch: true) { _, error in
                XCTAssertNotNil(error)
                XCTAssertFalse((error as NSError?)?.localizedFailureReason?.contains("credential-secret") ?? true)
                failed.fulfill()
            } }
            await fulfillment(of: [failureLaunched], timeout: 10)
            failedTask.finish(Data(secretOutput.utf8), error: NSError(domain: "fixture", code: 1))
            await fulfillment(of: [failed], timeout: 10)
            let required = ["worktree.lock.started phase=writing count=1 category=none", "worktree.add.failed phase=writing count=1 category=task"]
            let events = recorded.events
            XCTAssertEqual(events.filter { $0.hasPrefix("worktree.add.failed") || $0.hasPrefix("worktree.add.rejected") }.count, 1, "A task refusal has one terminal event with its real phase and category")
            for event in required {
                XCTAssertTrue(events.contains(event), "Missing emitted lifecycle event: \(event)")
            }
            for event in events {
                for secret in [secretReason, secretPath, secretBranch, secretOutput, "credential-secret"] {
                    XCTAssertFalse(event.contains(secret))
                }
            }
            XCTAssertEqual(PBWorktreeLifecycleDiagnostics.publicEvent(arguments: ["worktree", "lock", "--reason", secretReason, secretPath], stage: secretOutput, phase: secretBranch, count: -1, category: secretReason), "worktree.lock.unknown phase=unknown count=0 category=unknown")
        }
    #endif

    @MainActor
    private final class WorktreePublicEventRecorder {
        var events: [String] = []
    }

    @MainActor
    private final class WeakWorktreeOwnership {
        weak var repository: PBGitRepository?
        weak var service: PBRepositoryWorktreeService?

        init(repository: PBGitRepository?, service: PBRepositoryWorktreeService?) {
            self.repository = repository
            self.service = service
        }
    }

    @MainActor
    private final class RepairCompletion {
        var preview: PBWorktreeRepairPreview?
        var error: NSError?
    }

    private func prepareRepairPreview(_ service: PBRepositoryWorktreeService, worktree: PBGitWorktree? = nil, path: String? = nil, relative: Bool = false) async -> RepairCompletion {
        let result = RepairCompletion()
        let done = expectation(description: "repair preview completed")
        done.assertForOverFulfill = true
        let completion: (PBWorktreeRepairPreview?, Error?) -> Void = { preview, error in
            // swift6-safety-justification: The service delivers preview completion on the main queue.
            MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; done.fulfill() }
        }
        enqueue {
            if let worktree, let path {
                service.prepareRepair(worktree: worktree, movedTo: path, completion: completion)
            } else {
                service.prepareRepairLinks(relativePaths: relative, completion: completion)
            }
        }
        await fulfillment(of: [done], timeout: 10)
        return result
    }

    private func confirmRepairPreview(_ service: PBRepositoryWorktreeService, preview: PBWorktreeRepairPreview) async -> RepairCompletion {
        let result = RepairCompletion()
        let done = expectation(description: "repair confirmation completed")
        done.assertForOverFulfill = true
        enqueue { service.repair(confirmedPreview: preview) { renewed, error in
            // swift6-safety-justification: The service delivers confirmation completion on the main queue.
            MainActor.assumeIsolated { result.preview = renewed; result.error = error as NSError?; done.fulfill() }
        } }
        await fulfillment(of: [done], timeout: 10)
        return result
    }

    private func writeVersionedGitProxy(_ path: URL, version: String, atomic: Bool) throws {
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  printf '%s\\n' 'git version " + version + "'\nelse\n  exec /usr/bin/git \"$@\"\nfi\n"
        try script.write(to: path, atomically: atomic, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func testReadOnlyPruneRefreshConsumesOldAuthorityAndRevokedConfirmationNeverWrites() async throws {
        for queued in [false, true] {
            let fixture = try RepairFixture(label: "read-only-prune-review")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let blocked = ControlledWorktreeTask()
            let launched = queued ? expectation(description: "held writer admitted") : XCTestExpectation(description: "unused writer admission")
            var writes = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched, taskOverride: { arguments in
                if arguments == WorktreeCommand.prune.arguments {
                    writes += 1
                }
                return nil
            })
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            try FileManager.default.removeItem(at: fixture.linked)
            let captured = try await service.preparePrunePreview()
            let old = try XCTUnwrap(captured)
            let review = PruneCompletion()
            let refreshed = expectation(description: "read-only refresh returns one fresh token")
            service.refreshPrunePreview(old, ownerIsCurrent: { true }) { updated, changed, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue.
                MainActor.assumeIsolated {
                    XCTAssertFalse(changed)
                    review.preview = updated; review.error = error as NSError?; refreshed.fulfill()
                }
            }
            await fulfillment(of: [refreshed], timeout: 10)
            XCTAssertNil(review.error)
            let current = try XCTUnwrap(review.preview)
            XCTAssertEqual(writes, 0)
            let owner = PruneOwnerState()
            let previousWriter = queued ? expectation(description: "earlier writer completes") : XCTestExpectation(description: "unused writer completion")
            if queued {
                enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in
                    XCTAssertNil(error); previousWriter.fulfill()
                } }
                await fulfillment(of: [launched], timeout: 5)
            } else {
                owner.isCurrent = false
            }
            let refused = expectation(description: "revoked prune confirmation is cancelled")
            service.confirmPrune(current, ownerIsCurrent: { owner.isCurrent }) { updated, error in
                XCTAssertNil(updated)
                XCTAssertEqual((error as NSError?)?.code, NSUserCancelledError)
                refused.fulfill()
            }
            owner.isCurrent = false
            if queued {
                blocked.finish(Data())
                await fulfillment(of: [previousWriter], timeout: 10)
            }
            await fulfillment(of: [refused], timeout: 10)
            let consumed = expectation(description: "old preview cannot regain authority")
            enqueue { service.prune(confirmedPreview: old) { updated, error in
                XCTAssertNil(updated); XCTAssertNotNil(error); consumed.fulfill()
            } }
            await fulfillment(of: [consumed], timeout: 5)
            XCTAssertEqual(writes, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
        }
    }

    func testPruneRenewsConsentWhenHealthySiblingGitfileBytesChangeWithoutChangingTheirEndpoint() async throws {
        let fixture = try RepairFixture(label: "prune-exact-sibling-link")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        var prunes = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: {
            arguments in if arguments == ["worktree", "prune"] {
                prunes += 1
            }; return nil
        })
        defer { service.cancel() }
        try await ready(service)
        let missing = fixture.root.appendingPathComponent("prune-candidate")
        _ = try fixture.git(["worktree", "add", "-b", "prune-candidate", missing.path])
        try FileManager.default.removeItem(at: missing)
        let initial = try await service.preparePrunePreview()
        let preview = try XCTUnwrap(initial)
        XCTAssertTrue(preview.report.contains("prune-candidate"))
        let link = fixture.linked.appendingPathComponent(".git")
        let original = try Data(contentsOf: link)
        let ownAdmin = WorktreePaths.canonical(fixture.main.appendingPathComponent(".git/worktrees/linked").path)
        let replacement = Data(("gitdir: " + ownAdmin + "/.\n").utf8)
        XCTAssertNotEqual(original, replacement)
        let oldHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        try replacement.write(to: link)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), oldHead)
        XCTAssertEqual(try fixture.git(["worktree", "prune", "--dry-run", "--verbose"]), preview.report)
        let metadata = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let renewed = PruneCompletion()
        let updated = expectation(description: "exact gitfile byte changes require another explicit consent")
        enqueue { service.prune(confirmedPreview: preview) { current, error in
            // swift6-safety-justification: The service delivers typed lifecycle completion on the main queue.
            MainActor.assumeIsolated { renewed.preview = current; renewed.error = error as NSError?; updated.fulfill() }
        } }
        await fulfillment(of: [updated], timeout: 10)
        XCTAssertNil(renewed.error)
        XCTAssertEqual(prunes, 0)
        XCTAssertEqual(try self.metadata(in: fixture), metadata)
        XCTAssertEqual(try Data(contentsOf: link), replacement)
        let current = try XCTUnwrap(renewed.preview)
        XCTAssertEqual(current.report, preview.report)
        let confirmed = await confirmationError(service, preview: current)
        XCTAssertNil(confirmed)
        XCTAssertEqual(prunes, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/prune-candidate").path))
        XCTAssertEqual(try Data(contentsOf: link), replacement)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), oldHead)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try self.metadata(in: fixture).filter { $0.key.hasPrefix("linked/") }, metadata.filter { $0.key.hasPrefix("linked/") })
    }

    func testRealWriterPublishesReconciliationBeforeCompletionAndReleasesFIFO() async throws {
        try await characterizeRealWriterReconciliation(failsReconciliation: false)
    }

    func testCompletedRealWriterReportsReconciliationCancellationAndReleasesFIFO() async throws {
        try await characterizeRealWriterReconciliation(failsReconciliation: true)
    }

    func testAdmittedWriterFinishesAfterCloseOrPreferencesChangeAndKeepsFIFO() async throws {
        try await assertAdmittedWriterSurvivesOwnerChange(duringReconciliation: false)
    }

    func testCompletedWriterReconcilesAfterCloseOrPreferencesChangeAndKeepsFIFO() async throws {
        try await assertAdmittedWriterSurvivesOwnerChange(duringReconciliation: true)
    }

    func testQueuedRepairAcceptsOnlyHeadProjectionChangesWithoutAdoptingNewOwnership() async throws {
        for detached in [false, true] {
            let fixture = try RepairFixture(label: "queued-head-repair")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let blocked = ControlledWorktreeTask()
            let launched = expectation(description: "earlier writer reserves FIFO")
            var commands: [[String]] = []
            let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched, taskOverride: { arguments in commands.append(arguments); return nil })
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let original = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let link = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let held = expectation(description: "first writer completed")
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
            await fulfillment(of: [launched], timeout: 5)
            let done = expectation(description: "HEAD-only change does not invalidate repair")
            done.assertForOverFulfill = true
            enqueue { service.repair(worktree: tree, movedTo: fixture.linked.path) { error in XCTAssertNil(error); done.fulfill() } }
            if detached {
                _ = try fixture.git(["checkout", "--detach", "HEAD"], in: fixture.linked)
            } else {
                _ = try fixture.git(["symbolic-ref", "HEAD", "refs/heads/main"], in: fixture.linked)
            }
            let changed = try metadata(in: fixture)
            XCTAssertNotEqual(changed["linked/HEAD"], original["linked/HEAD"])
            XCTAssertEqual(changed.filter { !$0.key.hasSuffix("/HEAD") }, original.filter { !$0.key.hasSuffix("/HEAD") })
            let currentHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
            let progressed = expectation(description: "next writer runs after repair")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in progressed.fulfill() } }
            blocked.finish(Data())
            await fulfillment(of: [held, done, progressed], timeout: 10)
            XCTAssertEqual(commands.filter { $0.contains("repair") }.count, 1)
            XCTAssertEqual(try metadata(in: fixture), changed)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), link)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), currentHead)
        }
    }

    func testQueuedPruneAcceptsHeadProjectionChangesWithIdenticalCandidatesAndLinks() async throws {
        for detached in [false, true] {
            let fixture = try RepairFixture(label: "queued-head-prune")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let blocked = ControlledWorktreeTask()
            let launched = expectation(description: "earlier writer reserves FIFO")
            var pruneCommands = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched, taskOverride: { arguments in
                if arguments == ["worktree", "prune"] {
                    pruneCommands += 1
                }
                return nil
            })
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            try FileManager.default.removeItem(at: fixture.linked)
            let captured = try await service.preparePrunePreview()
            let preview = try XCTUnwrap(captured)
            XCTAssertTrue(preview.report.contains("linked"))
            let held = expectation(description: "first writer completed")
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
            await fulfillment(of: [launched], timeout: 5)
            let result = PruneCompletion()
            let done = expectation(description: "HEAD-only change does not require new prune consent")
            done.assertForOverFulfill = true
            enqueue { service.prune(confirmedPreview: preview) { renewed, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { result.preview = renewed; result.error = error as NSError?; done.fulfill() }
            } }
            let admin = fixture.main.appendingPathComponent(".git/worktrees/linked")
            let before = try metadata(in: fixture)
            let head = try fixture.git(["rev-parse", "refs/heads/main"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let changedHEAD = detached ? head + "\n" : "ref: refs/heads/main\n"
            try Data(changedHEAD.utf8).write(to: admin.appendingPathComponent("HEAD"))
            XCTAssertNotEqual(try Data(contentsOf: admin.appendingPathComponent("HEAD")), before["linked/HEAD"])
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/HEAD") }, before.filter { !$0.key.hasSuffix("/HEAD") })
            XCTAssertEqual(try fixture.git(["worktree", "prune", "--dry-run", "--verbose"]), preview.report)
            let refs = try fixture.git(["show-ref", "--head"])
            let mainHEAD = try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD"))
            let mainIndex = try Data(contentsOf: fixture.main.appendingPathComponent(".git/index"))
            let progressed = expectation(description: "next queued writer progresses")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in progressed.fulfill() } }
            blocked.finish(Data())
            await fulfillment(of: [held, done, progressed], timeout: 10)
            XCTAssertNil(result.error)
            XCTAssertNil(result.preview)
            if let renewed = result.preview {
                service.discardPrunePreview(renewed)
            }
            XCTAssertEqual(pruneCommands, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: admin.path))
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD")), mainHEAD)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/index")), mainIndex)
        }
    }

    func testPruneRevalidatesRegularStrayReplacementRemovalAndTypeChangeUnderPendingConsent() async throws {
        for queued in [false, true] {
            for change in ["replacement", "removal", "symlink"] {
                let fixture = try RepairFixture(label: "pending-stray-" + change)
                defer { fixture.cleanup() }
                let stray = fixture.main.appendingPathComponent(".git/worktrees/consent-stray")
                let opaque = Data("approved opaque bytes\n".utf8)
                try opaque.write(to: stray)
                let repository = try RepositoryTestGitRepository(url: fixture.main)
                let blocked = ControlledWorktreeTask()
                let launched = queued ? expectation(description: "earlier writer admitted") : XCTestExpectation(description: "unused admission")
                var prunes = 0
                let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched, taskOverride: {
                    arguments in if arguments == ["worktree", "prune"] {
                        prunes += 1
                    }; return nil
                })
                defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
                try await ready(service)
                try FileManager.default.removeItem(at: fixture.linked)
                let captured = try await service.preparePrunePreview()
                let preview = try XCTUnwrap(captured)
                XCTAssertTrue(preview.report.contains("linked"))
                XCTAssertTrue(preview.report.contains("consent-stray"))
                let oldStray = try WorktreeFileFingerprint.capture(path: stray.path)
                let protected = try metadata(in: fixture)
                let refs = try fixture.git(["show-ref", "--head"])
                let mainFiles = [".git/HEAD", ".git/index", "marker.txt"].map { fixture.main.appendingPathComponent($0) }
                let mainBytes = try mainFiles.map { try Data(contentsOf: $0) }
                let result = PruneCompletion()
                let confirmed = expectation(description: "changed stray rejects old consent: \(change), queued=\(queued)")
                confirmed.assertForOverFulfill = true
                let held = queued ? expectation(description: "earlier writer completes") : XCTestExpectation(description: "unused completion")
                if queued {
                    enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
                    await fulfillment(of: [launched], timeout: 5)
                    enqueue { service.prune(confirmedPreview: preview) { current, error in
                        // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                        MainActor.assumeIsolated { result.preview = current; result.error = error as NSError?; confirmed.fulfill() }
                    } }
                }
                let foreign = fixture.root.appendingPathComponent("foreign-opaque-file")
                switch change {
                case "replacement":
                    try opaque.write(to: stray, options: .atomic)
                    XCTAssertEqual(try Data(contentsOf: stray), opaque)
                    XCTAssertNotEqual(try WorktreeFileFingerprint.capture(path: stray.path).identity, oldStray.identity)
                case "removal": try FileManager.default.removeItem(at: stray)
                default:
                    try Data("foreign opaque bytes must survive\n".utf8).write(to: foreign)
                    try FileManager.default.removeItem(at: stray)
                    try FileManager.default.createSymbolicLink(at: stray, withDestinationURL: foreign)
                }
                if queued {
                    blocked.finish(Data())
                    await fulfillment(of: [held, confirmed], timeout: 10)
                } else {
                    enqueue { service.prune(confirmedPreview: preview) { current, error in
                        // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                        MainActor.assumeIsolated { result.preview = current; result.error = error as NSError?; confirmed.fulfill() }
                    } }
                    await fulfillment(of: [confirmed], timeout: 10)
                }
                XCTAssertEqual(prunes, 0)
                XCTAssertEqual(try metadata(in: fixture), protected)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                XCTAssertEqual(try mainFiles.map { try Data(contentsOf: $0) }, mainBytes)
                if change == "symlink" {
                    XCTAssertNil(result.preview)
                    XCTAssertNotNil(result.error)
                    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stray.path), foreign.path)
                    XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign opaque bytes must survive\n".utf8))
                } else {
                    XCTAssertNil(result.error)
                    XCTAssertNotNil(result.preview)
                    if change == "replacement" {
                        XCTAssertEqual(result.preview?.report, preview.report)
                    }
                }
                let progressed = expectation(description: "rejection or renewal releases shared FIFO")
                enqueue { service.unlockWorktree(path: fixture.linked.path) { _, error in XCTAssertNotNil(error); progressed.fulfill() } }
                await fulfillment(of: [progressed], timeout: 10)
                XCTAssertEqual(prunes, 0)
                if change == "symlink" {
                    try FileManager.default.removeItem(at: stray)
                    try opaque.write(to: stray)
                    let fresh = try await service.preparePrunePreview()
                    result.preview = try XCTUnwrap(fresh)
                }
                let fresh = try XCTUnwrap(result.preview)
                let approved = await confirmationError(service, preview: fresh)
                XCTAssertNil(approved)
                XCTAssertEqual(prunes, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                XCTAssertEqual(try mainFiles.map { try Data(contentsOf: $0) }, mainBytes)
                if change == "symlink" {
                    XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign opaque bytes must survive\n".utf8))
                }
            }
        }
    }

    func testPruneIncludesAnApprovedRegularStrayWithoutInventingAWorktreeRegistration() async throws {
        let fixture = try RepairFixture(label: "regular-stray")
        defer { fixture.cleanup() }
        let stray = fixture.main.appendingPathComponent(".git/worktrees/regular-stray")
        let bytes = Data("ordinary stray retained until consent\n".utf8)
        try bytes.write(to: stray)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        var pruneCommands = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if arguments == ["worktree", "prune"] {
                pruneCommands += 1
            }
            return nil
        })
        defer { service.cancel() }
        try await ready(service)
        let metadata = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let link = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let result = PruneCompletion()
        let captured = expectation(description: "complete preview includes regular stray")
        enqueue { service.preparePrunePreview { preview, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; captured.fulfill() }
        } }
        await fulfillment(of: [captured], timeout: 10)
        XCTAssertNil(result.error)
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(try Data(contentsOf: stray), bytes)
        XCTAssertEqual(pruneCommands, 0)
        guard let preview = result.preview else { XCTFail("A regular stray must be represented in complete inventory evidence"); return }
        XCTAssertTrue(preview.report.contains("regular-stray"))
        XCTAssertEqual(preview.report, try fixture.git(["worktree", "prune", "--dry-run", "--verbose"]))
        let confirmedError = await confirmationError(service, preview: preview)
        XCTAssertNil(confirmedError)
        XCTAssertEqual(pruneCommands, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(try self.metadata(in: fixture), metadata)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), link)
        XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked).isEmpty)
    }

    func testLocateAndReclaimAcceptHealthyMixedSiblingLinksInBothRequestedStyles() async throws {
        for relative in [false, true] {
            for reclaim in [false, true] {
                let fixture = try RepairFixture(label: "mixed-sibling")
                defer { fixture.cleanup() }
                let flag = relative ? "--relative-paths" : "--no-relative-paths"
                _ = try fixture.git(["worktree", "repair", flag])
                let sibling = fixture.root.appendingPathComponent("sibling")
                _ = try fixture.git(["worktree", "add", flag, "-b", "sibling", sibling.path])
                let siblingAdmin = fixture.main.appendingPathComponent(".git/worktrees/sibling")
                let backlink = siblingAdmin.appendingPathComponent("gitdir")
                try Data((relative ? sibling.appendingPathComponent(".git").path + "\n" : "../../../../sibling/.git\n").utf8).write(to: backlink)
                let pair = try [Data(contentsOf: sibling.appendingPathComponent(".git")), Data(contentsOf: backlink)]
                let selected: URL
                if reclaim {
                    selected = fixture.linked
                    try FileManager.default.removeItem(at: selected.appendingPathComponent(".git"))
                } else {
                    selected = fixture.root.appendingPathComponent("located")
                    try FileManager.default.moveItem(at: fixture.linked, to: selected)
                }
                let refs = try fixture.git(["show-ref", "--head"])
                let contents = try Data(contentsOf: selected.appendingPathComponent("marker.txt"))
                let repository = try RepositoryTestGitRepository(url: fixture.main)
                var writes: [[String]] = []
                let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                    if arguments.starts(with: ["worktree", "repair"]) {
                        writes.append(arguments)
                    }
                    return nil
                })
                defer { service.cancel() }
                try await ready(service, expectedWorktreeCount: 3)
                let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
                let previewResult = await prepareRepairPreview(service, worktree: tree, path: selected.path)
                XCTAssertNil(previewResult.error)
                let preview = try XCTUnwrap(previewResult.preview)
                XCTAssertEqual(preview.requiresReclaim, reclaim)
                let result = await confirmRepairPreview(service, preview: preview)
                XCTAssertNil(result.error, "Git deliberately preserves an unchanged healthy mixed-style sibling")
                XCTAssertNil(result.preview)
                XCTAssertEqual(writes.count, 1)
                XCTAssertTrue(try XCTUnwrap(writes.first).contains(flag))
                let actualPair = try [Data(contentsOf: sibling.appendingPathComponent(".git")), Data(contentsOf: backlink)]
                let siblingLink = String(decoding: actualPair[0], as: UTF8.self)
                let siblingBacklink = String(decoding: actualPair[1], as: UTF8.self).trimmingCharacters(in: .newlines)
                let normalized = siblingLink.hasPrefix("gitdir: /") == !relative && (siblingBacklink as NSString).isAbsolutePath == !relative
                XCTAssertTrue(actualPair == pair || normalized, "Git may preserve its healthy mixed pair or normalize both links to the requested style")
                XCTAssertEqual(try WorktreePaths.canonical(fixture.git(["rev-parse", "--absolute-git-dir"], in: sibling).trimmingCharacters(in: .newlines)), WorktreePaths.canonical(siblingAdmin.path))
                let backPath = (siblingBacklink as NSString).isAbsolutePath ? siblingBacklink : siblingAdmin.appendingPathComponent(siblingBacklink).path
                XCTAssertEqual(WorktreePaths.canonical(backPath), WorktreePaths.canonical(sibling.appendingPathComponent(".git").path))
                let selectedLink = try String(contentsOf: selected.appendingPathComponent(".git"), encoding: .utf8)
                let selectedBacklink = try String(contentsOf: fixture.main.appendingPathComponent(".git/worktrees/linked/gitdir"), encoding: .utf8)
                XCTAssertEqual(selectedLink.hasPrefix("gitdir: /"), !relative)
                XCTAssertEqual((selectedBacklink.trimmingCharacters(in: .newlines) as NSString).isAbsolutePath, !relative)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("marker.txt")), contents)
                XCTAssertEqual(try WorktreePaths.canonical(fixture.git(["rev-parse", "--absolute-git-dir"], in: selected).trimmingCharacters(in: .newlines)), WorktreePaths.canonical(fixture.main.appendingPathComponent(".git/worktrees/linked").path))
            }
        }
    }

    func testLocateUsesAndVerifiesCapturedRelativeStyle() async throws {
        for (hasHealthySibling, writesWrongStyle) in [(true, false), (true, true), (false, false), (false, true)] {
            let fixture = try RepairFixture(label: "relative-locate")
            defer { fixture.cleanup() }
            let sibling = fixture.root.appendingPathComponent("relative-sibling")
            let located = fixture.root.appendingPathComponent("located")
            _ = try fixture.git(["config", "worktree.useRelativePaths", "false"])
            _ = try fixture.git(["worktree", "repair", "--relative-paths"])
            if hasHealthySibling {
                _ = try fixture.git(["worktree", "add", "--relative-paths", "-b", "relative-sibling", sibling.path])
            }
            try FileManager.default.moveItem(at: fixture.linked, to: located)
            let before = try metadata(in: fixture).filter { !$0.key.hasSuffix("/gitdir") }
            let refs = try fixture.git(["show-ref", "--head"])
            let siblingGitfile: Data?
            if hasHealthySibling {
                siblingGitfile = try Data(contentsOf: sibling.appendingPathComponent(".git"))
            } else {
                siblingGitfile = nil
            }
            let content = try Data(contentsOf: located.appendingPathComponent("marker.txt"))
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            var repairCommands: [[String]] = []
            let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                var executed = arguments
                if arguments.starts(with: ["worktree", "repair"]) {
                    repairCommands.append(arguments)
                    if writesWrongStyle {
                        executed = ["worktree", "repair", "--no-relative-paths"] + arguments.dropFirst(2).filter { !["--relative-paths", "--no-relative-paths"].contains($0) }
                    }
                }
                let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + executed, inDirectory: fixture.main.path)
                GitXTestGitFixture.prepare(task)
                return task
            }
            defer { service.cancel() }
            let discovered = expectation(description: "relative checkout inventory published; healthy sibling: \(hasHealthySibling)")
            let observation = service.observe(\.worktrees) { _, _ in discovered.fulfill() }
            service.start()
            await fulfillment(of: [discovered], timeout: 10)
            observation.invalidate()
            XCTAssertTrue(service.isSupported)
            XCTAssertEqual(service.worktrees.count, hasHealthySibling ? 3 : 2)
            let selected = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let result = WriterCharacterizationResult()
            let repaired = expectation(description: "Locate style operation finished")
            enqueue { service.repair(worktree: selected, movedTo: located.path) { error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { result.error = error as NSError?; repaired.fulfill() }
            } }
            await fulfillment(of: [repaired], timeout: 10)
            XCTAssertEqual(repairCommands.count, 1)
            XCTAssertEqual(try XCTUnwrap(repairCommands.first), ["worktree", "repair", "--relative-paths", WorktreePaths.canonical(fixture.main.path), WorktreePaths.canonical(located.path)])
            if writesWrongStyle {
                let error = try XCTUnwrap(result.error)
                XCTAssertTrue(error.localizedFailureReason?.contains("exact bidirectional links") == true)
            } else {
                XCTAssertNil(result.error)
                XCTAssertEqual(try String(contentsOf: located.appendingPathComponent(".git"), encoding: .utf8), "gitdir: ../main/.git/worktrees/linked\n")
                XCTAssertEqual(try String(contentsOf: fixture.main.appendingPathComponent(".git/worktrees/linked/gitdir"), encoding: .utf8), "../../../../located/.git\n")
                if let siblingGitfile {
                    XCTAssertEqual(try Data(contentsOf: sibling.appendingPathComponent(".git")), siblingGitfile)
                }
            }
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/gitdir") }, before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: located.appendingPathComponent("marker.txt")), content)
        }
    }

    func testLocateRepairsEveryCapturedMovedCheckoutInsteadOfPartiallyCompleting() async throws {
        let fixture = try RepairFixture(label: "multi-moved")
        defer { fixture.cleanup() }
        let first = fixture.main.appendingPathComponent("first")
        let second = fixture.main.appendingPathComponent("second")
        _ = try fixture.git(["worktree", "move", fixture.linked.path, first.path])
        _ = try fixture.git(["worktree", "add", "-b", "second", second.path])
        let moved = fixture.root.appendingPathComponent("relocated-main")
        try FileManager.default.moveItem(at: fixture.main, to: moved)
        let repository = try RepositoryTestGitRepository(url: moved)
        var commands: [[String]] = []
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            commands.append(arguments)
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + moved.appendingPathComponent(".git").path] + arguments, inDirectory: moved.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
        defer { service.cancel() }
        let discovered = expectation(description: "both moved worktrees discovered")
        let observation = service.observe(\.worktrees) { _, _ in discovered.fulfill() }
        service.start()
        await fulfillment(of: [discovered], timeout: 10)
        observation.invalidate()
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.worktrees.count, 3)
        let selected = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let sibling = try XCTUnwrap(service.worktree(forBranch: "refs/heads/second"))
        XCTAssertNotNil(selected.movedPath)
        XCTAssertNotNil(sibling.movedPath)
        let selectedPath = moved.appendingPathComponent("first")
        let siblingPath = moved.appendingPathComponent("second")
        let protected = ["linked", "second"].flatMap { name in
            ["HEAD", "index", "commondir"].map { moved.appendingPathComponent(".git/worktrees/" + name + "/" + $0) }
        }
        let before = try protected.map { try Data(contentsOf: $0) }
        let refs = try fixture.git(["show-ref", "--head"], in: moved)
        let done = expectation(description: "Locate repairs every checkout in its captured scope")
        enqueue { service.repair(worktree: selected, movedTo: selectedPath.path) { error in XCTAssertNil(error); done.fulfill() } }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(commands.filter { $0.contains("repair") }.count, 1)
        for (name, path) in [("linked", selectedPath), ("second", siblingPath)] {
            let canonical = WorktreePaths.canonical(path.path)
            XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent(".git/worktrees/" + name + "/gitdir"), encoding: .utf8), canonical + "/.git\n")
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent(".git"), encoding: .utf8), "gitdir: " + WorktreePaths.canonical(moved.appendingPathComponent(".git/worktrees/" + name).path) + "\n")
            XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: path).isEmpty)
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("marker.txt")), Data("multi-moved\n".utf8))
        }
        XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: moved), refs)
    }

    private func assertAdmittedWriterSurvivesOwnerChange(duringReconciliation: Bool) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for close in [true, false] {
            let fixture = try RepairFixture(label: "admitted-writer-lifetime")
            defer { fixture.cleanup() }
            defaults.set(previous, forKey: "gitExecutable")
            let replacement = fixture.root.appendingPathComponent("new-selected-git")
            try writeVerificationGitProxy(replacement)
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let pending = ControlledWorktreeTask()
            let admitted = expectation(description: "writer or reconciliation admitted")
            admitted.assertForOverFulfill = true
            let lockArguments = ["worktree", "lock", "--reason", "draining writer", fixture.linked.path]
            let unlockArguments = ["worktree", "unlock", fixture.linked.path]
            var holdRead = false
            var arguments: [[String]] = []
            var followingArguments: [[String]] = []
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { command in
                arguments.append(command)
                if command == ["--version"], defaults.string(forKey: "gitExecutable") == replacement.path {
                    return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.50.1"], inDirectory: nil)
                }
                if (!duringReconciliation && command == lockArguments) || (holdRead && command == ["worktree", "list", "--porcelain", "-z"]) {
                    holdRead = false
                    admitted.fulfill()
                    return pending
                }
                return nil
            })
            let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { command in
                followingArguments.append(command)
                if command == ["--version"], defaults.string(forKey: "gitExecutable") == replacement.path {
                    return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.50.1"], inDirectory: nil)
                }
                return nil
            })
            defer { service.cancel(); following.cancel(); pending.finish(nil, error: CancellationError()) }
            try await ready(service)
            try await ready(following)
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let link = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let result = WriterCharacterizationResult()
            let completed = expectation(description: "admitted writer completes once using captured context")
            let progressed = expectation(description: "next writer follows terminal reconciliation")
            completed.assertForOverFulfill = true
            progressed.assertForOverFulfill = true
            holdRead = duringReconciliation
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "draining writer") { _, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated {
                    result.error = error as NSError?
                    result.names.append("first")
                    XCTAssertFalse(followingArguments.contains(unlockArguments))
                    completed.fulfill()
                }
            } }
            await fulfillment(of: [admitted], timeout: 10)
            let initialReads = arguments.filter { $0 == ["worktree", "list", "--porcelain", "-z"] }.count
            if close {
                service.cancel()
            } else {
                let rechecked = expectation(description: "new preference capability inspected")
                let observation = service.observe(\.gitVersion) { observed, _ in
                    // swift6-safety-justification: The service publishes capability changes on the main queue.
                    MainActor.assumeIsolated {
                        if observed.gitVersion == "git version 2.50.1" {
                            rechecked.fulfill()
                        }
                    }
                }
                let followingRechecked = expectation(description: "following owner has fresh supported capability")
                let followingObservation = following.observe(\.gitVersion) { observed, _ in
                    // swift6-safety-justification: The service publishes capability changes on the main queue.
                    MainActor.assumeIsolated {
                        if observed.gitVersion == "git version 2.50.1" {
                            followingRechecked.fulfill()
                        }
                    }
                }
                defaults.set(replacement.path, forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
                await fulfillment(of: [rechecked, followingRechecked], timeout: 10)
                observation.invalidate()
                followingObservation.invalidate()
            }
            XCTAssertFalse(pending.wasCancelled, "An admitted writer and its captured-context reconciliation drain after caller closure or preference change")
            XCTAssertTrue(result.names.isEmpty)
            enqueue { following.unlockWorktree(path: fixture.linked.path) { _, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { XCTAssertNil(error); result.names.append("following"); progressed.fulfill() }
            } }
            XCTAssertFalse(followingArguments.contains(unlockArguments))
            if duringReconciliation {
                XCTAssertEqual(try String(contentsOf: fixture.main.appendingPathComponent(".git/worktrees/linked/locked"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "draining writer")
                try pending.finish(Data(fixture.git(["worktree", "list", "--porcelain", "-z"]).utf8))
            } else {
                _ = try fixture.git(lockArguments)
                pending.finish(Data())
            }
            await fulfillment(of: [completed, progressed], timeout: 10)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.names, ["first", "following"])
            XCTAssertEqual(arguments.filter { $0 == lockArguments }.count, 1)
            XCTAssertEqual(followingArguments.filter { $0 == unlockArguments }.count, 1)
            if !duringReconciliation {
                XCTAssertGreaterThan(arguments.filter { $0 == ["worktree", "list", "--porcelain", "-z"] }.count, initialReads)
            }
            XCTAssertEqual(try metadata(in: fixture), before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), link)
        }
    }

    func testBareRepositoryPrunePreviewUsesTheSameCurrentInspectionLocation() async throws {
        let fixture = try RepairFixture(label: "bare-preview")
        defer { fixture.cleanup() }
        let bare = fixture.root.appendingPathComponent("bare")
        let linked = fixture.root.appendingPathComponent("bare-linked")
        _ = try fixture.git(["clone", "--bare", fixture.main.path, bare.path])
        _ = try fixture.git(["--git-dir=" + bare.path, "worktree", "add", "-b", "bare-topic", linked.path])
        let repository = try RepositoryTestGitRepository(url: bare)
        XCTAssertNil(repository.workingDirectoryURL(), "This exercises ObjectiveGit's bare-repository location boundary")
        var arguments: [[String]] = []
        let service = PBRepositoryWorktreeService(repository: repository) { command in
            arguments.append(command)
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + bare.path] + command, inDirectory: bare.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
        defer { service.cancel() }
        try await ready(service)
        let main = try XCTUnwrap(service.worktrees.first(where: \.isMain))
        XCTAssertTrue(main.isCurrent)
        let head = try Data(contentsOf: bare.appendingPathComponent("HEAD"))
        let refs = try fixture.git(["--git-dir=" + bare.path, "show-ref", "--head"])
        let gitfile = try Data(contentsOf: linked.appendingPathComponent(".git"))
        let admin = try URL(fileURLWithPath: fixture.git(["rev-parse", "--absolute-git-dir"], in: linked).trimmingCharacters(in: .whitespacesAndNewlines))
        let protectedPaths = ["HEAD", "index", "gitdir", "commondir"].map { admin.appendingPathComponent($0) }
        let protected = try protectedPaths.map { try Data(contentsOf: $0) }
        let result = PruneCompletion()
        let done = expectation(description: "bare preview finishes without an attribution mismatch")
        done.assertForOverFulfill = true
        enqueue {
            service.preparePrunePreview { preview, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue.
                MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; done.fulfill() }
            }
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.preview)
        if let preview = result.preview {
            XCTAssertTrue(preview.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(preview.hasMovedWorktrees)
            service.discardPrunePreview(preview)
        }
        XCTAssertTrue(service.worktrees.first(where: \.isMain)?.isCurrent == true)
        XCTAssertFalse(arguments.contains(["worktree", "prune"]))
        XCTAssertEqual(try Data(contentsOf: bare.appendingPathComponent("HEAD")), head)
        XCTAssertEqual(try fixture.git(["--git-dir=" + bare.path, "show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try protectedPaths.map { try Data(contentsOf: $0) }, protected)
    }

    @MainActor
    private final class PruneReadBoundaryState {
        var ready = false
        var tearingDown = false
        var requests = 0
        var normalCompletions = 0
        let results = WorktreeObservationCounter()

        func completed() {
            if !tearingDown {
                normalCompletions += 1
            }
            results.advance()
        }
    }

    func testDirectInitialPruneDiscoveryCancellationWithALiveOwnerIsExpectedCancellationAndReleasesFIFO() async throws {
        let cancellations: [Error] = [CancellationError(), NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        for cancellation in cancellations {
            let fixture = try RepairFixture(label: "cancel-live-initial-discovery")
            let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
            let discovery = ControlledWorktreeTask()
            let reading = expectation(description: "live owner reaches operation-owned initial discovery")
            var holdNextDiscovery = false
            var arguments: [[String]] = []
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { command in
                arguments.append(command)
                if holdNextDiscovery, command == ["worktree", "list", "--porcelain", "-z"] {
                    holdNextDiscovery = false
                    reading.fulfill()
                    return discovery
                }
                return nil
            })
            let state = PruneReadBoundaryState()
            addTeardownBlock { @MainActor in
                state.tearingDown = true
                service.cancel()
                discovery.finish(nil, error: CancellationError())
                if state.requests > 0 {
                    await self.fulfillment(of: [state.results.expectation(atLeast: state.requests)], timeout: 10)
                }
                guard state.ready, state.results.value == state.requests, state.normalCompletions == state.requests else {
                    XCTFail("Initial discovery cancellation did not finish normally before teardown; preserving fixture at " + fixture.root.path)
                    return
                }
                fixture.cleanup()
            }
            try await ready(service)
            state.ready = service.isSupported && service.worktrees.count == 2
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let mainHEAD = try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD"))
            let mainIndex = try Data(contentsOf: fixture.main.appendingPathComponent(".git/index"))
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            let result = PruneCompletion()
            let order = WriterCharacterizationResult()
            let cancelled = expectation(description: "live initial discovery cancellation completes exactly once")
            let progressed = expectation(description: "following real writer uses the released preview reservation")
            let following = ["worktree", "lock", "--reason", "after initial discovery cancellation", fixture.linked.path]
            holdNextDiscovery = true
            state.requests += 1
            enqueue { service.preparePrunePreview { preview, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue before releasing FIFO.
                MainActor.assumeIsolated {
                    defer { state.completed() }
                    result.preview = preview; result.error = error as NSError?
                    order.names.append("cancelled")
                    XCTAssertFalse(arguments.contains(following))
                    cancelled.fulfill()
                }
            } }
            await fulfillment(of: [reading], timeout: 10)
            state.requests += 1
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "after initial discovery cancellation") { _, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated {
                    defer { state.completed() }
                    XCTAssertNil(error)
                    order.names.append("following"); progressed.fulfill()
                }
            } }
            XCTAssertFalse(arguments.contains(following))
            discovery.finish(nil, error: cancellation)
            await fulfillment(of: [cancelled, progressed], timeout: 15)
            XCTAssertEqual(state.results.value, 2)
            XCTAssertEqual(state.normalCompletions, 2)
            XCTAssertEqual(order.names, ["cancelled", "following"])
            XCTAssertNil(result.preview)
            XCTAssertEqual(result.error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(result.error?.code, NSUserCancelledError)
            XCTAssertTrue(service.isSupported)
            XCTAssertFalse(discovery.wasCancelled, "The owner remains open; cancellation came from the operation-owned read")
            XCTAssertEqual(arguments.filter { $0 == following }.count, 1)
            XCTAssertFalse(arguments.contains(["worktree", "prune", "--dry-run", "--verbose"]), "Cancellation happened before the raw report phase")
            XCTAssertFalse(arguments.contains(["worktree", "prune"]))
            XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "after initial discovery cancellation")
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD")), mainHEAD)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/index")), mainIndex)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        }
    }

    func testLegacyPruneConfirmationUsesTheLatestReportPreviewAndActuallyPrunesItsCandidate() async throws {
        let fixture = try RepairFixture(label: "legacy-latest-prune-preview")
        let repository = LocatedWorktreeRepository(directory: fixture.main.appendingPathComponent(".git"))
        var arguments: [[String]] = []
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { command in
            arguments.append(command)
            return nil
        })
        let state = PruneReadBoundaryState()
        addTeardownBlock { @MainActor in
            state.tearingDown = true
            service.cancel()
            if state.requests > 0 {
                await self.fulfillment(of: [state.results.expectation(atLeast: state.requests)], timeout: 10)
            }
            guard state.ready, state.results.value == state.requests, state.normalCompletions == state.requests else {
                XCTFail("Legacy prune did not finish normally before teardown; preserving fixture at " + fixture.root.path)
                return
            }
            fixture.cleanup()
        }
        try await ready(service)
        state.ready = service.isSupported && service.worktrees.count == 2
        let mainHEAD = try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD"))
        let mainIndex = try Data(contentsOf: fixture.main.appendingPathComponent(".git/index"))
        let mainContent = try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt"))
        let refs = try fixture.git(["show-ref", "--head"])
        let administrative = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let first = expectation(description: "legacy report captures the healthy empty preview")
        state.requests += 1
        enqueue { service.pruneWorktrees(reportOnly: true) { report, error in
            // swift6-safety-justification: The service delivers legacy report completion on the main queue.
            MainActor.assumeIsolated {
                defer { state.completed() }
                XCTAssertNil(error)
                XCTAssertEqual(report?.trimmingCharacters(in: .whitespacesAndNewlines), "")
                first.fulfill()
            }
        } }
        await fulfillment(of: [first], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: administrative.path))
        XCTAssertFalse(arguments.contains(["worktree", "prune"]))
        try FileManager.default.removeItem(at: fixture.linked)
        let retained = try metadata(in: fixture)
        let listing = try fixture.git(["worktree", "list", "--porcelain"])
        XCTAssertTrue(listing.contains("prunable "), "Real Git must independently recognize the removed checkout as a candidate")
        let second = expectation(description: "second legacy report replaces the prior empty preview")
        state.requests += 1
        enqueue { service.pruneWorktrees(reportOnly: true) { report, error in
            // swift6-safety-justification: The service delivers legacy report completion on the main queue.
            MainActor.assumeIsolated {
                defer { state.completed() }
                XCTAssertNil(error)
                XCTAssertFalse(report?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                XCTAssertTrue(report?.contains("linked") == true)
                second.fulfill()
            }
        } }
        await fulfillment(of: [second], timeout: 10)
        XCTAssertEqual(arguments.filter { $0 == ["worktree", "prune", "--dry-run", "--verbose"] }.count, 2)
        XCTAssertEqual(try metadata(in: fixture), retained, "Neither legacy preview may mutate registration metadata")
        let confirmed = expectation(description: "legacy confirmation consumes the latest preview and really prunes")
        state.requests += 1
        enqueue { service.pruneWorktrees(reportOnly: false) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion after actual post-write discovery on the main queue.
            MainActor.assumeIsolated {
                defer { state.completed() }
                XCTAssertNil(error)
                XCTAssertNil(output)
                confirmed.fulfill()
            }
        } }
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(state.results.value, 3)
        XCTAssertEqual(state.normalCompletions, 3)
        XCTAssertEqual(arguments.filter { $0 == ["worktree", "prune"] }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: administrative.path))
        let consumed = expectation(description: "legacy confirmation cannot reuse its consumed preview")
        state.requests += 1
        enqueue { service.pruneWorktrees(reportOnly: false) { output, error in
            // swift6-safety-justification: The legacy facade rejects a consumed preview synchronously on its main-actor caller.
            MainActor.assumeIsolated {
                defer { state.completed() }
                XCTAssertNil(output)
                XCTAssertNotNil(error)
                consumed.fulfill()
            }
        } }
        await fulfillment(of: [consumed], timeout: 10)
        XCTAssertEqual(state.results.value, 4)
        XCTAssertEqual(state.normalCompletions, 4)
        XCTAssertEqual(arguments.filter { $0 == ["worktree", "prune"] }.count, 1)
        XCTAssertEqual(service.worktrees.map { WorktreePaths.identity($0.path) }, [WorktreePaths.identity(fixture.main.path)])
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD")), mainHEAD)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt")), mainContent)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
    }

    func testDirectPruneReportCancellationWithALiveOwnerIsExpectedCancellationAndReleasesFIFO() async throws {
        let cancellations: [Error] = [CancellationError(), NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        for cancellation in cancellations {
            let fixture = try RepairFixture(label: "cancel-current-report")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let report = ControlledWorktreeTask()
            let reading = expectation(description: "live owner reaches its read-only prune report")
            reading.assertForOverFulfill = true
            var holdNextReport = false
            var arguments: [[String]] = []
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { command in
                arguments.append(command)
                if holdNextReport, command == ["worktree", "prune", "--dry-run", "--verbose"] {
                    holdNextReport = false
                    reading.fulfill()
                    return report
                }
                return nil
            })
            defer { service.cancel(); report.finish(nil, error: CancellationError()) }
            try await ready(service)
            let before = try metadata(in: fixture)
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
            let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
            let result = PruneCompletion()
            let cancelled = expectation(description: "direct report cancellation completes once with the owner still live")
            let progressed = expectation(description: "following real writer proceeds after report cancellation")
            cancelled.assertForOverFulfill = true
            progressed.assertForOverFulfill = true
            let lockArguments = ["worktree", "lock", "--reason", "following", fixture.linked.path]
            holdNextReport = true
            enqueue {
                service.preparePrunePreview { preview, error in
                    // swift6-safety-justification: The service delivers preview completion on the main queue before releasing FIFO.
                    MainActor.assumeIsolated {
                        result.preview = preview
                        result.error = error as NSError?
                        XCTAssertFalse(arguments.contains(lockArguments))
                        cancelled.fulfill()
                    }
                }
            }
            await fulfillment(of: [reading], timeout: 10)
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "following") { _, error in XCTAssertNil(error); progressed.fulfill() } }
            XCTAssertFalse(arguments.contains(lockArguments))
            report.finish(nil, error: cancellation)
            await fulfillment(of: [cancelled, progressed], timeout: 10)
            XCTAssertNil(result.preview)
            XCTAssertEqual(result.error?.domain, NSCocoaErrorDomain)
            XCTAssertEqual(result.error?.code, NSUserCancelledError)
            XCTAssertTrue(service.isSupported)
            XCTAssertFalse(report.wasCancelled, "The owner remains open; cancellation came from the read-only task itself")
            XCTAssertEqual(arguments.filter { $0 == lockArguments }.count, 1)
            XCTAssertFalse(arguments.contains(["worktree", "prune"]))
            XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
            XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
            let fresh = try await service.preparePrunePreview()
            XCTAssertTrue(fresh.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            service.discardPrunePreview(fresh)
            let unlocked = expectation(description: "live service still performs a subsequent real writer")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, error in XCTAssertNil(error); unlocked.fulfill() } }
            await fulfillment(of: [unlocked], timeout: 10)
            XCTAssertEqual(try metadata(in: fixture), before)
        }
    }

    func testCancellingPruneDuringDiscoveryIsExpectedCancellationAndReleasesFIFO() async throws {
        let fixture = try RepairFixture(label: "cancel-preview-discovery")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let discovery = ControlledWorktreeTask()
        let reading = expectation(description: "preview discovery is pending")
        reading.assertForOverFulfill = true
        var holdNextDiscovery = false
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if holdNextDiscovery, arguments == ["worktree", "list", "--porcelain", "-z"] {
                holdNextDiscovery = false
                reading.fulfill()
                return discovery
            }
            return nil
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer { service.cancel(); following.cancel(); discovery.finish(nil, error: CancellationError()) }
        try await ready(service)
        try await ready(following)
        let before = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let content = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let result = PruneCompletion()
        let cancelled = expectation(description: "read-only preview reports expected cancellation once")
        cancelled.assertForOverFulfill = true
        holdNextDiscovery = true
        enqueue {
            service.preparePrunePreview { preview, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue.
                MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; cancelled.fulfill() }
            }
        }
        await fulfillment(of: [reading], timeout: 10)
        let progressed = expectation(description: "following real writer finishes after preview cancellation")
        progressed.assertForOverFulfill = true
        enqueue { following.lockWorktree(path: fixture.linked.path, reason: "following") { _, error in XCTAssertNil(error); progressed.fulfill() } }
        service.cancel()
        await fulfillment(of: [cancelled, progressed], timeout: 10)
        XCTAssertNil(result.preview)
        XCTAssertEqual(result.error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(result.error?.code, NSUserCancelledError)
        XCTAssertTrue(discovery.wasCancelled)
        XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
        XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        try discovery.finish(Data(fixture.git(["worktree", "list", "--porcelain", "-z"]).utf8))
        let drained = expectation(description: "late discovery callback was rejected")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertFalse(service.worktrees.first { $0.branchRefName == "refs/heads/topic" }?.isLocked ?? true)
    }

    #if DEBUG
        func testQueuedGlobalRepairUsesCapturedCheckoutWhenMovedDirectoryAliasChanges() async throws {
            let fixture = try RepairFixture(label: "argument-alias-own")
            let foreign = try RepairFixture(label: "argument-alias-foreign")
            defer { fixture.cleanup(); foreign.cleanup() }
            let nested = fixture.main.appendingPathComponent("nested")
            _ = try fixture.git(["worktree", "move", fixture.linked.path, nested.path])
            let movedMain = fixture.root.appendingPathComponent("relocated")
            try FileManager.default.moveItem(at: fixture.main, to: movedMain)
            let alias = movedMain.appendingPathComponent("nested")
            let ownedCheckout = fixture.root.appendingPathComponent("owned-checkout")
            try FileManager.default.moveItem(at: alias, to: ownedCheckout)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ownedCheckout)
            let repository = try RepositoryTestGitRepository(url: movedMain)
            let blocked = ControlledWorktreeTask()
            let launched = expectation(description: "first writer holds admission")
            let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                if arguments == ["worktree", "lock", "--reason", "held", fixture.linked.path] {
                    launched.fulfill(); return blocked
                }
                let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + movedMain.appendingPathComponent(".git").path] + arguments, inDirectory: movedMain.path)
                GitXTestGitFixture.prepare(task)
                return task
            }
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            XCTAssertTrue(tree.hasBrokenLink)
            XCTAssertNotNil(tree.movedPath)
            let held = expectation(description: "held writer completed")
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
            await fulfillment(of: [launched], timeout: 5)
            let repaired = expectation(description: "captured checkout repaired")
            let captured = expectation(description: "utility capture freezes the owned checkout before alias retarget")
            let initialCaptureCount = service.repairPreparationCount
            let captureObservation = service.observe(\.repairPreparationCount) { observed, _ in
                // swift6-safety-justification: The service publishes successful preparation diagnostics on the main queue.
                MainActor.assumeIsolated {
                    if observed.repairPreparationCount > initialCaptureCount {
                        captured.fulfill()
                    }
                }
            }
            enqueue { service.repairLinks(relativePaths: false) { error in XCTAssertNil(error); repaired.fulfill() } }
            await fulfillment(of: [captured], timeout: 10)
            captureObservation.invalidate()
            let progressed = expectation(description: "next queued writer completes")
            enqueue { service.unlockWorktree(path: ownedCheckout.path) { _, _ in progressed.fulfill() } }
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign.linked)
            let foreignLink = try Data(contentsOf: foreign.linked.appendingPathComponent(".git"))
            let foreignMetadata = try metadata(in: foreign)
            let foreignRefs = try foreign.git(["show-ref", "--head"])
            let foreignHead = try foreign.git(["rev-parse", "HEAD"], in: foreign.linked)
            let ownRefs = try fixture.git(["show-ref", "--head"], in: movedMain)
            blocked.finish(Data())
            await fulfillment(of: [held, repaired, progressed], timeout: 10)
            XCTAssertEqual(try Data(contentsOf: foreign.linked.appendingPathComponent(".git")), foreignLink)
            XCTAssertEqual(try metadata(in: foreign), foreignMetadata)
            XCTAssertEqual(try foreign.git(["show-ref", "--head"]), foreignRefs)
            XCTAssertEqual(try foreign.git(["rev-parse", "HEAD"], in: foreign.linked), foreignHead)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"], in: movedMain), ownRefs)
            let registered = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let ownedCanonical = try fixture.git(["rev-parse", "--show-toplevel"], in: ownedCheckout).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(registered.path, ownedCanonical)
            XCTAssertEqual(try String(contentsOf: movedMain.appendingPathComponent(".git/worktrees/linked/gitdir"), encoding: .utf8), ownedCanonical + "/.git\n")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), foreign.linked.path)
            XCTAssertEqual(try Data(contentsOf: ownedCheckout.appendingPathComponent("marker.txt")), Data("argument-alias-own\n".utf8))
            XCTAssertEqual(try Data(contentsOf: foreign.linked.appendingPathComponent("marker.txt")), Data("argument-alias-foreign\n".utf8))
        }
    #endif

    func testQueuedRepairRejectsAStaleLinkTargetThatBecomesAForeignRegistration() async throws {
        for repositoryWide in [false, true] {
            let fixture = try RepairFixture(label: "stale-target-own")
            let foreign = try RepairFixture(label: "stale-target-foreign")
            defer { fixture.cleanup(); foreign.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let blocked = ControlledWorktreeTask()
            let launched = expectation(description: "first writer holds admission")
            var repairCommands = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched, taskOverride: { arguments in
                if arguments.contains("repair") {
                    repairCommands += 1
                }
                return nil
            })
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            let staleTarget = foreign.main.appendingPathComponent(".git/worktrees/future")
            let link = fixture.linked.appendingPathComponent(".git")
            try Data(("gitdir: " + staleTarget.path + "\n").utf8).write(to: link)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleTarget.path))
            let held = expectation(description: "held writer completed")
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
            await fulfillment(of: [launched], timeout: 5)
            let refused = expectation(description: "new foreign ownership rejected")
            if repositoryWide {
                enqueue { service.repairLinks(relativePaths: false) { error in XCTAssertNotNil(error); refused.fulfill() } }
            } else {
                enqueue { service.repair(worktree: tree, movedTo: fixture.linked.path) { error in XCTAssertNotNil(error); refused.fulfill() } }
            }
            let next = expectation(description: "subsequent queued writer completes")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in next.fulfill() } }
            let future = foreign.root.appendingPathComponent("future")
            _ = try foreign.git(["worktree", "add", "-b", "future", future.path])
            let protectedLinks = [link, foreign.linked.appendingPathComponent(".git"), future.appendingPathComponent(".git")]
            let links = try protectedLinks.map { try Data(contentsOf: $0) }
            let ownMetadata = try metadata(in: fixture)
            let foreignMetadata = try metadata(in: foreign)
            let ownRefs = try fixture.git(["show-ref", "--head"])
            let foreignRefs = try foreign.git(["show-ref", "--head"])
            let linkedHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
            let foreignHead = try foreign.git(["rev-parse", "HEAD"], in: future)
            blocked.finish(Data())
            await fulfillment(of: [held, refused, next], timeout: 10)
            XCTAssertEqual(repairCommands, 0)
            XCTAssertEqual(try protectedLinks.map { try Data(contentsOf: $0) }, links)
            XCTAssertEqual(try metadata(in: fixture), ownMetadata)
            XCTAssertEqual(try metadata(in: foreign), foreignMetadata)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), ownRefs)
            XCTAssertEqual(try foreign.git(["show-ref", "--head"]), foreignRefs)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: fixture.linked), linkedHead)
            XCTAssertEqual(try foreign.git(["rev-parse", "HEAD"], in: future), foreignHead)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), Data("stale-target-own\n".utf8))
            XCTAssertEqual(try Data(contentsOf: future.appendingPathComponent("marker.txt")), Data("stale-target-foreign\n".utf8))
        }
    }

    func testQueuedLocateRejectsForeignFolderReplacementWithoutTouchingEitherRepository() async throws {
        let fixture = try RepairFixture(label: "own")
        let foreign = try RepairFixture(label: "foreign")
        defer { fixture.cleanup(); foreign.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "first writer holds admission")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let selected = fixture.root.appendingPathComponent("selected")
        try FileManager.default.moveItem(at: fixture.linked, to: selected)
        let ownAdmin = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let foreignAdmin = foreign.main.appendingPathComponent(".git/worktrees/linked")
        let protected = [ownAdmin.appendingPathComponent("gitdir"), ownAdmin.appendingPathComponent("HEAD"), ownAdmin.appendingPathComponent("index"),
                         foreignAdmin.appendingPathComponent("gitdir"), foreignAdmin.appendingPathComponent("HEAD"), foreignAdmin.appendingPathComponent("index")]
        let metadata = try protected.map { try Data(contentsOf: $0) }
        let foreignLink = try Data(contentsOf: foreign.linked.appendingPathComponent(".git"))
        let foreignHead = try foreign.git(["rev-parse", "HEAD"], in: foreign.linked)
        let ownRefs = try fixture.git(["show-ref", "--head"])
        let foreignRefs = try foreign.git(["show-ref", "--head"])
        let firstDone = expectation(description: "held writer completed")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); firstDone.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let repairDone = expectation(description: "stale repair rejected")
        enqueue { service.repair(worktree: tree, movedTo: selected.path) { error in XCTAssertNotNil(error); repairDone.fulfill() } }
        let followingDone = expectation(description: "next queued writer released")
        enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in followingDone.fulfill() } }
        try FileManager.default.moveItem(at: selected, to: fixture.root.appendingPathComponent("preserved-own"))
        try FileManager.default.moveItem(at: foreign.linked, to: selected)
        blocked.finish(Data())
        await fulfillment(of: [firstDone, repairDone, followingDone], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git")), foreignLink)
        XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, metadata)
        XCTAssertEqual(try foreign.git(["rev-parse", "HEAD"], in: selected), foreignHead)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), ownRefs)
        XCTAssertEqual(try foreign.git(["show-ref", "--head"]), foreignRefs)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("marker.txt")), Data("foreign\n".utf8))
    }

    func testQueuedLocateRejectsRecreatedAdministrativeRegistrationWithTheSameName() async throws {
        let fixture = try RepairFixture(label: "reuse")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "first writer holds admission")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let selected = fixture.root.appendingPathComponent("selected")
        try FileManager.default.moveItem(at: fixture.linked, to: selected)
        let firstDone = expectation(description: "held writer completed")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); firstDone.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let repairDone = expectation(description: "reused registration rejected")
        enqueue { service.repair(worktree: tree, movedTo: selected.path) { error in XCTAssertNotNil(error); repairDone.fulfill() } }
        let administrative = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let archive = fixture.root.appendingPathComponent("original-admin")
        try FileManager.default.moveItem(at: administrative, to: archive)
        try FileManager.default.copyItem(at: archive, to: administrative)
        let backlink = try Data(contentsOf: administrative.appendingPathComponent("gitdir"))
        let link = try Data(contentsOf: selected.appendingPathComponent(".git"))
        blocked.finish(Data())
        await fulfillment(of: [firstDone, repairDone], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: administrative.appendingPathComponent("gitdir")), backlink)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git")), link)
    }

    func testUnchangedQueuedLocateRepairsTheExactBidirectionalLinks() async throws {
        let fixture = try RepairFixture(label: "valid")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "first writer holds admission")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let head = try fixture.git(["rev-parse", "HEAD"], in: fixture.linked)
        let selected = fixture.root.appendingPathComponent("selected")
        try FileManager.default.moveItem(at: fixture.linked, to: selected)
        let firstDone = expectation(description: "held writer completed")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); firstDone.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let repairDone = expectation(description: "valid queued repair completed")
        enqueue { service.repair(worktree: tree, movedTo: selected.path) { error in XCTAssertNil(error); repairDone.fulfill() } }
        blocked.finish(Data())
        await fulfillment(of: [firstDone, repairDone], timeout: 10)
        let registered = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let selectedCanonical = try fixture.git(["rev-parse", "--show-toplevel"], in: selected).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(registered.path, selectedCanonical)
        let admin = fixture.main.appendingPathComponent(".git/worktrees/linked")
        XCTAssertEqual(try String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8), selectedCanonical + "/.git\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "--absolute-git-dir"], in: selected), try fixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines) + "/worktrees/linked\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: selected), head)
    }

    func testLegacyPruneRequiresAPreviewBeforeDeletingARegistration() async throws {
        let fixture = try RepairFixture(label: "unconfirmed")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused holder"))
        defer { service.cancel() }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let done = expectation(description: "unconfirmed prune refused")
        enqueue { service.pruneWorktrees(reportOnly: false) { _, error in XCTAssertNotNil(error); done.fulfill() } }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
    }

    func testLegacyPruneRejectsNewCandidatesAfterPreviewAndReleasesQueue() async throws {
        let fixture = try RepairFixture(label: "stale-prune")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused holder"))
        defer { service.cancel() }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let previewDone = expectation(description: "preview captured")
        enqueue { service.pruneWorktrees(reportOnly: true) { report, error in XCTAssertNil(error); XCTAssertTrue(report?.contains("linked") == true); previewDone.fulfill() } }
        await fulfillment(of: [previewDone], timeout: 10)
        let second = fixture.root.appendingPathComponent("second")
        _ = try fixture.git(["worktree", "add", "-b", "second", second.path])
        try FileManager.default.removeItem(at: second)
        let done = expectation(description: "changed prune refused")
        enqueue { service.pruneWorktrees(reportOnly: false) { _, error in XCTAssertNotNil(error); done.fulfill() } }
        let queueReleased = expectation(description: "subsequent writer completes")
        enqueue { service.unlockWorktree(path: second.path) { _, _ in queueReleased.fulfill() } }
        await fulfillment(of: [done, queueReleased], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/second").path))
    }

    func testPruneRevalidatesAddedRemovedLockedMovedAndReplacedRegistrationsWhileQueued() async throws {
        for change in ["added", "removed", "locked", "moved", "replaced"] {
            let fixture = try RepairFixture(label: change)
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let blocked = ControlledWorktreeTask()
            let launched = expectation(description: "holder admitted: " + change)
            let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
            defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
            try await ready(service)
            try FileManager.default.removeItem(at: fixture.linked)
            let captured = try await service.preparePrunePreview()
            let preview = try XCTUnwrap(captured)
            XCTAssertTrue(preview.report.contains("linked"))
            let held = expectation(description: "holder completes: " + change)
            enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
            await fulfillment(of: [launched], timeout: 5)
            let renewed = expectation(description: "renewed consent: " + change)
            renewed.assertForOverFulfill = true
            let result = PruneCompletion()
            enqueue { service.prune(confirmedPreview: preview) { updated, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { result.preview = updated; result.error = error as NSError?; renewed.fulfill() }
            } }
            let admin = fixture.main.appendingPathComponent(".git/worktrees/linked")
            switch change {
            case "removed": _ = try fixture.git(["worktree", "prune", "--expire", "now"])
            case "locked": _ = try fixture.git(["worktree", "lock", "--reason", "new lock", fixture.linked.path])
            case "replaced":
                let original = fixture.root.appendingPathComponent("original-registration")
                try FileManager.default.moveItem(at: admin, to: original)
                try FileManager.default.copyItem(at: original, to: admin)
            default:
                let other = fixture.root.appendingPathComponent("other")
                _ = try fixture.git(["worktree", "add", "-b", "other", other.path])
                if change == "moved" {
                    try FileManager.default.moveItem(at: other, to: fixture.root.appendingPathComponent("moved-other"))
                } else {
                    try FileManager.default.removeItem(at: other)
                }
            }
            let before = try metadata(in: fixture)
            blocked.finish(Data())
            await fulfillment(of: [held, renewed], timeout: 10)
            XCTAssertNil(result.error)
            let current = try XCTUnwrap(result.preview)
            XCTAssertEqual(try metadata(in: fixture), before, change)
            if change == "locked" || change == "removed" {
                XCTAssertTrue(current.report.isEmpty)
            }
            let replay = await confirmationError(service, preview: preview)
            XCTAssertNotNil(replay)
            service.discardPrunePreview(current)
            let cancelledError = await confirmationError(service, preview: current)
            XCTAssertNotNil(cancelledError)
            let released = expectation(description: "next writer: " + change)
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in released.fulfill() } }
            await fulfillment(of: [released], timeout: 10)
            if change == "moved" {
                XCTAssertFalse(try fixture.git(["rev-parse", "HEAD"], in: fixture.root.appendingPathComponent("moved-other")).isEmpty)
            }
        }
    }

    func testUnchangedQueuedPruneExecutesOnlyAfterFreshValidationAndReleasesQueue() async throws {
        let fixture = try RepairFixture(label: "approved")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "holder admitted")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let captured = try await service.preparePrunePreview()
        let preview = try XCTUnwrap(captured)
        let held = expectation(description: "holder completes")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let done = expectation(description: "confirmed prune completes")
        enqueue { service.prune(confirmedPreview: preview) { updated, error in XCTAssertNil(updated); XCTAssertNil(error); done.fulfill() } }
        let next = expectation(description: "following writer completes")
        enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in next.fulfill() } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
        blocked.finish(Data())
        await fulfillment(of: [held, done, next], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
        XCTAssertEqual(service.worktrees.count, 1)
    }

    func testQueuedPruneRequiresRenewedConsentWhenCommonDirectoryAliasChanges() async throws {
        let fixture = try RepairFixture(label: "prune-alias-own")
        let foreign = try RepairFixture(label: "prune-alias-foreign")
        defer { fixture.cleanup(); foreign.cleanup() }
        // Keep revision and candidate text identical while administrative ownership changes.
        let head = try fixture.git(["rev-parse", "refs/heads/topic"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try foreign.git(["fetch", fixture.main.path, "topic"])
        _ = try foreign.git(["update-ref", "refs/heads/topic", head])
        let alias = fixture.root.appendingPathComponent("common-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.main.appendingPathComponent(".git"))
        let commonLink = fixture.main.appendingPathComponent(".git/worktrees/linked/commondir")
        try Data((alias.path + "\n").utf8).write(to: commonLink)
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "holder admitted")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let captured = try await service.preparePrunePreview()
        let preview = try XCTUnwrap(captured)
        let held = expectation(description: "holder completed")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); held.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let renewed = expectation(description: "changed ownership requires new consent")
        let result = PruneCompletion()
        enqueue { service.prune(confirmedPreview: preview) { updated, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { result.preview = updated; result.error = error as NSError?; renewed.fulfill() }
        } }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign.main.appendingPathComponent(".git"))
        let ownMetadata = try metadata(in: fixture)
        let foreignMetadata = try metadata(in: foreign)
        let ownRefs = try fixture.git(["show-ref", "--head"])
        let foreignRefs = try foreign.git(["show-ref", "--head"])
        blocked.finish(Data())
        await fulfillment(of: [held, renewed], timeout: 10)
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.preview)
        XCTAssertEqual(result.preview?.report, preview.report)
        XCTAssertEqual(try metadata(in: fixture), ownMetadata)
        XCTAssertEqual(try metadata(in: foreign), foreignMetadata)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), ownRefs)
        XCTAssertEqual(try foreign.git(["show-ref", "--head"]), foreignRefs)
        if let updated = result.preview {
            service.discardPrunePreview(updated)
        }
        let next = expectation(description: "renewed consent releases shared queue")
        enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in next.fulfill() } }
        await fulfillment(of: [next], timeout: 10)
    }

    func testPrunePreviewCancellationReleasesSharedQueueAndIgnoresLateReport() async throws {
        let fixture = try RepairFixture(label: "cancel")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let report = ControlledWorktreeTask()
        let reading = expectation(description: "report started")
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            guard arguments == ["worktree", "prune", "--dry-run", "--verbose"] else { return nil }
            reading.fulfill(); return report
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer { service.cancel(); following.cancel(); report.finish(nil, error: CancellationError()) }
        try await ready(service); try await ready(following)
        let cancelled = expectation(description: "cancel completes once")
        cancelled.assertForOverFulfill = true
        enqueue { service.preparePrunePreview { preview, error in XCTAssertNil(preview); XCTAssertNotNil(error); cancelled.fulfill() } }
        await fulfillment(of: [reading], timeout: 10)
        let progressed = expectation(description: "shared queue progresses")
        enqueue { following.lockWorktree(path: fixture.linked.path, reason: "next") { _, error in XCTAssertNil(error); progressed.fulfill() } }
        service.cancel()
        await fulfillment(of: [cancelled, progressed], timeout: 10)
        XCTAssertTrue(report.wasCancelled)
        report.finish(Data("Removing worktrees/linked: fixture\n".utf8))
        let drained = expectation(description: "late report drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.appendingPathComponent(".git/worktrees/linked").path))
    }

    func testPruneRejectsReplacedRepositoryContextAndPreservesItsInventory() async throws {
        let fixture = try RepairFixture(label: "context")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"))
        defer { service.cancel() }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let captured = try await service.preparePrunePreview()
        let preview = try XCTUnwrap(captured)
        let gitDirectory = fixture.main.appendingPathComponent(".git")
        let original = fixture.root.appendingPathComponent("original-git")
        try FileManager.default.moveItem(at: gitDirectory, to: original)
        try FileManager.default.copyItem(at: original, to: gitDirectory)
        let before = try metadata(in: fixture)
        let contextError = await confirmationError(service, preview: preview)
        XCTAssertNotNil(contextError)
        XCTAssertEqual(try metadata(in: fixture), before)
        let next = expectation(description: "context rejection releases queue")
        enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in next.fulfill() } }
        await fulfillment(of: [next], timeout: 10)
    }

    func testGitSuccessWithoutRepairingTheCapturedLinksFailsPostcondition() async throws {
        for repositoryWide in [false, true] {
            let fixture = try RepairFixture(label: "postcondition")
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                arguments.contains("repair") ? PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil) : nil
            })
            defer { service.cancel() }
            try await ready(service)
            let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
            try FileManager.default.removeItem(at: fixture.linked.appendingPathComponent(".git"))
            let done = expectation(description: "failed bidirectional proof")
            if repositoryWide {
                enqueue { service.repairLinks(relativePaths: false) { error in XCTAssertNotNil(error); done.fulfill() } }
            } else {
                enqueue { service.repair(worktree: tree, movedTo: fixture.linked.path) { error in XCTAssertNotNil(error); done.fulfill() } }
            }
            await fulfillment(of: [done], timeout: 10)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.appendingPathComponent(".git").path))
            let next = expectation(description: "failed proof releases queue")
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in next.fulfill() } }
            await fulfillment(of: [next], timeout: 10)
        }
    }

    func testQueuedLocateRejectsAReappearedForeignSiblingWithoutTouchingEitherRepository() async throws {
        try await assertQueuedRepairRejectsReappearedForeignSibling(repositoryWide: false)
    }

    func testQueuedRepositoryRepairRejectsAReappearedForeignSiblingWithoutTouchingEitherRepository() async throws {
        try await assertQueuedRepairRejectsReappearedForeignSibling(repositoryWide: true)
    }

    private func assertQueuedRepairRejectsReappearedForeignSibling(repositoryWide: Bool) async throws {
        let fixture = try RepairFixture(label: "missing-sibling-own")
        let foreign = try RepairFixture(label: "missing-sibling-foreign")
        defer { fixture.cleanup(); foreign.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let blocked = ControlledWorktreeTask()
        let launched = expectation(description: "first writer holds admission")
        let service = makeService(repository: repository, fixture: fixture, blocked: blocked, launched: launched)
        defer { service.cancel(); blocked.finish(nil, error: CancellationError()) }
        try await ready(service)
        let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
        let missing = fixture.root.appendingPathComponent("missing-sibling")
        _ = try fixture.git(["worktree", "add", "-b", "missing-sibling", missing.path])
        try FileManager.default.moveItem(at: missing, to: fixture.root.appendingPathComponent("preserved-missing-sibling"))
        let discovered = expectation(description: "missing sibling registration discovered")
        let observation = service.observe(\.worktrees) { _, _ in discovered.fulfill() }
        service.refresh()
        await fulfillment(of: [discovered], timeout: 10)
        observation.invalidate()
        let unavailable = try XCTUnwrap(service.worktree(forBranch: "refs/heads/missing-sibling"))
        XCTAssertFalse(unavailable.folderExists)
        XCTAssertNil(unavailable.movedPath)
        let selected = repositoryWide ? fixture.linked : fixture.root.appendingPathComponent("selected")
        if !repositoryWide {
            try FileManager.default.moveItem(at: fixture.linked, to: selected)
        }
        let ownAdmin = fixture.main.appendingPathComponent(".git/worktrees/linked")
        let missingAdmin = fixture.main.appendingPathComponent(".git/worktrees/missing-sibling")
        let foreignAdmin = foreign.main.appendingPathComponent(".git/worktrees/linked")
        let protected = [ownAdmin, missingAdmin, foreignAdmin].flatMap { directory in
            ["gitdir", "commondir", "HEAD", "index"].map { directory.appendingPathComponent($0) }
        }
        let metadata = try protected.map { try Data(contentsOf: $0) }
        let ownLink = try Data(contentsOf: selected.appendingPathComponent(".git"))
        let foreignLink = try Data(contentsOf: foreign.linked.appendingPathComponent(".git"))
        let ownHead = try fixture.git(["rev-parse", "HEAD"], in: selected)
        let foreignHead = try foreign.git(["rev-parse", "HEAD"], in: foreign.linked)
        let ownRefs = try fixture.git(["show-ref", "--head"])
        let foreignRefs = try foreign.git(["show-ref", "--head"])
        let firstDone = expectation(description: "held writer completed")
        enqueue { service.lockWorktree(path: fixture.linked.path, reason: "held") { _, error in XCTAssertNil(error); firstDone.fulfill() } }
        await fulfillment(of: [launched], timeout: 5)
        let repairDone = expectation(description: "reappeared sibling ownership rejected")
        if repositoryWide {
            enqueue { service.repairLinks(relativePaths: false) { error in XCTAssertNotNil(error); repairDone.fulfill() } }
        } else {
            enqueue { service.repair(worktree: tree, movedTo: selected.path) { error in XCTAssertNotNil(error); repairDone.fulfill() } }
        }
        let followingDone = expectation(description: "ownership rejection releases next writer")
        enqueue { service.unlockWorktree(path: fixture.linked.path) { _, _ in followingDone.fulfill() } }
        try FileManager.default.moveItem(at: foreign.linked, to: missing)
        // The administrative inventory is identical; only the skipped folder has reappeared.
        XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, metadata)
        blocked.finish(Data())
        await fulfillment(of: [firstDone, repairDone, followingDone], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git")), ownLink)
        XCTAssertEqual(try Data(contentsOf: missing.appendingPathComponent(".git")), foreignLink)
        XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, metadata)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: selected), ownHead)
        XCTAssertEqual(try foreign.git(["rev-parse", "HEAD"], in: missing), foreignHead)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), ownRefs)
        XCTAssertEqual(try foreign.git(["show-ref", "--head"]), foreignRefs)
        XCTAssertEqual(try Data(contentsOf: missing.appendingPathComponent("marker.txt")), Data("missing-sibling-foreign\n".utf8))
    }

    func testPrunePreviewRejectsChangedUnreadableAndIncompleteEvidenceAndReleasesQueue() async throws {
        for change in ["locked", "unreadable", "report-error", "incomplete-report", "invalid-utf8"] {
            let fixture = try RepairFixture(label: "preview-" + change)
            defer { fixture.cleanup() }
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let report = ControlledWorktreeTask()
            let reading = expectation(description: "preview report pending: " + change)
            var pruneCommands = 0
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments == ["worktree", "prune", "--dry-run", "--verbose"] {
                    reading.fulfill(); return report
                }
                if arguments == ["worktree", "unlock", fixture.linked.path] {
                    return PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil)
                }
                if arguments == ["worktree", "prune"] {
                    pruneCommands += 1
                }
                return nil
            })
            defer { service.cancel(); report.finish(nil, error: CancellationError()) }
            try await ready(service)
            try FileManager.default.removeItem(at: fixture.linked)
            let done = expectation(description: "unsafe preview rejected: " + change)
            done.assertForOverFulfill = true
            let result = PruneCompletion()
            enqueue { service.preparePrunePreview { preview, error in
                // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; done.fulfill() }
            } }
            await fulfillment(of: [reading], timeout: 10)
            let admin = fixture.main.appendingPathComponent(".git/worktrees/linked")
            let backlink = admin.appendingPathComponent("gitdir")
            let marker = backlink.appendingPathComponent("external-marker")
            if change == "unreadable" {
                try FileManager.default.removeItem(at: backlink)
                try FileManager.default.createDirectory(at: backlink, withIntermediateDirectories: false)
                try Data("external replacement\n".utf8).write(to: marker)
            } else if change == "locked" {
                try Data("external lock\n".utf8).write(to: admin.appendingPathComponent("locked"))
            }
            let protected = ["commondir", "HEAD", "index"].map { admin.appendingPathComponent($0) }
            let before = try protected.map { try Data(contentsOf: $0) }
            if change == "report-error" {
                report.finish(nil, error: NSError(domain: "fixture", code: 1))
            } else if change == "incomplete-report" {
                report.finish(nil)
            } else if change == "invalid-utf8" {
                report.finish(Data([255]))
            } else {
                report.finish(Data("Removing worktrees/linked: gitdir file points to non-existent location\n".utf8))
            }
            await fulfillment(of: [done], timeout: 10)
            XCTAssertNil(result.preview)
            XCTAssertNotNil(result.error)
            XCTAssertEqual(try protected.map { try Data(contentsOf: $0) }, before)
            XCTAssertEqual(pruneCommands, 0)
            if change == "unreadable" {
                XCTAssertEqual(try Data(contentsOf: marker), Data("external replacement\n".utf8))
            } else if change == "locked" {
                XCTAssertEqual(try Data(contentsOf: admin.appendingPathComponent("locked")), Data("external lock\n".utf8))
            }
            let progressed = expectation(description: "failed preview releases queue: " + change)
            enqueue { service.unlockWorktree(path: fixture.linked.path) { _, error in XCTAssertNotNil(error); progressed.fulfill() } }
            await fulfillment(of: [progressed], timeout: 5)
        }
    }

    func testCapabilityLossAndClosureInvalidateCapturedPruneConsent() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for close in [true, false] {
            let fixture = try RepairFixture(label: close ? "closed-consent" : "lost-capability")
            defer { fixture.cleanup() }
            let oldGit = fixture.root.appendingPathComponent("older-git")
            try writeVerificationGitProxy(oldGit)
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
                if arguments == ["--version"], defaults.string(forKey: "gitExecutable") == oldGit.path {
                    return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.47.9"], inDirectory: nil)
                }
                return nil
            })
            defer { service.cancel() }
            try await ready(service)
            try FileManager.default.removeItem(at: fixture.linked)
            let captured = try await service.preparePrunePreview()
            let preview = try XCTUnwrap(captured)
            let before = try metadata(in: fixture)
            if close {
                service.cancel()
            } else {
                let unavailable = expectation(description: "older selected Git is unavailable")
                let observation = service.observe(\.gitVersion) { observed, _ in
                    // swift6-safety-justification: The service publishes capability changes on the main queue.
                    MainActor.assumeIsolated {
                        if observed.gitVersion == "git version 2.47.9" {
                            unavailable.fulfill()
                        }
                    }
                }
                defer { observation.invalidate() }
                defaults.set(oldGit.path, forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
                await fulfillment(of: [unavailable], timeout: 10)
                XCTAssertFalse(service.isSupported)
            }
            let rejected = expectation(description: "unavailable service refuses new preview")
            enqueue { service.preparePrunePreview { preview, error in XCTAssertNil(preview); XCTAssertNotNil(error); rejected.fulfill() } }
            await fulfillment(of: [rejected], timeout: 5)
            let confirmation = await confirmationError(service, preview: preview)
            XCTAssertNotNil(confirmation)
            XCTAssertEqual(try metadata(in: fixture), before)
        }
    }

    func testExecutableReplacementAfterCapabilityCheckRejectsPreviewWithoutLaunchingGit() async throws {
        let fixture = try RepairFixture(label: "replaced-executable")
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let executable = fixture.root.appendingPathComponent("selected-git")
        try writeVerificationGitProxy(executable)
        defaults.set(executable.path, forKey: "gitExecutable")
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        var reportCommands = 0
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if arguments == ["worktree", "prune", "--dry-run", "--verbose"] {
                reportCommands += 1
            }
            return nil
        })
        defer { service.cancel() }
        try await ready(service)
        try FileManager.default.removeItem(at: fixture.linked)
        let before = try metadata(in: fixture)
        // Atomic replacement changes file identity while the selected preference stays identical.
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let refused = expectation(description: "replacement since capability check refused")
        enqueue { service.preparePrunePreview { preview, error in XCTAssertNil(preview); XCTAssertNotNil(error); refused.fulfill() } }
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(reportCommands, 0)
        XCTAssertEqual(try metadata(in: fixture), before)
    }

    func testExecutableUpgradeDuringCapabilityProbeRecoversAtTheSamePathWithoutRevivingConsent() async throws {
        let fixture = try RepairFixture(label: "upgrade-during-capability-probe")
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let executable = fixture.root.appendingPathComponent("selected-git")
        try writeVersionedGitProxy(executable, version: "2.50.1", atomic: true)
        defaults.set(executable.path, forKey: "gitExecutable")
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        var probes: [ControlledWorktreeTask] = []
        var writes = 0
        var nextProbe: XCTestExpectation?
        var nextDiscovery: XCTestExpectation?
        let service = makeService(repository: repository, fixture: fixture,
                                  blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"),
                                  taskOverride: { arguments in
                                      if arguments == ["--version"] {
                                          let task = ControlledWorktreeTask()
                                          probes.append(task)
                                          nextProbe?.fulfill(); nextProbe = nil
                                          return task
                                      }
                                      if arguments == ["worktree", "list", "--porcelain", "-z"] {
                                          nextDiscovery?.fulfill(); nextDiscovery = nil
                                      } else if arguments.first == "worktree", arguments.count > 1,
                                                ["add", "remove", "lock", "unlock", "repair"].contains(arguments[1])
                                                || arguments == ["worktree", "prune"]
                                      {
                                          writes += 1
                                      }
                                      return nil
                                  })
        defer {
            service.cancel()
            probes.forEach { $0.finish(nil, error: CancellationError()) }
        }
        let firstPublished = expectation(description: "initial real Git inventory published")
        let initialObservation = service.observe(\.worktrees) { _, _ in firstPublished.fulfill() }
        service.start()
        XCTAssertEqual(probes.count, 1)
        try XCTUnwrap(probes.first).finish(Data("git version 2.50.1".utf8))
        await fulfillment(of: [firstPublished], timeout: 10)
        initialObservation.invalidate()
        XCTAssertTrue(service.isSupported)
        let capturedConsent = try await service.preparePrunePreview()
        let oldConsent = try XCTUnwrap(capturedConsent)
        let before = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let link = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let marker = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let initialIdentity = try WorktreeFileFingerprint.capture(path: executable.path)
        try writeVersionedGitProxy(executable, version: "2.50.2", atomic: true)
        let secondIdentity = try WorktreeFileFingerprint.capture(path: executable.path)
        XCTAssertNotEqual(secondIdentity, initialIdentity)
        service.refresh()
        XCTAssertEqual(probes.count, 2)
        let upgrading = try XCTUnwrap(probes.last)
        // Upgrade again while the second probe remains in flight. The old output cannot
        // certify the replacement, but the failed certification must remain recoverable.
        try writeVersionedGitProxy(executable, version: "2.50.3", atomic: true)
        XCTAssertNotEqual(try WorktreeFileFingerprint.capture(path: executable.path), secondIdentity)
        upgrading.finish(Data("git version 2.50.2".utf8))
        XCTAssertFalse(service.isSupported)
        let oldConsentError = await confirmationError(service, preview: oldConsent)
        XCTAssertNotNil(oldConsentError)
        let reprobed = expectation(description: "same-path request notices replacement after failed certification")
        reprobed.assertForOverFulfill = true
        nextProbe = reprobed
        let rejected = expectation(description: "writer blocked until capability is checked")
        enqueue {
            service.lockWorktree(path: fixture.linked.path, reason: "must-not-launch") { _, error in
                XCTAssertNotNil(error); rejected.fulfill()
            }
        }
        await fulfillment(of: [rejected, reprobed], timeout: 5)
        XCTAssertEqual(writes, 0)
        service.refresh() // An already in-flight unchanged probe is not duplicated.
        XCTAssertEqual(probes.count, 3)
        let current = try XCTUnwrap(probes.indices.contains(2) ? probes[2] : nil)
        let rediscovered = expectation(description: "fresh certified executable launches ordinary discovery")
        rediscovered.assertForOverFulfill = true
        nextDiscovery = rediscovered
        current.finish(Data("git version 2.50.3".utf8))
        await fulfillment(of: [rediscovered], timeout: 5)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.gitVersion, "git version 2.50.3")
        let capturedFreshConsent = try await service.preparePrunePreview()
        let freshConsent = try XCTUnwrap(capturedFreshConsent)
        service.discardPrunePreview(freshConsent)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try metadata(in: fixture), before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), link)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), marker)
    }

    private func writeVerificationGitProxy(_ path: URL) throws {
        try "#!/bin/sh\nexec /usr/bin/git \"$@\"\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private final class PruneCompletion {
        var preview: PBWorktreePrunePreview?
        var error: NSError?
    }

    private func characterizeRealWriterReconciliation(failsReconciliation: Bool) async throws {
        let fixture = try RepairFixture(label: "writer-reconciliation-\(failsReconciliation)")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let reconciliation = ControlledWorktreeTask()
        let reading = expectation(description: "completed real writer starts reconciliation")
        reading.assertForOverFulfill = true
        let listingArguments = ["worktree", "list", "--porcelain", "-z"]
        let lockArguments = ["worktree", "lock", "--reason", "characterized writer", fixture.linked.path]
        let unlockArguments = ["worktree", "unlock", fixture.linked.path]
        var holdNextDiscovery = false
        var firstArguments: [[String]] = []
        var followingArguments: [[String]] = []
        let service = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            firstArguments.append(arguments)
            if holdNextDiscovery, arguments == listingArguments {
                holdNextDiscovery = false
                reading.fulfill()
                return reconciliation
            }
            return nil
        })
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            followingArguments.append(arguments)
            return nil
        })
        defer { service.cancel(); following.cancel(); reconciliation.finish(nil, error: CancellationError()) }
        try await ready(service)
        try await ready(following)
        let initialMetadata = try metadata(in: fixture)
        let refs = try fixture.git(["show-ref", "--head"])
        let gitfile = try Data(contentsOf: fixture.linked.appendingPathComponent(".git"))
        let mainHEAD = try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD"))
        let mainIndex = try Data(contentsOf: fixture.main.appendingPathComponent(".git/index"))
        let mainContent = try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt"))
        let linkedContent = try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt"))
        let results = WriterCharacterizationResult()
        let firstCompleted = expectation(description: "real writer completion follows reconciliation")
        let followingCompleted = expectation(description: "following real writer reconciles")
        firstCompleted.assertForOverFulfill = true
        followingCompleted.assertForOverFulfill = true
        holdNextDiscovery = true
        enqueue {
            service.lockWorktree(path: fixture.linked.path, reason: "characterized writer") { _, error in
                // swift6-safety-justification: The service delivers these lifecycle completions synchronously on the main queue.
                MainActor.assumeIsolated {
                    results.error = error as NSError?
                    results.names.append("first")
                    XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.isLocked, !failsReconciliation)
                    XCTAssertFalse(followingArguments.contains(unlockArguments), "FIFO releases only after delivering this completion")
                    firstCompleted.fulfill()
                }
            }
        }
        await fulfillment(of: [reading], timeout: 10)
        XCTAssertTrue(results.names.isEmpty)
        let lockFile = fixture.main.appendingPathComponent(".git/worktrees/linked/locked")
        XCTAssertEqual(try String(contentsOf: lockFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "characterized writer")
        XCTAssertFalse(service.worktree(forBranch: "refs/heads/topic")?.isLocked ?? true, "The last snapshot stays unchanged while reconciliation is pending")
        enqueue {
            following.unlockWorktree(path: fixture.linked.path) { _, error in
                // swift6-safety-justification: The service delivers these lifecycle completions synchronously on the main queue.
                MainActor.assumeIsolated {
                    XCTAssertNil(error)
                    results.names.append("following")
                    followingCompleted.fulfill()
                }
            }
        }
        XCTAssertFalse(followingArguments.contains(unlockArguments))
        XCTAssertEqual(firstArguments.filter { $0 == lockArguments }.count, 1)
        if failsReconciliation {
            reconciliation.finish(nil, error: CancellationError())
        } else {
            try reconciliation.finish(Data(fixture.git(listingArguments).utf8))
        }
        await fulfillment(of: [firstCompleted, followingCompleted], timeout: 10)
        XCTAssertEqual(results.names, ["first", "following"])
        if failsReconciliation {
            let error = try XCTUnwrap(results.error)
            XCTAssertEqual(error.domain, "PBGitXErrorDomain")
            XCTAssertTrue(error.localizedFailureReason?.contains("Git completed the operation, but worktree state could not be reread") == true)
            XCTAssertTrue(error.userInfo[NSUnderlyingErrorKey] is CancellationError)
        } else {
            XCTAssertNil(results.error)
            XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.lockReason, "characterized writer")
        }
        XCTAssertEqual(firstArguments.filter { $0 == lockArguments }.count, 1)
        XCTAssertEqual(followingArguments.filter { $0 == unlockArguments }.count, 1)
        XCTAssertFalse(following.worktree(forBranch: "refs/heads/topic")?.isLocked ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFile.path))
        XCTAssertEqual(try metadata(in: fixture), initialMetadata)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/HEAD")), mainHEAD)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent("marker.txt")), mainContent)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), linkedContent)
    }

    @MainActor
    private final class WriterCharacterizationResult {
        var error: NSError?
        var names: [String] = []
    }

    private func confirmationError(_ service: PBRepositoryWorktreeService, preview: PBWorktreePrunePreview) async -> NSError? {
        let done = expectation(description: "confirmation returned")
        let result = PruneCompletion()
        enqueue { service.prune(confirmedPreview: preview) { updated, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { result.preview = updated; result.error = error as NSError?; done.fulfill() }
        } }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertNil(result.preview)
        return result.error
    }

    private func metadata(in fixture: RepairFixture) throws -> [String: Data] {
        let worktrees = fixture.main.appendingPathComponent(".git/worktrees")
        guard FileManager.default.fileExists(atPath: worktrees.path) else { return [:] }
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: worktrees.path) {
            for file in ["gitdir", "commondir", "HEAD", "index", "locked"] {
                let path = worktrees.appendingPathComponent(name).appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: path.path) {
                    result[name + "/" + file] = try Data(contentsOf: path)
                }
            }
        }
        return result
    }

    private func enqueue(_ operation: () -> Void) {
        operation()
    }

    private func makeService(repository: PBGitRepository, fixture: RepairFixture, blocked: ControlledWorktreeTask, launched: XCTestExpectation, taskOverride: (([String]) -> PBTask?)? = nil) -> PBRepositoryWorktreeService {
        PBRepositoryWorktreeService(repository: repository) { arguments in
            if let task = taskOverride?(arguments) {
                return task
            }
            if arguments == ["worktree", "lock", "--reason", "held", fixture.linked.path] {
                launched.fulfill(); return blocked
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
    }

    private func ready(_ service: PBRepositoryWorktreeService, expectedWorktreeCount: Int = 2) async throws {
        let published = expectation(description: "initial worktrees discovered")
        let observation = service.observe(\.worktrees) { _, _ in published.fulfill() }
        defer { observation.invalidate() }
        service.start()
        await fulfillment(of: [published], timeout: 10)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.worktrees.count, expectedWorktreeCount)
    }

    private final class RepairFixture {
        let root: URL
        let main: URL
        let linked: URL
        init(label: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-repair-safety-\(UUID().uuidString)")
            main = root.appendingPathComponent("main"); linked = root.appendingPathComponent("linked")
            do {
                try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
                _ = try git(["init", "-b", "main"])
                _ = try git(["config", "user.name", "Worktree Fixture"])
                _ = try git(["config", "user.email", "fixture@gitx.invalid"])
                try (label + "\n").write(to: main.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
                _ = try git(["add", "marker.txt"])
                _ = try git(["commit", "-m", label])
                _ = try git(["worktree", "add", "-b", "topic", linked.path])
            } catch {
                cleanup()
                throw error
            }
        }

        func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
            let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: (directory ?? main).path)
            GitXTestGitFixture.prepare(task); try task.launch()
            return String(decoding: task.standardOutputData, as: UTF8.self)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
