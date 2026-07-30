import Foundation

public enum ForgeDeepLinkError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme
    case credentialsNotAllowed
    case malformedAuthority
    case queryOrFragmentNotAllowed
    case unknownRepository
    case ambiguousRepository
    case unsupportedRoute
    case malformedRoute

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The GitX deep link is invalid."
        case .unsupportedScheme: "Only the x-gitx deep-link scheme is supported."
        case .credentialsNotAllowed: "GitX deep links cannot contain credentials."
        case .malformedAuthority: "The GitX deep-link authority is malformed."
        case .queryOrFragmentNotAllowed: "GitX deep links cannot contain a query or fragment."
        case .unknownRepository: "The GitX deep link does not match a known Forge Repository."
        case .ambiguousRepository: "The GitX deep link matches more than one Forge Repository."
        case .unsupportedRoute: "The GitX deep-link route is unsupported."
        case .malformedRoute: "The GitX deep-link route is malformed."
        }
    }
}

public enum ForgeDeepLinkCodec {
    public static func url(for destination: ForgeDestination) throws -> URL {
        let repository = destination.repository
        var path = repository.ownerPathComponents + [repository.name]
        switch destination {
        case .repository:
            path += ["repository"]
        case let .branch(_, branch):
            path += ["branch", branch.value]
        case let .commit(_, commit):
            path += ["commit", commit.value]
        case let .file(_, revision, file, selection):
            path += ["file", revision.value]
            if let selection {
                path += ["lines", String(selection.start), String(selection.end)]
            } else {
                path += ["lines", "0", "0"]
            }
            path += file.components
        case let .compare(_, base, head):
            path += ["compare", base.value, head.value]
        case let .pullRequest(_, number):
            path += ["pull-request", String(number.rawValue)]
        case let .issue(_, number):
            path += ["issue", String(number.rawValue)]
        }

        var components = URLComponents()
        components.scheme = "x-gitx"
        components.host = repository.forge.origin.host
        components.port = repository.forge.origin.port
        components.percentEncodedPath = "/" + path.map(percentEncodedComponent).joined(separator: "/")
        guard let url = components.url else { throw ForgeDeepLinkError.invalidURL }
        return url
    }

    public static func parse(
        _ url: URL,
        knownRepositories: [ForgeRepositoryIdentity]
    ) throws -> ForgeDestination {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ForgeDeepLinkError.invalidURL
        }
        guard components.scheme?.lowercased() == "x-gitx" else {
            throw ForgeDeepLinkError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw ForgeDeepLinkError.credentialsNotAllowed
        }
        guard let host = components.host, !host.isEmpty else {
            throw ForgeDeepLinkError.malformedAuthority
        }
        guard components.query == nil, components.fragment == nil else {
            throw ForgeDeepLinkError.queryOrFragmentNotAllowed
        }
        let authority: ForgeOrigin
        do {
            authority = try ForgeOrigin(host: host, port: components.port)
        } catch {
            throw ForgeDeepLinkError.malformedAuthority
        }
        let path = try decodedComponents(components.percentEncodedPath)
        let matches = knownRepositories.filter { repository in
            authority.isSameOrigin(as: repository.forge.origin)
                && path.starts(with: repository.ownerPathComponents + [repository.name])
        }
        guard !matches.isEmpty else { throw ForgeDeepLinkError.unknownRepository }
        let exactMatches = matches.filter { repository in
            path.count > repository.ownerPathComponents.count + 1
        }
        guard exactMatches.count == 1, let repository = exactMatches.first else {
            throw ForgeDeepLinkError.ambiguousRepository
        }
        let prefixCount = repository.ownerPathComponents.count + 1
        return try destination(repository: repository, route: Array(path.dropFirst(prefixCount)))
    }

    private static func destination(
        repository: ForgeRepositoryIdentity,
        route: [String]
    ) throws -> ForgeDestination {
        guard let family = route.first else { throw ForgeDeepLinkError.malformedRoute }
        switch family {
        case "repository":
            guard route.count == 1 else { throw ForgeDeepLinkError.malformedRoute }
            return .repository(repository)
        case "branch":
            guard route.count == 2 else { throw ForgeDeepLinkError.malformedRoute }
            return try mapped { try .branch(repository, ForgeRefName(route[1])) }
        case "commit":
            guard route.count == 2 else { throw ForgeDeepLinkError.malformedRoute }
            return try mapped { try .commit(repository, ForgeCommitID(route[1])) }
        case "file":
            guard route.count >= 6, route[2] == "lines" else {
                throw ForgeDeepLinkError.malformedRoute
            }
            let selection = try lineSelection(start: route[3], end: route[4])
            let filePath = Array(route.dropFirst(5)).joined(separator: "/")
            return try mapped {
                try .file(
                    repository,
                    revision: .opaque(ForgeRefName(route[1])),
                    path: ForgeFilePath(filePath),
                    selection: selection
                )
            }
        case "compare":
            guard route.count == 3 else { throw ForgeDeepLinkError.malformedRoute }
            return try mapped {
                try .compare(
                    repository,
                    base: .opaque(ForgeRefName(route[1])),
                    head: .opaque(ForgeRefName(route[2]))
                )
            }
        case "pull-request":
            guard route.count == 2 else { throw ForgeDeepLinkError.malformedRoute }
            return try mapped { try .pullRequest(repository, itemNumber(route[1])) }
        case "issue":
            guard route.count == 2 else { throw ForgeDeepLinkError.malformedRoute }
            return try mapped { try .issue(repository, itemNumber(route[1])) }
        case "auth", "oauth", "callback", "mutate", "mutation":
            throw ForgeDeepLinkError.unsupportedRoute
        default:
            throw ForgeDeepLinkError.unsupportedRoute
        }
    }

    private static func lineSelection(start: String, end: String) throws -> ForgeLineSelection? {
        guard let startValue = Int(start), let endValue = Int(end) else {
            throw ForgeDeepLinkError.malformedRoute
        }
        if startValue == 0, endValue == 0 {
            return nil
        }
        return try mapped { try ForgeLineSelection(start: startValue, end: endValue) }
    }

    private static func itemNumber(_ value: String) throws -> ForgeItemNumber {
        guard let integer = Int(value) else { throw ForgeDeepLinkError.malformedRoute }
        return try mapped { try ForgeItemNumber(integer) }
    }

    private static func mapped<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch is ForgeDestinationValidationError {
            throw ForgeDeepLinkError.malformedRoute
        }
    }

    private static func decodedComponents(_ percentEncodedPath: String) throws -> [String] {
        guard percentEncodedPath.hasPrefix("/") else { throw ForgeDeepLinkError.malformedRoute }
        let raw = percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !raw.isEmpty, raw.allSatisfy({ !$0.isEmpty }) else {
            throw ForgeDeepLinkError.malformedRoute
        }
        return try raw.map { value in
            guard let decoded = String(value).removingPercentEncoding,
                  ForgePathComponent.isNonemptyPrintable(decoded),
                  decoded != ".",
                  decoded != ".."
            else {
                throw ForgeDeepLinkError.malformedRoute
            }
            return decoded.precomposedStringWithCanonicalMapping
        }
    }

    private static func percentEncodedComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: deepLinkComponentCharacters) ?? ""
    }

    private static let deepLinkComponentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

public struct ForgeOpenCheckout: Codable, Hashable, Sendable {
    public let identifier: String
    public let repository: ForgeRepositoryIdentity
    public let frontmostRank: Int
    public let availableCommits: Set<ForgeCommitID>

    public init(
        identifier: String,
        repository: ForgeRepositoryIdentity,
        frontmostRank: Int,
        availableCommits: Set<ForgeCommitID> = []
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(identifier), frontmostRank >= 0 else {
            throw ForgeDeepLinkError.malformedRoute
        }
        self.identifier = identifier
        self.repository = repository
        self.frontmostRank = frontmostRank
        self.availableCommits = availableCommits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(String.self, forKey: .identifier),
            repository: container.decode(ForgeRepositoryIdentity.self, forKey: .repository),
            frontmostRank: container.decode(Int.self, forKey: .frontmostRank),
            availableCommits: container.decode(Set<ForgeCommitID>.self, forKey: .availableCommits)
        )
    }
}

public enum ForgeDeepLinkMissingObjectAction: String, CaseIterable, Codable, Hashable, Sendable {
    case fetch
    case openInBrowser
}

public enum ForgeDeepLinkRouteDecision: Hashable, Sendable {
    case open(checkoutIdentifier: String, destination: ForgeDestination)
    case chooseCheckout(checkoutIdentifiers: [String], destination: ForgeDestination)
    case missingLocalObject(
        checkoutIdentifier: String,
        destination: ForgeDestination,
        actions: [ForgeDeepLinkMissingObjectAction]
    )
    case noMatchingCheckout(destination: ForgeDestination)
}

public enum ForgeDeepLinkRouter {
    public static func route(
        _ destination: ForgeDestination,
        openCheckouts: [ForgeOpenCheckout]
    ) -> ForgeDeepLinkRouteDecision {
        let matches = openCheckouts
            .filter { $0.repository == destination.repository }
            .sorted {
                if $0.frontmostRank != $1.frontmostRank {
                    return $0.frontmostRank < $1.frontmostRank
                }
                return $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
            }
        guard let frontmost = matches.first else {
            return .noMatchingCheckout(destination: destination)
        }
        guard matches.count == 1 else {
            return .chooseCheckout(
                checkoutIdentifiers: matches.map(\.identifier),
                destination: destination
            )
        }
        if let commit = localCommitRequired(by: destination), !frontmost.availableCommits.contains(commit) {
            return .missingLocalObject(
                checkoutIdentifier: frontmost.identifier,
                destination: destination,
                actions: ForgeDeepLinkMissingObjectAction.allCases
            )
        }
        return .open(checkoutIdentifier: frontmost.identifier, destination: destination)
    }

    private static func localCommitRequired(by destination: ForgeDestination) -> ForgeCommitID? {
        switch destination {
        case let .commit(_, commit): commit
        case let .file(_, .commit(commit), _, _): commit
        case .repository, .branch, .file, .compare, .pullRequest, .issue: nil
        }
    }
}
