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
        let revision = worktree.branchRefName.map { PBGitRevSpecifier(ref: PBGitRef(string: $0)) }
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
