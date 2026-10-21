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
        // Take before recording: XCTest synchronously calls observers for the issue.
        if let failure = startup.withLock({ $0.takeFailure() }) {
            let invocation = ProcessInfo.processInfo.environment["GITX_TEST_INVOCATION_ID"] ?? "unconfigured"
            let message = "GitXNativeStartupFailure invocation=\(invocation) operation=\(failure.operation) category=\(failure.category) errno=\(failure.posixCode.map(String.init) ?? "none")"
            testCase.record(XCTIssue(type: .system, compactDescription: message))
        }
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        for attachment in Self.failureAttachments(in: ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"]) {
            testCase.add(attachment)
        }
    }

    static func failureAttachments(in directory: String?) -> [XCTAttachment] {
        // Bounded failure diagnostics supplement the complete supervisor-owned raw files.
        guard let directory, !directory.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard file.lastPathComponent.hasSuffix(".stderr.log") else { return nil }
            let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid() else {
                Darwin.close(descriptor)
                return nil
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65536) else { return nil }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
            attachment.name = "Native stderr excerpt: \(file.lastPathComponent)"
            attachment.lifetime = .keepAlways
            return attachment
        }
    }
}
// swiftlint:enable unused_declaration
