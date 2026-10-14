import AppKit
import GitXCore

@objc(PBSourceViewGitWorktreeItem)
final nonisolated class PBSourceViewGitWorktreeItem: PBSourceViewItem {
    @objc let worktree: PBGitWorktree
    @objc var identity: Data {
        worktree.canonicalIdentity
    }

    init(worktree: PBGitWorktree) {
        self.worktree = worktree
        let revision: PBGitRevSpecifier?
        switch WorktreePresentation.historyRevision(for: worktree.value) {
        case let .branch(branch):
            revision = PBGitRevSpecifier(ref: PBGitRef(string: branch))
        case let .capturedCommit(head, description):
            // The complex-revision pipeline includes commits reachable only
            // through this linked checkout's captured HEAD.
            revision = PBGitRevSpecifier(parameters: [head + "^{commit}"], description: description)
        case nil:
            revision = nil
        }
        super.init(title: WorktreePresentation.title(worktree.value), revSpecifier: revision)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Worktree sidebar items do not support coding")
    }

    override var icon: NSImage? {
        NSImage(named: "WorktreeBranchTemplate")
    }
}
