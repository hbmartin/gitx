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

    private func addOwnershipRegistration(_ value: Fixture, name: String) throws -> GitWorktree {
        let checkout = value.root.appendingPathComponent(name)
        let admin = value.common.appendingPathComponent("worktrees/" + name)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: false)
        try Data((checkout.appendingPathComponent(".git").path + "\n").utf8).write(to: admin.appendingPathComponent("gitdir"))
        try Data("../..\n".utf8).write(to: admin.appendingPathComponent("commondir"))
        try Data("ref: refs/heads/new\n".utf8).write(to: admin.appendingPathComponent("HEAD"))
        try Data(("gitdir: " + admin.path + "\n").utf8).write(to: checkout.appendingPathComponent(".git"))
        return GitWorktree(path: checkout.path)
    }

    func testRepairPostconditionsPreserveOnlyHealthyUnchangedMixedSiblingLinks() throws {
        for style in [WorktreeLinkStyle.absolute, .relative] {
            let value = try fixture(count: 1)
            let checkout = value.originals[0]
            let gitfile = checkout.appendingPathComponent(".git")
            let backlink = value.administrative[0].appendingPathComponent("gitdir")
            let absoluteGitfile = Data(("gitdir: " + value.administrative[0].path + "\n").utf8)
            let relativeGitfile = Data("gitdir: ../main/.git/worktrees/id-0\n".utf8)
            let absoluteBacklink = Data((gitfile.path + "\n").utf8)
            let relativeBacklink = Data("../../../../checkout-0/.git\n".utf8)
            try (style == .absolute ? absoluteGitfile : relativeGitfile).write(to: gitfile)
            try (style == .absolute ? relativeBacklink : absoluteBacklink).write(to: backlink)
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: style))

            // Equivalent endpoints cannot hide a changed, still wrong-style link.
            let changed = style == .absolute ? "../../../.././checkout-0/.git\n" : checkout.path + "/./.git\n"
            try Data(changed.utf8).write(to: backlink)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: style))
            try (style == .absolute ? absoluteBacklink : relativeBacklink).write(to: backlink)
            XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: style))

            // A no-op command must not satisfy an explicit request to change gitfile style.
            try (style == .absolute ? relativeGitfile : absoluteGitfile).write(to: gitfile)
            let opposite = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(opposite, records: value.records, commonDirectory: value.common.path, style: style))
        }
    }

    func testRepairPostconditionInventoryDoesNotReadHistoryOrLockPayloads() throws {
        let value = try fixture()
        try Data("keep locked\n".utf8).write(to: value.administrative[0].appendingPathComponent("locked"))
        let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        let base = WorktreeEvidenceFileSystem.live
        var historyReads: [String] = []
        let fileSystem = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            if path.hasSuffix("/HEAD") || path.hasSuffix("/locked") {
                historyReads.append(path)
                throw WorktreeEvidenceError.changed(path)
            }
            return try base.read(path)
        }, names: base.names, readLink: base.readLink, readableNode: base.readableNode)
        XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path,
                                                                     style: .absolute, fileSystem: fileSystem))
        XCTAssertTrue(historyReads.isEmpty)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, fileSystem: fileSystem))
        XCTAssertFalse(historyReads.isEmpty, "Preparation must retain complete consent evidence")
    }

    func testCancelledOwnershipInventoryStopsBeforeOrBetweenAdministrativeEntries() throws {
        let value = try fixture(count: 8)
        let base = WorktreeEvidenceFileSystem.live
        for cancellationCheck in [1, 3] {
            var checks = 0
            var reads = 0
            var metadata = 0
            let fileSystem = WorktreeEvidenceFileSystem(metadata: { path in
                metadata += 1
                return try base.metadata(path)
            }, read: { path in
                reads += 1
                return try base.read(path)
            }, names: base.names, readLink: base.readLink, readableNode: base.readableNode)
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path, fileSystem: fileSystem,
                                                                                       checkCancellation: {
                                                                                           checks += 1
                                                                                           if checks == cancellationCheck {
                                                                                               throw CancellationError()
                                                                                           }
                                                                                       })) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertLessThan(reads, 2 * value.administrative.count)
            if cancellationCheck == 1 {
                XCTAssertEqual(metadata, 0)
            }
        }
        XCTAssertEqual(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path).registrations.count, 8)
    }

    func testOwnershipSeedsAndPreparationAvoidHistoryPayloadsAndPreparationEnumeration() throws {
        for count in [0, 1, 8] {
            let value = try fixture(count: count)
            let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
            try Data("opaque".utf8).write(to: stray)
            let base = WorktreeEvidenceFileSystem.live
            var names = 0
            var reads = 0
            let cheap = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
                reads += 1
                XCTAssertFalse(path.hasSuffix("/HEAD") || path.hasSuffix("/locked") || path.hasSuffix("/index"))
                XCTAssertNotEqual(path, stray.path)
                return try base.read(path)
            }, names: { path in names += 1; return try base.names(path) }, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
            let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path, fileSystem: cheap)
            XCTAssertEqual(seeds.registrations.count, count)
            XCTAssertEqual(names, 2)
            XCTAssertEqual(reads, 2 * count)
            names = 0
            let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, fileSystem: cheap)
            XCTAssertEqual(names, 0)
            XCTAssertEqual(prepared.targets.count, count)
            XCTAssertNil(prepared.selection)
            let admitted = WorktreeEvidenceFileSystem(metadata: base.metadata, read: base.read, names: { path in names += 1; return try base.names(path) }, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, preparation: prepared, fileSystem: admitted)
            XCTAssertEqual(names, 2)
            XCTAssertEqual(scope.targets.map(\.path), value.originals.map { WorktreePaths.canonical($0.path) })
            XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        }
    }

    func testInitialPreparationAndAdmissionAllowOnlyUnrelatedSiblingAdditionsAndRemovals() throws {
        for selected in [false, true] {
            for beforePreparation in [false, true] {
                for adding in [false, true] {
                    let value = try fixture()
                    let protected = try Data(contentsOf: value.originals[0].appendingPathComponent(".git"))
                    let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
                    let selection = selected ? WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[0].path) : nil
                    let selectedIdentity = try selection.map { try WorktreeFileIdentity.capture(path: $0.path) }
                    var records = value.records
                    let change = {
                        if adding {
                            try records.append(self.addOwnershipRegistration(value, name: "added-sibling"))
                        } else {
                            try FileManager.default.removeItem(at: value.originals[1])
                            try FileManager.default.removeItem(at: value.administrative[1])
                            records.removeLast()
                        }
                    }
                    if beforePreparation {
                        try change()
                    }
                    let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: selectedIdentity)
                    if !beforePreparation {
                        try change()
                    }
                    let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared)
                    XCTAssertEqual(scope.targets.count, adding ? 3 : 1)
                    XCTAssertEqual(scope.selection, selection)
                    XCTAssertEqual(scope.targets.map(\.path), records.filter { !$0.isMain }.map { WorktreePaths.canonical($0.path) })
                    XCTAssertEqual(try Data(contentsOf: value.originals[0].appendingPathComponent(".git")), protected)
                    XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path, style: .absolute))
                }
            }
        }
    }

    func testSeedsRejectSelectedAdminFolderAndContextSubstitutionBeforeFirstPreparation() throws {
        for change in ["registration", "folder", "commondir", "backlink", "missing-registration", "missing-folder", "administrative-root", "common-root"] {
            let value = try fixture()
            let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
            let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[0].path)
            let selectedIdentity = try WorktreeFileIdentity.capture(path: selection.path)
            switch change {
            case "registration":
                let held = value.root.appendingPathComponent("held-admin")
                try FileManager.default.moveItem(at: value.administrative[0], to: held)
                try FileManager.default.copyItem(at: held, to: value.administrative[0])
            case "folder":
                let held = value.root.appendingPathComponent("held-checkout")
                try FileManager.default.moveItem(at: value.originals[0], to: held)
                try FileManager.default.copyItem(at: held, to: value.originals[0])
            case "commondir":
                try Data("./../..\n".utf8).write(to: value.administrative[0].appendingPathComponent("commondir"))
            case "backlink":
                try Data((value.originals[1].appendingPathComponent(".git").path + "\n").utf8).write(to: value.administrative[0].appendingPathComponent("gitdir"))
            case "missing-registration": try FileManager.default.removeItem(at: value.administrative[0])
            case "missing-folder": try FileManager.default.removeItem(at: value.originals[0])
            case "administrative-root":
                let old = value.root.appendingPathComponent("held-worktrees")
                let current = value.common.appendingPathComponent("worktrees")
                try FileManager.default.moveItem(at: current, to: old)
                try FileManager.default.copyItem(at: old, to: current)
            case "common-root":
                let old = value.root.appendingPathComponent("held-common")
                try FileManager.default.moveItem(at: value.common, to: old)
                try FileManager.default.copyItem(at: old, to: value.common)
            default: XCTFail(change)
            }
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: selectedIdentity), change)
        }
    }

    func testPreparationRequiresCompleteSelectionEvidenceAndPreservesUnavailableStates() throws {
        let value = try fixture()
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[0].path)
        let selectedIdentity = try WorktreeFileIdentity.capture(path: selection.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selectedIdentity: selectedIdentity))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection,
                                                                                selectedIdentity: WorktreeFileIdentity.capture(path: value.originals[1].path)))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path,
                                                                                selection: WorktreeRepairSelection(originalPath: value.root.appendingPathComponent("unknown").path, path: selection.path), selectedIdentity: selectedIdentity))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection,
                                                                                selectedIdentity: WorktreeFileIdentity.capture(path: value.originals[0].appendingPathComponent(".git").path)))
        try FileManager.default.removeItem(at: value.originals[1])
        let records = [value.records[0], value.records[1], GitWorktree(path: value.originals[1].path, folderExists: false)]
        let missing = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: value.common.path)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: missing, commonDirectory: value.common.path)
        XCTAssertEqual(prepared.targets.count, 1)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared)
        XCTAssertEqual(scope.absentLocations.count, 1)
        XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path))
        try FileManager.default.createDirectory(at: value.originals[1], withIntermediateDirectories: false)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared))
    }

    func testExplicitLocateAcceptsAPositivelyLinkedCheckoutMovedAfterDiscovery() throws {
        for copied in [false, true] {
            let value = try fixture(count: 1)
            let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
            let originalIdentity = try WorktreeFileIdentity.capture(path: value.originals[0].path)
            let before = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
            let originalGitfile = try Data(contentsOf: value.originals[0].appendingPathComponent(".git"))
            let selected = value.root.appendingPathComponent("selected")
            if copied {
                try FileManager.default.copyItem(at: value.originals[0], to: selected)
                try FileManager.default.removeItem(at: value.originals[0])
            } else {
                try FileManager.default.moveItem(at: value.originals[0], to: selected)
            }
            let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: selected.path)
            let identity = try WorktreeFileIdentity.capture(path: selected.path)
            XCTAssertEqual(identity.inode == originalIdentity.inode, !copied)
            let preparation = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity)
            let records = [value.records[0], GitWorktree(path: value.originals[0].path, folderExists: false)]
            let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: preparation)
            XCTAssertEqual(scope.targets.map(\.path), [WorktreePaths.canonical(selected.path)])
            XCTAssertFalse(scope.requiresReclaim)
            XCTAssertEqual(scope.targets.first?.selectedDirectory, identity)
            XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path), "A repository-wide request must not adopt an unlocated move")
            XCTAssertFalse(FileManager.default.fileExists(atPath: value.originals[0].path))
            XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), before)
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(".git")), originalGitfile)
            try Data((selected.appendingPathComponent(".git").path + "\n").utf8).write(to: value.administrative[0].appendingPathComponent("gitdir"))
            XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: [records[0], GitWorktree(path: selected.path)], commonDirectory: value.common.path, style: .absolute))
        }
    }

    func testExplicitLocateRejectsOriginalReappearanceAndSelectedDamageBeforePreparationOrAdmission() throws {
        for admission in [false, true] {
            for change in ["original-directory", "original-file", "original-symlink", "selected-replaced", "selected-missing", "gitfile-missing", "gitfile-empty", "gitfile-malformed", "gitfile-unresolved", "gitfile-foreign", "gitfile-symlink", "gitfile-unreadable"] {
                let value = try fixture(count: 1)
                let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
                let selected = value.root.appendingPathComponent("selected")
                try FileManager.default.moveItem(at: value.originals[0], to: selected)
                let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: selected.path)
                let identity = try WorktreeFileIdentity.capture(path: selected.path)
                let preparation = admission ? try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity) : nil
                let gitfile = selected.appendingPathComponent(".git")
                switch change {
                case "original-directory": try FileManager.default.createDirectory(at: value.originals[0], withIntermediateDirectories: false)
                case "original-file": try Data("unrelated".utf8).write(to: value.originals[0])
                case "original-symlink": try FileManager.default.createSymbolicLink(at: value.originals[0], withDestinationURL: selected)
                case "selected-replaced":
                    let held = value.root.appendingPathComponent("held-selected")
                    try FileManager.default.moveItem(at: selected, to: held)
                    try FileManager.default.copyItem(at: held, to: selected)
                case "selected-missing": try FileManager.default.removeItem(at: selected)
                case "gitfile-missing": try FileManager.default.removeItem(at: gitfile)
                case "gitfile-empty": try Data().write(to: gitfile)
                case "gitfile-malformed": try Data("invalid link\n".utf8).write(to: gitfile)
                case "gitfile-unresolved": try Data(("gitdir: " + value.root.appendingPathComponent("unavailable-admin").path + "\n").utf8).write(to: gitfile)
                case "gitfile-foreign":
                    let foreign = try fixture(count: 1)
                    try Data(("gitdir: " + foreign.administrative[0].path + "\n").utf8).write(to: gitfile)
                case "gitfile-symlink":
                    let managed = value.root.appendingPathComponent("managed-link")
                    try FileManager.default.moveItem(at: gitfile, to: managed)
                    try FileManager.default.createSymbolicLink(at: gitfile, withDestinationURL: managed)
                case "gitfile-unreadable": break
                default: XCTFail(change)
                }
                let before = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
                let base = WorktreeEvidenceFileSystem.live
                let fileSystem = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
                    if change == "gitfile-unreadable", path == gitfile.path {
                        throw WorktreeEvidenceError.unavailable(path)
                    }
                    return try base.read(path)
                }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
                if let preparation {
                    let records = [value.records[0], GitWorktree(path: value.originals[0].path, folderExists: false)]
                    XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: preparation, fileSystem: fileSystem), change)
                } else {
                    XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity, fileSystem: fileSystem), change)
                }
                XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), before)
            }
        }
    }

    func testExplicitLocatePreservesOriginalAliasBindingAndAnExistingKnownMovedLocation() throws {
        let value = try fixture(count: 1)
        let alias = value.root.appendingPathComponent("original-parent")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.root)
        let aliasedOriginal = alias.appendingPathComponent(value.originals[0].lastPathComponent)
        let records = [value.records[0], GitWorktree(path: aliasedOriginal.path)]
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: value.common.path)
        let selected = value.root.appendingPathComponent("selected")
        try FileManager.default.moveItem(at: value.originals[0], to: selected)
        let selection = WorktreeRepairSelection(originalPath: aliasedOriginal.path, path: selected.path)
        let identity = try WorktreeFileIdentity.capture(path: selected.path)
        let preparation = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity)
        let foreign = try fixture(count: 1)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign.root)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: preparation))

        let movedRecords = [value.records[0], GitWorktree(path: value.originals[0].path, movedPath: selected.path, folderExists: false)]
        let movedSeeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: movedRecords, commonDirectory: value.common.path)
        let knownSelection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: selected.path)
        let knownPreparation = try WorktreeLinkInspector.captureRepairPreparation(seeds: movedSeeds, commonDirectory: value.common.path, selection: knownSelection, selectedIdentity: identity)
        XCTAssertNoThrow(try WorktreeLinkInspector.captureRepairScope(records: movedRecords, commonDirectory: value.common.path, preparation: knownPreparation))
        let duplicate = value.root.appendingPathComponent("duplicate-positive-checkout")
        try FileManager.default.copyItem(at: selected, to: duplicate)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: movedSeeds, commonDirectory: value.common.path,
                                                                                selection: WorktreeRepairSelection(originalPath: value.originals[0].path, path: duplicate.path),
                                                                                selectedIdentity: WorktreeFileIdentity.capture(path: duplicate.path)))
    }

    func testAdmissionRejectsReusedNamesPathsChangedProofsAndMissingSelectedRegistration() throws {
        for selected in [false, true] {
            for change in ["registration", "new-name", "new-path", "folder", "gitfile", "commondir", "removed"] {
                let value = try fixture()
                let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
                let selection = selected ? WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[0].path) : nil
                let identity = try selection.map { try WorktreeFileIdentity.capture(path: $0.path) }
                let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity)
                var records = value.records
                switch change {
                case "registration":
                    let held = value.root.appendingPathComponent("held-admin")
                    try FileManager.default.moveItem(at: value.administrative[0], to: held)
                    try FileManager.default.copyItem(at: held, to: value.administrative[0])
                case "new-name":
                    let new = value.common.appendingPathComponent("worktrees/rebound")
                    try FileManager.default.moveItem(at: value.administrative[0], to: new)
                    try Data(("gitdir: " + new.path + "\n").utf8).write(to: value.originals[0].appendingPathComponent(".git"))
                case "new-path":
                    let new = value.root.appendingPathComponent("new-location")
                    try FileManager.default.moveItem(at: value.originals[0], to: new)
                    try Data((new.appendingPathComponent(".git").path + "\n").utf8).write(to: value.administrative[0].appendingPathComponent("gitdir"))
                    records[1] = GitWorktree(path: new.path)
                case "folder":
                    let held = value.root.appendingPathComponent("held-checkout")
                    try FileManager.default.moveItem(at: value.originals[0], to: held)
                    try FileManager.default.copyItem(at: held, to: value.originals[0])
                case "gitfile": try Data(("gitdir: " + value.root.path + "\n").utf8).write(to: value.originals[0].appendingPathComponent(".git"))
                case "commondir": try Data("./../..\n".utf8).write(to: value.administrative[0].appendingPathComponent("commondir"))
                case "removed":
                    try FileManager.default.removeItem(at: value.administrative[0])
                    records.remove(at: 1)
                default: XCTFail(change)
                }
                if change == "removed", !selected {
                    let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared)
                    XCTAssertEqual(scope.targets.count, 1)
                } else {
                    XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared), change)
                }
            }
        }
    }

    func testPreparedMovedTargetRetainsCanonicalProofAfterItsDirectoryAliasRetargets() throws {
        let value = try fixture(count: 1)
        let foreign = try fixture(count: 1)
        let old = value.root.appendingPathComponent("former/nested")
        let owned = value.root.appendingPathComponent("owned")
        let alias = value.common.deletingLastPathComponent().appendingPathComponent("nested")
        try FileManager.default.moveItem(at: value.originals[0], to: owned)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
        let stale = value.root.appendingPathComponent("former/.git/worktrees/id-0")
        try Data(("gitdir: " + stale.path + "\n").utf8).write(to: owned.appendingPathComponent(".git"))
        try Data((old.appendingPathComponent(".git").path + "\n").utf8).write(to: value.administrative[0].appendingPathComponent("gitdir"))
        let records = [value.records[0], GitWorktree(path: old.path, movedPath: alias.path, folderExists: false)]
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: value.common.path)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
        XCTAssertEqual(prepared.targets[Data("id-0".utf8)]?.path, WorktreePaths.canonical(owned.path))
        let foreignMetadata = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: foreign.common.path)
        let foreignGitfile = try Data(contentsOf: foreign.originals[0].appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign.originals[0])
        let fresh = [records[0], GitWorktree(path: old.path, folderExists: false, hasForeignLink: true)]
        let scope = try WorktreeLinkInspector.captureRepairScope(records: fresh, commonDirectory: value.common.path, preparation: prepared)
        XCTAssertEqual(scope.targets.map(\.path), [WorktreePaths.canonical(owned.path)])
        XCTAssertFalse(scope.requiresReclaim)
        XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path))
        XCTAssertEqual(try Data(contentsOf: foreign.originals[0].appendingPathComponent(".git")), foreignGitfile)
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: foreign.common.path), foreignMetadata)
    }

    func testSeedCaptureRejectsIncompleteInventoryUnsupportedFoldersAndReadFailures() throws {
        let value = try fixture()
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: Array(value.records.dropLast()), commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records + [value.records[1]], commonDirectory: value.common.path))
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: Array(value.records.dropLast()), commonDirectory: value.common.path, preparation: prepared))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records + [value.records[1]], commonDirectory: value.common.path, preparation: prepared))
        let base = WorktreeEvidenceFileSystem.live
        let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in throw WorktreeEvidenceError.unavailable(path) }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path, fileSystem: unreadable))
        try FileManager.default.removeItem(at: value.originals[0])
        try Data("not a folder".utf8).write(to: value.originals[0])
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path))
    }

    func testPostconditionReadsNoStrayPayloadAndAllowsContentChangesDuringIdentityCapture() throws {
        let value = try fixture(count: 1)
        let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
        try Data("old".utf8).write(to: stray)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        let base = WorktreeEvidenceFileSystem.live
        var payloadReads = 0
        var opens = 0
        let identityOnly = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            if path == stray.path {
                payloadReads += 1; XCTFail("Postcondition must not read stray payloads")
            }
            return try base.read(path)
        }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: { path in
            XCTAssertEqual(path, stray.path)
            opens += 1
            try Data("different content and size".utf8).write(to: stray)
            return try base.readableNode(path)
        })
        let inventory = try WorktreeLinkInspector.repairPostconditionInventory(commonDirectory: value.common.path, fileSystem: identityOnly)
        XCTAssertTrue(inventory.matches(scope.fingerprint))
        XCTAssertTrue(inventory.matchesRegistrationPaths(records: value.records))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(payloadReads, 0)
        XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: .absolute, fileSystem: identityOnly))
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
    }

    func testPostconditionRejectsDescriptorAndIdentityBookendSubstitutionWithoutPayloadReads() throws {
        let value = try fixture(count: 1)
        let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
        try Data("opaque".utf8).write(to: stray)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
        let base = WorktreeEvidenceFileSystem.live
        var info = stat()
        XCTAssertEqual(lstat(stray.path, &info), 0)
        info.st_ino += 1
        let different = WorktreeEvidenceNode(info)
        for change in ["during-open", "changed-after-open", "missing-after-open"] {
            var calls = 0
            let replaced = WorktreeEvidenceFileSystem(metadata: { path in
                if path == stray.path {
                    calls += 1
                    if calls > 1, change == "changed-after-open" {
                        return different
                    }
                    if calls > 1, change == "missing-after-open" {
                        return nil
                    }
                }
                return try base.metadata(path)
            }, read: { path in
                XCTAssertNotEqual(path, stray.path)
                return try base.read(path)
            }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: { path in
                change == "during-open" ? different : try base.readableNode(path)
            })
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, fileSystem: replaced))
        }
    }

    func testLightweightSeedsCannotBypassUnsafeHeadAndLockChecksAtAdmission() throws {
        for name in ["HEAD", "locked"] {
            let value = try fixture(count: 1)
            let path = value.administrative[0].appendingPathComponent(name)
            try? FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
            let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, preparation: prepared))
        }
    }

    func testPostconditionRejectsUnreadableStraysAndLinksButIgnoresHistoryPayloads() throws {
        for metadata in ["stray", "gitdir", "commondir", "HEAD", "locked"] {
            for unsupported in [false, true] {
                let value = try fixture(count: 1)
                let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
                try Data("opaque".utf8).write(to: stray)
                let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
                let path = metadata == "stray" ? stray : value.administrative[0].appendingPathComponent(metadata)
                if unsupported {
                    try? FileManager.default.removeItem(at: path)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                }
                let base = WorktreeEvidenceFileSystem.live
                let unreadable = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { current in
                    if current == path.path {
                        throw WorktreeEvidenceError.unavailable(current)
                    }
                    return try base.read(current)
                }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: { current in
                    if current == path.path {
                        throw WorktreeEvidenceError.unavailable(current)
                    }
                    return try base.readableNode(current)
                })
                // Consent must still inspect lock payloads, even though repair
                // postconditions concern only registration ownership and links.
                if metadata == "locked", !unsupported {
                    try Data("reason\n".utf8).write(to: path)
                }
                if metadata == "HEAD" || metadata == "locked" {
                    XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, fileSystem: unreadable), metadata)
                    XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path, fileSystem: unreadable), metadata)
                } else {
                    XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, fileSystem: unreadable), metadata)
                }
            }
        }
    }

    func testAdmittedScopeClassifiesNewHealthyAndReclaimSiblingsAndRejectsForeignUnreadableLinks() throws {
        for condition in ["healthy", "missing", "empty", "malformed", "unresolved", "foreign", "unreadable"] {
            let value = try fixture(count: 1)
            let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
            let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
            let sibling = try addOwnershipRegistration(value, name: "new-sibling")
            let gitfile = URL(fileURLWithPath: sibling.path).appendingPathComponent(".git")
            switch condition {
            case "missing": try FileManager.default.removeItem(at: gitfile)
            case "empty": try Data().write(to: gitfile)
            case "malformed": try Data("invalid\n".utf8).write(to: gitfile)
            case "unresolved": try Data(("gitdir: " + value.root.appendingPathComponent("missing-admin").path + "\n").utf8).write(to: gitfile)
            case "foreign": try Data(("gitdir: " + value.root.path + "\n").utf8).write(to: gitfile)
            default: break
            }
            let base = WorktreeEvidenceFileSystem.live
            let fileSystem = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
                if condition == "unreadable", path == gitfile.path {
                    throw WorktreeEvidenceError.unavailable(path)
                }
                return try base.read(path)
            }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
            let records = value.records + [sibling]
            if condition == "foreign" || condition == "unreadable" {
                XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared, fileSystem: fileSystem), condition)
            } else {
                let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: prepared, fileSystem: fileSystem)
                XCTAssertEqual(scope.targets.count, 2)
                XCTAssertEqual(scope.requiresReclaim, condition != "healthy")
                XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
            }
        }
    }

    func testAdmittedScopeBindsANewUnavailableRegistrationToItsAbsentCheckout() throws {
        let value = try fixture(count: 1)
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        let preparation = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
        let sibling = try addOwnershipRegistration(value, name: "unavailable-sibling")
        try FileManager.default.removeItem(atPath: sibling.path)
        let records = value.records + [GitWorktree(path: sibling.path, isPrunable: true, prunableReason: "gitdir file points to non-existent location", folderExists: false)]
        let before = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, preparation: preparation)
        XCTAssertEqual(scope.fingerprint.registrationCount, 2)
        XCTAssertEqual(scope.targets.map(\.path), [WorktreePaths.canonical(value.originals[0].path)])
        XCTAssertEqual(scope.absentLocations.map(\.identity), [WorktreePaths.identity(sibling.path)])
        XCTAssertFalse(scope.requiresReclaim)
        XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path, style: .absolute))
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        try FileManager.default.createDirectory(atPath: sibling.path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: records, commonDirectory: value.common.path))
    }

    func testSeedRootAbsenceIsStableAndCreatingOrReplacingItRequiresFreshEvidence() throws {
        let empty = try fixture(count: 0)
        let root = empty.common.appendingPathComponent("worktrees")
        try FileManager.default.removeItem(at: root)
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: empty.records, commonDirectory: empty.common.path)
        XCTAssertNil(seeds.root)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: empty.common.path)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: empty.records, commonDirectory: empty.common.path, preparation: prepared)
        XCTAssertTrue(scope.targets.isEmpty)
        XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: empty.records, commonDirectory: empty.common.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: empty.common.path))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: empty.records, commonDirectory: empty.common.path, preparation: prepared))
        let current = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: empty.records, commonDirectory: empty.common.path)
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: current, commonDirectory: empty.common.path))
        try Data("not a directory".utf8).write(to: root)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: current, commonDirectory: empty.common.path))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: empty.root)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: current, commonDirectory: empty.common.path))
    }

    func testSameAdministrativeObjectRestoredAfterProvisionalAbsenceNeedsFreshAnchoredProof() throws {
        let value = try fixture()
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        let held = value.root.appendingPathComponent("temporarily-unregistered")
        try FileManager.default.moveItem(at: value.administrative[1], to: held)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
        XCTAssertEqual(prepared.targets.count, 1)
        try FileManager.default.moveItem(at: held, to: value.administrative[1])
        let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, preparation: prepared)
        XCTAssertEqual(scope.targets.count, 2)
        XCTAssertEqual(scope.targets[1].administrativeIdentity, seeds.registrations[1].administrative)
        XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
    }

    func testPreparationRejectsOtherRegisteredSelectionAndDuplicateCanonicalMovedLocations() throws {
        let value = try fixture()
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[1].path)
        let identity = try WorktreeFileIdentity.capture(path: selection.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already another registered worktree"))
        }
        let shared = value.root.appendingPathComponent("shared")
        try FileManager.default.moveItem(at: value.originals[0], to: shared)
        try FileManager.default.removeItem(at: value.originals[1])
        let records = [value.records[0]] + value.originals.map { GitWorktree(path: $0.path, movedPath: shared.path, folderExists: false) }
        let conflicting = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: value.common.path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairPreparation(seeds: conflicting, commonDirectory: value.common.path))
    }

    func testAdmissionRejectsNewRegistrationClaimingTheFrozenLocatedCheckout() throws {
        let value = try fixture(count: 1)
        let located = value.root.appendingPathComponent("located")
        try FileManager.default.moveItem(at: value.originals[0], to: located)
        let records = [value.records[0], GitWorktree(path: value.originals[0].path, folderExists: false)]
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: value.common.path)
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: located.path)
        let identity = try WorktreeFileIdentity.capture(path: selection.path)
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path, selection: selection, selectedIdentity: identity)
        let new = value.common.appendingPathComponent("worktrees/new-claim")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false)
        try Data((located.appendingPathComponent(".git").path + "\n").utf8).write(to: new.appendingPathComponent("gitdir"))
        try Data("../..\n".utf8).write(to: new.appendingPathComponent("commondir"))
        try Data("ref: refs/heads/new\n".utf8).write(to: new.appendingPathComponent("HEAD"))
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records + [GitWorktree(path: located.path)], commonDirectory: value.common.path, preparation: prepared)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already another registered worktree"))
        }
    }

    func testHeadAndLockChangesDoNotEraseDiscoveryOwnershipAnchors() throws {
        let value = try fixture(count: 1)
        let seeds = try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: value.records, commonDirectory: value.common.path)
        try Data("ref: refs/heads/new-head\n".utf8).write(to: value.administrative[0].appendingPathComponent("HEAD"))
        try Data("new lock\n".utf8).write(to: value.administrative[0].appendingPathComponent("locked"))
        let prepared = try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: value.common.path)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, preparation: prepared)
        XCTAssertEqual(scope.fingerprint.registrations.first?.locked, Data("new lock\n".utf8))
        XCTAssertEqual(scope.fingerprint.registrations.first?.head, Data("ref: refs/heads/new-head\n".utf8))
        XCTAssertNoThrow(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
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
            }, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
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
                XCTAssertEqual(heads, phase == 0 ? count : 0)
                XCTAssertEqual(reads, (phase == 0 ? 6 : 5) * count)
                XCTAssertLessThanOrEqual(metadata, 24 * count + 8)
            }
        }
    }

    func testCapturedRepairStyleIncludesALoneLocatedRelativeCheckout() throws {
        let value = try fixture(count: 1)
        let located = value.root.appendingPathComponent("located")
        try Data("gitdir: ../main/.git/worktrees/id-0\n".utf8).write(to: value.originals[0].appendingPathComponent(".git"))
        try FileManager.default.moveItem(at: value.originals[0], to: located)
        let records = [value.records[0], GitWorktree(path: value.originals[0].path, folderExists: false)]
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: located.path)
        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path, selection: selection)
        XCTAssertFalse(scope.requiresReclaim)
        XCTAssertEqual(scope.preferredRepairStyle, .relative)
        try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path)

        let gitfile = located.appendingPathComponent(".git")
        try Data(("gitdir: " + value.administrative[0].path + "\n").utf8).write(to: gitfile)
        XCTAssertEqual(scope.preferredRepairStyle, .relative)
        XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
        try FileManager.default.removeItem(at: gitfile)
        XCTAssertEqual(scope.preferredRepairStyle, .relative)
    }

    func testCapturedRepairStylePreservesMixedAndUnknownFallbackPolicy() throws {
        let cases: [(styles: [WorktreeLinkStyle], expected: WorktreeLinkStyle)] = [
            ([], .absolute),
            ([.absolute], .absolute),
            ([.relative], .relative),
            ([.relative, .relative], .relative),
            ([.relative, .absolute], .absolute),
            ([.unknown], .absolute),
            ([.unknown, .unknown], .absolute),
            ([.relative, .unknown], .relative),
        ]
        for (styles, expected) in cases {
            let value = try fixture(count: styles.count)
            for (index, style) in styles.enumerated() {
                let gitfile = value.originals[index].appendingPathComponent(".git")
                switch style {
                case .absolute: break
                case .mixed:
                    XCTFail("A single gitfile cannot have mixed link styles")
                case .relative:
                    try Data("gitdir: ../main/.git/worktrees/id-\(index)\n".utf8).write(to: gitfile)
                case .unknown:
                    if index.isMultiple(of: 2) {
                        try FileManager.default.removeItem(at: gitfile)
                    } else {
                        try Data("malformed gitfile\n".utf8).write(to: gitfile)
                    }
                }
            }
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            XCTAssertEqual(scope.preferredRepairStyle, expected)
            try FileManager.default.removeItem(at: value.root)
            XCTAssertEqual(scope.preferredRepairStyle, expected)
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

    func testLocateIntoAnotherRegisteredCheckoutExplainsHowToRecover() throws {
        let value = try fixture()
        let before = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
        let gitfiles = try value.originals.map { try Data(contentsOf: $0.appendingPathComponent(".git")) }
        let selection = WorktreeRepairSelection(originalPath: value.originals[0].path, path: value.originals[1].path)
        XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path, selection: selection)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already another registered worktree"))
            XCTAssertTrue(error.localizedDescription.contains("Choose a different folder"))
        }
        XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), before)
        XCTAssertEqual(try value.originals.map { try Data(contentsOf: $0.appendingPathComponent(".git")) }, gitfiles)
    }

    func testUnidentifiedRepairRegistrationsExplainRefreshWithoutChangingEvidence() throws {
        for malformedBacklink in [false, true] {
            let value = try fixture()
            if malformedBacklink {
                try Data("not-a-checkout-gitfile\n".utf8).write(to: value.administrative[1].appendingPathComponent("gitdir"))
            }
            let records = malformedBacklink ? value.records : Array(value.records.dropLast())
            let before = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
            XCTAssertThrowsError(try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: value.common.path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("registrations cannot be identified"))
                XCTAssertTrue(error.localizedDescription.contains("Refresh the repository before repair"))
            }
            XCTAssertEqual(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path), before)
        }
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
        }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: opaque))
        XCTAssertEqual(strayReads, 1)
        let changedBytes = WorktreeEvidenceFileSystem(metadata: base.metadata, read: { path in
            path == stray.path ? Data("OPAQUE".utf8) : try base.read(path)
        }, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
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
            }, read: base.read, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
            XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: unsupported))
        }
        var calls = 0
        let disappeared = WorktreeEvidenceFileSystem(metadata: { path in
            if path == stray.path {
                return nil
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: disappeared))
        let replaced = WorktreeEvidenceFileSystem(metadata: { path in
            if path == stray.path {
                calls += 1
                if calls > 1 {
                    return nil
                }
            }
            return try base.metadata(path)
        }, read: base.read, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
        XCTAssertThrowsError(try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path, fileSystem: replaced))
    }

    func testRepairPostconditionIgnoresInPlaceRegularStrayContentAndLengthChanges() throws {
        let original = Data("opaque\n".utf8)
        for replacement in [Data("OPAQUE\n".utf8), Data("x\n".utf8), Data("longer opaque contents\n".utf8)] {
            let value = try fixture(count: 1)
            let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
            try original.write(to: stray)
            let identity = try WorktreeFileIdentity.capture(path: stray.path)
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            try replacement.write(to: stray)

            XCTAssertEqual(try WorktreeFileIdentity.capture(path: stray.path), identity)
            XCTAssertEqual(try Data(contentsOf: stray), replacement)
            XCTAssertNotEqual(replacement, original)
            let changed = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: value.common.path)
            XCTAssertFalse(scope.fingerprint.hasSameConsentEvidence(as: changed))
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path))
            XCTAssertNoThrow(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: .absolute))
        }
    }

    func testRepairPostconditionStillRejectsRegularStrayIdentityModeAndInventoryChanges() throws {
        for change in ["replacement", "removed", "added", "renamed", "directory", "symlink", "fifo", "permissions", "administrative-root", "common-root"] {
            let value = try fixture(count: 1)
            let stray = value.common.appendingPathComponent("worktrees/.DS_Store")
            let bytes = Data("opaque\n".utf8)
            try bytes.write(to: stray)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stray.path)
            let identity = try WorktreeFileIdentity.capture(path: stray.path)
            let scope = try WorktreeLinkInspector.captureRepairScope(records: value.records, commonDirectory: value.common.path)
            switch change {
            case "replacement":
                try FileManager.default.moveItem(at: stray, to: value.root.appendingPathComponent("held-stray"))
                try bytes.write(to: stray)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stray.path)
                XCTAssertNotEqual(try WorktreeFileIdentity.capture(path: stray.path), identity)
            case "removed":
                try FileManager.default.removeItem(at: stray)
            case "added":
                try bytes.write(to: value.common.appendingPathComponent("worktrees/new-stray"))
            case "renamed":
                try FileManager.default.moveItem(at: stray, to: value.common.appendingPathComponent("worktrees/renamed-stray"))
            case "directory":
                try FileManager.default.removeItem(at: stray)
                try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
            case "symlink":
                let target = value.root.appendingPathComponent("regular-target")
                try bytes.write(to: target)
                try FileManager.default.removeItem(at: stray)
                try FileManager.default.createSymbolicLink(at: stray, withDestinationURL: target)
            case "fifo":
                try FileManager.default.removeItem(at: stray)
                XCTAssertEqual(mkfifo(stray.path, 0o600), 0)
            case "permissions":
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stray.path)
                XCTAssertEqual(try WorktreeFileIdentity.capture(path: stray.path), identity)
                XCTAssertEqual(try Data(contentsOf: stray), bytes)
            case "administrative-root":
                let administrativeRoot = value.common.appendingPathComponent("worktrees")
                let holding = value.root.appendingPathComponent("held-worktrees")
                try FileManager.default.moveItem(at: administrativeRoot, to: holding)
                try FileManager.default.copyItem(at: holding, to: administrativeRoot)
            case "common-root":
                let holding = value.root.appendingPathComponent("held-common")
                try FileManager.default.moveItem(at: value.common, to: holding)
                try FileManager.default.copyItem(at: holding, to: value.common)
            default:
                XCTFail("Unhandled fixture change: \(change)")
            }
            XCTAssertThrowsError(try WorktreeLinkInspector.validateRepairScope(scope, commonDirectory: value.common.path), change)
            XCTAssertThrowsError(try WorktreeLinkInspector.verifyRepairScope(scope, records: value.records, commonDirectory: value.common.path, style: .absolute), change)
        }
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
            }, read: base.read, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
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
        }, read: { path in XCTFail("Scheduling must not read \(path)"); return Data() }, names: { path in XCTFail("Scheduling must not enumerate \(path)"); return [] }, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
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
        }, read: base.read, names: base.names, readLink: WorktreeEvidenceFileSystem.live.readLink, readableNode: WorktreeEvidenceFileSystem.live.readableNode)
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
