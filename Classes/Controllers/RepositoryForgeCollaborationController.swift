import AppKit
import ForgeKit
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

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
    static let readCapabilityOperations: Set<ForgeOperation> = [
        .readPullRequests,
        .readIssues,
    ]
    static let collaborationCapabilityOperations = mutationCapabilityOperations
        .union(readCapabilityOperations)

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
    private var credentialCooldownObservationTask: Task<Void, Never>?
    private var credentialCooldownRefreshTask: Task<Void, Never>?
    private var accountSelectionTask: Task<Void, Never>?
    private var accessPreparationGeneration: UInt64 = 0
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
    private var readCapabilities: [ForgeOperation: ForgeOperationCapability]?
    private var credentialCooldownState = GitHubCredentialCooldownState.none
    private var createPullRequestControl = ForgeMutationControlPresentation.hidden {
        didSet {
            windowController?.updateCreatePullRequestControl(createPullRequestControl)
        }
    }

    private var editPullRequestControl = ForgeMutationControlPresentation.hidden
    private var syncForkControl = ForgeMutationControlPresentation.hidden
    private weak var mountedController: NSViewController?
    private var isPrepared = false
    private var isClosed = false
    #if DEBUG
        private var credentialCooldownObservationReadyForProductProof = false
    #endif

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
        credentialCooldownObservationTask?.cancel()
        credentialCooldownRefreshTask?.cancel()
        accountSelectionTask?.cancel()
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
        isClosed = true
        accessPreparationGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        repositoryFactsTask?.cancel()
        repositoryFactsTask = nil
        credentialCooldownObservationTask?.cancel()
        credentialCooldownObservationTask = nil
        #if DEBUG
            credentialCooldownObservationReadyForProductProof = false
        #endif
        credentialCooldownRefreshTask?.cancel()
        credentialCooldownRefreshTask = nil
        accountSelectionTask?.cancel()
        accountSelectionTask = nil
        attentionSession?.stop()
        attentionSession = nil
        pullRequestReviewOverlayHost?.detach()
        pullRequestReviewOverlayHost = nil
        NotificationCenter.default.removeObserver(
            self,
            name: .forgeAccountsDidChange,
            object: nil
        )
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

    var availableSidebarSurfaces: [ForgeCollaborationSurface] {
        let isAuthenticated = if case .authenticated = accessResolution {
            true
        } else {
            false
        }
        return ForgeCollaborationSurfaceAvailabilityPolicy.availableSurfaces(
            readCapabilities: isAuthenticated ? readCapabilities : nil,
            isAuthenticated: isAuthenticated,
            attentionInstalled: attentionSession != nil
        )
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
        guard availableSidebarSurfaces.contains(surface) else {
            Self.logger.info("Ignored unavailable Forge collaboration surface")
            return
        }
        activeSurface = surface
        guard isViewLoaded else { return }
        renderActiveSurface()
    }

    @discardableResult
    func openNative(_ destination: ForgeDestination) -> Bool {
        guard destination.repository == binding?.primaryRepository else { return false }
        switch destination {
        case .pullRequest:
            guard availableSidebarSurfaces.contains(.pullRequests) else { return false }
            show(.pullRequests)
            windowController?.changeContentController(self)
            _ = readController?.open(destination: destination)
            return true
        case .issue:
            guard availableSidebarSurfaces.contains(.issues) else { return false }
            show(.issues)
            windowController?.changeContentController(self)
            _ = readController?.open(destination: destination)
            return true
        default:
            return false
        }
    }

    private func reloadAccess(resetPublicChoice: Bool) {
        guard !isClosed else { return }
        accessPreparationGeneration &+= 1
        let preparationGeneration = accessPreparationGeneration
        preparationTask?.cancel()
        repositoryFactsTask?.cancel()
        credentialCooldownObservationTask?.cancel()
        credentialCooldownRefreshTask?.cancel()
        accountSelectionTask?.cancel()
        credentialCooldownState = .none
        attentionSession?.stop()
        attentionSession = nil
        attentionController = nil
        pullRequestReviewOverlayHost?.detach()
        pullRequestReviewOverlayHost = nil
        readController = nil
        destinationRouter = nil
        nativeOpener = nil
        repositoryFacts = nil
        readCapabilities = nil
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
                guard let self,
                      !Task.isCancelled,
                      !self.isClosed,
                      self.accessPreparationGeneration == preparationGeneration,
                      self.binding == binding
                else { return }
                self.services = services
                self.accounts = accounts
                self.applyAccess(binding: binding)
                self.observeCredentialCooldowns(using: services)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      !self.isClosed,
                      self.accessPreparationGeneration == preparationGeneration,
                      self.binding == binding
                else { return }
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
        credentialCooldownState = .none
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
        if case .authenticated = resolution, let services {
            scheduleCredentialCooldownRefresh(using: services)
        }
    }

    private func observeCredentialCooldowns(using services: ForgeApplicationServices) {
        credentialCooldownObservationTask?.cancel()
        #if DEBUG
            credentialCooldownObservationReadyForProductProof = false
        #endif
        credentialCooldownObservationTask = Task { [weak self] in
            let changes = await services.credentialCooldowns.changes()
            guard !Task.isCancelled else { return }
            if let controller = self {
                await controller.refreshCredentialCooldownState(using: services)
                guard !Task.isCancelled else { return }
                #if DEBUG
                    controller.credentialCooldownObservationReadyForProductProof = true
                #endif
            } else {
                return
            }
            for await changedCredential in changes {
                guard !Task.isCancelled else { return }
                // Reacquire the controller only for this bounded refresh. The
                // task must not retain a closed window while awaiting the next
                // change from this process-lifetime stream.
                guard let controller = self else { return }
                guard case let .authenticated(account) = controller.accessResolution,
                      account.currentCredential.reference == changedCredential
                else { continue }
                await controller.refreshCredentialCooldownState(using: services)
            }
        }
    }

    private func scheduleCredentialCooldownRefresh(using services: ForgeApplicationServices) {
        credentialCooldownRefreshTask?.cancel()
        credentialCooldownRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCredentialCooldownState(using: services)
        }
    }

    private func refreshCredentialCooldownState(
        using services: ForgeApplicationServices
    ) async {
        guard case let .authenticated(account) = accessResolution else {
            installCredentialCooldownState(.none)
            return
        }
        let credential = account.currentCredential.reference
        let state = await services.credentialCooldowns.retainedState(
            for: credential,
            at: Date()
        )
        guard case let .authenticated(currentAccount) = accessResolution,
              currentAccount.currentCredential.reference == credential
        else { return }
        installCredentialCooldownState(state)
    }

    private func installCredentialCooldownState(_ state: GitHubCredentialCooldownState) {
        guard credentialCooldownState != state else { return }
        credentialCooldownState = state
        updateAccountBar()
        publishAccessChange()
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
            viewStateStore: settings,
            authorizationRecoveryHandler: { [weak self] error, retry in
                _ = GitHubAuthorizationRecoveryPresenter.present(
                    error: error,
                    for: self?.windowController,
                    retry: retry
                )
            }
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
        let initialDefaultRevision = defaultRevision()
        let reviewOverlayHost: RepositoryPullRequestReviewOverlayHost?
        if let reviewApplicationSession, let reviewAccountID {
            reviewOverlayHost = RepositoryPullRequestReviewOverlayHost(
                applicationSession: reviewApplicationSession,
                accountID: reviewAccountID,
                router: router,
                defaultRevision: initialDefaultRevision,
                authorizationRecoveryHandler: { [weak self] error, retry in
                    GitHubAuthorizationRecoveryPresenter.present(
                        error: error,
                        for: self?.windowController,
                        retry: retry
                    )
                },
                onFetchBaseCompletion: { [weak self] in
                    self?.windowController?.refreshAfterForgeBaseFetch()
                },
                onCheckOutBaseCompletion: { [weak self] in
                    self?.windowController?.refreshAfterForgeBaseCheckout()
                }
            )
        } else {
            reviewOverlayHost = nil
        }
        pullRequestReviewOverlayHost = reviewOverlayHost
        let kind: ForgeReadSurfaceKind = activeSurface == .issues ? .issues : .pullRequests
        readController = ForgeReadSurfaceViewController(
            kind: kind,
            defaultRevision: initialDefaultRevision,
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
            },
            authorizationRecoveryHandler: { [weak self] error, retry in
                _ = GitHubAuthorizationRecoveryPresenter.present(
                    error: error,
                    for: self?.windowController,
                    retry: retry
                )
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
                var capabilities: [ForgeOperation: ForgeOperationCapability] = [:]
                var capabilityError: Error?
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
                            capabilities = try await pullRequestMutationService.capabilities(
                                accountID: account.id,
                                repository: binding.primaryRepository,
                                operations: Self.collaborationCapabilityOperations
                            )
                        } catch {
                            capabilityError = error
                        }
                    }
                case .publicAccess:
                    facts = try await ForgeAnonymousRESTProcessRuntime.adapter.repositoryFacts(
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
                if case let .available(branch) = facts.defaultBranch {
                    let revision = ForgeRevision.branch(branch)
                    self.readController?.updateDefaultRevision(revision)
                    self.attentionController?.updateDefaultRevision(revision)
                }
                if let capabilityError {
                    self.applyMutationCapabilityError(
                        capabilityError,
                        resolution: resolution
                    )
                } else {
                    self.applyReadCapabilities(capabilities, resolution: resolution)
                    self.applyMutationCapabilities(capabilities, resolution: resolution)
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
                let offeredRecovery = GitHubAuthorizationRecoveryPresenter.present(
                    error: error,
                    for: self.windowController
                ) { [weak self] in
                    self?.loadRepositoryFacts(binding: binding, resolution: resolution)
                }
                if case .authenticated = resolution, !offeredRecovery {
                    self.applyMutationCapabilityError(error, resolution: resolution)
                    self.updateSyncForkButton()
                }
                Self.logger.info("Repository relationship metadata remains unavailable")
            }
        }
    }

    private func applyReadCapabilities(
        _ capabilities: [ForgeOperation: ForgeOperationCapability],
        resolution: ForgeCollaborationAccessResolution
    ) {
        guard case .authenticated = resolution else { return }
        readCapabilities = capabilities
        reconcileActiveSurface()
    }

    private func reconcileActiveSurface() {
        let surfaces = availableSidebarSurfaces
        guard !surfaces.contains(activeSurface) else { return }
        guard let fallback = surfaces.first else {
            renderActiveSurface()
            return
        }
        activeSurface = fallback
        Self.logger.notice("Fell back from an unavailable Forge collaboration surface")
        renderActiveSurface()
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
        readCapabilities = nil
        reconcileActiveSurface()
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
            readCapabilities = [.readIssues: .unavailable(.missingPermission(.issues))]
            let publicReadsRemainVisible = availableSidebarSurfaces == [.pullRequests, .issues]

            accessResolution = .authenticated(account)
            applyReadCapabilities([
                .readPullRequests: .verified(.knownAuthority),
                .readIssues: .verified(.knownAuthority),
            ], resolution: .authenticated(account))
            show(.issues)
            applyReadCapabilities([
                .readPullRequests: .verified(.knownAuthority),
                .readIssues: .unavailable(.missingPermission(.issues)),
            ], resolution: .authenticated(account))
            let unavailableIssueFallsBack = activeSurface == .pullRequests
                && availableSidebarSurfaces == [.pullRequests]
            show(.issues)
            let unavailableShowIsIgnored = activeSurface == .pullRequests
            let issueDestination = try ForgeDestination.issue(
                binding.primaryRepository,
                ForgeItemNumber(42)
            )
            let unavailableNativeRouteIsRejected = !openNative(issueDestination)

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
            let capabilityErrorPreservesReads = availableSidebarSurfaces == [.pullRequests, .issues]
            let publishedErrorControl = windowController?.createPullRequestControl == createPullRequestControl
            applyMutationCapabilities([
                .createPullRequest: .verified(.knownAuthority),
                .editPullRequest: .verified(.knownAuthority),
                .syncFork: .verified(.knownAuthority),
            ], resolution: .publicAccess)
            return publicReadOnly && publishedPublicControl
                && publicReadsRemainVisible && unavailableIssueFallsBack
                && unavailableShowIsIgnored && unavailableNativeRouteIsRejected
                && enabled && publishedEnabledControl && enabledFork
                && missingFailsClosed && errorFailsClosed && capabilityErrorPreservesReads
                && publishedErrorControl
        }
    #endif

    private func renderActiveSurface() {
        guard isViewLoaded else { return }
        if activeSurface != .attention,
           !availableSidebarSurfaces.contains(activeSurface)
        {
            renderGateway(
                title: "GitHub Permission Required",
                message: "The selected GitHub Credential cannot read Pull Requests or Issues for this repository."
            )
            return
        }
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
        let rebinding = RepositoryForgeAccountRebindingPresentation.present(
            isEnabled: credentialCooldownState == .none,
            cooldownDeadline: credentialCooldownDeadline,
            now: Date()
        )
        accountPopup.isHidden = !github || matching.isEmpty
        accountPopup.isEnabled = github && !matching.isEmpty && rebinding.isEnabled
        accountPopup.toolTip = rebinding.helpText
        accountPopup.setAccessibilityHelp(rebinding.helpText)
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

    private var credentialCooldownDeadline: Date? {
        switch credentialCooldownState {
        case .none:
            nil
        case let .waiting(until):
            until
        case let .retryPending(deadline):
            deadline
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
            RepositoryForgeAccountNotificationKey.accountRebindingEnabled:
                credentialCooldownState == .none,
            RepositoryForgeAccountNotificationKey.accounts: matchingAccounts().map {
                RepositoryForgeAccountChoice(id: $0.id, login: $0.login).notificationValue
            },
        ]
        if let credentialCooldownDeadline {
            userInfo[RepositoryForgeAccountNotificationKey.accountRebindingCooldownDeadline]
                = credentialCooldownDeadline
        }
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
        guard let binding, let services else { return }
        let matching = matchingAccounts()
        guard matching.indices.contains(sender.indexOfSelectedItem) else { return }
        let destinationAccount = matching[sender.indexOfSelectedItem]
        guard case let .authenticated(currentAccount) = accessResolution else {
            applyAccountSelection(destinationAccount, binding: binding)
            return
        }
        let currentCredential = currentAccount.currentCredential.reference
        accountSelectionTask?.cancel()
        accountSelectionTask = Task { [weak self] in
            do {
                guard let envelope = try await services.accountStore.credential(for: currentAccount.id),
                      envelope.account.currentCredential.reference == currentCredential
                else {
                    self?.reloadAccess(resetPublicChoice: false)
                    return
                }
                let state = await services.credentialCooldowns.retainedState(
                    for: currentCredential,
                    at: Date()
                )
                guard !Task.isCancelled, let self else { return }
                guard self.binding == binding,
                      self.accessResolution == .authenticated(currentAccount),
                      self.matchingAccounts().contains(where: { $0.id == destinationAccount.id }),
                      let currentEnvelope = try await services.accountStore.credential(for: currentAccount.id),
                      currentEnvelope.account.currentCredential.reference == currentCredential
                else {
                    self.restoreAccountPopupSelection()
                    return
                }
                guard state == .none else {
                    self.installCredentialCooldownState(state)
                    self.restoreAccountPopupSelection()
                    NSSound.beep()
                    return
                }
                self.applyAccountSelection(destinationAccount, binding: binding)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.restoreAccountPopupSelection()
                self.windowController?.showErrorSheet(error)
            }
        }
    }

    #if DEBUG
        func waitForAccountSelectionForProductProof() async {
            await accountSelectionTask?.value
        }

        var accessPreparationTaskForProductProof: Task<Void, Never>? {
            preparationTask
        }

        var accessPreparationGenerationForProductProof: UInt64 {
            accessPreparationGeneration
        }

        var observesCredentialCooldownsForProductProof: Bool {
            credentialCooldownObservationTask != nil
                && credentialCooldownObservationReadyForProductProof
        }
    #endif

    private func applyAccountSelection(_ account: ForgeAccount, binding: ForgeRepositoryBinding) {
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

    private func restoreAccountPopupSelection() {
        guard case let .authenticated(account) = accessResolution,
              let index = matchingAccounts().firstIndex(where: { $0.id == account.id })
        else { return }
        accountPopup.selectItem(at: index)
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
        let alert = RepositorySyncForkConfirmationPresenter.alert(plan: plan)
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
        guard !isClosed else { return }
        reloadAccess(resetPublicChoice: true)
    }
}
#endif
// swiftformat:enable indent
