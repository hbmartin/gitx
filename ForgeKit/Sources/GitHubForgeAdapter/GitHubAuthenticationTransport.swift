import ForgeKit
import Foundation
import os

public enum GitHubAuthenticationTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidHTTPResponse
    case unexpectedResponseEndpoint
    case responseTooLarge
    case rejectedStatus(Int)
    case authorizationFailure(GitHubRESTAuthorizationFailure)
    case rateLimited(GitHubRateLimitMetadata)
    case transportFailure
    case deviceFlowNotStarted
    case deviceFlowNotAuthorized
    case operationAlreadyInProgress
    case invalidRefreshSchedule
    case refreshAuthorizationExpired
    case samlRecoveryNotAvailable
    case invalidSAMLAuthorizationURL

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "GitHub returned an invalid HTTP response."
        case .unexpectedResponseEndpoint:
            "GitHub authentication returned from an unexpected endpoint."
        case .responseTooLarge:
            "GitHub returned an authentication response that was too large."
        case let .rejectedStatus(status):
            "GitHub rejected the authentication request with HTTP status \(status)."
        case let .authorizationFailure(failure):
            failure.description
        case .rateLimited:
            "GitHub rate limited the authentication request."
        case .transportFailure:
            "The GitHub authentication request could not be completed."
        case .deviceFlowNotStarted:
            "GitHub device authorization has not started."
        case .deviceFlowNotAuthorized:
            "GitHub device authorization has not completed."
        case .operationAlreadyInProgress:
            "A GitHub authentication operation is already in progress."
        case .invalidRefreshSchedule:
            "The GitHub Credential refresh schedule is invalid."
        case .refreshAuthorizationExpired:
            "The GitHub Credential must be authorized again."
        case .samlRecoveryNotAvailable:
            "GitHub SAML recovery is not available."
        case .invalidSAMLAuthorizationURL:
            "GitHub returned an invalid SAML authorization URL."
        }
    }
}

struct GitHubAuthenticationHTTPResponse: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let data: Data
    let statusCode: Int
    let url: URL
    let headers: [String: String]

    var description: String {
        "GitHub authentication HTTP response status=\(statusCode) (body and headers redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

protocol GitHubAuthenticationHTTPClient: Sendable {
    func perform(_ request: URLRequest) async throws -> GitHubAuthenticationHTTPResponse
}

// swift6-safety-justification: This stateless delegate rejects every redirect and owns no mutable state.
final class GitHubAuthenticationRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct GitHubURLSessionAuthenticationHTTPClient: GitHubAuthenticationHTTPClient {
    private let session: URLSession
    private let redirectDelegate = GitHubAuthenticationRedirectDelegate()

    init(configuration: URLSessionConfiguration) {
        let isolated = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        isolated.httpShouldSetCookies = false
        isolated.httpCookieStorage = nil
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.httpAdditionalHeaders = [:]
        session = URLSession(configuration: isolated)
    }

    func perform(_ request: URLRequest) async throws -> GitHubAuthenticationHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            guard let response = response as? HTTPURLResponse,
                  let url = response.url
            else {
                throw GitHubAuthenticationTransportError.invalidHTTPResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { values, entry in
                guard let name = entry.key as? String else { return }
                values[name] = String(describing: entry.value)
            }
            return GitHubAuthenticationHTTPResponse(
                data: data,
                statusCode: response.statusCode,
                url: url,
                headers: headers
            )
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? GitHubAuthenticationTransportError {
                throw error
            }
            throw GitHubAuthenticationTransportError.transportFailure
        }
    }
}

struct GitHubAuthenticatedUserRequest: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    static let endpoint = URL(string: "https://api.github.com/user")!

    let token: GitHubSecret

    var description: String {
        "GET api.github.com/user (Credential redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    func makeURLRequest() -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitX", forHTTPHeaderField: "User-Agent")
        token.withUnsafeUTF8Bytes { bytes in
            request.setValue("Bearer \(String(decoding: bytes, as: UTF8.self))", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

public enum GitHubPersonalAccessTokenScopeEvidence: Equatable, Sendable {
    case classic(scopes: Set<String>)
    case fineGrainedNotIntrospectable
}

public struct GitHubAuthenticatedUserIdentity: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let accountID: ForgeAccountID
    public let login: String
    public let databaseID: UInt64
    public let response: GitHubResponseMetadata

    public var description: String {
        "GitHub authenticated user identity (response redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubPersonalAccessTokenIntrospection: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let identity: GitHubAuthenticatedUserIdentity
    public let scopeEvidence: GitHubPersonalAccessTokenScopeEvidence

    public var accountID: ForgeAccountID {
        identity.accountID
    }

    public var login: String {
        identity.login
    }

    public var databaseID: UInt64 {
        identity.databaseID
    }

    public var response: GitHubResponseMetadata {
        identity.response
    }

    public var description: String {
        "GitHub personal access Credential introspection (response redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubAuthenticationTransport: Sendable {
    private static let maximumResponseSize = 1024 * 1024
    private let httpClient: any GitHubAuthenticationHTTPClient
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "github-authentication")

    public init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        httpClient = GitHubURLSessionAuthenticationHTTPClient(configuration: sessionConfiguration)
    }

    init(httpClient: any GitHubAuthenticationHTTPClient) {
        self.httpClient = httpClient
    }

    public func requestDeviceAuthorization(
        configuration: GitHubAppDeviceFlowConfiguration,
        receivedAt: Date = Date()
    ) async throws -> GitHubDeviceAuthorization {
        guard GitHubCheckedTime.isFinite(receivedAt) else {
            throw GitHubAuthenticationError.invalidDeviceAuthorization
        }
        let request = GitHubOAuthRequestFactory.deviceAuthorization(configuration: configuration)
        let response = try await perform(request.makeURLRequest(), expectedEndpoint: request.endpoint)
        guard response.statusCode == 200 else {
            logger.error("Device authorization failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.rejectedStatus(response.statusCode)
        }
        let authorization = try GitHubDeviceAuthorizationParser.parse(response.data, receivedAt: receivedAt)
        logger.notice("Device authorization started status=200")
        return authorization
    }

    public func refreshCredential(
        configuration: GitHubAppDeviceFlowConfiguration,
        credential: GitHubRotatingUserCredential,
        receivedAt: Date = Date()
    ) async throws -> GitHubRotatingUserCredential {
        guard GitHubCheckedTime.isFinite(receivedAt) else {
            throw GitHubAuthenticationTransportError.invalidRefreshSchedule
        }
        guard credential.canRefresh(at: receivedAt) else {
            throw GitHubAuthenticationTransportError.refreshAuthorizationExpired
        }
        let oauthRequest = GitHubOAuthRequestFactory.refresh(
            configuration: configuration,
            refreshToken: credential.refreshToken
        )
        let response = try await perform(oauthRequest.makeURLRequest(), expectedEndpoint: oauthRequest.endpoint)
        guard response.statusCode == 200 else {
            logger.error("Credential refresh failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.rejectedStatus(response.statusCode)
        }
        if Self.oauthErrorCode(response.data) == "bad_refresh_token" {
            throw GitHubAuthenticationTransportError.refreshAuthorizationExpired
        }
        let rotated = try GitHubOAuthTokenResponseParser.parse(response.data, receivedAt: receivedAt)
        logger.notice("Credential refresh completed status=200")
        return rotated
    }

    public func introspectPersonalAccessToken(
        _ entry: GitHubPersonalAccessTokenEntry,
        receivedAt: Date = Date()
    ) async throws -> GitHubPersonalAccessTokenIntrospection {
        let (identity, headers) = try await introspectAuthenticatedUser(
            accessToken: entry.token,
            receivedAt: receivedAt,
            samlRecoveryEligible: entry.kind == .classic
        )
        let scopeEvidence: GitHubPersonalAccessTokenScopeEvidence
        switch entry.kind {
        case .classic:
            scopeEvidence = .classic(scopes: Self.parseScopes(headers["x-oauth-scopes"]))
        case .fineGrained:
            scopeEvidence = .fineGrainedNotIntrospectable
        }
        logger.notice("Credential introspection completed status=200 kind=\(entry.kind.rawValue, privacy: .public)")
        return GitHubPersonalAccessTokenIntrospection(identity: identity, scopeEvidence: scopeEvidence)
    }

    public func introspectUserAccessCredential(
        _ credential: GitHubRotatingUserCredential,
        receivedAt: Date = Date()
    ) async throws -> GitHubAuthenticatedUserIdentity {
        let (identity, _) = try await introspectAuthenticatedUser(
            accessToken: credential.accessToken,
            receivedAt: receivedAt,
            samlRecoveryEligible: false
        )
        logger.notice("GitHub App user identity introspection completed status=200")
        return identity
    }

    private func introspectAuthenticatedUser(
        accessToken: GitHubSecret,
        receivedAt: Date,
        samlRecoveryEligible: Bool
    ) async throws -> (GitHubAuthenticatedUserIdentity, GitHubHTTPHeaders) {
        guard GitHubCheckedTime.isFinite(receivedAt) else {
            throw GitHubAuthenticationTransportError.invalidHTTPResponse
        }
        let userRequest = GitHubAuthenticatedUserRequest(token: accessToken)
        let response = try await perform(
            userRequest.makeURLRequest(),
            expectedEndpoint: GitHubAuthenticatedUserRequest.endpoint
        )
        let rateLimit = GitHubRateLimitParser.parse(
            statusCode: response.statusCode,
            headers: response.headers,
            receivedAt: receivedAt
        )
        if response.statusCode != 200,
           response.statusCode == 429 ||
           rateLimit.cooldownDeadline(statusCode: response.statusCode, now: receivedAt) != nil
        {
            logger.error("Credential introspection rate limited status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.rateLimited(rateLimit)
        }
        if let failure = GitHubRESTAuthorizationParser.parse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.data,
            installationConfigurationURL: nil
        ) {
            let effectiveFailure: GitHubRESTAuthorizationFailure
            if !samlRecoveryEligible,
               case .samlAuthorizationRequired = failure
            {
                // Fine-grained PATs are authorized for SAML during creation,
                // while GitHub App user tokens are authorized automatically.
                effectiveFailure = .authorizationDenied
            } else {
                effectiveFailure = failure
            }
            logger.error("Credential introspection authorization failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.authorizationFailure(effectiveFailure)
        }
        guard response.statusCode == 200 else {
            logger.error("Credential introspection failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.rejectedStatus(response.statusCode)
        }
        let identity = try Self.parseAuthenticatedUserIdentity(
            response.data,
            headers: response.headers,
            statusCode: response.statusCode,
            receivedAt: receivedAt
        )
        return (identity, GitHubHTTPHeaders(response.headers))
    }

    func pollDeviceAuthorization(
        configuration: GitHubAppDeviceFlowConfiguration,
        authorization: GitHubDeviceAuthorization
    ) async throws -> Data {
        let oauthRequest = GitHubOAuthRequestFactory.poll(
            configuration: configuration,
            deviceCode: authorization.deviceCode
        )
        let response = try await perform(oauthRequest.makeURLRequest(), expectedEndpoint: oauthRequest.endpoint)
        guard response.statusCode == 200 else {
            logger.error("Device authorization poll failed status=\(response.statusCode, privacy: .public)")
            throw GitHubAuthenticationTransportError.rejectedStatus(response.statusCode)
        }
        logger.debug("Device authorization poll completed status=200")
        return response.data
    }

    private func perform(
        _ request: URLRequest,
        expectedEndpoint: URL
    ) async throws -> GitHubAuthenticationHTTPResponse {
        let response = try await httpClient.perform(request)
        guard response.url == expectedEndpoint else {
            throw GitHubAuthenticationTransportError.unexpectedResponseEndpoint
        }
        guard response.data.count <= Self.maximumResponseSize else {
            throw GitHubAuthenticationTransportError.responseTooLarge
        }
        return response
    }

    private static func parseAuthenticatedUserIdentity(
        _ data: Data,
        headers values: [String: String],
        statusCode: Int,
        receivedAt: Date
    ) throws -> GitHubAuthenticatedUserIdentity {
        struct Payload: Decodable {
            let login: String
            let id: UInt64
            let nodeID: String

            enum CodingKeys: String, CodingKey {
                case login
                case id
                case nodeID = "node_id"
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isSafeIdentityComponent(payload.login),
              isSafeIdentityComponent(payload.nodeID),
              let forge = try? ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
              let accountID = try? ForgeAccountID(forge: forge, value: payload.nodeID)
        else {
            throw GitHubAuthenticationError.nonGitHubIdentity
        }
        let headers = GitHubHTTPHeaders(values)
        return GitHubAuthenticatedUserIdentity(
            accountID: accountID,
            login: payload.login,
            databaseID: payload.id,
            response: GitHubResponseMetadata(
                statusCode: statusCode,
                requestID: safeRequestID(headers["x-github-request-id"]),
                rateLimit: GitHubRateLimitParser.parse(
                    statusCode: statusCode,
                    headers: values,
                    receivedAt: receivedAt
                )
            )
        )
    }

    private static func oauthErrorCode(_ data: Data) -> String? {
        struct Payload: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.error
    }

    private static func isSafeIdentityComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func parseScopes(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(value.split(separator: ",").compactMap { component in
            let scope = component.trimmingCharacters(in: .whitespaces).lowercased()
            guard !scope.isEmpty,
                  scope.utf8.allSatisfy({ byte in
                      (byte >= 48 && byte <= 57) ||
                          (byte >= 97 && byte <= 122) ||
                          byte == 45 || byte == 58 || byte == 95
                  })
            else { return nil }
            return scope
        })
    }

    private static func safeRequestID(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) ||
                      (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      byte == 45 || byte == 58
              })
        else { return nil }
        return value
    }
}

public enum GitHubDeviceFlowCoordinatorState: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case ready
    case awaitingUserAuthorization(GitHubDeviceAuthorization, nextPollAt: Date)
    case terminal(GitHubDeviceFlowTerminalStatus)

    public var description: String {
        switch self {
        case .ready: "GitHub device flow ready."
        case .awaitingUserAuthorization: "GitHub device flow awaiting user authorization (code redacted)."
        case let .terminal(status): "GitHub device flow terminal status=\(status.rawValue)."
        }
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public actor GitHubDeviceFlowCoordinator {
    private let configuration: GitHubAppDeviceFlowConfiguration
    private let transport: GitHubAuthenticationTransport
    private var poller: GitHubDeviceFlowPoller?
    private var authorizedCredential: GitHubRotatingUserCredential?
    private var completedAuthorization: GitHubDeviceFlowAccountAuthorization?
    private var operationInProgress = false

    public init(
        configuration: GitHubAppDeviceFlowConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        transport = GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)
    }

    init(configuration: GitHubAppDeviceFlowConfiguration, transport: GitHubAuthenticationTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public var state: GitHubDeviceFlowCoordinatorState {
        guard let poller else { return .ready }
        switch poller.status {
        case let .active(nextPollAt):
            return .awaitingUserAuthorization(poller.authorization, nextPollAt: nextPollAt)
        case let .terminal(status):
            return .terminal(status)
        }
    }

    @discardableResult
    public func begin(receivedAt: Date = Date()) async throws -> GitHubDeviceAuthorization {
        guard !operationInProgress else {
            throw GitHubAuthenticationTransportError.operationAlreadyInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let authorization = try await transport.requestDeviceAuthorization(
            configuration: configuration,
            receivedAt: receivedAt
        )
        poller = GitHubDeviceFlowPoller(authorization: authorization)
        authorizedCredential = nil
        completedAuthorization = nil
        return authorization
    }

    public func poll(receivedAt: Date = Date()) async throws -> GitHubDeviceFlowPollResult {
        guard GitHubCheckedTime.isFinite(receivedAt) else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        guard var currentPoller = poller else {
            throw GitHubAuthenticationTransportError.deviceFlowNotStarted
        }
        if case let .terminal(status) = currentPoller.status {
            return .terminal(status)
        }
        if receivedAt >= currentPoller.authorization.expiresAt {
            let result = try currentPoller.consume(Data(), receivedAt: receivedAt)
            poller = currentPoller
            return result
        }
        if case let .active(nextPollAt) = currentPoller.status,
           receivedAt < nextPollAt
        {
            return .notYetPollable(nextPollAt: nextPollAt)
        }
        guard !operationInProgress else {
            throw GitHubAuthenticationTransportError.operationAlreadyInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let data = try await transport.pollDeviceAuthorization(
            configuration: configuration,
            authorization: currentPoller.authorization
        )
        let result = try currentPoller.consume(data, receivedAt: receivedAt)
        poller = currentPoller
        if case let .authorized(credential) = result {
            authorizedCredential = credential
        }
        return result
    }

    public func completeAuthorization(receivedAt: Date = Date()) async throws -> GitHubDeviceFlowAccountAuthorization {
        if let completedAuthorization {
            return completedAuthorization
        }
        guard let authorizedCredential else {
            throw GitHubAuthenticationTransportError.deviceFlowNotAuthorized
        }
        guard !operationInProgress else {
            throw GitHubAuthenticationTransportError.operationAlreadyInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let identity = try await transport.introspectUserAccessCredential(
            authorizedCredential,
            receivedAt: receivedAt
        )
        let authorization = GitHubDeviceFlowAccountAuthorization(
            credential: authorizedCredential,
            identity: identity
        )
        completedAuthorization = authorization
        return authorization
    }
}

public struct GitHubDeviceFlowAccountAuthorization: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let credential: GitHubRotatingUserCredential
    public let identity: GitHubAuthenticatedUserIdentity

    public var description: String {
        "GitHub device-flow Account authorization (Credential redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public enum GitHubCredentialRefreshDecision: Equatable, Sendable {
    case useCurrentCredential(refreshAt: Date)
    case refreshNow
    case reauthorizationRequired
}

public enum GitHubCredentialRefreshScheduler {
    public static func decision(
        for credential: GitHubRotatingUserCredential,
        at date: Date,
        minimumValidity: TimeInterval
    ) throws -> GitHubCredentialRefreshDecision {
        guard GitHubCheckedTime.isFinite(date),
              minimumValidity.isFinite,
              minimumValidity >= 0,
              GitHubCheckedTime.isFinite(credential.accessTokenExpiresAt),
              GitHubCheckedTime.isFinite(credential.refreshTokenExpiresAt)
        else {
            throw GitHubAuthenticationTransportError.invalidRefreshSchedule
        }
        guard credential.canRefresh(at: date) else {
            return .reauthorizationRequired
        }
        let earliestExpiry = min(credential.accessTokenExpiresAt, credential.refreshTokenExpiresAt)
        let refreshValue = earliestExpiry.timeIntervalSinceReferenceDate - minimumValidity
        guard refreshValue.isFinite else {
            throw GitHubAuthenticationTransportError.invalidRefreshSchedule
        }
        let refreshAt = Date(timeIntervalSinceReferenceDate: refreshValue)
        return date >= refreshAt ? .refreshNow : .useCurrentCredential(refreshAt: refreshAt)
    }
}

public enum GitHubCredentialRefreshResult: Equatable, Sendable {
    case current(refreshAt: Date)
    case refreshed(GitHubRotatingUserCredential)
    case reauthorizationRequired
}

public actor GitHubCredentialRefreshCoordinator {
    private struct InFlight: Sendable {
        let id: UInt64
        let credential: GitHubRotatingUserCredential
        let task: Task<GitHubRotatingUserCredential, Error>
    }

    private let configuration: GitHubAppDeviceFlowConfiguration
    private let transport: GitHubAuthenticationTransport
    private var nextID: UInt64 = 1
    private var inFlight: InFlight?

    public init(
        configuration: GitHubAppDeviceFlowConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        transport = GitHubAuthenticationTransport(sessionConfiguration: sessionConfiguration)
    }

    init(
        configuration: GitHubAppDeviceFlowConfiguration,
        transport: GitHubAuthenticationTransport,
        nextID: UInt64 = 1
    ) {
        self.configuration = configuration
        self.transport = transport
        self.nextID = nextID
    }

    public func refreshIfNeeded(
        _ credential: GitHubRotatingUserCredential,
        at date: Date = Date(),
        minimumValidity: TimeInterval
    ) async throws -> GitHubCredentialRefreshResult {
        switch try GitHubCredentialRefreshScheduler.decision(
            for: credential,
            at: date,
            minimumValidity: minimumValidity
        ) {
        case let .useCurrentCredential(refreshAt):
            return .current(refreshAt: refreshAt)
        case .reauthorizationRequired:
            return .reauthorizationRequired
        case .refreshNow:
            do {
                return try .refreshed(await coalescedRefresh(credential, receivedAt: date))
            } catch GitHubAuthenticationTransportError.refreshAuthorizationExpired {
                return .reauthorizationRequired
            }
        }
    }

    private func coalescedRefresh(
        _ credential: GitHubRotatingUserCredential,
        receivedAt: Date
    ) async throws -> GitHubRotatingUserCredential {
        if let inFlight {
            guard inFlight.credential == credential else {
                throw GitHubAuthenticationTransportError.operationAlreadyInProgress
            }
            return try await inFlight.task.value
        }
        guard nextID < UInt64.max else {
            throw GitHubAuthenticationTransportError.operationAlreadyInProgress
        }
        let id = nextID
        nextID += 1
        let configuration = configuration
        let transport = transport
        let task = Task {
            try await transport.refreshCredential(
                configuration: configuration,
                credential: credential,
                receivedAt: receivedAt
            )
        }
        inFlight = InFlight(id: id, credential: credential, task: task)
        do {
            let rotated = try await task.value
            if inFlight?.id == id {
                inFlight = nil
            }
            return rotated
        } catch {
            if inFlight?.id == id {
                inFlight = nil
            }
            throw error
        }
    }
}

public enum GitHubSAMLRetryState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    case idle
    case authorizeInBrowserAndRetry(URL)
    case retrying(URL)
    case declinedPreservingEffectiveCapabilities

    public var description: String {
        switch self {
        case .idle: "GitHub SAML recovery idle."
        case .authorizeInBrowserAndRetry: "GitHub SAML authorization required (URL redacted)."
        case .retrying: "GitHub SAML recovery retrying (URL redacted)."
        case .declinedPreservingEffectiveCapabilities:
            "GitHub SAML recovery declined; effective capabilities preserved."
        }
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public actor GitHubSAMLRetryCoordinator {
    public private(set) var state: GitHubSAMLRetryState = .idle

    public init() {}

    @discardableResult
    public func offer(
        for failure: GitHubRESTAuthorizationFailure,
        credentialSource: ForgeCredentialSource
    ) throws -> GitHubSAMLRetryState {
        guard credentialSource == .classicPersonalAccessToken || credentialSource == .commandLineBroker else {
            // Fine-grained PATs receive SAML authorization during creation and
            // GitHub App user tokens are authorized by their installation.
            throw GitHubAuthenticationTransportError.samlRecoveryNotAvailable
        }
        guard case let .samlAuthorizationRequired(authorizeURL) = failure else {
            throw GitHubAuthenticationTransportError.samlRecoveryNotAvailable
        }
        guard Self.isSafeSAMLAuthorizationURL(authorizeURL) else {
            throw GitHubAuthenticationTransportError.invalidSAMLAuthorizationURL
        }
        state = .authorizeInBrowserAndRetry(authorizeURL)
        return state
    }

    @discardableResult
    public func offer(
        for metadata: GitHubSAMLMetadata,
        credentialSource: ForgeCredentialSource
    ) throws -> GitHubSAMLRetryState {
        guard let authorizationURL = metadata.authorizationURL else {
            throw GitHubAuthenticationTransportError.samlRecoveryNotAvailable
        }
        return try offer(
            for: .samlAuthorizationRequired(authorizeURL: authorizationURL),
            credentialSource: credentialSource
        )
    }

    public func retry<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard case let .authorizeInBrowserAndRetry(url) = state else {
            if case .retrying = state {
                throw GitHubAuthenticationTransportError.operationAlreadyInProgress
            }
            throw GitHubAuthenticationTransportError.samlRecoveryNotAvailable
        }
        state = .retrying(url)
        do {
            let value = try await operation()
            if state == .retrying(url) {
                state = .idle
            }
            return value
        } catch {
            if state == .retrying(url) {
                state = .authorizeInBrowserAndRetry(url)
            }
            throw error
        }
    }

    @discardableResult
    public func decline() throws -> GitHubSAMLRetryState {
        guard case .authorizeInBrowserAndRetry = state else {
            if case .retrying = state {
                throw GitHubAuthenticationTransportError.operationAlreadyInProgress
            }
            throw GitHubAuthenticationTransportError.samlRecoveryNotAvailable
        }
        state = .declinedPreservingEffectiveCapabilities
        return state
    }

    private static func isSafeSAMLAuthorizationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.scheme == "https" &&
            components.host?.lowercased() == "github.com" &&
            components.user == nil &&
            components.password == nil &&
            components.port == nil &&
            path.count == 3 &&
            path[0] == "orgs" &&
            path[2] == "sso" &&
            components.fragment == nil
    }
}
