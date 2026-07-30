import ForgeKit
import Foundation

// MARK: - Provider-neutral mutation seam

/// Exact local and Forge state needed to present the Create Pull Request flow.
/// The concrete GitHub adapter remains behind `RepositoryPullRequestMutationServing`.
nonisolated struct RepositoryPullRequestCreationPreparation: Hashable, Sendable {
    let accountID: ForgeAccountID
    let repository: ForgeRepositoryIdentity
    let base: ForgeBranchReference
    let head: ForgeBranchReference
    let branchAlreadyPushed: Bool
    let templates: [ForgePullRequestTemplate]
    let commitsOldestFirst: [ForgePullRequestCommitSummary]

    init(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity,
        base: ForgeBranchReference,
        head: ForgeBranchReference,
        branchAlreadyPushed: Bool,
        templates: [ForgePullRequestTemplate] = [],
        commitsOldestFirst: [ForgePullRequestCommitSummary] = []
    ) throws {
        guard accountID.forge == repository.forge,
              base.repository == repository,
              head.repository.forge == repository.forge
        else {
            throw ForgePullRequestWorkflowError.mismatchedRepository
        }
        self.accountID = accountID
        self.repository = repository
        self.base = base
        self.head = head
        self.branchAlreadyPushed = branchAlreadyPushed
        self.templates = templates
        self.commitsOldestFirst = commitsOldestFirst
    }

    func initialForms() throws -> RepositoryPullRequestInitialForms {
        let selection = try ForgePullRequestInitialContentPolicy.selectTemplate(templates)
        switch selection {
        case .none:
            return try RepositoryPullRequestInitialForms(
                forms: [form(template: nil)],
                selectedTemplateIndex: nil
            )
        case let .selected(template):
            return try RepositoryPullRequestInitialForms(
                forms: [form(template: template)],
                selectedTemplateIndex: 0
            )
        case let .requiresChoice(templates):
            return try RepositoryPullRequestInitialForms(
                forms: templates.map { try form(template: $0) },
                selectedTemplateIndex: 0,
                templateNames: templates.map(\.displayName)
            )
        }
    }

    private func form(template: ForgePullRequestTemplate?) throws -> ForgePullRequestCreationForm {
        let content = ForgePullRequestInitialContentPolicy.content(
            branch: head.name,
            commitsOldestFirst: commitsOldestFirst,
            template: template
        )
        return try ForgePullRequestCreationForm(
            repository: repository,
            base: base,
            head: head,
            title: content.title,
            bodyMarkdown: content.bodyMarkdown,
            isDraft: false
        )
    }
}

nonisolated struct RepositoryPullRequestInitialForms: Hashable, Sendable {
    let forms: [ForgePullRequestCreationForm]
    let selectedTemplateIndex: Int?
    let templateNames: [String]

    init(
        forms: [ForgePullRequestCreationForm],
        selectedTemplateIndex: Int?,
        templateNames: [String] = []
    ) {
        precondition(!forms.isEmpty)
        precondition(templateNames.isEmpty || templateNames.count == forms.count)
        self.forms = forms
        self.selectedTemplateIndex = selectedTemplateIndex
        self.templateNames = templateNames
    }
}

nonisolated enum RepositoryPullRequestCreationOutcome: Hashable, Sendable {
    case created(ForgeDestination)
    case existing(ForgeDestination)
}

nonisolated struct RepositoryPullRequestEditOutcome: Hashable, Sendable {
    let snapshot: ForgePullRequestEditableSnapshot
    let destination: ForgeDestination
}

nonisolated struct RepositorySyncForkOutcome: Hashable, Sendable {
    let plan: ForgeSyncForkPlan
    let serverSummary: String
}

/// Application-facing contract implemented by the exact-account GitHub mutation wrapper.
/// Every implementation must re-evaluate live capability and repository ownership before
/// a write; cached read models are never authorization evidence.
nonisolated protocol RepositoryPullRequestMutationServing: Sendable {
    func prepareCreation(
        repository: ForgeRepositoryIdentity,
        localBranch: ForgeRefName,
        localHead: ForgeCommitID
    ) async throws -> RepositoryPullRequestCreationPreparation

    func createPullRequest(
        accountID: ForgeAccountID,
        form: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome

    func editPullRequest(
        accountID: ForgeAccountID,
        edit: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome

    func syncFork(
        accountID: ForgeAccountID,
        plan: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome
}

nonisolated enum RepositoryPullRequestServiceError: Error, Equatable, LocalizedError, Sendable {
    case nativeCreationUnavailable
    case repositoryUnavailable
    case noLocalBranch
    case invalidLocalHead
    case draftUnavailable
    case localDiffUnavailable
    case checkoutVerificationFailed
    case deepLinkUnavailable

    var errorDescription: String? {
        switch self {
        case .nativeCreationUnavailable:
            "Native Pull Request creation is unavailable for this repository and account."
        case .repositoryUnavailable:
            "The Primary Forge Repository is unavailable."
        case .noLocalBranch:
            "Check out a local branch before creating a Pull Request."
        case .invalidLocalHead:
            "GitX could not resolve the checked-out branch head."
        case .draftUnavailable:
            "The Pull Request draft could not be loaded or saved."
        case .localDiffUnavailable:
            "The local Pull Request comparison is unavailable."
        case .checkoutVerificationFailed:
            "The fetched Pull Request head did not match the expected commit."
        case .deepLinkUnavailable:
            "The GitX deep link does not match an open checkout."
        }
    }
}

nonisolated struct UnavailableRepositoryPullRequestMutationService: RepositoryPullRequestMutationServing {
    func prepareCreation(
        repository _: ForgeRepositoryIdentity,
        localBranch _: ForgeRefName,
        localHead _: ForgeCommitID
    ) async throws -> RepositoryPullRequestCreationPreparation {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func createPullRequest(
        accountID _: ForgeAccountID,
        form _: ForgePullRequestCreationForm
    ) async throws -> RepositoryPullRequestCreationOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func editPullRequest(
        accountID _: ForgeAccountID,
        edit _: ForgePullRequestEdit
    ) async throws -> RepositoryPullRequestEditOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }

    func syncFork(
        accountID _: ForgeAccountID,
        plan _: ForgeSyncForkPlan
    ) async throws -> RepositorySyncForkOutcome {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }
}

@MainActor
struct RepositoryPullRequestApplicationSession {
    let service: any RepositoryPullRequestMutationServing
    let drafts: any RepositoryPullRequestDraftPersisting

    init(
        service: any RepositoryPullRequestMutationServing,
        drafts: any RepositoryPullRequestDraftPersisting = NullRepositoryPullRequestDraftStore()
    ) {
        self.service = service
        self.drafts = drafts
    }
}

/// Narrow composition-root hook. Production supplies an exact-account GitHub
/// mutation wrapper here; tests inject deterministic fakes without introducing
/// application-wide dependency injection.
final nonisolated class RepositoryPullRequestServiceResolver: Sendable {
    typealias Factory = @MainActor @Sendable (PBGitRepository) -> RepositoryPullRequestApplicationSession

    private let factory: Factory

    init(factory: @escaping Factory = { _ in
        RepositoryPullRequestApplicationSession(service: UnavailableRepositoryPullRequestMutationService())
    }) {
        self.factory = factory
    }

    @MainActor
    func session(for repository: PBGitRepository) -> RepositoryPullRequestApplicationSession {
        factory(repository)
    }
}

// MARK: - Durable create-Pull-Request drafts

nonisolated protocol RepositoryPullRequestDraftPersisting: Sendable {
    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft?
    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws
    func delete(identity: ForgeDraftIdentity) async throws
}

nonisolated struct NullRepositoryPullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    func load(identity _: ForgeDraftIdentity) async throws -> ForgeDraft? {
        nil
    }

    func save(identity _: ForgeDraftIdentity, content _: ForgeDraftContent, at _: Date) async throws {}
    func delete(identity _: ForgeDraftIdentity) async throws {}
}

nonisolated struct ForgeSQLitePullRequestDraftStore: RepositoryPullRequestDraftPersisting {
    private let database: ForgeSQLiteStore

    init(database: ForgeSQLiteStore) {
        self.database = database
    }

    func load(identity: ForgeDraftIdentity) async throws -> ForgeDraft? {
        let key = try ForgeSQLiteStore.encodedKey(identity)
        guard let record = try await database.durableRecord(
            kind: .draft,
            accountID: identity.accountID,
            repository: identity.destination.repository,
            key: key
        ) else { return nil }
        let draft = try JSONDecoder().decode(ForgeDraft.self, from: record.payload)
        guard draft.identity == identity else {
            throw RepositoryPullRequestServiceError.draftUnavailable
        }
        return draft
    }

    func save(identity: ForgeDraftIdentity, content: ForgeDraftContent, at date: Date) async throws {
        let existing = try await load(identity: identity)
        let draft = if let existing {
            try existing.editing(content, at: max(date, existing.lastActivityAt))
        } else {
            try ForgeDraft(identity: identity, content: content, createdAt: date, lastActivityAt: date)
        }
        let key = try ForgeSQLiteStore.encodedKey(identity)
        let payload = try JSONEncoder().encode(draft)
        try await database.saveDurableRecord(ForgeSQLiteDurableRecord(
            kind: .draft,
            accountID: identity.accountID,
            repository: identity.destination.repository,
            key: key,
            payload: payload,
            lastActivityAt: draft.lastActivityAt,
            expiresAt: draft.lastActivityAt.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
        ))
    }

    func delete(identity: ForgeDraftIdentity) async throws {
        let key = try ForgeSQLiteStore.encodedKey(identity)
        _ = try await database.deleteDurableRecord(
            kind: .draft,
            accountID: identity.accountID,
            repository: identity.destination.repository,
            key: key
        )
    }
}

nonisolated enum RepositoryPullRequestDraftPolicy {
    static func identity(
        preparation: RepositoryPullRequestCreationPreparation
    ) throws -> ForgeDraftIdentity {
        try ForgeDraftIdentity(
            accountID: preparation.accountID,
            destination: .createPullRequest(
                repository: preparation.repository,
                base: preparation.base.name,
                head: preparation.head.name
            )
        )
    }

    static func restoredForm(
        preparation: RepositoryPullRequestCreationPreparation,
        initial: ForgePullRequestCreationForm,
        draft: ForgeDraft?
    ) throws -> ForgePullRequestCreationForm {
        guard let draft else { return initial }
        return try initial.editing(
            title: draft.content.title ?? initial.title,
            bodyMarkdown: draft.content.body,
            isDraft: false
        )
    }

    static func editIdentity(
        accountID: ForgeAccountID,
        snapshot: ForgePullRequestEditableSnapshot
    ) throws -> ForgeDraftIdentity {
        try ForgeDraftIdentity(
            accountID: accountID,
            destination: .pullRequest(repository: snapshot.repository, number: snapshot.number)
        )
    }

    static func restoredEditContent(
        snapshot: ForgePullRequestEditableSnapshot,
        draft: ForgeDraft?
    ) -> ForgeDraftContent {
        guard let draft else {
            return ForgeDraftContent(title: snapshot.title, body: snapshot.bodyMarkdown)
        }
        return ForgeDraftContent(
            title: draft.content.title ?? snapshot.title,
            body: draft.content.body
        )
    }
}

// MARK: - Explicit Forge clone catalog

nonisolated struct RepositoryForgeCloneCatalog: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        let repository: ForgeRepositoryIdentity
        let relationship: ForgeCloneRepositoryRelationship

        init(repository: ForgeRepositoryIdentity, relationship: ForgeCloneRepositoryRelationship) throws {
            guard relationship == .owned || relationship == .organization else {
                throw ForgePullRequestWorkflowError.unsupportedRepositoryRelationship
            }
            self.repository = repository
            self.relationship = relationship
        }
    }

    let accountID: ForgeAccountID
    let accountDisplayName: String
    let repositories: [Entry]

    init(accountID: ForgeAccountID, accountDisplayName: String, repositories: [Entry]) throws {
        guard Self.isNonemptyPrintable(accountDisplayName),
              repositories.allSatisfy({ $0.repository.forge == accountID.forge })
        else {
            throw ForgePullRequestWorkflowError.mismatchedForge
        }
        self.accountID = accountID
        self.accountDisplayName = accountDisplayName
        self.repositories = repositories.sorted {
            let left = ($0.repository.ownerPathComponents + [$0.repository.name]).joined(separator: "/")
            let right = ($1.repository.ownerPathComponents + [$1.repository.name]).joined(separator: "/")
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private static func isNonemptyPrintable(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

nonisolated protocol RepositoryForgeCloneCatalogServing: Sendable {
    func cloneCatalogs() async throws -> [RepositoryForgeCloneCatalog]
}

nonisolated struct UnavailableRepositoryForgeCloneCatalogService: RepositoryForgeCloneCatalogServing {
    func cloneCatalogs() async throws -> [RepositoryForgeCloneCatalog] {
        throw RepositoryPullRequestServiceError.nativeCreationUnavailable
    }
}

final nonisolated class RepositoryForgeCloneServiceResolver: Sendable {
    typealias Factory = @MainActor @Sendable () -> any RepositoryForgeCloneCatalogServing

    private let factory: Factory

    init(factory: @escaping Factory = { UnavailableRepositoryForgeCloneCatalogService() }) {
        self.factory = factory
    }

    @MainActor
    func service() -> any RepositoryForgeCloneCatalogServing {
        factory()
    }
}
