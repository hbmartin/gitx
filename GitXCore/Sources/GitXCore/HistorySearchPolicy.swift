import Foundation

public enum HistorySearchMode: Int, CaseIterable, Sendable {
    case basic = 1
    case pickaxe
    case regex
    case path
    case raw
}

public enum HistorySearchExecution: Equatable, Sendable {
    case clear
    case basic(query: String)
    case background(query: String, arguments: [String])
    /// Raw or path text that cannot be split into Git arguments; no search runs.
    case invalid(query: String, issue: HistorySearchArgumentIssue)
}

public enum HistorySearchPolicy {
    public static func validatedMode(rawValue: Int) -> HistorySearchMode {
        HistorySearchMode(rawValue: rawValue) ?? .basic
    }

    public static func execution(query: String, mode: HistorySearchMode) -> HistorySearchExecution {
        switch mode {
        case .basic:
            return query.isEmpty ? .clear : .basic(query: query)
        case .pickaxe, .regex, .path, .raw:
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return .clear }
            var arguments = ["log", "--pretty=format:%H", "--no-textconv"]
            switch mode {
            case .regex:
                arguments.append("--pickaxe-regex")
                arguments.append("-S\(normalized)")
            case .pickaxe:
                arguments.append("-S\(normalized)")
            default:
                switch HistorySearchArgumentSyntax.arguments(in: query) {
                case let .success(parsed):
                    if mode == .path {
                        arguments.append("--")
                    }
                    arguments.append(contentsOf: parsed)
                case let .failure(issue):
                    return .invalid(query: normalized, issue: issue)
                }
            }
            return .background(query: normalized, arguments: arguments)
        }
    }
}
