import AppKit
import GitXCore
import ObjectiveGit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog
import QuartzCore

/// Runs history searches for one history view. Basic searches filter the loaded commits; the other modes
/// run `git log` in the background. Marks matching rows, steps between them and shows a rewind overlay when
/// stepping wraps around.
// The history nib, PBGitHistoryController+UI.m and PBGitRevisionRow.m reach these members through
// Objective-C, which SwiftLint's analyzer cannot see.
// swiftlint:disable unused_declaration
@objc(PBHistorySearchController)
final class PBHistorySearchController: NSObject {
    private enum Direction {
        case next
        case previous
    }

    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "HistorySearch")
    private static let rewindPanelSize: CGFloat = 125
    private static let rewindPanelImageViewTag = 1234
    private static let menuModes = HistorySearchMenu.modes.map { PBSearchModeForInteger($0.rawValue) }

    @IBOutlet weak var historyController: PBGitHistoryController?
    @IBOutlet weak var commitController: NSArrayController?
    @IBOutlet weak var searchField: NSSearchField?
    @IBOutlet weak var stepper: NSSegmentedControl?
    @IBOutlet weak var numberOfMatchesField: NSTextField?
    @IBOutlet weak var progressIndicator: NSProgressIndicator?
    /// The scope bar's visible search mode control; it mirrors the search field menu's mode checkmarks.
    @IBOutlet weak var modePopUp: NSPopUpButton?

    private var storedSearchMode: PBHistorySearchMode = .basic
    private var results: IndexSet?
    private var searchTimer: Timer?
    /// The running background search; key-value readable so tests can wait for it to finish.
    @objc private(set) var backgroundSearchTask: PBTask?
    private var rewindPanel: NSPanel?
    private var arrangedObjectsObservation: NSKeyValueObservation?
    /// App-wide saved and recent searches, read from application preferences when first needed.
    private lazy var searchStore = SavedHistorySearchStore()

    @objc dynamic var searchMode: PBHistorySearchMode {
        get { storedSearchMode }
        set {
            storedSearchMode = newValue
            PBGitDefaults.setHistorySearchMode(newValue.rawValue)
            updateSearchMenuState()
            updateSearchPlaceholderString()
        }
    }

    // MARK: Public methods

    @objc(isRowInSearchResults:)
    func isRow(inSearchResults rowIndex: Int) -> Bool {
        guard rowIndex >= 0 else { return false }
        return results?.contains(rowIndex) ?? false
    }

    @objc func hasSearchResults() -> Bool {
        !(results?.isEmpty ?? true)
    }

    @objc func selectSearchMode(_ sender: Any) {
        let tag = (sender as? NSPopUpButton)?.selectedTag()
            ?? (sender as? NSMenuItem)?.tag
            ?? (sender as? NSView)?.tag
            ?? 0
        searchMode = PBSearchModeForInteger(tag)
        let mode = searchMode.rawValue
        Self.logger.info("Selected history search mode \(mode)")
        updateSearch(self)
    }

    @objc func selectNextResult() {
        selectNextResult(in: .next)
    }

    @objc func selectPreviousResult() {
        selectNextResult(in: .previous)
    }

    @IBAction func stepperPressed(_ sender: Any) {
        if (sender as? NSSegmentedControl)?.selectedSegment == 0 {
            selectPreviousResult()
        } else {
            selectNextResult()
        }
    }

    @objc func clearSearch() {
        searchField?.stringValue = ""
        numberOfMatchesField?.toolTip = nil
        if results != nil {
            results = nil
            historyController?.commitList.reloadData()
        }
        updateUI()
    }

    @IBAction func updateSearch(_ sender: Any?) {
        if searchMode == .basic {
            startBasicSearch()
        } else {
            startBackgroundSearch()
        }
    }

    /// Ignores a nil or empty search string; otherwise selects the mode, submits the text and remembers it as
    /// a recent search.
    @objc(setHistorySearch:mode:)
    func setHistorySearch(_ searchString: String?, mode: PBHistorySearchMode) {
        guard let searchString, !searchString.isEmpty else { return }
        searchMode = mode
        searchField?.stringValue = searchString
        searchField?.performClick(self)
        recordCurrentSearch()
    }

    /// Runs the chosen recent search in the mode it was made in.
    @objc func selectRecentSearch(_ sender: Any) {
        let queries = searchStore.recents.queries
        guard let index = ((sender as? NSMenuItem)?.representedObject as? NSNumber)?.intValue,
              queries.indices.contains(index)
        else {
            Self.logger.error("Ignored a recent history search that is no longer listed")
            rebuildSearchMenu()
            return
        }
        let query = queries[index]
        Self.logger.info("Running recent history search \(query.text, privacy: .private) in mode \(query.mode.rawValue)")
        run(query)
    }

    @objc func clearRecentSearches(_: Any?) {
        searchStore.clearRecents()
    }

    /// Runs the chosen saved search in the mode it was saved with.
    @objc func selectSavedSearch(_ sender: Any) {
        guard let identifier = (sender as? NSMenuItem)?.representedObject as? String,
              let id = UUID(uuidString: identifier),
              let search = searchStore.library.search(id: id)
        else {
            Self.logger.error("Ignored a saved history search that no longer exists")
            rebuildSearchMenu()
            return
        }
        Self.logger.info("Running saved history search \(search.name, privacy: .private)")
        run(search.query)
    }

    /// Asks for a name and saves the current search for every repository window.
    @objc func saveSearchAs(_: Any?) {
        let query = currentQuery
        guard HistorySearchMenu.canSaveSearch(query) else {
            NSSound.beep()
            return
        }
        let prompt = SavedHistorySearchSavePrompt(
            query: query,
            modeLabel: Self.label(for: searchMode),
            store: searchStore
        )
        let field = searchField
        prompt.present(for: presentationWindow) { saved in
            guard let saved else { return }
            AccessibilityAnnouncer.announce(
                String(format: NSLocalizedString("Saved search “%@”", comment: "Announcement after saving a search"), saved.name),
                from: field
            )
        }
    }

    @objc func manageSavedSearches(_: Any?) {
        guard let window = presentationWindow else { return }
        let sheet = SavedHistorySearchesSheetController(
            store: searchStore,
            modeLabel: { Self.label(for: PBSearchModeForInteger($0.rawValue)) },
            onApply: { [weak self] search in self?.run(search.query) }
        )
        sheet.present(for: window)
    }

    override nonisolated func awakeFromNib() {
        super.awakeFromNib()
        // swift6-safety-justification: AppKit invokes awakeFromNib on the main thread while loading the history XIB.
        MainActor.assumeIsolated {
            finishAwakingFromNib()
        }
    }

    private func finishAwakingFromNib() {
        // Recents are kept with their modes by the search store, not by the search field.
        searchField?.recentsAutosaveName = nil
        searchField?.maximumRecents = 0
        searchField?.setAccessibilityIdentifier("GitX.History.SearchField")
        (searchField?.cell as? NSSearchFieldCell)?.searchButtonCell?.setAccessibilityIdentifier("GitX.History.SearchMenuButton")
        numberOfMatchesField?.setAccessibilityIdentifier("GitX.History.SearchMatches")
        rebuildSearchMenu()
        setupModePopUp()
        for name in [Notification.Name.historySearchRecentsDidChange, .savedHistorySearchesDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(searchListsDidChange(_:)), name: name, object: nil)
        }
        searchMode = PBSearchModeForInteger(PBGitDefaults.historySearchMode())
        updateUI()
        arrangedObjectsObservation = commitController?.observe(\.arrangedObjects, options: []) { [weak self] _, _ in
            // The commit list changed, so the result indexes no longer describe the same commits.
            self?.clearSearchOnMain()
        }
    }

    // MARK: Navigation

    private func selectIndex(_ index: Int) {
        let objects = arrangedObjects
        guard index >= 0, index < objects.count, let commit = objects[index] as? PBGitCommit else { return }
        historyController?.selectCommit(commit.oid)
    }

    private func selectNextResult(in direction: Direction) {
        guard let results, let first = results.first, let last = results.last,
              let commitList = historyController?.commitList
        else { return }

        // With no selection the table reports -1, so Next starts at the first match and Previous wraps.
        let selectedRow = commitList.selectedRow
        var target = direction == .next ? results.integerGreaterThan(selectedRow) : results.integerLessThan(selectedRow)
        if target == nil {
            target = direction == .next ? first : last
            showSearchRewindPanel(reversed: direction != .next)
        }
        if let target {
            selectIndex(target)
        }
    }

    // MARK: Presentation

    private var numberOfMatchesString: String {
        let numberOfMatches = results?.count ?? 0
        switch numberOfMatches {
        case 0:
            return NSLocalizedString("Not found", comment: "Search count (left of search field): no results")
        case 1:
            return NSLocalizedString("1 match", comment: "Search count (left of search field): exactly one result")
        default:
            return String(
                format: NSLocalizedString("%lu matches", comment: "Search count (left of search field): number of results"),
                numberOfMatches
            )
        }
    }

    private func updateUI() {
        if searchField?.stringValue.isEmpty ?? true {
            numberOfMatchesField?.isHidden = true
            stepper?.isHidden = true
        } else {
            numberOfMatchesField?.stringValue = numberOfMatchesString
            numberOfMatchesField?.isHidden = false
            stepper?.isHidden = false
            if let commitList = historyController?.commitList {
                // Preserve the selection across the reload that redraws the match highlighting.
                let selectedRowIndexes = commitList.selectedRowIndexes
                commitList.reloadData()
                commitList.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
            }
        }
        clearProgressIndicator()
    }

    /// Moves to the next match after the selected row unless the selected row already matches.
    private func updateSelectedResult() {
        guard let searchString = searchField?.stringValue, !searchString.isEmpty else {
            clearSearch()
            return
        }
        if !isRow(inSearchResults: historyController?.commitList.selectedRow ?? -1) {
            selectNextResult()
        }
        updateUI()
    }

    @objc private func searchListsDidChange(_: Notification) {
        rebuildSearchMenu()
    }

    private var currentQuery: HistorySearchQuery {
        HistorySearchQuery(mode: Self.coreMode(searchMode), text: searchField?.stringValue ?? "")
    }

    private var presentationWindow: NSWindow? {
        searchField?.window ?? historyController?.view.window
    }

    private func recordCurrentSearch() {
        guard searchField != nil else { return }
        searchStore.recordRecent(currentQuery)
    }

    /// Shows and runs `query` in this window and remembers it as a recent search.
    private func run(_ query: HistorySearchQuery) {
        searchMode = PBSearchModeForInteger(query.mode.rawValue)
        searchField?.stringValue = query.text
        updateSearch(self)
        recordCurrentSearch()
    }

    /// Builds the search field menu: the modes, the saved searches, then the recent searches with their modes.
    private func rebuildSearchMenu() {
        let searchMenu = NSMenu(title: NSLocalizedString("Search Menu", comment: "Title of the Search menu."))
        let rows = HistorySearchMenu.rows(
            selectedMode: Self.coreMode(searchMode),
            library: searchStore.library,
            recents: searchStore.recents
        )
        for row in rows {
            searchMenu.addItem(menuItem(for: row))
        }
        searchFieldCell?.searchMenuTemplate = searchMenu
        Self.logger.debug("Rebuilt the history search menu with \(rows.count) rows")
    }

    private func menuItem(for row: HistorySearchMenuRow) -> NSMenuItem {
        switch row {
        case let .mode(mode, isSelected):
            let pbMode = PBSearchModeForInteger(mode.rawValue)
            let item = NSMenuItem(title: Self.label(for: pbMode), action: #selector(selectSearchMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = isSelected ? .on : .off
            return item
        case .separator:
            return .separator()
        case .savedSearchesHeader:
            return Self.headerItem(NSLocalizedString("Saved Searches", comment: "Searches menu: saved searches section title"))
        case let .savedSearch(search):
            let item = NSMenuItem(title: search.name, action: #selector(selectSavedSearch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = search.id.uuidString
            item.toolTip = Self.title(of: search.query, text: search.query.text)
            item.identifier = NSUserInterfaceItemIdentifier("GitX.History.Search.Saved.\(search.name)")
            return item
        case .noSavedSearches:
            return Self.headerItem(NSLocalizedString("No Saved Searches", comment: "Searches menu: no saved searches"))
        case .saveSearchAs:
            return actionItem(
                NSLocalizedString("Save Search As…", comment: "Searches menu: save the current search"),
                action: #selector(saveSearchAs(_:)),
                identifier: "GitX.History.Search.SaveAs"
            )
        case .manageSavedSearches:
            return actionItem(
                NSLocalizedString("Manage Saved Searches…", comment: "Searches menu: open the saved searches sheet"),
                action: #selector(manageSavedSearches(_:)),
                identifier: "GitX.History.Search.ManageSaved"
            )
        case .recentSearchesHeader:
            return Self.headerItem(NSLocalizedString(
                "Recent Searches",
                comment: "Searches menu: title of inactive headline item for Recent Searches section"
            ))
        case let .recentSearch(index, query):
            let item = NSMenuItem(title: Self.title(of: query, text: HistorySearchMenu.displayText(for: query.text)), action: #selector(selectRecentSearch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: index)
            item.toolTip = query.text
            item.identifier = NSUserInterfaceItemIdentifier("GitX.History.Search.Recent.\(index)")
            return item
        case .noRecentSearches:
            return Self.headerItem(NSLocalizedString(
                "No Recent Searches",
                comment: "Searches menu: title of dummy item displayed in recent searches section when there are no recent searches"
            ))
        case .clearRecentSearches:
            return actionItem(
                NSLocalizedString("Clear Recent Searches", comment: "Searches menu: title of clear recent searches item"),
                action: #selector(clearRecentSearches(_:)),
                identifier: "GitX.History.Search.ClearRecents"
            )
        }
    }

    private func actionItem(_ title: String, action: Selector, identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    /// "text — Mode", as the search menu lists a search.
    private static func title(of query: HistorySearchQuery, text: String) -> String {
        String(
            format: NSLocalizedString("%@ — %@", comment: "Searches menu: a search, as its text and its mode"),
            text,
            label(for: PBSearchModeForInteger(query.mode.rawValue))
        )
    }

    /// An inactive menu item: menus disable items that have no action.
    private static func headerItem(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private static func coreMode(_ mode: PBHistorySearchMode) -> HistorySearchMode {
        HistorySearchPolicy.validatedMode(rawValue: mode.rawValue)
    }

    private func setupModePopUp() {
        guard let modePopUp else { return }
        modePopUp.removeAllItems()
        for mode in Self.menuModes {
            modePopUp.addItem(withTitle: Self.label(for: mode))
            modePopUp.lastItem?.tag = mode.rawValue
        }
        modePopUp.target = self
        modePopUp.action = #selector(selectSearchMode(_:))
        modePopUp.setAccessibilityIdentifier("GitX.History.SearchMode")
        modePopUp.setAccessibilityLabel(
            NSLocalizedString("Search Mode", comment: "Accessibility label of the history search mode pop-up button")
        )
        modePopUp.toolTip = NSLocalizedString(
            "Choose what the search field matches",
            comment: "Tooltip of the history search mode pop-up button"
        )
        modePopUp.sizeToFit()
    }

    private func updateSearchMenuState() {
        if let modePopUp, modePopUp.selectedTag() != searchMode.rawValue {
            modePopUp.selectItem(withTag: searchMode.rawValue)
            modePopUp.sizeToFit()
        }
        guard let searchFieldCell, let searchMenu = searchFieldCell.searchMenuTemplate else { return }
        for mode in Self.menuModes {
            searchMenu.item(withTag: mode.rawValue)?.state = mode == searchMode ? .on : .off
        }
        searchFieldCell.searchMenuTemplate = searchMenu
    }

    private func updateSearchPlaceholderString() {
        searchFieldCell?.placeholderString = Self.label(for: searchMode)
    }

    private var searchFieldCell: NSSearchFieldCell? {
        searchField?.cell as? NSSearchFieldCell
    }

    /// The commit list's rows, read without bridging the whole array on every step.
    private var arrangedObjects: NSArray {
        (commitController?.arrangedObjects as? NSArray) ?? []
    }

    private static func label(for mode: PBHistorySearchMode) -> String {
        switch mode {
        case .pickaxe:
            NSLocalizedString("Commit (pickaxe)", comment: "Option in Search menu to use the pickaxe search")
        case .regex:
            NSLocalizedString(
                "Commit (pickaxe regex)",
                comment: "Option in Search menu to use the pickaxe search with regular expressions"
            )
        case .path:
            NSLocalizedString("File path", comment: "Option in Search menu to search for file paths in the commit")
        case .raw:
            NSLocalizedString("Raw", comment: "Option in Search menu to search for raw git log options")
        default:
            NSLocalizedString("Subject, Author, SHA", comment: "Option in Search menu to search for subject, author or SHA")
        }
    }

    // MARK: Progress

    @objc private func searchTimerFired(_: Timer) {
        progressIndicator?.isHidden = false
        progressIndicator?.startAnimation(self)
    }

    private func clearProgressIndicator() {
        searchTimer?.invalidate()
        searchTimer = nil
        progressIndicator?.isHidden = true
        progressIndicator?.stopAnimation(self)
    }

    private func startProgressIndicator() {
        clearProgressIndicator()
        numberOfMatchesField?.isHidden = true
        stepper?.isHidden = true
        searchTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(searchTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    // MARK: Basic search

    private func startBasicSearch() {
        numberOfMatchesField?.toolTip = nil
        let searchString = searchField?.stringValue ?? ""
        guard !searchString.isEmpty else {
            clearSearch()
            return
        }

        let searchPredicate = NSPredicate(
            format: "subject CONTAINS[cd] %@ OR author CONTAINS[cd] %@ OR SHA BEGINSWITH[c] %@",
            searchString,
            searchString,
            searchString
        )
        var matchingRows = IndexSet()
        for (row, commit) in arrangedObjects.enumerated() where searchPredicate.evaluate(with: commit) {
            matchingRows.insert(row)
        }
        results = matchingRows
        updateSelectedResult()
    }

    // MARK: Background search

    private func startBackgroundSearch() {
        backgroundSearchTask?.terminate()

        let plan = HistorySearchPolicyAdapter.plan(query: searchField?.stringValue ?? "", mode: searchMode.rawValue)
        switch plan.kind {
        case .clear:
            clearSearch()
            return
        case .invalid:
            showInvalidSearchPlan(plan)
            return
        case .basic:
            return
        case .background:
            break
        }

        results = nil
        numberOfMatchesField?.toolTip = plan.message
        Self.logger.info("Starting background history search with \(plan.arguments.count, privacy: .public) Git arguments")
        let searchString = plan.query
        guard let repository = historyController?.repository else { return }

        let task = repository.task(withArguments: plan.arguments)
        backgroundSearchTask = task
        task.perform(completionHandler: { [weak self, weak task] readData, taskError in
            guard let self else { return }
            // A newer search or a malformed query replaced this one; its results no longer apply,
            // even when it exited successfully before the termination signal arrived.
            guard let task, self.backgroundSearchTask === task else {
                Self.logger.info("Ignoring the result of a superseded history search")
                return
            }
            if let taskError = taskError as NSError?,
               taskError.domain == PBTaskErrorDomain,
               taskError.code == Int(PBTaskErrorCode.caughtSignalError.rawValue)
            {
                // A newer search terminated this one.
                return
            }
            guard let readData else {
                self.clearProgressIndicator()
                Self.logger.error("Background history search failed: \(taskError?.localizedDescription ?? "", privacy: .public)")
                let description = NSLocalizedString(
                    "Search failed",
                    comment: "Search Controller - Background search failed error description"
                )
                let reason = String(
                    format: NSLocalizedString(
                        "The search for \"%@\" failed.",
                        comment: "Search Controller - Background search failed error reason"
                    ),
                    searchString
                )
                let error = NSError.pb_error(withDescription: description, failureReason: reason, underlyingError: taskError)
                self.historyController?.windowController?.showErrorSheet(error)
                return
            }
            self.parseBackgroundSearchResults(readData)
        })

        startProgressIndicator()
    }

    /// Malformed raw or path queries never start Git; the match field explains how to fix them.
    private func showInvalidSearchPlan(_ plan: HistorySearchPlan) {
        backgroundSearchTask = nil
        if results != nil {
            results = nil
            historyController?.commitList.reloadData()
        }
        clearProgressIndicator()
        numberOfMatchesField?.stringValue = plan.summary
        numberOfMatchesField?.toolTip = plan.message
        numberOfMatchesField?.isHidden = false
        stepper?.isHidden = true
        Self.logger.info("Rejected malformed history search: \(plan.summary, privacy: .public)")
        AccessibilityAnnouncer.announce("\(plan.summary). \(plan.message)", from: searchField)
    }

    private func parseBackgroundSearchResults(_ data: Data) {
        backgroundSearchTask = nil

        let output = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? ?? ""
        let matches = Set(output.components(separatedBy: "\n").compactMap { GTOID(sha: $0) })
        var matchingRows = IndexSet()
        for (row, object) in arrangedObjects.enumerated() {
            if let oid = (object as? PBGitCommit)?.oid, matches.contains(oid) {
                matchingRows.insert(row)
            }
        }
        results = matchingRows
        Self.logger.debug("Background history search matched \(matchingRows.count, privacy: .public) loaded commits")
        clearProgressIndicator()
        updateSelectedResult()
    }

    // MARK: Rewind panel

    @objc private func closeRewindPanel() {
        if let rewindPanel {
            historyController?.view.window?.removeChildWindow(rewindPanel)
        }
        rewindPanel?.close()
        rewindPanel = nil
    }

    private func makeRewindPanel() -> NSPanel {
        // Recompute the frame each time in case the window was resized.
        let size = Self.rewindPanelSize
        let windowFrame = historyController?.view.window?.frame ?? .zero
        var historyFrame = NSRect.zero
        if let historyView = historyController?.view, let contentView = historyView.window?.contentView {
            historyFrame = contentView.convert(historyView.frame, from: historyView)
        }
        let panelRect = NSRect(
            x: windowFrame.origin.x + historyFrame.origin.x + (historyFrame.size.width - size) / 2,
            y: windowFrame.origin.y + historyFrame.origin.y + (historyFrame.size.height - size) / 2,
            width: size,
            height: size
        )

        let panel = NSPanel(contentRect: panelRect, styleMask: .borderless, backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0

        let overlay = RewindOverlayView(frame: panel.contentView?.frame ?? .zero)
        panel.contentView?.addSubview(overlay)

        let imageSize = NSImage(named: "rewindImage")?.size ?? .zero
        let imageView = NSImageView(frame: NSRect(
            x: (overlay.bounds.width - imageSize.width) / 2,
            y: (overlay.bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        ))
        imageView.tag = Self.rewindPanelImageViewTag
        overlay.addSubview(imageView)
        return panel
    }

    private static func rewindPanelFadeOutAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation()
        animation.duration = 1
        animation.values = [1.0, 1.0, 0.0, 0.0]
        animation.keyTimes = [0.1, 0.3, 0.7, NSNumber(value: animation.duration)]
        return animation
    }

    private func showSearchRewindPanel(reversed isReversed: Bool) {
        let panel: NSPanel
        if let rewindPanel {
            // The panel is still fading; cancel its pending close.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closeRewindPanel), object: nil)
            panel = rewindPanel
        } else {
            panel = makeRewindPanel()
            rewindPanel = panel
            historyController?.view.window?.addChildWindow(panel, ordered: .above)
        }
        Self.logger.debug("History search wrapped \(isReversed ? "backwards" : "forwards", privacy: .public)")

        // Point the wrap image in the direction the search wrapped.
        let rewindImage = NSImage(named: "rewindImage")
        let directionalImage = NSImage(size: rewindImage?.size ?? .zero, flipped: isReversed) { destination in
            rewindImage?.draw(in: destination, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        (panel.contentView?.viewWithTag(Self.rewindPanelImageViewTag) as? NSImageView)?.image = directionalImage

        panel.alphaValue = 1
        panel.animations = ["alphaValue": Self.rewindPanelFadeOutAnimation()]
        panel.animator().alphaValue = 0
        perform(#selector(closeRewindPanel), with: nil, afterDelay: 0.7)
    }

    // MARK: Main-thread delivery

    /// Key-value observation reports on the thread that changed the commit list, which is main in practice.
    private nonisolated func clearSearchOnMain() {
        if Thread.isMainThread {
            // swift6-safety-justification: The main-thread check proves synchronous execution is on MainActor's AppKit executor.
            MainActor.assumeIsolated { clearSearch() }
        } else {
            Task { @MainActor [weak self] in self?.clearSearch() }
        }
    }
}

extension PBHistorySearchController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveSearchAs(_:)):
            HistorySearchMenu.canSaveSearch(currentQuery)
        case #selector(manageSavedSearches(_:)):
            HistorySearchMenu.canManageSavedSearches(searchStore.library)
        default:
            true
        }
    }
}

extension PBHistorySearchController: NSSearchFieldDelegate {
    /// Return submits the search and remembers it; typing alone does not add recent searches.
    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            recordCurrentSearch()
        }
        return false
    }
}

// swiftlint:enable unused_declaration
