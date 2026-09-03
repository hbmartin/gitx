import Foundation

/// A framework-neutral view of one analysis diagnostic.
public struct HistoryFlowDiagnosticInput: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case information
        case warning
        case error
    }

    public let severity: Severity
    public let path: String?
    public let message: String

    public init(severity: Severity, path: String?, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

/// The user-facing explanation of an analysis that finished with problems.
public struct HistoryFlowDiagnosticsSummary: Equatable, Sendable {
    /// One sentence counting the problems, for example
    /// "Flow analysis is incomplete: 1 error and 2 warnings."
    public let headline: String
    /// Up to `maximumDetails` "path: message" lines, most severe first.
    public let details: [String]
    /// How many further problems `details` leaves out.
    public let omittedCount: Int

    /// Returns `nil` when nothing is worth telling the user, so a clean
    /// analysis shows no banner at all.
    public static func make(
        from diagnostics: [HistoryFlowDiagnosticInput],
        maximumDetails: Int = 3
    ) -> HistoryFlowDiagnosticsSummary? {
        let reportable = diagnostics.filter { $0.severity != .information }
        guard !reportable.isEmpty else { return nil }

        let errorCount = reportable.count { $0.severity == .error }
        let warningCount = reportable.count - errorCount
        var counts: [String] = []
        if errorCount > 0 {
            counts.append(errorCount == 1 ? "1 error" : "\(errorCount) errors")
        }
        if warningCount > 0 {
            counts.append(warningCount == 1 ? "1 warning" : "\(warningCount) warnings")
        }
        let headline = "Flow analysis is incomplete: \(counts.joined(separator: " and "))."

        let ordered = reportable.filter { $0.severity == .error } + reportable.filter { $0.severity == .warning }
        let details = ordered.prefix(max(0, maximumDetails)).map { diagnostic in
            if let path = diagnostic.path, !path.isEmpty {
                return "\(path): \(diagnostic.message)"
            }
            return diagnostic.message
        }
        return HistoryFlowDiagnosticsSummary(
            headline: headline,
            details: details,
            omittedCount: ordered.count - details.count
        )
    }
}
