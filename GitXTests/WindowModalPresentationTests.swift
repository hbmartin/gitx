import AppKit
@testable import GitX
import XCTest

/// Terminal, Raycast, and folder choices attach to the window that asked instead of blocking the app.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every window, sheet and fixture stays on main.
final class WindowModalPresentationTests: XCTestCase, @unchecked Sendable {
    private var restorers: [() -> Void] = []
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
        restorers = [
            "PBTerminalBundleIdentifier", "PBTerminalInitialCommand",
            "PBCustomTerminalExecutable", "PBCustomTerminalArguments",
            "PBRaycastScriptsDirectory",
        ].map(preservePersistentDefault(forKey:))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: .titled, backing: .buffered, defer: false)
    }

    private func dismissPresentations() {
        GitX.WindowModalPresenter.directoryChooserOverride = nil
        while let sheet = window?.attachedSheet {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        window = nil
        restorers.reversed().forEach { $0() }
        restorers = []
    }

    func testAlertsAttachToTheirWindowAndReportTheChosenButton() throws {
        var responses: [NSApplication.ModalResponse] = []
        let alert = NSAlert()
        alert.messageText = "Sheet Presentation"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        GitX.WindowModalPresenter.present(alert, for: window) { responses.append($0) }

        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
        try end(window.attachedSheet, response: .alertSecondButtonReturn)
        XCTAssertEqual(responses, [.alertSecondButtonReturn])
    }

    func testTerminalChooserIsASheetAndOnlyAnAcceptedChoiceIsRemembered() throws {
        ApplicationSettings.terminalBundleIdentifier = nil
        ApplicationSettings.customTerminalExecutable = "/usr/bin/true"
        ApplicationSettings.customTerminalArguments = ""
        let directory = FileManager.default.temporaryDirectory

        TerminalLauncher.shared.open(directory: directory, presenting: window)
        let cancelled = try XCTUnwrap(window.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(texts(in: cancelled.contentView).contains("Choose a Terminal Application"))
        try attachScreenshot(of: cancelled, named: "Terminal-Chooser-Sheet")
        try end(cancelled, response: .alertSecondButtonReturn)
        XCTAssertNil(ApplicationSettings.terminalBundleIdentifier)

        TerminalLauncher.shared.open(directory: directory, presenting: window)
        let accepted = try XCTUnwrap(window.attachedSheet)
        let popup = try XCTUnwrap(firstSubview(of: NSPopUpButton.self, in: accepted.contentView))
        popup.selectItem(at: popup.numberOfItems - 1)
        XCTAssertEqual(popup.titleOfSelectedItem, "Custom")
        try end(accepted, response: .alertFirstButtonReturn)
        XCTAssertEqual(ApplicationSettings.terminalBundleIdentifier, "custom")
        XCTAssertNil(window.attachedSheet, "Launching the accepted custom terminal must not report an error")
    }

    func testModifiedRaycastScriptIsReplacedOnlyAfterTheSheetIsAccepted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXRaycast-Sheet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ApplicationSettings.raycastScriptsDirectory = directory.path
        IntegrationManager.shared.installRaycastScripts(presenting: window)
        XCTAssertTrue(texts(in: window.attachedSheet?.contentView).contains("Raycast Commands Installed"))
        try end(window.attachedSheet, response: .alertFirstButtonReturn)
        let script = directory.appendingPathComponent("gitx-raycast-open-repository.sh")
        let managed = try String(contentsOf: script, encoding: .utf8)
        let modified = managed + "\n# user customization\n"
        try modified.write(to: script, atomically: true, encoding: .utf8)

        IntegrationManager.shared.installRaycastScripts(presenting: window)
        let declined = try XCTUnwrap(window.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(texts(in: declined.contentView).contains("Replace Modified Raycast Script?"))
        try attachScreenshot(of: declined, named: "Raycast-Replace-Modified-Sheet")
        try end(declined, response: .alertSecondButtonReturn)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), modified)
        XCTAssertNil(window.attachedSheet, "Declining stops the installation without a success message")

        IntegrationManager.shared.installRaycastScripts(presenting: window)
        try end(window.attachedSheet, response: .alertFirstButtonReturn)
        try waitForSheet()
        XCTAssertTrue(texts(in: window.attachedSheet?.contentView).contains("Raycast Commands Installed"))
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), managed)
    }

    func testRaycastFolderChoicesAttachToTheirWindowAndCancellingInstallsNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXRaycast-Choice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ApplicationSettings.raycastScriptsDirectory = ""
        var requests: [(prompt: String, window: NSWindow?)] = []
        var answer: URL?
        GitX.WindowModalPresenter.directoryChooserOverride = { prompt, window, completion in
            requests.append((prompt, window))
            completion(answer)
        }

        IntegrationManager.shared.installRaycastScripts(presenting: window)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.prompt, "Choose")
        XCTAssertTrue(requests.first?.window === window)
        XCTAssertEqual(ApplicationSettings.raycastScriptsDirectory, "")
        XCTAssertNil(window.attachedSheet)
        IntegrationManager.shared.removeRaycastScripts(presenting: window)
        XCTAssertEqual(requests.count, 1, "Removing never asks for a folder")

        answer = directory
        IntegrationManager.shared.installRaycastScripts(presenting: window)
        XCTAssertEqual(ApplicationSettings.raycastScriptsDirectory, directory.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)

        let pane = SettingsViewFactory.integrationView()
        window.contentView = pane
        let choose = try XCTUnwrap(firstSubview(of: NSButton.self, in: pane) { $0.title == "Choose Raycast Scripts Folder…" })
        answer = nil
        choose.performClick(nil)
        XCTAssertTrue(requests.last?.window === window)
        XCTAssertEqual(ApplicationSettings.raycastScriptsDirectory, directory.path, "Cancelling keeps the folder")
        let replacement = directory.appendingPathComponent("Replacement", isDirectory: true)
        answer = replacement
        choose.performClick(nil)
        XCTAssertEqual(ApplicationSettings.raycastScriptsDirectory, replacement.path)
    }

    func testRealFolderPanelAttachesAsASheetAndCancelCompletesWithoutAFolder() throws {
        var results: [URL?] = []
        window.makeKeyAndOrderFront(nil)

        GitX.WindowModalPresenter.chooseDirectory(prompt: "Choose", for: window) { results.append($0) }

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

    private func waitForSheet() throws {
        try waitUntil { self.window.attachedSheet != nil }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the presentation")
    }

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(texts(in:))
    }

    private func firstSubview<View: NSView>(
        of type: View.Type,
        in view: NSView?,
        where matches: (View) -> Bool = { _ in true }
    ) -> View? {
        guard let view else { return nil }
        if let match = view as? View, matches(match) {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview, where: matches) {
                return match
            }
        }
        return nil
    }

    private func preservePersistentDefault(forKey key: String) -> () -> Void {
        let defaults = UserDefaults.standard
        let original = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0)?[key] }
        return {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
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
