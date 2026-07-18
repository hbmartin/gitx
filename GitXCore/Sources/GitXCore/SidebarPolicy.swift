import Foundation

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
