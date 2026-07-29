import Foundation

public enum ForgeKind: String, CaseIterable, Codable, Hashable, Sendable {
    case github
    case gitLab
    case bitbucket

    /// Preserves GitX's GitHub-default host heuristic without allowing a
    /// detected family to replace or weaken the exact-origin identity.
    public static func detect(host: String) -> ForgeKind {
        let normalizedHost = host.lowercased()
        if normalizedHost.contains("gitlab") {
            return .gitLab
        }
        if normalizedHost.contains("bitbucket") {
            return .bitbucket
        }
        return .github
    }
}

public enum ForgeIdentityError: Error, Equatable, LocalizedError, Sendable {
    case httpsRequired
    case credentialsNotAllowed
    case invalidHost
    case invalidPort
    case originContainsPath
    case originContainsQueryOrFragment
    case invalidOwner
    case invalidRepositoryName
    case mismatchedForge
    case invalidAccountIdentifier

    public var errorDescription: String? {
        switch self {
        case .httpsRequired: "A Forge origin must use HTTPS."
        case .credentialsNotAllowed: "A Forge origin cannot contain credentials."
        case .invalidHost: "The Forge host is invalid."
        case .invalidPort: "The Forge port is invalid."
        case .originContainsPath: "A Forge origin cannot contain a path."
        case .originContainsQueryOrFragment: "A Forge origin cannot contain a query or fragment."
        case .invalidOwner: "The Forge repository owner is invalid."
        case .invalidRepositoryName: "The Forge repository name is invalid."
        case .mismatchedForge: "The account and repository belong to different Forges."
        case .invalidAccountIdentifier: "The Forge Account identifier is invalid."
        }
    }
}

public struct ForgeOrigin: Hashable, Sendable {
    public let host: String
    public let port: Int?
    private let validatedURL: URL

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https"
        else {
            throw ForgeIdentityError.httpsRequired
        }
        guard components.user == nil, components.password == nil else {
            throw ForgeIdentityError.credentialsNotAllowed
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw ForgeIdentityError.originContainsPath
        }
        guard components.query == nil, components.fragment == nil else {
            throw ForgeIdentityError.originContainsQueryOrFragment
        }
        let validated = try Self.validate(host: components.host, port: components.port)
        host = validated.host
        port = validated.port
        validatedURL = validated.url
    }

    public init(host: String, port: Int? = nil) throws {
        let validated = try Self.validate(host: host, port: port)
        self.host = validated.host
        self.port = validated.port
        validatedURL = validated.url
    }

    public var effectivePort: Int {
        port ?? 443
    }

    public var url: URL {
        validatedURL
    }

    public func isSameOrigin(as other: ForgeOrigin) -> Bool {
        host == other.host && effectivePort == other.effectivePort
    }

    private static func validate(host input: String?, port: Int?) throws -> (host: String, port: Int?, url: URL) {
        guard let input, !input.isEmpty,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeIdentityError.invalidHost
        }
        if let port, !(1 ... 65535).contains(port) {
            throw ForgeIdentityError.invalidPort
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = input
        components.port = port
        guard let url = components.url,
              let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
              !parsed.isEmpty
        else {
            throw ForgeIdentityError.invalidHost
        }

        guard !parsed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeIdentityError.invalidHost
        }
        let lowered = parsed.lowercased()
        let normalized = lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
        guard !normalized.isEmpty,
              !normalized.hasPrefix("."),
              !normalized.hasSuffix("."),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains("@"),
              !normalized.contains("..")
        else {
            throw ForgeIdentityError.invalidHost
        }
        let normalizedPort = port == 443 ? nil : port
        var normalizedComponents = URLComponents()
        normalizedComponents.scheme = "https"
        normalizedComponents.host = normalized
        normalizedComponents.port = normalizedPort
        guard let normalizedURL = normalizedComponents.url else {
            throw ForgeIdentityError.invalidHost
        }
        return (normalized, normalizedPort, normalizedURL)
    }
}

extension ForgeOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case host
        case port
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            host: container.decode(String.self, forKey: .host),
            port: container.decodeIfPresent(Int.self, forKey: .port)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(port, forKey: .port)
    }
}

public struct ForgeIdentity: Codable, Hashable, Sendable {
    public let kind: ForgeKind
    public let origin: ForgeOrigin

    public init(kind: ForgeKind, origin: ForgeOrigin) {
        self.kind = kind
        self.origin = origin
    }
}

public struct ForgeRepositoryIdentity: Hashable, Sendable {
    public let forge: ForgeIdentity
    public let owner: String
    public let name: String

    public init(forge: ForgeIdentity, owner: String, name: String) throws {
        let ownerComponents = owner.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !ownerComponents.isEmpty,
              ownerComponents.allSatisfy(ForgePathComponent.isSafe)
        else {
            throw ForgeIdentityError.invalidOwner
        }
        guard ForgePathComponent.isSafe(name) else {
            throw ForgeIdentityError.invalidRepositoryName
        }
        self.forge = forge
        self.owner = ownerComponents
            .map { $0.precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
        self.name = name.precomposedStringWithCanonicalMapping
    }

    public var ownerPathComponents: [String] {
        owner.split(separator: "/").map(String.init)
    }

    public var canonicalKey: String {
        "\(forge.kind.rawValue)|\(forge.origin.url.absoluteString)|\(owner)/\(name)"
    }
}

extension ForgeRepositoryIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case forge
        case owner
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            forge: container.decode(ForgeIdentity.self, forKey: .forge),
            owner: container.decode(String.self, forKey: .owner),
            name: container.decode(String.self, forKey: .name)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(forge, forKey: .forge)
        try container.encode(owner, forKey: .owner)
        try container.encode(name, forKey: .name)
    }
}

public struct ForgeAccountID: Hashable, Sendable {
    public let forge: ForgeIdentity
    public let value: String

    public init(forge: ForgeIdentity, value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeIdentityError.invalidAccountIdentifier
        }
        self.forge = forge
        self.value = value
    }
}

extension ForgeAccountID: Codable {
    private enum CodingKeys: String, CodingKey {
        case forge
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            forge: container.decode(ForgeIdentity.self, forKey: .forge),
            value: container.decode(String.self, forKey: .value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(forge, forKey: .forge)
        try container.encode(value, forKey: .value)
    }
}

enum ForgePathComponent {
    static func isNonemptyPrintable(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func isSafe(_ value: String) -> Bool {
        isNonemptyPrintable(value)
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }
}
