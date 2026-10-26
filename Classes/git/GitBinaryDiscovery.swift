import AppKit
import Foundation
import Synchronization

/// Shared parsing and search-location policy; no command execution or AppKit work.
@objc(PBGitBinaryDiscoveryPolicy)
final nonisolated class GitBinaryDiscoveryPolicy: NSObject {
    @objc(extractGitVersion:)
    static func extractGitVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value as NSString
        let range = text.range(of: "git version [0-9.]+", options: .regularExpression)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: NSRange(location: range.location + 12, length: range.length - 12))
    }

    @objc static let searchLocations = [
        "/opt/homebrew/bin/git", "/opt/local/bin/git", "/sw/bin/git", "/opt/git/bin/git",
        "/usr/local/bin/git", "/usr/local/git/bin/git", ("~/bin/git" as NSString).expandingTildeInPath,
        "/usr/bin/git",
    ]
}

nonisolated struct GitBinarySelection: Equatable, Sendable {
    let path: String
    let version: String
}

/// Every mutable field belongs to `state`; command execution happens outside its lock.
@objc(PBGitBinaryDiscovery)
final nonisolated class GitBinaryDiscovery: NSObject, Sendable {
    typealias Completion = @MainActor @Sendable (String?, NSError?) -> Void
    typealias Output = @Sendable (String, [String]) -> String?

    private struct State {
        var generation: UInt = 0
        var started = false
        var pending = false
        var preference: String?
        var selection: GitBinarySelection?
        var waiters: [Completion] = []
    }

    @objc static let shared: GitBinaryDiscovery = {
        let discovery = GitBinaryDiscovery(
            preference: { UserDefaults.standard.string(forKey: "gitExecutable") },
            environment: ProcessInfo.processInfo.environment,
            output: runCommand,
            notify: { selection, rejected in
                NotificationCenter.default.post(name: Notification.Name("PBGitBinaryDidChangeNotification"), object: nil)
                guard let rejected else { return }
                NSLog("[GitDiscovery] Rejected configured executable %@; selected %@", rejected, selection?.path ?? "unavailable")
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Invalid git path", comment: "Configured Git executable is invalid")
                alert.informativeText = String(format: NSLocalizedString("The configured Git executable “%@” could not be validated. %@", comment: "Git discovery fallback"), rejected,
                                               selection.map { "Using \($0.path) instead." } ?? "No usable Git executable was found.")
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.runModal()
            }
        )
        NotificationCenter.default.addObserver(discovery, selector: #selector(defaultsChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
        return discovery
    }()

    private let state = Mutex(State())
    private let preference: @Sendable () -> String?
    private let environment: [String: String]
    private let output: Output
    private let locations: [String]
    private let notify: @MainActor @Sendable (GitBinarySelection?, String?) -> Void

    init(preference: @escaping @Sendable () -> String?, environment: [String: String],
         output: @escaping Output, locations: [String] = GitBinaryDiscoveryPolicy.searchLocations,
         notify: @escaping @MainActor @Sendable (GitBinarySelection?, String?) -> Void = { _, _ in })
    {
        self.preference = preference
        self.environment = environment
        self.output = output
        self.locations = locations
        self.notify = notify
        super.init()
    }

    @objc var path: String? {
        state.withLock { $0.selection?.path }
    }

    @objc var version: String? {
        state.withLock { $0.selection?.version }
    }

    var isReady: Bool {
        let requested = preference()
        return state.withLock { $0.started && !$0.pending && $0.selection != nil && $0.preference == requested }
    }

    @objc private func defaultsChanged(_: Notification) {
        start()
    }

    @objc func start() {
        let requested = preference()
        let generation = state.withLock { state -> UInt? in
            guard !state.started || state.preference != requested else { return nil }
            state.started = true
            state.pending = true
            state.preference = requested
            state.generation &+= 1
            return state.generation
        }
        guard let generation else { return }
        NSLog("[GitDiscovery] Starting validation generation %lu", generation)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = search(preference: requested, generation: generation)
            let waiters = state.withLock { state -> [Completion]? in
                guard state.generation == generation else { return nil }
                state.selection = result.selection
                state.pending = false
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            guard let waiters else {
                NSLog("[GitDiscovery] Discarded stale validation generation %lu", generation)
                return
            }
            DispatchQueue.main.async { [self] in
                if isCurrent(generation, preference: requested) {
                    notify(result.selection, result.rejected)
                }
                for waiter in waiters {
                    deliver(waiter, generation: generation, preference: requested)
                }
            }
        }
    }

    @objc(whenAvailable:)
    func whenAvailable(_ completion: @escaping Completion) {
        start()
        let ready = state.withLock { state -> (UInt, String?)? in
            if state.pending {
                state.waiters.append(completion)
                return nil
            }
            return (state.generation, state.preference)
        }
        if let ready {
            DispatchQueue.main.async { [self] in deliver(completion, generation: ready.0, preference: ready.1) }
        }
    }

    @MainActor private func deliver(_ completion: @escaping Completion, generation: UInt, preference requested: String?) {
        guard isCurrent(generation, preference: requested) else {
            whenAvailable(completion)
            return
        }
        let selected = path
        completion(selected, selected == nil ? Self.unavailableError() : nil)
    }

    private func isCurrent(_ generation: UInt, preference requested: String?) -> Bool {
        state.withLock { $0.generation == generation } && preference() == requested
    }

    private func search(preference requested: String?, generation: UInt) -> (selection: GitBinarySelection?, rejected: String?) {
        var rejected: String?
        if let requested, !requested.isEmpty {
            if let selection = selection(for: requested) {
                return (selection, nil)
            }
            rejected = requested
        }
        if let candidate = environment["GIT_PATH"], isCurrent(generation, preference: requested),
           let selection = selection(for: candidate)
        {
            return (selection, rejected)
        }
        guard isCurrent(generation, preference: requested) else { return (nil, rejected) }
        if let candidate = output("/usr/bin/which", ["git"]), let selection = selection(for: candidate) {
            return (selection, rejected)
        }
        for candidate in locations {
            guard isCurrent(generation, preference: requested) else { return (nil, rejected) }
            if let selection = selection(for: candidate) {
                return (selection, rejected)
            }
        }
        guard isCurrent(generation, preference: requested) else { return (nil, rejected) }
        if let candidate = output("/usr/bin/xcrun", ["-f", "git"]), let selection = selection(for: candidate) {
            return (selection, rejected)
        }
        NSLog("[GitDiscovery] No usable executable found")
        return (nil, rejected)
    }

    private func selection(for candidate: String) -> GitBinarySelection? {
        let candidate = GitOutputFormatting.normalizedExecutableCandidate(candidate)
        guard !candidate.isEmpty, let version = version(forPath: candidate),
              version.compare("1.6.0", options: .numeric) != .orderedAscending else { return nil }
        return GitBinarySelection(path: candidate, version: version)
    }

    @objc(versionForPath:)
    func version(forPath path: String?) -> String? {
        guard let path else { return nil }
        return GitBinaryDiscoveryPolicy.extractGitVersion(output(path, ["--version"]))
    }

    /// Compatibility for existing callers that explicitly select a validated executable.
    @objc(acceptBinary:)
    func accept(_ candidate: String?) -> Bool {
        guard let candidate, let selection = selection(for: candidate) else { return false }
        let requested = preference()
        let publication = state.withLock { state -> (UInt, [Completion]) in
            state.generation &+= 1
            state.started = true
            state.pending = false
            state.preference = requested
            state.selection = selection
            let waiters = state.waiters
            state.waiters.removeAll()
            return (state.generation, waiters)
        }
        DispatchQueue.main.async { [self] in
            for waiter in publication.1 {
                deliver(waiter, generation: publication.0, preference: requested)
            }
        }
        return true
    }

    private static func runCommand(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let task = PBTask(launchPath: path, arguments: arguments, inDirectory: nil)
        do {
            try task.launch()
            return task.standardOutputString()
        } catch {
            NSLog("[GitDiscovery] Probe failed for %@: %@", path, String(describing: error))
            return nil
        }
    }

    private static func unavailableError() -> NSError {
        NSError(domain: "PBGitBinaryErrorDomain", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString("Unable to find git", comment: ""),
            NSLocalizedFailureReasonErrorKey: NSLocalizedString("No usable Git executable was found in the configured or default search paths.", comment: ""),
        ])
    }
}
