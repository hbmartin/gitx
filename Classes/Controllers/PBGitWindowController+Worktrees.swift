import AppKit
import GitXCore

extension PBGitWindowController {
    private var worktreeService: PBRepositoryWorktreeService? {
        repository?.worktreeService
    }

    private func selectedWorktree(_ sender: Any?) -> PBGitWorktree? {
        let represented = (sender as? NSMenuItem)?.representedObject
        if let worktree = represented as? PBGitWorktree {
            return worktree
        }
        if let ref = represented as? PBGitRef {
            return worktreeService?.worktree(forBranch: ref.ref)
        }
        return nil
    }

    @IBAction @objc(openWorktree:)
    dynamic func openWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender) else { return }
        open(worktree: worktree)
    }

    func open(worktree: PBGitWorktree) {
        guard let service = worktreeService, service.isSupported else { return }
        if worktree.hasBrokenLink {
            repairWorktreeLinks(nil); return
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            let alert = NSAlert()
            alert.messageText = "The worktree folder is unavailable"
            alert.informativeText = "\(worktree.path)\n\nConnect its disk, prune the registration, or locate the folder if it was moved."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Locate Folder…")
            presentWorktreeSheet(alert) { [self] response in
                if response == .alertSecondButtonReturn {
                    self.locate(worktree: worktree)
                }
            }
            return
        }
        RepositoryOpenCoordinator.shared.open(urls: [URL(fileURLWithPath: worktree.path)], sourceWindow: window) { [weak self] _, errors in
            for error in errors {
                self?.showErrorSheet(error)
            }
        }
    }

    @IBAction @objc(revealWorktreeInFinder:)
    dynamic func revealWorktreeInFinder(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }

    @IBAction @objc(locateWorktreeFolder:)
    dynamic func locateWorktreeFolder(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender) else { return }
        locate(worktree: worktree)
    }

    private func locate(worktree: PBGitWorktree) {
        guard let window, let service = worktreeService, service.isSupported else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder the worktree at \(worktree.path) was moved to."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let parent = URL(fileURLWithPath: worktree.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: parent.path) ? parent : newWorktreeParent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            service.repair(worktree: worktree, movedTo: url.path) { error in
                if let error {
                    self?.showErrorSheet(error)
                }
            }
        }
    }

    @IBAction @objc(lockWorktree:)
    dynamic func lockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let service = worktreeService,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canLock else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Reason (optional)"
        let alert = NSAlert()
        alert.messageText = "Lock the worktree at \(worktree.path)?"
        alert.informativeText = "Git will not prune, move or remove a locked worktree, and shows the reason to anyone who tries."
        alert.accessoryView = field
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            self.performWorktree(.lock(path: worktree.path, reason: field.stringValue))
        }
    }

    @IBAction @objc(unlockWorktree:)
    dynamic func unlockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let service = worktreeService,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canUnlock else { return }
        performWorktree(.unlock(path: worktree.path))
    }

    @IBAction @objc(removeWorktree:)
    dynamic func removeWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let service = worktreeService,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canRemove else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree at \(worktree.path)?"
        alert.informativeText = "Its folder is deleted." + (worktree.branchRefName.map { " The branch “\($0.dropFirst(11))” is kept." } ?? "")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            service.perform(.remove(path: worktree.path, force: false)) { [weak self] _, error in
                guard let self, let error else { return }
                let reason = error.localizedFailureReason ?? error.localizedDescription
                guard WorktreePolicy.offersForcedRemoval(gitMessage: reason) else { self.showErrorSheet(error); return }
                let force = NSAlert()
                force.messageText = "Git did not remove the worktree"
                force.informativeText = "\(reason)\n\nRemove Anyway deletes the folder and any uncommitted work in it."
                force.addButton(withTitle: "Remove Anyway").hasDestructiveAction = true
                force.addButton(withTitle: "Cancel")
                self.presentWorktreeSheet(force) { [self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self.performWorktree(.remove(path: worktree.path, force: true))
                }
            }
        }
    }

    @IBAction @objc(pruneWorktrees:)
    dynamic func pruneWorktrees(_: Any?) {
        guard let service = worktreeService, service.isSupported else { return }
        guard !service.worktrees.contains(where: { $0.movedPath != nil }) else { repairWorktreeLinks(nil); return }
        service.perform(.pruneReport) { [weak self] report, error in
            guard let self else { return }
            if let error {
                self.showErrorSheet(error); return
            }
            let report = (report ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let alert = NSAlert()
            if report.isEmpty {
                alert.messageText = "Nothing to prune"
                alert.informativeText = "Every worktree Git knows of still has its folder."
                alert.addButton(withTitle: "OK")
                self.presentWorktreeSheet(alert) { _ in }
                return
            }
            alert.messageText = "Prune these worktrees?"
            alert.informativeText = "Git will forget these worktrees:\n\n\(report)"
            alert.addButton(withTitle: "Prune")
            alert.addButton(withTitle: "Cancel")
            self.presentWorktreeSheet(alert) { [self] response in
                if response == .alertFirstButtonReturn {
                    self.performWorktree(.prune)
                }
            }
        }
    }

    private func newWorktreeParent() -> URL? {
        let path = worktreeService?.worktrees.first(where: \.isMain)?.path ?? repository?.workingDirectoryURL()?.path
        return path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    private func chooseWorktreeFolder(branch: String, newBranch: Bool) {
        guard let window, let service = worktreeService, service.isSupported else { return }
        let panel = NSSavePanel()
        panel.message = "Choose a folder for the worktree on branch “\(branch)”."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder:"
        panel.directoryURL = newWorktreeParent()
        panel.nameFieldStringValue = WorktreePresentation.suggestedFolderName(mainPath: service.worktrees.first(where: \.isMain)?.path ?? repository?.workingDirectoryURL()?.path ?? "Repository", branch: branch)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.performWorktree(newBranch ? .addNew(path: path, branch: branch) : .addExisting(path: path, branch: branch))
        }
    }

    @IBAction @objc(checkOutInNewWorktree:)
    dynamic func checkOutInNewWorktree(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? PBGitRef,
              ref.isBranch, let service = worktreeService, service.isSupported,
              repository?.headRef()?.simpleRef() != ref.ref, service.worktree(forBranch: ref.ref) == nil else { return }
        chooseWorktreeFolder(branch: ref.shortName(), newBranch: false)
    }

    @IBAction @objc(addWorktree:)
    dynamic func addWorktree(_: Any?) {
        guard worktreeService?.isSupported == true else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "Add a worktree on a new branch"
        alert.informativeText = "The branch starts at the commit checked out here. The next step chooses the worktree’s folder."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert) { [self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self.chooseWorktreeFolder(branch: name, newBranch: true)
        }
    }

    func offerWorktreeRepairIfNeeded() {
        guard !offeredWorktreeRepair, let service = worktreeService, service.isSupported,
              service.worktrees.contains(where: \.hasBrokenLink), !service.worktrees.contains(where: { $0.value.hasForeignLink }),
              let window, window.isVisible, window.attachedSheet == nil else { return }
        offeredWorktreeRepair = true
        repairWorktreeLinks(nil)
    }

    @IBAction @objc(repairWorktreeLinks:)
    dynamic func repairWorktreeLinks(_: Any?) {
        guard let service = worktreeService, service.isSupported else { return }
        let broken = service.worktrees.filter(\.hasBrokenLink)
        guard !broken.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "This repository was moved, so its worktrees can no longer find it"
        alert.informativeText = "Git can reconnect these worktrees with absolute or relative paths:\n\n" + broken.map { $0.movedPath ?? $0.path }.joined(separator: "\n")
        let absolute = alert.addButton(withTitle: "Repair with Absolute Paths")
        let relative = alert.addButton(withTitle: "Repair with Relative Paths")
        alert.addButton(withTitle: "Skip Repair")
        if WorktreePolicy.preferredRepairStyle(service.worktrees.map { $0.value.linkStyle }) == .relative {
            absolute.keyEquivalent = ""
            relative.keyEquivalent = "\r"
        }
        presentWorktreeSheet(alert) { [self] response in
            let style: WorktreeLinkStyle
            if response == .alertFirstButtonReturn {
                style = .absolute
            } else if response == .alertSecondButtonReturn {
                style = .relative
            } else {
                return
            }
            service.repairLinks(style: style) { [weak self] error in
                if let error {
                    self?.showErrorSheet(error)
                }
            }
        }
    }

    private func performWorktree(_ command: WorktreeCommand) {
        worktreeService?.perform(command) { [weak self] _, error in
            if let error {
                self?.showErrorSheet(error)
            }
        }
    }

    private func presentWorktreeSheet(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            DispatchQueue.main.async { completion(response) }
        }
    }
}
