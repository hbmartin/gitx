import AppKit
import ForgeKit
@testable import GitX
import XCTest

@MainActor
final class RepositoryTerminationTests: XCTestCase {
    private func recovery() throws -> GitX.RepositoryPullRequestRecoverySession {
        let fixture = try PullRequestAppFixture()
        let identity = try ForgeDraftIdentity(accountID: fixture.accountID, destination: .pullRequest(repository: fixture.repository, number: ForgeItemNumber(42)))
        let session = GitX.RepositoryPullRequestRecoverySession(drafts: GitX.NullRepositoryPullRequestDraftStore(), now: Date.init, ownerIsCurrent: { true })
        let submission = GitX.RepositoryEditSubmissionLifetime(identity: identity, destination: .repository(fixture.repository), content: ForgeDraftContent(title: "Exact title", body: "Exact unsaved bytes"))
        submission.persisted(.unavailable)
        XCTAssertTrue(submission.admit())
        submission.finish(error: CancellationError())
        session.submissions.append(submission)
        return session
    }

    func testMenuQuitProtectsRecoveryBeforeAppKitWaitsForItsSheet() async throws {
        let session = try recovery()
        let registry = GitX.RepositoryLocalMutationRegistry()
        var answer: ((Bool) -> Void)?
        let firstConsent = expectation(description: "Menu Quit asks for consent before entering AppKit")
        let secondConsent = expectation(description: "Another attempt requires fresh consent")
        let cancelled = expectation(description: "Keep Editing cancels menu preflight")
        let accepted = expectation(description: "AppKit starts only after final consent")
        var prompts = 0
        session.attachedCloseDecision = {
            answer = $0; prompts += 1
            (prompts == 1 ? firstConsent : secondConsent).fulfill()
            return true
        }
        var terminated = 0
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [session] }, remoteDecision: { .terminateNow }, remoteCancelled: { cancelled.fulfill() }, terminate: {
            terminated += 1; accepted.fulfill()
        }, reply: { _ in
            XCTFail("Menu preflight cannot reply to an AppKit termination that has not started")
        })
        coordinator.requestTermination()
        coordinator.requestTermination()
        await fulfillment(of: [firstConsent], timeout: 5)
        XCTAssertEqual(terminated, 0)
        try XCTUnwrap(answer)(false)
        await fulfillment(of: [cancelled], timeout: 5)
        let ticket = try registry.admitContinuation(requiresOpenAdmission: true)
        registry.finish(ticket)
        XCTAssertTrue(session.submissions[0].needsCloseProtection)
        answer = nil
        coordinator.requestTermination()
        await fulfillment(of: [secondConsent], timeout: 5)
        try XCTUnwrap(answer)(true)
        await fulfillment(of: [accepted], timeout: 5)
        XCTAssertFalse(session.protectionState.isEmpty)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertTrue(session.protectionState.isEmpty)
        XCTAssertEqual(terminated, 1)
    }

    func testAcceptedMenuPreflightCanBeCancelledIfAppKitDoesNotReply() async throws {
        let session = try recovery()
        let registry = GitX.RepositoryLocalMutationRegistry()
        let original = session.protectionState
        let forwarded = expectation(description: "Quit is offered to AppKit")
        session.attachedCloseDecision = { completion in
            completion(true)
            return true
        }
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [session] }, remoteDecision: { .terminateNow }, remoteCancelled: {},
                                                                terminate: { forwarded.fulfill() },
                                                                reply: { _ in XCTFail("There is no AppKit reply pending") })
        coordinator.requestTermination()
        await fulfillment(of: [forwarded], timeout: 5)
        XCTAssertEqual(session.protectionState, original)
        XCTAssertThrowsError(try registry.admit())
        coordinator.cancelPendingQuit()
        XCTAssertEqual(session.protectionState, original)
        let activity = try registry.admit()
        registry.finish(activity)
    }

    func testQuitWaitsForUnrelatedSheetWithoutDiscardingRecovery() async throws {
        let session = try recovery()
        let registry = GitX.RepositoryLocalMutationRegistry()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.close() }
        let alert = NSAlert()
        alert.messageText = "Unrelated alert"
        alert.beginSheetModal(for: parent) { _ in }
        session.attachedCloseDecision = { completion in completion(true); return true }
        let waiting = expectation(description: "Quit waits behind the unrelated sheet")
        let forwarded = expectation(description: "A fresh Quit reaches AppKit after the sheet ends")
        var waitingCount = 0
        weak var waitingPanel: NSPanel?
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [session] }, remoteDecision: { .terminateNow }, remoteCancelled: {},
                                                                waitingPresented: { panel in
                                                                    waitingPanel = panel
                                                                    waitingCount += 1
                                                                    if waitingCount == 1 {
                                                                        waiting.fulfill()
                                                                    }
                                                                },
                                                                hasBlockingSheets: { parent.attachedSheet != nil },
                                                                terminate: { forwarded.fulfill() },
                                                                reply: { _ in XCTFail("AppKit has not asked for a reply") })
        let protected = session.protectionState
        coordinator.requestTermination()
        await fulfillment(of: [waiting], timeout: 5)
        try attachScreenshot(of: XCTUnwrap(waitingPanel), named: "Quit waits for an unrelated sheet")
        XCTAssertEqual(session.protectionState, protected)
        XCTAssertTrue(parent.attachedSheet === alert.window)
        coordinator.cancelPendingQuit()
        XCTAssertTrue(parent.attachedSheet === alert.window)
        coordinator.requestTermination()
        parent.endSheet(alert.window)
        await fulfillment(of: [forwarded], timeout: 5)
        XCTAssertEqual(session.protectionState, protected)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertTrue(session.protectionState.isEmpty)
    }

    func testAppKitQuitJoiningMenuConsentReceivesOneReply() async throws {
        let session = try recovery()
        let consent = expectation(description: "Menu consent is pending")
        var answer: ((Bool) -> Void)?
        session.attachedCloseDecision = { answer = $0; consent.fulfill(); return true }
        let replied = expectation(description: "Joining AppKit request receives one reply")
        replied.assertForOverFulfill = true
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [session] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, terminate: {
            XCTFail("An already pending AppKit request must receive its reply instead of another terminate call")
        }, reply: { XCTAssertTrue($0); replied.fulfill() })
        coordinator.requestTermination()
        await fulfillment(of: [consent], timeout: 5)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        try XCTUnwrap(answer)(true)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
    }

    func testKeepEditingPreservesSavedPresentationsWhileAnotherSessionNeedsConsent() async throws {
        let saved = try recovery()
        let savedSubmission = try XCTUnwrap(saved.submissions.first)
        savedSubmission.markRecoverySaved(savedSubmission.recoveryContent)
        saved.retire()
        let unsaved = try recovery()
        var endedPresentations = 0
        saved.onAcceptedTermination = { endedPresentations += 1 }
        let consent = expectation(description: "Only the unsaved session requires consent")
        var answer: ((Bool) -> Void)?
        saved.attachedCloseDecision = { _ in XCTFail("Saved text needs no discard decision"); return false }
        unsaved.attachedCloseDecision = { answer = $0; consent.fulfill(); return true }
        let replied = expectation(description: "Keep Editing cancels the attempt")
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [saved, unsaved] }, remoteDecision: {
            XCTFail("Declined recovery consent precedes remote choices"); return .terminateNow
        }, remoteCancelled: {}, terminate: { XCTFail("Cancelled consent cannot start AppKit Quit") }, reply: { XCTAssertFalse($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [consent], timeout: 5)
        let reply = try XCTUnwrap(answer); answer = nil
        reply(false)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(endedPresentations, 0)
        XCTAssertTrue(GitX.RepositoryPullRequestRecoverySession.currentSessions.contains { $0 === saved })
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === saved })
        XCTAssertFalse(unsaved.protectionState.isEmpty)
    }

    func testEmptyQuitCoalescesAndSendsOneTerminalReply() async {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let replied = expectation(description: "Exactly one AppKit reply")
        var replies: [Bool] = []
        var remoteDecisions = 0
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: {
            remoteDecisions += 1; return .terminateNow
        }, remoteCancelled: { XCTFail("The accepted attempt is not cancelled") }, reply: { replies.append($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(remoteDecisions, 1)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(replies, [true])
        XCTAssertThrowsError(try registry.admit())
        coordinator.remoteTerminationReply(true)
        coordinator.cancelPendingQuit()
        XCTAssertEqual(replies, [true])
    }

    func testCancelQuitPreservesStartedWorkAndReopensAdmission() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let activity = try registry.admitContinuation()
        defer { registry.finish(activity) }
        let replied = expectation(description: "Cancelled quit replies once")
        var replies: [Bool] = []
        var remoteCancelled = 0
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: {
            XCTFail("Remote Quit Anyway cannot bypass a local writer"); return .terminateNow
        }, remoteCancelled: { remoteCancelled += 1 }, reply: { replies.append($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.windows.contains { $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" && $0.isVisible } }, object: nil)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertThrowsError(try registry.admitContinuation())
        XCTAssertTrue(registry.hasActivity)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" && $0.isVisible })
        try attachScreenshot(of: panel, named: "Quit waits for started local mutation and offers Cancel Quit")
        coordinator.cancelPendingQuit()
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(remoteCancelled, 1)
        XCTAssertTrue(registry.hasActivity)
        registry.finish(activity)
        XCTAssertFalse(registry.hasActivity)
        let next = try registry.admit()
        registry.finish(next)
    }

    func testCompletionWhileTheWaitingPanelAppearsCannotLoseItsWakeup() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let ticket = try registry.admitContinuation()
        defer { registry.finish(ticket) }
        let observed = expectation(description: "The waiting panel is presented")
        let replied = expectation(description: "Quit notices completion before it suspends")
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, waitingPresented: { panel in
            XCTAssertTrue(panel.isVisible)
            registry.finish(ticket)
            observed.fulfill()
        }, reply: { XCTAssertTrue($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [observed, replied], timeout: 5)
        XCTAssertFalse(registry.hasActivity)
    }

    func testStartedWorkDrainsBeforeTheRemoteQuitChoice() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let activity = try registry.admitContinuation()
        defer { registry.finish(activity) }
        let replied = expectation(description: "Quit resumes after actual completion")
        var remoteDecisions = 0
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: {
            XCTAssertFalse(registry.hasActivity); remoteDecisions += 1; return .terminateNow
        }, remoteCancelled: {}, reply: { XCTAssertTrue($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.windows.contains { $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" && $0.isVisible } }, object: nil)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(remoteDecisions, 0)
        registry.finish(activity)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(remoteDecisions, 1)
    }

    func testRecoveryChangedDuringAnotherConsentNeedsFreshConsentAndKeepEditingCancelsQuit() async throws {
        let first = try recovery()
        let second = try recovery()
        var callbacks: [(Bool) -> Void] = []
        let firstPrompt = expectation(description: "First recovery consent")
        let secondPrompt = expectation(description: "Second recovery consent")
        let renewed = expectation(description: "Changed text requires another consent")
        var firstRequests = 0
        first.attachedCloseDecision = { callback in
            callbacks.append(callback); firstRequests += 1
            if firstRequests == 1 {
                firstPrompt.fulfill()
            } else {
                renewed.fulfill()
            }
            return true
        }
        second.attachedCloseDecision = { callback in callbacks.append(callback); secondPrompt.fulfill(); return true }
        let replied = expectation(description: "Keep Editing cancels termination")
        let registry = GitX.RepositoryLocalMutationRegistry()
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [first, second] }, remoteDecision: {
            XCTFail("Recovered text must be decided first"); return .terminateNow
        }, remoteCancelled: {}, reply: { XCTAssertFalse($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [firstPrompt], timeout: 5)
        callbacks.removeFirst()(true)
        await fulfillment(of: [secondPrompt], timeout: 5)
        first.submissions[0].updateRecoveryContent(ForgeDraftContent(title: "New exact title", body: "New text after preflight"))
        callbacks.removeFirst()(true)
        await fulfillment(of: [renewed], timeout: 5)
        callbacks.removeFirst()(false)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(first.submissions[0].recoveryContent.body, "New text after preflight")
        XCTAssertTrue(first.submissions[0].needsCloseProtection)
        XCTAssertTrue(second.submissions[0].needsCloseProtection)
    }

    func testRemoteCompletionRevalidatesRecoveryCreatedWhileWaiting() async throws {
        let recovery = try recovery()
        var visible: [GitX.RepositoryPullRequestRecoverySession] = []
        let remoteAsked = expectation(description: "Existing Forge quit choice is retained")
        let consent = expectation(description: "New recovered text blocks the final remote reply")
        let replied = expectation(description: "Quit cancelled after new recovery")
        var decision: ((Bool) -> Void)?
        recovery.attachedCloseDecision = { decision = $0; consent.fulfill(); return true }
        var replies: [Bool] = []
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { visible }, remoteDecision: {
            remoteAsked.fulfill(); return .terminateLater
        }, remoteCancelled: {}, reply: { replies.append($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [remoteAsked], timeout: 5)
        visible = [recovery]
        coordinator.remoteTerminationReply(true)
        coordinator.remoteTerminationReply(true)
        await fulfillment(of: [consent], timeout: 5)
        try XCTUnwrap(decision)(false)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [false])
    }

    func testAnOldRemoteDecisionCannotApproveAReentrantQuitAttempt() async {
        let replies = expectation(description: "Both attempts are cancelled exactly once")
        replies.expectedFulfillmentCount = 2
        var values: [Bool] = []
        var decisions = 0
        var coordinator: GitX.RepositoryTerminationCoordinator!
        defer { coordinator = nil }
        coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [] }, remoteDecision: {
            decisions += 1
            if decisions == 1 {
                coordinator.cancelPendingQuit()
                XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
                return .terminateNow
            }
            return .terminateCancel
        }, remoteCancelled: {}, reply: { values.append($0); replies.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replies], timeout: 5)
        XCTAssertEqual(values, [false, false])
        XCTAssertEqual(decisions, 2)
    }

    func testRemoteReplyDuringTheNativeChoiceCannotStrandTheTerminationAttempt() async {
        let replied = expectation(description: "Reentrant remote completion still settles Quit")
        var coordinator: GitX.RepositoryTerminationCoordinator!
        defer { coordinator = nil }
        coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [] }, remoteDecision: {
            coordinator.remoteTerminationReply(true)
            return .terminateLater
        }, remoteCancelled: {}, reply: { XCTAssertTrue($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
    }

    func testImmediateRemoteCancellationReopensAdmission() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let replied = expectation(description: "Immediate remote cancellation replies once")
        var cancellations = 0
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: { .terminateCancel }, remoteCancelled: { cancellations += 1 }, reply: { XCTAssertFalse($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(cancellations, 1)
        let ticket = try registry.admit()
        registry.finish(ticket)
    }

    func testMissingRecoveryPresenterCannotAuthorizeQuitOrDiscardExactText() async throws {
        let session = try recovery()
        let replied = expectation(description: "Unavailable presentation cancels Quit safely")
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [session] }, remoteDecision: {
            XCTFail("Unresolved recovered text cannot be skipped"); return .terminateNow
        }, remoteCancelled: {}, reply: { XCTAssertFalse($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(session.submissions[0].needsCloseProtection)
        XCTAssertEqual(session.submissions[0].recoveryContent.body, "Exact unsaved bytes")
    }

    func testSynchronousRecoveryDecisionIsConsumedExactlyOnce() async throws {
        let session = try recovery()
        session.attachedCloseDecision = { callback in callback(true); return false }
        let replied = expectation(description: "Synchronous consent still has one final reply")
        replied.assertForOverFulfill = true
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [session] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, reply: { XCTAssertTrue($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(session.protectionState.isEmpty)
    }

    func testRemoteCancellationSettlesTheSameAttempt() async {
        let asked = expectation(description: "Remote confirmation started")
        let replied = expectation(description: "Remote cancellation is delivered")
        let registry = GitX.RepositoryLocalMutationRegistry()
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: {
            asked.fulfill(); return .terminateLater
        }, remoteCancelled: {}, reply: { XCTAssertFalse($0); replied.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [asked], timeout: 5)
        coordinator.remoteTerminationReply(false)
        await fulfillment(of: [replied], timeout: 5)
    }

    func testLocalRegistryPreservesNestedStartedWorkAndRejectsNewContinuations() throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let started = try registry.admitContinuation()
        registry.sealAdmission()
        XCTAssertThrowsError(try registry.admit())
        XCTAssertThrowsError(try registry.admitContinuation())
        try registry.withStartedActivity(started) {
            let nested = try registry.admit()
            registry.finish(nested)
        }
        let later = registry.trackContinuation()
        try registry.withStartedActivity(later) { XCTAssertThrowsError(try registry.admit()) }
        registry.finish(later)
        XCTAssertTrue(registry.hasActivity)
        registry.finish(started)
        registry.finish(started)
        XCTAssertFalse(registry.hasActivity)
        registry.reopenAdmission()
        let next = try registry.admit()
        registry.finish(next)
    }

    func testCancelThenImmediatelyRetryingQuitDoesNotLoseTheNewAttempt() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        let ticket = try registry.admitContinuation()
        defer { registry.finish(ticket) }
        var replies: [Bool] = []
        let finished = expectation(description: "Both quit attempts receive one reply")
        finished.expectedFulfillmentCount = 2
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, reply: { replies.append($0); finished.fulfill() })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        let firstWaiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" } }, object: nil)
        await fulfillment(of: [firstWaiting], timeout: 5)
        let oldPanel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" })
        coordinator.cancelPendingQuit()
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        let nextWaiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.windows.contains { $0 !== oldPanel && $0.isVisible && $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" } }, object: nil)
        await fulfillment(of: [nextWaiting], timeout: 5)
        registry.finish(ticket)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(replies, [false, true])
    }

    func testDraftLoadsDoNotDelayQuitButAdmittedRecoveryWritesDrain() async throws {
        let registry = GitX.RepositoryLocalMutationRegistry()
        defer { registry.reopenAdmission() }
        let queue = GitX.RepositoryDraftOperationQueue(mutations: registry)
        let loadGate = IgnoringCancellationGate<Bool>()
        let loadStarted = expectation(description: "Uncommitted recovery load starts")
        let load = queue.enqueueThrowing { loadStarted.fulfill(); return await loadGate.wait() }
        await fulfillment(of: [loadStarted], timeout: 5)
        let readReply = expectation(description: "A draft read does not hold normal Quit")
        let readQuit = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, reply: { XCTAssertTrue($0); readReply.fulfill() })
        XCTAssertEqual(readQuit.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [readReply], timeout: 5)
        await loadGate.release(true)
        _ = try await load.value
        registry.reopenAdmission()
        let writeGate = IgnoringCancellationGate<Bool>()
        let writeStarted = expectation(description: "Recovery write is admitted")
        let write = queue.enqueueThrowing(writes: true) { writeStarted.fulfill(); return await writeGate.wait() }
        await fulfillment(of: [writeStarted], timeout: 5)
        let writeReply = expectation(description: "An admitted draft save drains before Quit")
        var replied = false
        let writeQuit = GitX.RepositoryTerminationCoordinator(mutations: registry, sessions: { [] }, remoteDecision: { .terminateNow }, remoteCancelled: {}, reply: { replied = $0; writeReply.fulfill() })
        XCTAssertEqual(writeQuit.applicationShouldTerminate(), .terminateLater)
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "GitX.Quit.WaitingForLocalMutations" } }, object: nil)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertFalse(replied)
        let rejected = queue.enqueueThrowing(writes: true) { XCTFail("A new recovery write cannot be admitted during Quit"); return false }
        await writeGate.release(true)
        _ = try await write.value
        do { _ = try await rejected.value; XCTFail("The pending quit seals new writes") } catch { XCTAssertEqual(error as? GitX.RepositoryLocalMutationError, .terminationPending) }
        await fulfillment(of: [writeReply], timeout: 5)
        XCTAssertTrue(replied)
        XCTAssertFalse(registry.hasActivity)
    }

    func testRecoveredTextIsDiscardedOnlyAtTheFinalAcceptedTerminationReply() async throws {
        let recovery = try recovery()
        let consent = expectation(description: "Recovery preflight")
        let remote = expectation(description: "Remote choice remains independent")
        let replied = expectation(description: "Actual termination boundary")
        var answer: ((Bool) -> Void)?
        recovery.attachedCloseDecision = { answer = $0; consent.fulfill(); return true }
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [recovery] }, remoteDecision: {
            remote.fulfill(); return .terminateLater
        }, remoteCancelled: {}, reply: { allowed in
            XCTAssertTrue(allowed)
            XCTAssertTrue(recovery.protectionState.isEmpty)
            replied.fulfill()
        })
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
        await fulfillment(of: [consent], timeout: 5)
        try XCTUnwrap(answer)(true)
        await fulfillment(of: [remote], timeout: 5)
        XCTAssertTrue(recovery.submissions[0].needsCloseProtection, "Accepted preflight cannot discard text while a later guard is undecided")
        coordinator.remoteTerminationReply(true)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(recovery.submissions.isEmpty)
    }
}
