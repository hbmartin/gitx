import AppKit
import ForgeKit
import XCTest

final class ForgeApplicationCompositionTests: XCTestCase {
    func testOverlayLoaderPreparesCredentialFreeGitHubBindingWithPublicAccessAndSharedBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgePublicOverlayComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let services = ForgeApplicationServiceLoader {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner()
            )
        }
        let repository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository
        )
        let loader = RepositoryForgeOverlayLoader(
            binding: binding,
            services: services,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )

        guard case let .ready(preparedRepository, context) = await loader.prepare() else {
            return XCTFail("Credential-free public GitHub.com bindings should prepare anonymous reads")
        }
        XCTAssertEqual(preparedRepository, repository)
        XCTAssertEqual(context.access, .publicAccess)
        XCTAssertEqual(context.authentication, .publicAccess)
        XCTAssertNil(context.credential)
        let firstServices = try await services.services()
        let secondServices = try await services.services()
        XCTAssertTrue(firstServices.githubAnonymousRESTBudget === secondServices.githubAnonymousRESTBudget)
        XCTAssertTrue(firstServices.githubAnonymousRESTBudget === ForgeAnonymousRESTProcessRuntime.budget)
        let facts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(ForgeRefName("main")),
            description: .available("Public"),
            topics: .available([]),
            visibility: .available(.public),
            isArchived: .available(false),
            forkRelationship: .available(.standalone)
        )
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000)
        try await context.cache.putRepositoryFacts(RepositoryForgeRemoteSnapshot(
            value: facts,
            fetchedAt: fetchedAt,
            completeness: .partial(unavailableSections: [.repositoryFacts]),
            cooldownDeadline: nil
        ))
        let accountID = try ForgeAccountID(forge: repository.forge, value: "account-node")
        let accountPartition = try ForgeRepositoryPartitionKey(
            cachePartition: .account(accountID),
            repository: repository
        )
        let database = try XCTUnwrap(firstServices.database)
        let accountCache = SQLiteRepositoryForgeOverlayCache(database: database, partition: accountPartition)
        let publicValue = try await context.cache.cachedRepositoryFacts(accessedAt: fetchedAt)
        let accountValue = try await accountCache.cachedRepositoryFacts(accessedAt: fetchedAt)
        XCTAssertEqual(publicValue?.value, facts)
        XCTAssertNil(accountValue, "public anonymous snapshots must never seed an account partition")
    }

    func testDefaultRefreshCoordinatorDiscoversAuthenticatedBoundRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeBoundRefreshComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let keychain = CompositionKeychain()
        let accountStore = ForgeAccountStore(keychain: keychain)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "bound-account")
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("bound-pat"),
            kind: .fineGrained,
            token: Data("bound-token".utf8),
            expiresAt: nil
        )
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: accountID
        )
        try defaults.set([
            "bound-repository": [
                ForgeRepositoryBindingAccountCleaner.forgeBindingKey: JSONEncoder().encode(binding),
            ],
        ], forKey: ForgeRepositoryBindingAccountCleaner.repositorySettingsKey)

        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: keychain,
            cliRunner: CompositionRunner()
        )
        let coordinator = try XCTUnwrap(services.refreshCoordinator)
        let target = try ForgeRefreshTarget(
            authentication: .credential(account.currentCredential.reference),
            repository: repository
        )
        let interval = await coordinator.interval(for: target)
        XCTAssertEqual(interval, ForgeRefreshPolicy.boundRepositoryInterval)
        await coordinator.invalidate()
    }

    func testForgeServicesAreLazyCoalescedAndEntirelyOffMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationCompositionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let keychain = CompositionKeychain()
        let runner = CompositionRunner()
        let probe = CompositionFactoryProbe()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let loader = ForgeApplicationServiceLoader {
            probe.recordInvocation()
            _ = try keychain.allItems()
            return try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: keychain,
                cliRunner: runner
            )
        }

        XCTAssertEqual(probe.invocationCount, 0)
        XCTAssertEqual(keychain.accessThreads, [])
        let initialCommandCount = await runner.commandCount
        XCTAssertEqual(initialCommandCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        async let first = loader.services()
        async let second = loader.services()
        let (firstServices, secondServices) = try await(first, second)
        XCTAssertTrue(firstServices === secondServices)
        XCTAssertEqual(probe.invocationCount, 1)
        XCTAssertEqual(probe.invocationThreads, [false])
        XCTAssertEqual(keychain.accessThreads, [false])
        let finalCommandCount = await runner.commandCount
        XCTAssertEqual(finalCommandCount, 0, "lazy composition must not turn CLI brokerage into launch fallback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testDefaultFactoryUsesTheProvidedApplicationSupportDirectoryWithoutConsultingCredentials() async throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationDefaultFactoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let systemApplicationSupport = try ForgeApplicationServiceFactory.systemApplicationSupportDirectory()
        XCTAssertTrue(systemApplicationSupport.isFileURL)

        let loader = ForgeApplicationServiceLoader(
            bindingCleaner: bindingCleaner,
            applicationSupportDirectory: { applicationSupport },
            avatarLoader: nil,
            avatarLoadingEnabled: { true }
        )
        let services = try await loader.services()

        let forgeDirectory = applicationSupport
            .appendingPathComponent("GitX", isDirectory: true)
            .appendingPathComponent("Forge", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: forgeDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: forgeDirectory.appendingPathComponent("Forge.sqlite3").path
        ))
        _ = services
    }

    func testDefaultLoaderCanCaptureTheSystemDirectoryProviderWithoutInitializingServices() throws {
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)

        _ = ForgeApplicationServiceLoader(
            bindingCleaner: bindingCleaner,
            avatarLoader: nil,
            avatarLoadingEnabled: { true }
        )
    }

    func testDefaultLoaderEvaluatesLatestAvatarPreferenceWhenServicesStart() async throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationPreferenceTiming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let preference = CompositionAvatarLoadingAuthority(true)
        let transport = CompositionAvatarTransport(payload: ForgeAvatarPayload(
            data: Data([7, 7]),
            mediaType: .png
        ))
        let avatarLoader = ForgeAvatarLoader(
            transport: transport,
            loadingEnabled: false,
            requiresBackingStoreInstallation: true
        )
        let loader = ForgeApplicationServiceLoader(
            bindingCleaner: bindingCleaner,
            applicationSupportDirectory: { applicationSupport },
            avatarLoader: avatarLoader,
            avatarLoadingEnabled: { preference.value }
        )
        preference.set(false)

        _ = try await loader.services()

        let state = await avatarLoader.statistics()
        XCTAssertFalse(state.enabled)
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/71")
        await XCTAssertThrowsErrorAsync(try await avatarLoader.load(avatarURL)) { error in
            XCTAssertEqual(error as? ForgeAvatarLoadingError, .disabled)
        }
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testFailedLazyInitializationCanRetryWithoutPublishingPartialServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationCompositionRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let keychain = CompositionKeychain()
        let runner = CompositionRunner()
        let probe = CompositionFactoryProbe()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let loader = ForgeApplicationServiceLoader {
            let attempt = probe.recordInvocation()
            if attempt == 1 {
                throw CompositionFactoryError.expectedFailure
            }
            return try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: keychain,
                cliRunner: runner
            )
        }

        do {
            _ = try await loader.services()
            XCTFail("the injected first initialization should fail")
        } catch {
            XCTAssertEqual(error as? CompositionFactoryError, .expectedFailure)
        }
        let services = try await loader.services()
        let retainedServices = try await loader.services()
        XCTAssertTrue(services === retainedServices)
        XCTAssertEqual(probe.invocationCount, 2)
        XCTAssertEqual(probe.invocationThreads, [false, false])
    }

    func testFactoryComposesCacheDurableAndRecoveryCopyRetentionAtDeterministicClock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationRetentionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
        )
        let database = try ForgeSQLiteStore(configuration: configuration)
        let now = Date(timeIntervalSince1970: 10_000_000_000)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "retention-account")
        let staleRepository = try ForgeRepositoryIdentity(forge: forge, owner: "acme", name: "stale")
        let activeRepository = try ForgeRepositoryIdentity(forge: forge, owner: "acme", name: "active")
        let staleKey = try snapshotKey(accountID: accountID, repository: staleRepository, identity: "stale")
        let activeKey = try snapshotKey(accountID: accountID, repository: activeRepository, identity: "active")
        let staleDate = now.addingTimeInterval(-ForgePolicyConstants.repositoryIdleExpiration - 1)
        let activeDate = now.addingTimeInterval(-1)
        try await database.putCacheEntry(cacheEntry(key: staleKey, payload: "stale", at: staleDate))
        try await database.putCacheEntry(cacheEntry(key: activeKey, payload: "active", at: activeDate))
        let expiredRecord = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: activeRepository,
            key: Data("expired".utf8),
            payload: Data("expired draft".utf8),
            lastActivityAt: staleDate,
            expiresAt: now
        )
        let activeRecord = try ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: accountID,
            repository: activeRepository,
            key: Data("active".utf8),
            payload: Data("active attention".utf8),
            lastActivityAt: activeDate,
            expiresAt: now.addingTimeInterval(1)
        )
        try await database.saveDurableRecord(expiredRecord)
        try await database.saveDurableRecord(activeRecord)
        await database.close()

        let expiredRecoveryCopy = configuration.recoveryDirectoryURL
            .appendingPathComponent("ForgeKit-recovery-expired.sqlite3")
        try Data("old recovery".utf8).write(to: expiredRecoveryCopy)
        try Data("old sidecar".utf8).write(to: URL(fileURLWithPath: expiredRecoveryCopy.path + "-wal"))

        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: makeDefaults()),
            keychain: CompositionKeychain(),
            cliRunner: CompositionRunner(),
            now: { now }
        )
        let maintainedDatabase = try XCTUnwrap(services.database)
        let maintainedStale = try await maintainedDatabase.cacheEntry(for: staleKey, accessedAt: now)
        let maintainedActive = try await maintainedDatabase.cacheEntry(for: activeKey, accessedAt: now)
        let maintainedExpiredDurable = try await maintainedDatabase.durableRecord(
            kind: expiredRecord.kind,
            accountID: accountID,
            repository: activeRepository,
            key: expiredRecord.key
        )
        let maintainedActiveDurable = try await maintainedDatabase.durableRecord(
            kind: activeRecord.kind,
            accountID: accountID,
            repository: activeRepository,
            key: activeRecord.key
        )
        XCTAssertNil(maintainedStale)
        XCTAssertEqual(
            maintainedActive?.payload,
            Data("active".utf8)
        )
        XCTAssertNil(maintainedExpiredDurable)
        XCTAssertEqual(maintainedActiveDurable, activeRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredRecoveryCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredRecoveryCopy.path + "-wal"))
    }

    func testRecoverySalvagesOnlyDurableRecordsAndKeepsDiagnosticCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationDurableSalvageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceConfiguration = ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("RecoverySource.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("SourceRecovery", isDirectory: true)
        )
        let source = try ForgeSQLiteStore(configuration: sourceConfiguration)
        let now = Date(timeIntervalSince1970: 5_000_000)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "salvage-account")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let durable = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("draft".utf8),
            payload: Data("recover me".utf8),
            lastActivityAt: now,
            expiresAt: now.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
        )
        let disposableKey = try snapshotKey(
            accountID: accountID,
            repository: repository,
            identity: "discard-me"
        )
        try await source.saveDurableRecord(durable)
        try await source.putCacheEntry(cacheEntry(key: disposableKey, payload: "disposable", at: now))
        await source.close()

        let targetConfiguration = ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("Target/Forge.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("Target/Recovery", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: targetConfiguration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("broken live database".utf8).write(to: targetConfiguration.databaseURL)
        let recoveryCopy = ForgeSQLiteRecoveryCopy(url: sourceConfiguration.databaseURL, createdAt: now)
        let coordinator = ForgeApplicationRecoveryCoordinator(
            configuration: targetConfiguration,
            deferredAccountCleanup: ForgeDeferredAccountCleanupStore(
                forgeDirectory: targetConfiguration.databaseURL.deletingLastPathComponent()
            ),
            now: { now }
        )

        let result = try await coordinator.recoverDurableRecords(from: recoveryCopy)

        XCTAssertEqual(result.restoredDurableRecordCount, 1)
        XCTAssertEqual(result.skippedDurableRecordCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryCopy.url.path))
        let replacement = try ForgeSQLiteStore(configuration: targetConfiguration)
        let restoredDurable = try await replacement.durableRecord(
            kind: durable.kind,
            accountID: accountID,
            repository: repository,
            key: durable.key
        )
        let discardedDisposable = try await replacement.cacheEntry(for: disposableKey, accessedAt: now)
        XCTAssertEqual(restoredDurable, durable)
        XCTAssertNil(discardedDisposable)
        await replacement.close()
    }

    func testResetPreservesAccountsAndBindingsWhileClearingDatabaseAndTrustedOrigins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let trustedOrigins = ForgeTrustedExternalOriginStore(defaults: defaults)
        let keychain = CompositionKeychain()
        let loader = ForgeApplicationServiceLoader {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: keychain,
                cliRunner: CompositionRunner(),
                trustedExternalOrigins: trustedOrigins
            )
        }
        let services = try await loader.services()
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "reset-account")
        let account = try await services.accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("reset-pat"),
            kind: .classic,
            token: Data("reset-token".utf8),
            expiresAt: nil
        )
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: accountID
        )
        try defaults.set([
            "reset-repository": [
                ForgeRepositoryBindingAccountCleaner.forgeBindingKey: JSONEncoder().encode(binding),
            ],
        ], forKey: ForgeRepositoryBindingAccountCleaner.repositorySettingsKey)
        let trustedOrigin = try ForgeTrustedExternalOrigin(
            origin: ForgeOrigin(host: "docs.example")
        )
        XCTAssertTrue(trustedOrigins.add(trustedOrigin))
        let trustedOriginNotificationThreads = CompositionThreadProbe()
        let trustedOriginObserver = NotificationCenter.default.addObserver(
            forName: .forgeTrustedExternalOriginsDidChange,
            object: trustedOrigins,
            queue: nil
        ) { _ in
            trustedOriginNotificationThreads.recordCurrentThread()
        }
        defer { NotificationCenter.default.removeObserver(trustedOriginObserver) }
        let database = try XCTUnwrap(services.database)
        let durable = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("reset-draft".utf8),
            payload: Data("discarded by reset".utf8),
            lastActivityAt: Date()
        )
        try await database.saveDurableRecord(durable)

        try await loader.resetForgeData()

        let resetServices = try await loader.services()
        XCTAssertTrue(services.githubAnonymousRESTBudget === resetServices.githubAnonymousRESTBudget)
        XCTAssertTrue(resetServices.githubAnonymousRESTBudget === ForgeAnonymousRESTProcessRuntime.budget)
        let resetAccounts = try await resetServices.accountStore.accounts()
        XCTAssertEqual(bindingCleaner.forgeRepositoryBindings(), [binding])
        XCTAssertTrue(trustedOrigins.origins().isEmpty)
        XCTAssertEqual(trustedOriginNotificationThreads.mainThreadValues, [true])
        let resetDatabase = try XCTUnwrap(resetServices.database)
        let resetDurable = try await resetDatabase.durableRecord(
            kind: durable.kind,
            accountID: accountID,
            repository: repository,
            key: durable.key
        )
        XCTAssertEqual(resetAccounts, [account])
        XCTAssertNil(resetDurable)
    }

    func testNotNowIsSessionLocalAndRecoveryPresentationPinsEveryAction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationNotNowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: root.appendingPathComponent("Forge.sqlite3"))
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let loader = ForgeApplicationServiceLoader {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner()
            )
        }
        let services = try await loader.services()
        let copy = try XCTUnwrap(services.dataAvailability.recoveryCopy)

        let availabilityNotificationThreads = CompositionThreadProbe()
        let availabilityObserver = NotificationCenter.default.addObserver(
            forName: .forgeApplicationAvailabilityDidChange,
            object: nil,
            queue: nil
        ) { _ in
            availabilityNotificationThreads.recordCurrentThread()
        }
        defer { NotificationCenter.default.removeObserver(availabilityObserver) }

        await loader.disableForgeForSession()

        guard case let .sessionDisabled(disabledCopy) = try await loader.overlayServices() else {
            return XCTFail("Not Now must disable only the Forge overlay for this loader session")
        }
        XCTAssertEqual(disabledCopy, copy)
        await XCTAssertThrowsErrorAsync(try await loader.services()) { error in
            guard case ForgeApplicationRecoveryError.sessionDisabled = error else {
                return XCTFail("ordinary Forge service access must honor the session-wide gate")
            }
        }
        let accountServices = try await loader.accountManagementServices()
        XCTAssertTrue(accountServices === services, "account access remains available in-session")
        XCTAssertEqual(availabilityNotificationThreads.mainThreadValues, [true])

        let presentation = ForgeRecoveryAlertPresentation.make(recoveryCopies: [copy])
        XCTAssertEqual(presentation.title, "Forge Data Unavailable")
        XCTAssertTrue(presentation.message.contains(copy.url.lastPathComponent))
        XCTAssertTrue(presentation.message.contains("Local Git remains fully available"))
        XCTAssertTrue(presentation.message.contains("last copy of unrecovered drafts"))
        XCTAssertEqual(
            presentation.buttonTitles,
            ["Retry", "Reset Forge Data…", "Not Now", "Reveal in Finder", "Delete Now"]
        )
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        XCTAssertEqual(ForgeRecoveryAlertAction(response: .init(rawValue: first)), .retry)
        XCTAssertEqual(ForgeRecoveryAlertAction(response: .init(rawValue: first + 1)), .resetForgeData)
        XCTAssertEqual(ForgeRecoveryAlertAction(response: .init(rawValue: first + 2)), .notNow)
        XCTAssertEqual(ForgeRecoveryAlertAction(response: .init(rawValue: first + 3)), .revealInFinder)
        XCTAssertEqual(ForgeRecoveryAlertAction(response: .init(rawValue: first + 4)), .deleteNow)
        XCTAssertNil(ForgeRecoveryAlertAction(response: .init(rawValue: first + 5)))

        try await loader.deleteRecoveryCopy(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        await XCTAssertThrowsErrorAsync(try await loader.retryForgeRecovery(copy)) { error in
            guard case ForgeApplicationRecoveryError.unavailable = error else {
                return XCTFail("retry must reject a stale recovery-copy selection")
            }
        }
    }

    func testConcurrentResetsSerializeAndNeverRepublishAClosedDatabase() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationSerializedResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let probe = CompositionFactoryProbe()
        let loader = ForgeApplicationServiceLoader {
            probe.recordInvocation()
            return try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner()
            )
        }
        _ = try await loader.services()

        async let firstReset: Void = loader.resetForgeData()
        async let secondReset: Void = loader.resetForgeData()
        _ = try await(firstReset, secondReset)

        let services = try await loader.services()
        let database = try XCTUnwrap(services.database)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "serialized-reset")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let record = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("after-reset".utf8),
            payload: Data("open database".utf8),
            lastActivityAt: Date()
        )
        try await database.saveDurableRecord(record)
        let loadedRecord = try await database.durableRecord(
            kind: record.kind,
            accountID: accountID,
            repository: repository,
            key: record.key
        )
        XCTAssertEqual(loadedRecord?.kind, record.kind)
        XCTAssertEqual(loadedRecord?.accountID, record.accountID)
        XCTAssertEqual(loadedRecord?.repository, record.repository)
        XCTAssertEqual(loadedRecord?.key, record.key)
        XCTAssertEqual(loadedRecord?.payload, record.payload)
        XCTAssertEqual(loadedRecord?.expiresAt, record.expiresAt)
        XCTAssertEqual(
            try XCTUnwrap(loadedRecord?.lastActivityAt).timeIntervalSince1970,
            record.lastActivityAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(probe.invocationCount, 3)
    }

    func testLazyMaintenanceExpiresRecordsDuringLongRunningSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationLazyMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let clock = CompositionDateAuthority(Date().addingTimeInterval(1))
        let loader = ForgeApplicationServiceLoader(
            now: { clock.value },
            maintenanceInterval: 60
        ) {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner(),
                now: { clock.value }
            )
        }
        let services = try await loader.services()
        let database = try XCTUnwrap(services.database)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "long-session")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let record = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("expires-in-session".utf8),
            payload: Data("draft".utf8),
            lastActivityAt: clock.value,
            expiresAt: clock.value.addingTimeInterval(30)
        )
        try await database.saveDurableRecord(record)
        let recoveryDirectory = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let recoveryCopy = recoveryDirectory.appendingPathComponent("ForgeKit-recovery-long-session.sqlite3")
        let recoverySidecar = URL(fileURLWithPath: recoveryCopy.path + "-wal")
        try Data("private recovery".utf8).write(to: recoveryCopy)
        try Data("private sidecar".utf8).write(to: recoverySidecar)

        clock.advance(by: ForgePolicyConstants.recoveryCopyExpiration)
        _ = try await loader.services()

        let expiredRecord = try await database.durableRecord(
            kind: record.kind,
            accountID: accountID,
            repository: repository,
            key: record.key
        )
        XCTAssertNil(expiredRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoverySidecar.path))
    }

    func testSQLiteRecoveryKeepsAccountsKeychainAndRemovalAvailableWithoutCLIFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationRecoveryCompositionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-a-sqlite-database".utf8).write(
            to: root.appendingPathComponent("Forge.sqlite3")
        )
        let defaults = try makeDefaults()
        let keychain = CompositionKeychain()
        let runner = CompositionRunner()
        let avatarPayload = ForgeAvatarPayload(data: Data([8, 1]), mediaType: .png)
        let avatarLoader = ForgeAvatarLoader(
            transport: CompositionAvatarTransport(payload: avatarPayload),
            loadingEnabled: false,
            requiresBackingStoreInstallation: true
        )
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: keychain,
            cliRunner: runner,
            avatarLoader: avatarLoader
        )

        XCTAssertNil(services.database)
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/801")
        let loadedAvatar = try await avatarLoader.load(avatarURL)
        XCTAssertEqual(loadedAvatar, avatarPayload)
        let avatarState = await avatarLoader.statistics()
        XCTAssertTrue(avatarState.enabled)
        let recoveryCopy = try XCTUnwrap(services.dataAvailability.recoveryCopy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryCopy.url.path))
        let initialCommandCount = await runner.commandCount
        XCTAssertEqual(initialCommandCount, 0)

        let accountID = try ForgeAccountID(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            value: "recovery-account"
        )
        let account = try await services.accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("recovery-pat"),
            kind: .classic,
            token: Data("recovery-token".utf8),
            expiresAt: nil
        )
        let storedAccounts = try await services.accountStore.accounts()
        XCTAssertEqual(storedAccounts, [account])
        try await services.removalCoordinator.removeAccount(accountID)
        let remainingAccounts = try await services.accountStore.accounts()
        XCTAssertEqual(remainingAccounts, [])
        let finalCommandCount = await runner.commandCount
        XCTAssertEqual(finalCommandCount, 0)

        let tombstoneURL = ForgeDeferredAccountCleanupStore.tombstoneURL(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: tombstoneURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(
            try tombstoneURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
    }

    func testDeferredAccountCleanupReplaysIntoRecoveredDatabaseBeforePublishingServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationCleanupReplayTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let keychain = CompositionKeychain()
        let firstServices = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: bindingCleaner,
            keychain: keychain,
            cliRunner: CompositionRunner()
        )
        let firstDatabase = try XCTUnwrap(firstServices.database)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "removed-account")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let record = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("draft-key".utf8),
            payload: Data("private-draft".utf8),
            lastActivityAt: Date(timeIntervalSince1970: 1000)
        )
        try await firstDatabase.saveDurableRecord(record)
        let avatarKey = try ForgeAvatarCacheKey(
            canonicalURL: XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/u/902"))
        )
        let avatarBytes = Data([1, 9, 2])
        let avatarDate = Date(timeIntervalSince1970: 1000)
        try await firstDatabase.putAvatarCacheEntry(
            ForgeSQLiteCacheEntry(
                record: ForgeDisposableCacheRecord(
                    key: .avatar(avatarKey),
                    byteCount: UInt64(avatarBytes.count),
                    fetchedAt: avatarDate,
                    lastAccessedAt: avatarDate
                ),
                payload: avatarBytes
            ),
            owners: [.account(accountID)]
        )
        let storedBeforeReplay = try await firstDatabase.durableRecord(
            kind: record.kind,
            accountID: accountID,
            repository: repository,
            key: record.key
        )
        XCTAssertEqual(storedBeforeReplay, record)
        let recoveryDirectory = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let retainedRecoveryURL = recoveryDirectory.appendingPathComponent("retained-recovery.sqlite3")
        try Data("quarantined-recovery-copy".utf8).write(to: retainedRecoveryURL)
        let recoveryCopy = ForgeSQLiteRecoveryCopy(
            url: retainedRecoveryURL,
            createdAt: Date(timeIntervalSince1970: 900)
        )
        let tombstones = ForgeDeferredAccountCleanupStore(forgeDirectory: root)
        try await tombstones.record(accountID, recoveryCopy: recoveryCopy)
        await firstDatabase.close()

        let recoveredServices = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: bindingCleaner,
            keychain: keychain,
            cliRunner: CompositionRunner()
        )
        let recoveredDatabase = try XCTUnwrap(recoveredServices.database)
        let storedAfterReplay = try await recoveredDatabase.durableRecord(
            kind: record.kind,
            accountID: accountID,
            repository: repository,
            key: record.key
        )
        XCTAssertNil(storedAfterReplay)
        let avatarAfterReplay = try await recoveredDatabase.cacheEntry(
            for: .avatar(avatarKey),
            accessedAt: avatarDate
        )
        XCTAssertNil(avatarAfterReplay)
        let tombstoneURL = ForgeDeferredAccountCleanupStore.tombstoneURL(in: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tombstoneURL.path
        ), "tombstone remains authoritative while a quarantined recovery copy exists")

        let otherAccountID = try ForgeAccountID(forge: forge, value: "other-account")
        let otherRecord = try ForgeSQLiteDurableRecord(
            kind: .watchedRepository,
            accountID: otherAccountID,
            repository: repository,
            key: Data("watch-key".utf8),
            payload: Data("other-account-state".utf8),
            lastActivityAt: Date(timeIntervalSince1970: 1000)
        )
        let filteredSalvage = try await recoveredServices.deferredAccountCleanup.filtering(
            ForgeSQLiteSalvage(
                durableRecords: [record, otherRecord],
                skippedRecordCount: 2
            )
        )
        XCTAssertEqual(filteredSalvage.durableRecords, [otherRecord])
        XCTAssertEqual(filteredSalvage.skippedRecordCount, 3)

        try FileManager.default.removeItem(at: retainedRecoveryURL)
        await recoveredDatabase.close()
        let finalServices = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: bindingCleaner,
            keychain: keychain,
            cliRunner: CompositionRunner()
        )
        XCTAssertNotNil(finalServices.database)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ForgeDeferredAccountCleanupStore.tombstoneURL(in: root).path
        ))
    }

    func testDeferredCleanupCoalescesRecoveryCopiesSortsAccountsAndRejectsUnknownVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeDeferredCleanupEdgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let laterAccount = try ForgeAccountID(forge: forge, value: "z-account")
        let earlierAccount = try ForgeAccountID(forge: forge, value: "a-account")
        let firstCopy = ForgeSQLiteRecoveryCopy(
            url: root.appendingPathComponent("first.sqlite3"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let secondCopy = ForgeSQLiteRecoveryCopy(
            url: root.appendingPathComponent("second.sqlite3"),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let store = ForgeDeferredAccountCleanupStore(forgeDirectory: root)

        try await store.record(laterAccount, recoveryCopy: firstCopy)
        try await store.record(laterAccount, recoveryCopy: secondCopy)
        try await store.record(earlierAccount, recoveryCopy: firstCopy)

        let repository = try ForgeRepositoryIdentity(
            forge: forge,
            owner: "hbmartin",
            name: "gitx"
        )
        let records = try [laterAccount, earlierAccount].enumerated().map { index, accountID in
            try ForgeSQLiteDurableRecord(
                kind: .draft,
                accountID: accountID,
                repository: repository,
                key: Data("key-\(index)".utf8),
                payload: Data("payload-\(index)".utf8),
                lastActivityAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let filtered = try await store.filtering(
            ForgeSQLiteSalvage(durableRecords: records, skippedRecordCount: 0)
        )
        XCTAssertEqual(filtered.durableRecords, [])
        XCTAssertEqual(filtered.skippedRecordCount, 2)

        let tombstoneURL = ForgeDeferredAccountCleanupStore.tombstoneURL(in: root)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: tombstoneURL)) as? [String: Any]
        )
        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
        XCTAssertLessThan(
            try XCTUnwrap(encoded.range(of: "a-account")?.lowerBound),
            try XCTUnwrap(encoded.range(of: "z-account")?.lowerBound)
        )

        try await store.pruneResolvedEntries()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path))

        try Data("{\"entries\":[],\"version\":1}".utf8).write(to: tombstoneURL, options: .atomic)
        do {
            _ = try await store.filtering(
                ForgeSQLiteSalvage(durableRecords: [], skippedRecordCount: 0)
            )
            XCTFail("unknown tombstone versions must fail closed")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadCorruptFile)
        }
    }

    func testFactoryInstallsSQLiteAvatarPersistenceAndRemovalDeletesExclusiveOwnerData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeApplicationAvatarComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let keychain = CompositionKeychain()
        let payload = ForgeAvatarPayload(data: Data([9, 1]), mediaType: .png)
        let transport = CompositionAvatarTransport(payload: payload)
        let avatarLoader = ForgeAvatarLoader(transport: transport)
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: keychain,
            cliRunner: CompositionRunner(),
            avatarLoader: avatarLoader,
            avatarLoadingEnabled: { true }
        )
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "avatar-composition-account")
        _ = try await services.addAccountCoordinator.addPersonalAccessToken(
            accountID: accountID,
            login: "avatar-user",
            credentialID: ForgeCredentialID("avatar-pat"),
            kind: .fineGrained,
            token: Data("avatar-token".utf8),
            expiresAt: nil
        )
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/901")

        let loaded = try await avatarLoader.load(avatarURL, owner: .account(accountID))
        let database = try XCTUnwrap(services.database)
        let persisted = try await database.cacheEntry(
            for: .avatar(ForgeAvatarCacheKey(canonicalURL: avatarURL.url)),
            accessedAt: Date()
        )
        XCTAssertEqual(loaded, payload)
        XCTAssertNotNil(persisted)
        XCTAssertNil(persisted?.payload.range(of: Data(accountID.value.utf8)))

        try await services.removalCoordinator.removeAccount(accountID)

        let removed = try await database.cacheEntry(
            for: .avatar(ForgeAvatarCacheKey(canonicalURL: avatarURL.url)),
            accessedAt: Date()
        )
        let loaderState = await avatarLoader.statistics()
        let fetchCount = await transport.fetchCount
        XCTAssertNil(removed)
        XCTAssertEqual(loaderState.cachedItems, 0)
        XCTAssertEqual(loaderState.activeRequests, 0)
        XCTAssertEqual(fetchCount, 1)

        await XCTAssertThrowsErrorAsync(
            try await avatarLoader.load(avatarURL, owner: .account(accountID))
        ) { error in
            XCTAssertEqual(error as? ForgeAvatarLoadingError, .accountRemoved)
            XCTAssertEqual(
                error.localizedDescription,
                "The Forge Account for this avatar was removed."
            )
        }
        let blockedFetchCount = await transport.fetchCount
        XCTAssertEqual(blockedFetchCount, 1)
        _ = try await services.addAccountCoordinator.addPersonalAccessToken(
            accountID: accountID,
            login: "avatar-user",
            credentialID: ForgeCredentialID("avatar-pat-restored"),
            kind: .fineGrained,
            token: Data("avatar-token-restored".utf8),
            expiresAt: nil
        )
        let restored = try await avatarLoader.load(avatarURL, owner: .account(accountID))
        let restoredFetchCount = await transport.fetchCount
        XCTAssertEqual(restored, payload)
        XCTAssertEqual(restoredFetchCount, 2)
    }

    func testRecoveryLoaderReportsUnavailableOperationsWithoutCoordinatorAndUsesDefaultPolicies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRecoveryUnavailableTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let composed = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: CompositionKeychain(),
            cliRunner: CompositionRunner()
        )
        defer { Task { await composed.database?.close() } }
        let services = ForgeApplicationServices(
            dataAvailability: composed.dataAvailability,
            accountStore: composed.accountStore,
            addAccountCoordinator: composed.addAccountCoordinator,
            removalCoordinator: composed.removalCoordinator,
            githubReadAdapterFactory: composed.githubReadAdapterFactory,
            githubMutationNetworkMonitor: composed.githubMutationNetworkMonitor,
            githubAnonymousRESTBudget: composed.githubAnonymousRESTBudget,
            refreshCoordinator: composed.refreshCoordinator,
            deferredAccountCleanup: composed.deferredAccountCleanup
        )
        let loader = ForgeApplicationServiceLoader { services }

        XCTAssertEqual(
            ForgeApplicationRecoveryError.unavailable.localizedDescription,
            "Forge recovery is unavailable in this application composition."
        )
        XCTAssertEqual(
            ForgeApplicationRecoveryError.sessionDisabled.localizedDescription,
            "Forge features are disabled for the current application session."
        )
        let absentRecovery = try await loader.retryForgeRecovery()
        XCTAssertNil(absentRecovery)
        await XCTAssertThrowsErrorAsync(try await loader.retainedRecoveryCopies()) { error in
            guard case ForgeApplicationRecoveryError.unavailable = error else {
                return XCTFail("recovery-copy enumeration requires a recovery coordinator")
            }
        }
        let explicitCopyURL = root.appendingPathComponent("explicit-copy.sqlite3")
        try Data("copy".utf8).write(to: explicitCopyURL)
        let explicitCopy = ForgeSQLiteRecoveryCopy(url: explicitCopyURL, createdAt: Date())
        await XCTAssertThrowsErrorAsync(try await loader.retryForgeRecovery(explicitCopy)) { error in
            guard case ForgeApplicationRecoveryError.unavailable = error else {
                return XCTFail("explicit recovery requires a recovery coordinator")
            }
        }
        await XCTAssertThrowsErrorAsync(try await loader.resetForgeData()) { error in
            guard case ForgeApplicationRecoveryError.unavailable = error else {
                return XCTFail("reset requires a recovery coordinator")
            }
        }
        await XCTAssertThrowsErrorAsync(try await loader.deleteRecoveryCopy(explicitCopy)) { error in
            guard case ForgeApplicationRecoveryError.unavailable = error else {
                return XCTFail("copy deletion requires a recovery coordinator")
            }
        }

        let defaultPolicyRoot = root.appendingPathComponent("DefaultPolicy", isDirectory: true)
        let defaultPolicyCoordinator = ForgeApplicationRecoveryCoordinator(
            configuration: ForgeSQLiteConfiguration(
                databaseURL: defaultPolicyRoot.appendingPathComponent("Forge.sqlite3"),
                recoveryDirectoryURL: defaultPolicyRoot.appendingPathComponent("Recovery", isDirectory: true)
            ),
            deferredAccountCleanup: ForgeDeferredAccountCleanupStore(forgeDirectory: defaultPolicyRoot)
        )
        let retainedCopies = try await defaultPolicyCoordinator.retainedRecoveryCopies()
        XCTAssertEqual(retainedCopies, [])
        try await defaultPolicyCoordinator.resetForgeData()

        let defaultFactoryRoot = root.appendingPathComponent("DefaultFactory", isDirectory: true)
        let defaultFactoryServices = try await ForgeApplicationServiceFactory.makeDefault(
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            applicationSupportDirectory: { defaultFactoryRoot },
            avatarLoader: nil,
            avatarLoadingEnabled: { false }
        )
        await defaultFactoryServices.database?.close()
    }

    func testFactoryAutomaticallySalvagesDurableRecordsFromANewerConsistentSchema() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeAutomaticRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Forge.sqlite3")
        let source = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: databaseURL,
            recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "automatic-recovery")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let durable = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("automatic".utf8),
            payload: Data("salvaged".utf8),
            lastActivityAt: Date()
        )
        try await source.saveDurableRecord(durable)
        await source.close()
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [databaseURL.path, "PRAGMA user_version=4;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        let avatarLoader = ForgeAvatarLoader(
            transport: CompositionAvatarTransport(
                payload: ForgeAvatarPayload(data: Data([1, 2, 3]), mediaType: .png)
            ),
            loadingEnabled: false,
            requiresBackingStoreInstallation: true
        )

        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: makeDefaults()),
            keychain: CompositionKeychain(),
            cliRunner: CompositionRunner(),
            avatarLoader: avatarLoader,
            avatarLoadingEnabled: { false }
        )
        let recoveredDatabase = try XCTUnwrap(services.database)
        defer { Task { await recoveredDatabase.close() } }

        let recoveredRecord = try await recoveredDatabase.durableRecord(
            kind: durable.kind,
            accountID: accountID,
            repository: repository,
            key: durable.key
        )
        XCTAssertEqual(recoveredRecord?.kind, durable.kind)
        XCTAssertEqual(recoveredRecord?.accountID, durable.accountID)
        XCTAssertEqual(recoveredRecord?.repository, durable.repository)
        XCTAssertEqual(recoveredRecord?.key, durable.key)
        XCTAssertEqual(recoveredRecord?.payload, durable.payload)
        XCTAssertEqual(recoveredRecord?.expiresAt, durable.expiresAt)
        XCTAssertEqual(
            try XCTUnwrap(recoveredRecord?.lastActivityAt).timeIntervalSince1970,
            durable.lastActivityAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testRetryFailureDisablesForgeAndPeriodicRecoveryMaintenanceHandlesUnavailableStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRetryFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: root.appendingPathComponent("Forge.sqlite3"))
        let defaults = try makeDefaults()
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let loader = ForgeApplicationServiceLoader(now: Date.init, maintenanceInterval: 0) {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner()
            )
        }
        let services = try await loader.services()
        let copy = try XCTUnwrap(services.dataAvailability.recoveryCopy)

        await XCTAssertThrowsErrorAsync(try await loader.retryForgeRecovery(copy)) { _ in }
        await XCTAssertThrowsErrorAsync(try await loader.services()) { error in
            guard case ForgeApplicationRecoveryError.sessionDisabled = error else {
                return XCTFail("failed recovery must disable ordinary Forge access for this session")
            }
        }
        guard case let .sessionDisabled(retainedCopy) = try await loader.overlayServices() else {
            return XCTFail("the recovery copy must remain available after a failed retry")
        }
        XCTAssertEqual(retainedCopy, copy)

        let maintenanceRoot = root.appendingPathComponent("MaintenanceFailure", isDirectory: true)
        try FileManager.default.createDirectory(at: maintenanceRoot, withIntermediateDirectories: true)
        let invalidRecoveryDirectory = maintenanceRoot.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidRecoveryDirectory)
        let coordinator = ForgeApplicationRecoveryCoordinator(
            configuration: ForgeSQLiteConfiguration(
                databaseURL: maintenanceRoot.appendingPathComponent("Forge.sqlite3"),
                recoveryDirectoryURL: invalidRecoveryDirectory
            ),
            deferredAccountCleanup: ForgeDeferredAccountCleanupStore(forgeDirectory: maintenanceRoot)
        )
        let maintenanceServices = ForgeApplicationServices(
            dataAvailability: .recoveryRequired(copy),
            accountStore: services.accountStore,
            addAccountCoordinator: services.addAccountCoordinator,
            removalCoordinator: services.removalCoordinator,
            githubReadAdapterFactory: services.githubReadAdapterFactory,
            githubMutationState: services.githubMutationState,
            githubMutationNetworkMonitor: services.githubMutationNetworkMonitor,
            credentialCooldowns: services.credentialCooldowns,
            githubAnonymousRESTBudget: services.githubAnonymousRESTBudget,
            refreshCoordinator: nil,
            deferredAccountCleanup: services.deferredAccountCleanup,
            recoveryCoordinator: coordinator
        )
        let maintenanceLoader = ForgeApplicationServiceLoader(now: Date.init, maintenanceInterval: 0) {
            maintenanceServices
        }
        let maintainedServices = try await maintenanceLoader.services()
        XCTAssertTrue(maintainedServices === maintenanceServices)
    }

    func testSuccessfulRetrySerializesServiceAccessAndReloadsRecoveredDurableState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeSuccessfulRetryTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeSuccessfulRetrySource-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let defaults = try makeDefaults()
        let sourceURL = sourceRoot.appendingPathComponent("Recovery.sqlite3")
        let source = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: sourceURL,
            recoveryDirectoryURL: sourceRoot.appendingPathComponent("Copies", isDirectory: true)
        ))
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "successful-retry")
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        let durable = try ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: accountID,
            repository: repository,
            key: Data("retry".utf8),
            payload: Data("recovered".utf8),
            lastActivityAt: Date()
        )
        try await source.saveDurableRecord(durable)
        await source.close()
        let recoveryCopy = ForgeSQLiteRecoveryCopy(url: sourceURL, createdAt: Date())
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)
        let factory = BlockingSecondCompositionFactory {
            try await ForgeApplicationServiceFactory.make(
                forgeDirectory: root,
                bindingCleaner: bindingCleaner,
                keychain: CompositionKeychain(),
                cliRunner: CompositionRunner()
            )
        }
        let loader = ForgeApplicationServiceLoader { try await factory.load() }
        _ = try await loader.services()

        let retry = Task { try await loader.retryForgeRecovery(recoveryCopy) }
        await factory.waitForSecondInvocation()
        let waitingService = Task { try await loader.accountManagementServices() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await factory.releaseSecondInvocation()
        let result = try await retry.value
        let reloaded = try await waitingService.value
        let database = try XCTUnwrap(reloaded.database)

        XCTAssertEqual(result?.restoredDurableRecordCount, 1)
        let recoveredRecord = try await database.durableRecord(
            kind: durable.kind,
            accountID: accountID,
            repository: repository,
            key: durable.key
        )
        XCTAssertEqual(recoveredRecord?.kind, durable.kind)
        XCTAssertEqual(recoveredRecord?.accountID, durable.accountID)
        XCTAssertEqual(recoveredRecord?.repository, durable.repository)
        XCTAssertEqual(recoveredRecord?.key, durable.key)
        XCTAssertEqual(recoveredRecord?.payload, durable.payload)
        XCTAssertEqual(recoveredRecord?.expiresAt, durable.expiresAt)
        XCTAssertEqual(
            try XCTUnwrap(recoveredRecord?.lastActivityAt).timeIntervalSince1970,
            durable.lastActivityAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        await database.close()
    }

    func testRecoveryCoordinatorClosesReplacementOnMaintenanceFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRecoveryCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRecoveryCleanupSource-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let sourceURL = sourceRoot.appendingPathComponent("Recovery.sqlite3")
        let source = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: sourceURL,
            recoveryDirectoryURL: sourceRoot.appendingPathComponent("Copies", isDirectory: true)
        ))
        await source.close()
        let coordinator = ForgeApplicationRecoveryCoordinator(
            configuration: ForgeSQLiteConfiguration(
                databaseURL: root.appendingPathComponent("Forge.sqlite3"),
                recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
            ),
            deferredAccountCleanup: ForgeDeferredAccountCleanupStore(forgeDirectory: root),
            now: { Date(timeIntervalSince1970: .infinity) }
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.recoverDurableRecords(
                from: ForgeSQLiteRecoveryCopy(url: sourceURL, createdAt: Date())
            )
        ) { _ in }

        let replacement = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: root.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
        ))
        await replacement.close()
    }

    func testResetFailureRetainsRecoveryStateAndDisablesTheSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeResetFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let composed = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root.appendingPathComponent("Composed", isDirectory: true),
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: CompositionKeychain(),
            cliRunner: CompositionRunner()
        )
        await composed.database?.close()
        let protectedRoot = root.appendingPathComponent("Protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        let protectedDatabase = protectedRoot.appendingPathComponent("Forge.sqlite3")
        try Data("protected".utf8).write(to: protectedDatabase)
        let copyURL = root.appendingPathComponent("retained-copy.sqlite3")
        try Data("copy".utf8).write(to: copyURL)
        let copy = ForgeSQLiteRecoveryCopy(url: copyURL, createdAt: Date())
        let coordinator = ForgeApplicationRecoveryCoordinator(
            configuration: ForgeSQLiteConfiguration(
                databaseURL: protectedDatabase,
                recoveryDirectoryURL: protectedRoot.appendingPathComponent("Recovery", isDirectory: true)
            ),
            deferredAccountCleanup: composed.deferredAccountCleanup
        )
        let services = ForgeApplicationServices(
            dataAvailability: .recoveryRequired(copy),
            accountStore: composed.accountStore,
            addAccountCoordinator: composed.addAccountCoordinator,
            removalCoordinator: composed.removalCoordinator,
            githubReadAdapterFactory: composed.githubReadAdapterFactory,
            githubMutationState: composed.githubMutationState,
            githubMutationNetworkMonitor: composed.githubMutationNetworkMonitor,
            credentialCooldowns: composed.credentialCooldowns,
            githubAnonymousRESTBudget: composed.githubAnonymousRESTBudget,
            refreshCoordinator: nil,
            deferredAccountCleanup: composed.deferredAccountCleanup,
            recoveryCoordinator: coordinator
        )
        let loader = ForgeApplicationServiceLoader { services }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedRoot.path)
        }

        await XCTAssertThrowsErrorAsync(try await loader.resetForgeData()) { _ in }
        guard case let .sessionDisabled(retainedCopy) = try await loader.overlayServices() else {
            return XCTFail("a failed reset must disable Forge and retain the selected recovery copy")
        }
        XCTAssertEqual(retainedCopy, copy)
    }

    func testServiceAndOverlayLoadsRejectAConcurrentSessionDisableAfterFactoryCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeSessionDisableRaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: makeDefaults()),
            keychain: CompositionKeychain(),
            cliRunner: CompositionRunner()
        )
        defer { Task { await services.database?.close() } }

        let serviceGate = CompositionServiceLoadGate()
        let serviceLoader = ForgeApplicationServiceLoader { await serviceGate.load() }
        let serviceLoad = Task { try await serviceLoader.services() }
        await serviceGate.waitUntilStarted()
        let serviceDisable = Task { await serviceLoader.disableForgeForSession() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await serviceGate.release(services)
        await XCTAssertThrowsErrorAsync(try await serviceLoad.value) { error in
            guard case ForgeApplicationRecoveryError.sessionDisabled = error else {
                return XCTFail("a session disable must win over an in-flight service publication")
            }
        }
        await serviceDisable.value

        let overlayGate = CompositionServiceLoadGate()
        let overlayLoader = ForgeApplicationServiceLoader { await overlayGate.load() }
        let overlayLoad = Task { try await overlayLoader.overlayServices() }
        await overlayGate.waitUntilStarted()
        let overlayDisable = Task { await overlayLoader.disableForgeForSession() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await overlayGate.release(services)
        guard case .sessionDisabled = try await overlayLoad.value else {
            return XCTFail("an overlay session disable must win over in-flight publication")
        }
        await overlayDisable.value
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ForgeApplicationCompositionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshotKey(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        identity: String
    ) throws -> ForgeDisposableCacheKey {
        try .snapshot(ForgeCacheRecordKey(
            repositoryPartition: ForgeRepositoryPartitionKey(
                cachePartition: .account(accountID),
                repository: repository
            ),
            kind: .repositoryFacts,
            identity: identity
        ))
    }

    private func cacheEntry(
        key: ForgeDisposableCacheKey,
        payload: String,
        at date: Date
    ) throws -> ForgeSQLiteCacheEntry {
        let data = Data(payload.utf8)
        return try ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: key,
                byteCount: UInt64(data.count),
                fetchedAt: date,
                lastAccessedAt: date
            ),
            payload: data
        )
    }
}

private enum CompositionFactoryError: Error, Equatable {
    case expectedFailure
}

// swift6-safety-justification: The lock serializes all mutable probe counters and thread observations.
private final nonisolated class CompositionFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var threads: [Bool] = []

    var invocationCount: Int {
        lock.withLock { count }
    }

    var invocationThreads: [Bool] {
        lock.withLock { threads }
    }

    @discardableResult
    func recordInvocation() -> Int {
        lock.withLock {
            count += 1
            threads.append(Thread.isMainThread)
            return count
        }
    }
}

// swift6-safety-justification: The lock serializes the mutable preference used by a detached factory task.
private final nonisolated class CompositionAvatarLoadingAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    init(_ enabled: Bool) {
        self.enabled = enabled
    }

    var value: Bool {
        lock.withLock { enabled }
    }

    func set(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }
}

// swift6-safety-justification: The lock serializes mutable dates captured by detached factory tasks.
private final nonisolated class CompositionDateAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var value: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

// swift6-safety-justification: The lock serializes notification thread observations.
private final nonisolated class CompositionThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var mainThreadValues: [Bool] {
        lock.withLock { values }
    }

    func recordCurrentThread() {
        lock.withLock { values.append(Thread.isMainThread) }
    }
}

// swift6-safety-justification: The lock serializes all mutable test-double thread observations.
private final nonisolated class CompositionKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    private var storage: [String: Data] = [:]

    var accessThreads: [Bool] {
        lock.withLock { threads }
    }

    func data(for accountKey: String) throws -> Data? {
        lock.withLock {
            threads.append(Thread.isMainThread)
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        lock.withLock {
            threads.append(Thread.isMainThread)
            return storage.map(ForgeKeychainItem.init(accountKey:data:))
        }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        lock.withLock {
            threads.append(Thread.isMainThread)
            storage[accountKey] = data
        }
    }

    func remove(accountKey: String) throws {
        lock.withLock {
            threads.append(Thread.isMainThread)
            storage.removeValue(forKey: accountKey)
        }
    }
}

private actor CompositionRunner: ForgeCLICommandRunning {
    private(set) var commandCount = 0

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        commandCount += 1
        throw ForgeCLIBrokerError.commandLaunchFailed
    }
}

private actor CompositionAvatarTransport: ForgeAvatarTransport {
    let payload: ForgeAvatarPayload
    private(set) var fetchCount = 0

    init(payload: ForgeAvatarPayload) {
        self.payload = payload
    }

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        fetchCount += 1
        return payload
    }
}

private actor BlockingSecondCompositionFactory {
    typealias Factory = @Sendable () async throws -> ForgeApplicationServices

    private let factory: Factory
    private var invocationCount = 0
    private var secondInvocationContinuation: CheckedContinuation<Void, Never>?
    private var secondInvocationWaiters: [CheckedContinuation<Void, Never>] = []

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func load() async throws -> ForgeApplicationServices {
        invocationCount += 1
        if invocationCount == 2 {
            let waiters = secondInvocationWaiters
            secondInvocationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { secondInvocationContinuation = $0 }
        }
        return try await factory()
    }

    func waitForSecondInvocation() async {
        guard invocationCount < 2 else { return }
        await withCheckedContinuation { secondInvocationWaiters.append($0) }
    }

    func releaseSecondInvocation() {
        secondInvocationContinuation?.resume()
        secondInvocationContinuation = nil
    }
}

private actor CompositionServiceLoadGate {
    private var continuation: CheckedContinuation<ForgeApplicationServices, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async -> ForgeApplicationServices {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ services: ForgeApplicationServices) {
        continuation?.resume(returning: services)
        continuation = nil
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
