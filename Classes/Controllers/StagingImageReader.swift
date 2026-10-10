import CryptoKit
import Darwin
import Foundation

/// Previewing and authorizing images share the same filesystem rules. Opening
/// is nonblocking and never follows an unchecked final symlink.
// swift6-safety-justification: The cache is protected by cacheLock; each descriptor and link snapshot belongs to one synchronous read.
final nonisolated class StagingImageReader: @unchecked Sendable {
    static let shared = StagingImageReader()
    static let maximumBytes = 64 * 1024 * 1024
    private let cacheLock = NSLock()
    private var hashes: [String: String] = [:]

    struct Snapshot {
        let data: Data
        let identity: String
    }

    func read(_ url: URL, includeData: Bool = true, maximumBytes: Int = StagingImageReader.maximumBytes,
              timeout: TimeInterval = 2, clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
              shouldCancel: () -> Bool = { false }, whileReading: () -> Void = {}) throws -> Snapshot
    {
        let deadline = clock() + timeout
        func check() throws {
            guard !shouldCancel(), clock() < deadline else { throw Self.failure("Image loading was cancelled or exceeded its time limit.") }
        }
        let original = url.path
        let resolved = try Self.resolve(original, check: check)
        let (path, links, metadata) = (resolved.path, resolved.links, resolved.metadata)
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else { throw Self.failure("Image preview requires a regular file of at most 64 MiB.") }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Self.key(opened) == Self.key(metadata),
              opened.st_mode & S_IFMT == S_IFREG else { throw Self.failure("Image content changed before it could be opened.") }
        let key = Self.key(opened)
        cacheLock.lock(); let cached = hashes[key]; cacheLock.unlock()
        var bytes = Data()
        var digest = SHA256()
        if includeData || cached == nil {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var total = 0
            while true {
                try check()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count >= 0 else { throw POSIXError(.EIO) }
                if count == 0 {
                    break
                }
                guard count <= maximumBytes - total else { throw Self.failure("Image data exceeds the preview limit.") }
                total += count
                let chunk = Data(buffer.prefix(count))
                digest.update(data: chunk)
                if includeData {
                    bytes.append(chunk)
                }
            }
        }
        whileReading()
        try check()
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0, lstat(path, &current) == 0,
              Self.key(after) == key, Self.key(current) == key else { throw Self.failure("Image content changed while it was being read.") }
        for (link, identity, target) in links {
            var info = stat()
            guard lstat(link, &info) == 0, Self.key(info) == identity,
                  try Self.linkTarget(link) == target else { throw Self.failure("Image link changed while it was being read.") }
        }
        let verified = try Self.resolve(original, check: check)
        guard verified.path == path, Self.key(verified.metadata) == key, verified.links.count == links.count,
              zip(verified.links, links).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 })
        else {
            throw Self.failure("Image path changed while it was being read.")
        }
        let contentHash = cached ?? digest.finalize().map { String(format: "%02x", $0) }.joined()
        cacheLock.lock()
        if hashes.count >= 64 {
            hashes.removeAll()
        }
        hashes[key] = contentHash
        cacheLock.unlock()
        var identity = SHA256()
        for (_, _, target) in links {
            identity.update(data: target); identity.update(data: Data([0]))
        }
        identity.update(data: Data((contentHash + ":" + String(opened.st_mode)).utf8))
        return Snapshot(data: bytes, identity: identity.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private struct Resolved {
        let path: String
        let links: [(String, String, Data)]
        let metadata: stat
    }

    private static func resolve(_ original: String, check: () throws -> Void) throws -> Resolved {
        var pending = original.components(separatedBy: "/").filter { !$0.isEmpty }
        var path = "/"
        var links: [(String, String, Data)] = []
        var metadata = stat()
        while !pending.isEmpty {
            try check()
            let name = pending.removeFirst()
            if name == "." {
                continue
            }
            if name == ".." {
                path = (path as NSString).deletingLastPathComponent
                continue
            }
            let candidate = path == "/" ? path + name : path + "/" + name
            guard lstat(candidate, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                guard links.count < 40 else { throw failure("Image links contain a loop or too many indirections.") }
                let target = try linkTarget(candidate)
                links.append((candidate, key(metadata), target))
                guard let destination = String(data: target, encoding: .utf8) else { throw failure("The image link target cannot be represented.") }
                if destination.hasPrefix("/") {
                    path = "/"
                }
                pending = destination.components(separatedBy: "/").filter { !$0.isEmpty } + pending
            } else {
                guard pending.isEmpty || metadata.st_mode & S_IFMT == S_IFDIR else { throw failure("The image path contains a non-directory component.") }
                path = candidate
            }
        }
        guard lstat(path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
        return Resolved(path: path, links: links, metadata: metadata)
    }

    private static func linkTarget(_ path: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { readlink(path, $0.baseAddress, $0.count) }
        guard count >= 0, count < buffer.count else { throw failure("The image link target is unavailable or too long.") }
        return Data(buffer.prefix(count))
    }

    private static func key(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    static func failure(_ detail: String) -> NSError {
        NSError(domain: "PBGitIndexMutationError", code: 8, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

/// PBTask streams index blobs into a bounded buffer rather than retaining an
/// unrestricted standardOutputData. Only this reader owns and terminates it.
// swift6-safety-justification: The synchronous owner alone configures and launches the task; its output callback accesses bytes and overflow under lock and may only request task termination.
final nonisolated class StagingImageBlobReader: @unchecked Sendable {
    private let task: PBTask
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    init(task: PBTask) {
        self.task = task
    }

    func read(maximumBytes: Int = StagingImageReader.maximumBytes) throws -> Data {
        task.capturesStandardOutput = false
        task.timeout = 2
        try task.launch { [self] chunk in
            lock.lock()
            let exceeded = chunk.count > maximumBytes - bytes.count
            if exceeded {
                overflow = true
            } else if !overflow {
                bytes.append(chunk)
            }
            lock.unlock()
            if exceeded {
                task.terminate()
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw StagingImageReader.failure("Indexed image exceeds the preview limit.") }
        return bytes
    }
}

#if GITX_APP_TARGET && DEBUG
    // SwiftLint cannot follow XCTest's Objective-C bridge declarations.
    // swiftlint:disable unused_declaration
    @objc(PBStagingImageReaderTestHarness)
    final nonisolated class StagingImageReaderTestHarness: NSObject {
        @objc(readURL:maximumBytes:cancelled:timeout:whileReading:error:)
        static func read(url: URL, maximumBytes: Int, cancelled: Bool, timeout: Double, whileReading: () -> Void) throws -> Data {
            try StagingImageReader.shared.read(url, maximumBytes: maximumBytes, timeout: timeout,
                                               shouldCancel: { cancelled }, whileReading: whileReading).data
        }

        @objc(identityForURL:error:)
        static func identity(url: URL) throws -> String {
            try StagingImageReader.shared.read(url, includeData: false).identity
        }

        @objc(readBlobTask:maximumBytes:error:)
        static func readBlob(task: PBTask, maximumBytes: Int) throws -> Data {
            try StagingImageBlobReader(task: task).read(maximumBytes: maximumBytes)
        }
    }
    // swiftlint:enable unused_declaration
#endif
