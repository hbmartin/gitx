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
        var automaticallyConfirms = true

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

        override func confirmDialog(
            _ alert: NSAlert,
            suppressionIdentifier identifier: String?,
            forAction actionBlock: @escaping () -> Void
        ) -> Bool {
            confirmationCount += 1
            if automaticallyConfirms {
                actionBlock()
            }
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
        XCTAssertFalse(historyController.status.isEmpty)
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
        XCTAssertTrue(nativeView.textView.string.contains("new file mode"))
        try historyController.commitController.setSelectedObjects([XCTUnwrap(workingState)])
        historyController.updateKeys()
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
        XCTAssertTrue(historyController.status.contains("commits loaded"))
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

    func testWorkingStateDiffRefreshesInBackgroundAndReusesCachedRendering() throws {
        try fixture.write("cached working state\n", to: "cached.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()
        let workingState = try XCTUnwrap(
            historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        )
        let webController = try XCTUnwrap(
            historyController.value(forKey: "webHistoryController") as? NSObject
        )
        let nativeView = try XCTUnwrap(webController.value(forKey: "nativeView") as? PBNativeContentView)
        let changeContent = NSSelectorFromString("changeContentTo:")

        _ = webController.perform(changeContent, with: [workingState])
        XCTAssertTrue(waitForCondition {
            (webController.value(forKey: "diff") as? String)?.contains("+cached working state") == true &&
                nativeView.textView.string.contains("cached working state")
        })

        nativeView.showMessage("Cache sentinel")
        _ = webController.perform(changeContent, with: [workingState])
        XCTAssertTrue(
            nativeView.textView.string.contains("cached working state"),
            "A repeat Working State selection should synchronously restore its memory cache"
        )
        pumpRunLoop(for: 0.5)

        try fixture.write("refreshed working state\n", to: "cached.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()
        let refreshedWorkingState = try XCTUnwrap(
            historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        )
        _ = webController.perform(changeContent, with: [refreshedWorkingState])
        XCTAssertTrue(waitForCondition {
            (webController.value(forKey: "diff") as? String)?.contains("+refreshed working state") == true &&
                nativeView.textView.string.contains("refreshed working state")
        })
    }

    func testReferenceCommitStashAndPathMenuMatrices() throws {
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

    private func loadedCommits() -> [PBGitCommit] {
        waitForHistory()
        return repository.revisionList?.commits.compactMap { $0 as? PBGitCommit } ?? []
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
