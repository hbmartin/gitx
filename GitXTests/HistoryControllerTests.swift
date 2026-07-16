import AppKit
import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test case lifetime, while every mutable access is confined to the main actor.
final class HistoryControllerTests: XCTestCase, @unchecked Sendable {
    private final class HistoryWindowController: PBGitWindowController {
        private var fixedRepository: PBGitRepository!
        private(set) var shownErrors: [NSError] = []
        private(set) var confirmationCount = 0

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
            actionBlock()
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
        historyController.gitTree = commits[0].tree
        historyController.selectedCommitDetailsIndex = 1
        pumpRunLoop()
        if let leafNode = firstLeafNode(in: historyController.treeController.arrangedObjects) {
            historyController.treeController.setSelectionIndexPath(leafNode.indexPath)
            (historyController.value(forKey: "fileView") as? NSObject)?
                .perform(NSSelectorFromString("showFile"))
            (historyController.value(forKey: "fileView") as? NSObject)?
                .perform(NSSelectorFromString("modeChanged:"), with: NSSegmentedControl())
            pumpRunLoop(for: 0.5)
            historyController.saveFileBrowserSelection()
            historyController.treeController.setSelectionIndexPaths([])
            historyController.restoreFileBrowserSelection()
            XCTAssertFalse(historyController.treeController.selectionIndexPaths.isEmpty)
        }

        try fixture.write("working state\n", to: "uncommitted.txt")
        refreshIndex()
        historyController.updateUncommittedChanges()
        let workingState = historyController.commitController.value(forKey: "pinnedObject") as? PBUncommittedChanges
        XCTAssertNotNil(workingState)
        XCTAssertTrue(workingState?.isWorkingState == true)
        try historyController.commitController.setSelectedObjects([XCTUnwrap(workingState)])
        historyController.updateKeys()
        let proposed = IndexSet(integersIn: 0 ... 1)
        XCTAssertEqual(
            tableCoordinator.tableView(historyController.commitList, selectionIndexesForProposedSelection: proposed),
            IndexSet(integer: 0)
        )

        try fixture.git(["clean", "-fd"])
        refreshIndex()
        historyController.updateUncommittedChanges()
        XCTAssertNil(historyController.commitController.value(forKey: "pinnedObject"))
        XCTAssertFalse(historyController.commitController.selectedObjects.isEmpty)
        historyController.updateStatus()
        XCTAssertTrue(historyController.status.contains("commits loaded"))
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
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: head), contains: ["Checkout", "Create Branch", "Fetch", "Push"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: feature), contains: ["Checkout", "Merge", "Rebase", "Reset"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: tag), contains: ["View Tag Info", "Push"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: remoteBranch), contains: ["Push Updates", "Fetch", "Pull"])
        assertMenu(menuItems(selector: "menuItemsForRef:", argument: remote), contains: ["Push Updates", "Fetch", "Pull"])

        let commits = loadedCommits()
        let headCommit = try XCTUnwrap(commits.first { $0.oid == repository.headOID() })
        let featureCommit = try XCTUnwrap(commits.first { !$0.isOnHeadBranch() })
        assertMenu(menuItems(selector: "menuItemsForCommits:", argument: [headCommit]), contains: ["Checkout Commit", "Copy SHA", "Reset"])
        assertMenu(menuItems(selector: "menuItemsForCommits:", argument: [featureCommit]), contains: ["Merge Commit", "Cherry Pick", "Rebase"])
        let multiple = try XCTUnwrap(menuItems(selector: "menuItemsForCommits:", argument: [headCommit, featureCommit]))
        XCTAssertEqual(multiple.filter { $0.title == "Copy SHA" }.count, 1)
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

    private func loadedCommits() -> [PBGitCommit] {
        waitForHistory()
        return repository.revisionList?.commits.compactMap { $0 as? PBGitCommit } ?? []
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
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titles = items?.map(\.title) ?? []
        for fragment in fragments {
            XCTAssertTrue(titles.contains { $0.contains(fragment) }, "Missing \(fragment) in \(titles)", file: file, line: line)
        }
        XCTAssertTrue(items?.allSatisfy { $0.isSeparatorItem || $0.representedObject != nil } == true, file: file, line: line)
    }
}
