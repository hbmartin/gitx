import XCTest

// swift6-safety-justification: all mutable state is guarded by the private lock.
private final class RepositoryIgnoreErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [Error] = []

    func record(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}

private final class RepositoryIgnoreFileCoordinatorSpy: NSFileCoordinator {
    private(set) var writingOptions: [NSFileCoordinator.WritingOptions] = []

    override func coordinate(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        error outError: AutoreleasingUnsafeMutablePointer<NSError?>?,
        byAccessor writer: (URL) -> Void
    ) {
        writingOptions.append(options)
        writer(url)
    }
}

// swift6-safety-justification: this box intentionally stress-tests the production object's synchronized access.
private final class RepositorySettingsConcurrencyBox: @unchecked Sendable {
    let settings: PBRepositoryUISettings

    init(_ settings: PBRepositoryUISettings) {
        self.settings = settings
    }
}

private final class UnavailablePatchCommit: PBGitCommit {
    override var patch: String? {
        nil
    }
}

// swift6-safety-justification: This deliberately cyclic error fixture is assembled and read only by main-actor tests.
private final class CyclicRepositoryError: NSError, @unchecked Sendable {
    weak var underlying: NSError?
    override var userInfo: [String: Any] {
        underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
    }
}

private final class LocalGitRunner: NSObject, PBGitCommandRunning {
    let directory: String
    private(set) var lastOutput: String?

    init(directory: String) {
        self.directory = directory
    }

    func output(withArguments arguments: [String]) throws -> String {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory)
        _ = try task.launch()
        return task.standardOutputString() ?? ""
    }

    func launch(withArguments arguments: [String]) throws {
        lastOutput = try output(withArguments: arguments)
    }
}

@MainActor
final class RepositoryServiceTests: XCTestCase {
    private final class CommandRunnerFake: NSObject, PBGitCommandRunning {
        var outputResults: [Result<String, Error>] = []
        var launchResults: [Result<Void, Error>] = []
        var lastOutput: String?
        private(set) var outputArguments: [[String]] = []
        private(set) var launchArguments: [[String]] = []

        func output(withArguments arguments: [String]) throws -> String {
            outputArguments.append(arguments)
            return try outputResults.isEmpty ? "" : outputResults.removeFirst().get()
        }

        func launch(withArguments arguments: [String]) throws {
            launchArguments.append(arguments)
            try (launchResults.isEmpty ? .success(()) : launchResults.removeFirst()).get()
        }
    }

    private final class UnknownRefish: NSObject, PBGitRefish {
        func refishName() -> String {
            "refs/unknown"
        }

        func shortName() -> String {
            "unknown"
        }

        func refishType() -> String? {
            nil
        }
    }

    private let commandError = NSError(
        domain: "RepositoryServiceTests",
        code: 42,
        userInfo: [NSLocalizedDescriptionKey: "expected command failure"]
    )

    func testRecoveryIgnoresMisleadingDescriptionsWithoutStructuredRejection() {
        let error = NSError(domain: PBTaskErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Task exited unsuccessfully",
            NSLocalizedFailureReasonErrorKey: "git --git-dir=/tmp/[rejected] push non-fast-forward",
            PBTaskTerminationOutputKey: "fatal: Authentication failed",
        ])
        XCTAssertFalse(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: error, snapshot: snapshot))
    }

    func testCopyDecisionBoundariesAndPatchCounts() {
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits(shas: []))
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits(shas: [""]))
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits(shas: ["abc", ""]))
        XCTAssertTrue(CommitCopySelectionPolicy.canCopyImmutableCommits(shas: ["abc", "def"]))
        let mixed = CommitPatchCopyResult(patches: ["first", nil, "", "last"])
        XCTAssertEqual(mixed.text, "last\n\n\nfirst")
        XCTAssertEqual(mixed.copiedCount, 2)
        XCTAssertEqual(mixed.skippedCount, 2)
        XCTAssertEqual(mixed.warningMessage, "Some patches could not be copied")
        XCTAssertEqual(mixed.warningInfo, "Copied 2 patches; skipped 2 commits because Git did not return a patch.")
        let unavailable = CommitPatchCopyResult(patches: [nil])
        XCTAssertEqual(unavailable.warningMessage, "No patches available")
        XCTAssertEqual(unavailable.warningInfo, "Copied 0 patches; skipped 1 commit because Git did not return a patch.")
        let available = CommitPatchCopyResult(patches: ["patch"])
        XCTAssertNil(available.warningMessage)
        XCTAssertTrue(available.warningInfo.contains("1 patch;"))
        XCTAssertNil(CommitPatchCopyResult(patches: []).warningMessage)
        let absent = UnavailablePatchCommit()
        let empty = PBGitCommit()
        empty.setValue("", forKey: "patch")
        let valid = PBGitCommit()
        valid.setValue("valid", forKey: "patch")
        let result = GitXCommitCopier.patchCopyResult([valid, absent, empty])
        XCTAssertEqual(result.text, "valid")
        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertNotNil(result.warningMessage)
        XCTAssertTrue(result.warningInfo.contains("skipped 2"))
        XCTAssertEqual(GitXCommitCopier.toPatch([absent, empty]), "")
        XCTAssertFalse(GitXCommitCopier.canCopyImmutableCommits([]))
        GitXCommitCopier.putString(toPasteboard: nil)
    }

    func testRejectedPushCoordinatorPreservesIntentAndEmitsOneTerminalEvent() throws {
        #if DEBUG
            XCTAssertEqual(PBMilestone2ProductCoverageHarness.rejectedPushRecoveryProof(), (1 << 11) - 1)
        #else
            throw XCTSkip("Product harness is available in Debug")
        #endif
    }

    func testReferenceStoreParsesFirstReferenceAndHandlesBoundaries() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [
            .success("abc refs/heads/main\ndef refs/remotes/origin/main"),
            .success("abc"),
            .failure(commandError),
        ]
        let store = PBRepositoryReferenceStore(repository: repository, runner: runner)

        XCTAssertEqual(store.ref(forName: "main")?.ref, "refs/heads/main")
        XCTAssertNil(store.ref(forName: "incomplete"))
        XCTAssertNil(store.ref(forName: "failure"))
        XCTAssertNil(store.ref(forName: nil))
        XCTAssertEqual(runner.outputArguments, [
            ["show-ref", "main"],
            ["show-ref", "incomplete"],
            ["show-ref", "failure"],
        ])
    }

    func testRemoteServiceBuildsCommandsAndWrapsFailures() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success("origin"), .success("")]
        runner.launchResults = [.success(()), .success(()), .success(()), .failure(commandError)]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)

        XCTAssertEqual(service.remotes(), ["origin"])
        XCTAssertEqual(service.remotes(), [])
        XCTAssertTrue(service.addRemote("origin", withURL: "/tmp/remote", error: nil))
        XCTAssertTrue(service.fetchRemote(for: nil, error: nil))
        var error: NSError?
        let remote = PBGitRef(string: "refs/remotes/origin")
        XCTAssertTrue(service.pullBranch(nil, fromRemote: remote, rebase: true, error: &error))
        XCTAssertFalse(service.pushBranch(nil, toRemote: remote, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Push failed")
        XCTAssertNil(service.lastPushOutput)
        XCTAssertEqual(runner.launchArguments, [
            ["remote", "add", "-f", "origin", "/tmp/remote"],
            ["fetch", "--all"],
            ["pull", "--rebase", "origin"],
            ["push", "--porcelain", "--", "origin"],
        ])

        runner.launchResults = [.success(())]
        runner.lastOutput = "remote: Open https://example.test/pull/42"
        error = nil
        XCTAssertTrue(service.pushBranch(nil, toRemote: remote, error: &error))
        XCTAssertEqual(service.lastPushOutput, "remote: Open https://example.test/pull/42")
    }

    private func rejection(_ summary: String = "[rejected] (non-fast-forward)", destination: String = "refs/heads/main") -> NSError {
        NSError(domain: PBTaskErrorDomain, code: 1, userInfo: [
            PBTaskTerminationOutputKey: "To /tmp/remote\n!\trefs/heads/main:\(destination)\t\(summary)\nDone\n",
        ])
    }

    private var snapshot: RepositoryPushSnapshot {
        RepositoryPushSnapshot(sourceRef: "refs/heads/main", sourceOID: String(repeating: "a", count: 40),
                               remoteName: "origin", endpoint: "/tmp/remote", destinationRef: "refs/heads/main", fetchedOID: String(repeating: "b", count: 40))
    }

    private func snapshotOutputs(config: String = "remote.origin.fetch\n+refs/heads/*:refs/remotes/origin/*\0") -> [Result<String, Error>] {
        [.success(snapshot.sourceOID), .success(snapshot.endpoint), .success(snapshot.endpoint), .success(config), .success(snapshot.fetchedOID)]
    }

    func testRemoteServiceAttachesImmutablePlanAndRetriesWithoutReadingNewState() throws {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = snapshotOutputs()
        runner.launchResults = [.failure(rejection()), .success(()), .failure(rejection())]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: snapshot.sourceRef), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(PBRepositoryPushRetryPlan.plan(forError: XCTUnwrap(error)))
        XCTAssertEqual(plan.sourceOID, snapshot.sourceOID)
        XCTAssertEqual(plan.fetchedOID, snapshot.fetchedOID)
        XCTAssertEqual(plan.endpoint, snapshot.endpoint)
        XCTAssertEqual(plan.branchName, "main")
        XCTAssertEqual(plan.remoteName, "origin")
        XCTAssertEqual(plan.destinationRef, snapshot.destinationRef)
        let readCount = runner.outputArguments.count
        error = nil
        runner.lastOutput = "remote: Open https://example.test/pull/42"
        XCTAssertTrue(service.retryPush(with: plan, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(service.lastPushOutput, runner.lastOutput)
        XCTAssertEqual(runner.outputArguments.count, readCount)
        XCTAssertEqual(runner.launchArguments, [["push", "--porcelain", "--", "origin", "main"], snapshot.retryArguments])
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        XCTAssertNil(try PBRepositoryPushRetryPlan.plan(forError: XCTUnwrap(error)))
        XCTAssertNil(service.lastPushOutput)
        let outer = try NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: XCTUnwrap(error)])
        XCTAssertNil(PBRepositoryPushRetryPlan.plan(forError: outer))
    }

    func testRemoteServiceOnlyOffersRecoveryForFetchedSingleBranchAtSameEndpoint() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        let branch = PBGitRef(string: "refs/heads/main")
        let remote = PBGitRef(string: "refs/remotes/origin")
        var cases = [snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs(), snapshotOutputs()]
        cases[0][0] = .failure(commandError)
        cases[1][0] = .success("invalid")
        cases[2][2] = .success("/tmp/other")
        cases[3][1] = .success("/tmp/remote\n/tmp/second")
        cases[4][4] = .failure(commandError)
        cases[5][4] = .success(String(repeating: "b", count: 64))
        cases[6] = snapshotOutputs(config: "remote.origin.mirror\ntrue\0")
        cases[7] = snapshotOutputs(config: "push.followtags\ntrue\0")
        cases[8] = snapshotOutputs(config: "remote.origin.fetch\n^refs/heads/main\0")
        for outputs in cases {
            runner.outputResults = outputs
            runner.launchResults = [.failure(rejection())]
            var error: NSError?
            XCTAssertFalse(service.pushBranch(branch, toRemote: remote, error: &error))
            XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        }
        for ref in [nil, PBGitRef(string: "refs/tags/v1"), PBGitRef(string: "refs/remotes/origin/main")] {
            runner.outputResults = []
            runner.launchResults = [.failure(rejection())]
            var error: NSError?
            XCTAssertFalse(service.pushBranch(ref, toRemote: remote, error: &error))
            XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        }
        runner.outputResults = snapshotOutputs()
        runner.launchResults = [.failure(rejection("[remote rejected] (pre-receive hook declined)"))]
        var error: NSError?
        XCTAssertFalse(service.pushBranch(branch, toRemote: remote, error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
    }

    func testSnapshotResolvesCustomFetchAndPushMappings() throws {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = snapshotOutputs(config: "remote.origin.push\nrefs/heads/main:refs/heads/review\0remote.origin.fetch\n+refs/heads/*:refs/cache/origin/*\0")
        runner.launchResults = [.failure(rejection(destination: "refs/heads/review"))]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        XCTAssertEqual(plan.destinationRef, "refs/heads/review")
        XCTAssertEqual(runner.outputArguments.last, ["rev-parse", "--verify", "refs/cache/origin/review^{commit}"])
    }

    func testRemoteServiceReportsDiscoveryPullAndDeleteFailures() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.failure(commandError), .failure(commandError)]
        runner.launchResults = [.failure(commandError), .failure(commandError)]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        let branch = PBGitRef(string: "refs/heads/main")
        let remote = PBGitRef(string: "refs/remotes/origin")

        XCTAssertNil(service.remotes())
        var error: NSError?
        XCTAssertFalse(service.pullBranch(branch, fromRemote: remote, rebase: true, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Pull failed")
        error = nil
        XCTAssertFalse(service.pullBranch(nil, fromRemote: remote, rebase: false, error: &error))
        XCTAssertTrue(error?.localizedFailureReason?.contains("(null)") == true)
        error = nil
        XCTAssertFalse(service.deleteRemote(remote, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Delete remote failed!")
        XCTAssertEqual(runner.launchArguments, [
            ["pull", "--rebase", "origin"],
            ["pull", "origin"],
        ])
        XCTAssertEqual(runner.outputArguments, [["remote"], ["remote", "rm", "origin"]])
    }

    func testMutationServicePreservesReferenceAndPathCommandShapes() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success(""), .success(""), .failure(commandError), .success(""), .success("")]
        let service = PBRepositoryMutationService(repository: repository, runner: runner)
        let main = PBGitRef(string: "refs/heads/main")

        XCTAssertTrue(service.checkoutRefish(main, error: nil))
        XCTAssertFalse(service.checkoutFiles([], from: main, error: nil))
        XCTAssertTrue(service.checkoutFiles(["folder/file.txt"], from: main, error: nil))
        var error: NSError?
        XCTAssertFalse(service.checkoutRefish(UnknownRefish(), error: &error))
        XCTAssertTrue(error?.localizedFailureReason?.contains("(null)") == true)
        XCTAssertTrue(service.deleteReference(main, error: nil))
        XCTAssertTrue(service.deleteReference(PBGitRef(string: "refs/tags/v1"), error: nil))
        XCTAssertEqual(runner.outputArguments, [
            ["checkout", "main"],
            ["checkout", "main", "--", "folder/file.txt"],
            ["checkout", "refs/unknown"],
            ["branch", "-D", "--", "main"],
            ["update-ref", "-d", "refs/tags/v1"],
        ])
    }

    func testStashServicePreservesKeepIndexAndFailureErrors() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.success(""), .failure(commandError)]
        let service = PBRepositoryStashService(repository: repository, runner: runner)

        XCTAssertTrue(service.save(withKeepIndex: true, error: nil))
        var error: NSError?
        XCTAssertFalse(service.save(withKeepIndex: false, error: &error))
        XCTAssertEqual(error?.localizedDescription, "Stash save failed!")
        XCTAssertEqual(runner.outputArguments, [
            ["stash", "save", "--keep-index"],
            ["stash", "save", "--no-keep-index"],
        ])
    }

    func testCommitCopierSkipsCommitsWithoutAPatch() {
        let commit = UnavailablePatchCommit()

        XCTAssertEqual(GitXCommitCopier.toPatch([commit]), "")
        XCTAssertEqual(GitXCommitCopier.toPatch([]), "")
    }

    func testCommitCopierCopiesTwoCommitPatchesInReverseOrder() {
        let older = PBGitCommit()
        let newer = PBGitCommit()
        older.setValue("From older", forKey: "patch")
        newer.setValue("From newer", forKey: "patch")

        XCTAssertEqual(
            GitXCommitCopier.toPatch([older, newer]),
            "From newer\n\n\nFrom older"
        )
    }

    func testCheckoutFailureShowsTheGitError() {
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = [.failure(commandError)]
        let service = PBRepositoryMutationService(repository: repository, runner: runner)
        var error: NSError?

        XCTAssertFalse(service.checkoutRefish(PBGitRef(string: "refs/heads/main"), error: &error))
        XCTAssertEqual((error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription, "expected command failure")
        XCTAssertFalse(error?.localizedFailureReason?.contains("working directory not clean") == true)
    }

    func testStructuredRejectionRequiresMatchingSnapshotAndIgnoresDescriptions() {
        XCTAssertTrue(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: rejection(), snapshot: snapshot))
        XCTAssertTrue(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: rejection("[rejected] (fetch first)"), snapshot: snapshot))
        XCTAssertFalse(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: rejection(), snapshot: nil))
        for output in ["fatal: Authentication failed", "! [rejected] main -> main (non-fast-forward)",
                       "!\trefs/heads/other:refs/heads/main\t[rejected] (non-fast-forward)",
                       "!\trefs/heads/main:refs/heads/main\t[remote rejected] (pre-receive hook declined)",
                       "!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\n=\trefs/tags/v1:refs/tags/v1\t[up to date]",
                       "=\trefs/heads/main:refs/heads/main\t[up to date]"]
        {
            let error = NSError(domain: PBTaskErrorDomain, code: 1, userInfo: [PBTaskTerminationOutputKey: output])
            XCTAssertFalse(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: error, snapshot: snapshot))
        }
        let outer = NSError(domain: "git", code: 1, userInfo: [NSUnderlyingErrorKey: rejection()])
        XCTAssertTrue(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: outer, snapshot: snapshot))
        XCTAssertNil(RepositoryRejectedPushRecoveryPolicy.taskOutput(for: commandError))
        XCTAssertFalse(RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: commandError, snapshot: snapshot))
        XCTAssertTrue(RepositoryPushSnapshot.isOID(String(repeating: "A", count: 64)))
        XCTAssertFalse(RepositoryPushSnapshot.isOID(String(repeating: "z", count: 40)))
    }

    func testCyclicErrorChainsTerminateAndNestedPlansRemainAvailable() throws {
        let first = CyclicRepositoryError(domain: "cycle", code: 1)
        let second = CyclicRepositoryError(domain: "cycle", code: 2)
        first.underlying = second
        second.underlying = first
        XCTAssertNil(RepositoryRejectedPushRecoveryPolicy.taskOutput(for: first))
        XCTAssertNil(PBRepositoryPushRetryPlan.plan(forError: first))
        let repository = PBGitRepository()
        let runner = CommandRunnerFake()
        runner.outputResults = snapshotOutputs()
        runner.launchResults = [.failure(first), .failure(rejection())]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        let branch = PBGitRef(string: snapshot.sourceRef)
        let remote = PBGitRef(string: "refs/remotes/origin")
        XCTAssertFalse(service.pushBranch(branch, toRemote: remote, error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        runner.outputResults = snapshotOutputs()
        XCTAssertFalse(service.pushBranch(branch, toRemote: remote, error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        let outer = try NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: XCTUnwrap(error)])
        XCTAssertTrue(PBRepositoryPushRetryPlan.plan(forError: outer) === plan)
    }

    func testRefspecMappingFailsClosedOnUnsupportedOrAmbiguousMappings() {
        let source = "refs/heads/main"
        XCTAssertEqual(RepositoryPushRefspecPolicy.destination(source: source, pushMappings: []), source)
        XCTAssertEqual(RepositoryPushRefspecPolicy.destination(source: source, pushMappings: ["+refs/heads/*:refs/heads/review/*"]), "refs/heads/review/main")
        XCTAssertEqual(RepositoryPushRefspecPolicy.trackingReference(destination: source, fetchMappings: ["refs/heads/main:refs/cache/main"]), "refs/cache/main")
        XCTAssertNil(RepositoryPushRefspecPolicy.trackingReference(destination: source, fetchMappings: []))
        for specs in [[":"], ["^refs/heads/main"], ["refs/heads/*:refs/cache/main"],
                      ["refs/heads/*/*:refs/cache/*/*"], ["refs/heads/other:refs/cache/other"],
                      ["refs/heads/main:refs/cache/a", "refs/heads/main:refs/cache/b"],
                      ["refs/heads/main:refs/heads/main"], ["refs/heads/main:refs/tags/main"]]
        {
            XCTAssertNil(RepositoryPushRefspecPolicy.trackingReference(destination: source, fetchMappings: specs))
        }
        XCTAssertEqual(RepositoryPushRefspecPolicy.trackingReference(destination: "refs/heads/feature/end", fetchMappings: ["refs/heads/*/end:refs/cache/*"]), "refs/cache/feature")
        XCTAssertNil(RepositoryPushRefspecPolicy.trackingReference(destination: "refs/heads/feature/other", fetchMappings: ["refs/heads/*/end:refs/cache/*"]))
    }
}

final class RepositoryForgeCoordinatorTests: XCTestCase {
    private var originalComposition: PBApplicationComposition!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var repositoryURL: URL!
    private var repository: PBGitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalComposition = PBApplicationComposition.shared()
        defaultsSuiteName = "GitXTests.RepositoryForgeCoordinator.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        PBApplicationComposition.setShared(PBApplicationComposition(
            userDefaults: defaults,
            automaticallyStartsForgeServices: false
        ))

        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXRepositoryForge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(["init", "--quiet", "--initial-branch=main"])
        try runGit(["config", "user.name", "GitX Tests"])
        try runGit(["config", "user.email", "gitx-tests@example.invalid"])
        try "initial\n".write(
            to: repositoryURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "--all"])
        try runGit(["commit", "--quiet", "-m", "initial"])
        repository = try PBGitRepository(url: repositoryURL)
    }

    override func tearDownWithError() throws {
        repository = nil
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        PBApplicationComposition.setShared(originalComposition)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        originalComposition = nil
        try super.tearDownWithError()
    }

    func testNativeLocalBranchDeletionProtectsWorktreesAndRemovesConfiguration() throws {
        let runner = LocalGitRunner(directory: repositoryURL.path)
        let service = PBRepositoryMutationService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.deleteReference(PBGitRef(string: "refs/heads/main"), error: &error))
        XCTAssertTrue(taskOutput(error).contains("worktree") || taskOutput(error).contains("checked out"), taskOutput(error))
        XCTAssertFalse(service.deleteReference(PBGitRef(string: "refs/heads/missing"), error: &error))
        XCTAssertTrue(taskOutput(error).contains("not found"))

        let linked = repositoryURL.appendingPathComponent("linked")
        try runGit(["worktree", "add", "--quiet", "-b", "linked", linked.path])
        defer { try? runGit(["worktree", "remove", "--force", linked.path]) }
        XCTAssertFalse(service.deleteReference(PBGitRef(string: "refs/heads/linked"), error: &error))
        XCTAssertTrue(taskOutput(error).contains("worktree") || taskOutput(error).contains("checked out"), taskOutput(error))
        try runGit(["branch", "disposable"])
        try runGit(["config", "branch.disposable.remote", "origin"])
        try runGit(["config", "branch.disposable.merge", "refs/heads/main"])
        XCTAssertTrue(service.deleteReference(PBGitRef(string: "refs/heads/disposable"), error: &error))
        XCTAssertThrowsError(try runGit(["config", "--get", "branch.disposable.remote"]))
        XCTAssertThrowsError(try runGit(["rev-parse", "--verify", "refs/heads/disposable"]))
    }

    func testCheckoutRetainsRealGitOutputInUnderlyingTaskError() {
        let service = PBRepositoryMutationService(repository: repository, runner: LocalGitRunner(directory: repositoryURL.path))
        var error: NSError?
        XCTAssertFalse(service.checkoutRefish(PBGitRef(string: "refs/heads/missing"), error: &error))
        XCTAssertTrue(taskOutput(error).contains("pathspec"))
        error = nil
        XCTAssertFalse(service.checkoutFiles(["missing.txt"], from: PBGitRef(string: "refs/heads/main"), error: &error))
        XCTAssertTrue(taskOutput(error).contains("pathspec"))
    }

    func testCheckoutContextDoesNotRepeatGenericTaskDescription() {
        let service = PBRepositoryMutationService(repository: repository, runner: LocalGitRunner(directory: repositoryURL.path))
        var error: NSError?
        XCTAssertFalse(service.checkoutRefish(PBGitRef(string: "refs/heads/missing"), error: &error))
        XCTAssertFalse(error?.localizedFailureReason?.contains("Task exited unsuccessfully") == true)
        XCTAssertTrue(taskOutput(error).contains("pathspec"))
    }

    func testRetryCannotReplaceNewerRemoteCommit() throws {
        let bare = repositoryURL.appendingPathComponent("remote.git")
        let other = repositoryURL.appendingPathComponent("other")
        let runner = LocalGitRunner(directory: repositoryURL.path)
        _ = try runner.output(withArguments: ["init", "--bare", "--quiet", bare.path])
        try runGit(["remote", "add", "origin", bare.path])
        try runGit(["push", "--quiet", "origin", "main"])
        try runGit(["fetch", "--quiet", "origin"])
        _ = try runner.output(withArguments: ["clone", "--quiet", "--branch", "main", bare.path, other.path])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        let branch = PBGitRef(string: "refs/heads/main")
        let remote = PBGitRef(string: "refs/remotes/origin")
        var error: NSError?
        XCTAssertFalse(service.pushBranch(branch, toRemote: remote, error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        let otherRunner = LocalGitRunner(directory: other.path)
        _ = try otherRunner.output(withArguments: ["-c", "user.name=Other", "-c", "user.email=other@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "new remote work"])
        _ = try otherRunner.output(withArguments: ["push", "--quiet", "origin", "main"])
        let newerOID = try otherRunner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        try runGit(["fetch", "--quiet", "origin"])
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        let remoteOID = try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteOID, newerOID)
    }

    func testRetryReplacesFetchedTipWithFrozenSourceEvenIfLocalBranchMoves() throws {
        let runner = LocalGitRunner(directory: repositoryURL.path)
        let bare = repositoryURL.appendingPathComponent("remote.git")
        _ = try runner.output(withArguments: ["init", "--bare", "--quiet", bare.path])
        try runGit(["remote", "add", "origin", bare.path])
        try runGit(["push", "--quiet", "origin", "main"])
        try runGit(["fetch", "--quiet", "origin"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let frozenSource = try runner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        try runGit(["commit", "--quiet", "--allow-empty", "-m", "later local work"])
        try runGit(["fetch", "--quiet", "origin"])
        error = nil
        XCTAssertTrue(service.retryPush(with: plan, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .whitespacesAndNewlines), frozenSource)
        XCTAssertEqual(plan.sourceOID, frozenSource)
    }

    private func taskOutput(_ error: NSError?) -> String {
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.userInfo[PBTaskTerminationOutputKey] as? String ?? ""
    }

    func testUniqueRemotePersistsStableBindingThatRemainsAuthoritative() throws {
        try addRemote("origin", url: "git@github.com:acme/widgets.git")

        let automatic = PBRepositoryForgeCoordinator(repository: repository).resolveBinding()

        XCTAssertEqual(automatic.kind, .automatic)
        XCTAssertEqual(automatic.localRemoteName, "origin")
        XCTAssertEqual(automatic.providerName, "GitHub")
        XCTAssertEqual(automatic.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
        XCTAssertNotNil(persistedBindingData())

        try runGit(["remote", "remove", "origin"])
        try addRemote("upstream", url: "https://gitlab.com/other/project.git")
        let existing = PBRepositoryForgeCoordinator(repository: repository).resolveBinding()

        XCTAssertEqual(existing.kind, .existing)
        XCTAssertEqual(existing.localRemoteName, "origin")
        XCTAssertEqual(existing.providerName, "GitHub")
        XCTAssertEqual(existing.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
    }

    func testAmbiguousRemotesRetainLocalNamesAndRequireExplicitSelection() throws {
        try addRemote("origin", url: "git@github.com:person/widgets.git")
        try addRemote("upstream", url: "ssh://git@gitlab.com/organization/widgets.git")
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        let resolution = coordinator.resolveBinding()

        XCTAssertEqual(resolution.kind, .requiresChoice)
        XCTAssertEqual(Set(resolution.candidates.map(\.localRemoteName)), ["origin", "upstream"])
        XCTAssertNil(persistedBindingData())
        assertScriptingError(.ambiguousForgeRepository) {
            _ = try coordinator.repositoryURL()
        }

        let upstream = try XCTUnwrap(
            resolution.candidates.first { $0.localRemoteName == "upstream" }
        )
        let selected = try coordinator.select(upstream)
        XCTAssertEqual(selected.kind, .existing)
        XCTAssertEqual(selected.localRemoteName, "upstream")
        XCTAssertNotNil(persistedBindingData())
        XCTAssertEqual(
            try coordinator.repositoryURL().absoluteString,
            "https://gitlab.com/organization/widgets"
        )
    }

    @MainActor
    func testCandidateAccessorsDescribeEverySupportedProviderAndMixedResolution() throws {
        try addRemote("github", url: "git@github.com:acme/widgets.git")
        try addRemote("gitlab", url: "ssh://git@gitlab.com/group/project.git")
        try addRemote("bitbucket", url: "https://bitbucket.org/team/toolkit.git")
        try addRemote("unsupported", url: "http://example.com/acme/widgets.git")
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        let resolution = coordinator.resolveBinding()

        XCTAssertEqual(resolution.kind, .requiresChoice)
        XCTAssertNil(resolution.localRemoteName)
        XCTAssertNil(resolution.repositoryURL)
        XCTAssertNil(resolution.providerName)
        let candidates = Dictionary(uniqueKeysWithValues: resolution.candidates.map { ($0.localRemoteName, $0) })
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates["github"]?.providerName, "GitHub")
        XCTAssertEqual(candidates["github"]?.repositoryLabel, "acme/widgets")
        XCTAssertEqual(candidates["github"]?.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
        XCTAssertEqual(candidates["gitlab"]?.providerName, "GitLab")
        XCTAssertEqual(candidates["gitlab"]?.repositoryLabel, "group/project")
        XCTAssertEqual(candidates["gitlab"]?.repositoryURL?.absoluteString, "https://gitlab.com/group/project")
        XCTAssertEqual(candidates["bitbucket"]?.providerName, "Bitbucket")
        XCTAssertEqual(candidates["bitbucket"]?.repositoryLabel, "team/toolkit")
        XCTAssertEqual(
            candidates["bitbucket"]?.repositoryURL?.absoluteString,
            "https://bitbucket.org/team/toolkit"
        )

        let selected = try coordinator.select(XCTUnwrap(candidates["bitbucket"]))
        XCTAssertEqual(selected.localRemoteName, "bitbucket")
        XCTAssertEqual(selected.providerName, "Bitbucket")
        XCTAssertEqual(selected.repositoryURL?.absoluteString, "https://bitbucket.org/team/toolkit")
    }

    @MainActor
    func testSameProviderCandidatesExposeProviderBeforeBinding() throws {
        try addRemote("origin", url: "https://github.com/acme/widgets.git")
        try addRemote("upstream", url: "https://github.com/community/widgets.git")

        let resolution = PBRepositoryForgeCoordinator(repository: repository).resolveBinding()

        XCTAssertEqual(resolution.kind, .requiresChoice)
        XCTAssertEqual(resolution.providerName, "GitHub")
        XCTAssertNil(resolution.repositoryURL)
    }

    func testCorruptBindingDecodesAsNilAndProducesDeterministicNoRepositoryError() {
        setPersistedBindingData(Data("not-json".utf8))
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        let resolution = coordinator.resolveBinding()

        XCTAssertEqual(resolution.kind, .unavailable)
        XCTAssertNil(resolution.localRemoteName)
        XCTAssertNil(resolution.repositoryURL)
        XCTAssertNil(resolution.providerName)
        assertScriptingError(.noForgeRepository) {
            _ = try coordinator.repositoryURL()
        }
    }

    func testRemoteDescriptorLoaderCachesSubprocessResultsUntilConfigurationRevisionChanges() {
        let cache = RepositoryForgeRemoteDescriptorCache()
        let loader = RepositoryForgeRemoteDescriptorLoader(cache: cache)
        var revision = "config-v1"
        var remoteNameLoads = 0
        var remoteURLLoads = 0
        let key = "cache-test-\(UUID().uuidString)"
        func load() -> RepositoryForgeRemoteDescriptorLoad {
            loader.load(
                cacheKey: key,
                revision: revision,
                remoteNames: {
                    remoteNameLoads += 1
                    return ["origin", "upstream"]
                },
                remoteURL: { name in
                    remoteURLLoads += 1
                    return name == "origin"
                        ? "https://github.com/person/widgets.git"
                        : "https://github.com/organization/widgets.git"
                }
            )
        }

        XCTAssertFalse(load().reusedCache)
        XCTAssertTrue(load().reusedCache)
        XCTAssertEqual(remoteNameLoads, 1)
        XCTAssertEqual(remoteURLLoads, 2)

        revision = "config-v2"
        XCTAssertFalse(load().reusedCache)
        XCTAssertEqual(remoteNameLoads, 2)
        XCTAssertEqual(remoteURLLoads, 4)
    }

    func testTransientRemoteURLFailureIsNotNegativeCached() {
        let cache = RepositoryForgeRemoteDescriptorCache()
        let loader = RepositoryForgeRemoteDescriptorLoader(cache: cache)
        var remoteURLLoads = 0
        let key = "failure-cache-test-\(UUID().uuidString)"
        func load() -> RepositoryForgeRemoteDescriptorLoad {
            loader.load(
                cacheKey: key,
                revision: "unchanged",
                remoteNames: { ["origin"] },
                remoteURL: { _ in
                    remoteURLLoads += 1
                    return remoteURLLoads == 1 ? nil : "https://github.com/acme/widgets.git"
                }
            )
        }

        XCTAssertFalse(load().isCacheable)
        XCTAssertTrue(load().isCacheable)
        XCTAssertEqual(remoteURLLoads, 2)
    }

    func testLinkedWorktreeConfigurationRevisionIncludesRelativeCommonDirectory() throws {
        try addRemote("origin", url: "https://github.com/acme/widgets.git")
        let linkedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXRepositoryForgeLinked-\(UUID().uuidString)", isDirectory: true)
        try runGit(["worktree", "add", "--quiet", "-b", "linked", linkedURL.path])
        defer {
            try? runGit(["worktree", "remove", "--force", linkedURL.path])
            try? FileManager.default.removeItem(at: linkedURL)
        }
        let linkedRepository = try PBGitRepository(url: linkedURL)
        let linkedGitURL = try XCTUnwrap(linkedRepository.gitURL())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: linkedGitURL.appendingPathComponent("commondir").path
            )
        )

        let resolution = PBRepositoryForgeCoordinator(repository: linkedRepository).resolveBinding()
        XCTAssertEqual(resolution.kind, .automatic)
        XCTAssertEqual(resolution.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
    }

    func testIncludedGitConfigurationChangeInvalidatesUnavailableRemoteDescriptorCache() throws {
        let includedConfigurationURL = repositoryURL
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("forge-remotes.inc", isDirectory: false)
        try """
        [remote "origin"]
            url = http://example.com/acme/widgets.git
        """.write(to: includedConfigurationURL, atomically: true, encoding: .utf8)
        try runGit(["config", "--local", "include.path", includedConfigurationURL.lastPathComponent])
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        XCTAssertEqual(coordinator.resolveBinding().kind, .unavailable)
        XCTAssertEqual(coordinator.resolveBinding().kind, .unavailable)

        try """
        [remote "origin"]
            url = https://github.com/acme/widgets.git
        """.write(to: includedConfigurationURL, atomically: true, encoding: .utf8)
        let updated = coordinator.resolveBinding()
        XCTAssertEqual(updated.kind, .automatic)
        XCTAssertEqual(updated.providerName, "GitHub")
        XCTAssertEqual(updated.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
    }

    func testBranchConditionalGitConfigurationInvalidatesRemoteDescriptorCache() throws {
        let gitDirectoryURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        let mainConfigurationURL = gitDirectoryURL.appendingPathComponent("main-remotes.inc")
        let githubConfigurationURL = gitDirectoryURL.appendingPathComponent("github-remotes.inc")
        try """
        [remote "origin"]
            url = http://example.com/acme/widgets.git
        """.write(to: mainConfigurationURL, atomically: true, encoding: .utf8)
        try """
        [remote "origin"]
            url = https://github.com/acme/widgets.git
        """.write(to: githubConfigurationURL, atomically: true, encoding: .utf8)
        try runGit(["config", "--local", "includeIf.onbranch:main.path", mainConfigurationURL.path])
        try runGit(["config", "--local", "includeIf.onbranch:github.path", githubConfigurationURL.path])
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        XCTAssertEqual(coordinator.resolveBinding().kind, .unavailable)
        XCTAssertEqual(coordinator.resolveBinding().kind, .unavailable)

        try runGit(["checkout", "--quiet", "-b", "github"])
        let updated = coordinator.resolveBinding()
        XCTAssertEqual(updated.kind, .automatic)
        XCTAssertEqual(updated.providerName, "GitHub")
        XCTAssertEqual(updated.repositoryURL?.absoluteString, "https://github.com/acme/widgets")
    }

    @MainActor
    func testRevisionFacadeCoversTagAndCommitKinds() throws {
        try addRemote("origin", url: "https://github.com/acme/widgets.git")
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)
        let commit = String(repeating: "b", count: 40)

        XCTAssertEqual(
            try coordinator.fileURL(
                forRevision: "v2.0",
                revisionKind: .tag,
                path: "README.md",
                startLine: nil,
                endLine: nil
            ).absoluteString,
            "https://github.com/acme/widgets/blob/v2.0/README.md"
        )
        XCTAssertEqual(
            try coordinator.compareURL(
                fromRevision: commit,
                baseKind: .commit,
                toRevision: "v2.0",
                head: .tag
            ).absoluteString,
            "https://github.com/acme/widgets/compare/\(commit)...v2.0"
        )
    }

    func testScriptingConstructsEveryGitHubDestinationWithoutPersistingOrPresentingUI() throws {
        try addRemote("origin", url: "ssh://git@github.com/acme/widgets.git")
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)
        let commit = String(repeating: "a", count: 40)

        XCTAssertEqual(
            try coordinator.repositoryURL().absoluteString,
            "https://github.com/acme/widgets"
        )
        XCTAssertEqual(
            try coordinator.branchURL(forName: "feature/naïve").absoluteString,
            "https://github.com/acme/widgets/tree/feature%2Fna%C3%AFve"
        )
        XCTAssertEqual(
            try coordinator.commitURL(forIdentifier: commit).absoluteString,
            "https://github.com/acme/widgets/commit/\(commit)"
        )
        XCTAssertEqual(
            try coordinator.fileURL(
                forRevision: "feature/naïve",
                revisionKind: .branch,
                path: "Sources/naïve file.swift",
                startLine: 10,
                endLine: 20
            ).absoluteString,
            "https://github.com/acme/widgets/blob/feature%2Fna%C3%AFve/Sources/na%C3%AFve%20file.swift#L10-L20"
        )
        XCTAssertEqual(
            try coordinator.compareURL(
                fromRevision: "main",
                baseKind: .branch,
                toRevision: "feature/naïve",
                head: .branch
            ).absoluteString,
            "https://github.com/acme/widgets/compare/main...feature%2Fna%C3%AFve"
        )
        XCTAssertEqual(
            try coordinator.pullRequestURL(forNumber: 12).absoluteString,
            "https://github.com/acme/widgets/pull/12"
        )
        XCTAssertEqual(
            try coordinator.issueURL(forNumber: 34).absoluteString,
            "https://github.com/acme/widgets/issues/34"
        )
        XCTAssertNil(persistedBindingData(), "Read-only scripting must not silently create a binding")
    }

    func testScriptingRejectsInvalidDestinationWithStableErrorCode() throws {
        try addRemote("origin", url: "https://github.com/acme/widgets.git")
        let coordinator = PBRepositoryForgeCoordinator(repository: repository)

        assertScriptingError(.invalidDestination) {
            _ = try coordinator.fileURL(
                forRevision: "main",
                revisionKind: .branch,
                path: "File.swift",
                startLine: nil,
                endLine: 8
            )
        }
        assertScriptingError(.invalidDestination) {
            _ = try coordinator.pullRequestURL(forNumber: 0)
        }
        XCTAssertNil(persistedBindingData())
    }

    private func assertScriptingError(
        _ expectedCode: PBRepositoryForgeScriptingErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, "com.gitx.forge.scripting", file: file, line: line)
            XCTAssertEqual(error.code, expectedCode.rawValue, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    private func addRemote(_ name: String, url: String) throws {
        try runGit(["remote", "add", name, url])
    }

    private func persistedBindingData() -> Data? {
        let allSettings = defaults.dictionary(forKey: "PBRepositoryUISettings") ?? [:]
        let repositorySettings = allSettings[repositoryDefaultsKey] as? [String: Any]
        return repositorySettings?["forgeRepositoryBinding"] as? Data
    }

    private func setPersistedBindingData(_ data: Data) {
        defaults.set(
            [repositoryDefaultsKey: ["forgeRepositoryBinding": data]],
            forKey: "PBRepositoryUISettings"
        )
    }

    private var repositoryDefaultsKey: String {
        repositoryURL.appendingPathComponent(".git", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "RepositoryForgeCoordinatorTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

@MainActor
// swift6-safety-justification: XCTest owns the test case lifetime, while every mutable access is confined to the main actor.
final class RepositoryIgnoreCharacterizationTests: XCTestCase, @unchecked Sendable {
    private var repositoryURL: URL!
    private var repository: PBGitRepository!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where this repository fixture is confined.
        try MainActor.assumeIsolated {
            repositoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXRepositoryIgnore-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try runGit(["init", "--quiet", "--initial-branch=main"])
            try runGit(["config", "user.name", "GitX Tests"])
            try runGit(["config", "user.email", "gitx-tests@example.invalid"])
            try "tracked\n".write(
                to: repositoryURL.appendingPathComponent("tracked.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "--all"])
            try runGit(["commit", "--quiet", "-m", "initial"])
            repository = try PBGitRepository(url: repositoryURL)
        }
    }

    override nonisolated func tearDown() {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where this repository fixture is confined.
        MainActor.assumeIsolated {
            repository?.revisionList?.cleanup()
            repository = nil
            if let repositoryURL {
                try? FileManager.default.removeItem(at: repositoryURL)
            }
            repositoryURL = nil
        }
        super.tearDown()
    }

    func testCreatingIgnoreFilePreservesUnicodeOrderingAndCurrentNewlineBehavior() throws {
        let paths = ["build/", "résumé/雪.tmp", "*.temporary"]

        try repository.ignoreFilePaths(paths)

        let data = try Data(contentsOf: repositoryURL.appendingPathComponent(".gitignore"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "build/\nrésumé/雪.tmp\n*.temporary")
        XCTAssertNotEqual(data.last, Character("\n").asciiValue)
    }

    func testIgnoreWriteReportsErrorWhenIgnorePathIsDirectory() throws {
        let ignoreURL = repositoryURL.appendingPathComponent(".gitignore", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoreURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try repository.ignoreFilePaths(["ignored.txt"])) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoreURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testIgnoreWriteReportsFileCoordinationCancellation() {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.cancel()
        let service = PBRepositoryIgnoreFileService(
            fileURL: ignoreURL,
            fileCoordinator: coordinator
        )

        XCTAssertThrowsError(try service.appendPaths(["ignored.txt"])) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.userCancelled.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoreURL.path))
    }

    func testAtomicIgnoreWritesDeclareReplacementCoordination() throws {
        let coordinator = RepositoryIgnoreFileCoordinatorSpy(filePresenter: nil)
        let service = PBRepositoryIgnoreFileService(
            fileURL: ignoreURL,
            fileCoordinator: coordinator
        )

        try service.appendPaths(["ignored.txt"])
        try FileManager.default.removeItem(at: ignoreURL)
        try service.appendPaths([])

        XCTAssertEqual(coordinator.writingOptions, [.forReplacing, .forReplacing])
    }

    func testAppendingUsesExactlyOneSeparatorAndPreservesExistingNewlines() throws {
        let cases = [
            ("existing", "existing\nnew"),
            ("existing\n", "existing\nnew"),
            ("existing\n\n", "existing\n\nnew"),
            ("", "new"),
        ]

        for (existing, expected) in cases {
            try existing.write(to: ignoreURL, atomically: true, encoding: .utf8)

            assertSuccessfulIgnore(["new"])

            XCTAssertEqual(try String(contentsOf: ignoreURL, encoding: .utf8), expected)
        }
    }

    func testAppendingUsesExistingCRLFConventionForSeparatorsAndNewPaths() throws {
        try Data("existing\r\nline".utf8).write(to: ignoreURL, options: .atomic)

        assertSuccessfulIgnore(["résumé/雪.tmp", "*.temporary"])

        XCTAssertEqual(
            try Data(contentsOf: ignoreURL),
            Data("existing\r\nline\r\nrésumé/雪.tmp\r\n*.temporary".utf8)
        )
    }

    func testAppendingPreservesClassicMacNewlinesAndEmptyRequests() throws {
        try Data("existing\rline".utf8).write(to: ignoreURL, options: .atomic)

        assertSuccessfulIgnore(["new"])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), Data("existing\rline\rnew".utf8))

        let existingData = try Data(contentsOf: ignoreURL)
        assertSuccessfulIgnore([])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), existingData)

        try FileManager.default.removeItem(at: ignoreURL)
        assertSuccessfulIgnore([])
        XCTAssertEqual(try Data(contentsOf: ignoreURL), Data())
    }

    func testAppendingPreservesDetectedEncodingAndUnicode() throws {
        try "existing ü".write(to: ignoreURL, atomically: true, encoding: .utf16)
        var originalEncoding = String.Encoding.utf8
        _ = try String(contentsOf: ignoreURL, usedEncoding: &originalEncoding)

        assertSuccessfulIgnore(["résumé/雪.tmp"])

        var updatedEncoding = String.Encoding.utf8
        let updated = try String(contentsOf: ignoreURL, usedEncoding: &updatedEncoding)
        XCTAssertEqual(updatedEncoding, originalEncoding)
        XCTAssertEqual(updated, "existing ü\nrésumé/雪.tmp")
    }

    func testAppendingRereadsExternallyReplacedIgnoreFile() throws {
        try "initial".write(to: ignoreURL, atomically: true, encoding: .utf8)
        assertSuccessfulIgnore(["first"])
        XCTAssertEqual(try String(contentsOf: ignoreURL, encoding: .utf8), "initial\nfirst")

        try Data("external\r\nreplacement".utf8).write(to: ignoreURL, options: .atomic)
        assertSuccessfulIgnore(["second"])

        XCTAssertEqual(
            try Data(contentsOf: ignoreURL),
            Data("external\r\nreplacement\r\nsecond".utf8)
        )
    }

    func testConcurrentAppendsPreserveEveryPath() throws {
        let ignoreURL = repositoryURL.appendingPathComponent(".gitignore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoreURL.path))
        let collector = RepositoryIgnoreErrorCollector()
        let expected = Set((0 ..< 64).map { "concurrent-\($0)" })

        DispatchQueue.concurrentPerform(iterations: expected.count) { index in
            let service = PBRepositoryIgnoreFileService(fileURL: ignoreURL)
            do {
                try service.appendPaths(["concurrent-\(index)"])
            } catch {
                collector.record(error)
            }
        }

        XCTAssertTrue(collector.errors.isEmpty, "\(collector.errors)")
        let lines = try String(contentsOf: ignoreURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, expected.count)
        XCTAssertEqual(Set(lines), expected)
    }

    func testConcurrentRepositorySettingsUpdatesPreserveIndependentFields() {
        let defaultsKey = "PBRepositoryUISettings"
        let defaults = UserDefaults.standard
        let originalSettings = defaults.object(forKey: defaultsKey)
        defer {
            if let originalSettings {
                defaults.set(originalSettings, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let settings = PBRepositoryUISettings(repository: repository)
        settings.pushAfterCommit = false
        settings.hideContainedBranches = false
        let settingsBox = RepositorySettingsConcurrencyBox(settings)

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            if iteration.isMultiple(of: 2) {
                settingsBox.settings.pushAfterCommit = true
            } else {
                settingsBox.settings.hideContainedBranches = true
            }
        }

        let reloaded = PBRepositoryUISettings(repository: repository)
        XCTAssertTrue(reloaded.pushAfterCommit)
        XCTAssertTrue(reloaded.hideContainedBranches)
    }

    func testConcurrentRepositorySettingsInstancesPreserveIndependentFields() {
        let defaultsKey = "PBRepositoryUISettings"
        let defaults = UserDefaults.standard
        let originalSettings = defaults.object(forKey: defaultsKey)
        defer {
            if let originalSettings {
                defaults.set(originalSettings, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let pushSettings = RepositorySettingsConcurrencyBox(
            PBRepositoryUISettings(repository: repository)
        )
        let branchSettings = RepositorySettingsConcurrencyBox(
            PBRepositoryUISettings(repository: repository)
        )
        pushSettings.settings.pushAfterCommit = false
        branchSettings.settings.hideContainedBranches = false

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            if iteration.isMultiple(of: 2) {
                pushSettings.settings.pushAfterCommit = true
            } else {
                branchSettings.settings.hideContainedBranches = true
            }
        }

        let reloaded = PBRepositoryUISettings(repository: repository)
        XCTAssertTrue(reloaded.pushAfterCommit)
        XCTAssertTrue(reloaded.hideContainedBranches)
    }

    func testAtomicWriteFailurePreservesExistingIgnoreContents() throws {
        let original = Data("existing\n".utf8)
        try original.write(to: ignoreURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: repositoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: repositoryURL.path
            )
        }

        let invocation = PBRepositoryIgnoreInvocation.invokeRepository(
            repository,
            paths: ["new"]
        )

        XCTAssertNil(invocation.exception)
        XCTAssertFalse(invocation.success)
        XCTAssertNotNil(invocation.error)
        XCTAssertEqual(try Data(contentsOf: ignoreURL), original)
    }

    func testExternalIgnoreEditRemovesUntrackedRowButRetainsTrackedChange() throws {
        let ignoredPath = "ignored ü.txt"
        try "ignored\n".write(
            to: repositoryURL.appendingPathComponent(ignoredPath),
            atomically: true,
            encoding: .utf8
        )
        try "changed\n".write(
            to: repositoryURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        refreshIndex()
        XCTAssertEqual(Set(repository.index.indexChanges.map(\.path)), [ignoredPath, "tracked.txt"])

        try "\(ignoredPath)\n".write(
            to: repositoryURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        refreshIndex()

        let refreshedChanges = Dictionary(
            uniqueKeysWithValues: repository.index.indexChanges.map { ($0.path, $0) }
        )
        XCTAssertEqual(Set(refreshedChanges.keys), [".gitignore", "tracked.txt"])
        XCTAssertNil(refreshedChanges[ignoredPath])
        XCTAssertTrue(refreshedChanges["tracked.txt"]?.hasUnstagedChanges == true)
    }

    private var ignoreURL: URL {
        repositoryURL.appendingPathComponent(".gitignore")
    }

    private func assertSuccessfulIgnore(
        _ paths: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let invocation = PBRepositoryIgnoreInvocation.invokeRepository(repository, paths: paths)
        XCTAssertNil(invocation.exception, file: file, line: line)
        XCTAssertNil(invocation.error, file: file, line: line)
        XCTAssertTrue(invocation.success, file: file, line: line)
    }

    private func refreshIndex() {
        let refreshed = expectation(description: "index refresh finished")
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(PBGitIndexFinishedIndexRefresh),
            object: repository.index,
            queue: .main
        ) { _ in
            refreshed.fulfill()
        }
        repository.index.refresh()
        wait(for: [refreshed], timeout: 10)
        NotificationCenter.default.removeObserver(token)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "RepositoryIgnoreCharacterizationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
