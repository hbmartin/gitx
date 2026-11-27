@testable import GitX
import GitXCore
import XCTest

@MainActor
final class SavedHistorySearchStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()
    private var notificationCenter = NotificationCenter()
    private var store: GitX.SavedHistorySearchStore!
    private let pickaxe = HistorySearchQuery(mode: .pickaxe, text: "needle")
    private let raw = HistorySearchQuery(mode: .raw, text: "--author='Ada Lovelace'")

    override func setUp() {
        super.setUp()
        suiteName = "GitXTests.SavedHistorySearchStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        notificationCenter = NotificationCenter()
        store = makeStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func makeStore() -> GitX.SavedHistorySearchStore {
        GitX.SavedHistorySearchStore(
            preferences: GitX.ApplicationPreferences(userDefaults: defaults),
            notificationCenter: notificationCenter
        )
    }

    private var receivedNotifications = 0

    @objc private func receiveNotification(_: Notification) {
        receivedNotifications += 1
    }

    private func notificationCount(_ name: Notification.Name, during body: () throws -> Void) rethrows -> Int {
        receivedNotifications = 0
        notificationCenter.addObserver(self, selector: #selector(receiveNotification(_:)), name: name, object: nil)
        defer { notificationCenter.removeObserver(self, name: name, object: nil) }
        try body()
        return receivedNotifications
    }

    // MARK: Saved searches

    func testSavingPersistsTheLibraryForEveryStoreAndAnnouncesEachChange() throws {
        let posted = try notificationCount(.savedHistorySearchesDidChange) {
            let saved = try store.save(name: " Ada ", query: raw).get()
            XCTAssertEqual(saved.name, "Ada")
            _ = try store.save(name: "Needles", query: pickaxe).get()
        }

        XCTAssertEqual(posted, 2)
        XCTAssertEqual(makeStore().library.searches.map(\.name), ["Ada", "Needles"])
        XCTAssertEqual(makeStore().library.search(named: "ada")?.query, raw)
        let stored = try XCTUnwrap(defaults.data(forKey: "PBSavedHistorySearches"))
        XCTAssertEqual(SavedHistorySearchLibrary.decoded(from: stored).library, store.library)
    }

    func testRefusedChangesLeaveTheStoredLibraryUnchangedAndQuiet() throws {
        let original = try store.save(name: "Ada", query: raw).get()
        let stored = defaults.data(forKey: "PBSavedHistorySearches")

        let posted = notificationCount(.savedHistorySearchesDidChange) {
            XCTAssertEqual(store.save(name: "ADA", query: pickaxe), .failure(.library(.duplicateName(existing: "Ada"))))
            XCTAssertEqual(
                store.save(name: "Open", query: HistorySearchQuery(mode: .raw, text: "'open")),
                .failure(.library(.invalidQuery(.unclosedQuote("'"))))
            )
            XCTAssertEqual(store.rename(id: UUID(), to: "Other"), .failure(.library(.unknownSearch)))
            XCTAssertEqual(store.remove(id: UUID()), .failure(.library(.unknownSearch)))
        }

        XCTAssertEqual(posted, 0)
        XCTAssertEqual(defaults.data(forKey: "PBSavedHistorySearches"), stored)
        XCTAssertEqual(store.library.searches, [original])
    }

    func testReplacingRenamingAndRemovingKeepTheSearchIdentity() throws {
        let original = try store.save(name: "Ada", query: raw).get()

        let replaced = try store.save(name: "ADA", query: pickaxe, replacingExisting: true).get()
        XCTAssertEqual(replaced.id, original.id)
        let renamed = try store.rename(id: original.id, to: "Lovelace").get()
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(makeStore().library.searches.map(\.name), ["Lovelace"])
        XCTAssertEqual(makeStore().library.search(id: original.id)?.query, pickaxe)

        XCTAssertEqual(try store.remove(id: original.id).get().name, "Lovelace")
        XCTAssertTrue(makeStore().library.searches.isEmpty)
    }

    func testANewerLibraryIsShownEmptyAndNeverOverwritten() {
        let newer = Data(#"{"version":2,"searches":[{"anything":true}]}"#.utf8)
        defaults.set(newer, forKey: "PBSavedHistorySearches")

        XCTAssertTrue(store.library.searches.isEmpty)
        let posted = notificationCount(.savedHistorySearchesDidChange) {
            XCTAssertEqual(store.save(name: "Ada", query: raw), .failure(.unsupportedLibrary))
            XCTAssertEqual(store.remove(id: UUID()), .failure(.unsupportedLibrary))
        }

        XCTAssertEqual(posted, 0)
        XCTAssertEqual(defaults.data(forKey: "PBSavedHistorySearches"), newer)
        XCTAssertEqual(
            GitX.SavedHistorySearchStoreIssue.unsupportedLibrary.message,
            "A newer version of GitX saved these searches, so they can’t be changed in this version."
        )
        XCTAssertEqual(
            GitX.SavedHistorySearchStoreIssue.library(.emptyName).message,
            SavedHistorySearchIssue.emptyName.message
        )
    }

    func testDamagedEntriesAreDroppedAndTheNextChangeRewritesTheReadableOnes() throws {
        defaults.set(Data("""
        {"version":1,"searches":[
        {"id":"0B5C7A4E-7C9D-4B7E-9A51-2F4E9E0B6A11","mode":2,"name":"Kept","text":"needle"},
        {"id":"broken","mode":2,"name":"Broken","text":"needle"}
        ]}
        """.utf8), forKey: "PBSavedHistorySearches")

        XCTAssertEqual(store.library.searches.map(\.name), ["Kept"])
        _ = try store.save(name: "Ada", query: raw).get()

        let stored = SavedHistorySearchLibrary.decoded(from: defaults.data(forKey: "PBSavedHistorySearches"))
        XCTAssertEqual(stored.droppedEntryCount, 0)
        XCTAssertEqual(stored.library.searches.map(\.name), ["Ada", "Kept"])
    }

    // MARK: Recent searches

    func testLegacyRecentsMigrateOnceWithTheSavedModeAndStayInPlace() {
        defaults.set(["  newest  ", "older", "   "], forKey: GitX.SavedHistorySearchStore.legacyRecentsKey)
        defaults.set(HistorySearchMode.regex.rawValue, forKey: "PBHistorySearchMode")

        XCTAssertEqual(store.recents.queries, [
            HistorySearchQuery(mode: .regex, text: "  newest  "),
            HistorySearchQuery(mode: .regex, text: "older"),
        ])
        XCTAssertNotNil(defaults.data(forKey: "PBHistorySearchRecents"))
        XCTAssertEqual(defaults.stringArray(forKey: GitX.SavedHistorySearchStore.legacyRecentsKey), ["  newest  ", "older", "   "])

        defaults.set(["changed later"], forKey: GitX.SavedHistorySearchStore.legacyRecentsKey)
        defaults.set(HistorySearchMode.path.rawValue, forKey: "PBHistorySearchMode")
        XCTAssertEqual(makeStore().recents.queries.map(\.text), ["  newest  ", "older"])
        XCTAssertEqual(makeStore().recents.queries.map(\.mode), [.regex, .regex])
    }

    func testWithoutLegacyRecentsNothingIsWrittenAndAnUnknownSavedModeMigratesAsBasic() {
        defaults.set(99, forKey: "PBHistorySearchMode")
        XCTAssertTrue(store.recents.queries.isEmpty)
        XCTAssertNil(defaults.object(forKey: "PBHistorySearchRecents"))

        defaults.set([42, "only text"], forKey: GitX.SavedHistorySearchStore.legacyRecentsKey)
        XCTAssertEqual(store.recents.queries, [HistorySearchQuery(mode: .basic, text: "only text")])
    }

    func testRecordingDeduplicatesAndOnlyAnnouncesRealChanges() {
        let posted = notificationCount(.historySearchRecentsDidChange) {
            store.recordRecent(pickaxe)
            store.recordRecent(raw)
            store.recordRecent(raw)
            store.recordRecent(HistorySearchQuery(mode: .basic, text: " \n"))
            XCTAssertEqual(store.recordRecent(pickaxe).queries, [pickaxe, raw])
        }

        XCTAssertEqual(posted, 3)
        XCTAssertEqual(makeStore().recents.queries, [pickaxe, raw])
    }

    func testClearingRecentsSticksAndDoesNotBringBackLegacyRecents() {
        defaults.set(["legacy"], forKey: GitX.SavedHistorySearchStore.legacyRecentsKey)
        store.recordRecent(pickaxe)

        let posted = notificationCount(.historySearchRecentsDidChange) {
            store.clearRecents()
        }

        XCTAssertEqual(posted, 1)
        XCTAssertTrue(makeStore().recents.queries.isEmpty)
    }

    func testUnreadableStoredRecentsShowNoneWithoutReadingLegacyRecents() {
        defaults.set(["legacy"], forKey: GitX.SavedHistorySearchStore.legacyRecentsKey)
        defaults.set(Data(#"{"version":2,"recents":[]}"#.utf8), forKey: "PBHistorySearchRecents")

        XCTAssertTrue(store.recents.queries.isEmpty)
        store.recordRecent(raw)
        XCTAssertEqual(makeStore().recents.queries, [raw])
    }
}
