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
}
