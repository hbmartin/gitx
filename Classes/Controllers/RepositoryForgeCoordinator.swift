import ForgeKit
import Foundation

/// A passive metadata refresh can reuse even an unavailable result, provided
/// its persisted binding, executable and verifiable config inputs still match.
nonisolated struct RepositoryForgeQueryRevision: Equatable {
    let binding: ForgeRepositoryBinding?
    let configuration: String
    let dependencies: [String: String]
    let selection: GitBinarySelection?
}

nonisolated struct RepositoryForgeQueryRefreshPolicy {
    private(set) var prepared: RepositoryForgeQueryRevision?

    func needsPreparation(_ revision: RepositoryForgeQueryRevision?) -> Bool {
        revision == nil || revision != prepared
    }

    mutating func didPrepare(_ revision: RepositoryForgeQueryRevision?) {
        prepared = revision
    }
}

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

@objc(PBRepositoryForgeBindingResolutionKind)
enum RepositoryForgeBindingResolutionKind: Int {
    case existing
    case automatic
    case requiresChoice
    case unavailable
}

@objc(PBRepositoryForgeRevisionKind)
enum RepositoryForgeRevisionKind: Int {
    case branch
    case tag
    case commit
}

@objc(PBRepositoryForgeScriptingErrorCode)
enum RepositoryForgeScriptingErrorCode: Int {
    case noForgeRepository = 18001
    case ambiguousForgeRepository = 18002
    case invalidDestination = 18003
    case ambiguousDestination = 18004
    case noAvailableDestination = 18005
}

@objc(PBRepositoryForgeBindingCandidate)
// swift6-safety-justification: stored state is immutable and every ForgeKit value is Sendable.
final class RepositoryForgeBindingCandidate: NSObject, @unchecked Sendable {
    let candidate: ForgeRepositoryCandidate
    let originalRemoteURL: String

    init(candidate: ForgeRepositoryCandidate, originalRemoteURL: String) {
        self.candidate = candidate
        self.originalRemoteURL = originalRemoteURL
        super.init()
    }

    @objc var localRemoteName: String {
        candidate.remoteName
    }

    @objc var providerName: String {
        RepositoryForgeProviderName.name(for: candidate.repository.forge.kind)
    }

    @objc var repositoryLabel: String {
        "\(candidate.repository.owner)/\(candidate.repository.name)"
    }

    @objc var repositoryURL: URL? {
        try? ForgeDestinationURLCodec.url(for: .repository(candidate.repository))
    }
}

@objc(PBRepositoryForgeBindingResolution)
final class RepositoryForgeBindingResolution: NSObject {
    @objc let kind: RepositoryForgeBindingResolutionKind
    @objc let candidates: [RepositoryForgeBindingCandidate]
    let binding: ForgeRepositoryBinding?

    init(
        kind: RepositoryForgeBindingResolutionKind,
        binding: ForgeRepositoryBinding? = nil,
        candidates: [RepositoryForgeBindingCandidate] = []
    ) {
        self.kind = kind
        self.binding = binding
        self.candidates = candidates
        super.init()
    }

    @objc var localRemoteName: String? {
        binding?.localRemoteName
    }

    @objc var repositoryURL: URL? {
        guard let repository = binding?.primaryRepository else { return nil }
        return try? ForgeDestinationURLCodec.url(for: .repository(repository))
    }

    @objc var providerName: String? {
        if let kind = binding?.primaryRepository.forge.kind {
            return Self.providerName(for: kind)
        }
        let names = Set(candidates.map(\.providerName))
        return names.count == 1 ? names.first : nil
    }

    private static func providerName(for kind: ForgeKind) -> String {
        RepositoryForgeProviderName.name(for: kind)
    }
}

nonisolated enum RepositoryForgeRevisionRequest: Equatable, Sendable {
    case branch(String)
    case tag(String)
    case commit(String)
}

nonisolated enum RepositoryForgeDestinationRequest: Equatable, Sendable {
    case repository
    case branch(String)
    case commit(String)
    case file(
        revision: RepositoryForgeRevisionRequest,
        path: String,
        startLine: Int?,
        endLine: Int?
    )
    case compare(base: RepositoryForgeRevisionRequest, head: RepositoryForgeRevisionRequest)
    case pullRequest(Int)
    case issue(Int)
}

enum RepositoryForgeDestinationResolution {
    case route(ForgeDestinationRoute)
    case requiresBindingChoice([RepositoryForgeBindingCandidate])
    case failure(NSError)
}

enum RepositoryForgeNumberResolution {
    case route(ForgeDestinationRoute)
    case requiresBindingChoice([RepositoryForgeBindingCandidate])
    case requiresDestinationChoice([ForgeDestinationChoice])
    case failure(NSError)
}

/// Resolves local Git remotes into one stable Forge Repository Binding and
/// constructs provider-neutral destinations without presenting AppKit UI.
@objc(PBRepositoryForgeCoordinator)
final class RepositoryForgeCoordinator: NSObject {
    static let scriptingErrorDomain = "com.gitx.forge.scripting"

    private let repository: PBGitRepository
    private let settings: RepositoryUISettings
    private let remoteDescriptorCache: RepositoryForgeRemoteDescriptorCache
    private let remoteCacheKey: String
    private let remoteConfigurationRevision: () -> String
    private let remoteConfigurationDependencies: () -> [String]
    private let remoteDependencyRevision: (String) -> String
    private let remoteNames: () -> [String]?
    private let remoteURL: (String) -> String?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "RepositoryForge")

    @objc(initWithRepository:)
    convenience init(repository: PBGitRepository) {
        self.init(
            repository: repository,
            settings: ApplicationComposition.shared.repositoryViewState(for: repository)
        )
    }

    init(repository: PBGitRepository, settings: RepositoryUISettings) {
        self.repository = repository
        self.settings = settings
        remoteDescriptorCache = .shared
        remoteCacheKey = Self.remoteCacheKey(for: repository)
        remoteConfigurationRevision = { Self.remoteConfigurationRevision(for: repository) }
        remoteConfigurationDependencies = { Self.remoteConfigurationDependencies(for: repository) }
        remoteDependencyRevision = Self.configurationFileRevision
        remoteNames = { repository.remotes() }
        remoteURL = { name in Self.remoteURL(for: name, repository: repository) }
        super.init()
    }

    init(
        repository: PBGitRepository,
        settings: RepositoryUISettings,
        remoteDescriptorCache: RepositoryForgeRemoteDescriptorCache,
        remoteCacheKey: String,
        remoteConfigurationRevision: @escaping () -> String,
        remoteConfigurationDependencies: @escaping () -> [String] = { [] },
        remoteDependencyRevision: @escaping (String) -> String = { _ in "" },
        remoteNames: @escaping () -> [String]?,
        remoteURL: @escaping (String) -> String?
    ) {
        self.repository = repository
        self.settings = settings
        self.remoteDescriptorCache = remoteDescriptorCache
        self.remoteCacheKey = remoteCacheKey
        self.remoteConfigurationRevision = remoteConfigurationRevision
        self.remoteConfigurationDependencies = remoteConfigurationDependencies
        self.remoteDependencyRevision = remoteDependencyRevision
        self.remoteNames = remoteNames
        self.remoteURL = remoteURL
        super.init()
    }

    /// Reading a known preference must not repeat Git-directory discovery.
    var storedBinding: ForgeRepositoryBinding? {
        settings.passiveForgeBinding
    }

    @objc func resolveBinding() -> RepositoryForgeBindingResolution {
        resolveBinding(persistAutomaticBinding: true)
    }

    private var configurationPathCache: (inputs: [String: String], paths: [String])?
    private var queryRefreshPolicy = RepositoryForgeQueryRefreshPolicy()
    private var queryResolution: RepositoryForgeBindingResolution?
    private(set) var preparedBindingIsCurrent = false

    func prepareQueryBinding(selection: GitBinarySelection?) -> RepositoryForgeBindingResolution {
        let before = queryRevision(selection: selection)
        if !queryRefreshPolicy.needsPreparation(before), let queryResolution {
            preparedBindingIsCurrent = true
            return queryResolution
        }
        if let binding = before?.binding {
            // A stored binding needs no discovery or callback boundary. Resolve
            // from this delivery's captured bytes instead of rereading defaults.
            let resolution = RepositoryForgeBindingResolution(kind: .existing, binding: binding)
            preparedBindingIsCurrent = true
            queryResolution = resolution
            queryRefreshPolicy.didPrepare(before)
            logger.debug("Prepared stored Forge binding from the shared delivery snapshot")
            return resolution
        }
        let resolution = resolveBinding()
        let after = queryRevision(selection: selection, freshBinding: true)
        preparedBindingIsCurrent = resolution.binding == after?.binding
        if before?.binding != after?.binding {
            settings.invalidatePassiveForgeBinding()
        }
        let verifiable = before != nil && before == after && resolution.binding == after?.binding
        queryResolution = verifiable ? resolution : nil
        queryRefreshPolicy.didPrepare(verifiable ? after : nil)
        logger.debug("Prepared passive Forge metadata; verifiable=\(verifiable, privacy: .public)")
        return resolution
    }

    private func queryRevision(selection: GitBinarySelection?, freshBinding: Bool = false) -> RepositoryForgeQueryRevision? {
        let binding = freshBinding ? settings.forgeRepositoryBinding : settings.passiveForgeBinding
        if let binding {
            // An explicit binding resolves directly and is independent of Git
            // configuration. Revalidate the preference around publication.
            return RepositoryForgeQueryRevision(binding: binding, configuration: "", dependencies: [:], selection: selection)
        }
        let configuration = remoteConfigurationRevision()
        let cached = remoteDescriptorCache.dependencyRevisions(for: remoteCacheKey, revision: configuration, dependencyRevision: remoteDependencyRevision)
        guard cached != nil else { return nil }
        // Inferred bindings also depend on global Git configuration.
        let defaults = currentGlobalConfigurationPaths()
        var dependencies = cached ?? [:]
        for path in defaults {
            dependencies[path] = remoteDependencyRevision(path)
        }
        return RepositoryForgeQueryRevision(binding: binding, configuration: configuration, dependencies: dependencies, selection: selection)
    }

    /// Provider-neutral remote identities used by the repository source list.
    /// Remote names are presentation hints only; they never replace the stable
    /// Primary Forge Repository Binding.
    func sidebarCandidates() -> [ForgeRepositoryCandidate] {
        remoteCandidates().map(\.candidate)
    }

    private func resolveBinding(persistAutomaticBinding: Bool) -> RepositoryForgeBindingResolution {
        if let binding = settings.forgeRepositoryBinding {
            logger.debug(
                "Resolved existing Forge Repository Binding provider=\(binding.primaryRepository.forge.kind.rawValue, privacy: .public)"
            )
            return RepositoryForgeBindingResolution(kind: .existing, binding: binding)
        }

        let contexts = remoteCandidates()
        let selection = PrimaryForgeRepositorySelector.select(
            existingBinding: nil,
            candidates: contexts.map(\.candidate)
        )
        switch selection {
        case let .automatic(binding):
            if persistAutomaticBinding {
                settings.forgeRepositoryBinding = binding
                logger.info(
                    "Created automatic Forge Repository Binding provider=\(binding.primaryRepository.forge.kind.rawValue, privacy: .public)"
                )
            } else {
                logger.debug(
                    "Resolved transient Forge Repository for read-only scripting provider=\(binding.primaryRepository.forge.kind.rawValue, privacy: .public)"
                )
            }
            return RepositoryForgeBindingResolution(kind: .automatic, binding: binding)
        case let .requiresChoice(candidates):
            let choices = candidates.compactMap { candidate in
                contexts.first { $0.candidate == candidate }
            }
            logger.info("Forge Repository Binding requires explicit choice count=\(choices.count, privacy: .public)")
            return RepositoryForgeBindingResolution(kind: .requiresChoice, candidates: choices)
        case .unavailable:
            logger.info("No valid Forge Repository candidate is available")
            return RepositoryForgeBindingResolution(kind: .unavailable)
        case let .existing(binding):
            // No existing binding is supplied to the selector above.
            logger.error("Forge binding selector unexpectedly returned an existing binding")
            return RepositoryForgeBindingResolution(kind: .existing, binding: binding)
        }
    }

    @objc(selectCandidate:error:)
    func select(candidate: RepositoryForgeBindingCandidate) throws -> RepositoryForgeBindingResolution {
        let binding = try ForgeRepositoryBinding(
            localRemoteName: candidate.candidate.remoteName,
            primaryRepository: candidate.candidate.repository
        )
        settings.forgeRepositoryBinding = binding
        logger.info(
            "Saved explicit Forge Repository Binding provider=\(binding.primaryRepository.forge.kind.rawValue, privacy: .public)"
        )
        return RepositoryForgeBindingResolution(kind: .existing, binding: binding)
    }

    func resolve(_ request: RepositoryForgeDestinationRequest) -> RepositoryForgeDestinationResolution {
        resolve(request, persistAutomaticBinding: true)
    }

    private func resolve(
        _ request: RepositoryForgeDestinationRequest,
        persistAutomaticBinding: Bool
    ) -> RepositoryForgeDestinationResolution {
        let resolution = resolveBinding(persistAutomaticBinding: persistAutomaticBinding)
        if let binding = resolution.binding {
            do {
                return try .route(route(request, binding: binding))
            } catch {
                logger.info("Rejected invalid Forge destination request")
                return .failure(scriptingError(.invalidDestination))
            }
        }
        if resolution.kind == .requiresChoice {
            return .requiresBindingChoice(resolution.candidates)
        }
        return .failure(scriptingError(.noForgeRepository))
    }

    func resolveNumberReference(
        _ reference: String,
        availableKinds: Set<ForgeNumberedDestinationKind> = Set(ForgeNumberedDestinationKind.allCases)
    ) -> RepositoryForgeNumberResolution {
        let bindingResolution = resolveBinding()
        guard let binding = bindingResolution.binding else {
            if bindingResolution.kind == .requiresChoice {
                return .requiresBindingChoice(bindingResolution.candidates)
            }
            return .failure(scriptingError(.noForgeRepository))
        }
        let router = ForgeDestinationRouter()
        switch router.routeNumberReference(
            reference,
            boundRepository: binding.primaryRepository,
            availableKinds: availableKinds
        ) {
        case let .destination(destination):
            do {
                return try .route(router.route(destination))
            } catch {
                return .failure(scriptingError(.invalidDestination))
            }
        case let .requiresChoice(choices):
            return .requiresDestinationChoice(choices)
        case let .failure(error):
            let code: RepositoryForgeScriptingErrorCode = switch error {
            case .malformedNumberReference: .invalidDestination
            case .bindingRequired: .noForgeRepository
            case .noAvailableDestination: .noAvailableDestination
            }
            return .failure(scriptingError(code))
        }
    }

    func resolveForScripting(_ request: RepositoryForgeDestinationRequest) -> Result<URL, NSError> {
        switch resolve(request, persistAutomaticBinding: false) {
        case let .route(route):
            return .success(route.browserURL)
        case .requiresBindingChoice:
            return .failure(scriptingError(.ambiguousForgeRepository))
        case let .failure(error):
            return .failure(error)
        }
    }

    @objc(repositoryURLWithError:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func repositoryURL() throws -> URL {
        try scriptingURL(for: .repository)
    }

    @objc(branchURLForName:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func branchURL(name: String) throws -> URL {
        try scriptingURL(for: .branch(name))
    }

    @objc(commitURLForIdentifier:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func commitURL(identifier: String) throws -> URL {
        try scriptingURL(for: .commit(identifier))
    }

    @objc(fileURLForRevision:revisionKind:path:startLine:endLine:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func fileURL(
        revision: String,
        revisionKind: RepositoryForgeRevisionKind,
        path: String,
        startLine: NSNumber?,
        endLine: NSNumber?
    ) throws -> URL {
        try scriptingURL(for: .file(
            revision: revisionRequest(revision, kind: revisionKind),
            path: path,
            startLine: startLine?.intValue,
            endLine: endLine?.intValue
        ))
    }

    @objc(compareURLFromRevision:baseKind:toRevision:headKind:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func compareURL(
        base: String,
        baseKind: RepositoryForgeRevisionKind,
        head: String,
        headKind: RepositoryForgeRevisionKind
    ) throws -> URL {
        try scriptingURL(for: .compare(
            base: revisionRequest(base, kind: baseKind),
            head: revisionRequest(head, kind: headKind)
        ))
    }

    @objc(pullRequestURLForNumber:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func pullRequestURL(number: Int) throws -> URL {
        try scriptingURL(for: .pullRequest(number))
    }

    @objc(issueURLForNumber:error:)
    // Cocoa Scripting invokes this Objective-C facade dynamically.
    // swiftlint:disable:next unused_declaration
    func issueURL(number: Int) throws -> URL {
        try scriptingURL(for: .issue(number))
    }

    private func scriptingURL(for request: RepositoryForgeDestinationRequest) throws -> URL {
        switch resolveForScripting(request) {
        case let .success(url): url
        case let .failure(error): throw error
        }
    }

    private func remoteCandidates() -> [RepositoryForgeBindingCandidate] {
        let revision = remoteConfigurationRevision()
        let load = RepositoryForgeRemoteDescriptorLoader(cache: remoteDescriptorCache).load(
            cacheKey: remoteCacheKey,
            revision: revision,
            remoteNames: remoteNames,
            remoteURL: remoteURL,
            dependencyPaths: remoteConfigurationDependencies,
            dependencyRevision: remoteDependencyRevision
        )
        if load.reusedCache {
            logger.debug("Reused cached Forge remote descriptors count=\(load.descriptors.count, privacy: .public)")
        } else {
            logger.debug(
                "Loaded Forge remote descriptors count=\(load.descriptors.count, privacy: .public) cacheable=\(load.isCacheable, privacy: .public)"
            )
        }
        var candidates: [RepositoryForgeBindingCandidate] = []
        var rejectedCount = 0
        for descriptor in load.descriptors {
            guard let parsed = try? ForgeRemoteParser.parse(descriptor.url),
                  let candidate = try? ForgeRepositoryCandidate(
                      remoteName: descriptor.name,
                      repository: parsed.repository,
                      confidence: .high,
                      relationship: descriptor.name.caseInsensitiveCompare("upstream") == .orderedSame
                          ? .upstream
                          : .unknown
                  )
            else {
                rejectedCount += 1
                continue
            }
            candidates.append(RepositoryForgeBindingCandidate(
                candidate: candidate,
                originalRemoteURL: descriptor.url
            ))
        }
        logger.debug(
            "Parsed Forge remote candidates valid=\(candidates.count, privacy: .public) rejected=\(rejectedCount, privacy: .public)"
        )
        return candidates
    }

    private static func remoteURL(for name: String, repository: PBGitRepository) -> String? {
        let output = try? repository.outputOfTask(withArguments: ["remote", "get-url", name])
        let value = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func remoteCacheKey(for repository: PBGitRepository) -> String {
        if let gitURL = repository.gitURL() {
            return gitURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        if let workingDirectoryURL = repository.workingDirectoryURL() {
            return workingDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return "repository-object-\(ObjectIdentifier(repository))"
    }

    private static func remoteConfigurationRevision(for repository: PBGitRepository) -> String {
        guard let gitURL = repository.gitURL()?.standardizedFileURL else { return "missing-git-directory" }
        let commonDirectoryMarker = gitURL.appendingPathComponent("commondir", isDirectory: false)
        var configurationURLs = [
            gitURL.appendingPathComponent("config", isDirectory: false),
            gitURL.appendingPathComponent("config.worktree", isDirectory: false),
            commonDirectoryMarker,
            gitURL.appendingPathComponent("HEAD", isDirectory: false),
        ]
        if let rawCommonDirectory = try? String(contentsOf: commonDirectoryMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawCommonDirectory.isEmpty
        {
            let commonDirectory: URL = if NSString(string: rawCommonDirectory).isAbsolutePath {
                URL(fileURLWithPath: rawCommonDirectory, isDirectory: true)
            } else {
                gitURL.appendingPathComponent(rawCommonDirectory, isDirectory: true)
            }
            configurationURLs.append(commonDirectory.appendingPathComponent("config", isDirectory: false))
            configurationURLs.append(commonDirectory.appendingPathComponent("config.worktree", isDirectory: false))
            configurationURLs.append(commonDirectory.appendingPathComponent("HEAD", isDirectory: false))
        }

        return Set(configurationURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            .sorted()
            .map(configurationFileRevision)
            .joined(separator: "|")
    }

    private static func remoteConfigurationDependencies(for repository: PBGitRepository) -> [String] {
        var paths = globalConfigurationPaths()
        guard let output = try? repository.outputOfTask(
            withArguments: ["config", "--show-origin", "--null", "--list"]
        ) else { return paths }
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index + 1 < fields.count {
            let origin = fields[index]
            let setting = fields[index + 1]
            index += 2
            guard origin.hasPrefix("file:") else { continue }
            let originPath = String(origin.dropFirst("file:".count))
            paths.append(originPath)
            guard let newline = setting.firstIndex(of: "\n") else { continue }
            let name = setting[..<newline].lowercased()
            guard name == "include.path" || (name.hasPrefix("includeif.") && name.hasSuffix(".path")) else {
                continue
            }
            let rawPath = String(setting[setting.index(after: newline)...])
            guard !rawPath.isEmpty else { continue }
            let expandedPath = NSString(string: rawPath).expandingTildeInPath
            if NSString(string: expandedPath).isAbsolutePath {
                paths.append(expandedPath)
            } else {
                paths.append(
                    URL(fileURLWithPath: originPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent(expandedPath)
                        .standardizedFileURL.path
                )
            }
        }
        return Array(Set(paths)).sorted()
    }

    private func currentGlobalConfigurationPaths() -> [String] {
        // Cache path construction only, never filesystem evidence. Relevant
        // environment changes are observed again across discovery boundaries.
        let inputs = Self.configurationEnvironment()
        if let configurationPathCache, configurationPathCache.inputs == inputs {
            return configurationPathCache.paths
        }
        let paths = Self.globalConfigurationPaths(environment: inputs)
        configurationPathCache = (inputs, paths)
        return paths
    }

    private static func configurationEnvironment() -> [String: String] {
        let keys = ["GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME"]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = getenv(key) else { return nil }
            return (key, String(cString: value))
        })
    }

    static func globalConfigurationPaths(environment: [String: String] = configurationEnvironment(),
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String]
    {
        var paths: [String] = []
        if environment["GIT_CONFIG_NOSYSTEM"] != "1" {
            paths.append(environment["GIT_CONFIG_SYSTEM"] ?? "/etc/gitconfig")
        }
        if let global = environment["GIT_CONFIG_GLOBAL"] {
            paths.append(global)
        } else {
            paths.append(home.appendingPathComponent(".gitconfig").path)
            let xdg = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
            paths.append(xdg.appendingPathComponent("git/config").path)
        }
        return Array(Set(paths.filter { !$0.isEmpty })).sorted()
    }

    private static func configurationFileRevision(_ path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "\(path):missing"
        }
        let modificationBits = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(path):\(modificationBits):\(size):\(fileNumber)"
    }

    private func route(
        _ request: RepositoryForgeDestinationRequest,
        binding: ForgeRepositoryBinding
    ) throws -> ForgeDestinationRoute {
        let repository = binding.primaryRepository
        let destination: ForgeDestination = switch request {
        case .repository:
            .repository(repository)
        case let .branch(name):
            try .branch(repository, ForgeRefName(name))
        case let .commit(identifier):
            try .commit(repository, ForgeCommitID(identifier))
        case let .file(revision, path, startLine, endLine):
            try .file(
                repository,
                revision: forgeRevision(revision),
                path: ForgeFilePath(path),
                selection: lineSelection(start: startLine, end: endLine)
            )
        case let .compare(base, head):
            try .compare(
                repository,
                base: forgeRevision(base),
                head: forgeRevision(head)
            )
        case let .pullRequest(number):
            try .pullRequest(repository, ForgeItemNumber(number))
        case let .issue(number):
            try .issue(repository, ForgeItemNumber(number))
        }
        return try ForgeDestinationRouter().route(destination)
    }

    private func forgeRevision(_ request: RepositoryForgeRevisionRequest) throws -> ForgeRevision {
        switch request {
        case let .branch(value): try .branch(ForgeRefName(value))
        case let .tag(value): try .tag(ForgeRefName(value))
        case let .commit(value): try .commit(ForgeCommitID(value))
        }
    }

    private func revisionRequest(
        _ value: String,
        kind: RepositoryForgeRevisionKind
    ) -> RepositoryForgeRevisionRequest {
        switch kind {
        case .branch: .branch(value)
        case .tag: .tag(value)
        case .commit: .commit(value)
        }
    }

    private func lineSelection(start: Int?, end: Int?) throws -> ForgeLineSelection? {
        switch (start, end) {
        case (nil, nil): nil
        case let (start?, nil): try ForgeLineSelection(line: start)
        case let (start?, end?): try ForgeLineSelection(start: start, end: end)
        case (nil, _?): throw scriptingError(.invalidDestination)
        }
    }

    private func scriptingError(_ code: RepositoryForgeScriptingErrorCode) -> NSError {
        let description = switch code {
        case .noForgeRepository:
            "No Forge Repository can be resolved for this repository."
        case .ambiguousForgeRepository:
            "The repository has multiple possible Forge Repositories; choose a Primary Forge Repository first."
        case .invalidDestination:
            "The Forge destination parameters are invalid."
        case .ambiguousDestination:
            "The Forge destination is ambiguous."
        case .noAvailableDestination:
            "No matching Forge destination is available."
        }
        return NSError(
            domain: Self.scriptingErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
