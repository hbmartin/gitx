//
//  PBFileChangesTableView.swift
//  GitX
//
//  Converted from PBFileChangesTableView.m.
//

@objc(PBFileChangesTableView)
final class PBFileChangesTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard delegate != nil else { return nil }

        let eventLocation = convert(event.locationInWindow, from: nil)
        let rowIndex = row(at: eventLocation)
        if rowIndex >= 0 {
            selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: true)
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
