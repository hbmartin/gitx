import AppKit
import GitXCore
import XCTest

@MainActor
final class WorktreePresentationTests: XCTestCase {
    func testQueuedGenericGitFailureIsPresentedInItsLiveOriginWindowAndReleasesSharedFIFO() async throws {
        let defaults = UserDefaults.standard
        let previousGit = defaults.object(forKey: "gitExecutable")
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        defer {
            defaults.set(previousGit, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        blockerCompleted.assertForOverFulfill = true
        let followingCompleted = expectation(description: "following real writer reconciled")
        followingCompleted.assertForOverFulfill = true
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
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        for usesDocument in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
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
            completed.assertForOverFulfill = true
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
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        completed.assertForOverFulfill = true
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
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        for replacement in OwnerReplacement.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
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
            completed.assertForOverFulfill = true
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

    func testDeferredRemoveAnywayConfirmationLosesAuthorityAfterOwnerReplacementAndRestoration() async throws {
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        completed.assertForOverFulfill = true
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
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        completed.assertForOverFulfill = true
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

    func testHiddenPruneOwnerDiscardsRealPreviewFailuresAndReleasesTheSharedQueue() async throws {
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        for phase in HiddenPruneFailurePhase.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
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
            completed.assertForOverFulfill = true
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
            XCTAssertEqual(controller.errors.count, 0, "A hidden prune owner displayed its \(phase) failure")
            XCTAssertNil(window.attachedSheet)
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
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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

    private func queuedCancellation(closesAndReopensWindow: Bool) async throws {
        let previousGit = selectGit()
        defer { restoreGit(previousGit) }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        blockerCompleted.assertForOverFulfill = true
        followingCompleted.assertForOverFulfill = true
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

    private func recordingController(for origin: InstalledService) -> RecordingWindowController {
        let controller = RecordingWindowController()
        controller.presentsErrors = false
        controller.repository = origin.repository
        controller.showWindow(nil)
        return controller
    }

    private func selectGit() -> Any? {
        let previous = UserDefaults.standard.object(forKey: "gitExecutable")
        UserDefaults.standard.set("/usr/bin/git", forKey: "gitExecutable")
        return previous
    }

    private func restoreGit(_ previous: Any?) {
        UserDefaults.standard.set(previous, forKey: "gitExecutable")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
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
        default: XCTFail("These tests enqueue lock and unlock through public compatibility facades")
        }
    }

    private func installService(in fixture: Fixture, holdsWriter: Bool = false) async throws -> InstalledService {
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let original = try XCTUnwrap(repository.worktreeService)
        original.cancel()
        let gate = TaskGate(fixture: fixture, holdsWriter: holdsWriter)
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
        let fixture: Fixture
        let writer = DeferredWriterTask()
        private var holdsWriter: Bool
        var holdNextArguments: [String]?
        private(set) var commands: [[String]] = []

        init(fixture: Fixture, holdsWriter: Bool) {
            self.fixture = fixture
            self.holdsWriter = holdsWriter
        }

        func makeTask(_ arguments: [String]) -> PBTask {
            commands.append(arguments)
            if holdNextArguments == arguments {
                holdNextArguments = nil
                return writer
            }
            if holdsWriter, arguments == ["worktree", "lock", "--reason", "barrier", fixture.linked.path] {
                holdsWriter = false
                return writer
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
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
        let root: URL
        let main: URL
        let linked: URL
        var services: [InstalledService] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-presentation-\(UUID().uuidString)")
            main = root.appendingPathComponent("main")
            linked = root.appendingPathComponent("linked")
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

        func cleanup() {
            services.forEach { $0.service.cancel() }
            services.forEach { $0.gate.writer.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
            services.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
