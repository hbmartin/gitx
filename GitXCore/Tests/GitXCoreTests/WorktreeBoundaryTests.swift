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

    func testRepairFolderMustMatchAdministrativeBacklink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-repair-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("repo/.git")
        let administrative = common.appendingPathComponent("worktrees/id")
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("moved")
        let foreign = root.appendingPathComponent("foreign")
        let foreignAdmin = root.appendingPathComponent("other/.git/worktrees/id")
        for folder in [administrative, original, moved, foreign, foreignAdmin] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let backlink = administrative.appendingPathComponent("gitdir")
        try (original.path + "/.git\n").write(to: backlink, atomically: true, encoding: .utf8)
        for folder in [original, moved] {
            try ("gitdir: " + administrative.path + "\n").write(to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        }
        try ("gitdir: " + foreignAdmin.path + "\n").write(to: foreign.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let record = GitWorktree(path: original.path)
        XCTAssertTrue(WorktreeLinkInspector.canRepair(record, at: original.path, commonDirectory: common.path))
        XCTAssertTrue(WorktreeLinkInspector.canRepair(record, at: moved.path, commonDirectory: common.path))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(record, at: foreign.path, commonDirectory: common.path))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(record, at: root.path, commonDirectory: common.path))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(record, at: original.path, commonDirectory: root.appendingPathComponent("missing-common").path))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(GitWorktree(path: original.path, hasForeignLink: true), at: original.path, commonDirectory: common.path))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(GitWorktree(path: root.path), at: moved.path, commonDirectory: common.path))
        try "gitdir: /old/repo/.git/worktrees/id\n".write(to: moved.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertFalse(WorktreeLinkInspector.canRepair(record, at: moved.path, commonDirectory: common.path))
        XCTAssertTrue(WorktreeLinkInspector.canRepair(GitWorktree(path: original.path, movedPath: moved.path), at: moved.path, commonDirectory: common.path))
        try FileManager.default.removeItem(at: backlink)
        XCTAssertFalse(WorktreeLinkInspector.canRepair(record, at: moved.path, commonDirectory: common.path))
    }
}
