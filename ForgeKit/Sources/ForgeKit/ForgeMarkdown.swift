import Foundation

public struct ForgeMarkdownDocument: Codable, Equatable, Sendable {
    public let blocks: [ForgeMarkdownBlock]

    public init(blocks: [ForgeMarkdownBlock]) {
        self.blocks = blocks
    }
}

public indirect enum ForgeMarkdownBlock: Codable, Equatable, Sendable {
    case paragraph([ForgeMarkdownInline])
    case heading(level: Int, identifier: ForgeMarkdownHeadingID, content: [ForgeMarkdownInline])
    case blockQuote([ForgeMarkdownBlock])
    case unorderedList([ForgeMarkdownListItem])
    case orderedList(start: UInt, items: [ForgeMarkdownListItem])
    case table(ForgeMarkdownTable)
    case thematicBreak
    case codeBlock(language: String?, code: String)
}

public indirect enum ForgeMarkdownInline: Codable, Equatable, Sendable {
    case text(String)
    case emphasis([ForgeMarkdownInline])
    case strong([ForgeMarkdownInline])
    case strikethrough([ForgeMarkdownInline])
    case inlineCode(String)
    case softBreak
    case lineBreak
    case link(label: [ForgeMarkdownInline], target: ForgeMarkdownLinkTarget)

    /// Deliberately contains no image source. Forge-authored Markdown cannot
    /// cause network or local-file access during parsing or rendering.
    case imagePlaceholder(altText: String)
}

public struct ForgeMarkdownHeadingID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ForgeMarkdownListItem: Codable, Equatable, Sendable {
    public let taskState: ForgeMarkdownTaskState?
    public let blocks: [ForgeMarkdownBlock]

    public init(taskState: ForgeMarkdownTaskState?, blocks: [ForgeMarkdownBlock]) {
        self.taskState = taskState
        self.blocks = blocks
    }
}

public enum ForgeMarkdownTaskState: String, Codable, Equatable, Sendable {
    case checked
    case unchecked
}

public struct ForgeMarkdownTable: Codable, Equatable, Sendable {
    public let columnAlignments: [ForgeMarkdownTableAlignment?]
    public let header: [ForgeMarkdownTableCell]
    public let rows: [[ForgeMarkdownTableCell]]

    public init(
        columnAlignments: [ForgeMarkdownTableAlignment?],
        header: [ForgeMarkdownTableCell],
        rows: [[ForgeMarkdownTableCell]]
    ) {
        self.columnAlignments = columnAlignments
        self.header = header
        self.rows = rows
    }
}

public enum ForgeMarkdownTableAlignment: String, Codable, Equatable, Sendable {
    case left
    case center
    case right
}

public struct ForgeMarkdownTableCell: Codable, Equatable, Sendable {
    public let columnSpan: UInt
    public let rowSpan: UInt
    public let content: [ForgeMarkdownInline]

    public init(columnSpan: UInt, rowSpan: UInt, content: [ForgeMarkdownInline]) {
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
        self.content = content
    }
}

public struct ForgeMarkdownContext: Codable, Equatable, Sendable {
    public let repository: ForgeRepositoryIdentity
    public let location: ForgeMarkdownLocation

    public init(repository: ForgeRepositoryIdentity, location: ForgeMarkdownLocation) {
        self.repository = repository
        self.location = location
    }
}

public enum ForgeMarkdownLocation: Codable, Equatable, Sendable {
    case repository(defaultBranch: ForgeRevision)
    case file(revision: ForgeRevision, path: ForgeFilePath)

    var revision: ForgeRevision {
        switch self {
        case let .repository(defaultBranch): defaultBranch
        case let .file(revision, _): revision
        }
    }

    var baseDirectoryComponents: [String] {
        switch self {
        case .repository: []
        case let .file(_, path): Array(path.components.dropLast())
        }
    }
}

public struct ForgeMarkdownHeadingSlugger: Sendable {
    private var used: Set<String> = []
    private var nextSuffix: [String: Int] = [:]

    public init() {}

    public mutating func identifier(for heading: String) -> ForgeMarkdownHeadingID {
        let base = Self.slug(heading)
        guard !used.contains(base) else {
            var suffix = nextSuffix[base, default: 1]
            var candidate = "\(base)-\(suffix)"
            while used.contains(candidate) {
                suffix += 1
                candidate = "\(base)-\(suffix)"
            }
            nextSuffix[base] = suffix + 1
            used.insert(candidate)
            return ForgeMarkdownHeadingID(rawValue: candidate)
        }
        used.insert(base)
        nextSuffix[base] = 1
        return ForgeMarkdownHeadingID(rawValue: base)
    }

    private static func slug(_ heading: String) -> String {
        return String.UnicodeScalarView(
            heading.lowercased().unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                if scalar == " " {
                    return "-"
                }
                if scalar == "-" {
                    return scalar
                }
                return ForgeGitHubSlugUnicode13.retains(scalar) ? scalar : nil
            }
        ).description
    }
}
