import Foundation

public enum ForgeDestinationValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidReference
    case invalidCommitID
    case invalidFilePath
    case invalidLine
    case invalidLineRange
    case invalidItemNumber

    public var errorDescription: String? {
        switch self {
        case .invalidReference: "The Forge reference is invalid."
        case .invalidCommitID: "The Forge commit identifier is invalid."
        case .invalidFilePath: "The Forge file path is invalid."
        case .invalidLine: "The Forge line number is invalid."
        case .invalidLineRange: "The Forge line range is invalid."
        case .invalidItemNumber: "The Pull Request or Issue number is invalid."
        }
    }
}

public struct ForgeRefName: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.isValid(value) else {
            throw ForgeDestinationValidationError.invalidReference
        }
        self.value = value.precomposedStringWithCanonicalMapping
    }

    private static func isValid(_ value: String) -> Bool {
        guard ForgePathComponent.isNonemptyPrintable(value),
              !value.hasPrefix("-"),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              !value.contains("//"),
              !value.contains(".."),
              value != "@",
              !value.contains("@{"),
              !value.unicodeScalars.contains(where: { " ~^:?*[\\".unicodeScalars.contains($0) })
        else {
            return false
        }
        return value.split(separator: "/").allSatisfy {
            !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }
}

extension ForgeRefName: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ForgeCommitID: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard (4 ... 64).contains(value.count),
              value.unicodeScalars.allSatisfy(\.isASCIIHexDigit)
        else {
            throw ForgeDestinationValidationError.invalidCommitID
        }
        self.value = value.lowercased()
    }
}

extension ForgeCommitID: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ForgeRevision: Codable, Hashable, Sendable {
    case branch(ForgeRefName)
    case tag(ForgeRefName)
    case commit(ForgeCommitID)
    /// A revision parsed from a provider URL whose branch, tag, or commit
    /// identity is not encoded by that URL. Its exact ref text is preserved.
    case opaque(ForgeRefName)

    public var value: String {
        switch self {
        case let .branch(reference), let .tag(reference), let .opaque(reference): reference.value
        case let .commit(identifier): identifier.value
        }
    }
}

public struct ForgeFilePath: Hashable, Sendable {
    public let components: [String]

    public init(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.hasSuffix("/") else {
            throw ForgeDestinationValidationError.invalidFilePath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(ForgePathComponent.isSafe) else {
            throw ForgeDestinationValidationError.invalidFilePath
        }
        self.components = components.map { $0.precomposedStringWithCanonicalMapping }
    }

    public var value: String {
        components.joined(separator: "/")
    }
}

extension ForgeFilePath: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ForgeLineSelection: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let end: Int

    public init(line: Int) throws {
        guard line > 0 else { throw ForgeDestinationValidationError.invalidLine }
        start = line
        end = line
    }

    public init(start: Int, end: Int) throws {
        guard start > 0, end > 0, start <= end else {
            throw ForgeDestinationValidationError.invalidLineRange
        }
        self.start = start
        self.end = end
    }

    public var isSingleLine: Bool {
        start == end
    }
}

public struct ForgeItemNumber: Hashable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws {
        guard rawValue > 0 else { throw ForgeDestinationValidationError.invalidItemNumber }
        self.rawValue = rawValue
    }
}

extension ForgeItemNumber: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ForgeDestination: Codable, Equatable, Hashable, Sendable {
    case repository(ForgeRepositoryIdentity)
    case branch(ForgeRepositoryIdentity, ForgeRefName)
    case commit(ForgeRepositoryIdentity, ForgeCommitID)
    case file(ForgeRepositoryIdentity, revision: ForgeRevision, path: ForgeFilePath, selection: ForgeLineSelection?)
    case compare(ForgeRepositoryIdentity, base: ForgeRevision, head: ForgeRevision)
    case pullRequest(ForgeRepositoryIdentity, ForgeItemNumber)
    case issue(ForgeRepositoryIdentity, ForgeItemNumber)

    public var repository: ForgeRepositoryIdentity {
        switch self {
        case let .repository(repository),
             let .branch(repository, _),
             let .commit(repository, _),
             let .file(repository, _, _, _),
             let .compare(repository, _, _),
             let .pullRequest(repository, _),
             let .issue(repository, _):
            repository
        }
    }

    public var kind: ForgeDestinationKind {
        switch self {
        case .repository: .repository
        case .branch: .branch
        case .commit: .commit
        case .file: .file
        case .compare: .compare
        case .pullRequest: .pullRequest
        case .issue: .issue
        }
    }
}

public enum ForgeDestinationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case repository
    case branch
    case commit
    case file
    case compare
    case pullRequest
    case issue
}
