import Foundation

public enum WorktreeLinkStyle: Int, Sendable {
    case unknown, absolute, relative, mixed
}

/// A value snapshot of Git's porcelain record. Filesystem identity keeps the
/// original UTF-8 bytes; Swift's Unicode-equivalent String equality is not a
/// substitute for Git path or reference identity.
public struct GitWorktree: Equatable, Sendable {
    public let identity: Data
    public let head: String?
    public let branchIdentity: Data?
    public let isMain: Bool
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let prunableReason: String?
    public let isCurrent: Bool
    public let linkStyle: WorktreeLinkStyle
    public let hasBrokenLink: Bool
    public let movedPath: String?
    public let folderExists: Bool
    public let hasForeignLink: Bool

    public var path: String {
        String(decoding: identity, as: UTF8.self)
    }

    public var branchRefName: String? {
        branchIdentity.map { String(decoding: $0, as: UTF8.self) }
    }

    public init(path: String, head: String? = nil, branchRefName: String? = nil, isMain: Bool = false,
                isBare: Bool = false, isDetached: Bool = false, isLocked: Bool = false,
                lockReason: String? = nil, isPrunable: Bool = false, prunableReason: String? = nil,
                isCurrent: Bool = false, linkStyle: WorktreeLinkStyle = .unknown,
                hasBrokenLink: Bool = false, movedPath: String? = nil, folderExists: Bool = true,
                hasForeignLink: Bool = false)
    {
        identity = Data(path.utf8)
        self.head = head
        branchIdentity = branchRefName.map { Data($0.utf8) }
        self.isMain = isMain
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
        self.isCurrent = isCurrent
        self.linkStyle = linkStyle
        self.hasBrokenLink = hasBrokenLink
        self.movedPath = movedPath
        self.folderExists = folderExists
        self.hasForeignLink = hasForeignLink
    }
}

public enum WorktreeParseError: Error, Equatable {
    case malformedRecord
}

public enum WorktreeParser {
    /// `--porcelain -z` ends each field with NUL and each record with an empty
    /// field. Reasons and paths are unquoted in this format, including newlines.
    public static func parse(_ data: Data) throws -> [GitWorktree] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0 else { throw WorktreeParseError.malformedRecord }
        var result: [GitWorktree] = []
        var record: [String: String] = [:]
        var identities = Set<Data>()
        for bytes in data.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            guard let field = String(bytes: bytes, encoding: .utf8) else { throw WorktreeParseError.malformedRecord }
            if field.isEmpty {
                guard !record.isEmpty else { throw WorktreeParseError.malformedRecord }
                let worktree = try makeRecord(record, isMain: result.isEmpty)
                guard identities.insert(worktree.identity).inserted else { throw WorktreeParseError.malformedRecord }
                result.append(worktree)
                record.removeAll(keepingCapacity: true)
                continue
            }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : ""
            guard !record.isEmpty || key == "worktree" else { throw WorktreeParseError.malformedRecord }
            if ["worktree", "HEAD", "branch", "bare", "detached", "locked", "prunable"].contains(key) {
                guard record[key] == nil else { throw WorktreeParseError.malformedRecord }
                record[key] = value
            }
        }
        guard record.isEmpty else { throw WorktreeParseError.malformedRecord }
        return result
    }

    private static func makeRecord(_ fields: [String: String], isMain: Bool) throws -> GitWorktree {
        guard let path = fields["worktree"], path.hasPrefix("/") else { throw WorktreeParseError.malformedRecord }
        let bare = fields["bare"] != nil
        let detached = fields["detached"] != nil
        let head = fields["HEAD"]
        let branch = fields["branch"]
        guard fields["bare"].map({ $0.isEmpty }) ?? true, fields["detached"].map({ $0.isEmpty }) ?? true else {
            throw WorktreeParseError.malformedRecord
        }
        if bare {
            guard head == nil, branch == nil, !detached else { throw WorktreeParseError.malformedRecord }
        } else {
            guard let head, !head.isEmpty, detached ? branch == nil : (branch?.hasPrefix("refs/heads/") == true && (branch?.count ?? 0) > 11) else {
                throw WorktreeParseError.malformedRecord
            }
        }
        return GitWorktree(path: path, head: head, branchRefName: branch, isMain: isMain,
                           isBare: bare, isDetached: detached, isLocked: fields["locked"] != nil,
                           lockReason: nonempty(fields["locked"]), isPrunable: fields["prunable"] != nil,
                           prunableReason: nonempty(fields["prunable"]))
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public enum WorktreePolicy {
    public static let minimumGitVersion = "2.48"

    public static func supports(version: String?) -> Bool {
        guard let version else { return false }
        let raw = version.hasPrefix("git version ") ? String(version.dropFirst(12)) : version
        let token = raw.split(separator: " ").first ?? ""
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, let major = Int(components[0]), let minor = Int(components[1]),
              major >= 0, minor >= 0, components.dropFirst(2).allSatisfy({ Int($0).map { $0 >= 0 } == true }) else { return false }
        return major > 2 || (major == 2 && minor >= 48)
    }

    public static func offersForcedRemoval(gitMessage: String) -> Bool {
        gitMessage.contains("use --force") || gitMessage.contains("containing submodules")
    }

    public static func preferredRepairStyle(_ styles: [WorktreeLinkStyle]) -> WorktreeLinkStyle {
        let known = styles.filter { $0 != .unknown }
        return !known.isEmpty && known.allSatisfy { $0 == .relative } ? .relative : .absolute
    }
}
