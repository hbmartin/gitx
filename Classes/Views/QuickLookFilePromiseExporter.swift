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
    let workingDirectoryPath: String
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
    case workingDirectory(repository: QuickLookGitRepositoryDescriptor, entries: [QuickLookWorkingTreeEntry])
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
              let gitDirectoryPath = repository.gitURL()?.path,
              let workingDirectoryURL = repository.workingDirectoryURL()
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
            workingDirectoryPath: workingDirectoryURL.path
        )
        if tree is PBWorkingTree {
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
            let entries = workingEntries(
                below: tree,
                rootPath: fullPath,
                workingDirectoryURL: workingDirectoryURL
            )
            return QuickLookExportDescriptor(
                fileName: fileName,
                isDirectory: true,
                source: .workingDirectory(repository: repositoryDescriptor, entries: entries)
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

    @MainActor
    private static func workingEntries(
        below tree: PBGitTree,
        rootPath: String,
        workingDirectoryURL: URL
    ) -> [QuickLookWorkingTreeEntry] {
        var entries: [QuickLookWorkingTreeEntry] = []
        let children = tree.value(forKey: "children") as? [PBGitTree] ?? []
        for child in children {
            if child.leaf {
                let repositoryPath = child.value(forKey: "fullPath") as? String ?? ""
                let relativePath: String
                if rootPath.isEmpty {
                    relativePath = repositoryPath
                } else {
                    let prefix = rootPath + "/"
                    guard repositoryPath.hasPrefix(prefix) else { continue }
                    relativePath = String(repositoryPath.dropFirst(prefix.count))
                }
                entries.append(workingEntry(
                    repositoryPath: repositoryPath,
                    relativePath: relativePath,
                    workingDirectoryURL: workingDirectoryURL
                ))
            } else {
                entries.append(contentsOf: workingEntries(
                    below: child,
                    rootPath: rootPath,
                    workingDirectoryURL: workingDirectoryURL
                ))
            }
        }
        return entries
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
    case unsupportedSubmodule(String)
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
        case let .unsupportedSubmodule(path):
            "GitX cannot export the submodule at \(path) as a promised file."
        case let .missingTree(path):
            "Git could not find any files below \(path)."
        }
    }
}

final nonisolated class QuickLookFilePromiseExporter: @unchecked Sendable {
    private struct GitTreeEntry {
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
            let data = try runGit(repository: repository, arguments: ["cat-file", "blob", "\(revision):\(path)"], path: path)
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
            for entry in entries {
                if entry.type == "commit" {
                    throw QuickLookExportError.unsupportedSubmodule(entry.path)
                }
                guard entry.type == "blob" else {
                    throw QuickLookExportError.malformedTreeEntry
                }
                guard entry.path.hasPrefix(prefix) else { throw QuickLookExportError.unsafePath(entry.path) }
                let relativePath = String(entry.path.dropFirst(prefix.count))
                try validate(path: relativePath)
                let data = try runGit(
                    repository: repository,
                    arguments: ["cat-file", "blob", entry.objectIdentifier],
                    path: entry.path
                )
                try createParentAndWrite(data, to: outputURL.appendingPathComponent(relativePath))
            }
        case let .workingFile(repository, entry):
            try exportWorkingEntry(entry, repository: repository, to: outputURL)
        case let .workingDirectory(repository, entries):
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: false)
            for entry in entries {
                try validate(path: entry.relativePath)
                try exportWorkingEntry(
                    entry,
                    repository: repository,
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
        to outputURL: URL
    ) throws {
        try validate(path: entry.relativePath)
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: entry.fileURL.path) {
            try fileManager.copyItem(at: entry.fileURL, to: outputURL)
            return
        }
        let data = try runGit(
            repository: repository,
            arguments: ["cat-file", "blob", ":\(entry.repositoryPath)"],
            path: entry.repositoryPath
        )
        try data.write(to: outputURL, options: .atomic)
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
        let task = PBTask(
            launchPath: repository.executablePath,
            arguments: ["--git-dir=\(repository.gitDirectoryPath)"] + arguments,
            inDirectory: repository.workingDirectoryPath
        )
        task.timeout = commandTimeout
        task.additionalEnvironment = [
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        do {
            try task.launch()
            return task.standardOutputData
        } catch {
            throw QuickLookExportError.commandFailed(path: path, detail: error.localizedDescription)
        }
    }

    private func parseTreeEntries(_ data: Data) throws -> [GitTreeEntry] {
        try data.split(separator: 0).map { rawRecord in
            guard let tab = rawRecord.firstIndex(of: 9),
                  let header = String(data: Data(rawRecord[..<tab]), encoding: .utf8),
                  let path = String(data: Data(rawRecord[rawRecord.index(after: tab)...]), encoding: .utf8)
            else { throw QuickLookExportError.malformedTreeEntry }
            let headerComponents = header.split(separator: " ")
            guard headerComponents.count == 3 else { throw QuickLookExportError.malformedTreeEntry }
            return GitTreeEntry(
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
