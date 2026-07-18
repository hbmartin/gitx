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
            "Commit message replacement rule 3 is not a valid regular expression."
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
}
