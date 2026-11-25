import AppKit
@testable import GitX
import GitXCore
import XCTest

@MainActor
final class ReflogBrowserTests: XCTestCase {
    func testInitialServiceConstructionFailureLeavesTheBrowserIdleAndRefreshable() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: { _ in
            throw NSError(domain: "ReflogConstruction", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot construct a reflog reader"])
        }))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.status, "Cannot construct a reflog reader")
        XCTAssertTrue(try control("Refresh", in: controller, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("Cancel", in: controller, as: NSButton.self).isEnabled)
    }

    func testPageLoadingProtectsItsRequestFromRowSelection() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "reflog")
        defer { try? gate.open() }
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: gate.context)
        }))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        XCTAssertFalse(try control("Events", in: controller, as: NSTableView.self).isEnabled)
        let loading = try XCTUnwrap(controller.operation)
        try gate.open()
        await loading.value
        XCTAssertTrue(try control("Events", in: controller, as: NSTableView.self).isEnabled)
    }

    func testRejectedReaderConstructionDoesNotStrandAnActiveDetailRequest() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "--format=fuller")
        defer { try? gate.open() }
        var constructions = 0
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            constructions += 1
            if constructions == 3 {
                throw NSError(domain: "ReplacementReader", code: 1)
            }
            return try RepositoryReflogService(repository: $0, context: gate.context)
        }))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntilIdle(controller)
        try control("Events", in: controller, as: NSTableView.self).selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let details = try XCTUnwrap(controller.operation)
        controller.refresh(nil)
        XCTAssertTrue(controller.isBusy)
        try gate.open()
        await details.value
        XCTAssertFalse(controller.isBusy, "Rejecting a replacement cannot revoke the preceding request's completion")
        XCTAssertTrue(try control("Details", in: controller, as: NSTextView.self).string.contains("initial"))
    }

    func testIdleRepositoryChangeAutomaticallyRefreshesReferences() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntilIdle(controller)
        try fixture.git(["branch", "external-change"])
        controller.repositoryDidChange()
        let popup = try control("Reference", in: controller, as: NSPopUpButton.self)
        await waitUntil { popup.itemTitles.contains("external-change") }
        XCTAssertTrue(popup.itemTitles.contains("external-change"))
    }

    func testResetModeSheetCannotReplaceAnAutomaticRefresh() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "reflog")
        defer { try? gate.open() }
        var holdRefresh = false
        let browser = try await presentedBrowser(fixture, serviceFactory: { repository in
            try RepositoryReflogService(repository: repository, context: holdRefresh ? gate.context : nil)
        })
        defer { browser.controller.closeView(); browser.window.close() }
        try control("Reset", in: browser.controller, as: NSButton.self).performClick(nil)
        _ = try sheetControl("ResetMode", window: browser.window, as: NSPopUpButton.self)
        holdRefresh = true
        try fixture.git(["branch", "refresh-branch"])
        browser.controller.repositoryDidChange()
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let refresh = try XCTUnwrap(browser.controller.operation)
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        let reset = try control("Reset", in: browser.controller, as: NSButton.self)
        XCTAssertFalse(reset.isEnabled)
        XCTAssertTrue(browser.controller.isBusy)
        try gate.open()
        await refresh.value
        let popup = try control("Reference", in: browser.controller, as: NSPopUpButton.self)
        XCTAssertTrue(popup.itemTitles.contains("refresh-branch"))
        XCTAssertNil(browser.window.attachedSheet)
        XCTAssertTrue(reset.isEnabled)
    }

    func testInvalidatedReadsExplainWhyTheirResultWasDropped() async throws {
        for preview in [false, true] {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let repository = try GitXTestGitRepository(url: fixture.url)
            let command = preview ? "--is-bare-repository" : "--format=fuller"
            let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: command)
            defer { try? gate.open() }
            let refreshDelay = DelayGate()
            var held = false
            let browser = try await presentedBrowser(fixture, serviceFactory: { repository in
                try RepositoryReflogService(repository: repository, context: held ? gate.context : nil)
            }, delay: { _ in await refreshDelay.wait() })
            defer { browser.controller.closeView(); browser.window.close() }
            held = true
            if preview {
                try control("Reset", in: browser.controller, as: NSButton.self).performClick(nil)
                try dismissSheet(browser.window, response: .alertFirstButtonReturn)
            } else {
                // Deselecting preserves the original rows and lets us start a new detail read.
                let table = try control("Events", in: browser.controller, as: NSTableView.self)
                table.deselectAll(nil)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
            let read = try XCTUnwrap(browser.controller.operation)
            browser.controller.repositoryDidChange()
            try gate.open()
            await read.value
            XCTAssertTrue(browser.controller.status?.contains(preview ? "reset preview" : "commit details") == true)
            XCTAssertNil(browser.window.attachedSheet)
            await refreshDelay.release()
            await waitUntil { !browser.controller.isBusy && browser.controller.status?.hasPrefix("1 events") == true }
        }
    }

    func testUnsupportedReferenceIsEscapedAndDisabledWhileHeadRemainsUsable() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let oid = try fixture.git(["rev-parse", "HEAD"])
        var packed = Data("# pack-refs with: peeled fully-peeled sorted\n\(oid) refs/heads/invalid-".utf8)
        packed.append(0xFF)
        packed.append(0x0A)
        try packed.write(to: fixture.url.appendingPathComponent(".git/packed-refs"))
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntilIdle(controller)
        let popup = try control("Reference", in: controller, as: NSPopUpButton.self)
        let unsupported = try XCTUnwrap(popup.itemArray.first { $0.title.contains("unsupported encoding") })
        XCTAssertTrue(unsupported.title.contains("\\xFF"))
        XCTAssertFalse(unsupported.isEnabled)
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        XCTAssertGreaterThan(try control("Events", in: controller, as: NSTableView.self).numberOfRows, 0)
    }

    func testReferencePaginationDiscardsAnInvalidatedPageAndPreservesTheSelection() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        for index in 0 ..< 225 {
            try fixture.git(["commit", "--allow-empty", "-m", "event \(index)"])
        }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "reflog")
        defer { try? gate.open() }
        var held = false
        let pasteboard = NSPasteboard(name: .init("GitX.Reflog.Paging." + UUID().uuidString))
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: held ? gate.context : nil)
        }, pasteboard: pasteboard))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntilIdle(controller)
        let table = try control("Events", in: controller, as: NSTableView.self)
        let popup = try control("Reference", in: controller, as: NSPopUpButton.self)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntilIdle(controller)
        let selected = try fixture.git(["rev-parse", "HEAD"])
        popup.selectItem(withTitle: "main")
        XCTAssertTrue(try NSApp.sendAction(XCTUnwrap(popup.action), to: popup.target, from: popup))
        await waitUntilIdle(controller)
        XCTAssertEqual(table.numberOfRows, 200)
        held = true
        let more = try control("LoadMore", in: controller, as: NSButton.self)
        more.performClick(nil)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let loading = try XCTUnwrap(controller.operation)
        XCTAssertFalse(table.isEnabled)
        try fixture.git(["commit", "--allow-empty", "-m", "external event"])
        try fixture.git(["branch", "external-change"])
        controller.repositoryDidChange()
        XCTAssertEqual(table.numberOfRows, 200)
        try gate.open()
        await loading.value
        await waitUntil { popup.itemTitles.contains("external-change") && !controller.isBusy }
        XCTAssertEqual(table.numberOfRows, 200, "The stale append cannot publish rows before the replacement first page")
        XCTAssertEqual(popup.titleOfSelectedItem, "main")
        try control("Copy", in: controller, as: NSButton.self).performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
        more.performClick(nil)
        await waitUntilIdle(controller)
        XCTAssertEqual(table.numberOfRows, 227)
        XCTAssertFalse(more.isEnabled)
    }

    func testCancellingAReadKeepsOldRowsAndAllowsFreshRecoveryEvidence() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "reflog")
        defer { try? gate.open() }
        var held = false
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: held ? gate.context : nil)
        }))
        defer { controller.closeView() }
        _ = controller.view
        controller.refresh(nil)
        await waitUntilIdle(controller)
        let table = try control("Events", in: controller, as: NSTableView.self)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntilIdle(controller)
        held = true
        controller.refresh(nil)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let loading = try XCTUnwrap(controller.operation)
        try control("Cancel", in: controller, as: NSButton.self).performClick(nil)
        await loading.value
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(try control("Refresh", in: controller, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("Reset", in: controller, as: NSButton.self).isEnabled)
        try gate.open()
        controller.refresh(nil)
        await waitUntilIdle(controller)
        XCTAssertTrue(try control("Reset", in: controller, as: NSButton.self).isEnabled)
    }

    private actor DelayGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
        }
    }

    func testRepositoryEventsCoalesceWithoutErasingVisibleRows() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let delay = DelayGate()
        let scheduled = expectation(description: "Each invalidation schedules a bounded refresh")
        scheduled.expectedFulfillmentCount = 3
        var constructions = 0
        let browser = try await presentedBrowser(fixture, serviceFactory: {
            constructions += 1
            return try RepositoryReflogService(repository: $0)
        }, delay: { duration in
            if duration == .milliseconds(150) {
                scheduled.fulfill(); await delay.wait()
            }
        })
        defer { browser.controller.closeView(); browser.window.close(); Task { await delay.release() } }
        let baseline = constructions
        let table = try control("Events", in: browser.controller, as: NSTableView.self)
        let count = table.numberOfRows
        let subject = try XCTUnwrap(browser.controller.tableView(table, viewFor: nil, row: 0) as? NSTextField)
        XCTAssertEqual(subject.identifier?.rawValue, "subject")
        XCTAssertFalse(subject.stringValue.isEmpty)
        for _ in 0 ..< 3 {
            browser.controller.repositoryDidChange()
            await Task.yield()
        }
        await fulfillment(of: [scheduled], timeout: 5)
        XCTAssertEqual(table.numberOfRows, count)
        XCTAssertFalse(try control("Reset", in: browser.controller, as: NSButton.self).isEnabled)
        XCTAssertEqual(constructions, baseline)
        try attachScreenshot(of: browser.window, named: "Stale reflog rows remain visible while refresh is coalesced")
        await delay.release()
        await waitUntil { constructions == baseline + 1 && !browser.controller.isBusy }
        XCTAssertEqual(constructions, baseline + 1)
        XCTAssertTrue(try control("Reset", in: browser.controller, as: NSButton.self).isEnabled)
    }

    func testLongMutationReportsWaitingWithoutInterruptingGit() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "second\n")
        try fixture.git(["commit", "-am", "second"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: "branch")
        defer { try? gate.open() }
        let delay = DelayGate()
        let scheduled = expectation(description: "Sixty-second progress deadline is scheduled")
        let browser = try await presentedBrowser(fixture, row: 1, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: gate.context)
        }, delay: { duration in
            if duration == .seconds(60) {
                scheduled.fulfill(); await delay.wait()
            }
        })
        defer { browser.controller.closeView(); browser.window.close(); Task { await delay.release() } }
        try control("CreateBranch", in: browser.controller, as: NSButton.self).performClick(nil)
        try sheetControl("BranchName", window: browser.window, as: NSTextField.self).stringValue = "recovery/still-running"
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await fulfillment(of: [scheduled], timeout: 5)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        let mutation = try XCTUnwrap(browser.controller.operation)
        await delay.release()
        await waitUntil { browser.controller.status?.contains("still running") == true }
        XCTAssertTrue(browser.controller.isBusy)
        XCTAssertFalse(try control("Cancel", in: browser.controller, as: NSButton.self).isEnabled)
        try attachScreenshot(of: browser.window, named: "Started recovery mutation reports waiting without a force-stop action")
        try gate.open()
        await mutation.value
        await waitUntilIdle(browser.controller)
        let result = try control("LastResult", in: browser.controller, as: NSTextField.self)
        XCTAssertTrue(result.stringValue.contains("recovery/still-running"))
        let table = try control("Events", in: browser.controller, as: NSTableView.self)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await waitUntilIdle(browser.controller)
        XCTAssertTrue(result.stringValue.contains("recovery/still-running"))
        try attachScreenshot(of: browser.window, named: "Recovery result survives refreshed references and a new detail selection")
    }

    func testClosingAndReleasingBrowserLetsAnAdmittedHardResetFinish() async throws {
        try await exerciseDetachedMutation(mode: .hard)
    }

    func testDetachedBrowserReconcilesSoftAndMixedResetHistory() async throws {
        for mode in [ReflogResetMode.soft, .mixed] {
            try await exerciseDetachedMutation(mode: mode)
        }
    }

    func testDetachedBrowserReconcilesBackupAfterFailedReset() async throws {
        try await exerciseDetachedMutation(mode: .hard, failing: true)
    }

    func testDetachedBrowserReconcilesBranchCreationAndFailure() async throws {
        try await exerciseDetachedMutation(mode: nil)
        try await exerciseDetachedMutation(mode: nil, failing: true)
    }

    private func exerciseDetachedMutation(mode: ReflogResetMode?, failing: Bool = false) async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "second\n")
        try fixture.git(["commit", "-am", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let defaults = UserDefaults.standard
        let previousWatcher = defaults.object(forKey: "PBUseRepositoryWatcher")
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        defer { defaults.set(previousWatcher, forKey: "PBUseRepositoryWatcher") }
        let repository = try GitXTestGitRepository(url: fixture.url)
        XCTAssertFalse(PBGitDefaults.useRepositoryWatcher())
        repository.currentBranchFilter = Int(kGitXSelectedBranchFilter.rawValue)
        repository.currentBranch = repository.branches.first { $0.description == "main" }
        defer { repository.revisionList?.cleanup(); repository.revisionList = nil }
        await waitUntil { (repository.revisionList?.commits.firstObject as? PBGitCommit)?.sha == previous }
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture, command: mode == nil ? "branch" : "reset")
        defer { try? gate.open() }
        var controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: {
            try RepositoryReflogService(repository: $0, context: gate.context)
        })) as ReflogBrowserController?
        weak let released = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller?.closeView(); window.close() }
        window.contentView = try XCTUnwrap(controller).view
        window.makeKeyAndOrderFront(nil)
        controller?.updateView()
        try await waitUntilIdle(XCTUnwrap(controller))
        try control("Events", in: XCTUnwrap(controller), as: NSTableView.self).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntilIdle(XCTUnwrap(controller))
        let branchName = "recovery/detached-browser"
        if let mode {
            _ = try await preview(mode, browser: (controller: XCTUnwrap(controller), window: window, repository: repository))
            try dismissSheet(window, response: .alertFirstButtonReturn)
            if mode == .hard {
                await waitUntil { self.sheetButton("Discard Changes and Reset", window: window) != nil }
                try dismissSheet(window, response: .alertSecondButtonReturn)
            }
        } else {
            try control("CreateBranch", in: XCTUnwrap(controller), as: NSButton.self).performClick(nil)
            try sheetControl("BranchName", window: window, as: NSTextField.self).stringValue = branchName
            try dismissSheet(window, response: .alertFirstButtonReturn)
        }
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        if failing {
            if mode != nil {
                try fixture.write(".git/index.lock", "hold the index")
            } else {
                try fixture.git(["branch", branchName, previous])
            }
        }
        let reconciliation = repository.observe(\.refs) { _, _ in
            XCTAssertTrue(GitX.RepositoryLocalMutationRegistry.shared.hasActivity, "Quit must retain the started mutation through original-repository reconciliation")
        }
        defer { reconciliation.invalidate() }
        let admitted = try XCTUnwrap(controller?.operation)
        controller?.closeView()
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        controller = nil
        try gate.open()
        await admitted.value
        reconciliation.invalidate()
        let expectedHead = mode == nil || failing ? previous : target
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), expectedHead)
        if mode != nil {
            XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
            XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), mode == .hard && !failing ? "initial\n" : "second\n")
        } else {
            XCTAssertEqual(try fixture.git(["rev-parse", branchName]), failing ? previous : target)
        }
        XCTAssertTrue(repository.branches.contains { $0.description?.hasPrefix("recovery/") == true }, "The surviving repository publishes refs even after browser closure or mutation failure")
        await waitUntil { (repository.revisionList?.commits.firstObject as? PBGitCommit)?.sha == expectedHead }
        await waitUntil { released == nil }
        XCTAssertNil(released)
    }

    func testUnsafeResetDisplaysTheObservedHeadAndValidatedBackup() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.git(["commit", "--allow-empty", "-m", "validated preview"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
        defer { try? gate.open() }
        let browser = try await presentedBrowser(fixture, row: 1, serviceFactory: { try RepositoryReflogService(repository: $0, context: gate.context) })
        defer { browser.controller.closeView(); browser.window.close() }
        _ = try await preview(.soft, browser: browser)
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { FileManager.default.fileExists(atPath: gate.started.path) }
        try fixture.git(["commit", "--allow-empty", "-m", "external writer"])
        let observed = try fixture.git(["rev-parse", "HEAD"])
        try gate.open()
        await waitUntilIdle(browser.controller)
        let message = try control("Details", in: browser.controller, as: NSTextView.self).string
        XCTAssertTrue(message.contains(previous))
        XCTAssertTrue(message.contains(observed))
        XCTAssertTrue(message.contains("validated commit only"))
        XCTAssertTrue(message.contains("recovery/"))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
        try attachScreenshot(of: browser.window, named: "Unsafe reset identifies observed HEAD and retained validated backup")
    }

    func testNativeBrowserLoadsUnreachableDetailsAndCopiesPinnedCommit() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "replacement\n")
        try fixture.git(["commit", "--amend", "-am", "replacement"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let pasteboard = NSPasteboard(name: .init("GitX.ReflogTests." + UUID().uuidString))
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, pasteboard: pasteboard))
        defer { controller.closeView() }
        _ = controller.view
        controller.updateView()
        await waitUntilIdle(controller)
        let table = try control("Events", in: controller, as: NSTableView.self)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(try control("Reference", in: controller, as: NSPopUpButton.self).numberOfItems, 2)
        XCTAssertTrue(try control("Status", in: controller, as: NSTextField.self).stringValue.contains("2 events"))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await waitUntilIdle(controller)
        let details = try control("Details", in: controller, as: NSTextView.self)
        XCTAssertTrue(details.string.contains("initial"))
        XCTAssertTrue(details.string.contains(original))
        let copy = try control("Copy", in: controller, as: NSButton.self)
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), original)
        try control("Compare", in: controller, as: NSButton.self).performClick(nil)
        await waitUntilIdle(controller)
        XCTAssertTrue(details.string.contains("tracked.txt"))
        XCTAssertTrue(details.string.contains("replacement"))
        XCTAssertTrue(controller.firstResponder() === table)
    }

    func testClosingBrowserRevokesControlsAndDiscardsLateLoads() throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        _ = controller.view
        controller.updateView()
        controller.closeView()
        controller.closeView()
        for identifier in ["Reference", "Refresh", "LoadMore", "Cancel", "Copy", "Compare", "CreateBranch", "Reset"] {
            let control = try control(identifier, in: controller, as: NSControl.self)
            XCTAssertFalse(control.isEnabled)
            XCTAssertNil(control.target)
        }
        XCTAssertNil(try control("Events", in: controller, as: NSTableView.self).delegate)
        controller.refresh(nil)
        XCTAssertEqual(try control("Events", in: controller, as: NSTableView.self).numberOfRows, 0)
    }

    func testEmptyReflogExplainsRetentionAndDisablesRecovery() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["reflog", "expire", "--expire=all", "--all"])
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository))
        defer { controller.closeView() }
        _ = controller.view
        controller.updateView()
        await waitUntilIdle(controller)
        XCTAssertTrue(try control("Status", in: controller, as: NSTextField.self).stringValue.contains("no retained events"))
        XCTAssertFalse(try control("Reset", in: controller, as: NSButton.self).isEnabled)
        XCTAssertFalse(try control("LoadMore", in: controller, as: NSButton.self).isEnabled)
    }

    func testRecoveryBranchSheetUsesCapturedCommitAndRejectsClosedOwner() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"])
        let browser = try await presentedBrowser(fixture)
        defer { browser.controller.closeView(); browser.window.close() }
        try control("CreateBranch", in: browser.controller, as: NSButton.self).performClick(nil)
        let name = try sheetControl("BranchName", window: browser.window, as: NSTextField.self)
        name.stringValue = "recovery/from-sheet"
        // A new reflog event must not redirect the captured selection.
        try fixture.git(["commit", "--allow-empty", "-m", "new HEAD"])
        let current = try fixture.git(["rev-parse", "HEAD"])
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { !browser.controller.isBusy && (try? self.control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Created recovery/from-sheet.")) == true }
        await waitUntilIdle(browser.controller)
        XCTAssertEqual(try fixture.git(["rev-parse", "recovery/from-sheet"]), original)
        XCTAssertTrue(browser.repository.branches.contains { $0.description == "recovery/from-sheet" }, "A retained browser reconciles the repository branch snapshot")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), current)
        XCTAssertTrue(try control("Reference", in: browser.controller, as: NSPopUpButton.self).itemTitles.contains("recovery/from-sheet"))
        XCTAssertEqual(try control("Events", in: browser.controller, as: NSTableView.self).numberOfRows, 2)
        try attachScreenshot(of: browser.window, named: "Recovery branch and repository references refreshed")
        try control("CreateBranch", in: browser.controller, as: NSButton.self).performClick(nil)
        try sheetControl("BranchName", window: browser.window, as: NSTextField.self).stringValue = "recovery/closed-owner"
        browser.controller.closeView()
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { browser.window.attachedSheet == nil }
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/closed-owner"]), "")
    }

    func testEveryResetModeFlowsThroughPreviewAndPreservesBackup() async throws {
        for mode in ReflogResetMode.allCases {
            let fixture = try ReflogGitFixture()
            defer { fixture.remove() }
            let target = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "second\n")
            try fixture.git(["commit", "-am", "second"])
            let previous = try fixture.git(["rev-parse", "HEAD"])
            try fixture.write("tracked.txt", "staged\n")
            try fixture.git(["add", "tracked.txt"])
            try fixture.write("tracked.txt", "working\n")
            let browser = try await presentedBrowser(fixture, row: 1)
            defer { browser.controller.closeView(); browser.window.close() }
            let paths = try await preview(mode, browser: browser)
            XCTAssertTrue(paths.string.contains("tracked.txt"))
            try dismissSheet(browser.window, response: .alertFirstButtonReturn)
            if mode == .hard {
                await waitUntil { self.sheetButton("Discard Changes and Reset", window: browser.window) != nil }
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
                try dismissSheet(browser.window, response: .alertSecondButtonReturn)
            }
            await waitUntil { !browser.controller.isBusy && (try? self.control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Reset complete.")) == true }
            await waitUntilIdle(browser.controller)
            XCTAssertTrue(try control("Details", in: browser.controller, as: NSTextView.self).string.hasPrefix("Reset complete."))
            XCTAssertEqual(try control("Events", in: browser.controller, as: NSTableView.self).numberOfRows, 3)
            XCTAssertTrue(try control("Reference", in: browser.controller, as: NSPopUpButton.self).itemTitles.contains { $0.hasPrefix("recovery/") })
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
            XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery/"]), previous)
            XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), mode == .soft ? "staged" : "initial")
            XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), mode == .hard ? "initial\n" : "working\n")
        }
    }

    func testDiscardCancellationAndChangedPreviewNeverReset() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        try fixture.git(["commit", "--allow-empty", "-m", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "keep\n")
        let browser = try await presentedBrowser(fixture, row: 1)
        defer { browser.controller.closeView(); browser.window.close() }
        _ = try await preview(.hard, browser: browser)
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { self.sheetButton("Discard Changes and Reset", window: browser.window) != nil }
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { browser.window.attachedSheet == nil }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "keep\n")
        _ = try await preview(.mixed, browser: browser)
        try fixture.write("tracked.txt", "changed during confirmation\n")
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { (try? self.control("LastResult", in: browser.controller, as: NSTextField.self).stringValue.contains("changed")) == true }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), previous)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/recovery/"]), "")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "changed during confirmation\n")
    }

    func testSidebarAndViewMenuRetainReflogAcrossPassiveRepositoryRefreshes() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let repository = try GitXTestGitRepository(url: fixture.url)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        owner.showWindow(nil)
        defer { owner.close(); repository.worktreeService.cancel() }
        let sidebar = try XCTUnwrap(owner.sidebarViewController)
        owner.showReflog(nil)
        let browser = try XCTUnwrap(owner.value(forKey: "contentController") as? ReflogBrowserController)
        await waitUntilIdle(browser)
        XCTAssertTrue(sidebar.isReflogSelected)
        let item = try XCTUnwrap(sidebar.selectedItem())
        let outline = try XCTUnwrap(sidebar.sourceView)
        XCTAssertTrue(sidebar.outlineView(outline, shouldSelectItem: item))
        XCTAssertEqual(sidebar.outlineView(outline, viewFor: nil, item: item)?.accessibilityIdentifier(), "GitX.Sidebar.Reflog")
        let menu = NSMenuItem(title: "Reflog", action: #selector(GitX.PBGitWindowController.showReflog(_:)), keyEquivalent: "")
        XCTAssertTrue(owner.validateMenuItem(menu))
        XCTAssertEqual(menu.state, .on)
        let historyMenu = NSMenuItem(title: "History", action: #selector(GitX.PBGitWindowController.showHistoryView(_:)), keyEquivalent: "")
        XCTAssertTrue(owner.validateMenuItem(historyMenu))
        XCTAssertEqual(historyMenu.state, .off)
        sidebar.reloadSidebarPresentation()
        XCTAssertTrue(sidebar.isReflogSelected)
        _ = sidebar.perform(NSSelectorFromString("forgeAccessDidChange:"), with: Notification(name: Notification.Name("PBRepositoryForgeAccountDidChange")))
        XCTAssertTrue(sidebar.isReflogSelected)
        autoreleasepool {
            repository.willChangeValue(forKey: "currentBranch")
            repository.didChangeValue(forKey: "currentBranch")
        }
        XCTAssertTrue(sidebar.isReflogSelected)
        browser.refresh(nil)
        sidebar.reloadSidebarAfterReferencesChange()
        XCTAssertTrue(sidebar.isReflogSelected)
        XCTAssertTrue(browser.isBusy, "Invalidation must not cancel the accepted page request")
        XCTAssertFalse(try control("Reset", in: browser, as: NSButton.self).isEnabled)
        owner.showReflog(nil)
        await waitUntilIdle(browser)
        XCTAssertTrue(owner.value(forKey: "contentController") as? ReflogBrowserController === browser)
        owner.showHistoryView(nil)
        XCTAssertFalse(sidebar.isReflogSelected)
        XCTAssertTrue(owner.validateMenuItem(menu))
        XCTAssertEqual(menu.state, .off)
        let row = outline.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntilIdle(browser)
        XCTAssertTrue(sidebar.isReflogSelected)
        owner.close()
        sidebar.showReflog()
        owner.showReflog(nil)
        XCTAssertFalse(try control("Reset", in: browser, as: NSButton.self).isEnabled)
    }

    func testBrowserAllocatesSpareWindowHeightToTheSplitView() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let browser = try await presentedBrowser(fixture)
        defer { browser.controller.closeView(); browser.window.close() }
        let root = browser.controller.view
        root.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertGreaterThan(split.frame.height, root.bounds.height * 0.65,
                             "The event list and details should receive spare height, rather than stretching the footer")
        for pane in split.arrangedSubviews {
            XCTAssertGreaterThan(pane.frame.height, split.bounds.height * 0.3,
                                 "Both panes should be readable before the user adjusts the divider")
        }
        XCTAssertLessThan(try control("Status", in: browser.controller, as: NSTextField.self).frame.height, 24)
    }

    private typealias PresentedBrowser = (controller: ReflogBrowserController, window: NSWindow, repository: GitX.PBGitRepository)

    private func presentedBrowser(_ fixture: ReflogGitFixture, row: Int = 0,
                                  serviceFactory: @escaping (GitX.PBGitRepository) throws -> RepositoryReflogService = { try RepositoryReflogService(repository: $0) },
                                  delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> PresentedBrowser
    {
        let repository = try GitXTestGitRepository(url: fixture.url)
        let controller = try XCTUnwrap(ReflogBrowserController.make(repository: repository, serviceFactory: serviceFactory, delay: delay))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.orderFront(nil)
        controller.updateView()
        await waitUntilIdle(controller)
        try control("Events", in: controller, as: NSTableView.self).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntilIdle(controller)
        return (controller, window, repository)
    }

    private func preview(_ mode: ReflogResetMode, browser: PresentedBrowser) async throws -> NSTextView {
        try control("Reset", in: browser.controller, as: NSButton.self).performClick(nil)
        let modes = try sheetControl("ResetMode", window: browser.window, as: NSPopUpButton.self)
        XCTAssertEqual(modes.indexOfSelectedItem, 0)
        try modes.selectItem(at: XCTUnwrap(ReflogResetMode.allCases.firstIndex(of: mode)))
        try dismissSheet(browser.window, response: .alertFirstButtonReturn)
        await waitUntil { self.find("ResetPreview", in: browser.window.attachedSheet?.contentView) != nil }
        return try sheetControl("ResetPreview", window: browser.window, as: NSTextView.self)
    }

    private func dismissSheet(_ window: NSWindow, response: NSApplication.ModalResponse) throws {
        try window.endSheet(XCTUnwrap(window.attachedSheet), returnCode: response)
    }

    private func sheetButton(_ title: String, window: NSWindow) -> NSButton? {
        func button(in view: NSView?) -> NSButton? {
            if let value = view as? NSButton, value.title == title {
                return value
            }
            return view?.subviews.lazy.compactMap { button(in: $0) }.first
        }
        return button(in: window.attachedSheet?.contentView)
    }

    private func sheetControl<Value: NSView>(_ identifier: String, window: NSWindow, as _: Value.Type) throws -> Value {
        try XCTUnwrap(find(identifier, in: window.attachedSheet?.contentView) as? Value)
    }

    private func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // swift6-safety-justification: AppKit test predicates are evaluated on the main thread.
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    private func waitUntilIdle(_ controller: ReflogBrowserController) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // swift6-safety-justification: AppKit test predicates are evaluated on the main thread.
            MainActor.assumeIsolated { !controller.isBusy }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    private func control<Value: NSView>(_ identifier: String, in controller: ReflogBrowserController, as type: Value.Type) throws -> Value {
        try XCTUnwrap(find(identifier, in: controller.view) as? Value)
    }

    private func find(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == "GitX.Reflog." + identifier {
            return view
        }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}
