import AppKit
import ForgeKit
@testable import GitX
import XCTest

@MainActor
final class NativeRecoverySessionTests: XCTestCase {
    @MainActor private final class Owner { var current = true }
    @MainActor private struct Fixture {
        let owner: Owner
        let session: GitX.RepositoryPullRequestRecoverySession
        let submission: GitX.RepositoryEditSubmissionLifetime
        let sheet: GitX.ForgePullRequestSheetController
        let parent: NSWindow
        let store: CompletionDraftStore
        let identity: ForgeDraftIdentity
        let exact: ForgeDraftContent
        let loadGate: IgnoringCancellationGate<Bool>
        let writeGate: IgnoringCancellationGate<Bool>
    }

    private func fixture(pending: Bool = false, presented: Bool = true) async throws -> Fixture {
        let forge = try PullRequestAppFixture()
        let identity = try ForgeDraftIdentity(accountID: forge.accountID, destination: .pullRequest(repository: forge.repository, number: ForgeItemNumber(42)))
        let exact = ForgeDraftContent(title: "Exact recovered title", body: "Exact recovered body\nsecond line")
        let submission = try GitX.RepositoryEditSubmissionLifetime(identity: identity, destination: .pullRequest(forge.repository, ForgeItemNumber(42)), content: exact)
        submission.persisted(.unavailable)
        if !pending {
            XCTAssertTrue(submission.admit()); submission.finish(error: CancellationError())
        }
        let owner = Owner()
        let store = CompletionDraftStore()
        try await store.save(identity: identity, content: ForgeDraftContent(title: "Stored title", body: "Stored body"), at: .distantPast)
        let session = GitX.RepositoryPullRequestRecoverySession(drafts: NativeCompletionDraftStore(store: store), now: Date.init, ownerIsCurrent: { owner.current })
        session.submissions.append(submission)
        let sheet = GitX.ForgePullRequestSheetController(mode: .recovery(destination: submission.destination), restoredContent: exact)
        session.bind(sheet, to: submission)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        if presented {
            sheet.beginSheet(for: parent)
        }
        session.attachedCloseDecision = { [weak session, weak parent] completion in
            guard let session, let parent else { return false }
            return session.confirmClosing(parent: parent, validation: { owner.current }, completion: completion)
        }
        let fixture = Fixture(owner: owner, session: session, submission: submission, sheet: sheet, parent: parent, store: store, identity: identity, exact: exact, loadGate: IgnoringCancellationGate(), writeGate: IgnoringCancellationGate())
        addTeardownBlock { @MainActor in
            owner.current = false
            session.invalidateAttachedPresentation()
            submission.resolveRecovery()
            sheet.invalidatePresentation()
            await fixture.loadGate.release(true); await fixture.writeGate.release(true)
            await store.releaseSaveWaiters()
            await session.queue.tail?.value
            session.retire()
            parent.close()
        }
        return fixture
    }

    func testNativeCloseConsentIsCoalescedNondestructiveAndPhaseSpecific() async throws {
        for (pending, presented) in [(true, false), (false, false), (false, true)] {
            let fixture = try await fixture(pending: pending, presented: presented)
            var decisions: [Bool] = []
            XCTAssertTrue(fixture.session.requestCloseDecision { decisions.append($0) })
            let alert = try await alert("GitX.PullRequest.Recovery.WindowCloseConfirmation", on: fixture)
            XCTAssertTrue(fixture.session.requestCloseDecision { decisions.append($0) })
            XCTAssertNil(alert.attachedSheet)
            let text = descendants(alert.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
            if pending {
                XCTAssertTrue(text.contains("still being saved or sent"), text)
            } else if presented {
                XCTAssertTrue(text.contains("copy or save"), text)
            } else {
                XCTAssertTrue(text.contains("waiting for an editor"), text)
            }
            try attachScreenshot(of: alert, named: "Recovery close consent reflects its actual phase")
            alert.sheetParent?.endSheet(alert, returnCode: .alertSecondButtonReturn)
            await wait { decisions.count == 2 }
            XCTAssertEqual(decisions, [true, true])
            XCTAssertTrue(fixture.submission.needsCloseProtection, "Preflight consent cannot resolve recovered text")
            XCTAssertEqual(fixture.submission.recoveryContent, fixture.exact)
            XCTAssertTrue(fixture.session.requestCloseDecision { decisions.append($0) })
            let fresh = try await self.alert("GitX.PullRequest.Recovery.WindowCloseConfirmation", on: fixture)
            fresh.sheetParent?.endSheet(fresh, returnCode: .alertFirstButtonReturn)
            await wait { decisions.count == 3 }
            XCTAssertEqual(decisions, [true, true, false])
        }
    }

    func testNativeSessionRevocationSettlesPendingConsentOnceAndSuppressesStaleReplies() async throws {
        let fixture = try await fixture()
        var decisions: [Bool] = []
        XCTAssertTrue(fixture.session.requestCloseDecision { decisions.append($0) })
        let old = try await alert("GitX.PullRequest.Recovery.WindowCloseConfirmation", on: fixture)
        fixture.owner.current = false
        fixture.session.invalidateAttachedPresentation()
        XCTAssertEqual(decisions, [false])
        old.sheetParent?.endSheet(old, returnCode: .alertSecondButtonReturn)
        await wait { old.sheetParent == nil }
        XCTAssertEqual(decisions, [false])
        XCTAssertTrue(fixture.submission.needsCloseProtection)
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
    }

    func testMenuQuitEndsASavedRecoverySheetBeforeForwardingToAppKit() async throws {
        let fixture = try await fixture()
        try await fixture.store.save(identity: fixture.identity, content: fixture.exact, at: .now)
        fixture.sheet.markRecoverySaved(fixture.exact)
        XCTAssertTrue(fixture.session.protectionState.isEmpty)
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
        XCTAssertTrue(fixture.sheet.window?.isVisible == true, "Saved recovery remains available for further editing")
        fixture.session.attachedCloseDecision = { _ in
            XCTFail("Already saved recovery must not need discard consent"); return false
        }
        let forwarded = expectation(description: "AppKit receives Quit after presentation teardown")
        let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), remoteDecision: { .terminateNow }, remoteCancelled: {
            XCTFail("Saved recovery cannot cancel Quit")
        }, terminate: {
            XCTAssertFalse(fixture.sheet.window?.isVisible == true, "AppKit waits for an attached sheet before consulting its delegate")
            forwarded.fulfill()
        }, reply: { _ in XCTFail("Menu preflight must forward instead of replying") })
        coordinator.requestTermination()
        await fulfillment(of: [forwarded], timeout: 5)
        let stored = try await fixture.store.load(identity: fixture.identity)
        XCTAssertEqual(stored?.content, fixture.exact)
        XCTAssertTrue(fixture.parent.isVisible, "The coordinator closes presentation before AppKit owns document teardown")
    }

    func testCancelledMenuQuitRestoresTheSuspendedRecoveryAndItsFirstResponder() async throws {
        let fixture = try await fixture()
        let window = try XCTUnwrap(fixture.sheet.window)
        let body = try XCTUnwrap(find("GitX.PullRequest.Body", in: window.contentView) as? NSTextView)
        XCTAssertTrue(window.makeFirstResponder(body))
        fixture.session.attachedCloseDecision = { completion in completion(true); return true }
        let forwarded = expectation(description: "AppKit receives the approved Quit request")
        let coordinator = GitX.RepositoryTerminationCoordinator(
            mutations: GitX.RepositoryLocalMutationRegistry(),
            sessions: { [fixture.session] },
            remoteDecision: { .terminateNow },
            remoteCancelled: {},
            terminate: { forwarded.fulfill() },
            reply: { _ in XCTFail("The AppKit delegate has not started termination") }
        )
        let protected = fixture.session.protectionState
        coordinator.requestTermination()
        await fulfillment(of: [forwarded], timeout: 5)
        XCTAssertNil(window.sheetParent)
        XCTAssertEqual(fixture.session.protectionState, protected)

        coordinator.cancelPendingQuit()
        await wait { fixture.parent.attachedSheet === window }
        XCTAssertTrue(window.firstResponder === body)
        XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
        XCTAssertEqual(fixture.session.protectionState, protected)
    }

    func testNativeRegistrySynchronizesFurtherVisibleTextAfterARecoveryWasSaved() async throws {
        let fixture = try await fixture()
        try await fixture.store.save(identity: fixture.identity, content: fixture.exact, at: .now)
        fixture.sheet.markRecoverySaved(fixture.exact)
        XCTAssertTrue(fixture.submission.canRetire)
        XCTAssertTrue(fixture.session.submissions.isEmpty)
        XCTAssertTrue(fixture.sheet.window?.isVisible == true)
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
        let saved = try await fixture.store.load(identity: fixture.identity)
        XCTAssertEqual(saved?.content, fixture.exact)
        let body = try XCTUnwrap(find("GitX.PullRequest.Body", in: fixture.sheet.window?.contentView) as? NSTextView)
        body.string = "Further exact unsaved text"
        let protected = GitX.RepositoryPullRequestRecoverySession.protectedSessions
        XCTAssertTrue(protected.contains { $0 === fixture.session })
        XCTAssertEqual(fixture.session.protectionState.first?.content.body, body.string)
        XCTAssertTrue(fixture.submission.needsCloseProtection)
        XCTAssertTrue(fixture.session.submissions.first === fixture.submission)
    }

    func testNativeRecoveryLoadAndWriteFailuresPreserveTheExactTextAndStoredDraft() async throws {
        for failsWhileLoading in [true, false] {
            let fixture = try await fixture()
            let original = try await fixture.store.load(identity: fixture.identity)
            await fixture.store.failLoads(failsWhileLoading)
            try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
            if !failsWhileLoading {
                let consent = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
                await fixture.store.failSaves(true)
                consent.sheetParent?.endSheet(consent, returnCode: .alertFirstButtonReturn)
            }
            let error = try await alert("GitX.PullRequest.Recovery.SaveError", on: fixture)
            XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
            XCTAssertTrue(fixture.submission.needsRecovery)
            await fixture.store.failLoads(false)
            let stored = try await fixture.store.load(identity: fixture.identity)
            XCTAssertEqual(stored, original)
            error.sheetParent?.endSheet(error, returnCode: .alertFirstButtonReturn)
        }
    }

    func testNativeConditionalRecoverySavePreservesAConcurrentDraft() async throws {
        let fixture = try await fixture()
        try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
        let consent = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
        let newer = ForgeDraftContent(title: "Concurrent draft", body: "Another editor owns these bytes")
        try await fixture.store.save(identity: fixture.identity, content: newer, at: .distantFuture)
        consent.sheetParent?.endSheet(consent, returnCode: .alertFirstButtonReturn)
        let error = try await alert("GitX.PullRequest.Recovery.SaveError", on: fixture)
        let stored = try await fixture.store.load(identity: fixture.identity)
        XCTAssertEqual(stored?.content, newer)
        XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
        error.sheetParent?.endSheet(error, returnCode: .alertFirstButtonReturn)
    }

    func testNativeOwnerRevocationCancelsUncommittedLoadingAndConsentWithoutWriting() async throws {
        for duringLoad in [true, false] {
            let fixture = try await fixture()
            let started = XCTestExpectation(description: "Recovery load starts")
            if duringLoad {
                await fixture.store.holdNextLoad(fixture.loadGate, started: started)
            }
            try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
            if duringLoad {
                await fulfillment(of: [started], timeout: 5)
            } else {
                _ = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
            }
            fixture.owner.current = false
            fixture.session.invalidateAttachedPresentation()
            fixture.sheet.invalidatePresentation()
            await fixture.loadGate.release(true)
            await fixture.session.queue.tail?.value
            let writes = await fixture.store.conditionalSaves
            XCTAssertEqual(writes, 0)
            XCTAssertFalse(fixture.sheet.window?.isVisible == true)
        }
    }

    func testNativeAdmittedSaveFinishesAfterActualRevocationWithoutLatePresentation() async throws {
        let fixture = try await fixture()
        let started = expectation(description: "Conditional write is admitted")
        await fixture.store.holdNextConditionalSave(fixture.writeGate, started: started)
        try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
        let consent = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
        consent.sheetParent?.endSheet(consent, returnCode: .alertFirstButtonReturn)
        await fulfillment(of: [started], timeout: 5)
        var preflight: [Bool] = []
        XCTAssertTrue(fixture.session.requestCloseDecision { preflight.append($0) })
        let close = try await alert("GitX.PullRequest.Recovery.WindowCloseConfirmation", on: fixture)
        close.sheetParent?.endSheet(close, returnCode: .alertSecondButtonReturn)
        await wait { preflight == [true] }
        XCTAssertTrue(fixture.sheet.window?.isVisible == true)
        fixture.owner.current = false
        fixture.session.invalidateAttachedPresentation()
        fixture.sheet.invalidatePresentation()
        await fixture.writeGate.release(true)
        await fixture.session.queue.tail?.value
        let stored = try await fixture.store.load(identity: fixture.identity)
        XCTAssertEqual(stored?.content, fixture.exact)
        XCTAssertFalse(fixture.sheet.window?.isVisible == true)
        XCTAssertNil(fixture.parent.attachedSheet)
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
    }

    func testNativeRecoverySaveMarksOnlyItsCapturedTextAndProtectsFurtherEditing() async throws {
        let fixture = try await fixture()
        let started = expectation(description: "Captured recovery write is admitted")
        await fixture.store.holdNextConditionalSave(fixture.writeGate, started: started)
        try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
        let consent = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
        consent.sheetParent?.endSheet(consent, returnCode: .alertFirstButtonReturn)
        await fulfillment(of: [started], timeout: 5)
        let body = try XCTUnwrap(find("GitX.PullRequest.Body", in: fixture.sheet.window?.contentView) as? NSTextView)
        body.string = "Further exact text typed while the captured write is running"
        fixture.sheet.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        await fixture.writeGate.release(true)
        await wait { (self.find("GitX.PullRequest.Recovery.Notice", in: fixture.sheet.window?.contentView) as? NSTextField)?.stringValue.hasPrefix("Saved as a draft") == true }
        let stored = try await fixture.store.load(identity: fixture.identity)
        XCTAssertEqual(stored?.content, fixture.exact)
        XCTAssertEqual(fixture.submission.recoveryContent.body, body.string)
        XCTAssertTrue(fixture.submission.needsRecovery)
        XCTAssertEqual(fixture.session.submissions.count, 1)
        try button("GitX.PullRequest.Recovery.Close", fixture: fixture).performClick(nil)
        let close = try await alert("GitX.PullRequest.Recovery.CloseConfirmation", on: fixture)
        close.sheetParent?.endSheet(close, returnCode: .alertFirstButtonReturn)
        await wait { close.sheetParent == nil }
        XCTAssertTrue(fixture.sheet.window?.isVisible == true)
        XCTAssertEqual(fixture.session.protectionState.first?.content.body, body.string)
    }

    func testStandalonePendingSessionProtectsItsPlaceholderAndSuppressesLateRecoveryAfterDiscard() async throws {
        let fixture = try await fixture(pending: true, presented: false)
        fixture.session.detach(presented: [])
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery.Waiting" })
        panel.performClose(nil)
        await wait { panel.attachedSheet != nil }
        let first = try XCTUnwrap(panel.attachedSheet)
        try attachScreenshot(of: first, named: "Detached pending submission requires explicit discard")
        first.sheetParent?.endSheet(first, returnCode: .alertFirstButtonReturn)
        await wait { panel.attachedSheet == nil }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(fixture.submission.needsCloseProtection)
        panel.performClose(nil)
        await wait { panel.attachedSheet != nil }
        let second = try XCTUnwrap(panel.attachedSheet)
        second.sheetParent?.endSheet(second, returnCode: .alertSecondButtonReturn)
        await wait { !panel.isVisible }
        XCTAssertFalse(fixture.submission.needsCloseProtection)
        fixture.submission.finish()
        fixture.session.didSettle()
        XCTAssertTrue(fixture.session.submissions.isEmpty)
        XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery" })
    }

    func testDetachedCompletionSettlesOldPlaceholderConsentBeforePresentingRecovery() async throws {
        let fixture = try await fixture(pending: true, presented: false)
        fixture.session.detach(presented: [])
        let pending = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery.Waiting" })
        var decisions: [Bool] = []
        XCTAssertTrue(fixture.session.requestCloseDecision { decisions.append($0) })
        await wait { pending.attachedSheet != nil }
        let old = try XCTUnwrap(pending.attachedSheet)
        fixture.submission.finish()
        fixture.session.didSettle()
        await wait { decisions.count == 1 }
        XCTAssertEqual(decisions, [false], "The obsolete placeholder must not hold a termination attempt open")
        let recovered = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery" })
        let sheet = try XCTUnwrap(recovered.windowController as? GitX.ForgePullRequestSheetController)
        XCTAssertEqual(sheet.recoveryContentSnapshot, fixture.exact)
        XCTAssertTrue(fixture.submission.needsRecovery)
        old.sheetParent?.endSheet(old, returnCode: .alertSecondButtonReturn)
        XCTAssertEqual(decisions, [false])
        sheet.onCancel?(fixture.exact)
        sheet.invalidatePresentation()
    }

    func testKeepEditingDuringQuitPreservesRecoveryLoadingAndReplacementConsent() async throws {
        for duringLoad in [true, false] {
            let fixture = try await fixture()
            let loadStarted = duringLoad ? expectation(description: "Recovery load reaches its deterministic gate") : nil
            if let loadStarted {
                await fixture.store.holdNextLoad(fixture.loadGate, started: loadStarted)
            }
            try button("GitX.PullRequest.Recovery.SaveDraft", fixture: fixture).performClick(nil)
            if let loadStarted {
                await fulfillment(of: [loadStarted], timeout: 5)
            } else {
                _ = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
            }
            var replies: [Bool] = []
            let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [fixture.session] }, remoteDecision: {
                XCTFail("Keep Editing must cancel Quit before the remote decision"); return .terminateNow
            }, remoteCancelled: {}, reply: { replies.append($0) })
            XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
            let consent = try await alert("GitX.PullRequest.Recovery.WindowCloseConfirmation", on: fixture)
            if duringLoad {
                await fixture.loadGate.release(true)
            }
            consent.sheetParent?.endSheet(consent, returnCode: .alertFirstButtonReturn)
            await wait { replies == [false] }
            XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
            let replacement = try await alert("GitX.PullRequest.Recovery.ReplaceConfirmation", on: fixture)
            replacement.sheetParent?.endSheet(replacement, returnCode: .alertFirstButtonReturn)
            await wait { !fixture.submission.needsCloseProtection }
            let saved = try await fixture.store.load(identity: fixture.identity)
            let writes = await fixture.store.conditionalSaves
            XCTAssertEqual(saved?.content, fixture.exact)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(replies, [false])
        }
    }

    func testFinalAcceptedQuitDiscardsAttachedAndDetachedRecoveryOnlyAtItsReply() async throws {
        for detached in [false, true] {
            let fixture = try await fixture()
            let original = try await fixture.store.load(identity: fixture.identity)
            if detached {
                fixture.session.detach(presented: [(fixture.submission, fixture.sheet)])
            }
            let panel = try XCTUnwrap(fixture.sheet.window)
            let replied = expectation(description: "Every guard agrees before recovery is discarded")
            let coordinator = GitX.RepositoryTerminationCoordinator(mutations: GitX.RepositoryLocalMutationRegistry(), sessions: { [fixture.session] }, remoteDecision: {
                XCTAssertTrue(panel.isVisible)
                XCTAssertTrue(fixture.submission.needsCloseProtection)
                XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
                return .terminateNow
            }, remoteCancelled: {}, reply: { allowed in
                XCTAssertTrue(allowed)
                XCTAssertFalse(panel.isVisible)
                XCTAssertTrue(fixture.session.submissions.isEmpty)
                replied.fulfill()
            })
            XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateLater)
            await wait { panel.attachedSheet?.accessibilityIdentifier() == "GitX.PullRequest.Recovery.WindowCloseConfirmation" }
            XCTAssertEqual(fixture.sheet.recoveryContentSnapshot, fixture.exact)
            let consent = try XCTUnwrap(panel.attachedSheet)
            consent.sheetParent?.endSheet(consent, returnCode: .alertSecondButtonReturn)
            await fulfillment(of: [replied], timeout: 5)
            let stored = try await fixture.store.load(identity: fixture.identity)
            XCTAssertEqual(stored, original)
            XCTAssertFalse(GitX.RepositoryPullRequestRecoverySession.protectedSessions.contains { $0 === fixture.session })
        }
    }

    private func button(_ identifier: String, fixture: Fixture) throws -> NSButton {
        try XCTUnwrap(find(identifier, in: fixture.sheet.window?.contentView) as? NSButton)
    }

    private func alert(_ identifier: String, on fixture: Fixture) async throws -> NSWindow {
        var result: NSWindow?
        await wait {
            var window: NSWindow? = fixture.parent
            while let candidate = window {
                if candidate.accessibilityIdentifier() == identifier {
                    result = candidate; return true
                }
                window = candidate.attachedSheet
            }
            return false
        }
        return try XCTUnwrap(result)
    }

    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func find(_ identifier: String, in view: NSView?) -> NSView? {
        descendants(view).first { $0.accessibilityIdentifier() == identifier }
    }
}
