import ForgeKit
import Foundation
import XCTest

@MainActor
final class RepositoryPullRequestLocalReviewServiceProductionTests: XCTestCase {
    func testCheckedOutBranchSafetyUsesSymbolicBranchIdentityInsteadOfSharedOID() async throws {
        let branch = try ForgeRefName("feature/github-mutations")
        let head = try ForgeCommitID("abcdef12")

        let checkedOutBranchRunner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]:
                .output("refs/heads/feature/github-mutations\n"),
        ])
        let checkedOutBranchService = RepositoryPullRequestLocalReviewService(
            runner: checkedOutBranchRunner,
            workingDirectory: nil
        )
        let checkedOutBranchConflict = try await checkedOutBranchService.hasCheckedOutSafetyConflict(
            branch: branch,
            expectedHead: head
        )
        XCTAssertTrue(checkedOutBranchConflict)

        let differentBranchRunner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]: .output("refs/heads/release\n"),
        ])
        let differentBranchService = RepositoryPullRequestLocalReviewService(
            runner: differentBranchRunner,
            workingDirectory: nil
        )
        let differentBranchConflict = try await differentBranchService.hasCheckedOutSafetyConflict(
            branch: branch,
            expectedHead: head
        )
        XCTAssertFalse(differentBranchConflict)

        XCTAssertEqual(checkedOutBranchRunner.commands.count, 1)
        XCTAssertEqual(differentBranchRunner.commands.count, 1)
    }

    func testCheckedOutBranchSafetyFallsBackToOIDForDetachedHead() async throws {
        let branch = try ForgeRefName("feature/github-mutations")
        let head = try ForgeCommitID("abcdef12")
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]: .output("HEAD\n"),
            ["rev-parse", "--verify", "HEAD"]: .output("abcdef12\n"),
        ])
        let service = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil
        )

        let hasConflict = try await service.hasCheckedOutSafetyConflict(
            branch: branch,
            expectedHead: head
        )
        XCTAssertTrue(hasConflict)
        XCTAssertEqual(runner.commands, [
            ["rev-parse", "--symbolic-full-name", "HEAD"],
            ["rev-parse", "--verify", "HEAD"],
        ])
    }

    func testCheckedOutBranchSafetyAllowsDetachedHeadAtDifferentValidOID() async throws {
        let branch = try ForgeRefName("feature/github-mutations")
        let head = try ForgeCommitID("abcdef12")
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]: .output("HEAD\n"),
            ["rev-parse", "--verify", "HEAD"]: .output("fedcba98\n"),
        ])
        let service = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil
        )

        let hasConflict = try await service.hasCheckedOutSafetyConflict(
            branch: branch,
            expectedHead: head
        )

        XCTAssertFalse(hasConflict)
        XCTAssertEqual(runner.commands, [
            ["rev-parse", "--symbolic-full-name", "HEAD"],
            ["rev-parse", "--verify", "HEAD"],
        ])
    }

    func testCheckedOutBranchSafetyRejectsUnexpectedSymbolicReferenceWithoutOIDFallback() async {
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]: .output("refs/remotes/origin/main\n"),
            ["rev-parse", "--verify", "HEAD"]: .output("abcdef12\n"),
        ])
        let service = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil
        )

        await assertServiceError(.unsafeLocalEdit) {
            _ = try await service.hasCheckedOutSafetyConflict(
                branch: ForgeRefName("feature/github-mutations"),
                expectedHead: ForgeCommitID("abcdef12")
            )
        }

        XCTAssertEqual(runner.commands, [["rev-parse", "--symbolic-full-name", "HEAD"]])
    }

    func testCheckedOutBranchSafetyFailsClosedWhenSymbolicHeadCannotBeRead() async throws {
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--symbolic-full-name", "HEAD"]: .failure,
        ])
        let service = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil
        )

        do {
            _ = try await service.hasCheckedOutSafetyConflict(
                branch: ForgeRefName("feature/github-mutations"),
                expectedHead: ForgeCommitID("abcdef12")
            )
            XCTFail("Expected an unreadable symbolic HEAD to fail closed")
        } catch {
            XCTAssertEqual(runner.commands, [["rev-parse", "--symbolic-full-name", "HEAD"]])
        }
    }

    func testCheckedOutHeadRejectsMalformedRevisionOutput() async throws {
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["rev-parse", "--verify", "HEAD"]: .output("not-an-object-id\n"),
        ])
        let service = RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil
        )

        do {
            _ = try await service.checkedOutHead()
            XCTFail("Expected malformed HEAD output to fail closed")
        } catch {
            XCTAssertEqual(runner.commands, [["rev-parse", "--verify", "HEAD"]])
        }
    }

    func testFetchBaseUsesExactBoundPrimaryRemoteRefspecAndVerifiesFetchedOID() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("mirror\norigin\n"),
            ["remote", "get-url", "mirror"]: .output(fixture.primaryRemoteURL),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.fetchArguments(remote: "origin", branch: fixture.primaryBase): .output(""),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output("\(fixture.baseCommit.value)\n"),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.fetchBase(fixture.primaryBase)

        XCTAssertEqual(runner.commands, [
            ["remote"],
            ["remote", "get-url", "mirror"],
            ["remote", "get-url", "origin"],
            fixture.fetchArguments(remote: "origin", branch: fixture.primaryBase),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase),
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testFetchBaseAcceptsAdvancedDescendantAfterPullRequestMerge() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.fetchArguments(remote: "origin", branch: fixture.primaryBase): .output(""),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output("\(fixture.advancedCommit.value)\n"),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.advancedCommit): .output(""),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.fetchPostMergeBase(fixture.primaryBase)

        XCTAssertEqual(
            runner.commands.last,
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.advancedCommit)
        )
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testFetchPostMergeBaseRejectsRewrittenTip() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.fetchArguments(remote: "origin", branch: fixture.primaryBase): .output(""),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.staleCommit.value),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.staleCommit): .failure,
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.fetchPostMergeBase(fixture.primaryBase)
        }

        XCTAssertEqual(
            runner.commands.last,
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.staleCommit)
        )
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testFetchBaseDiscoversTheOneExactForkRemote() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\ncontributor\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            ["remote", "get-url", "contributor"]: .output(fixture.forkRemoteURL),
            fixture.fetchArguments(remote: "contributor", branch: fixture.forkBase): .output(""),
            fixture.remoteTrackingOIDArguments(remote: "contributor", branch: fixture.forkBase):
                .output(fixture.baseCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.fetchBase(fixture.forkBase)

        XCTAssertEqual(runner.commands.suffix(2), [
            fixture.fetchArguments(remote: "contributor", branch: fixture.forkBase),
            fixture.remoteTrackingOIDArguments(remote: "contributor", branch: fixture.forkBase),
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testFetchBaseRejectsPrimaryRepositoryWhenOnlyAnUnboundRemoteMatches() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("mirror\n"),
            ["remote", "get-url", "mirror"]: .output(fixture.primaryRemoteURL),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.unavailable) {
            try await service.fetchBase(fixture.primaryBase)
        }

        XCTAssertEqual(runner.commands, [
            ["remote"],
            ["remote", "get-url", "mirror"],
        ])
    }

    func testFetchBaseRejectsAmbiguousExactForkRemotesBeforeFetching() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("contributor\nmirror\n"),
            ["remote", "get-url", "contributor"]: .output(fixture.forkRemoteURL),
            ["remote", "get-url", "mirror"]: .output(fixture.forkRemoteURL),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.unavailable) {
            try await service.fetchBase(fixture.forkBase)
        }

        XCTAssertEqual(runner.commands, [
            ["remote"],
            ["remote", "get-url", "contributor"],
            ["remote", "get-url", "mirror"],
        ])
    }

    func testFetchBaseRejectsMissingRemoteBeforeFetching() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output(""),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.unavailable) {
            try await service.fetchBase(fixture.forkBase)
        }

        XCTAssertEqual(runner.commands, [["remote"]])
    }

    func testFetchBaseRejectsMismatchedRemoteBeforeFetching() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("elsewhere\n"),
            ["remote", "get-url", "elsewhere"]: .output(fixture.unrelatedRemoteURL),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.unavailable) {
            try await service.fetchBase(fixture.forkBase)
        }

        XCTAssertEqual(runner.commands, [
            ["remote"],
            ["remote", "get-url", "elsewhere"],
        ])
    }

    func testFetchBaseRejectsStaleFetchedOID() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.fetchArguments(remote: "origin", branch: fixture.primaryBase): .output(""),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.staleCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.fetchBase(fixture.primaryBase)
        }

        XCTAssertEqual(
            runner.commands.last,
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase)
        )
    }

    func testCheckOutBaseRequiresBindingAndExactPrimaryRepositoryBeforeGitCommands() async throws {
        let fixture = try LocalReviewGitFixture()
        let unboundRunner = ScriptedLocalReviewGitRunner(responses: [:])
        let unboundService = RepositoryPullRequestLocalReviewService(
            runner: unboundRunner,
            workingDirectory: nil
        )

        await assertServiceError(.invalidWorkspace) {
            try await unboundService.checkOutBase(fixture.primaryBase)
        }
        XCTAssertTrue(unboundRunner.commands.isEmpty)

        let mismatchedRunner = ScriptedLocalReviewGitRunner(responses: [:])
        let boundService = try RepositoryPullRequestLocalReviewService(
            runner: mismatchedRunner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.invalidWorkspace) {
            try await boundService.checkOutBase(fixture.forkBase)
        }
        XCTAssertTrue(mismatchedRunner.commands.isEmpty)
    }

    func testCheckOutBaseRequiresExactRemoteTrackingOIDBeforeInspectingWorktree() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.staleCommit.value),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.staleCommit): .failure,
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.checkOutBase(fixture.primaryBase)
        }

        XCTAssertEqual(
            runner.commands.last,
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.staleCommit)
        )
        XCTAssertFalse(runner.commands.contains(fixture.statusArguments))
    }

    func testCheckOutBaseChecksOutExistingExactLocalBase() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = fixture.checkoutRunner(localOID: .output(fixture.baseCommit.value), status: "")
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.checkOutBase(fixture.primaryBase)

        XCTAssertEqual(runner.commands, fixture.checkoutPrefix + [
            fixture.localBranchOIDArguments(branch: fixture.primaryBase),
            ["checkout", fixture.primaryBase.name.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseFastForwardsExactPreMergeBaseToAdvancedDescendant() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.advancedCommit.value),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.advancedCommit): .output(""),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .output(fixture.baseCommit.value),
            ["checkout", fixture.primaryBase.name.value]: .output(""),
            ["merge", "--ff-only", fixture.advancedCommit.value]: .output(""),
            fixture.headOIDArguments: .output(fixture.advancedCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.checkOutBase(fixture.primaryBase)

        XCTAssertEqual(runner.commands.suffix(3), [
            ["checkout", fixture.primaryBase.name.value],
            ["merge", "--ff-only", fixture.advancedCommit.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseFastForwardsIntermediateLocalDescendantToCapturedRemoteCommit() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.advancedCommit.value),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.advancedCommit):
                .output(""),
            fixture.ancestorArguments(ancestor: fixture.intermediateCommit, descendant: fixture.advancedCommit):
                .output(""),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase):
                .output(fixture.intermediateCommit.value),
            ["checkout", fixture.primaryBase.name.value]: .output(""),
            ["merge", "--ff-only", fixture.advancedCommit.value]: .output(""),
            fixture.headOIDArguments: .output(fixture.advancedCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        do {
            try await service.checkOutBase(fixture.primaryBase)
        } catch {
            return XCTFail("Expected safe intermediate base checkout, got \(error); commands: \(runner.commands)")
        }

        XCTAssertEqual(runner.commands.suffix(3), [
            ["checkout", fixture.primaryBase.name.value],
            ["merge", "--ff-only", fixture.advancedCommit.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseRejectsBranchMoveBetweenValidationAndCheckout() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.baseCommit.value),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .output(fixture.baseCommit.value),
            ["checkout", fixture.primaryBase.name.value]: .output(""),
            fixture.headOIDArguments: .output(fixture.aheadCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.checkOutBase(fixture.primaryBase)
        }

        XCTAssertEqual(runner.commands.suffix(2), [
            ["checkout", fixture.primaryBase.name.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseFastForwardsOlderLocalBaseToValidatedRemoteCommit() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.baseCommit.value),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .output(fixture.staleCommit.value),
            fixture.ancestorArguments(ancestor: fixture.staleCommit, descendant: fixture.baseCommit): .output(""),
            ["checkout", fixture.primaryBase.name.value]: .output(""),
            ["merge", "--ff-only", fixture.baseCommit.value]: .output(""),
            fixture.headOIDArguments: .output(fixture.baseCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.checkOutBase(fixture.primaryBase)

        XCTAssertEqual(runner.commands.suffix(3), [
            ["checkout", fixture.primaryBase.name.value],
            ["merge", "--ff-only", fixture.baseCommit.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseRejectsDivergentExistingLocalBase() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.baseCommit.value),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .output(fixture.staleCommit.value),
            fixture.ancestorArguments(ancestor: fixture.staleCommit, descendant: fixture.baseCommit): .failure,
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.checkOutBase(fixture.primaryBase)
        }

        XCTAssertEqual(runner.commands, fixture.checkoutPrefix + [
            fixture.localBranchOIDArguments(branch: fixture.primaryBase),
            fixture.ancestorArguments(ancestor: fixture.staleCommit, descendant: fixture.baseCommit),
        ])
    }

    func testCheckOutBaseRejectsLocalBaseAheadOfCapturedRemoteCommit() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.advancedCommit.value),
            fixture.ancestorArguments(ancestor: fixture.baseCommit, descendant: fixture.advancedCommit):
                .output(""),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .output(fixture.aheadCommit.value),
            fixture.ancestorArguments(ancestor: fixture.aheadCommit, descendant: fixture.advancedCommit): .failure,
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.stalePullRequest) {
            try await service.checkOutBase(fixture.primaryBase)
        }

        XCTAssertEqual(
            runner.commands.last,
            fixture.ancestorArguments(ancestor: fixture.aheadCommit, descendant: fixture.advancedCommit)
        )
        XCTAssertFalse(runner.commands.contains(["checkout", fixture.primaryBase.name.value]))
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseCreatesMissingLocalTrackingBranch() async throws {
        let fixture = try LocalReviewGitFixture()
        let remoteTrackingRef = fixture.remoteTrackingRef(remote: "origin", branch: fixture.primaryBase)
        let runner = ScriptedLocalReviewGitRunner(responses: [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(fixture.primaryRemoteURL),
            fixture.remoteTrackingOIDArguments(remote: "origin", branch: fixture.primaryBase):
                .output(fixture.baseCommit.value),
            fixture.statusArguments: .output(""),
            fixture.localBranchOIDArguments(branch: fixture.primaryBase): .failure,
            ["branch", fixture.primaryBase.name.value, fixture.baseCommit.value]: .output(""),
            ["branch", "--set-upstream-to", remoteTrackingRef, fixture.primaryBase.name.value]: .output(""),
            ["checkout", fixture.primaryBase.name.value]: .output(""),
            fixture.headOIDArguments: .output(fixture.baseCommit.value),
        ])
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        try await service.checkOutBase(fixture.primaryBase)

        XCTAssertEqual(runner.commands, fixture.checkoutPrefix + [
            fixture.localBranchOIDArguments(branch: fixture.primaryBase),
            ["branch", fixture.primaryBase.name.value, fixture.baseCommit.value],
            ["branch", "--set-upstream-to", remoteTrackingRef, fixture.primaryBase.name.value],
            ["checkout", fixture.primaryBase.name.value],
            fixture.headOIDArguments,
        ])
        XCTAssertTrue(runner.unusedArguments.isEmpty)
    }

    func testCheckOutBaseRejectsDirtyWorktreeBeforeInspectingOrCreatingLocalBranch() async throws {
        let fixture = try LocalReviewGitFixture()
        let runner = fixture.checkoutRunner(localOID: nil, status: "1 .M N... tracked.txt\0")
        let service = try RepositoryPullRequestLocalReviewService(
            runner: runner,
            workingDirectory: nil,
            binding: fixture.binding()
        )

        await assertServiceError(.unsafeLocalEdit) {
            try await service.checkOutBase(fixture.primaryBase)
        }

        XCTAssertEqual(runner.commands, fixture.checkoutPrefix)
        XCTAssertFalse(runner.commands.contains(fixture.localBranchOIDArguments(branch: fixture.primaryBase)))
    }

    private func assertServiceError(
        _ expected: RepositoryPullRequestReviewServiceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RepositoryPullRequestReviewServiceError, expected, file: file, line: line)
        }
    }
}

private struct LocalReviewGitFixture {
    let primary: ForgeRepositoryIdentity
    let fork: ForgeRepositoryIdentity
    let unrelated: ForgeRepositoryIdentity
    let baseCommit = try! ForgeCommitID(String(repeating: "a", count: 40))
    let staleCommit = try! ForgeCommitID(String(repeating: "b", count: 40))
    let intermediateCommit = try! ForgeCommitID(String(repeating: "d", count: 40))
    let aheadCommit = try! ForgeCommitID(String(repeating: "e", count: 40))
    let advancedCommit = try! ForgeCommitID(String(repeating: "c", count: 40))
    let primaryBase: ForgeBranchReference
    let forkBase: ForgeBranchReference

    let primaryRemoteURL = "git@github.com:hbmartin/gitx.git"
    let forkRemoteURL = "https://github.com/contributor/gitx.git"
    let unrelatedRemoteURL = "ssh://git@github.com/unrelated/gitx.git"

    init() throws {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        primary = try ForgeRepositoryIdentity(forge: forge, owner: "hbmartin", name: "gitx")
        fork = try ForgeRepositoryIdentity(forge: forge, owner: "contributor", name: "gitx")
        unrelated = try ForgeRepositoryIdentity(forge: forge, owner: "unrelated", name: "gitx")
        primaryBase = try ForgeBranchReference(
            repository: primary,
            name: ForgeRefName("main"),
            commit: baseCommit
        )
        forkBase = try ForgeBranchReference(
            repository: fork,
            name: ForgeRefName("feature/base"),
            commit: baseCommit
        )
    }

    var statusArguments: [String] {
        ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]
    }

    var checkoutPrefix: [[String]] {
        [
            ["remote"],
            ["remote", "get-url", "origin"],
            remoteTrackingOIDArguments(remote: "origin", branch: primaryBase),
            statusArguments,
        ]
    }

    var headOIDArguments: [String] {
        ["rev-parse", "--verify", "HEAD"]
    }

    func binding() throws -> ForgeRepositoryBinding {
        try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: primary)
    }

    func remoteTrackingRef(remote: String, branch: ForgeBranchReference) -> String {
        "refs/remotes/\(remote)/\(branch.name.value)"
    }

    func fetchArguments(remote: String, branch: ForgeBranchReference) -> [String] {
        [
            "fetch", "--no-tags", remote,
            "+refs/heads/\(branch.name.value):\(remoteTrackingRef(remote: remote, branch: branch))",
        ]
    }

    func remoteTrackingOIDArguments(remote: String, branch: ForgeBranchReference) -> [String] {
        ["rev-parse", "--verify", remoteTrackingRef(remote: remote, branch: branch)]
    }

    func localBranchOIDArguments(branch: ForgeBranchReference) -> [String] {
        ["rev-parse", "--verify", "refs/heads/\(branch.name.value)"]
    }

    func ancestorArguments(ancestor: ForgeCommitID, descendant: ForgeCommitID) -> [String] {
        ["merge-base", "--is-ancestor", ancestor.value, descendant.value]
    }

    func checkoutRunner(
        localOID: ScriptedLocalReviewGitRunner.Response?,
        status: String
    ) -> ScriptedLocalReviewGitRunner {
        var responses: [[String]: ScriptedLocalReviewGitRunner.Response] = [
            ["remote"]: .output("origin\n"),
            ["remote", "get-url", "origin"]: .output(primaryRemoteURL),
            remoteTrackingOIDArguments(remote: "origin", branch: primaryBase): .output(baseCommit.value),
            statusArguments: .output(status),
        ]
        if let localOID {
            responses[localBranchOIDArguments(branch: primaryBase)] = localOID
            switch localOID {
            case .output:
                responses[["checkout", primaryBase.name.value]] = .output("")
                responses[headOIDArguments] = .output(baseCommit.value)
            case .failure:
                let remoteTrackingRef = remoteTrackingRef(remote: "origin", branch: primaryBase)
                responses[["branch", primaryBase.name.value, baseCommit.value]] = .output("")
                responses[["branch", "--set-upstream-to", remoteTrackingRef, primaryBase.name.value]] = .output("")
                responses[["checkout", primaryBase.name.value]] = .output("")
                responses[headOIDArguments] = .output(baseCommit.value)
            }
        }
        return ScriptedLocalReviewGitRunner(responses: responses)
    }
}

// swift6-safety-justification: `lock` serializes the command log and immutable scripted responses.
private final class ScriptedLocalReviewGitRunner: RepositoryPullRequestGitCommandRunning, @unchecked Sendable {
    enum Response: Sendable {
        case output(String)
        case failure
    }

    private let lock = NSLock()
    private var responses: [[String]: Response]
    private var recordedCommands: [[String]] = []

    init(responses: [[String]: Response]) {
        self.responses = responses
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var unusedArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return Array(responses.keys)
    }

    func run(_ arguments: [String]) throws -> String {
        lock.lock()
        recordedCommands.append(arguments)
        let response = responses.removeValue(forKey: arguments)
        lock.unlock()
        guard let response else {
            throw LocalReviewGitRunnerError.unexpectedCommand(arguments)
        }
        switch response {
        case let .output(output):
            return output
        case .failure:
            throw LocalReviewGitRunnerError.scriptedFailure(arguments)
        }
    }
}

private enum LocalReviewGitRunnerError: Error, Sendable {
    case unexpectedCommand([String])
    case scriptedFailure([String])
}
