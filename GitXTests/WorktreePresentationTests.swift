import AppKit
import GitXCore
import XCTest

#if DEBUG
    @MainActor
    final class WorktreePresentationTests: XCTestCase {
        private var beforeGitPreferenceRestoration: (@MainActor () -> Void)?
        private var gitPreferenceRestoration: GitPreferenceRestoration?
        private var drainedFixtures: [Fixture] = []

        func testExternalBranchChangeRejectsNormalAndForcedRemovalConsent() async throws {
            for force in [false, true] {
                selectGit()
                let fixture = try makeFixture()
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let dirty = fixture.linked.appendingPathComponent("untracked.txt")
                let content = Data("keep uncommitted work after changed consent\n".utf8)
                try content.write(to: dirty)
                let origin = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                controller.presentsErrors = true
                let window = try XCTUnwrap(controller.window)
                await activateWorktreeTestApplication()
                window.makeKeyAndOrderFront(nil)
                defer {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    controller.close()
                }
                await waitUntil { NSApp.isActive && window.isKeyWindow }
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let item = NSMenuItem(); item.representedObject = tree
                controller.removeWorktree(item)
                var consent = try await waitForSheet(in: window, containing: "Remove")
                if force {
                    window.endSheet(consent, returnCode: .alertFirstButtonReturn)
                    consent = try await waitForSheet(in: window, containing: "Remove Anyway")
                }
                _ = try fixture.git(["switch", "-c", "replacement"], in: fixture.linked)
                let proof = try fixture.ownershipProof()
                window.endSheet(consent, returnCode: .alertFirstButtonReturn)
                await waitUntil { controller.errors.count == 1 && window.attachedSheet != nil }
                let error = try XCTUnwrap(controller.errors.first)
                XCTAssertTrue(error.localizedFailureReason?.contains("Review the refreshed worktree list") == true)
                let rejected = try XCTUnwrap(window.attachedSheet)
                XCTAssertTrue(sheetText(rejected).contains("Review the refreshed worktree list"))
                XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", "--force", tree.path]))
                XCTAssertEqual(origin.gate.commands.filter { $0 == ["worktree", "remove", tree.path] }.count, force ? 1 : 0)
                XCTAssertEqual(origin.service.worktree(forBranch: "refs/heads/replacement")?.path, tree.path)
                XCTAssertEqual(try fixture.ownershipProof(), proof)
                XCTAssertEqual(try Data(contentsOf: dirty), content)
                try attachScreenshot(of: rejected, named: force ? "Worktrees-Forced-Removal-Changed-Consent-Rejected" : "Worktrees-Removal-Changed-Consent-Rejected")
            }
        }

        func testExternalHeadChangeRejectsNormalAndForcedRemovalConsent() async throws {
            for force in [false, true] {
                selectGit()
                let fixture = try makeFixture()
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let dirty = fixture.linked.appendingPathComponent("untracked.txt")
                let content = Data("keep uncommitted work after changed consent\n".utf8)
                try content.write(to: dirty)
                let origin = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                controller.presentsErrors = true
                let window = try XCTUnwrap(controller.window)
                await activateWorktreeTestApplication()
                window.makeKeyAndOrderFront(nil)
                defer {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    controller.close()
                }
                await waitUntil { NSApp.isActive && window.isKeyWindow }
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let item = NSMenuItem(); item.representedObject = tree
                controller.removeWorktree(item)
                var consent = try await waitForSheet(in: window, containing: "Remove")
                if force {
                    window.endSheet(consent, returnCode: .alertFirstButtonReturn)
                    consent = try await waitForSheet(in: window, containing: "Remove Anyway")
                }
                _ = try fixture.git(["commit", "--allow-empty", "-m", "External commit after approval"], in: fixture.linked)
                let proof = try fixture.ownershipProof()
                window.endSheet(consent, returnCode: .alertFirstButtonReturn)
                await waitUntil { controller.errors.count == 1 && window.attachedSheet != nil }
                let error = try XCTUnwrap(controller.errors.first)
                XCTAssertTrue(error.localizedFailureReason?.contains("Review the refreshed worktree list") == true)
                let rejected = try XCTUnwrap(window.attachedSheet)
                XCTAssertTrue(sheetText(rejected).contains("Review the refreshed worktree list"))
                XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", "--force", tree.path]))
                XCTAssertEqual(origin.gate.commands.filter { $0 == ["worktree", "remove", tree.path] }.count, force ? 1 : 0)
                XCTAssertEqual(origin.service.worktree(forBranch: "refs/heads/topic")?.path, tree.path)
                XCTAssertEqual(try fixture.ownershipProof(), proof)
                XCTAssertEqual(try Data(contentsOf: dirty), content)
                try attachScreenshot(of: rejected, named: force ? "Worktrees-Forced-Removal-Changed-HEAD-Rejected" : "Worktrees-Removal-Changed-HEAD-Rejected")
            }
        }

        func testFixtureCleanupDrainsHeldDiscoveryBeforeRestoringGitPreferences() async throws {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "gitExecutable") as? NSObject
            var restorationCount = 0
            addTeardownBlock { @MainActor in
                XCTAssertEqual(restorationCount, 1)
                XCTAssertEqual(defaults.object(forKey: "gitExecutable") as? NSObject, previous)
            }
            selectGit()
            let fixture = try makeFixture()
            let origin = try await installService(in: fixture)
            let checkpoint = WorktreeWorkerCheckpoint()
            defer { checkpoint.resume() }
            origin.service.discoveryEvidenceObserver = { checkpoint.wait() }
            origin.service.refresh()
            await fulfillment(of: [checkpoint.entered], timeout: 5)
            XCTAssertTrue(checkpoint.isWaiting)
            var cleanupStarted = false
            var cleanupFinished = false
            beforeGitPreferenceRestoration = {
                restorationCount += 1
                XCTAssertTrue(cleanupFinished, "Preference restoration must follow the worker's main-actor acknowledgement")
                XCTAssertFalse(checkpoint.isWaiting)
                XCTAssertTrue(checkpoint.wasReleased)
                XCTAssertFalse(checkpoint.didTimeout)
            }
            let cleanup = Task { @MainActor in
                cleanupStarted = true
                let succeeded = await self.cleanupFixture(fixture)
                cleanupFinished = true
                return succeeded
            }
            await waitUntil { cleanupStarted }
            await drainCallbacks()
            XCTAssertFalse(cleanupFinished, "Cancellation alone must not make a held worker appear drained")
            XCTAssertEqual(restorationCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
            checkpoint.resume()
            let succeeded = await cleanup.value
            XCTAssertTrue(succeeded)
            XCTAssertFalse(checkpoint.didTimeout)
        }

        func testFixtureTeardownRestoresGitOnceBeforeRemovingAllDrainedFixtures() async throws {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "gitExecutable") as? NSObject
            var restorationCount = 0
            var fixtureRoots: [URL] = []
            addTeardownBlock { @MainActor in
                XCTAssertEqual(restorationCount, 1, "One test restores its original preference once, even when setup helpers select Git repeatedly")
                XCTAssertEqual(defaults.object(forKey: "gitExecutable") as? NSObject, previous)
                XCTAssertEqual(fixtureRoots.count, 2)
                for root in fixtureRoots {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "A drained fixture is deleted after preference restoration")
                }
            }
            selectGit()
            let first = try makeFixture()
            fixtureRoots.append(first.root)
            _ = try await installService(in: first)
            selectGit()
            let second = try makeFixture()
            fixtureRoots.append(second.root)
            _ = try await installService(in: second)
            beforeGitPreferenceRestoration = {
                restorationCount += 1
                for fixture in [first, second] {
                    XCTAssertTrue(fixture.services.isEmpty && fixture.retiredServices.isEmpty, "All fixture services must drain before any preference restoration")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path), "Fixture files must outlive preference restoration")
                }
            }
        }

        #if DEBUG
            @MainActor
            private final class QueueOwnerState { var current = true }

            func testQueuedPresentationPreservesAnotherKeyWindowUntilTheUserReturns() async throws {
                let queue = PBWorktreePresentationQueueTestHarness()
                let owner = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                let foreground = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                owner.title = "Pending worktree result"
                foreground.title = "Foreground window stays active"
                let message = NSTextField(wrappingLabelWithString: "Foreground window stays active\n\nThe worktree result waits for its original window. No sheet has taken focus.")
                message.frame = NSRect(x: 24, y: 40, width: 312, height: 120)
                foreground.contentView?.addSubview(message)
                owner.isReleasedWhenClosed = false
                foreground.isReleasedWhenClosed = false
                defer { queue.invalidate(); foreground.close(); owner.close() }
                await activateWorktreeTestApplication()
                owner.makeKeyAndOrderFront(nil)
                foreground.makeKeyAndOrderFront(nil)
                await waitUntil { NSApp.isActive && foreground.isKeyWindow }
                let alert = NSAlert()
                alert.messageText = "Deferred worktree result"
                alert.addButton(withTitle: "OK")
                var preparations = 0
                var presentations = 0
                queue.enqueue(window: owner, ownerIsCurrent: { true }, prepare: { ready in
                    preparations += 1
                    ready(.init(finishesWhenSheetEnds: true, present: { _ in
                        presentations += 1
                        alert.beginSheetModal(for: owner) { _ in }
                    }, discard: {}))
                }, discard: {})
                await drainCallbacks()
                XCTAssertTrue(foreground.isKeyWindow)
                XCTAssertEqual(preparations, 0)
                XCTAssertEqual(presentations, 0)
                XCTAssertTrue(queue.hasPendingPresentations)
                try attachScreenshot(of: XCTUnwrap(foreground.contentView?.superview), named: "Worktrees-Pending-Result-Preserves-Foreground")
                owner.makeKeyAndOrderFront(nil)
                await waitUntil { owner.attachedSheet === alert.window }
                XCTAssertEqual(preparations, 1)
                XCTAssertEqual(presentations, 1)
                owner.endSheet(alert.window, returnCode: .OK)
                await waitUntil { !queue.hasPendingPresentations }
                XCTAssertEqual(presentations, 1)
            }

            func testPresentationQueueRevalidatesFocusLossAndReturnDuringPreparation() async {
                let queue = PBWorktreePresentationQueueTestHarness()
                let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                owner.isReleasedWhenClosed = false
                other.isReleasedWhenClosed = false
                defer { queue.invalidate(); other.close(); owner.close() }
                await activateWorktreeTestApplication()
                owner.makeKeyAndOrderFront(nil)
                await waitUntil { NSApp.isActive && owner.isKeyWindow }
                var preparations = 0
                var presented: [Int] = []
                var discarded = 0
                queue.enqueue(window: owner, ownerIsCurrent: { true }, prepare: { ready in
                    preparations += 1
                    let revision = preparations
                    if revision == 1 {
                        other.makeKeyAndOrderFront(nil)
                        XCTAssertTrue(other.isKeyWindow)
                        owner.makeKeyAndOrderFront(nil)
                        XCTAssertTrue(owner.isKeyWindow)
                    }
                    ready(.init(finishesWhenSheetEnds: false, present: { done in
                        presented.append(revision); done()
                    }, discard: { discarded += 1 }))
                }, discard: {})
                await waitUntil { !queue.hasPendingPresentations }
                XCTAssertEqual(preparations, 2, "A brief focus loss during preparation requires fresh evidence even when the owner returns before the queued flush")
                XCTAssertEqual(presented, [2])
                XCTAssertEqual(discarded, 2)
            }

            func testPresentationQueueDiscardsLatePreparationAfterOwnerRevocation() async throws {
                for invalidatesQueue in [false, true] {
                    let queue = PBWorktreePresentationQueueTestHarness()
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    await activateWorktreeTestApplication()
                    window.makeKeyAndOrderFront(nil)
                    defer { queue.invalidate(); window.close() }
                    let owner = QueueOwnerState()
                    var ready: (@MainActor (PBWorktreePreparedPresentationTestValue?) -> Void)?
                    var discarded = 0
                    var presented = 0
                    var retired = 0
                    queue.enqueue(window: window, ownerIsCurrent: { owner.current }, prepare: { ready = $0 }, discard: { retired += 1 })
                    await waitUntil { ready != nil }
                    let delivery = try XCTUnwrap(ready)
                    owner.current = false
                    if invalidatesQueue {
                        queue.invalidate()
                    }
                    delivery(.init(finishesWhenSheetEnds: false, present: { _ in presented += 1 }, discard: { discarded += 1 }))
                    await waitUntil { !queue.hasPendingPresentations }
                    XCTAssertEqual(presented, 0)
                    XCTAssertEqual(discarded, 1, "A late prepared result relinquishes its single-use authority exactly once")
                    XCTAssertEqual(retired, 1)
                    XCTAssertNil(window.attachedSheet)
                }
            }

            func testPresentationQueueRevokesPreparedAndPendingOwnersBehindANewSheet() async throws {
                let queue = PBWorktreePresentationQueueTestHarness()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                await activateWorktreeTestApplication()
                window.makeKeyAndOrderFront(nil)
                defer { queue.invalidate(); window.close() }
                let owner = QueueOwnerState()
                var ready: (@MainActor (PBWorktreePreparedPresentationTestValue?) -> Void)?
                var discarded = 0
                var presented = 0
                var retired = 0
                queue.enqueue(window: window, ownerIsCurrent: { owner.current }, prepare: { ready = $0 }, discard: { retired += 1 })
                queue.enqueue(window: window, ownerIsCurrent: { false }, prepare: { _ in XCTFail("An expired pending owner must not prepare") }, discard: { retired += 1 })
                await waitUntil { ready != nil }
                let occupant = unrelatedSheet(on: window)
                try XCTUnwrap(ready)(.init(finishesWhenSheetEnds: false, present: { _ in presented += 1 }, discard: { discarded += 1 }))
                await drainCallbacks()
                XCTAssertTrue(queue.hasPendingPresentations)
                XCTAssertTrue(window.attachedSheet === occupant.window)
                owner.current = false
                window.endSheet(occupant.window, returnCode: .cancel)
                await waitUntil { !queue.hasPendingPresentations && window.attachedSheet == nil }
                XCTAssertEqual(presented, 0)
                XCTAssertEqual(discarded, 1)
                XCTAssertEqual(retired, 2)
            }

            func testPresentationQueueInvalidationEndsItsOwnPresentedSheetExactlyOnce() async {
                let queue = PBWorktreePresentationQueueTestHarness()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                await activateWorktreeTestApplication()
                window.makeKeyAndOrderFront(nil)
                defer { queue.invalidate(); window.close() }
                let alert = NSAlert()
                alert.messageText = "Owner-scoped diagnostic presentation"
                alert.addButton(withTitle: "Cancel")
                var responses: [NSApplication.ModalResponse] = []
                var discarded = 0
                queue.enqueue(window: window, ownerIsCurrent: { true }, prepare: { ready in
                    ready(.init(finishesWhenSheetEnds: false, present: { done in
                        alert.beginSheetModal(for: window) { response in responses.append(response); done() }
                    }, discard: { discarded += 1 }))
                }, discard: {})
                await waitUntil { window.attachedSheet === alert.window }
                queue.invalidate()
                await waitUntil { responses.count == 1 && window.attachedSheet == nil }
                XCTAssertEqual(responses, [.cancel])
                XCTAssertEqual(discarded, 1)
                XCTAssertFalse(queue.hasPendingPresentations)
            }

            func testSwiftLocateCompletesOrRejectsChangedFinalEvidenceWithoutLosingAdmission() async throws {
                selectGit()
                for changesEvidence in [false, true] {
                    let journey = try await movedRepairJourney()
                    let service = journey.origin.service
                    let tree = try XCTUnwrap(service.worktree(forBranch: "refs/heads/topic"))
                    journey.window.endSheet(journey.style, returnCode: .alertThirdButtonReturn)
                    await waitUntil { journey.window.attachedSheet == nil }
                    let checkpoint = WorktreeWorkerCheckpoint()
                    if changesEvidence {
                        service.repairValidationObserver = { checkpoint.wait() }
                        service.repairValidationResultObserver = { checkpoint.finish() }
                        checkpoint.expectResult()
                    }
                    addTeardownBlock { @MainActor in
                        checkpoint.resume()
                        if checkpoint.expectsResult {
                            await self.fulfillment(of: [checkpoint.finishedExpectation()], timeout: 15)
                        }
                        await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
                    }
                    let done = expectation(description: "Swift Locate delivers its terminal result")
                    var completed = 0
                    var failure: NSError?
                    service.beginRepairForTesting(worktree: tree, movedTo: journey.fixture.linked.path, relativePaths: false, ownerIsCurrent: { true }) { preview, succeeded, error in
                        XCTAssertNil(preview, "A proven moved checkout requires no additional consent")
                        if succeeded {
                            completed += 1
                        }
                        failure = error as NSError?
                        done.fulfill()
                    }
                    if changesEvidence {
                        await fulfillment(of: [checkpoint.entered], timeout: 5)
                        try Data("foreign link must survive final validation\n".utf8).write(to: journey.fixture.linked.appendingPathComponent(".git"))
                        checkpoint.resume()
                    }
                    await fulfillment(of: [done], timeout: 15)
                    if changesEvidence {
                        XCTAssertNotNil(failure)
                        XCTAssertEqual(completed, 0)
                        XCTAssertFalse(journey.origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                        XCTAssertEqual(try String(contentsOf: journey.fixture.linked.appendingPathComponent(".git"), encoding: .utf8), "foreign link must survive final validation\n")
                    } else {
                        XCTAssertNil(failure)
                        XCTAssertEqual(completed, 1)
                        try assertRepairedJourney(journey, relative: false)
                    }
                    try await assertFollowingPreviewProgresses(journey)
                }
            }

            func testReadOnlyRepairPreviewRejectsRevokedAndConsumedTokensWithoutWriting() async throws {
                selectGit()
                for revokesAfterRequest in [false, true] {
                    let fixture = try makeFixture()
                    let origin = try await installService(in: fixture)
                    let service = origin.service
                    try FileManager.default.removeItem(at: fixture.linked.appendingPathComponent(".git"))
                    service.refresh()
                    await waitUntil { service.worktrees.contains { $0.hasBrokenLink } }
                    let requested = expectation(description: "Swift repair releases admission for consent")
                    var captured: PBWorktreeRepairPreview?
                    service.beginRepairForTesting(worktree: nil, movedTo: nil, relativePaths: false, ownerIsCurrent: { true }) { preview, completed, error in
                        XCTAssertNil(error)
                        XCTAssertFalse(completed)
                        captured = preview
                        requested.fulfill()
                    }
                    await fulfillment(of: [requested], timeout: 15)
                    let original = try XCTUnwrap(captured)
                    let refreshed = expectation(description: "read-only refresh replaces its single-use token without writing")
                    service.refreshRepairPreviewForTesting(original, ownerIsCurrent: { true }) { preview, changed, error in
                        XCTAssertNil(error)
                        XCTAssertFalse(changed)
                        XCTAssertNotNil(preview)
                        captured = preview
                        refreshed.fulfill()
                    }
                    await fulfillment(of: [refreshed], timeout: 15)
                    let preview = try XCTUnwrap(captured)
                    let owner = QueueOwnerState()
                    XCTAssertFalse(preview === original)
                    for current in [false, true] {
                        let holdsRead = !current && revokesAfterRequest
                        let arguments = ["worktree", "list", "--porcelain", "-z"]
                        let heldOutput = holdsRead ? try Data(fixture.git(arguments).utf8) : nil
                        if holdsRead {
                            origin.gate.holdNextArguments = arguments
                        }
                        owner.current = current || revokesAfterRequest
                        let rejected = expectation(description: current ? "consumed preview is rejected" : "revoked owner is cancelled")
                        service.refreshRepairPreviewForTesting(preview, ownerIsCurrent: { owner.current }) { renewed, _, error in
                            XCTAssertNil(renewed)
                            guard let error else { XCTFail("Revoked and consumed tokens must not refresh"); rejected.fulfill(); return }
                            if current {
                                XCTAssertTrue((error as NSError).localizedFailureReason?.contains("consumed") == true)
                            } else {
                                XCTAssertTrue(WorktreePresentationPolicy.isExpectedCancellation(error as NSError))
                            }
                            rejected.fulfill()
                        }
                        if holdsRead {
                            // Entry accepted this owner; revoke it before the held discovery can deliver.
                            owner.current = false
                            await waitUntil { origin.gate.writer.isPending }
                            try origin.gate.writer.finish(XCTUnwrap(heldOutput))
                        }
                        await fulfillment(of: [rejected], timeout: 15)
                    }
                    let following = expectation(description: "a fresh consent request progresses after owner revocation")
                    service.beginRepairForTesting(worktree: nil, movedTo: nil, relativePaths: false, ownerIsCurrent: { true }) { renewed, completed, error in
                        XCTAssertNil(error)
                        XCTAssertFalse(completed)
                        XCTAssertNotNil(renewed)
                        if let renewed {
                            service.discardRepairPreview(renewed)
                        }
                        following.fulfill()
                    }
                    await fulfillment(of: [following], timeout: 15)
                    XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.appendingPathComponent(".git").path))
                }
            }

        #endif

        func testQueuedGenericGitFailureIsPresentedInItsLiveOriginWindowAndReleasesSharedFIFO() async throws {
            selectGit()
            let fixture = try makeFixture()
            let blocker = try await installService(in: fixture, holdsWriter: true)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = RecordingWindowController()
            controller.repository = origin.repository
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let initial = try fixture.ownershipProof()
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            XCTAssertTrue(tree.isLocked)
            let item = NSMenuItem()
            item.representedObject = tree
            let blockerCompleted = expectation(description: "controlled writer released")
            let followingCompleted = expectation(description: "following real writer reconciled")
            enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in
                XCTAssertNil(error)
                blockerCompleted.fulfill()
            }
            XCTAssertTrue(blocker.gate.writer.isPending)
            XCTAssertFalse(blocker.gate.writer.wasCancelled)
            controller.unlockWorktree(item)
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                XCTAssertNil(error)
                followingCompleted.fulfill()
            }
            XCTAssertFalse(origin.gate.commands.contains(["worktree", "unlock", tree.path]))
            XCTAssertNil(window.attachedSheet)
            // Admission used the captured locked row. A competing real Git command
            // removes that lock while the UI mutation is waiting behind the writer.
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            blocker.gate.writer.finish(Data())
            await fulfillment(of: [blockerCompleted, followingCompleted], timeout: 15)
            await waitUntil { controller.errors.count == 1 && window.attachedSheet != nil }
            let error = try XCTUnwrap(controller.errors.first)
            XCTAssertEqual(error.domain, "PBGitXErrorDomain")
            XCTAssertTrue(error.localizedFailureReason?.contains("not locked") == true, "Expected the real queued Git failure: \(error)")
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertTrue(sheetText(sheet).contains("not locked"))
            try attachScreenshot(of: sheet, named: "Worktrees-Live-Queued-Git-Failure")
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(following.service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
            XCTAssertTrue(following.service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
            XCTAssertEqual(origin.gate.commands.filter { $0 == ["worktree", "unlock", tree.path] }.count, 1)
            XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "lock", "--reason", "following", fixture.linked.path] }.count, 1)
            window.endSheet(sheet, returnCode: .OK)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(controller.errors.count, 1)
        }

        func testOwnerSettersAndObjectiveCWorktreeCallbacksDoNotLoadAnUnloadedWindow() {
            let controller = RecordingWindowController(windowNibName: "RepositoryWindow")
            controller.presentsErrors = false
            XCTAssertFalse(controller.isWindowLoaded)
            XCTAssertEqual(controller.loadWindowCount, 0)
            controller.window = nil
            controller.document = nil
            controller.repository = nil
            _ = controller.perform(NSSelectorFromString("windowDidBecomeMain:"), with: Notification(name: NSWindow.didBecomeMainNotification))
            _ = controller.perform(NSSelectorFromString("repairWorktreeLinks:"), with: nil)
            controller.addWorktree(nil)
            controller.pruneWorktrees(nil)
            _ = controller.perform(NSSelectorFromString("returnToHistory:"), with: nil)
            XCTAssertEqual(controller.loadWindowCount, 0)
            XCTAssertNil(controller.repository)
            XCTAssertEqual(controller.errors.count, 0)

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
            controller.window = window
            controller.window = window
            XCTAssertTrue(controller.window === window)
            let repository = PBGitRepository()
            let document = PBGitRepositoryDocument()
            document.setValue(repository, forKey: "repository")
            controller.document = document
            controller.document = document
            XCTAssertTrue(controller.document === document)
            controller.document = nil
            controller.document = nil
            var repositoryNotifications = 0
            let observation = controller.observe(\.repository) { _, _ in
                // swift6-safety-justification: This main-actor test invokes setters synchronously; KVO delivers their notifications on the same thread.
                MainActor.assumeIsolated { repositoryNotifications += 1 }
            }
            controller.repository = repository
            XCTAssertGreaterThan(repositoryNotifications, 0)
            controller.repository = repository
            XCTAssertTrue(controller.repository === repository)
            controller.repository = nil
            controller.repository = nil
            observation.invalidate()
            controller.window = nil
            controller.window = nil
            XCTAssertNil(controller.document)
            XCTAssertNil(controller.repository)
            XCTAssertEqual(controller.loadWindowCount, 0)
            window.close()

            // Prove this probe observes AppKit's actual lazy-load boundary.
            let positive = RecordingWindowController(windowNibName: "RepositoryWindow")
            XCTAssertFalse(positive.isWindowLoaded)
            XCTAssertEqual(positive.loadWindowCount, 0)
            positive.showWindow(nil)
            XCTAssertGreaterThan(positive.loadWindowCount, 0)
            positive.close()
        }

        func testUnchangedOwnersAndDocumentRepositoryPrecedenceKeepALiveGitFailurePresentable() async throws {
            selectGit()
            for usesDocument in [false, true] {
                let fixture = try makeFixture()
                let origin = try await installService(in: fixture)
                let alternative = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                let window = try XCTUnwrap(controller.window)
                let document = PBGitRepositoryDocument()
                // Use the existing Cocoa-owned repository slot without widening production API.
                document.setValue(origin.repository, forKey: "repository")
                if usesDocument {
                    controller.document = document
                }
                defer { controller.document = nil; controller.close() }
                let initial = try fixture.ownershipProof()
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let item = NSMenuItem(); item.representedObject = tree
                origin.gate.holdNextArguments = ["worktree", "unlock", tree.path]
                // The imported Objective-C callback surface must dispatch into the
                // Swift controller without new Swift-only virtual accessor slots.
                _ = controller.perform(NSSelectorFromString("unlockWorktree:"), with: item)
                await waitUntil { origin.gate.writer.isPending }
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let refused = try fixture.gitFailure(["worktree", "unlock", fixture.linked.path])
                controller.window = window
                controller.document = controller.document
                if usesDocument {
                    controller.repository = alternative.repository
                    XCTAssertTrue(controller.repository === origin.repository)
                }
                controller.repository = origin.repository
                let completed = expectation(description: "writer after current-owner error")
                enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                    XCTAssertNil(error); completed.fulfill()
                }
                origin.gate.writer.finish(refused.data, error: refused.error)
                await fulfillment(of: [completed], timeout: 15)
                XCTAssertEqual(controller.errors.count, 1)
                XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("not locked") == true)
                XCTAssertEqual(try fixture.ownershipProof(), initial)
                XCTAssertEqual(following.service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
            }
        }

        func testHeldGitFailureIsDiscardedWhenTheRepositoryServiceIsReplaced() async throws {
            selectGit()
            let fixture = try makeFixture()
            let origin = try await installService(in: fixture)
            let replacement = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer { origin.repository.setValue(origin.service, forKey: "worktreeService"); controller.close() }
            let initial = try fixture.ownershipProof()
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            origin.gate.holdNextArguments = ["worktree", "unlock", tree.path]
            controller.unlockWorktree(item)
            await waitUntil { origin.gate.writer.isPending }
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let refused = try fixture.gitFailure(["worktree", "unlock", fixture.linked.path])
            origin.repository.setValue(replacement.service, forKey: "worktreeService")
            XCTAssertTrue(controller.repository === origin.repository)
            XCTAssertTrue(controller.repository?.worktreeService === replacement.service)
            let completed = expectation(description: "writer after replaced-service failure")
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                XCTAssertNil(error); completed.fulfill()
            }
            origin.gate.writer.finish(refused.data, error: refused.error)
            await fulfillment(of: [completed], timeout: 15)
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(try fixture.ownershipProof(), initial)
        }

        func testExpectedQueuedCancellationIsSilentInALiveWindow() async throws {
            try await queuedCancellation(closesAndReopensWindow: false)
        }

        func testQueuedCancellationDoesNotPresentAfterRetainedWindowIsClosedAndReopened() async throws {
            try await queuedCancellation(closesAndReopensWindow: true)
        }

        func testHeldRealGitFailureDoesNotPresentAfterOwnerReplacementAndRestoration() async throws {
            selectGit()
            for replacement in OwnerReplacement.allCases {
                let fixture = try makeFixture()
                let origin = try await installService(in: fixture)
                let alternative = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                let window = try XCTUnwrap(controller.window)
                defer { controller.close() }
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let item = NSMenuItem(); item.representedObject = tree
                let initial = try fixture.ownershipProof()
                origin.gate.holdNextArguments = ["worktree", "unlock", tree.path]
                controller.unlockWorktree(item)
                await waitUntil { origin.gate.writer.isPending }
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let refused = try fixture.gitFailure(["worktree", "unlock", fixture.linked.path])
                XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("not locked"))
                replaceAndRestore(replacement, controller: controller, origin: origin, alternative: alternative, window: window)
                let completed = expectation(description: "following writer after stale failure")
                enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                    XCTAssertNil(error); completed.fulfill()
                }
                origin.gate.writer.finish(refused.data, error: refused.error)
                await fulfillment(of: [completed], timeout: 15)
                XCTAssertEqual(controller.errors.count, 0, "A stale \(replacement) owner displayed a delayed Git failure")
                XCTAssertNil(window.attachedSheet)
                XCTAssertEqual(try fixture.ownershipProof(), initial)
                XCTAssertEqual(following.service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
            }
        }

        func testRemoveConsentCannotAdoptARefreshedBranchBeforeItsConfirmationClick() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let origin = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            await activateWorktreeTestApplication()
            window.makeKeyAndOrderFront(nil)
            await waitUntil { NSApp.isActive && window.isKeyWindow }
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            controller.removeWorktree(item)
            let consent = try await waitForSheet(in: window, containing: "Remove")
            _ = try fixture.git(["checkout", "-b", "replacement"], in: fixture.linked)
            origin.service.refresh()
            await waitUntil { origin.service.worktree(forBranch: "refs/heads/replacement") != nil }
            window.endSheet(consent, returnCode: .alertFirstButtonReturn)
            await waitUntil { controller.errors.count == 1 }
            XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("Review") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "remove"]) })
            XCTAssertEqual(try fixture.git(["symbolic-ref", "HEAD"], in: fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines), "refs/heads/replacement")
        }

        func testRemoveAnywayWaitsBehindAnotherSheetAndHiddenOwnerWithoutHoldingAdmission() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let dirty = fixture.linked.appendingPathComponent("untracked.txt")
            let content = Data("preserve while consent waits\n".utf8)
            try content.write(to: dirty)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            let arguments = ["worktree", "remove", tree.path]
            origin.gate.holdNextArguments = arguments
            controller.removeWorktree(item)
            let first = try await waitForSheet(in: window, containing: "Remove")
            window.endSheet(first, returnCode: .alertFirstButtonReturn)
            await waitUntil { origin.gate.writer.isPending }
            let occupant = NSAlert()
            occupant.messageText = "Inspector owns this sheet"
            occupant.addButton(withTitle: "Done")
            occupant.beginSheetModal(for: window) { _ in }
            let refused = try fixture.gitFailure(arguments)
            XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: String(decoding: refused.data, as: UTF8.self)))
            let followingDone = expectation(description: "another writer completes while Remove Anyway waits")
            enqueue(following.service, command: .lock(path: tree.path, reason: "following")) { _, error in
                XCTAssertNil(error); followingDone.fulfill()
            }
            origin.gate.writer.finish(refused.data, error: refused.error)
            await fulfillment(of: [followingDone], timeout: 15)
            await drainCallbacks()
            XCTAssertTrue(window.attachedSheet === occupant.window)
            window.orderOut(nil)
            window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
            await drainCallbacks()
            XCTAssertFalse(window.isVisible)
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", "--force", tree.path]))
            window.makeKeyAndOrderFront(nil)
            let force = try await waitForSheet(in: window, containing: "Remove Anyway")
            window.endSheet(force, returnCode: .alertSecondButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(try Data(contentsOf: dirty), content)
            XCTAssertEqual(controller.errors.count, 0)
        }

        func testDeferredRemoveAnywayConfirmationLosesAuthorityAfterOwnerReplacementAndRestoration() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let dirty = fixture.linked.appendingPathComponent("untracked.txt")
            try "keep dirty data\n".write(to: dirty, atomically: true, encoding: .utf8)
            let origin = try await installService(in: fixture)
            let alternative = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let initial = try fixture.ownershipProof()
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            controller.removeWorktree(item)
            let first = try await waitForSheet(in: window, containing: "Remove")
            window.endSheet(first, returnCode: .alertFirstButtonReturn)
            let force = try await waitForSheet(in: window, containing: "Remove Anyway")
            let forcedArguments = ["worktree", "remove", "--force", tree.path]
            origin.gate.holdNextArguments = forcedArguments
            window.endSheet(force, returnCode: .alertFirstButtonReturn)
            // Worktree sheet continuations deliberately dispatch to a later main-queue turn.
            replaceAndRestore(.repository, controller: controller, origin: origin, alternative: alternative, window: window)
            await drainCallbacks()
            XCTAssertFalse(origin.gate.commands.contains(forcedArguments), "A stale confirmation acquired a forced-remove writer")
            // Release a wrongly admitted controlled writer so a red failure cannot strand the FIFO.
            origin.gate.writer.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            let completed = expectation(description: "following writer after discarded forced confirmation")
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                XCTAssertNil(error); completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 15)
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(try Data(contentsOf: dirty), Data("keep dirty data\n".utf8))
        }

        func testDelayedPrunePreviewIsDiscardedAfterOwnerReplacementAndRestoration() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let administrative = try fixture.administrativeDirectory()
            let origin = try await installService(in: fixture)
            let alternative = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            try FileManager.default.removeItem(at: fixture.linked)
            let metadata = try fixture.registrationProof(at: administrative)
            let report = try fixture.pruneReport()
            XCTAssertFalse(report.isEmpty)
            origin.gate.holdNextArguments = WorktreeCommand.pruneReport.arguments
            controller.pruneWorktrees(nil)
            await waitUntil { origin.gate.writer.isPending }
            replaceAndRestore(.repository, controller: controller, origin: origin, alternative: alternative, window: window)
            let completed = expectation(description: "following preview after delayed stale preview")
            enqueuePreview(following.service) { preview, error in
                XCTAssertNil(error)
                if let preview {
                    XCTAssertEqual(preview.report, String(decoding: report, as: UTF8.self))
                    following.service.discardPrunePreview(preview)
                }
                completed.fulfill()
            }
            origin.gate.writer.finish(report)
            await fulfillment(of: [completed], timeout: 15)
            XCTAssertNil(window.attachedSheet, "A restored owner displayed the old prune preview")
            XCTAssertFalse(origin.gate.commands.contains(WorktreeCommand.prune.arguments))
            XCTAssertEqual(try fixture.registrationProof(at: administrative), metadata)
            if let staleSheet = window.attachedSheet {
                window.endSheet(staleSheet, returnCode: .alertSecondButtonReturn)
                await waitUntil { window.attachedSheet == nil }
            }
            // Restoration is allowed to begin a fresh journey with its own single-use preview.
            controller.pruneWorktrees(nil)
            let fresh = try await waitForSheet(in: window, containing: "Prune")
            window.endSheet(fresh, returnCode: .alertSecondButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(try fixture.registrationProof(at: administrative), metadata)
        }

        func testDeferredPreviewRefreshFailureSurvivesAnotherPresentationWait() async throws {
            selectGit()
            for repairing in [false, true] {
                let fixture = try makeFixture()
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let origin = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                controller.presentsErrors = true
                let window = try XCTUnwrap(controller.window)
                addTeardownBlock { @MainActor in
                    await self.cleanupRepairPresentation(controller: controller, fixture: fixture)
                }
                let arguments = repairing ? ["worktree", "list", "--porcelain", "-z"] : WorktreeCommand.pruneReport.arguments
                if repairing {
                    try FileManager.default.removeItem(at: fixture.linked.appendingPathComponent(".git"))
                    origin.service.refresh()
                    await waitUntil { origin.service.worktrees.contains { $0.hasBrokenLink } }
                    let style = try await waitForSheet(in: window, containing: "Absolute Paths")
                    origin.gate.holdNextArguments = arguments
                    window.endSheet(style, returnCode: .alertFirstButtonReturn)
                } else {
                    try FileManager.default.removeItem(at: fixture.linked)
                    origin.gate.holdNextArguments = arguments
                    controller.pruneWorktrees(nil)
                }
                await waitUntil { origin.gate.writer.isPending }
                let occupant = unrelatedSheet(on: window)
                let firstOutput = try fixture.git(arguments)
                origin.gate.writer.finish(Data(firstOutput.utf8))
                let firstDrained = expectation(description: "initial preview completes behind occupant")
                enqueuePreview(following.service) { preview, error in
                    XCTAssertNil(error)
                    if let preview {
                        following.service.discardPrunePreview(preview)
                    }
                    firstDrained.fulfill()
                }
                await fulfillment(of: [firstDrained], timeout: 15)
                await drainCallbacks()
                origin.gate.holdNextArguments = arguments
                window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
                await waitUntil { origin.gate.writer.isPending }
                // Force another wait while refresh consumes the original token.
                window.orderOut(nil)
                let failure = try fixture.gitFailure(["worktree", "prune", "--unknown-deferred-refresh-option"])
                origin.gate.writer.finish(failure.data, error: failure.error)
                let failedReadDrained = expectation(description: "failed refresh releases FIFO")
                enqueuePreview(following.service) { preview, error in
                    XCTAssertNil(error)
                    if let preview {
                        following.service.discardPrunePreview(preview)
                    }
                    failedReadDrained.fulfill()
                }
                await fulfillment(of: [failedReadDrained], timeout: 15)
                await drainCallbacks()
                XCTAssertEqual(controller.errors.count, 0)
                window.makeKeyAndOrderFront(nil)
                let errorSheet = try await waitForSheet(in: window, containing: "unknown-deferred-refresh-option")
                XCTAssertEqual(controller.errors.count, 1)
                XCTAssertFalse(sheetText(errorSheet).contains("cancelled, consumed"))
                window.endSheet(errorSheet, returnCode: .OK)
                await waitUntil { window.attachedSheet == nil }
                window.orderOut(nil)
                window.makeKeyAndOrderFront(nil)
                await drainCallbacks()
                XCTAssertEqual(controller.errors.count, 1)
                XCTAssertFalse(origin.gate.commands.contains { $0 == WorktreeCommand.prune.arguments || $0.starts(with: ["worktree", "repair"]) })
            }
        }

        func testHiddenPruneOwnerRetainsRealPreviewFailuresUntilTheUserReturns() async throws {
            selectGit()
            for phase in HiddenPruneFailurePhase.allCases {
                let fixture = try makeFixture()
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let administrative = try fixture.administrativeDirectory()
                let origin = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                let window = try XCTUnwrap(controller.window)
                defer {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    controller.close()
                }
                try FileManager.default.removeItem(at: fixture.linked)
                let metadata = try fixture.registrationProof(at: administrative)
                let refused = try fixture.gitFailure(["worktree", "prune", "--unknown-preview-option"])
                XCTAssertFalse(refused.data.isEmpty)
                XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("unknown"))
                if phase == .prepare {
                    origin.gate.holdNextArguments = WorktreeCommand.pruneReport.arguments
                    controller.pruneWorktrees(nil)
                } else {
                    controller.pruneWorktrees(nil)
                    let confirmation = try await waitForSheet(in: window, containing: "Prune")
                    origin.gate.holdNextArguments = WorktreeCommand.pruneReport.arguments
                    window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
                }
                await waitUntil { origin.gate.writer.isPending }
                window.orderOut(nil)
                XCTAssertTrue(controller.window === window)
                XCTAssertTrue(controller.repository === origin.repository)
                XCTAssertTrue(origin.service.isSupported)
                XCTAssertFalse(origin.gate.writer.wasCancelled, "Hiding must not close the operation's service")
                let completed = expectation(description: "following real preview after hidden \(phase) failure")
                enqueuePreview(following.service) { preview, error in
                    XCTAssertNil(error)
                    XCTAssertNotNil(preview)
                    if let preview {
                        following.service.discardPrunePreview(preview)
                    }
                    completed.fulfill()
                }
                origin.gate.writer.finish(refused.data, error: refused.error)
                await fulfillment(of: [completed], timeout: 15)
                await drainCallbacks()
                XCTAssertEqual(controller.errors.count, 0)
                XCTAssertFalse(window.isVisible, "Completing a request must not restore or activate its hidden owner")
                window.makeKeyAndOrderFront(nil)
                await waitUntil { controller.errors.count == 1 && window.isVisible }
                XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("unknown-preview-option") == true)
                XCTAssertNil(window.attachedSheet, "The recording presenter observes the failure without attaching another sheet")
                XCTAssertFalse(origin.gate.commands.contains(WorktreeCommand.prune.arguments))
                XCTAssertEqual(try fixture.registrationProof(at: administrative), metadata)
                window.makeKeyAndOrderFront(nil)
                controller.pruneWorktrees(nil)
                let fresh = try await waitForSheet(in: window, containing: "Prune")
                window.endSheet(fresh, returnCode: .alertSecondButtonReturn)
                await waitUntil { window.attachedSheet == nil }
                XCTAssertEqual(try fixture.registrationProof(at: administrative), metadata)
            }
        }

        func testDeferredLockConfirmationCannotStartAfterWindowCloseAndReopen() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let origin = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            let initial = try fixture.ownershipProof()
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            controller.lockWorktree(item)
            let sheet = try await waitForSheet(in: window, containing: "Lock")
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            controller.close()
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(controller.window === window)
            await drainCallbacks()
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertFalse(origin.gate.commands.contains { $0.first == "worktree" && $0.dropFirst().first == "lock" })
            XCTAssertEqual(try fixture.ownershipProof(), initial)
        }

        func testHeldRepairPreparationRevokesReplacedOwnersAndDefersConsentBehindAnOccupiedSheet() async throws {
            selectGit()
            for replacesOwner in [true, false] {
                let fixture = try makeFixture()
                let blocker = try await installService(in: fixture, holdsWriter: true)
                let origin = try await installService(in: fixture)
                let alternative = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                let window = try XCTUnwrap(controller.window)
                defer {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    controller.close()
                }
                let administrative = try fixture.administrativeDirectory()
                let protected = try fixture.registrationProof(at: administrative)
                let refs = try fixture.git(["show-ref", "--head"])
                let content = try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt"))
                let barrierDone = expectation(description: "held writer reconciles before preparation")
                let followingDone = expectation(description: "real writer follows discarded repair preparation")
                enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in XCTAssertNil(error); barrierDone.fulfill() }
                XCTAssertTrue(blocker.gate.writer.isPending)
                let gitfile = fixture.linked.appendingPathComponent(".git")
                try FileManager.default.removeItem(at: gitfile)
                origin.service.refresh()
                await waitUntil { origin.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
                let style = try await waitForSheet(in: window, containing: "Absolute Paths")
                let preparationCount = origin.service.repairPreparationCount
                window.endSheet(style, returnCode: .alertFirstButtonReturn)
                await waitUntil { origin.service.repairPreparationCount > preparationCount && window.attachedSheet == nil }
                XCTAssertTrue(blocker.gate.writer.isPending, "The immutable capture completed while FIFO admission still waits")
                let occupant: NSAlert?
                if replacesOwner {
                    replaceAndRestore(.repository, controller: controller, origin: origin, alternative: alternative, window: window)
                    occupant = nil
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Unrelated inspector keeps its own sheet"
                    alert.addButton(withTitle: "Close Inspector")
                    alert.beginSheetModal(for: window) { _ in }
                    XCTAssertTrue(window.attachedSheet === alert.window)
                    occupant = alert
                }
                enqueue(following.service, command: .unlock(path: fixture.linked.path)) { _, error in XCTAssertNil(error); followingDone.fulfill() }
                XCTAssertFalse(following.gate.commands.contains(["worktree", "unlock", fixture.linked.path]))
                blocker.gate.writer.finish(Data())
                await fulfillment(of: [barrierDone, followingDone], timeout: 15)
                await drainCallbacks()
                XCTAssertEqual(controller.errors.count, 0)
                XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
                XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt")), content)
                XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "unlock", fixture.linked.path] }.count, 1)
                if let occupant {
                    XCTAssertTrue(window.attachedSheet === occupant.window, "Repair preparation must not replace another presenter's sheet")
                    window.orderOut(nil)
                    window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
                    await drainCallbacks()
                    XCTAssertFalse(window.isVisible, "Consent must wait for the user to restore its owner")
                    XCTAssertNil(window.attachedSheet)
                    window.makeKeyAndOrderFront(nil)
                    let deferred = try await waitForSheet(in: window, containing: "Reclaim")
                    XCTAssertTrue(window.isVisible)
                    XCTAssertTrue(NSApp.isActive)
                    XCTAssertTrue(sheetText(deferred).contains("worktree state changed"), "The deferred preview must describe the intervening unlock")
                    try attachScreenshot(of: deferred, named: "Worktrees-Deferred-Reclaim-Waits-For-Original-Window")
                    XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                    window.endSheet(deferred, returnCode: .alertSecondButtonReturn)
                    await waitUntil { window.attachedSheet == nil }
                } else {
                    XCTAssertNil(window.attachedSheet)
                }
                controller.repairWorktreeLinks(nil)
                let freshStyle = try await waitForSheet(in: window, containing: "Absolute Paths")
                window.endSheet(freshStyle, returnCode: .alertFirstButtonReturn)
                let freshConsent = try await waitForSheet(in: window, containing: "Reclaim")
                window.endSheet(freshConsent, returnCode: .alertSecondButtonReturn)
                await waitUntil { window.attachedSheet == nil }
                XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
                XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            }
        }

        func testOwnerRevocationDuringFinalRepairValidationPreventsWritingAndReleasesAdmission() async throws {
            selectGit()
            for closesWindow in [false, true] {
                let journey = try await movedRepairJourney()
                let alternative = try await installService(in: journey.fixture)
                let checkpoint = WorktreeWorkerCheckpoint()
                journey.origin.service.repairValidationObserver = { checkpoint.wait() }
                journey.origin.service.repairValidationResultObserver = { checkpoint.finish() }
                checkpoint.expectResult()
                addTeardownBlock { @MainActor in
                    checkpoint.resume()
                    await self.fulfillment(of: [checkpoint.finishedExpectation()], timeout: 15)
                    await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
                }
                let links = try journey.fixture.registrationProof(at: journey.administrative)
                let gitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
                journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
                try await approveChosenRepair(journey)
                await fulfillment(of: [checkpoint.entered], timeout: 5)
                XCTAssertTrue(checkpoint.isWaiting)
                if closesWindow {
                    journey.controller.close()
                } else {
                    replaceAndRestore(.repository, controller: journey.controller, origin: journey.origin, alternative: alternative, window: journey.window)
                }
                let progressed = expectation(description: "following preview waits for final validation to acknowledge owner revocation")
                var followingFinished = false
                enqueuePreview(journey.following.service) { preview, error in
                    XCTAssertNil(error)
                    if let preview {
                        journey.following.service.discardPrunePreview(preview)
                    }
                    followingFinished = true
                    progressed.fulfill()
                }
                await drainCallbacks()
                if closesWindow {
                    await fulfillment(of: [progressed], timeout: 15)
                    XCTAssertTrue(checkpoint.isWaiting, "Closing cancels preparation and releases its reservation before the late worker returns")
                } else {
                    XCTAssertFalse(followingFinished, "The final-validation worker still owns this admission")
                }
                checkpoint.resume()
                if !closesWindow {
                    await fulfillment(of: [progressed], timeout: 15)
                }
                await fulfillment(of: [checkpoint.finishedExpectation()], timeout: 15)
                XCTAssertFalse(checkpoint.didTimeout)
                XCTAssertEqual(checkpoint.deliveryCount, 1)
                XCTAssertFalse(journey.origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                XCTAssertEqual(journey.controller.errors.count, 0)
                XCTAssertTrue(journey.window.sheets.isEmpty)
                XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), links)
                XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), gitfile)
                XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
            }
        }

        func testProvenRepairRetainsAdmissionUntilItsWriteAndReconciliationComplete() async throws {
            selectGit()
            let journey = try await movedRepairJourney()
            addTeardownBlock { @MainActor in
                await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
            }
            let arguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
            journey.origin.gate.holdNextArguments = arguments
            journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
            try await approveChosenRepair(journey)
            await waitUntil { journey.origin.gate.writer.isPending }
            let followingDone = expectation(description: "following action waits for the complete repair admission")
            enqueue(journey.following.service, command: .unlock(path: journey.fixture.linked.path)) { _, error in
                XCTAssertNil(error)
                followingDone.fulfill()
            }
            await waitUntil { journey.origin.gate.writer.isPending || journey.following.gate.commands.contains(["worktree", "unlock", journey.fixture.linked.path]) }
            XCTAssertFalse(journey.following.gate.commands.contains(["worktree", "unlock", journey.fixture.linked.path]), "An explicitly approved repair owns admission through its write and reconciliation")
            guard journey.origin.gate.writer.isPending else {
                await fulfillment(of: [followingDone], timeout: 15)
                return
            }
            let output = try journey.fixture.git(arguments)
            journey.origin.gate.writer.finish(Data(output.utf8))
            await fulfillment(of: [followingDone], timeout: 15)
            await waitUntil { journey.origin.service.worktree(forBranch: "refs/heads/topic")?.hasBrokenLink == false }
            XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
            XCTAssertEqual(journey.following.gate.commands.filter { $0 == ["worktree", "unlock", journey.fixture.linked.path] }.count, 1)
            XCTAssertEqual(journey.controller.errors.count, 0)
            XCTAssertTrue(journey.window.sheets.isEmpty)
            // Unlock intentionally changes `locked`; all other repair payloads stay intact.
            var expected = journey.payload
            expected.removeValue(forKey: "locked")
            var actual = try journey.fixture.repairPayloadProof(at: journey.administrative, includingLock: false)
            actual.removeValue(forKey: "locked")
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(try WorktreePaths.canonical(journey.fixture.git(["rev-parse", "--absolute-git-dir"], in: journey.fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines)), WorktreePaths.canonical(journey.administrative.path))
        }

        func testChosenRepairStyleWaitsForExactScopeApprovalAfterAnUnrelatedSheet() async throws {
            selectGit()
            for relative in [false, true] {
                let journey = try await movedRepairJourney()
                addTeardownBlock { @MainActor in
                    await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
                }
                let barrierDone = expectation(description: "writer preceding preview completes")
                enqueue(journey.blocker.service, command: .lock(path: journey.fixture.linked.path, reason: "barrier")) { _, error in XCTAssertNil(error); barrierDone.fulfill() }
                let preparationCount = journey.origin.service.repairPreparationCount
                XCTAssertFalse(sheetText(journey.style).contains(journey.fixture.linked.path), "Style selection carries no mutable target list")
                journey.window.endSheet(journey.style, returnCode: relative ? .alertSecondButtonReturn : .alertFirstButtonReturn)
                await waitUntil { journey.origin.service.repairPreparationCount > preparationCount && journey.window.attachedSheet == nil }
                let occupant = unrelatedSheet(on: journey.window)
                journey.blocker.gate.writer.finish(Data())
                await fulfillment(of: [barrierDone], timeout: 15)
                try await assertFollowingPreviewProgresses(journey)
                XCTAssertFalse(journey.origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
                XCTAssertTrue(journey.window.attachedSheet === occupant.window)
                journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
                try await approveChosenRepair(journey)
                let arguments = ["worktree", "repair", relative ? "--relative-paths" : "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
                await waitUntil { journey.origin.gate.commands.contains(arguments) && journey.origin.service.worktree(forBranch: "refs/heads/topic")?.hasBrokenLink == false }
                XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
                XCTAssertEqual(journey.controller.errors.count, 0)
                try assertRepairedJourney(journey, relative: relative)
            }
        }

        func testRepairAndFollowingWorktreeFailuresWaitInOrderForTheirOriginalWindowSheet() async throws {
            selectGit()
            let journey = try await movedRepairJourney()
            addTeardownBlock { @MainActor in
                await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
            }
            journey.controller.presentsErrors = true
            let originalLinks = try journey.fixture.registrationProof(at: journey.administrative)
            let originalGitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
            let arguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
            journey.origin.gate.holdNextArguments = arguments
            journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
            try await approveChosenRepair(journey)
            await waitUntil { journey.origin.gate.writer.isPending }
            let occupant = unrelatedSheet(on: journey.window)
            let repairFailure = try journey.fixture.gitFailure(["worktree", "repair", "--unknown-repair-overlap-option"])
            XCTAssertTrue(String(decoding: repairFailure.data, as: UTF8.self).contains("unknown-repair-overlap-option"))
            journey.origin.gate.writer.finish(repairFailure.data, error: repairFailure.error)
            try await assertFollowingPreviewProgresses(journey)
            XCTAssertEqual(journey.controller.errors.count, 0, "The original presenter must retain the error until its unrelated sheet ends")
            XCTAssertTrue(journey.window.attachedSheet === occupant.window)
            XCTAssertEqual(journey.window.sheets.count, 1, "A pending error must remain outside AppKit's unguarded sheet queue")

            let item = NSMenuItem(); item.representedObject = journey.tree
            let unlockArguments = ["worktree", "unlock", journey.tree.path]
            journey.origin.gate.holdNextArguments = unlockArguments
            journey.controller.unlockWorktree(item)
            await waitUntil { journey.origin.gate.writer.isPending }
            let unlockFailure = try journey.fixture.gitFailure(["worktree", "unlock", "--unknown-unlock-overlap-option", journey.tree.path])
            XCTAssertTrue(String(decoding: unlockFailure.data, as: UTF8.self).contains("unknown-unlock-overlap-option"))
            journey.origin.gate.writer.finish(unlockFailure.data, error: unlockFailure.error)
            try await assertFollowingPreviewProgresses(journey)
            XCTAssertEqual(journey.controller.errors.count, 0, "A later error cannot replace or bypass the first pending error")
            XCTAssertEqual(journey.window.sheets.count, 1)
            XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
            XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)

            journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
            let first = try await waitForSheet(in: journey.window, containing: "unknown-repair-overlap-option")
            XCTAssertEqual(journey.controller.errors.count, 1)
            try attachScreenshot(of: first, named: "Worktrees-Deferred-Repair-Failure-After-Unrelated-Sheet")
            journey.window.endSheet(first, returnCode: .OK)
            let second = try await waitForSheet(in: journey.window, containing: "unknown-unlock-overlap-option")
            XCTAssertEqual(journey.controller.errors.count, 2)
            journey.window.endSheet(second, returnCode: .OK)
            await waitUntil { journey.window.attachedSheet == nil }
            XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
            XCTAssertEqual(journey.origin.gate.commands.filter { $0 == unlockArguments }.count, 1)
            XCTAssertFalse(journey.origin.gate.commands.contains(WorktreeCommand.prune.arguments))
            XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
            XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
        }

        func testDeferredRepairFailureCannotReturnAfterOwnerReplacementOrWindowCloseAndReopen() async throws {
            selectGit()
            for closesWindow in [false, true] {
                let journey = try await movedRepairJourney()
                addTeardownBlock { @MainActor in
                    await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
                }
                let alternative = try await installService(in: journey.fixture)
                journey.controller.presentsErrors = true
                let originalLinks = try journey.fixture.registrationProof(at: journey.administrative)
                let originalGitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
                let arguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
                journey.origin.gate.holdNextArguments = arguments
                journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
                try await approveChosenRepair(journey)
                await waitUntil { journey.origin.gate.writer.isPending }
                let occupant = unrelatedSheet(on: journey.window)
                let refused = try journey.fixture.gitFailure(["worktree", "repair", "--unknown-stale-overlap-option"])
                XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("unknown-stale-overlap-option"))
                journey.origin.gate.writer.finish(refused.data, error: refused.error)
                try await assertFollowingPreviewProgresses(journey)
                XCTAssertEqual(journey.controller.errors.count, 0)
                XCTAssertEqual(journey.window.sheets.count, 1)
                if closesWindow {
                    journey.controller.close()
                    journey.window.makeKeyAndOrderFront(nil)
                } else {
                    replaceAndRestore(.repository, controller: journey.controller, origin: journey.origin, alternative: alternative, window: journey.window)
                }
                if journey.window.attachedSheet === occupant.window {
                    journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
                }
                await drainCallbacks()
                XCTAssertEqual(journey.controller.errors.count, 0, "Restoring the same owners cannot revive an error whose authority expired")
                XCTAssertTrue(journey.window.sheets.isEmpty)
                XCTAssertTrue(journey.controller.window === journey.window)
                XCTAssertTrue(journey.controller.repository === journey.origin.repository)
                XCTAssertTrue(journey.window.isVisible)
                XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
                XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
                XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
                XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
                try await assertFollowingPreviewProgresses(journey)
            }
        }

        func testDeferredActionableRepairFailureRemainsDeliverableWhileGitCapabilityIsBeingRechecked() async throws {
            selectGit()
            let journey = try await movedRepairJourney(selectedGitProxy: true)
            addTeardownBlock { @MainActor in
                await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
            }
            journey.controller.presentsErrors = true
            let originalLinks = try journey.fixture.registrationProof(at: journey.administrative)
            let originalGitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
            let arguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
            journey.origin.gate.holdNextArguments = arguments
            journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
            try await approveChosenRepair(journey)
            await waitUntil { journey.origin.gate.writer.isPending }
            let occupant = unrelatedSheet(on: journey.window)
            let refused = try journey.fixture.gitFailure(["worktree", "repair", "--unknown-pending-capability-option"])
            journey.origin.gate.writer.finish(refused.data, error: refused.error)
            try await assertFollowingPreviewProgresses(journey)
            XCTAssertEqual(journey.controller.errors.count, 0)
            XCTAssertEqual(journey.window.sheets.count, 1)

            let executable = journey.fixture.root.appendingPathComponent("selected-git")
            try writeGitProxy(at: executable, generation: "after-pending-error")
            journey.origin.gate.holdNextArguments = ["--version"]
            let rejected = expectation(description: "new request reports its replaced Git executable")
            enqueuePreview(journey.origin.service) { preview, error in
                XCTAssertNil(preview)
                XCTAssertNotNil(error)
                XCTAssertTrue(error?.localizedFailureReason?.contains("selected Git") == true)
                rejected.fulfill()
            }
            await fulfillment(of: [rejected], timeout: 10)
            XCTAssertFalse(journey.origin.service.isSupported)
            XCTAssertTrue(journey.origin.gate.writer.isPending, "Keep the actual capability probe unresolved while the original error is delivered")
            journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
            let errorSheet = try await waitForSheet(in: journey.window, containing: "unknown-pending-capability-option")
            XCTAssertFalse(journey.origin.service.isSupported, "An error result must not depend on current consent capability")
            XCTAssertEqual(journey.controller.errors.count, 1)
            XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
            XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
            XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
            XCTAssertFalse(journey.origin.gate.commands.contains(WorktreeCommand.prune.arguments))
            journey.window.endSheet(errorSheet, returnCode: .OK)
            try journey.origin.gate.writer.finish(Data(journey.fixture.git(["--version"]).utf8))
            await waitUntil { journey.origin.service.isSupported }
            journey.following.service.refresh()
            await waitUntil { journey.following.service.isSupported }
            try await assertFollowingPreviewProgresses(journey)
        }

        func testExpectedQueuedCancellationDoesNotEnterTheDeferredFailureFIFO() async throws {
            selectGit()
            let journey = try await movedRepairJourney()
            addTeardownBlock { @MainActor in
                await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
            }
            journey.controller.presentsErrors = true
            let originalLinks = try journey.fixture.registrationProof(at: journey.administrative)
            let originalGitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
            journey.window.endSheet(journey.style, returnCode: .alertThirdButtonReturn)
            await waitUntil { journey.window.attachedSheet == nil }
            let barrierDone = expectation(description: "writer preceding expected cancellation completes")
            enqueue(journey.blocker.service, command: .lock(path: journey.fixture.linked.path, reason: "barrier")) { _, error in XCTAssertNil(error); barrierDone.fulfill() }
            XCTAssertTrue(journey.blocker.gate.writer.isPending)
            let occupant = unrelatedSheet(on: journey.window)
            let item = NSMenuItem(); item.representedObject = journey.tree
            journey.controller.unlockWorktree(item)
            journey.origin.service.cancel()
            journey.blocker.gate.writer.finish(Data())
            await fulfillment(of: [barrierDone], timeout: 15)
            try await assertFollowingPreviewProgresses(journey)
            XCTAssertEqual(journey.controller.errors.count, 0)
            XCTAssertTrue(journey.window.attachedSheet === occupant.window)
            XCTAssertEqual(journey.window.sheets.count, 1)
            XCTAssertFalse(journey.origin.gate.commands.contains(["worktree", "unlock", journey.tree.path]))
            journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
            await drainCallbacks()
            XCTAssertTrue(journey.window.sheets.isEmpty)
            XCTAssertEqual(journey.controller.errors.count, 0, "Expected cancellation must not leave an error waiting for the sheet to end")
            XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
            XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
            try await assertFollowingPreviewProgresses(journey)
        }

        func testDeferredRepairFailureWaitsForItsHiddenOrMinimizedOwnerExactlyOnce() async throws {
            selectGit()
            for presentation in 0 ..< 3 {
                let journey = try await movedRepairJourney()
                addTeardownBlock { @MainActor in
                    await self.cleanupRepairPresentation(controller: journey.controller, fixture: journey.fixture)
                }
                journey.controller.presentsErrors = true
                let originalLinks = try journey.fixture.registrationProof(at: journey.administrative)
                let originalGitfile = try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git"))
                let arguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(journey.fixture.main.path), WorktreePaths.canonical(journey.fixture.linked.path)]
                journey.origin.gate.holdNextArguments = arguments
                journey.window.endSheet(journey.style, returnCode: .alertFirstButtonReturn)
                try await approveChosenRepair(journey)
                await waitUntil { journey.origin.gate.writer.isPending }
                let occupant = presentation == 2 ? nil : unrelatedSheet(on: journey.window)
                if presentation == 2 {
                    // Start minimized without a sheet whose dismissal would restore the parent in AppKit.
                    journey.window.miniaturize(nil)
                    await waitUntil { journey.window.isMiniaturized }
                }
                let refused = try journey.fixture.gitFailure(["worktree", "repair", "--unknown-hidden-overlap-option"])
                journey.origin.gate.writer.finish(refused.data, error: refused.error)
                try await assertFollowingPreviewProgresses(journey)
                XCTAssertEqual(journey.controller.errors.count, 0)
                switch presentation {
                case 0: journey.window.orderOut(nil)
                case 1:
                    NSApp.hide(nil)
                    await waitUntil { NSApp.isHidden }
                default: break
                }
                if let occupant {
                    journey.window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
                }
                await drainCallbacks()
                XCTAssertEqual(journey.controller.errors.count, 0)
                XCTAssertNil(journey.window.attachedSheet)
                switch presentation {
                case 0: XCTAssertFalse(journey.window.isVisible)
                case 1: XCTAssertTrue(NSApp.isHidden)
                default: XCTAssertTrue(journey.window.isMiniaturized)
                }
                // Only this explicit user return permits presentation.
                NSApp.unhide(nil)
                journey.window.deminiaturize(nil)
                await activateWorktreeTestApplication()
                journey.window.makeKeyAndOrderFront(nil)
                let failure = try await waitForSheet(in: journey.window, containing: "unknown-hidden-overlap-option")
                XCTAssertEqual(journey.controller.errors.count, 1)
                XCTAssertTrue(journey.window.isVisible)
                XCTAssertFalse(journey.window.isMiniaturized)
                XCTAssertFalse(NSApp.isHidden)
                XCTAssertTrue(NSApp.isActive)
                if presentation == 2 {
                    try attachScreenshot(of: failure, named: "Worktrees-Deferred-Failure-Waits-For-Minimized-Window")
                }
                journey.window.endSheet(failure, returnCode: .OK)
                await waitUntil { journey.window.attachedSheet == nil }
                journey.window.makeKeyAndOrderFront(nil)
                await drainCallbacks()
                XCTAssertEqual(journey.controller.errors.count, 1, "Restoring the owner again cannot replay its result")
                XCTAssertTrue(journey.window.sheets.isEmpty)
                XCTAssertEqual(journey.origin.gate.commands.filter { $0 == arguments }.count, 1)
                XCTAssertEqual(try journey.fixture.registrationProof(at: journey.administrative), originalLinks)
                XCTAssertEqual(try Data(contentsOf: journey.fixture.linked.appendingPathComponent(".git")), originalGitfile)
                XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
                try await assertFollowingPreviewProgresses(journey)
            }
        }

        func testHeldPrunePreparationPreservesAnOccupiedSheetAndCanStartAFreshJourney() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let administrative = try fixture.administrativeDirectory()
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            try FileManager.default.removeItem(at: fixture.linked)
            let protected = try fixture.registrationProof(at: administrative)
            let refs = try fixture.git(["show-ref", "--head"])
            let report = try fixture.pruneReport()
            XCTAssertFalse(report.isEmpty)
            origin.gate.holdNextArguments = WorktreeCommand.pruneReport.arguments
            controller.pruneWorktrees(nil)
            await waitUntil { origin.gate.writer.isPending }
            let occupant = NSAlert()
            occupant.messageText = "Another presenter owns this sheet"
            occupant.addButton(withTitle: "Close Inspector")
            occupant.beginSheetModal(for: window) { _ in }
            XCTAssertTrue(window.attachedSheet === occupant.window)
            let followingDone = expectation(description: "discarded occupied-owner preview releases FIFO")
            enqueuePreview(following.service) { preview, error in
                XCTAssertNil(error)
                XCTAssertEqual(preview?.report, String(decoding: report, as: UTF8.self))
                if let preview {
                    following.service.discardPrunePreview(preview)
                }
                followingDone.fulfill()
            }
            origin.gate.writer.finish(report)
            await fulfillment(of: [followingDone], timeout: 15)
            await drainCallbacks()
            XCTAssertTrue(window.attachedSheet === occupant.window)
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertFalse(origin.gate.commands.contains(WorktreeCommand.prune.arguments))
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            window.endSheet(occupant.window, returnCode: .alertFirstButtonReturn)
            let fresh = try await waitForSheet(in: window, containing: "Prune")
            window.endSheet(fresh, returnCode: .alertSecondButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
        }

        func testLiveRepairPreparationRejectsAChangedForeignGitfileWithoutOfferingConsent() async throws {
            selectGit()
            let fixture = try makeFixture()
            let foreign = try makeFixture()
            let blocker = try await installService(in: fixture, holdsWriter: true)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let administrative = try fixture.administrativeDirectory()
            let protected = try fixture.registrationProof(at: administrative)
            let refs = try fixture.git(["show-ref", "--head"])
            let foreignProof = try foreign.ownershipProof()
            let foreignLink = try Data(contentsOf: foreign.linked.appendingPathComponent(".git"))
            let barrierDone = expectation(description: "writer preceding rejected repair completes")
            let followingDone = expectation(description: "writer after rejected repair completes")
            enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in XCTAssertNil(error); barrierDone.fulfill() }
            let gitfile = fixture.linked.appendingPathComponent(".git")
            try FileManager.default.removeItem(at: gitfile)
            origin.service.refresh()
            await waitUntil { origin.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
            let style = try await waitForSheet(in: window, containing: "Absolute Paths")
            let preparationCount = origin.service.repairPreparationCount
            window.endSheet(style, returnCode: .alertFirstButtonReturn)
            await waitUntil { origin.service.repairPreparationCount > preparationCount && window.attachedSheet == nil }
            try foreignLink.write(to: gitfile)
            enqueue(following.service, command: .unlock(path: fixture.linked.path)) { _, error in XCTAssertNil(error); followingDone.fulfill() }
            blocker.gate.writer.finish(Data())
            await fulfillment(of: [barrierDone, followingDone], timeout: 15)
            await waitUntil { controller.errors.count == 1 }
            let error = try XCTUnwrap(controller.errors.first)
            XCTAssertEqual(error.domain, "PBGitXErrorDomain")
            XCTAssertFalse((error.localizedFailureReason ?? "").isEmpty)
            XCTAssertNil(window.attachedSheet, "Preparation must not manufacture a Reclaim permit for a foreign link")
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
            XCTAssertEqual(try Data(contentsOf: gitfile), foreignLink)
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try foreign.ownershipProof(), foreignProof)
            XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "unlock", fixture.linked.path] }.count, 1)
        }

        func testLivePrunePreparationPresentsItsRealReportFailureAndReleasesFIFO() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let administrative = try fixture.administrativeDirectory()
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            try FileManager.default.removeItem(at: fixture.linked)
            let protected = try fixture.registrationProof(at: administrative)
            let report = try fixture.pruneReport()
            XCTAssertFalse(report.isEmpty)
            let refused = try fixture.gitFailure(["worktree", "prune", "--unknown-preview-option"])
            XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("unknown"))
            origin.gate.holdNextArguments = WorktreeCommand.pruneReport.arguments
            controller.pruneWorktrees(nil)
            await waitUntil { origin.gate.writer.isPending }
            let followingDone = expectation(description: "real preview after visible report error progresses")
            enqueuePreview(following.service) { preview, error in
                XCTAssertNil(error)
                XCTAssertEqual(preview?.report, String(decoding: report, as: UTF8.self))
                if let preview {
                    following.service.discardPrunePreview(preview)
                }
                followingDone.fulfill()
            }
            origin.gate.writer.finish(refused.data, error: refused.error)
            await fulfillment(of: [followingDone], timeout: 15)
            await waitUntil { controller.errors.count == 1 }
            XCTAssertEqual(controller.errors.first?.domain, "PBGitXErrorDomain")
            XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("unknown") == true)
            XCTAssertNil(window.attachedSheet, "No confirmation sheet exists after preparation fails")
            XCTAssertFalse(origin.gate.commands.contains(WorktreeCommand.prune.arguments))
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
        }

        func testDelayedFirstRemoveFailureIsShownOnlyInItsCurrentOwnerWithoutAForceRetry() async throws {
            selectGit()
            for replacesOwner in [false, true] {
                let fixture = try makeFixture()
                _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
                let origin = try await installService(in: fixture)
                let alternative = try await installService(in: fixture)
                let following = try await installService(in: fixture)
                let controller = recordingController(for: origin)
                let window = try XCTUnwrap(controller.window)
                defer {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    controller.close()
                }
                let initial = try fixture.ownershipProof()
                let refs = try fixture.git(["show-ref", "--head"])
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let item = NSMenuItem(); item.representedObject = tree
                let removeArguments = ["worktree", "remove", tree.path]
                origin.gate.holdNextArguments = removeArguments
                controller.removeWorktree(item)
                let confirmation = try await waitForSheet(in: window, containing: "Remove")
                window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
                await waitUntil { origin.gate.writer.isPending }
                let refused = try fixture.gitFailure(["worktree", "remove", "--unknown-remove-option", fixture.linked.path])
                XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("unknown"))
                if replacesOwner {
                    replaceAndRestore(.repository, controller: controller, origin: origin, alternative: alternative, window: window)
                }
                let followingDone = expectation(description: "writer after first-remove error progresses")
                enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in XCTAssertNil(error); followingDone.fulfill() }
                origin.gate.writer.finish(refused.data, error: refused.error)
                await fulfillment(of: [followingDone], timeout: 15)
                await drainCallbacks()
                XCTAssertEqual(controller.errors.count, replacesOwner ? 0 : 1)
                if !replacesOwner {
                    XCTAssertEqual(controller.errors.first?.domain, "PBGitXErrorDomain")
                    XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("unknown") == true)
                }
                XCTAssertNil(window.attachedSheet, "This error must not offer a destructive Remove Anyway retry")
                XCTAssertEqual(origin.gate.commands.filter { $0 == removeArguments }.count, 1)
                XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", "--force", tree.path]))
                XCTAssertEqual(try fixture.ownershipProof(), initial)
                XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
                XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "lock", "--reason", "following", fixture.linked.path] }.count, 1)
            }
        }

        func testDelayedFirstRemoveFailureDoesNotRetainItsReleasedControllerAndReleasesFIFO() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let dirty = fixture.linked.appendingPathComponent("untracked.txt")
            let dirtyData = Data("preserve after the controller is released\n".utf8)
            try dirtyData.write(to: dirty)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            var controller: RecordingWindowController? = recordingController(for: origin)
            weak let releasedController = controller
            let window = try XCTUnwrap(controller?.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller?.close()
            }
            let initial = try fixture.ownershipProof()
            let refs = try fixture.git(["show-ref", "--head"])
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            let removeArguments = ["worktree", "remove", tree.path]
            origin.gate.holdNextArguments = removeArguments
            controller?.removeWorktree(item)
            let confirmation = try await waitForSheet(in: window, containing: "Remove")
            window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
            await waitUntil { origin.gate.writer.isPending }
            // This real dirty-checkout refusal would offer Remove Anyway in a live owner.
            let refused = try fixture.gitFailure(removeArguments)
            XCTAssertTrue(WorktreePolicy.offersForcedRemoval(gitMessage: String(decoding: refused.data, as: UTF8.self)))
            XCTAssertEqual(controller?.errors.count, 0)
            controller?.close()
            controller = nil
            await waitUntil { releasedController == nil }
            XCTAssertNil(releasedController, "The in-flight Remove callback must not retain its original controller")
            XCTAssertTrue(origin.gate.writer.isPending, "The first Remove must still await its delayed Git failure")
            XCTAssertFalse(origin.gate.writer.wasCancelled, "An admitted writer drains after its window closes")
            let followingDone = expectation(description: "writer after released Remove owner progresses")
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in XCTAssertNil(error); followingDone.fulfill() }
            XCTAssertFalse(following.gate.commands.contains(["worktree", "lock", "--reason", "following", fixture.linked.path]))
            origin.gate.writer.finish(refused.data, error: refused.error)
            await fulfillment(of: [followingDone], timeout: 15)
            await drainCallbacks()
            XCTAssertNil(releasedController)
            XCTAssertNil(window.attachedSheet, "A released owner cannot present an error or a Remove Anyway sheet")
            XCTAssertEqual(origin.gate.commands.filter { $0 == removeArguments }.count, 1)
            XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", "--force", tree.path]))
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: dirty), dirtyData)
            XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "lock", "--reason", "following", fixture.linked.path] }.count, 1)
        }

        func testQueuedRemoveCancellationIsSilentInItsCurrentVisibleOwnerAndReleasesFIFO() async throws {
            selectGit()
            let fixture = try makeFixture()
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let dirty = fixture.linked.appendingPathComponent("untracked.txt")
            let dirtyData = Data("preserve after queued Remove cancellation\n".utf8)
            try dirtyData.write(to: dirty)
            let blocker = try await installService(in: fixture, holdsWriter: true)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let initial = try fixture.ownershipProof()
            let refs = try fixture.git(["show-ref", "--head"])
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            let blockerDone = expectation(description: "writer preceding cancelled Remove completes")
            let followingDone = expectation(description: "writer following cancelled Remove progresses")
            enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in XCTAssertNil(error); blockerDone.fulfill() }
            XCTAssertTrue(blocker.gate.writer.isPending)
            controller.removeWorktree(item)
            let confirmation = try await waitForSheet(in: window, containing: "Remove")
            window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
            // The sheet continuation reserves its mutation on the next main-queue turn.
            await drainCallbacks()
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(origin.gate.commands.contains(["worktree", "remove", tree.path]))
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in XCTAssertNil(error); followingDone.fulfill() }
            origin.service.cancel()
            XCTAssertTrue(controller.window === window)
            XCTAssertTrue(controller.repository === origin.repository)
            XCTAssertTrue(origin.repository.worktreeService === origin.service)
            XCTAssertTrue(window.isVisible, "Service cancellation must leave the original presentation owner current")
            blocker.gate.writer.finish(Data())
            await fulfillment(of: [blockerDone, followingDone], timeout: 15)
            await drainCallbacks()
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertNil(window.attachedSheet, "Expected cancellation cannot offer Remove Anyway")
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "remove"]) })
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: dirty), dirtyData)
            XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "lock", "--reason", "following", fixture.linked.path] }.count, 1)
        }

        func testRenewedRepairRequiresItsNewClickThenPresentsARealWriterFailureAndReleasesFIFO() async throws {
            selectGit()
            let fixture = try makeFixture()
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let initial = try fixture.ownershipProof()
            let refs = try fixture.git(["show-ref", "--head"])
            let gitfile = fixture.linked.appendingPathComponent(".git")
            let originalLink = try Data(contentsOf: gitfile)
            try FileManager.default.removeItem(at: gitfile)
            origin.service.refresh()
            await waitUntil { origin.service.worktrees.first { WorktreePaths.identity($0.path) == WorktreePaths.identity(fixture.linked.path) }?.hasBrokenLink == true }
            let style = try await waitForSheet(in: window, containing: "Absolute Paths")
            window.endSheet(style, returnCode: .alertFirstButtonReturn)
            let initialConsent = try await waitForSheet(in: window, containing: "Reclaim")
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
            try originalLink.write(to: gitfile)
            window.endSheet(initialConsent, returnCode: .alertFirstButtonReturn)
            let renewed = try await waitForSheet(in: window, containing: "Repair")
            XCTAssertTrue(sheetText(renewed).contains("The worktree state changed"))
            XCTAssertTrue(descendants(renewed.contentView).contains { ($0 as? NSButton)?.title == "Repair" })
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) }, "Changed evidence cannot launch from the old Reclaim click")
            let repairArguments = ["worktree", "repair", "--no-relative-paths", WorktreePaths.canonical(fixture.main.path)]
            origin.gate.holdNextArguments = repairArguments
            window.endSheet(renewed, returnCode: .alertFirstButtonReturn)
            await waitUntil { origin.gate.writer.isPending }
            XCTAssertEqual(origin.gate.commands.filter { $0 == repairArguments }.count, 1)
            let followingDone = expectation(description: "writer follows confirmed repair failure")
            enqueue(following.service, command: .unlock(path: fixture.linked.path)) { _, error in XCTAssertNil(error); followingDone.fulfill() }
            XCTAssertFalse(following.gate.commands.contains(["worktree", "unlock", fixture.linked.path]))
            let refused = try fixture.gitFailure(["worktree", "repair", "--unknown-repair-option"])
            XCTAssertTrue(String(decoding: refused.data, as: UTF8.self).contains("unknown"))
            origin.gate.writer.finish(refused.data, error: refused.error)
            await fulfillment(of: [followingDone], timeout: 15)
            await waitUntil { controller.errors.count == 1 }
            XCTAssertEqual(controller.errors.first?.domain, "PBGitXErrorDomain")
            XCTAssertTrue(controller.errors.first?.localizedFailureReason?.contains("unknown") == true)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(origin.gate.commands.filter { $0 == repairArguments }.count, 1)
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "unlock", fixture.linked.path] }.count, 1)
        }

        func testSamePathGitUpgradeDuringPruneConsentShowsAnActionableErrorWithoutPruning() async throws {
            try await assertGitUpgradeDuringConsentShowsError(repairing: false)
        }

        func testSamePathGitUpgradeDuringReclaimConsentShowsAnActionableErrorWithoutRepairing() async throws {
            try await assertGitUpgradeDuringConsentShowsError(repairing: true)
        }

        func testReclaimEscapeCancelsOnlyItsOwnSheetAndPreservesGitState() async throws {
            selectGit()
            let fixture = try makeFixture()
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            defer {
                otherWindow.close()
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let administrative = try fixture.administrativeDirectory()
            let protected = try fixture.registrationProof(at: administrative)
            let refs = try fixture.git(["show-ref", "--head"])
            let mainContent = try Data(contentsOf: fixture.main.appendingPathComponent("content.txt"))
            let linkedContent = try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt"))
            let gitfile = fixture.linked.appendingPathComponent(".git")
            try FileManager.default.removeItem(at: gitfile)
            origin.service.refresh()
            await waitUntil { origin.service.worktrees.contains { $0.hasBrokenLink } }
            let style = try await waitForSheet(in: window, containing: "Absolute Paths")
            window.endSheet(style, returnCode: .alertFirstButtonReturn)
            let consent = try await waitForSheet(in: window, containing: "Reclaim")
            let cancel = try XCTUnwrap(descendants(consent.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
            XCTAssertTrue(consent.defaultButtonCell === cancel.cell)
            otherWindow.makeKeyAndOrderFront(nil)
            try sendEscape(to: otherWindow)
            await drainCallbacks()
            XCTAssertTrue(window.attachedSheet === consent, "Another window's Escape cannot cancel this consent")
            XCTAssertTrue(consent.isVisible)
            consent.makeKeyAndOrderFront(nil)
            try sendEscape(to: consent)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertFalse(origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent("content.txt")), mainContent)
            XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt")), linkedContent)
            let progressed = expectation(description: "Escape cancellation leaves the shared FIFO available")
            enqueuePreview(following.service) { preview, error in
                XCTAssertNil(error)
                XCTAssertNotNil(preview)
                if let preview {
                    following.service.discardPrunePreview(preview)
                }
                progressed.fulfill()
            }
            await fulfillment(of: [progressed], timeout: 15)
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: gitfile.path))
        }

        private func sendEscape(to window: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53
            ))
            NSApp.sendEvent(event)
        }

        private func assertGitUpgradeDuringConsentShowsError(repairing: Bool) async throws {
            preserveGitPreferenceUntilTeardown()
            let fixture = try makeFixture()
            let executable = fixture.root.appendingPathComponent("selected-git")
            try writeGitProxy(at: executable, generation: "before")
            UserDefaults.standard.set(executable.path, forKey: "gitExecutable")
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            let administrative = try fixture.administrativeDirectory()
            let protected = try fixture.registrationProof(at: administrative)
            let refs = try fixture.git(["show-ref", "--head"])
            let mainContent = try Data(contentsOf: fixture.main.appendingPathComponent("content.txt"))
            let linkedContent = try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt"))
            let origin = try await installService(in: fixture, executable: executable)
            let controller = recordingController(for: origin)
            controller.presentsErrors = true
            let window = try XCTUnwrap(controller.window)
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
                controller.close()
            }
            let consent: NSWindow
            if repairing {
                try FileManager.default.removeItem(at: fixture.linked.appendingPathComponent(".git"))
                origin.service.refresh()
                await waitUntil { origin.service.worktrees.contains { $0.hasBrokenLink } }
                let style = try await waitForSheet(in: window, containing: "Absolute Paths")
                window.endSheet(style, returnCode: .alertFirstButtonReturn)
                consent = try await waitForSheet(in: window, containing: "Reclaim")
            } else {
                try FileManager.default.removeItem(at: fixture.linked)
                controller.pruneWorktrees(nil)
                consent = try await waitForSheet(in: window, containing: "Prune these worktrees?")
            }
            let capturedExecutable = try WorktreeFileFingerprint.capture(path: executable.path)
            var observedCapabilityLoss = false
            let availability = origin.service.observe(\.isSupported) { service, _ in
                // swift6-safety-justification: This service publishes capability KVO on the main actor.
                MainActor.assumeIsolated {
                    if !service.isSupported {
                        observedCapabilityLoss = true
                    }
                }
            }
            defer { availability.invalidate() }
            // Replace the actual selected executable at the same preference path.
            // No preference notification or separate refresh precedes this click.
            try writeGitProxy(at: executable, generation: "after-upgrade")
            XCTAssertNotEqual(try WorktreeFileFingerprint.capture(path: executable.path), capturedExecutable)
            window.endSheet(consent, returnCode: .alertFirstButtonReturn)
            await waitUntil { observedCapabilityLoss && origin.service.isSupported }
            let following = try await installService(in: fixture, executable: executable)
            let progressed = expectation(description: "capability rejection releases the shared FIFO")
            enqueuePreview(following.service) { preview, error in
                XCTAssertNil(error)
                XCTAssertNotNil(preview)
                if let preview {
                    following.service.discardPrunePreview(preview)
                }
                progressed.fulfill()
            }
            await fulfillment(of: [progressed], timeout: 15)
            await waitUntil { controller.errors.count == 1 }
            let error = try XCTUnwrap(controller.errors.first)
            XCTAssertTrue(error.localizedFailureReason?.contains("selected Git") == true, "Expected actionable capability-change guidance: \(error)")
            let errorSheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertTrue(sheetText(errorSheet).contains("selected Git"))
            try attachScreenshot(of: errorSheet, named: repairing ? "Worktrees-Reclaim-Git-Upgrade-Error" : "Worktrees-Prune-Git-Upgrade-Error")
            XCTAssertFalse(origin.gate.commands.contains { $0 == WorktreeCommand.prune.arguments || $0.starts(with: ["worktree", "repair"]) })
            XCTAssertEqual(try fixture.registrationProof(at: administrative), protected)
            XCTAssertEqual(try fixture.git(["show-ref", "--head"]), refs)
            XCTAssertEqual(try Data(contentsOf: fixture.main.appendingPathComponent("content.txt")), mainContent)
            if repairing {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.appendingPathComponent(".git").path))
                XCTAssertEqual(try Data(contentsOf: fixture.linked.appendingPathComponent("content.txt")), linkedContent)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
            }
            window.endSheet(errorSheet, returnCode: .alertFirstButtonReturn)
            await waitUntil { window.attachedSheet == nil }
            XCTAssertEqual(controller.errors.count, 1)
        }

        private func writeGitProxy(at path: URL, generation: String) throws {
            try ("#!/bin/sh\n# " + generation + "\nexec /usr/bin/git \"$@\"\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        private func queuedCancellation(closesAndReopensWindow: Bool) async throws {
            selectGit()
            let fixture = try makeFixture()
            let blocker = try await installService(in: fixture, holdsWriter: true)
            let origin = try await installService(in: fixture)
            let following = try await installService(in: fixture)
            let controller = recordingController(for: origin)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            let initial = try fixture.ownershipProof()
            let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
            let item = NSMenuItem(); item.representedObject = tree
            let blockerCompleted = expectation(description: "barrier writer completed")
            let followingCompleted = expectation(description: "writer after cancelled UI action completed")
            enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in
                XCTAssertNil(error); blockerCompleted.fulfill()
            }
            XCTAssertTrue(blocker.gate.writer.isPending)
            controller.unlockWorktree(item)
            enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
                XCTAssertNil(error); followingCompleted.fulfill()
            }
            if closesAndReopensWindow {
                controller.close()
                window.makeKeyAndOrderFront(nil)
                XCTAssertTrue(controller.window === window)
                XCTAssertTrue(window.isVisible)
            } else {
                origin.service.cancel()
                XCTAssertTrue(window.isVisible)
            }
            _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
            blocker.gate.writer.finish(Data())
            await fulfillment(of: [blockerCompleted, followingCompleted], timeout: 15)
            XCTAssertEqual(controller.errors.count, 0)
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(origin.gate.commands.contains(["worktree", "unlock", tree.path]))
            XCTAssertEqual(try fixture.ownershipProof(), initial)
            XCTAssertEqual(following.service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
        }

        private enum HiddenPruneFailurePhase: CaseIterable { case prepare, confirm }

        private enum OwnerReplacement: CaseIterable { case repository, repositoryThroughNil, window, windowThroughNil, document }

        private func replaceAndRestore(_ replacement: OwnerReplacement, controller: PBGitWindowController, origin: InstalledService, alternative: InstalledService, window: NSWindow) {
            switch replacement {
            case .repository:
                controller.repository = alternative.repository
                controller.repository = origin.repository
            case .repositoryThroughNil:
                controller.repository = nil
                controller.repository = origin.repository
            case .windowThroughNil:
                controller.window = nil
                controller.window = window
            case .document:
                let replacementDocument = PBGitRepositoryDocument()
                replacementDocument.setValue(origin.repository, forKey: "repository")
                controller.document = replacementDocument
                controller.document = nil
                withExtendedLifetime(replacementDocument) {}
            case .window:
                let replacementWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
                controller.window = replacementWindow
                controller.window = window
                replacementWindow.close()
            }
            XCTAssertTrue(controller.repository === origin.repository)
            XCTAssertTrue(controller.window === window)
        }

        private struct MovedRepairJourney {
            let fixture: Fixture
            let blocker: InstalledService
            let origin: InstalledService
            let following: InstalledService
            let controller: RecordingWindowController
            let window: NSWindow
            let style: NSWindow
            let tree: PBGitWorktree
            let administrative: URL
            let payload: [String: Data]
        }

        private func movedRepairJourney(selectedGitProxy: Bool = false) async throws -> MovedRepairJourney {
            let fixture = try makeFixture(nested: true)
            do {
                let administrativeName = try fixture.administrativeDirectory().lastPathComponent
                try Data("staged data survives repair overlap\n".utf8).write(to: fixture.linked.appendingPathComponent("overlap-canary.txt"))
                _ = try fixture.git(["add", "--", "overlap-canary.txt"], in: fixture.linked)
                try fixture.moveRoot()
                let administrative = fixture.main.appendingPathComponent(".git/worktrees").appendingPathComponent(administrativeName)
                let payload = try fixture.repairPayloadProof(at: administrative)
                let records = try WorktreeParser.parse(Data(fixture.git(["worktree", "list", "--porcelain", "-z"]).utf8))
                let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: fixture.main.appendingPathComponent(".git").path, currentPath: fixture.main.path)
                let target = try XCTUnwrap(inspected.first { $0.branchRefName == "refs/heads/topic" })
                XCTAssertEqual(target.movedPath.map(WorktreePaths.canonical), WorktreePaths.canonical(fixture.linked.path))
                XCTAssertTrue(WorktreeLinkInspector.canRepair(target, at: fixture.linked.path, commonDirectory: fixture.main.appendingPathComponent(".git").path), "The real moved link must be proven, so this journey needs no Reclaim approval")
                let executable: URL?
                if selectedGitProxy {
                    let proxy = fixture.root.appendingPathComponent("selected-git")
                    try writeGitProxy(at: proxy, generation: "before-pending-error")
                    UserDefaults.standard.set(proxy.path, forKey: "gitExecutable")
                    executable = proxy
                } else {
                    executable = nil
                }
                let blocker = try await installService(in: fixture, holdsWriter: true, executable: executable)
                let origin = try await installService(in: fixture, executable: executable)
                let following = try await installService(in: fixture, executable: executable)
                let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
                let controller = recordingController(for: origin)
                do {
                    let window = try XCTUnwrap(controller.window)
                    let style = try await waitForSheet(in: window, containing: "Absolute Paths")
                    return MovedRepairJourney(fixture: fixture, blocker: blocker, origin: origin, following: following,
                                              controller: controller, window: window, style: style, tree: tree,
                                              administrative: administrative, payload: payload)
                } catch {
                    controller.close()
                    throw error
                }
            } catch {
                fixture.cancelServices()
                throw error
            }
        }

        private func unrelatedSheet(on window: NSWindow) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = "Unrelated inspector keeps its own sheet"
            alert.addButton(withTitle: "Close Inspector")
            alert.beginSheetModal(for: window) { _ in }
            XCTAssertTrue(window.attachedSheet === alert.window)
            return alert
        }

        private func assertRepairedJourney(_ journey: MovedRepairJourney, relative: Bool) throws {
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
            let resolved = try journey.fixture.git(["rev-parse", "--absolute-git-dir"], in: journey.fixture.linked).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(WorktreePaths.canonical(resolved), WorktreePaths.canonical(journey.administrative.path))
            let gitfile = try String(contentsOf: journey.fixture.linked.appendingPathComponent(".git"), encoding: .utf8)
            XCTAssertEqual(gitfile.hasPrefix("gitdir: /"), !relative)
            let backlink = try String(contentsOf: journey.administrative.appendingPathComponent("gitdir"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let backlinkPath = (backlink as NSString).isAbsolutePath ? backlink : journey.administrative.appendingPathComponent(backlink).path
            XCTAssertEqual(WorktreePaths.canonical(backlinkPath), WorktreePaths.canonical(journey.fixture.linked.appendingPathComponent(".git").path))
            XCTAssertFalse(journey.origin.service.worktrees.contains { $0.hasBrokenLink })
        }

        private func approveChosenRepair(_ journey: MovedRepairJourney) async throws {
            let consent = try await waitForSheet(in: journey.window, containing: "Repair these worktree links?")
            XCTAssertFalse(journey.origin.gate.commands.contains { $0.starts(with: ["worktree", "repair"]) }, "Style choice cannot authorize a write")
            XCTAssertTrue(sheetText(consent).contains(WorktreePaths.canonical(journey.fixture.main.path)))
            XCTAssertTrue(sheetText(consent).contains(WorktreePaths.canonical(journey.fixture.linked.path)))
            XCTAssertEqual(consent.defaultButtonCell?.title, "Cancel")
            try attachScreenshot(of: consent, named: "Worktrees-Repair-Exact-Scope-Default-Cancel")
            journey.window.endSheet(consent, returnCode: .alertFirstButtonReturn)
        }

        private func assertFollowingPreviewProgresses(_ journey: MovedRepairJourney) async throws {
            let progressed = expectation(description: "following preview confirms the shared writer was released")
            enqueuePreview(journey.following.service) { preview, error in
                XCTAssertNil(error)
                XCTAssertNotNil(preview)
                if let preview {
                    journey.following.service.discardPrunePreview(preview)
                }
                progressed.fulfill()
            }
            await fulfillment(of: [progressed], timeout: 15)
            XCTAssertEqual(try journey.fixture.repairPayloadProof(at: journey.administrative), journey.payload)
        }

        private func cleanupRepairPresentation(controller: RecordingWindowController, fixture: Fixture) async {
            if let window = controller.window {
                while let sheet = window.attachedSheet {
                    let ended = XCTNSNotificationExpectation(name: NSWindow.didEndSheetNotification, object: window)
                    if let panel = sheet as? NSSavePanel {
                        panel.cancel(nil)
                    } else {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                    let result = await XCTWaiter.fulfillment(of: [ended], timeout: 15)
                    XCTAssertEqual(result, .completed, "A native sheet must finish before its fixture is removed")
                    guard result == .completed else { return }
                    await drainCallbacks()
                }
            }
            controller.close()
            await cleanupFixture(fixture)
        }

        private func makeFixture(nested: Bool = false) throws -> Fixture {
            preserveGitPreferenceUntilTeardown()
            let fixture = try Fixture(nested: nested)
            addTeardownBlock { @MainActor in
                await self.cleanupFixture(fixture)
            }
            return fixture
        }

        @discardableResult
        private func cleanupFixture(_ fixture: Fixture) async -> Bool {
            guard !fixture.retainedAfterDrainFailure else { return false }
            let services = fixture.cancelServices()
            if !services.isEmpty {
                let drained = XCTestExpectation(description: "cancelled worktree services acknowledged all fixture I/O")
                drained.expectedFulfillmentCount = services.count
                services.forEach { $0.drainForTesting { drained.fulfill() } }
                let result = await XCTWaiter.fulfillment(of: [drained], timeout: 15)
                guard result == .completed else {
                    fixture.retainedAfterDrainFailure = true
                    XCTFail("Worktree fixture did not drain; preserving files at " + fixture.root.path)
                    return false
                }
            }
            await drainCallbacks()
            fixture.services.removeAll()
            fixture.retiredServices.removeAll()
            if !drainedFixtures.contains(where: { $0 === fixture }) {
                drainedFixtures.append(fixture)
            }
            return true
        }

        private func recordingController(for origin: InstalledService) -> RecordingWindowController {
            let controller = RecordingWindowController()
            controller.presentsErrors = false
            controller.repository = origin.repository
            controller.showWindow(nil)
            return controller
        }

        private final class GitPreferenceRestoration {
            let previous = UserDefaults.standard.object(forKey: "gitExecutable")

            func restore() {
                UserDefaults.standard.set(previous, forKey: "gitExecutable")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            }
        }

        private func preserveGitPreferenceUntilTeardown() {
            guard gitPreferenceRestoration == nil else { return }
            let restoration = GitPreferenceRestoration()
            gitPreferenceRestoration = restoration
            // Registered once, before fixtures: drain all services, restore, then delete.
            addTeardownBlock { @MainActor in
                self.beforeGitPreferenceRestoration?()
                restoration.restore()
                let drained = self.drainedFixtures
                self.drainedFixtures.removeAll()
                for fixture in drained where !fixture.retainedAfterDrainFailure {
                    fixture.removeFiles()
                }
                self.gitPreferenceRestoration = nil
            }
        }

        private func selectGit() {
            preserveGitPreferenceUntilTeardown()
            UserDefaults.standard.set("/usr/bin/git", forKey: "gitExecutable")
        }

        private func waitForSheet(in window: NSWindow, containing title: String) async throws -> NSWindow {
            await waitUntil { window.attachedSheet.map { self.sheetText($0).contains(title) || self.descendants($0.contentView).contains { ($0 as? NSButton)?.title == title } } == true }
            return try XCTUnwrap(window.attachedSheet)
        }

        private func drainCallbacks() async {
            for _ in 0 ..< 3 {
                let drained = expectation(description: "deferred worktree callback turn")
                DispatchQueue.main.async { drained.fulfill() }
                await fulfillment(of: [drained], timeout: 5)
            }
        }

        private func enqueuePreview(_ service: PBRepositoryWorktreeService, completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void) {
            service.preparePrunePreview { preview, error in
                // swift6-safety-justification: The service delivers preview completion on the main queue.
                MainActor.assumeIsolated { completion(preview, error as NSError?) }
            }
        }

        private func enqueue(_ service: PBRepositoryWorktreeService, command: WorktreeCommand, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
            switch command {
            case let .lock(path, reason):
                service.lockWorktree(path: path, reason: reason) { output, error in
                    // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                    MainActor.assumeIsolated { completion(output, error as NSError?) }
                }
            case let .unlock(path):
                service.unlockWorktree(path: path) { output, error in
                    // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
                    MainActor.assumeIsolated { completion(output, error as NSError?) }
                }
            default:
                XCTFail("These tests enqueue lock and unlock through public compatibility facades")
                completion(nil, NSError(domain: "WorktreePresentationFixture", code: 1))
            }
        }

        private func installService(in fixture: Fixture, holdsWriter: Bool = false, executable: URL? = nil) async throws -> InstalledService {
            let repository = try RepositoryTestGitRepository(url: fixture.main)
            let original = try XCTUnwrap(repository.worktreeService)
            fixture.retiredServices.append(original)
            original.cancel()
            let gate = TaskGate(fixture: fixture, holdsWriter: holdsWriter, executable: executable?.path ?? "/usr/bin/git")
            let service = PBRepositoryWorktreeService(repository: repository, taskFactory: gate.makeTask)
            repository.setValue(service, forKey: "worktreeService")
            XCTAssertTrue(repository.worktreeService === service)
            let installed = InstalledService(repository: repository, service: service, gate: gate)
            fixture.services.append(installed)
            service.start()
            await waitUntil { service.isSupported && !service.worktrees.isEmpty }
            return installed
        }

        private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(condition(), file: file, line: line)
        }

        private func sheetText(_ sheet: NSWindow) -> String {
            descendants(sheet.contentView).compactMap { view in
                if let field = view as? NSTextField {
                    return field.stringValue
                }
                return (view as? NSTextView)?.string
            }.joined(separator: "\n")
        }

        private func descendants(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { descendants($0) }
        }

        /// AppKit creates KVO subclasses when ordering this window. The existing
        /// Objective-C base separates the imported mirror from the Swift layout.
        private final class RecordingWindowController: PBHistoryWindowControllerTestBase {
            private(set) var errors: [NSError] = []
            private(set) var loadWindowCount = 0
            var presentsErrors = true

            override func loadWindow() {
                loadWindowCount += 1
                super.loadWindow()
            }

            override func showErrorSheet(_ error: Error) {
                NSLog("[GitXTest] Recorded worktree presentation error: %@", String(describing: error as NSError))
                errors.append(error as NSError)
                if presentsErrors {
                    super.showErrorSheet(error)
                }
            }
        }

        private struct InstalledService {
            let repository: RepositoryTestGitRepository
            let service: PBRepositoryWorktreeService
            let gate: TaskGate
        }

        private final class TaskGate {
            private let mainDirectory: URL
            private let barrierPath: String
            let writer = DeferredWriterTask()
            private var holdsWriter: Bool
            private let executable: String
            var holdNextArguments: [String]?
            private(set) var commands: [[String]] = []

            @MainActor
            init(fixture: Fixture, holdsWriter: Bool, executable: String) {
                mainDirectory = fixture.main
                barrierPath = fixture.linked.path
                self.holdsWriter = holdsWriter
                self.executable = executable
            }

            func makeTask(_ arguments: [String]) -> PBTask {
                commands.append(arguments)
                if holdNextArguments == arguments {
                    holdNextArguments = nil
                    return writer
                }
                if holdsWriter, arguments == ["worktree", "lock", "--reason", "barrier", barrierPath] {
                    holdsWriter = false
                    return writer
                }
                let task = PBTask(launchPath: executable, arguments: ["--git-dir=" + mainDirectory.appendingPathComponent(".git").path] + arguments, inDirectory: mainDirectory.path)
                GitXTestGitFixture.prepare(task)
                return task
            }
        }

        // swift6-safety-justification: The lock guards callback and cancellation state shared with PBTask's callback queues.
        private final nonisolated class DeferredWriterTask: PBTask, @unchecked Sendable {
            private let lock = NSLock()
            private var callback: ((Data?, Error?) -> Void)?
            private var cancelled = false

            override func perform(on _: DispatchQueue, completionHandler: @escaping (Data?, Error?) -> Void) {
                lock.lock(); callback = completionHandler; lock.unlock()
            }

            override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
                lock.lock(); callback = completionHandler; lock.unlock()
            }

            override func terminate() {
                lock.lock(); cancelled = true; lock.unlock()
            }

            var wasCancelled: Bool {
                lock.lock(); defer { lock.unlock() }; return cancelled
            }

            var isPending: Bool {
                lock.lock(); defer { lock.unlock() }; return callback != nil
            }

            func finish(_ data: Data?, error: Error? = nil) {
                lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
                callback?(data, error)
            }
        }

        @MainActor
        private final class Fixture {
            private(set) var root: URL
            private(set) var main: URL
            private(set) var linked: URL
            var services: [InstalledService] = []
            var retiredServices: [PBRepositoryWorktreeService] = []
            var retainedAfterDrainFailure = false

            init(nested: Bool = false) throws {
                root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-presentation-\(UUID().uuidString)")
                main = root.appendingPathComponent("main")
                linked = nested ? main.appendingPathComponent("nested") : root.appendingPathComponent("linked")
                try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
                _ = try git(["init", "-b", "main"])
                _ = try git(["config", "user.name", "Presentation Fixture"])
                _ = try git(["config", "user.email", "fixture@gitx.invalid"])
                try "original\n".write(to: main.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
                _ = try git(["add", "content.txt"])
                _ = try git(["commit", "-m", "fixture"])
                _ = try git(["worktree", "add", "-b", "topic", linked.path])
                _ = try git(["worktree", "lock", linked.path])
            }

            @discardableResult
            func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
                try GitXTestGitFixture.run(arguments, in: directory ?? main).standardOutput
            }

            func gitFailure(_ arguments: [String]) throws -> (data: Data, error: NSError) {
                let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: main.path)
                GitXTestGitFixture.prepare(task)
                do {
                    try task.launch()
                } catch {
                    return (task.standardOutputData, error as NSError)
                }
                throw NSError(domain: "WorktreePresentationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a real Git failure"])
            }

            func pruneReport() throws -> Data {
                let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + main.appendingPathComponent(".git").path] + WorktreeCommand.pruneReport.arguments, inDirectory: main.path)
                GitXTestGitFixture.prepare(task)
                // Match the service's merged lifecycle stream: prune reports on stderr.
                task.separatesStandardError = false
                task.additionalEnvironment = ["LC_ALL": "C"]
                task.timeout = 10
                try task.launch()
                return task.standardOutputData
            }

            func administrativeDirectory() throws -> URL {
                try URL(fileURLWithPath: git(["rev-parse", "--absolute-git-dir"], in: linked).trimmingCharacters(in: .whitespacesAndNewlines))
            }

            func moveRoot() throws {
                let moved = root.appendingPathExtension("moved")
                let mainRelativePath = String(main.path.dropFirst(root.path.count + 1))
                let linkedRelativePath = String(linked.path.dropFirst(root.path.count + 1))
                try FileManager.default.moveItem(at: root, to: moved)
                root = moved
                main = moved.appendingPathComponent(mainRelativePath)
                linked = moved.appendingPathComponent(linkedRelativePath)
            }

            func repairPayloadProof(at administrative: URL, includingLock: Bool = true) throws -> [String: Data] {
                var proof = try Dictionary(uniqueKeysWithValues: (["HEAD", "index"] + (includingLock ? ["locked"] : [])).map {
                    try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
                })
                for name in ["HEAD", "index"] {
                    proof["main/" + name] = try Data(contentsOf: main.appendingPathComponent(".git").appendingPathComponent(name))
                }
                proof["mainContent"] = try Data(contentsOf: main.appendingPathComponent("content.txt"))
                proof["linkedContent"] = try Data(contentsOf: linked.appendingPathComponent("content.txt"))
                proof["stagedCanary"] = try Data(contentsOf: linked.appendingPathComponent("overlap-canary.txt"))
                proof["refs"] = try Data(git(["show-ref", "--head"]).utf8)
                return proof
            }

            func registrationProof(at administrative: URL) throws -> [String: Data] {
                var proof = try Dictionary(uniqueKeysWithValues: ["HEAD", "index", "gitdir", "commondir"].map {
                    try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
                })
                proof["mainHEAD"] = try Data(git(["rev-parse", "HEAD"]).utf8)
                return proof
            }

            func ownershipProof() throws -> [String: Data] {
                let administrative = try URL(fileURLWithPath: git(["rev-parse", "--absolute-git-dir"], in: linked).trimmingCharacters(in: .whitespacesAndNewlines))
                var proof = try Dictionary(uniqueKeysWithValues: ["HEAD", "index", "gitdir", "commondir"].map {
                    try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
                })
                proof["mainHEAD"] = try Data(git(["rev-parse", "HEAD"]).utf8)
                proof["linkedHEAD"] = try Data(git(["rev-parse", "HEAD"], in: linked).utf8)
                proof["gitfile"] = try Data(contentsOf: linked.appendingPathComponent(".git"))
                proof["content"] = try Data(contentsOf: linked.appendingPathComponent("content.txt"))
                return proof
            }

            @discardableResult
            func cancelServices() -> [PBRepositoryWorktreeService] {
                let draining = retiredServices + services.map(\.service)
                draining.forEach { $0.cancel() }
                services.forEach { $0.gate.writer.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
                return draining
            }

            func removeFiles() {
                try? FileManager.default.removeItem(at: root)
            }
        }
    }

#endif
