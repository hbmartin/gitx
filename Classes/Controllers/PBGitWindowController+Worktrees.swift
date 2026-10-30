import AppKit
import GitXCore

private final class WorktreePresentationContext {
    weak var window: NSWindow?
    weak var repository: PBGitRepository?
    let service: PBRepositoryWorktreeService
    let generation: UInt64
    let operationOwner: NSObject

    init(window: NSWindow, repository: PBGitRepository, service: PBRepositoryWorktreeService, generation: UInt64, operationOwner: NSObject) {
        self.window = window
        self.repository = repository
        self.service = service
        self.generation = generation
        self.operationOwner = operationOwner
    }

    @MainActor
    func discardPrunePreview(_ preview: PBWorktreePrunePreview?) {
        guard let preview else { return }
        service.discardPrunePreview(preview)
    }

    @MainActor
    func discardRepairPreview(_ preview: PBWorktreeRepairPreview?) {
        guard let preview else { return }
        service.discardRepairPreview(preview)
    }
}

/// A consumed preview cannot be refreshed again. Its terminal error survives every presentation wait.
private enum WorktreePreviewPreparation<Preview> {
    case preview(Preview)
    case consumed
    case failed(Error)

    var preview: Preview? {
        if case let .preview(value) = self {
            return value
        }
        return nil
    }

    var error: Error? {
        if case let .failed(error) = self {
            return error
        }
        return nil
    }

    mutating func consume() -> Preview? {
        guard let value = preview else { return nil }
        self = .consumed
        return value
    }
}

/// Participates in the alert's key-equivalent traversal without changing its default button.
private final class WorktreeConsentKeyView: NSView {
    weak var cancelButton: NSButton?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}",
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let cancelButton, let window, let parent = window.sheetParent, window.isVisible,
              parent.attachedSheet === window else { return super.performKeyEquivalent(with: event) }
        let source = event.window ?? NSApp.keyWindow
        guard source === window || source === parent else { return super.performKeyEquivalent(with: event) }
        NSLog("[GitX] Cancelled worktree consent with Escape")
        cancelButton.performClick(nil)
        return true
    }
}

@MainActor
final class WorktreePresentationQueue {
    struct Prepared {
        let finishesWhenSheetEnds: Bool
        let present: @MainActor (@escaping @MainActor () -> Void) -> Void
        let discard: @MainActor () -> Void
    }

    private final class Item {
        let identifier = UUID()
        weak var window: NSWindow?
        let isCurrent: @MainActor () -> Bool
        let prepare: @MainActor (Bool, @escaping @MainActor (Prepared?) -> Void) -> Void
        let discard: @MainActor () -> Void
        var prepared: Prepared?
        var isPreparing = false
        var isPresenting = false
        var needsRefresh: Bool
        var waiting = false
        var waitGeneration: UInt = 0
        weak var presentedSheet: NSWindow?

        init(window: NSWindow, isCurrent: @escaping @MainActor () -> Bool,
             deferred: Bool, prepare: @escaping @MainActor (Bool, @escaping @MainActor (Prepared?) -> Void) -> Void,
             discard: @escaping @MainActor () -> Void)
        {
            self.window = window
            self.isCurrent = isCurrent
            needsRefresh = deferred
            self.prepare = prepare
            self.discard = discard
        }

        func wait() {
            if !waiting {
                waitGeneration &+= 1
            }
            waiting = true
            needsRefresh = true
        }

        func revoke() {
            prepared?.discard()
            discard()
            if let window, let presentedSheet, window.attachedSheet === presentedSheet {
                window.endSheet(presentedSheet, returnCode: .cancel)
            }
        }
    }

    private var pending: [Item] = []
    private var active: Item?
    private var observers: [NSObjectProtocol] = []
    private var flushScheduled = false

    var hasPendingPresentations: Bool {
        active != nil || !pending.isEmpty
    }

    isolated deinit { invalidate() }

    func enqueue(window: NSWindow, isCurrent: @escaping @MainActor () -> Bool,
                 prepare: @escaping @MainActor (Bool, @escaping @MainActor (Prepared?) -> Void) -> Void,
                 discard: @escaping @MainActor () -> Void = {})
    {
        let deferred = hasPendingPresentations
        pending.append(Item(window: window, isCurrent: isCurrent, deferred: deferred, prepare: prepare, discard: discard))
        observe(window)
        NSLog("[GitX] Queued %ld worktree presentation(s) for their original owner", pending.count)
        scheduleFlush()
    }

    func invalidate() {
        let revoked = pending + (active.map { [$0] } ?? [])
        pending.removeAll()
        active = nil
        removeObservers()
        revoked.forEach { $0.revoke() }
        NSLog("[GitX] Revoked %ld worktree presentation(s) after an owner change", revoked.count)
    }

    private func observe(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.willBeginSheetNotification]
        {
            let blocked = [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willBeginSheetNotification].contains(name)
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // swift6-safety-justification: The observer explicitly delivers on the main queue.
                MainActor.assumeIsolated { self?.presentationChanged(wasBlocked: blocked) }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didUnhideNotification] {
            let blocked = name == NSApplication.didResignActiveNotification
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                // swift6-safety-justification: The observer explicitly delivers on the main queue.
                MainActor.assumeIsolated { self?.presentationChanged(wasBlocked: blocked) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            // swift6-safety-justification: The observer explicitly delivers on the main queue.
            MainActor.assumeIsolated { self?.sheetEnded() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // swift6-safety-justification: The observer explicitly delivers on the main queue.
            MainActor.assumeIsolated { self?.invalidate() }
        })
    }

    private func presentationChanged(wasBlocked: Bool) {
        // Preserve even a brief block that ends before the coalesced flush runs.
        if wasBlocked {
            if let active, !active.isPresenting {
                active.wait()
            } else if active == nil {
                pending.first?.wait()
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            flushScheduled = false
            flush()
        }
    }

    private func available(_ window: NSWindow) -> Bool {
        WorktreePresentationPolicy.canPresent(isApplicationActive: NSApp.isActive,
                                              isWindowVisible: window.isVisible, isWindowKey: window.isKeyWindow,
                                              isMiniaturized: window.isMiniaturized, hasAttachedSheet: window.attachedSheet != nil)
    }

    private func flush() {
        if let active {
            guard active.isCurrent(), let window = active.window else { complete(active.identifier); return }
            guard !active.isPresenting else { return }
            guard available(window) else { active.wait(); return }
            guard !active.isPreparing else { return }
            if active.prepared == nil || active.needsRefresh {
                prepare(active)
                return
            }
            guard let prepared = active.prepared else { return }
            active.isPresenting = true
            prepared.present { [weak self] in self?.complete(active.identifier) }
            if self.active === active {
                active.presentedSheet = window.attachedSheet
                if prepared.finishesWhenSheetEnds, window.attachedSheet == nil {
                    complete(active.identifier)
                }
            }
            return
        }
        while let next = pending.first {
            guard next.isCurrent(), let window = next.window else {
                pending.removeFirst().revoke()
                continue
            }
            guard available(window) else { next.wait(); return }
            pending.removeFirst()
            active = next
            prepare(next)
            return
        }
        removeObservers()
    }

    private func prepare(_ item: Item) {
        let deferred = item.needsRefresh
        item.needsRefresh = false
        item.waiting = false
        item.isPreparing = true
        let generation = item.waitGeneration
        let retired = item.prepared
        item.prepared = nil
        item.prepare(deferred) { [weak self] prepared in
            retired?.discard()
            guard let self, self.active === item else { prepared?.discard(); return }
            item.isPreparing = false
            guard item.isCurrent(), let prepared else { prepared?.discard(); complete(item.identifier); return }
            item.prepared = prepared
            item.needsRefresh = item.needsRefresh || generation != item.waitGeneration
            scheduleFlush()
        }
    }

    private func sheetEnded() {
        if let active, active.isPresenting, active.prepared?.finishesWhenSheetEnds == true {
            let identifier = active.identifier
            DispatchQueue.main.async { [weak self] in self?.complete(identifier) }
        } else {
            scheduleFlush()
        }
    }

    private func complete(_ identifier: UUID) {
        guard let active, active.identifier == identifier else { return }
        self.active = nil
        active.revoke()
        scheduleFlush()
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

#if DEBUG
    @objc(PBWorktreePreparedPresentationTestValue)
    @MainActor
    final class WorktreePreparedPresentationTestValue: NSObject {
        let value: WorktreePresentationQueue.Prepared

        @objc(initWithFinishesWhenSheetEnds:present:discard:)
        init(finishesWhenSheetEnds: Bool, present: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
             discard: @escaping @MainActor () -> Void)
        {
            value = .init(finishesWhenSheetEnds: finishesWhenSheetEnds, present: present, discard: discard)
        }
    }

    /// The test target references this class through its Objective-C bridging header.
    @objc(PBWorktreePresentationQueueTestHarness)
    @MainActor
    // swiftlint:disable:next unused_declaration
    final class WorktreePresentationQueueTestHarness: NSObject {
        private let queue = WorktreePresentationQueue()

        @objc var hasPendingPresentations: Bool {
            queue.hasPendingPresentations
        }

        /// This selector is used through the test target's Objective-C bridging header.
        @objc(enqueueWindow:ownerIsCurrent:prepare:discard:)
        // swiftlint:disable:next unused_declaration
        func enqueue(window: NSWindow, ownerIsCurrent: @escaping @MainActor () -> Bool,
                     prepare: @escaping @MainActor (@escaping @MainActor (WorktreePreparedPresentationTestValue?) -> Void) -> Void,
                     discard: @escaping @MainActor () -> Void)
        {
            queue.enqueue(window: window, isCurrent: ownerIsCurrent, prepare: { _, ready in prepare { ready($0?.value) } }, discard: discard)
        }

        @objc func invalidate() {
            queue.invalidate()
        }
    }
#endif

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
        guard let operationOwner = worktreeOperationOwner(for: service) else { return nil }
        NSLog("[GitX] Captured worktree presentation generation %llu (supported: %@)", worktreePresentationGeneration, service.isSupported ? "yes" : "no")
        return WorktreePresentationContext(window: window, repository: repository, service: service, generation: worktreePresentationGeneration, operationOwner: operationOwner)
    }

    private func isCurrentWorktreePresentation(_ context: WorktreePresentationContext) -> Bool {
        guard isWindowLoaded, let window = context.window, let repository = context.repository,
              self.window === window, self.repository === repository, worktreeService === context.service else { return false }
        return worktreePresentationGeneration == context.generation
    }

    private func presentationQueue() -> WorktreePresentationQueue {
        if let worktreePresentationQueue {
            return worktreePresentationQueue
        }
        let queue = WorktreePresentationQueue()
        worktreePresentationQueue = queue
        return queue
    }

    private func errorPresentation(_ error: Error, context: WorktreePresentationContext) -> WorktreePresentationQueue.Prepared? {
        guard isCurrentWorktreePresentation(context), !WorktreePresentationPolicy.isExpectedCancellation(error as NSError) else { return nil }
        return WorktreePresentationQueue.Prepared(finishesWhenSheetEnds: true, present: { [weak self] done in
            guard let self, isCurrentWorktreePresentation(context) else { done(); return }
            showErrorSheet(error)
        }, discard: {})
    }

    private func showWorktreeError(_ error: Error, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context), let window = context.window else {
            NSLog("[GitX] Discarded a worktree error after its presentation owner changed")
            return
        }
        guard !WorktreePresentationPolicy.isExpectedCancellation(error as NSError) else { return }
        presentationQueue().enqueue(window: window, isCurrent: { [weak self] in
            self?.isCurrentWorktreePresentation(context) == true
        }, prepare: { [weak self] _, ready in
            ready(self?.errorPresentation(error, context: context))
        })
    }

    private func enqueueWorktreeAlert(_ alert: NSAlert, context: WorktreePresentationContext,
                                      completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void)
    {
        guard isCurrentWorktreePresentation(context), let window = context.window else { return }
        presentationQueue().enqueue(window: window, isCurrent: { [weak self] in
            self?.isCurrentWorktreePresentation(context) == true
        }, prepare: { [weak self] _, ready in
            guard let self, isCurrentWorktreePresentation(context) else { ready(nil); return }
            ready(WorktreePresentationQueue.Prepared(finishesWhenSheetEnds: false, present: { [weak self] done in
                guard let self, isCurrentWorktreePresentation(context) else { done(); return }
                presentWorktreeSheet(alert, context: context) { response in
                    defer { done() }
                    completion(response)
                }
            }, discard: {}))
        })
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

    @IBAction @objc(refreshWorktrees:)
    dynamic func refreshWorktrees(_: Any?) {
        worktreeService?.refresh()
        NSLog("[GitX] Explicitly refreshing worktree inventory")
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
            guard let self, self.isCurrentWorktreePresentation(context), response == .OK, let url = panel.url else { return }
            context.service.prepareRepair(worktree: worktree, movedTo: url.path, owner: context.operationOwner) { [weak self] preview, error in
                guard let self, self.isCurrentWorktreePresentation(context) else {
                    context.discardRepairPreview(preview)
                    return
                }
                if let error {
                    self.showWorktreeError(error, context: context)
                } else if let preview {
                    self.presentRepairPreview(preview, context: context, changed: false)
                }
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
            context.service.perform(.remove(path: worktree.path, force: false), expectedWorktree: worktree.value, owner: context.operationOwner) { [weak self] _, error in
                guard let error else { return }
                guard let self else {
                    NSLog("[GitX] Discarded a Remove error after its controller was released")
                    return
                }
                guard self.isCurrentWorktreePresentation(context) else {
                    NSLog("[GitX] Discarded a Remove error after its presentation owner changed")
                    return
                }
                guard !WorktreePresentationPolicy.isExpectedCancellation(error) else {
                    NSLog("[GitX] Suppressed expected worktree cancellation")
                    return
                }
                let reason = error.localizedFailureReason ?? error.localizedDescription
                guard WorktreePolicy.offersForcedRemoval(gitMessage: reason) else { self.showWorktreeError(error, context: context); return }
                let force = NSAlert()
                force.messageText = "Git did not remove the worktree"
                force.informativeText = "\(reason)\n\nRemove Anyway deletes the folder and any uncommitted work in it."
                force.addButton(withTitle: "Remove Anyway").hasDestructiveAction = true
                force.addButton(withTitle: "Cancel")
                self.enqueueWorktreeAlert(force, context: context) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.performWorktree(.remove(path: worktree.path, force: true), expectedWorktree: worktree.value, context: context)
                }
            }
        }
    }

    @IBAction @objc(pruneWorktrees:)
    dynamic func pruneWorktrees(_: Any?) {
        guard let context = captureWorktreePresentation(), context.service.isSupported else { return }
        context.service.preparePrunePreview(owner: context.operationOwner) { [weak self] preview, error in
            guard let self, self.canReceiveWorktreeResult(context) else {
                context.discardPrunePreview(preview)
                NSLog("[GitX] Discarded prune preparation after its presentation owner changed")
                return
            }
            if let error {
                context.discardPrunePreview(preview)
                self.showWorktreeError(error, context: context)
                return
            }
            guard let preview else { return }
            self.presentPrunePreview(preview, context: context, changed: false)
        }
    }

    private func canReceiveWorktreeResult(_ context: WorktreePresentationContext) -> Bool {
        isCurrentWorktreePresentation(context)
    }

    private func canUseWorktreePreview(_ context: WorktreePresentationContext) -> Bool {
        isCurrentWorktreePresentation(context) && context.window?.isVisible == true && context.service.isSupported
    }

    private func presentPrunePreview(_ preview: PBWorktreePrunePreview, context: WorktreePresentationContext, changed: Bool) {
        guard isCurrentWorktreePresentation(context), let window = context.window else {
            context.discardPrunePreview(preview)
            return
        }
        var preparation = WorktreePreviewPreparation.preview(preview)
        var updatedBeforeDisplay = false
        presentationQueue().enqueue(window: window, isCurrent: { [weak self] in
            self?.isCurrentWorktreePresentation(context) == true
        }, prepare: { [weak self] deferred, ready in
            guard let self, isCurrentWorktreePresentation(context) else { ready(nil); return }
            if let error = preparation.error {
                ready(errorPresentation(error, context: context)); return
            }
            let prepared: @MainActor (PBWorktreePrunePreview) -> Void = { [weak self] updated in
                guard let self, isCurrentWorktreePresentation(context) else {
                    context.discardPrunePreview(updated); ready(nil); return
                }
                preparation = .preview(updated)
                ready(.init(finishesWhenSheetEnds: false, present: { [weak self] done in
                    guard let self, isCurrentWorktreePresentation(context) else { done(); return }
                    showPruneConsent(updated, context: context, changed: changed, updatedBeforeDisplay: updatedBeforeDisplay, finished: done)
                }, discard: { context.discardPrunePreview(updated) }))
            }
            guard let current = preparation.preview else { ready(nil); return }
            guard deferred else { prepared(current); return }
            _ = preparation.consume()
            context.service.refreshPrunePreview(current, ownerIsCurrent: { [weak self] in
                self?.isCurrentWorktreePresentation(context) == true
            }, owner: context.operationOwner) { [weak self] updated, listChanged, error in
                updatedBeforeDisplay = updatedBeforeDisplay || listChanged
                if let error {
                    preparation = .failed(error)
                    ready(self?.errorPresentation(error, context: context))
                } else if let updated {
                    prepared(updated)
                } else {
                    ready(nil)
                }
            }
        }, discard: { context.discardPrunePreview(preparation.preview) })
    }

    private func showPruneConsent(_ preview: PBWorktreePrunePreview, context: WorktreePresentationContext,
                                  changed: Bool, updatedBeforeDisplay: Bool, finished: @escaping @MainActor () -> Void)
    {
        guard isCurrentWorktreePresentation(context) else { finished(); return }
        let alert = NSAlert()
        switch WorktreePresentationPolicy.prune(report: preview.report, hasMovedWorktrees: preview.hasMovedWorktrees) {
        case .repair:
            context.service.discardPrunePreview(preview)
            finished()
            presentWorktreeRepair(context: context)
            return
        case .empty:
            context.service.discardPrunePreview(preview)
            alert.messageText = "Nothing to prune"
            alert.informativeText = "Git has no stale worktree registrations to prune."
            alert.addButton(withTitle: "OK")
            presentWorktreeSheet(alert, context: context) { _ in finished() }
            return
        case let .confirmation(report):
            alert.messageText = "Prune these worktrees?"
            alert.informativeText = WorktreePresentationPolicy.consentUpdateMessage(action: "Prune", previouslyConfirmed: changed, updated: updatedBeforeDisplay)
                + "Git will forget these worktrees:\n\n\(report)"
        }
        alert.addButton(withTitle: "Prune").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            defer { finished() }
            guard response == .alertFirstButtonReturn, let self, self.isCurrentWorktreePresentation(context)
            else {
                context.service.discardPrunePreview(preview)
                NSLog("[GitX] Discarded unconfirmed prune consent")
                return
            }
            context.service.confirmPrune(preview, ownerIsCurrent: { [weak self] in
                self?.isCurrentWorktreePresentation(context) == true
            }, owner: context.operationOwner) { [weak self] updated, error in
                guard let self, self.canReceiveWorktreeResult(context) else {
                    context.discardPrunePreview(updated)
                    NSLog("[GitX] Discarded renewed prune consent after its presentation owner changed")
                    return
                }
                if let error {
                    context.discardPrunePreview(updated)
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
              let window, window.isVisible, window.attachedSheet == nil,
              worktreePresentationQueue?.hasPendingPresentations != true else { return }
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
        alert.informativeText = "Choose how Git stores worktree links. You will review the exact folders before repairing them."
        let absolute = alert.addButton(withTitle: "Absolute Paths")
        let relative = alert.addButton(withTitle: "Relative Paths")
        alert.addButton(withTitle: "Skip Repair")
        if WorktreePolicy.preferredRepairStyle(service.worktrees.map { $0.value.linkStyle }) == .relative {
            absolute.keyEquivalent = ""
            relative.keyEquivalent = "\r"
        }
        enqueueWorktreeAlert(alert, context: context) { [weak self] response in
            guard let self, self.isCurrentWorktreePresentation(context) else { return }
            let style: WorktreeLinkStyle
            if response == .alertFirstButtonReturn {
                style = .absolute
            } else if response == .alertSecondButtonReturn {
                style = .relative
            } else {
                return
            }
            service.prepareRepairLinks(style: style, owner: context.operationOwner) { [weak self] preview, error in
                guard let self, self.canReceiveWorktreeResult(context) else {
                    context.discardRepairPreview(preview)
                    return
                }
                if let error {
                    context.discardRepairPreview(preview)
                    self.showWorktreeError(error, context: context)
                } else if let preview {
                    self.presentRepairPreview(preview, context: context, changed: false)
                }
            }
        }
    }

    private func presentRepairPreview(_ preview: PBWorktreeRepairPreview, context: WorktreePresentationContext, changed: Bool) {
        guard isCurrentWorktreePresentation(context), let window = context.window else {
            context.discardRepairPreview(preview)
            return
        }
        var preparation = WorktreePreviewPreparation.preview(preview)
        var updatedBeforeDisplay = false
        presentationQueue().enqueue(window: window, isCurrent: { [weak self] in
            self?.isCurrentWorktreePresentation(context) == true
        }, prepare: { [weak self] deferred, ready in
            guard let self, isCurrentWorktreePresentation(context) else { ready(nil); return }
            if let error = preparation.error {
                ready(errorPresentation(error, context: context)); return
            }
            let prepared: @MainActor (PBWorktreeRepairPreview) -> Void = { [weak self] updated in
                guard let self, isCurrentWorktreePresentation(context) else {
                    context.discardRepairPreview(updated); ready(nil); return
                }
                preparation = .preview(updated)
                ready(WorktreePresentationQueue.Prepared(finishesWhenSheetEnds: false, present: { [weak self] done in
                    guard let self, isCurrentWorktreePresentation(context) else { done(); return }
                    showRepairConsent(updated, context: context, changed: changed, updatedBeforeDisplay: updatedBeforeDisplay, finished: done)
                }, discard: { context.discardRepairPreview(updated) }))
            }
            guard let current = preparation.preview else { ready(nil); return }
            guard deferred else { prepared(current); return }
            _ = preparation.consume()
            context.service.refreshRepairPreview(current, ownerIsCurrent: { [weak self] in
                self?.isCurrentWorktreePresentation(context) == true
            }, owner: context.operationOwner) { [weak self] result in
                switch result {
                case let .failure(error):
                    preparation = .failed(error)
                    ready(self?.errorPresentation(error, context: context))
                case let .success(review):
                    updatedBeforeDisplay = updatedBeforeDisplay || review.changed
                    prepared(review.preview)
                }
            }
        }, discard: { context.discardRepairPreview(preparation.preview) })
    }

    private func showRepairConsent(_ preview: PBWorktreeRepairPreview, context: WorktreePresentationContext,
                                   changed: Bool, updatedBeforeDisplay: Bool, finished: @escaping @MainActor () -> Void)
    {
        guard isCurrentWorktreePresentation(context) else { finished(); return }
        let reclaim = preview.requiresReclaim
        let actionTitle = reclaim ? "Reclaim" : "Repair"
        let alert = NSAlert()
        alert.messageText = reclaim ? "Reclaim these worktree folders?" : "Repair these worktree links?"
        let changedMessage = WorktreePresentationPolicy.consentUpdateMessage(action: actionTitle, previouslyConfirmed: changed, updated: updatedBeforeDisplay)
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
        let keyView = WorktreeConsentKeyView(frame: .zero)
        keyView.cancelButton = cancel
        keyView.setAccessibilityElement(false)
        alert.accessoryView = keyView
        cancel.keyEquivalent = "\r"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        NSLog("[GitX] Presented %@ consent for %ld worktree folders (renewed: %@)", actionTitle, preview.paths.count, changed ? "yes" : "no")
        presentWorktreeSheet(alert, context: context) { [weak self] response in
            defer { finished() }
            guard response == .alertFirstButtonReturn, let self, self.isCurrentWorktreePresentation(context) else {
                context.service.discardRepairPreview(preview)
                NSLog("[GitX] Discarded unconfirmed worktree repair consent")
                return
            }
            self.performRepair(preview, context: context)
        }
    }

    private func performRepair(_ preview: PBWorktreeRepairPreview, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context) else {
            context.service.discardRepairPreview(preview)
            NSLog("[GitX] Discarded worktree repair consent before admission")
            return
        }
        context.service.confirmRepair(preview, ownerIsCurrent: { [weak self] in
            self?.isCurrentWorktreePresentation(context) == true
        }, owner: context.operationOwner) { [weak self] updated, error in
            guard let self, self.canReceiveWorktreeResult(context) else {
                context.discardRepairPreview(updated)
                NSLog("[GitX] Discarded renewed repair consent after its presentation owner changed")
                return
            }
            if let error {
                context.discardRepairPreview(updated)
                self.showWorktreeError(error, context: context)
            } else if let updated {
                self.presentRepairPreview(updated, context: context, changed: true)
            }
        }
    }

    private func performWorktree(_ command: WorktreeCommand, expectedWorktree: GitWorktree? = nil, context: WorktreePresentationContext) {
        guard isCurrentWorktreePresentation(context) else {
            NSLog("[GitX] Discarded a deferred worktree action after its presentation owner changed")
            return
        }
        context.service.perform(command, expectedWorktree: expectedWorktree, owner: context.operationOwner) { [weak self] _, error in
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
