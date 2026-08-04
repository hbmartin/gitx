import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
final class ForgeAttentionViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAttentionSurface")

    private let session: any RepositoryAttentionServing
    private let destinationRouter: any ForgeReadDestinationRouting
    private let viewStateStore: (any RepositoryForgeViewStateStoring)?
    private let authorizationRecoveryHandler: ((Error, @escaping @MainActor () -> Void) -> Void)?
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading Attention…")
    private let progress = NSProgressIndicator()
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let visibilityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let columnsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let markUnseenButton = NSButton(title: "Mark Unseen", target: nil, action: nil)
    private let markAllSeenButton = NSButton(title: "Mark All Seen", target: nil, action: nil)
    private let inspectorController: ForgeReadInspectorViewController
    private var state: ForgeAttentionViewState
    private var repositoryViewState: RepositoryForgeAttentionViewState
    private var entries: [ForgeAttentionInboxEntry] = []
    private var rows: [ForgeAttentionReadSurfaceRow] = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt = 0
    private var detailsTask: Task<Void, Never>?
    private var currentRoute: ForgeAttentionInspectorRoute?
    private var currentDetails: ForgeReadSurfaceDetailsSnapshot?
    private var pendingItemID: ForgeAttentionItemID?
    private var isRestoringSelection = false

    init(
        session: any RepositoryAttentionServing,
        markdownRenderer: any ForgeReadMarkdownRendering,
        avatarRenderer: any ForgeReadAvatarRendering,
        destinationRouter: any ForgeReadDestinationRouting,
        defaultRevision: ForgeRevision,
        pullRequestChangesProvider: (any RepositoryPullRequestChangesProviding)? = nil,
        viewStateStore: (any RepositoryForgeViewStateStoring)? = nil,
        authorizationRecoveryHandler: ((Error, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.session = session
        self.destinationRouter = destinationRouter
        self.viewStateStore = viewStateStore
        self.authorizationRecoveryHandler = authorizationRecoveryHandler
        let storedState = viewStateStore?.forgeAttentionViewState
            ?? RepositoryForgeAttentionViewState(query: ApplicationSettings.attentionViewState)
        repositoryViewState = storedState
        state = storedState.query
        pendingItemID = storedState.selectedItemID
        inspectorController = ForgeReadInspectorViewController(
            markdownRenderer: markdownRenderer,
            avatarRenderer: avatarRenderer,
            destinationRouter: destinationRouter,
            defaultRevision: defaultRevision,
            pullRequestChangesProvider: pullRequestChangesProvider,
            initialMode: storedState.inspectorMode
        )
        super.init(nibName: nil, bundle: nil)
        configureList()
        inspectorController.onLoadMoreTimeline = { [weak self] in
            self?.loadMore(.timeline)
        }
        inspectorController.onLoadMoreChecks = { [weak self] in
            self?.loadMore(.checks)
        }
        inspectorController.onPullRequestModeChange = { [weak self] mode in
            self?.persistAttentionInspectorMode(mode)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inboxChanged(_:)),
            name: .forgeAttentionInboxDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateDefaultRevision(_ revision: ForgeRevision) {
        inspectorController.updateDefaultRevision(revision)
    }

    deinit {
        loadTask?.cancel()
        detailsTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
    }

    func refresh() {
        setLoading(true)
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.session.refreshNow()
            if let error = self.session.lastRefreshError {
                self.authorizationRecoveryHandler?(error) { [weak self] in
                    self?.refresh()
                }
            }
            self.reload()
        }
    }

    #if DEBUG
        func runAuthorizationRecoveryForProductProof(_ error: Error) {
            let retry: @MainActor @Sendable () -> Void = {}
            retry()
            authorizationRecoveryHandler?(error, retry)
        }
    #endif

    func open(_ itemID: ForgeAttentionItemID) {
        pendingItemID = itemID
        persistAttentionSelection(itemID)
        if state.scope != .all || state.visibility != .active {
            replaceState(scope: .all, visibility: .active)
        } else {
            reload()
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }
        let rowValue = rows[row]
        let value: String = switch identifier {
        case ForgeAttentionColumn.kind.rawValue:
            rowValue.isUnseen ? "●  \(rowValue.kindName)" : rowValue.kindName
        case ForgeAttentionColumn.repository.rawValue: rowValue.repositoryName
        case ForgeAttentionColumn.number.rawValue: rowValue.readRow.number
        case ForgeAttentionColumn.title.rawValue: rowValue.readRow.title
        case ForgeAttentionColumn.author.rawValue: rowValue.readRow.author
        case ForgeAttentionColumn.updated.rawValue: Self.shortDate(rowValue.readRow.updatedAt)
        default: ""
        }
        let cellIdentifier = NSUserInterfaceItemIdentifier("ForgeAttention.\(identifier).Cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTextField {
            field = reused
            field.stringValue = value
        } else {
            field = NSTextField(labelWithString: value)
            field.identifier = cellIdentifier
        }
        field.lineBreakMode = identifier == ForgeAttentionColumn.title.rawValue
            ? .byTruncatingTail
            : .byTruncatingMiddle
        field.font = rowValue.isUnseen
            ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = identifier == ForgeAttentionColumn.kind.rawValue && rowValue.isUnseen
            ? .controlAccentColor
            : .labelColor
        field.setAccessibilityLabel(rowValue.accessibilityLabel)
        field.setAccessibilityIdentifier("ForgeAttention.\(identifier).Cell")
        return field
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateActionState()
        guard !isRestoringSelection else { return }
        guard rows.indices.contains(tableView.selectedRow) else { return }
        Self.logger.info("Opening selected Attention item")
        openAndInspect(rows[tableView.selectedRow])
    }

    private func configureList() {
        let listController = NSViewController()
        let root = NSView()
        root.setAccessibilityIdentifier("ForgeAttentionSurface")

        let header = ForgeReadSnowLeopardBarView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Attention")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityIdentifier("ForgeAttentionTitle")

        scopePopup.addItems(withTitles: ["Current Repository", "All Watched Repositories"])
        scopePopup.selectItem(at: state.scope == .currentRepository ? 0 : 1)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.setAccessibilityIdentifier("ForgeAttentionScope")
        scopePopup.setAccessibilityLabel("Attention repository scope")
        visibilityPopup.addItems(withTitles: ["Unseen", "All Current"])
        visibilityPopup.selectItem(at: state.visibility == .unseenOnly ? 0 : 1)
        visibilityPopup.target = self
        visibilityPopup.action = #selector(visibilityChanged(_:))
        visibilityPopup.setAccessibilityIdentifier("ForgeAttentionVisibility")
        visibilityPopup.setAccessibilityLabel("Attention visibility")
        sortPopup.addItems(withTitles: ["Newest First", "Oldest First"])
        sortPopup.selectItem(at: state.sortOrder == .newestFirst ? 0 : 1)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        sortPopup.setAccessibilityIdentifier("ForgeAttentionSort")
        sortPopup.setAccessibilityLabel("Attention sort order")
        configureFilterMenus()

        let filters = NSStackView(views: [scopePopup, visibilityPopup, sortPopup, kindPopup, columnsPopup])
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 6
        filters.translatesAutoresizingMaskIntoConstraints = false
        for popup in [scopePopup, visibilityPopup, sortPopup, kindPopup, columnsPopup] {
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for (column, title, width) in [
            (ForgeAttentionColumn.kind, "Kind", 130.0),
            (.repository, "Repository", 155.0),
            (.number, "#", 55.0),
            (.title, "Title", 275.0),
            (.author, "Author", 120.0),
            (.updated, "Updated", 105.0),
        ] {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.isHidden = !state.columns.contains(column)
            tableView.addTableColumn(tableColumn)
        }
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(openSelectedDestination(_:))
        tableView.target = self
        tableView.setAccessibilityIdentifier("ForgeAttentionTable")
        tableView.setAccessibilityLabel("Attention Inbox")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("ForgeAttentionStatus")

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityIdentifier("ForgeAttentionProgress")
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked(_:)))
        refreshButton.bezelStyle = .rounded
        refreshButton.setAccessibilityIdentifier("ForgeAttentionRefresh")
        markUnseenButton.target = self
        markUnseenButton.action = #selector(markUnseen(_:))
        markUnseenButton.bezelStyle = .rounded
        markUnseenButton.setAccessibilityIdentifier("ForgeAttentionMarkUnseen")
        markAllSeenButton.target = self
        markAllSeenButton.action = #selector(markAllSeen(_:))
        markAllSeenButton.bezelStyle = .rounded
        markAllSeenButton.setAccessibilityIdentifier("ForgeAttentionMarkAllSeen")
        let footer = NSStackView(views: [progress, statusLabel, NSView(), refreshButton, markUnseenButton, markAllSeenButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false

        for child in [header, scroll, footer] {
            root.addSubview(child)
        }
        header.addSubview(title)
        header.addSubview(filters)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            filters.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            filters.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            filters.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
        ])
        scopePopup.nextKeyView = visibilityPopup
        visibilityPopup.nextKeyView = sortPopup
        sortPopup.nextKeyView = kindPopup
        kindPopup.nextKeyView = columnsPopup
        columnsPopup.nextKeyView = tableView
        tableView.nextKeyView = refreshButton
        refreshButton.nextKeyView = markUnseenButton
        markUnseenButton.nextKeyView = markAllSeenButton
        markAllSeenButton.nextKeyView = scopePopup
        listController.view = root
        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 450
        listItem.canCollapse = false
        addSplitViewItem(listItem)
        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = 320
        inspectorItem.preferredThicknessFraction = repositoryViewState.inspectorLayout.preferredFraction
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = repositoryViewState.inspectorLayout.isCollapsed
        addSplitViewItem(inspectorItem)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
        updateActionState()
    }

    private func configureFilterMenus() {
        kindPopup.removeAllItems()
        kindPopup.addItem(withTitle: "Kinds")
        kindPopup.item(at: 0)?.isEnabled = false
        for kind in ForgeAttentionKind.allCases {
            let item = NSMenuItem(
                title: Self.kindTitle(kind),
                action: #selector(toggleKind(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = kind.rawValue
            item.state = state.kinds.contains(kind) ? .on : .off
            let identifier = "ForgeAttentionKinds.\(kind.rawValue)"
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
            item.setAccessibilityLabel("Show \(Self.kindTitle(kind)) Attention items")
            kindPopup.menu?.addItem(item)
        }
        kindPopup.setAccessibilityIdentifier("ForgeAttentionKinds")
        kindPopup.setAccessibilityLabel("Visible Attention kinds")

        columnsPopup.removeAllItems()
        columnsPopup.addItem(withTitle: "Columns")
        columnsPopup.item(at: 0)?.isEnabled = false
        for column in ForgeAttentionColumn.allCases {
            let item = NSMenuItem(
                title: Self.columnTitle(column),
                action: #selector(toggleColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.rawValue
            item.state = state.columns.contains(column) ? .on : .off
            let identifier = "ForgeAttentionColumns.\(column.rawValue)"
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
            item.setAccessibilityLabel("\(Self.columnTitle(column)) column")
            columnsPopup.menu?.addItem(item)
        }
        columnsPopup.setAccessibilityIdentifier("ForgeAttentionColumns")
        columnsPopup.setAccessibilityLabel("Visible Attention columns")
    }

    private func reload() {
        Self.logger.info("Reloading Attention rows")
        setLoading(true)
        loadTask?.cancel()
        loadGeneration &+= 1
        let requestedGeneration = loadGeneration
        let requestedState = state
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loadGeneration == requestedGeneration {
                    self.setLoading(false)
                    self.updateActionState()
                }
            }
            do {
                let loaded = try await self.session.entries(state: requestedState)
                guard requestedGeneration == self.loadGeneration,
                      requestedState == self.state
                else { return }
                self.entries = loaded
                Self.logger.info("Loaded \(loaded.count) Attention entries")
                let presentation = ForgeAttentionReadSurfacePresenter.present(
                    entries: loaded,
                    query: ForgeAttentionInboxQuery(
                        accountID: self.session.account.id,
                        currentRepository: self.session.repositoryIdentity,
                        state: requestedState
                    )
                )
                self.rows = presentation.rows
                self.applyColumns(presentation.visibleColumns)
                self.tableView.reloadData()
                if let pendingItemID = self.pendingItemID,
                   let row = self.rows.firstIndex(where: { $0.itemID == pendingItemID })
                {
                    self.pendingItemID = nil
                    self.tableView.selectRowIndexes(
                        IndexSet(integer: row),
                        byExtendingSelection: false
                    )
                } else if let selectedItemID = self.currentRoute?.itemID,
                          let row = self.rows.firstIndex(where: { $0.itemID == selectedItemID })
                {
                    self.isRestoringSelection = true
                    self.tableView.selectRowIndexes(
                        IndexSet(integer: row),
                        byExtendingSelection: false
                    )
                    self.isRestoringSelection = false
                }
                if let error = self.session.lastRefreshErrorDescription {
                    self.statusLabel.stringValue = self.rows.isEmpty
                        ? "Offline or unavailable. \(error)"
                        : "Showing cached Attention. \(error)"
                    self.statusLabel.isHidden = false
                } else {
                    self.statusLabel.stringValue = presentation.statusMessage ?? ""
                    self.statusLabel.isHidden = presentation.statusMessage == nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard requestedGeneration == self.loadGeneration,
                      requestedState == self.state
                else { return }
                Self.logger.error("Attention rows failed to load type=\(String(describing: type(of: error)), privacy: .public)")
                self.rows = []
                self.entries = []
                self.tableView.reloadData()
                self.statusLabel.stringValue = "Couldn’t load Attention. \(error.localizedDescription)"
                self.statusLabel.isHidden = false
                self.authorizationRecoveryHandler?(error) { [weak self] in
                    self?.reload()
                }
            }
        }
    }

    private func openAndInspect(_ row: ForgeAttentionReadSurfaceRow) {
        guard let route = ForgeAttentionReadSurfacePresenter.inspectorRoute(
            for: row.itemID,
            in: entries
        ) else { return }
        currentRoute = route
        persistAttentionSelection(route.itemID)
        currentDetails = nil
        inspectorController.showLoading(for: row.readRow)
        detailsTask?.cancel()
        detailsTask = Task { [weak self] in
            guard let self else { return }
            do {
                Self.logger.info("Marking selected Attention item open")
                try await self.session.markOpen(route.itemID)
                Self.logger.info("Loading selected Attention inspector")
                let service = try self.session.makeReadService(for: route.repository)
                let snapshot = try await service.loadDetails(
                    for: route.item,
                    timelineAfter: nil,
                    checkAfter: nil
                )
                guard self.currentRoute == route else { return }
                self.currentDetails = snapshot
                Self.logger.info("Installed selected Attention inspector")
                self.inspectorController.apply(ForgeReadInspectorPresenter.present(
                    snapshot,
                    formatDate: Self.dateDescription
                ))
            } catch is CancellationError {
                return
            } catch {
                guard self.currentRoute == route else { return }
                self.inspectorController.showError(error.localizedDescription, item: route.item)
                self.authorizationRecoveryHandler?(error) { [weak self] in
                    self?.openAndInspect(row)
                }
            }
        }
    }

    private func loadMore(_ continuation: ForgeReadDetailsContinuation) {
        guard let route = currentRoute, let currentDetails else { return }
        let presentation = ForgeReadInspectorPresenter.present(
            currentDetails,
            formatDate: Self.dateDescription
        )
        let timeline = continuation == .timeline ? presentation.nextTimelineCursor : nil
        let checks = continuation == .checks ? presentation.nextCheckCursor : nil
        guard timeline != nil || checks != nil else { return }
        inspectorController.showContinuationLoading(continuation)
        detailsTask?.cancel()
        detailsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try self.session.makeReadService(for: route.repository)
                let next = try await service.loadDetails(
                    for: route.item,
                    timelineAfter: timeline,
                    checkAfter: checks
                )
                let merged = try ForgeReadDetailsMerger.merge(
                    next,
                    into: currentDetails,
                    continuation: continuation
                )
                guard self.currentRoute == route else { return }
                self.currentDetails = merged
                self.inspectorController.apply(ForgeReadInspectorPresenter.present(
                    merged,
                    formatDate: Self.dateDescription
                ))
            } catch is CancellationError {
                return
            } catch {
                guard self.currentRoute == route else { return }
                self.inspectorController.showContinuationError(error.localizedDescription)
                self.authorizationRecoveryHandler?(error) { [weak self] in
                    self?.loadMore(continuation)
                }
            }
        }
    }

    private func replaceState(
        scope: ForgeAttentionViewScope? = nil,
        visibility: ForgeAttentionVisibility? = nil,
        sortOrder: ForgeAttentionSortOrder? = nil,
        kinds: Set<ForgeAttentionKind>? = nil,
        columns: Set<ForgeAttentionColumn>? = nil
    ) {
        state = ForgeAttentionViewState(
            scope: scope ?? state.scope,
            visibility: visibility ?? state.visibility,
            sortOrder: sortOrder ?? state.sortOrder,
            kinds: kinds ?? state.kinds,
            columns: columns ?? state.columns
        )
        repositoryViewState = RepositoryForgeAttentionViewState(
            query: state,
            selectedItemID: repositoryViewState.selectedItemID,
            inspectorLayout: repositoryViewState.inspectorLayout,
            inspectorMode: repositoryViewState.inspectorMode
        )
        persistAttentionViewState()
        configureFilterMenus()
        reload()
    }

    private static func dateDescription(_ date: Date) -> String {
        ForgeReadDateFormatting.dateAndTime(date)
    }

    private func applyColumns(_ columns: Set<ForgeAttentionColumn>) {
        for tableColumn in tableView.tableColumns {
            guard let column = ForgeAttentionColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.isHidden = !columns.contains(column)
        }
    }

    private func setLoading(_ loading: Bool) {
        if loading {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func updateActionState() {
        let selected = rows.indices.contains(tableView.selectedRow)
        markUnseenButton.isEnabled = selected
        markAllSeenButton.isEnabled = !rows.isEmpty
    }

    private func persistAttentionSelection(_ itemID: ForgeAttentionItemID?) {
        guard repositoryViewState.selectedItemID != itemID else { return }
        repositoryViewState = RepositoryForgeAttentionViewState(
            query: state,
            selectedItemID: itemID,
            inspectorLayout: repositoryViewState.inspectorLayout,
            inspectorMode: repositoryViewState.inspectorMode
        )
        persistAttentionViewState()
    }

    private func persistAttentionViewState() {
        if let viewStateStore {
            viewStateStore.forgeAttentionViewState = repositoryViewState
        } else {
            ApplicationSettings.attentionViewState = repositoryViewState.query
        }
    }

    private func persistAttentionInspectorLayout() {
        guard splitViewItems.indices.contains(1) else { return }
        let item = splitViewItems[1]
        var fraction = repositoryViewState.inspectorLayout.preferredFraction
        if !item.isCollapsed, splitView.bounds.width > 0 {
            fraction = item.viewController.view.frame.width / splitView.bounds.width
        }
        let layout = RepositoryForgeInspectorLayoutState(
            preferredFraction: fraction,
            isCollapsed: item.isCollapsed
        )
        guard layout != repositoryViewState.inspectorLayout else { return }
        repositoryViewState = RepositoryForgeAttentionViewState(
            query: state,
            selectedItemID: repositoryViewState.selectedItemID,
            inspectorLayout: layout,
            inspectorMode: repositoryViewState.inspectorMode
        )
        persistAttentionViewState()
        Self.logger.debug("Saved Attention inspector collapsed=\(layout.isCollapsed, privacy: .public)")
    }

    private func persistAttentionInspectorMode(_ mode: RepositoryForgeInspectorMode) {
        guard repositoryViewState.inspectorMode != mode else { return }
        repositoryViewState = RepositoryForgeAttentionViewState(
            query: state,
            selectedItemID: repositoryViewState.selectedItemID,
            inspectorLayout: repositoryViewState.inspectorLayout,
            inspectorMode: mode
        )
        persistAttentionViewState()
        Self.logger.debug("Saved Attention inspector mode")
    }

    @objc private func splitViewDidResize(_: Notification) {
        persistAttentionInspectorLayout()
    }

    @objc private func inboxChanged(_: Notification) {
        reload()
    }

    @objc private func refreshClicked(_: Any?) {
        refresh()
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        replaceState(scope: sender.indexOfSelectedItem == 0 ? .currentRepository : .all)
    }

    @objc private func visibilityChanged(_ sender: NSPopUpButton) {
        replaceState(visibility: sender.indexOfSelectedItem == 0 ? .unseenOnly : .active)
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        replaceState(sortOrder: sender.indexOfSelectedItem == 0 ? .newestFirst : .oldestFirst)
    }

    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let kind = ForgeAttentionKind(rawValue: rawValue)
        else { return }
        var updated = state.kinds
        if updated.remove(kind) == nil {
            updated.insert(kind)
        }
        replaceState(kinds: updated)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let column = ForgeAttentionColumn(rawValue: rawValue)
        else { return }
        var updated = state.columns
        if updated.remove(column) == nil {
            updated.insert(column)
        }
        if updated.isEmpty {
            updated.insert(.title)
        }
        replaceState(columns: updated)
    }

    @objc private func markUnseen(_: Any?) {
        guard rows.indices.contains(tableView.selectedRow) else { return }
        let itemID = rows[tableView.selectedRow].itemID
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.markUnseen(itemID)
                self.reload()
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                self.statusLabel.isHidden = false
            }
        }
    }

    @objc private func markAllSeen(_: Any?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.markAllSeen(state: self.state)
                self.reload()
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
                self.statusLabel.isHidden = false
            }
        }
    }

    @objc private func openSelectedDestination(_: Any?) {
        guard rows.indices.contains(tableView.selectedRow) else { return }
        destinationRouter.openNative(destination: rows[tableView.selectedRow].readRow.destination)
    }

    private static func shortDate(_ date: Date) -> String {
        ForgeReadDateFormatting.date(date)
    }

    private static func kindTitle(_ kind: ForgeAttentionKind) -> String {
        switch kind {
        case .reviewRequest: "Review Requests"
        case .mention: "Mentions"
        case .reply: "Replies"
        case .assignment: "Assignments"
        case .failedCheck: "Failed Checks"
        }
    }

    private static func columnTitle(_ column: ForgeAttentionColumn) -> String {
        switch column {
        case .kind: "Kind"
        case .repository: "Repository"
        case .number: "Number"
        case .title: "Title"
        case .author: "Author"
        case .updated: "Updated"
        }
    }
}
