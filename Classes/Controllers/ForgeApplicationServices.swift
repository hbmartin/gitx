import ForgeKit
import Foundation
import OSLog

nonisolated enum ForgeApplicationDataAvailability: Sendable {
    case available(ForgeSQLiteStore)
    case recoveryRequired(ForgeSQLiteRecoveryCopy)

    var database: ForgeSQLiteStore? {
        switch self {
        case let .available(database): database
        case .recoveryRequired: nil
        }
    }

    var recoveryCopy: ForgeSQLiteRecoveryCopy? {
        switch self {
        case .available: nil
        case let .recoveryRequired(copy): copy
        }
    }
}

actor ForgeDeferredAccountCleanupStore {
    private struct Entry: Codable {
        let accountID: ForgeAccountID
        var recoveryCopyURLs: [URL]
    }

    private struct Payload: Codable {
        let version: Int
        var entries: [Entry]
    }

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeRecovery")

    init(forgeDirectory: URL) {
        fileURL = Self.tombstoneURL(in: forgeDirectory)
    }

    func record(_ accountID: ForgeAccountID, recoveryCopy: ForgeSQLiteRecoveryCopy) throws {
        var payload = try load()
        let recoveryURLs = [recoveryCopy.url] + recoveryCopy.sidecarURLs
        if let index = payload.entries.firstIndex(where: { $0.accountID == accountID }) {
            payload.entries[index].recoveryCopyURLs = Array(Set(
                payload.entries[index].recoveryCopyURLs + recoveryURLs
            )).sorted { $0.absoluteString < $1.absoluteString }
        } else {
            payload.entries.append(Entry(accountID: accountID, recoveryCopyURLs: recoveryURLs))
        }
        payload.entries.sort { Self.sortsBefore($0.accountID, $1.accountID) }
        try persist(payload)
        logger.notice("Recorded deferred account cleanup while Forge recovery is required")
    }

    func replay(into database: ForgeSQLiteStore) async throws {
        var payload = try load()
        for entry in payload.entries {
            try await database.removeAccount(entry.accountID)
        }
        payload.entries.removeAll { entry in
            entry.recoveryCopyURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
        try persist(payload)
        logger.notice("Replayed deferred Forge account cleanup")
    }

    /// Recovery copies are quarantined archival evidence, never live account
    /// state. Preserve each tombstone while a named copy exists and filter that
    /// account from every salvage so removing one account cannot reseed it or
    /// discard another account's recoverable records.
    func filtering(_ salvage: ForgeSQLiteSalvage) throws -> ForgeSQLiteSalvage {
        let payload = try load()
        let excludedAccounts = Set(payload.entries.map(\.accountID))
        let retained = salvage.durableRecords.filter { !excludedAccounts.contains($0.accountID) }
        return ForgeSQLiteSalvage(
            durableRecords: retained,
            skippedRecordCount: salvage.skippedRecordCount + salvage.durableRecords.count - retained.count
        )
    }

    static func tombstoneURL(in forgeDirectory: URL) -> URL {
        forgeDirectory.appendingPathComponent("DeferredAccountCleanup.json")
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Payload(version: 2, entries: [])
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        guard payload.version == 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return payload
    }

    private func persist(_ payload: Payload) throws {
        if payload.entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(directoryValues)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableFile = fileURL
        try mutableFile.setResourceValues(fileValues)
    }

    private static func sortsBefore(_ lhs: ForgeAccountID, _ rhs: ForgeAccountID) -> Bool {
        let lhsKey = [lhs.forge.kind.rawValue, lhs.forge.origin.url.absoluteString, lhs.value]
        let rhsKey = [rhs.forge.kind.rawValue, rhs.forge.origin.url.absoluteString, rhs.value]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
}

nonisolated struct ForgeRecoveryDeferredAccountPersistenceCleaner: ForgeAccountPersistenceCleaning {
    private let tombstoneStore: ForgeDeferredAccountCleanupStore
    private let recoveryCopy: ForgeSQLiteRecoveryCopy
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeRecovery")

    init(
        tombstoneStore: ForgeDeferredAccountCleanupStore,
        recoveryCopy: ForgeSQLiteRecoveryCopy
    ) {
        self.tombstoneStore = tombstoneStore
        self.recoveryCopy = recoveryCopy
    }

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        try await tombstoneStore.record(accountID, recoveryCopy: recoveryCopy)
        logger.notice("Deferred inaccessible Forge database cleanup for replay after recovery")
    }
}

final nonisolated class ForgeApplicationServices: Sendable {
    let dataAvailability: ForgeApplicationDataAvailability
    let accountStore: ForgeAccountStore
    let addAccountCoordinator: ForgeAddAccountCoordinator
    let removalCoordinator: ForgeAccountRemovalCoordinator
    let githubReadAdapterFactory: ForgeGitHubReadAdapterFactory
    let deferredAccountCleanup: ForgeDeferredAccountCleanupStore

    var database: ForgeSQLiteStore? {
        dataAvailability.database
    }

    init(
        dataAvailability: ForgeApplicationDataAvailability,
        accountStore: ForgeAccountStore,
        addAccountCoordinator: ForgeAddAccountCoordinator,
        removalCoordinator: ForgeAccountRemovalCoordinator,
        githubReadAdapterFactory: ForgeGitHubReadAdapterFactory,
        deferredAccountCleanup: ForgeDeferredAccountCleanupStore
    ) {
        self.dataAvailability = dataAvailability
        self.accountStore = accountStore
        self.addAccountCoordinator = addAccountCoordinator
        self.removalCoordinator = removalCoordinator
        self.githubReadAdapterFactory = githubReadAdapterFactory
        self.deferredAccountCleanup = deferredAccountCleanup
    }
}

actor ForgeApplicationServiceLoader {
    typealias Factory = @Sendable () async throws -> ForgeApplicationServices

    private let factory: Factory
    private var loadingTask: Task<ForgeApplicationServices, Error>?
    private var generation: UInt64 = 0
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeComposition")

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    init(
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        applicationSupportDirectory: @escaping ForgeApplicationServiceFactory.ApplicationSupportDirectoryProvider =
            ForgeApplicationServiceFactory.systemApplicationSupportDirectory
    ) {
        factory = {
            try await ForgeApplicationServiceFactory.makeDefault(
                bindingCleaner: bindingCleaner,
                applicationSupportDirectory: applicationSupportDirectory
            )
        }
    }

    func services() async throws -> ForgeApplicationServices {
        if let loadingTask {
            return try await loadingTask.value
        }
        generation &+= 1
        let requestedGeneration = generation
        let factory = factory
        let task = Task.detached(priority: .utility) {
            try await factory()
        }
        loadingTask = task
        do {
            let services = try await task.value
            logger.notice("Lazy Forge application services initialized")
            return services
        } catch {
            if generation == requestedGeneration {
                loadingTask = nil
            }
            logger.error("Lazy Forge application services initialization failed")
            throw error
        }
    }
}

nonisolated enum ForgeApplicationServiceFactory {
    typealias ApplicationSupportDirectoryProvider = @Sendable () throws -> URL

    static func makeDefault(
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        applicationSupportDirectory: ApplicationSupportDirectoryProvider = systemApplicationSupportDirectory
    ) async throws -> ForgeApplicationServices {
        let applicationSupportURL = try applicationSupportDirectory()
        let forgeDirectory = applicationSupportURL
            .appendingPathComponent("GitX", isDirectory: true)
            .appendingPathComponent("Forge", isDirectory: true)
        return try await make(
            forgeDirectory: forgeDirectory,
            bindingCleaner: bindingCleaner,
            keychain: SecurityForgeCredentialKeychain(),
            cliRunner: SystemForgeCLICommandRunner()
        )
    }

    static func systemApplicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func make(
        forgeDirectory: URL,
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        keychain: any ForgeCredentialKeychain,
        cliRunner: any ForgeCLICommandRunning
    ) async throws -> ForgeApplicationServices {
        let accountStore = ForgeAccountStore(keychain: keychain)
        let tombstoneStore = ForgeDeferredAccountCleanupStore(forgeDirectory: forgeDirectory)
        let databaseConfiguration = ForgeSQLiteConfiguration(
            databaseURL: forgeDirectory.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: forgeDirectory.appendingPathComponent("Recovery", isDirectory: true)
        )
        let dataAvailability: ForgeApplicationDataAvailability
        let persistenceCleaner: any ForgeAccountPersistenceCleaning
        do {
            let database = try ForgeSQLiteStore(configuration: databaseConfiguration)
            try await tombstoneStore.replay(into: database)
            dataAvailability = .available(database)
            persistenceCleaner = database
        } catch let ForgeSQLiteError.recoveryRequired(copy, _) {
            dataAvailability = .recoveryRequired(copy)
            persistenceCleaner = ForgeRecoveryDeferredAccountPersistenceCleaner(
                tombstoneStore: tombstoneStore,
                recoveryCopy: copy
            )
        }
        let broker = GitHubCLIAccountBroker(runner: cliRunner)
        let addAccountCoordinator = ForgeAddAccountCoordinator(
            accountStore: accountStore,
            cliBroker: broker
        )
        let removalCoordinator = ForgeAccountRemovalCoordinator(
            accountStore: accountStore,
            persistenceCleaner: persistenceCleaner,
            bindingCleaner: bindingCleaner,
            avatarCleaner: PreservingSharedForgeAvatarCleaner()
        )
        let credentialAuthority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        return ForgeApplicationServices(
            dataAvailability: dataAvailability,
            accountStore: accountStore,
            addAccountCoordinator: addAccountCoordinator,
            removalCoordinator: removalCoordinator,
            githubReadAdapterFactory: ForgeGitHubReadAdapterFactory(
                credentialAuthority: credentialAuthority
            ),
            deferredAccountCleanup: tombstoneStore
        )
    }
}
