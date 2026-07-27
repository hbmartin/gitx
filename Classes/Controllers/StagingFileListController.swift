import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Builds and drives the staging pane's file lists in both user-selectable
/// layouts. The split-tables layout stacks a Staged section above an Unstaged
/// section and reuses CommitTableInteractionCoordinator for Space,
/// double-click, and drag interactions. The sectioned-list layout renders one
/// continuous table whose selection is mirrored into the same two array
/// controllers, so diff rendering and menu actions behave identically.
@objc(PBStagingFileListController)
final class StagingFileListController: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("StagingFileCell")
    private static let sectionHeaderIdentifier = NSUserInterfaceItemIdentifier("StagingSectionHeader")
    private static let sectionedDragType = NSPasteboard.PasteboardType("GitXStagingSectionedRows")

    @objc let view: NSView
    @objc let viewModel: StagingListViewModel
    @objc let unstagedFilesController: NSArrayController
    @objc let stagedFilesController: NSArrayController
    @objc let unstagedTable: PBFileChangesTableView
    @objc let stagedTable: PBFileChangesTableView
    @objc let sectionedTable: PBFileChangesTableView
    @objc let interactionCoordinator: CommitTableInteractionCoordinator
    @objc private(set) var layout: StagingListLayout

    /// Fired (coalesced upstream) whenever either list's selection changes.
    @objc var onSelectionChange: (() -> Void)?

    // swift6-safety-justification: The value is never read or written; only its
    // stable address distinguishes this class's KVO registrations.
    private nonisolated(unsafe) static var selectionContext = 0

    private let index: PBGitIndex
    private let stagedHeader = StagingSectionHeaderView(frame: .zero)
    private let unstagedHeader = StagingSectionHeaderView(frame: .zero)
    private let splitTablesView: NSSplitView
    private let sectionedScroll = NSScrollView()
    private var sectionedRows: [StagingListRow] = []
    private var syncingSectionedSelection = false
    private var syncingExclusiveSelection = false
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
        sectionedTable = Self.makeTable(tag: 2, accessibilityIdentifier: "PendingFiles")
        layout = ApplicationSettings.stagingListLayout

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
        splitTablesView = splitView

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        super.init()

        splitView.addArrangedSubview(Self.makeSection(header: stagedHeader, table: stagedTable))
        splitView.addArrangedSubview(Self.makeSection(header: unstagedHeader, table: unstagedTable))

        sectionedScroll.documentView = sectionedTable
        sectionedScroll.hasVerticalScroller = true
        sectionedScroll.autohidesScrollers = true
        sectionedScroll.translatesAutoresizingMaskIntoConstraints = false
        sectionedTable.delegate = self
        sectionedTable.dataSource = self
        sectionedTable.target = self
        sectionedTable.doubleAction = #selector(didDoubleClickTable(_:))
        sectionedTable.registerForDraggedTypes([Self.sectionedDragType])
        installLayoutView()

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
        sectionedTable.menu = Self.makeSectionedContextMenu()

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
        // swift6-safety-justification: NSArrayController selection only mutates
        // on the main thread, so this KVO callback always arrives there.
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
        rebuildSectionedRows()
        refreshHeaders()
    }

    // MARK: Layout switching

    @objc(setListLayout:)
    func setListLayout(_ newLayout: StagingListLayout) {
        guard newLayout != layout else { return }
        layout = newLayout
        ApplicationSettings.stagingListLayout = newLayout
        if newLayout == .splitTables,
           !stagedFilesController.selectionIndexes.isEmpty,
           !unstagedFilesController.selectionIndexes.isEmpty
        {
            syncingExclusiveSelection = true
            unstagedFilesController.setSelectionIndexes(IndexSet())
            syncingExclusiveSelection = false
            NSLog("[GitX] Preserved the staged side while restoring split-table selection exclusivity")
        }
        installLayoutView()
        rearrange()
        NSLog("[GitX] Staging file list layout switched to %@", newLayout == .sectionedList ? "sectioned list" : "split tables")
    }

    private func installLayoutView() {
        for subview in view.subviews {
            subview.removeFromSuperview()
        }
        let installed: NSView = layout == .sectionedList ? sectionedScroll : splitTablesView
        view.addSubview(installed)
        NSLayoutConstraint.activate([
            installed.topAnchor.constraint(equalTo: view.topAnchor),
            installed.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            installed.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            installed.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func rebuildSectionedRows() {
        sectionedRows = viewModel.flattenedRows(from: index.indexChanges)
        sectionedTable.reloadData()
        restoreSectionedSelectionFromControllers()
    }

    private func restoreSectionedSelectionFromControllers() {
        let selectedStaged = Set((stagedFilesController.selectedObjects as? [PBChangedFile] ?? []).map { ObjectIdentifier($0) })
        let selectedUnstaged = Set((unstagedFilesController.selectedObjects as? [PBChangedFile] ?? []).map { ObjectIdentifier($0) })
        var indexes = IndexSet()
        for (rowIndex, row) in sectionedRows.enumerated() {
            guard let file = row.file else { continue }
            let identifier = ObjectIdentifier(file)
            if row.section == .staged ? selectedStaged.contains(identifier) : selectedUnstaged.contains(identifier) {
                indexes.insert(rowIndex)
            }
        }
        syncingSectionedSelection = true
        sectionedTable.selectRowIndexes(indexes, byExtendingSelection: false)
        syncingSectionedSelection = false
    }

    private func syncControllersFromSectionedSelection() {
        var staged: [PBChangedFile] = []
        var unstaged: [PBChangedFile] = []
        for rowIndex in sectionedTable.selectedRowIndexes where sectionedRows.indices.contains(rowIndex) {
            let row = sectionedRows[rowIndex]
            guard let file = row.file else { continue }
            if row.section == .staged {
                staged.append(file)
            } else {
                unstaged.append(file)
            }
        }
        stagedFilesController.setSelectedObjects(staged)
        unstagedFilesController.setSelectedObjects(unstaged)
    }

    private func toggleSectionedSelection() {
        var toStage: [PBChangedFile] = []
        var toUnstage: [PBChangedFile] = []
        for rowIndex in sectionedTable.selectedRowIndexes where sectionedRows.indices.contains(rowIndex) {
            let row = sectionedRows[rowIndex]
            guard let file = row.file else { continue }
            if row.section == .staged {
                toUnstage.append(file)
            } else {
                toStage.append(file)
            }
        }
        if !toStage.isEmpty {
            NSLog("[GitX] Staging %ld file(s) from the sectioned list", toStage.count)
            index.stageFiles(toStage)
        }
        if !toUnstage.isEmpty {
            NSLog("[GitX] Unstaging %ld file(s) from the sectioned list", toUnstage.count)
            index.unstageFiles(toUnstage)
        }
    }

    @objc var stagedFileCount: Int {
        viewModel.stagedFileCount(from: index.indexChanges)
    }

    @objc func clearSelections() {
        unstagedFilesController.setSelectionIndexes(IndexSet())
        stagedFilesController.setSelectionIndexes(IndexSet())
    }

    /// Selects the first pending file (unstaged first) so the diff pane has
    /// content the moment the pane appears.
    @objc func selectInitialFile() {
        if let first = (unstagedFilesController.arrangedObjects as? [PBChangedFile])?.first {
            unstagedFilesController.setSelectedObjects([first])
        } else if let first = (stagedFilesController.arrangedObjects as? [PBChangedFile])?.first {
            stagedFilesController.setSelectedObjects([first])
        } else {
            return
        }
        if layout == .sectionedList {
            restoreSectionedSelectionFromControllers()
        }
    }

    @objc func focusFileList() {
        let table: NSTableView = layout == .sectionedList ? sectionedTable : unstagedTable
        if table.numberOfRows > 0, table.numberOfSelectedRows == 0 {
            if table === sectionedTable {
                selectInitialFile()
            } else {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
        table.window?.makeFirstResponder(table)
    }

    @objc(selectedFilesForStagedContext:)
    func selectedFiles(stagedContext: Bool) -> [PBChangedFile] {
        let controller = stagedContext ? stagedFilesController : unstagedFilesController
        return controller.selectedObjects as? [PBChangedFile] ?? []
    }

    @objc(resolvedSelectionForAction:contextualMenu:)
    func resolvedSelection(
        for action: StagingFileAction,
        contextualMenu: NSMenu?
    ) -> StagingActionSelection {
        let context: StagingSelectionContext
        if layout == .sectionedList {
            context = .sectioned
        } else if contextualMenu === stagedTable.menu {
            context = .splitStaged
        } else if contextualMenu === unstagedTable.menu {
            context = .splitUnstaged
        } else {
            context = .splitAutomatic
        }
        let files = viewModel.resolvedFiles(
            for: action,
            context: context,
            stagedSelection: selectedFiles(stagedContext: true),
            unstagedSelection: selectedFiles(stagedContext: false)
        )
        return StagingActionSelection(action: action, files: files)
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
        if sender === sectionedTable {
            toggleSectionedSelection()
        } else {
            interactionCoordinator.didDoubleClick(sender)
        }
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
        guard let (isStagedSection, file, _) = rowContext(for: sender) else { return }
        if isStagedSection {
            NSLog("[GitX] Unstaging %@ from its row checkbox", file.path)
            index.unstageFiles([file])
        } else {
            NSLog("[GitX] Staging %@ from its row checkbox", file.path)
            index.stageFiles([file])
        }
    }

    @objc private func rowOverflowClicked(_ sender: NSButton) {
        guard let (_, _, table) = rowContext(for: sender), let menu = table.menu else { return }
        let row = table.row(for: sender)
        if row >= 0, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private func rowContext(for sender: NSView) -> (isStagedSection: Bool, file: PBChangedFile, table: NSTableView)? {
        let sectionedRow = sectionedTable.row(for: sender)
        if sectionedRow >= 0, sectionedRows.indices.contains(sectionedRow),
           let file = sectionedRows[sectionedRow].file
        {
            return (sectionedRows[sectionedRow].section == .staged, file, sectionedTable)
        }
        for table in [unstagedTable, stagedTable] {
            let row = table.row(for: sender)
            guard row >= 0 else { continue }
            guard let files = controller(for: table).arrangedObjects as? [PBChangedFile],
                  files.indices.contains(row)
            else { return nil }
            return (table === stagedTable, files[row], table)
        }
        return nil
    }

    private func controller(for table: NSTableView) -> NSArrayController {
        table.tag == 0 ? unstagedFilesController : stagedFilesController
    }

    // MARK: NSTableViewDelegate / DataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sectionedTable ? sectionedRows.count : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sectionedTable {
            guard sectionedRows.indices.contains(row) else { return nil }
            let sectionRow = sectionedRows[row]
            if sectionRow.isHeader {
                return makeSectionedHeaderCell(for: sectionRow.section)
            }
            guard let file = sectionRow.file else { return nil }
            let cell = makeFileCell(in: tableView)
            cell.configure(
                with: file,
                checkboxState: viewModel.rowCheckboxState(for: file, in: sectionRow.section)
            )
            return cell
        }
        guard let files = controller(for: tableView).arrangedObjects as? [PBChangedFile],
              files.indices.contains(row)
        else { return nil }
        let file = files[row]
        let cell = makeFileCell(in: tableView)
        let section: StagingListSection = tableView.tag == 1 ? .staged : .unstaged
        cell.configure(with: file, checkboxState: viewModel.rowCheckboxState(for: file, in: section))
        return cell
    }

    private func makeFileCell(in tableView: NSTableView) -> StagingFileCellView {
        tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? StagingFileCellView
            ?? {
                let created = StagingFileCellView(frame: .zero)
                created.identifier = Self.cellIdentifier
                created.checkbox.target = self
                created.checkbox.action = #selector(rowCheckboxToggled(_:))
                created.overflowButton.target = self
                created.overflowButton.action = #selector(rowOverflowClicked(_:))
                return created
            }()
    }

    private func makeSectionedHeaderCell(for section: StagingListSection) -> StagingSectionHeaderView {
        let header = sectionedTable.makeView(withIdentifier: Self.sectionHeaderIdentifier, owner: self)
            as? StagingSectionHeaderView
            ?? {
                let created = StagingSectionHeaderView(frame: .zero)
                created.identifier = Self.sectionHeaderIdentifier
                created.masterCheckbox.target = self
                created.masterCheckbox.action = #selector(masterCheckboxToggled(_:))
                return created
            }()
        header.masterCheckbox.tag = section == .staged ? 1 : 0
        let changes = index.indexChanges
        let title = section == .staged
            ? NSLocalizedString("Staged files", comment: "Header of the staged section in the staging file list")
            : NSLocalizedString("Unstaged files", comment: "Header of the unstaged section in the staging file list")
        header.configure(
            title: title,
            fileCount: viewModel.files(in: section, from: changes).count,
            masterState: viewModel.masterCheckboxState(for: changes, in: section)
        )
        return header
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === sectionedTable else { return true }
        return sectionedRows.indices.contains(row) && !sectionedRows[row].isHeader
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === sectionedTable {
            guard !syncingSectionedSelection else { return }
            syncControllersFromSectionedSelection()
            return
        }
        guard layout == .splitTables else { return }
        // Selecting in one split table deselects the other so the diff pane
        // shows exactly the side the user chose, like the reference design.
        guard !syncingExclusiveSelection, table.numberOfSelectedRows > 0 else { return }
        syncingExclusiveSelection = true
        if table === stagedTable, !unstagedFilesController.selectionIndexes.isEmpty {
            unstagedFilesController.setSelectionIndexes(IndexSet())
        } else if table === unstagedTable, !stagedFilesController.selectionIndexes.isEmpty {
            stagedFilesController.setSelectionIndexes(IndexSet())
        }
        syncingExclusiveSelection = false
    }

    @objc func fileChangesTableViewDidRequestStagingToggle(_ tableView: PBFileChangesTableView) {
        if tableView === sectionedTable {
            toggleSectionedSelection()
        } else {
            interactionCoordinator.toggleStaging(for: tableView)
        }
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        if tableView === sectionedTable {
            let payload = viewModel.sectionedDragPayload(rows: sectionedRows, selectedIndexes: rowIndexes)
            guard !payload.isEmpty else { return false }
            pboard.declareTypes([Self.sectionedDragType], owner: self)
            pboard.setPropertyList(payload, forType: Self.sectionedDragType)
            return true
        }
        return interactionCoordinator.writeRows(with: rowIndexes, from: tableView, to: pboard)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === sectionedTable else {
            return interactionCoordinator.validateDrop(info, in: tableView)
        }
        guard let target = targetSection(forDropRow: row),
              let files = viewModel.resolvedDropFiles(
                  from: info.draggingPasteboard.propertyList(forType: Self.sectionedDragType),
                  rows: sectionedRows,
                  destinationSection: target
              ),
              !files.isEmpty
        else {
            NSLog("[GitX] Rejected a sectioned staging drop without current cross-section entries")
            return []
        }
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === sectionedTable else {
            return interactionCoordinator.acceptDrop(info, in: tableView)
        }
        guard let target = targetSection(forDropRow: row),
              let files = viewModel.resolvedDropFiles(
                  from: info.draggingPasteboard.propertyList(forType: Self.sectionedDragType),
                  rows: sectionedRows,
                  destinationSection: target
              ),
              !files.isEmpty
        else {
            NSLog("[GitX] Rejected a malformed, stale, or same-section staging drop")
            return false
        }
        if target == .staged {
            NSLog("[GitX] Staging %ld dropped file(s) in the sectioned list", files.count)
            index.stageFiles(files)
        } else {
            NSLog("[GitX] Unstaging %ld dropped file(s) in the sectioned list", files.count)
            index.unstageFiles(files)
        }
        return true
    }

    /// The drop target is the section of the row at the drop location; every
    /// row, header included, knows its section, and drops past the end land
    /// in the last section.
    private func targetSection(forDropRow row: Int) -> StagingListSection? {
        guard !sectionedRows.isEmpty else { return nil }
        return sectionedRows[min(max(row, 0), sectionedRows.count - 1)].section
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

    private static func makeSectionedContextMenu() -> NSMenu {
        let menu = makeContextMenu(stagedContext: false)
        let unstage = NSMenuItem(
            title: NSLocalizedString("Unstage Changes", comment: "Staging context menu item"),
            action: NSSelectorFromString("unstageFiles:"),
            keyEquivalent: ""
        )
        menu.insertItem(unstage, at: 1)
        return menu
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
