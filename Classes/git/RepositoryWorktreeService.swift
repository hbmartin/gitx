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

private nonisolated struct WorktreeOperationContext: Equatable, Sendable {
    let commonDirectory: String
    let commonIdentity: WorktreeFileIdentity
    let gitDirectory: String
    let gitIdentity: WorktreeFileIdentity
    let executable: String
    let executableIdentity: WorktreeFileIdentity
    let workingDirectory: String?
    let generation: Int
}

/// Consent binds the raw Git response to the repository and complete registration inventory.
/// Display text is never parsed to authorize a mutation.
@objc(PBWorktreePrunePreview)
final nonisolated class PBWorktreePrunePreview: NSObject {
    @objc let report: String
    @objc let hasMovedWorktrees: Bool
    let rawReport: Data
    fileprivate let identifier = UUID()
    fileprivate let context: WorktreeOperationContext
    fileprivate let fingerprint: WorktreeAdministrativeFingerprint
    fileprivate let records: [GitWorktree]

    fileprivate init(report: String, rawReport: Data, context: WorktreeOperationContext, fingerprint: WorktreeAdministrativeFingerprint, records: [GitWorktree]) {
        self.report = report
        self.rawReport = rawReport
        self.context = context
        self.fingerprint = fingerprint
        self.records = records
        hasMovedWorktrees = records.contains { $0.movedPath != nil }
        super.init()
    }

    fileprivate func matches(_ other: PBWorktreePrunePreview) -> Bool {
        rawReport == other.rawReport && context == other.context && fingerprint == other.fingerprint && records == other.records
    }
}

private nonisolated struct WorktreeAbsentLocation: Sendable {
    let path: String
    let identity: Data
}

/// Completion and cancellation may converge through a terminated task and a discovery callback.
/// This owns one FIFO admission and delivers its result once, even after late task callbacks.
private final class WorktreeOperation {
    private let release: @MainActor @Sendable () -> Void
    private(set) var isActive = true
    private(set) var cancellationRequested = false
    var writerPending = false
    var cancellation: (() -> Void)?

    init(release: @escaping @MainActor @Sendable () -> Void) {
        self.release = release
    }

    func complete(_ deliver: () -> Void) {
        guard isActive else { return }
        isActive = false
        cancellation = nil
        deliver()
        release()
    }

    func cancel() {
        guard isActive, !cancellationRequested else { return }
        cancellationRequested = true
        cancellation?()
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
    private var checkedExecutableIdentity: WorktreeFileIdentity?
    private var versionGeneration = 0
    private var snapshot: [GitWorktree] = []
    private var discoveryCompletions: [@MainActor @Sendable (Result<[GitWorktree], Error>) -> Void] = []
    private var mutationTask: PBTask?
    private var activeOperation: WorktreeOperation?
    private var prunePreviews: Set<UUID> = []
    private var legacyPrunePreview: PBWorktreePrunePreview?
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
        setAvailability(version: nil, supported: false)
        prunePreviews.removeAll()
        legacyPrunePreview = nil
        checkedExecutableIdentity = nil
        let generation = versionGeneration
        versionTask?.terminate()
        discovery?.terminate()
        discovery = nil
        state.invalidate()
        let cancelledCompletions = discoveryCompletions
        discoveryCompletions.removeAll()
        cancelledCompletions.forEach { $0(.failure(CancellationError())) }
        activeOperation?.cancel()
        executable = Self.selectedExecutable()
        configuredPreference = UserDefaults.standard.string(forKey: "gitExecutable")
        setAvailability(version: nil, supported: false)
        guard !executable.isEmpty else { return }
        let checkingExecutableIdentity = try? WorktreeFileIdentity.capture(path: executable)
        let task = makeTask(["--version"])
        task.timeout = 10
        versionTask = task
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees delivery on the main queue.
            MainActor.assumeIsolated {
                guard let self, generation == self.versionGeneration, !self.state.isClosed else { return }
                self.versionTask = nil
                let version = error == nil ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                let currentExecutableIdentity = try? WorktreeFileIdentity.capture(path: self.executable)
                let executableIsStable = checkingExecutableIdentity != nil && checkingExecutableIdentity?.kind == .regularFile && currentExecutableIdentity == checkingExecutableIdentity
                self.checkedExecutableIdentity = executableIsStable ? checkingExecutableIdentity : nil
                self.setAvailability(version: version, supported: executableIsStable && WorktreePolicy.supports(version: version))
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
        let checked: Result<[GitWorktree], Error>
        if case .success = result, discovery?.standardOutputTruncated != false || discovery?.standardErrorTruncated != false {
            checked = .failure(WorktreeParseError.malformedRecord)
        } else {
            checked = result
        }
        discovery = nil
        switch checked {
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
        completions.forEach { $0(checked) }
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
        prunePreviews.removeAll()
        legacyPrunePreview = nil
        versionGeneration += 1
        discovery?.terminate()
        versionTask?.terminate()
        discovery = nil
        versionTask = nil
        let completions = discoveryCompletions
        discoveryCompletions.removeAll()
        completions.forEach { $0(.failure(CancellationError())) }
        activeOperation?.cancel()
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
        if reportOnly {
            if let legacyPrunePreview {
                discardPrunePreview(legacyPrunePreview)
            }
            legacyPrunePreview = nil
            preparePrunePreview { [weak self] preview, error in
                self?.legacyPrunePreview = preview
                completion(preview?.report, error)
            }
        } else {
            guard let preview = legacyPrunePreview else {
                completion(nil, failure("Preview the worktrees before confirming Prune.")); return
            }
            legacyPrunePreview = nil
            prune(confirmedPreview: preview) { [weak self] updated, error in
                if let updated {
                    self?.discardPrunePreview(updated)
                    completion(nil, self?.failure("Worktree ownership or prune candidates changed. Preview them again before confirming Prune.") ?? Self.cancelledError())
                } else {
                    completion(nil, error)
                }
            }
        }
    }

    @objc(preparePrunePreviewWithCompletion:)
    func preparePrunePreview(completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void) {
        enqueueOperation(onFailure: { completion(nil, $0) }) { [weak self] operation in
            guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
            self.capturePrunePreview(operation: operation) { [weak self] result in
                guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
                operation.complete {
                    switch result {
                    case let .success(preview): self.prunePreviews.insert(preview.identifier); completion(preview, nil)
                    case let .failure(error): completion(nil, self.operationError(error))
                    }
                }
            }
        }
    }

    @objc(discardPrunePreview:)
    func discardPrunePreview(_ preview: PBWorktreePrunePreview) {
        prunePreviews.remove(preview.identifier)
        if legacyPrunePreview === preview {
            legacyPrunePreview = nil
        }
    }

    @objc(pruneWithConfirmedPreview:completion:)
    func prune(confirmedPreview preview: PBWorktreePrunePreview, completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void) {
        guard prunePreviews.remove(preview.identifier) != nil else {
            completion(nil, failure("This prune preview was cancelled, consumed, or belongs to another repository. Preview it again.")); return
        }
        enqueueOperation(onFailure: { completion(nil, $0) }) { [weak self] operation in
            guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
            do { try self.validateContext(preview.context) } catch {
                operation.complete { completion(nil, self.failure("The repository or selected Git changed. Preview the worktrees again.", underlying: error)) }; return
            }
            self.capturePrunePreview(operation: operation) { [weak self] result in
                guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
                switch result {
                case let .failure(error): operation.complete { completion(nil, self.operationError(error)) }
                case let .success(current):
                    guard current.matches(preview), !current.hasMovedWorktrees, !current.rawReport.isEmpty else {
                        self.logger.info("Prune consent rejected: registration evidence or candidates changed, or repair is needed")
                        operation.complete { self.prunePreviews.insert(current.identifier); completion(current, nil) }
                        return
                    }
                    // The final evidence read and launch share this admission. No UI callback or re-enqueue occurs between them.
                    self.executeTask(.prune, operation: operation) { [weak self] result in
                        guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
                        switch result {
                        case let .failure(error): operation.complete { completion(nil, self.operationError(error)) }
                        case .success:
                            self.discoverAfterMutation { result in
                                operation.complete {
                                    switch result {
                                    case .success: completion(nil, nil)
                                    case let .failure(error): completion(nil, self.failure("Git completed prune, but worktree state could not be reread: \(error.localizedDescription)", underlying: error))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func capturePrunePreview(operation: WorktreeOperation, completion: @escaping @MainActor @Sendable (Result<PBWorktreePrunePreview, Error>) -> Void) {
        let context: WorktreeOperationContext
        let fingerprint: WorktreeAdministrativeFingerprint
        do {
            context = try captureContext()
            fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)
        } catch { completion(.failure(error)); return }
        discoverAfterMutation { [weak self] result in
            guard operation.isActive else { return }
            guard let self else { completion(.failure(CancellationError())); return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(records):
                do { try self.validateContext(context) } catch { completion(.failure(error)); return }
                self.executeTask(.pruneReport, operation: operation) { [weak self] result in
                    guard let self else { completion(.failure(CancellationError())); return }
                    completion(Result {
                        let bytes = try result.get()
                        guard let text = String(data: bytes, encoding: .utf8) else { throw self.failure("Git's prune report could not be read completely.") }
                        let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: context.commonDirectory, currentPath: context.workingDirectory)
                        try self.validateContext(context)
                        guard try fingerprint == (WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)), records == inspected else {
                            throw self.failure("Worktree ownership changed while the preview was being collected. Preview it again.")
                        }
                        return PBWorktreePrunePreview(report: text, rawReport: bytes, context: context, fingerprint: fingerprint, records: inspected)
                    })
                }
            }
        }
    }

    @objc(repairLinksWithRelativePaths:completion:)
    func repairLinks(relativePaths: Bool, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        repairLinks(style: relativePaths ? .relative : .absolute, completion: completion)
    }

    func perform(_ command: WorktreeCommand, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        switch command {
        case .pruneReport: pruneWorktrees(reportOnly: true, completion: completion); return
        case .prune, .repairLinks, .repairMoved:
            completion(nil, failure("This operation requires a captured prune preview or repair ownership target.")); return
        default: break
        }
        enqueueOperation(onFailure: { completion(nil, $0) }) { [weak self] operation in
            guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
            if case let .remove(path, _) = command,
               let tree = self.worktrees.first(where: { WorktreePaths.identity($0.path) == WorktreePaths.identity(path) }),
               !WorktreeEligibility(tree.value, supported: self.isSupported).canRemove
            {
                operation.complete { completion(nil, self.failure("The main, current, or locked worktree cannot be removed. Unlock a linked worktree first.")) }; return
            }
            self.executeTask(command, operation: operation) { [weak self] result in
                guard let self else { operation.complete { completion(nil, Self.cancelledError()) }; return }
                switch result {
                case let .failure(error): operation.complete { completion(nil, self.operationError(error)) }
                case let .success(data):
                    self.discoverAfterMutation { result in
                        operation.complete {
                            switch result {
                            case .success: completion(String(decoding: data, as: UTF8.self), nil)
                            case let .failure(error): completion(nil, self.failure("Git completed the operation, but worktree state could not be reread: \(error.localizedDescription)", underlying: error))
                            }
                        }
                    }
                }
            }
        }
    }

    @objc(repairWorktree:movedTo:completion:)
    func repair(worktree: PBGitWorktree, movedTo path: String, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        do {
            let context = try captureContext()
            let target = try WorktreeLinkInspector.captureRepairTarget(worktree.value, at: path, commonDirectory: context.commonDirectory, mainPath: worktrees.first(where: \.isMain)?.path)
            let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)
            let identity = WorktreePaths.identity(path)
            guard !worktrees.contains(where: { $0.canonicalIdentity == identity && $0.canonicalIdentity != worktree.canonicalIdentity }) else {
                throw failure("That folder is already another worktree of this repository. Choose the folder belonging to this registration.")
            }
            let scope = try captureRepairTargets(context: context, fingerprint: fingerprint, selected: target)
            let command: WorktreeCommand
            if WorktreePaths.identity(target.originalPath) == WorktreePaths.identity(target.path) {
                let style = WorktreePolicy.preferredRepairStyle(worktrees.map { $0.value.linkStyle })
                command = .repairLinks(style: style, movedPaths: mainRepairPaths())
            } else {
                command = .repairMoved(path: target.path)
            }
            repair(command: command, targets: scope.targets, absentLocations: scope.absentLocations, fingerprint: fingerprint, context: context, style: nil, completion: completion)
        } catch {
            logger.error("Repair ownership rejected before admission: \(error.localizedDescription, privacy: .public)")
            completion(failure("The selected folder cannot be proven to belong to this registration. Foreign or ambiguous links are preserved.", underlying: error))
        }
    }

    func repairLinks(style: WorktreeLinkStyle, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        do {
            let context = try captureContext()
            let fingerprint = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)
            let scope = try captureRepairTargets(context: context, fingerprint: fingerprint)
            // Git receives the checkout paths whose identities were captured,
            // rather than aliases that can resolve elsewhere while queued.
            let paths = mainRepairPaths() + scope.targets.filter { !$0.originalPath.utf8.elementsEqual($0.path.utf8) }.map(\.path)
            repair(command: .repairLinks(style: style, movedPaths: paths), targets: scope.targets, absentLocations: scope.absentLocations, fingerprint: fingerprint, context: context, style: style, completion: completion)
        } catch {
            logger.error("Repository repair ownership rejected: \(error.localizedDescription, privacy: .public)")
            completion(failure("Worktree registrations or links cannot be safely attributed to this repository. Repair is stopped to preserve their ownership.", underlying: error))
        }
    }

    private func mainRepairPaths() -> [String] {
        worktrees.first(where: \.isMain).map { [WorktreePaths.canonical($0.path)] } ?? []
    }

    /// Git also repairs every registered checkout when Locate supplies an explicit path.
    private func captureRepairTargets(context: WorktreeOperationContext, fingerprint: WorktreeAdministrativeFingerprint, selected: WorktreeRepairTarget? = nil) throws -> (targets: [WorktreeRepairTarget], absentLocations: [WorktreeAbsentLocation]) {
        let linked = worktrees.map(\.value).filter { !$0.isMain && !$0.isBare }
        guard linked.count == fingerprint.registrationCount, fingerprint.matchesRegistrationPaths(records: linked) else { throw failure("Some administrative registrations cannot be identified. Refresh the repository before repair.") }
        if let selected {
            guard linked.contains(where: { WorktreePaths.identity($0.path) == WorktreePaths.identity(selected.originalPath) }) else { throw failure("The selected worktree is no longer represented by this repository snapshot.") }
        }
        var absentLocations: [WorktreeAbsentLocation] = []
        let targets = try linked.compactMap { tree -> WorktreeRepairTarget? in
            if let selected, WorktreePaths.identity(tree.path) == WorktreePaths.identity(selected.originalPath) {
                return selected
            }
            guard tree.folderExists || tree.movedPath != nil else {
                guard !FileManager.default.fileExists(atPath: tree.path) else { throw failure("An unavailable worktree reappeared before repair could capture its ownership.") }
                absentLocations.append(WorktreeAbsentLocation(path: tree.path, identity: WorktreePaths.identity(tree.path)))
                return nil
            }
            return try WorktreeLinkInspector.captureRepairTarget(tree, at: tree.movedPath ?? tree.path, commonDirectory: context.commonDirectory, mainPath: worktrees.first(where: \.isMain)?.path)
        }
        return (targets, absentLocations)
    }

    private func repair(command: WorktreeCommand, targets: [WorktreeRepairTarget], absentLocations: [WorktreeAbsentLocation], fingerprint: WorktreeAdministrativeFingerprint, context: WorktreeOperationContext, style: WorktreeLinkStyle?, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        enqueueOperation(onFailure: completion) { [weak self] operation in
            guard let self else { operation.complete { completion(Self.cancelledError()) }; return }
            do {
                try self.validateContext(context)
                guard try fingerprint == (WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)) else { throw self.failure("Administrative ownership changed while repair was queued.") }
                for location in absentLocations {
                    guard WorktreePaths.identity(location.path) == location.identity, !FileManager.default.fileExists(atPath: location.path) else { throw self.failure("A previously unavailable registration now points to an uncaptured folder.") }
                }
                for target in targets {
                    try WorktreeLinkInspector.validateRepairTarget(target, commonDirectory: context.commonDirectory)
                }
            } catch {
                self.logger.error("Queued repair ownership rejected: \(error.localizedDescription, privacy: .public)")
                operation.complete { completion(self.failure("The queued repair no longer owns the captured folders or registrations. Their links were left untouched.", underlying: error)) }; return
            }
            self.executeTask(command, operation: operation) { [weak self] result in
                guard let self else { operation.complete { completion(Self.cancelledError()) }; return }
                switch result {
                case let .failure(error): operation.complete { completion(self.operationError(error)) }
                case .success:
                    self.discoverAfterMutation { result in
                        let checked = Result<Void, Error> {
                            let records = try result.get()
                            try self.validateContext(context)
                            guard try fingerprint.hasSameRegistrations(as: WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)) else { throw self.failure("Git did not preserve the captured administrative registrations.") }
                            for target in targets {
                                try WorktreeLinkInspector.verifyRepairTarget(target, records: records, commonDirectory: context.commonDirectory, style: style)
                            }
                        }
                        operation.complete {
                            switch checked {
                            case .success: completion(nil)
                            case let .failure(error):
                                self.logger.error("Repair postcondition failed: \(error.localizedDescription, privacy: .public)")
                                completion(self.failure("Git completed repair, but the captured registration and checkout do not have exact bidirectional links: \(error.localizedDescription)", underlying: error))
                            }
                        }
                    }
                }
            }
        }
    }

    private func enqueueOperation(onFailure: @escaping @MainActor @Sendable (NSError) -> Void, body: @escaping @MainActor (WorktreeOperation) -> Void) {
        guard isSupported, !state.isClosed else { onFailure(failure(explanation)); return }
        let key = WorktreePaths.identity(Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? ""))
        WorktreeMutationGate.enqueue(key: key) { [weak self] finished in
            let operation = WorktreeOperation(release: finished)
            guard let self, !self.state.isClosed, self.isSupported else { operation.complete { onFailure(Self.cancelledError()) }; return }
            self.activeOperation = operation
            operation.cancellation = { [weak self, weak operation] in
                self?.mutationTask?.terminate()
                // SIGTERM is a request. A live writer retains admission until its terminal callback.
                guard operation?.writerPending != true else { return }
                self?.mutationTask = nil
                operation?.complete { onFailure(Self.cancelledError()) }
            }
            body(operation)
        }
    }

    /// Runs a checked command within an existing FIFO admission; never recursively enqueues.
    private func executeTask(_ command: WorktreeCommand, operation: WorktreeOperation, completion: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void) {
        guard operation.isActive else { return }
        guard !state.isClosed, isSupported else { completion(.failure(CancellationError())); return }
        let task = makeTask(command.arguments)
        task.additionalEnvironment = (task.additionalEnvironment ?? [:]).merging(["LC_ALL": "C"]) { _, value in value }
        task.timeout = 120
        mutationTask = task
        operation.writerPending = command != .pruneReport
        logger.info("Running worktree lifecycle command: \(command.arguments.joined(separator: " "), privacy: .public)")
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees delivery on the main queue.
            MainActor.assumeIsolated {
                guard operation.isActive else { return }
                guard let self else { completion(.failure(CancellationError())); return }
                let ownedTask = self.mutationTask
                self.mutationTask = nil
                operation.writerPending = false
                if operation.cancellationRequested {
                    completion(.failure(Self.cancelledError()))
                } else if let error {
                    let output = String(decoding: data ?? ownedTask?.standardOutputData ?? Data(), as: UTF8.self)
                    self.logger.error("Git refused worktree operation: \(output, privacy: .public)")
                    completion(.failure(self.failure(output.isEmpty ? error.localizedDescription : output, underlying: error)))
                } else if let data, ownedTask?.standardOutputTruncated == false, ownedTask?.standardErrorTruncated == false {
                    completion(.success(data))
                } else {
                    completion(.failure(self.failure("Git's worktree response could not be read completely.")))
                }
            }
        }
    }

    private func captureContext() throws -> WorktreeOperationContext {
        guard isSupported, !state.isClosed, let gitDirectory = repository?.gitURL()?.path, !executable.isEmpty, executable == Self.selectedExecutable() else { throw failure("The repository or selected Git is unavailable or changed.") }
        let common = Self.commonDirectory(gitDirectory: gitDirectory)
        let commonIdentity = try WorktreeFileIdentity.capture(path: common)
        let gitIdentity = try WorktreeFileIdentity.capture(path: gitDirectory)
        let executableIdentity = try WorktreeFileIdentity.capture(path: executable)
        guard executableIdentity == checkedExecutableIdentity else { throw failure("The selected Git executable changed after its capability check. Select and validate Git again.") }
        guard commonIdentity.kind == .directory, gitIdentity.kind == .directory, executableIdentity.kind == .regularFile else { throw failure("The repository or selected Git is not a supported filesystem object.") }
        return WorktreeOperationContext(commonDirectory: common, commonIdentity: commonIdentity, gitDirectory: gitDirectory, gitIdentity: gitIdentity, executable: executable, executableIdentity: executableIdentity, workingDirectory: repository?.workingDirectoryURL()?.path, generation: versionGeneration)
    }

    private func validateContext(_ context: WorktreeOperationContext) throws {
        guard try context == captureContext() else { throw failure("The captured repository or Git executable was replaced or changed.") }
    }

    private nonisolated static func cancelledError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
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

    private func operationError(_ error: Error) -> NSError {
        let value = error as NSError
        return value.domain == PBGitXErrorDomain || (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError) ? value : failure(value.localizedFailureReason ?? value.localizedDescription, underlying: value)
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
