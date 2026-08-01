import ForgeKit
import Foundation
import GitHubForgeAdapter
import XCTest

final class GitHubReadCompositionTests: XCTestCase {
    override func tearDown() {
        CompositionGitHubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testAuthorityRequiresExactCurrentGitHubCredentialAndRejectsExpiredOrMalformedSecrets() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-1")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat-1"),
            kind: .fineGrained,
            token: Data("github_pat_byte-safe".utf8),
            expiresAt: Date(timeIntervalSince1970: 2000)
        )
        let authority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let authentication = try await authority.currentAuthentication(
            for: account.currentCredential.reference
        )
        XCTAssertEqual(authentication?.account, account)
        XCTAssertEqual(authentication?.credential, account.currentCredential)

        let staleReference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("pat-1"),
            generation: ForgeCredentialGeneration(2)
        )
        let staleAuthentication = try await authority.currentAuthentication(for: staleReference)
        XCTAssertNil(staleAuthentication)

        let expiredAuthority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            now: { Date(timeIntervalSince1970: 2000) }
        )
        let expiredAuthentication = try await expiredAuthority.currentAuthentication(
            for: account.currentCredential.reference
        )
        XCTAssertNil(expiredAuthentication)
        do {
            let requestURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/hbmartin/gitx"))
            _ = try await expiredAuthority.authorizedRequest(
                URLRequest(url: requestURL),
                for: account.currentCredential.reference
            )
            XCTFail("expired credentials must fail before an authorized request is returned")
        } catch {
            XCTAssertEqual(
                error as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }

        let gitLabReference = try makeCredentialReference(
            kind: .gitLab,
            host: "gitlab.com",
            account: "gitlab-node"
        )
        let crossForgeAuthentication = try await authority.currentAuthentication(for: gitLabReference)
        XCTAssertNil(crossForgeAuthentication)
        XCTAssertEqual(
            ForgeGitHubReadCompositionError.githubDotComCredentialRequired.errorDescription,
            "GitHub reads require a GitHub.com Credential."
        )
        do {
            _ = try await authority.credentialChange(for: gitLabReference)
            XCTFail("cross-forge invalidation must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }
        do {
            _ = try await authority.refreshCredentialIfNeeded(
                for: gitLabReference,
                at: Date(timeIntervalSince1970: 1000)
            )
            XCTFail("cross-forge refresh must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }
        XCTAssertThrowsError(
            try ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
                .makeAdapter(for: gitLabReference)
        ) {
            XCTAssertEqual(
                $0 as? ForgeGitHubReadCompositionError,
                .githubDotComCredentialRequired
            )
        }

        try keychain.replaceAccessToken(
            with: Data([0xFF]),
            accountKey: ForgeAccountStore.keychainAccountKey(for: accountID)
        )
        do {
            _ = try await authority.currentAuthentication(for: account.currentCredential.reference)
            XCTFail("malformed GitHub token bytes must fail before transport creation")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .invalidSecret)
            XCTAssertFalse(error.localizedDescription.contains("byte-safe"))
        }
    }

    func testRetainedAdapterUsesRotatedTokenThenRejectsReplacementAndRemovalBeforeNetwork() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-rotation")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("app-credential"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: Date.distantFuture,
            secrets: rotatingSecrets(access: "original-access", refresh: "original-refresh")
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 401, body: Data())
        }
        let adapter = try factory.makeAdapter(
            for: original.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )

        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(capture.authorizationHeaders, ["Bearer original-access"])
        let addedChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(addedChange.revision, 1)

        let rotated = try await accountStore.rotateCredential(
            expectedReference: original.currentCredential.reference,
            expiresAt: Date.distantFuture,
            secrets: rotatingSecrets(access: "rotated-access", refresh: "rotated-refresh")
        )
        XCTAssertEqual(rotated.currentCredential.reference, original.currentCredential.reference)
        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(
            capture.authorizationHeaders,
            ["Bearer original-access", "Bearer rotated-access"]
        )
        let rotatedChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(rotatedChange.revision, 2)

        let replacement = try await accountStore.replaceCredential(
            expectedReference: original.currentCredential.reference,
            credentialID: ForgeCredentialID("replacement-pat"),
            source: .classicPersonalAccessToken,
            expiresAt: nil,
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("replacement-access".utf8))
        )
        await assertAuthenticationFailure(adapter)
        XCTAssertEqual(capture.authorizationHeaders.count, 2, "replacement must reject before transport")
        let replacementChange = try await factory.credentialChange(for: original.currentCredential.reference)
        XCTAssertEqual(
            replacementChange,
            ForgeAccountCredentialChange(
                accountID: accountID,
                currentReference: replacement.currentCredential.reference,
                revision: 3
            )
        )

        let replacementAdapter = try factory.makeAdapter(
            for: replacement.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        await assertAuthenticationFailure(replacementAdapter)
        XCTAssertEqual(capture.authorizationHeaders.last, "Bearer replacement-access")

        try await accountStore.removeAccount(accountID)
        await assertAuthenticationFailure(replacementAdapter)
        XCTAssertEqual(capture.authorizationHeaders.count, 3, "removal must reject before transport")
        let removedChange = try await factory.credentialChange(for: replacement.currentCredential.reference)
        XCTAssertEqual(
            removedChange,
            ForgeAccountCredentialChange(accountID: accountID, currentReference: nil, revision: 4)
        )
    }

    func testRuntimeRefreshRotatesBeforeExplicitAndReadAuthorizationWhileRetainingIdentity() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("runtime-background-refresh")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now.addingTimeInterval(-1),
            secrets: rotatingSecrets(access: "expired-runtime-access", refresh: "runtime-refresh")
        )
        let rotated = try rotatingCredential(
            access: "fresh-runtime-access",
            refresh: "fresh-runtime-refresh",
            accessExpiresAt: now.addingTimeInterval(3600),
            refreshExpiresAt: now.addingTimeInterval(7200)
        )
        let refresher = StubRuntimeCredentialRefresher(result: .refreshed(rotated))
        let runtimeRefresh = try ForgeAccountCredentialRefreshCoordinator(
            accountStore: accountStore,
            configuration: testApplicationConfiguration(),
            refresherFactory: { _ in refresher }
        )
        let authority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            credentialRefreshCoordinator: runtimeRefresh,
            now: { now }
        )
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)

        let explicitlyRefreshedAccount = try await factory.refreshCredentialIfNeeded(
            for: original.currentCredential.reference,
            at: now
        )
        XCTAssertEqual(explicitlyRefreshedAccount?.currentCredential.reference, original.currentCredential.reference)
        XCTAssertEqual(explicitlyRefreshedAccount?.currentCredential.expiresAt, rotated.accessTokenExpiresAt)

        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 401, body: Data())
        }
        let adapter = try factory.makeAdapter(
            for: original.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        await assertAuthenticationFailure(adapter)

        XCTAssertEqual(capture.authorizationHeaders, ["Bearer fresh-runtime-access"])
        let explicitAndReadRefreshCalls = await refresher.callCount()
        XCTAssertEqual(
            explicitAndReadRefreshCalls,
            2,
            "the second deterministic decision must use current material"
        )
        let change = try await accountStore.credentialChange(for: accountID)
        XCTAssertEqual(change.currentReference, original.currentCredential.reference)
        XCTAssertEqual(change.revision, 2)
        assertRedacted(runtimeRefresh, forbidden: "runtime-refresh")
    }

    func testConcurrentRuntimeRefreshPersistsOneExactIncarnationRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let accountStore = ForgeAccountStore(keychain: ReadCompositionKeychain())
        let accountID = try makeAccountID("runtime-concurrent-refresh")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now,
            secrets: rotatingSecrets(access: "concurrent-old-access", refresh: "concurrent-old-refresh")
        )
        let rotated = try rotatingCredential(
            access: "concurrent-new-access",
            refresh: "concurrent-new-refresh",
            accessExpiresAt: now.addingTimeInterval(3600),
            refreshExpiresAt: now.addingTimeInterval(7200)
        )
        let refresher = ControllableRuntimeCredentialRefresher(result: .refreshed(rotated))
        let coordinator = try ForgeAccountCredentialRefreshCoordinator(
            accountStore: accountStore,
            configuration: testApplicationConfiguration(),
            refresherFactory: { _ in refresher }
        )

        let first = Task {
            try await coordinator.credential(for: original.currentCredential.reference, at: now)
        }
        await refresher.waitUntilCallCount(1)
        let second = Task {
            try await coordinator.credential(for: original.currentCredential.reference, at: now)
        }
        await refresher.waitUntilCallCount(2)
        let concurrentCalls = await refresher.callCount()
        XCTAssertEqual(concurrentCalls, 2)
        await refresher.releaseAll()
        let (firstResult, secondResult) = try await(first.value, second.value)

        XCTAssertEqual(
            [firstResult, secondResult].compactMap { $0 }.count,
            2,
            "both concurrent consumers must reuse the one persisted rotation"
        )
        let change = try await accountStore.credentialChange(for: accountID)
        XCTAssertEqual(change.revision, 2, "coalesced results must persist one rotation")
        let storedCredential = try await accountStore.credential(for: accountID)
        let stored = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            stored.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("concurrent-new-access".utf8)
        )
    }

    func testCancelledRuntimeRefreshDoesNotPersistRotatedCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        let accountStore = ForgeAccountStore(keychain: ReadCompositionKeychain())
        let accountID = try makeAccountID("runtime-cancelled-refresh")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now,
            secrets: rotatingSecrets(access: "cancel-old-access", refresh: "cancel-old-refresh")
        )
        let rotated = try rotatingCredential(
            access: "cancel-new-access",
            refresh: "cancel-new-refresh",
            accessExpiresAt: now.addingTimeInterval(3600),
            refreshExpiresAt: now.addingTimeInterval(7200)
        )
        let refresher = ControllableRuntimeCredentialRefresher(result: .refreshed(rotated))
        let coordinator = try ForgeAccountCredentialRefreshCoordinator(
            accountStore: accountStore,
            configuration: testApplicationConfiguration(),
            refresherFactory: { _ in refresher }
        )
        let task = Task {
            try await coordinator.credential(for: original.currentCredential.reference, at: now)
        }
        await refresher.waitUntilCallCount(1)

        task.cancel()
        await refresher.releaseAll()
        do {
            _ = try await task.value
            XCTFail("cancellation before persistence must reject the refresh")
        } catch is CancellationError {
            // Expected.
        }
        let change = try await accountStore.credentialChange(for: accountID)
        XCTAssertEqual(change.revision, 1)
        let storedCredential = try await accountStore.credential(for: accountID)
        let stored = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            stored.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("cancel-old-access".utf8)
        )
    }

    func testInFlightRefreshCannotOverwriteRemovedAndReaddedCredentialIncarnation() async throws {
        let now = Date(timeIntervalSince1970: 2_300_000_000)
        let accountStore = ForgeAccountStore(keychain: ReadCompositionKeychain())
        let accountID = try makeAccountID("runtime-refresh-aba")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now,
            secrets: rotatingSecrets(access: "aba-old-access", refresh: "aba-old-refresh")
        )
        let rotated = try rotatingCredential(
            access: "aba-stale-rotated-access",
            refresh: "aba-stale-rotated-refresh",
            accessExpiresAt: now.addingTimeInterval(3600),
            refreshExpiresAt: now.addingTimeInterval(7200)
        )
        let refresher = ControllableRuntimeCredentialRefresher(result: .refreshed(rotated))
        let coordinator = try ForgeAccountCredentialRefreshCoordinator(
            accountStore: accountStore,
            configuration: testApplicationConfiguration(),
            refresherFactory: { _ in refresher }
        )
        let refreshTask = Task {
            try await coordinator.credential(for: original.currentCredential.reference, at: now)
        }
        await refresher.waitUntilCallCount(1)

        try await accountStore.removeAccount(accountID)
        let readded = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now.addingTimeInterval(1800),
            secrets: rotatingSecrets(access: "aba-new-access", refresh: "aba-new-refresh")
        )
        XCTAssertEqual(readded.currentCredential.reference, original.currentCredential.reference)
        await refresher.releaseAll()

        let staleResult = try await refreshTask.value
        XCTAssertNil(staleResult)
        let change = try await accountStore.credentialChange(for: accountID)
        XCTAssertEqual(change.revision, 3)
        let storedCredential = try await accountStore.credential(for: accountID)
        let stored = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            stored.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("aba-new-access".utf8)
        )
    }

    func testMutationRefreshesExpiredDeviceFlowCredentialBeforeTransportWithoutChangingSessionIdentity() async throws {
        let now = Date(timeIntervalSince1970: 3_000_000_000)
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("runtime-mutation-refresh")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now,
            secrets: rotatingSecrets(access: "expired-mutation-access", refresh: "mutation-refresh")
        )
        let rotated = try rotatingCredential(
            access: "fresh-mutation-access",
            refresh: "fresh-mutation-refresh",
            accessExpiresAt: now.addingTimeInterval(3600),
            refreshExpiresAt: now.addingTimeInterval(7200)
        )
        let refresher = StubRuntimeCredentialRefresher(result: .refreshed(rotated))
        let authority = try ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            credentialRefreshCoordinator: ForgeAccountCredentialRefreshCoordinator(
                accountStore: accountStore,
                configuration: testApplicationConfiguration(),
                refresherFactory: { _ in refresher }
            ),
            now: { now }
        )
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 401, body: Data())
        }
        let repository = try makeRepository()
        let sessionGate = GitHubMutationSessionGate()
        let adapter = try factory.makeMutationAdapter(
            for: original.currentCredential.reference,
            sessionGate: sessionGate,
            sessionConfiguration: stubConfiguration()
        )
        let authorization = try GitHubMutationAuthorization(
            key: ForgeCapabilityKey(
                credential: original.currentCredential.reference,
                repository: repository,
                operation: .createPullRequest
            ),
            capability: .verified(.knownAuthority)
        )
        let form = try ForgePullRequestCreationForm(
            repository: repository,
            base: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("master"),
                commit: ForgeCommitID("12345678")
            ),
            head: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("runtime-refresh"),
                commit: ForgeCommitID("abcdef12")
            ),
            title: "Runtime refresh",
            bodyMarkdown: "Credential rotation proof"
        )

        do {
            _ = try await adapter.createPullRequest(
                accountID: accountID,
                form: form,
                authorization: authorization
            )
            XCTFail("the deterministic 401 fixture must reject the mutation")
        } catch {
            // The transport rejection is expected; authentication must have refreshed first.
        }
        XCTAssertEqual(capture.authorizationHeaders, ["Bearer fresh-mutation-access"])
        let mutationRefreshCalls = await refresher.callCount()
        XCTAssertEqual(mutationRefreshCalls, 1)
        let environment = await sessionGate.environment(
            for: original.currentCredential.reference,
            at: now
        )
        XCTAssertEqual(environment, .available)
        let storedReference = try await accountStore.credential(for: accountID)?
            .account.currentCredential.reference
        XCTAssertEqual(storedReference, original.currentCredential.reference)
    }

    func testMutationSessionGateStopsOfflineAndCooldownBeforeCredentialRefresh() async throws {
        let now = Date(timeIntervalSince1970: 3_100_000_000)
        let accountStore = ForgeAccountStore(keychain: ReadCompositionKeychain())
        let accountID = try makeAccountID("runtime-mutation-gate")
        let original = try await accountStore.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now,
            secrets: rotatingSecrets(access: "gated-old-access", refresh: "gated-old-refresh")
        )
        let rotated = try rotatingCredential(
            access: "gated-new-access",
            refresh: "gated-new-refresh",
            accessExpiresAt: Date.distantFuture.addingTimeInterval(-3600),
            refreshExpiresAt: Date.distantFuture
        )
        let refresher = StubRuntimeCredentialRefresher(result: .refreshed(rotated))
        let authority = try ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            credentialRefreshCoordinator: ForgeAccountCredentialRefreshCoordinator(
                accountStore: accountStore,
                configuration: testApplicationConfiguration(),
                refresherFactory: { _ in refresher }
            ),
            now: { now }
        )
        let sessionGate = GitHubMutationSessionGate()
        let adapter = try ForgeGitHubReadAdapterFactory(credentialAuthority: authority).makeMutationAdapter(
            for: original.currentCredential.reference,
            sessionGate: sessionGate,
            sessionConfiguration: stubConfiguration()
        )
        let repository = try makeRepository()
        let authorization = try GitHubMutationAuthorization(
            key: ForgeCapabilityKey(
                credential: original.currentCredential.reference,
                repository: repository,
                operation: .createPullRequest
            ),
            capability: .verified(.knownAuthority)
        )
        let form = try ForgePullRequestCreationForm(
            repository: repository,
            base: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("master"),
                commit: ForgeCommitID("12345678")
            ),
            head: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("runtime-gate"),
                commit: ForgeCommitID("abcdef12")
            ),
            title: "Runtime gate",
            bodyMarkdown: "No refresh while gated"
        )

        await sessionGate.setOffline(true)
        do {
            _ = try await adapter.createPullRequest(
                accountID: accountID,
                form: form,
                authorization: authorization
            )
            XCTFail("offline mutation must fail before Credential refresh")
        } catch {
            XCTAssertEqual(error as? GitHubMutationError, .offline)
        }
        let callsWhileOffline = await refresher.callCount()
        XCTAssertEqual(callsWhileOffline, 0)

        await sessionGate.setOffline(false)
        let deadline = Date.distantFuture
        await sessionGate.recordCooldown(for: original.currentCredential.reference, until: deadline)
        do {
            _ = try await adapter.createPullRequest(
                accountID: accountID,
                form: form,
                authorization: authorization
            )
            XCTFail("cooldown must fail before Credential refresh")
        } catch {
            XCTAssertEqual(error as? GitHubMutationError, .cooldown(until: deadline))
        }
        let callsDuringCooldown = await refresher.callCount()
        XCTAssertEqual(callsDuringCooldown, 0)
    }

    func testProcessCredentialCooldownBlocksEveryAuthenticatedReadAdapterButNotAnotherCredential() async throws {
        let accountStore = ForgeAccountStore(keychain: ReadCompositionKeychain())
        let blockedAccountID = try makeAccountID("shared-read-cooldown-blocked")
        let blockedAccount = try await accountStore.addPersonalAccessToken(
            accountID: blockedAccountID,
            login: "blocked-reader",
            credentialID: ForgeCredentialID("blocked-read-pat"),
            kind: .fineGrained,
            token: Data("blocked-read-access".utf8),
            expiresAt: nil
        )
        let availableAccountID = try makeAccountID("shared-read-cooldown-available")
        let availableAccount = try await accountStore.addPersonalAccessToken(
            accountID: availableAccountID,
            login: "available-reader",
            credentialID: ForgeCredentialID("available-read-pat"),
            kind: .fineGrained,
            token: Data("available-read-access".utf8),
            expiresAt: nil
        )
        let sessionGate = GitHubMutationSessionGate()
        let factory = ForgeGitHubReadAdapterFactory(
            credentialAuthority: ForgeGitHubReadCredentialAuthority(accountStore: accountStore),
            sessionGate: sessionGate
        )
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(
                status: 200,
                body: Self.readSurfaceResponse(for: Self.operationName(from: request))
            )
        }
        let blockedReference = blockedAccount.currentCredential.reference
        let deadline = Date.distantFuture
        await sessionGate.recordCooldown(
            for: blockedReference,
            until: deadline
        )

        for adapter in try [
            factory.makeAdapter(
                for: blockedReference,
                sessionConfiguration: stubConfiguration()
            ),
            factory.makeAdapter(
                for: blockedReference,
                sessionConfiguration: stubConfiguration()
            ),
        ] {
            do {
                _ = try await adapter.pullRequests(repository: makeRepository())
                XCTFail("every adapter rebound to the throttled Credential must remain paused")
            } catch let GitHubReadError.rateLimited(response) {
                XCTAssertEqual(response.rateLimit.retryAt, deadline)
            } catch {
                XCTFail("unexpected cooldown error: \(error)")
            }
        }
        XCTAssertEqual(
            capture.authorizationHeaders,
            [],
            "a shared Credential cooldown must stop reads before Keychain or network access"
        )

        let availableAdapter = try factory.makeAdapter(
            for: availableAccount.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        _ = try await availableAdapter.pullRequests(repository: makeRepository())
        XCTAssertEqual(capture.authorizationHeaders, ["Bearer available-read-access"])

        await sessionGate.recordCooldown(for: blockedReference, until: nil)
    }

    func testRuntimeRefreshFailsClosedAfterReauthorizationAndDoesNotRefreshOtherCredentialKinds() async throws {
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let deviceAccountID = try makeAccountID("runtime-reauthorization")
        let deviceAccount = try await accountStore.addAccount(
            accountID: deviceAccountID,
            login: "device-user",
            credentialID: ForgeCredentialID("github-app:test"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: now.addingTimeInterval(-1),
            secrets: rotatingSecrets(access: "expired-device-access", refresh: "expired-device-refresh")
        )
        let patAccountID = try makeAccountID("runtime-expired-pat")
        let patAccount = try await accountStore.addPersonalAccessToken(
            accountID: patAccountID,
            login: "pat-user",
            credentialID: ForgeCredentialID("expiring-pat"),
            kind: .fineGrained,
            token: Data("expired-pat-access".utf8),
            expiresAt: now.addingTimeInterval(-1)
        )
        let refresher = StubRuntimeCredentialRefresher(result: .reauthorizationRequired)
        let runtimeRefresh = try ForgeAccountCredentialRefreshCoordinator(
            accountStore: accountStore,
            configuration: testApplicationConfiguration(),
            refresherFactory: { _ in refresher }
        )
        let authority = ForgeGitHubReadCredentialAuthority(
            accountStore: accountStore,
            credentialRefreshCoordinator: runtimeRefresh,
            now: { now }
        )
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)

        let reauthorization = try await authority.currentAuthentication(
            for: deviceAccount.currentCredential.reference
        )
        XCTAssertNil(reauthorization)
        let callsAfterDeviceAccount = await refresher.callCount()
        XCTAssertEqual(callsAfterDeviceAccount, 1)
        let proactiveRefresh = try await factory.refreshCredentialIfNeeded(
            for: deviceAccount.currentCredential.reference,
            at: now
        )
        XCTAssertNil(proactiveRefresh, "reauthorization must stop background and preflight work")
        let callsAfterProactiveRefresh = await refresher.callCount()
        XCTAssertEqual(callsAfterProactiveRefresh, 2)
        let personalAccessToken = try await authority.currentAuthentication(
            for: patAccount.currentCredential.reference
        )
        XCTAssertNil(personalAccessToken)
        let callsAfterPAT = await refresher.callCount()
        XCTAssertEqual(callsAfterPAT, 2, "PATs must never enter GitHub App token refresh")

        let staleReference = try ForgeCredentialReference(
            accountID: deviceAccountID,
            credentialID: deviceAccount.currentCredential.reference.credentialID,
            generation: ForgeCredentialGeneration(2)
        )
        let stale = try await authority.currentAuthentication(for: staleReference)
        XCTAssertNil(stale)
        let callsAfterStaleReference = await refresher.callCount()
        XCTAssertEqual(callsAfterStaleReference, 2, "a stale identity must fail before token refresh")
    }

    func testConcurrentAuthorityLoadsStayExactAndRedacted() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-concurrent")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("concurrent-pat"),
            kind: .classic,
            token: Data("concurrent-secret-token".utf8),
            expiresAt: nil
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let factory = ForgeGitHubReadAdapterFactory(credentialAuthority: authority)
        let readsBeforeConcurrentLoad = keychain.dataReadCount
        let references = try await withThrowingTaskGroup(
            of: ForgeCredentialReference?.self,
            returning: [ForgeCredentialReference?].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await authority.currentAuthentication(
                        for: account.currentCredential.reference
                    )?.credential.reference
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(references.count, 32)
        XCTAssertTrue(references.allSatisfy { $0 == account.currentCredential.reference })
        XCTAssertEqual(keychain.dataReadCount, readsBeforeConcurrentLoad + 32)
        assertRedacted(authority, forbidden: "concurrent-secret-token")
        assertRedacted(factory, forbidden: "concurrent-secret-token")
        let authentication = try await authority.currentAuthentication(
            for: account.currentCredential.reference
        )
        let resolvedAuthentication = try XCTUnwrap(authentication)
        assertRedacted(resolvedAuthentication, forbidden: "concurrent-secret-token")
    }

    func testCancellationBeforeAuthorityEntryPreventsKeychainAndNetworkAccess() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-cancelled")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("cancelled-pat"),
            kind: .classic,
            token: Data("cancelled-secret-token".utf8),
            expiresAt: nil
        )
        let authority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let capture = ReadCompositionRequestCapture()
        CompositionGitHubURLProtocol.setHandler { request in
            capture.record(request)
            return CompositionStubResponse(status: 200, body: Data())
        }
        let adapter = try ForgeGitHubReadAdapterFactory(credentialAuthority: authority).makeAdapter(
            for: account.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        let keychainReadsBeforeRequest = keychain.dataReadCount
        let repository = try makeRepository()
        let gate = AsyncStream<Void>.makeStream()
        let stream = gate.stream
        let task = Task { [adapter, repository, stream] in
            for await _ in stream {
                break
            }
            return try await adapter.repositoryFacts(repository: repository)
        }
        task.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()

        do {
            _ = try await task.value
            XCTFail("pre-cancelled read must not enter credential or transport work")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(keychain.dataReadCount, keychainReadsBeforeRequest)
        XCTAssertEqual(capture.authorizationHeaders, [])
    }

    @MainActor
    func testReadSurfaceAdapterBoxAndConvenienceServiceFailClosedWithoutAuthentication() async throws {
        let repository = try makeRepository()
        let cursor = try ForgePageCursor("next")
        let adapter = GitHubReadAdapter(sessionConfiguration: stubConfiguration())
        let box = ForgeGitHubReadSurfaceAdapterBox(adapter: adapter)

        await assertAuthenticationRequired {
            try await box.pullRequests(repository: repository, after: cursor, states: [.closed, .merged])
        }
        await assertAuthenticationRequired {
            try await box.issues(repository: repository, after: cursor, states: [.open])
        }
        await assertAuthenticationRequired {
            try await box.searchRepositoryItems(repository: repository, text: "literal search", after: cursor)
        }
        await assertAuthenticationRequired {
            try await box.pullRequestDetails(
                repository: repository,
                number: ForgeItemNumber(7),
                timelineAfter: cursor,
                checkAfter: cursor
            )
        }
        await assertAuthenticationRequired {
            try await box.issueDetails(
                repository: repository,
                number: ForgeItemNumber(8),
                timelineAfter: cursor
            )
        }

        let service = ForgeGitHubReadSurfaceService(
            repository: repository,
            adapter: adapter,
            now: { Date(timeIntervalSince1970: 500) }
        )
        await assertAuthenticationRequired {
            try await service.loadItems(
                kind: .pullRequests,
                query: ForgeReadSurfaceQuery(stateFilter: .all),
                after: nil
            )
        }
    }

    func testReadSurfaceAdapterBoxPreservesSuccessfulAdapterReads() async throws {
        let keychain = ReadCompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("surface-success")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("surface-pat"),
            kind: .fineGrained,
            token: Data("surface-access".utf8),
            expiresAt: nil
        )
        CompositionGitHubURLProtocol.setHandler { request in
            CompositionStubResponse(
                status: 200,
                body: Self.readSurfaceResponse(for: Self.operationName(from: request))
            )
        }
        let adapter = try ForgeGitHubReadAdapterFactory(
            credentialAuthority: ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        ).makeAdapter(
            for: account.currentCredential.reference,
            sessionConfiguration: stubConfiguration()
        )
        let box = ForgeGitHubReadSurfaceAdapterBox(adapter: adapter)
        let repository = try makeRepository()
        let number = try ForgeItemNumber(7)

        let pullRequests = try await box.pullRequests(repository: repository, after: nil, states: [.open])
        let issues = try await box.issues(repository: repository, after: nil, states: [.closed])
        let search = try await box.searchRepositoryItems(repository: repository, text: "surface", after: nil)
        let pullRequest = try await box.pullRequestDetails(
            repository: repository,
            number: number,
            timelineAfter: nil,
            checkAfter: nil
        )
        let issue = try await box.issueDetails(
            repository: repository,
            number: number,
            timelineAfter: nil
        )

        XCTAssertEqual(pullRequests.value.items, [])
        XCTAssertEqual(issues.value.items, [])
        XCTAssertEqual(search.value.items, [])
        XCTAssertEqual(pullRequest.value.details.summary.number, number)
        XCTAssertEqual(issue.value.summary.number, number)
    }

    func testReadSurfaceResultWrapperPreservesCompleteAndPartialEvidence() throws {
        let repository = try makeRepository()
        let credential = try makeCredentialReference(
            kind: .github,
            host: "github.com",
            account: "surface-result"
        )
        let response = GitHubResponseMetadata(
            statusCode: 200,
            requestID: "request-id",
            rateLimit: GitHubRateLimitParser.parse(
                statusCode: 200,
                headers: [:],
                receivedAt: Date(timeIntervalSince1970: 400)
            )
        )
        let ownership = try GitHubReadOwnership(credential: credential, repository: repository)
        let partial = ForgeGitHubSurfaceRead(GitHubReadResult(
            value: "partial",
            completeness: .partial,
            problems: [],
            response: response,
            ownership: ownership
        ))
        let complete = ForgeGitHubSurfaceRead(GitHubReadResult(
            value: "complete",
            completeness: .complete,
            problems: [],
            response: response,
            ownership: ownership
        ))

        XCTAssertEqual(partial.value, "partial")
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(complete.value, "complete")
        XCTAssertFalse(complete.isPartial)
    }

    private func assertAuthenticationFailure(
        _ adapter: GitHubReadAdapter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await adapter.repositoryFacts(repository: makeRepository())
            XCTFail("request must be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authenticationRequired, file: file, line: line)
        }
    }

    private func assertAuthenticationRequired<Value>(
        _ operation: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("request must require authentication", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authenticationRequired, file: file, line: line)
        }
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompositionGitHubURLProtocol.self]
        return configuration
    }

    private func makeRepository() throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
    }

    private static func operationName(from request: URLRequest) -> String {
        guard let body = request.httpBody ?? readBodyStream(request.httpBodyStream),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationName = object["operationName"] as? String
        else {
            return ""
        }
        return operationName
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func readSurfaceResponse(for operation: String) -> Data {
        let data: [String: Any]
        switch operation {
        case "GitHubPullRequestList":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "pullRequests": emptyConnection("PullRequestConnection"),
            ]]
        case "GitHubIssueList":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "issues": emptyConnection("IssueConnection"),
            ]]
        case "GitHubRepositoryItemSearch":
            data = ["search": emptyConnection("SearchResultItemConnection")]
        case "GitHubPullRequestDetails":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "pullRequest": pullRequestDetails,
            ]]
        case "GitHubIssueDetails":
            data = ["repository": [
                "__typename": "Repository",
                "id": "repository",
                "issue": issueDetails,
            ]]
        default:
            data = [:]
        }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    private static var pageInfo: [String: Any] {
        [
            "__typename": "PageInfo",
            "hasPreviousPage": false,
            "startCursor": NSNull(),
            "hasNextPage": false,
            "endCursor": NSNull(),
        ]
    }

    private static func emptyConnection(_ type: String) -> [String: Any] {
        ["__typename": type, "totalCount": 0, "pageInfo": pageInfo, "nodes": []]
    }

    private static var actor: [String: Any] {
        [
            "__typename": "User",
            "id": "actor",
            "login": "octocat",
            "name": "Octo",
            "avatarUrl": "https://avatars.githubusercontent.com/u/1",
        ]
    }

    private static var repositoryIdentity: [String: Any] {
        [
            "__typename": "Repository",
            "id": "repository",
            "name": "gitx",
            "nameWithOwner": "hbmartin/gitx",
            "owner": ["__typename": "User", "login": "hbmartin"],
        ]
    }

    private static var pullRequestDetails: [String: Any] {
        [
            "__typename": "PullRequest",
            "id": "pr",
            "number": 7,
            "pullRequestState": "OPEN",
            "isDraft": false,
            "title": "Adapter",
            "body": "body",
            "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z",
            "closedAt": NSNull(),
            "mergedAt": NSNull(),
            "author": actor,
            "headRefName": "feature",
            "headRefOid": "abcdef12",
            "headRepository": repositoryIdentity,
            "baseRefName": "main",
            "baseRefOid": "1234abcd",
            "baseRepository": repositoryIdentity,
            "labels": emptyConnection("LabelConnection"),
            "statusCheckRollup": [
                "__typename": "StatusCheckRollup",
                "state": "SUCCESS",
                "contexts": emptyConnection("StatusCheckRollupContextConnection"),
            ],
            "reviewDecision": NSNull(),
            "mergeable": "MERGEABLE",
            "assignedActors": emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": emptyConnection("UserConnection"),
            "reviewRequests": emptyConnection("ReviewRequestConnection"),
            "latestReviews": emptyConnection("PullRequestReviewConnection"),
            "closingIssuesReferences": emptyConnection("IssueConnection"),
            "timelineItems": emptyConnection("PullRequestTimelineItemsConnection"),
        ]
    }

    private static var issueDetails: [String: Any] {
        [
            "__typename": "Issue",
            "id": "issue",
            "number": 7,
            "issueState": "OPEN",
            "title": "Issue",
            "body": "body",
            "createdAt": "2026-07-29T12:34:56Z",
            "updatedAt": "2026-07-29T12:34:56Z",
            "closedAt": NSNull(),
            "author": actor,
            "labels": emptyConnection("LabelConnection"),
            "assignedActors": emptyConnection("AssigneeConnection"),
            "milestone": NSNull(),
            "participants": emptyConnection("UserConnection"),
            "timelineItems": emptyConnection("IssueTimelineItemsConnection"),
        ]
    }

    private func makeAccountID(_ value: String) throws -> ForgeAccountID {
        try ForgeAccountID(forge: makeRepository().forge, value: value)
    }

    private func makeCredentialReference(
        kind: ForgeKind,
        host: String,
        account: String
    ) throws -> ForgeCredentialReference {
        let accountID = try ForgeAccountID(
            forge: ForgeIdentity(kind: kind, origin: ForgeOrigin(host: host)),
            value: account
        )
        return try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("credential"),
            generation: ForgeCredentialGeneration(1)
        )
    }

    private func rotatingSecrets(access: String, refresh: String) throws -> ForgeCredentialSecretMaterial {
        try ForgeCredentialSecretMaterial(
            accessToken: Data(access.utf8),
            refreshToken: Data(refresh.utf8),
            refreshTokenExpiresAt: Date.distantFuture
        )
    }

    private func rotatingCredential(
        access: String,
        refresh: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date
    ) throws -> GitHubRotatingUserCredential {
        try GitHubRotatingUserCredential(
            accessToken: GitHubSecret(utf8Bytes: Data(access.utf8)),
            accessTokenExpiresAt: accessExpiresAt,
            refreshToken: GitHubSecret(utf8Bytes: Data(refresh.utf8)),
            refreshTokenExpiresAt: refreshExpiresAt
        )
    }

    private func testApplicationConfiguration() throws -> GitHubAppDeviceFlowConfiguration {
        try GitHubAppDeviceFlowConfiguration(
            clientID: "Iv1ABC123",
            applicationSlug: "runtime-refresh-test-app"
        )
    }

    private func assertRedacted<Value>(
        _ value: Value,
        forbidden: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(String(describing: value).contains(forbidden), file: file, line: line)
        XCTAssertFalse(String(reflecting: value).contains(forbidden), file: file, line: line)
        if let reflected = value as? any CustomReflectable {
            XCTAssertTrue(reflected.customMirror.children.isEmpty, file: file, line: line)
        }
    }
}

private actor StubRuntimeCredentialRefresher: ForgeGitHubCredentialRefreshing {
    private let result: GitHubCredentialRefreshResult
    private var calls = 0

    init(result: GitHubCredentialRefreshResult) {
        self.result = result
    }

    func refreshIfNeeded(
        _: GitHubRotatingUserCredential,
        at _: Date,
        minimumValidity _: TimeInterval
    ) async throws -> GitHubCredentialRefreshResult {
        calls += 1
        if calls == 1 {
            return result
        }
        guard case let .refreshed(credential) = result else {
            return result
        }
        return .current(refreshAt: credential.accessTokenExpiresAt)
    }

    func callCount() -> Int {
        calls
    }
}

private actor ControllableRuntimeCredentialRefresher: ForgeGitHubCredentialRefreshing {
    private let result: GitHubCredentialRefreshResult
    private var calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: GitHubCredentialRefreshResult) {
        self.result = result
    }

    func refreshIfNeeded(
        _: GitHubRotatingUserCredential,
        at _: Date,
        minimumValidity _: TimeInterval
    ) async -> GitHubCredentialRefreshResult {
        calls += 1
        let readyCallCountWaiters = callCountWaiters.filter { calls >= $0.0 }
        callCountWaiters.removeAll { calls >= $0.0 }
        readyCallCountWaiters.forEach { $0.1.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return result
    }

    func callCount() -> Int {
        calls
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        guard calls < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expectedCount, continuation))
        }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

// swift6-safety-justification: The lock serializes all in-memory Keychain test-double state.
private final nonisolated class ReadCompositionKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var reads = 0

    var dataReadCount: Int {
        lock.withLock { reads }
    }

    func data(for accountKey: String) throws -> Data? {
        lock.withLock {
            reads += 1
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        lock.withLock { storage.map(ForgeKeychainItem.init(accountKey:data:)) }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        lock.withLock { storage[accountKey] = data }
    }

    func remove(accountKey: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: accountKey) }
    }

    func replaceAccessToken(with token: Data, accountKey: String) throws {
        try lock.withLock {
            let data = try XCTUnwrap(storage[accountKey])
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            var secrets = try XCTUnwrap(object["secrets"] as? [String: Any])
            secrets["accessToken"] = token.base64EncodedString()
            object["secrets"] = secrets
            storage[accountKey] = try JSONSerialization.data(withJSONObject: object)
        }
    }
}

private struct CompositionStubResponse: Sendable {
    let status: Int
    let body: Data
}

// swift6-safety-justification: The lock serializes captured request metadata.
private final nonisolated class ReadCompositionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []

    var authorizationHeaders: [String] {
        lock.withLock { headers }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
    }
}

// swift6-safety-justification: The lock serializes the nonisolated handler used by URLProtocol callbacks.
private final class CompositionGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // swift6-safety-justification: The lock serializes all reads and writes of the URLProtocol handler.
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> CompositionStubResponse)?

    static func setHandler(_ value: (@Sendable (URLRequest) -> CompositionStubResponse)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: GitHubReadError.transportFailure)
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
