@testable import GitXCore
import XCTest

final class RelativeDatePolicyTests: XCTestCase {
    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    func testSubHourThresholdsRoundElapsedSecondsHalfAwayFromZero() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2024, 6, 15, 20)
        let cases: [(TimeInterval, RelativeDate)] = [
            (-0.5, .future),
            (-0.4, .seconds),
            (0, .seconds),
            (59.4, .seconds),
            (59.5, .minutes(1)),
            (119.4, .minutes(1)),
            (119.5, .minutes(2)),
            (3599.4, .minutes(59)),
            (3599.5, .hours(1)),
            (7199.4, .hours(1)),
            (7199.5, .hours(2)),
        ]

        for (secondsAgo, expected) in cases {
            XCTAssertEqual(
                RelativeDatePolicy.classify(now.addingTimeInterval(-secondsAgo), now: now, calendar: utc),
                expected,
                "\(secondsAgo) seconds ago"
            )
        }
    }

    func testHoursYesterdayAndDaysUseCalendarDaysAndTheSixHourGrace() throws {
        let utc = try calendar("UTC")
        let evening = try date(utc, 2024, 6, 15, 20)
        let earlyMorning = try date(utc, 2024, 6, 15, 3)

        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 15, 8), now: evening, calendar: utc), .hours(12))
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 14, 22), now: evening, calendar: utc), .yesterday)
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 14, 23), now: earlyMorning, calendar: utc), .hours(4))
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 14, 20), now: earlyMorning, calendar: utc), .yesterday)
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 12), now: evening, calendar: utc), .days(3))
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 2), now: evening, calendar: utc), .days(13))
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 6, 1), now: evening, calendar: utc), .weeks(2))
        XCTAssertEqual(try RelativeDatePolicy.classify(date(utc, 2024, 5, 25), now: evening, calendar: utc), .weeks(3))
    }

    func testMonthsAndYearsFollowCalendarComponents() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2024, 6, 15, 20)
        let cases: [(Date, RelativeDate)] = try [
            (date(utc, 2024, 5, 15), .months(1)),
            (date(utc, 2024, 3, 10), .months(3)),
            (date(utc, 2023, 6, 15), .years(1, months: 0)),
            (date(utc, 2023, 5, 15), .years(1, months: 1)),
            (date(utc, 2023, 2, 1), .years(1, months: 4)),
            (date(utc, 2021, 1, 1), .years(3, months: 0)),
        ]

        for (date, expected) in cases {
            XCTAssertEqual(RelativeDatePolicy.classify(date, now: now, calendar: utc), expected, "\(date)")
        }
    }

    func testMonthEndsLeapDaysAndYearRollover() throws {
        let utc = try calendar("UTC")

        XCTAssertEqual(
            try RelativeDatePolicy.classify(date(utc, 2024, 2, 29), now: date(utc, 2024, 3, 31), calendar: utc),
            .months(1)
        )
        XCTAssertEqual(
            try RelativeDatePolicy.classify(date(utc, 2023, 2, 28), now: date(utc, 2024, 2, 29), calendar: utc),
            .years(1, months: 0)
        )
        XCTAssertEqual(
            try RelativeDatePolicy.classify(date(utc, 2024, 12, 31, 20), now: date(utc, 2025, 1, 1, 9), calendar: utc),
            .yesterday
        )
    }

    func testCalendarTimeZoneDecidesWhichDayAnInstantBelongsTo() throws {
        let utc = try calendar("UTC")
        let losAngeles = try calendar("America/Los_Angeles")
        let now = try date(utc, 2024, 6, 15, 5)
        let sevenHoursEarlier = try date(utc, 2024, 6, 14, 22)

        XCTAssertEqual(RelativeDatePolicy.classify(sevenHoursEarlier, now: now, calendar: utc), .yesterday)
        XCTAssertEqual(RelativeDatePolicy.classify(sevenHoursEarlier, now: now, calendar: losAngeles), .hours(7))
    }

    func testMissingLocalMidnightUsesTheFirstMomentOfTheDay() throws {
        let havana = try calendar("America/Havana")
        let now = try date(havana, 2024, 3, 10, 12)

        XCTAssertEqual(try RelativeDatePolicy.classify(date(havana, 2024, 3, 9, 12), now: now, calendar: havana), .yesterday)
        XCTAssertEqual(try RelativeDatePolicy.classify(date(havana, 2024, 3, 10, 1, 30), now: now, calendar: havana), .hours(10))
    }

    func testUnrepresentableIntervalsDoNotTrap() throws {
        let utc = try calendar("UTC")
        let now = try date(utc, 2024, 6, 15)

        XCTAssertEqual(
            RelativeDatePolicy.classify(Date(timeIntervalSinceReferenceDate: .nan), now: now, calendar: utc),
            .seconds
        )
        XCTAssertEqual(
            RelativeDatePolicy.classify(Date(timeIntervalSinceReferenceDate: 1e19), now: now, calendar: utc),
            .future
        )
    }

    func testEnglishDescriptionsMatchTheHistoricalFormatterStrings() throws {
        let cases: [(RelativeDate, String)] = [
            (.future, "In the future!"),
            (.seconds, "seconds ago"),
            (.minutes(1), "1 minute ago"),
            (.minutes(42), "42 minutes ago"),
            (.hours(1), "1 hour ago"),
            (.hours(5), "5 hours ago"),
            (.yesterday, "Yesterday"),
            (.days(3), "3 days ago"),
            (.weeks(2), "2 weeks ago"),
            (.months(1), "1 month ago"),
            (.months(7), "7 months ago"),
            (.years(1, months: 0), "1 year ago"),
            (.years(1, months: 1), "1 year 1 month ago"),
            (.years(1, months: 4), "1 year 4 months ago"),
            (.years(6, months: 0), "6 years ago"),
        ]

        for (value, expected) in cases {
            XCTAssertEqual(RelativeDatePolicy.englishDescription(value), expected)
        }

        let utc = try calendar("UTC")
        let now = try date(utc, 2024, 6, 15)
        XCTAssertEqual(
            RelativeDatePolicy.englishDescription(of: now.addingTimeInterval(-600), now: now, calendar: utc),
            "10 minutes ago"
        )
    }
}
