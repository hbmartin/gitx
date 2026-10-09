import AppKit
import CryptoKit

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
private nonisolated enum StagingTextProduction { case success(String); case failure(String) }

// swift6-safety-justification: Immutable requests cross load and writer queues; each Git command owns its task, and the service locks its capability cache.
private final nonisolated class IndexMutationStagingDiffProducer: @unchecked Sendable {
    // Strong on purpose: production runs on the coordinator's background queue and can
    // outlive the pane, while the mutation service reaches the repository only through
    // weak references. This keeps the repository alive until queued work drains.
    // It is not a cycle — the repository never owns the staging pane.
    private let repository: PBGitRepository
    private let mutationService: IndexMutationService
    private let runner: IndexCommandRunning

    init(repository: PBGitRepository, runner: IndexCommandRunning? = nil) {
        self.repository = repository
        let commands = runner ?? IndexRepositoryCommandRunner(repository: repository)
        self.runner = commands
        mutationService = IndexMutationService(repository: repository, runner: commands)
    }

    func produce(_ request: StagingDiffLoadRequest) -> StagingDiffProduction {
        switch produceText(request) {
        case let .success(diff):
            do {
                let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
                let tree = request.parentTree == emptyTree ? emptyTree : try runner.output(arguments: ["rev-parse", "--verify", request.parentTree + "^{tree}"], input: nil, environment: nil).trimmingCharacters(in: .newlines)
                let visual = try imageIdentity(request)
                return .validated(diff: diff, parentTree: tree, visualIdentity: visual)
            } catch { return .failure(detail(for: error as NSError)) }
        case let .failure(error): return .failure(error)
        }
    }

    func revalidate(_ request: StagingDiffLoadRequest) -> StagingDiffProduction {
        guard let path = IndexFilePresentation.safePath(rawPath: request.rawPath) else { return .failure("The selected filename cannot be represented.") }
        do {
            func data(_ arguments: [String]) throws -> Data {
                let task = repository.task(withArguments: ["--literal-pathspecs"] + arguments + ["--", path])
                task.separatesStandardError = true
                task.additionalEnvironment = ["GIT_OPTIONAL_LOCKS": "0"]
                try task.launch()
                return task.standardOutputData
            }
            let parser = IndexStatusParser()
            var error: NSError?
            guard let staged = try parser.parseTrackedData(data(["diff-index", "--cached", "-z", request.parentTree]), error: &error),
                  let unstaged = try parser.parseTrackedData(data(["diff-files", "-z"]), error: &error),
                  let untracked = try parser.parseUntrackedData(data(["ls-files", "--others", "--exclude-standard", "-z"]), error: &error)
            else { throw error ?? NSError(domain: "PBGitIndexMutationError", code: 8) }
            let actual = request.staged ? staged[request.rawPath] : unstaged[request.rawPath] ?? untracked[request.rawPath]
            guard actual?.status == request.status, (staged[request.rawPath] != nil) == request.hasStagedChanges,
                  (untracked[request.rawPath] != nil) == request.syntheticUntracked
            else {
                return .failure("The selected file's staging state changed. Refresh and retry this action.")
            }
            return produce(request)
        } catch { return .failure(detail(for: error as NSError)) }
    }

    private func imageIdentity(_ request: StagingDiffLoadRequest) throws -> String {
        guard ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "icns", "heic", "webp"].contains((request.path as NSString).pathExtension.lowercased()) else { return "" }
        guard let path = IndexFilePresentation.safePath(rawPath: request.rawPath) else { return "unavailable" }
        if request.staged {
            if request.status == PBChangedFileStatus.DELETED.rawValue {
                return "absent:index"
            }
            return try runner.output(arguments: ["rev-parse", "--verify", ":0:" + path], input: nil, environment: nil).trimmingCharacters(in: .newlines)
        }
        guard let directory = request.workingDirectoryURL else { return "unavailable" }
        let url = directory.appendingPathComponent(path)
        if request.status == PBChangedFileStatus.DELETED.rawValue {
            return "absent:worktree"
        }
        let bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ":" + String(mode)
    }

    private func produceText(_ request: StagingDiffLoadRequest) -> StagingTextProduction {
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
    ) -> StagingTextProduction {
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
    private var renderPending = false
    private var displayedContexts: [StagingDiffActionContext] = []
    private var displayedAmend = false
    private let producer: IndexMutationStagingDiffProducer
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
        let production = IndexMutationStagingDiffProducer(repository: repository, runner: diffRunner)
        producer = production
        loadCoordinator = StagingDiffLoadCoordinator(producer: production.produce)
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
        // Update selection authority immediately, then merge publications and
        // selection callbacks arriving in the same main-queue turn.
        currentRequests = requests
        if requests.isEmpty {
            renderPending = false
            loadCoordinator.invalidate()
            displayedRequests = []
            displayedContexts = []
            contentView.showMessage(NSLocalizedString("No file selected", comment: "Placeholder in the staging diff pane when no file is selected"))
            return
        }
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, renderPending else { return }
            renderPending = false
            produceCurrentRequests()
        }
    }

    private func produceCurrentRequests() {
        let requests = currentRequests
        let index = repository.index
        let parentTree = index.parentTree
        let workingDirectoryURL = repository.workingDirectoryURL()
        let contextLines = contextLines
        let expectedAmend = index.isAmend
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
                syntheticUntracked: !request.staged && file.worktreeStatus == .NEW
            )
        }
        NSLog("[GitX] Scheduling %ld staging diff section(s)", snapshots.count)
        loadCoordinator.schedule(snapshots) { [weak self] output in
            guard let self else { return }
            displayedRequests = snapshots
            displayedAmend = expectedAmend
            displayedContexts = output.sections.compactMap(\.actionContext)
            let sections = output.sections.map(nativeSection(from:))
            let configuredSections = repository.gitURL() == nil ? sections : NativeDiffSectionSettings.apply(to: sections, repository: repository)
            contentView.showDiffSections(
                configuredSections,
                cacheIdentifier: output.cacheIdentifier,
                preserveScrollPosition: true
            )
        }
    }

    func updateSelection(_ requests: [StagingDiffRequest]) {
        currentRequests = requests
        if requests.isEmpty {
            render(requests)
        }
    }

    @objc func rerenderCurrentRequests() {
        render(currentRequests)
    }

    @objc(showStateMessage:)
    func showStateMessage(_ message: String) {
        renderPending = false
        displayedContexts = []
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
            apply(action, patch: patch, context: context, stage: true, reverse: false)
        case "unstage":
            NSLog("[GitX] Applying a partial unstage patch from the staging pane")
            apply(action, patch: patch, context: context, stage: true, reverse: true)
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
                guard response == .alertFirstButtonReturn, let self else { return }
                guard acceptsAction(action, context: context) else { return }
                NSLog("[GitX] Discarding a hunk from the staging pane")
                apply(action, patch: patch, context: context, stage: false, reverse: true)
            }
        default:
            NSLog("[GitX] Ignoring unknown staging diff action: %@", action)
        }
    }

    /// Capture before confirmation and validate on the same writer immediately
    /// before discard. No writer lock survives the user's confirmation sheet.
    func prepareDiscard(files: [PBChangedFile], eligibility: @escaping @MainActor @Sendable () -> Bool,
                        completion: @escaping @MainActor @Sendable (PBIndexPatchAuthorization?, NSError?) -> Void)
    {
        let parentTree = repository.index.parentTree
        let requests = files.map { file in
            StagingDiffLoadRequest(path: file.path, rawPath: file.rawPath, status: file.worktreeStatus.rawValue,
                                   hasStagedChanges: file.hasStagedChanges, staged: false, parentTree: parentTree, contextLines: 3,
                                   workingDirectoryURL: repository.workingDirectoryURL(), syntheticUntracked: file.worktreeStatus == .NEW)
        }
        let producer = producer
        let writer = IndexRepositoryCommandRunner(repository: repository).writerCoordinator
        writer.schedule("capture discard confirmation", work: { [producer] () -> (PBIndexPatchAuthorization?, NSError?) in
            do {
                let identities = try requests.map { request -> StagingDiffActionContext in
                    guard case let .validated(diff, tree, visual) = producer.revalidate(request) else { throw Self.staleActionError() }
                    return StagingDiffActionContext(rawPath: request.rawPath, staged: false, parentTree: tree, diff: diff,
                                                    contextLines: request.contextLines, status: request.status, hasStagedChanges: request.hasStagedChanges, visualIdentity: visual)
                }
                let authorization = PBIndexPatchAuthorization { [weak producer] in
                    guard let producer, DispatchQueue.main.sync(execute: { eligibility() }) else { throw Self.staleActionError() }
                    for (request, identity) in zip(requests, identities) {
                        guard case let .validated(diff, tree, visual) = producer.revalidate(request) else { throw Self.staleActionError() }
                        let fresh = StagingDiffActionContext(rawPath: request.rawPath, staged: false, parentTree: tree, diff: diff,
                                                             contextLines: request.contextLines, status: request.status, hasStagedChanges: request.hasStagedChanges, visualIdentity: visual)
                        guard fresh == identity else { throw Self.staleActionError() }
                    }
                }
                return (authorization, nil)
            } catch { return (nil, error as NSError) }
        }, completion: { result in
            DispatchQueue.main.async { completion(result.0, result.1) }
        })
    }

    private func stillSelected(_ token: StagingDiffActionContext) -> Bool {
        displayedContexts.contains(token) && token.contextLines == contextLines &&
            currentRequests.contains { request in
                request.file.rawPath == token.rawPath && request.staged == token.staged &&
                    (token.staged ? request.file.hasStagedChanges : request.file.hasUnstagedChanges)
            }
    }

    private func acceptsAction(_ action: String, context: [String: Any]) -> Bool {
        guard let token = StagingDiffActionContext(dictionary: context), token.permits(action),
              stillSelected(token), CommitSubmissionEligibility.allowsMutation(repository.index)
        else {
            rejectAction()
            return false
        }
        return true
    }

    private func rejectAction() {
        NSLog("[GitX] Rejected a stale or ineligible staging action")
        NotificationCenter.default.post(name: Notification.Name(PBGitIndexOperationFailed), object: repository.index,
                                        userInfo: ["description": "The selected diff or repository state changed. Refresh and retry this action."])
        rerenderCurrentRequests()
    }

    private func apply(_ action: String, patch: String, context: [String: Any], stage: Bool, reverse: Bool) {
        guard let token = StagingDiffActionContext(dictionary: context),
              let request = displayedRequests.first(where: { $0.rawPath == token.rawPath && $0.staged == token.staged }) else { rejectAction(); return }
        let expectedAmend = displayedAmend
        let eligibility: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return token.permits(action) && stillSelected(token) && !repository.index.submissionActive && repository.index.isAmend == expectedAmend
        }
        let producer = producer
        let authorization = PBIndexPatchAuthorization { [weak producer] in
            guard let producer, DispatchQueue.main.sync(execute: { eligibility() }) else { throw Self.staleActionError() }
            guard case let .validated(diff, tree, visual) = producer.revalidate(request) else { throw Self.staleActionError() }
            let fresh = StagingDiffActionContext(rawPath: request.rawPath, staged: request.staged, parentTree: tree,
                                                 diff: diff, contextLines: request.contextLines, status: request.status,
                                                 hasStagedChanges: request.hasStagedChanges, visualIdentity: visual)
            guard fresh == token else { throw Self.staleActionError() }
        }
        if !repository.index.applyPatch(patch, stage: stage, reverse: reverse, authorization: authorization, completion: { _, _ in }) {
            rejectAction()
        }
    }

    private nonisolated static func staleActionError() -> NSError {
        NSError(domain: "PBGitIndexMutationError", code: 8, userInfo: [NSLocalizedDescriptionKey: "The selected diff or repository state changed. Refresh and retry this action."])
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
