import AppKit
import Darwin
import ForgeKit
import ObjectiveC.runtime
import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test case lifetime, while every mutable access is confined to the main actor.
final class HistoryControllerTests: XCTestCase, @unchecked Sendable {
    private final class UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private var indexPublicationEvents: [String] = []

    @objc private func recordIndexPublication(_ notification: Notification) {
        guard let index = notification.object as? PBGitIndex else { return }
        XCTAssertTrue(index.mutationReconciliationPending, "Pending clears only after refresh notifications")
        indexPublicationEvents.append(notification.name == Notification.Name(PBGitIndexIndexUpdated) ? "updated" : "finished")
    }

    @objc private func assertPendingAtCommitCompletion(_ notification: Notification) {
        guard let index = notification.object as? PBGitIndex else { return }
        XCTAssertTrue(index.mutationReconciliationPending, "A created commit awaits authoritative index reconciliation")
        guard let pane = historyController.value(forKey: "stagingViewController") as? PBStagingViewController else { return }
        let buttons = controls(in: pane.view).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.first { $0.accessibilityIdentifier() == "CommitButton" }?.isEnabled ?? true)
        XCTAssertFalse(buttons.first { $0.title == "Amend" }?.isEnabled ?? true)
    }

    @objc(gitx_testFailingGitExecutablePath)
    private nonisolated class func failingGitExecutablePath() -> String {
        "/usr/bin/false"
    }

    private func withFailingGitExecutable(_ body: () -> Void) throws {
        let original = try XCTUnwrap(class_getClassMethod(PBGitBinary.self, NSSelectorFromString("path")))
        let replacement = try XCTUnwrap(
            class_getClassMethod(Self.self, #selector(Self.failingGitExecutablePath))
        )
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        body()
    }

    /// AppKit creates KVO notifying subclasses while presenting sheets. The
    /// Objective-C test base keeps the compatibility mirror and runtime Swift
    /// superclass layouts separated, while this name keeps KVO identity stable.
    @objc(PBHistoryWindowControllerTestDouble)
    private final class HistoryWindowController: PBHistoryWindowControllerTestBase {
        private var fixedRepository: PBGitRepository!
        private(set) var shownErrors: [NSError] = []
        private(set) var confirmationCount = 0
        private(set) var openedURLs: [URL] = []
        private(set) var revealedURLs: [URL] = []
        var automaticallyConfirms = true
        private var pendingConfirmation: (() -> Void)?

        init(repository: PBGitRepository) {
            fixedRepository = repository
            super.init(window: NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            ))
        }

        override init(window: NSWindow?) {
            super.init(window: window)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var repository: PBGitRepository? {
            get { fixedRepository }
            set { fixedRepository = newValue }
        }

        override func showErrorSheet(_ error: Error) {
            shownErrors.append(error as NSError)
        }

        override func open(_ fileURLs: [URL]?) {
            openedURLs = fileURLs ?? []
        }

        override func revealURLs(inFinder fileURLs: [URL]?) {
            revealedURLs = fileURLs ?? []
        }

        private(set) var shownMessages: [(message: String, info: String)] = []
        private(set) var hookFailureRetryHandlers: [() -> Void] = []
        private(set) var performedPushes = 0

        override func showMessageSheet(_ messageText: String, infoText: String) {
            shownMessages.append((messageText, infoText))
        }

        override func showCommitHookFailedSheet(
            _ messageText: String,
            infoText: String,
            retryHandler: (() -> Void)?
        ) {
            shownMessages.append((messageText, infoText))
            if let retryHandler {
                hookFailureRetryHandlers.append(retryHandler)
            }
        }

        override func performPush(
            forBranch branchRef: PBGitRef?,
            toRemote remoteRef: PBGitRef?,
            requiresConfirmation: Bool
        ) {
            performedPushes += 1
        }

        override func performPush(
            forBranch branchRef: PBGitRef?,
            toRemote remoteRef: PBGitRef?,
            requiresConfirmation: Bool,
            initiallyCreatePullRequest: Bool
        ) {
            performedPushes += 1
        }

        override func confirmDialog(
            _ alert: NSAlert,
            suppressionIdentifier identifier: String?,
            forAction actionBlock: @escaping () -> Void
        ) -> Bool {
            confirmationCount += 1
            if automaticallyConfirms {
                actionBlock()
            } else {
                pendingConfirmation = actionBlock
            }
            return true
        }

        func confirmPendingAction() {
            let action = pendingConfirmation
            pendingConfirmation = nil
            action?()
        }
    }

    @MainActor
    private final class WorkspaceOpenRecorder: NSObject {
        static var openedURLs: [URL] = []

        @objc(gitx_recordOpenedURL:)
        func recordOpenedURL(_ url: URL) -> Bool {
            WorkspaceOpenRecorder.openedURLs.append(url)
            return true
        }
    }

    private final class RevisionCellFake: NSTableCellView {
        var referenceIndex: Int32 = -1

        @objc(indexAtX:)
        // swiftlint:disable:next unused_declaration
        func referenceIndex(atX x: CGFloat) -> Int32 {
            referenceIndex
        }
    }

    private final class CommitListFake: NSTableView {
        var testRow = 0
        var testColumn = 0
        var testMouseDownPoint = NSPoint(x: 5, y: 5)
        let revisionCell = RevisionCellFake()

        @objc var mouseDownPoint: NSPoint {
            testMouseDownPoint
        }

        override func row(at point: NSPoint) -> Int {
            testRow
        }

        override func column(at point: NSPoint) -> Int {
            testColumn
        }

        override func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? {
            revisionCell
        }

        override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
            NSRect(x: 0, y: 0, width: 300, height: 20)
        }
    }

    private final class CommitListDataSource: NSObject, NSTableViewDataSource {
        let rowCount: Int

        init(rowCount: Int) {
            self.rowCount = rowCount
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }
    }

    private final class QLTextViewFake: PBQLTextView {
        private(set) var findActionCount = 0

        override func performFindPanelAction(_ sender: Any?) {
            findActionCount += 1
        }
    }

    private final class QuickLookHistoryControllerSpy: PBGitHistoryController {
        var detailIndex = 0
        private(set) var toggleCount = 0

        override var selectedCommitDetailsIndex: Int {
            get { detailIndex }
            set { detailIndex = newValue }
        }

        override func toggleQLPreviewPanel(_: Any) {
            toggleCount += 1
        }
    }

    @MainActor
    private final class DraggingInfoFake: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = .move
        var draggingLocation = NSPoint.zero
        var draggedImageLocation = NSPoint.zero
        var draggedImage: NSImage?
        var draggingSource: Any?
        var draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1

        init(pasteboard: NSPasteboard) {
            draggingPasteboard = pasteboard
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        var springLoadingHighlight: NSSpringLoadingHighlight {
            .none
        }

        func resetSpringLoading() {}
    }

    private final class GitFixture {
        let path: String
        let remotePath: String

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXHistoryController-\(UUID().uuidString)")
            path = root.path
            remotePath = root.appendingPathExtension("remote.git").path
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git(["init", "--quiet", "--initial-branch=main"])
            try git(["config", "user.name", "GitX Tests"])
            try git(["config", "user.email", "gitx-tests@example.invalid"])
            try write("initial\n", to: "nested/tracked.txt")
            try write(
                """
                func flowValue(_ enabled: Bool) -> Int {
                    if enabled {
                        return 1
                    }
                    return 0
                }

                """,
                to: "FlowSample.swift"
            )
            try git(["add", "--all"])
            try git(["commit", "--quiet", "-m", "initial commit"])
            try write("second\n", to: "nested/tracked.txt")
            try write(
                """
                func flowValue(_ enabled: Bool) -> Int {
                    guard enabled else {
                        return -1
                    }
                    return 2
                }

                """,
                to: "FlowSample.swift"
            )
            try git(["commit", "--quiet", "-am", "second main commit"])
            try git(["branch", "feature", "HEAD^"])
            try git(["checkout", "--quiet", "feature"])
            try write("feature\n", to: "feature.txt")
            try git(["add", "--all"])
            try git(["commit", "--quiet", "-m", "feature commit"])
            try git(["checkout", "--quiet", "main"])
            try git(["tag", "v1"])
            try git(["init", "--bare", "--quiet", remotePath])
            try git(["remote", "add", "origin", remotePath])
            try git(["push", "--quiet", "--set-upstream", "origin", "main"])
            try write("stash\n", to: "stash.txt")
            try git(["add", "stash.txt"])
            try git(["stash", "push", "--quiet", "-m", "history fixture stash"])
        }

        deinit {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: remotePath)
        }

        func write(_ contents: String, to relativePath: String) throws {
            let url = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = RepositoryTestGitEnvironment.isolated()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw NSError(
                    domain: "HistoryControllerTests",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorText]
                )
            }
            return outputText
        }
    }

    private static let detailIndexKey = "PBHistorySelectedDetailIndex"

    private var fixture: GitFixture!
    private var repository: PBGitRepository!
    private var historyController: PBGitHistoryController!
    private var windowController: PBGitWindowController!
    private var testArtifactDirectory: URL!
    private var previousDetailIndex: Any?
    private var didCapturePreviousDetailIndex = false

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where all AppKit fixtures must be created.
        try MainActor.assumeIsolated {
            // Capture the developer's real preference before any throwing
            // fixture work so teardown never mistakes a partial setup for an
            // intentionally absent value.
            previousDetailIndex = UserDefaults.standard.object(forKey: Self.detailIndexKey)
            didCapturePreviousDetailIndex = true
            testArtifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXHistoryControllerArtifacts-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: testArtifactDirectory, withIntermediateDirectories: true)
            for window in NSApp.windows where window.windowController is PBGitWindowController {
                window.orderOut(nil)
                window.close()
            }
            fixture = try GitFixture()
            repository = try RepositoryTestGitRepository(url: URL(fileURLWithPath: fixture.path))
            repository.currentBranchFilter = 0
            repository.readCurrentBranch()
            waitForHistory()
            UserDefaults.standard.set(0, forKey: Self.detailIndexKey)
            windowController = HistoryWindowController(repository: repository)
            historyController = PBGitHistoryController(
                repository: repository,
                superController: windowController
            )
            _ = historyController.view
            windowController.window?.contentView = historyController.view
            waitForHistory()
            pumpRunLoop()
        }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where all AppKit fixtures must be released.
        MainActor.assumeIsolated {
            waitForHistory()
            historyController?.closeView()
            repository?.revisionList?.cleanup()
            historyController = nil
            windowController = nil
            repository = nil
            fixture = nil
            if let testArtifactDirectory {
                try? FileManager.default.removeItem(at: testArtifactDirectory)
            }
            testArtifactDirectory = nil
            if didCapturePreviousDetailIndex {
                if let previousDetailIndex {
                    UserDefaults.standard.set(previousDetailIndex, forKey: Self.detailIndexKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.detailIndexKey)
                }
            }
        }
        super.tearDown()
    }

    func testRealNibLifecycleModesFiltersAndValidation() throws {
        XCTAssertEqual(historyController.commitList.accessibilityIdentifier(), "CommitList")
        XCTAssertTrue(historyController.commitList.allowsMultipleSelection)
        XCTAssertTrue(historyController.commitList.delegate is PBHistoryTableInteractionCoordinator)
        XCTAssertTrue(historyController.commitList.delegate === historyController.commitList.dataSource)
        XCTAssertNotNil(PBGitRevisionCell.shadowColor())
        XCTAssertNotNil(PBGitRevisionCell.lineShadowColor())
        _ = historyController.searchController.hasSearchResults()
        XCTAssertTrue(PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil).description.contains("command:"))
        XCTAssertTrue(historyController.firstResponder() === historyController.commitList)
        XCTAssertEqual(historyController.tableColumnMenu().items.count, historyController.commitList.tableColumns.count)

        let treeItem = NSMenuItem(title: "Tree", action: #selector(PBGitHistoryController.setTreeView(_:)), keyEquivalent: "")
        historyController.setTreeView(treeItem)
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 1)
        XCTAssertTrue(historyController.validateMenuItem(treeItem))
        XCTAssertEqual(treeItem.state, .on)

        let flowItem = NSMenuItem(title: "Flow", action: #selector(PBGitHistoryController.setFlowView(_:)), keyEquivalent: "")
        historyController.setFlowView(flowItem)
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 2)
        XCTAssertTrue(historyController.validateMenuItem(flowItem))
        XCTAssertEqual(flowItem.state, .on)
        XCTAssertTrue(historyController.validateMenuItem(treeItem))
        XCTAssertEqual(treeItem.state, .off)

        let detailItem = NSMenuItem(title: "Detail", action: #selector(PBGitHistoryController.setDetailedView(_:)), keyEquivalent: "")
        historyController.setDetailedView(detailItem)
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)
        XCTAssertTrue(historyController.validateMenuItem(detailItem))
        XCTAssertEqual(detailItem.state, .on)
        XCTAssertTrue(historyController.validateMenuItem(flowItem))
        XCTAssertEqual(flowItem.state, .off)

        let patchItem = NSMenuItem(title: "Create Patch…", action: #selector(PBGitHistoryController.createPatch(_:)), keyEquivalent: "")
        XCTAssertTrue(historyController.validateMenuItem(patchItem))
        let selectedForPatch = historyController.commitController.selectedObjects ?? []
        historyController.commitController.setSelectedObjects([])
        historyController.createPatch(self)
        historyController.commitController.setSelectedObjects(selectedForPatch)

        let localButton = try XCTUnwrap(historyController.value(forKey: "localRemoteBranchesFilterItem") as? NSButton)
        localButton.tag = 1
        historyController.setBranchFilter(localButton)
        XCTAssertEqual(repository.currentBranchFilter, 1)
        let selectedButton = try XCTUnwrap(historyController.value(forKey: "selectedBranchFilterItem") as? NSButton)
        XCTAssertEqual(selectedButton.title, repository.currentBranch?.title())

        repository.currentBranch = PBGitRevSpecifier(parameters: ["HEAD~0"])
        historyController.updateBranchFilterMatrix()
        let allButton = try XCTUnwrap(historyController.value(forKey: "allBranchesFilterItem") as? NSButton)
        XCTAssertFalse(allButton.isEnabled)
        XCTAssertFalse(localButton.isEnabled)
        XCTAssertEqual(selectedButton.state, .on)

        historyController.commitController.filterPredicate = NSPredicate(value: true)
        XCTAssertTrue(historyController.hasNonlinearPath())
        historyController.commitController.filterPredicate = nil
        historyController.commitController.sortDescriptors = [NSSortDescriptor(key: "subject", ascending: true)]
        XCTAssertTrue(historyController.hasNonlinearPath())
        historyController.commitController.sortDescriptors = []
        XCTAssertFalse(historyController.hasNonlinearPath())

        historyController.refresh(self)
        waitForHistory()
        historyController.updateView()
        XCTAssertEqual(historyController.status?.isEmpty, false)
        XCTAssertEqual(
            tableCoordinator.numberOfRows(in: historyController.commitList),
            (historyController.commitController.arrangedObjects as? [Any])?.count
        )
        XCTAssertNotNil(tableCoordinator.tableView(historyController.commitList, rowViewForRow: 0))
    }

    func testHistoryNibContainsNativeFlowTabAndPersistsItsSelection() throws {
        historyController.selectedCommitDetailsIndex = 2
        pumpRunLoop()

        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))
        XCTAssertEqual(flowView.accessibilityLabel(), "Commit flow delta")

        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 2)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "PBHistorySelectedDetailIndex"), 2)

        historyController.selectedCommitDetailsIndex = 0
        historyController.commitController.setSelectedObjects([])
        pumpRunLoop()
        historyController.selectedCommitDetailsIndex = 2
        pumpRunLoop()

        let statusLabels = controls(in: flowView).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            statusLabels.contains { $0.stringValue == "Select one commit to review its flow delta." },
            "Flow status labels: \(statusLabels.map(\.stringValue))"
        )
    }

    func testHistoryFlowRendersSuccessfulRevisionAnalysis() throws {
        selectCommitForFlowAnalysis()
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("1 files (Swift)") && $0.contains("function deltas")
                }
            },
            "Flow labels after analysis: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowReportsRevisionAnalysisFailure() throws {
        selectCommitForFlowAnalysis()
        let repositoryURL = URL(fileURLWithPath: fixture.path)
        let unavailableURL = repositoryURL.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: repositoryURL, to: unavailableURL)
        defer {
            try? FileManager.default.moveItem(at: unavailableURL, to: repositoryURL)
        }

        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains { $0.hasPrefix("Flow analysis failed.\n") }
            },
            "Flow labels after analysis failure: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowReportsGitExitFailure() throws {
        selectCommitForFlowAnalysis()
        try withFailingGitExecutable {
            historyController.selectedCommitDetailsIndex = 2
        }
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("failed with status 1")
                }
            },
            "Flow labels after git failure: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowReloadsSameCommitAfterLeavingWhileAnalysisIsPending() throws {
        selectCommitForFlowAnalysis()
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        historyController.selectedCommitDetailsIndex = 0
        historyController.selectedCommitDetailsIndex = 2

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("1 files (Swift)") && $0.contains("function deltas")
                }
            },
            "Flow labels after returning to the pending revision: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowExplainsCommitsWithoutAnalyzableFiles() throws {
        selectCommitForFlowAnalysis()
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains { $0.contains("1 files (Swift)") }
            },
            "Flow labels after analysis: \(flowLabels(in: flowView))"
        )

        try fixture.write("notes\n", to: "notes.md")
        try fixture.git(["add", "notes.md"])
        try commitAndReloadHistory("add notes")
        selectCommitForFlowAnalysis(revision: "HEAD")

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains { $0.hasPrefix("This commit changes no files Flow can analyze.") }
            },
            "Flow labels for a commit without analyzable files: \(flowLabels(in: flowView))"
        )
        // The previous commit's review must not linger under the message.
        let reviewView = try XCTUnwrap(descendant(identifier: "History.Flow.Review", in: flowView))
        XCTAssertTrue(reviewView.isHiddenOrHasHiddenAncestor, "The review view stayed visible for a commit without analyzable files")
    }

    func testHistoryFlowAnalyzesRenamesAcrossTheSupportedLanguageBoundary() throws {
        // FlowDelta's own provider traps on a rename whose other side is not a
        // supported language; GitX's provider reduces it to the loadable side.
        try fixture.git(["mv", "FlowSample.swift", "FlowSample.swift.bak"])
        let retiredSHA = try commitAndReloadHistory("retire the flow sample")
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                let labels = self.flowLabels(in: flowView)
                return labels.contains { $0.contains("1 files (Swift)") }
                    && labels.contains { $0.contains(String(retiredSHA.prefix(7))) }
            },
            "Flow labels after analyzing a rename to an unsupported extension: \(flowLabels(in: flowView))"
        )

        try fixture.git(["mv", "FlowSample.swift.bak", "FlowSample.swift"])
        let restoredSHA = try commitAndReloadHistory("restore the flow sample")
        selectCommitForFlowAnalysis(revision: "HEAD")

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                let labels = self.flowLabels(in: flowView)
                return labels.contains { $0.contains("1 files (Swift)") }
                    && labels.contains { $0.contains(String(restoredSHA.prefix(7))) }
            },
            "Flow labels after analyzing a rename from an unsupported extension: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowSurfacesPartialParseDiagnostics() throws {
        try fixture.write(
            """
            func flowValue(_ enabled: Bool) -> Int {
                if enabled {
                    return 1
                }
                return 0 )))
            }

            """,
            to: "FlowSample.swift"
        )
        try fixture.git(["add", "FlowSample.swift"])
        try commitAndReloadHistory("break the flow sample")
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))
        let banner = try XCTUnwrap(descendant(identifier: "History.Flow.Diagnostics", in: flowView) as? NSTextField)

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                !banner.isHiddenOrHasHiddenAncestor
                    && banner.stringValue.hasPrefix("Flow analysis is incomplete:")
            },
            "Flow diagnostics banner: \(banner.stringValue) hidden=\(banner.isHiddenOrHasHiddenAncestor)"
        )
        XCTAssertTrue(
            banner.stringValue.contains("FlowSample.swift: Swift parsed with"),
            "Flow diagnostics banner: \(banner.stringValue)"
        )
        XCTAssertEqual(banner.maximumNumberOfLines, 0, "The overflow summary must not be clipped")
        try attachScreenshot(of: flowView, named: "History-Flow-Diagnostics")

        // A clean analysis takes the banner down again.
        let mainSHA = try fixture.git(["rev-parse", "main~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        selectCommitForFlowAnalysis(revision: "main~1")
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains { $0.contains(String(mainSHA.prefix(7))) }
            },
            "Flow labels after re-analyzing the clean revision: \(flowLabels(in: flowView))"
        )
        XCTAssertTrue(banner.isHiddenOrHasHiddenAncestor, "The diagnostics banner outlived a clean analysis")
    }

    func testHistoryFlowReportsProviderFailuresInPlainLanguage() throws {
        // A source file git cannot hand back as UTF-8 fails the load with the
        // provider's own description rather than a generic NSError sentence.
        let brokenURL = URL(fileURLWithPath: fixture.path).appendingPathComponent("Broken.swift")
        try Data([0x66, 0x75, 0x6E, 0x63, 0x20, 0xFF, 0xFE, 0x0A]).write(to: brokenURL)
        try fixture.git(["add", "Broken.swift"])
        try commitAndReloadHistory("add a file git cannot decode")
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.hasPrefix("Flow analysis failed.\n") && $0.contains("Git returned non-UTF-8 data for Broken.swift")
                }
            },
            "Flow labels after a provider failure: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowRejectsABlobBeyondTheAnalysisLimit() throws {
        // Keep the fixture itself small so AppKit never has to lay out a
        // multi-megabyte diff. The configured git shim reports the committed
        // blob's production-sized object length at the preflight boundary.
        try fixture.write("let oversized = 0\n", to: "Oversized.swift")
        try fixture.git(["add", "Oversized.swift"])
        try commitAndReloadHistory("add an oversized source file")
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let commandLog = testArtifactDirectory.appendingPathComponent("flow-git-commands")
        let wrapper = try installLoggingGitWrapper(log: commandLog, oversizedBlobPath: "Oversized.swift")
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("Oversized.swift is") && $0.contains("exceeding the limit")
                }
            },
            "Flow labels after exceeding the blob limit: \(flowLabels(in: flowView))"
        )
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains("cat-file -s"), "Flow commands: \(commands)")
        XCTAssertFalse(commands.contains("show ") && commands.contains(":Oversized.swift"), "Flow commands: \(commands)")
    }

    func testHistoryFlowTerminatesGitWhenTheChangedFileListExceedsTheByteLimit() throws {
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let wrapper = try installOversizedNameStatusGitWrapper()
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("more than 8388608 bytes for changed-file list")
                }
            },
            "Flow labels after oversized name-status output: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowReportsExcessiveStderrWithoutMislabelingTheBlob() throws {
        try fixture.write("let stderrFixture = true\n", to: "Stderr.swift")
        try fixture.git(["add", "Stderr.swift"])
        try commitAndReloadHistory("add stderr fixture")
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let wrapper = testArtifactDirectory.appendingPathComponent("git-flow-excessive-stderr")
        let script = """
        #!/bin/bash
        if [[ "$*" == *" show "* && "$*" == *":Stderr.swift"* ]]; then
            exec /usr/bin/head -c 65537 /dev/zero >&2
        fi
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("more than 65536 bytes of error output") && $0.contains("blob Stderr.swift")
                }
            },
            "Flow labels after excessive stderr: \(flowLabels(in: flowView))"
        )
        XCTAssertFalse(
            flowLabels(in: flowView).contains { $0.contains("Stderr.swift is") && $0.contains("exceeding the limit") }
        )
        try attachScreenshot(of: flowView, named: "History-Flow-Stderr-Limit")
    }

    func testHistoryFlowRefusesRevisionsBeyondTheChangedFileLimit() throws {
        let limit = 500
        for index in 0 ... limit {
            try fixture.write("let value\(index) = \(index)\n", to: "Bulk/File\(index).swift")
        }
        try fixture.git(["add", "Bulk"])
        try commitAndReloadHistory("add more files than Flow will analyze")
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.flowLabels(in: flowView).contains {
                    $0.contains("Revision changes \(limit + 1) files, exceeding the limit of \(limit).")
                }
            },
            "Flow labels after exceeding the changed-file limit: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryFlowCancelsRunningGitWorkWhenTheSelectionMoves() throws {
        let defaults = UserDefaults.standard
        let defaultsDomain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let previousWatcherPreference = defaults.persistentDomain(forName: defaultsDomain)?["PBUseRepositoryWatcher"]
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        defer {
            if let previousWatcherPreference {
                defaults.set(previousWatcherPreference, forKey: "PBUseRepositoryWatcher")
            } else {
                defaults.removeObject(forKey: "PBUseRepositoryWatcher")
            }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let processStarted = testArtifactDirectory.appendingPathComponent("flow-git-started")
        let processTerminated = testArtifactDirectory.appendingPathComponent("flow-git-terminated")
        for marker in [processStarted, processTerminated] {
            try? FileManager.default.removeItem(at: marker)
        }
        let wrapper = try installCancellableGitWrapper(started: processStarted, terminated: processTerminated)
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))

        try fixture.write("let cancelled = true\n", to: "Cancelled.swift")
        try fixture.git(["add", "Cancelled.swift"])
        let bulkSHA = try commitAndReloadHistory("add a cancellable source file")
        let mainSHA = try fixture.git(["rev-parse", "main~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        selectCommitForFlowAnalysis(revision: "HEAD")
        historyController.selectedCommitDetailsIndex = 2
        let flowView = try XCTUnwrap(descendant(identifier: "History.Flow.View", in: historyController.view))
        XCTAssertTrue(
            waitForCondition(timeout: 10) { FileManager.default.fileExists(atPath: processStarted.path) },
            "The configured git wrapper never began loading a source snapshot"
        )

        selectCommitForFlowAnalysis(revision: "main~1")

        XCTAssertTrue(
            waitForCondition(timeout: 10) { FileManager.default.fileExists(atPath: processTerminated.path) },
            "The running configured git process did not receive SIGTERM"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 15) {
                self.flowLabels(in: flowView).contains { $0.contains(String(mainSHA.prefix(7))) }
            },
            "Flow labels after moving the selection away from \(bulkSHA): \(flowLabels(in: flowView))"
        )
        XCTAssertFalse(
            flowLabels(in: flowView).contains { $0.contains(String(bulkSHA.prefix(7))) },
            "The cancelled revision must not be displayed: \(flowLabels(in: flowView))"
        )
    }

    func testHistoryTreeExplainsASelectedDirectoryWithoutRelyingOnIncidentalCoverage() throws {
        let previousChangedFilesOnly = PBApplicationSettings.changedFilesOnly
        PBApplicationSettings.changedFilesOnly = false
        defer { PBApplicationSettings.changedFilesOnly = previousChangedFilesOnly }
        let mainSHA = try fixture.git(["rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try XCTUnwrap(loadedCommits().first { $0.sha == mainSHA })
        historyController.commitController.setSelectedObjects([commit])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        let directory = try XCTUnwrap(waitForTreeNode(fullPath: "nested"))
        XCTAssertFalse((directory.representedObject as? PBGitTree)?.leaf ?? true)
        historyController.treeController.setSelectionIndexPath(directory.indexPath)
        let fileView = try XCTUnwrap(historyController.value(forKey: "fileView") as? NSObject)
        let modeControl = try XCTUnwrap(fileView.value(forKey: "modeControl") as? NSSegmentedControl)
        let nativeView = try XCTUnwrap(fileView.value(forKey: "nativeView") as? PBNativeContentView)
        modeControl.selectedSegment = 0
        fileView.perform(NSSelectorFromString("showFile"))

        XCTAssertTrue(
            waitForCondition {
                nativeView.textView.string == "Select one or more files to view this mode."
            },
            "Unexpected empty directory presentation: \(nativeView.textView.string)"
        )
    }

    func testFlowAdapterWithoutAHistoryControllerExplainsItself() throws {
        let adapterClass = try XCTUnwrap(NSClassFromString("PBFlowDeltaAdapterView") as? NSView.Type)
        let adapter = adapterClass.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        adapter.awakeFromNib()

        XCTAssertTrue(
            controls(in: adapter).contains { ($0 as? NSTextField)?.stringValue == "The History controller is unavailable." },
            "Adapter labels: \(controls(in: adapter).compactMap { ($0 as? NSTextField)?.stringValue })"
        )
    }

    func testHistoryForgeColumnsDiagnosticScreenshot() throws {
        let checkColumn = try XCTUnwrap(historyController.commitList.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("ForgeCheckRollupColumn")
        ))
        let pullRequestColumn = try XCTUnwrap(historyController.commitList.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("ForgePullRequestBadgeColumn")
        ))
        checkColumn.isHidden = false
        pullRequestColumn.isHidden = false
        historyController.commitList.reloadData()
        pumpRunLoop()

        let contentView = try XCTUnwrap(windowController.window?.contentView)
        try attachScreenshot(
            of: contentView,
            named: "M1-History-01-Forge-Check-and-Pull-Request-Columns"
        )
    }

    func testCurrentBranchChangeClearsCommitSortDescriptors() {
        historyController.commitController.sortDescriptors = [
            NSSortDescriptor(key: "subject", ascending: true),
        ]
        XCTAssertFalse(historyController.commitController.sortDescriptors.isEmpty)

        repository.currentBranch = PBGitRevSpecifier(parameters: ["HEAD~0"])

        XCTAssertTrue(historyController.commitController.sortDescriptors.isEmpty)
    }

    func testRepositoryToolbarCreatesBranchAndTagItemsAndRejectsUnknownItems() throws {
        let toolbarController = PBRepositoryToolbarController(windowController: windowController)
        let toolbar = NSToolbar(identifier: "GitX.Repository.HistoryToolbar")

        let branchItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.CreateBranch"),
            willBeInsertedIntoToolbar: false
        ))
        XCTAssertEqual(branchItem.label, "New Branch")
        XCTAssertEqual(branchItem.action, #selector(PBGitWindowController.createBranch(_:)))

        let tagItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.CreateTag"),
            willBeInsertedIntoToolbar: false
        ))
        XCTAssertEqual(tagItem.label, "New Tag")
        XCTAssertEqual(tagItem.action, #selector(PBGitWindowController.createTag(_:)))

        let attentionItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.Attention"),
            willBeInsertedIntoToolbar: true
        ))
        NotificationCenter.default.post(
            name: .repositoryAttentionUnseenDidChange,
            object: repository,
            userInfo: nil
        )
        let attentionContainer = try XCTUnwrap(attentionItem.view)
        let attentionButton = try XCTUnwrap(attentionContainer.subviews.compactMap { $0 as? NSButton }.first)
        let attentionBadge = try XCTUnwrap(attentionContainer.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(attentionButton.accessibilityLabel(), "Attention Inbox, No unseen Attention items")
        XCTAssertTrue(attentionBadge.isHidden)

        let accountItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount"),
            willBeInsertedIntoToolbar: true
        ))
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let accountID = try ForgeAccountID(forge: forge, value: "toolbar-account")
        let otherAccountID = try ForgeAccountID(forge: forge, value: "toolbar-other-account")
        let accountChoice = RepositoryForgeAccountChoice(id: accountID, login: "hbmartin")
        let otherAccountChoice = RepositoryForgeAccountChoice(id: otherAccountID, login: "octocat")
        NotificationCenter.default.post(
            name: .repositoryForgeAccountDidChange,
            object: repository,
            userInfo: [
                RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                RepositoryForgeAccountNotificationKey.login: "octocat",
                RepositoryForgeAccountNotificationKey.isPublic: false,
                RepositoryForgeAccountNotificationKey.accountID: otherAccountID,
                RepositoryForgeAccountNotificationKey.accounts: [
                    accountChoice.notificationValue,
                    otherAccountChoice.notificationValue,
                ],
            ]
        )
        let accountStack = try XCTUnwrap(accountItem.view as? NSStackView)
        let accountPopup = try XCTUnwrap(accountStack.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount"
        })
        XCTAssertEqual(accountPopup.item(at: 0)?.title, "@octocat")
        XCTAssertEqual(accountPopup.accessibilityLabel(), "GitHub account, octocat")
        let choice = try XCTUnwrap(accountPopup.menu?.items.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount.Choice.toolbar-account"
        })
        XCTAssertEqual(choice.state, .off)
        XCTAssertEqual(choice.representedObject as? ForgeAccountID, accountID)
        let manage = try XCTUnwrap(accountPopup.menu?.items.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount.Manage"
        })
        XCTAssertEqual(manage.action, NSSelectorFromString("openForgeAccountsPreferences:"))
        let toolbarAvatar = try XCTUnwrap(accountStack.arrangedSubviews.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccountAvatarContainer"
        }?.subviews.first)
        XCTAssertEqual(toolbarAvatar.accessibilityIdentifier(), "GitX.Toolbar.ForgeAccountAvatar")
        XCTAssertEqual(toolbarAvatar.accessibilityLabel(), "octocat, initials O")
        XCTAssertEqual(accountChoice.avatarURL?.host, "avatars.githubusercontent.com")
        XCTAssertNoThrow(try ForgeAvatarURL(XCTUnwrap(accountChoice.avatarURL)))
        XCTAssertNotNil(choice.action)

        let cooldownDeadline = Date().addingTimeInterval(60)
        NotificationCenter.default.post(
            name: .repositoryForgeAccountDidChange,
            object: repository,
            userInfo: [
                RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                RepositoryForgeAccountNotificationKey.login: "octocat",
                RepositoryForgeAccountNotificationKey.isPublic: false,
                RepositoryForgeAccountNotificationKey.accountID: otherAccountID,
                RepositoryForgeAccountNotificationKey.accounts: [
                    accountChoice.notificationValue,
                    otherAccountChoice.notificationValue,
                ],
                RepositoryForgeAccountNotificationKey.accountRebindingEnabled: false,
                RepositoryForgeAccountNotificationKey.accountRebindingCooldownDeadline: cooldownDeadline,
            ]
        )
        XCTAssertFalse(accountPopup.isEnabled)
        XCTAssertEqual(
            accountPopup.accessibilityHelp(),
            "Account changes are paused until GitHub’s rate-limit window ends."
        )
        XCTAssertFalse(try XCTUnwrap(accountPopup.menu?.items.first {
            $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount.Choice.toolbar-account"
        }).isEnabled)

        XCTAssertNil(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.Unknown"),
            willBeInsertedIntoToolbar: false
        ))
    }

    func testControllerWithoutCurrentBranchReloadsHeadDuringNibAwakening() throws {
        let coldRepository = try RepositoryTestGitRepository(url: URL(fileURLWithPath: fixture.path))
        XCTAssertNil(coldRepository.currentBranch)
        let coldWindowController = HistoryWindowController(repository: coldRepository)
        let coldHistoryController = try XCTUnwrap(
            PBGitHistoryController(
                repository: coldRepository,
                superController: coldWindowController
            )
        )
        defer {
            XCTAssertTrue(waitForCondition(timeout: 10) {
                coldRepository.revisionList?.isUpdating != true
            })
            coldHistoryController.closeView()
            coldRepository.revisionList?.cleanup()
            coldWindowController.window?.orderOut(nil)
            coldWindowController.window?.close()
        }

        _ = coldHistoryController.view

        XCTAssertEqual(coldRepository.currentBranch?.simpleRef(), "refs/heads/main")
    }

    func testPendingUncommittedSelectionForcesDetailsForNewAndRefreshedWorkingState() throws {
        XCTAssertNil(historyController.commitController.value(forKey: "pinnedObject"))
        historyController.selectedCommitDetailsIndex = 1
        try fixture.write("pending selection\n", to: "pending-selection.txt")

        waitForIndexUpdate {
            historyController.selectUncommittedChanges()
        }

        let workingState = try XCTUnwrap(
            historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        )
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === workingState)

        let regularCommit = try XCTUnwrap(loadedCommits().first)
        historyController.commitController.setSelectedObjects([regularCommit])
        historyController.selectedCommitDetailsIndex = 1
        historyController.setValue(true, forKey: "pendingUncommittedSelection")

        historyController.updateUncommittedChanges()

        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === workingState)
    }

    func testSelectionReconciliationWorkingStateStatusAndTreeRestoration() throws {
        let previousChangedFilesOnly = PBApplicationSettings.changedFilesOnly
        PBApplicationSettings.changedFilesOnly = false
        defer { PBApplicationSettings.changedFilesOnly = previousChangedFilesOnly }

        let commits = loadedCommits()
        XCTAssertGreaterThanOrEqual(commits.count, 3)
        let tree = commits[0].tree
        let files = flattenedTree(tree).filter(\.leaf)
        let file = try XCTUnwrap(files.first { $0.fullPath == "nested/tracked.txt" })
        XCTAssertFalse(file.contents.isEmpty)
        XCTAssertNotNil(file.textContents())
        XCTAssertFalse(file.blame().isEmpty)
        XCTAssertFalse(file.log("%H").isEmpty)
        XCTAssertGreaterThan(file.fileSize(), 0)
        XCTAssertFalse(file.fullPath.isEmpty)
        XCTAssertFalse(file.displayPath.isEmpty)
        XCTAssertFalse(file.tmpFileNameForContents().isEmpty)
        historyController.commitController.setSelectedObjects([commits[0]])
        historyController.updateKeys()
        XCTAssertEqual(historyController.selectedCommits, [commits[0]])
        XCTAssertTrue(historyController.singleCommitSelected)

        historyController.selectedCommitDetailsIndex = 1
        historyController.commitController.setSelectedObjects(Array(commits.prefix(2)))
        historyController.updateKeys()
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)
        XCTAssertEqual(historyController.webCommits.count, 2)

        let replacement = PBGitCommit(repository: repository, andCommit: commits[0].gtCommit)
        historyController.selectedCommits = [commits[0]]
        historyController.commitController.content = [replacement]
        historyController.commitController.rearrangeObjects()
        historyController.reselectCommitAfterUpdate()
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === replacement)

        let stateCoordinator = PBHistoryStateCoordinator()
        let decisionWorkingState = PBUncommittedChanges(repository: repository)
        let stagingDecisionSelector = NSSelectorFromString("shouldShowStagingForSelection:")
        XCTAssertTrue(stateCoordinator.responds(to: stagingDecisionSelector))
        if stateCoordinator.responds(to: stagingDecisionSelector) {
            XCTAssertTrue(stateCoordinator.shouldShowStaging(for: [decisionWorkingState]))
            XCTAssertFalse(stateCoordinator.shouldShowStaging(for: []))
            XCTAssertFalse(stateCoordinator.shouldShowStaging(for: [commits[0]]))
            XCTAssertFalse(stateCoordinator.shouldShowStaging(for: [decisionWorkingState, commits[0]]))
            XCTAssertFalse(stateCoordinator.shouldShowStaging(for: [decisionWorkingState, decisionWorkingState]))
        }
        let secondReplacement = PBGitCommit(repository: repository, andCommit: commits[1].gtCommit)
        let duplicateSecondReplacement = PBGitCommit(repository: repository, andCommit: commits[1].gtCommit)
        let preserved = try XCTUnwrap(
            stateCoordinator.preservedSelection(
                [commits[1], commits[0], commits[1]],
                inContent: [secondReplacement, duplicateSecondReplacement, replacement]
            )
        )
        XCTAssertTrue(preserved[0] === secondReplacement)
        XCTAssertTrue(preserved[1] === replacement)
        XCTAssertTrue(preserved[2] === secondReplacement)
        XCTAssertNil(stateCoordinator.preservedSelection([commits[2]], inContent: [replacement]))
        XCTAssertNil(stateCoordinator.preservedSelection([decisionWorkingState], inContent: [replacement]))
        XCTAssertEqual(stateCoordinator.preservedSelection([commits[0]], inContent: [decisionWorkingState, replacement]), [replacement])

        historyController.commitController.content = commits
        historyController.commitController.rearrangeObjects()
        historyController.commitController.setSelectedObjects([commits[0]])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        XCTAssertNotNil(historyController.gitTree)
        XCTAssertFalse(historyController.gitTree?.children.isEmpty ?? true)
        XCTAssertFalse((historyController.treeController.content as? [Any])?.isEmpty ?? true)
        let leafNode = try XCTUnwrap(waitForTreeLeaf())
        let fileBrowser = try XCTUnwrap(historyController.value(forKey: "fileBrowser") as? NSOutlineView)
        let cell = NSTextFieldCell()
        historyController.outlineView(
            fileBrowser,
            willDisplay: cell,
            for: fileBrowser.tableColumns.first,
            item: leafNode
        )
        XCTAssertEqual(cell.lineBreakMode, .byTruncatingHead)
        XCTAssertNotNil(historyController.outlineView(
            fileBrowser,
            toolTipFor: cell,
            rect: nil,
            tableColumn: fileBrowser.tableColumns.first,
            item: leafNode,
            mouseLocation: .zero
        ))
        historyController.treeController.setSelectionIndexPath(leafNode.indexPath)
        let fileView = try XCTUnwrap(historyController.value(forKey: "fileView") as? NSObject)
        let modeControl = try XCTUnwrap(fileView.value(forKey: "modeControl") as? NSSegmentedControl)
        let nativeView = try XCTUnwrap(fileView.value(forKey: "nativeView") as? PBNativeContentView)
        for mode in 0 ... 3 {
            modeControl.selectedSegment = mode
            nativeView.showMessage("")
            fileView.perform(NSSelectorFromString("modeChanged:"), with: modeControl)
            XCTAssertTrue(waitForCondition {
                !nativeView.textView.string.isEmpty
            })
        }
        try fixture.git(["config", "--local", "gitx.diffSuppressionPatterns", "# ignored\n^generated/"])
        let selectionLeaf = try XCTUnwrap(waitForTreeNode(fullPath: "nested/tracked.txt"))
        historyController.treeController.setSelectionIndexPath(selectionLeaf.indexPath)
        XCTAssertFalse(historyController.treeController.selectionIndexPaths.isEmpty)
        historyController.saveFileBrowserSelection()
        historyController.treeController.setSelectionIndexPaths([])
        historyController.restoreFileBrowserSelection()
        pumpRunLoop()
        XCTAssertFalse(historyController.treeController.selectionIndexPaths.isEmpty)
        historyController.historyTreeSettingsDidChange(
            Notification(name: Notification.Name("PBHistoryTreeSettingsDidChangeNotification"))
        )

        try fixture.write("working state\n", to: "uncommitted.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()
        let workingState = historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        XCTAssertNotNil(workingState)
        XCTAssertTrue(workingState?.isWorkingState == true)
        PBApplicationSettings.changedFilesOnly = true
        let workingPresentation = PBHistoryTreePresentation(repository: repository)
        let flatWorkingTree = try workingPresentation.tree(for: XCTUnwrap(workingState))
        let flatWorkingPaths = flatWorkingTree.children.map(\.fullPath)
        XCTAssertEqual(flatWorkingPaths, ["uncommitted.txt"])
        try historyController.commitController.setSelectedObjects([XCTUnwrap(workingState)])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        let workingLeaf = try XCTUnwrap(waitForTreeNode(fullPath: "uncommitted.txt"))
        historyController.treeController.setSelectionIndexPath(workingLeaf.indexPath)
        modeControl.selectedSegment = 3
        fileView.perform(NSSelectorFromString("showFile"))
        pumpRunLoop(for: 1.0)
        let expectedSyntheticDiff =
            "diff --git a/uncommitted.txt b/uncommitted.txt\n" +
            "new file mode 100644\n" +
            "--- /dev/null\n" +
            "+++ b/uncommitted.txt\n" +
            "@@ -0,0 +1,1 @@\n" +
            "+working state\n"
        XCTAssertEqual(
            PBSyntheticUntrackedDiffFormatter.diff(forPath: "uncommitted.txt", contents: "working state\n"),
            expectedSyntheticDiff
        )
        XCTAssertTrue(
            nativeView.textView.string.contains("+working state"),
            "Rendered split diff did not contain the synthetic addition:\n\(nativeView.textView.string)"
        )
        let selectedWorkingState = try XCTUnwrap(workingState)
        historyController.commitController.setSelectedObjects([selectedWorkingState])
        historyController.updateKeys()
        historyController.selectedCommits = [selectedWorkingState]
        historyController.reselectCommitAfterUpdate()
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === workingState)
        historyController.updateUncommittedChanges()
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === workingState)
        let proposed = IndexSet(integersIn: 0 ... 1)
        XCTAssertEqual(
            tableCoordinator.tableView(historyController.commitList, selectionIndexesForProposedSelection: proposed),
            IndexSet(integer: 0)
        )
        let regularCommit = try XCTUnwrap(loadedCommits().first)
        try historyController.commitController.setSelectedObjects([XCTUnwrap(workingState), regularCommit])
        historyController.updateKeys()
        XCTAssertEqual(historyController.commitController.selectedObjects.count, 1)
        XCTAssertTrue(historyController.commitController.selectedObjects.first as AnyObject === workingState)

        try fixture.git(["clean", "-fd"])
        refreshIndex()
        XCTAssertTrue(waitForCondition(timeout: 10) {
            repository.index.indexChanges.isEmpty
        })
        historyController.updateUncommittedChanges()
        XCTAssertNil(historyController.commitController.value(forKey: "pinnedObject"))
        XCTAssertFalse(historyController.commitController.selectedObjects.isEmpty)
        historyController.updateStatus()
        XCTAssertEqual(historyController.status?.contains("commits loaded"), true)
    }

    func testHistoryTraversalRefreshPreservesExplicitColumnSortOverride() {
        let descriptor = NSSortDescriptor(key: "subject", ascending: true)
        historyController.commitController.sortDescriptors = [descriptor]

        historyController.historyTraversalSettingsDidChange(
            Notification(name: Notification.Name("PBHistoryTraversalSettingsDidChangeNotification"))
        )

        XCTAssertEqual(historyController.commitController.sortDescriptors, [descriptor])
        XCTAssertTrue(historyController.hasNonlinearPath())
        waitForHistory()
    }

    func testGitTreeFileSizeSupportsConcurrentPreviewLoads() throws {
        let commits = loadedCommits()
        let file = try XCTUnwrap(
            flattenedTree(commits[0].tree).first {
                $0.leaf && $0.fullPath == "nested/tracked.txt"
            }
        )
        let previewCount = 8
        let startGate = DispatchSemaphore(value: 0)
        let completion = DispatchGroup()
        let fileBox = UncheckedSendableBox(file)

        for _ in 0 ..< previewCount {
            completion.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                startGate.wait()
                _ = fileBox.value.fileSize()
                completion.leave()
            }
        }
        for _ in 0 ..< previewCount {
            startGate.signal()
        }

        XCTAssertEqual(completion.wait(timeout: .now() + 10), .success)
        XCTAssertGreaterThan(file.fileSize(), 0)
    }

    func testHistoryListPublishesUniqueBatchesAndFinishesEmptyLoads() throws {
        let historyList = try XCTUnwrap(repository.revisionList)
        let commits = loadedCommits()
        let addCommits = NSSelectorFromString("addCommitsFromArray:")

        historyList.setValue(true, forKey: "resetCommits")
        historyList.setValue(NSMutableSet(), forKey: "publishedCommitSHAs")
        _ = historyList.perform(addCommits, with: [commits[0], commits[0]])
        XCTAssertEqual(historyList.commits.count, 1)

        _ = historyList.perform(addCommits, with: [commits[0]])
        XCTAssertEqual(historyList.commits.count, 1)

        _ = historyList.perform(addCommits, with: [commits[1]])
        XCTAssertEqual(historyList.commits.count, 2)

        let currentRevList = try XCTUnwrap(
            historyList.value(forKey: "currentRevList") as? NSObject
        )
        let graphQueue = try XCTUnwrap(
            historyList.value(forKey: "graphQueue") as? OperationQueue
        )
        XCTAssertTrue(waitForCondition(timeout: 10) {
            currentRevList.value(forKey: "parsing") as? Bool == false && graphQueue.operationCount == 0
        })
        let currentCommits = currentRevList.value(forKey: "commits")
        let publishedCount = historyList.commits.count
        currentRevList.setValue(nil, forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue(NSNull(), forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue("invalid payload", forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue(NSMutableArray(), forKey: "commits")
        historyList.commits = [commits[0]]
        historyList.setValue(true, forKey: "resetCommits")
        historyList.isUpdating = true
        _ = historyList.perform(
            NSSelectorFromString("finishGraphingForQueue:revisionList:"),
            with: graphQueue,
            with: currentRevList
        )
        XCTAssertEqual(historyList.commits.count, 0)
        XCTAssertFalse(historyList.isUpdating)
        currentRevList.setValue(currentCommits, forKey: "commits")
        XCTAssertTrue(waitForCondition(timeout: 10) { graphQueue.operationCount == 0 })
    }

    func testHistoryFirstCommitAndScrollBoundaries() {
        let commits = loadedCommits()
        let workingState = PBUncommittedChanges(repository: repository)
        historyController.commitController.content = [workingState]
        historyController.commitController.rearrangeObjects()
        XCTAssertNil(historyController.value(forKey: "firstCommit"))

        historyController.commitController.content = [workingState] + Array(commits.prefix(3))
        historyController.commitController.sortDescriptors = []
        historyController.commitController.rearrangeObjects()
        XCTAssertTrue(historyController.value(forKey: "firstCommit") as AnyObject === commits[0])
        historyController.commitController.setSelectedObjects([commits[2]])

        let selector = NSSelectorFromString("scrollSelectionToTopOfViewFrom:")
        typealias ScrollImplementation = @convention(c) (AnyObject, Selector, Int) -> Void
        // swift6-safety-justification: This private Objective-C test seam has the declared id/SEL/NSInteger ABI.
        let scroll = unsafeBitCast(
            historyController.method(for: selector),
            to: ScrollImplementation.self
        )
        scroll(historyController, selector, NSNotFound)
        scroll(historyController, selector, 0)
    }

    func testCommitListAdjustScrollUsesDeterministicRowGeometry() throws {
        let commitListClass = try XCTUnwrap(NSClassFromString("GitX.PBCommitList") as? NSTableView.Type)
        let commitList = commitListClass.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let dataSource = CommitListDataSource(rowCount: 5)
        commitList.dataSource = dataSource
        commitList.rowHeight = 20
        commitList.intercellSpacing = .zero
        commitList.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SubjectColumn")))
        commitList.reloadData()
        commitList.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let selectedRect = commitList.rect(ofRow: 2)
        XCTAssertGreaterThan(selectedRect.origin.y, 0)
        let lowerProposedRect = NSRect(
            x: 0,
            y: selectedRect.origin.y - 1,
            width: 300,
            height: 100
        )
        commitList.setValue(false, forKey: "useAdjustScroll")
        XCTAssertEqual(commitList.adjustScroll(lowerProposedRect), lowerProposedRect)

        commitList.setValue(true, forKey: "useAdjustScroll")
        let rowHeight = Int(commitList.rowHeight)
        let lowerRemainder = Int(lowerProposedRect.origin.y) % rowHeight
        let adjustedLowerRect = commitList.adjustScroll(lowerProposedRect)
        XCTAssertEqual(
            adjustedLowerRect.origin.y,
            lowerProposedRect.origin.y + CGFloat(rowHeight - lowerRemainder)
        )
        XCTAssertGreaterThan(adjustedLowerRect.origin.y, lowerProposedRect.origin.y)

        let upperProposedRect = NSRect(
            x: 0,
            y: selectedRect.origin.y + CGFloat(rowHeight) + 1,
            width: 300,
            height: 100
        )
        let upperRemainder = Int(upperProposedRect.origin.y) % rowHeight
        let adjustedUpperRect = commitList.adjustScroll(upperProposedRect)
        XCTAssertEqual(adjustedUpperRect.origin.y, upperProposedRect.origin.y - CGFloat(upperRemainder))
        XCTAssertLessThan(adjustedUpperRect.origin.y, upperProposedRect.origin.y)
    }

    func testApplicationDelegateCoversActivationAndFileOpens() throws {
        // These app-delegate paths only run when the host application is
        // activated or receives file-open events, which never happens
        // deterministically in a headless suite; drive them directly.
        windowController.window?.orderOut(nil)
        _ = historyController.perform(
            NSSelectorFromString("applicationDidBecomeActive:"),
            with: NSNotification(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        )
        let delegate = try XCTUnwrap(NSApp.delegate as? NSObject)
        delegate.perform(
            NSSelectorFromString("applicationDidBecomeActive:"),
            with: NSNotification(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        )
        _ = delegate.perform(NSSelectorFromString("application:openFiles:"), with: NSApp, with: [fixture.path])
        pumpRunLoop(for: 1.0)
        for window in NSApp.windows
            where window.windowController is PBGitWindowController && window !== windowController.window
        {
            window.close()
        }
        for window in NSApp.windows where window.title.contains("Welcome") {
            window.close()
        }
    }

    func testCommitMessageTransformerAppliesRulesAndSurfacesRuleErrors() throws {
        try fixture.git(["config", "--local", "gitx.commitMessageReplacementRules", #"JIRA-(\d+) => ISSUE $1"#])
        var transformer = PBCommitMessageTransformer(repository: repository)
        XCTAssertEqual(try transformer.transformMessage("Fix JIRA-42 properly"), "Fix ISSUE 42 properly")

        try fixture.git(["config", "--local", "gitx.commitMessageReplacementRules", "rule-without-separator"])
        transformer = PBCommitMessageTransformer(repository: repository)
        XCTAssertThrowsError(try transformer.transformMessage("anything")) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("1"),
                "the missing-separator error names the offending line: \(error.localizedDescription)"
            )
        }

        try fixture.git(["config", "--local", "gitx.commitMessageReplacementRules", "([ => broken"])
        transformer = PBCommitMessageTransformer(repository: repository)
        XCTAssertThrowsError(try transformer.transformMessage("anything")) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        try fixture.git(["config", "--local", "--unset", "gitx.commitMessageReplacementRules"])
    }

    func testPushChoicesSurviveActiveRemoteRefreshFailureAndExplicitRetryChoice() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "PBRepositoryUISettings")
        defer {
            if let original {
                defaults.set(original, forKey: "PBRepositoryUISettings")
            } else {
                defaults.removeObject(forKey: "PBRepositoryUISettings")
            }
        }
        for choice in [true, false] {
            try verifyPushChoiceDuringFailedSubmission(choice)
        }
    }

    private func verifyPushChoiceDuringFailedSubmission(_ choice: Bool) throws {
        let settings = PBRepositoryUISettings(repository: repository)
        settings.pushAfterCommit = !choice
        try fixture.write("push recovery\n", to: "push-recovery-\(choice).txt")
        try fixture.git(["add", "--all"])
        let pane = try openStagingPane()
        let push = try XCTUnwrap(descendant(identifier: "PushAfterCommit", in: pane.view) as? NSButton)
        push.state = choice ? .on : .off

        let hookDirectory = URL(fileURLWithPath: fixture.path).appendingPathComponent("recovery-hooks-\(choice)")
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        let gate = hookDirectory.appendingPathComponent("release")
        let ready = hookDirectory.appendingPathComponent("ready")
        XCTAssertEqual(gate.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        let hook = hookDirectory.appendingPathComponent("pre-commit")
        try """
        #!/bin/sh
        printf ready > '\(ready.path)'
        IFS= read -r release < '\(gate.path)'
        exit 1

        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try fixture.git(["config", "core.hooksPath", hookDirectory.path])
        pane.commitMessageView.string = "Preserve exact push choice"
        let failed = expectation(forNotification: NSNotification.Name(PBGitIndexCommitHookFailed), object: repository.index)
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        XCTAssertTrue(waitForCondition(timeout: 10) { FileManager.default.fileExists(atPath: ready.path) })
        var writer: Int32 = -1
        XCTAssertTrue(waitForCondition(timeout: 10) {
            writer = gate.path.withCString { Darwin.open($0, O_WRONLY | O_NONBLOCK) }
            return writer >= 0
        })
        guard writer >= 0 else { return }
        var released = false
        func releaseHook() {
            guard !released else { return }
            released = true
            let bytes = Array("release\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
            Darwin.close(writer)
        }
        defer { releaseHook() }

        pane.perform(NSSelectorFromString("reloadPushRemotes"))
        try fixture.git(["remote", "remove", "origin"])
        pane.perform(NSSelectorFromString("reloadPushRemotes"))
        XCTAssertFalse(push.isEnabled)
        try fixture.git(["remote", "add", "origin", fixture.remotePath])
        pane.perform(NSSelectorFromString("reloadPushRemotes"))
        XCTAssertEqual(push.state, choice ? .on : .off, "Remote availability must not replace the submitted choice")
        releaseHook()
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(push.state, choice ? .on : .off)
        XCTAssertEqual(settings.pushAfterCommit, !choice, "Failed commits do not persist a preference")

        let retryChoice = !choice
        push.state = retryChoice ? .on : .off
        let action = try XCTUnwrap(push.action, "Push choice needs an explicit change action")
        XCTAssertTrue(NSApp.sendAction(action, to: push.target, from: push))
        pane.perform(NSSelectorFromString("reloadPushRemotes"))
        XCTAssertEqual(push.state, retryChoice ? .on : .off)
        let completed = expectation(forNotification: NSNotification.Name(PBGitIndexFinishedCommit), object: repository.index)
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let pushesBefore = stub.performedPushes
        try XCTUnwrap(stub.hookFailureRetryHandlers.last)()
        wait(for: [completed], timeout: 15)
        XCTAssertEqual(settings.pushAfterCommit, retryChoice)
        XCTAssertEqual(stub.performedPushes, pushesBefore + (retryChoice ? 1 : 0))
        refreshIndex()
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "Staging-Push-Choice-Recovery")
    }

    func testRepositoryUISettingsPersistCommitAndSidebarChoices() {
        let defaultsKey = "PBRepositoryUISettings"
        let defaults = UserDefaults.standard
        let originalSettings = defaults.object(forKey: defaultsKey)
        defer {
            if let originalSettings {
                defaults.set(originalSettings, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let settings = PBRepositoryUISettings(repository: repository)
        settings.pushAfterCommit = true
        settings.hideContainedBranches = true
        settings.historyRepositoryFactsInspectorVisible = true
        settings.sidebarVisibility = ["Stage": false]
        let reloaded = PBRepositoryUISettings(repository: repository)
        XCTAssertTrue(reloaded.pushAfterCommit)
        XCTAssertTrue(reloaded.hideContainedBranches)
        XCTAssertTrue(reloaded.historyRepositoryFactsInspectorVisible)
        XCTAssertFalse(reloaded.isSidebarGroupVisible("Stage"))
        XCTAssertTrue(reloaded.isSidebarGroupVisible("Remotes"))
    }

    @discardableResult
    private func openStagingPane() throws -> PBStagingViewController {
        historyController.selectedCommitDetailsIndex = 0
        refreshIndex()
        historyController.updateUncommittedChanges()
        XCTAssertTrue(
            waitForCondition {
                self.historyController.commitController.value(forKey: "pinnedObject") is PBUncommittedChanges
            },
            "the refreshed index publishes the uncommitted working state"
        )
        let workingState = try XCTUnwrap(
            historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        )
        historyController.commitController.setSelectedObjects([workingState])
        historyController.updateKeys()
        pumpRunLoop()
        return try XCTUnwrap(
            historyController.value(forKey: "stagingViewController") as? PBStagingViewController
        )
    }

    private func waitForIndexUpdate(during block: () throws -> Void) rethrows {
        let updated = expectation(
            forNotification: NSNotification.Name(PBGitIndexIndexUpdated),
            object: repository.index
        )
        try block()
        wait(for: [updated], timeout: 10)
        XCTAssertTrue(waitForCondition { !repository.index.mutationReconciliationPending })
        pumpRunLoop()
    }

    private func selectUnstagedFile(_ path: String, in pane: PBStagingViewController) throws {
        let files = try XCTUnwrap(
            pane.fileListController.unstagedFilesController.arrangedObjects as? [PBChangedFile]
        )
        let file = try XCTUnwrap(files.first { $0.path == path })
        pane.fileListController.unstagedFilesController.setSelectedObjects([file])
        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains(path)
        })
    }

    private func activateNativeDiffAction(_ title: String, in pane: PBStagingViewController) throws {
        let contentView = pane.diffPaneController.contentView
        XCTAssertTrue(waitForCondition {
            contentView.textView.string.contains(title)
        })
        let range = (contentView.textView.string as NSString).range(of: title)
        XCTAssertNotEqual(range.location, NSNotFound)
        let link = try XCTUnwrap(
            contentView.textView.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)
        )
        XCTAssertTrue(contentView.textView(contentView.textView, clickedOnLink: link, at: UInt(range.location)))
    }

    func testHunkDiscardAndCancellationPreserveCurrentConfirmationBehavior() throws {
        let original = try fixture.git(["show", "HEAD:nested/tracked.txt"])
        try fixture.write("initial discard fixture\n", to: "nested/tracked.txt")
        let pane = try openStagingPane()
        for confirm in [true, false] {
            let changed = "discard characterization \(confirm)\n"
            try fixture.write(changed, to: "nested/tracked.txt")
            waitForIndexUpdate { repository.index.refresh() }
            try selectUnstagedFile("nested/tracked.txt", in: pane)
            pane.diffPaneController.rerenderCurrentRequests()
            XCTAssertTrue(waitForCondition { pane.diffPaneController.contentView.textView.string.contains("+" + changed.trimmingCharacters(in: .newlines)) })
            try activateNativeDiffAction("Discard hunk", in: pane)
            let window = try XCTUnwrap(windowController.window)
            let sheet = try XCTUnwrap(window.attachedSheet)
            window.endSheet(sheet, returnCode: confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            if confirm {
                XCTAssertTrue(waitForCondition {
                    (try? String(contentsOf: URL(fileURLWithPath: self.fixture.path).appendingPathComponent("nested/tracked.txt"), encoding: .utf8)) == original && !self.repository.index.mutationReconciliationPending
                })
            } else {
                pumpRunLoop()
                XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent("nested/tracked.txt"), encoding: .utf8), changed)
                XCTAssertFalse(repository.index.mutationReconciliationPending)
            }
        }
    }

    func testWorkingTreeFoldersRemainAvailableToOpeningAndQuickLook() throws {
        let root = PBWorkingTree.root(for: repository)
        let folder = try XCTUnwrap(root.children.first { $0.path == "nested" })
        XCTAssertFalse(folder.leaf)
        let expected = try XCTUnwrap(repository.workingDirectoryURL()).appendingPathComponent("nested").path
        XCTAssertEqual(folder.tmpFileNameForContents(), expected)
        historyController.gitTree = root
        let node = try XCTUnwrap(waitForTreeNode(fullPath: "nested"))
        historyController.treeController.setSelectionIndexPath(node.indexPath)
        XCTAssertEqual(historyController.previewPanel(nil, previewItemAt: 0)?.previewItemURL?.path, expected)
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "History-Working-Folder-Preview")
        try FileManager.default.removeItem(atPath: expected)
        XCTAssertNil(historyController.previewPanel(nil, previewItemAt: 0))
        historyController.openSelectedFile(self)
    }

    func testAutomaticTreeFallbackPreservesRememberedFileUntilUserSelectsAnother() throws {
        let previous = PBApplicationSettings.changedFilesOnly
        PBApplicationSettings.changedFilesOnly = false
        defer { PBApplicationSettings.changedFilesOnly = previous }
        let original = try XCTUnwrap(repository.headCommit())
        historyController.commitController.setSelectedObjects([original])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        let selected = try XCTUnwrap(waitForTreeNode(fullPath: "nested/tracked.txt"))
        historyController.treeController.setSelectionIndexPath(selected.indexPath)
        historyController.saveFileBrowserSelection()
        try fixture.git(["rm", "nested/tracked.txt"])
        try fixture.git(["commit", "-m", "temporarily absent"])
        let absentSHA = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        historyController.refresh(self)
        XCTAssertTrue(waitForCondition { self.repository.revisionList?.commits.contains { ($0 as? PBGitCommit)?.sha == absentSHA } == true })
        let absent = try XCTUnwrap(loadedCommits().first { $0.sha == absentSHA })
        XCTAssertNotEqual(absent.sha, original.sha)
        historyController.commitController.content = [original, absent]
        historyController.commitController.setSelectedObjects([absent])
        historyController.updateKeys()
        XCTAssertFalse(try flattenedTree(XCTUnwrap(historyController.gitTree)).contains { $0.fullPath == "nested/tracked.txt" })
        historyController.commitController.setSelectedObjects([original])
        historyController.updateKeys()
        XCTAssertEqual((historyController.treeController.selectedObjects.first as? PBGitTree)?.fullPath, "nested/tracked.txt")
        let other = try XCTUnwrap(waitForTreeNode(fullPath: "FlowSample.swift"))
        historyController.treeController.setSelectionIndexPath(other.indexPath)
        let deliberatelySelected = (other.representedObject as? PBGitTree)?.fullPath
        historyController.commitController.setSelectedObjects([absent])
        historyController.updateKeys()
        historyController.commitController.setSelectedObjects([original])
        historyController.updateKeys()
        XCTAssertEqual((historyController.treeController.selectedObjects.first as? PBGitTree)?.fullPath, deliberatelySelected)
    }

    func testWorkingStateChangedTreeDeduplicatesTrackedDeletionAndUntrackedCopy() throws {
        let previous = PBApplicationSettings.changedFilesOnly
        defer { PBApplicationSettings.changedFilesOnly = previous }
        try fixture.git(["rm", "--cached", "nested/tracked.txt"])
        refreshIndex()
        PBApplicationSettings.changedFilesOnly = true
        let state = PBUncommittedChanges(repository: repository)
        let presentation = PBHistoryTreePresentation(repository: repository)
        let root = presentation.tree(for: state)
        let nodes = root.children.filter { $0.fullPath == "nested/tracked.txt" }
        XCTAssertEqual(nodes.count, 1)
        let node = try XCTUnwrap(nodes.first)
        XCTAssertEqual(presentation.displayTitle(for: node), "D  nested/tracked.txt")
        let file = try XCTUnwrap(repository.index.indexChanges.first { $0.rawPath == Data("nested/tracked.txt".utf8) })
        XCTAssertTrue(file.hasStagedChanges)
        XCTAssertTrue(file.hasUnstagedChanges)
        historyController.commitController.content = [state]
        historyController.commitController.setSelectedObjects([state])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "History-Deduplicated-Deletion-And-Untracked-Copy")
    }

    func testWorkingStateTreeAndDiffUseRawIdentityAcrossDisplayCollisionsAndDetachedParents() throws {
        let oldChangedFilesOnly = PBApplicationSettings.changedFilesOnly
        defer { PBApplicationSettings.changedFilesOnly = oldChangedFilesOnly }
        let label = "raw/nested/collision\\xFF.txt"
        try fixture.write("literal sentinel\n", to: label)
        _ = try openStagingPane()
        let index = repository.index
        let before = index.indexChanges
        let invalidBytes = Data(Array("raw/nested/collision".utf8) + [0xFF] + Array(".txt".utf8))
        let invalid = PBChangedFile(path: label, rawPath: invalidBytes)
        invalid.status = .DELETED
        invalid.hasStagedChanges = true
        invalid.hasUnstagedChanges = true
        invalid.worktreeStatus = .NEW
        index.willChangeValue(forKey: "indexChanges")
        index.setValue(NSMutableArray(array: [invalid] + before), forKey: "files")
        index.didChangeValue(forKey: "indexChanges")
        defer {
            index.willChangeValue(forKey: "indexChanges")
            index.setValue(NSMutableArray(array: before), forKey: "files")
            index.didChangeValue(forKey: "indexChanges")
        }
        func leaves(_ tree: PBGitTree) -> [PBWorkingTree] {
            tree.children.flatMap { child in
                child.leaf ? (child as? PBWorkingTree).map { [$0] } ?? [] : leaves(child)
            }
        }
        var root: PBWorkingTree? = PBWorkingTree.root(for: repository)
        let leaf = try XCTUnwrap(leaves(XCTUnwrap(root)).first { $0.fullPath == label })
        XCTAssertEqual(leaf.rawPath, Data(label.utf8))
        root = nil
        XCTAssertEqual(leaf.fullPath, label, "A selected leaf retains its complete raw identity after weak parents disappear")
        XCTAssertEqual(leaf.textContents(), "literal sentinel\n")
        PBApplicationSettings.changedFilesOnly = true
        historyController.updateUncommittedChanges()
        let state = try XCTUnwrap(historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges)
        let flat = PBHistoryTreePresentation(repository: repository).tree(for: state)
        let presented = try XCTUnwrap(flat.children.first { $0.fullPath == label } as? PBWorkingTree)
        XCTAssertEqual(presented.rawPath, Data(label.utf8))
        historyController.commitController.setSelectedObjects([state])
        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        let selected = try XCTUnwrap(waitForTreeNode(fullPath: label))
        historyController.treeController.setSelectionIndexPath(selected.indexPath)
        let fileView = try XCTUnwrap(historyController.value(forKey: "fileView") as? NSObject)
        let mode = try XCTUnwrap(fileView.value(forKey: "modeControl") as? NSSegmentedControl)
        let nativeView = try XCTUnwrap(fileView.value(forKey: "nativeView") as? PBNativeContentView)
        mode.selectedSegment = 3
        fileView.perform(NSSelectorFromString("showFile"))
        XCTAssertTrue(waitForCondition { nativeView.textView.string.contains("+literal sentinel") })
        XCTAssertFalse(nativeView.textView.string.contains("Staged —"), "A display collision must not select the raw file's staged side")
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "Working-State-Raw-Identity")
    }

    func testNulDelimitedMutationsPreserveNewlineFilenameAndDiscardPartiallyStagedAddition() throws {
        let path = "newline\nname.txt"
        try fixture.write("indexed portion\n", to: path)
        _ = try openStagingPane()
        let index = repository.index
        let added = try XCTUnwrap(index.indexChanges.first { $0.rawPath == Data(path.utf8) })
        waitForIndexUpdate { XCTAssertTrue(index.stageFiles([added])) }
        try fixture.write("worktree portion\n", to: path)
        refreshIndex()
        let partial = try XCTUnwrap(index.indexChanges.first { $0.rawPath == Data(path.utf8) })
        XCTAssertEqual(partial.stagedStatus, .NEW)
        XCTAssertEqual(partial.worktreeStatus, .MODIFIED)
        waitForIndexUpdate { index.discardChanges(for: [partial]) }
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(path), encoding: .utf8),
                       "indexed portion\n")
        XCTAssertTrue(partial.hasStagedChanges)
        XCTAssertFalse(partial.hasUnstagedChanges)
    }

    func testWorkingTreeBlameAndHistoryPreserveOrdinaryPathsWithOlderGit() throws {
        let specialPath = "legacy*.txt"
        try fixture.write("tracked wildcard\n", to: specialPath)
        try fixture.git(["--literal-pathspecs", "add", "--", specialPath])
        try fixture.git(["commit", "--quiet", "-m", "tracked wildcard filename"])
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let wrapper = testArtifactDirectory.appendingPathComponent("git-without-literal-pathspecs")
        let script = """
        #!/bin/sh
        reset=0
        help=0
        for argument in "$@"; do
            case "$argument" in
                --literal-pathspecs)
                    echo "unknown option: --literal-pathspecs" >&2
                    exit 129 ;;
                reset) reset=1 ;;
                -h) help=1 ;;
            esac
        done
        if [ "$reset" = 1 ] && [ "$help" = 1 ]; then
            echo "usage: git reset [--quiet] [<commit>] [--] [<paths>...]" >&2
            exit 129
        fi
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))

        let root = PBWorkingTree.root(for: repository)
        let folder = try XCTUnwrap(root.children.first { $0.path == "nested" })
        let tracked = try XCTUnwrap(folder.children.first { $0.path == "tracked.txt" } as? PBWorkingTree)
        let expectedCommit = try fixture.git(["log", "-1", "--pretty=format:%H", "--", "nested/tracked.txt"])

        XCTAssertTrue(tracked.blame().contains("author GitX Tests"), "Ordinary tracked filenames retain real blame on older Git")
        XCTAssertFalse(tracked.blame().contains("author Not Committed Yet"))
        XCTAssertTrue(tracked.log("%H").contains(expectedCommit), "Ordinary tracked filenames retain history on older Git")
        let special = try XCTUnwrap(root.children.first { $0.path == specialPath } as? PBWorkingTree)
        XCTAssertTrue(special.blame().isEmpty, "An unsupported tracked filename must not be mislabelled as uncommitted")
        XCTAssertTrue(special.log("%H").isEmpty, "An unsupported pathspec must not match other filenames")
    }

    func testWorkingTreeBlameAndHistoryUseLiteralWildcardIdentityWithModernGit() throws {
        let path = "wild*.txt"
        try fixture.write("literal wildcard contents\n", to: path)
        try fixture.write("sibling contents\n", to: "wild-other.txt")
        try fixture.git(["--literal-pathspecs", "add", "--", path, "wild-other.txt"])
        try fixture.git(["commit", "--quiet", "-m", "literal wildcard and sibling"])
        let root = PBWorkingTree.root(for: repository)
        let file = try XCTUnwrap(root.children.first { $0.path == path } as? PBWorkingTree)

        let blame = file.blame()
        XCTAssertTrue(blame.contains("\tliteral wildcard contents"))
        XCTAssertFalse(blame.contains("\tsibling contents"))
        XCTAssertTrue(file.log("%s").contains("literal wildcard and sibling"))
    }

    func testWorkingTreeAndStagingImageFallbackUseExplicitStageZeroForColonFilename() throws {
        let path = "1:foo"
        let contents = "literal index filename\n"
        try fixture.write(contents, to: path)
        try fixture.git(["add", "--", path])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path).appendingPathComponent(path))
        let pane = try openStagingPane()
        let root = PBWorkingTree.root(for: repository)
        let leaf = try XCTUnwrap(root.children.first { $0.fullPath == path } as? PBWorkingTree)
        XCTAssertEqual(leaf.contents, "literal index filename", "The existing text API trims the terminal LF while preserving the literal index filename")
        let file = try XCTUnwrap(repository.index.indexChanges.first { $0.rawPath == Data(path.utf8) })
        pane.diffPaneController.renderRequests([PBStagingDiffRequest(file: file, staged: true)])
        let view = pane.diffPaneController.contentView
        XCTAssertTrue(waitForCondition { view.textView.string.contains("+literal index filename") })
        let delegate = try XCTUnwrap(view.delegate)
        let image = delegate.nativeContentView?(view, imageDataForPath: path, section: 0, imageSource: [:])
        XCTAssertEqual(image, Data(contents.utf8))
    }

    func testBOMFilesystemActionsAddressTheExactSelectedFilename() throws {
        let names = ["notes.txt", "\u{FEFF}notes.txt", "\u{FEFF}"]
        for name in names {
            try fixture.write(name, to: name)
        }
        let pane = try openStagingPane()
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let files = repository.index.indexChanges.filter { names.contains($0.path) }
        XCTAssertEqual(files.count, names.count)
        let physicalPath = try XCTUnwrap(fixture.path.withCString { realpath($0, nil) })
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath))
        for file in files {
            let expected = root.appendingPathComponent(file.path)
            let open = NSMenuItem()
            open.representedObject = PBStagingActionSelection(action: .open, files: [file])
            pane.perform(NSSelectorFromString("openFiles:"), with: open)
            XCTAssertEqual(stub.openedURLs.last, expected)
            let reveal = NSMenuItem()
            reveal.representedObject = PBStagingActionSelection(action: .reveal, files: [file])
            pane.perform(NSSelectorFromString("revealInFinder:"), with: reveal)
            XCTAssertEqual(stub.revealedURLs.last, expected)
            var targets: [URL] = []
            pane.trashItemHandler = { targets.append($0); return true }
            let trash = NSMenuItem()
            trash.representedObject = PBStagingActionSelection(action: .trash, files: [file])
            waitForIndexUpdate { pane.perform(NSSelectorFromString("moveToTrash:"), with: trash) }
            XCTAssertEqual(targets, [expected])
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        }
    }

    func testSelectedIgnoreFilenamesAreRootAnchoredLiteralsAndLineBreaksAreRejectedAtomically() throws {
        let names = ["*.literal", "question?️⃣.md", "[bracket]", "#hash", "!bang", "back\\slash", " trailing space ", "nested/leaf"]
        for name in names {
            try fixture.write("literal", to: name)
        }
        try fixture.write("sibling", to: "other.literal")
        try fixture.write("sibling", to: "other/nested/leaf")
        let pane = try openStagingPane()
        let files = repository.index.indexChanges.filter { names.contains($0.path) }
        XCTAssertEqual(files.count, names.count)
        let item = NSMenuItem()
        item.representedObject = PBStagingActionSelection(action: .ignore, files: files)
        waitForIndexUpdate { pane.perform(NSSelectorFromString("ignoreFiles:"), with: item) }
        for name in names {
            XCTAssertNoThrow(try fixture.git(["check-ignore", "--quiet", "--", name]), name)
        }
        XCTAssertThrowsError(try fixture.git(["check-ignore", "--quiet", "--", "other.literal"]))
        XCTAssertThrowsError(try fixture.git(["check-ignore", "--quiet", "--", "other/nested/leaf"]))
        let ignoreURL = URL(fileURLWithPath: fixture.path).appendingPathComponent(".gitignore")
        let before = try Data(contentsOf: ignoreURL)
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        for name in ["newline\nname", "return\rname"] {
            let rejected = NSMenuItem()
            rejected.representedObject = PBStagingActionSelection(action: .ignore, files: [PBChangedFile(path: "ordinary"), PBChangedFile(path: name)])
            let count = stub.shownErrors.count
            pane.perform(NSSelectorFromString("ignoreFiles:"), with: rejected)
            XCTAssertEqual(stub.shownErrors.count, count + 1)
            XCTAssertEqual(try Data(contentsOf: ignoreURL), before)
        }
    }

    func testRootHEADFilenameDoesNotMakeRefreshOrResetAmbiguous() throws {
        try fixture.write("literal HEAD file", to: "HEAD")
        let pane = try openStagingPane()
        let file = try XCTUnwrap(repository.index.indexChanges.first { $0.rawPath == Data("HEAD".utf8) })
        waitForIndexUpdate { XCTAssertTrue(repository.index.stageFiles([file])) }
        XCTAssertTrue(repository.index.indexChanges.first { $0.rawPath == file.rawPath }?.hasStagedChanges == true)
        XCTAssertTrue(repository.index.diff(for: file, staged: true, contextLines: 3)?.contains("literal HEAD file") == true)
        waitForIndexUpdate { XCTAssertTrue(repository.index.unstageFiles([file])) }
        XCTAssertFalse(repository.index.indexChanges.first { $0.rawPath == file.rawPath }?.hasStagedChanges == true)
        withExtendedLifetime(pane) {}
    }

    func testRealGitIndexPreservesRawFilenameAndEscapedLiteralSiblingWhenUnstaging() throws {
        let label = "index-collision\\xFF.txt"
        let rawPath = Data(Array("index-collision".utf8) + [0xFF] + Array(".txt".utf8))
        try fixture.write("literal staged sentinel\n", to: label)
        try fixture.git(["add", "--", label])
        let blob = try fixture.git(["rev-parse", "HEAD:nested/tracked.txt"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitPath = try XCTUnwrap(PBGitBinary.path())
        func runRawGit(_ arguments: [String], input: Data? = nil) throws -> Data {
            let task = PBTask(launchPath: gitPath, arguments: arguments, inDirectory: fixture.path)
            task.additionalEnvironment = RepositoryTestGitEnvironment.isolated()
            task.standardInputData = input
            try task.launch()
            return task.standardOutputData
        }
        var record = Data("100644 \(blob)\t".utf8)
        record.append(rawPath)
        record.append(0)
        _ = try runRawGit(["update-index", "-z", "--index-info"], input: record)
        let before = try runRawGit(["ls-files", "-z"])
        XCTAssertNotNil(before.range(of: rawPath))
        _ = try openStagingPane()
        let index = repository.index
        let rawFile = try XCTUnwrap(index.indexChanges.first { $0.rawPath == rawPath })
        let literalFile = try XCTUnwrap(index.indexChanges.first { $0.rawPath == Data(label.utf8) })
        XCTAssertEqual(rawFile.path, literalFile.path)
        XCTAssertNil(rawFile.safePath)
        XCTAssertTrue(rawFile.hasStagedChanges)
        XCTAssertTrue(literalFile.hasStagedChanges)
        XCTAssertNil(index.diff(for: rawFile, staged: true, contextLines: 3), "An unsupported preview cannot read its escaped literal sibling")
        XCTAssertTrue(index.diff(for: literalFile, staged: true, contextLines: 3)?.contains("+literal staged sentinel") == true)
        waitForIndexUpdate { XCTAssertTrue(index.unstageFiles([rawFile])) }
        let after = try runRawGit(["ls-files", "-z"])
        XCTAssertNil(after.range(of: rawPath), "The modern reset command must preserve the raw path bytes")
        XCTAssertNotNil(after.range(of: Data(label.utf8)))
        XCTAssertFalse(index.indexChanges.contains { $0.rawPath == rawPath })
        XCTAssertTrue(index.indexChanges.first { $0.rawPath == Data(label.utf8) }?.hasStagedChanges == true)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(label), encoding: .utf8), "literal staged sentinel\n")
    }

    func testAmendComparisonChangeInvalidatesOlderRefreshAndKeepsControlsPending() throws {
        try fixture.write("amend pending\n", to: "amend-pending.txt")
        try fixture.git(["add", "amend-pending.txt"])
        let pane = try openStagingPane()
        let index = repository.index
        let oldGeneration = try XCTUnwrap(index.value(forKey: "mutationGeneration") as? NSNumber).uintValue
        let previousPaths = index.indexChanges.map(\.rawPath)

        index.isAmend = true

        XCTAssertEqual((index.value(forKey: "mutationGeneration") as? NSNumber)?.uintValue, oldGeneration + 1)
        XCTAssertTrue(index.mutationReconciliationPending, "Changing the comparison base awaits its authoritative refresh")
        let buttons = controls(in: pane.view).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.first { $0.accessibilityIdentifier() == "CommitButton" }?.isEnabled ?? true)
        XCTAssertFalse(buttons.first { $0.title == "Amend" }?.isEnabled ?? true)
        index.applyRefreshResult(PBIndexRefreshResult(staged: [:], unstaged: [:], untracked: [:], mutationGeneration: oldGeneration))
        XCTAssertEqual(index.indexChanges.map(\.rawPath), previousPaths, "The older HEAD snapshot must not replace HEAD^ rows")
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        XCTAssertTrue(index.indexChanges.contains { $0.path == "nested/tracked.txt" && $0.hasStagedChanges })
        index.isAmend = true
        XCTAssertEqual((index.value(forKey: "mutationGeneration") as? NSNumber)?.uintValue, oldGeneration + 1)
        XCTAssertFalse(index.mutationReconciliationPending, "Repeating the current comparison does not start a refresh")
    }

    func testFailedTrackedDiscardPreservesContentsAndRowsUntilRefreshFinishes() throws {
        let path = "nested/tracked.txt"
        let contents = "keep this modified worktree after failed discard\n"
        try fixture.write(contents, to: path)
        _ = try openStagingPane()
        let index = repository.index
        let file = try XCTUnwrap(index.indexChanges.first { $0.path == path })
        XCTAssertTrue(file.hasUnstagedChanges)
        let failed = expectation(forNotification: Notification.Name(PBGitIndexOperationFailed), object: index) { notification in
            (notification.userInfo?["description"] as? String)?.contains("Discarding changes failed") == true
        }
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)

        try withFailingGitExecutable {
            index.discardChanges(for: [file])
            XCTAssertTrue(index.mutationReconciliationPending)
            XCTAssertTrue(index.indexChanges.contains { $0 === file })
            wait(for: [failed, finished], timeout: 10)
            XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        }

        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(path), encoding: .utf8), contents)
        XCTAssertTrue(index.indexChanges.contains { $0 === file })
        XCTAssertTrue(file.hasUnstagedChanges)
        XCTAssertFalse(file.hasStagedChanges)
    }

    func testStagingImageExpansionResolvesTheIndexOnTheRendererQueue() throws {
        let path = "1:renderer.png"
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAS0lEQVR4nO3OsQ0AIAwDwYxDzQYMxpLU7BI2SApkufnC5csXY5+sdtcs99sHAAAA7AD1QdcDAADAD1AfdD0AAAD8APVB1wMAAMAOeNzXiIjVk5LGAAAAAElFTkSuQmCC"))
        let url = URL(fileURLWithPath: fixture.path).appendingPathComponent(path)
        try image.write(to: url)
        try fixture.git(["add", "--", path])
        try FileManager.default.removeItem(at: url)
        let pane = try openStagingPane()
        let file = try XCTUnwrap(repository.index.indexChanges.first { $0.rawPath == Data(path.utf8) })
        pane.diffPaneController.renderRequests([PBStagingDiffRequest(file: file, staged: true)])

        try activateNativeDiffAction("Show image", in: pane)

        let view = pane.diffPaneController.contentView
        XCTAssertTrue(waitForCondition {
            guard let storage = view.textView.textStorage else { return false }
            var attachmentFound = false
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value is NSTextAttachment {
                    attachmentFound = true
                    stop.pointee = true
                }
            }
            return attachmentFound
        }, "The real background renderer must resolve the literal stage-zero image without crossing actor isolation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSecondStageChunkFailureReconcilesSuccessfullyStagedFirstChunk() throws {
        for number in 0 ... 1000 {
            try fixture.write("chunk \(number)\n", to: String(format: "chunks/%04d.txt", number))
        }
        _ = try openStagingPane()
        let index = repository.index
        let selected = index.indexChanges.filter { $0.path.hasPrefix("chunks/") }
        XCTAssertEqual(selected.count, 1001)
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let marker = shellSingleQuoted(testArtifactDirectory.appendingPathComponent("first-stage-chunk").path)
        let wrapper = testArtifactDirectory.appendingPathComponent("git-fails-second-stage-chunk")
        let script = """
        #!/bin/sh
        update=0
        add=0
        stdin=0
        for argument in "$@"; do
            case "$argument" in
                update-index) update=1 ;;
                --add) add=1 ;;
                --stdin) stdin=1 ;;
            esac
        done
        if [ "$update" = 1 ] && [ "$add" = 1 ] && [ "$stdin" = 1 ]; then
            if [ -f \(marker) ]; then
                cat >/dev/null
                echo "expected second chunk failure" >&2
                exit 1
            fi
            : > \(marker)
        fi
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)

        XCTAssertFalse(index.stageFiles(selected))
        XCTAssertTrue(index.mutationReconciliationPending)
        XCTAssertTrue(selected.allSatisfy { !$0.hasStagedChanges }, "Pending rows retain their last accepted state")
        wait(for: [finished], timeout: 20)
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })

        let accepted = index.indexChanges.filter { $0.path.hasPrefix("chunks/") }
        XCTAssertEqual(accepted.filter(\.hasStagedChanges).count, 1000)
        XCTAssertEqual(accepted.filter(\.hasUnstagedChanges).count, 1)
        XCTAssertTrue(selected[0].hasStagedChanges, "Retained rows reflect the accepted partial mutation")
        XCTAssertFalse(selected[1000].hasStagedChanges)
        XCTAssertTrue(selected[1000].hasUnstagedChanges)
        XCTAssertTrue(index.indexChanges.first { $0.rawPath == selected[1000].rawPath } === selected[1000])
    }

    func testUnbornRepositoryStagesAndUnstagesAgainstEmptyTree() throws {
        let url = testArtifactDirectory.appendingPathComponent("unborn-repository")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let gitPath = try XCTUnwrap(PBGitBinary.path())
        func git(_ arguments: [String]) throws -> Data {
            let task = PBTask(launchPath: gitPath, arguments: arguments, inDirectory: url.path)
            task.additionalEnvironment = RepositoryTestGitEnvironment.isolated()
            try task.launch()
            return task.standardOutputData
        }
        _ = try git(["init", "--quiet", "--initial-branch=main"])
        let path = "unborn\nfile.txt"
        try "first contents\n".write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let unborn = try RepositoryTestGitRepository(url: url)
        let index = unborn.index
        func reconcile(_ operation: () -> Void) {
            let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
            operation()
            wait(for: [finished], timeout: 10)
            XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        }
        reconcile { index.refresh() }
        let file = try XCTUnwrap(index.indexChanges.first { $0.rawPath == Data(path.utf8) })
        XCTAssertTrue(file.hasUnstagedChanges)
        reconcile { XCTAssertTrue(index.stageFiles([file])) }
        XCTAssertTrue(file.hasStagedChanges)
        XCTAssertFalse(file.hasUnstagedChanges)
        XCTAssertEqual(try git(["ls-files", "-z"]), Data((path + "\0").utf8))
        reconcile { XCTAssertTrue(index.unstageFiles([file])) }
        XCTAssertFalse(file.hasStagedChanges)
        XCTAssertTrue(file.hasUnstagedChanges)
        XCTAssertEqual(file.worktreeStatus, .NEW)
        XCTAssertTrue(try git(["ls-files", "-z"]).isEmpty)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8), "first contents\n")
    }

    func testIndexMutationKeepsRowsUntilAuthoritativeRefreshAndUntrackedCopiesAreNotDiscarded() throws {
        try fixture.git(["rm", "--cached", "--", "nested/tracked.txt"])
        let pane = try openStagingPane()
        let index = repository.index
        let deleted = try XCTUnwrap(index.indexChanges.first { $0.path == "nested/tracked.txt" })
        XCTAssertEqual(deleted.stagedStatus, .DELETED)
        XCTAssertEqual(deleted.worktreeStatus, .NEW)
        XCTAssertTrue(deleted.hasStagedChanges)
        XCTAssertTrue(deleted.hasUnstagedChanges)
        let contents = try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(XCTUnwrap(deleted.safePath)), encoding: .utf8)
        index.discardChanges(for: [deleted])
        XCTAssertFalse(index.mutationReconciliationPending, "An untracked worktree copy is ineligible for discard")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(XCTUnwrap(deleted.safePath)), encoding: .utf8), contents)
        waitForIndexUpdate {
            XCTAssertTrue(index.unstageFiles([deleted]))
            XCTAssertTrue(index.mutationReconciliationPending)
            XCTAssertTrue(deleted.hasStagedChanges, "Synchronous Git completion must not guess the refreshed membership")
            XCTAssertEqual(deleted.stagedStatus, .DELETED)
        }
        XCTAssertFalse(index.mutationReconciliationPending)
        XCTAssertFalse(index.indexChanges.contains { $0.rawPath == deleted.rawPath })
        XCTAssertEqual(pane.fileListController.stagedFileCount, 0)
    }

    func testIndexRefreshRejectsOldMutationGenerationAndClearsPendingAfterFinishNotification() throws {
        try fixture.write("generation fixture\n", to: "generation.txt")
        refreshIndex()
        let index = repository.index
        let before = index.indexChanges
        let oldGeneration = try XCTUnwrap(index.value(forKey: "mutationGeneration") as? NSNumber)
        let oldReconciled = try XCTUnwrap(index.value(forKey: "reconciledMutationGeneration") as? NSNumber)
        index.setValue(100, forKey: "mutationGeneration")
        index.setValue(true, forKey: "mutationReconciliationPending")
        defer {
            index.setValue(oldGeneration, forKey: "mutationGeneration")
            index.setValue(oldReconciled, forKey: "reconciledMutationGeneration")
            index.setValue(false, forKey: "mutationReconciliationPending")
        }
        indexPublicationEvents = []
        let updated = expectation(forNotification: Notification.Name(PBGitIndexIndexUpdated), object: index)
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        NotificationCenter.default.addObserver(self, selector: #selector(recordIndexPublication(_:)), name: Notification.Name(PBGitIndexIndexUpdated), object: index)
        NotificationCenter.default.addObserver(self, selector: #selector(recordIndexPublication(_:)), name: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        defer {
            NotificationCenter.default.removeObserver(self, name: Notification.Name(PBGitIndexIndexUpdated), object: index)
            NotificationCenter.default.removeObserver(self, name: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        }
        index.applyRefreshResult(PBIndexRefreshResult(staged: [:], unstaged: [:], untracked: [:], mutationGeneration: 99))
        XCTAssertEqual(index.indexChanges.map(\.rawPath), before.map(\.rawPath))
        index.applyRefreshResult(PBIndexRefreshResult(staged: nil, unstaged: nil, untracked: nil, mutationGeneration: 100))
        index.postIndexRefreshFinished()
        wait(for: [updated, finished], timeout: 3)
        XCTAssertEqual(indexPublicationEvents, ["updated", "finished"])
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        XCTAssertEqual(index.indexChanges.map(\.rawPath), before.map(\.rawPath), "Failed components retain the last known snapshot")
    }

    func testCommitCompletionReconcilesBeforeControlsReturnIncludingPostCommitHookFailure() throws {
        let hook = URL(fileURLWithPath: fixture.path).appendingPathComponent(".git/hooks/post-commit")
        for hookSucceeds in [true, false] {
            let path = hookSucceeds ? "commit-pending.txt" : "commit-posthook-failed.txt"
            try fixture.write("created commit\n", to: path)
            try fixture.git(["add", path])
            if !hookSucceeds {
                try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            }
            let pane = try openStagingPane()
            let index = repository.index
            let generation = try XCTUnwrap(index.value(forKey: "mutationGeneration") as? NSNumber).uintValue
            pane.commitMessageView.string = "Commit reconciliation \(hookSucceeds)"
            let completed = expectation(forNotification: Notification.Name(PBGitIndexFinishedCommit), object: index)
            NotificationCenter.default.addObserver(self, selector: #selector(assertPendingAtCommitCompletion(_:)), name: Notification.Name(PBGitIndexFinishedCommit), object: index)
            pane.perform(NSSelectorFromString("commit:"), with: nil)
            wait(for: [completed], timeout: 20)
            NotificationCenter.default.removeObserver(self, name: Notification.Name(PBGitIndexFinishedCommit), object: index)
            XCTAssertEqual((index.value(forKey: "mutationGeneration") as? NSNumber)?.uintValue, generation + 1)
            XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending && index.indexChanges.isEmpty })
            XCTAssertEqual(try fixture.git(["show", "HEAD:" + path]), "created commit\n")
        }
    }

    func testStagingRawDisplayCollisionDisablesStringActionsAndShowsUnavailablePreview() throws {
        let label = "collision\\xFF.txt"
        try fixture.write("literal sentinel\n", to: label)
        let pane = try openStagingPane()
        let fileList = pane.fileListController
        fileList.setListLayout(.sectionedList)
        let invalidBytes = Data(Array("collision".utf8) + [0xFF] + Array(".txt".utf8))
        let invalid = PBChangedFile(path: label, rawPath: invalidBytes)
        invalid.hasUnstagedChanges = true
        let before = repository.index.indexChanges
        repository.index.willChangeValue(forKey: "indexChanges")
        repository.index.setValue(NSMutableArray(array: before + [invalid]), forKey: "files")
        repository.index.didChangeValue(forKey: "indexChanges")
        defer {
            repository.index.willChangeValue(forKey: "indexChanges")
            repository.index.setValue(NSMutableArray(array: before), forKey: "files")
            repository.index.didChangeValue(forKey: "indexChanges")
        }
        fileList.applyFilterAndSort()
        fileList.unstagedFilesController.setSelectedObjects([invalid])
        pane.diffPaneController.renderRequests([PBStagingDiffRequest(file: invalid, staged: false)])
        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains("cannot be represented for preview")
        })
        XCTAssertFalse(pane.diffPaneController.contentView.textView.string.contains("literal sentinel"))
        for selector in ["openFiles:", "revealInFinder:", "ignoreFiles:", "moveToTrash:", "openExternalDiff:"] {
            let item = NSMenuItem(title: selector, action: NSSelectorFromString(selector), keyEquivalent: "")
            XCTAssertFalse(pane.validate(item), selector)
        }
        let stage = NSMenuItem(title: "Stage Changes", action: NSSelectorFromString("stageFiles:"), keyEquivalent: "")
        XCTAssertTrue(pane.validate(stage), "Raw byte filenames remain stageable")
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let opened = stub.openedURLs
        let revealed = stub.revealedURLs
        pane.perform(NSSelectorFromString("openFiles:"), with: nil)
        pane.perform(NSSelectorFromString("revealInFinder:"), with: nil)
        XCTAssertEqual(stub.openedURLs, opened)
        XCTAssertEqual(stub.revealedURLs, revealed)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent(label), encoding: .utf8),
                       "literal sentinel\n")
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "Staging-Raw-Filename-Unavailable")
    }

    func testPendingIndexReconciliationDisablesMutationAndCommitControlsWithoutClearingSelection() throws {
        try fixture.write("staged portion\n", to: "pending-controls.txt")
        try fixture.git(["add", "pending-controls.txt"])
        try fixture.write("staged portion\nworktree portion\n", to: "pending-controls.txt")
        let pane = try openStagingPane()
        let fileList = pane.fileListController
        fileList.setListLayout(.sectionedList)
        try selectUnstagedFile("pending-controls.txt", in: pane)
        let selected = try XCTUnwrap(fileList.unstagedFilesController.selectedObjects as? [PBChangedFile])
        let completedDiff = pane.diffPaneController.contentView.textView.string
        let buttons = Mirror(reflecting: pane).children.compactMap { $0.value as? NSButton }
        let commit = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "CommitButton" })
        let amend = try XCTUnwrap(buttons.first { $0.title == "Amend" })
        XCTAssertTrue(commit.isEnabled)
        repository.index.setValue(true, forKey: "mutationReconciliationPending")
        defer { repository.index.setValue(false, forKey: "mutationReconciliationPending") }
        pumpRunLoop()
        XCTAssertFalse(commit.isEnabled)
        XCTAssertFalse(amend.isEnabled)
        for selector in ["stageFiles:", "unstageFiles:", "discardFiles:", "discardFilesForcibly:", "ignoreFiles:", "moveToTrash:", "toggleAmendCommit:"] {
            XCTAssertFalse(pane.validate(NSMenuItem(title: selector, action: NSSelectorFromString(selector), keyEquivalent: "")), selector)
        }
        XCTAssertEqual((fileList.unstagedFilesController.selectedObjects as? [PBChangedFile])?.map(\.rawPath),
                       selected.map(\.rawPath))
        XCTAssertEqual(pane.diffPaneController.contentView.textView.string, completedDiff)
        for row in 0 ..< fileList.sectionedTable.numberOfRows {
            if let cell = fileList.sectionedTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? PBStagingFileCellView {
                XCTAssertFalse(cell.checkbox.isEnabled)
            }
        }
        let indexBefore = try fixture.git(["show", ":pending-controls.txt"])
        pane.perform(NSSelectorFromString("stageFiles:"), with: nil)
        pane.perform(NSSelectorFromString("discardFilesForcibly:"), with: nil)
        XCTAssertEqual(try fixture.git(["show", ":pending-controls.txt"]), indexBefore)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.path).appendingPathComponent("pending-controls.txt"), encoding: .utf8),
                       "staged portion\nworktree portion\n")
        repository.index.setValue(false, forKey: "mutationReconciliationPending")
        pumpRunLoop()
        XCTAssertTrue(commit.isEnabled)
        XCTAssertTrue(amend.isEnabled)
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "Staging-Reconciled-Controls")
    }

    func testPartialStagingPreservesExecutableAndSymbolicLinkModes() throws {
        try fixture.write("first line\nsecond line\n", to: "executable.sh")
        let executableURL = URL(fileURLWithPath: fixture.path).appendingPathComponent("executable.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let brokenLinkURL = URL(fileURLWithPath: fixture.path).appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: brokenLinkURL.path, withDestinationPath: "missing-target")

        let pane = try openStagingPane()
        try selectUnstagedFile("executable.sh", in: pane)
        try waitForIndexUpdate {
            try activateNativeDiffAction("Stage line", in: pane)
        }
        let executableEntry = try fixture.git(["ls-files", "--stage", "--", "executable.sh"])
        XCTAssertTrue(executableEntry.hasPrefix("100755 "), executableEntry)
        XCTAssertEqual(try fixture.git(["show", ":executable.sh"]), "first line\n")

        try selectUnstagedFile("broken-link", in: pane)
        try waitForIndexUpdate {
            try activateNativeDiffAction("Stage hunk", in: pane)
        }
        let linkEntry = try fixture.git(["ls-files", "--stage", "--", "broken-link"])
        XCTAssertTrue(linkEntry.hasPrefix("120000 "), linkEntry)
        XCTAssertEqual(try fixture.git(["show", ":broken-link"]), "missing-target")
    }

    func testFirstPatchReconciliationRefreshesStatCacheBeforePublishingRows() throws {
        let defaults = UserDefaults.standard
        let defaultsDomain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let previousWatcherPreference = defaults.persistentDomain(forName: defaultsDomain)?["PBUseRepositoryWatcher"]
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        defer {
            if let previousWatcherPreference {
                defaults.set(previousWatcherPreference, forKey: "PBUseRepositoryWatcher")
            } else {
                defaults.removeObject(forKey: "PBUseRepositoryWatcher")
            }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        try fixture.write(" second\n", to: "nested/tracked.txt")
        let patch = try fixture.git(["diff", "--unified=0", "--", "nested/tracked.txt"])
        let index = PBGitIndex(repository: repository)
        let initial = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        index.refresh()
        wait(for: [initial], timeout: 10)
        let tracked = try XCTUnwrap(index.indexChanges.first { $0.path == "nested/tracked.txt" })
        XCTAssertTrue(tracked.hasUnstagedChanges)
        XCTAssertFalse(tracked.hasStagedChanges)
        let pinnedIndex = UncheckedSendableBox(index)
        let firstPublication = expectation(
            forNotification: Notification.Name(PBGitIndexIndexUpdated), object: index
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            let firstRows = pinnedIndex.value.indexChanges
            XCTAssertEqual(firstRows.count, 1)
            XCTAssertTrue(firstRows.first?.hasStagedChanges == true)
            XCTAssertFalse(
                firstRows.first?.hasUnstagedChanges == true,
                "The first accepted refresh must not publish a phantom unstaged row for the staged hunk"
            )
            return true
        }

        XCTAssertTrue(index.applyPatch(patch, stage: true, reverse: false))
        XCTAssertTrue(index.mutationReconciliationPending)
        index.refresh() // A watcher refresh may arrive before asynchronous stat-cache work finishes.
        wait(for: [firstPublication], timeout: 10)
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        XCTAssertTrue(tracked.hasStagedChanges)
        XCTAssertFalse(tracked.hasUnstagedChanges)
        XCTAssertEqual(try fixture.git(["diff-files", "-z"]), "")
        XCTAssertEqual(try fixture.git(["show", ":0:nested/tracked.txt"]), " second\n")
    }

    func testMutationReconciliationContinuesWhenStatCacheRefreshFails() throws {
        try fixture.write("stage despite stat refresh error\n", to: "nested/tracked.txt")
        let index = PBGitIndex(repository: repository)
        let initial = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)
        index.refresh()
        wait(for: [initial], timeout: 10)
        let tracked = try XCTUnwrap(index.indexChanges.first { $0.path == "nested/tracked.txt" })
        let originalGit = try XCTUnwrap(PBGitBinary.path())
        defer { XCTAssertTrue(PBGitBinary.accept(originalGit)) }
        let marker = testArtifactDirectory.appendingPathComponent("failed-post-mutation-stat-refresh")
        let wrapper = testArtifactDirectory.appendingPathComponent("git-fails-stat-refresh")
        let script = """
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = --refresh ]; then
                : > \(shellSingleQuoted(marker.path))
                echo "expected stat-cache refresh failure" >&2
                exit 1
            fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        XCTAssertTrue(PBGitBinary.accept(wrapper.path))
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)

        XCTAssertTrue(index.stageFiles([tracked]))
        XCTAssertTrue(index.mutationReconciliationPending)
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Post-mutation reconciliation attempted to refresh the stat cache")
        XCTAssertTrue(tracked.hasStagedChanges)
        XCTAssertFalse(tracked.hasUnstagedChanges)
    }

    func testBareMutationReconciliationCompletesWithoutAStatCacheCallback() throws {
        let bareRepository = try RepositoryTestGitRepository(url: URL(fileURLWithPath: fixture.remotePath))
        let index = PBGitIndex(repository: bareRepository)
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh), object: index)

        XCTAssertFalse(index.applyPatch("", stage: true, reverse: false))
        XCTAssertTrue(index.mutationReconciliationPending)
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(waitForCondition { !index.mutationReconciliationPending })
        XCTAssertTrue(index.indexChanges.isEmpty)
        withExtendedLifetime(bareRepository) {}
    }

    func testStagingAlwaysDisplaysWhitespaceAndAppliesTheDisplayedPatch() throws {
        let defaults = UserDefaults.standard
        let obsoleteKey = "PBStagingIgnoreWhitespace"
        let previousValue = defaults.object(forKey: obsoleteKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: obsoleteKey)
            } else {
                defaults.removeObject(forKey: obsoleteKey)
            }
        }
        defaults.set(true, forKey: obsoleteKey)
        try fixture.write(" second\nadded\n", to: "nested/tracked.txt")

        let pane = try openStagingPane()
        try selectUnstagedFile("nested/tracked.txt", in: pane)
        let rendered = pane.diffPaneController.contentView.textView.string
        XCTAssertTrue(rendered.contains("│ -second"), rendered)
        XCTAssertTrue(rendered.contains("│ + second"), rendered)
        XCTAssertFalse(pane.responds(to: NSSelectorFromString("changeWhitespaceVisibility:")))

        let optionsMenu = try XCTUnwrap(
            Mirror(reflecting: pane).children
                .compactMap { $0.value as? NSMenu }
                .first { $0.items.contains { $0.title == "External Diff" } }
        )
        XCTAssertNil(optionsMenu.item(withTitle: "Show whitespace"))
        XCTAssertNil(optionsMenu.item(withTitle: "Ignore whitespace"))

        try waitForIndexUpdate {
            try activateNativeDiffAction("Stage hunk", in: pane)
        }
        XCTAssertEqual(try fixture.git(["show", ":nested/tracked.txt"]), " second\nadded\n")
    }

    func testStagingDiffContextChangesRerenderTheCurrentSelection() throws {
        let defaults = UserDefaults.standard
        let contextKey = "PBStageDiffContextLines"
        let previousContext = defaults.object(forKey: contextKey)
        defer {
            if let previousContext {
                defaults.set(previousContext, forKey: contextKey)
            } else {
                defaults.removeObject(forKey: contextKey)
            }
        }

        let original = (1 ... 9).map { "context line \($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(original, to: "context.txt")
        try fixture.git(["add", "context.txt"])
        try fixture.git(["commit", "--quiet", "-m", "add context fixture"])
        try fixture.write(
            original.replacingOccurrences(of: "context line 5", with: "changed context line 5"),
            to: "context.txt"
        )

        let pane = try openStagingPane()
        pane.diffPaneController.contextLines = 0
        try selectUnstagedFile("context.txt", in: pane)
        XCTAssertFalse(pane.diffPaneController.contentView.textView.string.contains("context line 1"))

        pane.diffPaneController.contextLines = 8
        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains("context line 1")
        })
    }

    func testEmptyStagingSelectionImmediatelyInvalidatesPendingDiffs() throws {
        try fixture.write("pending\n", to: "pending.txt")
        let pane = try openStagingPane()
        let pendingFile = try XCTUnwrap(
            (pane.fileListController.unstagedFilesController.arrangedObjects as? [PBChangedFile])?
                .first { $0.path == "pending.txt" }
        )
        pane.diffPaneController.renderRequests([
            PBStagingDiffRequest(file: pendingFile, staged: false),
        ])

        pane.diffPaneController.renderRequests([])

        XCTAssertTrue(pane.diffPaneController.contentView.textView.string.contains("No file selected"))
    }

    func testStagingDiffFailureShowsUnderlyingDetailWithoutControls() throws {
        let missingPath = "missing-diff.txt"
        try fixture.write("working state\n", to: "trigger.txt")
        let missingURL = URL(fileURLWithPath: fixture.path).appendingPathComponent(missingPath)
        let expectedDetail: String
        do {
            _ = try FileManager.default.attributesOfItem(atPath: missingURL.path)
            XCTFail("the missing-file fixture unexpectedly exists")
            return
        } catch {
            expectedDetail = error.localizedDescription
        }
        let missingFile = PBChangedFile(path: missingPath)
        missingFile.status = .NEW
        missingFile.hasStagedChanges = false
        missingFile.hasUnstagedChanges = true
        let pane = try openStagingPane()
        try selectUnstagedFile("trigger.txt", in: pane)

        pane.diffPaneController.renderRequests([
            PBStagingDiffRequest(file: missingFile, staged: false),
        ])

        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains("Diff unavailable — \(missingPath)")
        })
        let rendered = pane.diffPaneController.contentView.textView.string
        XCTAssertTrue(rendered.contains("Half Dark could not load the diff for \(missingPath)."), rendered)
        XCTAssertTrue(rendered.contains(expectedDetail), rendered)
        XCTAssertFalse(rendered.contains("Stage hunk"), rendered)
        XCTAssertFalse(rendered.contains("Stage line"), rendered)
    }

    func testTrackedStagingDiffFailureIncludesGitCommandDetail() throws {
        try fixture.write("modified for a failing diff\n", to: "nested/tracked.txt")
        let pane = try openStagingPane()
        try selectUnstagedFile("nested/tracked.txt", in: pane)
        let trackedFile = try XCTUnwrap(
            (pane.fileListController.unstagedFilesController.arrangedObjects as? [PBChangedFile])?
                .first { $0.path == "nested/tracked.txt" }
        )
        let indexURL = URL(fileURLWithPath: fixture.path).appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: indexURL)
        defer { try? originalIndex.write(to: indexURL, options: .atomic) }
        try Data("invalid index".utf8).write(to: indexURL, options: .atomic)

        pane.diffPaneController.renderRequests([
            PBStagingDiffRequest(file: trackedFile, staged: false),
        ])

        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains(
                "Diff unavailable — nested/tracked.txt"
            )
        })
        let rendered = pane.diffPaneController.contentView.textView.string
        XCTAssertTrue(rendered.contains("Task exited unsuccessfully"), rendered)
        XCTAssertTrue(rendered.contains("returned a non-zero return code"), rendered)
        XCTAssertTrue(rendered.contains("Exit status:"), rendered)
        XCTAssertTrue(rendered.contains("index file"), rendered)
    }

    func testSectionedActionPolicyUsesOneSnapshotForMenusAndExecution() throws {
        try fixture.write("staged\n", to: "staged-only.txt")
        try fixture.write("staged portion\n", to: "partial.txt")
        try fixture.git(["add", "staged-only.txt", "partial.txt"])
        try fixture.write("staged portion\nworktree portion\n", to: "partial.txt")
        try fixture.write("unstaged\n", to: "unstaged-only.txt")

        let pane = try openStagingPane()
        let fileList = pane.fileListController
        fileList.setListLayout(.sectionedList)
        XCTAssertEqual(fileList.layout, .sectionedList)
        let stagedController = fileList.stagedFilesController
        let unstagedController = fileList.unstagedFilesController
        let stagedFiles = try XCTUnwrap(stagedController.arrangedObjects as? [PBChangedFile])
        let unstagedFiles = try XCTUnwrap(unstagedController.arrangedObjects as? [PBChangedFile])
        let stagedOnly = try XCTUnwrap(stagedFiles.first { $0.path == "staged-only.txt" })
        let stagedPartial = try XCTUnwrap(stagedFiles.first { $0.path == "partial.txt" })
        let unstagedPartial = try XCTUnwrap(unstagedFiles.first { $0.path == "partial.txt" })
        let unstagedOnly = try XCTUnwrap(unstagedFiles.first { $0.path == "unstaged-only.txt" })
        stagedController.setSelectedObjects([stagedOnly, stagedPartial])
        unstagedController.setSelectedObjects([unstagedPartial, unstagedOnly])

        let menu = try XCTUnwrap(fileList.sectionedTable.menu)
        func item(_ selectorName: String) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString(selectorName) })
        }
        func snapshot(_ selectorName: String) throws -> (NSMenuItem, [String], Bool) {
            let menuItem = try item(selectorName)
            let enabled = pane.validate(menuItem)
            let selection = try XCTUnwrap(menuItem.representedObject as? PBStagingActionSelection)
            return (menuItem, selection.files.map(\.path), enabled)
        }

        let stage = try snapshot("stageFiles:")
        XCTAssertEqual(stage.1, ["partial.txt", "unstaged-only.txt"])
        XCTAssertEqual(stage.0.title, "Stage 2 Files")
        XCTAssertTrue(stage.2)
        let unstage = try snapshot("unstageFiles:")
        XCTAssertEqual(unstage.1, ["partial.txt", "staged-only.txt"])
        XCTAssertEqual(unstage.0.title, "Unstage 2 Files")
        XCTAssertTrue(unstage.2)

        for selector in ["discardFiles:", "discardFilesForcibly:", "ignoreFiles:", "moveToTrash:"] {
            XCTAssertEqual(try snapshot(selector).1, ["partial.txt", "unstaged-only.txt"], selector)
        }
        let open = try snapshot("openFiles:")
        let reveal = try snapshot("revealInFinder:")
        let union = ["partial.txt", "staged-only.txt", "unstaged-only.txt"]
        XCTAssertEqual(open.1, union)
        XCTAssertEqual(open.0.title, "Open 3 Files")
        XCTAssertEqual(reveal.1, union)
        XCTAssertEqual(reveal.0.title, "Reveal 3 Files in Finder")

        stagedController.setSelectedObjects([])
        unstagedController.setSelectedObjects([])
        pane.perform(NSSelectorFromString("openFiles:"), with: open.0)
        pane.perform(NSSelectorFromString("revealInFinder:"), with: reveal.0)
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        XCTAssertEqual(stub.openedURLs.map(\.lastPathComponent), union)
        XCTAssertEqual(stub.revealedURLs.map(\.lastPathComponent), union)
        XCTAssertNil(
            open.0.representedObject,
            "execution consumes the snapshot so menu items do not retain the last selection"
        )
        XCTAssertNil(reveal.0.representedObject)

        stagedController.setSelectedObjects([stagedOnly])
        unstagedController.setSelectedObjects([])
        for selector in ["discardFiles:", "discardFilesForcibly:", "ignoreFiles:", "moveToTrash:"] {
            let stagedOnlyResult = try snapshot(selector)
            XCTAssertTrue(stagedOnlyResult.1.isEmpty, selector)
            XCTAssertFalse(stagedOnlyResult.2, selector)
        }

        stagedController.setSelectedObjects([stagedOnly])
        unstagedController.setSelectedObjects([unstagedOnly])
        fileList.setListLayout(.splitTables)
        XCTAssertEqual(stagedController.selectedObjects.count, 1)
        XCTAssertTrue(unstagedController.selectedObjects.isEmpty)
        let splitMainItem = NSMenuItem(
            title: "Open Files",
            action: NSSelectorFromString("openFiles:"),
            keyEquivalent: ""
        )
        let splitMainMenu = NSMenu()
        splitMainMenu.addItem(splitMainItem)
        XCTAssertTrue(pane.validate(splitMainItem))
        XCTAssertEqual(
            (splitMainItem.representedObject as? PBStagingActionSelection)?.files.map(\.path),
            ["staged-only.txt"],
            "a non-contextual split command uses the sole active side"
        )

        waitForIndexUpdate {
            pane.perform(NSSelectorFromString("stageFiles:"), with: stage.0)
        }
        XCTAssertEqual(try fixture.git(["show", ":partial.txt"]), "staged portion\nworktree portion\n")
        XCTAssertEqual(try fixture.git(["show", ":unstaged-only.txt"]), "unstaged\n")
        XCTAssertNil(stage.0.representedObject)
    }

    func testFilteredStagedFileRemainsCommittable() throws {
        try fixture.write("hidden staged change\n", to: "hidden-staged.txt")
        try fixture.git(["add", "hidden-staged.txt"])
        let pane = try openStagingPane()
        let fileList = pane.fileListController

        pane.searchField.stringValue = "does-not-match"
        if let action = pane.searchField.action {
            _ = NSApp.sendAction(action, to: pane.searchField.target, from: pane.searchField)
        }
        XCTAssertTrue((fileList.stagedFilesController.arrangedObjects as? [PBChangedFile])?.isEmpty == true)
        XCTAssertEqual(fileList.stagedFileCount, 1)
        let commitButton = try XCTUnwrap(
            Mirror(reflecting: pane).children
                .compactMap { $0.value as? NSButton }
                .first { $0.accessibilityIdentifier() == "CommitButton" }
        )
        XCTAssertTrue(commitButton.isEnabled)

        let initialHead = try fixture.git(["rev-parse", "HEAD"])
        pane.commitMessageView.string = "Commit hidden staged file"
        let committed = expectation(
            forNotification: NSNotification.Name(PBGitIndexFinishedCommit),
            object: repository.index
        )
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        wait(for: [committed], timeout: 20)
        refreshIndex()
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
        XCTAssertEqual(fileList.stagedFileCount, 0)
    }

    func testStagingLayoutsShareLocalizedFilteringAndOrdering() throws {
        for path in [
            "Alpha.txt",
            "alpha-lower.txt",
            "Café.swift",
            "CAFE-two.swift",
            "zeta.txt",
        ] {
            try fixture.write("\(path)\n", to: path)
        }
        refreshIndex()
        let pane = try openStagingPane()
        let fileList = pane.fileListController
        let model = fileList.viewModel

        func visibleSectionedPaths() -> [String] {
            fileList.setListLayout(.sectionedList)
            return (0 ..< fileList.sectionedTable.numberOfRows).compactMap { row in
                (fileList.sectionedTable.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? PBStagingFileCellView)?.pathField.stringValue
            }
        }

        for sortOrder in [PBStagingFileSortOrder.path, .status] {
            model.searchText = ""
            model.sortOrder = sortOrder
            fileList.applyFilterAndSort()
            let expected = model.files(in: .unstaged, fromChanges: repository.index.indexChanges).map(\.path)
            let split = (fileList.unstagedFilesController.arrangedObjects as? [PBChangedFile])?.map(\.path)
            XCTAssertEqual(split, expected, "split tables must use the view model's localized ordering")
            XCTAssertEqual(visibleSectionedPaths(), expected)
        }

        model.searchText = "cafe"
        model.sortOrder = .path
        fileList.applyFilterAndSort()
        let expectedFiltered = ["CAFE-two.swift", "Café.swift"]
        XCTAssertEqual(model.files(in: .unstaged, fromChanges: repository.index.indexChanges).map(\.path), expectedFiltered)
        XCTAssertEqual(
            (fileList.unstagedFilesController.arrangedObjects as? [PBChangedFile])?.map(\.path),
            expectedFiltered
        )
        XCTAssertEqual(visibleSectionedPaths(), expectedFiltered)
    }

    func testStagingDropsRejectOtherRepositoryWindowSources() throws {
        try fixture.write("keep unrelated repository file\n", to: "foreign-drag.txt")
        try fixture.write("staged anchor\n", to: "staged-anchor.txt")
        try fixture.git(["add", "staged-anchor.txt"])
        let pane = try openStagingPane()
        let list = pane.fileListController
        list.setListLayout(.splitTables)
        let files = try XCTUnwrap(list.unstagedFilesController.arrangedObjects as? [PBChangedFile])
        let row = try XCTUnwrap(files.firstIndex { $0.path == "foreign-drag.txt" })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXForeignStagingDrag"))
        XCTAssertTrue(list.interactionCoordinator.writeRows(with: IndexSet(integer: row), from: list.unstagedTable, to: pasteboard))
        let foreignInfo = DraggingInfoFake(pasteboard: pasteboard)
        foreignInfo.draggingSource = NSTableView()
        XCTAssertEqual(list.interactionCoordinator.validateDrop(foreignInfo, in: list.stagedTable), [])
        let accepted = list.interactionCoordinator.acceptDrop(foreignInfo, in: list.stagedTable)
        XCTAssertFalse(accepted, "A different repository window cannot address this repository by a coincidentally equal filename")
        if accepted {
            XCTAssertTrue(waitForCondition { !repository.index.mutationReconciliationPending })
            try fixture.git(["reset", "--quiet", "HEAD", "--", "foreign-drag.txt"])
            refreshIndex()
        }
        XCTAssertEqual(try fixture.git(["ls-files", "--", "foreign-drag.txt"]), "")
        list.setListLayout(.sectionedList)
        let dragType = NSPasteboard.PasteboardType("GitXStagingSectionedRows")
        pasteboard.declareTypes([dragType], owner: nil)
        pasteboard.setPropertyList([["rawPath": Data("foreign-drag.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue]], forType: dragType)
        let dataSource = try XCTUnwrap(list.sectionedTable.dataSource)
        XCTAssertEqual(dataSource.tableView?(list.sectionedTable, validateDrop: foreignInfo, proposedRow: 0, proposedDropOperation: .on), [])
        let acceptedSectioned = dataSource.tableView?(list.sectionedTable, acceptDrop: foreignInfo, row: 0, dropOperation: .on) ?? true
        XCTAssertFalse(acceptedSectioned)
        if acceptedSectioned {
            XCTAssertTrue(waitForCondition { !repository.index.mutationReconciliationPending })
        }
        XCTAssertEqual(try fixture.git(["ls-files", "--", "foreign-drag.txt"]), "")
    }

    func testSplitDragKeepsRawSelectionAndOmitsUnsafeExternalFilenameExport() throws {
        let label = "export\\xFF.txt"
        try fixture.write("literal external filename\n", to: label)
        let pane = try openStagingPane()
        let list = pane.fileListController
        list.setListLayout(.splitTables)
        let index = repository.index
        let before = index.indexChanges
        let invalid = PBChangedFile(path: label, rawPath: Data(Array("export".utf8) + [0xFF] + Array(".txt".utf8)))
        invalid.hasUnstagedChanges = true
        index.willChangeValue(forKey: "indexChanges")
        index.setValue(NSMutableArray(array: before + [invalid]), forKey: "files")
        index.didChangeValue(forKey: "indexChanges")
        defer {
            index.willChangeValue(forKey: "indexChanges")
            index.setValue(NSMutableArray(array: before), forKey: "files")
            index.didChangeValue(forKey: "indexChanges")
        }
        list.applyFilterAndSort()
        let files = try XCTUnwrap(list.unstagedFilesController.arrangedObjects as? [PBChangedFile])
        let validRow = try XCTUnwrap(files.firstIndex { $0.rawPath == Data(label.utf8) })
        let invalidRow = try XCTUnwrap(files.firstIndex { $0.rawPath == invalid.rawPath })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXUnsafeExternalFilenameDrag"))
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        XCTAssertTrue(list.interactionCoordinator.writeRows(with: IndexSet(integer: validRow), from: list.unstagedTable, to: pasteboard))
        XCTAssertEqual(pasteboard.propertyList(forType: filenamesType) as? [String],
                       try [XCTUnwrap(repository.workingDirectoryURL()).appendingPathComponent(label).path])
        XCTAssertTrue(list.interactionCoordinator.writeRows(with: IndexSet([validRow, invalidRow]), from: list.unstagedTable, to: pasteboard))
        let internalPayload = try XCTUnwrap(pasteboard.propertyList(forType: NSPasteboard.PasteboardType("GitFileChangedType")) as? [[String: Any]])
        XCTAssertEqual(Set(internalPayload.compactMap { $0["rawPath"] as? Data }), Set([Data(label.utf8), invalid.rawPath]))
        XCTAssertNil(pasteboard.propertyList(forType: filenamesType), "A mixed raw selection must not export only its literal display-name sibling")
    }

    func testCommitTableInteractionCoordinatorStagingDragAndFocusFlows() throws {
        try fixture.write("alpha.txt\n", to: "alpha.txt")
        try fixture.write("beta.txt\n", to: "beta.txt")
        let pane = try openStagingPane()
        let fileList = pane.fileListController
        fileList.setListLayout(.splitTables)
        let coordinator = fileList.interactionCoordinator

        let unstaged = fileList.unstagedFilesController
        let staged = fileList.stagedFilesController
        let alpha = try XCTUnwrap(
            (unstaged.arrangedObjects as? [PBChangedFile])?.first { $0.path == "alpha.txt" }
        )
        unstaged.setSelectedObjects([alpha])
        waitForIndexUpdate {
            _ = fileList.perform(
                NSSelectorFromString("fileChangesTableViewDidRequestStagingToggle:"),
                with: fileList.unstagedTable
            )
        }
        XCTAssertTrue(
            (staged.arrangedObjects as? [PBChangedFile])?.contains { $0.path == "alpha.txt" } == true,
            "stageSelectedFiles moves the selection into the staged list"
        )

        let stagedAlpha = try XCTUnwrap(
            (staged.arrangedObjects as? [PBChangedFile])?.first { $0.path == "alpha.txt" }
        )
        staged.setSelectedObjects([stagedAlpha])
        waitForIndexUpdate { coordinator.toggleStaging(for: fileList.stagedTable) }
        XCTAssertFalse(
            (staged.arrangedObjects as? [PBChangedFile])?.contains { $0.path == "alpha.txt" } == true
        )

        let beta = try XCTUnwrap(
            (unstaged.arrangedObjects as? [PBChangedFile])?.first { $0.path == "beta.txt" }
        )
        unstaged.setSelectedObjects([beta])
        let betaRow = try XCTUnwrap(
            (unstaged.arrangedObjects as? [PBChangedFile])?.firstIndex { $0.path == "beta.txt" }
        )
        pumpRunLoop()
        XCTAssertGreaterThan(fileList.unstagedTable.numberOfRows, 0)
        fileList.unstagedTable.selectRowIndexes(IndexSet(integer: betaRow), byExtendingSelection: false)
        pumpRunLoop()
        XCTAssertTrue(fileList.unstagedTable.selectedRowIndexes.contains(betaRow))
        waitForIndexUpdate { coordinator.didDoubleClick(fileList.unstagedTable) }
        XCTAssertTrue(
            (staged.arrangedObjects as? [PBChangedFile])?.contains { $0.path == "beta.txt" } == true,
            "double-click stages the clicked row"
        )

        coordinator.focusTable(fileList.unstagedTable)
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertFalse(coordinator.handleCommand(#selector(NSResponder.insertNewline(_:))))
        let column = try XCTUnwrap(fileList.unstagedTable.tableColumns.first)
        coordinator.displayCell(NSCell(), for: column, row: 0, in: fileList.unstagedTable)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTests"))
        pasteboard.clearContents()
        let unstagedRows = IndexSet(integer: 0)
        XCTAssertTrue(
            coordinator.writeRows(with: unstagedRows, from: fileList.unstagedTable, to: pasteboard)
        )
        let info = DraggingInfoFake(pasteboard: pasteboard)
        info.draggingSource = fileList.unstagedTable
        XCTAssertEqual(coordinator.validateDrop(info, in: fileList.stagedTable), .copy)
        waitForIndexUpdate {
            XCTAssertTrue(coordinator.acceptDrop(info, in: fileList.stagedTable))
        }
        XCTAssertTrue(
            waitForCondition { fileList.stagedFileCount == 2 },
            "the dragged unstaged file lands in the staged list"
        )

        let sameSource = DraggingInfoFake(pasteboard: pasteboard)
        sameSource.draggingSource = fileList.unstagedTable
        XCTAssertEqual(
            coordinator.validateDrop(sameSource, in: fileList.unstagedTable),
            [],
            "drags within the same table are rejected"
        )
        let emptyPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsEmpty"))
        emptyPasteboard.clearContents()
        let emptyInfo = DraggingInfoFake(pasteboard: emptyPasteboard)
        emptyInfo.draggingSource = fileList.unstagedTable
        XCTAssertFalse(coordinator.acceptDrop(emptyInfo, in: fileList.stagedTable))

        XCTAssertFalse(
            coordinator.writeRows(with: IndexSet(integer: 99), from: fileList.unstagedTable, to: pasteboard),
            "out-of-range drag rows are rejected"
        )
        let fileChangesType = NSPasteboard.PasteboardType("GitFileChangedType")
        let corruptPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsCorrupt"))
        corruptPasteboard.clearContents()
        corruptPasteboard.declareTypes([fileChangesType], owner: nil)
        corruptPasteboard.setData(Data([0x00, 0x01, 0x02]), forType: fileChangesType)
        let corruptInfo = DraggingInfoFake(pasteboard: corruptPasteboard)
        corruptInfo.draggingSource = fileList.unstagedTable
        XCTAssertFalse(
            coordinator.acceptDrop(corruptInfo, in: fileList.stagedTable),
            "corrupt drag payloads are rejected"
        )
        let staleRowsPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsStale"))
        staleRowsPasteboard.clearContents()
        staleRowsPasteboard.declareTypes([fileChangesType], owner: nil)
        try staleRowsPasteboard.setData(
            NSKeyedArchiver.archivedData(withRootObject: NSIndexSet(index: 99), requiringSecureCoding: true),
            forType: fileChangesType
        )
        let staleInfo = DraggingInfoFake(pasteboard: staleRowsPasteboard)
        staleInfo.draggingSource = fileList.unstagedTable
        XCTAssertFalse(
            coordinator.acceptDrop(staleInfo, in: fileList.stagedTable),
            "drag rows that no longer exist are rejected"
        )

        pumpRunLoop()
        let stagedFiles = staged.arrangedObjects as? [PBChangedFile] ?? []
        staged.setSelectedObjects(stagedFiles)
        fileList.stagedTable.selectRowIndexes(
            IndexSet(integersIn: 0 ..< stagedFiles.count),
            byExtendingSelection: false
        )
        pumpRunLoop()
        XCTAssertTrue(
            coordinator.writeRows(
                with: IndexSet(integer: 0),
                from: fileList.stagedTable,
                to: pasteboard
            )
        )
        let unstageInfo = DraggingInfoFake(pasteboard: pasteboard)
        unstageInfo.draggingSource = fileList.stagedTable
        waitForIndexUpdate {
            XCTAssertTrue(coordinator.acceptDrop(unstageInfo, in: fileList.unstagedTable))
        }
        XCTAssertTrue(
            waitForCondition { fileList.stagedFileCount == 1 },
            "the dragged staged file lands in the unstaged list"
        )

        waitForIndexUpdate {
            coordinator.toggleStaging(for: fileList.unstagedTable)
        }
        let remainingStagedFiles = staged.arrangedObjects as? [PBChangedFile] ?? []
        staged.setSelectedObjects(remainingStagedFiles)
        fileList.stagedTable.selectRowIndexes(
            IndexSet(integersIn: 0 ..< remainingStagedFiles.count),
            byExtendingSelection: false
        )
        pumpRunLoop()
        waitForIndexUpdate { coordinator.didDoubleClick(fileList.stagedTable) }
        XCTAssertTrue(
            waitForCondition { fileList.stagedFileCount == 0 },
            "double-clicking staged rows unstages them"
        )
    }

    func testSectionedDragPayloadsOnlyMutateCurrentCrossSectionEntries() throws {
        try fixture.write("staged only\n", to: "staged-only.txt")
        try fixture.write("indexed portion\n", to: "partial.txt")
        try fixture.git(["add", "staged-only.txt", "partial.txt"])
        try fixture.write("indexed portion\nworktree portion\n", to: "partial.txt")
        try fixture.write("unstaged only\n", to: "unstaged-only.txt")

        let pane = try openStagingPane()
        let fileList = pane.fileListController
        fileList.setListLayout(.sectionedList)
        let table = fileList.sectionedTable
        let dataSource = try XCTUnwrap(table.dataSource)
        let dragType = NSPasteboard.PasteboardType("GitXStagingSectionedRows")

        func rows(for path: String) -> [Int] {
            (0 ..< table.numberOfRows).filter { row in
                (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PBStagingFileCellView)?
                    .pathField.stringValue == path
            }
        }
        func writeDrag(row: Int, name: String) throws -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
            pasteboard.clearContents()
            let selector = NSSelectorFromString("tableView:writeRowsWithIndexes:toPasteboard:")
            typealias WriteRows = @convention(c) (
                AnyObject,
                Selector,
                NSTableView,
                NSIndexSet,
                NSPasteboard
            ) -> Bool
            // swift6-safety-justification: The Objective-C NSTableView data-source selector has this exact object-only ABI.
            let writeRows = unsafeBitCast(fileList.method(for: selector), to: WriteRows.self)
            XCTAssertTrue(writeRows(fileList, selector, table, NSIndexSet(index: row), pasteboard))
            return pasteboard
        }
        func validate(_ pasteboard: NSPasteboard, targetRow: Int) -> NSDragOperation {
            let info = DraggingInfoFake(pasteboard: pasteboard)
            info.draggingSource = table
            return dataSource.tableView?(
                table,
                validateDrop: info,
                proposedRow: targetRow,
                proposedDropOperation: .above
            ) ?? []
        }
        func accept(_ pasteboard: NSPasteboard, targetRow: Int) -> Bool {
            let info = DraggingInfoFake(pasteboard: pasteboard)
            info.draggingSource = table
            return dataSource.tableView?(
                table,
                acceptDrop: info,
                row: targetRow,
                dropOperation: .above
            ) ?? false
        }

        let partialRows = rows(for: "partial.txt")
        XCTAssertEqual(partialRows.count, 2)
        let stagedPartialRow = try XCTUnwrap(partialRows.min())
        let unstagedPartialRow = try XCTUnwrap(partialRows.max())
        let sameSectionDrag = try writeDrag(row: stagedPartialRow, name: "GitXSectionedSameSection")
        let encoded = try XCTUnwrap(sameSectionDrag.propertyList(forType: dragType) as? [[String: Any]])
        XCTAssertEqual(encoded.first?["rawPath"] as? Data, Data("partial.txt".utf8))
        XCTAssertEqual(encoded.first?["sourceSection"] as? Int, PBStagingListSection.staged.rawValue)
        let indexedPartial = try fixture.git(["show", ":partial.txt"])
        XCTAssertEqual(validate(sameSectionDrag, targetRow: 0), [])
        XCTAssertFalse(accept(sameSectionDrag, targetRow: 0))
        XCTAssertEqual(try fixture.git(["show", ":partial.txt"]), indexedPartial)
        XCTAssertEqual(
            try fixture.git(["status", "--porcelain", "--", "partial.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "AM partial.txt"
        )

        let unstagedRow = try XCTUnwrap(rows(for: "unstaged-only.txt").first)
        let stageDrag = try writeDrag(row: unstagedRow, name: "GitXSectionedStage")
        XCTAssertEqual(validate(stageDrag, targetRow: 0), .copy)
        waitForIndexUpdate {
            XCTAssertTrue(accept(stageDrag, targetRow: 0))
        }
        XCTAssertFalse(try fixture.git(["ls-files", "--stage", "--", "unstaged-only.txt"]).isEmpty)

        let stagedOnlyRow = try XCTUnwrap(rows(for: "staged-only.txt").first)
        let unstageDrag = try writeDrag(row: stagedOnlyRow, name: "GitXSectionedUnstage")
        XCTAssertEqual(validate(unstageDrag, targetRow: unstagedPartialRow), .copy)
        waitForIndexUpdate {
            XCTAssertTrue(accept(unstageDrag, targetRow: unstagedPartialRow))
        }
        XCTAssertTrue(try fixture.git(["ls-files", "--stage", "--", "staged-only.txt"]).isEmpty)

        let mixedPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXSectionedMixed"))
        mixedPasteboard.clearContents()
        mixedPasteboard.declareTypes([dragType], owner: nil)
        mixedPasteboard.setPropertyList(
            [
                ["rawPath": Data("unstaged-only.txt".utf8), "sourceSection": PBStagingListSection.staged.rawValue],
                ["rawPath": Data("staged-only.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
                ["rawPath": Data("staged-only.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
                ["rawPath": Data("stale.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
            ],
            forType: dragType
        )
        XCTAssertTrue(waitForCondition { validate(mixedPasteboard, targetRow: 0) == .copy })
        waitForIndexUpdate {
            XCTAssertTrue(accept(mixedPasteboard, targetRow: 0))
        }
        XCTAssertFalse(try fixture.git(["ls-files", "--stage", "--", "staged-only.txt"]).isEmpty)

        for (name, propertyList) in [
            ("Empty", [] as [[String: Any]]),
            ("Malformed", [["rawPath": Data("partial.txt".utf8), "sourceSection": 0, "extra": true]]),
        ] {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXSectioned\(name)"))
            pasteboard.clearContents()
            pasteboard.declareTypes([dragType], owner: nil)
            pasteboard.setPropertyList(propertyList, forType: dragType)
            XCTAssertEqual(validate(pasteboard, targetRow: 0), [])
            XCTAssertFalse(accept(pasteboard, targetRow: 0))
        }
    }

    func testHookFailureLeavesHEADUnchangedAndAllowsAFreshSubmissionAfterCancellation() throws {
        try fixture.write("hook fixture\n", to: "hook-fixture.txt")
        try fixture.git(["add", "hook-fixture.txt"])
        let pane = try openStagingPane()
        let hook = URL(fileURLWithPath: fixture.path).appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho rejected >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let before = try fixture.git(["rev-parse", "HEAD"])
        pane.commitMessageView.string = "Original rejected request"
        let rejected = expectation(forNotification: Notification.Name(PBGitIndexCommitHookFailed), object: repository.index)
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        wait(for: [rejected], timeout: 10)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), before)
        XCTAssertTrue(pane.commitMessageView.isEditable)
        try FileManager.default.removeItem(at: hook)
        pane.commitMessageView.string = "Fresh accepted request"
        let accepted = expectation(forNotification: Notification.Name(PBGitIndexFinishedCommit), object: repository.index)
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        wait(for: [accepted], timeout: 10)
        XCTAssertEqual(try fixture.git(["log", "-1", "--pretty=%s"]).trimmingCharacters(in: .newlines), "Fresh accepted request")
        XCTAssertTrue(waitForCondition { !self.repository.index.mutationReconciliationPending })
    }

    func testStagingPaneCommitWorkflowComposerAndNotifications() throws {
        try fixture.write("compose body\n", to: "compose.txt")
        try fixture.git(["add", "compose.txt"])
        let pane = try openStagingPane()
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let messageView = pane.commitMessageView

        messageView.string = ""
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        XCTAssertEqual(stub.shownMessages.last?.message, "Missing commit message")

        messageView.string = "Subject line"
        pane.perform(NSSelectorFromString("signOff:"), with: nil)
        XCTAssertTrue(
            messageView.string.contains("Signed-off-by: GitX Tests <gitx-tests@example.invalid>"),
            "sign-off appends the configured author: \(messageView.string)"
        )

        let hooksDirectory = URL(fileURLWithPath: fixture.path).appendingPathComponent(".git/hooks")
        let prepareHook = hooksDirectory.appendingPathComponent("prepare-commit-msg")
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"prepared subject\" > \"$1\"\n".write(to: prepareHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prepareHook.path)
        pane.perform(NSSelectorFromString("prepareCommitMessage:"), with: nil)
        XCTAssertTrue(messageView.string.contains("prepared subject"))
        try FileManager.default.removeItem(at: prepareHook)

        let initialHead = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        messageView.string = "Staging pane commit"
        let committed = expectation(
            forNotification: NSNotification.Name(PBGitIndexFinishedCommit),
            object: repository.index
        )
        pane.perform(NSSelectorFromString("commit:"), with: nil)
        wait(for: [committed], timeout: 20)
        XCTAssertTrue(
            waitForCondition(timeout: 20) {
                !self.repository.index.mutationReconciliationPending && self.repository.index.indexChanges.isEmpty
            },
            "commit retries await the accepted clean index and re-enabled controls"
        )
        let newHead = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(newHead, initialHead)
        XCTAssertEqual(messageView.string, "", "a successful commit clears the composer")
        XCTAssertEqual(
            try fixture.git(["log", "-1", "--pretty=%s"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "Staging pane commit"
        )

        NotificationCenter.default.post(
            name: NSNotification.Name(PBGitIndexCommitFailed),
            object: repository.index,
            userInfo: ["description": "synthetic failure"]
        )
        XCTAssertEqual(stub.shownMessages.last?.message, "Commit failed")
        XCTAssertEqual(stub.shownMessages.last?.info, "synthetic failure")

        NotificationCenter.default.post(
            name: NSNotification.Name(PBGitIndexCommitHookFailed),
            object: repository.index,
            userInfo: ["description": "synthetic hook failure"]
        )
        XCTAssertEqual(stub.shownMessages.last?.message, "Commit hook failed")
        let retry = try XCTUnwrap(stub.hookFailureRetryHandlers.last)
        retry()
        XCTAssertEqual(
            stub.shownMessages.last?.message,
            "No changes to commit",
            "retrying with a clean tree walks the force-commit validation path"
        )

        historyController.selectUncommittedChanges()
        pumpRunLoop(for: 0.5)
        XCTAssertFalse(
            historyController.uncommittedChangesSelected,
            "selecting uncommitted changes on a clean repository degrades to plain history"
        )
        historyController.perform(
            NSSelectorFromString("applicationDidBecomeActive:"),
            with: NSNotification(name: NSApplication.didBecomeActiveNotification, object: nil)
        )

        waitForIndexUpdate {
            stub.toggleAmendCommit(self)
        }
        XCTAssertTrue(repository.index.isAmend)
        XCTAssertTrue(
            messageView.string.contains("Staging pane commit"),
            "amend repopulates the composer with the last commit message"
        )
        XCTAssertTrue(historyController.uncommittedChangesSelected == false || pane.view.isHidden == false)
        waitForIndexUpdate {
            pane.perform(NSSelectorFromString("toggleAmendCommit:"), with: nil)
        }
        XCTAssertFalse(repository.index.isAmend)
    }

    func testStagingPaneTeardownUnbindsAmendAndSuccessfulCompletionClearsBusyState() throws {
        try fixture.write("lifecycle\n", to: "lifecycle.txt")
        let pane = try openStagingPane()
        let amendButton = try XCTUnwrap(
            controls(in: pane.view)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Amend" }
        )
        XCTAssertNotNil(amendButton.infoForBinding(.value))

        historyController.isBusy = true
        NotificationCenter.default.post(
            name: NSNotification.Name(PBGitIndexFinishedCommit),
            object: repository.index,
            userInfo: ["description": "Commit finished"]
        )
        XCTAssertFalse(historyController.isBusy)

        pane.closeView()
        XCTAssertNil(amendButton.infoForBinding(.value))
    }

    func testStagingPaneMenusAndViewOptions() throws {
        try fixture.write("modify me\n", to: "nested/tracked.txt")
        try fixture.write("junk\n", to: "junk.txt")
        try fixture.write("ignored candidate\n", to: "ignore-me.txt")
        try fixture.write("staged\n", to: "staged.txt")
        try fixture.git(["add", "staged.txt"])
        let pane = try openStagingPane()
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let fileList = pane.fileListController
        fileList.setListLayout(.splitTables)
        let unstaged = fileList.unstagedFilesController
        let staged = fileList.stagedFilesController
        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "nested/tracked.txt" } ?? []
        )
        staged.setSelectedObjects(staged.arrangedObjects as? [PBChangedFile] ?? [])

        for menu in [fileList.unstagedTable.menu, fileList.stagedTable.menu, fileList.sectionedTable.menu] {
            try pane.perform(NSSelectorFromString("menuNeedsUpdate:"), with: XCTUnwrap(menu))
        }

        let contextItem = NSMenuItem()
        contextItem.tag = 6
        pane.perform(NSSelectorFromString("changeContextLines:"), with: contextItem)
        XCTAssertEqual(pane.diffPaneController.contextLines, 6)
        contextItem.tag = 3
        pane.perform(NSSelectorFromString("changeContextLines:"), with: contextItem)

        let layoutItem = NSMenuItem()
        layoutItem.tag = PBStagingListLayout.sectionedList.rawValue
        pane.perform(NSSelectorFromString("changeListLayout:"), with: layoutItem)
        XCTAssertEqual(fileList.layout, .sectionedList)
        let delegate = try XCTUnwrap(pane.commitMessageView.delegate)
        _ = delegate.textView?(pane.commitMessageView, doCommandBy: #selector(NSResponder.insertTab(_:)))
        layoutItem.tag = PBStagingListLayout.splitTables.rawValue
        pane.perform(NSSelectorFromString("changeListLayout:"), with: layoutItem)
        _ = delegate.textView?(pane.commitMessageView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPopup.addItem(withTitle: "status")
        sortPopup.lastItem?.tag = PBStagingFileSortOrder.status.rawValue
        sortPopup.selectItem(withTag: PBStagingFileSortOrder.status.rawValue)
        pane.perform(NSSelectorFromString("sortOrderChanged:"), with: sortPopup)
        XCTAssertEqual(PBApplicationSettings.stagingFileSortOrder, .status)
        sortPopup.addItem(withTitle: "path")
        sortPopup.lastItem?.tag = PBStagingFileSortOrder.path.rawValue
        sortPopup.selectItem(withTag: PBStagingFileSortOrder.path.rawValue)
        pane.perform(NSSelectorFromString("sortOrderChanged:"), with: sortPopup)
        XCTAssertEqual(PBApplicationSettings.stagingFileSortOrder, .path)

        let amendItem = NSMenuItem(title: "Amend", action: NSSelectorFromString("toggleAmendCommit:"), keyEquivalent: "")
        _ = stub.validateMenuItem(amendItem)
        let uncommittedItem = NSMenuItem(title: "Uncommitted", action: NSSelectorFromString("showUncommittedChanges:"), keyEquivalent: "")
        _ = stub.validateMenuItem(uncommittedItem)
        let historyItem = NSMenuItem(title: "History", action: NSSelectorFromString("showHistoryView:"), keyEquivalent: "")
        _ = stub.validateMenuItem(historyItem)

        let webController = try XCTUnwrap(
            historyController.value(forKey: "webHistoryController") as? PBWebHistoryController
        )
        webController.refreshDisplayedContent()
        pumpRunLoop()

        webController.setValue(nil, forKey: "historyController")
        _ = webController.beginContentGeneration()
        let undecorated = webController.sections(
            [[PBNativeSectionTextKey: "diff"]],
            applyingDiffLayout: 0
        )
        XCTAssertEqual(undecorated.first?[PBNativeSectionSuppressionPatternsKey] as? [String], [])

        webController.setValue(historyController, forKey: "historyController")
        try fixture.git([
            "config",
            "gitx.diffSuppressionPatterns",
            " ^generated/ \n# note\n\n.*\\.lock$ ",
        ])
        _ = webController.beginContentGeneration()
        let configured = webController.sections(
            [[PBNativeSectionTextKey: "diff"]],
            applyingDiffLayout: 1
        )
        XCTAssertEqual(
            configured.first?[PBNativeSectionSuppressionPatternsKey] as? [String],
            ["^generated/", #".*\.lock$"#]
        )
    }

    func testStagingPaneFileActions() throws {
        try fixture.write("modify me\n", to: "nested/tracked.txt")
        try fixture.write("junk\n", to: "junk.txt")
        try fixture.write("ignored candidate\n", to: "ignore-me.txt")
        try fixture.write("staged\n", to: "staged.txt")
        try fixture.git(["add", "staged.txt"])
        let pane = try openStagingPane()
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)
        let fileList = pane.fileListController
        fileList.setListLayout(.splitTables)
        let unstaged = fileList.unstagedFilesController
        let staged = fileList.stagedFilesController

        // Selecting in the staged table above cleared the unstaged selection
        // (split-table selections are mutually exclusive); re-select before
        // staging.
        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "nested/tracked.txt" } ?? []
        )
        waitForIndexUpdate { pane.perform(NSSelectorFromString("stageFiles:"), with: nil) }
        XCTAssertTrue(
            (staged.arrangedObjects as? [PBChangedFile])?.contains { $0.path == "nested/tracked.txt" } == true
        )
        staged.setSelectedObjects(
            (staged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "nested/tracked.txt" } ?? []
        )
        waitForIndexUpdate { pane.perform(NSSelectorFromString("unstageFiles:"), with: nil) }

        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "nested/tracked.txt" } ?? []
        )
        waitForIndexUpdate { pane.perform(NSSelectorFromString("discardFilesForcibly:"), with: nil) }
        XCTAssertEqual(
            try fixture.git(["status", "--porcelain", "--", "nested/tracked.txt"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "forcible discard restores the tracked file"
        )

        let confirmations = stub.confirmationCount
        try fixture.write("discard me\n", to: "nested/tracked.txt")
        refreshIndex()
        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "nested/tracked.txt" } ?? []
        )
        waitForIndexUpdate { pane.perform(NSSelectorFromString("discardFiles:"), with: nil) }
        XCTAssertGreaterThan(stub.confirmationCount, confirmations, "plain discard confirms first")

        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "ignore-me.txt" } ?? []
        )
        let ignoreItem = NSMenuItem()
        waitForIndexUpdate { pane.perform(NSSelectorFromString("ignoreFiles:"), with: ignoreItem) }
        let gitignore = URL(fileURLWithPath: fixture.path).appendingPathComponent(".gitignore")
        XCTAssertTrue(
            (try? String(contentsOf: gitignore, encoding: .utf8))?.contains("ignore-me.txt") == true
        )

        unstaged.setSelectedObjects(
            (unstaged.arrangedObjects as? [PBChangedFile])?.filter { $0.path == "junk.txt" } ?? []
        )
        let trashItem = NSMenuItem()
        waitForIndexUpdate { pane.perform(NSSelectorFromString("moveToTrash:"), with: trashItem) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.path).appendingPathComponent("junk.txt").path),
            "move to trash removes the working-tree file"
        )
    }

    func testStagingPaneCommitMessageDropRewritesRepositoryPaths() throws {
        try fixture.write("staged\n", to: "staged.txt")
        try fixture.git(["add", "staged.txt"])
        let pane = try openStagingPane()
        XCTAssertTrue(pane.paneFirstResponder === pane.commitMessageView)

        let dragPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingMessageDrag"))
        dragPasteboard.clearContents()
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        dragPasteboard.declareTypes([filenamesType], owner: nil)
        let workingDirectory = repository.workingDirectory() ?? fixture.path
        let similarlyPrefixedDirectory = workingDirectory + "-backup"
        let externalPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("external.txt")
            .path
        dragPasteboard.setPropertyList(
            [
                (workingDirectory as NSString).appendingPathComponent("staged.txt"),
                workingDirectory,
                (similarlyPrefixedDirectory as NSString).appendingPathComponent("outside.txt"),
                externalPath,
            ],
            forType: filenamesType
        )
        pane.commitMessageView.string = ""
        _ = pane.commitMessageView.performDragOperation(DraggingInfoFake(pasteboard: dragPasteboard))
        let rewritten = dragPasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String]
        XCTAssertEqual(
            rewritten,
            [
                "staged.txt",
                workingDirectory,
                (similarlyPrefixedDirectory as NSString).appendingPathComponent("outside.txt"),
                externalPath,
            ],
            "only files contained by the repository are rewritten to relative paths"
        )

        pane.commitMessageView.repository = nil
        dragPasteboard.clearContents()
        dragPasteboard.declareTypes([filenamesType], owner: nil)
        dragPasteboard.setPropertyList([externalPath], forType: filenamesType)
        _ = pane.commitMessageView.performDragOperation(DraggingInfoFake(pasteboard: dragPasteboard))

        let remainingPaths = dragPasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String]
        XCTAssertEqual(remainingPaths, [], "a detached text view leaves the file drop to AppKit")
    }

    func testStagingPaneHistoryAndWindowMenuRouting() throws {
        try fixture.write("working tree\n", to: "menu-routing.txt")
        _ = try openStagingPane()
        let stub = try XCTUnwrap(windowController as? HistoryWindowController)

        let regularCommit = try XCTUnwrap(loadedCommits().first)
        historyController.commitController.setSelectedObjects([regularCommit])
        historyController.updateKeys()
        historyController.selectUncommittedChanges()
        pumpRunLoop()
        XCTAssertTrue(
            historyController.uncommittedChangesSelected,
            "selecting uncommitted changes with the row present selects it directly"
        )

        historyController.selectedCommitDetailsIndex = 1
        historyController.updateKeys()
        try fixture.write("tree refresh\n", to: "nested/tracked.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()
        historyController.selectedCommitDetailsIndex = 0
        historyController.updateKeys()
        XCTAssertTrue(historyController.uncommittedChangesSelected)
        XCTAssertNotNil(stub.window)
    }

    func testStagingPaneReplacesDetailViewForWorkingStateRow() throws {
        let previousLayout = PBApplicationSettings.stagingListLayout
        PBApplicationSettings.stagingListLayout = .sectionedList
        defer { PBApplicationSettings.stagingListLayout = previousLayout }

        try fixture.write("staged addition\n", to: "staged-addition.txt")
        try fixture.git(["add", "staged-addition.txt"])
        try fixture.write("tracked modification\n", to: "nested/tracked.txt")
        try fixture.write("brand new\n", to: "untracked.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()

        let workingState = try XCTUnwrap(
            historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        )
        historyController.selectedCommitDetailsIndex = 0
        historyController.commitController.setSelectedObjects([workingState])
        historyController.updateKeys()
        pumpRunLoop()

        let pane = try XCTUnwrap(
            historyController.value(forKey: "stagingViewController") as? PBStagingViewController,
            "selecting the working-state row in Detail mode must create the staging pane"
        )
        XCTAssertNotNil(pane.view.superview)
        XCTAssertFalse(pane.view.isHidden)
        let webView = try XCTUnwrap(
            (historyController.value(forKey: "webHistoryController") as? NSObject)?.value(forKey: "view") as? NSView
        )
        XCTAssertTrue(webView.isHidden, "the detail web view hides while the staging pane is shown")

        let fileList = pane.fileListController
        XCTAssertEqual(fileList.unstagedTable.accessibilityIdentifier(), "UnstagedFiles")
        XCTAssertEqual(fileList.stagedTable.accessibilityIdentifier(), "StagedFiles")
        XCTAssertEqual(fileList.unstagedTable.tag, 0)
        XCTAssertEqual(fileList.stagedTable.tag, 1)
        XCTAssertEqual(pane.commitMessageView.accessibilityIdentifier(), "CommitMessage")
        XCTAssertEqual(fileList.stagedFileCount, 1)
        let unstagedPaths = (fileList.unstagedFilesController.arrangedObjects as? [PBChangedFile])?.map(\.path)
        XCTAssertEqual(unstagedPaths, ["nested/tracked.txt", "untracked.txt"])

        let untracked = try XCTUnwrap(
            (fileList.unstagedFilesController.arrangedObjects as? [PBChangedFile])?
                .first { $0.path == "untracked.txt" }
        )
        fileList.unstagedFilesController.setSelectedObjects([untracked])
        XCTAssertTrue(waitForCondition {
            let rendered = pane.diffPaneController.contentView.textView.string
            return rendered.contains("Hunk 1 : Line 1")
                && rendered.contains("\u{00A0}Stage hunk\u{00A0}")
                && rendered.contains("│ +brand new")
        })
        let renderedUntracked = pane.diffPaneController.contentView.textView.string
        XCTAssertTrue(
            renderedUntracked.contains("Hunk 1 : Line 1"),
            "untracked files render as stageable synthetic hunks:\n\(renderedUntracked)"
        )
        XCTAssertTrue(renderedUntracked.contains("\u{00A0}Stage hunk\u{00A0}"))
        XCTAssertTrue(renderedUntracked.contains("│ +brand new"))

        let staged = try XCTUnwrap(
            (fileList.stagedFilesController.arrangedObjects as? [PBChangedFile])?.first
        )
        fileList.unstagedFilesController.setSelectedObjects([])
        fileList.stagedFilesController.setSelectedObjects([staged])
        XCTAssertTrue(waitForCondition {
            pane.diffPaneController.contentView.textView.string.contains("\u{00A0}Unstage hunk\u{00A0}")
        })
        let renderedStaged = pane.diffPaneController.contentView.textView.string
        XCTAssertTrue(
            renderedStaged.contains("\u{00A0}Unstage hunk\u{00A0}"),
            "staged selections render unstage buttons:\n\(renderedStaged)"
        )

        pane.searchField.stringValue = "nested"
        if let action = pane.searchField.action {
            _ = NSApp.sendAction(action, to: pane.searchField.target, from: pane.searchField)
        }
        XCTAssertEqual(
            (fileList.unstagedFilesController.arrangedObjects as? [PBChangedFile])?.map(\.path),
            ["nested/tracked.txt"],
            "the header search filters both lists by path substring"
        )
        XCTAssertEqual(fileList.stagedFileCount, 1, "search filtering does not change commit eligibility")
        pane.searchField.stringValue = ""
        if let action = pane.searchField.action {
            _ = NSApp.sendAction(action, to: pane.searchField.target, from: pane.searchField)
        }
        XCTAssertEqual(fileList.stagedFileCount, 1)

        XCTAssertEqual(fileList.layout, .sectionedList, "the sectioned list is the default layout")
        XCTAssertEqual(fileList.sectionedTable.numberOfRows, 5, "two headers plus three pending files")
        let untrackedRow = try XCTUnwrap(
            (0 ..< fileList.sectionedTable.numberOfRows).first { row in
                (fileList.sectionedTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? PBStagingFileCellView)?
                    .pathField.stringValue == "untracked.txt"
            }
        )
        fileList.sectionedTable.selectRowIndexes(IndexSet(integer: untrackedRow), byExtendingSelection: false)
        XCTAssertEqual(
            fileList.selectedFiles(forStagedContext: false).map(\.path),
            ["untracked.txt"],
            "sectioned selection mirrors into the unstaged array controller"
        )
        XCTAssertFalse(
            try XCTUnwrap(fileList.sectionedTable.delegate?.tableView?(fileList.sectionedTable, shouldSelectRow: 0)),
            "section headers are not selectable"
        )
        fileList.setListLayout(.splitTables)
        XCTAssertEqual(PBApplicationSettings.stagingListLayout, .splitTables)
        XCTAssertTrue(fileList.unstagedTable.superview != nil, "split tables install when toggled")
        fileList.setListLayout(.sectionedList)
        XCTAssertEqual(PBApplicationSettings.stagingListLayout, .sectionedList)
        XCTAssertTrue(fileList.sectionedTable.superview != nil, "the sectioned table reinstalls when toggled back")

        let previousContext = UserDefaults.standard.object(forKey: "PBStageDiffContextLines")
        pane.diffPaneController.contextLines = 6
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "PBStageDiffContextLines"), 6)
        if let previousContext = previousContext as? Int {
            pane.diffPaneController.contextLines = UInt(previousContext)
        } else {
            UserDefaults.standard.removeObject(forKey: "PBStageDiffContextLines")
        }

        let regularCommit = try XCTUnwrap(loadedCommits().first)
        historyController.commitController.setSelectedObjects([regularCommit])
        historyController.updateKeys()
        pumpRunLoop()
        XCTAssertTrue(pane.view.isHidden, "selecting a commit hides the staging pane again")
        XCTAssertFalse(webView.isHidden)
        XCTAssertEqual(historyController.webCommits.first, regularCommit)

        try fixture.git(["reset", "--quiet", "staged-addition.txt"])
        try fixture.git(["checkout", "--quiet", "--", "nested/tracked.txt"])
        try fixture.git(["clean", "-fdq"])
        refreshIndex()
        historyController.updateUncommittedChanges()
    }

    func testReferenceCommitStashAndPathMenuMatrices() throws {
        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems.map { $0 as NSPasteboardWriting })
        }
        repository.reloadRefs()
        let head = try XCTUnwrap(repository.headRef()?.ref())
        let feature = try XCTUnwrap(repository.ref(forName: "feature"))
        let tag = try XCTUnwrap(repository.ref(forName: "v1"))
        let remote = PBGitRef(string: "refs/remotes/origin")
        let remoteBranch = try XCTUnwrap(repository.ref(forName: "origin/main"))
        let stash = try XCTUnwrap(repository.stashes.first?.ref)

        XCTAssertNil(menuItems(selector: "menuItemsForRef:", argument: nil))
        XCTAssertEqual(menuItems(selector: "menuItemsForRef:", argument: PBGitRef(string: "refs/stash"))?.count, 0)
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: stash), contains: ["Pop", "Apply", "View Diff", "Drop"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: head), contains: ["Checkout", "Copy Branch Name", "Create Branch", "Fetch", "Push"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: feature), contains: ["Checkout", "Copy Branch Name", "Merge", "Rebase", "Reset"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: tag), contains: ["View Tag Info", "Push"], excludes: ["Copy Branch Name"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: remoteBranch), contains: ["Copy Branch Name", "Push Updates", "Fetch", "Pull"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: remote), contains: ["Push Updates", "Fetch", "Pull"], excludes: ["Copy Branch Name"])

        let featureItems = try XCTUnwrap(menuItems(selector: "menuItemsForRef:", argument: feature))
        let copyFeatureName = try XCTUnwrap(featureItems.first { $0.title == "Copy Branch Name" })
        let copyFeatureAction = try XCTUnwrap(copyFeatureName.action)
        XCTAssertTrue(NSApp.sendAction(copyFeatureAction, to: copyFeatureName.target, from: copyFeatureName))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "feature")

        let remoteBranchItems = try XCTUnwrap(menuItems(selector: "menuItemsForRef:", argument: remoteBranch))
        let copyRemoteBranchName = try XCTUnwrap(remoteBranchItems.first { $0.title == "Copy Branch Name" })
        let copyRemoteBranchAction = try XCTUnwrap(copyRemoteBranchName.action)
        XCTAssertTrue(NSApp.sendAction(copyRemoteBranchAction, to: copyRemoteBranchName.target, from: copyRemoteBranchName))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "origin/main")

        let invalidCopyItem = NSMenuItem(title: "Copy Branch Name", action: copyFeatureAction, keyEquivalent: "")
        invalidCopyItem.target = copyFeatureName.target
        invalidCopyItem.representedObject = tag
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSApp.sendAction(copyFeatureAction, to: invalidCopyItem.target, from: invalidCopyItem))
        XCTAssertNil(NSPasteboard.general.string(forType: .string))

        let commits = loadedCommits()
        let headCommit = try XCTUnwrap(commits.first { $0.oid == repository.headOID() })
        let featureCommit = try XCTUnwrap(commits.first { !$0.isOnHeadBranch() })
        assertMenu(menuItems(selector: "menuItemsForCommits:", argument: [headCommit]), contains: ["Checkout Commit", "Copy SHA-1", "Create Patch…", "Reset"])
        assertMenu(menuItems(selector: "menuItemsForCommits:", argument: [featureCommit]), contains: ["Merge Commit", "Cherry Pick", "Rebase"])
        let multiple = try XCTUnwrap(menuItems(selector: "menuItemsForCommits:", argument: [headCommit, featureCommit]))
        XCTAssertEqual(multiple.filter { $0.title == "Copy SHA-1" }.count, 1)
        XCTAssertFalse(multiple.contains { $0.title.contains("Checkout Commit") })

        historyController.selectedCommits = [featureCommit]
        let singlePaths = historyController.menuItems(forPaths: [" nested/tracked.txt "])
        XCTAssertEqual(singlePaths.count, 5)
        XCTAssertTrue(singlePaths.allSatisfy { $0.representedObject != nil })
        let featureDiff = try XCTUnwrap(singlePaths.first { $0.action == NSSelectorFromString("diffFilesAction:") })
        let featureCheckout = try XCTUnwrap(singlePaths.first { $0.action == NSSelectorFromString("checkoutFiles:") })
        XCTAssertTrue(featureDiff.isEnabled)
        XCTAssertTrue(featureCheckout.isEnabled)
        XCTAssertEqual(featureDiff.representedObject as? [String], ["nested/tracked.txt"])

        historyController.selectedCommits = [headCommit]
        let headPathItems = historyController.menuItems(forPaths: ["nested/tracked.txt"])
        let headDiff = try XCTUnwrap(headPathItems.first { $0.title.hasPrefix("Diff file") })
        let headCheckout = try XCTUnwrap(headPathItems.first { $0.action == NSSelectorFromString("checkoutFiles:") })
        XCTAssertFalse(headDiff.isEnabled)
        XCTAssertNil(headDiff.action)
        XCTAssertTrue(headCheckout.isEnabled)

        let multiplePaths = historyController.menuItems(forPaths: ["one", "two"])
        XCTAssertTrue(multiplePaths[0].title.contains("files"))
        let sender = NSMenuItem()
        sender.representedObject = ["nested/tracked.txt"]
        historyController.perform(NSSelectorFromString("showCommitsFromTree:"), with: sender)

        try fixture.git(["remote", "add", "backup", fixture.remotePath])
        let submenuItems = try XCTUnwrap(menuItems(selector: "menuItemsForRef:", argument: tag))
        XCTAssertTrue(submenuItems.contains { $0.hasSubmenu })

        try fixture.git(["checkout", "--quiet", "--detach", "HEAD"])
        repository.reloadRefs()
        repository.readCurrentBranch()
        waitForHistory()
        let detachedHead = try XCTUnwrap(repository.headRef()?.ref())
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: detachedHead), contains: ["Push"])
    }

    func testNavigationCopySearchQuickLookAndObserverCallbacks() throws {
        let commits = loadedCommits().filter { !$0.parents.isEmpty }
        XCTAssertFalse(commits.isEmpty)
        let child = commits[0]
        historyController.commitController.setSelectedObjects([child])
        historyController.updateKeys()
        historyController.selectParentCommit(self)
        XCTAssertEqual((historyController.commitController.selectedObjects.first as? PBGitCommit)?.oid, child.parents[0])

        historyController.commitController.setSelectedObjects([child])
        historyController.copy(self)
        historyController.copySHA(self)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains(child.sha) == true)
        historyController.copyShortName(self)
        historyController.commitController.setSelectedObjects([])
        historyController.copyPatch(self)
        historyController.commitController.setSelectedObjects([child])

        historyController.setHistorySearch("tracked.txt", mode: .path)
        historyController.selectNext(self)
        historyController.selectPrevious(self)
        historyController.performFindPanelAction(self)

        historyController.selectedCommitDetailsIndex = 1
        historyController.gitTree = child.tree
        pumpRunLoop()
        if let leafNode = firstLeafNode(in: historyController.treeController.arrangedObjects) {
            historyController.treeController.setSelectionIndexPath(leafNode.indexPath)
            pumpRunLoop(for: 0.5)
            let fileBrowser = try XCTUnwrap(historyController.value(forKey: "fileBrowser") as? NSOutlineView)
            fileBrowser.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let original = try XCTUnwrap(class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("openURL:")))
            let replacement = try XCTUnwrap(class_getInstanceMethod(
                WorkspaceOpenRecorder.self, #selector(WorkspaceOpenRecorder.recordOpenedURL(_:))
            ))
            WorkspaceOpenRecorder.openedURLs = []
            method_exchangeImplementations(original, replacement)
            defer {
                method_exchangeImplementations(original, replacement)
                WorkspaceOpenRecorder.openedURLs = []
            }
            historyController.openSelectedFile(self)
            let opened = try XCTUnwrap(WorkspaceOpenRecorder.openedURLs.first)
            XCTAssertTrue(opened.isFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path))
            XCTAssertEqual(historyController.numberOfPreviewItems(inPreviewPanel: nil), 1)
            XCTAssertNotNil(historyController.previewPanel(nil, previewItemAt: 0))
            _ = historyController.previewPanel(nil, sourceFrameOnScreenFor: NSURL(fileURLWithPath: "/tmp"))
        }
        historyController.updateQuicklookForce(false)
        let event = try XCTUnwrap(NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ))
        XCTAssertFalse(historyController.previewPanel(nil, handle: event))

        NotificationCenter.default.post(
            name: .PBGitHistorySortingPreferenceDidChange,
            object: nil
        )
        historyController._repositoryUpdatedNotification(
            Notification(
                name: .PBGitRepositoryEvent,
                object: repository,
                userInfo: [kPBGitRepositoryEventTypeUserInfoKey: NSNumber(value: 1 << 1)]
            )
        )
        waitForHistory()
        historyController.commitController.setSelectedObjects([])
        historyController.updateKeys()
        XCTAssertNil(historyController.gitTree)
        XCTAssertTrue(historyController.webCommits.isEmpty)
    }

    private func preservedPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
    }

    func testWorkingStatePatchCopyIncludesStagedAndUnstagedChanges() throws {
        let pasteboard = NSPasteboard.general
        let saved = preservedPasteboardItems(pasteboard)
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { $0 as NSPasteboardWriting })
        }
        try fixture.write("staged patch line\n", to: "nested/tracked.txt")
        try fixture.git(["add", "nested/tracked.txt"])
        try fixture.write("staged patch line\nunstaged patch line\n", to: "nested/tracked.txt")
        let working = PBUncommittedChanges(repository: repository)
        historyController.commitController.content = [working]
        historyController.commitController.setSelectedObjects([working])
        XCTAssertTrue(historyController.validateMenuItem(NSMenuItem(title: "Copy Patch", action: NSSelectorFromString("copyPatch:"), keyEquivalent: "")))
        historyController.copyPatch(self)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("+staged patch line"))
        XCTAssertTrue(copied.contains("+unstaged patch line"))
        XCTAssertTrue((windowController as? HistoryWindowController)?.shownMessages.isEmpty == true)
    }

    private final class SHAReadCountingCommit: PBGitCommit {
        private(set) var reads = 0
        override var sha: String {
            reads += 1
            return super.sha
        }
    }

    func testCopyMenuValidationUsesCachedOIDWithoutReadingSHA() throws {
        let real = try XCTUnwrap(loadedCommits().first)
        let counted = SHAReadCountingCommit(repository: repository, andCommit: real.gtCommit)
        historyController.commitController.content = [counted]
        historyController.commitController.setSelectedObjects([counted])
        let before = counted.reads
        for action in ["copy:", "copySHA:", "copyShortName:"] {
            let item = NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")
            XCTAssertTrue(historyController.validateMenuItem(item))
        }
        XCTAssertEqual(counted.reads, before)
        XCTAssertFalse(GitXCommitCopier.canCopyImmutableCommits([PBGitCommit()]))
    }

    func testWorkingStateImmutableCopyActionsPreserveClipboard() throws {
        let pasteboard = NSPasteboard.general
        let saved = preservedPasteboardItems(pasteboard)
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { $0 as NSPasteboardWriting })
        }
        let commit = try XCTUnwrap(loadedCommits().first)
        let working = PBUncommittedChanges(repository: repository)
        historyController.commitController.content = [commit, working]
        historyController.commitController.rearrangeObjects()
        for selection in [[working], [commit, working]] {
            historyController.commitController.setSelectedObjects(selection)
            for action in ["copy:", "copySHA:", "copyShortName:"] {
                let item = NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")
                XCTAssertFalse(historyController.validateMenuItem(item))
                pasteboard.clearContents()
                pasteboard.setString("preserve clipboard", forType: .string)
                historyController.perform(item.action, with: self)
                XCTAssertEqual(pasteboard.string(forType: .string), "preserve clipboard")
            }
        }
        historyController.commitController.setSelectedObjects([working])
        historyController.updateKeys()
        historyController.commitList.reloadData()
        pumpRunLoop()
        try attachScreenshot(of: XCTUnwrap(windowController.window?.contentView), named: "Working State immutable copy actions preserve the clipboard")
    }

    func testExportedRootOrdinaryAndMergePatchesRoundTripThroughApplyAndAm() throws {
        try fixture.git(["merge", "--quiet", "--no-ff", "feature", "-m", "merge export fixture"])
        let mergeSHA = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        historyController.refresh(self)
        XCTAssertTrue(waitForCondition { self.repository.revisionList?.commits.contains { ($0 as? PBGitCommit)?.sha == mergeSHA } == true })
        let commits = loadedCommits()
        let root = try XCTUnwrap(commits.first { $0.parents.isEmpty })
        let ordinary = try XCTUnwrap(commits.first { $0.parents.count == 1 })
        let merge = try XCTUnwrap(commits.first { $0.sha == mergeSHA })
        XCTAssertEqual(merge.parents.count, 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXPatchRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (offset, commit) in [root, ordinary, merge].enumerated() {
            let patch = try XCTUnwrap(commit.patch)
            XCTAssertFalse(patch.isEmpty)
            let arguments = commit.parents.count > 1
                ? ["show", "--first-parent", "-m", "--patch", "--format=email", commit.sha]
                : ["format-patch", "-1", "--stdout", commit.sha]
            let original = try fixture.git(arguments)
            XCTAssertTrue(patch.hasPrefix(original), "Git's original text must remain verbatim")
            let patchURL = directory.appendingPathComponent("\(offset).patch")
            try Data(patch.utf8).write(to: patchURL)
            let expectedTree = try fixture.git(["rev-parse", commit.sha + "^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            for useAm in [false, true] {
                let clone = directory.appendingPathComponent("clone-\(offset)-\(useAm)")
                try fixture.git(["clone", "--quiet", "--no-local", fixture.path, clone.path])
                @discardableResult
                func git(_ arguments: [String]) throws -> String {
                    try fixture.git(["-C", clone.path] + arguments)
                }
                try git(["config", "user.name", "Patch Round Trip"])
                try git(["config", "user.email", "patch@example.invalid"])
                if let parent = commit.parents.first {
                    try git(["checkout", "--quiet", "--detach", parent.sha])
                } else {
                    try git(["checkout", "--quiet", "--orphan", "empty-patch-base"])
                    try git(["rm", "--quiet", "-rf", "--ignore-unmatch", "."])
                }
                if useAm {
                    try git(["am", "--quiet", patchURL.path])
                    XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines), expectedTree)
                } else {
                    try git(["apply", "--index", patchURL.path])
                    XCTAssertEqual(try git(["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines), expectedTree)
                }
            }
        }
    }

    func testCommitPatchCharacterizesNewlineEmptyFailureAndCachedOutput() throws {
        let target = try XCTUnwrap(repository.headCommit()).gtCommit
        for (output, expected) in [("patch\n", "patch\n\n-- \n+GitX\n"), ("", ""), ("patch\n\n", "patch\n\n\n-- \n+GitX\n")] {
            let fake = PBCommitRecoveryRepository()
            fake.recoveryPatchOutput = output
            let commit = PBGitCommit(repository: fake, andCommit: target)
            XCTAssertEqual(commit.patch, expected)
            fake.recoveryPatchOutput = "changed output\n"
            XCTAssertEqual(commit.patch, expected)
            XCTAssertEqual(fake.recoveryPatchInvocationCount, 1)
        }
        let fake = PBCommitRecoveryRepository()
        let commit = PBGitCommit(repository: fake, andCommit: target)
        XCTAssertNil(commit.patch)
        XCTAssertNil(commit.patch)
        XCTAssertEqual(fake.recoveryPatchInvocationCount, 2)
    }

    func testCommitPatchPreservesFinalContentWhenOutputHasNoLineFeed() throws {
        let target = try XCTUnwrap(repository.headCommit()).gtCommit
        for output in ["patch-without-newline", "patch🙂", "patch\r", "patch\r\n"] {
            let fake = PBCommitRecoveryRepository()
            fake.recoveryPatchOutput = output
            let commit = PBGitCommit(repository: fake, andCommit: target)
            let terminated = output.unicodeScalars.last == "\n" ? output : output + "\n"
            XCTAssertEqual(commit.patch, terminated + "\n-- \n+GitX\n")
        }
    }

    func testCopyActionsCharacterizeMultipleCommitFormattingAndEmptySelection() throws {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { $0 as NSPasteboardWriting })
        }
        let commits = Array(loadedCommits().prefix(2))
        XCTAssertEqual(commits.count, 2)
        historyController.commitController.setSelectedObjects(commits)
        let selected = try XCTUnwrap(historyController.commitController.selectedObjects as? [PBGitCommit])
        XCTAssertEqual(selected.count, 2)
        historyController.copy(self)
        XCTAssertEqual(pasteboard.string(forType: .string), selected.reversed().map {
            "\($0.sha.prefix(10)) (\($0.subject))"
        }.joined(separator: "\n"))
        historyController.copySHA(self)
        XCTAssertEqual(pasteboard.string(forType: .string), selected.reversed().map(\.sha).joined(separator: "\n"))
        historyController.copyShortName(self)
        XCTAssertEqual(pasteboard.string(forType: .string), selected.reversed().map { $0.shortName() }.joined(separator: " "))
        selected[0].setValue("first patch", forKey: "patch")
        selected[1].setValue("second patch", forKey: "patch")
        historyController.copyPatch(self)
        XCTAssertEqual(pasteboard.string(forType: .string), "second patch\n\n\nfirst patch")
        for action in ["copy:", "copySHA:", "copyShortName:", "copyPatch:", "createPatch:"] {
            let item = NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")
            XCTAssertTrue(historyController.validateMenuItem(item))
            historyController.commitController.setSelectedObjects([])
            XCTAssertFalse(historyController.validateMenuItem(item))
            pasteboard.clearContents()
            pasteboard.setString("preserve clipboard", forType: .string)
            if action != "createPatch:" {
                historyController.perform(item.action, with: self)
            }
            XCTAssertEqual(pasteboard.string(forType: .string), "preserve clipboard")
            historyController.commitController.setSelectedObjects(selected)
        }
    }

    func testCopyPatchWarnsAfterCopyingAvailablePatchesAndPreservesAllUnavailableClipboard() throws {
        let window = try XCTUnwrap(windowController as? HistoryWindowController)
        let pasteboard = NSPasteboard.general
        let saved = preservedPasteboardItems(pasteboard)
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { $0 as NSPasteboardWriting })
        }
        let commits = Array(loadedCommits().prefix(3))
        XCTAssertEqual(commits.count, 3)
        historyController.commitController.setSelectedObjects(commits)
        let selected = try XCTUnwrap(historyController.commitController.selectedObjects as? [PBGitCommit])
        selected[0].setValue("first", forKey: "patch")
        selected[1].setValue("", forKey: "patch")
        selected[2].setValue("last", forKey: "patch")
        historyController.copyPatch(self)
        XCTAssertEqual(pasteboard.string(forType: .string), "last\n\n\nfirst")
        XCTAssertEqual(window.shownMessages.last?.message, "Some patches could not be copied")
        XCTAssertTrue(window.shownMessages.last?.info.contains("Copied 2 patches; skipped 1 commit") == true)
        selected.forEach { $0.setValue("", forKey: "patch") }
        pasteboard.clearContents()
        pasteboard.setString("preserve clipboard", forType: .string)
        historyController.copyPatch(self)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve clipboard")
        XCTAssertEqual(window.shownMessages.last?.message, "No patches available")
        XCTAssertTrue(window.shownMessages.last?.info.contains("skipped 3 commits") == true)
        let count = window.shownMessages.count
        historyController.commitController.setSelectedObjects([])
        historyController.copyPatch(self)
        XCTAssertEqual(window.shownMessages.count, count)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve clipboard")
    }

    func testHistoryUIEmptyNavigationAndRefreshBoundaries() throws {
        historyController.commitController.setSelectedObjects([])
        historyController.selectParentCommit(self)
        XCTAssertTrue(historyController.commitController.selectedObjects.isEmpty)
        let root = try XCTUnwrap(loadedCommits().first { $0.parents.isEmpty })
        historyController.commitController.setSelectedObjects([root])
        historyController.selectParentCommit(self)
        XCTAssertEqual((historyController.commitController.selectedObjects.first as? PBGitCommit)?.sha, root.sha)
        historyController.treeController.setSelectionIndexPaths([])
        historyController.openSelectedFile(self)
        historyController.updateView()
        historyController.refresh(self)
        waitForHistory()
        historyController.updateQuicklookForce(true)
        XCTAssertNotNil(historyController.commitController.arrangedObjects)
    }

    func testHistorySearchModesCharacterizeCurrentWhitespaceAndUnicodeBehavior() throws {
        let searchController = historyController.searchController
        let searchField = try XCTUnwrap(searchController.searchField)
        let arrangedCount = try XCTUnwrap(
            historyController.commitController.arrangedObjects as? [PBGitCommit]
        ).count
        XCTAssertGreaterThanOrEqual(arrangedCount, 3)

        XCTAssertEqual(try searchResultRows(for: "initial", mode: .basic).count, 1)
        XCTAssertTrue(searchController.hasSearchResults())
        XCTAssertEqual(searchField.stringValue, "initial")
        XCTAssertEqual(searchController.numberOfMatchesField.stringValue, "1 match")

        let basicWithOuterWhitespace = " \tinitial\n"
        XCTAssertTrue(try searchResultRows(for: basicWithOuterWhitespace, mode: .basic).isEmpty)
        XCTAssertFalse(searchController.hasSearchResults())
        XCTAssertEqual(searchField.stringValue, basicWithOuterWhitespace)
        XCTAssertEqual(searchController.numberOfMatchesField.stringValue, "Not found")

        XCTAssertEqual(
            try searchResultRows(for: "GitX Tests", mode: .basic).count,
            arrangedCount
        )
        XCTAssertEqual(searchField.stringValue, "GitX Tests")
        XCTAssertEqual(searchController.numberOfMatchesField.stringValue, "\(arrangedCount) matches")
        historyController.commitList.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        searchController.stepper.selectedSegment = 0
        searchController.stepperPressed(searchController.stepper)
        searchController.stepper.selectedSegment = 1
        searchController.stepperPressed(searchController.stepper)

        let unicodeQuery = "東京 crème"
        XCTAssertTrue(try searchResultRows(for: unicodeQuery, mode: .basic).isEmpty)
        XCTAssertEqual(searchField.stringValue, unicodeQuery)

        let pickaxeQuery = " \tsecond\n"
        XCTAssertEqual(try searchResultRows(for: pickaxeQuery, mode: .pickaxe).count, 1)
        XCTAssertEqual(searchField.stringValue, pickaxeQuery)

        let regexQuery = "\nseco.*\t"
        XCTAssertEqual(try searchResultRows(for: regexQuery, mode: .regex).count, 1)
        XCTAssertEqual(searchField.stringValue, regexQuery)

        let pathQuery = " \nnested/tracked.txt\t"
        XCTAssertEqual(try searchResultRows(for: pathQuery, mode: .path).count, 2)
        XCTAssertEqual(searchField.stringValue, pathQuery)

        let rawQuery = "\t--author=GitX\n"
        XCTAssertEqual(try searchResultRows(for: rawQuery, mode: .raw).count, 2)
        XCTAssertEqual(searchField.stringValue, rawQuery)
    }

    func testWhitespaceOnlySearchClearingDiffersBetweenBasicAndGitModes() throws {
        let searchController = historyController.searchController
        let searchField = try XCTUnwrap(searchController.searchField)
        let whitespace = " \t\n"

        XCTAssertTrue(try searchResultRows(for: whitespace, mode: .basic).isEmpty)
        XCTAssertEqual(searchField.stringValue, whitespace)
        XCTAssertFalse(searchController.numberOfMatchesField.isHidden)
        XCTAssertFalse(searchController.stepper.isHidden)

        for mode in [
            PBHistorySearchMode.pickaxe,
            .regex,
            .path,
            .raw,
        ] {
            XCTAssertTrue(try searchResultRows(for: whitespace, mode: mode).isEmpty)
            XCTAssertEqual(searchField.stringValue, "")
            XCTAssertTrue(searchController.numberOfMatchesField.isHidden)
            XCTAssertTrue(searchController.stepper.isHidden)
        }
    }

    func testSearchModeMenuSelectionPlaceholderAndPersistence() throws {
        let defaults = UserDefaults.standard
        let oldStoredMode = defaults.object(forKey: "PBHistorySearchMode")
        defer {
            if let oldStoredMode {
                defaults.set(oldStoredMode, forKey: "PBHistorySearchMode")
            } else {
                defaults.removeObject(forKey: "PBHistorySearchMode")
            }
        }

        let searchController = historyController.searchController
        let searchField = try XCTUnwrap(searchController.searchField)
        let searchFieldCell = try XCTUnwrap(searchField.cell as? NSSearchFieldCell)
        let menu = try XCTUnwrap(searchFieldCell.searchMenuTemplate)
        let expectations: [(PBHistorySearchMode, String)] = [
            (.basic, "Subject, Author, SHA"),
            (.pickaxe, "Commit (pickaxe)"),
            (.regex, "Commit (pickaxe regex)"),
            (.path, "File path"),
            (.raw, "Raw"),
        ]

        for (mode, placeholder) in expectations {
            let sender = NSButton()
            sender.tag = mode.rawValue
            searchController.selectSearchMode(sender)

            XCTAssertEqual(searchController.searchMode, mode)
            XCTAssertEqual(searchField.placeholderString, placeholder)
            XCTAssertEqual(defaults.integer(forKey: "PBHistorySearchMode"), mode.rawValue)
            for (candidate, _) in expectations {
                XCTAssertEqual(
                    menu.item(withTag: candidate.rawValue)?.state,
                    candidate == mode ? .on : .off
                )
            }
        }
    }

    func testHistorySearchRecentsCharacterizeSubmissionNavigationDedupAndClearing() throws {
        let searchController = historyController.searchController
        let searchField = try XCTUnwrap(searchController.searchField)
        let originalAutosaveName = searchField.recentsAutosaveName
        let originalRecents = searchField.recentSearches
        let autosaveName = "GitX History Search Tests \(UUID().uuidString)"
        defer {
            searchField.recentSearches = []
            searchField.recentsAutosaveName = originalAutosaveName
            searchField.recentSearches = originalRecents
            UserDefaults.standard.removeObject(forKey: autosaveName)
        }

        searchField.recentsAutosaveName = autosaveName
        searchField.recentSearches = []

        searchField.stringValue = "unchanged"
        searchController.setHistorySearch("", mode: .raw)
        XCTAssertEqual(searchField.stringValue, "unchanged")
        XCTAssertTrue(searchField.recentSearches.isEmpty)

        searchController.setHistorySearch("  alpha  ", mode: .basic)
        searchController.setHistorySearch("beta", mode: .basic)
        searchController.setHistorySearch("  alpha  ", mode: .basic)
        XCTAssertEqual(searchField.recentSearches, ["  alpha  ", "beta"])

        searchController.setHistorySearch("   ", mode: .basic)
        let submittedRecents = ["   ", "  alpha  ", "beta"]
        XCTAssertEqual(searchField.recentSearches, submittedRecents)

        searchController.clearSearch()
        XCTAssertEqual(searchField.stringValue, "")
        XCTAssertEqual(searchField.recentSearches, submittedRecents)

        let restoredField = NSSearchField()
        restoredField.recentsAutosaveName = autosaveName
        XCTAssertEqual(restoredField.recentSearches, submittedRecents)

        searchField.recentSearches = []
        let clearedField = NSSearchField()
        clearedField.recentsAutosaveName = autosaveName
        XCTAssertTrue(clearedField.recentSearches.isEmpty)

        searchField.stringValue = "init"
        searchController.updateSearch(self)
        searchField.stringValue = "initial"
        searchController.updateSearch(self)
        searchController.selectNextResult()
        XCTAssertTrue(searchField.recentSearches.isEmpty)

        searchField.performClick(self)
        XCTAssertEqual(searchField.recentSearches, ["initial"])
    }

    func testHistorySearchPastePreservesFullWhitespaceAndUnicode() throws {
        let searchField = try XCTUnwrap(historyController.searchController.searchField)
        let window = try XCTUnwrap(windowController.window)
        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems.map { $0 as NSPasteboardWriting })
        }

        searchField.stringValue = "prefix"
        XCTAssertTrue(window.makeFirstResponder(searchField))
        let editor = try XCTUnwrap(searchField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        pasteboard.clearContents()
        pasteboard.setString("  東京 crème  ", forType: .string)
        editor.paste(self)

        XCTAssertEqual(editor.string, "prefix  東京 crème  ")
        XCTAssertEqual(searchField.stringValue, "prefix  東京 crème  ")
    }

    func testPathMenuDisablesCommitActionsWithoutSelection() throws {
        historyController.selectedCommits = []

        let items = historyController.menuItems(forPaths: ["nested/tracked.txt"])
        let diff = try XCTUnwrap(items.first { $0.title.hasPrefix("Diff file") })
        let checkout = try XCTUnwrap(items.first { $0.title == "Checkout file" })
        let history = try XCTUnwrap(items.first { $0.title == "Show history of file" })
        let finder = try XCTUnwrap(items.first { $0.title == "Reveal in Finder" })
        let open = try XCTUnwrap(items.first { $0.title == "Open File" })

        XCTAssertFalse(diff.isEnabled)
        XCTAssertNil(diff.action)
        XCTAssertFalse(checkout.isEnabled)
        XCTAssertNil(checkout.action)
        XCTAssertTrue(history.isEnabled)
        XCTAssertTrue(finder.isEnabled)
        XCTAssertTrue(open.isEnabled)
    }

    func testWorkingStateTextDragPreservesPasteboard() {
        let working = PBUncommittedChanges(repository: repository)
        historyController.commitController.content = [working]
        historyController.commitController.rearrangeObjects()
        let table = CommitListFake()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ShortSHAColumn")))
        table.testRow = 0
        table.testColumn = 0
        table.revisionCell.referenceIndex = -1
        let coordinator = tableCoordinator
        let original = historyController.commitList
        historyController.setValue(table, forKey: "commitList")
        defer { historyController.setValue(original, forKey: "commitList") }
        let pasteboard = freshPasteboard()
        pasteboard.setString("preserve drag clipboard", forType: .string)
        let changeCount = pasteboard.changeCount
        let types = pasteboard.types
        XCTAssertFalse(coordinator.tableView(table, writeRowsWith: IndexSet(integer: 0), to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve drag clipboard")
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.types, types)
    }

    func testTablePasteboardDropCheckoutAndResponderInteractions() throws {
        repository.reloadRefs()
        let commits = loadedCommits()
        let featureRef = try XCTUnwrap(repository.ref(forName: "feature"))
        let sourceCommit = try XCTUnwrap(commits.first { commit in
            (commit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: featureRef) }
        })
        let destinationCommit = try XCTUnwrap(commits.first { $0 !== sourceCommit })
        historyController.commitController.content = [sourceCommit, destinationCommit]
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let sourceRow = try XCTUnwrap(arranged.firstIndex { $0 === sourceCommit })
        let destinationRow = try XCTUnwrap(arranged.firstIndex { $0 === destinationCommit })
        let featureIndex = try XCTUnwrap((sourceCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }
            .firstIndex { $0.isEqual(to: featureRef) })

        let table = CommitListFake()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SubjectColumn")))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ShortSHAColumn")))
        table.testRow = sourceRow
        table.testColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("ShortSHAColumn"))
        let tableCoordinator = self.tableCoordinator
        let originalCommitList = historyController.commitList
        historyController.setValue(table, forKey: "commitList")
        defer { historyController.setValue(originalCommitList, forKey: "commitList") }

        table.revisionCell.referenceIndex = -1
        let shortSHAPasteboard = freshPasteboard()
        XCTAssertTrue(tableCoordinator.tableView(
            table,
            writeRowsWith: IndexSet(integer: sourceRow),
            to: shortSHAPasteboard
        ))
        XCTAssertEqual(shortSHAPasteboard.string(forType: .string), sourceCommit.shortName())

        table.testColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("SubjectColumn"))
        let subjectPasteboard = freshPasteboard()
        XCTAssertTrue(tableCoordinator.tableView(
            table,
            writeRowsWith: IndexSet(integer: sourceRow),
            to: subjectPasteboard
        ))
        XCTAssertTrue(subjectPasteboard.string(forType: .string)?.contains(sourceCommit.subject) == true)

        table.revisionCell.referenceIndex = Int32(featureIndex)
        let referencePasteboard = freshPasteboard()
        XCTAssertTrue(tableCoordinator.tableView(
            table,
            writeRowsWith: IndexSet(integer: sourceRow),
            to: referencePasteboard
        ))
        XCTAssertNotNil(referencePasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef")))

        let draggingInfo = DraggingInfoFake(pasteboard: referencePasteboard)
        XCTAssertEqual(
            tableCoordinator.tableView(
                table,
                validateDrop: draggingInfo,
                proposedRow: destinationRow,
                proposedDropOperation: .above
            ),
            []
        )
        XCTAssertEqual(
            tableCoordinator.tableView(
                table,
                validateDrop: draggingInfo,
                proposedRow: destinationRow,
                proposedDropOperation: .on
            ),
            .move
        )
        let emptyDraggingInfo = DraggingInfoFake(pasteboard: freshPasteboard())
        XCTAssertEqual(
            tableCoordinator.tableView(
                table,
                validateDrop: emptyDraggingInfo,
                proposedRow: destinationRow,
                proposedDropOperation: .on
            ),
            []
        )
        XCTAssertFalse(tableCoordinator.tableView(
            table,
            acceptDrop: draggingInfo,
            row: destinationRow,
            dropOperation: .above
        ))
        XCTAssertFalse(tableCoordinator.tableView(
            table,
            acceptDrop: emptyDraggingInfo,
            row: destinationRow,
            dropOperation: .on
        ))
        XCTAssertFalse(tableCoordinator.tableView(
            table,
            acceptDrop: draggingInfo,
            row: sourceRow,
            dropOperation: .on
        ))
        XCTAssertTrue(tableCoordinator.tableView(
            table,
            acceptDrop: draggingInfo,
            row: destinationRow,
            dropOperation: .on
        ))
        let historyWindowController = try XCTUnwrap(windowController as? HistoryWindowController)
        XCTAssertEqual(historyWindowController.confirmationCount, 1)
        XCTAssertTrue((destinationCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: featureRef) })

        let missingRef = PBGitRef(string: "refs/heads/history-tests-missing")
        destinationCommit.addRef(missingRef)
        table.testRow = destinationRow
        table.revisionCell.referenceIndex = try Int32(XCTUnwrap(
            (destinationCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }
                .firstIndex { $0.isEqual(to: missingRef) }
        ))
        tableCoordinator.didDoubleClickCommitList(table)
        XCTAssertEqual(historyWindowController.shownErrors.count, 1)

        historyController.selectedCommits = [destinationCommit]
        let checkoutSender = NSMenuItem()
        checkoutSender.representedObject = ["nested/tracked.txt"]
        historyController.checkoutFiles(checkoutSender)
        let badCheckoutSender = NSMenuItem()
        badCheckoutSender.representedObject = ["does-not-exist.txt"]
        historyController.checkoutFiles(badCheckoutSender)
        XCTAssertEqual(historyWindowController.shownErrors.count, 2)

        historyController.commitController.setSelectedObjects([destinationCommit])
        historyController.selectedCommits = [destinationCommit]
        XCTAssertTrue(historyController.isCommitSelected())
        historyController.selectedCommits = []
        XCTAssertFalse(historyController.isCommitSelected())

        historyController.selectedCommitDetailsIndex = 1
        historyController.gitTree = destinationCommit.tree
        pumpRunLoop()
        if let firstPath = historyController.treeController.arrangedObjects.children?.first?.indexPath {
            historyController.treeController.setSelectionIndexPath(firstPath)
            XCTAssertFalse(historyController.contextMenuForTreeView().items.isEmpty)
        }

        let qlTextView = QLTextViewFake(frame: .zero)
        historyController.view.addSubview(qlTextView)
        XCTAssertTrue(windowController.window?.makeFirstResponder(qlTextView) == true)
        historyController.selectNext(self)
        historyController.selectPrevious(self)
        XCTAssertEqual(qlTextView.findActionCount, 2)

        let focusSearchEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: windowController.window?.windowNumber ?? 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        historyController.keyDown(with: focusSearchEvent)
        let searchField = try XCTUnwrap(historyController.value(forKey: "searchField") as? NSSearchField)
        XCTAssertTrue(windowController.window?.firstResponder === searchField.currentEditor())

        let previewKeyEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowController.window?.windowNumber ?? 0,
            context: nil,
            characters: "j",
            charactersIgnoringModifiers: "j",
            isARepeat: false,
            keyCode: 38
        ))
        XCTAssertTrue(historyController.previewPanel(nil, handle: previewKeyEvent))
    }

    func testCommitListSpaceKeyFollowsTheDetailMode() throws {
        func spaceEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: windowController.window?.windowNumber ?? 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            ))
        }
        let commit = try XCTUnwrap(loadedCommits().first)
        historyController.commitController.setSelectedObjects([commit])
        historyController.updateKeys()

        // Details pages the diff; Flow has nothing to page or preview, so the
        // key falls through to the table without opening an empty Quick Look.
        historyController.selectedCommitDetailsIndex = 0
        try historyController.commitList.keyDown(with: spaceEvent(modifiers: []))
        try historyController.commitList.keyDown(with: spaceEvent(modifiers: [.shift]))
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)

        historyController.selectedCommitDetailsIndex = 2
        try historyController.commitList.keyDown(with: spaceEvent(modifiers: []))
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 2)
        XCTAssertEqual(historyController.selectedCommits, [commit])

        // Assert the actual Quick Look dispatch, not only the selected tab.
        let quickLookSpy = try XCTUnwrap(QuickLookHistoryControllerSpy(
            repository: repository,
            superController: nil
        ))
        let commitList = historyController.commitList
        let originalController = commitList.value(forKey: "controller")
        commitList.setValue(quickLookSpy, forKey: "controller")
        defer { commitList.setValue(originalController, forKey: "controller") }

        quickLookSpy.detailIndex = 2
        try commitList.keyDown(with: spaceEvent(modifiers: []))
        XCTAssertEqual(quickLookSpy.toggleCount, 0, "Flow must not open an empty Quick Look panel")

        quickLookSpy.detailIndex = 1
        try commitList.keyDown(with: spaceEvent(modifiers: []))
        XCTAssertEqual(quickLookSpy.toggleCount, 1, "Tree mode must continue to route Space to Quick Look")
    }

    func testBranchDragSourceMaskNegotiatesMoveOnlyInsideApplication() throws {
        let commitListClass = try XCTUnwrap(NSClassFromString("GitX.PBCommitList") as? NSTableView.Type)
        let commitList = commitListClass.init(frame: .zero)
        let selector = NSSelectorFromString("branchDragSourceOperationMaskForContext:")
        let implementation = try XCTUnwrap(commitList.method(for: selector))
        typealias SourceMaskImplementation = @convention(c) (
            AnyObject,
            Selector,
            NSDraggingContext
        ) -> NSDragOperation
        // swift6-safety-justification: The Objective-C entry point accepts exactly one NSDraggingContext enum argument.
        let sourceMask = unsafeBitCast(implementation, to: SourceMaskImplementation.self)

        XCTAssertEqual(
            sourceMask(commitList, selector, .withinApplication),
            .move
        )
        XCTAssertEqual(
            sourceMask(commitList, selector, .outsideApplication),
            []
        )
    }

    func testBranchLabelDragPayloadAndEligibility() throws {
        repository.reloadRefs()
        let commits = loadedCommits()
        historyController.commitController.content = commits
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])

        let table = CommitListFake()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SubjectColumn")))
        table.testColumn = 0
        let tableCoordinator = self.tableCoordinator
        let originalCommitList = historyController.commitList
        historyController.setValue(table, forKey: "commitList")
        defer { historyController.setValue(originalCommitList, forKey: "commitList") }

        func writeDrag(for ref: PBGitRef) throws -> (Bool, NSPasteboard, Int, Int) {
            let row = try XCTUnwrap(arranged.firstIndex { commit in
                (commit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: ref) }
            })
            let referenceIndex = try XCTUnwrap(
                (arranged[row].refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.firstIndex { $0.isEqual(to: ref) }
            )
            table.testRow = row
            table.revisionCell.referenceIndex = Int32(referenceIndex)
            let pasteboard = freshPasteboard()
            let didWrite = tableCoordinator.tableView(
                table,
                writeRowsWith: IndexSet(integer: row),
                to: pasteboard
            )
            return (didWrite, pasteboard, row, referenceIndex)
        }

        let feature = try XCTUnwrap(repository.ref(forName: "feature"))
        let (didWriteFeature, featurePasteboard, featureRow, _) = try writeDrag(for: feature)
        XCTAssertTrue(didWriteFeature)
        let featureData = try XCTUnwrap(
            featurePasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef"))
        )
        let payload = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: featureData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["referenceName"] as? String, "refs/heads/feature")
        XCTAssertEqual(payload["sourceSHA"] as? String, arranged[featureRow].sha)

        let ineligibleReferences = try [
            XCTUnwrap(repository.headRef()?.ref()),
            XCTUnwrap(repository.ref(forName: "v1")),
            XCTUnwrap(repository.ref(forName: "origin/main")),
        ]
        for ref in ineligibleReferences {
            let (didWrite, pasteboard, _, _) = try writeDrag(for: ref)
            XCTAssertFalse(didWrite)
            XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef")))
        }

        table.testRow = arranged.count
        table.revisionCell.referenceIndex = 0
        let outOfRangePasteboard = freshPasteboard()
        XCTAssertFalse(tableCoordinator.tableView(
            table,
            writeRowsWith: IndexSet(integer: arranged.count),
            to: outOfRangePasteboard
        ))
        XCTAssertNil(outOfRangePasteboard.data(forType: NSPasteboard.PasteboardType("PBGitRef")))
    }

    func testBranchMoveSurvivesCommitAndReferenceReordering() throws {
        let drag = try branchDragFixture()
        try XCTUnwrap(drag.sourceCommit.refs).insert(PBGitRef(string: "refs/tags/reordered-label"), at: 0)
        historyController.commitController.sortDescriptors = [
            NSSortDescriptor(key: "SHA", ascending: false),
        ]
        historyController.commitController.rearrangeObjects()
        let reordered = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let destinationRow = try XCTUnwrap(reordered.firstIndex { $0.sha == drag.destinationCommit.sha })
        let info = DraggingInfoFake(pasteboard: drag.pasteboard)

        XCTAssertEqual(
            tableCoordinator.tableView(
                drag.table,
                validateDrop: info,
                proposedRow: destinationRow,
                proposedDropOperation: .on
            ),
            .move
        )
        XCTAssertTrue(tableCoordinator.tableView(
            drag.table,
            acceptDrop: info,
            row: destinationRow,
            dropOperation: .on
        ))
        XCTAssertTrue(
            (drag.destinationCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }
                .contains { $0.ref == "refs/heads/feature" }
        )
    }

    func testBranchMoveRejectsStaleReference() throws {
        let drag = try branchDragFixture()
        try fixture.git(["update-ref", "refs/heads/feature", drag.destinationCommit.sha])
        XCTAssertEqual(
            tableCoordinator.tableView(
                drag.table,
                validateDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
                proposedRow: drag.destinationRow,
                proposedDropOperation: .on
            ),
            []
        )
        XCTAssertFalse(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: drag.destinationRow,
            dropOperation: .on
        ))
    }

    func testBranchMoveRejectsSourceThatBecameCheckedOutAfterDragStarted() throws {
        let checkedOutDrag = try branchDragFixture()
        try fixture.git(["checkout", "--quiet", "feature"])
        XCTAssertFalse(tableCoordinator.tableView(
            checkedOutDrag.table,
            acceptDrop: DraggingInfoFake(pasteboard: checkedOutDrag.pasteboard),
            row: checkedOutDrag.destinationRow,
            dropOperation: .on
        ))
        XCTAssertEqual(
            try XCTUnwrap(windowController as? HistoryWindowController).confirmationCount,
            0
        )
    }

    func testBranchMoveRejectsDetachedRepositoryWindow() throws {
        let drag = try branchDragFixture()
        let historyWindowController = try XCTUnwrap(windowController as? HistoryWindowController)
        historyWindowController.repository = nil

        XCTAssertFalse(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: drag.destinationRow,
            dropOperation: .on
        ))
        XCTAssertEqual(historyWindowController.confirmationCount, 0)
    }

    func testBranchMoveRejectsCopyOnlyMalformedLegacyAndWorkingStateDrops() throws {
        let drag = try branchDragFixture()
        let copyOnlyInfo = DraggingInfoFake(pasteboard: drag.pasteboard)
        copyOnlyInfo.draggingSourceOperationMask = .copy
        XCTAssertEqual(
            tableCoordinator.tableView(
                drag.table,
                validateDrop: copyOnlyInfo,
                proposedRow: drag.destinationRow,
                proposedDropOperation: .on
            ),
            []
        )
        XCTAssertFalse(tableCoordinator.tableView(
            drag.table,
            acceptDrop: copyOnlyInfo,
            row: drag.destinationRow,
            dropOperation: .on
        ))

        for malformedData in try [
            PropertyListSerialization.data(
                fromPropertyList: [-1, -1],
                format: .binary,
                options: 0
            ),
            Data("not a property list".utf8),
            branchPayloadData(
                referenceName: "refs/remotes/origin/main",
                sourceSHA: drag.sourceCommit.sha
            ),
            branchPayloadData(
                referenceName: "refs/heads/feature",
                sourceSHA: "-1"
            ),
        ] {
            let malformedPasteboard = freshPasteboard()
            malformedPasteboard.setData(
                malformedData,
                forType: NSPasteboard.PasteboardType("PBGitRef")
            )
            let malformedInfo = DraggingInfoFake(pasteboard: malformedPasteboard)
            XCTAssertEqual(
                tableCoordinator.tableView(
                    drag.table,
                    validateDrop: malformedInfo,
                    proposedRow: drag.destinationRow,
                    proposedDropOperation: .on
                ),
                []
            )
            XCTAssertFalse(tableCoordinator.tableView(
                drag.table,
                acceptDrop: malformedInfo,
                row: drag.destinationRow,
                dropOperation: .on
            ))
        }

        let workingState = PBUncommittedChanges(repository: repository)
        historyController.commitController.content = [drag.sourceCommit, workingState]
        historyController.commitController.sortDescriptors = []
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let workingStateRow = try XCTUnwrap(arranged.firstIndex { $0 is PBUncommittedChanges })
        XCTAssertEqual(
            tableCoordinator.tableView(
                drag.table,
                validateDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
                proposedRow: workingStateRow,
                proposedDropOperation: .on
            ),
            []
        )
        XCTAssertFalse(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: workingStateRow,
            dropOperation: .on
        ))
    }

    func testBranchMoveRejectsSameCommitAtDifferentRow() throws {
        let drag = try branchDragFixture()
        let duplicate = PBGitCommit(repository: repository, andCommit: drag.sourceCommit.gtCommit)
        historyController.commitController.content = [drag.sourceCommit, duplicate]
        historyController.commitController.sortDescriptors = []
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let duplicateRow = try XCTUnwrap(arranged.firstIndex { $0 === duplicate })
        XCTAssertNotEqual(duplicateRow, drag.sourceRow)
        XCTAssertEqual(duplicate.sha, drag.sourceCommit.sha)

        XCTAssertEqual(
            tableCoordinator.tableView(
                drag.table,
                validateDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
                proposedRow: duplicateRow,
                proposedDropOperation: .on
            ),
            []
        )
        XCTAssertFalse(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: duplicateRow,
            dropOperation: .on
        ))
    }

    func testBranchMoveCancellationLeavesReferenceUnchanged() throws {
        let drag = try branchDragFixture()
        let historyWindowController = try XCTUnwrap(windowController as? HistoryWindowController)
        historyWindowController.automaticallyConfirms = false

        XCTAssertTrue(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: drag.destinationRow,
            dropOperation: .on
        ))
        XCTAssertEqual(historyWindowController.confirmationCount, 1)
        XCTAssertTrue(
            (drag.sourceCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }
                .contains { $0.ref == "refs/heads/feature" }
        )
        XCTAssertFalse(
            (drag.destinationCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }
                .contains { $0.ref == "refs/heads/feature" }
        )
        XCTAssertEqual(repository.ref(forName: "feature")?.ref, "refs/heads/feature")
    }

    func testBranchMoveRejectsReferenceChangedWhileConfirmationIsOpen() throws {
        let drag = try branchDragFixture()
        let historyWindowController = try XCTUnwrap(windowController as? HistoryWindowController)
        historyWindowController.automaticallyConfirms = false

        XCTAssertTrue(tableCoordinator.tableView(
            drag.table,
            acceptDrop: DraggingInfoFake(pasteboard: drag.pasteboard),
            row: drag.destinationRow,
            dropOperation: .on
        ))
        let interveningSHA = try fixture.git(["rev-parse", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["update-ref", "refs/heads/feature", interveningSHA])

        historyWindowController.confirmPendingAction()

        XCTAssertEqual(
            try fixture.git(["rev-parse", "refs/heads/feature"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            interveningSHA
        )
        XCTAssertEqual(historyWindowController.shownErrors.count, 1)
    }

    private func loadedCommits() -> [PBGitCommit] {
        waitForHistory()
        return repository.revisionList?.commits.compactMap { $0 as? PBGitCommit } ?? []
    }

    private func selectCommitForFlowAnalysis(
        revision: String = "main",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sha = try? fixture.git(["rev-parse", revision])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = loadedCommits().first { $0.sha == sha }
        XCTAssertNotNil(commit, "The \(revision) commit was not loaded", file: file, line: line)
        guard let commit else { return }
        historyController.commitController.setSelectedObjects([commit])
        historyController.updateKeys()
        XCTAssertEqual(historyController.selectedCommits, [commit], file: file, line: line)
    }

    /// Commits the staged fixture changes and waits until History lists the
    /// new commit, returning its SHA.
    @discardableResult
    private func commitAndReloadHistory(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try fixture.git(["commit", "--quiet", "-m", message])
        let sha = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        historyController.refresh(self)
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                let revisionIsVisible = self.repository.revisionList?.commits.contains {
                    ($0 as? PBGitCommit)?.sha == sha
                } == true
                let arrangedCommitIsVisible = (self.historyController.commitController.arrangedObjects as? [PBGitCommit])?
                    .contains { $0.sha == sha } == true
                return revisionIsVisible && arrangedCommitIsVisible
            },
            "History did not list and arrange the commit \"\(message)\"",
            file: file,
            line: line
        )
        return sha
    }

    private func flowLabels(in flowView: NSView) -> [String] {
        controls(in: flowView).compactMap { control in
            guard let label = control as? NSTextField,
                  !label.isHiddenOrHasHiddenAncestor
            else { return nil }
            return label.stringValue
        }
    }

    private func searchResultRows(
        for query: String,
        mode: PBHistorySearchMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IndexSet {
        let searchController = historyController.searchController
        let searchField = try XCTUnwrap(searchController.searchField, file: file, line: line)
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.repository.revisionList?.isUpdating != true
            },
            "Revision loading did not settle before history search",
            file: file,
            line: line
        )
        searchController.searchMode = mode
        searchField.stringValue = query
        searchController.updateSearch(self)

        if mode != .basic {
            XCTAssertTrue(
                waitForCondition {
                    searchController.value(forKey: "backgroundSearchTask") == nil
                },
                "Background history search did not finish",
                file: file,
                line: line
            )
        }

        let count = try XCTUnwrap(
            historyController.commitController.arrangedObjects as? [PBGitCommit],
            file: file,
            line: line
        ).count
        return IndexSet((0 ..< count).filter {
            searchController.isRow(inSearchResults: $0)
        })
    }

    private struct BranchDragFixture {
        let table: CommitListFake
        let sourceCommit: PBGitCommit
        let destinationCommit: PBGitCommit
        let sourceRow: Int
        let destinationRow: Int
        let pasteboard: NSPasteboard
    }

    private func branchDragFixture() throws -> BranchDragFixture {
        repository.reloadRefs()
        let commits = loadedCommits()
        let feature = try XCTUnwrap(repository.ref(forName: "feature"))
        let sourceCommit = try XCTUnwrap(commits.first { commit in
            (commit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.contains { $0.ref == feature.ref }
        })
        let destinationCommit = try XCTUnwrap(commits.first { $0.sha != sourceCommit.sha })
        historyController.commitController.content = [sourceCommit, destinationCommit]
        historyController.commitController.sortDescriptors = []
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let sourceRow = try XCTUnwrap(arranged.firstIndex { $0 === sourceCommit })
        let destinationRow = try XCTUnwrap(arranged.firstIndex { $0 === destinationCommit })
        let referenceIndex = try XCTUnwrap(
            (sourceCommit.refs ?? NSMutableArray()).compactMap { $0 as? PBGitRef }.firstIndex { $0.ref == feature.ref }
        )

        let table = CommitListFake()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SubjectColumn")))
        table.testColumn = 0
        table.testRow = sourceRow
        table.revisionCell.referenceIndex = Int32(referenceIndex)
        let pasteboard = freshPasteboard()
        XCTAssertTrue(tableCoordinator.tableView(
            table,
            writeRowsWith: IndexSet(integer: sourceRow),
            to: pasteboard
        ))
        return BranchDragFixture(
            table: table,
            sourceCommit: sourceCommit,
            destinationCommit: destinationCommit,
            sourceRow: sourceRow,
            destinationRow: destinationRow,
            pasteboard: pasteboard
        )
    }

    private func branchPayloadData(
        referenceName: String,
        sourceSHA: String,
        version: Int = 1
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "version": version,
                "referenceName": referenceName,
                "sourceSHA": sourceSHA,
            ],
            format: .binary,
            options: 0
        )
    }

    private func flattenedTree(_ root: PBGitTree) -> [PBGitTree] {
        [root] + root.children.flatMap(flattenedTree)
    }

    private func descendant(identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        return root.subviews.lazy.compactMap { self.descendant(identifier: identifier, in: $0) }.first
    }

    private func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { child -> [NSControl] in
            var result = controls(in: child)
            if let control = child as? NSControl {
                result.insert(control, at: 0)
            }
            return result
        }
    }

    private func firstLeafNode(in node: NSTreeNode) -> NSTreeNode? {
        if (node.representedObject as? PBGitTree)?.leaf == true {
            return node
        }
        return node.children?.lazy.compactMap(firstLeafNode).first
    }

    private func waitForTreeLeaf(timeout: TimeInterval = 3.0) -> NSTreeNode? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let leaf = firstLeafNode(in: historyController.treeController.arrangedObjects) {
                return leaf
            }
            pumpRunLoop()
        }
        return nil
    }

    private func waitForTreeNode(fullPath: String, timeout: TimeInterval = 3.0) -> NSTreeNode? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = treeNode(fullPath: fullPath, in: historyController.treeController.arrangedObjects) {
                return node
            }
            pumpRunLoop()
        }
        return nil
    }

    private func waitForCondition(timeout: TimeInterval = 5.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            pumpRunLoop()
        }
        return condition()
    }

    private func treeNode(fullPath: String, in node: NSTreeNode) -> NSTreeNode? {
        if (node.representedObject as? PBGitTree)?.fullPath == fullPath {
            return node
        }
        return node.children?.lazy.compactMap { self.treeNode(fullPath: fullPath, in: $0) }.first
    }

    private var tableCoordinator: PBHistoryTableInteractionCoordinator {
        historyController.commitList.delegate as! PBHistoryTableInteractionCoordinator
    }

    private func waitForHistory(file: StaticString = #filePath, line: UInt = #line) {
        guard repository != nil else { return }
        let deadline = Date().addingTimeInterval(10)
        let minimumDrainDate = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            let hasCommits = (repository.revisionList?.commits.count ?? 0) > 0
            if Date() >= minimumDrainDate,
               repository.revisionList?.isUpdating != true || hasCommits
            {
                return
            }
            pumpRunLoop()
        }
        XCTAssertGreaterThan(repository.revisionList?.commits.count ?? 0, 0, file: file, line: line)
    }

    private func refreshIndex() {
        let expectation = expectation(
            forNotification: Notification.Name(PBGitIndexFinishedIndexRefresh),
            object: repository.index,
            handler: nil
        )
        repository.index.refresh()
        wait(for: [expectation], timeout: 10)
        pumpRunLoop()
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func pumpRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func installCancellableGitWrapper(started: URL, terminated: URL) throws -> URL {
        let wrapper = testArtifactDirectory.appendingPathComponent("git-flow-wrapper")
        let startedPath = shellSingleQuoted(started.path)
        let terminatedPath = shellSingleQuoted(terminated.path)
        let script = """
        #!/bin/bash
        for argument in "$@"; do
            if [[ "$argument" == *":Cancelled.swift" ]]; then
                : > \(startedPath)
                trap ': > \(terminatedPath); exit 143' TERM
                while true; do
                    sleep 1
                done
            fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    private func installLoggingGitWrapper(log: URL, oversizedBlobPath: String? = nil) throws -> URL {
        let wrapper = testArtifactDirectory.appendingPathComponent("git-flow-logging-wrapper")
        let logPath = shellSingleQuoted(log.path)
        let oversizedBlobResponse = oversizedBlobPath.map { path in
            """
            if [[ "$*" == *"cat-file -s"* && "$*" == *":\(path)"* ]]; then
                printf '2200018\\n'
                exit 0
            fi
            """
        } ?? ""
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> \(logPath)
        \(oversizedBlobResponse)
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    private func installOversizedNameStatusGitWrapper() throws -> URL {
        let wrapper = testArtifactDirectory.appendingPathComponent("git-flow-oversized-output-wrapper")
        let script = """
        #!/bin/bash
        for argument in "$@"; do
            if [[ "$argument" == "--name-status" ]]; then
                /bin/dd if=/dev/zero bs=1048576 count=9 2>/dev/null
                exit 0
            fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func menuItems(selector: String, argument: Any?) -> [NSMenuItem]? {
        historyController.perform(NSSelectorFromString(selector), with: argument)?
            .takeUnretainedValue() as? [NSMenuItem]
    }

    private func freshPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitX.HistoryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func assertMenu(
        _ items: [NSMenuItem]?,
        contains fragments: [String],
        excludes excludedFragments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titles = items?.map(\.title) ?? []
        for fragment in fragments {
            XCTAssertTrue(titles.contains { $0.contains(fragment) }, "Missing \(fragment) in \(titles)", file: file, line: line)
        }
        for fragment in excludedFragments {
            XCTAssertFalse(titles.contains { $0.contains(fragment) }, "Unexpected \(fragment) in \(titles)", file: file, line: line)
        }
        XCTAssertTrue(items?.allSatisfy { $0.isSeparatorItem || $0.representedObject != nil } == true, file: file, line: line)
    }
}
