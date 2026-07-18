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

    func testHistorySearchPreservesWhitespaceComponentBehavior() {
        XCTAssertEqual(
            HistorySearchPolicy.execution(query: "one  two", mode: .path),
            .background(
                query: "one  two",
                arguments: ["log", "--pretty=format:%H", "--no-textconv", "--", "one", "", "two"]
            )
        )
    }
}
