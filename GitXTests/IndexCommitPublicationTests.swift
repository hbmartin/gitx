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
        // swift6-safety-justification: XCTest lifecycle and notification callbacks execute synchronously on the main thread; fixture state remains MainActor-isolated.
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
        // swift6-safety-justification: XCTest lifecycle and notification callbacks execute synchronously on the main thread; fixture state remains MainActor-isolated.
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
            // swift6-safety-justification: XCTest lifecycle and notification callbacks execute synchronously on the main thread; fixture state remains MainActor-isolated.
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

    func testFreshParentsIgnoreTheRepositoryHeadCache() throws {
        try seed()
        repository = try GitXTestGitRepository(url: directory)
        _ = repository.headOID
        try git(["commit", "-q", "--allow-empty", "-m", "External advance"])
        let fresh = try git(["rev-parse", "HEAD"])
        try write("new submission\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try submitAndSettle("Fresh parents", verify: false)
        XCTAssertEqual(try git(["show", "-s", "--format=%P", "HEAD"]), fresh)
    }

    func testSuccessfulVerificationHookChangesBelongToTheFinalTree() throws {
        try seed()
        try write("before hook\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try hook("printf 'after hook\\n' > tracked.txt\ngit add tracked.txt\n")
        repository = try GitXTestGitRepository(url: directory)
        try submitAndSettle("Hook tree", verify: true)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "after hook")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
    }

    func testExternalHeadAdvanceDuringHooksCannotBeOverwritten() throws {
        try rejectMovement("git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'External advance'\n")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "External advance")
    }

    func testSameOIDBranchSwitchDuringHooksCannotReceiveTheCommit() throws {
        try rejectMovement("git branch other\ngit symbolic-ref HEAD refs/heads/other\n")
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/other")
        XCTAssertEqual(try git(["rev-parse", "main"]), try git(["rev-parse", "other"]))
    }

    func testSymbolicToDetachedMovementCannotReceiveTheCommit() throws {
        try rejectMovement("git update-ref --no-deref HEAD \"$(git rev-parse HEAD)\"\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"]))
    }

    func testDetachedToSymbolicMovementCannotReceiveTheCommit() throws {
        try rejectMovement("git symbolic-ref HEAD refs/heads/main\n", detached: true)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main")
    }

    func testUnbornBranchSwitchCannotReceiveTheCommit() throws {
        try rejectMovement("git symbolic-ref HEAD refs/heads/other\n", unborn: true)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/other")
        XCTAssertEqual(try git(["for-each-ref", "--format=%(refname)"]), "")
    }

    func testRetryAfterTargetMovementRetainsTheOriginalExpectation() throws {
        try seed()
        try write("submitted\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try hook("git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'External advance'\nexit 1\n")
        repository = try GitXTestGitRepository(url: directory)
        let failed = expectation(forNotification: Notification.Name(PBGitIndexCommitHookFailed), object: repository.index)
        repository.index.commit(withMessage: "Original retry request", andVerify: true)
        wait(for: [failed], timeout: 10)
        let advanced = try git(["rev-parse", "HEAD"])
        let observation = Observation()
        let observer = failureObserver { observation.failure = $0 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let retained = try XCTUnwrap(repository.index.value(forKey: "retainedCommitRequest") as? PBIndexCommitRequest)
        XCTAssertEqual(retained.message, "Original retry request")
        repository.index.retryCommitWithoutVerification()
        XCTAssertTrue(observe { !self.repository.index.submissionActive })
        XCTAssertTrue(observe { !self.repository.index.mutationReconciliationPending })
        XCTAssertNotNil(observation.failure)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), advanced)
    }

    func testFreshMergeParentsAreIncludedAndAmendKeepsThem() throws {
        try seed()
        let base = try git(["rev-parse", "HEAD"])
        let tree = try git(["write-tree"])
        let other = try GitXTestGitFixture.run(["commit-tree", tree, "-p", base], in: directory, standardInput: Data("Other parent\n".utf8)).standardOutput.trimmingCharacters(in: .newlines)
        try write(other + "\n", to: ".git/MERGE_HEAD")
        try write("merge message\n", to: ".git/MERGE_MSG")
        try write("no-ff\n", to: ".git/MERGE_MODE")
        repository = try GitXTestGitRepository(url: directory)
        try submitAndSettle("Merge parents", verify: false)
        XCTAssertEqual(try git(["show", "-s", "--format=%P", "HEAD"]), base + " " + other)
        for marker in ["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/" + marker).path))
        }
        repository.index.isAmend = true
        XCTAssertTrue(observe { !self.repository.index.mutationReconciliationPending })
        try submitAndSettle("Amended merge", verify: false)
        XCTAssertEqual(try git(["show", "-s", "--format=%P", "HEAD"]), base + " " + other)
    }

    func testHookChangingMergeStateRefusesPublicationAndPreservesItsMarkers() throws {
        try seed()
        let original = try git(["rev-parse", "HEAD"])
        try write(original + "\n", to: ".git/MERGE_HEAD")
        try write("original merge\n", to: ".git/MERGE_MSG")
        try hook("printf 'changed merge\\n' > .git/MERGE_MSG")
        repository = try GitXTestGitRepository(url: directory)
        let observation = Observation()
        let observer = failureObserver { observation.failure = $0 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try submitAndSettle("Changed merge state", verify: true)
        XCTAssertNotNil(observation.failure)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8), "changed merge\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    func testInvalidMergeParentBytesRefusePublicationAndPreservePreparedState() throws {
        try seed()
        let original = try git(["rev-parse", "HEAD"])
        repository = try GitXTestGitRepository(url: directory)
        let observation = Observation()
        let observer = failureObserver { observation.failure = $0 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for marker in [Data([255]), Data("not-an-object-id\n".utf8)] {
            observation.failure = nil
            try marker.write(to: directory.appendingPathComponent(".git/MERGE_HEAD"))
            try submitAndSettle("Invalid merge parent", verify: false)
            XCTAssertNotNil(observation.failure)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/MERGE_HEAD")), marker)
        }
    }

    func testCancellingAnOwnedPreparedTransactionReleasesAllReferenceLocks() throws {
        try seed()
        let original = try git(["rev-parse", "HEAD"])
        try write("staged\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        let fifo = directory.appendingPathComponent(".git/reference-release")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let referenceHook = directory.appendingPathComponent(".git/hooks/reference-transaction")
        try "#!/bin/sh\nif [ \"$1\" = prepared ]; then printf 'prepared\\n' > .git/reference-ready; read release < .git/reference-release; fi\n".write(to: referenceHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: referenceHook.path)
        repository = try GitXTestGitRepository(url: directory)
        repository.index.commit(withMessage: "Cancelled publication", andVerify: false)
        XCTAssertTrue(observe { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(".git/reference-ready").path) })
        repository.index.cancelCommitSubmission()
        XCTAssertTrue(observe { !self.repository.index.submissionActive && !self.repository.index.mutationReconciliationPending })
        XCTAssertTrue(observe { !FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(".git/HEAD.lock").path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/refs/heads/main.lock").path))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
    }

    private func rejectMovement(_ body: String, detached: Bool = false, unborn: Bool = false) throws {
        if !unborn {
            try seed()
        }
        if detached {
            try git(["checkout", "-q", "--detach"])
        }
        try write("staged\n", to: "tracked.txt")
        try git(["add", "tracked.txt"])
        try hook(body)
        repository = try GitXTestGitRepository(url: directory)
        let observation = Observation()
        let failed = failureObserver { observation.failure = $0 }
        // swift6-safety-justification: XCTest lifecycle and notification callbacks execute synchronously on the main thread; fixture state remains MainActor-isolated.
        let finished = NotificationCenter.default.addObserver(forName: Notification.Name(PBGitIndexFinishedCommit), object: repository.index, queue: .main) { _ in MainActor.assumeIsolated { observation.completions += 1 } }
        defer { NotificationCenter.default.removeObserver(failed); NotificationCenter.default.removeObserver(finished) }
        try submitAndSettle("Rejected moved target", verify: true)
        XCTAssertNotNil(observation.failure)
        XCTAssertEqual(observation.completions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/HEAD.lock").path))
    }

    private func submitAndSettle(_ message: String, verify: Bool) throws {
        repository.index.commit(withMessage: message, andVerify: verify)
        XCTAssertTrue(observe { !self.repository.index.submissionActive })
        XCTAssertTrue(observe { !self.repository.index.mutationReconciliationPending })
    }

    private func failureObserver(_ callback: @escaping @MainActor @Sendable (String?) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: Notification.Name(PBGitIndexCommitFailed), object: repository.index, queue: .main) { notification in
            let description = notification.userInfo?["description"] as? String
            // swift6-safety-justification: XCTest lifecycle and notification callbacks execute synchronously on the main thread; fixture state remains MainActor-isolated.
            MainActor.assumeIsolated { callback(description) }
        }
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
