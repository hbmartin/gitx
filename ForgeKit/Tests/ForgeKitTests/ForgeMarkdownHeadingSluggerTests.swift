@testable import ForgeKit
import XCTest

final class ForgeMarkdownHeadingSluggerTests: XCTestCase {
    func testGitHubCompatiblePunctuationWhitespaceUnicodeAndDuplicateSlugs() {
        var slugger = ForgeMarkdownHeadingSlugger()
        let headings = [
            "Hello, World!",
            "Hello World",
            "Hello World-1-1",
            "Hello-World-1",
            "Café déjà vu",
            "A  B",
            "under_score-and-hyphen",
            "emoji 😄",
            "tab\tcontrol\u{7} © symbol",
            "non\u{a0}breaking",
            "e\u{301}lan ‿ connector",
            "Unicode 15 letters: \u{1c89}\u{1c8a} \u{105c0}",
            "!!!",
            "???",
        ]
        XCTAssertEqual(
            headings.map { slugger.identifier(for: $0).rawValue },
            [
                "hello-world",
                "hello-world-1",
                "hello-world-1-1",
                "hello-world-1-2",
                "café-déjà-vu",
                "a--b",
                "under_score-and-hyphen",
                "emoji-",
                "tabcontrol--symbol",
                "nonbreaking",
                "élan-‿-connector",
                "unicode-15-letters--",
                "",
                "-1",
            ]
        )
    }
}
