@testable import ForgeKit
import Foundation
import XCTest

final class ForgePullRequestWorkflowTests: XCTestCase {
    func testCreationFormDefaultsDraftOffEditsAndRoundTrips() throws {
        let fixture = try Fixture()
        let form = try fixture.form()
        XCTAssertFalse(form.isDraft)
        XCTAssertEqual(form.repository, fixture.repository)
        XCTAssertEqual(form.base.repository, fixture.repository)
        XCTAssertEqual(form.head.repository, fixture.fork)

        let edited = try form.editing(title: "Edited", bodyMarkdown: "Body", isDraft: true)
        XCTAssertEqual(edited.title, "Edited")
        XCTAssertEqual(edited.bodyMarkdown, "Body")
        XCTAssertTrue(edited.isDraft)
        XCTAssertEqual(try roundTrip(edited), edited)
    }

    func testCreationFormRejectsInvalidTitleBaseAndHeadBoundaries() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try fixture.form(title: " \n")) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTitle)
        }

        let wrongBase = try ForgeBranchReference(
            repository: fixture.fork,
            name: ForgeRefName("main"),
            commit: fixture.baseCommit
        )
        XCTAssertThrowsError(try ForgePullRequestCreationForm(
            repository: fixture.repository,
            base: wrongBase,
            head: fixture.head,
            title: "Title",
            bodyMarkdown: ""
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedRepository)
        }

        let otherHead = try ForgeBranchReference(
            repository: fixture.otherForgeRepository,
            name: ForgeRefName("feature"),
            commit: fixture.headCommit
        )
        XCTAssertThrowsError(try ForgePullRequestCreationForm(
            repository: fixture.repository,
            base: fixture.base,
            head: otherHead,
            title: "Title",
            bodyMarkdown: ""
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
    }

    func testCommitSummaryValidatesAndRoundTrips() throws {
        let fixture = try Fixture()
        let commit = try ForgePullRequestCommitSummary(
            id: fixture.headCommit,
            subject: "Implement native creation",
            body: "Preserve the draft."
        )
        XCTAssertEqual(try roundTrip(commit), commit)
        XCTAssertThrowsError(try ForgePullRequestCommitSummary(id: fixture.headCommit, subject: "\t")) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidCommitSubject)
        }
    }

    func testTemplateRecognitionDisplayNameAndRoundTrip() throws {
        for path in [
            "PULL_REQUEST_TEMPLATE.md",
            "docs/PULL_REQUEST_TEMPLATE.md",
            ".github/PULL_REQUEST_TEMPLATE.md",
            ".github/PULL_REQUEST_TEMPLATE/bug_fix.md",
        ] {
            let template = try ForgePullRequestTemplate(path: ForgeFilePath(path), bodyMarkdown: "Template")
            XCTAssertEqual(try roundTrip(template), template)
        }
        let named = try ForgePullRequestTemplate(
            path: ForgeFilePath(".github/PULL_REQUEST_TEMPLATE/bug_fix.md"),
            bodyMarkdown: ""
        )
        XCTAssertEqual(named.displayName, "bug fix")
        for path in ["template.txt", "nested/template.md", ".github/nope/template.md"] {
            XCTAssertThrowsError(try ForgePullRequestTemplate(path: ForgeFilePath(path), bodyMarkdown: "")) {
                XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTemplatePath)
            }
        }
    }

    func testTemplateSelectionUsesAcceptedPriorityAndRequiresChoiceOnlyForMultipleNamedTemplates() throws {
        let root = try template("PULL_REQUEST_TEMPLATE.md")
        let docs = try template("docs/PULL_REQUEST_TEMPLATE.md")
        let github = try template(".github/PULL_REQUEST_TEMPLATE.md")
        let feature = try template(".github/PULL_REQUEST_TEMPLATE/feature.md")
        let bug = try template(".github/PULL_REQUEST_TEMPLATE/bug.md")

        XCTAssertEqual(try ForgePullRequestInitialContentPolicy.selectTemplate([]), .none)
        XCTAssertEqual(
            try ForgePullRequestInitialContentPolicy.selectTemplate([root, feature, docs, github]),
            .selected(github)
        )
        XCTAssertEqual(
            try ForgePullRequestInitialContentPolicy.selectTemplate([feature, bug]),
            .requiresChoice([bug, feature])
        )
        XCTAssertThrowsError(try ForgePullRequestInitialContentPolicy.selectTemplate([github, github])) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .duplicateTemplatePath)
        }
    }

    func testInitialContentUsesTemplateThenCommitHeuristicsAndBranchFallback() throws {
        let fixture = try Fixture()
        let first = try ForgePullRequestCommitSummary(
            id: fixture.baseCommit,
            subject: "Prepare workflow",
            body: "Preparation details"
        )
        let second = try ForgePullRequestCommitSummary(
            id: fixture.headCommit,
            subject: "Implement workflow",
            body: "Implementation details"
        )
        let template = try self.template(".github/PULL_REQUEST_TEMPLATE.md", body: "Checklist")

        let templated = try ForgePullRequestInitialContentPolicy.content(
            branch: ForgeRefName("feature/native-pr"),
            commitsOldestFirst: [first, second],
            template: template
        )
        XCTAssertEqual(templated.title, "Implement workflow")
        XCTAssertEqual(templated.bodyMarkdown, "Checklist")

        let single = try ForgePullRequestInitialContentPolicy.content(
            branch: ForgeRefName("feature/native-pr"),
            commitsOldestFirst: [first],
            template: nil
        )
        XCTAssertEqual(single.title, "Prepare workflow")
        XCTAssertEqual(single.bodyMarkdown, "Preparation details")

        let multiple = try ForgePullRequestInitialContentPolicy.content(
            branch: ForgeRefName("feature/native-pr"),
            commitsOldestFirst: [first, second],
            template: nil
        )
        XCTAssertEqual(multiple.title, "Implement workflow")
        XCTAssertEqual(
            multiple.bodyMarkdown,
            "- Prepare workflow (`1111111`)\n- Implement workflow (`2222222`)"
        )

        let fallback = try ForgePullRequestInitialContentPolicy.content(
            branch: ForgeRefName("feature/native_pr"),
            commitsOldestFirst: [],
            template: nil
        )
        XCTAssertEqual(fallback.title, "Native pr")
        XCTAssertEqual(fallback.bodyMarkdown, "")

        let symbolFallback = try ForgePullRequestInitialContentPolicy.content(
            branch: ForgeRefName("_"),
            commitsOldestFirst: [],
            template: nil
        )
        XCTAssertEqual(symbolFallback.title, "_")
    }

    func testComparisonKeyValidatesRepositoryAndForge() throws {
        let fixture = try Fixture()
        let key = try fixture.comparisonKey()
        XCTAssertEqual(try roundTrip(key), key)
        XCTAssertThrowsError(try ForgePullRequestComparisonKey(
            repository: fixture.repository,
            baseRepository: fixture.fork,
            base: fixture.base.name,
            headRepository: fixture.fork,
            head: fixture.head.name
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedRepository)
        }
        XCTAssertThrowsError(try ForgePullRequestComparisonKey(
            repository: fixture.repository,
            baseRepository: fixture.repository,
            base: fixture.base.name,
            headRepository: fixture.otherForgeRepository,
            head: fixture.head.name
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
    }

    func testDuplicateDetectionUsesExactOpenBaseHeadAndNewestStableMatch() throws {
        let fixture = try Fixture()
        let key = try fixture.comparisonKey()
        let old = try fixture.pullRequest(number: 4, updatedAt: Date(timeIntervalSince1970: 20))
        let newest = try fixture.pullRequest(number: 9, updatedAt: Date(timeIntervalSince1970: 30))
        let tieLowerNumber = try fixture.pullRequest(number: 3, updatedAt: Date(timeIntervalSince1970: 30))
        let closed = try fixture.pullRequest(number: 1, state: .closed, updatedAt: Date(timeIntervalSince1970: 40))

        XCTAssertEqual(
            ForgeDuplicatePullRequestPolicy.decision(for: key, among: [old, newest, tieLowerNumber, closed]),
            .openExisting(tieLowerNumber)
        )
        XCTAssertEqual(ForgeDuplicatePullRequestPolicy.decision(for: key, among: [closed]), .create)

        let missingHead = try fixture.pullRequest(number: 10, head: .unavailable(.partialResponse))
        let wrongBase = try fixture.pullRequest(
            number: 11,
            base: .available(ForgeBranchReference(
                repository: fixture.repository,
                name: ForgeRefName("release"),
                commit: fixture.baseCommit
            ))
        )
        XCTAssertEqual(
            ForgeDuplicatePullRequestPolicy.decision(for: key, among: [missingHead, wrongBase]),
            .create
        )
    }

    func testAuthoritativeCreateRejectionOpensOnlyExactRefetchedDuplicate() throws {
        let fixture = try Fixture()
        let key = try fixture.comparisonKey()
        let rejection = try ForgeCreatePullRequestAuthoritativeRejection(
            comparison: key,
            message: "GitHub rejected Pull Request creation."
        )
        let exact = try fixture.pullRequest(number: 42)
        let wrongBase = try fixture.pullRequest(
            number: 43,
            base: .available(ForgeBranchReference(
                repository: fixture.repository,
                name: ForgeRefName("release"),
                commit: fixture.baseCommit
            ))
        )
        let closed = try fixture.pullRequest(number: 44, state: .closed)

        XCTAssertEqual(
            ForgeCreatePullRequestReconciliationPolicy.decision(
                rejection: rejection,
                refreshedPullRequests: [wrongBase, closed]
            ),
            .preserveDraft(authoritativeMessage: rejection.message)
        )
        XCTAssertEqual(
            ForgeCreatePullRequestReconciliationPolicy.decision(
                rejection: rejection,
                refreshedPullRequests: [wrongBase, exact]
            ),
            .openExisting(exact)
        )
        XCTAssertThrowsError(try ForgeCreatePullRequestAuthoritativeRejection(
            comparison: key,
            message: "\n"
        )) {
            XCTAssertEqual($0 as? ForgePullRequestMutationError, .invalidMessage)
        }
    }

    func testEditableSnapshotAndEditRequireExactUpdatedAt() throws {
        let fixture = try Fixture()
        let original = try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: ForgeItemNumber(12),
            title: "Original",
            bodyMarkdown: "Body",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(try roundTrip(original), original)
        let edit = try ForgePullRequestEdit(snapshot: original, title: "Edited", bodyMarkdown: "New")
        XCTAssertEqual(try roundTrip(edit), edit)
        XCTAssertNoThrow(try edit.validate(current: original))

        let changed = try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: original.number,
            title: "Remote",
            bodyMarkdown: "Remote",
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        XCTAssertThrowsError(try edit.validate(current: changed)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .editConflict)
        }
        let otherNumber = try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: ForgeItemNumber(13),
            title: "Other",
            bodyMarkdown: "",
            updatedAt: original.updatedAt
        )
        XCTAssertThrowsError(try edit.validate(current: otherNumber)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedRepository)
        }
        XCTAssertThrowsError(try ForgePullRequestEdit(snapshot: original, title: " ", bodyMarkdown: ""))
        XCTAssertThrowsError(try ForgePullRequestEditableSnapshot(
            repository: fixture.repository,
            number: original.number,
            title: "\n",
            bodyMarkdown: "",
            updatedAt: original.updatedAt
        ))
    }

    func testPushCreateWorkflowCoversNewAndOrdinaryPushPaths() throws {
        let fixture = try Fixture()
        let intent = try fixture.intent()
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(21))

        var state = ForgePushPullRequestState.idle
        state = try state.applying(.newPullRequest(branchAlreadyPushed: false, intent: intent))
        XCTAssertEqual(state, .pushSheet(createPullRequestSelected: true, intent: intent))
        state = try state.applying(.beginPush(createPullRequestSelected: true))
        XCTAssertEqual(state, .pushing(createPullRequestAfterSuccess: true, intent: intent))
        state = try state.applying(.pushSucceeded)
        XCTAssertEqual(state, .createSheet(intent))
        state = try state.applying(.creationSucceeded(destination))
        XCTAssertEqual(state, .completed(destination))
        XCTAssertEqual(try state.applying(.reset), .idle)

        state = try ForgePushPullRequestState.idle.applying(.ordinaryPush(intent: intent))
        XCTAssertEqual(state, .pushSheet(createPullRequestSelected: false, intent: intent))
        state = try state.applying(.beginPush(createPullRequestSelected: false))
        XCTAssertEqual(try state.applying(.pushSucceeded), .idle)
        XCTAssertEqual(try state.applying(.pushFailed), .idle)
        XCTAssertEqual(
            try ForgePushPullRequestState.pushSheet(
                createPullRequestSelected: false,
                intent: intent
            ).applying(.cancel),
            .idle
        )
    }

    func testPushCreateWorkflowPreservesCancelledAndFailedDrafts() throws {
        let fixture = try Fixture()
        let intent = try fixture.intent()
        let destination = try ForgeDestination.pullRequest(fixture.repository, ForgeItemNumber(22))

        let direct = try ForgePushPullRequestState.idle.applying(
            .newPullRequest(branchAlreadyPushed: true, intent: intent)
        )
        XCTAssertEqual(direct, .createSheet(intent))
        let cancelled = try direct.applying(.cancel)
        XCTAssertEqual(cancelled, .draftPreserved(intent))
        XCTAssertEqual(try cancelled.applying(.reopenDraft), .createSheet(intent))
        XCTAssertEqual(try cancelled.applying(.discardDraft), .idle)
        XCTAssertEqual(try direct.applying(.creationFailed), .draftPreserved(intent))
        XCTAssertEqual(try direct.applying(.existingPullRequest(destination)), .completed(destination))
        XCTAssertThrowsError(try ForgePushPullRequestState.idle.applying(.pushSucceeded)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTransition)
        }

        let pushing = try ForgePushPullRequestState.idle
            .applying(.newPullRequest(branchAlreadyPushed: false, intent: intent))
            .applying(.beginPush(createPullRequestSelected: true))
        XCTAssertEqual(try pushing.applying(.pushFailed), .draftPreserved(intent))
        XCTAssertEqual(
            try ForgePushPullRequestState.pushSheet(
                createPullRequestSelected: true,
                intent: intent
            ).applying(.cancel),
            .draftPreserved(intent)
        )
    }

    func testPushIntentRejectsDraftIdentityThatDoesNotExactlyMatchForm() throws {
        let fixture = try Fixture()
        let form = try fixture.form()
        let wrongIdentity = try ForgeDraftIdentity(
            accountID: fixture.accountID,
            destination: .createPullRequest(
                repository: fixture.repository,
                base: ForgeRefName("release"),
                head: fixture.head.name
            )
        )
        XCTAssertThrowsError(try ForgePushPullRequestIntent(form: form, draftIdentity: wrongIdentity)) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedRepository)
        }
        XCTAssertThrowsError(try ForgePushPullRequestState.idle
            .applying(.ordinaryPush(intent: nil))
            .applying(.beginPush(createPullRequestSelected: true)))
        {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidTransition)
        }
    }

    func testWorkingStateClampsCountsAndRequiresEveryCleanDimension() {
        let clamped = ForgeLocalWorkingState(
            stagedCount: -1,
            unstagedCount: -1,
            untrackedCount: -1,
            conflictCount: -1
        )
        XCTAssertTrue(clamped.isClean)
        XCTAssertEqual(try? roundTrip(clamped), clamped)
        for state in [
            ForgeLocalWorkingState(stagedCount: 1, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            ForgeLocalWorkingState(stagedCount: 0, unstagedCount: 1, untrackedCount: 0, conflictCount: 0),
            ForgeLocalWorkingState(stagedCount: 0, unstagedCount: 0, untrackedCount: 1, conflictCount: 0),
            ForgeLocalWorkingState(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 1),
            ForgeLocalWorkingState(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0, operationName: "rebase"),
        ] {
            XCTAssertFalse(state.isClean)
        }
    }

    func testGitRemoteValidatesAndRoundTrips() throws {
        let fixture = try Fixture()
        for url in ["https://github.com/contributor/gitx.git", "ssh://git@github.com/contributor/gitx.git", "git://github.com/contributor/gitx.git"] {
            let remote = try ForgeGitRemote(
                name: "contributor",
                repository: fixture.fork,
                fetchURL: XCTUnwrap(URL(string: url))
            )
            XCTAssertEqual(try roundTrip(remote), remote)
        }
        XCTAssertThrowsError(try ForgeGitRemote(
            name: "bad remote",
            repository: fixture.fork,
            fetchURL: XCTUnwrap(URL(string: "https://github.com/contributor/gitx.git"))
        ))
        XCTAssertThrowsError(try ForgeGitRemote(
            name: "remote",
            repository: fixture.fork,
            fetchURL: XCTUnwrap(URL(string: "file:///tmp/repo"))
        ))
        for url in [
            "https://token@github.com/contributor/gitx.git",
            "https://github.com/contributor/gitx.git?token=secret",
            "https://github.com/contributor/gitx.git#secret",
            "ssh://git:secret@github.com/contributor/gitx.git",
            "https:///missing-host",
            "ssh://deploy@github.com/contributor/gitx.git",
        ] {
            XCTAssertThrowsError(try ForgeGitRemote(
                name: "remote",
                repository: fixture.fork,
                fetchURL: XCTUnwrap(URL(string: url))
            ))
        }
    }

    func testCheckoutReusesExactRemoteAndCreatesBaseBranchName() throws {
        let fixture = try Fixture()
        let remote = try ForgeGitRemote(
            name: "contributor",
            repository: fixture.fork,
            fetchURL: XCTUnwrap(URL(string: "ssh://git@github.com/contributor/gitx.git"))
        )
        let plan = try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 42),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [remote],
            existingLocalBranches: [],
            headRemoteURL: remote.fetchURL
        )
        XCTAssertFalse(plan.addsRemote)
        XCTAssertEqual(plan.remote, remote)
        XCTAssertEqual(plan.localBranch.value, "pr/42")
        XCTAssertEqual(plan.fetchRefspec, "+refs/heads/feature:refs/remotes/contributor/feature")
        XCTAssertEqual(plan.expectedHead, fixture.headCommit)
        XCTAssertEqual(try roundTrip(plan), plan)
    }

    func testCheckoutCreatesCollisionSafeForkRemoteAndBranch() throws {
        let fixture = try Fixture(forkOwner: "Contributor Name")
        let occupiedRemote = try ForgeGitRemote(
            name: "github-contributor-name",
            repository: nil,
            fetchURL: XCTUnwrap(URL(string: "https://example.com/other/repo.git"))
        )
        let occupiedRemote2 = try ForgeGitRemote(
            name: "github-contributor-name-2",
            repository: nil,
            fetchURL: XCTUnwrap(URL(string: "https://example.com/other/repo2.git"))
        )
        let branches: Set<ForgeRefName> = try [
            ForgeRefName("pr/42"),
            ForgeRefName("pr/42-contributor-name"),
            ForgeRefName("pr/42-contributor-name-2"),
        ]
        let plan = try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 42),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [occupiedRemote, occupiedRemote2],
            existingLocalBranches: branches,
            headRemoteURL: XCTUnwrap(URL(string: "https://github.com/Contributor%20Name/gitx.git"))
        )
        XCTAssertTrue(plan.addsRemote)
        XCTAssertEqual(plan.remote.name, "github-contributor-name-3")
        XCTAssertEqual(plan.localBranch.value, "pr/42-contributor-name-3")
    }

    func testCheckoutUsesUnsuffixedRemoteAndContributorFallbackForSymbolOnlyOwner() throws {
        let fixture = try Fixture(forkOwner: "🔥")
        let url = try XCTUnwrap(URL(string: "https://github.com/%F0%9F%94%A5/gitx.git"))
        let first = try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 5),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [],
            existingLocalBranches: [],
            headRemoteURL: url
        )
        XCTAssertEqual(first.remote.name, "github-contributor")
        XCTAssertEqual(first.localBranch.value, "pr/5")

        let colliding: Set<ForgeRefName> = try [ForgeRefName("pr/5")]
        let second = try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 5),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [],
            existingLocalBranches: colliding,
            headRemoteURL: url
        )
        XCTAssertEqual(second.localBranch.value, "pr/5-contributor")
    }

    func testCheckoutRejectsUnsafeAndMissingHeads() throws {
        let fixture = try Fixture()
        let url = try XCTUnwrap(URL(string: "https://github.com/contributor/gitx.git"))
        XCTAssertThrowsError(try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 1),
            workingState: .init(stagedCount: 1, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [],
            existingLocalBranches: [],
            headRemoteURL: url
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsafeWorkingState)
        }
        XCTAssertThrowsError(try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 1, head: .unavailable(.partialResponse)),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [],
            existingLocalBranches: [],
            headRemoteURL: url
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .headReferenceUnavailable)
        }
    }

    func testCheckoutRequiresRemoteURLToMatchExactHeadRepositoryAndSafeAuthority() throws {
        let fixture = try Fixture()
        let unsafeURLs = [
            "https://example.com/contributor/gitx.git",
            "https://github.com/other/gitx.git",
            "https://github.com/contributor/other.git",
            "https://github.com:443/contributor/gitx.git",
            "ssh://git@github.com:22/contributor/gitx.git",
            "https://token@github.com/contributor/gitx.git",
            "ssh://deploy@github.com/contributor/gitx.git",
            "https://github.com//contributor/gitx.git",
            "https://github.com/contributor/gitx.git/",
        ]
        for rawURL in unsafeURLs {
            XCTAssertThrowsError(try ForgePullRequestCheckoutPolicy.plan(
                pullRequest: fixture.pullRequest(number: 42),
                workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
                remotes: [],
                existingLocalBranches: [],
                headRemoteURL: XCTUnwrap(URL(string: rawURL))
            ), rawURL) {
                XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRemoteURL, rawURL)
            }
        }

        let mislabeled = try ForgeGitRemote(
            name: "contributor",
            repository: fixture.fork,
            fetchURL: XCTUnwrap(URL(string: "https://github.com/other/gitx.git"))
        )
        XCTAssertThrowsError(try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: fixture.pullRequest(number: 42),
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [mislabeled],
            existingLocalBranches: [],
            headRemoteURL: XCTUnwrap(URL(string: "https://github.com/contributor/gitx.git"))
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRemoteURL)
        }

        let gitLabFork = try ForgeRepositoryIdentity(
            forge: fixture.otherForgeRepository.forge,
            owner: "contributor",
            name: "gitx"
        )
        let gitLabPullRequest = try ForgePullRequestSummary(
            repository: fixture.otherForgeRepository,
            number: ForgeItemNumber(45),
            state: .open,
            isDraft: false,
            title: "GitLab Pull Request",
            author: .unavailable(.notRequested),
            head: .available(ForgePullRequestHead(reference: ForgeBranchReference(
                repository: gitLabFork,
                name: ForgeRefName("feature"),
                commit: fixture.headCommit
            ))),
            base: .unavailable(.notRequested),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            labels: .available([]),
            checkRollup: .unavailable(.notRequested),
            reviewRollup: .unavailable(.notRequested)
        )
        XCTAssertNoThrow(try ForgePullRequestCheckoutPolicy.plan(
            pullRequest: gitLabPullRequest,
            workingState: .init(stagedCount: 0, unstagedCount: 0, untrackedCount: 0, conflictCount: 0),
            remotes: [],
            existingLocalBranches: [],
            headRemoteURL: XCTUnwrap(URL(string: "https://gitlab.com/contributor/gitx.git"))
        ))
    }

    func testCheckoutPlanRejectsMismatchedRemoteAndMalformedRefspec() throws {
        let fixture = try Fixture()
        let wrong = try ForgeGitRemote(
            name: "wrong",
            repository: fixture.otherForgeRepository,
            fetchURL: XCTUnwrap(URL(string: "https://gitlab.com/other/gitx.git"))
        )
        XCTAssertThrowsError(try ForgePullRequestCheckoutPlan(
            repository: fixture.repository,
            pullRequest: ForgeItemNumber(1),
            remote: wrong,
            fetchRefspec: "+refs/heads/main:refs/remotes/wrong/main",
            localBranch: ForgeRefName("pr/1"),
            expectedHead: fixture.headCommit,
            addsRemote: true
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
        let remote = try ForgeGitRemote(
            name: "fork",
            repository: fixture.fork,
            fetchURL: XCTUnwrap(URL(string: "https://github.com/contributor/gitx.git"))
        )
        XCTAssertThrowsError(try ForgePullRequestCheckoutPlan(
            repository: fixture.repository,
            pullRequest: ForgeItemNumber(1),
            remote: remote,
            fetchRefspec: "refs/heads/main",
            localBranch: ForgeRefName("pr/1"),
            expectedHead: fixture.headCommit,
            addsRemote: true
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRefspec)
        }
        for refspec in [
            "+refs/heads/main:refs/remotes/fork/other",
            "+refs/heads/main:refs/remotes/fork/main:extra",
            "+refs/heads/-bad:refs/remotes/fork/-bad",
        ] {
            XCTAssertThrowsError(try ForgePullRequestCheckoutPlan(
                repository: fixture.repository,
                pullRequest: ForgeItemNumber(1),
                remote: remote,
                fetchRefspec: refspec,
                localBranch: ForgeRefName("pr/1"),
                expectedHead: fixture.headCommit,
                addsRemote: true
            )) {
                XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRefspec)
            }
        }
    }

    func testCloneRequiresExactAccountAndExcludesStarredBrowsing() throws {
        let fixture = try Fixture()
        for relationship in [ForgeCloneRepositoryRelationship.owned, .organization] {
            for transport in [ForgeCloneTransport.ssh, .https] {
                let request = try ForgeCloneRequest(
                    accountID: fixture.accountID,
                    repository: fixture.repository,
                    relationship: relationship,
                    transport: transport
                )
                XCTAssertEqual(try roundTrip(request), request)
            }
        }
        XCTAssertThrowsError(try ForgeCloneRequest(
            accountID: fixture.accountID,
            repository: fixture.repository,
            relationship: .starred,
            transport: .ssh
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsupportedRepositoryRelationship)
        }
        XCTAssertThrowsError(try ForgeCloneRequest(
            accountID: fixture.otherAccountID,
            repository: fixture.repository,
            relationship: .owned,
            transport: .ssh
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
    }

    func testSyncForkIgnoresCheckoutDirtinessAndRoundTrips() throws {
        let fixture = try Fixture()
        let plan = try ForgeSyncForkPlan(
            fork: fixture.fork,
            parent: fixture.repository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: "origin"
        )
        XCTAssertTrue(plan.remainsEligible(workingState: .init(
            stagedCount: 2,
            unstagedCount: 3,
            untrackedCount: 4,
            conflictCount: 1,
            operationName: "rebase"
        )))
        XCTAssertEqual(try roundTrip(plan), plan)
        XCTAssertThrowsError(try ForgeSyncForkPlan(
            fork: fixture.repository,
            parent: fixture.repository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: "origin"
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .unsupportedRepositoryRelationship)
        }
        XCTAssertThrowsError(try ForgeSyncForkPlan(
            fork: fixture.fork,
            parent: fixture.otherForgeRepository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: "origin"
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .mismatchedForge)
        }
        XCTAssertThrowsError(try ForgeSyncForkPlan(
            fork: fixture.fork,
            parent: fixture.repository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: " "
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRemoteName)
        }
        XCTAssertThrowsError(try ForgeSyncForkPlan(
            fork: fixture.fork,
            parent: fixture.repository,
            branch: ForgeRefName("main"),
            localFetchRemoteName: "-bad"
        )) {
            XCTAssertEqual($0 as? ForgePullRequestWorkflowError, .invalidRemoteName)
        }
    }

    func testWorkflowErrorsHaveStableDescriptions() {
        let errors: [ForgePullRequestWorkflowError] = [
            .invalidTitle, .invalidCommitSubject, .invalidTemplatePath, .mismatchedRepository,
            .mismatchedForge, .duplicateTemplatePath, .invalidTransition, .invalidRemoteName,
            .invalidRemoteURL, .invalidRefspec, .unsafeWorkingState,
            .headReferenceUnavailable, .unsupportedRepositoryRelationship,
            .editConflict,
        ]
        XCTAssertTrue(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    private func template(_ path: String, body: String = "Template") throws -> ForgePullRequestTemplate {
        try ForgePullRequestTemplate(path: ForgeFilePath(path), bodyMarkdown: body)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

private struct Fixture {
    let repository: ForgeRepositoryIdentity
    let fork: ForgeRepositoryIdentity
    let otherForgeRepository: ForgeRepositoryIdentity
    let accountID: ForgeAccountID
    let otherAccountID: ForgeAccountID
    let baseCommit = try! ForgeCommitID(String(repeating: "1", count: 40))
    let headCommit = try! ForgeCommitID(String(repeating: "2", count: 40))
    let base: ForgeBranchReference
    let head: ForgeBranchReference

    init(forkOwner: String = "contributor") throws {
        let github = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let gitlab = try ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
        repository = try ForgeRepositoryIdentity(forge: github, owner: "gitx", name: "gitx")
        fork = try ForgeRepositoryIdentity(forge: github, owner: forkOwner, name: "gitx")
        otherForgeRepository = try ForgeRepositoryIdentity(forge: gitlab, owner: "other", name: "gitx")
        accountID = try ForgeAccountID(forge: github, value: "account")
        otherAccountID = try ForgeAccountID(forge: gitlab, value: "other-account")
        base = try ForgeBranchReference(repository: repository, name: ForgeRefName("main"), commit: baseCommit)
        head = try ForgeBranchReference(repository: fork, name: ForgeRefName("feature"), commit: headCommit)
    }

    func form(title: String = "Native Pull Requests") throws -> ForgePullRequestCreationForm {
        try ForgePullRequestCreationForm(
            repository: repository,
            base: base,
            head: head,
            title: title,
            bodyMarkdown: "Body"
        )
    }

    func intent() throws -> ForgePushPullRequestIntent {
        let form = try form()
        let identity = try ForgeDraftIdentity(
            accountID: accountID,
            destination: .createPullRequest(
                repository: repository,
                base: base.name,
                head: head.name
            )
        )
        return try ForgePushPullRequestIntent(form: form, draftIdentity: identity)
    }

    func comparisonKey() throws -> ForgePullRequestComparisonKey {
        try ForgePullRequestComparisonKey(
            repository: repository,
            baseRepository: repository,
            base: base.name,
            headRepository: fork,
            head: head.name
        )
    }

    func pullRequest(
        number: Int,
        state: ForgePullRequestState = .open,
        updatedAt: Date = Date(timeIntervalSince1970: 20),
        base: ForgeReadSection<ForgeBranchReference>? = nil,
        head: ForgeReadSection<ForgePullRequestHead>? = nil
    ) throws -> ForgePullRequestSummary {
        let baseValue = base ?? .available(self.base)
        let headValue = head ?? .available(ForgePullRequestHead(reference: self.head))
        return try ForgePullRequestSummary(
            repository: repository,
            number: ForgeItemNumber(number),
            state: state,
            isDraft: false,
            title: "PR \(number)",
            author: .unavailable(.notRequested),
            head: headValue,
            base: baseValue,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt,
            labels: .available([]),
            checkRollup: .unavailable(.notRequested),
            reviewRollup: .unavailable(.notRequested)
        )
    }
}
