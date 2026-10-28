import Foundation
import Synchronization

/// Shared parsing and diagnostics; no command execution or AppKit work.
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

    @objc static var failureDescription: String {
        NSLocalizedString("Unable to find git", comment: "")
    }

    @objc static func failureReason(_ paths: [String]) -> String {
        String(format: NSLocalizedString("Could not find a git binary version %@ or higher.\nPlease make sure there is a git binary in one of the following locations:\n\n\t%@", comment: "Git discovery failure"),
               PBGitMinimumVersion, paths.joined(separator: "\n\t"))
    }
}

nonisolated struct GitBinarySelection: Equatable, Sendable {
    let path: String
    let version: String
}

nonisolated enum GitBinaryDiscoveryOutcome: Sendable {
    case success(GitBinarySelection)
    case exhausted
    case timedOut
    case cancelled
}

/// The active selection outlives preference validation. Only successful validation replaces it.
@objc(PBGitBinaryDiscovery)
final nonisolated class GitBinaryDiscovery: NSObject, Sendable {
    typealias Completion = @MainActor @Sendable (String?, NSError?) -> Void
    typealias SelectionCompletion = @MainActor @Sendable (GitBinarySelection?, NSError?) -> Void
    typealias Output = @Sendable (String, [String]) -> String?

    private enum Candidate: Sendable {
        case executable(String)
        case lookup(String, [String])
        var path: String {
            switch self { case let .executable(path): GitOutputFormatting.normalizedExecutableCandidate(path); case let .lookup(path, _): path }
        }

        var arguments: [String] {
            switch self { case .executable: ["--version"]; case let .lookup(_, arguments): arguments }
        }
    }

    private struct Search {
        let generation: UInt
        let preference: String?
        let deadline: TimeInterval
        var candidates: [Candidate]
        var paths: [String] = []
        var rejected: String?
        var probeTimedOut = false
        var probeID: UUID?
        var probe: GitDiscoveryProbeRunner.Request?
    }

    private struct Waiter: Sendable {
        let id: UUID
        let deadline: TimeInterval
        let completion: SelectionCompletion
    }

    private struct Publication: Sendable {
        let generation: UInt
        let preference: String?
        let selection: GitBinarySelection?
        let rejected: String?
        let waiters: [Waiter]
        let error: NSError?
        let timeoutError: NSError
        let finishedAt: TimeInterval
        let probe: GitDiscoveryProbeRunner.Request?
    }

    private struct State {
        var generation: UInt = 0
        var started = false
        var preference: String?
        var selection: GitBinarySelection?
        var search: Search?
        var outcome: GitBinaryDiscoveryOutcome = .exhausted
        var attemptedPaths: [String] = []
        var waiters: [Waiter] = []
    }

    @objc static let shared: GitBinaryDiscovery = {
        let discovery = GitBinaryDiscovery(
            preference: { UserDefaults.standard.string(forKey: "gitExecutable") },
            environment: ProcessInfo.processInfo.environment,
            validationStarted: { GitBinaryDiscoveryPresenter.shared.invalidateWarning() },
            selectionDidChange: { GitBinaryDiscoveryPresenter.shared.publishSelection($0) },
            notify: { selection, rejected in GitBinaryDiscoveryPresenter.shared.publish(selection: selection, rejected: rejected) }
        )
        NotificationCenter.default.addObserver(discovery, selector: #selector(defaultsChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
        return discovery
    }()

    private let state = Mutex(State())
    private let preference: @Sendable () -> String?
    private let environment: [String: String]
    private let locations: [String]
    private let timing: GitDiscoveryTiming
    private let runner: GitDiscoveryProbeRunner
    private let notify: @MainActor @Sendable (GitBinarySelection?, String?) -> Void
    private let validationStarted: @MainActor @Sendable () -> Void
    private let selectionDidChange: @MainActor @Sendable (GitBinarySelection?) -> Void
    private let totalBudget: TimeInterval
    private let probeBudget: TimeInterval

    init(preference: @escaping @Sendable () -> String?, environment: [String: String],
         output: Output? = nil, locations: [String] = GitBinaryDiscoveryPolicy.searchLocations,
         timing: GitDiscoveryTiming = .live, totalBudget: TimeInterval = 30, probeBudget: TimeInterval = 5,
         runner: GitDiscoveryProbeRunner? = nil,
         validationStarted: @escaping @MainActor @Sendable () -> Void = {},
         selectionDidChange: @escaping @MainActor @Sendable (GitBinarySelection?) -> Void = { _ in },
         notify: @escaping @MainActor @Sendable (GitBinarySelection?, String?) -> Void = { _, _ in })
    {
        self.preference = preference
        self.environment = environment
        self.locations = locations
        self.timing = timing
        self.totalBudget = totalBudget
        self.probeBudget = probeBudget
        self.notify = notify
        self.validationStarted = validationStarted
        self.selectionDidChange = selectionDidChange
        if let runner {
            self.runner = runner
        } else if let output {
            self.runner = GitDiscoveryProbeRunner(timing: timing, factory: { path, arguments, _ in
                GitDiscoveryProbeRunner.Operation(output: { output(path, arguments) }, cancel: {})
            })
        } else {
            self.runner = GitDiscoveryProbeRunner(timing: timing)
        }
        super.init()
    }

    var currentSelection: GitBinarySelection? {
        state.withLock { $0.selection }
    }

    /// One ownership snapshot covers queued work, in-flight probes and the published selection.
    var referencedExecutablePaths: [String] {
        state.withLock { state in
            [state.selection?.path, state.search?.preference].compactMap { $0 }
                + (state.search?.paths ?? [])
                + (state.search?.candidates.map(\.path) ?? [])
        }
    }

    @objc var path: String? {
        currentSelection?.path
    }

    @objc var version: String? {
        currentSelection?.version
    }

    var isReady: Bool {
        currentSelection != nil
    }

    @objc private func defaultsChanged(_: Notification) {
        start()
    }

    @objc func start() {
        start(retryingFailure: false)
    }

    /// Explicit user opens can retry a failed cold discovery; background consumers cannot self-loop.
    func start(retryingFailure: Bool) {
        let requested = preference()
        let launch = state.withLock { state -> (UInt, GitDiscoveryProbeRunner.Request?)? in
            let retry = retryingFailure && state.search == nil && state.selection == nil
            guard !state.started || state.preference != requested || retry else { return nil }
            let previous = state.search?.probe
            state.generation &+= 1
            state.started = true
            state.preference = requested
            state.search = Search(generation: state.generation, preference: requested,
                                  deadline: timing.now() + totalBudget,
                                  candidates: candidates(preference: requested, hasSelection: state.selection != nil))
            return (state.generation, previous)
        }
        guard let (generation, previous) = launch else { return }
        previous?.cancel()
        DispatchQueue.main.async { [self] in
            if state.withLock({ $0.generation == generation }) {
                validationStarted()
            }
        }
        NSLog("[GitDiscovery] Starting validation generation %lu", generation)
        timing.schedule(totalBudget) { [self] in finish(.timedOut, generation: generation) }
        advance(generation)
    }

    @objc(whenAvailable:)
    func whenAvailable(_ completion: @escaping Completion) {
        whenSelectionAvailable { selection, error in completion(selection?.path, error) }
    }

    func whenSelectionAvailable(_ completion: @escaping SelectionCompletion) {
        start()
        let id = UUID()
        let ready = state.withLock { state -> (GitBinarySelection?, NSError?)? in
            if let selection = state.selection {
                return (selection, nil)
            }
            if state.search != nil {
                state.waiters.append(Waiter(id: id, deadline: timing.now() + totalBudget, completion: completion))
                return nil
            }
            return (nil, unavailableError(outcome: state.outcome, paths: state.attemptedPaths))
        }
        if let ready {
            DispatchQueue.main.async { completion(ready.0, ready.1) }
        } else {
            timing.schedule(totalBudget) { [self] in
                let expired = state.withLock { state -> Waiter? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiters.remove(at: index)
                }
                if let expired {
                    let error = unavailableError(outcome: .timedOut, paths: state.withLock { $0.search?.paths ?? $0.attemptedPaths })
                    DispatchQueue.main.async { expired.completion(nil, error) }
                }
            }
        }
    }

    private func candidates(preference requested: String?, hasSelection: Bool) -> [Candidate] {
        var result: [Candidate] = []
        if let requested, !requested.isEmpty {
            result.append(.executable(requested))
            if hasSelection {
                return result
            }
        }
        if let path = environment["GIT_PATH"] {
            result.append(.executable(path))
        }
        result.append(.lookup("/usr/bin/which", ["git"]))
        result += locations.map(Candidate.executable)
        result.append(.lookup("/usr/bin/xcrun", ["-f", "git"]))
        return result
    }

    private func advance(_ generation: UInt) {
        let currentPreference = preference()
        let next = state.withLock { state -> (Candidate, UUID, TimeInterval)? in
            guard var search = state.search, search.generation == generation, search.preference == currentPreference,
                  !search.candidates.isEmpty, timing.now() < search.deadline else { return nil }
            let candidate = search.candidates.removeFirst()
            let id = UUID()
            search.probeID = id
            search.probe = nil
            search.paths.append(candidate.path)
            state.search = search
            return (candidate, id, min(probeBudget, search.deadline - timing.now()))
        }
        guard let (candidate, id, budget) = next else {
            let timedOut = state.withLock { $0.search?.probeTimedOut == true }
            finish(timedOut ? .timedOut : .exhausted, generation: generation)
            return
        }
        let request = runner.run(path: candidate.path, arguments: candidate.arguments, timeout: budget) { [self] result in
            handle(result, candidate: candidate, generation: generation, probeID: id)
        }
        let accepted = state.withLock { state in
            guard state.search?.generation == generation, state.search?.probeID == id else { return false }
            state.search?.probe = request
            return true
        }
        if !accepted {
            request.cancel()
        }
    }

    private func handle(_ result: GitDiscoveryProbeResult, candidate: Candidate, generation: UInt, probeID: UUID) {
        guard state.withLock({ $0.search?.generation == generation && $0.search?.probeID == probeID }) else { return }
        if preference() != state.withLock({ $0.search?.preference }) {
            start(); return
        }
        if case .cancelled = result {
            NSLog("[GitDiscovery] Cancelled probe for %@", candidate.path)
            return
        }
        if case .timedOut = result {
            NSLog("[GitDiscovery] Probe timed out for %@", candidate.path)
            state.withLock { state in
                if state.search?.generation == generation {
                    state.search?.probeTimedOut = true
                }
            }
        }
        let output: String?
        if case let .output(value) = result {
            output = value
        } else {
            output = nil
        }
        switch candidate {
        case .lookup:
            if let output {
                let path = GitOutputFormatting.normalizedExecutableCandidate(output)
                if !path.isEmpty {
                    state.withLock { state in
                        if state.search?.generation == generation {
                            state.search?.candidates.insert(.executable(path), at: 0)
                        }
                    }
                }
            }
        case let .executable(path):
            if case .output = result, let selection = validatedSelection(path: path, output: output) {
                finish(.success(selection), generation: generation)
                return
            }
            state.withLock { state in
                if state.search?.generation == generation, state.search?.preference == path {
                    state.search?.rejected = path
                }
            }
        }
        advance(generation)
    }

    private func finish(_ outcome: GitBinaryDiscoveryOutcome, generation: UInt) {
        let requested = preference()
        let finishedAt = timing.now()
        let publication = state.withLock { state -> Publication? in
            guard let search = state.search, search.generation == generation, search.preference == requested else { return nil }
            var final = outcome
            if timing.now() >= search.deadline {
                final = .timedOut
            }
            let rejected: String?
            switch final {
            case let .success(selection):
                state.selection = selection
                rejected = search.rejected
            case .exhausted, .timedOut:
                rejected = search.preference.flatMap { $0.isEmpty ? nil : $0 } ?? (state.selection == nil ? nil : "")
            case .cancelled: return nil
            }
            state.outcome = final
            state.attemptedPaths = search.paths
            state.search = nil
            let waiters = state.waiters
            state.waiters.removeAll()
            return Publication(generation: generation, preference: requested, selection: state.selection, rejected: rejected, waiters: waiters,
                               error: state.selection == nil ? unavailableError(outcome: final, paths: search.paths) : nil,
                               timeoutError: unavailableError(outcome: .timedOut, paths: search.paths), finishedAt: finishedAt, probe: search.probe)
        }
        guard let publication else {
            if state.withLock({ $0.preference != requested }) {
                start()
            }
            return
        }
        deliver(publication)
    }

    private func deliver(_ publication: Publication) {
        publication.probe?.cancel()
        DispatchQueue.main.async { [self] in
            selectionDidChange(currentSelection)
            for waiter in publication.waiters {
                let expired = publication.finishedAt >= waiter.deadline
                waiter.completion(expired ? nil : publication.selection, expired ? publication.timeoutError : publication.error)
            }
            // Presentation is independent of readiness delivery and must never run a modal loop.
            if state.withLock({ $0.generation == publication.generation }), preference() == publication.preference {
                notify(publication.selection, publication.rejected)
            }
        }
    }

    private func validatedSelection(path: String, output: String?) -> GitBinarySelection? {
        guard let version = GitBinaryDiscoveryPolicy.extractGitVersion(output) else {
            NSLog("[GitDiscovery] Missing or malformed version for %@", path)
            return nil
        }
        guard version.compare(PBGitMinimumVersion, options: .numeric) != .orderedAscending else {
            NSLog("[GitDiscovery] %@ has only version %@; minimum is %@", path, version, PBGitMinimumVersion)
            return nil
        }
        return GitBinarySelection(path: GitOutputFormatting.normalizedExecutableCandidate(path), version: version)
    }

    @objc(versionForPath:)
    func version(forPath path: String?) -> String? {
        guard let path else { return nil }
        return GitBinaryDiscoveryPolicy.extractGitVersion(synchronousOutput(path: path))
    }

    private func synchronousOutput(path: String) -> String? {
        let result = Mutex<String?>(nil)
        let completed = DispatchSemaphore(value: 0)
        let request = runner.run(path: path, arguments: ["--version"], timeout: probeBudget) { response in
            if case let .output(output) = response {
                result.withLock { $0 = output }
            }
            completed.signal()
        }
        if completed.wait(timeout: .now() + probeBudget) == .timedOut {
            request.cancel(timedOut: true)
        }
        return result.withLock { $0 }
    }

    @objc(acceptBinary:)
    func accept(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let path = GitOutputFormatting.normalizedExecutableCandidate(candidate)
        guard !path.isEmpty, let selection = validatedSelection(path: path, output: synchronousOutput(path: path)) else { return false }
        let requested = preference()
        let finishedAt = timing.now()
        let publication = state.withLock { state -> Publication in
            let probe = state.search?.probe
            state.generation &+= 1
            state.started = true
            state.preference = requested
            state.selection = selection
            state.search = nil
            state.outcome = .success(selection)
            let waiters = state.waiters
            state.waiters.removeAll()
            return Publication(generation: state.generation, preference: requested, selection: selection, rejected: nil, waiters: waiters,
                               error: nil, timeoutError: unavailableError(outcome: .timedOut, paths: [selection.path]), finishedAt: finishedAt, probe: probe)
        }
        deliver(publication)
        return true
    }

    private func unavailableError(outcome: GitBinaryDiscoveryOutcome, paths: [String]) -> NSError {
        let timedOut: Bool
        if case .timedOut = outcome {
            timedOut = true
        } else {
            timedOut = false
        }
        return NSError(domain: "PBGitBinaryErrorDomain", code: timedOut ? 2 : 1, userInfo: [
            NSLocalizedDescriptionKey: GitBinaryDiscoveryPolicy.failureDescription,
            NSLocalizedFailureReasonErrorKey: (timedOut ? "Git executable validation timed out.\n" : "") + GitBinaryDiscoveryPolicy.failureReason(paths),
        ])
    }
}
