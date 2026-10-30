import OSLog // swiftlint:disable:this unused_import

// Objective-C actions call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryReferenceActionCoordinator)
final class RepositoryReferenceActionCoordinator: NSObject {
    private let repository: PBGitRepository
    private weak var windowController: PBGitWindowController?
    private let ownerIsCurrent: () -> Bool
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryReferenceActionCoordinator")

    @objc(initWithRepository:windowController:)
    init(repository: PBGitRepository, windowController: PBGitWindowController) {
        self.repository = repository
        self.windowController = windowController
        ownerIsCurrent = windowController.repositoryOwnerValidation(for: repository)
        super.init()
    }

    @objc(checkoutRefish:)
    func checkout(_ refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        logger.debug("Starting checkout action")
        perform { _ = try repository.checkoutRefish(refish) }
    }

    @objc(deleteRef:)
    func delete(_ ref: PBGitRef?) {
        guard ownerIsCurrent() else { return }
        guard let ref,
              ReferenceActionPolicy.canDelete(refishType: ref.refishType()) else { return }
        let type = ref.refishType() ?? ""
        let shortName = ref.shortName()
        let alert = NSAlert()
        alert.messageText = ReferenceActionPolicy.deletionConfirmationTitle(refishType: type, shortName: shortName)
        alert.informativeText = ReferenceActionPolicy.deletionConfirmationMessage(refishType: type, shortName: shortName)
        alert.addButton(withTitle: ReferenceActionPolicy.deletionConfirmationButtonTitle(refishType: type))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Delete ref alert - cancel button"))
        logger.debug("Requesting reference deletion confirmation")
        windowController?.confirmDialog(alert, suppressionIdentifier: "Delete Ref") { [weak self] in
            guard let self, self.ownerIsCurrent() else { return }
            self.perform(confirmed: true) { _ = try self.repository.deleteRef(ref) }
        }
    }

    @objc(mergeRefish:)
    func merge(_ refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        logger.debug("Starting merge action")
        perform { _ = try repository.merge(with: refish) }
    }

    @objc(rebaseOnRefish:)
    func rebase(on refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        logger.debug("Starting rebase action")
        perform { _ = try repository.rebaseBranch(nil, on: refish) }
    }

    @objc(cherryPickRefish:)
    func cherryPick(_ refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        logger.debug("Starting cherry-pick action")
        perform { _ = try repository.cherryPick(refish) }
    }

    @objc(resetSoftToRefish:)
    func resetSoft(to refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        logger.debug("Starting soft-reset action")
        perform { _ = try repository.resetRefish(.soft, to: refish) }
    }

    @objc(createBranchFromRefish:selectedCommit:)
    func createBranch(from explicitRefish: PBGitRefish?, selectedCommit: PBGitCommit?) {
        guard ownerIsCurrent() else { return }
        let currentRef = repository.currentBranch?.ref()
        let initialRefish: PBGitRefish?
        if let explicitRefish {
            initialRefish = explicitRefish
        } else if let selectedCommit {
            if let currentRef, selectedCommit.hasRef(currentRef) {
                initialRefish = currentRef
            } else {
                initialRefish = selectedCommit
            }
        } else {
            initialRefish = currentRef
        }
        guard let initialRefish, let windowController else { return }

        logger.debug("Starting create-branch workflow")
        PBCreateBranchSheet.begin(
            refish: initialRefish,
            windowController: windowController
        ) { [weak self] sheet, response in
            guard response == .OK, let self, self.ownerIsCurrent(), let sheet = sheet as? PBCreateBranchSheet else { return }
            self.perform(confirmed: true) {
                _ = try self.repository.createBranch(sheet.branchNameField.stringValue, at: sheet.startRefish)
                PBGitDefaults.setShouldCheckoutBranch(sheet.shouldCheckoutBranch)
                if sheet.shouldCheckoutBranch {
                    _ = try self.repository.checkoutRefish(sheet.selectedRef)
                }
                self.logger.debug("Create-branch workflow completed")
            }
        }
    }

    @objc(createTagFromRefish:selectedCommit:)
    func createTag(from explicitRefish: PBGitRefish?, selectedCommit: PBGitCommit?) {
        guard ownerIsCurrent() else { return }
        let initialRefish: PBGitRefish?
        if let explicitRefish {
            initialRefish = explicitRefish
        } else if let selectedCommit {
            initialRefish = selectedCommit
        } else {
            initialRefish = repository.currentBranch?.ref()
        }
        guard let initialRefish, let windowController else { return }
        logger.debug("Starting create-tag workflow")
        PBCreateTagSheet.begin(
            refish: initialRefish,
            windowController: windowController
        ) { [weak self] sheet, response in
            guard response == .OK, let self, self.ownerIsCurrent(), let sheet = sheet as? PBCreateTagSheet else { return }
            self.perform(confirmed: true) {
                _ = try self.repository.createTag(
                    sheet.tagNameField?.stringValue,
                    message: sheet.tagMessageText?.string ?? "",
                    at: sheet.targetRefish
                )
            }
        }
    }

    @objc(showDiffWithHEADForRefish:)
    func showDiffWithHEAD(for refish: PBGitRefish?) {
        guard ownerIsCurrent() else { return }
        guard let refish else { return }
        let commit = (refish as? PBGitCommit) ?? repository.commit(for: refish as? PBGitRef)
        guard let commit else { return }
        logger.debug("Rendering reference diff")
        PBDiffWindowController.showDiff(repository.performDiff(commit, against: nil, forFiles: nil))
    }

    @objc(showStashDiff:)
    func showStashDiff(_ stash: PBGitStash?) {
        guard ownerIsCurrent() else { return }
        guard let stash else { return }
        logger.debug("Rendering stash diff")
        PBDiffWindowController.showDiffWindow(
            withFiles: nil,
            from: stash.ancestorCommit,
            diffCommit: stash.commit
        )
    }

    @objc(showTagInfoForRef:)
    func showTagInfo(for ref: PBGitRef?) {
        guard ownerIsCurrent() else { return }
        guard let ref, let tagName = ref.tagName, let gitRepository = repository.gtRepo else { return }
        do {
            let object = try gitRepository.lookUpObject(byRevParse: "refs/tags/" + tagName)
            let message = (object as? GTTag)?.message ?? ""
            logger.debug("Showing tag information")
            windowController?.showMessageSheet("Info for tag: \(tagName)", infoText: message)
        } catch {
            logger.error("Tag information lookup failed")
        }
    }

    private func perform(confirmed: Bool = false, _ action: () throws -> Void) {
        guard ownerIsCurrent() else { return }
        guard CommitSubmissionEligibility.allowsMutation(repository.index) else {
            logger.debug("Refused reference action while repository mutation is active; confirmed: \(confirmed)")
            if confirmed {
                present(IndexWriterCoordinator.busyError())
            }
            return
        }
        do {
            try action()
            logger.debug("Reference action completed")
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        guard ownerIsCurrent() else { return }
        logger.error("Reference action failed")
        windowController?.showErrorSheet(error as NSError)
    }
}

// swiftlint:enable unused_declaration
