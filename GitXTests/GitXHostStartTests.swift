import AppKit
import XCTest

@MainActor
final class GitXHostStartTests: XCTestCase {
    func testHostStarts() {
        XCTAssertNotNil(NSApplication.shared.delegate)
        XCTAssertTrue(Bundle.main.bundleURL.pathExtension == "app")
        if let session = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"] {
            XCTAssertFalse(session.isEmpty)
        }
        let session = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"] ?? "absent"
        let attachment = XCTAttachment(string: "Host PID \(ProcessInfo.processInfo.processIdentifier); bundle \(Bundle.main.bundleURL.path); verificationSession=\(session)")
        attachment.name = "GitX host startup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
