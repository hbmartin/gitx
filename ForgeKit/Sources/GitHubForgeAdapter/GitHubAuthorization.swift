import ForgeKit
import Foundation

struct GitHubHTTPHeaders: Equatable, Sendable {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values.sorted { $0.key < $1.key }.reduce(into: [:]) {
            $0[$1.key.lowercased()] = $1.value
        }
    }

    subscript(_ name: String) -> String? {
        values[name.lowercased()]
    }
}

public enum GitHubRESTAuthorizationFailure: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    case badCredentials
    case authorizationDenied
    case samlAuthorizationRequired(authorizeURL: URL)
    case installationConfigurationRequired(configurationURL: URL)

    public var description: String {
        switch self {
        case .badCredentials: "GitHub authorization failed: bad Credential."
        case .authorizationDenied: "GitHub authorization was denied."
        case .samlAuthorizationRequired: "GitHub organization authorization is required (URL redacted)."
        case .installationConfigurationRequired: "GitHub App repository access configuration is required (URL redacted)."
        }
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public enum GitHubRESTAuthorizationParser {
    public static func parse(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        installationConfigurationURL: URL?
    ) -> GitHubRESTAuthorizationFailure? {
        guard statusCode == 401 || statusCode == 403 || statusCode == 404 else { return nil }
        let headers = GitHubHTTPHeaders(headers)
        if let sso = headers["x-github-sso"],
           let authorizeURL = samlURL(from: sso)
        {
            return .samlAuthorizationRequired(authorizeURL: authorizeURL)
        }
        if statusCode == 401 {
            return .badCredentials
        }
        if isMissingInstallationResponse(body),
           let installationConfigurationURL,
           isInstallationConfigurationURL(installationConfigurationURL)
        {
            return .installationConfigurationRequired(configurationURL: installationConfigurationURL)
        }
        return .authorizationDenied
    }

    private static func samlURL(from header: String) -> URL? {
        let candidate = header
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("url=") }?
            .dropFirst(4)
        guard let candidate, let url = URL(string: String(candidate)), isSAMLURL(url) else { return nil }
        return url
    }

    private static func isSAMLURL(_ url: URL) -> Bool {
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

    private static func isInstallationConfigurationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else { return false }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        if path.count == 3,
           path[0] == "settings",
           path[1] == "installations",
           UInt64(path[2]) != nil
        {
            return true
        }
        if path.count == 5,
           path[0] == "organizations",
           path[2] == "settings",
           path[3] == "installations",
           UInt64(path[4]) != nil
        {
            return true
        }
        return path.count == 4 && path[0] == "apps" && path[2] == "installations" && path[3] == "new"
    }

    private static func isMissingInstallationResponse(_ body: Data) -> Bool {
        struct Payload: Decodable { let message: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else { return false }
        let message = payload.message.lowercased()
        return message.contains("resource not accessible by integration") ||
            message.contains("repository is not accessible by this app") ||
            message.contains("installation not found")
    }
}

public struct GitHubRateLimitMetadata: Equatable, Sendable {
    public let limit: Int?
    public let remaining: Int?
    public let used: Int?
    public let resetAt: Date?
    public let retryAt: Date?
    public let resource: String?

    public func cooldownDeadline(statusCode: Int, now: Date) -> Date? {
        guard GitHubCheckedTime.isFinite(now) else { return nil }
        let isThrottled = statusCode == 429 || remaining == 0 || retryAt != nil
        guard isThrottled else { return nil }
        if let reported = [retryAt, resetAt]
            .compactMap({ $0 })
            .filter({ GitHubCheckedTime.isFinite($0) && $0 > now })
            .max()
        {
            return reported
        }
        guard statusCode == 429 else { return nil }
        return GitHubCheckedTime.adding(60, to: now)
    }

    public func credentialCooldown(
        statusCode: Int,
        credential: ForgeCredentialReference,
        now: Date
    ) -> ForgeCredentialCooldown? {
        guard let deadline = cooldownDeadline(statusCode: statusCode, now: now) else { return nil }
        return ForgeCredentialCooldown(credential: credential, deadline: deadline)
    }
}

public enum GitHubRateLimitParser {
    public static func parse(
        statusCode _: Int,
        headers values: [String: String],
        receivedAt: Date
    ) -> GitHubRateLimitMetadata {
        let headers = GitHubHTTPHeaders(values)
        let limit = nonnegativeInteger(headers["x-ratelimit-limit"])
        let remaining = nonnegativeInteger(headers["x-ratelimit-remaining"])
        let used = nonnegativeInteger(headers["x-ratelimit-used"])
        let resetAt = epochDate(headers["x-ratelimit-reset"])
        let retryAt = retryDate(headers["retry-after"], receivedAt: receivedAt)
        let resource = safeResource(headers["x-ratelimit-resource"])
        return GitHubRateLimitMetadata(
            limit: limit,
            remaining: remaining.flatMap { value in
                guard let limit else { return value }
                return value <= limit ? value : nil
            },
            used: used.flatMap { value in
                guard let limit else { return value }
                return value <= limit ? value : nil
            },
            resetAt: resetAt,
            retryAt: retryAt,
            resource: resource
        )
    }

    private static func nonnegativeInteger(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), parsed >= 0 else { return nil }
        return parsed
    }

    private static func epochDate(_ value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return GitHubCheckedTime.isFinite(date) ? date : nil
    }

    private static func retryDate(_ value: String?, receivedAt: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return GitHubCheckedTime.adding(seconds, to: receivedAt)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value), GitHubCheckedTime.isFinite(date) else { return nil }
        return date
    }

    private static func safeResource(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
              })
        else { return nil }
        return value
    }
}

public enum GitHubPermissionAccess: String, CaseIterable, Hashable, Sendable {
    case none
    case read
    case write
    case admin

    var forgeAuthority: ForgePermissionAuthority {
        switch self {
        case .none: .known(.unavailable)
        case .read: .known(.read)
        case .write, .admin: .known(.write)
        }
    }
}

public struct GitHubPermissionSnapshot: Equatable, Sendable {
    public let permissions: [String: GitHubPermissionAccess]
    public let isComplete: Bool
}

public struct GitHubAppPermissionRequest: Equatable, Sendable {
    public let permissions: [String: GitHubPermissionAccess]

    fileprivate init(permissions: [String: GitHubPermissionAccess]) {
        self.permissions = permissions
    }
}

public enum GitHubCredentialAuthority: Equatable, Sendable {
    case appUserToken(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        permissions: GitHubPermissionSnapshot
    )
    case classicPersonalAccessToken(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        scopes: Set<String>,
        repositoryIsPublic: Bool
    )
    case fineGrainedPersonalAccessToken(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        permissions: GitHubPermissionSnapshot
    )
    case commandLineBroker(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        scopes: Set<String>,
        repositoryIsPublic: Bool
    )
}

public enum GitHubCapabilityMapper {
    private struct AuthorityBinding {
        let credential: ForgeCredentialReference
        let repository: ForgeRepositoryIdentity
        let source: ForgeCredentialSource
    }

    public static let milestone3AppPermissionRequest = GitHubAppPermissionRequest(
        permissions: [
            "metadata": .read,
            "contents": .write,
            "pull_requests": .write,
            "issues": .write,
            "checks": .read,
            "statuses": .read,
        ]
    )

    public static func permissionEvidence(
        credentialMetadata: ForgeCredentialMetadata,
        repository: ForgeRepositoryIdentity,
        authority: GitHubCredentialAuthority,
        freshness: ForgeAuthorizationEvidenceFreshness = .current
    ) throws -> ForgePermissionEvidence {
        try validate(credential: credentialMetadata.reference, repository: repository)
        let binding = binding(for: authority)
        guard binding.credential == credentialMetadata.reference,
              binding.repository == repository,
              binding.source == credentialMetadata.source
        else {
            throw GitHubAuthenticationError.mismatchedCredentialAuthority
        }
        return try ForgePermissionEvidence(
            credential: credentialMetadata.reference,
            repository: repository,
            freshness: freshness,
            grants: ForgeRepositoryPermission.allCases.map {
                ForgePermissionGrant(permission: $0, authority: permission($0, from: authority))
            }
        )
    }

    public static func repositoryAccessEvidence(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity,
        viewerPermission: String?,
        failure: GitHubRESTAuthorizationFailure? = nil,
        freshness: ForgeAuthorizationEvidenceFreshness = .current
    ) throws -> ForgeRepositoryAccessEvidence {
        try validate(credential: credential, repository: repository)
        let status: ForgeRepositoryAccessStatus
        switch failure {
        case .samlAuthorizationRequired:
            status = .samlAuthorizationRequired
        case .installationConfigurationRequired:
            status = .installationConfigurationRequired
        case .badCredentials, .authorizationDenied:
            status = .denied
        case .none:
            status = viewerPermission == nil ? .unknown : .granted
        }
        return ForgeRepositoryAccessEvidence(
            credential: credential,
            repository: repository,
            freshness: freshness,
            status: status,
            role: role(from: viewerPermission)
        )
    }

    public static func role(from viewerPermission: String?) -> ForgeRepositoryRoleEvidence {
        switch viewerPermission?.uppercased() {
        case "NONE": .known(.none)
        case "READ": .known(.read)
        case "TRIAGE": .known(.triage)
        case "WRITE": .known(.write)
        case "MAINTAIN": .known(.maintain)
        case "ADMIN": .known(.admin)
        default: .unknown
        }
    }

    private static func validate(
        credential: ForgeCredentialReference,
        repository: ForgeRepositoryIdentity
    ) throws {
        guard credential.accountID.forge.kind == .github,
              repository.forge.kind == .github,
              credential.accountID.forge == repository.forge,
              repository.forge.origin.host == "github.com",
              repository.forge.origin.port == nil
        else {
            throw GitHubAuthenticationError.nonGitHubIdentity
        }
    }

    private static func binding(for authority: GitHubCredentialAuthority) -> AuthorityBinding {
        switch authority {
        case let .appUserToken(credential, repository, _):
            AuthorityBinding(
                credential: credential,
                repository: repository,
                source: .forgeApplicationDeviceFlow
            )
        case let .classicPersonalAccessToken(credential, repository, _, _):
            AuthorityBinding(
                credential: credential,
                repository: repository,
                source: .classicPersonalAccessToken
            )
        case let .fineGrainedPersonalAccessToken(credential, repository, _):
            AuthorityBinding(
                credential: credential,
                repository: repository,
                source: .fineGrainedPersonalAccessToken
            )
        case let .commandLineBroker(credential, repository, _, _):
            AuthorityBinding(
                credential: credential,
                repository: repository,
                source: .commandLineBroker
            )
        }
    }

    private static func permission(
        _ forgePermission: ForgeRepositoryPermission,
        from authority: GitHubCredentialAuthority
    ) -> ForgePermissionAuthority {
        switch authority {
        case let .appUserToken(_, _, snapshot), let .fineGrainedPersonalAccessToken(_, _, snapshot):
            return permission(forgePermission, from: snapshot)
        case let .classicPersonalAccessToken(_, _, scopes, repositoryIsPublic),
             let .commandLineBroker(_, _, scopes, repositoryIsPublic):
            return permission(forgePermission, scopes: scopes, repositoryIsPublic: repositoryIsPublic)
        }
    }

    private static func permission(
        _ permission: ForgeRepositoryPermission,
        from snapshot: GitHubPermissionSnapshot
    ) -> ForgePermissionAuthority {
        let key: String
        switch permission {
        case .metadata: key = "metadata"
        case .contents: key = "contents"
        case .pullRequests: key = "pull_requests"
        case .issues: key = "issues"
        case .checks: key = "checks"
        case .commitStatuses: key = "statuses"
        }
        if let access = snapshot.permissions[key] {
            return access.forgeAuthority
        }
        return snapshot.isComplete ? .known(.unavailable) : .unknown
    }

    private static func permission(
        _ permission: ForgeRepositoryPermission,
        scopes originalScopes: Set<String>,
        repositoryIsPublic: Bool
    ) -> ForgePermissionAuthority {
        let scopes = Set(originalScopes.map { $0.lowercased() })
        let fullRepositoryAuthority = scopes.contains("repo") || (repositoryIsPublic && scopes.contains("public_repo"))
        if fullRepositoryAuthority {
            switch permission {
            case .metadata: return .known(.read)
            case .contents, .pullRequests, .issues: return .known(.write)
            case .checks: return .known(.read)
            case .commitStatuses: return .known(.write)
            }
        }
        if permission == .commitStatuses, scopes.contains("repo:status") {
            return .known(.write)
        }
        if repositoryIsPublic {
            return .known(.read)
        }
        return .unknown
    }
}
