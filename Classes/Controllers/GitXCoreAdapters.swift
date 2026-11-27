import Foundation
import GitXCore

@objc(PBHistorySearchExecutionKind)
enum HistorySearchExecutionKind: Int {
    case clear
    case basic
    case background
    case invalid
}

@objc(PBHistorySearchPlan)
final nonisolated class HistorySearchPlan: NSObject {
    @objc let kind: HistorySearchExecutionKind
    @objc let query: String
    @objc let arguments: [String]
    /// A short status for the match-count field when `kind` is `invalid`.
    @objc let summary: String
    /// A full explanation for tooltips and VoiceOver; for background searches, the parsed argument preview.
    @objc let message: String

    init(
        kind: HistorySearchExecutionKind,
        query: String,
        arguments: [String] = [],
        summary: String = "",
        message: String = ""
    ) {
        self.kind = kind
        self.query = query
        self.arguments = arguments
        self.summary = summary
        self.message = message
        super.init()
    }
}

@objc(PBHistorySearchArgumentSyntax)
final nonisolated class HistorySearchArgumentSyntaxAdapter: NSObject { // swiftlint:disable:this unused_declaration
    /// Quotes each argument so the raw and path search tokenizer recovers it exactly.
    @objc(joinedArguments:)
    static func joined(_ arguments: [String]) -> String { // swiftlint:disable:this unused_declaration
        HistorySearchArgumentSyntax.joined(arguments)
    }
}

@objc(PBHistorySearchPolicy)
final nonisolated class HistorySearchPolicyAdapter: NSObject {
    @objc(planForQuery:mode:)
    static func plan(query: String, mode: Int) -> HistorySearchPlan {
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
            return HistorySearchPlan(
                kind: .background,
                query: query,
                arguments: arguments,
                message: "Git arguments: " + HistorySearchArgumentSyntax.preview(Array(arguments.dropFirst(3)))
            )
        case let .invalid(query, issue):
            return HistorySearchPlan(
                kind: .invalid,
                query: query,
                summary: HistorySearchArgumentSyntax.summary(for: issue),
                message: HistorySearchArgumentSyntax.message(for: issue)
            )
        }
    }
}
