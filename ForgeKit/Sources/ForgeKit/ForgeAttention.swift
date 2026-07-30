import Foundation

public enum ForgeAttentionError: Error, Equatable, LocalizedError, Sendable {
    case invalidSubjectIdentifier
    case mismatchedAccountForge
    case mismatchedDestinationRepository
    case invalidFailedCheckContext
    case invalidTimestampOrder
    case staleTransition

    public var errorDescription: String? {
        switch self {
        case .invalidSubjectIdentifier: "The Attention subject identifier is invalid."
        case .mismatchedAccountForge: "The Attention Account and repository belong to different Forges."
        case .mismatchedDestinationRepository: "The Attention destination belongs to a different repository."
        case .invalidFailedCheckContext: "Authored Pull Request check context requires a failed-check Attention item."
        case .invalidTimestampOrder: "The Attention timestamps are out of order."
        case .staleTransition: "The Attention transition predates its current state."
        }
    }
}

public struct ForgeAttentionSubjectID: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeAttentionError.invalidSubjectIdentifier
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

public struct ForgeWatchedRepositoryKey: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity

    public init(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeAttentionError.mismatchedAccountForge
        }
        self.accountID = accountID
        self.repository = repository
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository)
        )
    }

    fileprivate var schedulingKey: String {
        "\(accountID.forge.kind.rawValue)|\(accountID.forge.origin.url.absoluteString)|\(accountID.value)|\(repository.canonicalKey)"
    }
}

public enum ForgeWatchSource: String, Codable, Hashable, Sendable {
    case repositoryOpened
    case repositoryBound
    case preferences
}

public struct ForgeWatchedRepository: Codable, Hashable, Sendable {
    public let key: ForgeWatchedRepositoryKey
    public let addedAt: Date
    public let source: ForgeWatchSource
    public let includesBotReplies: Bool

    public init(
        key: ForgeWatchedRepositoryKey,
        addedAt: Date,
        source: ForgeWatchSource,
        includesBotReplies: Bool = false
    ) {
        self.key = key
        self.addedAt = addedAt
        self.source = source
        self.includesBotReplies = includesBotReplies
    }
}

public struct ForgeAttentionPolicy: Codable, Hashable, Sendable {
    public let includesFailedChecksOnAuthoredPullRequests: Bool
    public let includesFailedChecksAwaitingReview: Bool

    public init(
        includesFailedChecksOnAuthoredPullRequests: Bool = true,
        includesFailedChecksAwaitingReview: Bool = false
    ) {
        self.includesFailedChecksOnAuthoredPullRequests = includesFailedChecksOnAuthoredPullRequests
        self.includesFailedChecksAwaitingReview = includesFailedChecksAwaitingReview
    }

    public static let defaultValue = ForgeAttentionPolicy()
}

public enum ForgeAttentionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case reviewRequest
    case mention
    case reply
    case assignment
    case failedCheck
}

public struct ForgeAttentionSignal: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case reviewRequested
        case mention(actorIsAccount: Bool)
        case reply(actorIsAccount: Bool, actorIsBot: Bool, accountParticipated: Bool)
        case assigned
        case checkFailed(authoredByAccount: Bool, awaitingAccountReview: Bool)
        case mergeQueueTransition
    }

    public let watchedRepositoryKey: ForgeWatchedRepositoryKey
    public let event: Event

    public init(watchedRepositoryKey: ForgeWatchedRepositoryKey, event: Event) {
        self.watchedRepositoryKey = watchedRepositoryKey
        self.event = event
    }
}

public struct ForgeAttentionDerivation: Equatable, Sendable {
    public let kind: ForgeAttentionKind
    public let authoredPullRequestFailedCheck: Bool

    public init(kind: ForgeAttentionKind, authoredPullRequestFailedCheck: Bool = false) {
        self.kind = kind
        self.authoredPullRequestFailedCheck = authoredPullRequestFailedCheck
    }
}

public enum ForgeAttentionDerivationPolicy {
    public static func derive(
        _ signal: ForgeAttentionSignal,
        watchedRepository: ForgeWatchedRepository,
        policy: ForgeAttentionPolicy = .defaultValue
    ) -> ForgeAttentionDerivation? {
        guard signal.watchedRepositoryKey == watchedRepository.key else { return nil }
        switch signal.event {
        case .reviewRequested:
            return ForgeAttentionDerivation(kind: .reviewRequest)
        case let .mention(actorIsAccount):
            return actorIsAccount ? nil : ForgeAttentionDerivation(kind: .mention)
        case let .reply(actorIsAccount, actorIsBot, accountParticipated):
            guard !actorIsAccount,
                  accountParticipated,
                  !actorIsBot || watchedRepository.includesBotReplies
            else { return nil }
            return ForgeAttentionDerivation(kind: .reply)
        case .assigned:
            return ForgeAttentionDerivation(kind: .assignment)
        case let .checkFailed(authoredByAccount, awaitingAccountReview):
            let included = (authoredByAccount && policy.includesFailedChecksOnAuthoredPullRequests)
                || (awaitingAccountReview && policy.includesFailedChecksAwaitingReview)
            guard included else { return nil }
            return ForgeAttentionDerivation(
                kind: .failedCheck,
                authoredPullRequestFailedCheck: authoredByAccount
            )
        case .mergeQueueTransition:
            return nil
        }
    }
}

public struct ForgeAttentionItemID: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let kind: ForgeAttentionKind
    public let subjectID: ForgeAttentionSubjectID

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        kind: ForgeAttentionKind,
        subjectID: ForgeAttentionSubjectID
    ) throws {
        guard accountID.forge == repository.forge else {
            throw ForgeAttentionError.mismatchedAccountForge
        }
        self.accountID = accountID
        self.repository = repository
        self.kind = kind
        self.subjectID = subjectID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            kind: container.decode(ForgeAttentionKind.self, forKey: .kind),
            subjectID: container.decode(ForgeAttentionSubjectID.self, forKey: .subjectID)
        )
    }
}

public enum ForgeAttentionItemState: String, Codable, Hashable, Sendable {
    case active
    case resolved
}

public enum ForgeAttentionSeenState: Codable, Hashable, Sendable {
    case unseen
    case seen(at: Date)
}

public struct ForgeAttentionItem: Codable, Hashable, Sendable {
    public let id: ForgeAttentionItemID
    public let destination: ForgeDestination
    public let state: ForgeAttentionItemState
    public let seenState: ForgeAttentionSeenState
    public let authoredPullRequestFailedCheck: Bool
    public let firstBecameActionableAt: Date
    public let lastTransitionAt: Date
    public let lastUpdatedAt: Date

    public init(
        id: ForgeAttentionItemID,
        destination: ForgeDestination,
        authoredPullRequestFailedCheck: Bool = false,
        becameActionableAt: Date
    ) throws {
        guard id.repository == destination.repository else {
            throw ForgeAttentionError.mismatchedDestinationRepository
        }
        guard !authoredPullRequestFailedCheck || id.kind == .failedCheck else {
            throw ForgeAttentionError.invalidFailedCheckContext
        }
        self.id = id
        self.destination = destination
        state = .active
        seenState = .unseen
        self.authoredPullRequestFailedCheck = authoredPullRequestFailedCheck
        firstBecameActionableAt = becameActionableAt
        lastTransitionAt = becameActionableAt
        lastUpdatedAt = becameActionableAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ForgeAttentionItemID.self, forKey: .id)
        let destination = try container.decode(ForgeDestination.self, forKey: .destination)
        let state = try container.decode(ForgeAttentionItemState.self, forKey: .state)
        let seenState = try container.decode(ForgeAttentionSeenState.self, forKey: .seenState)
        let authoredPullRequestFailedCheck = try container.decode(
            Bool.self,
            forKey: .authoredPullRequestFailedCheck
        )
        let firstBecameActionableAt = try container.decode(Date.self, forKey: .firstBecameActionableAt)
        let lastTransitionAt = try container.decode(Date.self, forKey: .lastTransitionAt)
        let lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
        guard id.repository == destination.repository else {
            throw ForgeAttentionError.mismatchedDestinationRepository
        }
        guard !authoredPullRequestFailedCheck || id.kind == .failedCheck else {
            throw ForgeAttentionError.invalidFailedCheckContext
        }
        guard firstBecameActionableAt <= lastTransitionAt,
              lastTransitionAt <= lastUpdatedAt
        else {
            throw ForgeAttentionError.invalidTimestampOrder
        }
        if case let .seen(seenAt) = seenState {
            guard firstBecameActionableAt <= seenAt,
                  seenAt <= lastUpdatedAt
            else {
                throw ForgeAttentionError.invalidTimestampOrder
            }
        }
        self.init(
            id: id,
            destination: destination,
            state: state,
            seenState: seenState,
            authoredPullRequestFailedCheck: authoredPullRequestFailedCheck,
            firstBecameActionableAt: firstBecameActionableAt,
            lastTransitionAt: lastTransitionAt,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    private init(
        id: ForgeAttentionItemID,
        destination: ForgeDestination,
        state: ForgeAttentionItemState,
        seenState: ForgeAttentionSeenState,
        authoredPullRequestFailedCheck: Bool,
        firstBecameActionableAt: Date,
        lastTransitionAt: Date,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.destination = destination
        self.state = state
        self.seenState = seenState
        self.authoredPullRequestFailedCheck = authoredPullRequestFailedCheck
        self.firstBecameActionableAt = firstBecameActionableAt
        self.lastTransitionAt = lastTransitionAt
        self.lastUpdatedAt = lastUpdatedAt
    }

    public func opening(at date: Date) throws -> ForgeAttentionItem {
        try markingSeen(at: date)
    }

    public func markingSeen(at date: Date) throws -> ForgeAttentionItem {
        try validateTransition(at: date)
        return replacing(seenState: .seen(at: date), lastUpdatedAt: date)
    }

    public func markingUnseen(at date: Date) throws -> ForgeAttentionItem {
        try validateTransition(at: date)
        return replacing(seenState: .unseen, lastUpdatedAt: date)
    }

    public func resolving(at date: Date) throws -> ForgeAttentionItem {
        try validateTransition(at: date)
        guard state != .resolved else { return replacing(lastUpdatedAt: date) }
        return replacing(state: .resolved, lastTransitionAt: date, lastUpdatedAt: date)
    }

    public func reactivating(at date: Date) throws -> ForgeAttentionItem {
        try validateTransition(at: date)
        guard state != .active else { return replacing(lastUpdatedAt: date) }
        return replacing(
            state: .active,
            seenState: .unseen,
            lastTransitionAt: date,
            lastUpdatedAt: date
        )
    }

    public func isExpired(at date: Date) -> Bool {
        switch state {
        case .resolved:
            date.timeIntervalSince(lastTransitionAt) >= ForgePolicyConstants.durableRecordExpiration
        case .active:
            if case let .seen(seenAt) = seenState {
                date.timeIntervalSince(seenAt) >= ForgePolicyConstants.durableRecordExpiration
            } else {
                false
            }
        }
    }

    private func replacing(
        state: ForgeAttentionItemState? = nil,
        seenState: ForgeAttentionSeenState? = nil,
        lastTransitionAt: Date? = nil,
        lastUpdatedAt: Date
    ) -> ForgeAttentionItem {
        ForgeAttentionItem(
            id: id,
            destination: destination,
            state: state ?? self.state,
            seenState: seenState ?? self.seenState,
            authoredPullRequestFailedCheck: authoredPullRequestFailedCheck,
            firstBecameActionableAt: firstBecameActionableAt,
            lastTransitionAt: lastTransitionAt ?? self.lastTransitionAt,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    private func validateTransition(at date: Date) throws {
        guard date >= lastUpdatedAt else { throw ForgeAttentionError.staleTransition }
    }
}

public enum ForgeAttentionScope: Hashable, Sendable {
    case currentRepository(ForgeWatchedRepositoryKey)
    case all(accountID: ForgeAccountID)
}

public enum ForgeAttentionVisibility: String, Codable, Hashable, Sendable {
    case unseenOnly
    case active
    case all
}

public struct ForgeAttentionQuery: Hashable, Sendable {
    public let scope: ForgeAttentionScope
    public let visibility: ForgeAttentionVisibility

    public init(scope: ForgeAttentionScope, visibility: ForgeAttentionVisibility = .unseenOnly) {
        self.scope = scope
        self.visibility = visibility
    }

    public func applying(to items: [ForgeAttentionItem]) -> [ForgeAttentionItem] {
        items.filter { item in
            let inScope = switch scope {
            case let .all(accountID): item.id.accountID == accountID
            case let .currentRepository(key):
                item.id.accountID == key.accountID && item.id.repository == key.repository
            }
            let isVisible = switch visibility {
            case .all, .active: item.state == .active
            case .unseenOnly: item.state == .active && item.seenState == .unseen
            }
            return inScope && isVisible
        }.sorted {
            if $0.lastTransitionAt != $1.lastTransitionAt {
                return $0.lastTransitionAt > $1.lastTransitionAt
            }
            return $0.id.subjectID.value < $1.id.subjectID.value
        }
    }

    public func markingAllSeen(_ items: [ForgeAttentionItem], at date: Date) throws -> [ForgeAttentionItem] {
        let selectedIDs = Set(applying(to: items).filter { $0.state == .active }.map(\.id))
        return try items.map { selectedIDs.contains($0.id) ? try $0.markingSeen(at: date) : $0 }
    }
}

public enum ForgeAttentionAlertCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case reviewRequests
    case mentionsAndReplies
    case assignments
    case failedChecksOnAuthoredPullRequests
}

public enum ForgeAttentionAlertAction: String, CaseIterable, Codable, Hashable, Sendable {
    case open
    case markSeen
}

public enum ForgeAttentionAlertDecision: Equatable, Sendable {
    case suppressed
    case deliver(category: ForgeAttentionAlertCategory, actions: [ForgeAttentionAlertAction])
}

public enum ForgeAttentionAlertPolicy {
    public static func category(for item: ForgeAttentionItem) -> ForgeAttentionAlertCategory? {
        switch item.id.kind {
        case .reviewRequest: .reviewRequests
        case .mention, .reply: .mentionsAndReplies
        case .assignment: .assignments
        case .failedCheck:
            item.authoredPullRequestFailedCheck ? .failedChecksOnAuthoredPullRequests : nil
        }
    }

    public static func decision(
        forNewlyActionable item: ForgeAttentionItem,
        baselineAlreadyEstablished: Bool,
        applicationIsRunning: Bool,
        enabledCategories: Set<ForgeAttentionAlertCategory>,
        systemPermissionGranted: Bool
    ) -> ForgeAttentionAlertDecision {
        guard baselineAlreadyEstablished,
              applicationIsRunning,
              systemPermissionGranted,
              let category = category(for: item),
              enabledCategories.contains(category)
        else { return .suppressed }
        return .deliver(category: category, actions: [.open, .markSeen])
    }

    public static func shouldRequestSystemPermission(
        previous: Set<ForgeAttentionAlertCategory>,
        updated: Set<ForgeAttentionAlertCategory>
    ) -> Bool {
        previous.isEmpty && !updated.isEmpty
    }
}

public struct ForgeAttentionPollingCursor: Hashable, Sendable {
    public let lastPolled: ForgeWatchedRepositoryKey?

    public init(lastPolled: ForgeWatchedRepositoryKey? = nil) {
        self.lastPolled = lastPolled
    }

    public func next(in watchedRepositories: [ForgeWatchedRepository]) -> ForgeWatchedRepository? {
        let ordered = watchedRepositories.sorted { $0.key.schedulingKey < $1.key.schedulingKey }
        guard !ordered.isEmpty else { return nil }
        guard let lastPolled,
              let index = ordered.firstIndex(where: { $0.key == lastPolled })
        else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }
}
