import AppKit

extension PBGitWindowController {
    @IBAction dynamic func toolbarFetch(_ sender: Any?) {
        fetchAllRemotes(sender)
    }

    @IBAction dynamic func toolbarPull(_ sender: Any?) {
        guard let head = repository?.headRef()?.ref(), head.isBranch else { return }
        performPull(forBranch: head, remote: nil, rebase: false)
    }

    @IBAction dynamic func toolbarPush(_ sender: Any?) {
        guard let head = repository?.headRef()?.ref(), head.isBranch else { return }
        performPush(forBranch: head, toRemote: nil)
    }

    @IBAction dynamic func viewRemote(_ sender: Any?) {
        guard let repository else { return }
        RepositoryRemoteURLCoordinator.shared.viewRemote(repository: repository, presenting: window)
    }

    @IBAction dynamic func viewForgeRepository(_ sender: Any?) {
        forgeLinkUseCase?.openRepository()
    }

    @IBAction dynamic func viewForgeCheckedOutRevision(_ sender: Any?) {
        forgeLinkUseCase?.openCheckedOutRevision(forgeLinkContext.checkedOutRevision)
    }

    @IBAction dynamic func viewForgeSelectedCommit(_ sender: Any?) {
        forgeLinkUseCase?.openSelectedCommit(forgeLinkContext.selectedCommitIdentifiers)
    }

    @IBAction dynamic func viewForgeSelectedComparison(_ sender: Any?) {
        forgeLinkUseCase?.openSelectedComparison(forgeLinkContext.selectedCommitIdentifiers)
    }

    @IBAction dynamic func showForgePullRequestOrIssue(_ sender: Any?) {
        forgeLinkUseCase?.requestNumberReference()
    }
}
