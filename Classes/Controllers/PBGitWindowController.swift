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

/// Global presentation intent survives repository replacement; closure discards it.
nonisolated struct RepositoryWindowRefreshIntents {
    private(set) var activated = false
    private(set) var preferences = false
    var hasPending: Bool {
        activated || preferences
    }

    mutating func record(activated: Bool = false, preferences: Bool = false) {
        self.activated = self.activated || activated
        self.preferences = self.preferences || preferences
    }

    mutating func consume(ready: Bool) -> Self? {
        guard ready, hasPending else { return nil }
        let result = self
        self = Self()
        return result
    }

    mutating func discard() {
        self = Self()
    }
}

nonisolated struct RepositoryWindowRefreshDelivery {
    let metadataIsCurrent: Bool
    let intent: RepositoryWindowRefreshIntents

    var preparesMetadata: Bool {
        !metadataIsCurrent || intent.preferences || intent.activated
    }
}

nonisolated enum RepositoryWindowActionAvailability {
    static func error(gitUnavailable: Bool, discoveryError: Error?) -> Error {
        if gitUnavailable, let discoveryError {
            return discoveryError
        }
        let message = gitUnavailable ? "Git is not ready for this action. Try again when Git becomes available." :
            "The repository is not available for this action. Try again after the window finishes updating."
        return NSError(domain: "GitX.WindowAction", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Unavailable repository action")])
    }
}

/// Read queries can inspect a coherent owner but cannot install or revoke one.
nonisolated struct RepositoryWindowQueryPolicy {
    enum Decision: Equatable { case current, reconcileLater, unavailable }
    var closed = false
    var reconciling = false
    var repository: ObjectIdentifier?
    var currentOwner: RepositoryWindowOwnership.Identity?
    var installedOwner: RepositoryWindowOwnership.Identity?
    var paneRepository: ObjectIdentifier?
    var actionRepository: ObjectIdentifier?
    var facetsMatch = true
    var selectionMatches = true

    var decision: Decision {
        guard !closed, !reconciling else { return .unavailable }
        guard let repository else {
            return installedOwner != nil || paneRepository != nil || actionRepository != nil ? .reconcileLater : .unavailable
        }
        guard installedOwner == nil || installedOwner == currentOwner,
              paneRepository == nil || paneRepository == repository,
              actionRepository == nil || actionRepository == repository,
              facetsMatch, selectionMatches else { return .reconcileLater }
        return .current
    }
}

/// Prepared Forge metadata can be queried without discovering or persisting bindings.
nonisolated struct RepositoryForgeQueryPresentation {
    let repository: ObjectIdentifier
    let owner: RepositoryWindowOwnership.Identity?
    let generation: UInt64
    let selection: GitBinarySelection?
    let providerName: String?
    let isAvailable: Bool
    var binding: ForgeRepositoryBinding? = nil

    func matches(repository: ObjectIdentifier, owner: RepositoryWindowOwnership.Identity?, generation: UInt64, selection: GitBinarySelection?) -> Bool {
        self.repository == repository && self.owner == owner && self.generation == generation && self.selection == selection
    }
}

/// One synchronous decision retains its repository and presentation facets together.
@MainActor
private struct RepositoryWindowContext {
    let repository: PBGitRepository
    let owner: RepositoryWindowOwnership.Identity?
    let generation: UInt64
    let selection: GitBinarySelection?
    let window: NSWindow?
    let history: PBGitHistoryController?
    let sidebar: PBGitSidebarController?
}

nonisolated struct RepositoryWindowPreferenceRevision: Equatable {
    let repository: ObjectIdentifier?
    let refreshOnFocus: Bool
    let statusBarVisible: Bool
    let binding: ForgeRepositoryBinding?
}

/// Retains the repository until its reads and subscriptions have been revoked.
@MainActor
private final class RepositoryWindowLifetime {
    let repository: PBGitRepository
    let identity: RepositoryWindowOwnership.Identity
    var focus: RepositoryFocusRefreshCoordinator?
    var status: RepositoryLocalStatusLoader?
    var statusCoalescer: RefreshCoalescer?
    var forgeMetadataCoalescer: RefreshCoalescer?
    var referenceStatusRefresh = RepositoryStatusReferenceRefreshPolicy()
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
        PBRepositoryWorktreeService.cancelPreparations(forOwner: worktreeOwner, in: services)
        focus?.cancel()
        status?.cancel()
        statusCoalescer?.cancel()
        statusCoalescer = nil
        forgeMetadataCoalescer?.cancel()
        forgeMetadataCoalescer = nil
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
    private weak var panePresentationWindow: NSWindow?
    private var actionRepository: ObjectIdentifier?
    private var isReconcilingOwnership = false
    private var pendingOwnershipReconciliation = false
    private var pendingRefreshIntents = RepositoryWindowRefreshIntents()
    private var isDeliveringRefreshIntents = false
    private var observedPreferenceRevision: RepositoryWindowPreferenceRevision?
    private var synchronousActionContext: RepositoryWindowContext?
    private var synchronousQueryContext: RepositoryWindowContext?
    private var globalOwnerNotifications: [NSObjectProtocol] = []
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
    private var repositoryForgeCoordinator: RepositoryForgeCoordinator?
    private var forgeQueryPresentation: RepositoryForgeQueryPresentation?
    final var repositoryForgeLinkUseCase: RepositoryForgeLinkUseCase?
    private var repositoryToolbarController: RepositoryToolbarController?
    private(set) final var createPullRequestControl = ForgeMutationControlPresentation.hidden
    #if DEBUG
        private var milestone2UITestHarness: Milestone2UITestHarness?
        private var milestone3UITestHarness: Milestone3UITestHarness?
    #endif
    private var repositoryStatusBarController: RepositoryStatusBarController?
    private(set) final var repositoryForgeOverlaySession: RepositoryForgeOverlaySession? {
        didSet {
            guard oldValue !== repositoryForgeOverlaySession else { return }
            guard let history = _historyViewController, history.isViewLoaded else { return }
            (history.commitList.delegate as? HistoryTableInteractionCoordinator)?.bindForgeSession(repositoryForgeOverlaySession)
        }
    }

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
                repositoryToolbarController?.uninstall()
                panePresentationWindow = nil
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
        globalOwnerNotifications.forEach(self.ownerNotifications.removeObserver)
        globalOwnerNotifications.removeAll()
        pendingRefreshIntents.discard()
        self.ownerNotifications = ownerNotifications
        observedPreferenceRevision = nil
        installGlobalOwnerNotificationsIfNeeded()
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
        guard !isReconcilingOwnership else { return }
        reconcileOwnership()
    }

    private final func context(for repository: PBGitRepository) -> RepositoryWindowContext {
        RepositoryWindowContext(repository: repository, owner: ownerIdentity(for: repository), generation: ownership.generation,
                                selection: gitDiscovery.currentSelection, window: isWindowLoaded ? super.window : nil,
                                history: historyViewController, sidebar: sidebarViewController)
    }

    private final func queryContext() -> RepositoryWindowContext? {
        let repository = repository
        let captured = repository.map { context(for: $0) }
        let policy = RepositoryWindowQueryPolicy(
            closed: ownership.closed, reconciling: isReconcilingOwnership,
            repository: repository.map(ObjectIdentifier.init), currentOwner: captured?.owner,
            installedOwner: lifetime?.identity, paneRepository: paneRepository, actionRepository: actionRepository,
            facetsMatch: ((_historyViewController?.repository).map { $0 === repository } ?? true) &&
                ((_sidebarController?.repository).map { $0 === repository } ?? true),
            selectionMatches: gitLoaderSelection == nil || gitLoaderSelection == captured?.selection
        )
        switch policy.decision {
        case .current: return captured
        case .reconcileLater:
            scheduleOwnershipReconciliation()
            return nil
        case .unavailable: return nil
        }
    }

    private final func acceptsAction(_ context: RepositoryWindowContext) -> Bool {
        !ownership.closed && !isReconcilingOwnership && ownership.generation == context.generation &&
            repository === context.repository && ownerIdentity(for: context.repository) == context.owner &&
            gitDiscovery.currentSelection == context.selection
    }

    /// Nested dynamic facades share the admitted capture rather than retargeting it.
    private final func withActionContext(requiresGit: Bool, validIntent: Bool = true,
                                         validateInput: ((RepositoryWindowContext) -> Bool)? = nil,
                                         _ action: (RepositoryWindowContext) -> Void)
    {
        guard validIntent, !ownership.closed, !isReconcilingOwnership else { return }
        if let captured = synchronousActionContext {
            guard acceptsAction(captured) else { return }
            guard validateInput?(captured) != false else { return }
            guard !requiresGit || captured.selection != nil else {
                presentActionAvailabilityError(gitUnavailable: true)
                return
            }
            action(captured)
            return
        }
        reconcileOwnership()
        guard let captured = queryContext() else {
            presentActionAvailabilityError(gitUnavailable: false)
            return
        }
        guard validateInput?(captured) != false else { return }
        guard !requiresGit || captured.selection != nil else {
            presentActionAvailabilityError(gitUnavailable: true)
            return
        }
        synchronousActionContext = captured
        defer { synchronousActionContext = nil }
        action(captured)
    }

    private final func presentActionAvailabilityError(gitUnavailable: Bool) {
        guard !ownership.closed, !isReconcilingOwnership, isWindowLoaded,
              ownership.identity == currentOwnerIdentity(), ownership.identity != nil else { return }
        NSLog("[GitX] Refused unavailable explicit action; Git unavailable %@", gitUnavailable ? "yes" : "no")
        showErrorSheet(RepositoryWindowActionAvailability.error(gitUnavailable: gitUnavailable, discoveryError: gitDiscovery.currentAvailabilityError))
    }

    final func performCheckedOutBranchAction(_ action: (PBGitRef) -> Void) {
        withActionContext(requiresGit: false) { context in
            guard let head = context.repository.headRef()?.ref(), head.isBranch else { return }
            action(head)
        }
    }

    private final func hasReferenceIntent(_ sender: Any?, types: [String]) -> Bool {
        RepositoryActionContextResolver.hasRepresentedIntent((sender as? NSMenuItem)?.representedObject, allowedTypes: types)
    }

    private func configuredRemoteIntent(_ sender: Any?, types: [String], context: RepositoryWindowContext) -> Bool {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return true }
        let names = (try? context.repository.gtRepo?.remoteNames()) ??
            (context.selection == nil ? nil : context.repository.remotes())
        return RepositoryActionContextResolver.hasRepresentedIntent(name, allowedTypes: types, configuredRemotes: names)
    }

    private final func installActionCoordinators(repository: PBGitRepository?, identity: RepositoryWindowOwnership.Identity?, gitAvailable: Bool) {
        guard let repository else { resetActionCoordinators(); return }
        let locationAvailable = gitAvailable || repository.gitURL() != nil
        guard identity == currentOwnerIdentity(), !ownership.closed, locationAvailable else { resetActionCoordinators(); return }
        if actionRepository != ObjectIdentifier(repository) {
            resetActionCoordinators()
            actionRepository = ObjectIdentifier(repository)
        }
        if actionContextResolver == nil {
            actionContextResolver = RepositoryActionContextResolver()
        }
        // Legacy repository subclasses may expose a location without ObjectiveGit.
        // Read-only context and Finder/Terminal policy remain usable; Git work
        // still requires the complete validated lifetime below.
        guard gitAvailable, lifetime?.identity == identity, lifetime?.repository === repository else { return }
        if remoteActionCoordinator == nil {
            remoteActionCoordinator = RepositoryRemoteActionCoordinator(repository: repository, windowController: self, progressStarting: remoteProgressStarting)
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
                createPullRequestControlResolving: makeCreatePullRequestControlResolver()
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
    }

    private final func invalidateGitLoaders() {
        // Revoke callback authority before either cancellation can deliver a result.
        gitLoaderLifecycle.invalidate()
        lifetime?.statusCoalescer?.cancel()
        lifetime?.statusCoalescer = nil
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
        let identity = RepositoryGitLoaderLifecycle.Identity(repository: ObjectIdentifier(repository), selection: selection)
        guard gitLoaderLifecycle.requiresInstallation(identity, hasFocus: focusRefreshCoordinator != nil, hasStatus: repositoryLocalStatusLoader != nil) else { return false }
        guard repository.workingDirectoryURL() != nil || repository.gitURL() != nil else { return false }
        let ownerGeneration = ownership.generation
        invalidateGitLoaders()
        guard lifetime === scope, ownership.accepts(scope.identity, generation: ownerGeneration),
              self.repository === repository, gitDiscovery.currentSelection == selection else { return false }
        let generation = gitLoaderLifecycle.generation
        scope.referenceStatusRefresh = RepositoryStatusReferenceRefreshPolicy(baseline: referenceStatusIdentity(for: repository))
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
        ownerIdentity(for: repository)
    }

    private final func ownerIdentity(for repository: PBGitRepository?) -> RepositoryWindowOwnership.Identity? {
        guard isWindowLoaded, let window = super.window, let repository else { return nil }
        return .init(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window),
                     document: document.map(ObjectIdentifier.init))
    }

    final func reconciledWorktreeOwnership() -> (repository: PBGitRepository, service: PBRepositoryWorktreeService, owner: NSObject)? {
        guard !isReconcilingOwnership else { return nil }
        reconcileOwnership()
        return currentWorktreeOwnership()
    }

    final func currentWorktreeOwnership() -> (repository: PBGitRepository, service: PBRepositoryWorktreeService, owner: NSObject)? {
        guard !isReconcilingOwnership, !ownership.closed, let scope = lifetime, scope.identity == currentOwnerIdentity() else { return nil }
        let service = scope.repository.worktreeService
        if !scope.worktreeServices.contains(where: { $0 === service }) {
            scope.worktreeServices.append(service)
        }
        return (scope.repository, service, scope.worktreeOwner)
    }

    /// Presentation construction captures authority without installing an owner or starting Git.
    final func repositoryPresentationValidation(for repository: PBGitRepository?) -> () -> Bool {
        guard let repository else { return { false } }
        let generation = ownership.generation
        let identity = ownerIdentity(for: repository)
        let selection = gitDiscovery.currentSelection
        return { [weak self, weak repository] in
            guard let self, let repository, !self.ownership.closed, self.ownership.generation == generation,
                  self.repository === repository, self.gitDiscovery.currentSelection == selection else { return false }
            return self.currentOwnerIdentity() == identity
        }
    }

    /// Captured before asynchronous confirmation or work admission, never retargeted.
    final func repositoryOwnerValidation(for repository: PBGitRepository) -> () -> Bool {
        if !isReconcilingOwnership {
            reconcileOwnership()
        }
        let generation = ownership.generation
        let identity = currentOwnerIdentity()
        let repositoryID = ObjectIdentifier(repository)
        // Standalone coordinators historically supply their target before the
        // window has a document. That absence is itself captured ownership.
        let originatingRepository = self.repository.map(ObjectIdentifier.init)
        let matchesTarget = originatingRepository == nil || originatingRepository == repositoryID
        return { [weak self] in
            guard let self, matchesTarget, !self.ownership.closed, !self.isReconcilingOwnership, self.ownership.generation == generation,
                  self.repository.map(ObjectIdentifier.init) == originatingRepository else { return false }
            return self.currentOwnerIdentity() == identity
        }
    }

    final func makeCreatePullRequestControlResolver() -> () -> ForgeMutationControlPresentation {
        { [weak self] in self?.createPullRequestControl ?? .hidden }
    }

    private final func revokeOwner(closing: Bool = false) {
        // Revocation precedes cancellation, KVO removal and potentially reentrant UI work.
        ownership.revoke(closing: closing)
        approvedDocumentClose = nil
        pullRequestActivity = nil
        if closing {
            pendingRefreshIntents.discard()
            globalOwnerNotifications.forEach(ownerNotifications.removeObserver)
            globalOwnerNotifications.removeAll()
        }
        invalidateWorktreePresentation()
        invalidateGitLoaders()
        lifetime?.invalidate()
        lifetime = nil
        if let revoke = pullRequestOwnerRevocation {
            revoke()
        } else {
            pullRequestUIController?.invalidateOwner()
        }
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
        repositoryForgeCoordinator = nil
        forgeQueryPresentation = nil
        repositoryForgeLinkUseCase = nil
    }

    private final func ensureLifetime(repository: PBGitRepository?, identity: RepositoryWindowOwnership.Identity?) -> Bool {
        guard !ownership.closed else { return false }
        if lifetime != nil, lifetime?.identity != identity {
            revokeOwner()
        }
        let available = repository?.gtRepo != nil && repository?.gitURL() != nil
        if lifetime != nil, !available {
            revokeOwner()
        }
        guard available else { return false }
        guard let identity, let repository else { return true }
        guard lifetime?.identity != identity else { return true }
        ownership.install(identity)
        let scope = RepositoryWindowLifetime(repository: repository, identity: identity, notificationCenter: ownerNotifications)
        lifetime = scope
        if worktreeRepairRepository !== repository {
            worktreeRepairRepository = repository
            offeredWorktreeRepair = repairOfferedRepositories.contains(repository)
        }
        let generation = ownership.generation
        // Registration is synchronous. Keep its inputs alive here; only the
        // installed notification callbacks need weak owner references.
        let observe: (Notification.Name, AnyObject?, @escaping @MainActor @Sendable (PBGitWindowController, String?) -> Void) -> Void = { [self, scope] name, object, action in
            let token = scope.notificationCenter.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
                if name == .PBGitRepositoryEvent,
                   let raw = notification.userInfo?[kPBGitRepositoryEventTypeUserInfoKey] as? NSNumber,
                   raw.uintValue & PBGitRepositoryWatcherEventType.gitDirectory.rawValue == 0
                {
                    return
                }
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
                // Publishers may hold nonrecursive repository locks. Only close
                // revocation is synchronous; every other event crosses a queue boundary.
                if Thread.isMainThread, name == NSWindow.willCloseNotification {
                    // swift6-safety-justification: AppKit notifications delivered on the main thread run on its actor executor.
                    MainActor.assumeIsolated(deliver)
                } else {
                    DispatchQueue.main.async(execute: deliver)
                }
            }
            scope.notifications.append(token)
        }
        observe(.PBGitBinaryDidChange, nil) { owner, _ in owner.scheduleOwnershipReconciliation() }
        observe(NSNotification.Name(PBGitIndexIndexUpdated), repository.index) { owner, _ in
            owner.repositoryLocalStatusDidChange(Notification(name: NSNotification.Name(PBGitIndexIndexUpdated)))
        }
        observe(.repositoryRemoteOperationDidSucceed, repository) { owner, operation in
            owner.repositoryRemoteOperationDidSucceed(Notification(name: .repositoryRemoteOperationDidSucceed, userInfo: operation.map { ["operation": $0] }))
        }
        observe(.PBGitRepositoryEvent, repository) { owner, _ in
            owner.requestLocalStatusRefresh()
            owner.requestForgeQueryRefresh()
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
            repository.observe(\.refs, options: []) { [weak self, weak scope] _, _ in
                Task { @MainActor [weak self, weak scope] in
                    guard let self, let scope,
                          self.ownership.accepts(identity, generation: generation), self.currentOwnerIdentity() == identity else { return }
                    if scope.referenceStatusRefresh.needsRefresh(for: self.referenceStatusIdentity(for: scope.repository)) {
                        self.requestLocalStatusRefresh()
                        NSLog("[GitX] Requested local status after HEAD or references changed, owner generation %llu", generation)
                    }
                }
            },
        ]
        NSLog("[GitX] Installed repository subscriptions generation %llu", generation)
        return true
    }

    @discardableResult
    private final func reconcileOwnership(prepareForgeMetadata: Bool = true) -> Bool {
        guard !ownership.closed else { return false }
        installGlobalOwnerNotificationsIfNeeded()
        guard !isReconcilingOwnership else {
            scheduleOwnershipReconciliation()
            return false
        }
        isReconcilingOwnership = true
        defer {
            isReconcilingOwnership = false
            if observedPreferenceRevision == nil {
                observedPreferenceRevision = capturePreferenceRevision()
            }
            if !isDeliveringRefreshIntents, pendingRefreshIntents.hasPending, hasCurrentLifetime {
                scheduleOwnershipReconciliation()
            }
        }
        let repository = repository
        let identity = ownerIdentity(for: repository)
        let repositoryID = repository.map(ObjectIdentifier.init)
        let previousRepository = paneRepository ?? lifetime?.identity.repository ?? actionRepository
        let repositoryAvailable = ensureLifetime(repository: repository, identity: identity)
        if !repositoryAvailable || (previousRepository != nil && previousRepository != repositoryID) {
            closeRepositoryPanes()
        }
        installActionCoordinators(repository: repository, identity: identity, gitAvailable: repositoryAvailable)
        guard lifetime != nil else {
            if prepareForgeMetadata {
                prepareForgeQueryPresentation()
            }
            if isWindowLoaded {
                super.window?.representedURL = nil
            }
            return false
        }
        if prepareForgeMetadata {
            reconcileForgePresentation()
        }
        return reconcileGitLoaders()
    }

    private final var hasCurrentLifetime: Bool {
        lifetime != nil && lifetime?.identity == currentOwnerIdentity() && !ownership.closed
    }

    private final func installGlobalOwnerNotificationsIfNeeded() {
        guard globalOwnerNotifications.isEmpty else { return }
        let notificationSource = ObjectIdentifier(ownerNotifications)
        for (name, activated, preferences) in [(NSApplication.didBecomeActiveNotification, true, false), (UserDefaults.didChangeNotification, false, true)] {
            let token = ownerNotifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Global intent belongs to the controller, not an obsolete repository generation.
                // Defer all settings access until the notification publisher has returned.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.ownership.closed, ObjectIdentifier(self.ownerNotifications) == notificationSource else { return }
                    if preferences {
                        let revision = self.capturePreferenceRevision()
                        guard revision != self.observedPreferenceRevision else { return }
                        self.observedPreferenceRevision = revision
                    }
                    self.scheduleOwnershipReconciliation(activated: activated, preferences: preferences)
                }
            }
            globalOwnerNotifications.append(token)
        }
    }

    private final func capturePreferenceRevision() -> RepositoryWindowPreferenceRevision {
        let repository = repository
        return RepositoryWindowPreferenceRevision(repository: repository.map(ObjectIdentifier.init),
                                                  refreshOnFocus: RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation(),
                                                  statusBarVisible: ApplicationSettings.repositoryStatusBarVisible,
                                                  binding: repository.flatMap { actionRepository == ObjectIdentifier($0) ? repositoryForgeCoordinator?.storedBinding : nil })
    }

    private final func scheduleOwnershipReconciliation(activated: Bool = false, preferences: Bool = false) {
        guard !ownership.closed else { return }
        pendingRefreshIntents.record(activated: activated, preferences: preferences)
        guard !pendingOwnershipReconciliation else { return }
        pendingOwnershipReconciliation = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingOwnershipReconciliation = false
            guard !self.ownership.closed else { return }
            self.deliverRefreshIntents()
        }
    }

    private func deliverRefreshIntents() {
        guard !ownership.closed else { return }
        guard !isDeliveringRefreshIntents, !isReconcilingOwnership else {
            scheduleOwnershipReconciliation()
            return
        }
        isDeliveringRefreshIntents = true
        defer {
            isDeliveringRefreshIntents = false
            if pendingRefreshIntents.hasPending, hasCurrentLifetime {
                scheduleOwnershipReconciliation()
            }
        }
        let capturedInitialFocus = reconcileOwnership(prepareForgeMetadata: false)
        guard hasCurrentLifetime else {
            // Metadata-only and deliberately suppressed owners still need a
            // settled unavailable snapshot, without consuming global intent.
            if pendingRefreshIntents.preferences {
                applyRefreshPreferencePresentation()
            }
            if pendingRefreshIntents.preferences || !forgeQueryPresentationIsCurrent(for: repository) {
                prepareForgeQueryPresentation()
            }
            return
        }
        let intent = pendingRefreshIntents.consume(ready: true) ?? RepositoryWindowRefreshIntents()
        let generation = ownership.generation
        if intent.preferences {
            applyRefreshPreferencePresentation()
        }
        guard hasCurrentLifetime, generation == ownership.generation else {
            pendingRefreshIntents.record(activated: intent.activated, preferences: intent.preferences)
            return
        }
        let delivery = RepositoryWindowRefreshDelivery(metadataIsCurrent: forgeQueryPresentationIsCurrent(for: repository), intent: intent)
        reconcileForgePresentation(forceMetadata: delivery.preparesMetadata)
        guard hasCurrentLifetime, generation == ownership.generation else {
            pendingRefreshIntents.record(activated: intent.activated, preferences: intent.preferences)
            return
        }
        if intent.activated {
            if !capturedInitialFocus {
                focusRefreshCoordinator?.applicationDidBecomeActive()
            }
            repositoryForgeOverlaySession?.requestRefresh(reason: .applicationActivated)
        }
        NSLog("[GitX] Applied owner delivery activation=%@ preferences=%@ metadata=%@ generation=%llu", intent.activated ? "yes" : "no", intent.preferences ? "yes" : "no", delivery.preparesMetadata ? "yes" : "no", generation)
    }

    private final var suppressesRepositoryForgeSession: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["GITX_M2_UITEST"] == "1"
        #else
            false
        #endif
    }

    private func reconcileForgePresentation(forceMetadata: Bool = false) {
        let suppressed = suppressesRepositoryForgeSession
        if nibPresentationReady, !suppressed {
            _ = forgeCoordinator
        }
        let needsPreparation = forceMetadata || !forgeQueryPresentationIsCurrent(for: repository) ||
            (nibPresentationReady && repositoryForgeOverlaySession == nil && !suppressed)
        let preparation: RepositoryForgeBindingResolution?
        if suppressed {
            if needsPreparation {
                _ = prepareForgeQueryPresentation()
            }
            preparation = nil
        } else if needsPreparation {
            preparation = prepareForgeQueryPresentation()
        } else {
            preparation = nil
        }
        installRepositoryPanesIfReady(forgePreparation: preparation)
    }

    private final func referenceStatusIdentity(for repository: PBGitRepository) -> RepositoryStatusReferenceIdentity? {
        RepositoryStatusReferenceIdentity.capture(references: repository.refs,
                                                  headReference: repository.headRef()?.simpleRef(), headObject: repository.headOID()?.sha)
    }

    private final func requestLocalStatusRefresh() {
        guard !ownership.closed, let scope = lifetime, scope.identity == currentOwnerIdentity() else { return }
        if scope.statusCoalescer == nil {
            let generation = ownership.generation
            scope.statusCoalescer = RefreshCoalescer(label: "repository-status") { [weak self, weak scope] in
                guard let self, let scope, self.ownership.accepts(scope.identity, generation: generation),
                      self.currentOwnerIdentity() == scope.identity else { return }
                self.repositoryLocalStatusLoader?.refresh()
            }
        }
        scope.statusCoalescer?.requestRefresh()
    }

    private final func requestForgeQueryRefresh() {
        guard !ownership.closed, let scope = lifetime, scope.identity == currentOwnerIdentity() else { return }
        if scope.forgeMetadataCoalescer == nil {
            let generation = ownership.generation
            scope.forgeMetadataCoalescer = RefreshCoalescer(label: "Forge-metadata") { [weak self, weak scope] in
                guard let self, let scope, self.ownership.accepts(scope.identity, generation: generation),
                      self.currentOwnerIdentity() == scope.identity else { return }
                self.prepareForgeQueryPresentation()
            }
        }
        scope.forgeMetadataCoalescer?.requestRefresh()
    }

    final func requestForgeMetadataReconciliation() {
        guard !ownership.closed else { return }
        forgeQueryPresentation = nil
        scheduleOwnershipReconciliation()
    }

    final func recordWorktreeRepairOffer(for repository: PBGitRepository) {
        repairOfferedRepositories.add(repository)
        if worktreeRepairRepository === repository {
            offeredWorktreeRepair = true
        }
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
        panePresentationWindow = nil
        repositoryToolbarController?.uninstall()
        repositoryToolbarController = nil
        if isWindowLoaded, repository == nil {
            super.window?.representedURL = nil
        }
        if ownership.closed {
            repositoryStatusBarController?.uninstall()
            repositoryStatusBarController = nil
        }
    }

    private final func installRepositoryPanesIfReady(forgePreparation: RepositoryForgeBindingResolution?) {
        guard nibPresentationReady, let repository, let window = super.window,
              sourceSplitView?.window === window, contentSplitView?.window === window else { return }
        if window.delegate == nil {
            window.delegate = self
        }
        // History binds its facts and badges while its view is mounted.
        // Make the repository session available before constructing either pane.
        if let resolution = forgePreparation {
            installRepositoryForgeOverlaySession(resolution: resolution)
        }
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
        if panePresentationWindow !== window {
            window.representedURL = repository.workingDirectoryURL()
            panePresentationWindow = window
        }
        if repositoryToolbarController == nil {
            repositoryToolbarController = RepositoryToolbarController(windowController: self, repository: repository)
        }
        updatePreparedToolbarForgePresentation()
        repositoryToolbarController?.install()
        if repositoryStatusBarController == nil {
            installRepositoryStatusBar()
        }
    }

    isolated deinit {
        globalOwnerNotifications.forEach(ownerNotifications.removeObserver)
        ownership.revoke(closing: true)
        lifetime?.invalidate()
        if let revoke = pullRequestOwnerRevocation {
            revoke()
        } else {
            pullRequestUIController?.invalidateOwner()
        }
        repositoryForgeOverlaySession?.invalidate()
        repositoryStatusBarController?.uninstall()
        repositoryToolbarController?.uninstall()
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
        reconcileOwnership()
        offerWorktreeRepairIfNeeded(reconciling: false)
    }

    private weak var pullRequestCloseGuardOwner: NSObject?
    private var pullRequestCloseProtection: ((@escaping () -> Void) -> Bool)?
    private var pullRequestCloseDecision: ((@escaping (Bool) -> Void) -> Bool)?
    private var pullRequestOwnerRevocation: (() -> Void)?
    private var closingAfterDraftConfirmation = false
    private var approvedDocumentClose: ObjectIdentifier?

    final func approveDocumentClose(for document: NSDocument) {
        guard self.document === document else { return }
        approvedDocumentClose = ObjectIdentifier(document)
    }

    final func registerPullRequestCloseGuard(owner: NSObject, protection: @escaping (@escaping () -> Void) -> Bool, revoke: @escaping () -> Void,
                                             decision: ((@escaping (Bool) -> Void) -> Bool)? = nil)
    {
        if pullRequestCloseGuardOwner != nil, pullRequestCloseGuardOwner !== owner {
            pullRequestOwnerRevocation?()
        }
        pullRequestCloseGuardOwner = owner
        pullRequestCloseProtection = protection
        pullRequestCloseDecision = decision
        pullRequestOwnerRevocation = revoke
    }

    final func unregisterPullRequestCloseGuard(owner: NSObject) {
        if pullRequestCloseGuardOwner === owner {
            pullRequestCloseGuardOwner = nil
            pullRequestCloseProtection = nil
            pullRequestCloseDecision = nil
            pullRequestOwnerRevocation = nil
        }
    }

    final func requestPullRequestCloseDecision(_ completion: @escaping (Bool) -> Void) -> Bool {
        if let approvedDocumentClose, let document, approvedDocumentClose == ObjectIdentifier(document) {
            return false
        }
        guard !closingAfterDraftConfirmation, !ownership.closed, pullRequestCloseGuardOwner != nil,
              let protection = pullRequestCloseProtection else { return false }
        if let decision = pullRequestCloseDecision {
            return decision(completion)
        }
        return protection { completion(true) }
    }

    private func deferCloseForRecoveredText() -> Bool {
        guard !closingAfterDraftConfirmation, !ownership.closed else { return false }
        if pullRequestCloseGuardOwner != nil, let document = document as? PBGitRepositoryDocument,
           approvedDocumentClose != ObjectIdentifier(document)
        {
            document.requestRepositoryClose { _ in }
            return true
        }
        return requestPullRequestCloseDecision { [weak self] allowed in
            guard allowed else { return }
            guard let self, !self.ownership.closed else { return }
            self.closingAfterDraftConfirmation = true
            defer { self.closingAfterDraftConfirmation = false }
            self.close()
        }
    }

    @objc public dynamic func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === (isWindowLoaded ? super.window : nil) else { return true }
        return !deferCloseForRecoveredText()
    }

    override open func close() {
        guard !ownership.closed else { return }
        guard !deferCloseForRecoveredText() else { return }

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
        guard !ownership.closed else { return false }
        if menuItem.action == #selector(toggleRepositoryStatusBar(_:)) {
            menuItem.state = ApplicationSettings.repositoryStatusBarVisible ? .on : .off
            return true
        }
        let context = queryContext()
        let previous = synchronousQueryContext
        synchronousQueryContext = context
        defer { synchronousQueryContext = previous }
        if let action = RepositoryForgeLinkAction(selector: menuItem.action),
           let model = RepositoryForgeLinkMenuPresenter.itemModel(action: action, context: forgeLinkContext(for: context))
        {
            RepositoryForgeLinkMenuPresenter.apply(model: model, to: menuItem)
            return model.isEnabled
        }
        guard let context else { return false }
        let queryRepository = context.repository
        if let action = menuItem.action,
           ["checkout:", "merge:", "rebase:", "rebaseHeadBranch:", "cherryPick:", "resetSoft:",
            "stashSave:", "stashSaveWithKeepIndex:", "stashPop:", "stashApply:", "stashDrop:",
            "pullRemote:", "pullDefaultRemote:", "pullRebaseRemote:", "pullRebaseDefaultRemote:", "toolbarPull:",
            "deleteRef:", "createBranch:", "createTag:"].contains(NSStringFromSelector(action)),
           !CommitSubmissionEligibility.allowsMutation(queryRepository.index)
        {
            return false
        }
        if menuItem.action == #selector(newPullRequest(_:)) {
            menuItem.isHidden = !createPullRequestControl.isVisible
            menuItem.toolTip = createPullRequestControl.helpText
            return createPullRequestControl.isVisible && createPullRequestControl.isEnabled
        }
        if menuItem.action == #selector(revealInFinder(_:)) {
            return WorkspaceActionCoordinator(repository: queryRepository).hasRevealTarget
        }
        if menuItem.action == #selector(openInTerminal(_:)) {
            return WorkspaceActionCoordinator(repository: queryRepository).hasWorkingDirectory
        }
        if menuItem.action == #selector(showUncommittedChanges(_:)) {
            menuItem.state = isUncommittedChangesSelected ? .on : .off
            return !queryRepository.isBare()
        }
        if menuItem.action == #selector(showHistoryView(_:)) || menuItem.action == #selector(returnToHistory(_:)) {
            menuItem.state = isUncommittedChangesSelected || _sidebarController?.isReflogSelected == true ? .off : .on
            return !queryRepository.isBare()
        }
        if menuItem.action == #selector(showReflog(_:)) {
            menuItem.state = _sidebarController?.isReflogSelected == true ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleAmendCommit(_:)) {
            menuItem.state = queryRepository.index.isAmend ? .on : .off
            return CommitSubmissionEligibility.allowsMutation(queryRepository.index)
        }
        if menuItem.action == #selector(fetchRemote(_:)) {
            return validateMenuItem(menuItem, remoteTitle: "Fetch “%@”", plainTitle: "Fetch")
        }
        if menuItem.action == #selector(showRepositorySettings(_:)) {
            return true
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
        forgeLinkContext(for: queryContext())
    }

    private final func forgeQueryPresentationIsCurrent(for repository: PBGitRepository?) -> Bool {
        guard let repository else { return false }
        return forgeQueryPresentation?.matches(repository: ObjectIdentifier(repository), owner: ownerIdentity(for: repository), generation: ownership.generation, selection: gitDiscovery.currentSelection) == true
    }

    private final func forgeLinkContext(for context: RepositoryWindowContext?) -> RepositoryForgeLinkContext {
        guard let context, let presentation = forgeQueryPresentation,
              presentation.matches(repository: ObjectIdentifier(context.repository), owner: context.owner, generation: context.generation, selection: context.selection)
        else {
            if context != nil {
                scheduleOwnershipReconciliation()
            }
            return RepositoryForgeLinkContext(providerName: nil, isForgeAvailable: false, checkedOutRevision: nil, selectedCommitIdentifiers: [])
        }
        let repository = context.repository
        let headRef = repository.headRef()?.ref()
        let checkedOutRevision: RepositoryForgeLinkRevision?
        if let headRef, headRef.isBranch, let branchName = headRef.branchName {
            checkedOutRevision = .branch(branchName)
        } else if let identifier = repository.headOID()?.sha {
            checkedOutRevision = .commit(identifier)
        } else {
            checkedOutRevision = nil
        }
        let selectedCommitIdentifiers = (context.history?.selectedCommits ?? []).compactMap { commit in
            commit is PBUncommittedChanges ? nil : commit.sha
        }
        return RepositoryForgeLinkContext(
            providerName: presentation.providerName,
            isForgeAvailable: presentation.isAvailable,
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
        guard !ownership.closed, !isReconcilingOwnership else { return nil }
        ensureActionCoordinators()
        _ = forgeCoordinator
        guard prepareForgeQueryPresentation(force: true) != nil else { return nil }
        return repositoryForgeLinkUseCase
    }

    @discardableResult
    private final func prepareForgeQueryPresentation(force: Bool = false) -> RepositoryForgeBindingResolution? {
        guard !ownership.closed, let repository else { return nil }
        let identity = ownerIdentity(for: repository)
        let generation = ownership.generation
        let selection = gitDiscovery.currentSelection
        guard actionRepository == ObjectIdentifier(repository), let coordinator = repositoryForgeCoordinator else {
            forgeQueryPresentation = RepositoryForgeQueryPresentation(repository: ObjectIdentifier(repository), owner: identity, generation: generation,
                                                                      selection: selection, providerName: nil, isAvailable: false)
            updatePreparedToolbarForgePresentation()
            return nil
        }
        let resolution = force ? coordinator.resolveBinding() : coordinator.prepareQueryBinding(selection: selection)
        guard force || coordinator.preparedBindingIsCurrent, self.repository === repository, identity == currentOwnerIdentity(), generation == ownership.generation, selection == gitDiscovery.currentSelection, !ownership.closed else { return nil }
        forgeQueryPresentation = RepositoryForgeQueryPresentation(repository: ObjectIdentifier(repository), owner: identity, generation: generation, selection: selection,
                                                                  providerName: resolution.providerName, isAvailable: resolution.binding != nil || !resolution.candidates.isEmpty, binding: resolution.binding)
        updatePreparedToolbarForgePresentation()
        NSLog("[GitX] Prepared Forge menu metadata generation %llu, available %@", generation, forgeQueryPresentation?.isAvailable == true ? "yes" : "no")
        return resolution
    }

    private final func updatePreparedToolbarForgePresentation() {
        guard let presentation = forgeQueryPresentation, presentation.selection == gitDiscovery.currentSelection else { return }
        let generation = presentation.generation
        let identity = presentation.owner
        let repositoryID = presentation.repository
        repositoryToolbarController?.applyForgeMetadata(providerName: presentation.providerName, binding: presentation.binding) { [weak self] in
            guard let self, !self.ownership.closed, self.ownership.generation == generation,
                  let repository = self.repository else { return false }
            return ObjectIdentifier(repository) == repositoryID && self.ownerIdentity(for: repository) == identity
        }
    }

    @objc(validateMenuItem:remoteTitle:plainTitle:)
    dynamic func validateMenuItem(_ menuItem: NSMenuItem, remoteTitle: String, plainTitle: String) -> Bool {
        guard let context = synchronousQueryContext ?? queryContext() else { return false }
        let previous = synchronousQueryContext
        synchronousQueryContext = context
        defer { synchronousQueryContext = previous }
        let repository = context.repository
        guard let ref = selectedRef else { return false }
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
    // Kept as an Objective-C notification and subclass compatibility selector.
    // swiftlint:disable:next unused_declaration
    dynamic func applicationDidBecomeActive(_ notification: Notification) {
        pendingRefreshIntents.record(activated: true)
        deliverRefreshIntents()
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
    // Objective-C notification callers retain this synchronous compatibility selector.
    // swiftlint:disable:next unused_declaration
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
        pendingRefreshIntents.record(preferences: true)
        deliverRefreshIntents()
        observedPreferenceRevision = capturePreferenceRevision()
    }

    private func applyRefreshPreferencePresentation() {
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

    @IBAction dynamic func showReflog(_: Any?) {
        guard !ownership.closed else { return }
        _sidebarController?.showReflog()
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
        if let pullRequestActivity {
            displayedStatus = pullRequestActivity.message
            busy = busy || pullRequestActivity.isBusy
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

    private final var pullRequestActivity: RepositoryPullRequestActivity?

    final func setPullRequestActivity(_ activity: RepositoryPullRequestActivity) {
        guard !ownership.closed else { return }
        pullRequestActivity = activity
        updateStatus()
    }

    final func clearPullRequestActivity(_ identity: UUID) {
        guard pullRequestActivity?.identity == identity else { return }
        pullRequestActivity = nil
        updateStatus()
    }

    @objc(selectedURLsFromSender:)
    dynamic func selectedURLs(from sender: Any?) -> [URL]? {
        guard let context = synchronousActionContext ?? queryContext() else { return nil }
        return WorkspaceActionCoordinator(repository: context.repository).selectedURLs(from: representedObject(from: sender))
    }

    private func representedObject(from sender: Any?) -> Any? {
        let selector = NSSelectorFromString("representedObject")
        guard let object = sender as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @objc(openURLs:)
    open dynamic func open(_ fileURLs: [URL]?) {
        guard let fileURLs, !fileURLs.isEmpty else { return }
        withActionContext(requiresGit: false) { context in
            WorkspaceActionCoordinator(repository: context.repository).open(fileURLs)
        }
    }

    @objc(revealURLsInFinder:)
    open dynamic func revealURLs(inFinder fileURLs: [URL]?) {
        guard let fileURLs, !fileURLs.isEmpty else { return }
        withActionContext(requiresGit: false) { context in
            WorkspaceActionCoordinator(repository: context.repository).revealInFinder(fileURLs)
        }
    }

    @objc(refishForSender:refishTypes:)
    dynamic func refish(for sender: Any?, refishTypes types: [String]?) -> PBGitRefish? {
        guard let context = synchronousActionContext ?? queryContext() else { return nil }
        return refish(for: sender, types: types, context: context)
    }

    private final func refish(for sender: Any?, types: [String]?, context: RepositoryWindowContext) -> PBGitRefish? {
        let repository = context.repository
        let resolver = actionContextResolver ?? RepositoryActionContextResolver()
        let menuItem = sender as? NSMenuItem
        let selectedCommit = menuItem == nil ? context.history?.selectedCommits.first : nil
        return resolver.refish(
            representedObject: menuItem?.representedObject,
            selectedCommit: selectedCommit,
            allowedTypes: types,
            repository: repository
        )
    }

    @objc dynamic var selectedRef: PBGitRef? {
        guard let context = synchronousQueryContext ?? queryContext() else { return nil }
        return selectedRef(in: context)
    }

    private final func selectedRef(in context: RepositoryWindowContext) -> PBGitRef? {
        let queryWindow = context.window
        let resolver = actionContextResolver ?? RepositoryActionContextResolver()
        var sidebarRef: PBGitRef?
        var sidebarRemoteName: String?
        var historyRefs: [PBGitRef]?
        if let sidebarViewController = context.sidebar,
           let sidebarSourceView = sidebarViewController.sourceView,
           queryWindow?.firstResponder === sidebarSourceView,
           let item = sidebarSourceView.item(atRow: sidebarSourceView.selectedRow) as? PBSourceViewItem
        {
            if let remotes = sidebarViewController.remotes, item.parent === remotes {
                sidebarRemoteName = item.title
            } else {
                sidebarRef = item.ref()
            }
        } else if let history = context.history,
                  // Subclasses may provide a table without loading their History view.
                  // KVC keeps a missing nonnull-declared weak outlet safely optional.
                  let table = history.value(forKey: "commitList") as? NSView,
                  queryWindow?.firstResponder === table,
                  history.singleCommitSelected
        {
            historyRefs = history.selectedCommits.first?.refs?.compactMap { $0 as? PBGitRef }
        }
        return resolver.selectedRef(
            sidebarRef: sidebarRef,
            sidebarRemoteName: sidebarRemoteName,
            historyRefs: historyRefs
        )
    }

    @objc(performFetchForRef:)
    dynamic func performFetch(for ref: PBGitRef?) {
        withActionContext(requiresGit: true) { _ in remoteActionCoordinator?.performFetch(for: ref) }
    }

    @objc(performPullForBranch:remote:rebase:)
    dynamic func performPull(forBranch branch: PBGitRef, remote: PBGitRef?, rebase: Bool) {
        withActionContext(requiresGit: true) { _ in remoteActionCoordinator?.performPull(branch: branch, remote: remote, rebase: rebase) }
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
        withActionContext(requiresGit: true) { _ in
            pullRequestUIController?.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                initiallyCreatePullRequest: false
            )
        }
    }

    @objc(performPushForBranch:toRemote:requiresConfirmation:initiallyCreatePullRequest:)
    dynamic func performPush(
        forBranch branch: PBGitRef?,
        toRemote remote: PBGitRef?,
        requiresConfirmation: Bool,
        initiallyCreatePullRequest: Bool
    ) {
        withActionContext(requiresGit: true) { _ in
            pullRequestUIController?.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                initiallyCreatePullRequest: initiallyCreatePullRequest
            )
        }
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
        let types = [kGitXBranchType, kGitXRemoteBranchType, kGitXRemoteType]
        withActionContext(requiresGit: true, validIntent: hasReferenceIntent(sender, types: types),
                          validateInput: { self.configuredRemoteIntent(sender, types: types, context: $0) })
        { _ in
            let ref = refish(for: sender, refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXRemoteType])
            if let ref = ref as? PBGitRef {
                performFetch(for: ref)
            }
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
        pullFromDefaultRemote(sender, rebase: false)
    }

    @IBAction dynamic func pullRebaseDefaultRemote(_ sender: Any?) {
        pullFromDefaultRemote(sender, rebase: true)
    }

    private func pullFromDefaultRemote(_ sender: Any?, rebase: Bool) {
        let intent = RepositoryDefaultPullIntent(representedObject: (sender as? NSMenuItem)?.representedObject)
        withActionContext(requiresGit: true, validIntent: intent.isValid) { context in
            guard let branch = intent.resolve(checkedOutBranch: { context.repository.headRef()?.ref() }) else { return }
            performPull(forBranch: branch, remote: nil, rebase: rebase)
        }
    }

    private func pull(from sender: Any?, rebase: Bool) {
        withActionContext(requiresGit: true, validIntent: hasReferenceIntent(sender, types: [kGitXBranchType])) { _ in
            if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
                performPull(forBranch: ref, remote: nil, rebase: rebase)
            }
        }
    }

    @IBAction dynamic func pushUpdatesToRemote(_ sender: Any?) {
        let types = [kGitXRemoteType]
        withActionContext(requiresGit: true, validIntent: hasReferenceIntent(sender, types: types),
                          validateInput: { self.configuredRemoteIntent(sender, types: types, context: $0) })
        { _ in
            if let ref = refish(for: sender, refishTypes: [kGitXRemoteType]) as? PBGitRef {
                performPush(forBranch: nil, toRemote: ref.remote())
            }
        }
    }

    @IBAction dynamic func pushDefaultRemoteForRef(_ sender: Any?) {
        withActionContext(requiresGit: true, validIntent: hasReferenceIntent(sender, types: [kGitXBranchType])) { _ in
            if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
                performPush(forBranch: ref, toRemote: nil)
            }
        }
    }

    @IBAction dynamic func pushToRemote(_ sender: Any?) {
        withActionContext(requiresGit: true, validIntent: (sender as? NSMenuItem)?.parent?.representedObject is PBGitRefish && (sender as? NSMenuItem)?.representedObject != nil) { _ in
            guard let item = sender as? NSMenuItem,
                  let ref = refish(for: item.parent, refishTypes: nil) as? PBGitRef,
                  let remote = refish(for: item, refishTypes: [kGitXRemoteType]) as? PBGitRef,
                  ReferenceActionPolicy.canPushToNamedRemote(refishType: ref.refishType())
            else { return }
            performPush(forBranch: ref, toRemote: remote)
        }
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
        let represented = representedObject(from: sender)
        withActionContext(requiresGit: false, validIntent: (represented as? [Any])?.isEmpty == false) { _ in
            open(selectedURLs(from: sender))
        }
    }

    @IBAction dynamic func revealInFinder(_ sender: Any?) {
        withActionContext(requiresGit: false) { context in
            revealURLs(inFinder: WorkspaceActionCoordinator(repository: context.repository).revealURLs(from: representedObject(from: sender)))
        }
    }

    @IBAction dynamic func openInTerminal(_ sender: Any?) {
        withActionContext(requiresGit: false) { context in
            WorkspaceActionCoordinator(repository: context.repository).openRepositoryInTerminal()
        }
    }

    @IBAction dynamic func refreshRepositoryWindow(_ sender: Any?) {
        NSLog("[GitX] Global Refresh reached the repository window")
        refresh(sender)
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
        requestLocalStatusRefresh()
    }

    @objc(repositoryRemoteOperationDidSucceed:)
    private dynamic func repositoryRemoteOperationDidSucceed(_ notification: Notification) {
        requestLocalStatusRefresh()
        let operation = notification.userInfo?["operation"] as? String
        let reason: ForgeRefreshReason = operation == "push" ? .localPushSucceeded : .localFetchSucceeded
        repositoryForgeOverlaySession?.requestRefresh(reason: reason)
    }

    final func installRepositoryForgeOverlaySession() {
        guard !suppressesRepositoryForgeSession else {
            NSLog("[UITest] Suppressed repository Forge overlay session for deterministic Milestone 2 UI verification")
            return
        }
        guard repositoryForgeOverlaySession == nil else { return }
        _ = forgeCoordinator
        guard let resolution = prepareForgeQueryPresentation() else { return }
        installRepositoryForgeOverlaySession(resolution: resolution)
    }

    private func installRepositoryForgeOverlaySession(resolution: RepositoryForgeBindingResolution) {
        guard !suppressesRepositoryForgeSession else {
            NSLog("[UITest] Suppressed prepared repository Forge overlay session")
            return
        }
        guard repositoryForgeOverlaySession == nil, !ownership.closed else { return }
        let binding = resolution.binding
        let session = RepositoryForgeOverlaySession(
            binding: binding,
            services: ApplicationComposition.shared.forgeServices,
            detailsHandler: { [weak self] action in
                self?.presentForgeStatusDetails(action)
            }
        )
        replaceRepositoryForgeOverlaySession(session)
    }

    final func replaceRepositoryForgeOverlaySession(_ session: RepositoryForgeOverlaySession?) {
        guard repositoryForgeOverlaySession !== session, session == nil || !ownership.closed else { return }
        repositoryForgeOverlaySession?.invalidate()
        repositoryForgeOverlaySession = session
        if let session {
            repositoryStatusBarController?.bind(to: session)
            session.start()
        } else {
            repositoryStatusBarController?.invalidate()
            repositoryStatusBarController?.updateForge(.unbound)
        }
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
        replaceRepositoryForgeOverlaySession(nil)
        installRepositoryForgeOverlaySession()
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
