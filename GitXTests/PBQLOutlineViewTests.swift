import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PBQLOutlineViewTests: XCTestCase {
    // swift6-safety-justification: This immutable test double only replaces cleanup with a deterministic error.
    private final class CleanupFailingFileManager: FileManager, @unchecked Sendable {
        override func removeItem(at URL: URL) throws {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "simulated staging cleanup failure"]
            )
        }
    }

    private final class GitFixture {
        let directory: URL
        let repository: PBGitRepository
        let revision: String
        private var retainedRoots: [PBGitTree] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXQuickLookCharacterization-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Self.runGit(["init", "--quiet", "--initial-branch=main"], in: directory)
            try Self.runGit(["config", "user.name", "GitX Tests"], in: directory)
            try Self.runGit(["config", "user.email", "gitx-tests@example.invalid"], in: directory)
            try Data([0x00, 0x7F, 0xFF]).write(to: directory.appendingPathComponent("binary.dat"))
            let nested = directory.appendingPathComponent("Documentation/Café.txt")
            try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("promised directory contents\n".utf8).write(to: nested)
            try Self.runGit(["add", "--all"], in: directory)
            try Self.runGit(["commit", "--quiet", "-m", "Quick Look fixture"], in: directory)
            revision = try Self.runGit(["rev-parse", "HEAD"], in: directory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            repository = try PBGitRepository(url: directory)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func tree(path: String, leaf: Bool) -> PBGitTree {
            let root = PBGitTree()
            root.path = ""
            root.leaf = false
            root.sha = revision
            root.repository = repository
            let tree = PBGitTree()
            tree.path = path
            tree.leaf = leaf
            tree.sha = revision
            tree.repository = repository
            tree.parent = root
            retainedRoots.append(root)
            return tree
        }

        func write(_ data: Data, to relativePath: String) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        @discardableResult
        func commit(_ message: String) throws -> String {
            try Self.runGit(["add", "--all"], in: directory)
            try Self.runGit(["commit", "--quiet", "-m", message], in: directory)
            return try Self.runGit(["rev-parse", "HEAD"], in: directory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func addSubmoduleEntry(path: String) throws -> String {
            try Self.runGit(["update-index", "--add", "--cacheinfo", "160000,\(revision),\(path)"], in: directory)
            try Self.runGit(["commit", "--quiet", "-m", "Add gitlink"], in: directory)
            return try Self.runGit(["rev-parse", "HEAD"], in: directory)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @discardableResult
        private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = directory
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                throw NSError(
                    domain: "PBQLOutlineViewTests.GitFixture",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)]
                )
            }
            return String(decoding: outputData, as: UTF8.self)
        }
    }

    // swift6-safety-justification: The lock protects every read and write of the captured asynchronous error.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func store(_ error: Error?) {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }

    // swift6-safety-justification: The lock protects every read and write of the captured asynchronous value.
    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Bool?

        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func store(_ value: Bool) {
            lock.lock()
            storedValue = value
            lock.unlock()
        }
    }

    // swift6-safety-justification: The immutable context transfers AppKit references to one serial test operation and keeps them alive through completion.
    private final class PromiseWriteContext: @unchecked Sendable {
        let outline: PBQLOutlineView
        let provider: NSFilePromiseProvider
        let destination: URL

        init(outline: PBQLOutlineView, provider: NSFilePromiseProvider, destination: URL) {
            self.outline = outline
            self.provider = provider
            self.destination = destination
        }
    }

    func testFileAndDirectoryItemsProduceTypedProvidersWithBasenames() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let file = tree(path: "Sources/Café.swift", leaf: true)
        let extensionlessFile = tree(path: "LICENSE", leaf: true)
        let directory = tree(path: "Documentation", leaf: false)

        let fileProvider = try provider(for: file, in: outline)
        let extensionlessProvider = try provider(for: extensionlessFile, in: outline)
        let directoryProvider = try provider(for: directory, in: outline)

        XCTAssertEqual(fileProvider.fileType, UTType.swiftSource.identifier)
        XCTAssertEqual(extensionlessProvider.fileType, UTType.data.identifier)
        XCTAssertEqual(directoryProvider.fileType, UTType.directory.identifier)
        XCTAssertEqual(outline.filePromiseProvider(fileProvider, fileNameForType: fileProvider.fileType), "Café.swift")
        XCTAssertEqual(
            outline.filePromiseProvider(directoryProvider, fileNameForType: directoryProvider.fileType),
            "Documentation"
        )
        XCTAssertFalse(fileProvider === directoryProvider)
    }

    func testRealCommittedRootFilePromisePreservesBinaryContents() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: fixture.tree(path: "binary.dat", leaf: true), in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("binary.dat")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
    }

    func testRealCommittedDirectoryPromisePreservesNestedContents() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: fixture.tree(path: "Documentation", leaf: false), in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
    }

    func testCommittedDirectoryExportMapsRepeatedBinaryBlobsToTheirPaths() throws {
        let fixture = try GitFixture()
        let binary = Data([0x00, 0x7F, 0xFF, 0x0A])
        try fixture.write(binary, to: "Documentation/Alpha.dat")
        try fixture.write(binary, to: "Documentation/Guides/Beta.dat")
        let revision = try fixture.commit("Add repeated binary blobs")
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .committedDirectory(
                repository: repositoryDescriptor(for: fixture),
                revision: revision,
                path: "Documentation"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Alpha.dat")), binary)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Guides/Beta.dat")), binary)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
    }

    func testCommittedDirectoryExportPreservesExecutableAndSymbolicLinkModes() throws {
        let fixture = try GitFixture()
        let executable = fixture.directory.appendingPathComponent("Documentation/Run.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.directory.appendingPathComponent("Documentation/Run Link").path,
            withDestinationPath: "Run.sh"
        )
        let revision = try fixture.commit("Add executable and symbolic link")
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .committedDirectory(
                repository: repositoryDescriptor(for: fixture),
                revision: revision,
                path: "Documentation"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("Run.sh").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o755)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destination.appendingPathComponent("Run Link").path
            ),
            "Run.sh"
        )
    }

    func testBatchBlobWriterAcceptsHeadersAndBinaryBodiesSplitAtEveryByte() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let identifier = String(repeating: "a", count: 40)
        let output = parent.appendingPathComponent("binary.dat")
        let writer = GitBatchBlobWriter(
            targets: [.init(mode: "100644", objectIdentifier: identifier, path: "binary.dat", outputURL: output)],
            fileManager: .default
        )
        let binary = Data([0x00, 0x0A, 0xFF, 0x7F])
        var response = Data("\(identifier) blob \(binary.count)\n".utf8)
        response.append(binary)
        response.append(0x0A)

        for byte in response {
            writer.consume(Data([byte]))
        }

        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: output), binary)
    }

    func testBatchBlobWriterRejectsMissingMismatchedAndTruncatedObjects() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let identifier = String(repeating: "a", count: 40)
        let target = GitBatchBlobWriter.Target(
            mode: "100644",
            objectIdentifier: identifier,
            path: "missing.txt",
            outputURL: parent.appendingPathComponent("missing.txt")
        )
        for response in [
            Data("\(identifier) missing\n".utf8),
            Data("\(String(repeating: "b", count: 40)) blob 0\n\n".utf8),
            Data("\(identifier) blob 3\nab".utf8),
        ] {
            let writer = GitBatchBlobWriter(targets: [target], fileManager: .default)
            writer.consume(response)
            XCTAssertThrowsError(try writer.finish()) { error in
                XCTAssertTrue(error.localizedDescription.contains("invalid blob data"))
            }
            try? FileManager.default.removeItem(at: target.outputURL)
        }
    }

    func testBatchBlobWriterRejectsUnusableSymbolicLinkTargets() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let identifier = String(repeating: "a", count: 40)
        let output = parent.appendingPathComponent("Link")
        let target = GitBatchBlobWriter.Target(
            mode: "120000",
            objectIdentifier: identifier,
            path: "Link",
            outputURL: output
        )
        for payload in [Data(), Data([0]), Data([0xFF]), Data(repeating: 0x61, count: 4097)] {
            let writer = GitBatchBlobWriter(targets: [target], fileManager: .default)
            var response = Data("\(identifier) blob \(payload.count)\n".utf8)
            response.append(payload)
            response.append(0x0A)
            writer.consume(response)

            XCTAssertThrowsError(try writer.finish()) { error in
                XCTAssertTrue(error.localizedDescription.contains("invalid symbolic link"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCommittedDirectoryExportUsesOneBatchProcess() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("second file\n".utf8), to: "Documentation/Second.txt")
        let revision = try fixture.commit("Add a second file")
        let log = fixture.directory.appendingPathComponent("git-calls.txt")
        let script = fixture.directory.appendingPathComponent("recording-git.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >>'\(log.path)'\nexec /usr/bin/git \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .committedDirectory(repository: repository, revision: revision, path: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        try QuickLookFilePromiseExporter().export(
            descriptor,
            to: parent.appendingPathComponent("Documentation", isDirectory: true)
        )

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0.contains("cat-file --batch") }.count, 1)
        XCTAssertFalse(calls.contains { $0.contains("cat-file blob") })
    }

    func testMalformedBatchResponseRemovesPromisedDirectoryAndStaging() throws {
        let fixture = try GitFixture()
        let identifier = String(repeating: "a", count: 40)
        let script = fixture.directory.appendingPathComponent("malformed-batch-git.sh")
        try """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in
            ls-tree) printf '100644 blob \(identifier)\\tDocumentation/Test.txt\\0'; exit 0 ;;
            --batch) printf '\(identifier) blob 5\\nbad\\n'; exit 0 ;;
          esac
        done
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .committedDirectory(repository: repository, revision: fixture.revision, path: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testPromiseQueueIsDedicatedSerialAndUserInitiated() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let first = try provider(for: tree(path: "one.txt", leaf: true), in: outline)
        let second = try provider(for: tree(path: "two.txt", leaf: true), in: outline)

        let firstQueue = outline.operationQueue(for: first)
        XCTAssertTrue(firstQueue === outline.operationQueue(for: second))
        XCTAssertEqual(firstQueue.maxConcurrentOperationCount, 1)
        XCTAssertEqual(firstQueue.qualityOfService, .userInitiated)
    }

    func testPromiseQueuePerformsExportOffMainThread() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = fixture.tree(path: "binary.dat", leaf: true)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let context = PromiseWriteContext(
            outline: outline,
            provider: provider,
            destination: parent.appendingPathComponent("binary.dat")
        )
        let completed = expectation(description: "The file promise completed")
        let result = ErrorBox()
        let callbackThread = BoolBox()

        outline.operationQueue(for: provider).addOperation {
            callbackThread.store(Thread.isMainThread)
            context.outline.filePromiseProvider(context.provider, writePromiseTo: context.destination) { error in
                result.store(error)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertNil(result.error)
        XCTAssertEqual(callbackThread.value, false)
    }

    func testFilePromiseWritesToExactDestinationAndRemovesStagingDirectory() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = fixture.tree(path: "binary.dat", leaf: true)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("AppKit-selected-name.txt")

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [destination.lastPathComponent])
    }

    func testSuccessfulExportSurvivesStagingCleanupFailure() throws {
        let fixture = try GitFixture()
        let descriptor = QuickLookExportDescriptor(
            fileName: "binary.dat",
            isDirectory: false,
            source: .committedFile(
                repository: repositoryDescriptor(for: fixture),
                revision: fixture.revision,
                path: "binary.dat"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("binary.dat")

        XCTAssertNoThrow(
            try QuickLookFilePromiseExporter(fileManager: CleanupFailingFileManager())
                .export(descriptor, to: destination)
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .contains { $0.hasPrefix(".gitx-file-promise-") }
        )
    }

    func testDirectoryPromiseMovesExportedTreeToExactDestination() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = fixture.tree(path: "Documentation", leaf: false)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Dropped Folder", isDirectory: true)

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertNil(error)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [destination.lastPathComponent])
    }

    func testMissingExportReportsErrorAndCleansStagingDirectory() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = fixture.tree(path: "missing.txt", leaf: true)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("missing.txt")

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertTrue(error?.localizedDescription.contains("missing.txt") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testRejectsItemsThatAreNotTreeNodes() {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))

        XCTAssertNil(outline.outlineView(outline, pasteboardWriterForItem: NSObject()))
        XCTAssertEqual(NSStringFromClass(type(of: outline)), "PBQLOutlineView")
    }

    func testMalformedProviderUsesFallbackNameAndReportsError() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertEqual(outline.filePromiseProvider(provider, fileNameForType: provider.fileType), "GitX Export")
        let error = write(provider: provider, with: outline, to: parent.appendingPathComponent("invalid")) as NSError?

        XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error?.code, NSFileWriteUnknownError)
    }

    func testDescriptorReportsMissingNameAndRevisionWithoutRetainingTreeState() throws {
        let unnamedDescriptor = QuickLookExportDescriptor.make(tree: tree(path: "", leaf: true))
        XCTAssertEqual(unnamedDescriptor.fileName, "GitX Export")
        guard case let .unavailable(unnamedMessage) = unnamedDescriptor.source else {
            return XCTFail("An unnamed tree should produce an unavailable export")
        }
        XCTAssertTrue(unnamedMessage.contains("name"))

        let fixture = try GitFixture()
        let revisionlessTree = fixture.tree(path: "binary.dat", leaf: true)
        revisionlessTree.sha = ""
        let revisionlessDescriptor = QuickLookExportDescriptor.make(tree: revisionlessTree)
        guard case let .unavailable(revisionMessage) = revisionlessDescriptor.source else {
            return XCTFail("A revisionless tree should produce an unavailable export")
        }
        XCTAssertTrue(revisionMessage.contains("revision"))
    }

    func testNestedCommittedFileUsesExactDestinationWithoutRecreatingRepositoryFolders() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: fixture.tree(path: "Documentation/Café.txt", leaf: true), in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Renamed.txt")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("promised directory contents\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Renamed.txt"])
    }

    func testCommittedPromiseRetainsRevisionAndPathsAfterTreeReleaseAndNewCommit() throws {
        let fixture = try GitFixture()
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        weak var releasedTree: PBGitTree?
        let provider: NSFilePromiseProvider
        do {
            let tree = fixture.tree(path: "binary.dat", leaf: true)
            releasedTree = tree
            provider = try self.provider(for: tree, in: outline)
        }
        XCTAssertNil(releasedTree)
        try fixture.write(Data("new revision".utf8), to: "binary.dat")
        try fixture.commit("Replace binary")
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("binary.dat")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
    }

    func testWorkingFilePromiseUsesFilesystemContents() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("working contents\n".utf8), to: "Documentation/Café.txt")
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingFile = try XCTUnwrap(findTree(path: "Documentation/Café.txt", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingFile, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("working.txt")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("working contents\n".utf8))
    }

    func testWorkingFilePromiseFallsBackToCapturedIndexPathWhenCheckoutFileDisappears() throws {
        let fixture = try GitFixture()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("binary.dat"))
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingFile = try XCTUnwrap(findTree(path: "binary.dat", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingFile, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("restored.dat")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
    }

    func testWorkingDirectoryPromiseCopiesCapturedDescendants() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("working contents\n".utf8), to: "Documentation/Café.txt")
        try fixture.write(Data("untracked\n".utf8), to: "Documentation/New.txt")
        try fixture.write(Data("nested\n".utf8), to: "Documentation/Guides/Nested.txt")
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Café.txt")), Data("working contents\n".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("New.txt")), Data("untracked\n".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Guides/Nested.txt")),
            Data("nested\n".utf8)
        )
    }

    func testCommittedSubmodulePromiseReportsFailureWithoutDestination() throws {
        let fixture = try GitFixture()
        let revision = try fixture.addSubmoduleEntry(path: "Vendor")
        let descriptor = QuickLookExportDescriptor(
            fileName: "Vendor",
            isDirectory: true,
            source: .committedDirectory(
                repository: repositoryDescriptor(for: fixture),
                revision: revision,
                path: "Vendor"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Vendor", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("submodule"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testMissingCommittedDirectoryReportsFailureWithoutPartialDestination() throws {
        let fixture = try GitFixture()
        let descriptor = QuickLookExportDescriptor(
            fileName: "Missing",
            isDirectory: true,
            source: .committedDirectory(
                repository: repositoryDescriptor(for: fixture),
                revision: fixture.revision,
                path: "Missing"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Missing", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("find any files"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testUnsafeCommittedPathIsRejectedBeforeGitRuns() throws {
        let fixture = try GitFixture()
        let descriptor = QuickLookExportDescriptor(
            fileName: "escape.txt",
            isDirectory: false,
            source: .committedFile(
                repository: repositoryDescriptor(for: fixture),
                revision: fixture.revision,
                path: "../escape.txt"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("escape.txt")

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsafe repository path"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testUnavailableSourceReportsItsCapturedMessageWithoutCreatingDestination() throws {
        let descriptor = QuickLookExportDescriptor(
            fileName: "Unavailable.txt",
            isDirectory: false,
            source: .unavailable("captured unavailable reason")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Unavailable.txt")

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertEqual(error.localizedDescription, "captured unavailable reason")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testMalformedGitTreeOutputReportsFailureWithoutPartialDestination() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("malformed-tree-git.sh")
        try "#!/bin/sh\nprintf 'malformed\\0'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Malformed",
            isDirectory: true,
            source: .committedDirectory(repository: repository, revision: fixture.revision, path: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Malformed", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid tree entry"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testSelectedSubmoduleDetectedAfterEmptyRecursiveListing() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("selected-submodule-git.sh")
        try """
        #!/bin/sh
        for argument in "$@"; do
          [ "$argument" = "-r" ] && exit 0
        done
        printf '160000 commit deadbeef\\tVendor\\0'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Vendor",
            isDirectory: true,
            source: .committedDirectory(repository: repository, revision: fixture.revision, path: "Vendor")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Vendor", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("submodule"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUnexpectedRecursiveTreeEntryTypeIsRejected() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("unexpected-tree-type-git.sh")
        try "#!/bin/sh\nprintf '040000 tree deadbeef\\tDocumentation/Nested\\0'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .committedDirectory(
                repository: repository,
                revision: fixture.revision,
                path: "Documentation"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid tree entry"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testQuickLookExportErrorsDescribeEveryFailureClass() {
        XCTAssertEqual(
            QuickLookExportError.unavailable("unavailable").localizedDescription,
            "unavailable"
        )
        XCTAssertTrue(QuickLookExportError.unsafePath("../escape").localizedDescription.contains("unsafe"))
        XCTAssertTrue(
            QuickLookExportError.commandFailed(path: "file", detail: "failure").localizedDescription.contains("failure")
        )
        XCTAssertTrue(QuickLookExportError.malformedTreeEntry.localizedDescription.contains("invalid tree entry"))
        XCTAssertTrue(QuickLookExportError.unsupportedSubmodule("Vendor").localizedDescription.contains("submodule"))
        XCTAssertTrue(QuickLookExportError.missingTree("Missing").localizedDescription.contains("find any files"))
    }

    func testTimedOutGitExportReportsFailureWithoutDestination() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("slow-git.sh")
        try "#!/bin/sh\nsleep 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "slow.txt",
            isDirectory: false,
            source: .committedFile(repository: repository, revision: fixture.revision, path: "binary.dat")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("slow.txt")

        XCTAssertThrowsError(
            try QuickLookFilePromiseExporter(commandTimeout: 0.01).export(descriptor, to: destination)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    private func tree(path: String, leaf: Bool) -> PBGitTree {
        let tree = PBGitTree()
        tree.path = path
        tree.leaf = leaf
        return tree
    }

    private func findTree(path: String, below tree: PBGitTree) -> PBGitTree? {
        if tree.fullPath == path {
            return tree
        }
        for child in tree.children {
            if let match = findTree(path: path, below: child) {
                return match
            }
        }
        return nil
    }

    private func repositoryDescriptor(for fixture: GitFixture) -> QuickLookGitRepositoryDescriptor {
        QuickLookGitRepositoryDescriptor(
            executablePath: PBGitBinary.path() ?? "/usr/bin/git",
            gitDirectoryPath: fixture.repository.gitURL()?.path ?? "",
            workingDirectoryPath: fixture.directory.path
        )
    }

    private func provider(for tree: PBGitTree, in outline: PBQLOutlineView) throws -> NSFilePromiseProvider {
        try XCTUnwrap(
            outline.outlineView(outline, pasteboardWriterForItem: NSTreeNode(representedObject: tree))
                as? NSFilePromiseProvider
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitx-file-promise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func write(
        provider: NSFilePromiseProvider,
        with outline: PBQLOutlineView,
        to destination: URL
    ) -> Error? {
        let result = ErrorBox()
        outline.filePromiseProvider(provider, writePromiseTo: destination) { error in
            result.store(error)
        }
        return result.error
    }
}
