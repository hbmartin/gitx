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
        let token = StagingDiffActionContext(snapshotRevision: 7, loadIdentity: UUID(), rawPath: Data([0xFF]), staged: false)
        XCTAssertEqual(StagingDiffActionContext(dictionary: token.dictionary), token)
        XCTAssertTrue(token.permits("stage"))
        XCTAssertTrue(token.permits("discard"))
        XCTAssertFalse(token.permits("unstage"))
        XCTAssertFalse(token.permits("unknown"))
        let staged = StagingDiffActionContext(snapshotRevision: 7, loadIdentity: token.loadIdentity, rawPath: token.rawPath, staged: true)
        XCTAssertTrue(staged.permits("unstage"))
        XCTAssertFalse(staged.permits("stage"))
        XCTAssertFalse(staged.permits("discard"))
        XCTAssertNotEqual(staged, token)
        for (key, invalid) in [("snapshotRevision", "7" as Any), ("loadIdentity", "bad UUID"), ("rawPath", Data()), ("rawPath", Data([0])), ("staged", "true")] {
            var dictionary = token.dictionary
            dictionary[key] = invalid
            XCTAssertNil(StagingDiffActionContext(dictionary: dictionary))
        }
        var extended = token.dictionary
        extended["extra"] = true
        XCTAssertNil(StagingDiffActionContext(dictionary: extended))
        let delivered = expectation(description: "authority delivered")
        var request = request(path: "context.txt")
        request = StagingDiffLoadRequest(path: request.path, rawPath: request.rawPath, status: request.status,
                                         hasStagedChanges: request.hasStagedChanges, staged: request.staged,
                                         parentTree: request.parentTree, contextLines: request.contextLines,
                                         workingDirectoryURL: request.workingDirectoryURL,
                                         syntheticUntracked: request.syntheticUntracked, actionContext: token)
        StagingDiffLoadCoordinator { _ in .success("patch") }.schedule([request]) { output in
            XCTAssertEqual(output.sections.first?.actionContext, token)
            XCTAssertFalse(output.cacheIdentifier.contains(token.loadIdentity.uuidString))
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
            return .success("diff for \(request.path)")
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
            return .success("diff for \(request.path)")
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
            return .success("obsolete diff")
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
            return .success("diff for \(request.path)")
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
            .success("context \(request.contextLines)")
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
        let coordinator = StagingDiffLoadCoordinator { _ in .success("preview") }
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
