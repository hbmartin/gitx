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

    func testCancelRetainsAdmissionUntilTheActiveWriterTerminates() async throws {
        let fixture = try WorktreeMutationFixture()
        defer { fixture.cleanup() }
        let first = fixture.makeService()
        let second = fixture.makeService()
        try await start(first); try await start(second)
        let cancelled = expectation(description: "writer terminal cancellation")
        cancelled.assertForOverFulfill = true
        let completed = expectation(description: "following writer completes")
        let firstArguments = ["worktree", "lock", "--reason", "first", "/linked"]
        let secondArguments = ["worktree", "unlock", "/linked"]
        let completions = WorktreeCompletionRecorder()
        enqueueLock(first.service, reason: "first") { output, error in
            XCTAssertNil(output); XCTAssertEqual(error?.code, NSUserCancelledError)
            completions.names.append("cancelled"); cancelled.fulfill()
        }
        enqueueUnlock(second.service) { _, error in XCTAssertNil(error); completed.fulfill() }
        let writer = try first.tasks.task(firstArguments)
        first.service.cancel(); first.service.cancel()
        XCTAssertTrue(writer.wasCancelled)
        XCTAssertTrue(completions.names.isEmpty)
        XCTAssertTrue(second.tasks.mutations.isEmpty)
        let nextStarted = second.tasks.expect(secondArguments)
        writer.finish(nil, error: CancellationError())
        await fulfillment(of: [cancelled, nextStarted], timeout: 5)
        XCTAssertEqual(completions.names, ["cancelled"])
        let refreshed = second.tasks.expect(discoveryArguments)
        try second.tasks.task(secondArguments).finish(Data())
        await fulfillment(of: [refreshed], timeout: 5)
        try second.tasks.task(discoveryArguments, occurrence: 1).finish(snapshot)
        await fulfillment(of: [completed], timeout: 5)
        writer.finish(Data("late success".utf8))
        await drainMainQueue()
        XCTAssertEqual(completions.names, ["cancelled"])
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
        enqueue { service.repairLinks(relativePaths: false) { error in XCTAssertNil(error); repaired.fulfill() } }
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

    private func writeVerificationGitProxy(_ path: URL) throws {
        try "#!/bin/sh\nexec /usr/bin/git \"$@\"\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private final class PruneCompletion {
        var preview: PBWorktreePrunePreview?
        var error: NSError?
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
