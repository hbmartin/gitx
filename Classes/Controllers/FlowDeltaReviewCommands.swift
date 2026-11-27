import AppKit
import FlowDeltaCore
import FlowDeltaExport
import FlowDeltaUI
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger and privacy interpolation require OSLog.
import UniformTypeIdentifiers

/// View ▸ Flow Review: presentation, slice, noise, grouping, walkthrough, copy and export commands for the Flow tab.
///
/// Every menu item sends `performHistoryFlowCommand:` with its `HistoryFlowCommand` tag. The History controller
/// routes the action here while another History control is focused, and `HistoryFlowCommandPolicy` decides
/// which items are enabled and checked.
extension FlowDeltaAdapterView: NSMenuItemValidation {
    private static let commandLogger = Logger(subsystem: "com.gitx.gitx", category: "FlowDelta")

    /// Chooses where to export a report. Tests replace it to skip the save panel.
    static var chooseExportDestination: @MainActor (NSSavePanel, NSWindow, @escaping @MainActor (URL?) -> Void)
        -> Void = { panel, window, completion in
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        }

    /// What the Flow tab shows, as far as the Flow Review menu cares.
    var commandContext: HistoryFlowCommandContext {
        guard let report = displayedReport, window != nil, !isHiddenOrHasHiddenAncestor else { return .unavailable }
        let state = reviewView.state
        return HistoryFlowCommandContext(
            hasReport: true,
            hasFunction: state.selectedFunctionName != nil,
            hasSelectedNode: state.selectedNodeStableID != nil,
            presentation: Self.presentation(state.presentation),
            slice: state.slice.map(Self.slice),
            noise: HistoryFlowNoiseLevel(rawValue: state.noise.rawValue) ?? .showAll,
            groupsByConcern: state.groupsByConcern,
            canStartWalkthrough: !report.functionDeltas.isEmpty,
            walkthroughStep: state.walkthroughStep,
            walkthroughStepCount: reviewView.activeWalkthroughSteps.count
        )
    }

    @objc func performHistoryFlowCommand(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag
        guard let tag, let command = HistoryFlowCommand(tag: tag) else {
            Self.commandLogger.error("Ignored a Flow Review command without a known tag")
            return
        }
        perform(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Actions the view inherits, such as print:, keep AppKit's default of enabled.
        guard menuItem.action == #selector(performHistoryFlowCommand(_:)) else { return true }
        guard let command = HistoryFlowCommand(tag: menuItem.tag) else { return false }
        let state = HistoryFlowCommandPolicy.state(for: command, in: commandContext)
        menuItem.state = state.isChecked ? .on : .off
        return state.isEnabled
    }

    /// Runs `command` when the policy allows it. Review changes made here are the user's, so they are remembered.
    func perform(_ command: HistoryFlowCommand) {
        let context = commandContext
        guard HistoryFlowCommandPolicy.state(for: command, in: context).isEnabled else {
            Self.commandLogger.notice("Flow Review command \(String(describing: command), privacy: .public) is unavailable")
            return
        }
        Self.commandLogger.info("Performing Flow Review command \(String(describing: command), privacy: .public)")
        switch command {
        case let .presentation(presentation):
            reviewView.setPresentation(Self.flowPresentation(presentation))
            rememberReviewPreferences()
        case let .slice(direction):
            // Choosing the checked slice again hides it, like any checked menu item.
            reviewView.setSlice(context.slice == direction ? nil : Self.flowSlice(direction))
            rememberReviewPreferences()
        case let .noise(level):
            reviewView.setNoise(FlowNoisePolicy(rawValue: level.rawValue) ?? .showAll)
            rememberReviewPreferences()
        case .toggleGroupByConcern:
            reviewView.setGroupsByConcern(!context.groupsByConcern)
            rememberReviewPreferences()
        case .startWalkthrough:
            reviewView.startWalkthrough()
        case .nextWalkthroughStep:
            reviewView.showNextWalkthroughStep()
        case .previousWalkthroughStep:
            reviewView.showPreviousWalkthroughStep()
        case let .copyReport(format):
            copyReport(as: format)
        case .exportReport:
            exportReport()
        }
    }

    // MARK: Copy and export

    /// The report renders as the review shows it: with its noise level and concern grouping.
    private var exportOptions: FlowDeltaExportOptions {
        let state = reviewView.state
        return FlowDeltaExportOptions(noise: state.noise, groupByConcern: state.groupsByConcern)
    }

    private func copyReport(as format: HistoryFlowExportFormat) {
        guard let report = displayedReport else { return }
        let options = exportOptions
        let pasteboard = reportPasteboard
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            do {
                let text = try await Self.render(report, format: Self.flowFormat(format), options: options)
                try Task.checkCancellation()
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                Self.commandLogger.notice(
                    "Copied the Flow report as \(format.rawValue, privacy: .public), \(text.utf8.count) bytes"
                )
                self?.announce("Copied the Flow report as \(format.displayName).")
            } catch is CancellationError {
                Self.commandLogger.debug("Cancelled a superseded Flow report copy")
            } catch {
                self?.reportExportFailure(error)
            }
        }
    }

    private func exportReport() {
        guard let report = displayedReport, let window else { return }
        let preferences = ApplicationSettings.historyFlowReviewPreferences
        let panel = NSSavePanel()
        panel.title = "Export Flow Report"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formats = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.addItems(withTitles: HistoryFlowExportFormat.allCases.map(\.displayName))
        formats.setAccessibilityIdentifier("History.Flow.ExportFormat")
        formats.setAccessibilityLabel("Format")
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, formats])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory

        let chooser = ExportFormatChooser(panel: panel, report: report)
        chooser.select(preferences.exportFormat)
        formats.selectItem(at: HistoryFlowExportFormat.allCases.firstIndex(of: preferences.exportFormat) ?? 0)
        formats.target = chooser
        formats.action = #selector(ExportFormatChooser.formatChanged(_:))

        let options = exportOptions
        Self.commandLogger.notice("Presenting the Flow report export panel")
        Self.chooseExportDestination(panel, window) { [weak self] url in
            guard let url else {
                Self.commandLogger.info("Cancelled the Flow report export")
                return
            }
            let format = chooser.format
            var preferences = ApplicationSettings.historyFlowReviewPreferences
            preferences.exportFormat = format
            ApplicationSettings.historyFlowReviewPreferences = preferences
            self?.exportTask?.cancel()
            self?.exportTask = Task { [weak self] in
                do {
                    try await Self.write(report, format: Self.flowFormat(format), options: options, to: url)
                    Self.commandLogger.notice("Exported the Flow report as \(format.rawValue, privacy: .public)")
                    self?.announce("Exported the Flow report.")
                } catch is CancellationError {
                    Self.commandLogger.debug("Cancelled a superseded Flow report export")
                } catch {
                    self?.reportExportFailure(error)
                }
            }
        }
    }

    /// Tells VoiceOver that a copy or export finished, since neither moves focus.
    private func announce(_ message: String) {
        Self.commandLogger.info("Flow announcement: \(message, privacy: .public)")
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func reportExportFailure(_ error: any Error) {
        Self.commandLogger.error("Flow report copy or export failed: \(String(describing: error), privacy: .private)")
        guard let window else { return }
        presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }

    @concurrent
    private nonisolated static func render(
        _ report: RevisionFlowDeltaReport,
        format: FlowDeltaExportFormat,
        options: FlowDeltaExportOptions
    ) async throws -> String {
        try FlowDeltaReportExporter().render(report, format: format, options: options)
    }

    @concurrent
    private nonisolated static func write(
        _ report: RevisionFlowDeltaReport,
        format: FlowDeltaExportFormat,
        options: FlowDeltaExportOptions,
        to url: URL
    ) async throws {
        let text = try FlowDeltaReportExporter().render(report, format: format, options: options)
        try Task.checkCancellation()
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Mapping between GitX and FlowDelta

    static func presentation(_ presentation: FlowReviewPresentation) -> HistoryFlowPresentation {
        switch presentation {
        case .delta: .delta
        case .beforeAfter: .beforeAfter
        case .calls: .calls
        }
    }

    static func flowPresentation(_ presentation: HistoryFlowPresentation) -> FlowReviewPresentation {
        switch presentation {
        case .delta: .delta
        case .beforeAfter: .beforeAfter
        case .calls: .calls
        }
    }

    static func slice(_ direction: FlowSliceDirection) -> HistoryFlowSliceDirection {
        switch direction {
        case .forward: .forward
        case .backward: .backward
        }
    }

    static func flowSlice(_ direction: HistoryFlowSliceDirection) -> FlowSliceDirection {
        switch direction {
        case .forward: .forward
        case .backward: .backward
        }
    }

    private static func flowFormat(_ format: HistoryFlowExportFormat) -> FlowDeltaExportFormat {
        switch format {
        case .markdown: .markdown
        case .json: .json
        case .mermaid: .mermaid
        }
    }
}

/// Keeps the export panel's file name and type in step with its Format pop-up.
@MainActor
private final class ExportFormatChooser: NSObject {
    private let panel: NSSavePanel
    private let report: RevisionFlowDeltaReport
    private(set) var format: HistoryFlowExportFormat = .markdown

    init(panel: NSSavePanel, report: RevisionFlowDeltaReport) {
        self.panel = panel
        self.report = report
    }

    func select(_ format: HistoryFlowExportFormat) {
        self.format = format
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = HistoryFlowExportPolicy.fileName(
            base: report.base.value,
            target: report.target.value,
            format: format
        )
    }

    @objc func formatChanged(_ sender: NSPopUpButton) {
        guard HistoryFlowExportFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        select(HistoryFlowExportFormat.allCases[sender.indexOfSelectedItem])
    }
}
