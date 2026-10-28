import AppKit

/// Availability never depends on dismissing a warning. Sheets wait for an eligible parent.
@MainActor
final class GitBinaryDiscoveryPresenter: NSObject {
    struct Warning: Equatable {
        let preference: String
        let selection: GitBinarySelection?
    }

    typealias PresentSheet = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    static let shared = GitBinaryDiscoveryPresenter()

    private let center: NotificationCenter
    private let windows: () -> [NSWindow]
    private let presentSheet: PresentSheet
    private var selection: GitBinarySelection?
    private var pending: Warning?
    private var lastPresented: Warning?
    private var alert: NSAlert?

    init(center: NotificationCenter = .default, windows: @escaping () -> [NSWindow] = { NSApp.orderedWindows },
         presentSheet: @escaping PresentSheet = { alert, parent, completed in alert.beginSheetModal(for: parent, completionHandler: completed) })
    {
        self.center = center
        self.windows = windows
        self.presentSheet = presentSheet
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
    }

    func publishSelection(_ newSelection: GitBinarySelection?) {
        if selection != newSelection {
            selection = newSelection
            center.post(name: .PBGitBinaryDidChange, object: nil)
        }
    }

    func publish(selection newSelection: GitBinarySelection?, rejected: String?) {
        publishSelection(newSelection)
        guard let rejected else {
            pending = nil
            lastPresented = nil
            dismissWarning()
            return
        }
        let warning = Warning(preference: rejected, selection: newSelection)
        if let pending, pending != warning {
            dismissWarning()
        }
        pending = warning
        presentIfPossible()
    }

    @objc private func windowBecameAvailable(_: Notification) {
        presentIfPossible()
    }

    private func dismissWarning() {
        guard let alert else { return }
        self.alert = nil
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        alert.window.orderOut(nil)
    }

    private func presentIfPossible() {
        guard alert == nil, let pending, pending != lastPresented,
              let parent = windows().first(where: { $0.isVisible && $0.canBecomeKey && $0.attachedSheet == nil && $0.sheetParent == nil }) else { return }
        lastPresented = pending
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Invalid git path", comment: "Configured Git executable is invalid")
        let requested = pending.preference.isEmpty ? NSLocalizedString("Automatic Git discovery", comment: "") : pending.preference
        alert.informativeText = String(format: NSLocalizedString("The configured Git executable “%@” could not be validated. %@", comment: "Git discovery fallback"), requested,
                                       pending.selection.map { "Using \($0.path) instead." } ?? "No usable Git executable was found.")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        self.alert = alert
        NSLog("[GitDiscovery] Presenting rejected preference %@; active %@", requested, pending.selection?.path ?? "unavailable")
        presentSheet(alert, parent) { [weak self, weak alert] _ in
            guard let self, self.alert === alert else { return }
            self.alert = nil
            presentIfPossible()
        }
    }
}
