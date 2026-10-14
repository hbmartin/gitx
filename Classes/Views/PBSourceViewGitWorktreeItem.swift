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
        if let branch = worktree.branchRefName {
            revision = PBGitRevSpecifier(ref: PBGitRef(string: branch))
        } else if worktree.isDetached, let head = worktree.HEAD, !head.isEmpty {
            // The complex-revision pipeline includes commits reachable only
            // through this linked checkout's captured detached HEAD.
            revision = PBGitRevSpecifier(parameters: [head + "^{commit}"], description: "Detached HEAD (\(head))")
        } else {
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
