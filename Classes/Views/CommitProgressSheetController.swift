import AppKit
import OSLog // swiftlint:disable:this unused_import

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

@objc(PBCommitProgressSheetController)
final class CommitProgressSheetController: NSWindowController {
    private weak var parentWindow: NSWindow?
    private let progressIndicator = NSProgressIndicator()
    private let phaseLabel = NSTextField(labelWithString: "")
    private let outputTextView = NSTextView()
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "CommitProgressSheet")

    @objc(initWithRepositoryWindowController:)
    convenience init(repositoryWindowController: PBGitWindowController) {
        self.init(parentWindow: repositoryWindowController.window)
    }

    @objc(initWithParentWindow:)
    init(parentWindow: NSWindow?) {
        self.parentWindow = parentWindow
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = NSLocalizedString("Creating Commit", comment: "Interactive commit progress sheet title")
        sheet.isReleasedWhenClosed = false
        sheet.setAccessibilityIdentifier("CommitProgressSheet")
        super.init(window: sheet)
        configureWindow(sheet)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow(_ sheet: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            sheet.standardWindowButton(buttonType)?.isHidden = true
            sheet.standardWindowButton(buttonType)?.isEnabled = false
        }

        guard let contentView = sheet.contentView else { return }
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setAccessibilityIdentifier("CommitProgressSpinner")

        phaseLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        phaseLabel.lineBreakMode = .byTruncatingTail
        phaseLabel.translatesAutoresizingMaskIntoConstraints = false
        phaseLabel.setAccessibilityIdentifier("CommitProgressPhase")

        let phaseRow = NSStackView(views: [progressIndicator, phaseLabel])
        phaseRow.orientation = .horizontal
        phaseRow.alignment = .centerY
        phaseRow.spacing = 10
        phaseRow.translatesAutoresizingMaskIntoConstraints = false

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.isRichText = false
        outputTextView.usesFindBar = true
        outputTextView.font = NSFont.userFixedPitchFont(ofSize: NSFont.smallSystemFontSize)
        outputTextView.textColor = .textColor
        outputTextView.backgroundColor = .textBackgroundColor
        outputTextView.textContainerInset = NSSize(width: 6, height: 6)
        outputTextView.setAccessibilityIdentifier("CommitProgressOutput")

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outputTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(phaseRow)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            phaseRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            phaseRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            phaseRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: phaseRow.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    @objc(beginWithPhase:)
    func begin(withPhase phase: String) {
        updatePhase(phase)
        progressIndicator.startAnimation(nil)
        guard let window, let parentWindow else {
            logger.error("Could not present commit progress sheet without a repository window")
            return
        }
        parentWindow.beginSheet(window)
        logger.info("Presented interactive commit progress sheet")
    }

    @objc(updatePhase:)
    func updatePhase(_ phase: String) {
        phaseLabel.stringValue = phase
        logger.debug("Interactive commit entered phase: \(phase, privacy: .public)")
    }

    @objc(appendOutput:)
    func appendOutput(_ output: String) {
        guard !output.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.userFixedPitchFont(ofSize: NSFont.smallSystemFontSize) as Any,
            .foregroundColor: NSColor.textColor,
        ]
        outputTextView.textStorage?.append(NSAttributedString(string: output, attributes: attributes))
        outputTextView.scrollRangeToVisible(NSRange(location: outputTextView.string.utf16.count, length: 0))
        logger.debug("Appended \(output.utf8.count) bytes of interactive commit output")
    }

    @objc
    func finish() {
        progressIndicator.stopAnimation(nil)
        guard let window else { return }
        if parentWindow?.attachedSheet === window {
            parentWindow?.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        logger.info("Dismissed interactive commit progress sheet")
    }

    override func cancelOperation(_ sender: Any?) {
        logger.debug("Ignored cancellation request for non-cancellable commit progress")
    }
}

// swiftlint:enable unused_declaration
