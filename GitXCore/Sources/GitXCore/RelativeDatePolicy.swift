import Foundation

/// A calendar-aware description of how long ago a date occurred, relative to a reference `now`.
public enum RelativeDate: Equatable, Sendable {
    case future
    case seconds
    case minutes(Int)
    case hours(Int)
    case yesterday
    case days(Int)
    case weeks(Int)
    case months(Int)
    /// `months` is only meaningful when `years == 1`; it is normalized to zero otherwise.
    case years(Int, months: Int)
}

public enum RelativeDatePolicy {
    private static let minute = 60
    private static let hour = 60 * minute
    private static let daysPerWeek = 7
    /// Elapsed seconds are clamped far beyond any representable commit date so rounding never traps.
    private static let secondsLimit: TimeInterval = 1e18

    /// Classifies `date` relative to `now`.
    ///
    /// Elapsed seconds round half away from zero. Day, month, and year distances compare the
    /// calendar days that contain each instant in `calendar`'s time zone, so "Yesterday" means the
    /// previous calendar day rather than 24 hours ago. A date earlier today, or less than six hours
    /// ago, is described in hours.
    public static func classify(_ date: Date, now: Date, calendar: Calendar) -> RelativeDate {
        let interval = now.timeIntervalSince(date)
        let secondsAgo = interval.isNaN ? 0 : Int(min(max(interval.rounded(), -secondsLimit), secondsLimit))

        if secondsAgo < 0 {
            return .future
        }
        if secondsAgo < minute {
            return .seconds
        }
        if secondsAgo < hour {
            return .minutes(secondsAgo / minute)
        }
        if secondsAgo < 2 * hour {
            return .hours(1)
        }

        // Every requested unit is present, so the bridged non-optional accessors are exact.
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ) as NSDateComponents
        let yearsAgo = components.year
        let monthsAgo = components.month
        let daysAgo = components.day

        if yearsAgo == 0 {
            if monthsAgo == 0 {
                if daysAgo == 0 || secondsAgo < 6 * hour {
                    return .hours(secondsAgo / hour)
                }
                if daysAgo == 1 {
                    return .yesterday
                }
                if daysAgo >= 2 * daysPerWeek {
                    return .weeks(daysAgo / daysPerWeek)
                }
                return .days(daysAgo)
            }
            return .months(monthsAgo)
        }
        if yearsAgo == 1 {
            return .years(1, months: monthsAgo)
        }
        return .years(yearsAgo, months: 0)
    }

    public static func englishDescription(_ value: RelativeDate) -> String {
        switch value {
        case .future:
            "In the future!"
        case .seconds:
            "seconds ago"
        case let .minutes(count):
            count == 1 ? "1 minute ago" : "\(count) minutes ago"
        case let .hours(count):
            count == 1 ? "1 hour ago" : "\(count) hours ago"
        case .yesterday:
            "Yesterday"
        case let .days(count):
            "\(count) days ago"
        case let .weeks(count):
            "\(count) weeks ago"
        case let .months(count):
            count == 1 ? "1 month ago" : "\(count) months ago"
        case let .years(count, months):
            yearsDescription(count, months: months)
        }
    }

    public static func englishDescription(of date: Date, now: Date, calendar: Calendar) -> String {
        englishDescription(classify(date, now: now, calendar: calendar))
    }

    private static func yearsDescription(_ count: Int, months: Int) -> String {
        guard count == 1 else { return "\(count) years ago" }
        switch months {
        case 0: return "1 year ago"
        case 1: return "1 year 1 month ago"
        default: return "1 year \(months) months ago"
        }
    }
}
