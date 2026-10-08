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
        owner?.performDiffAction(action, patch: patch, context: [:], in: view)
    }

    func nativeContentView(_ view: PBNativeContentView, performDiffAction action: String,
                           patch: String, actionContext: [String: Any])
    {
        owner?.performDiffAction(action, patch: patch, context: actionContext, in: view)
    }

    nonisolated func nativeContentView(
        _ view: PBNativeContentView,
        imageDataForPath path: String,
        section sectionIndex: UInt,
        imageSource: [String: Any]
    ) -> Data? {
        // NativeDiffRenderer requests images on its operation queue. Capture
        // the current request identity on main, then perform file and Git IO
        // on the caller's queue without reading the pane's mutable state.
        let lookup: StagingImageLookup?
        if Thread.isMainThread {
            // swift6-safety-justification: The explicit main-thread branch guarantees AppKit and request-state access occurs on the main actor.
            lookup = MainActor.assumeIsolated {
                owner?.imageLookup(forPath: path, sectionIndex: Int(sectionIndex))
            }
        } else {
            lookup = DispatchQueue.main.sync {
                NSLog("[GitX] Resolving a staging image callback from the renderer queue")
                return owner?.imageLookup(forPath: path, sectionIndex: Int(sectionIndex))
            }
        }
        return lookup?.data()
    }
}

/// Captured only after main-actor validation of the current raw filename.
// swift6-safety-justification: Each lookup transfers its newly created, uniquely owned PBTask once to the synchronous image callback; the task is never shared or reused, and the URL is immutable.
private final nonisolated class StagingImageLookup: @unchecked Sendable {
    private let workingFileURL: URL?
    private let indexTask: PBTask

    init(workingFileURL: URL?, indexTask: PBTask) {
        self.workingFileURL = workingFileURL
        self.indexTask = indexTask
    }

    func data() -> Data? {
        NSLog("[GitX] Reading staging image data on %@", Thread.isMainThread ? "main" : "renderer queue")
        if let workingFileURL,
           let data = try? Data(contentsOf: workingFileURL), !data.isEmpty
        {
            return data
        }
        guard (try? indexTask.launch()) != nil else { return nil }
        let data = indexTask.standardOutputData
        return data.isEmpty ? nil : data
    }
}

/// Produces diff text from immutable request values on the coordinator's
/// serial queue. The service owns the Git command execution; synthetic
/// untracked diffs read only the snapshotted working-directory URL.
// swift6-safety-justification: The wrapped service is confined to one serial queue and receives only Sendable snapshots.
private final nonisolated class IndexMutationStagingDiffProducer: @unchecked Sendable {
    // Strong on purpose: production runs on the coordinator's background queue and can
    // outlive the pane, while the mutation service reaches the repository only through
    // weak references. This keeps the repository alive until queued work drains.
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
            forRawPath: request.rawPath,
            displayPath: request.path,
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
        guard let safePath = IndexFilePresentation.safePath(rawPath: request.rawPath) else {
            return .failure(NSLocalizedString("This filename contains bytes that cannot be represented for preview.", comment: "Unsupported raw filename preview"))
        }
        guard let workingDirectoryURL = request.workingDirectoryURL else {
            return .failure(NSLocalizedString(
                "The repository has no working directory.",
                comment: "Detail shown when an untracked file diff cannot be loaded"
            ))
        }
        let fileURL = workingDirectoryURL.appendingPathComponent(safePath)
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
                path: safePath,
                contents: contents,
                fileMode: fileMode
            ))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func detail(for error: NSError) -> String {
        IndexOperationErrorPresentation.detail(for: error)
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
    private var currentLoadIdentity: UUID?
    private var currentRequests: [StagingDiffRequest] = []
    private var displayedRequests: [StagingDiffLoadRequest] = []
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
        let loadIdentity = UUID()
        currentLoadIdentity = loadIdentity
        currentRequests = requests
        guard !requests.isEmpty else {
            loadCoordinator.invalidate()
            displayedRequests = []
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
                rawPath: file.rawPath,
                status: (request.staged ? file.stagedStatus : file.worktreeStatus).rawValue,
                hasStagedChanges: file.hasStagedChanges,
                staged: request.staged,
                parentTree: parentTree,
                contextLines: contextLines,
                workingDirectoryURL: workingDirectoryURL,
                syntheticUntracked: !request.staged && file.worktreeStatus == .NEW,
                actionContext: StagingDiffActionContext(snapshotRevision: index.snapshotRevision,
                                                        loadIdentity: loadIdentity, rawPath: file.rawPath,
                                                        staged: request.staged)
            )
        }
        NSLog("[GitX] Scheduling %ld staging diff section(s)", snapshots.count)
        loadCoordinator.schedule(snapshots) { [weak self] output in
            guard let self else { return }
            displayedRequests = snapshots
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
        currentLoadIdentity = nil
        currentRequests = []
        displayedRequests = []
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
            PBNativeSectionActionContextKey: descriptor.actionContext?.dictionary ?? [:],
        ]
    }

    // MARK: Content-view actions (dispatched via the private delegate adapter)

    fileprivate func performDiffAction(_ action: String, patch: String, context: [String: Any], in view: PBNativeContentView) {
        guard acceptsAction(action, context: context) else { return }
        switch action {
        case "stage":
            NSLog("[GitX] Applying a partial stage patch from the staging pane")
            repository.index.applyPatch(patch, stage: true, reverse: false, completion: { _, _ in })
        case "unstage":
            NSLog("[GitX] Applying a partial unstage patch from the staging pane")
            repository.index.applyPatch(patch, stage: true, reverse: true, completion: { _, _ in })
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
                guard response == .alertFirstButtonReturn, let self, acceptsAction(action, context: context) else { return }
                NSLog("[GitX] Discarding a hunk from the staging pane")
                repository.index.applyPatch(patch, stage: false, reverse: true, completion: { _, _ in })
            }
        default:
            NSLog("[GitX] Ignoring unknown staging diff action: %@", action)
        }
    }

    private func acceptsAction(_ action: String, context: [String: Any]) -> Bool {
        guard let token = StagingDiffActionContext(dictionary: context), token.permits(action),
              token.snapshotRevision == repository.index.snapshotRevision,
              token.loadIdentity == currentLoadIdentity,
              currentRequests.contains(where: { $0.file.rawPath == token.rawPath && $0.staged == token.staged }),
              CommitSubmissionEligibility.allowsMutation(repository.index)
        else {
            NSLog("[GitX] Rejected obsolete diff action %@ at snapshot revision %llu", action, UInt64(repository.index.snapshotRevision))
            return false
        }
        return true
    }

    fileprivate func imageLookup(forPath path: String, sectionIndex: Int) -> StagingImageLookup? {
        guard displayedRequests.indices.contains(sectionIndex),
              let safePath = IndexFilePresentation.safePath(rawPath: displayedRequests[sectionIndex].rawPath),
              Data(path.utf8) == displayedRequests[sectionIndex].rawPath, path == safePath else { return nil }
        let task = repository.task(withArguments: ["show", ":0:" + path])
        task.separatesStandardError = true
        return StagingImageLookup(
            workingFileURL: displayedRequests[sectionIndex].staged ? nil : repository.workingDirectoryURL()?.appendingPathComponent(path),
            indexTask: task
        )
    }
}

// swiftlint:enable unused_declaration
