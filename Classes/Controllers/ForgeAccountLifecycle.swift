import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

nonisolated struct ForgeCLISecretEnvironment: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let name: String
    private let value: Data

    init(name: String, value: Data) {
        self.name = name
        self.value = value
    }

    func withUnsafeValue<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        try body(value)
    }

    var description: String {
        "<redacted Forge CLI secret environment>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated struct ForgeCLICommand: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let executableURL: URL
    let arguments: [String]
    let secretEnvironment: ForgeCLISecretEnvironment?

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String],
        secretEnvironment: ForgeCLISecretEnvironment? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.secretEnvironment = secretEnvironment
    }

    var description: String {
        "<redacted Forge CLI command>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated struct ForgeCLICommandResult: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32

    var description: String {
        "<redacted Forge CLI command result status=\(terminationStatus)>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated protocol ForgeCLICommandRunning: Sendable {
    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult
}

nonisolated enum ForgeCLIBrokerError: Error, Equatable, LocalizedError, Sendable {
    case commandLaunchFailed
    case commandFailed(status: Int32)
    case invalidIdentityResponse
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .commandLaunchFailed:
            "GitHub CLI could not be started."
        case let .commandFailed(status):
            "GitHub CLI authentication brokerage failed with status \(status)."
        case .invalidIdentityResponse:
            "GitHub CLI returned an invalid account identity."
        case .invalidTokenResponse:
            "GitHub CLI returned invalid Credential material."
        }
    }
}

final nonisolated class SystemForgeCLICommandRunner: ForgeCLICommandRunning, Sendable {
    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        let ownership = ForgeCLIProcessOwnership()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let termination = ForgeCLIProcessTermination()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            if let secretEnvironment = command.secretEnvironment {
                let value = secretEnvironment.withUnsafeValue { String(data: $0, encoding: .utf8) }
                guard let value else {
                    throw ForgeCLIBrokerError.invalidTokenResponse
                }
                var environment = ProcessInfo.processInfo.environment
                environment[secretEnvironment.name] = value
                process.environment = environment
            }
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { terminatedProcess in
                ownership.didTerminate(terminatedProcess)
                termination.finish(status: terminatedProcess.terminationStatus)
            }
            do {
                try ownership.launch(process)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || ownership.isCancelled {
                    throw CancellationError()
                }
                throw ForgeCLIBrokerError.commandLaunchFailed
            }
            let outputHandle = SendableForgeFileHandle(outputPipe.fileHandleForReading)
            let errorHandle = SendableForgeFileHandle(errorPipe.fileHandleForReading)
            let outputRead = Task.detached(priority: .userInitiated) {
                outputHandle.value.readDataToEndOfFile()
            }
            let errorRead = Task.detached(priority: .userInitiated) {
                errorHandle.value.readDataToEndOfFile()
            }
            let terminationStatus = await termination.wait()
            let result = ForgeCLICommandResult(
                standardOutput: await outputRead.value,
                standardError: await errorRead.value,
                terminationStatus: terminationStatus
            )
            if Task.isCancelled || ownership.isCancelled {
                throw CancellationError()
            }
            return result
        } onCancel: {
            ownership.cancel()
        }
    }
}

// swift6-safety-justification: The lock linearizes cancellation with Process launch and termination state.
private final nonisolated class ForgeCLIProcessOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var terminated = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func launch(_ process: Process) throws {
        let shouldLaunch = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            // This successful lock transition commits the launch. A
            // cancellation that wins this lock prevents Process.run(); one
            // that follows it terminates immediately after Process.run().
            return true
        }
        guard shouldLaunch else {
            throw CancellationError()
        }
        try process.run()
        let shouldTerminate = lock.withLock { () -> Bool in
            if !terminated {
                self.process = process
            }
            return cancelled && !terminated
        }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func didTerminate(_ process: Process) {
        lock.withLock {
            terminated = true
            if self.process === process {
                self.process = nil
            }
        }
    }

    func cancel() {
        let runningProcess = lock.withLock { () -> Process? in
            cancelled = true
            defer { process = nil }
            return process
        }
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }
}

// swift6-safety-justification: The lock protects the single waiter and one terminal process status.
private final nonisolated class ForgeCLIProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(status: Int32) {
        let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard self.status == nil else { return nil }
            self.status = status
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { waiter in
            let finishedStatus = lock.withLock { () -> Int32? in
                if let status {
                    return status
                }
                continuation = waiter
                return nil
            }
            if let finishedStatus {
                waiter.resume(returning: finishedStatus)
            }
        }
    }
}

// swift6-safety-justification: The immutable handle is transferred to exactly one detached reader task.
private final nonisolated class SendableForgeFileHandle: @unchecked Sendable {
    let value: FileHandle

    init(_ value: FileHandle) {
        self.value = value
    }
}

nonisolated struct GitHubCLIBrokeredCredential: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let accountID: ForgeAccountID
    let login: String
    let credentialID: ForgeCredentialID
    let accessToken: Data

    var description: String {
        "<redacted GitHub CLI Credential>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

final nonisolated class GitHubCLIAccountBroker: Sendable {
    private struct IdentityResponse: Decodable {
        let nodeID: String
        let login: String

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login
        }
    }

    private let runner: any ForgeCLICommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubCLIAccountBroker")

    init(runner: any ForgeCLICommandRunning) {
        self.runner = runner
    }

    /// The only CLI-broker entry point. Callers must invoke it from an explicit Add Account action.
    func brokerForExplicitAddAccount() async throws -> GitHubCLIBrokeredCredential {
        let tokenResult = try await run(ForgeCLICommand(arguments: [
            "gh", "auth", "token", "--hostname", "github.com",
        ]))
        let token = Self.trimmingASCIISpace(tokenResult.standardOutput)
        do {
            _ = try ForgeCredentialSecretMaterial(accessToken: token)
        } catch {
            throw ForgeCLIBrokerError.invalidTokenResponse
        }

        let identityResult = try await run(ForgeCLICommand(
            arguments: ["gh", "api", "--hostname", "github.com", "user"],
            secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: token)
        ))
        let identity: IdentityResponse
        do {
            identity = try JSONDecoder().decode(IdentityResponse.self, from: identityResult.standardOutput)
        } catch {
            throw ForgeCLIBrokerError.invalidIdentityResponse
        }
        let forge = try ForgeIdentity(
            kind: .github,
            origin: ForgeOrigin(host: "github.com")
        )
        let accountID: ForgeAccountID
        do {
            accountID = try ForgeAccountID(forge: forge, value: identity.nodeID)
            _ = try ForgeAccount(
                id: accountID,
                login: identity.login,
                currentCredential: ForgeCredentialMetadata(
                    reference: ForgeCredentialReference(
                        accountID: accountID,
                        credentialID: ForgeCredentialID("github-cli:github.com"),
                        generation: ForgeCredentialGeneration(1)
                    ),
                    source: .commandLineBroker
                )
            )
        } catch {
            throw ForgeCLIBrokerError.invalidIdentityResponse
        }

        logger.notice("GitHub CLI explicit account brokerage completed")
        return try GitHubCLIBrokeredCredential(
            accountID: accountID,
            login: identity.login,
            credentialID: ForgeCredentialID("github-cli:github.com"),
            accessToken: token
        )
    }

    private func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        let result = try await runner.run(command)
        guard result.terminationStatus == 0 else {
            logger.error("GitHub CLI brokerage command failed status=\(result.terminationStatus, privacy: .public)")
            throw ForgeCLIBrokerError.commandFailed(status: result.terminationStatus)
        }
        return result
    }

    private static func trimmingASCIISpace(_ data: Data) -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard let first = data.firstIndex(where: { !whitespace.contains($0) }),
              let last = data.lastIndex(where: { !whitespace.contains($0) })
        else {
            return Data()
        }
        return data[first ... last]
    }
}

actor ForgeAddAccountCoordinator {
    private let accountStore: ForgeAccountStore
    private let cliBroker: GitHubCLIAccountBroker
    private let avatarLoader: ForgeAvatarLoader?

    init(
        accountStore: ForgeAccountStore,
        cliBroker: GitHubCLIAccountBroker,
        avatarLoader: ForgeAvatarLoader? = nil
    ) {
        self.accountStore = accountStore
        self.cliBroker = cliBroker
        self.avatarLoader = avatarLoader
    }

    func addUsingExplicitGitHubCLIBrokerage() async throws -> ForgeAccount {
        let credential = try await cliBroker.brokerForExplicitAddAccount()
        let account = try await accountStore.addAccount(
            accountID: credential.accountID,
            login: credential.login,
            credentialID: credential.credentialID,
            source: .commandLineBroker,
            expiresAt: nil,
            secrets: ForgeCredentialSecretMaterial(accessToken: credential.accessToken)
        )
        await avatarLoader?.restoreAfterAccountAddition(account.id)
        return account
    }

    func addPersonalAccessToken(
        accountID: ForgeAccountID,
        login: String,
        credentialID: ForgeCredentialID,
        kind: ForgePersonalAccessTokenKind,
        token: Data,
        expiresAt: Date?,
        authorizationEvidence: ForgeStoredCredentialAuthorizationEvidence? = nil
    ) async throws -> ForgeAccount {
        let account = try await accountStore.addPersonalAccessToken(
            accountID: accountID,
            login: login,
            credentialID: credentialID,
            kind: kind,
            token: token,
            expiresAt: expiresAt,
            authorizationEvidence: authorizationEvidence
        )
        await avatarLoader?.restoreAfterAccountAddition(account.id)
        return account
    }
}

nonisolated protocol ForgeAccountPersistenceCleaning: Sendable {
    func removeAccount(_ accountID: ForgeAccountID) async throws
}

extension ForgeSQLiteStore: ForgeAccountPersistenceCleaning {}

nonisolated protocol ForgeAccountAvatarCleaning: Sendable {
    func removeAccountAssociations(for accountID: ForgeAccountID) async throws
}

nonisolated struct PreservingSharedForgeAvatarCleaner: ForgeAccountAvatarCleaning {
    private let loader: ForgeAvatarLoader?

    init(loader: ForgeAvatarLoader? = nil) {
        self.loader = loader
    }

    func removeAccountAssociations(for accountID: ForgeAccountID) async throws {
        await loader?.invalidateForAccountRemoval(accountID)
        // Recovery mode has no live database or disk avatar tier. The deferred
        // persistence tombstone removes account attribution when recovery succeeds.
    }
}

nonisolated struct ForgeSQLiteAvatarAccountCleaner: ForgeAccountAvatarCleaning {
    private let store: ForgeSQLiteStore
    private let loader: ForgeAvatarLoader?

    init(store: ForgeSQLiteStore, loader: ForgeAvatarLoader?) {
        self.store = store
        self.loader = loader
    }

    func removeAccountAssociations(for accountID: ForgeAccountID) async throws {
        await loader?.invalidateForAccountRemoval(accountID)
        _ = try await store.removeAvatarAssociations(for: accountID)
    }
}

nonisolated protocol ForgeRepositoryBindingCleaning: Sendable {
    func removeBindings(for accountID: ForgeAccountID) throws
}

nonisolated protocol ForgeRepositoryBindingProviding: Sendable {
    func forgeRepositoryBindings() -> [ForgeRepositoryBinding]
}

// swift6-safety-justification: the shared repository-view-state lock serializes UserDefaults access.
final nonisolated class ForgeRepositoryBindingAccountCleaner:
    ForgeRepositoryBindingCleaning,
    ForgeRepositoryBindingProviding,
    // swift6-safety-justification: all mutable UserDefaults access uses the shared lock.
    @unchecked Sendable
{
    static let repositorySettingsKey = "PBRepositoryUISettings"
    static let forgeBindingKey = "forgeRepositoryBinding"

    private let userDefaults: UserDefaults
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func removeBindings(for accountID: ForgeAccountID) throws {
        RepositoryViewStatePreferencesSynchronization.lock.withLock {
            guard var repositorySettings = userDefaults.dictionary(forKey: Self.repositorySettingsKey) else {
                return
            }
            var changed = false
            for (repositoryKey, value) in repositorySettings {
                guard var settings = value as? [String: Any],
                      let bindingData = settings[Self.forgeBindingKey] as? Data,
                      let binding = try? JSONDecoder().decode(ForgeRepositoryBinding.self, from: bindingData),
                      binding.preferredAccount == accountID
                else {
                    continue
                }
                settings.removeValue(forKey: Self.forgeBindingKey)
                repositorySettings[repositoryKey] = settings
                changed = true
            }
            if changed {
                userDefaults.set(repositorySettings, forKey: Self.repositorySettingsKey)
            }
        }
    }

    func forgeRepositoryBindings() -> [ForgeRepositoryBinding] {
        RepositoryViewStatePreferencesSynchronization.lock.withLock {
            guard let repositorySettings = userDefaults.dictionary(forKey: Self.repositorySettingsKey) else {
                return []
            }
            let decoded = repositorySettings.values.compactMap { value -> ForgeRepositoryBinding? in
                guard let settings = value as? [String: Any],
                      let bindingData = settings[Self.forgeBindingKey] as? Data
                else {
                    return nil
                }
                return try? JSONDecoder().decode(ForgeRepositoryBinding.self, from: bindingData)
            }
            return Array(Set(decoded)).sorted { lhs, rhs in
                let left = lhs.primaryRepository
                let right = rhs.primaryRepository
                return [left.forge.origin.url.absoluteString, left.owner, left.name]
                    .lexicographicallyPrecedes([right.forge.origin.url.absoluteString, right.owner, right.name])
            }
        }
    }
}

actor ForgeAccountRemovalCoordinator {
    private let accountStore: ForgeAccountStore
    private let persistenceCleaner: any ForgeAccountPersistenceCleaning
    private let bindingCleaner: any ForgeRepositoryBindingCleaning
    private let avatarCleaner: any ForgeAccountAvatarCleaning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccountRemoval")

    init(
        accountStore: ForgeAccountStore,
        persistenceCleaner: any ForgeAccountPersistenceCleaning,
        bindingCleaner: any ForgeRepositoryBindingCleaning,
        avatarCleaner: any ForgeAccountAvatarCleaning
    ) {
        self.accountStore = accountStore
        self.persistenceCleaner = persistenceCleaner
        self.bindingCleaner = bindingCleaner
        self.avatarCleaner = avatarCleaner
    }

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        // Removing the Credential first prevents stale account data from remaining usable.
        // Every cleanup is idempotent so retry completes a partially finished removal.
        try await accountStore.removeAccount(accountID)
        try await persistenceCleaner.removeAccount(accountID)
        try bindingCleaner.removeBindings(for: accountID)
        try await avatarCleaner.removeAccountAssociations(for: accountID)
        logger.notice("Forge Account and account-scoped state removed")
    }
}

private nonisolated extension NSLock {
    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try operation()
    }
}
