import AppKit
import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

nonisolated enum RepositoryPullRequestCheckPagination {
    static func merging(_ current: [ForgeCheck], with next: [ForgeCheck]) -> [ForgeCheck] {
        var checks: [ForgeCheck] = []
        var indicesByIdentity: [Identity: Int] = [:]
        for check in current + next {
            let identity = Identity(check)
            if let index = indicesByIdentity[identity] {
                // A later page can overlap while a check is changing state. Keep
                // the newest value without moving the check in the presentation.
                checks[index] = check
            } else {
                indicesByIdentity[identity] = checks.count
                checks.append(check)
            }
        }
        return checks
    }

    private enum Identity: Hashable {
        case object(repository: ForgeRepositoryIdentity, id: ForgeObjectID)
        case fallback(repository: ForgeRepositoryIdentity, kind: ForgeCheckKind, name: String)

        init(_ check: ForgeCheck) {
            if let id = check.id {
                self = .object(repository: check.repository, id: id)
            } else {
                // GitHub normally supplies an object identifier. The kind/name pair is
                // the stable status-context identity when an adapter cannot.
                self = .fallback(
                    repository: check.repository,
                    kind: check.kind,
                    name: check.name
                )
            }
        }
    }
}

@MainActor
protocol RepositoryPullRequestReviewRouting: AnyObject {
    func openInBrowser(_ destination: ForgeDestination)
}

@MainActor
struct RepositoryPullRequestReviewApplicationSession {
    let service: any RepositoryPullRequestReviewMutationServing
    let localService: any RepositoryPullRequestLocalReviewServing
    let drafts: any RepositoryPullRequestDraftPersisting
    let preferences: any RepositoryPullRequestMutationPreferencePersisting

    func makeReviewSession(
        identity: RepositoryPullRequestReviewIdentity
    ) -> RepositoryPullRequestReviewSession {
        RepositoryPullRequestReviewSession(
            identity: identity,
            service: service,
            localService: localService,
            drafts: drafts,
            preferences: preferences
        )
    }
}

final nonisolated class RepositoryPullRequestReviewServiceResolver: Sendable {
    typealias Factory = @MainActor @Sendable (PBGitRepository) -> RepositoryPullRequestReviewApplicationSession

    private let factory: Factory

    init(factory: @escaping Factory = { _ in
        RepositoryPullRequestReviewApplicationSession(
            service: UnavailableRepositoryPullRequestReviewMutationService(),
            localService: UnavailableRepositoryPullRequestLocalReviewService(),
            drafts: NullRepositoryPullRequestDraftStore(),
            preferences: NullRepositoryPullRequestMutationPreferenceStore()
        )
    }) {
        self.factory = factory
    }

    @MainActor
    func session(for repository: PBGitRepository) -> RepositoryPullRequestReviewApplicationSession {
        factory(repository)
    }
}

@MainActor
final class RepositoryPullRequestReviewBrowserRouter: RepositoryPullRequestReviewRouting {
    func openInBrowser(_ destination: ForgeDestination) {
        guard let url = try? ForgeDestinationURLCodec.url(for: destination) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension ForgeCentralDestinationRouter: RepositoryPullRequestReviewRouting {
    func openInBrowser(_ destination: ForgeDestination) {
        openInBrowser(destination: destination)
    }
}

// MARK: - Exact-account provider boundaries

nonisolated protocol ForgeGitHubPullRequestReviewReading: Sendable {
    func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelinePageSize: Int,
        timelineAfter: ForgePageCursor?,
        checkPageSize: Int,
        checkAfter: ForgePageCursor?
    ) async throws -> GitHubReadResult<ForgePullRequestDetailsPage>

    func reviewThreads(
        repository: ForgeRepositoryIdentity,
        pullRequestNumber: ForgeItemNumber,
        pageSize: Int,
        after: ForgePageCursor?,
        initialCommentCount: Int
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewThread>>

    func reviewThreadComments(
        repository: ForgeRepositoryIdentity,
        threadID: ForgeObjectID,
        pageSize: Int,
        after: ForgePageCursor?
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewComment>>
}

extension GitHubReadAdapter: ForgeGitHubPullRequestReviewReading {}

nonisolated protocol ForgeGitHubPullRequestReviewMutationExecuting: Sendable {
    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt>

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt>

    func setReviewThreadResolution(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt>

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt>

    func performLifecycle(
        _ request: ForgePullRequestLifecycleRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue>

    func freshMergeSnapshot(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        operation: ForgeOperation,
        authorization: GitHubMutationAuthorization
    ) async throws -> ForgePullRequestMergeSnapshot

    func mergePullRequest(
        _ request: ForgePullRequestMergeRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue>

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubMergeQueueReceipt>

    func freshHeadBranchDeletionSnapshot(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        branch: ForgeRefName,
        expectedHead: ForgeCommitID,
        hasCheckedOutSafetyConflict: Bool,
        authorization: GitHubMutationAuthorization
    ) async throws -> ForgeHeadBranchDeletionSnapshot

    func deleteHeadBranch(
        _ request: ForgeHeadBranchDeletionRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubHeadBranchDeletionReceipt>
}

extension GitHubMutationAdapter: ForgeGitHubPullRequestReviewMutationExecuting {}

nonisolated struct ForgeGitHubPullRequestReviewReadContext: Sendable {
    let account: ForgeAccount
    let credential: ForgeCredentialReference
    let environment: ForgeMutationEnvironment
    let allowedOperations: Set<ForgeOperation>
    let readAdapter: any ForgeGitHubPullRequestReviewReading
}

nonisolated struct ForgeGitHubPullRequestReviewMutationContext: Sendable {
    let account: ForgeAccount
    let credential: ForgeCredentialReference
    let authorization: GitHubMutationAuthorization
    let readAdapter: any ForgeGitHubPullRequestReviewReading
    let mutationAdapter: any ForgeGitHubPullRequestReviewMutationExecuting
}

nonisolated protocol ForgeGitHubPullRequestReviewDependencyProviding: Sendable {
    func reviewReadContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operations: Set<ForgeOperation>
    ) async throws -> ForgeGitHubPullRequestReviewReadContext

    func reviewMutationContext(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestReviewMutationContext

    func recordSuccess(
        _ result: GitHubResponseMetadata,
        context: ForgeGitHubPullRequestReviewMutationContext
    ) async

    func recordFailure(
        _ error: GitHubMutationError,
        context: ForgeGitHubPullRequestReviewMutationContext
    ) async
}

nonisolated struct RepositoryPullRequestReviewThreadPageLoad: Sendable {
    let threads: [ForgeReviewThread]
    let didFail: Bool
}

nonisolated protocol RepositoryPullRequestReviewUnknownOutcomeReconciling: Sendable {
    func unknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope
    ) async throws -> [ForgeUnknownMutationOutcomeRecord]

    func consumeUnknownOutcomes(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        scope: ForgeUnknownMutationOutcomeScope
    ) async throws -> [ForgeUnknownMutationOutcomeRecord]
}

extension ForgeMutationQuitCoordinator: RepositoryPullRequestReviewUnknownOutcomeReconciling {}

/// Exact-account GitHub implementation for the native review surface. Reads
/// preserve the last complete workspace when a page fails, while every write
/// resolves fresh Credential-bound authorization and is tracked until its
/// dispatch returns.
actor RepositoryPullRequestReviewProductionService: RepositoryPullRequestReviewMutationServing {
    private static let reviewOperations: Set<ForgeOperation> = [
        .publishInlineReviewComment,
        .replyToReviewThread,
        .resolveReviewThread,
        .unresolveReviewThread,
        .submitApproveReview,
        .submitCommentReview,
        .submitRequestChangesReview,
        .markPullRequestReady,
        .convertPullRequestToDraft,
        .closePullRequest,
        .reopenPullRequest,
        .updatePullRequestBranch,
        .mergePullRequest,
        .deleteHeadBranch,
        .enterMergeQueue,
        .leaveMergeQueue,
    ]

    private let binding: ForgeRepositoryBinding
    private let dependencies: any ForgeGitHubPullRequestReviewDependencyProviding
    private let localService: any RepositoryPullRequestLocalReviewServing
    private let mutationLifecycle: (any ForgeMutationLifecycleCoordinating)?
    private let unknownOutcomes: (any RepositoryPullRequestReviewUnknownOutcomeReconciling)?
    private let currentBinding: @Sendable () -> ForgeRepositoryBinding?
    private let now: @Sendable () -> Date
    private var lastWorkspace: RepositoryPullRequestReviewWorkspace?
    private var loadGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestReviewComposition")

    init(
        binding: ForgeRepositoryBinding,
        dependencies: any ForgeGitHubPullRequestReviewDependencyProviding,
        localService: any RepositoryPullRequestLocalReviewServing,
        mutationLifecycle: (any ForgeMutationLifecycleCoordinating)? = nil,
        unknownOutcomes: (any RepositoryPullRequestReviewUnknownOutcomeReconciling)? = nil,
        currentBinding: (@Sendable () -> ForgeRepositoryBinding?)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.binding = binding
        self.dependencies = dependencies
        self.localService = localService
        self.mutationLifecycle = mutationLifecycle
        self.unknownOutcomes = unknownOutcomes
        self.currentBinding = currentBinding ?? { binding }
        self.now = now
    }

    func loadWorkspace(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        loadGeneration = loadGeneration == .max ? 1 : loadGeneration + 1
        let generation = loadGeneration
        try validate(identity)
        let previous = lastWorkspace.flatMap { $0.identity == identity ? $0 : nil }
        do {
            let readContext = try await dependencies.reviewReadContext(
                accountID: identity.accountID,
                repository: identity.repository,
                operations: Self.reviewOperations
            )
            try validate(readContext, identity: identity)

            let detailsResult = try await readContext.readAdapter.pullRequestDetails(
                repository: identity.repository,
                number: identity.number,
                timelinePageSize: 100,
                timelineAfter: nil,
                checkPageSize: 100,
                checkAfter: nil
            )
            try validate(detailsResult.ownership, context: readContext, identity: identity)
            let detailsLoad = try await completeDetails(
                initial: detailsResult,
                identity: identity,
                readContext: readContext
            )
            try Task.checkCancellation()
            try validate(identity)
            let detailsPage = detailsLoad.page
            let details = detailsPage.details
            let summary = details.summary
            guard summary.repository == identity.repository,
                  summary.number == identity.number,
                  case let .available(detailsHead) = summary.head,
                  case let .available(detailsBase) = summary.base
            else {
                throw RepositoryPullRequestReviewServiceError.invalidWorkspace
            }
            let sameHeadPrevious = previous.flatMap {
                $0.displayedHead == detailsHead.commit ? $0 : nil
            }
            let threadLoad = try await reviewThreads(
                identity: identity,
                readContext: readContext,
                previous: sameHeadPrevious?.threads ?? []
            )
            try Task.checkCancellation()
            try validate(identity)

            let mergeLoad = try await workspaceMergeSnapshot(
                identity: identity,
                readContext: readContext,
                detailsHead: detailsHead,
                detailsBase: detailsBase,
                summary: summary,
                previous: sameHeadPrevious
            )
            try Task.checkCancellation()
            try validate(identity)
            let merge = mergeLoad.snapshot
            var records: [RepositoryPullRequestReviewThreadRecord] = []
            records.reserveCapacity(threadLoad.threads.count)
            for thread in threadLoad.threads {
                try records.append(await reviewThreadRecord(
                    thread,
                    identity: identity,
                    displayedHead: merge.context.head.commit
                ))
                try Task.checkCancellation()
            }
            let deletionLoad = try await initialDeletionSnapshot(
                identity: identity,
                merge: merge
            )
            try validate(identity)
            let detailsComplete = !detailsLoad.didFail
                && detailsPage.nextCheckCursor == nil
                && Self.timelineIsComplete(details.timeline)
            let reconciliation = await pendingUnknownOperations(identity: identity)
            try Task.checkCancellation()
            try validate(identity)
            var isFresh = detailsComplete
                && !threadLoad.didFail
                && !mergeLoad.didFail
                && !deletionLoad.didFail
                && !reconciliation.didFail

            if isFresh, !reconciliation.operations.isEmpty {
                try validate(identity)
                isFresh = await consumeUnknownOperations(
                    reconciliation.operations,
                    identity: identity
                )
                try Task.checkCancellation()
                try validate(identity)
            }

            let canUpdateBranch = merge.context.allowedOperations.contains(.updatePullRequestBranch)
                && merge.warnings.contains(.branchBehind)
            let workspace = try RepositoryPullRequestReviewWorkspace(
                identity: identity,
                displayedHead: merge.context.head.commit,
                base: merge.context.base,
                title: summary.title,
                isDraft: merge.context.isDraft,
                threads: records,
                reviewers: details.reviewers,
                mutationContext: merge.context,
                mergeSnapshot: merge,
                headBranchDeletionSnapshot: deletionLoad.snapshot,
                canUpdateBranch: canUpdateBranch,
                isMutationStateFresh: isFresh,
                fetchedAt: now()
            )
            guard generation == loadGeneration else {
                throw CancellationError()
            }
            try validate(identity)
            lastWorkspace = workspace
            logger.info(
                "operation=load_review phase=install transition=complete fresh=\(isFresh, privacy: .public)"
            )
            return workspace
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == loadGeneration, let previous {
                lastWorkspace = try? previous.markingMutationStateFresh(false)
            }
            logger.error("operation=load_review phase=refresh transition=failed")
            throw error
        }
    }

    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let identity = try identity(
            accountID: publication.accountID,
            repository: publication.repository,
            number: publication.pullRequest
        )
        return try await mutate(identity: identity, operation: .publishInlineReviewComment) { context in
            try await context.mutationAdapter.publishInlineReview(
                publication,
                authorization: context.authorization
            )
        }
    }

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let identity = try identity(
            accountID: publication.accountID,
            repository: publication.repository,
            number: publication.pullRequest
        )
        return try await mutate(identity: identity, operation: .replyToReviewThread) { context in
            try await context.mutationAdapter.replyToReviewThread(
                publication,
                authorization: context.authorization
            )
        }
    }

    func setReviewThreadResolution(
        identity: RepositoryPullRequestReviewIdentity,
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation
    ) async throws {
        let operation: ForgeOperation = mutation == .resolve ? .resolveReviewThread : .unresolveReviewThread
        _ = try await dispatch(identity: identity, operation: operation) { context in
            try await context.mutationAdapter.setReviewThreadResolution(
                accountID: identity.accountID,
                repository: identity.repository,
                pullRequest: identity.number,
                threadID: threadID,
                mutation: mutation,
                authorization: context.authorization
            )
        }
    }

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let identity = try identity(
            accountID: submission.accountID,
            repository: submission.repository,
            number: submission.pullRequest
        )
        let operation: ForgeOperation = switch submission.kind {
        case .approve: .submitApproveReview
        case .comment: .submitCommentReview
        case .requestChanges: .submitRequestChangesReview
        }
        return try await mutate(identity: identity, operation: operation) { context in
            try await context.mutationAdapter.submitFormalReview(
                submission,
                authorization: context.authorization
            )
        }
    }

    func performLifecycle(
        _ request: ForgePullRequestLifecycleRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let identity = try identity(
            accountID: request.accountID,
            repository: request.repository,
            number: request.number
        )
        return try await mutate(
            identity: identity,
            operation: request.action.operation,
            afterSuccess: { [localService] value in
                guard let remoteTrackingBranch = RepositoryPullRequestReviewLocalRefreshPolicy.remoteTrackingBranch(
                    after: request.action,
                    updatedHead: value.head
                ) else { return }
                try await localService.fetchBase(remoteTrackingBranch)
            }
        ) { context in
            try await context.mutationAdapter.performLifecycle(
                request,
                authorization: context.authorization
            )
        }
    }

    func freshMergeSnapshot(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgePullRequestMergeSnapshot {
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        let context = try await mutationContext(identity: identity, operation: .mergePullRequest)
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        do {
            let snapshot = try await context.mutationAdapter.freshMergeSnapshot(
                accountID: identity.accountID,
                repository: identity.repository,
                pullRequest: identity.number,
                operation: .mergePullRequest,
                authorization: context.authorization
            )
            try validate(identity)
            try validate(snapshot, identity: identity)
            return snapshot
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            throw map(error)
        }
    }

    func mergePullRequest(
        _ request: ForgePullRequestMergeRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let confirmation = request.confirmation
        let identity = try identity(
            accountID: confirmation.accountID,
            repository: confirmation.repository,
            number: confirmation.number
        )
        return try await mutate(identity: identity, operation: .mergePullRequest) { context in
            try await context.mutationAdapter.mergePullRequest(
                request,
                authorization: context.authorization
            )
        }
    }

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let identity = try identity(
            accountID: request.accountID,
            repository: request.repository,
            number: request.number
        )
        return try await mutate(identity: identity, operation: request.action.operation) { context in
            try await context.mutationAdapter.changeMergeQueue(
                request,
                authorization: context.authorization
            )
        }
    }

    func freshHeadBranchDeletionSnapshot(
        identity: RepositoryPullRequestReviewIdentity
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        try validate(identity)
        let workspace = try await loadWorkspace(identity: identity)
        guard workspace.isMutationStateFresh else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        let context = try await mutationContext(identity: identity, operation: .deleteHeadBranch)
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        let checkedOutHead = try await localService.checkedOutHead()
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        do {
            let snapshot = try await context.mutationAdapter.freshHeadBranchDeletionSnapshot(
                accountID: identity.accountID,
                repository: identity.repository,
                pullRequest: identity.number,
                branch: workspace.mutationContext.head.name,
                expectedHead: workspace.displayedHead,
                hasCheckedOutSafetyConflict: checkedOutHead == workspace.displayedHead,
                authorization: context.authorization
            )
            try validate(identity)
            try validate(snapshot.mergeSnapshot, identity: identity)
            return snapshot
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            throw map(error)
        }
    }

    func deleteHeadBranch(_ request: ForgeHeadBranchDeletionRequest) async throws {
        let identity = try identity(
            accountID: request.accountID,
            repository: request.repository,
            number: request.pullRequest
        )
        _ = try requireCurrentWorkspace(identity)
        let context = try await mutationContext(identity: identity, operation: .deleteHeadBranch)
        try validate(identity)
        let workspace = try requireCurrentWorkspace(identity)
        let checkedOutHead = try await localService.checkedOutHead()
        try validate(identity)
        let current = try requireCurrentWorkspace(identity)
        guard current.displayedHead == workspace.displayedHead else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        try RepositoryPullRequestHeadDeletionDispatchPolicy.validate(
            request: request,
            workspace: current,
            checkedOutHead: checkedOutHead
        )
        _ = try await dispatch(
            identity: identity,
            operation: .deleteHeadBranch,
            preparedContext: context
        ) { context in
            try await context.mutationAdapter.deleteHeadBranch(
                request,
                authorization: context.authorization
            )
        }
        if let lastWorkspace, lastWorkspace.identity == identity {
            self.lastWorkspace = try? lastWorkspace.markingMutationStateFresh(false)
        }
    }

    private func mutate<Value: Sendable>(
        identity: RepositoryPullRequestReviewIdentity,
        operation: ForgeOperation,
        afterSuccess: @Sendable (Value) async throws -> Void = { _ in },
        body: @Sendable (ForgeGitHubPullRequestReviewMutationContext) async throws -> GitHubMutationResult<Value>
    ) async throws -> RepositoryPullRequestReviewWorkspace {
        let result = try await dispatch(identity: identity, operation: operation, body: body)
        let acknowledged = lastWorkspace.flatMap { $0.identity == identity ? $0 : nil }
        if let acknowledged {
            lastWorkspace = try? acknowledged.markingMutationStateFresh(false)
        }

        var localRefreshFailed = false
        do {
            try await afterSuccess(result.value)
        } catch is CancellationError {
            localRefreshFailed = true
            logger.error("Mutation succeeded but the required local refresh was cancelled")
        } catch {
            localRefreshFailed = true
            logger.error("Mutation succeeded but the required local refresh failed")
        }
        logger.notice("Completed native review mutation operation=\(operation.rawValue, privacy: .public)")

        do {
            let workspace = try await loadWorkspace(identity: identity)
            if localRefreshFailed || !workspace.isMutationStateFresh {
                let stale = try workspace.markingMutationStateFresh(false)
                lastWorkspace = stale
                return stale
            }
            return workspace
        } catch {
            guard let retained = lastWorkspace ?? acknowledged,
                  retained.identity == identity
            else {
                throw error
            }
            let stale = try retained.markingMutationStateFresh(false)
            lastWorkspace = stale
            logger.error("Mutation succeeded but authoritative workspace refresh failed; disabling mutations")
            return stale
        }
    }

    private func dispatch<Value: Sendable>(
        identity: RepositoryPullRequestReviewIdentity,
        operation: ForgeOperation,
        preparedContext: ForgeGitHubPullRequestReviewMutationContext? = nil,
        body: @Sendable (ForgeGitHubPullRequestReviewMutationContext) async throws -> GitHubMutationResult<Value>
    ) async throws -> GitHubMutationResult<Value> {
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        let context = if let preparedContext {
            preparedContext
        } else {
            try await mutationContext(identity: identity, operation: operation)
        }
        try validate(context, identity: identity, operation: operation)
        try validate(identity)
        _ = try requireCurrentWorkspace(identity)
        let registration = try mutationLifecycle?.register(
            accountID: identity.accountID,
            repository: identity.repository,
            operation: operation,
            scope: .pullRequest(identity.number),
            startedAt: now()
        )
        defer {
            if let registration {
                _ = mutationLifecycle?.finish(registration)
            }
        }

        let result: GitHubMutationResult<Value>
        do {
            try validate(identity)
            result = try await body(context)
        } catch let error as GitHubMutationError {
            await dependencies.recordFailure(error, context: context)
            throw map(error)
        }
        guard result.ownership.credential == context.credential,
              result.ownership.repository == identity.repository,
              result.ownership.operation == operation
        else {
            // The adapter returned after dispatch, so an invalid receipt cannot
            // prove that GitHub rejected the write. Reconcile without retrying.
            let error = GitHubMutationError.outcomeUnknown(result.response)
            await dependencies.recordFailure(error, context: context)
            throw map(error)
        }
        await dependencies.recordSuccess(result.response, context: context)
        return result
    }

    private func workspaceMergeSnapshot(
        identity: RepositoryPullRequestReviewIdentity,
        readContext: ForgeGitHubPullRequestReviewReadContext,
        detailsHead: ForgeBranchReference,
        detailsBase: ForgeBranchReference,
        summary: ForgePullRequestSummary,
        previous: RepositoryPullRequestReviewWorkspace?
    ) async throws -> (snapshot: ForgePullRequestMergeSnapshot, didFail: Bool) {
        let operation = readContext.allowedOperations.contains(.mergePullRequest)
            ? ForgeOperation.mergePullRequest
            : readContext.allowedOperations.sorted(by: { $0.rawValue < $1.rawValue }).first
        guard let operation else {
            return try (
                unavailableMergeSnapshot(
                    identity: identity,
                    readContext: readContext,
                    detailsHead: detailsHead,
                    detailsBase: detailsBase,
                    summary: summary
                ),
                false
            )
        }

        do {
            let mutation = try await mutationContext(identity: identity, operation: operation)
            try validate(identity)
            let snapshot = try await mutation.mutationAdapter.freshMergeSnapshot(
                accountID: identity.accountID,
                repository: identity.repository,
                pullRequest: identity.number,
                operation: operation,
                authorization: mutation.authorization
            )
            try validate(identity)
            try validate(snapshot, identity: identity)
            guard snapshot.context.head == detailsHead,
                  snapshot.context.base == detailsBase,
                  snapshot.context.state == summary.state,
                  snapshot.context.isDraft == summary.isDraft,
                  snapshot.context.updatedAt == summary.updatedAt
            else {
                throw RepositoryPullRequestReviewServiceError.stalePullRequest
            }
            let completeContext = try ForgePullRequestMutationContext(
                accountID: identity.accountID,
                repository: identity.repository,
                number: identity.number,
                state: snapshot.context.state,
                isDraft: snapshot.context.isDraft,
                head: snapshot.context.head,
                base: snapshot.context.base,
                updatedAt: snapshot.context.updatedAt,
                allowedOperations: readContext.allowedOperations,
                environment: readContext.environment
            )
            return (
                ForgePullRequestMergeSnapshot(
                    context: completeContext,
                    viewerCanMerge: snapshot.viewerCanMerge,
                    enabledMethods: snapshot.enabledMethods,
                    warnings: snapshot.warnings,
                    queueState: snapshot.queueState
                ),
                false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Merge-state preflight failed; retaining a nonfresh review workspace")
            if let previous,
               previous.displayedHead == detailsHead.commit,
               previous.base == detailsBase,
               previous.mutationContext.state == summary.state,
               previous.isDraft == summary.isDraft
            {
                return (previous.mergeSnapshot, true)
            }
            return try (
                unavailableMergeSnapshot(
                    identity: identity,
                    readContext: readContext,
                    detailsHead: detailsHead,
                    detailsBase: detailsBase,
                    summary: summary
                ),
                true
            )
        }
    }

    private func completeDetails(
        initial: GitHubReadResult<ForgePullRequestDetailsPage>,
        identity: RepositoryPullRequestReviewIdentity,
        readContext: ForgeGitHubPullRequestReviewReadContext
    ) async throws -> (page: ForgePullRequestDetailsPage, didFail: Bool) {
        var page = initial.value
        let baseline = initial.value.details.summary
        var didFail = !initial.problems.isEmpty
            || Self.hasUnexplainedPartialDetails(initial)

        var seenTimelineCursors: Set<ForgePageCursor> = []
        var timelineCursor = Self.timelineCursor(in: initial.value.details.timeline)
        while let cursor = timelineCursor {
            guard seenTimelineCursors.insert(cursor).inserted else {
                didFail = true
                logger.error("Pull Request timeline pagination repeated a cursor; stopping fail closed")
                break
            }
            do {
                let result = try await readContext.readAdapter.pullRequestDetails(
                    repository: identity.repository,
                    number: identity.number,
                    timelinePageSize: 100,
                    timelineAfter: cursor,
                    checkPageSize: 100,
                    checkAfter: nil
                )
                try validate(result.ownership, context: readContext, identity: identity)
                try Self.validateContinuation(result.value, baseline: baseline)
                page = try Self.mergingTimeline(result.value, into: page)
                didFail = didFail || !result.problems.isEmpty
                    || Self.hasUnexplainedPartialDetails(result)
                timelineCursor = Self.timelineCursor(in: result.value.details.timeline)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                didFail = true
                logger.error("Pull Request timeline page failed; retaining usable partial details")
                break
            }
        }

        var seenCheckCursors: Set<ForgePageCursor> = []
        var checkCursor = page.nextCheckCursor
        while let cursor = checkCursor {
            guard seenCheckCursors.insert(cursor).inserted else {
                didFail = true
                logger.error("Pull Request check pagination repeated a cursor; stopping fail closed")
                break
            }
            do {
                let result = try await readContext.readAdapter.pullRequestDetails(
                    repository: identity.repository,
                    number: identity.number,
                    timelinePageSize: 100,
                    timelineAfter: nil,
                    checkPageSize: 100,
                    checkAfter: cursor
                )
                try validate(result.ownership, context: readContext, identity: identity)
                try Self.validateContinuation(result.value, baseline: baseline)
                page = try Self.mergingChecks(result.value, into: page)
                didFail = didFail || !result.problems.isEmpty
                    || Self.hasUnexplainedPartialDetails(result)
                checkCursor = result.value.nextCheckCursor
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                didFail = true
                logger.error("Pull Request check page failed; retaining usable partial details")
                break
            }
        }

        didFail = didFail || !Self.detailsAreStructurallyComplete(page)
        return (page, didFail)
    }

    private static func timelineCursor(
        in timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) -> ForgePageCursor? {
        guard case let .available(page) = timeline else { return nil }
        return page.nextCursor
    }

    private static func validateContinuation(
        _ page: ForgePullRequestDetailsPage,
        baseline: ForgePullRequestSummary
    ) throws {
        let summary = page.details.summary
        guard summary.repository == baseline.repository,
              summary.number == baseline.number,
              summary.head == baseline.head,
              summary.base == baseline.base,
              summary.state == baseline.state,
              summary.isDraft == baseline.isDraft,
              summary.title == baseline.title,
              summary.updatedAt == baseline.updatedAt
        else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
    }

    private static func hasUnexplainedPartialDetails(
        _ result: GitHubReadResult<ForgePullRequestDetailsPage>
    ) -> Bool {
        result.completeness == .partial
            && result.value.nextCheckCursor == nil
            && timelineCursor(in: result.value.details.timeline) == nil
    }

    private static func detailsAreStructurallyComplete(
        _ page: ForgePullRequestDetailsPage
    ) -> Bool {
        let details = page.details
        let summary = details.summary
        let timelineIsCountComplete: Bool = switch details.timeline {
        case let .available(timeline):
            timeline.nextCursor == nil
                && timeline.totalCount.map { $0 == timeline.items.count } != false
        case .unavailable:
            false
        }
        return page.nextCheckCursor == nil
            && Self.isAvailable(summary.author)
            && Self.isAvailable(summary.head)
            && Self.isAvailable(summary.base)
            && Self.isAvailable(summary.labels)
            && Self.isAvailable(summary.checkRollup)
            && Self.isAvailable(summary.reviewRollup)
            && Self.isAvailable(details.bodyMarkdown)
            && Self.isAvailable(details.assignees)
            && Self.isAvailable(details.milestone)
            && Self.isAvailable(details.reviewers)
            && Self.isAvailable(details.linkedIssues)
            && Self.isAvailable(details.mergeability)
            && Self.isAvailable(details.checks)
            && timelineIsCountComplete
    }

    private static func isAvailable<Value>(_ section: ForgeReadSection<Value>) -> Bool {
        if case .available = section {
            return true
        }
        return false
    }

    private static func mergingTimeline(
        _ next: ForgePullRequestDetailsPage,
        into current: ForgePullRequestDetailsPage
    ) throws -> ForgePullRequestDetailsPage {
        guard case let .available(currentTimeline) = current.details.timeline,
              case let .available(nextTimeline) = next.details.timeline
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
        var identifiers = Set(currentTimeline.items.map(\.id))
        let timeline = try ForgePage(
            items: currentTimeline.items + nextTimeline.items.filter { identifiers.insert($0.id).inserted },
            nextCursor: nextTimeline.nextCursor,
            totalCount: nextTimeline.totalCount ?? currentTimeline.totalCount
        )
        let details = try ForgePullRequestDetails(
            summary: current.details.summary,
            bodyMarkdown: current.details.bodyMarkdown,
            assignees: current.details.assignees,
            milestone: current.details.milestone,
            reviewers: current.details.reviewers,
            linkedIssues: current.details.linkedIssues,
            mergeability: current.details.mergeability,
            checks: current.details.checks,
            timeline: .available(timeline)
        )
        return ForgePullRequestDetailsPage(
            details: details,
            nextCheckCursor: current.nextCheckCursor
        )
    }

    private static func mergingChecks(
        _ next: ForgePullRequestDetailsPage,
        into current: ForgePullRequestDetailsPage
    ) throws -> ForgePullRequestDetailsPage {
        guard case let .available(currentChecks) = current.details.checks,
              case let .available(nextChecks) = next.details.checks
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
        let checks = RepositoryPullRequestCheckPagination.merging(currentChecks, with: nextChecks)
        let details = try ForgePullRequestDetails(
            summary: current.details.summary,
            bodyMarkdown: current.details.bodyMarkdown,
            assignees: current.details.assignees,
            milestone: current.details.milestone,
            reviewers: current.details.reviewers,
            linkedIssues: current.details.linkedIssues,
            mergeability: current.details.mergeability,
            checks: .available(checks),
            timeline: current.details.timeline
        )
        return ForgePullRequestDetailsPage(
            details: details,
            nextCheckCursor: next.nextCheckCursor
        )
    }

    private func unavailableMergeSnapshot(
        identity: RepositoryPullRequestReviewIdentity,
        readContext: ForgeGitHubPullRequestReviewReadContext,
        detailsHead: ForgeBranchReference,
        detailsBase: ForgeBranchReference,
        summary: ForgePullRequestSummary
    ) throws -> ForgePullRequestMergeSnapshot {
        let context = try ForgePullRequestMutationContext(
            accountID: identity.accountID,
            repository: identity.repository,
            number: identity.number,
            state: summary.state,
            isDraft: summary.isDraft,
            head: detailsHead,
            base: detailsBase,
            updatedAt: summary.updatedAt,
            allowedOperations: readContext.allowedOperations,
            environment: readContext.environment
        )
        return ForgePullRequestMergeSnapshot(
            context: context,
            viewerCanMerge: false,
            enabledMethods: []
        )
    }

    private func initialDeletionSnapshot(
        identity: RepositoryPullRequestReviewIdentity,
        merge: ForgePullRequestMergeSnapshot
    ) async throws -> (snapshot: ForgeHeadBranchDeletionSnapshot?, didFail: Bool) {
        guard merge.context.allowedOperations.contains(.deleteHeadBranch),
              merge.context.state == .open || merge.context.state == .merged,
              merge.context.head.repository == identity.repository
        else {
            return (nil, false)
        }
        do {
            let context = try await mutationContext(identity: identity, operation: .deleteHeadBranch)
            let checkedOutHead = try await localService.checkedOutHead()
            try Task.checkCancellation()
            try validate(identity)
            let snapshot = try await context.mutationAdapter.freshHeadBranchDeletionSnapshot(
                accountID: identity.accountID,
                repository: identity.repository,
                pullRequest: identity.number,
                branch: merge.context.head.name,
                expectedHead: merge.context.head.commit,
                hasCheckedOutSafetyConflict: checkedOutHead == merge.context.head.commit,
                authorization: context.authorization
            )
            try validate(identity)
            try validate(snapshot.mergeSnapshot, identity: identity)
            guard snapshot.mergeSnapshot.context.head == merge.context.head,
                  snapshot.mergeSnapshot.context.base == merge.context.base,
                  snapshot.mergeSnapshot.context.state == merge.context.state,
                  snapshot.mergeSnapshot.context.isDraft == merge.context.isDraft,
                  snapshot.mergeSnapshot.context.updatedAt == merge.context.updatedAt
            else {
                throw RepositoryPullRequestReviewServiceError.stalePullRequest
            }
            return (
                ForgeHeadBranchDeletionSnapshot(
                    mergeSnapshot: ForgePullRequestMergeSnapshot(
                        context: merge.context,
                        viewerCanMerge: snapshot.mergeSnapshot.viewerCanMerge,
                        enabledMethods: snapshot.mergeSnapshot.enabledMethods,
                        warnings: snapshot.mergeSnapshot.warnings,
                        queueState: snapshot.mergeSnapshot.queueState
                    ),
                    isSameRepository: snapshot.isSameRepository,
                    isDefaultBranch: snapshot.isDefaultBranch,
                    isProtected: snapshot.isProtected,
                    viewerCanDelete: snapshot.viewerCanDelete,
                    hasCheckedOutSafetyConflict: snapshot.hasCheckedOutSafetyConflict
                ),
                false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.info("Optional head-branch deletion preflight is unavailable")
            return (nil, false)
        }
    }

    private func reviewThreads(
        identity: RepositoryPullRequestReviewIdentity,
        readContext: ForgeGitHubPullRequestReviewReadContext,
        previous: [RepositoryPullRequestReviewThreadRecord]
    ) async throws -> RepositoryPullRequestReviewThreadPageLoad {
        var values: [ForgeReviewThread] = []
        var seenThreads: Set<ForgeObjectID> = []
        var seenCursors: Set<ForgePageCursor> = []
        var cursor: ForgePageCursor?
        var didFail = false
        var reportedTotal: Int?
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map {
            ($0.presentation.thread.id, $0.presentation.thread)
        })

        do {
            repeat {
                if let cursor, !seenCursors.insert(cursor).inserted {
                    didFail = true
                    logger.error("Review-thread pagination repeated a cursor; stopping fail closed")
                    break
                }
                let result = try await readContext.readAdapter.reviewThreads(
                    repository: identity.repository,
                    pullRequestNumber: identity.number,
                    pageSize: 100,
                    after: cursor,
                    initialCommentCount: 100
                )
                try validate(result.ownership, context: readContext, identity: identity)
                let paginationExplainsPartial = result.value.nextCursor != nil
                    || result.value.items.contains(where: Self.threadHasPendingComments)
                didFail = didFail || !result.problems.isEmpty
                    || (result.completeness == .partial && !paginationExplainsPartial)
                if let total = result.value.totalCount {
                    if let reportedTotal, reportedTotal != total {
                        didFail = true
                    } else {
                        reportedTotal = total
                    }
                }
                for thread in result.value.items where seenThreads.insert(thread.id).inserted {
                    let completed = try await completeComments(
                        thread: thread,
                        readContext: readContext,
                        previous: previousByID[thread.id]
                    )
                    values.append(completed.thread)
                    didFail = didFail || completed.didFail
                }
                cursor = result.value.nextCursor
            } while cursor != nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            didFail = true
            logger.error("Review-thread page failed; preserving partial and last-good thread data")
        }

        if let reportedTotal, reportedTotal != seenThreads.count {
            didFail = true
        }
        if values.contains(where: { !Self.threadIsStructurallyComplete($0) }) {
            didFail = true
        }

        if didFail {
            values = try RepositoryPullRequestReviewPartialDataPolicy.preservingMissingThreads(
                fresh: values,
                previous: previous
            )
        }
        return RepositoryPullRequestReviewThreadPageLoad(threads: values, didFail: didFail)
    }

    private func completeComments(
        thread: ForgeReviewThread,
        readContext: ForgeGitHubPullRequestReviewReadContext,
        previous: ForgeReviewThread?
    ) async throws -> (thread: ForgeReviewThread, didFail: Bool) {
        guard case let .available(initialPage) = thread.comments else {
            return (thread, true)
        }
        guard initialPage.nextCursor != nil else {
            let isComplete = initialPage.totalCount.map { $0 == initialPage.items.count } != false
            return (thread, !isComplete)
        }
        var comments = initialPage.items
        var seenIDs = Set(comments.map(\.id))
        var seenCursors: Set<ForgePageCursor> = []
        var cursor = initialPage.nextCursor
        var didFail = false
        do {
            while let next = cursor {
                guard seenCursors.insert(next).inserted else {
                    didFail = true
                    logger.error("Review-comment pagination repeated a cursor; stopping fail closed")
                    break
                }
                let result = try await readContext.readAdapter.reviewThreadComments(
                    repository: thread.repository,
                    threadID: thread.id,
                    pageSize: 100,
                    after: next
                )
                guard result.ownership.credential == readContext.credential,
                      result.ownership.repository == thread.repository
                else {
                    throw RepositoryPullRequestReviewServiceError.invalidWorkspace
                }
                didFail = didFail || !result.problems.isEmpty
                    || (result.completeness == .partial && result.value.nextCursor == nil)
                comments.append(contentsOf: result.value.items.filter { seenIDs.insert($0.id).inserted })
                cursor = result.value.nextCursor
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            didFail = true
            logger.error("Review-comment page failed; preserving known comments with a tombstone")
        }

        if let totalCount = initialPage.totalCount, totalCount != comments.count {
            didFail = true
        }

        if didFail {
            let known = RepositoryPullRequestReviewPartialDataPolicy.mergingKnownComments(
                fresh: comments,
                previous: previous
            )
            return try (
                RepositoryPullRequestReviewPartialDataPolicy.markingCommentsPartial(
                    in: thread,
                    knownComments: known
                ),
                true
            )
        }
        return try (
            ForgeReviewThread(
                repository: thread.repository,
                id: thread.id,
                isResolved: thread.isResolved,
                isOutdated: thread.isOutdated,
                anchor: thread.anchor,
                comments: .available(ForgePage(
                    items: comments,
                    totalCount: initialPage.totalCount ?? comments.count
                ))
            ),
            false
        )
    }

    private static func threadIsStructurallyComplete(_ thread: ForgeReviewThread) -> Bool {
        guard case .available = thread.anchor,
              case let .available(comments) = thread.comments,
              comments.nextCursor == nil
        else {
            return false
        }
        return comments.totalCount.map { $0 == comments.items.count } != false
    }

    private static func threadHasPendingComments(_ thread: ForgeReviewThread) -> Bool {
        guard case let .available(comments) = thread.comments else { return false }
        return comments.nextCursor != nil
    }

    private func reviewThreadRecord(
        _ thread: ForgeReviewThread,
        identity: RepositoryPullRequestReviewIdentity,
        displayedHead: ForgeCommitID
    ) async throws -> RepositoryPullRequestReviewThreadRecord {
        guard thread.repository == identity.repository,
              thread.id.forge == identity.repository.forge
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
        var visibility: [ForgeObjectID: ForgeReviewCommentVisibility] = [:]
        var reactions: [ForgeObjectID: [ForgeReviewReactionSummary]] = [:]
        var suggestedChanges: [ForgeSuggestedChange] = []
        let comments: [ForgeReviewComment] = switch thread.comments {
        case let .available(page): page.items
        case .unavailable: []
        }
        for comment in comments {
            guard comment.repository == identity.repository,
                  comment.id.forge == identity.repository.forge
            else {
                throw RepositoryPullRequestReviewServiceError.invalidWorkspace
            }
            visibility[comment.id] = comment.isMinimized
                ? .minimized(reason: comment.minimizedReason ?? "Reason unavailable")
                : .ordinary
            if !comment.reactions.isEmpty {
                reactions[comment.id] = comment.reactions
            }
        }

        let anchor: ForgeReviewAnchor? = switch thread.anchor {
        case let .available(value): value
        case .unavailable: nil
        }
        if !thread.isOutdated, let anchor {
            suggestedChanges = comments.filter { !$0.isMinimized }.compactMap {
                RepositoryPullRequestSuggestedChangePolicy.change(
                    comment: $0,
                    anchor: anchor,
                    pullRequest: identity.number,
                    displayedHead: displayedHead
                )
            }
        }
        let localAnchor = await exactOutdatedLocalAnchor(
            thread: thread,
            comments: comments,
            serverAnchor: anchor,
            identity: identity,
            displayedHead: displayedHead
        )
        return try RepositoryPullRequestReviewThreadRecord(
            pullRequest: identity.number,
            presentation: ForgeReviewThreadPresentation(
                thread: thread,
                commentVisibility: visibility,
                commentReactions: reactions
            ),
            exactOutdatedLocalAnchor: localAnchor,
            suggestedChanges: suggestedChanges
        )
    }

    private func exactOutdatedLocalAnchor(
        thread: ForgeReviewThread,
        comments: [ForgeReviewComment],
        serverAnchor: ForgeReviewAnchor?,
        identity: RepositoryPullRequestReviewIdentity,
        displayedHead: ForgeCommitID
    ) async -> ForgeReviewAnchor? {
        guard thread.isOutdated,
              let serverAnchor,
              let diffHunk = comments.first(where: { $0.replyToID == nil && $0.diffHunk != nil })?.diffHunk
              ?? comments.first(where: { $0.diffHunk != nil })?.diffHunk,
              let contextLines = RepositoryPullRequestSuggestedChangePolicy.exactContextLines(
                  diffHunk: diffHunk,
                  anchor: serverAnchor
              ),
              !contextLines.isEmpty,
              let context = try? ForgeReviewContext(
                  repository: identity.repository,
                  pullRequest: identity.number,
                  displayedHead: displayedHead,
                  path: serverAnchor.path,
                  lines: contextLines,
                  isTruncated: false
              )
        else {
            return nil
        }
        do {
            let candidates = try await localService.reanchorCandidates(
                for: context,
                currentHead: displayedHead
            )
            guard candidates.count == 1 else { return nil }
            return candidates[0].anchor
        } catch {
            logger.info("operation=load_review phase=reanchor transition=unavailable")
            return nil
        }
    }

    private func pendingUnknownOperations(
        identity: RepositoryPullRequestReviewIdentity
    ) async -> (operations: Set<ForgeOperation>, didFail: Bool) {
        guard let unknownOutcomes else { return ([], false) }
        var pending: Set<ForgeOperation> = []
        do {
            for operation in Self.reviewOperations {
                try validate(identity)
                let records = try await unknownOutcomes.unknownOutcomes(
                    accountID: identity.accountID,
                    repository: identity.repository,
                    operation: operation,
                    scope: .pullRequest(identity.number)
                )
                try validate(identity)
                if !records.isEmpty {
                    pending.insert(operation)
                }
            }
            return (pending, false)
        } catch {
            logger.error("Could not inspect exact Pull Request unknown outcomes; disabling mutations")
            return (pending, true)
        }
    }

    private func consumeUnknownOperations(
        _ operations: Set<ForgeOperation>,
        identity: RepositoryPullRequestReviewIdentity
    ) async -> Bool {
        guard let unknownOutcomes else { return operations.isEmpty }
        do {
            for operation in operations {
                guard currentBinding() == binding else { return false }
                _ = try await unknownOutcomes.consumeUnknownOutcomes(
                    accountID: identity.accountID,
                    repository: identity.repository,
                    operation: operation,
                    scope: .pullRequest(identity.number)
                )
                guard currentBinding() == binding else { return false }
            }
            logger.notice("Reconciled exact Pull Request unknown mutation outcomes after a complete refresh")
            return true
        } catch {
            logger.error("Could not consume reconciled Pull Request unknown outcomes; disabling mutations")
            return false
        }
    }

    private func mutationContext(
        identity: RepositoryPullRequestReviewIdentity,
        operation: ForgeOperation
    ) async throws -> ForgeGitHubPullRequestReviewMutationContext {
        do {
            let context = try await dependencies.reviewMutationContext(
                accountID: identity.accountID,
                repository: identity.repository,
                operation: operation
            )
            try validate(identity)
            try validate(context, identity: identity, operation: operation)
            return context
        } catch {
            throw Self.mapComposition(error)
        }
    }

    private func identity(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber
    ) throws -> RepositoryPullRequestReviewIdentity {
        let identity = try RepositoryPullRequestReviewIdentity(
            accountID: accountID,
            repository: repository,
            number: number
        )
        try validate(identity)
        return identity
    }

    private func validate(_ identity: RepositoryPullRequestReviewIdentity) throws {
        guard currentBinding() == binding,
              binding.primaryRepository == identity.repository,
              binding.preferredAccount == identity.accountID
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func validate(
        _ context: ForgeGitHubPullRequestReviewReadContext,
        identity: RepositoryPullRequestReviewIdentity
    ) throws {
        guard context.account.id == identity.accountID,
              context.credential.accountID == identity.accountID,
              context.account.currentCredential.reference == context.credential,
              context.credential.accountID.forge == identity.repository.forge
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func validate(
        _ context: ForgeGitHubPullRequestReviewMutationContext,
        identity: RepositoryPullRequestReviewIdentity,
        operation: ForgeOperation
    ) throws {
        guard context.account.id == identity.accountID,
              context.credential.accountID == identity.accountID,
              context.account.currentCredential.reference == context.credential,
              context.authorization.key.credential == context.credential,
              context.authorization.key.repository == identity.repository,
              context.authorization.key.operation == operation
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func validate(
        _ ownership: GitHubReadOwnership,
        context: ForgeGitHubPullRequestReviewReadContext,
        identity: RepositoryPullRequestReviewIdentity
    ) throws {
        guard ownership.credential == context.credential,
              ownership.repository == identity.repository
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private func validate(
        _ snapshot: ForgePullRequestMergeSnapshot,
        identity: RepositoryPullRequestReviewIdentity
    ) throws {
        let context = snapshot.context
        guard context.accountID == identity.accountID,
              context.repository == identity.repository,
              context.number == identity.number,
              context.head.repository.forge == identity.repository.forge,
              context.base.repository == identity.repository
        else {
            throw RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    @discardableResult
    private func requireCurrentWorkspace(
        _ identity: RepositoryPullRequestReviewIdentity
    ) throws -> RepositoryPullRequestReviewWorkspace {
        guard let lastWorkspace,
              lastWorkspace.identity == identity,
              lastWorkspace.isMutationStateFresh
        else {
            throw RepositoryPullRequestReviewServiceError.stalePullRequest
        }
        return lastWorkspace
    }

    private func map(_ error: GitHubMutationError) -> Error {
        switch error {
        case .offline:
            RepositoryPullRequestReviewServiceError.offline
        case let .cooldown(until):
            RepositoryPullRequestReviewServiceError.rateLimited(until: until)
        case let .rateLimited(response):
            response.rateLimit.cooldownDeadline(statusCode: response.statusCode, now: now())
                .map(RepositoryPullRequestReviewServiceError.rateLimited(until:))
                ?? RepositoryPullRequestReviewServiceError.authoritative(error.localizedDescription)
        case let .authoritative(problems, _):
            RepositoryPullRequestReviewServiceError.authoritative(
                problems.first?.authoritativeMessage ?? error.localizedDescription
            )
        case .outcomeUnknown:
            RepositoryPullRequestReviewServiceError.outcomeUnknown
        case .stalePullRequest, .authorizationMismatch:
            RepositoryPullRequestReviewServiceError.stalePullRequest
        case .capabilityUnavailable, .explicitConfirmationRequired:
            RepositoryPullRequestReviewServiceError.unavailable
        default:
            RepositoryPullRequestReviewServiceError.authoritative(error.localizedDescription)
        }
    }

    private static func mapComposition(_ error: Error) -> Error {
        guard let error = error as? ForgeGitHubPullRequestCompositionError else { return error }
        return switch error {
        case .offline:
            RepositoryPullRequestReviewServiceError.offline
        case let .rateLimited(until):
            RepositoryPullRequestReviewServiceError.rateLimited(until: until)
        case .outcomeUnknown:
            RepositoryPullRequestReviewServiceError.outcomeUnknown
        case let .authoritative(message):
            RepositoryPullRequestReviewServiceError.authoritative(message)
        case .capabilityUnavailable:
            RepositoryPullRequestReviewServiceError.unavailable
        default:
            RepositoryPullRequestReviewServiceError.invalidWorkspace
        }
    }

    private static func timelineIsComplete(
        _ timeline: ForgeReadSection<ForgePage<ForgeTimelineItem>>
    ) -> Bool {
        switch timeline {
        case let .available(page):
            page.nextCursor == nil
        case .unavailable:
            false
        }
    }
}
