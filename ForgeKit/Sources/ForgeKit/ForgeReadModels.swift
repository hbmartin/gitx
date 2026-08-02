import Foundation

/// Provider-neutral state associated with one commit in the History view.
public struct ForgeHistoryOverlay: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let commit: ForgeCommitID
    public let checkRollup: ForgeReadSection<ForgeCheckRollup>
    public let pullRequests: ForgeReadSection<ForgePage<ForgePullRequestSummary>>

    public init(
        repository: ForgeRepositoryIdentity,
        commit: ForgeCommitID,
        checkRollup: ForgeReadSection<ForgeCheckRollup>,
        pullRequests: ForgeReadSection<ForgePage<ForgePullRequestSummary>>
    ) {
        self.repository = repository
        self.commit = commit
        self.checkRollup = checkRollup
        self.pullRequests = pullRequests
    }
}

/// One details response can independently continue the check and timeline
/// connections. Timeline continuation lives in `details.timeline`; this
/// cursor prevents the check connection from being silently truncated.
public struct ForgePullRequestDetailsPage: Codable, Hashable, Sendable {
    public let details: ForgePullRequestDetails
    public let nextCheckCursor: ForgePageCursor?

    public init(details: ForgePullRequestDetails, nextCheckCursor: ForgePageCursor?) {
        self.details = details
        self.nextCheckCursor = nextCheckCursor
    }
}

public enum ForgeRepositoryItem: Codable, Hashable, Sendable {
    case pullRequest(ForgePullRequestSummary)
    case issue(ForgeIssueSummary)

    public var repository: ForgeRepositoryIdentity {
        switch self {
        case let .pullRequest(value): value.repository
        case let .issue(value): value.repository
        }
    }

    public var destination: ForgeDestination {
        switch self {
        case let .pullRequest(value): .pullRequest(value.repository, value.number)
        case let .issue(value): .issue(value.repository, value.number)
        }
    }
}

public enum ForgeReviewDiffSide: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case right
}

public enum ForgeReviewSubject: String, CaseIterable, Codable, Hashable, Sendable {
    case file
    case line
}

/// The server anchor is preserved verbatim as a provider-neutral value. A
/// consumer may render an unavailable anchor, but must not guess one.
public struct ForgeReviewAnchor: Codable, Hashable, Sendable {
    public let path: ForgeFilePath
    public let subject: ForgeReviewSubject
    public let side: ForgeReviewDiffSide?
    public let startSide: ForgeReviewDiffSide?
    public let startLine: Int?
    public let line: Int?
    public let originalStartLine: Int?
    public let originalLine: Int?

    public init(
        path: ForgeFilePath,
        subject: ForgeReviewSubject,
        side: ForgeReviewDiffSide? = nil,
        startSide: ForgeReviewDiffSide? = nil,
        startLine: Int? = nil,
        line: Int? = nil,
        originalStartLine: Int? = nil,
        originalLine: Int? = nil
    ) {
        self.path = path
        self.subject = subject
        self.side = side
        self.startSide = startSide
        self.startLine = startLine
        self.line = line
        self.originalStartLine = originalStartLine
        self.originalLine = originalLine
    }
}

public struct ForgeReviewComment: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID
    public let bodyMarkdown: String
    public let createdAt: Date
    public let updatedAt: Date
    public let author: ForgeReadSection<ForgeAuthor>
    public let replyToID: ForgeObjectID?
    /// Provider-reported minimization is retained independently from the body
    /// so native clients do not accidentally reveal content GitHub collapsed.
    public let isMinimized: Bool
    public let minimizedReason: String?
    public let reactions: [ForgeReviewReactionSummary]
    /// The immutable server diff context used to validate suggested-change
    /// anchors. Consumers must not treat it as a complete local patch.
    public let diffHunk: String?

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        bodyMarkdown: String,
        createdAt: Date,
        updatedAt: Date,
        author: ForgeReadSection<ForgeAuthor>,
        replyToID: ForgeObjectID? = nil,
        isMinimized: Bool = false,
        minimizedReason: String? = nil,
        reactions: [ForgeReviewReactionSummary] = [],
        diffHunk: String? = nil
    ) {
        self.repository = repository
        self.id = id
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.author = author
        self.replyToID = replyToID
        self.isMinimized = isMinimized
        self.minimizedReason = minimizedReason
        self.reactions = reactions
        self.diffHunk = diffHunk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            id: container.decode(ForgeObjectID.self, forKey: .id),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            author: container.decode(ForgeReadSection<ForgeAuthor>.self, forKey: .author),
            replyToID: container.decodeIfPresent(ForgeObjectID.self, forKey: .replyToID),
            isMinimized: container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false,
            minimizedReason: container.decodeIfPresent(String.self, forKey: .minimizedReason),
            reactions: container.decodeIfPresent(
                [ForgeReviewReactionSummary].self,
                forKey: .reactions
            ) ?? [],
            diffHunk: container.decodeIfPresent(String.self, forKey: .diffHunk)
        )
    }
}

public struct ForgeReviewThread: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let id: ForgeObjectID
    public let isResolved: Bool
    public let isOutdated: Bool
    public let anchor: ForgeReadSection<ForgeReviewAnchor>
    public let comments: ForgeReadSection<ForgePage<ForgeReviewComment>>

    public init(
        repository: ForgeRepositoryIdentity,
        id: ForgeObjectID,
        isResolved: Bool,
        isOutdated: Bool,
        anchor: ForgeReadSection<ForgeReviewAnchor>,
        comments: ForgeReadSection<ForgePage<ForgeReviewComment>>
    ) {
        self.repository = repository
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.anchor = anchor
        self.comments = comments
    }
}

public enum ForgeAttentionActivityKind: String, CaseIterable, Codable, Hashable, Sendable {
    case conversationComment
    case review
    case reviewReply
}

/// Activity retained by the adapter so the Attention policy can derive
/// mentions and replies without importing provider transport models.
public struct ForgeAttentionActivity: Codable, Hashable, Sendable {
    public let id: ForgeObjectID
    public let kind: ForgeAttentionActivityKind
    public let author: ForgeReadSection<ForgeAuthor>
    public let bodyMarkdown: String
    public let occurredAt: Date

    public init(
        id: ForgeObjectID,
        kind: ForgeAttentionActivityKind,
        author: ForgeReadSection<ForgeAuthor>,
        bodyMarkdown: String,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.occurredAt = occurredAt
    }
}

public struct ForgeAttentionCandidate: Codable, Hashable, Sendable {
    public let subjectID: ForgeAttentionSubjectID
    public let item: ForgeRepositoryItem
    public let bodyMarkdown: ForgeReadSection<String>
    public let assignees: ForgeReadSection<[ForgeActor]>
    public let participants: ForgeReadSection<[ForgeActor]>
    public let requestedReviewers: ForgeReadSection<[ForgeReviewParticipant]>
    public let activities: ForgeReadSection<[ForgeAttentionActivity]>
    public let reviewThreads: ForgeReadSection<[ForgeReviewThread]>

    public init(
        subjectID: ForgeAttentionSubjectID,
        item: ForgeRepositoryItem,
        bodyMarkdown: ForgeReadSection<String>,
        assignees: ForgeReadSection<[ForgeActor]>,
        participants: ForgeReadSection<[ForgeActor]>,
        requestedReviewers: ForgeReadSection<[ForgeReviewParticipant]>,
        activities: ForgeReadSection<[ForgeAttentionActivity]>,
        reviewThreads: ForgeReadSection<[ForgeReviewThread]>
    ) {
        self.subjectID = subjectID
        self.item = item
        self.bodyMarkdown = bodyMarkdown
        self.assignees = assignees
        self.participants = participants
        self.requestedReviewers = requestedReviewers
        self.activities = activities
        self.reviewThreads = reviewThreads
    }
}

public struct ForgeAttentionCandidatePage: Codable, Hashable, Sendable {
    public let viewer: ForgeActor
    public let candidates: ForgePage<ForgeAttentionCandidate>

    public init(viewer: ForgeActor, candidates: ForgePage<ForgeAttentionCandidate>) {
        self.viewer = viewer
        self.candidates = candidates
    }
}
