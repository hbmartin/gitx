import Darwin
import XCTest

@MainActor
final class StagingDiffPaneControllerTests: XCTestCase {
    // swift6-safety-justification: Immutable status fixtures and lock-protected command counts are shared only with the serial producer/writer queues.
    private final nonisolated class StatusRunner: NSObject, PBIndexRawOutputCommandRunning, @unchecked Sendable {
        let paths: [String]
        let rawPaths: [Data]
        let status: String
        let indexOutput: Data?
        let indexedImageSize: String?
        let diffOutput: String
        init(paths: [String], rawPaths: [Data]? = nil, status: String = "M", indexOutput: Data? = nil,
             indexedImageSize: String? = nil, diffOutput: String = "diff --git a/selected.txt b/selected.txt\n")
        {
            self.paths = paths; self.rawPaths = rawPaths ?? paths.map { Data($0.utf8) }; self.status = status; self.indexOutput = indexOutput
            self.indexedImageSize = indexedImageSize; self.diffOutput = diffOutput; super.init()
        }

        private let lock = NSLock()
        private var statusCommands = 0
        private var diffCommands = 0
        private var treeCommands = 0
        private var indexObject = String(repeating: "a", count: 40)
        private var treeObject = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        private var staged = false
        private var capturedArguments: [[String]] = []

        func changeIndex() {
            lock.lock(); indexObject = String(repeating: "b", count: 40); lock.unlock()
        }

        func changeTree() {
            lock.lock(); treeObject = String(repeating: "b", count: 40); lock.unlock()
        }

        func changeStaging() {
            lock.lock(); staged = true; lock.unlock()
        }

        var counts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return [statusCommands, diffCommands, treeCommands]
        }

        var rawArguments: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return capturedArguments
        }

        func rawOutput(withArguments arguments: [String], environment: [String: Any]?) throws -> Data {
            XCTAssertEqual(environment?["GIT_OPTIONAL_LOCKS"] as? String, "0")
            lock.lock(); statusCommands += 1; capturedArguments.append(arguments); let object = indexObject; let hasStaged = staged; lock.unlock()
            let selected: [Data]
            if let separator = arguments.firstIndex(of: "--") {
                let names = Set(arguments.suffix(from: separator + 1).map { Data($0.utf8) })
                selected = rawPaths.filter { names.contains($0) }
            } else {
                selected = rawPaths
            }
            func records(_ header: String, separated: Bool) -> Data {
                var result = Data()
                for path in selected {
                    result.append(Data(header.utf8)); result.append(separated ? 0 : 9)
                    result.append(path); result.append(0)
                }
                return result
            }
            if arguments.contains("diff-files") {
                return records(":100644 100644 \(object) \(String(repeating: "0", count: 40)) \(status)", separated: true)
            }
            if arguments.contains("ls-files") {
                return indexOutput ?? records("100644 \(object) 0", separated: false)
            }
            if arguments.contains("diff-index"), hasStaged {
                return records(":100644 100644 \(String(repeating: "a", count: 40)) \(object) M", separated: true)
            }
            return Data()
        }

        func output(withArguments arguments: [String], input _: String?, environment _: [String: Any]?) throws -> String {
            lock.lock(); defer { lock.unlock() }
            XCTAssertFalse(arguments.contains("-z"), "Status must use the runner's byte output")
            if arguments.first == "rev-parse" {
                treeCommands += 1
                return treeObject + "\n"
            }
            if arguments.first == "cat-file", let indexedImageSize {
                XCTAssertEqual(arguments, ["cat-file", "-s", treeObject])
                return indexedImageSize
            }
            diffCommands += 1
            return diffOutput
        }

        func data(withArguments _: [String], completion: @escaping (Data?, Error?) -> Void) {
            XCTFail("Revalidation must use the synchronous command boundary")
            completion(nil, nil)
        }
    }

    #if DEBUG
        func testImageReaderPreservesRegularSymlinksAndTracksChangedContent() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("target")
            let link = root.appendingPathComponent("image.png")
            try Data("first".utf8).write(to: file)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let first = try PBStagingImageReaderTestHarness.identity(url: link)
            XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: link, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), Data("first".utf8))
            try Data("other".utf8).write(to: file)
            XCTAssertNotEqual(try PBStagingImageReaderTestHarness.identity(url: link), first)
            let parentLink = root.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
            XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: parentLink.appendingPathComponent("image.png"), maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), Data("other".utf8))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: link, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {
                try? FileManager.default.removeItem(at: link)
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
            }))
        }

        func testImageReaderResolvesRelativeSymlinkComponentsAndCapturesTheirIdentity() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let directory = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let target = directory.appendingPathComponent("target.png")
            let link = root.appendingPathComponent("image.png")
            let bytes = Data("relative symlink image".utf8)
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "./nested/../nested/target.png")
            let first = try PBStagingImageReaderTestHarness.identity(url: link)
            XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: link, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), bytes)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nested/target.png")
            XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: link, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), bytes)
            XCTAssertNotEqual(try PBStagingImageReaderTestHarness.identity(url: link), first, "Changing the link target invalidates authority even if it resolves to the same image bytes")
        }

        func testImageReaderRejectsAncestorReplacementEvenWhenTheFileRemainsIdentical() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let directory = root.appendingPathComponent("images")
            let renamed = root.appendingPathComponent("moved-images")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = directory.appendingPathComponent("image.png")
            let bytes = Data("unchanged image bytes".utf8)
            try bytes.write(to: file)
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {
                do {
                    try FileManager.default.moveItem(at: directory, to: renamed)
                    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: renamed)
                } catch { XCTFail("Fixture ancestor replacement failed: \(error)") }
            })) { error in
                XCTAssertTrue(error.localizedDescription.contains("Image path changed"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Refusal is caused by changed path authority, not changed file contents")
        }

        func testImageReaderMaintainsContentIdentityUnderCachePressure() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.png")
            let bytes = Data("first cached image".utf8)
            try bytes.write(to: first)
            let identity = try PBStagingImageReaderTestHarness.identity(url: first)
            for number in 0 ..< 65 {
                let file = directory.appendingPathComponent("image-\(number).png")
                let contents = Data("distinct image \(number)".utf8)
                try contents.write(to: file)
                XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), contents)
            }
            XCTAssertEqual(try PBStagingImageReaderTestHarness.identity(url: first), identity, "A bounded cache may evict hashes but must preserve content identity")
            XCTAssertEqual(try PBStagingImageReaderTestHarness.read(url: first, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {}), bytes)
        }

        func testImageDefaultBudgetAcceptsSlowReadsAndStillHasAFiniteLimit() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("image".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try PBStagingImageReaderTestHarness.readDefault(url: file, elapsedDuringRead: 3), Data("image".utf8))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.readDefault(url: file, elapsedDuringRead: 31))
        }

        func testImageReaderRefusesDevicesFIFOsLimitsCancellationAndReplacement() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("image.png")
            let fifo = root.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            for target in [URL(fileURLWithPath: "/dev/zero"), URL(fileURLWithPath: "/dev/null"), fifo] {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                XCTAssertThrowsError(try PBStagingImageReaderTestHarness.identity(url: file))
                try FileManager.default.removeItem(at: file)
            }
            try Data("contents".utf8).write(to: file)
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 2, cancelled: false, timeout: 2, whileReading: {}))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 64, cancelled: true, timeout: 2, whileReading: {}))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 64, cancelled: false, timeout: 0, whileReading: {}))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.read(url: file, maximumBytes: 64, cancelled: false, timeout: 2, whileReading: {
                try? Data("replaced".utf8).write(to: file, options: .atomic)
            }))
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.identity(url: root.appendingPathComponent("missing")))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.identity(url: file))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let loop = root.appendingPathComponent("loop.png")
            try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.identity(url: loop))
        }

        func testIndexedImageReadsAreBounded() throws {
            let task = PBTask(launchPath: "/usr/bin/printf", arguments: ["normal"], inDirectory: nil)
            XCTAssertEqual(try PBStagingImageReaderTestHarness.readBlob(task: task, maximumBytes: 64), Data("normal".utf8))
            let large = PBTask(launchPath: "/usr/bin/printf", arguments: ["oversized"], inDirectory: nil)
            XCTAssertThrowsError(try PBStagingImageReaderTestHarness.readBlob(task: large, maximumBytes: 2))
        }
    #endif

    #if DEBUG
        private func snapshotFixture(_ body: (URL, LifetimeRepository, PBChangedFile) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("contents\n".utf8).write(to: directory.appendingPathComponent("selected.txt"))
            let file = PBChangedFile(path: "selected.txt")
            file.status = .MODIFIED; file.hasUnstagedChanges = true
            try await body(directory, LifetimeRepository(directory: directory, onDeinit: {}), file)
        }

        func testDiscardSnapshotRejectsSameSizedContentPermissionsIndexTreeAndStagingChanges() async throws {
            for change in 0 ..< 5 {
                try await snapshotFixture { directory, repository, file in
                    let runner = StatusRunner(paths: [file.path])
                    let url = directory.appendingPathComponent(file.path)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
                    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
                    do {
                        try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                            do {
                                switch change {
                                case 0:
                                    try Data("mutated!\n".utf8).write(to: url)
                                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                                case 1: try FileManager.default.setAttributes([.posixPermissions: permissions ^ 0o100], ofItemAtPath: url.path)
                                case 2: runner.changeIndex()
                                case 3: runner.changeTree()
                                default: runner.changeStaging()
                                }
                            } catch { XCTFail("Fixture change failed: \(error)") }
                        })
                        XCTFail("A changed discard snapshot was authorized: \(change)")
                    } catch { XCTAssertEqual((error as NSError).code, 8) }
                }
            }
        }

        func testDiscardSnapshotAcceptsBinaryContentsAndRejectsAChangedSymlinkTarget() async throws {
            try await snapshotFixture { directory, repository, file in
                let runner = StatusRunner(paths: [file.path])
                let url = directory.appendingPathComponent(file.path)
                try Data([0, 255, 1, 0]).write(to: url)
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: String(repeating: "x", count: 600))
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                        do {
                            try FileManager.default.removeItem(at: url)
                            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "new target")
                        } catch { XCTFail("Fixture change failed: \(error)") }
                    })
                    XCTFail("A replaced symlink was authorized")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotAcceptsDeletionButRejectsAReappearingFile() async throws {
            try await snapshotFixture { directory, repository, file in
                let runner = StatusRunner(paths: [file.path], status: "D")
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.removeItem(at: url)
                file.status = .DELETED
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file], beforeValidation: {
                        do { try Data("new contents\n".utf8).write(to: url) }
                        catch { XCTFail("Fixture change failed: \(error)") }
                    })
                    XCTFail("A reappearing file was authorized")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotRejectsMalformedMissingIndexEntriesAndUnsupportedFileKinds() async throws {
            for record in [Data("malformed\0".utf8), Data("invalid metadata\tselected.txt\0".utf8), Data()] {
                try await snapshotFixture { _, repository, file in
                    do {
                        try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path], indexOutput: record), files: [file])
                        XCTFail("Malformed or missing index entry was authorized")
                    } catch { XCTAssertEqual((error as NSError).code, 8) }
                }
            }
            try await snapshotFixture { directory, repository, file in
                let url = directory.appendingPathComponent(file.path)
                try FileManager.default.removeItem(at: url)
                XCTAssertEqual(mkfifo(url.path, 0o600), 0)
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file])
                    XCTFail("A FIFO cannot authorize a tracked-file discard")
                } catch { XCTAssertEqual((error as NSError).code, 8) }
            }
        }

        func testDiscardSnapshotSkipsUntrackedAndStagedOnlyRowsAndRequiresAWorkingDirectory() async throws {
            let repository = LifetimeRepository(onDeinit: {})
            let runner = StatusRunner(paths: ["selected.txt"])
            let file = PBChangedFile(path: "selected.txt")
            file.status = .MODIFIED; file.hasStagedChanges = true
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
            file.status = .NEW; file.hasUnstagedChanges = true
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
            XCTAssertEqual(runner.counts, [0, 0, 0])
            file.status = .MODIFIED; file.hasStagedChanges = false
            do {
                try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: [file])
                XCTFail("A missing worktree was authorized")
            } catch { XCTAssertEqual((error as NSError).code, 8) }
        }

        func testDiscardRefusesABlockingAncestorWithoutOverwritingIt() async throws {
            for blockerPath in ["blocked", "nested/blocked"] {
                try await snapshotFixture { directory, repository, _ in
                    let blocker = directory.appendingPathComponent(blockerPath)
                    try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("keep this ancestor".utf8).write(to: blocker)
                    let file = PBChangedFile(path: blockerPath + "/deleted.txt")
                    file.status = .DELETED; file.hasUnstagedChanges = true
                    do {
                        try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path], status: "D"), files: [file])
                        XCTFail("Discard cannot replace an uncaptured ancestor")
                    } catch {
                        XCTAssertEqual((error as NSError).code, 8)
                        XCTAssertTrue(error.localizedDescription.contains("“" + blockerPath + "”"), error.localizedDescription)
                        XCTAssertTrue(error.localizedDescription.contains("Move or remove"), error.localizedDescription)
                        let alert = NSAlert()
                        alert.messageText = "Index operation failed"
                        alert.informativeText = error.localizedDescription
                        alert.layout()
                        try attachScreenshot(of: alert.window, named: "Discard-Blocking-Parent-Refusal")
                    }
                    XCTAssertEqual(try Data(contentsOf: blocker), Data("keep this ancestor".utf8))
                }
            }
        }

        func testClosedPaneCancelsConfirmedDiscardBeforeCheckingEligibility() async throws {
            try await snapshotFixture { _, repository, file in
                var checkedEligibility = false
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareCloseAndValidate(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file], eligibility: {
                        checkedEligibility = true
                        return true
                    })
                    XCTFail("A closed pane cannot authorize its confirmed discard")
                } catch {
                    XCTAssertEqual((error as NSError).code, 8)
                    XCTAssertTrue(error.localizedDescription.contains("cancelled"))
                }
                XCTAssertFalse(checkedEligibility, "Closing the pane invalidates lifetime before calling back into its controller")
            }
        }

        func testDiscardCaptureHasOneBudgetAndChecksCancellationWhileHashing() async throws {
            try await snapshotFixture { _, repository, file in
                for (timeout, checks) in [(0.0, -1), (30.0, 0), (30.0, 9)] {
                    do {
                        try await PBStagingDiffRevalidationTestHarness.capture(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file], timeout: timeout, cancelAfterChecks: checks)
                        XCTFail("Expired or cancelled discard capture must fail")
                    } catch {
                        XCTAssertEqual((error as NSError).code, 8)
                        XCTAssertTrue(error.localizedDescription.contains("cancelled") || error.localizedDescription.contains("time limit"))
                    }
                }
            }
        }

        func testDiscardCaptureBoundsSelectedPathBatchesAndPreservesRawFallback() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = LifetimeRepository(directory: directory, onDeinit: {})
            let paths = (0 ..< 200).map { "\(String(repeating: "p", count: 170))-\($0).txt" }
            let files = try paths.map { path in
                try Data("selected\n".utf8).write(to: directory.appendingPathComponent(path))
                let file = PBChangedFile(path: path); file.status = .MODIFIED; file.hasUnstagedChanges = true
                return file
            }
            let runner = StatusRunner(paths: paths)
            try await PBStagingDiffRevalidationTestHarness.capture(repository: repository, runner: runner, files: files, timeout: 30, cancelAfterChecks: -1)
            let calls = runner.rawArguments
            XCTAssertEqual(calls.count, 6, "Three queries each use two bounded batches")
            for command in ["diff-index", "diff-files", "ls-files"] {
                let batches = calls.filter { $0.contains(command) }.map { arguments -> [String] in
                    guard let separator = arguments.firstIndex(of: "--") else { XCTFail("UTF-8 selection must narrow each query"); return [] }
                    return Array(arguments.suffix(from: separator + 1))
                }
                XCTAssertEqual(batches.flatMap { $0 }, paths)
                XCTAssertTrue(batches.allSatisfy { $0.reduce(0) { $0 + $1.utf8.count + 1 } <= 32 * 1024 })
            }
            let rawPath = Data([0xFF]) + Data("-deleted.txt".utf8)
            let rawFile = PBChangedFile(path: "unrepresentable-deleted.txt", rawPath: rawPath); rawFile.status = .DELETED; rawFile.hasUnstagedChanges = true
            let rawRunner = StatusRunner(paths: [], rawPaths: [rawPath], status: "D")
            try await PBStagingDiffRevalidationTestHarness.capture(repository: repository, runner: rawRunner, files: [rawFile], timeout: 30, cancelAfterChecks: -1)
            XCTAssertEqual(rawRunner.rawArguments.count, 3)
            XCTAssertTrue(rawRunner.rawArguments.allSatisfy { !$0.contains("--") }, "Non-UTF-8 names retain whole-index byte output")
        }

        func testDiscardCaptureRefusesASubmoduleWithASpecificExplanation() async throws {
            try await snapshotFixture { _, repository, file in
                let record = Data("160000 \(String(repeating: "a", count: 40)) 0\tselected.txt\0".utf8)
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path], indexOutput: record), files: [file])
                    XCTFail("Submodule discard requires a separate operation")
                } catch { XCTAssertTrue(error.localizedDescription.contains("submodule")) }
            }
        }

        func testDiscardSnapshotReportsAnInvalidWorkingDirectory() async throws {
            try await snapshotFixture { directory, _, file in
                let repository = LifetimeRepository(directory: directory.appendingPathComponent(file.path), onDeinit: {})
                do {
                    try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: StatusRunner(paths: [file.path]), files: [file])
                    XCTFail("A regular file cannot be the discard working directory")
                } catch {
                    XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                    XCTAssertEqual((error as NSError).code, Int(ENOTDIR))
                }
            }
        }

        func testDiscardRevalidationUsesInjectedByteRunnerAndBatchesStatusFor300Files() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let paths = (0 ..< 300).map { "selected-\($0).txt" }
            for path in paths {
                try Data("contents\n".utf8).write(to: directory.appendingPathComponent(path))
            }
            let repository = LifetimeRepository(directory: directory, onDeinit: {})
            let runner = StatusRunner(paths: paths)
            let files = (0 ..< 300).map { index in
                let file = PBChangedFile(path: "selected-\(index).txt")
                file.status = .MODIFIED
                file.hasUnstagedChanges = true
                return file
            }
            try await PBStagingDiffRevalidationTestHarness.prepareAndValidate(repository: repository, runner: runner, files: files)
            XCTAssertEqual(runner.counts, [6, 0, 2], "Whole-file authorization uses shared byte queries and never decodes a text diff")
        }
    #endif

    // swift6-safety-justification: The repository crosses only into the serial producer queue,
    // and its immutable deinit callback is safe to invoke from whichever queue releases it.
    private final nonisolated class LifetimeRepository: PBGitRepository, @unchecked Sendable {
        private let onDeinit: @Sendable () -> Void
        private let directory: URL?

        init(directory: URL? = nil, onDeinit: @escaping @Sendable () -> Void) {
            self.directory = directory
            self.onDeinit = onDeinit
            super.init()
        }

        override func workingDirectoryURL() -> URL? {
            directory
        }

        override func revisionExists(_ spec: String) -> Bool {
            true
        }

        deinit {
            onDeinit()
        }
    }

    // swift6-safety-justification: XCTest expectations are only fulfilled, and the semaphore
    // synchronizes the sole cross-queue state transition controlled by this test.
    private final nonisolated class BlockingIndexCommandRunner: NSObject, PBIndexCommandRunning, @unchecked Sendable {
        private let producerStarted: XCTestExpectation
        private let producerFinished: XCTestExpectation
        private let parentResolved: XCTestExpectation
        private let gate = DispatchSemaphore(value: 0)

        init(producerStarted: XCTestExpectation, producerFinished: XCTestExpectation, parentResolved: XCTestExpectation) {
            self.producerStarted = producerStarted
            self.producerFinished = producerFinished
            self.parentResolved = parentResolved
            super.init()
        }

        func output(
            withArguments arguments: [String],
            input _: String?,
            environment _: [String: Any]?
        ) throws -> String {
            if arguments.first == "rev-parse" {
                XCTAssertEqual(arguments, ["rev-parse", "--verify", "HEAD^{tree}"])
                parentResolved.fulfill()
                return "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
            }
            producerStarted.fulfill()
            gate.wait()
            producerFinished.fulfill()
            return "diff --git a/queued.txt b/queued.txt\n"
        }

        func data(
            withArguments _: [String],
            completion: @escaping (Data?, Error?) -> Void
        ) {
            XCTFail("queued staging-diff production must not use the asynchronous data path")
            completion(nil, nil)
        }

        func releaseProduction() {
            gate.signal()
        }
    }

    func testDiffPaneOwnsTheRepositoryWithoutACycle() {
        weak var weakRepository: PBGitRepository?
        var pane: PBStagingDiffPaneController?
        autoreleasepool {
            var repository: PBGitRepository? = PBGitRepository()
            weakRepository = repository
            pane = PBStagingDiffPaneController(repository: repository!)
            repository = nil
        }
        XCTAssertNotNil(pane)
        XCTAssertNotNil(
            weakRepository,
            "diff production runs on a background queue after the pane may be torn down and reaches "
                + "the repository through unowned services, so the pane must keep the repository alive"
        )

        autoreleasepool {
            pane = nil
        }
        XCTAssertNil(weakRepository, "releasing the pane must release the repository without a retain cycle")
    }

    func testUntrackedDiffWithoutAWorkingDirectoryShowsTheFailure() {
        let repository = PBGitRepository()
        let pane = PBStagingDiffPaneController(repository: repository)
        let file = PBChangedFile(path: "untracked.txt")
        file.status = .NEW
        file.hasUnstagedChanges = true
        pane.renderRequests([PBStagingDiffRequest(file: file, staged: false)])

        let expected = "The repository has no working directory."
        let deadline = Date().addingTimeInterval(2)
        while !pane.contentView.textView.string.contains(expected), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(pane.contentView.textView.string.contains(expected))
        XCTAssertTrue(pane.contentView.textView.string.contains("untracked.txt"))
    }

    private func waitForRenderedText(_ text: String, in pane: PBStagingDiffPaneController) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !pane.contentView.textView.string.contains(text), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        return pane.contentView.textView.string.contains(text)
    }

    func testUnsupportedUntrackedObjectShowsAReadOnlyFailureWithoutReadingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "untracked-pipe.txt"
        let fifo = directory.appendingPathComponent(path)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let repository = LifetimeRepository(directory: directory, onDeinit: {})
        let pane = PBStagingDiffPaneController(repository: repository, diffRunner: StatusRunner(paths: [path]))
        defer { pane.renderRequests([]) }
        let file = PBChangedFile(path: path)
        file.status = .NEW; file.hasUnstagedChanges = true
        pane.renderRequests([PBStagingDiffRequest(file: file, staged: false)])
        XCTAssertTrue(waitForRenderedText("Diff unavailable — " + path, in: pane))
        XCTAssertTrue(pane.contentView.textView.string.contains("not a regular file or symbolic link"))
        XCTAssertFalse(pane.contentView.textView.string.contains("Stage hunk"))
        XCTAssertFalse(pane.contentView.textView.string.contains("Discard hunk"))
        var metadata = stat()
        XCTAssertEqual(lstat(fifo.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO, "Preview refusal must leave the unsupported object intact")
    }

    func testInvalidIndexedImageSizeKeepsTheDiffAndDisablesItsActions() throws {
        let path = "indexed-preview.png"
        let diff = """
        diff --git a/indexed-preview.png b/indexed-preview.png
        --- a/indexed-preview.png
        +++ b/indexed-preview.png
        @@ -1 +1 @@
        -previous image
        +selected image

        """
        for size in [String(64 * 1024 * 1024 + 1), "invalid size"] {
            let repository = LifetimeRepository(onDeinit: {})
            let runner = StatusRunner(paths: [path], indexedImageSize: size, diffOutput: diff)
            let pane = PBStagingDiffPaneController(repository: repository, diffRunner: runner)
            defer { pane.renderRequests([]) }
            let file = PBChangedFile(path: path)
            file.status = .MODIFIED; file.hasStagedChanges = true
            pane.renderRequests([PBStagingDiffRequest(file: file, staged: true)])
            XCTAssertTrue(waitForRenderedText("Actions unavailable — " + path, in: pane))
            let sections = try XCTUnwrap(pane.contentView.value(forKey: "currentDiffSections") as? [[String: Any]])
            let section = try XCTUnwrap(sections.first)
            XCTAssertEqual(section[PBNativeSectionTextKey] as? String, diff, "Unavailable image identity must preserve the selected Git diff")
            XCTAssertEqual(section[PBNativeSectionStagingChromeKey] as? Bool, false)
            XCTAssertTrue((section[PBNativeSectionActionContextKey] as? [String: Any])?.isEmpty == true)
            XCTAssertFalse(pane.contentView.textView.string.contains("Unstage hunk"))
            XCTAssertFalse(pane.contentView.textView.string.contains("Discard hunk"))
        }
    }

    func testQueuedProductionRetainsRepositoryAfterPaneTeardownAndCompletes() async throws {
        let producerStarted = expectation(description: "queued producer started")
        let producerFinished = expectation(description: "queued producer finished")
        let parentResolved = expectation(description: "queued producer resolves its parent through the command boundary")
        let repositoryReleased = expectation(description: "repository released after queued production")
        let runner = BlockingIndexCommandRunner(
            producerStarted: producerStarted,
            producerFinished: producerFinished,
            parentResolved: parentResolved
        )
        weak var weakRepository: PBGitRepository?
        var repository: LifetimeRepository? = LifetimeRepository {
            repositoryReleased.fulfill()
        }
        weakRepository = repository
        var pane: PBStagingDiffPaneController?
        do {
            let initialRepository = try XCTUnwrap(repository)
            pane = PBStagingDiffPaneController(
                repository: initialRepository,
                diffRunner: runner
            )
        }
        let file = PBChangedFile(path: "queued.txt")
        file.status = .MODIFIED
        file.hasUnstagedChanges = true

        pane?.renderRequests([PBStagingDiffRequest(file: file, staged: false)])
        await fulfillment(of: [producerStarted], timeout: 2)

        repository = nil
        pane = nil
        XCTAssertNotNil(
            weakRepository,
            "the queued production closure must keep its repository alive after pane teardown"
        )

        runner.releaseProduction()
        await fulfillment(of: [producerFinished, parentResolved, repositoryReleased], timeout: 2)
        XCTAssertNil(weakRepository)
    }
}
