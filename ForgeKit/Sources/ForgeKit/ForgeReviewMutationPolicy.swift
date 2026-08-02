import Foundation

public enum ForgeReviewMutationError: Error, Equatable, LocalizedError, Sendable {
    case invalidBody
    case invalidContext
    case mismatchedForge
    case mismatchedRepository
    case mismatchedPullRequest
    case displayedHeadChanged
    case truncatedAnchor
    case anchorUnavailable
    case ambiguousAnchor
    case invalidTransition
    case undoExpired
    case checkedOutHeadRequired
    case uncommittedTargetFile
    case contextMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidBody: "The review body must contain printable text."
        case .invalidContext: "The review context is invalid."
        case .mismatchedForge: "The review value belongs to another Forge."
        case .mismatchedRepository: "The review value belongs to another Forge Repository."
        case .mismatchedPullRequest: "The review value belongs to another Pull Request."
        case .displayedHeadChanged: "The displayed Pull Request head changed."
        case .truncatedAnchor: "A truncated review anchor cannot be published."
        case .anchorUnavailable: "The review anchor is unavailable."
        case .ambiguousAnchor: "The review anchor has more than one possible location."
        case .invalidTransition: "The review mutation transition is invalid."
        case .undoExpired: "The review-thread Undo window expired."
        case .checkedOutHeadRequired: "The exact Pull Request head must be checked out."
        case .uncommittedTargetFile: "The suggested-change target has uncommitted edits."
        case .contextMismatch: "The suggested-change context does not match exactly once."
        }
    }
}

public struct ForgeReviewContext: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let displayedHead: ForgeCommitID
    public let path: ForgeFilePath
    public let lines: [String]
    public let isTruncated: Bool

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID,
        path: ForgeFilePath,
        lines: [String],
        isTruncated: Bool = false
    ) throws {
        guard !lines.isEmpty, lines.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw ForgeReviewMutationError.invalidContext
        }
        self.repository = repository
        self.pullRequest = pullRequest
        self.displayedHead = displayedHead
        self.path = path
        self.lines = lines
        self.isTruncated = isTruncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            displayedHead: container.decode(ForgeCommitID.self, forKey: .displayedHead),
            path: container.decode(ForgeFilePath.self, forKey: .path),
            lines: container.decode([String].self, forKey: .lines),
            isTruncated: container.decode(Bool.self, forKey: .isTruncated)
        )
    }
}

public struct ForgeReviewReanchorCandidate: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let displayedHead: ForgeCommitID
    public let anchor: ForgeReviewAnchor
    public let contextLines: [String]

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID,
        anchor: ForgeReviewAnchor,
        contextLines: [String]
    ) throws {
        guard !contextLines.isEmpty else {
            throw ForgeReviewMutationError.invalidContext
        }
        guard contextLines.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw ForgeReviewMutationError.invalidContext
        }
        self.repository = repository
        self.pullRequest = pullRequest
        self.displayedHead = displayedHead
        self.anchor = anchor
        self.contextLines = contextLines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            displayedHead: container.decode(ForgeCommitID.self, forKey: .displayedHead),
            anchor: container.decode(ForgeReviewAnchor.self, forKey: .anchor),
            contextLines: container.decode([String].self, forKey: .contextLines)
        )
    }
}

public enum ForgeReviewReanchorDecision: Hashable, Sendable {
    case unchanged
    case requiresConfirmation(ForgeReviewReanchorConfirmation)
    case unavailable(ForgeReviewMutationError)
}

/// An opaque, fully validated handoff between reanchor discovery and the user
/// confirmation action. Publication can only be rebuilt from identities and
/// context that the policy matched exactly once.
public struct ForgeReviewReanchorConfirmation: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let previousHead: ForgeCommitID
    public let currentHead: ForgeCommitID
    public let anchor: ForgeReviewAnchor

    fileprivate init(
        original: ForgeReviewContext,
        currentHead: ForgeCommitID,
        anchor: ForgeReviewAnchor
    ) {
        repository = original.repository
        pullRequest = original.pullRequest
        previousHead = original.displayedHead
        self.currentHead = currentHead
        self.anchor = anchor
    }

    public func publication(
        replacing original: ForgeInlineReviewPublication
    ) throws -> ForgeInlineReviewPublication {
        guard original.repository == repository,
              original.pullRequest == pullRequest,
              original.displayedHead == previousHead
        else {
            throw ForgeReviewMutationError.contextMismatch
        }
        return try ForgeInlineReviewPublication(
            accountID: original.accountID,
            repository: repository,
            pullRequest: pullRequest,
            displayedHead: currentHead,
            anchor: anchor,
            bodyMarkdown: original.bodyMarkdown
        )
    }
}

public enum ForgeReviewReanchorPolicy {
    public static func decision(
        original: ForgeReviewContext,
        currentHead: ForgeCommitID,
        candidates: [ForgeReviewReanchorCandidate]
    ) -> ForgeReviewReanchorDecision {
        if original.displayedHead == currentHead {
            return .unchanged
        }
        if original.isTruncated {
            return .unavailable(.truncatedAnchor)
        }
        let matches = candidates.filter {
            $0.repository == original.repository
                && $0.pullRequest == original.pullRequest
                && $0.displayedHead == currentHead
                && $0.anchor.path == original.path
                && $0.contextLines == original.lines
        }
        switch matches.count {
        case 0: return .unavailable(.anchorUnavailable)
        case 1:
            return .requiresConfirmation(ForgeReviewReanchorConfirmation(
                original: original,
                currentHead: currentHead,
                anchor: matches[0].anchor
            ))
        default: return .unavailable(.ambiguousAnchor)
        }
    }
}

public struct ForgeInlineReviewPublication: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let displayedHead: ForgeCommitID
    public let anchor: ForgeReviewAnchor
    public let bodyMarkdown: String

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID,
        anchor: ForgeReviewAnchor,
        bodyMarkdown: String
    ) throws {
        guard accountID.forge == repository.forge else { throw ForgeReviewMutationError.mismatchedForge }
        guard ForgePathComponent.isNonemptyPrintable(bodyMarkdown) else { throw ForgeReviewMutationError.invalidBody }
        self.accountID = accountID
        self.repository = repository
        self.pullRequest = pullRequest
        self.displayedHead = displayedHead
        self.anchor = anchor
        self.bodyMarkdown = bodyMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            displayedHead: container.decode(ForgeCommitID.self, forKey: .displayedHead),
            anchor: container.decode(ForgeReviewAnchor.self, forKey: .anchor),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown)
        )
    }

    /// Inline publications are individual immediate requests. There is no
    /// provider-neutral pending-comment collection or submit-later state.
    public func validating(currentHead: ForgeCommitID) throws -> Self {
        guard currentHead == displayedHead else { throw ForgeReviewMutationError.displayedHeadChanged }
        return self
    }
}

public struct ForgeReviewThreadReplyPublication: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let threadID: ForgeObjectID
    public let bodyMarkdown: String

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        threadID: ForgeObjectID,
        bodyMarkdown: String
    ) throws {
        guard accountID.forge == repository.forge, threadID.forge == repository.forge else {
            throw ForgeReviewMutationError.mismatchedForge
        }
        guard ForgePathComponent.isNonemptyPrintable(bodyMarkdown) else {
            throw ForgeReviewMutationError.invalidBody
        }
        self.accountID = accountID
        self.repository = repository
        self.pullRequest = pullRequest
        self.threadID = threadID
        self.bodyMarkdown = bodyMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            threadID: container.decode(ForgeObjectID.self, forKey: .threadID),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown)
        )
    }
}

public enum ForgeReviewCommentVisibility: Codable, Hashable, Sendable {
    case ordinary
    case minimized(reason: String)
    case deleted
    case unavailable
}

public enum ForgeReviewThreadExpansion: String, Codable, Hashable, Sendable {
    case expanded
    case collapsed
}

public enum ForgeReviewReactionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case thumbsUp
    case thumbsDown
    case laugh
    case hooray
    case confused
    case heart
    case rocket
    case eyes
}

public struct ForgeReviewReactionSummary: Codable, Hashable, Sendable {
    public let kind: ForgeReviewReactionKind
    public let count: Int
    public let viewerReacted: Bool

    public init(kind: ForgeReviewReactionKind, count: Int, viewerReacted: Bool) throws {
        guard count >= 0 else { throw ForgeReviewMutationError.invalidContext }
        self.kind = kind
        self.count = count
        self.viewerReacted = viewerReacted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeReviewReactionKind.self, forKey: .kind),
            count: container.decode(Int.self, forKey: .count),
            viewerReacted: container.decode(Bool.self, forKey: .viewerReacted)
        )
    }
}

public struct ForgeReviewThreadPresentation: Codable, Hashable, Sendable {
    public let thread: ForgeReviewThread
    public let expansion: ForgeReviewThreadExpansion
    public let commentVisibility: [ForgeObjectID: ForgeReviewCommentVisibility]
    public let commentReactions: [ForgeObjectID: [ForgeReviewReactionSummary]]

    public init(
        thread: ForgeReviewThread,
        expansion: ForgeReviewThreadExpansion = .expanded,
        commentVisibility: [ForgeObjectID: ForgeReviewCommentVisibility],
        commentReactions: [ForgeObjectID: [ForgeReviewReactionSummary]] = [:]
    ) throws {
        let commentIDs = Set(commentVisibility.keys).union(commentReactions.keys)
        guard commentIDs.allSatisfy({ $0.forge == thread.repository.forge }) else {
            throw ForgeReviewMutationError.mismatchedForge
        }
        guard commentReactions.values.allSatisfy({ summaries in
            Set(summaries.map(\.kind)).count == summaries.count
        }) else {
            throw ForgeReviewMutationError.invalidContext
        }
        self.thread = thread
        self.expansion = expansion
        self.commentVisibility = commentVisibility
        self.commentReactions = commentReactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            thread: container.decode(ForgeReviewThread.self, forKey: .thread),
            expansion: container.decode(ForgeReviewThreadExpansion.self, forKey: .expansion),
            commentVisibility: container.decode([ForgeObjectID: ForgeReviewCommentVisibility].self, forKey: .commentVisibility),
            commentReactions: container.decode([ForgeObjectID: [ForgeReviewReactionSummary]].self, forKey: .commentReactions)
        )
    }

    public var remainsVisiblyOutdated: Bool {
        thread.isOutdated
    }
}

public enum ForgeFormalReviewKind: String, CaseIterable, Codable, Hashable, Sendable {
    case approve
    case comment
    case requestChanges
}

public struct ForgeFormalReviewSubmission: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let displayedHead: ForgeCommitID
    public let kind: ForgeFormalReviewKind
    public let bodyMarkdown: String

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID,
        kind: ForgeFormalReviewKind,
        bodyMarkdown: String
    ) throws {
        guard accountID.forge == repository.forge else { throw ForgeReviewMutationError.mismatchedForge }
        if kind == .requestChanges, !ForgePathComponent.isNonemptyPrintable(bodyMarkdown) {
            throw ForgeReviewMutationError.invalidBody
        }
        self.accountID = accountID
        self.repository = repository
        self.pullRequest = pullRequest
        self.displayedHead = displayedHead
        self.kind = kind
        self.bodyMarkdown = bodyMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(ForgeAccountID.self, forKey: .accountID),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            displayedHead: container.decode(ForgeCommitID.self, forKey: .displayedHead),
            kind: container.decode(ForgeFormalReviewKind.self, forKey: .kind),
            bodyMarkdown: container.decode(String.self, forKey: .bodyMarkdown)
        )
    }

    public func validating(currentHead: ForgeCommitID) throws -> Self {
        guard displayedHead == currentHead else { throw ForgeReviewMutationError.displayedHeadChanged }
        return self
    }
}

public enum ForgeReviewThreadResolutionMutation: String, Codable, Hashable, Sendable {
    case resolve
    case unresolve

    public var opposite: Self {
        self == .resolve ? .unresolve : .resolve
    }
}

public enum ForgeReviewThreadResolutionState: Hashable, Sendable {
    case confirmed(isResolved: Bool)
    case optimistic(
        mutation: ForgeReviewThreadResolutionMutation,
        priorValue: Bool,
        undoDeadline: Date
    )
    case unknownOutcome(lastKnownValue: Bool)

    public func applying(_ event: ForgeReviewThreadResolutionEvent) throws -> Self {
        switch (self, event) {
        case let (.confirmed(isResolved), .begin(mutation, now, undoInterval)):
            guard mutation == (isResolved ? .unresolve : .resolve), undoInterval > 0 else {
                throw ForgeReviewMutationError.invalidTransition
            }
            return .optimistic(
                mutation: mutation,
                priorValue: isResolved,
                undoDeadline: now.addingTimeInterval(undoInterval)
            )
        case let (.optimistic(mutation, priorValue, deadline), .undo(now)):
            guard now <= deadline else { throw ForgeReviewMutationError.undoExpired }
            return .optimistic(
                mutation: mutation.opposite,
                priorValue: !priorValue,
                undoDeadline: deadline
            )
        case let (.optimistic(mutation, _, _), .succeeded):
            return .confirmed(isResolved: mutation == .resolve)
        case let (.optimistic(_, priorValue, _), .failed):
            return .confirmed(isResolved: priorValue)
        case let (.optimistic(_, priorValue, _), .outcomeUnknown):
            return .unknownOutcome(lastKnownValue: priorValue)
        case let (.unknownOutcome, .reconciled(isResolved)),
             let (.confirmed, .reconciled(isResolved)):
            return .confirmed(isResolved: isResolved)
        default:
            throw ForgeReviewMutationError.invalidTransition
        }
    }
}

public enum ForgeReviewThreadResolutionEvent: Hashable, Sendable {
    case begin(ForgeReviewThreadResolutionMutation, now: Date, undoInterval: TimeInterval)
    case undo(now: Date)
    case succeeded
    case failed
    case outcomeUnknown
    case reconciled(isResolved: Bool)
}

public struct ForgeSuggestedChange: Codable, Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let displayedHead: ForgeCommitID
    public let path: ForgeFilePath
    public let originalText: String
    public let replacementText: String
    public let isTruncated: Bool

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        displayedHead: ForgeCommitID,
        path: ForgeFilePath,
        originalText: String,
        replacementText: String,
        isTruncated: Bool = false
    ) throws {
        guard !originalText.isEmpty else { throw ForgeReviewMutationError.invalidContext }
        self.repository = repository
        self.pullRequest = pullRequest
        self.displayedHead = displayedHead
        self.path = path
        self.originalText = originalText
        self.replacementText = replacementText
        self.isTruncated = isTruncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            pullRequest: container.decode(ForgeItemNumber.self, forKey: .pullRequest),
            displayedHead: container.decode(ForgeCommitID.self, forKey: .displayedHead),
            path: container.decode(ForgeFilePath.self, forKey: .path),
            originalText: container.decode(String.self, forKey: .originalText),
            replacementText: container.decode(String.self, forKey: .replacementText),
            isTruncated: container.decode(Bool.self, forKey: .isTruncated)
        )
    }
}

public enum ForgeSuggestedChangeDecision: Hashable, Sendable {
    case apply(updatedContents: String)
    case unavailable(ForgeReviewMutationError)
}

public enum ForgeSuggestedChangePolicy {
    public static func decision(
        change: ForgeSuggestedChange,
        checkedOutHead: ForgeCommitID?,
        filesWithUncommittedEdits: Set<ForgeFilePath>,
        currentContents: String
    ) -> ForgeSuggestedChangeDecision {
        guard checkedOutHead == change.displayedHead else {
            return .unavailable(.checkedOutHeadRequired)
        }
        guard !filesWithUncommittedEdits.contains(change.path) else {
            return .unavailable(.uncommittedTargetFile)
        }
        guard !change.isTruncated else { return .unavailable(.truncatedAnchor) }
        let ranges = currentContents.ranges(of: change.originalText)
        guard ranges.count == 1, let range = ranges.first else {
            return .unavailable(ranges.isEmpty ? .contextMismatch : .ambiguousAnchor)
        }
        return .apply(updatedContents: currentContents.replacingCharacters(in: range, with: change.replacementText))
    }
}

private extension String {
    func ranges(of search: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex, let range = range(of: search, range: cursor ..< endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
