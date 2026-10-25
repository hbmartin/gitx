import Darwin
import Synchronization
import XCTest

final class GitXTestGitFixtureTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testInvocationLeaseProtectsTheRootUntilItsOwnerIsReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let progress = root.appendingPathComponent("Progress")
        try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: true)
        directories.append(root)
        let path = root.appendingPathComponent("invocation.lease").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        let probe = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        XCTAssertGreaterThanOrEqual(probe, 0)
        guard probe >= 0 else { return }
        defer { Darwin.close(probe) }

        var lease: GitXTestInvocationLease? = try GitXTestInvocationLease(progressDirectory: progress.path)
        XCTAssertNotNil(lease)
        let lockedResult = flock(probe, LOCK_EX | LOCK_NB)
        let lockedCode = errno
        XCTAssertEqual(lockedResult, -1, "held invocation lease")
        XCTAssertEqual(lockedCode, EWOULDBLOCK, "held invocation lease")
        lease = nil
        XCTAssertEqual(flock(probe, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(probe, LOCK_UN), 0)
    }

    func testInvocationLeaseFailuresPreserveCauseAndCloseEveryAcquiredDescriptor() throws {
        let failures: [(operation: String, category: String, code: Int32?)] = [
            ("inspect-lease-directory", "system", EIO), ("validate-lease-directory", "ownership", nil),
            ("open-lease", "system", EMFILE), ("inspect-lease", "system", EIO),
            ("validate-lease", "ownership", nil), ("lock-lease", "system", EWOULDBLOCK),
        ]
        for failure in failures {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let progress = root.appendingPathComponent("Progress")
            try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: true)
            directories.append(root)
            let evidence = Data("keep-lease-evidence".utf8)
            try evidence.write(to: root.appendingPathComponent("invocation.lease"))
            var descriptors: [Int32] = []
            var inspections = 0
            XCTAssertThrowsError(try GitXTestInvocationLease(
                progressDirectory: progress.path,
                inspectDescriptor: { descriptor, info in
                    descriptors.append(descriptor)
                    inspections += 1
                    let phase = inspections == 1 ? "lease-directory" : "lease"
                    if failure.operation == "inspect-" + phase {
                        errno = EIO; return -1
                    }
                    let result = fstat(descriptor, info)
                    if failure.operation == "validate-" + phase {
                        info.pointee.st_uid = geteuid() ^ 1
                    }
                    return result
                },
                openLease: { parent, flags in
                    XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                    if failure.operation == "open-lease" {
                        errno = EMFILE; return -1
                    }
                    return openat(parent, "invocation.lease", flags)
                },
                lockLease: { descriptor, flags in
                    XCTAssertEqual(flags, LOCK_SH | LOCK_NB)
                    if failure.operation == "lock-lease" {
                        errno = EWOULDBLOCK; return -1
                    }
                    return flock(descriptor, flags)
                }
            )) { error in
                let actual = error as? GitXTestProgressRecords.PublicationError
                XCTAssertEqual(actual?.operation, failure.operation)
                XCTAssertEqual(actual?.category, failure.category)
                XCTAssertEqual(actual?.posixCode, failure.code)
            }
            XCTAssertEqual(inspections, failure.operation.hasSuffix("directory") || failure.operation == "open-lease" ? 1 : 2)
            for descriptor in descriptors {
                let result = fcntl(descriptor, F_GETFD)
                let code = errno
                XCTAssertEqual(result, -1, failure.operation)
                XCTAssertEqual(code, EBADF, failure.operation)
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("invocation.lease")), evidence)
        }
    }

    func testInvocationLeaseMissingRootPreservesTheOpenFailure() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Progress")
        XCTAssertThrowsError(try GitXTestInvocationLease(progressDirectory: missing.path)) { error in
            let failure = error as? GitXTestProgressRecords.PublicationError
            XCTAssertEqual(failure?.operation, "open-lease-directory")
            XCTAssertEqual(failure?.category, "system")
            XCTAssertEqual(failure?.posixCode, ENOENT)
        }
    }

    func testSharedEnvironmentMatchesExistingFixturePolicyAndKeepsNonGitInputs() {
        let inherited = ["PATH": "/fixture/tools", "DEVELOPER_DIR": "/fixture/Xcode", "GIT_DIR": "/wrong", "GIT_CONFIG_PARAMETERS": "hostile"]
        let shared = GitXTestGitEnvironment.isolated(inherited)
        let existing = RepositoryTestGitEnvironment.isolated(inherited)
        for (key, value) in existing {
            XCTAssertEqual(shared[key], value, key)
        }
        XCTAssertEqual(shared["PATH"], inherited["PATH"])
        XCTAssertEqual(shared["DEVELOPER_DIR"], inherited["DEVELOPER_DIR"])
        XCTAssertNil(shared["GIT_DIR"])
        XCTAssertNil(shared["GIT_CONFIG_PARAMETERS"])
        XCTAssertEqual(shared["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(shared["GCM_INTERACTIVE"], "never")
    }

    func testVerificationOwnershipReachesAnEmptyUILaunchEnvironment() {
        let environment = GitXTestGitEnvironment.isolated([:], verificationSession: "verified-run")
        XCTAssertEqual(environment["GITX_VERIFICATION_SESSION"], "verified-run")
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        let unowned = GitXTestGitEnvironment.isolated([:], verificationSession: nil)
        XCTAssertNil(unowned["GITX_VERIFICATION_SESSION"])
    }

    func testNativeDiagnosticsReachAnEmptyUILaunchEnvironment() {
        let environment = GitXTestGitEnvironment.isolated([:], nativeDiagnosticDirectory: "/run/Logs/Native")
        XCTAssertEqual(environment["GITX_TEST_STDERR_DIRECTORY"], "/run/Logs/Native")
        let unowned = GitXTestGitEnvironment.isolated([:], nativeDiagnosticDirectory: nil)
        XCTAssertNil(unowned["GITX_TEST_STDERR_DIRECTORY"])
    }

    func testManagedObserverRegistersIdempotentlyInThisTestBundle() throws {
        GitXManagedTestObserver.install()
        GitXManagedTestObserver.install()
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"],
              let invocation = environment["GITX_TEST_INVOCATION_ID"] else { return }
        let records = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("startup-") }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
        XCTAssertTrue(records.contains {
            $0["event"] as? String == "bundle-start" && $0["invocationID"] as? String == invocation
                && $0["bundleID"] as? String == "net.phere.GitXTests"
        }, "The loading shim must register before the bundle-start callback, in Debug and Release")
    }

    func testFailureAttachmentsKeepOnlyRegularNativeFilesAndPreserveOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let native = directory.appendingPathComponent("GitX-42-fixture.stderr.log")
        let bytes = Data(repeating: 255, count: 70000)
        try bytes.write(to: native)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.stderr.log"), withDestinationURL: native)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.stderr.log"), withIntermediateDirectories: true)
        let attachments = GitXManagedTestObserver.failureAttachments(in: directory.path)
        XCTAssertEqual(attachments.count, 1)
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.name, "Native stderr tail: GitX-42-fixture.stderr.log [4464..<70000]")
        XCTAssertEqual(attachment.lifetime, .keepAlways)
        XCTAssertEqual(try Data(contentsOf: native), bytes)
        XCTAssertTrue(GitXManagedTestObserver.failureAttachments(in: nil).isEmpty)
        XCTAssertTrue(GitXManagedTestObserver.failureAttachments(in: "").isEmpty)
    }

    func testNativeFailureAttachmentsRetainNewTailBytesOnceWithinCaseBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let source = directory.appendingPathComponent("GitX-42-a.stderr.log")
        let prefix = Data(repeating: 65, count: 70000)
        let sentinel = Data([0, 255]) + Data("AddressSanitizer: tail\ncrash-output: tail\n".utf8)
        let original = prefix + sentinel
        try original.write(to: source)
        var state = GitXManagedTestObserver.AttachmentState()
        let first = try XCTUnwrap(state.take(in: directory.path).first)
        XCTAssertEqual(first.data, original.suffix(65536))
        XCTAssertEqual(first.end, Int64(original.count))
        XCTAssertTrue(state.take(in: directory.path).isEmpty)
        let handle = try FileHandle(forWritingTo: source)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("next-issue".utf8))
        try handle.close()
        let next = try XCTUnwrap(state.take(in: directory.path).first)
        XCTAssertEqual(next.start, Int64(original.count))
        XCTAssertEqual(next.data, Data("next-issue".utf8))
        for pid in 43 ... 50 {
            try Data(repeating: UInt8(pid), count: 70000).write(to: directory.appendingPathComponent("GitX-\(pid)-a.stderr.log"))
        }
        let remaining = state.take(in: directory.path)
        XCTAssertTrue(remaining.allSatisfy { $0.data.count <= 65536 })
        XCTAssertEqual(state.retainedBytes, 262_144)
        XCTAssertTrue(state.take(in: directory.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original + Data("next-issue".utf8))
        var independentCase = GitXManagedTestObserver.AttachmentState()
        XCTAssertFalse(independentCase.take(in: directory.path).isEmpty)
    }

    func testFailureAttachmentsExcludePreCaseLogsAndPrioritizeNewLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for pid in 10 ... 15 {
            try Data(repeating: 65, count: 70000).write(to: directory.appendingPathComponent("GitX-\(pid)-a.stderr.log"))
        }
        var state = GitXManagedTestObserver.AttachmentState(in: directory.path)
        XCTAssertTrue(state.take(in: directory.path).isEmpty, "Earlier launches cannot spend this case's budget")
        let current = directory.appendingPathComponent("GitX-999-a.stderr.log")
        let sentinel = Data([0, 255]) + Data("crashing current launch".utf8)
        try sentinel.write(to: current)
        let excerpts = state.take(in: directory.path)
        XCTAssertEqual(excerpts.map(\.filename), [current.lastPathComponent])
        XCTAssertEqual(excerpts.first?.data, sentinel)
        XCTAssertTrue(state.take(in: directory.path).isEmpty)
        let old = directory.appendingPathComponent("GitX-10-a.stderr.log")
        let handle = try FileHandle(forWritingTo: old)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new issue".utf8))
        try handle.close()
        XCTAssertEqual(state.take(in: directory.path).first?.data, Data("new issue".utf8))
        XCTAssertEqual(try Data(contentsOf: current), sentinel)
    }

    func testRecoveredLogInspectionExcludesUnvalidatedPreCaseBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-42-a.stderr.log")
        try Data("before-case".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0), 0)
        defer { _ = chmod(file.path, 0o600) }
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path))
        defer { index.close() }
        let baseline = index.caseSnapshot()
        XCTAssertTrue(baseline.candidates.isEmpty)
        XCTAssertEqual(baseline.names, [file.lastPathComponent])
        let session = GitXManagedTestObserver.CaseAttachments(candidates: baseline.candidates, preexistingNames: baseline.names)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertTrue(session.take(candidates: index.snapshot()).isEmpty)
        let tail = Data([0, 255, 65])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()
        XCTAssertEqual(session.take(candidates: index.snapshot()).first?.data, tail)
        session.close()
    }

    func testLogIndexRetriesUnreadableEntriesWithoutDirectoryChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        var files: [URL] = []
        defer { files.forEach { _ = chmod($0.path, 0o600) } }
        for number in 1 ... 21 {
            let file = directory.appendingPathComponent("GitX-\(number)-retry.stderr.log")
            try Data([0, 255, 65]).write(to: file)
            files.append(file)
            XCTAssertEqual(chmod(file.path, 0), 0)
        }
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path))
        defer { index.close() }
        XCTAssertTrue(index.snapshot().isEmpty)
        files.forEach { XCTAssertEqual(chmod($0.path, 0o600), 0) }
        var recovered = Set<String>()
        for _ in 0 ..< 4 {
            let before = index.retryInspectionCount
            recovered.formUnion(index.snapshot().map(\.identity))
            XCTAssertLessThanOrEqual(index.retryInspectionCount - before, 16)
        }
        XCTAssertEqual(recovered.count, files.count)
    }

    func testLogIndexRetriesCaptureRecordsWithoutDirectoryChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-\(getpid())-retry.stderr.log")
        try Data([0, 255]).write(to: file)
        let record = try GitXTestProgressRecords.write([
            "schemaVersion": 1, "event": "capture", "state": "captured", "filename": file.lastPathComponent,
            "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture",
        ], prefix: "capture", directory: directory.path)
        XCTAssertEqual(chmod(record.path, 0), 0)
        defer { _ = chmod(record.path, 0o600) }
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(
            directory: directory.path, invocationID: "fixture", verificationSession: "fixture", progressDirectory: nil
        ))
        defer { index.close() }
        XCTAssertEqual(index.snapshot().first?.finalized, false)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        XCTAssertEqual(index.snapshot().first?.finalized, true)
        XCTAssertLessThanOrEqual(index.retryInspectionCount, 16)
    }

    func testIncompleteBaselineRecoveryKeepsEveryUnreadablePreCaseName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let readable = directory.appendingPathComponent("GitX-41-a.stderr.log")
        let delayed = directory.appendingPathComponent("GitX-42-b.stderr.log")
        try Data("old-a".utf8).write(to: readable)
        try Data("old-b".utf8).write(to: delayed)
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path))
        defer { index.close() }
        defer { _ = chmod(directory.path, 0o700); _ = chmod(delayed.path, 0o600) }
        XCTAssertEqual(chmod(delayed.path, 0), 0)
        XCTAssertEqual(chmod(directory.path, 0), 0)
        let baseline = index.caseSnapshot()
        XCTAssertFalse(baseline.complete)
        let session = GitXManagedTestObserver.CaseAttachments(candidates: baseline.candidates, preexistingNames: baseline.names,
                                                              needsBaselineRecovery: !baseline.complete)
        defer { session.close() }
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        XCTAssertTrue(session.take(snapshot: index.caseSnapshot()).isEmpty)
        XCTAssertEqual(chmod(delayed.path, 0o600), 0)
        XCTAssertTrue(session.take(snapshot: index.caseSnapshot()).isEmpty, "Delayed inspection must not attach pre-case bytes")
        let bytes = Data([0, 255, 65])
        let writer = try FileHandle(forWritingTo: delayed)
        try writer.seekToEnd()
        try writer.write(contentsOf: bytes)
        try writer.close()
        XCTAssertEqual(session.take(snapshot: index.caseSnapshot()).first?.data, bytes)
    }

    func testRecoveryPreservesProvenOffsetsAcrossIncompleteIssues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-41-proven.stderr.log")
        let delayed = directory.appendingPathComponent("GitX-42-delayed.stderr.log")
        try Data("old".utf8).write(to: file)
        try Data("unproven-old".utf8).write(to: delayed)
        let initial = try XCTUnwrap(GitXManagedTestObserver.AttachmentState.inspect(file))
        let session = GitXManagedTestObserver.CaseAttachments(
            candidates: [initial], preexistingNames: [file.lastPathComponent, delayed.lastPathComponent], needsBaselineRecovery: true
        )
        defer { session.close() }
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        for byte in [UInt8(0), 255, 65] {
            try writer.write(contentsOf: Data([byte]))
            let current = try XCTUnwrap(GitXManagedTestObserver.AttachmentState.inspect(file))
            let recovered = try XCTUnwrap(GitXManagedTestObserver.AttachmentState.inspect(delayed))
            let excerpts = session.take(snapshot: .init(candidates: [current, recovered], names: [file.lastPathComponent, delayed.lastPathComponent], complete: false))
            XCTAssertEqual(excerpts.map(\.data), [Data([byte])], "Recovery may establish unknown baselines only once")
        }
        XCTAssertTrue(session.take(snapshot: .init(candidates: [initial], names: [], complete: true)).isEmpty)
    }

    func testUnknownDiscoveryCannotEndBaselineRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-42-old.stderr.log")
        try Data("pre-case".utf8).write(to: file)
        var state = GitXManagedTestObserver.AttachmentState(candidates: [], needsBaselineRecovery: true)
        XCTAssertTrue(state.take(in: nil).isEmpty)
        let candidate = try XCTUnwrap(GitXManagedTestObserver.AttachmentState.inspect(file))
        XCTAssertTrue(state.take(in: nil, candidates: [candidate], names: [file.lastPathComponent], complete: true).isEmpty)
    }

    func testDirectoryChurnKeepsEveryHealthyLogAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for pid in 1 ... 33 {
            try Data([UInt8(pid)]).write(to: directory.appendingPathComponent("GitX-\(pid)-healthy.stderr.log"))
        }
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path, invalidateSnapshot: { true }))
        defer { index.close() }
        for _ in 0 ..< 5 {
            let snapshot = index.caseSnapshot()
            XCTAssertFalse(snapshot.complete)
            XCTAssertEqual(snapshot.candidates.count, 33, "Directory events cannot hide previously validated logs behind retry batches")
        }
    }

    func testLogIndexRetryRotationSurvivesEventsDuringEveryScan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        var files: [URL] = []
        defer { files.forEach { _ = chmod($0.path, 0o600) } }
        for number in 1 ... 21 {
            let file = directory.appendingPathComponent("GitX-\(number)-event.stderr.log")
            try Data([UInt8(number)]).write(to: file)
            XCTAssertEqual(chmod(file.path, 0), 0)
            files.append(file)
        }
        let interrupt = Mutex(false)
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path, invalidateSnapshot: { interrupt.withLock { $0 } }))
        defer { index.close() }
        XCTAssertTrue(index.snapshot().isEmpty)
        files.forEach { XCTAssertEqual(chmod($0.path, 0o600), 0) }
        interrupt.withLock { $0 = true }
        var recovered = Set<String>()
        for _ in 0 ..< 4 {
            let before = index.retryInspectionCount
            recovered.formUnion(index.snapshot().map(\.identity))
            XCTAssertLessThanOrEqual(index.retryInspectionCount - before, 16)
        }
        XCTAssertEqual(recovered.count, files.count, "Directory churn must not replay only the first retry batch")
    }

    func testCaptureRetriesDiscardAbsentRecordsAndReconsiderChangedInvalidRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-\(getpid())-record.stderr.log")
        try Data([0, 255]).write(to: file)
        let record = try GitXTestProgressRecords.write(["invalid": true], prefix: "capture", directory: directory.path)
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path, invocationID: "fixture", verificationSession: "fixture", progressDirectory: nil))
        defer { index.close() }
        XCTAssertEqual(index.snapshot().first?.finalized, false)
        let before = index.retryInspectionCount
        for _ in 0 ..< 3 {
            _ = index.snapshot()
        }
        XCTAssertEqual(index.retryInspectionCount, before, "Stable malformed records must not consume transient retries")
        let repaired: [String: Any] = ["schemaVersion": 1, "event": "capture", "state": "captured", "filename": file.lastPathComponent,
                                       "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture"]
        try JSONSerialization.data(withJSONObject: repaired).write(to: record)
        XCTAssertEqual(index.snapshot().first?.finalized, true)
        let unreadable = try GitXTestProgressRecords.write(repaired, prefix: "capture", directory: directory.path)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        _ = index.snapshot()
        try FileManager.default.removeItem(at: unreadable)
        let prior = index.retryInspectionCount
        _ = index.snapshot()
        XCTAssertEqual(index.retryInspectionCount, prior, "A successful listing must remove deleted pending records")
    }

    func testAttachmentClosureDoesNotWaitForAdmittedDelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-42-a.stderr.log")
        let bytes = Data([0, 255, 65])
        try bytes.write(to: file)
        let candidate = try XCTUnwrap(GitXManagedTestObserver.AttachmentState.inspect(file))
        let session = GitXManagedTestObserver.CaseAttachments(candidates: [])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let received = Mutex<Data?>(nil)
        let onCaller = Mutex(false)
        DispatchQueue.global().async {
            let caller = Thread.current
            session.deliver(candidates: [candidate]) { excerpt in
                received.withLock { $0 = excerpt.data }
                onCaller.withLock { $0 = Thread.current === caller }
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async { session.close(); closed.signal() }
        let closure = closed.wait(timeout: .now() + 5)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closure, .success)
        XCTAssertEqual(received.withLock { $0 }, bytes)
        XCTAssertTrue(onCaller.withLock { $0 })
        session.deliver(candidates: [candidate]) { _ in XCTFail("Closed session admitted a new delivery") }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLogIndexCachesQuiescentFilesAndTracksInheritedWriterLeases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for pid in 1 ... 20 {
            let name = "GitX-\(getpid())-\(pid).stderr.log"
            try Data("old".utf8).write(to: directory.appendingPathComponent(name))
            try GitXTestProgressRecords.write([
                "schemaVersion": 1, "event": "capture", "state": "captured", "filename": name,
                "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture",
            ], prefix: "capture", directory: directory.path)
        }
        let changed = expectation(description: "directory change delivered")
        changed.assertForOverFulfill = false
        let closed = expectation(description: "watch descriptor closed")
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(
            directory: directory.path, invocationID: "fixture", verificationSession: "fixture", progressDirectory: nil, onDirectoryChange: { changed.fulfill() }, onClosed: { closed.fulfill() }
        ))
        defer { index.close() }
        XCTAssertEqual(index.snapshot().count, 20)
        let inspections = index.inspectionCount
        for _ in 0 ..< 30 {
            XCTAssertEqual(index.snapshot().count, 20)
        }
        XCTAssertEqual(index.inspectionCount, inspections)
        let current = directory.appendingPathComponent("GitX-999-a.stderr.log")
        let writer = current.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o600) }
        XCTAssertGreaterThanOrEqual(writer, 0)
        guard writer >= 0 else { return }
        defer { Darwin.close(writer) }
        XCTAssertEqual(flock(writer, LOCK_SH | LOCK_NB), 0)
        wait(for: [changed], timeout: 5)
        let session = GitXManagedTestObserver.CaseAttachments(candidates: index.snapshot())
        let sentinel = Data([0, 255]) + Data("current case".utf8)
        sentinel.withUnsafeBytes { XCTAssertEqual(Darwin.write(writer, $0.baseAddress, $0.count), $0.count) }
        let candidates = index.snapshot()
        let bytes = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let excerpts = session.take(candidates: candidates)
            bytes.withLock { $0 += excerpts.reduce(0) { $0 + $1.data.count } }
        }
        XCTAssertEqual(bytes.withLock { $0 }, sentinel.count)
        session.close()
        XCTAssertTrue(session.take(candidates: candidates).isEmpty)
        index.close()
        wait(for: [closed], timeout: 5)
        XCTAssertTrue(index.snapshot().isEmpty)
    }

    func testLogIndexRejectsReplacementFilesAndDirectoryRedirection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent("GitX-42-a.stderr.log")
        try Data("old".utf8).write(to: file)
        let index = try XCTUnwrap(GitXManagedTestObserver.LogIndex(directory: directory.path))
        defer { index.close() }
        let original = try XCTUnwrap(index.snapshot().first)
        let retainedFile = try FileHandle(forReadingFrom: file)
        defer { try? retainedFile.close() }
        try FileManager.default.removeItem(at: file)
        try Data("new".utf8).write(to: file)
        let replacement = try XCTUnwrap(index.snapshot().first)
        XCTAssertNotEqual(original.identity, replacement.identity)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertTrue(index.snapshot().isEmpty)
        let moved = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        directories.append(moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        XCTAssertTrue(index.snapshot().isEmpty)
    }

    func testProgressPublicationLeavesOnlyCompleteDistinctRecordsAndPreservesEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let sentinel = directory.appendingPathComponent("startup-existing.json")
        try Data("keep-existing".utf8).write(to: sentinel)
        let record: [String: Any] = ["schemaVersion": 1, "event": "bundle-start", "invocationID": "fixture"]
        let first = try GitXTestProgressRecords.write(record, prefix: "startup", directory: directory.path)
        let second = try GitXTestProgressRecords.write(record, prefix: "startup", directory: directory.path)
        XCTAssertNotEqual(first, second)
        for file in [first, second] {
            let published = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(published["event"] as? String, "bundle-start")
            XCTAssertEqual(published["invocationID"] as? String, "fixture")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep-existing".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testProgressSerializationFailureLeavesNoPartialEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        XCTAssertThrowsError(try GitXTestProgressRecords.write(
            ["unsupported": Date()], prefix: "startup", directory: directory.path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testProgressPublicationPreservesSystemOperationAndErrno() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for operation in ["write-record", "publish-record"] {
            XCTAssertThrowsError(try GitXTestProgressRecords.write(
                ["event": "bundle-start"], prefix: "startup", directory: directory.path,
                writeBytes: { descriptor, bytes, count in
                    if operation == "write-record" {
                        errno = ENOSPC
                        return -1
                    }
                    return Darwin.write(descriptor, bytes, count)
                },
                publish: { _, _, _ in
                    errno = EACCES
                    return -1
                }
            )) { error in
                let failure = error as? GitXTestProgressRecords.PublicationError
                XCTAssertEqual(failure?.operation, operation)
                XCTAssertEqual(failure?.category, "system")
                XCTAssertEqual(failure?.posixCode, operation == "write-record" ? ENOSPC : EACCES)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testProgressExclusiveRenamePreservesCollisionAndRetriesInterruptedPartialWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let identity = UUID().uuidString
        let destination = directory.appendingPathComponent("startup-\(getpid())-\(identity).json")
        let original = Data("existing-record".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try GitXTestProgressRecords.write(
            ["event": "bundle-start"], prefix: "startup", directory: directory.path, identity: identity
        )) { error in
            XCTAssertEqual((error as? GitXTestProgressRecords.PublicationError)?.posixCode, EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        var attempts = 0
        let published = try GitXTestProgressRecords.write(
            ["event": "bundle-start"], prefix: "startup", directory: directory.path,
            writeBytes: { descriptor, bytes, count in
                attempts += 1
                if attempts == 1 {
                    errno = EINTR
                    return -1
                }
                return Darwin.write(descriptor, bytes, min(count, 3))
            }
        )
        XCTAssertGreaterThan(attempts, 2)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: published)) as? [String: String])
        XCTAssertEqual(record["event"], "bundle-start")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testManagedStartupFailureIsTakenBeforeRecursiveIssueDelivery() {
        var state = GitXManagedTestObserver.StartupState()
        state.failure = .init(operation: "publish-record", category: "system", posixCode: ENOSPC)
        XCTAssertEqual(state.takeFailure()?.posixCode, ENOSPC)
        XCTAssertNil(state.takeFailure())
    }

    func testEmptyDiagnosticRequestsAreRemovedAndProgressSurvivesEmptyLaunchEnvironment() {
        let empty = GitXTestGitEnvironment.isolated(
            ["GITX_VERIFICATION_SESSION": "old", "GITX_TEST_STDERR_DIRECTORY": "/previous",
             "GITX_TEST_PROGRESS_DIRECTORY": "/previous", "GITX_TEST_INVOCATION_ID": "old"],
            verificationSession: "", nativeDiagnosticDirectory: "", progressDirectory: "", invocationID: ""
        )
        XCTAssertNil(empty["GITX_VERIFICATION_SESSION"])
        XCTAssertNil(empty["GITX_TEST_STDERR_DIRECTORY"])
        XCTAssertNil(empty["GITX_TEST_PROGRESS_DIRECTORY"])
        XCTAssertNil(empty["GITX_TEST_INVOCATION_ID"])
        let progress = GitXTestGitEnvironment.isolated(
            [:], nativeDiagnosticDirectory: nil, progressDirectory: "/fixture/progress", invocationID: "invocation-1"
        )
        XCTAssertEqual(progress["GITX_TEST_PROGRESS_DIRECTORY"], "/fixture/progress")
        XCTAssertEqual(progress["GITX_TEST_INVOCATION_ID"], "invocation-1")
    }

    func testExplicitNativeDirectoryAndSessionRemainLiteralAcrossRepeatedIsolation() {
        let directory = "/fixture/cache with spaces/Native"
        let first = GitXTestGitEnvironment.isolated(
            ["PATH": "/fixture/tools"], verificationSession: "run-1", nativeDiagnosticDirectory: directory
        )
        let second = GitXTestGitEnvironment.isolated(
            first, verificationSession: "run-1", nativeDiagnosticDirectory: directory
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(second["GITX_TEST_STDERR_DIRECTORY"], directory)
        XCTAssertEqual(second["GITX_VERIFICATION_SESSION"], "run-1")
        XCTAssertEqual(second["PATH"], "/fixture/tools")
    }

    func testFixtureRunnerCommitsLiteralFilesAndPreservesIntentionalLocalHooks() throws {
        let directory = try makeRepository()
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf intentional-local-hook >&2\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let name = "Café $literal;file.txt"
        try "fixture\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try GitXTestGitFixture.run(["add", "--", name], in: directory)
        let commit = try GitXTestGitFixture.run(["commit", "--quiet", "-m", "Fixture"], in: directory)
        XCTAssertTrue(commit.standardOutput.isEmpty)
        XCTAssertTrue(commit.standardError.contains("intentional-local-hook"))
        XCTAssertEqual(try GitXTestGitFixture.run(["show", "HEAD:" + name], in: directory).standardOutput, "fixture\n")
        XCTAssertEqual(try GitXTestGitFixture.run(["log", "-1", "--format=%s"], in: directory).standardOutput, "Fixture\n")
    }

    func testFixtureRunnerReportsGitFailureWithSeparateDiagnostics() throws {
        let directory = try makeRepository()
        XCTAssertThrowsError(try GitXTestGitFixture.run(["show", "refs/heads/missing"], in: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing"))
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, PBTaskErrorDomain)
            XCTAssertEqual(underlying?.code, 4)
        }
    }

    func testFixtureRunnerDrainsBothStreamsBeyondPipeCapacity() throws {
        let directory = try makeRepository()
        let command = "!dd if=/dev/zero bs=98304 count=1 2>/dev/null; dd if=/dev/zero bs=98304 count=1 >&2 2>/dev/null"
        let result = try GitXTestGitFixture.run(["-c", "alias.fixture-output=" + command, "fixture-output"], in: directory)
        XCTAssertEqual(result.standardOutput.utf8.count, 98304)
        XCTAssertFalse(result.standardError.isEmpty)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 65536)
    }

    func testFixtureRunnerBoundsAStalledGitAlias() throws {
        let directory = try makeRepository()
        XCTAssertThrowsError(try GitXTestGitFixture.run(
            ["-c", "alias.fixture-wait=!exec /bin/sleep 60", "fixture-wait"], in: directory, timeout: 0.2
        )) { error in
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, PBTaskErrorDomain)
            XCTAssertEqual(underlying?.code, 2)
        }
    }

    func testFixtureRunnerStoresBinaryStandardInputWithoutChangingItsBytes() throws {
        let directory = try makeRepository()
        let data = Data([0, 0xFF, 0x0A, 0x7F])
        let object = try GitXTestGitFixture.run(["hash-object", "-w", "--stdin"], in: directory, standardInput: data)
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let read = PBTask(launchPath: "/usr/bin/git", arguments: ["cat-file", "blob", object], inDirectory: directory.path)
        GitXTestGitFixture.prepare(read)
        try read.launch()
        XCTAssertEqual(read.standardOutputData, data)
    }

    @MainActor
    func testFixtureRepositoryTasksKeepExplicitOverridesAndTheirOriginalTimeout() throws {
        let directory = try makeRepository()
        let repository = try GitXTestGitRepository(url: directory)
        defer { repository.revisionList?.cleanup() }
        let task = repository.task(withArguments: ["-c", "alias.fixture-value=!printf '%s' \"$GITX_FIXTURE_TASK_VALUE\"", "fixture-value"])
        task.additionalEnvironment = ["GITX_FIXTURE_TASK_VALUE": "explicit literal value"]
        XCTAssertEqual(task.timeout, 30)
        try task.launch()
        XCTAssertEqual(task.standardOutputString(), "explicit literal value")
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Fixture-Runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try GitXTestGitFixture.run(["init", "--quiet", "--initial-branch=main"], in: directory)
        return directory
    }
}
