import XCTest

@MainActor
// swift6-safety-justification: XCTest owns this case; fixture mutation and synchronous main-thread teardown are confined to the main actor.
final class GitXFixtureRepositoryPolicyTests: XCTestCase, @unchecked Sendable {
    private let fixtureWorkspace = GitXUITestFixtureWorkspace(prefix: "gitx-policy")

    override nonisolated func tearDown() {
        // swift6-safety-justification: XCTest invokes this synchronous AppKit fixture teardown on the main thread.
        MainActor.assumeIsolated { fixtureWorkspace.removeAll() }
        super.tearDown()
    }

    private func makeWorkingRepository(name: String) throws -> URL {
        let repository = try fixtureWorkspace.makeDirectory(named: name)
        try git(["init", "--quiet", "--initial-branch", "main"], in: repository)
        try git(["commit", "--quiet", "--allow-empty", "-m", "Fixture"], in: repository)
        return repository
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        try fixtureWorkspace.git(arguments, in: directory)
    }

    func testIsolatedHomesCreateIndependentPreferencesAndRemainOwnedByWorkspaceCleanup() throws {
        let standard = try fixtureWorkspace.makeIsolatedHome()
        let named = try fixtureWorkspace.makeIsolatedHome(named: "named home")
        XCTAssertNotEqual(standard, named)
        XCTAssertEqual(Set(fixtureWorkspace.directories), [standard, named])
        let fileManager = FileManager.default
        for home in [standard, named] {
            let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: preferences.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: preferences.path), [])
        }
        let preference = "Library/Preferences/fixture.plist"
        try Data("isolated preference".utf8).write(to: standard.appendingPathComponent(preference))
        XCTAssertFalse(fileManager.fileExists(atPath: named.appendingPathComponent(preference).path))

        fixtureWorkspace.removeAll()
        XCTAssertTrue(fixtureWorkspace.directories.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: standard.path))
        XCTAssertFalse(fileManager.fileExists(atPath: named.path))
    }

    func testFixtureKeepsRealUntrackedFilesAndExplicitlyTrackedFinderMetadata() throws {
        let repository = try makeWorkingRepository(name: "fixture-metadata-characterization")
        let metadata = repository.appendingPathComponent(".DS_Store")
        try Data([0, 1, 2]).write(to: metadata)
        _ = try git(["add", "--force", ".DS_Store"], in: repository)
        _ = try git(["commit", "--quiet", "-m", "Tracked fixture metadata"], in: repository)
        try Data([0, 1, 3]).write(to: metadata)
        try "real untracked source\n".write(
            to: repository.appendingPathComponent("real.swift"), atomically: true, encoding: .utf8
        )

        let status = try git(["status", "--porcelain", "--untracked-files=all"], in: repository)
        XCTAssertEqual(Set(status.split(separator: "\n").map(String.init)), [" M .DS_Store", "?? real.swift"])
    }

    func testFixtureIgnoresUntrackedFinderMetadataWithoutHidingRealFiles() throws {
        let repository = try makeWorkingRepository(name: "fixture-metadata-exclusion")
        let nested = repository.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: repository.appendingPathComponent(".DS_Store"))
        try Data([0, 1, 2]).write(to: nested.appendingPathComponent(".DS_Store"))
        try "real source\n".write(to: nested.appendingPathComponent("real.swift"), atomically: true, encoding: .utf8)
        try "real notes\n".write(to: repository.appendingPathComponent(".DS_Store.notes"), atomically: true, encoding: .utf8)

        let status = try git(["status", "--porcelain", "--untracked-files=all"], in: repository)
        XCTAssertEqual(Set(status.split(separator: "\n").map(String.init)), ["?? .DS_Store.notes", "?? nested/real.swift"])
    }

    func testFixtureMetadataExclusionPreservesExistingRulesAndIsIdempotent() throws {
        let repository = try makeWorkingRepository(name: "fixture-metadata-existing-rules")
        let exclude = repository.appendingPathComponent(".git/info/exclude")
        let existingRules = Data("private.log\n!keep.private.log\n".utf8)
        try existingRules.write(to: exclude)
        try GitXUITestRepositoryPolicy.excludeFinderMetadata(inRepositoryAtPath: repository.path)
        let combinedRules = try Data(contentsOf: exclude)
        XCTAssertTrue(combinedRules.starts(with: existingRules))
        try GitXUITestRepositoryPolicy.excludeFinderMetadata(inRepositoryAtPath: repository.path)
        XCTAssertEqual(try Data(contentsOf: exclude), combinedRules)

        for name in [".DS_Store", "private.log", "keep.private.log"] {
            try Data([0, 1, 2]).write(to: repository.appendingPathComponent(name))
        }
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: repository), "?? keep.private.log\n")
    }

    func testExistingMetadataRuleAnywhereInTheFileIsNotAppendedAgain() throws {
        let repository = try makeWorkingRepository(name: "existing-rule")
        let exclude = repository.appendingPathComponent(".git/info/exclude")
        for text in [".DS_Store\nprivate.log\n", "private.log\n.DS_Store", "private.log\r\n.DS_Store\r\n"] {
            let bytes = Data(text.utf8)
            try bytes.write(to: exclude)
            try GitXUITestRepositoryPolicy.excludeFinderMetadata(inRepositoryAtPath: repository.path)
            XCTAssertEqual(try Data(contentsOf: exclude), bytes)
        }
    }

    func testLinkedWorktreeUsesItsGitExcludeLocation() throws {
        let repository = try makeWorkingRepository(name: "main")
        let linked = try fixtureWorkspace.makeDirectory(named: "linked")
        try git(["worktree", "add", "--quiet", "-b", "linked", linked.path], in: repository)
        try GitXUITestRepositoryPolicy.excludeFinderMetadata(inRepositoryAtPath: linked.path)
        try Data([1, 2, 3]).write(to: linked.appendingPathComponent(".DS_Store"))
        try Data("real".utf8).write(to: linked.appendingPathComponent("real.txt"))
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: linked), "?? real.txt\n")
    }

    func testCloneCreationAppliesTheSameFixturePolicy() throws {
        let source = try makeWorkingRepository(name: "clone-source")
        let parent = try fixtureWorkspace.makeDirectory(named: "clone-parent")
        let clone = parent.appendingPathComponent("clone")
        try git(["clone", "--quiet", source.path, clone.path], in: parent)
        try Data([1, 2, 3]).write(to: clone.appendingPathComponent(".DS_Store"))
        try Data("real".utf8).write(to: clone.appendingPathComponent("real.txt"))
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: clone), "?? real.txt\n")
    }
}
