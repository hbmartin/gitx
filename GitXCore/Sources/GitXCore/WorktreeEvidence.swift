import Foundation

public enum WorktreeEvidenceError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case unsupportedObject(String)
    case changed(String)
    case invalidRepair(String)
    case invalidPostcondition(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(path): "Worktree metadata could not be read safely: \(path)"
        case let .unsupportedObject(path): "Worktree metadata is not a regular file or directory: \(path)"
        case let .changed(path): "Worktree ownership changed while the operation was waiting: \(path)"
        case let .invalidRepair(path): "The folder does not prove this worktree's administrative identity: \(path)"
        case let .invalidPostcondition(path): "Git did not establish the expected worktree links: \(path)"
        }
    }
}

public struct WorktreeFileIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case regularFile, directory
    }

    public let pathIdentity: Data
    public let device: UInt64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public let kind: Kind

    public static func capture(path: String) throws -> Self {
        try capture(path: path, fileSystem: .live)
    }

    static func capture(path: String, fileSystem: WorktreeEvidenceFileSystem) throws -> Self {
        let canonical = WorktreePaths.canonical(path)
        guard let node = try fileSystem.metadata(canonical) else { throw WorktreeEvidenceError.unavailable(path) }
        return try node.identity(path: canonical)
    }
}

public struct WorktreeAdministrativeFingerprint: Equatable, Sendable {
    struct Registration: Equatable, Sendable {
        let name: Data
        let directory: WorktreeFileIdentity
        let metadata: [Data?]
        let originalPathIdentity: Data?
        let backlinkIdentity: Data?
        let commonIdentity: Data?

        init(name: Data, directory: WorktreeFileIdentity, metadata: [Data?]) {
            self.name = name
            self.directory = directory
            self.metadata = metadata
            let folder = String(decoding: directory.pathIdentity, as: UTF8.self)
            let backlink = metadata[0].flatMap(WorktreeLinkInspector.firstLine).flatMap { $0.isEmpty ? nil : WorktreeLinkInspector.resolve($0, relativeTo: folder) }
            backlinkIdentity = backlink.map(WorktreePaths.identity)
            originalPathIdentity = backlink.flatMap {
                Data(($0 as NSString).lastPathComponent.utf8) == Data(".git".utf8) ? WorktreePaths.identity(($0 as NSString).deletingLastPathComponent) : nil
            }
            commonIdentity = metadata[1].flatMap(WorktreeLinkInspector.firstLine).flatMap { $0.isEmpty ? nil : WorktreePaths.identity(WorktreeLinkInspector.resolve($0, relativeTo: folder)) }
        }
    }

    let common: WorktreeFileIdentity
    let root: WorktreeFileIdentity?
    let registrations: [Registration]

    public var registrationCount: Int {
        registrations.count
    }

    public func hasSameRegistrations(as other: Self) -> Bool {
        common == other.common && root == other.root
            && registrations.map { ($0.name, $0.directory) }.elementsEqual(other.registrations.map { ($0.name, $0.directory) }, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    public func matchesRegistrationPaths(records: [GitWorktree]) -> Bool {
        let linked = records.filter { !$0.isMain && !$0.isBare }
        let paths = Set(linked.map { WorktreePaths.identity($0.path) })
        let backlinks = registrations.compactMap(\.originalPathIdentity)
        return paths.count == linked.count && linked.count == registrations.count
            && backlinks.count == registrations.count && Set(backlinks).count == registrations.count
            && Set(backlinks) == paths && registrations.allSatisfy { $0.commonIdentity == common.pathIdentity }
    }
}

public struct WorktreeRepairTarget: Equatable, Sendable {
    enum LinkTarget: Equatable, Sendable {
        case administrative
        case missing(Data)
    }

    let common: WorktreeFileIdentity
    let administrative: WorktreeFileIdentity
    let selectedDirectory: WorktreeFileIdentity
    let originalIdentity: Data
    let originalGitfileIdentity: Data
    let originalBacklink: Data
    let originalCommonLink: Data
    let selectedGitfile: Data?
    let selectedLinkTarget: LinkTarget?

    public var originalPath: String {
        String(decoding: originalIdentity, as: UTF8.self)
    }

    public var path: String {
        String(decoding: selectedDirectory.pathIdentity, as: UTF8.self)
    }

    public var administrativePath: String {
        String(decoding: administrative.pathIdentity, as: UTF8.self)
    }
}

struct WorktreeEvidenceNode: Equatable {
    let mode: mode_t
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        mode = value.st_mode
        device = UInt64(UInt32(bitPattern: value.st_dev))
        inode = UInt64(value.st_ino)
        birthSeconds = Int64(value.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }

    func identity(path: String) throws -> WorktreeFileIdentity {
        let kind: WorktreeFileIdentity.Kind
        switch mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        default: throw WorktreeEvidenceError.unsupportedObject(path)
        }
        return WorktreeFileIdentity(pathIdentity: Data(path.utf8), device: device, inode: inode,
                                    birthSeconds: birthSeconds, birthNanoseconds: birthNanoseconds, kind: kind)
    }
}

/// Per-call seams keep failures deterministic without shared test overrides.
struct WorktreeEvidenceFileSystem {
    let metadata: (String) throws -> WorktreeEvidenceNode?
    let read: (String) throws -> Data
    let names: (String) throws -> [String]

    static var live: Self {
        Self(metadata: metadataAtPath, read: { try readRegularFile($0) }, names: { try FileManager.default.contentsOfDirectory(atPath: $0) })
    }

    static func metadataAtPath(_ path: String) throws -> WorktreeEvidenceNode? {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw WorktreeEvidenceError.unavailable(path)
        }
        return WorktreeEvidenceNode(value)
    }

    func directory(_ path: String) throws -> WorktreeFileIdentity {
        guard let node = try metadata(path), node.mode & S_IFMT == S_IFDIR else { throw WorktreeEvidenceError.unsupportedObject(path) }
        return try node.identity(path: WorktreePaths.canonical(path))
    }

    func regularContents(_ path: String) throws -> Data? {
        guard let before = try metadata(path) else { return nil }
        guard before.mode & S_IFMT == S_IFREG else { throw WorktreeEvidenceError.unsupportedObject(path) }
        let data = try read(path)
        guard try metadata(path) == before else { throw WorktreeEvidenceError.changed(path) }
        return data
    }
}

struct WorktreeReadOperations {
    let open: (String) -> Int32
    let info: (Int32) -> WorktreeEvidenceNode?
    let read: (Int32, UnsafeMutableRawPointer, Int) -> Int
    let close: (Int32) -> Void

    static var live: Self {
        Self(open: { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }, info: { descriptor in
            var value = stat()
            return fstat(descriptor, &value) == 0 ? WorktreeEvidenceNode(value) : nil
        }, read: { Darwin.read($0, $1, $2) }, close: { _ = Darwin.close($0) })
    }
}

extension WorktreeEvidenceFileSystem {
    static func readRegularFile(_ path: String, operations: WorktreeReadOperations = .live) throws -> Data {
        let descriptor = operations.open(path)
        guard descriptor >= 0 else { throw WorktreeEvidenceError.unavailable(path) }
        defer { operations.close(descriptor) }
        guard let before = operations.info(descriptor), before.mode & S_IFMT == S_IFREG else { throw WorktreeEvidenceError.unsupportedObject(path) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { operations.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw WorktreeEvidenceError.unavailable(path)
            }
            if count == 0 {
                break
            }
            guard count <= buffer.count else { throw WorktreeEvidenceError.changed(path) }
            output.append(contentsOf: buffer.prefix(count))
        }
        guard operations.info(descriptor) == before else { throw WorktreeEvidenceError.changed(path) }
        return output
    }
}

extension WorktreeLinkInspector {
    public static func administrativeFingerprint(commonDirectory: String) throws -> WorktreeAdministrativeFingerprint {
        try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: .live)
    }

    static func administrativeFingerprint(commonDirectory: String, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeAdministrativeFingerprint {
        let commonPath = WorktreePaths.canonical(commonDirectory)
        let common = try fileSystem.directory(commonPath)
        let rootPath = (commonPath as NSString).appendingPathComponent("worktrees")
        guard try fileSystem.metadata(rootPath) != nil else {
            guard try fileSystem.directory(commonPath) == common, try fileSystem.metadata(rootPath) == nil else { throw WorktreeEvidenceError.changed(rootPath) }
            return WorktreeAdministrativeFingerprint(common: common, root: nil, registrations: [])
        }
        let root = try fileSystem.directory(rootPath)
        let names = try fileSystem.names(rootPath).sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
        var registrations: [WorktreeAdministrativeFingerprint.Registration] = []
        var seen = Set<Data>()
        for name in names {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", seen.insert(Data(name.utf8)).inserted else { throw WorktreeEvidenceError.unsupportedObject(rootPath) }
            let directoryPath = (rootPath as NSString).appendingPathComponent(name)
            let directory = try fileSystem.directory(directoryPath)
            let metadata = try ["gitdir", "commondir", "HEAD", "locked"].map { try fileSystem.regularContents((directoryPath as NSString).appendingPathComponent($0)) }
            guard try fileSystem.directory(directoryPath) == directory else { throw WorktreeEvidenceError.changed(directoryPath) }
            registrations.append(.init(name: Data(name.utf8), directory: directory, metadata: metadata))
        }
        guard try fileSystem.directory(commonPath) == common, try fileSystem.directory(rootPath) == root,
              try fileSystem.names(rootPath).sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }).map({ Data($0.utf8) }) == names.map({ Data($0.utf8) })
        else { throw WorktreeEvidenceError.changed(rootPath) }
        return WorktreeAdministrativeFingerprint(common: common, root: root, registrations: registrations)
    }
}

extension WorktreeLinkInspector {
    public static func captureRepairTarget(_ record: GitWorktree, at path: String, commonDirectory: String, mainPath: String? = nil) throws -> WorktreeRepairTarget {
        try captureRepairTarget(record, at: path, commonDirectory: commonDirectory, mainPath: mainPath, fileSystem: .live)
    }

    static func captureRepairTarget(_ record: GitWorktree, at path: String, commonDirectory: String, mainPath: String? = nil,
                                    fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeRepairTarget
    {
        guard !record.isMain, !record.hasForeignLink else { throw WorktreeEvidenceError.invalidRepair(path) }
        let fingerprint = try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: fileSystem)
        let originalIdentity = WorktreePaths.identity(record.path)
        let matches = fingerprint.registrations.filter { $0.originalPathIdentity == originalIdentity && $0.commonIdentity == fingerprint.common.pathIdentity }
        guard matches.count == 1, let registration = matches.first, let backlink = registration.metadata[0], let commonLink = registration.metadata[1],
              let originalGitfileIdentity = registration.backlinkIdentity
        else { throw WorktreeEvidenceError.invalidRepair(path) }
        let selected = WorktreePaths.canonical(path)
        let directory = try fileSystem.directory(selected)
        let gitfile = try fileSystem.regularContents((selected as NSString).appendingPathComponent(".git"))
        let selectedLink = gitfile.flatMap { link($0, at: selected) }
        var selectedLinkTarget: WorktreeRepairTarget.LinkTarget?
        if let selectedLink {
            let identity = WorktreePaths.identity(selectedLink.target)
            if identity == registration.directory.pathIdentity {
                selectedLinkTarget = .administrative
            } else {
                guard try fileSystem.metadata(selectedLink.target) == nil else { throw WorktreeEvidenceError.invalidRepair(path) }
                selectedLinkTarget = .missing(identity)
                if directory.pathIdentity != originalIdentity {
                    let common = String(decoding: fingerprint.common.pathIdentity, as: UTF8.self)
                    let inferredMain = (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
                    let identifier = String(decoding: registration.name, as: UTF8.self)
                    guard record.movedPath.map(WorktreePaths.identity) == directory.pathIdentity,
                          movedPath(record.path, identifier: identifier, mainPath: mainPath ?? inferredMain, commonDirectory: common).map(WorktreePaths.identity) == directory.pathIdentity
                    else { throw WorktreeEvidenceError.invalidRepair(path) }
                }
            }
        } else if directory.pathIdentity != originalIdentity {
            throw WorktreeEvidenceError.invalidRepair(path)
        }
        let target = WorktreeRepairTarget(common: fingerprint.common, administrative: registration.directory,
                                          selectedDirectory: directory, originalIdentity: originalIdentity,
                                          originalGitfileIdentity: originalGitfileIdentity,
                                          originalBacklink: backlink, originalCommonLink: commonLink, selectedGitfile: gitfile,
                                          selectedLinkTarget: selectedLinkTarget)
        try validateRepairTarget(target, commonDirectory: commonDirectory, fileSystem: fileSystem)
        return target
    }

    public static func validateRepairTarget(_ target: WorktreeRepairTarget, commonDirectory: String) throws {
        try validateRepairTarget(target, commonDirectory: commonDirectory, fileSystem: .live)
    }

    static func validateRepairTarget(_ target: WorktreeRepairTarget, commonDirectory: String, fileSystem: WorktreeEvidenceFileSystem) throws {
        guard try fileSystem.directory(WorktreePaths.canonical(commonDirectory)) == target.common,
              try fileSystem.directory(target.administrativePath) == target.administrative,
              try fileSystem.directory(target.path) == target.selectedDirectory,
              try fileSystem.regularContents((target.administrativePath as NSString).appendingPathComponent("gitdir")) == target.originalBacklink,
              try fileSystem.regularContents((target.administrativePath as NSString).appendingPathComponent("commondir")) == target.originalCommonLink,
              try fileSystem.regularContents((target.path as NSString).appendingPathComponent(".git")) == target.selectedGitfile,
              let backlink = firstLine(target.originalBacklink), let commonLink = firstLine(target.originalCommonLink),
              WorktreePaths.identity(resolve(backlink, relativeTo: target.administrativePath)) == target.originalGitfileIdentity,
              WorktreePaths.identity(resolve(commonLink, relativeTo: target.administrativePath)) == target.common.pathIdentity
        else { throw WorktreeEvidenceError.changed(target.path) }
        let selectedLink = target.selectedGitfile.flatMap { link($0, at: target.path) }
        switch target.selectedLinkTarget {
        case .administrative:
            guard selectedLink.map({ WorktreePaths.identity($0.target) }) == target.administrative.pathIdentity else { throw WorktreeEvidenceError.changed(target.path) }
        case let .missing(identity):
            guard let selectedLink, WorktreePaths.identity(selectedLink.target) == identity,
                  try fileSystem.metadata(selectedLink.target) == nil
            else { throw WorktreeEvidenceError.changed(target.path) }
        case nil:
            break
        }
    }

    public static func verifyRepairTarget(_ target: WorktreeRepairTarget, records: [GitWorktree], commonDirectory: String, style: WorktreeLinkStyle? = nil) throws {
        try verifyRepairTarget(target, records: records, commonDirectory: commonDirectory, style: style, fileSystem: .live)
    }

    static func verifyRepairTarget(_ target: WorktreeRepairTarget, records: [GitWorktree], commonDirectory: String,
                                   style: WorktreeLinkStyle? = nil, fileSystem: WorktreeEvidenceFileSystem) throws
    {
        let matching = records.filter { WorktreePaths.identity($0.path) == target.selectedDirectory.pathIdentity }
        guard matching.count == 1, let record = matching.first, !record.isMain, !record.hasForeignLink, !record.hasBrokenLink,
              target.originalIdentity == target.selectedDirectory.pathIdentity || !records.contains(where: { WorktreePaths.identity($0.path) == target.originalIdentity }),
              try fileSystem.directory(WorktreePaths.canonical(commonDirectory)) == target.common,
              try fileSystem.directory(target.administrativePath) == target.administrative,
              try fileSystem.directory(target.path) == target.selectedDirectory,
              let commonData = try fileSystem.regularContents((target.administrativePath as NSString).appendingPathComponent("commondir")),
              let commonLink = firstLine(commonData), !commonLink.isEmpty,
              WorktreePaths.identity(resolve(commonLink, relativeTo: target.administrativePath)) == target.common.pathIdentity,
              let backlinkData = try fileSystem.regularContents((target.administrativePath as NSString).appendingPathComponent("gitdir")),
              let backlink = firstLine(backlinkData), !backlink.isEmpty,
              WorktreePaths.identity(resolve(backlink, relativeTo: target.administrativePath)) == WorktreePaths.identity((target.path as NSString).appendingPathComponent(".git")),
              let gitfile = try fileSystem.regularContents((target.path as NSString).appendingPathComponent(".git")),
              let selectedLink = link(gitfile, at: target.path), WorktreePaths.identity(selectedLink.target) == target.administrative.pathIdentity
        else { throw WorktreeEvidenceError.invalidPostcondition(target.path) }
        if let style {
            let backlinkStyle: WorktreeLinkStyle = (backlink as NSString).isAbsolutePath ? .absolute : .relative
            guard selectedLink.style == style, backlinkStyle == style else { throw WorktreeEvidenceError.invalidPostcondition(target.path) }
        }
    }
}
