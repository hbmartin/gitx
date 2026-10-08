import AppKit

// AppKit and Objective-C controller wiring call these entry points indirectly.
// swiftlint:disable unused_declaration

@objc(PBCommitTableInteractionCoordinator)
final class CommitTableInteractionCoordinator: NSObject {
    private static let fileChangesPasteboardType = NSPasteboard.PasteboardType("GitFileChangedType")
    private static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    private let repository: PBGitRepository
    private let index: PBGitIndex
    private weak var unstagedFilesController: NSArrayController?
    private weak var stagedFilesController: NSArrayController?
    private weak var unstagedTable: NSTableView?
    private weak var stagedTable: NSTableView?
    private weak var pendingSelectionController: NSArrayController?
    private var pendingSelectionIndex: Int?

    @objc(initWithRepository:index:unstagedFilesController:stagedFilesController:unstagedTable:stagedTable:)
    init(
        repository: PBGitRepository,
        index: PBGitIndex,
        unstagedFilesController: NSArrayController,
        stagedFilesController: NSArrayController,
        unstagedTable: NSTableView,
        stagedTable: NSTableView
    ) {
        self.repository = repository
        self.index = index
        self.unstagedFilesController = unstagedFilesController
        self.stagedFilesController = stagedFilesController
        self.unstagedTable = unstagedTable
        self.stagedTable = stagedTable
        super.init()

        unstagedTable.registerForDraggedTypes([Self.fileChangesPasteboardType])
        stagedTable.registerForDraggedTypes([Self.fileChangesPasteboardType])
        NotificationCenter.default.addObserver(self, selector: #selector(indexDidUpdate(_:)), name: NSNotification.Name(PBGitIndexIndexUpdated), object: index)
    }

    @objc(stageSelectedFiles)
    func stageSelectedFiles() {
        guard CommitSubmissionEligibility.allowsMutation(index), let controller = unstagedFilesController,
              let files = controller.selectedObjects as? [PBChangedFile]
        else { return }
        NSLog("[GitX] Staging %ld selected file(s)", files.count)
        let selectionIndex = controller.selectionIndex
        index.stageFiles(files)
        reselectNextFile(in: controller, currentSelectionIndex: selectionIndex)
    }

    @objc(unstageSelectedFiles)
    func unstageSelectedFiles() {
        guard CommitSubmissionEligibility.allowsMutation(index), let controller = stagedFilesController,
              let files = controller.selectedObjects as? [PBChangedFile]
        else { return }
        NSLog("[GitX] Unstaging %ld selected file(s)", files.count)
        let selectionIndex = controller.selectionIndex
        index.unstageFiles(files)
        reselectNextFile(in: controller, currentSelectionIndex: selectionIndex)
    }

    @objc(toggleStagingForTableView:)
    func toggleStaging(for tableView: NSTableView) {
        if tableView === unstagedTable {
            stageSelectedFiles()
        } else if tableView === stagedTable {
            unstageSelectedFiles()
        }
    }

    @objc(focusTable:)
    func focus(_ tableView: NSTableView) {
        guard tableView.numberOfRows > 0 else { return }
        if tableView.numberOfSelectedRows == 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        tableView.window?.makeFirstResponder(tableView)
    }

    @objc(handleCommandSelector:)
    func handle(commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)), let stagedTable {
            focus(stagedTable)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), let unstagedTable {
            focus(unstagedTable)
            return true
        }
        return false
    }

    @objc(displayCell:forTableColumn:row:inTableView:)
    func displayCell(_: Any, for tableColumn: NSTableColumn, row: Int, in tableView: NSTableView) {
        let controller = tableView.tag == 0 ? unstagedFilesController : stagedFilesController
        guard let files = controller?.arrangedObjects as? [PBChangedFile],
              files.indices.contains(row)
        else { return }
        (tableColumn.dataCell as? NSCell)?.image = tableView.tag == 0 ? files[row].worktreeIcon() : files[row].stagedIcon()
    }

    @objc(didDoubleClickTableView:)
    func didDoubleClick(_ tableView: NSTableView) {
        let controller = tableView === unstagedTable ? unstagedFilesController : stagedFilesController
        guard CommitSubmissionEligibility.allowsMutation(index), let controller,
              let files = files(in: controller, at: tableView.selectedRowIndexes)
        else { return }

        if tableView === unstagedTable {
            NSLog("[GitX] Staging %ld file(s) from a double-click", files.count)
            index.stageFiles(files)
        } else {
            NSLog("[GitX] Unstaging %ld file(s) from a double-click", files.count)
            index.unstageFiles(files)
        }
    }

    @objc(writeRowsWithIndexes:fromTableView:toPasteboard:)
    func writeRows(
        with rowIndexes: IndexSet,
        from tableView: NSTableView,
        to pasteboard: NSPasteboard
    ) -> Bool {
        let controller = tableView.tag == 0 ? unstagedFilesController : stagedFilesController
        guard let controller, let files = files(in: controller, at: rowIndexes), !files.isEmpty else { return false }
        let source: StagingListSection = tableView.tag == 0 ? .unstaged : .staged
        let rows = files.map { StagingListRow.file($0, section: source) }
        let payload = StagingListViewModel().sectionedDragPayload(rows: rows, selectedIndexes: IndexSet(rows.indices))
        let safePaths = files.compactMap(\.safePath)
        let externalPaths = safePaths.count == files.count ? repository.workingDirectoryURL().map { url in
            safePaths.map { url.appendingPathComponent($0).path }
        } : nil
        var types = [Self.fileChangesPasteboardType]
        if externalPaths != nil {
            types.append(Self.filenamesPasteboardType)
        }
        pasteboard.declareTypes(types, owner: self)
        pasteboard.setPropertyList(payload, forType: Self.fileChangesPasteboardType)
        if let paths = externalPaths {
            pasteboard.setPropertyList(paths, forType: Self.filenamesPasteboardType)
        }
        NSLog("[GitX] Prepared %ld commit-table file(s) for dragging", files.count)
        return true
    }

    @objc(validateDrop:inTableView:)
    func validateDrop(_ info: NSDraggingInfo, in tableView: NSTableView) -> NSDragOperation {
        guard CommitSubmissionEligibility.allowsMutation(index),
              let files = dropFiles(info, destination: tableView), !files.isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    @objc(acceptDrop:inTableView:)
    func acceptDrop(_ info: NSDraggingInfo, in tableView: NSTableView) -> Bool {
        guard CommitSubmissionEligibility.allowsMutation(index), let files = dropFiles(info, destination: tableView),
              !files.isEmpty else { return false }
        if tableView.tag == 0 {
            NSLog("[GitX] Unstaging %ld dropped file(s)", files.count)
            return index.unstageFiles(files)
        }
        NSLog("[GitX] Staging %ld dropped file(s)", files.count)
        return index.stageFiles(files)
    }

    private func dropFiles(_ info: NSDraggingInfo, destination tableView: NSTableView) -> [PBChangedFile]? {
        guard let source = info.draggingSource as? NSTableView,
              (tableView === unstagedTable && source === stagedTable) ||
              (tableView === stagedTable && source === unstagedTable) else { return nil }
        let staged = (stagedFilesController?.arrangedObjects as? [PBChangedFile] ?? []).map {
            StagingListRow.file($0, section: .staged)
        }
        let unstaged = (unstagedFilesController?.arrangedObjects as? [PBChangedFile] ?? []).map {
            StagingListRow.file($0, section: .unstaged)
        }
        return StagingListViewModel().resolvedDropFiles(
            from: info.draggingPasteboard.propertyList(forType: Self.fileChangesPasteboardType),
            rows: staged + unstaged, destinationSection: tableView.tag == 0 ? .unstaged : .staged
        )
    }

    private func files(in controller: NSArrayController, at indexes: IndexSet) -> [PBChangedFile]? {
        guard let arrangedFiles = controller.arrangedObjects as? [PBChangedFile],
              indexes.allSatisfy({ arrangedFiles.indices.contains($0) })
        else { return nil }
        return indexes.map { arrangedFiles[$0] }
    }

    @objc func close() {
        NotificationCenter.default.removeObserver(self)
        pendingSelectionController = nil
        pendingSelectionIndex = nil
    }

    @objc private func indexDidUpdate(_: Notification) {
        guard let controller = pendingSelectionController, let currentSelectionIndex = pendingSelectionIndex else { return }
        pendingSelectionController = nil
        pendingSelectionIndex = nil
        // Array controllers rearrange in the other index observers. Selection
        // advances after those observers see this authoritative publication.
        advanceSelection(in: controller, currentSelectionIndex: currentSelectionIndex)
    }

    private func reselectNextFile(in controller: NSArrayController, currentSelectionIndex: Int) {
        if !CommitSubmissionEligibility.allowsMutation(index) {
            pendingSelectionController = controller
            pendingSelectionIndex = currentSelectionIndex
        } else {
            advanceSelection(in: controller, currentSelectionIndex: currentSelectionIndex)
        }
    }

    private func advanceSelection(in controller: NSArrayController, currentSelectionIndex: Int) {
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            let selectionIndex = CommitSelectionPolicy.selectionIndex(
                currentIndex: currentSelectionIndex,
                arrangedCount: (controller.arrangedObjects as? [Any])?.count ?? 0
            )
            controller.setSelectionIndex(selectionIndex)
        }
    }
}

// swiftlint:enable unused_declaration
