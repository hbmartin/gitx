import Foundation
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

extension Notification.Name {
    /// Posted after the app-wide saved history searches change, so every history window rebuilds its menus.
    nonisolated static let savedHistorySearchesDidChange = Notification.Name("PBSavedHistorySearchesDidChangeNotification")
    /// Posted after the remembered recent history searches change.
    nonisolated static let historySearchRecentsDidChange = Notification.Name("PBHistorySearchRecentsDidChangeNotification")
}

/// Why the saved history searches could not be changed.
enum SavedHistorySearchStoreIssue: Error, Equatable {
    case library(SavedHistorySearchIssue)
    /// A newer GitX wrote the stored searches; changing them here would discard them.
    case unsupportedLibrary

    var message: String {
        switch self {
        case let .library(issue):
            issue.message
        case .unsupportedLibrary:
            "A newer version of GitX saved these searches, so they can’t be changed in this version."
        }
    }
}

/// Reads and writes the app-wide saved history searches and the recent history searches in application
/// preferences. Query text is logged privately.
final class SavedHistorySearchStore {
    /// Where the search field's AppKit autosave kept text-only recents before recents remembered their modes.
    static let legacyRecentsKey = "Recent History Searches"

    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "HistorySearch")
    private static let libraryKey = ApplicationPreferenceKey.savedHistorySearches.rawValue
    private static let recentsKey = ApplicationPreferenceKey.historySearchRecents.rawValue

    private let preferences: ApplicationPreferences
    private let notificationCenter: NotificationCenter

    init(
        preferences: ApplicationPreferences = ApplicationComposition.shared.applicationPreferences,
        notificationCenter: NotificationCenter = .default
    ) {
        self.preferences = preferences
        self.notificationCenter = notificationCenter
    }

    // MARK: Saved searches

    var library: SavedHistorySearchLibrary {
        decodedLibrary().library
    }

    func save(
        name: String,
        query: HistorySearchQuery,
        replacingExisting: Bool = false
    ) -> Result<SavedHistorySearch, SavedHistorySearchStoreIssue> {
        change("save") { $0.save(name: name, query: query, replacingExisting: replacingExisting) }
    }

    func rename(id: UUID, to name: String) -> Result<SavedHistorySearch, SavedHistorySearchStoreIssue> {
        change("rename") { $0.rename(id: id, to: name) }
    }

    func remove(id: UUID) -> Result<SavedHistorySearch, SavedHistorySearchStoreIssue> {
        change("remove") { library in
            library.remove(id: id).map { .success($0) } ?? .failure(.unknownSearch)
        }
    }

    private func change(
        _ action: StaticString,
        _ body: (inout SavedHistorySearchLibrary) -> Result<SavedHistorySearch, SavedHistorySearchIssue>
    ) -> Result<SavedHistorySearch, SavedHistorySearchStoreIssue> {
        let decoding = decodedLibrary()
        guard decoding.isSupported else {
            Self.logger.error("Refused to \(action, privacy: .public) a saved history search in a newer library")
            return .failure(.unsupportedLibrary)
        }
        var library = decoding.library
        switch body(&library) {
        case let .failure(issue):
            Self.logger.info("Could not \(action, privacy: .public) a saved history search: \(issue.message, privacy: .public)")
            return .failure(.library(issue))
        case let .success(search):
            preferences.set(library.encoded(), forKey: Self.libraryKey)
            Self.logger.info(
                """
                Did \(action, privacy: .public) saved history search \(search.name, privacy: .private) \
                (\(search.query.text, privacy: .private), mode \(search.query.mode.rawValue)); \
                \(library.searches.count) saved
                """
            )
            notificationCenter.post(name: .savedHistorySearchesDidChange, object: self)
            return .success(search)
        }
    }

    private func decodedLibrary() -> SavedHistorySearchLibraryDecoding {
        let decoding = SavedHistorySearchLibrary.decoded(from: preferences.data(forKey: Self.libraryKey))
        if !decoding.isSupported {
            Self.logger.error("Saved history searches use an unsupported format; showing none and leaving them unchanged")
        } else if decoding.droppedEntryCount > 0 {
            Self.logger.error("Dropped \(decoding.droppedEntryCount) unreadable saved history searches")
        }
        return decoding
    }

    // MARK: Recent searches

    /// The remembered searches, newest first. The first read after upgrading converts the search field's legacy
    /// text-only recents, giving each one the saved search mode, and leaves the legacy list in place.
    var recents: HistorySearchRecents {
        guard preferences.object(forKey: Self.recentsKey) == nil else {
            guard let stored = HistorySearchRecents.decoded(from: preferences.data(forKey: Self.recentsKey)) else {
                Self.logger.error("Recent history searches use an unsupported format; showing none")
                return HistorySearchRecents()
            }
            return stored
        }
        let legacy = (preferences.array(forKey: Self.legacyRecentsKey) ?? []).compactMap { $0 as? String }
        guard !legacy.isEmpty else { return HistorySearchRecents() }
        let mode = HistorySearchMode(rawValue: preferences.integer(forKey: ApplicationPreferenceKey.historySearchMode.rawValue)) ?? .basic
        let migrated = HistorySearchRecents.migrated(legacy: legacy, mode: mode)
        preferences.set(migrated.encoded(), forKey: Self.recentsKey)
        Self.logger.info(
            "Migrated \(legacy.count) legacy recent history searches as \(migrated.queries.count) in mode \(mode.rawValue)"
        )
        return migrated
    }

    /// Remembers `query` as the newest recent search. Whitespace-only text is not remembered.
    @discardableResult
    func recordRecent(_ query: HistorySearchQuery) -> HistorySearchRecents {
        let previous = recents
        var updated = previous
        updated.record(query)
        guard updated != previous else { return updated }
        writeRecents(updated)
        Self.logger.debug("Recorded recent history search \(query.text, privacy: .private) in mode \(query.mode.rawValue)")
        return updated
    }

    func clearRecents() {
        writeRecents(HistorySearchRecents())
        Self.logger.info("Cleared recent history searches")
    }

    private func writeRecents(_ recents: HistorySearchRecents) {
        preferences.set(recents.encoded(), forKey: Self.recentsKey)
        notificationCenter.post(name: .historySearchRecentsDidChange, object: self)
    }
}
