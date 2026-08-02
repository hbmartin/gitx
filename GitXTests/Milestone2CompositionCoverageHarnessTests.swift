import XCTest

@MainActor
final class Milestone2CompositionCoverageHarnessTests: XCTestCase {
    func testShippedAsyncCompositionCoverageProof() async {
        let proof = await withCheckedContinuation { continuation in
            PBMilestone2CompositionCoverageHarness.asynchronousProof { proof in
                continuation.resume(returning: proof)
            }
        }

        XCTAssertEqual(proof & 0b0001, 0b0001, "Mutation-state composition proof failed")
        XCTAssertEqual(proof & 0b0010, 0b0010, "Pull Request provider composition proof failed")
        XCTAssertEqual(proof & 0b0100, 0b0100, "Clone-loader composition proof failed")
        XCTAssertEqual(proof & 0b1000, 0b1000, "Clone-service composition proof failed")
    }

    func testShippedReviewReadCompositionCoverageProof() async {
        let proof = await withCheckedContinuation { continuation in
            PBMilestone2CompositionCoverageHarness.reviewReadProof { proof in
                continuation.resume(returning: proof)
            }
        }

        XCTAssertEqual(proof, 1)
    }

    func testShippedReviewMutationCompositionCoverageProof() async {
        let proof = await withCheckedContinuation { continuation in
            PBMilestone2CompositionCoverageHarness.reviewMutationProof { proof in
                continuation.resume(returning: proof)
            }
        }

        XCTAssertEqual(proof, 1)
    }
}
