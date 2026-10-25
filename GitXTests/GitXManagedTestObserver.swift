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
        let baseline = index?.caseSnapshot()
        let session = CaseAttachments(candidates: baseline?.candidates ?? [], preexistingNames: baseline?.names ?? [],
                                      needsBaselineRecovery: baseline?.complete == false)
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

    private enum FileMetadata {
        struct Signature: Equatable, Sendable {
            let identity: String
            let mode: mode_t
            let owner: uid_t
            let bytes: Int64
            let modified: Int64
        }

        static func signature(_ info: stat) -> Signature {
            Signature(identity: "\(info.st_dev):\(info.st_ino)", mode: info.st_mode, owner: info.st_uid,
                      bytes: Int64(info.st_size), modified: modified(info))
        }

        static func signature(at path: String) -> Signature? {
            var info = stat()
            guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
            return signature(info)
        }

        static func modified(_ info: stat) -> Int64 {
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        }

        static func ownedDirectory(_ path: String) -> (Int32, stat)? {
            let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            else {
                Darwin.close(descriptor)
                return nil
            }
            return (descriptor, info)
        }
    }

    /// One owned directory index per bundle; failed inspections stay pending.
    final nonisolated class LogIndex: Sendable {
        /// Each channel gets eight rotating retries: at most sixteen per snapshot,
        /// including when one channel has a permanently unreadable entry.
        private static let retryLimit = 8

        private struct State {
            var descriptor: Int32 = -1
            var watcher: (any DispatchSourceFileSystemObject)?
            var known: [String: AttachmentState.Candidate] = [:]
            var names = Set<String>()
            var pending: [String] = []
            var directoryStamp: Int64?
            var dirty = true
            var closed = false
            var revision = 0
            var inspections = 0
            var retryInspections = 0
        }

        struct CaseBaseline: Sendable {
            let candidates: [AttachmentState.Candidate]
            let names: Set<String>
            let complete: Bool
        }

        private struct Inputs {
            let descriptor: Int32
            let dirty: Bool
            let stamp: Int64?
            let revision: Int
            let known: [String: AttachmentState.Candidate]
            let names: Set<String>
            let pending: [String]
        }

        private struct CaptureRecords {
            var stamps: [String: Int64] = [:]
            var names: [String: Set<String>] = [:]
            var accepted: [String: (filename: String, signature: FileMetadata.Signature)] = [:]
            var invalid: [String: FileMetadata.Signature] = [:]
            var pending: [String] = []
            var retryInspections = 0
        }

        private let records = Mutex(CaptureRecords())
        private let scans = NSLock()
        private let invocationID: String?
        private let verificationSession: String?
        private let progressDirectory: String?
        private let invalidateSnapshot: (@Sendable () -> Bool)?

        private enum CaptureInspection {
            case ready(String, FileMetadata.Signature)
            case invalid(FileMetadata.Signature)
            case retry
        }

        private func inspectCapture(_ path: String) -> CaptureInspection {
            guard let invocationID, let verificationSession,
                  let expected = FileMetadata.signature(at: path) else { return .retry }
            guard expected.mode & mode_t(S_IFMT) == mode_t(S_IFREG), expected.owner == geteuid(),
                  expected.bytes >= 0, expected.bytes <= 65536 else { return .invalid(expected) }
            let file = URL(fileURLWithPath: path)
            guard let (parent, _) = FileMetadata.ownedDirectory(file.deletingLastPathComponent().path) else { return .retry }
            defer { Darwin.close(parent) }
            let descriptor = file.lastPathComponent.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return .retry }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, FileMetadata.signature(info) == expected else { return .retry }
            var data = Data(count: Int(info.st_size))
            let size = data.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
            var after = stat()
            guard size == data.count, fstat(descriptor, &after) == 0,
                  FileMetadata.signature(after) == expected, FileMetadata.signature(at: path) == expected else { return .retry }
            guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["schemaVersion"] as? Int == 1, record["event"] as? String == "capture",
                  record["state"] as? String == "captured", record["invocationID"] as? String == invocationID,
                  record["verificationSession"] as? String == verificationSession,
                  let pid = record["pid"] as? Int, pid > 0,
                  URL(fileURLWithPath: path).lastPathComponent.hasPrefix("capture-\(pid)-"),
                  let filename = record["filename"] as? String,
                  filename.hasPrefix("GitX-\(pid)-"), filename.hasSuffix(".stderr.log"),
                  !filename.contains("/"), !filename.contains("\\") else { return .invalid(expected) }
            return .ready(filename, expected)
        }

        private func readyCaptures() -> Set<String> {
            guard invocationID != nil, verificationSession != nil else { return [] }
            var cached = records.withLock { $0 }
            var discovered: [String] = []
            for directory in Set([directory, progressDirectory].compactMap { $0 }).sorted() {
                guard let (parent, info) = FileMetadata.ownedDirectory(directory) else { continue }
                defer { Darwin.close(parent) }
                let stamp = FileMetadata.modified(info)
                guard cached.stamps[directory] != stamp else { continue }
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
                let names = Set(entries.filter { $0.hasPrefix("capture-") && $0.hasSuffix(".json") })
                for name in names.sorted() {
                    let path = directory + "/" + name
                    if let accepted = cached.accepted[path], FileMetadata.signature(at: path) != accepted.signature {
                        cached.accepted.removeValue(forKey: path)
                        discovered.append(path)
                    } else if !(cached.names[directory] ?? []).contains(name) {
                        discovered.append(path)
                    }
                }
                cached.names[directory] = names
                cached.stamps[directory] = stamp
            }
            // Only successful listings can prove that pending evidence disappeared.
            let present = Set(cached.names.flatMap { directory, names in names.map { directory + "/" + $0 } })
            cached.pending.removeAll { !present.contains($0) }
            cached.accepted = cached.accepted.filter { present.contains($0.key) }
            cached.invalid = cached.invalid.filter { present.contains($0.key) }
            let retry = Array(cached.pending.prefix(Self.retryLimit))
            cached.pending.removeFirst(retry.count)
            var inspected = Set<String>()
            for path in discovered + retry where cached.accepted[path] == nil && inspected.insert(path).inserted {
                if let invalid = cached.invalid[path], FileMetadata.signature(at: path) == invalid {
                    // Rotate a cheap identity probe; do not reopen unchanged invalid records.
                    cached.pending.append(path)
                    continue
                }
                cached.invalid.removeValue(forKey: path)
                if retry.contains(path) {
                    cached.retryInspections += 1
                }
                switch inspectCapture(path) {
                case let .ready(filename, signature):
                    cached.accepted[path] = (filename, signature)
                case let .invalid(signature):
                    cached.invalid[path] = signature
                    cached.pending.append(path)
                case .retry:
                    cached.pending.append(path)
                }
            }
            records.withLock { $0 = cached }
            return Set(cached.accepted.values.map(\.filename))
        }

        private let state = Mutex(State())
        private let directory: String
        private let identity: String

        init?(directory: String?, invocationID: String? = ProcessInfo.processInfo.environment["GITX_TEST_INVOCATION_ID"],
              verificationSession: String? = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"],
              progressDirectory: String? = ProcessInfo.processInfo.environment["GITX_TEST_PROGRESS_DIRECTORY"], onDirectoryChange: (@Sendable () -> Void)? = nil, onClosed: (@Sendable () -> Void)? = nil,
              invalidateSnapshot: (@Sendable () -> Bool)? = nil)
        {
            guard let directory, !directory.isEmpty, let (descriptor, info) = FileMetadata.ownedDirectory(directory) else { return nil }
            self.directory = directory
            self.invocationID = invocationID
            self.verificationSession = verificationSession
            self.progressDirectory = progressDirectory
            self.invalidateSnapshot = invalidateSnapshot
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
                self?.directoryDidChange()
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

        var retryInspectionCount: Int {
            state.withLock { $0.retryInspections } + records.withLock { $0.retryInspections }
        }

        private func directoryDidChange() {
            state.withLock {
                guard !$0.closed else { return }
                $0.dirty = true
                $0.revision += 1
            }
        }

        private func inputs() -> Inputs? {
            state.withLock { value in
                guard !value.closed else { return nil }
                let copy = Darwin.dup(value.descriptor)
                guard copy >= 0 else { return nil }
                guard fcntl(copy, F_SETFD, FD_CLOEXEC) == 0 else {
                    Darwin.close(copy)
                    return nil
                }
                return Inputs(descriptor: copy, dirty: value.dirty, stamp: value.directoryStamp,
                              revision: value.revision, known: value.known, names: value.names, pending: value.pending)
            }
        }

        func snapshot() -> [AttachmentState.Candidate] {
            caseSnapshot().candidates
        }

        func caseSnapshot() -> CaseBaseline {
            // Per-index scans do I/O outside the global case-state lock. Closure
            // only marks state and cancels the watcher; it never waits for a scan.
            scans.lock()
            defer { scans.unlock() }
            guard let inputs = inputs() else { return CaseBaseline(candidates: [], names: [], complete: false) }
            defer { Darwin.close(inputs.descriptor) }
            var info = stat()
            var pathInfo = stat()
            guard fstat(inputs.descriptor, &info) == 0,
                  directory.withCString({ lstat($0, &pathInfo) }) == 0,
                  (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), pathInfo.st_uid == geteuid(),
                  identity == "\(pathInfo.st_dev):\(pathInfo.st_ino)" else { return CaseBaseline(candidates: [], names: [], complete: false) }
            let stamp = FileMetadata.modified(info)
            let discover = inputs.dirty || stamp != inputs.stamp
            let names: Set<String>
            if discover {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return CaseBaseline(candidates: [], names: [], complete: false) }
                names = Set(entries.filter { $0.hasSuffix(".stderr.log") })
            } else {
                names = inputs.names
            }
            var pending = inputs.pending.filter { names.contains($0) }
            let retry = Set(pending.prefix(Self.retryLimit))
            pending.removeFirst(retry.count)
            let ready = readyCaptures()
            var known: [String: AttachmentState.Candidate] = [:]
            var inspections = 0
            for name in names.sorted() {
                if let cached = inputs.known[name], cached.finalized {
                    if !discover {
                        known[name] = cached
                        continue
                    }
                    var current = stat()
                    if cached.file.path.withCString({ lstat($0, &current) }) == 0,
                       cached.identity == "\(current.st_dev):\(current.st_ino)", Int64(current.st_size) == cached.end,
                       current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                       FileMetadata.modified(current) == cached.modified
                    {
                        known[name] = cached
                        continue
                    }
                }
                guard inputs.known[name] != nil || !inputs.names.contains(name) || retry.contains(name) else { continue }
                inspections += 1
                let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if let candidate = AttachmentState.inspect(file, mayFinalize: ready.contains(name)) {
                    known[name] = candidate
                } else if !pending.contains(name) {
                    pending.append(name)
                }
            }
            if invalidateSnapshot?() == true {
                directoryDidChange()
            }
            return state.withLock { value in
                guard !value.closed else { return CaseBaseline(candidates: [], names: [], complete: false) }
                value.inspections += inspections
                value.retryInspections += retry.count
                let complete = value.revision == inputs.revision
                value.names = names
                // The event invalidates directory discovery, not a successfully
                // inspected file. Active candidates are revalidated next time;
                // only failed inspections belong in the bounded retry queue.
                value.known = known
                if complete {
                    value.directoryStamp = stamp
                    value.dirty = false
                } else {
                    value.dirty = true
                }
                value.pending = pending
                value.revision += 1
                return CaseBaseline(candidates: Array(known.values), names: names, complete: complete)
            }
        }

        func close() {
            let watcher = state.withLock { value -> (any DispatchSourceFileSystemObject)? in
                value.closed = true
                value.known.removeAll()
                value.names.removeAll()
                value.pending.removeAll()
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
            var closed = false
        }

        private let state: Mutex<State>

        init(candidates: [AttachmentState.Candidate], preexistingNames: Set<String> = [], needsBaselineRecovery: Bool = false) {
            state = Mutex(State(value: AttachmentState(candidates: candidates, preexistingNames: preexistingNames,
                                                       needsBaselineRecovery: needsBaselineRecovery)))
        }

        func take(candidates: [AttachmentState.Candidate]) -> [Excerpt] {
            state.withLock { value in
                guard !value.closed else { return [] }
                return value.value.take(in: nil, candidates: candidates)
            }
        }

        func take(snapshot: LogIndex.CaseBaseline) -> [Excerpt] {
            state.withLock { value in
                guard !value.closed else { return [] }
                return value.value.take(in: nil, candidates: snapshot.candidates, names: snapshot.names, complete: snapshot.complete)
            }
        }

        func attach(snapshot: LogIndex.CaseBaseline, to testCase: XCTestCase) {
            deliver(excerpts: take(snapshot: snapshot)) { testCase.add($0.attachment()) }
        }

        /// Test-support seam; real delivery remains on the observer's calling thread.
        func deliver(candidates: [AttachmentState.Candidate], delivery: (Excerpt) -> Void) {
            deliver(excerpts: take(candidates: candidates), delivery: delivery)
        }

        private func deliver(excerpts: [Excerpt], delivery: (Excerpt) -> Void) {
            for excerpt in excerpts {
                // This is the delivery admission point. Close rejects subsequent
                // admissions without waiting for callbacks already admitted here.
                guard state.withLock({ !$0.closed }) else { return }
                delivery(excerpt)
            }
        }

        func close() {
            state.withLock { $0.closed = true }
        }
    }

    struct AttachmentState: Sendable {
        static let perFileLimit = 65536
        static let perCaseLimit = 262_144
        private(set) var retainedBytes = 0
        private var offsets: [String: Int64] = [:]
        private var baseline: [String: Int64] = [:]
        private var unresolvedBaselineNames: Set<String>
        private var needsBaselineRecovery: Bool

        struct Candidate: Sendable {
            let file: URL
            let identity: String
            let end: Int64
            let modified: Int64
            let finalized: Bool
        }

        init(in directory: String? = nil, candidates: [Candidate]? = nil, preexistingNames: Set<String> = [], needsBaselineRecovery: Bool = false) {
            let initial = candidates ?? Self.candidates(in: directory)
            for candidate in initial {
                baseline[candidate.identity] = candidate.end
            }
            unresolvedBaselineNames = preexistingNames.subtracting(initial.map { $0.file.lastPathComponent })
            self.needsBaselineRecovery = needsBaselineRecovery
            offsets = baseline
        }

        private static func candidates(in directory: String?) -> [Candidate] {
            guard let directory, !directory.isEmpty,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
                  ) else { return [] }
            return files.compactMap { inspect($0) }
        }

        static func inspect(_ file: URL, mayFinalize: Bool = false) -> Candidate? {
            guard file.lastPathComponent.hasSuffix(".stderr.log") else { return nil }
            let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid() else { return nil }
            // Shared capture locks follow inherited stderr; a PID check cannot prove quiescence.
            let finalized = mayFinalize && flock(descriptor, LOCK_EX | LOCK_NB) == 0
            return Candidate(file: file, identity: "\(info.st_dev):\(info.st_ino)", end: Int64(info.st_size),
                             modified: FileMetadata.modified(info),
                             finalized: finalized)
        }

        mutating func take(in directory: String?, candidates: [Candidate]? = nil, names: Set<String>? = nil, complete: Bool = false) -> [Excerpt] {
            guard retainedBytes < Self.perCaseLimit else { return [] }
            let available = candidates ?? Self.candidates(in: directory)
            if needsBaselineRecovery {
                unresolvedBaselineNames.formUnion(names ?? Set(available.map { $0.file.lastPathComponent }))
            }
            for candidate in available where needsBaselineRecovery || unresolvedBaselineNames.contains(candidate.file.lastPathComponent) {
                // The old prefix could not be inspected at case start. Never
                // attach unproven pre-case bytes; complete raw logs remain archived.
                if baseline[candidate.identity] == nil {
                    baseline[candidate.identity] = candidate.end
                    offsets[candidate.identity] = candidate.end
                }
                unresolvedBaselineNames.remove(candidate.file.lastPathComponent)
            }
            if complete {
                needsBaselineRecovery = false
            }
            let candidates = available.filter { $0.end > (offsets[$0.identity] ?? 0) }.sorted {
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
        session.attach(snapshot: index?.caseSnapshot() ?? .init(candidates: [], names: [], complete: false), to: testCase)
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
