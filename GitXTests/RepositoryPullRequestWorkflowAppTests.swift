import AppKit
import ForgeKit
import GitHubForgeAdapter
import XCTest

final class RepositoryPullRequestWorkflowAppTests: XCTestCase {
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
        XCTAssertEqual(title.stringValue, "Restored")
        XCTAssertEqual(body.string, "Body")
        XCTAssertEqual(draft.state, .off)
        XCTAssertEqual(submit.accessibilityLabel(), "Create Pull Request")

        var submitted: ForgePullRequestCreationForm?
        controller.onSubmit = { submission in
            guard case let .create(_, form) = submission else { return }
            submitted = form
        }
        submit.performClick(nil)
        XCTAssertEqual(submitted?.title, "Restored")
        XCTAssertFalse(try XCTUnwrap(submitted).isDraft)
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

        let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let sshChoice = try controller.selectedChoice(destinationDirectory: destination)
        XCTAssertEqual(sshChoice.request.transport, .ssh)
        XCTAssertEqual(sshChoice.request.relationship, .owned)
        ssh.state = .off
        XCTAssertEqual(try controller.selectedChoice(destinationDirectory: destination).request.transport, .https)
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
            ["remote", "get-url", "fork"]: "git@github.com:contributor/repo.git\n",
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
                rateLimit: GitHubRateLimitMetadata(
                    limit: 5000,
                    remaining: 0,
                    used: 5000,
                    resetAt: deadline,
                    retryAt: nil,
                    resource: "graphql"
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

private struct StubPullRequestMutationService: RepositoryPullRequestMutationServing {
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

    func preparation() throws -> RepositoryPullRequestCreationPreparation {
        try RepositoryPullRequestCreationPreparation(
            accountID: accountID,
            repository: repository,
            base: base,
            head: head,
            branchAlreadyPushed: true,
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
