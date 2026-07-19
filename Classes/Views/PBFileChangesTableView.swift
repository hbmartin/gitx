//
//  PBFileChangesTableView.swift
//  GitX
//
//  Converted from PBFileChangesTableView.m.
//

// Objective-C nib, controller, and test references are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBFileChangesTableView)
final class PBFileChangesTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard delegate != nil else { return nil }

        let eventLocation = convert(event.locationInWindow, from: nil)
        let rowIndex = row(at: eventLocation)
        if rowIndex >= 0 {
            selectRowIndexes(
                FileContextSelectionPolicy.selection(
                    current: selectedRowIndexes,
                    clickedRow: rowIndex
                ),
                byExtendingSelection: false
            )
        }
        return super.menu(for: event)
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation
    {
        .every
    }

    override var acceptsFirstResponder: Bool {
        numberOfRows > 0
    }

    override func keyDown(with event: NSEvent) {
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let isPlainSpace = event.keyCode == 49 && event.modifierFlags.intersection(actionModifiers).isEmpty

        guard isPlainSpace, numberOfSelectedRows > 0, let delegate else {
            super.keyDown(with: event)
            return
        }

        let stagingToggle = NSSelectorFromString("fileChangesTableViewDidRequestStagingToggle:")
        if NSApp.sendAction(stagingToggle, to: delegate, from: self) {
            return
        }

        super.keyDown(with: event)
    }
}

private enum FileContextSelectionPolicy {
    static func selection(current: IndexSet, clickedRow: Int) -> IndexSet {
        current.contains(clickedRow) ? current : IndexSet(integer: clickedRow)
    }
}

// swiftlint:enable unused_declaration
