import Darwin
import Foundation
import XCTest

@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; all fixture ownership and observations stay on main.
final class IndexCommitPublicationTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var repository: GitXTestGitRepository!

    @MainActor private final class Observation {
        var completions = 0
        var failure: String?
    }

    override nonisolated func setUpWithError() throws {
        try MainActor.assumeIsolated { try prepareFixture() }
    }

    private func prepareFixture() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXCommitPublication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main"])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        try git(["config", "user.name", "GitX Test"])
        try git(["config", "user.email", "gitx-tests@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
    }

    override nonisolated func tearDownWithError() throws {
        try MainActor.assumeIsolated { try removeFixture() }
    }

    private func removeFixture() throws {
        repository = nil
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testDirectIndexDuplicateSubmissionHasOneCompletionAndOneMutation() throws {
        try seed()
        let oldHead = try git(["rev-parse", "HEAD"])
        try write("staged\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        let fifo = directory.appendingPathComponent(".git/release")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try hook("printf 'entered\\n' >> .git/entered\nread release < .git/release\n")
        repository = try GitXTestGitRepository(url: directory)
        let index = repository.index
        let observation = Observation()
        let finished = expectation(description: "single direct-index completion")
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name(PBGitIndexFinishedCommit), object: index, queue: .main) { _ in
            MainActor.assumeIsolated {
                observation.completions += 1
                if observation.completions == 1 {
                    finished.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        index.commit(withMessage: "First direct request", andVerify: true)
        XCTAssertTrue(observe { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(".git/entered").path) })
        XCTAssertTrue(index.submissionActive)
        index.commit(withMessage: "Rejected duplicate", andVerify: false)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), oldHead)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/COMMIT_EDITMSG"), encoding: .utf8), "First direct request")
        let writer = PBTask(launchPath: "/bin/sh", arguments: ["-c", "printf 'release\\n' > .git/release"], inDirectory: directory.path)
        try writer.launch()
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(observe { !index.mutationReconciliationPending && !index.submissionActive })
        XCTAssertEqual(observation.completions, 1)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "First direct request")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/entered"), encoding: .utf8), "entered\n")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
    }

    func testFailedHookLeavesIndexChangesForTheOriginalVerificationSkippingRetry() throws {
        try seed()
        let original = try git(["rev-parse", "HEAD"])
        try write("submitted\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try hook("printf 'hook staged\\n' > tracked.txt\ngit add tracked.txt\nexit 1\n")
        repository = try GitXTestGitRepository(url: directory)
        let index = repository.index
        let failed = expectation(forNotification: Notification.Name(PBGitIndexCommitHookFailed), object: index)
        index.commit(withMessage: "Original retry message", andVerify: true)
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
        XCTAssertEqual(try git(["show", ":tracked.txt"]), "hook staged")
        XCTAssertTrue(index.awaitingHookDecision)
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedCommit), object: index)
        index.retryCommitWithoutVerification()
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(observe { !index.mutationReconciliationPending })
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "hook staged")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Original retry message")
        XCTAssertEqual(try git(["show", "-s", "--format=%P", "HEAD"]), original)
    }

    func testDirectIndexCanCreateAnUnbornCommit() throws {
        try write("initial\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        repository = try GitXTestGitRepository(url: directory)
        let finished = expectation(forNotification: Notification.Name(PBGitIndexFinishedCommit), object: repository.index)
        repository.index.commit(withMessage: "Initial direct request", andVerify: false)
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(observe { !self.repository.index.mutationReconciliationPending })
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1")
        XCTAssertEqual(try git(["show", "-s", "--format=%P", "HEAD"]), "")
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main")
    }

    private func seed() throws {
        try write("initial\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try git(["commit", "-q", "-m", "Initial"])
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func hook(_ body: String) throws {
        let path = directory.appendingPathComponent(".git/hooks/pre-commit")
        try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        try GitXTestGitFixture.run(arguments, in: directory).standardOutput.trimmingCharacters(in: .newlines)
    }

    private func observe(_ condition: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(10)
        while !condition(), Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
