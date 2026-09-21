import AppKit
import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

enum ForgeMutationQuitCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case accountRepositoryMismatch
    case readOnlyOperation
    case invalidTimestamp
    case terminationPending
    case persistenceUnavailable
    case invalidPersistedRecord

    var errorDescription: String? {
        switch self {
        case .accountRepositoryMismatch:
            "The Forge mutation Account and repository do not have the same exact Forge identity."
        case .readOnlyOperation:
            "Only Forge write operations can be registered as in-flight mutations."
        case .invalidTimestamp:
            "Forge mutation timestamps must be finite."
        case .terminationPending:
            "GitX is already waiting to terminate."
        case .persistenceUnavailable:
            "The Forge database is unavailable for unknown-outcome reconciliation."
        case .invalidPersistedRecord:
            "A persisted Forge unknown-outcome record has inconsistent identity metadata."
        }
    }
}

enum ForgeMutationQuitChoice: Equatable, Sendable {
    case wait
    case quitAnyway
}

nonisolated protocol ForgeMutationLifecycleCoordinating: Sendable {
    func register(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope,
        startedAt: Date
    ) throws -> ForgeMutationRegistration

    @discardableResult
    func finish(_ registration: ForgeMutationRegistration) -> Bool
}

nonisolated extension ForgeMutationLifecycleCoordinating {
    func register(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        startedAt: Date
    ) throws -> ForgeMutationRegistration {
        try register(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: .repositoryWide,
            startedAt: startedAt
        )
    }
}

// swift6-safety-justification: The private lock protects active mutations and termination state.
final nonisolated class ForgeMutationQuitCoordinator: ForgeMutationLifecycleCoordinating, @unchecked Sendable {
    typealias ChoiceProvider = @MainActor @Sendable ([ForgeInFlightMutation]) -> ForgeMutationQuitChoice
    typealias TerminationReply = @MainActor @Sendable (Bool) -> Void
    /// Runs `body` after `seconds`. Injected so tests drive the deadline directly
    /// instead of waiting on the clock.
    typealias TimeoutScheduler = @MainActor @Sendable (
        _ seconds: TimeInterval,
        _ body: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    /// Every state other than `idle` answers a quit with `terminateLater`, which
    /// obliges someone to call `reply(toApplicationShouldTerminate:)` later. A state
    /// that cannot be left therefore makes the application impossible to quit by any
    /// normal means, so each one below has an explicit exit.
    private enum TerminationState {
        case idle
        case waiting
        case recordingUnknownOutcomes
        case replyingToTermination
        case terminationAccepted
    }

    static let defaultTerminationTimeout: TimeInterval = 10

    static let defaultTimeoutScheduler: TimeoutScheduler = { seconds, body in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            body()
        }
    }

    #if GITX_APP_TARGET
        static let sharedPersistence = ForgeSQLiteUnknownMutationOutcomeStore {
            let services = try await ApplicationComposition.shared.forgeServices.services()
            guard let database = services.database else {
                throw ForgeMutationQuitCoordinatorError.persistenceUnavailable
            }
            return database
        }

        static let shared = ForgeMutationQuitCoordinator(
            persistence: sharedPersistence,
            choiceProvider: ForgeMutationQuitAlert.choice,
            terminationReply: { shouldTerminate in
                NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
    #endif

    private let persistence: any ForgeUnknownMutationOutcomePersisting
    private let choiceProvider: ChoiceProvider
    private let terminationReply: TerminationReply
    private let terminationTimeout: TimeInterval
    private let scheduleTimeout: TimeoutScheduler
    private let lock = NSLock()
    private var active: [UUID: ForgeInFlightMutation] = [:]
    private var terminationState = TerminationState.idle
    private var terminationAttemptGeneration: UInt64 = 0
    private var activeTerminationAttemptID: UInt64?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeMutationQuit")

    init(
        persistence: any ForgeUnknownMutationOutcomePersisting,
        choiceProvider: @escaping ChoiceProvider,
        terminationReply: @escaping TerminationReply,
        terminationTimeout: TimeInterval = ForgeMutationQuitCoordinator.defaultTerminationTimeout,
        scheduleTimeout: @escaping TimeoutScheduler = ForgeMutationQuitCoordinator.defaultTimeoutScheduler
    ) {
        self.persistence = persistence
        self.choiceProvider = choiceProvider
        self.terminationReply = terminationReply
        self.terminationTimeout = terminationTimeout
        self.scheduleTimeout = scheduleTimeout
    }

    func register(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope = .repositoryWide,
        startedAt: Date = Date()
    ) throws -> ForgeMutationRegistration {
        let mutation = try ForgeInFlightMutation(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope,
            startedAt: startedAt
        )
        try lock.withForgeMutationLock {
            guard case .idle = terminationState else {
                throw ForgeMutationQuitCoordinatorError.terminationPending
            }
            active[mutation.registrationID] = mutation
        }
        logger.info("Registered in-flight Forge mutation operation=\(operation.rawValue, privacy: .public)")
        return ForgeMutationRegistration(mutation: mutation)
    }

    @discardableResult
    func finish(_ registration: ForgeMutationRegistration) -> Bool {
        let result = lock.withForgeMutationLock { () -> (removed: Bool, reply: Bool) in
            guard active.removeValue(forKey: registration.mutation.registrationID) != nil else {
                return (false, false)
            }
            if case .waiting = terminationState, active.isEmpty {
                terminationState = .replyingToTermination
                activeTerminationAttemptID = nil
                return (true, true)
            }
            return (true, false)
        }
        guard result.removed else { return false }
        logger.info(
            "Finished in-flight Forge mutation operation=\(registration.mutation.operation.rawValue, privacy: .public)"
        )
        if result.reply {
            Task { @MainActor [terminationReply] in
                terminationReply(true)
            }
        }
        return true
    }

    // Exercised from the app-hosted test target, which SwiftLint's app compiler log cannot resolve.
    // swiftlint:disable:next unused_declaration
    func activeMutations() -> [ForgeInFlightMutation] {
        lock.withForgeMutationLock {
            active.values.sorted(by: Self.sortsBefore)
        }
    }

    func unknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope = .repositoryWide
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        try await persistence.records(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope
        )
    }

    func consumeUnknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope = .repositoryWide
    ) async throws -> [ForgeUnknownMutationOutcomeRecord] {
        try await persistence.consume(
            accountID: accountID,
            repository: repository,
            operation: operation,
            scope: scope
        )
    }

    @MainActor
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        let initial = lock.withForgeMutationLock { () -> TerminationInitialDecision in
            switch terminationState {
            case .idle:
                let mutations = active.values.sorted(by: Self.sortsBefore)
                guard mutations.isEmpty else { return .mutations(mutations) }
                terminationState = .terminationAccepted
                activeTerminationAttemptID = nil
                return .now
            case .waiting, .recordingUnknownOutcomes:
                return .later
            case .replyingToTermination:
                terminationState = .terminationAccepted
                activeTerminationAttemptID = nil
                return .now
            case .terminationAccepted:
                return .now
            }
        }

        let mutations: [ForgeInFlightMutation]
        switch initial {
        case .now:
            return .terminateNow
        case .later:
            return .terminateLater
        case let .mutations(current):
            mutations = current
        }

        let choice = choiceProvider(mutations)
        let transition = lock.withForgeMutationLock { () -> TerminationTransition in
            guard case .idle = terminationState else { return .alreadyDeferred }
            let current = active.values.sorted(by: Self.sortsBefore)
            guard !current.isEmpty else {
                terminationState = .terminationAccepted
                activeTerminationAttemptID = nil
                return .now
            }
            switch choice {
            case .wait:
                terminationState = .waiting
                return .later(beginTerminationAttemptLocked())
            case .quitAnyway:
                do {
                    let recordedAt = Date()
                    let records = try current.map {
                        try ForgeUnknownMutationOutcomeRecord(mutation: $0, recordedAt: recordedAt)
                    }
                    terminationState = .recordingUnknownOutcomes
                    return .record(records, beginTerminationAttemptLocked())
                } catch {
                    logger.error("Could not prepare redacted Forge unknown-outcome records")
                    return .cancel
                }
            }
        }

        switch transition {
        case .now:
            return .terminateNow
        case .alreadyDeferred:
            return .terminateLater
        case let .later(attemptID):
            scheduleTerminationWatchdog(attemptID: attemptID)
            return .terminateLater
        case .cancel:
            return .terminateCancel
        case let .record(records, attemptID):
            scheduleTerminationWatchdog(attemptID: attemptID)
            logger.notice("Recording \(records.count) in-flight Forge mutations as unknown outcomes before quit")
            Task { @MainActor [self, persistence] in
                do {
                    try await persistence.record(records)
                    completeUnknownOutcomeRecording(attemptID: attemptID, shouldTerminate: true)
                } catch {
                    logger.error("Could not durably record Forge unknown outcomes; cancelling termination")
                    completeUnknownOutcomeRecording(attemptID: attemptID, shouldTerminate: false)
                }
            }
            return .terminateLater
        }
    }

    /// Guarantees that a deferred quit is always answered. An expired `waiting`
    /// attempt is cancelled because the user did not consent to abandon the
    /// mutation. An expired `recordingUnknownOutcomes` attempt may terminate because
    /// the user already chose Quit Anyway.
    @MainActor
    private func scheduleTerminationWatchdog(attemptID: UInt64) {
        scheduleTimeout(terminationTimeout) { [self] in
            let action = lock.withForgeMutationLock { () -> TerminationWatchdogAction in
                guard attemptID == activeTerminationAttemptID else { return .none }
                switch terminationState {
                case .idle, .replyingToTermination, .terminationAccepted:
                    return .none
                case .waiting:
                    terminationState = .idle
                    activeTerminationAttemptID = nil
                    return .cancel
                case .recordingUnknownOutcomes:
                    terminationState = .replyingToTermination
                    activeTerminationAttemptID = nil
                    return .terminate
                }
            }
            switch action {
            case .none:
                return
            case .cancel:
                logger.error("Forge mutation did not finish within the quit deadline; cancelling this quit attempt")
                terminationReply(false)
            case .terminate:
                logger.error("Forge outcome recording did not finish within the quit deadline; terminating after Quit Anyway")
                terminationReply(true)
            }
        }
    }

    @MainActor
    private func completeUnknownOutcomeRecording(attemptID: UInt64, shouldTerminate: Bool) {
        let shouldReply = lock.withForgeMutationLock { () -> Bool in
            guard case .recordingUnknownOutcomes = terminationState,
                  attemptID == activeTerminationAttemptID
            else { return false }
            terminationState = shouldTerminate ? .replyingToTermination : .idle
            activeTerminationAttemptID = nil
            return true
        }
        if shouldReply {
            terminationReply(shouldTerminate)
        }
    }

    private enum TerminationTransition {
        case now
        case alreadyDeferred
        case later(UInt64)
        case cancel
        case record([ForgeUnknownMutationOutcomeRecord], UInt64)
    }

    private enum TerminationInitialDecision {
        case now
        case later
        case mutations([ForgeInFlightMutation])
    }

    private enum TerminationWatchdogAction {
        case none
        case cancel
        case terminate
    }

    private func beginTerminationAttemptLocked() -> UInt64 {
        terminationAttemptGeneration &+= 1
        activeTerminationAttemptID = terminationAttemptGeneration
        return terminationAttemptGeneration
    }

    private static func sortsBefore(_ lhs: ForgeInFlightMutation, _ rhs: ForgeInFlightMutation) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.registrationID.uuidString < rhs.registrationID.uuidString
    }
}

private enum ForgeMutationQuitAlert {
    @MainActor
    static func choice(for mutations: [ForgeInFlightMutation]) -> ForgeMutationQuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forge Changes Are Still in Progress"
        alert.informativeText = mutations.count == 1
            ? "GitX is waiting for a GitHub change to finish. Quit now only if you accept that its outcome may be unknown."
            : "GitX is waiting for \(mutations.count) GitHub changes to finish. Quit now only if you accept that their outcomes may be unknown."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .quitAnyway : .wait
    }
}

#if GITX_APP_TARGET
    extension ApplicationController {
        /// Objective-C runtime hook for the optional NSApplicationDelegate method.
        /// Keeping the selector in Swift avoids substantive churn in the legacy app delegate.
        // swiftlint:disable:next unused_declaration
        func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
            ForgeMutationQuitCoordinator.shared.applicationShouldTerminate()
        }
    }
#endif

private nonisolated extension NSLock {
    func withForgeMutationLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
