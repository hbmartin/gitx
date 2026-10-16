import Foundation

/// Debounces overlapping discoveries while retaining an explicit generation
/// barrier for close and executable changes.
public struct WorktreeRefreshState: Sendable {
    public private(set) var isClosed = false
    public private(set) var isStale = true
    private var generation: UInt64 = 0
    private var inFlight = false
    private var reconciling = false
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
        !isClosed && inFlight && !reconciling && candidate == generation
    }

    public mutating func complete(_ candidate: UInt64, succeeded: Bool = true) -> UInt64? {
        guard accepts(candidate) else { return nil }
        inFlight = false
        isStale = !succeeded
        let refresh = needsRefresh
        needsRefresh = false
        return refresh ? request() : nil
    }

    /// Retire an ordinary reader while carrying its invalidations across the owned pass.
    public mutating func beginReconciliation() -> UInt64? {
        guard !isClosed else { return nil }
        guard !reconciling else { needsRefresh = true; return nil }
        needsRefresh = needsRefresh || inFlight
        generation &+= 1
        inFlight = true
        reconciling = true
        isStale = true
        return generation
    }

    /// Only this failed owned pass earns an automatic recovery read. A failed
    /// ordinary recovery stays stale until another event or explicit refresh.
    public mutating func completeReconciliation(_ candidate: UInt64, succeeded: Bool) -> UInt64? {
        guard !isClosed, inFlight, reconciling, candidate == generation else { return nil }
        inFlight = false
        reconciling = false
        isStale = !succeeded
        let refresh = needsRefresh || !succeeded
        needsRefresh = false
        return refresh ? request() : nil
    }

    public mutating func invalidate() {
        generation &+= 1
        inFlight = false
        reconciling = false
        needsRefresh = false
        isStale = true
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
        supported && !worktrees.contains { $0.movedPath != nil }
    }
}

public extension WorktreePolicy {
    /// Keep moved checkout evidence for prune protection when its link object
    /// cannot be safely reconstructed by automatic repair.
    static func manualRepairPaths(_ records: [GitWorktree]) -> [String] {
        records.compactMap { $0.hasBrokenLink ? nil : $0.movedPath }
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
    case repairMovedPaths(paths: [String])
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
        case let .repairMovedPaths(paths): ["worktree", "repair"] + paths
        case let .repairLinks(style, paths): ["worktree", "repair"] + (style == .relative ? ["--relative-paths"] : ["--no-relative-paths"]) + paths
        }
    }
}

/// History can change without changing repair ownership or prune eligibility.
/// Raw text and resolved path endpoints remain part of the consent evidence.
public struct WorktreeConsentRecord: Equatable, Sendable {
    private let value: GitWorktree
    private let canonicalIdentity: Data
    private let lockReasonIdentity: Data?
    private let prunableReasonIdentity: Data?
    private let movedPathIdentity: Data?
    private let movedEndpointIdentity: Data?

    public init(_ record: GitWorktree) {
        value = GitWorktree(path: record.path, isMain: record.isMain, isBare: record.isBare,
                            isLocked: record.isLocked, lockReason: record.lockReason,
                            isPrunable: record.isPrunable, prunableReason: record.prunableReason,
                            isCurrent: record.isCurrent, linkStyle: record.linkStyle,
                            hasBrokenLink: record.hasBrokenLink, movedPath: record.movedPath,
                            folderExists: record.folderExists, hasForeignLink: record.hasForeignLink)
        canonicalIdentity = WorktreePaths.identity(record.path)
        lockReasonIdentity = record.lockReason.map { Data($0.utf8) }
        prunableReasonIdentity = record.prunableReason.map { Data($0.utf8) }
        movedPathIdentity = record.movedPath.map { Data($0.utf8) }
        movedEndpointIdentity = record.movedPath.map(WorktreePaths.identity)
    }
}

public enum WorktreeHistoryRevision: Equatable, Sendable {
    case branch(String)
    case capturedCommit(oid: String, description: String)
}

public enum WorktreePresentation {
    public static func historyRevision(for worktree: GitWorktree) -> WorktreeHistoryRevision? {
        if let branch = worktree.branchRefName {
            return .branch(branch)
        }
        guard worktree.isDetached || worktree.headRefIdentity != nil,
              let head = worktree.head, !head.isEmpty, head.contains(where: { $0 != "0" }) else { return nil }
        let description = worktree.headRefName == nil ? "Detached HEAD (\(head))" : "\(title(worktree)) (\(head))"
        return .capturedCommit(oid: head, description: description)
    }

    public static func title(_ worktree: GitWorktree) -> String {
        if let branch = worktree.branchRefName {
            return String(branch.dropFirst("refs/heads/".count))
        }
        if let reference = worktree.headRefName {
            return "HEAD → " + reference
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
