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

/// Executable replacement and in-place upgrades both invalidate capability evidence.
/// Directory ownership continues to use WorktreeFileIdentity without timestamps.
public struct WorktreeFileFingerprint: Equatable, Sendable {
    public let identity: WorktreeFileIdentity
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    private let mode: mode_t

    public var path: String {
        String(decoding: identity.pathIdentity, as: UTF8.self)
    }

    public static func capture(path: String) throws -> Self {
        try capture(path: path, fileSystem: .live)
    }

    static func capture(path: String, fileSystem: WorktreeEvidenceFileSystem) throws -> Self {
        let canonical = WorktreePaths.canonical(path)
        guard let node = try fileSystem.metadata(canonical) else { throw WorktreeEvidenceError.unavailable(path) }
        return try Self(path: canonical, node: node)
    }

    init(path: String, node: WorktreeEvidenceNode) throws {
        guard node.mode & S_IFMT == S_IFREG else { throw WorktreeEvidenceError.unsupportedObject(path) }
        identity = try node.identity(path: path)
        size = node.size
        modifiedSeconds = node.modifiedSeconds
        modifiedNanoseconds = node.modifiedNanoseconds
        changedSeconds = node.changedSeconds
        changedNanoseconds = node.changedNanoseconds
        mode = node.mode
    }
}

/// A bounded request-time check before background inventory capture begins.
/// Root timestamps never participate in later repair or prune consent.
public struct WorktreeAdministrativeAnchor: Equatable, Sendable {
    public let commonIdentity: WorktreeFileIdentity
    public let rootIdentity: WorktreeFileIdentity?
    private let rootMetadata: WorktreeEvidenceNode?

    public static func capture(commonDirectory: String) throws -> Self {
        try capture(commonDirectory: commonDirectory, fileSystem: .live)
    }

    static func capture(commonDirectory: String, fileSystem: WorktreeEvidenceFileSystem) throws -> Self {
        let common = WorktreePaths.canonical(commonDirectory)
        let identity = try fileSystem.directory(common)
        let rootPath = (common as NSString).appendingPathComponent("worktrees")
        let metadata = try fileSystem.metadata(rootPath)
        let root = try metadata.map { try $0.identity(path: rootPath) }
        guard root == nil || root?.kind == .directory else { throw WorktreeEvidenceError.unsupportedObject(rootPath) }
        return Self(commonIdentity: identity, rootIdentity: root, rootMetadata: metadata)
    }

    public func validate(commonDirectory: String) throws {
        try validate(commonDirectory: commonDirectory, fileSystem: .live)
    }

    func validate(commonDirectory: String, fileSystem: WorktreeEvidenceFileSystem) throws {
        guard try self == Self.capture(commonDirectory: commonDirectory, fileSystem: fileSystem) else { throw WorktreeEvidenceError.changed(commonDirectory) }
    }
}

public struct WorktreeAdministrativeFingerprint: Equatable, Sendable {
    struct Registration: Equatable, Sendable {
        let name: Data
        let directory: WorktreeFileIdentity
        let gitdir: Data?
        let commondir: Data?
        let head: Data?
        let locked: Data?
        let originalPathIdentity: Data?
        let backlinkIdentity: Data?
        let commonIdentity: Data?

        init(name: Data, directory: WorktreeFileIdentity, gitdir: Data?, commondir: Data?, head: Data?, locked: Data?) {
            self.name = name
            self.directory = directory
            self.gitdir = gitdir
            self.commondir = commondir
            self.head = head
            self.locked = locked
            let folder = String(decoding: directory.pathIdentity, as: UTF8.self)
            let backlink = gitdir.flatMap(WorktreeLinkInspector.firstLine).flatMap { $0.isEmpty ? nil : WorktreeLinkInspector.resolve($0, relativeTo: folder) }
            backlinkIdentity = backlink.map(WorktreePaths.identity)
            originalPathIdentity = backlink.flatMap {
                Data(($0 as NSString).lastPathComponent.utf8) == Data(".git".utf8) ? WorktreePaths.identity(($0 as NSString).deletingLastPathComponent) : nil
            }
            commonIdentity = commondir.flatMap(WorktreeLinkInspector.firstLine).flatMap { $0.isEmpty ? nil : WorktreePaths.identity(WorktreeLinkInspector.resolve($0, relativeTo: folder)) }
        }

        func hasSameConsentEvidence(as other: Self) -> Bool {
            name == other.name && directory == other.directory && gitdir == other.gitdir && commondir == other.commondir && locked == other.locked
                && originalPathIdentity == other.originalPathIdentity && backlinkIdentity == other.backlinkIdentity && commonIdentity == other.commonIdentity
        }
    }

    struct Stray: Equatable, Sendable {
        let name: Data
        let fingerprint: WorktreeFileFingerprint
        let contents: Data
    }

    let common: WorktreeFileIdentity
    let root: WorktreeFileIdentity?
    let registrations: [Registration]
    let strays: [Stray]
    let registrationsByName: [Data: Registration]
    let registrationsByPath: [Data: [Registration]]

    init(common: WorktreeFileIdentity, root: WorktreeFileIdentity?, registrations: [Registration], strays: [Stray] = []) {
        self.common = common
        self.root = root
        self.registrations = registrations
        self.strays = strays
        registrationsByName = Dictionary(uniqueKeysWithValues: registrations.map { ($0.name, $0) })
        registrationsByPath = Dictionary(grouping: registrations.filter { $0.originalPathIdentity != nil }, by: { $0.originalPathIdentity! })
    }

    public var registrationCount: Int {
        registrations.count
    }

    public func hasSameRegistrations(as other: Self) -> Bool {
        common == other.common && root == other.root && strays == other.strays
            && registrations.map { ($0.name, $0.directory) }.elementsEqual(other.registrations.map { ($0.name, $0.directory) }, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    public func hasSameConsentEvidence(as other: Self) -> Bool {
        common == other.common && root == other.root && strays == other.strays
            && registrations.elementsEqual(other.registrations, by: { $0.hasSameConsentEvidence(as: $1) })
    }

    /// New or removed registrations can require new consent. A reused existing
    /// administrative name must never be rebound by renewing an old permit.
    public func canRenew(from previous: Self) -> Bool {
        common == previous.common && root == previous.root && previous.registrations.allSatisfy { registration in
            registrationsByName[registration.name].map { $0.directory == registration.directory } ?? true
        }
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

public enum WorktreeReclaimReason: Equatable, Sendable {
    case missingGitfile, emptyGitfile, malformedGitfile, unresolvedGitdir
}

public enum WorktreeRepairOwnership: Equatable, Sendable {
    case proven
    case requiresReclaim(WorktreeReclaimReason)
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
    public let administrativeName: Data
    public let ownership: WorktreeRepairOwnership

    public var administrativeIdentity: WorktreeFileIdentity {
        administrative
    }

    public var requiresReclaim: Bool {
        if case .requiresReclaim = ownership {
            return true
        }
        return false
    }

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

public struct WorktreeRepairSelection: Equatable, Sendable {
    public let originalIdentity: Data
    public let pathIdentity: Data

    public init(originalPath: String, path: String) {
        originalIdentity = WorktreePaths.identity(originalPath)
        pathIdentity = WorktreePaths.identity(path)
    }

    public var path: String {
        String(decoding: pathIdentity, as: UTF8.self)
    }
}

public struct WorktreeAbsentLocation: Equatable, Sendable {
    public let identity: Data
    private let sourceIdentity: Data

    init(path: String) {
        identity = WorktreePaths.identity(path)
        sourceIdentity = Data(path.utf8)
    }

    public var path: String {
        String(decoding: sourceIdentity, as: UTF8.self)
    }
}

/// Evidence is descriptive. Only the service's single-use preview authorizes reclaim.
public struct WorktreeRepairScope: Equatable, Sendable {
    public let fingerprint: WorktreeAdministrativeFingerprint
    public let targets: [WorktreeRepairTarget]
    public let absentLocations: [WorktreeAbsentLocation]
    public let selection: WorktreeRepairSelection?
    public let mainPath: String?

    public var requiresReclaim: Bool {
        targets.contains(where: \.requiresReclaim)
    }

    public func hasSameConsentEvidence(as other: Self) -> Bool {
        fingerprint.hasSameConsentEvidence(as: other.fingerprint) && targets == other.targets
            && absentLocations == other.absentLocations && selection == other.selection
            && mainPath.map { Data($0.utf8) } == other.mainPath.map { Data($0.utf8) }
    }

    public func canRenew(from previous: Self) -> Bool {
        guard fingerprint.canRenew(from: previous.fingerprint) else { return false }
        guard let selection = previous.selection else { return selection == nil }
        guard selection == self.selection, let old = previous.targets.first(where: { $0.originalIdentity == selection.originalIdentity }),
              let current = targets.first(where: { $0.originalIdentity == selection.originalIdentity }) else { return false }
        return old.administrativeName == current.administrativeName && old.administrative == current.administrative
    }
}

/// Exact checkout links supplement administrative consent without capturing
/// HEAD, indexes, or directory timestamps. Protected moved scopes cannot prune.
public struct WorktreeCheckoutLinkEvidence: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let record: Data
        let location: Data
    }

    struct Node: Equatable, Sendable {
        let path: Data
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let kind: mode_t

        init(path: String, node: WorktreeEvidenceNode) {
            self.path = Data(path.utf8)
            device = node.device
            inode = node.inode
            birthSeconds = node.birthSeconds
            birthNanoseconds = node.birthNanoseconds
            kind = node.mode & S_IFMT
        }
    }

    struct Reference: Equatable, Sendable {
        let path: Data
        let node: Node?
    }

    enum Resolved: Equatable, Sendable {
        case missing
        case regular(Data, Reference?)
        case directory
        case unsupported
    }

    enum Object: Equatable, Sendable {
        case missing(Data)
        case regular(Node, Data, Reference?)
        case directory(Node)
        case symbolicLink(Node, Data, Reference, Resolved)
        case unsupported(Node)
    }

    enum Entry: Equatable, Sendable {
        case readable(Reference, Object)
        case unreadable(Data)
    }

    public let permitsPrune: Bool
    let entries: [Key: Entry]
}

struct WorktreeEvidenceNode: Equatable, Sendable {
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
    let readLink: (String) throws -> Data

    init(metadata: @escaping (String) throws -> WorktreeEvidenceNode?, read: @escaping (String) throws -> Data,
         names: @escaping (String) throws -> [String], readLink: @escaping (String) throws -> Data = { try WorktreeEvidenceFileSystem.readSymbolicLink($0) })
    {
        self.metadata = metadata
        self.read = read
        self.names = names
        self.readLink = readLink
    }

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

struct WorktreeLinkReadOperations {
    let read: (String, UnsafeMutableRawPointer, Int) -> Int

    static var live: Self {
        Self(read: { Darwin.readlink($0, $1.assumingMemoryBound(to: CChar.self), $2) })
    }
}

extension WorktreeEvidenceFileSystem {
    static func readSymbolicLink(_ path: String, operations: WorktreeLinkReadOperations = .live) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        var count: Int
        repeat {
            count = buffer.withUnsafeMutableBytes { operations.read(path, $0.baseAddress!, $0.count) }
        } while count < 0 && errno == EINTR
        guard count >= 0 else {
            throw WorktreeEvidenceError.unavailable(path)
        }
        guard count < buffer.count else { throw WorktreeEvidenceError.changed(path) }
        return Data(buffer.prefix(count))
    }

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
    public static func captureCheckoutLinkEvidence(records: [GitWorktree]) throws -> WorktreeCheckoutLinkEvidence {
        try captureCheckoutLinkEvidence(records: records, fileSystem: .live)
    }

    static func captureCheckoutLinkEvidence(records: [GitWorktree], fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeCheckoutLinkEvidence {
        let protected = records.contains { $0.movedPath != nil }
        var entries: [WorktreeCheckoutLinkEvidence.Key: WorktreeCheckoutLinkEvidence.Entry] = [:]
        for record in records {
            let paths = [record.path] + (record.movedPath.map { [$0] } ?? [])
            for path in paths {
                let key = WorktreeCheckoutLinkEvidence.Key(record: record.identity, location: Data(path.utf8))
                guard entries[key] == nil else { throw WorktreeEvidenceError.invalidRepair(path) }
                do {
                    let folder = try checkoutReference(path, fileSystem: fileSystem)
                    let canonical = String(decoding: folder.path, as: UTF8.self)
                    let object = try checkoutObject((canonical as NSString).appendingPathComponent(".git"), folder: canonical, fileSystem: fileSystem)
                    guard try folder == checkoutReference(path, fileSystem: fileSystem) else { throw WorktreeEvidenceError.changed(path) }
                    entries[key] = .readable(folder, object)
                } catch {
                    guard protected else { throw error }
                    entries[key] = .unreadable(WorktreePaths.identity(path))
                }
            }
        }
        return WorktreeCheckoutLinkEvidence(permitsPrune: !protected, entries: entries)
    }

    private static func checkoutReference(_ path: String, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeCheckoutLinkEvidence.Reference {
        let canonical = WorktreePaths.canonical(path)
        let node = try fileSystem.metadata(canonical).map { WorktreeCheckoutLinkEvidence.Node(path: canonical, node: $0) }
        return WorktreeCheckoutLinkEvidence.Reference(path: Data(canonical.utf8), node: node)
    }

    private static func checkoutGitdirReference(_ data: Data, folder: String, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeCheckoutLinkEvidence.Reference? {
        try link(data, at: folder).map { try checkoutReference($0.target, fileSystem: fileSystem) }
    }

    private static func checkoutObject(_ path: String, folder: String, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeCheckoutLinkEvidence.Object {
        guard let before = try fileSystem.metadata(path) else { return .missing(WorktreePaths.identity(path)) }
        let node = WorktreeCheckoutLinkEvidence.Node(path: path, node: before)
        let object: WorktreeCheckoutLinkEvidence.Object
        switch before.mode & S_IFMT {
        case S_IFREG:
            guard let bytes = try fileSystem.regularContents(path) else { throw WorktreeEvidenceError.changed(path) }
            object = try .regular(node, bytes, checkoutGitdirReference(bytes, folder: folder, fileSystem: fileSystem))
        case S_IFDIR:
            object = .directory(node)
        case S_IFLNK:
            let bytes = try fileSystem.readLink(path)
            guard let destination = String(data: bytes, encoding: .utf8), !destination.isEmpty else { throw WorktreeEvidenceError.unsupportedObject(path) }
            let reference = try checkoutReference(resolve(destination, relativeTo: folder), fileSystem: fileSystem)
            let resolved: WorktreeCheckoutLinkEvidence.Resolved
            switch reference.node?.kind {
            case nil: resolved = .missing
            case S_IFREG:
                let target = String(decoding: reference.path, as: UTF8.self)
                guard let bytes = try fileSystem.regularContents(target) else { throw WorktreeEvidenceError.changed(target) }
                resolved = try .regular(bytes, checkoutGitdirReference(bytes, folder: folder, fileSystem: fileSystem))
            case S_IFDIR: resolved = .directory
            default: resolved = .unsupported
            }
            guard try reference == checkoutReference(resolve(destination, relativeTo: folder), fileSystem: fileSystem) else { throw WorktreeEvidenceError.changed(path) }
            object = .symbolicLink(node, bytes, reference, resolved)
        default:
            object = .unsupported(node)
        }
        guard try fileSystem.metadata(path) == before else { throw WorktreeEvidenceError.changed(path) }
        return object
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
        var strays: [WorktreeAdministrativeFingerprint.Stray] = []
        var seen = Set<Data>()
        for name in names {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", seen.insert(Data(name.utf8)).inserted else { throw WorktreeEvidenceError.unsupportedObject(rootPath) }
            let directoryPath = (rootPath as NSString).appendingPathComponent(name)
            guard let node = try fileSystem.metadata(directoryPath) else { throw WorktreeEvidenceError.changed(directoryPath) }
            if node.mode & S_IFMT == S_IFREG {
                let fingerprint = try WorktreeFileFingerprint(path: directoryPath, node: node)
                guard let contents = try fileSystem.regularContents(directoryPath), try fileSystem.metadata(directoryPath) == node else { throw WorktreeEvidenceError.changed(directoryPath) }
                strays.append(.init(name: Data(name.utf8), fingerprint: fingerprint, contents: contents))
                continue
            }
            guard node.mode & S_IFMT == S_IFDIR else { throw WorktreeEvidenceError.unsupportedObject(directoryPath) }
            let directory = try node.identity(path: directoryPath)
            let gitdir = try fileSystem.regularContents((directoryPath as NSString).appendingPathComponent("gitdir"))
            let commondir = try fileSystem.regularContents((directoryPath as NSString).appendingPathComponent("commondir"))
            let head = try fileSystem.regularContents((directoryPath as NSString).appendingPathComponent("HEAD"))
            let locked = try fileSystem.regularContents((directoryPath as NSString).appendingPathComponent("locked"))
            guard try fileSystem.directory(directoryPath) == directory else { throw WorktreeEvidenceError.changed(directoryPath) }
            registrations.append(.init(name: Data(name.utf8), directory: directory, gitdir: gitdir, commondir: commondir, head: head, locked: locked))
        }
        guard try fileSystem.directory(commonPath) == common, try fileSystem.directory(rootPath) == root,
              try fileSystem.names(rootPath).sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }).map({ Data($0.utf8) }) == names.map({ Data($0.utf8) })
        else { throw WorktreeEvidenceError.changed(rootPath) }
        return WorktreeAdministrativeFingerprint(common: common, root: root, registrations: registrations, strays: strays)
    }
}

extension WorktreeLinkInspector {
    public static func captureRepairTarget(_ record: GitWorktree, at path: String, commonDirectory: String, mainPath: String? = nil) throws -> WorktreeRepairTarget {
        try captureRepairTarget(record, at: path, commonDirectory: commonDirectory, mainPath: mainPath, fileSystem: .live)
    }

    static func captureRepairTarget(_ record: GitWorktree, at path: String, commonDirectory: String, mainPath: String? = nil,
                                    fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeRepairTarget
    {
        let fingerprint = try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: fileSystem)
        return try captureRepairTarget(record, at: path, mainPath: mainPath, fingerprint: fingerprint, fileSystem: fileSystem)
    }

    private static func captureRepairTarget(_ record: GitWorktree, at path: String, mainPath: String?,
                                            fingerprint: WorktreeAdministrativeFingerprint, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeRepairTarget
    {
        guard !record.isMain, !record.isBare, !record.hasForeignLink else { throw WorktreeEvidenceError.invalidRepair(path) }
        let originalIdentity = WorktreePaths.identity(record.path)
        let matches = fingerprint.registrationsByPath[originalIdentity] ?? []
        guard matches.count == 1, let registration = matches.first, registration.commonIdentity == fingerprint.common.pathIdentity,
              let backlink = registration.gitdir, let commonLink = registration.commondir,
              let originalGitfileIdentity = registration.backlinkIdentity
        else { throw WorktreeEvidenceError.invalidRepair(path) }
        let selected = WorktreePaths.canonical(path)
        let directory = try fileSystem.directory(selected)
        let gitfile = try fileSystem.regularContents((selected as NSString).appendingPathComponent(".git"))
        let selectedLink = gitfile.flatMap { link($0, at: selected) }
        var selectedLinkTarget: WorktreeRepairTarget.LinkTarget?
        var ownership: WorktreeRepairOwnership = .proven
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
                } else {
                    ownership = .requiresReclaim(.unresolvedGitdir)
                }
            }
        } else if directory.pathIdentity != originalIdentity {
            throw WorktreeEvidenceError.invalidRepair(path)
        } else if let gitfile {
            ownership = .requiresReclaim(gitfile.isEmpty ? .emptyGitfile : .malformedGitfile)
        } else {
            ownership = .requiresReclaim(.missingGitfile)
        }
        let target = WorktreeRepairTarget(common: fingerprint.common, administrative: registration.directory,
                                          selectedDirectory: directory, originalIdentity: originalIdentity,
                                          originalGitfileIdentity: originalGitfileIdentity,
                                          originalBacklink: backlink, originalCommonLink: commonLink, selectedGitfile: gitfile,
                                          selectedLinkTarget: selectedLinkTarget, administrativeName: registration.name, ownership: ownership)
        try validateRepairTarget(target, commonDirectory: String(decoding: fingerprint.common.pathIdentity, as: UTF8.self), fileSystem: fileSystem)
        return target
    }

    public static func captureRepairScope(records: [GitWorktree], commonDirectory: String, mainPath: String? = nil,
                                          selection: WorktreeRepairSelection? = nil) throws -> WorktreeRepairScope
    {
        try captureRepairScope(records: records, commonDirectory: commonDirectory, mainPath: mainPath, selection: selection, fileSystem: .live)
    }

    static func captureRepairScope(records: [GitWorktree], commonDirectory: String, mainPath: String? = nil,
                                   selection: WorktreeRepairSelection? = nil, fileSystem: WorktreeEvidenceFileSystem) throws -> WorktreeRepairScope
    {
        let fingerprint = try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: fileSystem)
        guard fingerprint.matchesRegistrationPaths(records: records) else { throw WorktreeEvidenceError.invalidRepair(commonDirectory) }
        let linked = records.filter { !$0.isMain && !$0.isBare }
        let identities = Set(linked.map { WorktreePaths.identity($0.path) })
        if let selection, !identities.contains(selection.originalIdentity) {
            throw WorktreeEvidenceError.invalidRepair(selection.path)
        }
        let main = (mainPath ?? records.first(where: \.isMain)?.path).map(WorktreePaths.canonical)
        var targets: [WorktreeRepairTarget] = []
        var absentLocations: [WorktreeAbsentLocation] = []
        var selectedPaths = Set<Data>()
        for record in linked {
            let original = WorktreePaths.identity(record.path)
            let override = selection.flatMap { $0.originalIdentity == original ? $0.path : nil }
            if override == nil, !record.folderExists, record.movedPath == nil {
                guard try fileSystem.metadata(record.path) == nil else { throw WorktreeEvidenceError.changed(record.path) }
                absentLocations.append(WorktreeAbsentLocation(path: record.path))
                continue
            }
            let path = override ?? record.movedPath ?? record.path
            let identity = WorktreePaths.identity(path)
            guard !identities.contains(identity) || identity == original, selectedPaths.insert(identity).inserted else { throw WorktreeEvidenceError.invalidRepair(path) }
            try targets.append(captureRepairTarget(record, at: path, mainPath: main, fingerprint: fingerprint, fileSystem: fileSystem))
        }
        return WorktreeRepairScope(fingerprint: fingerprint, targets: targets, absentLocations: absentLocations, selection: selection, mainPath: main)
    }

    public static func validateRepairScope(_ scope: WorktreeRepairScope, commonDirectory: String) throws {
        try validateRepairScope(scope, commonDirectory: commonDirectory, fileSystem: .live)
    }

    static func validateRepairScope(_ scope: WorktreeRepairScope, commonDirectory: String, fileSystem: WorktreeEvidenceFileSystem) throws {
        let current = try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: fileSystem)
        guard scope.fingerprint.hasSameConsentEvidence(as: current) else { throw WorktreeEvidenceError.changed(commonDirectory) }
        try validateAbsentLocations(scope.absentLocations, fileSystem: fileSystem)
        for target in scope.targets {
            try validateRepairTarget(target, commonDirectory: commonDirectory, fileSystem: fileSystem)
        }
    }

    private static func validateAbsentLocations(_ locations: [WorktreeAbsentLocation], fileSystem: WorktreeEvidenceFileSystem) throws {
        for location in locations {
            guard WorktreePaths.identity(location.path) == location.identity, try fileSystem.metadata(location.path) == nil else { throw WorktreeEvidenceError.changed(location.path) }
        }
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
        let indexed = Dictionary(grouping: records, by: { WorktreePaths.identity($0.path) })
        try verifyRepairTarget(target, indexedRecords: indexed, commonDirectory: commonDirectory, style: style, fileSystem: fileSystem)
    }

    private static func verifyRepairTarget(_ target: WorktreeRepairTarget, indexedRecords: [Data: [GitWorktree]], commonDirectory: String,
                                           style: WorktreeLinkStyle?, fileSystem: WorktreeEvidenceFileSystem) throws
    {
        let matching = indexedRecords[target.selectedDirectory.pathIdentity] ?? []
        guard matching.count == 1, let record = matching.first, !record.isMain, !record.isBare, !record.hasForeignLink, !record.hasBrokenLink,
              target.originalIdentity == target.selectedDirectory.pathIdentity || indexedRecords[target.originalIdentity] == nil,
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

    public static func verifyRepairScope(_ scope: WorktreeRepairScope, records: [GitWorktree], commonDirectory: String, style: WorktreeLinkStyle? = nil) throws {
        try verifyRepairScope(scope, records: records, commonDirectory: commonDirectory, style: style, fileSystem: .live)
    }

    static func verifyRepairScope(_ scope: WorktreeRepairScope, records: [GitWorktree], commonDirectory: String,
                                  style: WorktreeLinkStyle? = nil, fileSystem: WorktreeEvidenceFileSystem) throws
    {
        let fingerprint = try administrativeFingerprint(commonDirectory: commonDirectory, fileSystem: fileSystem)
        guard scope.fingerprint.hasSameRegistrations(as: fingerprint), fingerprint.matchesRegistrationPaths(records: records) else {
            throw WorktreeEvidenceError.invalidPostcondition(commonDirectory)
        }
        try validateAbsentLocations(scope.absentLocations, fileSystem: fileSystem)
        let indexed = Dictionary(grouping: records, by: { WorktreePaths.identity($0.path) })
        for target in scope.targets {
            try verifyRepairTarget(target, indexedRecords: indexed, commonDirectory: commonDirectory, style: style, fileSystem: fileSystem)
        }
    }
}
