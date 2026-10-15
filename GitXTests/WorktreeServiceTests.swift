import Foundation
import GitXCore
import OSLog
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

// swift6-safety-justification: The lock protects timeout state and the semaphore synchronizes the utility worker with its main-actor owner.
private final nonisolated class WorktreeWorkerCheckpoint: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    var didTimeout: Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }

    func wait() {
        let result = semaphore.wait(timeout: .now() + 10)
        lock.lock(); timedOut = result == .timedOut; lock.unlock()
    }

    func resume() {
        semaphore.signal()
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
        for currentClipped in [false, true] {
            defaults.set("/usr/bin/git", forKey: "gitExecutable")
            let fixture = try WorktreeMutationFixture()
            defer { fixture.cleanup() }
            let installed = fixture.makeService()
            let service = installed.service
            try await start(installed)
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
            current.setTruncationFlags(standardOutput: currentClipped)
            // In the broken implementation this is the outer, superseded task stored in
            // self.versionTask after recursive checkVersion returns. Its flags must not
            // decide whether the newest-generation task output is complete.
            for obsolete in probes.dropFirst(2) {
                obsolete.task.setTruncationFlags(standardOutput: !currentClipped)
            }
            let version = "git version 2.50.1"
            current.finish(Data(version.utf8))
            await drainMainQueue()
            XCTAssertEqual(service.isSupported, !currentClipped)
            XCTAssertEqual(service.gitVersion, currentClipped ? nil : version)
            for obsolete in probes.dropFirst(2) {
                obsolete.task.finish(Data("git version 1.0.0".utf8))
            }
            oldRead.finish(nil, error: CancellationError())
            await drainMainQueue()
            XCTAssertEqual(service.isSupported, !currentClipped)
            XCTAssertEqual(service.gitVersion, currentClipped ? nil : version)
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
        try await start(installed)
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
        for obsolete in probes.dropFirst(2) {
            obsolete.task.finish(Data("git version 1.0.0".utf8))
        }
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

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue completion boundary")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    private func start(_ fixture: WorktreeMutationFixture.Service) async throws {
        let requested = fixture.tasks.expect(discoveryArguments)
        let published = expectation(description: "initial worktree snapshot published")
        let observation = fixture.service.observe(\.worktrees) { _, _ in published.fulfill() }
        defer { observation.invalidate() }
        fixture.service.start()
        try fixture.tasks.task(["--version"]).finish(Data("git version 2.48.0".utf8))
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

@MainActor
final class WorktreeRepairSafetyTests: XCTestCase {
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

    func testRepairPreparationKeepsMainActorResponsiveAndReservesFIFOBeforeUtilityCapture() async throws {
        let fixture = try RepairFixture(label: "utility-worker-fifo")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let workerEntered = expectation(description: "actual repair evidence worker begins")
        let checkpoint = WorktreeWorkerCheckpoint()
        var repairCommands = 0
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
            if arguments.contains("repair") {
                repairCommands += 1
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }, repairPreparationObserver: {
            workerEntered.fulfill()
            checkpoint.wait()
        })
        var followingCommands = 0
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: {
            arguments in if arguments.contains("lock") {
                followingCommands += 1
            }; return nil
        })
        defer { checkpoint.resume(); service.cancel(); following.cancel() }
        try await ready(service); try await ready(following)
        let result = RepairCompletion()
        let prepared = expectation(description: "prepared once after worker resumes")
        prepared.assertForOverFulfill = true
        enqueue { service.prepareRepairLinks(relativePaths: false) { preview, error in
            // swift6-safety-justification: The service delivers preview completion on the main queue.
            MainActor.assumeIsolated { result.preview = preview; result.error = error as NSError?; prepared.fulfill() }
        } }
        await fulfillment(of: [workerEntered], timeout: 5)
        let mainProgress = expectation(description: "main actor continues while inventory worker is held")
        DispatchQueue.main.async { mainProgress.fulfill() }
        await fulfillment(of: [mainProgress], timeout: 5)
        XCTAssertFalse(checkpoint.didTimeout)
        XCTAssertNil(result.preview)
        XCTAssertEqual(repairCommands, 0)
        let followingDone = expectation(description: "following writer runs only after preparation releases its reservation")
        enqueue { following.lockWorktree(path: fixture.linked.path, reason: "after utility capture") { _, error in XCTAssertNil(error); followingDone.fulfill() } }
        XCTAssertEqual(followingCommands, 0)
        checkpoint.resume()
        await fulfillment(of: [prepared, followingDone], timeout: 10)
        XCTAssertFalse(checkpoint.didTimeout)
        XCTAssertNil(result.error)
        try service.discardRepairPreview(XCTUnwrap(result.preview))
        XCTAssertEqual(followingCommands, 1)
        XCTAssertEqual(repairCommands, 0)
        XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "after utility capture")
    }

    func testCancellingAdmittedRepairEvidenceReleasesCompletionAndFIFOBeforeWorkerReturns() async throws {
        let fixture = try RepairFixture(label: "cancel-held-evidence")
        defer { fixture.cleanup() }
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let workerEntered = expectation(description: "repair evidence worker is held")
        let workerResumed = expectation(description: "cancelled evidence worker resumes")
        let checkpoint = WorktreeWorkerCheckpoint()
        var repairCommands = 0
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: { arguments in
            if arguments.contains("repair") {
                repairCommands += 1
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }, repairPreparationObserver: {
            workerEntered.fulfill()
            checkpoint.wait()
            workerResumed.fulfill()
        })
        var followingCommands = 0
        let following = makeService(repository: repository, fixture: fixture, blocked: ControlledWorktreeTask(), launched: XCTestExpectation(description: "unused"), taskOverride: { arguments in
            if arguments.contains("lock") {
                followingCommands += 1
            }
            return nil
        })
        defer { checkpoint.resume(); service.cancel(); following.cancel() }
        try await ready(service)
        try await ready(following)
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
        await fulfillment(of: [workerEntered], timeout: 5)
        XCTAssertNotNil(retainedCompletionOwner)
        let progressed = expectation(description: "following real writer finishes while evidence worker remains held")
        progressed.assertForOverFulfill = true
        enqueue {
            following.lockWorktree(path: fixture.linked.path, reason: "following") { _, error in
                XCTAssertNil(error)
                progressed.fulfill()
            }
        }
        XCTAssertEqual(followingCommands, 0)
        service.cancel()
        await fulfillment(of: [cancelled, progressed], timeout: 5)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(result.preview)
        XCTAssertEqual(result.error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(result.error?.code, NSUserCancelledError)
        XCTAssertNil(retainedCompletionOwner, "Cancellation must release the deferred completion before its utility worker returns")
        XCTAssertFalse(checkpoint.didTimeout)
        XCTAssertEqual(service.repairPreparationCount, 0)
        XCTAssertEqual(repairCommands, 0)
        XCTAssertEqual(followingCommands, 1)
        XCTAssertEqual(following.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
        XCTAssertEqual(try metadata(in: fixture).filter { !$0.key.hasSuffix("/locked") }, before)
        XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent(".git")), gitfile)
        XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("marker.txt")), content)
        checkpoint.resume()
        await fulfillment(of: [workerResumed], timeout: 5)
        XCTAssertFalse(checkpoint.didTimeout)
        XCTAssertEqual(completions, 1)
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
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date())
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
        let filter = NSPredicate(format: "subsystem == %@ AND category == %@", "com.gitx.gitx", "PBGitWorktrees")
        let observable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let events = (try? store.getEntries(at: position, matching: filter).compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage)) ?? []
            return events.contains { $0.contains("worktree.lock.started phase=writing count=1 category=none") }
                && events.contains { $0.contains("worktree.add.failed phase=writing count=1 category=task") }
        }, object: nil)
        await fulfillment(of: [observable], timeout: 10)
        let entries = try store.getEntries(at: position, matching: filter).compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage)
        let events = entries.filter { $0.hasPrefix("worktree.") }
        XCTAssertTrue(events.contains { $0.contains("worktree.lock.started phase=writing count=1 category=none") })
        XCTAssertTrue(events.contains { $0.contains("worktree.add.failed phase=writing count=1 category=task") })
        for event in events {
            for secret in [secretReason, secretPath, secretBranch, secretOutput, "credential-secret"] {
                XCTAssertFalse(event.contains(secret))
            }
        }
        XCTAssertEqual(PBWorktreeLifecycleDiagnostics.publicEvent(arguments: ["worktree", "lock", "--reason", secretReason, secretPath], stage: secretOutput, phase: secretBranch, count: -1, category: secretReason), "worktree.lock.unknown phase=unknown count=0 category=unknown")
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

    private func ready(_ service: PBRepositoryWorktreeService) async throws {
        let published = expectation(description: "initial worktrees discovered")
        let observation = service.observe(\.worktrees) { _, _ in published.fulfill() }
        defer { observation.invalidate() }
        service.start()
        await fulfillment(of: [published], timeout: 10)
        XCTAssertTrue(service.isSupported)
        XCTAssertEqual(service.worktrees.count, 2)
    }

    private final class RepairFixture {
        let root: URL
        let main: URL
        let linked: URL
        init(label: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-repair-safety-\(UUID().uuidString)")
            main = root.appendingPathComponent("main"); linked = root.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Worktree Fixture"])
            _ = try git(["config", "user.email", "fixture@gitx.invalid"])
            try (label + "\n").write(to: main.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
            _ = try git(["add", "marker.txt"])
            _ = try git(["commit", "-m", label])
            _ = try git(["worktree", "add", "-b", "topic", linked.path])
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
