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
    private var appKitReplyPending = false
    private let waitingPresented: (NSPanel) -> Void
    private var attempt: UUID?
    private var terminationAccepted = false
    private var approved: [UUID: [RepositoryPullRequestRecoverySession.Protection]] = [:]
    private var remoteApproved = false
    private var waitingForRemote = false
    private var advancing: UUID?
    private var waitingPanel: NSPanel?
    private var activityWait: CheckedContinuation<Bool, Never>?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryTermination")

    init(mutations: RepositoryLocalMutationRegistry = .shared,
         sessions: @escaping () -> [RepositoryPullRequestRecoverySession] = { RepositoryPullRequestRecoverySession.protectedSessions },
         remoteDecision: @escaping () -> NSApplication.TerminateReply,
         remoteCancelled: @escaping () -> Void,
         waitingPresented: @escaping (NSPanel) -> Void = { _ in },
         terminate: @escaping () -> Void = { NSApp.terminate(nil) },
         reply: @escaping (Bool) -> Void)
    {
        self.mutations = mutations; self.sessions = sessions; self.remoteDecision = remoteDecision
        self.remoteCancelled = remoteCancelled; self.reply = reply; self.waitingPresented = waitingPresented
        self.terminate = terminate
        super.init()
        mutations.observe { [weak self] in Task { @MainActor in self?.activityDidChange() } }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if terminationAccepted {
            return .terminateNow
        }
        appKitReplyPending = true
        beginAttempt()
        return .terminateLater
    }

    /// AppKit waits for attached sheets before consulting its delegate. The menu
    /// asks for consent first, while those sheets can still present that consent.
    func requestTermination() {
        guard !terminationAccepted else { terminate(); return }
        beginAttempt()
    }

    private func beginAttempt() {
        guard attempt == nil else { return }
        let identity = UUID()
        attempt = identity
        approved.removeAll()
        remoteApproved = false
        waitingForRemote = false
        mutations.sealAdmission()
        logger.notice("Began termination attempt with local admission sealed")
        Task { [self] in await advance(identity) }
    }

    func remoteTerminationReply(_ shouldTerminate: Bool) {
        guard let attempt, waitingForRemote else { return }
        waitingForRemote = false
        guard shouldTerminate else { finish(attempt, allowed: false); return }
        remoteApproved = true
        Task { [self] in await advance(attempt) }
    }

    private func advance(_ identity: UUID) async {
        guard attempt == identity, advancing != identity else { return }
        advancing = identity
        defer {
            if advancing == identity {
                advancing = nil
            }
        }
        while attempt == identity {
            if mutations.hasActivity {
                showWaitingPanel()
                guard attempt == identity else { return }
                let completed = await withCheckedContinuation {
                    activityWait = $0
                    // Work can settle while AppKit is presenting the waiting panel.
                    activityDidChange()
                }
                guard completed, attempt == identity else { return }
                hideWaitingPanel()
                continue
            }
            if let session = sessions().first(where: { approved[$0.identity] != $0.protectionState }) {
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
            if !remoteApproved {
                waitingForRemote = true
                let decision = remoteDecision()
                guard attempt == identity else { return }
                switch decision {
                case .terminateNow: remoteApproved = true; waitingForRemote = false
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
            // No await separates this final revalidation from AppKit's one reply.
            guard !mutations.hasActivity,
                  sessions().allSatisfy({ approved[$0.identity] == $0.protectionState }) else { continue }
            finish(identity, allowed: true)
        }
    }

    private func activityDidChange() {
        guard !mutations.hasActivity, let waiting = activityWait else { return }
        activityWait = nil
        waiting.resume(returning: true)
    }

    @objc func cancelPendingQuit() {
        guard let attempt else { return }
        finish(attempt, allowed: false)
    }

    private func finish(_ identity: UUID, allowed: Bool) {
        guard attempt == identity else { return }
        attempt = nil
        let needsAppKitReply = appKitReplyPending
        appKitReplyPending = false
        let waiting = activityWait; activityWait = nil
        waiting?.resume(returning: false)
        hideWaitingPanel()
        approved.removeAll()
        waitingForRemote = false
        if allowed {
            terminationAccepted = true
            sessions().forEach { $0.completeAcceptedTermination() }
        } else {
            sessions().forEach { $0.cancelPendingCloseDecision() }
            mutations.reopenAdmission()
            remoteCancelled()
        }
        logger.notice("Termination attempt settled allowed=\(allowed, privacy: .public)")
        if needsAppKitReply {
            reply(allowed)
        } else if allowed {
            terminate()
        }
    }

    private func showWaitingPanel() {
        guard waitingPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Waiting to Quit"
        panel.setAccessibilityIdentifier("GitX.Quit.WaitingForLocalMutations")
        let label = NSTextField(wrappingLabelWithString: "A repository mutation is still running. Half Dark will wait for it to finish before quitting.")
        label.frame = NSRect(x: 20, y: 64, width: 420, height: 66)
        let cancel = NSButton(title: "Cancel Quit", target: self, action: #selector(cancelPendingQuit))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 320, y: 18, width: 120, height: 32)
        cancel.setAccessibilityIdentifier("GitX.Quit.Cancel")
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(cancel)
        waitingPanel = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        waitingPresented(panel)
    }

    private func hideWaitingPanel() {
        waitingPanel?.orderOut(nil)
        waitingPanel?.close()
        waitingPanel = nil
    }
}
