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
    private let cancellation: StagingReadCancellation

    init(workingFileURL: URL?, indexTask: PBTask, cancellation: StagingReadCancellation) {
        self.workingFileURL = workingFileURL
        self.indexTask = indexTask
        self.cancellation = cancellation
    }

    func data() -> Data? {
        NSLog("[GitX] Reading staging image data on %@", Thread.isMainThread ? "main" : "renderer queue")
        if let workingFileURL {
            do {
                return try StagingImageReader.shared.read(workingFileURL, shouldCancel: { self.cancellation.isCancelled }).data
            } catch {
                guard StagingImageReader.isAbsent(workingFileURL, afterReadFailure: error, shouldCancel: { self.cancellation.isCancelled }) else {
                    let failure = error as NSError
                    NSLog("[GitX] Worktree image is unavailable without an index fallback (%@:%ld)", failure.domain, failure.code)
                    return nil
                }
                NSLog("[GitX] Missing worktree image; reading its indexed bytes")
            }
        }
        let data = try? StagingImageBlobReader(task: indexTask).read(cancellation: cancellation)
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
    static let defaultCaptureBudget: TimeInterval = 30
    let runner: IndexCommandRunning
    let service: IndexMutationService
    var timeout: TimeInterval = Self.defaultCaptureBudget
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var shouldCancel: () -> Bool = { false }

    /// Every query and hash chunk shares one monotonic capture budget.
    func snapshot(_ requests: [StagingDiffLoadRequest], parentTree: String) throws -> StagingDiscardSnapshot {
        guard let first = requests.first else { return StagingDiscardSnapshot(parentTree: parentTree, files: []) }
        guard let rawRunner = runner as? IndexRawOutputCommandRunning,
              let directory = first.workingDirectoryURL,
              requests.allSatisfy({ $0.parentTree == first.parentTree && $0.workingDirectoryURL == directory })
        else { throw Self.stale("capture request has no raw-output runner or a consistent working directory") }
        let started = clock()
        let deadline = started + timeout
        func check() throws {
            guard !shouldCancel(), clock() < deadline else {
                NSLog("[GitX] Discard capture cancelled or exceeded its total time limit")
                throw StagingImageReader.failure("Discard preparation was cancelled or exceeded its time limit. Refresh and retry.")
            }
        }
        try check()
        // Representable selections narrow Git's work to bounded argv batches.
        // Non-UTF-8 names keep the byte-preserving whole-index fallback.
        let paths = requests.compactMap { IndexFilePresentation.safePath(rawPath: $0.rawPath) }
        var groups: [[Data]] = []
        if paths.count == requests.count {
            var group: [Data] = []; var size = 0
            for request in requests {
                if !group.isEmpty, size + request.rawPath.count + 1 > 32 * 1024 {
                    groups.append(group); group = []; size = 0
                }
                group.append(request.rawPath); size += request.rawPath.count + 1
            }
            if !group.isEmpty {
                groups.append(group)
            }
        } else {
            groups = [[]]
        }
        let prepared = try groups.map { group in
            try check()
            return try PreparedPathArguments(paths: group, service: service, check: check)
        }
        func data(_ arguments: [String]) throws -> Data {
            var result = Data()
            for group in prepared {
                try check()
                let command = group.command(arguments)
                try result.append(rawRunner.rawOutput(arguments: ["-c", "core.precomposeUnicode=false"] + command,
                                                      environment: ["GIT_OPTIONAL_LOCKS": "0"]))
                try check()
            }
            return result
        }
        let parser = IndexStatusParser()
        var error: NSError?
        guard let staged = try parser.parseTrackedData(data(["diff-index", "--cached", "--no-renames", "-z", first.parentTree]), error: &error),
              let unstaged = try parser.parseTrackedData(data(["diff-files", "--no-renames", "-z"]), error: &error)
        else { throw error ?? Self.stale("Git status output could not be parsed") }
        let selected = Set(requests.map(\.rawPath))
        var entries: [Data: [Data]] = [:]
        for record in try IndexFilePresentation.rawPaths(data: data(["ls-files", "--stage", "-z"])) {
            guard let tab = record.firstIndex(of: 9) else { throw Self.stale("index entry lacks a header separator") }
            let path = Data(record.suffix(from: record.index(after: tab)))
            guard selected.contains(path) else { continue }
            let header = Data(record[..<tab])
            guard let text = String(data: header, encoding: .ascii) else { throw Self.stale("index entry header is not ASCII") }
            let fields = text.split(separator: " ")
            guard fields.count == 3, fields[0].count == 6, fields[0].allSatisfy({ ("0" ... "7").contains(String($0)) }),
                  [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit), ["0", "1", "2", "3"].contains(fields[2])
            else { throw Self.stale("index entry mode, object identity, or stage is invalid") }
            guard fields[0] != "160000" else {
                throw StagingImageReader.failure("Discard is unavailable for the selected submodule. Restore it with Git before retrying.")
            }
            entries[path, default: []].append(header)
        }
        let root = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard root >= 0 else { throw Self.fileError() }
        defer { Darwin.close(root) }
        let files = try requests.map { request in
            try check()
            guard let actual = unstaged[request.rawPath], actual.status == request.status
            else { throw Self.stale("selected worktree status changed") }
            guard (staged[request.rawPath] != nil) == request.hasStagedChanges
            else { throw Self.stale("selected staged status changed") }
            guard let indexEntries = entries[request.rawPath], !indexEntries.isEmpty
            else { throw Self.stale("selected path has no index entry") }
            return try StagingDiscardSnapshot.File(rawPath: request.rawPath, status: actual.status,
                                                   staged: request.hasStagedChanges, indexEntries: indexEntries,
                                                   worktree: Self.worktreeIdentity(root: root, path: request.rawPath, check: check))
        }
        try check()
        NSLog("[GitX] Captured byte-preserving discard identities for %ld tracked files in %ld selected-path batches in %.3f ms", files.count, groups.count, (clock() - started) * 1000)
        return StagingDiscardSnapshot(parentTree: parentTree, files: files)
    }

    struct PreparedPathArguments {
        let globalOptions: [String]
        let pathArguments: [String]

        init(paths: [Data], service: IndexMutationService, check: () throws -> Void = {}) throws {
            var literal = false
            var names: [String] = []
            for path in paths {
                try check()
                var error: NSError?
                guard let command = service.literalArguments(forRawPath: path, commandArguments: [], error: &error) else {
                    throw error ?? StagingDiffPaneController.staleActionError()
                }
                literal = literal || command.first == "--literal-pathspecs"
                names.append(command.last!)
            }
            globalOptions = literal ? ["--literal-pathspecs"] : []
            pathArguments = names.isEmpty ? [] : ["--"] + names
        }

        func command(_ arguments: [String]) -> [String] {
            globalOptions + arguments + pathArguments
        }
    }

    private static func worktreeIdentity(root: Int32, path: Data, check: () throws -> Void) throws -> StagingDiscardSnapshot.Worktree {
        let components = path.split(separator: 47, omittingEmptySubsequences: false)
        guard !path.contains(0), components.allSatisfy({ !$0.isEmpty && $0 != Data([46]) && $0 != Data([46, 46]) })
        else { throw stale("selected path contains an unsafe component") }
        var terminated = path; terminated.append(0)
        return try terminated.withUnsafeBytes { bytes in
            let name = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            var before = stat()
            guard fstatat(root, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT {
                    return .absent
                }
                if errno == ENOTDIR {
                    throw StagingImageReader.failure("Cannot discard this file because “\(blockingAncestor(root: root, path: path))” blocks its parent directory. Move or remove that item and retry.")
                }
                throw fileError()
            }
            let mode = UInt32(before.st_mode & 0o777)
            let kind = before.st_mode & S_IFMT
            let identity: StagingDiscardSnapshot.Worktree
            if kind == S_IFLNK {
                var capacity = 256
                while true {
                    try check()
                    var buffer = [UInt8](repeating: 0, count: capacity)
                    let count = buffer.withUnsafeMutableBytes { readlinkat(root, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
                    guard count >= 0 else { throw fileError() }
                    if count < capacity {
                        identity = .symlink(mode: mode, target: Data(buffer.prefix(count)))
                        break
                    }
                    guard capacity < 1024 * 1024 else { throw stale("symbolic-link target exceeded the capture limit") }
                    capacity *= 2
                }
            } else {
                guard kind == S_IFREG else {
                    NSLog("[GitX] Refused discard of unsupported filesystem kind %u", UInt32(kind))
                    throw StagingImageReader.failure("Discard requires a regular file or symbolic link. The selected item has an unsupported file type.")
                }
                let descriptor = Darwin.openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw fileError() }
                defer { Darwin.close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, sameFile(before, opened) else { throw stale("worktree file changed before hashing") }
                var hash = SHA256()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try check()
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
                guard fstat(descriptor, &finished) == 0, sameFile(opened, finished) else { throw stale("worktree file changed while hashing") }
                identity = .regular(mode: mode, digest: Data(hash.finalize()))
            }
            var after = stat()
            guard fstatat(root, name, &after, AT_SYMLINK_NOFOLLOW) == 0, sameFile(before, after)
            else { throw stale("worktree path identity changed after capture") }
            return identity
        }
    }

    private static func stale(_ reason: String) -> NSError {
        NSLog("[GitX] Rejected discard capture: %@", reason)
        return StagingDiffPaneController.staleActionError()
    }

    private static func blockingAncestor(root: Int32, path: Data) -> String {
        let components = path.split(separator: 47)
        var prefix = Data()
        for component in components.dropLast() {
            if !prefix.isEmpty {
                prefix.append(47)
            }
            prefix.append(contentsOf: component)
            var terminated = prefix; terminated.append(0)
            var metadata = stat()
            let result = terminated.withUnsafeBytes { fstatat(root, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &metadata, 0) }
            if result == 0, metadata.st_mode & S_IFMT != S_IFDIR {
                return IndexPathDisplayName.string(for: prefix)
            }
        }
        return IndexPathDisplayName.string(for: path)
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
                let prepared = try StagingDiscardCapture.PreparedPathArguments(paths: group.map(\.rawPath), service: mutationService)
                func data(_ arguments: [String]) throws -> Data {
                    let arguments = ["-c", "core.precomposeUnicode=false"] + prepared.command(arguments)
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
                              eligibility: @escaping @MainActor @Sendable () -> Bool,
                              cancellation: StagingReadCancellation,
                              validationCancellation: StagingReadCancellation) throws -> PBIndexPatchAuthorization
    {
        let expected = try discardSnapshot(requests, cancellation: cancellation)
        return PBIndexPatchAuthorization(discardPaths: expected.files.map(\.rawPath)) { [weak self] in
            guard !validationCancellation.isCancelled else {
                NSLog("[GitX] Cancelled confirmed discard after pane close")
                throw StagingImageReader.failure("Discard preparation was cancelled.")
            }
            guard let self, DispatchQueue.main.sync(execute: { eligibility() }) else {
                NSLog("[GitX] Rejected confirmed discard: selection or submission eligibility changed")
                throw StagingDiffPaneController.staleActionError()
            }
            let current = try discardSnapshot(requests, cancellation: validationCancellation)
            guard current == expected else {
                let reason: String
                if current.parentTree != expected.parentTree {
                    reason = "parent tree changed"
                } else if current.files.map(\.indexEntries) != expected.files.map(\.indexEntries) {
                    reason = "selected index identity changed"
                } else if current.files.map(\.worktree) != expected.files.map(\.worktree) {
                    reason = "selected worktree content, mode, or kind changed"
                } else {
                    reason = "selected path or status changed"
                }
                NSLog("[GitX] Rejected confirmed discard: %@", reason)
                throw StagingDiffPaneController.staleActionError()
            }
        }
    }

    private func discardSnapshot(_ requests: [StagingDiffLoadRequest], cancellation: StagingReadCancellation) throws -> StagingDiscardSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        guard !cancellation.isCancelled else { throw StagingImageReader.failure("Discard preparation was cancelled.") }
        let tree = try requests.first.map { try parentTreeIdentity($0.parentTree) } ?? ""
        return try StagingDiscardCapture(runner: runner, service: mutationService,
                                         timeout: max(0, StagingDiscardCapture.defaultCaptureBudget - (ProcessInfo.processInfo.systemUptime - started)),
                                         shouldCancel: { cancellation.isCancelled }).snapshot(requests, parentTree: tree)
    }

    #if DEBUG
        func captureDiscardForTesting(_ requests: [StagingDiffLoadRequest], timeout: Double, cancelAfterChecks: Int) throws {
            var checks = 0
            _ = try StagingDiscardCapture(runner: runner, service: mutationService, timeout: timeout, shouldCancel: {
                checks += 1
                return cancelAfterChecks >= 0 && checks > cancelAfterChecks
            }).snapshot(requests, parentTree: requests.first?.parentTree ?? "")
        }
    #endif

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
    private var selectionIdentity = StagingSelectionIdentity()
    private var displayedRequests: [StagingDiffLoadRequest] = []
    private let delegateAdapter = StagingDiffPaneDelegateAdapter()
    private let loadCoordinator: StagingDiffLoadCoordinator
    private var imageCancellation = StagingReadCancellation()
    private var discardCancellation = StagingReadCancellation()
    private let lifetimeCancellation = StagingReadCancellation()

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
        _ = updateSelectionAuthority(requests)
        imageCancellation.cancel(); imageCancellation = StagingReadCancellation()
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

    @discardableResult
    private func updateSelectionAuthority(_ requests: [StagingDiffRequest]) -> Bool {
        let identity = StagingSelectionIdentity(requests)
        let changed = selectionIdentity != identity
        selectionIdentity = identity
        if changed {
            NSLog("[GitX] Cancelling discard capture: selection changed to %ld requests", requests.count)
            discardCancellation.cancel(); discardCancellation = StagingReadCancellation()
        }
        currentRequests = requests
        return changed
    }

    @objc func close() {
        NSLog("[GitX] Cancelling staging reads and discard capture: pane closed")
        imageCancellation.cancel(); discardCancellation.cancel(); lifetimeCancellation.cancel()
        renderPending = false
        loadCoordinator.invalidate()
    }

    func updateSelection(_ requests: [StagingDiffRequest]) {
        if requests.isEmpty {
            render(requests)
        } else if updateSelectionAuthority(requests) {
            imageCancellation.cancel(); imageCancellation = StagingReadCancellation()
        }
    }

    @objc func rerenderCurrentRequests() {
        render(currentRequests)
    }

    #if DEBUG
        fileprivate func drainLoadsForTesting(completion: @escaping @MainActor @Sendable () -> Void) {
            loadCoordinator.drainForTesting(completion: completion)
        }
    #endif

    @objc(showStateMessage:)
    func showStateMessage(_ message: String) {
        NSLog("[GitX] Cancelling staging reads and discard capture: state message")
        imageCancellation.cancel(); discardCancellation.cancel()
        selectionIdentity = StagingSelectionIdentity()
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
        let writer = IndexWriterCoordinator.coordinator(for: repository)
        let cancellation = discardCancellation
        // List transactions publish complete selection. Revalidation uses
        // final eligibility plus the pane lifetime instead of that spent token.
        let validationCancellation = lifetimeCancellation
        writer.schedule("capture discard confirmation", work: { [producer] () -> (PBIndexPatchAuthorization?, NSError?) in
            do {
                let authorization = try producer.discardAuthorization(requests: requests, eligibility: eligibility, cancellation: cancellation,
                                                                      validationCancellation: validationCancellation)
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
            indexTask: task, cancellation: imageCancellation
        )
    }
}

#if DEBUG || GITX_PERFORMANCE_TEST_SUPPORT
    /// Drive the actual capture and writer revalidation without presenting a sheet.
    @objc(PBStagingDiffRevalidationTestHarness)
    final class StagingDiffRevalidationTestHarness: NSObject {
        @objc(selectionIdentityWithRequests:equalsRequests:)
        static func selectionIdentity(_ requests: [StagingDiffRequest], equals other: [StagingDiffRequest]) -> Bool {
            StagingSelectionIdentity(requests) == StagingSelectionIdentity(other)
        }

        #if DEBUG
            @objc(startValidationWithRepository:runner:files:completion:)
            static func startValidation(repository: PBGitRepository, runner: IndexCommandRunning, files: [PBChangedFile],
                                        completion: @escaping @MainActor @Sendable (NSError?) -> Void)
            {
                prepareAndValidate(repository: repository, runner: runner, files: files, beforeValidation: {}, completion: completion)
            }

            @objc(closeAndDrainWithRepository:panes:completion:)
            static func closeAndDrain(repository: PBGitRepository, panes: [StagingDiffPaneController],
                                      completion: @escaping @MainActor @Sendable () -> Void)
            {
                panes.forEach { $0.close() }
                let writer = IndexWriterCoordinator.coordinator(for: repository)
                writer.drainForTesting {
                    let group = DispatchGroup()
                    for pane in panes {
                        group.enter()
                        pane.drainLoadsForTesting { group.leave() }
                    }
                    group.notify(queue: .main) {
                        // swift6-safety-justification: DispatchGroup delivers this notification on the explicitly selected main queue.
                        MainActor.assumeIsolated {
                            if writer.isBusy {
                                closeAndDrain(repository: repository, panes: panes, completion: completion)
                            } else {
                                completion()
                            }
                        }
                    }
                }
            }

            @objc(imageDataWithPane:path:beforeReading:)
            static func imageData(pane: StagingDiffPaneController, path: String, beforeReading: @MainActor () -> Void) -> Data? {
                let lookup = pane.imageLookup(forPath: path, sectionIndex: 0)
                beforeReading()
                return lookup?.data()
            }

            @objc(prepareWithPane:files:completion:)
            static func prepare(pane: StagingDiffPaneController, files: [PBChangedFile],
                                completion: @escaping @MainActor @Sendable (NSError?) -> Void)
            {
                pane.prepareDiscard(files: files, eligibility: { true }) { authorization, error in
                    withExtendedLifetime(pane) { completion(authorization == nil ? error : nil) }
                }
            }

            @objc(updateSelectionWithPane:requests:)
            static func updateSelection(pane: StagingDiffPaneController, requests: [StagingDiffRequest]) {
                pane.updateSelection(requests)
            }

            @objc(captureWithRepository:runner:files:timeout:cancelAfterChecks:completion:)
            static func capture(repository: PBGitRepository, runner: IndexCommandRunning, files: [PBChangedFile], timeout: Double, cancelAfterChecks: Int,
                                completion: @escaping @MainActor @Sendable (NSError?) -> Void)
            {
                let producer = IndexMutationStagingDiffProducer(repository: repository, runner: runner)
                let requests = files.map { file in
                    StagingDiffLoadRequest(path: file.path, rawPath: file.rawPath, status: file.worktreeStatus.rawValue,
                                           hasStagedChanges: file.hasStagedChanges, staged: false, parentTree: repository.index.parentTree,
                                           contextLines: 3, workingDirectoryURL: repository.workingDirectoryURL(), syntheticUntracked: false)
                }
                IndexWriterCoordinator.coordinator(for: repository).schedule("test discard budget", work: { () -> NSError? in
                    do { try producer.captureDiscardForTesting(requests, timeout: timeout, cancelAfterChecks: cancelAfterChecks); return nil }
                    catch { return error as NSError }
                }, completion: { error in DispatchQueue.main.async { completion(error) } })
            }

            @objc(prepareCloseAndValidateWithRepository:runner:files:eligibility:completion:)
            static func prepareCloseAndValidate(repository: PBGitRepository, runner: IndexCommandRunning, files: [PBChangedFile],
                                                eligibility: @escaping @MainActor @Sendable () -> Bool,
                                                completion: @escaping @MainActor @Sendable (NSError?) -> Void)
            {
                let pane = StagingDiffPaneController(repository: repository, diffRunner: runner)
                pane.prepareDiscard(files: files, eligibility: eligibility) { authorization, error in
                    guard let authorization else { completion(error); return }
                    pane.close()
                    let writer = IndexWriterCoordinator.coordinator(for: repository)
                    writer.schedule("test closed discard revalidation", work: { [pane] () -> NSError? in
                        withExtendedLifetime(pane) {
                            do { try authorization.validate(); return nil }
                            catch { return error as NSError }
                        }
                    }, completion: { error in DispatchQueue.main.async { completion(error) } })
                }
            }

        #endif

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
                let writer = IndexWriterCoordinator.coordinator(for: repository)
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
