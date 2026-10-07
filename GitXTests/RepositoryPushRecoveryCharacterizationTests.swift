import ObjectiveGit
import XCTest

final class RepositoryPushRecoveryCharacterizationTests: XCTestCase {
    func testBranchReferenceIdentityPreservesLeadingPlusAndEquals() {
        for name in ["+feature", "feat=x"] {
            let ref = PBGitRef(string: "refs/heads/" + name)
            XCTAssertTrue(ref.isBranch)
            XCTAssertEqual(ref.ref, "refs/heads/" + name)
            XCTAssertEqual(ref.shortName(), name)
        }
    }

    func testVendoredFetchRefspecsTransformExactAndWildcardMappingsBothWays() throws {
        let cases = [
            ("+refs/heads/main:refs/cache/origin/review", "refs/heads/main", "refs/cache/origin/review"),
            ("+refs/heads/*:refs/remotes/origin/*", "refs/heads/topic/nested", "refs/remotes/origin/topic/nested"),
            ("refs/pull/*/head:refs/remotes/origin/pr/*", "refs/pull/42/head", "refs/remotes/origin/pr/42"),
        ]
        for (raw, source, destination) in cases {
            var pointer: OpaquePointer?
            XCTAssertEqual(git_refspec_parse(&pointer, raw, 1), 0)
            let spec = try XCTUnwrap(pointer)
            defer { git_refspec_free(spec) }
            XCTAssertEqual(git_refspec_src_matches(spec, source), 1)
            XCTAssertEqual(git_refspec_dst_matches(spec, destination), 1)
            XCTAssertEqual(git_refspec_src_matches(spec, "refs/tags/unrelated"), 0)
            XCTAssertEqual(git_refspec_dst_matches(spec, "refs/cache/unrelated"), 0)

            var forward = git_buf()
            defer { git_buf_dispose(&forward) }
            XCTAssertEqual(git_refspec_transform(&forward, spec, source), 0)
            XCTAssertEqual(try String(cString: XCTUnwrap(forward.ptr)), destination)

            var reverse = git_buf()
            defer { git_buf_dispose(&reverse) }
            XCTAssertEqual(git_refspec_rtransform(&reverse, spec, destination), 0)
            XCTAssertEqual(try String(cString: XCTUnwrap(reverse.ptr)), source)
        }
    }

    func testVendoredFetchRefspecsRecognizeNegativeRulesAndRejectMalformedPatterns() throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(git_refspec_parse(&pointer, "^refs/heads/private/*", 1), 0)
        let negative = try XCTUnwrap(pointer)
        defer { git_refspec_free(negative) }
        XCTAssertEqual(git_refspec_src_matches_negative(negative, "refs/heads/private/topic"), 1)
        XCTAssertEqual(git_refspec_src_matches_negative(negative, "refs/heads/main"), 0)
        XCTAssertNil(git_refspec_dst(negative))

        for raw in ["refs/heads/*:refs/remotes/origin/main", "refs/heads/main:refs/remotes/origin/*", "refs/heads/has space:refs/remotes/origin/main"] {
            var malformed: OpaquePointer?
            XCTAssertNotEqual(git_refspec_parse(&malformed, raw, 1), 0)
            XCTAssertNil(malformed)
        }
    }
}
