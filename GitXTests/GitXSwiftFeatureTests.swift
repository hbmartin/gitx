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
}
