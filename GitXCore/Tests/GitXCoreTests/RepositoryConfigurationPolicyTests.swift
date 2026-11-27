@testable import GitXCore
import XCTest

final class RepositoryConfigurationPolicyTests: XCTestCase {
    func testRepositoryConfigurationValidationReportsFirstIssue() {
        XCTAssertEqual(RepositoryConfigurationPolicy.validate(
            webURLTemplate: "http://example.invalid/{branch}",
            commitRules: "subject => replacement",
            diffSuppressionPatterns: ".*\\.lock"
        ), .webURLTemplateMustUseHTTPS)
        XCTAssertEqual(RepositoryConfigurationPolicy.validate(
            webURLTemplate: "",
            commitRules: "missing separator",
            diffSuppressionPatterns: ""
        ), .commitRuleMissingSeparator(line: 1))
        XCTAssertEqual(RepositoryConfigurationPolicy.validate(
            webURLTemplate: "",
            commitRules: "[ => replacement",
            diffSuppressionPatterns: ""
        ), .commitRuleInvalidRegularExpression(line: 1))
        XCTAssertEqual(RepositoryConfigurationPolicy.validate(
            webURLTemplate: "",
            commitRules: "# comment\n",
            diffSuppressionPatterns: "# comment\n["
        ), .diffSuppressionInvalidRegularExpression(line: 2))
        XCTAssertNil(RepositoryConfigurationPolicy.validate(
            webURLTemplate: "https://example.invalid/{branch}",
            commitRules: "(?i)bug (\\d+) => Fixes #$1",
            diffSuppressionPatterns: ".*\\.lock"
        ))
    }

    func testRepositoryConfigurationIssueMessagesPreserveLineNumbers() {
        XCTAssertEqual(
            RepositoryConfigurationIssuePresenter.message(for: .commitRuleMissingSeparator(line: 7)),
            "Commit message replacement rule on line 7 must contain =>."
        )
        XCTAssertEqual(
            RepositoryConfigurationIssuePresenter.message(for: .commitRuleInvalidRegularExpression(line: 3)),
            "Commit message replacement rule on line 3 is not a valid regular expression."
        )
        XCTAssertEqual(
            RepositoryConfigurationIssuePresenter.message(for: .diffSuppressionInvalidRegularExpression(line: 5)),
            "Diff suppression pattern on line 5 is not a valid regular expression."
        )
        XCTAssertEqual(
            RepositoryConfigurationIssuePresenter.message(for: .webURLTemplateMustUseHTTPS),
            "The web URL template must use HTTPS."
        )
    }

    func testCommitMessageRulesTransformInOrderAndIgnoreComments() throws {
        let transformed = try RepositoryConfigurationPolicy.transformedCommitMessage(
            "bug 42 draft",
            configuredRules: "# normalize\n(?i)bug (\\d+) => Fixes #$1\ndraft => ready"
        )
        XCTAssertEqual(transformed, "Fixes #42 ready")
    }

    func testCommitMessageRulesReportLineAndRegularExpressionErrors() {
        XCTAssertThrowsError(try RepositoryConfigurationPolicy.transformedCommitMessage(
            "subject",
            configuredRules: "# comment\ninvalid"
        )) { error in
            XCTAssertEqual(error as? CommitMessageRuleError, .missingSeparator(line: 2))
        }
        XCTAssertThrowsError(try RepositoryConfigurationPolicy.transformedCommitMessage(
            "subject",
            configuredRules: "[ => replacement"
        )) { error in
            guard case let .invalidRegularExpression(line, _) = error as? CommitMessageRuleError else {
                return XCTFail("Expected invalid regular expression")
            }
            XCTAssertEqual(line, 1)
        }
    }

    func testValidationIssuesIdentifyTheirFieldAndLine() {
        let cases: [(RepositoryConfigurationValidationIssue, RepositoryConfigurationField, Int?)] = [
            (.webURLTemplateMustUseHTTPS, .webURLTemplate, nil),
            (.commitRuleMissingSeparator(line: 2), .commitRules, 2),
            (.commitRuleInvalidRegularExpression(line: 3), .commitRules, 3),
            (.diffSuppressionInvalidRegularExpression(line: 4), .diffSuppressionPatterns, 4),
        ]
        for (issue, field, line) in cases {
            XCTAssertEqual(issue.field, field)
            XCTAssertEqual(issue.line, line)
        }
        XCTAssertEqual(RepositoryConfigurationField.allCases.count, 3)
    }

    func testCharacterRangeNumbersLinesExactlyAsValidationDoes() {
        let text = "a\nb\r\nc"
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 1, in: text), NSRange(location: 0, length: 1))
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 2, in: text), NSRange(location: 2, length: 1))
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 3, in: text), NSRange(location: 4, length: 0))
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 4, in: text), NSRange(location: 5, length: 1))
        XCTAssertNil(RepositoryConfigurationTextLines.characterRange(ofLine: 5, in: text))
        XCTAssertNil(RepositoryConfigurationTextLines.characterRange(ofLine: 0, in: text))
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 1, in: ""), NSRange(location: 0, length: 0))

        let rules = "\u{1F600}x => y\nbad("
        XCTAssertEqual(
            RepositoryConfigurationPolicy.validate(webURLTemplate: "", commitRules: rules, diffSuppressionPatterns: ""),
            .commitRuleMissingSeparator(line: 2)
        )
        XCTAssertEqual(RepositoryConfigurationTextLines.characterRange(ofLine: 2, in: rules), NSRange(location: 9, length: 4))
        let crlf = "a => b\r\nbad("
        XCTAssertEqual(
            RepositoryConfigurationPolicy.validate(webURLTemplate: "", commitRules: crlf, diffSuppressionPatterns: ""),
            .commitRuleMissingSeparator(line: 3)
        )
        XCTAssertEqual(
            (crlf as NSString).substring(with: RepositoryConfigurationTextLines.characterRange(ofLine: 3, in: crlf) ?? NSRange()),
            "bad("
        )
    }
}
