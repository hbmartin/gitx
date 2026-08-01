#if DEBUG
    import AppKit
    import ForgeKit
    import GitHubForgeAdapter

    /// Objective-C-compatible entry points which execute the shipped app
    /// module's Milestone 2 seams. The app-hosted XCTest bundle deliberately
    /// reaches this runtime class instead of compiling another copy of the
    /// production Swift sources.
    @MainActor
    @objc(PBMilestone2ProductCoverageHarness)
    // swiftlint:disable:next type_body_length unused_declaration
    final class Milestone2ProductCoverageHarness: NSObject {
        private static var retainedObjects: [AnyObject] = []

        @objc static func synchronousProof() -> UInt64 {
            guard let fixture = try? HarnessPullRequestFixture() else { return 0 }
            return bitProof([
                (try? workflowProof(fixture)) == true,
                (try? gitOperationProof(fixture)) == true,
                (try? sheetProof(fixture)) == true,
                (try? remoteActionProof(fixture)) == true,
                (try? deepLinkProof(fixture)) == true,
            ])
        }

        @objc(asyncProofWithCompletion:)
        // swiftlint:disable:next unused_declaration
        static func asyncProof(completion: @escaping (UInt64) -> Void) {
            Task { @MainActor in
                guard let fixture = try? HarnessPullRequestFixture() else {
                    completion(0)
                    return
                }
                let composition = (try? await compositionProof(fixture)) == true
                let localGit = (try? await localGitProof(fixture)) == true
                let ui = await loggedProof("ui") { try await uiControllerProof(fixture) }
                let quit = await loggedProof("quit") { try await mutationQuitProof(fixture) }
                let launchHarness = await loggedProof("launch") {
                    try await milestone2LaunchHarnessProof(fixture)
                }
                NSLog(
                    "[M2ProductCoverage] async composition=%d localGit=%d ui=%d quit=%d launch=%d",
                    composition,
                    localGit,
                    ui,
                    quit,
                    launchHarness
                )
                completion(bitProof([composition, localGit, ui, quit, launchHarness]))
            }
        }

        // MARK: Provider-neutral workflow

        private static func workflowProof(_ fixture: HarnessPullRequestFixture) throws -> Bool {
            _ = ForgeGitHubAppConfiguration.bundled()
            let preparation = try fixture.preparation(branchAlreadyPushed: false)
            let forms = try preparation.initialForms()
            guard let initial = forms.forms.first else { return false }
            let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
            let intent = try ForgePushPullRequestIntent(form: initial, draftIdentity: identity)
            let option = try RepositoryPullRequestPushOption(
                preparation: preparation,
                initialForm: initial,
                initiallySelected: true
            )

            var flow = RepositoryPullRequestPushFlow()
            try flow.beginOrdinaryPush(intent: intent)
            try flow.pushBegan(createPullRequestSelected: true)
            try flow.pushFailed()
            let preserved = flow.preservedIntent == intent
            try flow.beginNewPullRequest(branchAlreadyPushed: false, intent: intent)
            try flow.pushBegan(createPullRequestSelected: true)
            try flow.pushSucceeded()
            let sheetIntent = flow.createSheetIntent == intent
            try flow.createSheetCancelled()
            try flow.beginNewPullRequest(branchAlreadyPushed: true, intent: intent)
            let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
            try flow.existingPullRequest(destination)
            let completed = flow.state == .completed(destination)

            var cancelled = RepositoryPullRequestPushFlow()
            try cancelled.beginNewPullRequest(branchAlreadyPushed: false, intent: intent)
            try cancelled.pushCancelled()
            var successful = RepositoryPullRequestPushFlow()
            try successful.beginOrdinaryPush(intent: intent)
            try successful.pushBegan(createPullRequestSelected: false)
            try successful.pushSucceeded()

            let binding = try fixture.binding()
            guard let key = RepositoryPullRequestPreparationCacheKey(
                binding: binding,
                branch: preparation.head.name,
                localHead: preparation.head.commit,
                effectiveRemoteName: "origin",
                effectiveRemoteRepository: preparation.head.repository
            ) else { return false }
            let now = Date(timeIntervalSince1970: 100)
            let cache = RepositoryPullRequestPreparationCache(
                key: key,
                preparation: preparation,
                initialForm: initial,
                expiresAt: now.addingTimeInterval(10)
            )
            var cacheStore = RepositoryPullRequestPreparationCacheStore()
            cacheStore.replace(with: cache)
            let exact = cacheStore.takeExact(for: key, now: now) == cache
            cacheStore.replace(with: cache)
            let expired = cacheStore.takeExact(for: key, now: now.addingTimeInterval(10)) == nil

            let draft = try ForgeDraft(
                identity: identity,
                content: ForgeDraftContent(title: "Saved", body: "Saved body"),
                createdAt: now,
                lastActivityAt: now
            )
            let restored = try RepositoryPullRequestDraftPolicy.restoredForm(
                preparation: preparation,
                initial: initial,
                draft: draft
            )
            let snapshot = try fixture.editableSnapshot()
            let editIdentity = try RepositoryPullRequestDraftPolicy.editIdentity(
                accountID: fixture.accountID,
                snapshot: snapshot
            )
            let editDraft = try ForgeDraft(
                identity: editIdentity,
                content: ForgeDraftContent(title: "Edited", body: "Edited body"),
                createdAt: now,
                lastActivityAt: now
            )
            let restoredEdit = RepositoryPullRequestDraftPolicy.restoredEditContent(
                snapshot: snapshot,
                draft: editDraft
            )

            let remotePolicy = RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
                requestedRemoteName: nil,
                branchPushRemoteName: nil,
                defaultPushRemoteName: nil,
                trackingRemoteName: nil,
                boundRemoteName: "origin"
            ) == "origin"
            let parsedPush = RepositoryPullRequestPushRemotePolicy.pushRepository(
                rawURLs: "git@github.com:contributor/gitx.git\nhttps://github.com/contributor/gitx.git\n"
            ) == fixture.fork
            let rejectedPush = RepositoryPullRequestPushRemotePolicy.pushRepository(
                rawURLs: "https://github.com/a/gitx.git\nhttps://github.com/b/gitx.git\n"
            ) == nil
            var cancellationCount = 0
            let noWindow = !WindowDialogPresentationPolicy.cancelWithoutPresentation {
                cancellationCount += 1
            }
            let progress = RepositoryPushProgressStartPolicy.terminalEvent(didStart: false) == .failed
                && RepositoryPushProgressStartPolicy.terminalEvent(didStart: true) == nil
                && RepositoryPushProgressStartPolicy.rejectedEvents(createPullRequestSelected: true).count == 2
            let errorsHaveDescriptions = [
                RepositoryPullRequestServiceError.nativeCreationUnavailable,
                .repositoryUnavailable,
                .noLocalBranch,
                .invalidLocalHead,
                .draftUnavailable,
                .localDiffUnavailable,
                .checkoutVerificationFailed,
                .deepLinkUnavailable,
            ].allSatisfy { $0.errorDescription != nil }
            let unavailable = UnavailableRepositoryPullRequestMutationService()
            let resolver = RepositoryPullRequestServiceResolver { _ in
                RepositoryPullRequestApplicationSession(service: unavailable)
            }
            let resolverWorks = resolver.session(for: HarnessLocalRepository.empty).service is UnavailableRepositoryPullRequestMutationService
            let flowProof = option.intent == intent && preserved && sheetIntent && completed
                && cancelled.preservedIntent == intent && successful.state == .idle
            let cacheProof = exact && expired
            let draftProof = restored.title == "Saved" && !restored.isDraft
                && restoredEdit.title == "Edited" && restoredEdit.body == "Edited body"
            let policyProof = remotePolicy && parsedPush && rejectedPush && noWindow && cancellationCount == 1
                && progress && errorsHaveDescriptions && resolverWorks
            NSLog(
                "[M2ProductCoverage] workflow subproofs=%llu",
                bitProof([flowProof, cacheProof, draftProof, policyProof])
            )
            return flowProof && cacheProof && draftProof && policyProof
        }

        // MARK: Local Git and clone executors

        private static func gitOperationProof(_ fixture: HarnessPullRequestFixture) throws -> Bool {
            let plan = try fixture.checkoutPlan(addsRemote: true)
            let runner = HarnessGitRunner(head: fixture.headCommit.value)
            let receipt = try RepositoryPullRequestCheckoutExecutor(runner: runner).execute(plan)
            let wrongHead = HarnessGitRunner(head: fixture.baseCommit.value)
            let rejectedWrongHead = throwsExpected {
                _ = try RepositoryPullRequestCheckoutExecutor(runner: wrongHead).execute(plan)
            }
            let dirty = HarnessGitRunner(head: fixture.headCommit.value, status: "? dirty")
            let rejectedDirty = throwsExpected {
                _ = try RepositoryPullRequestCheckoutExecutor(runner: dirty).execute(plan)
            }
            let existingPlan = try fixture.checkoutPlan(addsRemote: false)
            let existing = HarnessGitRunner(head: fixture.headCommit.value, existingRefspec: existingPlan.fetchRefspec)
            _ = try RepositoryPullRequestCheckoutExecutor(runner: existing).execute(existingPlan)

            let request = try ForgeCloneRequest(
                accountID: fixture.accountID,
                repository: fixture.repository,
                relationship: .owned,
                transport: .https
            )
            let cloneChoice = try RepositoryForgeCloneChoice(
                request: request,
                destinationDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
            let cloneRunner = HarnessGitRunner(head: fixture.headCommit.value)
            let clone = try RepositoryForgeCloneExecutor(runner: cloneRunner).clone(cloneChoice)
            let ssh = try RepositoryForgeCloneURLPolicy.url(for: ForgeCloneRequest(
                accountID: fixture.accountID,
                repository: fixture.repository,
                relationship: .owned,
                transport: .ssh
            ))
            let invalidChoice = throwsExpected {
                _ = try RepositoryForgeCloneChoice(request: request, destinationDirectory: URL(string: "https://example.com")!)
            }
            let applicationReference = try ForgeCredentialReference(
                accountID: fixture.accountID,
                credentialID: ForgeCredentialID("m2-app-proof"),
                generation: ForgeCredentialGeneration(1)
            )
            let applicationAccount = try ForgeAccount(
                id: fixture.accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: applicationReference,
                    source: .forgeApplicationDeviceFlow,
                    expiresAt: Date(timeIntervalSince1970: 2_000_000)
                )
            )
            let applicationSecrets = try ForgeCredentialSecretMaterial(
                accessToken: Data("app-token".utf8),
                refreshToken: Data("refresh-token".utf8),
                refreshTokenExpiresAt: Date(timeIntervalSince1970: 3_000_000)
            )
            let evidence: [ForgeStoredCredentialAuthorizationEvidence] = [
                .githubApplicationMilestone3,
                .githubClassicScopes(["repo"]),
                .githubFineGrainedNotIntrospectable,
            ]
            let evidenceRoundTrips = try evidence.allSatisfy { value in
                try JSONDecoder().decode(
                    ForgeStoredCredentialAuthorizationEvidence.self,
                    from: JSONEncoder().encode(value)
                ) == value
            }
            let acceptedEvidence = try ForgeStoredCredentialEnvelope(
                account: applicationAccount,
                secrets: applicationSecrets,
                authorizationEvidence: .githubApplicationMilestone3
            ).authorizationEvidence == .githubApplicationMilestone3
            let rejectedEvidence = throwsExpected {
                _ = try ForgeStoredCredentialEnvelope(
                    account: applicationAccount,
                    secrets: applicationSecrets,
                    authorizationEvidence: .githubClassicScopes(["repo"])
                )
            }

            let compositionRepository = try HarnessLocalRepository(
                remoteURL: "git@github.com:contributor/gitx.git"
            )
            defer { compositionRepository.cleanup() }
            let defaults = UserDefaults(suiteName: "GitX-M2-Composition-\(UUID().uuidString)")!
            let composition = ApplicationComposition(
                userDefaults: defaults,
                automaticallyStartsForgeServices: false
            )
            RepositoryUISettings(
                repository: compositionRepository.repository,
                preferences: composition.applicationPreferences
            ).forgeRepositoryBinding = try fixture.binding()
            let previousComposition = ApplicationComposition.shared
            ApplicationComposition.setSharedComposition(composition)
            let applicationSession = composition.forgePullRequestServices.session(
                for: compositionRepository.repository
            )
            _ = composition.forgeCloneServices.service()
            let accountConfigurationBoundaries = ForgeGitHubAppConfiguration
                .runProductProofConfigurationBoundaries()
            ApplicationComposition.setSharedComposition(previousComposition)
            NSLog(
                "[M2ProductCoverage] git credential=%d rejected=%d composition=%d",
                evidenceRoundTrips,
                rejectedEvidence,
                !(applicationSession.service is UnavailableRepositoryPullRequestMutationService)
            )
            return receipt.fetchedHead == fixture.headCommit && rejectedWrongHead && rejectedDirty
                && existing.commands.contains { $0.first == "fetch" }
                && clone.repository == fixture.repository && clone.destinationURL.lastPathComponent == "gitx"
                && ssh.absoluteString == "ssh://git@github.com/gitx/gitx.git" && invalidChoice
                && evidenceRoundTrips && acceptedEvidence && rejectedEvidence
                && accountConfigurationBoundaries
                && !(applicationSession.service is UnavailableRepositoryPullRequestMutationService)
        }

        // MARK: Native sheets

        private static func sheetProof(_ fixture: HarnessPullRequestFixture) throws -> Bool {
            let preparation = try fixture.preparation()
            let forms = try preparation.initialForms()
            let create = ForgePullRequestSheetController(
                mode: .create(preparation: preparation, initialForms: forms),
                restoredContent: ForgeDraftContent(title: "Restored", body: "Body **preview**")
            )
            guard let createView = create.window?.contentView,
                  let submit = descendant("GitX.PullRequest.Submit", in: createView) as? NSButton,
                  let preview = descendant("GitX.PullRequest.WritePreview", in: createView) as? NSSegmentedControl,
                  let title = descendant("GitX.PullRequest.Title", in: createView) as? NSTextField
            else { return false }
            var submittedCreate = false
            create.onSubmit = { submission in
                if case let .create(account, form) = submission {
                    submittedCreate = account == fixture.accountID && form.title == "Restored"
                }
            }
            preview.selectedSegment = 1
            preview.sendAction(preview.action, to: preview.target)
            title.stringValue = "Restored"
            create.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            submit.performClick(nil)

            let snapshot = try fixture.editableSnapshot()
            let destination = ForgeDestination.pullRequest(fixture.repository, snapshot.number)
            let edit = ForgePullRequestSheetController(
                mode: .edit(accountID: fixture.accountID, snapshot: snapshot, destination: destination),
                restoredContent: ForgeDraftContent(title: "Edited", body: "Body")
            )
            guard let editView = edit.window?.contentView,
                  let editSubmit = descendant("GitX.PullRequest.Submit", in: editView) as? NSButton
            else { return false }
            var submittedEdit = false
            edit.onSubmit = { submission in
                if case let .edit(account, value, selectedDestination) = submission {
                    submittedEdit = account == fixture.accountID
                        && value.title == "Edited" && selectedDestination == destination
                }
            }
            editSubmit.performClick(nil)

            let cancellation = ForgePullRequestSheetController(
                mode: .create(preparation: preparation, initialForms: forms)
            )
            var cancellationCount = 0
            cancellation.onCancel = { _ in cancellationCount += 1 }
            if let window = cancellation.window {
                _ = cancellation.windowShouldClose(window)
                _ = cancellation.windowShouldClose(window)
            }

            let catalog = try fixture.cloneCatalog()
            let clone = ForgeRepositoryCloneSheetController(catalogs: [catalog, catalog])
            guard let cloneView = clone.window?.contentView,
                  let destinationField = descendant("GitX.Clone.Destination", in: cloneView) as? NSTextField,
                  let cloneButton = descendant("GitX.Clone.Submit", in: cloneView) as? NSButton,
                  let accountPopup = descendant("GitX.Clone.Account", in: cloneView) as? NSPopUpButton
            else {
                NSLog("[M2ProductCoverage] sheet clone controls unavailable")
                return false
            }
            accountPopup.selectItem(at: 1)
            accountPopup.sendAction(accountPopup.action, to: accountPopup.target)
            accountPopup.selectItem(at: 0)
            accountPopup.sendAction(accountPopup.action, to: accountPopup.target)
            destinationField.stringValue = NSTemporaryDirectory()
            clone.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
            let choice = try clone.selectedChoice()
            var cloned = false
            clone.onClone = { cloned = $0.request == choice.request }
            let cloneParent = NSWindow()
            clone.beginSheet(for: cloneParent)
            cloneButton.performClick(nil)

            let emptyClone = ForgeRepositoryCloneSheetController(catalogs: [])
            let emptyRejected = throwsExpected {
                _ = try emptyClone.selectedChoice()
            }
            let cancelledClone = ForgeRepositoryCloneSheetController(catalogs: [catalog])
            guard let cancelButton = descendant(
                "GitX.Clone.Cancel",
                in: cancelledClone.window?.contentView
            ) as? NSButton else { return false }
            cancelButton.performClick(nil)

            let statusView = RepositoryStatusBarView(
                frame: NSRect(x: 0, y: 0, width: 700, height: 29)
            )
            statusView.viewDidChangeEffectiveAppearance()

            let stagingRepository = try HarnessLocalRepository(
                remoteURL: "git@github.com:contributor/gitx.git"
            )
            defer { stagingRepository.cleanup() }
            let stagingWindowController = HarnessWindowController(
                repository: stagingRepository.repository,
                window: NSWindow()
            )
            guard let history = PBGitHistoryController(
                repository: stagingRepository.repository,
                superController: stagingWindowController
            ) else {
                NSLog("[M2ProductCoverage] sheet staging history unavailable")
                return false
            }
            let staging = StagingViewController(
                repository: stagingRepository.repository,
                hostController: history
            )
            guard let createAfterPush = descendant(
                "GitX.Staging.CreatePullRequestAfterPush",
                in: staging.view
            ) as? NSButton,
                let pushAfterCommit = descendant("PushAfterCommit", in: staging.view) as? NSButton
            else {
                NSLog("[M2ProductCoverage] sheet staging controls unavailable")
                return false
            }
            createAfterPush.state = .on
            staging.createPullRequestAfterPushChanged(createAfterPush)
            NotificationCenter.default.post(
                name: NSNotification.Name(PBGitIndexCommitOutput),
                object: stagingRepository.repository.index,
                userInfo: ["output": "Product coverage proof"]
            )
            let stagingArmed = pushAfterCommit.state == .on
            let sidebar = PBGitSidebarController(
                repository: stagingRepository.repository,
                superController: stagingWindowController
            )
            sidebar?.productProofForgeDestinationOpening = { _ in true }
            let sidebarPullRequest = try sidebar?.openForgeDestination(
                ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
            ) == true
            let sidebarIssue = try sidebar?.openForgeDestination(
                ForgeDestination.issue(fixture.repository, ForgeItemNumber(43))
            ) == true
            sidebar?.productProofForgeDestinationOpening = nil
            let sidebarUnavailable = sidebar?.openForgeDestination(
                ForgeDestination.repository(fixture.repository)
            ) == false
            staging.closeView()
            NSLog(
                "[M2ProductCoverage] sheet create=%d edit=%d cancel=%d rows=%d ssh=%d cloned=%d empty=%d staging=%d",
                submittedCreate,
                submittedEdit,
                cancellationCount,
                clone.numberOfRows(in: NSTableView()),
                choice.request.transport == .ssh,
                cloned,
                emptyRejected,
                stagingArmed
            )
            return submittedCreate && submittedEdit && cancellationCount == 1
                && clone.numberOfRows(in: NSTableView()) == 1
                && choice.request.transport == .ssh && cloned && emptyRejected && stagingArmed
                && sidebarPullRequest && sidebarIssue && sidebarUnavailable
        }

        // MARK: Existing remote action coordinator

        private static func remoteActionProof(_ fixture: HarnessPullRequestFixture) throws -> Bool {
            let local = try HarnessLocalRepository(remoteURL: "https://github.com/hbmartin/gitx.git")
            defer { local.cleanup() }
            let windowController = PBGitWindowController(window: NSWindow())
            var starts = 0
            var completions = 0
            let coordinator = RepositoryRemoteActionCoordinator(
                repository: local.repository,
                windowController: windowController
            ) { _, _, _, completion in
                starts += 1
                completion(nil)
                completions += 1
                return true
            }
            let branch = local.repository.headRef()?.ref()
            let remote = PBGitRef(string: kGitXRemoteRefPrefix + "origin")
            var invalidEvents: [RepositoryPushEvent] = []
            coordinator.performPush(
                branch: PBGitRef(string: "not-a-push-ref"),
                remote: nil,
                requiresConfirmation: false,
                pullRequestOption: nil,
                completion: { invalidEvents.append($0) }
            )
            var pushEvents: [RepositoryPushEvent] = []
            coordinator.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: false,
                pullRequestOption: nil,
                pullRequestOffer: RepositoryPullRequestPushOffer(
                    initiallySelected: true,
                    presentation: .capability(
                        .verified(.knownAuthority),
                        action: "create a Pull Request after pushing"
                    )
                ),
                suppressesPostPushBrowserSuggestion: true,
                completion: { pushEvents.append($0) }
            )
            coordinator.performFetch(for: remote)
            coordinator.performPull(branch: branch, remote: nil, rebase: false)
            coordinator.performPull(branch: nil, remote: remote, rebase: true)
            coordinator.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: false
            )

            var failedStartEvents: [RepositoryPushEvent] = []
            let failedStart = RepositoryRemoteActionCoordinator(
                repository: local.repository,
                windowController: windowController
            ) { _, _, _, _ in false }
            failedStart.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: false,
                pullRequestOption: nil,
                completion: { failedStartEvents.append($0) }
            )

            let cancellingWindow = HarnessDialogWindowController(window: NSWindow())
            let cancelled = RepositoryRemoteActionCoordinator(
                repository: local.repository,
                windowController: cancellingWindow
            ) { _, _, _, _ in true }
            let dynamicOffer = RepositoryPullRequestPushOffer(initiallySelected: true)
            cancellingWindow.beforeCancellation = {
                dynamicOffer.update(.capability(
                    .verified(.knownAuthority),
                    action: "create a Pull Request after pushing"
                ))
                dynamicOffer.update(.publicReadOnly(
                    action: "create a Pull Request after pushing"
                ))
            }
            var cancelledEvents: [RepositoryPushEvent] = []
            cancelled.performPush(
                branch: branch,
                remote: remote,
                requiresConfirmation: true,
                pullRequestOption: nil,
                pullRequestOffer: dynamicOffer,
                completion: { cancelledEvents.append($0) }
            )
            let capabilityWindow = HarnessDialogWindowController(window: nil)
            guard let collaboration = RepositoryForgeCollaborationController(
                repository: local.repository,
                superController: capabilityWindow
            ) else { return false }
            let collaborationCapabilityProof = try collaboration.runMutationCapabilityProductProof(
                account: fixture.account(),
                binding: fixture.binding(),
                parent: fixture.fork,
                snapshot: fixture.editableSnapshot(),
                destination: .pullRequest(fixture.repository, ForgeItemNumber(42))
            )
            let mutationPresentationProof = try mutationControlPresentationProof(fixture)
            let createControlProof = createPullRequestControlProof(repository: local.repository)
            return invalidEvents == [.began(createPullRequestSelected: false), .failed]
                && pushEvents.first == .began(createPullRequestSelected: true)
                && pushEvents.last?.isTerminal == true && starts == 5 && completions == 5
                && failedStartEvents == [.began(createPullRequestSelected: false), .failed]
                && cancelledEvents == [.cancelled] && cancellingWindow.cancellationCount == 1
                && collaborationCapabilityProof && mutationPresentationProof && createControlProof
        }

        private static func createPullRequestControlProof(repository: PBGitRepository) -> Bool {
            let windowController = HarnessWindowController(repository: repository, window: NSWindow())
            let toolbarController = RepositoryToolbarController(windowController: windowController)
            let toolbar = NSToolbar(identifier: "GitX.Repository.HistoryToolbar")
            guard let toolbarItem = toolbarController.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.NewPullRequest"),
                willBeInsertedIntoToolbar: true
            ) else { return false }
            let menuItem = NSMenuItem(
                title: "New Pull Request",
                action: NSSelectorFromString("newPullRequest:"),
                keyEquivalent: ""
            )
            let apply: (ForgeMutationControlPresentation) -> Void = { presentation in
                windowController.updateCreatePullRequestControl(presentation)
                toolbarController.updateCreatePullRequestControl(presentation)
            }

            let checking = ForgeMutationControlPresentation.checking(action: "create a Pull Request")
            apply(checking)
            let checkingDisabled = !windowController.validateMenuItem(menuItem)
                && !toolbarItem.isEnabled
                && menuItem.toolTip == checking.helpText
                && toolbarItem.toolTip == checking.helpText

            let publicReadOnly = ForgeMutationControlPresentation.publicReadOnly(action: "create a Pull Request")
            apply(publicReadOnly)
            windowController.newPullRequest(nil)
            let publicDisabled = !windowController.validateMenuItem(menuItem)
                && !menuItem.isHidden
                && !toolbarItem.isEnabled
                && toolbarItem.label == "New Pull Request"
                && windowController.pullRequestUIController == nil

            let unavailable = ForgeMutationControlPresentation.capability(
                .unavailable(.knownOperationRestriction),
                action: "create a Pull Request"
            )
            apply(unavailable)
            let unavailableDisabled = !windowController.validateMenuItem(menuItem)
                && !toolbarItem.isEnabled
                && toolbarItem.toolTip == unavailable.helpText

            let verified = ForgeMutationControlPresentation.capability(
                .verified(.knownAuthority),
                action: "create a Pull Request"
            )
            apply(verified)
            let verifiedEnabled = windowController.validateMenuItem(menuItem)
                && toolbarItem.isEnabled
                && toolbarItem.toolTip == "Create a Pull Request for the checked-out branch"
            windowController.newPullRequest(nil)
            let directInvocationEnabled = windowController.pullRequestUIController != nil

            let unverified = ForgeMutationControlPresentation(
                isVisible: true,
                isEnabled: true,
                helpText: "GitHub will verify this fine-grained token when this operation is confirmed."
            )
            apply(unverified)
            let unverifiedEnabled = windowController.validateMenuItem(menuItem)
                && toolbarItem.isEnabled
                && toolbarItem.toolTip == unverified.helpText

            var ephemeralController: HarnessWindowController? = HarnessWindowController(
                repository: repository,
                window: nil
            )
            ephemeralController?.ensureActionCoordinators()
            let detachedPullRequestController = ephemeralController?.pullRequestUIController
            weak var releasedController: HarnessWindowController?
            releasedController = ephemeralController
            ephemeralController = nil
            detachedPullRequestController?.performPush(
                branch: nil,
                remote: nil,
                requiresConfirmation: false
            )
            let releasedControllerFailsClosed = releasedController == nil

            return RepositoryForgeCollaborationController.mutationCapabilityOperations
                == [.createPullRequest, .editPullRequest, .syncFork]
                && RepositoryForgeCollaborationController.readCapabilityOperations
                == [.readPullRequests, .readIssues]
                && RepositoryForgeCollaborationController.collaborationCapabilityOperations
                == [
                    .readPullRequests,
                    .readIssues,
                    .createPullRequest,
                    .editPullRequest,
                    .syncFork,
                ]
                && checkingDisabled && publicDisabled && unavailableDisabled
                && verifiedEnabled && directInvocationEnabled && unverifiedEnabled
                && releasedControllerFailsClosed
        }

        private static func mutationControlPresentationProof(
            _ fixture: HarnessPullRequestFixture
        ) throws -> Bool {
            let account = try fixture.account()
            let credential = account.currentCredential.reference
            let permissionEvidence = try ForgePermissionEvidence(
                credential: credential,
                repository: fixture.repository,
                freshness: .current,
                grants: ForgeRepositoryPermission.allCases.map {
                    ForgePermissionGrant(permission: $0, authority: .unknown)
                }
            )
            let accessEvidence = ForgeRepositoryAccessEvidence(
                credential: credential,
                repository: fixture.repository,
                freshness: .current,
                status: .granted,
                role: .known(.write)
            )
            let unverified = ForgeCapabilityEvaluator.capability(
                account: account,
                repository: fixture.repository,
                operation: .createPullRequest,
                operationSupported: true,
                credentialAvailability: .available,
                now: Date(timeIntervalSince1970: 1),
                permissionEvidence: permissionEvidence,
                accessEvidence: accessEvidence,
                promotions: ForgeCapabilityPromotionLedger()
            )
            let reasons: [ForgeCapabilityUnavailableReason] = [
                .noCurrentCredential,
                .mismatchedForge,
                .unsupportedProviderOperation,
                .credentialUnavailable,
                .credentialExpired,
                .mismatchedCredentialEvidence,
                .mismatchedRepositoryEvidence,
                .missingPermission(.pullRequests),
                .repositoryAccessDenied,
                .samlAuthorizationRequired,
                .installationConfigurationRequired,
                .inadequateRepositoryRole(required: .write, actual: .read),
                .authorizationEvidenceUnavailable,
                .authorizationEvidenceNotCurrent,
                .knownOperationRestriction,
            ]
            let unavailable = reasons.map {
                ForgeMutationControlPresentation.capability(
                    .unavailable($0),
                    action: "perform this mutation"
                )
            }
            let unverifiedPresentation = ForgeMutationControlPresentation.capability(
                unverified,
                action: "perform this mutation"
            )
            let errorPresentation = ForgeMutationControlPresentation.unavailable(
                error: RepositoryPullRequestServiceError.nativeCreationUnavailable,
                action: "perform this mutation"
            )
            return unverifiedPresentation.isEnabled
                && unverifiedPresentation.helpText?.isEmpty == false
                && unavailable.allSatisfy { !$0.isEnabled && $0.helpText?.isEmpty == false }
                && !errorPresentation.isEnabled && errorPresentation.helpText?.isEmpty == false
        }

        // MARK: Deep-link application bridge

        private static func deepLinkProof(_ fixture: HarnessPullRequestFixture) throws -> Bool {
            let router = ForgeDeepLinkApplicationRouter()
            router.installIfNeeded()
            router.installIfNeeded()
            let repositoryURL = try ForgeDeepLinkCodec.url(for: .repository(fixture.repository))
            let pullRequestURL = try ForgeDeepLinkCodec.url(
                for: .pullRequest(fixture.repository, ForgeItemNumber(42))
            )
            let inferred = try router.parse(repositoryURL, knownRepositories: [])
            let exact = try router.parse(pullRequestURL, knownRepositories: [fixture.repository])
            let rejected = throwsExpected {
                _ = try router.parse(URL(string: "x-gitx://gitlab.example/a/b/issues/1")!, knownRepositories: [])
            }
            return try inferred == .repository(fixture.repository)
                && exact == .pullRequest(fixture.repository, ForgeItemNumber(42)) && rejected
        }

        // MARK: Production composition service

        // swiftlint:disable:next function_body_length
        private static func compositionProof(_ fixture: HarnessPullRequestFixture) async throws -> Bool {
            let preparation = try fixture.preparation()
            let form = try preparation.initialForms().forms[0]
            let binding = try fixture.binding()
            let local = HarnessLocalPreparation(preparation: preparation)

            let createdDependencies = try fixture.dependencies(.created)
            let createdService = RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: createdDependencies,
                localPreparation: local
            )
            let requestedOperations: Set<ForgeOperation> = [.createPullRequest, .syncFork]
            let capabilities = try await createdService.capabilities(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operations: requestedOperations
            )
            let capabilityRequests = await createdDependencies.capabilityRequests
            let capabilityAccountIDs = await createdDependencies.capabilityAccountIDs
            let rejectedCapabilityAccount = await throwsExpectedAsync {
                _ = try await createdService.capabilities(
                    accountID: ForgeAccountID(forge: fixture.accountID.forge, value: "other"),
                    repository: fixture.repository,
                    operations: requestedOperations
                )
            }
            let prepared = try await createdService.prepareCreation(
                repository: fixture.repository,
                localBranch: fixture.head.name,
                localHead: fixture.head.commit
            )
            let created = try await createdService.createPullRequest(accountID: fixture.accountID, form: form)

            let existingService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.existing),
                localPreparation: local
            )
            let existing = try await existingService.createPullRequest(accountID: fixture.accountID, form: form)

            let edit = try ForgePullRequestEdit(
                snapshot: fixture.editableSnapshot(),
                title: "Updated title",
                bodyMarkdown: "Updated body"
            )
            let editService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.edited),
                localPreparation: local
            )
            let edited = try await editService.editPullRequest(accountID: fixture.accountID, edit: edit)

            var syncSummaries: [String] = []
            for behavior in HarnessMutationBehavior.syncBehaviors {
                let service = try RepositoryPullRequestProductionService(
                    binding: fixture.forkBinding(),
                    dependencies: fixture.dependencies(behavior),
                    localPreparation: local
                )
                let outcome = try await service.syncFork(
                    accountID: fixture.accountID,
                    plan: fixture.syncPlan()
                )
                syncSummaries.append(outcome.serverSummary)
            }

            let reconciledService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.unknownCreateWithExistingRead),
                localPreparation: local
            )
            let reconciled = try await reconciledService.createPullRequest(
                accountID: fixture.accountID,
                form: form
            )
            let authoritativeService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.authoritativeCreateWithExistingRead),
                localPreparation: local
            )
            let authoritative = try await authoritativeService.createPullRequest(
                accountID: fixture.accountID,
                form: form
            )
            let unknownEditService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.unknownEditMatchingRead),
                localPreparation: local
            )
            let reconciledEdit = try await unknownEditService.editPullRequest(
                accountID: fixture.accountID,
                edit: edit
            )
            let rejectedAccount = await throwsExpectedAsync {
                _ = try await createdService.createPullRequest(
                    accountID: ForgeAccountID(forge: fixture.accountID.forge, value: "other"),
                    form: form
                )
            }
            let offlineService = try RepositoryPullRequestProductionService(
                binding: binding,
                dependencies: fixture.dependencies(.failure(.offline)),
                localPreparation: local
            )
            let mappedOffline = await throwsExpectedAsync {
                _ = try await offlineService.createPullRequest(accountID: fixture.accountID, form: form)
            }

            let credential = try fixture.credentialReference()
            let key = ForgeCapabilityKey(
                credential: credential,
                repository: fixture.repository,
                operation: .createPullRequest
            )
            let verified = try ForgeGitHubPullRequestDependencyProvider.authorization(
                key: key,
                capability: .verified(.knownAuthority),
                operationWasConfirmed: true
            )
            let unavailable = throwsExpected {
                _ = try ForgeGitHubPullRequestDependencyProvider.authorization(
                    key: key,
                    capability: .unavailable(.credentialUnavailable),
                    operationWasConfirmed: true
                )
            }
            let scopeBranches = ForgeRepositoryPermission.allCases.map {
                ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                    permission: $0,
                    scopes: ["repo"],
                    repositoryIsPublic: false
                )
            }
            let createdDestination = switch created {
            case let .created(destination), let .existing(destination): destination
            }
            let existingDestination = switch existing {
            case let .created(destination), let .existing(destination): destination
            }
            let reconciledDestination = switch reconciled {
            case let .created(destination), let .existing(destination): destination
            }
            let authoritativeDestination = switch authoritative {
            case let .created(destination), let .existing(destination): destination
            }
            return prepared.repository == fixture.repository
                && Set(capabilities.keys) == requestedOperations
                && capabilities.values.allSatisfy { $0 == .verified(.knownAuthority) }
                && capabilityRequests == [requestedOperations]
                && capabilityAccountIDs == [fixture.accountID]
                && rejectedCapabilityAccount
                && createdDestination.repository == fixture.repository
                && existingDestination.repository == fixture.repository
                && edited.snapshot.title == "Updated title"
                && syncSummaries.count == HarnessMutationBehavior.syncBehaviors.count
                && reconciledDestination == createdDestination
                && authoritativeDestination == createdDestination
                && reconciledEdit.snapshot.title == "Updated title"
                && rejectedAccount && mappedOffline && verified.key == key && unavailable
                && scopeBranches.allSatisfy { $0 != .unknown }
        }

        // MARK: Local asynchronous production workers

        private static func localGitProof(_ fixture: HarnessPullRequestFixture) async throws -> Bool {
            let local = try HarnessLocalRepository(remoteURL: "git@github.com:contributor/gitx.git")
            defer { local.cleanup() }
            let repositoryProvider = RepositoryLocalPullRequestChangesProvider(repository: local.repository)
            let commit = try ForgeCommitID(local.head)
            let base = try ForgeBranchReference(
                repository: fixture.repository,
                name: ForgeRefName("main"),
                commit: commit
            )
            let head = try ForgeBranchReference(
                repository: fixture.fork,
                name: ForgeRefName("main"),
                commit: commit
            )
            let diff = try await repositoryProvider.changes(
                repository: fixture.repository,
                base: base,
                head: head
            )
            let mismatched = await throwsExpectedAsync {
                _ = try await repositoryProvider.changes(
                    repository: fixture.fork,
                    base: base,
                    head: head
                )
            }
            let source = RepositoryPullRequestLocalPreparationSource(repository: local.repository)
            let preparation = try await source.preparation(
                accountID: fixture.accountID,
                binding: fixture.binding(),
                localBranch: ForgeRefName("main"),
                localHead: commit,
                defaultBranch: ForgeRefName("main")
            )
            let planner = RepositoryPullRequestCheckoutPlanner(repository: local.repository)
            let summary = try fixture.summary(headCommit: commit, headName: "main")
            let plan = try await planner.plan(for: summary)
            let syncRunner = HarnessGitRunner(head: commit.value)
            let sync = try await RepositorySyncForkCoordinator(
                service: HarnessSyncService(),
                runner: syncRunner
            ).sync(accountID: fixture.accountID, plan: fixture.syncPlan())
            let syncFailure = await throwsExpectedAsync {
                _ = try await RepositorySyncForkCoordinator(
                    service: HarnessSyncService(),
                    runner: HarnessGitRunner(head: commit.value, failsFetch: true)
                ).sync(accountID: fixture.accountID, plan: fixture.syncPlan())
            }
            return diff.title.contains("main") && mismatched
                && preparation.repository == fixture.repository
                && plan.expectedHead == commit && sync.fetchedRemote == "origin" && syncFailure
        }

        // MARK: AppKit workflow coordinator

        // swiftlint:disable:next function_body_length
        private static func uiControllerProof(_ fixture: HarnessPullRequestFixture) async throws -> Bool {
            let local = try HarnessLocalRepository(remoteURL: "git@github.com:contributor/gitx.git")
            defer { local.cleanup() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let windowController = PBGitWindowController(window: window)
            let localHead = try ForgeBranchReference(
                repository: fixture.fork,
                name: ForgeRefName("main"),
                commit: ForgeCommitID(local.head)
            )
            let preparation = try RepositoryPullRequestCreationPreparation(
                accountID: fixture.accountID,
                repository: fixture.repository,
                base: fixture.base,
                head: localHead,
                branchAlreadyPushed: true,
                commitsOldestFirst: [ForgePullRequestCommitSummary(
                    id: localHead.commit,
                    subject: "Native PR",
                    body: "Product coverage proof"
                )]
            )
            let service = HarnessUIService(fixture: fixture, preparation: preparation)
            let drafts = HarnessDraftStore()
            let remoteActions = HarnessRemoteActions(events: [])
            var opened: [ForgeDestination] = []
            let controller = RepositoryPullRequestUIController(
                repository: local.repository,
                windowController: windowController,
                remoteActions: remoteActions,
                service: service,
                drafts: drafts,
                destinationOpening: { opened.append($0); return true },
                bindingResolving: { try? fixture.binding() },
                postPushBrowserFallback: { _ in }
            )
            windowController.pullRequestUIController = controller
            let initial = try preparation.initialForms().forms[0]
            try controller.beginUITestCreateJourney(
                preparation: preparation,
                initialForm: initial,
                branch: local.repository.headRef()?.ref(),
                requiresPush: false
            )
            guard await eventually({ window.attachedSheet != nil }),
                  let createView = window.attachedSheet?.contentView,
                  let createButton = descendant("GitX.PullRequest.Submit", in: createView) as? NSButton
            else { return false }
            createButton.performClick(nil)
            let created = await eventually { !opened.isEmpty }

            let editSnapshot = try fixture.editableSnapshot()
            let editDestination = try ForgeDestination.pullRequest(
                fixture.repository,
                ForgeItemNumber(42)
            )
            windowController.editPullRequest(
                accountID: fixture.accountID,
                snapshot: editSnapshot,
                destination: editDestination
            )
            guard await eventually({ window.attachedSheet != nil }),
                  let editView = window.attachedSheet?.contentView,
                  let editButton = descendant("GitX.PullRequest.Submit", in: editView) as? NSButton
            else { return false }
            editButton.performClick(nil)
            let edited = await eventually { opened.count >= 2 }

            let exactPushWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let exactPushWindowController = PBGitWindowController(window: exactPushWindow)
            let exactPushActions = HarnessRemoteActions(events: [
                .began(createPullRequestSelected: true), .succeeded,
            ])
            let exactPushPreparation = try RepositoryPullRequestCreationPreparation(
                accountID: preparation.accountID,
                repository: preparation.repository,
                base: preparation.base,
                head: preparation.head,
                branchAlreadyPushed: false,
                commitsOldestFirst: preparation.commitsOldestFirst
            )
            let exactPushForm = try exactPushPreparation.initialForms().forms[0]
            var exactPushUsedBrowserFallback = false
            let exactPushController = RepositoryPullRequestUIController(
                repository: local.repository,
                windowController: exactPushWindowController,
                remoteActions: exactPushActions,
                service: service,
                drafts: drafts,
                destinationOpening: { _ in false },
                bindingResolving: { try? fixture.binding() },
                postPushBrowserFallback: { _ in exactPushUsedBrowserFallback = true }
            )
            let exactPushBranch = local.repository.headRef()?.ref()
            try exactPushController.beginUITestCreateJourney(
                preparation: exactPushPreparation,
                initialForm: exactPushForm,
                branch: exactPushBranch,
                requiresPush: true
            )
            let exactPushSheet = await eventually { exactPushWindow.attachedSheet != nil }
            let exactPushTitle = descendant(
                "GitX.PullRequest.Title",
                in: exactPushWindow.attachedSheet?.contentView
            ) as? NSTextField
            let exactPushInvocation = exactPushActions.recordedInvocations.first
            let exactPushProof = exactPushActions.recordedInvocations.count == 1
                && exactPushInvocation?.branch?.ref == exactPushBranch?.ref
                && exactPushInvocation?.remote?.ref == "refs/remotes/origin"
                && exactPushInvocation?.requiresConfirmation == true
                && exactPushInvocation?.option?.preparation == exactPushPreparation
                && exactPushInvocation?.option?.intent.form == exactPushForm
                && exactPushInvocation?.option?.initiallySelected == true
                && exactPushInvocation?.offer == nil
                && exactPushInvocation?.suppressesPostPushBrowserSuggestion == false
                && exactPushSheet
                && exactPushTitle?.stringValue == exactPushForm.title
                && !exactPushUsedBrowserFallback

            let pushActions = HarnessRemoteActions(events: [
                .began(createPullRequestSelected: false), .succeeded,
            ])
            let pushController = RepositoryPullRequestUIController(
                repository: local.repository,
                windowController: windowController,
                remoteActions: pushActions,
                service: service,
                destinationOpening: { _ in false },
                bindingResolving: { try? fixture.binding() },
                postPushBrowserFallback: { _ in }
            )
            windowController.pullRequestUIController = pushController
            windowController.performPush(
                forBranch: local.repository.headRef()?.ref(),
                toRemote: nil,
                requiresConfirmation: true
            )
            windowController.performPush(
                forBranch: nil,
                toRemote: nil,
                requiresConfirmation: false
            )

            let deferredWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let deferredWindowController = HarnessDialogWindowController(window: deferredWindow)
            let deferredActions = HarnessRemoteActions(events: [
                .began(createPullRequestSelected: true), .succeeded,
            ])
            let deferredController = RepositoryPullRequestUIController(
                repository: local.repository,
                windowController: deferredWindowController,
                remoteActions: deferredActions,
                service: service,
                drafts: drafts,
                destinationOpening: { _ in true },
                bindingResolving: { try? fixture.binding() },
                postPushBrowserFallback: { _ in }
            )
            deferredWindowController.pullRequestUIController = deferredController
            deferredWindowController.performPush(
                forBranch: local.repository.headRef()?.ref(),
                toRemote: nil,
                requiresConfirmation: false,
                initiallyCreatePullRequest: true
            )
            let deferredSheet = await eventually {
                descendant("GitX.PullRequest.Cancel", in: deferredWindow.attachedSheet?.contentView) != nil
            }
            if let cancel = descendant(
                "GitX.PullRequest.Cancel",
                in: deferredWindow.attachedSheet?.contentView
            ) as? NSButton {
                cancel.performClick(nil)
            }
            let deferredClosed = await eventually { deferredWindow.attachedSheet == nil }

            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let newWindowController = HarnessDialogWindowController(window: newWindow)
            var newOpened = false
            let newController = RepositoryPullRequestUIController(
                repository: local.repository,
                windowController: newWindowController,
                remoteActions: HarnessRemoteActions(events: []),
                service: service,
                drafts: drafts,
                destinationOpening: { _ in newOpened = true; return true },
                bindingResolving: { try? fixture.binding() },
                postPushBrowserFallback: { _ in }
            )
            newWindowController.pullRequestUIController = newController
            newWindowController.updateCreatePullRequestControl(.capability(
                .verified(.knownAuthority),
                action: "create a Pull Request"
            ))
            newWindowController.presentNewPullRequest()
            guard await eventually({ newWindow.attachedSheet != nil }),
                  let newSubmit = descendant(
                      "GitX.PullRequest.Submit",
                      in: newWindow.attachedSheet?.contentView
                  ) as? NSButton
            else { return false }
            newSubmit.performClick(nil)
            let newCreated = await eventually { newOpened }
            guard await eventually({ newWindow.attachedSheet == nil }) else { return false }

            let checkoutSummary = try fixture.summary()
            newWindowController.checkoutPullRequest(checkoutSummary)
            let checkoutPrompt = await eventually {
                newWindowController.confirmationCount >= 1
            }
            try Data("dirty\n".utf8).write(
                to: local.directory.appendingPathComponent("tracked.txt"),
                options: .atomic
            )
            try newController.checkout(fixture.checkoutPlan(addsRemote: false))
            let checkoutFailure = await eventually {
                newWindowController.errorCount >= 1
            }
            let failedSyncPlan = try ForgeSyncForkPlan(
                fork: fixture.fork,
                parent: fixture.repository,
                branch: ForgeRefName("main"),
                localFetchRemoteName: "missing"
            )
            newWindowController.syncFork(accountID: fixture.accountID, plan: failedSyncPlan)
            let syncFailure = await eventually {
                newWindowController.errorCount >= 2
            }
            let saveCount = await drafts.saveCount
            let deleteCount = await drafts.deleteCount
            NSLog(
                "[M2ProductCoverage] ui created=%d edited=%d push=%d new=%d prompt=%d checkoutFailure=%d syncFailure=%d saves=%d deletes=%d",
                created,
                edited,
                pushActions.invocations,
                newCreated,
                checkoutPrompt,
                checkoutFailure,
                syncFailure,
                saveCount,
                deleteCount
            )
            let previousComposition = ApplicationComposition.shared
            let wiringDefaults = UserDefaults(suiteName: "GitX-M2-Wiring-\(UUID().uuidString)")!
            let wiringComposition = ApplicationComposition(
                userDefaults: wiringDefaults,
                automaticallyStartsForgeServices: false
            )
            RepositoryUISettings(
                repository: local.repository,
                preferences: wiringComposition.applicationPreferences
            ).forgeRepositoryBinding = try fixture.binding()
            ApplicationComposition.setSharedComposition(wiringComposition)
            let wiringWindow = HarnessWindowController(repository: local.repository, window: NSWindow())
            wiringWindow.ensureActionCoordinators()
            let wiringDestination = try ForgeDestination.pullRequest(
                fixture.repository,
                ForgeItemNumber(42)
            )
            let wiringProof: Bool
            if let wiredController = wiringWindow.pullRequestUIController {
                _ = wiredController.destinationOpening(wiringDestination)
                let binding = wiredController.bindingResolving()
                wiredController.postPushBrowserFallback(nil)
                wiringProof = binding?.primaryRepository == fixture.repository
            } else {
                wiringProof = false
            }
            setenv("GITX_M2_UITEST", "1", 1)
            wiringWindow.installRepositoryForgeOverlaySession()
            unsetenv("GITX_M2_UITEST")
            ApplicationComposition.setSharedComposition(previousComposition)
            NSLog(
                "[M2ProductCoverage] ui deferredSheet=%d deferredClosed=%d deferredActions=%d wiring=%d",
                deferredSheet,
                deferredClosed,
                deferredActions.invocations,
                wiringProof
            )
            return created && edited && exactPushProof && pushActions.invocations >= 1
                && deferredSheet && deferredClosed && deferredActions.invocations == 1
                && newCreated && checkoutPrompt && checkoutFailure && syncFailure && wiringProof
                && saveCount >= 2 && deleteCount >= 2
        }

        // MARK: Quit and unknown-outcome persistence

        private static func mutationQuitProof(_ fixture: HarnessPullRequestFixture) async throws -> Bool {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitX-M2-Unknown-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
                databaseURL: directory.appendingPathComponent("forge.sqlite3"),
                recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
            ))
            let persistence = ForgeSQLiteUnknownMutationOutcomeStore(database: database)
            let replies = HarnessTerminationReplies()
            let waitCoordinator = ForgeMutationQuitCoordinator(
                persistence: persistence,
                choiceProvider: { _ in .wait },
                terminationReply: { replies.append($0) }
            )
            let first = try waitCoordinator.register(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .createPullRequest,
                startedAt: Date(timeIntervalSince1970: 1)
            )
            let second = try waitCoordinator.register(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .editPullRequest,
                startedAt: Date(timeIntervalSince1970: 2)
            )
            let later = waitCoordinator.applicationShouldTerminate() == .terminateLater
            _ = waitCoordinator.finish(first)
            _ = waitCoordinator.finish(second)
            let replied = await eventually { replies.values == [true] }

            let quitReplies = HarnessTerminationReplies()
            let quitCoordinator = ForgeMutationQuitCoordinator(
                persistence: persistence,
                choiceProvider: { _ in .quitAnyway },
                terminationReply: { quitReplies.append($0) }
            )
            _ = try quitCoordinator.register(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .syncFork,
                startedAt: Date(timeIntervalSince1970: 3)
            )
            let recording = quitCoordinator.applicationShouldTerminate() == .terminateLater
            let recorded = await eventually { quitReplies.values == [true] }
            let values = try await quitCoordinator.unknownOutcomes(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .syncFork
            )
            let consumed = try await quitCoordinator.consumeUnknownOutcomes(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .syncFork
            )
            let empty = try await persistence.consume(
                accountID: fixture.accountID,
                repository: fixture.repository,
                operation: .syncFork
            )
            let invalid = throwsExpected {
                _ = try ForgeInFlightMutation(
                    accountID: fixture.accountID,
                    repository: fixture.repository,
                    operation: .readPullRequests
                )
            }
            let proof = later && replied && recording && recorded
                && values.count == 1 && consumed == values && empty.isEmpty && invalid
            NSLog(
                "[M2ProductCoverage] quit later=%d replied=%d recording=%d recorded=%d values=%d consumed=%d empty=%d invalid=%d",
                later,
                replied,
                recording,
                recorded,
                values.count,
                consumed.count,
                empty.count,
                invalid
            )
            await database.close()
            try? FileManager.default.removeItem(at: directory)
            return proof
        }

        private static func milestone2LaunchHarnessProof(_ fixture: HarnessPullRequestFixture) async throws -> Bool {
            let local = try HarnessLocalRepository(remoteURL: "https://github.com/hbmartin/gitx.git")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let controller = HarnessWindowController(repository: local.repository, window: window)
            let staging = Milestone2UITestHarness.runProductProof(
                for: controller,
                environment: ["GITX_M2_SCENARIO": "existing-pull-request"]
            )
            guard await eventually({ window.attachedSheet != nil }),
                  let submit = descendant(
                      "GitX.PullRequest.Submit",
                      in: window.attachedSheet?.contentView
                  ) as? NSButton
            else { return false }
            submit.performClick(nil)
            let existingDestination = await eventually {
                window.attachedSheet == nil
            }

            let internalProof = await Milestone2UITestHarness.runInternalProductProof(for: controller)
            let checkoutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let checkoutController = HarnessWindowController(
                repository: local.repository,
                window: checkoutWindow
            )
            let checkout = Milestone2UITestHarness.runProductProof(
                for: checkoutController,
                environment: [
                    "GITX_M2_SCENARIO": "exact-checkout",
                    "GITX_M2_EXPECTED_HEAD": local.head,
                    "GITX_M2_CHECKOUT_REMOTE": "contributor",
                ]
            )
            let checkoutDestination = descendant(
                "GitX.M2.Harness.Ready.exact-checkout",
                in: checkoutWindow.contentView
            ) != nil

            let deepLinkWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            deepLinkWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            deepLinkWindow.makeKey()
            let deepLinkController = HarnessWindowController(
                repository: local.repository,
                window: deepLinkWindow
            )
            let deepLink = Milestone2UITestHarness.runProductProof(
                for: deepLinkController,
                environment: [
                    "GITX_M2_SCENARIO": "deep-link-no-checkout",
                    "GITX_M2_DEEP_LINK": "x-gitx://invalid",
                ]
            )
            let deepLinkReady = descendant(
                "GitX.M2.Harness.Ready.deep-link-no-checkout",
                in: deepLinkWindow.contentView
            ) != nil
            if let alert = deepLinkWindow.attachedSheet {
                deepLinkWindow.endSheet(alert, returnCode: .cancel)
            }
            let applicationRouter = ForgeDeepLinkApplicationRouter()
            let repositoryDestination = ForgeDestination.repository(fixture.repository)
            let deepLinkBranches = (0 ... 4).allSatisfy { scenario in
                let result = applicationRouter.runProductProof(
                    scenario: scenario,
                    destination: repositoryDestination,
                    controller: deepLinkController,
                    identity: fixture.repository
                )
                if let alert = deepLinkWindow.attachedSheet {
                    deepLinkWindow.endSheet(alert, returnCode: .cancel)
                }
                return result
            }
            let commitDestination = try ForgeDestination.commit(
                fixture.repository,
                ForgeCommitID(local.head)
            )
            _ = applicationRouter.runProductProof(
                scenario: 5,
                destination: commitDestination,
                controller: deepLinkController,
                identity: fixture.repository
            )
            deepLinkWindow.orderOut(nil)

            retainedObjects.append(staging)
            retainedObjects.append(checkout)
            retainedObjects.append(deepLink)
            retainedObjects.append(local)
            let marker = descendant(
                "GitX.M2.Harness.Ready.existing-pull-request",
                in: controller.window?.contentView
            )
            NSLog(
                "[M2ProductCoverage] launch marker=%d existing=%d internal=%d checkout=%d deepReady=%d branches=%d",
                marker != nil,
                existingDestination,
                internalProof,
                checkoutDestination,
                deepLinkReady,
                deepLinkBranches
            )
            return existingDestination && internalProof
                && checkoutDestination && deepLinkReady && deepLinkBranches
        }

        private static func descendant(_ identifier: String, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap { descendant(identifier, in: $0) }.first
        }

        private final class HarnessWindowController: PBGitWindowController {
            private var fixedRepository: PBGitRepository?

            init(repository: PBGitRepository, window: NSWindow?) {
                fixedRepository = repository
                super.init(window: window)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override var repository: PBGitRepository? {
                get { fixedRepository }
                set { fixedRepository = newValue }
            }
        }

        private final class HarnessDialogWindowController: PBGitWindowController {
            private(set) var confirmationCount = 0
            private(set) var errorCount = 0
            private(set) var cancellationCount = 0
            var beforeCancellation: (() -> Void)?

            override func showErrorSheet(_ error: any Error) {
                _ = error
                errorCount += 1
            }

            override func confirmDialog(
                _ alert: NSAlert,
                suppressionIdentifier identifier: String?,
                forAction actionBlock: @escaping () -> Void
            ) -> Bool {
                _ = identifier
                _ = actionBlock
                confirmationCount += 1
                return alert.buttons.first?.accessibilityIdentifier()
                    == "GitX.PullRequest.CheckoutConfirm"
            }

            override func confirmDialog(
                _ alert: NSAlert,
                suppressionIdentifier identifier: String?,
                onCancel: @escaping () -> Void,
                forAction actionBlock: @escaping () -> Void
            ) -> Bool {
                _ = alert
                _ = identifier
                _ = actionBlock
                cancellationCount += 1
                beforeCancellation?()
                onCancel()
                return false
            }
        }

        private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0 ..< 2000 {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return condition()
        }

        private static func bitProof(_ conditions: [Bool]) -> UInt64 {
            conditions.enumerated().reduce(into: UInt64(0)) { result, condition in
                if condition.element {
                    result |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        private static func throwsExpected(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }

        private static func throwsExpectedAsync(_ body: () async throws -> Void) async -> Bool {
            do { try await body(); return false } catch { return true }
        }

        private static func loggedProof(
            _ name: String,
            operation: () async throws -> Bool
        ) async -> Bool {
            do {
                return try await operation()
            } catch {
                NSLog(
                    "[M2ProductCoverage] %@ proof threw %@: %@",
                    name,
                    String(describing: type(of: error)),
                    error.localizedDescription
                )
                return false
            }
        }
    }

    // MARK: - Product-harness fixtures

    private struct HarnessPullRequestFixture {
        let repository: ForgeRepositoryIdentity
        let fork: ForgeRepositoryIdentity
        let accountID: ForgeAccountID
        let baseCommit: ForgeCommitID
        let headCommit: ForgeCommitID
        let base: ForgeBranchReference
        let head: ForgeBranchReference

        init() throws {
            let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
            repository = try ForgeRepositoryIdentity(forge: forge, owner: "gitx", name: "gitx")
            fork = try ForgeRepositoryIdentity(forge: forge, owner: "contributor", name: "gitx")
            accountID = try ForgeAccountID(forge: forge, value: "m2-product-proof")
            baseCommit = try ForgeCommitID(String(repeating: "1", count: 40))
            headCommit = try ForgeCommitID(String(repeating: "2", count: 40))
            base = try ForgeBranchReference(repository: repository, name: ForgeRefName("main"), commit: baseCommit)
            head = try ForgeBranchReference(repository: fork, name: ForgeRefName("feature"), commit: headCommit)
        }

        nonisolated func credentialReference() throws -> ForgeCredentialReference {
            try ForgeCredentialReference(
                accountID: accountID,
                credentialID: ForgeCredentialID("m2-proof-credential"),
                generation: ForgeCredentialGeneration(1)
            )
        }

        nonisolated func account() throws -> ForgeAccount {
            let reference = try credentialReference()
            return try ForgeAccount(
                id: accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: reference,
                    source: .fineGrainedPersonalAccessToken
                )
            )
        }

        func binding() throws -> ForgeRepositoryBinding {
            try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: repository,
                preferredAccount: accountID
            )
        }

        func forkBinding() throws -> ForgeRepositoryBinding {
            try ForgeRepositoryBinding(
                localRemoteName: "origin",
                primaryRepository: fork,
                preferredAccount: accountID
            )
        }

        func preparation(branchAlreadyPushed: Bool = true) throws -> RepositoryPullRequestCreationPreparation {
            try RepositoryPullRequestCreationPreparation(
                accountID: accountID,
                repository: repository,
                base: base,
                head: head,
                branchAlreadyPushed: branchAlreadyPushed,
                commitsOldestFirst: [ForgePullRequestCommitSummary(
                    id: headCommit,
                    subject: "Native PR",
                    body: "Product coverage proof"
                )]
            )
        }

        func editableSnapshot() throws -> ForgePullRequestEditableSnapshot {
            try ForgePullRequestEditableSnapshot(
                repository: repository,
                number: ForgeItemNumber(42),
                title: "Server title",
                bodyMarkdown: "Server body",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        }

        func checkoutPlan(addsRemote: Bool) throws -> ForgePullRequestCheckoutPlan {
            let remote = try ForgeGitRemote(
                name: "github-contributor",
                repository: fork,
                fetchURL: URL(string: "https://github.com/contributor/gitx.git")!
            )
            return try ForgePullRequestCheckoutPlan(
                repository: repository,
                pullRequest: ForgeItemNumber(42),
                remote: remote,
                fetchRefspec: "+refs/heads/feature:refs/remotes/github-contributor/feature",
                localBranch: ForgeRefName("pr-42-contributor"),
                expectedHead: headCommit,
                addsRemote: addsRemote
            )
        }

        func cloneCatalog() throws -> RepositoryForgeCloneCatalog {
            try RepositoryForgeCloneCatalog(
                accountID: accountID,
                accountDisplayName: "octocat",
                repositories: [RepositoryForgeCloneCatalog.Entry(repository: repository, relationship: .owned)]
            )
        }

        nonisolated func summary(
            headCommit: ForgeCommitID? = nil,
            headName: String = "feature"
        ) throws -> ForgePullRequestSummary {
            let head = try ForgeBranchReference(
                repository: fork,
                name: ForgeRefName(headName),
                commit: headCommit ?? self.headCommit
            )
            return try ForgePullRequestSummary(
                repository: repository,
                number: ForgeItemNumber(42),
                state: .open,
                isDraft: false,
                title: "Updated title",
                author: .unavailable(.notRequested),
                head: .available(head),
                base: .available(base),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 11),
                labels: .available([]),
                checkRollup: .available(.succeeded),
                reviewRollup: .available(.approved)
            )
        }

        func syncPlan() throws -> ForgeSyncForkPlan {
            try ForgeSyncForkPlan(
                fork: fork,
                parent: repository,
                branch: ForgeRefName("main"),
                localFetchRemoteName: "origin"
            )
        }

        func dependencies(_ behavior: HarnessMutationBehavior) throws -> HarnessDependencies {
            try HarnessDependencies(fixture: self, behavior: behavior)
        }
    }

    private enum HarnessMutationBehavior: Sendable {
        case created
        case existing
        case edited
        case sync(GitHubForkSyncMergeType)
        case failure(GitHubMutationError)
        case unknownCreateWithExistingRead
        case authoritativeCreateWithExistingRead
        case unknownEditMatchingRead

        static let syncBehaviors: [HarnessMutationBehavior] = [
            .sync(.fastForward), .sync(.merge), .sync(.none), .sync(.unknown),
        ]
    }

    private actor HarnessMutationAdapter: ForgeGitHubPullRequestMutationExecuting {
        let fixture: HarnessPullRequestFixture
        let behavior: HarnessMutationBehavior

        init(fixture: HarnessPullRequestFixture, behavior: HarnessMutationBehavior) {
            self.fixture = fixture
            self.behavior = behavior
        }

        func createPullRequest(
            accountID _: ForgeAccountID,
            form _: ForgePullRequestCreationForm,
            authorization _: GitHubMutationAuthorization
        ) async throws -> GitHubMutationResult<GitHubPullRequestCreationOutcome> {
            switch behavior {
            case .created: return try result(.created(value()))
            case .existing: return try result(.existing(value()))
            case let .failure(error): throw error
            case .unknownCreateWithExistingRead: throw GitHubMutationError.outcomeUnknown(nil)
            case .authoritativeCreateWithExistingRead:
                throw GitHubMutationError.authoritative(
                    [GitHubMutationProblem(authoritativeMessage: "already exists")], metadata()
                )
            default: throw GitHubMutationError.invalidRequest
            }
        }

        func editPullRequest(
            accountID _: ForgeAccountID,
            edit _: ForgePullRequestEdit,
            authorization _: GitHubMutationAuthorization
        ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
            switch behavior {
            case .edited: return try result(value())
            case .unknownEditMatchingRead: throw GitHubMutationError.outcomeUnknown(nil)
            case let .failure(error): throw error
            default: throw GitHubMutationError.invalidRequest
            }
        }

        func syncFork(
            accountID _: ForgeAccountID,
            plan _: ForgeSyncForkPlan,
            authorization _: GitHubMutationAuthorization
        ) async throws -> GitHubMutationResult<GitHubForkSyncReceipt> {
            switch behavior {
            case let .sync(mergeType):
                return try result(GitHubForkSyncReceipt(
                    fork: fixture.fork,
                    parent: fixture.repository,
                    branch: ForgeRefName("main"),
                    mergeType: mergeType
                ))
            case let .failure(error): throw error
            default: throw GitHubMutationError.invalidRequest
            }
        }

        private func value() throws -> GitHubPullRequestMutationValue {
            try GitHubPullRequestMutationValue(
                id: ForgeObjectID(forge: fixture.repository.forge, value: "PR_kwM2Proof"),
                repository: fixture.repository,
                number: ForgeItemNumber(42),
                state: .open,
                isDraft: false,
                title: "Updated title",
                bodyMarkdown: "Updated body",
                head: fixture.head,
                base: fixture.base,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 11),
                closedAt: nil,
                mergedAt: nil
            )
        }

        private func result<Value: Sendable>(_ value: Value) -> GitHubMutationResult<Value> {
            GitHubMutationResult(
                value: value,
                response: metadata(),
                ownership: GitHubMutationOwnership(
                    credential: try! fixture.credentialReference(),
                    repository: fixture.repository,
                    operation: operation
                )
            )
        }

        private var operation: ForgeOperation {
            switch behavior {
            case .edited, .unknownEditMatchingRead: .editPullRequest
            case .sync: .syncFork
            default: .createPullRequest
            }
        }

        private func metadata() -> GitHubResponseMetadata {
            GitHubResponseMetadata(
                statusCode: 200,
                rateLimit: GitHubRateLimitParser.parse(statusCode: 200, headers: [:], receivedAt: Date())
            )
        }
    }

    private actor HarnessReadAdapter: ForgeGitHubPullRequestReading {
        let fixture: HarnessPullRequestFixture

        init(fixture: HarnessPullRequestFixture) {
            self.fixture = fixture
        }

        func pullRequests(
            repository _: ForgeRepositoryIdentity,
            pageSize _: Int,
            after _: ForgePageCursor?,
            states _: Set<ForgePullRequestState>?
        ) async throws -> GitHubReadResult<ForgePage<ForgePullRequestSummary>> {
            try readResult(ForgePage(items: [fixture.summary()]))
        }

        func pullRequestDetails(
            repository _: ForgeRepositoryIdentity,
            number _: ForgeItemNumber,
            timelinePageSize _: Int,
            timelineAfter _: ForgePageCursor?,
            checkPageSize _: Int,
            checkAfter _: ForgePageCursor?
        ) async throws -> GitHubReadResult<ForgePullRequestDetailsPage> {
            let summary = try fixture.summary()
            let details = try ForgePullRequestDetails(
                summary: summary,
                bodyMarkdown: .available("Updated body"),
                assignees: .available([]),
                milestone: .available(nil),
                reviewers: .available([]),
                linkedIssues: .available([]),
                mergeability: .available(.mergeable),
                checks: .available([]),
                timeline: .available(ForgePage(items: []))
            )
            return try readResult(ForgePullRequestDetailsPage(details: details, nextCheckCursor: nil))
        }

        private func readResult<Value: Sendable>(
            _ value: Value
        ) throws -> GitHubReadResult<Value> {
            try GitHubReadResult(
                value: value,
                completeness: .complete,
                problems: [],
                response: GitHubResponseMetadata(
                    statusCode: 200,
                    rateLimit: GitHubRateLimitParser.parse(statusCode: 200, headers: [:], receivedAt: Date())
                ),
                ownership: GitHubReadOwnership(
                    credential: fixture.credentialReference(),
                    repository: fixture.repository
                )
            )
        }
    }

    private actor HarnessDependencies: ForgeGitHubPullRequestDependencyProviding {
        let fixture: HarnessPullRequestFixture
        let behavior: HarnessMutationBehavior
        let read: HarnessReadAdapter
        let mutation: HarnessMutationAdapter
        private(set) var successes = 0
        private(set) var failures = 0
        private(set) var capabilityRequests: [Set<ForgeOperation>] = []
        private(set) var capabilityAccountIDs: [ForgeAccountID] = []

        init(fixture: HarnessPullRequestFixture, behavior: HarnessMutationBehavior) throws {
            self.fixture = fixture
            self.behavior = behavior
            read = HarnessReadAdapter(fixture: fixture)
            mutation = HarnessMutationAdapter(fixture: fixture, behavior: behavior)
        }

        func preparationContext(
            accountID _: ForgeAccountID,
            repository _: ForgeRepositoryIdentity
        ) async throws -> ForgeGitHubPullRequestPreparationContext {
            try ForgeGitHubPullRequestPreparationContext(
                account: fixture.account(),
                facts: ForgeRepositoryFacts(
                    repository: fixture.repository,
                    defaultBranch: .available(ForgeRefName("main")),
                    description: .available("GitX"),
                    topics: .available([]),
                    visibility: .available(.public),
                    isArchived: .available(false),
                    forkRelationship: .available(.standalone)
                )
            )
        }

        func operationCapabilities(
            accountID: ForgeAccountID,
            repository: ForgeRepositoryIdentity,
            operations: Set<ForgeOperation>
        ) async throws -> [ForgeOperation: ForgeOperationCapability] {
            capabilityRequests.append(operations)
            capabilityAccountIDs.append(accountID)
            return Dictionary(uniqueKeysWithValues: operations.map { operation in
                (
                    operation,
                    .verified(.knownAuthority)
                )
            })
        }

        func mutationContext(
            accountID: ForgeAccountID,
            repository: ForgeRepositoryIdentity,
            operation: ForgeOperation
        ) async throws -> ForgeGitHubPullRequestMutationContext {
            let capabilities = try await operationCapabilities(
                accountID: accountID,
                repository: repository,
                operations: [operation]
            )
            guard let capability = capabilities[operation] else {
                throw ForgeGitHubPullRequestCompositionError.capabilityUnavailable(operation)
            }
            let key = try ForgeCapabilityKey(
                credential: fixture.credentialReference(),
                repository: repository,
                operation: operation
            )
            return try ForgeGitHubPullRequestMutationContext(
                account: fixture.account(),
                credential: fixture.credentialReference(),
                authorization: GitHubMutationAuthorization(
                    key: key,
                    capability: capability
                ),
                readAdapter: read,
                mutationAdapter: mutation
            )
        }

        func recordSuccess(
            _: GitHubResponseMetadata,
            context _: ForgeGitHubPullRequestMutationContext
        ) async {
            successes += 1
        }

        func recordFailure(
            _: GitHubMutationError,
            context _: ForgeGitHubPullRequestMutationContext
        ) async {
            failures += 1
        }
    }

    private struct HarnessLocalPreparation: RepositoryPullRequestLocalPreparationProviding {
        let preparation: RepositoryPullRequestCreationPreparation

        func preparation(
            accountID _: ForgeAccountID,
            binding _: ForgeRepositoryBinding,
            localBranch _: ForgeRefName,
            localHead _: ForgeCommitID,
            defaultBranch _: ForgeRefName
        ) async throws -> RepositoryPullRequestCreationPreparation {
            preparation
        }
    }

    // swift6-safety-justification: Immutable fixtures are Sendable and the lock serializes command recording.
    private final class HarnessGitRunner: RepositoryPullRequestGitCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private let head: String
        private let status: String
        private let existingRefspec: String?
        private let failsFetch: Bool
        private(set) var commands: [[String]] = []

        init(
            head: String,
            status: String = "",
            existingRefspec: String? = nil,
            failsFetch: Bool = false
        ) {
            self.head = head
            self.status = status
            self.existingRefspec = existingRefspec
            self.failsFetch = failsFetch
        }

        func run(_ arguments: [String]) throws -> String {
            lock.lock(); commands.append(arguments); lock.unlock()
            if arguments == ["status", "--porcelain=v2", "--untracked-files=normal"] {
                return status
            }
            if arguments.first == "fetch", failsFetch {
                throw HarnessError.expected
            }
            if arguments.starts(with: ["rev-parse", "--verify", "--quiet"]) {
                throw HarnessError.expected
            }
            if arguments.starts(with: ["config", "--get-all"]) {
                return existingRefspec ?? ""
            }
            if arguments.starts(with: ["rev-parse", "--verify"]) {
                return head
            }
            return ""
        }
    }

    // swift6-safety-justification: The app-hosted harness confines repository mutation to its main-actor proofs.
    private final class HarnessLocalRepository: NSObject, @unchecked Sendable {
        static let empty = try! HarnessLocalRepository(remoteURL: "https://github.com/hbmartin/gitx.git").repository

        let directory: URL
        let repository: PBGitRepository
        let head: String

        init(remoteURL: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitX-M2-Product-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try Self.git(["init", "--quiet", "--initial-branch=main"], in: directory)
            _ = try Self.git(["config", "user.name", "GitX Tests"], in: directory)
            _ = try Self.git(["config", "user.email", "gitx-tests@example.invalid"], in: directory)
            try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
            _ = try Self.git(["add", "tracked.txt"], in: directory)
            _ = try Self.git(["commit", "--quiet", "-m", "Fixture"], in: directory)
            _ = try Self.git(["remote", "add", "origin", remoteURL], in: directory)
            head = try Self.git(["rev-parse", "HEAD"], in: directory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            repository = try PBGitRepository(url: directory)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        private static func git(_ arguments: [String], in directory: URL) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw HarnessError.expected }
            return output
        }
    }

    private struct HarnessSyncService: RepositoryPullRequestMutationServing {
        func capabilities(
            accountID _: ForgeAccountID,
            repository _: ForgeRepositoryIdentity,
            operations: Set<ForgeOperation>
        ) async throws -> [ForgeOperation: ForgeOperationCapability] {
            Dictionary(uniqueKeysWithValues: operations.map { ($0, .verified(.knownAuthority)) })
        }

        func prepareCreation(
            repository _: ForgeRepositoryIdentity,
            localBranch _: ForgeRefName,
            localHead _: ForgeCommitID
        ) async throws -> RepositoryPullRequestCreationPreparation {
            throw HarnessError.expected
        }

        func createPullRequest(
            accountID _: ForgeAccountID,
            form _: ForgePullRequestCreationForm
        ) async throws -> RepositoryPullRequestCreationOutcome {
            throw HarnessError.expected
        }

        func editPullRequest(
            accountID _: ForgeAccountID,
            edit _: ForgePullRequestEdit
        ) async throws -> RepositoryPullRequestEditOutcome {
            throw HarnessError.expected
        }

        func syncFork(
            accountID _: ForgeAccountID,
            plan: ForgeSyncForkPlan
        ) async throws -> RepositorySyncForkOutcome {
            RepositorySyncForkOutcome(plan: plan, serverSummary: "Fork updated")
        }
    }

    private actor HarnessDraftStore: RepositoryPullRequestDraftPersisting {
        private(set) var saveCount = 0
        private(set) var deleteCount = 0
        func load(identity _: ForgeDraftIdentity) async throws -> ForgeDraft? {
            nil
        }

        func save(identity _: ForgeDraftIdentity, content _: ForgeDraftContent, at _: Date) async throws {
            saveCount += 1
        }

        func delete(identity _: ForgeDraftIdentity) async throws {
            deleteCount += 1
        }
    }

    @MainActor
    private final class HarnessRemoteActions: RepositoryRemoteActionCoordinating {
        struct Invocation {
            let branch: PBGitRef?
            let remote: PBGitRef?
            let requiresConfirmation: Bool
            let option: RepositoryPullRequestPushOption?
            let offer: RepositoryPullRequestPushOffer?
            let suppressesPostPushBrowserSuggestion: Bool
        }

        private let events: [RepositoryPushEvent]
        private(set) var recordedInvocations: [Invocation] = []
        var invocations: Int {
            recordedInvocations.count
        }

        init(events: [RepositoryPushEvent]) {
            self.events = events
        }

        func performPush(
            branch: PBGitRef?,
            remote: PBGitRef?,
            requiresConfirmation: Bool,
            pullRequestOption: RepositoryPullRequestPushOption?,
            pullRequestOffer: RepositoryPullRequestPushOffer?,
            suppressesPostPushBrowserSuggestion: Bool,
            completion: ((RepositoryPushEvent) -> Void)?
        ) {
            recordedInvocations.append(Invocation(
                branch: branch,
                remote: remote,
                requiresConfirmation: requiresConfirmation,
                option: pullRequestOption,
                offer: pullRequestOffer,
                suppressesPostPushBrowserSuggestion: suppressesPostPushBrowserSuggestion
            ))
            events.forEach { completion?($0) }
        }
    }

    private actor HarnessUIService: RepositoryPullRequestMutationServing {
        let fixture: HarnessPullRequestFixture
        let preparation: RepositoryPullRequestCreationPreparation
        init(fixture: HarnessPullRequestFixture, preparation: RepositoryPullRequestCreationPreparation) {
            self.fixture = fixture
            self.preparation = preparation
        }

        func capabilities(
            accountID _: ForgeAccountID,
            repository _: ForgeRepositoryIdentity,
            operations: Set<ForgeOperation>
        ) async throws -> [ForgeOperation: ForgeOperationCapability] {
            Dictionary(uniqueKeysWithValues: operations.map { ($0, .verified(.knownAuthority)) })
        }

        func prepareCreation(
            repository _: ForgeRepositoryIdentity,
            localBranch _: ForgeRefName,
            localHead _: ForgeCommitID
        ) async throws -> RepositoryPullRequestCreationPreparation {
            preparation
        }

        func createPullRequest(
            accountID _: ForgeAccountID,
            form _: ForgePullRequestCreationForm
        ) async throws -> RepositoryPullRequestCreationOutcome {
            try .created(.pullRequest(fixture.repository, ForgeItemNumber(42)))
        }

        func editPullRequest(
            accountID _: ForgeAccountID,
            edit: ForgePullRequestEdit
        ) async throws -> RepositoryPullRequestEditOutcome {
            try RepositoryPullRequestEditOutcome(
                snapshot: ForgePullRequestEditableSnapshot(
                    repository: fixture.repository,
                    number: edit.number,
                    title: edit.title,
                    bodyMarkdown: edit.bodyMarkdown,
                    updatedAt: Date(timeIntervalSince1970: 12)
                ),
                destination: .pullRequest(fixture.repository, edit.number)
            )
        }

        func syncFork(
            accountID _: ForgeAccountID,
            plan: ForgeSyncForkPlan
        ) async throws -> RepositorySyncForkOutcome {
            RepositorySyncForkOutcome(plan: plan, serverSummary: "Fork updated")
        }
    }

    @MainActor
    // swift6-safety-justification: MainActor isolation protects every access to the mutable reply collection.
    private final class HarnessTerminationReplies: @unchecked Sendable {
        private(set) var values: [Bool] = []
        func append(_ value: Bool) {
            values.append(value)
        }
    }

    private enum HarnessError: Error { case expected }
#endif
