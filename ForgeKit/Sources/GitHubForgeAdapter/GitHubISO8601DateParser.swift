import Foundation

enum GitHubISO8601DateParser {
    private static let shared = Parser()

    static func date(from value: String) -> Date? {
        shared.date(from: value)
    }

    // swift6-safety-justification: `lock` serializes formatter use; both formatters are fully initialized before publication and never mutated.
    private final class Parser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let whole: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
        }

        func date(from value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: value) ?? whole.date(from: value)
        }
    }
}
