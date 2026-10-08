import Darwin
import FlowDeltaCore
import Foundation
import XCTest

// swift6-safety-justification: XCTest owns the case lifetime; cross-task result state lives in the locked ResultBox.
final class HistoryFlowRevisionProviderTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if !DEBUG
            throw XCTSkip("The revision-provider harness is compiled into the Debug app only.")
        #endif
    }

    private enum InvocationResult {
        case success(RevisionComparison)
        case failure(String)
    }

    // swift6-safety-justification: NSLock protects every read and mutation of the result and continuation.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: InvocationResult?
        private var continuation: CheckedContinuation<InvocationResult, Never>?
        let completed = XCTestExpectation(description: "Flow provider completed")

        var completedResult: InvocationResult? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func complete(_ result: InvocationResult) {
            lock.lock()
            self.result = result
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                lock.unlock()
            }
            completed.fulfill()
        }

        func value() async -> InvocationResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    private final class RepositoryFixture {
        let url: URL
        private let inheritedEnvironment: [String: String]

        init(inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
            self.inheritedEnvironment = inheritedEnvironment
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitx-history-flow-provider-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try git(["init", "-q"])
            _ = try git(["config", "user.name", "GitX Tests"])
            _ = try git(["config", "user.email", "gitx-tests@example.invalid"])
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }

        func write(_ contents: String, to path: String) throws {
            let destination = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: destination, atomically: true, encoding: .utf8)
        }

        @discardableResult
        func commit(_ message: String) throws -> String {
            _ = try git(["add", "-A"])
            _ = try git(["commit", "-q", "-m", message])
            return try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "-C", url.path,
                "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null",
            ] + arguments
            var environment = inheritedEnvironment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "HistoryFlowRevisionProviderTests.Git",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: text]
                )
            }
            return text
        }
    }

    func testFixtureGitIgnoresInheritedRepositorySelectors() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = "/nonexistent/gitx-fixture-git-dir"
        environment["GIT_WORK_TREE"] = "/nonexistent/gitx-fixture-work-tree"
        environment["GIT_INDEX_FILE"] = "/nonexistent/gitx-fixture-index"
        let fixture = try RepositoryFixture(inheritedEnvironment: environment)
        defer { fixture.remove() }

        try fixture.write("fixture\n", to: "File.txt")
        XCTAssertFalse(try fixture.commit("Commit under poisoned repository environment").isEmpty)
    }

    func testFixtureGitIgnoresInheritedSigningAndHooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-history-flow-poison-\(UUID().uuidString)", isDirectory: true)
        let hooks = root.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\nexit 55\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let globalConfig = root.appendingPathComponent("config")
        try "[commit]\n\tgpgsign = true\n[core]\n\thooksPath = \(hooks.path)\n"
            .write(to: globalConfig, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = globalConfig.path
        let fixture = try RepositoryFixture(inheritedEnvironment: environment)
        defer { fixture.remove() }

        try fixture.write("fixture\n", to: "File.txt")
        XCTAssertFalse(try fixture.commit("Commit without inherited signing or hooks").isEmpty)
    }

    func testRealRepositoryComparisonLoadsAddedDeletedModifiedAndRenamedFiles() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("let modified = 1\n", to: "Modified.swift")
        try fixture.write("let deleted = true\n", to: "Deleted.swift")
        try fixture.write("let renamed = true\n", to: "Before.swift")
        let base = try fixture.commit("base")
        try fixture.write("let modified = 2\n", to: "Modified.swift")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("Deleted.swift"))
        _ = try fixture.git(["mv", "Before.swift", "After.swift"])
        try fixture.write("let added = true\n", to: "Added.swift")
        let target = try fixture.commit("target")

        let comparison = try await successfulComparison(repositoryURL: fixture.url, base: base, target: target)
        let files = Dictionary(uniqueKeysWithValues: comparison.files.map { ($0.path, $0) })

        XCTAssertEqual(comparison.base.value, base)
        XCTAssertEqual(comparison.target.value, target)
        XCTAssertEqual(Set(files.keys), ["Added.swift", "After.swift", "Deleted.swift", "Modified.swift"])
        XCTAssertNil(files["Added.swift"]?.old)
        XCTAssertEqual(files["Added.swift"]?.new?.text, "let added = true\n")
        XCTAssertEqual(files["Deleted.swift"]?.old?.text, "let deleted = true\n")
        XCTAssertNil(files["Deleted.swift"]?.new)
        XCTAssertEqual(files["After.swift"]?.old?.path, "Before.swift")
        XCTAssertEqual(files["After.swift"]?.new?.path, "After.swift")
        XCTAssertEqual(files["Modified.swift"]?.old?.text, "let modified = 1\n")
        XCTAssertEqual(files["Modified.swift"]?.new?.text, "let modified = 2\n")
    }

    func testMissingRepositoryIsRejectedBeforeLaunchingGit() async {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-missing-history-flow-repository-\(UUID().uuidString)")

        let message = await failedComparison(repositoryURL: repositoryURL)

        XCTAssertEqual(message, "Git repository not found at \(repositoryURL.path).")
    }

    func testMissingGitExecutableReportsLaunchFailure() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let message = await failedComparison(
            repositoryURL: fixture.url,
            gitExecutableURL: fixture.url.appendingPathComponent("missing-git")
        )

        XCTAssertTrue(message.contains("Could not run"), message)
        XCTAssertTrue(message.contains("missing-git"), message)
    }

    func testGitFailureIncludesStatusArgumentsAndStderr() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeExecutableScript(
            in: fixture,
            body: "printf 'forced git failure' >&2\nexit 7"
        )

        let message = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: executable)

        XCTAssertTrue(message.contains("rev-parse --verify HEAD~1^{commit}"), message)
        XCTAssertTrue(message.contains("status 7"), message)
        XCTAssertTrue(message.contains("forced git failure"), message)
    }

    func testMalformedNameStatusIsRejected() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeGitShim(
            in: fixture,
            diffCommand: "printf 'R100\\0Old.swift\\0'"
        )

        let message = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: executable)

        XCTAssertEqual(message, "Git returned malformed NUL-delimited name-status data.")
    }

    func testNonUTF8NameStatusIsRejected() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeGitShim(
            in: fixture,
            diffCommand: "printf 'M\\0\\377\\0'"
        )

        let message = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: executable)

        XCTAssertEqual(message, "Git returned non-UTF-8 data for name status.")
    }

    func testNonUTF8RevisionAndBlobSizeMetadataAreRejected() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let invalidRevision = try makeExecutableScript(in: fixture, body: "printf '\\377'")
        let revisionMessage = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: invalidRevision)
        XCTAssertEqual(revisionMessage, "Git returned non-UTF-8 data for base revision.")

        let invalidBlobSize = try makeGitShim(
            in: fixture, name: "invalid-blob-size-git", diffCommand: "printf 'M\\0File.swift\\0'",
            catFileCommand: "printf '\\377'"
        )
        let sizeMessage = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: invalidBlobSize)
        XCTAssertEqual(sizeMessage, "Git returned non-UTF-8 data for blob size for File.swift.")
    }

    // The private pipe-drain harness is compiled only into Debug app builds.
    #if DEBUG
        func testPipeDescriptorFailuresRetainNoDataAndRequestOneProcessStop() throws {
            let writeOnly = open("/dev/null", O_WRONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(writeOnly, 0)
            defer {
                if writeOnly >= 0 {
                    Darwin.close(writeOnly)
                }
            }
            for descriptor in [-1, writeOnly] {
                let result = PBHistoryFlowRevisionProviderTestHarness.drainPipe(fileDescriptor: descriptor)
                XCTAssertEqual(result["data"] as? Data, Data())
                XCTAssertEqual(result["didExceedLimit"] as? Bool, false)
                XCTAssertEqual(result["stopCount"] as? Int, 1)
                let message = try XCTUnwrap(result["failure"] as? String)
                XCTAssertEqual(message, "Could not read git output: \(String(cString: strerror(EBADF)))")
            }
            XCTAssertGreaterThanOrEqual(fcntl(writeOnly, F_GETFD), 0, "The runner retains descriptor closure ownership")
        }

        func testBufferedPipeEOFAndOutputBoundariesPreserveBytesAndDescriptorOwnership() throws {
            for byteCount in [0, 1024, 1025] {
                let source = Pipe()
                defer { try? source.fileHandleForReading.close() }
                let bytes = Data((0 ..< byteCount).map { UInt8($0 % 251) })
                try source.fileHandleForWriting.write(contentsOf: bytes)
                try source.fileHandleForWriting.close()

                let descriptor = source.fileHandleForReading.fileDescriptor
                let result = PBHistoryFlowRevisionProviderTestHarness.drainPipe(fileDescriptor: descriptor)

                XCTAssertEqual(result["data"] as? Data, Data(bytes.prefix(1024)))
                XCTAssertEqual(result["didExceedLimit"] as? Bool, byteCount > 1024)
                XCTAssertEqual(result["stopCount"] as? Int, byteCount > 1024 ? 1 : 0)
                XCTAssertEqual(result["failure"] as? String, "")
                XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0, "The runner retains descriptor closure ownership")
            }
        }

    #endif

    func testChangedFileAndBlobLimitsAreEnforced() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("let value = 1\n", to: "Limit.swift")
        let base = try fixture.commit("base")
        try fixture.write("let value = 2\n", to: "Limit.swift")
        let target = try fixture.commit("target")

        let changedFileMessage = await failedComparison(
            repositoryURL: fixture.url,
            base: base,
            target: target,
            maximumChangedFiles: 0
        )
        let blobMessage = await failedComparison(
            repositoryURL: fixture.url,
            base: base,
            target: target,
            maximumBlobBytes: 1
        )

        XCTAssertEqual(changedFileMessage, "Revision changes 1 files, exceeding the limit of 0.")
        XCTAssertTrue(blobMessage.contains("Blob Limit.swift is"), blobMessage)
        XCTAssertTrue(blobMessage.contains("exceeding the limit of 1"), blobMessage)
    }

    func testInvalidBlobSizeAndNonUTF8BlobAreRejected() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let invalidSizeGit = try makeGitShim(
            in: fixture,
            diffCommand: "printf 'M\\0File.swift\\0'",
            catFileCommand: "printf 'not-a-size\\n'"
        )
        let invalidBlobGit = try makeGitShim(
            in: fixture,
            name: "invalid-blob-git",
            diffCommand: "printf 'M\\0File.swift\\0'",
            catFileCommand: "printf '1\\n'",
            showCommand: "printf '\\377'"
        )

        let invalidSizeMessage = await failedComparison(
            repositoryURL: fixture.url,
            gitExecutableURL: invalidSizeGit
        )
        let invalidBlobMessage = await failedComparison(
            repositoryURL: fixture.url,
            gitExecutableURL: invalidBlobGit
        )

        XCTAssertEqual(invalidSizeMessage, "Git returned an invalid size for File.swift: not-a-size")
        XCTAssertEqual(invalidBlobMessage, "Git returned non-UTF-8 data for File.swift.")
    }

    func testBlobOutputLimitMapsToBlobLimitError() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeGitShim(
            in: fixture,
            diffCommand: "printf 'M\\0File.swift\\0'",
            catFileCommand: "printf '1\\n'",
            showCommand: "printf 'too-large'"
        )

        let message = await failedComparison(
            repositoryURL: fixture.url,
            gitExecutableURL: executable,
            maximumBlobBytes: 2
        )

        XCTAssertEqual(message, "Blob File.swift is 3 bytes, exceeding the limit of 2.")
    }

    func testExcessiveStandardErrorDoesNotBecomeBlobLimitError() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeGitShim(
            in: fixture,
            diffCommand: "printf 'M\\0File.swift\\0'",
            catFileCommand: "printf '1\\n'",
            showCommand: "/usr/bin/head -c 65537 /dev/zero >&2"
        )

        let message = await failedComparison(
            repositoryURL: fixture.url,
            gitExecutableURL: executable,
            maximumBlobBytes: 2
        )

        XCTAssertEqual(message, "Git returned more than 65536 bytes of error output for blob File.swift.")
        XCTAssertFalse(message.contains("Blob File.swift is"))
    }

    func testCancellationTerminatesTheRunningGitProcess() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let started = fixture.url.appendingPathComponent("started")
        let terminated = fixture.url.appendingPathComponent("terminated")
        let record = fixture.url.appendingPathComponent("cancellation-pid")
        let executable = try makeExecutableScript(
            in: fixture,
            body: """
            trap 'printf terminated > '\"'\"'\(terminated.path)'\"'\"'; exit 143' TERM
            printf '%s\\n' "$$" > '\(record.path)'
            : > '\(started.path)'
            while :; do :; done
            """
        )
        defer { terminateRecordedProcesses(at: record) }
        let invocation = startComparison(repositoryURL: fixture.url, gitExecutableURL: executable)
        defer { invocation.operation.cancel() }
        try await waitForFile(started)
        let identifiers = try recordedProcessIdentifiers(at: record)
        XCTAssertEqual(identifiers.count, 1)

        invocation.operation.cancel()
        let result = try await boundedResult(of: invocation.result)

        guard case let .failure(message) = result else {
            return XCTFail("Expected cancellation, received \(result)")
        }
        XCTAssertTrue(message.contains("CancellationError"), message)
        try await waitForFile(terminated)
        XCTAssertEqual(try String(contentsOf: terminated, encoding: .utf8), "terminated")
        try await waitForTerminatedProcesses(identifiers)
    }

    func testOutputLimitsIncludeTheBoundaryAndDrainBufferedEOFData() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        for byteCount in [0, 128 * 1024] {
            let executable = try makeGitShim(
                in: fixture,
                name: "boundary-git-\(byteCount)",
                diffCommand: "printf 'M\\0File.swift\\0'",
                catFileCommand: "printf '\(byteCount + 4)\\n'",
                showCommand: """
                /usr/bin/head -c 65536 /dev/zero >&2 &
                errorProducer=$!
                \(byteCount == 0 ? ":" : "/usr/bin/head -c \(byteCount) /dev/zero")
                printf tail
                wait "$errorProducer"
                """
            )

            let comparison = try await successfulComparison(
                repositoryURL: fixture.url,
                gitExecutableURL: executable,
                maximumBlobBytes: byteCount + 4
            )

            XCTAssertEqual(comparison.files.first?.new?.text, String(repeating: "\0", count: byteCount) + "tail")
        }
    }

    func testRevisionOutputLimitReportsTheRevisionContext() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeExecutableScript(
            in: fixture,
            body: "exec /usr/bin/head -c 4097 /dev/zero"
        )

        let message = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: executable)

        XCTAssertEqual(message, "Git returned more than 4096 bytes for base revision.")
    }

    func testStderrAtItsLimitPreservesTheGitFailureDiagnostic() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let executable = try makeExecutableScript(
            in: fixture,
            body: "/usr/bin/head -c 65529 /dev/zero >&2\nprintf failure >&2\nexit 7"
        )

        let message = await failedComparison(repositoryURL: fixture.url, gitExecutableURL: executable)

        XCTAssertTrue(message.contains("status 7"))
        XCTAssertTrue(message.hasSuffix("failure"))
        XCTAssertFalse(message.contains("more than"))
    }

    func testCancellationKillsATermResistantLeaderAndDescendant() async throws {
        try await assertCancellationCleansUpProcessGroup(leaderExitsFirst: false)
    }

    func testCancellationBeforeLaunchNeverRunsTheConfiguredExecutable() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let started = fixture.url.appendingPathComponent("unexpected-launch")
        let executable = try makeExecutableScript(in: fixture, body: "touch '\(started.path)'")
        let result = ResultBox()
        #if DEBUG
            let operation = PBHistoryFlowRevisionProviderTestHarness.cancelledBeforeLaunch(
                gitExecutableURL: executable
            ) { message in
                result.complete(.failure(message ?? "Unexpected launch success"))
            }
            defer { operation.cancel() }
        #endif

        guard case let .failure(message) = try await boundedResult(of: result) else {
            return XCTFail("Expected cancellation before launch")
        }
        XCTAssertTrue(message.contains("CancellationError"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
    }

    func testCancellationAfterLeaderExitKillsTheInheritedPipeHolder() async throws {
        try await assertCancellationCleansUpProcessGroup(leaderExitsFirst: true)
    }

    func testRepeatedOutputOverflowKillsTheWholeProducerGroup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        for iteration in 0 ..< 3 {
            let record = fixture.url.appendingPathComponent("producer-pids-\(iteration)")
            let release = fixture.url.appendingPathComponent("producer-release-\(iteration)")
            let executable = try makeGitShim(
                in: fixture,
                name: "overflow-git-\(iteration)",
                diffCommand: """
                trap '' TERM
                (
                    trap '' TERM
                    while [ ! -f '\(release.path)' ]; do /bin/sleep 0.01; done
                    exec /usr/bin/yes
                ) &
                producer=$!
                printf '%s\\n%s\\n' "$$" "$producer" > '\(record.path)'
                touch '\(release.path)'
                wait "$producer"
                """
            )
            defer { terminateRecordedProcesses(at: record) }
            let invocation = startComparison(repositoryURL: fixture.url, gitExecutableURL: executable)
            defer { invocation.operation.cancel() }

            guard case let .failure(message) = try await boundedResult(of: invocation.result) else {
                return XCTFail("Expected changed-file output overflow")
            }
            XCTAssertEqual(message, "Git returned more than 8388608 bytes for changed-file list.")
            let identifiers = try recordedProcessIdentifiers(at: record)
            XCTAssertEqual(identifiers.count, 2)
            try await waitForTerminatedProcesses(identifiers)
        }
    }

    private func assertCancellationCleansUpProcessGroup(leaderExitsFirst: Bool) async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let record = fixture.url.appendingPathComponent("cancellation-pids")
        let descendantReady = fixture.url.appendingPathComponent("descendant-ready")
        let ready = fixture.url.appendingPathComponent("cancellation-ready")
        let executable = try makeExecutableScript(
            in: fixture,
            body: """
            trap '' TERM
            (
                trap '' TERM
                touch '\(descendantReady.path)'
                exec /bin/sleep 60
            ) &
            child=$!
            printf '%s\\n%s\\n' "$$" "$child" > '\(record.path)'
            while [ ! -f '\(descendantReady.path)' ]; do /bin/sleep 0.01; done
            touch '\(ready.path)'
            \(leaderExitsFirst ? "exit 0" : "wait \"$child\"")
            """
        )
        defer { terminateRecordedProcesses(at: record) }
        let invocation = startComparison(repositoryURL: fixture.url, gitExecutableURL: executable)
        defer { invocation.operation.cancel() }
        try await waitForFile(ready)
        let identifiers = try recordedProcessIdentifiers(at: record)
        XCTAssertEqual(identifiers.count, 2)
        if leaderExitsFirst {
            let leader = try XCTUnwrap(identifiers.first)
            try await waitForCondition("leader exit while descendant retains pipes") { self.isZombie(leader) }
        }

        invocation.operation.cancel()
        invocation.operation.cancel()
        guard case let .failure(message) = try await boundedResult(of: invocation.result) else {
            return XCTFail("Expected process-group cancellation")
        }
        XCTAssertTrue(message.contains("CancellationError"), message)
        try await waitForTerminatedProcesses(identifiers)
    }

    private func boundedResult(of box: ResultBox) async throws -> InvocationResult {
        await fulfillment(of: [box.completed], timeout: 5)
        return try XCTUnwrap(box.completedResult)
    }

    private func recordedProcessIdentifiers(at record: URL) throws -> [pid_t] {
        try String(contentsOf: record, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    private func terminateRecordedProcesses(at record: URL) {
        for identifier in (try? recordedProcessIdentifiers(at: record)) ?? [] where identifier > 1 {
            kill(identifier, SIGKILL)
        }
    }

    private func isZombie(_ identifier: pid_t) -> Bool {
        // libproc may refuse information for zombies. waitid observes our
        // direct child without reaping the identity held by the supervisor.
        var status = siginfo_t()
        if waitid(P_PID, id_t(identifier), &status, WEXITED | WNOHANG | WNOWAIT) == 0,
           status.si_pid == identifier
        {
            return [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(status.si_code)
        }
        var information = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &information, Int32(size))
        return count == size && information.pbi_status == UInt32(SZOMB)
    }

    private func waitForTerminatedProcesses(_ identifiers: [pid_t]) async throws {
        try await waitForCondition("recorded git process group to terminate") {
            identifiers.allSatisfy { kill($0, 0) != 0 || self.isZombie($0) }
        }
        // The supervised leader must be reaped, not merely stopped as a zombie.
        if let leader = identifiers.first {
            XCTAssertNotEqual(kill(leader, 0), 0)
        }
    }

    private func waitForCondition(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(
                    domain: "HistoryFlowRevisionProviderTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func successfulComparison(
        repositoryURL: URL,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        base: String = "HEAD~1",
        target: String = "HEAD",
        maximumChangedFiles: Int = 500,
        maximumBlobBytes: Int = 2 * 1024 * 1024
    ) async throws -> RevisionComparison {
        let result = await startComparison(
            repositoryURL: repositoryURL,
            gitExecutableURL: gitExecutableURL,
            base: base,
            target: target,
            maximumChangedFiles: maximumChangedFiles,
            maximumBlobBytes: maximumBlobBytes
        ).result.value()
        switch result {
        case let .success(comparison):
            return comparison
        case let .failure(message):
            throw NSError(
                domain: "HistoryFlowRevisionProviderTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func failedComparison(
        repositoryURL: URL,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        base: String = "HEAD~1",
        target: String = "HEAD",
        maximumChangedFiles: Int = 500,
        maximumBlobBytes: Int = 2 * 1024 * 1024
    ) async -> String {
        let result = await startComparison(
            repositoryURL: repositoryURL,
            gitExecutableURL: gitExecutableURL,
            base: base,
            target: target,
            maximumChangedFiles: maximumChangedFiles,
            maximumBlobBytes: maximumBlobBytes
        ).result.value()
        switch result {
        case let .failure(message):
            return message
        case let .success(comparison):
            XCTFail("Expected failure, received \(comparison)")
            return ""
        }
    }

    private func startComparison(
        repositoryURL: URL,
        gitExecutableURL: URL,
        base: String = "HEAD~1",
        target: String = "HEAD",
        maximumChangedFiles: Int = 500,
        maximumBlobBytes: Int = 2 * 1024 * 1024
    ) -> (operation: PBHistoryFlowRevisionProviderTestOperation, result: ResultBox) {
        #if DEBUG
            let result = ResultBox()
            let operation = PBHistoryFlowRevisionProviderTestHarness.compareRepository(
                at: repositoryURL,
                gitExecutableURL: gitExecutableURL,
                base: base,
                target: target,
                maximumChangedFiles: maximumChangedFiles,
                maximumBlobBytes: maximumBlobBytes
            ) { data, errorDescription in
                do {
                    if let data {
                        let comparison = try JSONDecoder().decode(RevisionComparison.self, from: data)
                        result.complete(.success(comparison))
                    } else {
                        result.complete(.failure(errorDescription ?? "Unknown provider failure"))
                    }
                } catch {
                    result.complete(.failure("Could not decode provider result: \(error)"))
                }
            }
            return (operation, result)
        #else
            preconditionFailure("setUpWithError skips this Debug-only harness in Release.")
        #endif
    }

    private func makeGitShim(
        in fixture: RepositoryFixture,
        name: String = "git-shim",
        diffCommand: String,
        catFileCommand: String = "printf '0\\n'",
        showCommand: String = "printf ''"
    ) throws -> URL {
        try makeExecutableScript(
            in: fixture,
            name: name,
            body: """
            case "$3" in
              rev-parse) printf '1111111111111111111111111111111111111111\\n' ;;
              diff) \(diffCommand) ;;
              cat-file) \(catFileCommand) ;;
              show) \(showCommand) ;;
              *) printf 'unexpected command: %s\\n' "$*" >&2; exit 9 ;;
            esac
            """
        )
    }

    private func makeExecutableScript(
        in fixture: RepositoryFixture,
        name: String = "git-shim",
        body: String
    ) throws -> URL {
        let path = fixture.url.appendingPathComponent(name)
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        guard chmod(path.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return path
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                throw NSError(
                    domain: "HistoryFlowRevisionProviderTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(url.path)"]
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
