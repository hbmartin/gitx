import AppKit
import GitXCore

private final class WorktreePresentationContext {
    weak var window: NSWindow?
    weak var repository: PBGitRepository?
    let service: PBRepositoryWorktreeService
    let generation: UInt64

    init(window: NSWindow, repository: PBGitRepository, service: PBRepositoryWorktreeService, generation: UInt64) {
        self.window = window
        self.repository = repository
        self.service = service
        self.generation = generation
    }
}

extension PBGitWindowController {
    private var worktreeService: PBRepositoryWorktreeService? {
        repository?.worktreeService
    }

    private func captureWorktreePresentation() -> WorktreePresentationContext? {
        guard isWindowLoaded, let window, window.isVisible, let repository else {
            NSLog("[GitX] Ignored a worktree action without a loaded visible repository window")
            return nil
        }
        let service = repository.worktreeService
        NSLog("[GitX] Captured worktree presentation generation %llu (supported: %@)", worktreePresentationGeneration, service.isSupported ? "yes" : "no")
        return WorktreePresentationContext(window: window, repository: repository, service: service, generation: worktreePresentationGeneration)
    }

    private func isCurrentWorktreePresentation(_ context: WorktreePresentationContext) -> Bool {
        guard isWindowLoaded, let window = context.window, let repository = context.repository,
              self.window === window, self.repository === repository, worktreeService === context.service else { return false }
        return worktreePresentationGeneration == context.generation
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
        guard let context = captureWorktreePresentation(), context.service.isSupported else { return }
        if worktree.hasBrokenLink {
            presentWorktreeRepair(context: context); return
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            let alert = NSAlert()
            alert.messageText = "The worktree folder is unavailable"
            alert.informativeText = "\(worktree.path)\n\nConnect its disk, prune the registration, or locate the folder if it was moved."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Locate Folder…")
            presentWorktreeSheet(alert, context: context) { [weak self] response in
                guard let self, self.isCurrentWorktreePresentation(context), response == .alertSecondButtonReturn else { return }
                self.locate(worktree: worktree, context: context)
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
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation() else { return }
        locate(worktree: worktree, context: context)
    }

    private func locate(worktree: PBGitWorktree, context: WorktreePresentationContext) {
        guard canUseWorktreePreview(context), let window = context.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder the worktree at \(worktree.path) was moved to."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let parent = URL(fileURLWithPath: worktree.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: parent.path) ? parent : newWorktreeParent(context: context)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.canUseWorktreePreview(context), response == .OK, let url = panel.url else { return }
            context.service.prepareRepair(worktree: worktree, movedTo: url.path) { [weak self] preview, error in
                guard let self else {
                    if let preview {
                        context.service.discardRepairPreview(preview)
                    }
                    NSLog("[GitX] Discarded Locate repair consent after its controller was released")
                    return
                }
                self.receiveRepairPreparation(preview, error: error, context: context)
            }
        }
    }

    @IBAction @objc(lockWorktree:)
    dynamic func lockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(),
              WorktreeEligibility(worktree.value, supported: context.service.isSupported).canLock else { return }
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
            self?.performWorktree(.lock(path: worktree.path, reason: field.stringValue), context: context)
        }
    }

    @IBAction @objc(unlockWorktree:)
    dynamic func unlockWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(),
              WorktreeEligibility(worktree.value, supported: context.service.isSupported).canUnlock else { return }
        performWorktree(.unlock(path: worktree.path), context: context)
    }

    @IBAction @objc(removeWorktree:)
    dynamic func removeWorktree(_ sender: Any?) {
        guard let worktree = selectedWorktree(sender), let context = captureWorktreePresentation(),
              WorktreeEligibility(worktree.value, supported: context.service.isSupported).canRemove else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree at \(worktree.path)?"
        alert.informativeText = "Its folder is deleted." + (worktree.branchRefName.map { " The branch “\($0.dropFirst(11))” is kept." } ?? "")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context), response == .alertFirstButtonReturn else { return }
            context.service.perform(.remove(path: worktree.path, force: false)) { [weak self] _, error in
                guard let error else { return }
                guard let self else {
                    NSLog("[GitX] Discarded a Remove error after its controller was released")
                    return
                }
                guard self.isCurrentWorktreePresentation(context), !WorktreePresentationPolicy.isExpectedCancellation(error) else {
                    self.showWorktreeError(error, context: context)
                    return
                }
                let reason = error.localizedFailureReason ?? error.localizedDescription
                guard WorktreePolicy.offersForcedRemoval(gitMessage: reason) else { self.showWorktreeError(error, context: context); return }
                let force = NSAlert()
                force.messageText = "Git did not remove the worktree"
                force.informativeText = "\(reason)\n\nRemove Anyway deletes the folder and any uncommitted work in it."
                force.addButton(withTitle: "Remove Anyway").hasDestructiveAction = true
                force.addButton(withTitle: "Cancel")
                self.presentWorktreeSheet(force, context: context) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.performWorktree(.remove(path: worktree.path, force: true), context: context)
                }
            }
        }
    }

    @IBAction @objc(pruneWorktrees:)
    dynamic func pruneWorktrees(_: Any?) {
        guard let context = captureWorktreePresentation(), let window = context.window, window.attachedSheet == nil,
              context.service.isSupported else { return }
        context.service.preparePrunePreview { [weak self] preview, error in
            guard let self, self.canUseWorktreePreview(context) else {
                if let preview {
                    context.service.discardPrunePreview(preview)
                }
                NSLog("[GitX] Discarded prune preparation after its visible presentation ended")
                return
            }
            if let error {
                if let preview {
                    context.service.discardPrunePreview(preview)
                }
                self.showWorktreeError(error, context: context)
                return
            }
            guard let preview else { return }
            self.presentPrunePreview(preview, context: context, changed: false)
        }
    }

    private func canUseWorktreePreview(_ context: WorktreePresentationContext) -> Bool {
        isCurrentWorktreePresentation(context) && context.window?.isVisible == true && context.service.isSupported
    }

    private func presentPrunePreview(_ preview: PBWorktreePrunePreview, context: WorktreePresentationContext, changed: Bool) {
        guard canUseWorktreePreview(context), let window = context.window, window.attachedSheet == nil else {
            context.service.discardPrunePreview(preview)
            NSLog("[GitX] Discarded prune consent without an available presentation")
            return
        }
        let alert = NSAlert()
        switch WorktreePresentationPolicy.prune(report: preview.report, hasMovedWorktrees: preview.hasMovedWorktrees) {
        case .repair:
            context.service.discardPrunePreview(preview)
            presentWorktreeRepair(context: context)
            return
        case .empty:
            context.service.discardPrunePreview(preview)
            alert.messageText = "Nothing to prune"
            alert.informativeText = "Git has no stale worktree registrations to prune."
            alert.addButton(withTitle: "OK")
            presentWorktreeSheet(alert, context: context) { _ in }
            return
        case let .confirmation(report):
            alert.messageText = "Prune these worktrees?"
            alert.informativeText = (changed ? "The worktree state changed. Review this updated list and choose Prune again.\n\n" : "")
                + "Git will forget these worktrees:\n\n\(report)"
        }
        alert.addButton(withTitle: "Prune").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canUseWorktreePreview(context),
                  context.window?.attachedSheet == nil
            else {
                context.service.discardPrunePreview(preview)
                NSLog("[GitX] Discarded unconfirmed prune consent")
                return
            }
            context.service.prune(confirmedPreview: preview) { [weak self] updated, error in
                guard let self, self.canUseWorktreePreview(context) else {
                    if let updated {
                        context.service.discardPrunePreview(updated)
                    }
                    NSLog("[GitX] Discarded renewed prune consent after its visible presentation ended")
                    return
                }
                if let error {
                    if let updated {
                        context.service.discardPrunePreview(updated)
                    }
                    self.showWorktreeError(error, context: context)
                } else if let updated {
                    self.presentPrunePreview(updated, context: context, changed: true)
                }
            }
        }
    }

    private func newWorktreeParent(context: WorktreePresentationContext) -> URL? {
        let path = context.service.worktrees.first(where: \.isMain)?.path ?? context.repository?.workingDirectoryURL()?.path
        return path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    private func chooseWorktreeFolder(branch: String, newBranch: Bool, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context), let window = context.window, context.service.isSupported else { return }
        let panel = NSSavePanel()
        panel.message = "Choose a folder for the worktree on branch “\(branch)”."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder:"
        panel.directoryURL = newWorktreeParent(context: context)
        panel.nameFieldStringValue = WorktreePresentation.suggestedFolderName(mainPath: context.service.worktrees.first(where: \.isMain)?.path ?? context.repository?.workingDirectoryURL()?.path ?? "Repository", branch: branch)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.performWorktree(newBranch ? .addNew(path: path, branch: branch) : .addExisting(path: path, branch: branch), context: context)
        }
    }

    @IBAction @objc(checkOutInNewWorktree:)
    dynamic func checkOutInNewWorktree(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? PBGitRef, ref.isBranch,
              let context = captureWorktreePresentation(), context.service.isSupported,
              context.repository?.headRef()?.simpleRef() != ref.ref, context.service.worktree(forBranch: ref.ref) == nil else { return }
        chooseWorktreeFolder(branch: ref.shortName(), newBranch: false, context: context)
    }

    @IBAction @objc(addWorktree:)
    dynamic func addWorktree(_: Any?) {
        guard let context = captureWorktreePresentation(), context.service.isSupported else { return }
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
            self.chooseWorktreeFolder(branch: name, newBranch: true, context: context)
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
        guard let context = captureWorktreePresentation(), context.service.isSupported else { return }
        presentWorktreeRepair(context: context)
    }

    private func presentWorktreeRepair(context: WorktreePresentationContext) {
        guard canUseWorktreePreview(context) else { return }
        let service = context.service
        let manualPaths = WorktreePolicy.manualRepairPaths(service.worktrees.map(\.value))
        let broken = service.worktrees.filter(\.hasBrokenLink)
        switch WorktreePresentationPolicy.repairOffer(hasManualRepairPaths: !manualPaths.isEmpty, hasBrokenLinks: !broken.isEmpty) {
        case .manualGuidance:
            showWorktreeError(RepositoryServiceError.make(
                description: "A moved worktree needs manual link repair",
                failureReason: "Its .git link cannot be replaced safely. Restore a regular Git link file before repairing or pruning:\n\n" + manualPaths.joined(separator: "\n")
            ), context: context)
            return
        case .none:
            NSLog("[GitX] Repair discovery found no broken worktree links")
            return
        case .chooseStyle:
            break
        }
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
            guard self.canUseWorktreePreview(context) else { return }
            service.prepareRepairLinks(style: style) { [weak self] preview, error in
                guard let self else {
                    if let preview {
                        context.service.discardRepairPreview(preview)
                    }
                    NSLog("[GitX] Discarded repository repair consent after its controller was released")
                    return
                }
                self.receiveRepairPreparation(preview, error: error, context: context)
            }
        }
    }

    private func receiveRepairPreparation(_ preview: PBWorktreeRepairPreview?, error: Error?, context: WorktreePresentationContext) {
        guard canUseWorktreePreview(context) else {
            if let preview {
                context.service.discardRepairPreview(preview)
            }
            NSLog("[GitX] Discarded repair preparation after its visible presentation ended")
            return
        }
        if let error {
            if let preview {
                context.service.discardRepairPreview(preview)
            }
            showWorktreeError(error, context: context)
            return
        }
        guard let preview else {
            NSLog("[GitX] Repair preparation returned no pending consent")
            return
        }
        presentRepairPreview(preview, context: context, changed: false)
    }

    private func presentRepairPreview(_ preview: PBWorktreeRepairPreview, context: WorktreePresentationContext, changed: Bool) {
        guard canUseWorktreePreview(context), let window = context.window, window.attachedSheet == nil else {
            context.service.discardRepairPreview(preview)
            NSLog("[GitX] Discarded repair consent without an available presentation")
            return
        }
        let presentation = WorktreePresentationPolicy.repair(requiresReclaim: preview.requiresReclaim, changed: changed)
        if case .perform = presentation {
            performRepair(preview, context: context)
            return
        }
        let reclaim = preview.requiresReclaim
        let actionTitle = reclaim ? "Reclaim" : "Repair"
        let alert = NSAlert()
        alert.messageText = reclaim ? "Reclaim these worktree folders?" : "Repair these worktree links?"
        let changedMessage = changed ? "The worktree state changed. Review this updated list and choose \(actionTitle) again.\n\n" : ""
        if reclaim {
            alert.informativeText = changedMessage
                + "The .git links in these folders no longer prove their registration ownership:\n\n"
                + preview.reclaimPaths.joined(separator: "\n")
                + "\n\nReclaim replaces those links to reconnect the folders to this repository. Git will repair these worktree folders:\n\n"
                + preview.paths.joined(separator: "\n")
        } else {
            alert.informativeText = changedMessage + "Git will repair links for these worktree folders:\n\n" + preview.paths.joined(separator: "\n")
        }
        let action = alert.addButton(withTitle: actionTitle)
        action.hasDestructiveAction = reclaim
        action.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        NSLog("[GitX] Presented %@ consent for %ld worktree folders (renewed: %@)", actionTitle, preview.paths.count, changed ? "yes" : "no")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canUseWorktreePreview(context),
                  context.window?.attachedSheet == nil
            else {
                context.service.discardRepairPreview(preview)
                NSLog("[GitX] Discarded unconfirmed worktree repair consent")
                return
            }
            self.performRepair(preview, context: context)
        }
    }

    private func performRepair(_ preview: PBWorktreeRepairPreview, context: WorktreePresentationContext) {
        guard canUseWorktreePreview(context) else {
            context.service.discardRepairPreview(preview)
            NSLog("[GitX] Discarded worktree repair consent before admission")
            return
        }
        context.service.repair(confirmedPreview: preview) { [weak self] updated, error in
            guard let self, self.canUseWorktreePreview(context) else {
                if let updated {
                    context.service.discardRepairPreview(updated)
                }
                NSLog("[GitX] Discarded renewed repair consent after its visible presentation ended")
                return
            }
            if let error {
                if let updated {
                    context.service.discardRepairPreview(updated)
                }
                self.showWorktreeError(error, context: context)
            } else if let updated {
                self.presentRepairPreview(updated, context: context, changed: true)
            }
        }
    }

    private func performWorktree(_ command: WorktreeCommand, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context) else {
            NSLog("[GitX] Discarded a deferred worktree action after its presentation owner changed")
            return
        }
        context.service.perform(command) { [weak self] _, error in
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
