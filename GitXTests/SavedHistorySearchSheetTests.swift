import AppKit
@testable import GitX
import GitXCore
import XCTest

/// The Save Search and Saved Searches sheets attach to their window and change the app-wide saved searches.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every window, sheet and fixture stays on main.
final class SavedHistorySearchSheetTests: XCTestCase, @unchecked Sendable {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    private var store: GitX.SavedHistorySearchStore!
    private var window: NSWindow!
    private let raw = HistorySearchQuery(mode: .raw, text: "--author='Ada Lovelace'")
    private let pickaxe = HistorySearchQuery(mode: .pickaxe, text: "needle")

    override nonisolated func setUp() {
        super.setUp()
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture setup on the main thread.
        MainActor.assumeIsolated { prepare() }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture teardown on the main thread.
        MainActor.assumeIsolated { dismissPresentations() }
        super.tearDown()
    }

    private func prepare() {
        suiteName = "GitXTests.SavedHistorySearchSheets.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        notificationCenter = NotificationCenter()
        store = GitX.SavedHistorySearchStore(
            preferences: GitX.ApplicationPreferences(userDefaults: defaults),
            notificationCenter: notificationCenter
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func dismissPresentations() {
        while let sheet = window?.attachedSheet {
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Helpers

    private func end(_ response: NSApplication.ModalResponse) throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: response)
        sheet.orderOut(nil)
    }

    private func waitForSheet(_ matches: @escaping (NSWindow) -> Bool = { _ in true }) throws -> NSWindow {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let sheet = window.attachedSheet, matches(sheet) {
                return sheet
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return try XCTUnwrap(window.attachedSheet, "No sheet appeared")
    }

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(texts(in:))
    }

    private func button(_ identifier: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier {
            return button
        }
        return view.subviews.lazy.compactMap { self.button(identifier, in: $0) }.first
    }

    private func type(_ text: String, into prompt: GitX.SavedHistorySearchSavePrompt) {
        prompt.nameField.stringValue = text
        prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: prompt.nameField))
    }

    private func makePrompt(_ query: HistorySearchQuery) -> GitX.SavedHistorySearchSavePrompt {
        GitX.SavedHistorySearchSavePrompt(query: query, modeLabel: "Raw", store: store)
    }

    // MARK: Save Search

    func testSaveSheetExplainsNamesWhileTypingAndSavesANewSearch() throws {
        _ = try store.save(name: "Fixes", query: pickaxe).get()
        var results: [SavedHistorySearch?] = []
        let prompt = makePrompt(raw)

        prompt.present(for: window) { results.append($0) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNil(NSApp.modalWindow)
        let save = try XCTUnwrap(button("GitX.SavedSearches.Save", in: sheet.contentView))
        XCTAssertTrue(texts(in: sheet.contentView).contains {
            $0.contains("“--author='Ada Lovelace'” (Raw)")
        })
        XCTAssertEqual(prompt.nameField.accessibilityIdentifier(), "GitX.SavedSearches.Name")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(prompt.messageField.isHidden)

        type(String(repeating: "x", count: 65), into: prompt)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(prompt.messageField.stringValue, "Use a name of 64 characters or fewer.")
        try attachScreenshot(of: sheet, named: "PR2-Save-Search-Sheet-Name-Too-Long")

        type(" fixes ", into: prompt)
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(prompt.messageField.stringValue, "A saved search named “Fixes” already exists. Saving replaces it.")

        type(" Ada ", into: prompt)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(prompt.messageField.isHidden)
        try end(.alertFirstButtonReturn)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first??.name, "Ada")
        XCTAssertEqual(store.library.search(named: "ada")?.query, raw)
        XCTAssertNil(window.attachedSheet)
    }

    func testCancellingTheSaveSheetSavesNothing() throws {
        var results: [SavedHistorySearch?] = []
        let prompt = makePrompt(raw)
        prompt.present(for: window) { results.append($0) }
        type("Ada", into: prompt)

        try end(.alertSecondButtonReturn)

        XCTAssertEqual(results, [nil])
        XCTAssertTrue(store.library.searches.isEmpty)
    }

    func testSavingADuplicateNameAsksBeforeReplacingIt() throws {
        let original = try store.save(name: "Fixes", query: pickaxe).get()
        var results: [SavedHistorySearch?] = []

        let declined = makePrompt(raw)
        declined.present(for: window) { results.append($0) }
        type("FIXES", into: declined)
        try end(.alertFirstButtonReturn)
        let confirmation = try waitForSheet { [self] sheet in button("GitX.SavedSearches.Replace", in: sheet.contentView) != nil }
        XCTAssertTrue(texts(in: confirmation.contentView).contains("Replace “Fixes”?"))
        try end(.alertSecondButtonReturn)
        XCTAssertEqual(results, [nil])
        XCTAssertEqual(store.library.searches, [original])

        let accepted = makePrompt(raw)
        accepted.present(for: window) { results.append($0) }
        type("FIXES", into: accepted)
        try end(.alertFirstButtonReturn)
        let replace = try waitForSheet { [self] sheet in button("GitX.SavedSearches.Replace", in: sheet.contentView) != nil }
        try attachScreenshot(of: replace, named: "PR2-Save-Search-Replace-Confirmation")
        try end(.alertFirstButtonReturn)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.last??.id, original.id)
        XCTAssertEqual(store.library.searches.map(\.name), ["FIXES"])
        XCTAssertEqual(store.library.searches.first?.query, raw)
    }

    func testASaveTheLibraryRefusesIsExplainedInAFollowingSheet() throws {
        for index in 0 ..< SavedHistorySearchLibrary.maximumCount {
            _ = try store.save(name: "Search \(index)", query: pickaxe).get()
        }
        var results: [SavedHistorySearch?] = []
        let prompt = makePrompt(raw)
        prompt.present(for: window) { results.append($0) }
        type("One more", into: prompt)
        let save = try XCTUnwrap(button("GitX.SavedSearches.Save", in: window.attachedSheet?.contentView))
        XCTAssertFalse(save.isEnabled)

        // Return cannot reach a disabled button, but a forced save is still refused and explained.
        try end(.alertFirstButtonReturn)
        let failure = try waitForSheet { [self] sheet in
            texts(in: sheet.contentView).contains("The search could not be saved")
        }
        XCTAssertTrue(texts(in: failure.contentView).contains(
            "You can keep up to 100 saved searches. Remove one to save another."
        ))
        XCTAssertTrue(results.isEmpty)
        try end(.alertFirstButtonReturn)

        XCTAssertEqual(results, [nil])
        XCTAssertEqual(store.library.searches.count, 100)
    }

    // MARK: Saved Searches sheet

    private func makeManageSheet(onApply: @escaping (SavedHistorySearch) -> Void = { _ in }) -> GitX.SavedHistorySearchesSheetController {
        GitX.SavedHistorySearchesSheetController(
            store: store,
            modeLabel: { $0 == .raw ? "Raw" : "Commit (pickaxe)" },
            notificationCenter: notificationCenter,
            onApply: onApply
        )
    }

    private func cellText(_ sheet: GitX.SavedHistorySearchesSheetController, row: Int, column: Int) -> String? {
        (sheet.tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    func testSavedSearchesSheetListsRenamesAndRemovesSearches() throws {
        _ = try store.save(name: "Ada", query: raw).get()
        _ = try store.save(name: "Needles", query: pickaxe).get()
        let sheet = makeManageSheet()

        sheet.present(for: window)
        XCTAssertIdentical(window.attachedSheet, sheet.panel)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(sheet.tableView.numberOfRows, 2)
        XCTAssertEqual(cellText(sheet, row: 0, column: 0), "Ada")
        XCTAssertEqual(cellText(sheet, row: 0, column: 1), "Raw")
        XCTAssertEqual(cellText(sheet, row: 0, column: 2), "--author='Ada Lovelace'")
        XCTAssertEqual(cellText(sheet, row: 1, column: 1), "Commit (pickaxe)")
        XCTAssertFalse(sheet.removeButton.isEnabled)
        XCTAssertFalse(sheet.applyButton.isEnabled)

        sheet.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(sheet.removeButton.isEnabled)
        XCTAssertTrue(sheet.applyButton.isEnabled)
        try attachScreenshot(of: sheet.panel, named: "PR2-Saved-Searches-Sheet")

        // A refused name is explained, and the old name comes back.
        sheet.rename(row: 0, to: " needles ")
        XCTAssertFalse(sheet.messageField.isHidden)
        XCTAssertEqual(sheet.messageField.stringValue, "A saved search named “Needles” already exists.")
        XCTAssertEqual(cellText(sheet, row: 0, column: 0), "Ada")
        sheet.rename(row: 0, to: "Ada")
        sheet.rename(row: 9, to: "Out of range")

        // Renaming re-sorts the list and keeps the renamed search selected.
        let field = try XCTUnwrap((sheet.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField)
        field.stringValue = "Zed"
        sheet.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(sheet.messageField.isHidden)
        XCTAssertEqual(sheet.searches.map(\.name), ["Needles", "Zed"])
        XCTAssertEqual(sheet.tableView.selectedRow, 1)

        sheet.removeSelected(nil)
        XCTAssertEqual(store.library.searches.map(\.name), ["Needles"])
        XCTAssertEqual(sheet.tableView.numberOfRows, 1)
        XCTAssertFalse(sheet.removeButton.isEnabled)
        sheet.removeSelected(nil)
        sheet.applySelected(nil)
        XCTAssertEqual(store.library.searches.count, 1)

        sheet.done(nil)
        XCTAssertNil(window.attachedSheet)
    }

    func testRunningASavedSearchClosesTheSheetFirst() throws {
        let saved = try store.save(name: "Ada", query: raw).get()
        var applied: [SavedHistorySearch] = []
        var sheetWasOpen: [Bool] = []
        let sheet = makeManageSheet { [self] search in
            applied.append(search)
            sheetWasOpen.append(window.attachedSheet != nil)
        }
        sheet.present(for: window)
        sheet.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        sheet.applySelected(nil)

        XCTAssertEqual(applied, [saved])
        XCTAssertEqual(sheetWasOpen, [false])
    }

    func testTheSheetFollowsChangesMadeElsewhereAndExplainsARefusedRemoval() throws {
        _ = try store.save(name: "Ada", query: raw).get()
        let sheet = makeManageSheet()
        sheet.present(for: window)
        sheet.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        _ = try store.save(name: "Beta", query: pickaxe).get()
        XCTAssertEqual(sheet.tableView.numberOfRows, 2)
        XCTAssertEqual(sheet.tableView.selectedRow, 0)

        // A newer GitX's library cannot be changed here.
        defaults.set(Data(#"{"version":2,"searches":[]}"#.utf8), forKey: "PBSavedHistorySearches")
        sheet.removeSelected(nil)
        XCTAssertEqual(
            sheet.messageField.stringValue,
            "A newer version of Half Dark saved these searches, so they can’t be changed in this version."
        )
    }
}
