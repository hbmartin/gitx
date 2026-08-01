import AppKit
import ForgeKit
import GitHubForgeAdapter
import XCTest

final class RepositoryPullRequestWorkflowAppTests: XCTestCase {
    func testPostPushBrowserSuggestionRequiresUnavailableNativeCreationAndPreservesUncheckedSilence() {
        XCTAssertTrue(RepositoryPostPushBrowserSuggestionPolicy.shouldOpen(
            nativeCreationWasAvailable: false,
            explicitlySuppressed: false
        ))
        XCTAssertFalse(
            RepositoryPostPushBrowserSuggestionPolicy.shouldOpen(
                nativeCreationWasAvailable: true,
                explicitlySuppressed: false
            ),
            "Availability suppresses the legacy side effect even when the native checkbox is unchecked"
        )
        XCTAssertFalse(RepositoryPostPushBrowserSuggestionPolicy.shouldOpen(
            nativeCreationWasAvailable: false,
            explicitlySuppressed: true
        ))
    }

    func testUnavailableMutationServiceFailsClosedForEveryOperation() async throws {
        let fixture = try PullRequestAppFixture()
        let service = UnavailableRepositoryPullRequestMutationService()
        let operations: Set<ForgeOperation> = [
            .createPullRequest,
            .editPullRequest,
            .syncFork,
        ]
        let capabilities = try await service.capabilities(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operations: operations
        )
        XCTAssertEqual(
            capabilities,
            Dictionary(uniqueKeysWithValues: operations.map {
                ($0, .unavailable(.unsupportedProviderOperation))
            })
        )

        let preparationError = await capturedError {
            try await service.prepareCreation(
                repository: fixture.repository,
                localBranch: fixture.head.name,
                localHead: fixture.head.commit
            )
        }
        let createError = await capturedError {
            try await service.createPullRequest(
                accountID: fixture.accountID,
                form: XCTUnwrap(fixture.preparation().initialForms().forms.first)
            )
        }
        let editError = await capturedError {
            try await service.editPullRequest(
                accountID: fixture.accountID,
                edit: ForgePullRequestEdit(
                    snapshot: ForgePullRequestEditableSnapshot(
                        repository: fixture.repository,
                        number: ForgeItemNumber(42),
                        title: "Server title",
                        bodyMarkdown: "Server body",
                        updatedAt: Date(timeIntervalSince1970: 1)
                    ),
                    title: "Unavailable",
                    bodyMarkdown: "Unavailable"
                )
            )
        }
        let syncError = await capturedError {
            try await service.syncFork(
                accountID: fixture.accountID,
                plan: ForgeSyncForkPlan(
                    fork: fixture.fork,
                    parent: fixture.repository,
                    branch: fixture.base.name,
                    localFetchRemoteName: "origin"
                )
            )
        }
        for error in [preparationError, createError, editError, syncError] {
            XCTAssertEqual(error as? RepositoryPullRequestServiceError, .nativeCreationUnavailable)
        }
    }

    func testPushProgressStartPolicyTerminatesFailedPresentationWithoutClosingSuccessfulStart() {
        XCTAssertEqual(RepositoryPushProgressStartPolicy.terminalEvent(didStart: false), .failed)
        XCTAssertNil(RepositoryPushProgressStartPolicy.terminalEvent(didStart: true))
    }

    func testRejectedPushContextUsesOneValidTerminalFailureTransition() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation(branchAlreadyPushed: false)
        let form = try XCTUnwrap(preparation.initialForms().forms.first)
        let intent = try ForgePushPullRequestIntent(
            form: form,
            draftIdentity: RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        )
        let events = RepositoryPushProgressStartPolicy.rejectedEvents(
            createPullRequestSelected: true
        )
        XCTAssertEqual(events, [.began(createPullRequestSelected: true), .failed])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)

        var flow = RepositoryPullRequestPushFlow()
        try flow.beginOrdinaryPush(intent: intent)
        for event in events {
            switch event {
            case let .began(selected):
                try flow.pushBegan(createPullRequestSelected: selected)
            case .failed:
                try flow.pushFailed()
            case .succeeded:
                try flow.pushSucceeded()
            case .cancelled:
                try flow.pushCancelled()
            }
        }
        XCTAssertEqual(flow.state, .draftPreserved(intent))
    }

    func testApplicationPushFlowRejectsOverlappingIntentWithoutCrossPairing() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation(branchAlreadyPushed: false)
        let firstForm = try XCTUnwrap(preparation.initialForms().forms.first)
        let secondForm = try firstForm.editing(
            title: "Second Pull Request",
            bodyMarkdown: firstForm.bodyMarkdown,
            isDraft: firstForm.isDraft
        )
        let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        let first = try ForgePushPullRequestIntent(form: firstForm, draftIdentity: identity)
        let second = try ForgePushPullRequestIntent(form: secondForm, draftIdentity: identity)
        var flow = RepositoryPullRequestPushFlow()

        try flow.beginOrdinaryPush(intent: first)
        try flow.pushBegan(createPullRequestSelected: true)
        let pushingFirst = flow.state
        XCTAssertThrowsError(try flow.beginOrdinaryPush(intent: second)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTransition)
        }
        XCTAssertEqual(flow.state, pushingFirst)

        try flow.pushSucceeded()
        XCTAssertEqual(flow.createSheetIntent, first)
        XCTAssertThrowsError(try flow.beginNewPullRequest(branchAlreadyPushed: true, intent: second)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTransition)
        }
        XCTAssertEqual(flow.createSheetIntent, first)
    }

    func testPreparationCacheRequiresExactFreshRemoteBindingAccountBranchAndHead() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation()
        let form = try XCTUnwrap(preparation.initialForms().forms.first)
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let key = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: preparation.head.name,
            localHead: preparation.head.commit,
            effectiveRemoteName: "origin",
            effectiveRemoteRepository: preparation.head.repository
        ))
        let expiration = Date(timeIntervalSince1970: 200)
        let cache = RepositoryPullRequestPreparationCache(
            key: key,
            preparation: preparation,
            initialForm: form,
            expiresAt: expiration
        )
        XCTAssertTrue(cache.isExact(for: key, now: Date(timeIntervalSince1970: 199)))
        XCTAssertFalse(cache.isExact(for: key, now: expiration))

        var store = RepositoryPullRequestPreparationCacheStore()
        store.replace(with: cache)
        XCTAssertEqual(
            store.takeExact(for: key, now: Date(timeIntervalSince1970: 199)),
            cache
        )
        XCTAssertNil(store.takeExact(for: key, now: Date(timeIntervalSince1970: 199)))
        store.replace(with: cache)
        XCTAssertNil(store.takeExact(for: key, now: expiration))
        store.replace(with: cache)
        XCTAssertEqual(
            store.takeExact(for: key, now: Date(timeIntervalSince1970: 199)),
            cache
        )

        let differentRemote = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: preparation.head.name,
            localHead: preparation.head.commit,
            effectiveRemoteName: "upstream",
            effectiveRemoteRepository: fixture.repository
        ))
        XCTAssertFalse(cache.isExact(for: differentRemote, now: Date(timeIntervalSince1970: 199)))
        store.replace(with: cache)
        XCTAssertNil(store.takeExact(for: differentRemote, now: Date(timeIntervalSince1970: 199)))
        XCTAssertNil(store.takeExact(for: key, now: Date(timeIntervalSince1970: 199)))

        let otherAccount = try ForgeAccountID(forge: fixture.accountID.forge, value: "other")
        let otherBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: otherAccount
        )
        let differentAccount = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: otherBinding,
            branch: preparation.head.name,
            localHead: preparation.head.commit,
            effectiveRemoteName: "origin",
            effectiveRemoteRepository: preparation.head.repository
        ))
        XCTAssertFalse(cache.isExact(for: differentAccount, now: Date(timeIntervalSince1970: 199)))

        let differentHead = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: preparation.head.name,
            localHead: fixture.baseCommit,
            effectiveRemoteName: "origin",
            effectiveRemoteRepository: preparation.head.repository
        ))
        XCTAssertFalse(cache.isExact(for: differentHead, now: Date(timeIntervalSince1970: 199)))

        let accountlessBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository
        )
        XCTAssertNil(RepositoryPullRequestPreparationCacheKey(
            binding: accountlessBinding,
            branch: preparation.head.name,
            localHead: preparation.head.commit,
            effectiveRemoteName: "origin",
            effectiveRemoteRepository: preparation.head.repository
        ))
    }

    func testUntrackedPushUsesBoundRemoteWhileExplicitAndTrackingRemotesWin() {
        let untrackedRemoteName = RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: nil,
            branchPushRemoteName: nil,
            defaultPushRemoteName: nil,
            trackingRemoteName: nil,
            boundRemoteName: "origin"
        )
        XCTAssertEqual(untrackedRemoteName, "origin")
        let untrackedRemote = PBGitRef(string: kGitXRemoteRefPrefix + (untrackedRemoteName ?? ""))
        XCTAssertTrue(untrackedRemote.isRemote)
        XCTAssertEqual(untrackedRemote.remoteName, "origin")
        XCTAssertEqual(RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: nil,
            branchPushRemoteName: nil,
            defaultPushRemoteName: nil,
            trackingRemoteName: "fork",
            boundRemoteName: "origin"
        ), "fork")
        XCTAssertEqual(RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: "review",
            branchPushRemoteName: "push-remote",
            defaultPushRemoteName: "default-push",
            trackingRemoteName: "fork",
            boundRemoteName: "origin"
        ), "review")
        XCTAssertEqual(RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: nil,
            branchPushRemoteName: "push-remote",
            defaultPushRemoteName: "default-push",
            trackingRemoteName: "fork",
            boundRemoteName: "origin"
        ), "push-remote")
        XCTAssertEqual(RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: nil,
            branchPushRemoteName: nil,
            defaultPushRemoteName: "default-push",
            trackingRemoteName: "fork",
            boundRemoteName: "origin"
        ), "default-push")

        XCTAssertEqual(
            RepositoryPullRequestPushRemotePolicy.pushURLArguments(remoteName: "fork"),
            ["remote", "get-url", "--push", "--all", "fork"]
        )
        XCTAssertEqual(
            RepositoryPullRequestPushRemotePolicy.pushRepository(
                rawURLs: "git@github.com:contributor/repo.git\nhttps://github.com/contributor/repo.git\n"
            )?.owner,
            "contributor"
        )
        XCTAssertNil(RepositoryPullRequestPushRemotePolicy.pushRepository(
            rawURLs: "https://github.com/contributor/repo.git\nhttps://github.com/other/repo.git\n"
        ))
        XCTAssertNil(RepositoryPullRequestPushRemotePolicy.pushRepository(
            rawURLs: "https://github.com/contributor/repo.git\nnot a Forge remote\n"
        ))
        XCTAssertNil(RepositoryPullRequestPushRemotePolicy.pushRepository(rawURLs: "\n"))
    }

    func testWindowlessConfirmationCancelsExactlyOnceWithoutActing() {
        var cancellationCount = 0

        let didAct = WindowDialogPresentationPolicy.cancelWithoutPresentation(
            onCancel: { cancellationCount += 1 }
        )

        XCTAssertFalse(didAct)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testApplicationPushFlowPreservesExactIntentAcrossFailureAndReopen() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation(branchAlreadyPushed: false)
        let form = try XCTUnwrap(preparation.initialForms().forms.first)
        let intent = try ForgePushPullRequestIntent(
            form: form,
            draftIdentity: RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        )
        var flow = RepositoryPullRequestPushFlow()

        try flow.beginNewPullRequest(branchAlreadyPushed: false, intent: intent)
        XCTAssertEqual(flow.state, .pushSheet(createPullRequestSelected: true, intent: intent))
        try flow.pushBegan(createPullRequestSelected: true)
        try flow.pushFailed()
        XCTAssertEqual(flow.preservedIntent, intent)

        try flow.beginNewPullRequest(branchAlreadyPushed: true, intent: intent)
        XCTAssertEqual(flow.createSheetIntent, intent)
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
        try flow.existingPullRequest(destination)
        XCTAssertEqual(flow.state, .completed(destination))
    }

    func testPreparationUsesCommitHeuristicsAndRestoredDraftAlwaysResetsDraftFlag() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try RepositoryPullRequestCreationPreparation(
            accountID: fixture.accountID,
            repository: fixture.repository,
            base: fixture.base,
            head: fixture.head,
            branchAlreadyPushed: true,
            commitsOldestFirst: [ForgePullRequestCommitSummary(
                id: fixture.headCommit,
                subject: "Native creation",
                body: "Keep local Git authoritative"
            )]
        )
        let initial = try XCTUnwrap(preparation.initialForms().forms.first)
        XCTAssertEqual(initial.title, "Native creation")
        XCTAssertFalse(initial.isDraft)

        let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        let draft = try ForgeDraft(
            identity: identity,
            content: ForgeDraftContent(title: "Saved title", body: "Saved body"),
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivityAt: Date(timeIntervalSince1970: 2)
        )
        let restored = try RepositoryPullRequestDraftPolicy.restoredForm(
            preparation: preparation,
            initial: initial.editing(title: initial.title, bodyMarkdown: initial.bodyMarkdown, isDraft: true),
            draft: draft
        )
        XCTAssertEqual(restored.title, "Saved title")
        XCTAssertEqual(restored.bodyMarkdown, "Saved body")
        XCTAssertFalse(restored.isDraft)
    }

    func testEditDraftIdentityIsExactAndRestoresTitleAndBody() throws {
        let fixture = try PullRequestAppFixture()
        let number = try ForgeItemNumber(42)
        let snapshot = try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: number,
            title: "Server title",
            bodyMarkdown: "Server body",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let identity = try RepositoryPullRequestDraftPolicy.editIdentity(
            accountID: fixture.accountID,
            snapshot: snapshot
        )
        XCTAssertEqual(
            identity.destination,
            .pullRequest(repository: fixture.repository, number: number)
        )
        let draft = try ForgeDraft(
            identity: identity,
            content: ForgeDraftContent(title: "Draft title", body: "Draft body"),
            createdAt: Date(timeIntervalSince1970: 2),
            lastActivityAt: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(
            RepositoryPullRequestDraftPolicy.restoredEditContent(snapshot: snapshot, draft: draft),
            ForgeDraftContent(title: "Draft title", body: "Draft body")
        )
    }

    func testCheckoutExecutorRechecksSafetyFetchesExactRefAndCreatesNamedBranchBeforeSwitch() throws {
        let fixture = try PullRequestAppFixture()
        let runner = RecordingPullRequestGitRunner(head: fixture.headCommit.value)
        let plan = try fixture.checkoutPlan(addsRemote: true)

        let receipt = try RepositoryPullRequestCheckoutExecutor(runner: runner).execute(plan)

        XCTAssertEqual(receipt.localBranch, plan.localBranch)
        XCTAssertEqual(receipt.fetchedHead, fixture.headCommit)
        XCTAssertEqual(runner.commands.prefix(2).map { $0 }, [
            ["status", "--porcelain=v2", "--untracked-files=normal"],
            ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"],
        ])
        XCTAssertTrue(runner.commands.contains(["fetch", "--no-tags", "github-contributor", plan.fetchRefspec]))
        let branchIndex = try XCTUnwrap(runner.commands.firstIndex(of: [
            "branch", plan.localBranch.value, fixture.headCommit.value,
        ]))
        let switchIndex = try XCTUnwrap(runner.commands.firstIndex(of: ["switch", plan.localBranch.value]))
        XCTAssertLessThan(branchIndex, switchIndex)
    }

    func testCheckoutExecutorStopsBeforeMutationForDirtyOrInProgressRepository() throws {
        let fixture = try PullRequestAppFixture()
        let dirty = RecordingPullRequestGitRunner(head: fixture.headCommit.value, status: "? untracked")
        XCTAssertThrowsError(try RepositoryPullRequestCheckoutExecutor(runner: dirty).execute(
            fixture.checkoutPlan(addsRemote: true)
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsafeWorkingState)
        }
        XCTAssertFalse(dirty.commands.contains { $0.first == "remote" || $0.first == "fetch" })

        let merging = RecordingPullRequestGitRunner(
            head: fixture.headCommit.value,
            activeOperation: "MERGE_HEAD"
        )
        XCTAssertThrowsError(try RepositoryPullRequestCheckoutExecutor(runner: merging).execute(
            fixture.checkoutPlan(addsRemote: false)
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsafeWorkingState)
        }
        XCTAssertFalse(merging.commands.contains { $0.first == "fetch" })
    }

    func testCloneCatalogExcludesStarredAndURLChoiceIsExact() throws {
        let fixture = try PullRequestAppFixture()
        XCTAssertThrowsError(try RepositoryForgeCloneCatalog.Entry(
            repository: fixture.repository,
            relationship: .starred
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsupportedRepositoryRelationship)
        }
        let organization = try RepositoryForgeCloneCatalog.Entry(
            repository: fixture.repository,
            relationship: .organization
        )
        let ownedRepository = try ForgeRepositoryIdentity(
            forge: fixture.repository.forge,
            owner: "account",
            name: "aardvark"
        )
        let owned = try RepositoryForgeCloneCatalog.Entry(repository: ownedRepository, relationship: .owned)
        let catalog = try RepositoryForgeCloneCatalog(
            accountID: fixture.accountID,
            accountDisplayName: "account",
            repositories: [organization, owned]
        )
        XCTAssertEqual(catalog.repositories.map(\.repository.name), ["aardvark", "gitx"])

        let ssh = try ForgeCloneRequest(
            accountID: fixture.accountID,
            repository: fixture.repository,
            relationship: .organization,
            transport: .ssh
        )
        let https = try ForgeCloneRequest(
            accountID: fixture.accountID,
            repository: fixture.repository,
            relationship: .organization,
            transport: .https
        )
        XCTAssertEqual(try RepositoryForgeCloneURLPolicy.url(for: ssh).absoluteString, "ssh://git@github.com/gitx/gitx.git")
        XCTAssertEqual(try RepositoryForgeCloneURLPolicy.url(for: https).absoluteString, "https://github.com/gitx/gitx.git")
    }

    func testSyncForkRunsServerMutationThenFetchesExactBoundForkBranch() async throws {
        let fixture = try PullRequestAppFixture()
        let plan = try ForgeSyncForkPlan(
            fork: fixture.fork,
            parent: fixture.repository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: "origin"
        )
        let runner = RecordingPullRequestGitRunner(head: fixture.headCommit.value)
        let receipt = try await RepositorySyncForkCoordinator(
            service: StubPullRequestMutationService(),
            runner: runner
        ).sync(accountID: fixture.accountID, plan: plan)

        XCTAssertEqual(receipt.serverSummary, "Fork updated")
        XCTAssertEqual(receipt.fetchedRemote, "origin")
        XCTAssertEqual(runner.commands, [[
            "fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main",
        ]])

        let failingRunner = RecordingPullRequestGitRunner(head: fixture.headCommit.value, failsFetch: true)
        do {
            _ = try await RepositorySyncForkCoordinator(
                service: StubPullRequestMutationService(),
                runner: failingRunner
            ).sync(accountID: fixture.accountID, plan: plan)
            XCTFail("Expected the completed-server/local-fetch split to remain visible")
        } catch {
            XCTAssertEqual(error as? RepositorySyncForkError, .localFetchFailed(serverSummary: "Fork updated"))
        }
    }
}

private func capturedError<T>(
    _ operation: () async throws -> T
) async -> Error? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

@MainActor
private struct CachedPushContext {
    let repositoryFixture: LocalPullRequestRepositoryFixture
    let binding: ForgeRepositoryBinding
    let branch: PBGitRef
    let cache: RepositoryPullRequestPreparationCache
}

@MainActor
private func makeCachedPushContext(fixture: PullRequestAppFixture) throws -> CachedPushContext {
    let repositoryFixture = try LocalPullRequestRepositoryFixture(
        remoteURL: "git@github.com:contributor/gitx.git"
    )
    do {
        let branch = try XCTUnwrap(repositoryFixture.repository.headRef()?.ref())
        let branchName = try ForgeRefName(branch.shortName())
        let localHead = try ForgeCommitID(repositoryFixture.repository.outputOfTask(withArguments: [
            "rev-parse", branch.ref,
        ]).trimmingCharacters(in: .whitespacesAndNewlines))
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let head = ForgeBranchReference(
            repository: fixture.fork,
            name: branchName,
            commit: localHead
        )
        let preparation = try RepositoryPullRequestCreationPreparation(
            accountID: fixture.accountID,
            repository: fixture.repository,
            base: fixture.base,
            head: head,
            branchAlreadyPushed: false,
            commitsOldestFirst: [
                ForgePullRequestCommitSummary(id: localHead, subject: "Cached native PR"),
            ]
        )
        let initialForm = try XCTUnwrap(preparation.initialForms().forms.first)
        let key = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: branchName,
            localHead: localHead,
            effectiveRemoteName: "origin",
            effectiveRemoteRepository: fixture.fork
        ))
        return CachedPushContext(
            repositoryFixture: repositoryFixture,
            binding: binding,
            branch: branch,
            cache: RepositoryPullRequestPreparationCache(
                key: key,
                preparation: preparation,
                initialForm: initialForm,
                expiresAt: .distantFuture
            )
        )
    } catch {
        repositoryFixture.cleanup()
        throw error
    }
}

private func unverifiedCreateCapability(
    fixture: PullRequestAppFixture
) throws -> ForgeOperationCapability {
    let credential = try ForgeCredentialReference(
        accountID: fixture.accountID,
        credentialID: ForgeCredentialID("rotated-fine-grained-token"),
        generation: ForgeCredentialGeneration(2)
    )
    let account = try ForgeAccount(
        id: fixture.accountID,
        login: "octocat",
        currentCredential: ForgeCredentialMetadata(
            reference: credential,
            source: .fineGrainedPersonalAccessToken
        )
    )
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
    return ForgeCapabilityEvaluator.capability(
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
}

@MainActor
final class RepositoryPullRequestUIControllerAppTests: XCTestCase {
    func testPublicModeOrdinaryPushNeverOffersCachedNativeCreation() async throws {
        let fixture = try PullRequestAppFixture()
        let service = CapabilityOnlyMutationService(
            capability: .verified(.knownAuthority)
        )
        let context = try makeCachedPushContext(fixture: fixture)
        defer { context.repositoryFixture.cleanup() }
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: context.repositoryFixture.repository,
            windowController: PBGitWindowController(window: NSWindow()),
            remoteActions: remoteActions,
            service: service,
            destinationOpening: { _ in false },
            bindingResolving: { context.binding },
            postPushBrowserFallback: { _ in XCTFail("The recording coordinator owns fallback reporting") },
            createPullRequestControlResolving: {
                .publicReadOnly(action: "create a Pull Request")
            }
        )
        controller.installUITestOrdinaryPushPreparationCache(context.cache)

        controller.performPush(
            branch: context.branch,
            remote: nil,
            requiresConfirmation: true,
            initiallyCreatePullRequest: true
        )

        let invocation = try XCTUnwrap(remoteActions.invocations.first)
        XCTAssertNil(invocation.option)
        XCTAssertNil(invocation.offer)
        XCTAssertFalse(invocation.suppressesPostPushBrowserSuggestion)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCachedPreparationRechecksExactCapabilityAfterCredentialRotation() async throws {
        let fixture = try PullRequestAppFixture()
        let service = CapabilityOnlyMutationService(
            capability: .unavailable(.mismatchedCredentialEvidence)
        )
        let context = try makeCachedPushContext(fixture: fixture)
        defer { context.repositoryFixture.cleanup() }
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: context.repositoryFixture.repository,
            windowController: PBGitWindowController(window: NSWindow()),
            remoteActions: remoteActions,
            service: service,
            destinationOpening: { _ in false },
            bindingResolving: { context.binding },
            postPushBrowserFallback: { _ in XCTFail("The recording coordinator owns fallback reporting") }
        )
        controller.installUITestOrdinaryPushPreparationCache(context.cache)

        controller.performPush(
            branch: context.branch,
            remote: nil,
            requiresConfirmation: true,
            initiallyCreatePullRequest: true
        )

        let invocation = try XCTUnwrap(remoteActions.invocations.first)
        let offer = try XCTUnwrap(invocation.offer)
        XCTAssertNil(invocation.option)
        XCTAssertFalse(offer.presentation.isEnabled)
        XCTAssertTrue(try XCTUnwrap(offer.presentation.helpText).contains("Checking"))
        let rotationWasRejected = await eventually {
            offer.presentation.helpText?.contains("exact GitHub account and repository authority") == true
        }
        XCTAssertTrue(rotationWasRejected)
        XCTAssertFalse(offer.presentation.isEnabled)
        XCTAssertFalse(invocation.suppressesPostPushBrowserSuggestion)
        let requests = await service.requests
        XCTAssertEqual(requests, [CapabilityOnlyMutationService.Request(
            accountID: fixture.accountID,
            repository: fixture.repository,
            operations: [.createPullRequest]
        )])
    }

    func testCachedPreparationUnavailableCapabilityKeepsOfferDisabledAndFallbackEligible() async throws {
        let fixture = try PullRequestAppFixture()
        let service = CapabilityOnlyMutationService(
            capability: .unavailable(.knownOperationRestriction)
        )
        let context = try makeCachedPushContext(fixture: fixture)
        defer { context.repositoryFixture.cleanup() }
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: context.repositoryFixture.repository,
            windowController: PBGitWindowController(window: NSWindow()),
            remoteActions: remoteActions,
            service: service,
            destinationOpening: { _ in false },
            bindingResolving: { context.binding },
            postPushBrowserFallback: { _ in XCTFail("The recording coordinator owns fallback reporting") }
        )
        controller.installUITestOrdinaryPushPreparationCache(context.cache)

        controller.performPush(
            branch: context.branch,
            remote: nil,
            requiresConfirmation: true,
            initiallyCreatePullRequest: true
        )

        let invocation = try XCTUnwrap(remoteActions.invocations.first)
        let offer = try XCTUnwrap(invocation.offer)
        let restrictionBecameVisible = await eventually {
            offer.presentation.helpText?.contains("does not currently allow") == true
        }
        XCTAssertTrue(restrictionBecameVisible)
        XCTAssertFalse(offer.presentation.isEnabled)
        XCTAssertFalse(invocation.suppressesPostPushBrowserSuggestion)
    }

    func testCachedPreparationPreservesRawUnverifiedCapabilityPresentation() async throws {
        let fixture = try PullRequestAppFixture()
        let unverified = try unverifiedCreateCapability(fixture: fixture)
        let service = CapabilityOnlyMutationService(capability: unverified)
        let context = try makeCachedPushContext(fixture: fixture)
        defer { context.repositoryFixture.cleanup() }
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: context.repositoryFixture.repository,
            windowController: PBGitWindowController(window: NSWindow()),
            remoteActions: remoteActions,
            service: service,
            destinationOpening: { _ in false },
            bindingResolving: { context.binding },
            postPushBrowserFallback: { _ in XCTFail("The recording coordinator owns fallback reporting") }
        )
        controller.installUITestOrdinaryPushPreparationCache(context.cache)

        controller.performPush(
            branch: context.branch,
            remote: nil,
            requiresConfirmation: true,
            initiallyCreatePullRequest: true
        )

        let invocation = try XCTUnwrap(remoteActions.invocations.first)
        let offer = try XCTUnwrap(invocation.offer)
        let unverifiedBecameVisible = await eventually {
            offer.presentation.isEnabled &&
                offer.presentation.helpText?.contains("fine-grained token") == true
        }
        XCTAssertTrue(unverifiedBecameVisible)
        XCTAssertEqual(
            offer.presentation,
            .capability(unverified, action: "create a Pull Request after pushing")
        )
        XCTAssertFalse(invocation.suppressesPostPushBrowserSuggestion)
    }

    func testBusyDeferredFlowKeepsValidatedBrowserFallbackForFollowingPush() throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let repositoryFixture = try LocalPullRequestRepositoryFixture(
            remoteURL: "git@github.com:contributor/gitx.git"
        )
        defer { repositoryFixture.cleanup() }
        let windowController = PBGitWindowController(window: NSWindow())
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: repositoryFixture.repository,
            windowController: windowController,
            remoteActions: remoteActions,
            service: FailingPreparationMutationService(),
            destinationOpening: { _ in false },
            bindingResolving: { binding },
            postPushBrowserFallback: { _ in XCTFail("The recording coordinator owns fallback reporting") }
        )
        let branch = try XCTUnwrap(repositoryFixture.repository.headRef()?.ref())

        controller.performPush(branch: branch, remote: nil, requiresConfirmation: true)
        controller.performPush(branch: branch, remote: nil, requiresConfirmation: true)

        XCTAssertEqual(remoteActions.invocations.count, 2)
        XCTAssertNotNil(remoteActions.invocations[0].offer)
        XCTAssertNil(remoteActions.invocations[1].option)
        XCTAssertNil(remoteActions.invocations[1].offer)
        XCTAssertFalse(remoteActions.invocations[1].suppressesPostPushBrowserSuggestion)
    }

    func testDeferredOrdinaryPushDoesNotWaitForPreparationAndOpensExactSelectedSheet() async throws {
        let fixture = try PullRequestAppFixture()
        let context = try makeCachedPushContext(fixture: fixture)
        let preparation = context.cache.preparation
        let gate = IgnoringCancellationGate<RepositoryPullRequestCreationPreparation>()
        let bindingBox = PullRequestBindingBox()
        defer { context.repositoryFixture.cleanup() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowController = PBGitWindowController(window: window)
        let remoteActions = RecordingRepositoryRemoteActions(events: [
            .began(createPullRequestSelected: true),
            .succeeded,
        ])
        var browserFallbackCount = 0
        let controller = RepositoryPullRequestUIController(
            repository: context.repositoryFixture.repository,
            windowController: windowController,
            remoteActions: remoteActions,
            service: GatedPreparationMutationService(gate: gate),
            destinationOpening: { _ in false },
            bindingResolving: { bindingBox.binding },
            postPushBrowserFallback: { _ in browserFallbackCount += 1 }
        )
        bindingBox.binding = context.binding

        controller.performPush(
            branch: context.branch,
            remote: nil,
            requiresConfirmation: true,
            initiallyCreatePullRequest: true
        )

        XCTAssertEqual(remoteActions.invocations.count, 1)
        XCTAssertNil(remoteActions.invocations[0].option)
        XCTAssertEqual(remoteActions.invocations[0].offer?.initiallySelected, true)
        XCTAssertFalse(try XCTUnwrap(remoteActions.invocations[0].offer).presentation.isEnabled)
        XCTAssertTrue(try XCTUnwrap(remoteActions.invocations[0].offer?.presentation.helpText).contains("Checking"))
        XCTAssertNil(window.attachedSheet)
        await gate.release(preparation)
        let capabilityBecameAvailable = await eventually {
            remoteActions.invocations[0].offer?.presentation.isEnabled == true
        }
        XCTAssertTrue(capabilityBecameAvailable)
        let didPresentSheet = await eventually { window.attachedSheet != nil }
        XCTAssertTrue(didPresentSheet)
        let sheetView = try XCTUnwrap(window.attachedSheet?.contentView)
        let title = try XCTUnwrap(descendant("GitX.PullRequest.Title", in: sheetView) as? NSTextField)
        XCTAssertEqual(title.stringValue, "Cached native PR")
        XCTAssertEqual(browserFallbackCount, 0)
    }

    #if DEBUG
        func testExplicitNewPullRequestPushCarriesExactIntentIntoSuccessfulCreateSheet() throws {
            let fixture = try PullRequestAppFixture()
            let context = try makeCachedPushContext(fixture: fixture)
            defer { context.repositoryFixture.cleanup() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let windowController = PBGitWindowController(window: window)
            let remoteActions = RecordingRepositoryRemoteActions(events: [
                .began(createPullRequestSelected: true),
                .succeeded,
            ])
            let controller = RepositoryPullRequestUIController(
                repository: context.repositoryFixture.repository,
                windowController: windowController,
                remoteActions: remoteActions,
                service: CapabilityOnlyMutationService(capability: .verified(.knownAuthority)),
                destinationOpening: { _ in false },
                bindingResolving: { context.binding },
                postPushBrowserFallback: { _ in XCTFail("The exact native intent must not use browser fallback") }
            )

            try controller.beginUITestCreateJourney(
                preparation: context.cache.preparation,
                initialForm: context.cache.initialForm,
                branch: context.branch,
                requiresPush: true
            )

            let invocation = try XCTUnwrap(remoteActions.invocations.first)
            XCTAssertEqual(invocation.branch?.ref, context.branch.ref)
            XCTAssertNotNil(invocation.remote)
            XCTAssertEqual(invocation.option?.preparation, context.cache.preparation)
            XCTAssertEqual(invocation.option?.intent.form, context.cache.initialForm)
            XCTAssertNil(invocation.offer)
            XCTAssertTrue(invocation.requiresConfirmation)
            XCTAssertFalse(invocation.suppressesPostPushBrowserSuggestion)
            let sheetView = try XCTUnwrap(window.attachedSheet?.contentView)
            let title = try XCTUnwrap(descendant("GitX.PullRequest.Title", in: sheetView) as? NSTextField)
            XCTAssertEqual(title.stringValue, context.cache.initialForm.title)
        }
    #endif

    func testUncheckedDeferredOrdinaryPushHasNoPullRequestNavigationSideEffect() throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let bindingBox = PullRequestBindingBox()
        let repositoryFixture = try LocalPullRequestRepositoryFixture(remoteURL: "git@github.com:contributor/gitx.git")
        defer { repositoryFixture.cleanup() }
        let window = NSWindow()
        let windowController = PBGitWindowController(window: window)
        let remoteActions = RecordingRepositoryRemoteActions(events: [
            .began(createPullRequestSelected: false),
            .succeeded,
        ])
        var browserFallbackCount = 0
        let controller = try RepositoryPullRequestUIController(
            repository: repositoryFixture.repository,
            windowController: windowController,
            remoteActions: remoteActions,
            service: ImmediatePreparationMutationService(preparation: fixture.preparation()),
            destinationOpening: { _ in false },
            bindingResolving: { bindingBox.binding },
            postPushBrowserFallback: { _ in browserFallbackCount += 1 }
        )
        bindingBox.binding = binding

        try controller.performPush(
            branch: XCTUnwrap(repositoryFixture.repository.headRef()?.ref()),
            remote: nil,
            requiresConfirmation: true
        )

        XCTAssertEqual(remoteActions.invocations.count, 1)
        XCTAssertNotNil(remoteActions.invocations[0].offer)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(browserFallbackCount, 0)
    }

    func testUnavailableDeferredPreparationKeepsCreateOfferDisabled() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let bindingBox = PullRequestBindingBox()
        let repositoryFixture = try LocalPullRequestRepositoryFixture(
            remoteURL: "git@github.com:contributor/gitx.git"
        )
        defer { repositoryFixture.cleanup() }
        let windowController = PBGitWindowController(window: NSWindow())
        let remoteActions = RecordingRepositoryRemoteActions(events: [])
        let controller = RepositoryPullRequestUIController(
            repository: repositoryFixture.repository,
            windowController: windowController,
            remoteActions: remoteActions,
            service: FailingPreparationMutationService(),
            destinationOpening: { _ in false },
            bindingResolving: { bindingBox.binding },
            postPushBrowserFallback: { _ in XCTFail("The push has not completed") }
        )
        bindingBox.binding = binding

        try controller.performPush(
            branch: XCTUnwrap(repositoryFixture.repository.headRef()?.ref()),
            remote: nil,
            requiresConfirmation: true
        )

        let offer = try XCTUnwrap(remoteActions.invocations.first?.offer)
        let failureBecameVisible = await eventually {
            offer.presentation.helpText?.contains("Native Pull Request creation is unavailable") == true
        }
        XCTAssertTrue(failureBecameVisible)
        XCTAssertFalse(offer.presentation.isEnabled)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 1000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func descendant(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { self.descendant(identifier, in: $0) }.first
    }
}

@MainActor
final class RepositoryPullRequestSheetAppTests: XCTestCase {
    func testCreateSheetHasStableAccessibilityAndDraftDefaultsOffAfterRestore() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation()
        let forms = try preparation.initialForms()
        let controller = ForgePullRequestSheetController(
            mode: .create(preparation: preparation, initialForms: forms),
            restoredContent: ForgeDraftContent(title: "Restored", body: "Body")
        )
        let view = try XCTUnwrap(controller.window?.contentView)

        let title = try XCTUnwrap(descendant("GitX.PullRequest.Title", in: view) as? NSTextField)
        let draft = try XCTUnwrap(descendant("GitX.PullRequest.Draft", in: view) as? NSButton)
        let body = try XCTUnwrap(descendant("GitX.PullRequest.Body", in: view) as? NSTextView)
        let submit = try XCTUnwrap(descendant("GitX.PullRequest.Submit", in: view) as? NSButton)
        XCTAssertNotNil(descendant("GitX.PullRequest.DiscardDraft", in: view))
        XCTAssertEqual(title.stringValue, "Restored")
        XCTAssertEqual(body.string, "Body")
        XCTAssertEqual(draft.state, .off)
        XCTAssertEqual(submit.accessibilityLabel(), "Create Pull Request")
        try attachScreenshot(
            of: XCTUnwrap(controller.window),
            named: "Milestone 2 Create Pull Request sheet"
        )

        var submitted: ForgePullRequestCreationForm?
        controller.onSubmit = { submission in
            guard case let .create(_, form) = submission else { return }
            submitted = form
        }
        submit.performClick(nil)
        XCTAssertEqual(submitted?.title, "Restored")
        XCTAssertFalse(try XCTUnwrap(submitted).isDraft)
    }

    func testCreateSheetTitleBarCloseCancelsOnceAndPreservesCurrentDraft() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation()
        let controller = try ForgePullRequestSheetController(
            mode: .create(preparation: preparation, initialForms: preparation.initialForms()),
            restoredContent: ForgeDraftContent(title: "Preserved", body: "Current body")
        )
        let window = try XCTUnwrap(controller.window)
        var cancellations: [ForgeDraftContent] = []
        var discardCount = 0
        controller.onCancel = { cancellations.append($0) }
        controller.onDiscard = { discardCount += 1 }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertFalse(controller.windowShouldClose(window))

        XCTAssertEqual(cancellations, [ForgeDraftContent(title: "Preserved", body: "Current body")])
        XCTAssertEqual(discardCount, 0)
    }

    func testCreateSheetDiscardDraftFinishesOnceWithoutCancellation() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation()
        let controller = try ForgePullRequestSheetController(
            mode: .create(preparation: preparation, initialForms: preparation.initialForms())
        )
        let view = try XCTUnwrap(controller.window?.contentView)
        let discard = try XCTUnwrap(descendant("GitX.PullRequest.DiscardDraft", in: view) as? NSButton)
        var cancellationCount = 0
        var discardCount = 0
        controller.onCancel = { _ in cancellationCount += 1 }
        controller.onDiscard = { discardCount += 1 }

        discard.performClick(nil)
        discard.performClick(nil)

        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testEditSheetRestoresDraftAndRetainsServerConflictToken() throws {
        let fixture = try PullRequestAppFixture()
        let updatedAt = Date(timeIntervalSince1970: 10)
        let snapshot = try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: ForgeItemNumber(42),
            title: "Server title",
            bodyMarkdown: "Server body",
            updatedAt: updatedAt
        )
        let destination = try ForgeDestination.pullRequest(fixture.repository, snapshot.number)
        let controller = ForgePullRequestSheetController(
            mode: .edit(
                accountID: fixture.accountID,
                snapshot: snapshot,
                destination: destination
            ),
            restoredContent: ForgeDraftContent(title: "Draft title", body: "Draft body")
        )
        let view = try XCTUnwrap(controller.window?.contentView)
        let title = try XCTUnwrap(descendant("GitX.PullRequest.Title", in: view) as? NSTextField)
        let body = try XCTUnwrap(descendant("GitX.PullRequest.Body", in: view) as? NSTextView)
        let submit = try XCTUnwrap(descendant("GitX.PullRequest.Submit", in: view) as? NSButton)
        XCTAssertEqual(title.stringValue, "Draft title")
        XCTAssertEqual(body.string, "Draft body")
        try attachScreenshot(
            of: XCTUnwrap(controller.window),
            named: "Milestone 2 Edit Pull Request sheet"
        )

        var submittedEdit: ForgePullRequestEdit?
        controller.onSubmit = { submission in
            guard case let .edit(_, edit, _) = submission else { return }
            submittedEdit = edit
        }
        submit.performClick(nil)
        XCTAssertEqual(submittedEdit?.title, "Draft title")
        XCTAssertEqual(submittedEdit?.bodyMarkdown, "Draft body")
        XCTAssertEqual(submittedEdit?.expectedUpdatedAt, updatedAt)
    }

    func testCloneSheetRequiresExplicitAccountRepositoryDestinationAndSSHChoice() throws {
        let fixture = try PullRequestAppFixture()
        let entry = try RepositoryForgeCloneCatalog.Entry(repository: fixture.repository, relationship: .owned)
        let catalog = try RepositoryForgeCloneCatalog(
            accountID: fixture.accountID,
            accountDisplayName: "account",
            repositories: [entry]
        )
        let controller = ForgeRepositoryCloneSheetController(catalogs: [catalog])
        let view = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNotNil(descendant("GitX.Clone.Account", in: view))
        XCTAssertNotNil(descendant("GitX.Clone.Repositories", in: view))
        let ssh = try XCTUnwrap(descendant("GitX.Clone.UseSSH", in: view) as? NSButton)
        XCTAssertEqual(ssh.state, .on)
        try attachScreenshot(
            of: XCTUnwrap(controller.window),
            named: "Milestone 2 GitHub clone sheet"
        )

        let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let sshChoice = try controller.selectedChoice(destinationDirectory: destination)
        XCTAssertEqual(sshChoice.request.transport, .ssh)
        XCTAssertEqual(sshChoice.request.relationship, .owned)
        ssh.state = .off
        XCTAssertEqual(try controller.selectedChoice(destinationDirectory: destination).request.transport, .https)
    }

    func testPushAndDeepLinkPresentersKeepDiagnosticScreenshots() throws {
        let checkbox = RepositoryPushConfirmationPresenter.createPullRequestButton(
            initiallySelected: true
        )
        let pushAlert = RepositoryPushConfirmationPresenter.alert(
            description: "Push branch 'feature/milestone-2' to default remote",
            accessoryView: checkbox
        )
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertEqual(checkbox.accessibilityIdentifier(), "GitX.Push.CreatePullRequest")
        try attachScreenshot(
            of: pushAlert.window,
            named: "Milestone 2 Push confirmation and Create Pull Request checkbox"
        )

        let chooser = ForgeDeepLinkAlertFactory.checkoutChooser(candidates: [
            (title: "GitX — primary checkout", identifier: "checkout-1"),
            (title: "GitX — review checkout", identifier: "checkout-2"),
        ])
        XCTAssertEqual(chooser.popup.numberOfItems, 2)
        try attachScreenshot(
            of: chooser.alert.window,
            named: "Milestone 2 x-gitx checkout chooser"
        )

        let missing = ForgeDeepLinkAlertFactory.missingObject(
            actions: ForgeDeepLinkMissingObjectAction.allCases
        )
        try attachScreenshot(
            of: missing.window,
            named: "Milestone 2 x-gitx missing object error"
        )

        let invalid = ForgeDeepLinkAlertFactory.error(ForgeDeepLinkError.invalidURL)
        try attachScreenshot(
            of: invalid.window,
            named: "Milestone 2 x-gitx malformed link error"
        )
    }

    func testMissingObjectPresenterPreservesSuppliedActionOrderAndAccessibility() {
        let reversed = ForgeDeepLinkAlertFactory.missingObject(actions: [.openInBrowser, .fetch])
        XCTAssertEqual(reversed.buttons.map(\.title), ["Open in Browser", "Fetch", "Cancel"])
        XCTAssertEqual(reversed.buttons[0].accessibilityIdentifier(), "GitX.DeepLink.OpenInBrowser")
        XCTAssertEqual(reversed.buttons[1].accessibilityIdentifier(), "GitX.DeepLink.Fetch")

        let browserOnly = ForgeDeepLinkAlertFactory.missingObject(actions: [.openInBrowser])
        XCTAssertEqual(browserOnly.buttons.map(\.title), ["Open in Browser", "Cancel"])
        XCTAssertEqual(browserOnly.buttons[0].accessibilityIdentifier(), "GitX.DeepLink.OpenInBrowser")
    }

    func testLocalPreparationUsesExactTrackingRemoteBaseObjectsTemplatesAndCommitOrder() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let templatePath = ".github/PULL_REQUEST_TEMPLATE.md"
        let runner = ScriptedPullRequestGitRunner(responses: [
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native"]: "fork/feature/native\n",
            ["remote", "get-url", "--push", "--all", "fork"]: "git@github.com:contributor/repo.git\n",
            ["rev-parse", "--verify", "refs/remotes/fork/feature/native"]: fixture.headCommit.value,
            ["rev-parse", "--verify", "refs/remotes/upstream/main"]: fixture.baseCommit.value,
            ["ls-tree", "-r", "--name-only", fixture.baseCommit.value, "--"]: "\(templatePath)\nREADME.md\n",
            ["show", "\(fixture.baseCommit.value):\(templatePath)"]: "## Summary\n",
            [
                "log", "--reverse", "--format=%H%x00%s%x00%b%x00",
                "\(fixture.baseCommit.value)..\(fixture.headCommit.value)",
            ]: "\(fixture.headCommit.value)\0Native preparation\0Uses local Git objects\0",
        ])
        let source = RepositoryPullRequestLocalPreparationSource(runner: runner)

        let preparation = try await source.preparation(
            accountID: fixture.accountID,
            binding: binding,
            localBranch: ForgeRefName("feature/native"),
            localHead: fixture.headCommit,
            defaultBranch: ForgeRefName("main")
        )

        XCTAssertEqual(preparation.repository, fixture.repository)
        XCTAssertEqual(preparation.base.commit, fixture.baseCommit)
        XCTAssertEqual(preparation.head.repository.owner, "contributor")
        XCTAssertTrue(preparation.branchAlreadyPushed)
        XCTAssertEqual(preparation.templates.map(\.path), try [ForgeFilePath(templatePath)])
        XCTAssertEqual(preparation.commitsOldestFirst.map(\.subject), ["Native preparation"])
        XCTAssertEqual(try preparation.initialForms().forms.first?.bodyMarkdown, "## Summary\n")
    }

    func testLocalPreparationPrefersBranchPushRemoteThenDefaultPushRemote() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let branchPushRunner = ScriptedPullRequestGitRunner(responses: [
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native"]: "tracking/feature/native\n",
            ["config", "--get", "branch.feature/native.pushRemote"]: "branch-push\n",
            ["config", "--get", "remote.pushDefault"]: "default-push\n",
            ["remote", "get-url", "--push", "--all", "branch-push"]: "git@github.com:branch-contributor/repo.git\n",
            ["rev-parse", "--verify", "refs/remotes/upstream/main"]: fixture.baseCommit.value,
        ])
        let branchPreparation = try await RepositoryPullRequestLocalPreparationSource(
            runner: branchPushRunner
        ).preparation(
            accountID: fixture.accountID,
            binding: binding,
            localBranch: ForgeRefName("feature/native"),
            localHead: fixture.headCommit,
            defaultBranch: ForgeRefName("main")
        )
        XCTAssertEqual(branchPreparation.head.repository.owner, "branch-contributor")

        let defaultPushRunner = ScriptedPullRequestGitRunner(responses: [
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native"]: "tracking/feature/native\n",
            ["config", "--get", "remote.pushDefault"]: "default-push\n",
            ["remote", "get-url", "--push", "--all", "default-push"]: "git@github.com:default-contributor/repo.git\n",
            ["rev-parse", "--verify", "refs/remotes/upstream/main"]: fixture.baseCommit.value,
        ])
        let defaultPreparation = try await RepositoryPullRequestLocalPreparationSource(
            runner: defaultPushRunner
        ).preparation(
            accountID: fixture.accountID,
            binding: binding,
            localBranch: ForgeRefName("feature/native"),
            localHead: fixture.headCommit,
            defaultBranch: ForgeRefName("main")
        )
        XCTAssertEqual(defaultPreparation.head.repository.owner, "default-contributor")
    }

    func testLocalPreparationRejectsDivergentAndDifferentForgePushTargets() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let divergentRunner = ScriptedPullRequestGitRunner(responses: [
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native"]: "fork/feature/native\n",
            ["remote", "get-url", "--push", "--all", "fork"]:
                "git@github.com:contributor/repo.git\ngit@github.com:other/repo.git\n",
        ])
        do {
            _ = try await RepositoryPullRequestLocalPreparationSource(runner: divergentRunner).preparation(
                accountID: fixture.accountID,
                binding: binding,
                localBranch: ForgeRefName("feature/native"),
                localHead: fixture.headCommit,
                defaultBranch: ForgeRefName("main")
            )
            XCTFail("Divergent push targets must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgePullRequestWorkflowError, .invalidRemoteURL)
        }

        let differentForgeRunner = ScriptedPullRequestGitRunner(responses: [
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native"]: "fork/feature/native\n",
            ["remote", "get-url", "--push", "--all", "fork"]: "https://gitlab.com/contributor/repo.git\n",
        ])
        do {
            _ = try await RepositoryPullRequestLocalPreparationSource(runner: differentForgeRunner).preparation(
                accountID: fixture.accountID,
                binding: binding,
                localBranch: ForgeRefName("feature/native"),
                localHead: fixture.headCommit,
                defaultBranch: ForgeRefName("main")
            )
            XCTFail("A different Forge push target must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
    }

    func testCancellingLocalPreparationStopsAfterTheCurrentGitCommand() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let runner = BlockingPullRequestGitRunner()
        let source = RepositoryPullRequestLocalPreparationSource(runner: runner)
        let accountID = fixture.accountID
        let localHead = fixture.headCommit
        let task = Task.detached {
            try await source.preparation(
                accountID: accountID,
                binding: binding,
                localBranch: ForgeRefName("feature/native"),
                localHead: localHead,
                defaultBranch: ForgeRefName("main")
            )
        }

        XCTAssertTrue(runner.waitUntilFirstCommandStarts(timeout: 2))
        task.cancel()
        runner.releaseFirstCommand()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop local Git preparation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(runner.commands, [[
            "for-each-ref", "--format=%(upstream:short)", "refs/heads/feature/native",
        ]])
    }

    func testPreCancelledLocalPreparationDoesNotStartAGitCommand() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let runner = BlockingPullRequestGitRunner()
        let source = RepositoryPullRequestLocalPreparationSource(runner: runner)
        let accountID = fixture.accountID
        let localHead = fixture.headCommit
        let gate = PullRequestPreparationGate()
        let task = Task.detached {
            await gate.wait()
            return try await source.preparation(
                accountID: accountID,
                binding: binding,
                localBranch: ForgeRefName("feature/native"),
                localHead: localHead,
                defaultBranch: ForgeRefName("main")
            )
        }

        task.cancel()
        runner.releaseFirstCommand()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Pre-cancelled preparation must fail before launching Git")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testCancelledLateProviderResultDoesNotProducePreparationCache() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let key = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: fixture.head.name,
            localHead: fixture.head.commit,
            effectiveRemoteName: "fork",
            effectiveRemoteRepository: fixture.head.repository
        ))
        let providerGate = IgnoringCancellationGate<RepositoryPullRequestCreationPreparation>()
        let drafts = CountingPullRequestDraftStore()
        let task = Task.detached {
            try await RepositoryPullRequestPreparationCacheLoader().load(
                key: key,
                service: GatedPreparationMutationService(gate: providerGate),
                drafts: drafts,
                expiresAfter: 60,
                now: { Date(timeIntervalSince1970: 100) }
            )
        }

        await providerGate.awaitStarted()
        task.cancel()
        try await providerGate.release(fixture.preparation())
        do {
            _ = try await task.value
            XCTFail("A late provider result must not produce a cache")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let draftLoadCount = await drafts.loadCount
        XCTAssertEqual(draftLoadCount, 0)
    }

    func testCancelledLateDraftResultDoesNotProducePreparationCache() async throws {
        let fixture = try PullRequestAppFixture()
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: fixture.repository,
            preferredAccount: fixture.accountID
        )
        let key = try XCTUnwrap(RepositoryPullRequestPreparationCacheKey(
            binding: binding,
            branch: fixture.head.name,
            localHead: fixture.head.commit,
            effectiveRemoteName: "fork",
            effectiveRemoteRepository: fixture.head.repository
        ))
        let draftGate = IgnoringCancellationGate<ForgeDraft?>()
        let task = Task.detached {
            try await RepositoryPullRequestPreparationCacheLoader().load(
                key: key,
                service: ImmediatePreparationMutationService(preparation: fixture.preparation()),
                drafts: GatedPullRequestDraftStore(gate: draftGate),
                expiresAfter: 60,
                now: { Date(timeIntervalSince1970: 100) }
            )
        }

        await draftGate.awaitStarted()
        task.cancel()
        await draftGate.release(nil)
        do {
            _ = try await task.value
            XCTFail("A late draft result must not produce a cache")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSQLitePullRequestDraftStorePersistsAndDeletesExactIdentity() async throws {
        let fixture = try PullRequestAppFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let store = ForgeSQLitePullRequestDraftStore(database: database)
        let identity = try ForgeDraftIdentity(
            accountID: fixture.accountID,
            destination: .createPullRequest(
                repository: fixture.repository,
                base: ForgeRefName("main"),
                head: ForgeRefName("feature/native")
            )
        )
        let savedAt = Date(timeIntervalSince1970: 100)
        try await store.save(
            identity: identity,
            content: ForgeDraftContent(title: "Durable title", body: "Durable body"),
            at: savedAt
        )

        let loadedValue = try await store.load(identity: identity)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.identity, identity)
        XCTAssertEqual(loaded.content.title, "Durable title")
        XCTAssertEqual(loaded.content.body, "Durable body")

        try await store.delete(identity: identity)
        let deleted = try await store.load(identity: identity)
        XCTAssertNil(deleted)
    }

    func testMutationCooldownIsScopedToExactCredentialAndExpires() async throws {
        let fixture = try PullRequestAppFixture()
        let state = ForgeGitHubMutationStateStore()
        let reference = try ForgeCredentialReference(
            accountID: fixture.accountID,
            credentialID: ForgeCredentialID("credential-a"),
            generation: ForgeCredentialGeneration(1)
        )
        let other = try ForgeCredentialReference(
            accountID: fixture.accountID,
            credentialID: ForgeCredentialID("credential-b"),
            generation: ForgeCredentialGeneration(1)
        )
        let now = Date(timeIntervalSince1970: 1000)
        let deadline = now.addingTimeInterval(120)
        await state.record(
            response: GitHubResponseMetadata(
                statusCode: 429,
                rateLimit: GitHubRateLimitParser.parse(
                    statusCode: 429,
                    headers: ["retry-after": "120"],
                    receivedAt: now
                )
            ),
            credential: reference,
            now: now
        )

        let exactEnvironment = await state.environment(for: reference, now: now)
        let otherEnvironment = await state.environment(for: other, now: now)
        let expiredEnvironment = await state.environment(for: reference, now: deadline)
        XCTAssertEqual(exactEnvironment, .rateLimited(until: deadline))
        XCTAssertEqual(otherEnvironment, .available)
        XCTAssertEqual(expiredEnvironment, .available)
    }

    func testNormalNativeSubmissionConfirmsOnlyTheExactUnverifiedWriteAttempt() throws {
        let fixture = try PullRequestAppFixture()
        let credential = try ForgeCredentialReference(
            accountID: fixture.accountID,
            credentialID: ForgeCredentialID("fine-grained"),
            generation: ForgeCredentialGeneration(1)
        )
        let key = ForgeCapabilityKey(
            credential: credential,
            repository: fixture.repository,
            operation: .createPullRequest
        )
        let account = try ForgeAccount(
            id: fixture.accountID,
            login: "octocat",
            currentCredential: ForgeCredentialMetadata(
                reference: credential,
                source: .fineGrainedPersonalAccessToken
            )
        )
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
        let capability = ForgeCapabilityEvaluator.capability(
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
        guard case let .unverifiedWrite(attempt) = capability else {
            return XCTFail("Expected an evaluator-issued Unverified Write")
        }

        XCTAssertThrowsError(try ForgeGitHubPullRequestDependencyProvider.authorization(
            key: key,
            capability: capability,
            operationWasConfirmed: false
        )) {
            XCTAssertEqual(
                $0 as? ForgeGitHubPullRequestCompositionError,
                .explicitConfirmationRequired(.createPullRequest)
            )
        }

        let authorization = try ForgeGitHubPullRequestDependencyProvider.authorization(
            key: key,
            capability: capability,
            operationWasConfirmed: true
        )
        XCTAssertEqual(authorization.key, key)
        XCTAssertEqual(authorization.explicitConfirmation?.attempt, attempt)
        let otherKey = ForgeCapabilityKey(
            credential: credential,
            repository: fixture.repository,
            operation: .editPullRequest
        )
        XCTAssertThrowsError(try GitHubMutationAuthorization(
            key: otherKey,
            capability: capability,
            explicitConfirmation: authorization.explicitConfirmation
        ))
    }

    func testClassicScopeMappingUsesKnownScopeAndRepositoryVisibilityWithoutGuessing() {
        XCTAssertEqual(
            ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .pullRequests,
                scopes: ["repo"],
                repositoryIsPublic: false
            ),
            .known(.write)
        )
        XCTAssertEqual(
            ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .contents,
                scopes: ["public_repo"],
                repositoryIsPublic: true
            ),
            .known(.write)
        )
        XCTAssertEqual(
            ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .contents,
                scopes: ["public_repo"],
                repositoryIsPublic: false
            ),
            .unknown
        )
        XCTAssertEqual(
            ForgeGitHubPullRequestDependencyProvider.classicAuthority(
                permission: .pullRequests,
                scopes: [],
                repositoryIsPublic: true
            ),
            .known(.read)
        )
    }

    private func descendant(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for child in view.subviews {
            if let match = descendant(identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func attachScreenshot(of window: NSWindow, named name: String) throws {
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        )
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        let screenshot = NSImage(size: contentView.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// swift6-safety-justification: the only mutable command log is serialized by `lock`, and tests read it after calls return.
private final class RecordingPullRequestGitRunner: RepositoryPullRequestGitCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let head: String
    private let status: String
    private let activeOperation: String?
    private let failsFetch: Bool
    private(set) var commands: [[String]] = []

    init(
        head: String,
        status: String = "",
        activeOperation: String? = nil,
        failsFetch: Bool = false
    ) {
        self.head = head
        self.status = status
        self.activeOperation = activeOperation
        self.failsFetch = failsFetch
    }

    func run(_ arguments: [String]) throws -> String {
        lock.lock()
        commands.append(arguments)
        lock.unlock()
        if arguments == ["status", "--porcelain=v2", "--untracked-files=normal"] {
            return status
        }
        if arguments.first == "fetch", failsFetch {
            throw RecordingError.fetchFailed
        }
        if arguments.starts(with: ["rev-parse", "--verify", "--quiet"]), arguments.last == activeOperation {
            return head
        }
        if arguments.starts(with: ["rev-parse", "--verify", "--quiet"]) {
            throw RecordingError.missingReference
        }
        if arguments.count == 3,
           Array(arguments.prefix(2)) == ["rev-parse", "--verify"],
           arguments[2].hasPrefix("refs/remotes/")
        {
            return head
        }
        return ""
    }

    private enum RecordingError: Error { case missingReference, fetchFailed }
}

private actor PullRequestPreparationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor IgnoringCancellationGate<Value: Sendable> {
    private enum ReleaseState {
        case pending
        case released(Value)
    }

    private var isStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<Value, Never>?
    private var releaseState = ReleaseState.pending

    func awaitStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func wait() async -> Value {
        isStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        if case let .released(value) = releaseState {
            return value
        }
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func release(_ value: Value) {
        if let resultContinuation {
            self.resultContinuation = nil
            resultContinuation.resume(returning: value)
        } else {
            releaseState = .released(value)
        }
    }
}

private actor CapabilityOnlyMutationService: RepositoryPullRequestMutationServing {
    struct Request: Equatable, Sendable {
        let accountID: ForgeAccountID
        let repository: ForgeRepositoryIdentity
        let operations: Set<ForgeOperation>
    }

    let capability: ForgeOperationCapability
    private(set) var requests: [Request] = []

    init(capability: ForgeOperationCapability) {
        self.capability = capability
    }

    func capabilities(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> [ForgeOperation: ForgeOperationCapability] {
        requests.append(Request(
            accountID: accountID,
            repository: repository,
            operations: operations
        ))
        return Dictionary(uniqueKeysWithValues: operations.map { ($0, capability) })
    }

    func prepareCreation(
        repository _: ForgeRepositoryIdentity,
        localBranch _: ForgeRefName,
        localHead _: ForgeCommitID
    ) async throws -> RepositoryPullRequestCreationPreparation {
        throw CapabilityOnlyError.unexpectedPreparation
    }

    func createPullRequest(
        accountID _: ForgeAccountID,
        form _: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        throw CapabilityOnlyError.unexpectedMutation
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw CapabilityOnlyError.unexpectedMutation
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan _: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        throw CapabilityOnlyError.unexpectedMutation
    }

    private enum CapabilityOnlyError: Error {
        case unexpectedPreparation
        case unexpectedMutation
    }
}

private struct GatedPreparationMutationService: RepositoryPullRequestMutationServing {
    let gate: IgnoringCancellationGate<RepositoryPullRequestCreationPreparation>

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
        await gate.wait()
    }

    func createPullRequest(
        accountID _: ForgeAccountID,
        form _: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        throw GatedError.unexpectedCall
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw GatedError.unexpectedCall
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan _: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        throw GatedError.unexpectedCall
    }

    private enum GatedError: Error { case unexpectedCall }
}

private struct ImmediatePreparationMutationService: RepositoryPullRequestMutationServing {
    let preparation: RepositoryPullRequestCreationPreparation

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
        throw ImmediateError.unexpectedCall
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw ImmediateError.unexpectedCall
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan _: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        throw ImmediateError.unexpectedCall
    }

    private enum ImmediateError: Error { case unexpectedCall }
}

private struct FailingPreparationMutationService: RepositoryPullRequestMutationServing {
    func capabilities(
        accountID _: ForgeAccountID,
        repository _: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> [ForgeOperation: ForgeOperationCapability] {
        Dictionary(uniqueKeysWithValues: operations.map {
            ($0, .unavailable(.knownOperationRestriction))
        })
    }

    func prepareCreation(
        repository _: ForgeRepositoryIdentity,
        localBranch _: ForgeRefName,
        localHead _: ForgeCommitID
    ) async throws -> RepositoryPullRequestCreationPreparation {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func createPullRequest(
        accountID _: ForgeAccountID,
        form _: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan _: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }
}

private actor CountingPullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    private(set) var loadCount = 0

    func load(identity _: ForgeDraftIdentity) async throws -> ForgeDraft? {
        loadCount += 1
        return nil
    }

    func save(identity _: ForgeDraftIdentity, content _: ForgeDraftContent, at _: Date) async throws {}
    func delete(identity _: ForgeDraftIdentity) async throws {}
}

private struct GatedPullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    let gate: IgnoringCancellationGate<ForgeDraft?>

    func load(identity _: ForgeDraftIdentity) async throws -> ForgeDraft? {
        await gate.wait()
    }

    func save(identity _: ForgeDraftIdentity, content _: ForgeDraftContent, at _: Date) async throws {}
    func delete(identity _: ForgeDraftIdentity) async throws {}
}

@MainActor
private final class PullRequestBindingBox {
    var binding: ForgeRepositoryBinding?
}

@MainActor
private final class RecordingRepositoryRemoteActions: RepositoryRemoteActionCoordinating {
    struct Invocation {
        let branch: PBGitRef?
        let remote: PBGitRef?
        let requiresConfirmation: Bool
        let option: RepositoryPullRequestPushOption?
        let offer: RepositoryPullRequestPushOffer?
        let suppressesPostPushBrowserSuggestion: Bool
    }

    private(set) var invocations: [Invocation] = []
    private let events: [RepositoryPushEvent]

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
        invocations.append(Invocation(
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

@MainActor
private final class LocalPullRequestRepositoryFixture {
    let directory: URL
    let repository: PBGitRepository

    init(remoteURL: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitX-PullRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.runGit(["init", "--quiet", "--initial-branch=main"], in: directory)
            try Self.runGit(["config", "user.name", "GitX Tests"], in: directory)
            try Self.runGit(["config", "user.email", "gitx-tests@example.invalid"], in: directory)
            try "fixture\n".write(
                to: directory.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Self.runGit(["add", "tracked.txt"], in: directory)
            try Self.runGit(["commit", "--quiet", "-m", "Fixture"], in: directory)
            try Self.runGit(["remote", "add", "origin", remoteURL], in: directory)
            repository = try PBGitRepository(url: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() {
        repository.revisionList?.cleanup()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Git command failed"
            throw FixtureError.gitFailed(arguments, process.terminationStatus, message)
        }
    }

    private enum FixtureError: Error {
        case gitFailed([String], Int32, String)
    }
}

// swift6-safety-justification: immutable responses are safe for concurrent reads.
private final class ScriptedPullRequestGitRunner: RepositoryPullRequestGitCommandRunning, @unchecked Sendable {
    private let responses: [[String]: String]

    init(responses: [[String]: String]) {
        self.responses = responses
    }

    func run(_ arguments: [String]) throws -> String {
        guard let response = responses[arguments] else {
            throw ScriptedError.unexpected(arguments)
        }
        return response
    }

    private enum ScriptedError: Error { case unexpected([String]) }
}

// swift6-safety-justification: the condition guards the command log and the one-shot blocking gate.
private final class BlockingPullRequestGitRunner: RepositoryPullRequestGitCommandRunning, @unchecked Sendable {
    private let condition = NSCondition()
    private var firstCommandStarted = false
    private var firstCommandReleased = false
    private var recordedCommands: [[String]] = []

    var commands: [[String]] {
        condition.withLock { recordedCommands }
    }

    func run(_ arguments: [String]) throws -> String {
        condition.lock()
        recordedCommands.append(arguments)
        if recordedCommands.count == 1 {
            firstCommandStarted = true
            condition.broadcast()
            while !firstCommandReleased {
                condition.wait()
            }
        }
        condition.unlock()
        return ""
    }

    func waitUntilFirstCommandStarts(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !firstCommandStarted, condition.wait(until: deadline) {}
        return firstCommandStarted
    }

    func releaseFirstCommand() {
        condition.withLock {
            firstCommandReleased = true
            condition.broadcast()
        }
    }
}

private struct StubPullRequestMutationService: RepositoryPullRequestMutationServing {
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
        throw StubError.unexpectedCall
    }

    func createPullRequest(
        accountID _: ForgeAccountID,
        form _: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        throw StubError.unexpectedCall
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw StubError.unexpectedCall
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        RepositorySyncForkOutcome(plan: plan, serverSummary: "Fork updated")
    }

    private enum StubError: Error { case unexpectedCall }
}

private struct PullRequestAppFixture {
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
        accountID = try ForgeAccountID(forge: forge, value: "account")
        baseCommit = try ForgeCommitID(String(repeating: "1", count: 40))
        headCommit = try ForgeCommitID(String(repeating: "2", count: 40))
        base = try ForgeBranchReference(repository: repository, name: ForgeRefName("main"), commit: baseCommit)
        head = try ForgeBranchReference(repository: fork, name: ForgeRefName("feature"), commit: headCommit)
    }

    func preparation(branchAlreadyPushed: Bool = true) throws -> RepositoryPullRequestCreationPreparation {
        try RepositoryPullRequestCreationPreparation(
            accountID: accountID,
            repository: repository,
            base: base,
            head: head,
            branchAlreadyPushed: branchAlreadyPushed,
            commitsOldestFirst: [ForgePullRequestCommitSummary(id: headCommit, subject: "Native PR")]
        )
    }

    func checkoutPlan(addsRemote: Bool) throws -> ForgePullRequestCheckoutPlan {
        guard let fetchURL = URL(string: "https://github.com/contributor/gitx.git") else {
            throw FixtureError.invalidURL
        }
        let remote = try ForgeGitRemote(
            name: "github-contributor",
            repository: fork,
            fetchURL: fetchURL
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

    private enum FixtureError: Error { case invalidURL }
}
