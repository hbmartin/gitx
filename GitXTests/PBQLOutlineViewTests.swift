import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PBQLOutlineViewTests: XCTestCase {
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

    // swift6-safety-justification: Tests finish configuring the spy before queueing work, and the lock protects its only cross-queue result.
    private final class TreeSpy: PBGitTree, @unchecked Sendable {
        private let exportLock = NSLock()
        private var exportedOnMainThreadStorage: Bool?
        var shouldExport = true
        var exportedContents = Data("promised contents".utf8)

        var exportedOnMainThread: Bool? {
            exportLock.lock()
            defer { exportLock.unlock() }
            return exportedOnMainThreadStorage
        }

        override func save(toFolder directory: String) {
            exportLock.lock()
            exportedOnMainThreadStorage = Thread.isMainThread
            exportLock.unlock()
            guard shouldExport else { return }
            let outputURL = URL(fileURLWithPath: directory).appendingPathComponent(path)
            if leaf {
                try? FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? exportedContents.write(to: outputURL)
            } else {
                try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                try? exportedContents.write(to: outputURL.appendingPathComponent("child.txt"))
            }
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
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = tree(path: "background.txt", leaf: true)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let context = PromiseWriteContext(
            outline: outline,
            provider: provider,
            destination: parent.appendingPathComponent("background.txt")
        )
        let completed = expectation(description: "The file promise completed")
        let result = ErrorBox()

        outline.operationQueue(for: provider).addOperation {
            context.outline.filePromiseProvider(context.provider, writePromiseTo: context.destination) { error in
                result.store(error)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 2)
        XCTAssertNil(result.error)
        XCTAssertEqual(promisedTree.exportedOnMainThread, false)
    }

    func testFilePromiseWritesToExactDestinationAndRemovesStagingDirectory() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = tree(path: "nested/original-name.txt", leaf: true)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("AppKit-selected-name.txt")

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: destination), promisedTree.exportedContents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [destination.lastPathComponent])
    }

    func testDirectoryPromiseMovesExportedTreeToExactDestination() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = tree(path: "Original Folder", leaf: false)
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Dropped Folder", isDirectory: true)

        let error = write(provider: provider, with: outline, to: destination)

        XCTAssertNil(error)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("child.txt")),
            promisedTree.exportedContents
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [destination.lastPathComponent])
    }

    func testMissingExportReportsErrorAndCleansStagingDirectory() throws {
        let outline = PBQLOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let promisedTree = tree(path: "missing.txt", leaf: true)
        promisedTree.shouldExport = false
        let provider = try provider(for: promisedTree, in: outline)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("missing.txt")

        let error = write(provider: provider, with: outline, to: destination) as NSError?

        XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error?.code, NSFileNoSuchFileError)
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

    private func tree(path: String, leaf: Bool) -> TreeSpy {
        let tree = TreeSpy()
        tree.path = path
        tree.leaf = leaf
        return tree
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
