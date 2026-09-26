import Darwin
import Foundation

// SwiftLint analyze misclassifies this import; Logger and privacy interpolation require it at compile time.
// swiftlint:disable:next unused_import
import OSLog

private nonisolated let quickLookExportLogger = Logger(
    subsystem: "com.gitx.gitx",
    category: "QuickLookFilePromise"
)

nonisolated struct QuickLookGitRepositoryDescriptor: Sendable {
    let executablePath: String
    let gitDirectoryPath: String
    let workingDirectoryPath: String?
}

nonisolated struct QuickLookWorkingTreeEntry: Sendable, Equatable {
    let relativePath: String
    let repositoryPath: String
    let fileURL: URL
}

nonisolated enum QuickLookExportSource: Sendable {
    case committedFile(repository: QuickLookGitRepositoryDescriptor, revision: String, path: String)
    case committedDirectory(repository: QuickLookGitRepositoryDescriptor, revision: String, path: String)
    case workingFile(repository: QuickLookGitRepositoryDescriptor, entry: QuickLookWorkingTreeEntry)
    case workingDirectory(repository: QuickLookGitRepositoryDescriptor, rootPath: String)
    case unavailable(String)
}

nonisolated struct QuickLookExportDescriptor: Sendable {
    let fileName: String
    let isDirectory: Bool
    let source: QuickLookExportSource

    @MainActor
    static func make(tree: PBGitTree) -> QuickLookExportDescriptor {
        let fullPath = tree.value(forKey: "fullPath") as? String ?? ""
        let fileName = ((tree.value(forKey: "path") as? String ?? "") as NSString).lastPathComponent
        let isDirectory = !tree.leaf
        guard !fileName.isEmpty else {
            return QuickLookExportDescriptor(
                fileName: "GitX Export",
                isDirectory: isDirectory,
                source: .unavailable("GitX could not determine the selected repository item's name.")
            )
        }
        guard let repository = tree.value(forKey: "repository") as? PBGitRepository,
              let executablePath = PBGitBinary.path(),
              let gitDirectoryPath = repository.gitURL()?.path
        else {
            return QuickLookExportDescriptor(
                fileName: fileName,
                isDirectory: isDirectory,
                source: .unavailable("GitX could not retain the selected repository for export.")
            )
        }

        let repositoryDescriptor = QuickLookGitRepositoryDescriptor(
            executablePath: executablePath,
            gitDirectoryPath: gitDirectoryPath,
            workingDirectoryPath: repository.workingDirectoryURL()?.path
        )
        if tree is PBWorkingTree {
            guard let workingDirectoryURL = repository.workingDirectoryURL() else {
                return QuickLookExportDescriptor(
                    fileName: fileName,
                    isDirectory: isDirectory,
                    source: .unavailable("GitX could not locate the working directory for export.")
                )
            }
            if tree.leaf {
                let entry = workingEntry(
                    repositoryPath: fullPath,
                    relativePath: fileName,
                    workingDirectoryURL: workingDirectoryURL
                )
                return QuickLookExportDescriptor(
                    fileName: fileName,
                    isDirectory: false,
                    source: .workingFile(repository: repositoryDescriptor, entry: entry)
                )
            }
            return QuickLookExportDescriptor(
                fileName: fileName,
                isDirectory: true,
                source: .workingDirectory(repository: repositoryDescriptor, rootPath: fullPath)
            )
        }

        guard let revision = tree.value(forKey: "sha") as? String, !revision.isEmpty, !fullPath.isEmpty else {
            return QuickLookExportDescriptor(
                fileName: fileName,
                isDirectory: isDirectory,
                source: .unavailable("GitX could not determine the selected repository revision.")
            )
        }
        let source: QuickLookExportSource = if isDirectory {
            .committedDirectory(repository: repositoryDescriptor, revision: revision, path: fullPath)
        } else {
            .committedFile(repository: repositoryDescriptor, revision: revision, path: fullPath)
        }
        return QuickLookExportDescriptor(fileName: fileName, isDirectory: isDirectory, source: source)
    }

    private static func workingEntry(
        repositoryPath: String,
        relativePath: String,
        workingDirectoryURL: URL
    ) -> QuickLookWorkingTreeEntry {
        QuickLookWorkingTreeEntry(
            relativePath: relativePath,
            repositoryPath: repositoryPath,
            fileURL: workingDirectoryURL.appendingPathComponent(repositoryPath)
        )
    }
}

nonisolated enum QuickLookExportError: LocalizedError, Sendable {
    case unavailable(String)
    case unsafePath(String)
    case commandFailed(path: String, detail: String)
    case malformedTreeEntry
    case malformedBlobResponse(String)
    case invalidSymbolicLink(String)
    case unsupportedSubmodule(String)
    case unsupportedNestedRepository(String)
    case unrepresentablePath
    case missingTree(String)
    case filesystem(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        case let .unsafePath(path):
            "GitX refused to export an unsafe repository path: \(path)"
        case let .commandFailed(path, detail):
            "Git could not export \(path). \(detail)"
        case .malformedTreeEntry:
            "Git returned an invalid tree entry while exporting the promised directory."
        case let .malformedBlobResponse(path):
            "Git returned invalid blob data while exporting \(path)."
        case let .invalidSymbolicLink(path):
            "Git returned an invalid symbolic link while exporting \(path)."
        case let .unsupportedSubmodule(path):
            "GitX cannot export the submodule at \(path) as a promised file."
        case let .unsupportedNestedRepository(path):
            "GitX cannot export the nested repository at \(path) as a promised directory."
        case .unrepresentablePath:
            "Git returned a file name that GitX cannot represent as Unicode."
        case let .missingTree(path):
            "Git could not find any files below \(path)."
        case let .filesystem(path, code):
            "GitX could not access \(path): \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)."
        }
    }
}

/// All destination paths are resolved from this directory descriptor. In particular,
/// openat with O_NOFOLLOW prevents a repository link from becoming a parent of a write.
// swift6-safety-justification: The descriptor is immutable and used serially by one export and its PBTask chunk callback.
final nonisolated class StagedFileWriter: @unchecked Sendable {
    private let root: Int32

    init(rootURL: URL) throws {
        root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0 {
            throw QuickLookExportError.filesystem(path: rootURL.path, code: errno)
        }
    }

    deinit { close(root) }

    private func components(_ path: String) throws -> [String] {
        let pieces = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { throw QuickLookExportError.unsafePath(path) }
        return try pieces.map { bytes in
            guard !bytes.isEmpty, !bytes.elementsEqual([UInt8(46)]),
                  !bytes.elementsEqual([UInt8(46), 46]), !bytes.contains(0),
                  let component = String(bytes: bytes, encoding: .utf8)
            else { throw QuickLookExportError.unsafePath(path) }
            return component
        }
    }

    private func parent(of path: String, create: Bool) throws -> (Int32, String) {
        let parts = try components(path)
        var directory = dup(root)
        if directory < 0 {
            throw QuickLookExportError.filesystem(path: path, code: errno)
        }
        do {
            for component in parts.dropLast() {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    if mkdirat(directory, component, 0o755) != 0 && errno != EEXIST {
                        throw QuickLookExportError.filesystem(path: path, code: errno)
                    }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0 {
                    throw QuickLookExportError.filesystem(path: path, code: errno)
                }
                close(directory)
                directory = next
            }
            return (directory, parts[parts.count - 1])
        } catch {
            close(directory)
            throw error
        }
    }

    func createDirectory(_ path: String) throws {
        let (directory, name) = try parent(of: path, create: true)
        defer { close(directory) }
        if mkdirat(directory, name, 0o755) != 0 && errno != EEXIST {
            throw QuickLookExportError.filesystem(path: path, code: errno)
        }
        let descriptor = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            throw QuickLookExportError.filesystem(path: path, code: errno)
        }
        close(descriptor)
    }

    func openFile(_ path: String, permissions: mode_t = 0o644) throws -> FileHandle {
        let (directory, name) = try parent(of: path, create: true)
        defer { close(directory) }
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            throw QuickLookExportError.filesystem(path: path, code: errno)
        }
        if fchmod(descriptor, permissions) != 0 {
            let code = errno
            close(descriptor)
            throw QuickLookExportError.filesystem(path: path, code: code)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(_ data: Data, to path: String, permissions: mode_t = 0o644) throws {
        let handle = try openFile(path, permissions: permissions)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func createSymbolicLink(_ path: String, destination: String) throws {
        let (directory, name) = try parent(of: path, create: true)
        defer { close(directory) }
        if symlinkat(destination, directory, name) != 0 {
            throw QuickLookExportError.filesystem(path: path, code: errno)
        }
    }
}

// swift6-safety-justification: PBTask delivers chunks serially, and finish is called only after PBTask completes.
final nonisolated class GitBatchBlobWriter: @unchecked Sendable {
    nonisolated struct Target: Sendable {
        let mode: String
        let objectIdentifier: String
        let path: String
        let outputPath: String
    }

    private enum State {
        case header
        case body(Int)
        case separator
    }

    private static let maximumHeaderBytes = 256
    private static let maximumSymbolicLinkBytes = 4096

    private let targets: [Target]
    private let writer: StagedFileWriter
    private var buffer = Data()
    private var state: State = .header
    private var targetIndex = 0
    private var outputHandle: FileHandle?
    private var symbolicLinkData = Data()
    private var failure: Error?

    init(targets: [Target], writer: StagedFileWriter) {
        self.targets = targets
        self.writer = writer
    }

    func consume(_ chunk: Data) {
        guard failure == nil else { return }
        buffer.append(chunk)
        do {
            try consumeAvailableData()
        } catch {
            failure = error
            if let outputHandle {
                try? outputHandle.close()
            }
            outputHandle = nil
        }
    }

    func finish() throws {
        if let failure {
            throw failure
        }
        guard case .header = state, targetIndex == targets.count, buffer.isEmpty else {
            if let outputHandle {
                try? outputHandle.close()
                self.outputHandle = nil
            }
            throw QuickLookExportError.malformedBlobResponse(currentPath)
        }
    }

    private var currentPath: String {
        guard !targets.isEmpty else { return "directory" }
        return targets[min(targetIndex, targets.count - 1)].path
    }

    private func consumeAvailableData() throws {
        while true {
            switch state {
            case .header:
                guard targetIndex < targets.count else { return }
                guard let newline = buffer.firstIndex(of: 10) else {
                    if buffer.count > Self.maximumHeaderBytes {
                        throw QuickLookExportError.malformedBlobResponse(currentPath)
                    }
                    return
                }
                let headerSize = buffer.distance(from: buffer.startIndex, to: newline)
                guard headerSize <= Self.maximumHeaderBytes,
                      let header = String(data: Data(buffer.prefix(headerSize)), encoding: .utf8)
                else { throw QuickLookExportError.malformedBlobResponse(currentPath) }
                buffer.removeFirst(headerSize + 1)
                let components = header.split(separator: " ", omittingEmptySubsequences: false)
                let target = targets[targetIndex]
                guard components.count == 3,
                      components[0] == target.objectIdentifier,
                      components[1] == "blob",
                      let size = Int(components[2]),
                      size >= 0
                else { throw QuickLookExportError.malformedBlobResponse(target.path) }
                if target.mode == "120000" {
                    guard size <= Self.maximumSymbolicLinkBytes else {
                        throw QuickLookExportError.invalidSymbolicLink(target.path)
                    }
                } else {
                    try beginRegularFile(target)
                }
                state = .body(size)

            case let .body(remaining):
                if remaining == 0 {
                    state = .separator
                    continue
                }
                guard !buffer.isEmpty else { return }
                let byteCount = min(remaining, buffer.count)
                let bytes = Data(buffer.prefix(byteCount))
                if targets[targetIndex].mode == "120000" {
                    symbolicLinkData.append(bytes)
                } else {
                    guard let outputHandle else {
                        throw QuickLookExportError.malformedBlobResponse(currentPath)
                    }
                    try outputHandle.write(contentsOf: bytes)
                }
                buffer.removeFirst(byteCount)
                state = .body(remaining - byteCount)

            case .separator:
                guard let separator = buffer.first else { return }
                guard separator == 10 else { throw QuickLookExportError.malformedBlobResponse(currentPath) }
                buffer.removeFirst()
                try finishTarget(targets[targetIndex])
                targetIndex += 1
                state = .header
            }
        }
    }

    private func beginRegularFile(_ target: Target) throws {
        outputHandle = try writer.openFile(target.outputPath, permissions: target.mode == "100755" ? 0o755 : 0o644)
    }

    private func finishTarget(_ target: Target) throws {
        if target.mode == "120000" {
            guard !symbolicLinkData.isEmpty,
                  !symbolicLinkData.contains(0),
                  let destination = String(data: symbolicLinkData, encoding: .utf8)
            else { throw QuickLookExportError.invalidSymbolicLink(target.path) }
            try writer.createSymbolicLink(target.outputPath, destination: destination)
            symbolicLinkData.removeAll(keepingCapacity: true)
            return
        }
        guard let outputHandle else { throw QuickLookExportError.malformedBlobResponse(target.path) }
        try outputHandle.close()
        self.outputHandle = nil
    }
}

// swift6-safety-justification: Configuration is immutable, and each export confines mutable filesystem state to its unique staging directory.
final nonisolated class QuickLookFilePromiseExporter: @unchecked Sendable {
    private struct GitTreeEntry {
        let mode: String
        let type: String
        let objectIdentifier: String
        let path: String
    }

    private struct IndexEntry {
        let mode: String
        let objectIdentifier: String
    }

    private let fileManager: FileManager
    private let commandTimeout: TimeInterval

    init(fileManager: FileManager = .default, commandTimeout: TimeInterval = 30) {
        self.fileManager = fileManager
        self.commandTimeout = commandTimeout
    }

    func export(_ descriptor: QuickLookExportDescriptor, to destinationURL: URL) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".gitx-file-promise-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedOutputURL = stagingURL.appendingPathComponent("promised-output", isDirectory: descriptor.isDirectory)
        var exportError: Error?
        var movedOutput = false

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            let writer = try StagedFileWriter(rootURL: stagingURL)
            try exportSource(descriptor.source, writer: writer, outputPath: "promised-output")
            try fileManager.moveItem(at: stagedOutputURL, to: destinationURL)
            movedOutput = true
        } catch {
            exportError = error
        }

        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
        } catch {
            quickLookExportLogger.error(
                "Could not remove file-promise staging directory \(stagingURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if !movedOutput, exportError == nil {
                exportError = error
            }
        }

        if let exportError {
            quickLookExportLogger.error(
                "Failed to export promised item to \(destinationURL.path, privacy: .public): \(exportError.localizedDescription, privacy: .public)"
            )
            throw exportError
        }
        quickLookExportLogger.info("Exported promised item to \(destinationURL.path, privacy: .public)")
    }

    private func exportSource(_ source: QuickLookExportSource, writer: StagedFileWriter, outputPath: String) throws {
        switch source {
        case let .committedFile(repository, revision, path):
            try validate(path: path)
            let entries = try parseTreeEntries(runGit(
                repository: repository, arguments: ["ls-tree", "-z", revision, "--", path], path: path
            ))
            guard let entry = entries.first(where: { $0.path.utf8.elementsEqual(path.utf8) }) else {
                throw QuickLookExportError.missingTree(path)
            }
            if entry.type == "commit" {
                throw QuickLookExportError.unsupportedSubmodule(path)
            }
            try writeBlob(entry, repository: repository, writer: writer, outputPath: outputPath)
        case let .committedDirectory(repository, revision, path):
            try validate(path: path)
            try writer.createDirectory(outputPath)
            let treeData = try runGit(
                repository: repository,
                arguments: ["ls-tree", "-r", "-z", revision, "--", path],
                path: path
            )
            let entries = try parseTreeEntries(treeData)
            if entries.isEmpty {
                let selectedEntries = try parseTreeEntries(runGit(
                    repository: repository,
                    arguments: ["ls-tree", "-z", revision, "--", path],
                    path: path
                ))
                if selectedEntries.contains(where: { $0.type == "commit" }) {
                    throw QuickLookExportError.unsupportedSubmodule(path)
                }
                throw QuickLookExportError.missingTree(path)
            }
            let prefix = Array((path + "/").utf8)
            let targets = try entries.map { entry -> GitBatchBlobWriter.Target in
                if entry.type == "commit" {
                    throw QuickLookExportError.unsupportedSubmodule(entry.path)
                }
                let identifier = entry.objectIdentifier.utf8
                guard entry.type == "blob", ["100644", "100755", "120000"].contains(entry.mode),
                      validObjectIdentifier(identifier)
                else {
                    throw QuickLookExportError.malformedTreeEntry
                }
                let pathBytes = Array(entry.path.utf8)
                guard pathBytes.starts(with: prefix),
                      let relativePath = String(bytes: pathBytes.dropFirst(prefix.count), encoding: .utf8)
                else { throw QuickLookExportError.unsafePath(entry.path) }
                try validate(path: relativePath)
                return GitBatchBlobWriter.Target(
                    mode: entry.mode,
                    objectIdentifier: entry.objectIdentifier,
                    path: entry.path,
                    outputPath: outputPath + "/" + relativePath
                )
            }
            let paths = Set(targets.map { Data($0.outputPath.utf8) })
            guard paths.count == targets.count else { throw QuickLookExportError.malformedTreeEntry }
            for target in targets {
                var parent = target.outputPath
                while let slash = parent.utf8.lastIndex(of: 47) {
                    parent = String(decoding: parent.utf8[..<slash], as: UTF8.self)
                    if paths.contains(Data(parent.utf8)) {
                        throw QuickLookExportError.malformedTreeEntry
                    }
                }
            }
            let regular = targets.filter { $0.mode != "120000" }
            let links = targets.filter { $0.mode == "120000" }
            try exportCommittedBlobs(regular + links, repository: repository, path: path, writer: writer)
        case let .workingFile(repository, entry):
            let index = try workingIndexEntries(repository: repository, rootPath: entry.repositoryPath)
            let observed = Result { try fileType(at: entry.fileURL) }
            try exportWorkingEntry(entry, repository: repository, indexEntry: index[Data(entry.repositoryPath.utf8)],
                                   observed: observed, writer: writer, outputPath: outputPath)
        case let .workingDirectory(repository, rootPath):
            try validate(path: rootPath)
            let index = try workingIndexEntries(repository: repository, rootPath: rootPath)
            let entries = try workingEntries(repository: repository, rootPath: rootPath)
            try writer.createDirectory(outputPath)
            var exportedLeaves = Set<Data>()
            for entry in entries.sorted(by: { $0.repositoryPath.utf8.lexicographicallyPrecedes($1.repositoryPath.utf8) }) {
                if hasAncestor(entry.repositoryPath, in: exportedLeaves) {
                    quickLookExportLogger.info("Skipping stale descendant \(entry.repositoryPath, privacy: .public)")
                    continue
                }
                if entry.relativePath.isEmpty {
                    quickLookExportLogger.info("Copying selected nested repository \(rootPath, privacy: .public)")
                    guard let kind = try fileType(at: entry.fileURL) else {
                        throw QuickLookExportError.filesystem(path: entry.repositoryPath, code: ENOENT)
                    }
                    try copyWorkingItem(at: entry.fileURL, kind: kind, writer: writer, outputPath: outputPath)
                    exportedLeaves.insert(Data(entry.repositoryPath.utf8))
                    continue
                }
                let observed = Result { try fileType(at: entry.fileURL) }
                let kind = try? observed.get()
                if kind == mode_t(S_IFDIR) && index[Data(entry.repositoryPath.utf8)] != nil {
                    // An indexed file became a directory; copy its current contents.
                    quickLookExportLogger.info("Copying directory that replaced indexed file \(entry.repositoryPath, privacy: .public)")
                    try copyWorkingItem(at: entry.fileURL, kind: mode_t(S_IFDIR), writer: writer,
                                        outputPath: outputPath + "/" + entry.relativePath)
                    exportedLeaves.insert(Data(entry.repositoryPath.utf8))
                    continue
                }
                try exportWorkingEntry(
                    entry,
                    repository: repository,
                    indexEntry: index[Data(entry.repositoryPath.utf8)],
                    observed: observed,
                    writer: writer,
                    outputPath: outputPath + "/" + entry.relativePath
                )
                if kind == mode_t(S_IFLNK) || kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) {
                    exportedLeaves.insert(Data(entry.repositoryPath.utf8))
                }
            }
        case let .unavailable(message):
            throw QuickLookExportError.unavailable(message)
        }
    }

    private func exportWorkingEntry(
        _ entry: QuickLookWorkingTreeEntry,
        repository: QuickLookGitRepositoryDescriptor,
        indexEntry: IndexEntry?,
        observed: Result<mode_t?, Error>,
        writer: StagedFileWriter,
        outputPath: String
    ) throws {
        try validate(path: entry.relativePath)
        let existingType: mode_t?
        switch observed {
        case let .success(kind):
            existingType = kind
        case let .failure(error):
            if indexEntry == nil {
                throw error
            }
            existingType = nil
        }
        if let existingType {
            try copyWorkingItem(at: entry.fileURL, kind: existingType, writer: writer, outputPath: outputPath)
            return
        }
        guard let indexEntry else {
            throw QuickLookExportError.filesystem(path: entry.repositoryPath, code: ENOENT)
        }
        quickLookExportLogger.info("Restoring unavailable working entry from index \(entry.repositoryPath, privacy: .public)")
        if indexEntry.mode == "160000" {
            throw QuickLookExportError.unsupportedSubmodule(entry.repositoryPath)
        }
        let data = try runGit(
            repository: repository,
            arguments: ["cat-file", "blob", indexEntry.objectIdentifier],
            path: entry.repositoryPath
        )
        if indexEntry.mode == "120000" {
            guard !data.isEmpty, data.count <= 4096, !data.contains(0),
                  let destination = String(data: data, encoding: .utf8)
            else { throw QuickLookExportError.invalidSymbolicLink(entry.repositoryPath) }
            try writer.createSymbolicLink(outputPath, destination: destination)
            return
        }
        try writer.write(data, to: outputPath, permissions: indexEntry.mode == "100755" ? 0o755 : 0o644)
    }

    private func workingEntries(
        repository: QuickLookGitRepositoryDescriptor,
        rootPath: String
    ) throws -> [QuickLookWorkingTreeEntry] {
        guard let workingDirectoryPath = repository.workingDirectoryPath else {
            throw QuickLookExportError.unavailable("GitX could not locate the working directory for export.")
        }
        let visible = try runGit(
            repository: repository,
            arguments: ["ls-files", "-co", "--exclude-standard", "-z", "--", rootPath],
            path: rootPath
        )
        var seen = Set<Data>()
        var entries: [QuickLookWorkingTreeEntry] = []
        for record in try nulRecords(visible) {
            guard let path = String(data: record, encoding: .utf8) else {
                throw QuickLookExportError.unrepresentablePath
            }
            let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
            if path.hasSuffix("/"), normalizedPath.utf8.elementsEqual(rootPath.utf8) {
                guard seen.insert(Data(normalizedPath.utf8)).inserted else { continue }
                entries.append(QuickLookWorkingTreeEntry(
                    relativePath: "", repositoryPath: normalizedPath,
                    fileURL: URL(fileURLWithPath: workingDirectoryPath).appendingPathComponent(normalizedPath)
                ))
                continue
            }
            let prefix = Array((rootPath + "/").utf8)
            let pathBytes = Array(normalizedPath.utf8)
            guard pathBytes.starts(with: prefix),
                  let relativePath = String(bytes: pathBytes.dropFirst(prefix.count), encoding: .utf8)
            else {
                throw QuickLookExportError.unsafePath(path)
            }
            try validate(path: relativePath)
            guard seen.insert(Data(normalizedPath.utf8)).inserted else { continue }
            entries.append(QuickLookWorkingTreeEntry(
                relativePath: relativePath,
                repositoryPath: normalizedPath,
                fileURL: URL(fileURLWithPath: workingDirectoryPath).appendingPathComponent(normalizedPath)
            ))
        }
        guard !entries.isEmpty else { throw QuickLookExportError.missingTree(rootPath) }
        return entries
    }

    private func workingIndexEntries(
        repository: QuickLookGitRepositoryDescriptor,
        rootPath: String
    ) throws -> [Data: IndexEntry] {
        let data = try runGit(
            repository: repository,
            arguments: ["ls-files", "--stage", "-z", "--", rootPath],
            path: rootPath
        )
        var entries: [Data: IndexEntry] = [:]
        for record in try nulRecords(data) {
            guard let tab = record.firstIndex(of: 9),
                  let header = String(data: record[..<tab], encoding: .utf8),
                  let path = String(data: record[record.index(after: tab)...], encoding: .utf8)
            else { throw QuickLookExportError.unrepresentablePath }
            let parts = header.split(separator: " ")
            guard parts.count == 3 else { throw QuickLookExportError.malformedTreeEntry }
            if parts[2] != "0" {
                continue
            }
            let mode = String(parts[0])
            guard ["100644", "100755", "120000", "160000"].contains(mode),
                  validObjectIdentifier(parts[1].utf8)
            else { throw QuickLookExportError.malformedTreeEntry }
            entries[Data(path.utf8)] = IndexEntry(mode: mode, objectIdentifier: String(parts[1]))
        }
        return entries
    }

    private func nulRecords(_ data: Data) throws -> [Data] {
        guard data.isEmpty || data.last == 0 else { throw QuickLookExportError.malformedTreeEntry }
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        guard data.isEmpty || records.dropLast().allSatisfy({ !$0.isEmpty }) else {
            throw QuickLookExportError.malformedTreeEntry
        }
        return data.isEmpty ? [] : records.dropLast().map(Data.init)
    }

    private func fileType(at url: URL) throws -> mode_t? {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result == 0 {
            return status.st_mode & mode_t(S_IFMT)
        }
        if errno == ENOENT || errno == ENOTDIR {
            return nil
        }
        throw QuickLookExportError.filesystem(path: url.path, code: errno)
    }

    private func validObjectIdentifier<S: Collection>(_ bytes: S) -> Bool where S.Element == UInt8 {
        (bytes.count == 40 || bytes.count == 64)
            && bytes.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private func hasAncestor(_ path: String, in leaves: Set<Data>) -> Bool {
        let bytes = Array(path.utf8)
        for index in bytes.indices where bytes[index] == 47 {
            if leaves.contains(Data(bytes[..<index])) {
                return true
            }
        }
        return false
    }

    private func writeBlob(
        _ entry: GitTreeEntry,
        repository: QuickLookGitRepositoryDescriptor,
        writer: StagedFileWriter,
        outputPath: String
    ) throws {
        guard entry.type == "blob", ["100644", "100755", "120000"].contains(entry.mode),
              validObjectIdentifier(entry.objectIdentifier.utf8)
        else { throw QuickLookExportError.malformedTreeEntry }
        let data = try runGit(repository: repository, arguments: ["cat-file", "blob", entry.objectIdentifier], path: entry.path)
        if entry.mode == "120000" {
            guard !data.isEmpty, data.count <= 4096, !data.contains(0),
                  let destination = String(data: data, encoding: .utf8)
            else { throw QuickLookExportError.invalidSymbolicLink(entry.path) }
            try writer.createSymbolicLink(outputPath, destination: destination)
        } else {
            try writer.write(data, to: outputPath, permissions: entry.mode == "100755" ? 0o755 : 0o644)
        }
    }

    private func copyWorkingItem(at source: URL, kind: mode_t, writer: StagedFileWriter, outputPath: String) throws {
        switch kind {
        case mode_t(S_IFDIR):
            try writer.createDirectory(outputPath)
            for name in try fileManager.contentsOfDirectory(atPath: source.path) {
                try validate(path: name)
                let child = source.appendingPathComponent(name)
                guard let childKind = try fileType(at: child) else {
                    throw QuickLookExportError.filesystem(path: child.path, code: ENOENT)
                }
                try copyWorkingItem(
                    at: child, kind: childKind, writer: writer, outputPath: outputPath + "/" + name
                )
            }
        case mode_t(S_IFLNK):
            let destination = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try writer.createSymbolicLink(outputPath, destination: destination)
        case mode_t(S_IFREG):
            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                throw QuickLookExportError.filesystem(path: source.path, code: errno)
            }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw QuickLookExportError.filesystem(path: source.path, code: errno)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw QuickLookExportError.filesystem(path: source.path, code: EAGAIN)
            }
            let output = try writer.openFile(outputPath, permissions: status.st_mode & 0o777)
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.close()
        default:
            throw QuickLookExportError.filesystem(path: source.path, code: EINVAL)
        }
    }

    private func runGit(
        repository: QuickLookGitRepositoryDescriptor,
        arguments: [String],
        path: String
    ) throws -> Data {
        let task = makeGitTask(repository: repository, arguments: arguments)
        do {
            try task.launch()
            logGitDiagnostics(task.standardErrorData, path: path)
            return task.standardOutputData
        } catch {
            throw QuickLookExportError.commandFailed(path: path, detail: commandFailureDetail(task, error: error))
        }
    }

    private func exportCommittedBlobs(
        _ targets: [GitBatchBlobWriter.Target],
        repository: QuickLookGitRepositoryDescriptor,
        path: String,
        writer: StagedFileWriter
    ) throws {
        let task = makeGitTask(repository: repository, arguments: ["cat-file", "--batch"])
        task.capturesStandardOutput = false
        task.standardInputData = Data((targets.map(\.objectIdentifier).joined(separator: "\n") + "\n").utf8)
        let batchWriter = GitBatchBlobWriter(targets: targets, writer: writer)
        quickLookExportLogger.info("Streaming \(targets.count) committed blobs for \(path, privacy: .public)")
        do {
            try task.launch(outputChunkHandler: { batchWriter.consume($0) })
            logGitDiagnostics(task.standardErrorData, path: path)
        } catch {
            throw QuickLookExportError.commandFailed(path: path, detail: commandFailureDetail(task, error: error))
        }
        try batchWriter.finish()
    }

    private func commandFailureDetail(_ task: PBTask, error: Error) -> String {
        let diagnostics = String(decoding: task.standardErrorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostics.isEmpty ? error.localizedDescription : "\(error.localizedDescription) \(diagnostics)"
    }

    private func logGitDiagnostics(_ data: Data, path: String) {
        guard !data.isEmpty else { return }
        let diagnostics = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        quickLookExportLogger.info("Git reported diagnostics while exporting \(path, privacy: .public): \(diagnostics, privacy: .public)")
    }

    private func makeGitTask(
        repository: QuickLookGitRepositoryDescriptor,
        arguments: [String]
    ) -> PBTask {
        let task = PBTask(
            launchPath: repository.executablePath,
            arguments: ["--git-dir=\(repository.gitDirectoryPath)"] + arguments,
            inDirectory: repository.workingDirectoryPath
        )
        task.timeout = commandTimeout
        task.separatesStandardError = true
        task.additionalEnvironment = [
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_LITERAL_PATHSPECS": "1",
            "GIT_GLOB_PATHSPECS": "0",
            "GIT_ICASE_PATHSPECS": "0",
            "GIT_NOGLOB_PATHSPECS": "0",
        ]
        return task
    }

    private func parseTreeEntries(_ data: Data) throws -> [GitTreeEntry] {
        try data.split(separator: 0).map { rawRecord in
            guard let tab = rawRecord.firstIndex(of: 9),
                  let header = String(data: Data(rawRecord[..<tab]), encoding: .utf8)
            else { throw QuickLookExportError.malformedTreeEntry }
            guard let path = String(data: Data(rawRecord[rawRecord.index(after: tab)...]), encoding: .utf8)
            else { throw QuickLookExportError.unrepresentablePath }
            let headerComponents = header.split(separator: " ")
            guard headerComponents.count == 3 else { throw QuickLookExportError.malformedTreeEntry }
            return GitTreeEntry(
                mode: String(headerComponents[0]),
                type: String(headerComponents[1]),
                objectIdentifier: String(headerComponents[2]),
                path: path
            )
        }
    }

    private func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else { throw QuickLookExportError.unsafePath(path) }
        let components = (path as NSString).pathComponents
        guard !components.contains("."), !components.contains("..") else {
            throw QuickLookExportError.unsafePath(path)
        }
    }
}
