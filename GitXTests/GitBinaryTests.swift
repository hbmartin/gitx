import AppKit
@testable import GitX
import ObjectiveGit
import Synchronization
import XCTest

final class GitBinaryTests: XCTestCase {
    // swift6-safety-justification: The test counter stays on MainActor; inherited lifecycle state uses the manager's lock.
    private final nonisolated class FetchProbe: GitX.PBAutoFetchManager, @unchecked Sendable {
        @MainActor var evaluations = 0

        @MainActor override func candidateRepositoryURLs() -> [String: URL] {
            evaluations += 1
            return [:]
        }
    }

    private final nonisolated class Probe: Sendable {
        struct State {
            var preference: String?
            var outputs: [String: String]
            var calls: [String] = []
        }

        let state: Mutex<State>
        let release = DispatchSemaphore(value: 0)
        let delayed: String?

        init(preference: String? = nil, outputs: [String: String], delayed: String? = nil) {
            state = Mutex(State(preference: preference, outputs: outputs))
            self.delayed = delayed
        }

        func output(_ path: String, _ arguments: [String]) -> String? {
            state.withLock { $0.calls.append(path + " " + arguments.joined(separator: " ")) }
            if path == delayed {
                _ = release.wait(timeout: .now() + 10)
            }
            return state.withLock { $0.outputs[path] }
        }

        func discovery(locations: [String] = ["/known"], environment: [String: String] = [:]) -> GitBinaryDiscovery {
            GitBinaryDiscovery(preference: { self.state.withLock { $0.preference } }, environment: environment,
                               output: { self.output($0, $1) }, locations: locations)
        }
    }

    func testDiscoveryCoalescesWaitersAndLeavesTheMainQueueResponsiveDuringValidation() {
        let probe = Probe(preference: "/configured", outputs: ["/configured": "git version 2.50.1"], delayed: "/configured")
        let discovery = probe.discovery()
        let completed = expectation(description: "Both callers receive the validated path")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        for _ in 0 ..< 2 {
            discovery.whenAvailable { path, error in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(path, "/configured")
                XCTAssertNil(error)
                completed.fulfill()
            }
        }
        DispatchQueue.main.async {
            XCTAssertNil(discovery.path, "An unverified candidate must never be published")
            probe.release.signal()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.version, "2.50.1")
        XCTAssertEqual(probe.state.withLock { $0.calls }, ["/configured --version"])
    }

    @MainActor func testAutoFetchWaitsForValidationAndStopRevokesPendingFetches() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "PBAutoFetchScope")
        defaults.set(2, forKey: "PBAutoFetchScope")
        defer { defaults.set(previous, forKey: "PBAutoFetchScope") }
        for stopped in [false, true] {
            let probe = Probe(preference: "/git", outputs: ["/git": "git version 2.50.1"], delayed: "/git")
            let discovery = probe.discovery()
            let manager = FetchProbe(gitDiscovery: discovery)
            manager.evaluateRepositoriesForImmediateFetch(true)
            XCTAssertEqual(manager.evaluations, 0)
            if stopped {
                manager.stop()
            }
            let completed = expectation(description: "Validation completed")
            discovery.whenAvailable { _, _ in completed.fulfill() }
            probe.release.signal()
            wait(for: [completed], timeout: 3)
            XCTAssertEqual(manager.evaluations, stopped ? 0 : 1)
            manager.stop()
        }
        let missing = Probe(outputs: [:]).discovery()
        let manager = FetchProbe(gitDiscovery: missing)
        manager.evaluateRepositoriesForImmediateFetch(true)
        let failed = expectation(description: "Failed discovery completed")
        missing.whenAvailable { _, _ in failed.fulfill() }
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(manager.evaluations, 0)
    }

    @MainActor func testRepositoryOpenBalancesAccountingWhenDiscoveryFails() {
        let controller = GitX.PBRepositoryDocumentController()
        controller.gitDiscovery = Probe(outputs: [:]).discovery()
        let completed = expectation(description: "Failed open completed once")
        completed.assertForOverFulfill = true
        controller.openDocument(withContentsOf: URL(fileURLWithPath: "/unavailable"), display: false) { document, alreadyOpen, error in
            XCTAssertNil(document)
            XCTAssertFalse(alreadyOpen)
            XCTAssertEqual((error as NSError?)?.domain, "PBGitBinaryErrorDomain")
            XCTAssertFalse(controller.hasPendingOpens)
            completed.fulfill()
        }
        XCTAssertTrue(controller.hasPendingOpens)
        wait(for: [completed], timeout: 3)
    }

    @MainActor func testRepositoryOpenResumesAfterValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try GTRepository.initializeEmpty(atFileURL: directory, options: nil)
        let probe = Probe(preference: "/usr/bin/git", outputs: ["/usr/bin/git": "git version 2.50.1"], delayed: "/usr/bin/git")
        let controller = GitX.PBRepositoryDocumentController()
        controller.gitDiscovery = probe.discovery()
        let completed = expectation(description: "Validated repository opened once")
        completed.assertForOverFulfill = true
        controller.openDocument(withContentsOf: directory, display: false) { document, _, error in
            XCTAssertNotNil(document)
            XCTAssertNil(error)
            XCTAssertFalse(controller.hasPendingOpens)
            document?.close()
            completed.fulfill()
        }
        XCTAssertTrue(controller.hasPendingOpens)
        probe.release.signal()
        wait(for: [completed], timeout: 5)
    }

    func testDiscoveryPreservesCandidatePrecedenceAndFilenameSpaces() {
        let cases: [(String?, [String: String], [String: String], String)] = [
            ("/configured", ["/configured": "git version 2.50.1"], ["GIT_PATH": "/environment"], "/configured"),
            ("/invalid", ["/environment": "git version 2.50.1"], ["GIT_PATH": "/environment"], "/environment"),
            (nil, ["/usr/bin/which": "/which git \n", "/which git ": "git version 2.50.1"], [:], "/which git "),
            (nil, ["/usr/bin/which": "\n/which git \r\n", "\n/which git ": "git version 2.50.1"], [:], "\n/which git "),
            (nil, ["/known": "git version 2.50.1"], [:], "/known"),
            (nil, ["/known": "git version 1.5.9", "/usr/bin/xcrun": "/xcrun\n", "/xcrun": "git version 2.50.1"], [:], "/xcrun"),
        ]
        for (preference, outputs, environment, expected) in cases {
            let discovery = Probe(preference: preference, outputs: outputs).discovery(environment: environment)
            let completed = expectation(description: expected)
            discovery.whenAvailable { path, error in
                XCTAssertEqual(path, expected)
                XCTAssertNil(error)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
        }
    }

    func testDiscoveryReportsExhaustionAndRejectsInvalidExplicitSelections() {
        let discovery = Probe(preference: "/invalid", outputs: ["/known": "not a Git version"]).discovery()
        let completed = expectation(description: "Failure is terminal")
        discovery.whenAvailable { path, error in
            XCTAssertNil(path)
            XCTAssertEqual(error?.domain, "PBGitBinaryErrorDomain")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertFalse(discovery.accept(nil))
        XCTAssertFalse(discovery.accept("\n"))
        XCTAssertNil(discovery.version(forPath: nil))
        XCTAssertNil(discovery.path)
        XCTAssertFalse(discovery.isReady)
    }

    func testReadySnapshotIsInvalidatedAsSoonAsThePreferenceChanges() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"])
        let discovery = probe.discovery()
        XCTAssertTrue(discovery.accept("/old"))
        XCTAssertTrue(discovery.isReady)
        probe.state.withLock { $0.preference = "/new" }
        XCTAssertFalse(discovery.isReady)
        let completed = expectation(description: "New preference is validated")
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/new")
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(discovery.isReady)
        let cached = expectation(description: "Ready callers receive the cached path")
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/new")
            XCTAssertNil(error)
            cached.fulfill()
        }
        wait(for: [cached], timeout: 3)
        XCTAssertEqual(probe.state.withLock { $0.calls }, ["/old --version", "/new --version"])
    }

    func testObjectiveCFacadeDeliversTheValidatedPathOnTheMainQueue() {
        let completed = expectation(description: "Facade completion")
        PBGitBinary.whenAvailable { path, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(path)
            XCTAssertNil(error)
            XCTAssertEqual(path, PBGitBinary.path())
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testSupersededValidationCannotReplaceANewerValidatedSelection() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"], delayed: "/old")
        let discovery = probe.discovery()
        let completed = expectation(description: "Waiter follows the current generation")
        completed.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/new")
            XCTAssertNil(error)
            completed.fulfill()
        }
        probe.state.withLock { $0.preference = "/new" }
        discovery.start()
        probe.release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.path, "/new")
        XCTAssertEqual(discovery.version, "2.51.0")
        probe.release.signal()
        XCTAssertTrue(discovery.accept("/old"))
        XCTAssertEqual(discovery.path, "/old")
        XCTAssertFalse(discovery.accept("/missing"))
        XCTAssertEqual(discovery.path, "/old", "A failed explicit selection keeps the validated snapshot")
    }

    func testPreferenceChangesDuringPublicationRevalidateBeforeDeliveringWaiters() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"])
        let discovery = GitBinaryDiscovery(preference: { probe.state.withLock { $0.preference } }, environment: [:],
                                           output: { probe.output($0, $1) }, locations: [], notify: { selection, _ in
                                               if selection?.path == "/old" {
                                                   probe.state.withLock { $0.preference = "/new" }
                                               }
                                           })
        let completed = expectation(description: "Delivery follows the preference changed by publication")
        completed.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/new")
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.version, "2.51.0")
    }

    func testExplicitValidatedSelectionSettlesPendingWaitersAndSupersedesTheSearch() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"], delayed: "/old")
        let discovery = probe.discovery()
        let completed = expectation(description: "Explicit validation completes the pending caller once")
        completed.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/new")
            XCTAssertNil(error)
            completed.fulfill()
        }
        XCTAssertTrue(discovery.accept("/new"))
        probe.release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.path, "/new")
        XCTAssertEqual(discovery.version, "2.51.0")
    }

    func testEmbeddedToolReportsTheOwningApplicationVersion() throws {
        let tool = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
        let expected = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertEqual(try toolVersion(tool).output, "Half Dark version \(expected)\n")
    }

    @MainActor func testFolderDocumentTypeRoutesToRepositoryDocumentsWithoutTakingDefaultOwnership() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let folder = try XCTUnwrap(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.folder") == true })
        XCTAssertEqual(folder["NSDocumentClass"] as? String, "PBGitRepositoryDocument")
        XCTAssertEqual(folder["LSHandlerRank"] as? String, "Alternate")
        XCTAssertTrue(NSDocumentController.shared.documentClass(forType: "public.folder") == PBGitRepositoryDocument.self)
    }

    func testEmbeddedToolVersionRemainsLocalAndHasItsEstablishedOutputContract() throws {
        let tool = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
        let result = try toolVersion(tool)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.hasPrefix("Half Dark version "))
        XCTAssertTrue(result.output.hasSuffix("\n"))
    }

    func testToolVersionThroughASymlinkMatchesDirectInvocation() throws {
        let tool = try XCTUnwrap(Bundle.main.url(forResource: "gitx", withExtension: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("gitx with spaces")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        let direct = try toolVersion(tool)
        let linked = try toolVersion(link)
        XCTAssertEqual(linked.output, direct.output)
        XCTAssertEqual(linked.status, direct.status)
    }

    private func toolVersion(_ tool: URL) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    func testDiscoveryVersionAndFallbackErrorRemainAvailable() {
        XCTAssertFalse(PBGitBinary.searchLocations().isEmpty)
        XCTAssertNotNil(PBGitBinary.version())
        XCTAssertFalse(PBGitBinary.notFoundError().isEmpty)
    }
}
