import AppKit
import ForgeKit
import GitHubForgeAdapter
import XCTest

final class RepositoryPullRequestWorkflowAppTests: XCTestCase {
    @MainActor
    func testLocalPullRequestFixtureIgnoresInheritedGitDirectoryAndIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Hostile-Location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let foreignGitDirectory = root.appendingPathComponent("foreign.git")
        let foreignIndex = root.appendingPathComponent("foreign-index")
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_DIR"] = foreignGitDirectory.path
        inherited["GIT_INDEX_FILE"] = foreignIndex.path
        let fixture = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/example/fixture.git", inheritedEnvironment: inherited)
        defer { fixture.cleanup() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".git/HEAD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignGitDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignIndex.path))
        XCTAssertEqual(try fixture.repository.outputOfTask(withArguments: ["show", "HEAD:tracked.txt"]), "fixture")
    }

    @MainActor
    func testLocalPullRequestFixtureIgnoresInheritedHooksSigningTemplatesAndInjectedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Hostile-Config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks", isDirectory: true)
        let template = root.appendingPathComponent("template", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try "inherited-template\n".write(to: template.appendingPathComponent("inherited-template-marker"), atomically: true, encoding: .utf8)
        let hook = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\nprintf inherited-hook >\"$GITX_FIXTURE_HOOK_MARKER\"\nexit 9\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let signingProgram = root.appendingPathComponent("signing-program")
        try "#!/bin/sh\nprintf inherited-signing >\"$GITX_FIXTURE_SIGNING_MARKER\"\nexit 9\n".write(to: signingProgram, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signingProgram.path)
        let configuration = root.appendingPathComponent("gitconfig")
        try """
        [core]
            hooksPath = \(hooks.path)
        [commit]
            gpgsign = true
        [tag]
            gpgsign = true
        [gpg]
            program = \(signingProgram.path)
        [init]
            templateDir = \(template.path)
        """.write(to: configuration, atomically: true, encoding: .utf8)
        let hookMarker = root.appendingPathComponent("hook-ran")
        let signingMarker = root.appendingPathComponent("signing-ran")
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_CONFIG_GLOBAL"] = configuration.path
        inherited["GIT_CONFIG_SYSTEM"] = configuration.path
        inherited["GIT_CONFIG_NOSYSTEM"] = "0"
        inherited["GIT_CONFIG_COUNT"] = "1"
        inherited["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        inherited["GIT_CONFIG_VALUE_0"] = hooks.path
        inherited["GIT_CONFIG_PARAMETERS"] = "'commit.gpgsign=true'"
        inherited["GITX_FIXTURE_HOOK_MARKER"] = hookMarker.path
        inherited["GITX_FIXTURE_SIGNING_MARKER"] = signingMarker.path
        let fixture = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/example/fixture.git", inheritedEnvironment: inherited)
        defer { fixture.cleanup() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: signingMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".git/inherited-template-marker").path))
        XCTAssertEqual(try fixture.repository.outputOfTask(withArguments: ["log", "-1", "--format=%s"]), "Fixture")
    }

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
        XCTAssertFalse(flow.isActive)
        try flow.beginOrdinaryPush(intent: intent)
        XCTAssertTrue(flow.isActive)
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

    func testCheckoutExecutorDoesNotPersistAnExactRefspecOnAnExistingRemote() throws {
        let fixture = try PullRequestAppFixture()
        let runner = RecordingPullRequestGitRunner(head: fixture.headCommit.value)
        let plan = try fixture.checkoutPlan(addsRemote: false)

        _ = try RepositoryPullRequestCheckoutExecutor(runner: runner).execute(plan)

        XCTAssertFalse(runner.commands.contains { $0.first == "config" })
        XCTAssertFalse(runner.commands.contains { $0.starts(with: ["remote", "add"]) })
        XCTAssertTrue(runner.commands.contains([
            "fetch", "--no-tags", plan.remote.name, plan.fetchRefspec,
        ]))
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

    func testCloneProcessRunnerReturnsSuccessfulGitOutput() throws {
        let output = try RepositoryForgeProcessGitRunner().run(["--version"])

        XCTAssertTrue(output.hasPrefix("git version "))
    }

    func testCloneProcessRunnerReportsExitStatusWithoutExposingGitDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXMissingCloneSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("missing-private-source", isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)

        XCTAssertThrowsError(try RepositoryForgeProcessGitRunner().run([
            "clone", "--", source.path, destination.path,
        ])) { error in
            XCTAssertEqual(error as? RepositoryForgeProcessError, .commandFailed(exitCode: 128))
            XCTAssertEqual(error.localizedDescription, "Git could not clone the repository (exit code 128).")
            XCTAssertFalse(error.localizedDescription.contains(source.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCloneLaunchErrorProvidesAnActionableDescriptionWithoutCommandDetails() {
        XCTAssertEqual(
            RepositoryForgeProcessError.launchFailed.localizedDescription,
            "Half Dark could not start Git for the clone operation."
        )
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
final class RepositoryMutationCompletionTests: XCTestCase {
    private enum OwnerState { case current, revoked, released }

    func testCompletionPreservesTheDraftWhenTheServerOutcomeHasAnotherRepository() async throws {
        for returnsIssue in [false, true] {
            let fixture = try DirectMutationFixture(started: expectation(description: "The captured server request executes once"))
            try await fixture.saveSubmittedDraft()
            let original = try await fixture.drafts.load(identity: fixture.identity)
            let destination: ForgeDestination = try returnsIssue
                ? .issue(fixture.app.repository, ForgeItemNumber(42))
                : .pullRequest(fixture.app.fork, ForgeItemNumber(42))
            await fixture.service.release(.created(destination))
            do {
                _ = try await fixture.operation.create(accountID: fixture.app.accountID, form: fixture.form, preparation: fixture.preparation)
                XCTFail("Only a Pull Request in the submitted repository can certify publication")
            } catch { XCTAssertEqual(error as? ForgePullRequestWorkflowError, .mismatchedRepository) }
            let retained = try await fixture.drafts.load(identity: fixture.identity)
            XCTAssertEqual(retained, original)
            let deletions = await fixture.drafts.conditionalDeletes
            XCTAssertEqual(deletions, 0)
            await fulfillment(of: [fixture.started], timeout: 5)
        }
    }

    func testCleanupFailurePreservesTheDraftAndTheActualSuccessfulResult() async throws {
        let fixture = try DirectMutationFixture(started: expectation(description: "The successful server request is not retried"))
        try await fixture.saveSubmittedDraft()
        let original = try await fixture.drafts.load(identity: fixture.identity)
        await fixture.drafts.failDeletion(true)
        await fixture.service.release(fixture.outcome)
        let actual = try await fixture.operation.create(accountID: fixture.app.accountID, form: fixture.form, preparation: fixture.preparation)
        XCTAssertEqual(actual, fixture.outcome)
        let retained = try await fixture.drafts.load(identity: fixture.identity)
        XCTAssertEqual(retained, original)
        let attempts = await fixture.service.createCount
        let deletions = await fixture.drafts.conditionalDeletes
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(deletions, 1)
        await fulfillment(of: [fixture.started], timeout: 5)
    }

    func testUnreadableSubmittedSnapshotDoesNotTurnServerSuccessIntoFailure() async throws {
        let fixture = try DirectMutationFixture(started: expectation(description: "A snapshot failure never resubmits the server request"))
        try await fixture.saveSubmittedDraft()
        let original = try await fixture.drafts.load(identity: fixture.identity)
        await fixture.drafts.failLoads(true)
        await fixture.service.release(fixture.outcome)
        let actual = try await fixture.operation.create(accountID: fixture.app.accountID, form: fixture.form, preparation: fixture.preparation)
        XCTAssertEqual(actual, fixture.outcome)
        await fixture.drafts.failLoads(false)
        let retained = try await fixture.drafts.load(identity: fixture.identity)
        let deletions = await fixture.drafts.conditionalDeletes
        XCTAssertEqual(retained, original)
        XCTAssertEqual(deletions, 0)
        await fulfillment(of: [fixture.started], timeout: 5)
    }

    func testMissingOrDifferentDraftContentSurvivesVerifiedPublication() async throws {
        for newer in [false, true] {
            let fixture = try DirectMutationFixture(started: expectation(description: "Publish without a matching snapshot"))
            if newer {
                try await fixture.drafts.save(identity: fixture.identity, content: ForgeDraftContent(title: "Other edit", body: "Keep this"), at: Date(timeIntervalSince1970: 100))
            }
            let original = try await fixture.drafts.load(identity: fixture.identity)
            await fixture.service.release(fixture.outcome)
            let actual = try await fixture.operation.create(accountID: fixture.app.accountID, form: fixture.form, preparation: fixture.preparation)
            XCTAssertEqual(actual, fixture.outcome)
            let retained = try await fixture.drafts.load(identity: fixture.identity)
            let deletions = await fixture.drafts.conditionalDeletes
            XCTAssertEqual(retained, original)
            XCTAssertEqual(deletions, 0)
            await fulfillment(of: [fixture.started], timeout: 5)
        }
    }

    func testFailedServerRequestPreservesItsOriginalDraftAndError() async throws {
        let fixture = try DirectMutationFixture(started: expectation(description: "The refused server request executes once"))
        try await fixture.saveSubmittedDraft()
        let original = try await fixture.drafts.load(identity: fixture.identity)
        await fixture.service.rejectMutations()
        do {
            _ = try await fixture.operation.create(accountID: fixture.app.accountID, form: fixture.form, preparation: fixture.preparation)
            XCTFail("The original server error must propagate")
        } catch { XCTAssertEqual(error as? CompletionFixtureError, .unavailable) }
        let retained = try await fixture.drafts.load(identity: fixture.identity)
        let deletions = await fixture.drafts.conditionalDeletes
        XCTAssertEqual(retained, original)
        XCTAssertEqual(deletions, 0)
        await fulfillment(of: [fixture.started], timeout: 5)
    }

    func testEditCompletionRejectsADifferentDestinationWithoutDeletingTheDraft() async throws {
        let fixture = try DirectMutationFixture(started: expectation(description: "The exact edit request executes once"))
        let snapshot = try ForgePullRequestEditableSnapshot(repository: fixture.app.repository, number: ForgeItemNumber(42), title: "Submitted", bodyMarkdown: "Text", updatedAt: Date(timeIntervalSince1970: 100))
        let identity = try RepositoryPullRequestDraftPolicy.editIdentity(accountID: fixture.app.accountID, snapshot: snapshot)
        let edit = try ForgePullRequestEdit(snapshot: snapshot, title: snapshot.title, bodyMarkdown: snapshot.bodyMarkdown)
        try await fixture.drafts.save(identity: identity, content: ForgeDraftContent(title: edit.title, body: edit.bodyMarkdown), at: snapshot.updatedAt)
        let original = try await fixture.drafts.load(identity: identity)
        try await fixture.service.releaseEdit(RepositoryPullRequestEditOutcome(snapshot: snapshot, destination: .pullRequest(fixture.app.repository, ForgeItemNumber(43))))
        do {
            _ = try await fixture.operation.edit(accountID: fixture.app.accountID, edit: edit, destination: .pullRequest(fixture.app.repository, snapshot.number), identity: identity)
            XCTFail("Another destination cannot certify this edit")
        } catch { XCTAssertEqual(error as? ForgePullRequestWorkflowError, .mismatchedRepository) }
        let retained = try await fixture.drafts.load(identity: identity)
        XCTAssertEqual(retained, original)
        await fulfillment(of: [fixture.started], timeout: 5)
    }

    func testConditionalDraftDeletionPreservesNewerEditsAndSupportsLegacyPayloadEncoding() async throws {
        let fixture = try PullRequestAppFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Conditional-draft-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(databaseURL: root.appendingPathComponent("Forge.sqlite3"), recoveryDirectoryURL: root.appendingPathComponent("Recovery")))
        let store = ForgeSQLitePullRequestDraftStore(database: database)
        let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: fixture.preparation())
        try await store.save(identity: identity, content: ForgeDraftContent(title: "Submitted", body: "Old"), at: Date(timeIntervalSince1970: 100))
        let loaded = try await store.load(identity: identity)
        let submitted = try XCTUnwrap(loaded)
        try await store.save(identity: identity, content: ForgeDraftContent(title: "Newer", body: "Keep"), at: Date(timeIntervalSince1970: 101))
        let stale = try await store.delete(identity: identity, matching: submitted)
        XCTAssertFalse(stale)
        let updated = try await store.load(identity: identity)
        let newer = try XCTUnwrap(updated)
        XCTAssertEqual(newer.content, ForgeDraftContent(title: "Newer", body: "Keep"))
        let wrongIdentity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .pullRequest(repository: fixture.repository, number: ForgeItemNumber(42)))
        let wrong = try await store.delete(identity: wrongIdentity, matching: newer)
        XCTAssertFalse(wrong)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyPayload = try encoder.encode(newer)
        let key = try ForgeSQLiteStore.encodedKey(identity)
        try await database.saveDurableRecord(ForgeSQLiteDurableRecord(kind: .draft, accountID: fixture.accountID, repository: fixture.repository, key: key, payload: legacyPayload, lastActivityAt: newer.lastActivityAt))
        let removed = try await store.delete(identity: identity, matching: newer)
        XCTAssertTrue(removed, "Deletion must use stored bytes rather than a freshly encoded snapshot")
        let missing = try await store.delete(identity: identity, matching: newer)
        XCTAssertFalse(missing)
        let absent = try await NullRepositoryPullRequestDraftStore().delete(identity: identity, matching: newer)
        XCTAssertFalse(absent)
        await database.close()
    }

    func testConditionalDraftDeletionProtectsMalformedMismatchedAndUnavailableStorage() async throws {
        let fixture = try PullRequestAppFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Protected-draft-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(databaseURL: root.appendingPathComponent("Forge.sqlite3"), recoveryDirectoryURL: root.appendingPathComponent("Recovery")))
        let store = ForgeSQLitePullRequestDraftStore(database: database)
        let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: fixture.preparation())
        let submitted = try ForgeDraft(identity: identity, content: ForgeDraftContent(title: "Submitted", body: "Text"), createdAt: Date(timeIntervalSince1970: 100), lastActivityAt: Date(timeIntervalSince1970: 100))
        let otherIdentity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .pullRequest(repository: fixture.repository, number: ForgeItemNumber(42)))
        let other = try ForgeDraft(identity: otherIdentity, content: submitted.content, createdAt: submitted.createdAt, lastActivityAt: submitted.lastActivityAt)
        let key = try ForgeSQLiteStore.encodedKey(identity)
        for (payload, mismatchedIdentity) in try [(JSONEncoder().encode(other), true), (Data("invalid JSON".utf8), false)] {
            try await database.saveDurableRecord(ForgeSQLiteDurableRecord(kind: .draft, accountID: fixture.accountID, repository: fixture.repository, key: key, payload: payload, lastActivityAt: submitted.lastActivityAt))
            do {
                _ = try await store.delete(identity: identity, matching: submitted)
                XCTFail("Invalid stored evidence cannot be deleted")
            } catch {
                if mismatchedIdentity {
                    XCTAssertEqual(error as? RepositoryPullRequestServiceError, .draftUnavailable)
                } else {
                    XCTAssertTrue(error is DecodingError)
                }
            }
            let retained = try await database.durableRecord(kind: .draft, accountID: fixture.accountID, repository: fixture.repository, key: key)
            XCTAssertEqual(retained?.payload, payload)
        }
        await database.close()
        do {
            _ = try await store.delete(identity: identity, matching: submitted)
            XCTFail("Storage errors must propagate")
        } catch ForgeSQLiteError.closed {
            // Closed storage must fail rather than silently preserve a success value.
        } catch { XCTFail("Expected closed storage, got \(error)") }
    }

    func testCreateSuccessDeletesTheSubmittedDraftBeforeOpeningItsDestination() async throws {
        try await characterizeSuccessfulCreation(existing: false)
    }

    func testExistingPullRequestDeletesTheSubmittedDraftWithoutCreatingAgain() async throws {
        try await characterizeSuccessfulCreation(existing: true)
    }

    func testSuccessfulCreateCleansItsDraftAfterOwnerRevocationWithoutPresentation() async throws {
        try await characterizeSuccessfulCreation(existing: false, ownerState: .revoked)
    }

    func testSuccessfulCreateCleansItsDraftAfterAllPresentationOwnersDeallocate() async throws {
        try await characterizeSuccessfulCreation(existing: false, ownerState: .released)
    }

    func testOutcomeCallbackRevocationPreventsLaterPresentationCallbacks() async throws {
        try await characterizeSuccessfulCreation(existing: false, revokeDuringOutcome: true)
    }

    func testSuccessfulCreatePreservesNewerDraftEdits() async throws {
        try await characterizeSuccessfulCreation(existing: false, newerDraft: true)
    }

    func testExplicitRevocationDisablesEveryWrappedPresentationCapability() throws {
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        defer { local.cleanup() }
        let window = NSWindow()
        let owner = PBGitWindowController(window: window)
        defer { owner.close() }
        let binding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: fixture.repository, preferredAccount: fixture.accountID)
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
        var openings = 0
        var fallbacks = 0
        let controller = RepositoryPullRequestUIController(repository: local.repository, windowController: owner,
                                                           remoteActions: RecordingRepositoryRemoteActions(events: []), service: FailingPreparationMutationService(),
                                                           destinationOpening: { _ in openings += 1; return true }, bindingResolving: { binding },
                                                           postPushBrowserFallback: { _ in fallbacks += 1 })
        controller.invalidateOwner()
        XCTAssertFalse(controller.destinationOpening(destination))
        XCTAssertNil(controller.bindingResolving())
        controller.postPushBrowserFallback(nil)
        XCTAssertEqual(openings, 0)
        XCTAssertEqual(fallbacks, 0)
    }

    func testEscapedPresentationCapabilitiesDoNotRetainOrOutliveTheirController() throws {
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        defer { local.cleanup() }
        let owner = PBGitWindowController(window: NSWindow())
        defer { owner.close() }
        let box = PullRequestBindingBox()
        let binding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: fixture.repository, preferredAccount: fixture.accountID)
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
        var openings = 0
        var fallbacks = 0
        var controller: RepositoryPullRequestUIController? = RepositoryPullRequestUIController(repository: local.repository, windowController: owner,
                                                                                               remoteActions: RecordingRepositoryRemoteActions(events: []), service: FailingPreparationMutationService(),
                                                                                               destinationOpening: { _ in openings += 1; return true }, bindingResolving: { box.binding },
                                                                                               postPushBrowserFallback: { _ in fallbacks += 1 })
        box.binding = binding
        let open = try XCTUnwrap(controller?.destinationOpening)
        let resolve = try XCTUnwrap(controller?.bindingResolving)
        let fallback = try XCTUnwrap(controller?.postPushBrowserFallback)
        XCTAssertNotNil(resolve())
        weak let weakController = controller
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertFalse(open(destination))
        XCTAssertNil(resolve())
        fallback(nil)
        XCTAssertEqual(openings, 0)
        XCTAssertEqual(fallbacks, 0)
    }

    func testVerifiedSuccessCleansItsDraftAfterCancellationDuringTheServerRequest() async throws {
        try await characterizeSuccessfulCreation(existing: false, cancelAfterAdmission: true)
    }

    func testEditSuccessCleansItsDraftForTheCurrentOwner() async throws {
        try await exerciseEdit(ownerState: .current)
    }

    func testEditSuccessCleansItsDraftAfterOwnerRevocation() async throws {
        try await exerciseEdit(ownerState: .revoked)
    }

    func testEditSuccessCleansItsDraftAfterPresentationDeallocation() async throws {
        try await exerciseEdit(ownerState: .released)
    }

    private func exerciseEdit(ownerState: OwnerState) async throws {
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        var owner: PBGitWindowController? = PBGitWindowController(window: window)
        weak let weakOwner = owner
        let started = expectation(description: "The edit reaches its captured service")
        let service = try CompletionMutationService(preparation: fixture.preparation(), started: started)
        let drafts = CompletionDraftStore()
        let snapshot = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(42), title: "Submitted edit", bodyMarkdown: "Submitted body", updatedAt: Date(timeIntervalSince1970: 100))
        let destination = ForgeDestination.pullRequest(fixture.repository, snapshot.number)
        let outcome = RepositoryPullRequestEditOutcome(snapshot: snapshot, destination: destination)
        let identity = try RepositoryPullRequestDraftPolicy.editIdentity(accountID: fixture.accountID, snapshot: snapshot)
        var openings: [ForgeDestination] = []
        var controller: RepositoryPullRequestUIController? = try RepositoryPullRequestUIController(repository: local.repository, windowController: XCTUnwrap(owner),
                                                                                                   remoteActions: RecordingRepositoryRemoteActions(events: []), service: service, drafts: drafts,
                                                                                                   destinationOpening: { openings.append($0); return true }, bindingResolving: { nil }, postPushBrowserFallback: { _ in XCTFail("An edit never opens push fallback") })
        weak let weakController = controller
        defer {
            Task { await service.releaseEdit(outcome) }
            controller?.invalidateOwner()
            owner?.close()
            window.close()
            local.cleanup()
        }
        window.makeKeyAndOrderFront(nil)
        controller?.editPullRequest(accountID: fixture.accountID, snapshot: snapshot, destination: destination)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let button = try XCTUnwrap(find("GitX.PullRequest.Submit", in: XCTUnwrap(sheet.contentView)) as? NSButton)
        button.performClick(nil)
        await fulfillment(of: [started], timeout: 5)
        let admitted = try XCTUnwrap(controller?.mutationTask)
        switch ownerState {
        case .current: break
        case .revoked: controller?.invalidateOwner()
        case .released:
            controller = nil
            owner = nil
            let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in weakController == nil && weakOwner == nil }, object: nil)
            await fulfillment(of: [released], timeout: 5)
        }
        await service.releaseEdit(outcome)
        let completed = expectation(description: "The admitted edit finishes cleanup")
        Task { await admitted.value; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        let stored = try await drafts.load(identity: identity)
        XCTAssertNil(stored)
        XCTAssertEqual(openings, ownerState == .current ? [destination] : [])
        let calls = await service.editCount
        XCTAssertEqual(calls, 1)
    }

    private func characterizeSuccessfulCreation(existing: Bool, ownerState: OwnerState = .current, newerDraft: Bool = false, cancelAfterAdmission: Bool = false, revokeDuringOutcome: Bool = false) async throws {
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        var owner: PBGitWindowController? = PBGitWindowController(window: window)
        weak let weakOwner = owner
        let preparation = try fixture.preparation()
        let form = try XCTUnwrap(preparation.initialForms().forms.first)
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(42))
        let outcome: RepositoryPullRequestCreationOutcome = existing ? .existing(destination) : .created(destination)
        let started = expectation(description: "The submitted mutation reaches its service")
        let service = CompletionMutationService(preparation: preparation, started: started)
        let drafts = CompletionDraftStore()
        let binding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: fixture.repository, preferredAccount: fixture.accountID)
        var outcomes: [RepositoryPullRequestCreationOutcome] = []
        var openings: [ForgeDestination] = []
        var controller: RepositoryPullRequestUIController? = try RepositoryPullRequestUIController(
            repository: local.repository, windowController: XCTUnwrap(owner),
            remoteActions: RecordingRepositoryRemoteActions(events: []), service: service, drafts: drafts,
            destinationOpening: { value in openings.append(value); return true },
            bindingResolving: { binding }, postPushBrowserFallback: { _ in XCTFail("Creation does not open a push fallback") }
        )
        defer {
            Task { await service.release(outcome) }
            controller?.invalidateOwner()
            owner?.close()
            window.close()
            local.cleanup()
        }
        weak let weakController = controller
        controller?.onCreationOutcome = { [weak controller] outcome in
            outcomes.append(outcome)
            if revokeDuringOutcome {
                controller?.invalidateOwner()
            }
        }
        var destinationCallbacks = 0
        controller?.onCreationDestinationOpened = { _, _ in destinationCallbacks += 1 }
        window.makeKeyAndOrderFront(nil)
        controller?.newPullRequest()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let submit = try XCTUnwrap(find("GitX.PullRequest.Submit", in: XCTUnwrap(sheet.contentView)) as? NSButton)
        submit.performClick(nil)
        await fulfillment(of: [started], timeout: 5)
        let identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        let pending = try await drafts.load(identity: identity)
        XCTAssertEqual(pending?.content, ForgeDraftContent(title: form.title, body: form.bodyMarkdown))
        let admittedTask = try XCTUnwrap(controller?.mutationTask)
        if cancelAfterAdmission {
            admittedTask.cancel()
        }
        if newerDraft {
            try await drafts.save(identity: identity, content: ForgeDraftContent(title: "Newer edit", body: "Keep this text"), at: Date().addingTimeInterval(10))
        }
        switch ownerState {
        case .current: break
        case .revoked: controller?.invalidateOwner()
        case .released:
            controller = nil
            owner = nil
            let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in weakController == nil && weakOwner == nil }, object: nil)
            await fulfillment(of: [released], timeout: 5)
        }
        await service.release(outcome)
        let completed = expectation(description: "The admitted mutation finishes its cleanup")
        Task { await admittedTask.value; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        let saved = try await drafts.load(identity: identity)
        if newerDraft {
            XCTAssertEqual(saved?.content, ForgeDraftContent(title: "Newer edit", body: "Keep this text"))
        } else {
            XCTAssertNil(saved)
        }
        XCTAssertEqual(outcomes, ownerState == .current && !cancelAfterAdmission ? [outcome] : [])
        XCTAssertEqual(openings, ownerState == .current && !cancelAfterAdmission && !revokeDuringOutcome ? [destination] : [])
        XCTAssertEqual(destinationCallbacks, ownerState == .current && !cancelAfterAdmission && !revokeDuringOutcome ? 1 : 0)
        let calls = await service.createCount
        XCTAssertEqual(calls, 1)
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}

@MainActor
final class RepositoryMutationPresentationTests: XCTestCase {
    func testDeferredRetriesRequireTheCurrentMutationAndExternalOwner() {
        var externalOwnerIsCurrent = true
        let authority = RepositoryPullRequestPresentationAuthority(validation: { externalOwnerIsCurrent })
        XCTAssertFalse(authority.permitsMutation(UUID()))
        let first = authority.beginMutation()
        var deliveries: [String] = []
        let oldRetry = authority.retry(for: first) { deliveries.append("first") }
        oldRetry()
        XCTAssertEqual(deliveries, ["first"])
        let second = authority.beginMutation()
        let newRetry = authority.retry(for: second) { deliveries.append("second") }
        oldRetry()
        XCTAssertEqual(deliveries, ["first"], "An earlier recovery sheet cannot resubmit a superseded mutation")
        externalOwnerIsCurrent = false
        newRetry()
        XCTAssertEqual(deliveries, ["first"])
        externalOwnerIsCurrent = true
        newRetry()
        XCTAssertEqual(deliveries, ["first", "second"])
    }

    func testRevocationCannotBeUndoneByAnotherMutationOrAnUnchangedRawOwner() {
        let authority = RepositoryPullRequestPresentationAuthority(validation: { true })
        let submitted = authority.beginMutation()
        var calls = 0
        let retry = authority.retry(for: submitted) { calls += 1 }
        XCTAssertTrue(authority.permitsMutation(submitted))
        authority.revoke()
        retry()
        let later = authority.beginMutation()
        let laterRetry = authority.retry(for: later) { calls += 1 }
        laterRetry()
        XCTAssertFalse(authority.isCurrent)
        XCTAssertFalse(authority.permitsMutation(submitted))
        XCTAssertFalse(authority.permitsMutation(later))
        XCTAssertEqual(calls, 0)
    }
}

private enum CompletionFixtureError: Error, Equatable { case unavailable }

@MainActor
private struct DirectMutationFixture {
    let started: XCTestExpectation
    let app: PullRequestAppFixture
    let preparation: RepositoryPullRequestCreationPreparation
    let form: ForgePullRequestCreationForm
    let identity: ForgeDraftIdentity
    let outcome: RepositoryPullRequestCreationOutcome
    let service: CompletionMutationService
    let drafts: CompletionDraftStore
    var operation: RepositoryPullRequestMutationCompletion {
        .init(service: service, drafts: drafts)
    }

    init(started: XCTestExpectation) throws {
        self.started = started
        drafts = CompletionDraftStore()
        app = try PullRequestAppFixture()
        preparation = try app.preparation()
        form = try XCTUnwrap(preparation.initialForms().forms.first)
        identity = try RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
        outcome = try .created(.pullRequest(app.repository, ForgeItemNumber(42)))
        service = CompletionMutationService(preparation: preparation, started: started)
    }

    func saveSubmittedDraft() async throws {
        try await drafts.save(identity: identity, content: ForgeDraftContent(title: form.title, body: form.bodyMarkdown), at: Date(timeIntervalSince1970: 100))
    }
}

private actor CompletionDraftStore: RepositoryPullRequestDraftPersisting {
    init() {}
    private var values: [ForgeDraftIdentity: ForgeDraft] = [:]
    private var loadsFail = false
    private var deletionFails = false
    private(set) var conditionalDeletes = 0

    func failLoads(_ value: Bool) {
        loadsFail = value
    }

    func failDeletion(_ value: Bool) {
        deletionFails = value
    }

    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft? {
        if loadsFail {
            throw CompletionFixtureError.unavailable
        }
        return values[identity]
    }

    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws {
        values[identity] = try ForgeDraft(identity: identity, content: content, createdAt: values[identity]?.createdAt ?? date, lastActivityAt: date)
    }

    func delete(identity: ForgeDraftIdentity, matching snapshot: ForgeDraft) async throws -> Bool {
        conditionalDeletes += 1
        try Task.checkCancellation()
        if deletionFails {
            throw CompletionFixtureError.unavailable
        }
        guard snapshot.identity == identity, values[identity] == snapshot else { return false }
        values[identity] = nil
        return true
    }

    func delete(identity: ForgeDraftIdentity) async throws {
        values[identity] = nil
    }
}

private actor CompletionMutationService: RepositoryPullRequestMutationServing {
    let preparation: RepositoryPullRequestCreationPreparation
    let started: XCTestExpectation
    let gate = IgnoringCancellationGate<RepositoryPullRequestCreationOutcome>()
    private(set) var createCount = 0
    private(set) var editCount = 0
    let editGate = IgnoringCancellationGate<RepositoryPullRequestEditOutcome>()
    private var rejectsMutation = false

    func rejectMutations() {
        rejectsMutation = true
    }

    init(preparation: RepositoryPullRequestCreationPreparation, started: XCTestExpectation) {
        self.preparation = preparation
        self.started = started
    }

    func release(_ outcome: RepositoryPullRequestCreationOutcome) async {
        await gate.release(outcome)
    }

    func capabilities(accountID _: ForgeAccountID, repository _: ForgeRepositoryIdentity, operations: Set<ForgeOperation>) async throws -> [ForgeOperation: ForgeOperationCapability] {
        Dictionary(uniqueKeysWithValues: operations.map { ($0, .verified(.knownAuthority)) })
    }

    func prepareCreation(repository _: ForgeRepositoryIdentity, localBranch _: ForgeRefName, localHead _: ForgeCommitID) async throws -> RepositoryPullRequestCreationPreparation {
        preparation
    }

    func createPullRequest(accountID _: ForgeAccountID, form _: ForgePullRequestCreationForm) async throws -> RepositoryPullRequestCreationOutcome {
        createCount += 1
        started.fulfill()
        if rejectsMutation {
            throw CompletionFixtureError.unavailable
        }
        return await gate.wait()
    }

    func editPullRequest(accountID _: ForgeAccountID, edit _: ForgePullRequestEdit) async throws -> RepositoryPullRequestEditOutcome {
        editCount += 1
        started.fulfill()
        if rejectsMutation {
            throw CompletionFixtureError.unavailable
        }
        return await editGate.wait()
    }

    func releaseEdit(_ outcome: RepositoryPullRequestEditOutcome) async {
        await editGate.release(outcome)
    }

    func syncFork(accountID _: ForgeAccountID, plan _: ForgeSyncForkPlan) async throws -> RepositorySyncForkOutcome {
        throw CompletionError.unexpected
    }

    private enum CompletionError: Error { case unexpected }
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
        let writePreview = try XCTUnwrap(
            descendant("GitX.PullRequest.WritePreview", in: view) as? NSSegmentedControl
        )
        let preview = try XCTUnwrap(descendant("GitX.PullRequest.Preview", in: view))
        XCTAssertEqual(title.stringValue, "Draft title")
        XCTAssertEqual(body.string, "Draft body")
        writePreview.selectedSegment = 1
        writePreview.sendAction(writePreview.action, to: writePreview.target)
        XCTAssertFalse(preview.isHidden)
        XCTAssertEqual(preview.subviews.count, 1)
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

    @MainActor
    func testPartialPatchCopyWarningUsesDismissibleMessageSheet() throws {
        let result = CommitPatchCopyResult(patches: ["first", nil, "last"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let controller = PBGitWindowController(window: window)
        window.makeKeyAndOrderFront(nil)
        try controller.showMessageSheet(XCTUnwrap(result.warningMessage), infoText: result.warningInfo)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.attachedSheet?.isVisible == true
        }, object: nil)
        wait(for: [ready], timeout: 5)
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.contentView?.displayIfNeeded()
        window.endSheet(sheet)
        window.close()
    }

    @MainActor
    func testFrozenLeaseRetryAlertShowsSourceDestinationAndProtection() {
        let alert = RepositoryPushConfirmationPresenter.retryAlert(branch: "feature/rewrite", remote: "origin", destinationRef: "refs/heads/review/rewrite",
                                                                   sourceOID: "7b1c2a9a638c04110f0ec4fcb4de55a3c7901728", fetchedOID: "b2ee9100ca63e8c1a65766cb5dbf5ec33041a9bf")
        XCTAssertEqual(alert.messageText, "Replace remote branch 'review/rewrite'?")
        XCTAssertTrue(alert.informativeText.contains("local branch 'feature/rewrite'"))
        XCTAssertFalse(alert.showsSuppressionButton)
        XCTAssertEqual(alert.buttons.map(\.title), ["Push with Lease", "Cancel"])
        XCTAssertEqual(alert.buttons.first?.accessibilityIdentifier(), "GitX.Push.RetryWithLease")
        XCTAssertTrue(alert.informativeText.contains("newer remote work"))
        alert.layout()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.contentView?.displayIfNeeded()
        alert.window.close()
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
        defer {
            task.cancel()
            runner.releaseFirstCommand()
        }

        guard runner.waitUntilFirstCommandStarts(timeout: 2) else {
            task.cancel()
            runner.releaseFirstCommand()
            _ = try? await task.value
            XCTFail("Local Git preparation did not enter the controlled command")
            return
        }
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

    func testCancelledOwnershipCancelsATaskInstalledAfterCancellation() async throws {
        let ownership = RepositoryPullRequestPreparationTaskOwnership()
        let cancellation = PullRequestPreparationCancellationProbe()
        let task = Task.detached { () throws -> RepositoryPullRequestCreationPreparation in
            try await cancellation.wait()
            throw CancellationError()
        }
        let cancellationProbeStarted = await cancellation.waitUntilStarted()
        XCTAssertTrue(cancellationProbeStarted)

        ownership.cancel()
        ownership.install(task)
        let cancellationWasObserved = await cancellation.waitForCancellation()
        XCTAssertTrue(cancellationWasObserved, "Installing into cancelled ownership must cancel immediately")
        if !cancellationWasObserved {
            await cancellation.releaseForCleanup()
        }
        do {
            _ = try await task.value
            XCTFail("A task installed after parent cancellation must be cancelled immediately")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
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

private actor PullRequestPreparationCancellationProbe {
    private var started = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            let _: Void = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                started = true
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !started {
            guard clock.now < deadline else {
                releaseForCleanup()
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func waitForCancellation() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !cancelled {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func releaseForCleanup() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func cancel() {
        guard !cancelled else { return }
        cancelled = true
        continuation?.resume(throwing: CancellationError())
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
    func delete(identity _: ForgeDraftIdentity, matching _: ForgeDraft) async throws -> Bool {
        false
    }

    func delete(identity _: ForgeDraftIdentity) async throws {}
}

private struct GatedPullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    let gate: IgnoringCancellationGate<ForgeDraft?>

    func load(identity _: ForgeDraftIdentity) async throws -> ForgeDraft? {
        await gate.wait()
    }

    func save(identity _: ForgeDraftIdentity, content _: ForgeDraftContent, at _: Date) async throws {}
    func delete(identity _: ForgeDraftIdentity, matching _: ForgeDraft) async throws -> Bool {
        false
    }

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

    init(remoteURL: String, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitX-PullRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.runGit(["init", "--quiet", "--initial-branch=main"], in: directory, inheritedEnvironment: inheritedEnvironment)
            try Self.runGit(["config", "user.name", "GitX Tests"], in: directory, inheritedEnvironment: inheritedEnvironment)
            try Self.runGit(["config", "user.email", "gitx-tests@example.invalid"], in: directory, inheritedEnvironment: inheritedEnvironment)
            try "fixture\n".write(
                to: directory.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Self.runGit(["add", "tracked.txt"], in: directory, inheritedEnvironment: inheritedEnvironment)
            try Self.runGit(["commit", "--quiet", "-m", "Fixture"], in: directory, inheritedEnvironment: inheritedEnvironment)
            try Self.runGit(["remote", "add", "origin", remoteURL], in: directory, inheritedEnvironment: inheritedEnvironment)
            repository = try GitXTestGitRepository(url: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() {
        repository.revisionList?.cleanup()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func runGit(_ arguments: [String], in directory: URL, inheritedEnvironment: [String: String]) throws {
        try GitXTestGitFixture.run(arguments, in: directory, inheritedEnvironment: inheritedEnvironment)
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
