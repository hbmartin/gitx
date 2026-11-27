import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// The status bar's Git LFS Details sheet: what the label means, the files not downloaded, and Download All….
@MainActor
final class RepositoryLFSDetailsSheet: NSObject {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "LFS")
    static let visiblePathLimit = 200

    let alert = NSAlert()
    let pathList = NSTextView()
    private let snapshot: RepositoryLFSStatusSnapshot
    private var presentedSelf: RepositoryLFSDetailsSheet?

    init(snapshot: RepositoryLFSStatusSnapshot) {
        self.snapshot = snapshot
        super.init()
        alert.messageText = NSLocalizedString("Git LFS", comment: "Git LFS details sheet: title")
        alert.informativeText = LFSPresentation.detailsText(summary: snapshot.summary, tool: snapshot.tool)
        if canDownloadAll {
            alert.addButton(withTitle: NSLocalizedString("Download All…", comment: "Git LFS details: download every object"))
                .setAccessibilityIdentifier("GitX.LFS.Details.DownloadAll")
        }
        alert.addButton(withTitle: NSLocalizedString("Close", comment: "Git LFS details: close"))
            .setAccessibilityIdentifier("GitX.LFS.Details.Close")
        alert.window.setAccessibilityIdentifier("GitX.LFS.Details")
        if !snapshot.summary.notDownloadedPaths.isEmpty {
            alert.accessoryView = makePathList()
        }
    }

    var canDownloadAll: Bool {
        snapshot.tool.isAvailable && !snapshot.summary.notDownloadedPaths.isEmpty
    }

    /// Completes with true when the user chose Download All….
    func present(for window: NSWindow?, completion: @escaping (Bool) -> Void) {
        presentedSelf = self
        Self.logger.info("Showing Git LFS details: \(snapshot.summary.notDownloadedPaths.count) files not downloaded")
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            presentedSelf = nil
            completion(canDownloadAll && response == .alertFirstButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func makePathList() -> NSView {
        let paths = snapshot.summary.notDownloadedPaths
        var lines = paths.prefix(Self.visiblePathLimit).joined(separator: "\n")
        if paths.count > Self.visiblePathLimit {
            lines += "\n" + String(
                format: NSLocalizedString("…and %ld more", comment: "Git LFS details: more paths than listed"),
                paths.count - Self.visiblePathLimit
            )
        }
        pathList.string = lines
        pathList.isEditable = false
        pathList.isSelectable = true
        pathList.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathList.textContainerInset = NSSize(width: 4, height: 4)
        pathList.setAccessibilityIdentifier("GitX.LFS.Details.Paths")
        pathList.setAccessibilityLabel(NSLocalizedString("Files not downloaded", comment: "Git LFS details: path list"))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = pathList
        pathList.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        pathList.autoresizingMask = [.width]
        return scrollView
    }
}

/// Confirms a download before it starts, naming what it will fetch.
@MainActor
enum RepositoryLFSDownloadConfirmation {
    static func alert(for plan: LFSDownloadPlan, summary: LFSWorktreeSummary) -> NSAlert {
        let alert = NSAlert()
        let count = plan.paths?.count ?? summary.notDownloadedPaths.count
        alert.messageText = count == 1
            ? NSLocalizedString("Download Git LFS content for 1 file?", comment: "Git LFS download confirmation: one file")
            : String(format: NSLocalizedString("Download Git LFS content for %ld files?", comment: "Git LFS download confirmation"), count)
        alert.informativeText = NSLocalizedString(
            "Half Dark downloads the content for the current checkout from the remote, then writes it into the working tree. "
                + "You can cancel while it downloads; writing the files cannot be interrupted.",
            comment: "Git LFS download confirmation: explanation"
        )
        alert.addButton(withTitle: NSLocalizedString("Download", comment: "Git LFS download confirmation: start"))
            .setAccessibilityIdentifier("GitX.LFS.Confirm.Download")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Git LFS download confirmation: cancel"))
            .setAccessibilityIdentifier("GitX.LFS.Confirm.Cancel")
        return alert
    }
}

/// The progress sheet: determinate while git-lfs reports progress, then “Finishing…” with Cancel disabled.
@MainActor
final class RepositoryLFSDownloadSheet: NSObject {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled], backing: .buffered, defer: true)
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Git LFS download: cancel"), target: nil, action: nil)
    private var operation: RepositoryLFSDownloadOperation?
    private weak var hostWindow: NSWindow?
    private var presentedSelf: RepositoryLFSDownloadSheet?
    private var completion: ((RepositoryLFSDownloadOperation.Phase) -> Void)?

    override init() {
        super.init()
        buildInterface()
    }

    /// Starts the operation the factory makes, showing its progress; completes with its final phase.
    func run(
        for window: NSWindow?,
        operation makeOperation: (@escaping (RepositoryLFSDownloadOperation.Phase) -> Void) -> RepositoryLFSDownloadOperation,
        completion: @escaping (RepositoryLFSDownloadOperation.Phase) -> Void
    ) {
        presentedSelf = self
        hostWindow = window
        self.completion = completion
        let operation = makeOperation { [weak self] phase in self?.show(phase) }
        self.operation = operation
        window?.beginSheet(panel)
        operation.start()
    }

    func show(_ phase: RepositoryLFSDownloadOperation.Phase) {
        switch phase {
        case let .fetching(fraction, detail):
            titleLabel.stringValue = NSLocalizedString("Downloading Git LFS content…", comment: "Git LFS download: fetching")
            detailLabel.stringValue = detail ?? NSLocalizedString("Contacting the remote…", comment: "Git LFS download: no progress yet")
            if let fraction {
                progress.isIndeterminate = false
                progress.doubleValue = fraction * 100
            } else {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
            cancelButton.isEnabled = true
        case .finishing:
            titleLabel.stringValue = NSLocalizedString("Finishing…", comment: "Git LFS download: writing the checkout")
            detailLabel.stringValue = NSLocalizedString(
                "Writing the downloaded files into the working tree.",
                comment: "Git LFS download: checkout explanation"
            )
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            cancelButton.isEnabled = false
            AccessibilityNotifier.announce(titleLabel.stringValue, from: panel)
        case .finished, .failed, .cancelled:
            progress.stopAnimation(nil)
            close()
            presentedSelf = nil
            let completion = completion
            self.completion = nil
            completion?(phase)
        }
    }

    @objc func cancel(_: Any?) {
        operation?.cancel()
    }

    private func close() {
        hostWindow?.endSheet(panel)
        panel.orderOut(nil)
    }

    private func buildInterface() {
        panel.title = NSLocalizedString("Git LFS", comment: "Git LFS download sheet title")
        panel.setAccessibilityIdentifier("GitX.LFS.Download")
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.setAccessibilityIdentifier("GitX.LFS.Download.Title")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setAccessibilityIdentifier("GitX.LFS.Download.Detail")
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = true
        progress.setAccessibilityIdentifier("GitX.LFS.Download.Progress")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityIdentifier("GitX.LFS.Download.Cancel")
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.setViews([cancelButton], in: .trailing)
        let content = NSStackView(views: [titleLabel, progress, detailLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            detailLabel.widthAnchor.constraint(equalTo: progress.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: progress.widthAnchor),
        ])
        panel.contentView = contentView
    }
}

/// VoiceOver announcements for the LFS sheets.
@MainActor
enum AccessibilityNotifier {
    static func announce(_ message: String, from element: Any) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
