import AppKit
import os

/// Opaque capture ownership crosses only error presentation and active exports.
nonisolated enum PushDiagnosticOwnership {
    static let errorKey = "PBTaskDiagnosticArtifact"

    static func artifact(for error: NSError) -> PBTaskDiagnosticArtifact? {
        var current: NSError? = error
        var seen = Set<ObjectIdentifier>()
        while let candidate = current, seen.insert(ObjectIdentifier(candidate)).inserted {
            if let artifact = candidate.userInfo[errorKey] as? PBTaskDiagnosticArtifact {
                return artifact
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

#if DEBUG
    /// App-hosted XCTest exercises the shipped coordinator without importing duplicate app interfaces.
    // The test target reaches this facade through its Objective-C declarations.
    // swiftlint:disable unused_declaration
    @objc(PBPushOutputExportCoordinatorTestHarness)
    @MainActor
    final class PushOutputExportCoordinatorTestHarness: NSObject {
        @objc(artifactForError:)
        static func artifact(for error: NSError) -> PBTaskDiagnosticArtifact? {
            PushDiagnosticOwnership.artifact(for: error)
        }

        @objc(buttonForError:)
        static func button(for error: NSError) -> NSButton? {
            PushOutputExportCoordinator.button(for: error)
        }

        @objc(installOnWindow:error:)
        static func install(on window: NSWindow?, error: NSError) {
            PushOutputExportCoordinator.install(on: window, error: error)
        }

        @objc(exportProofForScenario:completion:)
        static func exportProof(scenario: String, completion: @escaping ([String: NSNumber]) -> Void) {
            Task { @MainActor in completion(await exportProof(scenario: scenario)) }
        }

        private static func exportProof(scenario: String) async -> [String: NSNumber] {
            let capture = PBTaskDiagnosticCapture()
            capture.appendStandardError(Data("saved diagnostic https://user:secret@example.invalid/repo\n".utf8))
            capture.finishStandardOutput(reachedEOF: true)
            capture.finishStandardError(reachedEOF: true)
            let artifact = capture.seal()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Export-Proof-" + UUID().uuidString, isDirectory: true)
            let destination = directory.appendingPathComponent("push.txt")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let button = NSButton()
            let state = PushOutputExportProofState(artifact: artifact, destination: destination, window: window)
            let coordinator: PushOutputExportCoordinator
            if scenario == "real-success" || scenario == "real-failure" {
                coordinator = PushOutputExportCoordinator(artifact: artifact, destinationPresenter: state.presentDestination)
            } else {
                coordinator = PushOutputExportCoordinator(
                    artifact: artifact, destinationPresenter: state.presentDestination,
                    reportWriter: state.writeReport, failurePresenter: state.presentFailure
                )
            }
            coordinator.exportDidFinishForTesting = state.didFinish
            defer {
                state.responses.removeAll()
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                window.close()
                try? FileManager.default.removeItem(at: directory)
                artifact.discard()
            }
            if scenario != "windowless" {
                window.contentView?.addSubview(button)
            }
            coordinator.saveOutput(button)
            switch scenario {
            case "pending":
                coordinator.saveOutput(button)
                state.facts["buttonEnabledWhilePending"] = button.isEnabled ? 1 : 0
                for response in state.responses {
                    response(.cancel, nil)
                }
            case "late-cancel":
                let previousResponse = state.responses[0]
                previousResponse(.cancel, nil)
                coordinator.saveOutput(button)
                previousResponse(.cancel, nil)
                coordinator.saveOutput(button)
                for response in state.responses.dropFirst() {
                    response(.cancel, nil)
                }
            case "cancel", "missing-destination":
                state.responses[0](scenario == "cancel" ? .cancel : .OK, nil)
                state.facts["buttonEnabledAfterCancellation"] = button.isEnabled ? 1 : 0
                coordinator.saveOutput(button)
                state.responses[1](.cancel, nil)
            case "windowless":
                break
            case "success", "writing", "failure-retry":
                state.responses[0](.OK, destination)
                await state.waitForWriter(count: 1)
                state.facts["buttonDisabledDuringWrite"] = button.isEnabled ? 0 : 1
                if scenario == "writing" {
                    coordinator.saveOutput(button)
                }
                let failure = scenario == "failure-retry" ? NSError(domain: "GitX.Export.Proof", code: 7, userInfo: [NSLocalizedDescriptionKey: "Controlled export failure"]) : nil
                await state.finishWrite(with: failure)
                state.facts["buttonEnabledAfterWrite"] = button.isEnabled ? 1 : 0
                if scenario == "failure-retry" {
                    coordinator.saveOutput(button)
                    state.responses[1](.OK, destination)
                    await state.waitForWriter(count: 2)
                    await state.finishWrite(with: nil)
                    state.facts["buttonEnabledAfterRetry"] = button.isEnabled ? 1 : 0
                }
            case "real-success", "real-failure":
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    window.makeKeyAndOrderFront(nil)
                    await state.waitForRealExport {
                        state.responses[0](.OK, scenario == "real-success" ? destination : URL(string: "https://example.invalid/output")!)
                    }
                    state.facts["buttonEnabledAfterWrite"] = button.isEnabled ? 1 : 0
                    if scenario == "real-success" {
                        let report = try String(contentsOf: destination, encoding: .utf8)
                        state.facts["reportContainsDiagnostic"] = report.contains("saved diagnostic") ? 1 : 0
                        state.facts["reportRedacted"] = !report.contains("secret") && report.contains("[redacted]") ? 1 : 0
                    } else {
                        state.facts["failureSheetPresented"] = window.attachedSheet == nil ? 0 : 1
                        let text = window.attachedSheet?.contentView.map(textInView) ?? ""
                        state.facts["failureSheetExplainsError"] = text.contains("Could Not Save Push Output") ? 1 : 0
                    }
                } catch {
                    state.facts["fixtureFailure"] = 1
                }
            default:
                state.facts["fixtureFailure"] = 1
            }
            return state.facts.mapValues(NSNumber.init(value:))
        }

        private static func textInView(_ view: NSView) -> String {
            ((view as? NSTextField)?.stringValue ?? "") + view.subviews.map(textInView).joined(separator: "\n")
        }
    }

    // swiftlint:enable unused_declaration

    @MainActor
    private final class PushOutputExportProofState {
        var responses: [PushOutputExportCoordinator.DestinationResponse] = []
        var facts = ["panels": 0, "writes": 0, "failures": 0, "finished": 0, "fixtureFailure": 0]
        private let artifact: PBTaskDiagnosticArtifact
        private let destination: URL
        private let window: NSWindow
        private var writeCompletion: CheckedContinuation<NSError?, Never>?
        private var writerStarted: CheckedContinuation<Void, Never>?
        private var exportFinished: CheckedContinuation<Void, Never>?

        init(artifact: PBTaskDiagnosticArtifact, destination: URL, window: NSWindow) {
            self.artifact = artifact
            self.destination = destination
            self.window = window
        }

        func presentDestination(for window: NSWindow, response: @escaping PushOutputExportCoordinator.DestinationResponse) {
            facts["panels", default: 0] += 1
            facts["panelUsesSenderWindow"] = window === self.window ? 1 : 0
            responses.append(response)
        }

        func writeReport(_ artifact: PBTaskDiagnosticArtifact, to destination: URL) async -> NSError? {
            facts["writes", default: 0] += 1
            facts["writerUsesOwnedArtifact"] = artifact === self.artifact ? 1 : 0
            facts["writerUsesSelectedDestination"] = destination == self.destination ? 1 : 0
            return await withCheckedContinuation { completion in
                writeCompletion = completion
                writerStarted?.resume()
                writerStarted = nil
            }
        }

        func presentFailure(_ error: NSError, for window: NSWindow) {
            facts["failures", default: 0] += 1
            facts["failureUsesSenderWindow"] = window === self.window ? 1 : 0
            facts["failurePreservesDiagnostic"] = error.domain == "GitX.Export.Proof" && error.code == 7 ? 1 : 0
        }

        func waitForWriter(count: Int) async {
            guard facts["writes", default: 0] < count else { return }
            await withCheckedContinuation { writerStarted = $0 }
        }

        func finishWrite(with error: NSError?) async {
            await withCheckedContinuation { completion in
                exportFinished = completion
                writeCompletion?.resume(returning: error)
                writeCompletion = nil
            }
        }

        func waitForRealExport(start: () -> Void) async {
            await withCheckedContinuation { completion in
                exportFinished = completion
                start()
            }
        }

        func didFinish() {
            facts["finished", default: 0] += 1
            exportFinished?.resume()
            exportFinished = nil
        }
    }
#endif

/// A button retains its coordinator while the containing sheet is presented.
@MainActor
private final class PushOutputExportButton: NSButton {
    let coordinator: PushOutputExportCoordinator

    init(coordinator: PushOutputExportCoordinator) {
        self.coordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 32))
        title = "Save Push Output…"
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = coordinator
        action = #selector(PushOutputExportCoordinator.saveOutput(_:))
        identifier = NSUserInterfaceItemIdentifier("GitX.Push.SaveOutput")
        setAccessibilityIdentifier("GitX.Push.SaveOutput")
        setAccessibilityHelp("Save the full redacted push output to a text file.")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Created by the push presenter")
    }
}

/// The existing Cocoa sheets retain their confirmation and responder behavior.
@objc(PBPushOutputExportCoordinator)
@MainActor
final class PushOutputExportCoordinator: NSObject {
    typealias DestinationResponse = @MainActor (NSApplication.ModalResponse, URL?) -> Void
    typealias DestinationPresenter = @MainActor (NSWindow, @escaping DestinationResponse) -> Void
    typealias ReportWriter = @MainActor (PBTaskDiagnosticArtifact, URL) async -> NSError?
    typealias FailurePresenter = @MainActor (NSError, NSWindow) -> Void

    private let artifact: PBTaskDiagnosticArtifact
    private let destinationPresenter: DestinationPresenter
    private let reportWriter: ReportWriter
    private let failurePresenter: FailurePresenter
    private let logger = os.Logger(subsystem: "com.gitx.gitx", category: "PushOutputExport")
    private var isExporting = false

    #if DEBUG
        var exportDidFinishForTesting: (() -> Void)?
    #endif

    init(
        artifact: PBTaskDiagnosticArtifact,
        destinationPresenter: @escaping DestinationPresenter = PushOutputExportCoordinator.presentDestination,
        reportWriter: @escaping ReportWriter = PushOutputExportCoordinator.writeReport,
        failurePresenter: @escaping FailurePresenter = PushOutputExportCoordinator.presentFailure
    ) {
        self.artifact = artifact
        self.destinationPresenter = destinationPresenter
        self.reportWriter = reportWriter
        self.failurePresenter = failurePresenter
        super.init()
    }

    @objc(buttonForError:)
    static func button(for error: NSError) -> NSButton? {
        guard let artifact = PushDiagnosticOwnership.artifact(for: error) else { return nil }
        return PushOutputExportButton(coordinator: PushOutputExportCoordinator(artifact: artifact))
    }

    @objc(installOnWindow:error:)
    static func install(on window: NSWindow?, error: NSError) {
        guard let content = window?.contentView, let button = button(for: error) else { return }
        button.frame.origin = NSPoint(x: 98, y: 12)
        button.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(button)
    }

    @objc func saveOutput(_ sender: NSButton) {
        guard !isExporting, let window = sender.window else { return }
        isExporting = true
        var responseHandled = false
        destinationPresenter(window) { [self] response, destination in
            guard !responseHandled else { return }
            responseHandled = true
            guard response == .OK, let destination else {
                isExporting = false
                return
            }
            sender.isEnabled = false
            Task { @MainActor [self] in
                let failure = await reportWriter(artifact, destination)
                isExporting = false
                sender.isEnabled = true
                if let failure {
                    logger.error("Redacted push output export failed")
                    failurePresenter(failure, window)
                } else {
                    logger.info("Redacted push output export completed")
                }
                #if DEBUG
                    exportDidFinishForTesting?()
                #endif
            }
        }
    }

    private static func presentDestination(for window: NSWindow, response: @escaping DestinationResponse) {
        let panel = NSSavePanel()
        panel.title = "Save Push Output"
        panel.nameFieldStringValue = "GitX-Push-Output.txt"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { result in response(result, panel.url) }
    }

    private static func writeReport(_ artifact: PBTaskDiagnosticArtifact, to destination: URL) async -> NSError? {
        await Task.detached(priority: .utility) { () -> NSError? in
            do { try artifact.writeRedactedReport(to: destination); return nil }
            catch { return error as NSError }
        }.value
    }

    private static func presentFailure(_ error: NSError, for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save Push Output"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
