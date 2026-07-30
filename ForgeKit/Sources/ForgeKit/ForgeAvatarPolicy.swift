import Foundation

public enum ForgeAvatarSecurityConstants {
    /// GitHub.com API identity fields currently return avatars from this exact
    /// host. Markdown image destinations never pass through this allowlist.
    public static let exactGitHubHosts: Set<String> = [
        "avatars.githubusercontent.com",
    ]

    public static let maximumResponseBytes = 5 * 1024 * 1024
    public static let maximumDecodedPixels = 2048 * 2048
}

public enum ForgeAvatarPolicyError: Error, Equatable, LocalizedError, Sendable {
    case disallowedURL
    case unsuccessfulResponse
    case unsupportedMediaType
    case responseTooLarge
    case invalidDimensions
    case decodedImageTooLarge
    case mediaTypeMismatch

    public var errorDescription: String? {
        switch self {
        case .disallowedURL:
            "The structured avatar URL is not allowed."
        case .unsuccessfulResponse:
            "The structured avatar request did not return a successful response."
        case .unsupportedMediaType:
            "The structured avatar response has an unsupported media type."
        case .responseTooLarge:
            "The structured avatar response exceeds the byte limit."
        case .invalidDimensions:
            "The structured avatar has invalid dimensions."
        case .decodedImageTooLarge:
            "The structured avatar exceeds the decoded-pixel limit."
        case .mediaTypeMismatch:
            "The structured avatar response does not match its declared media type."
        }
    }
}

public struct ForgeAvatarURL: Equatable, Hashable, Sendable {
    public let url: URL

    public init(_ url: URL) throws {
        guard Self.hasValidPercentEscapes(url.absoluteString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              ForgeAvatarSecurityConstants.exactGitHubHosts.contains(host),
              components.port == nil || components.port == 443,
              components.fragment == nil
        else {
            throw ForgeAvatarPolicyError.disallowedURL
        }
        components.scheme = "https"
        components.host = host
        components.port = nil
        guard let canonicalURL = components.url else {
            throw ForgeAvatarPolicyError.disallowedURL
        }
        self.url = canonicalURL
    }

    public init(_ destination: String) throws {
        guard Self.hasValidPercentEscapes(destination),
              let url = URL(string: destination)
        else {
            throw ForgeAvatarPolicyError.disallowedURL
        }
        try self.init(url)
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        for index in scalars.indices where scalars[index] == "%" {
            guard index + 2 < scalars.count,
                  scalars[index + 1].isAvatarASCIIHexDigit,
                  scalars[index + 2].isAvatarASCIIHexDigit
            else {
                return false
            }
        }
        return true
    }
}

private extension Unicode.Scalar {
    var isAvatarASCIIHexDigit: Bool {
        switch value {
        case 48 ... 57, 65 ... 70, 97 ... 102: true
        default: false
        }
    }
}

extension ForgeAvatarURL: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}

public enum ForgeAvatarMediaType: String, Codable, CaseIterable, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webP = "image/webp"

    public init?(httpContentType: String?) {
        guard let value = httpContentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }
        self.init(rawValue: value)
    }

    public static var acceptHeader: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public struct ForgeAvatarResponseMetadata: Equatable, Sendable {
    public let finalURL: ForgeAvatarURL
    public let mediaType: ForgeAvatarMediaType
    public let expectedByteCount: Int?

    public init(
        finalURL: URL,
        statusCode: Int,
        contentType: String?,
        expectedByteCount: Int64,
        maximumResponseBytes: Int = ForgeAvatarSecurityConstants.maximumResponseBytes
    ) throws {
        guard maximumResponseBytes >= 0 else {
            throw ForgeAvatarPolicyError.responseTooLarge
        }
        guard statusCode == 200 else {
            throw ForgeAvatarPolicyError.unsuccessfulResponse
        }
        self.finalURL = try ForgeAvatarURL(finalURL)
        guard let mediaType = ForgeAvatarMediaType(httpContentType: contentType) else {
            throw ForgeAvatarPolicyError.unsupportedMediaType
        }
        self.mediaType = mediaType
        if expectedByteCount >= 0 {
            guard expectedByteCount <= maximumResponseBytes else {
                throw ForgeAvatarPolicyError.responseTooLarge
            }
            self.expectedByteCount = Int(expectedByteCount)
        } else {
            self.expectedByteCount = nil
        }
    }
}

public struct ForgeAvatarByteAccumulator: Sendable {
    public let maximumByteCount: Int
    public private(set) var data: Data

    public init(
        maximumByteCount: Int = ForgeAvatarSecurityConstants.maximumResponseBytes,
        expectedByteCount: Int? = nil
    ) throws {
        guard maximumByteCount >= 0,
              expectedByteCount.map({ $0 >= 0 && $0 <= maximumByteCount }) ?? true
        else {
            throw ForgeAvatarPolicyError.responseTooLarge
        }
        self.maximumByteCount = maximumByteCount
        data = Data()
        if let expectedByteCount {
            data.reserveCapacity(expectedByteCount)
        }
    }

    public mutating func append(_ chunk: Data) throws {
        let (newCount, overflow) = data.count.addingReportingOverflow(chunk.count)
        guard !overflow, newCount <= maximumByteCount else {
            throw ForgeAvatarPolicyError.responseTooLarge
        }
        data.append(chunk)
    }
}

public struct ForgeAvatarDecodedDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelCount: Int

    public init(
        width: Int,
        height: Int,
        maximumPixels: Int = ForgeAvatarSecurityConstants.maximumDecodedPixels
    ) throws {
        guard width > 0, height > 0, maximumPixels >= 0 else {
            throw ForgeAvatarPolicyError.invalidDimensions
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= maximumPixels else {
            throw ForgeAvatarPolicyError.decodedImageTooLarge
        }
        self.width = width
        self.height = height
        self.pixelCount = pixelCount
    }
}
