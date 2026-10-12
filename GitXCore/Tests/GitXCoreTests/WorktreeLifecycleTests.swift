@testable import GitXCore
import XCTest

final class WorktreePolicyTests: XCTestCase {
    func testDiscoveryCoalescesAndRejectsStaleCompletions() throws {
        var state = WorktreeRefreshState()
        let first = try XCTUnwrap(state.request())
        XCTAssertTrue(state.accepts(first))
        XCTAssertNil(state.request())
        XCTAssertNil(state.request())
        XCTAssertNil(state.complete(first + 1))
        let second = try XCTUnwrap(state.complete(first))
        XCTAssertFalse(state.accepts(first))
        XCTAssertTrue(state.accepts(second))
        XCTAssertNil(state.complete(second))
        XCTAssertFalse(state.accepts(second))
        let third = try XCTUnwrap(state.request())
        state.invalidate()
        XCTAssertFalse(state.accepts(third))
        XCTAssertNil(state.complete(third))
        XCTAssertNotNil(state.request())
        state.close()
        XCTAssertTrue(state.isClosed)
        XCTAssertNil(state.request())
        XCTAssertNil(state.complete(third))
    }

    func testLifecycleEligibilityProtectsMainCurrentLockedAndMovedEntries() {
        let normal = GitWorktree(path: "/linked", head: "abc", branchRefName: "refs/heads/topic")
        XCTAssertTrue(WorktreeEligibility(normal, supported: true).canRemove)
        XCTAssertTrue(WorktreeEligibility(normal, supported: true).canLock)
        XCTAssertTrue(WorktreeEligibility(normal, supported: true).canReveal)
        XCTAssertTrue(WorktreeEligibility(normal, supported: true).canOpen)
        XCTAssertFalse(WorktreeEligibility(normal, supported: true).canLocate)
        XCTAssertFalse(WorktreeEligibility(normal, supported: false).canRemove)
        let main = GitWorktree(path: "/main", isMain: true, isCurrent: true)
        XCTAssertFalse(WorktreeEligibility(main, supported: true).canRemove)
        XCTAssertFalse(WorktreeEligibility(main, supported: true).canLock)
        XCTAssertFalse(WorktreeEligibility(main, supported: true).canOpen)
        XCTAssertTrue(WorktreeEligibility(GitWorktree(path: "/bare", isBare: true), supported: true).canOpen)
        let locked = GitWorktree(path: "/locked", isLocked: true)
        XCTAssertFalse(WorktreeEligibility(locked, supported: true).canRemove)
        XCTAssertFalse(WorktreeEligibility(locked, supported: true).canLock)
        XCTAssertTrue(WorktreeEligibility(locked, supported: true).canUnlock)
        let missing = GitWorktree(path: "/missing", isPrunable: true, folderExists: false)
        XCTAssertTrue(WorktreeEligibility(missing, supported: true).canLocate)
        XCTAssertFalse(WorktreeEligibility(missing, supported: true).canReveal)
        XCTAssertTrue(WorktreeEligibility.canPrune([missing], supported: true))
        XCTAssertFalse(WorktreeEligibility.canPrune([missing], supported: false))
        XCTAssertFalse(WorktreeEligibility.canPrune([normal], supported: true))
        let moved = GitWorktree(path: "/old", movedPath: "/new", folderExists: false)
        XCTAssertFalse(WorktreeEligibility(moved, supported: true).canLocate)
        XCTAssertFalse(WorktreeEligibility.canPrune([missing, moved], supported: true))
    }

    func testForceRetryAndRepairDefaultsMatchUpstream() {
        XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: "fatal: contains modified files, use --force to delete it"))
        XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: "fatal: working trees containing submodules cannot be moved or removed"))
        for message in ["fatal: worktree is locked", "fatal: permission denied", "fatal: not a working tree", ""] {
            XCTAssertFalse(WorktreePolicy.offersForcedRemoval(gitMessage: message))
        }
        XCTAssertEqual(WorktreePolicy.preferredRepairStyle([]), .absolute)
        XCTAssertEqual(WorktreePolicy.preferredRepairStyle([.unknown]), .absolute)
        XCTAssertEqual(WorktreePolicy.preferredRepairStyle([.relative, .unknown]), .relative)
        XCTAssertEqual(WorktreePolicy.preferredRepairStyle([.absolute, .relative]), .absolute)
        XCTAssertEqual(WorktreePolicy.preferredRepairStyle([.mixed]), .absolute)
    }

    func testCommandConstructionAndPresentation() {
        XCTAssertEqual(WorktreeCommand.addExisting(path: "/a", branch: "topic").arguments, ["worktree", "add", "/a", "topic"])
        XCTAssertEqual(WorktreeCommand.addNew(path: "/a", branch: "topic").arguments, ["worktree", "add", "-b", "topic", "/a"])
        XCTAssertEqual(WorktreeCommand.remove(path: "/a", force: false).arguments, ["worktree", "remove", "/a"])
        XCTAssertEqual(WorktreeCommand.remove(path: "/a", force: true).arguments, ["worktree", "remove", "--force", "/a"])
        XCTAssertEqual(WorktreeCommand.lock(path: "/a", reason: "").arguments, ["worktree", "lock", "/a"])
        XCTAssertEqual(WorktreeCommand.lock(path: "/a", reason: "offline disk").arguments, ["worktree", "lock", "--reason", "offline disk", "/a"])
        XCTAssertEqual(WorktreeCommand.unlock(path: "/a").arguments, ["worktree", "unlock", "/a"])
        XCTAssertEqual(WorktreeCommand.prune.arguments, ["worktree", "prune"])
        XCTAssertEqual(WorktreeCommand.pruneReport.arguments, ["worktree", "prune", "--dry-run", "--verbose"])
        XCTAssertEqual(WorktreeCommand.repairMoved(path: "/new").arguments, ["worktree", "repair", "/new"])
        XCTAssertEqual(WorktreeCommand.repairLinks(style: .relative, movedPaths: ["/a"]).arguments, ["worktree", "repair", "--relative-paths", "/a"])
        XCTAssertEqual(WorktreeCommand.repairLinks(style: .absolute, movedPaths: []).arguments, ["worktree", "repair", "--no-relative-paths"])
        let state = GitWorktree(path: "/old", head: "123456789", branchRefName: "refs/heads/feature/topic", isMain: true,
                                isLocked: true, lockReason: "offline", isPrunable: true, prunableReason: "gone", isCurrent: true,
                                hasBrokenLink: true, movedPath: "/new", folderExists: false)
        XCTAssertEqual(WorktreePresentation.title(state), "feature/topic")
        for detail in ["/old", "Current worktree", "Main worktree", "Locked: offline", "Prunable: gone", "/new", "Broken", "unavailable"] {
            XCTAssertTrue(WorktreePresentation.details(state).contains(detail))
        }
        XCTAssertEqual(WorktreePresentation.title(GitWorktree(path: "/bare", isBare: true)), "Bare repository")
        XCTAssertEqual(WorktreePresentation.title(GitWorktree(path: "/a", head: "123456789", isDetached: true)), "Detached HEAD (1234567)")
        XCTAssertEqual(WorktreePresentation.title(GitWorktree(path: "/fallback")), "fallback")
        XCTAssertTrue(WorktreePresentation.details(GitWorktree(path: "/locked", isLocked: true, isPrunable: true)).contains("Locked\nPrunable"))
        XCTAssertEqual(WorktreePresentation.suggestedFolderName(mainPath: "/dev/MyProject.git", branch: "feature/new"), "MyProject-feature-new")
        XCTAssertTrue(WorktreePaths.contains("/repo/.git/refs", in: "/repo/.git"))
        XCTAssertTrue(WorktreePaths.contains("/repo/.git", in: "/repo/.git"))
        XCTAssertFalse(WorktreePaths.contains("/repo/.git-copy", in: "/repo/.git"))
    }
}

final class WorktreeLinkTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitXWorktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func git(_ arguments: [String], at directory: URL, succeeds: Bool = true) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = directory
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if succeeds {
            XCTAssertEqual(task.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        } else {
            XCTAssertNotEqual(task.terminationStatus, 0)
        }
        return data
    }

    private func repository(in root: URL) throws -> URL {
        let main = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], at: main)
        return main
    }

    private func records(at main: URL) throws -> [GitWorktree] {
        try WorktreeLinkInspector.inspect(WorktreeParser.parse(git(["worktree", "list", "--porcelain", "-z"], at: main)),
                                          commonDirectory: main.appendingPathComponent(".git").path, currentPath: main.path)
    }

    func testRealLifecycleKeepsBranchesAndGitProtectsDirtyLockedAndMainWorktrees() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let linked = root.appendingPathComponent("雪\ncheckout")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let snapshot = try records(at: main)
        XCTAssertTrue(snapshot[0].isCurrent)
        XCTAssertEqual(snapshot[1].path, WorktreePaths.canonical(linked.path))
        XCTAssertEqual(snapshot[1].linkStyle, .absolute)
        XCTAssertFalse(snapshot[1].hasBrokenLink)
        _ = try git(WorktreeCommand.lock(path: linked.path, reason: "offline\ndisk").arguments, at: main)
        XCTAssertTrue(try records(at: main)[1].isLocked)
        _ = try git(WorktreeCommand.remove(path: linked.path, force: false).arguments, at: main, succeeds: false)
        _ = try git(WorktreeCommand.unlock(path: linked.path).arguments, at: main)
        try Data("dirty".utf8).write(to: linked.appendingPathComponent("untracked"))
        let refusal = try git(WorktreeCommand.remove(path: linked.path, force: false).arguments, at: main, succeeds: false)
        XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: String(decoding: refusal, as: UTF8.self)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
        _ = try git(WorktreeCommand.remove(path: linked.path, force: true).arguments, at: main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        _ = try git(["show-ref", "--verify", "refs/heads/topic"], at: main)
        _ = try git(WorktreeCommand.remove(path: main.path, force: true).arguments, at: main, succeeds: false)
    }

    func testPruningPreviewAndRelativeLinks() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let linked = root.appendingPathComponent("relative")
        _ = try git(["worktree", "add", "--relative-paths", "-b", "relative", linked.path], at: main)
        XCTAssertEqual(try records(at: main)[1].linkStyle, .relative)
        let moved = root.appendingPathComponent("moved-main")
        try FileManager.default.moveItem(at: main, to: moved)
        XCTAssertTrue(try records(at: moved)[1].hasBrokenLink)
        _ = try git(WorktreeCommand.repairLinks(style: .absolute, movedPaths: []).arguments, at: moved)
        XCTAssertEqual(try records(at: moved)[1].linkStyle, .absolute)
        try FileManager.default.removeItem(at: linked)
        let report = try git(WorktreeCommand.pruneReport.arguments, at: moved)
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(try records(at: moved).count, 2)
        _ = try git(WorktreeCommand.prune.arguments, at: moved)
        XCTAssertEqual(try records(at: moved).count, 1)
    }

    func testMovedNestedAbsoluteWorktreeIsIdentifiedAndRepairVerified() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let nested = main.appendingPathComponent("checkouts/topic")
        _ = try git(WorktreeCommand.addNew(path: nested.path, branch: "topic").arguments, at: main)
        let moved = root.appendingPathComponent("moved-main")
        try FileManager.default.moveItem(at: main, to: moved)
        let before = try records(at: moved)
        XCTAssertTrue(before[1].hasBrokenLink)
        XCTAssertEqual(before[1].movedPath, WorktreePaths.canonical(moved.appendingPathComponent("checkouts/topic").path))
        XCTAssertFalse(WorktreeEligibility.canPrune(before, supported: true))
        _ = try git(WorktreeCommand.repairLinks(style: .absolute, movedPaths: [XCTUnwrap(before[1].movedPath)]).arguments, at: moved)
        let after = try records(at: moved)
        XCTAssertFalse(after[1].hasBrokenLink)
        XCTAssertNil(after[1].movedPath)
    }

    func testCopiedRepositoryLeavesExistingForeignLinkUntouched() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let linked = main.appendingPathComponent("topic")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let copy = root.appendingPathComponent("copied")
        try FileManager.default.copyItem(at: main, to: copy)
        var snapshot = try WorktreeParser.parse(git(["worktree", "list", "--porcelain", "-z"], at: copy))
        snapshot[1] = GitWorktree(path: copy.appendingPathComponent("topic").path, head: snapshot[1].head, branchRefName: snapshot[1].branchRefName)
        let admin = copy.appendingPathComponent(".git/worktrees/topic/gitdir")
        try (copy.appendingPathComponent("topic/.git").path + "\n").write(to: admin, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: copy.appendingPathComponent("topic/.git"))
        let inspected = WorktreeLinkInspector.inspect(snapshot, commonDirectory: copy.appendingPathComponent(".git").path, currentPath: copy.path)
        XCTAssertFalse(inspected[1].hasBrokenLink)
        XCTAssertTrue(inspected[1].hasForeignLink)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("topic/.git")), before)
    }

    func testBrokenRelativeLinksAndUnmatchedAdministrativeFolders() throws {
        let root = try temporaryDirectory()
        let common = root.appendingPathComponent("repo.git")
        let linked = root.appendingPathComponent("linked")
        let admin = common.appendingPathComponent("worktrees/id")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try (linked.appendingPathComponent(".git").path + "\n").write(to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "gitdir: ../missing\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let raw = [GitWorktree(path: common.path, isMain: true, isBare: true), GitWorktree(path: linked.path)]
        let broken = WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)
        XCTAssertTrue(broken[1].hasBrokenLink)
        XCTAssertEqual(broken[1].linkStyle, .relative)
        XCTAssertFalse(broken[1].isCurrent)
        try "not a gitdir link\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)[1].linkStyle, .unknown)
        try "gitdir: \n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertFalse(WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)[1].hasBrokenLink)
        try FileManager.default.removeItem(at: admin.appendingPathComponent("gitdir"))
        XCTAssertEqual(WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)[1].linkStyle, .unknown)
        XCTAssertEqual(WorktreeLinkInspector.inspect([], commonDirectory: "/missing", currentPath: nil), [])
    }
}
