import Foundation

@objc(PBApplicationPreferences)
final nonisolated class ApplicationPreferences: NSObject {
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

@objc(PBApplicationComposition)
final nonisolated class ApplicationComposition: NSObject {
    private static let configuredSharedLock = NSLock()
    // swift6-safety-justification: `configuredSharedLock` protects every read and mutation of the shared composition.
    private nonisolated(unsafe) static var configuredShared: ApplicationComposition?

    static var shared: ApplicationComposition {
        configuredSharedLock.lock()
        defer { configuredSharedLock.unlock() }
        if let configuredShared {
            return configuredShared
        }
        let composition = ApplicationComposition(userDefaults: .standard)
        configuredShared = composition
        return composition
    }

    @objc let applicationPreferences: ApplicationPreferences

    @objc(initWithUserDefaults:)
    init(userDefaults: UserDefaults) {
        applicationPreferences = ApplicationPreferences(userDefaults: userDefaults)
        super.init()
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
