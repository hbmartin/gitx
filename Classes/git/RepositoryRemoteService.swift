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
        logger.info("Retrying frozen commit with the original fetched lease")
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
        var arguments = ["push", "--porcelain", "--", remoteName]
        let branchDescription: String
        if branchRef == nil || branchRef?.isRemote == true {
            branchDescription = "all updates"
        } else if branchRef?.isTag == true {
            let tagName = branchRef?.tagName ?? ""
            branchDescription = "tag '\(tagName)'"
            arguments.append(contentsOf: ["tag", tagName])
        } else {
            branchDescription = branchRef?.shortName() ?? ""
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

    private func capturePushSnapshot(branch: PBGitRef?, remoteName: String) -> RepositoryPushSnapshot? {
        guard let branch, branch.isBranch else { return nil }
        do {
            let sourceOID = try runner.output(arguments: ["rev-parse", "--verify", "\(branch.ref)^{commit}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fetchURLs = try runner.output(arguments: ["remote", "get-url", "--all", remoteName])
                .split(whereSeparator: \.isNewline).map(String.init)
            let pushURLs = try runner.output(arguments: ["remote", "get-url", "--push", "--all", remoteName])
                .split(whereSeparator: \.isNewline).map(String.init)
            guard fetchURLs.count == 1, fetchURLs == pushURLs, let endpoint = pushURLs.first,
                  !endpoint.isEmpty else { return nil }
            let config = try runner.output(arguments: ["config", "--null", "--list"])
            var values: [String: [String]] = [:]
            for entry in config.split(separator: "\0") {
                let fields = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                values[String(fields[0]), default: []].append(fields.count == 2 ? String(fields[1]) : "true")
            }
            let remoteKey = "remote.\(remoteName)."
            let disabledValues = ["false", "no", "off", "0"]
            guard (values[remoteKey + "mirror"] ?? []).allSatisfy({ disabledValues.contains($0.lowercased()) }),
                  (values["push.followtags"] ?? []).allSatisfy({ disabledValues.contains($0.lowercased()) }),
                  let destination = RepositoryPushRefspecPolicy.destination(
                      source: branch.ref, pushMappings: values[remoteKey + "push"] ?? []
                  ), destination.hasPrefix("refs/heads/"),
                  let tracking = RepositoryPushRefspecPolicy.trackingReference(
                      destination: destination, fetchMappings: values[remoteKey + "fetch"] ?? []
                  ) else { return nil }
            let fetchedOID = try runner.output(arguments: ["rev-parse", "--verify", "\(tracking)^{commit}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard RepositoryPushSnapshot.isOID(sourceOID), RepositoryPushSnapshot.isOID(fetchedOID),
                  sourceOID.count == fetchedOID.count else { return nil }
            logger.debug("Captured source commit and fetched destination before push")
            return RepositoryPushSnapshot(sourceRef: branch.ref, sourceOID: sourceOID,
                                          remoteName: remoteName, endpoint: endpoint, destinationRef: destination, fetchedOID: fetchedOID)
        } catch {
            logger.debug("No unambiguous fetched snapshot; push recovery will remain unavailable")
            return nil
        }
    }

    private func launchPush(
        arguments: [String],
        branchDescription: String,
        remoteName: String,
        snapshot: RepositoryPushSnapshot? = nil,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            commandWasLaunched = true
            try runner.launch(arguments: arguments)
            lastPushOutput = runner.lastOutput
            logger.debug("Repository reference push completed")
            return true
        } catch {
            var info: [String: Any] = [:]
            if let snapshot, RepositoryRejectedPushRecoveryPolicy.shouldOfferForceWithLease(for: error, snapshot: snapshot) {
                info[PBRepositoryPushRetryPlan.errorKey] = PBRepositoryPushRetryPlan(snapshot: snapshot)
                logger.info("Attached frozen retry plan to rejected push error")
            }
            let wrapped = RepositoryServiceError.make(
                description: NSLocalizedString(
                    "Push failed",
                    comment: "PBGitRepository - push error description"
                ),
                failureReason: String(
                    format: NSLocalizedString(
                        "An error occurred while pushing %@ to \"%@\".",
                        comment: "PBGitRepository - push error reason"
                    ),
                    branchDescription,
                    remoteName
                ),
                underlyingError: error,
                userInfo: info
            )
            logger.error("Repository reference push failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
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
