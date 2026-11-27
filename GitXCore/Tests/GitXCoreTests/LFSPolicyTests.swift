import Foundation
@testable import GitXCore
import XCTest

final class LFSPolicyTests: XCTestCase {
    private let oid = "28720365c5e7476a011e4f43ac003ee5f16247a263b9d623aa85ed311d73bf39"
    private let otherOID = String(repeating: "b", count: 64)

    private func pointer(_ size: Int64 = 3, oid: String? = nil) throws -> LFSPointer {
        try XCTUnwrap(LFSPointer(oid: oid ?? self.oid, size: size))
    }

    private func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: Pointers

    func testParsesTheTextGitLFSWritesAndTheLegacyHawserSpecification() throws {
        let text = "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 3\n"
        let parsed = try XCTUnwrap(LFSPointer.parse(data(text)))
        XCTAssertEqual(parsed.oid, oid)
        XCTAssertEqual(parsed.size, 3)
        XCTAssertEqual(parsed.text, text)
        XCTAssertEqual(parsed.abbreviatedOID, "28720365")

        let legacy = "version https://hawser.github.com/spec/v1\noid sha256:\(oid)\nsize 12345\n"
        XCTAssertEqual(LFSPointer.parse(data(legacy))?.size, 12345)
    }

    func testAcceptsSortedExtensionKeysAndLargeSizes() {
        let text = "version \(LFSPointer.specification)\next-0-foo sha256:\(otherOID)\noid sha256:\(oid)\n"
            + "size 9223372036854775807\n"
        XCTAssertEqual(LFSPointer.parse(data(text))?.size, .max)
    }

    func testRefusesAnythingThatIsNotExactlyAVersionOnePointer() {
        let valid = "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize 3\n"
        let refused = [
            "",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize 3",
            valid.replacingOccurrences(of: "\n", with: "\r\n"),
            "version https://example.com/spec/v2\noid sha256:\(oid)\nsize 3\n",
            "oid sha256:\(oid)\nsize 3\n",
            "version \(LFSPointer.specification)\nsize 3\noid sha256:\(oid)\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\n",
            "version \(LFSPointer.specification)\nsize 3\n",
            "version \(LFSPointer.specification)\noid md5:\(oid)\nsize 3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid.uppercased())\nsize 3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid.dropLast())\nsize 3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize -3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize +3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize 99999999999999999999\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize 9223372036854775808\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize \n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nSize 3\nsize 3\n",
            "version \(LFSPointer.specification)\n oid sha256:\(oid)\nsize 3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\noid sha256:\(oid)\nsize 3\n",
            "version \(LFSPointer.specification)\noid sha256:\(oid)\nsize 3\n\n",
            valid + "zz " + String(repeating: "x", count: LFSPointer.maximumSize - valid.utf8.count - 4) + "\n",
        ]
        for text in refused {
            XCTAssertNil(LFSPointer.parse(data(text)), text.debugDescription)
        }
        XCTAssertEqual(refused.last?.utf8.count, LFSPointer.maximumSize)
        XCTAssertNil(LFSPointer.parse(Data([0xFF, 0x0A])), "Invalid UTF-8 is ordinary content")
        let padded = "version \(LFSPointer.specification)\nab \(String(repeating: "x", count: 800))\n"
            + "oid sha256:\(oid)\nsize 3\n"
        XCTAssertLessThan(padded.utf8.count, LFSPointer.maximumSize)
        XCTAssertNotNil(LFSPointer.parse(data(padded)), "A pointer just under the limit still parses")
    }

    func testPointerInitializerValidatesTheDigestAndSize() {
        XCTAssertNil(LFSPointer(oid: "abc", size: 1))
        XCTAssertNil(LFSPointer(oid: String(repeating: "g", count: 64), size: 1))
        XCTAssertNil(LFSPointer(oid: oid, size: -1))
        XCTAssertNotNil(LFSPointer(oid: oid, size: 0))
    }

    // MARK: Tool

    func testToolStatusRequiresGitLFSThreeOrLater() {
        XCTAssertEqual(
            LFSToolPolicy.status(terminationStatus: 0, output: "git-lfs/3.8.1 (GitHub; darwin arm64; go 1.27.3)\n"),
            .available(version: "3.8.1")
        )
        XCTAssertEqual(LFSToolPolicy.status(terminationStatus: 0, output: "git-lfs/3.0.0"), .available(version: "3.0.0"))
        XCTAssertEqual(
            LFSToolPolicy.status(terminationStatus: 0, output: "git-lfs/2.13.3 (GitHub; darwin amd64; go 1.16.2)"),
            .unsupported(version: "2.13.3")
        )
        XCTAssertEqual(
            LFSToolPolicy.status(terminationStatus: 1, output: "git: 'lfs' is not a git command. See 'git --help'."),
            .missing
        )
        for output in ["", "lfs 3.0", "git-lfs/", "git-lfs/three.0", "git-lfs/3", "git-lfs/x3.1"] {
            XCTAssertEqual(LFSToolPolicy.status(terminationStatus: 0, output: output), .unrecognized, output)
        }
        XCTAssertTrue(LFSToolStatus.available(version: "3.0").isAvailable)
        XCTAssertFalse(LFSToolStatus.unsupported(version: "2.0").isAvailable)
        XCTAssertFalse(LFSToolStatus.missing.isAvailable)
    }

    // MARK: Worktree

    func testClassifiesWhatTheWorktreeHoldsForEachTrackedPath() throws {
        let stored = try pointer(3)
        func state(_ worktree: LFSWorktreeObservation.Worktree, pointer: LFSPointer? = nil) -> LFSFileState? {
            LFSWorktreeClassifier.state(of: LFSWorktreeObservation(path: "a.bin", pointer: pointer ?? stored, worktree: worktree))
        }
        XCTAssertEqual(state(.file(size: 128, pointer: stored)), .notDownloaded)
        XCTAssertEqual(state(.file(size: 3, pointer: nil)), .downloaded)
        XCTAssertEqual(state(.file(size: 4, pointer: nil)), .modified)
        XCTAssertEqual(try state(.file(size: 128, pointer: pointer(9, oid: otherOID))), .modified)
        XCTAssertEqual(state(.missing), .missing)
        XCTAssertNil(LFSWorktreeClassifier.state(of: LFSWorktreeObservation(path: "raw.bin", pointer: nil, worktree: .missing)))
    }

    func testSummaryCountsOnlyPointersAndTheObjectsNotDownloaded() throws {
        let small = try pointer(1500)
        let large = try pointer(2_000_000, oid: otherOID)
        let summary = LFSWorktreeClassifier.summary(
            of: [
                LFSWorktreeObservation(path: "a.bin", pointer: small, worktree: .file(size: 130, pointer: small)),
                LFSWorktreeObservation(path: "b.bin", pointer: large, worktree: .file(size: 130, pointer: large)),
                LFSWorktreeObservation(path: "c.bin", pointer: small, worktree: .file(size: 1500, pointer: nil)),
                LFSWorktreeObservation(path: "raw.bin", pointer: nil, worktree: .file(size: 3, pointer: nil)),
            ],
            isTruncated: false
        )
        XCTAssertEqual(summary.pointerCount, 3)
        XCTAssertEqual(summary.notDownloadedPaths, ["a.bin", "b.bin"])
        XCTAssertEqual(summary.notDownloadedBytes, 2_001_500)
        XCTAssertFalse(summary.isTruncated)
        XCTAssertEqual(LFSWorktreeSummary.empty.pointerCount, 0)
        XCTAssertGreaterThan(LFSWorktreeClassifier.scanLimit, 0)
    }

    func testSummaryBytesSaturateInsteadOfOverflowing() throws {
        let huge = try pointer(.max)
        let observation = LFSWorktreeObservation(path: "a.bin", pointer: huge, worktree: .file(size: 130, pointer: huge))
        let summary = LFSWorktreeClassifier.summary(of: [observation, observation, observation], isTruncated: true)
        XCTAssertEqual(summary.notDownloadedBytes, .max)
        XCTAssertTrue(summary.isTruncated)
    }

    // MARK: Local store

    func testFindsTheLocalStoreAndTheObjectWithinIt() throws {
        XCTAssertEqual(LFSObjectStore.storageDirectory(commonDirectory: "/r/.git", configuredStorage: nil), "/r/.git/lfs")
        XCTAssertEqual(LFSObjectStore.storageDirectory(commonDirectory: "/r/.git", configuredStorage: "  "), "/r/.git/lfs")
        XCTAssertEqual(LFSObjectStore.storageDirectory(commonDirectory: "/r/.git", configuredStorage: "/srv/lfs"), "/srv/lfs")
        XCTAssertEqual(LFSObjectStore.storageDirectory(commonDirectory: "/r/.git", configuredStorage: "media"), "/r/.git/media")
        XCTAssertEqual(
            try LFSObjectStore.objectPath(for: pointer(), storageDirectory: "/r/.git/lfs/"),
            "/r/.git/lfs/objects/28/72/\(oid)"
        )
    }

    func testDecidesWhetherAStoredObjectCanStandInForItsPointer() throws {
        let stored = try pointer(10)
        XCTAssertEqual(LFSObjectStore.decision(for: stored, storedSize: nil), .missing)
        XCTAssertEqual(LFSObjectStore.decision(for: stored, storedSize: 9), .incomplete)
        XCTAssertEqual(LFSObjectStore.decision(for: stored, storedSize: 10), .verify)
        let limit = LFSObjectStore.previewByteLimit
        XCTAssertEqual(try LFSObjectStore.decision(for: pointer(limit), storedSize: limit), .verify)
        XCTAssertEqual(try LFSObjectStore.decision(for: pointer(limit + 1), storedSize: limit + 1), .tooLargeToPreview)
    }

    // MARK: Downloads

    func testDownloadPlanAnchorsAndEscapesEachPath() throws {
        let plan = try LFSDownloadPlan.make(.paths(["a.bin", "dir with space/it's.bin", "st*r?.bin", "b[1].bin", "back\\slash.bin", "a.bin"])).get()
        let patterns = ["/a.bin", "/dir with space/it's.bin", "/st\\*r\\?.bin", "/b\\[1\\].bin", "/back\\\\slash.bin"]
        XCTAssertEqual(plan.fetchArguments, ["lfs", "fetch", "--include=" + patterns.joined(separator: ",")])
        XCTAssertEqual(plan.checkoutArguments, ["lfs", "checkout", "--"] + patterns)
        XCTAssertEqual(plan.paths, ["a.bin", "dir with space/it's.bin", "st*r?.bin", "b[1].bin", "back\\slash.bin"])
        XCTAssertEqual(LFSDownloadPlan.pattern(for: " leading.bin"), "/ leading.bin")
    }

    func testDownloadAllNeedsNoPatterns() throws {
        let plan = try LFSDownloadPlan.make(.all).get()
        XCTAssertEqual(plan.fetchArguments, ["lfs", "fetch"])
        XCTAssertEqual(plan.checkoutArguments, ["lfs", "checkout"])
        XCTAssertNil(plan.paths)
    }

    func testDownloadPlanRefusesPathsGitLFSCannotName() {
        XCTAssertEqual(LFSDownloadPlan.make(.paths([])), .failure(.noPaths))
        for path in ["com,ma.bin", "new\nline.bin", "carriage\r.bin", "nul\0.bin", "trailing.bin ", "trailing.bin\t", "/abs.bin", ""] {
            XCTAssertEqual(LFSDownloadPlan.make(.paths(["ok.bin", path])), .failure(.inexpressiblePath(path)), path.debugDescription)
        }
        let many = (0 ... LFSDownloadPlan.maximumPathCount).map { "file\($0).bin" }
        XCTAssertEqual(LFSDownloadPlan.make(.paths(many)), .failure(.tooManyPaths(count: many.count)))
        let long = (0 ..< 300).map { "\($0)-" + String(repeating: "x", count: 250) }
        XCTAssertEqual(LFSDownloadPlan.make(.paths(long)), .failure(.tooManyPaths(count: 300)))
    }

    func testDownloadPlanIssuesExplainWhatToDoInstead() {
        XCTAssertEqual(LFSDownloadPlanIssue.noPaths.message, "Choose a file whose Git LFS content is not downloaded.")
        XCTAssertEqual(
            LFSDownloadPlanIssue.inexpressiblePath("a,b").message,
            "Git LFS cannot download “a,b” on its own because of the characters in its name. Use Download All instead."
        )
        XCTAssertEqual(
            LFSDownloadPlanIssue.tooManyPaths(count: 600).message,
            "600 files are too many to download one by one. Use Download All instead."
        )
    }

    // MARK: Progress

    func testParsesProgressLinesWhoseNamesHoldSpaces() throws {
        let event = try XCTUnwrap(LFSProgressEvent.parse(line: "download 2/5 1024/4096 dir with space/it's.bin"))
        XCTAssertEqual(event.direction, "download")
        XCTAssertEqual(event.completedFiles, 2)
        XCTAssertEqual(event.totalFiles, 5)
        XCTAssertEqual(event.completedBytes, 1024)
        XCTAssertEqual(event.totalBytes, 4096)
        XCTAssertEqual(event.name, "dir with space/it's.bin")
        XCTAssertEqual(event.fractionCompleted, 0.25)
        for line in ["", "download 1/1 1/1", " 1/1 1/1 a", "download 1 1/1 a", "download 1/1/1 1/1 a", "download x/1 1/1 a", "download 1/1 1/y a", "download -1/1 1/1 a", "download 1/1 1/-1 a"] {
            XCTAssertNil(LFSProgressEvent.parse(line: line), line)
        }
    }

    func testProgressFallsBackToFilesAndNeverExceedsCompletion() throws {
        XCTAssertEqual(try XCTUnwrap(LFSProgressEvent.parse(line: "download 1/4 0/0 a")).fractionCompleted, 0.25)
        XCTAssertEqual(try XCTUnwrap(LFSProgressEvent.parse(line: "download 0/0 0/0 a")).fractionCompleted, 0)
        XCTAssertEqual(try XCTUnwrap(LFSProgressEvent.parse(line: "download 9/4 0/0 a")).fractionCompleted, 1)
        XCTAssertEqual(try XCTUnwrap(LFSProgressEvent.parse(line: "download 1/1 9/4 a")).fractionCompleted, 1)
    }

    func testSplitsProgressTextIntoCompleteLinesAndARemainder() {
        let split = LFSProgressEvent.events(in: "download 1/2 1/4 a\nnoise\ndownload 2/2 4/4 b\ndownl")
        XCTAssertEqual(split.events.map(\.name), ["a", "b"])
        XCTAssertEqual(split.remainder, "downl")
        XCTAssertEqual(LFSProgressEvent.events(in: "").events, [])
        XCTAssertEqual(LFSProgressEvent.events(in: "").remainder, "")
    }

    // MARK: Presentation

    func testPlaceholdersNameTheSizeAndAbbreviatedDigest() throws {
        XCTAssertEqual(
            try LFSPresentation.placeholder(for: pointer(12_400_000)),
            "Git LFS object not downloaded — 12.4 MB (sha256 28720365…)"
        )
        XCTAssertEqual(
            try LFSPresentation.tooLargePlaceholder(for: pointer(2_100_000_000)),
            "Git LFS object too large to preview — 2.1 GB (sha256 28720365…)"
        )
        XCTAssertEqual(LFSPresentation.flowSkipReason, "Git LFS object not downloaded")
    }

    func testStatusTextExplainsMissingToolsAndObjectsNotDownloaded() {
        let one = LFSWorktreeSummary(pointerCount: 4, notDownloadedPaths: ["a.bin"], notDownloadedBytes: 12_400_000, isTruncated: false)
        let three = LFSWorktreeSummary(pointerCount: 4, notDownloadedPaths: ["a", "b", "c"], notDownloadedBytes: 4000, isTruncated: false)
        let truncated = LFSWorktreeSummary(pointerCount: 4, notDownloadedPaths: ["a"], notDownloadedBytes: 1, isTruncated: true)
        let downloaded = LFSWorktreeSummary(pointerCount: 4, notDownloadedPaths: [], notDownloadedBytes: 0, isTruncated: false)
        let available = LFSToolStatus.available(version: "3.8.1")
        XCTAssertEqual(LFSPresentation.statusText(summary: one, tool: available), "LFS: 1 file not downloaded (12.4 MB)")
        XCTAssertEqual(LFSPresentation.statusText(summary: three, tool: available), "LFS: 3 files not downloaded (4 KB)")
        XCTAssertEqual(LFSPresentation.statusText(summary: truncated, tool: available), "LFS: 1+ files not downloaded (1 byte+)")
        XCTAssertNil(LFSPresentation.statusText(summary: downloaded, tool: available))
        XCTAssertNil(LFSPresentation.statusText(summary: .empty, tool: .missing), "A repository without LFS needs no label")
        XCTAssertEqual(LFSPresentation.statusText(summary: downloaded, tool: .missing), "Uses Git LFS, but git-lfs is not installed")
        XCTAssertEqual(
            LFSPresentation.statusText(summary: one, tool: .unsupported(version: "2.13.3")),
            "Git LFS 2.13.3 is too old; GitX needs 3.0 or later"
        )
        XCTAssertEqual(LFSPresentation.statusText(summary: one, tool: .unrecognized), "Uses Git LFS, but git-lfs did not report its version")
    }

    func testByteCountsReadLikeTheFinder() {
        let expectations: [(Int64, String)] = [
            (-1, "Zero bytes"), (0, "Zero bytes"), (1, "1 byte"), (999, "999 bytes"), (1000, "1 KB"), (1499, "1 KB"),
            (999_499, "999 KB"), (999_500, "1.0 MB"), (12_400_000, "12.4 MB"), (999_949_999, "999.9 MB"),
            (999_950_000, "1.0 GB"), (2_100_000_000, "2.1 GB"), (3_000_000_000_000, "3.0 TB"), (.max, "9.2 EB"),
        ]
        for (bytes, text) in expectations {
            XCTAssertEqual(LFSPresentation.byteCount(bytes), text, "\(bytes)")
        }
    }
}
