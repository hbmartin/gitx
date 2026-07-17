import OSLog // swiftlint:disable:this unused_import

/// The legacy progress sheet deliberately invokes its execution handler on a
/// global queue. Keep the Objective-C repository and refish arguments together
/// behind one audited Sendable boundary instead of actor-isolating that handler.
// swift6-safety-justification: The immutable operation target retains Objective-C values that the legacy API already uses exclusively on its worker queue.
private final nonisolated class RemoteOperationTarget: @unchecked Sendable {
    private let repository: PBGitRepository
    private let branch: PBGitRef?
    private let remote: PBGitRef?

    init(repository: PBGitRepository, branch: PBGitRef? = nil, remote: PBGitRef? = nil) {
        self.repository = repository
        self.branch = branch
        self.remote = remote
    }

    func addRemote(name: String, url: String) throws {
        _ = try repository.addRemote(name, withURL: url)
    }

    func fetch() throws {
        _ = try repository.fetchRemote(for: branch)
    }

    func pull(rebase: Bool) throws {
        _ = try repository.pullBranch(branch, fromRemote: remote, rebase: rebase)
    }

    func push() throws {
        _ = try repository.pushBranch(branch, toRemote: remote)
    }

    var pushOutput: String {
        repository.lastPushOutput ?? ""
    }
}

// Objective-C actions call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBRepositoryRemoteActionCoordinator)
final class RepositoryRemoteActionCoordinator: NSObject {
    // Progress operations run after the initiating window action returns, so the
    // repository must remain alive until the progress sheet completes.
    private let repository: PBGitRepository
    private weak var windowController: PBGitWindowController?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryRemoteActionCoordinator")

    @objc(initWithRepository:windowController:)
    init(repository: PBGitRepository, windowController: PBGitWindowController) {
        self.repository = repository
        self.windowController = windowController
        super.init()
    }

    @objc(addRemote)
    func addRemote() {
        guard let windowController else { return }
        logger.debug("Starting add-remote workflow")
        PBAddRemoteSheet.begin(windowController: windowController) { [weak self] sheet, response in
            guard response == .OK, let self, let sheet = sheet as? PBAddRemoteSheet else { return }
            let remoteName = sheet.remoteName?.stringValue ?? ""
            let remoteURL = sheet.remoteURL?.stringValue ?? ""
            let operationTarget = RemoteOperationTarget(repository: self.repository)
            self.runProgress(
                title: "Adding remote",
                description: "Adding remote \"\(remoteName)\"",
                operation: {
                    try operationTarget.addRemote(name: remoteName, url: remoteURL)
                },
                completion: { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.windowController?.showErrorSheet(error)
                        return
                    }
                    self.logger.debug("Add-remote workflow completed")
                    let remoteRef = self.repository.ref(forName: remoteName)
                    self.windowController?.performFetch(for: remoteRef)
                }
            )
        }
    }

    @objc(performFetchForRef:)
    func performFetch(for ref: PBGitRef?) {
        let description: String
        if let ref {
            if ref.isRemote || ref.isRemoteBranch {
                description = "Fetching branches from remote \(ref.remoteName ?? "")"
            } else {
                description = "Fetching tracking branch for \(ref.shortName())"
            }
        } else {
            description = "Fetching all remotes"
        }

        logger.debug("Starting fetch workflow")
        let operationTarget = RemoteOperationTarget(repository: repository, branch: ref)
        runProgress(
            title: "Fetching remote…",
            description: description,
            operation: {
                try operationTarget.fetch()
            },
            completion: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.windowController?.showErrorSheet(error)
                } else if let repositoryURL = self.repository.workingDirectoryURL() {
                    PBAutoFetchManager.shared().recordManualFetchSucceeded(forRepositoryURL: repositoryURL)
                    self.logger.debug("Fetch workflow completed")
                }
            }
        )
    }

    @objc(performPullForBranch:remote:rebase:)
    func performPull(branch: PBGitRef?, remote: PBGitRef?, rebase: Bool) {
        let description: String
        if branch == nil, let remote {
            description = "Pulling all tracking branches from \(remote.remoteName ?? "")"
        } else if let branch, remote == nil {
            description = "Pulling default remote for branch \(branch.shortName())"
        } else if let branch, let remote {
            description = "Pulling branch \(branch.shortName()) from remote \(remote.remoteName ?? "")"
        } else {
            assertionFailure("Asked to pull no branch from no remote")
            return
        }

        logger.debug("Starting pull workflow")
        let operationTarget = RemoteOperationTarget(repository: repository, branch: branch, remote: remote)
        runProgress(
            title: "Pulling remote…",
            description: description,
            operation: {
                try operationTarget.pull(rebase: rebase)
            },
            completion: { [weak self] error in
                if let error {
                    self?.windowController?.showErrorSheet(error)
                } else {
                    self?.logger.debug("Pull workflow completed")
                }
            }
        )
    }

    @objc(performPushForBranch:remote:requiresConfirmation:)
    func performPush(branch: PBGitRef?, remote: PBGitRef?, requiresConfirmation: Bool) {
        guard branch != nil || remote != nil,
              branch == nil || branch?.isBranch == true || branch?.isRemoteBranch == true || branch?.isTag == true,
              remote == nil || remote?.isRemote == true
        else {
            logger.debug("Rejected invalid push context")
            return
        }

        let description = pushDescription(branch: branch, remote: remote, capitalized: true)
        let beginPush = { [weak self] in
            guard let self else { return }
            self.logger.debug("Starting push workflow")
            let operationTarget = RemoteOperationTarget(repository: self.repository, branch: branch, remote: remote)
            self.runProgress(
                title: "Pushing remote…",
                description: self.pushDescription(branch: branch, remote: remote, capitalized: false),
                operation: {
                    try operationTarget.push()
                },
                completion: { [weak self] error in
                    if let error {
                        self?.windowController?.showErrorSheet(error)
                    } else {
                        self?.logger.debug("Push workflow completed")
                        if let self {
                            RepositoryRemoteURLCoordinator.shared.handleSuccessfulPush(
                                output: operationTarget.pushOutput,
                                repository: self.repository,
                                remote: remote,
                                presenting: self.windowController?.window
                            )
                        }
                    }
                }
            )
        }

        guard requiresConfirmation, let windowController else {
            beginPush()
            return
        }
        let lowerDescription = "p" + description.dropFirst()
        let alert = NSAlert()
        alert.messageText = description
        alert.informativeText = "Are you sure you want to \(lowerDescription)?"
        alert.addButton(withTitle: NSLocalizedString("Push", comment: "Push alert - default button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Push alert - cancel button"))
        alert.showsSuppressionButton = true
        windowController.confirmDialog(alert, suppressionIdentifier: "Confirm Push", forAction: beginPush)
    }

    private func pushDescription(branch: PBGitRef?, remote: PBGitRef?, capitalized: Bool) -> String {
        let verb = capitalized ? "Push" : "Pushing"
        if let branch, let remote {
            return "\(verb) \(branch.refishType() ?? "") '\(branch.shortName())' to remote \(remote.remoteName ?? "")"
        }
        if let branch {
            return "\(verb) \(branch.refishType() ?? "") '\(branch.shortName())' to default remote"
        }
        return "\(verb) updates to remote \(remote?.remoteName ?? "")"
    }

    private func runProgress(
        title: String,
        description: String,
        operation: @escaping @Sendable () throws -> Void,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let windowController else { return }
        let progressSheet = PBRemoteProgressSheet(
            title: title,
            description: description,
            windowController: windowController
        )
        progressSheet.begin(
            execution: {
                do {
                    try operation()
                    return nil
                } catch {
                    return error as NSError
                }
            },
            completion: { error in
                completion(error as NSError?)
            }
        )
    }
}

// swiftlint:enable unused_declaration
