import OSLog // swiftlint:disable:this unused_import

// Objective-C actions call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryStashActionCoordinator)
final class RepositoryStashActionCoordinator: NSObject {
    private unowned let repository: PBGitRepository
    private weak var windowController: PBGitWindowController?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryStashActionCoordinator")

    @objc(initWithRepository:windowController:)
    init(repository: PBGitRepository, windowController: PBGitWindowController) {
        self.repository = repository
        self.windowController = windowController
        super.init()
    }

    @objc(saveWithKeepIndex:)
    func save(keepIndex: Bool) {
        logger.debug("Starting stash-save action")
        perform { _ = try repository.stashSave(withKeepIndex: keepIndex) }
    }

    @objc(popRef:)
    func pop(ref: PBGitRef?) {
        guard let stash = ref.flatMap(repository.stash(for:)) ?? repository.stashes.first else { return }
        logger.debug("Starting stash-pop action")
        perform { _ = try repository.stashPop(stash) }
    }

    @objc(applyRef:)
    func apply(ref: PBGitRef?) {
        guard let ref, let stash = repository.stash(for: ref) else { return }
        logger.debug("Starting stash-apply action")
        perform { _ = try repository.stashApply(stash) }
    }

    @objc(dropRef:)
    func drop(ref: PBGitRef?) {
        guard let ref, let stash = repository.stash(for: ref) else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Dropping stash", comment: "Stash drop alert - title")
        alert.informativeText = String(
            format: NSLocalizedString("You're about to drop stash %@.", comment: "Stash drop alert - message"),
            ref.shortName()
        )
        alert.addButton(withTitle: NSLocalizedString("Drop", comment: "Stash drop alert - default button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Stash drop alert - cancel button"))
        logger.debug("Requesting stash-drop confirmation")
        windowController?.confirmDialog(alert, suppressionIdentifier: "Stash Drop") { [weak self] in
            guard let self else { return }
            self.perform { _ = try self.repository.stashDrop(stash) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            logger.debug("Stash action completed")
        } catch {
            logger.error("Stash action failed")
            windowController?.showErrorSheet(error as NSError)
        }
    }
}

// swiftlint:enable unused_declaration
