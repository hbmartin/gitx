@testable import GitXCore
import XCTest

final class HistorySearchMenuTests: XCTestCase {
    func testWithoutRecentsTheMenuListsModesAndSaysThereAreNoRecents() {
        XCTAssertEqual(HistorySearchMenu.rows(selectedMode: .path, library: SavedHistorySearchLibrary(), recents: HistorySearchRecents()), [
            .mode(.basic, isSelected: false),
            .mode(.pickaxe, isSelected: false),
            .mode(.regex, isSelected: false),
            .mode(.path, isSelected: true),
            .mode(.raw, isSelected: false),
            .separator,
            .savedSearchesHeader,
            .noSavedSearches,
            .saveSearchAs,
            .manageSavedSearches,
            .separator,
            .recentSearchesHeader,
            .noRecentSearches,
        ])
    }

    func testSavedSearchesAreListedByNameBeforeTheSaveAndManageItems() throws {
        var library = SavedHistorySearchLibrary()
        let zebra = try library.save(name: "Zebra", query: HistorySearchQuery(mode: .path, text: "docs/")).get()
        let ada = try library.save(name: "Ada", query: HistorySearchQuery(mode: .raw, text: "--author=Ada")).get()
        let rows = HistorySearchMenu.rows(selectedMode: .basic, library: library, recents: HistorySearchRecents())

        XCTAssertEqual(Array(rows[5 ..< 11]), [
            .separator,
            .savedSearchesHeader,
            .savedSearch(ada),
            .savedSearch(zebra),
            .saveSearchAs,
            .manageSavedSearches,
        ])
        XCTAssertTrue(HistorySearchMenu.canManageSavedSearches(library))
        XCTAssertFalse(HistorySearchMenu.canManageSavedSearches(SavedHistorySearchLibrary()))
    }

    func testOnlyRunnableQueriesCanBeSaved() {
        XCTAssertTrue(HistorySearchMenu.canSaveSearch(HistorySearchQuery(mode: .pickaxe, text: "needle")))
        XCTAssertFalse(HistorySearchMenu.canSaveSearch(HistorySearchQuery(mode: .pickaxe, text: "")))
        XCTAssertFalse(HistorySearchMenu.canSaveSearch(HistorySearchQuery(mode: .raw, text: "'open")))
    }

    func testRecentsAreListedNewestFirstWithAClearItem() {
        let newest = HistorySearchQuery(mode: .raw, text: "--all")
        let older = HistorySearchQuery(mode: .basic, text: "needle")
        let rows = HistorySearchMenu.rows(
            selectedMode: .basic,
            library: SavedHistorySearchLibrary(),
            recents: HistorySearchRecents(queries: [newest, older])
        )

        XCTAssertEqual(Array(rows.prefix(1)), [.mode(.basic, isSelected: true)])
        XCTAssertEqual(Array(rows.dropFirst(10)), [
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
