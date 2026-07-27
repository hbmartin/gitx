import AppKit

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

/// Adopts the content-view delegate on the staging pane's behalf. Kept
/// private so the generated Swift header never has to textually import the
/// bridging header for the protocol conformance, which would collide with the
/// hand-kept compatibility headers of converted classes.
private final class StagingDiffPaneDelegateAdapter: NSObject, PBNativeContentViewDelegate {
    weak var owner: StagingDiffPaneController?

    func nativeContentView(_ view: PBNativeContentView, performDiffAction action: String, patch: String) {
        owner?.performDiffAction(action, patch: patch, in: view)
    }

    func nativeContentView(
        _ view: PBNativeContentView,
        imageDataForPath path: String,
        section sectionIndex: UInt,
        imageSource: [String: Any]
    ) -> Data? {
        owner?.imageData(forPath: path)
    }
}

/// Owns the staging pane's diff surface: builds staged/unstaged sections with
/// the staging chrome, keeps scroll position across index refreshes, and
/// routes hunk/line actions back into the index.
@objc(PBStagingDiffPaneController)
final class StagingDiffPaneController: NSObject {
    private static let contextLinesKey = "PBStageDiffContextLines"

    @objc let contentView: PBNativeContentView
    private unowned let repository: PBGitRepository
    private var currentRequests: [StagingDiffRequest] = []
    private let delegateAdapter = StagingDiffPaneDelegateAdapter()

    @objc var contextLines: UInt {
        didSet {
            guard contextLines != oldValue else { return }
            UserDefaults.standard.set(Int(contextLines), forKey: Self.contextLinesKey)
            rerenderCurrentRequests()
        }
    }

    @objc var ignoreWhitespace: Bool {
        didSet {
            guard ignoreWhitespace != oldValue else { return }
            ApplicationSettings.stagingIgnoreWhitespace = ignoreWhitespace
            rerenderCurrentRequests()
        }
    }

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        contentView = PBNativeContentView(frame: .zero)
        let savedContext = UserDefaults.standard.object(forKey: Self.contextLinesKey) as? Int
        contextLines = UInt(max(0, savedContext ?? 3))
        ignoreWhitespace = ApplicationSettings.stagingIgnoreWhitespace
        super.init()
        delegateAdapter.owner = self
        contentView.delegate = delegateAdapter
        contentView.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc(renderRequests:)
    func render(_ requests: [StagingDiffRequest]) {
        currentRequests = requests
        guard !requests.isEmpty else {
            contentView.showMessage(NSLocalizedString(
                "No file selected",
                comment: "Placeholder in the staging diff pane when no file is selected"
            ))
            return
        }
        NSLog("[GitX] Rendering %ld staging diff section(s)", requests.count)
        contentView.showDiffSections(
            requests.map(section(for:)),
            cacheIdentifier: cacheIdentifier(for: requests),
            preserveScrollPosition: true
        )
    }

    @objc func rerenderCurrentRequests() {
        render(currentRequests)
    }

    @objc(showStateMessage:)
    func showStateMessage(_ message: String) {
        currentRequests = []
        contentView.showMessage(message)
    }

    private func section(for request: StagingDiffRequest) -> [String: Any] {
        let file = request.file
        var diff = repository.index.diff(
            for: file,
            staged: request.staged,
            contextLines: contextLines,
            ignoreWhitespace: ignoreWhitespace
        ) ?? ""
        let isUntracked = file.status == .NEW && !file.hasStagedChanges
        if isUntracked, !diff.isEmpty {
            // Untracked files come back as raw contents; wrap them into a
            // synthetic new-file diff so their hunks and lines are stageable.
            diff = SyntheticUntrackedDiffFormatterBridge.diff(path: file.path, contents: diff)
        }
        let sideTitle = request.staged
            ? NSLocalizedString("Staged", comment: "Staging diff section prefix for staged changes")
            : NSLocalizedString("Unstaged", comment: "Staging diff section prefix for unstaged changes")
        return [
            PBNativeSectionTitleKey: "\(sideTitle) — \(file.path)",
            PBNativeSectionPathKey: file.path,
            PBNativeSectionTextKey: diff,
            PBNativeSectionContextKey: request.staged ? "staged" : "unstaged",
            PBNativeSectionStagingChromeKey: true,
        ]
    }

    private func cacheIdentifier(for requests: [StagingDiffRequest]) -> String {
        let selection = requests
            .map { "\($0.staged ? "s" : "u"):\($0.file.path)" }
            .joined(separator: "|")
        return "staging:\(selection):ctx\(contextLines):ws\(ignoreWhitespace ? 1 : 0)"
    }

    // MARK: Content-view actions (dispatched via the private delegate adapter)

    fileprivate func performDiffAction(_ action: String, patch: String, in view: PBNativeContentView) {
        switch action {
        case "stage":
            NSLog("[GitX] Applying a partial stage patch from the staging pane")
            repository.index.applyPatch(patch, stage: true, reverse: false)
        case "unstage":
            NSLog("[GitX] Applying a partial unstage patch from the staging pane")
            repository.index.applyPatch(patch, stage: true, reverse: true)
        case "discard":
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Discard hunk", comment: "Title of the discard hunk confirmation")
            alert.informativeText = NSLocalizedString(
                "Are you sure you wish to discard this hunk? This operation cannot be undone.",
                comment: "Informative text of the discard hunk confirmation"
            )
            alert.addButton(withTitle: NSLocalizedString("Discard", comment: "Confirm button of the discard hunk confirmation"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button of the discard hunk confirmation"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                NSLog("[GitX] Discarding a hunk from the staging pane")
                self?.repository.index.applyPatch(patch, stage: false, reverse: true)
            }
        default:
            NSLog("[GitX] Ignoring unknown staging diff action: %@", action)
        }
    }

    fileprivate func imageData(forPath path: String) -> Data? {
        if let workingDirectoryURL = repository.workingDirectoryURL(),
           let data = try? Data(contentsOf: workingDirectoryURL.appendingPathComponent(path)),
           !data.isEmpty
        {
            return data
        }
        let task = repository.task(withArguments: ["show", ":" + path])
        guard (try? task.launch()) != nil else { return nil }
        let data = task.standardOutputData
        return data.isEmpty ? nil : data
    }
}

// swiftlint:enable unused_declaration
