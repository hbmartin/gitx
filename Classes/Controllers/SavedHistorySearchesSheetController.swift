import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// The Manage Saved Searches sheet: lists the app-wide saved searches, renames them in place, removes them and
/// runs one in the window that opened the sheet.
final class SavedHistorySearchesSheetController: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "HistorySearch")
    private static let nameColumn = NSUserInterfaceItemIdentifier("GitX.SavedSearches.NameColumn")
    private static let modeColumn = NSUserInterfaceItemIdentifier("GitX.SavedSearches.ModeColumn")
    private static let queryColumn = NSUserInterfaceItemIdentifier("GitX.SavedSearches.QueryColumn")

    private let store: SavedHistorySearchStore
    private let modeLabel: (HistorySearchMode) -> String
    private let onApply: (SavedHistorySearch) -> Void
    private let notificationCenter: NotificationCenter
    let panel: NSPanel
    let tableView = NSTableView()
    let removeButton = NSButton()
    let applyButton = NSButton()
    let doneButton = NSButton()
    let messageField = NSTextField(wrappingLabelWithString: "")
    private(set) var searches: [SavedHistorySearch] = []
    private weak var hostWindow: NSWindow?
    /// Keeps the controller alive while its sheet is open.
    private var presentedSelf: SavedHistorySearchesSheetController?

    init(
        store: SavedHistorySearchStore,
        modeLabel: @escaping (HistorySearchMode) -> String,
        notificationCenter: NotificationCenter = .default,
        onApply: @escaping (SavedHistorySearch) -> Void
    ) {
        self.store = store
        self.modeLabel = modeLabel
        self.notificationCenter = notificationCenter
        self.onApply = onApply
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        buildInterface()
    }

    func present(for window: NSWindow) {
        hostWindow = window
        presentedSelf = self
        reload()
        notificationCenter.addObserver(
            self,
            selector: #selector(savedSearchesDidChange(_:)),
            name: .savedHistorySearchesDidChange,
            object: nil
        )
        let count = searches.count
        Self.logger.info("Showing \(count) saved history searches")
        window.beginSheet(panel) { [self] _ in
            notificationCenter.removeObserver(self, name: .savedHistorySearchesDidChange, object: nil)
            presentedSelf = nil
        }
    }

    // MARK: Interface

    private func buildInterface() {
        panel.title = NSLocalizedString("Saved Searches", comment: "Manage Saved Searches sheet: title")
        panel.minSize = NSSize(width: 420, height: 220)
        panel.setAccessibilityIdentifier("GitX.SavedSearches.Sheet")

        let title = NSTextField(labelWithString: NSLocalizedString(
            "Saved searches are shared by every repository window.",
            comment: "Manage Saved Searches sheet: explanation"
        ))
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = .secondaryLabelColor

        addColumn(Self.nameColumn, title: NSLocalizedString("Name", comment: "Saved Searches column"), width: 150)
        addColumn(Self.modeColumn, title: NSLocalizedString("Mode", comment: "Saved Searches column"), width: 130)
        addColumn(Self.queryColumn, title: NSLocalizedString("Search", comment: "Saved Searches column"), width: 220)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(applySelected(_:))
        tableView.setAccessibilityIdentifier("GitX.SavedSearches.Table")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        removeButton.bezelStyle = .smallSquare
        removeButton.image = NSImage(named: NSImage.removeTemplateName)
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.setAccessibilityIdentifier("GitX.SavedSearches.Remove")
        removeButton.setAccessibilityLabel(NSLocalizedString("Remove Saved Search", comment: "Saved Searches remove button"))
        removeButton.toolTip = NSLocalizedString("Remove the selected saved search", comment: "Saved Searches remove button")

        messageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageField.textColor = .systemRed
        messageField.isHidden = true
        messageField.setAccessibilityIdentifier("GitX.SavedSearches.Message")

        configure(applyButton, title: NSLocalizedString("Search", comment: "Saved Searches: run the selected search"),
                  action: #selector(applySelected(_:)), identifier: "GitX.SavedSearches.Apply")
        configure(doneButton, title: NSLocalizedString("Done", comment: "Saved Searches: close the sheet"),
                  action: #selector(done(_:)), identifier: "GitX.SavedSearches.Done")
        doneButton.keyEquivalent = "\r"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setViews([removeButton], in: .leading)
        buttons.setViews([applyButton, doneButton], in: .trailing)
        let content = NSStackView(views: [title, scrollView, messageField, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            messageField.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
        ])
        panel.contentView = contentView
    }

    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = 60
        tableView.addTableColumn(column)
    }

    private func configure(_ button: NSButton, title: String, action: Selector, identifier: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    // MARK: State

    @objc private func savedSearchesDidChange(_: Notification) {
        reload()
    }

    private func reload() {
        let selectedID = selectedSearch?.id
        searches = store.library.searches
        tableView.reloadData()
        if let selectedID, let row = searches.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedSearch: SavedHistorySearch? {
        searches.indices.contains(tableView.selectedRow) ? searches[tableView.selectedRow] : nil
    }

    private func updateButtons() {
        removeButton.isEnabled = selectedSearch != nil
        applyButton.isEnabled = selectedSearch != nil
    }

    private func show(_ message: String?) {
        messageField.stringValue = message ?? ""
        messageField.isHidden = message == nil
        if let message {
            AccessibilityAnnouncer.announce(message, from: messageField)
        }
    }

    // MARK: Actions

    @objc func removeSelected(_: Any?) {
        guard let search = selectedSearch else { return }
        switch store.remove(id: search.id) {
        case .success:
            show(nil)
        case let .failure(issue):
            show(issue.message)
        }
    }

    @objc func applySelected(_: Any?) {
        guard let search = selectedSearch else { return }
        Self.logger.info("Running saved history search \(search.name, privacy: .private) from the Saved Searches sheet")
        close()
        onApply(search)
    }

    @objc func done(_: Any?) {
        close()
    }

    private func close() {
        hostWindow?.endSheet(panel)
        panel.orderOut(nil)
    }

    /// Renames the search on `row`; a refused name is explained and the old name comes back.
    func rename(row: Int, to name: String) {
        guard searches.indices.contains(row) else { return }
        let search = searches[row]
        guard name != search.name else { return }
        switch store.rename(id: search.id, to: name) {
        case .success:
            show(nil)
        case let .failure(issue):
            show(issue.message)
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }
}

extension SavedHistorySearchesSheetController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        searches.count
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, searches.indices.contains(row) else { return nil }
        let search = searches[row]
        let field: NSTextField
        switch tableColumn.identifier {
        case Self.nameColumn:
            field = NSTextField(string: search.name)
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.delegate = self
            field.setAccessibilityIdentifier("GitX.SavedSearches.Name.\(row)")
        case Self.modeColumn:
            field = NSTextField(labelWithString: modeLabel(search.query.mode))
        default:
            field = NSTextField(labelWithString: HistorySearchMenu.displayText(for: search.query.text))
            field.toolTip = search.query.text
        }
        field.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.textField = field
        cell.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateButtons()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        rename(row: tableView.row(for: field), to: field.stringValue)
    }
}
