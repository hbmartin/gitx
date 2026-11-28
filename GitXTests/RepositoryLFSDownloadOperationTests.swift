@testable import GitX
import GitXCore
import XCTest

/// The two-phase Git LFS download (ADR 0014): a fetch that Cancel stops, then a checkout that always finishes.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every fixture access stays on main.
final class RepositoryLFSDownloadOperationTests: XCTestCase, @unchecked Sendable {
    private typealias Phase = GitX.RepositoryLFSDownloadOperation.Phase

    private var directory: URL!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where the fixture directory is MainActor-isolated.
        try MainActor.assumeIsolated { try prepareFixture() }
    }

    override nonisolated func tearDownWithError() throws {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where the fixture directory is MainActor-isolated.
        MainActor.assumeIsolated { removeFixture() }
        try super.tearDownWithError()
    }

    private func prepareFixture() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSDownload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeFixture() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Fake git-lfs

    /// A stand-in for `git` that records each invocation's arguments, one per line, separated by U+001F.
    private struct FakeGit {
        let executable: URL
        let log: URL
        let environmentLog: URL

        var invocations: [[String]] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).dropLast().map(String.init) }
        }

        var environment: [String: String] {
            guard let text = try? String(contentsOf: environmentLog, encoding: .utf8) else { return [:] }
            return Dictionary(text.split(separator: "\n").compactMap { line in
                line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
            }, uniquingKeysWith: { _, last in last })
        }

        func makeTask(_ arguments: [String]) -> PBTask {
            PBTask(launchPath: executable.path, arguments: arguments, inDirectory: executable.deletingLastPathComponent().path)
        }
    }

    private func fakeGit(fetch: String = "exit 0", checkout: String = "exit 0") throws -> FakeGit {
        let executable = directory.appendingPathComponent("git")
        let log = directory.appendingPathComponent("invocations")
        let environmentLog = directory.appendingPathComponent("environment")
        let script = """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\037' "$argument"; done >> '\(log.path)'
        printf '\\n' >> '\(log.path)'
        if [ "$2" = fetch ]; then
          printf 'GIT_TERMINAL_PROMPT=%s\\n' "$GIT_TERMINAL_PROMPT" >> '\(environmentLog.path)'
          printf 'GIT_LFS_PROGRESS=%s\\n' "$GIT_LFS_PROGRESS" >> '\(environmentLog.path)'
          printf 'progressMode=%s\\n' "$(stat -f %Lp "$GIT_LFS_PROGRESS")" >> '\(environmentLog.path)'
          printf 'directoryMode=%s\\n' "$(stat -f %Lp "$(dirname "$GIT_LFS_PROGRESS")")" >> '\(environmentLog.path)'
          \(fetch)
        fi
        if [ "$2" = checkout ]; then
          printf 'checkoutPrompt=%s\\n' "$GIT_TERMINAL_PROMPT" >> '\(environmentLog.path)'
          \(checkout)
        fi
        exit 0
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return FakeGit(executable: executable, log: log, environmentLog: environmentLog)
    }

    private func run(
        _ operation: (@escaping (Phase) -> Void) -> GitX.RepositoryLFSDownloadOperation,
        onPhase: ((Phase, GitX.RepositoryLFSDownloadOperation) -> Void)? = nil,
        timeout: TimeInterval = 20
    ) -> (operation: GitX.RepositoryLFSDownloadOperation, phases: [Phase]) {
        var phases: [Phase] = []
        let finished = expectation(description: "the download reaches a final phase")
        var made: GitX.RepositoryLFSDownloadOperation?
        let operation = operation { phase in
            phases.append(phase)
            if let made {
                onPhase?(phase, made)
            }
            if phase.isFinal {
                finished.fulfill()
            }
        }
        made = operation
        operation.start()
        wait(for: [finished], timeout: timeout)
        return (operation, phases)
    }

    private func plan(_ scope: LFSDownloadScope) throws -> LFSDownloadPlan {
        try LFSDownloadPlan.make(scope).get()
    }

    // MARK: Phases

    func testFetchReportsProgressThenChecksOutUnderTheIndexWriter() throws {
        let fake = try fakeGit(fetch: """
        printf 'download 1/2 100/400 a.bin\\n' >> "$GIT_LFS_PROGRESS"
        sleep 1
        printf 'download 2/2 400/400 b c.bin\\n' >> "$GIT_LFS_PROGRESS"
        sleep 1
        """)
        let repositoryURL = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "-q", "-b", "main"], in: repositoryURL)
        let repository = try GitXTestGitRepository(url: repositoryURL)
        let plan = try plan(.paths(["a.bin", "b c.bin"]))
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(
                plan: plan,
                writer: IndexWriterCoordinator.coordinator(for: repository),
                makeTask: fake.makeTask,
                update: update
            )
        }

        XCTAssertEqual(result.phases.first, .fetching(fraction: nil, detail: nil))
        XCTAssertTrue(result.phases.contains(.fetching(fraction: 0.25, detail: "1 of 2 files — 100 bytes of 400 bytes")), "\(result.phases)")
        XCTAssertTrue(result.phases.contains(.fetching(fraction: 1, detail: "2 of 2 files — 400 bytes of 400 bytes")), "\(result.phases)")
        XCTAssertEqual(Array(result.phases.suffix(2)), [.finishing, .finished(.checkedOut)])
        XCTAssertEqual(result.operation.phase, .finished(.checkedOut))
        XCTAssertFalse(result.operation.isCancellable)
        XCTAssertEqual(fake.invocations, [plan.fetchArguments, plan.checkoutArguments])
        XCTAssertEqual(plan.checkoutArguments, ["lfs", "checkout", "--", "/a.bin", "/b c.bin"], "A space is literal in a git-lfs pattern")

        let environment = fake.environment
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["checkoutPrompt"], "0")
        XCTAssertEqual(environment["progressMode"], "600")
        XCTAssertEqual(environment["directoryMode"], "700")
        let progress = try XCTUnwrap(environment["GIT_LFS_PROGRESS"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: (progress as NSString).deletingLastPathComponent), "The private progress directory is removed")
    }

    func testFetchFailureReportsGitLFSsLastDiagnosticAndNeverChecksOut() throws {
        let fake = try fakeGit(fetch: """
        echo "Fetching reference refs/heads/main" >&2
        echo "batch response: Repository or object not found" >&2
        exit 2
        """)
        let plan = try plan(.all)
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, makeTask: fake.makeTask, update: update)
        }

        XCTAssertEqual(result.phases.last, .failed("Git LFS could not download the content. batch response: Repository or object not found"))
        XCTAssertEqual(fake.invocations, [["lfs", "fetch"]])
    }

    func testCancelTerminatesTheFetchAndLeavesTheCheckoutUntouched() throws {
        let fake = try fakeGit(fetch: "sleep 30")
        let plan = try plan(.all)
        let started = Date()
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, makeTask: fake.makeTask, update: update)
        } onPhase: { phase, operation in
            guard case .fetching = phase else { return }
            XCTAssertTrue(operation.isCancellable)
            // Cancel once the fake git has recorded the fetch, so a slow process start cannot race the assertion below.
            let deadline = Date().addingTimeInterval(5)
            @MainActor func cancelOnceTheFetchRuns() {
                guard fake.invocations.isEmpty, Date() < deadline else {
                    operation.cancel()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { cancelOnceTheFetchRuns() }
            }
            cancelOnceTheFetchRuns()
        }

        XCTAssertEqual(result.phases.last, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Cancel does not wait for the fetch")
        XCTAssertEqual(fake.invocations, [["lfs", "fetch"]])
        result.operation.cancel()
        XCTAssertEqual(result.operation.phase, .cancelled, "A second Cancel changes nothing")
    }

    func testACheckoutThatHasStartedIgnoresCancelAndFinishes() throws {
        let fake = try fakeGit(checkout: "sleep 1")
        let plan = try plan(.all)
        var cancelledWhileFinishing = false
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, makeTask: fake.makeTask, update: update)
        } onPhase: { phase, operation in
            guard phase == .finishing else { return }
            XCTAssertFalse(operation.isCancellable)
            operation.cancel()
            cancelledWhileFinishing = operation.phase == .finishing
        }

        XCTAssertTrue(cancelledWhileFinishing)
        XCTAssertEqual(result.phases.last, .finished(.checkedOut))
        XCTAssertEqual(fake.invocations, [["lfs", "fetch"], ["lfs", "checkout"]])
    }

    func testCheckoutWaitsForAdmissionAndDefersWhenGitXIsQuitting() throws {
        let fake = try fakeGit()
        let mutations = GitX.RepositoryLocalMutationRegistry()
        let plan = try plan(.all)
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, mutations: mutations, makeTask: fake.makeTask, update: update)
        } onPhase: { phase, _ in
            // Quit seals admission after the fetch, before the checkout is admitted.
            if phase == .finishing {
                mutations.sealAdmission()
            }
        }

        XCTAssertEqual(result.phases.last, .finished(.checkoutDeferred))
        XCTAssertEqual(fake.invocations, [["lfs", "fetch"]], "A refused checkout never runs")
        XCTAssertFalse(mutations.hasActivity)
    }

    func testCheckoutFailureSaysTheContentWasDownloaded() throws {
        let fake = try fakeGit(checkout: """
        echo "Could not update the index: index.lock exists" >&2
        exit 1
        """)
        let plan = try plan(.all)
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, makeTask: fake.makeTask, update: update)
        }

        XCTAssertEqual(
            result.phases.last,
            .failed("Git LFS downloaded the content but could not write it into the checkout. Could not update the index: index.lock exists")
        )
    }

    func testAFetchThatStopsReportingProgressIsTerminated() throws {
        let fake = try fakeGit(fetch: "sleep 30")
        let plan = try plan(.all)
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let result = run { update in
            GitX.RepositoryLFSDownloadOperation(plan: plan, writer: nil, now: { clock }, makeTask: fake.makeTask, update: update)
        } onPhase: { phase, _ in
            if phase == .fetching(fraction: nil, detail: nil) {
                clock += GitX.RepositoryLFSDownloadOperation.stallInterval + 1
            }
        }

        XCTAssertEqual(result.phases.last, .failed("Git LFS stopped making progress. Check your network connection, then try again."))
        XCTAssertEqual(fake.invocations, [["lfs", "fetch"]])
    }

    func testFailureMessagesFallBackToTheTaskError() {
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Task exited unsuccessfully"])
        XCTAssertEqual(
            GitX.RepositoryLFSDownloadOperation.failureMessage(diagnostic: "", error: error),
            "Git LFS could not download the content. Task exited unsuccessfully"
        )
        XCTAssertTrue(Phase.cancelled.isFinal)
        XCTAssertTrue(Phase.failed("x").isFinal)
        XCTAssertFalse(Phase.finishing.isFinal)
        XCTAssertFalse(Phase.fetching(fraction: 0.5, detail: nil).isFinal)
    }

    // MARK: Real git-lfs

    func testRealGitLFSDownloadsTheCheckoutsContentFromAFileRemote() throws {
        // The test host's PATH omits package-manager directories; GitX's own tasks search them for git-lfs.
        let environment = GitX.PBProcessEnvironment.preparedEnvironment(ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
        @discardableResult
        func lfsGit(_ arguments: [String], in directory: URL) throws -> GitXTestGitFixtureOutput {
            try GitXTestGitFixture.run(arguments, in: directory, inheritedEnvironment: environment)
        }
        let origin = directory.appendingPathComponent("origin")
        let clone = directory.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try lfsGit(["init", "-q", "-b", "main"], in: origin)
        let version = (try? lfsGit(["lfs", "version"], in: origin).standardOutput) ?? ""
        guard case .available = LFSToolPolicy.status(terminationStatus: 0, output: version) else {
            throw XCTSkip("git-lfs \(LFSToolPolicy.minimumMajorVersion).0 or later is not installed: \(version)")
        }
        try lfsGit(["lfs", "install", "--local"], in: origin)
        try lfsGit(["lfs", "track", "*.bin"], in: origin)
        let content = String(repeating: "real model weights\n", count: 64)
        try content.write(to: origin.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        try lfsGit(["add", "-A"], in: origin)
        try lfsGit(["commit", "-q", "-m", "Add a model"], in: origin)
        // Without a global filter.lfs, the clone checks out the pointer text.
        try lfsGit(["clone", "-q", "file://\(origin.path)", clone.path], in: directory)
        try lfsGit(["lfs", "install", "--local"], in: clone)
        let pointer = try String(contentsOf: clone.appendingPathComponent("model.bin"), encoding: .utf8)
        XCTAssertNotNil(LFSPointer.parse(Data(pointer.utf8)))

        let before = try XCTUnwrap(RepositoryLFSStatusScan(executablePath: "/usr/bin/git", workingDirectory: clone.path, knownTool: nil).run())
        XCTAssertEqual(before.summary.notDownloadedPaths, ["model.bin"])
        XCTAssertTrue(before.tool.isAvailable)

        let repository = try GitXTestGitRepository(url: clone)
        let plan = try plan(.paths(["model.bin"]))
        let result = run({ update in
            GitX.RepositoryLFSDownloadOperation(repository: repository, plan: plan, update: update)
        }, timeout: 60)

        XCTAssertEqual(result.phases.last, .finished(.checkedOut), "\(result.phases)")
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("model.bin"), encoding: .utf8), content)
        let after = try XCTUnwrap(RepositoryLFSStatusScan(executablePath: "/usr/bin/git", workingDirectory: clone.path, knownTool: before.tool).run())
        XCTAssertEqual(after.summary.pointerCount, 1)
        XCTAssertEqual(after.summary.notDownloadedPaths, [])
        let status = try lfsGit(["status", "--porcelain"], in: clone).standardOutput
        XCTAssertEqual(status, "", "The checkout leaves the index clean")
    }
}
