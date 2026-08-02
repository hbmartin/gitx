import ForgeKit
import Foundation

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

public enum GitHubAnonymousRESTError: Error, Equatable, LocalizedError, Sendable {
    case explicitRequestRequired
    case reserveProtected
    case cooldown(until: Date)
    case githubDotComRepositoryRequired
    case invalidPageCursor
    case invalidResponse
    case responseTooLarge
    case notFound
    case rateLimited(until: Date?)
    case serverFailure(status: Int)

    public var errorDescription: String? {
        switch self {
        case .explicitRequestRequired:
            "Anonymous GitHub reads require an explicit repository open or manual refresh."
        case .reserveProtected:
            "Anonymous GitHub reads are paused to preserve the shared request reserve."
        case let .cooldown(until):
            "Anonymous GitHub reads are paused until \(until.formatted())."
        case .githubDotComRepositoryRequired:
            "Anonymous reads are available only for public GitHub.com repositories."
        case .invalidPageCursor:
            "The anonymous GitHub page cursor is invalid."
        case .invalidResponse:
            "GitHub returned an invalid anonymous response."
        case .responseTooLarge:
            "GitHub returned an anonymous response larger than GitX accepts."
        case .notFound:
            "The public GitHub repository or item was not found."
        case let .rateLimited(until):
            if let until {
                "Anonymous GitHub reads are rate limited until \(until.formatted())."
            } else {
                "Anonymous GitHub reads are rate limited."
            }
        case let .serverFailure(status):
            "GitHub could not complete the anonymous read (HTTP \(status))."
        }
    }
}

public struct GitHubAnonymousReadResult<Value: Sendable>: Sendable {
    public let value: Value
    public let completeness: GitHubReadCompleteness
    public let response: GitHubResponseMetadata
    public let partition: ForgeRepositoryPartitionKey
    public let fetchedAt: Date

    public init(
        value: Value,
        completeness: GitHubReadCompleteness,
        response: GitHubResponseMetadata,
        partition: ForgeRepositoryPartitionKey,
        fetchedAt: Date
    ) {
        self.value = value
        self.completeness = completeness
        self.response = response
        self.partition = partition
        self.fetchedAt = fetchedAt
    }
}

struct GitHubAnonymousRESTReservation: Equatable, Sendable {
    let generation: UInt64
}

public actor GitHubAnonymousRESTBudget {
    private let resetAllowance: Int
    private var budget: ForgeAnonymousRateBudget
    private var generation: UInt64 = 1
    private var windowReset: Date?

    public init(initialRemainingRequestCount: Int = 60) {
        resetAllowance = max(0, initialRemainingRequestCount)
        budget = ForgeAnonymousRateBudget(remainingRequestCount: resetAllowance)
    }

    public func current() -> ForgeAnonymousRateBudget {
        budget
    }

    func reserve(reason: ForgeRefreshReason, at date: Date) throws -> GitHubAnonymousRESTReservation {
        guard ForgeRefreshPolicy.anonymousRequestIsExplicitlyAllowed(for: reason) else {
            throw GitHubAnonymousRESTError.explicitRequestRequired
        }
        resetExpiredWindow(at: date)
        switch budget.decision(at: date) {
        case .allowed:
            budget = ForgeAnonymousRateBudget(
                remainingRequestCount: budget.remainingRequestCount - 1,
                cooldownDeadline: budget.cooldownDeadline
            )
            return GitHubAnonymousRESTReservation(generation: generation)
        case .reserveProtected:
            throw GitHubAnonymousRESTError.reserveProtected
        case let .cooldown(until):
            throw GitHubAnonymousRESTError.cooldown(until: until)
        }
    }

    func update(
        reservation: GitHubAnonymousRESTReservation,
        status: Int,
        headers: [String: String],
        at date: Date
    ) {
        guard reservation.generation == generation else { return }
        let reportedRemaining = Self.integerHeader("x-ratelimit-remaining", headers: headers)
        let remaining: Int = if let reportedRemaining {
            min(budget.remainingRequestCount, reportedRemaining)
        } else {
            budget.remainingRequestCount
        }
        let reportedReset = Self.integerHeader("x-ratelimit-reset", headers: headers).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        if let reportedReset, reportedReset > (windowReset ?? .distantPast) {
            windowReset = reportedReset
        }
        var deadline = budget.cooldownDeadline
        if status == 403 || status == 429 || remaining == 0 {
            let candidate: Date?
            if let retrySeconds = Self.integerHeader("retry-after", headers: headers), retrySeconds >= 0 {
                candidate = date.addingTimeInterval(TimeInterval(retrySeconds))
            } else {
                candidate = reportedReset
            }
            if let candidate, candidate > (deadline ?? .distantPast) {
                deadline = candidate
            }
        } else if let activeDeadline = deadline, date >= activeDeadline {
            deadline = nil
        }
        budget = ForgeAnonymousRateBudget(
            remainingRequestCount: remaining,
            cooldownDeadline: deadline
        )
    }

    private func resetExpiredWindow(at date: Date) {
        guard let windowReset, date >= windowReset else { return }
        generation &+= 1
        self.windowReset = nil
        let activeCooldown = budget.cooldownDeadline.flatMap { date < $0 ? $0 : nil }
        budget = ForgeAnonymousRateBudget(
            remainingRequestCount: resetAllowance,
            cooldownDeadline: activeCooldown
        )
    }

    private static func integerHeader(_ name: String, headers: [String: String]) -> Int? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

struct GitHubAnonymousRESTHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

protocol GitHubAnonymousRESTHTTPClient: Sendable {
    func execute(_ request: URLRequest) async throws -> GitHubAnonymousRESTHTTPResponse
}

// swift6-safety-justification: This stateless delegate rejects every redirect and owns no mutable state.
final class GitHubAnonymousRedirectRejector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// swift6-safety-justification: The client owns one immutable thread-safe URLSession and no mutable state.
final class GitHubAnonymousURLSessionClient: GitHubAnonymousRESTHTTPClient, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let isolated = URLSessionConfiguration.ephemeral
        isolated.protocolClasses = configuration.protocolClasses
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        isolated.timeoutIntervalForRequest = 30
        isolated.httpAdditionalHeaders = [:]
        session = URLSession(
            configuration: isolated,
            delegate: GitHubAnonymousRedirectRejector(),
            delegateQueue: nil
        )
    }

    func execute(_ request: URLRequest) async throws -> GitHubAnonymousRESTHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == "api.github.com",
              response.url?.port == nil
        else {
            throw GitHubAnonymousRESTError.invalidResponse
        }
        guard data.count <= GitHubAnonymousRESTAdapter.maximumResponseBytes else {
            throw GitHubAnonymousRESTError.responseTooLarge
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            let key = String(describing: pair.key)
            result[key] = String(describing: pair.value)
        }
        return GitHubAnonymousRESTHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            data: data
        )
    }
}

public actor GitHubAnonymousRESTAdapter {
    static let maximumResponseBytes = 5 * 1024 * 1024
    private static let pageSize = 100

    private let client: any GitHubAnonymousRESTHTTPClient
    private let budget: GitHubAnonymousRESTBudget
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubAnonymousREST")

    public init(
        budget: GitHubAnonymousRESTBudget,
        now: @escaping @Sendable () -> Date = currentDate
    ) {
        client = GitHubAnonymousURLSessionClient()
        self.budget = budget
        self.now = now
    }

    @usableFromInline
    static func currentDate() -> Date {
        Date()
    }

    init(
        client: any GitHubAnonymousRESTHTTPClient,
        budget: GitHubAnonymousRESTBudget,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.budget = budget
        self.now = now
    }

    public func repositoryFacts(
        repository: ForgeRepositoryIdentity,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgeRepositoryFacts> {
        let response = try await request(
            repository: repository,
            path: [],
            query: [],
            reason: reason
        )
        let payload = try decode(GitHubRESTRepository.self, from: response.data)
        let parent: ForgeRepositoryIdentity?
        if let fullName = payload.parent?.fullName {
            parent = try Self.repository(fullName: fullName, forge: repository.forge)
        } else {
            parent = nil
        }
        let facts = try ForgeRepositoryFacts(
            repository: repository,
            defaultBranch: .available(ForgeRefName(payload.defaultBranch)),
            description: .available(payload.description),
            topics: .available(payload.topics ?? []),
            visibility: .available(ForgeRepositoryVisibility(rawValue: payload.visibility ?? "") ?? .unknown),
            isArchived: .available(payload.archived),
            forkRelationship: .available(parent.map(ForgeForkRelationship.fork(parent:)) ?? .standalone),
            viewerCapabilities: .unavailable(.authenticationRequired)
        )
        return try result(facts, completeness: .partial, repository: repository, response: response)
    }

    public func pullRequests(
        repository: ForgeRepositoryIdentity,
        page cursor: ForgePageCursor? = nil,
        states: Set<ForgePullRequestState>? = nil,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgePage<ForgePullRequestSummary>> {
        let page = try Self.pageNumber(cursor)
        let state = Self.pullRequestStateParameter(states)
        let response = try await request(
            repository: repository,
            path: ["pulls"],
            query: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: String(Self.pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ],
            reason: reason
        )
        let payload = try decode([GitHubRESTPullRequest].self, from: response.data)
        let values = try payload.compactMap { item -> ForgePullRequestSummary? in
            let value = try Self.pullRequest(item, repository: repository)
            guard states?.contains(value.state) ?? true else { return nil }
            return value
        }
        let next = try Self.nextCursor(currentPage: page, itemCount: payload.count, headers: response.headers)
        let value = try ForgePage(items: values, nextCursor: next)
        return try result(value, completeness: .partial, repository: repository, response: response)
    }

    public func issues(
        repository: ForgeRepositoryIdentity,
        page cursor: ForgePageCursor? = nil,
        states: Set<ForgeIssueState>? = nil,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgePage<ForgeIssueSummary>> {
        let page = try Self.pageNumber(cursor)
        let response = try await request(
            repository: repository,
            path: ["issues"],
            query: [
                URLQueryItem(name: "state", value: Self.issueStateParameter(states)),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: String(Self.pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ],
            reason: reason
        )
        let payload = try decode([GitHubRESTIssue].self, from: response.data)
        let issuePayloads = payload.filter { $0.pullRequest == nil }
        let values = try issuePayloads.compactMap { item -> ForgeIssueSummary? in
            let value = try Self.issue(item, repository: repository)
            guard states?.contains(value.state) ?? true else { return nil }
            return value
        }
        let next = try Self.nextCursor(currentPage: page, itemCount: payload.count, headers: response.headers)
        let value = try ForgePage(items: values, nextCursor: next)
        return try result(value, completeness: .partial, repository: repository, response: response)
    }

    public func pullRequestDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgePullRequestDetailsPage> {
        let response = try await request(
            repository: repository,
            path: ["pulls", String(number.rawValue)],
            query: [],
            reason: reason
        )
        let payload = try decode(GitHubRESTPullRequest.self, from: response.data)
        let summary = try Self.pullRequest(payload, repository: repository)
        let details = try ForgePullRequestDetails(
            summary: summary,
            bodyMarkdown: .available(payload.body ?? ""),
            assignees: .available(payload.assignees.map { try Self.actor($0, forge: repository.forge) }),
            milestone: .available(payload.milestone.map { try Self.milestone($0, repository: repository) }),
            reviewers: .unavailable(.authenticationRequired),
            linkedIssues: .unavailable(.notRequested),
            mergeability: .available(Self.mergeability(payload.mergeable)),
            checks: .unavailable(.authenticationRequired),
            timeline: .unavailable(.notRequested)
        )
        return try result(
            ForgePullRequestDetailsPage(details: details, nextCheckCursor: nil),
            completeness: .partial,
            repository: repository,
            response: response
        )
    }

    public func issueDetails(
        repository: ForgeRepositoryIdentity,
        number: ForgeItemNumber,
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousReadResult<ForgeIssueDetails> {
        let response = try await request(
            repository: repository,
            path: ["issues", String(number.rawValue)],
            query: [],
            reason: reason
        )
        let payload = try decode(GitHubRESTIssue.self, from: response.data)
        guard payload.pullRequest == nil else {
            throw GitHubAnonymousRESTError.invalidResponse
        }
        let summary = try Self.issue(payload, repository: repository)
        let details = try ForgeIssueDetails(
            summary: summary,
            bodyMarkdown: .available(payload.body ?? ""),
            assignees: .available(payload.assignees.map { try Self.actor($0, forge: repository.forge) }),
            milestone: .available(payload.milestone.map { try Self.milestone($0, repository: repository) }),
            timeline: .unavailable(.notRequested)
        )
        return try result(details, completeness: .partial, repository: repository, response: response)
    }

    private func request(
        repository: ForgeRepositoryIdentity,
        path: [String],
        query: [URLQueryItem],
        reason: ForgeRefreshReason
    ) async throws -> GitHubAnonymousRESTHTTPResponse {
        guard Self.isGitHubDotCom(repository.forge) else {
            throw GitHubAnonymousRESTError.githubDotComRepositoryRequired
        }
        let requestedAt = now()
        let reservation = try await budget.reserve(reason: reason, at: requestedAt)
        let request = try Self.makeRequest(repository: repository, path: path, query: query)
        let response = try await client.execute(request)
        let receivedAt = now()
        await budget.update(
            reservation: reservation,
            status: response.statusCode,
            headers: response.headers,
            at: receivedAt
        )
        switch response.statusCode {
        case 200:
            logger.info("Anonymous GitHub read completed status=200 bytes=\(response.data.count, privacy: .public)")
            return response
        case 403, 429:
            let deadline = await budget.current().cooldownDeadline
            logger.notice("Anonymous GitHub read was rate limited status=\(response.statusCode, privacy: .public)")
            throw GitHubAnonymousRESTError.rateLimited(until: deadline)
        case 404:
            throw GitHubAnonymousRESTError.notFound
        default:
            logger.error("Anonymous GitHub read failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAnonymousRESTError.serverFailure(status: response.statusCode)
        }
    }

    private func result<Value: Sendable>(
        _ value: Value,
        completeness: GitHubReadCompleteness,
        repository: ForgeRepositoryIdentity,
        response: GitHubAnonymousRESTHTTPResponse
    ) throws -> GitHubAnonymousReadResult<Value> {
        let fetchedAt = now()
        let remaining = Self.integerHeader("x-ratelimit-remaining", headers: response.headers)
        let resetAt = Self.integerHeader("x-ratelimit-reset", headers: response.headers)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let retryAt = Self.integerHeader("retry-after", headers: response.headers)
            .map { fetchedAt.addingTimeInterval(TimeInterval($0)) }
        let metadata = GitHubResponseMetadata(
            statusCode: response.statusCode,
            requestID: Self.header("x-github-request-id", headers: response.headers),
            rateLimit: GitHubRateLimitMetadata(
                limit: Self.integerHeader("x-ratelimit-limit", headers: response.headers),
                remaining: remaining,
                used: Self.integerHeader("x-ratelimit-used", headers: response.headers),
                resetAt: resetAt,
                retryAt: retryAt,
                resource: Self.header("x-ratelimit-resource", headers: response.headers)
            ),
            saml: nil
        )
        return try GitHubAnonymousReadResult(
            value: value,
            completeness: completeness,
            response: metadata,
            partition: ForgeRepositoryPartitionKey(cachePartition: .publicAccess, repository: repository),
            fetchedAt: fetchedAt
        )
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= Self.maximumResponseBytes else {
            throw GitHubAnonymousRESTError.responseTooLarge
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubAnonymousRESTError.invalidResponse
        }
    }

    private static func makeRequest(
        repository: ForgeRepositoryIdentity,
        path: [String],
        query: [URLQueryItem]
    ) throws -> URLRequest {
        var url = URL(string: "https://api.github.com")!
        for component in ["repos", repository.owner, repository.name] + path {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        let requestURL = components.url!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitX", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }

    private static func isGitHubDotCom(_ forge: ForgeIdentity) -> Bool {
        let origin = forge.origin.url
        return forge.kind == .github
            && origin.scheme?.lowercased() == "https"
            && origin.host?.lowercased() == "github.com"
            && origin.port == nil
    }

    private static func pageNumber(_ cursor: ForgePageCursor?) throws -> Int {
        guard let cursor else { return 1 }
        let prefix = "rest-page:"
        guard cursor.value.hasPrefix(prefix),
              let page = Int(cursor.value.dropFirst(prefix.count)),
              page > 1
        else {
            throw GitHubAnonymousRESTError.invalidPageCursor
        }
        return page
    }

    private static func nextCursor(
        currentPage: Int,
        itemCount: Int,
        headers: [String: String]
    ) throws -> ForgePageCursor? {
        let link = header("link", headers: headers) ?? ""
        guard itemCount == pageSize || link.contains("rel=\"next\"") else { return nil }
        guard currentPage < Int.max else { throw GitHubAnonymousRESTError.invalidPageCursor }
        return try ForgePageCursor("rest-page:\(currentPage + 1)")
    }

    private static func pullRequestStateParameter(_ states: Set<ForgePullRequestState>?) -> String {
        guard let states, !states.isEmpty else { return "all" }
        if states == [.open] {
            return "open"
        }
        if states.isSubset(of: [.closed, .merged]) {
            return "closed"
        }
        // GitHub cannot filter for an enum value unknown to this client. Fetch
        // all and let the provider-neutral state filter retain only requested
        // values without guessing.
        return "all"
    }

    private static func issueStateParameter(_ states: Set<ForgeIssueState>?) -> String {
        guard let states, !states.isEmpty else { return "all" }
        if states == [.open] {
            return "open"
        }
        if states == [.closed] {
            return "closed"
        }
        return "all"
    }

    private static func pullRequestState(_ value: String) -> ForgePullRequestState {
        switch value.lowercased() {
        case "open": .open
        case "closed": .closed
        default: .unknown
        }
    }

    private static func issueState(_ value: String) -> ForgeIssueState {
        switch value.lowercased() {
        case "open": .open
        case "closed": .closed
        default: .unknown
        }
    }

    private static func milestoneState(_ value: String) -> ForgeMilestoneState {
        switch value.lowercased() {
        case "open": .open
        case "closed": .closed
        default: .unknown
        }
    }

    private static func pullRequest(
        _ payload: GitHubRESTPullRequest,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgePullRequestSummary {
        let state: ForgePullRequestState
        if payload.mergedAt != nil {
            state = .merged
        } else {
            state = pullRequestState(payload.state)
        }
        return try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(payload.number),
            state: state,
            isDraft: payload.draft ?? false,
            title: payload.title,
            author: author(payload.user, forge: repository.forge),
            head: pullRequestHead(payload.head, forge: repository.forge),
            base: branch(payload.base, fallbackRepository: repository),
            createdAt: date(payload.createdAt),
            updatedAt: date(payload.updatedAt),
            closedAt: payload.closedAt.map(date),
            mergedAt: payload.mergedAt.map(date),
            labels: .available(payload.labels.map { try label($0, repository: repository) }),
            checkRollup: .unavailable(.authenticationRequired),
            reviewRollup: .unavailable(.authenticationRequired)
        )
    }

    private static func issue(
        _ payload: GitHubRESTIssue,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeIssueSummary {
        try ForgeIssueSummary(
            repository: repository,
            number: ForgeItemNumber(payload.number),
            state: issueState(payload.state),
            title: payload.title,
            author: author(payload.user, forge: repository.forge),
            createdAt: date(payload.createdAt),
            updatedAt: date(payload.updatedAt),
            closedAt: payload.closedAt.map(date),
            labels: .available(payload.labels.map { try label($0, repository: repository) })
        )
    }

    private static func author(_ payload: GitHubRESTUser?, forge: ForgeIdentity) throws -> ForgeReadSection<ForgeAuthor> {
        guard let payload else { return .available(.deleted) }
        return try .available(.actor(actor(payload, forge: forge)))
    }

    private static func actor(_ payload: GitHubRESTUser, forge: ForgeIdentity) throws -> ForgeActor {
        let value = payload.nodeID ?? "rest-user:\(payload.id)"
        let type = payload.type.lowercased()
        let kind: ForgeActorKind
        if type == "user" {
            kind = payload.login.lowercased().hasSuffix("[bot]") ? .bot : .person
        } else if type == "organization" {
            kind = .organization
        } else if type == "bot" {
            kind = .bot
        } else {
            kind = .unknown
        }
        return try ForgeActor(
            id: ForgeObjectID(forge: forge, value: value),
            login: payload.login,
            avatarURL: payload.avatarURL.flatMap(URL.init(string:)),
            kind: kind
        )
    }

    private static func label(_ payload: GitHubRESTLabel, repository: ForgeRepositoryIdentity) throws -> ForgeLabel {
        try ForgeLabel(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: payload.nodeID ?? "rest-label:\(payload.id)"),
            name: payload.name,
            description: payload.description,
            color: payload.color.map(ForgeLabelColor.init)
        )
    }

    private static func milestone(
        _ payload: GitHubRESTMilestone,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeMilestone {
        try ForgeMilestone(
            repository: repository,
            id: ForgeObjectID(forge: repository.forge, value: payload.nodeID ?? "rest-milestone:\(payload.id)"),
            number: payload.number,
            title: payload.title,
            description: payload.description,
            state: milestoneState(payload.state),
            dueAt: payload.dueOn.map(date)
        )
    }

    private static func branch(
        _ payload: GitHubRESTBranch,
        fallbackRepository: ForgeRepositoryIdentity
    ) throws -> ForgeReadSection<ForgeBranchReference> {
        let repository: ForgeRepositoryIdentity
        if let fullName = payload.repository?.fullName {
            repository = try self.repository(fullName: fullName, forge: fallbackRepository.forge)
        } else {
            repository = fallbackRepository
        }
        return try .available(ForgeBranchReference(
            repository: repository,
            name: ForgeRefName(payload.ref),
            commit: ForgeCommitID(payload.sha)
        ))
    }

    private static func pullRequestHead(
        _ payload: GitHubRESTBranch,
        forge: ForgeIdentity
    ) throws -> ForgeReadSection<ForgePullRequestHead> {
        let repository: ForgeRepositoryIdentity? = if let fullName = payload.repository?.fullName {
            try self.repository(fullName: fullName, forge: forge)
        } else {
            nil
        }
        return try .available(ForgePullRequestHead(
            repository: repository,
            name: ForgeRefName(payload.ref),
            commit: ForgeCommitID(payload.sha)
        ))
    }

    private static func repository(fullName: String, forge: ForgeIdentity) throws -> ForgeRepositoryIdentity {
        let components = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { throw GitHubAnonymousRESTError.invalidResponse }
        return try ForgeRepositoryIdentity(
            forge: forge,
            owner: String(components[0]),
            name: String(components[1])
        )
    }

    private static func mergeability(_ value: Bool?) -> ForgeMergeability {
        guard let value else { return .unknown }
        return value ? .mergeable : .conflicting
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = GitHubISO8601DateParser.date(from: value) else {
            throw GitHubAnonymousRESTError.invalidResponse
        }
        return date
    }

    private static func header(_ name: String, headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func integerHeader(_ name: String, headers: [String: String]) -> Int? {
        header(name, headers: headers).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct GitHubRESTRepositoryReference: Decodable {
    let fullName: String

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

private struct GitHubRESTRepository: Decodable {
    let defaultBranch: String
    let description: String?
    let topics: [String]?
    let visibility: String?
    let archived: Bool
    let parent: GitHubRESTRepositoryReference?

    private enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
        case description
        case topics
        case visibility
        case archived
        case parent
    }
}

private struct GitHubRESTUser: Decodable {
    let id: Int64
    let nodeID: String?
    let login: String
    let avatarURL: String?
    let type: String

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case login
        case avatarURL = "avatar_url"
        case type
    }
}

private struct GitHubRESTLabel: Decodable {
    let id: Int64
    let nodeID: String?
    let name: String
    let description: String?
    let color: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case name
        case description
        case color
    }
}

private struct GitHubRESTMilestone: Decodable {
    let id: Int64
    let nodeID: String?
    let number: Int
    let title: String
    let description: String?
    let state: String
    let dueOn: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case number
        case title
        case description
        case state
        case dueOn = "due_on"
    }
}

private struct GitHubRESTBranchRepository: Decodable {
    let fullName: String

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

private struct GitHubRESTBranch: Decodable {
    let ref: String
    let sha: String
    let repository: GitHubRESTBranchRepository?

    private enum CodingKeys: String, CodingKey {
        case ref
        case sha
        case repository = "repo"
    }
}

private struct GitHubRESTPullRequest: Decodable {
    let number: Int
    let state: String
    let draft: Bool?
    let title: String
    let body: String?
    let user: GitHubRESTUser?
    let head: GitHubRESTBranch
    let base: GitHubRESTBranch
    let createdAt: String
    let updatedAt: String
    let closedAt: String?
    let mergedAt: String?
    let labels: [GitHubRESTLabel]
    let assignees: [GitHubRESTUser]
    let milestone: GitHubRESTMilestone?
    let mergeable: Bool?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case draft
        case title
        case body
        case user
        case head
        case base
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case mergedAt = "merged_at"
        case labels
        case assignees
        case milestone
        case mergeable
    }
}

private struct GitHubRESTPullRequestMarker: Decodable {}

private struct GitHubRESTIssue: Decodable {
    let number: Int
    let state: String
    let title: String
    let body: String?
    let user: GitHubRESTUser?
    let createdAt: String
    let updatedAt: String
    let closedAt: String?
    let labels: [GitHubRESTLabel]
    let assignees: [GitHubRESTUser]
    let milestone: GitHubRESTMilestone?
    let pullRequest: GitHubRESTPullRequestMarker?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case title
        case body
        case user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case labels
        case assignees
        case milestone
        case pullRequest = "pull_request"
    }
}
