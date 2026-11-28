@testable import GitX
import GitXCore
import XCTest

/// The Git LFS Details, confirmation and progress sheets, and the window's download menu eligibility.
@MainActor
final class RepositoryLFSSheetsTests: XCTestCase {
    private typealias Snapshot = GitX.RepositoryLFSStatusSnapshot
    private let available = LFSToolStatus.available(version: "3.8.1")

    private func summary(_ paths: [String], truncated: Bool = false) -> LFSWorktreeSummary {
        LFSWorktreeSummary(pointerCount: paths.count + 1, notDownloadedPaths: paths, notDownloadedBytes: 4000 * Int64(paths.count), isTruncated: truncated)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: Details

    func testDetailsOffersDownloadAllAndListsTheFilesNotDownloaded() throws {
        let sheet = GitX.RepositoryLFSDetailsSheet(snapshot: Snapshot(tool: available, summary: summary(["a.bin", "assets/b c.png"])))
        XCTAssertTrue(sheet.canDownloadAll)
        XCTAssertEqual(sheet.alert.messageText, "Git LFS")
        XCTAssertEqual(sheet.alert.buttons.map(\.title), ["Download All…", "Close"])
        XCTAssertEqual(sheet.alert.buttons.map { $0.accessibilityIdentifier() }, ["GitX.LFS.Details.DownloadAll", "GitX.LFS.Details.Close"])
        XCTAssertEqual(sheet.pathList.string, "a.bin\nassets/b c.png")
        XCTAssertFalse(sheet.pathList.isEditable)
        XCTAssertEqual(sheet.pathList.accessibilityIdentifier(), "GitX.LFS.Details.Paths")
        XCTAssertNotNil(sheet.alert.accessoryView)

        let host = window()
        var choices: [Bool] = []
        sheet.present(for: host) { choices.append($0) }
        XCTAssertTrue(host.attachedSheet === sheet.alert.window)
        try attachScreenshot(of: XCTUnwrap(sheet.alert.window.contentView), named: "Git LFS - Details")
        host.endSheet(sheet.alert.window, returnCode: .alertFirstButtonReturn)
        XCTAssertEqual(choices, [true])
    }

    func testDetailsWithoutAUsableToolOnlyExplains() {
        for tool in [LFSToolStatus.missing, .unsupported(version: "2.13.3"), .unrecognized] {
            let sheet = GitX.RepositoryLFSDetailsSheet(snapshot: Snapshot(tool: tool, summary: summary(["a.bin"])))
            XCTAssertFalse(sheet.canDownloadAll, "\(tool)")
            XCTAssertEqual(sheet.alert.buttons.map(\.title), ["Close"])
            XCTAssertEqual(sheet.alert.informativeText, LFSPresentation.detailsText(summary: summary(["a.bin"]), tool: tool))
            let host = window()
            var choices: [Bool] = []
            sheet.present(for: host) { choices.append($0) }
            host.endSheet(sheet.alert.window, returnCode: .alertFirstButtonReturn)
            XCTAssertEqual(choices, [false], "Close is the first button when there is nothing to download")
        }
        let downloaded = GitX.RepositoryLFSDetailsSheet(snapshot: Snapshot(tool: available, summary: summary([])))
        XCTAssertFalse(downloaded.canDownloadAll)
        XCTAssertNil(downloaded.alert.accessoryView)
        XCTAssertEqual(downloaded.alert.informativeText, "Every Git LFS file in this checkout is downloaded.")
    }

    func testDetailsListsAtMostTheVisibleLimit() {
        let paths = (0 ... GitX.RepositoryLFSDetailsSheet.visiblePathLimit).map { "file\($0).bin" }
        let sheet = GitX.RepositoryLFSDetailsSheet(snapshot: Snapshot(tool: available, summary: summary(paths)))
        let lines = sheet.pathList.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, GitX.RepositoryLFSDetailsSheet.visiblePathLimit + 1)
        XCTAssertEqual(lines.last, "…and 1 more")
    }

    // MARK: Confirmation

    func testConfirmationNamesHowManyFilesItWillDownload() throws {
        let one = try GitX.RepositoryLFSDownloadConfirmation.alert(for: LFSDownloadPlan.make(.paths(["a.bin"])).get(), summary: summary(["a.bin", "b.bin"]))
        XCTAssertEqual(one.messageText, "Download Git LFS content for 1 file?")
        XCTAssertEqual(one.buttons.map(\.title), ["Download", "Cancel"])
        XCTAssertEqual(one.buttons.map { $0.accessibilityIdentifier() }, ["GitX.LFS.Confirm.Download", "GitX.LFS.Confirm.Cancel"])
        let all = try GitX.RepositoryLFSDownloadConfirmation.alert(for: LFSDownloadPlan.make(.all).get(), summary: summary(["a.bin", "b.bin"]))
        XCTAssertEqual(all.messageText, "Download Git LFS content for 2 files?")
        XCTAssertTrue(all.informativeText.contains("writing the files cannot be interrupted"))
    }

    // MARK: Progress

    func testProgressSheetIsDeterminateWhileFetchingAndCannotCancelWhileFinishing() throws {
        let sheet = GitX.RepositoryLFSDownloadSheet()
        XCTAssertEqual(sheet.panel.accessibilityIdentifier(), "GitX.LFS.Download")
        sheet.show(.fetching(fraction: nil, detail: nil))
        XCTAssertEqual(sheet.titleLabel.stringValue, "Downloading Git LFS content…")
        XCTAssertEqual(sheet.detailLabel.stringValue, "Contacting the remote…")
        XCTAssertTrue(sheet.progress.isIndeterminate)
        XCTAssertTrue(sheet.cancelButton.isEnabled)

        sheet.show(.fetching(fraction: 0.4, detail: "2 of 5 files — 4 MB of 10 MB"))
        XCTAssertFalse(sheet.progress.isIndeterminate)
        XCTAssertEqual(sheet.progress.doubleValue, 40, accuracy: 0.001)
        XCTAssertEqual(sheet.detailLabel.stringValue, "2 of 5 files — 4 MB of 10 MB")
        sheet.panel.contentView?.layoutSubtreeIfNeeded()
        try attachScreenshot(of: XCTUnwrap(sheet.panel.contentView), named: "Git LFS - Download - Fetching")

        sheet.show(.finishing)
        XCTAssertEqual(sheet.titleLabel.stringValue, "Finishing…")
        XCTAssertTrue(sheet.progress.isIndeterminate)
        XCTAssertFalse(sheet.cancelButton.isEnabled)
        try attachScreenshot(of: XCTUnwrap(sheet.panel.contentView), named: "Git LFS - Download - Finishing")
    }

    func testProgressSheetRunsTheOperationAndClosesWithItsFinalPhase() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSSheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        let executable = fake.appendingPathComponent("git")
        try "#!/bin/sh\n[ \"$2\" = fetch ] && sleep 30\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plan = try LFSDownloadPlan.make(.all).get()
        let host = window()
        let sheet = GitX.RepositoryLFSDownloadSheet()
        let closed = expectation(description: "the sheet closes")
        var final: GitX.RepositoryLFSDownloadOperation.Phase?
        sheet.run(for: host, operation: { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, makeTask: { arguments in
                PBTask(launchPath: executable.path, arguments: arguments, inDirectory: fake.path)
            }, update: update)
        }) { phase in
            final = phase
            closed.fulfill()
        }
        XCTAssertTrue(host.attachedSheet === sheet.panel)
        sheet.cancelButton.performClick(nil)
        wait(for: [closed], timeout: 10)
        XCTAssertEqual(final, .cancelled)
        XCTAssertNil(host.attachedSheet)
    }

    // MARK: Window eligibility

    func testWindowHidesDownloadOutsideCheckoutsThatUseGitLFS() {
        let controller = GitX.PBGitWindowController(window: NSWindow())
        let item = NSMenuItem(title: "Download LFS Content", action: #selector(GitX.PBGitWindowController.downloadLFSContent(_:)), keyEquivalent: "")
        item.representedObject = ["a.bin"]
        XCTAssertEqual(controller.lfsStatusSnapshot, Snapshot.none)
        XCTAssertFalse(controller.validateLFSDownload(item))
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(controller.validateMenuItem(item))
        controller.downloadLFSContent(item)
        XCTAssertNil(controller.window?.attachedSheet, "Without a repository nothing is downloaded")
    }
}
