import ForgeKit
import Foundation
import XCTest

final class RepositoryPullRequestMutationPreferenceStoreTests: XCTestCase {
    private var defaultsName: String!
    private var defaults: UserDefaults!
    private var repository: ForgeRepositoryIdentity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsName = "RepositoryPullRequestMutationPreferenceStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        repository = try makeRepository(owner: "hbmartin", name: "gitx")
        try setBinding(repository: repository, identifier: "local-a")
        try setBinding(repository: repository, identifier: "local-b")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        repository = nil
        defaults = nil
        defaultsName = nil
        try super.tearDownWithError()
    }

    func testDefaultsAreNilAndUncheckedWithoutWritingRepositoryViewState() async {
        let store = makeStore(identifier: "local-a", repository: repository)
        let before = defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)

        let method = await store.preferredMergeMethod(
            repository: repository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let deleteChoice = await store.rememberedDeleteBranchChoice(repository: repository)

        XCTAssertNil(method)
        XCTAssertFalse(deleteChoice)
        XCTAssertNil(repositoryState(identifier: "local-a")?[RepositoryPullRequestMutationPreferenceStore.payloadKey])
        XCTAssertEqual(
            defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
                as NSDictionary?,
            before as NSDictionary?
        )
    }

    func testSuccessfulChoicesPersistAsOneExactIdentityPayloadAcrossRecreation() async throws {
        let first = makeStore(identifier: "local-a", repository: repository)

        await first.recordSuccessfulMerge(repository: repository, method: .squash)
        await first.recordSuccessfulDeleteBranchChoice(repository: repository, selected: true)

        let recreated = makeStore(identifier: "local-a", repository: repository)
        let method = await recreated.preferredMergeMethod(repository: repository, enabled: [.merge, .squash])
        let deleteChoice = await recreated.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertEqual(method, .squash)
        XCTAssertTrue(deleteChoice)

        let payload = try persistedPayload(identifier: "local-a")
        XCTAssertEqual(payload.repository, repository)
        XCTAssertEqual(payload.lastSuccessfulMergeMethod, .squash)
        XCTAssertTrue(payload.lastSuccessfulDeleteBranchChoice)

        let repositoryState = try XCTUnwrap(repositoryState(identifier: "local-a"))
        XCTAssertEqual(repositoryState.count, 2)
        XCTAssertNotNil(repositoryState[RepositoryPullRequestMutationPreferenceStore.forgeRepositoryBindingKey])
        XCTAssertNotNil(repositoryState[RepositoryPullRequestMutationPreferenceStore.payloadKey])
    }

    func testSuccessfulFalseDeleteChoiceReplacesEarlierTrueChoice() async {
        let store = makeStore(identifier: "local-a", repository: repository)
        await store.recordSuccessfulDeleteBranchChoice(repository: repository, selected: true)
        let initiallyRemembered = await store.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertTrue(initiallyRemembered)

        await store.recordSuccessfulDeleteBranchChoice(repository: repository, selected: false)

        let recreated = makeStore(identifier: "local-a", repository: repository)
        let replacedChoice = await recreated.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertFalse(replacedChoice)
    }

    func testRememberedMergeMethodIsReturnedOnlyWhileCurrentlyEnabled() async {
        let store = makeStore(identifier: "local-a", repository: repository)
        await store.recordSuccessfulMerge(repository: repository, method: .rebase)

        let disabled = await store.preferredMergeMethod(repository: repository, enabled: [.merge, .squash])
        let noMethods = await store.preferredMergeMethod(repository: repository, enabled: [])
        let enabled = await store.preferredMergeMethod(repository: repository, enabled: [.rebase])
        XCTAssertNil(disabled)
        XCTAssertNil(noMethods)
        XCTAssertEqual(enabled, .rebase)
    }

    func testLocalRepositoriesUseIndependentRepositoryViewStatePartitions() async throws {
        let first = makeStore(identifier: "local-a", repository: repository)
        let second = makeStore(identifier: "local-b", repository: repository)

        await first.recordSuccessfulMerge(repository: repository, method: .merge)
        await first.recordSuccessfulDeleteBranchChoice(repository: repository, selected: true)

        let emptySecondMethod = await second.preferredMergeMethod(
            repository: repository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let emptySecondChoice = await second.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertNil(emptySecondMethod)
        XCTAssertFalse(emptySecondChoice)
        await second.recordSuccessfulMerge(repository: repository, method: .rebase)

        let firstMethod = await first.preferredMergeMethod(
            repository: repository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let firstChoice = await first.rememberedDeleteBranchChoice(repository: repository)
        let secondMethod = await second.preferredMergeMethod(
            repository: repository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let secondChoice = await second.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertEqual(firstMethod, .merge)
        XCTAssertTrue(firstChoice)
        XCTAssertEqual(secondMethod, .rebase)
        XCTAssertFalse(secondChoice)
        XCTAssertEqual(try persistedPayload(identifier: "local-a").repository, repository)
        XCTAssertEqual(try persistedPayload(identifier: "local-b").repository, repository)
    }

    func testForgeRebindDoesNotExposeOldChoicesAndIgnoresLateOldStoreCompletions() async throws {
        let original = try XCTUnwrap(repository)
        let rebound = try makeRepository(owner: "gitx", name: "gitx")
        let originalStore = makeStore(identifier: "local-a", repository: original)
        await originalStore.recordSuccessfulMerge(repository: original, method: .squash)
        await originalStore.recordSuccessfulDeleteBranchChoice(repository: original, selected: true)

        try setBinding(repository: rebound, identifier: "local-a")

        let reboundStore = makeStore(identifier: "local-a", repository: rebound)
        let originalMethodAfterRebind = await originalStore.preferredMergeMethod(
            repository: original,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let originalChoiceAfterRebind = await originalStore.rememberedDeleteBranchChoice(repository: original)
        let reboundMethodBeforeSuccess = await reboundStore.preferredMergeMethod(
            repository: rebound,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let reboundChoiceBeforeSuccess = await reboundStore.rememberedDeleteBranchChoice(repository: rebound)
        XCTAssertNil(originalMethodAfterRebind)
        XCTAssertFalse(originalChoiceAfterRebind)
        XCTAssertNil(reboundMethodBeforeSuccess)
        XCTAssertFalse(reboundChoiceBeforeSuccess)

        await originalStore.recordSuccessfulMerge(repository: original, method: .rebase)
        await originalStore.recordSuccessfulDeleteBranchChoice(repository: original, selected: false)

        let unchanged = try persistedPayload(identifier: "local-a")
        XCTAssertEqual(unchanged.repository, original)
        XCTAssertEqual(unchanged.lastSuccessfulMergeMethod, .squash)
        XCTAssertTrue(unchanged.lastSuccessfulDeleteBranchChoice)

        await reboundStore.recordSuccessfulMerge(repository: rebound, method: .merge)
        let reboundMethodAfterSuccess = await reboundStore.preferredMergeMethod(
            repository: rebound,
            enabled: [.merge]
        )
        let reboundChoiceAfterSuccess = await reboundStore.rememberedDeleteBranchChoice(repository: rebound)
        XCTAssertEqual(reboundMethodAfterSuccess, .merge)
        XCTAssertFalse(reboundChoiceAfterSuccess)
        XCTAssertEqual(try persistedPayload(identifier: "local-a").repository, rebound)
    }

    func testMissingCurrentBindingFailsClosedAndCannotMutateExistingPayload() async throws {
        let exactRepository = try XCTUnwrap(repository)
        let store = makeStore(identifier: "local-a", repository: exactRepository)
        await store.recordSuccessfulMerge(repository: exactRepository, method: .squash)
        await store.recordSuccessfulDeleteBranchChoice(repository: exactRepository, selected: true)
        let before = try persistedPayload(identifier: "local-a")

        removeBinding(identifier: "local-a")

        let method = await store.preferredMergeMethod(
            repository: exactRepository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let deleteChoice = await store.rememberedDeleteBranchChoice(repository: exactRepository)
        await store.recordSuccessfulMerge(repository: exactRepository, method: .rebase)
        await store.recordSuccessfulDeleteBranchChoice(repository: exactRepository, selected: false)

        XCTAssertNil(method)
        XCTAssertFalse(deleteChoice)
        XCTAssertEqual(try persistedPayload(identifier: "local-a"), before)
    }

    func testOlderPayloadWithoutDeleteChoiceUsesSafeDefault() async throws {
        struct OlderPayload: Encodable {
            let repository: ForgeRepositoryIdentity
            let lastSuccessfulMergeMethod: ForgePullRequestMergeMethod
        }
        try setPersistedData(
            JSONEncoder().encode(OlderPayload(
                repository: repository,
                lastSuccessfulMergeMethod: .squash
            )),
            identifier: "local-a"
        )

        let store = makeStore(identifier: "local-a", repository: repository)

        let method = await store.preferredMergeMethod(repository: repository, enabled: [.squash])
        let deleteChoice = await store.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertEqual(method, .squash)
        XCTAssertFalse(deleteChoice)
    }

    func testInvalidPayloadFailsClosedAndNextExactSuccessRepairsIt() async throws {
        try setPersistedData(Data("not-json".utf8), identifier: "local-a")
        let store = makeStore(identifier: "local-a", repository: repository)

        let invalidMethod = await store.preferredMergeMethod(
            repository: repository,
            enabled: Set(ForgePullRequestMergeMethod.allCases)
        )
        let invalidChoice = await store.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertNil(invalidMethod)
        XCTAssertFalse(invalidChoice)

        await store.recordSuccessfulDeleteBranchChoice(repository: repository, selected: true)

        let repairedChoice = await store.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertTrue(repairedChoice)
        let repaired = try persistedPayload(identifier: "local-a")
        XCTAssertEqual(repaired.repository, repository)
        XCTAssertNil(repaired.lastSuccessfulMergeMethod)
        XCTAssertTrue(repaired.lastSuccessfulDeleteBranchChoice)
    }

    func testConcurrentStoresPreserveIndependentSuccessfulFields() async throws {
        let mergeStore = makeStore(identifier: "local-a", repository: repository)
        let deletionStore = makeStore(identifier: "local-a", repository: repository)
        let exactRepository = try XCTUnwrap(repository)

        await withTaskGroup(of: Void.self) { group in
            for iteration in 0 ..< 200 {
                group.addTask {
                    if iteration.isMultiple(of: 2) {
                        await mergeStore.recordSuccessfulMerge(repository: exactRepository, method: .squash)
                    } else {
                        await deletionStore.recordSuccessfulDeleteBranchChoice(
                            repository: exactRepository,
                            selected: true
                        )
                    }
                }
            }
        }

        let recreated = makeStore(identifier: "local-a", repository: repository)
        let method = await recreated.preferredMergeMethod(repository: repository, enabled: [.squash])
        let deleteChoice = await recreated.rememberedDeleteBranchChoice(repository: repository)
        XCTAssertEqual(method, .squash)
        XCTAssertTrue(deleteChoice)
    }

    func testAccountRemovalAndLatePreferenceWriteCannotResurrectBinding() async throws {
        let exactRepository = try XCTUnwrap(repository)
        let accountID = try ForgeAccountID(forge: exactRepository.forge, value: "removed-account")
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: exactRepository,
            preferredAccount: accountID
        )
        var all = defaults.dictionary(
            forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey
        ) ?? [:]
        var state = all["local-a"] as? [String: Any] ?? [:]
        state[RepositoryPullRequestMutationPreferenceStore.forgeRepositoryBindingKey] = try JSONEncoder()
            .encode(binding)
        state["hideContainedBranches"] = true
        all["local-a"] = state
        defaults.set(all, forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
        let store = makeStore(identifier: "local-a", repository: exactRepository)
        let cleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for iteration in 0 ..< 100 {
                group.addTask {
                    if iteration.isMultiple(of: 2) {
                        try? cleaner.removeBindings(for: accountID)
                    } else {
                        await store.recordSuccessfulMerge(repository: exactRepository, method: .squash)
                    }
                }
            }
        }

        let finalState = try XCTUnwrap(repositoryState(identifier: "local-a"))
        XCTAssertNil(finalState[RepositoryPullRequestMutationPreferenceStore.forgeRepositoryBindingKey])
        XCTAssertEqual(finalState["hideContainedBranches"] as? Bool, true)
    }

    func testUnrelatedRepositoryViewStateFieldsSurviveSuccessfulRecords() async {
        var all = defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey) ?? [:]
        var firstState = all["local-a"] as? [String: Any] ?? [:]
        firstState["hideContainedBranches"] = true
        firstState["sidebarVisibility"] = ["Remotes": false]
        all["local-a"] = firstState
        var secondState = all["local-b"] as? [String: Any] ?? [:]
        secondState["pushAfterCommit"] = true
        all["local-b"] = secondState
        defaults.set(all, forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
        let store = makeStore(identifier: "local-a", repository: repository)

        await store.recordSuccessfulMerge(repository: repository, method: .merge)
        await store.recordSuccessfulDeleteBranchChoice(repository: repository, selected: true)

        let first = repositoryState(identifier: "local-a")
        XCTAssertEqual(first?["hideContainedBranches"] as? Bool, true)
        XCTAssertEqual((first?["sidebarVisibility"] as? [String: Bool])?["Remotes"], false)
        XCTAssertEqual(repositoryState(identifier: "local-b")?["pushAfterCommit"] as? Bool, true)
    }

    private func makeStore(
        identifier: String,
        repository: ForgeRepositoryIdentity
    ) -> RepositoryPullRequestMutationPreferenceStore {
        RepositoryPullRequestMutationPreferenceStore(
            repositoryViewStateIdentifier: identifier,
            repository: repository,
            userDefaults: defaults
        )
    }

    private func repositoryState(identifier: String) -> [String: Any]? {
        defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)?[identifier]
            as? [String: Any]
    }

    private func persistedPayload(
        identifier: String
    ) throws -> RepositoryPullRequestMutationPreferences {
        let state = try XCTUnwrap(repositoryState(identifier: identifier))
        let data = try XCTUnwrap(state[RepositoryPullRequestMutationPreferenceStore.payloadKey] as? Data)
        return try JSONDecoder().decode(RepositoryPullRequestMutationPreferences.self, from: data)
    }

    private func setPersistedData(_ data: Data, identifier: String) throws {
        var all = defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey) ?? [:]
        var state = all[identifier] as? [String: Any] ?? [:]
        state[RepositoryPullRequestMutationPreferenceStore.payloadKey] = data
        all[identifier] = state
        defaults.set(all, forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
    }

    private func setBinding(repository: ForgeRepositoryIdentity, identifier: String) throws {
        let binding = try ForgeRepositoryBinding(
            localRemoteName: "origin",
            primaryRepository: repository
        )
        var all = defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey) ?? [:]
        var state = all[identifier] as? [String: Any] ?? [:]
        state[RepositoryPullRequestMutationPreferenceStore.forgeRepositoryBindingKey] = try JSONEncoder()
            .encode(binding)
        all[identifier] = state
        defaults.set(all, forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
    }

    private func removeBinding(identifier: String) {
        var all = defaults.dictionary(forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey) ?? [:]
        var state = all[identifier] as? [String: Any] ?? [:]
        state.removeValue(forKey: RepositoryPullRequestMutationPreferenceStore.forgeRepositoryBindingKey)
        all[identifier] = state
        defaults.set(all, forKey: RepositoryPullRequestMutationPreferenceStore.repositorySettingsKey)
    }

    private func makeRepository(owner: String, name: String) throws -> ForgeRepositoryIdentity {
        try ForgeRepositoryIdentity(
            forge: ForgeIdentity(
                kind: .github,
                origin: ForgeOrigin(host: "github.com")
            ),
            owner: owner,
            name: name
        )
    }
}
