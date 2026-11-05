import AppKit
import ForgeKit
@testable import GitX
import ObjectiveGit
import Synchronization
import XCTest

@MainActor
@objc(PBForgeWindowFixtureTools)
// Called by WindowControllerTests.m through the generated Objective-C interface.
// swiftlint:disable:next unused_declaration
final class ForgeWindowFixtureTools: NSObject {
    @objc(retainedSessionFor:)
    // Objective-C test caller; semantic Swift analysis cannot see this reference.
    // swiftlint:disable:next unused_declaration
    static func retainedSession(for object: NSObject) -> AnyObject? {
        (object as? GitX.PBGitWindowController)?.repositoryForgeOverlaySession
    }

    @objc(requireAuthenticationFor:)
    // Objective-C test caller; semantic Swift analysis cannot see this reference.
    // swiftlint:disable:next unused_declaration
    static func requireAuthentication(for object: NSObject) -> Bool {
        guard let owner = object as? GitX.PBGitWindowController,
              let previous = owner.repositoryForgeOverlaySession,
              let repository = previous.currentInput.repository else { return false }
        let loader = GitX.RepositoryForgeOverlayLoader(bootstrap: .authenticationRequired(repository), now: Date.init)
        let session = GitX.RepositoryForgeOverlaySession(repository: repository, loader: loader, detailsHandler: { previous.showDetails(for: $0) })
        owner.replaceRepositoryForgeOverlaySession(session)
        return true
    }
}

// Keep the generated Swift service surface out of files using its Objective-C mirror.
#if DEBUG
    @MainActor
    final class ForgeWindowPolicyTests: XCTestCase {
        func testGlobalIntentWaitsForAvailabilityAndCoalescesWithoutGenerationLoss() throws {
            var pending = GitX.RepositoryWindowRefreshIntents()
            XCTAssertFalse(pending.hasPending)
            XCTAssertNil(pending.consume(ready: true))
            pending.record(activated: true)
            pending.record(preferences: true)
            pending.record(activated: true)
            XCTAssertNil(pending.consume(ready: false))
            XCTAssertTrue(pending.hasPending)
            let delivered = try XCTUnwrap(pending.consume(ready: true))
            XCTAssertTrue(delivered.activated)
            XCTAssertTrue(delivered.preferences)
            XCTAssertFalse(pending.hasPending)
            pending.record(preferences: true)
            pending.discard()
            XCTAssertNil(pending.consume(ready: true))
        }

        func testReferenceIdentityCaptureRejectsMalformedSnapshotsAndPreservesLiteralNames() throws {
            XCTAssertNil(GitX.RepositoryStatusReferenceIdentity.capture(references: nil, headReference: nil, headObject: nil))
            XCTAssertNil(GitX.RepositoryStatusReferenceIdentity.capture(references: ["wrong": []] as NSDictionary, headReference: nil, headObject: nil))
            let object = try XCTUnwrap(GTOID(sha: String(repeating: "1", count: 40)))
            XCTAssertNil(GitX.RepositoryStatusReferenceIdentity.capture(references: [object: "wrong"] as NSDictionary, headReference: nil, headObject: nil))
            XCTAssertEqual(GitX.RepositoryStatusReferenceIdentity.capture(references: [:], headReference: nil, headObject: nil),
                           GitX.RepositoryStatusReferenceIdentity(headReference: nil, headObject: nil, references: [:]))
            let name = "refs/heads/cafe\u{0301}"
            let ref = PBGitRef(string: name)
            XCTAssertEqual(GitX.RepositoryStatusReferenceIdentity.capture(references: [object: [ref]] as NSDictionary, headReference: name, headObject: object.sha),
                           GitX.RepositoryStatusReferenceIdentity(headReference: Data(name.utf8), headObject: Data(object.sha.utf8), references: [Data(name.utf8): Data(object.sha.utf8)]))
        }

        func testReferenceMapCapturePreservesUnicodeBytesWithAnUnchangedHead() throws {
            let object = try XCTUnwrap(GTOID(sha: String(repeating: "1", count: 40)))
            let composed = "refs/heads/caf\u{00e9}"
            let decomposed = "refs/heads/cafe\u{0301}"
            let first = try XCTUnwrap(GitX.RepositoryStatusReferenceIdentity.capture(references: [object: [PBGitRef(string: composed)]] as NSDictionary, headReference: "refs/heads/main", headObject: object.sha))
            let second = try XCTUnwrap(GitX.RepositoryStatusReferenceIdentity.capture(references: [object: [PBGitRef(string: decomposed)]] as NSDictionary, headReference: "refs/heads/main", headObject: object.sha))
            XCTAssertEqual(first.headReference, second.headReference)
            XCTAssertEqual(first.headObject, second.headObject)
            XCTAssertNotEqual(first.references, second.references)
            XCTAssertEqual(first.references, [Data(composed.utf8): Data(object.sha.utf8)])
            XCTAssertEqual(second.references, [Data(decomposed.utf8): Data(object.sha.utf8)])
            var refresh = GitX.RepositoryStatusReferenceRefreshPolicy(baseline: first)
            XCTAssertFalse(refresh.needsRefresh(for: first))
            XCTAssertTrue(refresh.needsRefresh(for: second))
            XCTAssertFalse(refresh.needsRefresh(for: second))
        }

        func testRefreshCoalescerUsesItsActivityLabelAndKeepsTrailingDelivery() {
            var messages: [String] = []
            var deliveries = 0
            let complete = expectation(description: "Current and trailing status refreshes")
            complete.expectedFulfillmentCount = 2
            var coalescer: GitX.RefreshCoalescer!
            coalescer = GitX.RefreshCoalescer(label: "repository-status", log: { messages.append($0) }) {
                deliveries += 1
                if deliveries == 1 {
                    coalescer.requestRefresh()
                }
                complete.fulfill()
            }
            coalescer.requestRefresh()
            coalescer.requestRefresh()
            wait(for: [complete], timeout: 3)
            coalescer.cancel()
            XCTAssertEqual(deliveries, 2)
            XCTAssertEqual(messages, [
                "[GitX] Scheduled a repository-status refresh for the next main-loop turn",
                "[GitX] Coalesced a duplicate repository-status refresh request",
                "[GitX] Delivering one coalesced repository-status refresh",
                "[GitX] Scheduled a repository-status refresh for the next main-loop turn",
                "[GitX] Delivering one coalesced repository-status refresh",
                "[GitX] Cancelled the pending repository-status refresh",
            ])
            coalescer = nil
        }

        func testQueryPolicyRefusesStaleFacetsWithoutRequiringAGitLifetimeForMetadata() {
            let repository = NSObject()
            let replacement = NSObject()
            let window = NSObject()
            let identity = GitX.RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window), document: nil)
            let metadata = GitX.RepositoryWindowQueryPolicy(repository: ObjectIdentifier(repository))
            XCTAssertEqual(metadata.decision, .current)
            var complete = metadata
            complete.currentOwner = identity
            complete.installedOwner = identity
            complete.paneRepository = ObjectIdentifier(repository)
            complete.actionRepository = ObjectIdentifier(repository)
            XCTAssertEqual(complete.decision, .current)
            var changed = complete
            changed.currentOwner = nil
            XCTAssertEqual(changed.decision, .reconcileLater)
            changed = complete
            changed.paneRepository = ObjectIdentifier(replacement)
            XCTAssertEqual(changed.decision, .reconcileLater)
            changed = complete
            changed.actionRepository = ObjectIdentifier(replacement)
            XCTAssertEqual(changed.decision, .reconcileLater)
            changed = complete
            changed.facetsMatch = false
            XCTAssertEqual(changed.decision, .reconcileLater)
            changed = complete
            changed.selectionMatches = false
            XCTAssertEqual(changed.decision, .reconcileLater)
            changed.closed = true
            XCTAssertEqual(changed.decision, .unavailable)
            changed.closed = false
            changed.reconciling = true
            XCTAssertEqual(changed.decision, .unavailable)
            XCTAssertEqual(GitX.RepositoryWindowQueryPolicy().decision, .unavailable)
            for index in 0 ..< 3 {
                var missing = GitX.RepositoryWindowQueryPolicy()
                if index == 0 {
                    missing.installedOwner = identity
                }
                if index == 1 {
                    missing.paneRepository = ObjectIdentifier(repository)
                }
                if index == 2 {
                    missing.actionRepository = ObjectIdentifier(repository)
                }
                XCTAssertEqual(missing.decision, .reconcileLater)
            }
        }

        func testActionAvailabilityPreservesDiscoveryErrorsAndDistinguishesOwnerAbsence() {
            let notFound = NSError(domain: "PBGitBinaryErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Searched executable candidates"])
            let timeout = NSError(domain: "PBGitBinaryErrorDomain", code: 2)
            for error in [notFound, timeout] {
                XCTAssertTrue(GitX.RepositoryWindowActionAvailability.error(gitUnavailable: true, discoveryError: error) as NSError === error)
            }
            let git = GitX.RepositoryWindowActionAvailability.error(gitUnavailable: true, discoveryError: nil) as NSError
            XCTAssertEqual(git.domain, "GitX.WindowAction")
            XCTAssertEqual(git.code, 1)
            XCTAssertEqual(git.localizedDescription, "Git is not ready for this action. Try again when Git becomes available.")
            let owner = GitX.RepositoryWindowActionAvailability.error(gitUnavailable: false, discoveryError: notFound) as NSError
            XCTAssertEqual(owner.domain, "GitX.WindowAction")
            XCTAssertEqual(owner.code, 1)
            XCTAssertEqual(owner.localizedDescription, "The repository is not available for this action. Try again after the window finishes updating.")
        }

        func testForgeQueryPresentationBelongsToItsExactOwnerGenerationAndExecutable() {
            let repository = NSObject()
            let replacement = NSObject()
            let window = NSObject()
            let owner = GitX.RepositoryWindowOwnership.Identity(repository: ObjectIdentifier(repository), window: ObjectIdentifier(window), document: nil)
            let selection = GitX.GitBinarySelection(path: "/fixture/git", version: "2.50.1")
            let snapshot = GitX.RepositoryForgeQueryPresentation(repository: ObjectIdentifier(repository), owner: owner, generation: 7, selection: selection, providerName: "GitHub", isAvailable: true)
            XCTAssertTrue(snapshot.matches(repository: ObjectIdentifier(repository), owner: owner, generation: 7, selection: selection))
            XCTAssertFalse(snapshot.matches(repository: ObjectIdentifier(replacement), owner: owner, generation: 7, selection: selection))
            XCTAssertFalse(snapshot.matches(repository: ObjectIdentifier(repository), owner: nil, generation: 7, selection: selection))
            XCTAssertFalse(snapshot.matches(repository: ObjectIdentifier(repository), owner: owner, generation: 8, selection: selection))
            XCTAssertFalse(snapshot.matches(repository: ObjectIdentifier(repository), owner: owner, generation: 7, selection: nil))
            XCTAssertFalse(snapshot.matches(repository: ObjectIdentifier(repository), owner: owner, generation: 7, selection: .init(path: "/replacement/git", version: "2.50.1")))
        }
    }

    @MainActor
    func performOwnedWorktreePruneReport(service: NSObject, owner: NSObject, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        guard let service = service as? GitX.PBRepositoryWorktreeService else {
            XCTFail("The fixture must supply the actual Swift worktree service")
            return
        }
        service.perform(.pruneReport, owner: owner, completion: completion)
    }
#endif

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

extension GitXPerformanceTests {
    func testRepeatedToolbarReconciliationBenchmark() throws {
        let ready = expectation(description: "Validated Git before the Release fixture")
        PBGitBinary.whenAvailable { path, error in XCTAssertNotNil(path); XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbar-benchmark-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: directory)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "fixture"], in: directory)
        let document = try PBGitRepositoryDocument(contentsOf: directory, ofType: PBGitRepositoryDocumentType)
        defer { closeRepositoryFixtureDocument(document) }
        let owner = GitX.PBGitWindowController(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
        owner.repository = document.repository
        defer { owner.close() }
        let controller = GitX.RepositoryToolbarController(windowController: owner)
        controller.install()
        let toolbar = owner.window?.toolbar
        var samples: [TimeInterval] = []
        for _ in 0 ..< 5 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0 ..< 100 {
                controller.install()
            }
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        XCTAssertTrue(owner.window?.toolbar === toolbar)
        let data = try JSONSerialization.data(withJSONObject: ["iterationsPerSample": 100, "seconds": samples], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Repeated toolbar reconciliation samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
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
    private actor WindowOverlaySource: GitX.RepositoryForgeOverlayReading, GitX.RepositoryForgeOverlayCaching {
        let repository: ForgeRepositoryIdentity
        let description: String
        let rollup: ForgeCheckRollup
        let number: Int

        init(repository: ForgeRepositoryIdentity, description: String, rollup: ForgeCheckRollup, number: Int) {
            self.repository = repository
            self.description = description
            self.rollup = rollup
            self.number = number
        }

        func repositoryFacts(request _: GitX.RepositoryForgeOverlayRemoteRequest) async throws -> GitX.RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts> {
            let facts = try ForgeRepositoryFacts(repository: repository, defaultBranch: .available(ForgeRefName("main")),
                                                 description: .available(description), topics: .available([]), visibility: .available(.public),
                                                 isArchived: .available(false), forkRelationship: .available(.standalone))
            return .init(value: facts, fetchedAt: Date(), completeness: .complete, cooldownDeadline: nil)
        }

        func historyOverlay(commit: ForgeCommitID, request _: GitX.RepositoryForgeOverlayRemoteRequest) async throws -> GitX.RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay> {
            let date = Date()
            let pullRequest = try ForgePullRequestSummary(repository: repository, number: ForgeItemNumber(number), state: .open, isDraft: false,
                                                          title: description, author: .unavailable(.notRequested), head: .unavailable(.notRequested),
                                                          base: .unavailable(.notRequested), createdAt: date, updatedAt: date,
                                                          labels: .unavailable(.notRequested), checkRollup: .available(rollup), reviewRollup: .unavailable(.notRequested))
            return try .init(value: ForgeHistoryOverlay(repository: repository, commit: commit, checkRollup: .available(rollup),
                                                        pullRequests: .available(ForgePage(items: [pullRequest]))), fetchedAt: date, completeness: .complete, cooldownDeadline: nil)
        }

        func cachedRepositoryFacts(accessedAt _: Date) async throws -> GitX.RepositoryForgeOverlaySnapshot<ForgeRepositoryFacts>? {
            nil
        }

        func putRepositoryFacts(_: GitX.RepositoryForgeRemoteSnapshot<ForgeRepositoryFacts>) async throws {}
        func cachedHistoryOverlay(commit _: ForgeCommitID, accessedAt _: Date) async throws -> GitX.RepositoryForgeOverlaySnapshot<ForgeHistoryOverlay>? {
            nil
        }

        func putHistoryOverlay(_: GitX.RepositoryForgeRemoteSnapshot<ForgeHistoryOverlay>) async throws {}
    }

    private final nonisolated class ToolbarRecording: Sendable {
        let values = Mutex<[ObjectIdentifier]>([])
    }

    private final class ToolbarInstallationProbe: GitX.PBGitWindowController {
        let initialToolbars = ToolbarRecording()
        override func windowDidLoad() {
            guard let nativeWindow = super.window else { return }
            let recorded = initialToolbars
            let observation = nativeWindow.observe(\.toolbar, options: [.new]) { _, change in
                if case let toolbar?? = change.newValue {
                    recorded.values.withLock { $0.append(ObjectIdentifier(toolbar)) }
                }
            }
            super.windowDidLoad()
            observation.invalidate()
        }
    }

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
        var beforeRepositoryRead: (() -> Void)?
        var repositoryReadCount = 0
        override var repository: PBGitRepository? {
            get {
                repositoryReadCount += 1
                let callback = beforeRepositoryRead
                beforeRepositoryRead = nil
                callback?()
                return suppliedRepository
            }
            set { suppliedRepository = newValue }
        }
    }

    private final class SenderActionWindowProbe: GitX.PBGitWindowController {
        var beforeRepositoryRead: (() -> Void)?
        override var repository: PBGitRepository? {
            get {
                let callback = beforeRepositoryRead
                beforeRepositoryRead = nil
                callback?()
                return suppliedRepository
            }
            set { suppliedRepository = newValue }
        }

        private var suppliedRepository: PBGitRepository?
        var pushes = 0
        var fetches = 0
        var fetchedRef: PBGitRef?
        var pulls = 0
        var pulledRef: PBGitRef?
        var pullRebases: [Bool] = []
        var routedRepository: PBGitRepository?
        var openedURLs: [URL] = []
        var selectedURLRequests = 0
        var forwardsPushToProduction = false
        var errors: [NSError] = []
        override func performFetch(for ref: PBGitRef?) {
            fetches += 1
            fetchedRef = ref
            routedRepository = repository
        }

        override func performPull(forBranch branch: PBGitRef?, remote _: PBGitRef?, rebase: Bool) {
            pulls += 1
            pulledRef = branch
            pullRebases.append(rebase)
            routedRepository = repository
        }

        override func performPush(forBranch branch: PBGitRef?, toRemote remote: PBGitRef?) {
            if forwardsPushToProduction {
                super.performPush(forBranch: branch, toRemote: remote)
                return
            }
            pushes += 1
            routedRepository = repository
        }

        override func selectedURLs(from sender: Any?) -> [URL]? {
            selectedURLRequests += 1
            return super.selectedURLs(from: sender)
        }

        override func open(_ urls: [URL]?) {
            openedURLs = urls ?? []
        }

        override func showErrorSheet(_ error: Error) {
            errors.append(error as NSError)
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
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.gitLoaderSelection?.path == "/usr/bin/git" }, object: nil)
        wait(for: [selected], timeout: 5)
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

    func testWorktreeOwnerAcquisitionCompletesAnOverriddenRepositoryTransition() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let other = directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=replacement"], in: other)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "replacement"], in: other)
        let replacement = try XCTUnwrap(PBGitRepository(url: other))
        defer { replacement.revisionList?.cleanup(); replacement.revisionList = nil }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        actual.repository = replacement
        XCTAssertTrue(actual.reconciledWorktreeOwnership()?.repository === replacement)
        XCTAssertTrue(actual.historyViewController?.repository === replacement)
        XCTAssertTrue(actual.sidebarViewController?.repository === replacement)
        waitForBranch("replacement", in: actual)
        actual.repository = PBGitRepository()
        XCTAssertNil(actual.reconciledWorktreeOwnership())
        actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertNil(actual.gitLoaderSelection)
        XCTAssertNil(actual.historyViewController)
        XCTAssertNil(actual.sidebarViewController)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "Repository")
    }

    // swift6-safety-justification: mutexes protect one-shot actor-isolated hooks; only main-thread repository reads invoke them.
    private final nonisolated class ReentrantPreparationRepository: PBGitRepository {
        let locationHook = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
        let remotesHook = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

        override func task(withArguments arguments: [Any]?) -> PBTask {
            let task = super.task(withArguments: arguments)
            RepositoryTestGitEnvironment.prepare(task)
            return task
        }

        override func gitURL() -> URL? {
            if Thread.isMainThread {
                let hook = locationHook.withLock { value in let hook = value; value = nil; return hook }
                // swift6-safety-justification: AppKit's main-thread repository decision owns this callback.
                MainActor.assumeIsolated { hook?() }
            }
            return super.gitURL()
        }

        override func remotes() -> [String]? {
            if Thread.isMainThread {
                let hook = remotesHook.withLock { value in let hook = value; value = nil; return hook }
                // swift6-safety-justification: AppKit's main-thread metadata decision owns this callback.
                MainActor.assumeIsolated { hook?() }
            }
            return super.remotes()
        }
    }

    func testRepositorySetterReentrancyDrainsBeforeRestoredAdmission() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(ReentrantPreparationRepository(url: directory))
        let actual = GitX.PBGitWindowController(ownerNotifications: NotificationCenter())
        actual.repository = repository
        _ = actual.window
        defer { actual.close(); repository.revisionList?.cleanup(); repository.revisionList = nil }
        let transitions = Mutex(0)
        repository.locationHook.withLock { hook in
            hook = { transitions.withLock { $0 += 1 }; actual.repository = nil }
        }
        actual.refreshIfRepositoryChangedSinceLastActivation()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.historyViewController == nil && actual.gitLoaderSelection == nil }, object: nil)
        wait(for: [cleared], timeout: 5)
        XCTAssertEqual(transitions.withLock { $0 }, 1)
        XCTAssertNil(actual.repository)
        XCTAssertNil(actual.sidebarViewController)
        actual.repository = repository
        XCTAssertTrue(actual.historyViewController?.repository === repository)
        waitForBranch("main", in: actual)
    }

    func testOwnerReplacementDuringForgePreparationPreservesRefreshIntent() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(ReentrantPreparationRepository(url: directory))
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: NotificationCenter())
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        settings.forgeRepositoryBinding = nil
        actual.repository = repository
        _ = actual.window
        defer { actual.close(); settings.forgeRepositoryBinding = previous; repository.revisionList?.cleanup(); repository.revisionList = nil }
        try GitXTestGitFixture.run(["config", "gitx.preparation-boundary", UUID().uuidString], in: directory)
        let transitions = Mutex(0)
        repository.remotesHook.withLock { hook in
            hook = { transitions.withLock { $0 += 1 }; actual.repository = nil }
        }
        actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(transitions.withLock { $0 }, 1)
        XCTAssertNil(actual.repository)
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
        actual.repository = repository
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.historyViewController?.repository === repository && actual.gitLoaderSelection != nil }, object: nil)
        wait(for: [restored], timeout: 5)
        XCTAssertEqual(transitions.withLock { $0 }, 1)
        waitForBranch("main", in: actual)
    }

    func testLoadedDeterministicOwnerSettlesWithoutAForgeSession() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previous = ProcessInfo.processInfo.environment["GITX_M2_UITEST"]
        setenv("GITX_M2_UITEST", "1", 1)
        defer {
            if let previous {
                setenv("GITX_M2_UITEST", previous, 1)
            } else {
                unsetenv("GITX_M2_UITEST")
            }
        }
        let actual = GitX.PBGitWindowController(ownerNotifications: NotificationCenter())
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        XCTAssertTrue(actual.isWindowLoaded)
        XCTAssertNil(actual.repositoryForgeOverlaySession)
        let menu = NSMenuItem(title: "Forge", action: NSSelectorFromString("viewForgeRepository:"), keyEquivalent: "")
        XCTAssertFalse(actual.validateMenuItem(menu))
        XCTAssertNotNil(actual.historyViewController)
    }

    func testReentrantOwnershipReconciliationRefusesAdmissionAndPreservesItsCompleteOwner() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        let history = actual.historyViewController
        let selection = actual.gitLoaderSelection
        var calls = 0
        actual.beforeRepositoryRead = { [weak actual] in
            guard let actual else { return }
            calls += 1
            XCTAssertNil(actual.reconciledWorktreeOwnership())
            actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        }
        actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let drained = expectation(description: "One deferred reconciliation completes after the reentrant callback")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertEqual(actual.gitLoaderSelection, selection)
        waitForBranch("main", in: actual)
    }

    #if DEBUG
        private final nonisolated class RepositoryLocationProbe: PBGitRepository {
            let failNextMainThreadLocationRead = Mutex(false)

            override func task(withArguments arguments: [Any]?) -> PBTask {
                let task = super.task(withArguments: arguments)
                RepositoryTestGitEnvironment.prepare(task)
                return task
            }

            override func gitURL() -> URL? {
                // Inject a transient owner-location failure without changing the
                // backend path observed by unrelated repository workers.
                let unavailable = Thread.isMainThread && failNextMainThreadLocationRead.withLock { pending in
                    defer { pending = false }
                    return pending
                }
                return unavailable ? nil : super.gitURL()
            }
        }

        func testTransientLocationLossRevokesTheCurrentRepositoryAndRestoresMatchingPanes() throws {
            try prepareFixture()
            defer { try? removeFixture() }
            let other = FileManager.default.temporaryDirectory.appendingPathComponent("gitx-owner-location-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            var drainedService = true
            defer {
                if drainedService {
                    try? FileManager.default.removeItem(at: other)
                }
            }
            try GitXTestGitFixture.run(["init", "--initial-branch=available-owner"], in: other)
            try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "available owner"], in: other)
            let repository = try XCTUnwrap(RepositoryLocationProbe(url: other))
            let service = try XCTUnwrap(repository.worktreeService)
            defer {
                repository.revisionList?.cleanup()
                repository.revisionList = nil
                service.cancel()
                drainedService = false
                let drained = expectation(description: "Location fixture acknowledges owned processes and evidence")
                service.drainForTesting { drained.fulfill() }
                drainedService = XCTWaiter.wait(for: [drained], timeout: 15) == .completed
                XCTAssertTrue(drainedService, "Preserving undrained location fixture at \(other.path)")
            }
            let actual = RepositoryOverrideWindowProbe()
            actual.repository = repository
            _ = actual.window
            defer { actual.close() }
            waitForBranch("available-owner", in: actual)
            XCTAssertTrue(actual.reconciledWorktreeOwnership()?.repository === repository)
            let authority = actual.repositoryOwnerValidation(for: repository)
            XCTAssertTrue(authority())
            repository.failNextMainThreadLocationRead.withLock { $0 = true }
            XCTAssertNil(actual.reconciledWorktreeOwnership())
            XCTAssertFalse(authority(), "Location loss revokes the previously captured presentation authority")
            XCTAssertNil(actual.gitLoaderSelection)
            XCTAssertNil(actual.historyViewController)
            XCTAssertNil(actual.sidebarViewController)
            XCTAssertEqual(localBranch(in: actual.window?.contentView), "Repository")
            XCTAssertTrue(actual.reconciledWorktreeOwnership()?.repository === repository)
            XCTAssertTrue(actual.historyViewController?.repository === repository)
            XCTAssertTrue(actual.sidebarViewController?.repository === repository)
            waitForBranch("available-owner", in: actual)
        }

        func testRepairOfferAfterAnOverriddenRepositoryChangeBelongsToTheNewRepository() throws {
            try prepareFixture()
            defer { try? removeFixture() }
            let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            var drainedService = true
            defer {
                if drainedService {
                    try? FileManager.default.removeItem(at: other)
                }
            }
            try GitXTestGitFixture.run(["init", "--initial-branch=replacement"], in: other)
            try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "replacement"], in: other)
            let linked = other.appendingPathComponent("linked")
            try GitXTestGitFixture.run(["worktree", "add", "-b", "linked", linked.path], in: other)
            try FileManager.default.removeItem(at: linked.appendingPathComponent(".git"))
            let replacement = try XCTUnwrap(PBGitRepository(url: other))
            defer { replacement.revisionList?.cleanup(); replacement.revisionList = nil }
            let service = try XCTUnwrap(replacement.worktreeService)
            drainedService = false
            defer {
                service.cancel()
                let drained = expectation(description: "Repair fixture service acknowledges every owned process and worker")
                service.drainForTesting { drained.fulfill() }
                drainedService = XCTWaiter.wait(for: [drained], timeout: 15) == .completed
                XCTAssertTrue(drainedService, "Preserving undrained repair fixture at \(other.path)")
            }
            service.refresh()
            let broken = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in service.isSupported && service.worktrees.contains(where: \.hasBrokenLink) }, object: nil)
            wait(for: [broken], timeout: 10)
            let actual = RepositoryOverrideWindowProbe()
            actual.repository = document.repository
            let nativeWindow = try XCTUnwrap(actual.window)
            activateFixtureWindow(nativeWindow)
            defer {
                if let sheet = nativeWindow.attachedSheet {
                    nativeWindow.endSheet(sheet, returnCode: .cancel)
                }
                actual.close()
            }
            actual.repository = replacement
            actual.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: nativeWindow))
            let offered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in nativeWindow.attachedSheet != nil }, object: nil)
            wait(for: [offered], timeout: 5)
            XCTAssertTrue(actual.offeredWorktreeRepair)
            XCTAssertTrue(actual.historyViewController?.repository === replacement)
            attachScreenshot(of: nativeWindow.attachedSheet?.contentView, named: "Replacement repository owns its repair offer")
            if let sheet = nativeWindow.attachedSheet {
                nativeWindow.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            }
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in nativeWindow.attachedSheet == nil }, object: nil)
            wait(for: [dismissed], timeout: 5)
            actual.repository = document.repository
            actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
            XCTAssertFalse(actual.offeredWorktreeRepair, "The old repository has not received an offer")
            actual.repository = replacement
            actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
            XCTAssertTrue(actual.offeredWorktreeRepair, "Returning to the replacement preserves its acknowledged offer")
            actual.offerWorktreeRepairIfNeeded()
            XCTAssertNil(nativeWindow.attachedSheet)
            XCTAssertFalse(FileManager.default.fileExists(atPath: linked.appendingPathComponent(".git").path), "Skipping the offer cannot perform repair")
        }
    #endif

    func testRetainedHistoryRebindsForgeFactsWithoutReplacingItsInspector() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        defer { actual.close() }
        let history = try XCTUnwrap(actual.historyViewController)
        func panels(_ view: NSView) -> [GitX.RepositoryFactsInspectorView] {
            (view as? GitX.RepositoryFactsInspectorView).map { [$0] } ?? view.subviews.flatMap(panels)
        }
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        let panel = try XCTUnwrap(panels(history.view).first)
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "example", name: "repo")
        func session(_ bootstrap: GitX.RepositoryForgeOverlayBootstrap) -> GitX.RepositoryForgeOverlaySession {
            GitX.RepositoryForgeOverlaySession(repository: identity, loader: GitX.RepositoryForgeOverlayLoader(bootstrap: bootstrap, now: Date.init))
        }
        let first = session(.unsupported(identity))
        let second = session(.authenticationRequired(identity))
        defer { first.invalidate(); second.invalidate() }
        actual.replaceRepositoryForgeOverlaySession(first)
        let firstFacts = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in labels(panel).contains("Native facts are unavailable") }, object: nil)
        wait(for: [firstFacts], timeout: 5)
        panel.collapseButton.performClick(nil)
        let width = panel.constraints.first { $0.firstAttribute == .width }?.constant
        let selection = history.commitController.selectionIndexes
        actual.replaceRepositoryForgeOverlaySession(second)
        let secondFacts = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in labels(panel).contains("Sign in and choose an Account") }, object: nil)
        wait(for: [secondFacts], timeout: 5)
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertEqual(panels(history.view).count, 1)
        XCTAssertTrue(panels(history.view).first === panel)
        XCTAssertEqual(panel.constraints.first { $0.firstAttribute == .width }?.constant, width)
        XCTAssertEqual(history.commitController.selectionIndexes, selection)
        first.start()
        let drained = expectation(description: "Obsolete session output is ignored")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
        XCTAssertTrue(labels(panel).contains("Sign in and choose an Account"))
        actual.replaceRepositoryForgeOverlaySession(nil)
        XCTAssertTrue(labels(panel).contains("Waiting for Forge data"))
        attachScreenshot(of: actual.window?.contentView, named: "Retained History clears its obsolete Forge session")
    }

    func testRetainedHistoryRendersReplacementFactsAndBadgesAndRejectsOldSessionOutput() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = GitX.PBGitWindowController(ownerNotifications: NotificationCenter())
        actual.repository = document.repository
        let nativeWindow = try XCTUnwrap(actual.window)
        defer { actual.close() }
        activateFixtureWindow(nativeWindow)
        let history = try XCTUnwrap(actual.historyViewController)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        let panel = try XCTUnwrap(history.view.subviews.compactMap { $0 as? GitX.RepositoryFactsInspectorView }.first)
        let wasCollapsed = panel.collapseButton.toolTip == "Show Repository Facts"
        if wasCollapsed {
            panel.collapseButton.performClick(nil)
        }
        defer {
            if wasCollapsed {
                panel.collapseButton.performClick(nil)
            }
        }
        XCTAssertEqual(panel.collapseButton.toolTip, "Hide Repository Facts")
        let check = try XCTUnwrap(history.commitList.tableColumn(withIdentifier: .init("ForgeCheckRollupColumn")))
        let pullRequest = try XCTUnwrap(history.commitList.tableColumn(withIdentifier: .init("ForgePullRequestBadgeColumn")))
        let previousCheck = check.isHidden
        let previousPullRequest = pullRequest.isHidden
        defer { check.isHidden = previousCheck; pullRequest.isHidden = previousPullRequest }
        check.isHidden = false
        pullRequest.isHidden = false
        nativeWindow.contentView?.layoutSubtreeIfNeeded()
        history.commitList.scrollColumnToVisible(history.commitList.column(withIdentifier: pullRequest.identifier))
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "example", name: "repo")
        func session(description: String, rollup: ForgeCheckRollup, number: Int) throws -> GitX.RepositoryForgeOverlaySession {
            let credential = try ForgeCredentialReference(accountID: ForgeAccountID(forge: identity.forge, value: "isolated-window-account"),
                                                          credentialID: ForgeCredentialID("isolated-window-credential"), generation: ForgeCredentialGeneration(1))
            let source = WindowOverlaySource(repository: identity, description: description, rollup: rollup, number: number)
            let context = GitX.RepositoryForgeOverlayContext(access: .account(login: "fixture"), authentication: .credential(credential),
                                                             reader: source, cache: source, cooldowns: GitX.ForgeCredentialCooldownRegistry())
            return GitX.RepositoryForgeOverlaySession(repository: identity, loader: GitX.RepositoryForgeOverlayLoader(bootstrap: .ready(identity, context), now: Date.init))
        }
        let first = try session(description: "First session facts", rollup: .succeeded, number: 7)
        let second = try session(description: "Replacement session facts", rollup: .failed, number: 8)
        defer { first.invalidate(); second.invalidate() }
        actual.replaceRepositoryForgeOverlaySession(first)
        let firstRendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let values = labels(history.view)
            return values.contains("First session facts") && values.contains("✓ Passed") && values.contains("#7")
        }, object: nil)
        wait(for: [firstRendered], timeout: 5)
        XCTAssertTrue(first.historyStates.values.contains { $0.snapshot?.value.checkRollup == .available(.succeeded) }, "Visible commit demand reaches the first production session")
        let selection = history.commitController.selectionIndexes
        let scroll = history.commitList.enclosingScrollView?.contentView.bounds.origin
        actual.replaceRepositoryForgeOverlaySession(second)
        let secondRendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let values = labels(history.view)
            return values.contains("Replacement session facts") && values.contains("✕ Failed") && values.contains("#8")
        }, object: nil)
        wait(for: [secondRendered], timeout: 5)
        XCTAssertTrue(second.historyStates.values.contains { $0.snapshot?.value.checkRollup == .available(.failed) }, "Replacement resets commit demand and loads fresh badges")
        let oldPublished = expectation(description: "An obsolete session publishes an actual late remote result")
        var oldValues = 0
        let token = first.observeFacts { state in
            if case .value = state {
                oldValues += 1
                if oldValues == 2 {
                    oldPublished.fulfill()
                }
            }
        }
        defer { first.removeObserver(token) }
        first.start()
        wait(for: [oldPublished], timeout: 5)
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertEqual(history.commitController.selectionIndexes, selection)
        XCTAssertEqual(history.commitList.enclosingScrollView?.contentView.bounds.origin, scroll)
        XCTAssertTrue(labels(history.view).contains("Replacement session facts"))
        XCTAssertTrue(labels(history.view).contains("✕ Failed"))
        XCTAssertTrue(labels(history.view).contains("#8"))
        XCTAssertFalse(labels(history.view).contains("#7"))
        attachScreenshot(of: nativeWindow.contentView, named: "Retained History renders replacement Forge facts and badges")
    }

    private final class ForgeResetRecordingTable: GitX.PBCommitList {
        var reloadedRows: [IndexSet] = []
        var viewportReads = 0
        var realizedCells: [Int: NSTextField] = [:]
        var cellReads = 0
        var visibleRows = NSRange(location: 0, length: 6)
        override func rows(in _: NSRect) -> NSRange {
            viewportReads += 1
            return visibleRows
        }

        override func reloadData(forRowIndexes rows: IndexSet, columnIndexes _: IndexSet) {
            reloadedRows.append(rows)
        }

        override func view(atColumn column: Int, row: Int, makeIfNecessary _: Bool) -> NSView? {
            cellReads += 1
            return row == 0 ? realizedCells[column] : nil
        }
    }

    private final nonisolated class PreferenceOnlyRepository: PBGitRepository {
        let taskStarts = Mutex(0)
        override func task(withArguments _: [Any]?) -> PBTask {
            taskStarts.withLock { $0 += 1 }
            let task = PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil)
            task.timeout = 1
            return task
        }
    }

    private final nonisolated class ColdForgeQueryRepository: PBGitRepository {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("cold-forge-query-\(UUID())")
        let remoteReads = Mutex(0)
        override func gitURL() -> URL? {
            location.appendingPathComponent(".git")
        }

        override func workingDirectoryURL() -> URL? {
            location
        }

        override func remotes() -> [String]? {
            remoteReads.withLock { $0 += 1 }
            return []
        }
    }

    // swift6-safety-justification: the mutex protects the aggregate read count; UserDefaults serializes its own storage.
    private final nonisolated class CountingForgeDefaults: UserDefaults, @unchecked Sendable {
        let aggregateReads = Mutex(0)
        override func dictionary(forKey key: String) -> [String: Any]? {
            if key == "PBRepositoryUISettings" {
                aggregateReads.withLock { $0 += 1 }
            }
            return super.dictionary(forKey: key)
        }
    }

    func testPreferenceSnapshotSharesAggregateReadsAndDecodesOnlyChangedBindingPayloads() throws {
        let suite = "GitX-Forge-Snapshots-\(UUID())"
        let defaults = try XCTUnwrap(CountingForgeDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let github = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "first")
        let gitlab = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "fixture", name: "second")
        let first = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: github)
        let second = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: gitlab)
        let firstPayload = try JSONEncoder().encode(first)
        let secondPayload = try JSONEncoder().encode(second)
        defaults.set(["one": ["forgeRepositoryBinding": firstPayload], "two": ["forgeRepositoryBinding": secondPayload]], forKey: "PBRepositoryUISettings")
        let decodes = Mutex(0)
        let source = GitX.RepositoryBindingPreferenceSnapshots(defaults: defaults, decodeBinding: { payload in
            decodes.withLock { $0 += 1 }
            return try? JSONDecoder().decode(ForgeRepositoryBinding.self, from: payload)
        })
        for _ in 0 ..< 20 {
            XCTAssertEqual(source.binding(for: "one"), first)
            XCTAssertEqual(source.binding(for: "two"), second)
            XCTAssertNil(source.binding(for: "missing"))
        }
        XCTAssertEqual(defaults.aggregateReads.withLock { $0 }, 1)
        XCTAssertEqual(decodes.withLock { $0 }, 2)
        source.invalidate()
        XCTAssertEqual(source.binding(for: "one"), first)
        XCTAssertEqual(defaults.aggregateReads.withLock { $0 }, 2)
        XCTAssertEqual(decodes.withLock { $0 }, 2, "An irrelevant preference publication must not decode unchanged binding bytes")
        defaults.set(["one": ["forgeRepositoryBinding": secondPayload]], forKey: "PBRepositoryUISettings")
        source.invalidate()
        XCTAssertEqual(source.binding(for: "one"), second)
        XCTAssertNil(source.binding(for: "two"))
        XCTAssertEqual(defaults.aggregateReads.withLock { $0 }, 3)
        XCTAssertEqual(decodes.withLock { $0 }, 3)
        defaults.set(["one": ["forgeRepositoryBinding": Data([0xFF])]], forKey: "PBRepositoryUISettings")
        source.invalidate()
        XCTAssertNil(source.binding(for: "one"))
        XCTAssertNil(source.binding(for: "one"))
        XCTAssertEqual(decodes.withLock { $0 }, 4, "Malformed unchanged payloads are settled unavailable too")
    }

    func testPreferenceSnapshotExpiresAfterDeliveryWithoutReusingAnOlderInvalidation() throws {
        let suite = "GitX-Forge-Snapshot-Expiry-\(UUID())"
        let defaults = try XCTUnwrap(CountingForgeDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = GitX.RepositoryBindingPreferenceSnapshots(defaults: defaults)
        XCTAssertNil(source.binding(for: "absent"))
        source.invalidate()
        XCTAssertNil(source.binding(for: "absent"))
        let nextTurn = expectation(description: "The delivery snapshot expires")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 5)
        XCTAssertNil(source.binding(for: "absent"))
        XCTAssertEqual(defaults.aggregateReads.withLock { $0 }, 3)
    }

    func testGlobalGitConfigurationPathsRespectEnvironmentOverrides() {
        XCTAssertEqual(GitX.RepositoryForgeCoordinator.globalConfigurationPaths(environment: [:], home: URL(fileURLWithPath: "/fixture")),
                       ["/etc/gitconfig", "/fixture/.config/git/config", "/fixture/.gitconfig"])
        XCTAssertEqual(GitX.RepositoryForgeCoordinator.globalConfigurationPaths(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/custom/global config", "XDG_CONFIG_HOME": "/ignored"], home: URL(fileURLWithPath: "/fixture")),
                       ["/custom/global config"])
        XCTAssertEqual(GitX.RepositoryForgeCoordinator.globalConfigurationPaths(environment: ["GIT_CONFIG_SYSTEM": "/custom/system", "XDG_CONFIG_HOME": "/custom/xdg"], home: URL(fileURLWithPath: "/fixture")),
                       ["/custom/system", "/custom/xdg/git/config", "/fixture/.gitconfig"])
    }

    func testColdForgeMenuQueryDoesNotInstallAResolverOrDiscoverRemotes() throws {
        let repository = ColdForgeQueryRepository()
        try FileManager.default.createDirectory(at: repository.location, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: repository.location)
        defer { try? FileManager.default.removeItem(at: repository.location) }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = repository
        defer { actual.close() }
        XCTAssertFalse(actual.isWindowLoaded)
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
        XCTAssertEqual(repository.remoteReads.withLock { $0 }, 0, "Menu context must not start discovery")
        XCTAssertFalse(actual.isWindowLoaded)
    }

    func testGlobalStatusBarMenuDoesNotRequireARepositoryOrLoadAWindow() {
        let actual = GitX.PBGitWindowController()
        defer { actual.close() }
        let menu = NSMenuItem(title: "Status Bar", action: NSSelectorFromString("toggleRepositoryStatusBar:"), keyEquivalent: "")
        XCTAssertTrue(actual.validateMenuItem(menu))
        XCTAssertEqual(menu.state, ApplicationSettings.repositoryStatusBarVisible ? .on : .off)
        XCTAssertFalse(actual.isWindowLoaded)
        actual.close()
        XCTAssertFalse(actual.validateMenuItem(menu))
    }

    func testSuppressedForgePreparationSettlesQueriesWithoutRepeatedReconciliation() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previous = ProcessInfo.processInfo.environment["GITX_M2_UITEST"]
        setenv("GITX_M2_UITEST", "1", 1)
        defer {
            if let previous {
                setenv("GITX_M2_UITEST", previous, 1)
            } else {
                unsetenv("GITX_M2_UITEST")
            }
        }
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: NotificationCenter())
        actual.repository = document.repository
        defer { actual.close() }
        actual.installRepositoryForgeOverlaySession()
        actual.refreshPreferenceDidChange(nil)
        let settled = expectation(description: "Initial preparation settles")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 5)
        actual.repositoryReadCount = 0
        let menu = NSMenuItem(title: "Forge", action: NSSelectorFromString("viewForgeRepository:"), keyEquivalent: "")
        for _ in 0 ..< 10 {
            XCTAssertFalse(actual.validateMenuItem(menu))
        }
        let delivered = expectation(description: "No query schedules another reconciliation")
        DispatchQueue.main.async { DispatchQueue.main.async { delivered.fulfill() } }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(actual.repositoryReadCount, 10)
        XCTAssertFalse(actual.isWindowLoaded)
        XCTAssertNil(actual.repositoryForgeOverlaySession)
    }

    func testPreparedToolbarPreservesTheFirstUnchangedMenuAndAvatar() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let owner = GitX.PBGitWindowController()
        owner.repository = repository
        let probeCalls = Mutex(0)
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in
            probeCalls.withLock { $0 += 1 }
            return "git version 2.50.1"
        }, locations: [])
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        let admittedProbeCount = probeCalls.withLock { $0 }
        owner.gitDiscovery = discovery
        defer { owner.close() }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "first-render")
        let binding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
        let controller = GitX.RepositoryToolbarController(windowController: owner, repository: repository)
        controller.applyForgeMetadata(providerName: "GitHub", binding: binding,
                                      ownerIsCurrent: owner.repositoryPresentationValidation(for: repository))
        let toolbar = NSToolbar(identifier: "GitX.FirstUnchangedPresentation")
        let item = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .init("GitX.Toolbar.ForgeAccount"), willBeInsertedIntoToolbar: true))
        let stack = try XCTUnwrap(item.view as? NSStackView)
        let popup = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        let menuItem = try XCTUnwrap(popup.item(at: 0))
        let avatarContainer = try XCTUnwrap(stack.arrangedSubviews.first { $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccountAvatarContainer" })
        let avatar = try XCTUnwrap(avatarContainer.subviews.first)
        XCTAssertEqual(popup.title, "GitHub")
        let paletteItem = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .init("GitX.Toolbar.ForgeAccount"), willBeInsertedIntoToolbar: false))
        XCTAssertFalse(paletteItem.view === stack, "Palette rendering must not replace the installed control")
        controller.applyForgeMetadata(providerName: "GitHub", binding: binding,
                                      ownerIsCurrent: owner.repositoryPresentationValidation(for: repository))
        XCTAssertTrue(popup.item(at: 0) === menuItem, "The first unchanged publication must not rebuild an existing account menu")
        XCTAssertTrue(avatarContainer.subviews.first === avatar, "Unchanged publication must preserve the rendered avatar")
        XCTAssertFalse(owner.isWindowLoaded, "Prepared rendering must remain independent of nib loading")
        XCTAssertEqual(probeCalls.withLock { $0 }, admittedProbeCount, "Rendering and authority renewal must not start Git discovery")
    }

    func testToolbarProviderUpdatesFromPreparedBindingWithoutAnAccountNotification() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let oldVisibility = ApplicationSettings.repositoryStatusBarVisible
        ApplicationSettings.repositoryStatusBarVisible = false
        defer { ApplicationSettings.repositoryStatusBarVisible = oldVisibility }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let settings = ApplicationComposition.shared.repositoryViewState(for: document.repository)
        let previous = settings.forgeRepositoryBinding
        defer { settings.forgeRepositoryBinding = previous }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "toolbar")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
        actual.refreshPreferenceDidChange(nil)
        let session = GitX.RepositoryForgeOverlaySession(repository: identity,
                                                         loader: GitX.RepositoryForgeOverlayLoader(bootstrap: .authenticationRequired(identity), now: Date.init))
        defer { session.invalidate() }
        actual.replaceRepositoryForgeOverlaySession(session)
        func accountPopup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount" {
                return popup
            }
            return view.subviews.compactMap { accountPopup(in: $0) }.first
        }
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            actual.window?.toolbar?.items.compactMap { $0.view }.compactMap { accountPopup(in: $0) }.first?.title == "GitHub"
        }, object: nil)
        wait(for: [rendered], timeout: 5)
        let popup = try XCTUnwrap(actual.window?.toolbar?.items.compactMap { $0.view }.compactMap { accountPopup(in: $0) }.first)
        XCTAssertEqual(popup.title, "GitHub")
        XCTAssertTrue(popup.accessibilityLabel()?.contains("GitHub") == true)
        attachScreenshot(of: actual.window?.contentView?.superview, named: "Prepared GitHub toolbar provider")
        let account = try ForgeAccountID(forge: identity.forge, value: "toolbar-account")
        let oldAccount: [AnyHashable: Any] = [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                                              GitX.RepositoryForgeAccountNotificationKey.accountID: account,
                                              GitX.RepositoryForgeAccountNotificationKey.login: "fixture"]
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository, userInfo: oldAccount)
        XCTAssertEqual(popup.item(at: 0)?.title, "@fixture")
        let accountMenuItem = popup.item(at: 0)
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(popup.item(at: 0)?.title, "@fixture", "Preparing unchanged metadata preserves account details")
        XCTAssertTrue(popup.item(at: 0) === accountMenuItem, "Unchanged preparation must not rebuild an open account menu")
        let replacement = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "fixture", name: "replacement")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: replacement)
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(popup.title, "GitLab")
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository, userInfo: oldAccount)
        XCTAssertEqual(popup.title, "GitLab", "Obsolete account identity cannot replace prepared provider metadata")
        actual.close()
        let closedTitle = popup.title
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository, userInfo: oldAccount)
        XCTAssertEqual(popup.title, closedTitle, "A detached toolbar rejects late account presentation")
    }

    func testAccountNotificationBeforeBindingPreparationSurvivesAccountSwitch() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        defer { settings.forgeRepositoryBinding = previous }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "account-switch")
        let oldAccount = try ForgeAccountID(forge: identity.forge, value: "old")
        let newAccount = try ForgeAccountID(forge: identity.forge, value: "new")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity, preferredAccount: oldAccount)
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: NotificationCenter())
        actual.repository = repository
        _ = actual.window
        defer { actual.close() }
        actual.refreshPreferenceDidChange(nil)
        let popup = try XCTUnwrap(actual.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "GitX.Toolbar.ForgeAccount" })?.view?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: repository, userInfo: [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.accountID: oldAccount,
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.login: "old"])
        XCTAssertEqual(popup.title, "@old")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity, preferredAccount: newAccount)
        let newBinding = try XCTUnwrap(settings.forgeRepositoryBinding)
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(popup.title, "Switching account…", "Old account details must not masquerade as the newly requested account")
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: repository, userInfo: [GitX.RepositoryForgeAccountNotificationKey.binding: newBinding,
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.accountID: newAccount,
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.login: "new"])
        XCTAssertEqual(popup.title, "@new")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity, preferredAccount: oldAccount)
        actual.refreshPreferenceDidChange(nil)
        settings.forgeRepositoryBinding = newBinding
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: repository, userInfo: [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.accountID: newAccount,
                                                                                                               GitX.RepositoryForgeAccountNotificationKey.login: "new"])
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(popup.title, "@new", "The new account notification cannot be lost against the previous cached preference")
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(popup.title, "@new", "Unchanged preparation must preserve the selected account")
    }

    func testBoundPreparationSharesOneSettingsSnapshotPerDelivery() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let suite = "GitX-Bound-Delivery-\(UUID())"
        let defaults = try XCTUnwrap(CountingForgeDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GitX.RepositoryUISettings(repository: repository, preferences: GitX.ApplicationPreferences(userDefaults: defaults))
        let github = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "first")
        let gitlab = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "fixture", name: "replacement")
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository, settings: settings,
                                                          remoteDescriptorCache: GitX.RepositoryForgeRemoteDescriptorCache(), remoteCacheKey: UUID().uuidString,
                                                          remoteConfigurationRevision: { XCTFail("Stored bindings require no configuration walk"); return "unused" },
                                                          remoteNames: { XCTFail("Stored bindings require no Git discovery"); return [] }, remoteURL: { _ in nil })
        for identity in [github, gitlab] {
            let binding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
            settings.forgeRepositoryBinding = binding
            defaults.aggregateReads.withLock { $0 = 0 }
            for _ in 0 ..< 10 {
                XCTAssertEqual(coordinator.prepareQueryBinding(selection: nil).binding, binding)
                XCTAssertTrue(coordinator.preparedBindingIsCurrent)
            }
            XCTAssertEqual(defaults.aggregateReads.withLock { $0 }, 1, "Production preparation must share one aggregate capture, including after replacement")
        }
    }

    func testBoundForgeRejectsNumberWhenNoDestinationKindIsSupported() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        defer { settings.forgeRepositoryBinding = previous }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "routing")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository)
        guard case let .failure(error) = coordinator.resolveNumberReference("#42", availableKinds: []) else {
            return XCTFail("An empty supported-kind set must not route a destination")
        }
        XCTAssertEqual(error.domain, GitX.RepositoryForgeCoordinator.scriptingErrorDomain)
        XCTAssertEqual(error.code, GitX.RepositoryForgeScriptingErrorCode.noAvailableDestination.rawValue)
    }

    func testBoundForgePreparationDoesNotInspectRemoteConfiguration() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        defer { settings.forgeRepositoryBinding = previous }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "bound")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
        var configurationReads = 0
        var dependencyReads = 0
        var remoteReads = 0
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository, settings: settings,
                                                          remoteDescriptorCache: GitX.RepositoryForgeRemoteDescriptorCache(), remoteCacheKey: UUID().uuidString,
                                                          remoteConfigurationRevision: { configurationReads += 1; return "config" },
                                                          remoteConfigurationDependencies: { ["dependency"] },
                                                          remoteDependencyRevision: { _ in dependencyReads += 1; return "revision" },
                                                          remoteNames: { remoteReads += 1; return [] }, remoteURL: { _ in nil })
        let first = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertEqual(first.binding?.primaryRepository, identity)
        XCTAssertTrue(first === coordinator.prepareQueryBinding(selection: nil))
        XCTAssertEqual(configurationReads, 0, "Stored binding resolution has no configuration dependency")
        XCTAssertEqual(dependencyReads, 0)
        XCTAssertEqual(remoteReads, 0)
    }

    func testVisibleOverlayDemandToleratesScrollRowsBeyondAShrunkenHistory() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let history = try XCTUnwrap(ForgeResetHistory(repository: document.repository, superController: nil))
        defer { history.closeView() }
        let git = try XCTUnwrap(document.repository.gtRepo)
        let object = try XCTUnwrap(try git.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        history.commitController.content = [PBGitCommit(repository: document.repository, andCommit: object)]
        let table = ForgeResetRecordingTable(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        table.visibleRows = NSRange(location: 5000, length: 10)
        table.addTableColumn(NSTableColumn(identifier: .init("ForgeCheckRollupColumn")))
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "bounds")
        let session = GitX.RepositoryForgeOverlaySession(repository: identity, loader: GitX.RepositoryForgeOverlayLoader(bootstrap: .unsupported(identity), now: Date.init))
        defer { session.invalidate() }
        let coordinator = try XCTUnwrap(GitX.HistoryForgeOverlayCoordinator(owner: history, commitList: table, session: session, factsInspectorInitiallyExpanded: false, factsInspectorVisibilityDidChange: { _ in }))
        defer { coordinator.invalidate() }
        XCTAssertEqual(table.cellReads, 0)
        XCTAssertTrue(session.historyStates.isEmpty)
        history.commitController.content = []
        table.visibleRows = NSRange(location: NSNotFound, length: 0)
        coordinator.bind(to: nil)
        coordinator.bind(to: session)
        XCTAssertTrue(session.historyStates.isEmpty)
    }

    func testValidationUsesOneRepositoryCaptureAcrossHistoryMutationAndSettingsMenus() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        for selector in ["showHistoryView:", "showUncommittedChanges:", "showRepositorySettings:", "checkout:"] {
            let menu = NSMenuItem(title: "Context", action: NSSelectorFromString(selector), keyEquivalent: "")
            actual.repositoryReadCount = 0
            _ = actual.validateMenuItem(menu)
            XCTAssertEqual(actual.repositoryReadCount, 1, selector)
        }
    }

    func testSenderActionsReconcileBeforeResolvingReferencesAndKeepDynamicOverrides() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let replacementDirectory = directory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: replacementDirectory)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "replacement"], in: replacementDirectory)
        let replacement = try PBGitRepositoryDocument(contentsOf: replacementDirectory, ofType: PBGitRepositoryDocumentType)
        defer { closeRepositoryFixtureDocument(replacement) }
        actual.repository = replacement.repository
        let menu = NSMenuItem()
        menu.representedObject = PBGitRef(string: "refs/heads/main")
        actual.pushDefaultRemoteForRef(menu)
        XCTAssertEqual(actual.pushes, 1)
        XCTAssertTrue(actual.routedRepository === replacement.repository)
        XCTAssertTrue(actual.historyViewController?.repository === replacement.repository)
        for fetch in [true, false] {
            let routed = SenderActionWindowProbe()
            routed.repository = document.repository
            _ = routed.window
            routed.repository = replacement.repository
            if fetch {
                routed.fetchRemote(menu)
            } else {
                routed.pullRemote(menu)
            }
            XCTAssertEqual(fetch ? routed.fetches : routed.pulls, 1)
            XCTAssertTrue(routed.routedRepository === replacement.repository)
            XCTAssertTrue(routed.historyViewController?.repository === replacement.repository)
            routed.close()
        }
        let files = SenderActionWindowProbe()
        files.repository = document.repository
        _ = files.window
        defer { files.close() }
        files.repository = replacement.repository
        let trackedFile = replacementDirectory.appendingPathComponent("tracked.txt")
        try Data("fixture".utf8).write(to: trackedFile)
        menu.representedObject = ["tracked.txt"]
        files.openFiles(menu)
        XCTAssertEqual(files.selectedURLRequests, 1, "Explicit actions retain the dynamic selection facade")
        XCTAssertEqual(files.openedURLs.map { $0.resolvingSymlinksInPath() }, [trackedFile.resolvingSymlinksInPath()])
        XCTAssertTrue(files.historyViewController?.repository === replacement.repository)
    }

    func testRemoteNameSenderUsesConfiguredRemoteAndRejectsMissingOrWrongKinds() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        try GitXTestGitFixture.run(["remote", "add", "origin", directory.appendingPathComponent("remote.git").path], in: directory)
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let menu = NSMenuItem()
        menu.representedObject = "origin"
        actual.fetchRemote(menu)
        XCTAssertEqual(actual.fetches, 1)
        XCTAssertEqual(actual.fetchedRef?.ref, "refs/remotes/origin")
        XCTAssertTrue(actual.routedRepository === document.repository)
        actual.pushDefaultRemoteForRef(menu)
        actual.pullRemote(menu)
        XCTAssertEqual(actual.pushes, 0)
        XCTAssertEqual(actual.pulls, 0)
        menu.representedObject = "missing"
        actual.fetchRemote(menu)
        menu.representedObject = ""
        actual.fetchRemote(menu)
        XCTAssertEqual(actual.fetches, 1, "Only a configured nonempty remote reaches command admission")
        XCTAssertTrue(actual.errors.isEmpty)
        let unavailable = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in nil }, locations: [])
        actual.gitDiscovery = unavailable
        menu.representedObject = "missing"
        actual.fetchRemote(menu)
        XCTAssertTrue(actual.errors.isEmpty, "Invalid remote input must not become an infrastructure warning")
        menu.representedObject = "origin"
        actual.fetchRemote(menu)
        XCTAssertEqual(actual.errors.count, 1)
        XCTAssertEqual(actual.errors.last?.code, 3)
        let exhausted = expectation(description: "Actual discovery failure is retained")
        unavailable.whenAvailable { _, error in
            XCTAssertEqual(error?.code, 1)
            exhausted.fulfill()
        }
        wait(for: [exhausted], timeout: 5)
        actual.fetchRemote(menu)
        XCTAssertEqual(actual.errors.count, 2)
        XCTAssertEqual(actual.errors.last?.code, 1, "A permanent discovery failure must not be relabelled temporary")
    }

    func testDefaultRemotePullResolvesHeadAndPreservesExplicitBranchCallers() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        document.repository.currentBranch = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/topic"))
        let menu = NSMenuItem(title: "Pull From Default Remote", action: NSSelectorFromString("pullDefaultRemote:"), keyEquivalent: "")
        actual.pullDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 1)
        XCTAssertEqual(actual.pulledRef?.ref, "refs/heads/main", "History browsing must not change the default pull target")
        actual.pullRebaseDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 2)
        XCTAssertEqual(actual.pulledRef?.ref, "refs/heads/main")
        XCTAssertEqual(actual.pullRebases, [false, true])
        menu.representedObject = PBGitRef(string: "refs/heads/topic")
        actual.pullDefaultRemote(menu)
        actual.pullRebaseDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 4)
        XCTAssertEqual(actual.pulledRef?.ref, "refs/heads/topic", "Explicit branch callers retain their compatibility behavior")
        XCTAssertEqual(actual.pullRebases, [false, true, false, true])
        XCTAssertTrue(actual.routedRepository === document.repository)
        menu.representedObject = PBGitRef(string: "refs/tags/wrong-kind")
        actual.pullDefaultRemote(menu)
        actual.pullRebaseDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 4)
        menu.representedObject = nil
        try GitXTestGitFixture.run(["checkout", "--detach", "HEAD"], in: directory)
        document.repository.reloadRefs()
        document.repository.readCurrentBranch()
        actual.pullDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 4, "A detached HEAD cannot supply a local branch")
        actual.close()
        actual.pullRebaseDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 4)
    }

    func testDefaultRemotePullRefusesUnavailableGitWithoutReplay() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" }, notify: { _, _ in })
        actual.gitDiscovery = discovery
        let menu = NSMenuItem()
        actual.pullDefaultRemote(menu)
        XCTAssertEqual(actual.errors.count, 1)
        XCTAssertEqual(actual.pulls, 0)
        actual.pullRebaseDefaultRemote(menu)
        XCTAssertEqual(actual.errors.count, 2)
        XCTAssertEqual(actual.pulls, 0)
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        XCTAssertEqual(actual.pulls, 0)
        actual.pullDefaultRemote(menu)
        XCTAssertEqual(actual.pulls, 1)
        XCTAssertEqual(actual.pulledRef?.ref, "refs/heads/main")
    }

    func testDefaultRemoteMenuPullMergesRealLocalRemote() throws {
        try exerciseDefaultRemoteMenuPull(rebase: false)
    }

    func testDefaultRemoteMenuPullRebasesRealLocalRemote() throws {
        try exerciseDefaultRemoteMenuPull(rebase: true)
    }

    private func exerciseDefaultRemoteMenuPull(rebase: Bool) throws {
        try prepareFixture()
        var operationDrained = true
        defer { try? removeFixture(removeFiles: operationDrained) }
        let remote = directory.appendingPathComponent("default-remote.git")
        let peer = directory.appendingPathComponent("peer")
        try GitXTestGitFixture.run(["init", "--bare", remote.path], in: directory)
        try GitXTestGitFixture.run(["remote", "add", "origin", remote.path], in: directory)
        try GitXTestGitFixture.run(["push", "--set-upstream", "origin", "main"], in: directory)
        try GitXTestGitFixture.run(["clone", "--branch", "main", remote.path, peer.path], in: directory)
        try Data("remote contribution".utf8).write(to: peer.appendingPathComponent("remote.txt"))
        try GitXTestGitFixture.run(["add", "remote.txt"], in: peer)
        try GitXTestGitFixture.run(["commit", "-m", "remote contribution"], in: peer)
        try GitXTestGitFixture.run(["push", "origin", "main"], in: peer)
        let incoming = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: peer).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("local contribution".utf8).write(to: directory.appendingPathComponent("local.txt"))
        try GitXTestGitFixture.run(["add", "local.txt"], in: directory)
        try GitXTestGitFixture.run(["commit", "-m", "local contribution"], in: directory)
        for (key, value) in [("pull.rebase", "false"), ("user.name", "GitX Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            try GitXTestGitFixture.run(["config", key, value], in: directory)
        }
        document.repository.reloadRefs()
        document.repository.readCurrentBranch()
        document.repository.currentBranch = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/topic"))
        var pending: (@Sendable () throws -> Void)?
        var finished: ((NSError?) -> Void)?
        var admissions = 0
        let nativeWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let actual = GitX.PBGitWindowController(window: nativeWindow, remoteProgressStarting: { _, _, operation, completion in
            admissions += 1
            pending = operation
            finished = completion
            return true
        })
        actual.repository = document.repository
        defer { actual.close() }
        let menu = NSMenuItem()
        if rebase {
            actual.pullRebaseDefaultRemote(menu)
        } else {
            actual.pullDefaultRemote(menu)
        }
        let operation = try XCTUnwrap(pending, "The actual default menu must admit its Git operation")
        pending = nil
        let failure = Mutex<NSError?>(nil)
        let completed = expectation(description: "The disposable remote pull drains")
        operationDrained = false
        DispatchQueue.global().async {
            do { try operation() } catch { failure.withLock { $0 = error as NSError } }
            completed.fulfill()
        }
        let result = XCTWaiter().wait(for: [completed], timeout: 15)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { return }
        operationDrained = true
        let error = failure.withLock { $0 }
        XCTAssertNil(error)
        finished?(error)
        finished = nil
        XCTAssertEqual(admissions, 1)
        let headParents = try GitXTestGitFixture.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: directory).standardOutput.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(headParents.count, rebase ? 2 : 3, "Rebase stays linear; ordinary Pull creates the expected merge")
        try GitXTestGitFixture.run(["merge-base", "--is-ancestor", incoming, "HEAD"], in: directory)
        XCTAssertEqual(try GitXTestGitFixture.run(["symbolic-ref", "HEAD"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "refs/heads/main")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("local.txt")), Data("local contribution".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("remote.txt")), Data("remote contribution".utf8))
    }

    func testSelectionNotificationRefreshesAnExistingForgePresentationWithoutGlobalIntent() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        let notifications = NotificationCenter()
        let actual = GitX.PBGitWindowController(ownerNotifications: notifications)
        defer { actual.close(); settings.forgeRepositoryBinding = previous }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "selection")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: identity)
        let version = Mutex("git version 2.50.1")
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in version.withLock { $0 } }, notify: { _, _ in })
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        actual.gitDiscovery = discovery
        actual.repository = repository
        _ = actual.window
        let session = GitX.RepositoryForgeOverlaySession(repository: identity, loader: GitX.RepositoryForgeOverlayLoader(bootstrap: .authenticationRequired(identity), now: Date.init))
        actual.replaceRepositoryForgeOverlaySession(session)
        // Finish initial preference accounting before the executable-only event.
        // Otherwise startup defaults delivery can independently repair metadata.
        actual.refreshPreferenceDidChange(nil)
        let settled = expectation(description: "Initial preference delivery settles")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 5)
        // This case isolates selection notification delivery from AppKit's
        // independent window-main reconciliation boundary.
        actual.window?.delegate = nil
        let menu = NSMenuItem(title: "Forge", action: NSSelectorFromString("viewForgeRepository:"), keyEquivalent: "")
        XCTAssertTrue(actual.validateMenuItem(menu))
        let toolbar = try XCTUnwrap(actual.window?.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount") })
        let popup = try XCTUnwrap(item.view?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(popup.title, "GitHub")
        version.withLock { $0 = "git version 2.51.0" }
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        XCTAssertFalse(actual.validateMenuItem(menu), "A stale read query remains unavailable until deferred reconciliation")
        for _ in 0 ..< 20 {
            notifications.post(name: .PBGitBinaryDidChange, object: nil)
        }
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.validateMenuItem(menu) }, object: nil)
        wait(for: [refreshed], timeout: 5)
        XCTAssertEqual(menu.title, "View Repository on GitHub")
        XCTAssertEqual(actual.gitLoaderSelection?.version, "2.51.0")
        XCTAssertTrue(actual.repositoryForgeOverlaySession === session, "Refreshing presentation must work without replacing the existing session")
        let account = try ForgeAccountID(forge: identity.forge, value: "selected-executable")
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: repository,
                                        userInfo: [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub",
                                                   GitX.RepositoryForgeAccountNotificationKey.accountID: account,
                                                   GitX.RepositoryForgeAccountNotificationKey.login: "new-selection"])
        XCTAssertEqual(popup.item(at: 0)?.title, "@new-selection", "The toolbar must accept presentation against the newly installed selection")
        attachScreenshot(of: actual.window?.contentView?.superview, named: "Forge presentation after executable selection notification")
        actual.close()
        notifications.post(name: .PBGitBinaryDidChange, object: nil)
        XCTAssertFalse(actual.validateMenuItem(menu))
    }

    func testExplicitActionRefusesRepositoryRemovalDuringAdmissionWithoutReplay() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        actual.beforeRepositoryRead = { [weak actual] in actual?.repository = nil }
        let menu = NSMenuItem()
        menu.representedObject = ["tracked.txt"]
        actual.openFiles(menu)
        XCTAssertTrue(actual.openedURLs.isEmpty)
        XCTAssertTrue(actual.errors.isEmpty, "A revoked owner cannot present an availability error")
        XCTAssertNil(actual.historyViewController)
        actual.repository = document.repository
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        XCTAssertTrue(actual.openedURLs.isEmpty, "Restoration does not replay the refused user intent")
    }

    func testUnavailableSenderActionPresentsOnceAndNeverReplaysAfterGitBecomesReady() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = SenderActionWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let discovery = GitX.GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" }, notify: { _, _ in })
        actual.gitDiscovery = discovery
        let menu = NSMenuItem()
        menu.representedObject = 42
        actual.pushDefaultRemoteForRef(menu)
        actual.pullRemote(menu)
        actual.fetchRemote(menu)
        actual.openFiles(menu)
        actual.fetchRemote(nil)
        actual.pullRemote(nil)
        actual.pushDefaultRemoteForRef(nil)
        XCTAssertTrue(actual.errors.isEmpty, "Invalid selections retain their existing no-op behavior")
        menu.representedObject = PBGitRef(string: "refs/heads/main")
        actual.pushDefaultRemoteForRef(menu)
        XCTAssertEqual(actual.errors.count, 1)
        XCTAssertEqual(actual.pushes, 0)
        actual.forwardsPushToProduction = true
        actual.toolbarPush(nil)
        XCTAssertEqual(actual.errors.count, 2, "A separate toolbar intent also reports one error through the production facade")
        XCTAssertEqual(actual.pushes, 0)
        XCTAssertTrue(discovery.accept("/usr/bin/git"))
        actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
        XCTAssertEqual(actual.pushes, 0, "Readiness must not replay a user mutation")
        actual.close()
        actual.pushDefaultRemoteForRef(menu)
        XCTAssertEqual(actual.errors.count, 2, "Closed owners cannot present errors")
    }

    func testPreferenceRevisionDoesNotDiscoverAnUnavailableRepository() {
        let repository = PreferenceOnlyRepository()
        XCTAssertNil(repository.gitURL())
        let notifications = NotificationCenter()
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: notifications)
        actual.repository = repository
        defer { actual.close() }
        actual.refreshPreferenceDidChange(nil)
        for _ in 0 ..< 20 {
            notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        let delivered = expectation(description: "Preference-only notifications drain without Git")
        DispatchQueue.main.async { DispatchQueue.main.async { delivered.fulfill() } }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(repository.taskStarts.withLock { $0 }, 0)
        XCTAssertFalse(actual.isWindowLoaded)
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
        actual.close()
        actual.repositoryReadCount = 0
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        let closed = expectation(description: "Closed owners refuse notification inspection")
        DispatchQueue.main.async { closed.fulfill() }
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(actual.repositoryReadCount, 0)
    }

    func testUnrelatedDefaultsNotificationDoesNotReconcileAnUnloadedWindow() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let notifications = NotificationCenter()
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: notifications)
        actual.repository = document.repository
        actual.refreshPreferenceDidChange(nil)
        defer { actual.close() }
        actual.repositoryReadCount = 0
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        let delivered = expectation(description: "Deferred defaults publication has drained")
        DispatchQueue.main.async { DispatchQueue.main.async { DispatchQueue.main.async { delivered.fulfill() } } }
        wait(for: [delivered], timeout: 5)
        XCTAssertLessThanOrEqual(actual.repositoryReadCount, 1, "Filtering reads the revision once without reconciling")
        XCTAssertFalse(actual.isWindowLoaded)
    }

    func testAmendMenuValidationPreservesItsCurrentWindowAndIndexEligibility() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        let window = try XCTUnwrap(actual.window)
        defer { actual.close() }
        activateFixtureWindow(window)
        let history = try XCTUnwrap(actual.historyViewController)
        let selection = actual.gitLoaderSelection
        let menu = NSMenuItem(title: "Amend Commit", action: NSSelectorFromString("toggleAmendCommit:"), keyEquivalent: "")
        let eligible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.validateMenuItem(menu) }, object: nil)
        wait(for: [eligible], timeout: 5)
        actual.repositoryReadCount = 0
        XCTAssertTrue(actual.validateMenuItem(menu))
        XCTAssertEqual(actual.repositoryReadCount, 1, "One synchronous menu decision uses its captured repository")
        XCTAssertEqual(menu.state, .off)
        XCTAssertTrue(actual.historyViewController === history)
        XCTAssertEqual(actual.gitLoaderSelection, selection)
        XCTAssertTrue(actual.window === window)
        actual.close()
        XCTAssertFalse(actual.validateMenuItem(menu))
    }

    func testForgeQueriesUsePreparedMetadataAndRefreshOnlyAtAuthorizedBoundaries() throws {
        let repository = ColdForgeQueryRepository()
        try FileManager.default.createDirectory(at: repository.location, withIntermediateDirectories: true)
        try GitXTestGitFixture.run(["init", "--initial-branch=main"], in: repository.location)
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: NotificationCenter())
        actual.repository = repository
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        defer {
            actual.close()
            settings.forgeRepositoryBinding = previous
            try? FileManager.default.removeItem(at: repository.location)
        }
        let github = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "example", name: "first")
        let gitlab = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "example", name: "second")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: github)
        let menu = NSMenuItem(title: "Stale", action: NSSelectorFromString("viewForgeRepository:"), keyEquivalent: "")
        XCTAssertFalse(actual.validateMenuItem(menu))
        XCTAssertEqual(menu.title, "View Repository")
        XCTAssertEqual(repository.remoteReads.withLock { $0 }, 0)
        XCTAssertNotNil(actual.forgeLinkUseCase, "Actual action admission prepares the binding")
        for _ in 0 ..< 3 {
            XCTAssertTrue(actual.validateMenuItem(menu))
            XCTAssertEqual(menu.title, "View Repository on GitHub")
            XCTAssertEqual(actual.forgeLinkContext.providerName, "GitHub")
        }
        XCTAssertEqual(repository.remoteReads.withLock { $0 }, 0)
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: gitlab)
        actual.refreshPreferenceDidChange(nil)
        XCTAssertEqual(actual.forgeLinkContext.providerName, "GitLab")
        settings.forgeRepositoryBinding = nil
        actual.refreshPreferenceDidChange(nil)
        XCTAssertFalse(actual.validateMenuItem(menu))
        XCTAssertEqual(menu.title, "View Repository")
        let reads = repository.remoteReads.withLock { $0 }
        XCTAssertGreaterThan(reads, 0, "Authorized refresh can discover remotes")
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
        XCTAssertEqual(repository.remoteReads.withLock { $0 }, reads)
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: github)
        actual.refreshPreferenceDidChange(nil)
        XCTAssertTrue(actual.forgeLinkContext.isForgeAvailable, "Make the obsolete snapshot observably different from unavailable")
        let replacement = ColdForgeQueryRepository()
        let replacementReads = replacement.remoteReads.withLock { $0 }
        actual.repository = replacement
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable, "Replacement cannot reuse the previous snapshot")
        XCTAssertEqual(replacement.remoteReads.withLock { $0 }, replacementReads)
        XCTAssertEqual(repository.remoteReads.withLock { $0 }, reads)
        XCTAssertFalse(actual.isWindowLoaded)
        actual.close()
        XCTAssertNil(actual.forgeLinkUseCase)
    }

    func testPassiveForgePreparationCachesUnavailableResultsAndInvalidatesConfigDependencies() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        settings.forgeRepositoryBinding = nil
        defer { settings.forgeRepositoryBinding = previous }
        var revision = "config-a"
        var dependency = "dependency-a"
        var reads = 0
        var namesAvailable = true
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository, settings: settings,
                                                          remoteDescriptorCache: GitX.RepositoryForgeRemoteDescriptorCache(), remoteCacheKey: UUID().uuidString,
                                                          remoteConfigurationRevision: { revision }, remoteConfigurationDependencies: { ["included.config"] },
                                                          remoteDependencyRevision: { _ in dependency }, remoteNames: { reads += 1; return namesAvailable ? [] : nil }, remoteURL: { _ in nil })
        let first = coordinator.prepareQueryBinding(selection: nil)
        let verified = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertFalse(first === verified, "The first discovery establishes evidence; a stable later preparation certifies reuse")
        XCTAssertTrue(verified === coordinator.prepareQueryBinding(selection: nil))
        XCTAssertEqual(reads, 1)
        dependency = "dependency-b"
        let changed = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertFalse(first === changed)
        XCTAssertEqual(reads, 2)
        revision = "config-b"
        XCTAssertFalse(changed === coordinator.prepareQueryBinding(selection: nil))
        XCTAssertEqual(reads, 3)
        namesAvailable = false
        revision = "unverifiable"
        let unavailable = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertFalse(unavailable === coordinator.prepareQueryBinding(selection: nil), "Failed discovery cannot become a permanent cached absence")
        XCTAssertEqual(reads, 5)
    }

    func testPassiveForgeResolutionCannotTagAnOldResultWithANewerPreferenceRevision() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let suite = "GitX-Forge-Revision-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GitX.RepositoryUISettings(repository: repository, preferences: GitX.ApplicationPreferences(userDefaults: defaults))
        let gitlab = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "fixture", name: "new")
        let replacement = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: gitlab)
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository, settings: settings,
                                                          remoteDescriptorCache: GitX.RepositoryForgeRemoteDescriptorCache(), remoteCacheKey: UUID().uuidString,
                                                          remoteConfigurationRevision: { "unchanged" }, remoteNames: {
                                                              settings.forgeRepositoryBinding = replacement
                                                              return []
                                                          }, remoteURL: { _ in nil })
        let first = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertNil(first.binding, "Discovery began unbound and returned no candidates")
        XCTAssertFalse(coordinator.preparedBindingIsCurrent, "A preference changed across discovery cannot authorize publication")
        let next = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertEqual(next.providerName, "GitLab", "The newer revision cannot authorize reuse of the old result")
        XCTAssertTrue(coordinator.preparedBindingIsCurrent)
        XCTAssertFalse(first === next)
        XCTAssertTrue(next === coordinator.prepareQueryBinding(selection: nil))
    }

    func testPassiveForgePreparationRetriesUnavailableDiscoveryAfterADependencyChange() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let suite = "GitX-Forge-Dependencies-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GitX.RepositoryUISettings(repository: repository, preferences: GitX.ApplicationPreferences(userDefaults: defaults))
        var dependency = "original"
        var names: [String]? = []
        var reads = 0
        let coordinator = GitX.RepositoryForgeCoordinator(repository: repository, settings: settings,
                                                          remoteDescriptorCache: GitX.RepositoryForgeRemoteDescriptorCache(), remoteCacheKey: UUID().uuidString,
                                                          remoteConfigurationRevision: { "unchanged" }, remoteConfigurationDependencies: { ["included.config"] },
                                                          remoteDependencyRevision: { _ in dependency }, remoteNames: { reads += 1; return names },
                                                          remoteURL: { _ in "https://github.com/fixture/recovered.git" })
        XCTAssertNil(coordinator.prepareQueryBinding(selection: nil).binding)
        XCTAssertEqual(reads, 1)
        dependency = "replacement"
        names = nil
        XCTAssertNil(coordinator.prepareQueryBinding(selection: nil).binding)
        XCTAssertEqual(reads, 2, "The changed dependency forces discovery, which is temporarily unavailable")
        names = ["origin"]
        let recovered = coordinator.prepareQueryBinding(selection: nil)
        XCTAssertEqual(reads, 3, "Failed discovery cannot certify the dependency revision of old descriptors")
        XCTAssertEqual(recovered.binding?.primaryRepository.name, "recovered")
        XCTAssertEqual(recovered.providerName, "GitHub")
    }

    func testActualDefaultsNotificationRefreshesThePreparedForgeMenu() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        let actual = GitX.PBGitWindowController()
        defer { actual.close(); settings.forgeRepositoryBinding = previous }
        let github = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "first")
        let gitlab = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com")), owner: "fixture", name: "second")
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: github)
        actual.repository = repository
        _ = actual.window
        let before = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.forgeLinkContext.providerName == "GitHub" }, object: nil)
        wait(for: [before], timeout: 5)
        settings.forgeRepositoryBinding = try ForgeRepositoryBinding(localRemoteName: "origin", primaryRepository: gitlab)
        let after = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.forgeLinkContext.providerName == "GitLab" }, object: nil)
        wait(for: [after], timeout: 5)
        actual.close()
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
    }

    func testGitDirectoryEventBurstRefreshesUnavailableMetadataAndExternalRemoteChanges() throws {
        try exercisePassiveForgeRemoteChange(activate: false)
    }

    func testActivationRefreshesUnavailableMetadataAfterAnExternalRemoteChange() throws {
        try exercisePassiveForgeRemoteChange(activate: true)
    }

    private func exercisePassiveForgeRemoteChange(activate: Bool) throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let ready = expectation(description: "Git selection is ready before the owner is installed")
        GitX.GitBinaryDiscovery.shared.whenSelectionAvailable { _, _ in ready.fulfill() }
        wait(for: [ready], timeout: 35)
        XCTAssertNotNil(GitX.GitBinaryDiscovery.shared.currentSelection)
        let repository = try XCTUnwrap(document.repository)
        let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
        let previous = settings.forgeRepositoryBinding
        let notifications = NotificationCenter()
        let actual = GitX.PBGitWindowController(ownerNotifications: notifications)
        defer { actual.close(); settings.forgeRepositoryBinding = previous }
        settings.forgeRepositoryBinding = nil
        actual.repository = repository
        _ = actual.window
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
        try GitXTestGitFixture.run(["remote", "add", "upstream", "https://gitlab.com/fixture/metadata.git"], in: directory)
        if activate {
            actual.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        } else {
            for _ in 0 ..< 20 {
                notifications.post(name: .PBGitRepositoryEvent, object: repository,
                                   userInfo: [kPBGitRepositoryEventTypeUserInfoKey: NSNumber(value: PBGitRepositoryWatcherEventType.gitDirectory.rawValue)])
            }
        }
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.forgeLinkContext.providerName == "GitLab" }, object: nil)
        wait(for: [refreshed], timeout: 5)
        XCTAssertTrue(actual.forgeLinkContext.isForgeAvailable)
        actual.close()
        notifications.post(name: .PBGitRepositoryEvent, object: repository,
                           userInfo: [kPBGitRepositoryEventTypeUserInfoKey: NSNumber(value: PBGitRepositoryWatcherEventType.gitDirectory.rawValue)])
        XCTAssertFalse(actual.forgeLinkContext.isForgeAvailable)
    }

    private final class ForgeResetHistory: PBGitHistoryController {
        let arranged = NSArrayController()
        override var commitController: NSArrayController {
            arranged
        }

        override func loadView() {
            view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        }
    }

    private final nonisolated class ForgeBadgeChangeRecorder: NSObject {
        let changes = Mutex(0)
        override func observeValue(forKeyPath _: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
            changes.withLock { $0 += 1 }
        }
    }

    func testForgeRebindingDoesNotResetOrReloadUntouchedHiddenRows() throws {
        try exerciseForgeReset(replayed: false, hidden: true)
    }

    func testForgeRebindingClearsEveryReplayedCommitObjectWithoutReloadingHiddenColumns() throws {
        try exerciseForgeReset(replayed: true, hidden: true)
    }

    func testForgeRebindingBatchesVisibleReplayedRowsAndIsIdempotent() throws {
        try exerciseForgeReset(replayed: true, hidden: false)
    }

    private func exerciseForgeReset(replayed: Bool, hidden: Bool) throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let history = try XCTUnwrap(ForgeResetHistory(repository: document.repository, superController: nil))
        defer { history.closeView() }
        let git = try XCTUnwrap(document.repository.gtRepo)
        let object = try XCTUnwrap(try git.lookUpObject(byRevParse: "HEAD") as? GTCommit)
        let commits = (0 ..< 6).map { _ in PBGitCommit(repository: document.repository, andCommit: object) }
        history.commitController.content = commits
        let table = ForgeResetRecordingTable(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        for name in ["ForgeCheckRollupColumn", "ForgePullRequestBadgeColumn"] {
            let column = NSTableColumn(identifier: .init(name))
            column.isHidden = hidden
            table.addTableColumn(column)
        }
        let identity = try ForgeRepositoryIdentity(forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")), owner: "fixture", name: "overlays")
        let session = GitX.RepositoryForgeOverlaySession(repository: identity, loader: GitX.RepositoryForgeOverlayLoader(bootstrap: .unsupported(identity), now: Date.init))
        defer { session.invalidate() }
        if replayed {
            try session.requestHistoryOverlay(ForgeCommitID(commits[0].sha))
        }
        let coordinator = try XCTUnwrap(GitX.HistoryForgeOverlayCoordinator(owner: history, commitList: table, session: session, factsInspectorInitiallyExpanded: false, factsInspectorVisibilityDidChange: { _ in }))
        defer { coordinator.invalidate() }
        if hidden {
            table.viewportReads = 0
            table.tableColumns[0].isHidden = true
            XCTAssertEqual(table.viewportReads, 0, "Hidden-column demand must not scan even the viewport")
        }
        let recorder = ForgeBadgeChangeRecorder()
        for commit in commits {
            commit.addObserver(recorder, forKeyPath: "forgeCheckRollupText", options: [], context: nil)
        }
        defer { for commit in commits {
            commit.removeObserver(recorder, forKeyPath: "forgeCheckRollupText")
        } }
        table.reloadedRows.removeAll()
        coordinator.bind(to: nil)
        let expected: [IndexSet] = !hidden && replayed ? [IndexSet(integersIn: 0 ..< 6)] : []
        XCTAssertEqual(table.reloadedRows, expected, "Only visible rows with applied presentations need one batch reload")
        XCTAssertEqual(recorder.changes.withLock { $0 }, replayed ? 6 : 0, "Reset exactly the objects which received replayed state, not all arranged commits")
        for commit in commits {
            XCTAssertEqual(commit.value(forKey: "forgeCheckRollupText") as? String, "—")
        }
        coordinator.bind(to: nil)
        XCTAssertEqual(table.reloadedRows, expected)
        XCTAssertEqual(recorder.changes.withLock { $0 }, replayed ? 6 : 0)
        if hidden {
            let cell = NSTextField(labelWithString: "Reused row")
            cell.setAccessibilityLabel("Obsolete Forge state")
            table.realizedCells[0] = cell
            table.cellReads = 0
            table.tableColumns[0].isHidden = true
            XCTAssertEqual(table.cellReads, 0)
            table.tableColumns[0].isHidden = false
            XCTAssertEqual(cell.accessibilityLabel(), "Check Rollup unavailable", "Revealed rows refresh accessibility even without a session")
            XCTAssertGreaterThan(table.cellReads, 0)
        }
    }

    func testSelectionQueryLeavesMatchingUnloadedHistoryAndWindowUnloaded() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        let history = try XCTUnwrap(ForgeResetHistory(repository: document.repository, superController: nil))
        actual.setValue(history, forKey: "_historyViewController")
        XCTAssertFalse(actual.isWindowLoaded)
        XCTAssertFalse(history.isViewLoaded)
        XCTAssertNil(actual.selectedRef)
        XCTAssertFalse(actual.isWindowLoaded)
        XCTAssertFalse(history.isViewLoaded)
        actual.close()
    }

    func testStaleSelectionQueriesDeferWithoutReplacingTheCurrentPresentation() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let actual = RepositoryOverrideWindowProbe()
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        let history = try XCTUnwrap(actual.historyViewController)
        let selection = actual.gitLoaderSelection
        actual.repository = nil
        let statusItem = NSMenuItem(title: "Status Bar", action: NSSelectorFromString("toggleRepositoryStatusBar:"), keyEquivalent: "")
        XCTAssertTrue(actual.validateMenuItem(statusItem), "A global preference remains available while repository queries defer")
        let item = NSMenuItem()
        item.representedObject = PBGitRef(string: "refs/heads/main")
        XCTAssertNil(actual.refish(for: item, refishTypes: nil))
        XCTAssertTrue(actual.historyViewController === history, "A query must defer teardown until its publisher has returned")
        XCTAssertEqual(actual.gitLoaderSelection, selection)
        let reconciled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.historyViewController == nil }, object: nil)
        wait(for: [reconciled], timeout: 5)
    }

    func testPreferenceIntentIsReplayedAfterReentrantReplacementDuringDelivery() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previous = ApplicationSettings.repositoryStatusBarVisible
        ApplicationSettings.repositoryStatusBarVisible = true
        defer { ApplicationSettings.repositoryStatusBarVisible = previous }
        let notifications = NotificationCenter()
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: notifications)
        actual.repository = document.repository
        let original = try XCTUnwrap(actual.window?.contentView?.subviews.first { $0.accessibilityIdentifier() == "GitX.RepositoryStatusBar" })
        let originalHistory = try XCTUnwrap(actual.historyViewController)
        defer { actual.close() }
        let repository = RepositoryNotificationFixture(document.repository)
        let replacements = Mutex(0)
        let observation = original.observe(\.isHidden, options: [.new]) { _, change in
            // swift6-safety-justification: AppKit publishes visibility KVO synchronously on its main actor.
            MainActor.assumeIsolated {
                guard change.newValue == true, replacements.withLock({ count in
                    guard count == 0 else { return false }
                    count += 1
                    return true
                }) else { return }
                actual.repository = nil
                actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
                actual.repository = repository.value
                actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
                // The isolated center receives no notification for this newer value.
                // A retained intent must apply it after replacement installation.
                ApplicationSettings.repositoryStatusBarVisible = true
            }
        }
        defer { observation.invalidate() }
        ApplicationSettings.repositoryStatusBarVisible = false
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        let replayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = actual.window?.contentView?.subviews.first(where: { $0.accessibilityIdentifier() == "GitX.RepositoryStatusBar" }) else { return false }
            return replacements.withLock { $0 } == 1 && actual.historyViewController !== originalHistory && !current.isHidden
        }, object: nil)
        wait(for: [replayed], timeout: 5)
        XCTAssertTrue(actual.historyViewController?.repository === repository.value)
    }

    func testGlobalPreferenceIntentSurvivesAnOwnerGenerationChangeBeforeDelivery() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let previous = ApplicationSettings.repositoryStatusBarVisible
        defer { ApplicationSettings.repositoryStatusBarVisible = previous }
        ApplicationSettings.repositoryStatusBarVisible = false
        let notifications = NotificationCenter()
        let actual = RepositoryOverrideWindowProbe(ownerNotifications: notifications)
        actual.repository = document.repository
        _ = actual.window
        defer { actual.close() }
        func bar(in view: NSView?) -> GitX.RepositoryStatusBarView? {
            guard let view else { return nil }
            return (view as? GitX.RepositoryStatusBarView) ?? view.subviews.lazy.compactMap { bar(in: $0) }.first
        }
        let status = try XCTUnwrap(bar(in: actual.window?.contentView))
        XCTAssertTrue(status.isHidden)
        ApplicationSettings.repositoryStatusBarVisible = true
        notifications.post(name: UserDefaults.didChangeNotification, object: nil)
        let replaced = expectation(description: "Owner changes after notification admission and before intent delivery")
        DispatchQueue.main.async {
            actual.repository = nil
            actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
            actual.repository = self.document.repository
            actual.gitBinaryDidChange(Notification(name: .PBGitBinaryDidChange))
            replaced.fulfill()
        }
        wait(for: [replaced], timeout: 5)
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !status.isHidden }, object: nil)
        wait(for: [applied], timeout: 5)
        XCTAssertTrue(bar(in: actual.window?.contentView) === status, "An unchanged presentation must receive the global preference")
    }

    func testOwnerNotificationsReturnBeforeReconciliationAndDiscardRevokedDeliveries() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        _ = actual.window
        defer { actual.close() }
        let before = try XCTUnwrap(actual.repositoryForgeOverlaySession)
        let publisherLock = NSLock()
        publisherLock.lock()
        NotificationCenter.default.post(name: .forgeApplicationAvailabilityDidChange, object: nil)
        XCTAssertTrue(actual.repositoryForgeOverlaySession === before, "Publication must return before a handler can reenter repository settings")
        publisherLock.unlock()
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in actual.repositoryForgeOverlaySession !== before }, object: nil)
        wait(for: [replaced], timeout: 5)
        NotificationCenter.default.post(name: .forgeApplicationAvailabilityDidChange, object: nil)
        actual.close()
        let drained = expectation(description: "A queued event cannot restore a closed owner's session")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
        XCTAssertNil(actual.repositoryForgeOverlaySession)
        XCTAssertNil(actual.gitLoaderSelection)
    }

    func testHistorySelectionDoesNotRefreshStatusButRefAndHeadEventsDo() throws {
        let defaults = UserDefaults.standard
        let previousWatcher = defaults.object(forKey: "PBUseRepositoryWatcher")
        let previousFocus = defaults.object(forKey: "PBRefreshOnApplicationFocus")
        defaults.set(false, forKey: "PBUseRepositoryWatcher")
        defaults.set(false, forKey: "PBRefreshOnApplicationFocus")
        defer {
            defaults.set(previousWatcher, forKey: "PBUseRepositoryWatcher")
            defaults.set(previousFocus, forKey: "PBRefreshOnApplicationFocus")
        }
        try prepareFixture()
        defer { try? removeFixture() }
        let controls = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controls) }
        let commands = controls.appendingPathComponent("commands")
        let executable = controls.appendingPathComponent("git")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(commands.path)'\nexec /usr/bin/git \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let discovery = GitBinaryDiscovery(preference: { nil }, environment: [:], output: { _, _ in "git version 2.50.1" }, notify: { _, _ in })
        XCTAssertTrue(discovery.accept(executable.path))
        document.removeWindowController(window)
        document.makeWindowControllers()
        let actual = try XCTUnwrap(document.windowControllers.first as? GitX.PBGitWindowController)
        actual.gitDiscovery = discovery
        _ = actual.window
        defer { actual.close() }
        waitForBranch("main", in: actual)
        func statusStarts() -> Int {
            ((try? String(contentsOf: commands, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("status ") }.count
        }
        let before = statusStarts()
        document.repository.currentBranch = PBGitRevSpecifier(ref: PBGitRef(string: "refs/heads/topic"))
        NotificationCenter.default.post(name: .PBGitRepositoryEvent, object: document.repository,
                                        userInfo: [kPBGitRepositoryEventTypeUserInfoKey: NSNumber(value: 0)])
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in statusStarts() > before }, object: nil)
        unexpected.isInverted = true
        wait(for: [unexpected], timeout: 2)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "main")
        let composed = "refs/heads/caf\u{00e9}"
        let decomposed = "refs/heads/cafe\u{0301}"
        try GitXTestGitFixture.run(["update-ref", composed, "HEAD"], in: directory)
        try GitXTestGitFixture.run(["pack-refs", "--all"], in: directory)
        document.repository.reloadRefs()
        let firstMapRefresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in statusStarts() > before }, object: nil)
        wait(for: [firstMapRefresh], timeout: 5)
        let packed = directory.appendingPathComponent(".git/packed-refs")
        let packedText = try String(contentsOf: packed, encoding: .utf8)
        XCTAssertTrue(packedText.utf8.contains(0xC3))
        let nfdText = packedText.replacingOccurrences(of: composed, with: decomposed)
        XCTAssertNotEqual(Data(packedText.utf8), Data(nfdText.utf8))
        let beforeMapOnly = statusStarts()
        try Data(nfdText.utf8).write(to: packed)
        document.repository.reloadRefs()
        let mapOnlyRefresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in statusStarts() > beforeMapOnly }, object: nil)
        wait(for: [mapOnlyRefresh], timeout: 5)
        XCTAssertEqual(localBranch(in: actual.window?.contentView), "main", "Only the references map changed; HEAD remains fixed")
        try GitXTestGitFixture.run(["checkout", "topic"], in: directory)
        document.repository.reloadRefs()
        waitForBranch("topic", in: actual)
        try GitXTestGitFixture.run(["checkout", "--detach", "main"], in: directory)
        NotificationCenter.default.post(name: .PBGitRepositoryEvent, object: document.repository,
                                        userInfo: [kPBGitRepositoryEventTypeUserInfoKey: NSNumber(value: PBGitRepositoryWatcherEventType.gitDirectory.rawValue)])
        let detached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.localBranch(in: actual.window?.contentView)?.hasPrefix("Detached") == true
        }, object: nil)
        wait(for: [detached], timeout: 5)
        XCTAssertGreaterThanOrEqual(statusStarts(), before + 2)
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
        controller.install()
        let toolbar = try XCTUnwrap(owner.window?.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount") })
        let popup = try XCTUnwrap(item.view?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository,
                                        userInfo: [GitX.RepositoryForgeAccountNotificationKey.providerName: "GitHub", GitX.RepositoryForgeAccountNotificationKey.login: "prior-owner"])
        XCTAssertEqual(popup.item(at: 0)?.title, "@prior-owner")
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository)
        XCTAssertEqual(popup.item(at: 0)?.title, "Forge")
        XCTAssertEqual(item.toolTip, "Configure a Forge account")
        owner.close()
        NotificationCenter.default.post(name: .repositoryForgeAccountDidChange, object: document.repository,
                                        userInfo: [GitX.RepositoryForgeAccountNotificationKey.login: "closed-owner"])
        XCTAssertEqual(popup.item(at: 0)?.title, "Forge", "Manual toolbar ownership also ends when its controller closes")
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

    func testNativeToolbarIsConstructedOnceAndDetachedWhenItsRepositoryIsRemoved() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let owner = ToolbarInstallationProbe(windowNibName: "RepositoryWindow")
        document.addWindowController(owner)
        defer { owner.close() }
        let nativeWindow = try XCTUnwrap(owner.window)
        XCTAssertNotNil(nativeWindow.toolbar?.delegate)
        XCTAssertEqual(owner.initialToolbars.values.withLock { $0.count }, 1)
        document.removeWindowController(owner)
        XCTAssertNil(owner.repository)
        XCTAssertNil(nativeWindow.toolbar)
        XCTAssertNil(nativeWindow.representedURL)
        document.addWindowController(owner)
        XCTAssertNotNil(nativeWindow.toolbar?.delegate)
        XCTAssertNotNil(owner.historyViewController)
        XCTAssertNotNil(nativeWindow.representedURL)
    }

    func testRepeatedToolbarInstallationPreservesCustomizationWithoutReassignment() throws {
        let defaults = UserDefaults.standard
        let configurationKey = "NSToolbar Configuration GitX.Repository.HistoryToolbar"
        let previousConfiguration = defaults.object(forKey: configurationKey)
        defer { defaults.set(previousConfiguration, forKey: configurationKey) }
        try prepareFixture()
        defer { try? removeFixture() }
        let nativeWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let owner = GitX.PBGitWindowController(window: nativeWindow)
        owner.repository = document.repository
        defer { owner.close() }
        let assignments = Mutex(0)
        let observation = nativeWindow.observe(\.toolbar, options: [.new]) { _, _ in assignments.withLock { $0 += 1 } }
        defer { observation.invalidate() }
        let toolbarController = GitX.RepositoryToolbarController(windowController: owner)
        toolbarController.install()
        let toolbar = try XCTUnwrap(nativeWindow.toolbar)
        toolbar.autosavesConfiguration = false
        let configurationBeforeCustomization = defaults.object(forKey: configurationKey) as? NSDictionary
        toolbar.displayMode = .iconOnly
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        XCTAssertEqual(toolbar.items.first?.itemIdentifier, .flexibleSpace)
        let identifiers = toolbar.items.map(\.itemIdentifier)
        toolbarController.install()
        XCTAssertTrue(nativeWindow.toolbar === toolbar)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), identifiers)
        XCTAssertEqual(assignments.withLock { $0 }, 1)
        XCTAssertFalse(toolbar.autosavesConfiguration)
        XCTAssertEqual(defaults.object(forKey: configurationKey) as? NSDictionary, configurationBeforeCustomization)
    }

    func testAdmittedPushReportsSuccessAfterEveryPresentationOwnerIsReleased() throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let remote = directory.appendingPathComponent("completion-target.git")
        try GitXTestGitFixture.run(["init", "--bare", remote.path], in: directory)
        try GitXTestGitFixture.run(["remote", "add", "origin", remote.path], in: directory)
        var pending: (@Sendable () throws -> Void)?
        var finished: ((NSError?) -> Void)?
        weak var weakOwner: GitX.PBGitWindowController?
        let successes = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: .repositoryRemoteOperationDidSucceed, object: document.repository, queue: nil) { _ in successes.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        autoreleasepool {
            let owner = GitX.PBGitWindowController(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false),
                                                   remoteProgressStarting: { _, _, operation, completion in pending = operation; finished = completion; return true })
            weakOwner = owner
            owner.repository = document.repository
            owner.pullRequestUIController?.performPush(branch: PBGitRef(string: "refs/heads/main"), remote: PBGitRef(string: "refs/remotes/origin"), requiresConfirmation: false)
            owner.close()
        }
        let operation = try XCTUnwrap(pending)
        pending = nil
        let deallocated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in weakOwner == nil }, object: nil)
        wait(for: [deallocated], timeout: 5)
        let executed = expectation(description: "The admitted operation reaches its actual Git result")
        let error = Mutex<NSError?>(nil)
        DispatchQueue.global().async {
            do { try operation() } catch let failure { error.withLock { $0 = failure as NSError } }
            executed.fulfill()
        }
        wait(for: [executed], timeout: 10)
        XCTAssertNil(error.withLock { $0 })
        finished?(error.withLock { $0 })
        finished?(error.withLock { $0 })
        finished = nil
        XCTAssertEqual(successes.withLock { $0 }, 1)
        XCTAssertEqual(try GitXTestGitFixture.run(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"], in: directory).standardOutput,
                       try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput)
    }

    func testAdmittedFetchPublishesOnceAfterItsOwnersDeallocate() throws {
        try remoteCompletionSurvivesPresentationRelease(kind: .fetch)
    }

    func testAdmittedPullPublishesOnceAfterItsOwnersDeallocate() throws {
        try remoteCompletionSurvivesPresentationRelease(kind: .pull)
    }

    func testRejectedPushReportsItsActualFailureAfterItsOwnersDeallocate() throws {
        try remoteCompletionSurvivesPresentationRelease(kind: .rejectedPush)
    }

    private enum CompletionKind { case fetch, pull, rejectedPush }

    private func remoteCompletionSurvivesPresentationRelease(kind: CompletionKind) throws {
        try prepareFixture()
        defer { try? removeFixture() }
        let remote = directory.appendingPathComponent("completion-remote.git")
        try GitXTestGitFixture.run(["init", "--bare", remote.path], in: directory)
        try GitXTestGitFixture.run(["remote", "add", "origin", remote.path], in: directory)
        let original = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try GitXTestGitFixture.run(["push", "--set-upstream", "origin", "main"], in: directory)
        try GitXTestGitFixture.run(["commit", "--allow-empty", "-m", "Incoming remote commit"], in: directory)
        let incoming = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        try GitXTestGitFixture.run(["push", "origin", "main"], in: directory)
        try GitXTestGitFixture.run(["reset", "--hard", original], in: directory)
        try GitXTestGitFixture.run(["update-ref", "refs/remotes/origin/main", original], in: directory)
        var pending: (@Sendable () throws -> Void)?
        var finished: ((NSError?) -> Void)?
        var admissions = 0
        var events: [GitX.RepositoryPushEvent] = []
        weak var weakOwner: GitX.PBGitWindowController?
        weak var weakCoordinator: GitX.RepositoryRemoteActionCoordinator?
        let successes = Mutex<[String]>([])
        let token = NotificationCenter.default.addObserver(forName: .repositoryRemoteOperationDidSucceed, object: document.repository, queue: nil) { notification in
            successes.withLock { $0.append(notification.userInfo?["operation"] as? String ?? "missing") }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        autoreleasepool {
            let owner = GitX.PBGitWindowController(window: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
            owner.repository = document.repository
            weakOwner = owner
            let coordinator = GitX.RepositoryRemoteActionCoordinator(repository: document.repository, windowController: owner, progressStarting: { _, _, operation, completion in
                admissions += 1
                pending = operation
                finished = completion
                return true
            })
            weakCoordinator = coordinator
            switch kind {
            case .pull:
                coordinator.performPull(branch: PBGitRef(string: "refs/heads/main"), remote: PBGitRef(string: "refs/remotes/origin"), rebase: false)
            case .fetch:
                coordinator.performFetch(for: PBGitRef(string: "refs/remotes/origin"))
            case .rejectedPush:
                coordinator.performPush(branch: PBGitRef(string: "refs/heads/main"), remote: PBGitRef(string: "refs/remotes/origin"), requiresConfirmation: false,
                                        pullRequestOption: nil, suppressesPostPushBrowserSuggestion: true, completion: { events.append($0) })
            }
            owner.close()
        }
        XCTAssertNil(weakOwner)
        XCTAssertNotNil(weakCoordinator, "Admitted completion retains its coordinator without retaining its presentation owner")
        let operation = try XCTUnwrap(pending)
        pending = nil
        let executed = expectation(description: "The original repository completes its admitted remote operation")
        let failure = Mutex<NSError?>(nil)
        DispatchQueue.global().async {
            do { try operation() } catch { failure.withLock { $0 = error as NSError } }
            executed.fulfill()
        }
        wait(for: [executed], timeout: 10)
        if kind == .rejectedPush {
            XCTAssertNotNil(failure.withLock { $0 })
        } else {
            XCTAssertNil(failure.withLock { $0 })
        }
        autoreleasepool {
            weakCoordinator?.performFetch(for: nil)
            finished?(failure.withLock { $0 })
            finished?(failure.withLock { $0 })
            finished = nil
        }
        XCTAssertEqual(admissions, 1, "Revoked presentation cannot admit more work")
        XCTAssertEqual(successes.withLock { $0 }, kind == .rejectedPush ? [] : [kind == .pull ? "pull" : "fetch"])
        if kind == .rejectedPush {
            XCTAssertEqual(events, [.began(createPullRequestSelected: false), .failed])
        }
        XCTAssertNil(weakCoordinator)
        let fetched = try GitXTestGitFixture.run(["rev-parse", "refs/remotes/origin/main"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try GitXTestGitFixture.run(["rev-parse", "HEAD"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .rejectedPush {
            XCTAssertEqual(fetched, incoming)
        }
        XCTAssertEqual(head, kind == .pull ? incoming : original)
        let remoteHead = try GitXTestGitFixture.run(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"], in: directory).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, incoming)
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

    private func activateFixtureWindow(_ window: NSWindow) {
        let activated = expectation(description: "Launch Services activates the existing test host")
        Task { @MainActor in
            await activateWorktreeTestApplication()
            activated.fulfill()
        }
        wait(for: [activated], timeout: 5)
        window.makeKeyAndOrderFront(nil)
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in NSApp.isActive && window.isKeyWindow }, object: nil)
        wait(for: [foreground], timeout: 5)
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
