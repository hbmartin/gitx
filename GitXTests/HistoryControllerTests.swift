import AppKit
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

    private final class HistoryWindowController: PBGitWindowController {
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

        override var repository: PBGitRepository {
            get { fixedRepository }
            set { fixedRepository = newValue }
        }

        override func showErrorSheet(_ error: Error) {
            shownErrors.append(error as NSError)
        }

        override func open(_ fileURLs: [URL]) {
            openedURLs = fileURLs
        }

        override func revealURLs(inFinder fileURLs: [URL]) {
            revealedURLs = fileURLs
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
            retryHandler: @escaping () -> Void
        ) {
            shownMessages.append((messageText, infoText))
            hookFailureRetryHandlers.append(retryHandler)
        }

        override func performPush(
            forBranch branchRef: PBGitRef?,
            toRemote remoteRef: PBGitRef?,
            requiresConfirmation: Bool
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

    private final class QLTextViewFake: PBQLTextView {
        private(set) var findActionCount = 0

        override func performFindPanelAction(_ sender: Any?) {
            findActionCount += 1
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
            try git(["add", "--all"])
            try git(["commit", "--quiet", "-m", "initial commit"])
            try write("second\n", to: "nested/tracked.txt")
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

    private var fixture: GitFixture!
    private var repository: PBGitRepository!
    private var historyController: PBGitHistoryController!
    private var windowController: PBGitWindowController!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where all AppKit fixtures must be created.
        try MainActor.assumeIsolated {
            for window in NSApp.windows where window.windowController is PBGitWindowController {
                window.orderOut(nil)
                window.close()
            }
            fixture = try GitFixture()
            repository = try PBGitRepository(url: URL(fileURLWithPath: fixture.path))
            repository.currentBranchFilter = 0
            repository.readCurrentBranch()
            waitForHistory()
            UserDefaults.standard.set(0, forKey: "PBHistorySelectedDetailIndex")
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

        let detailItem = NSMenuItem(title: "Detail", action: #selector(PBGitHistoryController.setDetailedView(_:)), keyEquivalent: "")
        historyController.setDetailedView(detailItem)
        XCTAssertEqual(historyController.selectedCommitDetailsIndex, 0)
        XCTAssertTrue(historyController.validateMenuItem(detailItem))
        XCTAssertEqual(detailItem.state, .on)

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
        XCTAssertNotNil(tableCoordinator.tableView(historyController.commitList, rowViewForRow: 0))
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
            fileView.perform(NSSelectorFromString("modeChanged:"), with: modeControl)
            pumpRunLoop(for: 0.5)
            XCTAssertFalse(nativeView.textView.string.isEmpty)
        }
        try fixture.git(["config", "--local", "gitx.diffSuppressionPatterns", "# ignored\n^generated/"])
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
        try historyController.commitController.setSelectedObjects([XCTUnwrap(workingState)])
        historyController.updateKeys()
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
        let currentCommits = currentRevList.value(forKey: "commits")
        let publishedCount = historyList.commits.count
        currentRevList.setValue(nil, forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue(NSNull(), forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue("invalid payload", forKey: "commits")
        XCTAssertEqual(historyList.commits.count, publishedCount)
        currentRevList.setValue(currentCommits, forKey: "commits")
        currentRevList.setValue(NSMutableArray(), forKey: "commits")
        historyList.commits = [commits[0]]
        historyList.setValue(true, forKey: "resetCommits")
        historyList.isUpdating = true
        _ = historyList.perform(NSSelectorFromString("finishedGraphing"))
        XCTAssertEqual(historyList.commits.count, 0)
        XCTAssertFalse(historyList.isUpdating)
        currentRevList.setValue(currentCommits, forKey: "commits")
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

    func testApplicationDelegateCoversActivationAndFileOpens() throws {
        // These app-delegate paths only run when the host application is
        // activated or receives file-open events, which never happens
        // deterministically in a headless suite; drive them directly.
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
        settings.sidebarVisibility = ["Stage": false]

        let reloaded = PBRepositoryUISettings(repository: repository)
        XCTAssertTrue(reloaded.pushAfterCommit)
        XCTAssertTrue(reloaded.hideContainedBranches)
        XCTAssertFalse(reloaded.isSidebarGroupVisible("Stage"))
        XCTAssertTrue(reloaded.isSidebarGroupVisible("Remotes"))
    }

    @discardableResult
    private func openStagingPane() throws -> PBStagingViewController {
        historyController.selectedCommitDetailsIndex = 0
        refreshIndex()
        historyController.updateUncommittedChanges()
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
        pumpRunLoop()
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
        XCTAssertEqual(fileList.stagedFileCount, 0)
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
        waitForIndexUpdate { coordinator.stageSelectedFiles() }
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
        XCTAssertEqual(coordinator.validateDrop(info, in: fileList.stagedTable), .copy)
        waitForIndexUpdate {
            XCTAssertTrue(coordinator.acceptDrop(info, in: fileList.stagedTable))
        }
        XCTAssertEqual(fileList.stagedFileCount, 2, "the dragged unstaged file lands in the staged list")

        let sameSource = DraggingInfoFake(pasteboard: pasteboard)
        sameSource.draggingSource = fileList.unstagedTable
        XCTAssertEqual(
            coordinator.validateDrop(sameSource, in: fileList.unstagedTable),
            [],
            "drags within the same table are rejected"
        )
        let emptyPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsEmpty"))
        emptyPasteboard.clearContents()
        XCTAssertFalse(coordinator.acceptDrop(DraggingInfoFake(pasteboard: emptyPasteboard), in: fileList.stagedTable))

        XCTAssertFalse(
            coordinator.writeRows(with: IndexSet(integer: 99), from: fileList.unstagedTable, to: pasteboard),
            "out-of-range drag rows are rejected"
        )
        let fileChangesType = NSPasteboard.PasteboardType("GitFileChangedType")
        let corruptPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsCorrupt"))
        corruptPasteboard.clearContents()
        corruptPasteboard.declareTypes([fileChangesType], owner: nil)
        corruptPasteboard.setData(Data([0x00, 0x01, 0x02]), forType: fileChangesType)
        XCTAssertFalse(
            coordinator.acceptDrop(DraggingInfoFake(pasteboard: corruptPasteboard), in: fileList.stagedTable),
            "corrupt drag payloads are rejected"
        )
        let staleRowsPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingCoordinatorTestsStale"))
        staleRowsPasteboard.clearContents()
        staleRowsPasteboard.declareTypes([fileChangesType], owner: nil)
        try staleRowsPasteboard.setData(
            NSKeyedArchiver.archivedData(withRootObject: NSIndexSet(index: 99), requiringSecureCoding: true),
            forType: fileChangesType
        )
        XCTAssertFalse(
            coordinator.acceptDrop(DraggingInfoFake(pasteboard: staleRowsPasteboard), in: fileList.stagedTable),
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
        coordinator.toggleStaging(for: fileList.unstagedTable)
        waitForIndexUpdate { coordinator.didDoubleClick(fileList.stagedTable) }
        XCTAssertEqual(fileList.stagedFileCount, 0, "double-clicking staged rows unstages them")
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
            dataSource.tableView?(
                table,
                validateDrop: DraggingInfoFake(pasteboard: pasteboard),
                proposedRow: targetRow,
                proposedDropOperation: .above
            ) ?? []
        }
        func accept(_ pasteboard: NSPasteboard, targetRow: Int) -> Bool {
            dataSource.tableView?(
                table,
                acceptDrop: DraggingInfoFake(pasteboard: pasteboard),
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
        XCTAssertEqual(encoded.first?["path"] as? String, "partial.txt")
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
                ["path": "unstaged-only.txt", "sourceSection": PBStagingListSection.staged.rawValue],
                ["path": "staged-only.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
                ["path": "staged-only.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
                ["path": "stale.txt", "sourceSection": PBStagingListSection.unstaged.rawValue],
            ],
            forType: dragType
        )
        XCTAssertEqual(validate(mixedPasteboard, targetRow: 0), .copy)
        waitForIndexUpdate {
            XCTAssertTrue(accept(mixedPasteboard, targetRow: 0))
        }
        XCTAssertFalse(try fixture.git(["ls-files", "--stage", "--", "staged-only.txt"]).isEmpty)

        for (name, propertyList) in [
            ("Empty", [] as [[String: Any]]),
            ("Malformed", [["path": "partial.txt", "sourceSection": 0, "extra": true]]),
        ] {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitXSectioned\(name)"))
            pasteboard.clearContents()
            pasteboard.declareTypes([dragType], owner: nil)
            pasteboard.setPropertyList(propertyList, forType: dragType)
            XCTAssertEqual(validate(pasteboard, targetRow: 0), [])
            XCTAssertFalse(accept(pasteboard, targetRow: 0))
        }
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
        pumpRunLoop(for: 0.5)
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

    func testStagingPaneMenusFileActionsAndViewOptions() throws {
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

        let dragPasteboard = NSPasteboard(name: NSPasteboard.Name("GitXStagingMessageDrag"))
        dragPasteboard.clearContents()
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        dragPasteboard.declareTypes([filenamesType], owner: nil)
        let workingDirectory = repository.workingDirectory() ?? fixture.path
        dragPasteboard.setPropertyList(
            [(workingDirectory as NSString).appendingPathComponent("staged.txt")],
            forType: filenamesType
        )
        pane.commitMessageView.string = ""
        _ = pane.commitMessageView.performDragOperation(DraggingInfoFake(pasteboard: dragPasteboard))
        let rewritten = dragPasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String]
        XCTAssertEqual(
            rewritten,
            ["staged.txt"],
            "dropped files are rewritten to repository-relative paths"
        )

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

        let amendItem = NSMenuItem(title: "Amend", action: NSSelectorFromString("toggleAmendCommit:"), keyEquivalent: "")
        _ = stub.validateMenuItem(amendItem)
        let uncommittedItem = NSMenuItem(title: "Uncommitted", action: NSSelectorFromString("showUncommittedChanges:"), keyEquivalent: "")
        _ = stub.validateMenuItem(uncommittedItem)
        let historyItem = NSMenuItem(title: "History", action: NSSelectorFromString("showHistoryView:"), keyEquivalent: "")
        _ = stub.validateMenuItem(historyItem)

        XCTAssertFalse(PBGitBinary.searchLocations().isEmpty)
        XCTAssertNotNil(PBGitBinary.version())
        XCTAssertFalse(PBGitBinary.notFoundError().isEmpty)
        let directoryTask = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: fixture.path)
        try directoryTask.launch()

        let slowTask = PBTask(launchPath: "/bin/sleep", arguments: ["30"], inDirectory: nil)
        let cancelled = expectation(description: "terminated task reports an error")
        slowTask.perform(on: DispatchQueue.global(qos: .userInitiated)) { _, error in
            XCTAssertNotNil(error, "terminating a running task surfaces an error")
            cancelled.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        slowTask.terminate()
        wait(for: [cancelled], timeout: 10)

        let webController = historyController.value(forKey: "webHistoryController") as? NSObject
        webController?.perform(NSSelectorFromString("refreshDisplayedContent"))
        pumpRunLoop()
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
        pumpRunLoop(for: 0.5)
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
        pumpRunLoop(for: 0.5)
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
        XCTAssertTrue(singlePaths.allSatisfy { ($0 as! NSMenuItem).representedObject != nil })
        let featurePathItems = try XCTUnwrap(singlePaths as? [NSMenuItem])
        let featureDiff = try XCTUnwrap(featurePathItems.first { $0.action == NSSelectorFromString("diffFilesAction:") })
        let featureCheckout = try XCTUnwrap(featurePathItems.first { $0.action == NSSelectorFromString("checkoutFiles:") })
        XCTAssertTrue(featureDiff.isEnabled)
        XCTAssertTrue(featureCheckout.isEnabled)
        XCTAssertEqual(featureDiff.representedObject as? [String], ["nested/tracked.txt"])

        historyController.selectedCommits = [headCommit]
        let headPathItems = try XCTUnwrap(historyController.menuItems(forPaths: ["nested/tracked.txt"]) as? [NSMenuItem])
        let headDiff = try XCTUnwrap(headPathItems.first { $0.title.hasPrefix("Diff file") })
        let headCheckout = try XCTUnwrap(headPathItems.first { $0.action == NSSelectorFromString("checkoutFiles:") })
        XCTAssertFalse(headDiff.isEnabled)
        XCTAssertNil(headDiff.action)
        XCTAssertTrue(headCheckout.isEnabled)

        let multiplePaths = historyController.menuItems(forPaths: ["one", "two"])
        XCTAssertTrue(try XCTUnwrap((multiplePaths[0] as? NSMenuItem)?.title.contains("files")))
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

        let items = try XCTUnwrap(historyController.menuItems(forPaths: ["nested/tracked.txt"]) as? [NSMenuItem])
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

    func testTablePasteboardDropCheckoutAndResponderInteractions() throws {
        repository.reloadRefs()
        let commits = loadedCommits()
        let featureRef = try XCTUnwrap(repository.ref(forName: "feature"))
        let sourceCommit = try XCTUnwrap(commits.first { commit in
            commit.refs.compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: featureRef) }
        })
        let destinationCommit = try XCTUnwrap(commits.first { $0 !== sourceCommit })
        historyController.commitController.content = [sourceCommit, destinationCommit]
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let sourceRow = try XCTUnwrap(arranged.firstIndex { $0 === sourceCommit })
        let destinationRow = try XCTUnwrap(arranged.firstIndex { $0 === destinationCommit })
        let featureIndex = try XCTUnwrap(sourceCommit.refs.compactMap { $0 as? PBGitRef }
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
        XCTAssertTrue(destinationCommit.refs.compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: featureRef) })

        let missingRef = PBGitRef(string: "refs/heads/history-tests-missing")
        destinationCommit.addRef(missingRef)
        table.testRow = destinationRow
        table.revisionCell.referenceIndex = try Int32(XCTUnwrap(
            destinationCommit.refs.compactMap { $0 as? PBGitRef }
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
                commit.refs.compactMap { $0 as? PBGitRef }.contains { $0.isEqual(to: ref) }
            })
            let referenceIndex = try XCTUnwrap(
                arranged[row].refs.compactMap { $0 as? PBGitRef }.firstIndex { $0.isEqual(to: ref) }
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
        drag.sourceCommit.refs.insert(PBGitRef(string: "refs/tags/reordered-label"), at: 0)
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
            drag.destinationCommit.refs.compactMap { $0 as? PBGitRef }
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
            drag.sourceCommit.refs.compactMap { $0 as? PBGitRef }
                .contains { $0.ref == "refs/heads/feature" }
        )
        XCTAssertFalse(
            drag.destinationCommit.refs.compactMap { $0 as? PBGitRef }
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
            commit.refs.compactMap { $0 as? PBGitRef }.contains { $0.ref == feature.ref }
        })
        let destinationCommit = try XCTUnwrap(commits.first { $0.sha != sourceCommit.sha })
        historyController.commitController.content = [sourceCommit, destinationCommit]
        historyController.commitController.sortDescriptors = []
        historyController.commitController.rearrangeObjects()
        let arranged = try XCTUnwrap(historyController.commitController.arrangedObjects as? [PBGitCommit])
        let sourceRow = try XCTUnwrap(arranged.firstIndex { $0 === sourceCommit })
        let destinationRow = try XCTUnwrap(arranged.firstIndex { $0 === destinationCommit })
        let referenceIndex = try XCTUnwrap(
            sourceCommit.refs.compactMap { $0 as? PBGitRef }.firstIndex { $0.ref == feature.ref }
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
