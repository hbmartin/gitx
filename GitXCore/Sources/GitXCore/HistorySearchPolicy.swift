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
            if mode == .regex {
                arguments.append("--pickaxe-regex")
                arguments.append("-S\(normalized)")
            } else if mode == .pickaxe {
                arguments.append("-S\(normalized)")
            } else if mode == .path {
                arguments.append("--")
                arguments.append(contentsOf: components(in: normalized))
            } else {
                arguments.append(contentsOf: components(in: normalized))
            }
            return .background(query: normalized, arguments: arguments)
        }
    }

    private static func components(in query: String) -> [String] {
        query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
}
