import ForgeKit
import Foundation

public enum GitHubAuthenticationError: Error, Equatable, LocalizedError, Sendable {
    case invalidClientIdentifier
    case invalidApplicationSlug
    case invalidSecret
    case invalidPersonalAccessTokenLabel
    case invalidPersonalAccessTokenExpiry
    case invalidDeviceAuthorization
    case invalidTokenResponse
    case unsupportedTokenType
    case mismatchedCredentialAuthority
    case authorizationDenied
    case deviceCodeExpired
    case serverRejectedAuthorization
    case nonGitHubIdentity

    public var errorDescription: String? {
        switch self {
        case .invalidClientIdentifier:
            "The GitHub App client identifier is invalid."
        case .invalidApplicationSlug:
            "The GitHub App slug is invalid."
        case .invalidSecret:
            "The GitHub Credential is invalid."
        case .invalidPersonalAccessTokenLabel:
            "The personal access token label is invalid."
        case .invalidPersonalAccessTokenExpiry:
            "The personal access token expiry is invalid."
        case .invalidDeviceAuthorization:
            "GitHub returned an invalid device authorization."
        case .invalidTokenResponse:
            "GitHub returned an invalid Credential response."
        case .unsupportedTokenType:
            "GitHub returned an unsupported Credential type."
        case .mismatchedCredentialAuthority:
            "The GitHub authority evidence does not match the Credential source."
        case .authorizationDenied:
            "GitHub authorization was denied."
        case .deviceCodeExpired:
            "The GitHub device code expired."
        case .serverRejectedAuthorization:
            "GitHub rejected the authorization request."
        case .nonGitHubIdentity:
            "GitHub authorization evidence cannot be attached to another Forge."
        }
    }
}

enum GitHubCheckedTime {
    static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    static func adding(_ interval: TimeInterval, to date: Date) -> Date? {
        guard interval.isFinite, isFinite(date) else { return nil }
        let value = date.timeIntervalSinceReferenceDate + interval
        guard value.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }
}

/// Secret-bearing values intentionally provide only a redacted textual and
/// reflection surface. Callers may hand bytes to an approved Credential store
/// or transport without first materializing another `String`.
public struct GitHubSecret: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private let bytes: [UInt8]

    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, !bytes.contains(where: { $0 < 0x21 || $0 == 0x7F }) else {
            throw GitHubAuthenticationError.invalidSecret
        }
        self.bytes = bytes
    }

    /// Creates a secret directly from validated UTF-8 bytes without requiring
    /// the caller to materialize credential data as an ordinary `String`.
    public init(utf8Bytes value: Data) throws {
        let bytes = Array(value)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
            throw GitHubAuthenticationError.invalidSecret
        }
        self.bytes = bytes
    }

    public var description: String {
        "<redacted>"
    }

    public var debugDescription: String {
        "<redacted>"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    public func withUnsafeUTF8Bytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try bytes.withUnsafeBytes(body)
    }

    fileprivate var formValue: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

public struct GitHubAppDeviceFlowConfiguration: Hashable, Sendable {
    public let clientID: String
    public let applicationSlug: String

    public init(clientID: String, applicationSlug: String) throws {
        guard Self.isIdentifier(clientID) else {
            throw GitHubAuthenticationError.invalidClientIdentifier
        }
        guard Self.isSlug(applicationSlug) else {
            throw GitHubAuthenticationError.invalidApplicationSlug
        }
        self.clientID = clientID
        self.applicationSlug = applicationSlug
    }

    public static let deviceAuthorizationURL = URL(string: "https://github.com/login/device/code")!
    public static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    public var newInstallationURL: URL {
        URL(string: "https://github.com/apps/\(applicationSlug)/installations/new")!
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        }
    }

    private static func isSlug(_ value: String) -> Bool {
        guard value.first != "-", value.last != "-", !value.isEmpty else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
}

struct GitHubOAuthRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let endpoint: URL
    let form: [(String, String)]

    var description: String {
        "POST \(endpoint.host ?? "github.com")\(endpoint.path) (body redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    func makeURLRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        return request
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte in
            let isUnreserved = (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                [45, 46, 95, 126].contains(byte)
            return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}

enum GitHubOAuthRequestFactory {
    static func deviceAuthorization(configuration: GitHubAppDeviceFlowConfiguration) -> GitHubOAuthRequest {
        GitHubOAuthRequest(
            endpoint: GitHubAppDeviceFlowConfiguration.deviceAuthorizationURL,
            form: [("client_id", configuration.clientID)]
        )
    }

    static func poll(
        configuration: GitHubAppDeviceFlowConfiguration,
        deviceCode: GitHubSecret
    ) -> GitHubOAuthRequest {
        GitHubOAuthRequest(
            endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
            form: [
                ("client_id", configuration.clientID),
                ("device_code", deviceCode.formValue),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ]
        )
    }

    static func refresh(
        configuration: GitHubAppDeviceFlowConfiguration,
        refreshToken: GitHubSecret
    ) -> GitHubOAuthRequest {
        GitHubOAuthRequest(
            endpoint: GitHubAppDeviceFlowConfiguration.tokenURL,
            form: [
                ("client_id", configuration.clientID),
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken.formValue),
            ]
        )
    }
}

public struct GitHubDeviceAuthorization: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let deviceCode: GitHubSecret
    public let userCode: String
    public let verificationURL: URL
    public let issuedAt: Date
    public let expiresAt: Date
    public let pollingInterval: TimeInterval

    public var description: String {
        "GitHub device authorization (code redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public enum GitHubDeviceAuthorizationParser {
    public static func parse(_ data: Data, receivedAt: Date) throws -> GitHubDeviceAuthorization {
        struct Payload: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationURI: URL
            let expiresIn: TimeInterval
            let interval: TimeInterval

            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case userCode = "user_code"
                case verificationURI = "verification_uri"
                case expiresIn = "expires_in"
                case interval
            }
        }

        guard GitHubCheckedTime.isFinite(receivedAt),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isDeviceVerificationURL(payload.verificationURI),
              !payload.userCode.isEmpty,
              payload.userCode.utf8.allSatisfy({ $0 >= 0x21 && $0 != 0x7F }),
              payload.expiresIn.isFinite,
              payload.expiresIn > 0,
              payload.interval.isFinite,
              payload.interval > 0,
              let code = try? GitHubSecret(payload.deviceCode),
              let expiresAt = GitHubCheckedTime.adding(payload.expiresIn, to: receivedAt),
              let firstPollAt = GitHubCheckedTime.adding(payload.interval, to: receivedAt),
              firstPollAt < expiresAt
        else {
            throw GitHubAuthenticationError.invalidDeviceAuthorization
        }
        return GitHubDeviceAuthorization(
            deviceCode: code,
            userCode: payload.userCode,
            verificationURL: payload.verificationURI,
            issuedAt: receivedAt,
            expiresAt: expiresAt,
            pollingInterval: payload.interval
        )
    }

    private static func isDeviceVerificationURL(_ url: URL) -> Bool {
        url.scheme == "https" &&
            url.host?.lowercased() == "github.com" &&
            url.user == nil &&
            url.password == nil &&
            url.port == nil &&
            url.path == "/login/device" &&
            url.query == nil &&
            url.fragment == nil
    }
}

public struct GitHubRotatingUserCredential: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let accessToken: GitHubSecret
    public let accessTokenExpiresAt: Date
    public let refreshToken: GitHubSecret
    public let refreshTokenExpiresAt: Date

    public init(
        accessToken: GitHubSecret,
        accessTokenExpiresAt: Date,
        refreshToken: GitHubSecret,
        refreshTokenExpiresAt: Date
    ) throws {
        guard GitHubCheckedTime.isFinite(accessTokenExpiresAt),
              GitHubCheckedTime.isFinite(refreshTokenExpiresAt),
              accessTokenExpiresAt < refreshTokenExpiresAt
        else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public var description: String {
        "GitHub rotating user Credential (tokens redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    public var forgeExpiryMetadata: Date {
        accessTokenExpiresAt
    }

    public func isAccessTokenExpired(at date: Date) -> Bool {
        date >= accessTokenExpiresAt
    }

    public func canRefresh(at date: Date) -> Bool {
        date < refreshTokenExpiresAt
    }
}

private struct GitHubOAuthResponsePayload: Decodable {
    let accessToken: String?
    let expiresIn: TimeInterval?
    let refreshToken: String?
    let refreshTokenExpiresIn: TimeInterval?
    let tokenType: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case tokenType = "token_type"
        case error
    }
}

public enum GitHubOAuthTokenResponseParser {
    public static func parse(_ data: Data, receivedAt: Date) throws -> GitHubRotatingUserCredential {
        guard GitHubCheckedTime.isFinite(receivedAt),
              let payload = try? JSONDecoder().decode(GitHubOAuthResponsePayload.self, from: data)
        else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        if payload.error != nil {
            throw GitHubAuthenticationError.serverRejectedAuthorization
        }
        guard payload.tokenType?.lowercased() == "bearer" else {
            throw GitHubAuthenticationError.unsupportedTokenType
        }
        guard let accessTokenValue = payload.accessToken,
              let refreshTokenValue = payload.refreshToken,
              let accessLifetime = payload.expiresIn,
              let refreshLifetime = payload.refreshTokenExpiresIn,
              accessLifetime.isFinite,
              refreshLifetime.isFinite,
              accessLifetime > 0,
              refreshLifetime > 0,
              let accessToken = try? GitHubSecret(accessTokenValue),
              let refreshToken = try? GitHubSecret(refreshTokenValue),
              let accessTokenExpiresAt = GitHubCheckedTime.adding(accessLifetime, to: receivedAt),
              let refreshTokenExpiresAt = GitHubCheckedTime.adding(refreshLifetime, to: receivedAt)
        else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        return try GitHubRotatingUserCredential(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        )
    }
}

public enum GitHubDeviceFlowPollResult: Equatable, Sendable {
    case notYetPollable(nextPollAt: Date)
    case pending(nextPollAt: Date)
    case slowedDown(nextPollAt: Date)
    case authorized(GitHubRotatingUserCredential)
    case expired
    case denied
    case terminal(GitHubDeviceFlowTerminalStatus)
}

public enum GitHubDeviceFlowTerminalStatus: String, Equatable, Sendable {
    case authorized
    case expired
    case denied
}

public enum GitHubDeviceFlowPollStatus: Equatable, Sendable {
    case active(nextPollAt: Date)
    case terminal(GitHubDeviceFlowTerminalStatus)
}

public struct GitHubDeviceFlowPoller: Equatable, Sendable {
    public let authorization: GitHubDeviceAuthorization
    public private(set) var pollingInterval: TimeInterval
    public private(set) var status: GitHubDeviceFlowPollStatus

    public init(authorization: GitHubDeviceAuthorization) {
        self.authorization = authorization
        pollingInterval = authorization.pollingInterval
        status = .active(
            nextPollAt: GitHubCheckedTime.adding(authorization.pollingInterval, to: authorization.issuedAt) ??
                authorization.expiresAt
        )
    }

    public mutating func consume(_ data: Data, receivedAt: Date) throws -> GitHubDeviceFlowPollResult {
        guard GitHubCheckedTime.isFinite(receivedAt) else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        let nextPollAt: Date
        switch status {
        case let .active(value):
            nextPollAt = value
        case let .terminal(terminalStatus):
            return .terminal(terminalStatus)
        }
        guard receivedAt < authorization.expiresAt else {
            status = .terminal(.expired)
            return .expired
        }
        guard receivedAt >= nextPollAt else {
            return .notYetPollable(nextPollAt: nextPollAt)
        }
        guard let payload = try? JSONDecoder().decode(GitHubOAuthResponsePayload.self, from: data) else {
            throw GitHubAuthenticationError.invalidTokenResponse
        }
        switch payload.error {
        case "authorization_pending":
            let nextPollAt = try scheduleNextPoll(after: receivedAt)
            return .pending(nextPollAt: nextPollAt)
        case "slow_down":
            pollingInterval = try Self.slowedInterval(from: pollingInterval)
            let nextPollAt = try scheduleNextPoll(after: receivedAt)
            return .slowedDown(nextPollAt: nextPollAt)
        case "expired_token":
            status = .terminal(.expired)
            return .expired
        case "access_denied":
            status = .terminal(.denied)
            return .denied
        case .some:
            throw GitHubAuthenticationError.serverRejectedAuthorization
        case .none:
            let credential = try GitHubOAuthTokenResponseParser.parse(data, receivedAt: receivedAt)
            status = .terminal(.authorized)
            return .authorized(credential)
        }
    }

    private mutating func scheduleNextPoll(after date: Date) throws -> Date {
        guard let scheduled = GitHubCheckedTime.adding(pollingInterval, to: date) else {
            throw GitHubAuthenticationError.invalidDeviceAuthorization
        }
        let nextPollAt = min(scheduled, authorization.expiresAt)
        status = .active(nextPollAt: nextPollAt)
        return nextPollAt
    }

    static func slowedInterval(from interval: TimeInterval) throws -> TimeInterval {
        let slowedInterval = interval + 5
        guard interval.isFinite, slowedInterval.isFinite else {
            throw GitHubAuthenticationError.invalidDeviceAuthorization
        }
        return slowedInterval
    }
}

public enum GitHubCredentialBrokerageIntent: String, CaseIterable, Sendable {
    case explicitAddAccount
    case backgroundRefresh
    case runtimeFallback
}

public enum GitHubCredentialBrokerageDecision: Equatable, Sendable {
    case allowedForAddAccount
    case denied
}

public enum GitHubCLIBrokeragePolicy {
    public static func decision(for intent: GitHubCredentialBrokerageIntent) -> GitHubCredentialBrokerageDecision {
        intent == .explicitAddAccount ? .allowedForAddAccount : .denied
    }
}

public enum GitHubPersonalAccessTokenKind: String, CaseIterable, Hashable, Sendable {
    case fineGrained
    case classic

    public var forgeCredentialSource: ForgeCredentialSource {
        switch self {
        case .fineGrained: .fineGrainedPersonalAccessToken
        case .classic: .classicPersonalAccessToken
        }
    }
}

public struct GitHubPersonalAccessTokenEntry: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let token: GitHubSecret
    public let kind: GitHubPersonalAccessTokenKind
    public let label: String?
    public let expiresAt: Date?

    public init(
        token: GitHubSecret,
        kind: GitHubPersonalAccessTokenKind,
        label: String? = nil,
        expiresAt: Date? = nil
    ) throws {
        if let label {
            guard !label.isEmpty,
                  label.count <= 80,
                  label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                throw GitHubAuthenticationError.invalidPersonalAccessTokenLabel
            }
        }
        guard expiresAt.map(GitHubCheckedTime.isFinite) ?? true else {
            throw GitHubAuthenticationError.invalidPersonalAccessTokenExpiry
        }
        self.token = token
        self.kind = kind
        self.label = label
        self.expiresAt = expiresAt
    }

    public var description: String {
        "GitHub \(kind.rawValue) personal access Credential (token redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
