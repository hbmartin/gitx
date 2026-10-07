import XCTest

final class GitXTestGitFixtureTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSharedEnvironmentMatchesExistingFixturePolicyAndKeepsNonGitInputs() {
        let inherited = ["PATH": "/fixture/tools", "DEVELOPER_DIR": "/fixture/Xcode", "GIT_DIR": "/wrong", "GIT_CONFIG_PARAMETERS": "hostile"]
        let shared = GitXTestGitEnvironment.isolated(inherited)
        let existing = RepositoryTestGitEnvironment.isolated(inherited)
        for (key, value) in existing {
            XCTAssertEqual(shared[key], value, key)
        }
        XCTAssertEqual(shared["PATH"], inherited["PATH"])
        XCTAssertEqual(shared["DEVELOPER_DIR"], inherited["DEVELOPER_DIR"])
        XCTAssertNil(shared["GIT_DIR"])
        XCTAssertNil(shared["GIT_CONFIG_PARAMETERS"])
        XCTAssertEqual(shared["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(shared["GCM_INTERACTIVE"], "never")
    }

    func testFixtureRunnerCommitsLiteralFilesAndPreservesIntentionalLocalHooks() throws {
        let directory = try makeRepository()
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf intentional-local-hook >&2\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let name = "Café $literal;file.txt"
        try "fixture\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try GitXTestGitFixture.run(["add", "--", name], in: directory)
        let commit = try GitXTestGitFixture.run(["commit", "--quiet", "-m", "Fixture"], in: directory)
        XCTAssertTrue(commit.standardOutput.isEmpty)
        XCTAssertTrue(commit.standardError.contains("intentional-local-hook"))
        XCTAssertEqual(try GitXTestGitFixture.run(["show", "HEAD:" + name], in: directory).standardOutput, "fixture\n")
        XCTAssertEqual(try GitXTestGitFixture.run(["log", "-1", "--format=%s"], in: directory).standardOutput, "Fixture\n")
    }

    func testFixtureRunnerReportsGitFailureWithSeparateDiagnostics() throws {
        let directory = try makeRepository()
        XCTAssertThrowsError(try GitXTestGitFixture.run(["show", "refs/heads/missing"], in: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing"))
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, PBTaskErrorDomain)
            XCTAssertEqual(underlying?.code, 4)
        }
    }

    func testFixtureRunnerDrainsBothStreamsBeyondPipeCapacity() throws {
        let directory = try makeRepository()
        let command = "!dd if=/dev/zero bs=98304 count=1 2>/dev/null; dd if=/dev/zero bs=98304 count=1 >&2 2>/dev/null"
        let result = try GitXTestGitFixture.run(["-c", "alias.fixture-output=" + command, "fixture-output"], in: directory)
        XCTAssertEqual(result.standardOutput.utf8.count, 98304)
        XCTAssertFalse(result.standardError.isEmpty)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 65536)
    }

    func testFixtureRunnerBoundsAStalledGitAlias() throws {
        let directory = try makeRepository()
        XCTAssertThrowsError(try GitXTestGitFixture.run(
            ["-c", "alias.fixture-wait=!exec /bin/sleep 60", "fixture-wait"], in: directory, timeout: 0.2
        )) { error in
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, PBTaskErrorDomain)
            XCTAssertEqual(underlying?.code, 2)
        }
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Fixture-Runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try GitXTestGitFixture.run(["init", "--quiet", "--initial-branch=main"], in: directory)
        return directory
    }
}
