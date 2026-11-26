import AppKit

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Presents alerts and folder choices as sheets on their originating window, so a question about one
/// repository window never blocks the rest of the app. Without a window, alerts fall back to an
/// app-modal run and folder choices to a free-standing panel.
@MainActor
enum WindowModalPresenter {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "WindowModal")

    /// Replaces the folder panel in tests; it receives the prompt and window and completes with a URL or nil.
    static var directoryChooserOverride: ((_ prompt: String, _ window: NSWindow?, _ completion: @escaping (URL?) -> Void) -> Void)?

    static func present(
        _ alert: NSAlert,
        for window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        if let window {
            logger.debug("Presenting alert as a sheet: \(alert.messageText, privacy: .public)")
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            logger.debug("Presenting a windowless alert modally: \(alert.messageText, privacy: .public)")
            completion(alert.runModal())
        }
    }

    /// Asks for one folder. Completes with nil when the person cancels.
    static func chooseDirectory(
        prompt: String,
        for window: NSWindow?,
        completion: @escaping (URL?) -> Void
    ) {
        if let directoryChooserOverride {
            directoryChooserOverride(prompt, window, completion)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let url = response == .OK ? panel.url : nil
            logger.info("Folder choice finished: chosen=\(url != nil, privacy: .public)")
            completion(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
