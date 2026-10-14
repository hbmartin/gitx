import Foundation
import GitXCore
import XCTest

final class WorktreeSymbolicHeadTests: XCTestCase {
    private let oid = String(repeating: "a", count: 40)

    private func parse(_ fields: [String]) throws -> [GitWorktree] {
        try WorktreeParser.parse(Data((fields.joined(separator: "\0") + "\0").utf8))
    }

    private func record(_ reference: String, path: String = "/linked") -> [String] {
        ["worktree " + path, "HEAD " + oid, "branch " + reference, ""]
    }

    private func gitAcceptsFullRef(_ reference: String) throws -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["check-ref-format", reference]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["LC_ALL"] = "C"
        task.environment = environment
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    func testMixedInventoryRetainsNonLocalSymbolicHeadsAsNonDetachedRecords() throws {
        let references = ["refs/tags/release", "refs/remotes/origin/main", "refs/notes/custom", "refs/custom"]
        var fields = record("refs/heads/main", path: "/main")
        fields += ["worktree /detached", "HEAD " + oid, "detached", ""]
        fields += ["worktree /bare", "bare", ""]
        for (index, reference) in references.enumerated() {
            XCTAssertTrue(try gitAcceptsFullRef(reference), reference)
            fields += record(reference, path: "/symbolic-\(index)")
        }
        let records = try parse(fields)
        XCTAssertEqual(records.count, 7)
        XCTAssertTrue(records[0].isMain)
        XCTAssertFalse(records[0].isDetached)
        XCTAssertEqual(records[0].branchRefName, "refs/heads/main")
        XCTAssertEqual(WorktreePresentation.title(records[0]), "main")
        XCTAssertFalse(records[1].isMain)
        XCTAssertTrue(records[1].isDetached)
        XCTAssertNil(records[1].branchRefName)
        XCTAssertEqual(WorktreePresentation.title(records[1]), "Detached HEAD (aaaaaaa)")
        XCTAssertTrue(records[2].isBare)
        XCTAssertNil(records[2].head)
        XCTAssertEqual(WorktreePresentation.title(records[2]), "Bare repository")
        for (index, reference) in references.enumerated() {
            let linked = records[index + 3]
            XCTAssertFalse(linked.isMain)
            XCTAssertFalse(linked.isDetached)
            XCTAssertNil(linked.branchIdentity, reference)
            XCTAssertNil(linked.branchRefName, reference)
            XCTAssertEqual(linked.headRefIdentity, Data(reference.utf8))
            XCTAssertEqual(linked.headRefName, reference)
            XCTAssertEqual(linked.head, oid)
            XCTAssertEqual(WorktreePresentation.title(linked), "HEAD → " + reference)
        }
    }

    func testLegacyReferenceInputClassifiesLocalBranchesAndKeepsFullSymbolicTitles() {
        let local = GitWorktree(path: "/local", head: oid, branchRefName: "refs/heads/feature/topic")
        XCTAssertEqual(local.branchIdentity, Data("refs/heads/feature/topic".utf8))
        XCTAssertEqual(local.branchRefName, "refs/heads/feature/topic")
        XCTAssertEqual(local.headRefIdentity, local.branchIdentity)
        XCTAssertEqual(local.headRefName, local.branchRefName)
        XCTAssertEqual(WorktreePresentation.title(local), "feature/topic")
        for reference in ["refs/tags/release", "refs/remotes/origin/main", "refs/notes/é", "refs/notes/e\u{301}"] {
            let symbolic = GitWorktree(path: "/symbolic", head: oid, branchRefName: reference)
            XCTAssertFalse(symbolic.isDetached)
            XCTAssertNil(symbolic.branchIdentity, reference)
            XCTAssertNil(symbolic.branchRefName, reference)
            XCTAssertEqual(symbolic.headRefIdentity, Data(reference.utf8))
            XCTAssertEqual(symbolic.headRefName, reference)
            XCTAssertEqual(WorktreePresentation.title(symbolic), "HEAD → " + reference)
        }
    }

    func testLinkInspectionReconstructsNonLocalSymbolicHeadWithoutLosingItsTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-symbolic-head-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("linked")
        let common = root.appendingPathComponent("common")
        let administrative = common.appendingPathComponent("worktrees/linked")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: administrative, withIntermediateDirectories: true)
        try Data((checkout.appendingPathComponent(".git").path + "\n").utf8).write(to: administrative.appendingPathComponent("gitdir"))
        try Data(("gitdir: " + administrative.path + "\n").utf8).write(to: checkout.appendingPathComponent(".git"))
        let path = checkout.path
        for reference in ["refs/tags/release", "refs/remotes/origin/main", "refs/custom"] {
            let symbolic = GitWorktree(path: path, head: oid, branchRefName: reference)
            let records = WorktreeLinkInspector.inspect([symbolic], commonDirectory: common.path, currentPath: path)
            XCTAssertEqual(records.count, 1)
            let inspected = records[0]
            XCTAssertEqual(inspected.identity, symbolic.identity)
            XCTAssertEqual(inspected.head, oid)
            XCTAssertFalse(inspected.isDetached)
            XCTAssertTrue(inspected.isCurrent)
            XCTAssertTrue(inspected.folderExists)
            XCTAssertEqual(inspected.linkStyle, .absolute)
            XCTAssertFalse(inspected.hasBrokenLink)
            XCTAssertFalse(inspected.hasForeignLink)
            XCTAssertNil(inspected.branchIdentity, reference)
            XCTAssertNil(inspected.branchRefName, reference)
            XCTAssertEqual(inspected.headRefIdentity, symbolic.headRefIdentity)
            XCTAssertEqual(inspected.headRefName, reference)
            XCTAssertEqual(WorktreePresentation.title(inspected), "HEAD → " + reference)
        }
    }

    func testFullReferenceValidationAgreesWithGitWithoutNormalizingItsInput() throws {
        let valid = ["refs/heads/-topic", "refs/heads/topic", "refs/tags/release", "refs/remotes/origin/main", "refs/custom", "refs/notes/é", "refs/notes/e\u{301}", "refs/tags/a]b", "refs/tags/@", "refs/tags/visible.LOCK", "refs/notes/a./b", "refs/tags/a\u{A0}b"]
        for reference in valid {
            XCTAssertTrue(try gitAcceptsFullRef(reference), reference)
            XCTAssertNoThrow(try parse(record(reference)), reference)
        }
        let malformed = ["", "a//b", ".hidden", "a/.hidden", "a.lock", "a/b.lock", "a..b", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a@{b}", "a.", "a/", "a\u{1F}b", "a\u{7F}b", "a\nb"]
        for namespace in ["refs/heads/", "refs/tags/"] {
            for suffix in malformed {
                let reference = namespace + suffix
                XCTAssertFalse(try gitAcceptsFullRef(reference), reference)
                XCTAssertThrowsError(try parse(record(reference)), reference)
            }
        }
        for reference in ["HEAD", "refs", "/refs/tags/release", "refs/.hidden/topic", "refs/namespace.lock/topic"] {
            XCTAssertFalse(try gitAcceptsFullRef(reference), reference)
            XCTAssertThrowsError(try parse(record(reference)), reference)
        }
    }

    func testForbiddenReferencePairsMatchGitBytesBesideCombiningMarks() throws {
        for namespace in ["refs/heads/", "refs/tags/"] {
            for suffix in ["a..\u{301}b", "a@{\u{301}b"] {
                let reference = namespace + suffix
                XCTAssertFalse(try gitAcceptsFullRef(reference), reference)
                XCTAssertThrowsError(try parse(record(reference)), reference)
            }
            for suffix in ["a.\u{301}.b", "a@\u{301}{b"] {
                let reference = namespace + suffix
                XCTAssertTrue(try gitAcceptsFullRef(reference), reference)
                let value = try XCTUnwrap(parse(record(reference)).first)
                XCTAssertEqual(value.headRefIdentity, Data(reference.utf8))
            }
        }
    }

    func testRawSymbolicIdentityPreservesUnicodeAndExplicitInputIsAuthoritative() throws {
        let composed = "refs/notes/é"
        let decomposed = "refs/notes/e\u{301}"
        let records = try parse(record(composed, path: "/composed") + record(decomposed, path: "/decomposed"))
        XCTAssertEqual(records[0].headRefIdentity, Data(composed.utf8))
        XCTAssertEqual(records[1].headRefIdentity, Data(decomposed.utf8))
        XCTAssertNotEqual(records[0].headRefIdentity, records[1].headRefIdentity)
        for reference in [composed, decomposed] {
            let value = GitWorktree(path: "/same-path", head: oid, headRefName: reference)
            XCTAssertEqual(try Data(XCTUnwrap(value.headRefName).utf8), Data(reference.utf8))
            XCTAssertNil(value.branchIdentity)
        }
        XCTAssertNotEqual(GitWorktree(path: "/same-path", headRefName: composed), GitWorktree(path: "/same-path", headRefName: decomposed))
        let symbolicOverride = GitWorktree(path: "/override", branchRefName: "refs/heads/legacy", headRefName: composed)
        XCTAssertEqual(symbolicOverride.headRefIdentity, Data(composed.utf8))
        XCTAssertNil(symbolicOverride.branchIdentity)
        let localOverride = GitWorktree(path: "/override", branchRefName: composed, headRefName: "refs/heads/new")
        XCTAssertEqual(localOverride.headRefName, "refs/heads/new")
        XCTAssertEqual(localOverride.branchRefName, "refs/heads/new")
        let emptyOverride = GitWorktree(path: "/override", branchRefName: "refs/heads/legacy", headRefName: "")
        XCTAssertEqual(emptyOverride.headRefIdentity, Data())
        XCTAssertNil(emptyOverride.branchIdentity)
        XCTAssertNil(GitWorktree(path: "/incomplete", headRefName: "refs/heads/").branchIdentity)
        for value in [GitWorktree(path: "/default"), GitWorktree(path: "/bare", isBare: true), GitWorktree(path: "/detached", head: oid, isDetached: true)] {
            XCTAssertNil(value.headRefIdentity)
            XCTAssertNil(value.headRefName)
            XCTAssertNil(value.branchIdentity)
        }
    }

    func testHistoryUsesCapturedCommitsForSymbolicAndDetachedHeadsAndKeepsUnbornBranches() {
        let reference = "refs/tags/release"
        let symbolic = GitWorktree(path: "/symbolic", head: oid, headRefName: reference)
        XCTAssertEqual(WorktreePresentation.historyRevision(for: symbolic), .capturedCommit(oid: oid, description: "HEAD → \(reference) (\(oid))"))
        let detached = GitWorktree(path: "/detached", head: oid, isDetached: true)
        XCTAssertEqual(WorktreePresentation.historyRevision(for: detached), .capturedCommit(oid: oid, description: "Detached HEAD (\(oid))"))
        for head in [nil, "", String(repeating: "0", count: 40), String(repeating: "0", count: 64)] {
            XCTAssertNil(WorktreePresentation.historyRevision(for: GitWorktree(path: "/symbolic", head: head, headRefName: reference)))
            XCTAssertNil(WorktreePresentation.historyRevision(for: GitWorktree(path: "/detached", head: head, isDetached: true)))
            XCTAssertEqual(WorktreePresentation.historyRevision(for: GitWorktree(path: "/local", head: head, headRefName: "refs/heads/unborn")), .branch("refs/heads/unborn"))
        }
        XCTAssertEqual(WorktreePresentation.historyRevision(for: GitWorktree(path: "/partial-zero", head: "0001", headRefName: reference)), .capturedCommit(oid: "0001", description: "HEAD → \(reference) (0001)"))
        XCTAssertNil(WorktreePresentation.historyRevision(for: GitWorktree(path: "/unmarked", head: oid)))
        XCTAssertNil(WorktreePresentation.historyRevision(for: GitWorktree(path: "/bare", isBare: true)))
    }

    func testNonLocalReferencesDoNotWeakenMalformedInventoryRejection() {
        let valid = record("refs/heads/main", path: "/main")
        for fields in [
            ["worktree /invalid", "HEAD " + oid, "branch refs/tags/release", "detached", ""],
            ["worktree /invalid", "bare", "branch refs/tags/release", ""],
            ["worktree /invalid", "branch refs/tags/release", ""],
            ["worktree /invalid", "HEAD ", "branch refs/tags/release", ""],
            ["worktree /invalid", "HEAD " + oid, "branch refs/tags/release", "branch refs/heads/topic", ""],
            ["worktree /invalid", "HEAD " + oid, "branch refs/tags/release", "bare value", ""],
            ["worktree /invalid", "HEAD " + oid, "detached value", ""],
        ] {
            XCTAssertThrowsError(try parse(valid + fields), "\(fields)")
        }
        var invalidUTF8 = Data((valid.joined(separator: "\0") + "\0worktree /invalid\0HEAD " + oid + "\0branch refs/tags/").utf8)
        invalidUTF8.append(contentsOf: [255, 0, 0])
        XCTAssertThrowsError(try WorktreeParser.parse(invalidUTF8))
        XCTAssertEqual(try parse(valid + record("refs/tags/a\0b")).last?.headRefIdentity, Data("refs/tags/a".utf8), "NUL frames b as an unknown field, which remains forward compatible")
        let truncated = Data((valid.joined(separator: "\0") + "\0worktree /invalid\0HEAD " + oid + "\0branch refs/tags/a\0").utf8)
        XCTAssertThrowsError(try WorktreeParser.parse(truncated))
    }

    func testRealGitSymbolicHeadsRemainCompleteAndInspectable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-symbolic-git-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], at: main)
        _ = try git(["worktree", "add", "-b", "topic", linked.path], at: main)
        let head = try String(decoding: git(["rev-parse", "HEAD"], at: main), as: UTF8.self).trimmingCharacters(in: .newlines)
        for reference in ["refs/tags/release", "refs/remotes/origin/main", "refs/notes/é", "refs/notes/e\u{301}", "refs/custom"] {
            _ = try git(["update-ref", reference, head], at: main)
            _ = try git(["symbolic-ref", "HEAD", reference], at: linked)
            let porcelain = try git(["worktree", "list", "--porcelain", "-z"], at: main)
            let branchPrefix = Data("branch ".utf8)
            let branchFields = porcelain.split(separator: 0).filter { $0.starts(with: branchPrefix) }
            XCTAssertEqual(branchFields.count, 2)
            // Git may precompose command-line names on macOS. The independent
            // byte oracle is its emitted field, not the original argument.
            let reportedIdentity = try Data(XCTUnwrap(branchFields.last).dropFirst(branchPrefix.count))
            let reportedName = try XCTUnwrap(String(data: reportedIdentity, encoding: .utf8))
            XCTAssertEqual(reportedName, reference)
            let snapshot = try WorktreeParser.parse(porcelain)
            XCTAssertEqual(snapshot.count, 2)
            XCTAssertEqual(snapshot[0].branchRefName, "refs/heads/main")
            let inspected = WorktreeLinkInspector.inspect(snapshot, commonDirectory: main.appendingPathComponent(".git").path, currentPath: linked.path)
            let symbolic = inspected[1]
            XCTAssertEqual(symbolic.headRefIdentity, reportedIdentity)
            XCTAssertNil(symbolic.branchIdentity)
            XCTAssertFalse(symbolic.isDetached)
            XCTAssertTrue(symbolic.isCurrent)
            XCTAssertEqual(symbolic.head, head)
            XCTAssertEqual(WorktreePresentation.title(symbolic), "HEAD → " + reportedName)
            XCTAssertEqual(WorktreePresentation.historyRevision(for: symbolic), .capturedCommit(oid: head, description: "HEAD → \(reportedName) (\(head))"))
        }
    }

    private func git(_ arguments: [String], at directory: URL) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return data
    }
}
