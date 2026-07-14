@testable import GitX
import XCTest

final class GitXSwiftFeatureTests: XCTestCase {
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
        XCTAssertEqual(GitX.PBHighlighting.languageName(forPath: "Dockerfile"), "dockerfile")
        XCTAssertEqual(GitX.PBHighlighting.languageName(forPath: "GNUmakefile"), "makefile")
        XCTAssertEqual(GitX.PBHighlighting.languageName(forPath: "Sources/EXAMPLE.SWIFT"), "swift")
        XCTAssertNil(GitX.PBHighlighting.languageName(forPath: "archive.unknown"))
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

    func testRefreshOnFocusPolicyIsOptIn() throws {
        let suiteName = "GitXTests.RefreshOnFocus.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(
            RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation(userDefaults: userDefaults)
        )

        userDefaults.set(true, forKey: RepositoryRefreshPolicy.refreshOnApplicationFocusKey)
        XCTAssertTrue(
            RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation(userDefaults: userDefaults)
        )

        userDefaults.set(false, forKey: RepositoryRefreshPolicy.refreshOnApplicationFocusKey)
        XCTAssertFalse(
            RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation(userDefaults: userDefaults)
        )
    }

    func testFocusRefreshTrackerOnlyRefreshesForChangedSnapshots() {
        let tracker = RepositoryFocusRefreshTracker()
        let initialSnapshot = [Data("a".utf8), Data("bc".utf8)]
        let changedAtComponentBoundary = [Data("ab".utf8), Data("c".utf8)]

        XCTAssertFalse(tracker.shouldRefresh(for: initialSnapshot))
        XCTAssertFalse(tracker.shouldRefresh(for: initialSnapshot))
        XCTAssertTrue(tracker.shouldRefresh(for: changedAtComponentBoundary))
        XCTAssertFalse(tracker.shouldRefresh(for: changedAtComponentBoundary))

        tracker.reset()
        XCTAssertFalse(tracker.shouldRefresh(for: initialSnapshot))
    }
}
