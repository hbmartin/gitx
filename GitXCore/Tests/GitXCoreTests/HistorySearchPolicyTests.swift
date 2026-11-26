@testable import GitXCore
import XCTest

final class HistorySearchPolicyTests: XCTestCase {
    func testHistorySearchModeValidationAndClearBoundaries() {
        XCTAssertEqual(HistorySearchPolicy.validatedMode(rawValue: 3), .regex)
        XCTAssertEqual(HistorySearchPolicy.validatedMode(rawValue: 99), .basic)
        XCTAssertEqual(HistorySearchPolicy.execution(query: "", mode: .basic), .clear)
        XCTAssertEqual(HistorySearchPolicy.execution(query: " \n ", mode: .path), .clear)
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: " subject ", mode: .basic),
            .basic(query: " subject ")
        )
    }

    func testHistorySearchBuildsExistingGitArguments() {
        let cases: [(HistorySearchMode, [String])] = [
            (.pickaxe, ["log", "--pretty=format:%H", "--no-textconv", "-Sneedle"]),
            (.regex, ["log", "--pretty=format:%H", "--no-textconv", "--pickaxe-regex", "-Sneedle"]),
            (.path, ["log", "--pretty=format:%H", "--no-textconv", "--", "needle"]),
            (.raw, ["log", "--pretty=format:%H", "--no-textconv", "needle"]),
        ]

        for (mode, expected) in cases {
            XCTAssertEqual(
                HistorySearchPolicy.execution(query: " needle\n", mode: mode),
                .background(query: "needle", arguments: expected)
            )
        }
    }

    func testHistorySearchNormalizesRepeatedWhitespaceComponents() {
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: "one  two", mode: .path),
            .background(
                query: "one  two",
                arguments: ["log", "--pretty=format:%H", "--no-textconv", "--", "one", "two"]
            )
        )
    }

    func testRawAndPathSearchesHonorQuotingAndRejectMalformedArguments() {
        let prefix = ["log", "--pretty=format:%H", "--no-textconv"]
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: #" "dir name/file's.txt" other "#, mode: .path),
            .background(
                query: #""dir name/file's.txt" other"#,
                arguments: prefix + ["--", "dir name/file's.txt", "other"]
            )
        )
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: "--author='GitX Tests' --grep=a\\.b", mode: .raw),
            .background(
                query: "--author='GitX Tests' --grep=a\\.b",
                arguments: prefix + ["--author=GitX Tests", "--grep=a\\.b"]
            )
        )
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: " don't ", mode: .path),
            .invalid(query: "don't", issue: .unclosedQuote("'"))
        )
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: "--all ''", mode: .raw),
            .invalid(query: "--all ''", issue: .emptyArgument(index: 1))
        )
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: "don't", mode: .pickaxe),
            .background(query: "don't", arguments: prefix + ["-Sdon't"])
        )
    }
}
