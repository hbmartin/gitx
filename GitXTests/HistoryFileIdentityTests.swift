import AppKit
import XCTest

@MainActor
final class HistoryFileIdentityTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitXHistoryIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GitXTestGitFixture.run(["init", "-q", "-b", "main"], in: directory)
        let previousOnly = PBApplicationSettings.changedFilesOnly
        let previousSort = PBApplicationSettings.changedFilesSort
        PBApplicationSettings.changedFilesOnly = true
        defer { PBApplicationSettings.changedFilesOnly = previousOnly; PBApplicationSettings.changedFilesSort = previousSort }
        try body(directory)
    }

    private func headCommit(in repository: PBGitRepository) throws -> PBGitCommit {
        let gitRepository = try XCTUnwrap(repository.gtRepo)
        let object = try XCTUnwrap(try gitRepository.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        return PBGitCommit(repository: repository, andCommit: object)
    }

    private func blob(_ contents: String, directory: URL) throws -> String {
        try GitXTestGitFixture.run(["hash-object", "-w", "--stdin"], in: directory, standardInput: Data(contents.utf8)).standardOutput.trimmingCharacters(in: .newlines)
    }

    private func put(_ entries: [(Data, String)], directory: URL) throws {
        var input = Data()
        for (path, oid) in entries {
            input.append(Data("100644 \(oid)\t".utf8)); input.append(path); input.append(0)
        }
        try GitXTestGitFixture.run(["update-index", "-z", "--index-info"], in: directory, standardInput: input)
    }

    func testCanonicallyEquivalentCommittedPathsKeepDistinctIdentityMetadataAndOrdering() throws {
        try fixture { directory in
            let nfc = Data("caf\u{00E9}.txt".utf8)
            let nfd = Data("cafe\u{0301}.txt".utf8)
            XCTAssertNotEqual(nfc, nfd)
            let old = try blob("old NFC\n", directory: directory)
            try put([(nfc, old)], directory: directory)
            try GitXTestGitFixture.run(["commit", "-q", "-m", "initial NFC"], in: directory)
            let changed = try blob("changed NFC\n", directory: directory)
            let added = try blob("added NFD\n", directory: directory)
            try put([(nfc, changed), (nfd, added)], directory: directory)
            try GitXTestGitFixture.run(["commit", "-q", "-m", "distinct canonical paths"], in: directory)
            let repository = try XCTUnwrap(GitXTestGitRepository(url: directory))
            defer { repository.revisionList?.cleanup() }
            let commit = try headCommit(in: repository)
            let presentation = PBHistoryTreePresentation(repository: repository)
            for sort in [PBChangedFilesSortMode.alphabetical, .status, .gitOrder] {
                PBApplicationSettings.changedFilesSort = sort
                let tree = presentation.tree(for: commit)
                let nodes = try XCTUnwrap(tree.children)
                XCTAssertEqual(nodes.count, 2)
                let byPath = try Dictionary(uniqueKeysWithValues: nodes.map { try (XCTUnwrap($0.value(forKey: "rawPath") as? Data), $0) })
                XCTAssertEqual(Set(byPath.keys), Set([nfc, nfd]))
                let nfcNode = try XCTUnwrap(byPath[nfc])
                let nfdNode = try XCTUnwrap(byPath[nfd])
                XCTAssertTrue(presentation.displayTitle(for: nfcNode).hasPrefix("M  "))
                XCTAssertTrue(presentation.displayTitle(for: nfdNode).hasPrefix("A  "))
                XCTAssertEqual(Data(nfcNode.fullPath.utf8), nfc)
                XCTAssertEqual(Data(nfdNode.fullPath.utf8), nfd)
                XCTAssertEqual(nfcNode.contents, "changed NFC")
                XCTAssertEqual(nfdNode.contents, "added NFD")
                XCTAssertEqual(nfdNode.fileSize(), Int64("added NFD\n".utf8.count))
                XCTAssertTrue(nfdNode.blame().contains("added NFD"))
                XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(nfdNode.tmpFileNameForContents()), encoding: .utf8), "added NFD\n")
                XCTAssertEqual(try nodes.map { try XCTUnwrap($0.value(forKey: "rawPath") as? Data) }, [nfd, nfc])
            }
        }
    }

    func testInvalidCommittedBytesRemainDistinctFromTheirDisplaySpellingAndCannotPreview() throws {
        try fixture { directory in
            let invalid = Data([0x66, 0xFF])
            let literal = Data("f\\xFF".utf8)
            let contents = try blob("literal contents\n", directory: directory)
            try put([(invalid, contents), (literal, contents)], directory: directory)
            try GitXTestGitFixture.run(["commit", "-q", "-m", "raw display collision"], in: directory)
            let repository = try XCTUnwrap(GitXTestGitRepository(url: directory))
            defer { repository.revisionList?.cleanup() }
            let presentation = PBHistoryTreePresentation(repository: repository)
            let nodes = try XCTUnwrap(try presentation.tree(for: headCommit(in: repository)).children)
            XCTAssertEqual(nodes.count, 2)
            let unsafe = try XCTUnwrap(nodes.first { ($0.value(forKey: "rawPath") as? Data) == invalid })
            let safe = try XCTUnwrap(nodes.first { ($0.value(forKey: "rawPath") as? Data) == literal })
            XCTAssertTrue(unsafe.contents.contains("cannot be represented"))
            XCTAssertEqual(unsafe.textContents(), unsafe.contents)
            XCTAssertEqual(unsafe.blame(), unsafe.contents)
            XCTAssertEqual(unsafe.log("%s"), unsafe.contents)
            XCTAssertEqual(unsafe.fileSize(), 0)
            XCTAssertNil(unsafe.perform(NSSelectorFromString("tmpFileNameForContents")))
            XCTAssertNil(PBHistoryFilePreview.url(for: unsafe))
            XCTAssertFalse(PBHistoryFileOpening.open(tree: unsafe, outline: nil, item: nil, opener: { _ in XCTFail("Unsafe leaf reached opener"); return true }))
            XCTAssertEqual(safe.contents, "literal contents")
            XCTAssertEqual(safe.textContents(), "literal contents")
            XCTAssertFalse(safe.blame().isEmpty)
            XCTAssertFalse(safe.log("%s").isEmpty)
            XCTAssertGreaterThan(safe.fileSize(), 0)
            XCTAssertNotNil(safe.tmpFileNameForContents())
            XCTAssertNotNil(PBHistoryFilePreview.url(for: safe))
        }
    }

    func testCommittedPreviewPreservesBinarySizeAndFailedReadDiagnostics() throws {
        try fixture { directory in
            let ordinary = try blob("plain\n", directory: directory)
            let binary = try blob("a\0b\n", directory: directory)
            let large = try blob(String(repeating: "x", count: 52_428_801), directory: directory)
            let entries = [("ordinary.txt", ordinary), ("image.png", ordinary), (".png", ordinary), ("forced.txt", ordinary),
                           ("text.png", ordinary), ("nul.txt", binary), ("large.txt", large)]
            try put(entries.map { (Data($0.0.utf8), $0.1) }, directory: directory)
            try "forced.txt binary\ntext.png -binary\n".write(to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try GitXTestGitFixture.run(["commit", "-q", "-m", "preview decisions"], in: directory)
            let repository = try XCTUnwrap(GitXTestGitRepository(url: directory))
            defer { repository.revisionList?.cleanup() }
            let nodes = try XCTUnwrap(PBHistoryTreePresentation(repository: repository).tree(for: headCommit(in: repository)).children)
            for path in ["image.png", ".png", "forced.txt", "nul.txt"] {
                let node = try XCTUnwrap(nodes.first { $0.path == path })
                XCTAssertTrue(node.textContents().contains("binary file"), path)
                XCTAssertTrue(node.blame().contains("binary file"), path)
                if path != "nul.txt" {
                    XCTAssertTrue(node.log("%s").contains("binary file"), path)
                }
            }
            let text = try XCTUnwrap(nodes.first { $0.path == "text.png" })
            XCTAssertEqual(text.textContents(), "plain")
            let oversized = try XCTUnwrap(nodes.first { $0.path == "large.txt" })
            XCTAssertTrue(oversized.textContents().contains("too big"))
            XCTAssertTrue(oversized.blame().contains("too big"))
            XCTAssertTrue(oversized.log("%s").contains("too big"))
            let normal = try XCTUnwrap(nodes.first { $0.path == "ordinary.txt" })
            let preview = try XCTUnwrap(normal.tmpFileNameForContents())
            XCTAssertEqual(normal.tmpFileNameForContents(), preview)
            try FileManager.default.removeItem(atPath: preview)
            XCTAssertEqual(normal.tmpFileNameForContents(), preview)
            XCTAssertEqual(normal.contents, "plain\n")
            try "edited preview\n".write(toFile: preview, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: preview)
            XCTAssertEqual(normal.contents, "plain")
            XCTAssertEqual(normal.tmpFileNameForContents(), preview)
            XCTAssertEqual(try String(contentsOfFile: preview, encoding: .utf8), "plain\n")
            try FileManager.default.removeItem(atPath: XCTUnwrap(normal.tmpFileNameForContents()))
            normal.sha = String(repeating: "f", count: 40)
            XCTAssertTrue(normal.contents.contains("fatal"))
            XCTAssertEqual(normal.fileSize(), -1)
            XCTAssertNil(normal.perform(NSSelectorFromString("tmpFileNameForContents")))
        }
    }

    private final class OutlineSource: NSObject, NSOutlineViewDataSource {
        let root: PBGitTree
        init(root: PBGitTree) {
            self.root = root
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            ((item as? PBGitTree) ?? root).children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? PBGitTree) ?? root).children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? PBGitTree)?.leaf == false
        }
    }

    func testOpeningDirectoriesTogglesTheOutlineAndOnlyLeavesReachTheInjectedOpener() throws {
        try fixture { directory in
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try "leaf contents\n".write(to: directory.appendingPathComponent("folder/leaf.txt"), atomically: true, encoding: .utf8)
            try GitXTestGitFixture.run(["add", "."], in: directory)
            try GitXTestGitFixture.run(["commit", "-q", "-m", "outline fixture"], in: directory)
            let repository = try XCTUnwrap(GitXTestGitRepository(url: directory))
            defer { repository.revisionList?.cleanup() }
            let root = try headCommit(in: repository).tree
            let folder = try XCTUnwrap(root.children.first)
            let leaf = try XCTUnwrap(folder.children.first)
            let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
            outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
            let source = OutlineSource(root: root)
            outline.dataSource = source
            outline.reloadData()
            var opens = 0
            let opener: (URL) -> Bool = { url in
                opens += 1
                XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "leaf contents\n")
                return true
            }
            XCTAssertFalse(PBHistoryFileOpening.open(tree: folder, outline: nil, item: folder, opener: opener))
            XCTAssertFalse(PBHistoryFileOpening.open(tree: folder, outline: outline, item: nil, opener: opener))
            XCTAssertFalse(outline.isItemExpanded(folder))
            XCTAssertTrue(PBHistoryFileOpening.open(tree: folder, outline: outline, item: folder, opener: opener))
            XCTAssertTrue(outline.isItemExpanded(folder))
            XCTAssertEqual(opens, 0)
            try attachScreenshot(of: outline, named: "History-Directory-Expanded-Without-Opening")
            XCTAssertTrue(PBHistoryFileOpening.open(tree: folder, outline: outline, item: folder, opener: opener))
            XCTAssertFalse(outline.isItemExpanded(folder))
            XCTAssertEqual(opens, 0)
            XCTAssertTrue(PBHistoryFileOpening.open(tree: leaf, outline: outline, item: leaf, opener: opener))
            XCTAssertEqual(opens, 1)
            XCTAssertFalse(PBHistoryFileOpening.open(tree: leaf, outline: outline, item: leaf, opener: { _ in false }))
            withExtendedLifetime(source) {}
        }
    }
}
