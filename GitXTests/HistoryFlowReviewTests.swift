import AppKit
import FlowDeltaAnalysis
import FlowDeltaCore
import FlowDeltaUI
@testable import GitX
import GitXCore
import XCTest

/// The Flow tab's review preferences, its View ▸ Flow Review commands, and copying and exporting its report.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every fixture and preference access stays on main.
final class HistoryFlowReviewTests: XCTestCase, @unchecked Sendable {
    private static let base = RevisionIdentity("58b966582ddd632593afb6101a147740c244ec89")
    private static let target = RevisionIdentity("39d18d4b9960adf8bf01026a5471c98d62fa3f64")
    private static let preferenceKeys = [
        ApplicationPreferenceKey.historyFlowPresentation,
        .historyFlowSliceDirection,
        .historyFlowNoiseLevel,
        .historyFlowGroupsByConcern,
        .historyFlowExportFormat,
    ].map(\.rawValue)

    private var savedPreferences: [String: Any] = [:]
    private var savedChooser: (@MainActor (NSSavePanel, NSWindow, @escaping @MainActor (URL?) -> Void) -> Void)?
    private var window: NSWindow?
    private var temporaryDirectory: URL?

    private var defaults: UserDefaults {
        ApplicationComposition.shared.applicationPreferences.userDefaults
    }

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where the preferences, chooser and AppKit fixtures are MainActor-isolated.
        try MainActor.assumeIsolated { try prepareFixture() }
    }

    override nonisolated func tearDownWithError() throws {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where the window and restored preferences are MainActor-isolated.
        MainActor.assumeIsolated { removeFixture() }
        try super.tearDownWithError()
    }

    private func prepareFixture() throws {
        for key in Self.preferenceKeys {
            if let value = defaults.object(forKey: key) {
                savedPreferences[key] = value
            }
            defaults.removeObject(forKey: key)
        }
        savedChooser = FlowDeltaAdapterView.chooseExportDestination
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXFlowReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
    }

    private func removeFixture() {
        for key in Self.preferenceKeys {
            defaults.removeObject(forKey: key)
            if let value = savedPreferences[key] {
                defaults.set(value, forKey: key)
            }
        }
        if let savedChooser {
            FlowDeltaAdapterView.chooseExportDestination = savedChooser
        }
        window?.close()
        window = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: Preferences

    func testSavedPreferencesApplyToTheNextReportWithoutBeingSavedAgain() throws {
        GitX.ApplicationSettings.historyFlowReviewPreferences = HistoryFlowReviewPreferences(
            presentation: .calls,
            slice: nil,
            noise: .hideFormatting,
            groupsByConcern: true,
            exportFormat: .json
        )
        let adapter = try makeAdapter()

        try adapter.display(Self.report())

        let state = adapter.reviewView.state
        XCTAssertEqual(state.presentation, .calls)
        XCTAssertNil(state.slice)
        XCTAssertEqual(state.noise, .hideFormatting)
        XCTAssertTrue(state.groupsByConcern)
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowPresentation"), "calls")
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowExportFormat"), "json", "Applying preferences never rewrites them")
        try attachScreenshot(of: adapter, named: "Flow review with saved preferences (Calls, grouped)")
    }

    func testASavedSliceIsDrawnFromTheNextSelectedNodeAndKeptUntilThen() throws {
        GitX.ApplicationSettings.historyFlowReviewPreferences = HistoryFlowReviewPreferences(
            presentation: .delta,
            slice: .backward,
            noise: .hideCosmetic,
            groupsByConcern: false,
            exportFormat: .markdown
        )
        let adapter = try makeAdapter()
        try adapter.display(Self.report())
        XCTAssertNil(adapter.reviewView.state.slice, "No slice is drawn before a node is selected")
        XCTAssertFalse(validate(.slice(.backward), in: adapter, checked: false))
        try selectSourceNode(in: adapter)
        XCTAssertEqual(adapter.reviewView.state.slice, .backward, "The saved slice is drawn from the selected node")
        XCTAssertTrue(validate(.slice(.backward), in: adapter, checked: true))
        try attachScreenshot(of: adapter, named: "Flow review draws the saved backward slice")

        try adapter.display(Self.report())
        adapter.performHistoryFlowCommand(menuItem(for: .noise(.showAll)))
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowNoiseLevel"), "show-all")
        XCTAssertEqual(
            defaults.string(forKey: "PBHistoryFlowSliceDirection"),
            "backward",
            "A choice made before any node is selected keeps the saved slice"
        )
    }

    func testMissingPreferencesHideCosmeticNoiseAndOfferToShowIt() throws {
        let adapter = try makeAdapter()

        try adapter.display(Self.report())

        XCTAssertEqual(adapter.reviewView.state.noise, .hideCosmetic)
        XCTAssertEqual(adapter.reviewView.state.presentation, .delta)
        XCTAssertGreaterThan(adapter.reviewView.hiddenNoiseCount, 0, "The parenthesized condition is cosmetic noise")
        XCTAssertNil(defaults.object(forKey: "PBHistoryFlowNoiseLevel"), "Defaults are not written until the user chooses")
        try attachScreenshot(of: adapter, named: "Flow review defaults hide cosmetic noise")
    }

    func testUserChangesInTheReviewAreRemembered() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())

        let noise = try XCTUnwrap(control(NSPopUpButton.self, "FlowDelta.Review.Noise", in: adapter.reviewView))
        noise.selectItem(at: 0)
        XCTAssertTrue(noise.sendAction(noise.action, to: noise.target))
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowNoiseLevel"), "show-all")

        let presentation = try XCTUnwrap(control(NSSegmentedControl.self, "FlowDelta.Review.Presentation", in: adapter.reviewView))
        presentation.selectedSegment = 1
        XCTAssertTrue(presentation.sendAction(presentation.action, to: presentation.target))
        XCTAssertEqual(adapter.reviewView.state.presentation, .beforeAfter)
        XCTAssertEqual(GitX.ApplicationSettings.historyFlowReviewPreferences.presentation, .beforeAfter)
    }

    // MARK: Menu commands

    func testFlowReviewMenuIsDisabledWithoutAReport() throws {
        let adapter = try makeAdapter()
        for command in HistoryFlowCommand.all {
            let item = menuItem(for: command)
            XCTAssertFalse(adapter.validateMenuItem(item), "\(command)")
            XCTAssertEqual(item.state, .off)
        }
        let unknown = menuItem(for: .exportReport)
        unknown.tag = 999
        XCTAssertFalse(adapter.validateMenuItem(unknown), "A Flow Review item with an unknown tag is disabled")
        let inherited = NSMenuItem(title: "Print…", action: #selector(NSView.printView(_:)), keyEquivalent: "")
        XCTAssertTrue(adapter.validateMenuItem(inherited), "Other actions keep AppKit's default")
    }

    func testFlowReviewMenuReflectsTheReview() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())

        XCTAssertTrue(validate(.presentation(.delta), in: adapter, checked: true))
        XCTAssertTrue(validate(.presentation(.calls), in: adapter, checked: false))
        XCTAssertFalse(validate(.slice(.forward), in: adapter, checked: false), "A slice needs a selected node")
        try selectSourceNode(in: adapter)
        XCTAssertTrue(validate(.slice(.forward), in: adapter, checked: false))
        XCTAssertTrue(validate(.noise(.hideCosmetic), in: adapter, checked: true))
        XCTAssertTrue(validate(.noise(.showAll), in: adapter, checked: false))
        XCTAssertTrue(validate(.toggleGroupByConcern, in: adapter, checked: false))
        XCTAssertTrue(validate(.startWalkthrough, in: adapter, checked: false))
        XCTAssertFalse(validate(.nextWalkthroughStep, in: adapter, checked: false))
        XCTAssertFalse(validate(.previousWalkthroughStep, in: adapter, checked: false))
        XCTAssertTrue(validate(.copyReport(.markdown), in: adapter, checked: false))
        XCTAssertTrue(validate(.exportReport, in: adapter, checked: false))
    }

    func testMenuCommandsDriveTheReviewAndAreRemembered() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())

        adapter.performHistoryFlowCommand(menuItem(for: .noise(.showAll)))
        XCTAssertEqual(adapter.reviewView.state.noise, .showAll)
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowNoiseLevel"), "show-all")

        try selectSourceNode(in: adapter)
        adapter.performHistoryFlowCommand(menuItem(for: .slice(.forward)))
        XCTAssertEqual(adapter.reviewView.state.slice, .forward)
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowSliceDirection"), "forward")
        adapter.performHistoryFlowCommand(menuItem(for: .slice(.forward)))
        XCTAssertNil(adapter.reviewView.state.slice, "Choosing the checked slice again hides it")
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowSliceDirection"), "none")

        adapter.performHistoryFlowCommand(menuItem(for: .toggleGroupByConcern))
        XCTAssertTrue(adapter.reviewView.state.groupsByConcern)
        XCTAssertEqual(defaults.object(forKey: "PBHistoryFlowGroupsByConcern") as? Bool, true)

        adapter.performHistoryFlowCommand(menuItem(for: .presentation(.beforeAfter)))
        XCTAssertEqual(adapter.reviewView.state.presentation, .beforeAfter)
        XCTAssertEqual(defaults.string(forKey: "PBHistoryFlowPresentation"), "before-after")
        XCTAssertFalse(validate(.slice(.forward), in: adapter, checked: false), "Slices need the delta graph")

        adapter.performHistoryFlowCommand(menuItem(for: .presentation(.delta)))
        adapter.performHistoryFlowCommand(menuItem(for: .startWalkthrough))
        XCTAssertEqual(adapter.reviewView.state.walkthroughStep, 0)
        XCTAssertFalse(validate(.startWalkthrough, in: adapter, checked: false))
        XCTAssertFalse(validate(.previousWalkthroughStep, in: adapter, checked: false))
        let steps = adapter.reviewView.activeWalkthroughSteps.count
        XCTAssertGreaterThan(steps, 1)
        adapter.performHistoryFlowCommand(menuItem(for: .nextWalkthroughStep))
        XCTAssertEqual(adapter.reviewView.state.walkthroughStep, 1)
        XCTAssertTrue(validate(.previousWalkthroughStep, in: adapter, checked: false))
        adapter.performHistoryFlowCommand(menuItem(for: .previousWalkthroughStep))
        XCTAssertEqual(adapter.reviewView.state.walkthroughStep, 0)
        try attachScreenshot(of: adapter, named: "Flow review walkthrough from the menu")

        let stale = NSMenuItem(title: "Unknown", action: #selector(FlowDeltaAdapterView.performHistoryFlowCommand(_:)), keyEquivalent: "")
        stale.tag = 999
        adapter.performHistoryFlowCommand(stale)
        XCTAssertEqual(adapter.reviewView.state.walkthroughStep, 0, "An unknown tag changes nothing")
    }

    func testCommandsIgnoreAHiddenFlowTab() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())
        adapter.isHidden = true

        adapter.performHistoryFlowCommand(menuItem(for: .presentation(.calls)))

        XCTAssertEqual(adapter.reviewView.state.presentation, .delta)
        XCTAssertNil(defaults.object(forKey: "PBHistoryFlowPresentation"))
    }

    // MARK: Copy and export

    func testCopyReportRendersWhatTheReviewShows() throws {
        let adapter = try makeAdapter()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXFlowReviewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        adapter.reportPasteboard = pasteboard
        try adapter.display(Self.report())

        adapter.performHistoryFlowCommand(menuItem(for: .copyReport(.json)))
        let json = try XCTUnwrap(waitForString(on: pasteboard) { $0.contains("\"base\"") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["target"] as? [String: Any])?["value"] as? String, Self.target.value)

        adapter.performHistoryFlowCommand(menuItem(for: .copyReport(.markdown)))
        let markdown = try XCTUnwrap(waitForString(on: pasteboard) { $0.hasPrefix("# FlowDelta report") })
        XCTAssertTrue(markdown.contains("shippingTotal"), markdown)

        adapter.performHistoryFlowCommand(menuItem(for: .copyReport(.mermaid)))
        XCTAssertNotNil(waitForString(on: pasteboard) { $0.hasPrefix("flowchart") })
    }

    func testExportWritesTheChosenFormatAndRemembersIt() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())
        let directory = try XCTUnwrap(temporaryDirectory)
        var offeredName: String?
        FlowDeltaAdapterView.chooseExportDestination = { panel, _, completion in
            offeredName = panel.nameFieldStringValue
            guard let formats = self.control(NSPopUpButton.self, "History.Flow.ExportFormat", in: panel.accessoryView) else {
                XCTFail("The export panel has no Format pop-up")
                completion(nil)
                return
            }
            XCTAssertEqual(formats.itemTitles, ["Markdown", "JSON", "Mermaid"])
            formats.selectItem(withTitle: "Mermaid")
            XCTAssertTrue(formats.sendAction(formats.action, to: formats.target))
            completion(directory.appendingPathComponent(panel.nameFieldStringValue))
        }

        adapter.performHistoryFlowCommand(menuItem(for: .exportReport))

        XCTAssertEqual(offeredName, "Flow 58b96658..39d18d4b.md")
        let exported = directory.appendingPathComponent("Flow 58b96658..39d18d4b.mmd")
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: exported.path) }, "No exported file")
        XCTAssertTrue(try String(contentsOf: exported, encoding: .utf8).hasPrefix("flowchart"))
        XCTAssertEqual(GitX.ApplicationSettings.historyFlowReviewPreferences.exportFormat, .mermaid)

        offeredName = nil
        FlowDeltaAdapterView.chooseExportDestination = { panel, _, completion in
            offeredName = panel.nameFieldStringValue
            completion(nil)
        }
        adapter.performHistoryFlowCommand(menuItem(for: .exportReport))
        XCTAssertEqual(offeredName, "Flow 58b96658..39d18d4b.mmd", "The remembered format names the next export")
    }

    func testExportFailureIsPresentedOnTheWindow() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report())
        let directory = try XCTUnwrap(temporaryDirectory)
        FlowDeltaAdapterView.chooseExportDestination = { _, _, completion in
            completion(directory.appendingPathComponent("missing/Flow.md"))
        }

        adapter.performHistoryFlowCommand(menuItem(for: .exportReport))

        XCTAssertTrue(waitUntil { self.window?.attachedSheet != nil }, "The failure was not presented")
        if let sheet = window?.attachedSheet {
            window?.endSheet(sheet)
        }
    }

    // MARK: Diagnostics

    func testDiagnosticCodesExplainIncompleteAnalysis() throws {
        let adapter = try makeAdapter()
        try adapter.display(Self.report(limits: AnalysisLimits(maximumFlowNodesPerFunction: 0)))

        let banner = try XCTUnwrap(control(NSTextField.self, "History.Flow.Diagnostics", in: adapter))
        XCTAssertTrue(banner.stringValue.hasPrefix("Flow analysis is incomplete"), banner.stringValue)
        XCTAssertTrue(banner.stringValue.contains("Some files or functions are larger than Flow analyzes."), banner.stringValue)
        try attachScreenshot(of: adapter, named: "Flow diagnostics explain analysis limits")
    }

    // MARK: Main menu

    func testViewMenuOffersEveryFlowReviewCommand() throws {
        let view = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
        let flowReview = try XCTUnwrap(view.item(withTitle: "Flow Review")?.submenu)
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(items(in:)) ?? []) }
        }
        let commands = items(in: flowReview).filter { $0.action == #selector(FlowDeltaAdapterView.performHistoryFlowCommand(_:)) }
        XCTAssertEqual(commands.map(\.tag).sorted(), HistoryFlowCommand.all.map(\.tag).sorted())

        func shortcut(_ command: HistoryFlowCommand) -> (String, NSEvent.ModifierFlags)? {
            commands.first { $0.tag == command.tag }.map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        }
        XCTAssertEqual(shortcut(.presentation(.delta))?.0, "1")
        XCTAssertEqual(shortcut(.presentation(.calls))?.1, [.control, .command])
        XCTAssertEqual(shortcut(.slice(.forward))?.0, "\u{F701}")
        XCTAssertEqual(shortcut(.slice(.backward))?.0, "\u{F700}")
        XCTAssertEqual(shortcut(.nextWalkthroughStep)?.0, "]")
        XCTAssertEqual(shortcut(.exportReport)?.0, "e")
        XCTAssertEqual(shortcut(.exportReport)?.1, [.shift, .command])
    }

    // MARK: Helpers

    private func makeAdapter() throws -> FlowDeltaAdapterView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let adapter = FlowDeltaAdapterView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        window.contentView = adapter
        self.window = window
        return adapter
    }

    private func selectSourceNode(in adapter: FlowDeltaAdapterView) throws {
        try adapter.reviewView.selectGraphNode(withStableID: XCTUnwrap(adapter.reviewView.sourceBackedNodeStableIDs.first))
    }

    private func menuItem(for command: HistoryFlowCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(command)",
            action: #selector(FlowDeltaAdapterView.performHistoryFlowCommand(_:)),
            keyEquivalent: ""
        )
        item.tag = command.tag
        return item
    }

    private func validate(_ command: HistoryFlowCommand, in adapter: FlowDeltaAdapterView, checked: Bool) -> Bool {
        let item = menuItem(for: command)
        let enabled = adapter.validateMenuItem(item)
        XCTAssertEqual(item.state == .on, checked, "\(command) checked state")
        return enabled
    }

    private func control<Control: NSView>(_: Control.Type, _ identifier: String, in root: NSView?) -> Control? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier, let match = root as? Control {
            return match
        }
        for subview in root.subviews {
            if let match = control(Control.self, identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func waitForString(on pasteboard: NSPasteboard, matching predicate: (String) -> Bool) -> String? {
        _ = waitUntil { pasteboard.string(forType: .string).map(predicate) == true }
        return pasteboard.string(forType: .string).flatMap { predicate($0) ? $0 : nil }
    }

    private static func report(limits: AnalysisLimits = .default) throws -> RevisionFlowDeltaReport {
        let old = """
        func shippingTotal(_ items: [Int], priority: Bool) -> Int {
            var total = 0
            for item in items {
                total += item
            }
            if priority { total += 10 }
            return total
        }

        func legacyDiscount(_ total: Int) -> Int { total > 100 ? 10 : 0 }
        """
        let new = """
        func shippingTotal(_ items: [Int], priority: Bool) -> Int {
            guard !items.isEmpty else { return 0 }
            var total = 0
            for item in items {
                total += item
            }
            if (priority) { total += 15 }
            return total
        }

        func auditOrder(_ items: [Int]) {
            for item in items { print(item) }
        }
        """
        return try FlowDeltaAnalyzer().analyze(
            RevisionComparison(
                base: base,
                target: target,
                files: [FileComparison(
                    old: SourceSnapshot(path: "Shipping.swift", revision: base, language: .swift, text: old),
                    new: SourceSnapshot(path: "Shipping.swift", revision: target, language: .swift, text: new)
                )]
            ),
            limits: limits
        )
    }
}
