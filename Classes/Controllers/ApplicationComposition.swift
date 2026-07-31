import Foundation

@objc(PBApplicationPreferences)
// swift6-safety-justification: UserDefaults is thread-safe, and this wrapper adds no mutable state of its own.
final nonisolated class ApplicationPreferences: NSObject, @unchecked Sendable {
    let userDefaults: UserDefaults

    @objc(initWithUserDefaults:)
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        super.init()
    }

    @objc(registerDefaults:)
    func register(defaults: [String: Any]) { // swiftlint:disable:this unused_declaration
        userDefaults.register(defaults: defaults)
    }

    @objc(objectForKey:)
    func object(forKey key: String) -> Any? { // swiftlint:disable:this unused_declaration
        userDefaults.object(forKey: key)
    }

    @objc(stringForKey:)
    func string(forKey key: String) -> String? { // swiftlint:disable:this unused_declaration
        userDefaults.string(forKey: key)
    }

    @objc(arrayForKey:)
    func array(forKey key: String) -> [Any]? { // swiftlint:disable:this unused_declaration
        userDefaults.array(forKey: key)
    }

    @objc(dictionaryForKey:)
    func dictionary(forKey key: String) -> [String: Any]? {
        userDefaults.dictionary(forKey: key)
    }

    @objc(dataForKey:)
    func data(forKey key: String) -> Data? { // swiftlint:disable:this unused_declaration
        userDefaults.data(forKey: key)
    }

    @objc(boolForKey:)
    func bool(forKey key: String) -> Bool { // swiftlint:disable:this unused_declaration
        userDefaults.bool(forKey: key)
    }

    @objc(integerForKey:)
    func integer(forKey key: String) -> Int { // swiftlint:disable:this unused_declaration
        userDefaults.integer(forKey: key)
    }

    @objc(doubleForKey:)
    func double(forKey key: String) -> Double { // swiftlint:disable:this unused_declaration
        userDefaults.double(forKey: key)
    }

    @objc(setObject:forKey:)
    func set(_ value: Any?, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    @objc(setBool:forKey:)
    func set(_ value: Bool, forKey key: String) { // swiftlint:disable:this unused_declaration
        userDefaults.set(value, forKey: key)
    }

    @objc(setInteger:forKey:)
    func set(_ value: Int, forKey key: String) { // swiftlint:disable:this unused_declaration
        userDefaults.set(value, forKey: key)
    }

    @objc(setDouble:forKey:)
    func set(_ value: Double, forKey key: String) { // swiftlint:disable:this unused_declaration
        userDefaults.set(value, forKey: key)
    }

    @objc(removeObjectForKey:)
    func removeObject(forKey key: String) { // swiftlint:disable:this unused_declaration
        userDefaults.removeObject(forKey: key)
    }

    @objc
    func synchronize() {
        userDefaults.synchronize()
    }
}

// swift6-safety-justification: UserDefaults supports concurrent reads, and this immutable wrapper only exposes one read operation to the Sendable startup closure.
private final nonisolated class ForgeAvatarLoadingPreferenceSource: @unchecked Sendable {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func isEnabled() -> Bool {
        ApplicationSettings.loadAvatars(in: userDefaults)
    }
}

@objc(PBApplicationComposition)
final nonisolated class ApplicationComposition: NSObject {
    private static let configuredSharedLock = NSLock()
    // swift6-safety-justification: `configuredSharedLock` protects every read and mutation of the shared composition.
    private nonisolated(unsafe) static var configuredShared = ApplicationComposition(userDefaults: .standard)

    static var shared: ApplicationComposition {
        configuredSharedLock.lock()
        defer { configuredSharedLock.unlock() }
        return configuredShared
    }

    @objc let applicationPreferences: ApplicationPreferences
    let forgeServices: ForgeApplicationServiceLoader
    let forgeExternalLinkPreferences: ForgeTrustedExternalOriginStore
    let forgePullRequestServices: RepositoryPullRequestServiceResolver
    let forgePullRequestReviewServices: RepositoryPullRequestReviewServiceResolver
    let forgeCloneServices: RepositoryForgeCloneServiceResolver
    private let automaticallyStartsForgeServices: Bool
    private let forgeServiceStartupLock = NSLock()
    private var didStartForgeServices = false

    @objc(initWithUserDefaults:)
    convenience init(userDefaults: UserDefaults) {
        self.init(userDefaults: userDefaults, automaticallyStartsForgeServices: true)
    }

    @objc(initWithUserDefaults:automaticallyStartsForgeServices:)
    convenience init(
        userDefaults: UserDefaults,
        automaticallyStartsForgeServices: Bool
    ) {
        let bindingCleaner = ForgeRepositoryBindingAccountCleaner(userDefaults: userDefaults)
        let avatarLoadingPreferenceSource = ForgeAvatarLoadingPreferenceSource(userDefaults: userDefaults)
        let forgeServices = ForgeApplicationServiceLoader(
            bindingCleaner: bindingCleaner,
            avatarLoader: .shared,
            avatarLoadingEnabled: { avatarLoadingPreferenceSource.isEnabled() }
        )
        let pullRequestDependencies = ForgeGitHubPullRequestDependencyProvider(loader: forgeServices)
        let applicationPreferences = ApplicationPreferences(userDefaults: userDefaults)
        let pullRequestMutationDefaults = RepositoryPullRequestMutationPreferenceDefaults(userDefaults: userDefaults)
        self.init(
            userDefaults: userDefaults,
            forgeServices: forgeServices,
            forgePullRequestServices: RepositoryPullRequestServiceResolver { repository in
                let settings = RepositoryUISettings(repository: repository, preferences: applicationPreferences)
                guard let binding = settings.forgeRepositoryBinding,
                      ForgeGitHubReadCredentialAuthority.isGitHubDotCom(binding.primaryRepository.forge)
                else {
                    return RepositoryPullRequestApplicationSession(
                        service: UnavailableRepositoryPullRequestMutationService(),
                        drafts: ForgeLazySQLitePullRequestDraftStore(loader: forgeServices)
                    )
                }
                return RepositoryPullRequestApplicationSession(
                    service: RepositoryPullRequestProductionService(
                        binding: binding,
                        dependencies: pullRequestDependencies,
                        localPreparation: RepositoryPullRequestLocalPreparationSource(repository: repository),
                        mutationLifecycle: ForgeMutationQuitCoordinator.shared
                    ),
                    drafts: ForgeLazySQLitePullRequestDraftStore(loader: forgeServices)
                )
            },
            forgePullRequestReviewServices: RepositoryPullRequestReviewServiceResolver { repository in
                let settings = RepositoryUISettings(repository: repository, preferences: applicationPreferences)
                let drafts = ForgeLazySQLitePullRequestDraftStore(loader: forgeServices)
                guard let binding = settings.forgeRepositoryBinding,
                      ForgeGitHubReadCredentialAuthority.isGitHubDotCom(binding.primaryRepository.forge)
                else {
                    return RepositoryPullRequestReviewApplicationSession(
                        service: UnavailableRepositoryPullRequestReviewMutationService(),
                        localService: UnavailableRepositoryPullRequestLocalReviewService(),
                        drafts: drafts,
                        preferences: NullRepositoryPullRequestMutationPreferenceStore()
                    )
                }
                let localService = RepositoryPullRequestLocalReviewService(
                    runner: RepositoryPullRequestObjectiveGitRunner(repository: repository),
                    workingDirectory: repository.workingDirectoryURL(),
                    binding: binding,
                    currentBinding: { settings.forgeRepositoryBinding }
                )
                return RepositoryPullRequestReviewApplicationSession(
                    service: RepositoryPullRequestReviewProductionService(
                        binding: binding,
                        dependencies: pullRequestDependencies,
                        localService: localService,
                        mutationLifecycle: ForgeMutationQuitCoordinator.shared,
                        unknownOutcomes: ForgeMutationQuitCoordinator.shared,
                        currentBinding: { settings.forgeRepositoryBinding }
                    ),
                    localService: localService,
                    drafts: drafts,
                    preferences: RepositoryPullRequestMutationPreferenceStore(
                        repositoryViewStateIdentifier: settings.repositoryViewStateIdentifier,
                        repository: binding.primaryRepository,
                        defaults: pullRequestMutationDefaults
                    )
                )
            },
            forgeCloneServices: RepositoryForgeCloneServiceResolver {
                RepositoryForgeCloneProductionService(loader: forgeServices)
            },
            automaticallyStartsForgeServices: automaticallyStartsForgeServices
        )
    }

    init(
        userDefaults: UserDefaults,
        forgeServices: ForgeApplicationServiceLoader,
        forgePullRequestServices: RepositoryPullRequestServiceResolver = RepositoryPullRequestServiceResolver(),
        forgePullRequestReviewServices: RepositoryPullRequestReviewServiceResolver = RepositoryPullRequestReviewServiceResolver(),
        forgeCloneServices: RepositoryForgeCloneServiceResolver = RepositoryForgeCloneServiceResolver(),
        automaticallyStartsForgeServices: Bool = true
    ) {
        applicationPreferences = ApplicationPreferences(userDefaults: userDefaults)
        self.forgeServices = forgeServices
        self.forgePullRequestServices = forgePullRequestServices
        self.forgePullRequestReviewServices = forgePullRequestReviewServices
        self.forgeCloneServices = forgeCloneServices
        forgeExternalLinkPreferences = ForgeTrustedExternalOriginStore(defaults: userDefaults)
        self.automaticallyStartsForgeServices = automaticallyStartsForgeServices
        super.init()
    }

    private func startForgeServicesIfNeeded() {
        guard automaticallyStartsForgeServices else { return }
        forgeServiceStartupLock.lock()
        let shouldStart = !didStartForgeServices
        didStartForgeServices = true
        forgeServiceStartupLock.unlock()
        guard shouldStart else { return }
        let forgeServices = forgeServices
        Task {
            do {
                _ = try await forgeServices.services()
                NSLog("[GitX] Forge application services initialized from the composition root")
            } catch {
                NSLog("[GitX] Forge application services initialization failed from the composition root")
            }
        }
    }

    @objc(sharedComposition)
    static func sharedComposition() -> ApplicationComposition { // swiftlint:disable:this unused_declaration
        shared
    }

    @objc(setSharedComposition:)
    static func setSharedComposition(_ composition: ApplicationComposition) { // swiftlint:disable:this unused_declaration
        configuredSharedLock.lock()
        configuredShared = composition
        configuredSharedLock.unlock()
        composition.startForgeServicesIfNeeded()
        NSLog("[GitX] Configured application composition root")
    }

    @objc(repositoryConfigurationForRepository:)
    func repositoryConfiguration(for repository: PBGitRepository) -> RepositorySettingsStore {
        RepositorySettingsStore(repository: repository, preferences: applicationPreferences)
    }

    @objc(repositoryViewStateForRepository:)
    func repositoryViewState(for repository: PBGitRepository) -> RepositoryUISettings {
        RepositoryUISettings(repository: repository, preferences: applicationPreferences)
    }
}
