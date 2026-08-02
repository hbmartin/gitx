import ForgeKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

private nonisolated enum RepositoryPullRequestDiffCommandOptions {
    static var arguments: [String] {
        DiffCommandOptions.arguments
    }
}

nonisolated struct RepositoryLocalPullRequestDiff: Equatable, Sendable {
    let title: String
    let patch: String
    let cacheIdentifier: String
}

nonisolated protocol RepositoryPullRequestChangesProviding: Sendable {
    func changes(
        repository: ForgeRepositoryIdentity,
        base: ForgeBranchReference,
        head: ForgeBranchReference
    ) async throws -> RepositoryLocalPullRequestDiff
}

/// The repository object is confined to this serial operation queue, matching the
/// existing History and staging diff producers. Only immutable Forge values cross it.
// swift6-safety-justification: every repository access is serialized by `queue` and results are Sendable values.
private final nonisolated class RepositoryPullRequestDiffWorker: @unchecked Sendable {
    private let repository: PBGitRepository
    private let queue = OperationQueue()

    init(repository: PBGitRepository) {
        self.repository = repository
        queue.name = "com.gitx.gitx.pull-request-local-diff"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func changes(
        repository forgeRepository: ForgeRepositoryIdentity,
        base: ForgeBranchReference,
        head: ForgeBranchReference
    ) async throws -> RepositoryLocalPullRequestDiff {
        guard forgeRepository == base.repository,
              forgeRepository.forge == head.repository.forge
        else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [self] in
                do {
                    let mergeBase = try self.repository.outputOfTask(withArguments: [
                        "merge-base", base.commit.value, head.commit.value,
                    ]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !mergeBase.isEmpty else {
                        throw RepositoryPullRequestServiceError.localDiffUnavailable
                    }
                    var arguments = ["diff"]
                    arguments.append(contentsOf: RepositoryPullRequestDiffCommandOptions.arguments)
                    arguments.append(contentsOf: [
                        "--find-renames", "--no-ext-diff", mergeBase, head.commit.value,
                    ])
                    let patch = try self.repository.outputOfTask(withArguments: arguments)
                    continuation.resume(returning: RepositoryLocalPullRequestDiff(
                        title: "Changes from \(base.name.value) to \(head.name.value)",
                        patch: patch,
                        cacheIdentifier: "pr-local-\(mergeBase)-\(head.commit.value)"
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

nonisolated struct RepositoryLocalPullRequestChangesProvider: RepositoryPullRequestChangesProviding {
    private let worker: RepositoryPullRequestDiffWorker

    init(repository: PBGitRepository) {
        worker = RepositoryPullRequestDiffWorker(repository: repository)
    }

    func changes(
        repository: ForgeRepositoryIdentity,
        base: ForgeBranchReference,
        head: ForgeBranchReference
    ) async throws -> RepositoryLocalPullRequestDiff {
        try await worker.changes(repository: repository, base: base, head: head)
    }
}

// MARK: - Explicit Pull Request checkout

nonisolated protocol RepositoryPullRequestGitCommandRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) throws -> String
}

nonisolated enum RepositoryForgeProcessError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed
    case commandFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            "GitX could not start Git for the clone operation."
        case let .commandFailed(exitCode):
            "Git could not clone the repository (exit code \(exitCode))."
        }
    }
}

/// Executes one explicit clone command without retaining or logging command
/// output, which may contain credential-helper diagnostics.
nonisolated struct RepositoryForgeProcessGitRunner: RepositoryPullRequestGitCommandRunning {
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PBGitBinary.path())
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw RepositoryForgeProcessError.launchFailed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RepositoryForgeProcessError.commandFailed(exitCode: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// ObjectiveGit's task runner is used from one serial workflow executor.
// swift6-safety-justification: the command runner is invoked serially and never exposes its Objective-C repository.
final nonisolated class RepositoryPullRequestObjectiveGitRunner: RepositoryPullRequestGitCommandRunning,
    @unchecked Sendable
{
    private let repository: PBGitRepository

    init(repository: PBGitRepository) {
        self.repository = repository
    }

    func run(_ arguments: [String]) throws -> String {
        try repository.outputOfTask(withArguments: arguments)
    }
}

nonisolated struct RepositoryPullRequestCheckoutReceipt: Equatable, Sendable {
    let localBranch: ForgeRefName
    let remoteName: String
    let addedRemote: Bool
    let fetchedHead: ForgeCommitID
}

/// Builds the provider-neutral checkout plan from a serialized snapshot of the
/// current local repository immediately before the user confirms checkout.
// swift6-safety-justification: all ObjectiveGit access is confined to one serial queue.
final nonisolated class RepositoryPullRequestCheckoutPlanner: @unchecked Sendable {
    private let repository: PBGitRepository
    private let queue = OperationQueue()

    init(repository: PBGitRepository) {
        self.repository = repository
        queue.name = "com.gitx.gitx.pull-request-checkout-planning"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func plan(for pullRequest: ForgePullRequestSummary) async throws -> ForgePullRequestCheckoutPlan {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [self] in
                do {
                    let status = try self.repository.outputOfTask(withArguments: [
                        "status", "--porcelain=v2", "--untracked-files=normal",
                    ]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let workingState = ForgeLocalWorkingState(
                        stagedCount: status.isEmpty ? 0 : 1,
                        unstagedCount: 0,
                        untrackedCount: 0,
                        conflictCount: 0,
                        operationName: nil
                    )
                    let remoteNames = try self.repository.outputOfTask(withArguments: ["remote"])
                        .components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }
                    let remotes = try remoteNames.compactMap { name -> ForgeGitRemote? in
                        let rawURL = try self.repository.outputOfTask(withArguments: ["remote", "get-url", name])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let normalizedURL = Self.normalizedRemoteURL(rawURL) else { return nil }
                        let identity = try? ForgeRemoteParser.parse(rawURL).repository
                        return try ForgeGitRemote(name: name, repository: identity, fetchURL: normalizedURL)
                    }
                    let branches = try Set(self.repository.outputOfTask(withArguments: [
                        "for-each-ref", "--format=%(refname:short)", "refs/heads",
                    ]).components(separatedBy: .newlines).filter { !$0.isEmpty }.map(ForgeRefName.init))
                    guard case let .available(head) = pullRequest.head else {
                        throw ForgePullRequestWorkflowError.headReferenceUnavailable
                    }
                    let path = (head.repository.ownerPathComponents + [head.repository.name + ".git"])
                        .map(Self.percentEncodedPathComponent)
                        .joined(separator: "/")
                    guard let headURL = URL(string: "https://github.com/\(path)") else {
                        throw ForgePullRequestWorkflowError.invalidRemoteURL
                    }
                    try continuation.resume(returning: ForgePullRequestCheckoutPolicy.plan(
                        pullRequest: pullRequest,
                        workingState: workingState,
                        remotes: remotes,
                        existingLocalBranches: branches,
                        headRemoteURL: headURL
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func normalizedRemoteURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        guard let separator = raw.firstIndex(of: ":"), raw[..<separator].contains("@") else { return nil }
        let authority = raw[..<separator]
        let path = raw[raw.index(after: separator)...]
        return URL(string: "ssh://\(authority)/\(path)")
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? value
    }
}

nonisolated struct RepositoryPullRequestCheckoutExecutor: Sendable {
    private let runner: any RepositoryPullRequestGitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestCheckout")

    init(runner: any RepositoryPullRequestGitCommandRunning) {
        self.runner = runner
    }

    init(repository: PBGitRepository) {
        runner = RepositoryPullRequestObjectiveGitRunner(repository: repository)
    }

    func execute(_ plan: ForgePullRequestCheckoutPlan) throws -> RepositoryPullRequestCheckoutReceipt {
        try ensureSafeWorkingState()
        if plan.addsRemote {
            _ = try runner.run(["remote", "add", plan.remote.name, plan.remote.fetchURL.absoluteString])
            // A contributor remote added for checkout is deliberately narrow: no broad
            // wildcard fetch is retained, only the exact branch approved by the plan.
            _ = try? runner.run(["config", "--unset-all", "remote.\(plan.remote.name).fetch"])
            _ = try runner.run([
                "config", "--add", "remote.\(plan.remote.name).fetch", plan.fetchRefspec,
            ])
        } else {
            let configured = (try? runner.run([
                "config", "--get-all", "remote.\(plan.remote.name).fetch",
            ])) ?? ""
            if !configured.components(separatedBy: .newlines).contains(plan.fetchRefspec) {
                _ = try runner.run([
                    "config", "--add", "remote.\(plan.remote.name).fetch", plan.fetchRefspec,
                ])
            }
        }

        _ = try runner.run(["fetch", "--no-tags", plan.remote.name, plan.fetchRefspec])
        let remoteTracking = String(plan.fetchRefspec.split(separator: ":", maxSplits: 1)[1])
        let fetched = try ForgeCommitID(runner.run([
            "rev-parse", "--verify", remoteTracking,
        ]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard fetched == plan.expectedHead else {
            throw RepositoryPullRequestServiceError.checkoutVerificationFailed
        }

        // Create the named branch before switching. If checkout reports a conflict,
        // the branch remains visible for the user's explicit manual resolution.
        _ = try runner.run(["branch", plan.localBranch.value, fetched.value])
        _ = try runner.run(["switch", plan.localBranch.value])
        logger.notice(
            "Checked out Pull Request using explicit remote/refspec; addedRemote=\(plan.addsRemote, privacy: .public)"
        )
        return RepositoryPullRequestCheckoutReceipt(
            localBranch: plan.localBranch,
            remoteName: plan.remote.name,
            addedRemote: plan.addsRemote,
            fetchedHead: fetched
        )
    }

    private func ensureSafeWorkingState() throws {
        let status = try runner.run([
            "status", "--porcelain=v2", "--untracked-files=normal",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ask this exact repository rather than resolving a possibly relative
        // `--git-dir` against the process working directory.
        let operationRefs = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"]
        let operationActive = operationRefs.contains { name in
            (try? runner.run(["rev-parse", "--verify", "--quiet", name])) != nil
        }
        guard status.isEmpty, !operationActive else {
            throw ForgePullRequestWorkflowError.unsafeWorkingState
        }
    }
}

// MARK: - Sync Fork local reconciliation

nonisolated struct RepositorySyncForkReceipt: Equatable, Sendable {
    let serverSummary: String
    let fetchedRemote: String
    let fetchedBranch: ForgeRefName
}

nonisolated enum RepositorySyncForkError: Error, Equatable, LocalizedError, Sendable {
    case localFetchFailed(serverSummary: String)

    var errorDescription: String? {
        switch self {
        case let .localFetchFailed(serverSummary):
            "\(serverSummary) The server-side fork sync completed, but GitX could not fetch the updated branch."
        }
    }
}

nonisolated struct RepositorySyncForkCoordinator: Sendable {
    private let service: any RepositoryPullRequestMutationServing
    private let runner: any RepositoryPullRequestGitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "SyncFork")

    init(
        service: any RepositoryPullRequestMutationServing,
        runner: any RepositoryPullRequestGitCommandRunning
    ) {
        self.service = service
        self.runner = runner
    }

    func sync(
        accountID: ForgeAccountID,
        plan: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkReceipt {
        let server = try await service.syncFork(accountID: accountID, plan: plan)
        do {
            _ = try runner.run([
                "fetch", "--no-tags", plan.localFetchRemoteName,
                "+refs/heads/\(plan.branch.value):refs/remotes/\(plan.localFetchRemoteName)/\(plan.branch.value)",
            ])
        } catch {
            throw RepositorySyncForkError.localFetchFailed(serverSummary: server.serverSummary)
        }
        logger.notice("Completed server-side Sync Fork and explicit local fetch")
        return RepositorySyncForkReceipt(
            serverSummary: server.serverSummary,
            fetchedRemote: plan.localFetchRemoteName,
            fetchedBranch: plan.branch
        )
    }
}

// MARK: - Owned and organization repository clone

nonisolated struct RepositoryForgeCloneChoice: Hashable, Sendable {
    let request: ForgeCloneRequest
    let destinationDirectory: URL

    init(request: ForgeCloneRequest, destinationDirectory: URL) throws {
        guard destinationDirectory.isFileURL else {
            throw ForgePullRequestWorkflowError.invalidRemoteURL
        }
        self.request = request
        self.destinationDirectory = destinationDirectory.standardizedFileURL
    }
}

nonisolated enum RepositoryForgeCloneURLPolicy {
    static func url(for request: ForgeCloneRequest) throws -> URL {
        guard request.repository.forge.kind == .github,
              request.repository.forge.origin.host.lowercased() == "github.com"
        else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        let owner = request.repository.ownerPathComponents.joined(separator: "/")
        switch request.transport {
        case .ssh:
            guard let url = URL(string: "ssh://git@github.com/\(owner)/\(request.repository.name).git") else {
                throw ForgePullRequestWorkflowError.invalidRemoteURL
            }
            return url
        case .https:
            guard let url = URL(string: "https://github.com/\(owner)/\(request.repository.name).git") else {
                throw ForgePullRequestWorkflowError.invalidRemoteURL
            }
            return url
        }
    }
}

nonisolated struct RepositoryForgeCloneReceipt: Equatable, Sendable {
    let repository: ForgeRepositoryIdentity
    let destinationURL: URL
    let transport: ForgeCloneTransport
}

nonisolated struct RepositoryForgeCloneExecutor: Sendable {
    private let runner: any RepositoryPullRequestGitCommandRunning

    init(runner: any RepositoryPullRequestGitCommandRunning) {
        self.runner = runner
    }

    func clone(_ choice: RepositoryForgeCloneChoice) throws -> RepositoryForgeCloneReceipt {
        let remoteURL = try RepositoryForgeCloneURLPolicy.url(for: choice.request)
        let destination = choice.destinationDirectory.appendingPathComponent(
            choice.request.repository.name,
            isDirectory: true
        )
        _ = try runner.run(["clone", "--origin", "origin", remoteURL.absoluteString, destination.path])
        return RepositoryForgeCloneReceipt(
            repository: choice.request.repository,
            destinationURL: destination,
            transport: choice.request.transport
        )
    }
}

// MARK: - Create Pull Request preparation

// swift6-safety-justification: the lock linearizes parent cancellation with detached task installation.
final nonisolated class RepositoryPullRequestPreparationTaskOwnership: @unchecked Sendable {
    typealias PreparationTask = Task<RepositoryPullRequestCreationPreparation, Error>

    private let lock = NSLock()
    private var task: PreparationTask?
    private var cancelled = false

    func install(_ task: PreparationTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            self.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> PreparationTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// Builds the provider-neutral Create Pull Request input exclusively from the
/// exact bound remotes and local Git objects. Repository templates and commit
/// heuristics therefore remain available offline after the live account and
/// default-branch authorization preflight succeeds.
nonisolated struct RepositoryPullRequestLocalPreparationSource:
    RepositoryPullRequestLocalPreparationProviding, Sendable
{
    private let runner: any RepositoryPullRequestGitCommandRunning

    init(runner: any RepositoryPullRequestGitCommandRunning) {
        self.runner = runner
    }

    init(repository: PBGitRepository) {
        runner = RepositoryPullRequestObjectiveGitRunner(repository: repository)
    }

    func preparation(
        accountID: ForgeAccountID,
        binding: ForgeRepositoryBinding,
        localBranch: ForgeRefName,
        localHead: ForgeCommitID,
        defaultBranch: ForgeRefName
    ) async throws -> RepositoryPullRequestCreationPreparation {
        let ownership = RepositoryPullRequestPreparationTaskOwnership()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let task = Task.detached(priority: .userInitiated) {
                try prepare(
                    accountID: accountID,
                    binding: binding,
                    localBranch: localBranch,
                    localHead: localHead,
                    defaultBranch: defaultBranch
                )
            }
            ownership.install(task)
            let preparation = try await task.value
            try Task.checkCancellation()
            return preparation
        } onCancel: {
            ownership.cancel()
        }
    }

    private func prepare(
        accountID: ForgeAccountID,
        binding: ForgeRepositoryBinding,
        localBranch: ForgeRefName,
        localHead: ForgeCommitID,
        defaultBranch: ForgeRefName
    ) throws -> RepositoryPullRequestCreationPreparation {
        let upstream = try optionalRun([
            "for-each-ref", "--format=%(upstream:short)", "refs/heads/\(localBranch.value)",
        ])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamParts = upstream?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        let trackingRemoteName = upstreamParts.count == 2 ? upstreamParts[0] : nil
        let branchPushRemoteName = try optionalConfigurationValue(
            for: "branch.\(localBranch.value).pushRemote"
        )
        let defaultPushRemoteName = try optionalConfigurationValue(for: "remote.pushDefault")
        guard let headRemoteName = RepositoryPullRequestPushRemotePolicy.effectiveRemoteName(
            requestedRemoteName: nil,
            branchPushRemoteName: branchPushRemoteName,
            defaultPushRemoteName: defaultPushRemoteName,
            trackingRemoteName: trackingRemoteName,
            boundRemoteName: binding.localRemoteName
        ) else {
            throw RepositoryPullRequestServiceError.repositoryUnavailable
        }
        let pushURLs = try run(
            RepositoryPullRequestPushRemotePolicy.pushURLArguments(remoteName: headRemoteName)
        )
        guard let headRepository = RepositoryPullRequestPushRemotePolicy.pushRepository(rawURLs: pushURLs)
        else {
            throw ForgePullRequestWorkflowError.invalidRemoteURL
        }
        guard headRepository.forge == binding.primaryRepository.forge else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }

        let remoteHeadRef = "refs/remotes/\(headRemoteName)/\(localBranch.value)"
        let pushedCommit = try optionalRun([
            "rev-parse", "--verify", remoteHeadRef,
        ]).flatMap { try? ForgeCommitID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let branchAlreadyPushed = pushedCommit == localHead

        let baseRemoteRef = "refs/remotes/\(binding.localRemoteName)/\(defaultBranch.value)"
        let baseCommit = try resolveCommit(
            candidates: [baseRemoteRef, "refs/heads/\(defaultBranch.value)", defaultBranch.value]
        )
        let base = ForgeBranchReference(
            repository: binding.primaryRepository,
            name: defaultBranch,
            commit: baseCommit
        )
        let head = ForgeBranchReference(
            repository: headRepository,
            name: localBranch,
            commit: localHead
        )
        return try RepositoryPullRequestCreationPreparation(
            accountID: accountID,
            repository: binding.primaryRepository,
            base: base,
            head: head,
            branchAlreadyPushed: branchAlreadyPushed,
            templates: templates(at: baseCommit),
            commitsOldestFirst: commitSummaries(base: baseCommit, head: localHead)
        )
    }

    private func resolveCommit(candidates: [String]) throws -> ForgeCommitID {
        for candidate in candidates {
            if let value = try optionalRun(["rev-parse", "--verify", candidate])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let commit = try? ForgeCommitID(value)
            {
                return commit
            }
        }
        throw RepositoryPullRequestServiceError.invalidLocalHead
    }

    private func templates(at commit: ForgeCommitID) throws -> [ForgePullRequestTemplate] {
        let roots = [
            ".github/PULL_REQUEST_TEMPLATE.md",
            "docs/PULL_REQUEST_TEMPLATE.md",
            "PULL_REQUEST_TEMPLATE.md",
            ".github/PULL_REQUEST_TEMPLATE",
            "docs/PULL_REQUEST_TEMPLATE",
            "PULL_REQUEST_TEMPLATE",
        ]
        guard let names = try optionalRun([
            "ls-tree", "-r", "--name-only", commit.value, "--",
        ]) else { return [] }
        var templates: [ForgePullRequestTemplate] = []
        for path in names.components(separatedBy: .newlines) {
            let lowercased = path.lowercased()
            guard !path.isEmpty,
                  lowercased.hasSuffix(".md"),
                  roots.contains(where: {
                      lowercased == $0.lowercased() || lowercased.hasPrefix($0.lowercased() + "/")
                  }),
                  let filePath = try? ForgeFilePath(path),
                  let markdown = try optionalRun(["show", "\(commit.value):\(path)"]),
                  let template = try? ForgePullRequestTemplate(path: filePath, bodyMarkdown: markdown)
            else { continue }
            templates.append(template)
        }
        return templates
    }

    private func commitSummaries(
        base: ForgeCommitID,
        head: ForgeCommitID
    ) throws -> [ForgePullRequestCommitSummary] {
        guard let output = try optionalRun([
            "log", "--reverse", "--format=%H%x00%s%x00%b%x00", "\(base.value)..\(head.value)",
        ]) else { return [] }
        let values = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 3 else { return [] }
        return stride(from: 0, to: values.count - 2, by: 3).compactMap { index in
            guard let id = try? ForgeCommitID(values[index]) else { return nil }
            return try? ForgePullRequestCommitSummary(
                id: id,
                subject: values[index + 1],
                body: values[index + 2].trimmingCharacters(in: .newlines)
            )
        }
    }

    private func optionalConfigurationValue(for key: String) throws -> String? {
        let value = try optionalRun(["config", "--get", key])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func optionalRun(_ arguments: [String]) throws -> String? {
        do {
            return try run(arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        try Task.checkCancellation()
        let output = try runner.run(arguments)
        try Task.checkCancellation()
        return output
    }
}
