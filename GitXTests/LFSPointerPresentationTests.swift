import AppKit
import CryptoKit
import XCTest

/// What each read surface shows for a Git LFS pointer: a placeholder or nothing while its object is not downloaded,
/// and the object itself once the local store holds it. `git show` and `git cat-file` never run the smudge filter,
/// so none of this contacts a remote.
@MainActor
final class LFSPointerPresentationTests: XCTestCase {
    private static let oid = "28720365c5e7476a011e4f43ac003ee5f16247a263b9d623aa85ed311d73bf39"
    private static let pointerText = "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 12400000\n"
    private static let placeholder = "Git LFS object not downloaded — 12.4 MB (sha256 28720365…)"
    private static let storedText = "Stored Git LFS content\nsecond line\n"
    private static let storedImage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])

    private var directory: URL!
    private var repository: GitXTestGitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSPointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try ".gitattributes".write(to: directory, contents: "*.bin filter=lfs diff=lfs merge=lfs -text\n*.png filter=lfs diff=lfs merge=lfs -text\n")
        try "model.bin".write(to: directory, contents: Self.pointerText)
        try "assets/logo.png".write(to: directory, contents: Self.pointerText)
        try "notes.txt".write(to: directory, contents: Self.pointerText)
        try "stored/content.bin".write(to: directory, contents: store(Data(Self.storedText.utf8)))
        try "stored/image.png".write(to: directory, contents: store(Self.storedImage))
        // With no filter.lfs configured, Git stores these files as written: the pointer text.
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Track LFS pointers"])
        repository = try XCTUnwrap(GitXTestGitRepository(url: directory))
    }

    override func tearDownWithError() throws {
        repository?.revisionList?.cleanup()
        repository = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        try GitXTestGitFixture.run(arguments, in: directory).standardOutput
    }

    /// Writes `content` into the repository's local LFS store and returns the pointer that names it.
    private func store(_ content: Data) throws -> String {
        let oid = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let object = directory
            .appendingPathComponent(".git/lfs/objects", isDirectory: true)
            .appendingPathComponent(String(oid.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: object, withIntermediateDirectories: true)
        try content.write(to: object.appendingPathComponent(oid))
        return "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(content.count)\n"
    }

    private func headCommit() throws -> PBGitCommit {
        let gitRepository = try XCTUnwrap(repository.gtRepo)
        let object = try XCTUnwrap(try gitRepository.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        return PBGitCommit(repository: repository, andCommit: object)
    }

    private func committedNode(_ path: String) throws -> PBGitTree {
        let root = try PBHistoryTreePresentation(repository: repository).tree(for: headCommit())
        var nodes = try XCTUnwrap(root.children as? [PBGitTree])
        var found: PBGitTree?
        while found == nil, !nodes.isEmpty {
            found = nodes.first { $0.fullPath == path }
            nodes = nodes.flatMap { ($0.children as? [PBGitTree]) ?? [] }
        }
        return try XCTUnwrap(found, path)
    }

    private func exporter() throws -> (QuickLookGitRepositoryDescriptor, String) {
        let descriptor = QuickLookGitRepositoryDescriptor(
            executablePath: "/usr/bin/git",
            gitDirectoryPath: directory.appendingPathComponent(".git").path,
            workingDirectoryPath: directory.path
        )
        return try (descriptor, git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var imageSource: [String: Any] {
        [
            PBNativeImageSourceGitLaunchPathKey: "/usr/bin/git",
            PBNativeImageSourceGitDirectoryKey: directory.appendingPathComponent(".git").path,
            PBNativeImageSourceTaskDirectoryKey: directory.path,
            PBNativeImageSourceRevisionsKey: ["HEAD"],
        ]
    }

    func testHistoryTreeShowsAPlaceholderAndTheContentSizeUntilTheObjectIsDownloaded() throws {
        let model = try committedNode("model.bin")
        XCTAssertEqual(model.contents, Self.placeholder)
        XCTAssertEqual(model.textContents(), Self.placeholder)
        XCTAssertEqual(model.fileSize(), 12_400_000, "The size is the content's, not the pointer's")
        XCTAssertNil(model.tmpFileNameForContents(), "There is nothing to preview")

        let logo = try committedNode("assets/logo.png")
        XCTAssertEqual(logo.textContents(), Self.placeholder, "A placeholder replaces the binary-file message")
    }

    func testHistoryTreeKeepsPointerTextThatGitLFSDoesNotTrack() throws {
        let notes = try committedNode("notes.txt")
        XCTAssertEqual(notes.contents, String(Self.pointerText.dropLast()))
        XCTAssertEqual(notes.textContents(), String(Self.pointerText.dropLast()))
        XCTAssertEqual(notes.fileSize(), Int64(Self.pointerText.utf8.count))
    }

    func testHistoryTreeShowsAndPreviewsAStoredObject() throws {
        let content = try committedNode("stored/content.bin")
        XCTAssertEqual(content.contents, String(Self.storedText.dropLast()))
        XCTAssertEqual(content.textContents(), String(Self.storedText.dropLast()))
        XCTAssertEqual(content.fileSize(), Int64(Self.storedText.utf8.count))
        let preview = try XCTUnwrap(content.tmpFileNameForContents())
        XCTAssertEqual(try String(contentsOfFile: preview, encoding: .utf8), Self.storedText)
    }

    func testQuickLookExportRefusesContentThatIsNotDownloaded() throws {
        let (descriptor, revision) = try exporter()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let file = parent.appendingPathComponent("model.bin")
        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "model.bin", isDirectory: false, source: .committedFile(repository: descriptor, revision: revision, path: "model.bin")),
            to: file
        )) { error in
            guard case let .lfsObjectNotDownloaded(path, size) = error as? QuickLookExportError else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(path, "model.bin")
            XCTAssertEqual(size, 12_400_000)
            XCTAssertEqual(
                error.localizedDescription,
                "Half Dark cannot export model.bin because its Git LFS content (12.4 MB) is not downloaded. Download it, then try again."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "No pointer text is written")

        XCTAssertThrowsError(try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "assets", isDirectory: true, source: .committedDirectory(repository: descriptor, revision: revision, path: "assets")),
            to: parent.appendingPathComponent("assets", isDirectory: true)
        ), "A folder holding content that is not downloaded is refused too")
    }

    func testQuickLookExportWritesStoredObjectsAndUntrackedPointerText() throws {
        let (descriptor, revision) = try exporter()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let folder = parent.appendingPathComponent("stored", isDirectory: true)
        try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "stored", isDirectory: true, source: .committedDirectory(repository: descriptor, revision: revision, path: "stored")),
            to: folder
        )
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("content.bin")), Data(Self.storedText.utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("image.png")), Self.storedImage)

        let notes = parent.appendingPathComponent("notes.txt")
        try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "notes.txt", isDirectory: false, source: .committedFile(repository: descriptor, revision: revision, path: "notes.txt")),
            to: notes
        )
        XCTAssertEqual(try Data(contentsOf: notes), Data(Self.pointerText.utf8))
    }

    func testHistoryImageCallbackShowsNoImageUntilTheObjectIsDownloaded() {
        let controller = PBWebHistoryController()
        let view = PBNativeContentView(frame: .zero)
        XCTAssertNil(controller.nativeContentView(view, imageDataForPath: "assets/logo.png", section: 0, imageSource: imageSource))
        XCTAssertEqual(
            controller.nativeContentView(view, imageDataForPath: "stored/image.png", section: 0, imageSource: imageSource),
            Self.storedImage
        )
        XCTAssertEqual(controller.data(forGitObject: "HEAD:assets/logo.png", imageSource: imageSource), Data(Self.pointerText.utf8),
                       "The raw object reader keeps returning the blob")
    }
}

private extension String {
    func write(to directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
