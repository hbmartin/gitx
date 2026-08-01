import Apollo
import ForgeKit
import Foundation

public enum GitHubReadCompleteness: String, CaseIterable, Codable, Hashable, Sendable {
    case complete
    case partial
}

extension GraphQLError {
    var gitXProblem: GitHubGraphQLProblem {
        let safePath: [String] = path?.map {
            switch $0 {
            case let .field(field): field
            case let .index(index): String(index)
            }
        } ?? []
        let reportedClassification = (extensions?["type"] as? String)
            ?? (extensions?["code"] as? String)
        let safeClassifications: Set = [
            "FORBIDDEN", "NOT_FOUND", "PARTIAL", "RATE_LIMITED", "UNAUTHORIZED",
        ]
        return GitHubGraphQLProblem(
            message: "GitHub could not complete part of this request.",
            path: safePath,
            classification: reportedClassification.flatMap {
                safeClassifications.contains($0) ? $0 : nil
            }
        )
    }
}

public struct GitHubGraphQLProblem: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let message: String
    public let path: [String]
    public let classification: String?

    public init(message: String, path: [String] = [], classification: String? = nil) {
        self.message = message
        self.path = path
        self.classification = classification
    }

    public var description: String {
        "GitHub GraphQL problem (server message redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubSAMLMetadata: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let authorizationURL: URL?

    public init(authorizationURL: URL?) {
        self.authorizationURL = authorizationURL
    }

    public var description: String {
        "GitHub SAML authorization metadata (URL redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubInstallationMetadata: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let configurationURL: URL?

    public init(configurationURL: URL?) {
        self.configurationURL = configurationURL
    }

    public var description: String {
        "GitHub App installation metadata (URL redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubResponseMetadata: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let statusCode: Int
    public let requestID: String?
    public let rateLimit: GitHubRateLimitMetadata
    public let saml: GitHubSAMLMetadata?
    public let installation: GitHubInstallationMetadata?

    public init(
        statusCode: Int,
        requestID: String? = nil,
        rateLimit: GitHubRateLimitMetadata,
        saml: GitHubSAMLMetadata? = nil,
        installation: GitHubInstallationMetadata? = nil
    ) {
        self.statusCode = statusCode
        self.requestID = requestID
        self.rateLimit = rateLimit
        self.saml = saml
        self.installation = installation
    }

    public var description: String {
        "GitHub response metadata (sensitive values redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

public struct GitHubReadResult<Value: Sendable>: Sendable {
    public let value: Value
    public let completeness: GitHubReadCompleteness
    public let problems: [GitHubGraphQLProblem]
    public let response: GitHubResponseMetadata
    public let ownership: GitHubReadOwnership
    public let accessEvidence: ForgeRepositoryAccessEvidence?

    public init(
        value: Value,
        completeness: GitHubReadCompleteness,
        problems: [GitHubGraphQLProblem],
        response: GitHubResponseMetadata,
        ownership: GitHubReadOwnership,
        accessEvidence: ForgeRepositoryAccessEvidence? = nil
    ) {
        self.value = value
        self.completeness = completeness
        self.problems = problems
        self.response = response
        self.ownership = ownership
        self.accessEvidence = accessEvidence
    }
}

public struct GitHubReadOwnership: Hashable, Sendable {
    public let credential: ForgeCredentialReference
    public let repository: ForgeRepositoryIdentity
    public let cachePartition: ForgeCachePartition

    public init(credential: ForgeCredentialReference, repository: ForgeRepositoryIdentity) throws {
        guard credential.accountID.forge == repository.forge else {
            throw GitHubReadError.githubDotComRequired
        }
        self.credential = credential
        self.repository = repository
        cachePartition = .account(credential.accountID)
    }
}

public enum GitHubReadMappingFailure: String, CaseIterable, Equatable, Sendable {
    case repositoryNotFound
    case objectNotFound
    case malformedResponse
}

public enum GitHubReadError: Error, Equatable, LocalizedError, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case githubDotComRequired
    case invalidPageSize
    case invalidSearchQuery
    case repositoryNotFound
    case objectNotFound
    case authenticationRequired
    case permissionDenied(GitHubResponseMetadata)
    case rateLimited(GitHubResponseMetadata)
    case samlAuthorizationRequired(GitHubResponseMetadata)
    case installationConfigurationRequired(GitHubResponseMetadata)
    case graphQL([GitHubGraphQLProblem], GitHubResponseMetadata)
    case mapping(GitHubReadMappingFailure, [GitHubGraphQLProblem], GitHubResponseMetadata)
    case malformedResponse
    case transportFailure

    public var errorDescription: String? {
        switch self {
        case .githubDotComRequired: "Native reads require an exact GitHub.com Forge Repository."
        case .invalidPageSize: "The GitHub page size must be between 1 and 100."
        case .invalidSearchQuery: "The GitHub search query is invalid."
        case .repositoryNotFound: "The GitHub repository was not found or is unavailable."
        case .objectNotFound: "The GitHub object was not found or is unavailable."
        case .authenticationRequired: "GitHub authentication is required."
        case .permissionDenied: "The Credential does not have access to this GitHub resource."
        case .rateLimited: "GitHub rate limited this Credential."
        case .samlAuthorizationRequired: "Organization SAML authorization is required."
        case .installationConfigurationRequired:
            "GitHub App repository access configuration is required."
        case .graphQL: "GitHub returned an error for this read."
        case .mapping: "GitHub returned data that could not be mapped safely."
        case .malformedResponse: "GitHub returned a malformed response."
        case .transportFailure: "The GitHub request could not be completed."
        }
    }

    public var description: String {
        errorDescription ?? "GitHub read failed."
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
