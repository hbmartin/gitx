import AppKit
import ForgeKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

extension Notification.Name {
    static let repositoryForgeManualRefreshRequested = Notification.Name(
        "PBRepositoryForgeManualRefreshRequested"
    )
    static let repositoryRemoteOperationDidSucceed = Notification.Name(
        "PBRepositoryRemoteOperationDidSucceedNotification"
    )
}

@MainActor
// Production wiring consumes this protocol through existential storage.
// swiftlint:disable:next unused_declaration
protocol RepositoryForgeStatusCoordinating: AnyObject {
    var currentInput: ForgeRepositoryStatusInput { get }
    var inputDidChange: ((ForgeRepositoryStatusInput) -> Void)? { get set }

    // Production wiring invokes this through the protocol existential.
    // swiftlint:disable:next unused_declaration
    func updateStatus(_ input: ForgeRepositoryStatusInput)
    func requestManualRefresh()
    func showDetails(for action: ForgeStatusDetailsAction)
}

/// Deterministic test seam for status-bar wiring. Production repository windows
/// bind the live `RepositoryForgeOverlaySession` through the same protocol.
@MainActor
// Production wiring and the app-hosted test target instantiate this coordinator.
// swiftlint:disable:next unused_declaration
final class RepositoryForgeStatusCoordinator: RepositoryForgeStatusCoordinating {
    private(set) var currentInput: ForgeRepositoryStatusInput
    var inputDidChange: ((ForgeRepositoryStatusInput) -> Void)?

    private let manualRefreshHandler: () -> Void
    private let detailsHandler: (ForgeStatusDetailsAction) -> Void

    init(
        initialInput: ForgeRepositoryStatusInput,
        manualRefreshHandler: @escaping () -> Void,
        detailsHandler: @escaping (ForgeStatusDetailsAction) -> Void
    ) {
        currentInput = initialInput
        self.manualRefreshHandler = manualRefreshHandler
        self.detailsHandler = detailsHandler
    }

    func updateStatus(_ input: ForgeRepositoryStatusInput) {
        currentInput = input
        inputDidChange?(input)
    }

    func requestManualRefresh() {
        manualRefreshHandler()
    }

    func showDetails(for action: ForgeStatusDetailsAction) {
        detailsHandler(action)
    }

    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
    static func postManualRefresh(
        from source: AnyObject,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(
            name: .repositoryForgeManualRefreshRequested,
            object: source,
            userInfo: ["reason": ForgeRefreshReason.manual.rawValue]
        )
    }
}

@MainActor
enum RepositoryStatusBarPalette {
    static func colors(for appearance: NSAppearance) -> (top: NSColor, bottom: NSColor, border: NSColor) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return (
                NSColor(calibratedWhite: 0.29, alpha: 1),
                NSColor(calibratedWhite: 0.19, alpha: 1),
                NSColor(calibratedWhite: 0.08, alpha: 1)
            )
        }
        return (
            NSColor(calibratedWhite: 0.96, alpha: 1),
            NSColor(calibratedWhite: 0.84, alpha: 1),
            NSColor(calibratedWhite: 0.62, alpha: 1)
        )
    }
}

@MainActor
final class RepositoryStatusBarView: NSView {
    let branchLabel = NSTextField(labelWithString: "Repository")
    let aheadBehindLabel = NSTextField(labelWithString: "")
    let countsLabel = NSTextField(labelWithString: "Clean")
    let localProgress = NSProgressIndicator()
    let operationLabel = NSTextField(labelWithString: "")
    let forgeRepositoryLabel = NSTextField(labelWithString: "No Forge Repository")
    let forgeAccountLabel = NSTextField(labelWithString: "")
    let forgeProgress = NSProgressIndicator()
    let forgeFreshnessLabel = NSTextField(labelWithString: "Local only")
    let forgeDiagnosticLabel = NSTextField(labelWithString: "")
    let forgeRefreshButton = NSButton()
    let detailsButton = NSButton(title: "Details", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("GitX.RepositoryStatusBar")
        configureLabels()
        configureProgressIndicators()
        configureButtons()
        installContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = RepositoryStatusBarPalette.colors(for: effectiveAppearance)
        NSGradient(starting: palette.top, ending: palette.bottom)?.draw(in: bounds, angle: -90)
        palette.border.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        apply(layout: RepositoryStatusBarLayout.presentation(forWidth: bounds.width))
    }

    func apply(local presentation: RepositoryLocalStatusPresentation) {
        branchLabel.stringValue = presentation.branchText
        aheadBehindLabel.stringValue = presentation.aheadBehindText ?? ""
        aheadBehindLabel.isHidden = presentation.aheadBehindText == nil
        countsLabel.stringValue = presentation.countsText
        operationLabel.stringValue = presentation.operationText ?? ""
        operationLabel.isHidden = presentation.operationText == nil
        setProgress(localProgress, active: presentation.showsProgress)
        setAccessibilityLabel("Repository status: \(presentation.accessibilityLabel)")
        needsLayout = true
    }

    func apply(forge presentation: ForgeRepositoryStatusPresentation) {
        forgeRepositoryLabel.stringValue = presentation.repositoryText
        forgeAccountLabel.stringValue = presentation.accountText ?? ""
        forgeAccountLabel.isHidden = presentation.accountText == nil
        forgeFreshnessLabel.stringValue = presentation.freshnessText
        forgeDiagnosticLabel.stringValue = presentation.diagnosticText ?? ""
        forgeDiagnosticLabel.isHidden = presentation.diagnosticText == nil
        forgeDiagnosticLabel.textColor = presentation.diagnosticText == nil ? .secondaryLabelColor : .systemOrange
        setProgress(forgeProgress, active: presentation.showsProgress)
        forgeRefreshButton.isEnabled = presentation.isRefreshEnabled
        forgeRefreshButton.toolTip = refreshToolTip(for: presentation)
        detailsButton.isHidden = presentation.detailsAction == nil
        detailsButton.isEnabled = presentation.detailsAction != nil
        setAccessibilityHelp(presentation.accessibilityLabel)
        needsLayout = true
    }

    func apply(layout: RepositoryStatusBarLayout) {
        aheadBehindLabel.isHidden = !layout.showsAheadBehind || aheadBehindLabel.stringValue.isEmpty
        countsLabel.isHidden = !layout.showsLocalCounts
        forgeAccountLabel.isHidden = !layout.showsForgeAccount || forgeAccountLabel.stringValue.isEmpty
        forgeFreshnessLabel.isHidden = !layout.showsForgeFreshness
    }

    private func configureLabels() {
        let labels = [
            branchLabel,
            aheadBehindLabel,
            countsLabel,
            operationLabel,
            forgeRepositoryLabel,
            forgeAccountLabel,
            forgeFreshnessLabel,
            forgeDiagnosticLabel,
        ]
        for label in labels {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        branchLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        forgeRepositoryLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        operationLabel.textColor = .secondaryLabelColor
        countsLabel.textColor = .secondaryLabelColor
        aheadBehindLabel.textColor = .secondaryLabelColor
        forgeAccountLabel.textColor = .secondaryLabelColor
        forgeFreshnessLabel.textColor = .secondaryLabelColor

        branchLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.LocalBranch")
        aheadBehindLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.LocalAheadBehind")
        countsLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.LocalCounts")
        operationLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.LocalOperation")
        forgeRepositoryLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeRepository")
        forgeAccountLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeAccount")
        forgeFreshnessLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeFreshness")
        forgeDiagnosticLabel.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeDiagnostic")
    }

    private func configureProgressIndicators() {
        for indicator in [localProgress, forgeProgress] {
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isDisplayedWhenStopped = false
            indicator.isHidden = true
            indicator.widthAnchor.constraint(equalToConstant: 14).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        localProgress.setAccessibilityIdentifier("GitX.RepositoryStatusBar.LocalProgress")
        forgeProgress.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeProgress")
    }

    private func configureButtons() {
        forgeRefreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh Forge Overlay"
        )
        forgeRefreshButton.bezelStyle = .texturedRounded
        forgeRefreshButton.controlSize = .small
        forgeRefreshButton.imagePosition = .imageOnly
        forgeRefreshButton.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeRefresh")
        forgeRefreshButton.setAccessibilityLabel("Refresh Forge Overlay")
        forgeRefreshButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        detailsButton.bezelStyle = .inline
        detailsButton.controlSize = .small
        detailsButton.setAccessibilityIdentifier("GitX.RepositoryStatusBar.ForgeDetails")
        detailsButton.setAccessibilityLabel("Forge status details")
        detailsButton.isHidden = true
    }

    private func installContents() {
        let local = NSStackView(views: [branchLabel, aheadBehindLabel, countsLabel, localProgress, operationLabel])
        local.orientation = .horizontal
        local.alignment = .centerY
        local.spacing = 7
        local.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 17).isActive = true

        let forge = NSStackView(views: [
            forgeRepositoryLabel,
            forgeAccountLabel,
            forgeProgress,
            forgeFreshnessLabel,
            forgeDiagnosticLabel,
            forgeRefreshButton,
            detailsButton,
        ])
        forge.orientation = .horizontal
        forge.alignment = .centerY
        forge.spacing = 7

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [local, spacer, divider, forge])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func setProgress(_ progress: NSProgressIndicator, active: Bool) {
        if active {
            progress.isHidden = false
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            progress.isHidden = true
        }
    }

    private func refreshToolTip(for presentation: ForgeRepositoryStatusPresentation) -> String {
        if let deadline = presentation.rateLimitResetAt {
            return "Rate limited until \(DateFormatter.localizedString(from: deadline, dateStyle: .none, timeStyle: .short))"
        }
        return presentation.refreshDisabledReason ?? "Refresh the cached Forge Overlay"
    }
}

/// AppKit owner for one repository window's status surface. Presentation
/// decisions stay in value types; this object only owns wiring and visibility.
@MainActor
final class RepositoryStatusBarController: NSObject {
    let view = RepositoryStatusBarView()
    private weak var splitView: NSView?
    private weak var contentView: NSView?
    private var shownConstraint: NSLayoutConstraint?
    private var hiddenConstraint: NSLayoutConstraint?
    // MainActor owns all scheduling and ordinary access. Foundation documents
    // Timer invalidation as thread-safe, allowing deinit to tear it down after
    // the final reference is released from any executor.
    // swift6-safety-justification: unsafe isolation is limited to thread-safe Timer invalidation from deinit.
    private(set) nonisolated(unsafe) var refreshTimer: Timer?
    private var forgeInput = ForgeRepositoryStatusInput.unbound
    private(set) var currentForgePresentation = ForgeRepositoryStatusPresenter.present(.unbound, now: .distantPast)
    private(set) var hasScheduledClockRefresh = false
    private var detailsAction: ForgeStatusDetailsAction?
    private var forgeCoordinator: (any RepositoryForgeStatusCoordinating)?
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryStatusBar")

    var presentationDidChange: ((ForgeRepositoryStatusPresentation) -> Void)?

    init(splitView: NSView, contentView: NSView, now: @escaping () -> Date = Date.init) {
        self.splitView = splitView
        self.contentView = contentView
        self.now = now
        super.init()
        view.forgeRefreshButton.target = self
        view.forgeRefreshButton.action = #selector(refreshForgeOverlay(_:))
        view.detailsButton.target = self
        view.detailsButton.action = #selector(showDetails(_:))
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func bind(to coordinator: any RepositoryForgeStatusCoordinating) {
        forgeCoordinator?.inputDidChange = nil
        forgeCoordinator = coordinator
        coordinator.inputDidChange = { [weak self] input in
            self?.updateForge(input)
        }
        updateForge(coordinator.currentInput)
    }

    func install(visible: Bool) {
        guard let splitView, let contentView, view.superview == nil else { return }
        for constraint in contentView.constraints where constraint.connectsBottom(of: splitView, and: contentView) {
            constraint.isActive = false
        }
        contentView.addSubview(view)
        shownConstraint = splitView.bottomAnchor.constraint(equalTo: view.topAnchor)
        hiddenConstraint = splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 29),
        ])
        setVisible(visible)
        updateForge(forgeInput)
        logger.info("Installed repository status bar visible=\(visible, privacy: .public)")
    }

    func setVisible(_ visible: Bool) {
        guard view.superview != nil else { return }
        if visible {
            hiddenConstraint?.isActive = false
            shownConstraint?.isActive = true
        } else {
            shownConstraint?.isActive = false
            hiddenConstraint?.isActive = true
        }
        view.isHidden = !visible
        logger.debug("Repository status bar visibility changed visible=\(visible, privacy: .public)")
        if visible {
            view.needsLayout = true
        }
    }

    func updateLocal(_ presentation: RepositoryLocalStatusPresentation) {
        view.apply(local: presentation)
        logger.debug(
            "Updated local status busy=\(presentation.showsProgress, privacy: .public) hasOperation=\(presentation.operationText != nil, privacy: .public)"
        )
    }

    func updateForge(_ input: ForgeRepositoryStatusInput) {
        forgeInput = input
        let presentation = ForgeRepositoryStatusPresenter.present(input, now: now())
        currentForgePresentation = presentation
        detailsAction = presentation.detailsAction
        view.apply(forge: presentation)
        scheduleRefreshTimer(for: presentation)
        presentationDidChange?(presentation)
        logger.info(
            "Updated Forge status progress=\(presentation.showsProgress, privacy: .public) diagnostic=\(presentation.diagnosticText != nil, privacy: .public) refreshEnabled=\(presentation.isRefreshEnabled, privacy: .public)"
        )
    }

    func invalidate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasScheduledClockRefresh = false
        forgeCoordinator?.inputDidChange = nil
        forgeCoordinator = nil
    }

    @objc private func refreshForgeOverlay(_ sender: Any?) {
        guard view.forgeRefreshButton.isEnabled else { return }
        logger.info("Requested manual Forge refresh")
        forgeCoordinator?.requestManualRefresh()
    }

    @objc private func showDetails(_ sender: Any?) {
        requestCurrentDetails()
    }

    func requestCurrentDetails() {
        guard let detailsAction else { return }
        logger.info("Requested Forge diagnostic details action=\(detailsAction.rawValue, privacy: .public)")
        forgeCoordinator?.showDetails(for: detailsAction)
    }

    func refreshClock() {
        updateForge(forgeInput)
    }

    private func scheduleRefreshTimer(for presentation: ForgeRepositoryStatusPresentation) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasScheduledClockRefresh = false
        guard presentation.requiresClockUpdates else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            // swift6-safety-justification: this Timer is installed only on RunLoop.main by the MainActor owner.
            MainActor.assumeIsolated {
                self?.refreshClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        hasScheduledClockRefresh = true
    }
}

@MainActor
final class RepositoryLocalStatusLoader: NSObject {
    private unowned let repository: PBGitRepository
    private let gitExecutablePath: String
    private let update: (RepositoryLocalStatusSnapshot) -> Void
    private var generation = 0
    private var task: PBTask?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryLocalStatus")

    init(
        repository: PBGitRepository,
        gitExecutablePath: String,
        update: @escaping (RepositoryLocalStatusSnapshot) -> Void
    ) {
        self.repository = repository
        self.gitExecutablePath = gitExecutablePath
        self.update = update
        super.init()
    }

    func refresh() {
        cancelCurrentTask()
        generation += 1
        let requestedGeneration = generation
        guard let directory = repository.workingDirectoryURL()?.path ?? repository.gitURL()?.path else {
            update(.unavailable)
            return
        }
        let operation = repository.gitURL().flatMap { gitDirectory in
            RepositoryGitOperationDetector.detect(gitDirectory: gitDirectory) {
                FileManager.default.fileExists(atPath: $0)
            }
        }
        let task = PBTask(
            launchPath: gitExecutablePath,
            arguments: ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
            inDirectory: directory
        )
        task.timeout = 10
        self.task = task
        logger.debug("Loading local repository status generation=\(requestedGeneration, privacy: .public)")
        task.perform(on: .main) { [weak self] data, error in
            // swift6-safety-justification: PBTask's `.main` completion queue guarantees synchronous MainActor execution.
            MainActor.assumeIsolated {
                guard let self, requestedGeneration == self.generation else { return }
                self.task = nil
                guard error == nil,
                      let data,
                      let snapshot = RepositoryPorcelainStatusParser.parse(data, operation: operation)
                else {
                    self.logger.error("Local repository status unavailable generation=\(requestedGeneration, privacy: .public)")
                    self.update(.unavailable)
                    return
                }
                self.logger.debug(
                    "Loaded local repository status staged=\(snapshot.counts.staged, privacy: .public) unstaged=\(snapshot.counts.unstaged, privacy: .public) untracked=\(snapshot.counts.untracked, privacy: .public) conflicts=\(snapshot.counts.conflicts, privacy: .public)"
                )
                self.update(snapshot)
            }
        }
    }

    func cancel() {
        generation += 1
        cancelCurrentTask()
    }

    private func cancelCurrentTask() {
        task?.terminate()
        task = nil
    }
}

private extension NSLayoutConstraint {
    func connectsBottom(of firstView: NSView, and secondView: NSView) -> Bool {
        guard firstAttribute == .bottom, secondAttribute == .bottom else { return false }
        return (firstItem as AnyObject?) === firstView && (secondItem as AnyObject?) === secondView ||
            (firstItem as AnyObject?) === secondView && (secondItem as AnyObject?) === firstView
    }
}
