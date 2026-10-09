import AppKit
import XCTest

@MainActor
final class PushOutputExportCoordinatorTests: XCTestCase {
    #if DEBUG
        func testPendingSavePanelRejectsRepeatedRequests() async {
            let result = await facts(for: "pending")
            XCTAssertEqual(result["panels"], 1)
            XCTAssertEqual(result["writes"], 0)
            XCTAssertEqual(result["finished"], 0)
        }

        func testLateCancellationDoesNotReleaseAnotherPendingSavePanel() async {
            let result = await facts(for: "late-cancel")
            XCTAssertEqual(result["panels"], 2)
            XCTAssertEqual(result["writes"], 0)
            XCTAssertEqual(result["finished"], 0)
        }

        func testCancellationAndMissingDestinationAllowAnotherSave() async {
            for scenario in ["cancel", "missing-destination"] {
                let result = await facts(for: scenario)
                XCTAssertEqual(result["panels"], 2, scenario)
                XCTAssertEqual(result["writes"], 0, scenario)
                XCTAssertEqual(result["buttonEnabledAfterCancellation"], 1, scenario)
            }
        }

        func testButtonWithoutWindowDoesNotPresentSavePanel() async {
            let result = await facts(for: "windowless")
            XCTAssertEqual(result["panels"], 0)
            XCTAssertEqual(result["writes"], 0)
        }

        func testSuccessfulWriterReceivesOwnedArtifactAndSelectedDestination() async {
            let result = await facts(for: "success")
            XCTAssertEqual(result["panels"], 1)
            XCTAssertEqual(result["panelUsesSenderWindow"], 1)
            XCTAssertEqual(result["writes"], 1)
            XCTAssertEqual(result["writerUsesOwnedArtifact"], 1)
            XCTAssertEqual(result["writerUsesSelectedDestination"], 1)
            XCTAssertEqual(result["buttonDisabledDuringWrite"], 1)
            XCTAssertEqual(result["buttonEnabledAfterWrite"], 1)
            XCTAssertEqual(result["failures"], 0)
            XCTAssertEqual(result["finished"], 1)
        }

        func testActiveWriterRejectsRepeatedSaveAndRestoresButton() async {
            let result = await facts(for: "writing")
            XCTAssertEqual(result["panels"], 1)
            XCTAssertEqual(result["writes"], 1)
            XCTAssertEqual(result["buttonDisabledDuringWrite"], 1)
            XCTAssertEqual(result["buttonEnabledAfterWrite"], 1)
        }

        func testFailedWriterShowsDiagnosticAndAllowsSuccessfulRetry() async {
            let result = await facts(for: "failure-retry")
            XCTAssertEqual(result["panels"], 2)
            XCTAssertEqual(result["writes"], 2)
            XCTAssertEqual(result["failures"], 1)
            XCTAssertEqual(result["failureUsesSenderWindow"], 1)
            XCTAssertEqual(result["failurePreservesDiagnostic"], 1)
            XCTAssertEqual(result["buttonEnabledAfterWrite"], 1)
            XCTAssertEqual(result["buttonEnabledAfterRetry"], 1)
            XCTAssertEqual(result["finished"], 2)
        }

        func testTemporaryInvisibilityRetainsOneExportErrorUntilRestoration() async {
            for scenario in ["hidden-restore", "minimized-restore", "application-hidden-restore", "sheet-minimized-restore"] {
                let result: [String: NSNumber] = await withCheckedContinuation { continuation in
                    PBPushOutputExportCoordinatorTestHarness.exportProof(scenario: scenario, restoration: { window in
                        do { try self.attachScreenshot(of: window, named: "Export-Error-Recovery-" + scenario) } catch { XCTFail("Export diagnostic screenshot unavailable: \(error)") }
                    }, completion: { continuation.resume(returning: $0) })
                }
                XCTAssertEqual(result["fixtureFailure"], 0, scenario)
                XCTAssertEqual(result["presentationsBeforeRestoration"], 1, scenario)
                XCTAssertEqual(result["presentationsAfterRestoration"], 0, scenario)
                XCTAssertEqual(result["failuresBeforeRestoration"], 0, scenario)
                XCTAssertEqual(result["failuresAfterRestoration"], 1, scenario)
                XCTAssertEqual(result["failures"], 1, scenario)
                XCTAssertEqual(result["failurePreservesDiagnostic"], 1, scenario)
                XCTAssertEqual(result["finished"], 1, scenario)
            }
        }

        func testPendingErrorIsDiscardedAfterActualClosureOrSheetDetachment() async {
            for scenario in ["hidden-close", "hidden-sheet-dismiss", "hidden-parent-close"] {
                let result = await facts(for: scenario)
                XCTAssertEqual(result["fixtureFailure"], 0, scenario)
                XCTAssertEqual(result["presentationsBeforeRestoration"], 1, scenario)
                XCTAssertEqual(result["presentationsAfterRestoration"], 0, scenario)
                XCTAssertEqual(result["failuresBeforeRestoration"], 0, scenario)
                XCTAssertEqual(result["failuresAfterRestoration"], 0, scenario)
                XCTAssertEqual(result["failures"], 0, scenario)
            }
        }

        func testDismissedSheetDoesNotReceiveLateExportFailure() async {
            for scenario in ["dismissed-sheet", "closed-window"] {
                let result = await facts(for: scenario)
                XCTAssertEqual(result["writes"], 1, scenario)
                XCTAssertEqual(result["finished"], 1, scenario)
                XCTAssertEqual(result["failures"], 0, scenario)
                XCTAssertEqual(result["dismissedWindowVisible"], 0, scenario)
            }
        }

        func testDefaultWriterSavesFullRedactedReport() async {
            let result = await facts(for: "real-success")
            XCTAssertEqual(result["reportContainsDiagnostic"], 1)
            XCTAssertEqual(result["reportRedacted"], 1)
            XCTAssertEqual(result["buttonEnabledAfterWrite"], 1)
            XCTAssertEqual(result["finished"], 1)
        }

        func testDefaultWriterFailureShowsNativeSheetAndRestoresButton() async {
            let result = await facts(for: "real-failure")
            XCTAssertEqual(result["failureSheetPresented"], 1)
            XCTAssertEqual(result["failureSheetExplainsError"], 1)
            XCTAssertEqual(result["buttonEnabledAfterWrite"], 1)
            XCTAssertEqual(result["finished"], 1)
        }

        func testMissingAndMalformedArtifactsDoNotOfferExport() {
            let values: [Any] = [NSNull(), 7, "not an artifact"]
            let missing = NSError(domain: "GitX.Export.Tests", code: 1)
            XCTAssertNil(PBPushOutputExportCoordinatorTestHarness.artifact(for: missing))
            XCTAssertNil(PBPushOutputExportCoordinatorTestHarness.button(for: missing))
            for value in values {
                let malformed = NSError(domain: "GitX.Export.Tests", code: 1,
                                        userInfo: ["PBTaskDiagnosticArtifact": value, NSUnderlyingErrorKey: value])
                XCTAssertNil(PBPushOutputExportCoordinatorTestHarness.artifact(for: malformed))
                XCTAssertNil(PBPushOutputExportCoordinatorTestHarness.button(for: malformed))
            }
        }

        func testOwnershipFindsNestedArtifactAndPrefersOutermostCapture() throws {
            let innerArtifact = makeArtifact("inner diagnostic")
            let outerArtifact = makeArtifact("outer diagnostic")
            defer { innerArtifact.discard(); outerArtifact.discard() }
            let inner = NSError(domain: PBTaskErrorDomain, code: 4, userInfo: ["PBTaskDiagnosticArtifact": innerArtifact])
            let middle = NSError(domain: "GitX.Export.Middle", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
            let outer = NSError(domain: "GitX.Export.Outer", code: 1,
                                userInfo: ["PBTaskDiagnosticArtifact": NSNull(), NSUnderlyingErrorKey: middle])
            XCTAssertTrue(PBPushOutputExportCoordinatorTestHarness.artifact(for: outer) === innerArtifact)
            let preferred = NSError(domain: "GitX.Export.Outer", code: 1,
                                    userInfo: ["PBTaskDiagnosticArtifact": outerArtifact, NSUnderlyingErrorKey: middle])
            XCTAssertTrue(PBPushOutputExportCoordinatorTestHarness.artifact(for: preferred) === outerArtifact)
            let button = try XCTUnwrap(PBPushOutputExportCoordinatorTestHarness.button(for: outer))
            XCTAssertEqual(button.title, "Save Push Output…")
            XCTAssertEqual(button.identifier?.rawValue, "GitX.Push.SaveOutput")
            XCTAssertNotNil(button.target)
            XCTAssertEqual(button.action, NSSelectorFromString("saveOutput:"))
        }

        func testInstallAddsOnlyEligibleExportButtonAndAcceptsMissingWindowContent() throws {
            let artifact = makeArtifact("diagnostic")
            defer { artifact.discard() }
            let captured = NSError(domain: PBTaskErrorDomain, code: 4, userInfo: ["PBTaskDiagnosticArtifact": artifact])
            let ordinary = NSError(domain: "GitX.Export.Tests", code: 1)
            PBPushOutputExportCoordinatorTestHarness.install(on: nil, error: captured)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            PBPushOutputExportCoordinatorTestHarness.install(on: window, error: ordinary)
            XCTAssertTrue(content.subviews.isEmpty)
            PBPushOutputExportCoordinatorTestHarness.install(on: window, error: captured)
            XCTAssertEqual(content.subviews.count, 1)
            let button = try XCTUnwrap(content.subviews.first as? NSButton)
            XCTAssertEqual(button.frame.origin, NSPoint(x: 98, y: 12))
            XCTAssertEqual(button.autoresizingMask, [.maxXMargin, .maxYMargin])
            window.contentView = nil
            PBPushOutputExportCoordinatorTestHarness.install(on: window, error: captured)
            XCTAssertNil(window.contentView)
        }

        func testCapturedNonZeroFailureUsesRedactedSummaryInsteadOfLegacyOutput() {
            let artifact = makeArtifact("first diagnostic\nhttps://user:secret@example.invalid/repo\nlast diagnostic")
            defer { artifact.discard() }
            let task = NSError(domain: PBTaskErrorDomain, code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Push failed", PBTaskTerminationStatusKey: 9,
                                          PBTaskTerminationOutputKey: "raw legacy secret output", "PBTaskDiagnosticArtifact": artifact])
            let outer = NSError(domain: "GitX.Export.Tests", code: 1, userInfo: [NSUnderlyingErrorKey: task])
            let info = PBErrorMessagePresentation.infoText(for: outer)
            XCTAssertTrue(info.contains("Return code: 9"))
            XCTAssertTrue(info.contains("first diagnostic"))
            XCTAssertTrue(info.contains("last diagnostic"))
            XCTAssertTrue(info.contains("https://[redacted]@example.invalid/repo"))
            XCTAssertFalse(info.contains("secret"))
            XCTAssertEqual(info.components(separatedBy: "Output:").count - 1, 1)
        }

        func testNonTaskWrappersFindCapturedSummaryWithoutTaskHeaders() {
            let artifact = makeArtifact("nested output")
            defer { artifact.discard() }
            let inner = NSError(domain: PBTaskErrorDomain, code: 2, userInfo: ["PBTaskDiagnosticArtifact": artifact])
            let middle = NSError(domain: "GitX.Export.Middle", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
            let outer = NSError(domain: "GitX.Export.Outer", code: 1,
                                userInfo: [NSLocalizedFailureReasonErrorKey: "Operation failed", NSUnderlyingErrorKey: middle])
            let info = PBErrorMessagePresentation.infoText(for: outer)
            XCTAssertTrue(info.hasPrefix("Operation failed"))
            XCTAssertTrue(info.contains("nested output"))
            XCTAssertFalse(info.contains("The underlying task failed:"))
        }

        func testNonTaskReadableFailureRetainsGitOutputAndCaptureFailureDetails() {
            let capture = PBTaskDiagnosticCaptureTestHarness.capture(fault: "createDirectory")
            let artifact = capture.seal()
            defer { artifact.discard() }
            let error = NSError(domain: "GitX.Export.Tests", code: 1,
                                userInfo: [NSLocalizedFailureReasonErrorKey: "Push failed",
                                           "PBTaskReadablePushOutput": "remote: permission denied",
                                           "PBTaskDiagnosticArtifact": artifact])
            let text = PBErrorMessagePresentation.infoText(for: error)
            XCTAssertTrue(text.contains("permission denied"))
            XCTAssertTrue(text.contains("could not be captured"))
            XCTAssertFalse(text.contains("The underlying task failed:"))
        }

        func testMalformedArtifactFallsBackToLegacyTaskOutputWithoutCoercion() {
            for value: Any in [NSNull(), NSNumber(value: 7), "not an artifact"] {
                let task = NSError(domain: PBTaskErrorDomain, code: 4,
                                   userInfo: [NSLocalizedDescriptionKey: "Push failed", "PBTaskDiagnosticArtifact": value,
                                              PBTaskTerminationOutputKey: "legacy diagnostic"])
                let outer = NSError(domain: "GitX.Export.Tests", code: 1,
                                    userInfo: [NSLocalizedFailureReasonErrorKey: NSNull(), NSLocalizedRecoverySuggestionErrorKey: 7,
                                               NSUnderlyingErrorKey: task])
                let info = PBErrorMessagePresentation.infoText(for: outer)
                XCTAssertTrue(info.contains("Return code: ?"))
                XCTAssertTrue(info.contains("Output:\nlegacy diagnostic"))
                XCTAssertFalse(info.contains("Maybe you could try the following:"))
            }
        }

        func testDefaultSavePanelUsesItsOwnerAndCancellationAllowsAnotherRequest() async throws {
            let artifact = makeArtifact("save panel ownership")
            defer { artifact.discard() }
            let error = NSError(domain: PBTaskErrorDomain, code: 4, userInfo: ["PBTaskDiagnosticArtifact": artifact])
            let button = try XCTUnwrap(PBPushOutputExportCoordinatorTestHarness.button(for: error))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(button)
            window.makeKeyAndOrderFront(nil)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                window.close()
            }
            for attempt in 0 ..< 2 {
                button.performClick(nil)
                let presented = await waitForPresentation { window.attachedSheet != nil }
                XCTAssertTrue(presented)
                let sheet = try XCTUnwrap(window.attachedSheet)
                XCTAssertTrue(sheet.sheetParent === window)
                if let panel = sheet as? NSSavePanel {
                    XCTAssertEqual(panel.nameFieldStringValue, "GitX-Push-Output.txt")
                    XCTAssertTrue(panel.canCreateDirectories)
                    if attempt == 0 {
                        try attachScreenshot(of: panel, named: "Export-Native-Save-Panel-Owner")
                    }
                    panel.cancel(nil)
                } else {
                    if attempt == 0 {
                        try attachScreenshot(of: sheet, named: "Export-Native-Save-Panel-Owner")
                    }
                    window.endSheet(sheet, returnCode: .cancel)
                    sheet.orderOut(nil)
                }
                let dismissed = await waitForPresentation { window.attachedSheet == nil }
                XCTAssertTrue(dismissed)
                XCTAssertTrue(button.isEnabled)
            }
        }

        private func waitForPresentation(_ state: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !state(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return state()
        }

        private func facts(for scenario: String) async -> [String: NSNumber] {
            let result = await withCheckedContinuation { continuation in
                PBPushOutputExportCoordinatorTestHarness.exportProof(scenario: scenario) { facts in
                    continuation.resume(returning: facts)
                }
            }
            XCTAssertEqual(result["fixtureFailure"], 0, scenario)
            return result
        }

        private func makeArtifact(_ diagnostic: String) -> PBTaskDiagnosticArtifact {
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardError(Data(diagnostic.utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: true)
            return capture.seal()
        }
    #endif
}
