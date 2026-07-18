import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBRecentRepositoryActivationAction)
enum RecentRepositoryActivationAction: Int {
    case open
    case locate
}

@objc(PBRecentRepositoryActivationPolicy)
final nonisolated class RecentRepositoryActivationPolicy: NSObject {
    @objc(actionForReachable:)
    static func action(forReachable reachable: Bool) -> RecentRepositoryActivationAction {
        reachable ? .open : .locate
    }
}

@objc(PBRecentRepositoryStore)
final class RecentRepositoryStore: NSObject {
    private static let key = "PBRecentRepositories"
    @objc static let shared = RecentRepositoryStore()

    struct Entry {
        let url: URL
        let lastOpened: Date
        var isReachable: Bool {
            (try? url.checkResourceIsReachable()) == true
        }
    }

    func entries() -> [Entry] {
        var values: [String: Date] = [:]
        for record in UserDefaults.standard.array(forKey: Self.key) as? [[String: Any]] ?? [] {
            guard let path = record["path"] as? String else { continue }
            values[URL(fileURLWithPath: path).standardizedFileURL.path] = record["lastOpened"] as? Date ?? .distantPast
        }
        for (index, url) in NSDocumentController.shared.recentDocumentURLs.enumerated() {
            let path = url.standardizedFileURL.path
            if values[path] == nil {
                values[path] = Date().addingTimeInterval(TimeInterval(-index))
            }
        }
        return values.map { Entry(url: URL(fileURLWithPath: $0.key), lastOpened: $0.value) }
            .sorted { left, right in
                if left.lastOpened != right.lastOpened {
                    return left.lastOpened > right.lastOpened
                }
                return left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
            }
            .prefix(20)
            .map { $0 }
    }

    @objc func record(_ url: URL) {
        var entries = entries().filter { $0.url.standardizedFileURL != url.standardizedFileURL }
        entries.insert(Entry(url: url.standardizedFileURL, lastOpened: Date()), at: 0)
        persist(entries: Array(entries.prefix(20)))
    }

    @objc func remove(_ url: URL) {
        persist(entries: entries().filter { $0.url.standardizedFileURL != url.standardizedFileURL })
    }

    @objc func replace(_ oldURL: URL, with newURL: URL) {
        remove(oldURL)
        record(newURL)
    }

    private func persist(entries: [Entry]) {
        UserDefaults.standard.set(entries.map {
            ["path": $0.url.standardizedFileURL.path, "lastOpened": $0.lastOpened]
        }, forKey: Self.key)
    }
}

@objc(PBRepositoryOpenCoordinator)
final class RepositoryOpenCoordinator: NSObject {
    @objc static let shared = RepositoryOpenCoordinator()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryOpening")

    @objc(openURLs:sourceWindow:completion:)
    func open(
        urls: [URL],
        sourceWindow: NSWindow?,
        completion: @escaping ([NSDocument], [NSError]) -> Void
    ) {
        let disposition = resolvedDisposition(for: NSApp.currentEvent?.modifierFlags ?? [])
        open(urls: urls, sourceWindow: sourceWindow, disposition: disposition, completion: completion)
    }

    func open(
        urls: [URL],
        sourceWindow: NSWindow?,
        disposition: OpenDisposition,
        completion: @escaping ([NSDocument], [NSError]) -> Void
    ) {
        let canonical = urls.compactMap { PBRepositoryFinder.fileURL(for: $0) ?? $0.standardizedFileURL }
        var documents: [NSDocument] = []
        var errors: [NSError] = []
        var tabTarget = eligibleRepositoryWindow(preferred: sourceWindow)

        func openNext(_ index: Int) {
            guard canonical.indices.contains(index) else {
                completion(documents, errors)
                return
            }
            let url = canonical[index]
            if let existing = existingDocument(for: url) {
                existing.showWindows()
                existing.windowControllers.first?.window?.makeKeyAndOrderFront(self)
                documents.append(existing)
                RecentRepositoryStore.shared.record(url)
                logger.info("Focused an already-open repository")
                openNext(index + 1)
                return
            }

            NSDocumentController.shared.openDocument(
                withContentsOf: url,
                display: true
            ) { document, _, error in
                if let document {
                    documents.append(document)
                    RecentRepositoryStore.shared.record(url)
                    if let newWindow = document.windowControllers.first?.window {
                        if self.shouldUseTab(disposition), let tabTarget, tabTarget != newWindow {
                            tabTarget.addTabbedWindow(newWindow, ordered: .above)
                            newWindow.makeKeyAndOrderFront(nil)
                            self.logger.info("Opened repository as a tab")
                        } else {
                            newWindow.tabbingMode = .disallowed
                            newWindow.makeKeyAndOrderFront(nil)
                            self.logger.info("Opened repository in a window")
                        }
                        if tabTarget == nil {
                            tabTarget = newWindow
                        }
                    }
                    WelcomeWindowController.shared.closeWelcome()
                } else if let error {
                    errors.append(error as NSError)
                }
                openNext(index + 1)
            }
        }
        openNext(0)
    }

    private func resolvedDisposition(for modifiers: NSEvent.ModifierFlags) -> OpenDisposition {
        if modifiers.contains(.option) {
            return .alwaysNewWindow
        }
        if modifiers.contains(.command) {
            return .preferTab
        }
        return ApplicationSettings.openDisposition
    }

    private func shouldUseTab(_ disposition: OpenDisposition) -> Bool {
        switch disposition {
        case .alwaysNewWindow:
            false
        case .preferTab:
            true
        case .followSystem:
            NSWindow.userTabbingPreference == .always
        }
    }

    private func eligibleRepositoryWindow(preferred: NSWindow?) -> NSWindow? {
        if preferred?.windowController is PBGitWindowController {
            return preferred
        }
        if NSApp.keyWindow?.windowController is PBGitWindowController {
            return NSApp.keyWindow
        }
        return NSApp.windows.first { $0.windowController is PBGitWindowController && $0.isVisible }
    }

    private func existingDocument(for url: URL) -> NSDocument? {
        NSDocumentController.shared.documents.first {
            $0.fileURL?.standardizedFileURL == url.standardizedFileURL
        }
    }
}

@objc(PBWelcomeWindowController)
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    @objc static let shared = WelcomeWindowController()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var allEntries: [RecentRepositoryStore.Entry] = []
    private var shownEntries: [RecentRepositoryStore.Entry] = []
    private let dateFormatter = DateFormatter()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to GitX"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func show() {
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showIfNeeded() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        show()
    }

    @objc func showIfNeededAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showIfNeeded()
        }
    }

    @objc func closeWelcome() {
        window?.orderOut(nil)
    }

    private func configureContent() {
        guard let root = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Open a Recent Repository")
        title.font = .preferredFont(forTextStyle: .title1, options: [:])
        title.setAccessibilityIdentifier("WelcomeTitle")
        let subtitle = NSTextField(labelWithString: "Search your 20 most recently opened repositories.")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, NSStackView(views: [title, subtitle])])
        (heading.arrangedSubviews[1] as? NSStackView)?.orientation = .vertical
        (heading.arrangedSubviews[1] as? NSStackView)?.alignment = .leading
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 14
        heading.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Repository name or path"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("WelcomeSearch")

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Repository"
        nameColumn.width = 240
        let parentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("parent"))
        parentColumn.title = "Location"
        parentColumn.width = 260
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Last Opened"
        dateColumn.width = 140
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(parentColumn)
        tableView.addTableColumn(dateColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.setAccessibilityIdentifier("WelcomeRecents")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "Open…", target: self, action: #selector(chooseRepository(_:)))
        let clone = NSButton(title: "Clone…", target: self, action: #selector(cloneRepository(_:)))
        let locate = NSButton(title: "Locate Missing…", target: self, action: #selector(locateSelected(_:)))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelected(_:)))
        let actions = NSStackView(views: [open, clone, NSView(), locate, remove])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setHuggingPriority(.defaultLow, for: .horizontal)

        root.addSubview(heading)
        root.addSubview(searchField)
        root.addSubview(scroll)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            searchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
    }

    private func refresh() {
        allEntries = RecentRepositoryStore.shared.entries()
        applyFilter()
    }

    @objc private func searchChanged(_ sender: Any?) {
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shownEntries = query.isEmpty ? allEntries : allEntries.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) ||
                $0.url.deletingLastPathComponent().path.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
        if !shownEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shownEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shownEntries.indices.contains(row), let tableColumn else { return nil }
        let entry = shownEntries[row]
        let value: String
        switch tableColumn.identifier.rawValue {
        case "name": value = entry.url.lastPathComponent
        case "parent": value = entry.url.deletingLastPathComponent().path
        case "date": value = dateFormatter.string(from: entry.lastOpened)
        default: value = ""
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = tableColumn.identifier.rawValue == "parent" ? .byTruncatingHead : .byTruncatingTail
        field.textColor = entry.isReachable ? .labelColor : .tertiaryLabelColor
        field.toolTip = entry.url.path
        field.setAccessibilityLabel(entry.url.path)
        return field
    }

    @objc private func openSelected(_ sender: Any?) {
        guard shownEntries.indices.contains(tableView.selectedRow) else { return }
        let entry = shownEntries[tableView.selectedRow]
        if RecentRepositoryActivationPolicy.action(forReachable: entry.isReachable) == .locate {
            locateSelected(sender)
            return
        }
        RepositoryOpenCoordinator.shared.open(urls: [entry.url], sourceWindow: window) { _, errors in
            if let error = errors.first {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func chooseRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RepositoryOpenCoordinator.shared.open(urls: [url], sourceWindow: window) { _, errors in
            if let error = errors.first {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func cloneRepository(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("showCloneRepository:"), to: nil, from: sender)
    }

    @objc private func locateSelected(_ sender: Any?) {
        guard shownEntries.indices.contains(tableView.selectedRow) else { return }
        let oldURL = shownEntries[tableView.selectedRow].url
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        guard panel.runModal() == .OK, let newURL = panel.url else { return }
        RecentRepositoryStore.shared.replace(oldURL, with: newURL)
        refresh()
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard shownEntries.indices.contains(tableView.selectedRow) else { return }
        RecentRepositoryStore.shared.remove(shownEntries[tableView.selectedRow].url)
        refresh()
    }
}

@objc(PBWindowSessionCoordinator)
final class WindowSessionCoordinator: NSObject {
    @objc static let shared = WindowSessionCoordinator()
    private static let snapshotKey = "PBWindowSessionSnapshot"
    private static let cleanShutdownKey = "PBWindowSessionCleanShutdown"
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "WindowSession")

    @objc func applicationDidFinishLaunching() {
        let defaults = UserDefaults.standard
        let previousRunWasClean = defaults.object(forKey: Self.cleanShutdownKey) == nil || defaults.bool(forKey: Self.cleanShutdownKey)
        defaults.set(false, forKey: Self.cleanShutdownKey)
        guard ProcessInfo.processInfo.environment["GITX_UITEST_REPO"] == nil else { return }
        guard NSDocumentController.shared.documents.isEmpty else { return }

        if !previousRunWasClean, !snapshot().isEmpty {
            WelcomeWindowController.shared.show()
            let alert = NSAlert()
            alert.messageText = "Restore Windows from the Previous Session?"
            alert.informativeText = "GitX did not finish closing normally. You can reopen the saved repository windows and tabs."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Don’t Restore")
            if let welcome = WelcomeWindowController.shared.window {
                alert.beginSheetModal(for: welcome) { response in
                    if response == .alertFirstButtonReturn {
                        self.restore()
                    } else {
                        self.clearSnapshot()
                    }
                }
            }
            return
        }

        if shouldRestore() {
            restore()
        } else {
            WelcomeWindowController.shared.showIfNeeded()
        }
    }

    @objc func applicationWillTerminate() {
        capture()
        UserDefaults.standard.set(true, forKey: Self.cleanShutdownKey)
    }

    @objc func capture() {
        var records: [[String: Any]] = []
        var groupIdentifiers: [ObjectIdentifier: Int] = [:]
        var nextGroup = 0
        for document in NSDocumentController.shared.documents {
            guard let url = document.fileURL,
                  let controller = document.windowControllers.first as? PBGitWindowController,
                  let window = controller.window else { continue }
            let groupWindows = window.tabbedWindows ?? [window]
            let groupKey = ObjectIdentifier(groupWindows.first ?? window)
            let group = groupIdentifiers[groupKey] ?? {
                defer { nextGroup += 1 }
                groupIdentifiers[groupKey] = nextGroup
                return nextGroup
            }()
            records.append([
                "path": url.standardizedFileURL.path,
                "frame": NSStringFromRect(window.frame),
                "group": group,
                "order": groupWindows.firstIndex(of: window) ?? 0,
                "commitMode": controller.isShowingCommitView,
                "active": window.isKeyWindow,
            ])
        }
        UserDefaults.standard.set(records, forKey: Self.snapshotKey)
        logger.info("Captured repository window topology")
    }

    private func shouldRestore() -> Bool {
        switch ApplicationSettings.restorePolicy {
        case .always: true
        case .never: false
        case .followSystem:
            UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true
        }
    }

    private func snapshot() -> [[String: Any]] {
        UserDefaults.standard.array(forKey: Self.snapshotKey) as? [[String: Any]] ?? []
    }

    private func restore() {
        let reachable = snapshot().filter {
            guard let path = $0["path"] as? String else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        UserDefaults.standard.set(reachable, forKey: Self.snapshotKey)
        guard !reachable.isEmpty else {
            WelcomeWindowController.shared.showIfNeeded()
            return
        }
        let groups = Dictionary(grouping: reachable) { $0["group"] as? Int ?? 0 }
        let orderedGroups = groups.keys.sorted()

        func restoreGroup(_ groupIndex: Int) {
            guard orderedGroups.indices.contains(groupIndex) else { return }
            let records = (groups[orderedGroups[groupIndex]] ?? []).sorted {
                ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0)
            }
            var groupWindow: NSWindow?

            func restoreRecord(_ recordIndex: Int) {
                guard records.indices.contains(recordIndex) else {
                    restoreGroup(groupIndex + 1)
                    return
                }
                guard let path = records[recordIndex]["path"] as? String else {
                    restoreRecord(recordIndex + 1)
                    return
                }
                RepositoryOpenCoordinator.shared.open(
                    urls: [URL(fileURLWithPath: path)],
                    sourceWindow: nil,
                    disposition: .alwaysNewWindow
                ) { documents, _ in
                    if let controller = documents.first?.windowControllers.first as? PBGitWindowController,
                       let window = controller.window
                    {
                        if let frame = records[recordIndex]["frame"] as? String {
                            window.setFrame(NSRectFromString(frame), display: false)
                        }
                        if records[recordIndex]["commitMode"] as? Bool == true {
                            controller.showCommitView(self)
                        } else {
                            controller.showHistoryView(self)
                        }
                        if let groupWindow, groupWindow != window {
                            groupWindow.addTabbedWindow(window, ordered: .above)
                        } else {
                            groupWindow = window
                        }
                        if records[recordIndex]["active"] as? Bool == true {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    restoreRecord(recordIndex + 1)
                }
            }
            restoreRecord(0)
        }
        restoreGroup(0)
        logger.info("Restoring repository window topology")
    }

    private func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        WelcomeWindowController.shared.showIfNeeded()
    }
}
