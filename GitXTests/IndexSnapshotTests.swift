import XCTest

final class IndexSnapshotTests: XCTestCase {
    private final class WorkingTreeRepository: PBGitRepository {
        private let listing: Data
        private let directory: URL
        private let failsScan: Bool
        private let statusData: Data?

        init(listing: Data, directory: URL, failsScan: Bool = false, statusData: Data? = nil) {
            self.listing = listing
            self.directory = directory
            self.failsScan = failsScan
            self.statusData = statusData
            super.init()
        }

        override func workingDirectoryURL() -> URL? {
            directory
        }

        override func task(withArguments arguments: [Any]?) -> PBTask {
            if (arguments as? [String])?.first == "status", let statusData {
                let format = statusData.map { String(format: "\\%03o", $0) }.joined()
                return PBTask(launchPath: "/usr/bin/printf", arguments: [format], inDirectory: nil)
            }
            // PBWorkingTree uses the repository's Objective-C factory for byte output.
            if (arguments as? [String])?.contains("ls-files") == true {
                if failsScan {
                    return PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil)
                }
                let format = listing.map { String(format: "\\%03o", $0) }.joined()
                return PBTask(launchPath: "/usr/bin/printf", arguments: [format], inDirectory: nil)
            }
            return PBTask(launchPath: "/usr/bin/printf", arguments: ["indexed fallback"], inDirectory: nil)
        }
    }

    @MainActor
    func testSelectedPreviewSnapshotsCaptureOnlyExactRawPathsAndRemainImmutable() {
        let invalid = PBChangedFile(path: "invalid\\xFF.png", rawPath: Data([0xFF, 0x2E, 0x70, 0x6E, 0x67]))
        invalid.hasStagedChanges = true
        invalid.stagedStatus = .DELETED
        invalid.commitBlobMode = "100644"
        invalid.commitBlobSHA = "original blob"
        let ordinary = PBChangedFile(path: "ordinary.png")
        let files = [ordinary, invalid]
        XCTAssertTrue(PBIndexFileViewSnapshot.snapshots(forFiles: files, rawPaths: []).isEmpty)
        XCTAssertTrue(PBIndexFileViewSnapshot.snapshots(forFiles: files, rawPaths: [Data("ordinary".utf8)]).isEmpty)
        let snapshots = PBIndexFileViewSnapshot.snapshots(forFiles: files, rawPaths: [invalid.rawPath, invalid.rawPath])
        XCTAssertEqual(snapshots.map(\.rawPath), [invalid.rawPath])
        let lookup = PBIndexFileViewSnapshotLookup(snapshots: snapshots + snapshots)
        XCTAssertTrue(lookup.snapshot(rawPath: invalid.rawPath) === snapshots[0])
        XCTAssertNil(lookup.snapshot(rawPath: ordinary.rawPath))
        XCTAssertNil(PBIndexFileViewSnapshotLookup(snapshots: []).snapshot(rawPath: invalid.rawPath))
        invalid.hasStagedChanges = false
        invalid.stagedStatus = .NEW
        invalid.commitBlobSHA = "replaced blob"
        let captured = snapshots[0].materializedFile()
        XCTAssertTrue(captured.hasStagedChanges)
        XCTAssertEqual(captured.stagedStatus, .DELETED)
        XCTAssertEqual(captured.commitBlobMode, "100644")
        XCTAssertEqual(captured.commitBlobSHA, "original blob")
    }

    @MainActor
    func testWorkingStateImageSourcesPreserveRawIdentityAndUseTheRequestedSide() {
        let source: [String: Any] = [PBNativeImageSourceWorkingTreeKey: true,
                                     PBNativeImageSourceRevisionsKey: ["HEAD"],
                                     "rawPath": Data("image.png".utf8), "safePath": "image.png"]
        let unstaged = PBIndexPreviewImageSource.source(workingSource: source, staged: false)
        XCTAssertEqual(unstaged as NSDictionary, source as NSDictionary)
        let staged = PBIndexPreviewImageSource.source(workingSource: source, staged: true)
        XCTAssertEqual(staged[PBNativeImageSourceWorkingTreeKey] as? Bool, false)
        XCTAssertEqual(staged[PBNativeImageSourceRevisionsKey] as? [String], [":"])
        XCTAssertEqual(staged["rawPath"] as? Data, source["rawPath"] as? Data)
        XCTAssertEqual(staged["safePath"] as? String, "image.png")
    }

    func testWorkingTreeOmitsRawUnsupportedPathsAndPreservesSideBadgesAndBinaryContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXWorkingTreeBoundaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var listing = Data([0x66, 0xFF, 0])
        listing.append(Data("staged.txt\0deleted.txt\0binary.txt\0missing.txt\0".utf8))
        let repository = WorkingTreeRepository(listing: listing, directory: directory)
        let staged = PBChangedFile(path: "staged.txt")
        staged.status = .MODIFIED
        staged.hasStagedChanges = true
        let deleted = PBChangedFile(path: "deleted.txt")
        deleted.status = .DELETED
        deleted.hasUnstagedChanges = true
        repository.index.setValue(NSMutableArray(array: [staged, deleted]), forKey: "files")
        try Data([0, 1, 2]).write(to: directory.appendingPathComponent("binary.txt"))

        let tree = PBWorkingTree.root(for: repository)

        XCTAssertEqual(Set(tree.children.map(\.fullPath)), Set(["staged.txt", "deleted.txt", "binary.txt", "missing.txt"]))
        XCTAssertFalse(tree.children.contains { $0.path == "f\\xFF" }, "An escaped invalid-byte label is never a literal tree leaf")
        XCTAssertEqual(tree.children.first { $0.path == "staged.txt" }?.displayPath, "staged.txt  [S]")
        XCTAssertEqual(tree.children.first { $0.path == "deleted.txt" }?.displayPath, "deleted.txt  [D]")
        XCTAssertEqual(tree.children.first { $0.path == "binary.txt" }?.contents, "This file cannot be displayed as text.")
        let missing = try XCTUnwrap(tree.children.first { $0.path == "missing.txt" })
        let temporaryFile = try XCTUnwrap(missing.tmpFileNameForContents())
        defer { try? FileManager.default.removeItem(atPath: temporaryFile) }
        XCTAssertEqual(try String(contentsOfFile: temporaryFile, encoding: .utf8), "indexed fallback")
    }

    @MainActor
    func testWorkingTreeScanFailurePublishesNoInventedLeaves() {
        let repository = WorkingTreeRepository(listing: Data("ignored.txt\0".utf8),
                                               directory: FileManager.default.temporaryDirectory, failsScan: true)
        let tree = PBWorkingTree.root(for: repository)

        XCTAssertFalse(tree.leaf)
        XCTAssertTrue(tree.children.isEmpty)
    }

    func testWorkingTreePathCollectionUsesExactBytesAndPreservesFirstSeenOrder() {
        let literal = PBChangedFile(path: "f\\xFF", rawPath: Data("f\\xFF".utf8))
        let invalid = PBChangedFile(path: "f\\xFF", rawPath: Data([0x66, 0xFF]))
        let paths = PBWorkingTreePaths(files: [literal, invalid])
        var data = invalid.rawPath
        data.append(0)
        data.append(literal.rawPath)
        data.append(0)
        paths.append(data: data)
        paths.append(data: data)
        paths.append(data: Data())
        paths.append(data: Data("unterminated".utf8))
        XCTAssertEqual(paths.rawPaths, [invalid.rawPath, literal.rawPath])
        XCTAssertTrue(paths.file(for: invalid.rawPath) === invalid)
        XCTAssertTrue(paths.file(for: literal.rawPath) === literal)
        XCTAssertNil(paths.file(for: Data("missing".utf8)))
        for unsafe in ["", "/absolute", "../parent", "a/./b", "a//b", "a/", "nul\0path"] {
            XCTAssertNil(PBWorkingTreePaths.validatedHierarchyPath(unsafe))
        }
        for safe in ["folder", "nested/folder", "\u{FEFF}folder", "literal..folder"] {
            XCTAssertEqual(PBWorkingTreePaths.validatedHierarchyPath(safe), safe)
        }
    }

    @MainActor
    func testChangedTreePrefersTrackedStatusRegardlessOfRecordOrder() throws {
        let previous = PBApplicationSettings.changedFilesOnly
        PBApplicationSettings.changedFilesOnly = true
        defer { PBApplicationSettings.changedFilesOnly = previous }
        for records in ["?? same.txt\0D  same.txt\0", "D  same.txt\0?? same.txt\0"] {
            let repository = WorkingTreeRepository(listing: Data("same.txt\0".utf8), directory: FileManager.default.temporaryDirectory, statusData: Data(records.utf8))
            let presentation = PBHistoryTreePresentation(repository: repository)
            let root = presentation.tree(for: PBUncommittedChanges(repository: repository))
            XCTAssertEqual(root.children.count, 1)
            XCTAssertEqual(try presentation.displayTitle(for: XCTUnwrap(root.children.first)), "D  same.txt")
        }
    }

    func testFilenameDecodingPreservesBOMAndRoundTripsExactly() {
        for name in ["\u{FEFF}", "\u{FEFF}notes.txt", "notes.txt", "*️⃣.md", "*́.md"] {
            let bytes = Data(name.utf8)
            XCTAssertEqual(PBIndexFilePresentation.safePath(forRawPath: bytes), name)
            XCTAssertEqual(PBIndexFilePresentation.displayPath(forRawPath: bytes), name)
        }
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: Data([0xFF])))
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: Data()))
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: Data([0])))
    }

    func testPlainChangedFileHasEmptyIdentityAndCannotBeAddressed() {
        let file = PBChangedFile()
        XCTAssertEqual(file.path, "")
        XCTAssertEqual(file.rawPath, Data())
        XCTAssertNil(file.safePath)
    }

    func testParserPreservesConsecutiveEmptyRecordValidation() {
        XCTAssertEqual(parser.parseUntrackedData(Data([0, 0, 0]), error: nil)?.count, 0)
        XCTAssertEqual(parser.parseUntrackedData(Data("a\0\0b\0".utf8), error: nil)?.count, 2)
        var error: NSError?
        XCTAssertNil(parser.parseTrackedData(Data(":100644 100644 a b M\0\0".utf8), error: &error))
        XCTAssertNotNil(error)
    }

    private let parser = PBIndexStatusParser()
    private let reducer = PBIndexSnapshotReducer()

    func testRawPathCorpusSurvivesRecordOrderAndDisplayCollisions() throws {
        let paths = ["plain.txt", "space name", "line\nbreak", "\u{FEFF}name", "é.txt", "e\u{301}.txt", "*.txt", "f\\xFF"].map { Data($0.utf8) } +
            [Data([0x66, 0xFF]), Data([0x66, 0xFE])]
        XCTAssertEqual(Set(paths).count, paths.count)
        for offset in paths.indices {
            let ordered = Array(paths[offset...] + paths[..<offset])
            var stream = Data()
            for rawPath in ordered + ordered {
                stream.append(rawPath)
                stream.append(0)
            }
            let entries = try XCTUnwrap(parser.parseUntrackedData(stream, error: nil))
            XCTAssertEqual(Set(entries.keys), Set(paths), "Raw identity survives order \(offset) and duplicate records")
            for rawPath in paths {
                XCTAssertEqual(entries[rawPath]?.rawPath, rawPath)
            }
            let collected = PBWorkingTreePaths(files: [])
            collected.append(data: stream)
            XCTAssertEqual(collected.rawPaths, ordered, "First-seen order uses exact bytes")
        }
    }

    func testParserDecodesTrackedStatusesAndUnicodePaths() {
        let output = ":100644 100644 abc def M\0folder/spaced ünicode.txt\0" +
            ":100644 000000 abc 0000000000000000000000000000000000000000 D\0deleted.txt\0"
        var error: NSError?

        let entries = parser.parseTrackedData(output.data(using: .utf8), error: &error)

        XCTAssertNil(error)
        XCTAssertEqual(entries?[Data("folder/spaced ünicode.txt".utf8)]?.status, 1)
        XCTAssertEqual(entries?[Data("folder/spaced ünicode.txt".utf8)]?.commitBlobMode, "100644")
        XCTAssertEqual(entries?[Data("folder/spaced ünicode.txt".utf8)]?.commitBlobSHA, "abc")
        XCTAssertEqual(entries?[Data("deleted.txt".utf8)]?.status, 2)
    }

    func testParserHandlesEmptyTerminatedAndMalformedData() {
        XCTAssertEqual(parser.parseUntrackedData(nil, error: nil)?.count, 0)
        XCTAssertEqual(parser.parseUntrackedData(Data(), error: nil)?.count, 0)
        XCTAssertEqual(
            parser.parseUntrackedData("one.txt\0two ü.txt\0".data(using: .utf8), error: nil)?.values.map(\.path).sorted(),
            ["one.txt", "two ü.txt"]
        )

        var error: NSError?
        XCTAssertNil(parser.parseTrackedData(Data([0xFF]), error: &error))
        XCTAssertNotNil(error)
        error = nil
        XCTAssertNil(parser.parseTrackedData(":100644 100644 abc def M\0".data(using: .utf8), error: &error))
        XCTAssertNotNil(error)
    }

    func testParserClassifiesUnmergedEntriesAsModifiedNotNew() {
        // Unmerged (conflicted) entries carry mode :000000 like additions; they must be MODIFIED, not NEW,
        // so conflicted files don't display as brand-new untracked files.
        let zero = String(repeating: "0", count: 40)
        let output = ":000000 000000 \(zero) \(zero) U\0conflict.txt\0"
        let entries = parser.parseTrackedData(output.data(using: .utf8), error: nil)
        XCTAssertEqual(entries?[Data("conflict.txt".utf8)]?.status, 1)
    }

    func testParserToleratesNonUTF8PathInsteadOfAbortingEntireParse() {
        // A single non-UTF-8 path must not fail the whole-payload decode (which froze the entire file list);
        // it survives with an escaped display path and the record still parses.
        var data = Data(":100644 100644 abc def M\0".utf8)
        data.append(0xFF)
        data.append(0x00)
        let entries = parser.parseTrackedData(data, error: nil)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.values.first?.status, 1)
    }

    func testParserKeepsPathsWithTheSameLossyUTF8DisplayDistinct() {
        var data = Data(":100644 100644 abc def M\0".utf8)
        data.append(contentsOf: [0x66, 0xFF, 0x00])
        data.append(contentsOf: Data(":100644 100644 abc def M\0".utf8))
        data.append(contentsOf: [0x66, 0xFE, 0x00])

        let entries = parser.parseTrackedData(data, error: nil)

        XCTAssertEqual(entries?.count, 2, "Display decoding must never define Git filename identity")
    }

    func testParserRejectsUnterminatedTrackedAndUntrackedStreams() {
        var trackedError: NSError?
        XCTAssertNil(parser.parseTrackedData(Data(":100644 100644 old new M\0truncated".utf8), error: &trackedError))
        XCTAssertEqual(trackedError?.domain, "PBGitIndexSnapshotError")
        var untrackedError: NSError?
        XCTAssertNil(parser.parseUntrackedData(Data("complete.txt\0truncated".utf8), error: &untrackedError))
        XCTAssertEqual(untrackedError?.domain, "PBGitIndexSnapshotError")
        XCTAssertTrue(PBIndexFilePresentation.rawPaths(from: Data("complete.txt\0truncated".utf8)).isEmpty,
                      "Working-state path scans must also reject an unframed suffix")
    }

    func testReducerPreservesStagedDeletionWhenPathAlsoUntracked() {
        // `git rm --cached foo` (kept on disk) reports foo as both staged-deleted and untracked; the
        // untracked entry must not erase the staged deletion, or the user cannot see or unstage it.
        let zero = String(repeating: "0", count: 40)
        let stagedOutput = ":100644 000000 abc \(zero) D\0foo.txt\0"
        let staged = parser.parseTrackedData(stagedOutput.data(using: .utf8), error: nil)
        let untracked = parser.parseUntrackedData("foo.txt\0".data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: [:], untracked: untracked)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "foo.txt")
        XCTAssertEqual(result[0].status, 2)
        XCTAssertTrue(result[0].hasStagedChanges)
    }

    func testReducerPreservesStagedMetadataForPartialAddition() {
        let stagedOutput = ":000000 100644 0000000000000000000000000000000000000000 stagedsha A\0new.txt\0"
        let unstagedOutput = ":100644 100644 stagedsha workingsha M\0new.txt\0"
        let staged = parser.parseTrackedData(stagedOutput.data(using: .utf8), error: nil)
        let unstaged = parser.parseTrackedData(unstagedOutput.data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: unstaged, untracked: [:])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "new.txt")
        XCTAssertEqual(result[0].status, 0)
        XCTAssertEqual(result[0].commitBlobMode, "000000")
        XCTAssertEqual(result[0].commitBlobSHA, "0000000000000000000000000000000000000000")
        XCTAssertTrue(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
    }

    func testPartialRefreshRecomputesAggregateFromPreservedWorktreeAfterStagedRemoval() throws {
        let rawPath = Data("kept-on-disk.txt".utf8)
        let staged = parser.parseTrackedData(Data(":100644 000000 old zero D\0kept-on-disk.txt\0".utf8), error: nil)
        let untracked = parser.parseUntrackedData(Data("kept-on-disk.txt\0".utf8), error: nil)
        let previous = reducer.reducePrevious([], staged: staged, unstaged: [:], untracked: untracked)
        XCTAssertEqual(previous.first?.status, PBChangedFileStatus.DELETED.rawValue)
        let result = try XCTUnwrap(reducer.reducePrevious(previous, staged: [:], unstaged: nil, untracked: nil).first)
        XCTAssertEqual(result.rawPath, rawPath)
        XCTAssertFalse(result.hasStagedChanges)
        XCTAssertTrue(result.hasUnstagedChanges, "Failed worktree components preserve their last known membership")
        XCTAssertEqual(result.worktreeStatus, PBChangedFileStatus.NEW.rawValue)
        XCTAssertEqual(result.status, PBChangedFileStatus.NEW.rawValue, "The aggregate follows the side that remains present")
        XCTAssertTrue(previous[0].hasStagedChanges, "Reduction must not mutate its previous value snapshots")
        XCTAssertEqual(previous[0].status, PBChangedFileStatus.DELETED.rawValue)
    }

    func testReducerRemovesStalePathsAndPreservesSnapshotAfterCommandFailure() {
        let previous = PBIndexFileSnapshot(
            path: "tracked.txt",
            status: 1,
            commitBlobMode: "100644",
            commitBlobSHA: "abc",
            hasStagedChanges: true,
            hasUnstagedChanges: true
        )

        let preserved = reducer.reducePrevious([previous], staged: nil, unstaged: nil, untracked: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertTrue(preserved[0].hasStagedChanges)
        XCTAssertTrue(preserved[0].hasUnstagedChanges)

        let removed = reducer.reducePrevious([previous], staged: [:], unstaged: [:], untracked: [:])
        XCTAssertTrue(removed.isEmpty)
    }

    func testSuccessfulRefreshRemovesIgnoredUntrackedPathAndRetainsTrackedChange() {
        let ignored = PBIndexFileSnapshot(
            path: "ignored ü.txt",
            status: 0,
            commitBlobMode: nil,
            commitBlobSHA: nil,
            hasStagedChanges: false,
            hasUnstagedChanges: true
        )
        let tracked = PBIndexFileSnapshot(
            path: "tracked.txt",
            status: 1,
            commitBlobMode: "100644",
            commitBlobSHA: "old",
            hasStagedChanges: false,
            hasUnstagedChanges: true
        )
        let refreshedTracked = parser.parseTrackedData(
            ":100644 100644 old new M\0tracked.txt\0".data(using: .utf8),
            error: nil
        )

        let result = reducer.reducePrevious(
            [ignored, tracked],
            staged: [:],
            unstaged: refreshedTracked,
            untracked: [:]
        )

        XCTAssertEqual(result.map(\.path), ["tracked.txt"])
        XCTAssertFalse(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
        XCTAssertEqual(result[0].commitBlobSHA, "old")
    }

    func testReducerCombinesStagedUnstagedAndUntrackedEntries() {
        let staged = parser.parseTrackedData(
            ":100644 100644 old staged M\0partial.txt\0".data(using: .utf8),
            error: nil
        )
        let unstaged = parser.parseTrackedData(
            ":100644 100644 staged working M\0partial.txt\0".data(using: .utf8),
            error: nil
        )
        let untracked = parser.parseUntrackedData("new ü.txt\0".data(using: .utf8), error: nil)

        let result = reducer.reducePrevious([], staged: staged, unstaged: unstaged, untracked: untracked)
        let byPath = Dictionary(uniqueKeysWithValues: result.map { ($0.path, $0) })

        XCTAssertEqual(byPath["partial.txt"]?.commitBlobSHA, "old")
        XCTAssertTrue(byPath["partial.txt"]?.hasStagedChanges == true)
        XCTAssertTrue(byPath["partial.txt"]?.hasUnstagedChanges == true)
        XCTAssertEqual(byPath["new ü.txt"]?.status, 0)
        XCTAssertFalse(byPath["new ü.txt"]?.hasStagedChanges == true)
        XCTAssertTrue(byPath["new ü.txt"]?.hasUnstagedChanges == true)
    }

    func testEscapedDisplayCollisionRetainsRawIdentityAndSideStatus() throws {
        let invalid = Data([0x66, 0xFF])
        let literal = Data("f\\xFF".utf8)
        var untrackedData = invalid
        untrackedData.append(0)
        untrackedData.append(literal)
        untrackedData.append(0)
        let entries = try XCTUnwrap(parser.parseUntrackedData(untrackedData, error: nil))
        XCTAssertEqual(entries[invalid]?.path, "f\\xFF")
        XCTAssertEqual(entries[literal]?.path, "f\\xFF")
        let snapshots = reducer.reducePrevious([], staged: [:], unstaged: [:], untracked: entries)
        XCTAssertEqual(snapshots.map(\.rawPath), [literal, invalid])
        XCTAssertTrue(snapshots.allSatisfy(\.hasUnstagedChanges))
    }

    func testIndependentSideStatusesAndMetadataDoNotOverwriteOneAnother() throws {
        let staged = parser.parseTrackedData(Data(":100644 000000 old zero D\0same.txt\0".utf8), error: nil)
        let untracked = parser.parseUntrackedData(Data("same.txt\0".utf8), error: nil)
        let deleted = try XCTUnwrap(reducer.reducePrevious([], staged: staged, unstaged: [:], untracked: untracked).first)
        XCTAssertEqual(deleted.status, 2)
        XCTAssertEqual(deleted.stagedStatus, 2)
        XCTAssertEqual(deleted.worktreeStatus, 0)
        XCTAssertEqual(deleted.commitBlobSHA, "old")
        let worktree = parser.parseTrackedData(Data(":100644 100644 indexed changed M\0same.txt\0".utf8), error: nil)
        let nowUnstaged = try XCTUnwrap(reducer.reducePrevious([deleted], staged: [:], unstaged: worktree, untracked: [:]).first)
        XCTAssertEqual(nowUnstaged.status, 1)
        XCTAssertEqual(nowUnstaged.worktreeStatus, 1)
        XCTAssertFalse(nowUnstaged.hasStagedChanges)
        XCTAssertEqual(nowUnstaged.commitBlobSHA, "indexed")
    }

    func testReducerDeduplicatesPriorIdentityAndKeepsStableOrder() {
        func old(_ path: String) -> PBIndexFileSnapshot {
            PBIndexFileSnapshot(path: path, status: 1, commitBlobMode: nil, commitBlobSHA: nil,
                                hasStagedChanges: false, hasUnstagedChanges: true)
        }
        let untracked = parser.parseUntrackedData(Data("z.txt\0a.txt\0kept.txt\0".utf8), error: nil)
        let result = reducer.reducePrevious([old("kept.txt"), old("kept.txt")], staged: [:], unstaged: [:], untracked: untracked)
        XCTAssertEqual(result.map(\.path), ["kept.txt", "a.txt", "z.txt"])
    }

    func testMalformedMetadataAndEmptyTrackedPathFailWithoutAffectingValidRecords() {
        var nonUTF8 = Data([0xFF])
        nonUTF8.append(contentsOf: Data("\0name\0".utf8))
        for data in [nonUTF8, Data("bad metadata\0name\0".utf8), Data(":100644 100644 a b M\0\0".utf8)] {
            var error: NSError?
            XCTAssertNil(parser.parseTrackedData(data, error: &error))
            XCTAssertEqual(error?.domain, "PBGitIndexSnapshotError")
        }
        XCTAssertEqual(parser.parseUntrackedData(Data([0]), error: nil)?.count, 0)
    }

    @MainActor
    func testFileReconciliationReusesRawIdentityAndSnapshotsDoNotTrackLaterMutation() throws {
        let invalid = Data([0x66, 0xFF])
        let literal = Data("f\\xFF".utf8)
        let rawFile = PBChangedFile(path: "f\\xFF", rawPath: invalid)
        rawFile.status = .DELETED
        rawFile.hasStagedChanges = true
        let literalFile = PBChangedFile(path: "f\\xFF", rawPath: literal)
        literalFile.hasUnstagedChanges = true
        var data = invalid
        data.append(0)
        data.append(literal)
        data.append(0)
        let result = PBIndexRefreshResult(staged: nil, unstaged: [:], untracked: parser.parseUntrackedData(data, error: nil), mutationGeneration: 7)
        let reconciliation = PBIndexFileReconciliation(files: [rawFile, literalFile], result: result, reducer: reducer)
        XCTAssertFalse(reconciliation.membershipChanged)
        XCTAssertTrue(reconciliation.files[0] === rawFile)
        XCTAssertEqual(rawFile.stagedStatus, .DELETED)
        XCTAssertEqual(rawFile.worktreeStatus, .NEW)
        XCTAssertNil(rawFile.safePath)
        XCTAssertEqual(literalFile.safePath, "f\\xFF")
        let captured = PBIndexFileViewSnapshot.snapshots(forFiles: [rawFile])
        rawFile.path = "later.txt"
        rawFile.status = .MODIFIED
        rawFile.hasStagedChanges = false
        let materialized = try XCTUnwrap(captured.first).materializedFile()
        XCTAssertEqual(materialized.rawPath, invalid)
        XCTAssertEqual(materialized.stagedStatus, .DELETED)
        XCTAssertEqual(materialized.worktreeStatus, .NEW)
        XCTAssertTrue(materialized.hasStagedChanges)
        let removed = PBIndexFileReconciliation(files: reconciliation.files, result: PBIndexRefreshResult(staged: [:], unstaged: [:], untracked: [:], mutationGeneration: 8), reducer: reducer)
        XCTAssertTrue(removed.membershipChanged)
        XCTAssertTrue(removed.files.isEmpty)
        XCTAssertFalse(rawFile.hasStagedChanges)
        XCTAssertFalse(rawFile.hasUnstagedChanges)
        XCTAssertEqual(rawFile.status, .MODIFIED)
        XCTAssertEqual(rawFile.stagedStatus, .MODIFIED)
        XCTAssertEqual(rawFile.worktreeStatus, .MODIFIED)
        XCTAssertNil(rawFile.commitBlobMode)
        XCTAssertNil(rawFile.commitBlobSHA)
        XCTAssertFalse(literalFile.hasStagedChanges)
        XCTAssertFalse(literalFile.hasUnstagedChanges)
    }

    func testRawPathPresentationAndWorkingCountsFailClosed() {
        let invalid = Data([0x66, 0xFF])
        XCTAssertEqual(PBIndexFilePresentation.displayPath(forRawPath: invalid), "f\\xFF")
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: invalid))
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: Data()))
        XCTAssertNil(PBIndexFilePresentation.safePath(forRawPath: Data([0])))
        XCTAssertEqual(PBIndexFilePresentation.rawPaths(from: Data("one\0\0two\0".utf8)), [Data("one".utf8), Data("two".utf8)])
        XCTAssertFalse(PBIndexFilePresentation.pathMatchesRawPath(invalid, fullPath: "f\\xFF"))
        XCTAssertFalse(PBIndexFilePresentation.pathMatchesRawPath(nil, fullPath: nil))
        XCTAssertFalse(PBIndexFilePresentation.pathMatchesRawPath(Data("one".utf8), fullPath: "two"))
        XCTAssertTrue(PBIndexFilePresentation.pathMatchesRawPath(Data("one".utf8), fullPath: "one"))
        let deleted = PBChangedFile(path: "deleted")
        deleted.status = .DELETED
        deleted.hasStagedChanges = true
        deleted.hasUnstagedChanges = true
        deleted.worktreeStatus = .NEW
        XCTAssertEqual(PBIndexFilePresentation.workingStatus(for: deleted), "staged, untracked, deleted")
        let modified = PBChangedFile(path: "modified")
        modified.status = .MODIFIED
        modified.hasUnstagedChanges = true
        XCTAssertEqual(PBIndexFilePresentation.workingStatus(for: modified), "unstaged")
        modified.worktreeStatus = .DELETED
        XCTAssertEqual(PBIndexFilePresentation.workingStatus(for: modified), "unstaged, deleted")
        let counts = PBIndexWorkingStateSummary(files: [deleted, modified])
        XCTAssertEqual(counts.stagedCount, 1)
        XCTAssertEqual(counts.unstagedCount, 1)
        XCTAssertEqual(counts.untrackedCount, 1)
        let stagedOnly = PBChangedFile(path: "staged-only")
        stagedOnly.status = .MODIFIED
        stagedOnly.hasStagedChanges = true
        XCTAssertEqual(PBIndexFilePresentation.discardableFiles(from: [deleted, modified, stagedOnly]), [modified])
    }

    func testIndexOperationErrorsIncludeOrdinaryAndTaskDiagnostics() {
        XCTAssertEqual(PBIndexOperationErrorPresentation.message(forOperation: "Stage failed", error: nil), "Stage failed")
        let ordinary = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unavailable Git", NSLocalizedFailureReasonErrorKey: "Choose another executable"])
        XCTAssertEqual(PBIndexOperationErrorPresentation.message(forOperation: "Stage failed", error: ordinary), "Stage failed\nUnavailable Git\nChoose another executable")
        let task = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Task failed", NSLocalizedFailureReasonErrorKey: "Task failed", PBTaskTerminationStatusKey: 128, PBTaskTerminationOutputKey: "  fatal: details\n"])
        XCTAssertEqual(PBIndexOperationErrorPresentation.message(forOperation: "Unstage failed", error: task), "Unstage failed\nTask failed\nExit status: 128\nfatal: details")
        let blank = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed", PBTaskTerminationOutputKey: "  \n"])
        XCTAssertEqual(PBIndexOperationErrorPresentation.message(forOperation: "Discard failed", error: blank), "Discard failed\nfailed")
    }
}
