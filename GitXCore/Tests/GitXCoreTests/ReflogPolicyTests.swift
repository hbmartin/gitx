import Foundation
@testable import GitXCore
import XCTest

final class ReflogPolicyTests: XCTestCase {
    private let oid = String(repeating: "a", count: 40)

    func testParsesEventTimeActorAndPinnedObjectWithoutUsingCommitTime() throws {
        let fields = [oid, "HEAD@{2026-10-01T12:34:56-07:00}", "commit (amend): subject", "Åctor", "actor@example.invalid", "subject"]
        let entries = try ReflogParser.entries(from: Data((fields.joined(separator: "\0") + "\0\n").utf8))
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.objectID, oid)
        XCTAssertEqual(entry.actor, "Åctor")
        XCTAssertEqual(entry.email, "actor@example.invalid")
        XCTAssertEqual(entry.action, "commit (amend): subject")
        XCTAssertEqual(entry.subject, "subject")
        XCTAssertEqual(entry.eventDate, ISO8601DateFormatter().date(from: "2026-10-01T19:34:56Z"))
    }

    func testInvalidDisplayBytesDoNotDiscardAnIdentifiableEvent() throws {
        let fields = [Data(oid.utf8), Data("HEAD@{2026-10-01T00:00:00Z}".utf8),
                      Data([0x65, 0xFF]), Data("Åctor".utf8) + Data([0xFE]), Data([0xFF]), Data([0x73, 0xFF])]
        var record = Data()
        for field in fields {
            record.append(field); record.append(0)
        }
        record.append(10)
        let entry = try XCTUnwrap(ReflogParser.entries(from: record).first)
        XCTAssertEqual(entry.objectID, oid)
        XCTAssertEqual(entry.action, "e\\xFF")
        XCTAssertEqual(entry.actor, "Åctor\\xFE")
        XCTAssertEqual(entry.email, "\\xFF")
        XCTAssertEqual(entry.subject, "s\\xFF")
    }

    func testEmptyAndRepeatedEventsPreserveOrderAndSHA256() throws {
        XCTAssertEqual(try ReflogParser.entries(from: Data()), [])
        let second = String(repeating: "b", count: 64)
        let rows = [second, oid, oid].map { [$0, "refs/heads/topic@{2026-10-01T00:00:00+00:00}", "reset: moving to HEAD", "User", "", ""].joined(separator: "\0") + "\0\n" }
        XCTAssertEqual(try ReflogParser.entries(from: Data(rows.joined().utf8)).map(\.objectID), [second, oid, oid])
    }

    func testRejectsIncompleteOrMalformedRecordsInsteadOfPartialRecoveryEvidence() {
        for fields in [
            [oid],
            ["--bad", "HEAD@{2026-10-01T00:00:00Z}", "event", "actor", "", "subject"],
            [oid, "HEAD@{0}", "event", "actor", "", "subject"],
            [oid, "HEAD@{not-a-date}", "event", "actor", "", "subject"],
        ] {
            XCTAssertThrowsError(try ReflogParser.entries(from: Data((fields.joined(separator: "\0") + "\0\n").utf8)))
        }
        XCTAssertThrowsError(try ReflogParser.entries(from: Data([0xFF])))
        XCTAssertThrowsError(try ReflogParser.entries(from: Data((oid + "\0HEAD@{2026-10-01T00:00:00Z}\0event\0actor\0mail\0subject").utf8)))
    }

    func testRecoveryModesDescribeTheirDifferentEffects() {
        XCTAssertEqual(ReflogResetMode.allCases.map(\.rawValue), ["soft", "mixed", "hard"])
        XCTAssertTrue(ReflogResetMode.soft.explanation.contains("unchanged"))
        XCTAssertTrue(ReflogResetMode.mixed.explanation.contains("unstaged"))
        XCTAssertTrue(ReflogResetMode.hard.explanation.contains("discard"))
        XCTAssertFalse(ReflogResetMode.soft.requiresDiscardConfirmation)
        XCTAssertFalse(ReflogResetMode.mixed.requiresDiscardConfirmation)
        XCTAssertTrue(ReflogResetMode.hard.requiresDiscardConfirmation)
    }

    func testReadFailuresExplainTheUnavailableEvidence() {
        XCTAssertTrue(ReflogReadError.incompleteOutput.localizedDescription.contains("incomplete"))
        XCTAssertTrue(ReflogReadError.invalidRecord.localizedDescription.contains("identified safely"))
        XCTAssertFalse(ReflogParser.isObjectID(String(repeating: "A", count: 40)))
        XCTAssertFalse(ReflogParser.isObjectID(String(repeating: "g", count: 40)))
        XCTAssertTrue(ReflogParser.isObjectID(String(repeating: "1", count: 40)))
    }

    func testResetEligibilityRequiresCompleteIdleNonbareCheckoutAndAvailableCommit() {
        XCTAssertNil(ReflogRecoveryPolicy.blocker(isBare: false, operationInProgress: false, hasHead: true, targetAvailable: true, previewComplete: true))
        XCTAssertNotNil(ReflogRecoveryPolicy.blocker(isBare: true, operationInProgress: false, hasHead: true, targetAvailable: true, previewComplete: true))
        XCTAssertNotNil(ReflogRecoveryPolicy.blocker(isBare: false, operationInProgress: true, hasHead: true, targetAvailable: true, previewComplete: true))
        XCTAssertNotNil(ReflogRecoveryPolicy.blocker(isBare: false, operationInProgress: false, hasHead: false, targetAvailable: true, previewComplete: true))
        XCTAssertNotNil(ReflogRecoveryPolicy.blocker(isBare: false, operationInProgress: false, hasHead: true, targetAvailable: false, previewComplete: true))
        XCTAssertNotNil(ReflogRecoveryPolicy.blocker(isBare: false, operationInProgress: false, hasHead: true, targetAvailable: true, previewComplete: false))
    }
}
