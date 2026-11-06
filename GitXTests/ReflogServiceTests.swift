@testable import GitX
import GitXCore
import XCTest

final class ReflogServiceTests: XCTestCase {
    func testReadsPinnedEventsAndUnreachableCommitDetails() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "new\n")
        try fixture.git(["commit", "--amend", "-am", "replacement"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let page = try service.page()
        XCTAssertEqual(page.entries.first?.subject, "replacement")
        XCTAssertTrue(page.entries.contains { $0.objectID == original })
        XCTAssertTrue(try service.details(objectID: original).contains("initial"))
        XCTAssertTrue(try service.details(objectID: original, compareWithHead: true).contains("tracked.txt"))
        XCTAssertEqual(try service.branches(), ["refs/heads/main"])
        XCTAssertFalse(page.hasMore)
        XCTAssertThrowsError(try service.page(reference: "--all"))
        XCTAssertThrowsError(try service.page(offset: -1))
    }

    func testRecoveryBranchesPreserveCurrentCheckoutAndRejectCollisions() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "local edit\n")
        try service.createRecoveryBranch(objectID: head, name: "recovery/test")
        XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"]), "refs/heads/main")
        XCTAssertEqual(try fixture.git(["rev-parse", "recovery/test"]), head)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "local edit\n")
        XCTAssertThrowsError(try service.createRecoveryBranch(objectID: head, name: "recovery/test"))
        XCTAssertThrowsError(try service.createRecoveryBranch(objectID: head, name: "--force"))
        XCTAssertThrowsError(try service.createRecoveryBranch(objectID: "--help", name: "safe"))
    }

    func testEveryResetModeBacksUpPreviousHeadAndChangesOnlyItsDefinedState() throws {
        for mode in ReflogResetMode.allCases {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let target = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "second\n")
            try fixture.git(["commit", "-am", "second"])
            let previous = try fixture.git(["rev-parse", "HEAD"])
            let repository = try GitXTestGitRepository(url: fixture.url)
            let service = try RepositoryReflogService(repository: repository)
            try fixture.write("tracked.txt", "staged\n")
            try fixture.git(["add", "tracked.txt"])
            try fixture.write("tracked.txt", "working\n")
            let preview = try service.preview(target: target, mode: mode)
            XCTAssertEqual(preview.affectedPaths, ["tracked.txt"])
            let backup = try service.reset(confirmed: preview, discardConfirmed: mode == .hard)
            XCTAssertEqual(try fixture.git(["rev-parse", backup]), previous)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
            XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), mode == .soft ? "staged" : "initial")
            XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), mode == .hard ? "initial\n" : "working\n")
        }
    }

    func testChangedWorkingFileOrIndexInvalidatesConsentWithoutCreatingBackup() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let preview = try service.preview(target: head, mode: .hard)
        XCTAssertThrowsError(try service.reset(confirmed: preview, discardConfirmed: false))
        try fixture.write("tracked.txt", "new local edit\n")
        XCTAssertThrowsError(try service.reset(confirmed: preview, discardConfirmed: true))
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]), "")
        let updated = try service.preview(target: head, mode: .mixed)
        try fixture.git(["add", "tracked.txt"])
        XCTAssertThrowsError(try service.reset(confirmed: updated, discardConfirmed: false))
    }

    func testHardResetPreviewIncludesIgnoredObstructionsAndInvalidatesOnTheirEdits() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.write("obstruction", "target\n")
        try fixture.git(["add", "obstruction"])
        try fixture.git(["commit", "-m", "target"])
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["rm", "obstruction"])
        try fixture.git(["commit", "-m", "remove"])
        try fixture.write(".git/info/exclude", "obstruction/\n")
        try fixture.write("obstruction/ignored.txt", "keep until confirmed\n")
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let preview = try service.preview(target: target, mode: .hard)
        XCTAssertTrue(preview.discardedPaths.contains("obstruction"))
        XCTAssertTrue(preview.discardedPaths.contains("obstruction/ignored.txt"))
        try fixture.write("obstruction/ignored.txt", "changed after preview\n")
        XCTAssertThrowsError(try service.reset(confirmed: preview, discardConfirmed: true))
        _ = try service.reset(confirmed: service.preview(target: target, mode: .hard), discardConfirmed: true)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("obstruction"), encoding: .utf8), "target\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("obstruction/ignored.txt").path))
    }

    func testActiveOperationMissingObjectsAndCancellationAreReported() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write(".git/MERGE_HEAD", head + "\n")
        XCTAssertThrowsError(try service.preview(target: head, mode: .soft))
        XCTAssertThrowsError(try service.details(objectID: String(repeating: "0", count: 40)))
        service.cancel()
        XCTAssertThrowsError(try service.page())
    }

    func testHardResetCannotUseAnIncompletePreviewForHiddenIndexEntries() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        for flag in ["assume-unchanged", "skip-worktree"] {
            try fixture.git(["update-index", "--" + flag, "tracked.txt"])
            try fixture.write("tracked.txt", "hidden local edit\n")
            XCTAssertEqual(try fixture.git(["diff", "--name-only"]), "")
            XCTAssertThrowsError(try service.preview(target: head, mode: .hard))
            try fixture.git(["update-index", "--no-" + flag, "tracked.txt"])
        }
    }

    func testMissingCommitExplainsWhyRecoveryIsUnavailable() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        XCTAssertThrowsError(try service.details(objectID: String(repeating: "0", count: 40))) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer available locally"))
        }
    }

    func testBackupCreationFailureLeavesHeadAndWorkingFilesUntouched() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "unsaved\n")
        let preview = try service.preview(target: head, mode: .hard)
        // A ref named recovery prevents creating recovery/anything.
        try fixture.git(["branch", "recovery", head])
        XCTAssertThrowsError(try service.reset(confirmed: preview, discardConfirmed: true))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "unsaved\n")
    }

    func testResetFailureRetainsAndIdentifiesTheBackup() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let preview = try service.preview(target: head, mode: .mixed)
        try fixture.write(".git/index.lock", "other writer\n")
        var retainedBackup: String?
        XCTAssertThrowsError(try service.reset(confirmed: preview, discardConfirmed: false)) { error in
            guard case let RepositoryReflogError.resetFailed(backup, _) = error else {
                return XCTFail("Expected the retained backup identity, got \(error)")
            }
            retainedBackup = backup
            XCTAssertTrue(error.localizedDescription.contains(backup))
        }
        XCTAssertEqual(try fixture.git(["rev-parse", XCTUnwrap(retainedBackup)]), head)
    }

    func testDetachedHeadResetAndBareRepositoryRestriction() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["checkout", "--detach", head])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let preview = try service.preview(target: head, mode: .soft)
        XCTAssertEqual(preview.branch, "HEAD")
        let backup = try service.reset(confirmed: preview, discardConfirmed: false)
        XCTAssertEqual(try fixture.git(["rev-parse", backup]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD")
        let bareURL = fixture.url.appendingPathComponent("bare.git")
        try fixture.git(["clone", "--bare", fixture.url.path, bareURL.path])
        let bareRepository = try GitXTestGitRepository(url: bareURL)
        let bare = try RepositoryReflogService(repository: bareRepository)
        XCTAssertThrowsError(try bare.preview(target: head, mode: .soft))
        try bare.createRecoveryBranch(objectID: head, name: "recovery/bare")
    }

    func testExpiredReflogIsEmptyAndPaginationRejectsChangedEvidence() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let first = try service.page()
        try fixture.git(["commit", "--allow-empty", "-m", "new event"])
        XCTAssertThrowsError(try service.page(offset: first.entries.count, expectedFingerprint: first.fingerprint))
        try fixture.git(["reflog", "expire", "--expire=all", "--all"])
        XCTAssertEqual(try service.page().entries, [])
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".git/logs/HEAD"))
        XCTAssertEqual(try service.page().entries, [])
        try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent(".git/logs/HEAD"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try service.page())
    }

    func testLinkedWorktreeHeadIsolationThroughRepositoryService() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let linkedURL = fixture.url.appendingPathComponent("linked")
        try fixture.git(["worktree", "add", "-b", "linked-topic", linkedURL.path])
        try fixture.git(["-C", linkedURL.path, "commit", "--allow-empty", "-m", "linked-only"])
        let linkedHead = try fixture.git(["-C", linkedURL.path, "rev-parse", "HEAD"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let linkedRepository = try GitXTestGitRepository(url: linkedURL)
        let service = try RepositoryReflogService(repository: repository)
        let linked = try RepositoryReflogService(repository: linkedRepository)
        XCTAssertFalse(try service.page().entries.contains { $0.objectID == linkedHead })
        XCTAssertEqual(try linked.page().entries.first?.objectID, linkedHead)
        XCTAssertEqual(try service.page(reference: "refs/heads/linked-topic").entries.first?.objectID, linkedHead)
    }

    func testLargeReflogUsesBoundedPagesWithoutDroppingRepeatedEvents() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["commit", "--allow-empty", "-m", "repeated event"])
        let log = fixture.url.appendingPathComponent(".git/logs/HEAD")
        let line = try XCTUnwrap(String(contentsOf: log, encoding: .utf8).split(separator: "\n").last)
        try (Array(repeating: String(line), count: 205).joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let first = try service.page()
        XCTAssertEqual(first.entries.count, 200)
        XCTAssertTrue(first.hasMore)
        let second = try service.page(offset: 200, expectedFingerprint: first.fingerprint)
        XCTAssertEqual(second.entries.count, 5)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(Set((first.entries + second.entries).map(\.objectID)).count, 1)
    }

    func testSubmoduleChangesBlockHardResetAndUnchangedSubmodulesAreNeverResetRecursively() throws {
        let fixture = try ReflogGitFixture()
        let child = try ReflogGitFixture()
        defer { fixture.remove(); child.remove() }
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.url.path, "module"])
        try fixture.git(["commit", "-am", "add submodule"])
        let original = try fixture.git(["rev-parse", "HEAD"])
        let childHead = try fixture.git(["-C", "module", "rev-parse", "HEAD"])
        try fixture.write("module/tracked.txt", "preserve submodule edit\n")
        try fixture.write("tracked.txt", "second\n")
        try fixture.git(["commit", "-am", "parent only"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let preview = try service.preview(target: original, mode: .hard)
        _ = try service.reset(confirmed: preview, discardConfirmed: true)
        XCTAssertEqual(try fixture.git(["-C", "module", "rev-parse", "HEAD"]), childHead)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("module/tracked.txt"), encoding: .utf8), "preserve submodule edit\n")
        try fixture.git(["update-index", "--cacheinfo", "160000," + original + ",module"])
        try fixture.git(["commit", "-m", "change gitlink"])
        XCTAssertThrowsError(try service.preview(target: original, mode: .hard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("submodule"))
        }
        _ = try service.reset(confirmed: service.preview(target: original, mode: .mixed), discardConfirmed: false)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("module/tracked.txt"), encoding: .utf8), "preserve submodule edit\n")
    }

    func testSymlinkObstructionIsCapturedWithoutFollowingItsDestination() throws {
        let fixture = try ReflogGitFixture()
        let external = try ReflogGitFixture()
        defer { fixture.remove(); external.remove() }
        try fixture.write("directory/target.txt", "target\n")
        try fixture.git(["add", "directory"])
        try fixture.git(["commit", "-m", "add directory"])
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["rm", "-r", "directory"])
        try fixture.git(["commit", "-m", "remove directory"])
        try FileManager.default.createSymbolicLink(at: fixture.url.appendingPathComponent("directory"), withDestinationURL: external.url)
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let preview = try service.preview(target: target, mode: .hard)
        XCTAssertEqual(preview.discardedPaths, ["directory"])
        _ = try service.reset(confirmed: preview, discardConfirmed: true)
        XCTAssertEqual(try String(contentsOf: external.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "initial\n")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("directory/target.txt"), encoding: .utf8), "target\n")
    }

    func testTrackedFileReplacedByDirectoryListsEveryObstructingChild() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("tracked.txt"))
        try fixture.write("tracked.txt/local.txt", "local content\n")
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let preview = try service.preview(target: head, mode: .hard)
        XCTAssertEqual(preview.discardedPaths, ["tracked.txt", "tracked.txt/local.txt"])
        XCTAssertEqual(preview.affectedPaths, ["tracked.txt", "tracked.txt/local.txt"])
    }

    func testNestedRepositoryObstructionAndUnreadableReflogAreNotTreatedAsEmpty() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.write("target", "target\n")
        try fixture.git(["add", "target"])
        try fixture.git(["commit", "-m", "target"])
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["rm", "target"])
        try fixture.git(["commit", "-m", "remove"])
        try fixture.write("target/.git/config", "nested repository\n")
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        XCTAssertThrowsError(try service.preview(target: target, mode: .hard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("nested repository"))
        }
        let log = fixture.url.appendingPathComponent(".git/logs/HEAD")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path) }
        XCTAssertThrowsError(try service.page())
    }

    func testChangedHeadAndReplacedGitDirectoryInvalidateResetConsent() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let original = try fixture.git(["rev-parse", "HEAD"])
        let beforeCommit = try service.preview(target: original, mode: .soft)
        try fixture.git(["commit", "--allow-empty", "-m", "new HEAD"])
        let current = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertThrowsError(try service.reset(confirmed: beforeCommit, discardConfirmed: false))
        let beforeReplacement = try service.preview(target: original, mode: .soft)
        let gitDirectory = fixture.url.appendingPathComponent(".git")
        let retained = fixture.url.appendingPathComponent("retained-git")
        try FileManager.default.moveItem(at: gitDirectory, to: retained)
        try FileManager.default.copyItem(at: retained, to: gitDirectory)
        XCTAssertThrowsError(try service.reset(confirmed: beforeReplacement, discardConfirmed: false))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), current)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]), "")
    }

    func testUnmergedIndexBlocksResetEvenWithoutAnOperationMarker() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["checkout", "-b", "conflicting"])
        try fixture.write("tracked.txt", "conflicting\n")
        try fixture.git(["commit", "-am", "conflicting"])
        try fixture.git(["checkout", "main"])
        try fixture.write("tracked.txt", "main\n")
        try fixture.git(["commit", "-am", "main"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertThrowsError(try fixture.git(["merge", "conflicting"]))
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".git/MERGE_HEAD"))
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        for mode in ReflogResetMode.allCases {
            XCTAssertThrowsError(try service.preview(target: head, mode: mode)) { error in
                XCTAssertTrue(error.localizedDescription.contains("unmerged index"))
            }
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }
}
