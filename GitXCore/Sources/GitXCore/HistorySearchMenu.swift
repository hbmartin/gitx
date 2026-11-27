import Foundation

/// One row of the history search field's menu, in display order.
public enum HistorySearchMenuRow: Equatable, Sendable {
    case mode(HistorySearchMode, isSelected: Bool)
    case separator
    case savedSearchesHeader
    case savedSearch(SavedHistorySearch)
    case noSavedSearches
    /// Enabled only while the search field holds a query that can run; see `canSaveSearch(_:)`.
    case saveSearchAs
    /// Enabled only while there are saved searches; see `canManageSavedSearches(_:)`.
    case manageSavedSearches
    case recentSearchesHeader
    /// `index` is the query's position in the recents the menu was built from.
    case recentSearch(index: Int, query: HistorySearchQuery)
    case noRecentSearches
    case clearRecentSearches
}

/// Decides what the history search field's menu shows.
public enum HistorySearchMenu {
    /// The modes in menu order.
    public static let modes: [HistorySearchMode] = [.basic, .pickaxe, .regex, .path, .raw]
    /// The longest query text a menu item shows before it is shortened.
    public static let maximumDisplayLength = 48

    public static func rows(
        selectedMode: HistorySearchMode,
        library: SavedHistorySearchLibrary,
        recents: HistorySearchRecents
    ) -> [HistorySearchMenuRow] {
        var rows = modes.map { HistorySearchMenuRow.mode($0, isSelected: $0 == selectedMode) }
        rows.append(.separator)
        rows.append(.savedSearchesHeader)
        if library.searches.isEmpty {
            rows.append(.noSavedSearches)
        } else {
            rows += library.searches.map(HistorySearchMenuRow.savedSearch)
        }
        rows += [.saveSearchAs, .manageSavedSearches, .separator]
        rows.append(.recentSearchesHeader)
        if recents.queries.isEmpty {
            rows.append(.noRecentSearches)
        } else {
            rows += recents.queries.enumerated().map { HistorySearchMenuRow.recentSearch(index: $0.offset, query: $0.element) }
            rows.append(.separator)
            rows.append(.clearRecentSearches)
        }
        return rows
    }

    public static func canSaveSearch(_ query: HistorySearchQuery) -> Bool {
        query.isRunnable
    }

    public static func canManageSavedSearches(_ library: SavedHistorySearchLibrary) -> Bool {
        !library.searches.isEmpty
    }

    /// Query text for a one-line menu title: line breaks and tabs become spaces, and long text is shortened with
    /// an ellipsis.
    public static func displayText(for text: String) -> String {
        let oneLine = String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        guard oneLine.count > maximumDisplayLength else { return oneLine }
        return String(oneLine.prefix(maximumDisplayLength - 1)) + "…"
    }
}
