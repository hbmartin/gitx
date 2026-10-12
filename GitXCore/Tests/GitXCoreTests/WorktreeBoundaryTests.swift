@testable import GitXCore
import XCTest

final class WorktreeBoundaryTests: XCTestCase {
    func testRejectsMalformedFlagsAndTruncatedRecords() {
        for text in ["worktree /main\0bare wrong\0\0", "worktree /main\0HEAD abc\0detached wrong\0\0", "worktree /main\0HEAD abc\0branch refs/heads/\0\0", "\0", "worktree /main"] {
            XCTAssertThrowsError(try WorktreeParser.parse(Data(text.utf8)))
        }
        XCTAssertEqual(WorktreePaths.canonical(""), "")
    }

    func testForeignLinksAreVisibleAndSnapshotsIncludeLinkState() {
        let foreign = GitWorktree(path: "/copy", hasForeignLink: true)
        XCTAssertTrue(WorktreePresentation.details(foreign).contains("Linked to another repository"))
        XCTAssertNotEqual(foreign, GitWorktree(path: "/copy"))
        XCTAssertNotEqual(GitWorktree(path: "/a", linkStyle: .relative), GitWorktree(path: "/a", linkStyle: .absolute))
        XCTAssertNotEqual(GitWorktree(path: "/a", isCurrent: true), GitWorktree(path: "/a"))
        XCTAssertNotEqual(GitWorktree(path: "/a", folderExists: false), GitWorktree(path: "/a"))
    }
}
