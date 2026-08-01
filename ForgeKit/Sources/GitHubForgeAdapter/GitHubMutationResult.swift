import ForgeKit
import Foundation

public struct GitHubMutationAuthorization: Hashable, Sendable {
    public let key: ForgeCapabilityKey
    public let capability: ForgeOperationCapability
    public let explicitConfirmation: ForgeExplicitCapabilityConfirmation?

    public init(
        key: ForgeCapabilityKey,
        capability: ForgeOperationCapability,
        explicitConfirmation: ForgeExplicitCapabilityConfirmation? = nil
    ) throws {
        switch capability {
        case .verified:
            guard explicitConfirmation == nil else {
                throw GitHubMutationError.authorizationMismatch
            }
        case let .unverifiedWrite(attempt):
            guard attempt.key == key,
                  let explicitConfirmation,
                  explicitConfirmation.attempt == attempt
            else {
                throw GitHubMutationError.explicitConfirmationRequired
            }
        case .unavailable:
            throw GitHubMutationError.capabilityUnavailable
        }
        self.key = key
        self.capability = capability
        self.explicitConfirmation = explicitConfirmation
    }
}

public struct GitHubMutationOwnership: Hashable, Sendable {
    public let credential: ForgeCredentialReference
    public let repository: ForgeRepositoryIdentity
    public let operation: ForgeOperation

    public init(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) {
        self.credential = credential
        self.repository = repository
        self.operation = operation
    }
}

public struct GitHubMutationResult<Value: Sendable>: Sendable {
    public let value: Value
    public let response: GitHubResponseMetadata
    public let ownership: GitHubMutationOwnership

    public init(
        value: Value,
        response: GitHubResponseMetadata,
        ownership: GitHubMutationOwnership
    ) {
        self.value = value
        self.response = response
        self.ownership = ownership
    }
}

/// Provider-neutral state consumed by application composition. The adapter
/// owns GitHub response details; views only need to know whether to refresh,
/// present an authoritative message, or wait for the exact session gate.
public enum GitHubMutationUIMapper {
    public static func outcome<Value: Sendable>(
        _ result: Result<GitHubMutationResult<Value>, Error>
    ) -> ForgeMutationPresentationOutcome<Value> {
        switch result {
        case let .success(value):
            return .succeeded(value.value)
        case let .failure(error as GitHubMutationError):
            switch error {
            case let .authoritative(problems, _):
                return .authoritativeFailure(
                    problems.first?.authoritativeMessage ?? "GitHub rejected this operation."
                )
            case .offline:
                return .offline
            case let .cooldown(until):
                return .cooldown(until: until)
            case let .rateLimited(metadata):
                return .cooldown(
                    until: metadata.rateLimit.retryAt
                        ?? metadata.rateLimit.resetAt
                        ?? Date.distantFuture
                )
            case .capabilityUnavailable:
                return .capabilityUnavailable
            case .permissionDenied, .samlAuthorizationRequired,
                 .installationConfigurationRequired:
                return .permissionDenied
            case .authenticationRequired, .authorizationMismatch,
                 .explicitConfirmationRequired, .githubDotComRequired:
                return .authenticationRequired
            case .stalePullRequest, .objectNotFound, .invalidRequest,
                 .malformedResponse, .transportFailure:
                return .stale
            case .outcomeUnknown:
                return .outcomeUnknown
            }
        case .failure:
            return .stale
        }
    }
}

public struct GitHubMutationProblem: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let authoritativeMessage: String
    public let path: [String]
    public let classification: String?

    public init(
        authoritativeMessage: String,
        path: [String] = [],
        classification: String? = nil
    ) {
        self.authoritativeMessage = authoritativeMessage
        self.path = path
        self.classification = classification
    }

    public var description: String {
        "GitHub mutation problem (server message redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public enum GitHubMutationError: Error, Equatable, LocalizedError, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case githubDotComRequired
    case authenticationRequired
    case authorizationMismatch
    case capabilityUnavailable
    case explicitConfirmationRequired
    case invalidRequest
    case objectNotFound
    case stalePullRequest
    case offline
    case cooldown(until: Date)
    case rateLimited(GitHubResponseMetadata)
    case samlAuthorizationRequired(GitHubResponseMetadata)
    case installationConfigurationRequired(GitHubResponseMetadata)
    case permissionDenied(GitHubResponseMetadata)
    case authoritative([GitHubMutationProblem], GitHubResponseMetadata)
    case malformedResponse
    case transportFailure
    case outcomeUnknown(GitHubResponseMetadata?)

    public var errorDescription: String? {
        switch self {
        case .githubDotComRequired:
            "Native mutations require an exact GitHub.com Forge Repository."
        case .authenticationRequired:
            "GitHub authentication is required."
        case .authorizationMismatch:
            "The mutation authorization does not match this Credential, Forge Repository, and operation."
        case .capabilityUnavailable:
            "The current Credential cannot perform this operation."
        case .explicitConfirmationRequired:
            "This Unverified Write requires confirmation for the exact operation."
        case .invalidRequest:
            "The GitHub mutation request is invalid."
        case .objectNotFound:
            "The GitHub object was not found or is unavailable."
        case .stalePullRequest:
            "The Pull Request changed before the operation could be performed."
        case .offline:
            "The GitHub mutation could not start while offline."
        case let .cooldown(until):
            "This GitHub Credential is cooling down until \(until.formatted())."
        case .rateLimited:
            "GitHub rate limited this Credential."
        case .samlAuthorizationRequired:
            "Organization SAML authorization is required."
        case .installationConfigurationRequired:
            "GitHub App repository access configuration is required."
        case .permissionDenied:
            "GitHub denied this operation."
        case let .authoritative(problems, _):
            problems.first?.authoritativeMessage ?? "GitHub rejected this operation."
        case .malformedResponse:
            "GitHub returned a malformed response before the mutation began."
        case .transportFailure:
            "The GitHub preflight request could not be completed."
        case .outcomeUnknown:
            "The mutation outcome is unknown and must be reconciled before retrying."
        }
    }

    public var description: String {
        switch self {
        case .authoritative:
            "GitHub rejected the mutation (server message redacted)."
        default:
            errorDescription ?? "GitHub mutation failed."
        }
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubPullRequestMutationValue: Hashable, Sendable {
    public let id: ForgeObjectID
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let state: ForgePullRequestState
    public let isDraft: Bool
    public let title: String
    public let bodyMarkdown: String
    public let head: ForgeBranchReference
    public let base: ForgeBranchReference
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let mergedAt: Date?

    public init(
        id: ForgeObjectID,
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        state: ForgePullRequestState,
        isDraft: Bool,
        title: String,
        bodyMarkdown: String,
        head: ForgeBranchReference,
        base: ForgeBranchReference,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date?,
        mergedAt: Date?
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.head = head
        self.base = base
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
    }

    public var editableSnapshot: ForgePullRequestEditableSnapshot {
        get throws {
            try ForgePullRequestEditableSnapshot(
                repository: repository,
                number: number,
                title: title,
                bodyMarkdown: bodyMarkdown,
                updatedAt: updatedAt
            )
        }
    }
}

public enum GitHubPullRequestCreationOutcome: Hashable, Sendable {
    case created(GitHubPullRequestMutationValue)
    case existing(GitHubPullRequestMutationValue)
}

public struct GitHubReviewMutationReceipt: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let objectID: ForgeObjectID
    public let displayedHead: ForgeCommitID?
    public let isResolved: Bool?

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        objectID: ForgeObjectID,
        displayedHead: ForgeCommitID? = nil,
        isResolved: Bool? = nil
    ) {
        self.repository = repository
        self.pullRequest = pullRequest
        self.objectID = objectID
        self.displayedHead = displayedHead
        self.isResolved = isResolved
    }
}

public struct GitHubMergeQueueReceipt: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let entryID: ForgeObjectID
    public let action: ForgePullRequestMergeQueueAction

    public init(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        entryID: ForgeObjectID,
        action: ForgePullRequestMergeQueueAction
    ) {
        self.repository = repository
        self.pullRequest = pullRequest
        self.entryID = entryID
        self.action = action
    }
}

public struct GitHubHeadBranchDeletionReceipt: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let branch: ForgeRefName
    public let deletedHead: ForgeCommitID

    public init(
        repository: ForgeRepositoryIdentity,
        branch: ForgeRefName,
        deletedHead: ForgeCommitID
    ) {
        self.repository = repository
        self.branch = branch
        self.deletedHead = deletedHead
    }
}

public enum GitHubForkSyncMergeType: String, Hashable, Sendable {
    case merge
    case fastForward = "fast-forward"
    case none
    case unknown
}

public struct GitHubForkSyncReceipt: Hashable, Sendable {
    public let fork: ForgeRepositoryIdentity
    public let parent: ForgeRepositoryIdentity
    public let branch: ForgeRefName
    public let mergeType: GitHubForkSyncMergeType

    public init(
        fork: ForgeRepositoryIdentity,
        parent: ForgeRepositoryIdentity,
        branch: ForgeRefName,
        mergeType: GitHubForkSyncMergeType
    ) {
        self.fork = fork
        self.parent = parent
        self.branch = branch
        self.mergeType = mergeType
    }
}
