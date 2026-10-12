import AppKit
import XCTest

// swift6-safety-justification: The lock protects every callback, output, and cancellation access, including delivery from the discovery queue.
private final nonisolated class ControlledWorktreeTask: PBTask, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    private var cancelled = false

    override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
        lock.lock(); callback = completionHandler; lock.unlock()
    }

    override func terminate() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    func finish(_ data: Data?, error: Error? = nil) {
        lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
        callback?(data, error)
    }
}

@MainActor
final class WorktreeServiceTests: XCTestCase {
    private let snapshot = Data("worktree /main\0HEAD abc\0branch refs/heads/main\0\0worktree /linked\0HEAD def\0branch refs/heads/topic\0locked offline disk\0\0".utf8)

    func testCoalescesPublishesChangedSnapshotsOnMainAndRetainsFailure() async {
        let repository = PBGitRepository()
        var tasks: [ControlledWorktreeTask] = []
        var requested = expectation(description: "initial discovery")
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            if arguments == ["--version"] {
                return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.48.0"], inDirectory: nil)
            }
            let task = ControlledWorktreeTask(); tasks.append(task); requested.fulfill(); return task
        }
        var publications = 0
        let changed = expectation(description: "snapshot publication")
        let observation = service.observe(\.worktrees) { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            // swift6-safety-justification: The assertion above verifies discovery publishes this KVO callback on the main thread.
            MainActor.assumeIsolated { publications += 1; changed.fulfill() }
        }
        defer { observation.invalidate(); service.cancel() }
        service.start()
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(service.isSupported)
        requested = expectation(description: "one coalesced discovery")
        service.refresh(); service.refresh(); service.refresh()
        XCTAssertEqual(tasks.count, 1)
        tasks[0].finish(snapshot)
        await fulfillment(of: [changed, requested], timeout: 5)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(service.worktree(forBranch: "refs/heads/topic")?.path, "/linked")
        XCTAssertNil(service.worktree(forBranch: "refs/heads/missing"))
        tasks[1].finish(snapshot)
        await drainMainQueue()
        XCTAssertEqual(publications, 1)
        requested = expectation(description: "failure discovery")
        service.refresh()
        await fulfillment(of: [requested], timeout: 5)
        tasks[2].finish(Data("malformed".utf8))
        await drainMainQueue()
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(publications, 1)
        requested = expectation(description: "Git error discovery")
        service.refresh()
        await fulfillment(of: [requested], timeout: 5)
        tasks[3].finish(nil, error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Git refused discovery"]))
        await drainMainQueue()
        XCTAssertEqual(service.worktrees.count, 2)
        XCTAssertEqual(publications, 1)
    }

    func testCancelTerminatesPendingDiscoveryAndRejectsLateCompletion() async {
        let repository = PBGitRepository()
        let task = ControlledWorktreeTask()
        let requested = expectation(description: "discovery requested")
        let service = PBRepositoryWorktreeService(repository: repository) { arguments in
            if arguments == ["--version"] {
                return PBTask(launchPath: "/bin/echo", arguments: ["git version 2.54.0"], inDirectory: nil)
            }
            requested.fulfill(); return task
        }
        service.start(); service.start()
        await fulfillment(of: [requested], timeout: 5)
        service.refresh(); service.cancel()
        XCTAssertTrue(task.wasCancelled)
        task.finish(snapshot)
        service.refresh()
        await drainMainQueue()
        XCTAssertTrue(service.worktrees.isEmpty)
        XCTAssertNil(service.worktree(forBranch: "refs/heads/topic"))
    }

    func testOldAndUnavailableGitDisableDiscoveryAndExplainMinimum() async {
        for version in ["git version 2.47.9", "not Git"] {
            let repository = PBGitRepository()
            let checked = expectation(description: "version checked")
            let service = PBRepositoryWorktreeService(repository: repository) { arguments in
                XCTAssertEqual(arguments, ["--version"])
                return PBTask(launchPath: "/bin/echo", arguments: [version], inDirectory: nil)
            }
            let observation = service.observe(\.gitVersion) { _, _ in checked.fulfill() }
            service.start()
            await fulfillment(of: [checked], timeout: 5)
            XCTAssertFalse(service.isSupported)
            XCTAssertTrue(service.explanation.contains("Git 2.48"))
            service.refresh(); service.cancel(); observation.invalidate()
        }
    }

    func testWatchOwnershipSeparatesSharedReferencesAndSiblingIndexes() {
        let linked = PBRepositoryWatchPaths(gitDirectory: "/repo/.git/worktrees/one", commonDirectory: "/repo/.git", workingDirectory: "/linked")
        for path in ["/repo/.git/worktrees/one/HEAD", "/repo/.git/worktrees/one/index"] {
            XCTAssertEqual(linked.category(for: path), 1)
        }
        for path in ["/repo/.git/refs/heads/main", "/repo/.git/worktrees/two/HEAD", "/repo/.git/worktrees"] {
            XCTAssertEqual(linked.category(for: path), 2)
        }
        for path in ["/repo/.git/index", "/repo/.git/worktrees/two/index", "/repo/.git/refs/main.lock", "/repo/.git/objects/abc", "/linked-other/file"] {
            XCTAssertEqual(linked.category(for: path), 0)
        }
        XCTAssertEqual(linked.category(for: "/linked/file"), 3)
        let main = PBRepositoryWatchPaths(gitDirectory: "/repo/.git", commonDirectory: "/repo/.git", workingDirectory: "/repo")
        XCTAssertEqual(main.category(for: "/repo/.git/index"), 1)
        XCTAssertEqual(main.category(for: "/repo/.git/worktrees/two/index"), 0)
        XCTAssertEqual(main.category(for: "/repo/.git/worktrees/two/HEAD"), 2)
        XCTAssertEqual(main.category(for: "/repo/.git/refs/main"), 2)
        XCTAssertEqual(main.category(for: "/repo/file"), 3)
        XCTAssertEqual(main.category(for: "/repo/.git/HEAD.lock"), 0)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue completion boundary")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }
}
