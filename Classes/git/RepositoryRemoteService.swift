import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryRemoteService)
final class RepositoryRemoteService: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteService")
    @objc private(set) var commandWasLaunched = false

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
        logger.debug("Pushing repository reference")
        guard let resolvedRemote = resolvedRemote(remoteRef, for: branchRef, error: outputError) else {
            return false
        }
        let remoteName = resolvedRemote.remoteName ?? ""
        var arguments = ["push", remoteName]
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

        do {
            commandWasLaunched = true
            try runner.launch(arguments: arguments)
            logger.debug("Repository reference push completed")
            return true
        } catch {
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
                underlyingError: error
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
