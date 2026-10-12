import Foundation

/// Debounces overlapping discoveries while retaining an explicit generation
/// barrier for close and executable changes.
public struct WorktreeRefreshState: Sendable {
    public private(set) var isClosed = false
    private var generation: UInt64 = 0
    private var inFlight = false
    private var needsRefresh = false

    public init() {}

    public mutating func request() -> UInt64? {
        guard !isClosed else { return nil }
        guard !inFlight else { needsRefresh = true; return nil }
        inFlight = true
        generation &+= 1
        return generation
    }

    public func accepts(_ candidate: UInt64) -> Bool {
        !isClosed && inFlight && candidate == generation
    }

    public mutating func complete(_ candidate: UInt64) -> UInt64? {
        guard accepts(candidate) else { return nil }
        inFlight = false
        let refresh = needsRefresh
        needsRefresh = false
        return refresh ? request() : nil
    }

    public mutating func invalidate() {
        generation &+= 1
        inFlight = false
        needsRefresh = false
    }

    public mutating func close() {
        invalidate(); isClosed = true
    }
}

public struct WorktreeEligibility: Equatable, Sendable {
    public let canOpen: Bool
    public let canRemove: Bool
    public let canLock: Bool
    public let canUnlock: Bool
    public let canReveal: Bool
    public let canLocate: Bool

    public init(_ worktree: GitWorktree, supported: Bool) {
        canOpen = supported && !worktree.isCurrent
        canRemove = supported && !worktree.isMain && !worktree.isCurrent && !worktree.isLocked
        canLock = supported && !worktree.isMain && !worktree.isLocked
        canUnlock = supported && !worktree.isMain && worktree.isLocked
        canReveal = supported && worktree.folderExists
        canLocate = supported && !worktree.isMain && !worktree.folderExists && worktree.movedPath == nil
    }

    public static func canPrune(_ worktrees: [GitWorktree], supported: Bool) -> Bool {
        supported && !worktrees.contains { $0.movedPath != nil } && worktrees.contains { $0.isPrunable || !$0.folderExists }
    }
}

public enum WorktreeCommand: Equatable, Sendable {
    case addExisting(path: String, branch: String)
    case addNew(path: String, branch: String)
    case remove(path: String, force: Bool)
    case lock(path: String, reason: String)
    case unlock(path: String)
    case pruneReport
    case prune
    case repairMoved(path: String)
    case repairLinks(style: WorktreeLinkStyle, movedPaths: [String])

    public var arguments: [String] {
        switch self {
        case let .addExisting(path, branch): ["worktree", "add", path, branch]
        case let .addNew(path, branch): ["worktree", "add", "-b", branch, path]
        case let .remove(path, force): ["worktree", "remove"] + (force ? ["--force"] : []) + [path]
        case let .lock(path, reason): ["worktree", "lock"] + (reason.isEmpty ? [] : ["--reason", reason]) + [path]
        case let .unlock(path): ["worktree", "unlock", path]
        case .pruneReport: ["worktree", "prune", "--dry-run", "--verbose"]
        case .prune: ["worktree", "prune"]
        case let .repairMoved(path): ["worktree", "repair", path]
        case let .repairLinks(style, paths): ["worktree", "repair"] + (style == .relative ? ["--relative-paths"] : ["--no-relative-paths"]) + paths
        }
    }
}

public enum WorktreePresentation {
    public static func title(_ worktree: GitWorktree) -> String {
        if let branch = worktree.branchRefName {
            return String(branch.dropFirst("refs/heads/".count))
        }
        if worktree.isBare {
            return "Bare repository"
        }
        if let head = worktree.head {
            return "Detached HEAD (\(head.prefix(7)))"
        }
        return (worktree.path as NSString).lastPathComponent
    }

    public static func details(_ worktree: GitWorktree) -> String {
        var details = [title(worktree), worktree.path]
        if worktree.isCurrent {
            details.append("Current worktree")
        }
        if worktree.isMain {
            details.append("Main worktree")
        }
        if worktree.isLocked {
            details.append("Locked" + worktree.lockReason.map { ": \($0)" }.orEmpty)
        }
        if let moved = worktree.movedPath {
            details.append("Moved with repository to \(moved)")
        }
        if worktree.hasBrokenLink {
            details.append("Broken repository link; repair required")
        }
        if worktree.hasForeignLink {
            details.append("Linked to another repository; automatic repair unavailable")
        }
        if worktree.isPrunable {
            details.append("Prunable" + worktree.prunableReason.map { ": \($0)" }.orEmpty)
        }
        if !worktree.folderExists {
            details.append("Folder unavailable")
        }
        return details.joined(separator: "\n")
    }

    public static func suggestedFolderName(mainPath: String, branch: String) -> String {
        let repository = ((mainPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return repository + "-" + branch.replacingOccurrences(of: "/", with: "-")
    }
}

private extension String? {
    var orEmpty: String {
        self ?? ""
    }
}
