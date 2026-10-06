import XCTest

nonisolated enum RepositoryTestGitEnvironment {
    static func isolated(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false",
            "GIT_CONFIG_KEY_1": "tag.gpgsign", "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "init.templateDir", "GIT_CONFIG_VALUE_2": "/dev/null",
            "GIT_AUTHOR_NAME": "GitX Tests", "GIT_AUTHOR_EMAIL": "gitx-tests@example.invalid",
            "GIT_COMMITTER_NAME": "GitX Tests", "GIT_COMMITTER_EMAIL": "gitx-tests@example.invalid",
            "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
        ]) { _, value in value }
        return environment
    }

    static func prepare(_ task: PBTask) {
        task.setValue(isolated(task.value(forKey: "environment") as? [String: String] ?? [:]), forKey: "environment")
    }
}

final nonisolated class RepositoryTestGitRepository: PBGitRepository {
    override func task(withArguments arguments: [Any]?) -> PBTask {
        let task = super.task(withArguments: arguments)
        RepositoryTestGitEnvironment.prepare(task)
        return task
    }
}

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
    var environmentOverrides: [String: String] = [:]

    init(directory: String) {
        self.directory = directory
    }

    func output(withArguments arguments: [String]) throws -> String {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory)
        RepositoryTestGitEnvironment.prepare(task)
        task.additionalEnvironment = environmentOverrides
        _ = try task.launch()
        return task.standardOutputString() ?? ""
    }

    func historyOutput(withArguments arguments: [String]) throws -> String {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory)
        RepositoryTestGitEnvironment.prepare(task)
        task.additionalEnvironment = environmentOverrides.merging(["GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null"]) { _, value in value }
        try task.launch()
        return task.standardOutputString() ?? ""
    }

    func push(withArguments arguments: [String]) -> PBRepositoryPushCommandResult {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory)
        RepositoryTestGitEnvironment.prepare(task)
        task.additionalEnvironment = environmentOverrides
        task.separatesStandardError = true
        do {
            try task.launch()
            return PBRepositoryPushCommandResult(stdout: String(decoding: task.standardOutputData, as: UTF8.self), stderr: String(decoding: task.standardErrorData, as: UTF8.self), terminationStatus: 0, error: nil)
        } catch {
            return PBRepositoryPushCommandResult(stdout: String(decoding: task.standardOutputData, as: UTF8.self), stderr: String(decoding: task.standardErrorData, as: UTF8.self), terminationStatus: (error as NSError).userInfo[PBTaskTerminationStatusKey] as? NSNumber, error: error as NSError)
        }
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

        func historyOutput(withArguments arguments: [String]) throws -> String {
            try output(withArguments: arguments)
        }

        func push(withArguments arguments: [String]) -> PBRepositoryPushCommandResult {
            do {
                try launch(withArguments: arguments)
                return PBRepositoryPushCommandResult(stdout: lastOutput ?? "", stderr: "", terminationStatus: 0, error: nil)
            } catch {
                return PBRepositoryPushCommandResult(stdout: (error as NSError).userInfo[PBTaskTerminationOutputKey] as? String ?? "", stderr: "", terminationStatus: 1, error: error as NSError)
            }
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
        XCTAssertFalse(RepositoryRejectedPushRecoveryPolicy.decision(stdout: (error as NSError).userInfo[PBTaskTerminationOutputKey] as? String ?? "", snapshot: snapshot) == .eligible)
    }

    func testCopyDecisionBoundariesAndPatchCounts() {
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits([Bool](), isImmutable: { $0 }))
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits([false], isImmutable: { $0 }))
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits([true, false], isImmutable: { $0 }))
        XCTAssertTrue(CommitCopySelectionPolicy.canCopyImmutableCommits([true, true], isImmutable: { $0 }))
        var visited: [Int] = []
        XCTAssertFalse(CommitCopySelectionPolicy.canCopyImmutableCommits([1, 0, 2], isImmutable: { value in
            visited.append(value)
            return value != 0
        }))
        XCTAssertEqual(visited, [1, 0])
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

    @MainActor
    func testDialogSuppressionRequiresAnIdentifier() throws {
        #if DEBUG
            let unidentified = PBMilestone2ProductCoverageHarness.reviewSuppressionAlert(hasIdentifier: false, allowsSuppression: true)
            XCTAssertFalse(unidentified.showsSuppressionButton)
            let prohibited = PBMilestone2ProductCoverageHarness.reviewSuppressionAlert(hasIdentifier: true, allowsSuppression: false)
            XCTAssertFalse(prohibited.showsSuppressionButton)
            let identified = PBMilestone2ProductCoverageHarness.reviewSuppressionAlert(hasIdentifier: true, allowsSuppression: true)
            XCTAssertTrue(identified.showsSuppressionButton)
            try attachScreenshot(of: unidentified.window, named: "Unidentified dialog without suppression checkbox")
            try attachScreenshot(of: identified.window, named: "Identified dialog retains suppression checkbox")
        #else
            throw XCTSkip("Product harness is available in Debug")
        #endif
    }

    func testRejectedPushCoordinatorPreservesIntentAndEmitsOneTerminalEvent() throws {
        #if DEBUG
            XCTAssertEqual(PBMilestone2ProductCoverageHarness.rejectedPushRecoveryProof(), (1 << 12) - 1)
        #else
            throw XCTSkip("Product harness is available in Debug")
        #endif
    }

    @MainActor
    func testRetryCancellationPreservesDraftAndAllowsAnotherPRJourney() async throws {
        #if DEBUG
            let preservedAndReusable = await PBMilestone2ProductCoverageHarness.reviewRetryCancellationWorkflow()
            XCTAssertTrue(preservedAndReusable)
        #else
            throw XCTSkip("Product harness is available in Debug")
        #endif
    }

    func testAppReportsMissingHarnessRepositoryAndUsesTheChildWorkingDirectory() throws {
        #if DEBUG
            XCTAssertEqual(PBMilestone2ProductCoverageHarness.verificationBoundaryProof(), (1 << 9) - 1)
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
            ["push", "--", "origin"],
        ])

        runner.launchResults = [.success(())]
        runner.lastOutput = "remote: Open https://example.test/pull/42"
        error = nil
        XCTAssertTrue(service.pushBranch(nil, toRemote: remote, error: &error))
        XCTAssertEqual(service.lastPushOutput, "remote: Open https://example.test/pull/42")
    }

    private func rejection(_ summary: String = "[rejected] (non-fast-forward)", destination: String = "refs/heads/main") -> NSError {
        NSError(domain: PBTaskErrorDomain, code: 4, userInfo: [
            PBTaskTerminationOutputKey: "To /tmp/remote\n!\trefs/heads/main:\(destination)\t\(summary)\nDone\n",
        ])
    }

    private var snapshot: RepositoryPushSnapshot {
        RepositoryPushSnapshot(sourceRef: "refs/heads/main", sourceOID: String(repeating: "a", count: 40),
                               remoteName: "origin", endpoint: "/tmp/remote", destinationRef: "refs/heads/main", fetchedOID: String(repeating: "b", count: 40))
    }

    private final class PushRunnerFake: NSObject, PBGitCommandRunning {
        let source = String(repeating: "a", count: 40)
        let fetched = String(repeating: "b", count: 40)
        var lastOutput: String?
        var replies: [[String]: Result<String, Error>] = [:]
        var pushResults: [PBRepositoryPushCommandResult] = []
        var commands: [[String]] = []
        var pushes: [[String]] = []
        var config = "remote.origin.fetch\n+refs/heads/*:refs/remotes/origin/*\0branch.main.remote\norigin\0branch.main.merge\nrefs/heads/main\0"
        var destination = "refs/heads/main"
        var tracking = "refs/remotes/origin/main"
        init(eligible: Bool = true) {
            super.init()
            replies[["config", "--null", "--list"]] = .success(config)
            replies[["-c", "branch.main.remote=origin", "-c", "branch.main.pushRemote=origin", "-c", "push.default=current", "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream:remoteref)%00%(push:remoteref)%00%(push)%00%(push:remotename)", "refs/heads/main"]] = .success("refs/heads/main\0" + source + "\0refs/heads/main\0\0refs/remotes/origin/main\0origin\n")
            replies[["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", tracking]] = .success(tracking + "\0" + fetched + "\0commit\n")
            replies[["reflog", "show", "--format=%H", "refs/heads/main"]] = .success(eligible ? fetched + "\n" : source + "\n")
            replies[["remote", "get-url", "--all", "origin"]] = .success("/tmp/remote\n")
            replies[["remote", "get-url", "--push", "--all", "origin"]] = .success("/tmp/remote\n")
            replies[["rev-parse", "--is-shallow-repository"]] = .success("false\n")
            replies[["rev-list", "--no-walk", source, fetched, "--"]] = .success(source + "\n" + fetched + "\n")
            replies[["merge-base", "--is-ancestor", fetched, source]] = .failure(NSError(domain: PBTaskErrorDomain, code: 4, userInfo: [PBTaskTerminationStatusKey: 1]))
        }

        func output(withArguments arguments: [String]) throws -> String {
            commands.append(arguments)
            guard let reply = replies[arguments] else {
                XCTFail("Unexpected Git command: \(arguments)")
                throw NSError(domain: "unexpected-command", code: 1)
            }
            return try reply.get()
        }

        func historyOutput(withArguments arguments: [String]) throws -> String {
            try output(withArguments: arguments)
        }

        func launch(withArguments arguments: [String]) throws {
            XCTFail("Unexpected legacy launch: \(arguments)")
        }

        func push(withArguments arguments: [String]) -> PBRepositoryPushCommandResult {
            pushes.append(arguments)
            guard !pushResults.isEmpty else { XCTFail("Unexpected push"); return PBRepositoryPushCommandResult(stdout: "", stderr: "", terminationStatus: nil, error: NSError(domain: "unexpected-push", code: 1)) }
            return pushResults.removeFirst()
        }
    }

    private func rejectedResult(_ output: String? = nil, stderr: String = "", status: NSNumber? = 1) -> PBRepositoryPushCommandResult {
        PBRepositoryPushCommandResult(stdout: output ?? "To /tmp/remote\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n", stderr: stderr, terminationStatus: status, error: NSError(domain: PBTaskErrorDomain, code: 4))
    }

    func testRemoteServiceAttachesImmutablePlanAndRetriesWithoutReplacingSourceOrLease() throws {
        let repository = PBGitRepository()
        let runner = PushRunnerFake()
        runner.pushResults = [rejectedResult(), PBRepositoryPushCommandResult(stdout: "Done\n", stderr: "remote: Open https://example.test/pull/42", terminationStatus: 0, error: nil), rejectedResult()]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        XCTAssertEqual(plan.sourceOID, runner.source)
        XCTAssertEqual(plan.fetchedOID, runner.fetched)
        XCTAssertEqual(plan.endpoint, "/tmp/remote")
        let readCount = runner.commands.count
        XCTAssertTrue(service.retryPush(with: plan, error: &error))
        XCTAssertEqual(Array(runner.commands.dropFirst(readCount)), [["config", "--null", "--list"], ["remote", "get-url", "--all", "origin"], ["remote", "get-url", "--push", "--all", "origin"]])
        XCTAssertEqual(runner.pushes, [["push", "--porcelain", "--", "origin", "main"], ["push", "--porcelain", "--force-with-lease=refs/heads/main:" + String(repeating: "b", count: 40), "--", "origin", String(repeating: "a", count: 40) + ":refs/heads/main"]])
        XCTAssertTrue(service.lastPushOutput?.contains("https://example.test/pull/42") == true)
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
    }

    func testRecoveryExclusionsChangeOneConditionFromEligibleEvidence() {
        let mutations: [(PushRunnerFake) -> Void] = [
            { $0.replies[["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", $0.tracking]] = .success("") },
            { $0.replies[["reflog", "show", "--format=%H", "refs/heads/main"]] = .success($0.source + "\n") },
            { $0.replies[["rev-parse", "--is-shallow-repository"]] = .success("true\n") },
            { $0.replies[["remote", "get-url", "--push", "--all", "origin"]] = .success("/tmp/different\n") },
            { $0.replies[["remote", "get-url", "--all", "origin"]] = .success("/tmp/remote\n/tmp/second\n") },
            { $0.replies[["rev-list", "--no-walk", $0.source, $0.fetched, "--"]] = .failure(NSError(domain: PBTaskErrorDomain, code: 4)) },
            { $0.replies[["reflog", "show", "--format=%H", "refs/heads/main"]] = .success("invalid\n") },
            { $0.replies[["config", "--null", "--list"]] = .failure(NSError(domain: PBTaskErrorDomain, code: 4)) },
            { $0.replies[["config", "--null", "--list"]] = .success($0.config + "remote.origin.mirror\ntrue\0"); $0.replies[["config", "--type=bool", "--get", "remote.origin.mirror"]] = .success("true\n") },
            { $0.replies[["config", "--null", "--list"]] = .success($0.config + "push.followtags\ntrue\0"); $0.replies[["config", "--type=bool", "--get", "push.followtags"]] = .success("true\n") },
        ]
        for mutate in mutations {
            let runner = PushRunnerFake()
            mutate(runner)
            runner.pushResults = [rejectedResult()]
            let repository = PBGitRepository()
            let service = PBRepositoryRemoteService(repository: repository, runner: runner)
            var error: NSError?
            XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
            XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        }
    }

    func testDiscoveryAndAncestryFailuresDisableRecovery() {
        let metadataArguments = ["-c", "branch.main.remote=origin", "-c", "branch.main.pushRemote=origin", "-c", "push.default=current", "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream:remoteref)%00%(push:remoteref)%00%(push)%00%(push:remotename)", "refs/heads/main"]
        let mutations: [(PushRunnerFake) -> Void] = [
            { $0.replies[["config", "--null", "--list"]] = .success($0.config + "remote.origin.fetch\n+refs/other/*:refs/cache/*\0") },
            { $0.replies[["config", "--null", "--list"]] = .success($0.config + "remote.origin.mirror\ninvalid\0"); $0.replies[["config", "--type=bool", "--get", "remote.origin.mirror"]] = .success("invalid") },
            { $0.replies[metadataArguments] = .success("") },
            { $0.replies[metadataArguments] = .success("refs/heads/main\0" + $0.source + "\0\0refs/tags/main\0refs/remotes/origin/main\0origin") },
            { $0.replies[metadataArguments] = .success("refs/heads/main\0" + $0.source + "\0\0\0refs/heads/main\0origin") },
            { $0.replies[metadataArguments] = .success("refs/heads/main\0invalid\0\0\0refs/remotes/origin/main\0origin") },
            { $0.replies[["config", "--null", "--list"]] = .success($0.config + "remote.origin.push\nrefs/heads/missing:refs/heads/main\0") },
            { $0.replies[["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", $0.tracking]] = .success($0.tracking + "\0" + $0.fetched + "\0tag") },
        ]
        for mutate in mutations {
            let runner = PushRunnerFake()
            mutate(runner)
            runner.pushResults = [rejectedResult()]
            let repository = PBGitRepository()
            let service = PBRepositoryRemoteService(repository: repository, runner: runner)
            var error: NSError?
            XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
            XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        }
    }

    func testAncestryCommandFailuresChangeOneConditionFromIntegratedHistory() {
        let failures = [
            NSError(domain: PBTaskErrorDomain, code: 4, userInfo: [PBTaskTerminationStatusKey: 128]),
            NSError(domain: "unexpected-command-error", code: 4, userInfo: [PBTaskTerminationStatusKey: 1]),
            NSError(domain: PBTaskErrorDomain, code: 2, userInfo: [PBTaskTerminationStatusKey: 1]),
        ]
        for failure in failures {
            let runner = PushRunnerFake(eligible: false)
            let ancestry = ["merge-base", "--is-ancestor", runner.fetched, runner.source]
            runner.replies[ancestry] = .success("")
            runner.pushResults = [rejectedResult(), rejectedResult()]
            let repository = PBGitRepository()
            let service = PBRepositoryRemoteService(repository: repository, runner: runner)
            var error: NSError?
            XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
            XCTAssertNotNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
            // The same captured graph is eligible until this one command fails.
            runner.replies[ancestry] = .failure(failure)
            XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
            XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        }
    }

    func testMissingTrackingStopsBeforeReadingBranchHistory() {
        let runner = PushRunnerFake()
        runner.replies[["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", runner.tracking]] = .success("")
        runner.pushResults = [rejectedResult()]
        let repository = PBGitRepository()
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: nil))
        XCTAssertFalse(runner.commands.contains { ["reflog", "remote", "rev-list", "merge-base"].contains($0.first ?? "") })
    }

    func testCapturedConfigurationIncludesTransportAndRewriteSettingsOnly() {
        let values = RepositoryPushConfiguration.values("push.followtags\0remote.origin.url\nhttps://dummy:password@example.invalid/repo\0core.editor\nvi\0url.file:///tmp/.insteadof\ngit@example.invalid:\0core.sshcommand\nssh-wrapper\0")
        XCTAssertEqual(values["push.followtags"], ["true"])
        let relevant = RepositoryPushConfiguration.relevant(values, remote: "origin", branch: "main")
        XCTAssertNil(relevant["core.editor"])
        XCTAssertEqual(relevant["url.file:///tmp/.insteadof"], ["git@example.invalid:"])
        XCTAssertEqual(relevant["core.sshcommand"], ["ssh-wrapper"])
    }

    func testSuccessfulPushDefersEndpointAndAncestryWork() {
        let runner = PushRunnerFake()
        runner.pushResults = [PBRepositoryPushCommandResult(stdout: "Done\n", stderr: "browser hint", terminationStatus: 0, error: nil)]
        let repository = PBGitRepository()
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        XCTAssertTrue(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: nil))
        XCTAssertFalse(runner.commands.contains { $0.first == "remote" || $0.first == "merge-base" || $0.first == "rev-list" })
    }

    func testConfigurationDriftRequiresFreshPushWithoutRetryLaunch() throws {
        let runner = PushRunnerFake()
        runner.pushResults = [rejectedResult()]
        let repository = PBGitRepository()
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        runner.replies[["config", "--null", "--list"]] = .success(runner.config + "remote.origin.receivepack\ncustom-pack\0")
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        XCTAssertTrue(error?.localizedFailureReason?.contains("fresh push") == true)
        XCTAssertEqual(runner.pushes.count, 1)
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

    func testStructuredRejectionRequiresOneCompleteLiteralLFEnvelope() {
        let valid = "To /tmp/remote\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n"
        XCTAssertEqual(RepositoryRejectedPushRecoveryPolicy.decision(stdout: valid, snapshot: snapshot), .eligible)
        XCTAssertNotEqual(RepositoryRejectedPushRecoveryPolicy.decision(stdout: valid, snapshot: nil), .eligible)
        for output in ["", "fatal: Authentication failed", valid.replacingOccurrences(of: "(non-fast-forward)", with: "(fetch first)"),
                       valid.replacingOccurrences(of: "[rejected]", with: "[remote rejected]"),
                       valid.replacingOccurrences(of: "refs/heads/main:refs/heads/main", with: "refs/heads/other:refs/heads/main"),
                       valid.replacingOccurrences(of: "!\t", with: "=\t"), valid.replacingOccurrences(of: "Done\n", with: ""),
                       valid.replacingOccurrences(of: "\n", with: "\u{2028}"), valid.replacingOccurrences(of: "\n", with: "\u{2029}"),
                       valid.replacingOccurrences(of: "\n", with: "\r\n"), valid + valid,
                       valid.replacingOccurrences(of: "Done", with: "!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone")]
        {
            XCTAssertNotEqual(RepositoryRejectedPushRecoveryPolicy.decision(stdout: output, snapshot: snapshot), .eligible, output)
        }
        XCTAssertTrue(RepositoryPushSnapshot.isOID(String(repeating: "A", count: 64)))
        XCTAssertFalse(RepositoryPushSnapshot.isOID(String(repeating: "z", count: 40)))
        XCTAssertFalse(RepositoryPushSnapshot.isOID(""))
    }

    func testStderrCannotSupplyPushStatusOrCredentialsToDiagnostics() {
        let runner = PushRunnerFake()
        runner.pushResults = [rejectedResult("", stderr: "To https://dummy:password@example.invalid/repo\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n")]
        let repository = PBGitRepository()
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        let diagnostic = (error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.userInfo[PBTaskTerminationOutputKey] as? String ?? ""
        XCTAssertFalse(diagnostic.contains("dummy:password"))
        XCTAssertTrue(diagnostic.contains("[redacted]@example.invalid"))
    }

    @MainActor
    func testShippedFailureSheetDisplaysReadableRedactedBranchStatus() throws {
        #if DEBUG
            let runner = PushRunnerFake()
            runner.pushResults = [rejectedResult("To https://dummy:password@example.invalid/repo\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n")]
            let repository = PBGitRepository()
            let service = PBRepositoryRemoteService(repository: repository, runner: runner)
            var error: NSError?
            XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
            let window = try PBMilestone2ProductCoverageHarness.reviewPushFailureWindow(error: XCTUnwrap(error))
            defer {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }; window.close()
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.attachedSheet != nil }, object: nil)
            wait(for: [ready], timeout: 5)
            let sheet = try XCTUnwrap(window.attachedSheet)
            func text(in view: NSView) -> String {
                let current = (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue ?? ""
                return ([current] + view.subviews.map { text(in: $0) }).joined(separator: "\n")
            }
            let displayed = try text(in: XCTUnwrap(sheet.contentView))
            XCTAssertTrue(displayed.contains("refs/heads/main → refs/heads/main: [rejected] (non-fast-forward)"))
            XCTAssertTrue(displayed.contains("[redacted]@example.invalid"))
            XCTAssertFalse(displayed.contains("dummy:password"))
            XCTAssertFalse(displayed.contains("Done"))
            try attachScreenshot(of: sheet, named: "Readable rejected branch push with redacted credentials")
        #endif
    }

    func testCyclicErrorChainsTerminateAndNestedPlansRemainAvailable() throws {
        let first = CyclicRepositoryError(domain: "cycle", code: 1)
        let second = CyclicRepositoryError(domain: "cycle", code: 2)
        first.underlying = second
        second.underlying = first
        XCTAssertNil(PBRepositoryPushRetryPlan.plan(forError: first))
        let repository = PBGitRepository()
        let runner = PushRunnerFake()
        runner.pushResults = [rejectedResult()]
        let service = PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        let plan = try XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        let outer = try NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: XCTUnwrap(error)])
        XCTAssertTrue(PBRepositoryPushRetryPlan.plan(forError: outer) === plan)
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
        repository = try RepositoryTestGitRepository(url: repositoryURL)
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
        let service = PBRepositoryRemoteService(repository: repository)
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
        let service = PBRepositoryRemoteService(repository: repository)
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
        XCTAssertEqual(try runner.output(withArguments: ["rev-parse", "refs/remotes/origin/main"]).trimmingCharacters(in: .newlines), frozenSource)
    }

    private func prepareRecoveryRemote(destination: String = "main", fetch: String? = nil) throws -> (LocalGitRunner, URL) {
        let runner = LocalGitRunner(directory: repositoryURL.path)
        let bare = repositoryURL.appendingPathComponent("remote.git")
        _ = try runner.output(withArguments: ["init", "--bare", "--quiet", bare.path])
        try runGit(["remote", "add", "origin", bare.path])
        if let fetch {
            try runGit(["config", "remote.origin.fetch", fetch])
        }
        try runGit(["push", "--quiet", "origin", "main:" + destination])
        try runGit(["fetch", "--quiet", "origin"])
        return (runner, bare)
    }

    private func rejectedPlan(runner: LocalGitRunner, branch: String = "main", useShippedRunner: Bool = true) throws -> (PBRepositoryRemoteService, PBRepositoryPushRetryPlan) {
        let service = useShippedRunner ? PBRepositoryRemoteService(repository: repository) : PBRepositoryRemoteService(repository: repository, runner: runner)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/" + branch), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        return try (service, XCTUnwrap(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) }, taskOutput(error)))
    }

    func testSameBranchTraversalIgnoresCommitsWithoutCachedOID() throws {
        let gitRepository = try XCTUnwrap(repository.gtRepo)
        let ancestor = try XCTUnwrap(gitRepository.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        try runGit(["commit", "--quiet", "--allow-empty", "-m", "descendant"])
        let descendant = try XCTUnwrap(gitRepository.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        let commits = [PBGitCommit(), PBGitCommit(repository: repository, andCommit: descendant), PBGitCommit(repository: repository, andCommit: ancestor)]
        let store = PBRepositoryReferenceStore(repository: repository, runner: LocalGitRunner(directory: repositoryURL.path))
        XCTAssertTrue(store.isOID(descendant.oid, onSameBranchAs: ancestor.oid, commits: commits))
        XCTAssertFalse(store.isOID(ancestor.oid, onSameBranchAs: descendant.oid, commits: commits))
        XCTAssertFalse(store.isOID(descendant.oid, onSameBranchAs: ancestor.oid, commits: [PBGitCommit()]))
    }

    func testFetchedButUnintegratedRemoteWorkCannotRecover() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        let other = repositoryURL.appendingPathComponent("other")
        _ = try runner.output(withArguments: ["clone", "--quiet", "--branch", "main", bare.path, other.path])
        let otherRunner = LocalGitRunner(directory: other.path)
        _ = try otherRunner.output(withArguments: ["commit", "--quiet", "--allow-empty", "-m", "unintegrated remote work"])
        _ = try otherRunner.output(withArguments: ["push", "--quiet", "origin", "main"])
        try runGit(["fetch", "--quiet", "origin"])
        try runGit(["commit", "--quiet", "--amend", "-m", "local rewrite"])
        let service = PBRepositoryRemoteService(repository: repository)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]), try otherRunner.output(withArguments: ["rev-parse", "HEAD"]))
    }

    func testUpstreamTopicToMainRecoveryUsesNativeDestinationAndUpdatesTracking() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        try runGit(["branch", "-m", "topic"])
        try runGit(["config", "branch.topic.remote", "origin"])
        try runGit(["config", "branch.topic.merge", "refs/heads/main"])
        try runGit(["config", "push.default", "upstream"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten topic"])
        let (service, plan) = try rejectedPlan(runner: runner, branch: "topic")
        XCTAssertEqual(plan.destinationRef, "refs/heads/main")
        XCTAssertTrue(service.retryPush(with: plan, error: nil))
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
        XCTAssertEqual(try runner.output(withArguments: ["rev-parse", "refs/remotes/origin/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
    }

    func testQualifiedExactPushMappingPreservesCustomTrackingNamespace() throws {
        let (runner, bare) = try prepareRecoveryRemote(destination: "review/main", fetch: "+refs/heads/*:refs/cache/origin/*")
        try runGit(["config", "remote.origin.push", "refs/heads/main:refs/heads/review/main"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten exact"])
        let (service, plan) = try rejectedPlan(runner: runner)
        XCTAssertEqual(plan.destinationRef, "refs/heads/review/main")
        XCTAssertTrue(service.retryPush(with: plan, error: nil))
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/review/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
        XCTAssertEqual(try runner.output(withArguments: ["rev-parse", "refs/cache/origin/review/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
    }

    func testQualifiedWildcardPushMappingPreservesCustomTrackingNamespace() throws {
        let (runner, _) = try prepareRecoveryRemote(destination: "review/main", fetch: "+refs/heads/*:refs/cache/origin/*")
        try runGit(["config", "remote.origin.push", "refs/heads/*:refs/heads/review/*"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten wildcard"])
        let (service, plan) = try rejectedPlan(runner: runner)
        XCTAssertEqual(plan.destinationRef, "refs/heads/review/main")
        XCTAssertTrue(service.retryPush(with: plan, error: nil))
        XCTAssertEqual(try runner.output(withArguments: ["rev-parse", "refs/cache/origin/review/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
    }

    func testRemoteSettingsDriftRequiresFreshPush() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let (service, plan) = try rejectedPlan(runner: runner)
        try runGit(["config", "remote.origin.receivepack", "git-receive-pack"])
        var error: NSError?
        XCTAssertFalse(service.retryPush(with: plan, error: &error))
        XCTAssertFalse(service.commandWasLaunched)
        XCTAssertTrue(error?.localizedFailureReason?.contains("fresh push") == true)
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .newlines), plan.fetchedOID)
    }

    func testRetryPreservesNamedRemoteHookIdentityAndConfiguredReceivePack() throws {
        let (runner, _) = try prepareRecoveryRemote()
        let hookMarker = repositoryURL.appendingPathComponent("hook-marker")
        let transportMarker = repositoryURL.appendingPathComponent("transport-marker")
        try FileManager.default.createDirectory(at: repositoryURL.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        let hook = repositoryURL.appendingPathComponent(".git/hooks/pre-push")
        let receivePack = repositoryURL.appendingPathComponent("receive-pack")
        func quoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" > \(quoted(hookMarker.path))\ncat >/dev/null\n".write(to: hook, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'called\\n' >> \(quoted(transportMarker.path))\nexec /usr/bin/git-receive-pack \"$@\"\n".write(to: receivePack, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: receivePack.path)
        try runGit(["config", "remote.origin.receivepack", receivePack.path])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let (service, plan) = try rejectedPlan(runner: runner)
        XCTAssertTrue(service.retryPush(with: plan, error: nil))
        XCTAssertEqual(try String(contentsOf: hookMarker, encoding: .utf8), "origin\n")
        XCTAssertEqual(try String(contentsOf: transportMarker, encoding: .utf8), "called\ncalled\n")
    }

    func testShippedPushRunnerKeepsHookStatusAndCredentialsOutOfRecovery() throws {
        _ = try prepareRecoveryRemote()
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        try FileManager.default.createDirectory(at: repositoryURL.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        let hook = repositoryURL.appendingPathComponent(".git/hooks/pre-push")
        let spoof = "To https://dummy:password@example.invalid/repo\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n"
        try ("#!/bin/sh\ncat >/dev/null\ncat >&2 <<'STATUS'\n" + spoof + "STATUS\nexit 1\n").write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let service = PBRepositoryRemoteService(repository: repository)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        XCTAssertFalse(String(describing: error).contains("dummy:password"))
        XCTAssertTrue(taskOutput(error).contains("[redacted]@example.invalid"))
    }

    func testRemoteAdvanceBeforeOriginalAttemptRemainsProtectedByCapturedLease() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        let other = repositoryURL.appendingPathComponent("other")
        _ = try runner.output(withArguments: ["clone", "--quiet", "--branch", "main", bare.path, other.path])
        let otherRunner = LocalGitRunner(directory: other.path)
        _ = try otherRunner.output(withArguments: ["commit", "--quiet", "--allow-empty", "-m", "newer remote"])
        _ = try otherRunner.output(withArguments: ["push", "--quiet", "origin", "main"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let service = PBRepositoryRemoteService(repository: repository)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        // Git normally reports fetch first here, which must never offer recovery.
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]), try otherRunner.output(withArguments: ["rev-parse", "HEAD"]))
    }

    func testEffectiveEmptyAndLocalFalseBooleansPermitRecovery() throws {
        let (runner, _) = try prepareRecoveryRemote()
        let global = repositoryURL.appendingPathComponent("fixture-global-config")
        try "[push]\n\tfollowTags = true\n[remote \"origin\"]\n\tmirror = true\n".write(to: global, atomically: true, encoding: .utf8)
        runner.environmentOverrides = ["GIT_CONFIG_GLOBAL": global.path]
        for value in ["false", ""] {
            try runGit(["config", "push.followTags", value])
            try runGit(["config", "remote.origin.mirror", value])
            try runGit(["commit", "--quiet", "--amend", "-m", "rewritten " + value])
            let (service, plan) = try rejectedPlan(runner: runner, useShippedRunner: false)
            XCTAssertTrue(service.retryPush(with: plan, error: nil))
        }
    }

    func testShallowHistoryAndExpiredBranchEvidenceDisableRecovery() throws {
        let (runner, _) = try prepareRecoveryRemote()
        let old = try runner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let shallow = repositoryURL.appendingPathComponent(".git/shallow")
        try (old + "\n").write(to: shallow, atomically: true, encoding: .utf8)
        let service = PBRepositoryRemoteService(repository: repository)
        var error: NSError?
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
        try FileManager.default.removeItem(at: shallow)
        try runGit(["reflog", "expire", "--expire=now", "refs/heads/main"])
        XCTAssertFalse(service.pushBranch(PBGitRef(string: "refs/heads/main"), toRemote: PBGitRef(string: "refs/remotes/origin"), error: &error))
        XCTAssertNil(error.flatMap { PBRepositoryPushRetryPlan.plan(forError: $0) })
    }

    func testShippedAncestryIgnoresLocalGrafts() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        let other = repositoryURL.appendingPathComponent("other")
        _ = try runner.output(withArguments: ["clone", "--quiet", "--branch", "main", bare.path, other.path])
        let otherRunner = LocalGitRunner(directory: other.path)
        _ = try otherRunner.output(withArguments: ["commit", "--quiet", "--allow-empty", "-m", "unintegrated remote"])
        _ = try otherRunner.output(withArguments: ["push", "--quiet", "origin", "main"])
        try runGit(["fetch", "--quiet", "origin"])
        try runGit(["commit", "--quiet", "--amend", "-m", "rewritten"])
        let source = try runner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        let fetched = try otherRunner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try FileManager.default.createDirectory(at: repositoryURL.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try (source + " " + fetched + "\n").write(to: repositoryURL.appendingPathComponent(".git/info/grafts"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try runner.output(withArguments: ["merge-base", "--is-ancestor", fetched, source]))
        #if DEBUG
            XCTAssertThrowsError(try PBMilestone2ProductCoverageHarness.reviewHistoryOutput(repository: repository, arguments: ["merge-base", "--is-ancestor", fetched, source])) { error in
                XCTAssertEqual((error as NSError).userInfo[PBTaskTerminationStatusKey] as? Int, 1)
            }
        #endif
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .newlines), fetched)
    }

    func testRebaseCanRecoverUsingAncestorOfCapturedReflogEntry() throws {
        let (runner, bare) = try prepareRecoveryRemote()
        let base = try runner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try runGit(["commit", "--quiet", "--allow-empty", "-m", "integrated remote tip"])
        let fetched = try runner.output(withArguments: ["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try runGit(["push", "--quiet", "origin", "main"])
        try runGit(["fetch", "--quiet", "origin"])
        try runGit(["commit", "--quiet", "--allow-empty", "-m", "local descendant"])
        try runGit(["rebase", "--quiet", "--keep-empty", "--onto", base, fetched])
        let entries = try runner.output(withArguments: ["reflog", "show", "--format=%H", "refs/heads/main"]).split(separator: "\n").map(String.init)
        for index in entries.indices.reversed() where entries[index] == fetched {
            try runGit(["reflog", "delete", "refs/heads/main@{\(index)}"])
        }
        let (service, plan) = try rejectedPlan(runner: runner)
        XCTAssertEqual(plan.fetchedOID, fetched)
        XCTAssertTrue(service.retryPush(with: plan, error: nil))
        XCTAssertEqual(try runner.output(withArguments: ["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).trimmingCharacters(in: .newlines), plan.sourceOID)
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
        let linkedRepository = try RepositoryTestGitRepository(url: linkedURL)
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
        process.environment = RepositoryTestGitEnvironment.isolated()
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
            repository = try RepositoryTestGitRepository(url: repositoryURL)
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
        process.environment = RepositoryTestGitEnvironment.isolated()
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
