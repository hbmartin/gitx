import ForgeKit
import Foundation
import OSLog

final nonisolated class ForgeApplicationServices: Sendable {
    let database: ForgeSQLiteStore
    let accountStore: ForgeAccountStore
    let addAccountCoordinator: ForgeAddAccountCoordinator
    let removalCoordinator: ForgeAccountRemovalCoordinator

    init(
        database: ForgeSQLiteStore,
        accountStore: ForgeAccountStore,
        addAccountCoordinator: ForgeAddAccountCoordinator,
        removalCoordinator: ForgeAccountRemovalCoordinator
    ) {
        self.database = database
        self.accountStore = accountStore
        self.addAccountCoordinator = addAccountCoordinator
        self.removalCoordinator = removalCoordinator
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
        return try make(
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
    ) throws -> ForgeApplicationServices {
        let database = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: forgeDirectory.appendingPathComponent("Forge.sqlite3"),
            recoveryDirectoryURL: forgeDirectory.appendingPathComponent("Recovery", isDirectory: true)
        ))
        let accountStore = ForgeAccountStore(keychain: keychain)
        let broker = GitHubCLIAccountBroker(runner: cliRunner)
        let addAccountCoordinator = ForgeAddAccountCoordinator(
            accountStore: accountStore,
            cliBroker: broker
        )
        let removalCoordinator = ForgeAccountRemovalCoordinator(
            accountStore: accountStore,
            persistenceCleaner: database,
            bindingCleaner: bindingCleaner,
            avatarCleaner: PreservingSharedForgeAvatarCleaner()
        )
        return ForgeApplicationServices(
            database: database,
            accountStore: accountStore,
            addAccountCoordinator: addAccountCoordinator,
            removalCoordinator: removalCoordinator
        )
    }
}
