import AppKit
import FlowDeltaAnalysis
import FlowDeltaCore
import FlowDeltaGit
import FlowDeltaUI
import GitXCore
import OSLog // swiftlint:disable:this unused_import -- Logger and privacy interpolation require OSLog.

@MainActor
@objc(PBFlowDeltaAdapterView)
final class FlowDeltaAdapterView: NSView {
    private static let logger = Logger(subsystem: "com.gitx.GitX", category: "FlowDelta")

    @IBOutlet private weak var historyController: PBGitHistoryController?

    private let reviewView = FlowDeltaReviewView()
    private let statusOverlay = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "Select a commit to review its flow delta.")
    private let progressIndicator = NSProgressIndicator()
    private var selectionObservation: NSKeyValueObservation?
    private var tabObservation: NSKeyValueObservation?
    private var analysisTask: Task<Void, Never>?
    private var representedRequest: HistoryFlowRevisionRequest?
    private var generation = 0

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
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("History.Flow.View")
        setAccessibilityLabel("Commit flow delta")

        reviewView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reviewView)

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
            reviewView.topAnchor.constraint(equalTo: topAnchor),
            reviewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            reviewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            reviewView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let commits = historyController.selectedCommits.map { commit in
            HistoryFlowCommitInput(
                sha: commit.sha,
                firstParentSHA: commit.parents.first?.sha,
                isWorkingState: commit is PBUncommittedChanges
            )
        }
        let decision = HistoryFlowSelectionPolicy().decision(
            selectedTabIndex: historyController.selectedCommitDetailsIndex,
            repositoryURL: historyController.repository?.workingDirectoryURL(),
            commits: commits
        )
        apply(decision)
    }

    private func apply(_ decision: HistoryFlowSelectionDecision) {
        switch decision {
        case .inactive:
            analysisTask?.cancel()
        case let .message(message):
            representedRequest = nil
            analysisTask?.cancel()
            showMessage(message)
        case let .load(request):
            guard representedRequest != request else { return }
            representedRequest = request
            load(request)
        }
    }

    private func load(_ request: HistoryFlowRevisionRequest) {
        analysisTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        showLoading("Analyzing \(String(request.target.prefix(8)))…")
        Self.logger.notice(
            "Loading flow delta \(request.base, privacy: .public) → \(request.target, privacy: .public)"
        )
        analysisTask = Task { [weak self] in
            do {
                let report = try await Self.analyze(request)
                try Task.checkCancellation()
                guard let self, requestedGeneration == self.generation else { return }
                self.reviewView.display(report)
                self.reviewView.isHidden = false
                self.statusOverlay.isHidden = true
                Self.logger.notice("Displayed History flow delta with \(report.functionDeltas.count) functions")
            } catch is CancellationError {
                Self.logger.debug("Cancelled stale History flow analysis")
            } catch {
                guard let self, requestedGeneration == self.generation else { return }
                Self.logger.error("History flow analysis failed: \(String(describing: error), privacy: .public)")
                self.showMessage("Flow analysis failed.\n\(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func analyze(
        _ request: HistoryFlowRevisionRequest
    ) async throws -> RevisionFlowDeltaReport {
        let comparison = try await GitCLIRevisionProvider().comparison(
            repositoryURL: request.repositoryURL,
            base: request.base,
            target: request.target
        )
        try Task.checkCancellation()
        return try FlowDeltaAnalyzer().analyze(comparison)
    }

    private func showLoading(_ message: String) {
        reviewView.isHidden = true
        statusOverlay.isHidden = false
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        progressIndicator.startAnimation(nil)
    }

    private func showMessage(_ message: String) {
        reviewView.isHidden = true
        statusOverlay.isHidden = false
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
        progressIndicator.stopAnimation(nil)
    }
}
