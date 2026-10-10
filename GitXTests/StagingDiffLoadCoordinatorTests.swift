import XCTest

// swift6-safety-justification: XCTest owns the test lifetime; async callbacks touch only expectations and locked helpers.
final class StagingDiffLoadCoordinatorTests: XCTestCase, @unchecked Sendable {
    // swift6-safety-justification: NSLock protects every read and mutation of storage.
    private final class LockedValues<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testDiffActionAuthorityRequiresExactIdentityAndValidSide() async {
        func token(path: Data = Data([0xFF]), staged: Bool = false, tree: String = "tree", diff: String = "patch",
                   lines: UInt = 3, status: Int = 2, hasStaged: Bool = false, visual: String = "") -> StagingDiffActionContext
        {
            StagingDiffActionContext(rawPath: path, staged: staged, parentTree: tree, diff: diff, contextLines: lines,
                                     status: status, hasStagedChanges: hasStaged, visualIdentity: visual)
        }
        let original = token()
        XCTAssertEqual(StagingDiffActionContext(dictionary: original.dictionary), original)
        XCTAssertEqual(token(), original, "An unchanged render retains authority")
        XCTAssertTrue(original.permits("stage")); XCTAssertTrue(original.permits("discard"))
        XCTAssertFalse(original.permits("unstage")); XCTAssertFalse(original.permits("unknown"))
        let staged = token(staged: true)
        XCTAssertTrue(staged.permits("unstage")); XCTAssertFalse(staged.permits("stage")); XCTAssertFalse(staged.permits("discard"))
        for changed in [token(path: Data("other".utf8)), staged, token(tree: "other"), token(diff: "different"),
                        token(lines: 4), token(status: 3), token(hasStaged: true), token(visual: "image-sha")]
        {
            XCTAssertNotEqual(changed.contentIdentity, original.contentIdentity)
        }
        XCTAssertNotEqual(token(path: Data("é".utf8)), token(path: Data("e\u{301}".utf8)))
        XCTAssertNotEqual(token(diff: "é"), token(diff: "e\u{301}"), "Diff identity retains exact UTF-8 bytes")
        for (key, invalid) in [("rawPath", "path" as Any), ("rawPath", Data()), ("rawPath", Data([0])),
                               ("staged", "true"), ("parentTree", ""), ("parentTree", 1),
                               ("contentIdentity", "short"), ("contentIdentity", String(repeating: "Z", count: 64)),
                               ("contextLines", "3"), ("status", "2"), ("hasStagedChanges", "false"), ("visualIdentity", 1)]
        {
            var dictionary = original.dictionary; dictionary[key] = invalid
            XCTAssertNil(StagingDiffActionContext(dictionary: dictionary), key)
        }
        var extended = original.dictionary; extended["extra"] = true
        XCTAssertNil(StagingDiffActionContext(dictionary: extended))
        let request = request(path: "context.txt")
        let validated = expectation(description: "validated production supplies content authority")
        StagingDiffLoadCoordinator { _ in .validated(diff: "patch", parentTree: "actual-tree", visualIdentity: "actual-image") }.schedule([request]) { output in
            let authority = output.sections.first?.actionContext
            XCTAssertEqual(authority?.parentTree, "actual-tree"); XCTAssertEqual(authority?.visualIdentity, "actual-image")
            validated.fulfill()
        }
        await fulfillment(of: [validated], timeout: 3)
    }

    func testUnavailableImageIdentityRetainsDiffWithoutMutationAuthority() async {
        let delivered = expectation(description: "read-only image delivered")
        StagingDiffLoadCoordinator { _ in .readOnly(diff: "binary diff", detail: "unsafe target") }.schedule([request(path: "unsafe.png")]) { output in
            XCTAssertEqual(output.sections.first?.text, "binary diff")
            XCTAssertTrue(output.sections.first?.title.contains("Actions unavailable") == true)
            XCTAssertEqual(output.sections.first?.stagingChrome, false)
            XCTAssertNil(output.sections.first?.actionContext)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 3)
    }

    func testSchedulingDoesNotWaitForDiffProduction() async {
        let producerStarted = expectation(description: "producer started")
        let schedulingReturned = expectation(description: "scheduling returned")
        let delivered = expectation(description: "result delivered")
        let producerGate = DispatchSemaphore(value: 0)
        let coordinator = StagingDiffLoadCoordinator { request in
            producerStarted.fulfill()
            producerGate.wait()
            return .validated(diff: "diff for \(request.path)", parentTree: "HEAD", visualIdentity: "")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.schedule([self.request(path: "slow.txt")]) { output in
                XCTAssertEqual(output.sections.map(\.path), ["slow.txt"])
                delivered.fulfill()
            }
            schedulingReturned.fulfill()
        }

        await fulfillment(of: [producerStarted, schedulingReturned], timeout: 2)
        producerGate.signal()
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testNewestGenerationWinsAfterSupersededWorkFinishes() async {
        let firstStarted = expectation(description: "first producer started")
        let newestDelivered = expectation(description: "newest result delivered")
        let firstGate = DispatchSemaphore(value: 0)
        let producedPaths = LockedValues<String>()
        let coordinator = StagingDiffLoadCoordinator { request in
            producedPaths.append(request.path)
            if request.path == "first.txt" {
                firstStarted.fulfill()
                firstGate.wait()
            }
            return .validated(diff: "diff for \(request.path)", parentTree: "HEAD", visualIdentity: "")
        }

        coordinator.schedule([request(path: "first.txt")]) { _ in
            XCTFail("a superseded generation must not be delivered")
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        coordinator.schedule([request(path: "newest.txt")]) { output in
            XCTAssertEqual(output.sections.map(\.path), ["newest.txt"])
            newestDelivered.fulfill()
        }
        firstGate.signal()

        await fulfillment(of: [newestDelivered], timeout: 2)
        XCTAssertEqual(producedPaths.values, ["first.txt", "newest.txt"])
    }

    func testSupersededQueuedGenerationsAndRemainingSectionsSkipProduction() async {
        let started = expectation(description: "first section started")
        let delivered = expectation(description: "newest generation delivered")
        let gate = DispatchSemaphore(value: 0)
        let paths = LockedValues<String>()
        let coordinator = StagingDiffLoadCoordinator { request in
            paths.append(request.path)
            if request.path == "first.txt" {
                started.fulfill(); _ = gate.wait(timeout: .now() + 5)
            }
            return .validated(diff: "diff for \(request.path)", parentTree: "HEAD", visualIdentity: "")
        }
        coordinator.schedule([request(path: "first.txt"), request(path: "obsolete-section.txt")]) { _ in XCTFail("Superseded generation published") }
        await fulfillment(of: [started], timeout: 2)
        coordinator.schedule([request(path: "obsolete-queued.txt")]) { _ in XCTFail("Superseded queued generation published") }
        coordinator.schedule([request(path: "newest.txt")]) { output in
            XCTAssertEqual(output.sections.map(\.path), ["newest.txt"])
            delivered.fulfill()
        }
        gate.signal()
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(paths.values, ["first.txt", "newest.txt"])
    }

    func testInvalidationDiscardsPendingWorkWithoutCancellingIt() async {
        let producerStarted = expectation(description: "producer started")
        let producerFinished = expectation(description: "producer finished")
        let resultDelivered = expectation(description: "result not delivered")
        resultDelivered.isInverted = true
        let producerGate = DispatchSemaphore(value: 0)
        let coordinator = StagingDiffLoadCoordinator { _ in
            producerStarted.fulfill()
            producerGate.wait()
            producerFinished.fulfill()
            return .validated(diff: "obsolete diff", parentTree: "HEAD", visualIdentity: "")
        }

        coordinator.schedule([request(path: "obsolete.txt")]) { _ in
            resultDelivered.fulfill()
        }
        await fulfillment(of: [producerStarted], timeout: 2)
        coordinator.invalidate()
        producerGate.signal()

        await fulfillment(of: [producerFinished], timeout: 2)
        await fulfillment(of: [resultDelivered], timeout: 0.2)
    }

    func testOrderedPartialFailuresHaveDetailedControlFreeSections() async {
        let delivered = expectation(description: "ordered result delivered")
        let producedPaths = LockedValues<String>()
        let coordinator = StagingDiffLoadCoordinator { request in
            producedPaths.append(request.path)
            if request.path == "broken.txt" {
                return .failure("git exited 128: invalid object name")
            }
            return .validated(diff: "diff for \(request.path)", parentTree: "HEAD", visualIdentity: "")
        }
        let requests = [
            request(path: "first.txt", staged: false),
            request(path: "broken.txt", staged: true),
            request(path: "last.txt", staged: false),
        ]

        coordinator.schedule(requests) { output in
            XCTAssertEqual(output.sections.map(\.path), ["first.txt", "broken.txt", "last.txt"])
            XCTAssertEqual(output.sections.map(\.stagingChrome), [true, false, true])
            XCTAssertEqual(output.sections[1].title, "Diff unavailable — broken.txt")
            XCTAssertTrue(output.sections[1].text.contains("Half Dark could not load the diff for broken.txt."))
            XCTAssertTrue(output.sections[1].text.contains("git exited 128: invalid object name"))
            XCTAssertEqual(output.sections[1].context, "readOnly")
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(producedPaths.values, requests.map(\.path))
    }

    func testContextLinesParticipateInOffMainCacheIdentity() async {
        let firstDelivered = expectation(description: "first context delivered")
        let secondDelivered = expectation(description: "second context delivered")
        let identifiers = LockedValues<String>()
        let coordinator = StagingDiffLoadCoordinator { request in
            .validated(diff: "context \(request.contextLines)", parentTree: "HEAD", visualIdentity: "")
        }

        coordinator.schedule([request(path: "context.txt", contextLines: 3)]) { output in
            identifiers.append(output.cacheIdentifier)
            firstDelivered.fulfill()
        }
        await fulfillment(of: [firstDelivered], timeout: 2)
        coordinator.schedule([request(path: "context.txt", contextLines: 8)]) { output in
            identifiers.append(output.cacheIdentifier)
            secondDelivered.fulfill()
        }
        await fulfillment(of: [secondDelivered], timeout: 2)

        XCTAssertEqual(identifiers.values, [
            "staging:u:\(Data("context.txt".utf8).base64EncodedString()):ctx3",
            "staging:u:\(Data("context.txt".utf8).base64EncodedString()):ctx8",
        ])
    }

    func testRawBytesParticipateInCacheIdentityWhenDisplayNamesCollide() async {
        let firstDelivered = expectation(description: "raw filename delivered")
        let secondDelivered = expectation(description: "literal filename delivered")
        let identifiers = LockedValues<String>()
        let coordinator = StagingDiffLoadCoordinator { _ in .validated(diff: "preview", parentTree: "HEAD", visualIdentity: "") }
        func collision(_ rawPath: Data) -> StagingDiffLoadRequest {
            StagingDiffLoadRequest(path: "f\\xFF", rawPath: rawPath, status: 1,
                                   hasStagedChanges: false, staged: false, parentTree: "HEAD",
                                   contextLines: 3, workingDirectoryURL: nil, syntheticUntracked: false)
        }
        coordinator.schedule([collision(Data([0x66, 0xFF]))]) { output in
            identifiers.append(output.cacheIdentifier)
            firstDelivered.fulfill()
        }
        await fulfillment(of: [firstDelivered], timeout: 2)
        coordinator.schedule([collision(Data("f\\xFF".utf8))]) { output in
            identifiers.append(output.cacheIdentifier)
            secondDelivered.fulfill()
        }
        await fulfillment(of: [secondDelivered], timeout: 2)
        XCTAssertNotEqual(identifiers.values[0], identifiers.values[1])
    }

    private func request(
        path: String,
        staged: Bool = false,
        contextLines: UInt = 3
    ) -> StagingDiffLoadRequest {
        StagingDiffLoadRequest(
            path: path,
            status: 2,
            hasStagedChanges: staged,
            staged: staged,
            parentTree: "HEAD",
            contextLines: contextLines,
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/repository"),
            syntheticUntracked: false
        )
    }
}
