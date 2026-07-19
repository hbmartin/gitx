import AppKit
import XCTest

@MainActor
final class GitXSwiftFeatureTests: XCTestCase {
    private final class TreeFixture: NSObject {
        @objc dynamic let fullPath: String
        @objc dynamic let path: String
        @objc dynamic let children: [TreeFixture]?

        init(fullPath: String, path: String, children: [TreeFixture]? = nil) {
            self.fullPath = fullPath
            self.path = path
            self.children = children
        }
    }

    private func preservePersistentDefault(forKey key: String) -> () -> Void {
        let defaults = UserDefaults.standard
        let originalValue = Bundle.main.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0)?[key] }
        return {
            if let originalValue {
                defaults.set(originalValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func testCommitRenderInputFreezesPlainMetadataAndImageRevisions() {
        let input = PBCommitRenderInput(
            sha: "abcdef0123456789",
            parentSHA: "1234567890abcdef",
            shortName: "abcdef0",
            subject: "Render safely",
            author: "Ada",
            authorDate: "Today"
        )

        XCTAssertEqual(input.sha, "abcdef0123456789")
        XCTAssertEqual(input.parentSHA, "1234567890abcdef")
        XCTAssertEqual(input.shortName, "abcdef0")
        XCTAssertEqual(input.title, "abcdef0  Render safely\nAda — Today")
        XCTAssertEqual(input.imageRevisions, ["abcdef0123456789", "1234567890abcdef"])
    }

    func testCommitRenderInputOmitsMissingRootParentFromImageRevisions() {
        let input = PBCommitRenderInput(
            sha: "abcdef0123456789",
            parentSHA: nil,
            shortName: "abcdef0",
            subject: "Root",
            author: "Ada",
            authorDate: "Today"
        )

        XCTAssertEqual(input.imageRevisions, ["abcdef0123456789"])
    }

    func testImageRevisionPolicyFallsBackFromCommitToParent() {
        XCTAssertEqual(
            PBImageRevisionPolicy.revisions(
                commitSHA: "abcdef0123456789",
                parentSHA: "1234567890abcdef",
                workingState: false
            ),
            ["abcdef0123456789", "1234567890abcdef"]
        )
    }

    func testImageRevisionPolicyOmitsUnavailableRepositoryObjects() {
        XCTAssertEqual(
            PBImageRevisionPolicy.revisions(
                commitSHA: "abcdef0123456789",
                parentSHA: nil,
                workingState: false
            ),
            ["abcdef0123456789"]
        )
        XCTAssertEqual(
            PBImageRevisionPolicy.revisions(
                commitSHA: "abcdef0123456789",
                parentSHA: "1234567890abcdef",
                workingState: true
            ),
            []
        )
        XCTAssertEqual(
            PBImageRevisionPolicy.revisions(
                commitSHA: "",
                parentSHA: "1234567890abcdef",
                workingState: false
            ),
            []
        )
    }

    func testWorkingStateRefreshPolicyPreservesAnEqualDisplayedDiff() {
        XCTAssertFalse(PBWorkingStateRefreshPolicy.shouldReplaceDisplayedDiff("same", renderedDiff: "same"))
        XCTAssertTrue(PBWorkingStateRefreshPolicy.shouldReplaceDisplayedDiff(nil, renderedDiff: "same"))
        XCTAssertTrue(PBWorkingStateRefreshPolicy.shouldReplaceDisplayedDiff("old", renderedDiff: "new"))
    }

    func testWorkingStateDiffCacheIsMemoryAndLayoutScoped() {
        let cache = PBWorkingStateDiffCache()
        let sections = [["title": "Unstaged Changes", "text": "cached"]]

        XCTAssertNil(cache.snapshot(forLayout: 0))
        cache.store(sections: sections, renderedDiff: "cached", layout: 0)
        XCTAssertEqual(cache.snapshot(forLayout: 0)?.renderedDiff, "cached")
        XCTAssertEqual(cache.snapshot(forLayout: 0)?.sections.count, 1)
        XCTAssertNil(cache.snapshot(forLayout: 1))
        cache.removeAll()
        XCTAssertNil(cache.snapshot(forLayout: 0))
    }

    func testRecentRepositoryActivationRoutesMissingEntriesToLocate() {
        XCTAssertEqual(PBRecentRepositoryActivationPolicy.action(forReachable: true), .open)
        XCTAssertEqual(PBRecentRepositoryActivationPolicy.action(forReachable: false), .locate)
    }

    func testRecentRepositoryKeyNavigationMovesOneRowAtATime() {
        // Moving down advances exactly one row and stops at the last row.
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 5, movingDown: true), 1)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 3, rowCount: 5, movingDown: true), 4)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 4, rowCount: 5, movingDown: true), 4)

        // Moving up retreats exactly one row — regression guard against the double-decrement that skipped a row.
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 3, rowCount: 5, movingDown: false), 2)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 1, rowCount: 5, movingDown: false), 0)
    }

    func testRecentRepositoryKeyNavigationClampsAtTopRowWithoutUnderflow() {
        // Regression guard: pressing Up on the first row must clamp to 0, not underflow NSUInteger and crash.
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 5, movingDown: false), 0)
        // A not-found selection bridges from NSNotFound to -1; it must be treated as the nearest valid row.
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: -1, rowCount: 5, movingDown: false), 0)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: -1, rowCount: 5, movingDown: true), 1)
    }

    func testRecentRepositoryKeyNavigationReportsNoSelectableRowWhenEmpty() {
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 0, movingDown: true), -1)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 0, movingDown: false), -1)
        // Single-row list: both directions stay put.
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 1, movingDown: true), 0)
        XCTAssertEqual(PBRecentRepositoryKeyNavigation.nextRow(fromRow: 0, rowCount: 1, movingDown: false), 0)
    }

    func testRewindOverlayUsesOneLayerBackedSurface() throws {
        let overlay = PBRewindOverlayView(frame: NSRect(x: 0, y: 0, width: 125, height: 125))

        XCTAssertFalse(overlay.isKind(of: NSBox.self))
        let layer = try XCTUnwrap(overlay.layer)
        XCTAssertEqual(layer.borderWidth, 1)
        XCTAssertEqual(layer.cornerRadius, 12)
        XCTAssertNotNil(layer.backgroundColor)
        XCTAssertNotNil(layer.borderColor)
    }

    func testRepositoryToolbarInsertedStatusItemReceivesLiveUpdates() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowController = PBGitWindowController(window: window)
        let toolbarController = PBRepositoryToolbarController(windowController: windowController)
        let toolbar = NSToolbar(identifier: "GitX.Repository.HistoryToolbar")
        let item = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.RefreshStatus"),
            willBeInsertedIntoToolbar: true
        ))
        let stack = try XCTUnwrap(item.view as? NSStackView)
        let labels: [NSTextField] = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
        let spinners: [NSProgressIndicator] = stack.arrangedSubviews.compactMap { $0 as? NSProgressIndicator }
        let label = try XCTUnwrap(labels.first)
        let spinner = try XCTUnwrap(spinners.first)

        toolbarController.update(
            withStatus: "Fetching updates",
            busy: true,
            baseWindowTitle: "Repository"
        )

        XCTAssertEqual(label.stringValue, "Fetching updates")
        XCTAssertFalse(spinner.isHidden)
        XCTAssertEqual(window.title, "Repository — Fetching updates")
    }

    func testRepositoryToolbarPaletteStatusItemDoesNotReplaceInsertedStatusViews() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowController = PBGitWindowController(window: window)
        let toolbarController = PBRepositoryToolbarController(windowController: windowController)
        let toolbar = NSToolbar(identifier: "GitX.Repository.HistoryToolbar")
        let identifier = NSToolbarItem.Identifier("GitX.Toolbar.RefreshStatus")
        let insertedItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: true
        ))
        let insertedStack = try XCTUnwrap(insertedItem.view as? NSStackView)
        let insertedLabels: [NSTextField] = insertedStack.arrangedSubviews.compactMap { $0 as? NSTextField }
        let insertedLabel = try XCTUnwrap(insertedLabels.first)
        let paletteItem = try XCTUnwrap(toolbarController.toolbar(
            toolbar,
            itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: false
        ))
        let paletteStack = try XCTUnwrap(paletteItem.view as? NSStackView)
        let paletteLabels: [NSTextField] = paletteStack.arrangedSubviews.compactMap { $0 as? NSTextField }
        let paletteLabel = try XCTUnwrap(paletteLabels.first)

        toolbarController.update(
            withStatus: "Fetching updates",
            busy: false,
            baseWindowTitle: "Repository"
        )

        XCTAssertEqual(insertedLabel.stringValue, "Fetching updates")
        XCTAssertEqual(paletteLabel.stringValue, "Ready")

        insertedStack.frame = NSRect(origin: .zero, size: insertedStack.fittingSize)
        insertedStack.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            insertedStack.bitmapImageRepForCachingDisplay(in: insertedStack.bounds)
        )
        insertedStack.cacheDisplay(in: insertedStack.bounds, to: representation)
        let screenshot = NSImage(size: insertedStack.bounds.size)
        screenshot.addRepresentation(representation)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Active repository status after toolbar palette request"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func largeDiff(
        lineCount: Int,
        path: String = "Large.swift",
        startingAt firstIndex: Int = 0
    ) -> String {
        var diff = """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -1,\(lineCount) +1,\(lineCount) @@

        """
        for index in firstIndex ..< firstIndex + lineCount {
            diff += "-let oldValue\(index) = \(index)\n"
            diff += "+let newValue\(index) = \(index + 1)\n"
        }
        return diff
    }

    private func waitForDiff(_ tail: String, in view: PBNativeContentView) {
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in view.textView.string.contains(tail) },
            object: view.textView
        )
        wait(for: [rendered], timeout: 10)
    }

    private func assertLightweightColoring(
        of lineText: String,
        in view: PBNativeContentView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let storage = try XCTUnwrap(view.textView.textStorage, file: file, line: line)
        let range = try XCTUnwrap(storage.string.range(of: lineText), file: file, line: line)
        let lineRange = NSRange(range, in: storage.string)
        let prefixColor = storage.attribute(
            .foregroundColor,
            at: lineRange.location,
            effectiveRange: nil
        ) as? NSColor
        let bodyColor = storage.attribute(
            .foregroundColor,
            at: lineRange.location + 1,
            effectiveRange: nil
        ) as? NSColor

        XCTAssertEqual(prefixColor, bodyColor, file: file, line: line)
        XCTAssertNotNil(
            storage.attribute(.backgroundColor, at: lineRange.location + 1, effectiveRange: nil),
            file: file,
            line: line
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testRepositoryBridgePreservesInitializationAndPathMetadata() throws {
        try withTemporaryDirectory { repositoryURL in
            try runGit(["init", "--quiet", "--initial-branch=main"], in: repositoryURL)
            try runGit(["config", "user.name", "GitX Test"], in: repositoryURL)
            try runGit(["config", "user.email", "gitx-tests@example.invalid"], in: repositoryURL)
            try "tracked\n".write(
                to: repositoryURL.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "--all"], in: repositoryURL)
            try runGit(["commit", "--quiet", "-m", "initial"], in: repositoryURL)

            let repository = try PBGitRepository(url: repositoryURL)

            XCTAssertEqual(
                repository.workingDirectory().map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                },
                repositoryURL.resolvingSymlinksInPath().path
            )
            XCTAssertEqual(repository.projectName(), repositoryURL.lastPathComponent)
            XCTAssertEqual(repository.indexURL?.lastPathComponent, "index")
            XCTAssertEqual(repository.headRef()?.ref()?.branchName, "main")
            XCTAssertTrue(repository.revisionExists("HEAD"))
            XCTAssertFalse(repository.hasRemotes())
        }
    }

    func testLanguageNameClassification() {
        XCTAssertEqual(PBHighlighting.languageName(forPath: "Dockerfile"), "dockerfile")
        XCTAssertEqual(PBHighlighting.languageName(forPath: "GNUmakefile"), "makefile")
        XCTAssertEqual(PBHighlighting.languageName(forPath: "Sources/EXAMPLE.SWIFT"), "swift")
        XCTAssertNil(PBHighlighting.languageName(forPath: "archive.unknown"))
    }

    func testRelativeDateFormatterHandlesCommonRanges() {
        let formatter = GitXRelativeDateFormatter()
        let now = Date()

        XCTAssertNil(formatter.string(for: "not a date"))
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(3600)), "In the future!")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-10)), "seconds ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-80)), "1 minute ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-600)), "10 minutes ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-5400)), "1 hour ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-10800)), "3 hours ago")
    }

    func testAutoFetchScopeSetterStoresAValidatedValue() throws {
        let restoreDefault = preservePersistentDefault(forKey: "PBAutoFetchScope")
        defer { restoreDefault() }
        let invalidScope = try XCTUnwrap(PBAutoFetchScope(rawValue: .max))
        PBGitDefaults.setAutoFetchScope(invalidScope)

        XCTAssertEqual(UserDefaults.standard.integer(forKey: "PBAutoFetchScope"), PBAutoFetchScope.none.rawValue)
        XCTAssertEqual(PBGitDefaults.autoFetchScope(), .none)
    }

    func testRepositoryNotificationDefaultsTreatSymlinksAsTheSameRepository() throws {
        let restoreDefault = preservePersistentDefault(forKey: "PBAutoFetchRepositoryNotifications")
        defer { restoreDefault() }
        try withTemporaryDirectory { root in
            let repository = root.appendingPathComponent("repository", isDirectory: true)
            let symlink = root.appendingPathComponent("repository-link", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: repository)

            PBGitDefaults.setNotifyAboutFetchedCommits(false, forRepositoryURL: repository)
            PBGitDefaults.setNotifyAboutFetchedCommits(false, forRepositoryURL: symlink)

            PBGitDefaults.setNotifyAboutFetchedCommits(true, forRepositoryURL: symlink)

            XCTAssertTrue(PBGitDefaults.notifyAboutFetchedCommits(forRepositoryURL: repository))
        }
    }

    func testRepositoryFinderDiscoversWorktreesNestedPathsAndBareRepositories() throws {
        try withTemporaryDirectory { root in
            let worktree = root.appendingPathComponent("unicode-ü", isDirectory: true)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try runGit(["init", "--quiet"], in: worktree)

            let nested = worktree.appendingPathComponent("Sources/Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let expectedWorktree = worktree.standardizedFileURL
            let expectedGitDirectory = worktree.appendingPathComponent(".git", isDirectory: true).standardizedFileURL

            XCTAssertEqual(PBRepositoryFinder.workDir(for: nested)?.standardizedFileURL, expectedWorktree)
            XCTAssertEqual(PBRepositoryFinder.gitDir(for: nested)?.standardizedFileURL, expectedGitDirectory)
            XCTAssertEqual(PBRepositoryFinder.fileURL(for: nested)?.standardizedFileURL, expectedWorktree)

            let bare = root.appendingPathComponent("bare.git", isDirectory: true)
            try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            try runGit(["init", "--bare", "--quiet"], in: bare)
            XCTAssertNil(PBRepositoryFinder.workDir(for: bare))
            XCTAssertEqual(PBRepositoryFinder.gitDir(for: bare)?.standardizedFileURL, bare.standardizedFileURL)
            XCTAssertEqual(PBRepositoryFinder.fileURL(for: bare)?.standardizedFileURL, bare.standardizedFileURL)
        }
    }

    func testRepositoryFinderRejectsNonRepositoriesAndNonFileURLs() throws {
        try withTemporaryDirectory { directory in
            XCTAssertNil(PBRepositoryFinder.workDir(for: directory))
            XCTAssertNil(PBRepositoryFinder.gitDir(for: directory))
            XCTAssertNil(PBRepositoryFinder.fileURL(for: directory))
        }

        let webURL = try XCTUnwrap(URL(string: "https://example.invalid/repository"))
        XCTAssertNil(PBRepositoryFinder.workDir(for: webURL))
        XCTAssertNil(PBRepositoryFinder.gitDir(for: webURL))
        XCTAssertNil(PBRepositoryFinder.fileURL(for: webURL))
    }

    func testCommandLineToolDoesNotCrashWhenLibgitRejectsRepositoryFormat() throws {
        try withTemporaryDirectory { worktree in
            try runGit(["init", "--quiet"], in: worktree)
            try runGit(["config", "core.repositoryformatversion", "1"], in: worktree)

            XCTAssertNil(PBRepositoryFinder.workDir(for: worktree))
            XCTAssertNil(PBRepositoryFinder.fileURL(for: worktree))

            let cliURL = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
            let process = Process()
            process.executableURL = cliURL
            process.currentDirectoryURL = worktree
            process.arguments = []
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = worktree.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testTaskAppliesCallerEnvironmentOverridesAtLaunch() {
        let task = PBTask(launchPath: "/usr/bin/env", arguments: [], inDirectory: nil)
        task.additionalEnvironment = ["GITX_ENVIRONMENT_OVERRIDE": "configured-after-initialization"]
        let completed = expectation(description: "environment task completed")

        task.perform(on: .main) { data, error in
            XCTAssertNil(error)
            let output = data.flatMap { String(data: $0, encoding: .utf8) }
            XCTAssertTrue(output?.contains(
                "GITX_ENVIRONMENT_OVERRIDE=configured-after-initialization"
            ) == true)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
    }

    func testProcessEnvironmentPreservesPathOrderAndDeduplicatesEntries() {
        let prepared = PBProcessEnvironment.preparedEnvironment(
            [
                "PATH": "/custom/bin:/usr/bin:/custom/bin",
                "KEEP": "yes",
            ],
            homeDirectory: "/Users/example"
        )

        XCTAssertEqual(prepared["KEEP"], "yes")
        XCTAssertEqual(pathEntries(in: prepared), [
            "/custom/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/sw/bin",
            "/Users/example/.local/bin",
            "/Users/example/bin",
        ])
    }

    func testProcessEnvironmentBuildsPathWhenMissingOrEmpty() {
        let expected = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/sw/bin",
            "/Users/example/.local/bin",
            "/Users/example/bin",
        ]

        XCTAssertEqual(
            pathEntries(in: PBProcessEnvironment.preparedEnvironment(
                [:],
                homeDirectory: "/Users/example"
            )),
            expected
        )
        XCTAssertEqual(
            pathEntries(in: PBProcessEnvironment.preparedEnvironment(
                ["PATH": ""],
                homeDirectory: "/Users/example"
            )),
            expected
        )
    }

    func testProcessEnvironmentExpandsAndDeduplicatesHomeDirectories() {
        let prepared = PBProcessEnvironment.preparedEnvironment(
            ["PATH": "/Users/example/bin::/Users/example/.local/bin:/Users/example/bin"],
            homeDirectory: "/Users/example"
        )
        let entries = pathEntries(in: prepared)

        XCTAssertEqual(entries.first, "/Users/example/bin")
        XCTAssertEqual(entries.filter { $0 == "/Users/example/bin" }.count, 1)
        XCTAssertEqual(entries.filter { $0 == "/Users/example/.local/bin" }.count, 1)
        XCTAssertFalse(entries.contains(""))
    }

    private func pathEntries(in environment: [String: String]) -> [String] {
        environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    }

    func testReferenceActionPolicyAllowsBranchesAndTagsToPush() {
        XCTAssertTrue(PBReferenceActionPolicy.canPush(refishType: "branch"))
        XCTAssertTrue(PBReferenceActionPolicy.canPush(refishType: "tag"))
        XCTAssertFalse(PBReferenceActionPolicy.canPush(refishType: "remote branch"))
    }

    func testReferenceActionPolicyAllowsRemoteTrackingBranchRemoval() {
        XCTAssertTrue(PBReferenceActionPolicy.canDelete(refishType: "branch"))
        XCTAssertTrue(PBReferenceActionPolicy.canDelete(refishType: "remote"))
        XCTAssertTrue(PBReferenceActionPolicy.canDelete(refishType: "tag"))
        XCTAssertTrue(PBReferenceActionPolicy.canDelete(refishType: "remote branch"))
    }

    func testReferenceActionPolicyDistinguishesDeleteFromLocalRemoval() {
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionMenuTitle(refName: "origin/topic", isRemote: true),
            "Remove “origin/topic”…"
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionMenuTitle(refName: "topic", isRemote: false),
            "Delete “topic”…"
        )
    }

    func testRemoteTrackingBranchConfirmationExplainsLocalRemoval() {
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationTitle(
                refishType: "remote branch",
                shortName: "origin/topic"
            ),
            "Remove remote branch 'origin/topic'?"
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationMessage(
                refishType: "remote branch",
                shortName: "origin/topic"
            ),
            "This removes only the local remote-tracking branch. "
                + "The branch on the remote server is left unchanged."
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationButtonTitle(refishType: "remote branch"),
            "Remove"
        )
    }

    func testRemoteConfigurationConfirmationUsesRemovalTerminology() {
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationTitle(
                refishType: "remote",
                shortName: "origin"
            ),
            "Remove remote 'origin'?"
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationMessage(
                refishType: "remote",
                shortName: "origin"
            ),
            "This removes the remote configuration and its local remote-tracking branches. "
                + "Branches on the remote server are left unchanged."
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationButtonTitle(refishType: "remote"),
            "Remove"
        )
    }

    func testLocalBranchConfirmationUsesDeletionTerminology() {
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationTitle(
                refishType: "branch",
                shortName: "topic"
            ),
            "Delete branch 'topic'?"
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationMessage(
                refishType: "branch",
                shortName: "topic"
            ),
            "Are you sure you want to delete the branch 'topic'?"
        )
        XCTAssertEqual(
            PBReferenceActionPolicy.deletionConfirmationButtonTitle(refishType: "branch"),
            "Delete"
        )
    }

    func testRemoteSidebarSyncAddsConfiguredOnlyRemote() {
        let plan = PBRemoteSidebarSyncPlan.plan(
            configuredRemoteNames: ["origin"],
            existingRemoteNames: [],
            nonEmptyRemoteNames: []
        )

        XCTAssertEqual(plan.namesToAdd, ["origin"])
        XCTAssertEqual(plan.namesToRemove, [])
    }

    func testRemoteSidebarSyncPreservesTrackingOnlyRemote() {
        let plan = PBRemoteSidebarSyncPlan.plan(
            configuredRemoteNames: [],
            existingRemoteNames: ["archived"],
            nonEmptyRemoteNames: ["archived"]
        )

        XCTAssertEqual(plan.namesToAdd, [])
        XCTAssertEqual(plan.namesToRemove, [])
    }

    func testRemoteSidebarSyncRemovesOnlyEmptyUnconfiguredRemotes() {
        let plan = PBRemoteSidebarSyncPlan.plan(
            configuredRemoteNames: ["zulu", "alpha", "origin", "zulu"],
            existingRemoteNames: ["upstream", "origin", "stale", "unused"],
            nonEmptyRemoteNames: ["upstream"]
        )

        XCTAssertEqual(plan.namesToAdd, ["alpha", "zulu"])
        XCTAssertEqual(plan.namesToRemove, ["stale", "unused"])
    }

    func testLargeNativeDiffProducesScrollableDocument() throws {
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.layoutSubtreeIfNeeded()
        let diff = largeDiff(lineCount: 600)

        view.showDiffSections([
            [
                PBNativeSectionTextKey: diff,
                PBNativeSectionPathKey: "Large.swift",
                PBNativeSectionContextKey: "readOnly",
            ],
        ])
        waitForDiff("+let newValue599 = 600", in: view)
        view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(view.textView.enclosingScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(documentView.frame.height, scrollView.contentView.bounds.height)

        let clipView = scrollView.contentView
        let maximumY = max(0, documentView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)

        XCTAssertGreaterThan(clipView.bounds.origin.y, 0)
        XCTAssertLessThanOrEqual(clipView.bounds.origin.y, maximumY)
    }

    func testLargeNativeDiffUsesLightweightColoring() throws {
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let diff = largeDiff(lineCount: 4500)

        view.showDiffSections([
            [
                PBNativeSectionTextKey: diff,
                PBNativeSectionPathKey: "Large.swift",
                PBNativeSectionContextKey: "readOnly",
            ],
        ])
        waitForDiff("+let newValue4499 = 4500", in: view)
        try assertLightweightColoring(of: "+let newValue4499 = 4500", in: view)
    }

    func testCombinedLargeNativeDiffUsesLightweightColoring() throws {
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let firstDiff = largeDiff(lineCount: 2500, path: "First.swift")
        let secondDiff = largeDiff(lineCount: 2500, path: "Second.swift", startingAt: 2500)
        let byteBudget = 200 * 1024

        XCTAssertLessThan(firstDiff.utf8.count, byteBudget)
        XCTAssertLessThan(secondDiff.utf8.count, byteBudget)
        XCTAssertGreaterThan(firstDiff.utf8.count + secondDiff.utf8.count, byteBudget)

        view.showDiffSections([
            [
                PBNativeSectionTextKey: firstDiff,
                PBNativeSectionPathKey: "First.swift",
                PBNativeSectionContextKey: "readOnly",
            ],
            [
                PBNativeSectionTextKey: secondDiff,
                PBNativeSectionPathKey: "Second.swift",
                PBNativeSectionContextKey: "readOnly",
            ],
        ])
        waitForDiff("+let newValue4999 = 5000", in: view)
        try assertLightweightColoring(of: "+let newValue2499 = 2500", in: view)
        try assertLightweightColoring(of: "+let newValue4999 = 5000", in: view)
    }

    func testDiffSyntaxHighlightingByteBudgetIncludesItsBoundary() {
        XCTAssertTrue(PBHighlighting.shouldHighlightDiff(withByteCount: 0))
        XCTAssertTrue(PBHighlighting.shouldHighlightDiff(withByteCount: 200 * 1024))
        XCTAssertFalse(PBHighlighting.shouldHighlightDiff(withByteCount: 200 * 1024 + 1))
    }

    func testApplicationSettingsRoundTripAndPaneActions() throws {
        let keys = [
            "PBOpenDisposition", "PBWindowRestorePolicy", "PBHistoryChangedFilesOnly",
            "PBHistoryChangedFilesSort", "PBHistoryGroupIncomingBranchCommits",
            "PBBranchSortMode", "PBDiffLayout",
            "PBDiffAlgorithm", "PBDiffContextLines", "PBSyntaxTheme", "PBDiffFontName",
            "PBDiffFontSize", "PBDiffAddedTextColor", "PBDiffRemovedTextColor",
            "PBDiffAddedBackgroundColor", "PBDiffRemovedBackgroundColor",
            "PBTerminalBundleIdentifier", "PBTerminalInitialCommand",
            "PBCustomTerminalExecutable", "PBCustomTerminalArguments",
            "PBRaycastScriptsDirectory", "PBPatchExportMode",
        ]
        let restorers = keys.map { preservePersistentDefault(forKey: $0) }
        defer { restorers.reversed().forEach { $0() } }

        UserDefaults.standard.removeObject(forKey: "PBHistoryGroupIncomingBranchCommits")
        XCTAssertTrue(PBApplicationSettings.groupIncomingBranchCommits)
        PBApplicationSettings.openDisposition = .preferTab
        PBApplicationSettings.restorePolicy = .never
        PBApplicationSettings.changedFilesOnly = false
        PBApplicationSettings.changedFilesSort = .status
        PBApplicationSettings.groupIncomingBranchCommits = false
        PBApplicationSettings.branchSort = .recentCommit
        PBApplicationSettings.diffLayout = .unified
        PBApplicationSettings.diffAlgorithm = .histogram
        PBApplicationSettings.diffContextLines = 50
        PBApplicationSettings.syntaxTheme = .github
        PBApplicationSettings.diffFontName = "Menlo"
        PBApplicationSettings.diffFontSize = 40
        PBApplicationSettings.addedTextColor = .systemGreen
        PBApplicationSettings.removedTextColor = .systemRed
        PBApplicationSettings.addedBackgroundColor = .systemMint
        PBApplicationSettings.removedBackgroundColor = .systemPink
        PBApplicationSettings.terminalBundleIdentifier = "custom"
        PBApplicationSettings.terminalInitialCommand = "git log -1"
        PBApplicationSettings.customTerminalExecutable = "/usr/bin/true"
        PBApplicationSettings.customTerminalArguments = "--working-directory {directory}"
        PBApplicationSettings.raycastScriptsDirectory = "/tmp/raycast"
        PBApplicationSettings.patchExportMode = 1

        XCTAssertEqual(PBApplicationSettings.openDisposition, .preferTab)
        XCTAssertEqual(PBApplicationSettings.restorePolicy, .never)
        XCTAssertFalse(PBApplicationSettings.changedFilesOnly)
        XCTAssertEqual(PBApplicationSettings.changedFilesSort, .status)
        XCTAssertFalse(PBApplicationSettings.groupIncomingBranchCommits)
        XCTAssertEqual(PBApplicationSettings.branchSort, .recentCommit)
        XCTAssertEqual(PBApplicationSettings.diffLayout, .unified)
        XCTAssertEqual(PBApplicationSettings.diffAlgorithm, .histogram)
        XCTAssertEqual(PBApplicationSettings.diffContextLines, 20)
        XCTAssertEqual(PBApplicationSettings.syntaxTheme, .github)
        XCTAssertEqual(PBApplicationSettings.diffFontName, "Menlo")
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 36)
        XCTAssertEqual(PBApplicationSettings.addedTextColor, .systemGreen)
        XCTAssertEqual(PBApplicationSettings.removedTextColor, .systemRed)
        XCTAssertEqual(PBApplicationSettings.addedBackgroundColor, .systemMint)
        XCTAssertEqual(PBApplicationSettings.removedBackgroundColor, .systemPink)
        XCTAssertEqual(PBApplicationSettings.terminalBundleIdentifier, "custom")
        XCTAssertEqual(PBApplicationSettings.terminalInitialCommand, "git log -1")
        XCTAssertEqual(PBApplicationSettings.customTerminalExecutable, "/usr/bin/true")
        XCTAssertEqual(PBApplicationSettings.customTerminalArguments, "--working-directory {directory}")
        XCTAssertEqual(PBApplicationSettings.raycastScriptsDirectory, "/tmp/raycast")
        XCTAssertEqual(PBApplicationSettings.patchExportMode, 1)

        for algorithm in [PBDiffAlgorithm.myers, .minimal, .patience, .histogram] {
            PBApplicationSettings.diffAlgorithm = algorithm
            XCTAssertEqual(PBDiffCommandOptions.arguments.count, 2)
        }

        let general = PBSettingsViewFactory.generalView(legacyView: NSView())
        let windows = PBSettingsViewFactory.windowsView()
        let diff = PBSettingsViewFactory.diffAndTextView()
        let terminal = PBSettingsViewFactory.terminalView()
        let traversalNotification = expectation(description: "history traversal setting changed")
        traversalNotification.assertForOverFulfill = true
        let traversalToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("PBHistoryTraversalSettingsDidChangeNotification"),
            object: nil,
            queue: nil
        ) { _ in
            traversalNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(traversalToken) }
        try triggerSettingsAction("changedOnlyChanged:", in: general) {
            ($0 as? NSButton)?.state = .on
        }
        try triggerSettingsAction("changedFilesSortChanged:", in: general) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBChangedFilesSortMode.gitOrder.rawValue)
        }
        try triggerSettingsAction("groupIncomingBranchCommitsChanged:", in: general) {
            ($0 as? NSButton)?.state = .on
        }
        try triggerSettingsAction("branchSortChanged:", in: general) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBBranchSortMode.alphabetical.rawValue)
        }
        try triggerSettingsAction("openDispositionChanged:", in: windows) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBOpenDisposition.alwaysNewWindow.rawValue)
        }
        try triggerSettingsAction("restorePolicyChanged:", in: windows) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBWindowRestorePolicy.always.rawValue)
        }
        try triggerSettingsAction("diffLayoutChanged:", in: diff) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBDiffLayout.sideBySide.rawValue)
        }
        try triggerSettingsAction("diffAlgorithmChanged:", in: diff) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBDiffAlgorithm.patience.rawValue)
        }
        try triggerSettingsAction("syntaxThemeChanged:", in: diff) {
            ($0 as? NSPopUpButton)?.selectItem(withTag: PBSyntaxTheme.xcode.rawValue)
        }
        try triggerSettingsAction("contextChanged:", in: diff) {
            ($0 as? NSStepper)?.integerValue = 7
        }
        try triggerSettingsAction("fontSizeChanged:", in: diff) {
            ($0 as? NSStepper)?.doubleValue = 15
        }
        try triggerSettingsAction("fontChanged:", in: diff) { _ in }
        for control in controls(in: diff).filter({ $0.action == NSSelectorFromString("diffColorChanged:") }) {
            (control as? NSColorWell)?.color = .systemOrange
            _ = control.target?.perform(control.action, with: control)
        }
        try triggerSettingsAction("terminalChanged:", in: terminal) { _ in }
        try triggerSettingsAction("terminalCommandChanged:", in: terminal) {
            ($0 as? NSTextField)?.stringValue = "git status --short"
        }
        try triggerSettingsAction("customExecutableChanged:", in: terminal) {
            ($0 as? NSTextField)?.stringValue = "/usr/bin/true"
        }
        try triggerSettingsAction("customArgumentsChanged:", in: terminal) {
            ($0 as? NSTextField)?.stringValue = "--cwd {directory}"
        }

        XCTAssertTrue(PBApplicationSettings.changedFilesOnly)
        XCTAssertEqual(PBApplicationSettings.changedFilesSort, .gitOrder)
        XCTAssertTrue(PBApplicationSettings.groupIncomingBranchCommits)
        wait(for: [traversalNotification], timeout: 0.1)
        XCTAssertEqual(PBApplicationSettings.branchSort, .alphabetical)
        XCTAssertEqual(PBApplicationSettings.openDisposition, .alwaysNewWindow)
        XCTAssertEqual(PBApplicationSettings.restorePolicy, .always)
        XCTAssertEqual(PBApplicationSettings.diffLayout, .sideBySide)
        XCTAssertEqual(PBApplicationSettings.diffAlgorithm, .patience)
        XCTAssertEqual(PBApplicationSettings.diffContextLines, 7)
        XCTAssertEqual(PBApplicationSettings.diffFontSize, 15)
        XCTAssertEqual(
            controls(in: diff).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "DiffContextValue" }?.stringValue,
            "7 lines"
        )
        XCTAssertEqual(
            controls(in: diff).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "DiffFontSizeValue" }?.stringValue,
            "15 pt"
        )
    }

    func testDockIconChoicesRenderAndApplyImmediately() throws {
        let restoreIconStyle = preservePersistentDefault(forKey: "PBApplicationIconStyle")
        let originalApplicationIcon = NSApplication.shared.applicationIconImage
        defer {
            restoreIconStyle()
            NSApplication.shared.applicationIconImage = originalApplicationIcon
        }

        PBApplicationSettings.applicationIconStyle = .plusEyes
        PBApplicationIconController.applySelectedIcon()
        let plusEyesDockImage = NSApplication.shared.applicationIconImage?.tiffRepresentation
        let pane = PBSettingsViewFactory.dockIconView()
        let buttons = controls(in: pane).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("applicationIconChanged:") }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(
            Set(buttons.map(\.tag)),
            Set(PBApplicationIconStyle.plusEyes.rawValue ... PBApplicationIconStyle.mixedDiff.rawValue)
        )

        let styles: [PBApplicationIconStyle] = [.plusEyes, .bracketed, .cursor, .mixedDiff]
        let renderedIcons = try styles.map { style -> Data in
            let image = PBApplicationIconController.image(for: style)
            XCTAssertEqual(image.size, NSSize(width: 512, height: 512))
            return try XCTUnwrap(image.tiffRepresentation)
        }
        XCTAssertEqual(Set(renderedIcons).count, styles.count, "Each choice should render a distinct robot face")

        let mixedDiffButton = try XCTUnwrap(
            buttons.first { $0.tag == PBApplicationIconStyle.mixedDiff.rawValue }
        )
        mixedDiffButton.performClick(nil)

        XCTAssertEqual(PBApplicationSettings.applicationIconStyle, .mixedDiff)
        XCTAssertEqual(buttons.filter { $0.state == .on }, [mixedDiffButton])
        XCTAssertNotEqual(
            NSApplication.shared.applicationIconImage?.tiffRepresentation,
            plusEyesDockImage,
            "Selecting another robot face should replace the current Dock image"
        )
    }

    func testTerminalLaunchArgumentsTokenizationAndCustomExecution() throws {
        let keys = [
            "PBTerminalBundleIdentifier", "PBTerminalInitialCommand",
            "PBCustomTerminalExecutable", "PBCustomTerminalArguments",
        ]
        let restorers = keys.map { preservePersistentDefault(forKey: $0) }
        defer { restorers.reversed().forEach { $0() } }
        let launcher = PBTerminalLauncher.shared

        XCTAssertEqual(
            launcher.argumentTokens("alpha 'two words' \"three words\" escaped\\ value trailing\\"),
            ["alpha", "two words", "three words", "escaped value", "trailing\\"]
        )
        XCTAssertEqual(
            launcher.launchArguments(identifier: "com.mitchellh.ghostty", directory: "/tmp/repo", command: "git status"),
            ["--working-directory=/tmp/repo", "-e", "/bin/zsh", "-lc", "git status"]
        )
        XCTAssertEqual(
            launcher.launchArguments(identifier: "dev.warp.Warp-Stable", directory: "/tmp/repo", command: ""),
            ["--new-window", "--cwd", "/tmp/repo"]
        )
        XCTAssertEqual(
            launcher.launchArguments(identifier: "com.github.wez.wezterm", directory: "/tmp/repo", command: ""),
            ["start", "--cwd", "/tmp/repo", "--always-new-process"]
        )
        XCTAssertEqual(
            launcher.launchArguments(identifier: "net.kovidgoyal.kitty", directory: "/tmp/repo", command: ""),
            ["--directory", "/tmp/repo"]
        )
        XCTAssertEqual(
            launcher.launchArguments(identifier: "org.alacritty", directory: "/tmp/repo", command: ""),
            ["--working-directory", "/tmp/repo"]
        )
        XCTAssertTrue(launcher.launchArguments(identifier: "unknown", directory: "/tmp/repo", command: "").isEmpty)
        XCTAssertEqual(
            launcher.customArguments(
                template: "--cwd '{directory}' --command \"{command}\"",
                directory: "/tmp/repository with spaces",
                command: "git status --short"
            ),
            ["--cwd", "/tmp/repository with spaces", "--command", "git status --short"]
        )

        PBApplicationSettings.terminalBundleIdentifier = "custom"
        PBApplicationSettings.terminalInitialCommand = "git status"
        PBApplicationSettings.customTerminalExecutable = "/usr/bin/true"
        PBApplicationSettings.customTerminalArguments = "--cwd '{directory}' --command \"{command}\""
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitX terminal repository \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        launcher.open(directory: directory, presenting: nil)

        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        launcher.completeApplicationLaunch(
            error: NSError(
                domain: "TerminalLauncherTests",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "launch failed"]
            ),
            presenting: parentWindow
        )
        XCTAssertNotNil(parentWindow.attachedSheet)
        dismissAttachedSheet(from: parentWindow)
    }

    func testRaycastManagedScriptsInstallUpdateAndRemove() throws {
        let restoreDirectory = preservePersistentDefault(forKey: "PBRaycastScriptsDirectory")
        defer { restoreDirectory() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXRaycast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        PBApplicationSettings.raycastScriptsDirectory = directory.path
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: .titled, backing: .buffered, defer: false)

        PBIntegrationManager.shared.installRaycastScripts(presenting: window)
        dismissAttachedSheet(from: window)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("gitx-raycast-") }.count, 4)
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(contents.contains("# GitX checksum:"))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o755)
        }

        PBIntegrationManager.shared.installRaycastScripts(presenting: window)
        dismissAttachedSheet(from: window)
        let modifiedScript = directory.appendingPathComponent("gitx-raycast-open-repository.sh")
        try (String(contentsOf: modifiedScript, encoding: .utf8) + "\n# user customization\n")
            .write(to: modifiedScript, atomically: true, encoding: .utf8)
        let userScript = directory.appendingPathComponent("gitx-raycast-personal-command.sh")
        try "#!/bin/zsh\necho personal\n".write(to: userScript, atomically: true, encoding: .utf8)
        PBIntegrationManager.shared.removeRaycastScripts(presenting: window)
        dismissAttachedSheet(from: window)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set(["gitx-raycast-open-repository.sh", "gitx-raycast-personal-command.sh"])
        )

        PBApplicationSettings.raycastScriptsDirectory = ""
        PBIntegrationManager.shared.removeRaycastScripts(presenting: window)
    }

    func testRecentRepositoryStorePersistsReplacesAndRemovesEntries() {
        let restore = preservePersistentDefault(forKey: "PBRecentRepositories")
        defer { restore() }
        UserDefaults.standard.set([], forKey: "PBRecentRepositories")
        let first = URL(fileURLWithPath: "/tmp/GitX-Recent-First")
        let second = URL(fileURLWithPath: "/tmp/GitX-Recent-Second")
        let store = PBRecentRepositoryStore.shared

        store.record(first)
        XCTAssertTrue(recentRepositoryPaths().contains(first.path))
        store.replace(first, with: second)
        XCTAssertFalse(recentRepositoryPaths().contains(first.path))
        XCTAssertTrue(recentRepositoryPaths().contains(second.path))
        store.remove(second)
        XCTAssertFalse(recentRepositoryPaths().contains(second.path))
    }

    func testHighlightingThemesAndPlainFallbackFont() {
        let restoreTheme = preservePersistentDefault(forKey: "PBSyntaxTheme")
        let restoreFont = preservePersistentDefault(forKey: "PBDiffFontName")
        let restoreSize = preservePersistentDefault(forKey: "PBDiffFontSize")
        defer {
            restoreSize()
            restoreFont()
            restoreTheme()
        }
        for theme in [PBSyntaxTheme.xcode, .github] {
            PBApplicationSettings.syntaxTheme = theme
            XCTAssertEqual(PBHighlighting.highlightedString(forText: "let value = 1", path: "File.swift").string, "let value = 1")
        }
        PBApplicationSettings.syntaxTheme = .plain
        PBApplicationSettings.diffFontName = "Definitely Not A Font"
        PBApplicationSettings.diffFontSize = 13
        let plain = PBHighlighting.highlightedString(forText: "plain", path: "File.swift")
        XCTAssertEqual(plain.string, "plain")
        XCTAssertNotNil(plain.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertNotNil(PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)).textView.font)
    }

    func testPatchExportNamingRevisionAndSeriesPolicies() {
        XCTAssertEqual(
            PBCommitPatchExportPolicy.filenames(forSubjects: ["Add Café / Toolbar", "!!!"]),
            ["0001-add-cafe-toolbar.patch", "0002-commit.patch"]
        )
        XCTAssertEqual(PBCommitPatchExportPolicy.safeFilename(forSubject: String(repeating: "A", count: 100)).count, 80)
        XCTAssertEqual(
            PBCommitPatchExportPolicy.revision(forOldestSHA: "old", newestSHA: "new", oldestIsRoot: false),
            "old^..new"
        )
        XCTAssertEqual(
            PBCommitPatchExportPolicy.revision(forOldestSHA: "old", newestSHA: "new", oldestIsRoot: true),
            "new"
        )
        XCTAssertTrue(PBCommitPatchExportPolicy.series(output: "old\nnew\n", matchesSHAs: ["old", "new"]))
        XCTAssertFalse(PBCommitPatchExportPolicy.series(output: "new\nold\n", matchesSHAs: ["old", "new"]))
    }

    func testHistoryStateNestedSelectionAndOverflowBoundaries() {
        let coordinator = PBHistoryStateCoordinator()
        let repository = PBGitRepository()
        let working = PBUncommittedChanges(repository: repository)
        XCTAssertTrue(coordinator.normalizedSelection([working, working]).first === working)

        let presentation = coordinator.branchFilterPresentation(
            simpleBranch: true,
            filter: 1,
            selectedTitle: "origin/main",
            remote: true
        )
        XCTAssertEqual(presentation.localTitle, "Remote")
        XCTAssertTrue(presentation.allEnabled)

        let leaf = TreeFixture(fullPath: "Sources/App.swift", path: "App.swift")
        let folder = TreeFixture(fullPath: "Sources", path: "Sources", children: [leaf])
        coordinator.saveFileBrowserSelection(selectedObjects: [leaf], hasContent: true)
        XCTAssertEqual(coordinator.treeSelectionIndexPath(children: [folder], treeMode: true), IndexPath(indexes: [0, 0]))
        XCTAssertEqual(
            coordinator.adjustedScrollRow(selectionRow: Int.max - 1, oldRow: 0, visibleRows: 3, contentCount: 4),
            3
        )
        XCTAssertEqual(coordinator.adjustedScrollRow(selectionRow: 4, oldRow: 1, visibleRows: 3, contentCount: 10), 6)
    }

    private func controls(in view: NSView) -> [NSControl] {
        var result = view.subviews.compactMap { $0 as? NSControl }
        for child in view.subviews {
            result.append(contentsOf: controls(in: child))
        }
        return result
    }

    private func recentRepositoryPaths() -> [String] {
        (UserDefaults.standard.array(forKey: "PBRecentRepositories") as? [[String: Any]] ?? [])
            .compactMap { $0["path"] as? String }
    }

    private func triggerSettingsAction(
        _ actionName: String,
        in view: NSView,
        configure: (NSControl) -> Void
    ) throws {
        let selector = NSSelectorFromString(actionName)
        let control = try XCTUnwrap(controls(in: view).first { $0.action == selector })
        configure(control)
        _ = control.target?.perform(selector, with: control)
    }

    private func dismissAttachedSheet(from window: NSWindow) {
        guard let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
        sheet.orderOut(nil)
    }
}
