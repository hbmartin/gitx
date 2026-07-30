import Darwin
import ForgeKit
import XCTest

final class ForgeAccountLifecycleTests: XCTestCase {
    func testGitHubCLIIsConsultedOnlyByExplicitAddAccountAndStoresBrokeredToken() async throws {
        let runner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("cli-secret-token\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: Data(#"{"node_id":"MDQ6VXNlcjE=","login":"octocat"}"#.utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let coordinator = ForgeAddAccountCoordinator(
            accountStore: store,
            cliBroker: GitHubCLIAccountBroker(runner: runner)
        )

        let initialCommands = await runner.commands()
        XCTAssertEqual(initialCommands, [], "composition must never consult GitHub CLI")
        let account = try await coordinator.addUsingExplicitGitHubCLIBrokerage()
        XCTAssertEqual(account.login, "octocat")
        XCTAssertEqual(account.id.value, "MDQ6VXNlcjE=")
        XCTAssertEqual(account.currentCredential.source, .commandLineBroker)
        let executedArguments = await runner.commands().map(\.arguments)
        XCTAssertEqual(executedArguments, [
            ["gh", "auth", "token", "--hostname", "github.com"],
            ["gh", "api", "--hostname", "github.com", "user"],
        ])
        let executedCommands = await runner.commands()
        let identityCommand = try XCTUnwrap(executedCommands.last)
        let identityEnvironment = try XCTUnwrap(identityCommand.secretEnvironment)
        XCTAssertEqual(identityEnvironment.name, "GH_TOKEN")
        XCTAssertEqual(
            identityEnvironment.withUnsafeValue { Data($0) },
            Data("cli-secret-token".utf8)
        )
        XCTAssertFalse(String(describing: identityCommand).contains("cli-secret-token"))
        XCTAssertFalse(String(reflecting: identityCommand).contains("cli-secret-token"))
        XCTAssertTrue(identityCommand.customMirror.children.isEmpty)
        XCTAssertFalse(String(describing: identityEnvironment).contains("cli-secret-token"))
        XCTAssertFalse(String(reflecting: identityEnvironment).contains("cli-secret-token"))
        XCTAssertTrue(identityEnvironment.customMirror.children.isEmpty)
        let storedCredential = try await store.credential(for: account.id)
        let envelope = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            envelope.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("cli-secret-token".utf8)
        )
        XCTAssertFalse(String(reflecting: envelope).contains("cli-secret-token"))
    }

    func testCLIBrokerFailuresExposeStatusButNeverCommandOutput() async throws {
        let runner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("private-response".utf8),
                standardError: Data("secret-diagnostic".utf8),
                terminationStatus: 23
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: runner).brokerForExplicitAddAccount()
            XCTFail("a failing CLI command must not produce a Credential")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .commandFailed(status: 23))
            XCTAssertFalse(error.localizedDescription.contains("private-response"))
            XCTAssertFalse(error.localizedDescription.contains("secret-diagnostic"))
        }
    }

    func testCLIBrokerRejectsMalformedIdentityAndEmptyToken() async throws {
        let malformedIdentityRunner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data("token".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
            ForgeCLICommandResult(
                standardOutput: Data(#"{"login":"octocat"}"#.utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: malformedIdentityRunner).brokerForExplicitAddAccount()
            XCTFail("brokerage requires GitHub's stable node identity")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidIdentityResponse)
            XCTAssertEqual(error.localizedDescription, "GitHub CLI returned an invalid account identity.")
        }

        let emptyTokenRunner = StubForgeCLICommandRunner(results: [
            ForgeCLICommandResult(
                standardOutput: Data(" \n\t".utf8),
                standardError: Data(),
                terminationStatus: 0
            ),
        ])
        do {
            _ = try await GitHubCLIAccountBroker(runner: emptyTokenRunner).brokerForExplicitAddAccount()
            XCTFail("brokerage requires nonempty Credential material")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidTokenResponse)
            XCTAssertEqual(error.localizedDescription, "GitHub CLI returned invalid Credential material.")
        }
    }

    func testCLIBrokerBindsIdentityToTokenWhenActiveCLIAccountChangesBetweenCommands() async throws {
        let runner = RacingForgeCLICommandRunner()
        let credential = try await GitHubCLIAccountBroker(runner: runner).brokerForExplicitAddAccount()

        XCTAssertEqual(credential.accountID.value, "node-token-account")
        XCTAssertEqual(credential.login, "token-account")
        XCTAssertFalse(String(describing: credential).contains("token-account-secret"))
        XCTAssertFalse(String(reflecting: credential).contains("token-account-secret"))
        XCTAssertTrue(credential.customMirror.children.isEmpty)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, ["gh", "auth", "token", "--hostname", "github.com"])
        XCTAssertNil(commands[0].secretEnvironment)
        XCTAssertEqual(commands[1].arguments, ["gh", "api", "--hostname", "github.com", "user"])
        XCTAssertEqual(
            commands[1].secretEnvironment?.withUnsafeValue { Data($0) },
            Data("token-account-secret".utf8)
        )
        XCTAssertFalse(commands[1].arguments.joined().contains("token-account-secret"))
        XCTAssertFalse(String(reflecting: commands[1]).contains("token-account-secret"))
    }

    func testSystemCLIRunnerCapturesOutputAndMapsLaunchFailureWithoutLeakingArguments() async throws {
        let runner = SystemForgeCLICommandRunner()
        let result = try await runner.run(ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["runner-output"]
        ))
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, Data("runner-output".utf8))
        XCTAssertEqual(result.standardError, Data())
        let environmentResult = try await runner.run(ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$GH_TOKEN\""],
            secretEnvironment: ForgeCLISecretEnvironment(
                name: "GH_TOKEN",
                value: Data("environment-secret".utf8)
            )
        ))
        XCTAssertEqual(environmentResult.standardOutput, Data("environment-secret".utf8))
        XCTAssertFalse(String(reflecting: environmentResult).contains("environment-secret"))
        do {
            _ = try await runner.run(ForgeCLICommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [],
                secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data([0xFF]))
            ))
            XCTFail("non-UTF-8 secret material must fail before launch")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .invalidTokenResponse)
        }
        let secretResult = ForgeCLICommandResult(
            standardOutput: Data("secret-standard-output".utf8),
            standardError: Data("secret-standard-error".utf8),
            terminationStatus: 23
        )
        XCTAssertFalse(String(describing: secretResult).contains("secret-standard"))
        XCTAssertFalse(String(reflecting: secretResult).contains("secret-standard"))
        XCTAssertTrue(secretResult.customMirror.children.isEmpty)

        do {
            _ = try await runner.run(ForgeCLICommand(
                executableURL: URL(fileURLWithPath: "/not/a/real/executable"),
                arguments: ["secret-argument"]
            ))
            XCTFail("an invalid executable must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeCLIBrokerError, .commandLaunchFailed)
            XCTAssertFalse(error.localizedDescription.contains("secret-argument"))
        }
    }

    func testSystemCLIRunnerCancellationPreventsLaunchAndTerminatesRunningChild() async throws {
        let runner = SystemForgeCLICommandRunner()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-cli-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        printf '%s' "$$" > "$1"
        printf '%s' "$GH_TOKEN" >&2
        trap 'exit 0' TERM INT
        while :; do :; done
        """
        let secret = "cancellation-secret"

        let preventedMarker = directory.appendingPathComponent("prevented.pid")
        let preventedCommand = ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "gitx-cancellation-test", preventedMarker.path],
            secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data(secret.utf8))
        )
        let gate = AsyncStream<Void>.makeStream()
        let preventedTask = Task {
            for await _ in gate.stream {
                break
            }
            return try await runner.run(preventedCommand)
        }
        preventedTask.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        do {
            _ = try await preventedTask.value
            XCTFail("cancellation before launch must not start a child process")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preventedMarker.path))
        XCTAssertFalse(String(reflecting: preventedCommand).contains(secret))

        let runningMarker = directory.appendingPathComponent("running.pid.fifo")
        XCTAssertEqual(mkfifo(runningMarker.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        let runningCommand = ForgeCLICommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "gitx-cancellation-test", runningMarker.path],
            secretEnvironment: ForgeCLISecretEnvironment(name: "GH_TOKEN", value: Data(secret.utf8))
        )
        async let observedProcessID = ForgeAccountLifecycleTests.readProcessID(fromFIFO: runningMarker)
        let runningTask = Task { try await runner.run(runningCommand) }
        let launchedProcessID = try await observedProcessID

        runningTask.cancel()
        do {
            _ = try await runningTask.value
            XCTFail("cancellation after launch must surface as CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("cancellation must not be reclassified: \(error.localizedDescription)")
        }
        errno = 0
        let probeResult = kill(launchedProcessID, 0)
        let probeError = errno
        XCTAssertEqual(probeResult, -1, "the cancelled CLI child must be fully reaped")
        XCTAssertEqual(probeError, ESRCH)
        XCTAssertFalse(String(reflecting: runningCommand).contains(secret))
    }

    func testAddAccountCoordinatorDelegatesPATAndSharedAvatarCleanupIsANoOp() async throws {
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let coordinator = ForgeAddAccountCoordinator(
            accountStore: store,
            cliBroker: GitHubCLIAccountBroker(runner: StubForgeCLICommandRunner(results: []))
        )
        let accountID = try makeAccountID("pat-account")

        let account = try await coordinator.addPersonalAccessToken(
            accountID: accountID,
            login: "pat-user",
            credentialID: ForgeCredentialID("fine-grained-pat"),
            kind: .fineGrained,
            token: Data("pat-token".utf8),
            expiresAt: nil
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.currentCredential.source, .fineGrainedPersonalAccessToken)
        try await PreservingSharedForgeAvatarCleaner().removeAccountAssociations(for: accountID)
        let defaults = try makeDefaults()
        try ForgeRepositoryBindingAccountCleaner(userDefaults: defaults).removeBindings(for: accountID)
        XCTAssertNil(defaults.dictionary(forKey: ForgeRepositoryBindingAccountCleaner.repositorySettingsKey))
    }

    func testRemovalDeletesAccountScopedStateAndPreservesTrustedOriginsAndOtherBindings() async throws {
        let defaults = try makeDefaults()
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let targetID = try makeAccountID("target")
        let otherID = try makeAccountID("other")
        _ = try await store.addPersonalAccessToken(
            accountID: targetID,
            login: "target-login",
            credentialID: ForgeCredentialID("target-pat"),
            kind: .fineGrained,
            token: Data("target-token".utf8),
            expiresAt: nil
        )
        _ = try await store.addPersonalAccessToken(
            accountID: otherID,
            login: "other-login",
            credentialID: ForgeCredentialID("other-pat"),
            kind: .classic,
            token: Data("other-token".utf8),
            expiresAt: nil
        )

        let repository = try ForgeRepositoryIdentity(
            forge: targetID.forge,
            owner: "example",
            name: "repository"
        )
        let targetBinding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository,
            preferredAccount: targetID
        )
        let otherBinding = try ForgeRepositoryBinding(
            localRemoteName: "upstream",
            primaryRepository: repository,
            preferredAccount: otherID
        )
        try defaults.set([
            "target-repository": [
                "forgeRepositoryBinding": JSONEncoder().encode(targetBinding),
                "selectedTab": "history",
            ],
            "other-repository": [
                "forgeRepositoryBinding": JSONEncoder().encode(otherBinding),
            ],
        ], forKey: "PBRepositoryUISettings")
        let trustedOrigins = ["https://docs.example.com"]
        defaults.set(trustedOrigins, forKey: "PBForgeTrustedExternalOrigins")

        let persistence = RecordingPersistenceCleaner()
        let avatars = RecordingAvatarCleaner()
        let coordinator = ForgeAccountRemovalCoordinator(
            accountStore: store,
            persistenceCleaner: persistence,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            avatarCleaner: avatars
        )
        try await coordinator.removeAccount(targetID)

        let removedCredential = try await store.credential(for: targetID)
        let retainedCredential = try await store.credential(for: otherID)
        let persistedRemovals = await persistence.removedAccounts()
        let avatarRemovals = await avatars.removedAccounts()
        XCTAssertNil(removedCredential)
        XCTAssertNotNil(retainedCredential)
        XCTAssertEqual(persistedRemovals, [targetID])
        XCTAssertEqual(avatarRemovals, [targetID])
        let repositorySettings = try XCTUnwrap(defaults.dictionary(forKey: "PBRepositoryUISettings"))
        let targetSettings = try XCTUnwrap(repositorySettings["target-repository"] as? [String: Any])
        XCTAssertNil(targetSettings["forgeRepositoryBinding"])
        XCTAssertEqual(targetSettings["selectedTab"] as? String, "history")
        let otherSettings = try XCTUnwrap(repositorySettings["other-repository"] as? [String: Any])
        XCTAssertNotNil(otherSettings["forgeRepositoryBinding"])
        XCTAssertEqual(defaults.stringArray(forKey: "PBForgeTrustedExternalOrigins"), trustedOrigins)
    }

    func testRemovalStopsBeforeStateCleanupWhenKeychainRemovalFails() async throws {
        let defaults = try makeDefaults()
        let keychain = LifecycleKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("target")
        _ = try await store.addPersonalAccessToken(
            accountID: accountID,
            login: "target-login",
            credentialID: ForgeCredentialID("pat"),
            kind: .classic,
            token: Data("token".utf8),
            expiresAt: nil
        )
        keychain.failure = .interactionNotAllowed(operation: .remove)
        let persistence = RecordingPersistenceCleaner()
        let avatars = RecordingAvatarCleaner()
        let coordinator = ForgeAccountRemovalCoordinator(
            accountStore: store,
            persistenceCleaner: persistence,
            bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
            avatarCleaner: avatars
        )

        do {
            try await coordinator.removeAccount(accountID)
            XCTFail("state cleanup must not proceed while a Credential remains usable")
        } catch {
            XCTAssertEqual(
                error as? ForgeCredentialStoreError,
                .keychain(.interactionNotAllowed(operation: .remove))
            )
        }
        let persistedRemovals = await persistence.removedAccounts()
        let avatarRemovals = await avatars.removedAccounts()
        XCTAssertEqual(persistedRemovals, [])
        XCTAssertEqual(avatarRemovals, [])
    }

    private func makeAccountID(_ value: String) throws -> ForgeAccountID {
        try ForgeAccountID(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            value: value
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ForgeAccountLifecycleTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private nonisolated static func readProcessID(fromFIFO url: URL) async throws -> pid_t {
        // swift6-safety-justification: The detached worker exclusively owns the blocking FIFO descriptor until EOF.
        try await Task.detached(priority: .userInitiated) {
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 32)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            guard let text = String(data: data, encoding: .utf8),
                  let processID = pid_t(text)
            else {
                throw ForgeCLIProcessTestError.invalidProcessID
            }
            return processID
        }.value
    }
}

private enum ForgeCLIProcessTestError: Error {
    case invalidProcessID
}

private actor StubForgeCLICommandRunner: ForgeCLICommandRunning {
    private var results: [ForgeCLICommandResult]
    private var recordedCommands: [ForgeCLICommand] = []

    init(results: [ForgeCLICommandResult]) {
        self.results = results
    }

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        recordedCommands.append(command)
        guard !results.isEmpty else {
            throw ForgeCLIBrokerError.commandLaunchFailed
        }
        return results.removeFirst()
    }

    func commands() -> [ForgeCLICommand] {
        recordedCommands
    }
}

private actor RacingForgeCLICommandRunner: ForgeCLICommandRunning {
    private var recordedCommands: [ForgeCLICommand] = []

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        recordedCommands.append(command)
        if recordedCommands.count == 1 {
            // Simulate the user switching the gh active account immediately after
            // token acquisition. The second command must not inherit that change.
            return ForgeCLICommandResult(
                standardOutput: Data("token-account-secret\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        }
        let authority = command.secretEnvironment?.withUnsafeValue { Data($0) }
        let identity = if authority == Data("token-account-secret".utf8) {
            #"{"node_id":"node-token-account","login":"token-account"}"#
        } else {
            #"{"node_id":"node-new-active-account","login":"new-active-account"}"#
        }
        return ForgeCLICommandResult(
            standardOutput: Data(identity.utf8),
            standardError: Data(),
            terminationStatus: 0
        )
    }

    func commands() -> [ForgeCLICommand] {
        recordedCommands
    }
}

private actor RecordingPersistenceCleaner: ForgeAccountPersistenceCleaning {
    private var accounts: [ForgeAccountID] = []

    func removeAccount(_ accountID: ForgeAccountID) async throws {
        accounts.append(accountID)
    }

    func removedAccounts() -> [ForgeAccountID] {
        accounts
    }
}

private actor RecordingAvatarCleaner: ForgeAccountAvatarCleaning {
    private var accounts: [ForgeAccountID] = []

    func removeAccountAssociations(for accountID: ForgeAccountID) async throws {
        accounts.append(accountID)
    }

    func removedAccounts() -> [ForgeAccountID] {
        accounts
    }
}

// swift6-safety-justification: The lock serializes all test-double storage and failure state.
private final nonisolated class LifecycleKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var failure: ForgeKeychainError?

    func data(for accountKey: String) throws -> Data? {
        try lock.withLock {
            if let failure {
                throw failure
            }
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        try lock.withLock {
            if let failure {
                throw failure
            }
            return storage.map(ForgeKeychainItem.init(accountKey:data:))
        }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
            storage[accountKey] = data
        }
    }

    func remove(accountKey: String) throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
            storage.removeValue(forKey: accountKey)
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
