import AppKit
import FlowDeltaAnalysis
import FlowDeltaCore
import FlowDeltaGit
import FlowDeltaUI
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger and privacy interpolation require OSLog.

@MainActor
@objc(PBFlowDeltaAdapterView)
final class FlowDeltaAdapterView: NSView, FlowDeltaReviewViewDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "FlowDelta")
    /// Selection changes made while scrolling the commit list are coalesced so
    /// a held arrow key does not start one git chain per row.
    static let selectionDebounce: Duration = .milliseconds(150)
    static let noAnalyzableFilesMessage = "This commit changes no files Flow can analyze.\nSupported languages: "
        + SourceLanguage.allCases.map(\.displayName).joined(separator: ", ") + "."

    @IBOutlet private weak var historyController: PBGitHistoryController?

    private let contentStack = NSStackView()
    /// The embedded review. Flow Review menu commands drive it (see FlowDeltaReviewCommands.swift).
    let reviewView = FlowDeltaReviewView()
    /// The report the review shows, or nil while a message, the progress overlay or nothing is shown.
    private(set) var displayedReport: RevisionFlowDeltaReport?
    /// Where Copy Flow Report As puts its text. Tests use a private pasteboard.
    var reportPasteboard = NSPasteboard.general
    /// The copy or export rendering in flight, so a newer one supersedes it.
    var exportTask: Task<Void, Never>?
    private let diagnosticsBanner = NSStackView()
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusOverlay = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "Select a commit to review its flow delta.")
    private let progressIndicator = NSProgressIndicator()
    private var selectionObservation: NSKeyValueObservation?
    private var tabObservation: NSKeyValueObservation?
    private var analysisTask: Task<Void, Never>?
    /// The request whose outcome the view currently shows or is loading.
    /// Cleared whenever the view stops representing it, so the next matching
    /// decision loads again instead of being deduplicated.
    private var representedRequest: HistoryFlowRevisionRequest?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override nonisolated func awakeFromNib() {
        super.awakeFromNib()
        // swift6-safety-justification: AppKit awakens this main-actor view on the main thread.
        MainActor.assumeIsolated {
            startObservingHistory()
        }
    }

    deinit {
        analysisTask?.cancel()
        exportTask?.cancel()
    }

    override func layout() {
        super.layout()
        diagnosticsLabel.preferredMaxLayoutWidth = max(0, bounds.width - 48)
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("History.Flow.View")
        setAccessibilityLabel("Commit flow delta")

        let warningImage = NSImageView()
        warningImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        warningImage.contentTintColor = .systemOrange
        warningImage.setContentHuggingPriority(.required, for: .horizontal)
        diagnosticsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnosticsLabel.textColor = .secondaryLabelColor
        // The summary can contain a headline, three details, and an overflow
        // line. Let the stack view size to the complete bounded summary rather
        // than clipping the final line that explains omitted diagnostics.
        diagnosticsLabel.maximumNumberOfLines = 0
        diagnosticsLabel.setAccessibilityIdentifier("History.Flow.Diagnostics")
        diagnosticsBanner.orientation = .horizontal
        diagnosticsBanner.alignment = .top
        diagnosticsBanner.spacing = 6
        diagnosticsBanner.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        diagnosticsBanner.addArrangedSubview(warningImage)
        diagnosticsBanner.addArrangedSubview(diagnosticsLabel)
        diagnosticsBanner.isHidden = true

        reviewView.translatesAutoresizingMaskIntoConstraints = false
        reviewView.setAccessibilityIdentifier("History.Flow.Review")
        reviewView.delegate = self
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 0
        contentStack.addArrangedSubview(diagnosticsBanner)
        contentStack.addArrangedSubview(reviewView)
        addSubview(contentStack)

        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.material = .contentBackground
        statusOverlay.blendingMode = .withinWindow
        addSubview(statusOverlay)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        statusOverlay.addSubview(progressIndicator)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        statusOverlay.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusOverlay.topAnchor.constraint(equalTo: topAnchor),
            statusOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressIndicator.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusOverlay.centerYAnchor, constant: 18),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func startObservingHistory() {
        guard let historyController else {
            showMessage("The History controller is unavailable.")
            return
        }
        selectionObservation = historyController.observe(\.selectedCommits, options: [.initial, .new]) {
            [weak self] _, _ in
            // swift6-safety-justification: History selection mutations and this observation are main-actor confined.
            MainActor.assumeIsolated { self?.refreshFromHistory() }
        }
        tabObservation = historyController.observe(\.selectedCommitDetailsIndex, options: [.initial, .new]) {
            [weak self] _, _ in
            // swift6-safety-justification: History tab mutations and this observation are main-actor confined.
            MainActor.assumeIsolated { self?.refreshFromHistory() }
        }
        Self.logger.notice("Flow adapter began observing History selection")
    }

    private func refreshFromHistory() {
        guard let historyController else { return }
        let selectedTabIndex = historyController.selectedCommitDetailsIndex
        guard HistoryDetailMode(rawValue: selectedTabIndex) == .flow else {
            apply(.inactive)
            return
        }
        let commits = historyController.selectedCommits.map { commit in
            HistoryFlowCommitInput(
                sha: commit.sha,
                firstParentSHA: commit.parents.first?.sha,
                isWorkingState: commit is PBUncommittedChanges
            )
        }
        let decision = HistoryFlowSelectionPolicy().decision(
            repositoryURL: historyController.repository?.workingDirectoryURL(),
            commits: commits
        )
        apply(decision)
    }

    private func apply(_ decision: HistoryFlowSelectionDecision) {
        switch decision {
        case .inactive:
            cancelAnalysis()
            representedRequest = nil
        case let .message(message):
            cancelAnalysis()
            representedRequest = nil
            showMessage(message)
        case let .load(request):
            guard representedRequest != request else { return }
            representedRequest = request
            load(request)
        }
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
    }

    private func load(_ request: HistoryFlowRevisionRequest) {
        cancelAnalysis()
        // Flow runs the git GitX was configured with; without one the app has
        // already reported the problem at launch, so FlowDelta's default stands in.
        let gitExecutableURL = URL(fileURLWithPath: PBGitBinary.path() ?? "/usr/bin/git")
        showOverlay("Analyzing \(String(request.target.prefix(8)))…", loading: true)
        Self.logger.notice(
            "Loading flow delta \(request.base, privacy: .public) → \(request.target, privacy: .public)"
        )
        // Every path that stops showing this request cancels the task first, so
        // a stale task can only ever reach the cancellation branch below.
        analysisTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.selectionDebounce)
                let report = try await Self.analyze(request, gitExecutableURL: gitExecutableURL)
                try Task.checkCancellation()
                self?.display(report)
            } catch is CancellationError {
                Self.logger.debug("Cancelled stale History flow analysis")
            } catch {
                guard !Task.isCancelled, let self else { return }
                Self.logger.error("History flow analysis failed: \(String(describing: error), privacy: .private)")
                // Forget the request so the same commit can be retried once the
                // cause is fixed instead of being deduplicated forever.
                self.representedRequest = nil
                self.showMessage("Flow analysis failed.\n\(String(describing: error))")
            }
        }
    }

    @concurrent
    private nonisolated static func analyze(
        _ request: HistoryFlowRevisionRequest,
        gitExecutableURL: URL
    ) async throws -> RevisionFlowDeltaReport {
        let comparison = try await HistoryFlowRevisionProvider(gitExecutableURL: gitExecutableURL).comparison(
            repositoryURL: request.repositoryURL,
            base: request.base,
            target: request.target
        )
        try Task.checkCancellation()
        return try FlowDeltaAnalyzer().analyze(comparison)
    }

    /// Shows `report` with the saved Flow review preferences. Tests display reports directly.
    func display(_ report: RevisionFlowDeltaReport) {
        guard !report.files.isEmpty else {
            Self.logger.notice("History flow delta has no analyzable files")
            showMessage(Self.noAnalyzableFilesMessage)
            return
        }
        let preferences = ApplicationSettings.historyFlowReviewPreferences
        applyPreferences(preferences)
        reviewView.display(report)
        // Showing a function turns Slice off, so the saved slice applies after the report is on screen.
        applySavedSlice(preferences)
        displayedReport = report
        showDiagnostics(Self.diagnosticsSummary(for: report))
        reviewView.isHidden = false
        statusOverlay.isHidden = true
        progressIndicator.stopAnimation(nil)
        Self.logger.notice("Displayed History flow delta with \(report.functionDeltas.count) functions")
    }

    private static func diagnosticsSummary(for report: RevisionFlowDeltaReport) -> HistoryFlowDiagnosticsSummary? {
        let inputs = report.files.flatMap(\.diagnostics).map { diagnostic in
            let severity: HistoryFlowDiagnosticInput.Severity = switch diagnostic.severity {
            case .information: .information
            case .warning: .warning
            case .error: .error
            }
            let code: HistoryFlowDiagnosticInput.Code = switch diagnostic.code {
            case .partialParse: .partialParse
            case .resourceLimit: .resourceLimit
            case .unsupportedConstruct: .unsupportedConstruct
            case .internalInvariant: .internalInvariant
            }
            return HistoryFlowDiagnosticInput(
                severity: severity,
                path: diagnostic.path,
                message: diagnostic.message,
                code: code
            )
        }
        return HistoryFlowDiagnosticsSummary.make(from: inputs)
    }

    private func showDiagnostics(_ summary: HistoryFlowDiagnosticsSummary?) {
        guard let summary else {
            diagnosticsBanner.isHidden = true
            diagnosticsLabel.stringValue = ""
            diagnosticsLabel.toolTip = nil
            return
        }
        var lines = [summary.headline] + summary.details
        if summary.omittedCount > 0 {
            lines.append("… and \(summary.omittedCount) more.")
        }
        lines += summary.notes
        let text = lines.joined(separator: "\n")
        diagnosticsLabel.stringValue = text
        diagnosticsLabel.toolTip = text
        diagnosticsLabel.setAccessibilityLabel(text)
        diagnosticsBanner.isHidden = false
        Self.logger.notice("History flow delta finished with diagnostics: \(summary.headline, privacy: .public)")
    }

    private func showMessage(_ message: String) {
        showOverlay(message, loading: false)
    }

    private func showOverlay(_ message: String, loading: Bool) {
        displayedReport = nil
        reviewView.isHidden = true
        diagnosticsBanner.isHidden = true
        statusOverlay.isHidden = false
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        if loading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    // MARK: Review preferences

    /// Applies the saved noise, grouping and presentation as host changes, so applying them never saves them again.
    func applyPreferences(_ preferences: HistoryFlowReviewPreferences) {
        let current = reviewView.state
        let noise = FlowNoisePolicy(rawValue: preferences.noise.rawValue) ?? .showAll
        if current.noise != noise {
            reviewView.setNoise(noise)
        }
        if current.groupsByConcern != preferences.groupsByConcern {
            reviewView.setGroupsByConcern(preferences.groupsByConcern)
        }
        let presentation = Self.flowPresentation(preferences.presentation)
        if current.presentation != presentation {
            reviewView.setPresentation(presentation)
        }
    }

    /// Turns on the saved slice, which FlowDelta draws from the next node the user selects in the delta graph.
    func applySavedSlice(_ preferences: HistoryFlowReviewPreferences) {
        guard let slice = preferences.slice.map(Self.flowSlice), reviewView.state.presentation == .delta else { return }
        reviewView.setSlice(slice)
        Self.logger.debug("Applied the saved \(preferences.slice?.rawValue ?? "none", privacy: .public) slice")
    }

    func flowDeltaReviewView(_: FlowDeltaReviewView, didChange _: FlowReviewState, cause: FlowReviewChangeCause) {
        guard cause == .user else { return }
        rememberReviewPreferences()
    }

    /// Saves the review's presentation, slice, noise and grouping as the app-wide Flow review preferences.
    func rememberReviewPreferences() {
        let state = reviewView.state
        var preferences = ApplicationSettings.historyFlowReviewPreferences
        preferences.presentation = Self.presentation(state.presentation)
        // FlowDelta draws a slice only from a node selected in the delta graph, and reports none otherwise. The saved
        // slice changes only while one could be drawn, so other choices keep it for the next selection.
        if state.presentation == .delta, state.selectedNodeStableID != nil {
            preferences.slice = state.slice.map(Self.slice)
        }
        preferences.noise = HistoryFlowNoiseLevel(rawValue: state.noise.rawValue) ?? preferences.noise
        preferences.groupsByConcern = state.groupsByConcern
        guard preferences != ApplicationSettings.historyFlowReviewPreferences else { return }
        ApplicationSettings.historyFlowReviewPreferences = preferences
        Self.logger.notice(
            """
            Saved Flow review preferences: \(preferences.presentation.rawValue, privacy: .public), \
            slice \(preferences.slice?.rawValue ?? "none", privacy: .public), \
            noise \(preferences.noise.rawValue, privacy: .public), \
            grouped \(preferences.groupsByConcern, privacy: .public)
            """
        )
    }
}
