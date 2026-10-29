import Foundation
@testable import GitX
import XCTest

/// Worktree fixtures can change global preferences while testing their own injected Git boundary.
/// Never delete an executable that the shared facade still publishes or is validating.
nonisolated enum GitBinaryTestIsolation {
    static func prepareToRemove(_ ownedURL: URL, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        func pathname(_ url: URL) -> String {
            // The configured fixture pathname, including a final symlink, is the owned entry.
            url.standardizedFileURL.path
        }
        let root = pathname(ownedURL)
        func owns(_ candidate: String?) -> Bool {
            guard let candidate else { return false }
            let path = pathname(URL(fileURLWithPath: candidate))
            return path == root || path.hasPrefix(root + "/")
        }
        let defaults = UserDefaults.standard
        let configured = defaults.string(forKey: "gitExecutable")
        guard GitBinaryDiscovery.shared.referencedExecutablePaths.contains(where: owns) || owns(configured) else { return true }
        if owns(configured) {
            defaults.set("/usr/bin/git", forKey: "gitExecutable")
        }
        // Synchronous explicit acceptance also revokes any in-flight fixture validation.
        let restored = PBGitBinary.accept("/usr/bin/git") && PBGitBinary.path() == "/usr/bin/git"
        XCTAssertTrue(restored, "Retaining a fixture because shared Git restoration failed: " + root, file: file, line: line)
        return restored
    }
}

@MainActor
final class GitBinaryTestIsolationTests: XCTestCase {
    func testSharedSelectionIsRestoredBeforeAnOwnedExecutableCanBeRemoved() throws {
        let ready = expectation(description: "The shared facade has a validated selection")
        PBGitBinary.whenAvailable { _, error in XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let original = try XCTUnwrap(PBGitBinary.path())
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "gitExecutable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Apple's tool shim dispatches by basename, so preserve the name "git".
        let executable = directory.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: original))
        defer {
            defaults.set(previous, forKey: "gitExecutable")
            let restored = PBGitBinary.accept(original) && PBGitBinary.path() == original
            XCTAssertTrue(restored)
            if restored {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        defaults.set(executable.path, forKey: "gitExecutable")
        XCTAssertTrue(PBGitBinary.accept(executable.path))
        XCTAssertEqual(PBGitBinary.path(), executable.path)
        XCTAssertTrue(GitBinaryTestIsolation.prepareToRemove(directory))
        XCTAssertEqual(PBGitBinary.path(), "/usr/bin/git")
        XCTAssertEqual(defaults.string(forKey: "gitExecutable"), "/usr/bin/git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path), "Authorization must leave fixture bytes intact")
        XCTAssertTrue(GitBinaryTestIsolation.prepareToRemove(directory), "Repeated cleanup authorization is harmless")
    }
}
