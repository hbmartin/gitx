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

    func updateDefaultRevision(_ revision: ForgeRevision)

    func detach()
}

extension RepositoryPullRequestReviewOverlayHosting {
    func updateDefaultRevision(_: ForgeRevision) {}
}

@MainActor
final class ForgeReadSurfaceViewController: NSSplitViewController {
    private let service: any ForgeReadSurfaceServing
    private let markdownRenderer: any ForgeReadMarkdownRendering
    private let avatarRenderer: any ForgeReadAvatarRendering
    private let destinationRouter: any ForgeReadDestinationRouting
    private let reviewOverlayHost: (any RepositoryPullRequestReviewOverlayHosting)?
    private let authorizationRecoveryHandler: ((Error, @escaping @MainActor () -> Void) -> Void)?
    private var defaultRevision: ForgeRevision
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
        onCheckoutPullRequest: ((ForgePullRequestSummary) -> Void)? = nil,
        authorizationRecoveryHandler: ((Error, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.service = service
        self.markdownRenderer = markdownRenderer
        self.avatarRenderer = avatarRenderer
        self.destinationRouter = destinationRouter
        self.reviewOverlayHost = reviewOverlayHost
        self.authorizationRecoveryHandler = authorizationRecoveryHandler
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

    func updateDefaultRevision(_ revision: ForgeRevision) {
        guard defaultRevision != revision else { return }
        defaultRevision = revision
        inspectorController.updateDefaultRevision(revision)
        reviewOverlayHost?.updateDefaultRevision(revision)
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
                    logger.error("Forge list refresh failed type=\(String(describing: type(of: error)), privacy: .public)")
                    renderList()
                    if !invalidatesSelection {
                        retainSelectedInspectorAfterRefreshFailure(error.localizedDescription)
                    }
                    authorizationRecoveryHandler?(error) { [weak self] in
                        self?.reload(kind: request.kind, query: request.query)
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
                    logger.error("Forge pagination failed type=\(String(describing: type(of: error)), privacy: .public)")
                    renderList()
                    authorizationRecoveryHandler?(error) { [weak self] in
                        self?.loadNextPage()
                    }
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
                logger.error("Forge inspector load failed type=\(String(describing: type(of: error)), privacy: .public)")
                if !retainStaleDetailsAfterRefreshFailure(
                    error.localizedDescription,
                    item: item,
                    preservingCurrentSnapshot: preservingCurrentSnapshot
                ) {
                    inspectorController.showError(error.localizedDescription, item: item)
                }
                authorizationRecoveryHandler?(error) { [weak self] in
                    self?.loadDetails(
                        for: item,
                        rowNumber: ForgeReadSurfaceRow(item: item).number,
                        preservingCurrentSnapshot: true
                    )
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
                logger.error("Forge inspector continuation failed type=\(String(describing: type(of: error)), privacy: .public)")
                authorizationRecoveryHandler?(error) { [weak self] in
                    self?.loadMoreDetails(continuation)
                }
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
        ForgeReadDateFormatting.dateAndTime(date)
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
        case "Unknown": .secondaryLabelColor
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
        ForgeReadDateFormatting.date(date)
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
    private var defaultRevision: ForgeRevision
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

    func updateDefaultRevision(_ revision: ForgeRevision) {
        guard defaultRevision != revision else { return }
        defaultRevision = revision
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
              case let .available(headValue) = summary.head,
              let head = headValue.reference,
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
        ForgeReadDateFormatting.dateAndTime(date)
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
final class ForgeReadSnowLeopardBarView: NSView {
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
