import AppKit
import XCTest

@MainActor
final class WorktreeCharacterizationTests: XCTestCase {
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
