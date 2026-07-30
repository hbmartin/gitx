import Foundation

public enum ForgeCollaborationModelError: Error, Equatable, LocalizedError, Sendable {
    case invalidObjectIdentifier
    case invalidPageCursor
    case invalidPageTotal
    case invalidActorLogin
    case invalidTeamName
    case invalidTeamSlug
    case invalidLabelName
    case invalidLabelColor
    case invalidMilestoneNumber
    case invalidCheckName
    case mismatchedForge
    case mismatchedRepository

    public var errorDescription: String? {
        switch self {
        case .invalidObjectIdentifier: "The Forge object identifier is invalid."
        case .invalidPageCursor: "The Forge page cursor is invalid."
        case .invalidPageTotal: "The Forge page total is invalid."
        case .invalidActorLogin: "The Forge actor login is invalid."
        case .invalidTeamName: "The Forge team name is invalid."
        case .invalidTeamSlug: "The Forge team slug is invalid."
        case .invalidLabelName: "The Forge label name is invalid."
        case .invalidLabelColor: "The Forge label color is invalid."
        case .invalidMilestoneNumber: "The Forge milestone number is invalid."
        case .invalidCheckName: "The Forge check name is invalid."
        case .mismatchedForge: "The collaboration value belongs to a different Forge."
        case .mismatchedRepository: "The collaboration value belongs to a different Forge Repository."
        }
    }
}

/// A provider-issued identifier scoped to one exact Forge. The value is
/// opaque and must never be interpreted as a GitHub GraphQL node type.
public struct ForgeObjectID: Hashable, Sendable {
    public let forge: ForgeIdentity
    public let value: String

    public init(forge: ForgeIdentity, value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeCollaborationModelError.invalidObjectIdentifier
        }
        self.forge = forge
        self.value = value
    }
}

extension ForgeObjectID: Codable {
    private enum CodingKeys: String, CodingKey {
        case forge
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            forge: container.decode(ForgeIdentity.self, forKey: .forge),
            value: container.decode(String.self, forKey: .value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(forge, forKey: .forge)
        try container.encode(value, forKey: .value)
    }
}

public struct ForgePageCursor: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeCollaborationModelError.invalidPageCursor
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ForgePage<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let items: [Element]
    public let nextCursor: ForgePageCursor?
    public let totalCount: Int?

    public init(items: [Element], nextCursor: ForgePageCursor? = nil, totalCount: Int? = nil) throws {
        if let totalCount, totalCount < 0 {
            throw ForgeCollaborationModelError.invalidPageTotal
        }
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            items: container.decode([Element].self, forKey: .items),
            nextCursor: container.decodeIfPresent(ForgePageCursor.self, forKey: .nextCursor),
            totalCount: container.decodeIfPresent(Int.self, forKey: .totalCount)
        )
    }
}

public enum ForgeReadUnavailableReason: String, CaseIterable, Codable, Hashable, Sendable {
    case notRequested
    case partialResponse
    case authenticationRequired
    case permissionDenied
    case unsupported
}

/// Distinguishes a legitimate optional value from data that the provider did
/// not or could not return. Cached failures must remain visibly unavailable.
public enum ForgeReadSection<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case available(Value)
    case unavailable(ForgeReadUnavailableReason)
}

public enum ForgeActorKind: String, CaseIterable, Codable, Hashable, Sendable {
    case person
    case organization
    case bot
    case unknown
}

public struct ForgeActor: Hashable, Sendable {
    public let id: ForgeObjectID
    public let login: String
    public let displayName: String?
    public let avatarURL: URL?
    public let kind: ForgeActorKind

    public init(
        id: ForgeObjectID,
        login: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        kind: ForgeActorKind
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(login) else {
            throw ForgeCollaborationModelError.invalidActorLogin
        }
        self.id = id
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.kind = kind
    }
}

extension ForgeActor: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName
        case avatarURL
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeObjectID.self, forKey: .id),
            login: container.decode(String.self, forKey: .login),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            avatarURL: container.decodeIfPresent(URL.self, forKey: .avatarURL),
            kind: container.decode(ForgeActorKind.self, forKey: .kind)
        )
    }
}

public enum ForgeAuthor: Codable, Hashable, Sendable {
    case actor(ForgeActor)
    case deleted
}

public struct ForgeTeam: Hashable, Sendable {
    public let id: ForgeObjectID
    public let name: String
    public let slug: String
    public let avatarURL: URL?

    public init(id: ForgeObjectID, name: String, slug: String, avatarURL: URL? = nil) throws {
        guard ForgePathComponent.isNonemptyPrintable(name) else {
            throw ForgeCollaborationModelError.invalidTeamName
        }
        guard ForgePathComponent.isNonemptyPrintable(slug) else {
            throw ForgeCollaborationModelError.invalidTeamSlug
        }
        self.id = id
        self.name = name
        self.slug = slug
        self.avatarURL = avatarURL
    }
}

extension ForgeTeam: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case avatarURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeObjectID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            slug: container.decode(String.self, forKey: .slug),
            avatarURL: container.decodeIfPresent(URL.self, forKey: .avatarURL)
        )
    }
}

public enum ForgeReviewParticipant: Codable, Hashable, Sendable {
    case actor(ForgeActor)
    case team(ForgeTeam)
}

public struct ForgeLabelColor: Codable, Hashable, Sendable {
    public let hexRGB: String

    public init(_ hexRGB: String) throws {
        guard hexRGB.unicodeScalars.count == 6,
              hexRGB.unicodeScalars.allSatisfy(\.isASCIIHexDigit)
        else {
            throw ForgeCollaborationModelError.invalidLabelColor
        }
        self.hexRGB = hexRGB.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexRGB)
    }
}

public struct ForgeLabel: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID
    public let name: String
    public let description: String?
    public let color: ForgeLabelColor?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        name: String,
        description: String? = nil,
        color: ForgeLabelColor? = nil
    ) throws {
        guard id.forge == repository.forge else {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        guard ForgePathComponent.isNonemptyPrintable(name) else {
            throw ForgeCollaborationModelError.invalidLabelName
        }
        self.repository = repository
        self.id = id
        self.name = name
        self.description = description
        self.color = color
    }
}

extension ForgeLabel: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case id
        case name
        case description
        case color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            id: container.decode(ForgeObjectID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            description: container.decodeIfPresent(String.self, forKey: .description),
            color: container.decodeIfPresent(ForgeLabelColor.self, forKey: .color)
        )
    }
}

public enum ForgeMilestoneState: String, CaseIterable, Codable, Hashable, Sendable {
    case open
    case closed
}

public struct ForgeMilestone: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID
    public let number: Int
    public let title: String
    public let description: String?
    public let state: ForgeMilestoneState
    public let dueAt: Date?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        number: Int,
        title: String,
        description: String? = nil,
        state: ForgeMilestoneState,
        dueAt: Date? = nil
    ) throws {
        guard id.forge == repository.forge else {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        guard number > 0 else {
            throw ForgeCollaborationModelError.invalidMilestoneNumber
        }
        self.repository = repository
        self.id = id
        self.number = number
        self.title = title
        self.description = description
        self.state = state
        self.dueAt = dueAt
    }
}

extension ForgeMilestone: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case id
        case number
        case title
        case description
        case state
        case dueAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            id: container.decode(ForgeObjectID.self, forKey: .id),
            number: container.decode(Int.self, forKey: .number),
            title: container.decode(String.self, forKey: .title),
            description: container.decodeIfPresent(String.self, forKey: .description),
            state: container.decode(ForgeMilestoneState.self, forKey: .state),
            dueAt: container.decodeIfPresent(Date.self, forKey: .dueAt)
        )
    }
}

public struct ForgeBranchReference: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let name: ForgeRefName
    public let commit: ForgeCommitID

    public init(repository: ForgeRepositoryIdentity, name: ForgeRefName, commit: ForgeCommitID) {
        self.repository = repository
        self.name = name
        self.commit = commit
    }
}

public enum ForgeRepositoryVisibility: String, CaseIterable, Codable, Hashable, Sendable {
    case `public`
    case `private`
    case `internal`
    case unknown
}

public enum ForgeForkRelationship: Codable, Hashable, Sendable {
    case standalone
    case fork(parent: ForgeRepositoryIdentity)
}

public struct ForgeRepositoryFacts: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let defaultBranch: ForgeReadSection<ForgeRefName>
    public let description: ForgeReadSection<String?>
    public let topics: ForgeReadSection<[String]>
    public let visibility: ForgeReadSection<ForgeRepositoryVisibility>
    public let isArchived: ForgeReadSection<Bool>
    public let forkRelationship: ForgeReadSection<ForgeForkRelationship>

    public init(
        repository: ForgeRepositoryIdentity,
        defaultBranch: ForgeReadSection<ForgeRefName>,
        description: ForgeReadSection<String?>,
        topics: ForgeReadSection<[String]>,
        visibility: ForgeReadSection<ForgeRepositoryVisibility>,
        isArchived: ForgeReadSection<Bool>,
        forkRelationship: ForgeReadSection<ForgeForkRelationship>
    ) throws {
        if case let .available(.fork(parent)) = forkRelationship,
           parent.forge != repository.forge
        {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        self.repository = repository
        self.defaultBranch = defaultBranch
        self.description = description
        self.topics = topics
        self.visibility = visibility
        self.isArchived = isArchived
        self.forkRelationship = forkRelationship
    }
}

extension ForgeRepositoryFacts: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case defaultBranch
        case description
        case topics
        case visibility
        case isArchived
        case forkRelationship
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            defaultBranch: container.decode(ForgeReadSection<ForgeRefName>.self, forKey: .defaultBranch),
            description: container.decode(ForgeReadSection<String?>.self, forKey: .description),
            topics: container.decode(ForgeReadSection<[String]>.self, forKey: .topics),
            visibility: container.decode(ForgeReadSection<ForgeRepositoryVisibility>.self, forKey: .visibility),
            isArchived: container.decode(ForgeReadSection<Bool>.self, forKey: .isArchived),
            forkRelationship: container.decode(
                ForgeReadSection<ForgeForkRelationship>.self,
                forKey: .forkRelationship
            )
        )
    }
}

public enum ForgeCheckKind: String, CaseIterable, Codable, Hashable, Sendable {
    case check
    case commitStatus
}

public enum ForgeCheckState: String, CaseIterable, Codable, Hashable, Sendable {
    case succeeded
    case failed
    case running
    case attentionRequired
    case neutral
}

public struct ForgeCheck: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID?
    public let kind: ForgeCheckKind
    public let name: String
    public let summary: String?
    public let state: ForgeCheckState
    public let detailsURL: URL?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID? = nil,
        kind: ForgeCheckKind,
        name: String,
        summary: String? = nil,
        state: ForgeCheckState,
        detailsURL: URL? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws {
        guard id?.forge == nil || id?.forge == repository.forge else {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        guard ForgePathComponent.isNonemptyPrintable(name) else {
            throw ForgeCollaborationModelError.invalidCheckName
        }
        self.repository = repository
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.state = state
        self.detailsURL = detailsURL
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

extension ForgeCheck: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case id
        case kind
        case name
        case summary
        case state
        case detailsURL
        case startedAt
        case completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            id: container.decodeIfPresent(ForgeObjectID.self, forKey: .id),
            kind: container.decode(ForgeCheckKind.self, forKey: .kind),
            name: container.decode(String.self, forKey: .name),
            summary: container.decodeIfPresent(String.self, forKey: .summary),
            state: container.decode(ForgeCheckState.self, forKey: .state),
            detailsURL: container.decodeIfPresent(URL.self, forKey: .detailsURL),
            startedAt: container.decodeIfPresent(Date.self, forKey: .startedAt),
            completedAt: container.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }
}

public enum ForgeCheckRollup: String, CaseIterable, Codable, Hashable, Sendable {
    case succeeded
    case failed
    case running
    case attentionRequired
    case neutral
}

public enum ForgeCheckRollupPolicy {
    public static func rollup(_ checks: [ForgeCheck]) -> ForgeCheckRollup {
        if checks.contains(where: { $0.state == .failed }) {
            return .failed
        }
        if checks.contains(where: { $0.state == .attentionRequired }) {
            return .attentionRequired
        }
        if checks.contains(where: { $0.state == .running }) {
            return .running
        }
        if checks.contains(where: { $0.state == .succeeded }) {
            return .succeeded
        }
        return .neutral
    }
}

public enum ForgeReviewState: String, CaseIterable, Codable, Hashable, Sendable {
    case approved
    case changesRequested
    case commented
    case dismissed
}

public struct ForgeReviewer: Codable, Hashable, Sendable {
    public let participant: ForgeReviewParticipant
    public let isRequested: Bool
    public let latestReviewState: ForgeReviewState?

    public init(
        participant: ForgeReviewParticipant,
        isRequested: Bool,
        latestReviewState: ForgeReviewState? = nil
    ) {
        self.participant = participant
        self.isRequested = isRequested
        self.latestReviewState = latestReviewState
    }
}

public enum ForgeReviewRollup: String, CaseIterable, Codable, Hashable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
    case noDecision
}

public enum ForgeMergeability: String, CaseIterable, Codable, Hashable, Sendable {
    case mergeable
    case conflicting
    case unknown
}

public enum ForgePullRequestState: String, CaseIterable, Codable, Hashable, Sendable {
    case open
    case closed
    case merged
}

public enum ForgeIssueState: String, CaseIterable, Codable, Hashable, Sendable {
    case open
    case closed
}

public struct ForgeLinkedIssue: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let state: ForgeIssueState
    public let title: String

    public init(repository: ForgeRepositoryIdentity, number: ForgeItemNumber, state: ForgeIssueState, title: String) {
        self.repository = repository
        self.number = number
        self.state = state
        self.title = title
    }
}

public enum ForgeTimelineEvent: Codable, Hashable, Sendable {
    case comment(bodyMarkdown: String, updatedAt: Date?)
    case review(state: ForgeReviewState, bodyMarkdown: String, commit: ForgeCommitID?)
    case closed
    case reopened
    case merged(commit: ForgeCommitID?)
    case assigned(ForgeActor)
    case unassigned(ForgeActor)
    case labeled(ForgeLabel)
    case unlabeled(ForgeLabel)
    case milestoneChanged(ForgeMilestone?)
    case renamed(previousTitle: String, currentTitle: String)
    case crossReferenced(destination: ForgeDestination, title: String)
}

public struct ForgeTimelineItem: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID
    public let occurredAt: Date
    public let actor: ForgeAuthor?
    public let event: ForgeTimelineEvent

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        occurredAt: Date,
        actor: ForgeAuthor? = nil,
        event: ForgeTimelineEvent
    ) throws {
        guard id.forge == repository.forge else {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        try Self.validate(actor: actor, event: event, repository: repository)
        self.repository = repository
        self.id = id
        self.occurredAt = occurredAt
        self.actor = actor
        self.event = event
    }

    private static func validate(
        actor: ForgeAuthor?,
        event: ForgeTimelineEvent,
        repository: ForgeRepositoryIdentity
    ) throws {
        if case let .actor(value) = actor, value.id.forge != repository.forge {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        switch event {
        case let .assigned(value), let .unassigned(value):
            guard value.id.forge == repository.forge else {
                throw ForgeCollaborationModelError.mismatchedForge
            }
        case let .labeled(value), let .unlabeled(value):
            guard value.repository == repository else {
                throw ForgeCollaborationModelError.mismatchedRepository
            }
        case let .milestoneChanged(value):
            guard value?.repository == nil || value?.repository == repository else {
                throw ForgeCollaborationModelError.mismatchedRepository
            }
        case let .crossReferenced(destination, _):
            guard destination.repository.forge == repository.forge else {
                throw ForgeCollaborationModelError.mismatchedForge
            }
        case .comment, .review, .closed, .reopened, .merged, .renamed:
            break
        }
    }
}

extension ForgeTimelineItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case id
        case occurredAt
        case actor
        case event
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            id: container.decode(ForgeObjectID.self, forKey: .id),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            actor: container.decodeIfPresent(ForgeAuthor.self, forKey: .actor),
            event: container.decode(ForgeTimelineEvent.self, forKey: .event)
        )
    }
}

public struct ForgePullRequestSummary: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let state: ForgePullRequestState
    public let isDraft: Bool
    public let title: String
    public let author: ForgeReadSection<ForgeAuthor>
    public let head: ForgeReadSection<ForgeBranchReference>
    public let base: ForgeReadSection<ForgeBranchReference>
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let mergedAt: Date?
    public let labels: ForgeReadSection<[ForgeLabel]>
    public let checkRollup: ForgeReadSection<ForgeCheckRollup>
    public let reviewRollup: ForgeReadSection<ForgeReviewRollup>

    public init(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        state: ForgePullRequestState,
        isDraft: Bool,
        title: String,
        author: ForgeReadSection<ForgeAuthor>,
        head: ForgeReadSection<ForgeBranchReference>,
        base: ForgeReadSection<ForgeBranchReference>,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date? = nil,
        mergedAt: Date? = nil,
        labels: ForgeReadSection<[ForgeLabel]>,
        checkRollup: ForgeReadSection<ForgeCheckRollup>,
        reviewRollup: ForgeReadSection<ForgeReviewRollup>
    ) throws {
        try Self.validate(repository: repository, author: author, head: head, base: base, labels: labels)
        self.repository = repository
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.title = title
        self.author = author
        self.head = head
        self.base = base
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
        self.labels = labels
        self.checkRollup = checkRollup
        self.reviewRollup = reviewRollup
    }

    private static func validate(
        repository: ForgeRepositoryIdentity,
        author: ForgeReadSection<ForgeAuthor>,
        head: ForgeReadSection<ForgeBranchReference>,
        base: ForgeReadSection<ForgeBranchReference>,
        labels: ForgeReadSection<[ForgeLabel]>
    ) throws {
        if case let .available(.actor(value)) = author, value.id.forge != repository.forge {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(value) = head, value.repository.forge != repository.forge {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(value) = base, value.repository != repository {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        if case let .available(values) = labels,
           values.contains(where: { $0.repository != repository })
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
    }
}

extension ForgePullRequestSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case number
        case state
        case isDraft
        case title
        case author
        case head
        case base
        case createdAt
        case updatedAt
        case closedAt
        case mergedAt
        case labels
        case checkRollup
        case reviewRollup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            number: container.decode(ForgeItemNumber.self, forKey: .number),
            state: container.decode(ForgePullRequestState.self, forKey: .state),
            isDraft: container.decode(Bool.self, forKey: .isDraft),
            title: container.decode(String.self, forKey: .title),
            author: container.decode(ForgeReadSection<ForgeAuthor>.self, forKey: .author),
            head: container.decode(ForgeReadSection<ForgeBranchReference>.self, forKey: .head),
            base: container.decode(ForgeReadSection<ForgeBranchReference>.self, forKey: .base),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            closedAt: container.decodeIfPresent(Date.self, forKey: .closedAt),
            mergedAt: container.decodeIfPresent(Date.self, forKey: .mergedAt),
            labels: container.decode(ForgeReadSection<[ForgeLabel]>.self, forKey: .labels),
            checkRollup: container.decode(ForgeReadSection<ForgeCheckRollup>.self, forKey: .checkRollup),
            reviewRollup: container.decode(ForgeReadSection<ForgeReviewRollup>.self, forKey: .reviewRollup)
        )
    }
}

public struct ForgePullRequestDetails: Hashable, Sendable {
    public let summary: ForgePullRequestSummary
    public let bodyMarkdown: ForgeReadSection<String>
    public let assignees: ForgeReadSection<[ForgeActor]>
    public let milestone: ForgeReadSection<ForgeMilestone?>
    public let reviewers: ForgeReadSection<[ForgeReviewer]>
    public let linkedIssues: ForgeReadSection<[ForgeLinkedIssue]>
    public let mergeability: ForgeReadSection<ForgeMergeability>
    public let checks: ForgeReadSection<[ForgeCheck]>
    public let timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>

    public init(
        summary: ForgePullRequestSummary,
        bodyMarkdown: ForgeReadSection<String>,
        assignees: ForgeReadSection<[ForgeActor]>,
        milestone: ForgeReadSection<ForgeMilestone?>,
        reviewers: ForgeReadSection<[ForgeReviewer]>,
        linkedIssues: ForgeReadSection<[ForgeLinkedIssue]>,
        mergeability: ForgeReadSection<ForgeMergeability>,
        checks: ForgeReadSection<[ForgeCheck]>,
        timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) throws {
        try Self.validate(
            repository: summary.repository,
            assignees: assignees,
            milestone: milestone,
            reviewers: reviewers,
            linkedIssues: linkedIssues,
            checks: checks,
            timeline: timeline
        )
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.assignees = assignees
        self.milestone = milestone
        self.reviewers = reviewers
        self.linkedIssues = linkedIssues
        self.mergeability = mergeability
        self.checks = checks
        self.timeline = timeline
    }

    private static func validate(
        repository: ForgeRepositoryIdentity,
        assignees: ForgeReadSection<[ForgeActor]>,
        milestone: ForgeReadSection<ForgeMilestone?>,
        reviewers: ForgeReadSection<[ForgeReviewer]>,
        linkedIssues: ForgeReadSection<[ForgeLinkedIssue]>,
        checks: ForgeReadSection<[ForgeCheck]>,
        timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) throws {
        if case let .available(values) = assignees,
           values.contains(where: { $0.id.forge != repository.forge })
        {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(value) = milestone,
           let value,
           value.repository != repository
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        if case let .available(values) = reviewers,
           values.contains(where: { $0.participant.forge != repository.forge })
        {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(values) = linkedIssues,
           values.contains(where: { $0.repository.forge != repository.forge })
        {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(values) = checks,
           values.contains(where: { $0.repository != repository })
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        if case let .available(page) = timeline,
           page.items.contains(where: { $0.repository != repository })
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
    }
}

extension ForgePullRequestDetails: Codable {
    private enum CodingKeys: String, CodingKey {
        case summary
        case bodyMarkdown
        case assignees
        case milestone
        case reviewers
        case linkedIssues
        case mergeability
        case checks
        case timeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            summary: container.decode(ForgePullRequestSummary.self, forKey: .summary),
            bodyMarkdown: container.decode(ForgeReadSection<String>.self, forKey: .bodyMarkdown),
            assignees: container.decode(ForgeReadSection<[ForgeActor]>.self, forKey: .assignees),
            milestone: container.decode(ForgeReadSection<ForgeMilestone?>.self, forKey: .milestone),
            reviewers: container.decode(ForgeReadSection<[ForgeReviewer]>.self, forKey: .reviewers),
            linkedIssues: container.decode(ForgeReadSection<[ForgeLinkedIssue]>.self, forKey: .linkedIssues),
            mergeability: container.decode(ForgeReadSection<ForgeMergeability>.self, forKey: .mergeability),
            checks: container.decode(ForgeReadSection<[ForgeCheck]>.self, forKey: .checks),
            timeline: container.decode(ForgeReadSection<ForgePage<ForgeTimelineItem>>.self, forKey: .timeline)
        )
    }
}

public struct ForgeIssueSummary: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let state: ForgeIssueState
    public let title: String
    public let author: ForgeReadSection<ForgeAuthor>
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let labels: ForgeReadSection<[ForgeLabel]>

    public init(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        state: ForgeIssueState,
        title: String,
        author: ForgeReadSection<ForgeAuthor>,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date? = nil,
        labels: ForgeReadSection<[ForgeLabel]>
    ) throws {
        if case let .available(.actor(value)) = author, value.id.forge != repository.forge {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(values) = labels,
           values.contains(where: { $0.repository != repository })
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        self.repository = repository
        self.number = number
        self.state = state
        self.title = title
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.labels = labels
    }
}

extension ForgeIssueSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case number
        case state
        case title
        case author
        case createdAt
        case updatedAt
        case closedAt
        case labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            number: container.decode(ForgeItemNumber.self, forKey: .number),
            state: container.decode(ForgeIssueState.self, forKey: .state),
            title: container.decode(String.self, forKey: .title),
            author: container.decode(ForgeReadSection<ForgeAuthor>.self, forKey: .author),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            closedAt: container.decodeIfPresent(Date.self, forKey: .closedAt),
            labels: container.decode(ForgeReadSection<[ForgeLabel]>.self, forKey: .labels)
        )
    }
}

public struct ForgeIssueDetails: Hashable, Sendable {
    public let summary: ForgeIssueSummary
    public let bodyMarkdown: ForgeReadSection<String>
    public let assignees: ForgeReadSection<[ForgeActor]>
    public let milestone: ForgeReadSection<ForgeMilestone?>
    public let timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>

    public init(
        summary: ForgeIssueSummary,
        bodyMarkdown: ForgeReadSection<String>,
        assignees: ForgeReadSection<[ForgeActor]>,
        milestone: ForgeReadSection<ForgeMilestone?>,
        timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) throws {
        if case let .available(values) = assignees,
           values.contains(where: { $0.id.forge != summary.repository.forge })
        {
            throw ForgeCollaborationModelError.mismatchedForge
        }
        if case let .available(value) = milestone,
           let value,
           value.repository != summary.repository
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        if case let .available(page) = timeline,
           page.items.contains(where: { $0.repository != summary.repository })
        {
            throw ForgeCollaborationModelError.mismatchedRepository
        }
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.assignees = assignees
        self.milestone = milestone
        self.timeline = timeline
    }
}

extension ForgeIssueDetails: Codable {
    private enum CodingKeys: String, CodingKey {
        case summary
        case bodyMarkdown
        case assignees
        case milestone
        case timeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            summary: container.decode(ForgeIssueSummary.self, forKey: .summary),
            bodyMarkdown: container.decode(ForgeReadSection<String>.self, forKey: .bodyMarkdown),
            assignees: container.decode(ForgeReadSection<[ForgeActor]>.self, forKey: .assignees),
            milestone: container.decode(ForgeReadSection<ForgeMilestone?>.self, forKey: .milestone),
            timeline: container.decode(ForgeReadSection<ForgePage<ForgeTimelineItem>>.self, forKey: .timeline)
        )
    }
}

private extension ForgeReviewParticipant {
    var forge: ForgeIdentity {
        switch self {
        case let .actor(actor): actor.id.forge
        case let .team(team): team.id.forge
        }
    }
}
