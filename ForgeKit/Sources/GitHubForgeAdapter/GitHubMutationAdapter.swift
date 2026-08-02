import Apollo
import ApolloAPI
import ForgeKit
import Foundation
import os

/// Executes GitHub.com Pull Request and review mutations while keeping Apollo
/// and generated schema values inside the adapter target.
public actor GitHubMutationAdapter {
    private let expectedCredential: ForgeCredentialReference
    private let credentialAuthority: any GitHubReadCredentialAuthority
    private let sessionConfiguration: URLSessionConfiguration
    private let installationConfigurationURL: URL?
    private let restClient: any GitHubMutationHTTPClient
    private let sessionGate: GitHubMutationSessionGate
    private let store = ApolloStore(cache: InMemoryNormalizedCache())
    private let mapper: GitHubMutationMapper
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "github-mutation")
    private var resolutionGenerations: [ForgeObjectID: UInt64] = [:]
    private var activeResolutionThreads: Set<ForgeObjectID> = []
    private var resolutionWaiters: [ForgeObjectID: [CheckedContinuation<UInt64, Never>]] = [:]

    public init(
        expectedCredential: ForgeCredentialReference,
        credentialAuthority: any GitHubReadCredentialAuthority,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        sessionGate: GitHubMutationSessionGate = .shared,
        installationConfigurationURL: URL? = nil
    ) {
        self.expectedCredential = expectedCredential
        self.credentialAuthority = credentialAuthority
        self.sessionConfiguration = sessionConfiguration
        self.sessionGate = sessionGate
        self.installationConfigurationURL = installationConfigurationURL
        restClient = GitHubMutationURLSessionClient(configuration: sessionConfiguration)
        mapper = GitHubMutationMapper(forge: Self.gitHubForge)
        now = Date.init
    }

    init(
        expectedCredential: ForgeCredentialReference,
        credentialAuthority: any GitHubReadCredentialAuthority,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        restClient: any GitHubMutationHTTPClient,
        sessionGate: GitHubMutationSessionGate = GitHubMutationSessionGate(),
        now: @escaping @Sendable () -> Date,
        installationConfigurationURL: URL? = nil
    ) {
        self.expectedCredential = expectedCredential
        self.credentialAuthority = credentialAuthority
        self.sessionConfiguration = sessionConfiguration
        self.restClient = restClient
        self.sessionGate = sessionGate
        self.installationConfigurationURL = installationConfigurationURL
        mapper = GitHubMutationMapper(forge: Self.gitHubForge)
        self.now = now
    }

    public func createPullRequest(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestCreationOutcome> {
        let authentication = try await authenticate(
            accountID: accountID,
            repository: form.repository,
            operation: .createPullRequest,
            authorization: authorization
        )
        var cursor: String?
        var requestedCursors = Set<String>()
        var repositoryID: String?
        var headRepositoryID: String?
        repeat {
            if let cursor, !requestedCursors.insert(cursor).inserted {
                logger.error(
                    "operation=createPullRequest phase=preflight failure=cyclic_pagination"
                )
                throw GitHubMutationError.malformedResponse
            }
            let query = GitHubAPI.GitHubPullRequestCreationPreflightQuery(
                owner: form.repository.owner,
                name: form.repository.name,
                headOwner: form.head.repository.owner,
                headName: form.head.repository.name,
                baseRefName: form.base.name.value,
                headRefName: form.head.name.value,
                after: nullable(cursor)
            )
            let executed = try await executePreflight(
                query,
                authentication: authentication
            ) { data in
                try mapper.creationPage(
                    data,
                    expectedRepository: form.repository,
                    expectedHeadRepository: form.head.repository
                )
            }
            let page = executed.value
            repositoryID = repositoryID ?? page.repositoryID
            headRepositoryID = headRepositoryID ?? page.headRepositoryID
            guard repositoryID == page.repositoryID,
                  headRepositoryID == page.headRepositoryID
            else {
                throw GitHubMutationError.authorizationMismatch
            }
            if let existing = page.snapshots.first(where: {
                $0.state == .open
                    && $0.base.repository == form.base.repository
                    && $0.base.name == form.base.name
                    && $0.head.repository == form.head.repository
                    && $0.head.name == form.head.name
            }) {
                return result(
                    value: .existing(existing),
                    response: executed.response,
                    repository: form.repository,
                    operation: .createPullRequest
                )
            }
            cursor = page.nextCursor
        } while cursor != nil

        guard let repositoryID, let headRepositoryID else {
            throw GitHubMutationError.malformedResponse
        }
        let mutation = GitHubAPI.GitHubCreatePullRequestMutation(input: .init(
            baseRefName: form.base.name.value,
            body: .some(form.bodyMarkdown),
            draft: .some(form.isDraft),
            headRefName: form.head.name.value,
            headRepositoryId: .some(headRepositoryID),
            repositoryId: repositoryID,
            title: form.title
        ))
        let executed = try await executeMutation(
            mutation,
            authentication: authentication
        ) { data in
            guard let fragment = data.createPullRequest?.pullRequest?
                .fragments.gitHubPullRequestMutationSnapshot
            else {
                throw GitHubMutationError.malformedResponse
            }
            let snapshot = try mapper.snapshot(fragment, expectedRepository: form.repository)
            guard snapshot.base.name == form.base.name,
                  snapshot.head.repository == form.head.repository,
                  snapshot.head.name == form.head.name,
                  snapshot.head.commit == form.head.commit,
                  snapshot.title == form.title,
                  snapshot.bodyMarkdown == form.bodyMarkdown,
                  snapshot.isDraft == form.isDraft
            else {
                throw GitHubMutationError.outcomeUnknown(nil)
            }
            return GitHubPullRequestCreationOutcome.created(snapshot)
        }
        return result(
            value: executed.value,
            response: executed.response,
            repository: form.repository,
            operation: .createPullRequest
        )
    }

    public func editPullRequest(
        accountID: ForgeAccountID,
        edit: ForgePullRequestEdit,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
        let authentication = try await authenticate(
            accountID: accountID,
            repository: edit.repository,
            operation: .editPullRequest,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: edit.repository,
            number: edit.number,
            authentication: authentication
        )
        do {
            try edit.validate(current: preflight.snapshot.editableSnapshot)
        } catch ForgePullRequestWorkflowError.editConflict {
            throw GitHubMutationError.stalePullRequest
        } catch {
            throw GitHubMutationError.invalidRequest
        }
        guard preflight.viewerCanUpdate else {
            throw GitHubMutationError.capabilityUnavailable
        }
        let mutation = GitHubAPI.GitHubEditPullRequestMutation(input: .init(
            body: .some(edit.bodyMarkdown),
            pullRequestId: preflight.snapshot.id.value,
            title: .some(edit.title)
        ))
        return try await mutatePullRequest(
            mutation,
            authentication: authentication,
            repository: edit.repository,
            expectedNumber: edit.number,
            operation: .editPullRequest
        ) { snapshot in
            guard snapshot.title == edit.title,
                  snapshot.bodyMarkdown == edit.bodyMarkdown
            else {
                throw GitHubMutationError.outcomeUnknown(nil)
            }
        } fragment: {
            $0.updatePullRequest?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
        }
    }

    public func syncFork(
        accountID: ForgeAccountID,
        plan: ForgeSyncForkPlan,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubForkSyncReceipt> {
        let authentication = try await authenticate(
            accountID: accountID,
            repository: plan.fork,
            operation: .syncFork,
            authorization: authorization
        )
        let query = GitHubAPI.GitHubSyncForkPreflightQuery(
            owner: plan.fork.owner,
            name: plan.fork.name
        )
        _ = try await executePreflight(query, authentication: authentication) { data in
            try mapper.validateSyncFork(data, plan: plan)
        }
        var endpoint = URL(string: "https://api.github.com")!
        endpoint.append(path: "repos")
        endpoint.append(path: plan.fork.owner)
        endpoint.append(path: plan.fork.name)
        endpoint.append(path: "merge-upstream")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitX-ForgeKit", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(authentication.accessToken.withUnsafeUTF8Bytes {
            "Bearer \(String(decoding: $0, as: UTF8.self))"
        }, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["branch": plan.branch.value])
        let permit = try await admitRequest()
        let response: GitHubMutationHTTPResponse
        do {
            response = try await restClient.execute(request)
        } catch is CancellationError {
            logger.notice(
                "operation=syncFork phase=mutation transition=outcome_unknown reason=cancelled_after_dispatch"
            )
            throw GitHubMutationError.outcomeUnknown(nil)
        } catch let error as GitHubMutationError {
            if case let .outcomeUnknown(metadata) = error {
                throw GitHubMutationError.outcomeUnknown(metadata)
            }
            throw GitHubMutationError.outcomeUnknown(nil)
        } catch {
            throw classifyNetworkFailure(
                error,
                mutationStarted: true,
                metadata: nil,
                credentialSource: authentication.credential.source
            )
        }
        let metadata = responseMetadata(response)
        let responseIsCoolingDown = await recordCooldown(metadata)
        guard response.statusCode == 200 else {
            let error = classifyRESTFailure(
                response,
                metadata: metadata,
                credentialSource: authentication.credential.source
            )
            if case .rateLimited = error {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw error
        }
        struct Payload: Decodable {
            let mergeType: String

            enum CodingKeys: String, CodingKey {
                case mergeType = "merge_type"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.data) else {
            throw GitHubMutationError.outcomeUnknown(metadata)
        }
        if !responseIsCoolingDown {
            await sessionGate.recordSuccessfulRequest(permit)
        }
        let mergeType = GitHubForkSyncMergeType(rawValue: payload.mergeType) ?? .unknown
        return result(
            value: GitHubForkSyncReceipt(
                fork: plan.fork,
                parent: plan.parent,
                branch: plan.branch,
                mergeType: mergeType
            ),
            response: metadata,
            repository: plan.fork,
            operation: .syncFork
        )
    }
}

public extension GitHubMutationAdapter {
    /// Fetches the complete merge confirmation state immediately before the UI
    /// presents or revalidates confirmation. This is always network-only.
    func freshMergeSnapshot(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        operation: ForgeOperation = .mergePullRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> ForgePullRequestMergeSnapshot {
        let authentication = try await authenticate(
            accountID: accountID,
            repository: repository,
            operation: operation,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: repository,
            number: pullRequest,
            authentication: authentication
        )
        return try mergeSnapshot(
            preflight: preflight,
            accountID: accountID,
            allowedOperation: operation
        )
    }

    /// Combines fresh server deletion facts with the caller's current local
    /// checkout conflict. The returned provider-neutral snapshot is the only
    /// value the deletion policy should use to create a request.
    func freshHeadBranchDeletionSnapshot(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        branch: ForgeRefName,
        expectedHead: ForgeCommitID,
        hasCheckedOutSafetyConflict: Bool,
        authorization: GitHubMutationAuthorization
    ) async throws -> ForgeHeadBranchDeletionSnapshot {
        let authentication = try await authenticate(
            accountID: accountID,
            repository: repository,
            operation: .deleteHeadBranch,
            authorization: authorization
        )
        let pullRequestPreflight = try await pullRequestPreflight(
            repository: repository,
            number: pullRequest,
            authentication: authentication
        )
        guard pullRequestPreflight.snapshot.head.repository == repository else {
            throw GitHubMutationError.capabilityUnavailable
        }
        let branchPreflight = try await headBranchPreflight(
            repository: repository,
            branch: branch,
            expectedHead: expectedHead,
            authentication: authentication
        )
        return try ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot(
                preflight: pullRequestPreflight,
                accountID: accountID,
                allowedOperation: .deleteHeadBranch
            ),
            isSameRepository: pullRequestPreflight.snapshot.head.repository == repository,
            isDefaultBranch: branchPreflight.isDefaultBranch,
            isProtected: branchPreflight.isProtected,
            viewerCanDelete: branchPreflight.viewerCanDelete,
            hasCheckedOutSafetyConflict: hasCheckedOutSafetyConflict
        )
    }

    func performLifecycle(
        _ request: ForgePullRequestLifecycleRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
        let operation = request.action.operation
        let authentication = try await authenticate(
            accountID: request.accountID,
            repository: request.repository,
            operation: operation,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: request.repository,
            number: request.number,
            authentication: authentication
        )
        try validateLifecycle(request, preflight: preflight)
        switch request.action {
        case .markReady:
            let mutation = GitHubAPI.GitHubMarkPullRequestReadyMutation(input: .init(
                pullRequestId: preflight.snapshot.id.value
            ))
            return try await mutatePullRequest(
                mutation,
                authentication: authentication,
                repository: request.repository,
                expectedNumber: request.number,
                operation: operation
            ) { snapshot in
                guard snapshot.state == .open, !snapshot.isDraft else {
                    throw GitHubMutationError.outcomeUnknown(nil)
                }
            } fragment: {
                $0.markPullRequestReadyForReview?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
            }
        case .convertToDraft:
            let mutation = GitHubAPI.GitHubConvertPullRequestToDraftMutation(input: .init(
                pullRequestId: preflight.snapshot.id.value
            ))
            return try await mutatePullRequest(
                mutation,
                authentication: authentication,
                repository: request.repository,
                expectedNumber: request.number,
                operation: operation
            ) { snapshot in
                guard snapshot.state == .open, snapshot.isDraft else {
                    throw GitHubMutationError.outcomeUnknown(nil)
                }
            } fragment: {
                $0.convertPullRequestToDraft?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
            }
        case .close:
            guard preflight.viewerCanClose else { throw GitHubMutationError.capabilityUnavailable }
            let mutation = GitHubAPI.GitHubClosePullRequestMutation(input: .init(
                pullRequestId: preflight.snapshot.id.value,
                state: .some(GraphQLEnum(.closed))
            ))
            return try await mutatePullRequest(
                mutation,
                authentication: authentication,
                repository: request.repository,
                expectedNumber: request.number,
                operation: operation
            ) { snapshot in
                guard snapshot.state == .closed else {
                    throw GitHubMutationError.outcomeUnknown(nil)
                }
            } fragment: {
                $0.updatePullRequest?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
            }
        case .reopen:
            guard preflight.viewerCanReopen else { throw GitHubMutationError.capabilityUnavailable }
            let mutation = GitHubAPI.GitHubReopenPullRequestMutation(input: .init(
                pullRequestId: preflight.snapshot.id.value,
                state: .some(GraphQLEnum(.open))
            ))
            return try await mutatePullRequest(
                mutation,
                authentication: authentication,
                repository: request.repository,
                expectedNumber: request.number,
                operation: operation
            ) { snapshot in
                guard snapshot.state == .open else {
                    throw GitHubMutationError.outcomeUnknown(nil)
                }
            } fragment: {
                $0.updatePullRequest?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
            }
        case .updateBranch:
            let mutation = GitHubAPI.GitHubUpdatePullRequestBranchMutation(input: .init(
                expectedHeadOid: .some(request.expectedHead.value),
                pullRequestId: preflight.snapshot.id.value
            ))
            return try await mutatePullRequest(
                mutation,
                authentication: authentication,
                repository: request.repository,
                expectedNumber: request.number,
                operation: operation
            ) { snapshot in
                guard snapshot.head.reference != nil else {
                    throw GitHubMutationError.outcomeUnknown(nil)
                }
            } fragment: {
                $0.updatePullRequestBranch?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
            }
        }
    }

    func mergePullRequest(
        _ request: ForgePullRequestMergeRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue> {
        let confirmation = request.confirmation
        let authentication = try await authenticate(
            accountID: confirmation.accountID,
            repository: confirmation.repository,
            operation: .mergePullRequest,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: confirmation.repository,
            number: confirmation.number,
            authentication: authentication
        )
        try validateMergeConfirmation(confirmation, preflight: preflight)
        let method: GitHubAPI.PullRequestMergeMethod = switch confirmation.method {
        case .merge: .merge
        case .squash: .squash
        case .rebase: .rebase
        }
        let mutation = GitHubAPI.GitHubMergePullRequestMutation(input: .init(
            commitBody: nullable(request.message),
            commitHeadline: nullable(request.title),
            expectedHeadOid: .some(confirmation.head.value),
            mergeMethod: .some(GraphQLEnum(method)),
            pullRequestId: preflight.snapshot.id.value
        ))
        return try await mutatePullRequest(
            mutation,
            authentication: authentication,
            repository: confirmation.repository,
            expectedNumber: confirmation.number,
            operation: .mergePullRequest
        ) { snapshot in
            guard snapshot.state == .merged else {
                throw GitHubMutationError.outcomeUnknown(nil)
            }
        } fragment: {
            $0.mergePullRequest?.pullRequest?.fragments.gitHubPullRequestMutationSnapshot
        }
    }

    func changeMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubMergeQueueReceipt> {
        let operation = request.action.operation
        let authentication = try await authenticate(
            accountID: request.accountID,
            repository: request.repository,
            operation: operation,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: request.repository,
            number: request.number,
            authentication: authentication
        )
        guard preflight.snapshot.head.commit == request.expectedHead else {
            throw GitHubMutationError.stalePullRequest
        }
        let validatedAction = try validateMergeQueue(request, preflight: preflight)
        switch validatedAction {
        case .enter:
            let mutation = GitHubAPI.GitHubEnterMergeQueueMutation(input: .init(
                expectedHeadOid: .some(request.expectedHead.value),
                pullRequestId: preflight.snapshot.id.value
            ))
            let executed = try await executeMutation(mutation, authentication: authentication) { data in
                guard let entry = data.enqueuePullRequest?.mergeQueueEntry,
                      let pullRequest = entry.pullRequest
                else {
                    throw GitHubMutationError.malformedResponse
                }
                try validateMutationPullRequest(
                    repositoryFragment: pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    number: pullRequest.number,
                    expectedRepository: request.repository,
                    expectedNumber: request.number
                )
                guard try ForgeCommitID(pullRequest.headRefOid) == request.expectedHead else {
                    throw GitHubMutationError.stalePullRequest
                }
                return try GitHubMergeQueueReceipt(
                    repository: request.repository,
                    pullRequest: request.number,
                    entryID: mapper.objectID(entry.id),
                    action: .enter
                )
            }
            return result(
                value: executed.value,
                response: executed.response,
                repository: request.repository,
                operation: operation
            )
        case let .leave(entryID):
            // GitHub's dequeuePullRequest input is the Pull Request node ID,
            // not the merge-queue-entry ID returned by the preflight.
            let mutation = GitHubAPI.GitHubLeaveMergeQueueMutation(input: .init(
                id: preflight.snapshot.id.value
            ))
            let executed = try await executeMutation(mutation, authentication: authentication) { data in
                guard let entry = data.dequeuePullRequest?.mergeQueueEntry,
                      let pullRequest = entry.pullRequest
                else {
                    throw GitHubMutationError.malformedResponse
                }
                try validateMutationPullRequest(
                    repositoryFragment: pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    number: pullRequest.number,
                    expectedRepository: request.repository,
                    expectedNumber: request.number
                )
                guard try mapper.objectID(entry.id) == entryID else {
                    throw GitHubMutationError.authorizationMismatch
                }
                return GitHubMergeQueueReceipt(
                    repository: request.repository,
                    pullRequest: request.number,
                    entryID: entryID,
                    action: .leave
                )
            }
            return result(
                value: executed.value,
                response: executed.response,
                repository: request.repository,
                operation: operation
            )
        }
    }

    func deleteHeadBranch(
        _ request: ForgeHeadBranchDeletionRequest,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubHeadBranchDeletionReceipt> {
        let authentication = try await authenticate(
            accountID: request.accountID,
            repository: request.repository,
            operation: .deleteHeadBranch,
            authorization: authorization
        )
        let pullRequestPreflight = try await pullRequestPreflight(
            repository: request.repository,
            number: request.pullRequest,
            authentication: authentication
        )
        guard pullRequestPreflight.snapshot.head.repository == request.repository else {
            throw GitHubMutationError.capabilityUnavailable
        }
        let preflight = try await headBranchPreflight(
            repository: request.repository,
            branch: request.branch,
            expectedHead: request.expectedHead,
            authentication: authentication
        )
        let deletionSnapshot = try ForgeHeadBranchDeletionSnapshot(
            mergeSnapshot: mergeSnapshot(
                preflight: pullRequestPreflight,
                accountID: request.accountID,
                allowedOperation: .deleteHeadBranch
            ),
            isSameRepository: pullRequestPreflight.snapshot.head.repository == request.repository,
            isDefaultBranch: preflight.isDefaultBranch,
            isProtected: preflight.isProtected,
            viewerCanDelete: preflight.viewerCanDelete,
            hasCheckedOutSafetyConflict: false
        )
        guard case let .available(validated) = ForgeHeadBranchDeletionPolicy.decision(
            snapshot: deletionSnapshot,
            mergeWasQueued: false
        ), validated == request else {
            throw GitHubMutationError.stalePullRequest
        }
        let mutation = GitHubAPI.GitHubDeleteHeadBranchMutation(input: .init(
            refId: preflight.refID.value
        ))
        let executed = try await executeMutation(mutation, authentication: authentication) { data in
            guard data.deleteRef != nil else { throw GitHubMutationError.malformedResponse }
            return GitHubHeadBranchDeletionReceipt(
                repository: request.repository,
                branch: request.branch,
                deletedHead: request.expectedHead
            )
        }
        return result(
            value: executed.value,
            response: executed.response,
            repository: request.repository,
            operation: .deleteHeadBranch
        )
    }
}

private struct GitHubExecutedMutation<Value: Sendable>: Sendable {
    let value: Value
    let response: GitHubResponseMetadata
}

private enum GitHubValidatedMergeQueueAction {
    case enter
    case leave(entryID: ForgeObjectID)
}

private extension GitHubMutationAdapter {
    nonisolated static var gitHubForge: ForgeIdentity {
        ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com"))
    }

    func authenticate(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubReadAuthentication {
        guard repository.forge == Self.gitHubForge else {
            throw GitHubMutationError.githubDotComRequired
        }
        let expectedKey = ForgeCapabilityKey(
            credential: expectedCredential,
            repository: repository,
            operation: operation
        )
        guard accountID == expectedCredential.accountID,
              authorization.key == expectedKey
        else {
            throw GitHubMutationError.authorizationMismatch
        }
        switch await sessionGate.environment(for: expectedCredential, at: now()) {
        case .available:
            break
        case .offline:
            throw GitHubMutationError.offline
        case let .rateLimited(until):
            throw GitHubMutationError.cooldown(until: until)
        }
        guard let authentication = try await credentialAuthority.currentAuthentication(
            for: expectedCredential
        ),
            authentication.account.id == accountID,
            authentication.account.currentCredential == authentication.credential,
            authentication.credential.reference == expectedCredential,
            authentication.credential.expiresAt.map({ $0 > now() }) ?? true
        else {
            throw GitHubMutationError.authenticationRequired
        }
        logger.debug(
            "operation=\(String(describing: operation), privacy: .public) phase=gate state=available"
        )
        return authentication
    }

    func admitRequest() async throws -> GitHubCredentialRequestPermit {
        switch await sessionGate.admitRequest(for: expectedCredential, at: now()) {
        case let .allowed(permit):
            return permit
        case .offline:
            throw GitHubMutationError.offline
        case let .rateLimited(until):
            throw GitHubMutationError.cooldown(until: until)
        }
    }

    func pullRequestPreflight(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        authentication: GitHubReadAuthentication
    ) async throws -> GitHubPullRequestMutationPreflight {
        guard let number = Int32(exactly: number.rawValue) else {
            throw GitHubMutationError.invalidRequest
        }
        let query = GitHubAPI.GitHubPullRequestMutationPreflightQuery(
            owner: repository.owner,
            name: repository.name,
            number: number
        )
        return try await executePreflight(query, authentication: authentication) { data in
            try mapper.pullRequestPreflight(data, expectedRepository: repository)
        }.value
    }

    func reviewThreadPreflight(
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        threadID: ForgeObjectID,
        authentication: GitHubReadAuthentication
    ) async throws -> GitHubReviewThreadMutationPreflight {
        guard threadID.forge == repository.forge else {
            throw GitHubMutationError.authorizationMismatch
        }
        let query = GitHubAPI.GitHubReviewThreadMutationPreflightQuery(id: threadID.value)
        return try await executePreflight(query, authentication: authentication) { data in
            try mapper.reviewThreadPreflight(
                data,
                expectedID: threadID,
                expectedRepository: repository,
                expectedPullRequest: pullRequest
            )
        }.value
    }

    func headBranchPreflight(
        repository: ForgeRepositoryIdentity,
        branch: ForgeRefName,
        expectedHead: ForgeCommitID,
        authentication: GitHubReadAuthentication
    ) async throws -> GitHubHeadBranchMutationPreflight {
        let query = GitHubAPI.GitHubHeadBranchDeletionPreflightQuery(
            owner: repository.owner,
            name: repository.name,
            qualifiedName: "refs/heads/\(branch.value)"
        )
        return try await executePreflight(query, authentication: authentication) { data in
            try mapper.headBranchPreflight(
                data,
                expectedRepository: repository,
                expectedBranch: branch,
                expectedHead: expectedHead
            )
        }.value
    }

    func executePreflight<Query: GraphQLQuery, Value: Sendable>(
        _ query: Query,
        authentication: GitHubReadAuthentication,
        map: (Query.Data) throws -> Value
    ) async throws -> GitHubExecutedMutation<Value> where Query.ResponseFormat == SingleResponseFormat {
        let permit = try await admitRequest()
        let metadataBox = GitHubResponseMetadataBox(
            installationConfigurationURL: installationConfigurationURL
        )
        let client = GitHubGraphQLTransportFactory.makeClient(
            accessToken: authentication.accessToken,
            sessionConfiguration: sessionConfiguration,
            metadataBox: metadataBox,
            store: store
        )
        let startedAt = ContinuousClock.now
        do {
            let graphQLResponse = try await client.fetch(query: query, cachePolicy: .networkOnly)
            guard let response = metadataBox.take() else {
                throw GitHubMutationError.malformedResponse
            }
            let responseIsCoolingDown = await recordCooldown(response)
            let problems = mutationProblems(graphQLResponse.errors)
            if let authorizationError = authorizationError(
                response: response,
                credentialSource: authentication.credential.source
            ) {
                throw authorizationError
            }
            if problems.contains(where: { $0.classification == "RATE_LIMITED" }) {
                await recordCooldown(response, assumeThrottled: true)
                throw GitHubMutationError.rateLimited(response)
            }
            guard problems.isEmpty else {
                throw GitHubMutationError.authoritative(problems, response)
            }
            guard let data = graphQLResponse.data else {
                throw GitHubMutationError.malformedResponse
            }
            let value = try map(data)
            if !responseIsCoolingDown {
                await sessionGate.recordSuccessfulRequest(permit)
            }
            logger.info(
                "operation=\(Query.operationName, privacy: .public) phase=preflight status=\(response.statusCode) duration=\(String(describing: ContinuousClock.now - startedAt), privacy: .public)"
            )
            return GitHubExecutedMutation(value: value, response: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubMutationError {
            if case let .rateLimited(metadata) = error {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw error
        } catch {
            let metadata = metadataBox.take()
            let classified = classifyNetworkFailure(
                error,
                mutationStarted: false,
                metadata: metadata,
                credentialSource: authentication.credential.source
            )
            if case .rateLimited = classified, let metadata {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw classified
        }
    }

    func executeMutation<Mutation: GraphQLMutation, Value: Sendable>(
        _ mutation: Mutation,
        authentication: GitHubReadAuthentication,
        map: (Mutation.Data) throws -> Value
    ) async throws -> GitHubExecutedMutation<Value> where Mutation.ResponseFormat == SingleResponseFormat {
        let permit = try await admitRequest()
        let metadataBox = GitHubResponseMetadataBox(
            installationConfigurationURL: installationConfigurationURL
        )
        let client = GitHubGraphQLTransportFactory.makeClient(
            accessToken: authentication.accessToken,
            sessionConfiguration: sessionConfiguration,
            metadataBox: metadataBox,
            store: store
        )
        let startedAt = ContinuousClock.now
        do {
            let graphQLResponse = try await client.perform(mutation: mutation)
            guard let response = metadataBox.take() else {
                throw GitHubMutationError.outcomeUnknown(nil)
            }
            let responseIsCoolingDown = await recordCooldown(response)
            let problems = mutationProblems(graphQLResponse.errors)
            if let authorizationError = authorizationError(
                response: response,
                credentialSource: authentication.credential.source
            ) {
                throw authorizationError
            }
            if problems.contains(where: { $0.classification == "RATE_LIMITED" }) {
                await recordCooldown(response, assumeThrottled: true)
                throw GitHubMutationError.rateLimited(response)
            }
            if !problems.isEmpty {
                if graphQLResponse.data != nil {
                    throw GitHubMutationError.outcomeUnknown(response)
                }
                throw GitHubMutationError.authoritative(problems, response)
            }
            guard let data = graphQLResponse.data else {
                throw GitHubMutationError.outcomeUnknown(response)
            }
            let value: Value
            do {
                value = try map(data)
            } catch {
                throw GitHubMutationError.outcomeUnknown(response)
            }
            if !responseIsCoolingDown {
                await sessionGate.recordSuccessfulRequest(permit)
            }
            logger.info(
                "operation=\(Mutation.operationName, privacy: .public) phase=mutation status=\(response.statusCode) duration=\(String(describing: ContinuousClock.now - startedAt), privacy: .public)"
            )
            return GitHubExecutedMutation(value: value, response: response)
        } catch let error as GitHubMutationError {
            if case let .rateLimited(metadata) = error {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw error
        } catch {
            let metadata = metadataBox.take()
            let classified = classifyNetworkFailure(
                error,
                mutationStarted: true,
                metadata: metadata,
                credentialSource: authentication.credential.source
            )
            if case .rateLimited = classified, let metadata {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw classified
        }
    }

    func mutatePullRequest<Mutation: GraphQLMutation>(
        _ mutation: Mutation,
        authentication: GitHubReadAuthentication,
        repository: ForgeRepositoryIdentity,
        expectedNumber: ForgeItemNumber,
        operation: ForgeOperation,
        validate: @Sendable (GitHubPullRequestMutationValue) throws -> Void,
        fragment: @Sendable (Mutation.Data) -> GitHubAPI.GitHubPullRequestMutationSnapshot?
    ) async throws -> GitHubMutationResult<GitHubPullRequestMutationValue>
        where Mutation.ResponseFormat == SingleResponseFormat
    {
        let executed = try await executeMutation(mutation, authentication: authentication) { data in
            guard let fragment = fragment(data) else {
                throw GitHubMutationError.malformedResponse
            }
            let snapshot = try mapper.snapshot(fragment, expectedRepository: repository)
            guard snapshot.number == expectedNumber else {
                throw GitHubMutationError.authorizationMismatch
            }
            try validate(snapshot)
            return snapshot
        }
        return result(
            value: executed.value,
            response: executed.response,
            repository: repository,
            operation: operation
        )
    }

    func result<Value: Sendable>(
        value: Value,
        response: GitHubResponseMetadata,
        repository: ForgeRepositoryIdentity,
        operation: ForgeOperation
    ) -> GitHubMutationResult<Value> {
        GitHubMutationResult(
            value: value,
            response: response,
            ownership: GitHubMutationOwnership(
                credential: expectedCredential,
                repository: repository,
                operation: operation
            )
        )
    }

    func mutationContext(
        preflight: GitHubPullRequestMutationPreflight,
        accountID: ForgeAccountID,
        allowedOperation: ForgeOperation
    ) throws -> ForgePullRequestMutationContext {
        try ForgePullRequestMutationContext(
            accountID: accountID,
            repository: preflight.snapshot.repository,
            number: preflight.snapshot.number,
            state: preflight.snapshot.state,
            isDraft: preflight.snapshot.isDraft,
            head: preflight.snapshot.head,
            base: preflight.snapshot.base,
            updatedAt: preflight.snapshot.updatedAt,
            allowedOperations: [allowedOperation]
        )
    }

    func validateLifecycle(
        _ request: ForgePullRequestLifecycleRequest,
        preflight: GitHubPullRequestMutationPreflight
    ) throws {
        guard preflight.snapshot.head.commit == request.expectedHead else {
            throw GitHubMutationError.stalePullRequest
        }
        let context = try mutationContext(
            preflight: preflight,
            accountID: request.accountID,
            allowedOperation: request.action.operation
        )
        guard case let .available(validated) = ForgePullRequestLifecyclePolicy.decision(
            context: context,
            action: request.action,
            canUpdateBranch: preflight.viewerCanUpdateBranch
        ), validated == request else {
            if request.action == .updateBranch, context.head.reference == nil {
                throw GitHubMutationError.capabilityUnavailable
            }
            throw GitHubMutationError.stalePullRequest
        }
    }

    func validateMergeConfirmation(
        _ confirmation: ForgePullRequestMergeConfirmation,
        preflight: GitHubPullRequestMutationPreflight
    ) throws {
        let snapshot = try mergeSnapshot(
            preflight: preflight,
            accountID: confirmation.accountID,
            allowedOperation: .mergePullRequest
        )
        do {
            _ = try ForgePullRequestMergePolicy.validate(
                confirmation: confirmation,
                fresh: snapshot
            )
        } catch {
            throw GitHubMutationError.stalePullRequest
        }
    }

    func validateMergeQueue(
        _ request: ForgePullRequestMergeQueueRequest,
        preflight: GitHubPullRequestMutationPreflight
    ) throws -> GitHubValidatedMergeQueueAction {
        let validatedAction: GitHubValidatedMergeQueueAction = switch (
            request.action,
            preflight.mergeQueueEntryID
        ) {
        case (.enter, nil): .enter
        case let (.leave, entryID?): .leave(entryID: entryID)
        default: throw GitHubMutationError.stalePullRequest
        }
        let snapshot = try mergeSnapshot(
            preflight: preflight,
            accountID: request.accountID,
            allowedOperation: request.action.operation
        )
        guard case let .available(validated) = ForgePullRequestMergeQueuePolicy.decision(
            snapshot: snapshot,
            action: request.action
        ), validated == request else {
            throw GitHubMutationError.stalePullRequest
        }
        return validatedAction
    }

    func mergeSnapshot(
        preflight: GitHubPullRequestMutationPreflight,
        accountID: ForgeAccountID,
        allowedOperation: ForgeOperation
    ) throws -> ForgePullRequestMergeSnapshot {
        try ForgePullRequestMergeSnapshot(
            context: mutationContext(
                preflight: preflight,
                accountID: accountID,
                allowedOperation: allowedOperation
            ),
            viewerCanMerge: preflight.viewerCanMerge,
            enabledMethods: preflight.enabledMergeMethods,
            warnings: preflight.mergeWarnings,
            queueState: preflight.mergeQueueEntryID == nil ? .notQueued : .queued
        )
    }

    func restAnchorPayload(_ anchor: ForgeReviewAnchor) throws -> [String: Any] {
        var payload: [String: Any] = ["path": anchor.path.value]
        switch anchor.subject {
        case .file:
            guard anchor.side == nil,
                  anchor.startSide == nil,
                  anchor.startLine == nil,
                  anchor.line == nil
            else {
                throw GitHubMutationError.invalidRequest
            }
            payload["subject_type"] = "file"
        case .line:
            guard let line = anchor.line,
                  let side = anchor.side,
                  line > 0
            else {
                throw GitHubMutationError.invalidRequest
            }
            let sideValue = side == .left ? "LEFT" : "RIGHT"
            payload["subject_type"] = "line"
            payload["line"] = line
            payload["side"] = sideValue
            switch (anchor.startLine, anchor.startSide) {
            case (nil, nil):
                break
            case let (.some(value), .some(start)):
                guard value > 0,
                      value <= line,
                      start == side
                else {
                    throw GitHubMutationError.invalidRequest
                }
                payload["start_line"] = value
                payload["start_side"] = sideValue
            default:
                throw GitHubMutationError.invalidRequest
            }
        }
        return payload
    }

    func validateMutationPullRequest(
        repositoryFragment: GitHubAPI.GitHubRepositoryIdentity,
        number: Int,
        expectedRepository: ForgeRepositoryIdentity,
        expectedNumber: ForgeItemNumber
    ) throws {
        guard try mapper.repository(repositoryFragment) == expectedRepository,
              try ForgeItemNumber(number) == expectedNumber
        else {
            throw GitHubMutationError.authorizationMismatch
        }
    }

    func reviewState(
        _ state: GitHubAPI.PullRequestReviewState?,
        matches kind: ForgeFormalReviewKind
    ) -> Bool {
        switch (state, kind) {
        case (.approved, .approve), (.commented, .comment), (.changesRequested, .requestChanges): true
        default: false
        }
    }

    func reviewResolutionReceipt(
        id: String,
        isResolved: Bool,
        repositoryFragment: GitHubAPI.GitHubRepositoryIdentity,
        number: Int,
        expectedID: ForgeObjectID,
        expectedRepository: ForgeRepositoryIdentity,
        expectedNumber: ForgeItemNumber,
        expectedResolved: Bool
    ) throws -> GitHubReviewMutationReceipt {
        try validateMutationPullRequest(
            repositoryFragment: repositoryFragment,
            number: number,
            expectedRepository: expectedRepository,
            expectedNumber: expectedNumber
        )
        guard try mapper.objectID(id) == expectedID,
              isResolved == expectedResolved
        else {
            throw GitHubMutationError.outcomeUnknown(nil)
        }
        return GitHubReviewMutationReceipt(
            repository: expectedRepository,
            pullRequest: expectedNumber,
            objectID: expectedID,
            isResolved: isResolved
        )
    }

    func mutationProblems(_ errors: [GraphQLError]?) -> [GitHubMutationProblem] {
        (errors ?? []).map { error in
            let rawMessage = (error.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeMessage = rawMessage.isEmpty
                || rawMessage.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                ? "GitHub rejected this operation."
                : String(rawMessage.prefix(500))
            let path: [String] = error.path?.map {
                switch $0 {
                case let .field(field): field
                case let .index(index): String(index)
                }
            } ?? []
            let reported = (error.extensions?["type"] as? String)
                ?? (error.extensions?["code"] as? String)
            let allowed = Set(["FORBIDDEN", "NOT_FOUND", "RATE_LIMITED", "UNAUTHORIZED", "UNPROCESSABLE"])
            return GitHubMutationProblem(
                authoritativeMessage: safeMessage,
                path: path,
                classification: reported.flatMap { allowed.contains($0) ? $0 : nil }
            )
        }
    }

    func classifyNetworkFailure(
        _ error: Error,
        mutationStarted: Bool,
        metadata: GitHubResponseMetadata?,
        credentialSource: ForgeCredentialSource
    ) -> GitHubMutationError {
        if let metadata,
           let authorizationError = authorizationError(
               response: metadata,
               credentialSource: credentialSource
           )
        {
            return authorizationError
        }
        if let metadata {
            switch metadata.statusCode {
            case 403 where metadata.rateLimit.remaining == 0 || metadata.rateLimit.retryAt != nil:
                return .rateLimited(metadata)
            case 429:
                return .rateLimited(metadata)
            default:
                break
            }
        }
        if mutationStarted {
            logger.notice("phase=mutation transition=outcome_unknown reason=post_dispatch_transport")
            return .outcomeUnknown(metadata)
        }
        if isOffline(error) {
            return .offline
        }
        if let metadata {
            switch metadata.statusCode {
            case 401: return .authenticationRequired
            case 403 where metadata.rateLimit.remaining == 0 || metadata.rateLimit.retryAt != nil:
                return .rateLimited(metadata)
            case 403: return .permissionDenied(metadata)
            case 429: return .rateLimited(metadata)
            case 408, 500 ... 599: return .transportFailure
            default: break
            }
        }
        return .transportFailure
    }

    func authorizationError(
        response: GitHubResponseMetadata,
        credentialSource: ForgeCredentialSource
    ) -> GitHubMutationError? {
        switch GitHubAuthorizationRecoveryPolicy.recovery(
            from: response,
            credentialSource: credentialSource
        ) {
        case .saml:
            .samlAuthorizationRequired(response)
        case .installation:
            .installationConfigurationRequired(response)
        case nil:
            nil
        }
    }

    func isOffline(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let value = current {
            if value.domain == NSURLErrorDomain,
               [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed].contains(value.code)
            {
                return true
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    func responseMetadata(_ response: GitHubMutationHTTPResponse) -> GitHubResponseMetadata {
        let rateLimit = GitHubRateLimitParser.parse(
            statusCode: response.statusCode,
            headers: response.headers,
            receivedAt: now()
        )
        let authorization = GitHubRESTAuthorizationParser.responseMetadata(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.data,
            installationConfigurationURL: installationConfigurationURL
        )
        return GitHubResponseMetadata(
            statusCode: response.statusCode,
            requestID: response.headers.first {
                $0.key.caseInsensitiveCompare("X-GitHub-Request-Id") == .orderedSame
            }?.value,
            rateLimit: rateLimit,
            saml: authorization.saml,
            installation: authorization.installation
        )
    }

    func classifyRESTFailure(
        _ response: GitHubMutationHTTPResponse,
        metadata: GitHubResponseMetadata,
        credentialSource: ForgeCredentialSource
    ) -> GitHubMutationError {
        if let authorizationError = authorizationError(
            response: metadata,
            credentialSource: credentialSource
        ) {
            return authorizationError
        }
        switch response.statusCode {
        case 401: return .authenticationRequired
        case 403 where metadata.rateLimit.remaining == 0 || metadata.rateLimit.retryAt != nil:
            return .rateLimited(metadata)
        case 403, 404: return .permissionDenied(metadata)
        case 429: return .rateLimited(metadata)
        case 408, 500 ... 599: return .outcomeUnknown(metadata)
        default:
            let message = authoritativeRESTMessage(response.data)
            return .authoritative([
                GitHubMutationProblem(authoritativeMessage: message),
            ], metadata)
        }
    }

    func authoritativeRESTMessage(_ data: Data) -> String {
        struct Payload: Decodable { let message: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return "GitHub rejected this operation."
        }
        let value = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return "GitHub rejected this operation."
        }
        return String(value.prefix(500))
    }

    func nullable<Value: Sendable>(_ value: Value?) -> GraphQLNullable<Value> {
        value.map(GraphQLNullable.some) ?? .none
    }

    @discardableResult
    func recordCooldown(
        _ metadata: GitHubResponseMetadata,
        assumeThrottled: Bool = false
    ) async -> Bool {
        let evaluationDate = now()
        let deadline = metadata.rateLimit.cooldownDeadline(
            statusCode: metadata.statusCode,
            now: evaluationDate
        ) ?? (assumeThrottled ? evaluationDate.addingTimeInterval(60) : nil)
        guard let deadline else { return false }
        await sessionGate.recordCooldown(for: expectedCredential, until: deadline)
        logger.notice("phase=gate transition=cooldown_recorded")
        return true
    }
}

extension GitHubMutationAdapter {
    func acquireResolutionTransition(for threadID: ForgeObjectID) async -> UInt64 {
        if activeResolutionThreads.insert(threadID).inserted {
            let generation = (resolutionGenerations[threadID] ?? 0) + 1
            resolutionGenerations[threadID] = generation
            logger.debug(
                "operation=reviewThreadResolution phase=transition generation=\(generation) state=acquired"
            )
            return generation
        }
        logger.debug("operation=reviewThreadResolution phase=transition state=queued")
        return await withCheckedContinuation { continuation in
            resolutionWaiters[threadID, default: []].append(continuation)
        }
    }

    func releaseResolutionTransition(for threadID: ForgeObjectID, generation: UInt64) {
        guard var waiters = resolutionWaiters[threadID], !waiters.isEmpty else {
            activeResolutionThreads.remove(threadID)
            resolutionWaiters.removeValue(forKey: threadID)
            logger.debug(
                "operation=reviewThreadResolution phase=transition generation=\(generation) state=released"
            )
            return
        }
        let next = waiters.removeFirst()
        resolutionWaiters[threadID] = waiters.isEmpty ? nil : waiters
        let nextGeneration = generation + 1
        resolutionGenerations[threadID] = nextGeneration
        logger.debug(
            "operation=reviewThreadResolution phase=transition generation=\(nextGeneration) state=advanced"
        )
        next.resume(returning: nextGeneration)
    }

    // Exercised by ForgeKit package tests, which the app-target analyzer log does not include.
    // swiftlint:disable:next unused_declaration
    func hasQueuedResolutionTransition(for threadID: ForgeObjectID) -> Bool {
        !(resolutionWaiters[threadID] ?? []).isEmpty
    }
}

public extension GitHubMutationAdapter {
    func publishInlineReview(
        _ publication: ForgeInlineReviewPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        let authentication = try await authenticate(
            accountID: publication.accountID,
            repository: publication.repository,
            operation: .publishInlineReviewComment,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: publication.repository,
            number: publication.pullRequest,
            authentication: authentication
        )
        do {
            _ = try publication.validating(currentHead: preflight.snapshot.head.commit)
        } catch {
            throw GitHubMutationError.stalePullRequest
        }
        var payload = try restAnchorPayload(publication.anchor)
        payload["body"] = publication.bodyMarkdown
        payload["commit_id"] = publication.displayedHead.value
        var endpoint = URL(string: "https://api.github.com")!
        endpoint.append(path: "repos")
        endpoint.append(path: publication.repository.owner)
        endpoint.append(path: publication.repository.name)
        endpoint.append(path: "pulls")
        endpoint.append(path: String(publication.pullRequest.rawValue))
        endpoint.append(path: "comments")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitX-ForgeKit", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(authentication.accessToken.withUnsafeUTF8Bytes {
            "Bearer \(String(decoding: $0, as: UTF8.self))"
        }, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let permit = try await admitRequest()
        let response: GitHubMutationHTTPResponse
        do {
            logger.info("operation=publishInlineReviewComment phase=mutation transition=dispatch")
            response = try await restClient.execute(request)
        } catch is CancellationError {
            logger.notice(
                "operation=publishInlineReviewComment phase=mutation transition=outcome_unknown reason=cancelled_after_dispatch"
            )
            throw GitHubMutationError.outcomeUnknown(nil)
        } catch let error as GitHubMutationError {
            if case let .outcomeUnknown(metadata) = error {
                throw GitHubMutationError.outcomeUnknown(metadata)
            }
            throw GitHubMutationError.outcomeUnknown(nil)
        } catch {
            throw classifyNetworkFailure(
                error,
                mutationStarted: true,
                metadata: nil,
                credentialSource: authentication.credential.source
            )
        }
        let metadata = responseMetadata(response)
        let responseIsCoolingDown = await recordCooldown(metadata)
        guard response.statusCode == 201 else {
            let error = classifyRESTFailure(
                response,
                metadata: metadata,
                credentialSource: authentication.credential.source
            )
            if case .rateLimited = error {
                await recordCooldown(metadata, assumeThrottled: true)
            }
            throw error
        }
        struct Payload: Decodable {
            let nodeID: String
            let commitID: String
            let path: String

            enum CodingKeys: String, CodingKey {
                case nodeID = "node_id"
                case commitID = "commit_id"
                case path
            }
        }
        guard let returned = try? JSONDecoder().decode(Payload.self, from: response.data),
              returned.commitID == publication.displayedHead.value,
              returned.path == publication.anchor.path.value
        else {
            throw GitHubMutationError.outcomeUnknown(metadata)
        }
        let value = try GitHubReviewMutationReceipt(
            repository: publication.repository,
            pullRequest: publication.pullRequest,
            objectID: mapper.objectID(returned.nodeID),
            displayedHead: publication.displayedHead,
            isResolved: false
        )
        if !responseIsCoolingDown {
            await sessionGate.recordSuccessfulRequest(permit)
        }
        return result(
            value: value,
            response: metadata,
            repository: publication.repository,
            operation: .publishInlineReviewComment
        )
    }

    func replyToReviewThread(
        _ publication: ForgeReviewThreadReplyPublication,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        let authentication = try await authenticate(
            accountID: publication.accountID,
            repository: publication.repository,
            operation: .replyToReviewThread,
            authorization: authorization
        )
        _ = try await reviewThreadPreflight(
            repository: publication.repository,
            pullRequest: publication.pullRequest,
            threadID: publication.threadID,
            authentication: authentication
        )
        let mutation = GitHubAPI.GitHubReplyToReviewThreadMutation(input: .init(
            body: publication.bodyMarkdown,
            pullRequestReviewThreadId: publication.threadID.value
        ))
        let executed = try await executeMutation(mutation, authentication: authentication) { data in
            guard let comment = data.addPullRequestReviewThreadReply?.comment else {
                throw GitHubMutationError.malformedResponse
            }
            try validateMutationPullRequest(
                repositoryFragment: comment.pullRequest.repository.fragments.gitHubRepositoryIdentity,
                number: comment.pullRequest.number,
                expectedRepository: publication.repository,
                expectedNumber: publication.pullRequest
            )
            return try GitHubReviewMutationReceipt(
                repository: publication.repository,
                pullRequest: publication.pullRequest,
                objectID: mapper.objectID(comment.id)
            )
        }
        return result(
            value: executed.value,
            response: executed.response,
            repository: publication.repository,
            operation: .replyToReviewThread
        )
    }

    func submitFormalReview(
        _ submission: ForgeFormalReviewSubmission,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        let operation: ForgeOperation = switch submission.kind {
        case .approve: .submitApproveReview
        case .comment: .submitCommentReview
        case .requestChanges: .submitRequestChangesReview
        }
        let authentication = try await authenticate(
            accountID: submission.accountID,
            repository: submission.repository,
            operation: operation,
            authorization: authorization
        )
        let preflight = try await pullRequestPreflight(
            repository: submission.repository,
            number: submission.pullRequest,
            authentication: authentication
        )
        do {
            _ = try submission.validating(currentHead: preflight.snapshot.head.commit)
        } catch {
            throw GitHubMutationError.stalePullRequest
        }
        let event: GitHubAPI.PullRequestReviewEvent = switch submission.kind {
        case .approve: .approve
        case .comment: .comment
        case .requestChanges: .requestChanges
        }
        let mutation = GitHubAPI.GitHubSubmitFormalReviewMutation(input: .init(
            body: .some(submission.bodyMarkdown),
            commitOID: .some(submission.displayedHead.value),
            event: .some(GraphQLEnum(event)),
            pullRequestId: preflight.snapshot.id.value
        ))
        let executed = try await executeMutation(mutation, authentication: authentication) { data in
            guard let review = data.addPullRequestReview?.pullRequestReview,
                  let commit = review.commit
            else {
                throw GitHubMutationError.malformedResponse
            }
            try validateMutationPullRequest(
                repositoryFragment: review.pullRequest.repository.fragments.gitHubRepositoryIdentity,
                number: review.pullRequest.number,
                expectedRepository: submission.repository,
                expectedNumber: submission.pullRequest
            )
            guard try ForgeCommitID(commit.oid) == submission.displayedHead,
                  reviewState(review.state.value, matches: submission.kind)
            else {
                throw GitHubMutationError.outcomeUnknown(nil)
            }
            return try GitHubReviewMutationReceipt(
                repository: submission.repository,
                pullRequest: submission.pullRequest,
                objectID: mapper.objectID(review.id),
                displayedHead: submission.displayedHead
            )
        }
        return result(
            value: executed.value,
            response: executed.response,
            repository: submission.repository,
            operation: operation
        )
    }

    func setReviewThreadResolution(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        pullRequest: ForgeItemNumber,
        threadID: ForgeObjectID,
        mutation: ForgeReviewThreadResolutionMutation,
        authorization: GitHubMutationAuthorization
    ) async throws -> GitHubMutationResult<GitHubReviewMutationReceipt> {
        let operation: ForgeOperation = mutation == .resolve ? .resolveReviewThread : .unresolveReviewThread
        let authentication = try await authenticate(
            accountID: accountID,
            repository: repository,
            operation: operation,
            authorization: authorization
        )
        let generation = await acquireResolutionTransition(for: threadID)
        defer { releaseResolutionTransition(for: threadID, generation: generation) }
        try Task.checkCancellation()
        let preflight = try await reviewThreadPreflight(
            repository: repository,
            pullRequest: pullRequest,
            threadID: threadID,
            authentication: authentication
        )
        guard preflight.isResolved == (mutation == .unresolve) else {
            throw GitHubMutationError.stalePullRequest
        }
        switch mutation {
        case .resolve:
            let graphQLMutation = GitHubAPI.GitHubResolveReviewThreadMutation(input: .init(
                threadId: threadID.value
            ))
            let executed = try await executeMutation(graphQLMutation, authentication: authentication) { data in
                guard let thread = data.resolveReviewThread?.thread else {
                    throw GitHubMutationError.malformedResponse
                }
                return try reviewResolutionReceipt(
                    id: thread.id,
                    isResolved: thread.isResolved,
                    repositoryFragment: thread.pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    number: thread.pullRequest.number,
                    expectedID: threadID,
                    expectedRepository: repository,
                    expectedNumber: pullRequest,
                    expectedResolved: true
                )
            }
            return result(
                value: executed.value,
                response: executed.response,
                repository: repository,
                operation: operation
            )
        case .unresolve:
            let graphQLMutation = GitHubAPI.GitHubUnresolveReviewThreadMutation(input: .init(
                threadId: threadID.value
            ))
            let executed = try await executeMutation(graphQLMutation, authentication: authentication) { data in
                guard let thread = data.unresolveReviewThread?.thread else {
                    throw GitHubMutationError.malformedResponse
                }
                return try reviewResolutionReceipt(
                    id: thread.id,
                    isResolved: thread.isResolved,
                    repositoryFragment: thread.pullRequest.repository.fragments.gitHubRepositoryIdentity,
                    number: thread.pullRequest.number,
                    expectedID: threadID,
                    expectedRepository: repository,
                    expectedNumber: pullRequest,
                    expectedResolved: false
                )
            }
            return result(
                value: executed.value,
                response: executed.response,
                repository: repository,
                operation: operation
            )
        }
    }
}
