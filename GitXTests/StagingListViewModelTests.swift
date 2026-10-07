import XCTest

@MainActor
// swift6-safety-justification: XCTest owns the test lifetime and all mutable access is confined to the main actor.
final class StagingListViewModelTests: XCTestCase, @unchecked Sendable {
    // swift6-safety-justification: KVO may invoke a Sendable callback; this recorder serializes every access with its lock.
    private final nonisolated class KVORecorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        func snapshot() -> [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            values.removeAll()
        }
    }

    private final nonisolated class ChangedFileKVOObserver: NSObject {
        let callbacks = KVORecorder<String>()

        override func observeValue(
            forKeyPath keyPath: String?,
            of _: Any?,
            change _: [NSKeyValueChangeKey: Any]?,
            context _: UnsafeMutableRawPointer?
        ) {
            if let keyPath {
                callbacks.append(keyPath)
            }
        }
    }

    func testChangedFileDefaultsAndAllStatusIconsPreserveObjectiveCContract() {
        let changed = PBChangedFile(path: "folder/spaced ü.txt")
        XCTAssertEqual(changed.path, "folder/spaced ü.txt")
        XCTAssertEqual(changed.status, .NEW)
        XCTAssertFalse(changed.hasStagedChanges)
        XCTAssertFalse(changed.hasUnstagedChanges)
        XCTAssertNil(changed.commitBlobSHA)
        XCTAssertNil(changed.commitBlobMode)
        for (status, imageName) in [
            (PBChangedFileStatus.NEW, "new_file"),
            (.MODIFIED, "empty_file"),
            (.DELETED, "deleted_file"),
        ] {
            changed.status = status
            XCTAssertEqual(changed.icon(), NSImage(named: imageName))
        }
    }

    func testChangedFileCopySettersNullableMetadataAndKVC() {
        let changed = PBChangedFile(path: "initial.txt")
        let mutablePath = NSMutableString(string: "copied.txt")
        changed.setValue(mutablePath, forKey: "path")
        mutablePath.append("-mutated")
        XCTAssertEqual(changed.path, "copied.txt")
        changed.commitBlobSHA = "abc"
        changed.commitBlobMode = "100644"
        XCTAssertEqual(changed.value(forKey: "commitBlobSHA") as? String, "abc")
        XCTAssertEqual(changed.value(forKey: "commitBlobMode") as? String, "100644")
        changed.commitBlobSHA = nil
        changed.commitBlobMode = nil
        XCTAssertNil(changed.commitBlobSHA)
        XCTAssertNil(changed.commitBlobMode)
    }

    func testChangedFileStatusAndMembershipRemainKVOObservable() {
        let changed = PBChangedFile(path: "observed.txt")
        let statuses = KVORecorder<Int>()
        let memberships = KVORecorder<Bool>()
        let statusObservation = changed.observe(\.status, options: [.new]) { object, _ in
            // NS_ENUM values arrive through NSNumber in Objective-C KVO;
            // reading the observed object preserves the imported enum contract.
            statuses.append(object.status.rawValue)
        }
        let membershipObservation = changed.observe(\.hasStagedChanges, options: [.new]) { _, change in
            if let value = change.newValue {
                memberships.append(value)
            }
        }
        changed.status = .MODIFIED
        changed.hasStagedChanges = true
        changed.hasStagedChanges = false
        XCTAssertEqual(statuses.snapshot(), [PBChangedFileStatus.MODIFIED.rawValue])
        XCTAssertEqual(memberships.snapshot(), [true, false])
        withExtendedLifetime((statusObservation, membershipObservation)) {}
    }

    func testChangedFilePathDependenciesPublishExactRawIdentityAndFailClosedBoundaries() {
        let rawBytes = Data([0x66, 0xFF])
        let mutableBytes = NSMutableData(data: rawBytes)
        let changed = PBChangedFile(path: "f\\xFF", rawPath: mutableBytes as Data)
        mutableBytes.append(Data([0xFE]))
        XCTAssertEqual(changed.rawPath, rawBytes, "The facade copies the raw initializer input")
        XCTAssertNil(changed.safePath)
        let observer = ChangedFileKVOObserver()
        let keys = ["rawPath", "safePath"]
        for key in keys {
            changed.addObserver(observer, forKeyPath: key, options: [.new], context: nil)
        }
        defer { for key in keys {
            changed.removeObserver(observer, forKeyPath: key)
        } }

        changed.path = "new ü.txt"
        XCTAssertEqual(changed.rawPath, Data("new ü.txt".utf8))
        XCTAssertEqual(changed.safePath, "new ü.txt")
        XCTAssertEqual(Set(observer.callbacks.snapshot()), Set(keys), "Path changes publish both derived Cocoa properties")
        observer.callbacks.clear()
        changed.path = ""
        XCTAssertTrue(changed.rawPath.isEmpty)
        XCTAssertNil(changed.safePath)
        XCTAssertEqual(Set(observer.callbacks.snapshot()), Set(keys))
        changed.path = "invalid\0path"
        XCTAssertEqual(changed.rawPath, Data("invalid\0path".utf8))
        XCTAssertNil(changed.safePath)
    }

    func testChangedFileSideStatusesAndIconsPublishIndependentCocoaDependencies() {
        let changed = PBChangedFile(path: "partial.txt")
        changed.status = .MODIFIED
        let observer = ChangedFileKVOObserver()
        let keys = ["icon", "stagedStatus", "worktreeStatus", "stagedIcon", "worktreeIcon"]
        for key in keys {
            changed.addObserver(observer, forKeyPath: key, options: [.new], context: nil)
        }
        defer { for key in keys {
            changed.removeObserver(observer, forKeyPath: key)
        } }

        changed.status = .DELETED
        XCTAssertEqual(changed.stagedStatus, .DELETED)
        XCTAssertEqual(changed.worktreeStatus, .DELETED)
        for image in [changed.icon(), changed.stagedIcon(), changed.worktreeIcon()] {
            XCTAssertEqual(image, NSImage(named: "deleted_file"))
        }
        XCTAssertEqual(Set(observer.callbacks.snapshot()), Set(keys), "The legacy setter publishes every derived icon and side status")
        observer.callbacks.clear()

        changed.stagedStatus = .NEW
        XCTAssertEqual(changed.stagedIcon(), NSImage(named: "new_file"))
        XCTAssertEqual(changed.worktreeStatus, .DELETED)
        XCTAssertEqual(changed.worktreeIcon(), NSImage(named: "deleted_file"))
        XCTAssertEqual(changed.status, .DELETED)
        XCTAssertEqual(changed.icon(), NSImage(named: "deleted_file"))
        XCTAssertEqual(Set(observer.callbacks.snapshot()), Set(["stagedStatus", "stagedIcon"]))
        observer.callbacks.clear()

        changed.worktreeStatus = .MODIFIED
        XCTAssertEqual(changed.worktreeIcon(), NSImage(named: "empty_file"))
        XCTAssertEqual(changed.stagedStatus, .NEW)
        XCTAssertEqual(changed.stagedIcon(), NSImage(named: "new_file"))
        XCTAssertEqual(Set(observer.callbacks.snapshot()), Set(["worktreeStatus", "worktreeIcon"]))
    }

    private func file(
        _ path: String,
        status: PBChangedFileStatus = .MODIFIED,
        staged: Bool = false,
        unstaged: Bool = true
    ) -> PBChangedFile {
        let file = PBChangedFile(path: path)
        file.status = status
        file.hasStagedChanges = staged
        file.hasUnstagedChanges = unstaged
        return file
    }

    func testSectionMembershipIncludesPartiallyStagedFilesOnBothSides() {
        let model = PBStagingListViewModel()
        let changes = [
            file("staged.txt", staged: true, unstaged: false),
            file("partial.txt", staged: true, unstaged: true),
            file("unstaged.txt"),
            file("untracked.txt", status: .NEW),
        ]

        let staged = model.files(in: .staged, fromChanges: changes)
        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(staged.map(\.path), ["partial.txt", "staged.txt"])
        XCTAssertEqual(unstaged.map(\.path), ["partial.txt", "unstaged.txt", "untracked.txt"])
    }

    func testSearchFilterMatchesPathSubstringCaseAndDiacriticInsensitively() {
        let model = PBStagingListViewModel()
        model.searchText = "  cafe "
        let changes = [
            file("components/CaféApp.tsx"),
            file("components/CAFEWeather.tsx"),
            file("lib/utils.ts"),
        ]

        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(
            unstaged.map(\.path),
            ["components/CaféApp.tsx", "components/CAFEWeather.tsx"]
        )
    }

    func testStagedCountIgnoresSearchFiltering() {
        let model = PBStagingListViewModel()
        model.searchText = "visible"
        let changes = [
            file("hidden-staged.txt", staged: true, unstaged: false),
            file("visible-unstaged.txt"),
        ]

        XCTAssertTrue(model.files(in: .staged, fromChanges: changes).isEmpty)
        XCTAssertEqual(model.stagedFileCount(fromChanges: changes), 1)
    }

    func testSectionedActionSelectionsUseTheCorrectSideAndDeduplicatedUnion() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstaged = file("unstaged.txt")
        let stagedSelection = [staged, partial]
        let unstagedSelection = [partial, unstaged]

        for action in [
            PBStagingFileAction.stage,
            .discard,
            .forceDiscard,
            .ignore,
            .trash,
        ] {
            XCTAssertEqual(
                model.resolvedFiles(
                    for: action,
                    context: .sectioned,
                    stagedSelection: stagedSelection,
                    unstagedSelection: unstagedSelection
                ).map(\.path),
                ["partial.txt", "unstaged.txt"]
            )
        }
        XCTAssertEqual(
            model.resolvedFiles(
                for: .unstage,
                context: .sectioned,
                stagedSelection: stagedSelection,
                unstagedSelection: unstagedSelection
            ).map(\.path),
            ["staged.txt", "partial.txt"]
        )
        for action in [PBStagingFileAction.open, .reveal] {
            XCTAssertEqual(
                model.resolvedFiles(
                    for: action,
                    context: .sectioned,
                    stagedSelection: stagedSelection,
                    unstagedSelection: unstagedSelection
                ).map(\.path),
                ["staged.txt", "partial.txt", "unstaged.txt"],
                "sectioned navigation is staged-first and de-duplicates a partially staged path"
            )
        }
    }

    func testSplitActionSelectionsRemainScopedToTheSoleActiveSide() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")

        XCTAssertEqual(
            model.resolvedFiles(
                for: .open,
                context: .splitStaged,
                stagedSelection: [staged],
                unstagedSelection: [unstaged]
            ).map(\.path),
            ["staged.txt"]
        )
        XCTAssertTrue(model.resolvedFiles(
            for: .discard,
            context: .splitStaged,
            stagedSelection: [staged],
            unstagedSelection: [unstaged]
        ).isEmpty)
        XCTAssertEqual(
            model.resolvedFiles(
                for: .ignore,
                context: .splitUnstaged,
                stagedSelection: [staged],
                unstagedSelection: [unstaged]
            ).map(\.path),
            ["unstaged.txt"]
        )
        XCTAssertEqual(
            model.resolvedFiles(
                for: .reveal,
                context: .splitAutomatic,
                stagedSelection: [staged],
                unstagedSelection: []
            ).map(\.path),
            ["staged.txt"]
        )
        XCTAssertTrue(model.resolvedFiles(
            for: .open,
            context: .splitAutomatic,
            stagedSelection: [staged],
            unstagedSelection: [unstaged]
        ).isEmpty, "ambiguous split selections cannot accidentally become a union")
    }

    func testStatusSortOrdersDeletionsFirstThenPath() {
        let model = PBStagingListViewModel()
        model.sortOrder = .status
        let changes = [
            file("b-modified.txt", status: .MODIFIED),
            file("a-untracked.txt", status: .NEW),
            file("z-deleted.txt", status: .DELETED),
            file("a-modified.txt", status: .MODIFIED),
        ]

        let unstaged = model.files(in: .unstaged, fromChanges: changes)

        XCTAssertEqual(
            unstaged.map(\.path),
            ["z-deleted.txt", "a-modified.txt", "b-modified.txt", "a-untracked.txt"]
        )
    }

    func testDefaultSortDescriptorsPreserveStableRawIdentityAndEqualIdentityComparison() {
        let model = PBStagingListViewModel()
        let first = file("same.txt", staged: true, unstaged: false)
        let sameIdentity = file("same.txt", staged: true, unstaged: false)
        let descriptors = model.sortDescriptors

        XCTAssertEqual(descriptors.map(\.key), ["path", "rawPath"])
        XCTAssertEqual(descriptors[1].compare(first, to: sameIdentity), .orderedSame)
        XCTAssertEqual(descriptors[1].compare(sameIdentity, to: first), .orderedSame)
        XCTAssertEqual((([sameIdentity, first] as NSArray).sortedArray(using: descriptors) as? [PBChangedFile])?.map(\.rawPath),
                       [first.rawPath, first.rawPath])
        XCTAssertEqual(model.files(in: .staged, fromChanges: [sameIdentity, first]).count, 2)
    }

    func testFlattenedRowsSkipEmptySectionsAndKeepHeaderOrder() {
        let model = PBStagingListViewModel()
        let changes = [
            file("one.txt"),
            file("two.txt"),
        ]

        let rows = model.flattenedRows(fromChanges: changes)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].isHeader)
        XCTAssertEqual(rows[0].section, .unstaged)
        XCTAssertEqual(rows[1].file?.path, "one.txt")
        XCTAssertEqual(rows[2].file?.path, "two.txt")

        let mixed = model.flattenedRows(fromChanges: changes + [file("staged.txt", staged: true, unstaged: false)])
        XCTAssertTrue(mixed[0].isHeader)
        XCTAssertEqual(mixed[0].section, .staged)
        XCTAssertEqual(mixed[1].file?.path, "staged.txt")
        XCTAssertEqual(mixed[2].section, .unstaged)
        XCTAssertTrue(mixed[2].isHeader)
    }

    func testCheckboxStatesReflectFullAndPartialStaging() {
        let model = PBStagingListViewModel()
        let fullyStaged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstagedOnly = file("unstaged.txt")

        XCTAssertEqual(model.rowCheckboxState(for: fullyStaged, in: .staged), NSControl.StateValue.on.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: partial, in: .staged), NSControl.StateValue.mixed.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: partial, in: .unstaged), NSControl.StateValue.mixed.rawValue)
        XCTAssertEqual(model.rowCheckboxState(for: unstagedOnly, in: .unstaged), NSControl.StateValue.off.rawValue)

        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [fullyStaged], in: .staged),
            NSControl.StateValue.on.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [fullyStaged, partial], in: .staged),
            NSControl.StateValue.mixed.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [unstagedOnly], in: .staged),
            NSControl.StateValue.off.rawValue
        )
        XCTAssertEqual(
            model.masterCheckboxState(forChanges: [unstagedOnly], in: .unstaged),
            NSControl.StateValue.off.rawValue
        )
    }

    func testFileAndSectionControlsExposeLocalizedAccessibilityLabels() {
        let changedFile = file("Sources/App.swift")
        let cell = PBStagingFileCellView(frame: .zero)
        cell.configure(with: changedFile, checkboxState: NSControl.StateValue.off.rawValue)
        XCTAssertEqual(cell.checkbox.accessibilityLabel(), "Toggle staging for Sources/App.swift")
        XCTAssertEqual(cell.overflowButton.accessibilityLabel(), "File actions for Sources/App.swift")

        let header = PBStagingSectionHeaderView(frame: .zero)
        header.configure(title: "Staged files", fileCount: 0, masterState: NSControl.StateValue.off.rawValue)
        XCTAssertEqual(header.masterCheckbox.accessibilityLabel(), "Toggle Staged files")
        XCTAssertFalse(header.masterCheckbox.isEnabled)
    }

    func testDiffRequestsOrderStagedSelectionsFirst() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")

        let fromTables = model.diffRequests(forStagedSelection: [staged], unstagedSelection: [unstaged])
        XCTAssertEqual(fromTables.map(\.file.path), ["staged.txt", "unstaged.txt"])
        XCTAssertEqual(fromTables.map(\.staged), [true, false])

        let rows = model.flattenedRows(fromChanges: [staged, unstaged])
        // rows: [staged header, staged.txt, unstaged header, unstaged.txt]
        let requests = model.diffRequests(
            for: rows,
            selectedIndexes: IndexSet([0, 1, 3])
        )
        XCTAssertEqual(requests.map(\.file.path), ["staged.txt", "unstaged.txt"])
        XCTAssertEqual(requests.map(\.staged), [true, false])
    }

    func testSectionedDragPayloadUsesStablePathsAndSourceSections() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let partial = file("partial.txt", staged: true, unstaged: true)
        let unstaged = file("unstaged.txt")
        let rows = model.flattenedRows(fromChanges: [staged, partial, unstaged])
        let partialRows = rows.indices.filter { rows[$0].file?.path == "partial.txt" }
        XCTAssertEqual(partialRows.count, 2)

        let payload = model.sectionedDragPayload(for: rows, selectedIndexes: IndexSet(partialRows))
        XCTAssertEqual(payload.compactMap { $0["rawPath"] as? Data }, [Data("partial.txt".utf8), Data("partial.txt".utf8)])
        XCTAssertEqual(payload.compactMap { $0["sourceSection"] as? Int }, [0, 1])

        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: [payload[0]],
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            [],
            "dragging the staged side back to Staged cannot stage the remaining worktree side"
        )
        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: [payload[1]],
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            ["partial.txt"]
        )
    }

    func testSectionedDropResolutionRejectsMalformedAndFiltersMixedStaleDuplicateEntries() {
        let model = PBStagingListViewModel()
        let staged = file("staged.txt", staged: true, unstaged: false)
        let unstaged = file("unstaged.txt")
        let rows = model.flattenedRows(fromChanges: [staged, unstaged])
        let mixed: [[String: Any]] = [
            ["rawPath": Data("staged.txt".utf8), "sourceSection": PBStagingListSection.staged.rawValue],
            ["rawPath": Data("unstaged.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
            ["rawPath": Data("unstaged.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
            ["rawPath": Data("stale.txt".utf8), "sourceSection": PBStagingListSection.unstaged.rawValue],
        ]

        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: mixed,
                rows: rows,
                destinationSection: .staged
            )?.map(\.path),
            ["unstaged.txt"]
        )
        XCTAssertEqual(
            model.resolvedDropFiles(
                fromPropertyList: mixed,
                rows: rows,
                destinationSection: .unstaged
            )?.map(\.path),
            ["staged.txt"]
        )
        XCTAssertEqual(
            model.resolvedDropFiles(fromPropertyList: [], rows: rows, destinationSection: .staged),
            []
        )

        let malformed: [Any] = [
            [0, 1],
            [["rawPath": Data("unstaged.txt".utf8)]],
            [["rawPath": Data("unstaged.txt".utf8), "sourceSection": "unstaged"]],
            [["rawPath": Data("unstaged.txt".utf8), "sourceSection": 1, "extra": true]],
            [["rawPath": Data("".utf8), "sourceSection": 1]],
        ]
        for propertyList in malformed {
            XCTAssertNil(model.resolvedDropFiles(
                fromPropertyList: propertyList,
                rows: rows,
                destinationSection: .staged
            ))
        }
    }

    func testDisplayCollisionSelectionsAndDragsResolveByRawIdentity() throws {
        let model = PBStagingListViewModel()
        let invalid = PBChangedFile(path: "f\\xFF", rawPath: Data([0x66, 0xFF]))
        invalid.hasUnstagedChanges = true
        let literal = PBChangedFile(path: "f\\xFF")
        literal.hasUnstagedChanges = true
        let rows = model.flattenedRows(fromChanges: [invalid, literal])
        let files = model.files(in: .unstaged, fromChanges: [invalid, literal])
        XCTAssertEqual(files.map(\.rawPath), [literal.rawPath, invalid.rawPath])
        XCTAssertEqual(model.resolvedFiles(for: .open, context: .sectioned,
                                           stagedSelection: [], unstagedSelection: files).count, 2)
        let rawRow = try XCTUnwrap(rows.firstIndex { $0.file === invalid })
        let payload = model.sectionedDragPayload(for: rows, selectedIndexes: IndexSet(integer: rawRow))
        let selected = try XCTUnwrap(model.resolvedDropFiles(fromPropertyList: payload, rows: rows, destinationSection: .staged))
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0] === invalid)
        XCTAssertNil(invalid.safePath)
        XCTAssertEqual(literal.safePath, "f\\xFF")
    }

    func testEachSectionSortsAndRendersItsOwnStatus() {
        let model = PBStagingListViewModel()
        model.sortOrder = .status
        let deletedUntracked = file("a.txt", staged: true, unstaged: true)
        deletedUntracked.status = .DELETED
        deletedUntracked.worktreeStatus = .NEW
        let addedModified = file("b.txt", staged: true, unstaged: true)
        addedModified.status = .NEW
        addedModified.worktreeStatus = .MODIFIED
        XCTAssertEqual(model.files(in: .staged, fromChanges: [addedModified, deletedUntracked]).map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(model.files(in: .unstaged, fromChanges: [addedModified, deletedUntracked]).map(\.path), ["b.txt", "a.txt"])
        let cell = PBStagingFileCellView(frame: .zero)
        cell.configure(with: deletedUntracked, checkboxState: NSControl.StateValue.mixed.rawValue, section: .staged)
        XCTAssertTrue(cell.imageView?.image === deletedUntracked.stagedIcon())
        cell.configure(with: deletedUntracked, checkboxState: NSControl.StateValue.mixed.rawValue, section: .unstaged)
        XCTAssertTrue(cell.imageView?.image === deletedUntracked.worktreeIcon())
    }
}
