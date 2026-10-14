import Darwin
@testable import GitXCore
import XCTest

final class WorktreeScopeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let common: URL
        let originals: [URL]
        let administrative: [URL]

        var records: [GitWorktree] {
            [GitWorktree(path: common.deletingLastPathComponent().path, isMain: true)] + originals.map { GitWorktree(path: $0.path) }
        }
    }

    private func fixture(count: Int = 2) throws -> Fixture {
        let root = URL(fileURLWithPath: WorktreePaths.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("gitx-scope-\(UUID().uuidString)")
        let common = root.appendingPathComponent("main/.git")
        try FileManager.default.createDirectory(at: common.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
        let originals = (0 ..< count).map { root.appendingPathComponent("checkout-\($0)") }
        let administrative = (0 ..< count).map { common.appendingPathComponent("worktrees/id-\($0)") }
        for (original, admin) in zip(originals, administrative) {
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: false)
            try Data((original.appendingPathComponent(".git").path + "\n").utf8).write(to: admin.appendingPathComponent("gitdir"))
            try Data("../..\n".utf8).write(to: admin.appendingPathComponent("commondir"))
            try Data("ref: refs/heads/topic\n".utf8).write(to: admin.appendingPathComponent("HEAD"))
            try Data(("gitdir: " + admin.path + "\n").utf8).write(to: original.appendingPathComponent(".git"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, common: common, originals: originals, administrative: administrative)
    }

    func testBatchCaptureValidationAndPostconditionUseOneInventoryAndLinearReads() throws {
        for count in [1, 8, 32] {
            let value = try fixture(count: count)
            let base = WorktreeEvidenceFileSystem.live
            var names = 0
            var reads = 0
            var metadata = 0
            var heads = 0
            let counted = WorktreeEvidenceFileSystem(metadata: { path in
                metadata += 1
                return try base.metadata(path)
            }, read: { path in
                reads += 1
                if path.hasSuffix("/HEAD") {
                    heads += 1
                }
                XCTAssertFalse(path.hasSuffix("/index"))
                return try base.read(path)
            }, names: { path in
                names += 1
                return try base.names(path)
            })
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, fileSystem: counted)
            XCTAssertEqual(scope.targets.count, count)
            XCTAssertEqual(scope.fingerprint.registrationCount, count)
            XCTAssertFalse(scope.requiresReclaim)
            XCTAssertTrue(scope.absentLocations.isEmpty)
            XCTAssertEqual(scope.mainPath, WorktreePaths.canonical(value.common.deletingLastPathComponent().path))
            XCTAssertEqual(names, 2)
            XCTAssertEqual(heads, count)
            XCTAssertEqual(reads, 7 * count)
            XCTAssertLessThanOrEqual(metadata, 24 * count + 8)
            for phase in 0 ..< 2 {
                names = 0; reads = 0; metadata = 0; heads = 0
                if phase == 0 {
                    try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path, fileSystem: counted)
                } else {
                    try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: .absolute, fileSystem: counted)
                }
                XCTAssertEqual(names, 2)
                XCTAssertEqual(heads, count)
                XCTAssertEqual(reads, 6 * count)
                XCTAssertLessThanOrEqual(metadata, 24 * count + 8)
            }
        }
    }

    func testHeadOnlyChangesKeepConsentAndLocksStillInvalidateIt() throws {
        let value = try fixture()
        let initial = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        for head in ["ref: refs/heads/other\n", "0123456789012345678901234567890123456789\n"] {
            try Data(head.utf8).write(to: value.administrative[0].appendingPathComponent("HEAD"))
            let current = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            XCTAssertNotEqual(initial.fingerprint, current.fingerprint)
            XCTAssertTrue(initial.fingerprint.hasSameConsentEvidence(as: current.fingerprint))
            XCTAssertTrue(initial.hasSameConsentEvidence(as: current))
            XCTAssertTrue(current.canRenew(from: initial))
            try WorktreeLinkInspector.validateRepairScope(initial, commonDirectory: value.common.path)
            try WorktreeLinkInspector.verifyRepairScope(initial, records: value.records, commonDirectory: value.common.path)
        }
        let lock = value.administrative[0].appendingPathComponent("locked")
        for reason in ["first reason\n", "changed reason\n"] {
            try Data(reason.utf8).write(to: lock)
            let current = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            XCTAssertFalse(initial.hasSameConsentEvidence(as: current))
            XCTAssertTrue(current.canRenew(from: initial))
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(initial, commonDirectory: value.common.path))
        }
    }

    func testReclaimClassificationIsDescriptiveAndForeignOrLocatedDamageIsRejected() throws {
        let value = try fixture(count: 1)
        let dotGit = value.originals[0].appendingPathComponent(".git")
        let original = try Data(contentsOf: dotGit)
        let damaged: [(Data?, WorktreeReclaimReason)] = [(nil, .missingGitfile), (Data(), .emptyGitfile), (Data([255]), .malformedGitfile), (Data("bad\n".utf8), .malformedGitfile), (Data(("gitdir: " + value.root.appendingPathComponent("missing-admin").path + "\n").utf8), .unresolvedGitdir)]
        for (bytes, reason) in damaged {
            try FileManager.default.removeItem(at: dotGit)
            if let bytes {
                try bytes.write(to: dotGit)
            }
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            let target = try XCTUnwrap(scope.targets.first)
            XCTAssertEqual(target.ownership, .requiresReclaim(reason))
            XCTAssertTrue(target.requiresReclaim)
            XCTAssertTrue(scope.requiresReclaim)
            XCTAssertEqual(target.administrativeName, Data("id-0".utf8))
            XCTAssertEqual(target.administrativeIdentity, try WorktreeFileIdentity.capture(path: value.administrative[0].path))
            try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path))
            try original.write(to: dotGit)
            try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path)
        }
        let foreign = value.root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data(("gitdir: " + foreign.path + "\n").utf8).write(to: dotGit)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path))
        let location = value.root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: location.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, selection: selection))
        try original.write(to: dotGit)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairTarget(GitWorktree(path: value.originals[0].path, isBare: true), at: value.originals[0].path, commonDirectory: value.common.path))
    }

    func testLocateCapturesCanonicalSelectedAndSiblingMovedPaths() throws {
        let value = try fixture()
        let alias = value.root.appendingPathComponent("selected-alias")
        let selected = value.root.appendingPathComponent("selected")
        let sibling = value.root.appendingPathComponent("sibling")
        try FileManager.default.moveItem(at: value.originals[0], to: selected)
        try FileManager.default.moveItem(at: value.originals[1], to: sibling)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
        let records = [value.records[0], GitWorktree(path: value.originals[0].path, folderExists: false), GitWorktree(path: value.originals[1].path, movedPath: sibling.path, folderExists: false)]
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: alias.path)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, selection: selection)
        XCTAssertEqual(selection.pathIdentity, WorktreePaths.identity(selected.path))
        XCTAssertEqual(scope.targets.map(\.path), [selected, sibling].map { WorktreePaths.canonical($0.path) })
        XCTAssertFalse(scope.requiresReclaim)
        XCTAssertTrue(scope.canRenew(from: scope))
        try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path)
        let otherSelection = WorktreeRepairSelection(originalPath: value.originals[1].path, path: sibling.path)
        let otherScope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, selection: otherSelection)
        XCTAssertFalse(otherScope.canRenew(from: scope))
        let global = try WorktreeLinkInspector.captureRepairScope(records: [records[0], GitWorktree(path: value.originals[0].path, movedPath: selected.path, folderExists: false), records[2]], commonDirectory: value.common.path)
        XCTAssertFalse(global.canRenew(from: scope))
        XCTAssertFalse(scope.canRenew(from: global))
        for (target, path) in zip(scope.targets, [selected, sibling]) {
            try Data((path.appendingPathComponent(".git").path + "\n").utf8).write(to: URL(fileURLWithPath: target.administrativePath).appendingPathComponent("gitdir"))
        }
        let after = [records[0], GitWorktree(path: selected.path), GitWorktree(path: sibling.path)]
        try WorktreeLinkInspector.verifyRepairScope(scope, records: after, commonDirectory: value.common.path, style: .absolute)
    }

    func testUnavailableRegistrationsAreBoundToAbsenceAndFullInventory() throws {
        let value = try fixture()
        try FileManager.default.removeItem(at: value.originals[1])
        let records = [value.records[0], value.records[1], GitWorktree(path: value.originals[1].path, isPrunable: true, folderExists: false)]
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path)
        XCTAssertEqual(scope.targets.count, 1)
        let absent = try XCTUnwrap(scope.absentLocations.first)
        XCTAssertEqual(absent.path, value.originals[1].path)
        XCTAssertEqual(absent.identity, WorktreePaths.identity(absent.path))
        try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path)
        try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path)
        try FileManager.default.createDirectory(at: value.originals[1], withIntermediateDirectories: false)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path))
    }

    func testScopeRejectsIncompleteDuplicateAndConflictingSelectionEvidence() throws {
        let value = try fixture()
        for records in [Array(value.records.dropLast()), value.records + [value.records[1]]] {
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path))
        }
        for selection in [WorktreeRepairSelection(originalPath: "/not-registered", path: value.originals[0].path), WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[1].path)] {
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, selection: selection))
        }
        let moved = value.root.appendingPathComponent("shared-destination")
        try FileManager.default.moveItem(at: value.originals[0], to: moved)
        let overlapping = [value.records[0]] + value.originals.map { GitWorktree(path: $0.path, movedPath: moved.path, folderExists: false) }
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: overlapping, commonDirectory: value.common.path))
    }

    func testRenewalRejectsReusedAdministrativeNamesAndPermitsFreshScopeChanges() throws {
        let value = try fixture()
        let initial = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        let holding = value.root.appendingPathComponent("held-admin")
        try FileManager.default.moveItem(at: value.administrative[0], to: holding)
        try FileManager.default.copyItem(at: holding, to: value.administrative[0])
        let replaced = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        XCTAssertFalse(replaced.canRenew(from: initial))
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(initial, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(initial, records: value.records, commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: value.administrative[0])
        try FileManager.default.moveItem(at: holding, to: value.administrative[0])
        try FileManager.default.removeItem(at: value.administrative[1])
        let removed = try WorktreeLinkInspector.captureRepairScope(records: Array(value.records.dropLast()), commonDirectory: value.common.path)
        XCTAssertTrue(removed.canRenew(from: initial))
        XCTAssertFalse(removed.hasSameConsentEvidence(as: initial))
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(initial, records: Array(value.records.dropLast()), commonDirectory: value.common.path))
    }

    func testSelectedRegistrationCannotRenewAfterAdministrativeRename() throws {
        let value = try fixture(count: 1)
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[0].path)
        let initial = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, selection: selection)
        let renamed = value.common.appendingPathComponent("worktrees/renamed")
        try FileManager.default.moveItem(at: value.administrative[0], to: renamed)
        try Data(("gitdir: " + renamed.path + "\n").utf8).write(to: value.originals[0].appendingPathComponent(".git"))
        let current = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, selection: selection)
        XCTAssertTrue(current.fingerprint.canRenew(from: initial.fingerprint))
        XCTAssertFalse(current.canRenew(from: initial))
        XCTAssertNotEqual(current.targets[0].administrativeName, initial.targets[0].administrativeName)
    }

    func testRegularStraysAreOpaqueConsentEvidenceAndUnsupportedEntriesFailClosed() throws {
        let value = try fixture(count: 1)
        let initial = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
        try Data("opaque".utf8).write(to: stray)
        let withStray = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        XCTAssertEqual(withStray.fingerprint.registrationCount, 1)
        XCTAssertFalse(withStray.hasSameConsentEvidence(as: initial))
        XCTAssertTrue(withStray.canRenew(from: initial))
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(initial, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(initial, records: value.records, commonDirectory: value.common.path))
        let base = WorktreeEvidenceFileSystem.live
        var strayReads = 0
        let opaque = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            if path == stray.path {
                strayReads += 1; throw WorktreeEvidenceError.unavailable(path)
            }
            return try base.read(path)
        }, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: opaque))
        XCTAssertEqual(strayReads, 1)
        let changedBytes = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            path == stray.path ? Data("OPAQUE".utf8) : try base.read(path)
        }, names: base.names)
        let sameMetadata = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: changedBytes)
        XCTAssertEqual(sameMetadata.strays.map(\.fingerprint), withStray.fingerprint.strays.map(\.fingerprint))
        XCTAssertFalse(sameMetadata.hasSameConsentEvidence(as: withStray.fingerprint))
        try Data("changed opaque contents".utf8).write(to: stray)
        let changed = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        XCTAssertFalse(changed.hasSameConsentEvidence(as: withStray))
        for kind in [S_IFIFO, S_IFLNK] {
            let unsupported = WorktreeEvidenceFileSystem(metadata: { path in
                if path == stray.path {
                    var value = stat(); value.st_mode = mode_t(kind)
                    return WorktreeEvidenceNode(value)
                }
                return try base.metadata(path)
            }, read: base.read, names: base.names)
            XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: unsupported))
        }
        var calls = 0
        let disappeared = WorktreeEvidenceFileSystem(metadata: { path in
            if path == stray.path {
                return nil
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: disappeared))
        let replaced = WorktreeEvidenceFileSystem(metadata: { path in
            if path == stray.path {
                calls += 1
                if calls > 1 {
                    return nil
                }
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: replaced))
    }

    func testAbsentAliasRetargetAndPostconditionInventoryMismatchAreRejected() throws {
        let value = try fixture(count: 1)
        let first = value.root.appendingPathComponent("first")
        let second = value.root.appendingPathComponent("second")
        let alias = value.root.appendingPathComponent("alias")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let unavailable = first.appendingPathComponent("unavailable")
        let rawPath = alias.appendingPathComponent("unavailable")
        try Data((unavailable.appendingPathComponent(".git").path + "\n").utf8).write(to: value.administrative[0].appendingPathComponent("gitdir"))
        let records = [value.records[0], GitWorktree(path: rawPath.path, folderExists: false)]
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path)
        XCTAssertTrue(scope.targets.isEmpty)
        XCTAssertFalse(scope.requiresReclaim)
        try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: [records[0]], commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
    }

    func testBareAndEmptyAdministrativeRootsHaveValidEmptyScopes() throws {
        let value = try fixture(count: 0)
        let records = [GitWorktree(path: value.common.path, isMain: true, isBare: true)]
        let present = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path)
        XCTAssertFalse(present.requiresReclaim)
        try WorktreeLinkInspector.validateRepairScope(present, commonDirectory: value.common.path)
        try WorktreeLinkInspector.verifyRepairScope(present, records: records, commonDirectory: value.common.path)
        try FileManager.default.removeItem(at: value.common.appendingPathComponent("worktrees"))
        let absent = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, mainPath: value.common.path)
        XCTAssertTrue(absent.canRenew(from: absent))
        XCTAssertFalse(absent.canRenew(from: present))
        XCTAssertFalse(absent.hasSameConsentEvidence(as: present))
        try WorktreeLinkInspector.validateRepairScope(absent, commonDirectory: value.common.path)
        try WorktreeLinkInspector.verifyRepairScope(absent, records: records, commonDirectory: value.common.path)
    }

    func testExecutableFingerprintDetectsInPlaceChangesAndResolvesAliases() throws {
        let value = try fixture(count: 0)
        let executable = value.root.appendingPathComponent("git-fixture")
        let alias = value.root.appendingPathComponent("git-alias")
        try Data("initial".utf8).write(to: executable)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let initial = try WorktreeFileFingerprint.capture(path: executable.path)
        XCTAssertEqual(try WorktreeFileFingerprint.capture(path: alias.path), initial)
        XCTAssertEqual(initial.path, WorktreePaths.canonical(executable.path))
        XCTAssertEqual(initial.identity.kind, .regularFile)
        XCTAssertEqual(initial.size, 7)
        let handle = try FileHandle(forWritingTo: executable)
        try handle.write(contentsOf: Data("changed same inode contents".utf8))
        try handle.close()
        let changed = try WorktreeFileFingerprint.capture(path: executable.path)
        XCTAssertEqual(changed.identity, initial.identity)
        XCTAssertNotEqual(changed, initial)
        XCTAssertThrowsError(try WorktreeFileFingerprint.capture(path: value.root.path))
        XCTAssertThrowsError(try WorktreeFileFingerprint.capture(path: value.root.appendingPathComponent("absent").path))
        var info = stat()
        XCTAssertEqual(lstat(executable.path, &info), 0)
        for field in 0 ..< 5 {
            var altered = info
            switch field {
            case 0: altered.st_mtimespec.tv_sec += 1
            case 1: altered.st_mtimespec.tv_nsec += 1
            case 2: altered.st_ctimespec.tv_sec += 1
            case 3: altered.st_ctimespec.tv_nsec += 1
            default: altered.st_mode ^= mode_t(S_IXUSR)
            }
            let base = WorktreeEvidenceFileSystem.live
            let metadata = WorktreeEvidenceFileSystem(metadata: { path in
                path == executable.path ? WorktreeEvidenceNode(altered) : try base.metadata(path)
            }, read: base.read, names: base.names)
            let fingerprint = try WorktreeFileFingerprint.capture(path: executable.path, fileSystem: metadata)
            XCTAssertEqual(fingerprint.identity, changed.identity)
            XCTAssertNotEqual(fingerprint, changed)
        }
        XCTAssertEqual(changed.modifiedSeconds, Int64(info.st_mtimespec.tv_sec))
        XCTAssertEqual(changed.modifiedNanoseconds, Int64(info.st_mtimespec.tv_nsec))
        XCTAssertEqual(changed.changedSeconds, Int64(info.st_ctimespec.tv_sec))
        XCTAssertEqual(changed.changedNanoseconds, Int64(info.st_ctimespec.tv_nsec))
    }

    func testAdministrativeSchedulingAnchorIsBoundedAndSeparateFromConsent() throws {
        let value = try fixture(count: 1)
        let base = WorktreeEvidenceFileSystem.live
        var metadataCalls = 0
        let bounded = WorktreeEvidenceFileSystem(metadata: { path in
            metadataCalls += 1
            return try base.metadata(path)
        }, read: { path in XCTFail("Scheduling must not read \(path)"); return Data() }, names: { path in XCTFail("Scheduling must not enumerate \(path)"); return [] })
        let anchor = try WorktreeAdministrativeAnchor.capture(commonDirectory: value.common.path, fileSystem: bounded)
        XCTAssertEqual(metadataCalls, 2)
        XCTAssertEqual(anchor.commonIdentity, try WorktreeFileIdentity.capture(path: value.common.path))
        XCTAssertEqual(anchor.rootIdentity, try WorktreeFileIdentity.capture(path: value.common.appendingPathComponent("worktrees").path))
        try anchor.validate(commonDirectory: value.common.path)
        try Data("new HEAD\n".utf8).write(to: value.administrative[0].appendingPathComponent("HEAD"))
        try anchor.validate(commonDirectory: value.common.path)
        let root = value.common.appendingPathComponent("worktrees")
        var info = stat()
        XCTAssertEqual(lstat(root.path, &info), 0)
        info.st_mtimespec.tv_nsec += 1
        let changed = WorktreeEvidenceFileSystem(metadata: { path in
            path == root.path ? WorktreeEvidenceNode(info) : try base.metadata(path)
        }, read: base.read, names: base.names)
        XCTAssertThrowsError(try anchor.validate(commonDirectory: value.common.path, fileSystem: changed))
        let holding = value.root.appendingPathComponent("held-worktrees")
        try FileManager.default.moveItem(at: root, to: holding)
        let absent = try WorktreeAdministrativeAnchor.capture(commonDirectory: value.common.path)
        XCTAssertNil(absent.rootIdentity)
        try absent.validate(commonDirectory: value.common.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try absent.validate(commonDirectory: value.common.path))
        XCTAssertThrowsError(try anchor.validate(commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)
        XCTAssertThrowsError(try WorktreeAdministrativeAnchor.capture(commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: holding)
        XCTAssertThrowsError(try WorktreeAdministrativeAnchor.capture(commonDirectory: value.common.path))
    }

    func testConsentRecordIgnoresAllHistoryFieldsAndPreservesOtherDecisions() {
        let initial = WorktreeConsentRecord(GitWorktree(path: "/registered", head: "aaa", headRefName: "refs/heads/first"))
        for history in [GitWorktree(path: "/registered", head: "bbb", headRefName: "refs/remotes/origin/main"), GitWorktree(path: "/registered", head: "ccc", isDetached: true), GitWorktree(path: "/registered")] {
            XCTAssertEqual(WorktreeConsentRecord(history), initial)
        }
        for changed in [GitWorktree(path: "/other"), GitWorktree(path: "/registered", isMain: true), GitWorktree(path: "/registered", isBare: true), GitWorktree(path: "/registered", isLocked: true), GitWorktree(path: "/registered", lockReason: "reason"), GitWorktree(path: "/registered", isPrunable: true), GitWorktree(path: "/registered", prunableReason: "reason"), GitWorktree(path: "/registered", isCurrent: true), GitWorktree(path: "/registered", linkStyle: .relative), GitWorktree(path: "/registered", hasBrokenLink: true), GitWorktree(path: "/registered", movedPath: "/moved"), GitWorktree(path: "/registered", folderExists: false), GitWorktree(path: "/registered", hasForeignLink: true)] {
            XCTAssertNotEqual(WorktreeConsentRecord(changed), initial)
        }
        XCTAssertNotEqual(WorktreeConsentRecord(GitWorktree(path: "/registered", lockReason: "caf\u{e9}")), WorktreeConsentRecord(GitWorktree(path: "/registered", lockReason: "cafe\u{301}")))
        XCTAssertNotEqual(WorktreeConsentRecord(GitWorktree(path: "/registered", prunableReason: "caf\u{e9}")), WorktreeConsentRecord(GitWorktree(path: "/registered", prunableReason: "cafe\u{301}")))
    }
}
