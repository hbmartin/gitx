import Foundation

public enum ForgeDraftError: Error, Equatable, LocalizedError, Sendable {
    case invalidDestinationIdentifier
    case mismatchedAccountForge
    case displayedHeadRequired
    case displayedHeadNotAllowed
    case invalidTimestampOrder
    case staleEdit

    public var errorDescription: String? {
        switch self {
        case .invalidDestinationIdentifier: "The Forge Draft destination identifier is invalid."
        case .mismatchedAccountForge: "The Forge Draft Account and destination belong to different Forges."
        case .displayedHeadRequired: "This Forge Draft requires the displayed Pull Request head."
        case .displayedHeadNotAllowed: "This Forge Draft destination does not use a displayed Pull Request head."
        case .invalidTimestampOrder: "The Forge Draft timestamps are out of order."
        case .staleEdit: "The Forge Draft edit predates its current state."
        }
    }
}

public struct ForgeDraftDestinationIdentifier: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeDraftError.invalidDestinationIdentifier
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ForgeDraftDestination: Codable, Hashable, Sendable {
    case createPullRequest(repository: ForgeRepositoryIdentity, base: ForgeRefName, head: ForgeRefName)
    case pullRequest(repository: ForgeRepositoryIdentity, number: ForgeItemNumber)
    case inlineReview(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        path: ForgeFilePath,
        selection: ForgeLineSelection
    )
    case reviewThread(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        thread: ForgeDraftDestinationIdentifier
    )
    case formalReview(repository: ForgeRepositoryIdentity, pullRequest: ForgeItemNumber)

    public var repository: ForgeRepositoryIdentity {
        switch self {
        case let .createPullRequest(repository, _, _),
             let .pullRequest(repository, _),
             let .inlineReview(repository, _, _, _),
             let .reviewThread(repository, _, _),
             let .formalReview(repository, _):
            repository
        }
    }

    public var requiresDisplayedPullRequestHead: Bool {
        switch self {
        case .inlineReview, .formalReview: true
        case .createPullRequest, .pullRequest, .reviewThread: false
        }
    }
}

public struct ForgeDraftIdentity: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let destination: ForgeDraftDestination
    public let displayedPullRequestHead: ForgeCommitID?

    public init(
        accountID: ForgeAccountID,
        destination: ForgeDraftDestination,
        displayedPullRequestHead: ForgeCommitID? = nil
    ) throws {
        guard accountID.forge == destination.repository.forge else {
            throw ForgeDraftError.mismatchedAccountForge
        }
        if destination.requiresDisplayedPullRequestHead {
            guard displayedPullRequestHead != nil else {
                throw ForgeDraftError.displayedHeadRequired
            }
        } else if displayedPullRequestHead != nil {
            throw ForgeDraftError.displayedHeadNotAllowed
        }
        self.accountID = accountID
        self.destination = destination
        self.displayedPullRequestHead = displayedPullRequestHead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            destination: container.decode(ForgeDraftDestination.self, forKey: .destination),
            displayedPullRequestHead: container.decodeIfPresent(ForgeCommitID.self, forKey: .displayedPullRequestHead)
        )
    }
}

public struct ForgeDraftContent: Codable, Hashable, Sendable {
    public let title: String?
    public let body: String

    public init(title: String? = nil, body: String) {
        self.title = title
        self.body = body
    }
}

public struct ForgeDraft: Codable, Hashable, Sendable {
    public let identity: ForgeDraftIdentity
    public let content: ForgeDraftContent
    public let createdAt: Date
    public let lastActivityAt: Date

    public init(
        identity: ForgeDraftIdentity,
        content: ForgeDraftContent,
        createdAt: Date,
        lastActivityAt: Date
    ) throws {
        guard lastActivityAt >= createdAt else {
            throw ForgeDraftError.invalidTimestampOrder
        }
        self.identity = identity
        self.content = content
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(ForgeDraftIdentity.self, forKey: .identity),
            content: container.decode(ForgeDraftContent.self, forKey: .content),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            lastActivityAt: container.decode(Date.self, forKey: .lastActivityAt)
        )
    }

    public func editing(_ content: ForgeDraftContent, at date: Date) throws -> ForgeDraft {
        guard date >= lastActivityAt else { throw ForgeDraftError.staleEdit }
        return try ForgeDraft(
            identity: identity,
            content: content,
            createdAt: createdAt,
            lastActivityAt: date
        )
    }

    public func recordingActivity(at date: Date) throws -> ForgeDraft {
        guard date >= lastActivityAt else { throw ForgeDraftError.staleEdit }
        return try ForgeDraft(
            identity: identity,
            content: content,
            createdAt: createdAt,
            lastActivityAt: date
        )
    }

    public func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(lastActivityAt) >= ForgePolicyConstants.durableRecordExpiration
    }
}

public enum ForgeDraftDeletionReason: String, Codable, Hashable, Sendable {
    case published
    case explicitlyDiscarded
    case accountRemoved
    case inactive
}

public enum ForgeDraftPreservationReason: String, Codable, Hashable, Sendable {
    case cancelled
    case offline
    case rateLimited
    case authorizationFailure
    case conflict
    case transportFailure
    case unknownOutcome
    case displayedHeadChanged
}

public enum ForgeDraftEvent: Hashable, Sendable {
    case edit(ForgeDraftContent, at: Date)
    case activity(at: Date)
    case publishSucceeded
    case discard
    case accountRemoved(ForgeAccountID)
    case expirationSweep(at: Date)
    case preserve(ForgeDraftPreservationReason)
}

public enum ForgeDraftState: Hashable, Sendable {
    case active(ForgeDraft)
    case deleted(ForgeDraftDeletionReason)

    public func applying(_ event: ForgeDraftEvent) throws -> ForgeDraftState {
        guard case let .active(draft) = self else { return self }
        return switch event {
        case let .edit(content, date): try .active(draft.editing(content, at: date))
        case let .activity(date): try .active(draft.recordingActivity(at: date))
        case .publishSucceeded: .deleted(.published)
        case .discard: .deleted(.explicitlyDiscarded)
        case let .accountRemoved(accountID):
            accountID == draft.identity.accountID ? .deleted(.accountRemoved) : self
        case let .expirationSweep(date):
            draft.isExpired(at: date) ? .deleted(.inactive) : self
        case .preserve: self
        }
    }
}
