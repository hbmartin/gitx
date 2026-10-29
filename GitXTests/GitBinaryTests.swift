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
        let sharedReady = expectation(description: "The document facade is ready independently of the injected gate")
        PBGitBinary.whenAvailable { path, error in
            XCTAssertNotNil(path)
            XCTAssertNil(error)
            sharedReady.fulfill()
        }
        wait(for: [sharedReady], timeout: 35)
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

    func testActiveSnapshotStaysReadyWhileANewPreferenceIsValidated() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"])
        let completed = expectation(description: "New preference is validated")
        let discovery = GitBinaryDiscovery(preference: { probe.state.withLock { $0.preference } }, environment: [:],
                                           output: { probe.output($0, $1) }, notify: { selection, _ in
                                               if selection?.path == "/new" {
                                                   completed.fulfill()
                                               }
                                           })
        XCTAssertTrue(discovery.accept("/old"))
        XCTAssertTrue(discovery.isReady)
        probe.state.withLock { $0.preference = "/new" }
        XCTAssertTrue(discovery.isReady)
        discovery.start()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(discovery.path, "/new")
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

    func testAvailabilityDeliveryKeepsItsSnapshotWhenPublicationRequestsAnotherPreference() {
        let probe = Probe(preference: "/old", outputs: ["/old": "git version 2.50.1", "/new": "git version 2.51.0"])
        let replaced = expectation(description: "Following validation publishes the new preference")
        let discovery = GitBinaryDiscovery(preference: { probe.state.withLock { $0.preference } }, environment: [:],
                                           output: { probe.output($0, $1) }, locations: [], notify: { selection, _ in
                                               if selection?.path == "/old" {
                                                   probe.state.withLock { $0.preference = "/new" }
                                               }
                                               if selection?.path == "/new" {
                                                   replaced.fulfill()
                                               }
                                           })
        let completed = expectation(description: "Availability delivers its immutable validated snapshot")
        completed.assertForOverFulfill = true
        discovery.whenAvailable { path, error in
            XCTAssertEqual(path, "/old")
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        discovery.start()
        wait(for: [replaced], timeout: 3)
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
        let ready = expectation(description: "The shared facade has finished initial discovery")
        PBGitBinary.whenAvailable { path, error in
            XCTAssertNotNil(path)
            XCTAssertNil(error)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        XCTAssertFalse(PBGitBinary.searchLocations().isEmpty)
        XCTAssertNotNil(PBGitBinary.version())
        XCTAssertFalse(PBGitBinary.notFoundError().isEmpty)
    }
}

/// Characterizes the Objective-C document before extracting its scripting decisions.
@MainActor
final class RepositoryDocumentScriptingCharacterizationTests: XCTestCase {
    private final class WindowProbe: GitX.PBGitWindowController {
        var actions: [String] = []
        override func showUncommittedChanges(_: Any?) {
            actions.append("commit")
        }

        override func showHistoryView(_: Any?) {
            actions.append("history")
        }

        override func showWindow(_: Any?) {
            actions.append("show")
        }

        override func setHistorySearch(_ text: String, mode: PBHistorySearchMode) {
            actions.append("search:\(text):\(mode.rawValue)")
        }
    }

    private var directory: URL!
    private var document: PBGitRepositoryDocument!
    private var window: WindowProbe!

    private func prepareFixture() throws {
        let ready = expectation(description: "Validated Git before document characterization")
        PBGitBinary.whenAvailable { path, error in
            XCTAssertNotNil(path)
            XCTAssertNil(error)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: directory)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "fixture"], in: directory)
        try GitXTestGitFixture.run(["branch", "topic"], in: directory)
        document = try PBGitRepositoryDocument(contentsOf: directory, ofType: PBGitRepositoryDocumentType)
        window = WindowProbe(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                              styleMask: [.titled], backing: .buffered, defer: false))
        document.addWindowController(window)
    }

    private func removeFixture(removeFiles: Bool = true) throws {
        document?.repository.revisionList?.cleanup()
        document?.repository.revisionList = nil
        document?.close()
        document = nil
        window = nil
        if let directory {
            if removeFiles {
                try FileManager.default.removeItem(at: directory)
            } else {
                NSLog("[GitDiscoveryTests] Retaining fixture until shared executable restoration succeeds: %@", directory.path)
            }
        }
        directory = nil
    }

    func testSupportedOptionsPreserveViewsFiltersAndRevisionArguments() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        for option in ["-c", "--commit"] {
            apply([option])
            XCTAssertEqual(window.actions.last, "commit")
        }
        for (option, filter) in [("--all", 0), ("--local", 1), ("--branch", 2)] {
            apply([option])
            XCTAssertEqual(document.repository.currentBranchFilter, filter)
            XCTAssertEqual(window.actions.last, "history")
        }
        apply(["topic"])
        XCTAssertEqual(document.repository.currentBranch?.description, "topic")
        apply(["--max-count=7", "HEAD"])
        XCTAssertEqual(document.repository.currentBranch?.parameters as? [String], ["--max-count=7", "HEAD"])
        let count = window.actions.count
        apply([])
        _ = document.perform(NSSelectorFromString("handleRevListArguments:"), with: [])
        XCTAssertEqual(window.actions.count, count)
    }

    func testBranchFiltersConsumeOnlyTheFlagAndPreserveFollowingRevisions() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        for (option, filter) in [("--all", 0), ("--local", 1), ("--branch", 2)] {
            apply([option, "topic"])
            XCTAssertEqual(document.repository.currentBranchFilter, filter)
            XCTAssertEqual(document.repository.currentBranch?.description, "topic")
            apply([option, "--max-count=7", "HEAD"])
            XCTAssertEqual(document.repository.currentBranch?.parameters as? [String], ["--max-count=7", "HEAD"])
        }
    }

    func testDocumentActionsAndPresentationRemainWired() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.displayName.contains("branch: main"))
        XCTAssertTrue(document.windowController() === window)
        document.showUncommittedChanges(self)
        document.showHistoryView(self)
        document.selectRevisionSpecifier(PBGitRevSpecifier(parameters: ["HEAD"]))
        XCTAssertEqual(window.actions, ["commit", "history", "history"])
        document.showWindows()
        XCTAssertEqual(window.actions.last, "show")
        XCTAssertEqual(window.window?.title, document.displayName)
        document.removeWindowController(window)
        XCTAssertNil(document.windowController())
        document.makeWindowControllers()
        XCTAssertEqual(document.windowControllers.count, 1)
    }

    func testCapturedScriptContextOnlyAppliesToItsOwnRepository() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let descriptions = try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "Standard Suite"))
        let description = try XCTUnwrap(descriptions["open"])
        let command = NSScriptCommand(commandDescription: description)
        command.arguments = ["openOptions": ["--commit"]]
        for parameter: Any in try ["not a URL", directory.appendingPathComponent("missing"), XCTUnwrap(directory)] {
            let previous = window.actions.filter { $0 == "commit" }.count
            command.directParameter = parameter
            let intent = RepositoryDocumentOpenIntent(command: command)
            if let arguments = intent.arguments(for: document) {
                RepositoryDocumentScripting.enqueue(arguments, for: document)
            }
            document.showWindows()
            XCTAssertEqual(window.actions.filter { $0 == "commit" }.count - previous, parameter as? URL == directory ? 1 : 0)
        }
    }

    func testDeferredOpenPreservesItsScriptingOptionsAfterTheCommandEnds() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let controller = GitX.PBRepositoryDocumentController()
        let release = DispatchSemaphore(value: 0)
        controller.gitDiscovery = GitBinaryDiscovery(preference: { "/usr/bin/git" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        })
        let descriptions = try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "Standard Suite"))
        let command = try NSScriptCommand(commandDescription: XCTUnwrap(descriptions["open"]))
        command.directParameter = directory
        command.arguments = ["openOptions": ["--commit"]]
        let method = try XCTUnwrap(class_getClassMethod(NSScriptCommand.self, NSSelectorFromString("currentCommand")))
        let original = method_getImplementation(method)
        let replacement: @convention(block) (AnyObject) -> NSScriptCommand? = { _ in command }
        let implementation = imp_implementationWithBlock(replacement)
        method_setImplementation(method, implementation)
        let opened = expectation(description: "Deferred open consumes its captured options")
        controller.openDocument(withContentsOf: directory, display: false) { incoming, _, error in
            XCTAssertNil(error)
            if let incoming = incoming as? PBGitRepositoryDocument {
                let probe = WindowProbe(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
                incoming.addWindowController(probe)
                incoming.showWindows()
                XCTAssertEqual(probe.actions.filter { $0 == "commit" }, ["commit"])
                incoming.showWindows()
                XCTAssertEqual(probe.actions.filter { $0 == "commit" }, ["commit"], "A captured open is consumed exactly once")
                incoming.repository.revisionList?.cleanup()
                incoming.repository.revisionList = nil
                incoming.close()
            } else {
                XCTFail("Expected a repository document")
            }
            opened.fulfill()
        }
        method_setImplementation(method, original)
        imp_removeBlock(implementation)
        release.signal()
        wait(for: [opened], timeout: 5)
    }

    func testAlreadyOpenRepositoryAndAliasBypassUnavailableDiscovery() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let controller = GitX.PBRepositoryDocumentController()
        controller.addDocument(document)
        defer { controller.removeDocument(document) }
        let calls = Mutex(0)
        controller.gitDiscovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in calls.withLock { $0 += 1 }; return nil })
        let alias = directory.appendingPathComponent("repository-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        for url in try [XCTUnwrap(directory), alias] {
            let completed = expectation(description: "Existing document is reused without Git discovery")
            controller.openDocument(withContentsOf: url, display: false) { incoming, alreadyOpen, error in
                XCTAssertTrue(incoming === self.document)
                XCTAssertTrue(alreadyOpen)
                XCTAssertNil(error)
                XCTAssertFalse(controller.hasPendingOpens)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertTrue(window.actions.isEmpty, "display=false must not present the existing document")
    }

    func testQueuedRequestsRemainPerDocumentAndAreDiscardedOnClose() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let otherURL = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        _ = try GitXTestGitFixture.run(["init"], in: otherURL)
        let other = try PBGitRepositoryDocument(contentsOf: otherURL, ofType: PBGitRepositoryDocumentType)
        let probe = WindowProbe(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        other.addWindowController(probe)
        defer { other.repository.revisionList?.cleanup(); other.repository.revisionList = nil; other.close() }
        RepositoryDocumentScripting.enqueue(["--commit"], for: document)
        RepositoryDocumentScripting.enqueue(["--all"], for: other)
        RepositoryDocumentScripting.enqueue(["--local"], for: document)
        other.showWindows()
        XCTAssertEqual(probe.actions, ["history", "show"])
        XCTAssertTrue(window.actions.isEmpty)
        document.showWindows()
        XCTAssertEqual(window.actions, ["commit", "history", "show"])
        document.showWindows()
        XCTAssertEqual(window.actions, ["commit", "history", "show", "show"])
        RepositoryDocumentScripting.enqueue(["--commit"], for: other)
        other.close()
        other.showWindows()
        XCTAssertEqual(probe.actions.filter { $0 == "commit" }.count, 0)
    }

    func testOpenWindowReplacesItsGitLoadersAndIgnoresChangesAfterClose() throws {
        try prepareFixture()
        var restoredSharedSelection = true
        defer { try? removeFixture(removeFiles: restoredSharedSelection) }
        let original = try XCTUnwrap(GitBinaryDiscovery.shared.currentSelection)
        // Preserve the basename required by Apple's Git tool shim.
        let replacement = directory.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: URL(fileURLWithPath: original.path))
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        XCTAssertEqual(actual.gitLoaderSelection, original)
        defer {
            let restored = PBGitBinary.accept(original.path)
            XCTAssertTrue(restored)
            XCTAssertEqual(PBGitBinary.path(), original.path)
            let deliveredRestoration = expectation(description: "Restoration notification drains before fixture deletion")
            DispatchQueue.main.async { deliveredRestoration.fulfill() }
            wait(for: [deliveredRestoration], timeout: 3)
            restoredSharedSelection = restored && PBGitBinary.path() == original.path
        }
        let accepted = PBGitBinary.accept(replacement.path)
        restoredSharedSelection = !accepted
        XCTAssertTrue(accepted)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.gitLoaderSelection?.path == replacement.path }, object: nil)
        wait(for: [changed], timeout: 5)
        actual.close()
        XCTAssertTrue(PBGitBinary.accept(original.path))
        let delivered = expectation(description: "Closed-window notification drains")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 3)
        // A notification already queued off-main may arrive after observer removal.
        let lateCallback = expectation(description: "Late background notification returns")
        DispatchQueue.global().async {
            actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
            lateCallback.fulfill()
        }
        wait(for: [lateCallback], timeout: 3)
        let lateDelivery = expectation(description: "Late loader update drains on main")
        DispatchQueue.main.async { lateDelivery.fulfill() }
        wait(for: [lateDelivery], timeout: 3)
        XCTAssertEqual(actual.gitLoaderSelection?.path, replacement.path, "A closed owner must not recreate loaders")
    }

    func testSearchCommandAndFilePresenterCallbacks() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let descriptions = try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "Standard Suite"))
        let command = try NSScriptCommand(commandDescription: XCTUnwrap(descriptions["open"]))
        command.arguments = [:]
        document.find(inModeScriptCommand: command)
        XCTAssertTrue(window.actions.isEmpty)
        command.arguments = ["searchString": "needle", "inMode": 0]
        document.find(inModeScriptCommand: command)
        XCTAssertEqual(window.actions.first, "history")
        XCTAssertTrue(window.actions.last?.hasPrefix("search:needle:") == true)
        let removed = expectation(description: "File-presenter deletion acknowledges closure")
        document.accommodatePresentedItemDeletion { error in
            XCTAssertNil(error)
            removed.fulfill()
        }
        wait(for: [removed], timeout: 5)
        document.presentedItemDidMove(to: directory.appendingPathComponent("moved"))
        let moved = expectation(description: "File-presenter move drains on main queue")
        DispatchQueue.main.async { moved.fulfill() }
        wait(for: [moved], timeout: 5)
    }

    func testReadRejectsShallowAndNonDirectoryInputsWithoutChangingTheirBytes() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let file = directory.appendingPathComponent("ordinary-file")
        try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try PBGitRepositoryDocument(contentsOf: file, ofType: PBGitRepositoryDocumentType))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        let malformed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: malformed) }
        XCTAssertThrowsError(try PBGitRepositoryDocument(contentsOf: malformed, ofType: PBGitRepositoryDocumentType))
        let head = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput
        let shallow = directory.appendingPathComponent(".git/shallow")
        try head.write(to: shallow, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PBGitRepositoryDocument(contentsOf: directory, ofType: PBGitRepositoryDocumentType)) { error in
            XCTAssertFalse((error as NSError).localizedRecoveryOptions?.isEmpty ?? true)
        }
        XCTAssertEqual(try String(contentsOf: shallow, encoding: .utf8), head)
        document.applyGitXOpenArguments(nil)
        XCTAssertTrue(window.actions.isEmpty)
    }

    func testOverlappingColdOpensKeepCopiedOptionsWithTheirOwnRepositories() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let other = directory.appendingPathComponent("overlapping")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: other)
        _ = try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "other"], in: other)
        _ = try GitXTestGitFixture.run(["branch", "topic"], in: other)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = GitX.PBRepositoryDocumentController()
        controller.gitDiscovery = GitBinaryDiscovery(preference: { "/usr/bin/git" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        })
        let descriptions = try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "Standard Suite"))
        let description = try XCTUnwrap(descriptions["open"])
        let completed = expectation(description: "Both captured requests open their matching repository")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        for (url, options) in try [(XCTUnwrap(directory), ["--commit"]), (other, ["--branch", "topic"])] {
            let command = NSScriptCommand(commandDescription: description)
            command.directParameter = url
            let mutable = NSMutableArray(array: options)
            command.arguments = ["openOptions": mutable]
            try withCurrentCommand(command) {
                controller.openDocument(withContentsOf: url, display: false) { incoming, _, error in
                    XCTAssertNil(error)
                    if let incoming = incoming as? PBGitRepositoryDocument {
                        let probe = WindowProbe(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
                        incoming.addWindowController(probe)
                        XCTAssertTrue(probe.actions.isEmpty, "Delayed display keeps the request queued")
                        incoming.showWindows()
                        if url == other {
                            XCTAssertEqual(incoming.repository.currentBranchFilter, 2)
                            XCTAssertEqual(incoming.repository.currentBranch?.description, "topic")
                            XCTAssertFalse(probe.actions.contains("commit"))
                        } else {
                            XCTAssertEqual(probe.actions, ["commit", "show"])
                        }
                        incoming.repository.revisionList?.cleanup()
                        incoming.repository.revisionList = nil
                        incoming.close()
                        controller.removeDocument(incoming)
                    } else {
                        XCTFail("Expected a repository document")
                    }
                    completed.fulfill()
                }
            }
            mutable.removeAllObjects()
            mutable.add("--all")
        }
        release.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(controller.hasPendingOpens)
    }

    func testExplicitOpenRetriesACompletedColdDiscoveryFailure() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let works = Mutex(false)
        let controller = GitX.PBRepositoryDocumentController()
        controller.gitDiscovery = GitBinaryDiscovery(preference: { "/usr/bin/git" }, environment: [:], output: { path, _ in
            works.withLock { $0 && path == "/usr/bin/git" ? "git version 2.50.1" : nil }
        }, locations: [])
        let failed = expectation(description: "Cold failure releases the pending open")
        controller.openDocument(withContentsOf: directory, display: false) { incoming, _, error in
            XCTAssertNil(incoming)
            XCTAssertNotNil(error)
            XCTAssertFalse(controller.hasPendingOpens)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        works.withLock { $0 = true }
        let retried = expectation(description: "A later explicit open retries the same preference")
        controller.openDocument(withContentsOf: directory, display: false) { incoming, _, error in
            XCTAssertNotNil(incoming)
            XCTAssertNil(error)
            incoming?.close()
            if let incoming {
                controller.removeDocument(incoming)
            }
            retried.fulfill()
        }
        wait(for: [retried], timeout: 5)
        XCTAssertFalse(controller.hasPendingOpens)
    }

    func testWindowDefersGitLoadersUntilItsIsolatedDiscoverySucceeds() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discovery = GitBinaryDiscovery(preference: { "/usr/bin/git" }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        }, notify: { _, _ in NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil) })
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        actual.gitDiscovery = discovery
        _ = actual.window
        XCTAssertNotNil(actual.historyViewController)
        XCTAssertEqual(actual.window?.representedURL, document.repository.workingDirectoryURL())
        XCTAssertNil(actual.gitLoaderSelection)
        let ready = expectation(description: "The isolated selection becomes available")
        discovery.whenAvailable { _, error in XCTAssertNil(error); ready.fulfill() }
        release.signal()
        wait(for: [ready], timeout: 3)
        let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.gitLoaderSelection?.path == "/usr/bin/git" }, object: nil)
        wait(for: [installed], timeout: 3)
        actual.close()
        let background = expectation(description: "A background notification reaches a closed owner safely")
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil)
            DispatchQueue.main.async { background.fulfill() }
        }
        wait(for: [background], timeout: 3)
    }

    private func withCurrentCommand(_ command: NSScriptCommand, body: () -> Void) throws {
        let method = try XCTUnwrap(class_getClassMethod(NSScriptCommand.self, NSSelectorFromString("currentCommand")))
        let original = method_getImplementation(method)
        let replacement: @convention(block) (AnyObject) -> NSScriptCommand? = { _ in command }
        let implementation = imp_implementationWithBlock(replacement)
        method_setImplementation(method, implementation)
        defer { method_setImplementation(method, original); imp_removeBlock(implementation) }
        body()
    }

    private func apply(_ arguments: [String]) {
        document.applyGitXOpenArguments(arguments)
    }
}
