import AppKit
import ForgeKit
@testable import GitX
import XCTest

@MainActor
final class NativeRecoveryMoveTests: XCTestCase {
    private enum Phase { case ready, loading, consent, writing, finalSave, remote, queued }
    @MainActor private final class Owner { var controller: GitX.RepositoryPullRequestUIController? }

    func testMoveDetachesExactRecoveredTextAndCanSaveToOriginalDraftIdentity() async throws {
        try await exerciseMove(.ready)
    }

    func testMovePreservesRecoveryLoadAndOriginalDraftReplacementConsent() async throws {
        try await exerciseMove(.loading)
    }

    func testMovePreservesVisibleReplacementConsentAndExactlyOneWrite() async throws {
        try await exerciseMove(.consent)
    }

    func testMovePreservesAdmittedRecoveryWriteAndRecordsItsResult() async throws {
        try await exerciseMove(.writing)
    }

    func testMoveDuringFinalPersistenceRetainsUnsentTextWithoutRemoteAdmission() async throws {
        try await exerciseMove(.finalSave)
    }

    func testMoveDuringAdmittedEditRetainsItsLateRecoveryAfterControllerDeallocation() async throws {
        try await exerciseMove(.remote)
    }

    func testMoveMakesQueuedRecoveryAvailableWithoutTheObsoleteEditorSlot() async throws {
        try await exerciseMove(.queued)
    }

    private func exerciseMove(_ phase: Phase) async throws {
        let defaults = UserDefaults.standard
        let watcher = defaults.object(forKey: "PBUseRepositoryWatcher")
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        let fixture = try PullRequestAppFixture()
        let local = try LocalPullRequestRepositoryFixture(remoteURL: "https://github.com/contributor/gitx.git")
        let document = try GitX.PBGitRepositoryDocument(contentsOf: local.directory, ofType: PBGitRepositoryDocumentType)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let owner = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        owner.showWindow(nil)
        let window = try XCTUnwrap(owner.window)
        let repository = try XCTUnwrap(document.repository)
        let store = CompletionDraftStore()
        let loadGate = IgnoringCancellationGate<Bool>()
        let writeGate = IgnoringCancellationGate<Bool>()
        let finalGate = IgnoringCancellationGate<Bool>()
        let started = XCTestExpectation(description: "Original edit is admitted")
        let service = NativePullRequestMutationService(started: phase == .finalSave ? nil : started)
        let snapshot = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(42), title: "Original draft", bodyMarkdown: "Original durable body", updatedAt: .distantPast)
        let destination = ForgeDestination.pullRequest(fixture.repository, snapshot.number)
        let outcome = GitX.RepositoryPullRequestEditOutcome(snapshot: snapshot, destination: destination)
        let identity = try GitX.RepositoryPullRequestDraftPolicy.editIdentity(accountID: fixture.accountID, snapshot: snapshot)
        let exact = ForgeDraftContent(title: "Recovered title — original account", body: "Exact recovered text\nline two\t☃")
        try await store.save(identity: identity, content: ForgeDraftContent(title: snapshot.title, body: snapshot.bodyMarkdown), at: snapshot.updatedAt)
        let holder = Owner()
        holder.controller = GitX.RepositoryPullRequestUIController(repository: repository, windowController: owner,
                                                                   ownerIsCurrent: owner.repositoryPresentationValidation(for: repository),
                                                                   remoteActions: GitX.RepositoryRemoteActionCoordinator(repository: repository, windowController: owner),
                                                                   service: service, drafts: NativeCompletionDraftStore(store: store), destinationOpening: { _ in XCTFail("An obsolete destination cannot reopen"); return false }, bindingResolving: { nil }, postPushBrowserFallback: { _ in })
        let moved = local.directory.appendingPathExtension("moved")
        addTeardownBlock { @MainActor [self] in
            await loadGate.release(true); await writeGate.release(true); await finalGate.release(true)
            await service.releaseEdit(outcome); await store.releaseSaveWaiters()
            holder.controller?.invalidateOwner(); holder.controller = nil
            for panel in NSApp.windows where panel.isVisible && panel.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery" {
                if let close = panel.contentView.flatMap({ self.find("GitX.PullRequest.Recovery.Close", in: $0) }) as? NSButton {
                    close.performClick(nil)
                    if let confirmation = panel.attachedSheet, let discard = confirmation.contentView.flatMap({ self.button("Close Without Saving", in: $0) }) {
                        discard.performClick(nil)
                    }
                }
            }
            owner.close(); document.close()
            for repo in [repository, local.repository] {
                repo.revisionList?.cleanup()
                let worktrees = repo.worktreeService
                worktrees.cancel()
                #if DEBUG
                    let drained = XCTestExpectation(description: "Moved fixture work drains")
                    worktrees.drainForTesting { drained.fulfill() }
                    await self.fulfillment(of: [drained], timeout: 15)
                #endif
            }
            local.cleanup(); try? FileManager.default.removeItem(at: moved)
            defaults.set(watcher, forKey: "PBUseRepositoryWatcher")
        }
        holder.controller?.editPullRequest(accountID: fixture.accountID, snapshot: snapshot, destination: destination)
        await wait("Original editor", until: { window.attachedSheet != nil })
        let editor = try XCTUnwrap(window.attachedSheet)
        let initialSaved = expectation(description: "Initial editor draft is durable")
        Task { await store.waitForSaves(2); initialSaved.fulfill() }
        await fulfillment(of: [initialSaved], timeout: 5)
        await store.failSaves(true)
        try XCTUnwrap(find("GitX.PullRequest.Title", in: XCTUnwrap(editor.contentView)) as? NSTextField).stringValue = exact.title ?? ""
        try XCTUnwrap(find("GitX.PullRequest.Body", in: XCTUnwrap(editor.contentView)) as? NSTextView).string = exact.body
        let finalStarted = XCTestExpectation(description: "Final save starts")
        if phase == .finalSave {
            await store.holdNextConditionalSave(finalGate, started: finalStarted)
        }
        try XCTUnwrap(find("GitX.PullRequest.Submit", in: XCTUnwrap(editor.contentView)) as? NSButton).performClick(nil)
        let submitted = try XCTUnwrap(holder.controller?.mutationTask)
        if phase == .finalSave {
            await fulfillment(of: [finalStarted], timeout: 5)
        } else {
            await fulfillment(of: [started], timeout: 5)
        }
        var recovered: NSWindow?
        var consent: NSWindow?
        let saveStarted = XCTestExpectation(description: "Recovery persistence begins")
        if phase == .queued {
            await wait("The submitted editor closes", until: { window.attachedSheet == nil })
            let next = try ForgePullRequestEditableSnapshot(repository: fixture.repository, number: ForgeItemNumber(43), title: "Another editor", bodyMarkdown: "Current server text", updatedAt: .distantPast)
            holder.controller?.editPullRequest(accountID: fixture.accountID, snapshot: next, destination: .pullRequest(fixture.repository, next.number))
            await wait("A newer editor owns the old sheet slot", until: { window.attachedSheet != nil })
            let occupied = try XCTUnwrap(window.attachedSheet)
            await service.releaseEdit(outcome); await submitted.value
            XCTAssertTrue(window.attachedSheet === occupied)
            XCTAssertNil(try find("GitX.PullRequest.Recovery.Copy", in: XCTUnwrap(occupied.contentView)))
        }
        if phase != .finalSave && phase != .remote && phase != .queued {
            await service.releaseEdit(outcome); await submitted.value
            await wait("Exact recovery is presented", until: {
                window.attachedSheet?.contentView.flatMap { self.find("GitX.PullRequest.Recovery.Copy", in: $0) } != nil
            })
            recovered = window.attachedSheet
            await store.failSaves(false)
            if phase == .loading {
                await store.holdNextLoad(loadGate, started: saveStarted)
            }
            if phase == .writing {
                await store.holdNextConditionalSave(writeGate, started: saveStarted)
            }
            if phase != .ready {
                try XCTUnwrap(find("GitX.PullRequest.Recovery.SaveDraft", in: XCTUnwrap(recovered?.contentView)) as? NSButton).performClick(nil)
                if phase == .loading {
                    await fulfillment(of: [saveStarted], timeout: 5)
                } else {
                    await wait("Original draft replacement consent", until: { recovered?.attachedSheet != nil })
                    consent = recovered?.attachedSheet
                    if phase == .writing {
                        try XCTUnwrap(button("Replace Draft", in: XCTUnwrap(consent?.contentView))).performClick(nil)
                        await fulfillment(of: [saveStarted], timeout: 5)
                    }
                }
            }
        }
        weak let releasedController = holder.controller
        try FileManager.default.moveItem(at: local.directory, to: moved)
        document.presentedItemDidMove(to: moved)
        await wait("Obsolete document closes after recovery transfer", until: { !NSDocumentController.shared.documents.contains { $0 === document } })
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
        guard !NSDocumentController.shared.documents.contains(where: { $0 === document }) else { return }
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0 === document })
        XCTAssertFalse(window.isVisible)
        holder.controller = nil
        XCTAssertNil(releasedController, "The recovery session, not the obsolete controller, owns pending work")
        await finalGate.release(true)
        if phase == .remote {
            await service.releaseEdit(outcome)
        }
        await submitted.value
        if phase == .finalSave || phase == .remote || phase == .queued {
            await wait("Late recovery becomes standalone", until: { NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery" } })
            recovered = NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "GitX.PullRequest.DetachedRecovery" }
            await store.failSaves(false)
        }
        let standalone = try XCTUnwrap(recovered)
        XCTAssertTrue(standalone.isVisible)
        XCTAssertNil(standalone.sheetParent)
        XCTAssertEqual(standalone.accessibilityIdentifier(), "GitX.PullRequest.DetachedRecovery")
        XCTAssertEqual(try (find("GitX.PullRequest.Title", in: XCTUnwrap(standalone.contentView)) as? NSTextField)?.stringValue, exact.title)
        XCTAssertEqual(try (find("GitX.PullRequest.Body", in: XCTUnwrap(standalone.contentView)) as? NSTextView)?.string, exact.body)
        if phase == .consent {
            XCTAssertTrue(standalone.attachedSheet === consent, "Moving must preserve the existing replacement choice")
        }
        if phase == .loading {
            await loadGate.release(true)
            await wait("Load completes into standalone replacement consent", until: { standalone.attachedSheet != nil })
            consent = standalone.attachedSheet
        }
        if phase == .ready || phase == .finalSave || phase == .remote || phase == .queued {
            try XCTUnwrap(find("GitX.PullRequest.Recovery.SaveDraft", in: XCTUnwrap(standalone.contentView)) as? NSButton).performClick(nil)
            await wait("Standalone uses original draft identity", until: { standalone.attachedSheet != nil })
            consent = standalone.attachedSheet
        }
        if phase != .writing {
            try XCTUnwrap(button("Replace Draft", in: XCTUnwrap(consent?.contentView))).performClick(nil)
        }
        await writeGate.release(true)
        await wait("Admitted save is recorded in standalone recovery", until: {
            (standalone.contentView.flatMap { self.find("GitX.PullRequest.Recovery.Notice", in: $0) } as? NSTextField)?.stringValue.hasPrefix("Saved as a draft") == true
        })
        let durable = try await store.load(identity: identity)
        XCTAssertEqual(durable?.content, exact)
        let saves = await store.conditionalSaves
        XCTAssertEqual(saves, 2, "Exactly one final submission save and one recovery write")
        let calls = await service.editCount
        XCTAssertEqual(calls, phase == .finalSave ? 0 : 1)
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0.fileURL == moved }, "Moving cannot silently rebind or reopen")
        try attachScreenshot(of: standalone, named: "Detached recovery preserves exact text and original destination")
        let presenter = try XCTUnwrap(standalone.windowController as? GitX.ForgePullRequestSheetController)
        var copied: ForgeDraftContent?
        presenter.onCopyRecovery = { copied = $0 }
        try XCTUnwrap(find("GitX.PullRequest.Recovery.Copy", in: XCTUnwrap(standalone.contentView)) as? NSButton).performClick(nil)
        XCTAssertEqual(copied, exact, "Copy uses the same exact session content without touching the general pasteboard")
        let close = try XCTUnwrap(find("GitX.PullRequest.Recovery.Close", in: XCTUnwrap(standalone.contentView)) as? NSButton)
        if phase == .ready {
            let body = try XCTUnwrap(find("GitX.PullRequest.Body", in: XCTUnwrap(standalone.contentView)) as? NSTextView)
            body.string = exact.body + "\nA further unsaved detached edit"
            presenter.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
            close.performClick(nil)
            await wait("Further edits retain close protection after saving", until: { standalone.attachedSheet != nil })
            try XCTUnwrap(button("Keep Editing", in: XCTUnwrap(standalone.attachedSheet?.contentView))).performClick(nil)
            XCTAssertTrue(standalone.isVisible)
            XCTAssertEqual(body.string, exact.body + "\nA further unsaved detached edit")
            let stillStored = try await store.load(identity: identity)
            XCTAssertEqual(stillStored?.content, exact)
            close.performClick(nil)
            await wait("Discard is a fresh explicit choice", until: { standalone.attachedSheet != nil })
            try XCTUnwrap(button("Close Without Saving", in: XCTUnwrap(standalone.attachedSheet?.contentView))).performClick(nil)
        } else {
            close.performClick(nil)
        }
        XCTAssertFalse(standalone.isVisible)
    }

    private func wait(_ description: String, until condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { [self] in find(identifier, in: $0) }.first
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        return view.subviews.lazy.compactMap { [self] in button(title, in: $0) }.first
    }
}

struct NativeCompletionDraftStore: GitX.RepositoryPullRequestDraftPersisting {
    let store: CompletionDraftStore
    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft? {
        try await store.load(identity: identity)
    }

    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws {
        try await store.save(identity: identity, content: content, at: date)
    }

    func saveSnapshot(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws -> ForgeDraft? {
        try await store.saveSnapshot(identity: identity, content: content, at: date)
    }

    func saveSnapshot(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date, matching snapshot: ForgeDraft?) async throws -> ForgeDraft? {
        try await store.saveSnapshot(identity: identity, content: content, at: date, matching: snapshot)
    }

    func delete(identity: ForgeDraftIdentity, matching snapshot: ForgeDraft) async throws -> Bool {
        try await store.delete(identity: identity, matching: snapshot)
    }

    func delete(identity: ForgeDraftIdentity) async throws {
        try await store.delete(identity: identity)
    }
}
