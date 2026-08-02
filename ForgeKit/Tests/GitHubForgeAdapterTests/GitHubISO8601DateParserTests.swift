import Foundation
@testable import GitHubForgeAdapter
import XCTest

final class GitHubISO8601DateParserTests: XCTestCase {
    func testMatchesThePreviousAdapterParsingContract() {
        let values = [
            "2026-07-29T12:34:56Z",
            "2026-07-29T12:34:56.1Z",
            "2026-07-29T12:34:56.123456Z",
            "2026-07-29T15:04:56+02:30",
            "2026-07-29T15:04:56.123+02:30",
            "",
            "not-a-date",
            "2026-07-29",
            "2026-07-29T12:34:56",
        ]

        for value in values {
            XCTAssertEqual(GitHubISO8601DateParser.date(from: value), legacyDate(from: value), value)
        }
    }

    func testParsesWholeFractionalAndOffsetInternetDates() throws {
        let whole = try XCTUnwrap(GitHubISO8601DateParser.date(from: "2026-07-29T12:34:56Z"))
        let fractional = try XCTUnwrap(GitHubISO8601DateParser.date(from: "2026-07-29T12:34:56.123Z"))
        let offset = try XCTUnwrap(GitHubISO8601DateParser.date(from: "2026-07-29T15:04:56+02:30"))

        XCTAssertEqual(whole.timeIntervalSince1970, 1_785_328_496, accuracy: 0.001)
        XCTAssertEqual(fractional.timeIntervalSince1970, 1_785_328_496.123, accuracy: 0.001)
        XCTAssertEqual(offset, whole)
    }

    func testRejectsValuesRejectedByTheAdapterContract() {
        for value in ["", "not-a-date", "2026-07-29", "2026-07-29T12:34:56"] {
            XCTAssertNil(GitHubISO8601DateParser.date(from: value), value)
        }
    }

    func testConcurrentParsingRemainsDeterministic() async {
        let values = [
            "2026-07-29T12:34:56Z",
            "2026-07-29T12:34:56.123Z",
            "2026-07-29T15:04:56+02:30",
            "not-a-date",
        ]
        let expected = values.map(GitHubISO8601DateParser.date(from:))

        let allMatched = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    for _ in 0 ..< 50 where values.map(GitHubISO8601DateParser.date(from:)) != expected {
                        return false
                    }
                    return true
                }
            }
            return await group.reduce(true) { $0 && $1 }
        }

        XCTAssertTrue(allMatched)
    }

    private func legacyDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }
}
