import AppKit
import ForgeKit
@testable import GitX
import XCTest

@MainActor
final class NativePullRequestCompletionTests: XCTestCase {
    private func waitForEditor(on window: NSWindow) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
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

private actor NativePullRequestMutationService: GitX.RepositoryPullRequestMutationServing {
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
