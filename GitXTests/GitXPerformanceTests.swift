import AppKit
import ForgeKit
import XCTest

/// Scheduled microbenchmarks for deterministic parsing and presentation policy.
/// Keep fixture creation outside each measured block and keep this class out of
/// correctness and sanitizer plans.
@MainActor
final class GitXPerformanceTests: XCTestCase {
    private struct DiffFixture {
        let fileCount: Int
        let byteCount: Int
        let sections: [[String: Any]]
        let marker: String
    }

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func elapsedThrowing(_ work: () throws -> Void) rethrows -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        try work()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func elapsedAsync(_ work: () async throws -> Void) async rethrows -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        try await work()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func percentile95(_ samples: [TimeInterval]) -> TimeInterval {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private func attachMeasurements(
        _ name: String,
        cold: TimeInterval? = nil,
        samples: [TimeInterval]
    ) {
        let milliseconds = samples.map { String(format: "%.2f", $0 * 1000) }.joined(separator: ", ")
        let coldDescription = cold.map { String(format: "cold=%.2fms, ", $0 * 1000) } ?? ""
        let attachment = XCTAttachment(
            string: "\(coldDescription)p95=\(String(format: "%.2f", percentile95(samples) * 1000))ms\n" +
                "samples(ms)=\(milliseconds)"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func representativeAvatarPayload() throws -> ForgeAvatarPayload {
        let side = 512
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(starting: .systemBlue, ending: .systemPurple)?.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            angle: 35
        )
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return ForgeAvatarPayload(data: data, mediaType: .png)
    }

    private func pushFlowFixture() throws -> (
        intent: ForgePushPullRequestIntent,
        destination: ForgeDestination
    ) {
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let repository = try ForgeRepositoryIdentity(forge: forge, owner: "gitx", name: "gitx")
        let contributor = try ForgeRepositoryIdentity(
            forge: forge,
            owner: "contributor",
            name: "gitx"
        )
        let accountID = try ForgeAccountID(forge: forge, value: "performance")
        let baseCommit = try ForgeCommitID(String(repeating: "1", count: 40))
        let headCommit = try ForgeCommitID(String(repeating: "2", count: 40))
        let preparation = try RepositoryPullRequestCreationPreparation(
            accountID: accountID,
            repository: repository,
            base: ForgeBranchReference(
                repository: repository,
                name: ForgeRefName("main"),
                commit: baseCommit
            ),
            head: ForgeBranchReference(
                repository: contributor,
                name: ForgeRefName("feature/performance"),
                commit: headCommit
            ),
            branchAlreadyPushed: false,
            commitsOldestFirst: [ForgePullRequestCommitSummary(
                id: headCommit,
                subject: "Performance fixture"
            )]
        )
        let form = try preparation.initialForms().forms[0]
        return try (
            ForgePushPullRequestIntent(
                form: form,
                draftIdentity: RepositoryPullRequestDraftPolicy.identity(preparation: preparation)
            ),
            .pullRequest(repository, ForgeItemNumber(42))
        )
    }

    private func diffFixture(fileCount: Int, minimumByteCount: Int) -> DiffFixture {
        var diff = ""
        let linePairsPerFile = 8
        let fixedBytesPerFile = 180
        let payloadWidth = max(
            8,
            (minimumByteCount / fileCount - fixedBytesPerFile) / (linePairsPerFile * 2)
        )
        let payload = String(repeating: "x", count: payloadWidth)
        var marker = ""
        for fileIndex in 0 ..< fileCount {
            let path = String(format: "Sources/Feature/File-%05d.swift", fileIndex)
            diff += """
            diff --git a/\(path) b/\(path)
            --- a/\(path)
            +++ b/\(path)
            @@ -1,\(linePairsPerFile) +1,\(linePairsPerFile) @@

            """
            for lineIndex in 0 ..< linePairsPerFile {
                diff += "-old-\(fileIndex)-\(lineIndex)-\(payload)\n"
                marker = "new-\(fileIndex)-\(lineIndex)-\(payload)"
                diff += "+\(marker)\n"
            }
        }
        while diff.utf8.count < minimumByteCount {
            diff += " context-padding-\(payload)\n"
        }
        return DiffFixture(
            fileCount: fileCount,
            byteCount: diff.utf8.count,
            sections: [[
                PBNativeSectionTextKey: diff,
                PBNativeSectionContextKey: "readOnly",
                PBNativeSectionDiffLayoutKey: 0,
            ]],
            marker: marker
        )
    }

    private func diffRenderer() -> PBNativeDiffRenderer {
        PBNativeDiffRenderer(
            baseAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ],
            titleAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ],
            parser: PBDiffDocumentParser()
        )
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let task = PBTask(
            launchPath: "/usr/bin/git",
            arguments: arguments,
            inDirectory: directory.path
        )
        task.timeout = 30
        try task.launch()
        return task.standardOutputString() ?? ""
    }

    func testRepositoryStatusBarOverlayApplicationStaysWithinMainThreadBudget() throws {
        let records = [
            "# branch.oid 0123456789abcdef",
            "# branch.head main",
            "# branch.ab +12 -3",
        ] + (0 ..< 500).map { index in
            "1 MM N... 100644 100644 100644 a b Sources/File-\(index).swift"
        }
        let data = Data((records.joined(separator: "\0") + "\0").utf8)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let forgeInput = try ForgeRepositoryStatusInput(
            repository: ForgeRepositoryIdentity(
                forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
                owner: "hbmartin",
                name: "gitx"
            ),
            access: .account(login: "octocat"),
            freshness: .current(fetchedAt: now.addingTimeInterval(-300)),
            diagnostic: .none
        )
        let statusBar = RepositoryStatusBarView(
            frame: NSRect(x: 0, y: 0, width: 890, height: 29)
        )
        let samples = (0 ..< 200).map { _ in
            elapsed {
                let snapshot = RepositoryPorcelainStatusParser.parse(data, operation: .rebase)!
                let local = RepositoryLocalStatusPresenter.present(snapshot, activityText: nil, isBusy: false)
                let forge = ForgeRepositoryStatusPresenter.present(forgeInput, now: now)
                statusBar.apply(local: local)
                statusBar.apply(forge: forge)
                statusBar.layoutSubtreeIfNeeded()
            }
        }
        attachMeasurements("repository-status-overlay-application", samples: samples)
        XCTAssertLessThan(percentile95(samples), 0.016)
    }

    func testHistoryCachedBadgeRenderingAndMainThreadApplicationMeetBudgets() throws {
        let repository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "hbmartin",
            name: "gitx"
        )
        let now = Date(timeIntervalSince1970: 2_000_000)
        let states = try (0 ..< 200).map { index in
            let identifier = String(repeating: "0", count: 36) + String(format: "%04x", index)
            let overlay = try ForgeHistoryOverlay(
                repository: repository,
                commit: ForgeCommitID(identifier),
                checkRollup: .available(index.isMultiple(of: 2) ? .succeeded : .running),
                pullRequests: .available(ForgePage(items: [], totalCount: 0))
            )
            return RepositoryForgeOverlayValueState.value(RepositoryForgeOverlaySnapshot(
                value: overlay,
                fetchedAt: now,
                isPartial: false,
                isStale: false
            ))
        }
        var presentations: [HistoryForgeBadgePresentation] = []
        let renderingSamples = (0 ..< 100).map { _ in
            elapsed {
                presentations = states.map(HistoryForgeBadgePresenter.present)
            }
        }
        attachMeasurements("history-cached-badge-rendering", samples: renderingSamples)
        XCTAssertEqual(presentations.count, 200)
        XCTAssertLessThan(percentile95(renderingSamples), 0.050)

        let visiblePresentations = Array(presentations.prefix(40))
        let cells = visiblePresentations.map { _ in
            (NSTextField(labelWithString: ""), NSTextField(labelWithString: ""))
        }
        let applicationSamples = (0 ..< 200).map { _ in
            elapsed {
                for (index, presentation) in visiblePresentations.enumerated() {
                    cells[index].0.stringValue = presentation.checkText
                    cells[index].0.setAccessibilityLabel(presentation.checkAccessibilityLabel)
                    cells[index].1.stringValue = presentation.pullRequestText
                    cells[index].1.setAccessibilityLabel(presentation.pullRequestAccessibilityLabel)
                }
            }
        }
        attachMeasurements("history-visible-overlay-main-thread-application", samples: applicationSamples)
        XCTAssertLessThan(percentile95(applicationSamples), 0.016)
    }

    private func makeRepresentativeRepository() throws -> URL {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-working-state-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )
        _ = try gitOutput(["init", "--quiet"], in: repositoryURL)
        let originalPayload = String(repeating: "o", count: 1024)
        for index in 0 ..< PBPerformanceBudgets.representativeChangedFileCount {
            let fileURL = repositoryURL.appendingPathComponent(
                String(format: "file-%05d.txt", index)
            )
            try "old-\(index)-\(originalPayload)\n".write(
                to: fileURL,
                atomically: false,
                encoding: .utf8
            )
        }
        _ = try gitOutput(["add", "."], in: repositoryURL)
        _ = try gitOutput([
            "-c", "user.name=GitX Performance",
            "-c", "user.email=performance@gitx.invalid",
            "commit", "--quiet", "-m", "Fixture",
        ], in: repositoryURL)

        let changedPayload = String(repeating: "n", count: 1024)
        for index in 0 ..< PBPerformanceBudgets.representativeChangedFileCount {
            let fileURL = repositoryURL.appendingPathComponent(
                String(format: "file-%05d.txt", index)
            )
            try "new-\(index)-\(changedPayload)\n".write(
                to: fileURL,
                atomically: false,
                encoding: .utf8
            )
        }
        return repositoryURL
    }

    private func largeDiff(path: String, lineCount: Int) -> String {
        var diff = """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -1,\(lineCount) +1,\(lineCount) @@

        """
        for index in 0 ..< lineCount {
            diff += "-let oldValue\(index) = \(index)\n"
            diff += "+let newValue\(index) = \(index + 1)\n"
        }
        return diff
    }

    private func renderedDiff() throws -> (
        window: NSWindow,
        view: PBNativeContentView,
        scrollView: NSScrollView
    ) {
        XCTAssertTrue(Thread.isMainThread)
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.layoutIfNeeded()
        let path = "Large.swift"
        let diff = largeDiff(path: path, lineCount: 4500)
        XCTAssertFalse(PBHighlighting.shouldHighlightDiff(withByteCount: UInt(diff.utf8.count)))
        view.showDiffSections([
            [
                PBNativeSectionTextKey: diff,
                PBNativeSectionPathKey: path,
                PBNativeSectionContextKey: "readOnly",
            ],
        ])
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                view.textView.string.contains("+let newValue4499 = 4500")
            },
            object: view.textView
        )
        wait(for: [rendered], timeout: 20)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let scrollView = try XCTUnwrap(view.textView.enclosingScrollView)
        XCTAssertGreaterThan(
            try XCTUnwrap(scrollView.documentView).frame.height,
            scrollView.contentView.bounds.height
        )
        return (window, view, scrollView)
    }

    private func scrollWorkload(
        window: NSWindow,
        view: PBNativeContentView,
        scrollView: NSScrollView
    ) -> CGFloat {
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximumY = max(0, documentHeight - clipView.bounds.height)
        let viewportSize = clipView.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewportSize.width),
            pixelsHigh: Int(viewportSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return 0 }
        var checksum: CGFloat = 0
        for step in 0 ..< 40 {
            let fraction = CGFloat((step * 37) % 101) / 100
            clipView.scroll(to: NSPoint(x: 0, y: maximumY * fraction))
            scrollView.reflectScrolledClipView(clipView)
            view.layoutSubtreeIfNeeded()
            let viewport = NSRect(origin: clipView.bounds.origin, size: viewportSize)
            view.textView.cacheDisplay(in: viewport, to: bitmap)
            window.displayIfNeeded()
            checksum += clipView.bounds.origin.y
        }
        return checksum
    }

    func testRevisionSpecifierParsingPerformance() {
        let parameterSets = [
            ["refs/heads/main"],
            ["refs/remotes/origin/topic"],
            ["HEAD~25"],
            ["main..topic"],
            ["HEAD", "--", "Classes/Controllers"],
        ]
        let workload = { () -> Int in
            var classifiedCount = 0
            for iteration in 0 ..< 2000 {
                autoreleasepool {
                    let specifier = PBGitRevSpecifier(
                        parameters: parameterSets[iteration % parameterSets.count]
                    )
                    classifiedCount += specifier.isSimpleRef ? 1 : 0
                    classifiedCount += specifier.hasPathLimiter() ? 1 : 0
                    _ = specifier.title()
                }
            }
            return classifiedCount
        }
        _ = workload()

        var classifiedCount = 0
        measure {
            classifiedCount = workload()
        }

        XCTAssertGreaterThan(classifiedCount, 0)
    }

    func testPushPullRequestDecisionWorkloadMeetsCachedFeedbackBudget() throws {
        let fixture = try pushFlowFixture()
        var terminalState = RepositoryPullRequestPushFlow()
        var samples: [TimeInterval] = []
        for _ in 0 ..< 20 {
            try samples.append(elapsedThrowing {
                for _ in 0 ..< 1000 {
                    var flow = RepositoryPullRequestPushFlow()
                    try flow.beginNewPullRequest(
                        branchAlreadyPushed: false,
                        intent: fixture.intent
                    )
                    try flow.pushBegan(createPullRequestSelected: true)
                    try flow.pushSucceeded()
                    try flow.createSheetCancelled()
                    try flow.beginNewPullRequest(
                        branchAlreadyPushed: true,
                        intent: fixture.intent
                    )
                    try flow.creationSucceeded(fixture.destination)
                    terminalState = flow
                }
            })
        }

        attachMeasurements("Push-to-Pull-Request decisions (1,000 journeys)", samples: samples)
        XCTAssertEqual(terminalState.state, .completed(fixture.destination))
        XCTAssertLessThanOrEqual(
            percentile95(samples),
            PBPerformanceBudgets.cachedWorkingStateFeedbackSeconds
        )
    }

    func testPushPullRequestFormUpdateMeetsMainThreadBudget() {
        let checkbox = RepositoryPushConfirmationPresenter.createPullRequestButton(
            initiallySelected: true
        )
        let alert = RepositoryPushConfirmationPresenter.alert(
            description: "Push branch 'feature/performance' to default remote",
            accessoryView: checkbox
        )
        let contentView = alert.window.contentView
        contentView?.layoutSubtreeIfNeeded()
        var samples: [TimeInterval] = []
        for index in 0 ..< 40 {
            samples.append(elapsed {
                checkbox.state = index.isMultiple(of: 2) ? .on : .off
                checkbox.sizeToFit()
                contentView?.needsLayout = true
                contentView?.layoutSubtreeIfNeeded()
            })
        }

        attachMeasurements("Push Pull Request checkbox/form update", samples: samples)
        XCTAssertLessThanOrEqual(
            percentile95(samples),
            PBPerformanceBudgets.mainThreadBlockSeconds
        )
    }

    func testSourceLanguageClassificationPerformance() {
        let paths = [
            "Classes/Controllers/PBGitWindowController.swift",
            "Classes/Views/PBHighlighting.swift",
            "Resources/source.css",
            "Dockerfile",
            "README.markdown",
        ]
        let workload = { () -> String? in
            var lastLanguage: String?
            for iteration in 0 ..< 20000 {
                lastLanguage = PBHighlighting.languageName(
                    forPath: paths[iteration % paths.count]
                )
            }
            return lastLanguage
        }
        _ = workload()

        var lastLanguage: String?
        measure {
            lastLanguage = workload()
        }

        XCTAssertNotNil(lastLanguage)
    }

    func testWarmSyntaxHighlightingCachePerformance() {
        let defaults = UserDefaults.standard
        let originalTheme = defaults.object(forKey: "PBSyntaxTheme")
        defer {
            if let originalTheme {
                defaults.set(originalTheme, forKey: "PBSyntaxTheme")
            } else {
                defaults.removeObject(forKey: "PBSyntaxTheme")
            }
        }
        defaults.set(PBSyntaxTheme.xcode.rawValue, forKey: "PBSyntaxTheme")
        let source = "{\n" + (0 ..< 300)
            .map { "\"cachedValue\($0)\": \($0)" }
            .joined(separator: ",\n") + "\n}"
        _ = PBHighlighting.highlightedString(forText: source, path: "Cached.json")
        var renderedLength = 0

        measure {
            for _ in 0 ..< 100 {
                renderedLength = PBHighlighting.highlightedString(
                    forText: source,
                    path: "Cached.json"
                ).length
            }
        }

        XCTAssertEqual(renderedLength, (source as NSString).length)
    }

    func testLargeIndexSnapshotParsingAndReductionPerformance() {
        let parser = PBIndexStatusParser()
        let reducer = PBIndexSnapshotReducer()
        var stagedOutput = ""
        var unstagedOutput = ""
        for index in 0 ..< 5000 {
            let path = "folder/file-\(index).txt"
            stagedOutput += ":100644 100644 old\(index) staged\(index) M\0\(path)\0"
            unstagedOutput += ":100644 100644 staged\(index) working\(index) M\0\(path)\0"
        }
        let stagedData = stagedOutput.data(using: .utf8)
        let unstagedData = unstagedOutput.data(using: .utf8)
        var resultCount = 0
        let workload = {
            let staged = parser.parseTrackedData(stagedData, error: nil)
            let unstaged = parser.parseTrackedData(unstagedData, error: nil)
            resultCount = reducer.reducePrevious(
                [],
                staged: staged,
                unstaged: unstaged,
                untracked: [:]
            ).count
        }
        workload()

        measure {
            workload()
        }

        XCTAssertEqual(resultCount, 5000)
    }

    func testLargeNativeDiffScrollingPerformance() throws {
        let fixture = try renderedDiff()
        _ = scrollWorkload(window: fixture.window, view: fixture.view, scrollView: fixture.scrollView)
        _ = scrollWorkload(window: fixture.window, view: fixture.view, scrollView: fixture.scrollView)

        var checksum: CGFloat = 0
        measure {
            checksum = scrollWorkload(
                window: fixture.window,
                view: fixture.view,
                scrollView: fixture.scrollView
            )
        }

        XCTAssertGreaterThan(checksum, 0)
    }

    func testCachedWorkingStateFeedbackMeetsBudget() {
        let fixture = diffFixture(
            fileCount: PBPerformanceBudgets.representativeChangedFileCount,
            minimumByteCount: PBPerformanceBudgets.representativeDiffByteCount
        )
        XCTAssertEqual(fixture.fileCount, 500)
        XCTAssertGreaterThanOrEqual(fixture.byteCount, 1_048_576)
        let view = PBNativeContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.showDiffSections(
            fixture.sections,
            cacheIdentifier: "performance-working-state",
            preserveScrollPosition: true
        )
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in view.textView.string.contains(fixture.marker) },
            object: view.textView
        )
        wait(for: [rendered], timeout: 30)

        var samples: [TimeInterval] = []
        for _ in 0 ..< 20 {
            view.showMessage("Loading…")
            samples.append(elapsed {
                view.showDiffSections(
                    fixture.sections,
                    cacheIdentifier: "performance-working-state",
                    preserveScrollPosition: true
                )
            })
            XCTAssertTrue(view.textView.string.contains(fixture.marker))
        }

        attachMeasurements("Cached Working State feedback", samples: samples)
        XCTAssertLessThanOrEqual(
            percentile95(samples),
            PBPerformanceBudgets.cachedWorkingStateFeedbackSeconds
        )
    }

    func testFreshRepresentativeWorkingStateRenderingMeetsBudget() {
        let fixture = diffFixture(
            fileCount: PBPerformanceBudgets.representativeChangedFileCount,
            minimumByteCount: PBPerformanceBudgets.representativeDiffByteCount
        )
        let sections = PBNativeContentSection.sections(withDictionaries: fixture.sections)
        let renderer = diffRenderer()
        var latestResult: PBNativeRenderResult?
        let cold = elapsed {
            latestResult = renderer.renderSections(
                sections,
                collapsedFiles: [],
                expandedImages: [],
                imageDataProvider: nil
            )
        }
        var samples: [TimeInterval] = []
        for _ in 0 ..< 12 {
            samples.append(elapsed {
                latestResult = renderer.renderSections(
                    sections,
                    collapsedFiles: [],
                    expandedImages: [],
                    imageDataProvider: nil
                )
            })
        }

        attachMeasurements("Fresh 500-file 1-MiB Working State rendering", cold: cold, samples: samples)
        XCTAssertTrue(latestResult?.attributedString.string.contains(fixture.marker) == true)
        XCTAssertLessThanOrEqual(
            percentile95(samples),
            PBPerformanceBudgets.freshWorkingStateP95Seconds
        )
    }

    func testFreshRepresentativeWorkingStatePipelineMeetsBudget() throws {
        let repositoryURL = try makeRepresentativeRepository()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        let renderer = diffRenderer()
        let options = PBDiffCommandOptions.arguments
        var latestResult: PBNativeRenderResult?
        var latestByteCount = 0
        let pipeline = {
            let staged = try! self.gitOutput(
                ["diff"] + options + ["--cached", "--find-renames", "--no-ext-diff"],
                in: repositoryURL
            )
            let unstaged = try! self.gitOutput(
                ["diff"] + options + ["--find-renames", "--no-ext-diff"],
                in: repositoryURL
            )
            latestByteCount = staged.utf8.count + unstaged.utf8.count
            let sections = PBNativeContentSection.sections(withDictionaries: [
                [
                    PBNativeSectionTitleKey: "Staged Changes",
                    PBNativeSectionTextKey: staged,
                    PBNativeSectionContextKey: "readOnly",
                    PBNativeSectionDiffLayoutKey: 0,
                ],
                [
                    PBNativeSectionTitleKey: "Unstaged Changes",
                    PBNativeSectionTextKey: unstaged,
                    PBNativeSectionContextKey: "readOnly",
                    PBNativeSectionDiffLayoutKey: 0,
                ],
            ])
            latestResult = renderer.renderSections(
                sections,
                collapsedFiles: [],
                expandedImages: [],
                imageDataProvider: nil
            )
        }
        let cold = elapsed(pipeline)
        var samples: [TimeInterval] = []
        for _ in 0 ..< 10 {
            samples.append(elapsed(pipeline))
        }

        attachMeasurements(
            "Fresh 500-file 1-MiB Working State Git-plus-render pipeline",
            cold: cold,
            samples: samples
        )
        XCTAssertGreaterThanOrEqual(
            latestByteCount,
            PBPerformanceBudgets.representativeDiffByteCount
        )
        XCTAssertTrue(latestResult?.attributedString.string.contains("file-00499.txt") == true)
        XCTAssertLessThanOrEqual(
            percentile95(samples),
            PBPerformanceBudgets.freshWorkingStateP95Seconds
        )
    }

    func testStressWorkingStateRenderingIsReportedWithoutGate() {
        let fixture = diffFixture(
            fileCount: PBPerformanceBudgets.stressChangedFileCount,
            minimumByteCount: PBPerformanceBudgets.stressDiffByteCount
        )
        let sections = PBNativeContentSection.sections(withDictionaries: fixture.sections)
        var result: PBNativeRenderResult?
        let duration = elapsed {
            result = diffRenderer().renderSections(
                sections,
                collapsedFiles: [],
                expandedImages: [],
                imageDataProvider: nil
            )
        }

        attachMeasurements("Stress 5,000-file 10-MiB Working State rendering", samples: [duration])
        XCTAssertEqual(fixture.fileCount, PBPerformanceBudgets.stressChangedFileCount)
        XCTAssertGreaterThanOrEqual(fixture.byteCount, PBPerformanceBudgets.stressDiffByteCount)
        XCTAssertTrue(result?.attributedString.string.contains(fixture.marker) == true)
    }

    func testRepresentativeForgeMarkdownRenderingMeetsMainThreadBudget() {
        var blocks: [ForgeMarkdownBlock] = [
            .heading(
                level: 1,
                identifier: ForgeMarkdownHeadingID(rawValue: "review-summary"),
                content: [.text("Review summary")]
            ),
        ]
        for index in 0 ..< 60 {
            blocks.append(.paragraph([
                .text("Comment \(index) keeps "),
                .strong([.text("structured Markdown")]),
                .text(" readable, with "),
                .imagePlaceholder(altText: "inert diagram \(index)"),
            ]))
            blocks.append(.unorderedList([
                ForgeMarkdownListItem(
                    taskState: index.isMultiple(of: 2) ? .checked : .unchecked,
                    blocks: [.paragraph([.text("Review item \(index)")])]
                ),
            ]))
        }
        let document = ForgeMarkdownDocument(blocks: blocks)
        let renderer = ForgeMarkdownNativeRenderer()
        let view = ForgeMarkdownNativeView(document: document, renderer: renderer)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        view.layoutSubtreeIfNeeded()
        let applyAndLayout = {
            view.display(document, renderer: renderer)
            view.layoutSubtreeIfNeeded()
            if let textContainer = view.textView.textContainer {
                view.textView.layoutManager?.ensureLayout(for: textContainer)
            }
        }
        let cold = elapsed {
            applyAndLayout()
        }
        var samples: [TimeInterval] = []
        for _ in 0 ..< 20 {
            samples.append(elapsed {
                applyAndLayout()
            })
        }

        attachMeasurements(
            "Representative native Forge Markdown render, text storage, and layout application",
            cold: cold,
            samples: samples
        )
        XCTAssertTrue(view.textView.string.contains("inert diagram 59"))
        XCTAssertLessThanOrEqual(percentile95(samples), 0.016)
    }

    func testRepresentativeAvatarMemoryCacheHitsMeetAffectedViewBudget() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/9001")
        let payload = ForgeAvatarPayload(
            data: Data(repeating: 0xA5, count: 4 * 1024),
            mediaType: .png
        )
        let transport = PerformanceAvatarTransport(payload: payload)
        let loader = ForgeAvatarLoader(
            transport: transport,
            cacheByteLimit: Int(ForgePolicyConstants.avatarCacheByteLimit)
        )
        _ = try await loader.load(avatarURL)

        var latest: ForgeAvatarPayload?
        var samples: [TimeInterval] = []
        for _ in 0 ..< 200 {
            try samples.append(await elapsedAsync {
                latest = try await loader.load(avatarURL)
            })
        }

        attachMeasurements("Representative structured-avatar memory-cache hits", samples: samples)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(latest, payload)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertLessThanOrEqual(percentile95(samples), 0.016)
    }

    func testRepresentativeAvatarDecodeRunsOffMainAndMeetsAffectedViewBudgets() async throws {
        let payload = try representativeAvatarPayload()
        let decoder = ForgeAvatarImageDecoder()
        var latest: ForgeAvatarDecodedImage?
        let cold = try await elapsedAsync {
            latest = try await decoder.decodeOffMain(payload)
        }
        var decodeSamples: [TimeInterval] = []
        for _ in 0 ..< 20 {
            try decodeSamples.append(await elapsedAsync {
                latest = try await decoder.decodeOffMain(payload)
            })
        }
        attachMeasurements(
            "Representative 512-pixel structured-avatar background decode",
            cold: cold,
            samples: decodeSamples
        )
        let decoded = try XCTUnwrap(latest)
        XCTAssertFalse(decoded.wasDecodedOnMainThread)
        XCTAssertEqual(decoded.size, NSSize(width: 512, height: 512))
        XCTAssertLessThanOrEqual(percentile95(decodeSamples), 0.050)

        var assignmentSamples: [TimeInterval] = []
        for _ in 0 ..< 200 {
            assignmentSamples.append(elapsed {
                _ = decoded.makeImage()
            })
        }
        attachMeasurements(
            "Representative structured-avatar main-actor image assignment",
            samples: assignmentSamples
        )
        XCTAssertLessThanOrEqual(percentile95(assignmentSamples), 0.016)
    }
}

private actor PerformanceAvatarTransport: ForgeAvatarTransport {
    let payload: ForgeAvatarPayload
    private(set) var fetchCount = 0

    init(payload: ForgeAvatarPayload) {
        self.payload = payload
    }

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        fetchCount += 1
        return payload
    }
}
