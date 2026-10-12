import Foundation
import GitXCore
import OSLog // swiftlint:disable:this unused_import

// These selectors are consumed through the repository's Objective-C facade.
// swiftlint:disable unused_declaration
@objc(PBGitWorktree)
final nonisolated class PBGitWorktree: NSObject {
    let value: GitWorktree
    @objc var path: String {
        value.path
    }

    @objc var HEAD: String? {
        value.head
    }

    @objc var branchRefName: String? {
        value.branchRefName
    }

    @objc var isCurrent: Bool {
        value.isCurrent
    }

    @objc var isMain: Bool {
        value.isMain
    }

    @objc var isBare: Bool {
        value.isBare
    }

    @objc var isDetached: Bool {
        value.isDetached
    }

    @objc var isLocked: Bool {
        value.isLocked
    }

    @objc var lockReason: String? {
        value.lockReason
    }

    @objc var isPrunable: Bool {
        value.isPrunable
    }

    @objc var prunableReason: String? {
        value.prunableReason
    }

    @objc var folderExists: Bool {
        value.folderExists
    }

    @objc var hasBrokenLink: Bool {
        value.hasBrokenLink
    }

    @objc var movedPath: String? {
        value.movedPath
    }

    @objc var linkStyle: Int {
        value.linkStyle.rawValue
    }

    let canonicalIdentity: Data

    var isUnavailable: Bool {
        value.isPrunable || value.hasBrokenLink || !value.folderExists
    }

    init(_ value: GitWorktree) {
        self.value = value
        canonicalIdentity = WorktreePaths.identity(value.path)
        super.init()
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? PBGitWorktree)?.value == value
    }

    override var hash: Int {
        value.identity.hashValue
    }
}

@objc(PBRepositoryWorktreeService)
final class PBRepositoryWorktreeService: NSObject {
    private weak var repository: PBGitRepository?
    private let makeTask: ([String]) -> PBTask
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PBGitWorktrees")
    private var state = WorktreeRefreshState()
    private var discovery: PBTask?
    private var versionTask: PBTask?
    private var executable = ""
    private var versionGeneration = 0
    private var snapshot: [GitWorktree] = []
    private var discoveryCompletions: [@MainActor @Sendable (Result<[GitWorktree], Error>) -> Void] = []
    private var mutationTask: PBTask?
    private var configuredPreference: String?
    private var started = false
    @objc private(set) dynamic var worktrees: [PBGitWorktree] = []
    @objc private(set) dynamic var gitVersion: String?
    @objc private(set) dynamic var isSupported = false
    @objc var explanation: String {
        "Worktrees require Git 2.48 or later. Selected Git: \(gitVersion ?? "unavailable or being checked"). Choose a newer executable in Git Preferences…"
    }

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        makeTask = { [weak repository] arguments in
            guard let repository, let gitDirectory = repository.gitURL()?.path else {
                return PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil)
            }
            return PBTask(launchPath: Self.selectedExecutable(), arguments: ["--git-dir=" + gitDirectory] + arguments, inDirectory: repository.workingDirectoryURL()?.path)
        }
        super.init()
    }

    @objc(initWithRepository:taskFactory:)
    init(repository: PBGitRepository, taskFactory: @escaping ([String]) -> PBTask) {
        self.repository = repository
        makeTask = taskFactory
        super.init()
    }

    @objc(start)
    nonisolated func start() {
        onMain { self.startOnMain() }
    }

    private func startOnMain() {
        guard !started, !state.isClosed else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(repositoryChanged(_:)), name: Notification.Name("PBGitRepositoryModifiedNotification"), object: repository)
        checkVersion()
    }

    @objc private nonisolated func preferencesChanged(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.executable != Self.selectedExecutable() || self.configuredPreference != UserDefaults.standard.string(forKey: "gitExecutable") else { return }
            self.checkVersion()
        }
    }

    @objc private nonisolated func repositoryChanged(_: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func checkVersion() {
        guard !state.isClosed else { return }
        versionGeneration += 1
        let generation = versionGeneration
        versionTask?.terminate()
        discovery?.terminate()
        discovery = nil
        state.invalidate()
        let cancelledCompletions = discoveryCompletions
        discoveryCompletions.removeAll()
        cancelledCompletions.forEach { $0(.failure(CancellationError())) }
        executable = Self.selectedExecutable()
        configuredPreference = UserDefaults.standard.string(forKey: "gitExecutable")
        setAvailability(version: nil, supported: false)
        guard !executable.isEmpty else { return }
        let task = makeTask(["--version"])
        task.timeout = 10
        versionTask = task
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees delivery on the main queue.
            MainActor.assumeIsolated {
                guard let self, generation == self.versionGeneration, !self.state.isClosed else { return }
                self.versionTask = nil
                let version = error == nil ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                self.setAvailability(version: version, supported: WorktreePolicy.supports(version: version))
                self.logger.info("Worktree Git capability checked: \(version ?? "unavailable", privacy: .public)")
                if self.isSupported {
                    self.refresh()
                }
            }
        }
    }

    private func setAvailability(version: String?, supported: Bool) {
        guard gitVersion != version || isSupported != supported else { return }
        repository?.willChangeValue(forKey: "worktreeFeatureAvailable")
        gitVersion = version
        isSupported = supported
        repository?.didChangeValue(forKey: "worktreeFeatureAvailable")
    }

    @objc(refresh)
    nonisolated func refresh() {
        onMain { self.refreshOnMain() }
    }

    private func refreshOnMain() {
        guard isSupported, let generation = state.request() else { return }
        beginDiscovery(generation: generation)
    }

    private func beginDiscovery(generation: UInt64) {
        let task = makeTask(["worktree", "list", "--porcelain", "-z"])
        task.separatesStandardError = true
        task.timeout = 10
        discovery = task
        let common = Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? "")
        let current = repository?.workingDirectoryURL()?.path ?? repository?.gitURL()?.path
        logger.debug("Discovering worktrees")
        task.perform(on: .global(qos: .utility), outputChunkHandler: nil) { [weak self] data, error in
            let result: Result<[GitWorktree], Error> = Result {
                if let error {
                    throw error
                }
                guard let data else { throw WorktreeParseError.malformedRecord }
                return try WorktreeLinkInspector.inspect(WorktreeParser.parse(data), commonDirectory: common, currentPath: current)
            }
            DispatchQueue.main.async { [weak self] in self?.complete(result, generation: generation) }
        }
    }

    private func complete(_ result: Result<[GitWorktree], Error>, generation: UInt64) {
        guard state.accepts(generation) else { logger.debug("Discarding stale worktree discovery"); return }
        discovery = nil
        switch result {
        case let .success(records):
            if snapshot != records {
                repository?.willChangeValue(forKey: "worktrees")
                snapshot = records
                worktrees = records.map(PBGitWorktree.init)
                repository?.didChangeValue(forKey: "worktrees")
                logger.info("Published \(records.count) worktrees")
            }
        case let .failure(error):
            let cause = (error as NSError).userInfo[PBTaskTerminationOutputKey] as? String ?? (error as NSError).localizedFailureReason ?? error.localizedDescription
            logger.error("Worktree discovery failed; retaining last snapshot: \(cause, privacy: .public)")
        }
        let completions = discoveryCompletions
        discoveryCompletions.removeAll()
        completions.forEach { $0(result) }
        if let next = state.complete(generation) {
            beginDiscovery(generation: next)
        }
    }

    @objc(cancel)
    nonisolated func cancel() {
        onMain { self.cancelOnMain() }
    }

    private func cancelOnMain() {
        state.close()
        versionGeneration += 1
        discovery?.terminate()
        versionTask?.terminate()
        discovery = nil
        versionTask = nil
        let completions = discoveryCompletions
        discoveryCompletions.removeAll()
        completions.forEach { $0(.failure(CancellationError())) }
        NotificationCenter.default.removeObserver(self)
        logger.debug("Cancelled worktree service")
    }

    @objc(worktreeForBranch:)
    func worktree(forBranch refName: String) -> PBGitWorktree? {
        guard isSupported, !state.isClosed else { return nil }
        let identity = Data(refName.utf8)
        return worktrees.first { !$0.isCurrent && $0.value.branchIdentity == identity }
    }

    @objc(addWorktreeAtPath:branch:createBranch:completion:)
    func addWorktree(path: String, branch: String, createBranch: Bool, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        perform(createBranch ? .addNew(path: path, branch: branch) : .addExisting(path: path, branch: branch), completion: completion)
    }

    @objc(removeWorktreeAtPath:force:completion:)
    func removeWorktree(path: String, force: Bool, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        perform(.remove(path: path, force: force), completion: completion)
    }

    @objc(lockWorktreeAtPath:reason:completion:)
    func lockWorktree(path: String, reason: String, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        perform(.lock(path: path, reason: reason), completion: completion)
    }

    @objc(unlockWorktreeAtPath:completion:)
    func unlockWorktree(path: String, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        perform(.unlock(path: path), completion: completion)
    }

    @objc(pruneWorktreesReportOnly:completion:)
    func pruneWorktrees(reportOnly: Bool, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        perform(reportOnly ? .pruneReport : .prune, completion: completion)
    }

    @objc(repairLinksWithRelativePaths:completion:)
    func repairLinks(relativePaths: Bool, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        repairLinks(style: relativePaths ? .relative : .absolute, completion: completion)
    }

    func perform(_ command: WorktreeCommand, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        guard isSupported, !state.isClosed else { completion(nil, failure(explanation)); return }
        let key = WorktreePaths.identity(Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? ""))
        WorktreeMutationGate.enqueue(key: key) { [weak self] finished in
            guard let self, !self.state.isClosed, self.isSupported else { completion(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); finished(); return }
            switch command {
            case .repairLinks, .repairMoved:
                guard !self.worktrees.contains(where: { $0.value.hasForeignLink }) else {
                    completion(nil, self.failure("A worktree links to another existing repository. Repair is stopped to preserve that repository's links."))
                    finished()
                    return
                }
            default: break
            }
            if command == .prune, self.worktrees.contains(where: { $0.movedPath != nil }) {
                completion(nil, self.failure("Repair the worktree links first: pruning would forget a worktree that moved with this repository."))
                finished()
                return
            }
            if case let .remove(path, _) = command,
               let tree = self.worktrees.first(where: { WorktreePaths.identity($0.path) == WorktreePaths.identity(path) }),
               !WorktreeEligibility(tree.value, supported: self.isSupported).canRemove
            {
                completion(nil, self.failure("The main, current, or locked worktree cannot be removed. Unlock a linked worktree first."))
                finished()
                return
            }
            let task = self.makeTask(command.arguments)
            task.additionalEnvironment = (task.additionalEnvironment ?? [:]).merging(["LC_ALL": "C"]) { _, value in value }
            task.timeout = 120
            self.mutationTask = task
            self.logger.info("Running worktree lifecycle command: \(command.arguments.first ?? "worktree", privacy: .public)")
            task.perform { [weak self] data, error in
                // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees delivery on the main queue.
                MainActor.assumeIsolated {
                    guard let self else { finished(); return }
                    let output = String(decoding: data ?? self.mutationTask?.standardOutputData ?? Data(), as: UTF8.self)
                    self.mutationTask = nil
                    if let error {
                        self.logger.error("Git refused worktree operation: \(output, privacy: .public)")
                        completion(nil, self.failure(output.isEmpty ? error.localizedDescription : output, underlying: error))
                        finished()
                    } else if command == .pruneReport {
                        completion(output, nil)
                        finished()
                    } else {
                        self.discoverAfterMutation { result in
                            switch result {
                            case .success: completion(output, nil)
                            case let .failure(error): completion(nil, self.failure("Git completed the operation, but worktree state could not be reread: \(error.localizedDescription)", underlying: error))
                            }
                            finished()
                        }
                    }
                }
            }
        }
    }

    @objc(repairWorktree:movedTo:completion:)
    func repair(worktree: PBGitWorktree, movedTo path: String, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        guard WorktreeLinkInspector.canRepair(worktree.value, at: path, commonDirectory: Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? "")) else {
            completion(failure("The selected folder does not have this worktree’s Git administrative link. Choose its moved folder; links to another repository are left untouched."))
            return
        }
        let identity = WorktreePaths.identity(path)
        guard !worktrees.contains(where: { $0.canonicalIdentity == identity && $0.canonicalIdentity != worktree.canonicalIdentity }) else {
            completion(failure("That folder is already another worktree of this repository. Choose the folder that was moved."))
            return
        }
        perform(.repairMoved(path: path)) { [weak self] _, error in
            guard let self else { return }
            if let error {
                completion(error); return
            }
            guard !self.worktrees.contains(where: { $0.canonicalIdentity == worktree.canonicalIdentity }) else {
                completion(self.failure("Git did not reconnect the worktree at \(worktree.path). The selected folder does not match it."))
                return
            }
            completion(nil)
        }
    }

    func repairLinks(style: WorktreeLinkStyle, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        perform(.repairLinks(style: style, movedPaths: worktrees.compactMap(\.movedPath))) { [weak self] _, error in
            guard let self else { return }
            if let error {
                completion(error); return
            }
            completion(self.worktrees.contains(where: \.hasBrokenLink) ? self.failure("Some worktree links remain broken after Git's repair. Locate their folders and try again.") : nil)
        }
    }

    private func discoverAfterMutation(completion: @escaping @MainActor @Sendable (Result<[GitWorktree], Error>) -> Void) {
        guard !state.isClosed else { completion(.failure(CancellationError())); return }
        guard isSupported else { completion(.failure(failure(explanation))); return }
        discovery?.terminate()
        discovery = nil
        state.invalidate()
        discoveryCompletions.append(completion)
        refresh()
    }

    private func failure(_ message: String, underlying: Error? = nil) -> NSError {
        RepositoryServiceError.make(description: "Worktree operation failed", failureReason: message, underlyingError: underlying)
    }

    private nonisolated func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            // swift6-safety-justification: The main-thread check proves this synchronous Objective-C callback is on AppKit’s executor.
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    private nonisolated static func selectedExecutable() -> String {
        if let configured = UserDefaults.standard.string(forKey: "gitExecutable"), !configured.isEmpty {
            return configured
        }
        return PBGitBinary.path() ?? ""
    }

    @objc(commonDirectoryForGitDirectory:)
    nonisolated static func commonDirectory(gitDirectory: String) -> String {
        guard var path = try? String(contentsOfFile: (gitDirectory as NSString).appendingPathComponent("commondir"), encoding: .utf8) else { return gitDirectory }
        if path.hasSuffix("\n") {
            path.removeLast()
        }
        guard !path.isEmpty else { return gitDirectory }
        return WorktreePaths.canonical((path as NSString).isAbsolutePath ? path : (gitDirectory as NSString).appendingPathComponent(path))
    }
}

/// Linked windows share one FIFO for lifecycle changes in their common Git
/// directory. Each checkout keeps its separate index writer.
private enum WorktreeMutationGate {
    typealias Job = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private static var jobs: [Data: [Job]] = [:]

    static func enqueue(key: Data, job: @escaping Job) {
        let idle = jobs[key] == nil
        jobs[key, default: []].append(job)
        if idle {
            start(key: key)
        }
    }

    private static func start(key: Data) {
        guard let job = jobs[key]?.first else { jobs[key] = nil; return }
        job {
            jobs[key]?.removeFirst()
            start(key: key)
        }
    }
}

// swiftlint:enable unused_declaration
