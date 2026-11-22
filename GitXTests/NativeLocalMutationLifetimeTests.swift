import AppKit
@testable import GitX
import XCTest

@MainActor
final class NativeLocalMutationLifetimeTests: XCTestCase {
    func testClosingTheOriginalDocumentLetsAnAdmittedHardResetFinish() async throws {
        let fixture = try ReflogGitFixture()
        defer { fixture.remove() }
        let target = try fixture.git(["rev-parse", "HEAD"])
        try fixture.write("tracked.txt", "second committed contents\n")
        try fixture.git(["commit", "-am", "second"])
        let previous = try fixture.git(["rev-parse", "HEAD"])
        let document = try GitX.PBGitRepositoryDocument(contentsOf: fixture.url, ofType: PBGitRepositoryDocumentType)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let owner = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        owner.showWindow(nil)
        let repository = try XCTUnwrap(document.repository)
        defer { document.close(); repository.revisionList?.cleanup(); repository.revisionList = nil }
        let gate = try ReflogResetExecutionGate(repository: repository, fixture: fixture)
        defer { try? gate.open() }
        let service = try GitX.RepositoryReflogService(repository: repository, context: gate.context)
        let preview = try service.preview(target: target, mode: .hard)
        let admitted = Task.detached { try service.reset(confirmed: preview, discardConfirmed: true) }
        let held = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: gate.started.path) }, object: nil)
        await fulfillment(of: [held], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gate.started.path))
        document.close()
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0 === document })
        XCTAssertFalse(owner.window?.isVisible == true)
        document.close()
        try gate.open()
        let backup = try await admitted.value
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), target)
        XCTAssertEqual(try fixture.git(["rev-parse", backup]), previous)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8), "initial\n")
    }
}
