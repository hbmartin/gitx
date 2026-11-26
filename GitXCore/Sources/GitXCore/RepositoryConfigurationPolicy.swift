import Foundation

public enum RepositoryConfigurationKey: String, CaseIterable, Sendable {
    case primaryBranch = "gitx.primaryBranch"
    case commitMessageReplacementRules = "gitx.commitMessageReplacementRules"
    case autoOpenPushedURL = "gitx.autoOpenPushedURL"
    case requirePushedURLHostMatch = "gitx.requirePushedURLHostMatch"
    case webURLTemplate = "gitx.webURLTemplate"
    case diffSuppressionPatterns = "gitx.diffSuppressionPatterns"
}

public enum RepositoryConfigurationValidationIssue: Equatable, Sendable {
    case webURLTemplateMustUseHTTPS
    case commitRuleMissingSeparator(line: Int)
    case commitRuleInvalidRegularExpression(line: Int)
    case diffSuppressionInvalidRegularExpression(line: Int)
}

/// The editable control that holds the value a validation issue refers to.
public enum RepositoryConfigurationField: String, CaseIterable, Sendable {
    case webURLTemplate
    case commitRules
    case diffSuppressionPatterns
}

public extension RepositoryConfigurationValidationIssue {
    var field: RepositoryConfigurationField {
        switch self {
        case .webURLTemplateMustUseHTTPS: .webURLTemplate
        case .commitRuleMissingSeparator, .commitRuleInvalidRegularExpression: .commitRules
        case .diffSuppressionInvalidRegularExpression: .diffSuppressionPatterns
        }
    }

    /// The 1-based line `RepositoryConfigurationPolicy.validate` reported, when the issue has one.
    var line: Int? {
        switch self {
        case .webURLTemplateMustUseHTTPS: nil
        case let .commitRuleMissingSeparator(line),
             let .commitRuleInvalidRegularExpression(line),
             let .diffSuppressionInvalidRegularExpression(line): line
        }
    }
}

public enum RepositoryConfigurationTextLines {
    /// The UTF-16 characters `CharacterSet.newlines` contains; validation numbers lines by splitting on each.
    private static let newlineUnits: Set<UInt16> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    /// The UTF-16 range of `line` (1-based) numbered exactly as validation numbers lines, so each half
    /// of a CRLF pair starts a line. Returns nil when the text has fewer lines.
    public static func characterRange(ofLine line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        var offset = 0
        for unit in text.utf16 {
            if newlineUnits.contains(unit) {
                if current == line {
                    return NSRange(location: start, length: offset - start)
                }
                current += 1
                start = offset + 1
            }
            offset += 1
        }
        return current == line ? NSRange(location: start, length: offset - start) : nil
    }
}

public enum RepositoryConfigurationPolicy {
    public static func validate(
        webURLTemplate: String,
        commitRules: String,
        diffSuppressionPatterns: String
    ) -> RepositoryConfigurationValidationIssue? {
        let template = webURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty, URL(string: template)?.scheme?.lowercased() != "https" {
            return .webURLTemplateMustUseHTTPS
        }

        for (offset, line) in commitRules.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "=>")
            guard parts.count >= 2 else {
                return .commitRuleMissingSeparator(line: offset + 1)
            }
            do {
                _ = try NSRegularExpression(pattern: parts[0].trimmingCharacters(in: .whitespaces))
            } catch {
                return .commitRuleInvalidRegularExpression(line: offset + 1)
            }
        }

        for (offset, line) in diffSuppressionPatterns.components(separatedBy: .newlines).enumerated() {
            let pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                return .diffSuppressionInvalidRegularExpression(line: offset + 1)
            }
        }
        return nil
    }

    public static func transformedCommitMessage(
        _ message: String,
        configuredRules: String
    ) throws -> String {
        var result = message
        for (offset, line) in configuredRules.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.range(of: "=>") else {
                throw CommitMessageRuleError.missingSeparator(line: offset + 1)
            }
            let pattern = trimmed[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let replacement = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            do {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: replacement
                )
            } catch {
                throw CommitMessageRuleError.invalidRegularExpression(
                    line: offset + 1,
                    description: error.localizedDescription
                )
            }
        }
        return result
    }
}

public enum RepositoryConfigurationIssuePresenter {
    public static func message(for issue: RepositoryConfigurationValidationIssue) -> String {
        switch issue {
        case .webURLTemplateMustUseHTTPS:
            "The web URL template must use HTTPS."
        case let .commitRuleMissingSeparator(line):
            "Commit message replacement rule on line \(line) must contain =>."
        case let .commitRuleInvalidRegularExpression(line):
            "Commit message replacement rule on line \(line) is not a valid regular expression."
        case let .diffSuppressionInvalidRegularExpression(line):
            "Diff suppression pattern on line \(line) is not a valid regular expression."
        }
    }
}

public enum CommitMessageRuleError: Error, Equatable, Sendable {
    case missingSeparator(line: Int)
    case invalidRegularExpression(line: Int, description: String)
}
