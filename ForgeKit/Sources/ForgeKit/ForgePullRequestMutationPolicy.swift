import Foundation

public enum ForgePullRequestMutationError: Error, Equatable, LocalizedError, Sendable {
    case mismatchedForge
    case mismatchedRepository
    case invalidMutation
    case invalidMessage
    case staleConfirmation
    case invalidTransition

    public var errorDescription: String? {
        switch self {
        case .mismatchedForge: "The mutation belongs to another Forge."
        case .mismatchedRepository: "The mutation belongs to another Forge Repository."
        case .invalidMutation: "The Pull Request mutation is invalid."
        case .invalidMessage: "The merge title or message is invalid."
        case .staleConfirmation: "The Pull Request changed after confirmation."
        case .invalidTransition: "The mutation state transition is invalid."
        }
    }
}

public enum ForgeMutationEnvironment: Hashable, Sendable {
    case available
    case offline
    case rateLimited(until: Date)
}

public enum ForgePullRequestMutationUnavailableReason: Hashable, Sendable {
    case offline
    case rateLimited(until: Date)
    case capabilityUnavailable(ForgeOperation)
    case pullRequestNotOpen
    case pullRequestIsDraft
    case pullRequestIsReady
    case pullRequestNotClosed
    case pullRequestAlreadyMerged
    case updateBranchUnavailable
    case viewerCannotMerge
    case mergeMethodDisabled
    case mergeQueueAlreadyEntered
    case mergeQueueNotEntered
    case branchDeletionUnavailable
    case forkHeadBranch
    case defaultBranch
    case protectedBranch
    case checkedOutBranch
}

public enum ForgePullRequestMutationDecision<Value: Hashable & Sendable>: Hashable, Sendable {
    case available(Value)
    case unavailable(ForgePullRequestMutationUnavailableReason)
}

public struct ForgePullRequestMutationContext: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let state: ForgePullRequestState
    public let isDraft: Bool
    public let head: ForgeBranchReference
    public let base: ForgeBranchReference
    public let updatedAt: Date
    public let allowedOperations: Set<ForgeOperation>
    public let environment: ForgeMutationEnvironment

    public init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        state: ForgePullRequestState,
        isDraft: Bool,
        head: ForgeBranchReference,
        base: ForgeBranchReference,
        updatedAt: Date,
        allowedOperations: Set<ForgeOperation>,
        environment: ForgeMutationEnvironment = .available
    ) throws {
        guard accountID.forge == repository.forge,
              head.repository.forge == repository.forge
        else {
            throw ForgePullRequestMutationError.mismatchedForge
        }
        guard base.repository == repository else {
            throw ForgePullRequestMutationError.mismatchedRepository
        }
        self.accountID = accountID
        self.repository = repository
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.head = head
        self.base = base
        self.updatedAt = updatedAt
        self.allowedOperations = allowedOperations
        self.environment = environment
    }
}

public enum ForgePullRequestLifecycleAction: String, CaseIterable, Hashable, Sendable {
    case markReady
    case convertToDraft
    case close
    case reopen
    case updateBranch

    public var operation: ForgeOperation {
        switch self {
        case .markReady: .markPullRequestReady
        case .convertToDraft: .convertPullRequestToDraft
        case .close: .closePullRequest
        case .reopen: .reopenPullRequest
        case .updateBranch: .updatePullRequestBranch
        }
    }
}

public struct ForgePullRequestLifecycleRequest: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let action: ForgePullRequestLifecycleAction
    public let expectedHead: ForgeCommitID

    public init(context: ForgePullRequestMutationContext, action: ForgePullRequestLifecycleAction) {
        accountID = context.accountID
        repository = context.repository
        number = context.number
        self.action = action
        expectedHead = context.head.commit
    }
}

public enum ForgePullRequestLifecyclePolicy {
    public static func decision(
        context: ForgePullRequestMutationContext,
        action: ForgePullRequestLifecycleAction,
        canUpdateBranch: Bool = false
    ) -> ForgePullRequestMutationDecision<ForgePullRequestLifecycleRequest> {
        if let unavailable = environmentOrCapability(context: context, operation: action.operation) {
            return .unavailable(unavailable)
        }
        switch action {
        case .markReady:
            guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
            guard context.isDraft else { return .unavailable(.pullRequestIsReady) }
        case .convertToDraft:
            guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
            guard !context.isDraft else { return .unavailable(.pullRequestIsDraft) }
        case .close:
            guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
        case .reopen:
            guard context.state == .closed else {
                return .unavailable(context.state == .merged ? .pullRequestAlreadyMerged : .pullRequestNotClosed)
            }
        case .updateBranch:
            guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
            guard canUpdateBranch else { return .unavailable(.updateBranchUnavailable) }
        }
        return .available(ForgePullRequestLifecycleRequest(context: context, action: action))
    }
}

public enum ForgePullRequestMergeMethod: String, CaseIterable, Codable, Hashable, Sendable {
    case merge
    case squash
    case rebase
}

public enum ForgePullRequestMergeWarning: String, CaseIterable, Codable, Hashable, Sendable {
    case mergeabilityUnknown
    case mergeConflictReported
    case checksPending
    case checksFailing
    case reviewRequired
    case changesRequested
    case branchBehind
}

public enum ForgePullRequestMergeQueueState: String, Codable, Hashable, Sendable {
    case notQueued
    case queued
}

public struct ForgePullRequestMergeSnapshot: Hashable, Sendable {
    public let context: ForgePullRequestMutationContext
    public let viewerCanMerge: Bool
    public let enabledMethods: Set<ForgePullRequestMergeMethod>
    public let warnings: Set<ForgePullRequestMergeWarning>
    public let queueState: ForgePullRequestMergeQueueState

    public init(
        context: ForgePullRequestMutationContext,
        viewerCanMerge: Bool,
        enabledMethods: Set<ForgePullRequestMergeMethod>,
        warnings: Set<ForgePullRequestMergeWarning> = [],
        queueState: ForgePullRequestMergeQueueState = .notQueued
    ) {
        self.context = context
        self.viewerCanMerge = viewerCanMerge
        self.enabledMethods = enabledMethods
        self.warnings = warnings
        self.queueState = queueState
    }
}

public struct ForgePullRequestMergeConfirmation: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let head: ForgeCommitID
    public let base: ForgeCommitID
    public let updatedAt: Date
    public let method: ForgePullRequestMergeMethod
    public let warnings: Set<ForgePullRequestMergeWarning>

    public init(snapshot: ForgePullRequestMergeSnapshot, method: ForgePullRequestMergeMethod) {
        accountID = snapshot.context.accountID
        repository = snapshot.context.repository
        number = snapshot.context.number
        head = snapshot.context.head.commit
        base = snapshot.context.base.commit
        updatedAt = snapshot.context.updatedAt
        self.method = method
        warnings = snapshot.warnings
    }
}

public struct ForgePullRequestMergeRequest: Hashable, Sendable {
    public let confirmation: ForgePullRequestMergeConfirmation
    public let title: String?
    public let message: String?

    public init(
        confirmation: ForgePullRequestMergeConfirmation,
        title: String? = nil,
        message: String? = nil
    ) throws {
        switch confirmation.method {
        case .merge, .squash:
            if let title, !ForgePathComponent.isNonemptyPrintable(title) {
                throw ForgePullRequestMutationError.invalidMessage
            }
            if let message, !message.isEmpty, !ForgePathComponent.isNonemptyPrintable(message) {
                throw ForgePullRequestMutationError.invalidMessage
            }
        case .rebase:
            guard title == nil, message == nil else {
                throw ForgePullRequestMutationError.invalidMessage
            }
        }
        self.confirmation = confirmation
        self.title = title
        self.message = message
    }
}

public enum ForgePullRequestMergePolicy {
    /// This decision must be made from a freshly fetched snapshot immediately
    /// before presenting confirmation. Warnings are descriptive; GitHub makes
    /// the authoritative final merge decision.
    public static func confirmationDecision(
        snapshot: ForgePullRequestMergeSnapshot,
        method: ForgePullRequestMergeMethod
    ) -> ForgePullRequestMutationDecision<ForgePullRequestMergeConfirmation> {
        let context = snapshot.context
        if let unavailable = environmentOrCapability(context: context, operation: .mergePullRequest) {
            return .unavailable(unavailable)
        }
        guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
        guard !context.isDraft else { return .unavailable(.pullRequestIsDraft) }
        guard snapshot.viewerCanMerge else { return .unavailable(.viewerCannotMerge) }
        guard snapshot.enabledMethods.contains(method) else { return .unavailable(.mergeMethodDisabled) }
        return .available(ForgePullRequestMergeConfirmation(snapshot: snapshot, method: method))
    }

    /// The second validation is deliberately strict. Any changed identity,
    /// head, base, or server timestamp stops the merge and requires the user to
    /// confirm a newly fetched snapshot.
    public static func validate(
        confirmation: ForgePullRequestMergeConfirmation,
        fresh snapshot: ForgePullRequestMergeSnapshot
    ) throws -> ForgePullRequestMergeRequest {
        let context = snapshot.context
        guard confirmation.accountID == context.accountID,
              confirmation.repository == context.repository,
              confirmation.number == context.number,
              confirmation.head == context.head.commit,
              confirmation.base == context.base.commit,
              confirmation.updatedAt == context.updatedAt
        else {
            throw ForgePullRequestMutationError.staleConfirmation
        }
        guard case .available = confirmationDecision(snapshot: snapshot, method: confirmation.method) else {
            throw ForgePullRequestMutationError.staleConfirmation
        }
        return try ForgePullRequestMergeRequest(confirmation: confirmation)
    }
}

public struct ForgePullRequestMergePreferenceLedger: Codable, Hashable, Sendable {
    private var methodsByRepository: [ForgeRepositoryIdentity: ForgePullRequestMergeMethod]

    public init(methodsByRepository: [ForgeRepositoryIdentity: ForgePullRequestMergeMethod] = [:]) {
        self.methodsByRepository = methodsByRepository
    }

    public func preferredMethod(
        for repository: ForgeRepositoryIdentity,
        enabledMethods: Set<ForgePullRequestMergeMethod>
    ) -> ForgePullRequestMergeMethod? {
        guard let method = methodsByRepository[repository], enabledMethods.contains(method) else { return nil }
        return method
    }

    public mutating func recordSuccessfulMerge(
        repository: ForgeRepositoryIdentity,
        method: ForgePullRequestMergeMethod
    ) {
        methodsByRepository[repository] = method
    }
}

public enum ForgePullRequestMergeQueueAction: String, Codable, Hashable, Sendable {
    case enter
    case leave

    public var operation: ForgeOperation {
        self == .enter ? .enterMergeQueue : .leaveMergeQueue
    }
}

public struct ForgePullRequestMergeQueueRequest: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let number: ForgeItemNumber
    public let action: ForgePullRequestMergeQueueAction
    public let expectedHead: ForgeCommitID
}

public enum ForgePullRequestMergeQueuePolicy {
    public static func decision(
        snapshot: ForgePullRequestMergeSnapshot,
        action: ForgePullRequestMergeQueueAction
    ) -> ForgePullRequestMutationDecision<ForgePullRequestMergeQueueRequest> {
        let context = snapshot.context
        if let unavailable = environmentOrCapability(context: context, operation: action.operation) {
            return .unavailable(unavailable)
        }
        guard context.state == .open else { return .unavailable(.pullRequestNotOpen) }
        guard !context.isDraft else { return .unavailable(.pullRequestIsDraft) }
        switch action {
        case .enter:
            guard snapshot.queueState == .notQueued else { return .unavailable(.mergeQueueAlreadyEntered) }
        case .leave:
            guard snapshot.queueState == .queued else { return .unavailable(.mergeQueueNotEntered) }
        }
        return .available(ForgePullRequestMergeQueueRequest(
            accountID: context.accountID,
            repository: context.repository,
            number: context.number,
            action: action,
            expectedHead: context.head.commit
        ))
    }
}

public struct ForgeHeadBranchDeletionSnapshot: Hashable, Sendable {
    public let mergeSnapshot: ForgePullRequestMergeSnapshot
    public let isSameRepository: Bool
    public let isDefaultBranch: Bool
    public let isProtected: Bool
    public let viewerCanDelete: Bool
    public let hasCheckedOutSafetyConflict: Bool

    public init(
        mergeSnapshot: ForgePullRequestMergeSnapshot,
        isSameRepository: Bool,
        isDefaultBranch: Bool,
        isProtected: Bool,
        viewerCanDelete: Bool,
        hasCheckedOutSafetyConflict: Bool
    ) {
        self.mergeSnapshot = mergeSnapshot
        self.isSameRepository = isSameRepository
        self.isDefaultBranch = isDefaultBranch
        self.isProtected = isProtected
        self.viewerCanDelete = viewerCanDelete
        self.hasCheckedOutSafetyConflict = hasCheckedOutSafetyConflict
    }
}

public struct ForgeHeadBranchDeletionRequest: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let repository: ForgeRepositoryIdentity
    public let pullRequest: ForgeItemNumber
    public let branch: ForgeRefName
    public let expectedHead: ForgeCommitID
}

public enum ForgeHeadBranchDeletionPolicy {
    public static func decision(
        snapshot: ForgeHeadBranchDeletionSnapshot,
        mergeWasQueued: Bool
    ) -> ForgePullRequestMutationDecision<ForgeHeadBranchDeletionRequest> {
        let context = snapshot.mergeSnapshot.context
        if let unavailable = environmentOrCapability(context: context, operation: .deleteHeadBranch) {
            return .unavailable(unavailable)
        }
        guard context.state == .merged, !mergeWasQueued else {
            return .unavailable(.branchDeletionUnavailable)
        }
        guard snapshot.isSameRepository else { return .unavailable(.forkHeadBranch) }
        guard !snapshot.isDefaultBranch else { return .unavailable(.defaultBranch) }
        guard !snapshot.isProtected else { return .unavailable(.protectedBranch) }
        guard snapshot.viewerCanDelete else { return .unavailable(.branchDeletionUnavailable) }
        guard !snapshot.hasCheckedOutSafetyConflict else { return .unavailable(.checkedOutBranch) }
        return .available(ForgeHeadBranchDeletionRequest(
            accountID: context.accountID,
            repository: context.repository,
            pullRequest: context.number,
            branch: context.head.name,
            expectedHead: context.head.commit
        ))
    }
}

public struct ForgeHeadBranchDeletionPreferenceLedger: Codable, Hashable, Sendable {
    private var successfulChoicesByRepository: [ForgeRepositoryIdentity: Bool]

    public init(successfulChoicesByRepository: [ForgeRepositoryIdentity: Bool] = [:]) {
        self.successfulChoicesByRepository = successfulChoicesByRepository
    }

    /// The first presentation is always unchecked. A remembered value is only
    /// returned after a successful merge/deletion choice for this repository.
    public func rememberedChoice(for repository: ForgeRepositoryIdentity) -> Bool {
        successfulChoicesByRepository[repository] ?? false
    }

    public mutating func recordSuccessfulChoice(repository: ForgeRepositoryIdentity, selected: Bool) {
        successfulChoicesByRepository[repository] = selected
    }
}

public enum ForgePostMergeAction: String, CaseIterable, Codable, Hashable, Sendable {
    case fetch
    case checkOutBase
}

public enum ForgePostMergePolicy {
    public static let explicitActions = Set(ForgePostMergeAction.allCases)
}

public struct ForgeCreatePullRequestAuthoritativeRejection: Hashable, Sendable {
    public let comparison: ForgePullRequestComparisonKey
    public let message: String

    public init(comparison: ForgePullRequestComparisonKey, message: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(message) else {
            throw ForgePullRequestMutationError.invalidMessage
        }
        self.comparison = comparison
        self.message = message
    }
}

public enum ForgeCreatePullRequestReconciliationDecision: Hashable, Sendable {
    case openExisting(ForgePullRequestSummary)
    case preserveDraft(authoritativeMessage: String)
}

public enum ForgeCreatePullRequestReconciliationPolicy {
    /// An authoritative create rejection is never converted into a guessed
    /// duplicate. Only a freshly fetched, exact open base/head match may route
    /// to an existing Pull Request; every other result preserves the draft and
    /// the server's message without retrying.
    public static func decision(
        rejection: ForgeCreatePullRequestAuthoritativeRejection,
        refreshedPullRequests: [ForgePullRequestSummary]
    ) -> ForgeCreatePullRequestReconciliationDecision {
        switch ForgeDuplicatePullRequestPolicy.decision(
            for: rejection.comparison,
            among: refreshedPullRequests
        ) {
        case let .openExisting(pullRequest): .openExisting(pullRequest)
        case .create: .preserveDraft(authoritativeMessage: rejection.message)
        }
    }
}

public enum ForgeMutationResultState: Hashable, Sendable {
    case idle
    case executing
    case succeeded
    case failed(authoritativeMessage: String)
    case outcomeUnknown
    case reconciled(succeeded: Bool)

    public func applying(_ event: ForgeMutationResultEvent) throws -> Self {
        switch (self, event) {
        case (.idle, .begin), (.failed, .retry), (.reconciled(succeeded: false), .retry):
            return .executing
        case (.executing, .succeeded): return .succeeded
        case let (.executing, .failed(message)):
            guard ForgePathComponent.isNonemptyPrintable(message) else {
                throw ForgePullRequestMutationError.invalidMessage
            }
            return .failed(authoritativeMessage: message)
        case (.executing, .outcomeUnknown): return .outcomeUnknown
        case let (.outcomeUnknown, .reconciled(succeeded)): return .reconciled(succeeded: succeeded)
        default: throw ForgePullRequestMutationError.invalidTransition
        }
    }
}

public enum ForgeMutationResultEvent: Hashable, Sendable {
    case begin
    case succeeded
    case failed(authoritativeMessage: String)
    case outcomeUnknown
    case reconciled(succeeded: Bool)
    case retry
}

/// Provider-neutral boundary between a forge adapter and controller/UI state.
/// Provider response metadata and error types never cross this boundary.
public enum ForgeMutationPresentationOutcome<Value: Sendable>: Sendable {
    case succeeded(Value)
    case authoritativeFailure(String)
    case offline
    case cooldown(until: Date)
    case authenticationRequired
    case permissionDenied
    case capabilityUnavailable
    case stale
    case outcomeUnknown
}

private func environmentOrCapability(
    context: ForgePullRequestMutationContext,
    operation: ForgeOperation
) -> ForgePullRequestMutationUnavailableReason? {
    switch context.environment {
    case .available: break
    case .offline: return .offline
    case let .rateLimited(until): return .rateLimited(until: until)
    }
    guard context.allowedOperations.contains(operation) else {
        return .capabilityUnavailable(operation)
    }
    return nil
}
