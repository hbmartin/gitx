import XCTest

final class GitXSwiftFeatureTests: XCTestCase {
    func testLanguageNameClassification() {
        XCTAssertEqual(PBHighlighting.languageName(forPath: "Dockerfile"), "dockerfile")
        XCTAssertEqual(PBHighlighting.languageName(forPath: "GNUmakefile"), "makefile")
        XCTAssertEqual(PBHighlighting.languageName(forPath: "Sources/EXAMPLE.SWIFT"), "swift")
        XCTAssertNil(PBHighlighting.languageName(forPath: "archive.unknown"))
    }

    func testRelativeDateFormatterHandlesCommonRanges() {
        let formatter = GitXRelativeDateFormatter()
        let now = Date()

        XCTAssertNil(formatter.string(for: "not a date"))
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(30)), "In the future!")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-30)), "seconds ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-90)), "1 minute ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-600)), "10 minutes ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-5400)), "1 hour ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-10800)), "3 hours ago")
    }
}
