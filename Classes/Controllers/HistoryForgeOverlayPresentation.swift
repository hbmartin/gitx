import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

nonisolated struct HistoryForgeBadgePresentation: Equatable, Sendable {
    let checkText: String
    let checkAccessibilityLabel: String
    let pullRequestText: String
    let pullRequestAccessibilityLabel: String
    let isLoading: Bool
}

nonisolated enum HistoryForgeBadgePresenter {
    static let unavailable = HistoryForgeBadgePresentation(
        checkText: "—",
        checkAccessibilityLabel: "Check Rollup unavailable",
        pullRequestText: "—",
        pullRequestAccessibilityLabel: "No Pull Request data",
        isLoading: false
    )

    static func present(
        _ state: RepositoryForgeOverlayValueState<ForgeHistoryOverlay>
    ) -> HistoryForgeBadgePresentation {
        switch state {
        case .unavailable:
            unavailable
        case let .loading(previous):
            previous.map { present($0.value, isLoading: true) } ?? HistoryForgeBadgePresentation(
                checkText: "…",
                checkAccessibilityLabel: "Loading Check Rollup",
                pullRequestText: "…",
                pullRequestAccessibilityLabel: "Loading Pull Request badges",
                isLoading: true
            )
        case let .value(snapshot):
            present(snapshot.value, isLoading: false)
        }
    }

    private static func present(
        _ overlay: ForgeHistoryOverlay,
        isLoading: Bool
    ) -> HistoryForgeBadgePresentation {
        let check = checkPresentation(overlay.checkRollup)
        let pullRequests = pullRequestPresentation(overlay.pullRequests)
        return HistoryForgeBadgePresentation(
            checkText: check.text,
            checkAccessibilityLabel: check.accessibility,
            pullRequestText: pullRequests.text,
            pullRequestAccessibilityLabel: pullRequests.accessibility,
            isLoading: isLoading
        )
    }

    private static func checkPresentation(
        _ section: ForgeReadSection<ForgeCheckRollup>
    ) -> (text: String, accessibility: String) {
        guard case let .available(rollup) = section else {
            return ("—", "Check Rollup unavailable")
        }
        return switch rollup {
        case .succeeded: ("✓ Passed", "Check Rollup succeeded")
        case .failed: ("✕ Failed", "Check Rollup failed")
        case .running: ("● Running", "Check Rollup running")
        case .attentionRequired: ("! Attention", "Check Rollup needs attention")
        case .neutral: ("— Neutral", "Check Rollup neutral")
        }
    }

    private static func pullRequestPresentation(
        _ section: ForgeReadSection<ForgePage<ForgePullRequestSummary>>
    ) -> (text: String, accessibility: String) {
        guard case let .available(page) = section else {
            return ("—", "Pull Request badges unavailable")
        }
        let sorted = page.items.sorted { $0.number.rawValue < $1.number.rawValue }
        guard let first = sorted.first else {
            return ("—", "No associated Pull Requests")
        }
        let total = max(page.totalCount ?? sorted.count, sorted.count)
        let suffix = total > 1 ? " +\(total - 1)" : ""
        let text = "#\(first.number.rawValue)\(suffix)"
        let accessibility = total == 1
            ? "Associated Pull Request number \(first.number.rawValue)"
            : "\(total) associated Pull Requests, beginning with number \(first.number.rawValue)"
        return (text, accessibility)
    }
}

nonisolated struct RepositoryFactsRowPresentation: Equatable, Sendable {
    let label: String
    let value: String
}

nonisolated struct RepositoryFactsPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String
    let rows: [RepositoryFactsRowPresentation]
    let isLoading: Bool
    let accessibilityLabel: String
}

nonisolated enum RepositoryFactsPresenter {
    static func present(
        _ state: RepositoryForgeOverlayValueState<ForgeRepositoryFacts>
    ) -> RepositoryFactsPresentation {
        switch state {
        case let .unavailable(reason):
            let subtitle = switch reason {
            case .authenticationRequired: "Sign in and choose an Account"
            case .unsupported: "Native facts are unavailable"
            case .permissionDenied: "Repository access is required"
            case .notRequested: "Waiting for Forge data"
            case .partialResponse: "Repository facts are unavailable"
            }
            return RepositoryFactsPresentation(
                title: "Repository Facts",
                subtitle: subtitle,
                rows: [],
                isLoading: false,
                accessibilityLabel: "Repository Facts; \(subtitle)"
            )
        case let .loading(previous):
            guard let previous else {
                return RepositoryFactsPresentation(
                    title: "Repository Facts",
                    subtitle: "Loading…",
                    rows: [],
                    isLoading: true,
                    accessibilityLabel: "Repository Facts; loading"
                )
            }
            return presentation(previous, isLoading: true)
        case let .value(snapshot):
            return presentation(snapshot, isLoading: false)
        }
    }

    private static func presentation(
        _ snapshot: RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>,
        isLoading: Bool
    ) -> RepositoryFactsPresentation {
        let facts = snapshot.value
        let rows = [
            RepositoryFactsRowPresentation(label: "Default Branch", value: value(facts.defaultBranch) { $0.value }),
            RepositoryFactsRowPresentation(label: "Description", value: value(facts.description) { $0 ?? "None" }),
            RepositoryFactsRowPresentation(label: "Topics", value: value(facts.topics) {
                $0.isEmpty ? "None" : $0.joined(separator: ", ")
            }),
            RepositoryFactsRowPresentation(label: "Visibility", value: value(facts.visibility) {
                switch $0 {
                case .public: "Public"
                case .private: "Private"
                case .internal: "Internal"
                case .unknown: "Unknown"
                }
            }),
            RepositoryFactsRowPresentation(label: "State", value: value(facts.isArchived) {
                $0 ? "Archived" : "Active"
            }),
            RepositoryFactsRowPresentation(label: "Relationship", value: value(facts.forkRelationship) {
                switch $0 {
                case .standalone: "Standalone"
                case let .fork(parent): "Fork of \(parent.owner)/\(parent.name)"
                }
            }),
        ]
        let stateParts = [
            snapshot.isStale ? "Stale cached data" : nil,
            snapshot.isPartial ? "Partial response" : nil,
            isLoading ? "Refreshing" : nil,
        ].compactMap { $0 }
        let subtitle = stateParts.isEmpty ? "\(facts.repository.owner)/\(facts.repository.name)" : stateParts.joined(separator: " · ")
        let accessibility = (["Repository Facts", subtitle] + rows.map { "\($0.label): \($0.value)" })
            .joined(separator: "; ")
        return RepositoryFactsPresentation(
            title: "Repository Facts",
            subtitle: subtitle,
            rows: rows,
            isLoading: isLoading,
            accessibilityLabel: accessibility
        )
    }

    private static func value<Value: Codable & Hashable & Sendable>(
        _ section: ForgeReadSection<Value>,
        transform: (Value) -> String
    ) -> String {
        switch section {
        case let .available(value): transform(value)
        case .unavailable: "Unavailable"
        }
    }
}

private final nonisolated class HistoryForgeBadgeBox: NSObject {
    let presentation: HistoryForgeBadgePresentation

    init(_ presentation: HistoryForgeBadgePresentation) {
        self.presentation = presentation
    }
}

private nonisolated enum HistoryForgeOverlayRegistry {
    private static let lock = NSLock()
    // swift6-safety-justification: `lock` protects every read and mutation of this weak-keyed presentation cache.
    private nonisolated(unsafe) static let presentations =
        NSMapTable<PBGitCommit, HistoryForgeBadgeBox>.weakToStrongObjects()

    static func presentation(for commit: PBGitCommit) -> HistoryForgeBadgePresentation {
        lock.withLock {
            presentations.object(forKey: commit)?.presentation ?? HistoryForgeBadgePresenter.unavailable
        }
    }

    static func set(_ presentation: HistoryForgeBadgePresentation, for commit: PBGitCommit) {
        lock.withLock { presentations.setObject(HistoryForgeBadgeBox(presentation), forKey: commit) }
    }
}

extension PBGitCommit {
    @objc dynamic var forgeCheckRollupText: String {
        HistoryForgeOverlayRegistry.presentation(for: self).checkText
    }

    @objc dynamic var forgePullRequestBadgeText: String {
        HistoryForgeOverlayRegistry.presentation(for: self).pullRequestText
    }
}

@MainActor
final class RepositoryFactsInspectorController: NSObject {
    private let panel = RepositoryFactsInspectorView()
    private let visibilityDidChange: (Bool) -> Void
    private var widthConstraint: NSLayoutConstraint?
    private var isExpanded: Bool
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryFactsInspector")

    init(isExpanded: Bool, visibilityDidChange: @escaping (Bool) -> Void) {
        self.isExpanded = isExpanded
        self.visibilityDidChange = visibilityDidChange
        super.init()
        panel.collapseButton.target = self
        panel.collapseButton.action = #selector(toggleInspector(_:))
    }

    func install(in rootView: NSView) {
        guard panel.superview == nil,
              let historyContent = rootView.subviews.first(where: { $0 is NSSplitView })
        else { return }

        for constraint in rootView.constraints where constraint.connectsTrailing(of: historyContent, and: rootView) {
            constraint.isActive = false
        }
        rootView.addSubview(panel)
        let width = panel.widthAnchor.constraint(equalToConstant: isExpanded ? 258 : 34)
        widthConstraint = width
        NSLayoutConstraint.activate([
            historyContent.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            panel.topAnchor.constraint(equalTo: historyContent.topAnchor),
            panel.bottomAnchor.constraint(equalTo: historyContent.bottomAnchor),
            width,
        ])
        applyExpansion(animated: false)
        let expanded = isExpanded
        logger.info("Installed History Repository Facts inspector expanded=\(expanded, privacy: .public)")
    }

    func apply(_ state: RepositoryForgeOverlayValueState<ForgeRepositoryFacts>) {
        panel.apply(RepositoryFactsPresenter.present(state))
    }

    @objc private func toggleInspector(_ sender: Any?) {
        isExpanded.toggle()
        visibilityDidChange(isExpanded)
        applyExpansion(animated: true)
        let expanded = isExpanded
        logger.info("History Repository Facts inspector expanded=\(expanded, privacy: .public)")
    }

    private func applyExpansion(animated: Bool) {
        panel.setExpanded(isExpanded)
        widthConstraint?.constant = isExpanded ? 258 : 34
        guard animated else {
            panel.superview?.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            panel.superview?.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
final class RepositoryFactsInspectorView: NSView {
    let collapseButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Repository Facts")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "Waiting for Forge data")
    private let spinner = NSProgressIndicator()
    private let rows = NSStackView()
    private var rowViews: [NSView] = []
    private var isLoading = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("GitX.History.RepositoryFactsInspector")
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.68, alpha: 1).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    func setExpanded(_ expanded: Bool) {
        titleLabel.isHidden = !expanded
        subtitleLabel.isHidden = !expanded
        rows.isHidden = !expanded
        spinner.isHidden = !expanded || !isLoading
        collapseButton.title = expanded ? "›" : "‹"
        collapseButton.toolTip = expanded ? "Hide Repository Facts" : "Show Repository Facts"
        collapseButton.setAccessibilityLabel(collapseButton.toolTip ?? "Repository Facts")
    }

    func apply(_ presentation: RepositoryFactsPresentation) {
        titleLabel.stringValue = presentation.title
        subtitleLabel.stringValue = presentation.subtitle
        for view in rowViews {
            rows.removeArrangedSubview(view); view.removeFromSuperview()
        }
        rowViews = presentation.rows.map(makeRow)
        rowViews.forEach(rows.addArrangedSubview)
        isLoading = presentation.isLoading
        if presentation.isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        spinner.isHidden = titleLabel.isHidden || !isLoading
        setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func configure() {
        collapseButton.bezelStyle = .inline
        collapseButton.font = .boldSystemFont(ofSize: 15)
        collapseButton.setAccessibilityIdentifier("GitX.History.RepositoryFactsInspector.Toggle")
        titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 9

        let header = NSStackView(views: [collapseButton, titleLabel, spinner])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let content = NSStackView(views: [header, subtitleLabel, rows])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            collapseButton.widthAnchor.constraint(equalToConstant: 20),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func makeRow(_ row: RepositoryFactsRowPresentation) -> NSView {
        let label = NSTextField(labelWithString: row.label.uppercased())
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize - 1)
        label.textColor = .secondaryLabelColor
        let value = NSTextField(wrappingLabelWithString: row.value)
        value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        value.maximumNumberOfLines = 4
        value.setAccessibilityLabel("\(row.label): \(row.value)")
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }
}

private extension NSLayoutConstraint {
    func connectsTrailing(of firstView: NSView, and secondView: NSView) -> Bool {
        guard firstAttribute == .trailing, secondAttribute == .trailing else { return false }
        return (firstItem as AnyObject?) === firstView && (secondItem as AnyObject?) === secondView ||
            (firstItem as AnyObject?) === secondView && (secondItem as AnyObject?) === firstView
    }
}

@MainActor
final class HistoryForgeOverlayCoordinator: NSObject {
    private weak var owner: PBGitHistoryController?
    private weak var commitList: PBCommitList?
    private let session: RepositoryForgeOverlaySession
    private let inspector: RepositoryFactsInspectorController
    private var factsToken: UUID?
    private var historyToken: UUID?
    private var columnObservations: [NSKeyValueObservation] = []
    private var arrangedObjectsObservation: NSKeyValueObservation?
    private var boundsObserver: NSObjectProtocol?
    private var requestedCommits: Set<ForgeCommitID> = []
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "HistoryForgeOverlay")

    init?(
        owner: PBGitHistoryController,
        commitList: PBCommitList,
        session: RepositoryForgeOverlaySession,
        factsInspectorInitiallyExpanded: Bool,
        factsInspectorVisibilityDidChange: @escaping (Bool) -> Void
    ) {
        guard owner.repository != nil else { return nil }
        self.owner = owner
        self.commitList = commitList
        self.session = session
        inspector = RepositoryFactsInspectorController(
            isExpanded: factsInspectorInitiallyExpanded,
            visibilityDidChange: factsInspectorVisibilityDidChange
        )
        super.init()
        inspector.install(in: owner.view)
        factsToken = session.observeFacts { [weak self] state in
            self?.inspector.apply(state)
        }
        historyToken = session.observeHistory { [weak self] commit, state in
            self?.apply(state, to: commit)
        }
        observeDemand()
        requestVisibleOverlays()
    }

    // Invoked by the owning window controller and app-hosted verification.
    // swiftlint:disable:next unused_declaration
    func invalidate() {
        if let factsToken {
            session.removeObserver(factsToken)
        }
        if let historyToken {
            session.removeObserver(historyToken)
        }
        factsToken = nil
        historyToken = nil
        columnObservations.removeAll()
        arrangedObjectsObservation = nil
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        boundsObserver = nil
    }

    private func observeDemand() {
        guard let commitList else { return }
        if let owner {
            arrangedObjectsObservation = owner.commitController.observe(
                \.arrangedObjects,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                // swift6-safety-justification: NSArrayController publishes arranged-object changes on AppKit's main thread.
                MainActor.assumeIsolated { self?.requestVisibleOverlays() }
            }
        }
        for identifier in ["ForgeCheckRollupColumn", "ForgePullRequestBadgeColumn"] {
            guard let column = commitList.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) else {
                continue
            }
            columnObservations.append(column.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                // swift6-safety-justification: AppKit delivers table-column visibility KVO on the main thread.
                MainActor.assumeIsolated { self?.requestVisibleOverlays() }
            })
        }
        if let clipView = commitList.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                // swift6-safety-justification: The notification observer explicitly targets the main operation queue.
                MainActor.assumeIsolated { self?.requestVisibleOverlays() }
            }
        }
    }

    private func requestVisibleOverlays() {
        guard let owner, let commitList, forgeColumnsAreVisible(in: commitList),
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit]
        else { return }
        let rows = commitList.rows(in: commitList.visibleRect)
        guard rows.location != NSNotFound else { return }
        let visibleRange = rows.location ..< min(rows.location + rows.length, commits.count)
        var requestCount = 0
        for row in visibleRange {
            let commit = commits[row]
            guard !(commit is PBUncommittedChanges), let identifier = try? ForgeCommitID(commit.sha) else { continue }
            if requestedCommits.insert(identifier).inserted {
                requestCount += 1
                session.requestHistoryOverlay(identifier)
            }
        }
        if requestCount > 0 {
            logger.debug("Demand-loaded History Forge overlays count=\(requestCount, privacy: .public)")
        }
    }

    private func forgeColumnsAreVisible(in table: NSTableView) -> Bool {
        ["ForgeCheckRollupColumn", "ForgePullRequestBadgeColumn"].contains { identifier in
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.isHidden == false
        }
    }

    private func apply(
        _ state: RepositoryForgeOverlayValueState<ForgeHistoryOverlay>,
        to commit: ForgeCommitID
    ) {
        guard let owner, let commitList,
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit]
        else { return }
        let presentation = HistoryForgeBadgePresenter.present(state)
        let matchingRows = commits.enumerated().filter { $0.element.sha.caseInsensitiveCompare(commit.value) == .orderedSame }
        let columns = IndexSet([
            commitList.column(withIdentifier: NSUserInterfaceItemIdentifier("ForgeCheckRollupColumn")),
            commitList.column(withIdentifier: NSUserInterfaceItemIdentifier("ForgePullRequestBadgeColumn")),
        ].filter { $0 >= 0 })
        for (_, item) in matchingRows {
            item.willChangeValue(forKey: "forgeCheckRollupText")
            item.willChangeValue(forKey: "forgePullRequestBadgeText")
        }
        for (_, item) in matchingRows {
            HistoryForgeOverlayRegistry.set(presentation, for: item)
        }
        for (row, item) in matchingRows {
            item.didChangeValue(forKey: "forgePullRequestBadgeText")
            item.didChangeValue(forKey: "forgeCheckRollupText")
            if !columns.isEmpty {
                commitList.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
            }
            applyAccessibility(presentation, toRow: row, in: commitList)
        }
    }

    private func applyAccessibility(
        _ presentation: HistoryForgeBadgePresentation,
        toRow row: Int,
        in table: NSTableView
    ) {
        let labels = [
            "ForgeCheckRollupColumn": presentation.checkAccessibilityLabel,
            "ForgePullRequestBadgeColumn": presentation.pullRequestAccessibilityLabel,
        ]
        for (identifier, label) in labels {
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            guard column >= 0,
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
            else { continue }
            let textField = cell as? NSTextField ?? cell.subviews.compactMap { $0 as? NSTextField }.first
            textField?.setAccessibilityLabel(label)
        }
    }
}
