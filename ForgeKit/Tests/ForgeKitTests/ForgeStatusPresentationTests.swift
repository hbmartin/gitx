@testable import ForgeKit
import Foundation
import XCTest

final class ForgeStatusPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testUnboundRepositoryRemainsLocalOnlyAndCannotRefresh() {
        let presentation = ForgeRepositoryStatusPresenter.present(.unbound, now: now)

        XCTAssertEqual(presentation.repositoryText, "No Forge Repository")
        XCTAssertNil(presentation.accountText)
        XCTAssertEqual(presentation.freshnessText, "Local only")
        XCTAssertEqual(presentation.accessibilityLabel, "No Forge Repository; local Git remains available")
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertFalse(presentation.isRefreshEnabled)
        XCTAssertEqual(presentation.refreshDisabledReason, "Bind a Forge Repository to refresh its overlay")
        XCTAssertNil(presentation.rateLimitResetAt)
        XCTAssertFalse(presentation.requiresClockUpdates)
        XCTAssertNil(presentation.detailsAction)
        XCTAssertNil(presentation.toolbarPersistentFailureText)
    }

    func testPersistentStorageFailureRemainsVisibleAndMirroredWithoutABinding() {
        let presentation = ForgeRepositoryStatusPresenter.present(
            ForgeRepositoryStatusInput(
                repository: nil,
                access: .noAccount,
                freshness: .notLoaded,
                diagnostic: .unavailable(.persistentStorageFailure)
            ),
            now: now
        )

        XCTAssertEqual(presentation.repositoryText, "No Forge Repository")
        XCTAssertEqual(presentation.freshnessText, "Local only")
        XCTAssertEqual(presentation.diagnosticText, "Forge Unavailable")
        XCTAssertEqual(presentation.detailsAction, .recoverForgeData)
        XCTAssertEqual(presentation.toolbarPersistentFailureText, "Forge Unavailable")
        XCTAssertEqual(presentation.accessibilityLabel, "No Forge Repository; local Git remains available; Forge Unavailable")
        XCTAssertFalse(presentation.isRefreshEnabled)
    }

    func testAccessLabelsAndFreshnessAgeBoundaries() {
        let cases: [(ForgeStatusAccess, ForgeOverlayFreshness, String, String)] = [
            (.noAccount, .notLoaded, "No Account", "Not refreshed"),
            (.publicAccess, .current(fetchedAt: now.addingTimeInterval(30)), "Public access", "Updated just now"),
            (.account(login: "octocat"), .current(fetchedAt: now.addingTimeInterval(-60)), "octocat", "Updated 1m ago"),
            (.account(login: "octocat"), .current(fetchedAt: now.addingTimeInterval(-3599)), "octocat", "Updated 59m ago"),
            (.account(login: "octocat"), .current(fetchedAt: now.addingTimeInterval(-3600)), "octocat", "Updated 1h ago"),
            (.account(login: "octocat"), .current(fetchedAt: now.addingTimeInterval(-86400)), "octocat", "Updated 1d ago"),
            (.publicAccess, .stale(cachedAt: nil), "Public access", "Stale · no cached data"),
            (.publicAccess, .stale(cachedAt: now.addingTimeInterval(-120)), "Public access", "Stale · cached 2m ago"),
        ]

        for (access, freshness, account, freshnessText) in cases {
            let presentation = ForgeRepositoryStatusPresenter.present(
                input(access: access, freshness: freshness),
                now: now
            )
            XCTAssertEqual(presentation.repositoryText, "hbmartin/gitx")
            XCTAssertEqual(presentation.accountText, account)
            XCTAssertEqual(presentation.freshnessText, freshnessText)
            XCTAssertTrue(presentation.isRefreshEnabled)
            XCTAssertEqual(
                presentation.requiresClockUpdates,
                freshness != .notLoaded && freshness != .stale(cachedAt: nil)
            )
        }
    }

    func testRefreshingUsesCachedAgeAndDisablesDuplicateRefresh() {
        let withoutCache = ForgeRepositoryStatusPresenter.present(
            input(freshness: .refreshing(cachedAt: nil)),
            now: now
        )
        XCTAssertEqual(withoutCache.freshnessText, "Refreshing")
        XCTAssertTrue(withoutCache.showsProgress)
        XCTAssertFalse(withoutCache.requiresClockUpdates)
        XCTAssertFalse(withoutCache.isRefreshEnabled)
        XCTAssertEqual(withoutCache.refreshDisabledReason, "A Forge refresh is already in progress")

        let withCache = ForgeRepositoryStatusPresenter.present(
            input(freshness: .refreshing(cachedAt: now.addingTimeInterval(-7200))),
            now: now
        )
        XCTAssertEqual(withCache.freshnessText, "Refreshing · cached 2h ago")
        XCTAssertTrue(withCache.requiresClockUpdates)
    }

    func testOfflineAndAuthenticationDiagnosticsAreActionable() {
        let offline = ForgeRepositoryStatusPresenter.present(input(diagnostic: .offline), now: now)
        XCTAssertEqual(offline.diagnosticText, "Offline")
        XCTAssertTrue(offline.isRefreshEnabled)
        XCTAssertNil(offline.refreshDisabledReason)
        XCTAssertEqual(offline.detailsAction, .explainOffline)
        XCTAssertNil(offline.toolbarPersistentFailureText)
        XCTAssertFalse(offline.requiresClockUpdates)

        let authentication = ForgeRepositoryStatusPresenter.present(
            input(diagnostic: .authenticationRequired),
            now: now
        )
        XCTAssertEqual(authentication.diagnosticText, "Sign In Required")
        XCTAssertEqual(authentication.detailsAction, .authenticate)
        XCTAssertEqual(authentication.accessibilityLabel, "hbmartin/gitx; octocat; Not refreshed; Sign In Required")
    }

    func testActiveRateLimitRoundsRemainingTimeAndExposesExactDeadline() {
        let oneMinute = now.addingTimeInterval(1)
        let oneHour = now.addingTimeInterval(3600)
        let mixed = now.addingTimeInterval(3601)

        XCTAssertEqual(rateLimited(until: oneMinute).diagnosticText, "Rate Limited · 1m remaining")
        XCTAssertEqual(rateLimited(until: oneHour).diagnosticText, "Rate Limited · 1h remaining")
        let presentation = rateLimited(until: mixed)
        XCTAssertEqual(presentation.diagnosticText, "Rate Limited · 1h 1m remaining")
        XCTAssertEqual(presentation.rateLimitResetAt, mixed)
        XCTAssertEqual(presentation.refreshDisabledReason, "Rate limited")
        XCTAssertEqual(presentation.detailsAction, .explainRateLimit)
        XCTAssertFalse(presentation.isRefreshEnabled)
        XCTAssertTrue(presentation.requiresClockUpdates)
        XCTAssertNil(presentation.toolbarPersistentFailureText)
    }

    func testExpiredRateLimitPermitsExplicitRefresh() {
        for deadline in [now, now.addingTimeInterval(-1)] {
            let presentation = rateLimited(until: deadline)
            XCTAssertEqual(presentation.diagnosticText, "Rate Limit Reset")
            XCTAssertTrue(presentation.isRefreshEnabled)
            XCTAssertNil(presentation.refreshDisabledReason)
            XCTAssertNil(presentation.rateLimitResetAt)
            XCTAssertEqual(presentation.detailsAction, .explainRateLimit)
            XCTAssertFalse(presentation.requiresClockUpdates)
        }
    }

    func testUnavailableReasonsMapToRecoveryWithoutMirroringOrdinaryDiagnostics() {
        let cases: [(ForgeUnavailableReason, String, ForgeStatusDetailsAction, String?)] = [
            (.sessionDisabled, "Forge Unavailable", .recoverForgeData, "Forge Unavailable"),
            (.persistentStorageFailure, "Forge Unavailable", .recoverForgeData, "Forge Unavailable"),
            (.missingInstallation, "GitHub App Not Installed", .configureRepositoryAccess, nil),
            (.missingRepositoryAccess, "Repository Access Required", .configureRepositoryAccess, nil),
            (.other, "Forge Unavailable", .explainUnavailable, nil),
        ]

        for (reason, text, action, toolbarText) in cases {
            let presentation = ForgeRepositoryStatusPresenter.present(
                input(diagnostic: .unavailable(reason)),
                now: now
            )
            XCTAssertEqual(presentation.diagnosticText, text)
            XCTAssertEqual(presentation.detailsAction, action)
            XCTAssertEqual(presentation.toolbarPersistentFailureText, toolbarText)
            XCTAssertFalse(presentation.isRefreshEnabled)
            XCTAssertEqual(presentation.refreshDisabledReason, "Forge refresh is unavailable")
        }
    }

    func testAllDetailsActionsAndUnavailableReasonsRemainStable() {
        XCTAssertEqual(Set(ForgeStatusDetailsAction.allCases.map(\.rawValue)).count, 6)
        XCTAssertEqual(Set(ForgeUnavailableReason.allCases.map(\.rawValue)).count, 5)
    }

    private func rateLimited(until deadline: Date) -> ForgeRepositoryStatusPresentation {
        ForgeRepositoryStatusPresenter.present(input(diagnostic: .rateLimited(until: deadline)), now: now)
    }

    private func input(
        access: ForgeStatusAccess = .account(login: "octocat"),
        freshness: ForgeOverlayFreshness = .notLoaded,
        diagnostic: ForgeStatusDiagnostic = .none
    ) -> ForgeRepositoryStatusInput {
        ForgeRepositoryStatusInput(
            repository: try! ForgeRepositoryIdentity(
                forge: ForgeIdentity(kind: .github, origin: try! ForgeOrigin(host: "github.com")),
                owner: "hbmartin",
                name: "gitx"
            ),
            access: access,
            freshness: freshness,
            diagnostic: diagnostic
        )
    }
}
