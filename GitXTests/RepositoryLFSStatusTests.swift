import AppKit
import GitXCore
import XCTest

/// The passive Git LFS status scan behind the status bar (ADR 0014): local reads only, never a smudge.
@MainActor
// swift6-safety-justification: XCTest's nonisolated setup and teardown enter MainActor synchronously; every fixture access stays on main.
final class RepositoryLFSStatusTests: XCTestCase, @unchecked Sendable {
    private static let oid = "28720365c5e7476a011e4f43ac003ee5f16247a263b9d623aa85ed311d73bf39"
    private static let fiveByteOID = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    private var directory: URL!

    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        // swift6-safety-justification: App-hosted XCTest invokes setup on the main thread, where the repository fixture is MainActor-isolated.
        try MainActor.assumeIsolated { try prepareFixture() }
    }

    override nonisolated func tearDownWithError() throws {
        // swift6-safety-justification: App-hosted XCTest invokes teardown on the main thread, where the repository fixture is MainActor-isolated.
        MainActor.assumeIsolated { removeFixture() }
        try super.tearDownWithError()
    }

    private func prepareFixture() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
    }

    private func removeFixture() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    private func git(_ arguments: [String], input: Data? = nil) throws -> String {
        try GitXTestGitFixture.run(arguments, in: directory, standardInput: input).standardOutput
    }

    private static func pointer(oid: String = oid, size: Int64 = 12_400_000) -> String {
        "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(size)\n"
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A `git` that answers `git lfs version` itself and passes everything else to /usr/bin/git.
    private func gitWrapper(lfsVersion: String) throws -> (executable: String, lfsLog: URL) {
        let executable = directory.appendingPathComponent(".git/fake-git")
        let lfsLog = directory.appendingPathComponent(".git/lfs-invocations")
        let script = """
        #!/bin/sh
        if [ "$1" = lfs ]; then
          echo "$*" >> '\(lfsLog.path)'
          \(lfsVersion)
          exit $?
        fi
        exec /usr/bin/git "$@"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable.path, lfsLog)
    }

    private func scan(executable: String = "/usr/bin/git", knownTool: LFSToolStatus? = .available(version: "3.8.1")) -> RepositoryLFSStatusSnapshot? {
        RepositoryLFSStatusScan(executablePath: executable, workingDirectory: directory.path, knownTool: knownTool).run()
    }

    // MARK: Parsing

    func testIndexEntriesKeepOnlyStageZeroRegularFiles() {
        let records = [
            "100644 \(Self.oid) 0\ta.bin",
            "100755 \(Self.oid) 0\tscripts/run me.bin",
            "120000 \(Self.oid) 0\tlink.bin",
            "160000 \(Self.oid) 0\tsubmodule",
            "100644 \(Self.oid) 2\tconflicted.bin",
            "garbage",
            "100644 \(Self.oid)\tshort.bin",
        ]
        let data = Data(records.joined(separator: "\0").utf8) + Data([0])
        XCTAssertEqual(RepositoryLFSStatusScan.indexEntries(in: data).map(\.path), ["a.bin", "scripts/run me.bin"])
        XCTAssertEqual(RepositoryLFSStatusScan.indexEntries(in: Data()), [])
    }

    func testBatchOutputKeepsBlobPointersAndStopsAtATruncatedRecord() {
        let pointer = Self.pointer()
        let ordinary = "plain text\n"
        var data = Data("aaaa blob \(pointer.utf8.count)\n\(pointer)\n".utf8)
        data += Data("bbbb blob \(ordinary.utf8.count)\n\(ordinary)\n".utf8)
        data += Data("cccc tree \(pointer.utf8.count)\n\(pointer)\n".utf8)
        data += Data("dddd missing\n".utf8)
        data += Data("ffff blob \(pointer.utf8.count)\n\(pointer)\n".utf8)
        data += Data("eeee blob 9999\nshort".utf8)
        data += Data("gggg blob \(pointer.utf8.count)\n\(pointer)\n".utf8)
        let pointers = RepositoryLFSStatusScan.pointers(inBatchOutput: data)
        XCTAssertEqual(pointers.keys.sorted(), ["aaaa", "ffff"], "A missing object is skipped; a truncated record ends the parse")
        XCTAssertEqual(pointers["aaaa"]?.size, 12_400_000)
        XCTAssertEqual(RepositoryLFSStatusScan.pointers(inBatchOutput: Data("hhhh blob x\n".utf8)), [:])
        XCTAssertEqual(RepositoryLFSStatusScan.pointers(inBatchOutput: Data()), [:])
    }

    // MARK: Scan

    func testScanClassifiesEveryWorktreeStateOfTrackedPointers() throws {
        try write(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        try write("pointer.bin", Self.pointer())
        try write("assets/second pointer.bin", Self.pointer(size: 600))
        try write("downloaded.bin", Self.pointer(oid: Self.fiveByteOID, size: 5))
        try write("modified.bin", Self.pointer(oid: Self.fiveByteOID, size: 5))
        try write("deleted.bin", Self.pointer())
        try write("ordinary.bin", "not a pointer\n")
        try write("untracked-pointer.txt", Self.pointer())
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Track pointers"])
        try write("downloaded.bin", "hello")
        try write("modified.bin", "hello, world")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deleted.bin"))

        let snapshot = try XCTUnwrap(scan())
        XCTAssertEqual(snapshot.tool, .available(version: "3.8.1"), "A known available tool is not checked again")
        XCTAssertEqual(snapshot.summary.pointerCount, 5)
        XCTAssertEqual(snapshot.summary.notDownloadedPaths, ["assets/second pointer.bin", "pointer.bin"])
        XCTAssertEqual(snapshot.summary.notDownloadedBytes, 12_400_600)
        XCTAssertFalse(snapshot.summary.isTruncated)
        XCTAssertEqual(snapshot.statusText, "LFS: 2 files not downloaded (12.4 MB)")
    }

    func testScanChecksTheToolOnlyWhenTheCheckoutUsesGitLFS() throws {
        let unsupported = try gitWrapper(lfsVersion: "echo 'git-lfs/2.13.3 (GitHub; darwin arm64; go 1.16.2)'")
        try write("README", "no LFS here\n")
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Plain"])
        XCTAssertEqual(scan(executable: unsupported.executable, knownTool: nil), RepositoryLFSStatusSnapshot.none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.lfsLog.path), "A checkout without LFS paths never runs git-lfs")

        try write(".gitattributes", "*.bin filter=lfs\n")
        try write("model.bin", Self.pointer())
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "LFS"])
        let snapshot = try XCTUnwrap(scan(executable: unsupported.executable, knownTool: nil))
        XCTAssertEqual(snapshot.tool, .unsupported(version: "2.13.3"))
        XCTAssertEqual(snapshot.statusText, "Git LFS 2.13.3 is too old; Half Dark needs 3.0 or later")
        XCTAssertEqual(try String(contentsOf: unsupported.lfsLog, encoding: .utf8), "lfs version\n")

        let missing = try gitWrapper(lfsVersion: "echo \"git: 'lfs' is not a git command.\" >&2; exit 1")
        XCTAssertEqual(try XCTUnwrap(scan(executable: missing.executable, knownTool: .missing)).tool, .missing, "A missing tool is checked again")
        XCTAssertEqual(try XCTUnwrap(scan(executable: missing.executable, knownTool: .missing)).statusText, "Uses Git LFS, but git-lfs is not installed")

        let available = try gitWrapper(lfsVersion: "echo 'git-lfs/3.8.1 (GitHub; darwin arm64; go 1.25.1)'")
        XCTAssertEqual(try XCTUnwrap(scan(executable: available.executable, knownTool: nil)).tool, .available(version: "3.8.1"))
    }

    func testScanStopsAtTheScanLimitAndSaysSo() throws {
        let blob = try git(["hash-object", "-w", "--stdin"], input: Data(Self.pointer().utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        try write(".gitattributes", "*.bin filter=lfs\n")
        let count = LFSWorktreeClassifier.scanLimit + 1
        let entries = (0 ..< count).map { "100644 \(blob)\tdata/\(String(format: "%05d", $0)).bin" }.joined(separator: "\n") + "\n"
        try git(["update-index", "--index-info"], input: Data(entries.utf8))
        try write("data/00000.bin", Self.pointer())

        let snapshot = try XCTUnwrap(scan())
        XCTAssertTrue(snapshot.summary.isTruncated)
        XCTAssertEqual(snapshot.summary.pointerCount, LFSWorktreeClassifier.scanLimit)
        XCTAssertEqual(snapshot.summary.notDownloadedPaths, ["data/00000.bin"])
        XCTAssertEqual(snapshot.statusText, "LFS: 1+ files not downloaded (12.4 MB+)")
    }

    func testCancelledOrFailedScansReportNothing() throws {
        let cancelled = RepositoryLFSStatusScan(executablePath: "/usr/bin/git", workingDirectory: directory.path, knownTool: nil)
        cancelled.cancel()
        XCTAssertNil(cancelled.run())
        let notARepository = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSNotARepository-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepository) }
        XCTAssertNil(RepositoryLFSStatusScan(executablePath: "/usr/bin/git", workingDirectory: notARepository.path, knownTool: nil).run())
    }

    // MARK: Loader

    func testLoaderPublishesOnlyTheNewestChangedSnapshot() throws {
        try write(".gitattributes", "*.bin filter=lfs\n")
        try write("model.bin", Self.pointer())
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "LFS"])
        let repository = try GitXTestGitRepository(url: directory)
        var snapshots: [RepositoryLFSStatusSnapshot] = []
        var published = expectation(description: "the first snapshot")
        let loader = RepositoryLFSStatusLoader(repository: repository, gitExecutablePath: "/usr/bin/git") { snapshot in
            snapshots.append(snapshot)
            published.fulfill()
        }
        loader.refresh()
        loader.refresh()
        wait(for: [published], timeout: 15)
        XCTAssertEqual(snapshots.count, 1, "The superseded scan is discarded")
        XCTAssertEqual(snapshots.last?.summary.notDownloadedPaths, ["model.bin"])
        XCTAssertEqual(loader.snapshot, snapshots.last)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("model.bin"))
        published = expectation(description: "the changed snapshot")
        loader.refresh()
        wait(for: [published], timeout: 15)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.summary.notDownloadedPaths, [])
        XCTAssertEqual(snapshots.last?.summary.pointerCount, 1)

        loader.refresh()
        loader.cancel()
        let quiet = expectation(description: "a cancelled refresh publishes nothing")
        quiet.isInverted = true
        published = quiet
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(snapshots.count, 2)
    }

    // MARK: Status bar

    func testStatusBarShowsTheLFSLabelAndRoutesDetails() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        let split = NSView()
        content.addSubview(split)
        let controller = RepositoryStatusBarController(splitView: split, contentView: content, now: Date.init)
        controller.install(visible: true)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 29)
        var details: [RepositoryLFSStatusSnapshot] = []
        controller.lfsDetails = { details.append($0) }
        let summary = LFSWorktreeSummary(pointerCount: 2, notDownloadedPaths: ["a.bin"], notDownloadedBytes: 4000, isTruncated: false)
        let snapshot = RepositoryLFSStatusSnapshot(tool: .available(version: "3.8.1"), summary: summary)

        controller.updateLFS(snapshot)
        XCTAssertFalse(controller.view.lfsLabel.isHidden)
        XCTAssertEqual(controller.view.lfsLabel.stringValue, "LFS: 1 file not downloaded (4 KB)")
        XCTAssertEqual(controller.view.lfsLabel.accessibilityIdentifier(), "GitX.RepositoryStatusBar.LFS")
        XCTAssertFalse(controller.view.lfsDetailsButton.isHidden)
        controller.view.lfsDetailsButton.performClick(nil)
        XCTAssertEqual(details, [snapshot])

        controller.updateLFS(RepositoryLFSStatusSnapshot.none)
        XCTAssertTrue(controller.view.lfsLabel.isHidden)
        XCTAssertTrue(controller.view.lfsDetailsButton.isHidden)
        controller.invalidate()
    }

    func testGitLFSStatusBarDiagnosticScreenshot() throws {
        let view = RepositoryStatusBarView(frame: NSRect(x: 0, y: 0, width: 1040, height: 29))
        view.apply(local: RepositoryLocalStatusPresenter.present(
            RepositoryLocalStatusSnapshot(
                head: .branch(name: "main", unborn: false),
                ahead: 0,
                behind: 0,
                counts: RepositoryWorkingStateCounts(staged: 0, unstaged: 0, untracked: 0, conflicts: 0),
                operation: nil
            ),
            activityText: nil,
            isBusy: false
        ))
        let summary = LFSWorktreeSummary(pointerCount: 9, notDownloadedPaths: ["a", "b", "c"], notDownloadedBytes: 12_400_000, isTruncated: false)
        view.apply(lfs: RepositoryLFSStatusSnapshot(tool: .available(version: "3.8.1"), summary: summary).statusText)
        try attachScreenshot(of: view, named: "Git LFS - Repository Status Bar - Not Downloaded")
        view.apply(lfs: RepositoryLFSStatusSnapshot(tool: .missing, summary: summary).statusText)
        try attachScreenshot(of: view, named: "Git LFS - Repository Status Bar - Not Installed")
    }
}
