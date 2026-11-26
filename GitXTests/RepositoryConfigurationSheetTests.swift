import AppKit
@testable import GitX
import XCTest

/// Characterizes saving the Repository Configuration sheet through its real controls.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every window, sheet and fixture stays on main.
final class RepositoryConfigurationSheetTests: XCTestCase, @unchecked Sendable {
    private var fixture: ReflogGitFixture!
    private var repository: GitXTestGitRepository!
    private var owner: GitX.PBGitWindowController!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture setup on the main thread.
        try MainActor.assumeIsolated { try openRepositoryWindow() }
    }

    override nonisolated func tearDownWithError() throws {
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture teardown on the main thread.
        MainActor.assumeIsolated { closeRepositoryWindow() }
        try super.tearDownWithError()
    }

    private func openRepositoryWindow() throws {
        fixture = try ReflogGitFixture()
        repository = try GitXTestGitRepository(url: fixture.url)
        owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
    }

    private func closeRepositoryWindow() {
        if let window = owner?.window {
            while let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        owner?.close()
        repository?.worktreeService.cancel()
        fixture?.remove()
        owner = nil
        repository = nil
        fixture = nil
    }

    func testSavingValidConfigurationPersistsEveryFieldAndClosesTheSheet() async throws {
        let window = try XCTUnwrap(owner.window)
        WindowDialogPresenter.showRepositorySettings(for: owner)
        let sheet = try XCTUnwrap(window.attachedSheet)

        let generalFields = editableTextFields(in: sheet.contentView)
        XCTAssertEqual(generalFields.count, 2, "Primary branch and web URL template")
        let webURLTemplate = try XCTUnwrap(generalFields.last)
        webURLTemplate.stringValue = "https://example.com/{branch}"
        try selectTab("Commit", in: sheet)
        let rules = try XCTUnwrap(firstSubview(of: NSTextView.self, in: sheet.contentView))
        rules.string = "fixup => squash"
        try selectTab("Diff", in: sheet)
        let patterns = try XCTUnwrap(firstSubview(of: NSTextView.self, in: sheet.contentView))
        patterns.string = "# generated\n\\.lock$"

        let saved = expectation(forNotification: .repositorySettingsDidChange, object: repository)
        try XCTUnwrap(firstSubview(of: NSButton.self, in: sheet.contentView) { $0.title == "Save" }).performClick(nil)
        await fulfillment(of: [saved], timeout: 2)

        XCTAssertNil(window.attachedSheet)
        let store = ApplicationComposition.shared.repositoryConfiguration(for: repository)
        XCTAssertEqual(store.string(forKey: RepositorySettingsStore.webURLTemplateKey), "https://example.com/{branch}")
        XCTAssertEqual(store.string(forKey: RepositorySettingsStore.commitRulesKey), "fixup => squash")
        XCTAssertEqual(store.string(forKey: RepositorySettingsStore.diffSuppressionKey), "# generated\n\\.lock$")
    }

    // MARK: - Helpers

    func selectTab(_ name: String, in sheet: NSWindow) throws {
        let item = try XCTUnwrap(sheet.toolbar?.items.first { $0.itemIdentifier.rawValue == name })
        XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(sheet.toolbar?.selectedItemIdentifier?.rawValue, name)
    }

    func editableTextFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own = (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []
        return own + view.subviews.flatMap(editableTextFields(in:))
    }

    func firstSubview<View: NSView>(
        of type: View.Type,
        in view: NSView?,
        where matches: (View) -> Bool = { _ in true }
    ) -> View? {
        guard let view else { return nil }
        if let match = view as? View, matches(match) {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview, where: matches) {
                return match
            }
        }
        return nil
    }
}
