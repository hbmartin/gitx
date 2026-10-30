import AppKit
@testable import GitX
import ObjectiveGit
import Synchronization
import XCTest

/// File-coordination may release a closed document on its own queue.
/// Clear main-actor history ownership before that asynchronous release.
@MainActor
private func closeRepositoryFixtureDocument(_ document: NSDocument?) {
    if let repositoryDocument = document as? PBGitRepositoryDocument {
        repositoryDocument.repository.revisionList?.cleanup()
        repositoryDocument.repository.revisionList = nil
    }
    document?.close()
}

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
            closeRepositoryFixtureDocument(document)
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
    // swift6-safety-justification: Only immutable identity is transferred to NotificationCenter; repository access remains on the main actor.
    private final nonisolated class RepositoryNotificationFixture: @unchecked Sendable {
        let value: PBGitRepository
        init(_ value: PBGitRepository) {
            self.value = value
        }
    }

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

    /// Legacy Objective-C subclasses can supply repository identity without the base setter.
    private final class RepositoryOverrideWindowProbe: GitX.PBGitWindowController {
        private var suppliedRepository: PBGitRepository?
        override var repository: PBGitRepository? {
            get { suppliedRepository }
            set { suppliedRepository = newValue }
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
            var identities = RepositoryGitDirectoryIdentity()
            if let arguments = intent.arguments(for: document, identities: &identities) {
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
                closeRepositoryFixtureDocument(incoming)
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

    func testDocumentRegisteredDuringDiscoveryIsReusedBeforeSuccessOrFailure() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        let descriptions = try XCTUnwrap(NSScriptSuiteRegistry.shared().commandDescriptions(inSuite: "Standard Suite"))
        let description = try XCTUnwrap(descriptions["open"])
        for succeeds in [true, false] {
            window.actions = []
            let controller = GitX.PBRepositoryDocumentController()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            controller.gitDiscovery = GitBinaryDiscovery(preference: { "/delayed" }, environment: [:], output: { path, _ in
                if path == "/delayed" {
                    _ = release.wait(timeout: .now() + 10)
                    return succeeds ? "git version 2.50.1" : nil
                }
                return nil
            }, locations: [])
            let opened = expectation(description: "Overlapping requests reuse a document registered during discovery")
            opened.expectedFulfillmentCount = 2
            opened.assertForOverFulfill = true
            for _ in 0 ..< 2 {
                let command = NSScriptCommand(commandDescription: description)
                command.directParameter = directory
                command.arguments = ["openOptions": ["--commit"]]
                try withCurrentCommand(command) {
                    controller.openDocument(withContentsOf: gitDirectory, display: false) { incoming, alreadyOpen, error in
                        XCTAssertTrue(incoming === self.document)
                        XCTAssertTrue(alreadyOpen)
                        XCTAssertNil(error, "Discovery failure cannot hide a repository that is already open")
                        if incoming !== self.document {
                            closeRepositoryFixtureDocument(incoming)
                        }
                        opened.fulfill()
                    }
                }
            }
            XCTAssertTrue(controller.hasPendingOpens)
            // Different URLs bypass AppKit's exact-URL shortcut but name the same Git directory.
            controller.addDocument(document)
            release.signal()
            wait(for: [opened], timeout: 5)
            XCTAssertEqual(controller.documents.count, 1)
            XCTAssertFalse(controller.hasPendingOpens)
            XCTAssertTrue(window.actions.isEmpty, "display=false keeps scripting requests pending")
            document.showWindows()
            XCTAssertEqual(window.actions.filter { $0 == "commit" }, ["commit", "commit"])
            document.showWindows()
            XCTAssertEqual(window.actions.filter { $0 == "commit" }.count, 2)
            controller.removeDocument(document)
        }
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
        XCTAssertNil(actual.gitLoaderSelection, "A closed owner must not report an installation")
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
                        closeRepositoryFixtureDocument(incoming)
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
            closeRepositoryFixtureDocument(incoming)
            if let incoming {
                controller.removeDocument(incoming)
            }
            retried.fulfill()
        }
        wait(for: [retried], timeout: 5)
        XCTAssertFalse(controller.hasPendingOpens)
    }

    func testWindowDefersGitLoadersUntilItsIsolatedDiscoverySucceeds() throws {
        try verifyDeferredLoaderInstallation(activationBeforeNotification: false)
    }

    func testInstalledRepositoryNotificationsRefreshRenderedStatus() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)

        try Data("pending\n".utf8).write(to: directory.appendingPathComponent("pending.txt"), options: .atomic)
        NotificationCenter.default.post(name: Notification.Name(PBGitIndexIndexUpdated), object: document.repository.index)
        let dirty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.localStatusText("GitX.RepositoryStatusBar.LocalCounts", in: actual.window?.contentView)?.contains("1 untracked") == true
        }, object: nil)
        wait(for: [dirty], timeout: 5)

        try GitXTestGitFixture.run(["checkout", "topic"], in: directory)
        NotificationCenter.default.post(name: .repositoryRemoteOperationDidSucceed, object: document.repository, userInfo: ["operation": "push"])
        waitForBranch("topic", in: actual)
    }

    func testRemovingRepositoryImmediatelyClearsRenderedStatusAndInstallation() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        document.removeWindowController(actual)
        XCTAssertNil(actual.gitLoaderSelection)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "Repository")
    }

    func testWindowRoundTripReinstallsLoadersWithoutAnotherActivation() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        let originalWindow = try XCTUnwrap(actual.window)
        defer { actual.window = originalWindow; actual.close() }
        waitForBranch("main", in: actual)
        let history = actual.historyViewController
        let sidebar = actual.sidebarViewController
        actual.window = nil
        XCTAssertNil(actual.gitLoaderSelection)
        let empty = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        actual.window = empty
        actual.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: originalWindow))
        actual.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: originalWindow))
        XCTAssertNotNil(actual.gitLoaderSelection, "A replaced window's late delegate callback cannot close the current owner")
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertTrue(actual.sidebarViewController === sidebar)
        XCTAssertNil(localBranch(in: empty.contentView), "Outlets belonging to the old window cannot render in an empty replacement")
        actual.window = originalWindow
        empty.close()
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertTrue(actual.sidebarViewController === sidebar)
        try GitXTestGitFixture.run(["checkout", "topic"], in: directory)
        NotificationCenter.default.post(name: Notification.Name(PBGitIndexIndexUpdated), object: document.repository.index)
        waitForBranch("topic", in: actual)
    }

    func testActivationBeforeSelectionNotificationInstallsBothLoadersAndRendersStatus() throws {
        try verifyDeferredLoaderInstallation(activationBeforeNotification: true)
    }

    func testSelectionNotificationReconcilesAnObjectiveCDerivedWindowOwner() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let owner = PBHistoryWindowControllerTestBase(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        let actual = try XCTUnwrap((owner as AnyObject) as? GitX.PBGitWindowController)
        defer { actual.close() }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" }, notify: { _, _ in })
        actual.gitDiscovery = discovery
        document.removeWindowController(window)
        document.addWindowController(owner)
        XCTAssertNil(actual.gitLoaderSelection)
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil)
        XCTAssertEqual(actual.gitLoaderSelection?.path, "/usr/bin/git")
        let delivered = expectation(description: "A background selection event also reconciles the Objective-C-derived owner")
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil)
            DispatchQueue.main.async { delivered.fulfill() }
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(actual.gitLoaderSelection?.path, "/usr/bin/git")
        actual.close()
        NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil)
        XCTAssertNil(actual.gitLoaderSelection)
    }

    func testPreferenceNotificationWaitsForPublisherToReturnBeforeUpdatingWindow() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousVisibility = ApplicationSettings.repositoryStatusBarVisible
        ApplicationSettings.repositoryStatusBarVisible = true
        defer { ApplicationSettings.repositoryStatusBarVisible = previousVisibility }
        let notifications = NotificationCenter()
        document.removeWindowController(window)
        let actual = GitX.PBGitWindowController(ownerNotifications: notifications)
        document.addWindowController(actual)
        defer { actual.close() }
        let content = try XCTUnwrap(actual.window?.contentView)
        let bar = try XCTUnwrap(content.subviews.first { $0.accessibilityIdentifier() == "GitX.RepositoryStatusBar" })
        XCTAssertFalse(bar.isHidden)
        ApplicationSettings.repositoryStatusBarVisible = false
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        XCTAssertFalse(bar.isHidden, "A settings publisher may still hold a repository lock until its notification returns")
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bar.isHidden }, object: nil)
        wait(for: [updated], timeout: 5)
        ApplicationSettings.repositoryStatusBarVisible = true
        XCTAssertTrue(bar.isHidden, "The isolated notification source must not reconcile an unannounced preference")
        let background = expectation(description: "The compatibility preference selector returns without blocking its publisher")
        DispatchQueue.global().async {
            actual.refreshPreferenceDidChange(nil)
            background.fulfill()
        }
        wait(for: [background], timeout: 5)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !bar.isHidden }, object: nil)
        wait(for: [shown], timeout: 5)
    }

    func testOverriddenRepositoryIdentityReconcilesAndSelectionLossClearsStatus() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try GitXTestGitFixture.run(["init", "--initial-branch=override-owner"], in: other)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "other owner"], in: other)
        let replacement = try XCTUnwrap(PBGitRepository(url: other))
        defer { replacement.revisionList?.cleanup(); replacement.revisionList = nil }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" }, notify: { _, _ in })
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        let actual = RepositoryOverrideWindowProbe()
        actual.gitDiscovery = discovery
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        let previousHistory = actual.historyViewController
        actual.repository = replacement
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        waitForBranch("override-owner", in: actual)
        XCTAssertFalse(actual.historyViewController === previousHistory)
        XCTAssertTrue(actual.historyViewController?.repository === replacement)
        actual.gitDiscovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in nil }, notify: { _, _ in })
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        XCTAssertNil(actual.gitLoaderSelection)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "Repository")
    }

    func testLegacyRepositoryCancellationAndBareIgnoreFailurePreserveRepositoryBytes() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let bare = directory.appendingPathComponent("bare.git")
        try GitXTestGitFixture.run(["init", "--bare", bare.path], in: directory)
        let repository = try XCTUnwrap(PBGitRepository(url: bare))
        defer { repository.revisionList?.cleanup(); repository.revisionList = nil }
        let head = try Data(contentsOf: bare.appendingPathComponent("HEAD"))
        repository.cancelWorktreeDiscovery()
        XCTAssertThrowsError(try repository.ignoreFilePaths(["must-not-write.txt"])) { error in
            XCTAssertEqual((error as NSError).localizedFailureReason, "This repository does not have a working directory.")
        }
        XCTAssertEqual(try Data(contentsOf: bare.appendingPathComponent("HEAD")), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent(".gitignore").path))
        XCTAssertNil(PBGitRepository().indexURL, "A placeholder cannot provide an index URL")
    }

    func testRemoteDescriptorCacheReusesOnlyCompleteDiscovery() {
        let loader = GitX.RepositoryForgeRemoteDescriptorLoader(cache: GitX.RepositoryForgeRemoteDescriptorCache())
        let unavailable = loader.load(cacheKey: "owner", revision: "1", remoteNames: { nil }, remoteURL: { _ in nil })
        XCTAssertFalse(unavailable.isCacheable)
        let partial = loader.load(cacheKey: "owner", revision: "1", remoteNames: { ["z", "a"] }, remoteURL: { $0 == "a" ? "https://example.com/a" : nil })
        XCTAssertFalse(partial.isCacheable)
        XCTAssertEqual(partial.descriptors.map(\.name), ["a"])
        let complete = loader.load(cacheKey: "owner", revision: "1", remoteNames: { ["z", "a"] }, remoteURL: { "https://example.com/" + $0 }, dependencyPaths: { ["owned-config"] })
        XCTAssertTrue(complete.isCacheable)
        XCTAssertFalse(complete.reusedCache)
        XCTAssertEqual(complete.descriptors.map(\.name), ["a", "z"])
        let cached = loader.load(cacheKey: "owner", revision: "1", remoteNames: { XCTFail("A complete unchanged discovery must be reused"); return nil }, remoteURL: { _ in XCTFail("Cached descriptors need no lookup"); return nil })
        XCTAssertTrue(cached.reusedCache)
        XCTAssertEqual(cached.descriptors, complete.descriptors)
    }

    func testToolbarAccountNotificationClearsAnObsoleteProviderAndLogin() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let owner = GitX.PBGitWindowController(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        owner.repository = document.repository
        defer { owner.close() }
        let controller = GitX.RepositoryToolbarController(windowController: owner)
        let toolbar = NSToolbar(identifier: "GitX.Test.AccountReplacement")
        let item = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount"), willBeInsertedIntoToolbar: true))
        let popup = try XCTUnwrap(item.view?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository,
                                        userInfo: [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub", GitX.RepositoryForgeAccountNotificationKey.login: "prior-owner"])
        XCTAssertEqual(popup.titleOfSelectedItem, "@prior-owner")
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository)
        XCTAssertEqual(popup.titleOfSelectedItem, "Forge")
        XCTAssertEqual(item.toolTip, "Configure a Forge account")
    }

    func testAdmittedOrdinaryPushFinishesAfterItsWindowDeallocates() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let remote = directory.appendingPathComponent("push-target.git")
        try GitXTestGitFixture.run(["init", "--bare", remote.path], in: directory)
        try GitXTestGitFixture.run(["remote", "add", "origin", remote.path], in: directory)
        let nativeWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var pending: (@Sendable () throws -> Void)?
        var finished: ((NSError?) -> Void)?
        var admissions = 0
        var owner: GitX.PBGitWindowController? = GitX.PBGitWindowController(window: nativeWindow, remoteProgressStarting: { _, _, operation, completion in
            admissions += 1
            pending = operation
            finished = completion
            return true
        })
        weak let weakOwner = owner
        owner?.repository = document.repository
        owner?.pullRequestUIController?.invalidateOwner()
        owner?.pullRequestUIController = nil
        owner?.updateCreatePullRequestControl(GitX.ForgeMutationControlPresentation(isVisible: true, isEnabled: true, helpText: nil))
        owner?.ensureActionCoordinators()
        let ui = try XCTUnwrap(owner?.pullRequestUIController)
        let branch = PBGitRef(string: "refs/heads/main")
        let destination = PBGitRef(string: "refs/remotes/origin")
        ui.performPush(branch: branch, remote: destination, requiresConfirmation: false)
        XCTAssertEqual(admissions, 1)
        let operation = try XCTUnwrap(pending)
        pending = nil
        autoreleasepool { owner = nil }
        let deallocated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in weakOwner == nil }, object: nil)
        wait(for: [deallocated], timeout: 5)
        let executed = expectation(description: "Admitted push writes only to its original repository")
        let failure = Mutex<Error?>(nil)
        DispatchQueue.global().async {
            do { try operation() } catch { failure.withLock { $0 = error } }
            executed.fulfill()
        }
        wait(for: [executed], timeout: 10)
        XCTAssertNil(failure.withLock { $0 })
        finished?(failure.withLock { $0 as NSError? })
        finished = nil
        ui.performPush(branch: branch, remote: destination, requiresConfirmation: false)
        XCTAssertEqual(admissions, 1, "A retained UI coordinator cannot admit another write after owner deallocation")
        XCTAssertEqual(try GitXTestGitFixture.run(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"], in: directory).standardOutput,
                       try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput)
    }

    private func verifyDeferredLoaderInstallation(activationBeforeNotification: Bool) throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(true, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        let controls = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controls) }
        let executable = controls.appendingPathComponent("git")
        let commands = controls.appendingPathComponent("commands")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(commands.path)'\nexec /usr/bin/git \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let notifications = NotificationCenter()
        let discovery = GitBinaryDiscovery(preference: { executable.path }, environment: [:], output: { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return "git version 2.50.1"
        }, notify: { _, _ in
            if !activationBeforeNotification {
                notifications.post(name: .PBGitBinaryDidChange, object: nil)
            }
        })
        document.removeWindowController(window)
        let actual = GitX.PBGitWindowController(ownerNotifications: notifications)
        actual.gitDiscovery = discovery
        document.addWindowController(actual)
        _ = actual.window
        XCTAssertNotNil(actual.historyViewController)
        XCTAssertEqual(actual.window?.representedURL, document.repository.workingDirectoryURL())
        XCTAssertNil(actual.gitLoaderSelection)
        let ready = expectation(description: "The isolated selection becomes available")
        discovery.whenAvailable { _, error in XCTAssertNil(error); ready.fulfill() }
        release.signal()
        wait(for: [ready], timeout: 3)
        if activationBeforeNotification {
            actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            notifications.post(name: .PBGitBinaryDidChange, object: nil)
        }
        let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.gitLoaderSelection?.path == executable.path }, object: nil)
        wait(for: [installed], timeout: 3)
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.localBranch(in: actual.window?.contentView) == "main"
        }, object: nil)
        wait(for: [rendered], timeout: 5)
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: commands, encoding: .utf8))?.contains("for-each-ref --format=") == true
        }, object: nil)
        wait(for: [focus], timeout: 5)
        XCTAssertEqual(try String(contentsOf: commands, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("for-each-ref ") }.count, 1,
                       "The installation activation must not start and cancel a redundant initial focus capture")

        XCTAssertTrue((try? String(contentsOf: commands, encoding: .utf8))?.contains("status --porcelain=v2 --branch -z --untracked-files=normal") == true)
        actual.close()
        let background = expectation(description: "A background notification reaches a closed owner safely")
        DispatchQueue.global().async {
            notifications.post(name: .PBGitBinaryDidChange, object: nil)
            DispatchQueue.main.async { background.fulfill() }
        }
        wait(for: [background], timeout: 3)
    }

    func testLoaderReplacementAndRepositoryChangeRenderOnlyTheCurrentOwner() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        let controls = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controls) }
        let commands = controls.appendingPathComponent("commands")
        let first = controls.appendingPathComponent("first-git")
        let second = controls.appendingPathComponent("second-git")
        for (executable, label) in [(first, "first"), (second, "second")] {
            try "#!/bin/sh\nprintf '\(label) %s\\n' \"$*\" >> '\(commands.path)'\nexec /usr/bin/git \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" },
                                           notify: { _, _ in NotificationCenter.default.post(name: .PBGitBinaryDidChange, object: nil) })
        XCTAssertTrue(discovery.accept(first.path))
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        actual.gitDiscovery = discovery
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        try GitXTestGitFixture.run(["checkout", "topic"], in: directory)
        XCTAssertTrue(discovery.accept(second.path))
        waitForBranch("topic", in: actual)
        XCTAssertTrue(try String(contentsOf: commands, encoding: .utf8).contains("second status --porcelain=v2 --branch -z --untracked-files=normal"))

        let other = controls.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=other-owner"], in: other)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "other"], in: other)
        let replacementRepository = try XCTUnwrap(PBGitRepository(url: other))
        defer { replacementRepository.revisionList?.cleanup(); replacementRepository.revisionList = nil }
        document.removeWindowController(actual)
        actual.repository = replacementRepository
        waitForBranch("other-owner", in: actual)
        actual.close()
        let before = try String(contentsOf: commands, encoding: .utf8)
        XCTAssertTrue(discovery.accept(first.path))
        actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let drained = expectation(description: "Closed owner rejects late activation and selection delivery")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertNil(actual.gitLoaderSelection)
        XCTAssertEqual(try String(contentsOf: commands, encoding: .utf8), before)
    }

    func testRepositoryReplacementRebindsPanesActionsAndActualRepositoryNotifications() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try GitXTestGitFixture.run(["init", "--initial-branch=replacement"], in: other)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "replacement"], in: other)
        try GitXTestGitFixture.run(["branch", "replacement-topic"], in: other)
        let replacement = try XCTUnwrap(PBGitRepository(url: other))
        defer { replacement.revisionList?.cleanup(); replacement.revisionList = nil }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        let oldHistory = actual.historyViewController
        let oldSidebar = actual.sidebarViewController
        let oldFactsInspector = try XCTUnwrap(oldHistory?.view.subviews.first {
            $0.accessibilityIdentifier() == "GitX.History.RepositoryFactsInspector"
        }, "Initial History must attach the window's Forge session")
        document.removeWindowController(actual)
        actual.repository = replacement
        waitForBranch("replacement", in: actual)
        XCTAssertFalse(actual.historyViewController === oldHistory)
        XCTAssertFalse(actual.sidebarViewController === oldSidebar)
        XCTAssertTrue(actual.historyViewController?.repository === replacement)
        XCTAssertTrue(actual.sidebarViewController?.repository === replacement)
        let replacementFactsInspector = try XCTUnwrap(actual.historyViewController?.view.subviews.first {
            $0.accessibilityIdentifier() == "GitX.History.RepositoryFactsInspector"
        }, "Replacement History must attach the replacement Forge session")
        XCTAssertFalse(replacementFactsInspector === oldFactsInspector)
        XCTAssertFalse(actual.isUncommittedChangesSelected)
        attachScreenshot(of: actual.window?.contentView, named: "Replacement repository owns History sidebar and status")
        try "replacement bytes".write(to: other.appendingPathComponent("pending.txt"), atomically: true, encoding: .utf8)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.localStatusText("GitX.RepositoryStatusBar.LocalCounts", in: actual.window?.contentView)?.contains("1 untracked") == true
        }, object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(PBGitIndexIndexUpdated), object: replacement.index)
        wait(for: [refreshed], timeout: 5)
        let checkout = NSMenuItem()
        checkout.representedObject = PBGitRef(string: "refs/heads/replacement-topic")
        actual.checkout(checkout)
        waitForBranch("replacement-topic", in: actual)
        XCTAssertEqual(try GitXTestGitFixture.run(["branch", "--show-current"], in: other).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "replacement-topic")
        XCTAssertEqual(try GitXTestGitFixture.run(["branch", "--show-current"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "main")
        try GitXTestGitFixture.run(["checkout", "replacement"], in: other)
        let notified = expectation(description: "A background event from the replacement repository is delivered")
        let repositoryBox = RepositoryNotificationFixture(replacement)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .repositoryRemoteOperationDidSucceed, object: repositoryBox.value, userInfo: ["operation": "push"])
            notified.fulfill()
        }
        wait(for: [notified], timeout: 3)
        waitForBranch("replacement", in: actual)
        // If an obsolete subscription survived, this event would reveal the unannounced checkout.
        try GitXTestGitFixture.run(["checkout", "replacement-topic"], in: other)
        NotificationCenter.default.post(name: NSNotification.Name(PBGitIndexIndexUpdated), object: document.repository.index)
        NotificationCenter.default.post(name: .repositoryRemoteOperationDidSucceed, object: document.repository, userInfo: ["operation": "fetch"])
        let drained = expectation(description: "Obsolete notifications drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "replacement")
        NotificationCenter.default.post(name: NSNotification.Name(PBGitIndexIndexUpdated), object: replacement.index)
        waitForBranch("replacement-topic", in: actual)
        let linked = other.appendingPathExtension("linked")
        defer { try? FileManager.default.removeItem(at: linked) }
        try GitXTestGitFixture.run(["worktree", "add", "-b", "replacement-linked", linked.path], in: other)
        replacement.refreshWorktrees()
        let resolvedLinked = try XCTUnwrap(realpath(linked.path, nil))
        defer { free(resolvedLinked) }
        let linkedIdentity = Data(String(cString: resolvedLinked).utf8)
        let inventory = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let sidebar = actual.sidebarViewController,
                  let group = sidebar.items.compactMap({ $0 as? PBSourceViewItem }).first(where: { $0.title == "WORKTREES" }) else { return false }
            sidebar.sourceView?.expandItem(group)
            return group.sortedChildren.contains {
                $0.responds(to: NSSelectorFromString("identity")) && $0.value(forKey: "identity") as? Data == linkedIdentity &&
                    $0.ref()?.ref == "refs/heads/replacement-linked"
            }
        }, object: nil)
        wait(for: [inventory], timeout: 10)
        if let group = actual.sidebarViewController?.items.compactMap({ $0 as? PBSourceViewItem }).first(where: { $0.title == "WORKTREES" }) {
            for item in group.sortedChildren where item.responds(to: NSSelectorFromString("identity")) {
                let identity = item.value(forKey: "identity") as? Data ?? Data()
                NSLog("[GitDiscoveryTests] Observed worktree row %@ identity %@ (expected %@)", item.ref()?.ref ?? "none",
                      String(decoding: identity, as: UTF8.self), String(decoding: linkedIdentity, as: UTF8.self))
            }
        }
        XCTAssertTrue(actual.sidebarViewController?.repository === replacement)
        attachScreenshot(of: actual.window?.contentView, named: "Replacement repository worktree inventory")
    }

    func testAdmittedFetchKeepsItsRepositoryWhileReplacementRevokesFurtherAdmission() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let remote = fixtures.appendingPathComponent("remote.git")
        try GitXTestGitFixture.run(["init", "--bare", remote.path], in: directory)
        try GitXTestGitFixture.run(["remote", "add", "origin", remote.path], in: directory)
        try GitXTestGitFixture.run(["push", "origin", "HEAD:refs/heads/from-remote"], in: directory)
        try GitXTestGitFixture.run(["update-ref", "-d", "refs/remotes/origin/from-remote"], in: directory)
        let other = fixtures.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=replacement"], in: other)
        let replacement = try XCTUnwrap(PBGitRepository(url: other))
        defer { replacement.revisionList?.cleanup(); replacement.revisionList = nil }
        let owner = GitX.PBGitWindowController(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        owner.repository = document.repository
        defer { owner.close() }
        var pending: (@Sendable () throws -> Void)?
        var completion: ((NSError?) -> Void)?
        var admissions = 0
        let coordinator = GitX.RepositoryRemoteActionCoordinator(repository: document.repository, windowController: owner, progressStarting: { _, _, operation, finished in
            admissions += 1; pending = operation; completion = finished; return true
        })
        coordinator.performFetch(for: nil)
        XCTAssertEqual(admissions, 1)
        owner.repository = replacement
        coordinator.performFetch(for: nil)
        XCTAssertEqual(admissions, 1, "The old coordinator cannot admit another mutation")
        let operation = try XCTUnwrap(pending)
        let executed = expectation(description: "The admitted fetch drains on its original repository")
        let failure = Mutex<Error?>(nil)
        DispatchQueue.global().async {
            do { try operation() } catch { failure.withLock { $0 = error } }
            executed.fulfill()
        }
        wait(for: [executed], timeout: 10)
        XCTAssertNil(failure.withLock { $0 })
        completion?(failure.withLock { $0 as NSError? })
        XCTAssertEqual(try GitXTestGitFixture.run(["rev-parse", "refs/remotes/origin/from-remote"], in: directory).standardOutput,
                       try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput)
        XCTAssertTrue(try GitXTestGitFixture.run(["for-each-ref", "refs/remotes"], in: other).standardOutput.isEmpty)
    }

    func testProgrammaticControllerDeallocationCancelsAndReapsItsOwnedStatusProcess() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        let controls = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        let gate = controls.appendingPathComponent("gate")
        let marker = controls.appendingPathComponent("pid")
        let executable = controls.appendingPathComponent("git")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0)
        let descriptor = open(gate.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var released = false
        defer {
            if !released {
                _ = Darwin.close(descriptor)
            }
            if let pid = (try? String(contentsOf: marker, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: controls)
            } else {
                XCTFail("Retained owned process controls at \(controls.path) because exit was not proven")
            }
        }
        try "#!/bin/sh\nif [ \"$1\" = status ]; then\n  printf '%s\\n' \"$$\" > '\(marker.path).pending'\n  /bin/mv '\(marker.path).pending' '\(marker.path)'\n  exec /bin/cat '\(gate.path)'\nfi\nexec /usr/bin/git \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" })
        XCTAssertTrue(discovery.accept(executable.path))
        let nativeWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        var owner: GitX.PBGitWindowController? = GitX.PBGitWindowController(window: nativeWindow)
        weak let weakOwner = owner
        owner?.gitDiscovery = discovery
        owner?.repository = document.repository
        XCTAssertNil(owner?.historyViewController, "An empty programmatic window must not acquire repository panes")
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) }, object: nil)
        wait(for: [started], timeout: 5)
        let pid = try XCTUnwrap(try Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        autoreleasepool { owner = nil }
        let destroyed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in weakOwner == nil }, object: nil)
        wait(for: [destroyed], timeout: 3)
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in kill(pid, 0) == -1 && errno == ESRCH }, object: nil)
        let result = XCTWaiter.wait(for: [reaped], timeout: 5)
        _ = Darwin.close(descriptor); released = true
        XCTAssertEqual(result, .completed, "Deinitialization must cancel owned reads without needing a window delegate")
        let cleanup = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in kill(pid, 0) == -1 && errno == ESRCH }, object: nil)
        wait(for: [cleanup], timeout: 5)
    }

    func testReplacedStatusTaskCannotPublishItsLateOutput() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previousRefresh = UserDefaults.standard.object(forKey: "PBRefreshOnApplicationFocus")
        UserDefaults.standard.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer { UserDefaults.standard.set(previousRefresh, forKey: "PBRefreshOnApplicationFocus") }
        let controls = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        var controlsCanBeRemoved = true
        defer {
            if controlsCanBeRemoved {
                try? FileManager.default.removeItem(at: controls)
            } else {
                NSLog("[GitDiscoveryTests] Retaining unproven process controls: %@", controls.path)
            }
        }
        let executable = controls.appendingPathComponent("delayed-git")
        let started = controls.appendingPathComponent("started")
        let finished = controls.appendingPathComponent("finished")
        let captured = controls.appendingPathComponent("captured")
        let gate = controls.appendingPathComponent("gate")
        let captureLease = controls.appendingPathComponent("capture-lease")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0)
        // Own both FIFO ends so release is buffered even before the child reaches read.
        let gateDescriptor = open(gate.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(gateDescriptor, 0)
        defer { close(gateDescriptor) }
        _ = fcntl(gateDescriptor, F_SETNOSIGPIPE, 1)
        // Preserve old status bytes, then deliberately finish after replacement.
        // This owned process ignores SIGTERM so cancellation cannot hide the late-result case.
        try """
        #!/bin/sh
        if [ "$1" = status ] && mkdir '\(captureLease.path)' 2>/dev/null; then
            trap '' TERM
            /usr/bin/git "$@" > '\(captured.path)'
            printf '%s' $$ > '\(started.path).tmp'
            mv '\(started.path).tmp' '\(started.path)'
            IFS= read -r ready < '\(gate.path)'
            cat '\(captured.path)'
            printf done > '\(finished.path)'
        else
            exec /usr/bin/git "$@"
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        func release() {
            _ = "ready\n".withCString { write(gateDescriptor, $0, 6) }
        }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" })
        XCTAssertTrue(discovery.accept(executable.path))
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        actual.gitDiscovery = discovery
        controlsCanBeRemoved = false
        defer {
            release()
            actual.close()
            let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let text = try? String(contentsOf: started, encoding: .utf8), let process = Int32(text) else { return false }
                return FileManager.default.fileExists(atPath: finished.path) && kill(process, 0) == -1 && errno == ESRCH
            }, object: nil)
            controlsCanBeRemoved = XCTWaiter.wait(for: [reaped], timeout: 5) == .completed
            XCTAssertTrue(controlsCanBeRemoved, "Owned delayed Git must exit before removing its controls at \(controls.path)")
        }
        _ = actual.window
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: started.path) }, object: nil)
        wait(for: [waiting], timeout: 5)
        let process = try XCTUnwrap(try Int32(String(contentsOf: started, encoding: .utf8)))
        try GitXTestGitFixture.run(["checkout", "topic"], in: directory)
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        waitForBranch("topic", in: actual)
        release()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: finished.path) && kill(process, 0) == -1 && errno == ESRCH
        }, object: nil)
        wait(for: [completed], timeout: 5)
        let drained = expectation(description: "Late process completion drains on the main queue")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "topic")
        XCTAssertTrue(try Data(contentsOf: captured).contains(Data("branch.head main".utf8)))
    }

    private func waitForBranch(_ branch: String, in controller: GitX.PBGitWindowController) {
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.localBranch(in: controller.window?.contentView) == branch
        }, object: nil)
        wait(for: [rendered], timeout: 5)
    }

    private func localBranch(in view: NSView?) -> String? {
        localStatusText("GitX.RepositoryStatusBar.LocalBranch", in: view)
    }

    private func localStatusText(_ identifier: String, in view: NSView?) -> String? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return (view as? NSTextField)?.stringValue
        }
        return view.subviews.lazy.compactMap { self.localStatusText(identifier, in: $0) }.first
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
