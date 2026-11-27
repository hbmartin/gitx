import AppKit
import XCTest

/// Pins what each read surface shows for a Git LFS pointer whose object was never downloaded.
/// `git show` and `git cat-file` never run the smudge filter, so today every surface shows the pointer text itself.
@MainActor
final class LFSPointerCharacterizationTests: XCTestCase {
    private static let oid = "28720365c5e7476a011e4f43ac003ee5f16247a263b9d623aa85ed311d73bf39"
    private static let pointerText = "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 12400000\n"

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

    func testHistoryTreeShowsThePointerTextAndItsSize() throws {
        let model = try committedNode("model.bin")
        XCTAssertEqual(model.contents, String(Self.pointerText.dropLast()))
        XCTAssertEqual(model.textContents(), String(Self.pointerText.dropLast()))
        XCTAssertEqual(model.fileSize(), Int64(Self.pointerText.utf8.count))
        let preview = try XCTUnwrap(model.tmpFileNameForContents())
        XCTAssertEqual(try String(contentsOfFile: preview, encoding: .utf8), Self.pointerText)

        let logo = try committedNode("assets/logo.png")
        XCTAssertEqual(logo.textContents(), "assets/logo.png appears to be a binary file of \(Self.pointerText.utf8.count) bytes")
    }

    func testQuickLookExportWritesThePointerBytes() throws {
        let descriptor = QuickLookGitRepositoryDescriptor(
            executablePath: "/usr/bin/git",
            gitDirectoryPath: directory.appendingPathComponent(".git").path,
            workingDirectoryPath: directory.path
        )
        let revision = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("GitXLFSExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let file = parent.appendingPathComponent("model.bin")
        try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "model.bin", isDirectory: false, source: .committedFile(repository: descriptor, revision: revision, path: "model.bin")),
            to: file
        )
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.pointerText.utf8))

        let folder = parent.appendingPathComponent("assets", isDirectory: true)
        try QuickLookFilePromiseExporter().export(
            QuickLookExportDescriptor(fileName: "assets", isDirectory: true, source: .committedDirectory(repository: descriptor, revision: revision, path: "assets")),
            to: folder
        )
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("logo.png")), Data(Self.pointerText.utf8))
    }

    func testHistoryImageCallbackReturnsThePointerBytes() {
        let imageSource: [String: Any] = [
            PBNativeImageSourceGitLaunchPathKey: "/usr/bin/git",
            PBNativeImageSourceGitDirectoryKey: directory.appendingPathComponent(".git").path,
            PBNativeImageSourceTaskDirectoryKey: directory.path,
            PBNativeImageSourceRevisionsKey: ["HEAD"],
        ]
        let controller = PBWebHistoryController()
        let view = PBNativeContentView(frame: .zero)
        XCTAssertEqual(
            controller.nativeContentView(view, imageDataForPath: "assets/logo.png", section: 0, imageSource: imageSource),
            Data(Self.pointerText.utf8)
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
