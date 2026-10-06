import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryRemoteService)
final nonisolated class RepositoryRemoteService: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteService")
    @objc private(set) var commandWasLaunched = false
    @objc private(set) var lastPushOutput: String?

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        runner = RepositoryGitCommandRunner(repository: repository)
        super.init()
    }

    @objc(initWithRepository:runner:)
    init(repository: PBGitRepository, runner: GitCommandRunning) {
        self.repository = repository
        self.runner = runner
        super.init()
    }

    @objc(remotes)
    func remotes() -> [String]? {
        do {
            let output = try runner.output(arguments: ["remote"])
            guard !output.isEmpty else { return [] }
            return output.components(separatedBy: .newlines)
        } catch {
            logger.error("Configured remote discovery failed")
            return nil
        }
    }

    @objc(hasRemotes)
    func hasRemotes() -> Bool {
        !(remotes() ?? []).isEmpty
    }

    @objc(remoteRefForBranch:error:)
    func remoteRef(
        forBranch branch: PBGitRef,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> PBGitRef? {
        if branch.isRemote {
            return branch.remote()
        }
        guard !branch.ref.isEmpty, let gitRepository = repository.gtRepo else { return nil }
        do {
            var success = ObjCBool(false)
            let gitBranch = try gitRepository.lookUpBranch(
                withName: branch.branchName ?? "",
                type: .local,
                success: &success
            )
            guard success.boolValue else {
                let failure = "There doesn't seem to be a branch named \"\(branch.shortName())\""
                outputError?.pointee = RepositoryServiceError.make(
                    description: "Branch lookup failed",
                    failureReason: failure
                )
                return nil
            }
            success = false
            var trackingError: NSError?
            let trackingBranch = gitBranch.trackingBranchWithError(
                &trackingError,
                success: &success
            )
            guard success.boolValue, let trackingBranch else {
                let recovery = "Please select a branch from the popup menu, which has a corresponding remote tracking branch set up.\n\nYou can also use a contextual menu to choose a branch by right clicking on its label in the commit history list."
                outputError?.pointee = RepositoryServiceError.make(
                    description: "No remote configured for branch",
                    failureReason: "There is no remote configured for branch \"\(branch.shortName())\".",
                    underlyingError: trackingError,
                    userInfo: [NSLocalizedRecoverySuggestionErrorKey: recovery]
                )
                return nil
            }
            return PBGitRef(string: trackingBranch.reference.name)
        } catch {
            let failure = "There was an error finding the tracking branch of branch \"\(branch.shortName())\""
            outputError?.pointee = RepositoryServiceError.make(
                description: "Branch lookup failed",
                failureReason: failure,
                underlyingError: error
            )
            return nil
        }
    }

    @objc(addRemote:withURL:error:)
    func addRemote(
        _ remoteName: String,
        withURL urlString: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        logger.debug("Adding configured remote")
        do {
            commandWasLaunched = true
            try runner.launch(arguments: ["remote", "add", "-f", remoteName, urlString])
            logger.debug("Configured remote added")
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Adding configured remote failed")
            return false
        }
    }

    @objc(fetchRemoteForRef:error:)
    func fetchRemote(
        for ref: PBGitRef?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        logger.debug("Fetching remote references")
        var resolvedRef = ref
        let fetchArgument: String
        if let ref {
            if !ref.isRemote {
                resolvedRef = remoteRef(forBranch: ref, error: outputError)
                guard resolvedRef != nil else { return false }
            }
            fetchArgument = resolvedRef?.remoteName ?? ""
        } else {
            fetchArgument = "--all"
        }

        do {
            commandWasLaunched = true
            try runner.launch(arguments: ["fetch", fetchArgument])
            logger.debug("Remote reference fetch completed")
            return true
        } catch {
            let remoteName = resolvedRef?.remoteName ?? "(null)"
            let wrapped = RepositoryServiceError.make(
                description: NSLocalizedString(
                    "Fetch failed",
                    comment: "PBGitRepository - fetch error description"
                ),
                failureReason: String(
                    format: NSLocalizedString(
                        "An error occurred while fetching remote \"%@\".",
                        comment: "PBGitRepository - fetch error reason"
                    ),
                    remoteName
                ),
                underlyingError: error
            )
            logger.error("Remote reference fetch failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(pullBranch:fromRemote:rebase:error:)
    func pullBranch(
        _ branchRef: PBGitRef?,
        fromRemote remoteRef: PBGitRef?,
        rebase: Bool,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        logger.debug("Pulling remote branch")
        guard let resolvedRemote = resolvedRemote(remoteRef, for: branchRef, error: outputError) else {
            return false
        }
        let remoteName = resolvedRemote.remoteName ?? ""
        var arguments = ["pull"]
        if rebase {
            arguments.append("--rebase")
        }
        arguments.append(remoteName)

        do {
            commandWasLaunched = true
            try runner.launch(arguments: arguments)
            logger.debug("Remote branch pull completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: NSLocalizedString(
                    "Pull failed",
                    comment: "PBGitRepository - pull error description"
                ),
                failureReason: String(
                    format: NSLocalizedString(
                        "An error occurred while pulling remote \"%@\" to \"%@\".",
                        comment: "PBGitRepository - pull error reason"
                    ),
                    remoteName,
                    branchRef?.shortName() ?? "(null)"
                ),
                underlyingError: error
            )
            logger.error("Remote branch pull failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(pushBranch:toRemote:error:)
    func pushBranch(
        _ branchRef: PBGitRef?,
        toRemote remoteRef: PBGitRef?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        lastPushOutput = nil
        logger.debug("Pushing repository reference")
        guard let resolvedRemote = resolvedRemote(remoteRef, for: branchRef, error: outputError) else {
            return false
        }
        return pushBranch(branchRef, to: resolvedRemote, error: outputError)
    }

    @objc(retryPushWithPlan:error:)
    func retryPush(
        withPlan plan: PBRepositoryPushRetryPlan,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        lastPushOutput = nil
        do {
            _ = try validatedEndpoint(for: plan.snapshot)
        } catch {
            logger.info("Retry excluded because captured remote settings changed or became unavailable")
            return RepositoryServiceError.assign(RepositoryServiceError.make(
                description: "Push settings changed",
                failureReason: "The remote settings changed or could not be verified. Start a fresh push before retrying."
            ), to: outputError)
        }
        logger.info("Retrying frozen commit through the named remote with the original fetched lease")
        return launchPush(
            arguments: plan.snapshot.retryArguments,
            branchDescription: plan.branchName,
            remoteName: plan.remoteName,
            error: outputError
        )
    }

    private func pushBranch(
        _ branchRef: PBGitRef?,
        to resolvedRemote: PBGitRef,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        let remoteName = resolvedRemote.remoteName ?? ""
        var arguments = ["push", "--", remoteName]
        let branchDescription: String
        if branchRef == nil || branchRef?.isRemote == true {
            branchDescription = "all updates"
        } else if branchRef?.isTag == true {
            let tagName = branchRef?.tagName ?? ""
            branchDescription = "tag '\(tagName)'"
            arguments.append(contentsOf: ["tag", tagName])
        } else {
            branchDescription = branchRef?.shortName() ?? ""
            arguments.insert("--porcelain", at: 1)
            arguments.append(branchDescription)
        }

        return launchPush(
            arguments: arguments,
            branchDescription: branchDescription,
            remoteName: remoteName,
            snapshot: capturePushSnapshot(branch: branchRef, remoteName: remoteName),
            error: outputError
        )
    }

    private enum PushSafetyFailure: Error {
        case excluded(String)
    }

    private func configuration() throws -> [String: [String]] {
        try RepositoryPushConfiguration.values(runner.output(arguments: ["config", "--null", "--list"]))
    }

    private func effectiveBoolean(_ key: String, values: [String: [String]]) throws -> Bool {
        guard values[key] != nil else { return false }
        let value = try runner.output(arguments: ["config", "--type=bool", "--get", key]).trimmingCharacters(in: .newlines)
        guard value == "true" || value == "false" else {
            throw PushSafetyFailure.excluded("Git could not resolve a Boolean setting")
        }
        return value == "true"
    }

    private func capturePushSnapshot(branch: PBGitRef?, remoteName: String) -> RepositoryPushSnapshot? {
        guard let branch, branch.isBranch else { return nil }
        do {
            let values = try configuration()
            guard try !effectiveBoolean("remote.\(remoteName).mirror", values: values),
                  try !effectiveBoolean("push.followtags", values: values)
            else { throw PushSafetyFailure.excluded("Mirror or follow-tags push is not a single-branch recovery") }
            guard values["remote.\(remoteName).fetch"]?.count == 1,
                  (values["remote.\(remoteName).push"]?.count ?? 0) <= 1
            else { throw PushSafetyFailure.excluded("Unsupported or ambiguous reference mappings") }
            let mode = values["push.default"]?.last == "upstream" ? "upstream" : "current"
            let format = "%(refname)%00%(objectname)%00%(upstream:remoteref)%00%(push:remoteref)%00%(push)%00%(push:remotename)"
            let metadata = try runner.output(arguments: [
                "-c", "branch.\(branch.shortName()).remote=\(remoteName)",
                "-c", "branch.\(branch.shortName()).pushRemote=\(remoteName)", "-c", "push.default=\(mode)",
                "for-each-ref", "--format=\(format)", branch.ref,
            ]).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard metadata.count == 1 else { throw PushSafetyFailure.excluded("Ambiguous source reference") }
            let fields = metadata[0].components(separatedBy: "\0")
            guard fields.count == 6, fields[0] == branch.ref, RepositoryPushSnapshot.isOID(fields[1]),
                  fields[5] == remoteName, !fields[4].isEmpty,
                  !fields[4].hasPrefix("refs/heads/"), !fields[4].hasPrefix("refs/tags/")
            else { throw PushSafetyFailure.excluded("Git could not resolve a unique tracking reference") }
            let destination: String
            if !fields[3].isEmpty {
                destination = fields[3]
            } else {
                guard values["remote.\(remoteName).push"] == nil else {
                    throw PushSafetyFailure.excluded("Unsupported or ambiguous push mapping")
                }
                destination = mode == "upstream" ? fields[2] : branch.ref
            }
            guard destination.hasPrefix("refs/heads/") else { throw PushSafetyFailure.excluded("Destination is not a branch") }
            let tracking = try runner.output(arguments: ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", fields[4]])
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard tracking.count == 1 else { throw PushSafetyFailure.excluded("Fetched tracking reference is missing or ambiguous") }
            let tracked = tracking[0].components(separatedBy: "\0")
            guard tracked.count == 3, tracked[0] == fields[4], tracked[2] == "commit",
                  RepositoryPushSnapshot.isOID(tracked[1]), tracked[1].count == fields[1].count
            else { throw PushSafetyFailure.excluded("Fetched tracking commit is unavailable") }
            let reflog = try runner.output(arguments: ["reflog", "show", "--format=%H", branch.ref])
                .split(separator: "\n").map(String.init)
            guard reflog.allSatisfy(RepositoryPushSnapshot.isOID) else { throw PushSafetyFailure.excluded("Invalid branch reflog evidence") }
            logger.debug("Captured source, tracking commit, branch reflog and effective push settings")
            return RepositoryPushSnapshot(sourceRef: branch.ref, sourceOID: fields[1], remoteName: remoteName,
                                          endpoint: "", destinationRef: destination, fetchedOID: tracked[1], trackingRef: fields[4],
                                          reflogOIDs: reflog, configuration: RepositoryPushConfiguration.relevant(values, remote: remoteName, branch: branch.shortName()))
        } catch {
            logExclusion(error)
            return nil
        }
    }

    private func logExclusion(_ error: Error) {
        if case let PushSafetyFailure.excluded(reason) = error {
            logger.info("Push recovery excluded: \(reason, privacy: .public)")
        } else {
            logger.info("Push recovery excluded because Git could not validate captured evidence")
        }
    }

    private func validatedEndpoint(for snapshot: RepositoryPushSnapshot) throws -> String {
        let current = try RepositoryPushConfiguration.relevant(configuration(), remote: snapshot.remoteName, branch: snapshot.branchName)
        guard current == snapshot.configuration else { throw PushSafetyFailure.excluded("Relevant configuration changed; start a fresh push") }
        let fetch = try runner.output(arguments: ["remote", "get-url", "--all", snapshot.remoteName]).split(separator: "\n").map(String.init)
        let push = try runner.output(arguments: ["remote", "get-url", "--push", "--all", snapshot.remoteName]).split(separator: "\n").map(String.init)
        guard fetch.count == 1, fetch == push, let endpoint = push.first,
              snapshot.endpoint.isEmpty || endpoint == snapshot.endpoint
        else { throw PushSafetyFailure.excluded("Push and fetch endpoints differ or changed") }
        return endpoint
    }

    private func recoveryPlan(for snapshot: RepositoryPushSnapshot) throws -> PBRepositoryPushRetryPlan {
        let endpoint = try validatedEndpoint(for: snapshot)
        guard try runner.output(arguments: ["rev-parse", "--is-shallow-repository"]).trimmingCharacters(in: .newlines) == "false" else {
            throw PushSafetyFailure.excluded("Shallow history cannot prove integration")
        }
        let witnesses = Array(Set([snapshot.sourceOID] + snapshot.reflogOIDs)).sorted()
        // Validate captured objects, without reading any live source or lease ref.
        _ = try runner.historyOutput(arguments: ["rev-list", "--no-walk"] + Array(Set(witnesses + [snapshot.fetchedOID])).sorted() + ["--"])
        var integrated = witnesses.contains(snapshot.fetchedOID)
        for witness in witnesses where !integrated {
            do {
                _ = try runner.historyOutput(arguments: ["merge-base", "--is-ancestor", snapshot.fetchedOID, witness])
                integrated = true
            } catch {
                guard (error as NSError).domain == PBTaskErrorDomain,
                      (error as NSError).code == Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue),
                      (error as NSError).userInfo[PBTaskTerminationStatusKey] as? Int == 1 else { throw error }
            }
        }
        guard integrated else { throw PushSafetyFailure.excluded("Fetched remote work was never integrated into the captured branch") }
        let eligible = RepositoryPushSnapshot(sourceRef: snapshot.sourceRef, sourceOID: snapshot.sourceOID,
                                              remoteName: snapshot.remoteName, endpoint: endpoint, destinationRef: snapshot.destinationRef,
                                              fetchedOID: snapshot.fetchedOID, trackingRef: snapshot.trackingRef,
                                              reflogOIDs: snapshot.reflogOIDs, configuration: snapshot.configuration)
        logger.info("Captured branch history proves fetched remote work was integrated")
        return PBRepositoryPushRetryPlan(snapshot: eligible)
    }

    private func launchPush(
        arguments: [String], branchDescription: String, remoteName: String,
        snapshot: RepositoryPushSnapshot? = nil,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = true
        let result = runner.push(arguments: arguments)
        guard let error = result.error else {
            lastPushOutput = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            logger.debug("Repository reference push completed")
            return true
        }
        var info: [String: Any] = [:]
        let decision = RepositoryRejectedPushRecoveryPolicy.decision(stdout: result.stdout, snapshot: snapshot)
        if let status = result.terminationStatus, status.intValue != 0, error.domain == PBTaskErrorDomain,
           error.code == Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue), decision == .eligible, let snapshot
        {
            do {
                info[PBRepositoryPushRetryPlan.errorKey] = try recoveryPlan(for: snapshot)
                logger.info("Attached one frozen recovery plan to rejected push")
            } catch { logExclusion(error) }
        } else if case let .excluded(reason) = decision {
            logger.info("Push recovery excluded: \(reason, privacy: .public)")
        }
        let diagnostic = PBTaskDiagnostics.pushFailure(stdout: result.stdout, stderr: result.stderr,
                                                       porcelain: arguments.contains("--porcelain"))
        var diagnostics: [String: Any] = [
            NSLocalizedDescriptionKey: PBTaskDiagnostics.redacted(error.localizedDescription),
            NSLocalizedFailureReasonErrorKey: PBTaskDiagnostics.redacted(error.localizedFailureReason ?? error.localizedDescription),
            PBTaskTerminationOutputKey: diagnostic,
        ]
        diagnostics[PBTaskTerminationStatusKey] = result.terminationStatus
        let safeError = NSError(domain: error.domain, code: error.code, userInfo: diagnostics)
        let wrapped = RepositoryServiceError.make(
            description: "Push failed",
            failureReason: PBTaskDiagnostics.redacted("An error occurred while pushing \(branchDescription) to \"\(remoteName)\"."),
            underlyingError: safeError, userInfo: info
        )
        logger.error("Repository reference push failed")
        return RepositoryServiceError.assign(wrapped, to: outputError)
    }

    @objc(deleteRemote:error:)
    func deleteRemote(
        _ ref: PBGitRef?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = false
        guard let ref, ref.refishType() == kGitXRemoteType else { return false }
        logger.debug("Deleting configured remote")
        do {
            commandWasLaunched = true
            _ = try runner.output(arguments: ["remote", "rm", ref.remoteName ?? ""])
            logger.debug("Configured remote deleted")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Delete remote failed!",
                failureReason: "There was an error deleting the remote: \(ref.remoteName ?? "")\n\n",
                underlyingError: error,
                userInfo: [NSUnderlyingErrorKey: error]
            )
            logger.error("Configured remote deletion failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    private func resolvedRemote(
        _ remoteRef: PBGitRef?,
        for branchRef: PBGitRef?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> PBGitRef? {
        if let remoteRef, remoteRef.isRemote {
            return remoteRef
        }
        guard let branchRef else { return nil }
        return self.remoteRef(forBranch: branchRef, error: outputError)
    }
}

// swiftlint:enable unused_declaration

/// Cocoa passes this immutable value back to the repository façade after confirmation.
// swiftlint:disable unused_declaration
@objc(PBRepositoryPushRetryPlan)
// swift6-safety-justification: Every stored property is an immutable Sendable snapshot; NSObject supplies only Objective-C interoperability.
final nonisolated class PBRepositoryPushRetryPlan: NSObject, @unchecked Sendable {
    static let errorKey = "GitXRejectedPushRetryPlan"
    let snapshot: RepositoryPushSnapshot

    init(snapshot: RepositoryPushSnapshot) {
        self.snapshot = snapshot
        super.init()
    }

    @objc var branchName: String {
        snapshot.branchName
    }

    @objc var remoteName: String {
        snapshot.remoteName
    }

    @objc var sourceOID: String {
        snapshot.sourceOID
    }

    @objc var fetchedOID: String {
        snapshot.fetchedOID
    }

    @objc var destinationRef: String {
        snapshot.destinationRef
    }

    @objc var endpoint: String {
        snapshot.endpoint
    }

    @objc(planForError:)
    static func plan(forError error: NSError) -> PBRepositoryPushRetryPlan? {
        var current: NSError? = error
        var visited = Set<ObjectIdentifier>()
        while let error = current, visited.insert(ObjectIdentifier(error)).inserted {
            if let plan = error.userInfo[errorKey] as? PBRepositoryPushRetryPlan {
                return plan
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

// swiftlint:enable unused_declaration
