import CryptoKit
import Foundation
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

/// Recognizes Git LFS pointers in the blob bytes Git returns without smudging, and finds their objects in the
/// local store. Every command it runs is local: `git show` and `git cat-file` never run the smudge filter, and
/// `check-attr`, `rev-parse` and `config` never contact a remote.
nonisolated struct LFSPointerInspector: Sendable {
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "LFS")

    enum Resolution: Equatable, Sendable {
        /// Not an LFS pointer, so the bytes are the content.
        case ordinary
        /// A pointer whose object is in the local store and matches its digest.
        case stored(LFSPointer, URL)
        /// A pointer GitX cannot replace with its object, and why.
        case pointer(LFSPointer, LFSObjectStore.Decision)

        /// The placeholder to show instead of content, or nil when there is content to show.
        var placeholder: String? {
            guard case let .pointer(pointer, decision) = self else { return nil }
            return decision == .tooLargeToPreview
                ? LFSPresentation.tooLargePlaceholder(for: pointer)
                : LFSPresentation.placeholder(for: pointer)
        }

        /// The size of the content the bytes stand for.
        func contentSize(ofBlobSize size: Int64) -> Int64 {
            switch self {
            case .ordinary: size
            case let .stored(pointer, _), let .pointer(pointer, _): pointer.size
            }
        }
    }

    let executablePath: String
    /// The repository's Git directory, or nil to let Git find it from the working directory.
    let gitDirectoryPath: String?
    let workingDirectoryPath: String?

    init(executablePath: String, gitDirectoryPath: String?, workingDirectoryPath: String?) {
        self.executablePath = executablePath
        self.gitDirectoryPath = gitDirectoryPath
        self.workingDirectoryPath = workingDirectoryPath
    }

    init?(repository: PBGitRepository) {
        guard let executable = PBGitBinary.path(), let gitDirectory = repository.gitURL()?.path else { return nil }
        self.init(
            executablePath: executable,
            gitDirectoryPath: gitDirectory,
            workingDirectoryPath: repository.workingDirectoryURL()?.path
        )
    }

    /// Classifies blob bytes stored at a repository-relative path. Pass `trackedByLFS` when a batch query already
    /// read the path's `filter` attribute.
    func resolve(_ data: Data, path: String, trackedByLFS: Bool? = nil) -> Resolution {
        guard data.count < LFSPointer.maximumSize, let pointer = LFSPointer.parse(data) else { return .ordinary }
        guard trackedByLFS ?? isTrackedByLFS(path) else {
            Self.logger.info("\(path, privacy: .private) holds pointer text but is not tracked by Git LFS")
            return .ordinary
        }
        guard let object = objectURL(for: pointer) else {
            Self.logger.error("Could not locate the Git LFS store for \(path, privacy: .private)")
            return .pointer(pointer, .missing)
        }
        let storedSize = (try? FileManager.default.attributesOfItem(atPath: object.path)[.size] as? NSNumber)?.int64Value
        let decision = LFSObjectStore.decision(for: pointer, storedSize: storedSize)
        guard decision == .verify else {
            Self.logger.info(
                "Git LFS object \(pointer.abbreviatedOID, privacy: .public) for \(path, privacy: .private) is \(String(describing: decision), privacy: .public)"
            )
            return .pointer(pointer, decision)
        }
        guard Self.digest(of: object) == pointer.oid else {
            Self.logger.error("Git LFS object \(pointer.abbreviatedOID, privacy: .public) failed digest verification")
            return .pointer(pointer, .incomplete)
        }
        Self.logger.debug("Showing stored Git LFS object \(pointer.abbreviatedOID, privacy: .public)")
        return .stored(pointer, object)
    }

    /// The bytes to show for a blob: the blob itself, its stored object, or nil when only a placeholder fits.
    func displayData(for data: Data, path: String) -> Data? {
        switch resolve(data, path: path) {
        case .ordinary:
            data
        case let .stored(_, url):
            try? Data(contentsOf: url, options: .mappedIfSafe)
        case .pointer:
            nil
        }
    }

    // MARK: Git

    func isTrackedByLFS(_ path: String) -> Bool {
        guard let output = run(["check-attr", "-z", "filter", "--", path]) else { return false }
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        return fields.count >= 3 && fields[2].elementsEqual("lfs".utf8)
    }

    func objectURL(for pointer: LFSPointer) -> URL? {
        guard let gitDirectory = gitDirectoryPath ?? text(["rev-parse", "--absolute-git-dir"]) else { return nil }
        let common = Self.commonDirectory(ofGitDirectory: gitDirectory)
        let storage = LFSObjectStore.storageDirectory(
            commonDirectory: common,
            configuredStorage: text(["config", "--get", "lfs.storage"])
        )
        return URL(fileURLWithPath: LFSObjectStore.objectPath(for: pointer, storageDirectory: storage))
    }

    /// A linked worktree's Git directory names the shared directory in its `commondir` file.
    static func commonDirectory(ofGitDirectory gitDirectory: String) -> String {
        let file = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return gitDirectory }
        let relative = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relative.isEmpty else { return gitDirectory }
        let path = relative.hasPrefix("/") ? relative : (gitDirectory as NSString).appendingPathComponent(relative)
        return (path as NSString).standardizingPath
    }

    static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` returns nil or empty data at the end of the file, and throws only on a read error.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                Self.logger.error("Could not read a Git LFS object to verify it: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func text(_ arguments: [String]) -> String? {
        guard let data = run(arguments), let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func run(_ arguments: [String]) -> Data? {
        let prefix = gitDirectoryPath.map { ["--git-dir=\($0)"] } ?? []
        let task = PBTask(launchPath: executablePath, arguments: prefix + arguments, inDirectory: workingDirectoryPath)
        task.separatesStandardError = true
        task.timeout = 10
        task.additionalEnvironment = ["GIT_TERMINAL_PROMPT": "0", "GIT_LITERAL_PATHSPECS": "1"]
        do {
            try task.launch()
        } catch {
            return nil
        }
        return task.standardOutputData
    }
}

/// The Objective-C entry point for readers that show image bytes from Git or the worktree.
@objc(PBLFSContentResolver)
final nonisolated class LFSContentResolver: NSObject {
    /// The bytes to show for an image read at a repository-relative path: the bytes themselves, their stored Git
    /// LFS object, or nil when the object is not downloaded, because pointer text is not an image.
    @objc(displayDataForData:path:gitLaunchPath:gitDirectory:workingDirectory:)
    static func displayData(
        _ data: Data,
        path: String,
        gitLaunchPath: String,
        gitDirectory: String?,
        workingDirectory: String?
    ) -> Data? {
        LFSPointerInspector(
            executablePath: gitLaunchPath,
            gitDirectoryPath: gitDirectory,
            workingDirectoryPath: workingDirectory
        ).displayData(for: data, path: path)
    }
}
