import AppKit

nonisolated enum GitDiscoveryWarningPolicy {
    static func shouldPresentAutomatically(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }
}

/// Availability never depends on dismissing a warning. Sheets wait for an eligible parent.
@MainActor
final class GitBinaryDiscoveryPresenter: NSObject {
    struct Warning: Equatable {
        let preference: String
        let selection: GitBinarySelection?
    }

    private struct Presentation {
        let id = UUID()
        let warning: Warning
        let alert: NSAlert
    }

    typealias PresentSheet = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    typealias DismissSheet = (NSAlert) -> Void
    static let shared = GitBinaryDiscoveryPresenter(
        automaticPresentationEnabled: GitDiscoveryWarningPolicy.shouldPresentAutomatically(environment: ProcessInfo.processInfo.environment)
    )

    let automaticPresentationEnabled: Bool
    private let center: NotificationCenter
    private let windows: () -> [NSWindow]
    private let presentSheet: PresentSheet
    private let dismissSheet: DismissSheet
    private var selection: GitBinarySelection?
    private var pending: Warning?
    private var acknowledged: Warning?
    private var presentation: Presentation?

    init(center: NotificationCenter = .default, windows: @escaping () -> [NSWindow] = { NSApp.orderedWindows },
         automaticPresentationEnabled: Bool = true,
         presentSheet: @escaping PresentSheet = { alert, parent, completed in alert.beginSheetModal(for: parent, completionHandler: completed) },
         dismissSheet: @escaping DismissSheet = { alert in
             if let parent = alert.window.sheetParent {
                 parent.endSheet(alert.window, returnCode: .abort)
             }
             alert.window.orderOut(nil)
         })
    {
        self.center = center
        self.windows = windows
        self.automaticPresentationEnabled = automaticPresentationEnabled
        self.presentSheet = presentSheet
        self.dismissSheet = dismissSheet
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification]
        {
            center.addObserver(self, selector: #selector(windowBecameAvailable(_:)), name: name, object: nil)
        }
    }

    deinit { center.removeObserver(self) }

    func invalidateWarning() {
        pending = nil
        dismissWarning()
        NSLog("[GitDiscovery] Invalidated warning; acknowledgement preserved")
    }

    func publishSelection(_ newSelection: GitBinarySelection?) {
        if selection != newSelection {
            selection = newSelection
            center.post(name: .PBGitBinaryDidChange, object: nil)
        }
    }

    func publish(selection newSelection: GitBinarySelection?, rejected: String?) {
        let warning = rejected.map { Warning(preference: $0, selection: newSelection) }
        let changed = pending != warning
        // Both notification publication and sheet dismissal can reenter presentation.
        pending = warning
        if warning == nil {
            acknowledged = nil
            NSLog("[GitDiscovery] Successful validation cleared warning acknowledgement")
        }
        if changed || warning == nil {
            dismissWarning()
        }
        publishSelection(newSelection)
        presentIfPossible()
    }

    @objc private func windowBecameAvailable(_: Notification) {
        presentIfPossible()
    }

    private func dismissWarning() {
        guard let presentation else { return }
        // Revoke authority before endSheet can synchronously invoke its completion.
        self.presentation = nil
        dismissSheet(presentation.alert)
        NSLog("[GitDiscovery] Invalidated warning presentation %@", presentation.id.uuidString)
    }

    private func presentIfPossible() {
        guard automaticPresentationEnabled, presentation == nil, let pending, pending != acknowledged,
              let parent = windows().first(where: { $0.isVisible && $0.canBecomeKey && $0.attachedSheet == nil && $0.sheetParent == nil }) else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Invalid git path", comment: "Configured Git executable is invalid")
        let requested = pending.preference.isEmpty ? NSLocalizedString("Automatic Git discovery", comment: "") : pending.preference
        alert.informativeText = String(format: NSLocalizedString("The configured Git executable “%@” could not be validated. %@", comment: "Git discovery fallback"), requested,
                                       pending.selection.map { "Using \($0.path) instead." } ?? "No usable Git executable was found.")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        let presentation = Presentation(warning: pending, alert: alert)
        self.presentation = presentation
        NSLog("[GitDiscovery] Presenting rejected preference %@; active %@; presentation %@", requested, pending.selection?.path ?? "unavailable", presentation.id.uuidString)
        let id = presentation.id
        let warning = presentation.warning
        presentSheet(alert, parent) { [weak self] response in
            guard let self, self.presentation?.id == id else { return }
            self.presentation = nil
            if response == .alertFirstButtonReturn {
                acknowledged = warning
                NSLog("[GitDiscovery] Acknowledged warning presentation %@", id.uuidString)
            } else {
                NSLog("[GitDiscovery] Aborted warning presentation %@ without acknowledgement", id.uuidString)
            }
        }
    }
}
