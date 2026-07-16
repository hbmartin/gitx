import AppKit

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBHistoryTableInteractionCoordinator)
final class HistoryTableInteractionCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private weak var owner: PBGitHistoryController?
    private weak var commitList: PBCommitList?
    private let stateCoordinator: HistoryStateCoordinator

    @objc var hasWorkingState = false

    @objc(initWithOwner:commitList:stateCoordinator:)
    init(owner: PBGitHistoryController, commitList: PBCommitList, stateCoordinator: HistoryStateCoordinator) {
        self.owner = owner
        self.commitList = commitList
        self.stateCoordinator = stateCoordinator
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        (owner?.commitController.arrangedObjects as? [Any])?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let existing = tableView.rowView(atRow: row, makeIfNecessary: false) {
            return existing
        }
        let rowView = PBGitRevisionRow()
        rowView.controller = owner
        return rowView
    }

    func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        stateCoordinator.selectionIndexes(proposed: proposedSelectionIndexes, hasWorkingState: hasWorkingState)
    }

    func tableView(
        _ tableView: NSTableView,
        writeRowsWith rowIndexes: IndexSet,
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard let owner,
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit]
        else { return false }
        let location = mouseLocation(in: tableView)
        let row = tableView.row(at: location)
        let column = tableView.column(at: location)
        guard commits.indices.contains(row), column >= 0 else { return false }
        let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
        let commit = commits[row]
        let referenceIndex = hitReferenceIndex(cell: cell, x: location.x - tableView.frameOfCell(atColumn: column, row: row).origin.x)

        if referenceIndex >= 0 {
            guard commit.refs.count > Int(referenceIndex),
                  let ref = commit.refs.object(at: Int(referenceIndex)) as? PBGitRef,
                  !ref.isTag, !ref.isRemoteBranch,
                  owner.repository.headRef()?.ref()?.isEqual(to: ref) != true
            else { return false }
            let payload = [row, Int(referenceIndex)]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) else { return false }
            pasteboard.declareTypes([NSPasteboard.PasteboardType("PBGitRef")], owner: self)
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType("PBGitRef"))
        } else {
            pasteboard.declareTypes([.string], owner: self)
            let shortColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("ShortSHAColumn"))
            let value = column == shortColumn ? commit.shortName() : "\(commit.shortName()) (\(commit.subject))"
            pasteboard.setString(value, forType: .string)
        }
        return true
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation != .above,
              info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef")) != nil
        else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard dropOperation == .on,
              let owner,
              let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef")),
              let payload = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Int],
              payload.count == 2,
              payload[0] != row,
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit],
              commits.indices.contains(payload[0]), commits.indices.contains(row),
              commits[payload[0]].refs.count > payload[1],
              let ref = commits[payload[0]].refs.object(at: payload[1]) as? PBGitRef
        else { return false }

        let oldCommit = commits[payload[0]]
        let dropCommit = commits[row]
        let subject = dropCommit.subject.count > 99 ? String(dropCommit.subject.prefix(99)) + "…" : dropCommit.subject
        let alert = NSAlert()
        alert.messageText = "Move \(ref.refishType() ?? "reference"): \(ref.shortName())"
        alert.informativeText = "Move the \(ref.refishType() ?? "reference") to point to the commit: \(subject)"
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard let windowController = owner.windowController else { return false }
        NSLog("[GitX] History reference move confirmation requested")
        windowController.confirmDialog(alert, suppressionIdentifier: kDialogAcceptDroppedRef) { [weak windowController] in
            guard let windowController else { return }
            do {
                try windowController.repository.updateReference(ref, toPointAt: dropCommit)
                dropCommit.addRef(ref)
                oldCommit.removeRef(ref)
                NSLog("[GitX] History reference move completed")
            } catch {
                windowController.showErrorSheet(error)
            }
        }
        return true
    }

    @objc(didDoubleClickCommitList:)
    func didDoubleClickCommitList(_ sender: Any?) {
        guard let tableView = sender as? NSTableView ?? commitList,
              let owner,
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit]
        else { return }
        let location = mouseLocation(in: tableView)
        let row = tableView.row(at: location)
        let column = tableView.column(at: location)
        guard commits.indices.contains(row), column >= 0 else { return }
        let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
        let index = hitReferenceIndex(cell: cell, x: location.x - tableView.frameOfCell(atColumn: column, row: row).origin.x)
        guard index >= 0, commits[row].refs.count > Int(index),
              let ref = commits[row].refs.object(at: Int(index)) as? PBGitRef
        else { return }
        do {
            _ = try owner.repository.checkoutRefish(ref)
        } catch {
            owner.windowController?.showErrorSheet(error)
        }
    }

    private func mouseLocation(in tableView: NSTableView) -> NSPoint {
        if let commitList = tableView as? PBCommitList {
            return commitList.mouseDownPoint
        }
        return (tableView.value(forKey: "mouseDownPoint") as? NSValue)?.pointValue ?? .zero
    }

    private func hitReferenceIndex(cell: NSView?, x: CGFloat) -> Int32 {
        let selector = NSSelectorFromString("indexAtX:")
        guard let object = cell, object.responds(to: selector),
              let implementation = object.method(for: selector)
        else { return -1 }
        typealias Function = @convention(c) (AnyObject, Selector, CGFloat) -> Int32
        // swift6-safety-justification: PBGraphCellInfo's Objective-C -indexAtX: selector has this exact CGFloat-to-int signature.
        return unsafeBitCast(implementation, to: Function.self)(object, selector, x)
    }
}

// swiftlint:enable unused_declaration
