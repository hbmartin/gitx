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
            XCTAssertTrue(output.sections[1].text.contains("GitX could not load the diff for broken.txt."))
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
            "staging:u:context.txt:ctx3",
            "staging:u:context.txt:ctx8",
        ])
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
