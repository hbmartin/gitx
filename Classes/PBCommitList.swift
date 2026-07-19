//
//  PBCommitList.swift
//  GitX
//
//  Converted from PBCommitList.m
//

// Objective-C nib and controller references are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc class PBCommitList: NSTableView {
    // MARK: - Properties

    @IBOutlet weak var webController: PBWebHistoryController!
    @IBOutlet weak var controller: PBGitHistoryController!
    @IBOutlet weak var searchController: PBHistorySearchController!

    @objc dynamic var useAdjustScroll: Bool = false
    @objc private(set) var mouseDownPoint: NSPoint = .zero

    // MARK: - Drag and Drop

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation
    {
        if session.draggingPasteboard.data(forType: .gitXBranchReference) != nil {
            return branchDragSourceOperationMask(for: context)
        }
        return .copy
    }

    @objc(branchDragSourceOperationMaskForContext:)
    func branchDragSourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // TODO: dragImageForRowsWithIndexes is deprecated in modern macOS
    // This custom drag image implementation may need to be reimplemented using modern APIs
    // For now, using the default implementation
    /*
     override func dragImageForRowsWithIndexes(_ dragRows: NSIndexSet,
                                               tableColumns: [NSTableColumn],
                                               event dragEvent: NSEvent,
                                               offset dragImageOffset: NSPointPointer) -> NSImage {
         let location = mouseDownPoint
         let row = self.row(at: location)
         let column = self.column(at: location)

         guard let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? PBGitRevisionCell else {
             return super.dragImageForRowsWithIndexes(dragRows,
                                                      tableColumns: tableColumns,
                                                      event: dragEvent,
                                                      offset: dragImageOffset)
         }

         let cellFrame = frameOfCell(atColumn: column, row: row)
         let index = cell.responds(to: #selector(PBGitRevisionCell.index(atX:)))
             ? cell.index(atX: location.x - cellFrame.origin.x)
             : -1

         if index == -1 {
             return super.dragImageForRowsWithIndexes(dragRows,
                                                      tableColumns: tableColumns,
                                                      event: dragEvent,
                                                      offset: dragImageOffset)
         }

         var rect = cell.rectAtIndex(index)
         let newImage = NSImage(size: NSSize(width: rect.size.width + 3,
                                             height: rect.size.height + 3))
         rect.origin = NSPoint(x: 0.5, y: 0.5)

         newImage.lockFocus()
         cell.drawLabelAtIndex(index, inRect: rect)
         newImage.unlockFocus()

         dragImageOffset.pointee = NSPoint(x: rect.size.width / 2 + 10, y: 0)
         return newImage
     }
     */

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard let character = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags

        // Pass on command-shift up/down to the responder. We want the splitview to capture this.
        if modifiers.contains(.shift) && modifiers.contains(.command) &&
            (event.keyCode == 0x7E || event.keyCode == 0x7D)
        {
            nextResponder?.keyDown(with: event)
            return
        }

        if character == " " {
            if controller.selectedCommitDetailsIndex == 0 {
                if modifiers.contains(.shift) {
                    webController.scrollPageUp()
                } else {
                    webController.scrollPageDown()
                }
            } else {
                controller.toggleQLPreviewPanel(self)
            }
        } else if let range = character.rangeOfCharacter(from: CharacterSet(charactersIn: "jkcv")),
                  range.lowerBound == character.startIndex
        {
            webController.sendKey(character)
        } else if let firstChar = character.utf16.first,
                  firstChar == NSDownArrowFunctionKey && modifiers.contains(.control)
        {
            controller.selectParentCommit(self)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Scroll Adjustment

    override func adjustScroll(_ proposedVisibleRect: NSRect) -> NSRect {
        var newRect = proposedVisibleRect

        // Only modify if scrollSelectionToTopOfViewFrom has set useAdjustScroll to true
        // Otherwise we'd also constrain things like middle mouse scrolling.
        guard useAdjustScroll else {
            return newRect
        }

        let rh = Int(rowHeight)
        let ny = Int(proposedVisibleRect.origin.y) % rh
        let adj = rh - ny

        // Check the targeted row and see if we need to add or subtract the difference
        let sr = rect(ofRow: selectedRow)

        if sr.origin.y > proposedVisibleRect.origin.y {
            newRect = NSRect(x: newRect.origin.x,
                             y: newRect.origin.y + CGFloat(adj),
                             width: newRect.size.width,
                             height: newRect.size.height)
        } else if sr.origin.y < proposedVisibleRect.origin.y {
            newRect = NSRect(x: newRect.origin.x,
                             y: newRect.origin.y - CGFloat(ny),
                             width: newRect.size.width,
                             height: newRect.size.height)
        }

        return newRect
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    // MARK: - Context Menu

    @objc(shouldReplaceSelectionForContextClickAtRow:selectedRows:)
    static func shouldReplaceSelectionForContextClick(at clickedRow: Int, selectedRows: IndexSet) -> Bool {
        clickedRow >= 0 && !selectedRows.contains(clickedRow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event)
        let index = clickedRow

        let column = self.column(withIdentifier: NSUserInterfaceItemIdentifier("SubjectColumn"))
        guard index >= 0,
              column != -1,
              let cell = view(atColumn: column, row: index, makeIfNecessary: false) as? PBGitRevisionCell,
              let commit = cell.objectValue
        else {
            return nil
        }
        // The Working State row is a navigation surface, not an immutable
        // commit, so commit/ref actions do not apply to it.
        if commit.sha.isEmpty {
            return nil
        }

        if Self.shouldReplaceSelectionForContextClick(at: index, selectedRows: selectedRowIndexes) {
            NSLog("[GitX] Context-click selected commit row %ld", index)
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }

        let point = window?.contentView?.convert(event.locationInWindow, to: cell) ?? .zero
        let i = Int(cell.indexAt(x: point.x))
        let clickedRef: PBGitRef? = (i >= 0 && i < commit.refs.count) ? commit.refs[i] as? PBGitRef : nil

        let selectedCommits = controller.selectedCommits
        let items: [NSMenuItem]

        if let clickedRef = clickedRef {
            items = controller.menuItems(for: clickedRef) as? [NSMenuItem] ?? []
        } else if selectedCommits.contains(commit) {
            items = controller.menuItems(for: controller.selectedCommits) as? [NSMenuItem] ?? []
        } else {
            items = controller.menuItems(for: [commit]) as? [NSMenuItem] ?? []
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(item)
        }

        return menu
    }
}

// swiftlint:enable unused_declaration
