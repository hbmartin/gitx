import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
private final class RepositoryPullRequestOperation {
    var flow: RepositoryPullRequestPushFlow

    init(flow: RepositoryPullRequestPushFlow = RepositoryPullRequestPushFlow()) {
        self.flow = flow
    }
}

@MainActor
private final class RepositoryPullRequestDeferredPushOperation {
    let key: RepositoryPullRequestPreparationCacheKey
    let offer: RepositoryPullRequestPushOffer
    var preparationTask: Task<Void, Never>?
    var cache: RepositoryPullRequestPreparationCache?
    var preparationError: Error?
    var createPullRequestSelected: Bool?
    var pushSucceeded = false

    init(key: RepositoryPullRequestPreparationCacheKey, offer: RepositoryPullRequestPushOffer) {
        self.key = key
        self.offer = offer
    }

    deinit {
        preparationTask?.cancel()
    }
}

/// Coordinates native PR presentation with the existing local push workflow.
/// Local Git remains authoritative for the push; this object starts a mutation only
/// after the push completion has returned successfully.
@MainActor
final class RepositoryPullRequestUIController {
    private static let ordinaryPushPreparationLifetime: TimeInterval = 60

    private unowned let repository: PBGitRepository
    private weak var windowController: PBGitWindowController?
    private let remoteActions: any RepositoryRemoteActionCoordinating
    private let service: any RepositoryPullRequestMutationServing
    private let drafts: any RepositoryPullRequestDraftPersisting
    let destinationOpening: (ForgeDestination) -> Bool
    let bindingResolving: () -> ForgeRepositoryBinding?
    let postPushBrowserFallback: (PBGitRef?) -> Void
    private let createPullRequestControlResolving: () -> ForgeMutationControlPresentation
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestWorkflow")
    private var preparationTask: Task<Void, Never>?
    private var ordinaryPushPreparationTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var sheetController: ForgePullRequestSheetController?
    private var activePreparation: RepositoryPullRequestCreationPreparation?
    private var ordinaryPushPreparationCache = RepositoryPullRequestPreparationCacheStore()
    private var pullRequestOperation: RepositoryPullRequestOperation?
    private var deferredPullRequestOperation: RepositoryPullRequestDeferredPushOperation?
    var onCreationOutcome: ((RepositoryPullRequestCreationOutcome) -> Void)?
    var onCreationDestinationOpened: ((ForgeDestination, Bool) -> Void)?

    init(
        repository: PBGitRepository,
        windowController: PBGitWindowController,
        remoteActions: any RepositoryRemoteActionCoordinating,
        service: any RepositoryPullRequestMutationServing,
        drafts: any RepositoryPullRequestDraftPersisting = NullRepositoryPullRequestDraftStore(),
        destinationOpening: @escaping (ForgeDestination) -> Bool,
        bindingResolving: @escaping () -> ForgeRepositoryBinding?,
        postPushBrowserFallback: @escaping (PBGitRef?) -> Void,
        createPullRequestControlResolving: @escaping () -> ForgeMutationControlPresentation = {
            .capability(.verified(.knownAuthority), action: "create a Pull Request")
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.windowController = windowController
        self.remoteActions = remoteActions
        self.service = service
        self.drafts = drafts
        self.destinationOpening = destinationOpening
        self.bindingResolving = bindingResolving
        self.postPushBrowserFallback = postPushBrowserFallback
        self.createPullRequestControlResolving = createPullRequestControlResolving
        self.now = now
        preloadOrdinaryPushPreparation()
    }

    deinit {
        preparationTask?.cancel()
        ordinaryPushPreparationTask?.cancel()
        mutationTask?.cancel()
        draftSaveTask?.cancel()
    }

    func newPullRequest() {
        cancelOrdinaryPushPreparation(clearCache: true)
        cancelDeferredPullRequestOperation()
        guard let branch = repository.headRef()?.ref(), branch.isBranch else {
            windowController?.showErrorSheet(RepositoryPullRequestServiceError.noLocalBranch)
            return
        }
        prepare(branch: branch) { [weak self] preparation, form in
            guard let self else { return }
            do {
                let option = try RepositoryPullRequestPushOption(
                    preparation: preparation,
                    initialForm: form,
                    initiallySelected: true
                )
                let remote = preparation.branchAlreadyPushed ? nil : self.effectiveRemote(
                    for: branch,
                    requestedRemote: nil
                )
                if !preparation.branchAlreadyPushed, remote == nil {
                    throw RepositoryPullRequestServiceError.repositoryUnavailable
                }
                if let remote, remote.repository != preparation.head.repository {
                    throw ForgePullRequestWorkflowError.mismatchedRepository
                }
                let operation = try self.beginNewPullRequestOperation(
                    branchAlreadyPushed: preparation.branchAlreadyPushed,
                    intent: option.intent
                )
                if preparation.branchAlreadyPushed {
                    self.presentCreateSheet(
                        preparation: preparation,
                        intent: option.intent,
                        operation: operation
                    )
                } else {
                    self.push(
                        branch: branch,
                        remote: remote?.ref,
                        requiresConfirmation: true,
                        option: option,
                        operation: operation
                    )
                }
            } catch {
                self.windowController?.showErrorSheet(error)
            }
        }
    }

    #if DEBUG
        /// Environment-gated UI-test entrypoint. The supplied values are immutable
        /// ForgeKit fixtures, while push execution still uses the real local-Git
        /// coordinator and the production Push-to-Pull-Request state machine.
        func beginUITestCreateJourney(
            preparation: RepositoryPullRequestCreationPreparation,
            initialForm: ForgePullRequestCreationForm,
            branch: PBGitRef?,
            requiresPush: Bool
        ) throws {
            let option = try RepositoryPullRequestPushOption(
                preparation: preparation,
                initialForm: initialForm,
                initiallySelected: true
            )
            let remote: PBGitRef?
            if requiresPush {
                guard let branch, branch.isBranch else {
                    throw RepositoryPullRequestServiceError.noLocalBranch
                }
                guard let effectiveRemote = effectiveRemote(
                    for: branch,
                    requestedRemote: nil,
                    repositoryOverride: preparation.head.repository
                ),
                    effectiveRemote.repository == preparation.head.repository
                else {
                    throw RepositoryPullRequestServiceError.repositoryUnavailable
                }
                remote = effectiveRemote.ref
            } else {
                remote = nil
            }
            let operation = try beginNewPullRequestOperation(
                branchAlreadyPushed: !requiresPush,
                intent: option.intent
            )
            if requiresPush {
                guard let branch else { return }
                push(
                    branch: branch,
                    remote: remote,
                    requiresConfirmation: true,
                    option: option,
                    operation: operation
                )
            } else {
                presentCreateSheet(
                    preparation: preparation,
                    intent: option.intent,
                    operation: operation
                )
            }
        }
    #endif

    func performPush(
        branch: PBGitRef?,
        remote: PBGitRef?,
        requiresConfirmation: Bool,
        initiallyCreatePullRequest: Bool = false
    ) {
        cancelOrdinaryPushPreparation(clearCache: false)
        guard createPullRequestControlResolving().isEnabled else {
            cancelOrdinaryPushPreparation(clearCache: true)
            remoteActions.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                pullRequestOption: nil,
                pullRequestOffer: nil,
                suppressesPostPushBrowserSuggestion: false,
                completion: nil
            )
            logger.info("Started local push without a native Pull Request offer because current capability is unavailable")
            return
        }
        guard let branch, branch.isBranch else {
            remoteActions.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                pullRequestOption: nil,
                pullRequestOffer: nil,
                suppressesPostPushBrowserSuggestion: false,
                completion: nil
            )
            return
        }
        let resolvedRemote = effectiveRemote(for: branch, requestedRemote: remote)?.ref ?? remote
        let nativePreparationKey = ordinaryPushPreparationKey(for: branch, remote: resolvedRemote)
        if let cache = takeExactOrdinaryPushPreparation(for: branch, remote: resolvedRemote) {
            beginDeferredOrdinaryPush(
                branch: branch,
                remote: resolvedRemote,
                requiresConfirmation: requiresConfirmation,
                initiallySelected: initiallyCreatePullRequest,
                key: cache.key,
                cachedPreparation: cache
            )
            return
        }
        if let key = nativePreparationKey,
           pullRequestOperation?.flow.isActive != true,
           deferredPullRequestOperation == nil
        {
            beginDeferredOrdinaryPush(
                branch: branch,
                remote: resolvedRemote,
                requiresConfirmation: requiresConfirmation,
                initiallySelected: initiallyCreatePullRequest,
                key: key
            )
            return
        }
        remoteActions.performPush(
            branch: branch,
            remote: resolvedRemote,
            requiresConfirmation: requiresConfirmation,
            pullRequestOption: nil,
            pullRequestOffer: nil,
            suppressesPostPushBrowserSuggestion: false,
            completion: { [weak self] event in
                guard event.isTerminal else { return }
                self?.preloadOrdinaryPushPreparation(for: branch, remote: resolvedRemote)
            }
        )
        logger.info("Started local push without waiting for Forge preparation")
    }

    private func beginDeferredOrdinaryPush(
        branch: PBGitRef,
        remote: PBGitRef?,
        requiresConfirmation: Bool,
        initiallySelected: Bool,
        key: RepositoryPullRequestPreparationCacheKey,
        cachedPreparation: RepositoryPullRequestPreparationCache? = nil
    ) {
        let offer = RepositoryPullRequestPushOffer(initiallySelected: initiallySelected)
        let operation = RepositoryPullRequestDeferredPushOperation(key: key, offer: offer)
        deferredPullRequestOperation = operation
        operation.preparationTask = Task { [weak self, service, drafts] in
            do {
                let cache = if let cachedPreparation {
                    cachedPreparation
                } else {
                    try await RepositoryPullRequestPreparationCacheLoader().load(
                        key: key,
                        service: service,
                        drafts: drafts,
                        expiresAfter: Self.ordinaryPushPreparationLifetime,
                        now: self?.now ?? Date.init
                    )
                }
                let capability = try await RepositoryPullRequestPushCapabilityRecheck().capability(
                    for: key,
                    service: service
                )
                guard let self, self.deferredPullRequestOperation === operation else { return }
                guard let currentKey = self.ordinaryPushPreparationKey(for: branch, remote: remote),
                      cache.isExact(for: currentKey, now: self.now())
                else {
                    throw RepositoryPullRequestServiceError.invalidLocalHead
                }
                let presentation = ForgeMutationControlPresentation.capability(
                    capability,
                    action: "create a Pull Request after pushing"
                )
                if presentation.isEnabled {
                    operation.cache = cache
                } else {
                    operation.preparationError = RepositoryPullRequestServiceError.nativeCreationUnavailable
                }
                operation.offer.update(presentation)
                self.advanceDeferredOrdinaryPush(operation, branch: branch, remote: remote)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.deferredPullRequestOperation === operation else { return }
                operation.preparationError = error
                operation.offer.update(.unavailable(
                    error: error,
                    action: "create a Pull Request after pushing"
                ))
                self.advanceDeferredOrdinaryPush(operation, branch: branch, remote: remote)
                self.logger.error(
                    "Native Pull Request preparation failed before push completion: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        remoteActions.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation,
            pullRequestOption: nil,
            pullRequestOffer: offer,
            suppressesPostPushBrowserSuggestion: false
        ) { [weak self] event in
            guard let self, self.deferredPullRequestOperation === operation else { return }
            switch event {
            case let .began(selected):
                operation.createPullRequestSelected = selected
                if !selected {
                    self.cancelDeferredPullRequestOperation()
                    self.logger.info("Started unchecked GitHub push without Pull Request navigation")
                    return
                }
            case .succeeded:
                operation.pushSucceeded = true
            case .failed, .cancelled:
                self.cancelDeferredPullRequestOperation()
                return
            }
            self.advanceDeferredOrdinaryPush(operation, branch: branch, remote: remote)
        }
        logger.info("Started local push with a nonblocking native Pull Request offer")
    }

    // SwiftLint analyzes the app and app-hosted test compilations separately and cannot
    // see the four test-target callers of this intentionally internal cache seam.
    // swiftlint:disable:next unused_declaration
    func installUITestOrdinaryPushPreparationCache(_ cache: RepositoryPullRequestPreparationCache) {
        cancelOrdinaryPushPreparation(clearCache: true)
        ordinaryPushPreparationCache.replace(with: cache)
    }

    private func advanceDeferredOrdinaryPush(
        _ deferred: RepositoryPullRequestDeferredPushOperation,
        branch: PBGitRef,
        remote: PBGitRef?
    ) {
        guard deferredPullRequestOperation === deferred,
              deferred.createPullRequestSelected == true,
              deferred.pushSucceeded
        else { return }
        if let error = deferred.preparationError {
            cancelDeferredPullRequestOperation()
            windowController?.showErrorSheet(error)
            postPushBrowserFallback(remote)
            logger.error("Native Pull Request preparation failed after push; retained validated browser fallback")
            return
        }
        guard let cache = deferred.cache else { return }
        guard let currentKey = ordinaryPushPreparationKey(for: branch, remote: remote),
              cache.key == currentKey
        else {
            cancelDeferredPullRequestOperation()
            windowController?.showErrorSheet(RepositoryPullRequestServiceError.invalidLocalHead)
            logger.error("Rejected stale Pull Request preparation after successful push")
            return
        }
        cancelDeferredPullRequestOperation()
        do {
            let option = try RepositoryPullRequestPushOption(
                preparation: cache.preparation,
                initialForm: cache.initialForm,
                initiallySelected: true
            )
            let operation = try beginOrdinaryPushOperation(intent: option.intent)
            try operation.flow.pushBegan(createPullRequestSelected: true)
            try operation.flow.pushSucceeded()
            presentCreateSheet(
                preparation: option.preparation,
                intent: option.intent,
                operation: operation
            )
        } catch {
            windowController?.showErrorSheet(error)
            logger.error("Could not continue deferred Push-to-Pull-Request workflow")
        }
    }

    private func cancelDeferredPullRequestOperation() {
        deferredPullRequestOperation?.preparationTask?.cancel()
        deferredPullRequestOperation = nil
    }

    func editPullRequest(
        accountID: ForgeAccountID,
        snapshot: ForgePullRequestEditableSnapshot,
        destination: ForgeDestination
    ) {
        preparationTask?.cancel()
        mutationTask?.cancel()
        let identity: ForgeDraftIdentity
        do {
            identity = try RepositoryPullRequestDraftPolicy.editIdentity(
                accountID: accountID,
                snapshot: snapshot
            )
        } catch {
            windowController?.showErrorSheet(error)
            return
        }
        preparationTask = Task { [weak self, drafts] in
            do {
                let draft = try await drafts.load(identity: identity)
                guard let self, !Task.isCancelled else { return }
                let content = RepositoryPullRequestDraftPolicy.restoredEditContent(
                    snapshot: snapshot,
                    draft: draft
                )
                self.presentEditSheet(
                    accountID: accountID,
                    snapshot: snapshot,
                    destination: destination,
                    identity: identity,
                    content: content
                )
            } catch is CancellationError {
                return
            } catch {
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    private func presentEditSheet(
        accountID: ForgeAccountID,
        snapshot: ForgePullRequestEditableSnapshot,
        destination: ForgeDestination,
        identity: ForgeDraftIdentity,
        content: ForgeDraftContent
    ) {
        guard let window = windowController?.window else { return }
        let sheet = ForgePullRequestSheetController(
            mode: .edit(accountID: accountID, snapshot: snapshot, destination: destination),
            restoredContent: content
        )
        sheet.onSubmit = { [weak self] submission in
            guard case let .edit(accountID, edit, destination) = submission else { return }
            self?.submitEdit(
                accountID: accountID,
                edit: edit,
                destination: destination,
                draftIdentity: identity
            )
        }
        sheet.onDraftChanged = { [weak self] content in
            self?.saveDraft(identity: identity, content: content)
        }
        sheet.onCancel = { [weak self] content in
            self?.saveDraft(identity: identity, content: content)
        }
        sheet.onDiscard = { [weak self] in
            self?.discardDraft(identity: identity)
        }
        sheetController = sheet
        saveDraft(identity: identity, content: content)
        sheet.beginSheet(for: window)
        logger.notice("Presented conflict-aware Pull Request edit sheet")
    }

    func checkout(_ plan: ForgePullRequestCheckoutPlan) {
        mutationTask?.cancel()
        let executor = RepositoryPullRequestCheckoutExecutor(repository: repository)
        mutationTask = Task { [weak self] in
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try executor.execute(plan)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.windowController?.showMessageSheet(
                    "Pull Request Checked Out",
                    infoText: "Checked out \(receipt.localBranch.value) from \(receipt.remoteName)."
                )
                self.logger.notice("Completed explicit Pull Request checkout")
            } catch is CancellationError {
                return
            } catch {
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    func checkout(_ pullRequest: ForgePullRequestSummary) {
        mutationTask?.cancel()
        let planner = RepositoryPullRequestCheckoutPlanner(repository: repository)
        mutationTask = Task { [weak self] in
            do {
                let plan = try await planner.plan(for: pullRequest)
                guard let self, !Task.isCancelled, let windowController = self.windowController else { return }
                let alert = NSAlert()
                alert.messageText = "Check Out Pull Request #\(pullRequest.number.rawValue)?"
                let remoteDetail = plan.addsRemote
                    ? "GitX will add the exact contributor remote ‘\(plan.remote.name)’ and fetch only \(plan.fetchRefspec)."
                    : "GitX will fetch only \(plan.fetchRefspec) from ‘\(plan.remote.name)’."
                alert.informativeText = "\(remoteDetail) The local branch will be named ‘\(plan.localBranch.value)’."
                alert.addButton(withTitle: "Check Out")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.setAccessibilityIdentifier("GitX.PullRequest.CheckoutConfirm")
                windowController.confirmDialog(alert, suppressionIdentifier: nil) { [weak self] in
                    self?.checkout(plan)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    func syncFork(accountID: ForgeAccountID, plan: ForgeSyncForkPlan) {
        mutationTask?.cancel()
        let runner = RepositoryPullRequestObjectiveGitRunner(repository: repository)
        let coordinator = RepositorySyncForkCoordinator(service: service, runner: runner)
        mutationTask = Task { [weak self] in
            do {
                let receipt = try await coordinator.sync(accountID: accountID, plan: plan)
                guard let self, !Task.isCancelled else { return }
                self.windowController?.showMessageSheet(
                    "Fork Synchronized",
                    infoText: "\(receipt.serverSummary) Fetched \(receipt.fetchedRemote)/\(receipt.fetchedBranch.value)."
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let offeredRecovery = self.presentAuthorizationRecovery(
                    error,
                    retry: { [weak self] in
                        self?.syncFork(accountID: accountID, plan: plan)
                    }
                )
                if !offeredRecovery {
                    self.windowController?.showErrorSheet(error)
                }
            }
        }
    }

    private func prepare(
        branch: PBGitRef,
        completion: @escaping (RepositoryPullRequestCreationPreparation, ForgePullRequestCreationForm) -> Void,
        fallback: (() -> Void)? = nil
    ) {
        preparationTask?.cancel()
        guard let binding = bindingResolving(),
              binding.primaryRepository.forge.kind == .github,
              binding.primaryRepository.forge.origin.host.lowercased() == "github.com"
        else {
            fallback?()
            if fallback == nil {
                windowController?.showErrorSheet(RepositoryPullRequestServiceError.repositoryUnavailable)
            }
            return
        }
        let branchName: ForgeRefName
        let head: ForgeCommitID
        do {
            branchName = try ForgeRefName(branch.shortName())
            head = try ForgeCommitID(repository.outputOfTask(withArguments: ["rev-parse", branch.ref])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            fallback?()
            if fallback == nil {
                windowController?.showErrorSheet(RepositoryPullRequestServiceError.invalidLocalHead)
            }
            return
        }

        preparationTask = Task { [weak self, service] in
            do {
                let preparation = try await service.prepareCreation(
                    repository: binding.primaryRepository,
                    localBranch: branchName,
                    localHead: head
                )
                let forms = try preparation.initialForms()
                let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
                let draft = try await self?.drafts.load(identity: identity)
                let initial = try RepositoryPullRequestDraftPolicy.restoredForm(
                    preparation: preparation,
                    initial: forms.forms[forms.selectedTemplateIndex ?? 0],
                    draft: draft
                )
                guard let self, !Task.isCancelled else { return }
                self.activePreparation = preparation
                completion(preparation, initial)
                self.logger.info(
                    "Prepared native Pull Request workflow pushed=\(preparation.branchAlreadyPushed, privacy: .public) templates=\(preparation.templates.count, privacy: .public)"
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.presentAuthorizationRecovery(error, retry: { [weak self] in
                    self?.prepare(branch: branch, completion: completion)
                }) {
                    self.logger.notice("Offered explicit authorization recovery for Pull Request preparation")
                } else if let fallback {
                    fallback()
                } else {
                    self.windowController?.showErrorSheet(error)
                }
                self.logger.error("Native Pull Request preparation failed; browser fallback remains available")
            }
        }
    }

    private func preloadOrdinaryPushPreparation(
        for requestedBranch: PBGitRef? = nil,
        remote requestedRemote: PBGitRef? = nil
    ) {
        cancelOrdinaryPushPreparation(clearCache: true)
        guard createPullRequestControlResolving().isEnabled else {
            logger.debug("Skipped Pull Request push-option preload because current capability is unavailable")
            return
        }
        guard let branch = requestedBranch ?? repository.headRef()?.ref(), branch.isBranch else { return }
        guard let key = ordinaryPushPreparationKey(for: branch, remote: requestedRemote) else {
            logger.debug("Skipped Pull Request push-option preload because the local branch could not be resolved")
            return
        }

        ordinaryPushPreparationTask = Task { [weak self, service, drafts] in
            do {
                let cache = try await RepositoryPullRequestPreparationCacheLoader().load(
                    key: key,
                    service: service,
                    drafts: drafts,
                    expiresAfter: Self.ordinaryPushPreparationLifetime,
                    now: self?.now ?? Date.init
                )
                guard let self, !Task.isCancelled else { return }
                guard let currentKey = self.ordinaryPushPreparationKey(
                    for: branch,
                    remote: requestedRemote
                ), cache.isExact(for: currentKey, now: self.now()) else { return }
                self.ordinaryPushPreparationCache.replace(with: cache)
                self.logger.debug("Preloaded exact Pull Request option without blocking local Git")
            } catch is CancellationError {
                return
            } catch {
                self?.logger.debug("Pull Request option preload unavailable; local Git remains unaffected")
            }
        }
    }

    private func takeExactOrdinaryPushPreparation(
        for branch: PBGitRef,
        remote: PBGitRef?
    ) -> RepositoryPullRequestPreparationCache? {
        guard let currentKey = ordinaryPushPreparationKey(for: branch, remote: remote) else {
            ordinaryPushPreparationCache.replace(with: nil)
            return nil
        }
        return ordinaryPushPreparationCache.takeExact(for: currentKey, now: now())
    }

    private func ordinaryPushPreparationKey(
        for branch: PBGitRef,
        remote: PBGitRef?
    ) -> RepositoryPullRequestPreparationCacheKey? {
        guard branch.isBranch,
              let binding = bindingResolving(),
              binding.primaryRepository.forge.kind == .github,
              binding.primaryRepository.forge.origin.host.lowercased() == "github.com",
              let branchName = try? ForgeRefName(branch.shortName()),
              let localHead = try? ForgeCommitID(repository.outputOfTask(withArguments: [
                  "rev-parse", branch.ref,
              ]).trimmingCharacters(in: .whitespacesAndNewlines)),
              let effectiveRemote = effectiveRemote(for: branch, requestedRemote: remote)
        else { return nil }
        return RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: branchName,
            localHead: localHead,
            effectiveRemoteName: effectiveRemote.name,
            effectiveRemoteRepository: effectiveRemote.repository
        )
    }

    private func effectiveRemote(
        for branch: PBGitRef,
        requestedRemote: PBGitRef?,
        repositoryOverride: ForgeRepositoryIdentity? = nil
    ) -> (ref: PBGitRef, name: String, repository: ForgeRepositoryIdentity)? {
        guard requestedRemote == nil || requestedRemote?.isRemote == true,
              let binding = bindingResolving(),
              let name = RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
                  requestedRemoteName: requestedRemote?.remoteName,
                  branchPushRemoteName: gitConfigurationValue(
                      for: "branch.\(branch.shortName()).pushRemote"
                  ),
                  defaultPushRemoteName: gitConfigurationValue(for: "remote.pushDefault"),
                  trackingRemoteName: (try? repository.remoteRef(forBranch: branch))?.remoteName,
                  boundRemoteName: binding.localRemoteName
              ),
              let rawURLs = try? repository.outputOfTask(withArguments:
                  RepositoryPullRequestPushRemotePolicy.pushURLArguments(remoteName: name)),
              let identity = repositoryOverride ?? RepositoryPullRequestPushRemotePolicy.pushRepository(
                  rawURLs: rawURLs
              )
        else { return nil }
        return (PBGitRef(string: kGitXRemoteRefPrefix + name), name, identity)
    }

    private func cancelOrdinaryPushPreparation(clearCache: Bool) {
        ordinaryPushPreparationTask?.cancel()
        ordinaryPushPreparationTask = nil
        if clearCache {
            ordinaryPushPreparationCache.replace(with: nil)
        }
    }

    private func gitConfigurationValue(for key: String) -> String? {
        let value = (try? repository.outputOfTask(withArguments: ["config", "--get", key]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func beginNewPullRequestOperation(
        branchAlreadyPushed: Bool,
        intent: ForgePushPullRequestIntent
    ) throws -> RepositoryPullRequestOperation {
        let preservedFlow = pullRequestOperation?.flow ?? RepositoryPullRequestPushFlow()
        guard !preservedFlow.isActive, deferredPullRequestOperation == nil else {
            throw ForgePullRequestWorkflowError.invalidTransition
        }
        let operation = RepositoryPullRequestOperation(flow: preservedFlow)
        try operation.flow.beginNewPullRequest(
            branchAlreadyPushed: branchAlreadyPushed,
            intent: intent
        )
        pullRequestOperation = operation
        return operation
    }

    private func beginOrdinaryPushOperation(
        intent: ForgePushPullRequestIntent
    ) throws -> RepositoryPullRequestOperation {
        guard pullRequestOperation?.flow.isActive != true, deferredPullRequestOperation == nil else {
            throw ForgePullRequestWorkflowError.invalidTransition
        }
        let operation = RepositoryPullRequestOperation()
        try operation.flow.beginOrdinaryPush(intent: intent)
        pullRequestOperation = operation
        return operation
    }

    private func push(
        branch: PBGitRef,
        remote: PBGitRef?,
        requiresConfirmation: Bool,
        option: RepositoryPullRequestPushOption,
        operation: RepositoryPullRequestOperation
    ) {
        saveDraft(
            identity: option.intent.draftIdentity,
            content: ForgeDraftContent(
                title: option.intent.form.title,
                body: option.intent.form.bodyMarkdown
            )
        )
        remoteActions.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation,
            pullRequestOption: option,
            pullRequestOffer: nil,
            suppressesPostPushBrowserSuggestion: false
        ) { [weak self] event in
            guard let self, self.pullRequestOperation === operation else { return }
            defer {
                if event.isTerminal {
                    self.preloadOrdinaryPushPreparation(for: branch, remote: remote)
                }
            }
            do {
                switch event {
                case let .began(selected):
                    try operation.flow.pushBegan(createPullRequestSelected: selected)
                case .succeeded:
                    try operation.flow.pushSucceeded()
                    if let intent = operation.flow.createSheetIntent {
                        self.presentCreateSheet(
                            preparation: option.preparation,
                            intent: intent,
                            operation: operation
                        )
                    }
                case .failed:
                    try operation.flow.pushFailed()
                case .cancelled:
                    try operation.flow.pushCancelled()
                }
            } catch {
                self.logger.fault("Rejected invalid Push-to-Pull-Request transition")
                self.windowController?.showErrorSheet(error)
            }
        }
    }

    private func presentCreateSheet(
        preparation: RepositoryPullRequestCreationPreparation,
        intent: ForgePushPullRequestIntent,
        operation: RepositoryPullRequestOperation
    ) {
        guard pullRequestOperation === operation else { return }
        guard let window = windowController?.window else {
            do {
                try operation.flow.createSheetCancelled()
            } catch {
                logger.fault("Rejected invalid windowless Pull Request sheet transition")
            }
            return
        }
        activePreparation = preparation
        let initialForm = intent.form
        let forms: RepositoryPullRequestInitialForms
        do {
            let initial = try preparation.initialForms()
            forms = RepositoryPullRequestInitialForms(
                forms: initial.forms.map { candidate in
                    candidate == initial.forms[initial.selectedTemplateIndex ?? 0] ? initialForm : candidate
                },
                selectedTemplateIndex: initial.selectedTemplateIndex,
                templateNames: initial.templateNames
            )
        } catch {
            windowController?.showErrorSheet(error)
            do {
                try operation.flow.creationFailed()
            } catch {
                logger.fault("Rejected invalid Pull Request form failure transition")
            }
            return
        }
        let restored = ForgeDraftContent(title: initialForm.title, body: initialForm.bodyMarkdown)
        let sheet = ForgePullRequestSheetController(
            mode: .create(preparation: preparation, initialForms: forms),
            restoredContent: restored
        )
        sheet.onDraftChanged = { [weak self] content in
            self?.saveDraft(preparation: preparation, content: content)
        }
        sheet.onCancel = { [weak self] content in
            self?.saveDraft(preparation: preparation, content: content)
            guard let self, self.pullRequestOperation === operation else { return }
            do {
                try operation.flow.createSheetCancelled()
            } catch {
                self.logger.fault("Rejected invalid Pull Request sheet cancellation transition")
            }
        }
        sheet.onDiscard = { [weak self] in
            guard let self, self.pullRequestOperation === operation else { return }
            do {
                try operation.flow.createSheetCancelled()
            } catch {
                self.logger.fault("Rejected invalid Pull Request draft discard transition")
            }
            do {
                let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
                self.discardDraft(identity: identity)
            } catch {
                self.logger.error("Could not identify discarded Pull Request draft")
            }
        }
        sheet.onSubmit = { [weak self] submission in
            guard case let .create(accountID, form) = submission else { return }
            self?.submitCreate(
                accountID: accountID,
                form: form,
                preparation: preparation,
                operation: operation
            )
        }
        sheetController = sheet
        // Persist the initial content before presentation so every cancellation
        // path, including closing the sheet from its title bar, preserves a
        // durable draft even when the user made no edit first.
        saveDraft(preparation: preparation, content: restored)
        sheet.beginSheet(for: window)
    }

    private func saveDraft(
        preparation: RepositoryPullRequestCreationPreparation,
        content: ForgeDraftContent
    ) {
        do {
            try saveDraft(
                identity: RepositoryPullRequestDraftPolicy.identity(preparation: preparation),
                content: content
            )
        } catch {
            logger.error("Could not identify Pull Request draft")
        }
    }

    private func saveDraft(
        identity: ForgeDraftIdentity,
        content: ForgeDraftContent
    ) {
        let drafts = drafts
        let date = now()
        let previousSave = draftSaveTask
        draftSaveTask = Task {
            await previousSave?.value
            guard !Task.isCancelled else { return }
            do {
                try await drafts.save(identity: identity, content: content, at: date)
            } catch {
                logger.error("Could not autosave Pull Request draft")
            }
        }
    }

    private func discardDraft(identity: ForgeDraftIdentity) {
        let drafts = drafts
        let previousSave = draftSaveTask
        draftSaveTask = Task { [weak self] in
            await previousSave?.value
            guard !Task.isCancelled else { return }
            do {
                try await drafts.delete(identity: identity)
                self?.logger.notice("Deleted discarded Pull Request Forge Draft")
            } catch {
                self?.logger.error("Could not delete discarded Pull Request Forge Draft")
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    private func submitCreate(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm,
        preparation: RepositoryPullRequestCreationPreparation,
        operation: RepositoryPullRequestOperation
    ) {
        mutationTask?.cancel()
        saveDraft(
            preparation: preparation,
            content: ForgeDraftContent(title: form.title, body: form.bodyMarkdown)
        )
        let pendingDraftSave = draftSaveTask
        mutationTask = Task { [weak self, service, drafts] in
            do {
                await pendingDraftSave?.value
                guard !Task.isCancelled else { return }
                let outcome = try await service.createPullRequest(accountID: accountID, form: form)
                let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
                guard let self,
                      !Task.isCancelled,
                      self.pullRequestOperation === operation
                else { return }
                let destination: ForgeDestination
                switch outcome {
                case let .created(value):
                    destination = value
                    self.logger.notice("Created Pull Request")
                case let .existing(value):
                    destination = value
                    self.logger.notice("Detected existing Pull Request; skipped duplicate creation")
                }
                guard case .pullRequest = destination,
                      destination.repository == preparation.repository
                else {
                    throw ForgePullRequestWorkflowError.mismatchedRepository
                }
                switch outcome {
                case .created:
                    try operation.flow.creationSucceeded(destination)
                case .existing:
                    try operation.flow.existingPullRequest(destination)
                }
                do {
                    try await drafts.delete(identity: identity)
                    self.logger.notice("Removed published Pull Request Forge Draft")
                } catch {
                    self.logger.error("Pull Request succeeded, but its published Forge Draft could not be removed")
                }
                self.onCreationOutcome?(outcome)
                let opened = self.destinationOpening(destination)
                self.onCreationDestinationOpened?(destination, opened)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pullRequestOperation === operation else { return }
                if self.presentAuthorizationRecovery(error, retry: { [weak self] in
                    self?.submitCreate(
                        accountID: accountID,
                        form: form,
                        preparation: preparation,
                        operation: operation
                    )
                }) {
                    self.logger.notice("Offered explicit authorization recovery for Pull Request creation")
                    return
                }
                do {
                    try operation.flow.creationFailed()
                } catch {
                    self.logger.fault("Rejected invalid Pull Request creation failure transition")
                }
                self.windowController?.showErrorSheet(error)
                self.logger.error("Pull Request creation failed; draft preserved without automatic retry")
            }
        }
    }

    private func submitEdit(
        accountID: ForgeAccountID,
        edit: ForgePullRequestEdit,
        destination: ForgeDestination,
        draftIdentity: ForgeDraftIdentity
    ) {
        mutationTask?.cancel()
        let pendingDraftSave = draftSaveTask
        mutationTask = Task { [weak self, service, drafts] in
            do {
                await pendingDraftSave?.value
                guard !Task.isCancelled else { return }
                let outcome = try await service.editPullRequest(accountID: accountID, edit: edit)
                guard outcome.destination == destination else {
                    throw ForgePullRequestWorkflowError.mismatchedRepository
                }
                guard let self, !Task.isCancelled else { return }
                do {
                    try await drafts.delete(identity: draftIdentity)
                    self.logger.notice("Removed published Pull Request edit Forge Draft")
                } catch {
                    self.logger.error("Pull Request edit succeeded, but its published Forge Draft could not be removed")
                }
                _ = self.destinationOpening(outcome.destination)
                self.logger.notice("Saved conflict-aware Pull Request title/body edit")
            } catch is CancellationError {
                return
            } catch ForgePullRequestWorkflowError.editConflict {
                self?.windowController?.showMessageSheet(
                    "Pull Request Changed",
                    infoText: "Refresh the Pull Request before applying your title or body edit. Your text remains in the editor draft."
                )
            } catch {
                guard let self else { return }
                let offeredRecovery = self.presentAuthorizationRecovery(
                    error,
                    retry: { [weak self] in
                        self?.submitEdit(
                            accountID: accountID,
                            edit: edit,
                            destination: destination,
                            draftIdentity: draftIdentity
                        )
                    }
                )
                if !offeredRecovery {
                    self.windowController?.showErrorSheet(error)
                }
            }
        }
    }

    private func presentAuthorizationRecovery(
        _ error: Error,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        GitHubAuthorizationRecoveryPresenter.present(
            error: error,
            for: windowController,
            retry: retry
        )
    }
}
