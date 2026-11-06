import XCTest

final class ReflogRecoveryCharacterizationTests: XCTestCase {
    func testReflogUsesEventTimeAndRetainsReplacedCommit() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["commit", "--amend", "--no-edit", "--date=2001-01-01T00:00:00Z"])
        let current = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(original, current)
        let output = try fixture.git(["reflog", "show", "--date=iso-strict", "--format=%H%x00%gD%x00%gs", "HEAD"])
        XCTAssertTrue(output.contains(original))
        XCTAssertTrue(output.contains("commit (amend)"))
        XCTAssertFalse(output.contains("HEAD@{2001-01-01"))
        XCTAssertEqual(try fixture.git(["show", "--format=%s", "--no-patch", original]), "initial")
    }

    func testResetModesSeparateHeadIndexAndWorkingCopy() throws {
        for mode in ["--soft", "--mixed", "--hard"] {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let target = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "second\n")
            try fixture.git(["commit", "-am", "second"])
            let previous = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "staged\n")
            try fixture.git(["add", "tracked.txt"])
            try fixture.write("tracked.txt", "working\n")
            try fixture.git(["branch", "recovery/before-reset", previous])
            try fixture.git(["reset", mode, "--no-recurse-submodules", target])
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
            XCTAssertEqual(try fixture.git(["rev-parse", "recovery/before-reset"]), previous)
            XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), mode == "--soft" ? "staged" : "initial")
            XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), mode == "--hard" ? "initial\n" : "working\n")
        }
    }

    func testHardResetRemovesObstructingIgnoredDirectoryButLeavesUnrelatedFiles() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.write("obstruction", "tracked target\n")
        try fixture.git(["add", "obstruction"])
        try fixture.git(["commit", "-m", "add target"])
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["rm", "obstruction"])
        try fixture.git(["commit", "-m", "remove target"])
        try fixture.write(".git/info/exclude", "obstruction/\n")
        try fixture.write("obstruction/ignored.txt", "local content\n")
        try fixture.write("unrelated.txt", "keep\n")
        try fixture.git(["reset", "--hard", target])
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("obstruction"), encoding: .utf8), "tracked target\n")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("unrelated.txt"), encoding: .utf8), "keep\n")
    }

    func testHeadReflogsAreLocalToEachWorktreeAndBranchReflogsAreShared() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let linked = fixture.url.appendingPathComponent("linked")
        try fixture.git(["worktree", "add", "-b", "topic", linked.path])
        try fixture.git(["-C", linked.path, "commit", "--allow-empty", "-m", "linked-only"])
        let linkedHead = try fixture.git(["-C", linked.path, "rev-parse", "HEAD"])
        XCTAssertFalse(try fixture.git(["reflog", "--format=%H", "HEAD"]).contains(linkedHead))
        XCTAssertTrue(try fixture.git(["-C", linked.path, "reflog", "--format=%H", "HEAD"]).contains(linkedHead))
        XCTAssertTrue(try fixture.git(["reflog", "--format=%H", "refs/heads/topic"]).contains(linkedHead))
    }
}

final class ReflogGitFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("GitXReflog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=main"])
        try git(["config", "user.name", "Reflog Tests"])
        try git(["config", "user.email", "reflog@example.invalid"])
        try write("tracked.txt", "initial\n")
        try git(["add", "tracked.txt"])
        try git(["commit", "--quiet", "-m", "initial"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ path: String, _ text: String) throws {
        let destination = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try GitXTestGitFixture.run(arguments, in: url).standardOutput.trimmingCharacters(in: .newlines)
    }
}
