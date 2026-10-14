import Foundation

public enum WorktreePrunePresentation: Equatable, Sendable {
    case repair
    case empty
    case confirmation(String)
}

public enum WorktreeRepairPresentation: Equatable, Sendable {
    case perform
    case reclaim
    case renewed
}

public enum WorktreeRepairOfferPresentation: Equatable, Sendable {
    case manualGuidance
    case none
    case chooseStyle
}

public enum WorktreePresentationPolicy {
    public static func isExpectedCancellation(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }

    public static func prune(report: String, hasMovedWorktrees: Bool) -> WorktreePrunePresentation {
        if hasMovedWorktrees {
            return .repair
        }
        let report = report.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.isEmpty ? .empty : .confirmation(report)
    }

    public static func repair(requiresReclaim: Bool, changed: Bool) -> WorktreeRepairPresentation {
        if requiresReclaim {
            return .reclaim
        }
        return changed ? .renewed : .perform
    }

    public static func repairOffer(hasManualRepairPaths: Bool, hasBrokenLinks: Bool) -> WorktreeRepairOfferPresentation {
        if hasManualRepairPaths {
            return .manualGuidance
        }
        return hasBrokenLinks ? .chooseStyle : .none
    }
}

public struct SidebarSelectionControlsRefreshState: Sendable {
    private var depth = 0

    public init() {}

    public mutating func begin() {
        depth += 1
    }

    /// Nested selection and rebuild scopes contribute to one final refresh.
    public mutating func finish() -> Bool {
        guard depth > 0 else { return false }
        depth -= 1
        return depth == 0
    }
}

public enum SidebarWorktreeMenuPolicy {
    public static func canUseReferenceMenu(reference: String, branchIdentity: Data?) -> Bool {
        guard reference.hasPrefix("refs/heads/"), reference.utf8.count > "refs/heads/".utf8.count else { return false }
        return branchIdentity == Data(reference.utf8)
    }
}

public struct SidebarRemoteSyncPlan: Equatable, Sendable {
    public let namesToAdd: [String]
    public let namesToRemove: [String]

    public init(namesToAdd: [String], namesToRemove: [String]) {
        self.namesToAdd = namesToAdd
        self.namesToRemove = namesToRemove
    }
}

public enum SidebarRemotePolicy {
    public static func syncPlan(
        configuredRemoteNames: [String],
        existingRemoteNames: [String],
        nonEmptyRemoteNames: [String]
    ) -> SidebarRemoteSyncPlan {
        let configured = Set(configuredRemoteNames)
        let existing = Set(existingRemoteNames)
        let nonEmpty = Set(nonEmptyRemoteNames)
        return SidebarRemoteSyncPlan(
            namesToAdd: sorted(configured.subtracting(existing)),
            namesToRemove: sorted(existing.subtracting(configured).subtracting(nonEmpty))
        )
    }

    private static func sorted(_ names: Set<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum SidebarRevisionPlacement: Int, Sendable {
    case other
    case branchRoot
    case branchPath
    case tagPath
    case remotePath
    case hidden
    case unsupported
}

public struct SidebarRevisionPlan: Equatable, Sendable {
    public let placement: SidebarRevisionPlacement
    public let path: [String]

    public init(placement: SidebarRevisionPlacement, path: [String] = []) {
        self.placement = placement
        self.path = path
    }
}

public enum SidebarRevisionPolicy {
    public static func plan(
        simpleReference: String?,
        shouldShowBranch: Bool,
        usesRecentBranchSorting: Bool
    ) -> SidebarRevisionPlan {
        guard let simpleReference else {
            return SidebarRevisionPlan(placement: .other)
        }
        let components = simpleReference.components(separatedBy: "/")
        guard components.count >= 2 else {
            return SidebarRevisionPlan(placement: .branchRoot)
        }
        if components[1] == "heads" {
            guard shouldShowBranch else {
                return SidebarRevisionPlan(placement: .hidden)
            }
            if usesRecentBranchSorting {
                return SidebarRevisionPlan(placement: .branchRoot)
            }
            return SidebarRevisionPlan(placement: .branchPath, path: Array(components.dropFirst(2)))
        }
        if simpleReference.hasPrefix("refs/tags/") {
            return SidebarRevisionPlan(placement: .tagPath, path: Array(components.dropFirst(2)))
        }
        if simpleReference.hasPrefix("refs/remotes/") {
            return SidebarRevisionPlan(placement: .remotePath, path: Array(components.dropFirst(2)))
        }
        return SidebarRevisionPlan(placement: .unsupported)
    }
}
