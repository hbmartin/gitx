import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog // swiftlint:disable:this unused_import

nonisolated enum ForgeGitHubReadCompositionError: Error, Equatable, LocalizedError, Sendable {
    case githubDotComCredentialRequired

    var errorDescription: String? {
        switch self {
        case .githubDotComCredentialRequired:
            "GitHub reads require a GitHub.com Credential."
        }
    }
}

/// Resolves authentication from the one Keychain-backed current Credential
/// for each request. It never consults GitHub CLI or another account.
final nonisolated class ForgeGitHubReadCredentialAuthority: GitHubReadCredentialAuthority, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    typealias NowProvider = @Sendable () -> Date

    private let accountStore: ForgeAccountStore
    private let now: NowProvider
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubReadAuthority")

    init(
        accountStore: ForgeAccountStore,
        now: @escaping NowProvider = { Date() }
    ) {
        self.accountStore = accountStore
        self.now = now
    }

    func currentAuthentication(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> GitHubReadAuthentication? {
        try Task.checkCancellation()
        guard Self.isGitHubDotCom(expectedCredential.accountID.forge) else {
            logger.error("Rejected non-GitHub.com read Credential")
            return nil
        }
        guard let envelope = try await accountStore.credential(for: expectedCredential.accountID) else {
            logger.notice("GitHub read Credential is unavailable")
            return nil
        }
        let account = envelope.account
        let credential = account.currentCredential
        try Task.checkCancellation()
        guard credential.reference == expectedCredential else {
            logger.notice("GitHub read Credential reference is no longer current")
            return nil
        }
        guard credential.expiresAt.map({ $0 > now() }) ?? true else {
            logger.notice("GitHub read Credential is expired")
            return nil
        }
        let accessToken = try envelope.secrets.withUnsafeAccessTokenBytes {
            try GitHubSecret(utf8Bytes: $0)
        }
        logger.debug("Resolved exact GitHub read Credential from Keychain authority")
        return try GitHubReadAuthentication(
            account: account,
            credential: credential,
            accessToken: accessToken
        )
    }

    var description: String {
        "GitHub read Credential authority (secrets redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    func credentialChange(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> ForgeAccountCredentialChange {
        guard Self.isGitHubDotCom(expectedCredential.accountID.forge) else {
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        return try await accountStore.credentialChange(for: expectedCredential.accountID)
    }

    static func isGitHubDotCom(_ forge: ForgeIdentity) -> Bool {
        guard forge.kind == .github else { return false }
        let origin = forge.origin.url
        return origin.scheme == "https" &&
            origin.host?.lowercased() == "github.com" &&
            origin.user == nil &&
            origin.password == nil &&
            origin.port == nil &&
            (origin.path.isEmpty || origin.path == "/") &&
            origin.query == nil &&
            origin.fragment == nil
    }

    /// Installs the current exact Credential directly onto a GitHub API
    /// request without exposing token material to the catalog service or any
    /// provider-neutral model.
    func authorizedRequest(
        _ original: URLRequest,
        for expectedCredential: ForgeCredentialReference
    ) async throws -> URLRequest {
        guard Self.isGitHubDotCom(expectedCredential.accountID.forge),
              let url = original.url,
              url.scheme == "https",
              url.host?.lowercased() == "api.github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              original.value(forHTTPHeaderField: "Authorization") == nil,
              let envelope = try await accountStore.credential(for: expectedCredential.accountID),
              envelope.account.currentCredential.reference == expectedCredential,
              envelope.account.currentCredential.expiresAt.map({ $0 > now() }) ?? true
        else {
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        var request = original
        let authorization = try envelope.secrets.withUnsafeAccessTokenBytes { bytes in
            let secret = try GitHubSecret(utf8Bytes: bytes)
            return secret.withUnsafeUTF8Bytes { "Bearer \(String(decoding: $0, as: UTF8.self))" }
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Produces an uncached adapter bound to one exact Credential reference. The
/// adapter re-enters the authority before every request, so retained adapters
/// see same-generation token rotation and fail closed after replacement or
/// removal.
final nonisolated class ForgeGitHubReadAdapterFactory: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let credentialAuthority: ForgeGitHubReadCredentialAuthority
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubReadComposition")

    init(credentialAuthority: ForgeGitHubReadCredentialAuthority) {
        self.credentialAuthority = credentialAuthority
    }

    func makeAdapter(
        for expectedCredential: ForgeCredentialReference,
        sessionConfiguration: URLSessionConfiguration = .default
    ) throws -> GitHubReadAdapter {
        guard ForgeGitHubReadCredentialAuthority.isGitHubDotCom(expectedCredential.accountID.forge) else {
            logger.error("Rejected adapter creation for non-GitHub.com Credential")
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        logger.debug("Created exact-reference GitHub read adapter")
        return GitHubReadAdapter(
            expectedCredential: expectedCredential,
            credentialAuthority: credentialAuthority,
            sessionConfiguration: sessionConfiguration
        )
    }

    func makeMutationAdapter(
        for expectedCredential: ForgeCredentialReference,
        sessionGate: GitHubMutationSessionGate,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws -> GitHubMutationAdapter {
        guard ForgeGitHubReadCredentialAuthority.isGitHubDotCom(expectedCredential.accountID.forge) else {
            logger.error("Rejected mutation adapter creation for non-GitHub.com Credential")
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        logger.debug("Created exact-reference GitHub mutation adapter")
        return GitHubMutationAdapter(
            expectedCredential: expectedCredential,
            credentialAuthority: credentialAuthority,
            sessionConfiguration: sessionConfiguration,
            sessionGate: sessionGate
        )
    }

    func authorizedRequest(
        _ request: URLRequest,
        for expectedCredential: ForgeCredentialReference
    ) async throws -> URLRequest {
        try await credentialAuthority.authorizedRequest(request, for: expectedCredential)
    }

    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
    func credentialChange(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> ForgeAccountCredentialChange {
        try await credentialAuthority.credentialChange(for: expectedCredential)
    }

    var description: String {
        "Exact-reference GitHub read adapter factory (secrets redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated enum ForgeGitHubReadSurfaceServiceError: Error, Equatable, LocalizedError, Sendable {
    case repositoryMismatch

    var errorDescription: String? {
        switch self {
        case .repositoryMismatch:
            "The selected GitHub item belongs to a different repository."
        }
    }
}

nonisolated struct ForgeGitHubSurfaceRead<Value: Sendable>: Sendable {
    let value: Value
    let isPartial: Bool

    init(value: Value, isPartial: Bool = false) {
        self.value = value
        self.isPartial = isPartial
    }

    init(_ result: GitHubReadResult<Value>) {
        value = result.value
        isPartial = result.completeness == .partial
    }
}

nonisolated protocol ForgeGitHubReadSurfaceAdapter: Sendable {
    func pullRequests(
        repository: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgePullRequestState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgePullRequestSummary>>

    func issues(
        repository: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgeIssueState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeIssueSummary>>

    func searchRepositoryItems(
        repository: ForgeRepositoryIdentity,
        text: String,
        after: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeRepositoryItem>>

    func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePullRequestDetailsPage>

    func issueDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgeIssueDetails>
}

actor ForgeGitHubReadSurfaceAdapterBox: ForgeGitHubReadSurfaceAdapter {
    private let adapter: GitHubReadAdapter

    init(adapter: GitHubReadAdapter) {
        self.adapter = adapter
    }

    func pullRequests(
        repository: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgePullRequestState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgePullRequestSummary>> {
        try await ForgeGitHubSurfaceRead(adapter.pullRequests(
            repository: repository,
            after: after,
            states: states
        ))
    }

    func issues(
        repository: ForgeRepositoryIdentity,
        after: ForgePageCursor?,
        states: Set<ForgeIssueState>?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeIssueSummary>> {
        try await ForgeGitHubSurfaceRead(adapter.issues(
            repository: repository,
            after: after,
            states: states
        ))
    }

    func searchRepositoryItems(
        repository: ForgeRepositoryIdentity,
        text: String,
        after: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePage<ForgeRepositoryItem>> {
        try await ForgeGitHubSurfaceRead(adapter.searchRepositoryItems(
            repository: repository,
            text: text,
            after: after
        ))
    }

    func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgePullRequestDetailsPage> {
        try await ForgeGitHubSurfaceRead(adapter.pullRequestDetails(
            repository: repository,
            number: number,
            timelineAfter: timelineAfter,
            checkAfter: checkAfter
        ))
    }

    func issueDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        timelineAfter: ForgePageCursor?
    ) async throws -> ForgeGitHubSurfaceRead<ForgeIssueDetails> {
        try await ForgeGitHubSurfaceRead(adapter.issueDetails(
            repository: repository,
            number: number,
            timelineAfter: timelineAfter
        ))
    }
}

/// Maps the exact-Credential GitHub adapter onto the list/inspector UI seam.
/// Search remains a server-side repository search, followed by a defensive
/// kind/state filter because the checked-in adapter deliberately treats user
/// text as a literal phrase rather than executable GitHub qualifiers.
@MainActor
final class ForgeGitHubReadSurfaceService: ForgeReadSurfaceServing {
    typealias NowProvider = @Sendable () -> Date

    private let repository: ForgeRepositoryIdentity
    private let adapter: any ForgeGitHubReadSurfaceAdapter
    private let now: NowProvider

    convenience init(
        repository: ForgeRepositoryIdentity,
        adapter: GitHubReadAdapter,
        now: @escaping NowProvider = { Date() }
    ) {
        self.init(
            repository: repository,
            adapter: ForgeGitHubReadSurfaceAdapterBox(adapter: adapter),
            now: now
        )
    }

    init(
        repository: ForgeRepositoryIdentity,
        adapter: any ForgeGitHubReadSurfaceAdapter,
        now: @escaping NowProvider = { Date() }
    ) {
        self.repository = repository
        self.adapter = adapter
        self.now = now
    }

    func loadItems(
        kind: ForgeReadSurfaceKind,
        query: ForgeReadSurfaceQuery,
        after cursor: ForgePageCursor?
    ) async throws -> ForgeReadSurfacePage {
        if !query.searchText.isEmpty {
            let result = try await adapter.searchRepositoryItems(
                repository: repository,
                text: query.searchText,
                after: cursor
            )
            let items = result.value.items.filter {
                Self.matches($0, kind: kind, state: query.stateFilter)
            }
            return ForgeReadSurfacePage(
                items: items,
                nextCursor: result.value.nextCursor,
                fetchedAt: now(),
                isPartial: result.isPartial
            )
        }

        switch kind {
        case .pullRequests:
            let result = try await adapter.pullRequests(
                repository: repository,
                after: cursor,
                states: Self.pullRequestStates(query.stateFilter)
            )
            return ForgeReadSurfacePage(
                items: result.value.items.map(ForgeRepositoryItem.pullRequest),
                nextCursor: result.value.nextCursor,
                totalCount: result.value.totalCount,
                fetchedAt: now(),
                isPartial: result.isPartial
            )
        case .issues:
            let result = try await adapter.issues(
                repository: repository,
                after: cursor,
                states: Self.issueStates(query.stateFilter)
            )
            return ForgeReadSurfacePage(
                items: result.value.items.map(ForgeRepositoryItem.issue),
                nextCursor: result.value.nextCursor,
                totalCount: result.value.totalCount,
                fetchedAt: now(),
                isPartial: result.isPartial
            )
        }
    }

    func loadDetails(
        for item: ForgeRepositoryItem,
        timelineAfter: ForgePageCursor?,
        checkAfter: ForgePageCursor?
    ) async throws -> ForgeReadSurfaceDetailsSnapshot {
        guard item.repository == repository else {
            throw ForgeGitHubReadSurfaceServiceError.repositoryMismatch
        }
        switch item {
        case let .pullRequest(summary):
            let result = try await adapter.pullRequestDetails(
                repository: repository,
                number: summary.number,
                timelineAfter: timelineAfter,
                checkAfter: checkAfter
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .pullRequest(result.value),
                fetchedAt: now(),
                isPartial: result.isPartial
            )
        case let .issue(summary):
            let result = try await adapter.issueDetails(
                repository: repository,
                number: summary.number,
                timelineAfter: timelineAfter
            )
            return ForgeReadSurfaceDetailsSnapshot(
                details: .issue(result.value),
                fetchedAt: now(),
                isPartial: result.isPartial
            )
        }
    }

    private static func pullRequestStates(
        _ filter: ForgeReadStateFilter
    ) -> Set<ForgePullRequestState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed, .merged]
        case .all: nil
        }
    }

    private static func issueStates(_ filter: ForgeReadStateFilter) -> Set<ForgeIssueState>? {
        switch filter {
        case .open: [.open]
        case .closed: [.closed]
        case .all: nil
        }
    }

    private static func matches(
        _ item: ForgeRepositoryItem,
        kind: ForgeReadSurfaceKind,
        state: ForgeReadStateFilter
    ) -> Bool {
        switch (item, kind, state) {
        case (.pullRequest, .issues, _), (.issue, .pullRequests, _):
            false
        case let (.pullRequest(summary), .pullRequests, .open):
            summary.state == .open
        case let (.pullRequest(summary), .pullRequests, .closed):
            summary.state == .closed || summary.state == .merged
        case (.pullRequest, .pullRequests, .all):
            true
        case let (.issue(summary), .issues, .open):
            summary.state == .open
        case let (.issue(summary), .issues, .closed):
            summary.state == .closed
        case (.issue, .issues, .all):
            true
        }
    }
}
