import Foundation

public enum ForgeMarkdownLinkPolicyError: Error, Equatable, LocalizedError, Sendable {
    case invalidHTTPSURL
    case invalidMailtoURL
    case unsupportedMailtoField
    case unsafeMailtoHeader

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPSURL: "The Markdown link is not a valid HTTPS URL."
        case .invalidMailtoURL: "The Markdown link is not a valid mail address."
        case .unsupportedMailtoField: "The mail link contains an unsupported field."
        case .unsafeMailtoHeader: "The mail link contains an unsafe header value."
        }
    }
}

public struct ForgeHTTPSLink: Hashable, Sendable {
    public let url: URL
    public let origin: ForgeOrigin

    public init(_ destination: String) throws {
        guard ForgeURLSyntax.hasValidPercentEscapes(destination),
              var components = URLComponents(string: destination),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              let originalURL = components.url
        else {
            throw ForgeMarkdownLinkPolicyError.invalidHTTPSURL
        }
        let validatedOrigin: ForgeOrigin
        do {
            validatedOrigin = try ForgeOrigin(host: host, port: components.port)
        } catch {
            throw ForgeMarkdownLinkPolicyError.invalidHTTPSURL
        }
        components.scheme = "https"
        components.host = validatedOrigin.host
        components.port = validatedOrigin.port
        url = components.url ?? originalURL
        origin = validatedOrigin
    }

    public var displayHost: String {
        origin.host
    }

    public var asciiHost: String {
        origin.url.host(percentEncoded: false) ?? origin.host
    }
}

extension ForgeHTTPSLink: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}

public struct ForgeMailLink: Hashable, Sendable {
    public let url: URL
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String?
    public let hasBody: Bool

    public init(_ destination: String) throws {
        guard ForgeURLSyntax.hasValidPercentEscapes(destination),
              var components = URLComponents(string: destination),
              components.scheme?.lowercased() == "mailto",
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let normalizedURL = components.url
        else {
            throw ForgeMarkdownLinkPolicyError.invalidMailtoURL
        }

        var decodedTo = try Self.recipients(components.percentEncodedPath)
        var decodedCC: [String] = []
        var decodedBCC: [String] = []
        var decodedSubject: String?
        var containsBody = false
        var sawSubject = false
        var sawBody = false

        for item in try Self.queryItems(components.percentEncodedQuery) {
            let value = try Self.decoded(item.value)
            switch item.name {
            case "to":
                decodedTo += try Self.recipients(item.value)
            case "cc":
                decodedCC += try Self.recipients(item.value)
            case "bcc":
                decodedBCC += try Self.recipients(item.value)
            case "subject":
                guard !sawSubject else { throw ForgeMarkdownLinkPolicyError.invalidMailtoURL }
                try Self.validateHeader(value)
                decodedSubject = value
                sawSubject = true
            case "body":
                guard !sawBody else { throw ForgeMarkdownLinkPolicyError.invalidMailtoURL }
                containsBody = !value.isEmpty
                sawBody = true
            default:
                throw ForgeMarkdownLinkPolicyError.unsupportedMailtoField
            }
        }

        components.scheme = "mailto"
        let finalURL = components.url ?? normalizedURL
        url = finalURL == normalizedURL ? normalizedURL : finalURL
        to = decodedTo
        cc = decodedCC
        bcc = decodedBCC
        subject = decodedSubject
        hasBody = containsBody
    }

    private static func recipients(_ field: String) throws -> [String] {
        if field.isEmpty {
            return []
        }

        var encodedRecipients: [Substring] = []
        var start = field.startIndex
        var index = start
        var insideQuotes = false
        var escapingQuote = false
        while index < field.endIndex {
            let tokenStart = index
            let token = structuralToken(in: field, at: index)
            index = token.nextIndex

            if escapingQuote {
                escapingQuote = false
            } else if token.character == "\\", insideQuotes {
                escapingQuote = true
            } else if token.character == "\"" {
                insideQuotes.toggle()
            } else if token.character == ",", !token.wasPercentEncoded, !insideQuotes {
                encodedRecipients.append(field[start ..< tokenStart])
                start = index
            }
        }
        guard !insideQuotes, !escapingQuote else {
            throw ForgeMarkdownLinkPolicyError.invalidMailtoURL
        }
        encodedRecipients.append(field[start...])

        return try encodedRecipients.map { component in
            let recipient = try decoded(String(component)).trimmingCharacters(in: .whitespaces)
            guard !recipient.isEmpty else { throw ForgeMarkdownLinkPolicyError.invalidMailtoURL }
            try validateHeader(recipient)
            return recipient
        }
    }

    private struct EncodedQueryItem {
        let name: String
        let value: String
    }

    private struct StructuralToken {
        let character: Character?
        let wasPercentEncoded: Bool
        let nextIndex: String.Index
    }

    private static func queryItems(_ query: String?) throws -> [EncodedQueryItem] {
        guard let query else { return [] }
        return try query.split(separator: "&", omittingEmptySubsequences: false).map { item in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = try decoded(String(parts[0])).lowercased()
            let value = parts.count == 2 ? String(parts[1]) : ""
            return EncodedQueryItem(name: name, value: value)
        }
    }

    private static func structuralToken(in field: String, at index: String.Index) -> StructuralToken {
        let next = field.index(after: index)
        guard field[index] == "%",
              next < field.endIndex
        else {
            return StructuralToken(character: field[index], wasPercentEncoded: false, nextIndex: next)
        }
        let second = field.index(after: next)
        // The public initializer validates every percent escape before any
        // recipient field reaches this scanner.
        let byte = UInt8(field[next ... second], radix: 16) ?? 0
        let end = field.index(after: second)
        let character = byte < 128 ? Character(UnicodeScalar(byte)) : nil
        return StructuralToken(character: character, wasPercentEncoded: true, nextIndex: end)
    }

    private static func decoded(_ value: String) throws -> String {
        guard let decoded = value.removingPercentEncoding else {
            throw ForgeMarkdownLinkPolicyError.invalidMailtoURL
        }
        return decoded
    }

    private static func validateHeader(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeMarkdownLinkPolicyError.unsafeMailtoHeader
        }
    }
}

extension ForgeMailLink: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}

public enum ForgeMarkdownLinkTarget: Codable, Equatable, Hashable, Sendable {
    case heading(ForgeMarkdownHeadingID)
    case native(ForgeDestination)
    case https(ForgeHTTPSLink)
    case mailto(ForgeMailLink)
}

public struct ForgeTrustedExternalOrigin: Codable, Equatable, Hashable, Sendable {
    public let origin: ForgeOrigin

    public init(origin: ForgeOrigin) {
        self.origin = origin
    }
}

public struct ForgeExternalLinkConfirmation: Equatable, Sendable {
    public let url: URL
    public let origin: ForgeTrustedExternalOrigin
    public let displayHost: String
    public let asciiHost: String

    public init(
        url: URL,
        origin: ForgeTrustedExternalOrigin,
        displayHost: String,
        asciiHost: String
    ) {
        self.url = url
        self.origin = origin
        self.displayHost = displayHost
        self.asciiHost = asciiHost
    }
}

public struct ForgeMailConfirmation: Equatable, Sendable {
    public let url: URL
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String?
    public let hasBody: Bool

    public init(
        url: URL,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String?,
        hasBody: Bool
    ) {
        self.url = url
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.hasBody = hasBody
    }
}

public enum ForgeMarkdownLinkActivation: Equatable, Sendable {
    case scrollToHeading(ForgeMarkdownHeadingID)
    case openNative(destination: ForgeDestination, browserURL: URL)
    case openHTTPS(URL)
    case confirmHTTPS(ForgeExternalLinkConfirmation)
    case confirmMail(ForgeMailConfirmation)
}

public enum ForgeMarkdownLinkActivationPolicy {
    public static func activation(
        for target: ForgeMarkdownLinkTarget,
        boundTo repository: ForgeRepositoryIdentity,
        trustedExternalOrigins: Set<ForgeTrustedExternalOrigin>
    ) throws -> ForgeMarkdownLinkActivation {
        switch target {
        case let .heading(identifier):
            return .scrollToHeading(identifier)
        case let .native(destination):
            let browserURL = try ForgeDestinationURLCodec.url(for: destination)
            let nativeKinds: Set<ForgeDestinationKind> = [.pullRequest, .issue, .commit, .file]
            guard destination.repository == repository, nativeKinds.contains(destination.kind) else {
                return try httpsActivation(
                    ForgeHTTPSLink(browserURL.absoluteString),
                    configuredForgeOrigin: repository.forge.origin,
                    trustedExternalOrigins: trustedExternalOrigins
                )
            }
            return .openNative(destination: destination, browserURL: browserURL)
        case let .https(link):
            return httpsActivation(
                link,
                configuredForgeOrigin: repository.forge.origin,
                trustedExternalOrigins: trustedExternalOrigins
            )
        case let .mailto(link):
            return .confirmMail(ForgeMailConfirmation(
                url: link.url,
                to: link.to,
                cc: link.cc,
                bcc: link.bcc,
                subject: link.subject,
                hasBody: link.hasBody
            ))
        }
    }

    private static func httpsActivation(
        _ link: ForgeHTTPSLink,
        configuredForgeOrigin: ForgeOrigin,
        trustedExternalOrigins: Set<ForgeTrustedExternalOrigin>
    ) -> ForgeMarkdownLinkActivation {
        if link.origin.isSameOrigin(as: configuredForgeOrigin)
            || trustedExternalOrigins.contains(where: { $0.origin.isSameOrigin(as: link.origin) })
        {
            return .openHTTPS(link.url)
        }
        return .confirmHTTPS(ForgeExternalLinkConfirmation(
            url: link.url,
            origin: ForgeTrustedExternalOrigin(origin: link.origin),
            displayHost: link.displayHost,
            asciiHost: link.asciiHost
        ))
    }
}

public struct ForgeMarkdownLinkPolicy: Sendable {
    public init() {}

    public func target(
        for destination: String,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownLinkTarget? {
        guard !destination.isEmpty, ForgeURLSyntax.hasValidPercentEscapes(destination) else {
            return nil
        }
        if destination.first == "#" {
            guard !destination.dropFirst().contains("#"),
                  let identifier = String(destination.dropFirst()).removingPercentEncoding,
                  !identifier.isEmpty
            else {
                return nil
            }
            return .heading(ForgeMarkdownHeadingID(rawValue: identifier))
        }
        guard !destination.hasPrefix("//") else { return nil }

        if let scheme = URLComponents(string: destination)?.scheme?.lowercased() {
            switch scheme {
            case "https":
                guard let link = try? ForgeHTTPSLink(destination) else { return nil }
                return classifiedHTTPS(link, context: context)
            case "mailto":
                return (try? ForgeMailLink(destination)).map(ForgeMarkdownLinkTarget.mailto)
            default:
                return nil
            }
        }
        if destination.hasPrefix("/") {
            return rootRelativeTarget(destination, context: context)
        }
        return repositoryFileTarget(destination, context: context)
    }

    private func rootRelativeTarget(
        _ destination: String,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownLinkTarget? {
        // target(for:context:) has already rejected protocol-relative input;
        // a single leading slash is necessarily a relative-reference path.
        var components = URLComponents(string: destination) ?? URLComponents()
        components.scheme = "https"
        components.host = context.repository.forge.origin.host
        components.port = context.repository.forge.origin.port
        guard let url = components.url,
              Self.isWithinBoundRepository(url, repository: context.repository),
              let link = try? ForgeHTTPSLink(url.absoluteString)
        else {
            return nil
        }
        return classifiedHTTPS(link, context: context)
    }

    private func repositoryFileTarget(
        _ destination: String,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownLinkTarget? {
        guard let split = ForgeURLSyntax.relativeParts(destination) else { return nil }
        var path = context.location.baseDirectoryComponents
        for rawComponent in split.path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !rawComponent.isEmpty,
                  let component = String(rawComponent).removingPercentEncoding,
                  !component.contains("/"),
                  !component.contains("\\")
            else {
                return nil
            }
            switch component {
            case ".":
                continue
            case "..":
                guard !path.isEmpty else { return nil }
                path.removeLast()
            default:
                guard ForgePathComponent.isSafe(component) else { return nil }
                path.append(component)
            }
        }
        guard !path.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = context.repository.forge.origin.host
        components.port = context.repository.forge.origin.port
        let prefix = filePrefix(repository: context.repository, revision: context.location.revision)
        components.percentEncodedPath = "/" + (prefix + path)
            .map(ForgeURLSyntax.percentEncodedComponent)
            .joined(separator: "/")
        components.percentEncodedQuery = split.query
        components.percentEncodedFragment = split.fragment
        return components.url
            .flatMap { try? ForgeHTTPSLink($0.absoluteString) }
            .map { classifiedHTTPS($0, context: context) }
    }

    private func classifiedHTTPS(
        _ link: ForgeHTTPSLink,
        context: ForgeMarkdownContext
    ) -> ForgeMarkdownLinkTarget {
        if link.origin.isSameOrigin(as: context.repository.forge.origin),
           let destination = try? ForgeDestinationURLCodec.parse(link.url, boundTo: context.repository),
           [.pullRequest, .issue, .commit, .file].contains(destination.kind)
        {
            return .native(destination)
        }
        return .https(link)
    }

    static func isWithinBoundRepository(
        _ url: URL,
        repository: ForgeRepositoryIdentity
    ) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              let origin = try? ForgeOrigin(host: host, port: components.port),
              origin.isSameOrigin(as: repository.forge.origin)
        else {
            return false
        }
        let rawComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
        let decoded = rawComponents.compactMap { raw -> String? in
            guard let value = String(raw).removingPercentEncoding,
                  ForgePathComponent.isSafe(value)
            else {
                return nil
            }
            return value
        }
        let repositoryPrefix = repository.ownerPathComponents + [repository.name]
        return decoded.count == rawComponents.count && decoded.starts(with: repositoryPrefix)
    }

    private func filePrefix(
        repository: ForgeRepositoryIdentity,
        revision: ForgeRevision
    ) -> [String] {
        let repositoryPath = repository.ownerPathComponents + [repository.name]
        switch repository.forge.kind {
        case .github:
            return repositoryPath + ["blob", revision.value]
        case .gitLab:
            return repositoryPath + ["-", "blob", revision.value]
        case .bitbucket:
            return repositoryPath + ["src", revision.value]
        }
    }
}

private enum ForgeURLSyntax {
    struct RelativeParts {
        let path: String
        let query: String?
        let fragment: String?
    }

    static func hasValidPercentEscapes(_ value: String) -> Bool {
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

    static func relativeParts(_ value: String) -> RelativeParts? {
        let fragmentSplit = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard fragmentSplit.count <= 2 else { return nil }
        let beforeFragment = String(fragmentSplit[0])
        let querySplit = beforeFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard querySplit.count <= 2, !querySplit[0].isEmpty else { return nil }
        return RelativeParts(
            path: String(querySplit[0]),
            query: querySplit.count == 2 ? String(querySplit[1]) : nil,
            fragment: fragmentSplit.count == 2 ? String(fragmentSplit[1]) : nil
        )
    }

    static func percentEncodedComponent(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case 65 ... 90, 97 ... 122, 48 ... 57, 45, 46, 95, 126:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append("%")
                encoded.append(hexadecimalDigits[Int(byte >> 4)])
                encoded.append(hexadecimalDigits[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    private static let hexadecimalDigits: [Character] = Array("0123456789ABCDEF")
}
