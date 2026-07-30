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
            return try ForgeApplicationServiceFactory.make(
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
            applicationSupportDirectory: { applicationSupport }
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
            return try ForgeApplicationServiceFactory.make(
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

// swift6-safety-justification: The lock serializes all mutable test-double thread observations.
private final nonisolated class CompositionKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []

    var accessThreads: [Bool] {
        lock.withLock { threads }
    }

    func data(for accountKey: String) throws -> Data? {
        lock.withLock { threads.append(Thread.isMainThread) }
        return nil
    }

    func allItems() throws -> [ForgeKeychainItem] {
        lock.withLock { threads.append(Thread.isMainThread) }
        return []
    }

    func replace(_ data: Data, for accountKey: String) throws {
        lock.withLock { threads.append(Thread.isMainThread) }
    }

    func remove(accountKey: String) throws {
        lock.withLock { threads.append(Thread.isMainThread) }
    }
}

private actor CompositionRunner: ForgeCLICommandRunning {
    private(set) var commandCount = 0

    func run(_ command: ForgeCLICommand) async throws -> ForgeCLICommandResult {
        commandCount += 1
        throw ForgeCLIBrokerError.commandLaunchFailed
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
