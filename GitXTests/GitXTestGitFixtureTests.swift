import Darwin
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

    func testVerificationOwnershipReachesAnEmptyUILaunchEnvironment() {
        let environment = GitXTestGitEnvironment.isolated([:], verificationSession: "verified-run")
        XCTAssertEqual(environment["GITX_VERIFICATION_SESSION"], "verified-run")
        XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        let unowned = GitXTestGitEnvironment.isolated([:], verificationSession: nil)
        XCTAssertNil(unowned["GITX_VERIFICATION_SESSION"])
    }

    func testNativeDiagnosticsReachAnEmptyUILaunchEnvironment() {
        let environment = GitXTestGitEnvironment.isolated([:], nativeDiagnosticDirectory: "/run/Logs/Native")
        XCTAssertEqual(environment["GITX_TEST_STDERR_DIRECTORY"], "/run/Logs/Native")
        let unowned = GitXTestGitEnvironment.isolated([:], nativeDiagnosticDirectory: nil)
        XCTAssertNil(unowned["GITX_TEST_STDERR_DIRECTORY"])
    }

    func testManagedObserverRegistersIdempotentlyInThisTestBundle() throws {
        GitXManagedTestObserver.install()
        GitXManagedTestObserver.install()
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"],
              let invocation = environment["GITX_TEST_INVOCATION_ID"] else { return }
        let records = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("startup-") }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
        XCTAssertTrue(records.contains {
            $0["event"] as? String == "bundle-start" && $0["invocationID"] as? String == invocation
                && $0["bundleID"] as? String == "net.phere.GitXTests"
        }, "The loading shim must register before the bundle-start callback, in Debug and Release")
    }

    func testFailureAttachmentsKeepOnlyRegularNativeFilesAndPreserveOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let native = directory.appendingPathComponent("GitX-42-fixture.stderr.log")
        let bytes = Data(repeating: 255, count: 70000)
        try bytes.write(to: native)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.stderr.log"), withDestinationURL: native)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.stderr.log"), withIntermediateDirectories: true)
        let attachments = GitXManagedTestObserver.failureAttachments(in: directory.path)
        XCTAssertEqual(attachments.count, 1)
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.name, "Native stderr tail: GitX-42-fixture.stderr.log [4464..<70000]")
        XCTAssertEqual(attachment.lifetime, .keepAlways)
        XCTAssertEqual(try Data(contentsOf: native), bytes)
        XCTAssertTrue(GitXManagedTestObserver.failureAttachments(in: nil).isEmpty)
        XCTAssertTrue(GitXManagedTestObserver.failureAttachments(in: "").isEmpty)
    }

    func testNativeFailureAttachmentsRetainNewTailBytesOnceWithinCaseBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let source = directory.appendingPathComponent("GitX-42-a.stderr.log")
        let prefix = Data(repeating: 65, count: 70000)
        let sentinel = Data([0, 255]) + Data("AddressSanitizer: tail\ncrash-output: tail\n".utf8)
        let original = prefix + sentinel
        try original.write(to: source)
        var state = GitXManagedTestObserver.AttachmentState()
        let first = try XCTUnwrap(state.take(in: directory.path).first)
        XCTAssertEqual(first.data, original.suffix(65536))
        XCTAssertEqual(first.end, Int64(original.count))
        XCTAssertTrue(state.take(in: directory.path).isEmpty)
        let handle = try FileHandle(forWritingTo: source)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("next-issue".utf8))
        try handle.close()
        let next = try XCTUnwrap(state.take(in: directory.path).first)
        XCTAssertEqual(next.start, Int64(original.count))
        XCTAssertEqual(next.data, Data("next-issue".utf8))
        for pid in 43 ... 50 {
            try Data(repeating: UInt8(pid), count: 70000).write(to: directory.appendingPathComponent("GitX-\(pid)-a.stderr.log"))
        }
        let remaining = state.take(in: directory.path)
        XCTAssertTrue(remaining.allSatisfy { $0.data.count <= 65536 })
        XCTAssertEqual(state.retainedBytes, 262144)
        XCTAssertTrue(state.take(in: directory.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original + Data("next-issue".utf8))
        var independentCase = GitXManagedTestObserver.AttachmentState()
        XCTAssertFalse(independentCase.take(in: directory.path).isEmpty)
    }

    func testProgressPublicationLeavesOnlyCompleteDistinctRecordsAndPreservesEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let sentinel = directory.appendingPathComponent("startup-existing.json")
        try Data("keep-existing".utf8).write(to: sentinel)
        let record: [String: Any] = ["schemaVersion": 1, "event": "bundle-start", "invocationID": "fixture"]
        let first = try GitXTestProgressRecords.write(record, prefix: "startup", directory: directory.path)
        let second = try GitXTestProgressRecords.write(record, prefix: "startup", directory: directory.path)
        XCTAssertNotEqual(first, second)
        for file in [first, second] {
            let published = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(published["event"] as? String, "bundle-start")
            XCTAssertEqual(published["invocationID"] as? String, "fixture")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep-existing".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testProgressSerializationFailureLeavesNoPartialEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        XCTAssertThrowsError(try GitXTestProgressRecords.write(
            ["unsupported": Date()], prefix: "startup", directory: directory.path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testProgressPublicationPreservesSystemOperationAndErrno() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        for operation in ["write-record", "publish-record"] {
            XCTAssertThrowsError(try GitXTestProgressRecords.write(
                ["event": "bundle-start"], prefix: "startup", directory: directory.path,
                writeBytes: { descriptor, bytes, count in
                    if operation == "write-record" { errno = ENOSPC; return -1 }
                    return Darwin.write(descriptor, bytes, count)
                },
                publish: { _, _, _ in errno = EACCES; return -1 }
            )) { error in
                let failure = error as? GitXTestProgressRecords.PublicationError
                XCTAssertEqual(failure?.operation, operation)
                XCTAssertEqual(failure?.category, "system")
                XCTAssertEqual(failure?.posixCode, operation == "write-record" ? ENOSPC : EACCES)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testProgressExclusiveRenamePreservesCollisionAndRetriesInterruptedPartialWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let identity = UUID().uuidString
        let destination = directory.appendingPathComponent("startup-\(getpid())-\(identity).json")
        let original = Data("existing-record".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try GitXTestProgressRecords.write(
            ["event": "bundle-start"], prefix: "startup", directory: directory.path, identity: identity
        )) { error in
            XCTAssertEqual((error as? GitXTestProgressRecords.PublicationError)?.posixCode, EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        var attempts = 0
        let published = try GitXTestProgressRecords.write(
            ["event": "bundle-start"], prefix: "startup", directory: directory.path,
            writeBytes: { descriptor, bytes, count in
                attempts += 1
                if attempts == 1 { errno = EINTR; return -1 }
                return Darwin.write(descriptor, bytes, min(count, 3))
            }
        )
        XCTAssertGreaterThan(attempts, 2)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: published)) as? [String: String])
        XCTAssertEqual(record["event"], "bundle-start")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testManagedStartupFailureIsTakenBeforeRecursiveIssueDelivery() {
        var state = GitXManagedTestObserver.StartupState()
        state.failure = .init(operation: "publish-record", category: "system", posixCode: ENOSPC)
        XCTAssertEqual(state.takeFailure()?.posixCode, ENOSPC)
        XCTAssertNil(state.takeFailure())
    }

    func testEmptyDiagnosticRequestsAreRemovedAndProgressSurvivesEmptyLaunchEnvironment() {
        let empty = GitXTestGitEnvironment.isolated(
            ["GITX_TEST_STDERR_DIRECTORY": "/previous", "GITX_TEST_PROGRESS_DIRECTORY": "/previous", "GITX_TEST_INVOCATION_ID": "old"],
            nativeDiagnosticDirectory: "", progressDirectory: "", invocationID: ""
        )
        XCTAssertNil(empty["GITX_TEST_STDERR_DIRECTORY"])
        XCTAssertNil(empty["GITX_TEST_PROGRESS_DIRECTORY"])
        XCTAssertNil(empty["GITX_TEST_INVOCATION_ID"])
        let progress = GitXTestGitEnvironment.isolated(
            [:], nativeDiagnosticDirectory: nil, progressDirectory: "/fixture/progress", invocationID: "invocation-1"
        )
        XCTAssertEqual(progress["GITX_TEST_PROGRESS_DIRECTORY"], "/fixture/progress")
        XCTAssertEqual(progress["GITX_TEST_INVOCATION_ID"], "invocation-1")
    }

    func testExplicitNativeDirectoryAndSessionRemainLiteralAcrossRepeatedIsolation() {
        let directory = "/fixture/cache with spaces/Native"
        let first = GitXTestGitEnvironment.isolated(
            ["PATH": "/fixture/tools"], verificationSession: "run-1", nativeDiagnosticDirectory: directory
        )
        let second = GitXTestGitEnvironment.isolated(
            first, verificationSession: "run-1", nativeDiagnosticDirectory: directory
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(second["GITX_TEST_STDERR_DIRECTORY"], directory)
        XCTAssertEqual(second["GITX_VERIFICATION_SESSION"], "run-1")
        XCTAssertEqual(second["PATH"], "/fixture/tools")
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

    func testFixtureRunnerStoresBinaryStandardInputWithoutChangingItsBytes() throws {
        let directory = try makeRepository()
        let data = Data([0, 0xFF, 0x0A, 0x7F])
        let object = try GitXTestGitFixture.run(["hash-object", "-w", "--stdin"], in: directory, standardInput: data)
            .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let read = PBTask(launchPath: "/usr/bin/git", arguments: ["cat-file", "blob", object], inDirectory: directory.path)
        GitXTestGitFixture.prepare(read)
        try read.launch()
        XCTAssertEqual(read.standardOutputData, data)
    }

    @MainActor
    func testFixtureRepositoryTasksKeepExplicitOverridesAndTheirOriginalTimeout() throws {
        let directory = try makeRepository()
        let repository = try GitXTestGitRepository(url: directory)
        defer { repository.revisionList?.cleanup() }
        let task = repository.task(withArguments: ["-c", "alias.fixture-value=!printf '%s' \"$GITX_FIXTURE_TASK_VALUE\"", "fixture-value"])
        task.additionalEnvironment = ["GITX_FIXTURE_TASK_VALUE": "explicit literal value"]
        XCTAssertEqual(task.timeout, 30)
        try task.launch()
        XCTAssertEqual(task.standardOutputString(), "explicit literal value")
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Fixture-Runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try GitXTestGitFixture.run(["init", "--quiet", "--initial-branch=main"], in: directory)
        return directory
    }
}
