import ForgeKit
import Foundation
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBRepositoryUISettings)
// swift6-safety-justification: the shared lock serializes every preferences access; remaining state is immutable.
final nonisolated class RepositoryUISettings: NSObject, @unchecked Sendable {
    private static let defaultsKey = "PBRepositoryUISettings"
    private static let forgeRepositoryBindingKey = "forgeRepositoryBinding"
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryViewState")
    private let repositoryKey: String

    @objc(initWithRepository:)
    convenience init(repository: PBGitRepository) {
        self.init(
            repository: repository,
            preferences: ApplicationComposition.shared.applicationPreferences
        )
    }

    init(repository: PBGitRepository, preferences: ApplicationPreferences) {
        repositoryKey = ApplicationPreferencePolicy.repositoryViewStateIdentifier(
            for: Self.commonGitDirectory(for: repository)
        )
        self.preferences = preferences
        super.init()
    }

    var repositoryViewStateIdentifier: String {
        repositoryKey
    }

    private let preferences: ApplicationPreferences

    @objc var hideContainedBranches: Bool {
        get { value(for: "hideContainedBranches") as? Bool ?? false }
        set { setValue(newValue, for: "hideContainedBranches") }
    }

    @objc var pushAfterCommit: Bool {
        get { value(for: "pushAfterCommit") as? Bool ?? false }
        set { setValue(newValue, for: "pushAfterCommit") }
    }

    @objc var historyRepositoryFactsInspectorVisible: Bool {
        get { value(for: "historyRepositoryFactsInspectorVisible") as? Bool ?? false }
        set { setValue(newValue, for: "historyRepositoryFactsInspectorVisible") }
    }

    @objc var sidebarVisibility: [String: Bool] {
        get {
            value(for: "sidebarVisibility") as? [String: Bool] ?? [
                "Remotes": true,
                "Tags": true,
                "Stashes": true,
                "Submodules": true,
                "Other": true,
            ]
        }
        set { setValue(newValue, for: "sidebarVisibility") }
    }

    @objc func isSidebarGroupVisible(_ group: String) -> Bool {
        sidebarVisibility[group] ?? true
    }

    var forgeRepositoryBinding: ForgeRepositoryBinding? {
        get {
            guard let data = value(for: Self.forgeRepositoryBindingKey) as? Data else {
                return nil
            }
            do {
                return try JSONDecoder().decode(ForgeRepositoryBinding.self, from: data)
            } catch {
                Self.logger.error("Ignored an invalid persisted Forge Repository Binding")
                return nil
            }
        }
        set {
            guard let newValue else {
                removeValue(for: Self.forgeRepositoryBindingKey)
                Self.logger.info("Removed the Forge Repository Binding from repository view state")
                return
            }
            do {
                let data = try JSONEncoder().encode(newValue)
                setValue(data, for: Self.forgeRepositoryBindingKey)
                Self.logger.info(
                    "Saved a Forge Repository Binding provider=\(newValue.primaryRepository.forge.kind.rawValue, privacy: .public)"
                )
            } catch {
                Self.logger.error("Could not encode the Forge Repository Binding")
            }
        }
    }

    private func value(for key: String) -> Any? {
        RepositoryViewStatePreferencesSynchronization.lock.lock()
        defer { RepositoryViewStatePreferencesSynchronization.lock.unlock() }
        let all = preferences.dictionary(forKey: Self.defaultsKey) ?? [:]
        return (all[repositoryKey] as? [String: Any])?[key]
    }

    private func setValue(_ value: Any, for key: String) {
        RepositoryViewStatePreferencesSynchronization.lock.lock()
        defer { RepositoryViewStatePreferencesSynchronization.lock.unlock() }
        var all = preferences.dictionary(forKey: Self.defaultsKey) ?? [:]
        var repository = all[repositoryKey] as? [String: Any] ?? [:]
        repository[key] = value
        all[repositoryKey] = repository
        preferences.set(all, forKey: Self.defaultsKey)
    }

    private func removeValue(for key: String) {
        RepositoryViewStatePreferencesSynchronization.lock.lock()
        defer { RepositoryViewStatePreferencesSynchronization.lock.unlock() }
        var all = preferences.dictionary(forKey: Self.defaultsKey) ?? [:]
        var repository = all[repositoryKey] as? [String: Any] ?? [:]
        repository.removeValue(forKey: key)
        all[repositoryKey] = repository
        preferences.set(all, forKey: Self.defaultsKey)
    }

    private static func commonGitDirectory(for repository: PBGitRepository) -> URL {
        if let output = try? repository.outputOfTask(withArguments: ["rev-parse", "--git-common-dir"]),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let base = repository.workingDirectoryURL() ?? repository.gitURL() ?? URL(fileURLWithPath: "/")
            return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
        }
        return repository.gitURL() ?? repository.workingDirectoryURL() ?? URL(fileURLWithPath: "/")
    }
}

@objc(PBRepositorySettingsStore)
final nonisolated class RepositorySettingsStore: NSObject {
    static let primaryBranchKey = "gitx.primaryBranch"
    static let commitRulesKey = "gitx.commitMessageReplacementRules"
    static let autoOpenURLKey = "gitx.autoOpenPushedURL"
    static let requireHostMatchKey = "gitx.requirePushedURLHostMatch"
    static let webURLTemplateKey = "gitx.webURLTemplate"
    static let diffSuppressionKey = "gitx.diffSuppressionPatterns"

    private let repository: PBGitRepository
    @objc let uiSettings: RepositoryUISettings
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositorySettings")

    @objc(initWithRepository:)
    convenience init(repository: PBGitRepository) {
        self.init(
            repository: repository,
            preferences: ApplicationComposition.shared.applicationPreferences
        )
    }

    init(repository: PBGitRepository, preferences: ApplicationPreferences) {
        self.repository = repository
        uiSettings = RepositoryUISettings(repository: repository, preferences: preferences)
        super.init()
    }

    @objc func string(forKey key: String) -> String {
        do {
            return try repository.outputOfTask(withArguments: ["config", "--local", "--get", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    @objc func bool(forKey key: String, defaultValue: Bool) -> Bool {
        let value = string(forKey: key).lowercased()
        if ["true", "yes", "on", "1"].contains(value) {
            return true
        }
        if ["false", "no", "off", "0"].contains(value) {
            return false
        }
        return defaultValue
    }

    @objc func setString(_ value: String, forKey key: String) throws {
        try repository.launchTask(withArguments: ["config", "--local", key, value])
        logger.info("Updated repository-local GitX configuration")
    }

    @objc func setBool(_ value: Bool, forKey key: String) throws {
        try setString(value ? "true" : "false", forKey: key)
    }

    @objc func detectedPrimaryBranch() -> String {
        let configured = string(forKey: Self.primaryBranchKey)
        if !configured.isEmpty {
            return configured
        }
        if let remoteHead = try? repository.outputOfTask(withArguments: [
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
        ]) {
            let short = remoteHead.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = short.firstIndex(of: "/") {
                return String(short[short.index(after: slash)...])
            }
        }
        if repository.ref(forName: "refs/heads/main") != nil {
            return "main"
        }
        if repository.ref(forName: "refs/heads/master") != nil {
            return "master"
        }
        return repository.headRef()?.ref()?.shortName() ?? "main"
    }
}
