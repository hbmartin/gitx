import Darwin
@testable import GitXCore
import XCTest

final class WorktreeCheckoutEvidenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let common: URL
        let checkout: URL
        let administrative: URL
        var gitfile: URL {
            checkout.appendingPathComponent(".git")
        }

        var records: [GitWorktree] {
            [GitWorktree(path: common.deletingLastPathComponent().path, isMain: true), GitWorktree(path: checkout.path)]
        }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: WorktreePaths.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("gitx-checkout-evidence-\(UUID().uuidString)")
        let value = Fixture(root: root, common: root.appendingPathComponent("main/.git"), checkout: root.appendingPathComponent("linked"), administrative: root.appendingPathComponent("main/.git/worktrees/linked"))
        for directory in [value.checkout, value.administrative] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(("gitdir: " + value.administrative.path + "\n").utf8).write(to: value.gitfile)
        try Data((value.gitfile.path + "\n").utf8).write(to: value.administrative.appendingPathComponent("gitdir"))
        try Data("../..\n".utf8).write(to: value.administrative.appendingPathComponent("commondir"))
        try Data("ref: refs/heads/topic\n".utf8).write(to: value.administrative.appendingPathComponent("HEAD"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return value
    }

    func testEquivalentEndpointRawRewriteInvalidatesEvidenceWithoutHistoryOrInventoryChanges() throws {
        let value = try fixture()
        let original = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        XCTAssertTrue(original.permitsPrune)
        let originalFingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        let originalRecords = WorktreeLinkInspector.inspect(value.records, commonDirectory: value.common.path, currentPath: nil)
        let alias = value.root.appendingPathComponent("equivalent-admin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.administrative)
        let handle = try FileHandle(forWritingTo: value.gitfile)
        let rewritten = Data(("gitdir: " + alias.path + "\n").utf8)
        try handle.write(contentsOf: rewritten)
        try handle.truncate(atOffset: UInt64(rewritten.count))
        try handle.close()
        let currentRecords = WorktreeLinkInspector.inspect(value.records, commonDirectory: value.common.path, currentPath: nil)
        XCTAssertEqual(originalRecords.map(WorktreeConsentRecord.init), currentRecords.map(WorktreeConsentRecord.init))
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), originalFingerprint)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), original)
        let current = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        try Data("detached or changed symbolic HEAD\n".utf8).write(to: value.administrative.appendingPathComponent("HEAD"))
        try Data("new index".utf8).write(to: value.administrative.appendingPathComponent("index"))
        try FileManager.default.createDirectory(at: value.administrative.appendingPathComponent("logs"), withIntermediateDirectories: false)
        try Data("new log".utf8).write(to: value.administrative.appendingPathComponent("logs/HEAD"))
        XCTAssertEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: Array(value.records.reversed())), current)
    }

    func testFolderAndGitfileReplacementAreDifferentEvenWithIdenticalBytes() throws {
        let value = try fixture()
        let initial = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        let holding = value.root.appendingPathComponent("held-gitfile")
        try FileManager.default.moveItem(at: value.gitfile, to: holding)
        try FileManager.default.copyItem(at: holding, to: value.gitfile)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), initial)
        let current = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        let heldCheckout = value.root.appendingPathComponent("held-checkout")
        try FileManager.default.moveItem(at: value.checkout, to: heldCheckout)
        try FileManager.default.copyItem(at: heldCheckout, to: value.checkout)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), current)
    }

    func testMissingTargetBecomingForeignAndPointerAliasRetargetAreDetected() throws {
        let value = try fixture()
        let missing = value.root.appendingPathComponent("missing-admin")
        try Data(("gitdir: " + missing.path + "\n").utf8).write(to: value.gitfile)
        let before = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), before)
        let alias = value.root.appendingPathComponent("pointer-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.administrative)
        try Data(("gitdir: " + alias.path + "\n").utf8).write(to: value.gitfile)
        let owned = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: missing)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), owned)
    }

    func testMissingDirectoryMalformedAndUnsupportedGitObjectsHaveTypedEvidence() throws {
        let value = try fixture()
        var variants = try [WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)]
        try Data("malformed\n".utf8).write(to: value.gitfile)
        try variants.append(WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records))
        try FileManager.default.removeItem(at: value.gitfile)
        try variants.append(WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records))
        try FileManager.default.createDirectory(at: value.gitfile, withIntermediateDirectories: false)
        try variants.append(WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records))
        let base = WorktreeEvidenceFileSystem.live
        let unsupported = WorktreeEvidenceFileSystem(metadata: { path in
            if path == value.gitfile.path {
                var info = stat(); info.st_mode = mode_t(S_IFIFO); return WorktreeEvidenceNode(info)
            }
            return try base.metadata(path)
        }, read: { path in XCTFail("Unsupported objects must not be read: \(path)"); return Data() }, names: base.names)
        try variants.append(WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: unsupported))
        for index in variants.indices {
            XCTAssertTrue(variants[index].permitsPrune)
            for other in variants.indices where other != index {
                XCTAssertNotEqual(variants[index], variants[other])
            }
        }
        try FileManager.default.removeItem(at: value.checkout)
        let missingFolder = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        XCTAssertNotEqual(missingFolder, variants[2])
        XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records + [value.records[1]]))
        XCTAssertTrue(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: []).permitsPrune)
    }

    func testSymlinkDestinationAndResolvedRegularGitfileAreExactEvidence() throws {
        let value = try fixture()
        let managed = value.root.appendingPathComponent("managed-gitfile")
        try FileManager.default.moveItem(at: value.gitfile, to: managed)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: managed)
        let initial = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        XCTAssertTrue(initial.permitsPrune)
        let contents = try Data(contentsOf: managed)
        let handle = try FileHandle(forWritingTo: managed)
        let rewritten = Data(("gitdir: " + value.root.appendingPathComponent("missing").path + "\n").utf8)
        try handle.write(contentsOf: rewritten); try handle.truncate(atOffset: UInt64(rewritten.count)); try handle.close()
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), initial)
        try contents.write(to: managed)
        let equivalent = value.root.appendingPathComponent("managed-alias")
        try FileManager.default.createSymbolicLink(at: equivalent, withDestinationURL: managed)
        let base = WorktreeEvidenceFileSystem.live
        let changedDestinationBytes = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: base.names, readLink: { path in
            path == value.gitfile.path ? Data(equivalent.path.utf8) : try base.readLink(path)
        })
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: changedDestinationBytes), initial)
        try FileManager.default.removeItem(at: value.gitfile)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: equivalent)
        XCTAssertNotEqual(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records), initial)
        XCTAssertEqual(try WorktreeEvidenceFileSystem.readSymbolicLink(value.gitfile.path), Data(equivalent.path.utf8))
    }

    func testSymlinkMissingDirectoryAndUnsupportedResolvedKindsRemainDistinct() throws {
        let value = try fixture()
        let destination = value.root.appendingPathComponent("destination")
        try FileManager.default.removeItem(at: value.gitfile)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: destination)
        let missing = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let directory = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records)
        XCTAssertNotEqual(directory, missing)
        let base = WorktreeEvidenceFileSystem.live
        let unsupported = WorktreeEvidenceFileSystem(metadata: { path in
            if path == destination.path {
                var info = stat(); info.st_mode = mode_t(S_IFIFO); return WorktreeEvidenceNode(info)
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        let other = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: unsupported)
        XCTAssertNotEqual(other, directory)
        XCTAssertTrue(other.permitsPrune)
    }

    func testUnreadableOrdinaryLinksFailAndMovedLinksRemainProtectedForGuidance() throws {
        let value = try fixture()
        let base = WorktreeEvidenceFileSystem.live
        let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in throw WorktreeEvidenceError.unavailable(path) }, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: unreadable))
        let moved = value.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: value.checkout, to: moved)
        let records = [value.records[0], GitWorktree(path: value.checkout.path, movedPath: moved.path, folderExists: false)]
        let protected = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: records, fileSystem: unreadable)
        XCTAssertFalse(protected.permitsPrune)
        let brokenLink = moved.appendingPathComponent(".git")
        try FileManager.default.removeItem(at: brokenLink)
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: value.root.appendingPathComponent("missing"))
        let protectedSymlink = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: records)
        XCTAssertFalse(protectedSymlink.permitsPrune)
        XCTAssertNotEqual(protectedSymlink, protected)
        let failedReadlink = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: base.names, readLink: { path in throw WorktreeEvidenceError.unavailable(path) })
        XCTAssertFalse(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: records, fileSystem: failedReadlink).permitsPrune)
        for destination in [Data(), Data([255])] {
            let invalid = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: base.names, readLink: { _ in destination })
            XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: [GitWorktree(path: moved.path)], fileSystem: invalid))
        }
    }

    func testCaptureRejectsObjectDisappearanceReplacementAndFolderSubstitution() throws {
        let value = try fixture()
        let base = WorktreeEvidenceFileSystem.live
        for disappearing in [true, false] {
            var calls = 0
            let changed = WorktreeEvidenceFileSystem(metadata: { path in
                if path == value.gitfile.path {
                    calls += 1
                    if calls == (disappearing ? 2 : 4) {
                        return nil
                    }
                }
                return try base.metadata(path)
            }, read: base.read, names: base.names)
            XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: changed))
        }
        var folderCalls = 0
        let replacement = WorktreeEvidenceFileSystem(metadata: { path in
            if path == value.checkout.path {
                folderCalls += 1
                if folderCalls > 1 {
                    var info = stat(); info.st_mode = mode_t(S_IFDIR); info.st_ino = 999; return WorktreeEvidenceNode(info)
                }
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: replacement))
        let managed = value.root.appendingPathComponent("managed")
        try FileManager.default.moveItem(at: value.gitfile, to: managed)
        try FileManager.default.createSymbolicLink(at: value.gitfile, withDestinationURL: managed)
        var targetCalls = 0
        let vanishedTarget = WorktreeEvidenceFileSystem(metadata: { path in
            if path == managed.path {
                targetCalls += 1
                if targetCalls > 1 {
                    return nil
                }
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: vanishedTarget))
        var replacingTargetCalls = 0
        let replacedTarget = WorktreeEvidenceFileSystem(metadata: { path in
            if path == managed.path {
                replacingTargetCalls += 1
                if replacingTargetCalls > 1 {
                    var info = stat(); info.st_mode = mode_t(S_IFREG); info.st_ino = 999
                    return WorktreeEvidenceNode(info)
                }
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: replacedTarget))
    }

    func testCaptureNeverEnumeratesRegistrationsAndReadsEachRegularLinkOnce() throws {
        let value = try fixture()
        let base = WorktreeEvidenceFileSystem.live
        var reads = 0
        let bounded = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            reads += 1
            XCTAssertEqual(path, value.gitfile.path)
            return try base.read(path)
        }, names: { path in XCTFail("Checkout evidence must not enumerate \(path)"); return [] })
        let evidence = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: value.records, fileSystem: bounded)
        XCTAssertTrue(evidence.permitsPrune)
        XCTAssertEqual(reads, 1)
    }

    func testSymbolicLinkReadHandlesInterruptedFailedAndClippedReads() throws {
        var calls = 0
        let interrupted = WorktreeLinkReadOperations(read: { _, buffer, _ in
            calls += 1
            if calls == 1 {
                errno = EINTR; return -1
            }
            buffer.storeBytes(of: UInt8(42), as: UInt8.self)
            return 1
        })
        XCTAssertEqual(try WorktreeEvidenceFileSystem.readSymbolicLink("/link", operations: interrupted), Data([42]))
        XCTAssertEqual(calls, 2)
        let failed = WorktreeLinkReadOperations(read: { _, _, _ in errno = EIO; return -1 })
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readSymbolicLink("/link", operations: failed))
        let clipped = WorktreeLinkReadOperations(read: { _, _, capacity in capacity })
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readSymbolicLink("/link", operations: clipped))
        XCTAssertThrowsError(try WorktreeEvidenceFileSystem.readSymbolicLink("/not-a-link"))
    }
}
