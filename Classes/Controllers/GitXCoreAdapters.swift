import Foundation
import GitXCore

@objc(PBHistorySearchExecutionKind)
enum HistorySearchExecutionKind: Int {
    case clear
    case basic
    case background
}

@objc(PBHistorySearchPlan)
final nonisolated class HistorySearchPlan: NSObject {
    @objc let kind: HistorySearchExecutionKind
    @objc let query: String
    @objc let arguments: [String]

    init(kind: HistorySearchExecutionKind, query: String, arguments: [String] = []) {
        self.kind = kind
        self.query = query
        self.arguments = arguments
        super.init()
    }
}

@objc(PBHistorySearchPolicy)
final nonisolated class HistorySearchPolicyAdapter: NSObject { // swiftlint:disable:this unused_declaration
    @objc(planForQuery:mode:)
    static func plan(query: String, mode: Int) -> HistorySearchPlan { // swiftlint:disable:this unused_declaration
        let execution = GitXCore.HistorySearchPolicy.execution(
            query: query,
            mode: GitXCore.HistorySearchPolicy.validatedMode(rawValue: mode)
        )
        switch execution {
        case .clear:
            return HistorySearchPlan(kind: .clear, query: "")
        case let .basic(query):
            return HistorySearchPlan(kind: .basic, query: query)
        case let .background(query, arguments):
            return HistorySearchPlan(kind: .background, query: query, arguments: arguments)
        }
    }
}

@objc(PBSidebarRevisionPlacement)
enum SidebarRevisionPlacementAdapter: Int {
    case other
    case branchRoot
    case branchPath
    case tagPath
    case remotePath
    case hidden
    case unsupported
}

@objc(PBSidebarRevisionPlan)
final nonisolated class SidebarRevisionPlanAdapter: NSObject {
    @objc let placement: SidebarRevisionPlacementAdapter
    @objc let path: [String]

    init(plan: GitXCore.SidebarRevisionPlan) {
        placement = switch plan.placement {
        case .other: .other
        case .branchRoot: .branchRoot
        case .branchPath: .branchPath
        case .tagPath: .tagPath
        case .remotePath: .remotePath
        case .hidden: .hidden
        case .unsupported: .unsupported
        }
        path = plan.path
        super.init()
    }
}

@objc(PBSidebarRevisionPolicy)
final nonisolated class SidebarRevisionPolicyAdapter: NSObject { // swiftlint:disable:this unused_declaration
    @objc(planForSimpleReference:shouldShowBranch:usesRecentBranchSorting:)
    // swiftlint:disable:next unused_declaration
    static func plan(
        simpleReference: String?,
        shouldShowBranch: Bool,
        usesRecentBranchSorting: Bool
    ) -> SidebarRevisionPlanAdapter {
        SidebarRevisionPlanAdapter(plan: GitXCore.SidebarRevisionPolicy.plan(
            simpleReference: simpleReference,
            shouldShowBranch: shouldShowBranch,
            usesRecentBranchSorting: usesRecentBranchSorting
        ))
    }
}
