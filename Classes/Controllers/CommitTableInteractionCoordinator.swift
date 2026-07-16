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
    }

    @objc(stageSelectedFiles)
    func stageSelectedFiles() {
        guard let controller = unstagedFilesController,
              let files = controller.selectedObjects as? [PBChangedFile]
        else { return }
        NSLog("[GitX] Staging %ld selected file(s)", files.count)
        index.stageFiles(files)
        reselectNextFile(in: controller)
    }

    @objc(unstageSelectedFiles)
    func unstageSelectedFiles() {
        guard let controller = stagedFilesController,
              let files = controller.selectedObjects as? [PBChangedFile]
        else { return }
        NSLog("[GitX] Unstaging %ld selected file(s)", files.count)
        index.unstageFiles(files)
        reselectNextFile(in: controller)
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
        (tableColumn.dataCell as? NSCell)?.image = files[row].icon()
    }

    @objc(didDoubleClickTableView:)
    func didDoubleClick(_ tableView: NSTableView) {
        let controller = tableView === unstagedTable ? unstagedFilesController : stagedFilesController
        guard let controller,
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
        pasteboard.declareTypes([Self.fileChangesPasteboardType, Self.filenamesPasteboardType], owner: self)

        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: rowIndexes as NSIndexSet,
                requiringSecureCoding: true
            )
            pasteboard.setData(data, forType: Self.fileChangesPasteboardType)
        } catch {
            NSLog("[GitX] Could not archive commit-table drag rows: %@", error.localizedDescription)
            return false
        }

        let controller = tableView.tag == 0 ? unstagedFilesController : stagedFilesController
        guard let controller,
              let files = files(in: controller, at: rowIndexes),
              let workingDirectoryURL = repository.workingDirectoryURL()
        else { return false }
        let paths = files.map { workingDirectoryURL.appendingPathComponent($0.path).path }
        pasteboard.setPropertyList(paths, forType: Self.filenamesPasteboardType)
        NSLog("[GitX] Prepared %ld commit-table file(s) for dragging", files.count)
        return true
    }

    @objc(validateDrop:inTableView:)
    func validateDrop(_ info: NSDraggingInfo, in tableView: NSTableView) -> NSDragOperation {
        if let source = info.draggingSource as? NSTableView, source === tableView {
            return []
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    @objc(acceptDrop:inTableView:)
    func acceptDrop(_ info: NSDraggingInfo, in tableView: NSTableView) -> Bool {
        guard let rowData = info.draggingPasteboard.data(forType: Self.fileChangesPasteboardType) else {
            return false
        }

        let rowIndexes: IndexSet
        do {
            guard let archivedIndexes = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSIndexSet.self,
                from: rowData
            ) else { return false }
            rowIndexes = archivedIndexes as IndexSet
        } catch {
            NSLog("[GitX] Could not unarchive commit-table drag rows: %@", error.localizedDescription)
            return false
        }

        let sourceController = tableView.tag == 0 ? stagedFilesController : unstagedFilesController
        guard let sourceController,
              let files = files(in: sourceController, at: rowIndexes)
        else { return false }

        if tableView.tag == 0 {
            NSLog("[GitX] Unstaging %ld dropped file(s)", files.count)
            index.unstageFiles(files)
        } else {
            NSLog("[GitX] Staging %ld dropped file(s)", files.count)
            index.stageFiles(files)
        }
        return true
    }

    private func files(in controller: NSArrayController, at indexes: IndexSet) -> [PBChangedFile]? {
        guard let arrangedFiles = controller.arrangedObjects as? [PBChangedFile],
              indexes.allSatisfy({ arrangedFiles.indices.contains($0) })
        else { return nil }
        return indexes.map { arrangedFiles[$0] }
    }

    private func reselectNextFile(in controller: NSArrayController) {
        let currentSelectionIndex = controller.selectionIndex
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
