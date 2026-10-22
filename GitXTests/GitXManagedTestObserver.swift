import Darwin
import Dispatch
import Foundation
import Synchronization
import XCTest

/// This class belongs only to test bundles, including their Release configuration.
// The Objective-C loading shim registers the observer before XCTest starts its bundle.
// swiftlint:disable unused_declaration
@objc(GitXManagedTestObserver)
final nonisolated class GitXManagedTestObserver: NSObject, XCTestObservation, Sendable {
    private static let shared = GitXManagedTestObserver()
    private static let registration: Void = XCTestObservationCenter.shared.addTestObserver(shared)

    struct StartupState: Sendable {
        var failure: GitXTestProgressRecords.PublicationError?
        var delivered = false
        var lease: GitXTestInvocationLease?

        mutating func takeFailure() -> GitXTestProgressRecords.PublicationError? {
            guard !delivered, let failure else { return nil }
            delivered = true
            return failure
        }
    }

    private let startup = Mutex(StartupState())
    private let attachmentStates = Mutex<[ObjectIdentifier: CaseAttachments]>([:])
    private let logIndex = Mutex<LogIndex?>(nil)

    @objc static func install() {
        _ = registration
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let environment = ProcessInfo.processInfo.environment
        let index = LogIndex(directory: environment["GITX_TEST_STDERR_DIRECTORY"])
        logIndex.withLock { $0 = index }
        guard let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"], !directory.isEmpty,
              let invocation = environment["GITX_TEST_INVOCATION_ID"], !invocation.isEmpty,
              let session = environment["GITX_VERIFICATION_SESSION"], !session.isEmpty else { return }
        do {
            let lease = try GitXTestInvocationLease(progressDirectory: directory)
            startup.withLock { $0.lease = lease }
            try GitXTestProgressRecords.write([
                "schemaVersion": 1, "event": "bundle-start", "invocationID": invocation,
                "verificationSession": session, "bundleID": testBundle.bundleIdentifier ?? "",
                "pid": ProcessInfo.processInfo.processIdentifier,
            ], prefix: "startup", directory: directory)
        } catch let error as GitXTestProgressRecords.PublicationError {
            startup.withLock { $0.failure = error }
        } catch {
            startup.withLock {
                $0.failure = .init(operation: "publish-record", category: "unexpected", posixCode: nil)
            }
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let index = logIndex.withLock { $0 }
        let session = CaseAttachments(candidates: index?.snapshot() ?? [])
        attachmentStates.withLock { $0[ObjectIdentifier(testCase)] = session }
        // Take before recording: XCTest synchronously calls observers for the issue.
        if let failure = startup.withLock({ $0.takeFailure() }) {
            let invocation = ProcessInfo.processInfo.environment["GITX_TEST_INVOCATION_ID"] ?? "unconfigured"
            let message = "GitXNativeStartupFailure invocation=\(invocation) operation=\(failure.operation) category=\(failure.category) errno=\(failure.posixCode.map(String.init) ?? "none")"
            testCase.record(XCTIssue(type: .system, compactDescription: message))
        }
    }

    struct Excerpt: Sendable {
        let filename: String
        let start: Int64
        let end: Int64
        let data: Data

        func attachment() -> XCTAttachment {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
            attachment.name = "Native stderr tail: \(filename) [\(start)..<\(end)]"
            attachment.lifetime = .keepAlways
            return attachment
        }
    }

    /// One owned directory index per bundle; quiescent logs never need repeated opens.
    final nonisolated class LogIndex: Sendable {
        private struct State {
            var descriptor: Int32 = -1
            var watcher: (any DispatchSourceFileSystemObject)?
            var known: [String: AttachmentState.Candidate] = [:]
            var directoryStamp: Int64?
            var dirty = true
            var closed = false
            var revision = 0
            var inspections = 0
        }

        private let state = Mutex(State())
        private let directory: String
        private let identity: String

        init?(directory: String?, onDirectoryChange: (@Sendable () -> Void)? = nil, onClosed: (@Sendable () -> Void)? = nil) {
            guard let directory, !directory.isEmpty else { return nil }
            let descriptor = directory.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else {
                Darwin.close(descriptor)
                return nil
            }
            self.directory = directory
            identity = "\(info.st_dev):\(info.st_ino)"
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke],
                queue: DispatchQueue(label: "GitXTests.NativeLogIndex")
            )
            state.withLock {
                $0.descriptor = descriptor
                $0.watcher = watcher
            }
            watcher.setEventHandler { [weak self] in
                self?.state.withLock { $0.dirty = true }
                onDirectoryChange?()
            }
            watcher.setCancelHandler {
                Darwin.close(descriptor)
                onClosed?()
            }
            watcher.resume()
        }

        var inspectionCount: Int {
            state.withLock { $0.inspections }
        }

        func snapshot() -> [AttachmentState.Candidate] {
            // Pin the descriptor while doing I/O outside the shared index lock.
            let inputs = state.withLock { value -> (Int32, Bool, Int64?, Int, [String: AttachmentState.Candidate]) in
                guard !value.closed else { return (-1, false, nil, 0, [:]) }
                let copy = Darwin.dup(value.descriptor)
                guard copy >= 0 else { return (-1, false, nil, 0, [:]) }
                guard fcntl(copy, F_SETFD, FD_CLOEXEC) == 0 else {
                    Darwin.close(copy)
                    return (-1, false, nil, 0, [:])
                }
                return (copy, value.dirty, value.directoryStamp, value.revision, value.known)
            }
            guard inputs.0 >= 0 else { return [] }
            defer { Darwin.close(inputs.0) }
            var info = stat()
            var pathInfo = stat()
            guard fstat(inputs.0, &info) == 0,
                  directory.withCString({ lstat($0, &pathInfo) }) == 0,
                  (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), pathInfo.st_uid == geteuid(),
                  identity == "\(pathInfo.st_dev):\(pathInfo.st_ino)" else { return [] }
            let stamp = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            let discover = inputs.1 || stamp != inputs.2
            let names: [String]
            if discover {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
                names = entries.filter { $0.hasSuffix(".stderr.log") }
            } else {
                names = Array(inputs.4.keys)
            }
            var known: [String: AttachmentState.Candidate] = [:]
            var inspections = 0
            for name in names {
                if let cached = inputs.4[name], cached.finalized {
                    if !discover {
                        known[name] = cached
                        continue
                    }
                    var current = stat()
                    if cached.file.path.withCString({ lstat($0, &current) }) == 0,
                       cached.identity == "\(current.st_dev):\(current.st_ino)",
                       Int64(current.st_size) == cached.end,
                       (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                       Self.modified(current) == cached.modified
                    {
                        known[name] = cached
                        continue
                    }
                }
                inspections += 1
                let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if let candidate = AttachmentState.inspect(file) {
                    known[name] = candidate
                }
            }
            return state.withLock { value in
                guard !value.closed else { return [] }
                value.inspections += inspections
                if value.revision == inputs.3 {
                    value.known = known
                    value.directoryStamp = stamp
                    value.dirty = false
                    value.revision += 1
                }
                return Array(known.values)
            }
        }

        private static func modified(_ info: stat) -> Int64 {
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        }

        func close() {
            let watcher = state.withLock { value -> (any DispatchSourceFileSystemObject)? in
                value.closed = true
                value.known.removeAll()
                let watcher = value.watcher
                value.watcher = nil
                return watcher
            }
            watcher?.cancel()
        }

        deinit { close() }
    }

    /// Different cases do not share a filesystem lock; each case serializes its own byte ranges.
    final nonisolated class CaseAttachments: Sendable {
        private struct State {
            var value: AttachmentState
            let queueKey: DispatchSpecificKey<UInt8>
            var closed = false
        }

        private let state: Mutex<State>
        private let queue = DispatchQueue(label: "GitXTests.CaseAttachments")

        init(candidates: [AttachmentState.Candidate]) {
            let key = DispatchSpecificKey<UInt8>()
            state = Mutex(State(value: AttachmentState(candidates: candidates), queueKey: key))
            queue.setSpecific(key: key, value: 1)
        }

        private func serialized<Result>(_ body: () -> Result) -> Result {
            let key = state.withLock { $0.queueKey }
            if DispatchQueue.getSpecific(key: key) != nil {
                return body()
            }
            return queue.sync(execute: body)
        }

        func take(candidates: [AttachmentState.Candidate]) -> [Excerpt] {
            serialized {
                state.withLock { value in
                    guard !value.closed else { return [] }
                    return value.value.take(in: nil, candidates: candidates)
                }
            }
        }

        func attach(candidates: [AttachmentState.Candidate], to testCase: XCTestCase) {
            serialized {
                // Keep delivery ordered with close, outside the state mutex. Reentrant
                // XCTest issue callbacks can reserve only previously unseen ranges.
                for excerpt in take(candidates: candidates) {
                    testCase.add(excerpt.attachment())
                }
            }
        }

        func close() {
            serialized { state.withLock { $0.closed = true } }
        }
    }

    struct AttachmentState: Sendable {
        static let perFileLimit = 65536
        static let perCaseLimit = 262_144
        private(set) var retainedBytes = 0
        private var offsets: [String: Int64] = [:]
        private var baseline: [String: Int64] = [:]

        struct Candidate: Sendable {
            let file: URL
            let identity: String
            let end: Int64
            let modified: Int64
            let finalized: Bool
        }

        init(in directory: String? = nil, candidates: [Candidate]? = nil) {
            for candidate in candidates ?? Self.candidates(in: directory) {
                baseline[candidate.identity] = candidate.end
            }
            offsets = baseline
        }

        private static func candidates(in directory: String?) -> [Candidate] {
            guard let directory, !directory.isEmpty,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
                  ) else { return [] }
            return files.compactMap(inspect)
        }

        static func inspect(_ file: URL) -> Candidate? {
            guard file.lastPathComponent.hasSuffix(".stderr.log") else { return nil }
            let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid() else { return nil }
            // Shared capture locks follow inherited stderr; a PID check cannot prove quiescence.
            let finalized = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            return Candidate(file: file, identity: "\(info.st_dev):\(info.st_ino)", end: Int64(info.st_size),
                             modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                             finalized: finalized)
        }

        mutating func take(in directory: String?, candidates: [Candidate]? = nil) -> [Excerpt] {
            guard retainedBytes < Self.perCaseLimit else { return [] }
            let candidates = (candidates ?? Self.candidates(in: directory)).filter { $0.end > (offsets[$0.identity] ?? 0) }.sorted {
                let leftIsNew = baseline[$0.identity] == nil
                let rightIsNew = baseline[$1.identity] == nil
                if leftIsNew != rightIsNew {
                    return leftIsNew
                }
                if $0.modified != $1.modified {
                    return $0.modified > $1.modified
                }
                return $0.file.lastPathComponent < $1.file.lastPathComponent
            }
            var excerpts: [Excerpt] = []
            for candidate in candidates {
                guard retainedBytes < Self.perCaseLimit, let excerpt = read(candidate) else { continue }
                retainedBytes += excerpt.data.count
                excerpts.append(excerpt)
            }
            return excerpts
        }

        private mutating func read(_ candidate: Candidate) -> Excerpt? {
            let file = candidate.file
            let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid() else { return nil }
            let identity = "\(info.st_dev):\(info.st_ino)"
            guard identity == candidate.identity else { return nil }
            let previous = offsets[identity] ?? 0
            let end = Int64(info.st_size)
            guard end > previous else { return nil }
            let limit = min(Self.perFileLimit, Self.perCaseLimit - retainedBytes)
            let start = max(previous, end - Int64(limit))
            var bytes = Data(count: Int(end - start))
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                var read = 0
                while read < buffer.count {
                    let count = Darwin.pread(descriptor, buffer.baseAddress?.advanced(by: read), buffer.count - read, off_t(start + Int64(read)))
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else { break }
                    read += count
                }
                return read
            }
            guard count > 0 else { return nil }
            bytes.count = count
            offsets[identity] = start + Int64(count)
            return Excerpt(filename: file.lastPathComponent, start: start, end: start + Int64(count), data: bytes)
        }
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard let session = attachmentStates.withLock({ $0[ObjectIdentifier(testCase)] }) else { return }
        let index = logIndex.withLock { $0 }
        session.attach(candidates: index?.snapshot() ?? [], to: testCase)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let session = attachmentStates.withLock { $0.removeValue(forKey: ObjectIdentifier(testCase)) }
        session?.close()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let index = logIndex.withLock { value in
            let index = value
            value = nil
            return index
        }
        index?.close()
        let sessions = attachmentStates.withLock { value in
            let sessions = Array(value.values)
            value.removeAll()
            return sessions
        }
        sessions.forEach { $0.close() }
    }

    static func failureAttachments(in directory: String?) -> [XCTAttachment] {
        var state = AttachmentState()
        return state.take(in: directory).map { $0.attachment() }
    }
}

// swiftlint:enable unused_declaration
