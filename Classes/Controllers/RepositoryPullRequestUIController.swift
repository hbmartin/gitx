import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
struct RepositoryPullRequestPushOption {
    let preparation: RepositoryPullRequestCreationPreparation
    let initialForm: ForgePullRequestCreationForm
    let initiallySelected: Bool
}

/// Coordinates native PR presentation with the existing local push workflow.
/// Local Git remains authoritative for the push; this object starts a mutation only
/// after the push completion has returned successfully.
@MainActor
final class RepositoryPullRequestUIController {
    private unowned let repository: PBGitRepository
    private weak var windowController: PBGitWindowController?
    private let remoteActions: RepositoryRemoteActionCoordinator
    private let service: any RepositoryPullRequestMutationServing
    private let drafts: any RepositoryPullRequestDraftPersisting
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestWorkflow")
    private var preparationTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var sheetController: ForgePullRequestSheetController?
    private var activePreparation: RepositoryPullRequestCreationPreparation?

    init(
        repository: PBGitRepository,
        windowController: PBGitWindowController,
        remoteActions: RepositoryRemoteActionCoordinator,
        service: any RepositoryPullRequestMutationServing,
        drafts: any RepositoryPullRequestDraftPersisting = NullRepositoryPullRequestDraftStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.windowController = windowController
        self.remoteActions = remoteActions
        self.service = service
        self.drafts = drafts
        self.now = now
    }

    deinit {
        preparationTask?.cancel()
        mutationTask?.cancel()
        draftSaveTask?.cancel()
    }

    func newPullRequest() {
        guard let branch = repository.headRef()?.ref(), branch.isBranch else {
            windowController?.showErrorSheet(RepositoryPullRequestServiceError.noLocalBranch)
            return
        }
        prepare(branch: branch) { [weak self] preparation, form in
            guard let self else { return }
            if preparation.branchAlreadyPushed {
                self.presentCreateSheet(preparation: preparation, initialForm: form)
            } else {
                self.push(
                    branch: branch,
                    remote: nil,
                    requiresConfirmation: true,
                    option: RepositoryPullRequestPushOption(
                        preparation: preparation,
                        initialForm: form,
                        initiallySelected: true
                    )
                )
            }
        }
    }

    func performPush(
        branch: PBGitRef?,
        remote: PBGitRef?,
        requiresConfirmation: Bool,
        initiallyCreatePullRequest: Bool = false
    ) {
        guard let branch, branch.isBranch else {
            remoteActions.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                pullRequestOption: nil,
                completion: nil
            )
            return
        }
        prepare(branch: branch) { [weak self] preparation, form in
            guard let self else { return }
            self.push(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                option: RepositoryPullRequestPushOption(
                    preparation: preparation,
                    initialForm: form,
                    initiallySelected: initiallyCreatePullRequest
                )
            )
        } fallback: { [weak self] in
            self?.remoteActions.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                pullRequestOption: nil,
                completion: nil
            )
        }
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
                self?.windowController?.showErrorSheet(error)
            }
        }
    }

    private func prepare(
        branch: PBGitRef,
        completion: @escaping (RepositoryPullRequestCreationPreparation, ForgePullRequestCreationForm) -> Void,
        fallback: (() -> Void)? = nil
    ) {
        preparationTask?.cancel()
        guard let binding = RepositoryForgeCoordinator(repository: repository).resolveBinding().binding,
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
            head = try ForgeCommitID(repository.outputOfTask(withArguments: ["rev-parse", "HEAD"])
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
                if let fallback {
                    fallback()
                } else {
                    self.windowController?.showErrorSheet(error)
                }
                self.logger.error("Native Pull Request preparation failed; browser fallback remains available")
            }
        }
    }

    private func push(
        branch: PBGitRef,
        remote: PBGitRef?,
        requiresConfirmation: Bool,
        option: RepositoryPullRequestPushOption
    ) {
        remoteActions.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation,
            pullRequestOption: option
        ) { [weak self] selected in
            guard selected else { return }
            self?.presentCreateSheet(preparation: option.preparation, initialForm: option.initialForm)
        }
    }

    private func presentCreateSheet(
        preparation: RepositoryPullRequestCreationPreparation,
        initialForm: ForgePullRequestCreationForm
    ) {
        guard let window = windowController?.window else { return }
        activePreparation = preparation
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
        }
        sheet.onSubmit = { [weak self] submission in
            guard case let .create(accountID, form) = submission else { return }
            self?.submitCreate(accountID: accountID, form: form, preparation: preparation)
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

    private func submitCreate(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm,
        preparation: RepositoryPullRequestCreationPreparation
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
                guard let self, !Task.isCancelled else { return }
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
                do {
                    try await drafts.delete(identity: identity)
                    self.logger.notice("Removed published Pull Request Forge Draft")
                } catch {
                    self.logger.error("Pull Request succeeded, but its published Forge Draft could not be removed")
                }
                _ = self.windowController?.sidebarViewController?.openForgeDestination(destination)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
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
                _ = self.windowController?.sidebarViewController?.openForgeDestination(outcome.destination)
                self.logger.notice("Saved conflict-aware Pull Request title/body edit")
            } catch is CancellationError {
                return
            } catch ForgePullRequestWorkflowError.editConflict {
                self?.windowController?.showMessageSheet(
                    "Pull Request Changed",
                    infoText: "Refresh the Pull Request before applying your title or body edit. Your text remains in the editor draft."
                )
            } catch {
                self?.windowController?.showErrorSheet(error)
            }
        }
    }
}
