import Foundation

public enum ForgeRepositoryPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case metadata
    case contents
    case pullRequests
    case issues
    case checks
    case commitStatuses
}

public enum ForgePermissionLevel: Int, Codable, Comparable, Hashable, Sendable {
    case unavailable
    case read
    case write

    public static func < (lhs: ForgePermissionLevel, rhs: ForgePermissionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgePermissionAuthority: Codable, Hashable, Sendable {
    case known(ForgePermissionLevel)
    case unknown
}

/// Live authorization evidence is deliberately non-Codable. Cached Forge
/// snapshots use separate read models and cannot be decoded into a value that
/// authorizes a write.
public enum ForgeAuthorizationEvidenceFreshness: String, Hashable, Sendable {
    case current
    case cached
    case stale
}

/// A live credential-store observation, deliberately excluded from archives.
public enum ForgeCredentialAvailability: String, Hashable, Sendable {
    case available
    case unavailable
}

public struct ForgePermissionGrant: Codable, Hashable, Sendable {
    public let permission: ForgeRepositoryPermission
    public let authority: ForgePermissionAuthority

    public init(permission: ForgeRepositoryPermission, authority: ForgePermissionAuthority) {
        self.permission = permission
        self.authority = authority
    }
}

public enum ForgeCapabilityModelError: Error, Equatable, LocalizedError, Sendable {
    case duplicatePermission(ForgeRepositoryPermission)

    public var errorDescription: String? {
        switch self {
        case let .duplicatePermission(permission):
            "Permission evidence contains more than one \(permission.rawValue) entry."
        }
    }
}

public struct ForgePermissionEvidence: Hashable, Sendable {
    public let credential: ForgeCredentialReference
    public let repository: ForgeRepositoryIdentity
    public let freshness: ForgeAuthorizationEvidenceFreshness
    private let grants: [ForgePermissionGrant]

    public init(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        freshness: ForgeAuthorizationEvidenceFreshness,
        grants: [ForgePermissionGrant]
    ) throws {
        var seen: Set<ForgeRepositoryPermission> = []
        for grant in grants where !seen.insert(grant.permission).inserted {
            throw ForgeCapabilityModelError.duplicatePermission(grant.permission)
        }
        self.credential = credential
        self.repository = repository
        self.freshness = freshness
        self.grants = grants.sorted { $0.permission.rawValue < $1.permission.rawValue }
    }

    public func authority(for permission: ForgeRepositoryPermission) -> ForgePermissionAuthority {
        grants.first { $0.permission == permission }?.authority ?? .unknown
    }
}

public struct ForgePermissionEnvelope: Codable, Hashable, Sendable {
    public let grants: [ForgePermissionGrant]

    public init(grants: [ForgePermissionGrant]) throws {
        var seen: Set<ForgeRepositoryPermission> = []
        for grant in grants where !seen.insert(grant.permission).inserted {
            throw ForgeCapabilityModelError.duplicatePermission(grant.permission)
        }
        self.grants = grants.sorted { $0.permission.rawValue < $1.permission.rawValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(grants: container.decode([ForgePermissionGrant].self, forKey: .grants))
    }

    /// The complete, predictable permission contract requested from the first
    /// authenticated GitHub App release through Milestone 3.
    public static let milestone3 = try! ForgePermissionEnvelope(grants: [
        ForgePermissionGrant(permission: .metadata, authority: .known(.read)),
        ForgePermissionGrant(permission: .contents, authority: .known(.write)),
        ForgePermissionGrant(permission: .pullRequests, authority: .known(.write)),
        ForgePermissionGrant(permission: .issues, authority: .known(.write)),
        ForgePermissionGrant(permission: .checks, authority: .known(.read)),
        ForgePermissionGrant(permission: .commitStatuses, authority: .known(.read)),
    ])
}

public enum ForgeRepositoryRole: Int, Codable, Comparable, Hashable, Sendable {
    case none
    case read
    case triage
    case write
    case maintain
    case admin

    public static func < (lhs: ForgeRepositoryRole, rhs: ForgeRepositoryRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeRepositoryRoleEvidence: Codable, Hashable, Sendable {
    case known(ForgeRepositoryRole)
    case unknown
}

public enum ForgeRepositoryAccessStatus: String, Codable, Hashable, Sendable {
    case granted
    case unknown
    case denied
    case samlAuthorizationRequired
    case installationConfigurationRequired
}

public struct ForgeRepositoryAccessEvidence: Hashable, Sendable {
    public let credential: ForgeCredentialReference
    public let repository: ForgeRepositoryIdentity
    public let freshness: ForgeAuthorizationEvidenceFreshness
    public let status: ForgeRepositoryAccessStatus
    public let role: ForgeRepositoryRoleEvidence
    public let restrictedOperations: Set<ForgeOperation>

    public init(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        freshness: ForgeAuthorizationEvidenceFreshness,
        status: ForgeRepositoryAccessStatus,
        role: ForgeRepositoryRoleEvidence,
        restrictedOperations: Set<ForgeOperation> = []
    ) {
        self.credential = credential
        self.repository = repository
        self.freshness = freshness
        self.status = status
        self.role = role
        self.restrictedOperations = restrictedOperations
    }
}

public struct ForgePermissionRequirement: Codable, Hashable, Sendable {
    public let permission: ForgeRepositoryPermission
    public let level: ForgePermissionLevel

    public init(permission: ForgeRepositoryPermission, level: ForgePermissionLevel) {
        self.permission = permission
        self.level = level
    }
}

public enum ForgeOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case readRepositoryMetadata
    case listCloneRepositories
    case readRepositoryContents
    case readPullRequests
    case readIssues
    case readChecks
    case readCommitStatuses
    case createPullRequest
    case editPullRequest
    case syncFork
    case publishInlineReviewComment
    case replyToReviewThread
    case resolveReviewThread
    case unresolveReviewThread
    case submitApproveReview
    case submitCommentReview
    case submitRequestChangesReview
    case markPullRequestReady
    case convertPullRequestToDraft
    case closePullRequest
    case reopenPullRequest
    case updatePullRequestBranch
    case mergePullRequest
    case deleteHeadBranch
    case enterMergeQueue
    case leaveMergeQueue

    public var isWrite: Bool {
        switch self {
        case .readRepositoryMetadata, .listCloneRepositories, .readRepositoryContents,
             .readPullRequests, .readIssues, .readChecks, .readCommitStatuses:
            false
        default:
            true
        }
    }

    public var permissionRequirements: [ForgePermissionRequirement] {
        switch self {
        case .readRepositoryMetadata, .listCloneRepositories:
            [ForgePermissionRequirement(permission: .metadata, level: .read)]
        case .readRepositoryContents:
            [ForgePermissionRequirement(permission: .contents, level: .read)]
        case .readPullRequests:
            [ForgePermissionRequirement(permission: .pullRequests, level: .read)]
        case .readIssues:
            [ForgePermissionRequirement(permission: .issues, level: .read)]
        case .readChecks:
            [ForgePermissionRequirement(permission: .checks, level: .read)]
        case .readCommitStatuses:
            [ForgePermissionRequirement(permission: .commitStatuses, level: .read)]
        case .syncFork, .deleteHeadBranch:
            [ForgePermissionRequirement(permission: .contents, level: .write)]
        case .updatePullRequestBranch, .mergePullRequest:
            [
                ForgePermissionRequirement(permission: .contents, level: .write),
                ForgePermissionRequirement(permission: .pullRequests, level: .write),
            ]
        default:
            [ForgePermissionRequirement(permission: .pullRequests, level: .write)]
        }
    }

    public var minimumRole: ForgeRepositoryRole {
        switch self {
        case .syncFork, .updatePullRequestBranch, .mergePullRequest, .deleteHeadBranch,
             .enterMergeQueue, .leaveMergeQueue:
            .write
        default:
            .read
        }
    }
}

public struct ForgeCapabilityKey: Codable, Hashable, Sendable {
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

public enum ForgeCapabilityUnavailableReason: Codable, Hashable, Sendable {
    case noCurrentCredential
    case mismatchedForge
    case unsupportedProviderOperation
    case credentialUnavailable
    case credentialExpired
    case mismatchedCredentialEvidence
    case mismatchedRepositoryEvidence
    case missingPermission(ForgeRepositoryPermission)
    case repositoryAccessDenied
    case samlAuthorizationRequired
    case installationConfigurationRequired
    case inadequateRepositoryRole(required: ForgeRepositoryRole, actual: ForgeRepositoryRole)
    case authorizationEvidenceUnavailable
    case authorizationEvidenceNotCurrent
    case knownOperationRestriction
}

public enum ForgeCapabilityVerification: String, Codable, Hashable, Sendable {
    case knownAuthority
    case successfulConfirmedOperation
}

public struct ForgeUnverifiedWriteAttempt: Hashable, Sendable {
    public let key: ForgeCapabilityKey
}

public struct ForgeExplicitCapabilityConfirmation: Hashable, Sendable {
    public let attempt: ForgeUnverifiedWriteAttempt
    public let identifier: UUID

    public init(attempt: ForgeUnverifiedWriteAttempt, identifier: UUID = UUID()) {
        self.attempt = attempt
        self.identifier = identifier
    }
}

public enum ForgeOperationCapability: Hashable, Sendable {
    case verified(ForgeCapabilityVerification)
    case unverifiedWrite(ForgeUnverifiedWriteAttempt)
    case unavailable(ForgeCapabilityUnavailableReason)
}

public enum ForgeCapabilityAttemptOutcome: String, Codable, Hashable, Sendable {
    case success
    case authorizationDenied
    case nonAuthorizationFailure
    case cancelled
    case unknownOutcome
}

public struct ForgeCapabilityPromotionLedger: Hashable, Sendable {
    private var promotedKeys: Set<ForgeCapabilityKey>

    public init() {
        promotedKeys = []
    }

    public func contains(_ key: ForgeCapabilityKey) -> Bool {
        promotedKeys.contains(key)
    }

    public mutating func record(
        _ outcome: ForgeCapabilityAttemptOutcome,
        for confirmation: ForgeExplicitCapabilityConfirmation
    ) {
        let key = confirmation.attempt.key
        switch outcome {
        case .success:
            promotedKeys.insert(key)
        case .authorizationDenied:
            promotedKeys.remove(key)
        case .nonAuthorizationFailure, .cancelled, .unknownOutcome:
            break
        }
    }

    public mutating func recordAuthoritativeDenial(for key: ForgeCapabilityKey) {
        promotedKeys.remove(key)
    }

    public mutating func invalidate(credential: ForgeCredentialReference) {
        promotedKeys = promotedKeys.filter { $0.credential != credential }
    }

    public mutating func retainOnlyCurrentCredential(for account: ForgeAccount) {
        promotedKeys = promotedKeys.filter {
            $0.credential.accountID != account.id || $0.credential == account.currentCredential.reference
        }
    }
}

public enum ForgeCapabilityEvaluator {
    public static func capability(
        account: ForgeAccount?,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        operationSupported: Bool,
        credentialAvailability: ForgeCredentialAvailability,
        now: Date,
        permissionEvidence: ForgePermissionEvidence,
        accessEvidence: ForgeRepositoryAccessEvidence,
        promotions: ForgeCapabilityPromotionLedger
    ) -> ForgeOperationCapability {
        guard let account else {
            return .unavailable(.noCurrentCredential)
        }
        let credential = account.currentCredential.reference
        guard account.id.forge == repository.forge else {
            return .unavailable(.mismatchedForge)
        }
        guard operationSupported else {
            return .unavailable(.unsupportedProviderOperation)
        }
        guard credentialAvailability == .available else {
            return .unavailable(.credentialUnavailable)
        }
        if let expiresAt = account.currentCredential.expiresAt, expiresAt <= now {
            return .unavailable(.credentialExpired)
        }
        guard permissionEvidence.credential == credential,
              accessEvidence.credential == credential
        else {
            return .unavailable(.mismatchedCredentialEvidence)
        }
        guard permissionEvidence.repository == repository,
              accessEvidence.repository == repository
        else {
            return .unavailable(.mismatchedRepositoryEvidence)
        }

        switch accessEvidence.status {
        case .denied:
            return .unavailable(.repositoryAccessDenied)
        case .samlAuthorizationRequired:
            return .unavailable(.samlAuthorizationRequired)
        case .installationConfigurationRequired:
            return .unavailable(.installationConfigurationRequired)
        case .granted, .unknown:
            break
        }
        guard !accessEvidence.restrictedOperations.contains(operation) else {
            return .unavailable(.knownOperationRestriction)
        }

        if case let .known(role) = accessEvidence.role, role < operation.minimumRole {
            return .unavailable(.inadequateRepositoryRole(required: operation.minimumRole, actual: role))
        }

        var hasUnknownRequiredPermission = false
        for requirement in operation.permissionRequirements {
            switch permissionEvidence.authority(for: requirement.permission) {
            case let .known(level) where level < requirement.level:
                return .unavailable(.missingPermission(requirement.permission))
            case .known:
                break
            case .unknown:
                hasUnknownRequiredPermission = true
            }
        }

        let key = ForgeCapabilityKey(
            credential: credential,
            repository: repository,
            operation: operation
        )
        if operation.isWrite,
           permissionEvidence.freshness != .current || accessEvidence.freshness != .current
        {
            return .unavailable(.authorizationEvidenceNotCurrent)
        }
        if promotions.contains(key) {
            return .verified(.successfulConfirmedOperation)
        }

        if !hasUnknownRequiredPermission,
           accessEvidence.status == .granted,
           case let .known(role) = accessEvidence.role,
           role >= operation.minimumRole
        {
            return .verified(.knownAuthority)
        }

        if operation.isWrite,
           account.currentCredential.source == .fineGrainedPersonalAccessToken,
           hasUnknownRequiredPermission
        {
            return .unverifiedWrite(ForgeUnverifiedWriteAttempt(key: key))
        }
        return .unavailable(.authorizationEvidenceUnavailable)
    }
}
