import ForgeKit
import Foundation

public struct GitHubCredentialRequestPermit: Equatable, Sendable {
    fileprivate let credential: ForgeCredentialReference
    fileprivate let cooldownGeneration: UInt64?
}

public enum GitHubCredentialRequestAdmission: Equatable, Sendable {
    case allowed(GitHubCredentialRequestPermit)
    case offline
    case rateLimited(until: Date)
}

public enum GitHubCredentialCooldownState: Equatable, Sendable {
    case none
    case waiting(until: Date)
    case retryPending(deadline: Date)
}

/// One concurrency-safe process gate shared by every authenticated read and
/// mutation adapter. Cooldowns are keyed by the exact Credential generation,
/// so repository/account rebinding cannot bypass a pause and another
/// Credential remains independent.
public actor GitHubMutationSessionGate {
    public static let shared = GitHubMutationSessionGate()

    private struct Cooldown: Sendable {
        let deadline: Date
        let generation: UInt64
    }

    private var isOffline = false
    private var cooldowns: [ForgeCredentialReference: Cooldown] = [:]
    private var cooldownChangeContinuations: [
        UUID: AsyncStream<ForgeCredentialReference>.Continuation
    ] = [:]
    private var nextCooldownGeneration: UInt64 = 0

    public init() {}

    public func setOffline(_ value: Bool) {
        isOffline = value
    }

    public func recordCooldown(
        for credential: ForgeCredentialReference,
        until deadline: Date?
    ) {
        guard let deadline else {
            if cooldowns.removeValue(forKey: credential) != nil {
                publishCooldownChange(for: credential)
            }
            return
        }
        if let current = cooldowns[credential], current.deadline >= deadline {
            return
        }
        nextCooldownGeneration &+= 1
        cooldowns[credential] = Cooldown(
            deadline: deadline,
            generation: nextCooldownGeneration
        )
        publishCooldownChange(for: credential)
    }

    /// Admits traffic after the server deadline but retains the cooldown until
    /// a request that observed that exact generation succeeds. A request that
    /// began before a later throttle can therefore never clear the new pause.
    public func admitRequest(
        for credential: ForgeCredentialReference,
        at date: Date
    ) -> GitHubCredentialRequestAdmission {
        switch environment(for: credential, at: date) {
        case .offline:
            return .offline
        case let .rateLimited(until):
            return .rateLimited(until: until)
        case .available:
            return .allowed(GitHubCredentialRequestPermit(
                credential: credential,
                cooldownGeneration: cooldowns[credential]?.generation
            ))
        }
    }

    public func recordSuccessfulRequest(_ permit: GitHubCredentialRequestPermit) {
        guard let observedGeneration = permit.cooldownGeneration,
              let current = cooldowns[permit.credential],
              current.generation == observedGeneration
        else {
            return
        }
        cooldowns.removeValue(forKey: permit.credential)
        publishCooldownChange(for: permit.credential)
    }

    /// Returns the server deadline for a cooldown that still awaits a
    /// successful current-generation retry. The deadline may already have
    /// elapsed: traffic is then admitted, but contextual account rebinding
    /// must remain disabled until that retry succeeds.
    public func retainedCooldownDeadline(
        for credential: ForgeCredentialReference
    ) -> Date? {
        cooldowns[credential]?.deadline
    }

    public func retainedCooldownState(
        for credential: ForgeCredentialReference,
        at date: Date
    ) -> GitHubCredentialCooldownState {
        guard let cooldown = cooldowns[credential] else { return .none }
        if date < cooldown.deadline {
            return .waiting(until: cooldown.deadline)
        }
        return .retryPending(deadline: cooldown.deadline)
    }

    public func cooldownChanges() -> AsyncStream<ForgeCredentialReference> {
        let id = UUID()
        return AsyncStream { continuation in
            cooldownChangeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeCooldownChangeContinuation(id) }
            }
        }
    }

    public func environment(
        for credential: ForgeCredentialReference,
        at date: Date
    ) -> ForgeMutationEnvironment {
        if isOffline {
            return .offline
        }
        guard let cooldown = cooldowns[credential] else {
            return .available
        }
        guard date < cooldown.deadline else {
            return .available
        }
        return .rateLimited(until: cooldown.deadline)
    }

    private func publishCooldownChange(for credential: ForgeCredentialReference) {
        for continuation in cooldownChangeContinuations.values {
            continuation.yield(credential)
        }
    }

    private func removeCooldownChangeContinuation(_ id: UUID) {
        cooldownChangeContinuations.removeValue(forKey: id)
    }
}
