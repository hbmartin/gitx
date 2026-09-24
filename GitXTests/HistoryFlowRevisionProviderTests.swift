import Darwin
import FlowDeltaCore
import Foundation
import XCTest

// swift6-safety-justification: XCTest owns the case lifetime; cross-task result state lives in the locked ResultBox.
final class HistoryFlowRevisionProviderTests: XCTestCase, @unchecked Sendable {
    private enum InvocationResult {
        case success(RevisionComparison)
        case failure(String)
    }

    // swift6-safety-justification: NSLock protects every read and mutation of the result and continuation.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: InvocationResult?
        private var continuation: CheckedContinuation<InvocationResult, Never>?

        func complete(_ result: InvocationResult) {
            lock.lock()
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.result = result
                lock.unlock()
            }
        }

        func value() async -> InvocationResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    self.result = nil
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

        init() throws {
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

        func write(_ data: Data, to path: String) throws {
            let destination = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
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
            process.arguments = ["-C", url.path] + arguments
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

    func testCancellationTerminatesTheRunningGitProcess() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let started = fixture.url.appendingPathComponent("started")
        let terminated = fixture.url.appendingPathComponent("terminated")
        let executable = try makeExecutableScript(
            in: fixture,
            body: """
            trap 'touch '\"'\"'\(terminated.path)'\"'\"'; exit 143' TERM
            touch '\(started.path)'
            while :; do sleep 1; done
            """
        )
        let invocation = startComparison(repositoryURL: fixture.url, gitExecutableURL: executable)
        try await waitForFile(started)

        invocation.operation.cancel()
        let result = await invocation.result.value()

        guard case let .failure(message) = result else {
            return XCTFail("Expected cancellation, received \(result)")
        }
        XCTAssertTrue(message.contains("CancellationError"), message)
        try await waitForFile(terminated)
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
