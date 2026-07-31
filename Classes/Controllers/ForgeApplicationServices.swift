import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

extension Notification.Name {
    nonisolated static let forgeApplicationAvailabilityDidChange = Notification.Name(
        "PBForgeApplicationAvailabilityDidChangeNotification"
    )
}

/// One process-lifetime anonymous allowance is shared by repository overlays,
/// native list/detail surfaces, and every service generation after recovery.
nonisolated enum ForgeAnonymousRESTProcessRuntime {
    static let budget = GitHubAnonymousRESTBudget()
    static let adapter = GitHubAnonymousRESTAdapter(budget: budget)
}

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

nonisolated struct ForgeApplicationMaintenanceResult: Equatable, Sendable {
    let idleCacheRecordsRemoved: Int
    let expiredDurableRecordsRemoved: Int
    let cacheLimitRecordsRemoved: Int
}

nonisolated struct ForgeApplicationRecoveryResult: Equatable, Sendable {
    let restoredDurableRecordCount: Int
    let skippedDurableRecordCount: Int
    let maintenance: ForgeApplicationMaintenanceResult
}

nonisolated enum ForgeApplicationRecoveryError: Error, LocalizedError, Sendable {
    case unavailable
    case sessionDisabled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Forge recovery is unavailable in this application composition."
        case .sessionDisabled:
            "Forge features are disabled for the current application session."
        }
    }
}

/// Owns the destructive filesystem boundary for Forge database recovery.
/// Accounts remain in Keychain and repository bindings remain in Repository
/// View State because neither store is reachable through this coordinator.
actor ForgeApplicationRecoveryCoordinator {
    private let configuration: ForgeSQLiteConfiguration
    private let deferredAccountCleanup: ForgeDeferredAccountCleanupStore
    private let clearTrustedExternalOrigins: @MainActor @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeRecovery")

    init(
        configuration: ForgeSQLiteConfiguration,
        deferredAccountCleanup: ForgeDeferredAccountCleanupStore,
        clearTrustedExternalOrigins: @escaping @MainActor @Sendable () -> Void = {},
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.deferredAccountCleanup = deferredAccountCleanup
        self.clearTrustedExternalOrigins = clearTrustedExternalOrigins
        self.now = now
    }

    func retainedRecoveryCopies() async throws -> [ForgeSQLiteRecoveryCopy] {
        let copies = try ForgeSQLiteStore.recoveryCopies(
            in: configuration.recoveryDirectoryURL,
            now: now()
        )
        try await deferredAccountCleanup.pruneResolvedEntries()
        logger.info("Retained \(copies.count) unexpired Forge database recovery copies")
        return copies
    }

    func performMaintenance(on database: ForgeSQLiteStore) async throws -> ForgeApplicationMaintenanceResult {
        let maintenanceDate = now()
        _ = try await retainedRecoveryCopies()
        let idleCacheRecordsRemoved = try await database.removeIdleCacheRepositories(
            notAccessedSince: maintenanceDate.addingTimeInterval(-ForgePolicyConstants.repositoryIdleExpiration)
        )
        let expiredDurableRecordsRemoved = try await database.removeExpiredDurableRecords(at: maintenanceDate)
        let cacheLimitRecordsRemoved = try await database.enforceCacheLimits()
        let result = ForgeApplicationMaintenanceResult(
            idleCacheRecordsRemoved: idleCacheRecordsRemoved,
            expiredDurableRecordsRemoved: expiredDurableRecordsRemoved,
            cacheLimitRecordsRemoved: cacheLimitRecordsRemoved
        )
        logger.info(
            "Completed Forge retention maintenance idle=\(idleCacheRecordsRemoved) durable=\(expiredDurableRecordsRemoved) lru=\(cacheLimitRecordsRemoved)"
        )
        return result
    }

    /// Salvages only durable records. Disposable snapshots are deliberately
    /// rebuilt after a recovery, preserving the public/account cache boundary.
    func recoverDurableRecords(from recoveryCopy: ForgeSQLiteRecoveryCopy) async throws
        -> ForgeApplicationRecoveryResult
    {
        let salvage = try ForgeSQLiteStore.salvageDurableRecords(from: recoveryCopy.url)
        let filteredSalvage = try await deferredAccountCleanup.filtering(salvage)
        try removeLiveDatabaseFiles()
        let replacement = try ForgeSQLiteStore(configuration: configuration)
        do {
            try await replacement.restore(filteredSalvage)
            try await deferredAccountCleanup.replay(into: replacement)
            let maintenance = try await performMaintenance(on: replacement)
            await replacement.close()
            let result = ForgeApplicationRecoveryResult(
                restoredDurableRecordCount: filteredSalvage.durableRecords.count,
                skippedDurableRecordCount: filteredSalvage.skippedRecordCount,
                maintenance: maintenance
            )
            logger.notice(
                "Recovered Forge durable state restored=\(result.restoredDurableRecordCount) skipped=\(result.skippedDurableRecordCount)"
            )
            return result
        } catch {
            await replacement.close()
            logger.error("Forge durable-state recovery failed; retained recovery copy remains available")
            throw error
        }
    }

    /// Removes only Forge database files. Keychain accounts and Repository View
    /// State bindings remain intact; the accepted reset policy additionally
    /// clears exact trusted external origins from Application Preferences.
    func resetForgeData() async throws {
        try removeLiveDatabaseFiles()
        await clearTrustedExternalOrigins()
        logger.notice("Reset Forge database and cleared trusted external origins")
    }

    func deleteRecoveryCopy(_ copy: ForgeSQLiteRecoveryCopy) throws {
        try ForgeSQLiteStore.deleteRecoveryCopy(copy, in: configuration.recoveryDirectoryURL)
        logger.notice("Permanently deleted one Forge recovery copy at explicit user request")
    }

    private func removeLiveDatabaseFiles() throws {
        let fileManager = FileManager.default
        for url in [
            configuration.databaseURL,
            URL(fileURLWithPath: configuration.databaseURL.path + "-wal"),
            URL(fileURLWithPath: configuration.databaseURL.path + "-shm"),
            URL(fileURLWithPath: configuration.databaseURL.path + "-journal"),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
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
        Self.removeResolvedEntries(from: &payload)
        try persist(payload)
        logger.notice("Replayed deferred Forge account cleanup")
    }

    func pruneResolvedEntries() throws {
        var payload = try load()
        let previousCount = payload.entries.count
        Self.removeResolvedEntries(from: &payload)
        guard payload.entries.count != previousCount else { return }
        try persist(payload)
        logger.notice("Removed resolved deferred Forge account-cleanup tombstones")
    }

    /// Recovery copies are quarantined archival evidence, never live account
    /// state. Preserve each tombstone while a named copy exists and filter that
    /// account from every salvage so removing one account cannot reseed it or
    /// discard another account's recoverable records.
    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
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

    private static func removeResolvedEntries(from payload: inout Payload) {
        payload.entries.removeAll { entry in
            entry.recoveryCopyURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
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
    let githubMutationState: ForgeGitHubMutationStateStore
    let githubMutationNetworkMonitor: ForgeGitHubMutationNetworkMonitor?
    let credentialCooldowns: ForgeCredentialCooldownRegistry
    let githubAnonymousRESTBudget: GitHubAnonymousRESTBudget
    let refreshCoordinator: ForgeApplicationRefreshCoordinator?
    let deferredAccountCleanup: ForgeDeferredAccountCleanupStore
    let recoveryCoordinator: ForgeApplicationRecoveryCoordinator?

    var database: ForgeSQLiteStore? {
        dataAvailability.database
    }

    init(
        dataAvailability: ForgeApplicationDataAvailability,
        accountStore: ForgeAccountStore,
        addAccountCoordinator: ForgeAddAccountCoordinator,
        removalCoordinator: ForgeAccountRemovalCoordinator,
        githubReadAdapterFactory: ForgeGitHubReadAdapterFactory,
        githubMutationState: ForgeGitHubMutationStateStore? = nil,
        githubMutationNetworkMonitor: ForgeGitHubMutationNetworkMonitor? = nil,
        credentialCooldowns: ForgeCredentialCooldownRegistry? = nil,
        githubAnonymousRESTBudget: GitHubAnonymousRESTBudget = ForgeAnonymousRESTProcessRuntime.budget,
        refreshCoordinator: ForgeApplicationRefreshCoordinator? = nil,
        deferredAccountCleanup: ForgeDeferredAccountCleanupStore,
        recoveryCoordinator: ForgeApplicationRecoveryCoordinator? = nil
    ) {
        self.dataAvailability = dataAvailability
        self.accountStore = accountStore
        self.addAccountCoordinator = addAccountCoordinator
        self.removalCoordinator = removalCoordinator
        self.githubReadAdapterFactory = githubReadAdapterFactory
        let sharedMutationState = githubMutationState ?? ForgeGitHubMutationStateStore(
            sessionGate: githubReadAdapterFactory.sessionGate
        )
        self.githubMutationState = sharedMutationState
        self.githubMutationNetworkMonitor = githubMutationNetworkMonitor
        self.credentialCooldowns = credentialCooldowns ?? ForgeCredentialCooldownRegistry(
            sessionGate: sharedMutationState.sessionGate
        )
        self.githubAnonymousRESTBudget = githubAnonymousRESTBudget
        self.refreshCoordinator = refreshCoordinator
        self.deferredAccountCleanup = deferredAccountCleanup
        self.recoveryCoordinator = recoveryCoordinator
    }
}

nonisolated enum ForgeApplicationOverlayServices: Sendable {
    case enabled(ForgeApplicationServices)
    case sessionDisabled(ForgeSQLiteRecoveryCopy?)
}

actor ForgeApplicationServiceLoader {
    typealias Factory = @Sendable () async throws -> ForgeApplicationServices

    private let factory: Factory
    private let now: @Sendable () -> Date
    private let maintenanceInterval: TimeInterval
    private var loadingTask: Task<ForgeApplicationServices, Error>?
    private var generation: UInt64 = 0
    private var forgeDisabledForSession = false
    private var lastRecoveryCopy: ForgeSQLiteRecoveryCopy?
    private var lastMaintenanceAt: Date?
    private var destructiveOperationInProgress = false
    private var destructiveOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var serviceWaiters: [CheckedContinuation<Void, Never>] = []
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeComposition")

    init(factory: @escaping Factory) {
        self.factory = factory
        now = Date.init
        maintenanceInterval = 24 * 60 * 60
    }

    init(
        now: @escaping @Sendable () -> Date,
        maintenanceInterval: TimeInterval = 24 * 60 * 60,
        factory: @escaping Factory
    ) {
        self.factory = factory
        self.now = now
        self.maintenanceInterval = maintenanceInterval
    }

    init(
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        applicationSupportDirectory: @escaping ForgeApplicationServiceFactory.ApplicationSupportDirectoryProvider =
            ForgeApplicationServiceFactory.systemApplicationSupportDirectory,
        avatarLoader: ForgeAvatarLoader?,
        avatarLoadingEnabled: @escaping @Sendable () -> Bool,
        trustedExternalOrigins: ForgeTrustedExternalOriginStore? = nil,
        githubAnonymousRESTBudget: GitHubAnonymousRESTBudget = ForgeAnonymousRESTProcessRuntime.budget,
        now: @escaping @Sendable () -> Date = Date.init,
        maintenanceInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.now = now
        self.maintenanceInterval = maintenanceInterval
        factory = {
            try await ForgeApplicationServiceFactory.makeDefault(
                bindingCleaner: bindingCleaner,
                applicationSupportDirectory: applicationSupportDirectory,
                avatarLoader: avatarLoader,
                avatarLoadingEnabled: avatarLoadingEnabled,
                trustedExternalOrigins: trustedExternalOrigins,
                githubAnonymousRESTBudget: githubAnonymousRESTBudget,
                now: now
            )
        }
    }

    func services() async throws -> ForgeApplicationServices {
        await waitForDestructiveOperation()
        guard !forgeDisabledForSession else {
            throw ForgeApplicationRecoveryError.sessionDisabled
        }
        let applicationServices = try await loadServicesIgnoringSessionGate()
        guard !forgeDisabledForSession else {
            throw ForgeApplicationRecoveryError.sessionDisabled
        }
        await performMaintenanceIfNeeded(on: applicationServices)
        return applicationServices
    }

    /// Application Preferences may continue account management while ordinary
    /// Forge reads and writes are disabled for the current session.
    func accountManagementServices() async throws -> ForgeApplicationServices {
        await waitForDestructiveOperation()
        let applicationServices = try await loadServicesIgnoringSessionGate()
        await performMaintenanceIfNeeded(on: applicationServices)
        return applicationServices
    }

    private func loadServicesIgnoringSessionGate() async throws -> ForgeApplicationServices {
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
            lastRecoveryCopy = services.dataAvailability.recoveryCopy
            if lastMaintenanceAt == nil {
                lastMaintenanceAt = now()
            }
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

    func overlayServices() async throws -> ForgeApplicationOverlayServices {
        await waitForDestructiveOperation()
        guard !forgeDisabledForSession else {
            return .sessionDisabled(lastRecoveryCopy)
        }
        let applicationServices = try await loadServicesIgnoringSessionGate()
        guard !forgeDisabledForSession else {
            return .sessionDisabled(lastRecoveryCopy)
        }
        await performMaintenanceIfNeeded(on: applicationServices)
        return .enabled(applicationServices)
    }

    func disableForgeForSession() async {
        await waitForDestructiveOperation()
        forgeDisabledForSession = true
        if let loadingTask, let services = try? await loadingTask.value {
            lastRecoveryCopy = services.dataAvailability.recoveryCopy
            await services.refreshCoordinator?.invalidate()
        }
        await notifyAvailabilityChanged()
        logger.notice("Disabled Forge features for the current session; local Git remains available")
    }

    func retainedRecoveryCopies() async throws -> [ForgeSQLiteRecoveryCopy] {
        let applicationServices = try await accountManagementServices()
        guard let recoveryCoordinator = applicationServices.recoveryCoordinator else {
            throw ForgeApplicationRecoveryError.unavailable
        }
        return try await recoveryCoordinator.retainedRecoveryCopies()
    }

    @discardableResult
    func retryForgeRecovery(_ recoveryCopy: ForgeSQLiteRecoveryCopy? = nil) async throws
        -> ForgeApplicationRecoveryResult?
    {
        await beginDestructiveOperation()
        defer { endDestructiveOperation() }
        let currentServices = try await loadServicesIgnoringSessionGate()
        let requestedCopy = recoveryCopy ?? currentServices.dataAvailability.recoveryCopy ?? lastRecoveryCopy
        guard let targetCopy = requestedCopy else {
            forgeDisabledForSession = false
            await notifyAvailabilityChanged()
            return nil
        }
        guard FileManager.default.fileExists(atPath: targetCopy.url.path) else {
            throw ForgeApplicationRecoveryError.unavailable
        }
        guard let recoveryCoordinator = currentServices.recoveryCoordinator else {
            throw ForgeApplicationRecoveryError.unavailable
        }
        invalidateLoadedServices()
        await currentServices.refreshCoordinator?.invalidate()
        if let database = currentServices.database {
            await database.close()
        }
        do {
            let result = try await recoveryCoordinator.recoverDurableRecords(from: targetCopy)
            forgeDisabledForSession = false
            _ = try await loadServicesIgnoringSessionGate()
            await notifyAvailabilityChanged()
            logger.notice("Retried Forge recovery and reloaded application services")
            return result
        } catch {
            await persistRecoveryFailure(copy: targetCopy)
            throw error
        }
    }

    func resetForgeData() async throws {
        await beginDestructiveOperation()
        defer { endDestructiveOperation() }
        let currentServices = try await loadServicesIgnoringSessionGate()
        guard let recoveryCoordinator = currentServices.recoveryCoordinator else {
            throw ForgeApplicationRecoveryError.unavailable
        }
        let recoveryCopy = currentServices.dataAvailability.recoveryCopy ?? lastRecoveryCopy
        invalidateLoadedServices()
        await currentServices.refreshCoordinator?.invalidate()
        if let database = currentServices.database {
            await database.close()
        }
        do {
            try await recoveryCoordinator.resetForgeData()
            forgeDisabledForSession = false
            _ = try await loadServicesIgnoringSessionGate()
            await notifyAvailabilityChanged()
            logger.notice("Reloaded Forge application services after explicit reset")
        } catch {
            await persistRecoveryFailure(copy: recoveryCopy)
            throw error
        }
    }

    func deleteRecoveryCopy(_ recoveryCopy: ForgeSQLiteRecoveryCopy) async throws {
        let applicationServices = try await accountManagementServices()
        guard let recoveryCoordinator = applicationServices.recoveryCoordinator else {
            throw ForgeApplicationRecoveryError.unavailable
        }
        try await recoveryCoordinator.deleteRecoveryCopy(recoveryCopy)
        if lastRecoveryCopy?.url == recoveryCopy.url {
            lastRecoveryCopy = nil
        }
    }

    private func invalidateLoadedServices() {
        generation &+= 1
        loadingTask = nil
        lastMaintenanceAt = nil
    }

    private func performMaintenanceIfNeeded(on services: ForgeApplicationServices) async {
        let maintenanceDate = now()
        guard let lastMaintenanceAt else {
            lastMaintenanceAt = maintenanceDate
            return
        }
        guard maintenanceDate.timeIntervalSince(lastMaintenanceAt) >= maintenanceInterval,
              let recoveryCoordinator = services.recoveryCoordinator
        else { return }
        do {
            if let database = services.database {
                _ = try await recoveryCoordinator.performMaintenance(on: database)
            } else {
                _ = try await recoveryCoordinator.retainedRecoveryCopies()
            }
            self.lastMaintenanceAt = maintenanceDate
        } catch {
            logger.error("Periodic Forge retention maintenance failed; will retry on the next access")
        }
    }

    private func beginDestructiveOperation() async {
        guard destructiveOperationInProgress else {
            destructiveOperationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            destructiveOperationWaiters.append(continuation)
        }
    }

    private func endDestructiveOperation() {
        if !destructiveOperationWaiters.isEmpty {
            destructiveOperationWaiters.removeFirst().resume()
            return
        }
        destructiveOperationInProgress = false
        let waiters = serviceWaiters
        serviceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForDestructiveOperation() async {
        while destructiveOperationInProgress {
            await withCheckedContinuation { continuation in
                serviceWaiters.append(continuation)
            }
        }
    }

    private func persistRecoveryFailure(copy: ForgeSQLiteRecoveryCopy?) async {
        invalidateLoadedServices()
        forgeDisabledForSession = true
        lastRecoveryCopy = copy
        await notifyAvailabilityChanged()
        logger.error("Forge recovery operation failed; unpublished closed services remain invalidated")
    }

    private func notifyAvailabilityChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .forgeApplicationAvailabilityDidChange, object: nil)
        }
    }
}

nonisolated enum ForgeApplicationServiceFactory {
    typealias ApplicationSupportDirectoryProvider = @Sendable () throws -> URL

    static func makeDefault(
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        applicationSupportDirectory: ApplicationSupportDirectoryProvider = systemApplicationSupportDirectory,
        avatarLoader: ForgeAvatarLoader?,
        avatarLoadingEnabled: @escaping @Sendable () -> Bool,
        trustedExternalOrigins: ForgeTrustedExternalOriginStore? = nil,
        githubAnonymousRESTBudget: GitHubAnonymousRESTBudget = ForgeAnonymousRESTProcessRuntime.budget,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ForgeApplicationServices {
        let applicationSupportURL = try applicationSupportDirectory()
        let forgeDirectory = applicationSupportURL
            .appendingPathComponent("GitX", isDirectory: true)
            .appendingPathComponent("Forge", isDirectory: true)
        return try await make(
            forgeDirectory: forgeDirectory,
            bindingCleaner: bindingCleaner,
            keychain: SecurityForgeCredentialKeychain(),
            cliRunner: SystemForgeCLICommandRunner(),
            avatarLoader: avatarLoader,
            avatarLoadingEnabled: avatarLoadingEnabled,
            trustedExternalOrigins: trustedExternalOrigins,
            githubAnonymousRESTBudget: githubAnonymousRESTBudget,
            now: now
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
        cliRunner: any ForgeCLICommandRunning,
        avatarLoader: ForgeAvatarLoader? = nil,
        avatarLoadingEnabled: @escaping @Sendable () -> Bool = { true },
        trustedExternalOrigins: ForgeTrustedExternalOriginStore? = nil,
        githubAnonymousRESTBudget: GitHubAnonymousRESTBudget = ForgeAnonymousRESTProcessRuntime.budget,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ForgeApplicationServices {
        let accountStore = ForgeAccountStore(keychain: keychain)
        let tombstoneStore = ForgeDeferredAccountCleanupStore(forgeDirectory: forgeDirectory)
        let databaseConfiguration = ForgeSQLiteConfiguration(
            databaseURL: forgeDirectory.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: forgeDirectory.appendingPathComponent("Recovery", isDirectory: true)
        )
        let recoveryCoordinator = ForgeApplicationRecoveryCoordinator(
            configuration: databaseConfiguration,
            deferredAccountCleanup: tombstoneStore,
            clearTrustedExternalOrigins: {
                _ = trustedExternalOrigins?.removeAll()
            },
            now: now
        )
        _ = try await recoveryCoordinator.retainedRecoveryCopies()
        let dataAvailability: ForgeApplicationDataAvailability
        let persistenceCleaner: any ForgeAccountPersistenceCleaning
        let avatarCleaner: any ForgeAccountAvatarCleaning
        do {
            let database = try ForgeSQLiteStore(configuration: databaseConfiguration)
            try await tombstoneStore.replay(into: database)
            _ = try await recoveryCoordinator.performMaintenance(on: database)
            if let avatarLoader {
                try await avatarLoader.installBackingStore(
                    ForgeSQLiteAvatarBackingStore(store: database),
                    loadingEnabled: avatarLoadingEnabled()
                )
            }
            dataAvailability = .available(database)
            persistenceCleaner = database
            avatarCleaner = ForgeSQLiteAvatarAccountCleaner(
                store: database,
                loader: avatarLoader
            )
        } catch let ForgeSQLiteError.recoveryRequired(copy, _) {
            do {
                _ = try await recoveryCoordinator.recoverDurableRecords(from: copy)
                let database = try ForgeSQLiteStore(configuration: databaseConfiguration)
                try await tombstoneStore.replay(into: database)
                _ = try await recoveryCoordinator.performMaintenance(on: database)
                if let avatarLoader {
                    try await avatarLoader.installBackingStore(
                        ForgeSQLiteAvatarBackingStore(store: database),
                        loadingEnabled: avatarLoadingEnabled()
                    )
                }
                dataAvailability = .available(database)
                persistenceCleaner = database
                avatarCleaner = ForgeSQLiteAvatarAccountCleaner(
                    store: database,
                    loader: avatarLoader
                )
            } catch {
                dataAvailability = .recoveryRequired(copy)
                persistenceCleaner = ForgeRecoveryDeferredAccountPersistenceCleaner(
                    tombstoneStore: tombstoneStore,
                    recoveryCopy: copy
                )
                avatarCleaner = PreservingSharedForgeAvatarCleaner(loader: avatarLoader)
                if let avatarLoader {
                    try await avatarLoader.installBackingStore(
                        ForgeAvatarMemoryOnlyBackingStore(),
                        loadingEnabled: avatarLoadingEnabled()
                    )
                }
            }
        }
        let broker = GitHubCLIAccountBroker(runner: cliRunner)
        let addAccountCoordinator = ForgeAddAccountCoordinator(
            accountStore: accountStore,
            cliBroker: broker,
            avatarLoader: avatarLoader
        )
        let removalCoordinator = ForgeAccountRemovalCoordinator(
            accountStore: accountStore,
            persistenceCleaner: persistenceCleaner,
            bindingCleaner: bindingCleaner,
            avatarCleaner: avatarCleaner
        )
        let mutationSessionGate = GitHubMutationSessionGate.shared
        let credentialAuthority = ForgeGitHubReadCredentialAuthority(accountStore: accountStore)
        let adapterFactory = ForgeGitHubReadAdapterFactory(
            credentialAuthority: credentialAuthority,
            sessionGate: mutationSessionGate
        )
        let mutationState = ForgeGitHubMutationStateStore(sessionGate: mutationSessionGate)
        let cooldowns = ForgeCredentialCooldownRegistry(sessionGate: mutationSessionGate)
        let refreshCoordinator = await ForgeApplicationRefreshCoordinator.makeDefault(
            dataAvailability: dataAvailability,
            bindingCleaner: bindingCleaner,
            accountStore: accountStore,
            adapterFactory: adapterFactory,
            cooldowns: cooldowns
        )
        return ForgeApplicationServices(
            dataAvailability: dataAvailability,
            accountStore: accountStore,
            addAccountCoordinator: addAccountCoordinator,
            removalCoordinator: removalCoordinator,
            githubReadAdapterFactory: adapterFactory,
            githubMutationState: mutationState,
            githubMutationNetworkMonitor: ForgeGitHubMutationNetworkMonitor(
                sessionGate: mutationSessionGate
            ),
            credentialCooldowns: cooldowns,
            githubAnonymousRESTBudget: githubAnonymousRESTBudget,
            refreshCoordinator: refreshCoordinator,
            deferredAccountCleanup: tombstoneStore,
            recoveryCoordinator: recoveryCoordinator
        )
    }
}
