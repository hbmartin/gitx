import AppKit
import ForgeKit
import OSLog // swiftlint:disable:this unused_import

@MainActor
final class ForgePullRequestSheetController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    enum Mode {
        case create(
            preparation: RepositoryPullRequestCreationPreparation,
            initialForms: RepositoryPullRequestInitialForms
        )
        case edit(
            accountID: ForgeAccountID,
            snapshot: ForgePullRequestEditableSnapshot,
            destination: ForgeDestination
        )
        case recovery(destination: ForgeDestination)
    }

    enum Submission {
        case create(accountID: ForgeAccountID, form: ForgePullRequestCreationForm)
        case edit(accountID: ForgeAccountID, edit: ForgePullRequestEdit, destination: ForgeDestination)
    }

    var onSubmit: ((Submission) -> Void)?
    var onCancel: ((ForgeDraftContent) -> Void)?
    var onDiscard: (() -> Void)?
    var onDraftChanged: ((ForgeDraftContent) -> Void)?
    var onSaveRecovery: ((ForgeDraftContent) -> Void)?
    var onCopyRecovery: ((ForgeDraftContent) -> Void)?

    private let mode: Mode
    private let titleField = NSTextField()
    private let bodyTextView = NSTextView()
    private let previewContainer = NSView()
    private let writePreviewControl = NSSegmentedControl(labels: ["Write", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let draftButton = NSButton(checkboxWithTitle: "Draft", target: nil, action: nil)
    private let templatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let submitButton = NSButton(title: "Create Pull Request", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard Draft", target: nil, action: nil)
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PullRequestSheet")
    private var selectedForm: ForgePullRequestCreationForm?
    private var previewView: ForgeMarkdownNativeView?
    private var hasFinished = false
    private var recoverySavedContent: ForgeDraftContent?
    private let recoveryNotice = NSTextField(wrappingLabelWithString: "The remote edit did not complete. This recovered text has not been saved as a draft.")
    private var isRecovery: Bool {
        if case .recovery = mode {
            return true
        }
        return false
    }

    init(mode: Mode, restoredContent: ForgeDraftContent? = nil, recoveryMessage: String? = nil) {
        self.mode = mode
        if let recoveryMessage {
            recoveryNotice.stringValue = recoveryMessage
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = switch mode {
        case .create: "Create Pull Request"
        case .edit: "Edit Pull Request"
        case .recovery: "Recover Pull Request Edit"
        }
        super.init(window: panel)
        panel.delegate = self
        configure(restoredContent: restoredContent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ForgePullRequestSheetController is built in code")
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(titleField)
        logger.notice("Presented native Pull Request editor")
    }

    private func configure(restoredContent: ForgeDraftContent?) {
        guard let contentView = window?.contentView else { return }

        let identityStack = NSStackView()
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 3
        identityStack.addArrangedSubview(identityLabel())
        if isRecovery {
            recoveryNotice.setAccessibilityIdentifier("GitX.PullRequest.Recovery.Notice")
            recoveryNotice.textColor = .secondaryLabelColor
            identityStack.addArrangedSubview(recoveryNotice)
        }

        templatePopup.target = self
        templatePopup.action = #selector(templateChanged(_:))
        templatePopup.setAccessibilityIdentifier("GitX.PullRequest.Template")
        templatePopup.setAccessibilityLabel("Pull Request template")

        titleField.delegate = self
        titleField.placeholderString = "Pull Request title"
        titleField.setAccessibilityIdentifier("GitX.PullRequest.Title")
        titleField.setAccessibilityLabel("Pull Request title")

        bodyTextView.delegate = self
        bodyTextView.isRichText = false
        bodyTextView.allowsUndo = true
        bodyTextView.isContinuousSpellCheckingEnabled = true
        bodyTextView.font = NSFont.systemFont(ofSize: 13)
        bodyTextView.setAccessibilityIdentifier("GitX.PullRequest.Body")
        bodyTextView.setAccessibilityLabel("Pull Request body")
        let bodyScroll = NSScrollView()
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.documentView = bodyTextView
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.isHidden = true
        previewContainer.setAccessibilityIdentifier("GitX.PullRequest.Preview")

        writePreviewControl.selectedSegment = 0
        writePreviewControl.target = self
        writePreviewControl.action = #selector(writePreviewChanged(_:))
        writePreviewControl.setAccessibilityIdentifier("GitX.PullRequest.WritePreview")
        writePreviewControl.setAccessibilityLabel("Pull Request body mode")

        draftButton.state = .off
        draftButton.isHidden = !isCreate
        draftButton.target = self
        draftButton.action = #selector(fieldChanged(_:))
        draftButton.setAccessibilityIdentifier("GitX.PullRequest.Draft")
        draftButton.setAccessibilityLabel("Create as Draft Pull Request")

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityIdentifier("GitX.PullRequest.Cancel")

        discardButton.target = self
        discardButton.action = #selector(discard(_:))
        discardButton.setAccessibilityIdentifier("GitX.PullRequest.DiscardDraft")
        discardButton.setAccessibilityLabel("Discard Pull Request draft")

        submitButton.keyEquivalent = "\r"
        submitButton.target = self
        submitButton.action = #selector(submit(_:))
        submitButton.setAccessibilityIdentifier("GitX.PullRequest.Submit")
        submitButton.setAccessibilityLabel(isCreate ? "Create Pull Request" : "Save Pull Request")
        if isRecovery {
            discardButton.title = "Copy"
            discardButton.action = #selector(copyRecovery(_:))
            discardButton.setAccessibilityIdentifier("GitX.PullRequest.Recovery.Copy")
            discardButton.setAccessibilityLabel("Copy recovered title and body")
            submitButton.title = "Save Draft…"
            submitButton.setAccessibilityIdentifier("GitX.PullRequest.Recovery.SaveDraft")
            submitButton.setAccessibilityLabel("Save recovered text as a draft")
            cancelButton.title = "Close"
            cancelButton.setAccessibilityIdentifier("GitX.PullRequest.Recovery.Close")
        }

        let topControls = NSStackView(views: [writePreviewControl, NSView(), draftButton])
        topControls.orientation = .horizontal
        topControls.alignment = .centerY
        topControls.spacing = 8
        let buttons = NSStackView(views: [discardButton, NSView(), cancelButton, submitButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let form = NSStackView(views: [identityStack, templatePopup, titleField, topControls, bodyScroll, previewContainer, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        form.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            form.topAnchor.constraint(equalTo: contentView.topAnchor),
            form.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            identityStack.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            templatePopup.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            titleField.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            topControls.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            bodyScroll.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            previewContainer.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            buttons.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
        ])

        installInitialContent(restoredContent: restoredContent)
        updateSubmitEligibility()
    }

    private var isCreate: Bool {
        if case .create = mode {
            return true
        }
        return false
    }

    private func identityLabel() -> NSTextField {
        let text = switch mode {
        case let .create(preparation, _):
            "\(preparation.head.repository.owner):\(preparation.head.name.value) → \(preparation.repository.owner):\(preparation.base.name.value)"
        case let .edit(_, snapshot, _):
            "Pull Request #\(snapshot.number.rawValue) • server version from \(Self.timestamp(snapshot.updatedAt))"
        case .recovery:
            "Recovered submitted text • stored drafts remain unchanged"
        }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("GitX.PullRequest.Identity")
        return label
    }

    private func installInitialContent(restoredContent: ForgeDraftContent?) {
        switch mode {
        case let .create(_, initialForms):
            let index = min(initialForms.selectedTemplateIndex ?? 0, initialForms.forms.count - 1)
            selectedForm = initialForms.forms[index]
            if initialForms.templateNames.isEmpty {
                templatePopup.isHidden = true
            } else {
                templatePopup.addItems(withTitles: initialForms.templateNames)
                for (offset, form) in initialForms.forms.enumerated() {
                    templatePopup.item(at: offset)?.representedObject = form.bodyMarkdown
                }
                templatePopup.selectItem(at: index)
            }
            titleField.stringValue = restoredContent?.title ?? initialForms.forms[index].title
            bodyTextView.string = restoredContent?.body ?? initialForms.forms[index].bodyMarkdown
            draftButton.state = .off
        case let .edit(_, snapshot, _):
            templatePopup.isHidden = true
            titleField.stringValue = restoredContent?.title ?? snapshot.title
            bodyTextView.string = restoredContent?.body ?? snapshot.bodyMarkdown
            submitButton.title = "Save"
        case .recovery:
            templatePopup.isHidden = true
            titleField.stringValue = restoredContent?.title ?? ""
            bodyTextView.string = restoredContent?.body ?? ""
        }
    }

    private func currentDraftContent() -> ForgeDraftContent {
        ForgeDraftContent(title: titleField.stringValue, body: bodyTextView.string)
    }

    private func currentCreationForm() throws -> ForgePullRequestCreationForm {
        guard let selectedForm else {
            throw RepositoryPullRequestServiceError.draftUnavailable
        }
        return try selectedForm.editing(
            title: titleField.stringValue,
            bodyMarkdown: bodyTextView.string,
            isDraft: draftButton.state == .on
        )
    }

    private func updateSubmitEligibility() {
        submitButton.isEnabled = isRecovery || titleField.stringValue.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
    }

    @objc private func templateChanged(_: Any?) {
        guard case let .create(_, initialForms) = mode,
              templatePopup.indexOfSelectedItem >= 0,
              templatePopup.indexOfSelectedItem < initialForms.forms.count
        else { return }
        selectedForm = initialForms.forms[templatePopup.indexOfSelectedItem]
        bodyTextView.string = selectedForm?.bodyMarkdown ?? ""
        onDraftChanged?(currentDraftContent())
        logger.info("Changed Pull Request template selection")
    }

    @objc private func writePreviewChanged(_: Any?) {
        let showsPreview = writePreviewControl.selectedSegment == 1
        previewContainer.isHidden = !showsPreview
        bodyTextView.enclosingScrollView?.isHidden = showsPreview
        guard showsPreview else { return }
        previewView?.removeFromSuperview()
        let revision: ForgeRevision
        switch mode {
        case let .create(preparation, _):
            revision = .branch(preparation.base.name)
        case .edit, .recovery:
            guard let head = try? ForgeRefName("HEAD") else { return }
            revision = .opaque(head)
        }
        let context = ForgeMarkdownContext(
            repository: destination.repository,
            location: .repository(defaultBranch: revision)
        )
        let document = ForgeMarkdownSanitizer().sanitize(bodyTextView.string, context: context)
        let preview = ForgeMarkdownNativeView(document: document)
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
        previewView = preview
        logger.debug("Rendered sanitized Pull Request Markdown preview")
    }

    @objc private func fieldChanged(_: Any?) {
        updateSubmitEligibility()
        onDraftChanged?(currentDraftContent())
    }

    func controlTextDidChange(_: Notification) {
        fieldChanged(nil)
    }

    func textDidChange(_: Notification) {
        fieldChanged(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        finishCancellation()
        return false
    }

    @objc private func submit(_: Any?) {
        if isRecovery {
            onSaveRecovery?(currentDraftContent())
            return
        }
        do {
            let submission: Submission = switch mode {
            case let .create(preparation, _):
                try .create(accountID: preparation.accountID, form: currentCreationForm())
            case let .edit(accountID, snapshot, destination):
                try .edit(
                    accountID: accountID,
                    edit: ForgePullRequestEdit(
                        snapshot: snapshot,
                        title: titleField.stringValue,
                        bodyMarkdown: bodyTextView.string
                    ),
                    destination: destination
                )
            case .recovery:
                throw RepositoryPullRequestServiceError.draftUnavailable
            }
            guard !hasFinished else { return }
            hasFinished = true
            closeSheet()
            onSubmit?(submission)
        } catch {
            NSSound.beep()
            window?.makeFirstResponder(titleField)
        }
    }

    @objc private func cancel(_: Any?) {
        finishCancellation()
    }

    @objc private func discard(_: Any?) {
        guard !hasFinished else { return }
        hasFinished = true
        closeSheet()
        onDiscard?()
        logger.info("Discarded Pull Request editor draft")
    }

    private func finishCancellation() {
        guard !hasFinished else { return }
        if isRecovery, recoverySavedContent != currentDraftContent(), let window {
            let alert = NSAlert()
            alert.window.setAccessibilityIdentifier("GitX.PullRequest.Recovery.CloseConfirmation")
            alert.messageText = "Close Without Saving?"
            alert.informativeText = "This recovered text has not been saved as a draft. Copy or save it before closing if you want to keep it."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Close Without Saving")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.finishClosingRecovery()
            }
            return
        }
        finishClosingRecovery()
    }

    private func finishClosingRecovery() {
        guard !hasFinished else { return }
        hasFinished = true
        let content = currentDraftContent()
        closeSheet()
        onCancel?(content)
        logger.info("Cancelled Pull Request editor with draft preserved")
    }

    @objc private func copyRecovery(_: Any?) {
        let content = currentDraftContent()
        if let onCopyRecovery {
            onCopyRecovery(content)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((content.title ?? "") + "\n\n" + content.body, forType: .string)
        }
    }

    func markRecoverySaved(_ content: ForgeDraftContent) {
        recoverySavedContent = content
        recoveryNotice.stringValue = "Saved as a draft. Further edits remain unsaved until you choose Save Draft again."
    }

    func invalidatePresentation() {
        hasFinished = true
        if let window, let confirmation = window.attachedSheet {
            window.endSheet(confirmation, returnCode: .abort)
            confirmation.orderOut(nil)
        }
        closeSheet()
    }

    private func closeSheet() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    private static func timestamp(_ date: Date) -> String {
        ForgeReadDateFormatting.dateAndTime(date)
    }

    private var destination: ForgeDestination {
        switch mode {
        case let .create(preparation, _):
            .repository(preparation.repository)
        case let .edit(_, _, destination):
            destination
        case let .recovery(destination):
            destination
        }
    }
}
