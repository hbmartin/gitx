import ForgeKit
import Foundation

/// One concurrency-safe gate shared by reads/composition and every mutation
/// adapter. Cooldowns are keyed by the exact Credential generation so rotating
/// a token never inherits stale rate-limit state from a replaced Credential.
public actor GitHubMutationSessionGate {
    public static let shared = GitHubMutationSessionGate()

    private var isOffline = false
    private var cooldowns: [ForgeCredentialReference: Date] = [:]

    public init() {}

    public func setOffline(_ value: Bool) {
        isOffline = value
    }

    public func recordCooldown(
        for credential: ForgeCredentialReference,
        until deadline: Date?
    ) {
        if let deadline {
            cooldowns[credential] = deadline
        } else {
            cooldowns.removeValue(forKey: credential)
        }
    }

    public func environment(
        for credential: ForgeCredentialReference,
        at date: Date
    ) -> ForgeMutationEnvironment {
        if isOffline {
            return .offline
        }
        guard let deadline = cooldowns[credential] else {
            return .available
        }
        guard date < deadline else {
            cooldowns.removeValue(forKey: credential)
            return .available
        }
        return .rateLimited(until: deadline)
    }
}
