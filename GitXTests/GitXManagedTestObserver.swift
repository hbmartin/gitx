import Foundation
import XCTest

/// This class belongs only to test bundles, including their Release configuration.
// The Objective-C loading shim registers the observer before XCTest starts its bundle.
// swiftlint:disable unused_declaration
@objc(GitXManagedTestObserver)
final nonisolated class GitXManagedTestObserver: NSObject, XCTestObservation, Sendable {
    private static let shared = GitXManagedTestObserver()
    private static let registration: Void = XCTestObservationCenter.shared.addTestObserver(shared)

    @objc static func install() {
        _ = registration
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"], !directory.isEmpty,
              let invocation = environment["GITX_TEST_INVOCATION_ID"], !invocation.isEmpty,
              let session = environment["GITX_VERIFICATION_SESSION"], !session.isEmpty else { return }
        try? GitXTestProgressRecords.write([
            "schemaVersion": 1, "event": "bundle-start", "invocationID": invocation,
            "verificationSession": session, "bundleID": testBundle.bundleIdentifier ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ], prefix: "startup", directory: directory)
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        // A bounded diagnostic attachment supplements the complete supervisor-owned raw files.
        guard let directory = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"], !directory.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".stderr.log") {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink == false,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65536) else { continue }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
            attachment.name = "Native stderr excerpt: \(file.lastPathComponent)"
            attachment.lifetime = .keepAlways
            testCase.add(attachment)
        }
    }
}
// swiftlint:enable unused_declaration
