@_spi(Unsafe) import ApolloAPI
import ForgeKit
import Foundation

struct GitHubPullRequestMutationPreflight: Sendable {
    let snapshot: GitHubPullRequestMutationValue
    let viewerCanClose: Bool
    let viewerCanReopen: Bool
    let viewerCanUpdate: Bool
    let viewerCanUpdateBranch: Bool
    let viewerCanMerge: Bool
    let enabledMergeMethods: Set<ForgePullRequestMergeMethod>
    let mergeWarnings: Set<ForgePullRequestMergeWarning>
    let mergeQueueEntryID: ForgeObjectID?
}

struct GitHubReviewThreadMutationPreflight: Sendable {
    let id: ForgeObjectID
    let repository: ForgeRepositoryIdentity
    let pullRequest: ForgeItemNumber
    let displayedHead: ForgeCommitID
    let isResolved: Bool
}

struct GitHubHeadBranchMutationPreflight: Sendable {
    let refID: ForgeObjectID
    let branch: ForgeRefName
    let head: ForgeCommitID
    let isDefaultBranch: Bool
    let isProtected: Bool
    let viewerCanDelete: Bool
}

struct GitHubPullRequestCreationPage: Sendable {
    let repositoryID: String
    let headRepositoryID: String
    let snapshots: [GitHubPullRequestMutationValue]
    let nextCursor: String?
}

struct GitHubMutationMapper {
    private let forge: ForgeIdentity

    init(forge: ForgeIdentity) {
        self.forge = forge
    }

    func repository(_ fragment: GitHubAPI.GitHubRepositoryIdentity) throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: forge,
            owner: fragment.owner.login,
            name: fragment.name
        )
    }

    func objectID(_ value: String) throws -> ForgeObjectID {
        try ForgeObjectID(forge: forge, value: value)
    }

    func snapshot(
        _ fragment: GitHubAPI.GitHubPullRequestMutationSnapshot,
        expectedRepository: ForgeRepositoryIdentity
    ) throws -> GitHubPullRequestMutationValue {
        guard let headRepositoryNode = fragment.headRepository,
              let baseRepositoryNode = fragment.baseRepository
        else {
            throw GitHubMutationError.malformedResponse
        }
        let headRepository = try repository(
            headRepositoryNode.fragments.gitHubRepositoryIdentity
        )
        let baseRepository = try repository(
            baseRepositoryNode.fragments.gitHubRepositoryIdentity
        )
        guard baseRepository == expectedRepository else {
            throw GitHubMutationError.malformedResponse
        }
        let state: ForgePullRequestState
        switch fragment.state.value {
        case .open: state = .open
        case .closed: state = .closed
        case .merged: state = .merged
        case nil: throw GitHubMutationError.malformedResponse
        }
        return try GitHubPullRequestMutationValue(
            id: objectID(fragment.id),
            repository: expectedRepository,
            number: ForgeItemNumber(fragment.number),
            state: state,
            isDraft: fragment.isDraft,
            title: fragment.title,
            bodyMarkdown: fragment.body,
            head: ForgeBranchReference(
                repository: headRepository,
                name: ForgeRefName(fragment.headRefName),
                commit: ForgeCommitID(fragment.headRefOid)
            ),
            base: ForgeBranchReference(
                repository: baseRepository,
                name: ForgeRefName(fragment.baseRefName),
                commit: ForgeCommitID(fragment.baseRefOid)
            ),
            createdAt: date(fragment.createdAt),
            updatedAt: date(fragment.updatedAt),
            closedAt: optionalDate(fragment.closedAt),
            mergedAt: optionalDate(fragment.mergedAt)
        )
    }

    func pullRequestPreflight(
        _ data: GitHubAPI.GitHubPullRequestMutationPreflightQuery.Data,
        expectedRepository: ForgeRepositoryIdentity
    ) throws -> GitHubPullRequestMutationPreflight {
        guard let repository = data.repository else {
            throw GitHubMutationError.objectNotFound
        }
        try validateRepository(repository.fragments.gitHubRepositoryIdentity, expected: expectedRepository)
        guard let pullRequest = repository.pullRequest else {
            throw GitHubMutationError.objectNotFound
        }
        let snapshot = try snapshot(
            pullRequest.fragments.gitHubPullRequestMutationSnapshot,
            expectedRepository: expectedRepository
        )
        var methods: Set<ForgePullRequestMergeMethod> = []
        if repository.mergeCommitAllowed {
            methods.insert(.merge)
        }
        if repository.squashMergeAllowed {
            methods.insert(.squash)
        }
        if repository.rebaseMergeAllowed {
            methods.insert(.rebase)
        }
        let viewerCanMerge: Bool
        switch repository.viewerPermission?.value {
        case .write, .maintain, .admin: viewerCanMerge = true
        case .read, .triage, nil: viewerCanMerge = false
        }
        var warnings: Set<ForgePullRequestMergeWarning> = []
        if pullRequest.viewerCanUpdateBranch {
            warnings.insert(.branchBehind)
        }
        switch pullRequest.mergeable.value {
        case .conflicting: warnings.insert(.mergeConflictReported)
        case .unknown, nil: warnings.insert(.mergeabilityUnknown)
        case .mergeable: break
        }
        switch pullRequest.reviewDecision?.value {
        case .changesRequested: warnings.insert(.changesRequested)
        case .reviewRequired: warnings.insert(.reviewRequired)
        case .approved, nil: break
        }
        switch pullRequest.statusCheckRollup?.state.value {
        case .pending, .expected:
            warnings.insert(.checksPending)
        case .error, .failure:
            warnings.insert(.checksFailing)
        case .success, nil:
            break
        }
        return try GitHubPullRequestMutationPreflight(
            snapshot: snapshot,
            viewerCanClose: pullRequest.viewerCanClose,
            viewerCanReopen: pullRequest.viewerCanReopen,
            viewerCanUpdate: pullRequest.viewerCanUpdate,
            viewerCanUpdateBranch: pullRequest.viewerCanUpdateBranch,
            viewerCanMerge: viewerCanMerge,
            enabledMergeMethods: methods,
            mergeWarnings: warnings,
            mergeQueueEntryID: pullRequest.mergeQueueEntry.map {
                try objectID($0.id)
            }
        )
    }

    func creationPage(
        _ data: GitHubAPI.GitHubPullRequestCreationPreflightQuery.Data,
        expectedRepository: ForgeRepositoryIdentity,
        expectedHeadRepository: ForgeRepositoryIdentity
    ) throws -> GitHubPullRequestCreationPage {
        guard let repository = data.repository,
              let headRepository = data.headRepository
        else {
            throw GitHubMutationError.objectNotFound
        }
        try validateRepository(repository.fragments.gitHubRepositoryIdentity, expected: expectedRepository)
        try validateRepository(
            headRepository.fragments.gitHubRepositoryIdentity,
            expected: expectedHeadRepository
        )
        let snapshots = try (repository.pullRequests.nodes ?? []).compactMap { node in
            try node.map {
                try snapshot(
                    $0.fragments.gitHubPullRequestMutationSnapshot,
                    expectedRepository: expectedRepository
                )
            }
        }
        let pageInfo = repository.pullRequests.pageInfo
        guard !pageInfo.hasNextPage || pageInfo.endCursor != nil else {
            throw GitHubMutationError.malformedResponse
        }
        return GitHubPullRequestCreationPage(
            repositoryID: repository.id,
            headRepositoryID: headRepository.id,
            snapshots: snapshots,
            nextCursor: pageInfo.hasNextPage ? pageInfo.endCursor : nil
        )
    }

    func reviewThreadPreflight(
        _ data: GitHubAPI.GitHubReviewThreadMutationPreflightQuery.Data,
        expectedID: ForgeObjectID,
        expectedRepository: ForgeRepositoryIdentity,
        expectedPullRequest: ForgeItemNumber
    ) throws -> GitHubReviewThreadMutationPreflight {
        guard let thread = data.node?.asPullRequestReviewThread else {
            throw GitHubMutationError.objectNotFound
        }
        let repository = try repository(
            thread.pullRequest.repository.fragments.gitHubRepositoryIdentity
        )
        let pullRequest = try ForgeItemNumber(thread.pullRequest.number)
        let id = try objectID(thread.id)
        guard id == expectedID,
              repository == expectedRepository,
              pullRequest == expectedPullRequest
        else {
            throw GitHubMutationError.authorizationMismatch
        }
        return try GitHubReviewThreadMutationPreflight(
            id: id,
            repository: repository,
            pullRequest: pullRequest,
            displayedHead: ForgeCommitID(thread.pullRequest.headRefOid),
            isResolved: thread.isResolved
        )
    }

    func headBranchPreflight(
        _ data: GitHubAPI.GitHubHeadBranchDeletionPreflightQuery.Data,
        expectedRepository: ForgeRepositoryIdentity,
        expectedBranch: ForgeRefName,
        expectedHead: ForgeCommitID
    ) throws -> GitHubHeadBranchMutationPreflight {
        guard let repository = data.repository else {
            throw GitHubMutationError.objectNotFound
        }
        try validateRepository(repository.fragments.gitHubRepositoryIdentity, expected: expectedRepository)
        guard let reference = repository.ref,
              let target = reference.target,
              try ForgeRefName(reference.name) == expectedBranch,
              try ForgeCommitID(target.oid) == expectedHead
        else {
            throw GitHubMutationError.stalePullRequest
        }
        let viewerCanDelete = switch repository.viewerPermission?.value {
        case .write, .maintain, .admin: true
        case .read, .triage, nil: false
        }
        return try GitHubHeadBranchMutationPreflight(
            refID: objectID(reference.id),
            branch: expectedBranch,
            head: expectedHead,
            isDefaultBranch: repository.defaultBranchRef?.name == expectedBranch.value,
            isProtected: reference.branchProtectionRule != nil,
            viewerCanDelete: viewerCanDelete
        )
    }

    func validateSyncFork(
        _ data: GitHubAPI.GitHubSyncForkPreflightQuery.Data,
        plan: ForgeSyncForkPlan
    ) throws {
        guard let fork = data.repository else {
            throw GitHubMutationError.objectNotFound
        }
        try validateRepository(fork.fragments.gitHubRepositoryIdentity, expected: plan.fork)
        guard fork.isFork, let parent = fork.parent else {
            throw GitHubMutationError.invalidRequest
        }
        try validateRepository(parent.fragments.gitHubRepositoryIdentity, expected: plan.parent)
    }

    private func validateRepository(
        _ fragment: GitHubAPI.GitHubRepositoryIdentity,
        expected: ForgeRepositoryIdentity
    ) throws {
        guard try repository(fragment) == expected else {
            throw GitHubMutationError.authorizationMismatch
        }
    }

    private func date(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let parsed = whole.date(from: value) else {
            throw GitHubMutationError.malformedResponse
        }
        return parsed
    }

    private func optionalDate(_ value: String?) throws -> Date? {
        try value.map(date)
    }
}
