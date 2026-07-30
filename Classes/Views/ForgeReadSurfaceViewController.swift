import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
protocol ForgeReadMarkdownRendering: AnyObject {
    /// Implementations must use the ForgeKit parse/sanitize pipeline. In
    /// particular, an image node remains inert alt text plus a placeholder.
    func makeView(markdown: String, context: ForgeMarkdownContext) -> NSView
}

@MainActor
protocol ForgeReadAvatarRendering: AnyObject {
    /// Avatar networking, validation, caching, and cancellation remain owned
    /// by the injected avatar view rather than this view controller.
    func makeAvatarView(for actor: ForgeActor, size: NSSize) -> NSView
}

@MainActor
protocol ForgeReadDestinationRouting: AnyObject {
    func openNative(destination: ForgeDestination)
    func openInBrowser(destination: ForgeDestination)
}

@MainActor
final class ForgeReadSurfaceViewController: NSSplitViewController {
    private let service: any ForgeReadSurfaceServing
    private let markdownRenderer: any ForgeReadMarkdownRendering
    private let avatarRenderer: any ForgeReadAvatarRendering
    private let destinationRouter: any ForgeReadDestinationRouting
    private let defaultRevision: ForgeRevision
    private let listController: ForgeReadListViewController
    private let inspectorController: ForgeReadInspectorViewController
    private var accumulator: ForgeReadSurfaceAccumulator
    private var rows: [ForgeReadSurfaceRow] = []
    private var listTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var currentDetailsSnapshot: ForgeReadSurfaceDetailsSnapshot?
    private var detailsGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeReadSurface")

    init(
        kind: ForgeReadSurfaceKind,
        defaultRevision: ForgeRevision,
        service: any ForgeReadSurfaceServing,
        markdownRenderer: any ForgeReadMarkdownRendering,
        avatarRenderer: any ForgeReadAvatarRendering,
        destinationRouter: any ForgeReadDestinationRouting
    ) {
        self.service = service
        self.markdownRenderer = markdownRenderer
        self.avatarRenderer = avatarRenderer
        self.destinationRouter = destinationRouter
        self.defaultRevision = defaultRevision
        accumulator = ForgeReadSurfaceAccumulator(kind: kind)
        listController = ForgeReadListViewController(kind: kind)
        inspectorController = ForgeReadInspectorViewController(
            markdownRenderer: markdownRenderer,
            avatarRenderer: avatarRenderer,
            destinationRouter: destinationRouter,
            defaultRevision: defaultRevision
        )
        super.init(nibName: nil, bundle: nil)

        listController.onReload = { [weak self] query in
            self?.reload(query: query)
        }
        listController.onLoadNextPage = { [weak self] in
            self?.loadNextPage()
        }
        listController.onSelectRow = { [weak self] row in
            self?.selectRow(row)
        }
        listController.onOpenRow = { [weak self] row in
            self?.openRow(row)
        }
        inspectorController.onLoadMoreTimeline = { [weak self] in
            self?.loadMoreDetails(.timeline)
        }
        inspectorController.onLoadMoreChecks = { [weak self] in
            self?.loadMoreDetails(.checks)
        }

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 420
        listItem.canCollapse = false
        addSplitViewItem(listItem)

        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = 320
        inspectorItem.preferredThicknessFraction = 0.38
        inspectorItem.canCollapse = true
        inspectorItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        addSplitViewItem(inspectorItem)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        view.setAccessibilityIdentifier("ForgeReadSurface")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        listTask?.cancel()
        detailsTask?.cancel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard accumulator.fetchedAt == nil, accumulator.activeRequest == nil else { return }
        reload(query: listController.query)
    }

    func show(kind: ForgeReadSurfaceKind) {
        guard kind != accumulator.kind else { return }
        listController.setKind(kind)
        currentDetailsSnapshot = nil
        inspectorController.showPlaceholder("Select a \(kind == .pullRequests ? "pull request" : "issue") to inspect it.")
        reload(kind: kind, query: listController.query)
    }

    func refresh() {
        reload(query: listController.query)
    }

    func setVisibleColumns(_ columns: Set<ForgeReadSurfaceColumn>) {
        listController.setVisibleColumns(columns)
    }

    private func reload(kind: ForgeReadSurfaceKind? = nil, query: ForgeReadSurfaceQuery) {
        listTask?.cancel()
        let request = accumulator.beginReload(kind: kind, query: query)
        renderList()
        logger.info(
            "Loading \(request.kind.displayName, privacy: .public) from first page; search is \(request.query.searchText.isEmpty ? "empty" : "set", privacy: .public)"
        )
        listTask = Task { @MainActor [weak self, service] in
            do {
                let page = try await service.loadItems(
                    kind: request.kind,
                    query: request.query,
                    after: request.cursor
                )
                guard !Task.isCancelled, let self else { return }
                if accumulator.receive(page, for: request) {
                    logger.info("Installed \(page.items.count) Forge list items")
                    renderList()
                } else {
                    logger.debug("Rejected an obsolete Forge list response")
                }
            } catch is CancellationError {
                self?.logger.debug("Cancelled Forge list refresh")
            } catch {
                guard let self else { return }
                if accumulator.fail(error.localizedDescription, for: request) {
                    logger.error("Forge list refresh failed: \(error.localizedDescription, privacy: .public)")
                    renderList()
                }
            }
        }
    }

    private func loadNextPage() {
        guard let request = accumulator.beginNextPage() else { return }
        renderList()
        logger.info("Loading the next \(request.kind.displayName, privacy: .public) page")
        listTask = Task { @MainActor [weak self, service] in
            do {
                let page = try await service.loadItems(
                    kind: request.kind,
                    query: request.query,
                    after: request.cursor
                )
                guard !Task.isCancelled, let self else { return }
                if accumulator.receive(page, for: request) {
                    logger.info("Appended \(page.items.count) Forge list items")
                    renderList()
                }
            } catch is CancellationError {
                self?.logger.debug("Cancelled Forge pagination")
            } catch {
                guard let self else { return }
                if accumulator.fail(error.localizedDescription, for: request) {
                    logger.error("Forge pagination failed: \(error.localizedDescription, privacy: .public)")
                    renderList()
                }
            }
        }
    }

    private func renderList() {
        let presentation = accumulator.presentation(formatDate: Self.dateDescription)
        rows = presentation.rows
        listController.apply(presentation)
    }

    private func selectRow(_ index: Int) {
        guard rows.indices.contains(index) else {
            inspectorController.showPlaceholder("Select an item to inspect it.")
            return
        }
        let item = rows[index].item
        let rowNumber = rows[index].number
        detailsTask?.cancel()
        currentDetailsSnapshot = nil
        detailsGeneration &+= 1
        let generation = detailsGeneration
        inspectorController.showLoading(for: rows[index])
        logger.info("Loading Forge inspector details for \(rowNumber, privacy: .public)")
        detailsTask = Task { @MainActor [weak self, service] in
            do {
                let snapshot = try await service.loadDetails(
                    for: item,
                    timelineAfter: nil,
                    checkAfter: nil
                )
                guard !Task.isCancelled, let self, generation == detailsGeneration else { return }
                guard snapshot.details.item.destination == item.destination else {
                    logger.error("Rejected Forge details for a different destination")
                    inspectorController.showError("GitHub returned details for a different item.", item: item)
                    return
                }
                let presentation = ForgeReadInspectorPresenter.present(
                    snapshot,
                    formatDate: Self.dateDescription
                )
                currentDetailsSnapshot = snapshot
                inspectorController.apply(presentation)
                logger.info("Installed Forge inspector details")
            } catch is CancellationError {
                self?.logger.debug("Cancelled Forge inspector request")
            } catch {
                guard let self, generation == detailsGeneration else { return }
                logger.error("Forge inspector load failed: \(error.localizedDescription, privacy: .public)")
                inspectorController.showError(error.localizedDescription, item: item)
            }
        }
    }

    private func loadMoreDetails(_ continuation: ForgeReadDetailsContinuation) {
        guard let currentDetailsSnapshot else { return }
        let item = currentDetailsSnapshot.details.item
        let cursor: ForgePageCursor?
        switch (currentDetailsSnapshot.details, continuation) {
        case let (.pullRequest(page), .timeline):
            cursor = Self.timelineCursor(page.details.timeline)
        case let (.pullRequest(page), .checks):
            cursor = page.nextCheckCursor
        case let (.issue(details), .timeline):
            cursor = Self.timelineCursor(details.timeline)
        case (.issue, .checks):
            cursor = nil
        }
        guard let cursor else { return }
        detailsTask?.cancel()
        let generation = detailsGeneration
        inspectorController.showContinuationLoading(continuation)
        logger.info("Loading more Forge inspector details")
        detailsTask = Task { @MainActor [weak self, service] in
            do {
                let next = try await service.loadDetails(
                    for: item,
                    timelineAfter: continuation == .timeline ? cursor : nil,
                    checkAfter: continuation == .checks ? cursor : nil
                )
                guard !Task.isCancelled, let self, generation == detailsGeneration else { return }
                let merged = try ForgeReadDetailsMerger.merge(
                    next,
                    into: currentDetailsSnapshot,
                    continuation: continuation
                )
                self.currentDetailsSnapshot = merged
                inspectorController.apply(ForgeReadInspectorPresenter.present(
                    merged,
                    formatDate: Self.dateDescription
                ))
                logger.info("Appended Forge inspector continuation")
            } catch is CancellationError {
                self?.logger.debug("Cancelled Forge inspector continuation")
            } catch {
                guard let self, generation == detailsGeneration else { return }
                inspectorController.showContinuationError(error.localizedDescription)
                logger.error("Forge inspector continuation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func openRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        destinationRouter.openNative(destination: rows[index].destination)
    }

    private static func dateDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func timelineCursor(
        _ section: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) -> ForgePageCursor? {
        guard case let .available(page) = section else { return nil }
        return page.nextCursor
    }
}

@MainActor
private final class ForgeReadListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    var onReload: ((ForgeReadSurfaceQuery) -> Void)?
    var onLoadNextPage: (() -> Void)?
    var onSelectRow: ((Int) -> Void)?
    var onOpenRow: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let stateFilter = NSPopUpButton()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let freshnessLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let totalLabel = NSTextField(labelWithString: "")
    private var presentation = ForgeReadListPresentation(
        rows: [],
        statusMessage: nil,
        freshnessMessage: nil,
        isLoading: false,
        canLoadNextPage: false,
        totalDescription: nil
    )

    var query: ForgeReadSurfaceQuery {
        ForgeReadSurfaceQuery(
            searchText: searchField.stringValue,
            stateFilter: ForgeReadStateFilter(rawValue: stateFilter.selectedItem?.representedObject as? String ?? "") ?? .open
        )
    }

    init(kind: ForgeReadSurfaceKind) {
        super.init(nibName: nil, bundle: nil)
        configureView()
        setKind(kind)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setKind(_ kind: ForgeReadSurfaceKind) {
        titleLabel.stringValue = kind.displayName
        searchField.placeholderString = "Search \(kind.displayName)"
        tableView.setAccessibilityLabel(kind.displayName)
    }

    func apply(_ presentation: ForgeReadListPresentation) {
        self.presentation = presentation
        tableView.reloadData()
        statusLabel.stringValue = presentation.statusMessage ?? ""
        statusLabel.isHidden = presentation.statusMessage == nil
        freshnessLabel.stringValue = presentation.freshnessMessage ?? ""
        freshnessLabel.isHidden = presentation.freshnessMessage == nil
        freshnessLabel.textColor = presentation.freshnessMessage == nil ? .secondaryLabelColor : .systemOrange
        totalLabel.stringValue = presentation.totalDescription ?? ""
        progressIndicator.isHidden = !presentation.isLoading
        if presentation.isLoading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        refreshButton.isEnabled = !presentation.isLoading
        loadMoreButton.isHidden = !presentation.canLoadNextPage
        loadMoreButton.isEnabled = presentation.canLoadNextPage
    }

    func setVisibleColumns(_ columns: Set<ForgeReadSurfaceColumn>) {
        let effectiveColumns = columns.union([.title])
        for column in tableView.tableColumns {
            guard let value = ForgeReadSurfaceColumn(rawValue: column.identifier.rawValue) else { continue }
            column.isHidden = !effectiveColumns.contains(value)
        }
        tableView.sizeLastColumnToFit()
    }

    func numberOfRows(in _: NSTableView) -> Int {
        presentation.rows.count
    }

    func tableViewSelectionDidChange(_: Notification) {
        onSelectRow?(tableView.selectedRow)
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        presentation.rows.indices.contains(row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presentation.rows.indices.contains(row), let tableColumn else { return nil }
        let value = presentation.rows[row]
        let identifier = NSUserInterfaceItemIdentifier("ForgeReadCell.\(tableColumn.identifier.rawValue)")
        let cell: NSTableCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let text: String
        switch tableColumn.identifier.rawValue {
        case "state":
            text = value.state
            cell.textField?.textColor = Self.color(for: value.state)
            cell.textField?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        case "number":
            text = value.number
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        case "author":
            text = value.author
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        case "updated":
            text = Self.shortDate(value.updatedAt)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        default:
            text = value.labels.isEmpty ? value.title : "\(value.title)  [\(value.labels.joined(separator: ", "))]"
            cell.textField?.textColor = .labelColor
            cell.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
        cell.textField?.stringValue = text
        cell.setAccessibilityLabel(value.accessibilityLabel)
        return cell
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        onReload?(query)
    }

    private func configureView() {
        let root = NSView()
        root.setAccessibilityIdentifier("ForgeReadList")
        view = root

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("ForgeReadListTitle")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(search(_:))
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityIdentifier("ForgeReadSearch")

        stateFilter.removeAllItems()
        for filter in ForgeReadStateFilter.allCases {
            stateFilter.addItem(withTitle: filter.displayName)
            stateFilter.lastItem?.representedObject = filter.rawValue
        }
        stateFilter.selectItem(at: 0)
        stateFilter.target = self
        stateFilter.action = #selector(filterChanged(_:))
        stateFilter.setAccessibilityIdentifier("ForgeReadStateFilter")

        let header = ForgeReadSnowLeopardBarView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for subview in [titleLabel, searchField, stateFilter] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }

        let columns: [(String, String, CGFloat)] = [
            ("state", "State", 74),
            ("number", "Number", 66),
            ("title", "Title", 260),
            ("author", "Author", 120),
            ("updated", "Updated", 112),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "title" ? 160 : 56
            column.resizingMask = identifier == "title" ? .autoresizingMask : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .sourceList
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.target = self
        tableView.setAccessibilityIdentifier("ForgeReadTable")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("ForgeReadStatus")
        freshnessLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        freshnessLabel.setAccessibilityIdentifier("ForgeReadFreshness")
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        totalLabel.setAccessibilityIdentifier("ForgeReadTotal")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityIdentifier("ForgeReadProgress")
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.setAccessibilityIdentifier("ForgeReadRefresh")
        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore(_:))
        loadMoreButton.setAccessibilityIdentifier("ForgeReadLoadMore")

        let footerSpacer = NSView()
        let footer = NSStackView(views: [freshnessLabel, totalLabel, footerSpacer, progressIndicator, refreshButton, loadMoreButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false

        for child in [header, scrollView, statusLabel, footer] {
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stateFilter.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            stateFilter.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            stateFilter.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])
        apply(presentation)
    }

    @objc private func search(_: Any?) {
        onReload?(query)
    }

    @objc private func filterChanged(_: Any?) {
        onReload?(query)
    }

    @objc private func refresh(_: Any?) {
        onReload?(query)
    }

    @objc private func loadMore(_: Any?) {
        onLoadNextPage?()
    }

    @objc private func openSelected(_: Any?) {
        guard tableView.selectedRow >= 0 else { return }
        onOpenRow?(tableView.selectedRow)
    }

    private static func color(for state: String) -> NSColor {
        switch state {
        case "Open": .systemGreen
        case "Merged": .systemPurple
        case "Draft": .secondaryLabelColor
        default: .systemRed
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

@MainActor
private final class ForgeReadInspectorViewController: NSViewController {
    var onLoadMoreTimeline: (() -> Void)?
    var onLoadMoreChecks: (() -> Void)?

    private let markdownRenderer: any ForgeReadMarkdownRendering
    private let avatarRenderer: any ForgeReadAvatarRendering
    private let destinationRouter: any ForgeReadDestinationRouting
    private let defaultRevision: ForgeRevision
    private let contentStack = NSStackView()
    private var routedDestination: ForgeDestination?
    private var continuationButtons: [NSButton] = []
    private var continuationStatusView: NSView?

    init(
        markdownRenderer: any ForgeReadMarkdownRendering,
        avatarRenderer: any ForgeReadAvatarRendering,
        destinationRouter: any ForgeReadDestinationRouting,
        defaultRevision: ForgeRevision
    ) {
        self.markdownRenderer = markdownRenderer
        self.avatarRenderer = avatarRenderer
        self.destinationRouter = destinationRouter
        self.defaultRevision = defaultRevision
        super.init(nibName: nil, bundle: nil)
        configureView()
        showPlaceholder("Select an item to inspect it.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPlaceholder(_ message: String) {
        routedDestination = nil
        resetContent()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("ForgeInspectorPlaceholder")
        contentStack.addArrangedSubview(label)
    }

    func showLoading(for row: ForgeReadSurfaceRow) {
        routedDestination = row.destination
        resetContent()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.setAccessibilityIdentifier("ForgeInspectorProgress")
        let label = NSTextField(labelWithString: "Loading \(row.number)…")
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        contentStack.addArrangedSubview(stack)
    }

    func showError(_ message: String, item: ForgeRepositoryItem) {
        routedDestination = item.destination
        resetContent()
        let title = NSTextField(labelWithString: "Couldn’t load details")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.textColor = .secondaryLabelColor
        detail.setAccessibilityIdentifier("ForgeInspectorError")
        let browserButton = NSButton(title: "Open in Browser", target: self, action: #selector(openInBrowser(_:)))
        browserButton.bezelStyle = .rounded
        browserButton.setAccessibilityIdentifier("ForgeInspectorOpenInBrowser")
        contentStack.addArrangedSubview(title)
        contentStack.addArrangedSubview(detail)
        contentStack.addArrangedSubview(browserButton)
    }

    func apply(_ presentation: ForgeReadInspectorPresentation) {
        routedDestination = presentation.item.destination
        resetContent()

        let title = NSTextField(wrappingLabelWithString: presentation.title)
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.maximumNumberOfLines = 3
        title.setAccessibilityIdentifier("ForgeInspectorTitle")
        let subtitle = NSTextField(labelWithString: presentation.subtitle)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setAccessibilityIdentifier("ForgeInspectorSubtitle")
        let browserButton = NSButton(title: "Open in Browser", target: self, action: #selector(openInBrowser(_:)))
        browserButton.bezelStyle = .rounded
        browserButton.setAccessibilityIdentifier("ForgeInspectorOpenInBrowser")

        let avatar: NSView
        if let author = presentation.author {
            avatar = avatarRenderer.makeAvatarView(for: author, size: NSSize(width: 40, height: 40))
            avatar.setAccessibilityLabel("Avatar for \(author.displayName ?? author.login)")
        } else {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(
                systemSymbolName: "person.crop.circle",
                accessibilityDescription: "Author unavailable"
            )
            avatar = imageView
        }
        avatar.setAccessibilityIdentifier("ForgeInspectorAvatar")
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
        ])
        let headingText = NSStackView(views: [title, subtitle])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 2
        let heading = NSStackView(views: [avatar, headingText, NSView(), browserButton])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        contentStack.addArrangedSubview(heading)

        if let freshnessMessage = presentation.freshnessMessage {
            let freshness = banner(freshnessMessage, color: .systemOrange)
            freshness.setAccessibilityIdentifier("ForgeInspectorFreshness")
            contentStack.addArrangedSubview(freshness)
        }

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(sectionTitle("Details"))
        for entry in presentation.metadata {
            contentStack.addArrangedSubview(metadataRow(entry))
        }

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(sectionTitle("Description"))
        if let markdown = presentation.bodyMarkdown {
            let markdownView = markdownRenderer.makeView(
                markdown: markdown,
                context: ForgeMarkdownContext(
                    repository: presentation.item.repository,
                    location: .repository(defaultBranch: defaultRevision)
                )
            )
            markdownView.translatesAutoresizingMaskIntoConstraints = false
            markdownView.setAccessibilityIdentifier("ForgeInspectorBody")
            contentStack.addArrangedSubview(markdownView)
            NSLayoutConstraint.activate([
                markdownView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
                markdownView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            ])
        } else {
            let unavailable = NSTextField(wrappingLabelWithString: presentation.bodyUnavailableMessage ?? "No description")
            unavailable.textColor = .secondaryLabelColor
            unavailable.setAccessibilityIdentifier("ForgeInspectorBodyUnavailable")
            contentStack.addArrangedSubview(unavailable)
        }

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(sectionTitle("Timeline"))
        if let unavailable = presentation.timelineUnavailableMessage {
            let label = NSTextField(wrappingLabelWithString: unavailable)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityIdentifier("ForgeInspectorTimelineUnavailable")
            contentStack.addArrangedSubview(label)
        } else if presentation.timeline.isEmpty {
            let label = NSTextField(labelWithString: "No timeline activity")
            label.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(label)
        } else {
            for timeline in presentation.timeline {
                let view = timelineView(timeline, repository: presentation.item.repository)
                contentStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
            }
        }

        if presentation.nextTimelineCursor != nil {
            let button = NSButton(title: "Load More Timeline", target: self, action: #selector(loadMoreTimeline(_:)))
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("ForgeInspectorLoadMoreTimeline")
            continuationButtons.append(button)
            contentStack.addArrangedSubview(button)
        }
        if presentation.nextCheckCursor != nil {
            let button = NSButton(title: "Load More Checks", target: self, action: #selector(loadMoreChecks(_:)))
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("ForgeInspectorLoadMoreChecks")
            continuationButtons.append(button)
            contentStack.addArrangedSubview(button)
        }
    }

    func showContinuationLoading(_ continuation: ForgeReadDetailsContinuation) {
        clearContinuationStatus()
        continuationButtons.forEach { $0.isEnabled = false }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let description = continuation == .timeline ? "Loading more timeline…" : "Loading more checks…"
        let label = NSTextField(labelWithString: description)
        label.textColor = .secondaryLabelColor
        let status = NSStackView(views: [spinner, label])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8
        status.setAccessibilityIdentifier("ForgeInspectorContinuationProgress")
        continuationStatusView = status
        contentStack.addArrangedSubview(status)
    }

    func showContinuationError(_ message: String) {
        clearContinuationStatus()
        continuationButtons.forEach { $0.isEnabled = true }
        let status = banner("Couldn’t load more details. \(message)", color: .systemRed)
        status.setAccessibilityIdentifier("ForgeInspectorContinuationError")
        continuationStatusView = status
        contentStack.addArrangedSubview(status)
    }

    private func configureView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityIdentifier("ForgeInspector")

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 20, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scrollView.documentView = document
        view = scrollView

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func resetContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        continuationButtons.removeAll()
        continuationStatusView = nil
    }

    private func clearContinuationStatus() {
        guard let continuationStatusView else { return }
        contentStack.removeArrangedSubview(continuationStatusView)
        continuationStatusView.removeFromSuperview()
        self.continuationStatusView = nil
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func metadataRow(_ metadata: ForgeReadInspectorMetadata) -> NSView {
        let key = NSTextField(labelWithString: metadata.title)
        key.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        key.translatesAutoresizingMaskIntoConstraints = false
        key.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let value = NSTextField(wrappingLabelWithString: metadata.value)
        value.textColor = metadata.isUnavailable ? .tertiaryLabelColor : .labelColor
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [key, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.setAccessibilityLabel("\(metadata.title): \(metadata.value)")
        return row
    }

    private func timelineView(_ item: ForgeReadTimelinePresentation, repository: ForgeRepositoryIdentity) -> NSView {
        let title = NSTextField(wrappingLabelWithString: "\(item.actor) \(item.summary)")
        title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let date = NSTextField(labelWithString: Self.timelineDate(item.occurredAt))
        date.textColor = .secondaryLabelColor
        date.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let heading = NSStackView(views: [title, NSView(), date])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8
        let card = NSStackView(views: [heading])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 6
        card.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        card.wantsLayer = true
        card.layer?.cornerRadius = 5
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        card.setAccessibilityLabel("\(item.actor) \(item.summary), \(Self.timelineDate(item.occurredAt))")
        card.translatesAutoresizingMaskIntoConstraints = false
        if let markdown = item.markdown {
            let body = markdownRenderer.makeView(
                markdown: markdown,
                context: ForgeMarkdownContext(
                    repository: repository,
                    location: .repository(defaultBranch: defaultRevision)
                )
            )
            body.translatesAutoresizingMaskIntoConstraints = false
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            card.addArrangedSubview(body)
        }
        if let destination = item.destination {
            let button = ForgeReadDestinationButton(title: "View Referenced Item", destination: destination)
            button.target = self
            button.action = #selector(openTimelineDestination(_:))
            button.bezelStyle = .inline
            card.addArrangedSubview(button)
        }
        return card
    }

    private func banner(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = color
        label.drawsBackground = true
        label.backgroundColor = color.withAlphaComponent(0.08)
        label.isBezeled = true
        label.bezelStyle = .roundedBezel
        return label
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func openInBrowser(_: Any?) {
        guard let routedDestination else { return }
        destinationRouter.openInBrowser(destination: routedDestination)
    }

    @objc private func openTimelineDestination(_ sender: ForgeReadDestinationButton) {
        destinationRouter.openNative(destination: sender.destination)
    }

    @objc private func loadMoreTimeline(_: Any?) {
        onLoadMoreTimeline?()
    }

    @objc private func loadMoreChecks(_: Any?) {
        onLoadMoreChecks?()
    }

    private static func timelineDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

@MainActor
private final class ForgeReadDestinationButton: NSButton {
    let destination: ForgeDestination

    init(title: String, destination: ForgeDestination) {
        self.destination = destination
        super.init(frame: .zero)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ForgeReadSnowLeopardBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = isDark
            ? NSColor(calibratedWhite: 0.24, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        let bottom = isDark
            ? NSColor(calibratedWhite: 0.16, alpha: 1)
            : NSColor(calibratedWhite: 0.78, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }
}
