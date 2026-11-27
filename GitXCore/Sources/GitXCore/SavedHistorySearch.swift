import Foundation

/// The text and mode of one history search, as the search field submits it.
public struct HistorySearchQuery: Hashable, Sendable {
    public var mode: HistorySearchMode
    public var text: String

    public init(mode: HistorySearchMode, text: String) {
        self.mode = mode
        self.text = text
    }

    /// True when submitting the query would run a search rather than clear the results.
    public var isRunnable: Bool {
        switch HistorySearchPolicy.execution(query: text, mode: mode) {
        case .basic, .background:
            true
        case .clear, .invalid:
            false
        }
    }
}

/// A history search the user named so it can be run again from any repository window, the `gitx` tool or
/// AppleScript.
public struct SavedHistorySearch: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var query: HistorySearchQuery

    public init(id: UUID = UUID(), name: String, query: HistorySearchQuery) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// Why a saved search cannot be stored, renamed or run.
public enum SavedHistorySearchIssue: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong(limit: Int)
    /// Another saved search already uses this name; saving again asks whether to replace it.
    case duplicateName(existing: String)
    case emptyQuery
    case invalidQuery(HistorySearchArgumentIssue)
    case libraryFull(limit: Int)
    case unknownSearch

    public var message: String {
        switch self {
        case .emptyName:
            "Enter a name for the saved search."
        case let .nameTooLong(limit):
            "Use a name of \(limit) characters or fewer."
        case let .duplicateName(existing):
            "A saved search named “\(existing)” already exists."
        case .emptyQuery:
            "Enter search text before saving the search."
        case let .invalidQuery(issue):
            HistorySearchArgumentSyntax.message(for: issue)
        case let .libraryFull(limit):
            "You can keep up to \(limit) saved searches. Remove one to save another."
        case .unknownSearch:
            "That saved search no longer exists."
        }
    }
}

/// The app-wide list of saved history searches. Names are unique, ignoring case and diacritics, and the list is
/// kept sorted by name so every menu shows the same order.
public struct SavedHistorySearchLibrary: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumNameLength = 64
    public static let maximumCount = 100

    public private(set) var searches: [SavedHistorySearch]

    public init(searches: [SavedHistorySearch] = []) {
        self.searches = []
        for search in searches {
            _ = insertDecoded(search)
        }
    }

    public func search(named name: String) -> SavedHistorySearch? {
        let key = Self.matchingKey(name)
        return searches.first { Self.matchingKey($0.name) == key }
    }

    public func search(id: UUID) -> SavedHistorySearch? {
        searches.first { $0.id == id }
    }

    /// Checks a proposed name. `excluding` is the search being renamed, which may keep its own name.
    public func nameIssue(for name: String, excluding id: UUID? = nil) -> SavedHistorySearchIssue? {
        let trimmed = Self.trimmedName(name)
        if trimmed.isEmpty {
            return .emptyName
        }
        if trimmed.count > Self.maximumNameLength {
            return .nameTooLong(limit: Self.maximumNameLength)
        }
        if let existing = search(named: trimmed), existing.id != id {
            return .duplicateName(existing: existing.name)
        }
        return nil
    }

    public static func queryIssue(for query: HistorySearchQuery) -> SavedHistorySearchIssue? {
        switch HistorySearchPolicy.execution(query: query.text, mode: query.mode) {
        case .basic, .background:
            nil
        case .clear:
            .emptyQuery
        case let .invalid(_, issue):
            .invalidQuery(issue)
        }
    }

    /// Saves `query` under `name`. A search with the same name is replaced only when `replacingExisting` is true;
    /// the replacement keeps its identity so open menus and sheets still find it.
    @discardableResult
    public mutating func save(
        name: String,
        query: HistorySearchQuery,
        replacingExisting: Bool = false
    ) -> Result<SavedHistorySearch, SavedHistorySearchIssue> {
        if let issue = Self.queryIssue(for: query) {
            return .failure(issue)
        }
        let trimmed = Self.trimmedName(name)
        if let issue = nameIssue(for: trimmed) {
            guard case .duplicateName = issue, replacingExisting,
                  let index = searches.firstIndex(where: { Self.matchingKey($0.name) == Self.matchingKey(trimmed) })
            else { return .failure(issue) }
            searches[index].name = trimmed
            searches[index].query = query
            let saved = searches[index]
            sort()
            return .success(saved)
        }
        guard searches.count < Self.maximumCount else { return .failure(.libraryFull(limit: Self.maximumCount)) }
        let saved = SavedHistorySearch(name: trimmed, query: query)
        searches.append(saved)
        sort()
        return .success(saved)
    }

    @discardableResult
    public mutating func rename(id: UUID, to name: String) -> Result<SavedHistorySearch, SavedHistorySearchIssue> {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return .failure(.unknownSearch) }
        if let issue = nameIssue(for: name, excluding: id) {
            return .failure(issue)
        }
        searches[index].name = Self.trimmedName(name)
        let renamed = searches[index]
        sort()
        return .success(renamed)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> SavedHistorySearch? {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return nil }
        return searches.remove(at: index)
    }

    // MARK: Persistence

    public func encoded() -> Data {
        let payload = LibraryPayload(
            version: Self.currentVersion,
            searches: searches.map {
                EntryPayload(id: $0.id.uuidString, name: $0.name, mode: $0.query.mode.rawValue, text: $0.query.text)
            }
        )
        return StoredHistorySearchJSON.encoded(payload)
    }

    /// Reads a stored library. Entries that cannot be used are dropped and counted, so the caller can log them.
    /// `isSupported` is false for a payload written by a newer GitX, which the caller must not overwrite.
    public static func decoded(from data: Data?) -> SavedHistorySearchLibraryDecoding {
        guard let data else {
            return SavedHistorySearchLibraryDecoding(library: SavedHistorySearchLibrary(), droppedEntryCount: 0, isSupported: true)
        }
        guard let header = try? JSONDecoder().decode(VersionPayload.self, from: data) else {
            return SavedHistorySearchLibraryDecoding(library: SavedHistorySearchLibrary(), droppedEntryCount: 0, isSupported: false)
        }
        guard header.version == currentVersion else {
            return SavedHistorySearchLibraryDecoding(library: SavedHistorySearchLibrary(), droppedEntryCount: 0, isSupported: false)
        }
        let entries = (try? JSONDecoder().decode(LossyEntriesPayload.self, from: data))?.searches ?? []
        var library = SavedHistorySearchLibrary()
        var dropped = 0
        for entry in entries {
            guard let entry,
                  let id = UUID(uuidString: entry.id),
                  let mode = HistorySearchMode(rawValue: entry.mode),
                  library.insertDecoded(SavedHistorySearch(id: id, name: entry.name, query: HistorySearchQuery(mode: mode, text: entry.text)))
            else {
                dropped += 1
                continue
            }
        }
        return SavedHistorySearchLibraryDecoding(library: library, droppedEntryCount: dropped, isSupported: true)
    }

    /// Adds a stored search if it is still valid; duplicate names and identities keep the first entry.
    private mutating func insertDecoded(_ search: SavedHistorySearch) -> Bool {
        guard searches.count < Self.maximumCount,
              !searches.contains(where: { $0.id == search.id }),
              nameIssue(for: search.name) == nil,
              Self.queryIssue(for: search.query) == nil
        else { return false }
        var stored = search
        stored.name = Self.trimmedName(search.name)
        searches.append(stored)
        sort()
        return true
    }

    private mutating func sort() {
        // Names are unique ignoring case and diacritics, and Finder ordering never ties distinct names.
        searches.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchingKey(_ name: String) -> String {
        trimmedName(name).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private struct VersionPayload: Decodable {
        let version: Int
    }

    private struct LibraryPayload: Encodable {
        let version: Int
        let searches: [EntryPayload]
    }

    private struct EntryPayload: Codable {
        let id: String
        let name: String
        let mode: Int
        let text: String
    }

    /// Decodes each entry independently so one damaged entry does not discard the rest.
    private struct LossyEntriesPayload: Decodable {
        let searches: [EntryPayload?]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .searches)
            var entries: [EntryPayload?] = []
            while !list.isAtEnd {
                if let entry = try? list.decode(EntryPayload.self) {
                    entries.append(entry)
                } else {
                    // A failed decode leaves the cursor in place; consume the damaged element.
                    _ = try? list.decode(DiscardedElement.self)
                    entries.append(nil)
                }
            }
            searches = entries
        }

        private enum CodingKeys: String, CodingKey {
            case searches
        }
    }
}

public struct SavedHistorySearchLibraryDecoding: Equatable, Sendable {
    public let library: SavedHistorySearchLibrary
    public let droppedEntryCount: Int
    public let isSupported: Bool
}

/// The most recent history searches, newest first, remembered with their modes.
public struct HistorySearchRecents: Equatable, Sendable {
    public static let currentVersion = 1
    public static let limit = 10

    public private(set) var queries: [HistorySearchQuery]

    public init(queries: [HistorySearchQuery] = []) {
        self.queries = []
        for query in queries.reversed() {
            record(query)
        }
    }

    /// Moves `query` to the front, replacing an identical earlier entry. Text that is empty or only whitespace is
    /// not remembered.
    public mutating func record(_ query: HistorySearchQuery) {
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queries.removeAll { $0 == query }
        queries.insert(query, at: 0)
        if queries.count > Self.limit {
            queries.removeLast(queries.count - Self.limit)
        }
    }

    public mutating func clear() {
        queries.removeAll()
    }

    /// Converts the search field's old text-only recents, newest first, by giving each one `mode`.
    public static func migrated(legacy: [String], mode: HistorySearchMode) -> HistorySearchRecents {
        HistorySearchRecents(queries: legacy.map { HistorySearchQuery(mode: mode, text: $0) })
    }

    public func encoded() -> Data {
        let payload = RecentsPayload(
            version: Self.currentVersion,
            recents: queries.map { RecentPayload(mode: $0.mode.rawValue, text: $0.text) }
        )
        return StoredHistorySearchJSON.encoded(payload)
    }

    /// Reads stored recents, or nil when nothing usable was stored. Unknown modes and damaged entries are skipped.
    public static func decoded(from data: Data?) -> HistorySearchRecents? {
        guard let data,
              let payload = try? JSONDecoder().decode(StoredRecentsPayload.self, from: data),
              payload.version == currentVersion
        else { return nil }
        return HistorySearchRecents(queries: payload.recents.compactMap { entry in
            guard let entry, let mode = HistorySearchMode(rawValue: entry.mode) else { return nil }
            return HistorySearchQuery(mode: mode, text: entry.text)
        })
    }

    private struct RecentsPayload: Encodable {
        let version: Int
        let recents: [RecentPayload]
    }

    private struct RecentPayload: Codable {
        let mode: Int
        let text: String
    }

    private struct StoredRecentsPayload: Decodable {
        let version: Int
        let recents: [RecentPayload?]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            var list = try container.nestedUnkeyedContainer(forKey: .recents)
            var entries: [RecentPayload?] = []
            while !list.isAtEnd {
                if let entry = try? list.decode(RecentPayload.self) {
                    entries.append(entry)
                } else {
                    _ = try? list.decode(DiscardedElement.self)
                    entries.append(nil)
                }
            }
            recents = entries
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case recents
        }
    }
}

/// Resolves the search a `gitx` invocation or an AppleScript `search` command asks for.
public enum HistorySearchScriptRequest {
    /// A named saved search wins over any text and mode in the same request. Without a name, empty text asks for
    /// no search.
    public static func resolve(
        savedSearchName: String?,
        text: String?,
        mode: HistorySearchMode,
        library: SavedHistorySearchLibrary
    ) -> Result<HistorySearchQuery?, HistorySearchScriptIssue> {
        if let savedSearchName {
            guard let saved = library.search(named: savedSearchName) else {
                return .failure(.unknownSavedSearch(name: savedSearchName))
            }
            return .success(saved.query)
        }
        guard let text, !text.isEmpty else { return .success(nil) }
        return .success(HistorySearchQuery(mode: mode, text: text))
    }
}

public enum HistorySearchScriptIssue: Error, Equatable, Sendable {
    case unknownSavedSearch(name: String)

    public var message: String {
        switch self {
        case let .unknownSavedSearch(name):
            "There is no saved search named “\(name)”."
        }
    }
}

/// Sorted-key JSON for stored search payloads, which hold only strings and integers.
enum StoredHistorySearchJSON {
    /// Returns empty data only for a value JSON cannot represent, such as a non-finite number.
    static func encoded(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            return Data()
        }
    }
}

/// Decodes any JSON element without reading it, so a lossy array decoder can step past a damaged entry.
private struct DiscardedElement: Decodable {
    init(from _: Decoder) throws {}
}
