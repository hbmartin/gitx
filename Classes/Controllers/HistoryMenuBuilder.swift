import AppKit
import GitXCore
import OSLog // swiftlint:disable:this unused_import

// SwiftLint's analyzer cannot see these entry points through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBHistoryMenuBuilder)
final class HistoryMenuBuilder: NSObject {
    private let repository: PBGitRepository
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "HistoryMenuBuilder")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
    }

    private func item(_ title: String, action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        menuItem.isEnabled = enabled
        return menuItem
    }

    @objc(menuItemsForPaths:selectedCommit:)
    func menuItems(for paths: [String], selectedCommit: PBGitCommit?) -> [NSMenuItem] {
        let filePaths = paths.map { $0.trimmingCharacters(in: .whitespaces) }
        let multiple = filePaths.count != 1
        let hasCommit = selectedCommit != nil
        if !hasCommit {
            logger.debug("Disabling commit-dependent path menu actions without a selected commit")
        }
        let history = item(multiple ? "Show history of files" : "Show history of file", action: NSSelectorFromString("showCommitsFromTree:"))
        let headName = repository.headRef()?.ref()?.shortName() ?? "HEAD"
        let isHead = selectedCommit?.oid == repository.headOID()
        let diff = item("\(multiple ? "Diff files" : "Diff file") with \(headName)", action: NSSelectorFromString("diffFilesAction:"), enabled: hasCommit && !isHead)
        let checkout = item(multiple ? "Checkout files" : "Checkout file", action: NSSelectorFromString("checkoutFiles:"), enabled: hasCommit)
        let finder = item("Reveal in Finder", action: #selector(PBGitWindowController.revealInFinder(_:)))
        let open = item(multiple ? "Open Files" : "Open File", action: #selector(PBGitWindowController.openFiles(_:)))
        let items = [history, diff, checkout, finder, open]
        items.forEach { $0.representedObject = filePaths }
        return items
    }

    @objc(menuItemsForRef:)
    func menuItems(for ref: PBGitRef?) -> [NSMenuItem]? {
        guard let ref else { return nil }
        if ref.refishName() == "refs/stash" {
            return []
        }
        if ref.isStash {
            return stashItems(ref)
        }

        return referenceMenuItems(for: ref, worktree: worktreeService.worktree(forBranch: ref.ref))
    }

    /// A checkout row carries its own lifecycle identity even when Git permits
    /// the same local branch in more than one worktree.
    func menuItems(for ref: PBGitRef, selectedWorktree: PBGitWorktree) -> [NSMenuItem] {
        guard SidebarWorktreeMenuPolicy.canUseReferenceMenu(reference: ref.ref, branchIdentity: selectedWorktree.value.branchIdentity) else {
            logger.info("Worktree menu fallback: count=1 category=reference-mismatch")
            return menuItems(forWorktree: selectedWorktree)
        }
        logger.info("Worktree branch menu: count=1 category=clicked-checkout")
        return referenceMenuItems(for: ref, worktree: selectedWorktree)
    }

    private func referenceMenuItems(for ref: PBGitRef, worktree: PBGitWorktree?) -> [NSMenuItem] {
        let refName = ref.shortName()
        let headRef = repository.headRef()?.ref()
        let headName = headRef?.shortName() ?? "HEAD"
        let isHead = headRef.map(ref.isEqual) ?? false
        let onHead = isHead || repository.isRef(onHeadBranch: ref)
        let detached = isHead && headName == "HEAD"
        let trackingRef = ref.isBranch ? try? repository.remoteRef(forBranch: ref) : nil
        let remoteName = ref.remoteName ?? trackingRef?.remoteName
        let hasRemote = remoteName != nil
        let remoteOnly = ref.isRemote && !ref.isRemoteBranch
        var items: [NSMenuItem] = []

        if !remoteOnly {
            if let worktree {
                items.append(worktreeItem("Open Worktree of Branch “\(refName)”", action: #selector(PBGitWindowController.openWorktree(_:)), worktree: worktree,
                                          enabled: WorktreeEligibility(worktree.value, supported: worktreeService.isSupported).canOpen))
            } else {
                items.append(item("Checkout “\(refName)”", action: #selector(PBGitWindowController.checkout(_:)), enabled: !isHead))
            }
            if ref.isBranch || ref.isRemoteBranch {
                let copyBranchName = item("Copy Branch Name", action: #selector(copyBranchName(_:)))
                copyBranchName.target = self
                items.append(copyBranchName)
            }
            items.append(.separator())
            if let worktree {
                items += worktreeFolderItems(worktree) + [.separator()]
            } else if ref.isBranch {
                let create = worktreeItem("Checkout “\(refName)” in New Worktree…", action: #selector(PBGitWindowController.checkOutInNewWorktree(_:)), enabled: worktreeService.isSupported && !isHead, reason: "This branch is checked out here. Git checks a branch out in one worktree at a time.")
                create.representedObject = ref
                items += [create, .separator()]
            }
            let branchTitle = ref.isRemoteBranch ? "Create Branch tracking “\(refName)”…" : "Create Branch…"
            items += [item(branchTitle, action: #selector(PBGitWindowController.createBranch(_:))), item("Create Tag…", action: #selector(PBGitWindowController.createTag(_:)))]
            if ref.isTag {
                items.append(item("View Tag Info…", action: #selector(PBGitWindowController.showTagInfoSheet(_:))))
            }
            items += [item("Diff with “\(headName)”", action: #selector(PBGitWindowController.diffWithHEAD(_:)), enabled: !isHead), .separator()]
            items.append(item(onHead ? "Merge" : "Merge \(refName) into \(headName)", action: #selector(PBGitWindowController.merge(_:)), enabled: !onHead))
            items.append(item(onHead ? "Rebase" : "Rebase ”\(headName)“ onto “\(refName)”", action: #selector(PBGitWindowController.rebaseHeadBranch(_:)), enabled: !onHead))
            items += [.separator(), item("Reset to “\(refName)”", action: #selector(PBGitWindowController.resetSoft(_:)), enabled: !isHead), .separator()]
        }

        items.append(item(hasRemote ? "Fetch “\(remoteName!)”" : "Fetch", action: #selector(PBGitWindowController.fetchRemote(_:)), enabled: hasRemote))
        items.append(item(hasRemote ? "Pull “\(remoteName!)” and Update “\(headName)”" : "Pull", action: #selector(PBGitWindowController.pullRemote(_:)), enabled: hasRemote))
        if remoteOnly || ref.isRemoteBranch {
            items.append(item("Push Updates to “\(remoteName ?? "")”", action: #selector(PBGitWindowController.pushUpdatesToRemote(_:))))
        } else if detached {
            items.append(item("Push", action: nil, enabled: false))
        } else {
            var hasDefault = false
            if !ref.isTag, let remoteName {
                hasDefault = true
                items.append(item("Push “\(refName)” to “\(remoteName)”", action: #selector(PBGitWindowController.pushDefaultRemoteForRef(_:))))
            }
            let remotes = repository.remotes() ?? []
            if !remotes.isEmpty, !(hasDefault && remotes.count == 1) {
                let pushTo = item("Push “\(refName)” to", action: nil)
                let submenu = NSMenu(title: "Remotes Menu")
                for remote in remotes {
                    let remoteItem = item(remote, action: #selector(PBGitWindowController.pushToRemote(_:)))
                    remoteItem.representedObject = remote
                    submenu.addItem(remoteItem)
                }
                pushTo.submenu = submenu
                pushTo.representedObject = ref
                items.append(pushTo)
            }
        }

        items.append(.separator())
        if let worktree {
            items.append(removeWorktreeItem(worktree))
        } else if !(detached || isHead || ref.ref.hasPrefix("refs/stash")) {
            let title = ReferenceActionPolicy.deletionMenuTitle(refName: refName, isRemote: ref.isRemote)
            items.append(item(title, action: #selector(PBGitWindowController.deleteRef(_:))))
        }
        items.filter { $0.representedObject == nil }.forEach { $0.representedObject = ref }
        return items
    }

    @objc(copyBranchName:)
    private func copyBranchName(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? PBGitRef,
              ref.isBranch || ref.isRemoteBranch
        else {
            logger.error("Ignoring Copy Branch Name without an eligible branch reference")
            return
        }

        let branchName = ref.shortName()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(branchName, forType: .string)
        logger.debug("Copied branch name to the pasteboard")
    }

    private func stashItems(_ ref: PBGitRef) -> [NSMenuItem] {
        let name = ref.shortName()
        let items = [
            item("Pop \(name)", action: #selector(PBGitWindowController.stashPop(_:))),
            item("Apply \(name)", action: #selector(PBGitWindowController.stashApply(_:))),
            item("View Diff", action: #selector(PBGitWindowController.stashViewDiff(_:))),
            NSMenuItem.separator(),
            item("Drop \(name)", action: #selector(PBGitWindowController.stashDrop(_:))),
        ]
        items.forEach { $0.representedObject = ref }
        return items
    }

    @objc(menuItemsForCommits:)
    func menuItems(for commits: [PBGitCommit]) -> [NSMenuItem] {
        guard let first = commits.first else { return [] }
        let single = commits.count == 1
        let headName = first.repository?.headRef()?.ref()?.shortName() ?? "HEAD"
        let onHead = first.isOnHeadBranch()
        let isHead = first.oid == first.repository?.headOID()
        var items: [NSMenuItem] = []
        if single {
            items += [item("Checkout Commit", action: #selector(PBGitWindowController.checkout(_:))), .separator(), item("Create Branch…", action: #selector(PBGitWindowController.createBranch(_:))), item("Create Tag…", action: #selector(PBGitWindowController.createTag(_:))), .separator()]
        }
        items += [
            item("Copy SHA-1", action: #selector(PBGitHistoryController.copySHA(_:))),
            item("Copy Short SHA-1", action: #selector(PBGitHistoryController.copyShortName(_:))),
            item("Copy Patch", action: #selector(PBGitHistoryController.copyPatch(_:))),
            item("Create Patch…", action: #selector(PBGitHistoryController.createPatch(_:))),
        ]
        if single {
            items += [item("Diff with “\(headName)”", action: #selector(PBGitWindowController.diffWithHEAD(_:)), enabled: !isHead), .separator()]
            items.append(item(onHead ? "Merge Commit" : "Merge Commit into “\(headName)”", action: #selector(PBGitWindowController.merge(_:)), enabled: !onHead))
            items.append(item(onHead ? "Cherry Pick Commit" : "Cherry Pick Commit to “\(headName)”", action: #selector(PBGitWindowController.cherryPick(_:)), enabled: !onHead))
            items.append(item(onHead ? "Rebase Commit" : "Rebase “\(headName)” onto Commit", action: #selector(PBGitWindowController.rebaseHeadBranch(_:)), enabled: !onHead))
            items.append(item("Reset to commit", action: #selector(PBGitWindowController.resetSoft(_:)), enabled: !isHead))
        }
        let represented: Any = single ? first : commits
        items.filter { $0.representedObject == nil }.forEach { $0.representedObject = represented }
        return items
    }
}

// swiftlint:enable unused_declaration

extension HistoryMenuBuilder {
    private var worktreeService: PBRepositoryWorktreeService {
        repository.worktreeService
    }

    private func worktreeItem(_ title: String, action: Selector, worktree: PBGitWorktree? = nil, enabled: Bool, reason: String? = nil) -> NSMenuItem {
        let menu = item(title, action: action, enabled: enabled)
        menu.representedObject = worktree
        menu.toolTip = enabled ? worktree?.path : (worktreeService.isSupported ? reason : worktreeService.explanation)
        return menu
    }

    private func worktreeFolderItems(_ worktree: PBGitWorktree) -> [NSMenuItem] {
        let eligibility = WorktreeEligibility(worktree.value, supported: worktreeService.isSupported)
        let folder: NSMenuItem
        if !WorktreePolicy.manualRepairPaths([worktree.value]).isEmpty {
            folder = worktreeItem("Show Link Repair Guidance…", action: #selector(PBGitWindowController.repairWorktreeLinks(_:)), worktree: worktree, enabled: worktreeService.isSupported)
        } else if worktree.hasBrokenLink {
            folder = worktreeItem("Repair Worktree Links…", action: #selector(PBGitWindowController.repairWorktreeLinks(_:)), worktree: worktree, enabled: worktreeService.isSupported)
        } else if worktree.value.folderExists {
            folder = worktreeItem("Reveal Worktree in Finder", action: #selector(PBGitWindowController.revealWorktreeInFinder(_:)), worktree: worktree, enabled: eligibility.canReveal)
        } else {
            folder = worktreeItem("Locate Worktree Folder…", action: #selector(PBGitWindowController.locateWorktreeFolder(_:)), worktree: worktree, enabled: eligibility.canLocate)
        }
        let lock = worktree.isLocked && !worktree.isMain
            ? worktreeItem("Unlock Worktree", action: #selector(PBGitWindowController.unlockWorktree(_:)), worktree: worktree, enabled: eligibility.canUnlock)
            : worktreeItem("Lock Worktree…", action: #selector(PBGitWindowController.lockWorktree(_:)), worktree: worktree, enabled: eligibility.canLock, reason: "Git cannot lock the main worktree.")
        return [folder, lock, worktreeItem("Refresh Worktrees", action: #selector(PBGitWindowController.refreshWorktrees(_:)), enabled: true)]
    }

    private func removeWorktreeItem(_ worktree: PBGitWorktree) -> NSMenuItem {
        let reason = worktree.isMain ? "Git never removes the main worktree." : "Locked\(worktree.lockReason.map { ": \($0)" } ?? ""). Unlock it first."
        return worktreeItem("Remove Worktree…", action: #selector(PBGitWindowController.removeWorktree(_:)), worktree: worktree,
                            enabled: WorktreeEligibility(worktree.value, supported: worktreeService.isSupported).canRemove, reason: reason)
    }

    @objc(menuItemsForWorktree:)
    func menuItems(forWorktree worktree: PBGitWorktree) -> [NSMenuItem] {
        [worktreeItem("Open Worktree", action: #selector(PBGitWindowController.openWorktree(_:)), worktree: worktree,
                      enabled: WorktreeEligibility(worktree.value, supported: worktreeService.isSupported).canOpen), .separator()]
            + worktreeFolderItems(worktree) + [.separator(), removeWorktreeItem(worktree)]
    }

    @objc(menuItemsForWorktreeGroup)
    func menuItemsForWorktreeGroup() -> [NSMenuItem] {
        let items = [worktreeItem("Add Worktree…", action: #selector(PBGitWindowController.addWorktree(_:)), enabled: worktreeService.isSupported),
                     worktreeItem("Prune Worktrees…", action: #selector(PBGitWindowController.pruneWorktrees(_:)),
                                  enabled: WorktreeEligibility.canPrune(worktreeService.worktrees.map(\.value), supported: worktreeService.isSupported),
                                  reason: "Repair the worktree links first; these worktrees moved with the repository."),
                     worktreeItem("Refresh Worktrees", action: #selector(PBGitWindowController.refreshWorktrees(_:)), enabled: true)]
        guard !WorktreePolicy.manualRepairPaths(worktreeService.worktrees.map(\.value)).isEmpty else { return items }
        return items + [.separator(), worktreeItem("Show Link Repair Guidance…", action: #selector(PBGitWindowController.repairWorktreeLinks(_:)), enabled: worktreeService.isSupported)]
    }
}
