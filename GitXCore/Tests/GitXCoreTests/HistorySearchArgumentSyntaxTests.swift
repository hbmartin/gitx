@testable import GitXCore
import XCTest

final class HistorySearchArgumentSyntaxTests: XCTestCase {
    private func arguments(_ text: String) -> Result<[String], HistorySearchArgumentIssue> {
        HistorySearchArgumentSyntax.arguments(in: text)
    }

    func testUnquotedWhitespaceSeparatesArgumentsAndRepeatedWhitespaceIsIgnored() {
        XCTAssertEqual(arguments(""), .success([]))
        XCTAssertEqual(arguments(" \t\n "), .success([]))
        XCTAssertEqual(arguments("  one \t two\nthree  "), .success(["one", "two", "three"]))
        XCTAssertEqual(arguments("東京\u{00A0}crème"), .success(["東京", "crème"]))
    }

    func testSingleQuotesPreserveEverythingLiterally() {
        XCTAssertEqual(arguments("'a b' c"), .success(["a b", "c"]))
        XCTAssertEqual(arguments(#"'back\slash "double"'"#), .success([#"back\slash "double""#]))
        XCTAssertEqual(arguments("pre'fix mid'post"), .success(["prefix midpost"]))
    }

    func testDoubleQuotesEscapeOnlyDoubleQuoteAndBackslash() {
        XCTAssertEqual(arguments(#""a b" c"#), .success(["a b", "c"]))
        XCTAssertEqual(arguments(#""say \"hi\" \\ \n""#), .success([#"say "hi" \ \n"#]))
        XCTAssertEqual(arguments(#""it's""#), .success(["it's"]))
        XCTAssertEqual(arguments(#""trailing\"#), .failure(.unclosedQuote("\"")))
    }

    func testUnquotedBackslashEscapesOnlyWhitespaceQuotesAndBackslash() {
        XCTAssertEqual(arguments(#"path\ with\ spaces.txt"#), .success(["path with spaces.txt"]))
        XCTAssertEqual(arguments(#"don\'t \"x\" a\\b"#), .success(["don't", "\"x\"", #"a\b"#]))
        XCTAssertEqual(arguments(#"--grep=a\.b"#), .success([#"--grep=a\.b"#]))
        XCTAssertEqual(arguments(#"trailing\"#), .success([#"trailing\"#]))
    }

    func testMalformedQuotingAndEmptyArgumentsAreReported() {
        XCTAssertEqual(arguments("don't"), .failure(.unclosedQuote("'")))
        XCTAssertEqual(arguments(#"open "quote"#), .failure(.unclosedQuote("\"")))
        XCTAssertEqual(arguments("''"), .failure(.emptyArgument(index: 0)))
        XCTAssertEqual(arguments(#"a "" b"#), .failure(.emptyArgument(index: 1)))
    }

    func testQuotedAndJoinedRoundTripThroughTheParser() {
        let corpus = [
            "plain",
            "with space",
            "tab\there",
            "it's",
            #"say "hi""#,
            #"back\slash"#,
            "東京 crème",
            "--author=GitX Tests",
            "nested/tracked.txt",
        ]

        XCTAssertEqual(HistorySearchArgumentSyntax.quoted("plain"), "plain")
        XCTAssertEqual(HistorySearchArgumentSyntax.quoted("with space"), "'with space'")
        XCTAssertEqual(HistorySearchArgumentSyntax.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(HistorySearchArgumentSyntax.quoted(""), "''")
        for argument in corpus {
            XCTAssertEqual(arguments(HistorySearchArgumentSyntax.quoted(argument)), .success([argument]), argument)
        }
        XCTAssertEqual(arguments(HistorySearchArgumentSyntax.joined(corpus)), .success(corpus))
        XCTAssertEqual(HistorySearchArgumentSyntax.joined([]), "")
    }

    func testPreviewSummaryAndMessageDescribeArgumentsAndIssues() {
        XCTAssertEqual(HistorySearchArgumentSyntax.preview(["--", "a b", ""]), "[--] [a b] []")
        XCTAssertEqual(HistorySearchArgumentSyntax.summary(for: .unclosedQuote("'")), "Unclosed quote")
        XCTAssertEqual(HistorySearchArgumentSyntax.summary(for: .emptyArgument(index: 0)), "Empty argument")
        XCTAssertEqual(
            HistorySearchArgumentSyntax.message(for: .unclosedQuote("'")),
            "Close the single quote or escape it with a backslash."
        )
        XCTAssertEqual(
            HistorySearchArgumentSyntax.message(for: .unclosedQuote("\"")),
            "Close the double quote or escape it with a backslash."
        )
        XCTAssertEqual(
            HistorySearchArgumentSyntax.message(for: .emptyArgument(index: 2)),
            "Argument 3 is empty. Remove the empty quotes."
        )
    }
}
