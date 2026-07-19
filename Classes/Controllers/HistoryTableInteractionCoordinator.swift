import AppKit
import OSLog // swiftlint:disable:this unused_import

extension NSPasteboard.PasteboardType {
    static let gitXBranchReference = NSPasteboard.PasteboardType("PBGitRef")
}

private struct HistoryBranchDragPayload: Codable {
    static let currentVersion = 1

    let version: Int
    let referenceName: String
    let sourceSHA: String

    init(referenceName: String, sourceSHA: String) {
        version = Self.currentVersion
        self.referenceName = referenceName
        self.sourceSHA = sourceSHA
    }
}

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBHistoryTableInteractionCoordinator)
final class HistoryTableInteractionCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private weak var owner: PBGitHistoryController?
    private weak var commitList: PBCommitList?
    private let stateCoordinator: HistoryStateCoordinator
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "HistoryBranchDrag")

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
                  ref.isBranch,
                  commit.sha.isEmpty == false,
                  liveCheckedOutReferenceName(in: owner.repository) != ref.ref
            else {
                logger.debug("Rejected branch drag source")
                return false
            }
            let payload = HistoryBranchDragPayload(referenceName: ref.ref, sourceSHA: commit.sha)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(payload) else {
                logger.error("Could not encode branch drag payload")
                return false
            }
            pasteboard.declareTypes([.gitXBranchReference], owner: self)
            pasteboard.setData(data, forType: .gitXBranchReference)
            logger.debug("Started local branch drag")
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
        guard dropOperation == .on,
              info.draggingSourceOperationMask.contains(.move),
              validatedBranchMove(info: info, destinationRow: row) != nil
        else {
            return []
        }
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
              info.draggingSourceOperationMask.contains(.move),
              let move = validatedBranchMove(info: info, destinationRow: row)
        else {
            logger.debug("Rejected branch move drop")
            return false
        }

        let ref = move.reference
        let oldCommit = move.sourceCommit
        let dropCommit = move.destinationCommit
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
                try RepositoryMutationService(repository: windowController.repository).updateReference(
                    ref,
                    toPointAt: dropCommit,
                    expectedOldOID: oldCommit.sha
                )
                dropCommit.addRef(ref)
                oldCommit.removeRef(ref)
                self.logger.debug("History branch move completed")
            } catch {
                self.logger.error("History branch move failed")
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

    private struct ValidatedBranchMove {
        let reference: PBGitRef
        let sourceCommit: PBGitCommit
        let destinationCommit: PBGitCommit
    }

    private func validatedBranchMove(
        info: NSDraggingInfo,
        destinationRow: Int
    ) -> ValidatedBranchMove? {
        guard let owner,
              let data = info.draggingPasteboard.data(forType: .gitXBranchReference),
              let payload = try? PropertyListDecoder().decode(HistoryBranchDragPayload.self, from: data),
              payload.version == HistoryBranchDragPayload.currentVersion,
              isFullSHA(payload.sourceSHA),
              let commits = owner.commitController.arrangedObjects as? [PBGitCommit],
              commits.indices.contains(destinationRow),
              let sourceCommit = commits.first(where: { $0.sha == payload.sourceSHA }),
              let reference = sourceCommit.refs.compactMap({ $0 as? PBGitRef }).first(where: {
                  $0.ref == payload.referenceName
              }),
              reference.isBranch,
              liveCheckedOutReferenceName(in: owner.repository) != payload.referenceName,
              liveReferenceSHA(payload.referenceName, in: owner.repository) == payload.sourceSHA
        else {
            return nil
        }

        let destinationCommit = commits[destinationRow]
        guard !(destinationCommit is PBUncommittedChanges),
              destinationCommit.sha.isEmpty == false,
              destinationCommit.sha != payload.sourceSHA
        else {
            return nil
        }
        return ValidatedBranchMove(
            reference: reference,
            sourceCommit: sourceCommit,
            destinationCommit: destinationCommit
        )
    }

    private func liveCheckedOutReferenceName(in repository: PBGitRepository) -> String? {
        guard let gitRepository = repository.gtRepo,
              let head = try? gitRepository.lookUpReference(withName: "HEAD"),
              gitRepository.isHEADDetached == false
        else {
            return nil
        }
        return gitRepository.isHEADUnborn ? head.name : head.resolved.name
    }

    private func liveReferenceSHA(_ referenceName: String, in repository: PBGitRepository) -> String? {
        guard let gitRepository = repository.gtRepo,
              let reference = try? gitRepository.lookUpReference(withName: referenceName),
              let oid = reference.oid
        else {
            return nil
        }
        return oid.sha
    }

    private func isFullSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }
}

// swiftlint:enable unused_declaration
