import AppKit
import ForgeKit
@testable import GitX
import XCTest

@MainActor
final class NativePullRequestCompletionTests: XCTestCase {
    func testCreateFailureLeavesTheSheetAndPreservesItsExactDraftIntent() throws {
        let fixture = try PullRequestAppFixture()
        let preparation = try fixture.preparation()
        let form = try XCTUnwrap(preparation.initialForms().forms.first)
        let identity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .createPullRequest(repository: preparation.repository, base: preparation.base.name, head: preparation.head.name))
        let intent = try ForgePushPullRequestIntent(form: form, draftIdentity: identity)
        var flow = GitX.RepositoryPullRequestPushFlow()
        try flow.beginNewPullRequest(branchAlreadyPushed: true, intent: intent)
        XCTAssertEqual(flow.createSheetIntent, intent)
        XCTAssertTrue(flow.isActive)
        try flow.creationFailed()
        XCTAssertNil(flow.createSheetIntent)
        XCTAssertEqual(flow.preservedIntent, intent)
        XCTAssertFalse(flow.isActive)
        try flow.beginNewPullRequest(branchAlreadyPushed: true, intent: intent)
        XCTAssertEqual(flow.createSheetIntent, intent)
        try flow.creationSucceeded(.pullRequest(fixture.repository, ForgeItemNumber(42)))
        XCTAssertFalse(flow.isActive)
        XCTAssertNil(flow.preservedIntent)
    }

    func testNativeSubmissionFailureSnapshotsKeepTheirDispositionAfterRetirement() throws {
        let fixture = try PullRequestAppFixture()
        let identity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .pullRequest(repository: fixture.repository, number: ForgeItemNumber(42)))
        let content = ForgeDraftContent(title: "Exact title", body: "Exact failed edit")
        for disposition in [GitX.RepositoryOperationFailure.Disposition.notSent, .rejected, .uncertain] {
            let submission = GitX.RepositoryEditSubmissionLifetime(identity: identity, destination: .repository(fixture.repository), content: content)
            submission.persisted(.unavailable)
            if disposition == .notSent {
                submission.supersede()
                XCTAssertTrue(submission.finish())
            } else {
                XCTAssertTrue(submission.admit())
                let error: Error = disposition == .rejected ? ForgePullRequestWorkflowError.editConflict : CancellationError()
                XCTAssertTrue(submission.finish(error: error))
            }
            let failure = try XCTUnwrap(submission.failure)
            XCTAssertEqual(failure.disposition, disposition)
            XCTAssertTrue(submission.needsRecovery)
            submission.resolveRecovery()
            XCTAssertTrue(submission.canRetire)
            XCTAssertFalse(submission.finish(error: CancellationError()))
            XCTAssertEqual(submission.failure, failure)
            XCTAssertEqual(submission.recoveryContent, content)
        }
    }

    private func waitForEditor(on window: NSWindow) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
    }

    func testSupersededEditFailureAppearsWithoutInterruptingTheNewEditor() async throws {
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        defer { local.cleanup() }
        let owner = GitX.PBGitWindowController()
        owner.repository = local.repository
        owner.showWindow(nil)
        defer { owner.close() }
        let window = try XCTUnwrap(owner.window)
        let started = expectation(description: "First edit reaches the server")
        let service = NativePullRequestMutationService(started: started)
        let drafts = GitX.NullRepositoryPullRequestDraftStore()
        let first = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(42), title: "First edit", bodyMarkdown: "First exact body", updatedAt: .distantPast)
        let next = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(43), title: "Newer editor", bodyMarkdown: "Do not interrupt these bytes", updatedAt: .distantPast)
        let controller = GitX.RepositoryPullRequestUIController(repository: local.repository, windowController: owner,
                                                                ownerIsCurrent: owner.repositoryPresentationValidation(for: local.repository),
                                                                remoteActions: GitX.RepositoryRemoteActionCoordinator(repository: local.repository, windowController: owner), service: service, drafts: drafts,
                                                                destinationOpening: { _ in XCTFail("A superseded destination must stay closed"); return false },
                                                                bindingResolving: { nil }, postPushBrowserFallback: { _ in })
        defer { controller.invalidateOwner() }
        let outcome = GitX.RepositoryPullRequestEditOutcome(snapshot: first, destination: .pullRequest(fixture.repository, first.number))
        defer { Task { await service.releaseEdit(outcome) } }
        controller.editPullRequest(accountID: fixture.accountID, snapshot: first, destination: outcome.destination)
        await waitForEditor(on: window)
        let old = try XCTUnwrap(window.attachedSheet)
        try XCTUnwrap(find("GitX.PullRequest.Submit", in: XCTUnwrap(old.contentView)) as? NSButton).performClick(nil)
        await fulfillment(of: [started], timeout: 5)
        let submitted = try XCTUnwrap(controller.mutationTask)
        await waitForNoSheet(on: window)
        controller.editPullRequest(accountID: fixture.accountID, snapshot: next, destination: .pullRequest(fixture.repository, next.number))
        await waitForEditor(on: window)
        let editor = try XCTUnwrap(window.attachedSheet)
        await service.releaseEdit(outcome)
        await submitted.value
        let row = try find("GitX.RepositoryFailure.Message", in: XCTUnwrap(window.contentView)) as? NSTextField
        XCTAssertNotNil(row, "An admitted superseded failure needs an owner-scoped nonmodal result")
        XCTAssertTrue(row?.stringValue.contains("rejected") == true)
        XCTAssertTrue(window.attachedSheet === editor)
        XCTAssertEqual(try (find("GitX.PullRequest.Body", in: XCTUnwrap(editor.contentView)) as? NSTextView)?.string, next.bodyMarkdown)
        if let row {
            XCTAssertFalse(row.isHiddenOrHasHiddenAncestor)
            try attachScreenshot(of: window, named: "Superseded failure stays outside the newer Pull Request editor")
            let details = try XCTUnwrap(try find("GitX.RepositoryFailure.Details", in: XCTUnwrap(window.contentView)) as? NSButton)
            details.performClick(nil)
            let diagnostic = try await attachedSheet(of: editor, identifier: "GitX.RepositoryFailure.Details")
            details.performClick(nil)
            XCTAssertNil(diagnostic.attachedSheet)
            try XCTUnwrap(button(titled: "OK", in: XCTUnwrap(diagnostic.contentView))).performClick(nil)
            await waitForNoSheet(on: editor)
            XCTAssertTrue(window.attachedSheet === editor)
            try XCTUnwrap(try find("GitX.RepositoryFailure.Dismiss", in: XCTUnwrap(window.contentView)) as? NSButton).performClick(nil)
            XCTAssertTrue(row.isHiddenOrHasHiddenAncestor)
        }
        let calls = await service.editCount
        XCTAssertEqual(calls, 1)
    }

    func testCheckoutReconcilesItsOriginalRepositoryAfterSupersessionOrOwnerRevocation() async throws {
        for failing in [false, true] {
            for revoked in [false, true] {
                try await exerciseHeldCheckout(failing: failing, revokeOwner: revoked)
            }
        }
    }

    func testCurrentOwnerCheckoutReportsActualGitSuccessAndFailure() async throws {
        for failing in [false, true] {
            try await exerciseHeldCheckout(failing: failing, revokeOwner: false, characterize: true)
        }
    }

    private func exerciseHeldCheckout(failing: Bool, revokeOwner: Bool, characterize: Bool = false) async throws {
        let defaults = UserDefaults.standard
        let previousWatcher = defaults.object(forKey: "PBUseRepositoryWatcher")
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        defer { defaults.set(previousWatcher, forKey: "PBUseRepositoryWatcher") }
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        let remote = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        defer { local.cleanup(); remote.cleanup() }
        try "target contents\n".write(to: remote.directory.appendingPathComponent("blocked.txt"), atomically: true, encoding: .utf8)
        try GitXTestGitFixture.run(["checkout", "-b", "feature"], in: remote.directory)
        try GitXTestGitFixture.run(["add", "blocked.txt"], in: remote.directory)
        try GitXTestGitFixture.run(["commit", "-m", "contributor change"], in: remote.directory)
        let target = try ForgeCommitID(remote.repository.outputOfTask(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))
        let original = try local.repository.outputOfTask(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try GitXTestGitFixture.run(["config", "url." + remote.directory.path + ".insteadOf", "https://github.com/contributor/gitx.git"], in: local.directory)
        let hooks = local.directory.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("reference-transaction")
        let script = #"""
        #!/bin/sh
        set -e
        [ "$1" = committed ] || exit 0
        marker_dir="$(git rev-parse --absolute-git-dir)"
        worktree_dir="$(git rev-parse --show-toplevel)"
        while read old new ref; do
          if [ "$ref" = refs/remotes/github-contributor/feature ]; then
            : > "$marker_dir/gitx-checkout-started"
            while [ ! -f "$marker_dir/gitx-checkout-release" ]; do sleep 0.01; done
            if [ -f "$marker_dir/gitx-checkout-failure" ]; then
              printf 'untracked obstruction\n' > "$worktree_dir/blocked.txt"
            fi
          fi
        done
        exit 0
        """#
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        if failing {
            try Data().write(to: local.directory.appendingPathComponent(".git/gitx-checkout-failure"))
        }
        let release = local.directory.appendingPathComponent(".git/gitx-checkout-release")
        defer { try? Data().write(to: release) }
        let owner = GitX.PBGitWindowController()
        owner.repository = local.repository
        owner.showWindow(nil)
        defer { owner.close() }
        let window = try XCTUnwrap(owner.window)
        var controller: GitX.RepositoryPullRequestUIController? = GitX.RepositoryPullRequestUIController(repository: local.repository, windowController: owner,
                                                                                                         ownerIsCurrent: owner.repositoryPresentationValidation(for: local.repository),
                                                                                                         remoteActions: GitX.RepositoryRemoteActionCoordinator(repository: local.repository, windowController: owner), service: NativePullRequestMutationService(started: nil),
                                                                                                         destinationOpening: { _ in XCTFail("A superseded completion cannot navigate"); return false }, bindingResolving: { nil }, postPushBrowserFallback: { _ in })
        defer { controller?.invalidateOwner() }
        weak let releasedController = controller
        let remotePlan = try ForgeGitRemote(name: "github-contributor", repository: fixture.fork, fetchURL: XCTUnwrap(URL(string: "https://github.com/contributor/gitx.git")))
        let plan = try ForgePullRequestCheckoutPlan(repository: fixture.repository, pullRequest: ForgeItemNumber(42), remote: remotePlan,
                                                    fetchRefspec: "+refs/heads/feature:refs/remotes/github-contributor/feature", localBranch: ForgeRefName("pr-42-contributor"), expectedHead: target, addsRemote: true)
        controller?.checkout(plan)
        let held = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: local.directory.appendingPathComponent(".git/gitx-checkout-started").path) }, object: nil)
        await fulfillment(of: [held], timeout: 10)
        guard FileManager.default.fileExists(atPath: local.directory.appendingPathComponent(".git/gitx-checkout-started").path) else {
            try Data().write(to: release)
            return
        }
        let admitted = try XCTUnwrap(controller?.mutationTask)
        var editor: NSWindow?
        if characterize {
            // Preserve current-owner result presentation as the extraction boundary.
        } else if revokeOwner {
            controller?.invalidateOwner(); owner.close(); controller = nil
            XCTAssertNil(releasedController)
        } else {
            let snapshot = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(43), title: "Current editor", bodyMarkdown: "Preserve the current editor", updatedAt: .distantPast)
            controller?.editPullRequest(accountID: fixture.accountID, snapshot: snapshot, destination: .pullRequest(fixture.repository, snapshot.number))
            await waitForEditor(on: window)
            editor = try XCTUnwrap(window.attachedSheet)
        }
        try Data().write(to: release)
        await admitted.value
        if characterize {
            await waitForEditor(on: window)
            let result = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(result.contentView)
            let checkedOut = text(in: content).contains("Pull Request Checked Out")
            XCTAssertEqual(checkedOut, !failing)
            try attachScreenshot(of: result, named: failing ? "Current owner receives actual checkout failure" : "Current owner receives actual checkout success")
            try XCTUnwrap(button(titled: "OK", in: content)).performClick(nil)
            await waitForNoSheet(on: window)
        } else {
            XCTAssertTrue(local.repository.branches.contains { $0.description == "pr-42-contributor" }, "Completion must reconcile the original refs even with its watcher disabled")
        }
        let branch = try local.repository.outputOfTask(withArguments: ["rev-parse", "pr-42-contributor"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, target.value)
        let head = try local.repository.outputOfTask(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, failing ? original : target.value)
        if !revokeOwner, !characterize {
            XCTAssertTrue(window.attachedSheet === editor)
            let row = try find("GitX.RepositoryFailure.Message", in: XCTUnwrap(window.contentView)) as? NSTextField
            XCTAssertEqual(row?.isHiddenOrHasHiddenAncestor == false, failing)
        }
        if failing {
            XCTAssertEqual(try String(contentsOf: local.directory.appendingPathComponent("blocked.txt"), encoding: .utf8), "untracked obstruction\n")
        }
    }

    func testFailureRowKeepsHiddenStatusPreferenceAndRevokesOldDetailsOnReplacement() async throws {
        let firstRepository = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        let secondRepository = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        defer { firstRepository.cleanup(); secondRepository.cleanup() }
        let previouslyVisible = GitX.ApplicationSettings.repositoryStatusBarVisible
        GitX.ApplicationSettings.repositoryStatusBarVisible = false
        defer { GitX.ApplicationSettings.repositoryStatusBarVisible = previouslyVisible }
        let owner = GitX.PBGitWindowController()
        owner.repository = firstRepository.repository
        owner.showWindow(nil)
        defer { owner.close() }
        let window = try XCTUnwrap(owner.window)
        let content = try XCTUnwrap(window.contentView)
        let first = GitX.RepositoryOperationFailure(operation: "First edit", disposition: .rejected, details: "First exact diagnostic")
        let second = GitX.RepositoryOperationFailure(operation: "Second edit", disposition: .uncertain, details: "Second exact diagnostic")
        owner.recordOperationFailure(first)
        owner.recordOperationFailure(second)
        let row = try XCTUnwrap(find("GitX.RepositoryFailure.Message", in: content) as? NSTextField)
        XCTAssertEqual(row.stringValue, first.message)
        XCTAssertFalse(row.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try XCTUnwrap(find("GitX.RepositoryStatusBar.LocalBranch", in: content)).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(GitX.ApplicationSettings.repositoryStatusBarVisible)
        try XCTUnwrap(find("GitX.RepositoryFailure.Details", in: content) as? NSButton).performClick(nil)
        _ = try await attachedSheet(of: window, identifier: "GitX.RepositoryFailure.Details")
        owner.repository = secondRepository.repository
        await waitForNoSheet(on: window)
        XCTAssertTrue(row.window == nil || row.isHiddenOrHasHiddenAncestor)
        let fresh = GitX.RepositoryOperationFailure(operation: "Fresh edit", disposition: .uncertain, details: "Fresh diagnostic")
        owner.recordOperationFailure(fresh)
        let currentContent = try XCTUnwrap(window.contentView)
        let current = try XCTUnwrap(find("GitX.RepositoryFailure.Message", in: currentContent) as? NSTextField)
        XCTAssertEqual(current.stringValue, fresh.message)
        try XCTUnwrap(find("GitX.RepositoryFailure.Dismiss", in: currentContent) as? NSButton).performClick(nil)
        XCTAssertTrue(current.isHiddenOrHasHiddenAncestor)
        owner.close()
        owner.recordOperationFailure(first)
        XCTAssertFalse(window.isVisible)
    }

    private func text(in view: NSView) -> [String] {
        if let label = view as? NSTextField {
            return [label.stringValue]
        }
        return view.subviews.flatMap { text(in: $0) }
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { [self] in find(identifier, in: $0) }.first
    }

    private func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        return view.subviews.lazy.compactMap { [self] in button(titled: title, in: $0) }.first
    }

    private func waitForNoSheet(on window: NSWindow) async {
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet == nil }, object: nil)
        await fulfillment(of: [ended], timeout: 5)
    }

    private func attachedSheet(of window: NSWindow, identifier: String) async throws -> NSWindow {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet?.accessibilityIdentifier() == identifier }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(window.attachedSheet)
    }
}

nonisolated struct NativePullRequestMutationService: GitX.RepositoryPullRequestMutationServing {
    private let storage: NativePullRequestMutationStorage
    init(started: XCTestExpectation?) {
        storage = NativePullRequestMutationStorage(started: started)
    }

    var editCount: Int {
        get async { await storage.editCount }
    }

    func capabilities(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity, operations: Set<ForgeOperation>) async throws -> [ForgeOperation: ForgeOperationCapability] {
        try await storage.capabilities(accountID: accountID, repository: repository, operations: operations)
    }

    func prepareCreation(repository: ForgeRepositoryIdentity, localBranch: ForgeRefName, localHead: ForgeCommitID) async throws -> GitX.RepositoryPullRequestCreationPreparation {
        try await storage.prepareCreation(repository: repository, localBranch: localBranch, localHead: localHead)
    }

    func createPullRequest(accountID: ForgeAccountID, form: ForgePullRequestCreationForm) async throws -> GitX.RepositoryPullRequestCreationOutcome {
        try await storage.createPullRequest(accountID: accountID, form: form)
    }

    func editPullRequest(accountID: ForgeAccountID, edit: ForgePullRequestEdit) async throws -> GitX.RepositoryPullRequestEditOutcome {
        try await storage.editPullRequest(accountID: accountID, edit: edit)
    }

    func syncFork(accountID: ForgeAccountID, plan: ForgeSyncForkPlan) async throws -> GitX.RepositorySyncForkOutcome {
        try await storage.syncFork(accountID: accountID, plan: plan)
    }

    func releaseEdit(_ outcome: GitX.RepositoryPullRequestEditOutcome) async {
        await storage.releaseEdit(outcome)
    }
}

private actor NativePullRequestMutationStorage {
    let started: XCTestExpectation?
    private(set) var editCount = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation?) {
        self.started = started
    }

    func capabilities(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity, operations: Set<ForgeOperation>) async throws -> [ForgeOperation: ForgeOperationCapability] {
        throw GitX.RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func prepareCreation(repository: ForgeRepositoryIdentity, localBranch: ForgeRefName, localHead: ForgeCommitID) async throws -> GitX.RepositoryPullRequestCreationPreparation {
        throw GitX.RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func createPullRequest(accountID: ForgeAccountID, form: ForgePullRequestCreationForm) async throws -> GitX.RepositoryPullRequestCreationOutcome {
        throw GitX.RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func editPullRequest(accountID: ForgeAccountID, edit: ForgePullRequestEdit) async throws -> GitX.RepositoryPullRequestEditOutcome {
        editCount += 1
        started?.fulfill()
        if !released {
            await withCheckedContinuation { waiter = $0 }
        }
        throw ForgePullRequestWorkflowError.editConflict
    }

    func syncFork(accountID: ForgeAccountID, plan: ForgeSyncForkPlan) async throws -> GitX.RepositorySyncForkOutcome {
        throw GitX.RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func releaseEdit(_ outcome: GitX.RepositoryPullRequestEditOutcome) {
        released = true; waiter?.resume(); waiter = nil
    }
}
