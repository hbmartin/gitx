import ForgeKit
import XCTest

final class ForgeApplicationCompositionTests: XCTestCase {
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
        let services = try await ForgeApplicationServiceFactory.make(
            forgeDirectory: root,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            keychain: keychain,
            cliRunner: runner
        )

        XCTAssertNil(services.database)
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

    private func makeDefaults() throws -> UserDefaults {
        let name = "ForgeApplicationCompositionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
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

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
