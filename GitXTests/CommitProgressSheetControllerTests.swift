import AppKit
import XCTest

@MainActor
final class CommitProgressSheetControllerTests: XCTestCase {
    func testSheetPresentsSelectableMonospaceOutputAndCannotBeCancelled() throws {
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = PBCommitProgressSheetController(parentWindow: parentWindow)
        let sheet = try XCTUnwrap(controller.window)

        XCTAssertEqual(sheet.accessibilityIdentifier(), "CommitProgressSheet")
        XCTAssertEqual(sheet.styleMask, [.titled])
        assertUnavailable(sheet.standardWindowButton(.closeButton))
        assertUnavailable(sheet.standardWindowButton(.miniaturizeButton))
        assertUnavailable(sheet.standardWindowButton(.zoomButton))

        controller.begin(withPhase: "Running pre-commit hook")
        XCTAssertTrue(parentWindow.attachedSheet === sheet)

        let phaseLabel = try XCTUnwrap(
            descendant(identifier: "CommitProgressPhase", in: sheet.contentView) as? NSTextField
        )
        XCTAssertEqual(phaseLabel.stringValue, "Running pre-commit hook")
        controller.updatePhase("Running commit-msg hook")
        XCTAssertEqual(phaseLabel.stringValue, "Running commit-msg hook")

        let outputTextView = try XCTUnwrap(
            descendant(identifier: "CommitProgressOutput", in: sheet.contentView) as? NSTextView
        )
        controller.appendOutput("first chunk\n")
        controller.appendOutput("second chunk\n")
        XCTAssertEqual(outputTextView.string, "first chunk\nsecond chunk\n")
        XCTAssertTrue(outputTextView.isSelectable)
        XCTAssertFalse(outputTextView.isEditable)
        XCTAssertEqual(
            outputTextView.font?.fontName,
            NSFont.userFixedPitchFont(ofSize: NSFont.smallSystemFontSize)?.fontName
        )

        controller.cancelOperation(nil)
        XCTAssertTrue(parentWindow.attachedSheet === sheet)
        controller.finish()
        XCTAssertNil(parentWindow.attachedSheet)
    }

    func testSheetWithoutParentHandlesEmptyOutputAndFinishesDetached() throws {
        let controller = PBCommitProgressSheetController(parentWindow: nil)
        let sheet = try XCTUnwrap(controller.window)
        let outputTextView = try XCTUnwrap(
            descendant(identifier: "CommitProgressOutput", in: sheet.contentView) as? NSTextView
        )

        controller.begin(withPhase: "Preparing commit")
        controller.appendOutput("")
        XCTAssertEqual(outputTextView.string, "")

        controller.finish()
        XCTAssertFalse(sheet.isVisible)
    }

    private func descendant(identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func assertUnavailable(_ button: NSButton?) {
        guard let button else { return }
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isEnabled)
    }
}
