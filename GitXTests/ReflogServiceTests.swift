@testable import GitX
import GitXCore
import Synchronization
import XCTest

final class ReflogServiceTests: XCTestCase {
    func testEveryResetModePreservesDetachedAndLinkedWorktreeIdentities() throws {
        for linked in [false, true] {
            for mode in ReflogResetMode.allCases {
                let fixture = try ReflogGitFixture()
                defer { fixture.remove() }
                let target = try fixture.git(["rev-parse", "HEAD"])
                let checkout = linked ? fixture.url.appendingPathComponent("linked") : fixture.url
                if linked {
                    try fixture.git(["worktree", "add", "-b", "linked-topic", checkout.path])
                } else {
                    try fixture.git(["checkout", "--detach", target])
                }
                let prefix = ["-C", checkout.path]
                try fixture.git(prefix + ["commit", "--allow-empty", "-m", "checkout-only"])
                let previous = try fixture.git(prefix + ["rev-parse", "HEAD"])
                let repository = try GitXTestGitRepository(url: checkout)
                let service = try RepositoryReflogService(repository: repository)
                let preview = try service.preview(target: target, mode: mode)
                XCTAssertEqual(preview.branch, linked ? "linked-topic" : "HEAD")
                let backup = try service.reset(confirmed: preview, discardConfirmed: mode == .hard)
                XCTAssertEqual(try fixture.git(prefix + ["rev-parse", "HEAD"]), target)
                XCTAssertEqual(try fixture.git(prefix + ["rev-parse", backup]), previous)
                XCTAssertEqual(try fixture.git(prefix + ["rev-parse", "--abbrev-ref", "HEAD"]), preview.branch)
                XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/main"]), target)
            }
        }
    }

    @MainActor
    func testResetReportsTheActualInterveningHeadWithoutAutomaticRollback() async throws {
        for mode in ReflogResetMode.allCases {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let target = try fixture.git(["rev-parse", "HEAD"])
            try fixture.git(["commit", "--allow-empty", "-m", "validated"])
            let previous = try fixture.git(["rev-parse", "HEAD"])
            let repository = try GitXTestGitRepository(url: fixture.url)
            let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
            defer { try? gate.open() }
            let service = try RepositoryReflogService(repository: repository, context: gate.context)
            let preview = try service.preview(target: target, mode: mode)
            let reset = Task.detached { try service.reset(confirmed: preview, discardConfirmed: mode == .hard) }
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: gate.started.path) }, object: nil)
            await fulfillment(of: [started], timeout: 10)
            try fixture.git(["commit", "--allow-empty", "-m", "external writer"])
            let intervening = try fixture.git(["rev-parse", "HEAD"])
            try gate.open()
            do { _ = try await reset.value; XCTFail("The changed predecessor must not be reported as a safe reset") }
            catch {
                guard case let RepositoryReflogError.resetFailed(backup, reason) = error else { return XCTFail("Expected a retained-backup failure: \(error)") }
                XCTAssertTrue(reason.contains(previous))
                XCTAssertTrue(reason.contains(intervening))
                XCTAssertEqual(try fixture.git(["rev-parse", backup]), previous)
            }
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
            XCTAssertEqual(try fixture.git(["rev-parse", "ORIG_HEAD"]), intervening)
        }
    }

    func testPreviewReadsContentsOnlyForHardResetOverwrites() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: 8 * 1024 * 1024).write(to: fixture.url.appendingPathComponent("unchanged.bin"))
        try fixture.git(["add", "unchanged.bin"])
        try fixture.git(["commit", "-m", "large unchanged file"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let changed = "Unsaved overwrite evidence\n"
        try fixture.write("tracked.txt", changed)
        let repository = try GitXTestGitRepository(url: fixture.url)
        for mode in ReflogResetMode.allCases {
            let reads = Mutex<[String: Int]>([:])
            let service = try RepositoryReflogService(repository: repository, contentRead: { path, count in reads.withLock { $0[path, default: 0] += count } })
            _ = try service.preview(target: head, mode: mode)
            XCTAssertEqual(reads.withLock { $0 }, mode == .hard ? ["tracked.txt": changed.utf8.count] : [:])
        }
    }

    @MainActor
    func testResetReportsASameCommitCheckoutRaceAndRetainsTheValidatedBackup() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
        defer { try? gate.open() }
        let service = try RepositoryReflogService(repository: repository, context: gate.context)
        let preview = try service.preview(target: previous, mode: .soft)
        let reset = Task.detached { try service.reset(confirmed: preview, discardConfirmed: false) }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: gate.started.path) }, object: nil)
        await fulfillment(of: [started], timeout: 10)
        try fixture.git(["checkout", "-b", "intervening"])
        try gate.open()
        do { _ = try await reset.value; XCTFail("A changed checkout must not certify the original preview") }
        catch {
            guard case let RepositoryReflogError.resetFailed(backup, reason) = error else { return XCTFail("Expected the retained-backup diagnostic") }
            XCTAssertTrue(reason.contains("main")); XCTAssertTrue(reason.contains("intervening"))
            XCTAssertEqual(try fixture.git(["rev-parse", backup]), previous)
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "--abbrev-ref", "HEAD"]), "intervening")
    }

    func testResetOutcomePolicyHandlesMissingContradictoryAndChangedEvidence() {
        let expected = String(repeating: "a", count: 40)
        let other = String(repeating: "b", count: 40)
        XCTAssertNil(RepositoryResetOutcomePolicy.problem(expected: expected, original: expected, predecessor: expected))
        XCTAssertNil(RepositoryResetOutcomePolicy.problem(expected: expected, original: expected, predecessor: nil))
        XCTAssertNil(RepositoryResetOutcomePolicy.problem(expected: expected, original: nil, predecessor: expected))
        XCTAssertTrue(RepositoryResetOutcomePolicy.problem(expected: expected, original: nil, predecessor: "invalid")?.contains("unverified") == true)
        let mismatch = RepositoryResetOutcomePolicy.problem(expected: expected, original: other, predecessor: expected)
        XCTAssertTrue(mismatch?.contains(expected) == true)
        XCTAssertTrue(mismatch?.contains(other) == true)
        XCTAssertTrue(RepositoryResetOutcomePolicy.problem(expected: expected, original: expected, predecessor: other)?.contains("backup preserves the validated commit only") == true)
        XCTAssertNotNil(RepositoryResetOutcomePolicy.problem(expected: expected, original: other, predecessor: nil))
    }

    func testResetWithoutReflogsUsesTheActualOrigHeadEvidence() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["commit", "--allow-empty", "-m", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["config", "core.logAllRefUpdates", "false"])
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".git/logs"))
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        let backup = try service.reset(confirmed: service.preview(target: target, mode: .soft), discardConfirmed: false)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
        XCTAssertEqual(try fixture.git(["rev-parse", "ORIG_HEAD"]), previous)
        XCTAssertEqual(try fixture.git(["rev-parse", backup]), previous)
    }

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
        XCTAssertFalse(preview.affectedPaths.contains("module"), "Internal submodule edits are preserved")
        XCTAssertFalse(preview.discardedPaths.contains("module"), "Do not claim preserved submodule edits will be discarded")
        _ = try service.reset(confirmed: preview, discardConfirmed: true)
        XCTAssertEqual(try fixture.git(["-C", "module", "rev-parse", "HEAD"]), childHead)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("module/tracked.txt"), encoding: .utf8), "preserve submodule edit\n")
        try fixture.git(["config", "diff.ignoreSubmodules", "all"])
        try fixture.git(["update-index", "--cacheinfo", "160000," + original + ",module"])
        let stagedGitlink = try service.preview(target: original, mode: .hard)
        XCTAssertTrue(stagedGitlink.affectedPaths.contains("module"), "Git configuration must not hide staged gitlink changes")
        XCTAssertTrue(stagedGitlink.discardedPaths.contains("module"))
        _ = try service.reset(confirmed: stagedGitlink, discardConfirmed: true)
        XCTAssertTrue(try fixture.git(["ls-files", "--stage", "module"]).contains(childHead))
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

    func testStagedGitlinkReplacingTrackedFileBlocksHardResetButMixedPreservesNestedContent() throws {
        let fixture = try ReflogGitFixture()
        let nested = try ReflogGitFixture()
        defer { fixture.remove(); nested.remove() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        try fixture.stageNestedRepositoryOverTrackedFile(nested)
        let repository = try GitXTestGitRepository(url: fixture.url)
        let service = try RepositoryReflogService(repository: repository)
        XCTAssertThrowsError(try service.preview(target: head, mode: .hard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("submodule"))
        }
        XCTAssertTrue(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]).isEmpty)
        _ = try service.preview(target: head, mode: .soft)
        let mixed = try service.preview(target: head, mode: .mixed)
        _ = try service.reset(confirmed: mixed, discardConfirmed: false)
        XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), "initial")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt/untracked.txt"), encoding: .utf8), "preserve nested local content\n")
    }

    func testSubmoduleDirectoryCreationIsPreviewedAndObstructionsInvalidateConfirmation() throws {
        for modulePath in ["module", "folder/module"] {
            let fixture = try ReflogGitFixture()
            let child = try ReflogGitFixture()
            defer { fixture.remove(); child.remove() }
            try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.url.path, modulePath])
            try fixture.git(["commit", "-am", "add submodule"])
            let head = try fixture.git(["rev-parse", "HEAD"])
            let obstructionPath = String(modulePath.split(separator: "/")[0])
            let obstruction = fixture.url.appendingPathComponent(obstructionPath)
            try FileManager.default.removeItem(at: obstruction)
            let repository = try GitXTestGitRepository(url: fixture.url)
            let reads = Mutex<[String: Int]>([:])
            let service = try RepositoryReflogService(repository: repository, contentRead: { path, count in reads.withLock { $0[path, default: 0] += count } })
            let missing = try service.preview(target: head, mode: .hard)
            XCTAssertTrue(missing.affectedPaths.contains(modulePath))
            XCTAssertEqual(missing.discardedPaths, [modulePath], "Reset reverses this local directory deletion")
            try fixture.write(obstructionPath, "preserve local obstruction\n")
            XCTAssertThrowsError(try service.reset(confirmed: missing, discardConfirmed: true))
            XCTAssertEqual(try? String(contentsOf: obstruction, encoding: .utf8), "preserve local obstruction\n")
            XCTAssertTrue(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]).isEmpty)
            try FileManager.default.removeItem(at: obstruction)
            try fixture.write(obstructionPath, "explicitly discard this obstruction\n")
            reads.withLock { $0.removeAll() }
            let filePreview = try service.preview(target: head, mode: .hard)
            XCTAssertEqual(reads.withLock { $0 }, [obstructionPath: "explicitly discard this obstruction\n".utf8.count])
            XCTAssertTrue(filePreview.affectedPaths.contains(modulePath))
            XCTAssertTrue(filePreview.discardedPaths.contains(obstructionPath))
            XCTAssertThrowsError(try service.reset(confirmed: filePreview, discardConfirmed: false))
            _ = try service.reset(confirmed: filePreview, discardConfirmed: true)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.url.appendingPathComponent(modulePath).path).isEmpty)
            try FileManager.default.removeItem(at: obstruction)
            try FileManager.default.createSymbolicLink(at: obstruction, withDestinationURL: child.url)
            let symlinkPreview = try service.preview(target: head, mode: .hard)
            XCTAssertTrue(symlinkPreview.affectedPaths.contains(modulePath))
            XCTAssertTrue(symlinkPreview.discardedPaths.contains(obstructionPath))
            _ = try service.reset(confirmed: symlinkPreview, discardConfirmed: true)
            XCTAssertEqual(try String(contentsOf: child.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "initial\n")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.url.appendingPathComponent(modulePath).path).isEmpty)
            try FileManager.default.removeItem(at: obstruction)
            let refreshed = try service.preview(target: head, mode: .hard)
            XCTAssertTrue(refreshed.affectedPaths.contains(modulePath))
            _ = try service.reset(confirmed: refreshed, discardConfirmed: true)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.url.appendingPathComponent(modulePath).path).isEmpty)
        }
    }

    func testTrackedFileReplacedByDirectoryListsEveryObstructingChild() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("tracked.txt"))
        try fixture.write("tracked.txt/local.txt", "local content\n")
        let repository = try GitXTestGitRepository(url: fixture.url)
        let reads = Mutex<[String: Int]>([:])
        let service = try RepositoryReflogService(repository: repository, contentRead: { path, count in reads.withLock { $0[path, default: 0] += count } })
        let preview = try service.preview(target: head, mode: .hard)
        XCTAssertEqual(reads.withLock { $0 }, ["tracked.txt/local.txt": "local content\n".utf8.count])
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
