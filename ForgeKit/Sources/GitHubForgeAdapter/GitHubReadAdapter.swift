import Apollo
import ApolloAPI
import ForgeKit
import Foundation
import os

/// Executes the checked-in GitHub.com read operations through Apollo's
/// in-memory normalized cache and maps every result to ForgeKit values before
/// it crosses the adapter boundary.
public struct GitHubReadAuthentication: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let account: ForgeAccount
    public let credential: ForgeCredentialMetadata
    let accessToken: GitHubSecret

    public init(
        account: ForgeAccount,
        credential: ForgeCredentialMetadata,
        accessToken: GitHubSecret
    ) throws {
        guard account.currentCredential == credential else {
            throw GitHubAuthenticationError.mismatchedCredentialAuthority
        }
        self.account = account
        self.credential = credential
        self.accessToken = accessToken
    }

    public var description: String {
        "GitHub read authentication (token redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

/// Loads the one current Credential and its matching token for every request.
/// Implementations must read both values from the same authoritative store
/// snapshot; the adapter then verifies that snapshot against its exact bound
/// Credential reference before creating a network transport.
public protocol GitHubReadCredentialAuthority: Sendable {
    func currentAuthentication(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> GitHubReadAuthentication?
}

public actor GitHubReadAdapter {
    private let expectedCredential: ForgeCredentialReference?
    private let credentialAuthority: (any GitHubReadCredentialAuthority)?
    private let sessionGate: GitHubMutationSessionGate
    private let sessionConfiguration: URLSessionConfiguration
    private let installationConfigurationURL: URL?
    private let store = ApolloStore(cache: InMemoryNormalizedCache())
    private let mapper: GitHubGraphQLDocumentMapper
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "github-read")

    public init(
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        expectedCredential = nil
        credentialAuthority = nil
        sessionGate = GitHubMutationSessionGate()
        self.sessionConfiguration = sessionConfiguration
        installationConfigurationURL = nil
        mapper = GitHubGraphQLDocumentMapper(forge: Self.gitHubForge)
    }

    public init(
        expectedCredential: ForgeCredentialReference,
        credentialAuthority: any GitHubReadCredentialAuthority,
        sessionConfiguration: URLSessionConfiguration = .default,
        sessionGate: GitHubMutationSessionGate = GitHubMutationSessionGate(),
        installationConfigurationURL: URL? = nil
    ) {
        self.expectedCredential = expectedCredential
        self.credentialAuthority = credentialAuthority
        self.sessionGate = sessionGate
        self.sessionConfiguration = sessionConfiguration
        self.installationConfigurationURL = installationConfigurationURL
        mapper = GitHubGraphQLDocumentMapper(forge: Self.gitHubForge)
    }

    public func repositoryFacts(
        repository: ForgeRepositoryIdentity
    ) async throws -> GitHubReadResult<ForgeRepositoryFacts> {
        let (authentication, permit) = try await validate(repository)
        let credential = authentication.credential
        let query = GitHubAPI.GitHubRepositoryFactsQuery(owner: repository.owner, name: repository.name)
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, _ in
            try mapper.repositoryFacts(data: data, expectedRepository: repository, credential: credential.reference)
        }
    }

    public func pullRequests(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        states: Set<ForgePullRequestState>? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgePullRequestSummary>> {
        let (authentication, permit) = try await validate(repository)
        let first = try pageSizeValue(pageSize)
        let stateValues = states.map { values in
            values.compactMap { value -> GraphQLEnum<GitHubAPI.PullRequestState>? in
                switch value {
                case .open: GraphQLEnum(.open)
                case .closed: GraphQLEnum(.closed)
                case .merged: GraphQLEnum(.merged)
                case .unknown: nil
                }
            }
        }
        let query = GitHubAPI.GitHubPullRequestListQuery(
            owner: repository.owner,
            name: repository.name,
            first: first,
            after: nullable(after?.value),
            states: nullable(stateValues)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.pullRequestList(data: data, repository: repository, problems: problems)
        }
    }

    public func issues(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        states: Set<ForgeIssueState>? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeIssueSummary>> {
        let (authentication, permit) = try await validate(repository)
        let first = try pageSizeValue(pageSize)
        let stateValues = states.map { values in
            values.compactMap { value -> GraphQLEnum<GitHubAPI.IssueState>? in
                switch value {
                case .open: GraphQLEnum(.open)
                case .closed: GraphQLEnum(.closed)
                case .unknown: nil
                }
            }
        }
        let query = GitHubAPI.GitHubIssueListQuery(
            owner: repository.owner,
            name: repository.name,
            first: first,
            after: nullable(after?.value),
            states: nullable(stateValues)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, _ in
            try mapper.issueList(data: data, repository: repository)
        }
    }

    public func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelinePageSize: Int = 50,
        timelineAfter: ForgePageCursor? = nil,
        checkPageSize: Int = 50,
        checkAfter: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgePullRequestDetailsPage> {
        let (authentication, permit) = try await validate(repository)
        let query = try GitHubAPI.GitHubPullRequestDetailsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(number.rawValue),
            timelineFirst: pageSizeValue(timelinePageSize),
            timelineAfter: nullable(timelineAfter?.value),
            checkFirst: pageSizeValue(checkPageSize),
            checkAfter: nullable(checkAfter?.value)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.pullRequestDetails(data: data, repository: repository, problems: problems)
        }
    }

    public func issueDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelinePageSize: Int = 50,
        timelineAfter: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgeIssueDetails> {
        let (authentication, permit) = try await validate(repository)
        let query = try GitHubAPI.GitHubIssueDetailsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(number.rawValue),
            timelineFirst: pageSizeValue(timelinePageSize),
            timelineAfter: nullable(timelineAfter?.value)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, _ in
            try mapper.issueDetails(data: data, repository: repository)
        }
    }

    public func historyOverlay(
        repository: ForgeRepositoryIdentity,
        commit: ForgeCommitID,
        pullRequestPageSize: Int = 25,
        pullRequestAfter: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgeHistoryOverlay> {
        let (authentication, permit) = try await validate(repository)
        let query = try GitHubAPI.GitHubHistoryOverlayQuery(
            owner: repository.owner,
            name: repository.name,
            oid: commit.value,
            pullRequestFirst: pageSizeValue(pullRequestPageSize),
            pullRequestAfter: nullable(pullRequestAfter?.value)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.historyOverlay(
                data: data,
                repository: repository,
                commit: commit,
                problems: problems
            )
        }
    }

    public func searchRepositoryItems(
        repository: ForgeRepositoryIdentity,
        text: String,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeRepositoryItem>> {
        let (authentication, permit) = try await validate(repository)
        let search = try searchQuery(repository: repository, text: text)
        let query = try GitHubAPI.GitHubRepositoryItemSearchQuery(
            query: search,
            first: pageSizeValue(pageSize),
            after: nullable(after?.value)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.repositoryItemSearch(data: data, repository: repository, problems: problems)
        }
    }

    public func attentionCandidates(
        repository: ForgeRepositoryIdentity,
        searchText: String,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        activityCount: Int = 25,
        reviewThreadCount: Int = 25
    ) async throws -> GitHubReadResult<ForgeAttentionCandidatePage> {
        let (authentication, permit) = try await validate(repository)
        try validateAttentionNodeBudget(
            pageSize: pageSize,
            activityCount: activityCount,
            reviewThreadCount: reviewThreadCount
        )
        let query = try GitHubAPI.GitHubAttentionCandidatesQuery(
            query: searchQuery(repository: repository, text: searchText),
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            activityLast: pageSizeValue(activityCount),
            reviewThreadFirst: pageSizeValue(reviewThreadCount)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.attentionCandidates(data: data, repository: repository, problems: problems)
        }
    }

    /// Fetches the provider-owned current Attention candidate set. Unlike the
    /// repository search field, these qualifiers are not user text and must not
    /// be quoted into a literal phrase.
    public func currentAttentionCandidates(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 100,
        after: ForgePageCursor? = nil,
        activityCount: Int = 40,
        reviewThreadCount: Int = 40
    ) async throws -> GitHubReadResult<ForgeAttentionCandidatePage> {
        let (authentication, permit) = try await validate(repository)
        try validateAttentionNodeBudget(
            pageSize: pageSize,
            activityCount: activityCount,
            reviewThreadCount: reviewThreadCount
        )
        let query = try GitHubAPI.GitHubAttentionCandidatesQuery(
            query: "repo:\(repository.owner)/\(repository.name) is:open involves:@me",
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            activityLast: pageSizeValue(activityCount),
            reviewThreadFirst: pageSizeValue(reviewThreadCount)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, problems in
            try mapper.attentionCandidates(data: data, repository: repository, problems: problems)
        }
    }

    public func reviewThreads(
        repository: ForgeRepositoryIdentity,
        pullRequestNumber: ForgeItemNumber,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        initialCommentCount: Int = 25
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewThread>> {
        let (authentication, permit) = try await validate(repository)
        let query = try GitHubAPI.GitHubPullRequestReviewThreadsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(pullRequestNumber.rawValue),
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            commentFirst: pageSizeValue(initialCommentCount)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, _ in
            try mapper.reviewThreads(data: data, repository: repository)
        }
    }

    public func reviewThreadComments(
        repository: ForgeRepositoryIdentity,
        threadID: ForgeObjectID,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewComment>> {
        let (authentication, permit) = try await validate(repository)
        guard threadID.forge == repository.forge else { throw GitHubReadError.githubDotComRequired }
        let query = try GitHubAPI.GitHubPullRequestReviewThreadCommentsQuery(
            id: threadID.value,
            first: pageSizeValue(pageSize),
            after: nullable(after?.value)
        )
        return try await execute(
            query,
            repository: repository,
            authentication: authentication,
            permit: permit
        ) { data, _ in
            try mapper.reviewThreadComments(data: data, repository: repository)
        }
    }
}

private extension GitHubReadAdapter {
    nonisolated static var gitHubForge: ForgeIdentity {
        ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com"))
    }

    func execute<Query: GraphQLQuery, Value: Sendable>(
        _ query: Query,
        repository: ForgeRepositoryIdentity,
        authentication: GitHubReadAuthentication,
        permit: GitHubCredentialRequestPermit,
        map: (Query.Data, [GitHubGraphQLProblem]) throws -> GitHubMappedValue<Value>
    ) async throws -> GitHubReadResult<Value> where Query.ResponseFormat == SingleResponseFormat {
        let credential = authentication.credential
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
            guard let response = metadataBox.take() else { throw GitHubReadError.malformedResponse }
            let problems = graphQLResponse.errors?.map(\.gitXProblem) ?? []
            if problems.contains(where: { $0.classification == "RATE_LIMITED" }) {
                await recordResponseMetadata(from: .rateLimited(response))
            }
            guard let data = graphQLResponse.data else {
                if let authorizationError = authorizationError(
                    response: response,
                    credentialSource: credential.source
                ) {
                    throw authorizationError
                }
                if problems.contains(where: { $0.classification == "RATE_LIMITED" }) {
                    throw GitHubReadError.rateLimited(response)
                }
                if !problems.isEmpty {
                    throw GitHubReadError.graphQL(problems, response)
                }
                throw GitHubReadError.malformedResponse
            }
            let mapped: GitHubMappedValue<Value>
            do {
                mapped = try map(data, problems)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubReadError {
                throw GitHubReadError.mapping(mappingFailure(error), problems, response)
            } catch {
                throw GitHubReadError.mapping(.malformedResponse, problems, response)
            }
            let completeness: GitHubReadCompleteness = mapped.isPartial || !problems.isEmpty ? .partial : .complete
            let duration = ContinuousClock.now - startedAt
            logger.info(
                "operation=\(Query.operationName, privacy: .public) status=\(response.statusCode) partial=\(completeness == .partial) duration=\(String(describing: duration), privacy: .public)"
            )
            let result = try GitHubReadResult(
                value: mapped.value,
                completeness: completeness,
                problems: problems,
                response: response,
                ownership: GitHubReadOwnership(credential: credential.reference, repository: repository),
                accessEvidence: mapped.accessEvidence
            )
            await recordSuccessfulResponse(response, permit: permit)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubReadError {
            await recordResponseMetadata(from: error)
            logger.error("operation=\(Query.operationName, privacy: .public) failure=\(error.errorDescription ?? "unknown", privacy: .public)")
            throw error
        } catch {
            let metadata = metadataBox.take()
            let classified = classifyTransportFailure(
                metadata: metadata,
                credentialSource: credential.source
            )
            await recordResponseMetadata(from: classified)
            logger.error("operation=\(Query.operationName, privacy: .public) failure=transport status=\(metadata?.statusCode ?? 0)")
            throw classified
        }
    }

    func classifyTransportFailure(
        metadata: GitHubResponseMetadata?,
        credentialSource: ForgeCredentialSource
    ) -> GitHubReadError {
        guard let metadata else { return .transportFailure }
        if let authorizationError = authorizationError(
            response: metadata,
            credentialSource: credentialSource
        ) {
            return authorizationError
        }
        switch metadata.statusCode {
        case 200 ... 299: return .malformedResponse
        case 401: return .authenticationRequired
        case 403 where metadata.rateLimit.remaining == 0 || metadata.rateLimit.retryAt != nil:
            return .rateLimited(metadata)
        case 403: return .permissionDenied(metadata)
        case 429: return .rateLimited(metadata)
        default: return .transportFailure
        }
    }

    func authorizationError(
        response: GitHubResponseMetadata,
        credentialSource: ForgeCredentialSource
    ) -> GitHubReadError? {
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

    func mappingFailure(_ error: GitHubReadError) -> GitHubReadMappingFailure {
        switch error {
        case .repositoryNotFound: .repositoryNotFound
        case .objectNotFound: .objectNotFound
        default: .malformedResponse
        }
    }

    func validate(
        _ repository: ForgeRepositoryIdentity
    ) async throws -> (GitHubReadAuthentication, GitHubCredentialRequestPermit) {
        guard repository.forge == Self.gitHubForge else {
            throw GitHubReadError.githubDotComRequired
        }
        guard let expectedCredential, let credentialAuthority else {
            throw GitHubReadError.authenticationRequired
        }
        let evaluationDate = Date()
        let permit: GitHubCredentialRequestPermit
        switch await sessionGate.admitRequest(for: expectedCredential, at: evaluationDate) {
        case let .allowed(admitted):
            permit = admitted
        case .offline:
            throw GitHubReadError.transportFailure
        case let .rateLimited(until):
            throw GitHubReadError.rateLimited(Self.cooldownMetadata(until: until))
        }
        guard let authentication = try await credentialAuthority.currentAuthentication(
            for: expectedCredential
        ),
            authentication.account.currentCredential == authentication.credential,
            authentication.credential.reference == expectedCredential,
            authentication.account.id == authentication.credential.reference.accountID,
            authentication.credential.reference.accountID.forge == repository.forge,
            authentication.credential.expiresAt.map({ $0 > evaluationDate }) ?? true
        else {
            throw GitHubReadError.authenticationRequired
        }
        return (authentication, permit)
    }

    nonisolated static func cooldownMetadata(until deadline: Date) -> GitHubResponseMetadata {
        GitHubResponseMetadata(
            statusCode: 429,
            rateLimit: GitHubRateLimitMetadata(
                limit: nil,
                remaining: 0,
                used: nil,
                resetAt: deadline,
                retryAt: deadline,
                resource: nil
            )
        )
    }

    func recordSuccessfulResponse(
        _ response: GitHubResponseMetadata,
        permit: GitHubCredentialRequestPermit
    ) async {
        if let deadline = response.rateLimit.cooldownDeadline(
            statusCode: response.statusCode,
            now: Date()
        ), let expectedCredential {
            await sessionGate.recordCooldown(for: expectedCredential, until: deadline)
            logger.notice("phase=gate transition=cooldown_recorded source=authenticated_read")
            return
        }
        await sessionGate.recordSuccessfulRequest(permit)
    }

    func recordResponseMetadata(from error: GitHubReadError) async {
        let metadata: GitHubResponseMetadata?
        let assumesThrottle: Bool
        switch error {
        case let .rateLimited(response):
            metadata = response
            assumesThrottle = true
        case let .permissionDenied(response),
             let .samlAuthorizationRequired(response),
             let .installationConfigurationRequired(response),
             let .graphQL(_, response),
             let .mapping(_, _, response):
            metadata = response
            assumesThrottle = false
        default:
            metadata = nil
            assumesThrottle = false
        }
        guard let metadata, let expectedCredential else { return }
        let evaluationDate = Date()
        let deadline = metadata.rateLimit.cooldownDeadline(
            statusCode: metadata.statusCode,
            now: evaluationDate
        ) ?? (assumesThrottle ? evaluationDate.addingTimeInterval(60) : nil)
        guard let deadline else { return }
        await sessionGate.recordCooldown(for: expectedCredential, until: deadline)
        logger.notice("phase=gate transition=cooldown_recorded source=authenticated_read")
    }

    func pageSizeValue(_ value: Int) throws -> Int32 {
        guard (1 ... 100).contains(value) else { throw GitHubReadError.invalidPageSize }
        return Int32(value)
    }

    /// GitHub validates a GraphQL document against the maximum number of nodes
    /// its connection arguments can request, rather than the number a particular
    /// repository happens to return. Keep the Attention operation below the
    /// 500,000-node provider limit on every outer pagination request.
    func validateAttentionNodeBudget(
        pageSize: Int,
        activityCount: Int,
        reviewThreadCount: Int
    ) throws {
        _ = try pageSizeValue(pageSize)
        _ = try pageSizeValue(activityCount)
        _ = try pageSizeValue(reviewThreadCount)
        guard GitHubAttentionGraphQLNodeBudget.upperBound(
            pageSize: pageSize,
            activityCount: activityCount,
            reviewThreadCount: reviewThreadCount
        ) < GitHubAttentionGraphQLNodeBudget.maximumNodeCount else {
            throw GitHubReadError.queryNodeLimitExceeded
        }
    }

    func int32(_ value: Int) throws -> Int32 {
        guard let result = Int32(exactly: value) else { throw GitHubReadError.malformedResponse }
        return result
    }

    func searchQuery(repository: ForgeRepositoryIdentity, text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw GitHubReadError.invalidSearchQuery
        }
        let quoted = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "repo:\(repository.owner)/\(repository.name) \"\(quoted)\""
    }

    func nullable<Value: Sendable>(_ value: Value?) -> GraphQLNullable<Value> {
        value.map(GraphQLNullable.some) ?? .none
    }
}

/// GitHub's validated upper bound for `GitHubAttentionCandidates` is
/// `pageSize * (501 + activityCount + reviewThreadCount
/// + 2 * activityCount * reviewThreadCount)`. The final term accounts for the
/// nested review-thread activity expansion. Scalars and non-connection objects
/// do not consume GitHub's node budget.
enum GitHubAttentionGraphQLNodeBudget {
    static let maximumNodeCount = 500_000

    static func upperBound(
        pageSize: Int,
        activityCount: Int,
        reviewThreadCount: Int
    ) -> Int {
        let nodesPerCandidate = 501
            + activityCount
            + reviewThreadCount
            + (2 * activityCount * reviewThreadCount)
        return pageSize * nodesPerCandidate
    }
}
