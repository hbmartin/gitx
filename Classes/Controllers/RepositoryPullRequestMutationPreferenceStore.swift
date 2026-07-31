import ForgeKit
import Foundation

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

nonisolated enum RepositoryViewStatePreferencesSynchronization {
    static let lock = NSLock()
}

// swift6-safety-justification: UserDefaults is thread-safe; this immutable wrapper is safe to capture in Sendable factories.
final nonisolated class RepositoryPullRequestMutationPreferenceDefaults: @unchecked Sendable {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        userDefaults.dictionary(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }
}

/// Pull Request mutation choices owned by one local repository's Repository View State.
///
/// The Forge repository identity is persisted alongside the choices so a local repository
/// rebind cannot leak the old repository's choices into the new overlay.
nonisolated struct RepositoryPullRequestMutationPreferences: Codable, Hashable, Sendable {
    let repository: ForgeRepositoryIdentity
    var lastSuccessfulMergeMethod: ForgePullRequestMergeMethod?
    var lastSuccessfulDeleteBranchChoice: Bool

    init(
        repository: ForgeRepositoryIdentity,
        lastSuccessfulMergeMethod: ForgePullRequestMergeMethod? = nil,
        lastSuccessfulDeleteBranchChoice: Bool = false
    ) {
        self.repository = repository
        self.lastSuccessfulMergeMethod = lastSuccessfulMergeMethod
        self.lastSuccessfulDeleteBranchChoice = lastSuccessfulDeleteBranchChoice
    }

    private enum CodingKeys: String, CodingKey {
        case repository
        case lastSuccessfulMergeMethod
        case lastSuccessfulDeleteBranchChoice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decode(ForgeRepositoryIdentity.self, forKey: .repository)
        lastSuccessfulMergeMethod = try container.decodeIfPresent(
            ForgePullRequestMergeMethod.self,
            forKey: .lastSuccessfulMergeMethod
        )
        lastSuccessfulDeleteBranchChoice = try container.decodeIfPresent(
            Bool.self,
            forKey: .lastSuccessfulDeleteBranchChoice
        ) ?? false
    }
}

/// Persists only choices confirmed by successful Pull Request mutations.
///
/// The store performs atomic read-modify-write operations across all instances so concurrent
/// merge and branch-deletion completions preserve both independent fields.
final nonisolated class RepositoryPullRequestMutationPreferenceStore:
    RepositoryPullRequestMutationPreferencePersisting,
    // swift6-safety-justification: The shared lock serializes every access to UserDefaults-backed state.
    @unchecked Sendable
{
    static let repositorySettingsKey = "PBRepositoryUISettings"
    static let forgeRepositoryBindingKey = "forgeRepositoryBinding"
    static let payloadKey = "forgePullRequestMutationPreferences"

    private static let logger = Logger(
        subsystem: "com.gitx.gitx",
        category: "PullRequestMutationPreferences"
    )

    private let repositoryViewStateIdentifier: String
    private let repository: ForgeRepositoryIdentity
    private let defaults: RepositoryPullRequestMutationPreferenceDefaults

    init(
        repositoryViewStateIdentifier: String,
        repository: ForgeRepositoryIdentity,
        defaults: RepositoryPullRequestMutationPreferenceDefaults
    ) {
        self.repositoryViewStateIdentifier = repositoryViewStateIdentifier
        self.repository = repository
        self.defaults = defaults
    }

    convenience init(
        repositoryViewStateIdentifier: String,
        repository: ForgeRepositoryIdentity,
        userDefaults: UserDefaults
    ) {
        self.init(
            repositoryViewStateIdentifier: repositoryViewStateIdentifier,
            repository: repository,
            defaults: RepositoryPullRequestMutationPreferenceDefaults(userDefaults: userDefaults)
        )
    }

    /// Returns the remembered method only when it still belongs to this exact Forge
    /// repository and the latest server state says that method is enabled.
    func preferredMergeMethod(
        repository requestedRepository: ForgeRepositoryIdentity,
        enabled enabledMethods: Set<ForgePullRequestMergeMethod>
    ) async -> ForgePullRequestMergeMethod? {
        RepositoryViewStatePreferencesSynchronization.lock.withLock {
            let repositorySettings = persistedRepositorySettings()
            guard currentBinding(in: repositorySettings)?.primaryRepository == repository,
                  requestedRepository == repository,
                  let payload = persistedPayload(in: repositorySettings),
                  payload.repository == repository
            else {
                return nil
            }
            guard let method = payload.lastSuccessfulMergeMethod, enabledMethods.contains(method) else {
                return nil
            }
            return method
        }
    }

    /// The first safe choice is unchecked. A value becomes true only after an explicit
    /// successful-record call for this exact Forge repository.
    func rememberedDeleteBranchChoice(
        repository requestedRepository: ForgeRepositoryIdentity
    ) async -> Bool {
        RepositoryViewStatePreferencesSynchronization.lock.withLock {
            let repositorySettings = persistedRepositorySettings()
            guard currentBinding(in: repositorySettings)?.primaryRepository == repository,
                  requestedRepository == repository,
                  let payload = persistedPayload(in: repositorySettings),
                  payload.repository == repository
            else {
                return false
            }
            return payload.lastSuccessfulDeleteBranchChoice
        }
    }

    /// Records a merge method only after the caller has observed a successful merge.
    /// A late completion from a repository that is no longer bound is ignored.
    func recordSuccessfulMerge(
        repository resultRepository: ForgeRepositoryIdentity,
        method: ForgePullRequestMergeMethod
    ) async {
        guard updatePayload(resultRepository: resultRepository, update: { payload in
            payload.lastSuccessfulMergeMethod = method
        }) else {
            Self.logger.notice("Ignored a successful merge preference for a mismatched Forge repository")
            return
        }
        Self.logger.info("Recorded the last successful Pull Request merge method")
    }

    /// Records the selected delete-head-branch choice only after the caller has observed
    /// the successful operation whose confirmation contained that choice.
    func recordSuccessfulDeleteBranchChoice(
        repository resultRepository: ForgeRepositoryIdentity,
        selected: Bool
    ) async {
        guard updatePayload(resultRepository: resultRepository, update: { payload in
            payload.lastSuccessfulDeleteBranchChoice = selected
        }) else {
            Self.logger.notice("Ignored a successful branch-deletion preference for a mismatched Forge repository")
            return
        }
        Self.logger.info("Recorded the last successful Pull Request branch-deletion choice")
    }

    private func updatePayload(
        resultRepository: ForgeRepositoryIdentity,
        update: (inout RepositoryPullRequestMutationPreferences) -> Void
    ) -> Bool {
        RepositoryViewStatePreferencesSynchronization.lock.withLock {
            var allRepositorySettings = defaults.dictionary(forKey: Self.repositorySettingsKey) ?? [:]
            var repositorySettings = allRepositorySettings[repositoryViewStateIdentifier] as? [String: Any] ?? [:]
            guard currentBinding(in: repositorySettings)?.primaryRepository == repository,
                  resultRepository == repository
            else {
                return false
            }
            var payload = persistedPayload(in: repositorySettings)
                .flatMap { $0.repository == repository ? $0 : nil }
                ?? RepositoryPullRequestMutationPreferences(repository: repository)
            update(&payload)

            do {
                repositorySettings[Self.payloadKey] = try JSONEncoder().encode(payload)
                allRepositorySettings[repositoryViewStateIdentifier] = repositorySettings
                defaults.set(allRepositorySettings, forKey: Self.repositorySettingsKey)
                return true
            } catch {
                Self.logger.error("Could not encode Pull Request mutation Repository View State")
                return false
            }
        }
    }

    private func persistedRepositorySettings() -> [String: Any] {
        let allRepositorySettings = defaults.dictionary(forKey: Self.repositorySettingsKey) ?? [:]
        return allRepositorySettings[repositoryViewStateIdentifier] as? [String: Any] ?? [:]
    }

    private func currentBinding(in repositorySettings: [String: Any]) -> ForgeRepositoryBinding? {
        guard let data = repositorySettings[Self.forgeRepositoryBindingKey] as? Data else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ForgeRepositoryBinding.self, from: data)
        } catch {
            Self.logger.error("Ignored invalid Forge Repository Binding while reading mutation preferences")
            return nil
        }
    }

    private func persistedPayload(
        in repositorySettings: [String: Any]
    ) -> RepositoryPullRequestMutationPreferences? {
        guard let data = repositorySettings[Self.payloadKey] as? Data else {
            return nil
        }
        do {
            return try JSONDecoder().decode(RepositoryPullRequestMutationPreferences.self, from: data)
        } catch {
            Self.logger.error("Ignored invalid Pull Request mutation Repository View State")
            return nil
        }
    }
}
