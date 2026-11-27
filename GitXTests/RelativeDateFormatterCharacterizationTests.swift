@testable import GitX
import XCTest

/// Characterizes the history list's relative-date column formatter through the real clock.
///
/// Dates are built with calendar arithmetic that preserves wall-clock time and stay well away
/// from every threshold, so the assertions hold whenever the suite runs.
final class RelativeDateFormatterCharacterizationTests: XCTestCase {
    private let formatter = GitX.GitXRelativeDateFormatter()

    private func describe(_ date: Date) -> String? {
        formatter.string(for: date)
    }

    private func date(adding components: DateComponents, to now: Date = Date()) throws -> Date {
        try XCTUnwrap(Calendar.current.date(byAdding: components, to: now))
    }

    func testNonDateValuesProduceNoString() {
        XCTAssertNil(formatter.string(for: nil))
        XCTAssertNil(formatter.string(for: "2024-06-15"))
        XCTAssertNil(formatter.string(for: 1_718_409_600))
    }

    func testElapsedSecondsRoundHalfAwayFromZeroBeforeClassification() {
        let now = Date()

        XCTAssertEqual(describe(now.addingTimeInterval(0.4)), "seconds ago")
        XCTAssertEqual(describe(now.addingTimeInterval(30)), "In the future!")
        XCTAssertEqual(describe(now.addingTimeInterval(-59.6)), "1 minute ago")
        XCTAssertEqual(describe(now.addingTimeInterval(-150)), "2 minutes ago")
        XCTAssertEqual(describe(now.addingTimeInterval(-3000)), "50 minutes ago")
        XCTAssertEqual(describe(now.addingTimeInterval(-4000)), "1 hour ago")
        XCTAssertEqual(describe(now.addingTimeInterval(-3 * 3600 - 600)), "3 hours ago")
    }

    func testCalendarDayDistancesProduceYesterdayDaysAndWeeks() throws {
        XCTAssertEqual(try describe(date(adding: DateComponents(day: -1))), "Yesterday")
        XCTAssertEqual(try describe(date(adding: DateComponents(day: -3))), "3 days ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(day: -13))), "13 days ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(day: -15))), "2 weeks ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(day: -22))), "3 weeks ago")
    }

    func testCalendarMonthAndYearDistances() throws {
        XCTAssertEqual(try describe(date(adding: DateComponents(month: -1))), "1 month ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(month: -3))), "3 months ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(year: -1))), "1 year ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(year: -1, month: -1))), "1 year 1 month ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(year: -1, month: -4))), "1 year 4 months ago")
        XCTAssertEqual(try describe(date(adding: DateComponents(year: -3))), "3 years ago")
    }

    func testInjectedClockAndCalendarDecideCalendarDayDistances() throws {
        let formatter = GitX.GitXRelativeDateFormatter()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 1)))
        formatter.now = { now }
        formatter.calendar = utc

        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-2 * 3600)), "2 hours ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-6 * 3600)), "Yesterday")

        var tokyo = utc
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        formatter.calendar = tokyo
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-6 * 3600)), "6 hours ago")
        XCTAssertEqual(GitX.GitXRelativeDateFormatter().calendar, Calendar.autoupdatingCurrent)
    }
}
