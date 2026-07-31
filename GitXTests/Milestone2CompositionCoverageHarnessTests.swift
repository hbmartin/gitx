import XCTest

@MainActor
final class Milestone2CompositionCoverageHarnessTests: XCTestCase {
    func testShippedAsyncCompositionCoverageProof() async {
        let proof = await withCheckedContinuation { continuation in
            PBMilestone2CompositionCoverageHarness.asynchronousProof { proof in
                continuation.resume(returning: proof)
            }
        }

        XCTAssertEqual(proof, 0b1111)
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
