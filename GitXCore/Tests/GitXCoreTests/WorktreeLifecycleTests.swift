@testable import GitXCore
import XCTest

final class WorktreePolicyTests: XCTestCase {
    func testFreshLifecycleEligibilityRejectsRemovedAndLockedTargetsAndUnsupportedGit() {
        let main = GitWorktree(path: "/main", isMain: true, isCurrent: true)
        let linked = GitWorktree(path: "/linked")
        let locked = GitWorktree(path: "/linked", isLocked: true)
        XCTAssertTrue(WorktreeEligibility.allows(.remove(path: "/linked", force: false), records: [main, linked], supported: true))
        XCTAssertFalse(WorktreeEligibility.allows(.remove(path: "/linked", force: true), records: [main, locked], supported: true))
        for command in [WorktreeCommand.remove(path: "/linked", force: false), .lock(path: "/linked", reason: ""), .unlock(path: "/linked")] {
            XCTAssertFalse(WorktreeEligibility.allows(command, records: [main], supported: true))
            XCTAssertFalse(WorktreeEligibility.allows(command, records: [main, linked], supported: false))
        }
        XCTAssertFalse(WorktreeEligibility.allows(.remove(path: "/main", force: true), records: [main], supported: true))
        XCTAssertTrue(WorktreeEligibility.allows(.lock(path: "/linked", reason: ""), records: [main, linked], supported: true))
        XCTAssertTrue(WorktreeEligibility.allows(.unlock(path: "/linked"), records: [main, locked], supported: true))
        XCTAssertTrue(WorktreeEligibility.allows(.addNew(path: "/new", branch: "topic"), records: [], supported: true))
        XCTAssertTrue(WorktreeEligibility.allows(.addExisting(path: "/new", branch: "topic"), records: [], supported: true))
        for command in [WorktreeCommand.prune, .pruneReport, .repairLinks(style: .absolute, movedPaths: [])] {
            XCTAssertFalse(WorktreeEligibility.allows(command, records: [], supported: true))
        }
    }

    func testStaleRemovalRequiresAnotherConfirmationWhenConsentMetadataOrBranchChanges() {
        let original = GitWorktree(path: "/linked", head: "old", branchRefName: "refs/heads/topic")
        let command = WorktreeCommand.remove(path: "/linked", force: false)
        let committed = GitWorktree(path: "/linked", head: "new", branchRefName: "refs/heads/topic")
        XCTAssertFalse(WorktreeEligibility.allows(command, records: [committed], supported: true, previousRecords: [original]))
        for replacement in [GitWorktree(path: "/linked", branchRefName: "refs/heads/other"),
                            GitWorktree(path: "/linked", branchRefName: "refs/heads/topic", hasBrokenLink: true)]
        {
            XCTAssertFalse(WorktreeEligibility.allows(command, records: [replacement], supported: true, previousRecords: [original]))
        }
        XCTAssertFalse(WorktreeEligibility.allows(command, records: [original], supported: true, previousRecords: []))
    }

    func testReconciliationSatisfiesEarlierInvalidationsWithoutAnotherDiscovery() throws {
        var state = WorktreeRefreshState()
        let earlier = try XCTUnwrap(state.request())
        XCTAssertNil(state.request())
        let owned = try XCTUnwrap(state.beginReconciliation())
        XCTAssertFalse(state.accepts(earlier))
        XCTAssertNil(state.completeReconciliation(owned, succeeded: true))
        XCTAssertFalse(state.isStale)
        state.invalidate()
        XCTAssertTrue(state.isStale)
        state.didPublishSnapshot()
        XCTAssertFalse(state.isStale)
    }

    func testRemovalConsentIncludesExactHistoryAndPreservesUnchangedApproval() {
        let original = GitWorktree(path: "/linked", head: "A", branchRefName: "refs/heads/topic")
        let consent = WorktreeRemovalConsent(original)
        XCTAssertNil(WorktreeEligibility.removalRejection(path: original.path, records: [original], consent: consent))
        let replacements = [
            GitWorktree(path: original.path, head: "B", branchRefName: "refs/heads/topic"),
            GitWorktree(path: original.path, head: "A", headRefName: "refs/tags/topic"),
            GitWorktree(path: original.path, head: "A", isDetached: true),
            GitWorktree(path: original.path, head: "A", branchRefName: "refs/heads/topic", isLocked: true),
        ]
        for replacement in replacements {
            XCTAssertEqual(WorktreeEligibility.removalRejection(path: original.path, records: [replacement], consent: consent), .changedConsent)
            for force in [false, true] {
                XCTAssertFalse(WorktreeEligibility.allows(.remove(path: original.path, force: force), records: [replacement], supported: true, previousRecords: [original]))
            }
        }
        let detached = GitWorktree(path: original.path, head: "A", isDetached: true)
        let advanced = GitWorktree(path: original.path, head: "B", isDetached: true)
        XCTAssertNotEqual(WorktreeRemovalConsent(detached), WorktreeRemovalConsent(advanced))
        XCTAssertEqual(WorktreeConsentRecord(detached), WorktreeConsentRecord(advanced), "Repair and prune consent remains history-insensitive")
        XCTAssertEqual(WorktreeEligibility.removalRejection(path: original.path, records: [], consent: consent), .changedConsent)
        XCTAssertEqual(WorktreeEligibility.removalRejection(path: original.path, records: [original], consent: nil), .missingConsent)
        XCTAssertTrue(WorktreeRemovalRejection.missingConsent.localizedDescription.contains("previously reviewed"))
        XCTAssertTrue(WorktreeRemovalRejection.changedConsent.localizedDescription.contains("Review the refreshed"))
        for (record, reason) in [(GitWorktree(path: "/linked", isMain: true), WorktreeRemovalRejection.mainWorktree),
                                 (GitWorktree(path: "/linked", isCurrent: true), .currentWorktree),
                                 (GitWorktree(path: "/linked", isLocked: true), .lockedWorktree)]
        {
            XCTAssertEqual(WorktreeEligibility.removalRejection(path: record.path, records: [record], consent: WorktreeRemovalConsent(record)), reason)
            XCTAssertFalse(reason.localizedDescription.isEmpty)
        }
    }

    func testOwnedPreflightRetiresOrdinaryReadAndOnlyReplaysLaterInvalidations() throws {
        for succeeds in [false, true] {
            var state = WorktreeRefreshState()
            state.didPublishSnapshot()
            let ordinary = try XCTUnwrap(state.request())
            XCTAssertNil(state.request())
            let owned = try XCTUnwrap(state.beginOwnedDiscovery())
            XCTAssertTrue(state.isReading)
            XCTAssertFalse(state.isStale)
            XCTAssertFalse(state.accepts(ordinary))
            XCTAssertNil(state.complete(ordinary))
            XCTAssertNil(state.completeOwnedDiscovery(owned, succeeded: succeeds))
            XCTAssertEqual(state.isStale, !succeeds)
            XCTAssertFalse(state.isReading)
            let nextOwned = try XCTUnwrap(state.beginOwnedDiscovery())
            XCTAssertNil(state.request())
            let followup = try XCTUnwrap(state.completeOwnedDiscovery(nextOwned, succeeded: true))
            XCTAssertTrue(state.accepts(followup))
            XCTAssertNil(state.complete(followup))
        }
    }

    func testReconciliationRetiresOrdinaryReadAndPreservesInvalidations() throws {
        var state = WorktreeRefreshState()
        let ordinary = try XCTUnwrap(state.request())
        XCTAssertNil(state.request())
        let owned = try XCTUnwrap(state.beginReconciliation())
        XCTAssertFalse(state.accepts(ordinary))
        XCTAssertNil(state.complete(ordinary))
        XCTAssertNil(state.request())
        XCTAssertTrue(state.isStale)
        let followup = try XCTUnwrap(state.completeReconciliation(owned, succeeded: true))
        XCTAssertFalse(state.isStale)
        XCTAssertTrue(state.accepts(followup))
        XCTAssertNil(state.completeReconciliation(owned, succeeded: false))
        XCTAssertNil(state.complete(followup))
        XCTAssertFalse(state.isStale)
    }

    func testSuccessfulOwnedPassNeedsNoRecoveryWithoutAnInvalidation() throws {
        var state = WorktreeRefreshState()
        let owned = try XCTUnwrap(state.beginReconciliation())
        XCTAssertNil(state.completeReconciliation(owned, succeeded: true))
        XCTAssertFalse(state.isStale)
        XCTAssertNotNil(state.request())
    }

    func testFailedReconciliationSchedulesOnlyOneAutomaticRecoveryRead() throws {
        var state = WorktreeRefreshState()
        let owned = try XCTUnwrap(state.beginReconciliation())
        let retry = try XCTUnwrap(state.completeReconciliation(owned, succeeded: false))
        XCTAssertTrue(state.isStale)
        XCTAssertNil(state.complete(retry, succeeded: false))
        XCTAssertTrue(state.isStale)
        let explicit = try XCTUnwrap(state.request())
        XCTAssertNil(state.complete(explicit))
        XCTAssertFalse(state.isStale)
    }

    func testEventsDuringRecoveryRequestAnotherPassWithoutLoopingOnFailure() throws {
        var state = WorktreeRefreshState()
        let owned = try XCTUnwrap(state.beginReconciliation())
        let retry = try XCTUnwrap(state.completeReconciliation(owned, succeeded: false))
        XCTAssertNil(state.request())
        let next = try XCTUnwrap(state.complete(retry, succeeded: false))
        XCTAssertTrue(state.isStale)
        XCTAssertNil(state.complete(next))
        XCTAssertFalse(state.isStale)
    }

    func testReconciliationCompletionCannotCrossExecutableInvalidationOrClose() throws {
        for closing in [false, true] {
            var state = WorktreeRefreshState()
            let owned = try XCTUnwrap(state.beginReconciliation())
            if closing {
                state.close()
            } else {
                state.invalidate()
            }
            XCTAssertNil(state.completeReconciliation(owned, succeeded: false))
            XCTAssertTrue(state.isStale)
            if closing {
                XCTAssertNil(state.request())
                XCTAssertNil(state.beginReconciliation())
            } else {
                let fresh = try XCTUnwrap(state.request())
                XCTAssertNil(state.complete(fresh))
                XCTAssertFalse(state.isStale)
            }
        }
    }

    func testOverlappingOwnedPassCannotReplaceTheCurrentReconciliation() throws {
        var state = WorktreeRefreshState()
        let owned = try XCTUnwrap(state.beginReconciliation())
        XCTAssertNil(state.beginReconciliation())
        XCTAssertNil(state.completeReconciliation(owned + 1, succeeded: false))
        XCTAssertNil(state.complete(owned))
        let next = try XCTUnwrap(state.completeReconciliation(owned, succeeded: true))
        XCTAssertNil(state.complete(next))
        XCTAssertNil(state.completeReconciliation(owned, succeeded: true))
    }

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
        XCTAssertTrue(WorktreeEligibility.canPrune([normal], supported: true))
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
        XCTAssertEqual(WorktreePolicy.manualRepairPaths([]), [])
        XCTAssertEqual(WorktreePolicy.manualRepairPaths([GitWorktree(path: "/main", isMain: true), GitWorktree(path: "/original")]), [])
        let regularMoved = GitWorktree(path: "/old", hasBrokenLink: true, movedPath: "/new", folderExists: false)
        let unsupportedMoved = GitWorktree(path: "/old-unsupported", movedPath: "/manual", folderExists: false)
        XCTAssertEqual(WorktreePolicy.manualRepairPaths([regularMoved, unsupportedMoved]), ["/manual"])
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

    func testMissingEmptyAndMalformedOriginalGitfilesRequireReclaimAndPreserveCheckout() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let tracked = main.appendingPathComponent("tracked.txt")
        try Data("tracked content\n".utf8).write(to: tracked)
        _ = try git(["add", "tracked.txt"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "tracked fixture"], at: main)
        let linked = root.appendingPathComponent("linked")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let common = main.appendingPathComponent(".git")
        let dotGit = linked.appendingPathComponent(".git")
        let originalLink = try Data(contentsOf: dotGit)
        let originalHead = try git(["rev-parse", "HEAD"], at: linked)
        let originalBranch = try git(["symbolic-ref", "HEAD"], at: linked)
        let index = common.appendingPathComponent("worktrees/linked/index")
        let originalIndex = try Data(contentsOf: index)
        let originalContent = try Data(contentsOf: linked.appendingPathComponent("tracked.txt"))
        let damagedLinks: [Data?] = [nil, Data(), Data("gitdir: \n".utf8), Data("not a gitfile\n".utf8)]
        for (caseIndex, damaged) in damagedLinks.enumerated() {
            if let damaged {
                try damaged.write(to: dotGit)
            } else {
                try FileManager.default.removeItem(at: dotGit)
            }
            let broken = try XCTUnwrap(records(at: main).first { !$0.isMain })
            XCTAssertTrue(broken.folderExists, "case \(caseIndex)")
            XCTAssertTrue(broken.hasBrokenLink, "case \(caseIndex)")
            XCTAssertFalse(broken.hasForeignLink, "case \(caseIndex)")
            XCTAssertFalse(WorktreeLinkInspector.canRepair(broken, at: linked.path, commonDirectory: common.path), "case \(caseIndex)")
            let target = try WorktreeLinkInspector.captureRepairTarget(broken, at: linked.path, commonDirectory: common.path)
            XCTAssertTrue(target.requiresReclaim)
            try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: common.path)
            _ = try git(WorktreeCommand.repairLinks(style: .absolute, movedPaths: []).arguments, at: main)
            let repaired = try XCTUnwrap(records(at: main).first { !$0.isMain })
            XCTAssertFalse(repaired.hasBrokenLink)
            XCTAssertFalse(repaired.hasForeignLink)
            XCTAssertEqual(repaired.path, WorktreePaths.canonical(linked.path))
            XCTAssertEqual(try Data(contentsOf: dotGit), originalLink)
            XCTAssertEqual(try git(["rev-parse", "HEAD"], at: linked), originalHead)
            XCTAssertEqual(try git(["symbolic-ref", "HEAD"], at: linked), originalBranch)
            XCTAssertEqual(try Data(contentsOf: index), originalIndex)
            XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent("tracked.txt")), originalContent)
            try WorktreeLinkInspector.verifyRepairTarget(target, records: records(at: main), commonDirectory: common.path, style: .absolute)
        }
    }

    func testValidSymlinkGitfileRemainsBrowsableAndRepairPreservesItsObject() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let linked = root.appendingPathComponent("linked")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let gitfile = root.appendingPathComponent("gitfile")
        try FileManager.default.moveItem(at: linked.appendingPathComponent(".git"), to: gitfile)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".git"), withDestinationURL: gitfile)
        _ = try git(["status", "--porcelain"], at: linked)
        let inspected = try XCTUnwrap(records(at: main).first { !$0.isMain })
        XCTAssertFalse(inspected.hasBrokenLink)
        XCTAssertFalse(inspected.hasForeignLink)
        XCTAssertTrue(WorktreeEligibility(inspected, supported: true).canOpen)
        XCTAssertFalse(WorktreeLinkInspector.canRepair(inspected, at: linked.path, commonDirectory: main.appendingPathComponent(".git").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.appendingPathComponent(".git").path), gitfile.path)
    }

    func testStaleOriginalGitfileSymlinkDoesNotAdvertiseAutomaticRepairAndPreservesMetadata() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let tracked = main.appendingPathComponent("tracked.txt")
        try Data("tracked content\n".utf8).write(to: tracked)
        _ = try git(["add", "tracked.txt"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "tracked fixture"], at: main)
        let linked = root.appendingPathComponent("linked")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let common = main.appendingPathComponent(".git")
        let administrative = common.appendingPathComponent("worktrees/linked")
        let dotGit = linked.appendingPathComponent(".git")
        let gitfile = root.appendingPathComponent("gitfile")
        let staleLink = Data(("gitdir: " + root.appendingPathComponent("missing/worktrees/linked").path + "\n").utf8)
        try staleLink.write(to: gitfile)
        try FileManager.default.removeItem(at: dotGit)
        try FileManager.default.createSymbolicLink(at: dotGit, withDestinationURL: gitfile)
        let symlink = try WorktreeEvidenceFileSystem.metadataAtPath(dotGit.path)
        let target = try WorktreeFileIdentity.capture(path: gitfile.path)
        let metadata = try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: administrative.appendingPathComponent($0)) }
        let content = try Data(contentsOf: linked.appendingPathComponent("tracked.txt"))

        let inspected = try XCTUnwrap(records(at: main).first { !$0.isMain })
        XCTAssertFalse(inspected.hasBrokenLink, "A stale symlink cannot be reconstructed safely")
        XCTAssertEqual(WorktreePolicy.manualRepairPaths([inspected]), [])
        XCTAssertNil(inspected.movedPath)
        XCTAssertFalse(inspected.hasForeignLink)
        XCTAssertTrue(inspected.folderExists)
        XCTAssertFalse(WorktreeLinkInspector.canRepair(inspected, at: linked.path, commonDirectory: common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(inspected, at: linked.path, commonDirectory: common.path))
        XCTAssertEqual(try WorktreeEvidenceFileSystem.metadataAtPath(dotGit.path), symlink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dotGit.path), gitfile.path)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: gitfile.path), target)
        XCTAssertEqual(try Data(contentsOf: gitfile), staleLink)
        XCTAssertEqual(try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: administrative.appendingPathComponent($0)) }, metadata)
        XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent("tracked.txt")), content)
    }

    func testMovedStaleGitfileSymlinkRetainsPruneProtectionWithoutAdvertisingAutomaticRepair() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let tracked = main.appendingPathComponent("tracked.txt")
        try Data("tracked content\n".utf8).write(to: tracked)
        _ = try git(["add", "tracked.txt"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "tracked fixture"], at: main)
        let nested = main.appendingPathComponent("checkouts/topic")
        _ = try git(WorktreeCommand.addNew(path: nested.path, branch: "topic").arguments, at: main)
        let gitfile = root.appendingPathComponent("gitfile")
        let staleLink = try Data(contentsOf: nested.appendingPathComponent(".git"))
        try FileManager.default.moveItem(at: nested.appendingPathComponent(".git"), to: gitfile)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent(".git"), withDestinationURL: gitfile)
        let movedMain = root.appendingPathComponent("moved-main")
        try FileManager.default.moveItem(at: main, to: movedMain)
        let moved = movedMain.appendingPathComponent("checkouts/topic")
        let common = movedMain.appendingPathComponent(".git")
        let administrative = common.appendingPathComponent("worktrees/topic")
        let dotGit = moved.appendingPathComponent(".git")
        let symlink = try WorktreeEvidenceFileSystem.metadataAtPath(dotGit.path)
        let target = try WorktreeFileIdentity.capture(path: gitfile.path)
        let metadata = try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: administrative.appendingPathComponent($0)) }
        let content = try Data(contentsOf: moved.appendingPathComponent("tracked.txt"))

        let snapshot = try records(at: movedMain)
        let inspected = try XCTUnwrap(snapshot.first { !$0.isMain })
        XCTAssertEqual(inspected.movedPath, WorktreePaths.canonical(moved.path))
        XCTAssertFalse(inspected.hasBrokenLink, "Move evidence must not imply a symlink can be replaced safely")
        XCTAssertEqual(WorktreePolicy.manualRepairPaths(snapshot), [WorktreePaths.canonical(moved.path)])
        XCTAssertFalse(inspected.hasForeignLink)
        XCTAssertFalse(inspected.folderExists)
        XCTAssertFalse(WorktreeEligibility.canPrune(snapshot, supported: true))
        XCTAssertFalse(WorktreeLinkInspector.canRepair(inspected, at: moved.path, commonDirectory: common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(inspected, at: moved.path, commonDirectory: common.path, mainPath: movedMain.path))
        XCTAssertEqual(try WorktreeEvidenceFileSystem.metadataAtPath(dotGit.path), symlink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dotGit.path), gitfile.path)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: gitfile.path), target)
        XCTAssertEqual(try Data(contentsOf: gitfile), staleLink)
        XCTAssertEqual(try ["gitdir", "commondir", "HEAD", "index"].map { try Data(contentsOf: administrative.appendingPathComponent($0)) }, metadata)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("tracked.txt")), content)
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

    func testGitPrunesRegularAdministrativeStraysWithoutChangingRegisteredCheckout() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        try Data("tracked content\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"], at: main)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "tracked fixture"], at: main)
        let linked = root.appendingPathComponent("linked")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let common = main.appendingPathComponent(".git")
        let administrativeRoot = common.appendingPathComponent("worktrees")
        let administrative = administrativeRoot.appendingPathComponent("linked")
        let metadataFiles = [common.appendingPathComponent("HEAD"), linked.appendingPathComponent(".git")]
            + ["gitdir", "commondir", "HEAD", "index"].map { administrative.appendingPathComponent($0) }
        let originalMetadata = try metadataFiles.map { try Data(contentsOf: $0) }
        let originalContent = try Data(contentsOf: linked.appendingPathComponent("tracked.txt"))
        let originalReferences = try git(["show-ref"], at: main)
        let originalHead = try git(["rev-parse", "HEAD"], at: linked)
        let originalRecords = try git(["worktree", "list", "--porcelain", "-z"], at: main)
        let originalFingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: common.path)
        let strays = [".DS_Store", "._linked"].map { administrativeRoot.appendingPathComponent($0) }
        for stray in strays {
            try Data("ordinary administrative stray".utf8).write(to: stray)
        }
        XCTAssertEqual(try git(["worktree", "list", "--porcelain", "-z"], at: main), originalRecords)
        let report = try git(["worktree", "prune", "--dry-run", "--verbose", "--expire", "now"], at: main)
        XCTAssertFalse(report.isEmpty)
        XCTAssertTrue(strays.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        _ = try git(["worktree", "prune", "--expire", "now"], at: main)
        XCTAssertTrue(strays.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try git(["worktree", "list", "--porcelain", "-z"], at: main), originalRecords)
        XCTAssertEqual(try git(["show-ref"], at: main), originalReferences)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: linked), originalHead)
        XCTAssertEqual(try metadataFiles.map { try Data(contentsOf: $0) }, originalMetadata)
        XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent("tracked.txt")), originalContent)
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: common.path), originalFingerprint)
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
        XCTAssertEqual(WorktreePolicy.manualRepairPaths(before), [])
        XCTAssertEqual(before[1].movedPath, WorktreePaths.canonical(moved.appendingPathComponent("checkouts/topic").path))
        XCTAssertFalse(WorktreeEligibility.canPrune(before, supported: true))
        let target = try WorktreeLinkInspector.captureRepairTarget(before[1], at: XCTUnwrap(before[1].movedPath), commonDirectory: moved.appendingPathComponent(".git").path, mainPath: moved.path)
        try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: moved.appendingPathComponent(".git").path)
        _ = try git(WorktreeCommand.repairLinks(style: .absolute, movedPaths: [XCTUnwrap(before[1].movedPath)]).arguments, at: moved)
        let after = try records(at: moved)
        XCTAssertFalse(after[1].hasBrokenLink)
        XCTAssertNil(after[1].movedPath)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: after, commonDirectory: moved.appendingPathComponent(".git").path, style: .absolute)
    }

    func testCopiedRepositoryLeavesExistingForeignLinkUntouched() throws {
        let root = try temporaryDirectory()
        let main = try repository(in: root)
        let linked = main.appendingPathComponent("topic")
        _ = try git(WorktreeCommand.addNew(path: linked.path, branch: "topic").arguments, at: main)
        let copy = root.appendingPathComponent("copied")
        try FileManager.default.copyItem(at: main, to: copy)
        var snapshot = try WorktreeParser.parse(git(["worktree", "list", "--porcelain", "-z"], at: copy))
        snapshot[1] = GitWorktree(path: copy.appendingPathComponent("topic").path, head: snapshot[1].head, headRefName: snapshot[1].headRefName)
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
        XCTAssertTrue(WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)[1].hasBrokenLink)
        try FileManager.default.removeItem(at: admin.appendingPathComponent("gitdir"))
        XCTAssertEqual(WorktreeLinkInspector.inspect(raw, commonDirectory: common.path, currentPath: nil)[1].linkStyle, .unknown)
        XCTAssertEqual(WorktreeLinkInspector.inspect([], commonDirectory: "/missing", currentPath: nil), [])
    }
}
