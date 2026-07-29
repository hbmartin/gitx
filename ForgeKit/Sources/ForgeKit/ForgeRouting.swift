import Foundation

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

public enum ForgeNumberedDestinationKind: String, CaseIterable, Codable, Hashable, Sendable {
    case pullRequest
    case issue
}

public struct ForgeDestinationChoice: Codable, Equatable, Hashable, Sendable {
    public let destination: ForgeDestination
    public let title: String

    public init(destination: ForgeDestination, title: String) {
        self.destination = destination
        self.title = title
    }
}

public enum ForgeRoutingError: Error, Equatable, LocalizedError, Sendable {
    case malformedNumberReference
    case bindingRequired
    case noAvailableDestination

    public var errorDescription: String? {
        switch self {
        case .malformedNumberReference: "The Pull Request or Issue reference is malformed."
        case .bindingRequired: "Choose a Primary Forge Repository before opening this reference."
        case .noAvailableDestination: "No Pull Request or Issue destination is available."
        }
    }
}

public enum ForgeNumberRoute: Equatable, Sendable {
    case destination(ForgeDestination)
    case requiresChoice([ForgeDestinationChoice])
    case failure(ForgeRoutingError)
}

public struct ForgeDestinationRoute: Equatable, Sendable {
    public let destination: ForgeDestination
    public let browserURL: URL

    public init(destination: ForgeDestination, browserURL: URL) {
        self.destination = destination
        self.browserURL = browserURL
    }
}

public struct ForgeDestinationRouter: Sendable {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeDestinationRouter")

    public init() {}

    public func route(_ destination: ForgeDestination) throws -> ForgeDestinationRoute {
        let url = try ForgeDestinationURLCodec.url(for: destination)
        logger.debug(
            "Resolved destination kind=\(destination.kind.rawValue, privacy: .public) forge=\(destination.repository.forge.kind.rawValue, privacy: .public)"
        )
        return ForgeDestinationRoute(destination: destination, browserURL: url)
    }

    /// `#123` is resolved directly only when both the repository binding and
    /// item family are unambiguous. Every other resolvable case returns choices.
    public func routeNumberReference(
        _ reference: String,
        boundRepository: ForgeRepositoryIdentity?,
        candidateRepositories: [ForgeRepositoryIdentity] = [],
        availableKinds: Set<ForgeNumberedDestinationKind> = Set(ForgeNumberedDestinationKind.allCases)
    ) -> ForgeNumberRoute {
        guard let number = parseNumberReference(reference) else {
            logger.debug("Rejected malformed numbered Forge reference")
            return .failure(.malformedNumberReference)
        }
        guard !availableKinds.isEmpty else {
            logger.debug("No numbered Forge destination capability is available")
            return .failure(.noAvailableDestination)
        }

        if let boundRepository {
            let destinations = choices(
                repositories: [boundRepository],
                number: number,
                kinds: availableKinds
            )
            if destinations.count == 1 {
                logger.debug("Resolved numbered Forge reference in bound context")
                return .destination(destinations[0].destination)
            }
            logger.debug("Numbered Forge reference needs a Pull Request or Issue choice")
            return .requiresChoice(destinations)
        }

        let repositories = uniqueSortedRepositories(candidateRepositories)
        guard !repositories.isEmpty else {
            logger.debug("Numbered Forge reference needs a repository binding")
            return .failure(.bindingRequired)
        }
        logger.debug("Numbered Forge reference needs a repository or item choice")
        return .requiresChoice(choices(repositories: repositories, number: number, kinds: availableKinds))
    }

    private func parseNumberReference(_ reference: String) -> ForgeItemNumber? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#", trimmed.dropFirst().allSatisfy(\.isNumber),
              let value = Int(trimmed.dropFirst())
        else {
            return nil
        }
        return try? ForgeItemNumber(value)
    }

    private func choices(
        repositories: [ForgeRepositoryIdentity],
        number: ForgeItemNumber,
        kinds: Set<ForgeNumberedDestinationKind>
    ) -> [ForgeDestinationChoice] {
        repositories.flatMap { repository in
            ForgeNumberedDestinationKind.allCases.compactMap { kind in
                guard kinds.contains(kind) else { return nil }
                let destination: ForgeDestination
                let family: String
                switch kind {
                case .pullRequest:
                    destination = .pullRequest(repository, number)
                    family = "Pull Request"
                case .issue:
                    destination = .issue(repository, number)
                    family = "Issue"
                }
                return ForgeDestinationChoice(
                    destination: destination,
                    title: "\(repository.owner)/\(repository.name) — \(family) #\(number.rawValue)"
                )
            }
        }
    }

    private func uniqueSortedRepositories(
        _ repositories: [ForgeRepositoryIdentity]
    ) -> [ForgeRepositoryIdentity] {
        var seen: Set<String> = []
        return repositories
            .sorted { $0.canonicalKey < $1.canonicalKey }
            .filter { seen.insert($0.canonicalKey).inserted }
    }
}
