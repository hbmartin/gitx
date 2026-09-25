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
        }
    }
}

// swift6-safety-justification: PBTask delivers chunks serially, and finish is called only after PBTask completes.
final nonisolated class GitBatchBlobWriter: @unchecked Sendable {
    nonisolated struct Target: Sendable {
        let mode: String
        let objectIdentifier: String
        let path: String
        let outputURL: URL
    }

    private enum State {
        case header
        case body(Int)
        case separator
    }

    private static let maximumHeaderBytes = 256
    private static let maximumSymbolicLinkBytes = 4096

    private let targets: [Target]
    private let fileManager: FileManager
    private var buffer = Data()
    private var state: State = .header
    private var targetIndex = 0
    private var outputHandle: FileHandle?
    private var symbolicLinkData = Data()
    private var failure: Error?

    init(targets: [Target], fileManager: FileManager) {
        self.targets = targets
        self.fileManager = fileManager
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
        try fileManager.createDirectory(
            at: target.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: target.outputURL.path),
              fileManager.createFile(atPath: target.outputURL.path, contents: nil)
        else { throw QuickLookExportError.malformedTreeEntry }
        outputHandle = try FileHandle(forWritingTo: target.outputURL)
    }

    private func finishTarget(_ target: Target) throws {
        if target.mode == "120000" {
            guard !symbolicLinkData.isEmpty,
                  !symbolicLinkData.contains(0),
                  let destination = String(data: symbolicLinkData, encoding: .utf8)
            else { throw QuickLookExportError.invalidSymbolicLink(target.path) }
            try fileManager.createDirectory(
                at: target.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(
                atPath: target.outputURL.path,
                withDestinationPath: destination
            )
            symbolicLinkData.removeAll(keepingCapacity: true)
            return
        }
        guard let outputHandle else { throw QuickLookExportError.malformedBlobResponse(target.path) }
        try outputHandle.close()
        self.outputHandle = nil
        if target.mode == "100755" {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.outputURL.path)
        }
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
            try exportSource(descriptor.source, to: stagedOutputURL)
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

    private func exportSource(_ source: QuickLookExportSource, to outputURL: URL) throws {
        switch source {
        case let .committedFile(repository, revision, path):
            try validate(path: path)
            let data: Data
            do {
                data = try runGit(repository: repository, arguments: ["cat-file", "blob", "\(revision):\(path)"], path: path)
            } catch {
                if let treeData = try? runGit(
                    repository: repository,
                    arguments: ["ls-tree", "-z", revision, "--", path],
                    path: path
                ), let entries = try? parseTreeEntries(treeData),
                entries.contains(where: { $0.path == path && $0.type == "commit" }) {
                    throw QuickLookExportError.unsupportedSubmodule(path)
                }
                throw error
            }
            try createParentAndWrite(data, to: outputURL)
        case let .committedDirectory(repository, revision, path):
            try validate(path: path)
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: false)
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
            let prefix = path + "/"
            let targets = try entries.map { entry -> GitBatchBlobWriter.Target in
                if entry.type == "commit" {
                    throw QuickLookExportError.unsupportedSubmodule(entry.path)
                }
                let identifier = entry.objectIdentifier.utf8
                guard entry.type == "blob",
                      identifier.count == 40 || identifier.count == 64,
                      identifier.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
                else {
                    throw QuickLookExportError.malformedTreeEntry
                }
                guard entry.path.hasPrefix(prefix) else { throw QuickLookExportError.unsafePath(entry.path) }
                let relativePath = String(entry.path.dropFirst(prefix.count))
                try validate(path: relativePath)
                return GitBatchBlobWriter.Target(
                    mode: entry.mode,
                    objectIdentifier: entry.objectIdentifier,
                    path: entry.path,
                    outputURL: outputURL.appendingPathComponent(relativePath)
                )
            }
            let regular = targets.filter { $0.mode != "120000" }
            let links = targets.filter { $0.mode == "120000" }
            try exportCommittedBlobs(regular + links, repository: repository, path: path)
        case let .workingFile(repository, entry):
            let modes = try workingIndexModes(repository: repository, rootPath: entry.repositoryPath)
            try exportWorkingEntry(entry, repository: repository, indexMode: modes[entry.repositoryPath], to: outputURL)
        case let .workingDirectory(repository, rootPath):
            try validate(path: rootPath)
            let modes = try workingIndexModes(repository: repository, rootPath: rootPath)
            let entries = try workingEntries(repository: repository, rootPath: rootPath)
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: false)
            let regular = try entries.filter { try !isSymbolicLink(at: $0.fileURL, indexMode: modes[$0.repositoryPath]) }
            let links = try entries.filter { try isSymbolicLink(at: $0.fileURL, indexMode: modes[$0.repositoryPath]) }
            for entry in regular + links {
                try exportWorkingEntry(
                    entry,
                    repository: repository,
                    indexMode: modes[entry.repositoryPath],
                    to: outputURL.appendingPathComponent(entry.relativePath)
                )
            }
        case let .unavailable(message):
            throw QuickLookExportError.unavailable(message)
        }
    }

    private func exportWorkingEntry(
        _ entry: QuickLookWorkingTreeEntry,
        repository: QuickLookGitRepositoryDescriptor,
        indexMode: String?,
        to outputURL: URL
    ) throws {
        try validate(path: entry.relativePath)
        if indexMode == "160000" {
            throw QuickLookExportError.unsupportedSubmodule(entry.repositoryPath)
        }
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let mode = try fileType(at: entry.fileURL) {
            guard mode != S_IFDIR else {
                throw QuickLookExportError.unsupportedNestedRepository(entry.repositoryPath)
            }
            try fileManager.copyItem(at: entry.fileURL, to: outputURL)
            return
        }
        let data = try runGit(
            repository: repository,
            arguments: ["cat-file", "blob", ":\(entry.repositoryPath)"],
            path: entry.repositoryPath
        )
        if indexMode == "120000" {
            guard !data.isEmpty, data.count <= 4096, !data.contains(0),
                  let destination = String(data: data, encoding: .utf8)
            else { throw QuickLookExportError.invalidSymbolicLink(entry.repositoryPath) }
            try fileManager.createSymbolicLink(atPath: outputURL.path, withDestinationPath: destination)
            return
        }
        try data.write(to: outputURL, options: .atomic)
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
        var seen = Set<String>()
        var entries: [QuickLookWorkingTreeEntry] = []
        for record in try nulRecords(visible) {
            guard let path = String(data: record, encoding: .utf8) else {
                throw QuickLookExportError.unrepresentablePath
            }
            if path.hasSuffix("/") {
                throw QuickLookExportError.unsupportedNestedRepository(String(path.dropLast()))
            }
            guard path.hasPrefix(rootPath + "/") else {
                throw QuickLookExportError.unsafePath(path)
            }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            try validate(path: relativePath)
            guard seen.insert(path).inserted else { continue }
            entries.append(QuickLookWorkingTreeEntry(
                relativePath: relativePath,
                repositoryPath: path,
                fileURL: URL(fileURLWithPath: workingDirectoryPath).appendingPathComponent(path)
            ))
        }
        guard !entries.isEmpty else { throw QuickLookExportError.missingTree(rootPath) }
        return entries
    }

    private func workingIndexModes(
        repository: QuickLookGitRepositoryDescriptor,
        rootPath: String
    ) throws -> [String: String] {
        let data = try runGit(
            repository: repository,
            arguments: ["ls-files", "--stage", "-z", "--", rootPath],
            path: rootPath
        )
        var modes: [String: String] = [:]
        for record in try nulRecords(data) {
            guard let tab = record.firstIndex(of: 9),
                  let header = String(data: record[..<tab], encoding: .utf8),
                  let path = String(data: record[record.index(after: tab)...], encoding: .utf8)
            else { throw QuickLookExportError.unrepresentablePath }
            let parts = header.split(separator: " ")
            guard parts.count == 3 else { throw QuickLookExportError.malformedTreeEntry }
            modes[path] = String(parts[0])
        }
        return modes
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
        if errno == ENOENT {
            return nil
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func isSymbolicLink(at url: URL, indexMode: String?) throws -> Bool {
        if let type = try fileType(at: url) {
            return type == mode_t(S_IFLNK)
        }
        return indexMode == "120000"
    }

    private func createParentAndWrite(_ data: Data, to outputURL: URL) throws {
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
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
        path: String
    ) throws {
        let task = makeGitTask(repository: repository, arguments: ["cat-file", "--batch"])
        task.capturesStandardOutput = false
        task.standardInputData = Data((targets.map(\.objectIdentifier).joined(separator: "\n") + "\n").utf8)
        let writer = GitBatchBlobWriter(targets: targets, fileManager: fileManager)
        quickLookExportLogger.info("Streaming \(targets.count) committed blobs for \(path, privacy: .public)")
        do {
            try task.launch(outputChunkHandler: { writer.consume($0) })
            logGitDiagnostics(task.standardErrorData, path: path)
        } catch {
            throw QuickLookExportError.commandFailed(path: path, detail: commandFailureDetail(task, error: error))
        }
        try writer.finish()
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
