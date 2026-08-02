import Foundation

public enum ForgeDestinationURLCodecError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case originMismatch
    case repositoryMismatch
    case unsupportedDestination
    case malformedDestination
    case malformedFragment

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The Forge destination URL is invalid."
        case .originMismatch: "The Forge destination has a different origin."
        case .repositoryMismatch: "The Forge destination belongs to another repository."
        case .unsupportedDestination: "The Forge destination is unsupported."
        case .malformedDestination: "The Forge destination path is malformed."
        case .malformedFragment: "The Forge destination line fragment is malformed."
        }
    }
}

public enum ForgeDestinationURLCodec {
    public static func url(for destination: ForgeDestination) throws -> URL {
        let repository = destination.repository
        var path = repository.ownerPathComponents + [repository.name]
        var fragment: String?

        switch (repository.forge.kind, destination) {
        case (_, .repository):
            break
        case let (.github, .branch(_, reference)):
            path += ["tree", reference.value]
        case let (.gitLab, .branch(_, reference)):
            path += ["-", "tree", reference.value]
        case let (.bitbucket, .branch(_, reference)):
            path += ["src", reference.value]
        case let (.github, .commit(_, identifier)):
            path += ["commit", identifier.value]
        case let (.gitLab, .commit(_, identifier)):
            path += ["-", "commit", identifier.value]
        case let (.bitbucket, .commit(_, identifier)):
            path += ["commits", identifier.value]
        case let (.github, .file(_, revision, file, selection)):
            path += ["blob", revision.value] + file.components
            fragment = selection.map(gitHubOrGitLabFragment)
        case let (.gitLab, .file(_, revision, file, selection)):
            path += ["-", "blob", revision.value] + file.components
            fragment = selection.map(gitHubOrGitLabFragment)
        case let (.bitbucket, .file(_, revision, file, selection)):
            path += ["src", revision.value] + file.components
            fragment = selection.map(bitbucketFragment)
        case let (.github, .compare(_, base, head)):
            path += ["compare", "\(base.value)...\(head.value)"]
        case let (.gitLab, .compare(_, base, head)):
            path += ["-", "compare", "\(base.value)...\(head.value)"]
        case let (.bitbucket, .compare(_, base, head)):
            // Bitbucket's web comparison spells the source before the destination.
            path += ["branches", "compare", "\(head.value)..\(base.value)"]
        case let (.github, .pullRequest(_, number)):
            path += ["pull", String(number.rawValue)]
        case let (.gitLab, .pullRequest(_, number)):
            path += ["-", "merge_requests", String(number.rawValue)]
        case let (.bitbucket, .pullRequest(_, number)):
            path += ["pull-requests", String(number.rawValue)]
        case let (.github, .issue(_, number)):
            path += ["issues", String(number.rawValue)]
        case let (.gitLab, .issue(_, number)):
            path += ["-", "issues", String(number.rawValue)]
        case let (.bitbucket, .issue(_, number)):
            path += ["issues", String(number.rawValue)]
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = repository.forge.origin.host
        components.port = repository.forge.origin.port
        components.percentEncodedPath = "/" + path.map(percentEncodedComponent).joined(separator: "/")
        components.fragment = fragment
        guard let url = components.url else { throw ForgeDestinationURLCodecError.invalidURL }
        return url
    }

    public static func parse(
        _ url: URL,
        boundTo repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              let host = components.host
        else {
            throw ForgeDestinationURLCodecError.invalidURL
        }
        let destinationOrigin: ForgeOrigin
        do {
            destinationOrigin = try ForgeOrigin(host: host, port: components.port)
        } catch {
            throw ForgeDestinationURLCodecError.invalidURL
        }
        guard destinationOrigin.isSameOrigin(as: repository.forge.origin) else {
            throw ForgeDestinationURLCodecError.originMismatch
        }

        let decoded = try decodedComponents(components.percentEncodedPath)
        let repositoryPrefix = repository.ownerPathComponents + [repository.name]
        guard decoded.starts(with: repositoryPrefix) else {
            throw ForgeDestinationURLCodecError.repositoryMismatch
        }
        let relative = Array(decoded.dropFirst(repositoryPrefix.count))
        if relative.isEmpty {
            guard components.fragment == nil else {
                throw ForgeDestinationURLCodecError.malformedFragment
            }
            return .repository(repository)
        }

        switch repository.forge.kind {
        case .github:
            return try parseGitHub(relative, fragment: components.fragment, repository: repository)
        case .gitLab:
            return try parseGitLab(relative, fragment: components.fragment, repository: repository)
        case .bitbucket:
            return try parseBitbucket(relative, fragment: components.fragment, repository: repository)
        }
    }

    private static func parseGitHub(
        _ path: [String],
        fragment: String?,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        if path.count >= 3, path[0] == "blob" {
            return try fileDestination(
                repository: repository,
                revision: path[1],
                fileComponents: Array(path.dropFirst(2)),
                selection: parseGitHubOrGitLabFragment(fragment)
            )
        }
        guard fragment == nil else { throw ForgeDestinationURLCodecError.malformedFragment }
        if path.count == 2, path[0] == "tree" {
            return try .branch(repository, ForgeRefName(path[1]))
        }
        if path.count == 2, path[0] == "commit" {
            return try .commit(repository, ForgeCommitID(path[1]))
        }
        if path.count == 2, path[0] == "compare" {
            return try parseComparison(path[1], separator: "...", repository: repository)
        }
        if path.count == 2, path[0] == "pull" {
            return try .pullRequest(repository, itemNumber(path[1]))
        }
        if path.count == 2, path[0] == "issues" {
            return try .issue(repository, itemNumber(path[1]))
        }
        throw ForgeDestinationURLCodecError.unsupportedDestination
    }

    private static func parseGitLab(
        _ path: [String],
        fragment: String?,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        if path.count >= 4, path[0] == "-", path[1] == "blob" {
            return try fileDestination(
                repository: repository,
                revision: path[2],
                fileComponents: Array(path.dropFirst(3)),
                selection: parseGitHubOrGitLabFragment(fragment)
            )
        }
        guard fragment == nil else { throw ForgeDestinationURLCodecError.malformedFragment }
        if path.count == 3, path[0] == "-", path[1] == "tree" {
            return try .branch(repository, ForgeRefName(path[2]))
        }
        if path.count == 3, path[0] == "-", path[1] == "commit" {
            return try .commit(repository, ForgeCommitID(path[2]))
        }
        if path.count == 3, path[0] == "-", path[1] == "compare" {
            return try parseComparison(path[2], separator: "...", repository: repository)
        }
        if path.count == 3, path[0] == "-", path[1] == "merge_requests" {
            return try .pullRequest(repository, itemNumber(path[2]))
        }
        if path.count == 3, path[0] == "-", path[1] == "issues" {
            return try .issue(repository, itemNumber(path[2]))
        }
        throw ForgeDestinationURLCodecError.unsupportedDestination
    }

    private static func parseBitbucket(
        _ path: [String],
        fragment: String?,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        if path.count >= 3, path[0] == "src" {
            return try fileDestination(
                repository: repository,
                revision: path[1],
                fileComponents: Array(path.dropFirst(2)),
                selection: parseBitbucketFragment(fragment)
            )
        }
        guard fragment == nil else { throw ForgeDestinationURLCodecError.malformedFragment }
        if path.count == 2, path[0] == "src" {
            return try .branch(repository, ForgeRefName(path[1]))
        }
        if path.count == 2, path[0] == "commits" {
            return try .commit(repository, ForgeCommitID(path[1]))
        }
        if path.count == 3, path[0] == "branches", path[1] == "compare" {
            return try parseBitbucketComparison(path[2], repository: repository)
        }
        if path.count == 2, path[0] == "pull-requests" {
            return try .pullRequest(repository, itemNumber(path[1]))
        }
        if path.count == 2, path[0] == "issues" {
            return try .issue(repository, itemNumber(path[1]))
        }
        throw ForgeDestinationURLCodecError.unsupportedDestination
    }

    private static func fileDestination(
        repository: ForgeRepositoryIdentity,
        revision: String,
        fileComponents: [String],
        selection: ForgeLineSelection?
    ) throws -> ForgeDestination {
        guard fileComponents.allSatisfy({ !$0.contains("/") && !$0.contains("\\") }) else {
            throw ForgeDestinationURLCodecError.malformedDestination
        }
        return try .file(
            repository,
            revision: parsedRevision(revision),
            path: ForgeFilePath(fileComponents.joined(separator: "/")),
            selection: selection
        )
    }

    private static func parseComparison(
        _ comparison: String,
        separator: String,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        let values = comparison.components(separatedBy: separator)
        guard values.count == 2 else { throw ForgeDestinationURLCodecError.malformedDestination }
        return try .compare(
            repository,
            base: parsedRevision(values[0]),
            head: parsedRevision(values[1])
        )
    }

    private static func parseBitbucketComparison(
        _ comparison: String,
        repository: ForgeRepositoryIdentity
    ) throws -> ForgeDestination {
        let values = comparison.components(separatedBy: "..")
        guard values.count == 2 else { throw ForgeDestinationURLCodecError.malformedDestination }
        return try .compare(
            repository,
            base: parsedRevision(values[1]),
            head: parsedRevision(values[0])
        )
    }

    /// File and compare URLs encode only revision text, so parsing cannot
    /// truthfully distinguish a branch, tag, or hex-named ref from a commit.
    private static func parsedRevision(_ value: String) throws -> ForgeRevision {
        try .opaque(ForgeRefName(value))
    }

    private static func itemNumber(_ value: String) throws -> ForgeItemNumber {
        guard let integer = Int(value), let number = try? ForgeItemNumber(integer) else {
            throw ForgeDestinationURLCodecError.malformedDestination
        }
        return number
    }

    private static func gitHubOrGitLabFragment(_ selection: ForgeLineSelection) -> String {
        selection.isSingleLine ? "L\(selection.start)" : "L\(selection.start)-L\(selection.end)"
    }

    private static func bitbucketFragment(_ selection: ForgeLineSelection) -> String {
        selection.isSingleLine ? "lines-\(selection.start)" : "lines-\(selection.start):\(selection.end)"
    }

    private static func parseGitHubOrGitLabFragment(_ fragment: String?) throws -> ForgeLineSelection? {
        guard let fragment else { return nil }
        guard fragment.hasPrefix("L") else { throw ForgeDestinationURLCodecError.malformedFragment }
        let values = fragment.dropFirst().components(separatedBy: "-L")
        return try selection(values)
    }

    private static func parseBitbucketFragment(_ fragment: String?) throws -> ForgeLineSelection? {
        guard let fragment else { return nil }
        guard fragment.hasPrefix("lines-") else { throw ForgeDestinationURLCodecError.malformedFragment }
        let values = fragment.dropFirst("lines-".count).components(separatedBy: ":")
        return try selection(values)
    }

    private static func selection(_ values: [String]) throws -> ForgeLineSelection {
        guard (1 ... 2).contains(values.count), let start = Int(values[0]) else {
            throw ForgeDestinationURLCodecError.malformedFragment
        }
        do {
            if values.count == 1 {
                return try ForgeLineSelection(line: start)
            }
            guard let end = Int(values[1]) else {
                throw ForgeDestinationURLCodecError.malformedFragment
            }
            return try ForgeLineSelection(start: start, end: end)
        } catch is ForgeDestinationValidationError {
            throw ForgeDestinationURLCodecError.malformedFragment
        }
    }

    private static func decodedComponents(_ percentEncodedPath: String) throws -> [String] {
        guard percentEncodedPath.hasPrefix("/") else {
            throw ForgeDestinationURLCodecError.malformedDestination
        }
        let raw = percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !raw.isEmpty, raw.allSatisfy({ !$0.isEmpty }) else {
            throw ForgeDestinationURLCodecError.malformedDestination
        }
        return try raw.map { component in
            guard let decoded = String(component).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw ForgeDestinationURLCodecError.malformedDestination
            }
            return decoded.precomposedStringWithCanonicalMapping
        }
    }

    private static func percentEncodedComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .forgeURLComponentAllowed) ?? ""
    }
}

private extension CharacterSet {
    static let forgeURLComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
