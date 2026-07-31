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
            cooldowns.removeValue(forKey: credential)
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
}
