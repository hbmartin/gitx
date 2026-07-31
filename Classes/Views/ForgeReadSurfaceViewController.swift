import AppKit
import ForgeKit
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import
import UserNotifications

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

/// Bridge between the local-diff authority and native review UI. The review
/// implementation owns its overlay views and reports only an explicitly chosen
/// local anchor; the read renderer never infers or rewrites server anchors.
@MainActor
protocol RepositoryPullRequestReviewOverlayHosting: AnyObject {
    /// Returns the reusable lifecycle/review action area for both inspector modes.
    func actionView(for pullRequest: ForgePullRequestSummary) -> NSView

    func install(
        in nativeDiffView: PBNativeContentView,
        pullRequest: ForgePullRequestSummary,
        diff: RepositoryLocalPullRequestDiff
    )

    func refresh()

    func failClosedAfterRepositoryRefresh(_ message: String)

    func detach()
}

@MainActor
final class ForgeReadSurfaceViewController: NSSplitViewController {
    private let service: any ForgeReadSurfaceServing
    private let markdownRenderer: any ForgeReadMarkdownRendering
    private let avatarRenderer: any ForgeReadAvatarRendering
    private let destinationRouter: any ForgeReadDestinationRouting
    private let reviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)?
    private let defaultRevision: ForgeRevision
    private let viewStateStore: (any RepositoryForgeViewStateStoring)?
    private let listController: ForgeReadListViewController
    private let inspectorController: ForgeReadInspectorViewController
    private var accumulator: ForgeReadSurfaceAccumulator
    private var surfaceViewState: RepositoryForgeReadSurfaceViewState
    private var surfaceViewStateKind: ForgeReadSurfaceKind
    private var rows: [ForgeReadSurfaceRow] = []
    private var listTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var currentDetailsSnapshot: ForgeReadSurfaceDetailsSnapshot?
    private var selectedItem: ForgeRepositoryItem?
    private var pendingDestination: ForgeDestination?
    private var detailsGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeReadSurface")

    init(
        kind: ForgeReadSurfaceKind,
        defaultRevision: ForgeRevision,
        service: any ForgeReadSurfaceServing,
        markdownRenderer: any ForgeReadMarkdownRendering,
        avatarRenderer: any ForgeReadAvatarRendering,
        destinationRouter: any ForgeReadDestinationRouting,
        pullRequestChangesProvider: (any RepositoryPullRequestChangesProviding)? = nil,
        reviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)? = nil,
        viewStateStore: (any RepositoryForgeViewStateStoring)? = nil,
        editPullRequestControl: ForgeMutationControlPresentation? = nil,
        onEditPullRequest: ((ForgePullRequestEditableSnapshot, ForgeDestination) -> Void)? = nil,
        onCheckoutPullRequest: ((ForgePullRequestSummary) -> Void)? = nil
    ) {
        self.service = service
        self.markdownRenderer = markdownRenderer
        self.avatarRenderer = avatarRenderer
        self.destinationRouter = destinationRouter
        self.reviewOverlayHost = reviewOverlayHost
        self.defaultRevision = defaultRevision
        self.viewStateStore = viewStateStore
        let initialViewState = viewStateStore?.forgeReadSurfaceViewState(for: kind).validated(for: kind)
            ?? .defaultValue
        surfaceViewState = initialViewState
        surfaceViewStateKind = kind
        accumulator = ForgeReadSurfaceAccumulator(kind: kind, query: initialViewState.query)
        listController = ForgeReadListViewController(kind: kind)
        inspectorController = ForgeReadInspectorViewController(
            markdownRenderer: markdownRenderer,
            avatarRenderer: avatarRenderer,
            destinationRouter: destinationRouter,
            defaultRevision: defaultRevision,
            pullRequestChangesProvider: pullRequestChangesProvider,
            reviewOverlayHost: reviewOverlayHost,
            initialMode: initialViewState.inspectorMode
        )
        super.init(nibName: nil, bundle: nil)
        pendingDestination = initialViewState.selectedDestination

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
        listController.onVisibleColumnsChange = { [weak self] columns in
            self?.persistVisibleColumns(columns)
        }
        listController.apply(viewState: initialViewState)
        inspectorController.onLoadMoreTimeline = { [weak self] in
            self?.loadMoreDetails(.timeline)
        }
        inspectorController.onLoadMoreChecks = { [weak self] in
            self?.loadMoreDetails(.checks)
        }
        inspectorController.onPullRequestModeChange = { [weak self] mode in
            self?.persistInspectorMode(mode)
        }
        inspectorController.editPullRequestControl = editPullRequestControl ?? .hidden
        inspectorController.onEditPullRequest = onEditPullRequest
        inspectorController.onCheckoutPullRequest = onCheckoutPullRequest

        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 420
        listItem.canCollapse = false
        addSplitViewItem(listItem)

        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = 320
        inspectorItem.preferredThicknessFraction = initialViewState.inspectorLayout.preferredFraction
        inspectorItem.canCollapse = true
        inspectorItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        inspectorItem.isCollapsed = initialViewState.inspectorLayout.isCollapsed
        addSplitViewItem(inspectorItem)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        view.setAccessibilityIdentifier("ForgeReadSurface")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        listTask?.cancel()
        detailsTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard accumulator.fetchedAt == nil, accumulator.activeRequest == nil else { return }
        reload(query: listController.query)
    }

    func show(kind: ForgeReadSurfaceKind) {
        guard kind != accumulator.kind else { return }
        persistInspectorLayout()
        surfaceViewState = viewStateStore?.forgeReadSurfaceViewState(for: kind).validated(for: kind)
            ?? .defaultValue
        surfaceViewStateKind = kind
        listController.setKind(kind)
        listController.apply(viewState: surfaceViewState)
        pendingDestination = surfaceViewState.selectedDestination
        applyInspectorLayout(surfaceViewState.inspectorLayout)
        inspectorController.setPullRequestMode(surfaceViewState.inspectorMode)
        reload(kind: kind, query: surfaceViewState.query)
        inspectorController.showPlaceholder("Select a \(kind == .pullRequests ? "pull request" : "issue") to inspect it.")
    }

    func refresh() {
        reload(query: listController.query)
    }

    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
    func setVisibleColumns(_ columns: Set<ForgeReadSurfaceColumn>) {
        listController.setVisibleColumns(columns)
    }

    func updateEditPullRequestControl(
        _ presentation: ForgeMutationControlPresentation,
        handler: ((ForgePullRequestEditableSnapshot, ForgeDestination) -> Void)?
    ) {
        inspectorController.editPullRequestControl = presentation
        inspectorController.onEditPullRequest = handler
        if let currentDetailsSnapshot {
            inspectorController.apply(ForgeReadInspectorPresenter.present(
                currentDetailsSnapshot,
                formatDate: Self.dateDescription
            ))
        }
    }

    #if DEBUG
        func runProductProofDiagnostics(_ presentation: ForgeReadInspectorPresentation) async -> Bool {
            listController.runProductProofEndEditing()
            let localChangesError = await inspectorController.runProductProofLocalChanges(presentation)
            selectRow(-1)
            openRow(-1)
            return localChangesError
                && !Self.dateDescription(Date(timeIntervalSince1970: 1_700_200_200)).isEmpty
        }
    #endif

    @discardableResult
    func open(destination: ForgeDestination) -> Bool {
        let matchesKind = switch (accumulator.kind, destination) {
        case (.pullRequests, .pullRequest), (.issues, .issue): true
        default: false
        }
        guard matchesKind else { return false }
        persistSelection(destination)
        guard let row = rows.firstIndex(where: { $0.destination == destination }) else {
            pendingDestination = destination
            return true
        }
        pendingDestination = nil
        listController.select(row: row)
        return true
    }

    private func reload(kind: ForgeReadSurfaceKind? = nil, query: ForgeReadSurfaceQuery) {
        listTask?.cancel()
        let changesKind = (kind ?? accumulator.kind) != accumulator.kind
        let invalidatesSelection = changesKind || query != accumulator.query
        if invalidatesSelection {
            if !changesKind {
                persistQuery(query, clearingSelection: true)
            }
            listController.restoreSelection(row: nil)
            selectedItem = nil
            detailsTask?.cancel()
            currentDetailsSnapshot = nil
            detailsGeneration &+= 1
            inspectorController.showPlaceholder("Select an item to inspect it.")
        }
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
                    let resolvedPendingDestination = renderList()
                    if !resolvedPendingDestination {
                        refreshSelectedInspectorAfterReload()
                    }
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
                    if !invalidatesSelection {
                        retainSelectedInspectorAfterRefreshFailure(error.localizedDescription)
                    }
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
                    reconcileSelectedInspectorAfterPagination()
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

    @discardableResult
    private func renderList() -> Bool {
        let presentation = accumulator.presentation(formatDate: Self.dateDescription)
        rows = presentation.rows
        listController.apply(presentation)
        if let pendingDestination,
           let row = rows.firstIndex(where: { $0.destination == pendingDestination })
        {
            self.pendingDestination = nil
            listController.select(row: row)
            return true
        }
        let selectedRow = selectedItem.flatMap { selected in
            rows.firstIndex(where: { $0.destination == selected.destination })
        }
        listController.restoreSelection(row: selectedRow)
        return false
    }

    private func selectRow(_ index: Int) {
        guard rows.indices.contains(index) else {
            selectedItem = nil
            persistSelection(nil)
            detailsTask?.cancel()
            currentDetailsSnapshot = nil
            detailsGeneration &+= 1
            inspectorController.showPlaceholder("Select an item to inspect it.")
            return
        }
        let item = rows[index].item
        selectedItem = item
        persistSelection(item.destination)
        loadDetails(for: item, rowNumber: rows[index].number, preservingCurrentSnapshot: false)
    }

    private func loadDetails(
        for item: ForgeRepositoryItem,
        rowNumber: String,
        preservingCurrentSnapshot: Bool
    ) {
        detailsTask?.cancel()
        if !preservingCurrentSnapshot {
            currentDetailsSnapshot = nil
            inspectorController.showLoading(for: ForgeReadSurfaceRow(item: item))
        }
        detailsGeneration &+= 1
        let generation = detailsGeneration
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
                    if !retainStaleDetailsAfterRefreshFailure(
                        "GitHub returned details for a different item.",
                        item: item,
                        preservingCurrentSnapshot: preservingCurrentSnapshot
                    ) {
                        inspectorController.showError("GitHub returned details for a different item.", item: item)
                    }
                    return
                }
                let presentation = ForgeReadInspectorPresenter.present(
                    snapshot,
                    formatDate: Self.dateDescription
                )
                currentDetailsSnapshot = snapshot
                selectedItem = snapshot.details.item
                inspectorController.apply(presentation)
                logger.info("Installed Forge inspector details")
            } catch is CancellationError {
                self?.logger.debug("Cancelled Forge inspector request")
            } catch {
                guard let self, generation == detailsGeneration else { return }
                logger.error("Forge inspector load failed: \(error.localizedDescription, privacy: .public)")
                if !retainStaleDetailsAfterRefreshFailure(
                    error.localizedDescription,
                    item: item,
                    preservingCurrentSnapshot: preservingCurrentSnapshot
                ) {
                    inspectorController.showError(error.localizedDescription, item: item)
                }
            }
        }
    }

    private func retainStaleDetailsAfterRefreshFailure(
        _ message: String,
        item: ForgeRepositoryItem,
        preservingCurrentSnapshot: Bool,
        markingPartial: Bool = false
    ) -> Bool {
        guard preservingCurrentSnapshot,
              let currentDetailsSnapshot,
              currentDetailsSnapshot.details.item.destination == item.destination
        else { return false }
        let staleSnapshot = ForgeReadSurfaceDetailsSnapshot(
            details: currentDetailsSnapshot.details,
            fetchedAt: currentDetailsSnapshot.fetchedAt,
            isStale: true,
            isPartial: currentDetailsSnapshot.isPartial || markingPartial
        )
        self.currentDetailsSnapshot = staleSnapshot
        let stalePresentation = ForgeReadInspectorPresenter.present(
            staleSnapshot,
            formatDate: Self.dateDescription
        )
        inspectorController.apply(stalePresentation)
        inspectorController.showRefreshError(
            message,
            freshnessMessage: stalePresentation.freshnessMessage
        )
        if case .pullRequest = item {
            reviewOverlayHost?.failClosedAfterRepositoryRefresh(message)
        }
        logger.info("Retained explicitly stale Forge inspector details after refresh failure")
        return true
    }

    @discardableResult
    private func retainSelectedInspectorAfterPartialReload(_ item: ForgeRepositoryItem) -> Bool {
        let message = "The refreshed list was incomplete, so the selected item could not be verified."
        let retained = retainStaleDetailsAfterRefreshFailure(
            message,
            item: item,
            preservingCurrentSnapshot: true,
            markingPartial: true
        )
        if retained {
            logger.info("Retained selected Forge inspector because a partial list cannot prove absence")
        }
        return retained
    }

    private func retainSelectedInspectorAfterRefreshFailure(_ message: String) {
        guard let selectedItem else { return }
        _ = retainStaleDetailsAfterRefreshFailure(
            message,
            item: selectedItem,
            preservingCurrentSnapshot: true
        )
    }

    private func refreshSelectedInspectorAfterReload() {
        guard var item = selectedItem else { return }
        let row = rows.firstIndex(where: { $0.destination == item.destination })
        if let row {
            item = rows[row].item
            selectedItem = item
            listController.restoreSelection(row: row)
        } else {
            listController.restoreSelection(row: nil)
            if accumulator.isPartial {
                if !retainSelectedInspectorAfterPartialReload(item) {
                    loadDetails(
                        for: item,
                        rowNumber: ForgeReadSurfaceRow(item: item).number,
                        preservingCurrentSnapshot: false
                    )
                }
                return
            }
            guard accumulator.nextCursor != nil else {
                selectRow(-1)
                logger.info("Cleared Forge inspector because the selected item is no longer in the refreshed list")
                return
            }
            logger.info("Preserving the selected Forge inspector while its item is beyond the refreshed first page")
        }
        if case .pullRequest = item {
            reviewOverlayHost?.refresh()
        }
        loadDetails(
            for: item,
            rowNumber: ForgeReadSurfaceRow(item: item).number,
            preservingCurrentSnapshot: true
        )
        logger.info("Refreshing Forge inspector after the selected item list reloaded")
    }

    private func reconcileSelectedInspectorAfterPagination() {
        guard let selectedItem else { return }
        if let row = rows.firstIndex(where: { $0.destination == selectedItem.destination }) {
            self.selectedItem = rows[row].item
            listController.restoreSelection(row: row)
            logger.info("Restored selected Forge item after loading another list page")
        } else if accumulator.nextCursor == nil {
            if accumulator.isPartial {
                listController.restoreSelection(row: nil)
                _ = retainSelectedInspectorAfterPartialReload(selectedItem)
            } else {
                selectRow(-1)
                logger.info("Cleared Forge inspector after the final list page omitted the selected item")
            }
        } else {
            listController.restoreSelection(row: nil)
            logger.info("Preserving selected Forge inspector while more list pages remain")
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

    private func persistQuery(_ query: ForgeReadSurfaceQuery, clearingSelection: Bool) {
        surfaceViewState = RepositoryForgeReadSurfaceViewState(
            searchText: query.searchText,
            stateFilter: query.stateFilter,
            visibleColumns: surfaceViewState.visibleColumns,
            selectedDestination: clearingSelection ? nil : surfaceViewState.selectedDestination,
            inspectorLayout: surfaceViewState.inspectorLayout,
            inspectorMode: surfaceViewState.inspectorMode
        )
        saveSurfaceViewState()
    }

    private func persistVisibleColumns(_ columns: Set<ForgeReadSurfaceColumn>) {
        surfaceViewState = RepositoryForgeReadSurfaceViewState(
            searchText: surfaceViewState.searchText,
            stateFilter: surfaceViewState.stateFilter,
            visibleColumns: columns,
            selectedDestination: surfaceViewState.selectedDestination,
            inspectorLayout: surfaceViewState.inspectorLayout,
            inspectorMode: surfaceViewState.inspectorMode
        )
        saveSurfaceViewState()
        let kind = surfaceViewStateKind.rawValue
        logger.debug("Saved user-configured \(kind, privacy: .public) columns")
    }

    private func persistSelection(_ destination: ForgeDestination?) {
        guard surfaceViewState.selectedDestination != destination else { return }
        surfaceViewState = RepositoryForgeReadSurfaceViewState(
            searchText: surfaceViewState.searchText,
            stateFilter: surfaceViewState.stateFilter,
            visibleColumns: surfaceViewState.visibleColumns,
            selectedDestination: destination,
            inspectorLayout: surfaceViewState.inspectorLayout,
            inspectorMode: surfaceViewState.inspectorMode
        )
        saveSurfaceViewState()
    }

    private func persistInspectorLayout() {
        guard splitViewItems.indices.contains(1) else { return }
        let item = splitViewItems[1]
        var fraction = surfaceViewState.inspectorLayout.preferredFraction
        if !item.isCollapsed, splitView.bounds.width > 0 {
            fraction = item.viewController.view.frame.width / splitView.bounds.width
        }
        let layout = RepositoryForgeInspectorLayoutState(
            preferredFraction: fraction,
            isCollapsed: item.isCollapsed
        )
        guard layout != surfaceViewState.inspectorLayout else { return }
        surfaceViewState = RepositoryForgeReadSurfaceViewState(
            searchText: surfaceViewState.searchText,
            stateFilter: surfaceViewState.stateFilter,
            visibleColumns: surfaceViewState.visibleColumns,
            selectedDestination: surfaceViewState.selectedDestination,
            inspectorLayout: layout,
            inspectorMode: surfaceViewState.inspectorMode
        )
        saveSurfaceViewState()
        let kind = surfaceViewStateKind.rawValue
        logger.debug(
            "Saved \(kind, privacy: .public) inspector collapsed=\(layout.isCollapsed, privacy: .public)"
        )
    }

    private func applyInspectorLayout(_ layout: RepositoryForgeInspectorLayoutState) {
        guard splitViewItems.indices.contains(1) else { return }
        let item = splitViewItems[1]
        item.preferredThicknessFraction = layout.preferredFraction
        item.isCollapsed = layout.isCollapsed
    }

    private func persistInspectorMode(_ mode: RepositoryForgeInspectorMode) {
        guard mode != surfaceViewState.inspectorMode else { return }
        surfaceViewState = RepositoryForgeReadSurfaceViewState(
            searchText: surfaceViewState.searchText,
            stateFilter: surfaceViewState.stateFilter,
            visibleColumns: surfaceViewState.visibleColumns,
            selectedDestination: surfaceViewState.selectedDestination,
            inspectorLayout: surfaceViewState.inspectorLayout,
            inspectorMode: mode
        )
        saveSurfaceViewState()
        let kind = surfaceViewStateKind.rawValue
        logger.debug("Saved \(kind, privacy: .public) inspector mode")
    }

    private func saveSurfaceViewState() {
        viewStateStore?.setForgeReadSurfaceViewState(surfaceViewState, for: surfaceViewStateKind)
    }

    @objc private func splitViewDidResize(_: Notification) {
        persistInspectorLayout()
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
    var onVisibleColumnsChange: ((Set<ForgeReadSurfaceColumn>) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let stateFilter = NSPopUpButton()
    private let columnsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let freshnessLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let totalLabel = NSTextField(labelWithString: "")
    private var suppressesSelectionChanges = false
    private var visibleColumns = Set(ForgeReadSurfaceColumn.allCases)
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

    func apply(viewState: RepositoryForgeReadSurfaceViewState) {
        searchField.stringValue = viewState.searchText
        if let item = stateFilter.itemArray.first(where: {
            $0.representedObject as? String == viewState.stateFilter.rawValue
        }) {
            stateFilter.select(item)
        }
        setVisibleColumns(viewState.visibleColumns, notifyingChange: false)
    }

    func apply(_ presentation: ForgeReadListPresentation) {
        self.presentation = presentation
        suppressesSelectionChanges = true
        tableView.reloadData()
        suppressesSelectionChanges = false
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

    func setVisibleColumns(
        _ columns: Set<ForgeReadSurfaceColumn>,
        notifyingChange: Bool = true
    ) {
        let effectiveColumns = columns.union([.title])
        visibleColumns = effectiveColumns
        for column in tableView.tableColumns {
            guard let value = ForgeReadSurfaceColumn(rawValue: column.identifier.rawValue) else { continue }
            column.isHidden = !effectiveColumns.contains(value)
        }
        configureColumnsMenu()
        tableView.sizeLastColumnToFit()
        if notifyingChange {
            onVisibleColumnsChange?(effectiveColumns)
        }
    }

    func select(row: Int) {
        guard presentation.rows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func restoreSelection(row: Int?) {
        suppressesSelectionChanges = true
        if let row, presentation.rows.indices.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        suppressesSelectionChanges = false
    }

    func numberOfRows(in _: NSTableView) -> Int {
        presentation.rows.count
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !suppressesSelectionChanges else { return }
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

    @inline(never)
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        onReload?(query)
    }

    #if DEBUG
        func runProductProofEndEditing() {
            controlTextDidEndEditing(Notification(
                name: NSControl.textDidEndEditingNotification,
                object: searchField
            ))
        }
    #endif

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
        stateFilter.setAccessibilityLabel("Pull request or issue state")

        columnsPopup.bezelStyle = .texturedRounded
        columnsPopup.setAccessibilityIdentifier("ForgeReadColumns")
        columnsPopup.setAccessibilityLabel("Visible list columns")
        configureColumnsMenu()

        let header = ForgeReadSnowLeopardBarView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for subview in [titleLabel, searchField, stateFilter, columnsPopup] {
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
        let searchMinimumWidth = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        searchMinimumWidth.priority = .defaultHigh
        let columnsMinimumWidth = columnsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 82)
        columnsMinimumWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
            searchMinimumWidth,
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stateFilter.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            columnsPopup.leadingAnchor.constraint(equalTo: stateFilter.trailingAnchor, constant: 6),
            columnsPopup.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            columnsMinimumWidth,
            stateFilter.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            columnsPopup.centerYAnchor.constraint(equalTo: header.centerYAnchor),
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
        searchField.nextKeyView = stateFilter
        stateFilter.nextKeyView = columnsPopup
        columnsPopup.nextKeyView = tableView
        tableView.nextKeyView = refreshButton
        refreshButton.nextKeyView = loadMoreButton
        loadMoreButton.nextKeyView = searchField
        apply(presentation)
    }

    @objc private func search(_: Any?) {
        onReload?(query)
    }

    @objc private func filterChanged(_: Any?) {
        onReload?(query)
    }

    private func configureColumnsMenu() {
        columnsPopup.removeAllItems()
        columnsPopup.addItem(withTitle: "Columns")
        columnsPopup.item(at: 0)?.isEnabled = false
        for column in ForgeReadSurfaceColumn.allCases {
            let item = NSMenuItem(
                title: Self.columnTitle(column),
                action: #selector(toggleColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.rawValue
            item.state = visibleColumns.contains(column) ? .on : .off
            item.isEnabled = column != .title
            let identifier = "ForgeReadColumns.\(column.rawValue)"
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
            item.setAccessibilityLabel("\(Self.columnTitle(column)) column")
            columnsPopup.menu?.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let column = ForgeReadSurfaceColumn(rawValue: rawValue),
              column != .title
        else { return }
        var updated = visibleColumns
        if updated.contains(column) {
            updated.remove(column)
        } else {
            updated.insert(column)
        }
        setVisibleColumns(updated)
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

    private static func columnTitle(_ column: ForgeReadSurfaceColumn) -> String {
        switch column {
        case .state: "State"
        case .number: "Number"
        case .title: "Title"
        case .author: "Author"
        case .updated: "Updated"
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
final class ForgeReadInspectorViewController: NSViewController {
    var onLoadMoreTimeline: (() -> Void)?
    var onLoadMoreChecks: (() -> Void)?
    var onPullRequestModeChange: ((RepositoryForgeInspectorMode) -> Void)?
    var onEditPullRequest: ((ForgePullRequestEditableSnapshot, ForgeDestination) -> Void)?
    var onCheckoutPullRequest: ((ForgePullRequestSummary) -> Void)?
    var editPullRequestControl = ForgeMutationControlPresentation.hidden

    private let markdownRenderer: any ForgeReadMarkdownRendering
    private let avatarRenderer: any ForgeReadAvatarRendering
    private let destinationRouter: any ForgeReadDestinationRouting
    private let defaultRevision: ForgeRevision
    private var pullRequestChangesProvider: (any RepositoryPullRequestChangesProviding)?
    private let reviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)?
    private let contentStack = NSStackView()
    private var routedDestination: ForgeDestination?
    private var continuationButtons: [NSButton] = []
    private var continuationStatusView: NSView?
    private var refreshFailureView: NSView?
    private var refreshFailureMessage: String?
    private weak var freshnessView: NSTextField?
    private var pullRequestModeControl: NSSegmentedControl?
    private var currentPresentation: ForgeReadInspectorPresentation?
    private var changesTask: Task<Void, Never>?
    private var pullRequestMode: RepositoryForgeInspectorMode
    private var editablePullRequestSnapshot: ForgePullRequestEditableSnapshot?
    private weak var editPullRequestButton: NSButton?
    private var currentPullRequestSummary: ForgePullRequestSummary?

    init(
        markdownRenderer: any ForgeReadMarkdownRendering,
        avatarRenderer: any ForgeReadAvatarRendering,
        destinationRouter: any ForgeReadDestinationRouting,
        defaultRevision: ForgeRevision,
        pullRequestChangesProvider: (any RepositoryPullRequestChangesProviding)? = nil,
        reviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)? = nil,
        initialMode: RepositoryForgeInspectorMode = .overview
    ) {
        self.markdownRenderer = markdownRenderer
        self.avatarRenderer = avatarRenderer
        self.destinationRouter = destinationRouter
        self.defaultRevision = defaultRevision
        self.pullRequestChangesProvider = pullRequestChangesProvider
        self.reviewOverlayHost = reviewOverlayHost
        pullRequestMode = initialMode
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
        reviewOverlayHost?.detach()
        resetContent()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("ForgeInspectorPlaceholder")
        contentStack.addArrangedSubview(label)
    }

    func showLoading(for row: ForgeReadSurfaceRow) {
        routedDestination = row.destination
        reviewOverlayHost?.detach()
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
        reviewOverlayHost?.detach()
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

    func showRefreshError(_ message: String, freshnessMessage: String?) {
        refreshFailureMessage = message
        renderRefreshError(message, freshnessMessage: freshnessMessage)
    }

    private func renderRefreshError(_ message: String, freshnessMessage: String?) {
        if let refreshFailureView {
            contentStack.removeArrangedSubview(refreshFailureView)
            refreshFailureView.removeFromSuperview()
        }
        if let freshnessMessage {
            if let freshnessView {
                freshnessView.stringValue = freshnessMessage
            } else {
                let freshness = banner(freshnessMessage, color: .systemOrange)
                freshness.setAccessibilityIdentifier("ForgeInspectorFreshness")
                contentStack.addArrangedSubview(freshness)
                freshnessView = freshness
            }
        }
        let failure = banner("Showing stale details. Refresh failed: \(message)", color: .systemOrange)
        failure.setAccessibilityIdentifier("ForgeInspectorRefreshError")
        contentStack.addArrangedSubview(failure)
        refreshFailureView = failure
        editPullRequestButton?.isEnabled = false
        editPullRequestButton?.toolTip = "Refresh this Pull Request before editing; stale data cannot authorize a mutation."
        editPullRequestButton?.setAccessibilityHelp(editPullRequestButton?.toolTip)
    }

    func apply(_ presentation: ForgeReadInspectorPresentation) {
        refreshFailureMessage = nil
        changesTask?.cancel()
        currentPresentation = presentation
        routedDestination = presentation.item.destination
        resetContent()

        if case let .pullRequest(summary) = presentation.item,
           pullRequestChangesProvider != nil
        {
            let control = makePullRequestModeControl()
            contentStack.addArrangedSubview(control)
            pullRequestModeControl = control
            addReviewActionView(for: summary)
            if control.selectedSegment == 1 {
                showLocalChanges(for: presentation)
                return
            }
        } else {
            reviewOverlayHost?.detach()
            pullRequestModeControl = nil
        }

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
        var headingViews: [NSView] = [avatar, headingText, NSView()]
        editablePullRequestSnapshot = nil
        currentPullRequestSummary = nil
        if case let .pullRequest(summary) = presentation.item,
           onCheckoutPullRequest != nil
        {
            currentPullRequestSummary = summary
            let checkoutButton = NSButton(title: "Check Out…", target: self, action: #selector(checkoutPullRequest(_:)))
            checkoutButton.bezelStyle = .rounded
            checkoutButton.setAccessibilityIdentifier("GitX.PullRequest.Checkout")
            checkoutButton.setAccessibilityLabel("Check out Pull Request")
            headingViews.append(checkoutButton)
        }
        if editPullRequestControl.isVisible,
           case let .pullRequest(summary) = presentation.item,
           let body = presentation.bodyMarkdown,
           let snapshot = try? ForgePullRequestEditableSnapshot(
               repository: summary.repository,
               number: summary.number,
               title: summary.title,
               bodyMarkdown: body,
               updatedAt: summary.updatedAt
           )
        {
            editablePullRequestSnapshot = snapshot
            let editButton = NSButton(title: "Edit…", target: self, action: #selector(editPullRequest(_:)))
            editButton.bezelStyle = .rounded
            editButton.setAccessibilityIdentifier("GitX.PullRequest.Edit")
            editButton.setAccessibilityLabel("Edit Pull Request title and body")
            editButton.isEnabled = editPullRequestControl.isEnabled && presentation.isMutationStateFresh
            editButton.toolTip = presentation.isMutationStateFresh
                ? editPullRequestControl.helpText
                : "Refresh this Pull Request before editing; stale data cannot authorize a mutation."
            editButton.setAccessibilityHelp(editButton.toolTip)
            editPullRequestButton = editButton
            headingViews.append(editButton)
        }
        headingViews.append(browserButton)
        let heading = NSStackView(views: headingViews)
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        contentStack.addArrangedSubview(heading)

        if let freshnessMessage = presentation.freshnessMessage {
            let freshness = banner(freshnessMessage, color: .systemOrange)
            freshness.setAccessibilityIdentifier("ForgeInspectorFreshness")
            contentStack.addArrangedSubview(freshness)
            freshnessView = freshness
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

    func setPullRequestMode(_ mode: RepositoryForgeInspectorMode) {
        guard pullRequestMode != mode else { return }
        pullRequestMode = mode
        guard let currentPresentation else { return }
        apply(currentPresentation)
    }

    private func makePullRequestModeControl() -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: ["Overview", "Changes"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(pullRequestModeChanged(_:))
        )
        control.selectedSegment = pullRequestMode.selectedSegment
        control.setAccessibilityIdentifier("GitX.PullRequest.InspectorMode")
        control.setAccessibilityLabel("Pull Request inspector mode")
        return control
    }

    @objc private func pullRequestModeChanged(_ sender: NSSegmentedControl) {
        pullRequestMode = RepositoryForgeInspectorMode(selectedSegment: sender.selectedSegment)
        onPullRequestModeChange?(pullRequestMode)
        guard let currentPresentation else { return }
        let refreshFailureMessage = self.refreshFailureMessage
        apply(currentPresentation)
        if let refreshFailureMessage {
            showRefreshError(
                refreshFailureMessage,
                freshnessMessage: currentPresentation.freshnessMessage
            )
        }
    }

    private func showLocalChanges(for presentation: ForgeReadInspectorPresentation) {
        guard case let .pullRequest(summary) = presentation.item,
              case let .available(base) = summary.base,
              case let .available(head) = summary.head,
              let pullRequestChangesProvider
        else {
            let unavailable = NSTextField(wrappingLabelWithString: "Local base or head objects are unavailable. Fetch them or open the Pull Request in a matching checkout.")
            unavailable.textColor = .secondaryLabelColor
            unavailable.setAccessibilityIdentifier("GitX.PullRequest.ChangesUnavailable")
            contentStack.addArrangedSubview(unavailable)
            return
        }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Computing changes from local Git objects…")
        label.textColor = .secondaryLabelColor
        let loading = NSStackView(views: [spinner, label])
        loading.orientation = .horizontal
        loading.alignment = .centerY
        loading.spacing = 8
        loading.setAccessibilityIdentifier("GitX.PullRequest.ChangesProgress")
        contentStack.addArrangedSubview(loading)

        let destination = presentation.item.destination
        changesTask = Task { [weak self] in
            do {
                let diff = try await pullRequestChangesProvider.changes(
                    repository: summary.repository,
                    base: base,
                    head: head
                )
                guard let self,
                      !Task.isCancelled,
                      self.routedDestination == destination,
                      self.pullRequestMode == .changes
                else { return }
                self.renderLocalChanges(diff, pullRequest: summary)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.routedDestination == destination,
                      self.pullRequestMode == .changes
                else { return }
                self.renderLocalChangesError(error.localizedDescription, pullRequest: summary)
            }
        }
    }

    private func renderLocalChanges(
        _ diff: RepositoryLocalPullRequestDiff,
        pullRequest: ForgePullRequestSummary
    ) {
        resetContent()
        let control = makePullRequestModeControl()
        contentStack.addArrangedSubview(control)
        pullRequestModeControl = control
        addReviewActionView(for: pullRequest)
        let nativeView = PBNativeContentView(frame: .zero)
        nativeView.translatesAutoresizingMaskIntoConstraints = false
        nativeView.setAccessibilityIdentifier("GitX.PullRequest.LocalChanges")
        nativeView.showDiffSections(
            [[
                PBNativeSectionTitleKey: diff.title,
                PBNativeSectionTextKey: diff.patch,
                PBNativeSectionContextKey: "readOnly",
            ]],
            cacheIdentifier: diff.cacheIdentifier,
            preserveScrollPosition: true
        )
        reviewOverlayHost?.install(in: nativeView, pullRequest: pullRequest, diff: diff)
        contentStack.addArrangedSubview(nativeView)
        NSLayoutConstraint.activate([
            nativeView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            nativeView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        if let refreshFailureMessage {
            renderRefreshError(
                refreshFailureMessage,
                freshnessMessage: currentPresentation?.freshnessMessage
            )
        }
    }

    @inline(never)
    private func renderLocalChangesError(
        _ message: String,
        pullRequest: ForgePullRequestSummary
    ) {
        resetContent()
        let control = makePullRequestModeControl()
        contentStack.addArrangedSubview(control)
        pullRequestModeControl = control
        addReviewActionView(for: pullRequest)
        let error = banner("Couldn’t compute local Pull Request changes. \(message)", color: .systemRed)
        error.setAccessibilityIdentifier("GitX.PullRequest.ChangesError")
        contentStack.addArrangedSubview(error)
        if let refreshFailureMessage {
            renderRefreshError(
                refreshFailureMessage,
                freshnessMessage: currentPresentation?.freshnessMessage
            )
        }
    }

    private func addReviewActionView(for pullRequest: ForgePullRequestSummary) {
        guard let reviewOverlayHost else { return }
        let actionView = reviewOverlayHost.actionView(for: pullRequest)
        actionView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(actionView)
        actionView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    #if DEBUG
        func runProductProofLocalChanges(_ presentation: ForgeReadInspectorPresentation) async -> Bool {
            let provider = pullRequestChangesProvider
            pullRequestChangesProvider = nil
            apply(presentation)
            pullRequestMode = .changes
            showLocalChanges(for: presentation)
            let unavailable = contentStack.arrangedSubviews.contains(where: {
                $0.accessibilityIdentifier() == "GitX.PullRequest.ChangesUnavailable"
            })
            pullRequestChangesProvider = provider
            apply(presentation)
            pullRequestMode = .changes
            showLocalChanges(for: presentation)
            for _ in 0 ..< 500 {
                if contentStack.arrangedSubviews.contains(where: {
                    $0.accessibilityIdentifier() == "GitX.PullRequest.ChangesError"
                }) {
                    return unavailable
                }
                await Task.yield()
            }
            return false
        }
    #endif

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
        editablePullRequestSnapshot = nil
        editPullRequestButton = nil
        currentPullRequestSummary = nil
        refreshFailureView = nil
        freshnessView = nil
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

    @objc private func editPullRequest(_: Any?) {
        guard let editablePullRequestSnapshot, let routedDestination else { return }
        onEditPullRequest?(editablePullRequestSnapshot, routedDestination)
    }

    @objc private func checkoutPullRequest(_: NSButton) {
        guard let pullRequest = currentPullRequestSummary else { return }
        onCheckoutPullRequest?(pullRequest)
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

extension Notification.Name {
    nonisolated static let forgeAccountsDidChange = Notification.Name("PBForgeAccountsDidChangeNotification")
    nonisolated static let forgeAttentionInboxDidChange = Notification.Name("PBForgeAttentionInboxDidChangeNotification")
    nonisolated static let forgeAttentionPreferencesDidChange = Notification.Name(
        "PBForgeAttentionPreferencesDidChangeNotification"
    )
    nonisolated static let repositoryForgeAccountDidChange = Notification.Name(
        "PBRepositoryForgeAccountDidChangeNotification"
    )
    nonisolated static let repositoryAttentionUnseenDidChange = Notification.Name(
        "PBRepositoryAttentionUnseenDidChangeNotification"
    )
    nonisolated static let forgeAttentionAlertAction = Notification.Name(
        "PBForgeAttentionAlertActionNotification"
    )
}

enum RepositoryAttentionNotificationKey {
    static let count = "count"
    static let itemID = "itemID"
    static let action = "action"
}

enum RepositoryForgeAccountNotificationKey {
    static let providerName = "providerName"
    static let login = "login"
    static let isPublic = "isPublic"
    static let accountID = "accountID"
    static let accounts = "accounts"
}

@MainActor
final class ForgeReadNativeMarkdownRenderer: ForgeReadMarkdownRendering {
    private weak var router: (any ForgeMarkdownNavigationRouting)?

    init(router: any ForgeMarkdownNavigationRouting) {
        self.router = router
    }

    func makeView(markdown: String, context: ForgeMarkdownContext) -> NSView {
        let document = ForgeMarkdownSanitizer().sanitize(markdown, context: context)
        return ForgeMarkdownNativeView(document: document, navigationRouter: router)
    }
}

@MainActor
final class ForgeReadNativeAvatarRenderer: ForgeReadAvatarRendering {
    private let owner: ForgeAvatarCacheOwner

    init(owner: ForgeAvatarCacheOwner) {
        self.owner = owner
    }

    func makeAvatarView(for actor: ForgeActor, size: NSSize) -> NSView {
        let view = ForgeAvatarView(
            frame: NSRect(origin: .zero, size: size),
            owner: owner
        )
        view.configure(displayName: actor.displayName ?? actor.login, avatarURL: actor.avatarURL)
        return view
    }
}

nonisolated enum ForgeAnonymousReadAdapterPool {
    static let budget = GitHubAnonymousRESTBudget()
    static let shared = GitHubAnonymousRESTAdapter(budget: budget)
}

/// Explicit-only anonymous adapter for a single public GitHub.com repository.
/// The first request is caused by opening the surface; every later request is
/// an explicit search, filter, pagination, detail selection, or refresh action.
@MainActor
final class ForgeGitHubAnonymousReadSurfaceService: ForgeReadSurfaceServing {
    private let repository: ForgeRepositoryIdentity
    private let adapter: GitHubAnonymousRESTAdapter
    private var hasIssuedRequest = false

    init(
        repository: ForgeRepositoryIdentity,
        adapter: GitHubAnonymousRESTAdapter = ForgeAnonymousReadAdapterPool.shared
    ) {
        self.repository = repository
        self.adapter = adapter
    }

    func loadItems(
        kind: ForgeReadSurfaceKind,
        query: ForgeReadSurfaceQuery,
        after cursor: ForgePageCursor?
    ) async throws -> ForgeReadSurfacePage {
        let reason = nextExplicitReason()
        let result: ForgeReadSurfacePage
        switch kind {
        case .pullRequests:
            let response = try await adapter.pullRequests(
                repository: repository,
                page: cursor,
                states: pullRequestStates(query.stateFilter),
                reason: reason
            )
            result = ForgeReadSurfacePage(
                items: response.value.items.map(ForgeRepositoryItem.pullRequest),
                nextCursor: response.value.nextCursor,
                totalCount: response.value.totalCount,
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        case .issues:
            let response = try await adapter.issues(
                repository: repository,
                page: cursor,
                states: issueStates(query.stateFilter),
                reason: reason
            )
            result = ForgeReadSurfacePage(
                items: response.value.items.map(ForgeRepositoryItem.issue),
                nextCursor: response.value.nextCursor,
                totalCount: response.value.totalCount,
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        }
        guard !query.searchText.isEmpty else { return result }
        let needle = query.searchText.localizedLowercase
        return ForgeReadSurfacePage(
            items: result.items.filter { item in
                let row = ForgeReadSurfaceRow(item: item)
                return row.title.localizedLowercase.contains(needle) ||
                    row.number.localizedLowercase.contains(needle) ||
                    row.author.localizedLowercase.contains(needle)
            },
            nextCursor: result.nextCursor,
            fetchedAt: result.fetchedAt,
            isPartial: true
        )
    }

    func loadDetails(
        for item: ForgeRepositoryItem,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeReadSurfaceDetailsSnapshot {
        guard item.repository == repository else {
            throw ForgeGitHubReadSurfaceServiceError.repositoryMismatch
        }
        let reason = nextExplicitReason()
        switch item {
        case let .pullRequest(summary):
            let response = try await adapter.pullRequestDetails(
                repository: repository,
                number: summary.number,
                reason: reason
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(response.value),
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        case let .issue(summary):
            let response = try await adapter.issueDetails(
                repository: repository,
                number: summary.number,
                reason: reason
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .issue(response.value),
                fetchedAt: response.fetchedAt,
                isPartial: true
            )
        }
    }

    private func nextExplicitReason() -> ForgeRefreshReason {
        defer { hasIssuedRequest = true }
        return hasIssuedRequest ? .manual : .repositoryOpened
    }

    private func pullRequestStates(_ filter: ForgeReadStateFilter) -> Set<ForgePullRequestState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed, .merged]
        case .all: nil
        }
    }

    private func issueStates(_ filter: ForgeReadStateFilter) -> Set<ForgeIssueState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed]
        case .all: nil
        }
    }
}

private nonisolated struct ForgeAttentionNotificationPayload: Codable, Sendable {
    let itemID: ForgeAttentionItemID
}

/// The one notification boundary used by every Attention coordinator. It
/// preserves the app's existing notification delegate through a small
/// forwarding bridge and registers only the two accepted actions.
actor ForgeAttentionNotificationDelivery: ForgeAttentionAlertDelivering {
    static let shared = ForgeAttentionNotificationDelivery()

    fileprivate static let categoryIdentifier = "PBForgeAttention"
    fileprivate static let openActionIdentifier = "PBForgeAttention.Open"
    fileprivate static let markSeenActionIdentifier = "PBForgeAttention.MarkSeen"
    private var isInstalled = false

    func authorizationStatus() async -> ForgeAttentionSystemAuthorization {
        await installIfNeeded()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        await installIfNeeded()
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ alert: ForgeAttentionAlert) async {
        await installIfNeeded()
        guard let payload = try? JSONEncoder().encode(ForgeAttentionNotificationPayload(itemID: alert.itemID)) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = Self.title(alert.category)
        content.body = "GitX found a current item that needs your attention."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["payload": payload.base64EncodedString()]
        let identifier = "forge-attention-\(payload.base64EncodedString())"
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            // The current-state row remains available even when macOS cannot
            // accept a notification request.
        }
    }

    private func installIfNeeded() async {
        guard !isInstalled else { return }
        isInstalled = true
        let center = UNUserNotificationCenter.current()
        let actions = [
            UNNotificationAction(
                identifier: Self.openActionIdentifier,
                title: "Open",
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: Self.markSeenActionIdentifier,
                title: "Mark Seen",
                options: []
            ),
        ]
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        var categories = await center.notificationCategories()
        categories.insert(category)
        center.setNotificationCategories(categories)
        await MainActor.run {
            ForgeAttentionNotificationDelegateBridge.shared.install(on: center)
        }
    }

    private static func title(_ category: ForgeAttentionAlertCategory) -> String {
        switch category {
        case .reviewRequests: "Review Requested"
        case .mentionsAndReplies: "Mention or Reply"
        case .assignments: "Assignment"
        case .failedChecksOnAuthoredPullRequests: "Pull Request Check Failed"
        }
    }

    nonisolated static func action(
        for identifier: String
    ) -> ForgeAttentionAlertAction? {
        switch identifier {
        case openActionIdentifier, UNNotificationDefaultActionIdentifier: .open
        case markSeenActionIdentifier: .markSeen
        default: nil
        }
    }

    fileprivate nonisolated static func payload(
        from response: UNNotificationResponse
    ) -> ForgeAttentionNotificationPayload? {
        guard response.notification.request.content.categoryIdentifier == categoryIdentifier,
              let value = response.notification.request.content.userInfo["payload"] as? String,
              let data = Data(base64Encoded: value)
        else { return nil }
        return try? JSONDecoder().decode(ForgeAttentionNotificationPayload.self, from: data)
    }
}

@MainActor
private final class ForgeAttentionNotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForgeAttentionNotificationDelegateBridge()

    // UserNotifications calls these delegate methods outside MainActor. The delegate is
    // installed once on MainActor before callbacks begin, then is only read afterward.
    // swift6-safety-justification: The weak reference only preserves that callback chain.
    private nonisolated(unsafe) weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    private var isInstalled = false

    func install(on center: UNUserNotificationCenter) {
        guard !isInstalled else { return }
        previousDelegate = center.delegate
        center.delegate = self
        isInstalled = true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.categoryIdentifier != ForgeAttentionNotificationDelivery.categoryIdentifier else {
            completionHandler([.banner, .sound])
            return
        }
        guard let previousDelegate else {
            completionHandler([])
            return
        }
        previousDelegate.userNotificationCenter?(
            center,
            willPresent: notification,
            withCompletionHandler: completionHandler
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        if let payload = ForgeAttentionNotificationDelivery.payload(from: response),
           let action = ForgeAttentionNotificationDelivery.action(for: response.actionIdentifier)
        {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .forgeAttentionAlertAction,
                    object: nil,
                    userInfo: [
                        RepositoryAttentionNotificationKey.itemID: payload.itemID,
                        RepositoryAttentionNotificationKey.action: action,
                    ]
                )
                completionHandler()
            }
            return
        }
        guard let previousDelegate else {
            completionHandler()
            return
        }
        previousDelegate.userNotificationCenter?(
            center,
            didReceive: response,
            withCompletionHandler: completionHandler
        )
    }
}

enum RepositoryAttentionSessionError: Error, LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "Forge data is unavailable for this session. Local Git remains available."
        }
    }
}

@MainActor
protocol RepositoryAttentionServing: AnyObject {
    var account: ForgeAccount { get }
    var repositoryIdentity: ForgeRepositoryIdentity { get }
    var lastRefreshErrorDescription: String? { get }

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry]
    func markOpen(_ itemID: ForgeAttentionItemID) async throws
    func markUnseen(_ itemID: ForgeAttentionItemID) async throws
    func markAllSeen(state: ForgeAttentionViewState) async throws
    func refreshNow() async
    func makeReadService(for repository: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing
}

/// One repository-window session participates in the account-wide durable
/// inbox. The scheduler still considers every watched repository for that
/// account, while this window identifies its repository as active/open.
@MainActor
final class RepositoryAttentionSession: NSObject, RepositoryAttentionServing {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "AttentionSession")
    private static var sessionsByAccount: [ForgeAccountID: [WeakRepositoryAttentionSession]] = [:]

    let account: ForgeAccount
    let repositoryIdentity: ForgeRepositoryIdentity
    private weak var repositoryObject: PBGitRepository?
    private let services: ForgeApplicationServices
    private let persistence: ForgeSQLiteAttentionPersistence
    private let watchedKey: ForgeWatchedRepositoryKey
    private var coordinator: ForgeAttentionInboxCoordinator
    private var pollingTask: Task<Void, Never>?
    private var didStart = false
    private var didEnrollOpenedRepository = false
    private(set) var lastRefreshErrorDescription: String?
    var onOpenAttentionItem: ((ForgeAttentionItemID) -> Void)?

    init(
        account: ForgeAccount,
        repositoryIdentity: ForgeRepositoryIdentity,
        repositoryObject: PBGitRepository,
        services: ForgeApplicationServices
    ) throws {
        guard let database = services.database else {
            throw RepositoryAttentionSessionError.databaseUnavailable
        }
        self.account = account
        self.repositoryIdentity = repositoryIdentity
        self.repositoryObject = repositoryObject
        self.services = services
        persistence = ForgeSQLiteAttentionPersistence(store: database)
        watchedKey = try ForgeWatchedRepositoryKey(
            accountID: account.id,
            repository: repositoryIdentity
        )
        coordinator = try Self.makeCoordinator(
            account: account,
            services: services,
            persistence: persistence
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged(_:)),
            name: .forgeAttentionPreferencesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alertAction(_:)),
            name: .forgeAttentionAlertAction,
            object: nil
        )
    }

    deinit {
        pollingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Self.register(self)
        beginPollingCycle(shouldEnrollOpenedRepository: !didEnrollOpenedRepository)
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        didStart = false
        Self.unregister(self)
    }

    #if DEBUG
        func waitForCurrentPollingCycleForProductProof() async {
            await pollingTask?.value
        }
    #endif

    func entries(state: ForgeAttentionViewState) async throws -> [ForgeAttentionInboxEntry] {
        try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: account.id,
                currentRepository: repositoryIdentity,
                state: state
            ),
            at: Date()
        )
    }

    func markOpen(_ itemID: ForgeAttentionItemID) async throws {
        _ = try await persistence.open(itemID, at: Date())
        try await publishChange()
    }

    func markUnseen(_ itemID: ForgeAttentionItemID) async throws {
        _ = try await persistence.markUnseen(itemID, at: Date())
        try await publishChange()
    }

    func markAllSeen(state: ForgeAttentionViewState) async throws {
        let scope: ForgeAttentionScope = state.scope == .all
            ? .all(accountID: account.id)
            : .currentRepository(watchedKey)
        _ = try await persistence.markAllSeen(
            query: ForgeAttentionQuery(scope: scope, visibility: state.visibility),
            at: Date()
        )
        try await publishChange()
    }

    func refreshNow() async {
        do {
            _ = try await coordinator.refresh(watchedKey)
            lastRefreshErrorDescription = nil
            try await publishChange()
        } catch is CancellationError {
            return
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
            Self.logger.error("Manual Attention refresh failed type=\(String(describing: type(of: error)), privacy: .public)")
            NotificationCenter.default.post(name: .forgeAttentionInboxDidChange, object: repositoryObject)
        }
    }

    func makeReadService(for repository: ForgeRepositoryIdentity) throws -> ForgeReadSurfaceServing {
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference
        )
        return ForgeGitHubReadSurfaceService(repository: repository, adapter: adapter)
    }

    private static func makeCoordinator(
        account: ForgeAccount,
        services: ForgeApplicationServices,
        persistence: ForgeSQLiteAttentionPersistence
    ) throws -> ForgeAttentionInboxCoordinator {
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference
        )
        return ForgeAttentionInboxCoordinator(
            persistence: persistence,
            fetcher: GitHubAttentionSnapshotFetcher(adapter: adapter),
            alertDelivery: ForgeAttentionNotificationDelivery.shared,
            attentionPolicy: ApplicationSettings.attentionPolicy,
            enabledAlertCategories: ApplicationSettings.attentionAlertCategories,
            pollingPreset: ApplicationSettings.attentionPollingPreset
        )
    }

    private func beginPollingCycle(shouldEnrollOpenedRepository: Bool) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            if shouldEnrollOpenedRepository {
                do {
                    try await self.enrollWatchIfNeeded()
                    self.didEnrollOpenedRepository = true
                    try await self.publishChange()
                } catch {
                    self.lastRefreshErrorDescription = error.localizedDescription
                }
            }
            guard ApplicationSettings.attentionPollingPreset != .manual else { return }
            while !Task.isCancelled {
                do {
                    let reconciliation = try await self.coordinator.refreshNextDue(
                        accountID: self.account.id,
                        activeOrOpenRepositories: [self.watchedKey],
                        at: Date()
                    )
                    if reconciliation != nil {
                        self.lastRefreshErrorDescription = nil
                        try await self.publishChange()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.lastRefreshErrorDescription = error.localizedDescription
                    Self.logger.error(
                        "Scheduled Attention refresh failed type=\(String(describing: type(of: error)), privacy: .public)"
                    )
                    NotificationCenter.default.post(
                        name: .forgeAttentionInboxDidChange,
                        object: self.repositoryObject
                    )
                }
                let interval = ApplicationSettings.attentionPollingPreset.activeInterval ?? 60
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func enrollWatchIfNeeded() async throws {
        let watches = try await persistence.watchedRepositories(accountID: account.id)
        guard !watches.contains(where: { $0.key == watchedKey }) else { return }
        try await persistence.save(ForgeWatchedRepository(
            key: watchedKey,
            addedAt: Date(),
            source: .repositoryOpened
        ))
        Self.logger.notice("Added opened repository to the Attention watch set")
    }

    private func publishChange() async throws {
        let state = ForgeAttentionViewState(
            scope: .all,
            visibility: .unseenOnly,
            sortOrder: .newestFirst
        )
        let unseen = try await persistence.cachedEntries(
            query: ForgeAttentionInboxQuery(
                accountID: account.id,
                currentRepository: repositoryIdentity,
                state: state
            ),
            at: Date()
        ).count
        NotificationCenter.default.post(
            name: .forgeAttentionInboxDidChange,
            object: repositoryObject
        )
        NotificationCenter.default.post(
            name: .repositoryAttentionUnseenDidChange,
            object: repositoryObject,
            userInfo: [RepositoryAttentionNotificationKey.count: unseen]
        )
    }

    @objc private func preferencesChanged(_: Notification) {
        do {
            coordinator = try Self.makeCoordinator(
                account: account,
                services: services,
                persistence: persistence
            )
            if didStart {
                beginPollingCycle(shouldEnrollOpenedRepository: !didEnrollOpenedRepository)
            }
        } catch {
            lastRefreshErrorDescription = error.localizedDescription
        }
    }

    @objc private func alertAction(_ notification: Notification) {
        guard let itemID = notification.userInfo?[RepositoryAttentionNotificationKey.itemID]
            as? ForgeAttentionItemID,
            itemID.accountID == account.id,
            Self.alertHandler(for: account.id) === self,
            let action = notification.userInfo?[RepositoryAttentionNotificationKey.action]
            as? ForgeAttentionAlertAction
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await self.coordinator.handle(
                    action: action,
                    itemID: itemID,
                    at: Date()
                )
                try await self.publishChange()
                if destination != nil {
                    self.onOpenAttentionItem?(itemID)
                }
            } catch {
                Self.logger.error("Attention alert action failed")
            }
        }
    }

    private static func register(_ session: RepositoryAttentionSession) {
        var sessions = sessionsByAccount[session.account.id] ?? []
        sessions.removeAll { $0.value == nil || $0.value === session }
        sessions.append(WeakRepositoryAttentionSession(session))
        sessionsByAccount[session.account.id] = sessions
    }

    private static func unregister(_ session: RepositoryAttentionSession) {
        var sessions = sessionsByAccount[session.account.id] ?? []
        sessions.removeAll { $0.value == nil || $0.value === session }
        sessionsByAccount[session.account.id] = sessions.isEmpty ? nil : sessions
    }

    private static func alertHandler(for accountID: ForgeAccountID) -> RepositoryAttentionSession? {
        var sessions = sessionsByAccount[accountID] ?? []
        sessions.removeAll { $0.value == nil }
        sessionsByAccount[accountID] = sessions.isEmpty ? nil : sessions
        return sessions.last?.value
    }
}

@MainActor
private final class WeakRepositoryAttentionSession {
    weak var value: RepositoryAttentionSession?

    init(_ value: RepositoryAttentionSession) {
        self.value = value
    }
}

@MainActor
final class ForgeAttentionViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAttentionSurface")

    private let session: any RepositoryAttentionServing
    private let destinationRouter: any ForgeReadDestinationRouting
    private let viewStateStore: (any RepositoryForgeViewStateStoring)?
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
        viewStateStore: (any RepositoryForgeViewStateStoring)? = nil
    ) {
        self.session = session
        self.destinationRouter = destinationRouter
        self.viewStateStore = viewStateStore
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
            self.reload()
        }
    }

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
        let field = NSTextField(labelWithString: value)
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
        let requestedState = state
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.session.entries(state: requestedState)
                guard requestedState == self.state else { return }
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
            } catch {
                Self.logger.error("Attention rows failed to load: \(error.localizedDescription, privacy: .public)")
                self.rows = []
                self.entries = []
                self.tableView.reloadData()
                self.statusLabel.stringValue = "Couldn’t load Attention. \(error.localizedDescription)"
                self.statusLabel.isHidden = false
            }
            self.setLoading(false)
            self.updateActionState()
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
                self.reload()
            } catch is CancellationError {
                return
            } catch {
                guard self.currentRoute == route else { return }
                self.inspectorController.showError(error.localizedDescription, item: route.item)
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
                self.inspectorController.showContinuationError(error.localizedDescription)
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
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
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

// swiftformat:disable indent
#if GITX_APP_TARGET
@MainActor
private final class RepositoryForgeNativeDestinationOpener: ForgeNativeDestinationOpening {
    weak var owner: RepositoryForgeCollaborationController?

    func open(_ destination: ForgeDestination) -> ForgeNativeDestinationOpenResult {
        owner?.openNative(destination) == true ? .opened : .unavailable
    }
}

/// The PBViewController bridge that makes the provider-neutral Forge read
/// surfaces a first-class repository-window destination. The controller owns
/// account choice for this window only; exact-account persistence remains in
/// the stable Repository Forge Binding.
@MainActor
@objc(PBRepositoryForgeCollaborationController)
final class RepositoryForgeCollaborationController: PBViewController {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeCollaboration")
    static let mutationCapabilityOperations: Set<ForgeOperation> = [
        .createPullRequest,
        .editPullRequest,
        .syncFork,
    ]

    private var forgeCoordinator: RepositoryForgeCoordinator!
    private var settings: RepositoryUISettings!
    private var composition: ApplicationComposition {
        ApplicationComposition.shared
    }

    private let providerTitleLabel = NSTextField(labelWithString: "Forge")
    private let accountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let accountsButton = NSButton(title: "Accounts…", target: nil, action: nil)
    private let publicButton = NSButton(title: "Continue Publicly", target: nil, action: nil)
    private let syncForkButton = NSButton(title: "Sync Fork…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Resolving GitHub repository…")
    private let contentContainer = NSView()
    private var preparationTask: Task<Void, Never>?
    private var repositoryFactsTask: Task<Void, Never>?
    private var services: ForgeApplicationServices?
    private var pullRequestMutationService: (any RepositoryPullRequestMutationServing)?
    private var accounts: [ForgeAccount] = []
    private var binding: ForgeRepositoryBinding?
    private var explicitAccountID: ForgeAccountID?
    private var explicitlyContinuesPublicly = false
    private var accessResolution: ForgeCollaborationAccessResolution?
    private var activeSurface: ForgeCollaborationSurface = .pullRequests
    private var readController: ForgeReadSurfaceViewController?
    private var pullRequestReviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)?
    private var attentionController: ForgeAttentionViewController?
    private var attentionSession: RepositoryAttentionSession?
    private var nativeOpener: RepositoryForgeNativeDestinationOpener?
    private var destinationRouter: ForgeCentralDestinationRouter?
    private var repositoryFacts: ForgeRepositoryFacts?
    private var createPullRequestControl = ForgeMutationControlPresentation.hidden {
        didSet {
            windowController?.updateCreatePullRequestControl(createPullRequestControl)
        }
    }

    private var editPullRequestControl = ForgeMutationControlPresentation.hidden
    private var syncForkControl = ForgeMutationControlPresentation.hidden
    private weak var mountedController: NSViewController?
    private var isPrepared = false

    @objc(initWithRepository:superController:)
    override init?(repository: PBGitRepository, superController controller: PBGitWindowController?) {
        super.init(repository: repository, superController: controller)
        forgeCoordinator = RepositoryForgeCoordinator(repository: repository)
        settings = composition.repositoryViewState(for: repository)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accountsDidChange(_:)),
            name: .forgeAccountsDidChange,
            object: nil
        )
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepositoryForgeCollaborationController must be initialized with a repository")
    }

    isolated deinit {
        preparationTask?.cancel()
        repositoryFactsTask?.cancel()
        attentionSession?.stop()
        pullRequestReviewOverlayHost?.detach()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("RepositoryForgeCollaboration")
        let accountBar = ForgeReadSnowLeopardBarView()
        accountBar.translatesAutoresizingMaskIntoConstraints = false
        providerTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        providerTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("ForgeCollaborationAccountStatus")

        accountPopup.target = self
        accountPopup.action = #selector(accountChanged(_:))
        accountPopup.translatesAutoresizingMaskIntoConstraints = false
        accountPopup.setAccessibilityIdentifier("ForgeCollaborationAccount")
        accountPopup.setAccessibilityLabel("GitHub account for this repository")

        publicButton.target = self
        publicButton.action = #selector(continuePublicly(_:))
        publicButton.bezelStyle = .rounded
        publicButton.translatesAutoresizingMaskIntoConstraints = false
        publicButton.setAccessibilityIdentifier("ForgeCollaborationContinuePublicly")

        syncForkButton.target = self
        syncForkButton.action = #selector(syncFork(_:))
        syncForkButton.bezelStyle = .rounded
        syncForkButton.translatesAutoresizingMaskIntoConstraints = false
        syncForkButton.setAccessibilityIdentifier("GitX.SyncFork")
        syncForkButton.setAccessibilityLabel("Synchronize this fork from its parent")

        accountsButton.target = self
        accountsButton.action = #selector(openAccountsPreferences(_:))
        accountsButton.bezelStyle = .rounded
        accountsButton.translatesAutoresizingMaskIntoConstraints = false
        accountsButton.setAccessibilityIdentifier("ForgeCollaborationAccountsPreferences")

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setAccessibilityIdentifier("ForgeCollaborationContent")
        for child in [accountBar, contentContainer] {
            root.addSubview(child)
        }
        let controls = NSStackView(views: [accountPopup, syncForkButton, accountsButton, publicButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        for child in [providerTitleLabel, statusLabel, controls] {
            accountBar.addSubview(child)
        }
        NSLayoutConstraint.activate([
            accountBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            accountBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            accountBar.topAnchor.constraint(equalTo: root.topAnchor),
            accountBar.heightAnchor.constraint(equalToConstant: 38),
            providerTitleLabel.leadingAnchor.constraint(equalTo: accountBar.leadingAnchor, constant: 10),
            providerTitleLabel.centerYAnchor.constraint(equalTo: accountBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: providerTitleLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: accountBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            accountPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            controls.trailingAnchor.constraint(equalTo: accountBar.trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: accountBar.centerYAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: accountBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        renderGateway(
            title: "Loading GitHub Collaboration…",
            message: "GitX is resolving this repository’s exact GitHub account and local cache."
        )
        updateAccountBar()
    }

    override func updateView() {
        prepare()
        show(activeSurface)
    }

    override func firstResponder() -> NSResponder? {
        accountPopup.isHidden ? view : accountPopup
    }

    override func refresh(_ sender: Any?) {
        switch activeSurface {
        case .pullRequests, .issues:
            readController?.refresh()
        case .attention:
            attentionController?.refresh()
        }
    }

    override func closeView() {
        preparationTask?.cancel()
        repositoryFactsTask?.cancel()
        attentionSession?.stop()
        pullRequestReviewOverlayHost?.detach()
        pullRequestReviewOverlayHost = nil
        super.closeView()
    }

    var currentAccountLogin: String? {
        if case let .authenticated(account) = accessResolution {
            return account.login
        }
        return nil
    }

    var includesAttention: Bool {
        if case .authenticated = accessResolution {
            return attentionSession != nil
        }
        return false
    }

    var sidebarRepositories: [RepositoryForgeSidebarRepositoryPresentation] {
        guard let binding else { return [] }
        let fork: Bool?
        let parent: ForgeRepositoryIdentity?
        if case let .available(relationship) = repositoryFacts?.forkRelationship {
            switch relationship {
            case .standalone:
                fork = false
                parent = nil
            case let .fork(repository):
                fork = true
                parent = repository
            }
        } else {
            fork = nil
            parent = nil
        }
        return RepositoryForgeSidebarPresenter.repositories(
            binding: binding,
            candidates: forgeCoordinator.sidebarCandidates(),
            accountLogin: currentAccountLogin,
            primaryIsFork: fork,
            parentRepository: parent
        )
    }

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        reloadAccess(resetPublicChoice: false)
    }

    func repositoryBindingDidChange() {
        isPrepared = true
        explicitAccountID = nil
        explicitlyContinuesPublicly = false
        reloadAccess(resetPublicChoice: true)
    }

    func show(_ surface: ForgeCollaborationSurface) {
        activeSurface = surface
        guard isViewLoaded else { return }
        renderActiveSurface()
    }

    @discardableResult
    func openNative(_ destination: ForgeDestination) -> Bool {
        guard destination.repository == binding?.primaryRepository else { return false }
        switch destination {
        case .pullRequest:
            show(.pullRequests)
            windowController?.changeContentController(self)
            _ = readController?.open(destination: destination)
            return true
        case .issue:
            show(.issues)
            windowController?.changeContentController(self)
            _ = readController?.open(destination: destination)
            return true
        default:
            return false
        }
    }

    private func reloadAccess(resetPublicChoice: Bool) {
        preparationTask?.cancel()
        repositoryFactsTask?.cancel()
        attentionSession?.stop()
        attentionSession = nil
        attentionController = nil
        pullRequestReviewOverlayHost?.detach()
        pullRequestReviewOverlayHost = nil
        readController = nil
        destinationRouter = nil
        nativeOpener = nil
        repositoryFacts = nil
        pullRequestMutationService = nil
        createPullRequestControl = .hidden
        editPullRequestControl = .hidden
        syncForkControl = .hidden
        if resetPublicChoice {
            explicitlyContinuesPublicly = false
        }
        let resolution = forgeCoordinator.resolveBinding()
        binding = resolution.binding
        guard let binding else {
            services = nil
            accounts = []
            accessResolution = nil
            updateAccountBar()
            if isViewLoaded {
                let message = resolution.kind == .requiresChoice
                    ? "Choose a Primary Repository in the GitHub sidebar group to continue."
                    : "Add a GitHub remote to use native Pull Requests and Issues."
                renderGateway(title: "GitHub Repository Required", message: message)
            }
            publishAccessChange()
            return
        }
        accessResolution = nil
        updateAccountBar()
        if isViewLoaded {
            renderGateway(
                title: "Loading GitHub Collaboration…",
                message: "GitX is loading exact-account Credentials without exposing secret material."
            )
        }
        preparationTask = Task { [weak self, composition] in
            do {
                let services = try await composition.forgeServices.services()
                let accounts = try await services.accountStore.accounts()
                guard let self, !Task.isCancelled else { return }
                self.services = services
                self.accounts = accounts
                self.applyAccess(binding: binding)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.services = nil
                self.accounts = []
                self.accessResolution = ForgeCollaborationAccessPolicy.resolve(
                    binding: binding,
                    availableAccounts: [],
                    explicitAccountID: self.explicitAccountID,
                    explicitlyContinuesPublicly: self.explicitlyContinuesPublicly
                )
                self.updateAccountBar(error: error.localizedDescription)
                self.renderActiveSurface()
                self.publishAccessChange()
            }
        }
    }

    private func applyAccess(binding: ForgeRepositoryBinding) {
        let resolution = ForgeCollaborationAccessPolicy.resolve(
            binding: binding,
            availableAccounts: accounts,
            explicitAccountID: explicitAccountID,
            explicitlyContinuesPublicly: explicitlyContinuesPublicly
        )
        accessResolution = resolution
        do {
            switch resolution {
            case let .authenticated(account):
                try installAuthenticated(account: account, binding: binding)
            case .publicAccess:
                installPublic(binding: binding)
            case .requiresExplicitChoice, .browserOnly:
                break
            }
        } catch {
            Self.logger.error("Could not install GitHub collaboration session")
            createPullRequestControl = .unavailable(
                error: error,
                action: "create a Pull Request"
            )
            accessResolution = .requiresExplicitChoice(
                accounts: accounts.filter { $0.id.forge == binding.primaryRepository.forge },
                preferredAccountUnavailable: binding.preferredAccount != nil
            )
            updateAccountBar(error: error.localizedDescription)
            renderActiveSurface()
            publishAccessChange()
            return
        }
        updateAccountBar()
        renderActiveSurface()
        publishAccessChange()
        loadRepositoryFacts(binding: binding, resolution: resolution)
    }

    private func installAuthenticated(account: ForgeAccount, binding: ForgeRepositoryBinding) throws {
        guard let services, let repository else { return }
        pullRequestMutationService = composition.forgePullRequestServices.session(for: repository).service
        createPullRequestControl = .checking(action: "create a Pull Request")
        editPullRequestControl = .checking(action: "edit this Pull Request")
        syncForkControl = .checking(action: "synchronize this fork")
        let adapter = try services.githubReadAdapterFactory.makeAdapter(
            for: account.currentCredential.reference
        )
        let reviewApplicationSession = composition.forgePullRequestReviewServices.session(
            for: repository
        )
        installReadSurface(
            binding: binding,
            service: ForgeGitHubReadSurfaceService(
                repository: binding.primaryRepository,
                adapter: adapter
            ),
            avatarOwner: .account(account.id),
            editPullRequestControl: editPullRequestControl,
            onEditPullRequest: editPullRequestHandler(account: account),
            reviewApplicationSession: reviewApplicationSession,
            reviewAccountID: account.id
        )
        let session = try RepositoryAttentionSession(
            account: account,
            repositoryIdentity: binding.primaryRepository,
            repositoryObject: repository,
            services: services
        )
        session.onOpenAttentionItem = { [weak self] itemID in
            self?.openAttention(itemID)
        }
        attentionSession = session
        guard let destinationRouter else { return }
        attentionController = ForgeAttentionViewController(
            session: session,
            markdownRenderer: ForgeReadNativeMarkdownRenderer(router: destinationRouter),
            avatarRenderer: ForgeReadNativeAvatarRenderer(owner: .account(account.id)),
            destinationRouter: destinationRouter,
            defaultRevision: defaultRevision(),
            pullRequestChangesProvider: RepositoryLocalPullRequestChangesProvider(repository: repository),
            viewStateStore: settings
        )
        session.start()
        Self.logger.notice("Started exact-account GitHub collaboration session")
    }

    private func installPublic(binding: ForgeRepositoryBinding) {
        pullRequestMutationService = nil
        createPullRequestControl = .publicReadOnly(action: "create a Pull Request")
        editPullRequestControl = .publicReadOnly(action: "edit this Pull Request")
        syncForkControl = .publicReadOnly(action: "synchronize this fork")
        installReadSurface(
            binding: binding,
            service: ForgeGitHubAnonymousReadSurfaceService(repository: binding.primaryRepository),
            avatarOwner: .anonymous,
            editPullRequestControl: editPullRequestControl,
            onEditPullRequest: nil
        )
        attentionSession = nil
        attentionController = nil
        Self.logger.notice("Started explicit anonymous GitHub read session")
    }

    private func openAttention(_ itemID: ForgeAttentionItemID) {
        guard itemID.accountID == attentionSession?.account.id else { return }
        show(.attention)
        windowController?.changeContentController(self)
        attentionController?.open(itemID)
    }

    private func installReadSurface(
        binding: ForgeRepositoryBinding,
        service: any ForgeReadSurfaceServing,
        avatarOwner: ForgeAvatarCacheOwner,
        editPullRequestControl: ForgeMutationControlPresentation,
        onEditPullRequest: ((ForgePullRequestEditableSnapshot, ForgeDestination) -> Void)?,
        reviewApplicationSession: RepositoryPullRequestReviewApplicationSession? = nil,
        reviewAccountID: ForgeAccountID? = nil
    ) {
        guard let repository else {
            Self.logger.error("Could not install Forge read surface without its local repository")
            return
        }
        let opener = RepositoryForgeNativeDestinationOpener()
        let router = ForgeCentralDestinationRouter(
            repository: binding.primaryRepository,
            trustedOrigins: composition.forgeExternalLinkPreferences,
            nativeOpener: opener,
            externalOpener: WorkspaceForgeExternalURLOpener(),
            confirmations: AppKitForgeLinkConfirmationPresenter(
                windowProvider: { [weak self] in self?.windowController?.window }
            )
        )
        opener.owner = self
        nativeOpener = opener
        destinationRouter = router
        pullRequestReviewOverlayHost?.detach()
        let reviewOverlayHost: RepositoryPullRequestReviewOverlayHost?
        if let reviewApplicationSession, let reviewAccountID {
            reviewOverlayHost = RepositoryPullRequestReviewOverlayHost(
                applicationSession: reviewApplicationSession,
                accountID: reviewAccountID,
                router: router
            )
        } else {
            reviewOverlayHost = nil
        }
        pullRequestReviewOverlayHost = reviewOverlayHost
        let kind: ForgeReadSurfaceKind = activeSurface == .issues ? .issues : .pullRequests
        readController = ForgeReadSurfaceViewController(
            kind: kind,
            defaultRevision: defaultRevision(),
            service: service,
            markdownRenderer: ForgeReadNativeMarkdownRenderer(router: router),
            avatarRenderer: ForgeReadNativeAvatarRenderer(owner: avatarOwner),
            destinationRouter: router,
            pullRequestChangesProvider: RepositoryLocalPullRequestChangesProvider(repository: repository),
            reviewOverlayHost: reviewOverlayHost,
            viewStateStore: settings,
            editPullRequestControl: editPullRequestControl,
            onEditPullRequest: onEditPullRequest,
            onCheckoutPullRequest: { [weak self] pullRequest in
                self?.windowController?.checkoutPullRequest(pullRequest)
            }
        )
    }

    private func loadRepositoryFacts(
        binding: ForgeRepositoryBinding,
        resolution: ForgeCollaborationAccessResolution
    ) {
        repositoryFactsTask?.cancel()
        repositoryFactsTask = Task { [weak self, services, pullRequestMutationService] in
            do {
                let facts: ForgeRepositoryFacts
                var mutationCapabilities: [ForgeOperation: ForgeOperationCapability] = [:]
                var mutationCapabilityError: Error?
                switch resolution {
                case let .authenticated(account):
                    guard let services else { return }
                    let adapter = try services.githubReadAdapterFactory.makeAdapter(
                        for: account.currentCredential.reference
                    )
                    facts = try await adapter.repositoryFacts(repository: binding.primaryRepository).value
                    guard !Task.isCancelled else { return }
                    if let pullRequestMutationService {
                        do {
                            mutationCapabilities = try await pullRequestMutationService.capabilities(
                                accountID: account.id,
                                repository: binding.primaryRepository,
                                operations: Self.mutationCapabilityOperations
                            )
                        } catch {
                            mutationCapabilityError = error
                        }
                    }
                case .publicAccess:
                    facts = try await ForgeAnonymousReadAdapterPool.shared.repositoryFacts(
                        repository: binding.primaryRepository,
                        reason: .repositoryOpened
                    ).value
                case .requiresExplicitChoice, .browserOnly:
                    return
                }
                guard let self,
                      self.binding == binding,
                      self.accessResolution == resolution,
                      !Task.isCancelled
                else { return }
                self.repositoryFacts = facts
                if let mutationCapabilityError {
                    self.applyMutationCapabilityError(
                        mutationCapabilityError,
                        resolution: resolution
                    )
                } else {
                    self.applyMutationCapabilities(mutationCapabilities, resolution: resolution)
                }
                self.updateSyncForkButton()
                self.publishAccessChange()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.binding == binding,
                      self.accessResolution == resolution
                else { return }
                if case .authenticated = resolution {
                    self.applyMutationCapabilityError(error, resolution: resolution)
                    self.updateSyncForkButton()
                }
                Self.logger.info("Repository relationship metadata remains unavailable")
            }
        }
    }

    private func applyMutationCapabilities(
        _ capabilities: [ForgeOperation: ForgeOperationCapability],
        resolution: ForgeCollaborationAccessResolution
    ) {
        guard case let .authenticated(account) = resolution else { return }
        createPullRequestControl = capabilities[.createPullRequest].map {
            .capability($0, action: "create a Pull Request")
        } ?? .unavailable(
            error: RepositoryPullRequestServiceError.nativeCreationUnavailable,
            action: "create a Pull Request"
        )
        editPullRequestControl = capabilities[.editPullRequest].map {
            .capability($0, action: "edit this Pull Request")
        } ?? .unavailable(
            error: RepositoryPullRequestServiceError.nativeCreationUnavailable,
            action: "edit this Pull Request"
        )
        syncForkControl = capabilities[.syncFork].map {
            .capability($0, action: "synchronize this fork")
        } ?? .unavailable(
            error: RepositoryPullRequestServiceError.nativeCreationUnavailable,
            action: "synchronize this fork"
        )
        readController?.updateEditPullRequestControl(
            editPullRequestControl,
            handler: editPullRequestControl.isEnabled ? editPullRequestHandler(account: account) : nil
        )
    }

    private func applyMutationCapabilityError(
        _ error: Error,
        resolution: ForgeCollaborationAccessResolution
    ) {
        guard case .authenticated = resolution else { return }
        createPullRequestControl = .unavailable(
            error: error,
            action: "create a Pull Request"
        )
        editPullRequestControl = .unavailable(
            error: error,
            action: "edit this Pull Request"
        )
        syncForkControl = .unavailable(
            error: error,
            action: "synchronize this fork"
        )
        readController?.updateEditPullRequestControl(
            editPullRequestControl,
            handler: nil
        )
    }

    private func editPullRequestHandler(
        account: ForgeAccount
    ) -> (ForgePullRequestEditableSnapshot, ForgeDestination) -> Void {
        { [weak self] snapshot, destination in
            guard let self,
                  self.editPullRequestControl.isEnabled,
                  self.accessResolution == .authenticated(account)
            else { return }
            self.windowController?.editPullRequest(
                accountID: account.id,
                snapshot: snapshot,
                destination: destination
            )
        }
    }

    #if DEBUG
        func installReviewOverlayHostForCloseTesting(
            _ host: any RepositoryPullRequestReviewOverlayHosting
        ) {
            pullRequestReviewOverlayHost = host
        }

        var hasReviewOverlayHostForTesting: Bool {
            pullRequestReviewOverlayHost != nil
        }

        func runMutationCapabilityProductProof(
            account: ForgeAccount,
            binding: ForgeRepositoryBinding,
            parent: ForgeRepositoryIdentity,
            snapshot: ForgePullRequestEditableSnapshot,
            destination: ForgeDestination
        ) throws -> Bool {
            self.binding = binding
            accessResolution = .publicAccess
            installPublic(binding: binding)
            let publicReadOnly = !createPullRequestControl.isEnabled
                && !editPullRequestControl.isEnabled
                && !syncForkControl.isEnabled
            let publishedPublicControl = windowController?.createPullRequestControl == createPullRequestControl

            accessResolution = .authenticated(account)
            applyMutationCapabilities([
                .createPullRequest: .verified(.knownAuthority),
                .editPullRequest: .verified(.knownAuthority),
                .syncFork: .verified(.knownAuthority),
            ], resolution: .authenticated(account))
            let enabled = createPullRequestControl.isEnabled
                && editPullRequestControl.isEnabled
                && syncForkControl.isEnabled
            let publishedEnabledControl = windowController?.createPullRequestControl == createPullRequestControl
            editPullRequestHandler(account: account)(snapshot, destination)

            repositoryFacts = try ForgeRepositoryFacts(
                repository: binding.primaryRepository,
                defaultBranch: .available(ForgeRefName("main")),
                description: .available("Capability proof"),
                topics: .available([]),
                visibility: .available(.public),
                isArchived: .available(false),
                forkRelationship: .available(.fork(parent: parent))
            )
            updateSyncForkButton()
            let enabledFork = !syncForkButton.isHidden && syncForkButton.isEnabled

            applyMutationCapabilities([:], resolution: .authenticated(account))
            updateSyncForkButton()
            let missingFailsClosed = !createPullRequestControl.isEnabled
                && !editPullRequestControl.isEnabled
                && !syncForkButton.isEnabled

            applyMutationCapabilityError(
                RepositoryPullRequestServiceError.nativeCreationUnavailable,
                resolution: .authenticated(account)
            )
            let errorFailsClosed = !createPullRequestControl.isEnabled
                && !editPullRequestControl.isEnabled
                && !syncForkControl.isEnabled
            let publishedErrorControl = windowController?.createPullRequestControl == createPullRequestControl
            applyMutationCapabilities([
                .createPullRequest: .verified(.knownAuthority),
                .editPullRequest: .verified(.knownAuthority),
                .syncFork: .verified(.knownAuthority),
            ], resolution: .publicAccess)
            return publicReadOnly && publishedPublicControl
                && enabled && publishedEnabledControl && enabledFork
                && missingFailsClosed && errorFailsClosed && publishedErrorControl
        }
    #endif

    private func renderActiveSurface() {
        guard isViewLoaded else { return }
        switch accessResolution {
        case .authenticated:
            if activeSurface == .attention, let attentionController {
                mount(attentionController)
            } else if let readController {
                readController.show(kind: activeSurface == .issues ? .issues : .pullRequests)
                mount(readController)
            }
        case .publicAccess:
            if activeSurface == .attention {
                renderGateway(
                    title: "Attention Requires a GitHub Account",
                    message: "Choose an exact GitHub account above. Anonymous mode has no background polling, alerts, or mutations."
                )
            } else if let readController {
                readController.show(kind: activeSurface == .issues ? .issues : .pullRequests)
                mount(readController)
            }
        case let .requiresExplicitChoice(_, preferredUnavailable):
            renderGateway(
                title: preferredUnavailable ? "Preferred GitHub Account Unavailable" : "Choose a GitHub Account",
                message: "Choose the exact account for this repository, or explicitly Continue Publicly for public read-only access."
            )
        case .browserOnly:
            let stack = renderGateway(
                title: "Open on the Git Host",
                message: "Native collaboration reads are limited to GitHub.com. This repository remains available through validated browser links."
            )
            let button = NSButton(
                title: "Open Repository in Browser",
                target: self,
                action: #selector(openBoundRepositoryInBrowser(_:))
            )
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("ForgeCollaborationOpenRepositoryInBrowser")
            stack.addArrangedSubview(button)
        case nil:
            renderGateway(
                title: "Loading GitHub Collaboration…",
                message: "GitX is resolving the stable repository binding and exact account."
            )
        }
    }

    private func mount(_ controller: NSViewController) {
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }
        if mountedController !== controller {
            mountedController?.removeFromParent()
            addChild(controller)
            mountedController = controller
        }
        controller.view.frame = contentContainer.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(controller.view)
    }

    @discardableResult
    private func renderGateway(title: String, message: String) -> NSStackView {
        guard isViewLoaded else { return NSStackView() }
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        heading.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 4
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("ForgeCollaborationGateway")
        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -80),
        ])
        return stack
    }

    private func updateAccountBar(error: String? = nil) {
        guard isViewLoaded else { return }
        let matching = matchingAccounts()
        accountPopup.removeAllItems()
        accountPopup.addItems(withTitles: matching.map(\.login))
        for (index, account) in matching.enumerated() {
            accountPopup.item(at: index)?.representedObject = account.id.value
        }
        if case let .authenticated(account) = accessResolution,
           let index = matching.firstIndex(where: { $0.id == account.id })
        {
            accountPopup.selectItem(at: index)
        }
        let github = binding.map { ForgeCollaborationAccessPolicy.isGitHubDotCom($0.primaryRepository.forge) } == true
        providerTitleLabel.stringValue = binding.map {
            Self.providerName($0.primaryRepository.forge.kind)
        } ?? "Forge"
        accountPopup.isHidden = !github || matching.isEmpty
        accountPopup.isEnabled = github && !matching.isEmpty
        accountsButton.isHidden = !github
        accountsButton.isEnabled = github
        publicButton.isHidden = !github || accessResolution == .publicAccess
        publicButton.isEnabled = github
        updateSyncForkButton()
        if let error {
            statusLabel.stringValue = "Forge data unavailable — \(error)"
        } else {
            statusLabel.stringValue = switch accessResolution {
            case let .authenticated(account): "Using @\(account.login)"
            case .publicAccess: "Public read-only — no polling or mutations"
            case let .requiresExplicitChoice(_, preferredUnavailable):
                preferredUnavailable ? "Preferred account is unavailable" : "Account choice required"
            case .browserOnly: "Browser links only"
            case nil: "Resolving repository access…"
            }
        }
    }

    private func defaultRevision() -> ForgeRevision {
        if let branch = repository?.headRef()?.ref(), branch.isBranch,
           let name = try? ForgeRefName(branch.shortName())
        {
            return .branch(name)
        }
        if let name = try? ForgeRefName("main") {
            return .branch(name)
        }
        preconditionFailure("The static default branch name must remain valid")
    }

    private func matchingAccounts() -> [ForgeAccount] {
        guard let binding else { return [] }
        return accounts
            .filter { $0.id.forge == binding.primaryRepository.forge }
            .sorted { lhs, rhs in
                if lhs.login != rhs.login {
                    return lhs.login.localizedStandardCompare(rhs.login) == .orderedAscending
                }
                return lhs.id.value < rhs.id.value
            }
    }

    private func updateSyncForkButton() {
        guard case .authenticated = accessResolution,
              case let .available(relationship) = repositoryFacts?.forkRelationship,
              case .fork = relationship,
              case .available = repositoryFacts?.defaultBranch
        else {
            syncForkButton.isHidden = true
            syncForkButton.isEnabled = false
            return
        }
        syncForkButton.isHidden = false
        syncForkButton.isEnabled = syncForkControl.isEnabled
        syncForkButton.toolTip = syncForkControl.helpText
        syncForkButton.setAccessibilityHelp(syncForkControl.helpText)
    }

    private static func providerName(_ kind: ForgeKind) -> String {
        switch kind {
        case .github: "GitHub"
        case .gitLab: "GitLab"
        case .bitbucket: "Bitbucket"
        }
    }

    private func publishAccessChange() {
        let login: String? = if case let .authenticated(account) = accessResolution {
            account.login
        } else {
            nil
        }
        let isPublic = accessResolution == .publicAccess
        var userInfo: [AnyHashable: Any] = [
            RepositoryForgeAccountNotificationKey.isPublic: isPublic,
            RepositoryForgeAccountNotificationKey.accounts: matchingAccounts().map {
                RepositoryForgeAccountChoice(id: $0.id, login: $0.login).notificationValue
            },
        ]
        if let binding {
            userInfo[RepositoryForgeAccountNotificationKey.providerName] = Self.providerName(
                binding.primaryRepository.forge.kind
            )
        }
        if case let .authenticated(account) = accessResolution {
            userInfo[RepositoryForgeAccountNotificationKey.accountID] = account.id
        }
        if let login {
            userInfo[RepositoryForgeAccountNotificationKey.login] = login
        }
        NotificationCenter.default.post(
            name: .repositoryForgeAccountDidChange,
            object: repository,
            userInfo: userInfo
        )
    }

    @objc private func accountChanged(_ sender: NSPopUpButton) {
        guard let binding,
              accounts.indices.contains(sender.indexOfSelectedItem)
        else { return }
        let matching = matchingAccounts()
        guard matching.indices.contains(sender.indexOfSelectedItem) else { return }
        let account = matching[sender.indexOfSelectedItem]
        do {
            let updated = try ForgeRepositoryBinding(
                localRemoteName: binding.localRemoteName,
                primaryRepository: binding.primaryRepository,
                preferredAccount: account.id
            )
            settings.forgeRepositoryBinding = updated
            explicitAccountID = account.id
            explicitlyContinuesPublicly = false
            self.binding = updated
            applyAccess(binding: updated)
        } catch {
            windowController?.showErrorSheet(error)
        }
    }

    @objc private func continuePublicly(_: Any?) {
        explicitAccountID = nil
        explicitlyContinuesPublicly = true
        guard let binding else { return }
        applyAccess(binding: binding)
    }

    @objc private func openAccountsPreferences(_: Any?) {
        RepositoryForgeAccountsPreferencesRouting.prepare()
        if !NSApp.sendAction(NSSelectorFromString("openPreferencesWindow:"), to: nil, from: self) {
            NSSound.beep()
        }
    }

    @objc private func syncFork(_: Any?) {
        guard syncForkControl.isEnabled,
              let binding,
              case let .authenticated(account) = accessResolution,
              case let .available(relationship) = repositoryFacts?.forkRelationship,
              case let .fork(parent) = relationship,
              case let .available(branch) = repositoryFacts?.defaultBranch,
              let plan = try? ForgeSyncForkPlan(
                  fork: binding.primaryRepository,
                  parent: parent,
                  branch: branch,
                  localFetchRemoteName: binding.localRemoteName
              )
        else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sync Fork from Parent?"
        alert.informativeText = "GitHub will update \(branch.value) on the fork, then GitX will fetch \(binding.localRemoteName)/\(branch.value). Your checkout will not be changed."
        alert.addButton(withTitle: "Sync Fork")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.setAccessibilityIdentifier("GitX.SyncFork.Confirm")
        windowController?.confirmDialog(alert, suppressionIdentifier: nil) { [weak self] in
            self?.windowController?.syncFork(accountID: account.id, plan: plan)
        }
    }

    @objc private func openBoundRepositoryInBrowser(_: Any?) {
        guard case let .route(route) = forgeCoordinator.resolve(.repository) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(route.browserURL)
    }

    @objc private func accountsDidChange(_: Notification) {
        reloadAccess(resetPublicChoice: true)
    }
}
#endif
// swiftformat:enable indent
