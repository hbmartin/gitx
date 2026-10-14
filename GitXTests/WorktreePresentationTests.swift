import AppKit
import GitXCore
import XCTest

@MainActor
final class WorktreePresentationTests: XCTestCase {
    func testQueuedGenericGitFailureIsPresentedInItsLiveOriginWindowAndReleasesSharedFIFO() async throws {
        let defaults = UserDefaults.standard
        let previousGit = defaults.object(forKey: "gitExecutable")
        defaults.set("/usr/bin/git", forKey: "gitExecutable")
        defer {
            defaults.set(previousGit, forKey: "gitExecutable")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let blocker = try await installService(in: fixture, holdsWriter: true)
        let origin = try await installService(in: fixture)
        let following = try await installService(in: fixture)
        let controller = RecordingWindowController()
        controller.repository = origin.repository
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
            }
            controller.close()
        }
        let initial = try fixture.ownershipProof()
        let tree = try XCTUnwrap(origin.service.worktree(forBranch: "refs/heads/topic"))
        XCTAssertTrue(tree.isLocked)
        let item = NSMenuItem()
        item.representedObject = tree
        let blockerCompleted = expectation(description: "controlled writer released")
        blockerCompleted.assertForOverFulfill = true
        let followingCompleted = expectation(description: "following real writer reconciled")
        followingCompleted.assertForOverFulfill = true
        enqueue(blocker.service, command: .lock(path: fixture.linked.path, reason: "barrier")) { _, error in
            XCTAssertNil(error)
            blockerCompleted.fulfill()
        }
        XCTAssertTrue(blocker.gate.writer.isPending)
        XCTAssertFalse(blocker.gate.writer.wasCancelled)
        controller.unlockWorktree(item)
        enqueue(following.service, command: .lock(path: fixture.linked.path, reason: "following")) { _, error in
            XCTAssertNil(error)
            followingCompleted.fulfill()
        }
        XCTAssertFalse(origin.gate.commands.contains(["worktree", "unlock", tree.path]))
        XCTAssertNil(window.attachedSheet)
        // Admission used the captured locked row. A competing real Git command
        // removes that lock while the UI mutation is waiting behind the writer.
        _ = try fixture.git(["worktree", "unlock", fixture.linked.path])
        blocker.gate.writer.finish(Data())
        await fulfillment(of: [blockerCompleted, followingCompleted], timeout: 15)
        await waitUntil { controller.errors.count == 1 && window.attachedSheet != nil }
        let error = try XCTUnwrap(controller.errors.first)
        XCTAssertEqual(error.domain, "PBGitXErrorDomain")
        XCTAssertTrue(error.localizedFailureReason?.contains("not locked") == true, "Expected the real queued Git failure: \(error)")
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheetText(sheet).contains("not locked"))
        try attachScreenshot(of: sheet, named: "Worktrees-Live-Queued-Git-Failure")
        XCTAssertEqual(try fixture.ownershipProof(), initial)
        XCTAssertEqual(following.service.worktree(forBranch: "refs/heads/topic")?.lockReason, "following")
        XCTAssertTrue(following.service.worktree(forBranch: "refs/heads/topic")?.isLocked == true)
        XCTAssertEqual(origin.gate.commands.filter { $0 == ["worktree", "unlock", tree.path] }.count, 1)
        XCTAssertEqual(following.gate.commands.filter { $0 == ["worktree", "lock", "--reason", "following", fixture.linked.path] }.count, 1)
        window.endSheet(sheet, returnCode: .OK)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(controller.errors.count, 1)
    }

    private func enqueue(_ service: PBRepositoryWorktreeService, command: WorktreeCommand, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        guard case let .lock(path, reason) = command else {
            XCTFail("The characterization queues locks through the public compatibility facade")
            return
        }
        service.lockWorktree(path: path, reason: reason) { output, error in
            // swift6-safety-justification: The service delivers lifecycle completion on the main queue.
            MainActor.assumeIsolated { completion(output, error as NSError?) }
        }
    }

    private func installService(in fixture: Fixture, holdsWriter: Bool = false) async throws -> InstalledService {
        let repository = try RepositoryTestGitRepository(url: fixture.main)
        let original = try XCTUnwrap(repository.worktreeService)
        original.cancel()
        let gate = TaskGate(fixture: fixture, holdsWriter: holdsWriter)
        let service = PBRepositoryWorktreeService(repository: repository, taskFactory: gate.makeTask)
        repository.setValue(service, forKey: "worktreeService")
        XCTAssertTrue(repository.worktreeService === service)
        let installed = InstalledService(repository: repository, service: service, gate: gate)
        fixture.services.append(installed)
        service.start()
        await waitUntil { service.isSupported && !service.worktrees.isEmpty }
        return installed
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func sheetText(_ sheet: NSWindow) -> String {
        descendants(sheet.contentView).compactMap { view in
            if let field = view as? NSTextField {
                return field.stringValue
            }
            return (view as? NSTextView)?.string
        }.joined(separator: "\n")
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private final class RecordingWindowController: PBGitWindowController {
        private(set) var errors: [NSError] = []

        override func showErrorSheet(_ error: Error) {
            errors.append(error as NSError)
            super.showErrorSheet(error)
        }
    }

    private struct InstalledService {
        let repository: RepositoryTestGitRepository
        let service: PBRepositoryWorktreeService
        let gate: TaskGate
    }

    private final class TaskGate {
        let fixture: Fixture
        let writer = DeferredWriterTask()
        private var holdsWriter: Bool
        private(set) var commands: [[String]] = []

        init(fixture: Fixture, holdsWriter: Bool) {
            self.fixture = fixture
            self.holdsWriter = holdsWriter
        }

        func makeTask(_ arguments: [String]) -> PBTask {
            commands.append(arguments)
            if holdsWriter, arguments == ["worktree", "lock", "--reason", "barrier", fixture.linked.path] {
                holdsWriter = false
                return writer
            }
            let task = PBTask(launchPath: "/usr/bin/git", arguments: ["--git-dir=" + fixture.main.appendingPathComponent(".git").path] + arguments, inDirectory: fixture.main.path)
            GitXTestGitFixture.prepare(task)
            return task
        }
    }

    // swift6-safety-justification: The lock guards callback and cancellation state shared with PBTask's callback queues.
    private final nonisolated class DeferredWriterTask: PBTask, @unchecked Sendable {
        private let lock = NSLock()
        private var callback: ((Data?, Error?) -> Void)?
        private var cancelled = false

        override func perform(on _: DispatchQueue, completionHandler: @escaping (Data?, Error?) -> Void) {
            lock.lock(); callback = completionHandler; lock.unlock()
        }

        override func perform(on _: DispatchQueue, outputChunkHandler _: PBTaskOutputChunkHandler?, completionHandler: @escaping (Data?, Error?) -> Void) {
            lock.lock(); callback = completionHandler; lock.unlock()
        }

        override func terminate() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        var isPending: Bool {
            lock.lock(); defer { lock.unlock() }; return callback != nil
        }

        func finish(_ data: Data?, error: Error? = nil) {
            lock.lock(); let callback = callback; self.callback = nil; lock.unlock()
            callback?(data, error)
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let main: URL
        let linked: URL
        var services: [InstalledService] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-worktree-presentation-\(UUID().uuidString)")
            main = root.appendingPathComponent("main")
            linked = root.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Presentation Fixture"])
            _ = try git(["config", "user.email", "fixture@gitx.invalid"])
            try "original\n".write(to: main.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
            _ = try git(["add", "content.txt"])
            _ = try git(["commit", "-m", "fixture"])
            _ = try git(["worktree", "add", "-b", "topic", linked.path])
            _ = try git(["worktree", "lock", linked.path])
        }

        @discardableResult
        func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
            try GitXTestGitFixture.run(arguments, in: directory ?? main).standardOutput
        }

        func ownershipProof() throws -> [String: Data] {
            let administrative = try URL(fileURLWithPath: git(["rev-parse", "--absolute-git-dir"], in: linked).trimmingCharacters(in: .whitespacesAndNewlines))
            var proof = try Dictionary(uniqueKeysWithValues: ["HEAD", "index", "gitdir", "commondir"].map {
                try ($0, Data(contentsOf: administrative.appendingPathComponent($0)))
            })
            proof["mainHEAD"] = try Data(git(["rev-parse", "HEAD"]).utf8)
            proof["linkedHEAD"] = try Data(git(["rev-parse", "HEAD"], in: linked).utf8)
            proof["gitfile"] = try Data(contentsOf: linked.appendingPathComponent(".git"))
            proof["content"] = try Data(contentsOf: linked.appendingPathComponent("content.txt"))
            return proof
        }

        func cleanup() {
            services.forEach { $0.service.cancel() }
            services.forEach { $0.gate.writer.finish(nil, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
            services.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
