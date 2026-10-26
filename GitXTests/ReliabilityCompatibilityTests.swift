import AppKit
import ObjectiveGit
import XCTest

final class ReliabilityCompatibilityTests: XCTestCase {
    @MainActor private final class ScriptCommand: NSObject {
        @objc let directParameter: Any?
        @objc let arguments: [String: Any]

        init(_ directParameter: Any?, arguments: [String: Any] = [:]) {
            self.directParameter = directParameter
            self.arguments = arguments
        }
    }

    func testExecutablePreferenceTransformerPreservesLocalPathsAndNilValues() throws {
        let type = try XCTUnwrap(NSClassFromString("PBNSURLPathUserDefaultsTransfomer") as? ValueTransformer.Type)
        XCTAssertTrue(type.transformedValueClass() == NSURL.self)
        XCTAssertTrue(type.allowsReverseTransformation())
        let transformer = type.init()
        XCTAssertNil(transformer.transformedValue(nil))
        XCTAssertNil(transformer.reverseTransformedValue(nil))
        let url = try XCTUnwrap(transformer.transformedValue("/usr/local/bin/git") as? URL)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/usr/local/bin/git")
        XCTAssertEqual(transformer.reverseTransformedValue(url) as? String, "/usr/local/bin/git")
    }

    func testTaskOutputConveniencePreservesSuccessAndFailure() throws {
        XCTAssertEqual(try PBTask.output(forCommand: "/usr/bin/printf", arguments: ["command output"]), "command output")
        XCTAssertEqual(try PBTask.output(forCommand: "/usr/bin/true", arguments: nil), "")
        XCTAssertThrowsError(try PBTask.output(forCommand: "/usr/bin/false", arguments: nil))
    }

    @MainActor func testDefaultContentRefreshPreservesItsRepositoryAndMountedView() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try GTRepository.initializeEmpty(atFileURL: directory, options: nil)
        let repository = try PBGitRepository(url: directory)
        let content = try XCTUnwrap(PBViewController(repository: repository, superController: nil))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        content.view = view
        content.status = "Ready"
        content.isBusy = false
        content.refresh(nil)
        XCTAssertTrue(content.repository === repository)
        XCTAssertTrue(content.view === view)
        XCTAssertTrue(view.superview === container)
        XCTAssertEqual(content.status, "Ready")
        XCTAssertFalse(content.isBusy)
        XCTAssertNil(content.firstResponder())
    }

    @MainActor func testScriptedDiffUsesTheRepositoryAndPreservesThePatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try GTRepository.initializeEmpty(atFileURL: directory, options: nil)
        let file = directory.appendingPathComponent("tracked.txt")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try PBTask.output(forCommand: "/usr/bin/git", arguments: ["-C", directory.path, "add", "tracked.txt"])
        _ = try PBTask.output(forCommand: "/usr/bin/git", arguments: [
            "-C", directory.path, "-c", "user.name=GitX Tests", "-c", "user.email=tests@gitx.invalid",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Initial",
        ])
        try "initial\nchanged\n".write(to: file, atomically: true, encoding: .utf8)
        let original = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { NSApp.windows.filter { !original.contains(ObjectIdentifier($0)) }.forEach { $0.close() } }
        let diffClass: AnyClass = try XCTUnwrap(NSClassFromString("PBDiffWindowController"))
        _ = NSApp.perform(NSSelectorFromString("performDiffScriptCommand:"), with: ScriptCommand(directory, arguments: ["diffOptions": []]))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSApp.windows.contains { window in
                !original.contains(ObjectIdentifier(window))
                    && window.windowController?.isKind(of: diffClass) == true
                    && (window.windowController?.value(forKey: "diff") as? String)?.contains("+changed") == true
            }
        }, object: nil)
        wait(for: [shown], timeout: 5)
    }

    @MainActor func testScriptedDiffDisplayAndRepositoryInitializationPreserveTheirContracts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = NSDocumentController.shared
        let original = Set(NSApp.windows.map(ObjectIdentifier.init))
        let originalDocuments = Set(controller.documents.map(ObjectIdentifier.init))
        defer {
            for document in controller.documents where !originalDocuments.contains(ObjectIdentifier(document)) {
                document.close()
            }
            NSApp.windows.filter { !original.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        let empty = ScriptCommand(nil)
        _ = NSApp.perform(NSSelectorFromString("showDiffScriptCommand:"), with: empty)
        _ = NSApp.perform(NSSelectorFromString("initRepositoryScriptCommand:"), with: empty)
        _ = NSApp.perform(NSSelectorFromString("cloneRepositoryScriptCommand:"), with: empty)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), original)
        _ = NSApp.perform(NSSelectorFromString("showDiffScriptCommand:"), with: ScriptCommand("diff --git a/file b/file\n"))
        XCTAssertTrue(NSApp.windows.contains { !original.contains(ObjectIdentifier($0)) })
        _ = NSApp.perform(NSSelectorFromString("initRepositoryScriptCommand:"), with: ScriptCommand(directory))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.documents.contains { $0.fileURL?.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() }
        }, object: nil)
        wait(for: [opened], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/HEAD").path))
        let invalid = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalid)
        _ = NSApp.perform(NSSelectorFromString("initRepositoryScriptCommand:"), with: ScriptCommand(invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.appendingPathComponent(".git").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
