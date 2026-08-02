import Foundation

public enum ForgeOverlayActivity: String, Codable, Hashable, Sendable {
    case affectedViewActive
    case otherOpenRepository
    case otherBoundRepository
}

public enum ForgeRefreshReason: String, CaseIterable, Codable, Hashable, Sendable {
    case applicationActivated
    case repositoryOpened
    case localFetchSucceeded
    case localPushSucceeded
    case selectedPullRequestChanged
    case selectedIssueChanged
    case manual
    case networkRestored
    case mutationCompleted
    case scheduledOverlay
    case scheduledAttention
    case unknownOutcomeReconciliation
}

public enum ForgeAttentionPollingPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case frequent
    case balanced
    case conservative
    case manual

    public static let defaultValue = ForgeAttentionPollingPreset.balanced

    public var activeInterval: TimeInterval? {
        switch self {
        case .frequent: 2 * 60
        case .balanced: 5 * 60
        case .conservative: 15 * 60
        case .manual: nil
        }
    }

    public var backgroundInterval: TimeInterval? {
        switch self {
        case .frequent: 5 * 60
        case .balanced: 15 * 60
        case .conservative: 30 * 60
        case .manual: nil
        }
    }
}

public enum ForgeRefreshAuthentication: Codable, Hashable, Sendable {
    case publicAccess
    case credential(ForgeCredentialReference)

    public var cachePartition: ForgeCachePartition {
        switch self {
        case .publicAccess: .publicAccess
        case let .credential(reference): .account(reference.accountID)
        }
    }
}

public enum ForgeRefreshPolicyError: Error, Equatable, LocalizedError, Sendable {
    case mismatchedCredentialForge
    case mismatchedRequestTarget
    case refreshAlreadyInFlight
    case staleRequestSequence
    case invalidRequestSequence
    case invalidGeneration
    case generationExhausted

    public var errorDescription: String? {
        switch self {
        case .mismatchedCredentialForge:
            "The refresh Credential and repository belong to different Forges."
        case .mismatchedRequestTarget:
            "The refresh request does not match the causal refresh target."
        case .refreshAlreadyInFlight:
            "A refresh is already in flight for this target."
        case .staleRequestSequence:
            "The refresh request sequence does not advance the accepted causal boundary."
        case .invalidRequestSequence:
            "The refresh request sequence is invalid."
        case .invalidGeneration:
            "The refresh generation is invalid."
        case .generationExhausted:
            "The refresh generation sequence is exhausted."
        }
    }
}

public struct ForgeRefreshTarget: Codable, Hashable, Sendable {
    public let authentication: ForgeRefreshAuthentication
    public let repository: ForgeRepositoryIdentity
    public let repositoryPartition: ForgeRepositoryPartitionKey

    public init(authentication: ForgeRefreshAuthentication, repository: ForgeRepositoryIdentity) throws {
        do {
            repositoryPartition = try ForgeRepositoryPartitionKey(
                cachePartition: authentication.cachePartition,
                repository: repository
            )
        } catch ForgeCachePolicyError.mismatchedAccountForge {
            throw ForgeRefreshPolicyError.mismatchedCredentialForge
        }
        self.authentication = authentication
        self.repository = repository
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            authentication: container.decode(ForgeRefreshAuthentication.self, forKey: .authentication),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository)
        )
    }

    private enum CodingKeys: CodingKey {
        case authentication
        case repository
    }
}

public struct ForgeRefreshRequestSequence: Codable, Comparable, Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) throws {
        guard value > 0 else { throw ForgeRefreshPolicyError.invalidRequestSequence }
        self.value = value
    }

    public static func < (lhs: ForgeRefreshRequestSequence, rhs: ForgeRefreshRequestSequence) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ForgeRefreshGeneration: Codable, Comparable, Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) throws {
        guard value > 0 else { throw ForgeRefreshPolicyError.invalidGeneration }
        self.value = value
    }

    public static func < (lhs: ForgeRefreshGeneration, rhs: ForgeRefreshGeneration) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ForgeRefreshExecution: Hashable, Sendable {
    public let request: ForgeRefreshRequest
    public let generation: ForgeRefreshGeneration
    public let startedAt: Date

    public init(
        request: ForgeRefreshRequest,
        generation: ForgeRefreshGeneration,
        startedAt: Date
    ) {
        self.request = request
        self.generation = generation
        self.startedAt = startedAt
    }
}

public enum ForgeRefreshRequestDisposition: Equatable, Sendable {
    case readyToStart
    case satisfiedByInFlight(ForgeRefreshGeneration)
    case queuedAfterInFlight
    case retainedStaleSequenceForFollowUp(ForgeRefreshRequestSequence)
}

public enum ForgeRefreshCompletionDisposition<Record: Hashable & Sendable>: Hashable, Sendable {
    case apply(ForgeSnapshotRefreshApplication<Record>)
    case discardStale
}

public struct ForgeCausalRefreshState: Hashable, Sendable {
    public let target: ForgeRefreshTarget
    public private(set) var inFlight: ForgeRefreshExecution?
    public private(set) var pendingRequest: ForgeRefreshRequest?
    public private(set) var highestAcceptedRequestSequence: ForgeRefreshRequestSequence?
    private var latestStartedGenerationValue: UInt64

    public init(
        target: ForgeRefreshTarget,
        latestStartedGeneration: ForgeRefreshGeneration? = nil,
        highestAcceptedRequestSequence: ForgeRefreshRequestSequence? = nil
    ) {
        self.target = target
        inFlight = nil
        pendingRequest = nil
        self.highestAcceptedRequestSequence = highestAcceptedRequestSequence
        latestStartedGenerationValue = latestStartedGeneration?.value ?? 0
    }

    public var latestStartedGeneration: ForgeRefreshGeneration? {
        try? ForgeRefreshGeneration(latestStartedGenerationValue)
    }

    public mutating func start(
        _ request: ForgeRefreshRequest,
        at date: Date
    ) throws -> ForgeRefreshExecution {
        guard request.target == target else {
            throw ForgeRefreshPolicyError.mismatchedRequestTarget
        }
        guard inFlight == nil else {
            throw ForgeRefreshPolicyError.refreshAlreadyInFlight
        }
        let acceptedRequest: ForgeRefreshRequest
        if let pendingRequest {
            guard let combined = pendingRequest.coalesced(with: request) else {
                throw ForgeRefreshPolicyError.mismatchedRequestTarget
            }
            acceptedRequest = combined
        } else {
            if let highestAcceptedRequestSequence,
               request.sequence <= highestAcceptedRequestSequence
            {
                throw ForgeRefreshPolicyError.staleRequestSequence
            }
            acceptedRequest = request
        }
        guard latestStartedGenerationValue < UInt64.max else {
            throw ForgeRefreshPolicyError.generationExhausted
        }
        latestStartedGenerationValue += 1
        let execution = try ForgeRefreshExecution(
            request: acceptedRequest,
            generation: ForgeRefreshGeneration(latestStartedGenerationValue),
            startedAt: date
        )
        inFlight = execution
        pendingRequest = nil
        highestAcceptedRequestSequence = max(
            highestAcceptedRequestSequence ?? acceptedRequest.sequence,
            acceptedRequest.sequence
        )
        return execution
    }

    public mutating func receive(_ request: ForgeRefreshRequest) throws -> ForgeRefreshRequestDisposition {
        guard request.target == target else {
            throw ForgeRefreshPolicyError.mismatchedRequestTarget
        }
        guard let inFlight else {
            guard let highestAcceptedRequestSequence,
                  request.sequence <= highestAcceptedRequestSequence
            else {
                return .readyToStart
            }
            try retainForFollowUp(request, at: highestAcceptedRequestSequence)
            return .retainedStaleSequenceForFollowUp(highestAcceptedRequestSequence)
        }
        if request.sequence <= inFlight.request.sequence,
           inFlight.request.satisfies(request)
        {
            return .satisfiedByInFlight(inFlight.generation)
        }
        if let highestAcceptedRequestSequence,
           request.sequence <= highestAcceptedRequestSequence
        {
            try retainForFollowUp(request, at: highestAcceptedRequestSequence)
            return .retainedStaleSequenceForFollowUp(highestAcceptedRequestSequence)
        }
        try queueForFollowUp(request)
        highestAcceptedRequestSequence = request.sequence
        return .queuedAfterInFlight
    }

    public mutating func complete<Record: Hashable & Sendable>(
        _ execution: ForgeRefreshExecution,
        with outcome: ForgeSnapshotRefreshOutcome<Record>
    ) -> ForgeRefreshCompletionDisposition<Record> {
        guard execution.request.target == target,
              execution.generation == latestStartedGeneration,
              inFlight == execution
        else {
            return .discardStale
        }
        inFlight = nil
        let nextRequest = pendingRequest
        return .apply(
            ForgeSnapshotRefreshApplication(
                result: ForgeSnapshotRefreshResult(
                    generation: execution.generation,
                    outcome: outcome
                ),
                nextRequest: nextRequest
            )
        )
    }

    private mutating func retainForFollowUp(
        _ request: ForgeRefreshRequest,
        at sequence: ForgeRefreshRequestSequence
    ) throws {
        try queueForFollowUp(request.replacingSequence(with: sequence))
    }

    private mutating func queueForFollowUp(_ request: ForgeRefreshRequest) throws {
        if let pendingRequest {
            guard let combined = pendingRequest.coalesced(with: request) else {
                throw ForgeRefreshPolicyError.mismatchedRequestTarget
            }
            self.pendingRequest = combined
        } else {
            pendingRequest = request
        }
    }
}

public struct ForgeRefreshRequest: Hashable, Sendable {
    public let target: ForgeRefreshTarget
    public let reasons: Set<ForgeRefreshReason>
    public let recordKinds: Set<ForgeCacheRecordKind>
    public let sequence: ForgeRefreshRequestSequence
    public let requestedAt: Date

    public init(
        target: ForgeRefreshTarget,
        reasons: Set<ForgeRefreshReason>,
        recordKinds: Set<ForgeCacheRecordKind>,
        sequence: ForgeRefreshRequestSequence,
        requestedAt: Date
    ) {
        self.target = target
        self.reasons = reasons
        self.recordKinds = recordKinds
        self.sequence = sequence
        self.requestedAt = requestedAt
    }

    public func coalesced(with other: ForgeRefreshRequest) -> ForgeRefreshRequest? {
        guard target == other.target else { return nil }
        return ForgeRefreshRequest(
            target: target,
            reasons: reasons.union(other.reasons),
            recordKinds: recordKinds.union(other.recordKinds),
            sequence: max(sequence, other.sequence),
            requestedAt: min(requestedAt, other.requestedAt)
        )
    }

    public func satisfies(_ other: ForgeRefreshRequest) -> Bool {
        target == other.target && recordKinds.isSuperset(of: other.recordKinds)
    }

    fileprivate func replacingSequence(with sequence: ForgeRefreshRequestSequence) -> ForgeRefreshRequest {
        ForgeRefreshRequest(
            target: target,
            reasons: reasons,
            recordKinds: recordKinds,
            sequence: sequence,
            requestedAt: requestedAt
        )
    }
}

public enum ForgeRefreshState: Hashable, Sendable {
    case idle
    case scheduled(ForgeRefreshRequest)
    case refreshing(ForgeRefreshRequest)
    case succeeded(at: Date, completeness: ForgeSnapshotCompleteness)
    case failed(at: Date, retainedStaleSnapshot: Bool)
    case suspendedOffline(ForgeRefreshRequest)
    case suspendedCooldown(ForgeRefreshRequest, until: Date)
    case cancelled
}

public struct ForgeCredentialCooldown: Hashable, Sendable {
    public let credential: ForgeCredentialReference
    public let deadline: Date

    public init(credential: ForgeCredentialReference, deadline: Date) {
        self.credential = credential
        self.deadline = deadline
    }

    public func isActive(at date: Date) -> Bool {
        date < deadline
    }

    public func blocks(_ target: ForgeRefreshTarget, at date: Date) -> Bool {
        guard case let .credential(reference) = target.authentication else { return false }
        return reference == credential && isActive(at: date)
    }
}

public enum ForgeAnonymousRequestDecision: Equatable, Sendable {
    case allowed
    case reserveProtected
    case cooldown(until: Date)
}

public struct ForgeAnonymousRateBudget: Hashable, Sendable {
    public let remainingRequestCount: Int
    public let cooldownDeadline: Date?

    public init(remainingRequestCount: Int, cooldownDeadline: Date? = nil) {
        self.remainingRequestCount = max(0, remainingRequestCount)
        self.cooldownDeadline = cooldownDeadline
    }

    public func decision(plannedRequestCost: Int = 1, at date: Date) -> ForgeAnonymousRequestDecision {
        if let cooldownDeadline, date < cooldownDeadline {
            return .cooldown(until: cooldownDeadline)
        }
        guard plannedRequestCost > 0,
              remainingRequestCount - plannedRequestCost >= ForgePolicyConstants.anonymousReservedRequestCount
        else {
            return .reserveProtected
        }
        return .allowed
    }
}

public enum ForgeRefreshPolicy {
    public static let activeOverlayInterval: TimeInterval = 60
    public static let openRepositoryInterval: TimeInterval = 5 * 60
    public static let boundRepositoryInterval: TimeInterval = 15 * 60

    public static func interval(for activity: ForgeOverlayActivity) -> TimeInterval {
        switch activity {
        case .affectedViewActive: activeOverlayInterval
        case .otherOpenRepository: openRepositoryInterval
        case .otherBoundRepository: boundRepositoryInterval
        }
    }

    public static func mayScheduleAutomatically(authentication: ForgeRefreshAuthentication) -> Bool {
        if case .publicAccess = authentication {
            return false
        }
        return true
    }

    public static func anonymousRequestIsExplicitlyAllowed(for reason: ForgeRefreshReason) -> Bool {
        reason == .repositoryOpened || reason == .manual
    }
}
