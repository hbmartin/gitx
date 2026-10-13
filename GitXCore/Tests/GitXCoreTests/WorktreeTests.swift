@testable import GitXCore
import XCTest

final class WorktreeTests: XCTestCase {
    private func parse(_ fields: [String]) throws -> [GitWorktree] {
        try WorktreeParser.parse(Data((fields.joined(separator: "\0") + "\0").utf8))
    }

    func testMainLinkedDetachedBareAndStateRecords() throws {
        let records = try parse([
            "worktree /main", "HEAD abc", "branch refs/heads/main", "",
            "worktree /雪\ncheckout", "HEAD def", "detached", "locked reason\nwith newline", "prunable missing folder", "",
            "worktree /bare", "bare", "",
        ])
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records[0].isMain)
        XCTAssertEqual(records[0].branchRefName, "refs/heads/main")
        XCTAssertEqual(records[1].path, "/雪\ncheckout")
        XCTAssertTrue(records[1].isDetached)
        XCTAssertTrue(records[1].isLocked)
        XCTAssertEqual(records[1].lockReason, "reason\nwith newline")
        XCTAssertTrue(records[1].isPrunable)
        XCTAssertEqual(records[1].prunableReason, "missing folder")
        XCTAssertTrue(records[2].isBare)
        XCTAssertNil(records[2].head)
    }

    func testEmptyFlagsUnknownFieldsAndEmptySnapshot() throws {
        XCTAssertEqual(try WorktreeParser.parse(Data()), [])
        let record = try XCTUnwrap(parse(["worktree /main", "HEAD abc", "branch refs/heads/main", "locked", "prunable", "future-field ignored", ""]).first)
        XCTAssertTrue(record.isLocked)
        XCTAssertNil(record.lockReason)
        XCTAssertTrue(record.isPrunable)
        XCTAssertNil(record.prunableReason)
    }

    func testMalformedSnapshotsAreRejected() {
        for fields in [
            ["HEAD abc", ""], ["worktree ", "bare", ""],
            ["worktree relative", "bare", ""], ["worktree /missing-head", "detached", ""],
            ["worktree /main", "HEAD abc", ""],
            ["worktree /main", "HEAD abc", "branch refs/heads/main", "detached", ""],
            ["worktree /main", "bare", "HEAD abc", ""],
            ["worktree /main", "bare", "", "worktree /main", "bare", ""],
            ["worktree /main", "bare", "bare", ""],
        ] {
            XCTAssertThrowsError(try parse(fields), "\(fields)")
        }
        XCTAssertThrowsError(try WorktreeParser.parse(Data("worktree /main\0bare\0".utf8)))
        XCTAssertThrowsError(try WorktreeParser.parse(Data([0xFF, 0])))
    }

    func testPathsAndBranchIdentityPreserveUnicodeBytes() throws {
        let records = try parse(["worktree /é", "HEAD abc", "branch refs/heads/é", "", "worktree /e\u{301}", "HEAD abc", "branch refs/heads/e\u{301}", ""])
        XCTAssertNotEqual(records[0].identity, records[1].identity)
        XCTAssertNotEqual(records[0].branchIdentity, records[1].branchIdentity)
        XCTAssertNotEqual(records[0], records[1])
        XCTAssertEqual(records, try parse(["worktree /é", "HEAD abc", "branch refs/heads/é", "", "worktree /e\u{301}", "HEAD abc", "branch refs/heads/e\u{301}", ""]))
    }

    func testGitVersionMinimum() {
        for version in ["2.48", "git version 2.48.0", "git version 2.54.0 (Apple Git-157)", "3.0.0"] {
            XCTAssertTrue(WorktreePolicy.supports(version: version), version)
        }
        for version in [nil, "", "unknown", "2.47.9", "1.99", "2", "2.a", "git version"] {
            XCTAssertFalse(WorktreePolicy.supports(version: version), version ?? "nil")
        }
    }
}
