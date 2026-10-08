import AppKit

enum WindowDialogPresenter {
    static func showRepositorySettings(for windowController: PBGitWindowController) {
        guard let repository = windowController.repository else { return }
        RepositorySettingsController.beginSheet(for: repository, windowController: windowController)
    }

    static func showCommitHookFailedSheet(
        _ messageText: String,
        infoText: String,
        retryHandler: (() -> Void)?,
        cancelHandler: (() -> Void)?,
        for windowController: PBGitWindowController
    ) {
        PBCommitHookFailedSheet.begin(
            withMessageText: messageText,
            infoText: infoText,
            windowController: windowController
        ) { _, response in
            if response == .OK {
                retryHandler?()
            } else {
                cancelHandler?()
            }
        }
    }

    static func showMessageSheet(
        _ messageText: String,
        infoText: String,
        for windowController: PBGitWindowController
    ) {
        PBGitXMessageSheet.begin(
            withMessage: messageText,
            info: infoText,
            windowController: windowController
        )
    }

    static func showErrorSheet(_ error: Error, for windowController: PBGitWindowController) {
        let nsError = error as NSError
        if nsError.domain == PBGitXErrorDomain {
            PBShowGitXErrorSheet(nsError, windowController)
        } else if let window = windowController.window {
            NSAlert(error: nsError).beginSheetModal(for: window) { _ in }
        }
    }

    static func confirmDialog(
        _ alert: NSAlert,
        suppressionIdentifier identifier: String?,
        for windowController: PBGitWindowController,
        onCancel: (() -> Void)? = nil,
        allowsSuppression: Bool = true,
        action actionBlock: @escaping () -> Void
    ) -> Bool {
        var didAct = true
        if allowsSuppression, let identifier, PBGitDefaults.isDialogWarningSuppressed(forDialog: identifier) {
            actionBlock()
            return didAct
        }
        alert.showsSuppressionButton = allowsSuppression && identifier != nil
        guard let window = windowController.window else {
            return WindowDialogPresentationPolicy.cancelWithoutPresentation(onCancel: onCancel)
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                didAct = false
                onCancel?()
                return
            }
            if allowsSuppression, let identifier, alert.suppressionButton?.state == .on {
                PBGitDefaults.suppressDialogWarning(forDialog: identifier)
            }
            actionBlock()
        }
        return didAct
    }
}
