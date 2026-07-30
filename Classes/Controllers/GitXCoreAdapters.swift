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
