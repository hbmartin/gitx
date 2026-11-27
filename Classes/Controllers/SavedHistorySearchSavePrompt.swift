import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// The Save Search sheet: asks for a name, explains problems while it is typed, and confirms before replacing a
/// saved search with the same name.
final class SavedHistorySearchSavePrompt: NSObject, NSTextFieldDelegate {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "HistorySearch")

    private let query: HistorySearchQuery
    private let modeLabel: String
    private let store: SavedHistorySearchStore
    private let alert = NSAlert()
    let nameField = NSTextField()
    let messageField = NSTextField(wrappingLabelWithString: "")
    private var window: NSWindow?
    private var completion: (SavedHistorySearch?) -> Void = { _ in }
    /// Keeps the prompt alive while its sheets are open.
    private var presentedSelf: SavedHistorySearchSavePrompt?

    init(query: HistorySearchQuery, modeLabel: String, store: SavedHistorySearchStore) {
        self.query = query
        self.modeLabel = modeLabel
        self.store = store
        super.init()
    }

    private var saveButton: NSButton {
        alert.buttons[0]
    }

    private var queryDescription: String {
        "“\(HistorySearchMenu.displayText(for: query.text))” (\(modeLabel))"
    }

    /// Completes with the saved search, or nil when nothing was saved.
    func present(for window: NSWindow?, completion: @escaping (SavedHistorySearch?) -> Void) {
        self.window = window
        self.completion = completion
        presentedSelf = self

        alert.messageText = NSLocalizedString("Save Search", comment: "Save Search sheet: title")
        alert.informativeText = String(
            format: NSLocalizedString(
                "Save %@ to run it again from any repository window, the gitx tool or AppleScript.",
                comment: "Save Search sheet: explanation; the argument is the quoted search and its mode"
            ),
            queryDescription
        )
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Save Search sheet: save button"))
            .setAccessibilityIdentifier("GitX.SavedSearches.Save")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Save Search sheet: cancel button"))
            .setAccessibilityIdentifier("GitX.SavedSearches.Cancel")
        alert.accessoryView = makeAccessoryView()
        alert.window.initialFirstResponder = nameField
        updateFeedback()
        Self.logger.info("Asking for a name for history search \(query.text, privacy: .private)")
        WindowModalPresenter.present(alert, for: window) { [self] response in
            finishNaming(response)
        }
    }

    private func makeAccessoryView() -> NSView {
        nameField.placeholderString = NSLocalizedString("Name", comment: "Save Search sheet: name field placeholder")
        nameField.setAccessibilityIdentifier("GitX.SavedSearches.Name")
        nameField.setAccessibilityLabel(NSLocalizedString("Saved search name", comment: "Save Search sheet: name field"))
        nameField.delegate = self
        messageField.setAccessibilityIdentifier("GitX.SavedSearches.NameMessage")
        messageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageField.textColor = .systemRed
        messageField.isHidden = true

        let stack = NSStackView(views: [nameField, messageField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        messageField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return stack
    }

    func controlTextDidChange(_: Notification) {
        updateFeedback()
    }

    private func updateFeedback() {
        let feedback = store.library.nameFeedback(for: nameField.stringValue)
        messageField.stringValue = feedback.message ?? ""
        messageField.isHidden = feedback.message == nil
        saveButton.isEnabled = feedback.canSave
    }

    private func finishNaming(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else {
            Self.logger.info("Cancelled saving a history search")
            finish(nil)
            return
        }
        let name = nameField.stringValue
        if let replacedName = store.library.nameFeedback(for: name).replacedName {
            // The naming sheet is still closing; the confirmation follows it.
            DispatchQueue.main.async { [self] in confirmReplacement(of: replacedName, name: name) }
        } else {
            save(name: name, replacingExisting: false)
        }
    }

    private func confirmReplacement(of replacedName: String, name: String) {
        let confirmation = NSAlert()
        confirmation.messageText = String(
            format: NSLocalizedString("Replace “%@”?", comment: "Save Search sheet: replace confirmation title"),
            replacedName
        )
        confirmation.informativeText = String(
            format: NSLocalizedString(
                "The saved search “%@” will search for %@ instead.",
                comment: "Save Search sheet: replace confirmation explanation"
            ),
            replacedName,
            queryDescription
        )
        confirmation.addButton(withTitle: NSLocalizedString("Replace", comment: "Save Search sheet: replace button"))
            .setAccessibilityIdentifier("GitX.SavedSearches.Replace")
        confirmation.addButton(withTitle: NSLocalizedString("Cancel", comment: "Save Search sheet: cancel button"))
        WindowModalPresenter.present(confirmation, for: window) { [self] response in
            if response == .alertFirstButtonReturn {
                save(name: name, replacingExisting: true)
            } else {
                Self.logger.info("Kept the existing saved history search instead of replacing it")
                finish(nil)
            }
        }
    }

    private func save(name: String, replacingExisting: Bool) {
        switch store.save(name: name, query: query, replacingExisting: replacingExisting) {
        case let .success(search):
            finish(search)
        case let .failure(issue):
            Self.logger.error("Could not save a history search: \(issue.message, privacy: .public)")
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = NSLocalizedString("The search could not be saved", comment: "Save Search failure title")
            failure.informativeText = issue.message
            DispatchQueue.main.async { [self] in
                WindowModalPresenter.present(failure, for: window) { [self] _ in finish(nil) }
            }
        }
    }

    private func finish(_ search: SavedHistorySearch?) {
        let completion = completion
        self.completion = { _ in }
        presentedSelf = nil
        completion(search)
    }
}
