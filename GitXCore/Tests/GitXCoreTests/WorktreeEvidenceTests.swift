import Darwin
@testable import GitXCore
import XCTest

final class WorktreeEvidenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let common: URL
        let administrative: URL
        let original: URL
        var gitfile: URL {
            original.appendingPathComponent(".git")
        }

        var backlink: URL {
            administrative.appendingPathComponent("gitdir")
        }

        var record: GitWorktree {
            GitWorktree(path: original.path)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-evidence-\(UUID().uuidString)")
        let value = Fixture(root: root, common: root.appendingPathComponent("main/.git"), administrative: root.appendingPathComponent("main/.git/worktrees/topic"), original: root.appendingPathComponent("original"))
        for directory in [value.administrative, value.original] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data((value.gitfile.path + "\n").utf8).write(to: value.backlink)
        try Data("../..\n".utf8).write(to: value.administrative.appendingPathComponent("commondir"))
        try Data("ref: refs/heads/topic\n".utf8).write(to: value.administrative.appendingPathComponent("HEAD"))
        try Data(("gitdir: " + value.administrative.path + "\n").utf8).write(to: value.gitfile)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return value
    }

    private func node(_ mode: mode_t = S_IFREG, inode: UInt64 = 1) -> WorktreeEvidenceNode {
        var value = stat()
        value.st_mode = mode
        value.st_ino = inode
        return WorktreeEvidenceNode(value)
    }

    private func replacingMetadata(_ base: WorktreeEvidenceFileSystem = .live, _ change: @escaping (String, WorktreeEvidenceNode?) throws -> WorktreeEvidenceNode?) -> WorktreeEvidenceFileSystem {
        WorktreeEvidenceFileSystem(metadata: { try change($0, base.metadata($0)) }, read: base.read, names: base.names)
    }

    func testMultipleRegistrationsPreserveUniqueAttributionAndIndependentTargets() throws {
        let value = try fixture()
        let second = value.root.appendingPathComponent("second")
        let unavailable = value.root.appendingPathComponent("unavailable")
        let secondAdmin = value.common.appendingPathComponent("worktrees/second")
        let unavailableAdmin = value.common.appendingPathComponent("worktrees/unavailable")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        for (checkout, administrative) in [(second, secondAdmin), (unavailable, unavailableAdmin)] {
            try FileManager.default.createDirectory(at: administrative, withIntermediateDirectories: false)
            try Data((checkout.appendingPathComponent(".git").path + "\n").utf8).write(to: administrative.appendingPathComponent("gitdir"))
            try Data("../..\n".utf8).write(to: administrative.appendingPathComponent("commondir"))
            try Data("ref: refs/heads/other\n".utf8).write(to: administrative.appendingPathComponent("HEAD"))
        }
        let secondGitfile = second.appendingPathComponent(".git")
        try Data(("gitdir: " + secondAdmin.path + "\n").utf8).write(to: secondGitfile)
        let secondRecord = GitWorktree(path: second.path, head: "abc", branchRefName: "refs/heads/other")
        let unavailableRecord = GitWorktree(path: unavailable.path, isPrunable: true, folderExists: false)
        let records = [GitWorktree(path: value.common.deletingLastPathComponent().path, isMain: true), value.record, secondRecord, unavailableRecord]
        let administrativeFiles = [value.administrative, secondAdmin, unavailableAdmin].flatMap { directory in
            ["gitdir", "commondir", "HEAD"].map { directory.appendingPathComponent($0) }
        }
        let originalMetadata = try administrativeFiles.map { try Data(contentsOf: $0) }
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertEqual(fingerprint.registrationCount, 3)
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: records))
        XCTAssertFalse(fingerprint.matchesRegistrationPaths(records: records + [secondRecord]))
        let firstTarget = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let secondTarget = try WorktreeLinkInspector.captureRepairTarget(secondRecord, at: second.path, commonDirectory: value.common.path)
        XCTAssertNotEqual(firstTarget.administrativePath, secondTarget.administrativePath)
        for target in [firstTarget, secondTarget] {
            try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
            try WorktreeLinkInspector.verifyRepairTarget(target, records: records, commonDirectory: value.common.path, style: .absolute)
        }
        XCTAssertEqual(try administrativeFiles.map { try Data(contentsOf: $0) }, originalMetadata)
        try Data("not a gitfile\n".utf8).write(to: secondGitfile)
        try WorktreeLinkInspector.validateRepairTarget(firstTarget, commonDirectory: value.common.path)
        try WorktreeLinkInspector.verifyRepairTarget(firstTarget, records: records, commonDirectory: value.common.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(secondTarget, commonDirectory: value.common.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    }

    func testFileIdentitySeparatesOwnershipFromOrdinaryContentsChanges() throws {
        let value = try fixture()
        let directory = try WorktreeFileIdentity.capture(path: value.original.path)
        let file = value.original.appendingPathComponent("executable-fixture")
        try Data("initial".utf8).write(to: file)
        let initialFile = try WorktreeFileIdentity.capture(path: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("same inode, changed contents".utf8))
        try handle.close()
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: file.path), initialFile)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: value.original.path), directory)
        try Data("index".utf8).write(to: value.administrative.appendingPathComponent("index"))
        try FileManager.default.createDirectory(at: value.administrative.appendingPathComponent("logs"), withIntermediateDirectories: false)
        try Data("log".utf8).write(to: value.administrative.appendingPathComponent("logs/HEAD"))
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: value.original.path), directory)
        let held = value.root.appendingPathComponent("held-executable")
        try FileManager.default.moveItem(at: file, to: held)
        try Data("replacement".utf8).write(to: file)
        XCTAssertNotEqual(try WorktreeFileIdentity.capture(path: file.path), initialFile)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: value.original.path), directory)
        XCTAssertEqual(try Data(contentsOf: held), Data("same inode, changed contents".utf8))
    }

    func testFileIdentitiesResolveAliasesAndRejectMissingUnsupportedObjects() throws {
        let value = try fixture()
        let file = try WorktreeFileIdentity.capture(path: value.gitfile.path)
        XCTAssertEqual(file.kind, .regularFile)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: value.original.path).kind, .directory)
        let alias = value.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.gitfile)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: alias.path), file)
        XCTAssertEqual(file.pathIdentity, WorktreePaths.identity(value.gitfile.path))
        XCTAssertThrowsError(try WorktreeFileIdentity.capture(path: value.root.appendingPathComponent("absent").path))
        let unsupported = replacingMetadata { _, _ in self.node(S_IFLNK) }
        XCTAssertThrowsError(try WorktreeFileIdentity.capture(path: value.gitfile.path, fileSystem: unsupported))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.metadataAtPath(value.gitfile.appendingPathComponent("child").path))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.live.directory(value.gitfile.path))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.live.directory(value.root.appendingPathComponent("absent").path))
        XCTAssertNil(try WorktreeEvidenceFileSystem.live.regularContents(value.root.appendingPathComponent("absent").path))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.live.regularContents(value.original.path))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.live.regularContents(alias.path))
        var calls = 0
        let changed = replacingMetadata { _, _ in
            calls += 1
            return self.node(inode: UInt64(calls))
        }
        XCTAssertThrowsError(try changed.regularContents(value.gitfile.path))
        for error in [WorktreeEvidenceError.unavailable("a"), .unsupportedObject("b"), .changed("c"), .invalidRepair("d"), .invalidPostcondition("e")] {
            XCTAssertFalse(try XCTUnwrap(error.errorDescription).isEmpty)
        }
    }

    func testDescriptorReadHandlesAllFailuresAndInterruptions() throws {
        var closes = 0
        func operations(open: Int32 = 3, info: WorktreeEvidenceNode? = nil, read: @escaping (Int32, UnsafeMutableRawPointer, Int) -> Int = { _, _, _ in 0 }) -> WorktreeReadOperations {
            WorktreeReadOperations(open: { _ in open }, info: { _ in info }, read: read, close: { _ in closes += 1 })
        }
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: operations(open: -1)))
        XCTAssertEqual(closes, 0)
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: operations()))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: operations(info: node(S_IFDIR))))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: operations(info: node(), read: { _, _, _ in errno = EIO; return -1 })))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: operations(info: node(), read: { _, _, count in count + 1 })))
        var reads = 0
        let interrupted = operations(info: node(), read: { _, buffer, _ in
            reads += 1
            if reads == 1 {
                errno = EINTR; return -1
            }
            if reads == 2 {
                buffer.storeBytes(of: UInt8(42), as: UInt8.self); return 1
            }
            return 0
        })
        XCTAssertEqual(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: interrupted), Data([42]))
        var infos = 0
        let changed = WorktreeReadOperations(open: { _ in 3 }, info: { _ in
            infos += 1
            return self.node(inode: UInt64(infos))
        }, read: { _, _, _ in 0 }, close: { _ in closes += 1 })
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readRegularFile("/test", operations: changed))
        XCTAssertEqual(closes, 6)
    }

    func testInspectionOnlyOffersReconstructionForReadableRegularDamage() throws {
        let value = try fixture()
        let records = [GitWorktree(path: value.common.deletingLastPathComponent().path, isMain: true), value.record]
        let base = WorktreeEvidenceFileSystem.live
        let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            if WorktreePaths.identity(path) == WorktreePaths.identity(value.gitfile.path) {
                throw WorktreeEvidenceError.unavailable(path)
            }
            return try base.read(path)
        }, names: base.names)
        let unsupported = replacingMetadata { path, original in
            WorktreePaths.identity(path) == WorktreePaths.identity(value.gitfile.path) ? self.node(S_IFIFO) : original
        }
        for contents in ["malformed\n", "gitdir: " + value.root.appendingPathComponent("missing-admin").path + "\n"] {
            try Data(contents.utf8).write(to: value.gitfile)
            XCTAssertTrue(WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil)[1].hasBrokenLink)
            XCTAssertFalse(WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil, fileSystem: unreadable)[1].hasBrokenLink)
            XCTAssertFalse(WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil, fileSystem: unsupported)[1].hasBrokenLink)
        }
        try FileManager.default.removeItem(at: value.gitfile)
        XCTAssertTrue(WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil)[1].hasBrokenLink)
    }

    func testFingerprintIncludesOnlyConsentRelevantAdministrativeMetadata() throws {
        let value = try fixture()
        let initial = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertEqual(initial.registrationCount, 1)
        XCTAssertTrue(initial.matchesRegistrationPaths(records: [GitWorktree(path: value.common.path, isMain: true), value.record]))
        XCTAssertFalse(initial.matchesRegistrationPaths(records: [value.record, value.record]))
        XCTAssertFalse(initial.matchesRegistrationPaths(records: []))
        XCTAssertFalse(initial.matchesRegistrationPaths(records: [GitWorktree(path: value.root.path)]))
        try Data("index".utf8).write(to: value.administrative.appendingPathComponent("index"))
        try FileManager.default.createDirectory(at: value.administrative.appendingPathComponent("logs"), withIntermediateDirectories: false)
        try Data("log".utf8).write(to: value.administrative.appendingPathComponent("logs/HEAD"))
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), initial)
        for name in ["HEAD", "locked", "commondir", "gitdir"] {
            let url = value.administrative.appendingPathComponent(name)
            let prior = try? Data(contentsOf: url)
            try Data("changed\n".utf8).write(to: url)
            let changed = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
            XCTAssertNotEqual(changed, initial, name)
            XCTAssertTrue(initial.hasSameRegistrations(as: changed), name)
            XCTAssertEqual(changed.matchesRegistrationPaths(records: [value.record]), name == "HEAD" || name == "locked")
            if let prior {
                try prior.write(to: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        let extra = value.common.appendingPathComponent("worktrees/extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        let added = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertEqual(added.registrationCount, 2)
        XCTAssertFalse(initial.hasSameRegistrations(as: added))
        XCTAssertFalse(added.matchesRegistrationPaths(records: [value.record, GitWorktree(path: value.root.path)]))
        try FileManager.default.removeItem(at: extra)
        let held = value.root.appendingPathComponent("held")
        try FileManager.default.moveItem(at: value.administrative, to: held)
        try FileManager.default.copyItem(at: held, to: value.administrative)
        XCTAssertFalse(try initial.hasSameRegistrations(as: WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)))
        try FileManager.default.removeItem(at: value.common.appendingPathComponent("worktrees"))
        let empty = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertEqual(empty.registrationCount, 0)
        XCTAssertFalse(initial.hasSameRegistrations(as: empty))
        XCTAssertTrue(try empty.hasSameRegistrations(as: WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)))
        XCTAssertTrue(empty.matchesRegistrationPaths(records: [GitWorktree(path: value.common.path, isMain: true, isBare: true)]))
    }

    func testFingerprintRejectsSymlinkObjectsInvalidInventoryAndReadFailures() throws {
        let value = try fixture()
        let base = WorktreeEvidenceFileSystem.live
        for names in [[""], [".."], ["."], ["a/b"], ["topic", "topic"]] {
            let invalid = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: { _ in names })
            XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: invalid))
        }
        let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in throw WorktreeEvidenceError.unavailable(path) }, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: unreadable))
        let foreign = value.root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        for url in [value.backlink, value.administrative, value.common.appendingPathComponent("worktrees")] {
            let holding = value.root.appendingPathComponent("holding-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: holding)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign)
            XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path))
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: holding, to: url)
        }
        var nameCalls = 0
        let renamed = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: { path in
            nameCalls += 1
            return nameCalls == 1 ? try base.names(path) : []
        })
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: renamed))
        for url in [value.common, value.common.appendingPathComponent("worktrees"), value.administrative] {
            var calls = 0
            let captureReads = url.lastPathComponent == "worktrees" ? 2 : 1
            let changed = replacingMetadata { path, original in
                guard Data(path.utf8) == WorktreePaths.identity(url.path) else { return original }
                calls += 1
                return calls <= captureReads ? original : self.node(S_IFDIR, inode: 999)
            }
            XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: changed))
        }
        try FileManager.default.removeItem(at: value.common.appendingPathComponent("worktrees"))
        var calls = 0
        let created = replacingMetadata { path, original in
            guard path.hasSuffix("/worktrees") else { return original }
            calls += 1
            return calls == 1 ? nil : self.node(S_IFDIR)
        }
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: created))
    }

    func testOriginalRepairAcceptsReadableDamageAndRejectsUnprovenObjects() throws {
        let value = try fixture()
        let initial = try Data(contentsOf: value.gitfile)
        for damage in [nil, Data(), Data([255]), Data("gitdir: \n".utf8), Data("invalid\n".utf8), Data("gitdir: /missing\n".utf8)] as [Data?] {
            try FileManager.default.removeItem(at: value.gitfile)
            if let damage {
                try damage.write(to: value.gitfile)
            }
            let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
            XCTAssertEqual(target.originalPath, WorktreePaths.canonical(value.original.path))
            XCTAssertEqual(target.path, target.originalPath)
            XCTAssertEqual(target.administrativePath, WorktreePaths.canonical(value.administrative.path))
            try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
            try initial.write(to: value.gitfile)
            try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path, style: .absolute)
        }
        let foreign = value.root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data(("gitdir: " + foreign.path + "\n").utf8).write(to: value.gitfile)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        for record in [GitWorktree(path: value.original.path, isMain: true), GitWorktree(path: value.original.path, hasForeignLink: true), GitWorktree(path: foreign.path)] {
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(record, at: value.original.path, commonDirectory: value.common.path))
        }
        try initial.write(to: value.gitfile)
        let duplicate = value.common.appendingPathComponent("worktrees/duplicate")
        try FileManager.default.copyItem(at: value.administrative, to: duplicate)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: duplicate)
        for backlink in [Data(), Data([255]), Data([0]), Data((value.original.path + "/other\n").utf8)] {
            try backlink.write(to: value.backlink)
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
            XCTAssertFalse(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path).matchesRegistrationPaths(records: [value.record]))
        }
    }

    func testAmbiguousOriginalGitfilesCannotAuthorizeGenericRepair() throws {
        let value = try fixture()
        let originalGitfile = try Data(contentsOf: value.gitfile)
        let administrativeFiles = ["gitdir", "commondir", "HEAD"].map { value.administrative.appendingPathComponent($0) }
        let originalMetadata = try administrativeFiles.map { try Data(contentsOf: $0) }
        let records = [GitWorktree(path: value.common.deletingLastPathComponent().path, isMain: true), value.record]
        let unresolved = Data(("gitdir: " + value.root.appendingPathComponent("unrelated-missing-admin").path + "\n").utf8)
        let damage: [Data?] = [nil, Data(), Data([255]), Data("gitdir: \n".utf8), Data("not a gitfile\n".utf8), unresolved]
        for (index, contents) in damage.enumerated() {
            try FileManager.default.removeItem(at: value.gitfile)
            if let contents {
                try contents.write(to: value.gitfile)
            }
            let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil)[1]
            XCTAssertTrue(inspected.hasBrokenLink, "damage \(index)")
            XCTAssertFalse(inspected.hasForeignLink, "damage \(index)")
            XCTAssertFalse(WorktreeLinkInspector.canRepair(inspected, at: value.original.path, commonDirectory: value.common.path), "Unproven damage \(index) requires explicit reclaim consent")
            XCTAssertEqual(try? Data(contentsOf: value.gitfile), contents)
            XCTAssertEqual(try administrativeFiles.map { try Data(contentsOf: $0) }, originalMetadata)
            try originalGitfile.write(to: value.gitfile)
        }
        XCTAssertTrue(WorktreeLinkInspector.canRepair(value.record, at: value.original.path, commonDirectory: value.common.path))
    }

    func testRecreatedRegisteredFolderWithoutGitfileCannotAuthorizeGenericRepair() throws {
        let value = try fixture()
        let originalGitfile = try Data(contentsOf: value.gitfile)
        let administrativeFiles = ["gitdir", "commondir", "HEAD"].map { value.administrative.appendingPathComponent($0) }
        let originalMetadata = try administrativeFiles.map { try Data(contentsOf: $0) }
        let held = value.root.appendingPathComponent("held-original")
        try FileManager.default.moveItem(at: value.original, to: held)
        try FileManager.default.createDirectory(at: value.original, withIntermediateDirectories: false)
        let unrelatedFile = value.original.appendingPathComponent("unrelated.txt")
        try Data("unrelated recreated directory\n".utf8).write(to: unrelatedFile)
        let records = [GitWorktree(path: value.common.deletingLastPathComponent().path, isMain: true), value.record]
        let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: value.common.path, currentPath: nil)[1]
        XCTAssertTrue(inspected.folderExists)
        XCTAssertTrue(inspected.hasBrokenLink)
        XCTAssertFalse(inspected.hasForeignLink)
        XCTAssertFalse(WorktreeLinkInspector.canRepair(inspected, at: value.original.path, commonDirectory: value.common.path), "A backlink path cannot authorize attaching an unrelated recreated directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.gitfile.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), Data("unrelated recreated directory\n".utf8))
        XCTAssertEqual(try Data(contentsOf: held.appendingPathComponent(".git")), originalGitfile)
        XCTAssertEqual(try administrativeFiles.map { try Data(contentsOf: $0) }, originalMetadata)
    }

    func testRegularAdministrativeStraysDoNotPoisonRegistrationInventory() throws {
        let value = try fixture()
        let administrativeFiles = ["gitdir", "commondir", "HEAD"].map { value.administrative.appendingPathComponent($0) }
        let originalMetadata = try administrativeFiles.map { try Data(contentsOf: $0) }
        let originalGitfile = try Data(contentsOf: value.gitfile)
        let root = value.common.appendingPathComponent("worktrees")
        let strays = [".DS_Store", "._topic", "ordinary-file"].map { root.appendingPathComponent($0) }
        for stray in strays {
            try Data("opaque regular stray\n".utf8).write(to: stray)
        }
        XCTAssertNoThrow(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path))
        if let fingerprint = try? WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path) {
            XCTAssertEqual(fingerprint.registrationCount, 1)
            XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        }
        XCTAssertEqual(try administrativeFiles.map { try Data(contentsOf: $0) }, originalMetadata)
        XCTAssertEqual(try Data(contentsOf: value.gitfile), originalGitfile)
        XCTAssertEqual(try strays.map { try Data(contentsOf: $0) }, Array(repeating: Data("opaque regular stray\n".utf8), count: strays.count))
    }

    func testLocatedRepairRequiresExactCurrentAdministrativeLink() throws {
        let value = try fixture()
        let moved = value.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: value.original, to: moved)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: moved.path, commonDirectory: value.common.path)
        try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
        for damage in [nil, Data(), Data("invalid\n".utf8), Data("gitdir: /missing\n".utf8)] as [Data?] {
            try FileManager.default.removeItem(at: moved.appendingPathComponent(".git"))
            if let damage {
                try damage.write(to: moved.appendingPathComponent(".git"))
            }
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: moved.path, commonDirectory: value.common.path))
            try Data(("gitdir: " + value.administrative.path + "\n").utf8).write(to: moved.appendingPathComponent(".git"))
        }
        try Data((moved.appendingPathComponent(".git").path + "\n").utf8).write(to: value.backlink)
        let repaired = GitWorktree(path: moved.path)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: [repaired], commonDirectory: value.common.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [repaired, value.record], commonDirectory: value.common.path))
    }

    func testQueuedRepairRejectsReplacedCheckoutGitfileBacklinkAndRegistration() throws {
        let value = try fixture()
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let originalLink = try Data(contentsOf: value.gitfile)
        let originalBacklink = try Data(contentsOf: value.backlink)
        try Data("gitdir: /foreign\n".utf8).write(to: value.gitfile)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        try originalLink.write(to: value.gitfile)
        try Data("/foreign/.git\n".utf8).write(to: value.backlink)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        try originalBacklink.write(to: value.backlink)
        let commonFile = value.administrative.appendingPathComponent("commondir")
        let originalCommon = try Data(contentsOf: commonFile)
        try Data("../../../foreign\n".utf8).write(to: commonFile)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        try originalCommon.write(to: commonFile)
        for folder in [value.original, value.administrative, value.common] {
            let held = value.root.appendingPathComponent("held-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: folder, to: held)
            try FileManager.default.copyItem(at: held, to: folder)
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: held, to: folder)
        }
        try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
        let base = WorktreeEvidenceFileSystem.live
        let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            if path.hasSuffix("/.git") {
                throw WorktreeEvidenceError.unavailable(path)
            }
            return try base.read(path)
        }, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path, fileSystem: unreadable))
    }

    func testQueuedRepairRejectsAStaleTargetThatBecomesAnExistingForeignRegistration() throws {
        let value = try fixture()
        let foreign = value.root.appendingPathComponent("foreign/worktrees/topic")
        let bytes = Data(("gitdir: " + foreign.path + "\n").utf8)
        try bytes.write(to: value.gitfile)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        let directory = try WorktreeFileIdentity.capture(path: value.original.path)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        XCTAssertEqual(try Data(contentsOf: value.gitfile), bytes)
        XCTAssertEqual(try WorktreeFileIdentity.capture(path: value.original.path), directory)
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), fingerprint)
    }

    func testQueuedRepairRejectsRetargetedSelectedGitdirAlias() throws {
        let value = try fixture()
        let alias = value.root.appendingPathComponent("admin-alias")
        let foreign = value.root.appendingPathComponent("foreign/worktrees/topic")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.administrative)
        let bytes = Data(("gitdir: " + alias.path + "\n").utf8)
        try bytes.write(to: value.gitfile)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        XCTAssertEqual(try Data(contentsOf: value.gitfile), bytes)
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), fingerprint)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), foreign.path)
    }

    func testQueuedRepairRejectsRetargetedAdministrativeBacklinkAlias() throws {
        let value = try fixture()
        let alias = value.root.appendingPathComponent("checkout-alias")
        let foreign = value.root.appendingPathComponent("foreign-checkout")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.original)
        let bytes = Data((alias.appendingPathComponent(".git").path + "\n").utf8)
        try bytes.write(to: value.backlink)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        XCTAssertEqual(try Data(contentsOf: value.backlink), bytes)
        let changed = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertNotEqual(changed, fingerprint)
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        XCTAssertFalse(changed.matchesRegistrationPaths(records: [value.record]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), foreign.path)
    }

    func testQueuedRepairRejectsRetargetedAdministrativeCommonAlias() throws {
        let value = try fixture()
        let alias = value.root.appendingPathComponent("common-alias")
        let foreign = value.root.appendingPathComponent("foreign-common")
        let commonFile = value.administrative.appendingPathComponent("commondir")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.common)
        let bytes = Data((alias.path + "\n").utf8)
        try bytes.write(to: commonFile)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
        XCTAssertEqual(try Data(contentsOf: commonFile), bytes)
        let changed = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertNotEqual(changed, fingerprint)
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        XCTAssertFalse(changed.matchesRegistrationPaths(records: [value.record]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), foreign.path)
    }

    func testQueuedRepairAcceptsStableOwnedPointerAliases() throws {
        let value = try fixture()
        let administrativeAlias = value.root.appendingPathComponent("admin-alias")
        let checkoutAlias = value.root.appendingPathComponent("checkout-alias")
        let commonAlias = value.root.appendingPathComponent("common-alias")
        for (alias, destination) in [(administrativeAlias, value.administrative), (checkoutAlias, value.original), (commonAlias, value.common)] {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        }
        try Data(("gitdir: " + administrativeAlias.path + "\n").utf8).write(to: value.gitfile)
        try Data((checkoutAlias.appendingPathComponent(".git").path + "\n").utf8).write(to: value.backlink)
        try Data((commonAlias.path + "\n").utf8).write(to: value.administrative.appendingPathComponent("commondir"))
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: checkoutAlias.path, commonDirectory: commonAlias.path)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: commonAlias.path)
        try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: commonAlias.path)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: commonAlias.path, style: .absolute)
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: commonAlias.path), fingerprint)
        XCTAssertEqual(target.path, WorktreePaths.canonical(value.original.path))
    }

    func testQueuedRepairBindsMissingPointerAliasResolutionAndChecksAbsenceErrors() throws {
        let value = try fixture()
        let first = value.root.appendingPathComponent("first")
        let second = value.root.appendingPathComponent("second")
        let alias = value.root.appendingPathComponent("missing-alias")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let missing = alias.appendingPathComponent("missing-admin")
        let bytes = Data(("gitdir: " + missing.path + "\n").utf8)
        try bytes.write(to: value.gitfile)
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
        let unreadable = replacingMetadata { path, original in
            if Data(path.utf8) == Data(missing.path.utf8) {
                throw WorktreeEvidenceError.unavailable(path)
            }
            return original
        }
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path, fileSystem: unreadable))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path, fileSystem: unreadable))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
        let recaptured = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        XCTAssertNotEqual(recaptured, target)
        try WorktreeLinkInspector.validateRepairTarget(recaptured, commonDirectory: value.common.path)
        XCTAssertEqual(try Data(contentsOf: value.gitfile), bytes)
    }

    func testQueuedRepairReevaluatesGitdirAliasesBeforeParentComponents() throws {
        for relativeTarget in ["worktrees/topic", "missing-admin"] {
            let value = try fixture()
            let alias = value.common.appendingPathComponent("alias")
            let ownedSubdirectory = value.common.appendingPathComponent("subdirectory")
            let foreignCommon = value.root.appendingPathComponent("foreign-common")
            let foreignSubdirectory = foreignCommon.appendingPathComponent("subdirectory")
            for folder in [ownedSubdirectory, foreignSubdirectory, foreignCommon.appendingPathComponent("worktrees/topic")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ownedSubdirectory)
            let rawTarget = alias.path + "/../" + relativeTarget
            let bytes = Data(("gitdir: " + rawTarget + "\n").utf8)
            try bytes.write(to: value.gitfile)
            XCTAssertEqual(WorktreePaths.identity(rawTarget), WorktreePaths.identity(value.common.appendingPathComponent(relativeTarget).path))
            let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
            let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
            try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreignSubdirectory)
            XCTAssertEqual(WorktreePaths.identity(rawTarget), WorktreePaths.identity(foreignCommon.appendingPathComponent(relativeTarget).path))
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path), relativeTarget)
            if relativeTarget == "worktrees/topic" {
                XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
                XCTAssertTrue(WorktreeLinkInspector.inspect([value.record], commonDirectory: value.common.path, currentPath: nil)[0].hasForeignLink)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: rawTarget))
                XCTAssertNotEqual(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path), target)
            }
            XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), fingerprint)
            XCTAssertEqual(try Data(contentsOf: value.gitfile), bytes)
        }
    }

    func testFingerprintFreezesBacklinkEndpointResolutionWithoutChangingCheckoutPathAttribution() throws {
        let value = try fixture()
        let owned = value.root.appendingPathComponent("owned-gitfile")
        let foreign = value.root.appendingPathComponent("foreign-gitfile")
        try Data(contentsOf: value.gitfile).write(to: owned)
        try Data("gitdir: /foreign/worktrees/topic\n".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: value.gitfile)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: owned)
        let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        let backlink = try Data(contentsOf: value.backlink)
        try FileManager.default.removeItem(at: value.gitfile)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: foreign)
        let changed = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        XCTAssertNotEqual(fingerprint, changed)
        XCTAssertTrue(fingerprint.hasSameRegistrations(as: changed))
        XCTAssertTrue(fingerprint.matchesRegistrationPaths(records: [value.record]))
        XCTAssertTrue(changed.matchesRegistrationPaths(records: [value.record]))
        XCTAssertEqual(try Data(contentsOf: value.backlink), backlink)
    }

    func testPostconditionRequiresBothExactLinksOneRecordAndRequestedStyle() throws {
        let value = try fixture()
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path)
        for records in [[], [value.record, value.record], [GitWorktree(path: value.original.path, isMain: true)], [GitWorktree(path: value.original.path, hasForeignLink: true)], [GitWorktree(path: value.original.path, hasBrokenLink: true)]] {
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: records, commonDirectory: value.common.path))
        }
        for data in [Data(), Data("/other/.git\n".utf8)] {
            try data.write(to: value.backlink)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path))
        }
        try Data((value.gitfile.path + "\n").utf8).write(to: value.backlink)
        for data in [Data(), Data("gitdir: /other\n".utf8)] {
            try data.write(to: value.gitfile)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path))
        }
        try Data(("gitdir: " + value.administrative.path + "\n").utf8).write(to: value.gitfile)
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path, style: .relative))
        try Data("gitdir: ../main/.git/worktrees/topic\n".utf8).write(to: value.gitfile)
        try Data("../../../../original/.git\n".utf8).write(to: value.backlink)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path, style: .relative)
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path, style: .absolute))
    }

    func testRepairRejectsMissingMalformedOrForeignCommonMetadata() throws {
        let value = try fixture()
        let target = try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path)
        let commonFile = value.administrative.appendingPathComponent("commondir")
        for data in [nil, Data(), Data([255]), Data([0]), Data("../../../foreign\n".utf8)] as [Data?] {
            try FileManager.default.removeItem(at: commonFile)
            if let data {
                try data.write(to: commonFile)
            }
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(value.record, at: value.original.path, commonDirectory: value.common.path))
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: value.common.path))
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path))
            XCTAssertFalse(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path).matchesRegistrationPaths(records: [value.record]))
            try Data("../..\n".utf8).write(to: commonFile)
        }
        try Data((value.common.path + "\n").utf8).write(to: commonFile)
        try WorktreeLinkInspector.verifyRepairTarget(target, records: [value.record], commonDirectory: value.common.path)
        XCTAssertTrue(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path).matchesRegistrationPaths(records: [value.record]))
    }
}
