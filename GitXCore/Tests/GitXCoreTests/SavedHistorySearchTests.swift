@testable import GitXCore
import XCTest

final class SavedHistorySearchTests: XCTestCase {
    private let pickaxe = HistorySearchQuery(mode: .pickaxe, text: "needle")
    private let raw = HistorySearchQuery(mode: .raw, text: "--author='Ada Lovelace'")

    // MARK: Library

    func testSavingSortsByNameAndFindsNamesIgnoringCaseDiacriticsAndOuterWhitespace() throws {
        var library = SavedHistorySearchLibrary()
        let zebra = try library.save(name: "  Zebra fixes ", query: pickaxe).get()
        let cafe = try library.save(name: "Café work", query: raw).get()
        let numbered = try library.save(name: "Release 10", query: pickaxe).get()
        _ = try library.save(name: "Release 9", query: raw).get()

        XCTAssertEqual(zebra.name, "Zebra fixes")
        XCTAssertEqual(library.searches.map(\.name), ["Café work", "Release 9", "Release 10", "Zebra fixes"])
        XCTAssertEqual(library.search(named: "  CAFE WORK ")?.id, cafe.id)
        XCTAssertEqual(library.search(named: "release 10")?.query, pickaxe)
        XCTAssertEqual(library.search(id: numbered.id)?.name, "Release 10")
        XCTAssertNil(library.search(named: "Release"))
        XCTAssertNil(library.search(id: UUID()))
    }

    func testSavingRejectsInvalidNamesAndQueriesWithExplanations() {
        var library = SavedHistorySearchLibrary()
        XCTAssertEqual(library.save(name: " \n", query: pickaxe), .failure(.emptyName))
        let longName = String(repeating: "é", count: SavedHistorySearchLibrary.maximumNameLength + 1)
        XCTAssertEqual(library.save(name: longName, query: pickaxe), .failure(.nameTooLong(limit: 64)))
        XCTAssertNoThrow(try library.save(name: String(longName.dropLast()), query: pickaxe).get())
        XCTAssertEqual(
            library.save(name: "Empty", query: HistorySearchQuery(mode: .path, text: "  ")),
            .failure(.emptyQuery)
        )
        XCTAssertEqual(
            library.save(name: "Unclosed", query: HistorySearchQuery(mode: .raw, text: "--grep='open")),
            .failure(.invalidQuery(.unclosedQuote("'")))
        )
        XCTAssertEqual(library.searches.count, 1)

        XCTAssertEqual(SavedHistorySearchIssue.emptyName.message, "Enter a name for the saved search.")
        XCTAssertEqual(SavedHistorySearchIssue.nameTooLong(limit: 64).message, "Use a name of 64 characters or fewer.")
        XCTAssertEqual(
            SavedHistorySearchIssue.duplicateName(existing: "Café").message,
            "A saved search named “Café” already exists."
        )
        XCTAssertEqual(SavedHistorySearchIssue.emptyQuery.message, "Enter search text before saving the search.")
        XCTAssertEqual(
            SavedHistorySearchIssue.invalidQuery(.unclosedQuote("'")).message,
            HistorySearchArgumentSyntax.message(for: .unclosedQuote("'"))
        )
        XCTAssertEqual(
            SavedHistorySearchIssue.libraryFull(limit: 100).message,
            "You can keep up to 100 saved searches. Remove one to save another."
        )
        XCTAssertEqual(SavedHistorySearchIssue.unknownSearch.message, "That saved search no longer exists.")
    }

    func testDuplicateNamesNeedAnExplicitReplacementThatKeepsTheIdentity() throws {
        var library = SavedHistorySearchLibrary()
        let original = try library.save(name: "Fixes", query: pickaxe).get()

        XCTAssertEqual(library.save(name: "FIXES", query: raw), .failure(.duplicateName(existing: "Fixes")))
        XCTAssertEqual(library.nameIssue(for: "fixes"), .duplicateName(existing: "Fixes"))
        XCTAssertNil(library.nameIssue(for: "fixes", excluding: original.id))

        let replaced = try library.save(name: "FIXES", query: raw, replacingExisting: true).get()
        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.name, "FIXES")
        XCTAssertEqual(library.searches, [replaced])
        XCTAssertEqual(
            library.save(name: "New", query: HistorySearchQuery(mode: .basic, text: ""), replacingExisting: true),
            .failure(.emptyQuery)
        )
    }

    func testRenamingAndRemovingValidateTheTargetAndKeepNamesUnique() throws {
        var library = SavedHistorySearchLibrary()
        let first = try library.save(name: "Alpha", query: pickaxe).get()
        _ = try library.save(name: "Beta", query: raw).get()

        XCTAssertEqual(library.rename(id: first.id, to: " beta "), .failure(.duplicateName(existing: "Beta")))
        XCTAssertEqual(library.rename(id: first.id, to: ""), .failure(.emptyName))
        XCTAssertEqual(library.rename(id: UUID(), to: "Gamma"), .failure(.unknownSearch))
        XCTAssertEqual(try library.rename(id: first.id, to: " alpha ").get().name, "alpha")
        let renamed = try library.rename(id: first.id, to: "Gamma").get()
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(library.searches.map(\.name), ["Beta", "Gamma"])

        XCTAssertEqual(library.remove(id: first.id)?.name, "Gamma")
        XCTAssertNil(library.remove(id: first.id))
        XCTAssertEqual(library.searches.map(\.name), ["Beta"])
    }

    func testTheLibraryHoldsAtMostOneHundredSearches() throws {
        var library = SavedHistorySearchLibrary()
        for index in 0 ..< SavedHistorySearchLibrary.maximumCount {
            _ = try library.save(name: "Search \(index)", query: pickaxe).get()
        }

        XCTAssertEqual(library.save(name: "One more", query: pickaxe), .failure(.libraryFull(limit: 100)))
        XCTAssertNoThrow(try library.save(name: "search 5", query: raw, replacingExisting: true).get())
        XCTAssertEqual(library.searches.count, 100)
        let initialized = SavedHistorySearchLibrary(
            searches: library.searches + [SavedHistorySearch(name: "Overflow", query: pickaxe)]
        )
        XCTAssertEqual(initialized.searches.count, 100)
        XCTAssertNil(initialized.search(named: "Overflow"))
    }

    // MARK: Library persistence

    func testLibraryRoundTripsThroughItsVersionedEncoding() throws {
        var library = SavedHistorySearchLibrary()
        _ = try library.save(name: "Paths", query: HistorySearchQuery(mode: .path, text: "'dir name/it'\\''s.txt'")).get()
        _ = try library.save(name: "東京 crème", query: HistorySearchQuery(mode: .basic, text: "  outer spaces  ")).get()

        let decoded = SavedHistorySearchLibrary.decoded(from: library.encoded())

        XCTAssertEqual(decoded, SavedHistorySearchLibraryDecoding(library: library, droppedEntryCount: 0, isSupported: true))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: library.encoded()) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
    }

    func testStoredJSONIsSortedAndEmptyOnlyForUnrepresentableValues() {
        XCTAssertEqual(
            String(decoding: StoredHistorySearchJSON.encoded(["b": 1, "a": 2]), as: UTF8.self),
            #"{"a":2,"b":1}"#
        )
        XCTAssertEqual(StoredHistorySearchJSON.encoded(Double.nan), Data())
    }

    func testFrozenVersionOneLibraryStillDecodes() {
        let frozen = Data("""
        {"searches":[\
        {"id":"0B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":4,"name":"Docs","text":"docs/"},\
        {"id":"6D1A3F2B-8E44-4C2B-B0C9-7A35F1E2D3C4","mode":1,"name":"Ada","text":"Ada Lovelace"}\
        ],"version":1}
        """.utf8)

        let decoded = SavedHistorySearchLibrary.decoded(from: frozen)

        XCTAssertTrue(decoded.isSupported)
        XCTAssertEqual(decoded.droppedEntryCount, 0)
        XCTAssertEqual(decoded.library.searches.map(\.name), ["Ada", "Docs"])
        XCTAssertEqual(decoded.library.search(named: "docs")?.query, HistorySearchQuery(mode: .path, text: "docs/"))
        XCTAssertEqual(
            decoded.library.search(named: "Ada")?.id,
            UUID(uuidString: "6D1A3F2B-8E44-4C2B-B0C9-7A35F1E2D3C4")
        )
        XCTAssertEqual(SavedHistorySearchLibrary.decoded(from: decoded.library.encoded()), decoded)
    }

    func testDamagedAndUnknownEntriesAreDroppedAndCounted() {
        let stored = Data("""
        {"version":1,"searches":[
        {"id":"0B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":2,"name":"Kept","text":"needle"},
        {"id":"not-a-uuid","mode":2,"name":"Bad identity","text":"needle"},
        {"id":"1B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":42,"name":"Unknown mode","text":"needle"},
        {"id":"2B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":2,"name":"   ","text":"needle"},
        {"id":"3B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":2,"name":"KEPT","text":"duplicate name"},
        {"id":"0B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":2,"name":"Same identity","text":"needle"},
        {"id":"4B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":5,"name":"Unclosed","text":"'open"},
        {"id":"5B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","name":"Missing mode","text":"needle"},
        "not an object",
        17
        ]}
        """.utf8)

        let decoded = SavedHistorySearchLibrary.decoded(from: stored)

        XCTAssertTrue(decoded.isSupported)
        XCTAssertEqual(decoded.library.searches.map(\.name), ["Kept"])
        XCTAssertEqual(decoded.droppedEntryCount, 9)
    }

    func testMissingUnreadableAndNewerLibrariesDecodeEmpty() {
        XCTAssertEqual(
            SavedHistorySearchLibrary.decoded(from: nil),
            SavedHistorySearchLibraryDecoding(library: SavedHistorySearchLibrary(), droppedEntryCount: 0, isSupported: true)
        )
        for data in [Data("garbage".utf8), Data(#"{"version":2,"searches":[]}"#.utf8), Data(#"{"searches":[]}"#.utf8)] {
            let decoded = SavedHistorySearchLibrary.decoded(from: data)
            XCTAssertFalse(decoded.isSupported)
            XCTAssertTrue(decoded.library.searches.isEmpty)
        }
        let withoutList = SavedHistorySearchLibrary.decoded(from: Data(#"{"version":1}"#.utf8))
        XCTAssertTrue(withoutList.isSupported)
        XCTAssertTrue(withoutList.library.searches.isEmpty)
    }

    // MARK: Recents

    func testRecentsKeepTheTenNewestDistinctQueriesWithTheirModes() {
        var recents = HistorySearchRecents()
        recents.record(HistorySearchQuery(mode: .basic, text: "alpha"))
        recents.record(HistorySearchQuery(mode: .raw, text: "alpha"))
        recents.record(HistorySearchQuery(mode: .basic, text: "beta"))
        recents.record(HistorySearchQuery(mode: .basic, text: "alpha"))
        recents.record(HistorySearchQuery(mode: .path, text: "  \n"))

        XCTAssertEqual(recents.queries, [
            HistorySearchQuery(mode: .basic, text: "alpha"),
            HistorySearchQuery(mode: .basic, text: "beta"),
            HistorySearchQuery(mode: .raw, text: "alpha"),
        ])

        for index in 0 ..< 12 {
            recents.record(HistorySearchQuery(mode: .pickaxe, text: "query \(index)"))
        }
        XCTAssertEqual(recents.queries.count, HistorySearchRecents.limit)
        XCTAssertEqual(recents.queries.first?.text, "query 11")
        XCTAssertEqual(recents.queries.last?.text, "query 2")

        recents.clear()
        XCTAssertTrue(recents.queries.isEmpty)
    }

    func testLegacyRecentsMigrateNewestFirstWithTheSavedMode() {
        let migrated = HistorySearchRecents.migrated(legacy: ["   ", "  alpha  ", "beta", "  alpha  "], mode: .regex)

        XCTAssertEqual(migrated.queries, [
            HistorySearchQuery(mode: .regex, text: "  alpha  "),
            HistorySearchQuery(mode: .regex, text: "beta"),
        ])
    }

    func testRecentsRoundTripAndSkipDamagedEntries() {
        let recents = HistorySearchRecents(queries: [
            HistorySearchQuery(mode: .raw, text: "--all"),
            HistorySearchQuery(mode: .basic, text: "東京"),
        ])
        XCTAssertEqual(HistorySearchRecents.decoded(from: recents.encoded()), recents)

        let damaged = Data("""
        {"version":1,"recents":[{"mode":3,"text":"seco.*"},{"mode":99,"text":"unknown"},{"text":"no mode"},[],{"mode":1,"text":"subject"}]}
        """.utf8)
        XCTAssertEqual(HistorySearchRecents.decoded(from: damaged)?.queries, [
            HistorySearchQuery(mode: .regex, text: "seco.*"),
            HistorySearchQuery(mode: .basic, text: "subject"),
        ])
        XCTAssertNil(HistorySearchRecents.decoded(from: nil))
        XCTAssertNil(HistorySearchRecents.decoded(from: Data("[]".utf8)))
        XCTAssertNil(HistorySearchRecents.decoded(from: Data(#"{"version":2,"recents":[]}"#.utf8)))
    }

    // MARK: Queries and script requests

    func testQueriesAreRunnableOnlyWhenTheyWouldSearch() {
        XCTAssertTrue(HistorySearchQuery(mode: .basic, text: " ").isRunnable)
        XCTAssertTrue(raw.isRunnable)
        XCTAssertFalse(HistorySearchQuery(mode: .basic, text: "").isRunnable)
        XCTAssertFalse(HistorySearchQuery(mode: .path, text: "'unclosed").isRunnable)
    }

    func testScriptRequestsPreferANamedSearchAndReportUnknownNames() throws {
        var library = SavedHistorySearchLibrary()
        _ = try library.save(name: "Ada", query: raw).get()

        XCTAssertEqual(
            HistorySearchScriptRequest.resolve(savedSearchName: "ada", text: "ignored", mode: .path, library: library),
            .success(raw)
        )
        XCTAssertEqual(
            HistorySearchScriptRequest.resolve(savedSearchName: "Missing", text: nil, mode: .basic, library: library),
            .failure(.unknownSavedSearch(name: "Missing"))
        )
        XCTAssertEqual(
            HistorySearchScriptRequest.resolve(savedSearchName: nil, text: "needle", mode: .pickaxe, library: library),
            .success(pickaxe)
        )
        XCTAssertEqual(
            HistorySearchScriptRequest.resolve(savedSearchName: nil, text: "", mode: .pickaxe, library: library),
            .success(nil)
        )
        XCTAssertEqual(
            HistorySearchScriptRequest.resolve(savedSearchName: nil, text: nil, mode: .pickaxe, library: library),
            .success(nil)
        )
        XCTAssertEqual(
            HistorySearchScriptIssue.unknownSavedSearch(name: "Missing").message,
            "There is no saved search named “Missing”."
        )
    }
}
