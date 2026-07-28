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

/// Produces diff text from immutable request values on the coordinator's
/// serial queue. The service owns the Git command execution; synthetic
/// untracked diffs read only the snapshotted working-directory URL.
// swift6-safety-justification: The wrapped service is confined to one serial queue and receives only Sendable snapshots.
private final nonisolated class IndexMutationStagingDiffProducer: @unchecked Sendable {
    // Strong on purpose: production runs on the coordinator's background queue and can
    // outlive the pane, while the mutation service reaches the repository only through
    // unowned references. This keeps the repository alive until queued work drains.
    // It is not a cycle — the repository never owns the staging pane.
    private let repository: PBGitRepository
    private let mutationService: IndexMutationService

    init(repository: PBGitRepository, runner: IndexCommandRunning? = nil) {
        self.repository = repository
        mutationService = if let runner {
            IndexMutationService(repository: repository, runner: runner)
        } else {
            IndexMutationService(repository: repository)
        }
    }

    func produce(_ request: StagingDiffLoadRequest) -> StagingDiffProduction {
        if request.syntheticUntracked {
            return syntheticUntrackedDiff(for: request)
        }

        var error: NSError?
        if let diff = mutationService.diff(
            forPath: request.path,
            status: request.status,
            hasStagedChanges: request.hasStagedChanges,
            staged: request.staged,
            parentTree: request.parentTree,
            contextLines: request.contextLines,
            ignoreWhitespace: false,
            error: &error
        ) {
            return .success(diff)
        }
        if let error {
            return .failure(detail(for: error))
        }
        return .failure(NSLocalizedString(
            "Git returned no diff data.",
            comment: "Detail shown when Git fails to return a selected file's diff"
        ))
    }

    private func syntheticUntrackedDiff(
        for request: StagingDiffLoadRequest
    ) -> StagingDiffProduction {
        guard let workingDirectoryURL = request.workingDirectoryURL else {
            return .failure(NSLocalizedString(
                "The repository has no working directory.",
                comment: "Detail shown when an untracked file diff cannot be loaded"
            ))
        }
        let fileURL = workingDirectoryURL.appendingPathComponent(request.path)
        do {
            let fileManager = FileManager()
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            let contents: String
            let fileMode: SyntheticUntrackedFileMode
            switch fileType {
            case .typeRegular:
                var encoding = String.Encoding.utf8
                contents = try String(contentsOf: fileURL, usedEncoding: &encoding)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                fileMode = permissions & 0o111 == 0 ? .regular : .executable
            case .typeSymbolicLink:
                contents = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                fileMode = .symbolicLink
            default:
                throw NSError(
                    domain: "PBStagingDiffLoadError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(
                        format: NSLocalizedString(
                            "The worktree object at %@ is not a regular file or symbolic link.",
                            comment: "Detail shown for an unsupported untracked worktree object"
                        ),
                        request.path
                    )]
                )
            }
            NSLog(
                "[GitX] Building a synthetic untracked diff for %@ with mode %@",
                request.path,
                fileMode.gitMode
            )
            return .success(SyntheticUntrackedDiffFormatterBridge.diff(
                path: request.path,
                contents: contents,
                fileMode: fileMode
            ))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func detail(for error: NSError) -> String {
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason,
           reason != error.localizedDescription
        {
            parts.append(reason)
        }
        if let status = error.userInfo[PBTaskTerminationStatusKey] as? NSNumber {
            parts.append(String(
                format: NSLocalizedString(
                    "Exit status: %@",
                    comment: "Git process exit status in a staging diff failure"
                ),
                status
            ))
        }
        if let output = error.userInfo[PBTaskTerminationOutputKey] as? String {
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                parts.append(trimmedOutput)
            }
        }
        return parts.joined(separator: "\n")
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
    private let loadCoordinator: StagingDiffLoadCoordinator

    @objc var contextLines: UInt {
        didSet {
            guard contextLines != oldValue else { return }
            UserDefaults.standard.set(Int(contextLines), forKey: Self.contextLinesKey)
            rerenderCurrentRequests()
        }
    }

    @objc(initWithRepository:)
    convenience init(repository: PBGitRepository) {
        self.init(repository: repository, diffRunner: nil)
    }

    @objc(initWithRepository:diffRunner:)
    init(repository: PBGitRepository, diffRunner: IndexCommandRunning?) {
        self.repository = repository
        contentView = PBNativeContentView(frame: .zero)
        let producer = IndexMutationStagingDiffProducer(repository: repository, runner: diffRunner)
        loadCoordinator = StagingDiffLoadCoordinator(producer: producer.produce)
        let savedContext = UserDefaults.standard.object(forKey: Self.contextLinesKey) as? Int
        contextLines = UInt(max(0, savedContext ?? 3))
        super.init()
        delegateAdapter.owner = self
        contentView.delegate = delegateAdapter
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLog("[GitX] Staging diffs include whitespace changes for patch integrity")
    }

    @objc(renderRequests:)
    func render(_ requests: [StagingDiffRequest]) {
        currentRequests = requests
        guard !requests.isEmpty else {
            loadCoordinator.invalidate()
            contentView.showMessage(NSLocalizedString(
                "No file selected",
                comment: "Placeholder in the staging diff pane when no file is selected"
            ))
            return
        }
        let index = repository.index
        let parentTree = index.parentTree
        let workingDirectoryURL = repository.workingDirectoryURL()
        let contextLines = contextLines
        let snapshots = requests.map { request in
            let file = request.file
            return StagingDiffLoadRequest(
                path: file.path,
                status: file.status.rawValue,
                hasStagedChanges: file.hasStagedChanges,
                staged: request.staged,
                parentTree: parentTree,
                contextLines: contextLines,
                workingDirectoryURL: workingDirectoryURL,
                syntheticUntracked: file.status == .NEW && !file.hasStagedChanges
            )
        }
        NSLog("[GitX] Scheduling %ld staging diff section(s)", snapshots.count)
        loadCoordinator.schedule(snapshots) { [weak self] output in
            guard let self else { return }
            contentView.showDiffSections(
                output.sections.map(nativeSection(from:)),
                cacheIdentifier: output.cacheIdentifier,
                preserveScrollPosition: true
            )
        }
    }

    @objc func rerenderCurrentRequests() {
        render(currentRequests)
    }

    @objc(showStateMessage:)
    func showStateMessage(_ message: String) {
        currentRequests = []
        loadCoordinator.invalidate()
        contentView.showMessage(message)
    }

    private func nativeSection(from descriptor: StagingDiffSectionDescriptor) -> [String: Any] {
        return [
            PBNativeSectionTitleKey: descriptor.title,
            PBNativeSectionPathKey: descriptor.path,
            PBNativeSectionTextKey: descriptor.text,
            PBNativeSectionContextKey: descriptor.context,
            PBNativeSectionStagingChromeKey: descriptor.stagingChrome,
        ]
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
