import AppKit
import ForgeKit

/// Consent and asynchronous results belong to one complete AppKit owner.
nonisolated struct RepositoryWindowOwnership {
    struct Identity: Equatable {
        let repository: ObjectIdentifier
        let window: ObjectIdentifier
        let document: ObjectIdentifier?
    }

    private(set) var generation: UInt64 = 0
    private(set) var identity: Identity?
    private(set) var closed = false

    mutating func revoke(closing: Bool = false) {
        generation &+= 1
        identity = nil
        closed = closed || closing
    }

    mutating func install(_ identity: Identity) {
        guard !closed else { return }
        self.identity = identity
    }

    func accepts(_ identity: Identity, generation: UInt64) -> Bool {
        !closed && self.identity == identity && self.generation == generation
    }
}

/// Retains the repository until its reads and subscriptions have been revoked.
@MainActor
private final class RepositoryWindowLifetime {
    let repository: PBGitRepository
    let identity: RepositoryWindowOwnership.Identity
    var focus: RepositoryFocusRefreshCoordinator?
    var status: RepositoryLocalStatusLoader?
    var notifications: [NSObjectProtocol] = []
    var observations: [NSKeyValueObservation] = []
    let notificationCenter: NotificationCenter
    let worktreeOwner = NSObject()
    var worktreeServices: [PBRepositoryWorktreeService] = []

    init(repository: PBGitRepository, identity: RepositoryWindowOwnership.Identity, notificationCenter: NotificationCenter) {
        self.repository = repository
        self.identity = identity
        self.notificationCenter = notificationCenter
    }

    func invalidate() {
        NSLog("[GitX] Removing %ld owner subscriptions for %@", notifications.count, String(describing: identity))
        notifications.forEach(notificationCenter.removeObserver)
        notifications.removeAll()
        observations.removeAll()
        let services = worktreeServices
        worktreeServices.removeAll()
        // Mark every reservation before cancellation can release shared FIFO admission.
        services.forEach { $0.markPreparationsCancelled(forOwner: worktreeOwner) }
        services.forEach { $0.cancelPreparations(forOwner: worktreeOwner) }
        focus?.cancel()
        status?.cancel()
        focus = nil
        status = nil
    }

    isolated deinit { invalidate() }
}

/// A selection is installed only when both repository-scoped loaders exist.
nonisolated struct RepositoryGitLoaderLifecycle {
    struct Identity: Equatable {
        let repository: ObjectIdentifier
        let selection: GitBinarySelection
    }

    private(set) var generation: UInt64 = 0
    private(set) var installed: Identity?

    func requiresInstallation(_ identity: Identity, hasFocus: Bool, hasStatus: Bool) -> Bool {
        installed != identity || !hasFocus || !hasStatus
    }

    mutating func invalidate() {
        generation &+= 1
        installed = nil
    }

    mutating func didInstall(_ identity: Identity) {
        installed = identity
    }

    func accepts(generation: UInt64, identity: Identity) -> Bool {
        self.generation == generation && installed == identity
    }
}

/// Owns the repository window's AppKit wiring while routing decisions to focused coordinators.
@objc(PBGitWindowController)
open class PBGitWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation { // swiftlint:disable:this type_body_length
    @objc private dynamic var _sidebarController: PBGitSidebarController? // swiftlint:disable:this identifier_name
    @objc private dynamic var _historyViewController: PBGitHistoryController? // swiftlint:disable:this identifier_name
    @objc private dynamic weak var contentController: PBViewController?

    private var explicitlyAssignedRepository: PBGitRepository?
    private var ownership = RepositoryWindowOwnership()
    private var lifetime: RepositoryWindowLifetime?
    private var nibPresentationReady = false
    private var paneRepository: ObjectIdentifier?
    private var actionRepository: ObjectIdentifier?
    private var ownerNotifications = NotificationCenter.default
    private weak var worktreeRepairRepository: PBGitRepository?
    private let repairOfferedRepositories = NSHashTable<PBGitRepository>.weakObjects()
    private final var focusRefreshCoordinator: RepositoryFocusRefreshCoordinator? {
        get { lifetime?.focus }
        set { lifetime?.focus = newValue }
    }

    final var gitDiscovery = GitBinaryDiscovery.shared
    private(set) final var gitLoaderSelection: GitBinarySelection?
    private var gitLoaderLifecycle = RepositoryGitLoaderLifecycle()
    private var actionContextResolver: RepositoryActionContextResolver?
    private var remoteActionCoordinator: RepositoryRemoteActionCoordinator?
    private final var remoteProgressStarting: RepositoryRemoteProgressStarting?
    final var pullRequestUIController: RepositoryPullRequestUIController?
    private var referenceActionCoordinator: RepositoryReferenceActionCoordinator?
    private var stashActionCoordinator: RepositoryStashActionCoordinator?
    private var workspaceActionCoordinator: WorkspaceActionCoordinator?
    private var repositoryForgeCoordinator: RepositoryForgeCoordinator?
    final var repositoryForgeLinkUseCase: RepositoryForgeLinkUseCase?
    private var repositoryToolbarController: RepositoryToolbarController?
    private(set) final var createPullRequestControl = ForgeMutationControlPresentation.hidden
    #if DEBUG
        private var milestone2UITestHarness: Milestone2UITestHarness?
        private var milestone3UITestHarness: Milestone3UITestHarness?
    #endif
    private var repositoryStatusBarController: RepositoryStatusBarController?
    private(set) final var repositoryForgeOverlaySession: RepositoryForgeOverlaySession?
    /// Read-only diagnostic state used to verify deterministic UI-test launches.
    @objc public final var hasRepositoryForgeOverlaySessionForDiagnostics: Bool {
        repositoryForgeOverlaySession != nil
    }

    private final var repositoryLocalStatusLoader: RepositoryLocalStatusLoader? {
        get { lifetime?.status }
        set { lifetime?.status = newValue }
    }

    private var repositoryLocalStatusSnapshot = RepositoryLocalStatusSnapshot.unavailable
    private var initializedContentControllers: NSHashTable<PBViewController>?
    private var contentStatusObservation: NSKeyValueObservation?

    @IBOutlet private weak var sourceListControlsView: NSView?
    @IBOutlet private weak var splitView: NSSplitView? // swiftlint:disable:this unused_declaration
    @IBOutlet private weak var sourceSplitView: NSView?
    @IBOutlet private weak var contentSplitView: NSView?
    @IBOutlet private weak var statusField: NSTextField?
    @IBOutlet private weak var progressIndicator: NSProgressIndicator?
    @IBOutlet private weak var jumpToCheckedOutBranchButton: NSButton?

    /// Objective-C-imported subclasses cannot dispatch new Swift-only virtual accessors.
    final var offeredWorktreeRepair = false
    /// Presentation authority expires when the originating window or owner changes.
    private(set) final var worktreePresentationGeneration: UInt64 = 0
    final var worktreePresentationQueue: WorktreePresentationQueue?

    private final func invalidateWorktreePresentation() {
        worktreePresentationGeneration &+= 1
        worktreePresentationQueue?.invalidate()
        worktreePresentationQueue = nil
        NSLog("[GitX] Invalidated worktree presentation generation %llu", worktreePresentationGeneration)
    }

    override open var window: NSWindow? {
        get { super.window }
        set {
            // Reading an unloaded window would create it merely to compare ownership.
            let previous = super.isWindowLoaded ? super.window : nil
            if previous !== newValue {
                revokeOwner()
                if previous?.delegate === self {
                    previous?.delegate = nil
                }
                repositoryStatusBarController?.uninstall()
                repositoryStatusBarController = nil
            }
            super.window = newValue
            if previous !== newValue {
                reconcileOwnership()
            }
        }
    }

    override open var document: AnyObject? {
        get { super.document }
        set {
            let changed = super.document !== newValue
            if changed {
                revokeOwner()
            }
            super.document = newValue
            if changed {
                reconcileOwnership()
            }
        }
    }

    @objc public convenience init() {
        self.init(windowNibName: "RepositoryWindow")
    }

    convenience init(ownerNotifications: NotificationCenter) {
        self.init()
        self.ownerNotifications = ownerNotifications
    }

    convenience init(window: NSWindow?, remoteProgressStarting: @escaping RepositoryRemoteProgressStarting) {
        self.init(window: window)
        self.remoteProgressStarting = remoteProgressStarting
    }

    /// Retain the historical setter surface while continuing to derive the active repository from the document.
    @objc open dynamic var repository: PBGitRepository? {
        get { (document as? PBGitRepositoryDocument)?.repository ?? explicitlyAssignedRepository }
        set {
            let incoming = (document as? PBGitRepositoryDocument)?.repository ?? newValue
            let changed = repository !== incoming
            if changed {
                revokeOwner()
            }
            explicitlyAssignedRepository = newValue
            if changed {
                reconcileOwnership()
            }
        }
    }

    @objc dynamic var historyViewController: PBGitHistoryController? {
        _historyViewController
    }

    @objc dynamic var sidebarViewController: PBGitSidebarController? {
        _sidebarController
    }

    final func ensureActionCoordinators() {
        guard !ownership.closed, let repository, repository.gitURL() != nil else { return }
        ensureLifetime()
        if actionRepository != ObjectIdentifier(repository) {
            resetActionCoordinators()
            actionRepository = ObjectIdentifier(repository)
        }
        if actionContextResolver == nil {
            actionContextResolver = RepositoryActionContextResolver()
        }
        if remoteActionCoordinator == nil {
            if let remoteProgressStarting {
                remoteActionCoordinator = RepositoryRemoteActionCoordinator(repository: repository, windowController: self, progressStarting: remoteProgressStarting)
            } else {
                remoteActionCoordinator = RepositoryRemoteActionCoordinator(repository: repository, windowController: self)
            }
        }
        if pullRequestUIController == nil, let remoteActionCoordinator {
            let session = ApplicationComposition.shared.forgePullRequestServices.session(for: repository)
            pullRequestUIController = RepositoryPullRequestUIController(
                repository: repository,
                windowController: self,
                ownerIsCurrent: repositoryOwnerValidation(for: repository),
                remoteActions: remoteActionCoordinator,
                service: session.service,
                drafts: session.drafts,
                destinationOpening: { [weak self] destination in
                    self?.sidebarViewController?.openForgeDestination(destination) == true
                },
                bindingResolving: { [weak repository] in
                    repository.flatMap { RepositoryForgeCoordinator(repository: $0).resolveBinding().binding }
                },
                postPushBrowserFallback: { [weak self, weak repository] remote in
                    guard let self, let repository else { return }
                    RepositoryRemoteURLCoordinator.shared.handleSuccessfulPush(
                        output: repository.lastPushOutput ?? "",
                        repository: repository,
                        remote: remote,
                        presenting: self.window
                    )
                },
                createPullRequestControlResolving: { [weak self] in
                    self?.createPullRequestControl ?? .hidden
                }
            )
        }
        if referenceActionCoordinator == nil {
            referenceActionCoordinator = RepositoryReferenceActionCoordinator(
                repository: repository,
                windowController: self
            )
        }
        if stashActionCoordinator == nil {
            stashActionCoordinator = RepositoryStashActionCoordinator(
                repository: repository,
                windowController: self
            )
        }
        if workspaceActionCoordinator == nil {
            workspaceActionCoordinator = WorkspaceActionCoordinator(repository: repository)
        }
    }

    private final func invalidateGitLoaders() {
        // Revoke callback authority before either cancellation can deliver a result.
        gitLoaderLifecycle.invalidate()
        focusRefreshCoordinator?.cancel()
        repositoryLocalStatusLoader?.cancel()
        focusRefreshCoordinator = nil
        repositoryLocalStatusLoader = nil
        repositoryLocalStatusSnapshot = .unavailable
        gitLoaderSelection = nil
        if isWindowLoaded {
            updateStatus()
        }
        NSLog("[GitX] Invalidated Git loader generation %llu", gitLoaderLifecycle.generation)
    }

    private final func acceptsGitLoaderResult(generation: UInt64, identity: RepositoryGitLoaderLifecycle.Identity) -> Bool {
        guard !ownership.closed, lifetime != nil, let repository else { return false }
        return ObjectIdentifier(repository) == identity.repository && gitDiscovery.currentSelection == identity.selection &&
            gitLoaderLifecycle.accepts(generation: generation, identity: identity)
    }

    @discardableResult
    private final func reconcileGitLoaders() -> Bool {
        guard !ownership.closed, let scope = lifetime, let repository else { return false }
        guard let selection = gitDiscovery.currentSelection else {
            if focusRefreshCoordinator != nil || repositoryLocalStatusLoader != nil {
                invalidateGitLoaders()
            }
            return false
        }
        guard
            repository.workingDirectoryURL() != nil || repository.gitURL() != nil else { return false }
        let identity = RepositoryGitLoaderLifecycle.Identity(repository: ObjectIdentifier(repository), selection: selection)
        guard gitLoaderLifecycle.requiresInstallation(identity, hasFocus: focusRefreshCoordinator != nil, hasStatus: repositoryLocalStatusLoader != nil) else { return false }
        let ownerGeneration = ownership.generation
        invalidateGitLoaders()
        guard lifetime === scope, ownership.accepts(scope.identity, generation: ownerGeneration),
              self.repository === repository, gitDiscovery.currentSelection == selection else { return false }
        let generation = gitLoaderLifecycle.generation
        focusRefreshCoordinator = RepositoryFocusRefreshCoordinator(repository: repository, gitExecutablePath: selection.path) { [weak self] in
            guard let self, self.acceptsGitLoaderResult(generation: generation, identity: identity) else { return }
            self.refreshLocalRepositoryContent()
        }
        repositoryLocalStatusLoader = RepositoryLocalStatusLoader(repository: repository, gitExecutablePath: selection.path) { [weak self] snapshot in
            guard let self, self.acceptsGitLoaderResult(generation: generation, identity: identity) else { return }
            self.repositoryLocalStatusSnapshot = snapshot
            self.updateStatus()
        }
        gitLoaderLifecycle.didInstall(identity)
        gitLoaderSelection = selection
        NSLog("[GitX] Installed both Git loaders generation %llu, repository %@, executable %@", generation, String(describing: identity.repository), selection.path)
        let captureInitialFocus = RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation()
        focusRefreshCoordinator?.updatePreference(enabled: captureInitialFocus)
        repositoryLocalStatusLoader?.refresh()
        updateStatus()
        return captureInitialFocus
    }

    private final func currentOwnerIdentity() -> RepositoryWindowOwnership.Identity? {
        guard isWindowLoaded, let window = super.window, let repository else { return nil }
        return .init(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window),
                     document: document.map(ObjectIdentifier.init))
    }

    final func worktreeOperationOwner(for service: PBRepositoryWorktreeService) -> NSObject? {
        ensureLifetime()
        guard !ownership.closed, let scope = lifetime else { return nil }
        if !scope.worktreeServices.contains(where: { $0 === service }) {
            scope.worktreeServices.append(service)
        }
        return scope.worktreeOwner
    }

    /// Captured before asynchronous confirmation or work admission, never retargeted.
    final func repositoryOwnerValidation(for repository: PBGitRepository) -> () -> Bool {
        ensureLifetime()
        let generation = ownership.generation
        let identity = currentOwnerIdentity()
        let repositoryID = ObjectIdentifier(repository)
        // Standalone coordinators historically supply their target before the
        // window has a document. That absence is itself captured ownership.
        let originatingRepository = self.repository.map(ObjectIdentifier.init)
        let matchesTarget = originatingRepository == nil || originatingRepository == repositoryID
        return { [weak self] in
            guard let self, matchesTarget, !self.ownership.closed, self.ownership.generation == generation,
                  self.repository.map(ObjectIdentifier.init) == originatingRepository else { return false }
            return self.currentOwnerIdentity() == identity
        }
    }

    private final func revokeOwner(closing: Bool = false) {
        // Revocation precedes cancellation, KVO removal and potentially reentrant UI work.
        ownership.revoke(closing: closing)
        invalidateWorktreePresentation()
        invalidateGitLoaders()
        lifetime?.invalidate()
        lifetime = nil
        pullRequestUIController?.invalidateOwner()
        resetActionCoordinators()
        repositoryForgeOverlaySession?.invalidate()
        repositoryForgeOverlaySession = nil
        repositoryStatusBarController?.invalidate()
        repositoryStatusBarController?.updateForge(.unbound)
        NSLog("[GitX] Revoked repository owner generation %llu, closed %@", ownership.generation, closing ? "yes" : "no")
    }

    private final func resetActionCoordinators() {
        actionRepository = nil
        createPullRequestControl = .hidden
        repositoryToolbarController?.updateCreatePullRequestControl(.hidden)
        actionContextResolver = nil
        remoteActionCoordinator = nil
        pullRequestUIController = nil
        referenceActionCoordinator = nil
        stashActionCoordinator = nil
        workspaceActionCoordinator = nil
        repositoryForgeCoordinator = nil
        repositoryForgeLinkUseCase = nil
    }

    private final func ensureLifetime() {
        guard !ownership.closed, let identity = currentOwnerIdentity(), let repository, repository.gitURL() != nil else { return }
        guard lifetime?.identity != identity else { return }
        if lifetime != nil {
            revokeOwner()
        }
        ownership.install(identity)
        let scope = RepositoryWindowLifetime(repository: repository, identity: identity, notificationCenter: ownerNotifications)
        lifetime = scope
        if worktreeRepairRepository !== repository {
            if offeredWorktreeRepair, let previous = worktreeRepairRepository {
                repairOfferedRepositories.add(previous)
            }
            worktreeRepairRepository = repository
            offeredWorktreeRepair = repairOfferedRepositories.contains(repository)
        }
        let generation = ownership.generation
        // Registration is synchronous. Keep its inputs alive here; only the
        // installed notification callbacks need weak owner references.
        let observe: (Notification.Name, AnyObject?, @escaping @MainActor @Sendable (PBGitWindowController, String?) -> Void) -> Void = { [self, scope] name, object, action in
            let token = scope.notificationCenter.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
                let operation = notification.userInfo?["operation"] as? String
                let deliver: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    guard self.ownership.accepts(identity, generation: generation), self.currentOwnerIdentity() == identity else {
                        NSLog("[GitX] Ignored owner event %@ generation %llu (current %llu, installed %@, captured %@, current %@)", name.rawValue, generation,
                              self.ownership.generation, String(describing: self.ownership.identity), String(describing: identity), String(describing: self.currentOwnerIdentity()))
                        return
                    }
                    NSLog("[GitX] Delivering owner event %@ generation %llu", name.rawValue, generation)
                    action(self, operation)
                }
                // Settings publication can hold a repository's binding lock.
                // Reconcile preferences only after the publisher has returned.
                if Thread.isMainThread, name != UserDefaults.didChangeNotification {
                    // swift6-safety-justification: AppKit notifications delivered on the main thread run on its actor executor.
                    MainActor.assumeIsolated(deliver)
                } else {
                    DispatchQueue.main.async(execute: deliver)
                }
            }
            scope.notifications.append(token)
        }
        observe(NSApplication.didBecomeActiveNotification, nil) { owner, _ in
            owner.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        }
        observe(.PBGitBinaryDidChange, nil) { owner, _ in owner.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange)) }
        observe(UserDefaults.didChangeNotification, nil) { owner, _ in owner.refreshPreferenceDidChange(Notification(name: UserDefaults.didChangeNotification)) }
        observe(NSNotification.Name(PBGitIndexIndexUpdated), repository.index) { owner, _ in
            owner.repositoryLocalStatusDidChange(Notification(name: NSNotification.Name(PBGitIndexIndexUpdated)))
        }
        observe(.repositoryRemoteOperationDidSucceed, repository) { owner, operation in
            owner.repositoryRemoteOperationDidSucceed(Notification(name: .repositoryRemoteOperationDidSucceed, userInfo: operation.map { ["operation": $0] }))
        }
        observe(.forgeApplicationAvailabilityDidChange, nil) { owner, _ in owner.forgeApplicationAvailabilityDidChange(Notification(name: .forgeApplicationAvailabilityDidChange)) }
        observe(NSWindow.willCloseNotification, super.window) { owner, _ in
            owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        let update: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.ownership.accepts(identity, generation: generation), self.currentOwnerIdentity() == identity else { return }
                self.offerWorktreeRepairIfNeeded()
                if let history = self.historyViewController, history.isViewLoaded {
                    history.commitList.enumerateAvailableRowViews { row, _ in
                        row.subviews.forEach { $0.needsDisplay = true }
                    }
                }
            }
        }
        scope.observations = [
            repository.observe(\.worktrees, options: [.initial]) { _, _ in update() },
            repository.observe(\.worktreeFeatureAvailable, options: []) { _, _ in update() },
            repository.observe(\.currentBranch, options: []) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.ownership.accepts(identity, generation: generation), self.currentOwnerIdentity() == identity else { return }
                    self.repositoryLocalStatusLoader?.refresh()
                    NSLog("[GitX] Refreshed local status after current branch changed, owner generation %llu", generation)
                }
            },
        ]
        NSLog("[GitX] Installed repository subscriptions generation %llu", generation)
    }

    @discardableResult
    private final func reconcileOwnership() -> Bool {
        guard !ownership.closed else { return false }
        let repositoryID = repository.map(ObjectIdentifier.init)
        if paneRepository != repositoryID {
            closeRepositoryPanes()
        }
        ensureLifetime()
        guard lifetime != nil else { return false }
        ensureActionCoordinators()
        installRepositoryPanesIfReady()
        return reconcileGitLoaders()
    }

    private final func closeRepositoryPanes() {
        contentStatusObservation = nil
        contentController?.viewIfLoaded?.removeFromSuperview()
        contentController = nil
        _sidebarController?.sourceListControlsView?.removeFromSuperview()
        _sidebarController?.viewIfLoaded?.removeFromSuperview()
        _sidebarController?.closeView()
        _historyViewController?.closeView()
        _sidebarController = nil
        _historyViewController = nil
        initializedContentControllers = .weakObjects()
        paneRepository = nil
        repositoryToolbarController = nil
        if ownership.closed {
            repositoryStatusBarController?.uninstall()
            repositoryStatusBarController = nil
        }
    }

    private final func installRepositoryPanesIfReady() {
        guard nibPresentationReady, let repository, let window = super.window,
              sourceSplitView?.window === window, contentSplitView?.window === window else { return }
        if window.delegate == nil {
            window.delegate = self
        }
        // History binds its facts and badges while its view is mounted.
        // Make the repository session available before constructing either pane.
        installRepositoryForgeOverlaySession()
        if paneRepository == nil {
            paneRepository = ObjectIdentifier(repository)
            _sidebarController = PBGitSidebarController(repository: repository, superController: self)
            _historyViewController = PBGitHistoryController(repository: repository, superController: self)
            if let sidebar = _sidebarController, let sourceSplitView {
                sidebar.view.frame = sourceSplitView.bounds
                sourceSplitView.addSubview(sidebar.view)
                if let controls = sidebar.sourceListControlsView {
                    sourceListControlsView?.addSubview(controls)
                }
            }
            if let history = _historyViewController {
                changeContentController(history)
            }
            NSLog("[GitX] Installed repository panes with initial History selection")
        }
        window.representedURL = repository.workingDirectoryURL()
        if repositoryToolbarController == nil {
            repositoryToolbarController = RepositoryToolbarController(windowController: self)
        }
        repositoryToolbarController?.install()
        if repositoryStatusBarController == nil {
            installRepositoryStatusBar()
        }
    }

    isolated deinit {
        ownership.revoke(closing: true)
        lifetime?.invalidate()
        pullRequestUIController?.invalidateOwner()
        repositoryForgeOverlaySession?.invalidate()
        repositoryStatusBarController?.uninstall()
        _sidebarController?.closeView()
        _historyViewController?.closeView()
    }

    override open func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if isWindowLoaded {
            window?.representedURL = repository?.workingDirectoryURL()
        }
    }

    @objc public dynamic func windowDidBecomeMain(_ notification: Notification) {
        if let source = notification.object as? NSWindow, source !== (isWindowLoaded ? super.window : nil) {
            return
        }
        offerWorktreeRepairIfNeeded()
    }

    override open func close() {
        windowWillClose(Notification(name: NSWindow.willCloseNotification))
        super.close()
    }

    @objc public dynamic func windowWillClose(_ notification: Notification) {
        if let source = notification.object as? NSWindow, source !== (isWindowLoaded ? super.window : nil) {
            return
        }
        guard !ownership.closed else { return }
        revokeOwner(closing: true)
        closeRepositoryPanes()
        repositoryToolbarController = nil
        #if DEBUG
            milestone2UITestHarness = nil
            milestone3UITestHarness = nil
        #endif
        if nibPresentationReady {
            WelcomeWindowController.shared.showIfNeededAfterDelay()
        }
    }

    @objc public dynamic func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action,
           ["checkout:", "merge:", "rebase:", "rebaseHeadBranch:", "cherryPick:", "resetSoft:",
            "stashSave:", "stashSaveWithKeepIndex:", "stashPop:", "stashApply:", "stashDrop:",
            "pullRemote:", "pullDefaultRemote:", "pullRebaseRemote:", "pullRebaseDefaultRemote:", "toolbarPull:",
            "deleteRef:", "createBranch:", "createTag:"].contains(NSStringFromSelector(action)),
           repository.map({ !CommitSubmissionEligibility.allowsMutation($0.index) }) != false
        {
            return false
        }
        if menuItem.action == #selector(newPullRequest(_:)) {
            menuItem.isHidden = !createPullRequestControl.isVisible
            menuItem.toolTip = createPullRequestControl.helpText
            return createPullRequestControl.isVisible && createPullRequestControl.isEnabled
        }
        if let action = RepositoryForgeLinkAction(selector: menuItem.action),
           let model = RepositoryForgeLinkMenuPresenter.itemModel(action: action, context: forgeLinkContext)
        {
            RepositoryForgeLinkMenuPresenter.apply(model: model, to: menuItem)
            return model.isEnabled
        }
        if menuItem.action == #selector(revealInFinder(_:)) {
            ensureActionCoordinators()
            return workspaceActionCoordinator?.hasRevealTarget == true
        }
        if menuItem.action == #selector(openInTerminal(_:)) {
            ensureActionCoordinators()
            return workspaceActionCoordinator?.hasWorkingDirectory == true
        }
        if menuItem.action == #selector(showUncommittedChanges(_:)) {
            menuItem.state = isUncommittedChangesSelected ? .on : .off
            return repository?.isBare() != true
        }
        if menuItem.action == #selector(showHistoryView(_:)) || menuItem.action == #selector(returnToHistory(_:)) {
            menuItem.state = isUncommittedChangesSelected ? .off : .on
            return repository?.isBare() != true
        }
        if menuItem.action == #selector(toggleAmendCommit(_:)) {
            menuItem.state = repository?.index.isAmend == true ? .on : .off
            return repository.map { CommitSubmissionEligibility.allowsMutation($0.index) } ?? false
        }
        if menuItem.action == #selector(toggleRepositoryStatusBar(_:)) {
            menuItem.state = ApplicationSettings.repositoryStatusBarVisible ? .on : .off
            return true
        }
        if menuItem.action == #selector(fetchRemote(_:)) {
            return validateMenuItem(menuItem, remoteTitle: "Fetch “%@”", plainTitle: "Fetch")
        }
        if menuItem.action == #selector(showRepositorySettings(_:)) {
            return repository != nil
        }
        if menuItem.action == #selector(pullRemote(_:)) {
            return validateMenuItem(menuItem, remoteTitle: "Pull From “%@”", plainTitle: "Pull")
        }
        if menuItem.action == #selector(pullRebaseRemote(_:)) {
            return validateMenuItem(
                menuItem,
                remoteTitle: "Pull From “%@” and Rebase",
                plainTitle: "Pull and Rebase"
            )
        }
        return true
    }

    final var forgeLinkContext: RepositoryForgeLinkContext {
        let resolution = forgeCoordinator?.resolveBinding()
        let headRef = repository?.headRef()?.ref()
        let checkedOutRevision: RepositoryForgeLinkRevision?
        if let headRef, headRef.isBranch, let branchName = headRef.branchName {
            checkedOutRevision = .branch(branchName)
        } else if let identifier = repository?.headOID()?.sha {
            checkedOutRevision = .commit(identifier)
        } else {
            checkedOutRevision = nil
        }
        let selectedCommitIdentifiers = (_historyViewController?.selectedCommits ?? []).compactMap { commit in
            commit is PBUncommittedChanges ? nil : commit.sha
        }
        return RepositoryForgeLinkContext(
            providerName: resolution?.providerName,
            isForgeAvailable: resolution?.binding != nil || resolution?.candidates.isEmpty == false,
            checkedOutRevision: checkedOutRevision,
            selectedCommitIdentifiers: selectedCommitIdentifiers
        )
    }

    final var forgeCoordinator: RepositoryForgeCoordinator? {
        if repositoryForgeCoordinator == nil, let repository {
            let coordinator = RepositoryForgeCoordinator(repository: repository)
            repositoryForgeCoordinator = coordinator
            repositoryForgeLinkUseCase = RepositoryForgeLinkUseCase(
                coordinator: coordinator,
                windowController: self
            )
        }
        return repositoryForgeCoordinator
    }

    final var forgeLinkUseCase: RepositoryForgeLinkUseCase? {
        _ = forgeCoordinator
        return repositoryForgeLinkUseCase
    }

    @objc(validateMenuItem:remoteTitle:plainTitle:)
    dynamic func validateMenuItem(_ menuItem: NSMenuItem, remoteTitle: String, plainTitle: String) -> Bool {
        guard let repository, let ref = selectedRef else { return false }
        let remoteRef = try? repository.remoteRef(forBranch: ref)
        if ref.isRemote || remoteRef != nil {
            let displayRef: PBGitRef
            if let remoteRef {
                displayRef = remoteRef
            } else {
                displayRef = ref
            }
            let remoteName: String
            if let name = displayRef.remoteName {
                remoteName = name
            } else {
                remoteName = "(null)"
            }
            menuItem.title = String(format: NSLocalizedString(remoteTitle, comment: ""), remoteName)
            menuItem.representedObject = ref
            return true
        }
        menuItem.title = NSLocalizedString(plainTitle, comment: "")
        return false
    }

    override open func windowDidLoad() {
        super.windowDidLoad()
        guard !ownership.closed else { return }
        nibPresentationReady = true
        ForgeDeepLinkApplicationRouter.shared.installIfNeeded()
        window?.setFrameUsingName("GitX")
        repositoryToolbarController = RepositoryToolbarController(windowController: self)
        repositoryToolbarController?.install()
        reconcileOwnership()
        statusField?.cell?.backgroundStyle = .raised
        progressIndicator?.usesThreadedAnimation = true
        jumpToCheckedOutBranchButton?.setAccessibilityIdentifier("JumpToCheckedOutBranchButton")
        #if DEBUG
            milestone2UITestHarness = Milestone2UITestHarness.installIfRequested(for: self)
            milestone3UITestHarness = Milestone3UITestHarness.installIfRequested(for: self)
        #endif
    }

    @objc(applicationDidBecomeActive:)
    dynamic func applicationDidBecomeActive(_ notification: Notification) {
        let capturedInitialFocus = reconcileOwnership()
        if !capturedInitialFocus {
            focusRefreshCoordinator?.applicationDidBecomeActive()
        }
        repositoryForgeOverlaySession?.requestRefresh(reason: .applicationActivated)
    }

    @objc dynamic nonisolated func gitBinaryDidChange(_: Notification) {
        if Thread.isMainThread {
            // swift6-safety-justification: The thread check establishes main-actor ownership for the Objective-C notification.
            _ = MainActor.assumeIsolated { reconcileOwnership() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.reconcileOwnership() }
        }
    }

    @objc(forgeApplicationAvailabilityDidChange:)
    private dynamic func forgeApplicationAvailabilityDidChange(_ notification: Notification) {
        reloadRepositoryForgeOverlaySession()
    }

    @objc(refreshPreferenceDidChange:)
    dynamic nonisolated func refreshPreferenceDidChange(_ notification: Notification?) {
        if Thread.isMainThread {
            // swift6-safety-justification: The explicit main-thread check makes this synchronous selector hop safe.
            MainActor.assumeIsolated {
                applyRefreshPreferences()
            }
            return
        }

        NSLog("[GitX] Routing a background preference notification to the main actor")
        DispatchQueue.main.async { [weak self] in
            self?.applyRefreshPreferences()
        }
    }

    private func applyRefreshPreferences() {
        reconcileOwnership()
        focusRefreshCoordinator?.updatePreference(enabled: RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation())
        repositoryStatusBarController?.setVisible(ApplicationSettings.repositoryStatusBarVisible)
        updateToolbarForgeDiagnostic()
    }

    @objc dynamic func refreshIfRepositoryChangedSinceLastActivation() {
        let capturedInitialFocus = reconcileOwnership()
        if !capturedInitialFocus {
            focusRefreshCoordinator?.applicationDidBecomeActive()
        }
    }

    @objc dynamic func changeContentController(_ controller: PBViewController?) {
        guard let controller, contentController !== controller else { return }
        if let previousController = contentController {
            contentStatusObservation = nil
            previousController.view.isHidden = true
            previousController.view.removeFromSuperview()
        }

        contentController = controller
        if initializedContentControllers == nil {
            initializedContentControllers = .weakObjects()
        }
        let firstMount = initializedContentControllers?.contains(controller) != true
        controller.view.frame = .zero
        if let contentSplitView {
            controller.view.frame = contentSplitView.bounds
        }
        controller.view.autoresizingMask = [.width, .height]
        controller.view.isHidden = false
        contentSplitView?.addSubview(controller.view)
        if firstMount {
            initializedContentControllers?.add(controller)
            controller.updateView()
        }
        if let firstResponder = controller.firstResponder() {
            window?.makeFirstResponder(firstResponder)
        }
        contentStatusObservation = controller.observe(\.status, options: [.initial]) { [weak self] _, _ in
            // swift6-safety-justification: KVO delivery and content-controller mutations are confined to AppKit's main thread.
            MainActor.assumeIsolated {
                self?.updateStatus()
            }
        }
        NSLog(
            "[GitX] Mounted %@ (first mount: %@)",
            NSStringFromClass(type(of: controller)),
            firstMount ? "yes" : "no"
        )
        let forgeActivity: ForgeOverlayActivity = controller === _historyViewController
            ? .affectedViewActive
            : .otherOpenRepository
        repositoryForgeOverlaySession?.setActivity(forgeActivity)
    }

    @IBAction dynamic func showUncommittedChanges(_ sender: Any?) {
        NSLog("[GitX] Showing the Uncommitted Changes row")
        showHistoryView(sender)
        _historyViewController?.selectUncommittedChanges()
    }

    @IBAction dynamic func showHistoryView(_ sender: Any?) {
        NSLog("Switching repository window to History view")
        _sidebarController?.selectCurrentBranch()
        changeContentController(_historyViewController)
    }

    @IBAction dynamic func returnToHistory(_ sender: Any?) {
        NSLog("[GitX] Explicitly returning to the selected checkout's latest History")
        if _sidebarController?.browseSelectedWorktreeHistory() != true {
            _sidebarController?.selectCurrentBranch()
        }
        changeContentController(_historyViewController)
    }

    /// Opens a validated local revision from an `x-gitx` deep link. Resolution
    /// remains local-only: the application router separately offers an explicit
    /// Fetch action when a required object is absent.
    @discardableResult
    @objc(openForgeRevision:)
    final func openForgeRevision(_ revision: String) -> Bool {
        guard let repository else { return false }
        guard let resolved = try? repository.outputOfTask(withArguments: [
            "rev-parse", "--verify", "\(revision)^{commit}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines),
            let oid = GTOID(sha: resolved)
        else { return false }
        showHistoryView(self)
        _historyViewController?.selectCommit(oid)
        return true
    }

    @discardableResult
    @objc(openForgeComparisonFrom:to:)
    final func openForgeComparison(base: String, head: String) -> Bool {
        guard let repository,
              (try? repository.outputOfTask(withArguments: ["rev-parse", "--verify", "\(base)^{commit}"])) != nil,
              (try? repository.outputOfTask(withArguments: ["rev-parse", "--verify", "\(head)^{commit}"])) != nil,
              let diff = try? repository.outputOfTask(withArguments: ["diff"] + DiffCommandOptions.arguments + [
                  "--find-renames", "--no-ext-diff", base, head,
              ])
        else { return false }
        PBDiffWindowController.showDiff(diff)
        return true
    }

    @objc dynamic var isUncommittedChangesSelected: Bool {
        _historyViewController?.uncommittedChangesSelected == true
    }

    @IBAction dynamic func toggleAmendCommit(_ sender: Any?) {
        // Toggling amend refreshes the index against HEAD^, which repopulates indexChanges and pins the
        // Uncommitted Changes row even on a clean tree; the pending selection then lands on it.
        guard let index = repository?.index, CommitSubmissionEligibility.allowsMutation(index) else { return }
        index.isAmend.toggle()
        showUncommittedChanges(sender)
    }

    @objc dynamic func updateStatus() {
        var displayedStatus = ""
        var busy = false
        if let contentController, let status = contentController.status {
            displayedStatus = status
            busy = contentController.isBusy
        }
        statusField?.stringValue = displayedStatus
        var baseTitle = ""
        if let document = document as? NSDocument {
            baseTitle = document.displayName
        } else if let window {
            baseTitle = window.title
        }
        repositoryToolbarController?.update(status: displayedStatus, busy: busy, baseWindowTitle: baseTitle)
        repositoryStatusBarController?.updateLocal(RepositoryLocalStatusPresenter.present(
            repositoryLocalStatusSnapshot,
            activityText: displayedStatus,
            isBusy: busy
        ))
        if busy {
            progressIndicator?.startAnimation(self)
            progressIndicator?.isHidden = false
        } else {
            progressIndicator?.stopAnimation(self)
            progressIndicator?.isHidden = true
        }
    }

    @objc dynamic func setHistorySearch(_ searchString: String, mode: PBHistorySearchMode) {
        _historyViewController?.setHistorySearch(searchString, mode: mode)
    }

    @objc(selectedURLsFromSender:)
    dynamic func selectedURLs(from sender: Any?) -> [URL]? {
        ensureActionCoordinators()
        return workspaceActionCoordinator?.selectedURLs(from: representedObject(from: sender))
    }

    private func representedObject(from sender: Any?) -> Any? {
        let selector = NSSelectorFromString("representedObject")
        guard let object = sender as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @objc(openURLs:)
    open dynamic func open(_ fileURLs: [URL]?) {
        ensureActionCoordinators()
        let urls = fileURLs ?? []
        workspaceActionCoordinator?.open(urls)
    }

    @objc(revealURLsInFinder:)
    open dynamic func revealURLs(inFinder fileURLs: [URL]?) {
        ensureActionCoordinators()
        let urls = fileURLs ?? []
        workspaceActionCoordinator?.revealInFinder(urls)
    }

    @objc(refishForSender:refishTypes:)
    dynamic func refish(for sender: Any?, refishTypes types: [String]?) -> PBGitRefish? {
        ensureActionCoordinators()
        guard let repository, let actionContextResolver else { return nil }
        let menuItem = sender as? NSMenuItem
        let selectedCommit = menuItem == nil ? _historyViewController?.selectedCommits.first : nil
        return actionContextResolver.refish(
            representedObject: menuItem?.representedObject,
            selectedCommit: selectedCommit,
            allowedTypes: types,
            repository: repository
        )
    }

    @objc dynamic var selectedRef: PBGitRef? {
        ensureActionCoordinators()
        var sidebarRef: PBGitRef?
        var sidebarRemoteName: String?
        var historyRefs: [PBGitRef]?
        if let sidebarViewController,
           let sidebarSourceView = sidebarViewController.sourceView,
           window?.firstResponder === sidebarSourceView,
           let item = sidebarSourceView.item(atRow: sidebarSourceView.selectedRow) as? PBSourceViewItem
        {
            if let remotes = sidebarViewController.remotes, item.parent === remotes {
                sidebarRemoteName = item.title
            } else {
                sidebarRef = item.ref()
            }
        } else if window?.firstResponder === _historyViewController?.commitList,
                  _historyViewController?.singleCommitSelected == true
        {
            historyRefs = _historyViewController?.selectedCommits.first?.refs?.compactMap { $0 as? PBGitRef }
        }
        return actionContextResolver?.selectedRef(
            sidebarRef: sidebarRef,
            sidebarRemoteName: sidebarRemoteName,
            historyRefs: historyRefs
        )
    }

    @objc(performFetchForRef:)
    dynamic func performFetch(for ref: PBGitRef?) {
        ensureActionCoordinators()
        remoteActionCoordinator?.performFetch(for: ref)
    }

    @objc(performPullForBranch:remote:rebase:)
    dynamic func performPull(forBranch branch: PBGitRef, remote: PBGitRef?, rebase: Bool) {
        ensureActionCoordinators()
        remoteActionCoordinator?.performPull(branch: branch, remote: remote, rebase: rebase)
    }

    @objc(performPushForBranch:toRemote:)
    open dynamic func performPush(forBranch branch: PBGitRef?, toRemote remote: PBGitRef?) {
        performPush(forBranch: branch, toRemote: remote, requiresConfirmation: true)
    }

    @objc(performPushForBranch:toRemote:requiresConfirmation:)
    open dynamic func performPush(
        forBranch branch: PBGitRef?,
        toRemote remote: PBGitRef?,
        requiresConfirmation: Bool
    ) {
        ensureActionCoordinators()
        pullRequestUIController?.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation,
            initiallyCreatePullRequest: false
        )
    }

    @objc(performPushForBranch:toRemote:requiresConfirmation:initiallyCreatePullRequest:)
    dynamic func performPush(
        forBranch branch: PBGitRef?,
        toRemote remote: PBGitRef?,
        requiresConfirmation: Bool,
        initiallyCreatePullRequest: Bool
    ) {
        ensureActionCoordinators()
        pullRequestUIController?.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation,
            initiallyCreatePullRequest: initiallyCreatePullRequest
        )
    }

    @objc(presentNewPullRequest)
    dynamic func presentNewPullRequest() {
        guard createPullRequestControl.isVisible, createPullRequestControl.isEnabled else { return }
        ensureActionCoordinators()
        pullRequestUIController?.newPullRequest()
    }

    final func updateCreatePullRequestControl(_ presentation: ForgeMutationControlPresentation) {
        createPullRequestControl = presentation
        repositoryToolbarController?.updateCreatePullRequestControl(presentation)
    }

    func editPullRequest(
        accountID: ForgeAccountID,
        snapshot: ForgePullRequestEditableSnapshot,
        destination: ForgeDestination
    ) {
        ensureActionCoordinators()
        pullRequestUIController?.editPullRequest(
            accountID: accountID,
            snapshot: snapshot,
            destination: destination
        )
    }

    func checkoutPullRequest(_ pullRequest: ForgePullRequestSummary) {
        ensureActionCoordinators()
        pullRequestUIController?.checkout(pullRequest)
    }

    func syncFork(accountID: ForgeAccountID, plan: ForgeSyncForkPlan) {
        ensureActionCoordinators()
        pullRequestUIController?.syncFork(accountID: accountID, plan: plan)
    }

    @available(*, deprecated, message: "Use addRemote(_:)")
    @IBAction dynamic func showAddRemoteSheet(_ sender: Any?) {
        addRemote(sender)
    }

    @IBAction dynamic func addRemote(_ sender: Any?) {
        ensureActionCoordinators()
        remoteActionCoordinator?.addRemote()
    }

    @IBAction dynamic func fetchRemote(_ sender: Any?) {
        let ref = refish(for: sender, refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXRemoteType])
        if let ref = ref as? PBGitRef {
            performFetch(for: ref)
        }
    }

    @IBAction dynamic func fetchAllRemotes(_ sender: Any?) {
        performFetch(for: nil)
    }

    @IBAction dynamic func pullRemote(_ sender: Any?) {
        pull(from: sender, rebase: false)
    }

    @IBAction dynamic func pullRebaseRemote(_ sender: Any?) {
        pull(from: sender, rebase: true)
    }

    @IBAction dynamic func pullDefaultRemote(_ sender: Any?) {
        pull(from: sender, rebase: false)
    }

    @IBAction dynamic func pullRebaseDefaultRemote(_ sender: Any?) {
        pull(from: sender, rebase: true)
    }

    private func pull(from sender: Any?, rebase: Bool) {
        if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
            performPull(forBranch: ref, remote: nil, rebase: rebase)
        }
    }

    @IBAction dynamic func pushUpdatesToRemote(_ sender: Any?) {
        if let ref = refish(for: sender, refishTypes: [kGitXRemoteType]) as? PBGitRef {
            performPush(forBranch: nil, toRemote: ref.remote())
        }
    }

    @IBAction dynamic func pushDefaultRemoteForRef(_ sender: Any?) {
        if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
            performPush(forBranch: ref, toRemote: nil)
        }
    }

    @IBAction dynamic func pushToRemote(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let ref = refish(for: item.parent, refishTypes: nil) as? PBGitRef,
              let remote = refish(for: item, refishTypes: [kGitXRemoteType]) as? PBGitRef,
              ReferenceActionPolicy.canPushToNamedRemote(refishType: ref.refishType())
        else { return }
        performPush(forBranch: ref, toRemote: remote)
    }

    @IBAction dynamic func checkout(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.checkout(refish(
            for: sender,
            refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType]
        ))
    }

    @IBAction dynamic func merge(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.merge(refish(
            for: sender,
            refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType]
        ))
    }

    @IBAction dynamic func rebase(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.rebase(on: refish(for: sender, refishTypes: [kGitXCommitType]))
    }

    @IBAction dynamic func rebaseHeadBranch(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.rebase(on: refish(
            for: sender,
            refishTypes: [kGitXCommitType, kGitXBranchType, kGitXRemoteBranchType]
        ))
    }

    @IBAction dynamic func cherryPick(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.cherryPick(refish(for: sender, refishTypes: [kGitXCommitType]))
    }

    @IBAction dynamic func resetSoft(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.resetSoft(
            to: refish(for: sender, refishTypes: [kGitXBranchType, kGitXCommitType])
        )
    }

    @IBAction dynamic func deleteRef(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.delete(refish(for: sender, refishTypes: nil) as? PBGitRef)
    }

    @IBAction dynamic func createBranch(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.createBranch(
            from: refish(for: sender, refishTypes: nil),
            selectedCommit: _historyViewController?.selectedCommits.first
        )
    }

    @IBAction dynamic func createTag(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.createTag(
            from: refish(for: sender, refishTypes: nil),
            selectedCommit: _historyViewController?.selectedCommits.first
        )
    }

    @IBAction dynamic func diffWithHEAD(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.showDiffWithHEAD(for: refish(for: sender, refishTypes: nil))
    }

    @IBAction dynamic func stashViewDiff(_ sender: Any?) {
        ensureActionCoordinators()
        let ref = refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef
        referenceActionCoordinator?.showStashDiff(ref.flatMap { repository?.stash(for: $0) })
    }

    @IBAction dynamic func showTagInfoSheet(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.showTagInfo(
            for: refish(for: sender, refishTypes: [kGitXTagType]) as? PBGitRef
        )
    }

    @IBAction dynamic func stashSave(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.save(keepIndex: false)
    }

    @IBAction dynamic func stashSaveWithKeepIndex(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.save(keepIndex: true)
    }

    @IBAction dynamic func stashPop(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.pop(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func stashApply(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.apply(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func stashDrop(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.drop(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func openFiles(_ sender: Any?) {
        open(selectedURLs(from: sender))
    }

    @IBAction dynamic func revealInFinder(_ sender: Any?) {
        ensureActionCoordinators()
        revealURLs(inFinder: workspaceActionCoordinator?.revealURLs(from: representedObject(from: sender)))
    }

    @IBAction dynamic func openInTerminal(_ sender: Any?) {
        ensureActionCoordinators()
        workspaceActionCoordinator?.openRepositoryInTerminal()
    }

    @IBAction dynamic func refresh(_ sender: Any?) {
        refreshLocalRepositoryContent()
        repositoryForgeOverlaySession?.requestManualRefresh()
    }

    func refreshAfterForgeBaseFetch() {
        repository?.reloadRefs()
        NSLog("[GitX] Refreshed repository references after explicit Forge base fetch")
    }

    func refreshAfterForgeBaseCheckout() {
        repository?.reloadRefs()
        repository?.readCurrentBranch()
        _sidebarController?.selectCurrentBranch()
        refreshLocalRepositoryContent()
        NSLog("[GitX] Refreshed repository model after explicit Forge base checkout")
    }

    private func refreshLocalRepositoryContent() {
        repository?.refreshWorktrees()
        contentController?.refresh(self)
        repositoryLocalStatusLoader?.refresh()
        synchronizeWindowTitleWithDocumentName()
        NSLog("[GitX] Manual refresh synchronized window title: %@", window?.title ?? "")
    }

    @IBAction dynamic func toggleRepositoryStatusBar(_ sender: Any?) {
        ApplicationSettings.repositoryStatusBarVisible.toggle()
        repositoryStatusBarController?.setVisible(ApplicationSettings.repositoryStatusBarVisible)
        updateToolbarForgeDiagnostic()
        NSLog(
            "[GitX] Repository status bar visibility changed: %@",
            ApplicationSettings.repositoryStatusBarVisible ? "visible" : "hidden"
        )
    }

    @objc(repositoryLocalStatusDidChange:)
    private dynamic func repositoryLocalStatusDidChange(_ notification: Notification) {
        repositoryLocalStatusLoader?.refresh()
    }

    @objc(repositoryRemoteOperationDidSucceed:)
    private dynamic func repositoryRemoteOperationDidSucceed(_ notification: Notification) {
        repositoryLocalStatusLoader?.refresh()
        let operation = notification.userInfo?["operation"] as? String
        let reason: ForgeRefreshReason = operation == "push" ? .localPushSucceeded : .localFetchSucceeded
        repositoryForgeOverlaySession?.requestRefresh(reason: reason)
    }

    final func installRepositoryForgeOverlaySession() {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["GITX_M2_UITEST"] != "1" else {
                NSLog("[UITest] Suppressed repository Forge overlay session for deterministic Milestone 2 UI verification")
                return
            }
        #endif
        guard repositoryForgeOverlaySession == nil else { return }
        let binding = forgeCoordinator?.resolveBinding().binding
        let session = RepositoryForgeOverlaySession(
            binding: binding,
            services: ApplicationComposition.shared.forgeServices,
            detailsHandler: { [weak self] action in
                self?.presentForgeStatusDetails(action)
            }
        )
        repositoryForgeOverlaySession = session
        repositoryStatusBarController?.bind(to: session)
        session.start()
    }

    private func installRepositoryStatusBar() {
        guard let splitView, let window = super.window, splitView.window === window, let contentView = window.contentView, repository != nil else { return }
        let controller = RepositoryStatusBarController(splitView: splitView, contentView: contentView)
        controller.presentationDidChange = { [weak self] presentation in
            self?.repositoryToolbarController?.updateForgeDiagnostic(
                persistentFailureText: presentation.toolbarPersistentFailureText,
                statusBarVisible: ApplicationSettings.repositoryStatusBarVisible
            )
        }
        repositoryStatusBarController = controller
        controller.install(visible: ApplicationSettings.repositoryStatusBarVisible)
        updateStatus()
        if let repositoryForgeOverlaySession {
            controller.bind(to: repositoryForgeOverlaySession)
        }
    }

    private func updateToolbarForgeDiagnostic() {
        repositoryToolbarController?.updateForgeDiagnostic(
            persistentFailureText: repositoryStatusBarController?.currentForgePresentation.toolbarPersistentFailureText,
            statusBarVisible: ApplicationSettings.repositoryStatusBarVisible
        )
    }

    func presentForgeStatusDetails(
        _ action: ForgeStatusDetailsAction,
        recoveryCopyOverride: ForgeSQLiteRecoveryCopy? = nil,
        revealRecoveryCopy: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        let details = RepositoryForgeDiagnosticDetailsPresenter.present(action)
        let recoveryCopy = recoveryCopyOverride ?? repositoryForgeOverlaySession?.recoveryCopy
        if action == .recoverForgeData {
            if let recoveryCopyOverride {
                presentForgeRecoveryAlert(
                    recoveryCopies: [recoveryCopyOverride],
                    currentRecoveryCopy: recoveryCopyOverride,
                    revealRecoveryCopy: revealRecoveryCopy
                )
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    let retainedCopies = (try? await ApplicationComposition.shared.forgeServices
                        .retainedRecoveryCopies()) ?? []
                    let candidates = recoveryCopy.map { copy in
                        retainedCopies.contains(where: { $0.url == copy.url })
                            ? retainedCopies
                            : retainedCopies + [copy]
                    } ?? retainedCopies
                    let copies = candidates.filter {
                        FileManager.default.fileExists(atPath: $0.url.path)
                    }
                    self.presentForgeRecoveryAlert(
                        recoveryCopies: copies,
                        currentRecoveryCopy: recoveryCopy.flatMap { current in
                            copies.first { $0.url == current.url }
                        } ?? copies.last,
                        revealRecoveryCopy: revealRecoveryCopy
                    )
                }
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = details.title
        alert.informativeText = details.message
        alert.addButton(withTitle: "OK")
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    private func presentForgeRecoveryAlert(
        recoveryCopies: [ForgeSQLiteRecoveryCopy],
        currentRecoveryCopy: ForgeSQLiteRecoveryCopy?,
        revealRecoveryCopy: @escaping (URL) -> Void
    ) {
        let copies = Dictionary(grouping: recoveryCopies, by: { $0.url.standardizedFileURL })
            .compactMap(\.value.first)
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.createdAt < $1.createdAt }
        let presentation = ForgeRecoveryAlertPresentation.make(recoveryCopies: copies)
        let alert = NSAlert()
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        presentation.buttonTitles.forEach { alert.addButton(withTitle: $0) }
        let copySelector: NSPopUpButton? = if copies.count > 1 {
            NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 420, height: 26),
                pullsDown: false
            )
        } else {
            nil
        }
        if let copySelector {
            copySelector.addItems(withTitles: copies.map(\.url.lastPathComponent))
            copySelector.setAccessibilityIdentifier("ForgeRecoveryCopySelector")
            copySelector.setAccessibilityLabel("Recovery copy")
            if let currentRecoveryCopy,
               let index = copies.firstIndex(where: { $0.url == currentRecoveryCopy.url })
            {
                copySelector.selectItem(at: index)
            }
            alert.accessoryView = copySelector
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let action = ForgeRecoveryAlertAction(response: response) else { return }
            let selectedCopy = copySelector.flatMap { selector in
                copies.indices.contains(selector.indexOfSelectedItem)
                    ? copies[selector.indexOfSelectedItem]
                    : nil
            } ?? currentRecoveryCopy.flatMap { current in
                copies.first { $0.url == current.url }
            } ?? copies.first
            if action == .revealInFinder, let selectedCopy {
                revealRecoveryCopy(selectedCopy.url)
                return
            }
            self.performForgeRecoveryAction(action, recoveryCopy: selectedCopy)
        }
    }

    private func performForgeRecoveryAction(
        _ action: ForgeRecoveryAlertAction,
        recoveryCopy: ForgeSQLiteRecoveryCopy?
    ) {
        switch action {
        case .retry:
            Task { [weak self] in
                do {
                    _ = try await ApplicationComposition.shared.forgeServices.retryForgeRecovery(recoveryCopy)
                } catch {
                    self?.presentForgeRecoveryOperationFailure()
                }
            }
        case .resetForgeData:
            confirmForgeDataReset()
        case .notNow:
            Task {
                await ApplicationComposition.shared.forgeServices.disableForgeForSession()
            }
        case .revealInFinder:
            break
        case .deleteNow:
            guard let recoveryCopy else { return }
            Task { [weak self] in
                do {
                    try await ApplicationComposition.shared.forgeServices.deleteRecoveryCopy(recoveryCopy)
                } catch {
                    self?.presentForgeRecoveryOperationFailure()
                }
            }
        }
    }

    private func confirmForgeDataReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Forge Data?"
        alert.informativeText = """
        This permanently removes cached Forge data and any unrecovered drafts. GitHub accounts, Keychain credentials, and repository bindings are preserved. Trusted external-link origins are cleared.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset Forge Data")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                do {
                    try await ApplicationComposition.shared.forgeServices.resetForgeData()
                } catch {
                    self?.presentForgeRecoveryOperationFailure()
                }
            }
        }
    }

    private func reloadRepositoryForgeOverlaySession() {
        repositoryForgeOverlaySession?.invalidate()
        repositoryForgeOverlaySession = nil
        installRepositoryForgeOverlaySession()
        if let repositoryForgeOverlaySession {
            repositoryStatusBarController?.bind(to: repositoryForgeOverlaySession)
        }
        updateToolbarForgeDiagnostic()
        NSLog("[GitX] Reloaded the repository Forge overlay after a recovery action")
    }

    private func presentForgeRecoveryOperationFailure() {
        let alert = NSAlert()
        alert.messageText = "Forge Recovery Did Not Complete"
        alert.informativeText = "The recovery copy remains available. Local Git is unaffected; choose Details to retry, reset Forge data, or defer recovery."
        alert.addButton(withTitle: "OK")
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    #if DEBUG
        @objc(repositoryForgeOverlaySessionIdentityForTesting)
        // Objective-C app-hosted tests compare this opaque identity across availability reloads.
        // swiftlint:disable:next unused_declaration
        dynamic func repositoryForgeOverlaySessionIdentityForTesting() -> UInt {
            guard let repositoryForgeOverlaySession else { return 0 }
            return UInt(bitPattern: ObjectIdentifier(repositoryForgeOverlaySession))
        }

        @objc(presentForgeRecoveryStatusDetailsWithCopyURL:)
        // Objective-C app-hosted tests invoke this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        dynamic func presentForgeRecoveryStatusDetails(copyURL: URL) {
            presentForgeStatusDetails(
                .recoverForgeData,
                recoveryCopyOverride: ForgeSQLiteRecoveryCopy(url: copyURL, createdAt: Date())
            )
        }

        @objc(presentForgeRecoveryStatusDetailsWithCopyURL:revealHandler:)
        // Objective-C app-hosted tests invoke this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        dynamic func presentForgeRecoveryStatusDetails(
            copyURL: URL,
            revealHandler: @escaping (URL) -> Void
        ) {
            presentForgeStatusDetails(
                .recoverForgeData,
                recoveryCopyOverride: ForgeSQLiteRecoveryCopy(url: copyURL, createdAt: Date()),
                revealRecoveryCopy: revealHandler
            )
        }

        @objc(presentForgeRecoveryStatusDetailsWithCopyURLs:revealHandler:)
        // Objective-C app-hosted tests invoke this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        dynamic func presentForgeRecoveryStatusDetails(
            copyURLs: [URL],
            revealHandler: @escaping (URL) -> Void
        ) {
            let copies = copyURLs.enumerated().map { index, url in
                ForgeSQLiteRecoveryCopy(
                    url: url,
                    createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
                )
            }
            presentForgeRecoveryAlert(
                recoveryCopies: copies,
                currentRecoveryCopy: copies.first,
                revealRecoveryCopy: revealHandler
            )
        }
    #endif

    @objc(showForgeStatusDetails:)
    // AppKit dispatches this target/action selector through the responder chain.
    // swiftlint:disable:next unused_declaration
    dynamic func showForgeStatusDetails(_ sender: Any?) {
        repositoryStatusBarController?.requestCurrentDetails()
    }

    @IBAction dynamic func jumpToCheckedOutBranch(_ sender: Any?) {
        NSLog("[GitX] Jumping to the repository's checked-out branch")
        repository?.reloadRefs()
        repository?.readCurrentBranch()
        _sidebarController?.selectCurrentBranch()
    }

    @IBAction dynamic func showRepositorySettings(_ sender: Any?) {
        WindowDialogPresenter.showRepositorySettings(for: self)
    }

    @objc open dynamic func showCommitHookFailedSheet(
        _ messageText: String,
        infoText: String,
        retryHandler: (() -> Void)?
    ) {
        showCommitHookFailedSheet(messageText, infoText: infoText, retryHandler: retryHandler, cancelHandler: nil)
    }

    @objc open dynamic func showCommitHookFailedSheet(
        _ messageText: String, infoText: String, retryHandler: (() -> Void)?, cancelHandler: (() -> Void)?
    ) {
        WindowDialogPresenter.showCommitHookFailedSheet(messageText, infoText: infoText,
                                                        retryHandler: retryHandler, cancelHandler: cancelHandler, for: self)
    }

    @objc open dynamic func showMessageSheet(_ messageText: String, infoText: String) {
        WindowDialogPresenter.showMessageSheet(messageText, infoText: infoText, for: self)
    }

    @objc open dynamic func showErrorSheet(_ error: Error) {
        WindowDialogPresenter.showErrorSheet(error, for: self)
    }

    @discardableResult
    @objc open dynamic func confirmDialog(
        _ alert: NSAlert,
        suppressionIdentifier identifier: String?,
        forAction actionBlock: @escaping () -> Void
    ) -> Bool {
        WindowDialogPresenter.confirmDialog(
            alert,
            suppressionIdentifier: identifier,
            for: self,
            action: actionBlock
        )
    }

    @discardableResult
    @objc(confirmDialog:suppressionIdentifier:onCancel:forAction:)
    open dynamic func confirmDialog(
        _ alert: NSAlert,
        suppressionIdentifier identifier: String?,
        onCancel: @escaping () -> Void,
        forAction actionBlock: @escaping () -> Void
    ) -> Bool {
        WindowDialogPresenter.confirmDialog(
            alert,
            suppressionIdentifier: identifier,
            for: self,
            onCancel: onCancel,
            action: actionBlock
        )
    }
}
