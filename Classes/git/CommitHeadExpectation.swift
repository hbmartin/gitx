import Foundation

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// The symbolic identity and object identity are independent: switching to a
/// different branch at the same commit must still invalidate publication.
@objc(PBCommitHeadExpectation)
final nonisolated class CommitHeadExpectation: NSObject, Sendable {
    @objc let symbolicTarget: String?
    @objc let expectedOID: String?
    @objc let objectIDWidth: Int

    @objc(initWithSymbolicTarget:expectedOID:objectIDWidth:error:)
    init(symbolicTarget: String?, expectedOID: String?, objectIDWidth: Int) throws {
        guard [40, 64].contains(objectIDWidth),
              expectedOID.map({ Self.isObjectID($0, width: objectIDWidth) }) ?? (symbolicTarget != nil),
              symbolicTarget.map({ $0.hasPrefix("refs/") && !$0.utf8.contains(where: { $0 <= 32 || $0 == 127 }) }) ?? true
        else { throw Self.movementError("Git returned an invalid HEAD identity.") }
        self.symbolicTarget = symbolicTarget
        self.expectedOID = expectedOID
        self.objectIDWidth = objectIDWidth
        super.init()
    }

    var expectedOldOID: String {
        expectedOID ?? String(repeating: "0", count: objectIDWidth)
    }

    @objc(matchesExpectation:)
    func matches(_ other: CommitHeadExpectation) -> Bool {
        symbolicTarget.map { Data($0.utf8) } == other.symbolicTarget.map { Data($0.utf8) } && expectedOID == other.expectedOID && objectIDWidth == other.objectIDWidth
    }

    static func isObjectID(_ value: String, width: Int) -> Bool {
        value.utf8.count == width && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func movementError(_ description: String = "HEAD changed while the commit was being prepared. Your message is preserved. Review the refreshed repository and submit again.") -> NSError {
        NSError(domain: "PBGitCommitPublicationError", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

// swift6-safety-justification: Cancellation is a monotonic state protected by the lock; no repository or task crosses this boundary.
final nonisolated class IndexCommitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value {
            throw NSError(domain: "PBGitCommitPublicationError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Commit publication was cancelled. Your message is preserved."])
        }
    }
}

@objc(PBIndexCommitReferenceRunning)
nonisolated protocol IndexCommitReferenceRunning: AnyObject {
    nonisolated func prepareCommitRequest(_ request: IndexCommitRequest) throws -> IndexCommitRequest
    nonisolated func publishCommit(_ oid: String, request: IndexCommitRequest, subject: String) throws
}

// swift6-safety-justification: A lock protects the executable identity cache and serializes its one capability probe.
private final nonisolated class IndexPreparedReferenceCapabilities: @unchecked Sendable {
    static let shared = IndexPreparedReferenceCapabilities()
    private let lock = NSLock()
    private var results: [String: Result<Void, Error>] = [:]

    func require(context: PBTaskExecutionContext, cancellation: IndexCommitCancellation) throws {
        let identity = IndexGitExecutableIdentity.identity(path: context.launchPath)
        lock.lock()
        defer { lock.unlock() }
        if let result = results[identity] {
            return try result.get()
        }
        let result = Result<Void, Error> {
            let transaction = IndexReferenceTransaction(checkCancellation: cancellation.check)
            defer { transaction.abortAndClose() }
            try transaction.launch(context: context)
            try transaction.send("start\nprepare\nabort\n")
            try transaction.acknowledge("start: ok")
            try transaction.acknowledge("prepare: ok")
            try transaction.acknowledge("abort: ok")
            try transaction.finish()
        }.mapError { error in
            if (error as NSError).domain == "PBGitCommitPublicationError", (error as NSError).code == 3 {
                return error
            }
            return NSError(domain: "PBGitCommitPublicationError", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Could not verify prepared reference transactions. Resolve the underlying Git error and retry. If this Git version lacks update-ref --stdin start/prepare/commit/abort, select a supported Git executable before committing. Browsing and staging remain available.",
                NSUnderlyingErrorKey: error,
            ])
        }
        if case let .failure(error) = result, (error as NSError).code == 3 {
            throw error
        }
        // Repository/configuration, launch and resource errors do not establish
        // an executable's capability. Only a successful probe is reusable.
        if case .success = result {
            results[identity] = result
        }
        try result.get()
    }
}

nonisolated extension IndexRepositoryCommandRunner: IndexCommitReferenceRunning {
    func prepareCommitRequest(_ request: IndexCommitRequest) throws -> IndexCommitRequest {
        try request.cancellation.check()
        try IndexPreparedReferenceCapabilities.shared.require(context: referenceContext(subject: "GitX capability probe", capabilityProbe: true), cancellation: request.cancellation)
        let head = try readCommitHead()
        guard let directory = repositoryForCommit?.gitURL() else { throw CommitHeadExpectation.movementError("The repository closed before commit preparation.") }
        let mergeState = try IndexCommitMergeState(directory: directory)
        if let expected = request.headExpectation {
            guard expected.matches(head) else { throw CommitHeadExpectation.movementError() }
            try request.mergeState?.validate()
            return request
        }
        var parents: [String] = []
        if request.amend {
            guard mergeState.mergeHead == nil else { throw CommitHeadExpectation.movementError("Finish the current merge before amending a commit.") }
            guard let oid = head.expectedOID else { throw CommitHeadExpectation.movementError("There is no HEAD commit to amend. Submit a new commit instead.") }
            let line = try output(arguments: ["rev-list", "--parents", "-n", "1", oid], input: nil, environment: nil)
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.first == oid else { throw CommitHeadExpectation.movementError("Git could not resolve the commit's parents.") }
            parents = Array(fields.dropFirst())
        } else {
            if let oid = head.expectedOID {
                parents.append(oid)
            }
            if let mergeHead = mergeState.mergeHead {
                guard let text = String(data: mergeHead, encoding: .utf8) else { throw CommitHeadExpectation.movementError("MERGE_HEAD contains invalid text.") }
                let mergeHeads = text.split(whereSeparator: \.isWhitespace).map(String.init)
                for oid in mergeHeads {
                    guard CommitHeadExpectation.isObjectID(oid, width: head.objectIDWidth) else { throw CommitHeadExpectation.movementError("MERGE_HEAD contains an invalid parent identity.") }
                    _ = try output(arguments: ["cat-file", "-e", "\(oid)^{commit}"], input: nil, environment: nil)
                    if !parents.contains(oid) {
                        parents.append(oid)
                    }
                }
            }
        }
        guard parents.allSatisfy({ CommitHeadExpectation.isObjectID($0, width: head.objectIDWidth) }), try head.matches(readCommitHead()) else {
            throw CommitHeadExpectation.movementError()
        }
        try mergeState.validate()
        return request.prepared(head: head, parents: parents, mergeState: mergeState)
    }

    func publishCommit(_ oid: String, request: IndexCommitRequest, subject: String) throws {
        guard let expected = request.headExpectation, CommitHeadExpectation.isObjectID(oid, width: expected.objectIDWidth) else {
            throw CommitHeadExpectation.movementError("Commit publication requires a prepared HEAD expectation.")
        }
        try request.cancellation.check()
        let transaction = IndexReferenceTransaction(checkCancellation: request.cancellation.check)
        defer { transaction.abortAndClose() }
        try transaction.launch(context: referenceContext(subject: subject))
        try transaction.send("start\nupdate HEAD \(oid) \(expected.expectedOldOID)\nprepare\n")
        try transaction.acknowledge("start: ok")
        do { try transaction.acknowledge("prepare: ok") }
        catch {
            if let observed = try? readCommitHead(timeout: max(0.1, transaction.remainingTime)), !expected.matches(observed) {
                throw CommitHeadExpectation.movementError()
            }
            throw error
        }
        // update HEAD locks both its symbolic identity and the resolved reference.
        // Inspect identity only after prepare; an old OID alone misses branch switches.
        guard try expected.matches(readCommitHead(timeout: transaction.remainingTime)) else { throw CommitHeadExpectation.movementError() }
        try request.mergeState?.validate()
        try request.cancellation.check()
        try transaction.send("commit\n")
        try transaction.acknowledge("commit: ok")
        try transaction.finish()
        request.mergeState?.clearAfterPublication()
    }

    private func referenceContext(subject: String, capabilityProbe: Bool = false) throws -> PBTaskExecutionContext {
        guard let repository = repositoryForCommit else { throw CommitHeadExpectation.movementError("The repository closed before commit publication.") }
        let prefix = capabilityProbe ? ["-c", "core.hooksPath=/dev/null"] : []
        return try repository.task(withArguments: prefix + ["update-ref", "--stdin", "-m", subject]).executionContext()
    }

    private func readCommitHead(timeout: TimeInterval = 30) throws -> CommitHeadExpectation {
        let start = ProcessInfo.processInfo.systemUptime
        func query(_ arguments: [String], absentAllowed: Bool = false) throws -> String? {
            guard let repository = repositoryForCommit else { throw CommitHeadExpectation.movementError("The repository closed before commit publication.") }
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { throw CommitHeadExpectation.movementError("Commit publication timed out while checking HEAD.") }
            let task = repository.task(withArguments: arguments)
            task.timeout = remaining
            task.separatesStandardError = true
            task.additionalEnvironment = ["GIT_OPTIONAL_LOCKS": "0"]
            do { try task.launch() }
            catch {
                if absentAllowed, (error as NSError).userInfo[PBTaskTerminationStatusKey] as? Int == 1 {
                    return nil
                }
                throw error
            }
            var value = task.standardOutputString() ?? ""
            if value.hasSuffix("\n") {
                value.removeLast()
            }
            return value
        }
        let format = try query(["rev-parse", "--show-object-format"])
        guard let width = ["sha1": 40, "sha256": 64][format ?? ""] else { throw CommitHeadExpectation.movementError("Git returned an unsupported object format.") }
        let target = try query(["symbolic-ref", "-q", "HEAD"], absentAllowed: true)
        let oid = try query(["rev-parse", "--verify", "-q", "HEAD^{commit}"], absentAllowed: true)
        return try CommitHeadExpectation(symbolicTarget: target, expectedOID: oid, objectIDWidth: width)
    }
}

/// Freeze the merge inputs alongside parents. Retry cannot adopt another
/// merge, and publication cleans up only the state belonging to this request.
nonisolated struct IndexCommitMergeState: Sendable {
    private let directory: URL
    private let markers: [String: Data]
    private static let names = ["MERGE_MSG", "MERGE_MODE", "MERGE_HEAD"]
    var mergeHead: Data? {
        markers["MERGE_HEAD"]
    }

    init(directory: URL) throws {
        self.directory = directory
        var snapshot: [String: Data] = [:]
        for name in Self.names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                snapshot[name] = try Data(contentsOf: url)
            }
        }
        markers = snapshot
    }

    func validate() throws {
        guard try IndexCommitMergeState(directory: directory).markers == markers else {
            throw CommitHeadExpectation.movementError("Merge state changed while the commit was being prepared. Your message is preserved. Review the repository and submit again.")
        }
    }

    func clearAfterPublication() {
        guard mergeHead != nil else { return }
        do {
            try validate()
            // MERGE_HEAD is the active-state marker and is removed last.
            for name in Self.names where markers[name] != nil {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            NSLog("[GitX] Published merge commit and cleared its preparation markers")
        } catch {
            // Publication succeeded. Preserve newer/changed markers and never
            // report a failed commit or suppress the post-commit hook here.
            NSLog("[GitX] Commit published; merge cleanup needs review: %@", error.localizedDescription)
        }
    }
}

#if DEBUG
    @objc(PBIndexReferenceCapabilityTestHarness)
    final nonisolated class IndexReferenceCapabilityTestHarness: NSObject {
        @objc(requireWithTask:error:)
        static func require(task: PBTask) throws {
            try require(task: task, cancelled: false)
        }

        @objc(requireWithTask:cancelled:error:)
        static func require(task: PBTask, cancelled: Bool) throws {
            let cancellation = IndexCommitCancellation()
            if cancelled {
                cancellation.cancel()
            }
            try IndexPreparedReferenceCapabilities.shared.require(context: task.executionContext(), cancellation: cancellation)
        }

        @objc(clearCapturedMergeStateInDirectory:replacementMessage:error:)
        static func clearCapturedMergeState(directory: String, replacementMessage: String?) throws {
            let url = URL(fileURLWithPath: directory)
            let state = try IndexCommitMergeState(directory: url)
            if let replacementMessage {
                try Data(replacementMessage.utf8).write(to: url.appendingPathComponent("MERGE_MSG"))
            }
            state.clearAfterPublication()
        }
    }
#endif
