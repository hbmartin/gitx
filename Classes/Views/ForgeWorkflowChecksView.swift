import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

/// What the checks view says and offers for an inspection, kept out of the view so it is testable.
struct ForgeWorkflowChecksPresentation: Equatable {
    static let fallbackPermissionsURL = URL(string: "https://github.com/settings/installations")!

    let note: String?
    let showsPermissionsButton: Bool
    let canLoadMoreSuites: Bool

    init(_ inspection: ForgeWorkflowInspection) {
        var notes: [String] = []
        if inspection.snapshot.suites.items.isEmpty {
            notes.append("No checks have run on this commit.")
        }
        if inspection.access == .denied {
            notes.append("Half Dark can’t see which workflow runs these checks belong to, because the GitHub App or token can’t read Actions. Jobs still open on GitHub.")
        }
        if inspection.isPartial {
            notes.append("GitHub left part of this answer out.")
        }
        note = notes.isEmpty ? nil : notes.joined(separator: " ")
        showsPermissionsButton = inspection.access == .denied
        canLoadMoreSuites = inspection.snapshot.suites.nextCursor != nil
    }

    static func title(_ suite: ForgeWorkflowRun) -> String {
        var title = ForgeWorkflowPresentationPolicy.summary(suite)
        if let total = suite.jobs.totalCount, total > suite.jobs.items.count {
            title += " — \(suite.jobs.items.count) of \(total) jobs"
        }
        return title
    }

    static func title(_ job: ForgeWorkflowJob) -> String {
        "\(job.name) · \(ForgeWorkflowPresentationPolicy.outcomeName(job.outcome))"
    }

    static func title(_ step: ForgeWorkflowStep) -> String {
        "\(step.number). \(step.name) · \(ForgeWorkflowPresentationPolicy.outcomeName(step.outcome))"
    }

    /// The run to open for "Re-run Failed Jobs on GitHub…": the selected suite's, or the only eligible one.
    static func rerunDestination(selected: ForgeWorkflowRun?, in inspection: ForgeWorkflowInspection) -> ForgeDestination? {
        let candidates = selected.map { [$0] } ?? inspection.snapshot.suites.items
        let eligible = candidates.compactMap { suite -> ForgeDestination? in
            guard case let .openRun(destination) = ForgeWorkflowPresentationPolicy.rerunFailedEligibility(suite) else { return nil }
            return destination
        }
        return eligible.count == 1 ? eligible[0] : nil
    }

    /// The page "View Job on GitHub" opens for a job: its Actions job page, or another app's details page.
    static func jobTarget(_ job: ForgeWorkflowJob) -> ForgeWorkflowLinkTarget? {
        if let destination = job.destination {
            return .destination(destination)
        }
        return job.detailsURL.map(ForgeWorkflowLinkTarget.url)
    }

    static func symbol(_ outcome: ForgeWorkflowOutcome) -> (name: String, color: NSColor) {
        switch outcome {
        case .failed, .timedOut: ("xmark.circle.fill", .systemRed)
        case .cancelled, .skipped, .neutral: ("minus.circle.fill", .systemGray)
        case .actionRequired: ("exclamationmark.triangle.fill", .systemOrange)
        case .queued, .waiting, .running: ("clock.fill", .systemOrange)
        case .succeeded: ("checkmark.circle.fill", .systemGreen)
        }
    }
}

enum ForgeWorkflowLinkTarget: Equatable {
    case destination(ForgeDestination)
    case url(URL)
}

/// One row of the checks outline: a suite, a job, a step, or a message in place of steps.
final class ForgeWorkflowOutlineNode: NSObject {
    enum Kind {
        case suite(ForgeWorkflowRun)
        case job(ForgeWorkflowJob)
        case step(ForgeWorkflowStep)
        case message(String)
    }

    let kind: Kind
    var children: [ForgeWorkflowOutlineNode]
    var loadsStepsOnExpand: Bool

    init(_ kind: Kind, children: [ForgeWorkflowOutlineNode] = [], loadsStepsOnExpand: Bool = false) {
        self.kind = kind
        self.children = children
        self.loadsStepsOnExpand = loadsStepsOnExpand
    }

    var isExpandable: Bool {
        loadsStepsOnExpand || !children.isEmpty
    }
}

/// The workflow runs, jobs and steps of a pull request's head commit (ADR 0015). Steps load when a job is
/// expanded. Reruns and logs stay on GitHub: every button opens a page there.
@MainActor
final class ForgeWorkflowChecksView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeWorkflows")

    var openTarget: ((ForgeWorkflowLinkTarget) -> Void)?

    private let service: ForgeWorkflowInspectionService
    private let pullRequest: ForgePullRequestSummary
    private(set) var inspection: ForgeWorkflowInspection?
    private(set) var roots: [ForgeWorkflowOutlineNode] = []
    private var loadToken = 0
    private var rateLimitedUntil: Date?

    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let outlineView = NSOutlineView()
    let rerunButton = NSButton(title: "Re-run Failed Jobs on GitHub…", target: nil, action: nil)
    let viewJobButton = NSButton(title: "View Job on GitHub", target: nil, action: nil)
    let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let permissionsButton = NSButton(title: "Review App Permissions on GitHub…", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(service: ForgeWorkflowInspectionService, pullRequest: ForgePullRequestSummary) {
        self.service = service
        self.pullRequest = pullRequest
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        configure()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the cached answer at once, if any, and reads it otherwise.
    func start() {
        if let cached = service.cachedInspection(for: pullRequest) {
            apply(cached)
        } else {
            load(refresh: false)
        }
    }

    func load(refresh: Bool) {
        loadToken += 1
        let token = loadToken
        showStatus("Loading checks…", busy: true)
        refreshButton.isEnabled = false
        Task { @MainActor [weak self, service, pullRequest] in
            do {
                let inspection = try await service.inspect(pullRequest, refresh: refresh)
                guard let self, token == loadToken else { return }
                rateLimitedUntil = nil
                apply(inspection)
            } catch {
                guard let self, token == loadToken else { return }
                fail(error)
            }
        }
    }

    func apply(_ inspection: ForgeWorkflowInspection) {
        self.inspection = inspection
        let presentation = ForgeWorkflowChecksPresentation(inspection)
        noteLabel.stringValue = presentation.note ?? ""
        noteLabel.isHidden = presentation.note == nil
        permissionsButton.isHidden = !presentation.showsPermissionsButton
        roots = ForgeWorkflowPresentationPolicy.ordered(inspection.snapshot.suites.items).map { suite in
            ForgeWorkflowOutlineNode(.suite(suite), children: ForgeWorkflowPresentationPolicy.ordered(suite.jobs.items).map { job in
                ForgeWorkflowOutlineNode(.job(job), loadsStepsOnExpand: job.destination != nil)
            })
        }
        outlineView.reloadData()
        for root in roots {
            if case let .suite(suite) = root.kind, suite.outcome.isRerunnableFailure {
                outlineView.expandItem(root)
            }
        }
        showStatus(nil, busy: false)
        refreshButton.isEnabled = rateLimitedUntil == nil
        updateButtons()
        // Swift's logger interpolation captures these values in an escaping autoclosure.
        // swiftformat:disable:next redundantSelf
        Self.logger.info("Showing workflow checks suites=\(self.roots.count)")
    }

    // MARK: Outline

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ForgeWorkflowOutlineNode)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ForgeWorkflowOutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ForgeWorkflowOutlineNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ForgeWorkflowOutlineNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("GitX.Workflows.Cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        let title: String
        var outcome: ForgeWorkflowOutcome?
        switch node.kind {
        case let .suite(suite):
            title = ForgeWorkflowChecksPresentation.title(suite)
            outcome = suite.outcome
        case let .job(job):
            title = ForgeWorkflowChecksPresentation.title(job)
            outcome = job.outcome
        case let .step(step):
            title = ForgeWorkflowChecksPresentation.title(step)
            outcome = step.outcome
        case let .message(message):
            title = message
        }
        cell.textField?.stringValue = title
        cell.textField?.textColor = outcome == nil ? .secondaryLabelColor : .labelColor
        if let outcome {
            let symbol = ForgeWorkflowChecksPresentation.symbol(outcome)
            let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: ForgeWorkflowPresentationPolicy.outcomeName(outcome))
            cell.imageView?.image = image
            cell.imageView?.contentTintColor = symbol.color
        } else {
            cell.imageView?.image = nil
        }
        cell.setAccessibilityLabel(title)
        return cell
    }

    func outlineViewSelectionDidChange(_: Notification) {
        updateButtons()
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ForgeWorkflowOutlineNode,
              node.loadsStepsOnExpand,
              case let .job(job) = node.kind
        else { return }
        node.loadsStepsOnExpand = false
        node.children = [ForgeWorkflowOutlineNode(.message("Loading steps…"))]
        Task { @MainActor [weak self, service] in
            let children: [ForgeWorkflowOutlineNode]
            do {
                let steps = try await service.steps(of: job)
                children = steps.isEmpty
                    ? [ForgeWorkflowOutlineNode(.message("No steps"))]
                    : steps.map { ForgeWorkflowOutlineNode(.step($0)) }
            } catch {
                children = [ForgeWorkflowOutlineNode(.message("Couldn’t load steps: \(error.localizedDescription)"))]
            }
            guard let self else { return }
            node.children = children
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        }
    }

    // MARK: Actions

    var selectedNode: ForgeWorkflowOutlineNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? ForgeWorkflowOutlineNode
    }

    private var selectedSuite: ForgeWorkflowRun? {
        guard let node = selectedNode else { return nil }
        if case let .suite(suite) = node.kind {
            return suite
        }
        if let parent = outlineView.parent(forItem: node) as? ForgeWorkflowOutlineNode, case let .suite(suite) = parent.kind {
            return suite
        }
        return nil
    }

    private var selectedJob: ForgeWorkflowJob? {
        guard let node = selectedNode else { return nil }
        if case let .job(job) = node.kind {
            return job
        }
        if let parent = outlineView.parent(forItem: node) as? ForgeWorkflowOutlineNode, case let .job(job) = parent.kind {
            return job
        }
        return nil
    }

    func updateButtons() {
        guard let inspection else {
            [rerunButton, viewJobButton, loadMoreButton].forEach { $0.isEnabled = false }
            return
        }
        rerunButton.isEnabled = ForgeWorkflowChecksPresentation.rerunDestination(selected: selectedSuite, in: inspection) != nil
        viewJobButton.isEnabled = selectedJob.flatMap(ForgeWorkflowChecksPresentation.jobTarget) != nil
        let suiteHasMore = selectedSuite?.jobs.nextCursor != nil
        loadMoreButton.isEnabled = suiteHasMore || ForgeWorkflowChecksPresentation(inspection).canLoadMoreSuites
        loadMoreButton.title = suiteHasMore ? "Load More Jobs" : "Load More"
    }

    @objc func rerunFailedJobs(_: Any?) {
        guard let inspection,
              let destination = ForgeWorkflowChecksPresentation.rerunDestination(selected: selectedSuite, in: inspection)
        else { return }
        Self.logger.notice("Opening workflow run on GitHub to rerun failed jobs")
        openTarget?(.destination(destination))
    }

    @objc func viewJob(_: Any?) {
        guard let target = selectedJob.flatMap(ForgeWorkflowChecksPresentation.jobTarget) else { return }
        Self.logger.notice("Opening workflow job on GitHub")
        openTarget?(target)
    }

    @objc func reviewPermissions(_: Any?) {
        let url = inspection?.permissionsURL ?? ForgeWorkflowChecksPresentation.fallbackPermissionsURL
        Self.logger.notice("Opening GitHub App permissions")
        openTarget?(.url(url))
    }

    @objc func refresh(_: Any?) {
        load(refresh: true)
    }

    @objc func loadMore(_: Any?) {
        guard let inspection else { return }
        loadToken += 1
        let token = loadToken
        let suite = selectedSuite.flatMap { $0.jobs.nextCursor == nil ? nil : $0 }
        showStatus("Loading more…", busy: true)
        Task { @MainActor [weak self, service] in
            do {
                let updated = if let suite {
                    try await service.loadMoreJobs(of: suite, in: inspection)
                } else {
                    try await service.loadMoreSuites(inspection)
                }
                guard let self, token == loadToken else { return }
                apply(updated)
            } catch {
                guard let self, token == loadToken else { return }
                fail(error)
            }
        }
    }

    @objc private func doubleClick(_: Any?) {
        viewJob(nil)
    }

    // MARK: Layout

    private func fail(_ error: Error) {
        if case let ForgeWorkflowInspectionError.rateLimited(until) = error {
            rateLimitedUntil = until ?? Date.distantFuture
            refreshButton.isEnabled = false
            let time = until.map { $0.formatted(date: .omitted, time: .shortened) }
            showStatus(time.map { "Rate limited until \($0)" } ?? "Rate limited by GitHub", busy: false)
            refreshButton.toolTip = statusLabel.stringValue
            return
        }
        refreshButton.isEnabled = true
        showStatus("Couldn’t load checks: \(error.localizedDescription)", busy: false)
        updateButtons()
    }

    private func showStatus(_ message: String?, busy: Bool) {
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = message == nil
        if busy {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        if let message {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 14),
            image.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure() {
        setAccessibilityIdentifier("GitX.Workflows.View")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Checks")
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.setAccessibilityIdentifier("GitX.Workflows.Note")
        noteLabel.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.setAccessibilityIdentifier("GitX.Workflows.Status")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitX.Workflows.Column"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .small
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClick(_:))
        outlineView.setAccessibilityIdentifier("GitX.Workflows.Outline")
        outlineView.setAccessibilityLabel("Workflow runs, jobs and steps")
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let buttons: [(NSButton, Selector, String)] = [
            (rerunButton, #selector(rerunFailedJobs(_:)), "GitX.Workflows.Rerun"),
            (viewJobButton, #selector(viewJob(_:)), "GitX.Workflows.ViewJob"),
            (loadMoreButton, #selector(loadMore(_:)), "GitX.Workflows.LoadMore"),
            (refreshButton, #selector(refresh(_:)), "GitX.Workflows.Refresh"),
            (permissionsButton, #selector(reviewPermissions(_:)), "GitX.Workflows.Permissions"),
        ]
        for (button, action, identifier) in buttons {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setAccessibilityIdentifier(identifier)
        }
        rerunButton.toolTip = "Opens the workflow run on GitHub, where you confirm rerunning its failed jobs."
        permissionsButton.isHidden = true
        let primary = NSStackView(views: [rerunButton, viewJobButton, NSView(), spinner, loadMoreButton, refreshButton])
        primary.orientation = .horizontal
        primary.spacing = 6
        let stack = NSStackView(views: [noteLabel, scroll, primary, permissionsButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            primary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateButtons()
    }
}

/// A sheet showing one pull request's workflow runs, for Attention's "Show Failed Jobs…".
@MainActor
final class ForgeWorkflowChecksSheet: NSObject {
    let panel: NSPanel
    let checks: ForgeWorkflowChecksView
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var completion: (() -> Void)?

    init(service: ForgeWorkflowInspectionService, pullRequest: ForgePullRequestSummary) {
        checks = ForgeWorkflowChecksView(service: service, pullRequest: pullRequest)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = "Failed Jobs"
        panel.setAccessibilityIdentifier("GitX.Workflows.Sheet")
        let title = NSTextField(labelWithString: "#\(pullRequest.number.rawValue) \(pullRequest.title)")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityIdentifier("GitX.Workflows.Sheet.Title")
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityIdentifier("GitX.Workflows.Sheet.Done")
        let footer = NSStackView(views: [NSView(), doneButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [title, checks, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            checks.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
        ])
    }

    func present(for window: NSWindow, completion: @escaping () -> Void) {
        self.completion = completion
        window.beginSheet(panel) { [weak self] _ in
            self?.completion?()
            self?.completion = nil
        }
        checks.start()
    }

    @objc func done(_: Any?) {
        panel.sheetParent?.endSheet(panel)
    }
}
