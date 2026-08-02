import Foundation

public enum ForgeRemoteParseError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case unsupportedScheme(String)
    case malformedURL
    case credentialsNotAllowed
    case missingHost
    case missingRepository
    case malformedPath
    case queryOrFragmentNotAllowed
    case unsafePathComponent

    public var errorDescription: String? {
        switch self {
        case .empty: "The Git remote URL is empty."
        case let .unsupportedScheme(scheme): "The Git remote scheme \(scheme) is unsupported."
        case .malformedURL: "The Git remote URL is malformed."
        case .credentialsNotAllowed: "HTTPS Git remote URLs cannot contain credentials."
        case .missingHost: "The Git remote URL has no host."
        case .missingRepository: "The Git remote URL has no repository path."
        case .malformedPath: "The Git remote repository path is malformed."
        case .queryOrFragmentNotAllowed: "The Git remote URL cannot contain a query or fragment."
        case .unsafePathComponent: "The Git remote URL contains an unsafe path component."
        }
    }
}

public struct ParsedForgeRemote: Codable, Equatable, Hashable, Sendable {
    public let original: String
    public let repository: ForgeRepositoryIdentity

    public init(original: String, repository: ForgeRepositoryIdentity) {
        self.original = original
        self.repository = repository
    }
}

public enum ForgeRemoteParser {
    public static func parse(_ remote: String) throws -> ParsedForgeRemote {
        let candidate = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw ForgeRemoteParseError.empty }

        let parsed: RemoteParts
        if candidate.contains("://") {
            parsed = try parseURL(candidate)
        } else {
            parsed = try parseSCP(candidate)
        }

        let origin: ForgeOrigin
        do {
            origin = try ForgeOrigin(host: parsed.host, port: parsed.httpsPort)
        } catch ForgeIdentityError.invalidPort {
            throw ForgeRemoteParseError.malformedURL
        } catch {
            throw ForgeRemoteParseError.missingHost
        }

        let pathComponents = try decodedPathComponents(parsed.percentEncodedPath)
        guard pathComponents.count >= 2 else { throw ForgeRemoteParseError.missingRepository }
        var repositoryName = pathComponents.last!
        if repositoryName.hasSuffix(".git") {
            repositoryName.removeLast(4)
        }
        guard !repositoryName.isEmpty else { throw ForgeRemoteParseError.missingRepository }
        let owner = pathComponents.dropLast().joined(separator: "/")
        let kind = ForgeKind.detect(host: origin.host)
        let repository: ForgeRepositoryIdentity
        do {
            repository = try ForgeRepositoryIdentity(
                forge: ForgeIdentity(kind: kind, origin: origin),
                owner: owner,
                name: repositoryName
            )
        } catch {
            throw ForgeRemoteParseError.unsafePathComponent
        }
        return ParsedForgeRemote(original: remote, repository: repository)
    }

    private static func parseURL(_ remote: String) throws -> RemoteParts {
        guard hasValidPercentEscapes(remote) else {
            throw ForgeRemoteParseError.unsafePathComponent
        }
        guard let components = URLComponents(string: remote),
              let scheme = components.scheme?.lowercased()
        else {
            throw ForgeRemoteParseError.malformedURL
        }
        guard ["https", "ssh", "git"].contains(scheme) else {
            throw ForgeRemoteParseError.unsupportedScheme(scheme)
        }
        guard components.query == nil, components.fragment == nil else {
            throw ForgeRemoteParseError.queryOrFragmentNotAllowed
        }
        if scheme == "https", components.user != nil || components.password != nil {
            throw ForgeRemoteParseError.credentialsNotAllowed
        }
        guard components.password == nil else {
            throw ForgeRemoteParseError.credentialsNotAllowed
        }
        guard let host = components.host, !host.isEmpty else {
            throw ForgeRemoteParseError.missingHost
        }
        return RemoteParts(
            host: host,
            httpsPort: scheme == "https" ? components.port : nil,
            percentEncodedPath: components.percentEncodedPath
        )
    }

    private static func parseSCP(_ remote: String) throws -> RemoteParts {
        guard !remote.hasPrefix("/"),
              !remote.hasPrefix("./"),
              !remote.hasPrefix("../"),
              let separator = remote.firstIndex(of: ":")
        else {
            throw ForgeRemoteParseError.malformedURL
        }
        let authority = String(remote[..<separator])
        let path = String(remote[remote.index(after: separator)...])
        guard !authority.isEmpty, !authority.contains("/"), !path.isEmpty else {
            throw ForgeRemoteParseError.malformedURL
        }
        let authorityParts = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard authorityParts.count <= 2,
              authorityParts.allSatisfy({ !$0.isEmpty }),
              let hostPart = authorityParts.last
        else {
            throw ForgeRemoteParseError.malformedURL
        }
        return RemoteParts(host: String(hostPart), httpsPort: nil, percentEncodedPath: "/" + path)
    }

    private static func decodedPathComponents(_ percentEncodedPath: String) throws -> [String] {
        let encoded = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first?.isEmpty == true else { throw ForgeRemoteParseError.malformedPath }
        let nonempty = Array(encoded.dropFirst())
        guard !nonempty.isEmpty, nonempty.allSatisfy({ !$0.isEmpty }) else {
            throw ForgeRemoteParseError.malformedPath
        }
        return try nonempty.map { raw in
            let value = String(raw)
            guard hasValidPercentEscapes(value),
                  let decoded = value.removingPercentEncoding,
                  ForgePathComponent.isSafe(decoded),
                  !decoded.contains("/")
            else {
                throw ForgeRemoteParseError.unsafePathComponent
            }
            return decoded.precomposedStringWithCanonicalMapping
        }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%" {
                guard index + 2 < scalars.count,
                      scalars[index + 1].isASCIIHexDigit,
                      scalars[index + 2].isASCIIHexDigit
                else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }
}

private struct RemoteParts {
    let host: String
    let httpsPort: Int?
    let percentEncodedPath: String
}

extension Unicode.Scalar {
    var isASCIIHexDigit: Bool {
        switch value {
        case 48 ... 57, 65 ... 70, 97 ... 102: true
        default: false
        }
    }
}
