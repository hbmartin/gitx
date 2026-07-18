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

public enum CommitMessageRuleError: Error, Equatable, Sendable {
    case missingSeparator(line: Int)
    case invalidRegularExpression(line: Int, description: String)
}
