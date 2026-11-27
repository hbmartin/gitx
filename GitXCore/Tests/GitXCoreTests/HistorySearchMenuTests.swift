@testable import GitXCore
import XCTest

final class HistorySearchMenuTests: XCTestCase {
    func testWithoutRecentsTheMenuListsModesAndSaysThereAreNoRecents() {
        XCTAssertEqual(HistorySearchMenu.rows(selectedMode: .path, recents: HistorySearchRecents()), [
            .mode(.basic, isSelected: false),
            .mode(.pickaxe, isSelected: false),
            .mode(.regex, isSelected: false),
            .mode(.path, isSelected: true),
            .mode(.raw, isSelected: false),
            .separator,
            .recentSearchesHeader,
            .noRecentSearches,
        ])
    }

    func testRecentsAreListedNewestFirstWithAClearItem() {
        let newest = HistorySearchQuery(mode: .raw, text: "--all")
        let older = HistorySearchQuery(mode: .basic, text: "needle")
        let rows = HistorySearchMenu.rows(selectedMode: .basic, recents: HistorySearchRecents(queries: [newest, older]))

        XCTAssertEqual(Array(rows.prefix(1)), [.mode(.basic, isSelected: true)])
        XCTAssertEqual(Array(rows.dropFirst(5)), [
            .separator,
            .recentSearchesHeader,
            .recentSearch(index: 0, query: newest),
            .recentSearch(index: 1, query: older),
            .separator,
            .clearRecentSearches,
        ])
    }

    func testDisplayTextKeepsOneLineAndShortensLongQueries() {
        XCTAssertEqual(HistorySearchMenu.displayText(for: "  two\nlines\r\nand\ttab "), "  two lines and tab ")
        let exact = String(repeating: "x", count: HistorySearchMenu.maximumDisplayLength)
        XCTAssertEqual(HistorySearchMenu.displayText(for: exact), exact)
        let long = String(repeating: "東", count: HistorySearchMenu.maximumDisplayLength + 1)
        let shortened = HistorySearchMenu.displayText(for: long)
        XCTAssertEqual(shortened.count, HistorySearchMenu.maximumDisplayLength)
        XCTAssertTrue(shortened.hasSuffix("…"))
    }
}
