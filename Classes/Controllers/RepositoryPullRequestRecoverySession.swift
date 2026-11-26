import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

/// Owns exact text and persistence independently of either presentation host.
@MainActor
final class RepositoryPullRequestRecoverySession {
    private static let live = NSHashTable<RepositoryPullRequestRecoverySession>.weakObjects()
    private static var detachedHosts: [UUID: DetachedRecoveryHost] = [:]
    static var currentSessions: [RepositoryPullRequestRecoverySession] {
        let current = live.allObjects.filter(\.isCurrent)
        current.forEach { $0.synchronizeRecoveredContent() }
        return current
    }

    static var protectedSessions: [RepositoryPullRequestRecoverySession] {
        currentSessions.filter { !$0.protectionState.isEmpty }
    }

    struct Protection: Equatable {
        let submission: ObjectIdentifier
        let content: ForgeDraftContent
        let phase: RepositoryEditSubmissionLifetime.Phase
    }

    var protectionState: [Protection] {
        submissions.filter(\.needsCloseProtection).map { Protection(submission: ObjectIdentifier($0), content: $0.recoveryContent, phase: $0.phase) }
    }

    let identity = UUID()
    let queue = RepositoryDraftOperationQueue()
    var submissions: [RepositoryEditSubmissionLifetime] = []
    var attachedCloseDecision: ((@escaping (Bool) -> Void) -> Bool)?
    var onAcceptedTermination: (() -> Void)?
    var attachedEditorsForTermination: (() -> [ForgePullRequestSheetController])?
    private let drafts: any RepositoryPullRequestDraftPersisting
    private let now: @Sendable () -> Date
    private let ownerIsCurrent: () -> Bool
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RecoveredEdit")
    private var invalidated = false
    private(set) var isDetached = false
    private weak var host: DetachedRecoveryHost?
    private var saveAttempts: [UUID: Task<Void, Never>] = [:]
    private var closeAlert: NSAlert?
    private var closeIdentity: UUID?
    private var closeDecisions: [(Bool) -> Void] = []
    private var presentations: [ObjectIdentifier: WeakRecoveryPresentation] = [:]

    init(drafts: any RepositoryPullRequestDraftPersisting, now: @escaping @Sendable () -> Date, ownerIsCurrent: @escaping () -> Bool) {
        self.drafts = drafts; self.now = now; self.ownerIsCurrent = ownerIsCurrent
        Self.live.add(self)
    }

    private var isCurrent: Bool {
        !invalidated && (isDetached || ownerIsCurrent())
    }

    func bind(_ sheet: ForgePullRequestSheetController, to submission: RepositoryEditSubmissionLifetime) {
        presentations[ObjectIdentifier(sheet)] = WeakRecoveryPresentation(sheet, submission: submission)
        sheet.onDraftChanged = { [weak self] content in
            submission.updateRecoveryContent(content)
            if submission.needsCloseProtection, self?.submissions.contains(where: { $0 === submission }) == false {
                self?.submissions.append(submission)
            }
        }
        sheet.onCancel = { [weak self] _ in
            submission.resolveRecovery()
            self?.retire()
        }
        sheet.onRecoverySaved = { [weak self] content in
            submission.markRecoverySaved(content)
            self?.retire()
        }
        sheet.onSaveRecovery = { [weak self, weak sheet] content in
            guard let self, let sheet else { return }
            save(content, identity: submission.draftIdentity, sheet: sheet)
        }
    }

    func retire() {
        submissions.removeAll(where: \.canRetire)
        presentations = presentations.filter { $0.value.sheet != nil }
        host?.update()
    }

    func didSettle() {
        // Attached presentation preserves the controller's authorization-retry order.
        // A detached host has no mutation presentation authority to consult.
        if isDetached {
            retire()
        }
    }

    func invalidateAttachedPresentation() {
        guard !isDetached else { return }
        invalidated = true
        attachedCloseDecision = nil
        onAcceptedTermination = nil
        attachedEditorsForTermination = nil
        cancelPendingCloseDecision()
    }

    func detach(presented: [(RepositoryEditSubmissionLifetime, ForgePullRequestSheetController)]) {
        guard !isDetached, !protectionState.isEmpty || !presented.isEmpty else { return }
        cancelPendingCloseDecision()
        isDetached = true
        attachedCloseDecision = nil
        onAcceptedTermination = nil
        attachedEditorsForTermination = nil
        let host = DetachedRecoveryHost(session: self, presented: presented)
        self.host = host
        Self.detachedHosts[identity] = host
        host.update()
        logger.notice("Transferred recovered edits and admitted persistence to standalone presentation")
    }

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard !protectionState.isEmpty else { return false }
        if let host {
            return host.requestCloseDecision(completion)
        }
        return attachedCloseDecision?(completion) ?? false
    }

    private func synchronizeRecoveredContent() {
        for presentation in presentations.values {
            guard let content = presentation.sheet?.recoveryContentSnapshot else { continue }
            let submission = presentation.submission
            submission.updateRecoveryContent(content)
            if submission.needsCloseProtection, !submissions.contains(where: { $0 === submission }) {
                submissions.append(submission)
            }
        }
    }

    func confirmClosing(parent: NSWindow, validation: @escaping () -> Bool, completion: @escaping (Bool) -> Void) -> Bool {
        synchronizeRecoveredContent()
        guard isCurrent, !protectionState.isEmpty else { return false }
        if closeIdentity != nil {
            closeDecisions.append(completion); return true
        }
        closeDecisions.append(completion)
        let pending = submissions.contains { $0.needsCloseProtection && $0.phase != .finished }
        let editorAvailable = presentations.values.contains { $0.sheet?.window?.isVisible == true }
        let id = UUID()
        closeIdentity = id
        let alert = NSAlert()
        closeAlert = alert
        alert.window.setAccessibilityIdentifier("GitX.PullRequest.Recovery.WindowCloseConfirmation")
        alert.messageText = pending ? "Close With a Pull Request Edit Pending?" : "Close Without Saving Recovered Text?"
        alert.informativeText = pending
            ? "A Pull Request edit is still being saved or sent. Keep this window open to wait for its result. Closing discards text that cannot be saved; an edit already sent may still finish."
            : editorAvailable
            ? "This window still owns Pull Request edit text that has not been saved. Keep the window open to copy or save it. Closing discards the memory-only text."
            : "Recovered Pull Request text is waiting for an editor. Keep the window open to review it when the current sheet closes. Closing discards this unsaved text."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Close Without Saving")
        var confirmationParent = parent
        while let attached = confirmationParent.attachedSheet {
            confirmationParent = attached
        }
        alert.beginSheetModal(for: confirmationParent) { [weak self] response in
            guard let self, closeIdentity == id else { return }
            closeIdentity = nil; closeAlert = nil
            let callbacks = closeDecisions; closeDecisions.removeAll()
            let allowed = isCurrent && validation() && response == .alertSecondButtonReturn
            callbacks.forEach { $0(allowed) }
        }
        return true
    }

    var terminationEditors: [ForgePullRequestSheetController] {
        (attachedEditorsForTermination?() ?? []) + presentations.values.compactMap(\.sheet)
    }

    func preparePresentationsForTermination() -> Bool {
        terminationEditors.map { $0.suspendForTermination() }.allSatisfy { $0 }
    }

    func restorePresentationsAfterCancelledTermination() {
        terminationEditors.forEach { $0.restoreAfterCancelledTermination() }
    }

    /// Called only after every Quit guard has agreed, immediately before AppKit's
    /// final affirmative reply. Earlier consent remains nondestructive.
    func completeAcceptedTermination() {
        let endAttachedPresentation = onAcceptedTermination
        onAcceptedTermination = nil
        invalidated = true
        attachedCloseDecision = nil
        cancelPendingCloseDecision()
        submissions.forEach { $0.resolveRecovery() }
        presentations.values.compactMap(\.sheet).forEach { $0.invalidatePresentation() }
        retire()
        endAttachedPresentation?()
    }

    func cancelPendingCloseDecision() {
        closeIdentity = nil
        let callbacks = closeDecisions; closeDecisions.removeAll()
        if let alert = closeAlert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
            alert.window.orderOut(nil)
        }
        closeAlert = nil
        callbacks.forEach { $0(false) }
    }

    private func save(_ content: ForgeDraftContent, identity: ForgeDraftIdentity, sheet: ForgePullRequestSheetController) {
        guard isCurrent, let attempt = sheet.beginRecoverySave() else { return }
        let drafts = drafts
        let date = now()
        let load = queue.enqueueThrowing { try await drafts.load(identity: identity) }
        saveAttempts[attempt] = Task { [self, weak sheet] in
            defer { sheet?.finishRecoverySave(attempt); saveAttempts[attempt] = nil }
            guard let sheet else { return }
            do {
                let expected = try await load.value
                guard isCurrent, sheet.acceptsRecoverySave(attempt) else { return }
                if expected != nil {
                    guard await sheet.confirmRecoveryReplacement(attempt) else { return }
                }
                guard isCurrent, sheet.acceptsRecoverySave(attempt) else { return }
                let write = queue.enqueueThrowing(writes: true) { try await drafts.saveSnapshot(identity: identity, content: content, at: date, matching: expected) }
                let saved = try await write.value
                guard isCurrent, sheet.acceptsRecoverySave(attempt) else { return }
                if saved != nil {
                    sheet.markRecoverySaved(content)
                } else {
                    showSaveError("The stored draft changed. Your recovered text remains here; choose Save Draft again to review the latest draft.", sheet: sheet)
                }
            } catch {
                guard isCurrent, sheet.acceptsRecoverySave(attempt) else { return }
                showSaveError("The draft could not be saved. Your recovered text remains here. Copy it or try Save Draft again.", sheet: sheet)
                logger.error("Recovered draft save failed; code=\((error as NSError).code)")
            }
        }
    }

    private func showSaveError(_ message: String, sheet: ForgePullRequestSheetController) {
        guard let window = sheet.window else { return }
        let alert = NSAlert()
        alert.window.setAccessibilityIdentifier("GitX.PullRequest.Recovery.SaveError")
        alert.messageText = "Draft Not Saved"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @MainActor private final class WeakRecoveryPresentation {
        weak var sheet: ForgePullRequestSheetController?
        let submission: RepositoryEditSubmissionLifetime
        init(_ sheet: ForgePullRequestSheetController, submission: RepositoryEditSubmissionLifetime) {
            self.sheet = sheet
            self.submission = submission
        }
    }

    @MainActor private final class DetachedRecoveryHost: NSObject, NSWindowDelegate {
        let session: RepositoryPullRequestRecoverySession
        private var sheets: [ObjectIdentifier: ForgePullRequestSheetController] = [:]
        private var waitingWindow: NSWindow?
        private var updating = false
        init(session: RepositoryPullRequestRecoverySession, presented: [(RepositoryEditSubmissionLifetime, ForgePullRequestSheetController)]) {
            self.session = session
            super.init()
            for (submission, sheet) in presented {
                install(sheet, submission: submission)
            }
        }

        private func install(_ sheet: ForgePullRequestSheetController, submission: RepositoryEditSubmissionLifetime) {
            let identity = ObjectIdentifier(sheet)
            sheets[identity] = sheet
            submission.recoveryQueued = true
            session.bind(sheet, to: submission)
            sheet.onPresentationEnded = { [weak self] in
                guard let self else { return }
                sheets[identity] = nil
                submission.recoveryQueued = false
                DispatchQueue.main.async { [weak self] in self?.update() }
            }
            sheet.showStandaloneRecovery()
        }

        func update() {
            guard !updating else { return }
            updating = true
            defer { updating = false }
            for submission in RepositoryEditRecoveryOrder.ready(in: session.submissions) {
                let sheet = ForgePullRequestSheetController(mode: .recovery(destination: submission.destination), restoredContent: submission.recoveryContent, recoveryMessage: submission.recoveryMessage)
                install(sheet, submission: submission)
            }
            let pending = session.submissions.contains { $0.needsCloseProtection && $0.phase != .finished }
            if pending, sheets.isEmpty, waitingWindow == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 130), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.title = "Recovered Pull Request Edit"
                panel.setAccessibilityIdentifier("GitX.PullRequest.DetachedRecovery.Waiting")
                let label = NSTextField(wrappingLabelWithString: "The repository moved. A Pull Request edit is still being saved or sent. Its recovered text will appear here if it cannot be saved.")
                label.frame = NSRect(x: 20, y: 24, width: 440, height: 80)
                panel.contentView?.addSubview(label)
                panel.delegate = self
                waitingWindow = panel
                panel.center(); panel.makeKeyAndOrderFront(nil)
            } else if !pending || !sheets.isEmpty {
                if waitingWindow != nil {
                    session.cancelPendingCloseDecision()
                }
                waitingWindow?.orderOut(nil)
                waitingWindow?.delegate = nil
                waitingWindow?.close()
                waitingWindow = nil
            }
            if !pending, sheets.isEmpty, session.protectionState.isEmpty {
                Self.closeHost(session)
            }
        }

        private static func closeHost(_ session: RepositoryPullRequestRecoverySession) {
            session.invalidated = true
            RepositoryPullRequestRecoverySession.detachedHosts[session.identity] = nil
        }

        func requestCloseDecision(_ completion: @escaping (Bool) -> Void) -> Bool {
            guard let parent = sheets.values.first?.window ?? waitingWindow else { return false }
            return session.confirmClosing(parent: parent, validation: { [weak self] in self != nil }, completion: completion)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if requestCloseDecision({ [weak self] allowed in
                guard allowed, let self else { return }
                session.submissions.forEach { $0.resolveRecovery() }
                session.retire()
            }) {
                return false
            }
            return true
        }
    }
}
