import Foundation
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryMutationService)
final nonisolated class RepositoryMutationService: NSObject {
    private unowned let repository: PBGitRepository
    private let runner: GitCommandRunning
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryMutationService")

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

    private func displayType(of ref: PBGitRefish) -> String {
        ref.refishType() ?? "(null)"
    }

    @objc(checkoutRefish:error:)
    func checkout(
        _ ref: PBGitRefish,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        let refName = ref.refishType() == kGitXBranchType ? ref.shortName() : ref.refishName()
        logger.debug("Checking out repository reference")
        do {
            _ = try runner.output(arguments: ["checkout", refName])
            logger.debug("Repository checkout completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Checkout failed",
                failureReason: "There was an error checking out the \(displayType(of: ref)) '\(ref.shortName())'.\n\nPerhaps your working directory is not clean?",
                underlyingError: error
            )
            logger.error("Repository checkout failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(checkoutFiles:fromRefish:error:)
    func checkoutFiles(
        _ files: [String]?,
        from ref: PBGitRefish,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard let files, !files.isEmpty else { return false }
        let refName = ref.refishType() == kGitXBranchType ? ref.shortName() : ref.refishName()
        logger.debug("Checking out repository paths")
        do {
            _ = try runner.output(arguments: ["checkout", refName, "--"] + files)
            logger.debug("Repository path checkout completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Checkout failed",
                failureReason: "There was an error checking out the file(s) from the \(displayType(of: ref)) '\(ref.shortName())'.\n\nPerhaps your working directory is not clean?",
                underlyingError: error
            )
            logger.error("Repository path checkout failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(mergeWithRefish:headName:error:)
    func merge(
        with ref: PBGitRefish,
        headName: String,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        let refName = ref.refishName()
        logger.debug("Merging repository reference")
        do {
            _ = try runner.output(arguments: ["merge", refName])
            logger.debug("Repository merge completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Merge failed!",
                failureReason: "There was an error merging \(refName) into \(headName).",
                underlyingError: error
            )
            logger.error("Repository merge failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(cherryPickRefish:error:)
    func cherryPick(
        _ ref: PBGitRefish?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard let ref else { return false }
        logger.debug("Cherry-picking repository reference")
        do {
            _ = try runner.output(arguments: ["cherry-pick", ref.refishName()])
            logger.debug("Repository cherry-pick completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Cherry pick failed!",
                failureReason: "There was an error cherry picking the \(displayType(of: ref)) '\(ref.shortName())'.\n\nPerhaps your working directory is not clean?",
                underlyingError: error
            )
            logger.error("Repository cherry-pick failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(resetRefish:to:error:)
    func reset(
        _ mode: GTRepositoryResetType,
        to ref: PBGitRefish?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard let ref else { return false }
        let modeParameter: String
        switch mode {
        case .soft: modeParameter = "--soft"
        case .mixed: modeParameter = "--mixed"
        case .hard: modeParameter = "--hard"
        @unknown default: modeParameter = "--mixed"
        }
        logger.debug("Resetting repository reference")
        do {
            _ = try runner.output(arguments: ["reset", modeParameter, ref.refishName()])
            logger.debug("Repository reset completed")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Reset failed!",
                failureReason: "There was an error resetting to \(displayType(of: ref)) '\(ref.shortName())'.",
                underlyingError: error
            )
            logger.error("Repository reset failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(rebaseBranch:onRefish:error:)
    func rebase(
        _ branch: PBGitRefish?,
        on upstream: PBGitRefish,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        var arguments = ["rebase", upstream.refishName()]
        if let branch {
            arguments.append(branch.refishName())
        }
        logger.debug("Rebasing repository reference")
        do {
            _ = try runner.output(arguments: arguments)
            logger.debug("Repository rebase completed")
            return true
        } catch {
            let branchName = branch.map { "\(displayType(of: $0)) '\($0.shortName())'" } ?? "HEAD"
            let wrapped = RepositoryServiceError.make(
                description: "Rebase failed!",
                failureReason: "There was an error rebasing \(branchName) with \(displayType(of: upstream)) '\(upstream.shortName())'.",
                underlyingError: error
            )
            logger.error("Repository rebase failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(createBranch:atRefish:error:)
    func createBranch(
        _ branchName: String?,
        at ref: PBGitRefish?,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard let branchName, let ref else { return false }
        logger.debug("Creating repository branch")
        do {
            _ = try runner.output(arguments: ["branch", branchName, ref.refishName()])
            logger.debug("Repository branch created")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Create Branch failed!",
                failureReason: "There was an error creating the branch '\(branchName)' at \(displayType(of: ref)) '\(ref.shortName())'.",
                underlyingError: error,
                userInfo: [NSUnderlyingErrorKey: error]
            )
            logger.error("Repository branch creation failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(createTag:message:atRefish:error:)
    func createTag(
        _ tagName: String?,
        message: String,
        at target: PBGitRefish,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        guard let tagName, let gitRepository = repository.gtRepo else { return false }
        logger.debug("Creating repository tag")
        do {
            guard let object = try gitRepository.lookUpObject(byRevParse: target.refishName()) as? GTObject else {
                return false
            }
            if message.isEmpty {
                _ = try gitRepository.createLightweightTagNamed(tagName, target: object)
            } else {
                guard let tagger = gitRepository.userSignatureForNow() else { return false }
                _ = try gitRepository.createTagNamed(tagName, target: object, tagger: tagger, message: message)
            }
            logger.debug("Repository tag created")
            return true
        } catch {
            outputError?.pointee = error as NSError
            logger.error("Repository tag creation failed")
            return false
        }
    }

    @objc(deleteReference:error:)
    func deleteReference(
        _ ref: PBGitRef,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        logger.debug("Deleting repository reference")
        do {
            _ = try runner.output(arguments: ["update-ref", "-d", ref.ref])
            logger.debug("Repository reference deleted")
            return true
        } catch {
            let wrapped = RepositoryServiceError.make(
                description: "Delete ref failed!",
                failureReason: "There was an error deleting the ref: \(ref.shortName())\n\n",
                underlyingError: error,
                userInfo: [NSUnderlyingErrorKey: error]
            )
            logger.error("Repository reference deletion failed")
            return RepositoryServiceError.assign(wrapped, to: outputError)
        }
    }

    @objc(updateReference:toPointAtCommit:error:)
    func updateReference(
        _ ref: PBGitRef,
        toPointAt newCommit: PBGitCommit,
        error outputError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        logger.debug("Updating repository reference")
        do {
            try updateReference(ref, toPointAt: newCommit, expectedOldOID: nil)
            return true
        } catch {
            return RepositoryServiceError.assign(error as NSError, to: outputError)
        }
    }

    func updateReference(
        _ ref: PBGitRef,
        toPointAt newCommit: PBGitCommit,
        expectedOldOID: String?
    ) throws {
        var arguments = ["update-ref", "-mUpdate from GitX", ref.ref, newCommit.sha]
        if let expectedOldOID {
            arguments.append(expectedOldOID)
        }
        do {
            try runner.launch(arguments: arguments)
            logger.debug("Repository reference updated")
        } catch {
            logger.error("Repository reference update failed")
            throw RepositoryServiceError.make(
                description: NSLocalizedString("Reference update failed", comment: "Reference update failure - error title"),
                failureReason: String(
                    format: NSLocalizedString("The reference %@ couldn't be updated", comment: "Reference update failure - error message"),
                    ref.shortName()
                ),
                underlyingError: error
            )
        }
    }

    @objc(performDiff:against:forFiles:)
    func performDiff(
        _ startCommit: PBGitCommit,
        against diffCommit: PBGitCommit?,
        forFiles filePaths: [String]?
    ) -> String {
        guard startCommit.repository === repository else { return "" }
        let targetCommit = diffCommit ?? repository.headCommit()
        guard let targetCommit, targetCommit.repository === repository else { return "" }
        var arguments = ["diff", "--no-ext-diff", "\(startCommit.sha)..\(targetCommit.sha)"]
        if !PBGitDefaults.showWhitespaceDifferences() {
            arguments.insert("-w", at: 1)
        }
        if let filePaths {
            arguments.append("--"); arguments.append(contentsOf: filePaths)
        }
        logger.debug("Creating repository diff")
        do {
            let diff = try runner.output(arguments: arguments)
            logger.debug("Repository diff completed")
            return diff
        } catch {
            logger.error("Repository diff failed")
            return ""
        }
    }
}

// swiftlint:enable unused_declaration
