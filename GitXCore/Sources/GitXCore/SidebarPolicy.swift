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

public struct WorktreeInventoryPresentation: Equatable, Sendable {
    public let message: String?
    public let warns: Bool
    public let isUpdating: Bool

    /// Unknown service values retain actionable inventory recovery guidance.
    public init(rawStatus: Int, hasSnapshot: Bool, capabilityExplanation: String) {
        self.init(status: WorktreeInventoryStatus(rawValue: rawStatus) ?? .stale,
                  hasSnapshot: hasSnapshot, capabilityExplanation: capabilityExplanation)
    }

    public init(status: WorktreeInventoryStatus, hasSnapshot: Bool, capabilityExplanation: String) {
        isUpdating = status == .updating
        switch status {
        case .checkingCapability:
            message = "Checking the selected Git executable…"; warns = false
        case .updating:
            message = hasSnapshot ? "Updating the worktree list…" : "Loading worktrees…"; warns = false
        case .fresh, .closed:
            message = nil; warns = false
        case .stale:
            message = hasSnapshot ? "Worktree list may be out of date. Choose Refresh Worktrees to try again."
                : "Worktrees could not be loaded. Choose Refresh Worktrees to try again."
            warns = true
        case .unsupported:
            message = capabilityExplanation; warns = true
        }
    }
}

public enum WorktreePresentationPolicy {
    public static func consentUpdateMessage(action: String, previouslyConfirmed: Bool, updated: Bool) -> String {
        if previouslyConfirmed {
            return "The worktree state changed. Review this updated list and choose \(action) again.\n\n"
        }
        return updated ? "The worktree state changed. Review this updated list before continuing.\n\n" : ""
    }

    public static func freshnessWarning(hasSnapshot: Bool, isStale: Bool) -> String? {
        hasSnapshot && isStale ? "Worktree list may be out of date. Choose Refresh Worktrees to try again." : nil
    }

    public static func canPresent(isApplicationActive: Bool, isWindowVisible: Bool, isWindowKey: Bool,
                                  isMiniaturized: Bool, hasAttachedSheet: Bool) -> Bool
    {
        isApplicationActive && isWindowVisible && isWindowKey && !isMiniaturized && !hasAttachedSheet
    }

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

    /// An already-approved proven plan needs no further sheet. New consent always does.
    public static func canDeliverRepair(_ presentation: WorktreeRepairPresentation, hasAttachedSheet: Bool) -> Bool {
        switch presentation {
        case .perform: true
        case .reclaim, .renewed: !hasAttachedSheet
        }
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
