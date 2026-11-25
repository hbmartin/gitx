import AppKit
import ForgeKit
@testable import GitX
import Synchronization
import XCTest

@MainActor
final class NativeTerminationIntegrationTests: XCTestCase {
    func testShippedApplicationDelegateExportsTheNativeQuitSelector() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? ApplicationController)
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("applicationShouldTerminate:")), "AppKit must reach the Swift termination coordinator through its optional Objective-C delegate method")
        let quit = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        XCTAssertTrue(quit.target as AnyObject? === delegate, "Menu Quit must ask for consent before AppKit waits for attached sheets")
        XCTAssertTrue(delegate.responds(to: #selector(NSApplication.terminate(_:))))
    }

    func testActualApplicationQuitProtectsRecoveryAndKeepEditingReopensAdmission() async throws {
        let application = try XCTUnwrap(NSApp)
        let selector = NSSelectorFromString("applicationShouldTerminate:")
        guard application.delegate?.responds(to: selector) == true else {
            XCTFail("Refusing to invoke Quit without its production consent hook")
            return
        }
        let fixture = try PullRequestAppFixture()
        let identity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .pullRequest(repository: fixture.repository, number: ForgeItemNumber(42)))
        let exact = ForgeDraftContent(title: "Actual Quit recovery", body: "Keep these exact recovered bytes")
        let session = GitX.RepositoryPullRequestRecoverySession(drafts: GitX.NullRepositoryPullRequestDraftStore(), now: Date.init, ownerIsCurrent: { true })
        let submission = GitX.RepositoryEditSubmissionLifetime(identity: identity, destination: .repository(fixture.repository), content: exact)
        submission.persisted(.unavailable)
        XCTAssertTrue(submission.admit())
        submission.finish(error: CancellationError())
        session.submissions.append(submission)
        let quit = try XCTUnwrap(application.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        let menuTarget = try XCTUnwrap(quit.target as? NSObject)
        let terminationTargets: [NSObject] = [application, menuTarget]
        defer {
            for target in terminationTargets {
                NSObject.cancelPreviousPerformRequests(withTarget: target, selector: #selector(NSApplication.terminate(_:)), object: nil)
            }
            GitX.RepositoryTerminationCoordinator.shared.cancelPendingQuit()
            submission.resolveRecovery()
            session.invalidateAttachedPresentation()
        }
        XCTAssertTrue(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === session })
        for target in terminationTargets {
            let consent = expectation(description: "The actual application delegate protects recovered text")
            session.attachedCloseDecision = { answer in answer(false); consent.fulfill(); return true }
            // AppKit's termination loop must run as a native event, outside this Swift task.
            target.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
            await fulfillment(of: [consent], timeout: 5)
            await waitForHarness {
                do {
                    let admitted = try GitX.RepositoryLocalMutationRegistry.shared.admitContinuation(requiresOpenAdmission: true)
                    GitX.RepositoryLocalMutationRegistry.shared.finish(admitted)
                    return true
                } catch { return false }
            }
            XCTAssertEqual(submission.recoveryContent, exact)
            XCTAssertTrue(submission.needsCloseProtection)
            XCTAssertTrue(NSApp.isRunning)
        }
    }

    func testActualMenuQuitWaitsForAnUnrelatedSheetAndCanBeCancelled() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Unrelated sheet"
        alert.beginSheetModal(for: parent) { _ in }
        let coordinator = GitX.RepositoryTerminationCoordinator.shared
        defer {
            coordinator.cancelPendingQuit()
            if parent.attachedSheet === alert.window {
                parent.endSheet(alert.window)
            }
            parent.close()
        }
        guard parent.isVisible, parent.attachedSheet === alert.window else {
            XCTFail("An unrelated attached sheet must be present before invoking Quit")
            return
        }
        let quit = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        let target = try XCTUnwrap(quit.target as? ApplicationController)
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let panelID = "GitX.Quit.WaitingForLocalMutations"
        func waitingPanel() -> NSWindow? {
            NSApp.windows.first {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.accessibilityIdentifier() == panelID
            }
        }
        _ = try target.perform(XCTUnwrap(quit.action), with: nil)
        await waitForHarness { waitingPanel() != nil }
        let panel = try XCTUnwrap(waitingPanel())
        XCTAssertTrue(parent.attachedSheet === alert.window)
        coordinator.cancelPendingQuit()
        await waitForHarness { !panel.isVisible }
        XCTAssertTrue(parent.attachedSheet === alert.window)
        let admitted = try GitX.RepositoryLocalMutationRegistry.shared.admitContinuation(requiresOpenAdmission: true)
        GitX.RepositoryLocalMutationRegistry.shared.finish(admitted)
    }

    func testPendingQuitRejectsNativeIndexAndRecoveryWritersButAllowsReads() async throws {
        let fixture = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        addTeardownBlock { @MainActor in
            fixture.repository.revisionList?.cleanup()
            let service = fixture.repository.worktreeService
            service.cancel()
            #if DEBUG
                let drained = XCTestExpectation(description: "Rejected worktree request drains before fixture deletion")
                service.drainForTesting { drained.fulfill() }
                guard await XCTWaiter.fulfillment(of: [drained], timeout: 15) == .completed else {
                    XCTFail("Retaining undrained fixture at " + fixture.directory.path)
                    return
                }
            #endif
            fixture.cleanup()
        }
        let runner = GitX.IndexRepositoryCommandRunner(repository: fixture.repository)
        let writer = GitX.IndexWriterCoordinator.coordinator(for: fixture.repository)
        let reflog = try GitX.RepositoryReflogService(repository: fixture.repository)
        let previous = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: fixture.directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = try reflog.preview(target: previous, mode: .soft)
        let index = try Data(contentsOf: fixture.directory.appendingPathComponent(".git/index"))
        let worktrees = fixture.repository.worktreeService
        await waitForHarness { !worktrees.worktrees.isEmpty }
        let mutations = GitX.RepositoryLocalMutationRegistry.shared
        mutations.sealAdmission()
        defer { mutations.reopenAdmission() }
        func refused(_ error: Error) {
            XCTAssertEqual(error as? GitX.RepositoryLocalMutationError, .terminationPending)
            XCTAssertTrue(error.localizedDescription.contains("Cancel Quit"))
        }
        XCTAssertThrowsError(try runner.output(arguments: ["update-index", "--refresh"], input: nil, environment: nil)) { refused($0) }
        XCTAssertThrowsError(try writer.performIfAvailable("new mutation during Quit") { XCTFail("No new writer body may execute") }) { refused($0) }
        let rejected = expectation(description: "Queued mutation rejection completes exactly once")
        rejected.assertForOverFulfill = true
        runner.data(arguments: ["update-index", "--refresh"]) { bytes, error in
            XCTAssertNil(bytes)
            XCTAssertEqual(error as? GitX.RepositoryLocalMutationError, .terminationPending)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertThrowsError(try reflog.createRecoveryBranch(objectID: previous, name: "recovery/not-admitted")) { refused($0) }
        XCTAssertThrowsError(try reflog.reset(confirmed: preview, discardConfirmed: false)) { refused($0) }
        XCTAssertEqual(try runner.rawOutput(arguments: ["rev-parse", "HEAD"], environment: nil), Data((previous + "\n").utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".git/refs/heads/recovery/not-admitted").path))
        var tagFailure: NSError?
        let tagService = GitX.RepositoryMutationService(repository: fixture.repository)
        XCTAssertFalse(tagService.createTag("quit-not-admitted", message: "", at: PBGitRef(string: "HEAD"), error: &tagFailure))
        XCTAssertEqual(tagFailure?.localizedDescription, GitX.RepositoryLocalMutationError.terminationPending.localizedDescription)
        XCTAssertEqual(try GitXTestGitFixture.run(["for-each-ref", "--format=%(refname)", "refs/tags/quit-not-admitted"], in: fixture.directory).standardOutput, "")
        XCTAssertFalse(writer.isBusy)
        let newPath = fixture.directory.appendingPathComponent("quit-not-admitted")
        do {
            _ = try await worktrees.addWorktree(path: newPath.path, branch: "quit-not-admitted", createBranch: true)
            XCTFail("A new worktree writer cannot be admitted during Quit")
        } catch {
            let message = error.localizedDescription + ((error as NSError).localizedFailureReason ?? "")
            XCTAssertTrue(message.contains("Cancel Quit"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPath.path))
        XCTAssertEqual(try GitXTestGitFixture.run(["for-each-ref", "--format=%(refname)", "refs/heads/quit-not-admitted"], in: fixture.directory).standardOutput, "")
    }

    @MainActor private final class RemoteReplyTarget {
        weak var coordinator: GitX.RepositoryTerminationCoordinator?
    }

    private nonisolated struct NoUnknownOutcomeWrites: GitX.ForgeUnknownMutationOutcomePersisting {
        func record(_ records: [GitX.ForgeUnknownMutationOutcomeRecord]) async throws {
            XCTFail("Cancel Quit must not record unknown outcomes")
        }

        func records(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity, operation: ForgeOperation, scope: GitX.ForgeUnknownMutationOutcomeScope) async throws -> [GitX.ForgeUnknownMutationOutcomeRecord] {
            []
        }

        func consume(accountID: ForgeAccountID, repository: ForgeRepositoryIdentity, operation: ForgeOperation, scope: GitX.ForgeUnknownMutationOutcomeScope) async throws -> [GitX.ForgeUnknownMutationOutcomeRecord] {
            []
        }
    }

    func testForgeMutationFinishingDuringTheQuitChoiceNeedsNoUnknownOutcomeRecord() throws {
        let fixture = try PullRequestAppFixture()
        let finish = Mutex<(@Sendable () -> Void)?>(nil)
        let remote = GitX.ForgeMutationQuitCoordinator(
            persistence: NoUnknownOutcomeWrites(),
            choiceProvider: { mutations in
                XCTAssertEqual(mutations.count, 1)
                finish.withLock { $0 }?()
                return .quitAnyway
            },
            terminationReply: { _ in XCTFail("An already settled operation requires no delayed reply") }
        )
        let change = try remote.register(accountID: fixture.accountID, repository: fixture.repository, operation: .editPullRequest)
        finish.withLock {
            $0 = { [weak remote] in
                XCTAssertTrue(remote?.finish(change) == true)
            }
        }
        XCTAssertEqual(remote.applicationShouldTerminate(), .terminateNow)
        XCTAssertTrue(remote.activeMutations().isEmpty)
    }

    func testCancelQuitReopensTheActualForgeLifecycleWithoutCancellingItsMutation() async throws {
        let fixture = try PullRequestAppFixture()
        let target = RemoteReplyTarget()
        let remoteAsked = expectation(description: "The actual Forge lifecycle retains its Wait choice")
        let remote = GitX.ForgeMutationQuitCoordinator(persistence: NoUnknownOutcomeWrites(), choiceProvider: { _ in
            remoteAsked.fulfill(); return .wait
        }, terminationReply: { [target] allowed in target.coordinator?.remoteTerminationReply(allowed) }, scheduleTimeout: { _, _ in })
        defer {
            GitX.RepositoryLocalMutationRegistry.shared.reopenAdmission()
            remote.cancelApplicationTermination()
        }
        let first = try remote.register(accountID: fixture.accountID, repository: fixture.repository, operation: .editPullRequest)
        let replied = expectation(description: "Cancel Quit replies once and reopens admission")
        var replies: [Bool] = []
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: .shared, sessions: { [] }, remoteDecision: {
            remote.applicationShouldTerminate()
        }, remoteCancelled: { remote.cancelApplicationTermination() }, reply: { replies.append($0); replied.fulfill() })
        target.coordinator = coordinator
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [remoteAsked], timeout: 5)
        XCTAssertThrowsError(try remote.register(accountID: fixture.accountID, repository: fixture.repository, operation: .createPullRequest)) {
            XCTAssertEqual($0 as? GitX.ForgeMutationQuitCoordinatorError, .terminationPending)
        }
        XCTAssertEqual(remote.activeMutations().count, 1)
        coordinator.cancelPendingQuit()
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(remote.activeMutations().count, 1, "Cancelling Quit cannot cancel the admitted HTTP operation")
        let second = try remote.register(accountID: fixture.accountID, repository: fixture.repository, operation: .createPullRequest)
        XCTAssertEqual(remote.activeMutations().count, 2)
        XCTAssertTrue(remote.finish(first))
        XCTAssertTrue(remote.finish(second))
        XCTAssertTrue(remote.activeMutations().isEmpty)
        XCTAssertEqual(replies, [false])
    }

    #if DEBUG
        func testRecoveryQuitHarnessRetainsTheExactNativeRecoveryContent() async throws {
            let fixture = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
            let owner = GitX.PBGitWindowController()
            owner.repository = fixture.repository
            owner.showWindow(nil)
            disposeAfterTest(fixture, owner: owner)
            let proof = GitX.Milestone2UITestHarness.runProductProof(for: owner, environment: ["GITX_M2_SCENARIO": "recovery-quit"])
            let window = try XCTUnwrap(owner.window)
            await waitForHarness { window.attachedSheet != nil }
            let editor = try XCTUnwrap(window.attachedSheet)
            try XCTUnwrap(findHarness("GitX.PullRequest.Submit", in: editor.contentView) as? NSButton).performClick(nil)
            await waitForHarness { window.attachedSheet?.contentView.flatMap { self.findHarness("GitX.PullRequest.Recovery.Copy", in: $0) } != nil }
            let recovered = try XCTUnwrap(window.attachedSheet)
            let sheet = try XCTUnwrap(recovered.windowController as? GitX.ForgePullRequestSheetController)
            XCTAssertEqual(sheet.recoveryContentSnapshot, ForgeDraftContent(title: "Recovery Quit title", body: "Exact unsaved recovery body"))
            try sheet.onCancel?(XCTUnwrap(sheet.recoveryContentSnapshot))
            sheet.invalidatePresentation()
            withExtendedLifetime(proof) {}
        }

        func testLocalQuitHarnessOwnsRealGitThroughSuccessAndFailure() async throws {
            for failing in [false, true] {
                let fixture = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
                let owner = GitX.PBGitWindowController()
                owner.repository = fixture.repository
                owner.showWindow(nil)
                let release = fixture.directory.appendingPathComponent(".git/quit-local-release")
                disposeAfterTest(fixture, owner: owner)
                defer { try? Data().write(to: release) }
                let proof = GitX.Milestone2UITestHarness.runProductProof(for: owner, environment: ["GITX_M2_SCENARIO": "local-mutation-quit"])
                let started = fixture.directory.appendingPathComponent(".git/quit-local-started")
                await waitForHarness { FileManager.default.fileExists(atPath: started.path) }
                XCTAssertTrue(GitX.RepositoryLocalMutationRegistry.shared.hasActivity)
                if failing {
                    try GitXTestGitFixture.run(["branch", "recovery/quit-local"], in: fixture.directory)
                }
                try Data().write(to: release)
                await waitForHarness { !GitX.RepositoryLocalMutationRegistry.shared.hasActivity }
                let head = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: fixture.directory).standardOutput
                XCTAssertEqual(try GitXTestGitFixture.run(["rev-parse", "refs/heads/recovery/quit-local"], in: fixture.directory).standardOutput, head)
                withExtendedLifetime(proof) {}
            }
        }

    #endif

    private func disposeAfterTest(_ fixture: LocalPullRequestRepositoryFixture, owner: GitX.PBGitWindowController) {
        addTeardownBlock { @MainActor in
            owner.close()
            fixture.repository.revisionList?.cleanup()
            let service = fixture.repository.worktreeService
            service.cancel()
            #if DEBUG
                let drained = XCTestExpectation(description: "Native Quit fixture drains owned I/O")
                service.drainForTesting { drained.fulfill() }
                guard await XCTWaiter.fulfillment(of: [drained], timeout: 15) == .completed else {
                    XCTFail("Retaining undrained fixture at " + fixture.directory.path)
                    return
                }
            #endif
            fixture.cleanup()
        }
    }

    private func waitForHarness(_ predicate: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func findHarness(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { [self] in findHarness(identifier, in: $0) }.first
    }
}
