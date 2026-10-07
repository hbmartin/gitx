import Foundation
import XCTest

final class RepositoryPushRecoveryEvidenceTests: XCTestCase {
    private let source = String(repeating: "a", count: 40)
    private let fetched = String(repeating: "b", count: 40)

    func testFetchMappingAllowsUnrelatedRulesAndRequiresUniqueBothDirections() throws {
        let heads = "+refs/heads/*:refs/remotes/origin/*"
        let destination = "refs/heads/main"
        let tracking = "refs/remotes/origin/main"
        try RepositoryPushFetchMapping.validate([heads, "+refs/pull/*/head:refs/remotes/origin/pr/*"],
                                                destination: destination, tracking: tracking)
        try RepositoryPushFetchMapping.validate(["refs/heads/main:refs/cache/main"],
                                                destination: destination, tracking: "refs/cache/main")
        for rules in [[heads, heads], [heads, "refs/heads/main:refs/cache/main"],
                      [heads, "+refs/pull/*/head:refs/remotes/origin/*"], [],
                      [heads, "^refs/heads/main"], [heads, "^refs/heads/*"]]
        {
            XCTAssertThrowsError(try RepositoryPushFetchMapping.validate(rules, destination: destination, tracking: tracking))
        }
        XCTAssertThrowsError(try RepositoryPushFetchMapping.validate([heads], destination: destination, tracking: "refs/cache/main"))
        try RepositoryPushFetchMapping.validate([heads, "+refs/pull/*/head:refs/remotes/origin/*", "^refs/pull/*/head"],
                                                destination: destination, tracking: tracking)
    }

    func testRefspecSupportRejectsUnqualifiedMissingAndMalformedMappings() throws {
        for raw in ["main:refs/cache/main", "refs/heads/main:main", "refs/heads/main", "refs/heads/*:refs/cache/main",
                    "refs/heads/main:refs/cache/*", "^main", "refs/heads/main:refs/cache/has space", "refs/heads/main\0:refs/cache/main"]
        {
            XCTAssertThrowsError(try RepositoryFetchRefspec(raw), raw)
        }
        let rule = try RepositoryFetchRefspec("+refs/heads/*:refs/cache/*")
        XCTAssertEqual(rule.source, "refs/heads/*")
        XCTAssertEqual(rule.destination, "refs/cache/*")
        XCTAssertFalse(rule.isNegative)
        XCTAssertTrue(try rule.matchesSource("refs/heads/topic"))
        XCTAssertFalse(try rule.matchesDestination("refs/remotes/topic"))
        XCTAssertEqual(try rule.transform("refs/heads/topic"), "refs/cache/topic")
        XCTAssertEqual(try rule.transform("refs/cache/topic", reverse: true), "refs/heads/topic")
        XCTAssertThrowsError(try rule.transform("refs/tags/topic"))
        let negative = try RepositoryFetchRefspec("^refs/heads/private/*")
        XCTAssertTrue(negative.isNegative)
        XCTAssertEqual(negative.source, "refs/heads/private/*")
        XCTAssertEqual(negative.raw, "^refs/heads/private/*")
        XCTAssertTrue(try negative.matchesSource("refs/heads/private/topic"))
        XCTAssertFalse(try negative.matchesSource("refs/heads/main"))
        XCTAssertFalse(try negative.matchesDestination("refs/cache/main"))
        XCTAssertThrowsError(try negative.transform("refs/heads/private/topic"))
        XCTAssertThrowsError(try negative.transform("refs/cache/topic", reverse: true))
    }

    func testReflogLimitRetainsNewestEntriesAndNeverUsesDetectionEntry() throws {
        let empty = try RepositoryPushReflogEvidence.capture(Data(), oidLength: 40)
        XCTAssertEqual(empty.retainedOIDs, [])
        XCTAssertFalse(empty.isTruncated)
        let exact = try RepositoryPushReflogEvidence.capture(RepositoryPushObjectEvidence.input(Array(repeating: source, count: 1024)), oidLength: 40)
        XCTAssertEqual(exact.retainedOIDs.count, 1024)
        XCTAssertFalse(exact.isTruncated)
        let truncated = try RepositoryPushReflogEvidence.capture(RepositoryPushObjectEvidence.input(Array(repeating: source, count: 1024) + [fetched]), oidLength: 40)
        XCTAssertEqual(truncated.retainedOIDs, exact.retainedOIDs)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(RepositoryPushReflogEvidence.witnesses(sourceOID: source, reflogOIDs: [fetched, source, fetched]), [source, fetched])
        XCTAssertThrowsError(try RepositoryPushReflogEvidence.capture(RepositoryPushObjectEvidence.input(Array(repeating: source, count: 1026)), oidLength: 40))
    }

    func testReflogRequiresCompleteConsistentASCIIObjectRecords() throws {
        for data in [Data(source.utf8), Data((source + "\r\n").utf8), Data((source + "\n\n").utf8),
                     Data("invalid\n".utf8), Data([0xFF, 10]), Data((String(repeating: "a", count: 64) + "\n").utf8)]
        {
            XCTAssertThrowsError(try RepositoryPushReflogEvidence.capture(data, oidLength: 40))
        }
        let sha256 = String(repeating: "a", count: 64)
        XCTAssertEqual(try RepositoryPushReflogEvidence.capture(Data((sha256 + "\n").utf8), oidLength: 64).retainedOIDs, [sha256])
    }

    func testCommitValidationRequiresEveryFrozenObjectInOrderAndCommitType() throws {
        let valid = source + " commit 100\n" + fetched + " commit 200\n"
        try RepositoryPushObjectEvidence.validateCommits(Data(valid.utf8), expectedOIDs: [source, fetched])
        for output in ["", valid.replacingOccurrences(of: "commit", with: "blob"), valid.replacingOccurrences(of: "commit", with: "tag"),
                       source + " missing\n" + fetched + " commit 200\n", fetched + " commit 200\n" + source + " commit 100\n",
                       source + " commit 0\n" + fetched + " commit 200\n", valid.replacingOccurrences(of: "100", with: "-1"),
                       valid.replacingOccurrences(of: "100", with: "18446744073709551616"),
                       valid.replacingOccurrences(of: "100", with: "1 0"), String(valid.dropLast()), valid + "\n"]
        {
            XCTAssertThrowsError(try RepositoryPushObjectEvidence.validateCommits(Data(output.utf8), expectedOIDs: [source, fetched]))
        }
        XCTAssertThrowsError(try RepositoryPushObjectEvidence.validateCommits(Data([0xFF, 10]), expectedOIDs: [source]))
    }

    func testAncestryProofAcceptsOnlyEmptyOrOneCompleteObjectRecord() throws {
        XCTAssertFalse(try RepositoryPushObjectEvidence.provesAncestry(Data(), oidLength: 40))
        XCTAssertTrue(try RepositoryPushObjectEvidence.provesAncestry(Data((source + "\n").utf8), oidLength: 40))
        for data in [Data(source.utf8), Data((source + "\r\n").utf8), Data((source + "\n" + fetched + "\n").utf8),
                     Data("\n".utf8), Data("invalid\n".utf8), Data([0xFF, 10]), Data((String(repeating: "a", count: 64) + "\n").utf8)]
        {
            XCTAssertThrowsError(try RepositoryPushObjectEvidence.provesAncestry(data, oidLength: 40))
        }
    }
}
