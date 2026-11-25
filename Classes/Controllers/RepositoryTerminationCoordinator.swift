import AppKit
import OSLog // swiftlint:disable:this unused_import

/// Application termination composes local execution, recovery consent and Forge's
/// existing remote-outcome choices without borrowing document-close authority.
@MainActor
final class RepositoryTerminationCoordinator: NSObject {
    #if GITX_APP_TARGET
        static let shared: RepositoryTerminationCoordinator = .init(
            remoteDecision: { ForgeMutationQuitCoordinator.shared.applicationShouldTerminate() },
            remoteCancelled: { ForgeMutationQuitCoordinator.shared.cancelApplicationTermination() },
            hasBlockingSheets: { ownedSheets in
                NSApp.windows.contains { window in
                    guard window.isVisible, let sheet = window.attachedSheet else { return false }
                    return !ownedSheets.contains(ObjectIdentifier(sheet))
                }
            },
            reply: { NSApp.reply(toApplicationShouldTerminate: $0) }
        )
    #endif
    #if GITX_APP_TARGET
        /// Thin Objective-C delegate hook; every lifecycle decision stays here.
        // ApplicationController.m calls this delegate hook through GitX-Swift.h.
        // swiftlint:disable unused_declaration
        @objc(applicationShouldTerminate:)
        static func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
            shared.applicationShouldTerminate()
        }

        // swiftlint:enable unused_declaration

        // ApplicationController.m forwards the native menu action through GitX-Swift.h.
        // swiftlint:disable unused_declaration
        @objc(requestApplicationTermination:)
        static func requestApplicationTermination(_ sender: Any?) {
            shared.requestTermination()
        }
        // swiftlint:enable unused_declaration
    #endif

    private let mutations: RepositoryLocalMutationRegistry
    private let sessions: () -> [RepositoryPullRequestRecoverySession]
    private let remoteDecision: () -> NSApplication.TerminateReply
    private let remoteCancelled: () -> Void
    private let reply: (Bool) -> Void
    private let terminate: () -> Void
    private let hasBlockingSheets: (Set<ObjectIdentifier>) -> Bool
    private var appKitReplyPending = false
    private enum NativeHandoff: Equatable {
        case idle
        case queued(UUID)
        case awaitingDelegate(UUID)
        case cancelled
    }

    private var handoff: NativeHandoff = .idle
    private var nativeInvocationInProgress = false
    private var retryRequested = false
    private var probeScheduled = false
    private var activityObservation: UUID?
    private let waitingPresented: (NSPanel) -> Void
    private var attempt: UUID?
    private var terminationAccepted = false
    private var approved: [UUID: [RepositoryPullRequestRecoverySession.Protection]] = [:]
    private var remoteApproval: ForgeMutationQuitCoordinator.QuitDecision?
    private var waitingForRemote = false
    private var advancing: UUID?
    private var waitingPanel: NSPanel?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryTermination")

    init(mutations: RepositoryLocalMutationRegistry = .shared,
         sessions: @escaping () -> [RepositoryPullRequestRecoverySession] = { RepositoryPullRequestRecoverySession.currentSessions },
         remoteDecision: @escaping () -> NSApplication.TerminateReply,
         remoteCancelled: @escaping () -> Void,
         waitingPresented: @escaping (NSPanel) -> Void = { _ in },
         hasBlockingSheets: @escaping (Set<ObjectIdentifier>) -> Bool = { _ in false },
         terminate: @escaping () -> Void = { NSApp.terminate(nil) },
         reply: @escaping (Bool) -> Void)
    {
        self.mutations = mutations; self.sessions = sessions; self.remoteDecision = remoteDecision
        self.remoteCancelled = remoteCancelled; self.reply = reply; self.waitingPresented = waitingPresented
        self.terminate = terminate; self.hasBlockingSheets = hasBlockingSheets
        super.init()
        activityObservation = mutations.observe { [weak self] in Task { @MainActor in self?.activityDidChange() } }
        NotificationCenter.default.addObserver(self, selector: #selector(sheetAvailabilityChanged), name: NSWindow.didEndSheetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetAvailabilityChanged), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetAvailabilityChanged), name: ForgePullRequestSheetController.terminationReadinessDidChange, object: nil)
    }

    isolated deinit {
        if let activityObservation {
            mutations.removeObserver(activityObservation)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if terminationAccepted {
            return .terminateNow
        }
        if handoff == .cancelled {
            handoff = .idle
            hideWaitingPanel()
            if !nativeInvocationInProgress {
                scheduleRequestedRetry()
            }
            return .terminateCancel
        }
        if let attempt, handoff == .awaitingDelegate(attempt) {
            handoff = .idle
            if presentationBlocker == nil, acceptIfReady(attempt) {
                return .terminateNow
            }
            restorePresentations()
            if !nativeInvocationInProgress {
                scheduleAdvance(attempt)
            }
            return .terminateCancel
        }

        // A system-origin request may arrive before our queued menu call starts.
        handoff = .idle
        appKitReplyPending = true
        if let attempt {
            scheduleAdvance(attempt)
        } else {
            beginAttempt()
        }
        return .terminateLater
    }

    /// AppKit waits for attached sheets before consulting its delegate. The menu
    /// asks for consent first, while those sheets can still present that consent.
    func requestTermination() {
        guard !terminationAccepted else { terminate(); return }
        if attempt != nil || retryRequested {
            waitingPanel?.makeKeyAndOrderFront(nil)
            return
        }
        if handoff == .cancelled || nativeInvocationInProgress {
            retryRequested = true
            showNativeWait()
            scheduleCancellationProbe()
        } else {
            beginAttempt()
        }
    }

    private func beginAttempt() {
        guard attempt == nil, handoff == .idle else { return }
        let identity = UUID()
        attempt = identity
        approved.removeAll()
        remoteApproval = nil
        waitingForRemote = false
        mutations.sealAdmission()
        logger.notice("Began termination attempt with local admission sealed")
        scheduleAdvance(identity)
    }

    func remoteTerminationReply(_ decision: ForgeMutationQuitCoordinator.QuitDecision) {
        guard let attempt, waitingForRemote else { return }
        waitingForRemote = false
        guard decision != .cancelled else { finish(attempt, allowed: false); return }
        remoteApproval = decision
        scheduleAdvance(attempt)
    }

    private func scheduleAdvance(_ identity: UUID) {
        Task { [self] in await advance(identity) }
    }

    private func advance(_ identity: UUID) async {
        guard attempt == identity, advancing != identity, handoff == .idle, !nativeInvocationInProgress else { return }
        advancing = identity
        defer {
            if advancing == identity {
                advancing = nil
            }
        }
        while attempt == identity {
            if mutations.hasActivity(includingReservedFetches: remoteApproval == .waitForFetches) {
                showWaitingPanel()
                return
            }
            if let session = sessions().first(where: { approved[$0.identity] != $0.protectionState }) {
                hideWaitingPanel()
                let state = session.protectionState
                let allowed = await withCheckedContinuation { continuation in
                    var replied = false
                    let deferred = session.requestCloseDecision { allowed in
                        guard !replied else { return }; replied = true
                        continuation.resume(returning: allowed)
                    }
                    if !deferred, !replied {
                        replied = true; continuation.resume(returning: session.protectionState.isEmpty)
                    }
                }
                guard attempt == identity else { return }
                guard allowed else { finish(identity, allowed: false); return }
                approved[session.identity] = state
                continue
            }
            if remoteApproval == nil {
                guard !waitingForRemote else { return }
                hideWaitingPanel()
                waitingForRemote = true
                let decision = remoteDecision()
                guard attempt == identity else { return }
                switch decision {
                case .terminateNow: remoteApproval = .waitForFetches; waitingForRemote = false
                case .terminateLater:
                    // A native modal remote choice may deliver completion before
                    // its original delegate call returns.
                    if waitingForRemote {
                        return
                    }
                case .terminateCancel: finish(identity, allowed: false); return
                @unknown default: finish(identity, allowed: false); return
                }
                continue
            }
            guard readyForFinalDecision else { continue }
            if appKitReplyPending {
                if acceptIfReady(identity) {
                    return
                }
                continue
            }
            if let blocker = presentationBlocker {
                showWaitingPanel(message: blocker)
                return
            }
            handoff = .queued(identity)
            scheduleOnDefaultRunLoop { [weak self] in self?.performHandoff(identity) }
            return
        }
    }

    private var readyForFinalDecision: Bool {
        remoteApproval != nil && !mutations.hasActivity(includingReservedFetches: remoteApproval == .waitForFetches)
            && sessions().allSatisfy { approved[$0.identity] == $0.protectionState }
    }

    private var presentationBlocker: String? {
        let editors = sessions().flatMap(\.terminationEditors)
        let ownedSheets = Set(editors.compactMap { editor -> ObjectIdentifier? in
            guard let window = editor.window, window.sheetParent != nil else { return nil }
            return ObjectIdentifier(window)
        })
        let editorBlockers = editors.compactMap(\.terminationBlocker)
        if editorBlockers.contains(.sheet) || hasBlockingSheets(ownedSheets) {
            return "Finish the open sheet to continue quitting, or choose Cancel Quit to keep working."
        }
        if editorBlockers.contains(.draftSave) {
            return "A recovered edit is still being saved. Wait for the draft save to finish, or choose Cancel Quit to keep working."
        }
        return nil
    }

    private func performHandoff(_ identity: UUID) {
        guard attempt == identity, handoff == .queued(identity) else { return }
        handoff = .idle
        guard readyForFinalDecision, presentationBlocker == nil else {
            scheduleAdvance(identity)
            return
        }
        let suspended = sessions().map { $0.preparePresentationsForTermination() }.allSatisfy { $0 }
        guard attempt == identity, suspended, readyForFinalDecision, presentationBlocker == nil else {
            restorePresentations()
            scheduleAdvance(identity)
            return
        }
        handoff = .awaitingDelegate(identity)
        invokeNativeTermination()
    }

    private func invokeNativeTermination(isCancellationProbe: Bool = false) {
        nativeInvocationInProgress = true
        terminate()
        nativeInvocationInProgress = false
        if let attempt {
            if handoff == .awaitingDelegate(attempt) {
                showNativeWait()
            } else if handoff == .idle {
                scheduleAdvance(attempt)
            }
        } else if handoff == .idle {
            scheduleRequestedRetry()
        } else if handoff == .cancelled, retryRequested {
            showNativeWait()
            if !isCancellationProbe {
                scheduleCancellationProbe()
            }
        }
    }

    private func scheduleCancellationProbe() {
        guard handoff == .cancelled, !nativeInvocationInProgress, !probeScheduled else { return }
        probeScheduled = true
        scheduleOnDefaultRunLoop { [weak self] in
            guard let self else { return }
            self.probeScheduled = false
            guard self.retryRequested, self.handoff == .cancelled else { return }
            self.invokeNativeTermination(isCancellationProbe: true)
        }
    }

    private func scheduleRequestedRetry() {
        guard retryRequested, handoff == .idle else { return }
        scheduleOnDefaultRunLoop { [weak self] in
            guard let self, self.retryRequested, self.handoff == .idle, !self.nativeInvocationInProgress else { return }
            self.retryRequested = false
            self.beginAttempt()
        }
    }

    private func scheduleOnDefaultRunLoop(_ action: @escaping @MainActor @Sendable () -> Void) {
        // The main run loop's default mode runs after AppKit's nested Quit loop unwinds.
        RunLoop.main.perform(inModes: [.default]) {
            // swift6-safety-justification: RunLoop.main executes its scheduled blocks on the main thread.
            MainActor.assumeIsolated { action() }
        }
    }

    private func showNativeWait() {
        showWaitingPanel(message: "Waiting for macOS to finish Quit. Choose Cancel Quit to keep working.")
    }

    @objc private func sheetAvailabilityChanged(_: Notification) {
        if let attempt {
            scheduleAdvance(attempt)
        }
    }

    private func activityDidChange() {
        if let attempt {
            scheduleAdvance(attempt)
        }
    }

    @objc func cancelPendingQuit() {
        if let attempt {
            finish(attempt, allowed: false)
        } else if retryRequested {
            retryRequested = false
            hideWaitingPanel()
        }
    }

    private func acceptIfReady(_ identity: UUID) -> Bool {
        guard attempt == identity, readyForFinalDecision,
              mutations.commitTermination(waitForReservedFetches: remoteApproval == .waitForFetches)
        else { return false }
        finish(identity, allowed: true)
        return true
    }

    private func restorePresentations() {
        sessions().forEach { $0.restorePresentationsAfterCancelledTermination() }
    }

    private func finish(_ identity: UUID, allowed: Bool) {
        guard attempt == identity else { return }
        attempt = nil
        let needsAppKitReply = appKitReplyPending
        appKitReplyPending = false
        handoff = !allowed && handoff == .awaitingDelegate(identity) ? .cancelled : .idle
        hideWaitingPanel()
        approved.removeAll()
        waitingForRemote = false
        if allowed {
            terminationAccepted = true
            sessions().forEach { $0.completeAcceptedTermination() }
        } else {
            sessions().forEach { $0.cancelPendingCloseDecision() }
            restorePresentations()
            mutations.reopenAdmission()
            remoteCancelled()
        }
        logger.notice("Termination attempt settled allowed=\(allowed, privacy: .public)")
        if needsAppKitReply {
            reply(allowed)
        }
    }

    private func showWaitingPanel(message: String = "A repository mutation is still running. Half Dark will wait for it to finish before quitting.") {
        if let waitingPanel {
            (waitingPanel.contentView?.subviews.first as? NSTextField)?.stringValue = message
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = "Waiting to Quit"
        panel.setAccessibilityIdentifier("GitX.Quit.WaitingForLocalMutations")
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 20, y: 64, width: 420, height: 66)
        let cancel = NSButton(title: "Cancel Quit", target: self, action: #selector(cancelPendingQuit))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 320, y: 18, width: 120, height: 32)
        cancel.setAccessibilityIdentifier("GitX.Quit.Cancel")
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(cancel)
        waitingPanel = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        logger.notice("Presented cancellable Quit wait")
        waitingPresented(panel)
    }

    private func hideWaitingPanel() {
        waitingPanel?.orderOut(nil)
        waitingPanel?.close()
        waitingPanel = nil
    }
}
