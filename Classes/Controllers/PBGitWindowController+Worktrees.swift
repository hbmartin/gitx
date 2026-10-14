import AppKit
import GitXCore

/// Identity is a value; weak owners below prove those identities still exist.
private struct WorktreePresentationIdentity: Equatable {
    let generation: UInt64
    let window: ObjectIdentifier
    let repository: ObjectIdentifier
    let service: ObjectIdentifier
}

private enum WorktreePresentationPolicy {
    static func isExpectedCancellation(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

private final class WorktreePresentationContext {
    weak var window: NSWindow?
    weak var repository: PBGitRepository?
    weak var service: PBRepositoryWorktreeService?
    let identity: WorktreePresentationIdentity

    init(window: NSWindow, repository: PBGitRepository, service: PBRepositoryWorktreeService, generation: UInt64) {
        self.window = window
        self.repository = repository
        self.service = service
        identity = WorktreePresentationIdentity(generation: generation, window: ObjectIdentifier(window), repository: ObjectIdentifier(repository), service: ObjectIdentifier(service))
    }
}

extension PBGitWindowController {
    private var worktreeService: PBRepositoryWorktreeService? {
        repository?.worktreeService
    }

    private func captureWorktreePresentation() -> WorktreePresentationContext? {
        guard isWindowLoaded, let window, window.isVisible, let repository else { return nil }
        let service = repository.worktreeService
        return WorktreePresentationContext(window: window, repository: repository, service: service, generation: worktreePresentationGeneration)
    }

    private func isCurrentWorktreePresentation(_ context: WorktreePresentationContext) -> Bool {
        guard isWindowLoaded, let window = context.window, let repository = context.repository, let service = context.service,
              self.window === window, self.repository === repository, worktreeService === service else { return false }
        let current = WorktreePresentationIdentity(generation: worktreePresentationGeneration, window: ObjectIdentifier(window), repository: ObjectIdentifier(repository), service: ObjectIdentifier(service))
        return current == context.identity
    }

    private func showWorktreeError(_ error: Error, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context) else {
            NSLog("[GitX] Discarded a worktree error after its presentation owner changed")
            return
        }
        guard !WorktreePresentationPolicy.isExpectedCancellation(error as NSError) else {
            NSLog("[GitX] Suppressed expected worktree cancellation")
            return
        }
        showErrorSheet(error)
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
        guard let context = captureWorktreePresentation(), let service = context.service, service.isSupported else { return }
        if worktree.hasBrokenLink {
            presentWorktreeRepair(service: service, context: context); return
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            let alert = NSAlert()
            alert.messageText = "The worktree folder is unavailable"
            alert.informativeText = "\(worktree.path)\n\nConnect its disk, prune the registration, or locate the folder if it was moved."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Locate Folder…")
            presentWorktreeSheet(alert, context: context) { [weak self] response in
                guard let self, self.isCurrentWorktreePresentation(context), response == .alertSecondButtonReturn else { return }
                self.locate(worktree: worktree, service: service, context: context)
            }
            return
        }
        RepositoryOpenCoordinator.shared.open(urls: [URL(fileURLWithPath: worktree.path)], sourceWindow: context.window) { [weak self] _, errors in
            for error in errors {
                self?.showWorktreeError(error, context: context)
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
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(), let service = context.service else { return }
        locate(worktree: worktree, service: service, context: context)
    }

    private func locate(worktree: PBGitWorktree, service: PBRepositoryWorktreeService, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context), let window = context.window, service.isSupported else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder the worktree at \(worktree.path) was moved to."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let parent = URL(fileURLWithPath: worktree.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: parent.path) ? parent : newWorktreeParent(service: service, context: context)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context), response == .OK, let url = panel.url else { return }
            service.repair(worktree: worktree, movedTo: url.path) { [weak self] error in
                if let error {
                    self?.showWorktreeError(error, context: context)
                }
            }
        }
    }

    @IBAction @objc(lockWorktree:)
    dynamic func lockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(), let service = context.service,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canLock else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Reason (optional)"
        let alert = NSAlert()
        alert.messageText = "Lock the worktree at \(worktree.path)?"
        alert.informativeText = "Git will not prune, move or remove a locked worktree, and shows the reason to anyone who tries."
        alert.accessoryView = field
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performWorktree(.lock(path: worktree.path, reason: field.stringValue), service: service, context: context)
        }
    }

    @IBAction @objc(unlockWorktree:)
    dynamic func unlockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(), let service = context.service,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canUnlock else { return }
        performWorktree(.unlock(path: worktree.path), service: service, context: context)
    }

    @IBAction @objc(removeWorktree:)
    dynamic func removeWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(), let service = context.service,
              WorktreeEligibility(worktree.value, supported: service.isSupported).canRemove else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree at \(worktree.path)?"
        alert.informativeText = "Its folder is deleted." + (worktree.branchRefName.map { " The branch “\($0.dropFirst(11))” is kept." } ?? "")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context), response == .alertFirstButtonReturn else { return }
            service.perform(.remove(path: worktree.path, force: false)) { [weak self] _, error in
                guard let self, self.isCurrentWorktreePresentation(context), let error, !WorktreePresentationPolicy.isExpectedCancellation(error) else { return }
                let reason = error.localizedFailureReason ?? error.localizedDescription
                guard WorktreePolicy.offersForcedRemoval(gitMessage: reason) else { self.showWorktreeError(error, context: context); return }
                let force = NSAlert()
                force.messageText = "Git did not remove the worktree"
                force.informativeText = "\(reason)\n\nRemove Anyway deletes the folder and any uncommitted work in it."
                force.addButton(withTitle: "Remove Anyway").hasDestructiveAction = true
                force.addButton(withTitle: "Cancel")
                self.presentWorktreeSheet(force, context: context) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.performWorktree(.remove(path: worktree.path, force: true), service: service, context: context)
                }
            }
        }
    }

    @IBAction @objc(pruneWorktrees:)
    dynamic func pruneWorktrees(_: Any?) {
        guard let context = captureWorktreePresentation(), let window = context.window, window.attachedSheet == nil,
              let service = context.service, service.isSupported else { return }
        service.preparePrunePreview { [weak self] preview, error in
            guard let self, self.canUsePrunePreview(service: service, context: context) else {
                if let preview {
                    service.discardPrunePreview(preview)
                }
                return
            }
            if let error {
                if let preview {
                    service.discardPrunePreview(preview)
                }
                self.showWorktreeError(error, context: context)
                return
            }
            guard let preview else { return }
            self.presentPrunePreview(preview, service: service, context: context, changed: false)
        }
    }

    private func canUsePrunePreview(service: PBRepositoryWorktreeService, context: WorktreePresentationContext) -> Bool {
        isCurrentWorktreePresentation(context) && context.window?.isVisible == true && service.isSupported
    }

    private func presentPrunePreview(_ preview: PBWorktreePrunePreview, service: PBRepositoryWorktreeService, context: WorktreePresentationContext, changed: Bool) {
        guard canUsePrunePreview(service: service, context: context), let window = context.window, window.attachedSheet == nil else {
            service.discardPrunePreview(preview)
            return
        }
        if preview.hasMovedWorktrees {
            service.discardPrunePreview(preview)
            presentWorktreeRepair(service: service, context: context)
            return
        }
        let report = preview.report.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        if report.isEmpty {
            service.discardPrunePreview(preview)
            alert.messageText = "Nothing to prune"
            alert.informativeText = "Git has no stale worktree registrations to prune."
            alert.addButton(withTitle: "OK")
            presentWorktreeSheet(alert, context: context) { _ in }
            return
        }
        alert.messageText = "Prune these worktrees?"
        alert.informativeText = (changed ? "The worktree state changed. Review this updated list and choose Prune again.\n\n" : "")
            + "Git will forget these worktrees:\n\n\(report)"
        alert.addButton(withTitle: "Prune").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canUsePrunePreview(service: service, context: context),
                  context.window?.attachedSheet == nil
            else {
                service.discardPrunePreview(preview)
                return
            }
            service.prune(confirmedPreview: preview) { [weak self] updated, error in
                guard let self, self.canUsePrunePreview(service: service, context: context) else {
                    if let updated {
                        service.discardPrunePreview(updated)
                    }
                    return
                }
                if let error {
                    if let updated {
                        service.discardPrunePreview(updated)
                    }
                    self.showWorktreeError(error, context: context)
                } else if let updated {
                    self.presentPrunePreview(updated, service: service, context: context, changed: true)
                }
            }
        }
    }

    private func newWorktreeParent(service: PBRepositoryWorktreeService, context: WorktreePresentationContext) -> URL? {
        let path = service.worktrees.first(where: \.isMain)?.path ?? context.repository?.workingDirectoryURL()?.path
        return path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    private func chooseWorktreeFolder(branch: String, newBranch: Bool, service: PBRepositoryWorktreeService, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context), let window = context.window, service.isSupported else { return }
        let panel = NSSavePanel()
        panel.message = "Choose a folder for the worktree on branch “\(branch)”."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder:"
        panel.directoryURL = newWorktreeParent(service: service, context: context)
        panel.nameFieldStringValue = WorktreePresentation.suggestedFolderName(mainPath: service.worktrees.first(where: \.isMain)?.path ?? context.repository?.workingDirectoryURL()?.path ?? "Repository", branch: branch)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.performWorktree(newBranch ? .addNew(path: path, branch: branch) : .addExisting(path: path, branch: branch), service: service, context: context)
        }
    }

    @IBAction @objc(checkOutInNewWorktree:)
    dynamic func checkOutInNewWorktree(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? PBGitRef, ref.isBranch,
              let context = captureWorktreePresentation(), let service = context.service, service.isSupported,
              repository?.headRef()?.simpleRef() != ref.ref, service.worktree(forBranch: ref.ref) == nil else { return }
        chooseWorktreeFolder(branch: ref.shortName(), newBranch: false, service: service, context: context)
    }

    @IBAction @objc(addWorktree:)
    dynamic func addWorktree(_: Any?) {
        guard let context = captureWorktreePresentation(), let service = context.service, service.isSupported else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "Add a worktree on a new branch"
        alert.informativeText = "The branch starts at the commit checked out here. The next step chooses the worktree’s folder."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context) else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self.chooseWorktreeFolder(branch: name, newBranch: true, service: service, context: context)
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
        guard let context = captureWorktreePresentation(), let service = context.service, service.isSupported else { return }
        presentWorktreeRepair(service: service, context: context)
    }

    private func presentWorktreeRepair(service: PBRepositoryWorktreeService, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context), service.isSupported else { return }
        let manualPaths = WorktreePolicy.manualRepairPaths(service.worktrees.map(\.value))
        guard manualPaths.isEmpty else {
            showWorktreeError(RepositoryServiceError.make(
                description: "A moved worktree needs manual link repair",
                failureReason: "Its .git link cannot be replaced safely. Restore a regular Git link file before repairing or pruning:\n\n" + manualPaths.joined(separator: "\n")
            ), context: context)
            return
        }
        let broken = service.worktrees.filter(\.hasBrokenLink)
        guard !broken.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some worktrees have broken repository links"
        alert.informativeText = "Git can reconnect these worktrees with absolute or relative paths:\n\n" + broken.map { $0.movedPath ?? $0.path }.joined(separator: "\n")
        let absolute = alert.addButton(withTitle: "Repair with Absolute Paths")
        let relative = alert.addButton(withTitle: "Repair with Relative Paths")
        alert.addButton(withTitle: "Skip Repair")
        if WorktreePolicy.preferredRepairStyle(service.worktrees.map { $0.value.linkStyle }) == .relative {
            absolute.keyEquivalent = ""
            relative.keyEquivalent = "\r"
        }
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context) else { return }
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
                    self?.showWorktreeError(error, context: context)
                }
            }
        }
    }

    private func performWorktree(_ command: WorktreeCommand, service: PBRepositoryWorktreeService, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context) else {
            NSLog("[GitX] Discarded a deferred worktree action after its presentation owner changed")
            return
        }
        service.perform(command) { [weak self] _, error in
            if let error {
                self?.showWorktreeError(error, context: context)
            }
        }
    }

    private func presentWorktreeSheet(_ alert: NSAlert, context: WorktreePresentationContext, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard isCurrentWorktreePresentation(context), let window = context.window else { return }
        alert.beginSheetModal(for: window) { response in
            // Each continuation validates its original context; prune also discards stale consent.
            DispatchQueue.main.async { completion(response) }
        }
    }
}
