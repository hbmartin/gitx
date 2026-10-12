import AppKit
import XCTest

@MainActor
final class WorktreeCharacterizationTests: XCTestCase {
    func testLockedAndUnavailableRowsRetainCurrentBranchPriority() throws {
        let cell = PBSidebarTableViewCell(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let badge = NSImageView()
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "topic")
        [badge, icon, text].forEach(cell.addSubview)
        cell.setValue(badge, forKey: "checkedOutImageView")
        cell.imageView = icon
        cell.textField = text
        cell.isLocked = true
        let lock = try XCTUnwrap(badge.image)
        XCTAssertFalse(badge.isHidden)
        XCTAssertNotNil(badge.contentTintColor)
        cell.isCheckedOut = true
        XCTAssertFalse(badge.image === lock)
        XCTAssertNil(badge.contentTintColor)
        cell.isUnavailable = true
        XCTAssertEqual(text.textColor, .tertiaryLabelColor)
        XCTAssertEqual(icon.alphaValue, 0.5)
        XCTAssertEqual(badge.alphaValue, 0.5)
        cell.isUnavailable = false
        XCTAssertEqual(text.textColor, .labelColor)
        XCTAssertEqual(icon.alphaValue, 1)
        XCTAssertEqual(badge.alphaValue, 1)
        cell.isCheckedOut = false
        cell.isLocked = false
        XCTAssertNil(badge.image)
        XCTAssertTrue(badge.isHidden)
    }

    func testLockBadgeRefreshesWhenItsWindowChangesMainState() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let cell = PBSidebarTableViewCell(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        let badge = NSImageView()
        cell.addSubview(badge)
        cell.setValue(badge, forKey: "checkedOutImageView")
        cell.isLocked = true
        window.contentView?.addSubview(cell)
        let before = try XCTUnwrap(badge.image)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        XCTAssertFalse(badge.image === before)
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: window)
        XCTAssertNotNil(badge.image)
        cell.removeFromSuperview()
        XCTAssertNil(cell.window)
        cell.isLocked = false
        XCTAssertTrue(badge.isHidden)
        window.close()
    }

    func testSidebarCheckmarkTracksStateAndBackgroundStyle() throws {
        let cell = PBSidebarTableViewCell(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let badge = NSImageView()
        cell.addSubview(badge)
        cell.setValue(badge, forKey: "checkedOutImageView")
        XCTAssertFalse(cell.isCheckedOut)
        cell.isCheckedOut = true
        XCTAssertFalse(badge.isHidden)
        let image = try XCTUnwrap(badge.image)
        XCTAssertGreaterThan(image.size.width, 0)
        cell.backgroundStyle = .emphasized
        XCTAssertFalse(badge.isHidden)
        XCTAssertFalse(badge.image === image)
        cell.isCheckedOut = false
        XCTAssertTrue(badge.isHidden)
        XCTAssertNil(badge.image)
        cell.backgroundStyle = .normal
        XCTAssertTrue(badge.isHidden)
        XCTAssertNil(badge.image)
    }

    func testSidebarCheckmarkAllowsDisconnectedAndReleasedNibOutlet() {
        let cell = PBSidebarTableViewCell(frame: .zero)
        cell.isCheckedOut = true
        cell.backgroundStyle = .emphasized
        autoreleasepool {
            let badge = NSImageView()
            cell.setValue(badge, forKey: "checkedOutImageView")
            cell.isCheckedOut = false
            XCTAssertTrue(badge.isHidden)
        }
        XCTAssertNil(cell.value(forKey: "checkedOutImageView"))
        cell.isCheckedOut = true
        cell.backgroundStyle = .normal
        XCTAssertTrue(cell.isCheckedOut)
        XCTAssertEqual(NSStringFromClass(type(of: cell)), "PBSidebarTableViewCell")
    }
}
