import AppKit
import XCTest

final class GitXSwiftFeatureTests: XCTestCase {
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
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(30)), "In the future!")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-30)), "seconds ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-90)), "1 minute ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-600)), "10 minutes ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-5400)), "1 hour ago")
        XCTAssertEqual(formatter.string(for: now.addingTimeInterval(-10800)), "3 hours ago")
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
}
