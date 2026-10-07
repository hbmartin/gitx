import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryRemoteService)
final nonisolated class RepositoryRemoteService: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteService")
    private let capabilitiesLock = NSLock()
    private var cachedCapabilities: PushCapabilities?
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
        var snapshot: RepositoryPushSnapshot?
        var captureExclusion: String?
        let branchDescription: String
        if branchRef == nil || branchRef?.isRemote == true {
            branchDescription = "all updates"
        } else if branchRef?.isTag == true {
            let tagName = branchRef?.tagName ?? ""
            branchDescription = "tag '\(tagName)'"
            arguments.append(contentsOf: ["tag", tagName])
        } else {
            branchDescription = branchRef?.shortName() ?? ""
            let porcelain = porcelainSupported()
            if porcelain == true {
                arguments.insert("--porcelain", at: 1)
                let capture = capturePushSnapshot(branch: branchRef, remoteName: remoteName)
                snapshot = capture.snapshot
                captureExclusion = capture.exclusion
            } else {
                captureExclusion = porcelain == false
                    ? "Configured Git does not advertise porcelain push status"
                    : "Porcelain push capability could not be verified"
            }
            arguments.append(branchRef?.ref ?? "")
        }

        return launchPush(
            arguments: arguments,
            branchDescription: branchDescription,
            remoteName: remoteName,
            snapshot: snapshot,
            captureExclusion: captureExclusion,
            error: outputError
        )
    }

    private enum PushSafetyFailure: Error {
        case excluded(String)
    }

    private struct PushCapabilities {
        let identity: String
        var porcelain: Bool?
        var configEnvironment: Bool?
    }

    private func capabilityIdentity() -> String {
        (runner as? GitEvidenceCommandRunning)?.evidenceExecutableIdentity
            ?? IndexGitExecutableIdentity.identity(path: PBGitBinary.path() ?? "")
    }

    private func capabilities(for identity: String) -> PushCapabilities {
        if let cachedCapabilities, cachedCapabilities.identity == identity {
            return cachedCapabilities
        }
        return PushCapabilities(identity: identity)
    }

    /// A configured executable can change in place. Re-probe its resolved
    /// target identity, never infer optional features from a version number.
    private func porcelainSupported() -> Bool? {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        let identity = capabilityIdentity()
        var cached = capabilities(for: identity)
        if let supported = cached.porcelain {
            return supported
        }
        let help: String
        do {
            help = try runner.output(arguments: ["push", "-h"])
        } catch {
            let error = error as NSError
            guard error.domain == PBTaskErrorDomain,
                  error.code == Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue),
                  (error.userInfo[PBTaskTerminationStatusKey] as? NSNumber)?.intValue == 129,
                  let output = error.userInfo[PBTaskTerminationOutputKey] as? String
            else { return nil }
            help = output
        }
        guard help.contains("git push") else { return nil }
        cached.porcelain = help.replacingOccurrences(of: "[no-]", with: "").contains("--porcelain")
        cachedCapabilities = cached
        return cached.porcelain
    }

    private func configEnvironmentSupported(using evidence: GitEvidenceCommandRunning) -> Bool? {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        let identity = evidence.evidenceExecutableIdentity
        var cached = capabilities(for: identity)
        if let supported = cached.configEnvironment {
            return supported
        }
        let key = "gitx.push-recovery=probe.value"
        let variable = "GITX_PUSH_CAPABILITY_PROBE"
        let sentinel = "gitx-config-env-capability"
        do {
            let data = try evidence.evidenceData(
                arguments: ["--config-env=\(key)=\(variable)", "config", "--get", key], inputData: nil,
                environment: [variable: sentinel]
            )
            guard data == Data((sentinel + "\n").utf8) else { return nil }
            cached.configEnvironment = true
        } catch {
            let error = error as NSError
            let output = (error.userInfo[PBTaskTerminationOutputKey] as? String ?? "").lowercased()
            guard error.domain == PBTaskErrorDomain,
                  error.code == Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue),
                  (error.userInfo[PBTaskTerminationStatusKey] as? NSNumber)?.intValue == 129,
                  output.contains("config-env"), output.contains("unknown option") || output.contains("unrecognized option")
            else { return nil }
            cached.configEnvironment = false
        }
        cachedCapabilities = cached
        return cached.configEnvironment
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

    private func capturePushSnapshot(branch: PBGitRef?, remoteName: String) -> (snapshot: RepositoryPushSnapshot?, exclusion: String?) {
        guard let branch, branch.isBranch else { return (nil, "Selection is not a local branch") }
        do {
            guard let evidence = runner as? GitEvidenceCommandRunning else {
                throw PushSafetyFailure.excluded("Configured Git does not provide bounded byte evidence")
            }
            let values = try configuration()
            guard try !effectiveBoolean("remote.\(remoteName).mirror", values: values),
                  try !effectiveBoolean("push.followtags", values: values)
            else { throw PushSafetyFailure.excluded("Mirror or follow-tags push is not a single-branch recovery") }
            guard let fetchMappings = values["remote.\(remoteName).fetch"], !fetchMappings.isEmpty,
                  (values["remote.\(remoteName).push"]?.count ?? 0) <= 1
            else { throw PushSafetyFailure.excluded("Unsupported or ambiguous reference mappings") }
            let mode = ["upstream", "tracking"].contains(values["push.default"]?.last ?? "") ? "upstream" : "current"
            let format = "%(refname)%00%(objectname)%00%(upstream:remoteref)%00%(push:remoteref)%00%(push)%00%(push:remotename)"
            let keys = ["branch.\(branch.shortName()).remote", "branch.\(branch.shortName()).pushRemote", "push.default"]
            let overrides: [String]
            let environment: [String: String]?
            if configEnvironmentSupported(using: evidence) == true {
                overrides = keys.prefix(2).map { "--config-env=\($0)=GITX_PUSH_METADATA_REMOTE" }
                    + ["--config-env=push.default=GITX_PUSH_METADATA_MODE"]
                environment = ["GITX_PUSH_METADATA_REMOTE": remoteName, "GITX_PUSH_METADATA_MODE": mode]
            } else {
                guard keys.allSatisfy({ !$0.contains("=") }) else {
                    throw PushSafetyFailure.excluded("Configured Git cannot safely override this branch metadata key")
                }
                overrides = ["-c", keys[0] + "=" + remoteName, "-c", keys[1] + "=" + remoteName, "-c", keys[2] + "=" + mode]
                environment = nil
            }
            let metadataData = try evidence.evidenceData(
                arguments: overrides + ["for-each-ref", "--format=\(format)", branch.ref], inputData: nil,
                environment: environment
            )
            guard let metadata = RepositoryPushObjectEvidence.lines(metadataData) else {
                throw PushSafetyFailure.excluded("Incomplete source reference metadata")
            }
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
            try RepositoryPushFetchMapping.validate(fetchMappings, destination: destination, tracking: fields[4])
            let trackingData = try evidence.evidenceData(
                arguments: ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)", fields[4]],
                inputData: nil, environment: nil
            )
            guard let tracking = RepositoryPushObjectEvidence.lines(trackingData) else {
                throw PushSafetyFailure.excluded("Incomplete fetched tracking metadata")
            }
            guard tracking.count == 1 else { throw PushSafetyFailure.excluded("Fetched tracking reference is missing or ambiguous") }
            let tracked = tracking[0].components(separatedBy: "\0")
            guard tracked.count == 3, tracked[0] == fields[4], tracked[2] == "commit",
                  RepositoryPushSnapshot.isOID(tracked[1]), tracked[1].count == fields[1].count
            else { throw PushSafetyFailure.excluded("Fetched tracking commit is unavailable") }
            let reflogData = try evidence.evidenceData(
                arguments: ["reflog", "show", "--no-show-signature", "--format=%H",
                            "--max-count=\(RepositoryPushReflogEvidence.limit + 1)", branch.ref, "--"],
                inputData: nil, environment: nil
            )
            let reflog = try RepositoryPushReflogEvidence.capture(reflogData, oidLength: fields[1].count)
            logger.debug("Captured source, tracking commit, branch reflog and effective push settings")
            return (RepositoryPushSnapshot(sourceRef: branch.ref, sourceOID: fields[1], remoteName: remoteName,
                                           endpoint: "", destinationRef: destination, fetchedOID: tracked[1],
                                           reflogOIDs: reflog.retainedOIDs, reflogIsTruncated: reflog.isTruncated,
                                           configuration: RepositoryPushConfiguration.relevant(values, remote: remoteName, branch: branch.shortName())), nil)
        } catch {
            return (nil, exclusionReason(for: error))
        }
    }

    private func exclusionReason(for error: Error) -> String {
        if case let PushSafetyFailure.excluded(reason) = error {
            return reason
        } else if let failure = error as? RepositoryPushEvidenceError {
            return "Bounded reference evidence is invalid: \(failure)"
        }
        let taskError = error as NSError
        if taskError.domain == PBTaskErrorDomain {
            switch taskError.code {
            case Int(PBTaskErrorCode.timeoutError.rawValue): return "Git evidence command timed out"
            case Int(PBTaskErrorCode.caughtSignalError.rawValue): return "Git evidence command ended by signal"
            case Int(PBTaskErrorCode.launchError.rawValue): return "Git evidence command could not start"
            default: break
            }
        }
        return "Git could not validate captured evidence"
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
        guard let evidence = runner as? GitEvidenceCommandRunning else {
            throw PushSafetyFailure.excluded("Configured Git does not provide bounded byte evidence")
        }
        let endpoint = try validatedEndpoint(for: snapshot)
        let witnesses = RepositoryPushReflogEvidence.witnesses(sourceOID: snapshot.sourceOID, reflogOIDs: snapshot.reflogOIDs)
        let objects = RepositoryPushReflogEvidence.witnesses(sourceOID: snapshot.sourceOID, reflogOIDs: snapshot.reflogOIDs + [snapshot.fetchedOID])
        let validated = try evidence.evidenceData(arguments: ["cat-file", "--batch-check"],
                                                  inputData: RepositoryPushObjectEvidence.input(objects), environment: nil)
        try RepositoryPushObjectEvidence.validateCommits(validated, expectedOIDs: objects)
        let integrated: Bool
        if witnesses.contains(snapshot.fetchedOID) {
            integrated = true
        } else {
            guard try evidence.evidenceData(arguments: ["rev-parse", "--is-shallow-repository"], inputData: nil, environment: nil) == Data("false\n".utf8) else {
                throw PushSafetyFailure.excluded("Shallow history cannot prove integration")
            }
            let input = RepositoryPushObjectEvidence.input(witnesses + ["^" + snapshot.fetchedOID])
            let proof = try evidence.evidenceData(arguments: ["rev-list", "--stdin", "--ancestry-path", "--max-count=1"],
                                                  inputData: input, environment: nil)
            integrated = try RepositoryPushObjectEvidence.provesAncestry(proof, oidLength: snapshot.fetchedOID.count)
        }
        guard integrated else {
            throw PushSafetyFailure.excluded(snapshot.reflogIsTruncated
                ? "Newest 1024 reflog entries do not prove integration"
                : "Fetched remote work was never integrated into the captured branch")
        }
        let eligible = RepositoryPushSnapshot(sourceRef: snapshot.sourceRef, sourceOID: snapshot.sourceOID,
                                              remoteName: snapshot.remoteName, endpoint: endpoint, destinationRef: snapshot.destinationRef,
                                              fetchedOID: snapshot.fetchedOID,
                                              reflogOIDs: snapshot.reflogOIDs, reflogIsTruncated: snapshot.reflogIsTruncated,
                                              configuration: snapshot.configuration)
        return PBRepositoryPushRetryPlan(snapshot: eligible)
    }

    private func launchPush(
        arguments: [String], branchDescription: String, remoteName: String,
        snapshot: RepositoryPushSnapshot? = nil,
        captureExclusion: String? = nil,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        commandWasLaunched = true
        let result = runner.push(arguments: arguments)
        guard let error = result.error else {
            lastPushOutput = result.browserHintOutput
            logger.debug("Repository reference push completed")
            return true
        }
        var info: [String: Any] = [:]
        let decision = failedPushDecision(result: result, snapshot: snapshot, captureExclusion: captureExclusion)
        let outcome: String
        if decision == .eligible, let snapshot {
            do {
                info[PBRepositoryPushRetryPlan.errorKey] = try recoveryPlan(for: snapshot)
                outcome = "Eligible using source and \(snapshot.reflogOIDs.count) captured reflog entries (maximum 1024, capped=\(snapshot.reflogIsTruncated))"
            } catch { outcome = "Excluded: " + exclusionReason(for: error) }
        } else if case let .excluded(reason) = decision {
            outcome = "Excluded: " + reason
        } else {
            outcome = "Excluded: No captured branch evidence"
        }
        let statusKind = failedPushStatusKind(result: result)
        let witnessCount = snapshot.map { RepositoryPushReflogEvidence.witnesses(sourceOID: $0.sourceOID, reflogOIDs: $0.reflogOIDs).count } ?? 0
        logger.info("Failed push recovery decision: \(outcome, privacy: .public) [task=\(statusKind, privacy: .public), statusComplete=\(result.standardOutputComplete), diagnosticsComplete=\(result.standardErrorComplete), witnesses=\(witnessCount), reflogCapped=\(snapshot?.reflogIsTruncated ?? false)]")
        let diagnostic = result.diagnosticArtifact?.redactedSummary
            ?? PBTaskDiagnostics.pushFailure(stdout: result.standardOutput, stderr: result.standardError,
                                             porcelain: arguments.contains("--porcelain"))
        var diagnostics: [String: Any] = [
            NSLocalizedDescriptionKey: PBTaskDiagnostics.redacted(error.localizedDescription),
            NSLocalizedFailureReasonErrorKey: PBTaskDiagnostics.redacted(error.localizedFailureReason ?? error.localizedDescription),
            PBTaskTerminationOutputKey: diagnostic,
        ]
        diagnostics[PBTaskTerminationStatusKey] = result.terminationStatus
        if let artifact = result.diagnosticArtifact {
            diagnostics[PushDiagnosticOwnership.errorKey] = artifact
            info[PushDiagnosticOwnership.errorKey] = artifact
        }
        if let suggestion = error.localizedRecoverySuggestion {
            diagnostics[NSLocalizedRecoverySuggestionErrorKey] = PBTaskDiagnostics.redacted(suggestion)
            info[NSLocalizedRecoverySuggestionErrorKey] = PBTaskDiagnostics.redacted(suggestion)
        }
        let safeError = NSError(domain: error.domain, code: error.code, userInfo: diagnostics)
        let completionUnknown = error.domain == PBTaskErrorDomain && error.code == Int(PBTaskErrorCode.timeoutError.rawValue)
        let failureReason = completionUnknown
            ? "Git stopped waiting, so remote completion is unknown. Check or fetch the remote before starting another push."
            : PBTaskDiagnostics.redacted("An error occurred while pushing \(branchDescription) to \"\(remoteName)\".")
        let wrapped = RepositoryServiceError.make(
            description: "Push failed",
            failureReason: failureReason,
            underlyingError: safeError, userInfo: info
        )
        logger.error("Repository reference push failed")
        return RepositoryServiceError.assign(wrapped, to: outputError)
    }

    private func failedPushDecision(result: PBRepositoryPushCommandResult, snapshot: RepositoryPushSnapshot?,
                                    captureExclusion: String?) -> RepositoryPushRecoveryDecision
    {
        guard let error = result.error, error.domain == PBTaskErrorDomain else {
            return .excluded("Push did not report a Git task failure")
        }
        switch error.code {
        case Int(PBTaskErrorCode.timeoutError.rawValue): return .excluded("Push timed out; remote completion is unknown")
        case Int(PBTaskErrorCode.caughtSignalError.rawValue): return .excluded("Push ended by signal")
        case Int(PBTaskErrorCode.launchError.rawValue): return .excluded("Push command could not start")
        case Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue): break
        default: return .excluded("Push did not report a nonzero Git exit")
        }
        guard let status = result.terminationStatus, status.intValue != 0 else {
            return .excluded("Push exit status is missing or inconsistent")
        }
        guard result.standardOutputComplete else { return .excluded("Porcelain status capture is incomplete") }
        guard let snapshot else { return .excluded(captureExclusion ?? "No captured branch evidence") }
        return RepositoryRejectedPushRecoveryPolicy.decision(stdout: result.standardOutput, snapshot: snapshot)
    }

    private func failedPushStatusKind(result: PBRepositoryPushCommandResult) -> String {
        guard let error = result.error, error.domain == PBTaskErrorDomain else { return "non-Git failure" }
        switch error.code {
        case Int(PBTaskErrorCode.timeoutError.rawValue): return "timeout"
        case Int(PBTaskErrorCode.caughtSignalError.rawValue): return "signal"
        case Int(PBTaskErrorCode.launchError.rawValue): return "launch failure"
        case Int(PBTaskErrorCode.nonZeroExitCodeError.rawValue):
            return result.terminationStatus.map { "nonzero exit \($0.intValue)" } ?? "missing exit status"
        default: return "unrecognized task failure"
        }
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
