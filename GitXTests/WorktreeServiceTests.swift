import Foundation
import XCTest

// swift6-safety-justification: The lock protects every callback, output, and cancellation access, including delivery from the discovery queue.
private final nonisolated class ControlledWorktreeTask: PBTask, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    private var cancelled = false

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

    func finish(_ data: Data?, error: Error? = nil) {
        lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
        callback?(data, error)
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
final class WorktreeServiceTests: XCTestCase {
    private let snapshot = Data("worktree /main\0HEAD abc\0branch refs/heads/main\0\0worktree /linked\0HEAD def\0branch refs/heads/topic\0locked offline disk\0\0".utf8)
    private let discoveryArguments = ["worktree", "list", "--porcelain", "-z"]

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

    func testFailedMutationPropagatesErrorAndReleasesNextWriterWithoutDiscovery() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first)
        try await start(second)
        let completions = WorktreeCompletionRecorder()
        let failed = expectation(description: "failed mutation completed")
        let completed = expectation(description: "next mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        enqueueLock(first.service, reason: "first") { output, error in
            XCTAssertNil(output)
            XCTAssertEqual(error?.localizedFailureReason, "Git refused lock")
            XCTAssertEqual((error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain, "fixture")
            completions.names.append("failed"); failed.fulfill()
        }
        enqueueUnlock(second.service) { _, error in
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
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
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

    func testCancellingPostMutationDiscoveryReleasesFIFOAndIgnoresLateCompletion() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first)
        try await start(second)
        let completions = WorktreeCompletionRecorder()
        let cancelled = expectation(description: "post-mutation discovery cancelled")
        let completed = expectation(description: "next mutation completed")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        enqueueLock(first.service, reason: "first") { output, error in
            XCTAssertNil(output)
            XCTAssertTrue(error?.localizedFailureReason?.contains("worktree state could not be reread") == true)
            XCTAssertTrue(error?.userInfo[NSUnderlyingErrorKey] is CancellationError)
            completions.names.append("cancelled"); cancelled.fulfill()
        }
        enqueueUnlock(second.service) { _, error in
            XCTAssertNil(error)
            completions.names.append("next"); completed.fulfill()
        }
        let refreshed = first.tasks.expect(discoveryArguments)
        try first.tasks.task(firstArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        let lateDiscovery = try first.tasks.task(discoveryArguments, occurrence: 1)
        let nextStarted = second.tasks.expect(secondArguments)
        first.service.cancel()
        await fulfillment(of: [cancelled, nextStarted], timeout: 5)
        XCTAssertTrue(lateDiscovery.wasCancelled)
        XCTAssertEqual(completions.names, ["cancelled"])
        lateDiscovery.finish(Data("worktree /late\0HEAD late\0branch refs/heads/late\0\0".utf8))
        await drainMainQueue()
        XCTAssertEqual(first.service.worktrees.map(\.path), ["/main", "/linked"])
        XCTAssertEqual(completions.names, ["cancelled"])
        XCTAssertEqual(second.tasks.requests.filter { $0.arguments == discoveryArguments }.count, 1)

        let secondDiscovery = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data())
        await fulfillment(of: [secondDiscovery], timeout: 5)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions.names, ["cancelled", "next"])
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

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue completion boundary")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    private func start(_ fixture: WorktreeMutationFixture.Service) async throws {
        let requested = fixture.tasks.expect(discoveryArguments)
        fixture.service.start()
        try fixture.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
        await fulfillment(of: [requested], timeout: 5)
        try fixture.tasks.task(discoveryArguments).finish(snapshot)
        await drainMainQueue()
        XCTAssertTrue(fixture.service.isSupported)
        XCTAssertEqual(fixture.service.worktrees.count, 2)
    }

    /// Calling the completion selectors synchronously preserves immediate FIFO admission;
    /// their imported async alternatives would suspend before the assertions can observe it.
    private func enqueueLock(_ service: PBRepositoryWorktreeService, reason: String, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        service.lockWorktree(path: "/linked", reason: reason) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }

    private func enqueueUnlock(_ service: PBRepositoryWorktreeService, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        service.unlockWorktree(path: "/linked") { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }
}
