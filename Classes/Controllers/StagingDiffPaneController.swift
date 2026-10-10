import AppKit
import CryptoKit
import Darwin

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
        if let workingFileURL {
            return try? StagingImageReader.shared.read(workingFileURL).data
        }
        let data = try? StagingImageBlobReader(task: indexTask).read()
        return data?.isEmpty == false ? data : nil
    }
}

/// Whole-file authorization compares Git and filesystem bytes, independently
/// of diff rendering or filename display decoding.
private nonisolated struct StagingDiscardSnapshot: Equatable {
    let parentTree: String
    let files: [File]

    struct File: Equatable {
        let rawPath: Data
        let status: Int
        let staged: Bool
        let indexEntries: [Data]
        let worktree: Worktree
    }

    enum Worktree: Equatable {
        case absent
        case regular(mode: UInt32, digest: Data)
        case symlink(mode: UInt32, target: Data)
    }
}

private nonisolated struct StagingDiscardCapture {
    let runner: IndexCommandRunning

    func snapshot(_ requests: [StagingDiffLoadRequest], parentTree: String) throws -> StagingDiscardSnapshot {
        guard let first = requests.first else { return StagingDiscardSnapshot(parentTree: parentTree, files: []) }
        guard let rawRunner = runner as? IndexRawOutputCommandRunning,
              let directory = first.workingDirectoryURL,
              requests.allSatisfy({ $0.parentTree == first.parentTree && $0.workingDirectoryURL == directory })
        else { throw StagingDiffPaneController.staleActionError() }
        func data(_ arguments: [String]) throws -> Data {
            try rawRunner.rawOutput(arguments: ["--literal-pathspecs"] + arguments, environment: ["GIT_OPTIONAL_LOCKS": "0"])
        }
        // Query raw records once, then select by bytes. No argv encoding can
        // represent every Git pathname, and no command is needed per file.
        let parser = IndexStatusParser()
        var error: NSError?
        guard let staged = try parser.parseTrackedData(data(["diff-index", "--cached", "--no-renames", "-z", first.parentTree]), error: &error),
              let unstaged = try parser.parseTrackedData(data(["diff-files", "--no-renames", "-z"]), error: &error)
        else { throw error ?? StagingDiffPaneController.staleActionError() }
        let selected = Set(requests.map(\.rawPath))
        var entries: [Data: [Data]] = [:]
        for record in try IndexFilePresentation.rawPaths(data: data(["ls-files", "--stage", "-z"])) {
            guard let tab = record.firstIndex(of: 9) else { throw StagingDiffPaneController.staleActionError() }
            let path = Data(record.suffix(from: record.index(after: tab)))
            guard selected.contains(path) else { continue }
            let header = Data(record[..<tab])
            guard let text = String(data: header, encoding: .ascii) else { throw StagingDiffPaneController.staleActionError() }
            let fields = text.split(separator: " ")
            guard fields.count == 3, fields[0].count == 6, fields[0].allSatisfy({ ("0" ... "7").contains(String($0)) }),
                  [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit), ["0", "1", "2", "3"].contains(fields[2])
            else { throw StagingDiffPaneController.staleActionError() }
            entries[path, default: []].append(header)
        }
        let root = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard root >= 0 else { throw Self.fileError() }
        defer { Darwin.close(root) }
        let files = try requests.map { request in
            guard let actual = unstaged[request.rawPath], actual.status == request.status,
                  (staged[request.rawPath] != nil) == request.hasStagedChanges,
                  let indexEntries = entries[request.rawPath], !indexEntries.isEmpty
            else { throw StagingDiffPaneController.staleActionError() }
            return try StagingDiscardSnapshot.File(rawPath: request.rawPath, status: actual.status,
                                                   staged: request.hasStagedChanges, indexEntries: indexEntries,
                                                   worktree: Self.worktreeIdentity(root: root, path: request.rawPath))
        }
        NSLog("[GitX] Captured byte-preserving discard identities for %ld tracked files", files.count)
        return StagingDiscardSnapshot(parentTree: parentTree, files: files)
    }

    private static func worktreeIdentity(root: Int32, path: Data) throws -> StagingDiscardSnapshot.Worktree {
        let components = path.split(separator: 47, omittingEmptySubsequences: false)
        guard !path.contains(0), components.allSatisfy({ !$0.isEmpty && $0 != Data([46]) && $0 != Data([46, 46]) })
        else { throw StagingDiffPaneController.staleActionError() }
        var terminated = path; terminated.append(0)
        return try terminated.withUnsafeBytes { bytes in
            let name = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            var before = stat()
            guard fstatat(root, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT {
                    return .absent
                }
                throw fileError()
            }
            let mode = UInt32(before.st_mode & 0o777)
            let kind = before.st_mode & S_IFMT
            let identity: StagingDiscardSnapshot.Worktree
            if kind == S_IFLNK {
                var capacity = 256
                while true {
                    var buffer = [UInt8](repeating: 0, count: capacity)
                    let count = buffer.withUnsafeMutableBytes { readlinkat(root, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
                    guard count >= 0 else { throw fileError() }
                    if count < capacity {
                        identity = .symlink(mode: mode, target: Data(buffer.prefix(count)))
                        break
                    }
                    guard capacity < 1024 * 1024 else { throw StagingDiffPaneController.staleActionError() }
                    capacity *= 2
                }
            } else {
                guard kind == S_IFREG else { throw StagingDiffPaneController.staleActionError() }
                let descriptor = Darwin.openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw fileError() }
                defer { Darwin.close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, sameFile(before, opened) else { throw StagingDiffPaneController.staleActionError() }
                var hash = SHA256()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        hash.update(data: Data(buffer.prefix(count)))
                    } else if count == 0 {
                        break
                    } else if errno != EINTR {
                        throw fileError()
                    }
                }
                var finished = stat()
                guard fstat(descriptor, &finished) == 0, sameFile(opened, finished) else { throw StagingDiffPaneController.staleActionError() }
                identity = .regular(mode: mode, digest: Data(hash.finalize()))
            }
            var after = stat()
            guard fstatat(root, name, &after, AT_SYMLINK_NOFOLLOW) == 0, sameFile(before, after)
            else { throw StagingDiffPaneController.staleActionError() }
            return identity
        }
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
            first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func fileError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not capture the selected file for discard."])
    }
}

/// Produces diff text from immutable request values on the coordinator's
/// serial queue. The service owns the Git command execution; synthetic
/// untracked diffs read only the snapshotted working-directory URL.
private nonisolated enum StagingTextProduction { case success(String); case failure(String) }

// swift6-safety-justification: Immutable requests cross load and writer queues; each Git command owns its task, and the capability/image caches are lock-protected.
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

    func produce(_ request: StagingDiffLoadRequest, resolvedTree: String? = nil, shouldCancel: () -> Bool = { false }) -> StagingDiffProduction {
        switch produceText(request) {
        case let .success(diff):
            do {
                let tree = try resolvedTree ?? parentTreeIdentity(request.parentTree)
                // Unknown visual input must disable reuse/authorization, while
                // retaining the diff and conflict details already produced.
                let visual: String
                do { visual = try imageIdentity(request, shouldCancel: shouldCancel) }
                catch {
                    NSLog("[GitX] Image identity unavailable for %@: %@", request.path, error.localizedDescription)
                    return .readOnly(diff: diff, detail: error.localizedDescription)
                }
                return .validated(diff: diff, parentTree: tree, visualIdentity: visual)
            } catch { return .failure(detail(for: error as NSError)) }
        case let .failure(error): return .failure(error)
        }
    }

    func revalidate(_ requests: [StagingDiffLoadRequest]) -> [StagingDiffProduction] {
        guard let first = requests.first else { return [] }
        do {
            guard requests.allSatisfy({ $0.parentTree == first.parentTree }) else {
                throw NSError(domain: "PBGitIndexMutationError", code: 8)
            }
            let tree = try parentTreeIdentity(first.parentTree)
            // Bound argv while sharing the three status queries across selected
            // files. Each file still gets its exact diff and visual identity.
            var groups: [[StagingDiffLoadRequest]] = []
            var group: [StagingDiffLoadRequest] = []
            var size = 0
            for request in requests {
                guard let path = IndexFilePresentation.safePath(rawPath: request.rawPath) else {
                    throw NSError(domain: "PBGitIndexMutationError", code: 8, userInfo: [NSLocalizedDescriptionKey: "The selected filename cannot be represented."])
                }
                if !group.isEmpty, size + path.utf8.count + 1 > 32 * 1024 {
                    groups.append(group); group = []; size = 0
                }
                group.append(request); size += path.utf8.count + 1
            }
            if !group.isEmpty {
                groups.append(group)
            }
            var results: [StagingDiffProduction] = []
            for group in groups {
                let paths = group.compactMap { IndexFilePresentation.safePath(rawPath: $0.rawPath) }
                func data(_ arguments: [String]) throws -> Data {
                    let arguments = ["-c", "core.precomposeUnicode=false", "--literal-pathspecs"] + arguments + ["--"] + paths
                    let environment: [String: Any] = ["GIT_OPTIONAL_LOCKS": "0"]
                    if let raw = runner as? IndexRawOutputCommandRunning {
                        return try raw.rawOutput(arguments: arguments, environment: environment)
                    }
                    return try Data(runner.output(arguments: arguments, input: nil, environment: environment).utf8)
                }
                let parser = IndexStatusParser()
                var error: NSError?
                guard let staged = try parser.parseTrackedData(data(["diff-index", "--cached", "-z", first.parentTree]), error: &error),
                      let unstaged = try parser.parseTrackedData(data(["diff-files", "-z"]), error: &error),
                      let untracked = try parser.parseUntrackedData(data(["ls-files", "--others", "--exclude-standard", "-z"]), error: &error)
                else { throw error ?? NSError(domain: "PBGitIndexMutationError", code: 8) }
                results += group.map { request in
                    let actual = request.staged ? staged[request.rawPath] : unstaged[request.rawPath] ?? untracked[request.rawPath]
                    guard actual?.status == request.status, (staged[request.rawPath] != nil) == request.hasStagedChanges,
                          (untracked[request.rawPath] != nil) == request.syntheticUntracked
                    else { return .failure("The selected file's staging state changed. Refresh and retry this action.") }
                    return produce(request, resolvedTree: tree)
                }
            }
            NSLog("[GitX] Revalidated %ld selected files in %ld status batches", requests.count, groups.count)
            return results
        } catch { return requests.map { _ in .failure(detail(for: error as NSError)) } }
    }

    private func parentTreeIdentity(_ parentTree: String) throws -> String {
        let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        return parentTree == emptyTree ? emptyTree : try runner.output(arguments: ["rev-parse", "--verify", parentTree + "^{tree}"], input: nil, environment: nil).trimmingCharacters(in: .newlines)
    }

    func discardAuthorization(requests: [StagingDiffLoadRequest],
                              eligibility: @escaping @MainActor @Sendable () -> Bool) throws -> PBIndexPatchAuthorization
    {
        let expected = try discardSnapshot(requests)
        return PBIndexPatchAuthorization { [weak self] in
            guard let self, DispatchQueue.main.sync(execute: { eligibility() }),
                  try discardSnapshot(requests) == expected else { throw StagingDiffPaneController.staleActionError() }
        }
    }

    private func discardSnapshot(_ requests: [StagingDiffLoadRequest]) throws -> StagingDiscardSnapshot {
        let tree = try requests.first.map { try parentTreeIdentity($0.parentTree) } ?? ""
        return try StagingDiscardCapture(runner: runner).snapshot(requests, parentTree: tree)
    }

    func actionIdentities(_ requests: [StagingDiffLoadRequest]) throws -> [StagingDiffActionContext] {
        try zip(requests, revalidate(requests)).map { request, production in
            guard case let .validated(diff, tree, visual) = production else { throw StagingDiffPaneController.staleActionError() }
            return StagingDiffActionContext(request: request, diff: diff, parentTree: tree, visualIdentity: visual)
        }
    }

    func authorization(requests: [StagingDiffLoadRequest], identities: [StagingDiffActionContext],
                       eligibility: @escaping @MainActor @Sendable () -> Bool) -> PBIndexPatchAuthorization
    {
        PBIndexPatchAuthorization { [weak self] in
            guard let self, DispatchQueue.main.sync(execute: { eligibility() }),
                  try actionIdentities(requests) == identities else { throw StagingDiffPaneController.staleActionError() }
        }
    }

    private func imageIdentity(_ request: StagingDiffLoadRequest, shouldCancel: () -> Bool) throws -> String {
        guard ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "icns", "heic", "webp"].contains((request.path as NSString).pathExtension.lowercased()) else { return "" }
        guard let path = IndexFilePresentation.safePath(rawPath: request.rawPath) else { throw StagingImageReader.failure("The image path cannot be represented safely.") }
        if request.staged {
            if request.status == PBChangedFileStatus.DELETED.rawValue {
                return "absent:index"
            }
            let object = try runner.output(arguments: ["rev-parse", "--verify", ":0:" + path], input: nil, environment: nil).trimmingCharacters(in: .newlines)
            let size = try runner.output(arguments: ["cat-file", "-s", object], input: nil, environment: nil).trimmingCharacters(in: .newlines)
            guard !shouldCancel(), let count = Int(size), count >= 0, count <= StagingImageReader.maximumBytes else {
                throw StagingImageReader.failure("Indexed image is unavailable or exceeds the preview limit.")
            }
            return object
        }
        guard let directory = request.workingDirectoryURL else { throw StagingImageReader.failure("The image working directory is unavailable.") }
        let url = directory.appendingPathComponent(path)
        if request.status == PBChangedFileStatus.DELETED.rawValue {
            return "absent:worktree"
        }
        return try StagingImageReader.shared.read(url, includeData: false, shouldCancel: shouldCancel).identity
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
        loadCoordinator = StagingDiffLoadCoordinator(cancellableProducer: { production.produce($0, shouldCancel: $1) })
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
        let requests = IndexFilePresentation.discardableFiles(files: files).map { file in
            StagingDiffLoadRequest(path: file.path, rawPath: file.rawPath, status: file.worktreeStatus.rawValue,
                                   hasStagedChanges: file.hasStagedChanges, staged: false, parentTree: parentTree, contextLines: 3,
                                   workingDirectoryURL: repository.workingDirectoryURL(), syntheticUntracked: file.worktreeStatus == .NEW)
        }
        let producer = producer
        let writer = IndexRepositoryCommandRunner(repository: repository).writerCoordinator
        writer.schedule("capture discard confirmation", work: { [producer] () -> (PBIndexPatchAuthorization?, NSError?) in
            do {
                let authorization = try producer.discardAuthorization(requests: requests, eligibility: eligibility)
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
        guard CommitSubmissionEligibility.allowsMutation(repository.index) else {
            NSLog("[GitX] Ignored a staging action while mutation or reconciliation is active")
            return false
        }
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
        let authorization = producer.authorization(requests: [request], identities: [token], eligibility: eligibility)
        if !repository.index.applyPatch(patch, stage: stage, reverse: reverse, authorization: authorization, completion: { _, _ in }) {
            rejectAction()
        }
    }

    fileprivate nonisolated static func staleActionError() -> NSError {
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

#if DEBUG
    /// Drive the actual capture and writer revalidation without presenting a sheet.
    @objc(PBStagingDiffRevalidationTestHarness)
    final class StagingDiffRevalidationTestHarness: NSObject {
        @objc(prepareAndValidateWithRepository:runner:files:completion:)
        static func prepareAndValidate(repository: PBGitRepository, runner: IndexCommandRunning, files: [PBChangedFile],
                                       completion: @escaping @MainActor @Sendable (NSError?) -> Void)
        {
            prepareAndValidate(repository: repository, runner: runner, files: files, beforeValidation: {}, completion: completion)
        }

        @objc(prepareAndValidateWithRepository:runner:files:beforeValidation:completion:)
        static func prepareAndValidate(repository: PBGitRepository, runner: IndexCommandRunning, files: [PBChangedFile],
                                       beforeValidation: @escaping @MainActor @Sendable () -> Void,
                                       completion: @escaping @MainActor @Sendable (NSError?) -> Void)
        {
            let pane = StagingDiffPaneController(repository: repository, diffRunner: runner)
            pane.prepareDiscard(files: files, eligibility: { true }) { authorization, error in
                guard let authorization else { completion(error); return }
                beforeValidation()
                let writer = IndexRepositoryCommandRunner(repository: repository).writerCoordinator
                writer.schedule("test confirmed discard revalidation", work: { [pane] () -> NSError? in
                    withExtendedLifetime(pane) {
                        do { try authorization.validate(); return nil }
                        catch { return error as NSError }
                    }
                }, completion: { error in DispatchQueue.main.async { completion(error) } })
            }
        }
    }
#endif

// swiftlint:enable unused_declaration
