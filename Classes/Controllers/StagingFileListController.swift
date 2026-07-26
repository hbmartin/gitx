import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Builds and drives the staging pane's file lists. The split-tables layout
/// stacks a Staged section above an Unstaged section, each with a master
/// checkbox header, and reuses CommitTableInteractionCoordinator for Space,
/// double-click, and drag interactions.
@objc(PBStagingFileListController)
final class StagingFileListController: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("StagingFileCell")

    @objc let view: NSView
    @objc let viewModel: StagingListViewModel
    @objc let unstagedFilesController: NSArrayController
    @objc let stagedFilesController: NSArrayController
    @objc let unstagedTable: PBFileChangesTableView
    @objc let stagedTable: PBFileChangesTableView
    @objc let interactionCoordinator: CommitTableInteractionCoordinator

    /// Fired (coalesced upstream) whenever either list's selection changes.
    @objc var onSelectionChange: (() -> Void)?

    private nonisolated(unsafe) static var selectionContext = 0

    private let index: PBGitIndex
    private let stagedHeader = StagingSectionHeaderView(frame: .zero)
    private let unstagedHeader = StagingSectionHeaderView(frame: .zero)
    private var observingSelections = false

    @objc(initWithRepository:index:)
    init(repository: PBGitRepository, index: PBGitIndex) {
        self.index = index
        viewModel = StagingListViewModel()
        viewModel.sortOrder = ApplicationSettings.stagingFileSortOrder

        unstagedFilesController = NSArrayController()
        stagedFilesController = NSArrayController()
        for controller in [unstagedFilesController, stagedFilesController] {
            controller.automaticallyRearrangesObjects = false
            controller.preservesSelection = true
            controller.bind(
                NSBindingName.contentArray,
                to: index,
                withKeyPath: "indexChanges",
                options: nil
            )
        }

        unstagedTable = Self.makeTable(tag: 0, accessibilityIdentifier: "UnstagedFiles")
        stagedTable = Self.makeTable(tag: 1, accessibilityIdentifier: "StagedFiles")

        interactionCoordinator = CommitTableInteractionCoordinator(
            repository: repository,
            index: index,
            unstagedFilesController: unstagedFilesController,
            stagedFilesController: stagedFilesController,
            unstagedTable: unstagedTable,
            stagedTable: stagedTable
        )

        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autosaveName = "StagingFileLists"
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view = splitView

        super.init()

        splitView.addArrangedSubview(Self.makeSection(header: stagedHeader, table: stagedTable))
        splitView.addArrangedSubview(Self.makeSection(header: unstagedHeader, table: unstagedTable))

        stagedHeader.masterCheckbox.target = self
        stagedHeader.masterCheckbox.action = #selector(masterCheckboxToggled(_:))
        stagedHeader.masterCheckbox.tag = 1
        unstagedHeader.masterCheckbox.target = self
        unstagedHeader.masterCheckbox.action = #selector(masterCheckboxToggled(_:))
        unstagedHeader.masterCheckbox.tag = 0

        for table in [unstagedTable, stagedTable] {
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.doubleAction = #selector(didDoubleClickTable(_:))
            table.bind(NSBindingName.content, to: controller(for: table), withKeyPath: "arrangedObjects", options: nil)
            table.bind(
                NSBindingName.selectionIndexes,
                to: controller(for: table),
                withKeyPath: "selectionIndexes",
                options: nil
            )
        }
        unstagedTable.menu = Self.makeContextMenu(stagedContext: false)
        stagedTable.menu = Self.makeContextMenu(stagedContext: true)

        applyFilterAndSort()

        for controller in [unstagedFilesController, stagedFilesController] {
            controller.addObserver(self, forKeyPath: "selectionIndexes", options: [], context: &Self.selectionContext)
        }
        observingSelections = true
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &Self.selectionContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        // Array-controller selection only mutates on the main thread.
        MainActor.assumeIsolated {
            onSelectionChange?()
        }
    }

    @objc func close() {
        if observingSelections {
            for controller in [unstagedFilesController, stagedFilesController] {
                controller.removeObserver(self, forKeyPath: "selectionIndexes", context: &Self.selectionContext)
            }
            observingSelections = false
        }
        onSelectionChange = nil
        for table in [unstagedTable, stagedTable] {
            table.unbind(NSBindingName.content)
            table.unbind(NSBindingName.selectionIndexes)
        }
        for controller in [unstagedFilesController, stagedFilesController] {
            controller.unbind(NSBindingName.contentArray)
        }
    }

    /// Re-filters, re-sorts, and refreshes the section headers after an index
    /// update or a search/sort change.
    @objc func applyFilterAndSort() {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var unstagedPredicate = NSPredicate(format: "hasUnstagedChanges == 1")
        var stagedPredicate = NSPredicate(format: "hasStagedChanges == 1")
        if !query.isEmpty {
            let search = NSPredicate(format: "path CONTAINS[cd] %@", query)
            unstagedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [unstagedPredicate, search])
            stagedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [stagedPredicate, search])
        }
        unstagedFilesController.filterPredicate = unstagedPredicate
        stagedFilesController.filterPredicate = stagedPredicate

        let sortDescriptors: [NSSortDescriptor] = switch viewModel.sortOrder {
        case .status:
            [
                NSSortDescriptor(key: "status", ascending: false),
                NSSortDescriptor(key: "path", ascending: true),
            ]
        case .path:
            [NSSortDescriptor(key: "path", ascending: true)]
        }
        unstagedFilesController.sortDescriptors = sortDescriptors
        stagedFilesController.sortDescriptors = sortDescriptors

        rearrange()
    }

    @objc func rearrange() {
        unstagedFilesController.rearrangeObjects()
        stagedFilesController.rearrangeObjects()
        refreshHeaders()
    }

    @objc var stagedFileCount: Int {
        (stagedFilesController.arrangedObjects as? [Any])?.count ?? 0
    }

    @objc func clearSelections() {
        unstagedFilesController.setSelectionIndexes(IndexSet())
        stagedFilesController.setSelectionIndexes(IndexSet())
    }

    @objc(selectedFilesForStagedContext:)
    func selectedFiles(stagedContext: Bool) -> [PBChangedFile] {
        let controller = stagedContext ? stagedFilesController : unstagedFilesController
        return controller.selectedObjects as? [PBChangedFile] ?? []
    }

    @objc var currentDiffRequests: [StagingDiffRequest] {
        viewModel.diffRequests(
            stagedSelection: selectedFiles(stagedContext: true),
            unstagedSelection: selectedFiles(stagedContext: false)
        )
    }

    private func refreshHeaders() {
        let changes = index.indexChanges
        stagedHeader.configure(
            title: NSLocalizedString("Staged files", comment: "Header of the staged section in the staging file list"),
            fileCount: viewModel.files(in: .staged, from: changes).count,
            masterState: viewModel.masterCheckboxState(for: changes, in: .staged)
        )
        unstagedHeader.configure(
            title: NSLocalizedString("Unstaged files", comment: "Header of the unstaged section in the staging file list"),
            fileCount: viewModel.files(in: .unstaged, from: changes).count,
            masterState: viewModel.masterCheckboxState(for: changes, in: .unstaged)
        )
    }

    // MARK: Actions

    @objc private func didDoubleClickTable(_ sender: NSTableView) {
        interactionCoordinator.didDoubleClick(sender)
    }

    @objc private func masterCheckboxToggled(_ sender: NSButton) {
        let stagedContext = sender.tag == 1
        let controller = stagedContext ? stagedFilesController : unstagedFilesController
        guard let files = controller.arrangedObjects as? [PBChangedFile], !files.isEmpty else {
            refreshHeaders()
            return
        }
        if stagedContext {
            NSLog("[GitX] Unstaging all %ld staged file(s) from the master checkbox", files.count)
            index.unstageFiles(files)
        } else {
            NSLog("[GitX] Staging all %ld unstaged file(s) from the master checkbox", files.count)
            index.stageFiles(files)
        }
    }

    @objc private func rowCheckboxToggled(_ sender: NSButton) {
        guard let (table, file) = rowContext(for: sender) else { return }
        if table === stagedTable {
            NSLog("[GitX] Unstaging %@ from its row checkbox", file.path)
            index.unstageFiles([file])
        } else {
            NSLog("[GitX] Staging %@ from its row checkbox", file.path)
            index.stageFiles([file])
        }
    }

    @objc private func rowOverflowClicked(_ sender: NSButton) {
        guard let (table, _) = rowContext(for: sender), let menu = table.menu else { return }
        let row = table.row(for: sender)
        if row >= 0, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private func rowContext(for sender: NSView) -> (NSTableView, PBChangedFile)? {
        for table in [unstagedTable, stagedTable] {
            let row = table.row(for: sender)
            guard row >= 0 else { continue }
            guard let files = controller(for: table).arrangedObjects as? [PBChangedFile],
                  files.indices.contains(row)
            else { return nil }
            return (table, files[row])
        }
        return nil
    }

    private func controller(for table: NSTableView) -> NSArrayController {
        table.tag == 0 ? unstagedFilesController : stagedFilesController
    }

    // MARK: NSTableViewDelegate / DataSource

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let files = controller(for: tableView).arrangedObjects as? [PBChangedFile],
              files.indices.contains(row)
        else { return nil }
        let file = files[row]
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? StagingFileCellView
            ?? {
                let created = StagingFileCellView(frame: .zero)
                created.identifier = Self.cellIdentifier
                created.checkbox.target = self
                created.checkbox.action = #selector(rowCheckboxToggled(_:))
                created.overflowButton.target = self
                created.overflowButton.action = #selector(rowOverflowClicked(_:))
                return created
            }()
        let section: StagingListSection = tableView.tag == 1 ? .staged : .unstaged
        cell.configure(with: file, checkboxState: viewModel.rowCheckboxState(for: file, in: section))
        return cell
    }

    @objc func fileChangesTableViewDidRequestStagingToggle(_ tableView: PBFileChangesTableView) {
        interactionCoordinator.toggleStaging(for: tableView)
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        interactionCoordinator.writeRows(with: rowIndexes, from: tableView, to: pboard)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        interactionCoordinator.validateDrop(info, in: tableView)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        interactionCoordinator.acceptDrop(info, in: tableView)
    }

    // MARK: Construction helpers

    private static func makeTable(tag: Int, accessibilityIdentifier: String) -> PBFileChangesTableView {
        let table = PBFileChangesTableView(frame: .zero)
        table.tag = tag
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier(accessibilityIdentifier)
        return table
    }

    private static func makeSection(header: StagingSectionHeaderView, table: NSTableView) -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        return container
    }

    private static func makeContextMenu(stagedContext: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        func add(_ title: String, _ action: Selector, alternate: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if alternate {
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
            }
            menu.addItem(item)
        }
        if stagedContext {
            add(NSLocalizedString("Unstage Changes", comment: "Staging context menu item"), NSSelectorFromString("unstageFiles:"))
        } else {
            add(NSLocalizedString("Stage Changes", comment: "Staging context menu item"), NSSelectorFromString("stageFiles:"))
        }
        add(NSLocalizedString("Open Files", comment: "Staging context menu item"), NSSelectorFromString("openFiles:"))
        menu.addItem(.separator())
        add(NSLocalizedString("Ignore Files", comment: "Staging context menu item"), NSSelectorFromString("ignoreFiles:"))
        add(NSLocalizedString("Discard Changes…", comment: "Staging context menu item"), NSSelectorFromString("discardFiles:"))
        add(
            NSLocalizedString("Discard Changes", comment: "Staging context menu item (no confirmation)"),
            NSSelectorFromString("discardFilesForcibly:"),
            alternate: true
        )
        menu.addItem(.separator())
        add(NSLocalizedString("Reveal in Finder", comment: "Staging context menu item"), NSSelectorFromString("revealInFinder:"))
        add(NSLocalizedString("Move to Trash…", comment: "Staging context menu item"), NSSelectorFromString("moveToTrash:"))
        return menu
    }
}

// swiftlint:enable unused_declaration
