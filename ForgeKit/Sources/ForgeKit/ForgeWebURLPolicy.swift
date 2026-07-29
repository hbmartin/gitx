import Foundation

public enum ForgeWebURLPolicyError: Error, Equatable, LocalizedError, Sendable {
    case invalidTemplate
    case httpsRequired
    case credentialsNotAllowed
    case hostMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidTemplate: "The custom Forge web URL template is invalid."
        case .httpsRequired: "The custom Forge web URL must use HTTPS."
        case .credentialsNotAllowed: "The custom Forge web URL cannot contain credentials."
        case .hostMismatch: "The custom Forge web URL host does not match the Git remote."
        }
    }
}

public enum ForgeWebURLPolicy {
    public static func customURL(
        template: String,
        repository: ForgeRepositoryIdentity,
        branch: String,
        commitID: String,
        requireOriginMatch: Bool
    ) throws -> URL {
        let repositoryURL = try ForgeDestinationURLCodec.url(for: .repository(repository))
        let expanded = template
            .replacingOccurrences(of: "{remoteURL}", with: repositoryURL.absoluteString)
            .replacingOccurrences(of: "{branch}", with: percentEncodedTemplateValue(branch))
            .replacingOccurrences(of: "{sha}", with: percentEncodedTemplateValue(commitID))
        guard !expanded.contains("{"), !expanded.contains("}"),
              let components = URLComponents(string: expanded),
              let url = components.url,
              let host = components.host
        else {
            throw ForgeWebURLPolicyError.invalidTemplate
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ForgeWebURLPolicyError.httpsRequired
        }
        guard components.user == nil, components.password == nil else {
            throw ForgeWebURLPolicyError.credentialsNotAllowed
        }
        let candidate: ForgeOrigin
        do {
            candidate = try ForgeOrigin(host: host, port: components.port)
        } catch {
            throw ForgeWebURLPolicyError.invalidTemplate
        }
        if requireOriginMatch {
            guard candidate.isSameOrigin(as: repository.forge.origin) else {
                throw ForgeWebURLPolicyError.hostMismatch
            }
        }
        return url
    }

    public static func firstHTTPURL(in output: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        var result: URL?
        detector.enumerateMatches(in: output, range: range) { match, _, stop in
            guard let candidate = match?.url,
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return
            }
            result = candidate
            stop.pointee = true
        }
        return result
    }

    /// Preserves the existing post-push host-match contract. Scheme and port
    /// are not treated as identity here because older Git servers may print an
    /// HTTP browser hint even when the configured Git transport is HTTPS/SSH.
    public static func postPushURL(
        _ candidate: URL,
        matchesRemote repository: ForgeRepositoryIdentity,
        requireHostMatch: Bool
    ) -> Bool {
        guard let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              let normalizedHost = try? ForgeOrigin(host: host).host
        else {
            return false
        }
        return !requireHostMatch || normalizedHost == repository.forge.origin.host
    }

    private static func percentEncodedTemplateValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )) ?? ""
    }
}
