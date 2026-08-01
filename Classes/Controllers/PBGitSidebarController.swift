import AppKit
import ForgeKit // swiftlint:disable:this unused_import
import GitXCore
import OSLog // swiftlint:disable:this unused_import

private let sidebarCellIdentifier = NSUserInterfaceItemIdentifier("PBSidebarCellIdentifier")
private let branchesHeaderCellIdentifier = NSUserInterfaceItemIdentifier("PBBranchesHeaderCellIdentifier")
private let forgeAttentionBadgeIdentifier = NSUserInterfaceItemIdentifier("PBForgeAttentionBadgeIdentifier")

private enum RepositoryForgeSidebarDestination: Equatable {
    case surface(ForgeCollaborationSurface)
    case chooseBinding
}

private final nonisolated class RepositoryForgeSourceViewItem: PBSourceViewItem {
    let destination: RepositoryForgeSidebarDestination?
    private let itemIcon: NSImage?
    var accessibilityLabel: String

    nonisolated init(
        title: String,
        destination: RepositoryForgeSidebarDestination? = nil,
        symbolName: String,
        accessibilityLabel: String
    ) {
        self.destination = destination
        itemIcon = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        self.accessibilityLabel = accessibilityLabel
        super.init(title: title, revSpecifier: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepositoryForgeSourceViewItem does not support coding")
    }

    override nonisolated var icon: NSImage? {
        itemIcon
    }
}

/// Owns the repository source-list wiring while delegating sorting and filtering decisions to value types.
@objc(PBGitSidebarController)
open class PBGitSidebarController: PBViewController, NSMenuDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate { // swiftlint:disable:this type_body_length
    private enum RemoteSegment: Int {
        case add = 0
        case fetch = 1
        case pull = 2
        case push = 3
    }

    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositorySidebar")

    @IBOutlet private weak var window: NSWindow?
    @IBOutlet open private(set) dynamic weak var sourceView: NSOutlineView?
    @IBOutlet public private(set) dynamic weak var sourceListControlsView: NSView?
    @IBOutlet private weak var actionButton: NSPopUpButton?
    @IBOutlet private weak var remoteControls: NSSegmentedControl?

    private let mutableItems = NSMutableArray()
    @objc private dynamic var branches: PBSourceViewItem?
    @objc open private(set) dynamic var remotes: PBSourceViewItem?
    @objc private dynamic var tags: PBSourceViewItem?
    @objc private dynamic var others: PBSourceViewItem?
    @objc private dynamic var submodules: PBSourceViewItem?
    @objc private dynamic var stashes: PBSourceViewItem?
    @objc private dynamic var forgeGroup: PBSourceViewItem?
    private var forgeRepositoryItems: [RepositoryForgeSourceViewItem] = []
    private var forgeSurfaceItems: [ForgeCollaborationSurface: RepositoryForgeSourceViewItem] = [:]
    private var collaborationController: RepositoryForgeCollaborationController?
    #if DEBUG
        final var productProofForgeDestinationOpening: ((ForgeDestination) -> Bool)?
    #endif
    private var unseenAttentionCount = 0
    @objc private dynamic var branchPresentation: BranchSidebarPresentation?
    @objc private dynamic var lastKnownHeadRef: PBGitRevSpecifier?

    private var currentBranchObservation: NSKeyValueObservation?
    private var branchesObservation: NSKeyValueObservation?
    private var refsObservation: NSKeyValueObservation?
    private var stashesObservation: NSKeyValueObservation?

    @objc open dynamic var items: NSMutableArray {
        mutableItems
    }

    @objc(initWithRepository:superController:)
    override public init?(repository: PBGitRepository, superController controller: PBGitWindowController?) {
        super.init(repository: repository, superController: controller)
        branchPresentation = BranchSidebarPresentation(repository: repository)
    }

    override public init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("PBGitSidebarController must be initialized with a repository")
    }

    override open nonisolated func awakeFromNib() {
        super.awakeFromNib()
        // swift6-safety-justification: AppKit invokes awakeFromNib on the main thread while loading this controller's XIB.
        MainActor.assumeIsolated {
            finishAwakingFromNib()
        }
    }

    private func finishAwakingFromNib() {
        window?.contentView = view
        sourceView?.setAccessibilityIdentifier("RepositorySidebar")
        if let repository, let windowController {
            collaborationController = RepositoryForgeCollaborationController(
                repository: repository,
                superController: windowController
            )
            collaborationController?.prepare()
        }
        populateList()

        guard let repository else { return }
        lastKnownHeadRef = repository.headRef()
        installRepositoryObservations(repository)

        sourceView?.target = self
        sourceView?.doubleAction = #selector(doubleClicked(_:))
        if let menu = actionButton?.menu {
            menuNeedsUpdate(menu)
        }
        selectCurrentBranch()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(expandCollapseItem(_:)),
            name: NSOutlineView.itemWillExpandNotification,
            object: sourceView
        )
        center.addObserver(
            self,
            selector: #selector(expandCollapseItem(_:)),
            name: NSOutlineView.itemWillCollapseNotification,
            object: sourceView
        )
        center.addObserver(
            self,
            selector: #selector(repositorySettingsDidChange(_:)),
            name: .repositorySettingsDidChange,
            object: repository
        )
        center.addObserver(
            self,
            selector: #selector(repositorySettingsDidChange(_:)),
            name: .branchSidebarSettingsDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(forgeAccessDidChange(_:)),
            name: .repositoryForgeAccountDidChange,
            object: repository
        )
        center.addObserver(
            self,
            selector: #selector(attentionUnseenDidChange(_:)),
            name: .repositoryAttentionUnseenDidChange,
            object: repository
        )
    }

    isolated deinit {
        collaborationController?.closeView()
        NotificationCenter.default.removeObserver(self)
    }

    private nonisolated static func performRepositoryObservationOnMain(
        _ body: @escaping @MainActor @Sendable () -> Void
    ) {
        if Thread.isMainThread {
            // swift6-safety-justification: The main-thread check proves synchronous execution is on MainActor's AppKit executor.
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in
                body()
            }
        }
    }

    private func installRepositoryObservations(_ repository: PBGitRepository) {
        currentBranchObservation = repository.observe(\.currentBranch, options: []) { [weak self] _, _ in
            Self.performRepositoryObservationOnMain { [weak self] in
                guard let self else { return }
                let selectedRow = self.sourceView?.selectedRow
                self.sourceView?.reloadData()
                if let selectedRow, selectedRow >= 0 {
                    self.sourceView?.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                }
                self.selectCurrentBranch()
            }
        }
        branchesObservation = repository.observe(\.branches, options: [.old, .new]) { [weak self] _, _ in
            Self.performRepositoryObservationOnMain { [weak self] in
                self?.reloadSidebarPresentation()
            }
        }
        refsObservation = repository.observe(\.refs, options: []) { [weak self] _, _ in
            Self.performRepositoryObservationOnMain { [weak self] in
                self?.reloadSidebarAfterReferencesChange()
            }
        }
        stashesObservation = repository.observe(\.stashes, options: []) { [weak self] _, _ in
            Self.performRepositoryObservationOnMain { [weak self] in
                self?.reloadStashes()
            }
        }
    }

    private func reloadStashes() {
        guard let stashes, let repository else { return }
        for item in stashes.sortedChildren {
            stashes.removeChild(item)
        }
        for stash in repository.stashes {
            stashes.addChild(PBSourceViewGitStashItem(stash: stash))
        }
        sourceView?.expandItem(stashes)
        sourceView?.reloadItem(stashes, reloadChildren: true)
    }

    @objc(repositorySettingsDidChange:)
    dynamic func repositorySettingsDidChange(_ notification: Notification) {
        reloadSidebarPresentation()
    }

    @objc dynamic func reloadSidebarPresentation() {
        let selectedForgeSurface = selectedForgeSurface()
        let viewedRevision = repository?.currentBranch
        populateList()
        if restoreForgeSelection(selectedForgeSurface) {
            return
        }
        if let viewedRevision, let item = item(for: viewedRevision) {
            expandItemAndParents(item)
            select(item)
        } else {
            selectCurrentBranch()
        }
    }

    @objc(showForgeAttention:)
    // AppKit dispatches this target/action selector through the responder chain.
    // swiftlint:disable:next unused_declaration
    dynamic func showForgeAttention(_ sender: Any?) {
        showForgeSurface(.attention)
    }

    @objc dynamic func selectedItem() -> PBSourceViewItem? {
        guard let sourceView else { return nil }
        return sourceView.item(atRow: sourceView.selectedRow) as? PBSourceViewItem
    }

    @objc open dynamic func selectCurrentBranch() {
        guard let repository else { return }
        guard let revision = repository.currentBranch else {
            repository.reloadRefs()
            repository.readCurrentBranch()
            return
        }

        dispatchPrecondition(condition: .onQueue(.main))
        if let item = add(revision: revision), let sourceView {
            expandItemAndParents(item)
            let row = sourceView.row(forItem: item)
            if row >= 0 {
                sourceView.deselectAll(nil)
                sourceView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    @objc(itemForRev:)
    dynamic func item(for revision: PBGitRevSpecifier) -> PBSourceViewItem? {
        for case let item as PBSourceViewItem in mutableItems {
            if let found = item.findRev(revision) {
                return found
            }
        }
        return nil
    }

    @objc(addRevSpec:)
    dynamic func add(revision: PBGitRevSpecifier) -> PBSourceViewItem? { // swiftlint:disable:this cyclomatic_complexity
        if let existing = item(for: revision) {
            return existing
        }

        let simpleReference = revision.isSimpleRef ? revision.simpleRef() : nil
        let plan = SidebarRevisionPolicy.plan(
            simpleReference: simpleReference,
            shouldShowBranch: branchPresentation?.shouldShow(revision: revision) ?? true,
            usesRecentBranchSorting: branchPresentation?.usesRecentSorting ?? false
        )
        let item: PBSourceViewItem?
        switch plan.placement {
        case .other:
            item = PBSourceViewItem(revSpec: revision)
            others?.addChild(item)
            return item
        case .branchRoot:
            item = PBSourceViewItem(revSpec: revision)
            if simpleReference?.hasPrefix("refs/heads/") == true,
               branchPresentation?.usesRecentSorting == true
            {
                if let shortName = item?.ref()?.shortName() {
                    item?.title = shortName
                }
            }
            branches?.addChild(item)
        case .branchPath:
            branches?.addRev(revision, toPath: plan.path)
            item = nil
        case .tagPath:
            tags?.addRev(revision, toPath: plan.path)
            item = nil
        case .remotePath:
            remotes?.addRev(revision, toPath: plan.path)
            item = nil
        case .hidden:
            return nil
        case .unsupported:
            item = nil
        }
        return item ?? self.item(for: revision)
    }

    @objc dynamic func reloadSidebarAfterReferencesChange() {
        guard let repository else { return }
        let selectedForgeSurface = selectedForgeSurface()
        var viewedRevision = repository.currentBranch
        let newHead = repository.headRef()
        let followHead = HistoryRefreshSelectionPolicy.shouldFollowCheckedOutBranch(
            stageSelected: false,
            viewedRef: viewedRevision?.simpleRef(),
            previousHeadRef: lastKnownHeadRef?.simpleRef()
        )
        if followHead, let newHead, viewedRevision?.isEqual(newHead) != true {
            repository.currentBranch = newHead
            viewedRevision = newHead
        }

        populateList()
        if !restoreForgeSelection(selectedForgeSurface),
           let viewedRevision,
           let item = item(for: viewedRevision)
        {
            expandItemAndParents(item)
            select(item)
        }

        let previousHeadName = lastKnownHeadRef?.simpleRef() ?? "(none)"
        let newHeadName = newHead?.simpleRef() ?? "(none)"
        Self.logger.info(
            "Refreshed sidebar refs: HEAD \(previousHeadName, privacy: .public) -> \(newHeadName, privacy: .public), followed=\(followHead, privacy: .public)"
        )
        lastKnownHeadRef = newHead
    }

    @objc private dynamic func synchronizeConfiguredRemotes() {
        guard let remotes, let repository else { return }
        let remoteItems = remotes.sortedChildren
        var nonEmptyNames: [String] = []
        var itemsByName: [String: PBSourceViewItem] = [:]
        for item in remoteItems where item is PBSourceViewGitRemoteItem {
            itemsByName[item.title] = item
            if !item.sortedChildren.isEmpty {
                nonEmptyNames.append(item.title)
            }
        }

        let plan = SidebarRemotePolicy.syncPlan(
            configuredRemoteNames: repository.remotes() ?? [],
            existingRemoteNames: Array(itemsByName.keys),
            nonEmptyRemoteNames: nonEmptyNames
        )
        for name in plan.namesToAdd {
            remotes.addChild(PBSourceViewGitRemoteItem(title: name, revSpecifier: nil))
        }
        for name in plan.namesToRemove {
            remotes.removeChild(itemsByName[name])
        }
        if !plan.namesToAdd.isEmpty || !plan.namesToRemove.isEmpty {
            Self.logger.info(
                "Synchronized configured remotes: added=\(plan.namesToAdd, privacy: .public) removed=\(plan.namesToRemove, privacy: .public)"
            )
        }
    }

    @objc(removeRevSpec:)
    // swiftlint:disable:next unused_declaration -- Objective-C compatibility selector exercised by app-hosted tests.
    dynamic func remove(revision: PBGitRevSpecifier) {
        guard let item = item(for: revision) else { return }
        item.parent?.removeChild(item)
        sourceView?.reloadData()
    }

    @objc(openSubmoduleFromMenuItem:)
    dynamic func openSubmodule(from menuItem: NSMenuItem) {
        guard let url = menuItem.representedObject as? URL else { return }
        openSubmodule(at: url)
    }

    @objc(openSubmoduleAtURL:)
    dynamic func openSubmodule(at url: URL) {
        RepositoryOpenCoordinator.shared.open(
            urls: [url],
            sourceWindow: windowController?.window
        ) { _, errors in
            for error in errors {
                self.windowController?.showErrorSheet(error)
            }
        }
    }

    private func expandItemAndParents(_ item: PBSourceViewItem) {
        sourceView?.pbExpandItem(item, expandParents: true)
    }

    private func select(_ item: PBSourceViewItem) {
        guard let sourceView else { return }
        let row = sourceView.row(forItem: item)
        if row >= 0 {
            sourceView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func selectedForgeSurface() -> ForgeCollaborationSurface? {
        guard let item = selectedItem() as? RepositoryForgeSourceViewItem,
              case let .surface(surface) = item.destination
        else { return nil }
        return surface
    }

    @discardableResult
    private func restoreForgeSelection(_ surface: ForgeCollaborationSurface?) -> Bool {
        guard let surface, let item = forgeSurfaceItems[surface] else { return false }
        expandItemAndParents(item)
        select(item)
        return true
    }

    private func forgeGroupTitle() -> String {
        guard let repository else { return "Forge" }
        return RepositoryForgeCoordinator(repository: repository).resolveBinding().providerName ?? "Forge"
    }

    private func populateForgeGroup(_ group: PBSourceViewItem) {
        guard let repository else { return }
        let coordinator = RepositoryForgeCoordinator(repository: repository)
        let resolution = coordinator.resolveBinding()
        guard let binding = resolution.binding else {
            if resolution.kind == .requiresChoice {
                let choice = RepositoryForgeSourceViewItem(
                    title: "Choose Primary Repository…",
                    destination: .chooseBinding,
                    symbolName: "point.3.connected.trianglepath.dotted",
                    accessibilityLabel: "Choose Primary Forge Repository"
                )
                group.addChild(choice)
                forgeRepositoryItems = [choice]
            }
            return
        }

        var presentations = collaborationController?.sidebarRepositories ?? []
        if presentations.isEmpty {
            presentations = RepositoryForgeSidebarPresenter.repositories(
                binding: binding,
                candidates: coordinator.sidebarCandidates(),
                accountLogin: collaborationController?.currentAccountLogin
            )
        }
        for presentation in presentations {
            let repositoryItem = RepositoryForgeSourceViewItem(
                title: presentation.detailText,
                symbolName: presentation.isPrimary ? "externaldrive.connected.to.line.below" : "network",
                accessibilityLabel: "\(presentation.repositoryName), \(presentation.relationships.map(\.rawValue).joined(separator: ", "))"
            )
            group.addChild(repositoryItem)
            forgeRepositoryItems.append(repositoryItem)
            guard presentation.isPrimary else { continue }
            let surfaces = collaborationController?.availableSidebarSurfaces
                ?? [.pullRequests, .issues]
            for surface in surfaces {
                let presentation = surface == .attention
                    ? RepositoryAttentionUnseenPresenter.present(count: unseenAttentionCount)
                    : nil
                let item = RepositoryForgeSourceViewItem(
                    title: surface.displayName,
                    destination: .surface(surface),
                    symbolName: Self.forgeSymbol(surface),
                    accessibilityLabel: presentation?.sidebarAccessibilityLabel ?? surface.displayName
                )
                repositoryItem.addChild(item)
                forgeSurfaceItems[surface] = item
            }
        }
    }

    private static func forgeSymbol(_ surface: ForgeCollaborationSurface) -> String {
        switch surface {
        case .pullRequests: "arrow.triangle.pull"
        case .issues: "exclamationmark.circle"
        case .attention: "bell"
        }
    }

    private func showForgeSurface(_ surface: ForgeCollaborationSurface) {
        guard let collaborationController else { return }
        collaborationController.show(surface)
        windowController?.changeContentController(collaborationController)
        if let item = forgeSurfaceItems[surface] {
            expandItemAndParents(item)
            select(item)
        }
    }

    @discardableResult
    @inline(never)
    func openForgeDestination(_ destination: ForgeDestination) -> Bool {
        #if DEBUG
            let opened: Bool
            if let productProofForgeDestinationOpening {
                opened = productProofForgeDestinationOpening(destination)
            } else {
                opened = collaborationController?.openNative(destination) == true
            }
        #else
            let opened = collaborationController?.openNative(destination) == true
        #endif
        guard opened else { return false }
        if case .pullRequest = destination {
            restoreForgeSelection(.pullRequests)
        } else if case .issue = destination {
            restoreForgeSelection(.issues)
        }
        return true
    }

    private func chooseForgeBinding() {
        guard let repository else { return }
        let coordinator = RepositoryForgeCoordinator(repository: repository)
        let resolution = coordinator.resolveBinding()
        guard resolution.kind == .requiresChoice else { return }
        let presenter = AppKitRepositoryForgeLinkAlertPresenter(
            windowProvider: { [weak self] in self?.windowController?.window },
            errorPresentation: { [weak self] error in self?.windowController?.showErrorSheet(error) }
        )
        presenter.chooseBinding(from: resolution.candidates) { [weak self] candidate in
            guard let self, let candidate else { return }
            do {
                _ = try coordinator.select(candidate: candidate)
                self.collaborationController?.repositoryBindingDidChange()
                self.populateList()
            } catch {
                self.windowController?.showErrorSheet(error)
            }
        }
    }

    @objc private func forgeAccessDidChange(_: Notification) {
        let selectedDestination = (selectedItem() as? RepositoryForgeSourceViewItem)?.destination
        populateList()
        if case let .surface(surface) = selectedDestination,
           let item = forgeSurfaceItems[surface]
        {
            expandItemAndParents(item)
            select(item)
        } else if case .surface = selectedDestination,
                  let fallback = collaborationController?.availableSidebarSurfaces.first,
                  let item = forgeSurfaceItems[fallback]
        {
            expandItemAndParents(item)
            select(item)
        }
    }

    @objc private func attentionUnseenDidChange(_ notification: Notification) {
        unseenAttentionCount = max(
            0,
            notification.userInfo?[RepositoryAttentionNotificationKey.count] as? Int ?? 0
        )
        guard let item = forgeSurfaceItems[.attention] else { return }
        item.accessibilityLabel = RepositoryAttentionUnseenPresenter.present(
            count: unseenAttentionCount
        ).sidebarAccessibilityLabel
        sourceView?.reloadItem(item)
    }

    @objc private dynamic func populateList() {
        guard let repository else { return }
        if branchPresentation == nil {
            branchPresentation = BranchSidebarPresentation(repository: repository)
        }
        branchPresentation?.reload()
        mutableItems.removeAllObjects()

        let project = PBSourceViewItem.groupItem(withTitle: repository.projectName() ?? "")
        project.isUncollapsible = true
        let branches = PBSourceViewItem.groupItem(withTitle: "Branches")
        let remotes = PBSourceViewItem.groupItem(withTitle: "Remotes")
        let tags = PBSourceViewItem.groupItem(withTitle: "Tags")
        let stashes = PBSourceViewItem.groupItem(withTitle: "Stashes")
        let submodules = PBSourceViewItem.groupItem(withTitle: "Submodules")
        let others = PBSourceViewItem.groupItem(withTitle: "Other")
        let forgeGroup = PBSourceViewItem.groupItem(withTitle: forgeGroupTitle())
        self.branches = branches
        self.remotes = remotes
        self.tags = tags
        self.stashes = stashes
        self.submodules = submodules
        self.others = others
        self.forgeGroup = forgeGroup
        forgeRepositoryItems = []
        forgeSurfaceItems = [:]
        populateForgeGroup(forgeGroup)

        for stash in repository.stashes {
            stashes.addChild(PBSourceViewGitStashItem(stash: stash))
        }
        for revision in repository.branches {
            _ = add(revision: revision)
        }
        synchronizeConfiguredRemotes()
        for rawSubmodule in repository.submodules {
            // swift6-safety-justification: NSMutableArray erases its generic; this preserves Objective-C's
            // message-compatible handling of GTSubmodule test doubles and legacy subclasses with reference-sized objects.
            let submodule = unsafeBitCast(rawSubmodule as AnyObject, to: GTSubmodule.self)
            submodules.addChild(PBSourceViewGitSubmoduleItem(submodule: submodule))
        }

        let settings = RepositoryUISettings(repository: repository)
        mutableItems.add(project)
        if !forgeRepositoryItems.isEmpty {
            mutableItems.add(forgeGroup)
        }
        mutableItems.add(branches)
        if settings.isSidebarGroupVisible("Remotes") {
            mutableItems.add(remotes)
        }
        if settings.isSidebarGroupVisible("Tags") {
            mutableItems.add(tags)
        }
        if settings.isSidebarGroupVisible("Stashes") {
            mutableItems.add(stashes)
        }
        if settings.isSidebarGroupVisible("Submodules") {
            mutableItems.add(submodules)
        }
        if settings.isSidebarGroupVisible("Other") {
            mutableItems.add(others)
        }

        sourceView?.reloadData()
        sourceView?.expandItem(project)
        sourceView?.expandItem(forgeGroup, expandChildren: true)
        sourceView?.expandItem(branches, expandChildren: true)
        sourceView?.expandItem(remotes)
        sourceView?.expandItem(stashes)
        sourceView?.expandItem(submodules)
        sourceView?.reloadItem(nil, reloadChildren: true)
    }
}

public extension PBGitSidebarController {
    @objc dynamic func outlineViewSelectionDidChange(_ notification: Notification) {
        if let forgeItem = selectedItem() as? RepositoryForgeSourceViewItem,
           let destination = forgeItem.destination
        {
            switch destination {
            case let .surface(surface):
                showForgeSurface(surface)
            case .chooseBinding:
                chooseForgeBinding()
            }
        } else if let item = selectedItem(), let revision = item.revSpecifier {
            if repository?.currentBranch?.isEqual(revision) != true {
                repository?.currentBranch = revision
            }
            if let history = windowController?.historyViewController {
                windowController?.changeContentController(history)
            }
        }
        updateActionMenu()
        updateRemoteControls()
    }

    @objc internal dynamic func doubleClicked(_ sender: Any?) {
        guard let item = selectedItem() else { return }
        if let submodule = item as? PBSourceViewGitSubmoduleItem {
            openSubmodule(at: submodule.path)
        } else if let branch = item as? PBSourceViewGitBranchItem, let ref = branch.ref() {
            do {
                _ = try repository?.checkoutRefish(ref)
            } catch {
                windowController?.showErrorSheet(error)
            }
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldEdit tableColumn: NSTableColumn?,
        item: Any
    ) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? PBSourceViewItem)?.isGroupItem ?? false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let item = item as? PBSourceViewItem else { return nil }
        if item === branches {
            let header = (outlineView.makeView(withIdentifier: branchesHeaderCellIdentifier, owner: self) as? NSTableCellView)
                ?? makeBranchesHeader(for: outlineView)
            configureBranchesHeader(header)
            return header
        }

        guard let cell = outlineView.makeView(
            withIdentifier: sidebarCellIdentifier,
            owner: outlineView
        ) as? PBSidebarTableViewCell else { return nil }
        cell.textField?.stringValue = item.title
        cell.imageView?.image = item.icon
        cell.isCheckedOut = item.revSpecifier?.isEqual(repository?.headRef()) == true
        configureForgeCell(cell, item: item)
        return cell
    }

    private func configureForgeCell(_ cell: PBSidebarTableViewCell, item: PBSourceViewItem) {
        let forgeItem = item as? RepositoryForgeSourceViewItem
        cell.setAccessibilityIdentifier(forgeItem == nil ? nil : "RepositoryForgeSidebarItem")
        cell.setAccessibilityLabel(forgeItem?.accessibilityLabel)
        var badge = cell.subviews.first {
            $0.identifier == forgeAttentionBadgeIdentifier
        } as? NSTextField
        if badge == nil {
            let field = NSTextField(labelWithString: "")
            field.identifier = forgeAttentionBadgeIdentifier
            field.alignment = .center
            field.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            field.textColor = .white
            field.backgroundColor = .systemRed
            field.drawsBackground = true
            field.isBezeled = false
            field.wantsLayer = true
            field.layer?.cornerRadius = 7
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.heightAnchor.constraint(equalToConstant: 15),
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            ])
            badge = field
        }
        guard forgeItem?.destination == .surface(.attention) else {
            badge?.isHidden = true
            return
        }
        let presentation = RepositoryAttentionUnseenPresenter.present(count: unseenAttentionCount)
        badge?.stringValue = presentation.sidebarBadgeText ?? ""
        badge?.isHidden = presentation.sidebarBadgeText == nil
        badge?.setAccessibilityLabel(presentation.sidebarAccessibilityLabel)
    }

    private func makeBranchesHeader(for outlineView: NSOutlineView) -> NSTableCellView {
        let header = NSTableCellView(frame: NSRect(x: 0, y: 0, width: outlineView.bounds.width, height: 22))
        header.identifier = branchesHeaderCellIdentifier
        let label = NSTextField(labelWithString: NSLocalizedString("BRANCHES", comment: "Sidebar branches heading"))
        label.font = NSFont.preferredFont(forTextStyle: .subheadline, options: [:])
        label.translatesAutoresizingMaskIntoConstraints = false
        header.textField = label
        header.addSubview(label)

        let image = NSImage(systemSymbolName: "textformat", accessibilityDescription: NSLocalizedString("Change branch sorting", comment: "Sidebar branch-sort control"))
        var buttonImage = NSImage()
        if let image {
            buttonImage = image
        }
        let button = NSButton(image: buttonImage, target: self, action: #selector(toggleBranchSort(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("BranchSortToggle")
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func configureBranchesHeader(_ header: NSTableCellView) {
        let sortButton = header.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "BranchSortToggle"
        }
        let recent = branchPresentation?.usesRecentSorting == true
        if #available(macOS 11.0, *) {
            sortButton?.image = NSImage(
                systemSymbolName: recent ? "clock" : "textformat",
                accessibilityDescription: NSLocalizedString("Change branch sorting", comment: "Sidebar branch-sort control")
            )
        }
        sortButton?.toolTip = recent
            ? NSLocalizedString("Branches sorted by most recent commit. Click for alphabetical.", comment: "Sidebar branch-sort control")
            : NSLocalizedString("Branches sorted alphabetically. Click for most recent commit.", comment: "Sidebar branch-sort control")
    }

    @objc internal dynamic func toggleBranchSort(_ sender: Any?) {
        branchPresentation?.toggleSorting()
        Self.logger.info("Toggled branch sidebar sort mode")
        NotificationCenter.default.post(name: .branchSidebarSettingsDidChange, object: nil)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = sourceView?.row(forItem: item) ?? -1
        return sourceView?.rowView(atRow: row, makeIfNecessary: false) ?? NSTableRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let forgeItem = item as? RepositoryForgeSourceViewItem {
            return forgeItem.destination != nil
        }
        return !((item as? PBSourceViewItem)?.isGroupItem ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !((item as? PBSourceViewItem)?.isUncollapsible ?? false)
    }

    @objc(expandCollapseItem:)
    internal dynamic func expandCollapseItem(_ notification: Notification) {
        guard let child = notification.userInfo?["NSObject"] as? PBSourceViewItem else { return }
        child.isExpanded = notification.name == NSOutlineView.itemWillExpandNotification
    }
}

public extension PBGitSidebarController {
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return mutableItems[index]
        }
        return visibleChildren(for: item as! PBSourceViewItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? PBSourceViewItem else { return false }
        return !visibleChildren(for: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? PBSourceViewItem else { return mutableItems.count }
        return visibleChildren(for: item).count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        objectValueFor tableColumn: NSTableColumn?,
        byItem item: Any?
    ) -> Any? {
        (item as? PBSourceViewItem)?.title
    }

    @objc(visibleChildrenForItem:)
    dynamic func visibleChildren(for item: PBSourceViewItem) -> [PBSourceViewItem] {
        let children = item.sortedChildren
        if item === branches {
            return branchPresentation?.sortedBranchItems(children) ?? children
        }
        if item === forgeGroup {
            return forgeRepositoryItems
        }
        if forgeRepositoryItems.contains(where: { $0 === item }) {
            let order: [ForgeCollaborationSurface] = [.pullRequests, .issues, .attention]
            return order.compactMap { forgeSurfaceItems[$0] }.filter { $0.parent === item }
        }
        return children
    }
}

extension PBGitSidebarController {
    @objc dynamic func updateActionMenu() {
        let item = selectedItem()
        actionButton?.isEnabled = item?.ref() != nil || item is PBSourceViewGitSubmoduleItem
    }

    @objc(addMenuItemsForRef:toMenu:)
    dynamic func addMenuItems(for ref: PBGitRef?, to menu: NSMenu) {
        guard let ref, let items = windowController?.historyViewController?.menuItems(for: ref) else { return }
        for item in items {
            menu.addItem(item)
        }
    }

    @objc(addMenuItemsForSubmodule:toMenu:)
    dynamic func addMenuItems(for submodule: PBSourceViewGitSubmoduleItem?, to menu: NSMenu) {
        guard let submodule else { return }
        let item = menu.addItem(
            withTitle: NSLocalizedString("Open Submodule", comment: "Open Submodule menu item"),
            action: #selector(openSubmodule(from:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = submodule.path
    }

    @objc dynamic func actionIconItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let image = NSImage(named: NSImage.actionTemplateName)
        image?.size = NSSize(width: 12, height: 12)
        item.image = image
        return item
    }

    @objc(menuForRow:)
    public dynamic func menu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let viewItem = sourceView?.item(atRow: row) as? PBSourceViewItem else { return menu }
        addMenuItems(for: viewItem.ref(), to: menu)
        addMenuItems(for: viewItem as? PBSourceViewGitSubmoduleItem, to: menu)
        return menu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === actionButton?.menu {
            menu.addItem(actionIconItem())
        }
        let item = selectedItem()
        addMenuItems(for: item?.ref(), to: menu)
        addMenuItems(for: item as? PBSourceViewGitSubmoduleItem, to: menu)
    }
}

extension PBGitSidebarController {
    @objc dynamic func updateRemoteControls() {
        var hasRemote = false
        if let ref = selectedItem()?.ref() {
            let tracking: PBGitRef?
            if ref.isBranch, let repository {
                tracking = try? repository.remoteRef(forBranch: ref)
            } else {
                tracking = nil
            }
            hasRemote = ref.isRemote || tracking?.remoteName != nil
        }
        remoteControls?.setEnabled(hasRemote, forSegment: RemoteSegment.fetch.rawValue)
        remoteControls?.setEnabled(hasRemote, forSegment: RemoteSegment.pull.rawValue)
        remoteControls?.setEnabled(hasRemote, forSegment: RemoteSegment.push.rawValue)
    }

    @IBAction open dynamic func fetchPullPushAction(_ sender: Any?) {
        let selectedSegment = (sender as? NSSegmentedControl)?.selectedSegment ?? RemoteSegment.add.rawValue
        if selectedSegment == RemoteSegment.add.rawValue {
            tryToPerform(NSSelectorFromString("addRemote:"), with: self)
            return
        }

        guard let item = selectedItem() else { return }
        var ref = item.revSpecifier?.ref()
        if ref == nil, item.parent === remotes {
            ref = PBGitRef(string: kGitXRemoteRefPrefix + item.title)
        }
        guard let ref, ref.isRemote || ref.isBranch, let repository,
              let remoteRef = try? repository.remoteRef(forBranch: ref) else { return }

        switch selectedSegment {
        case RemoteSegment.fetch.rawValue:
            windowController?.performFetch(for: ref)
        case RemoteSegment.pull.rawValue:
            windowController?.performPull(forBranch: ref, remote: remoteRef, rebase: false)
        case RemoteSegment.push.rawValue where ref.isRemote:
            windowController?.performPush(forBranch: nil, toRemote: remoteRef)
        case RemoteSegment.push.rawValue where ref.isBranch:
            windowController?.performPush(forBranch: ref, toRemote: remoteRef)
        default:
            break
        }
    }
}
