import AppKit
@testable import GitX
import XCTest

/// Alerts and folder choices attach to the window that asked instead of blocking the app.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every window, sheet and fixture stays on main.
final class WindowModalPresentationTests: XCTestCase, @unchecked Sendable {
    private var window: NSWindow!

    override nonisolated func setUp() {
        super.setUp()
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture setup on the main thread.
        MainActor.assumeIsolated { prepareWindow() }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture teardown on the main thread.
        MainActor.assumeIsolated { dismissPresentations() }
        super.tearDown()
    }

    private func prepareWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: .titled, backing: .buffered, defer: false)
    }

    private func dismissPresentations() {
        WindowModalPresenter.directoryChooserOverride = nil
        while let sheet = window?.attachedSheet {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        window = nil
    }

    func testAlertsAttachToTheirWindowAndReportTheChosenButton() throws {
        var responses: [NSApplication.ModalResponse] = []
        let alert = NSAlert()
        alert.messageText = "Sheet Presentation"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        WindowModalPresenter.present(alert, for: window) { responses.append($0) }

        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
        try end(window.attachedSheet, response: .alertSecondButtonReturn)
        XCTAssertEqual(responses, [.alertSecondButtonReturn])
    }

    func testRealFolderPanelAttachesAsASheetAndCancelCompletesWithoutAFolder() throws {
        var results: [URL?] = []
        window.makeKeyAndOrderFront(nil)

        WindowModalPresenter.chooseDirectory(prompt: "Choose", for: window) { results.append($0) }

        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertEqual(panel.prompt, "Choose")
        XCTAssertNil(NSApp.modalWindow)
        window.endSheet(panel, returnCode: .cancel)
        try waitUntil { results.count == 1 }
        XCTAssertEqual(results, [nil])
    }

    // MARK: - Helpers

    private func end(_ sheet: NSWindow?, response: NSApplication.ModalResponse) throws {
        let sheet = try XCTUnwrap(sheet)
        window.endSheet(sheet, returnCode: response)
        sheet.orderOut(nil)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the presentation")
    }
}

/// VoiceOver announcements go through one seam so app-hosted tests can observe them.
@MainActor
final class AccessibilityAnnouncerTests: XCTestCase {
    func testAnnouncementsPostNonEmptyMessagesFromTheirElementOrTheApplication() {
        var posted: [(message: String, element: AnyObject)] = []
        let restore = AccessibilityAnnouncer.post
        AccessibilityAnnouncer.post = { message, element in posted.append((message, element as AnyObject)) }
        defer { AccessibilityAnnouncer.post = restore }
        let field = NSTextField(labelWithString: "Status")

        AccessibilityAnnouncer.announce("Saved", from: field)
        AccessibilityAnnouncer.announce("", from: field)
        AccessibilityAnnouncer.announce("Application", from: nil)

        XCTAssertEqual(posted.map(\.message), ["Saved", "Application"])
        XCTAssertTrue(posted.first?.element === field)
        XCTAssertTrue(posted.last?.element === NSApp)
    }

    func testDefaultPostDeliversWithoutVoiceOver() {
        AccessibilityAnnouncer.post("Delivered without an assistive client", NSTextField(labelWithString: "Status"))
    }
}
