import Foundation

public struct ForgeRepositoryBinding: Hashable, Sendable {
    public let localRemoteName: String
    public let primaryRepository: ForgeRepositoryIdentity
    public let preferredAccount: ForgeAccountID?

    public init(
        localRemoteName: String,
        primaryRepository: ForgeRepositoryIdentity,
        preferredAccount: ForgeAccountID? = nil
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(localRemoteName) else {
            throw ForgeBindingError.invalidRemoteName
        }
        if let preferredAccount, preferredAccount.forge != primaryRepository.forge {
            throw ForgeIdentityError.mismatchedForge
        }
        self.localRemoteName = localRemoteName
        self.primaryRepository = primaryRepository
        self.preferredAccount = preferredAccount
    }
}

extension ForgeRepositoryBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case localRemoteName
        case primaryRepository
        case preferredAccount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            localRemoteName: container.decode(String.self, forKey: .localRemoteName),
            primaryRepository: container.decode(ForgeRepositoryIdentity.self, forKey: .primaryRepository),
            preferredAccount: container.decodeIfPresent(ForgeAccountID.self, forKey: .preferredAccount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localRemoteName, forKey: .localRemoteName)
        try container.encode(primaryRepository, forKey: .primaryRepository)
        try container.encodeIfPresent(preferredAccount, forKey: .preferredAccount)
    }
}

public enum ForgeBindingError: Error, Equatable, LocalizedError, Sendable {
    case invalidRemoteName

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteName: "The Git remote name is invalid."
        }
    }
}

public enum ForgeCandidateConfidence: Int, Codable, Comparable, Hashable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: ForgeCandidateConfidence, rhs: ForgeCandidateConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeRepositoryRelationship: String, Codable, Hashable, Sendable {
    case direct
    case fork
    case parent
    case upstream
    case unknown
}

public struct ForgeRepositoryCandidate: Codable, Hashable, Sendable {
    public let remoteName: String
    public let repository: ForgeRepositoryIdentity
    public let confidence: ForgeCandidateConfidence
    public let relationship: ForgeRepositoryRelationship

    public init(
        remoteName: String,
        repository: ForgeRepositoryIdentity,
        confidence: ForgeCandidateConfidence,
        relationship: ForgeRepositoryRelationship = .unknown
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(remoteName) else {
            throw ForgeBindingError.invalidRemoteName
        }
        self.remoteName = remoteName
        self.repository = repository
        self.confidence = confidence
        self.relationship = relationship
    }
}

public enum PrimaryForgeRepositorySelection: Equatable, Sendable {
    case existing(ForgeRepositoryBinding)
    case automatic(ForgeRepositoryBinding)
    case requiresChoice([ForgeRepositoryCandidate])
    case unavailable
}

public enum PrimaryForgeRepositorySelector {
    /// Existing bindings are deliberately stable. The selected Git remote and
    /// `origin`/`upstream` names are never allowed to replace them implicitly.
    public static func select(
        existingBinding: ForgeRepositoryBinding?,
        candidates: [ForgeRepositoryCandidate]
    ) -> PrimaryForgeRepositorySelection {
        if let existingBinding {
            return .existing(existingBinding)
        }

        let choices = uniqueSortedCandidates(candidates)
        guard !choices.isEmpty else { return .unavailable }
        guard choices.count == 1,
              choices[0].confidence == .high,
              let binding = try? ForgeRepositoryBinding(
                  localRemoteName: choices[0].remoteName,
                  primaryRepository: choices[0].repository
              )
        else {
            return .requiresChoice(choices)
        }
        return .automatic(binding)
    }

    private static func uniqueSortedCandidates(
        _ candidates: [ForgeRepositoryCandidate]
    ) -> [ForgeRepositoryCandidate] {
        let sorted = candidates.sorted {
            if $0.repository.canonicalKey != $1.repository.canonicalKey {
                return $0.repository.canonicalKey < $1.repository.canonicalKey
            }
            if $0.remoteName != $1.remoteName {
                return $0.remoteName.localizedStandardCompare($1.remoteName) == .orderedAscending
            }
            if $0.confidence != $1.confidence {
                return $0.confidence > $1.confidence
            }
            return $0.relationship.rawValue < $1.relationship.rawValue
        }
        var seen: Set<String> = []
        return sorted.filter { candidate in
            let key = "\(candidate.repository.canonicalKey)|\(candidate.remoteName)"
            return seen.insert(key).inserted
        }
    }
}
