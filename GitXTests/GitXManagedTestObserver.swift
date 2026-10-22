import Darwin
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
    private let attachmentStates = Mutex<[ObjectIdentifier: AttachmentState]>([:])

    @objc static func install() {
        _ = registration
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let environment = ProcessInfo.processInfo.environment
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
        let directory = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"]
        attachmentStates.withLock { $0[ObjectIdentifier(testCase)] = AttachmentState(in: directory) }
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

    struct AttachmentState: Sendable {
        static let perFileLimit = 65536
        static let perCaseLimit = 262_144
        private(set) var retainedBytes = 0
        private var offsets: [String: Int64] = [:]
        private var baseline: [String: Int64] = [:]

        private struct Candidate {
            let file: URL
            let identity: String
            let end: Int64
            let modified: Int64
        }

        init(in directory: String? = nil) {
            for candidate in Self.candidates(in: directory) {
                baseline[candidate.identity] = candidate.end
            }
            offsets = baseline
        }

        private static func candidates(in directory: String?) -> [Candidate] {
            guard let directory, !directory.isEmpty,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
                  ) else { return [] }
            return files.compactMap { file in
                guard file.lastPathComponent.hasSuffix(".stderr.log") else { return nil }
                let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                guard descriptor >= 0 else { return nil }
                defer { Darwin.close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      info.st_uid == geteuid() else { return nil }
                return Candidate(file: file, identity: "\(info.st_dev):\(info.st_ino)", end: Int64(info.st_size),
                                 modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
            }
        }

        mutating func take(in directory: String?) -> [Excerpt] {
            guard retainedBytes < Self.perCaseLimit else { return [] }
            let candidates = Self.candidates(in: directory).filter { $0.end > (offsets[$0.identity] ?? 0) }.sorted {
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
        let excerpts = attachmentStates.withLock { states in
            var state = states[ObjectIdentifier(testCase)] ?? AttachmentState()
            let excerpts = state.take(in: ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"])
            states[ObjectIdentifier(testCase)] = state
            return excerpts
        }
        for excerpt in excerpts {
            testCase.add(excerpt.attachment())
        }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        _ = attachmentStates.withLock { $0.removeValue(forKey: ObjectIdentifier(testCase)) }
    }

    static func failureAttachments(in directory: String?) -> [XCTAttachment] {
        var state = AttachmentState()
        return state.take(in: directory).map { $0.attachment() }
    }
}

// swiftlint:enable unused_declaration
