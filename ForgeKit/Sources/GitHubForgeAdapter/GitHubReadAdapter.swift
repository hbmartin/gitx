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
    private let sessionConfiguration: URLSessionConfiguration
    private let store = ApolloStore(cache: InMemoryNormalizedCache())
    private let mapper: GitHubGraphQLDocumentMapper
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "github-read")

    public init(
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        expectedCredential = nil
        credentialAuthority = nil
        self.sessionConfiguration = sessionConfiguration
        mapper = GitHubGraphQLDocumentMapper(forge: Self.gitHubForge)
    }

    public init(
        expectedCredential: ForgeCredentialReference,
        credentialAuthority: any GitHubReadCredentialAuthority,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.expectedCredential = expectedCredential
        self.credentialAuthority = credentialAuthority
        self.sessionConfiguration = sessionConfiguration
        mapper = GitHubGraphQLDocumentMapper(forge: Self.gitHubForge)
    }

    public func repositoryFacts(
        repository: ForgeRepositoryIdentity
    ) async throws -> GitHubReadResult<ForgeRepositoryFacts> {
        let authentication = try await validate(repository)
        let credential = authentication.credential
        let query = GitHubAPI.GitHubRepositoryFactsQuery(owner: repository.owner, name: repository.name)
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.repositoryFacts(data: data, expectedRepository: repository, credential: credential.reference)
        }
    }

    public func pullRequests(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        states: Set<ForgePullRequestState>? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgePullRequestSummary>> {
        let authentication = try await validate(repository)
        let first = try pageSizeValue(pageSize)
        let stateValues = states.map { values in
            values.map { value -> GraphQLEnum<GitHubAPI.PullRequestState> in
                switch value {
                case .open: GraphQLEnum(.open)
                case .closed: GraphQLEnum(.closed)
                case .merged: GraphQLEnum(.merged)
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
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.pullRequestList(data: data, repository: repository)
        }
    }

    public func issues(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        states: Set<ForgeIssueState>? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeIssueSummary>> {
        let authentication = try await validate(repository)
        let first = try pageSizeValue(pageSize)
        let stateValues = states.map { values in
            values.map { value -> GraphQLEnum<GitHubAPI.IssueState> in
                switch value {
                case .open: GraphQLEnum(.open)
                case .closed: GraphQLEnum(.closed)
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
        return try await execute(query, repository: repository, authentication: authentication) { data in
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
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubPullRequestDetailsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(number.rawValue),
            timelineFirst: pageSizeValue(timelinePageSize),
            timelineAfter: nullable(timelineAfter?.value),
            checkFirst: pageSizeValue(checkPageSize),
            checkAfter: nullable(checkAfter?.value)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.pullRequestDetails(data: data, repository: repository)
        }
    }

    public func issueDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelinePageSize: Int = 50,
        timelineAfter: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgeIssueDetails> {
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubIssueDetailsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(number.rawValue),
            timelineFirst: pageSizeValue(timelinePageSize),
            timelineAfter: nullable(timelineAfter?.value)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.issueDetails(data: data, repository: repository)
        }
    }

    public func historyOverlay(
        repository: ForgeRepositoryIdentity,
        commit: ForgeCommitID,
        pullRequestPageSize: Int = 25,
        pullRequestAfter: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgeHistoryOverlay> {
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubHistoryOverlayQuery(
            owner: repository.owner,
            name: repository.name,
            oid: commit.value,
            pullRequestFirst: pageSizeValue(pullRequestPageSize),
            pullRequestAfter: nullable(pullRequestAfter?.value)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.historyOverlay(data: data, repository: repository, commit: commit)
        }
    }

    public func searchRepositoryItems(
        repository: ForgeRepositoryIdentity,
        text: String,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeRepositoryItem>> {
        let authentication = try await validate(repository)
        let search = try searchQuery(repository: repository, text: text)
        let query = try GitHubAPI.GitHubRepositoryItemSearchQuery(
            query: search,
            first: pageSizeValue(pageSize),
            after: nullable(after?.value)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.repositoryItemSearch(data: data, repository: repository)
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
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubAttentionCandidatesQuery(
            query: searchQuery(repository: repository, text: searchText),
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            activityLast: pageSizeValue(activityCount),
            reviewThreadFirst: pageSizeValue(reviewThreadCount)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.attentionCandidates(data: data, repository: repository)
        }
    }

    /// Fetches the provider-owned current Attention candidate set. Unlike the
    /// repository search field, these qualifiers are not user text and must not
    /// be quoted into a literal phrase.
    public func currentAttentionCandidates(
        repository: ForgeRepositoryIdentity,
        pageSize: Int = 100,
        after: ForgePageCursor? = nil,
        activityCount: Int = 100,
        reviewThreadCount: Int = 100
    ) async throws -> GitHubReadResult<ForgeAttentionCandidatePage> {
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubAttentionCandidatesQuery(
            query: "repo:\(repository.owner)/\(repository.name) is:open involves:@me",
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            activityLast: pageSizeValue(activityCount),
            reviewThreadFirst: pageSizeValue(reviewThreadCount)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.attentionCandidates(data: data, repository: repository)
        }
    }

    public func reviewThreads(
        repository: ForgeRepositoryIdentity,
        pullRequestNumber: ForgeItemNumber,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil,
        initialCommentCount: Int = 25
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewThread>> {
        let authentication = try await validate(repository)
        let query = try GitHubAPI.GitHubPullRequestReviewThreadsQuery(
            owner: repository.owner,
            name: repository.name,
            number: int32(pullRequestNumber.rawValue),
            first: pageSizeValue(pageSize),
            after: nullable(after?.value),
            commentFirst: pageSizeValue(initialCommentCount)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
            try mapper.reviewThreads(data: data, repository: repository)
        }
    }

    public func reviewThreadComments(
        repository: ForgeRepositoryIdentity,
        threadID: ForgeObjectID,
        pageSize: Int = 50,
        after: ForgePageCursor? = nil
    ) async throws -> GitHubReadResult<ForgePage<ForgeReviewComment>> {
        let authentication = try await validate(repository)
        guard threadID.forge == repository.forge else { throw GitHubReadError.githubDotComRequired }
        let query = try GitHubAPI.GitHubPullRequestReviewThreadCommentsQuery(
            id: threadID.value,
            first: pageSizeValue(pageSize),
            after: nullable(after?.value)
        )
        return try await execute(query, repository: repository, authentication: authentication) { data in
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
        map: (Query.Data) throws -> GitHubMappedValue<Value>
    ) async throws -> GitHubReadResult<Value> where Query.ResponseFormat == SingleResponseFormat {
        let credential = authentication.credential
        let metadataBox = GitHubResponseMetadataBox()
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
            guard let data = graphQLResponse.data else {
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
                mapped = try map(data)
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
            return try GitHubReadResult(
                value: mapped.value,
                completeness: completeness,
                problems: problems,
                response: response,
                ownership: GitHubReadOwnership(credential: credential.reference, repository: repository),
                accessEvidence: mapped.accessEvidence
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubReadError {
            logger.error("operation=\(Query.operationName, privacy: .public) failure=\(error.errorDescription ?? "unknown", privacy: .public)")
            throw error
        } catch {
            let metadata = metadataBox.take()
            let classified = classifyTransportFailure(metadata: metadata)
            logger.error("operation=\(Query.operationName, privacy: .public) failure=transport status=\(metadata?.statusCode ?? 0)")
            throw classified
        }
    }

    func classifyTransportFailure(metadata: GitHubResponseMetadata?) -> GitHubReadError {
        guard let metadata else { return .transportFailure }
        if metadata.saml != nil {
            return .samlAuthorizationRequired(metadata)
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

    func mappingFailure(_ error: GitHubReadError) -> GitHubReadMappingFailure {
        switch error {
        case .repositoryNotFound: .repositoryNotFound
        case .objectNotFound: .objectNotFound
        default: .malformedResponse
        }
    }

    func validate(_ repository: ForgeRepositoryIdentity) async throws -> GitHubReadAuthentication {
        guard repository.forge == Self.gitHubForge else {
            throw GitHubReadError.githubDotComRequired
        }
        guard let expectedCredential,
              let credentialAuthority,
              let authentication = try await credentialAuthority.currentAuthentication(
                  for: expectedCredential
              ),
              authentication.account.currentCredential == authentication.credential,
              authentication.credential.reference == expectedCredential,
              authentication.account.id == authentication.credential.reference.accountID,
              authentication.credential.reference.accountID.forge == repository.forge,
              authentication.credential.expiresAt.map({ $0 > Date() }) ?? true
        else {
            throw GitHubReadError.authenticationRequired
        }
        return authentication
    }

    func pageSizeValue(_ value: Int) throws -> Int32 {
        guard (1 ... 100).contains(value) else { throw GitHubReadError.invalidPageSize }
        return Int32(value)
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
