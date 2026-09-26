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

        func writeObject(type: String, data: Data) throws -> String {
            let task = PBTask(
                launchPath: "/usr/bin/git",
                arguments: ["hash-object", "-w", "-t", type, "--literally", "--stdin"],
                inDirectory: directory.path
            )
            task.standardInputData = data
            try task.launch()
            return String(decoding: task.standardOutputData, as: UTF8.self)
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

    func testCommittedFilePromiseExcludesGitDiagnosticsFromBinaryContents() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("diagnostic-git.sh")
        try "#!/bin/sh\nprintf 'git warning\\n' >&2\nexec /usr/bin/git \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: script.path,
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: fixture.directory.path
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "binary.dat",
            isDirectory: false,
            source: .committedFile(repository: repository, revision: fixture.revision, path: "binary.dat")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("binary.dat")

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
    }

    func testCommittedDirectoryPromiseIgnoresGitTraceOnStandardError() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("traced-git.sh")
        try "#!/bin/sh\nGIT_TRACE=1 exec /usr/bin/git \"$@\"\n"
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
            source: .committedDirectory(repository: repository, revision: fixture.revision, path: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
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

    func testBareRepositoryCommittedFilePromiseExportsWithoutWorkingDirectory() throws {
        let fixture = try GitFixture()
        let bare = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("gitx-bare-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: bare) }
        let clone = PBTask(
            launchPath: "/usr/bin/git",
            arguments: ["clone", "--bare", "--quiet", fixture.directory.path, bare.path],
            inDirectory: nil
        )
        try clone.launch()
        let bareRepository = try PBGitRepository(url: bare)
        let root = PBGitTree()
        root.path = ""
        root.leaf = false
        let tree = PBGitTree()
        tree.path = "binary.dat"
        tree.leaf = true
        tree.sha = fixture.revision
        tree.repository = bareRepository
        tree.parent = root
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: tree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("binary.dat")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x00, 0x7F, 0xFF]))
    }

    func testCommittedDirectoryStartingWithColonUsesLiteralPath() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("literal path\n".utf8), to: ":Design/Note.txt")
        let revision = try fixture.commit("Add colon directory")
        let descriptor = QuickLookExportDescriptor(
            fileName: ":Design",
            isDirectory: true,
            source: .committedDirectory(
                repository: repositoryDescriptor(for: fixture), revision: revision, path: ":Design"
            )
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent(":Design", isDirectory: true)

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Note.txt")), Data("literal path\n".utf8))
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
        let writer = try GitBatchBlobWriter(
            targets: [.init(mode: "100644", objectIdentifier: identifier, path: "binary.dat", outputPath: "binary.dat")],
            writer: StagedFileWriter(rootURL: parent)
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
            outputPath: "missing.txt"
        )
        for response in [
            Data("\(identifier) missing\n".utf8),
            Data("\(String(repeating: "b", count: 40)) blob 0\n\n".utf8),
            Data("\(identifier) blob 3\nab".utf8),
            Data(repeating: 0x61, count: 257),
            Data("\(identifier) blob 3\nabc!".utf8),
        ] {
            let writer = try GitBatchBlobWriter(targets: [target], writer: StagedFileWriter(rootURL: parent))
            writer.consume(response)
            XCTAssertThrowsError(try writer.finish()) { error in
                XCTAssertTrue(error.localizedDescription.contains("invalid blob data"))
            }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(target.outputPath))
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
            outputPath: "Link"
        )
        for payload in [Data(), Data([0]), Data([0xFF]), Data(repeating: 0x61, count: 4097)] {
            let writer = try GitBatchBlobWriter(targets: [target], writer: StagedFileWriter(rootURL: parent))
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

    func testWorkingDirectoryPromisePreservesAnExistingRelativeSymbolicLink() throws {
        let fixture = try GitFixture()
        try FileManager.default.createSymbolicLink(
            atPath: fixture.directory.appendingPathComponent("Documentation/Current.txt").path,
            withDestinationPath: "Café.txt"
        )
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destination.appendingPathComponent("Current.txt").path
            ),
            "Café.txt"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
    }

    func testWorkingDirectoryPromiseCollectsNewFilesAtDropTime() throws {
        let fixture = try GitFixture()
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        try fixture.write(Data("new after drag\n".utf8), to: "Documentation/NewAfterDrag.txt")
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("NewAfterDrag.txt")),
            Data("new after drag\n".utf8)
        )
    }

    func testWorkingDirectoryPromisePreservesBrokenSymbolicLink() throws {
        let fixture = try GitFixture()
        try FileManager.default.createSymbolicLink(
            atPath: fixture.directory.appendingPathComponent("Documentation/Broken.txt").path,
            withDestinationPath: "missing.txt"
        )
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Broken.txt").path),
            "missing.txt"
        )
    }

    func testDeletedTrackedSymbolicLinkIsRestoredAsALinkFromIndex() throws {
        let fixture = try GitFixture()
        let link = fixture.directory.appendingPathComponent("Documentation/DeletedLink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Café.txt")
        _ = try fixture.commit("Add tracked symbolic link")
        try FileManager.default.removeItem(at: link)
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("DeletedLink").path),
            "Café.txt"
        )
    }

    func testDeletedTrackedFileIsRestoredFromIndex() throws {
        let fixture = try GitFixture()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("Documentation/Café.txt"))
        let root = PBWorkingTree.root(for: fixture.repository)
        let workingDirectory = try XCTUnwrap(findTree(path: "Documentation", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: workingDirectory, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Café.txt")),
            Data("promised directory contents\n".utf8)
        )
    }

    func testNestedUntrackedRepositoryPromiseCopiesFullContents() throws {
        let fixture = try GitFixture()
        let nested = fixture.directory.appendingPathComponent("Documentation/NestedRepo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let initTask = PBTask(launchPath: "/usr/bin/git", arguments: ["init", "--quiet", nested.path], inDirectory: nil)
        try initTask.launch()
        try Data("nested\n".utf8).write(to: nested.appendingPathComponent("README.md"))
        let root = PBWorkingTree.root(for: fixture.repository)
        let selected = try XCTUnwrap(findTree(path: "Documentation/NestedRepo", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: selected, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("NestedRepo", isDirectory: true)

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")), Data("nested\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    }

    func testCommittedTreeRejectsLinkWithDescendantBeforeWritingOutsideStaging() throws {
        let fixture = try GitFixture()
        let link = try fixture.writeObject(type: "blob", data: Data("../../outside".utf8))
        let childLink = try fixture.writeObject(type: "blob", data: Data("target".utf8))
        let child = try fixture.writeObject(type: "tree", data: rawTreeEntry("120000", "b", childLink))
        var directoryData = rawTreeEntry("120000", "a", link)
        directoryData.append(rawTreeEntry("40000", "a", child))
        let directory = try fixture.writeObject(type: "tree", data: directoryData)
        let root = try fixture.writeObject(type: "tree", data: rawTreeEntry("40000", "Documentation", directory))
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation", isDirectory: true,
            source: .committedDirectory(repository: repositoryDescriptor(for: fixture), revision: root, path: "Documentation")
        )

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("b").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWorkingDirectoryLinkAncestorCannotWriteOutsideStaging() throws {
        let fixture = try GitFixture()
        let original = fixture.directory.appendingPathComponent("Documentation/a", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("b").path, withDestinationPath: "target")
        _ = try fixture.commit("Track link below directory")
        try FileManager.default.removeItem(at: original)
        let sourceOutside = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("gitx-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sourceOutside) }
        try FileManager.default.createDirectory(at: sourceOutside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: sourceOutside.appendingPathComponent("b").path, withDestinationPath: "target")
        let relativeTarget = "../../\(sourceOutside.lastPathComponent)"
        try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: relativeTarget)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent(sourceOutside.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("a").path), relativeTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("b").path))
    }

    func testDeletedColonPrefixedIndexPathUsesItsOwnBlob() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("correct".utf8), to: "Documentation/0:foo")
        try fixture.write(Data("wrong".utf8), to: "Documentation/foo")
        _ = try fixture.commit("Track ambiguous index names")
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("Documentation/0:foo"))
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("0:foo")), Data("correct".utf8))
    }

    func testCommittedSingleFilePromisePreservesLinkAndExecutableMode() throws {
        let fixture = try GitFixture()
        let link = fixture.directory.appendingPathComponent("Documentation/Run Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Run.sh")
        let script = fixture.directory.appendingPathComponent("Documentation/Run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let revision = try fixture.commit("Track executable and link")
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        for name in ["Run Link", "Run.sh"] {
            let descriptor = QuickLookExportDescriptor(
                fileName: name, isDirectory: false,
                source: .committedFile(
                    repository: repositoryDescriptor(for: fixture), revision: revision, path: "Documentation/\(name)"
                )
            )
            try QuickLookFilePromiseExporter().export(descriptor, to: parent.appendingPathComponent(name))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: parent.appendingPathComponent("Run Link").path), "Run.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.appendingPathComponent("Run.sh").path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o755)
    }

    func testDeletedExecutableRetainsIndexMode() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("Documentation/Run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try fixture.commit("Track executable")
        try FileManager.default.removeItem(at: script)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("Run.sh").path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o755)
    }

    func testWorkingFolderCopiesDescendantSubmoduleCheckout() throws {
        let fixture = try GitFixture()
        _ = try fixture.addSubmoduleEntry(path: "Documentation/Vendor")
        let vendor = fixture.directory.appendingPathComponent("Documentation/Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: false)
        try Data("checkout".utf8).write(to: vendor.appendingPathComponent("README.md"))
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Vendor/README.md")), Data("checkout".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Café.txt")), Data("promised directory contents\n".utf8))
    }

    func testWorkingFolderUsesCurrentTypesWhenIndexPathsAreStale() throws {
        let fixture = try GitFixture()
        try fixture.write(Data("indexed file".utf8), to: "Documentation/BecomesDirectory")
        try fixture.write(Data("indexed child".utf8), to: "Documentation/BecomesFile/Old.txt")
        _ = try fixture.commit("Track both original types")
        let first = fixture.directory.appendingPathComponent("Documentation/BecomesDirectory")
        let second = fixture.directory.appendingPathComponent("Documentation/BecomesFile", isDirectory: true)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try Data("new child".utf8).write(to: first.appendingPathComponent("New.txt"))
        try FileManager.default.removeItem(at: second)
        try Data("new file".utf8).write(to: second)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("BecomesDirectory/New.txt")), Data("new child".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("BecomesFile")), Data("new file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("BecomesFile/Old.txt").path))
    }

    func testWorkingFolderPreservesNameWhoseGraphemeCrossesSeparator() throws {
        let fixture = try GitFixture()
        let name = "\u{301}note.txt"
        try fixture.write(Data("unicode".utf8), to: "e/\(name)")
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Exported", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Exported", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "e")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), Data("unicode".utf8))
    }

    func testExportNeutralizesInheritedGitPathspecModes() throws {
        let fixture = try GitFixture()
        let oldGlob = getenv("GIT_GLOB_PATHSPECS").map { String(cString: $0) }
        let oldCase = getenv("GIT_ICASE_PATHSPECS").map { String(cString: $0) }
        defer {
            if let oldGlob {
                setenv("GIT_GLOB_PATHSPECS", oldGlob, 1)
            } else {
                unsetenv("GIT_GLOB_PATHSPECS")
            }
            if let oldCase {
                setenv("GIT_ICASE_PATHSPECS", oldCase, 1)
            } else {
                unsetenv("GIT_ICASE_PATHSPECS")
            }
        }
        setenv("GIT_GLOB_PATHSPECS", "1", 1)
        setenv("GIT_ICASE_PATHSPECS", "1", 1)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Working", isDirectory: true)
        let descriptor = QuickLookExportDescriptor(
            fileName: "Working", isDirectory: true,
            source: .workingDirectory(repository: repositoryDescriptor(for: fixture), rootPath: "Documentation")
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Café.txt")), Data("promised directory contents\n".utf8))
    }

    func testInaccessibleWorkingFileFallsBackToItsIndexBlob() throws {
        let fixture = try GitFixture()
        let documentation = fixture.directory.appendingPathComponent("Documentation", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: documentation.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documentation.path) }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Café.txt")
        let entry = QuickLookWorkingTreeEntry(
            relativePath: "Café.txt", repositoryPath: "Documentation/Café.txt",
            fileURL: documentation.appendingPathComponent("Café.txt")
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Café.txt", isDirectory: false,
            source: .workingFile(repository: repositoryDescriptor(for: fixture), entry: entry)
        )

        try QuickLookFilePromiseExporter().export(descriptor, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("promised directory contents\n".utf8))
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

    func testSelectedCommittedSubmoduleLeafReportsSpecificFailure() throws {
        let fixture = try GitFixture()
        let revision = try fixture.addSubmoduleEntry(path: "Vendor")
        let tree = fixture.tree(path: "Vendor", leaf: true)
        tree.sha = revision
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: tree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Vendor")

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertTrue(error?.localizedDescription.contains("submodule") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSelectedWorkingSubmoduleLeafCopiesCheckout() throws {
        let fixture = try GitFixture()
        _ = try fixture.addSubmoduleEntry(path: "Vendor")
        let vendor = fixture.directory.appendingPathComponent("Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: false)
        try Data("working submodule\n".utf8).write(to: vendor.appendingPathComponent("README.md"))
        let root = PBWorkingTree.root(for: fixture.repository)
        let selected = try XCTUnwrap(findTree(path: "Vendor", below: root))
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let provider = try provider(for: selected, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Vendor")

        XCTAssertNil(write(provider: provider, with: outline, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")), Data("working submodule\n".utf8))
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

    func testWorkingDirectoryPromiseWithoutWorkingDirectoryFailsAndCleansStaging() throws {
        let fixture = try GitFixture()
        let repository = QuickLookGitRepositoryDescriptor(
            executablePath: PBGitBinary.path() ?? "/usr/bin/git",
            gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
            workingDirectoryPath: nil
        )
        let descriptor = QuickLookExportDescriptor(
            fileName: "Documentation",
            isDirectory: true,
            source: .workingDirectory(repository: repository, rootPath: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("working directory"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testWorkingDirectoryPromiseRejectsNonUTF8VisibleNameAndCleansStaging() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("non-utf8-working-git.sh")
        try "#!/bin/sh\ncase \"$*\" in *--stage*) exit 0;; esac\nprintf 'Documentation/\\377\\000'\n"
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
            source: .workingDirectory(repository: repository, rootPath: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unicode"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testWorkingDirectoryPromiseRejectsUnsafeAndMalformedVisibleListings() throws {
        let fixture = try GitFixture()
        let cases: [(name: String, output: String, expectedError: String)] = [
            ("outside-root", "printf 'Outside.txt\\000'", "unsafe repository path"),
            ("missing-nul", "printf 'Documentation/File.txt'", "invalid tree entry"),
            ("empty-record", "printf 'Documentation/File.txt\\000\\000'", "invalid tree entry"),
        ]
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        for testCase in cases {
            let script = fixture.directory.appendingPathComponent("\(testCase.name)-working-git.sh")
            try "#!/bin/sh\ncase \"$*\" in *--stage*) exit 0;; esac\n\(testCase.output)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let repository = QuickLookGitRepositoryDescriptor(
                executablePath: script.path,
                gitDirectoryPath: fixture.directory.appendingPathComponent(".git").path,
                workingDirectoryPath: fixture.directory.path
            )
            let descriptor = QuickLookExportDescriptor(
                fileName: testCase.name,
                isDirectory: true,
                source: .workingDirectory(repository: repository, rootPath: "Documentation")
            )
            let destination = parent.appendingPathComponent(testCase.name, isDirectory: true)

            XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
                XCTAssertTrue(error.localizedDescription.contains(testCase.expectedError), testCase.name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
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

    func testNonUTF8CommittedNameFailsClearlyAndCleansStaging() throws {
        let fixture = try GitFixture()
        let script = fixture.directory.appendingPathComponent("non-utf8-tree-git.sh")
        let oid = String(repeating: "0", count: 40)
        try "#!/bin/sh\nprintf '100644 blob \(oid)\\tDocumentation/\\377\\0'\n"
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
            source: .committedDirectory(repository: repository, revision: fixture.revision, path: "Documentation")
        )
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Documentation", isDirectory: true)

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(descriptor, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unicode"))
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

    private func rawTreeEntry(_ mode: String, _ name: String, _ identifier: String) -> Data {
        var data = Data("\(mode) \(name)".utf8)
        data.append(0)
        let bytes = Array(identifier.utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let high = UInt8(String(decoding: bytes[index ... index], as: UTF8.self), radix: 16) ?? 0
            let low = UInt8(String(decoding: bytes[index + 1 ... index + 1], as: UTF8.self), radix: 16) ?? 0
            data.append(high << 4 | low)
        }
        return data
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
