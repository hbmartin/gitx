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

    @objc var headRefName: String? {
        value.headRefName
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
    let executable: WorktreeFileFingerprint
    let workingDirectory: String?
    let workingIdentity: WorktreeFileIdentity?
    let generation: Int

    var inspectionLocation: String {
        workingDirectory ?? gitDirectory
    }

    func validate() throws {
        guard try WorktreeFileIdentity.capture(path: commonDirectory) == commonIdentity,
              try WorktreeFileIdentity.capture(path: gitDirectory) == gitIdentity,
              try WorktreeFileFingerprint.capture(path: executable.path) == executable
        else {
            throw WorktreeEvidenceError.changed(gitDirectory)
        }
        if let workingDirectory, let workingIdentity {
            guard try WorktreeFileIdentity.capture(path: workingDirectory) == workingIdentity else { throw WorktreeEvidenceError.changed(workingDirectory) }
        }
    }
}

/// Consent binds raw Git output to complete ownership, locks and candidates; history is informational.
@objc(PBWorktreePrunePreview)
final nonisolated class PBWorktreePrunePreview: NSObject {
    @objc let report: String
    @objc let hasMovedWorktrees: Bool
    let rawReport: Data
    fileprivate let identifier = UUID()
    fileprivate let context: WorktreeOperationContext
    fileprivate let fingerprint: WorktreeAdministrativeFingerprint
    fileprivate let checkoutLinks: WorktreeCheckoutLinkEvidence
    fileprivate let records: [GitWorktree]

    fileprivate init(report: String, rawReport: Data, context: WorktreeOperationContext, fingerprint: WorktreeAdministrativeFingerprint, checkoutLinks: WorktreeCheckoutLinkEvidence, records: [GitWorktree]) {
        self.report = report
        self.rawReport = rawReport
        self.context = context
        self.fingerprint = fingerprint
        self.checkoutLinks = checkoutLinks
        self.records = records
        hasMovedWorktrees = records.contains { $0.movedPath != nil }
        super.init()
    }

    fileprivate func matches(_ other: PBWorktreePrunePreview) -> Bool {
        rawReport == other.rawReport && context == other.context && fingerprint.hasSameConsentEvidence(as: other.fingerprint)
            && checkoutLinks == other.checkoutLinks && records.map(WorktreeConsentRecord.init) == other.records.map(WorktreeConsentRecord.init)
    }
}

private nonisolated struct WorktreeRepairPlan: Sendable {
    let context: WorktreeOperationContext
    let scope: WorktreeRepairScope
    let selection: WorktreeRepairSelection?
    let style: WorktreeLinkStyle?
    let fallbackStyle: WorktreeLinkStyle

    var command: WorktreeCommand {
        var paths = scope.mainPath.map { [$0] } ?? []
        paths += scope.targets.filter { !$0.originalPath.utf8.elementsEqual($0.path.utf8) }.map(\.path)
        let selected = selection.flatMap { choice in scope.targets.first { WorktreePaths.identity($0.originalPath) == choice.originalIdentity } }
        let isLocate = selected.map { !Data($0.originalPath.utf8).elementsEqual(Data($0.path.utf8)) } ?? false
        if isLocate, let selected {
            paths.append(selected.path)
        }
        var seen: Set<Data> = []
        paths = paths.filter { seen.insert(Data($0.utf8)).inserted }
        return isLocate ? .repairMovedPaths(paths: paths) : .repairLinks(style: style ?? fallbackStyle, movedPaths: paths)
    }
}

/// A consumed service-issued preview is explicit consent for every target, including reclaim targets.
@objc(PBWorktreeRepairPreview)
final nonisolated class PBWorktreeRepairPreview: NSObject {
    @objc let paths: [String]
    @objc let reclaimPaths: [String]
    @objc var requiresReclaim: Bool {
        !reclaimPaths.isEmpty
    }

    fileprivate let identifier = UUID()
    fileprivate let plan: WorktreeRepairPlan

    fileprivate init(plan: WorktreeRepairPlan) {
        self.plan = plan
        paths = plan.scope.targets.map(\.path)
        reclaimPaths = plan.scope.targets.filter(\.requiresReclaim).map(\.path)
        super.init()
    }
}

/// Public events contain only whitelisted operation/stage names. Arguments and output remain raw for execution.
@objc(PBWorktreeLifecycleDiagnostics)
final nonisolated class PBWorktreeLifecycleDiagnostics: NSObject {
    @objc(publicEventWithArguments:stage:phase:count:category:)
    static func publicEvent(arguments: [String], stage: String, phase: String, count: Int, category: String) -> String {
        let operations = ["add", "remove", "lock", "unlock", "prune", "repair", "list"]
        let operation: String
        if arguments.first == "--version" {
            operation = "capability"
        } else if arguments.count > 1, arguments[0] == "worktree", operations.contains(arguments[1]) {
            operation = arguments[1]
        } else {
            operation = "unknown"
        }
        let stages = ["started", "completed", "failed", "rejected", "cancelled", "draining", "published"]
        let phases = ["reserved", "preparing", "writing", "reconciling", "terminal", "discovery", "capability"]
        let categories = ["none", "ownership", "context", "capability", "incomplete", "task", "moved", "consent"]
        return "worktree." + operation + "." + (stages.contains(stage) ? stage : "unknown")
            + " phase=" + (phases.contains(phase) ? phase : "unknown")
            + " count=" + String(max(0, count)) + " category=" + (categories.contains(category) ? category : "unknown")
    }
}

/// The reservation owns its retained repository, task and frozen execution context through completion.
private final class WorktreeOperation {
    enum Phase { case reserved, preparing, writing, reconciling, terminal }
    let identifier = UUID()
    let context: WorktreeOperationContext
    private(set) var repository: PBGitRepository?
    var taskCompletion: (@MainActor @Sendable (Result<Data, Error>) -> Void)?
    var discoveryCompletion: (@MainActor @Sendable (Result<[GitWorktree], Error>) -> Void)?
    private(set) var phase = Phase.reserved
    private(set) var isCancelled = false
    private var release: (@MainActor @Sendable () -> Void)?
    var task: PBTask?
    var cancellation: (() -> Void)?
    var evidenceCancellations: [UUID: () -> Void] = [:]
    var eventArguments: [String] = []

    init(context: WorktreeOperationContext, repository: PBGitRepository) {
        self.context = context
        self.repository = repository
    }

    var isActive: Bool {
        phase != .terminal
    }

    var phaseName: String {
        switch phase {
        case .reserved: "reserved"
        case .preparing: "preparing"
        case .writing: "writing"
        case .reconciling: "reconciling"
        case .terminal: "terminal"
        }
    }

    var drainsAfterOwnerChange: Bool {
        phase == .writing || phase == .reconciling
    }

    func admit(release: @escaping @MainActor @Sendable () -> Void) {
        guard isActive else { release(); return }
        self.release = release
        phase = .preparing
        if isCancelled {
            cancellation?()
        }
    }

    func beginWriter() {
        phase = .writing
    }

    func beginReconciliation() {
        phase = .reconciling
    }

    func complete(_ deliver: () -> Void) {
        guard isActive else { return }
        phase = .terminal
        task = nil
        taskCompletion = nil
        discoveryCompletion = nil
        evidenceCancellations.values.forEach { $0() }
        evidenceCancellations.removeAll()
        cancellation = nil
        repository = nil
        eventArguments = []
        let release = release
        self.release = nil
        deliver()
        release?()
    }

    func cancelPreparation() {
        guard isActive, !drainsAfterOwnerChange else { return }
        isCancelled = true
        guard phase != .reserved else { return }
        task?.terminate()
        cancellation?()
    }
}

private final class WorktreeEvidenceDelivery<Value: Sendable> {
    var completion: (@MainActor @Sendable (Result<Value, Error>) -> Void)?
    init(_ completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        self.completion = completion
    }
}

private final class WorktreePreparedReservation<Value: Sendable> {
    var result: Result<Value, Error>?
    var isAdmitted = false
    var started = false

    func takeReadyResult() -> Result<Value, Error>? {
        guard isAdmitted, !started, let result else { return nil }
        started = true
        return result
    }
}

@objc(PBRepositoryWorktreeService)
final class PBRepositoryWorktreeService: NSObject {
    private weak var repository: PBGitRepository?
    private let taskFactory: (([String]) -> PBTask)?
    private let repairPreparationObserver: (@Sendable () -> Void)?
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PBGitWorktrees")
    private var state = WorktreeRefreshState()
    private var discovery: PBTask?
    private var versionTask: PBTask?
    private var executable = ""
    private var checkedExecutable: WorktreeFileFingerprint?
    private var versionGeneration = 0
    private var snapshot: [GitWorktree] = []
    private var operations: [UUID: WorktreeOperation] = [:]
    private var prunePreviews: Set<UUID> = []
    private var repairPreviews: Set<UUID> = []
    private var legacyPrunePreview: PBWorktreePrunePreview?
    private var configuredPreference: String?
    private var started = false
    @objc private(set) dynamic var repairPreparationCount: UInt64 = 0
    @objc private(set) dynamic var worktrees: [PBGitWorktree] = []
    @objc private(set) dynamic var gitVersion: String?
    @objc private(set) dynamic var isSupported = false
    @objc var explanation: String {
        "Worktrees require Git 2.48 or later. Selected Git: \(gitVersion ?? "unavailable or being checked"). Choose a newer executable in Git Preferences…"
    }

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        taskFactory = nil
        repairPreparationObserver = nil
        super.init()
    }

    @objc(initWithRepository:taskFactory:)
    init(repository: PBGitRepository, taskFactory: @escaping ([String]) -> PBTask) {
        self.repository = repository
        self.taskFactory = taskFactory
        repairPreparationObserver = nil
        super.init()
    }

    @objc(initWithRepository:taskFactory:repairPreparationObserver:)
    init(repository: PBGitRepository, taskFactory: @escaping ([String]) -> PBTask, repairPreparationObserver: @escaping @Sendable () -> Void) {
        self.repository = repository
        self.taskFactory = taskFactory
        self.repairPreparationObserver = repairPreparationObserver
        super.init()
    }

    private func makeTask(_ arguments: [String], context: WorktreeOperationContext? = nil) -> PBTask {
        if let taskFactory {
            return taskFactory(arguments)
        }
        if let context {
            return PBTask(launchPath: context.executable.path, arguments: ["--git-dir=" + context.gitDirectory] + arguments, inDirectory: context.workingDirectory)
        }
        guard let gitDirectory = repository?.gitURL()?.path else { return PBTask(launchPath: "/usr/bin/false", arguments: [], inDirectory: nil) }
        return PBTask(launchPath: executable, arguments: ["--git-dir=" + gitDirectory] + arguments, inDirectory: repository?.workingDirectoryURL()?.path)
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
        DispatchQueue.main.async { [weak self] in _ = self?.refreshCapabilityIfChanged() }
    }

    @objc private nonisolated func repositoryChanged(_: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// Same-path upgrades invalidate old consent before a fresh capability probe.
    private func refreshCapabilityIfChanged() -> Bool {
        guard !state.isClosed else { return false }
        let selected = Self.selectedExecutable()
        let changed = !selected.utf8.elementsEqual(executable.utf8)
            || configuredPreference != UserDefaults.standard.string(forKey: "gitExecutable")
            || (checkedExecutable != nil && (try? WorktreeFileFingerprint.capture(path: selected)) != checkedExecutable)
        if changed {
            checkVersion()
        }
        return changed
    }

    private func checkVersion() {
        guard !state.isClosed else { return }
        versionGeneration += 1
        let generation = versionGeneration
        setAvailability(version: nil, supported: false)
        prunePreviews.removeAll()
        repairPreviews.removeAll()
        legacyPrunePreview = nil
        checkedExecutable = nil
        versionTask?.terminate()
        discovery?.terminate()
        discovery = nil
        state.invalidate()
        cancelPreparationOperations()
        executable = Self.selectedExecutable()
        configuredPreference = UserDefaults.standard.string(forKey: "gitExecutable")
        guard !executable.isEmpty else { return }
        let checking = try? WorktreeFileFingerprint.capture(path: executable)
        let task = makeTask(["--version"])
        task.timeout = 10
        versionTask = task
        logEvent(["--version"], stage: "started", phase: "capability")
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees main-queue delivery.
            MainActor.assumeIsolated {
                guard let self, generation == self.versionGeneration, !self.state.isClosed else { return }
                let complete = self.versionTask?.standardOutputTruncated == false && self.versionTask?.standardErrorTruncated == false
                self.versionTask = nil
                let version = error == nil && complete ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                let stable = checking != nil && (try? WorktreeFileFingerprint.capture(path: self.executable)) == checking
                self.checkedExecutable = stable ? checking : nil
                self.setAvailability(version: version, supported: stable && WorktreePolicy.supports(version: version))
                self.logEvent(["--version"], stage: self.isSupported ? "completed" : "failed", phase: "capability", category: self.isSupported ? "none" : "capability")
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
        guard !refreshCapabilityIfChanged(), isSupported, let generation = state.request() else { return }
        beginDiscovery(generation: generation)
    }

    private func beginDiscovery(generation: UInt64) {
        let task = makeTask(["worktree", "list", "--porcelain", "-z"])
        task.separatesStandardError = true
        task.timeout = 10
        discovery = task
        let common = Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? "")
        let current = repository?.workingDirectoryURL()?.path ?? repository?.gitURL()?.path
        logEvent(["worktree", "list"], stage: "started", phase: "discovery")
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees main-queue delivery.
            MainActor.assumeIsolated {
                guard let self, self.state.accepts(generation) else { return }
                let complete = self.discovery?.standardOutputTruncated == false && self.discovery?.standardErrorTruncated == false
                Self.evidence({
                    if let error {
                        throw error
                    }
                    guard let data, complete else { throw WorktreeParseError.malformedRecord }
                    return try WorktreeLinkInspector.inspect(WorktreeParser.parse(data), commonDirectory: common, currentPath: current)
                }) { [weak self] result in self?.complete(result, generation: generation) }
            }
        }
    }

    private func complete(_ result: Result<[GitWorktree], Error>, generation: UInt64) {
        guard state.accepts(generation) else { return }
        discovery = nil
        switch result {
        case let .success(records): publish(records)
        case .failure: logEvent(["worktree", "list"], stage: "failed", phase: "discovery", category: "task")
        }
        if let next = state.complete(generation) {
            beginDiscovery(generation: next)
        }
    }

    private func publish(_ records: [GitWorktree]) {
        guard snapshot != records else { return }
        repository?.willChangeValue(forKey: "worktrees")
        snapshot = records
        worktrees = records.map(PBGitWorktree.init)
        repository?.didChangeValue(forKey: "worktrees")
        logEvent(["worktree", "list"], stage: "published", phase: "discovery", count: records.count)
    }

    @objc(cancel)
    nonisolated func cancel() {
        onMain { self.cancelOnMain() }
    }

    private func cancelOnMain() {
        state.close()
        prunePreviews.removeAll()
        repairPreviews.removeAll()
        legacyPrunePreview = nil
        versionGeneration += 1
        discovery?.terminate()
        versionTask?.terminate()
        discovery = nil
        versionTask = nil
        cancelPreparationOperations()
        NotificationCenter.default.removeObserver(self)
        logEvent([], stage: "cancelled", phase: "terminal")
    }

    private func cancelPreparationOperations() {
        for operation in Array(operations.values) {
            if operation.drainsAfterOwnerChange {
                logEvent(operation.eventArguments, stage: "draining", phase: operation.phaseName, count: 1)
            }
            operation.cancelPreparation()
        }
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

    func perform(_ command: WorktreeCommand, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        switch command {
        case .pruneReport: pruneWorktrees(reportOnly: true, completion: completion); return
        case .prune, .repairLinks, .repairMoved, .repairMovedPaths:
            completion(nil, failure("This operation requires a captured prune preview or repair ownership target.")); return
        default: break
        }
        enqueueOperation(onFailure: { completion(nil, $0) }) { operation in
            if case let .remove(path, _) = command,
               let tree = self.worktrees.first(where: { WorktreePaths.identity($0.path) == WorktreePaths.identity(path) }),
               !WorktreeEligibility(tree.value, supported: self.isSupported).canRemove
            {
                self.finish(operation) { completion(nil, self.failure("The main, current, or locked worktree cannot be removed. Unlock a linked worktree first.")) }; return
            }
            self.executeTask(command, operation: operation) { result in
                switch result {
                case let .failure(error): self.finish(operation) { completion(nil, self.operationError(error)) }
                case let .success(data):
                    self.discover(operation: operation, reconciling: true) { result in
                        self.finish(operation) {
                            switch result {
                            case .success: completion(String(decoding: data, as: UTF8.self), nil)
                            case let .failure(error): completion(nil, self.reconciliationError("the operation", error: error))
                            }
                        }
                    }
                }
            }
        }
    }

    @objc(pruneWorktreesReportOnly:completion:)
    func pruneWorktrees(reportOnly: Bool, completion: @escaping @MainActor @Sendable (String?, NSError?) -> Void) {
        if reportOnly {
            if let legacyPrunePreview {
                discardPrunePreview(legacyPrunePreview)
            }
            legacyPrunePreview = nil
            preparePrunePreview { preview, error in
                self.legacyPrunePreview = preview
                completion(preview?.report, error)
            }
        } else {
            guard let preview = legacyPrunePreview else {
                completion(nil, failure("Preview the worktrees before confirming Prune.")); return
            }
            legacyPrunePreview = nil
            prune(confirmedPreview: preview) { updated, error in
                if let updated {
                    self.discardPrunePreview(updated)
                    completion(nil, self.failure(updated.hasMovedWorktrees ? "Repair the worktree links first. Moved checkouts are protected from Prune." : "Worktree ownership or prune candidates changed. Preview them again before confirming Prune."))
                } else {
                    completion(nil, error)
                }
            }
        }
    }

    @objc(preparePrunePreviewWithCompletion:)
    func preparePrunePreview(completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void) {
        enqueueOperation(onFailure: { completion(nil, $0) }) { operation in
            self.capturePrunePreview(operation: operation) { result in
                self.finish(operation) {
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
        enqueueOperation(context: preview.context, onFailure: { completion(nil, $0) }) { operation in
            self.capturePrunePreview(operation: operation) { result in
                switch result {
                case let .failure(error): self.finish(operation) { completion(nil, self.operationError(error)) }
                case let .success(current):
                    guard current.matches(preview), current.checkoutLinks.permitsPrune, !current.hasMovedWorktrees, !current.rawReport.isEmpty else {
                        self.logEvent(["worktree", "prune"], stage: "rejected", count: current.fingerprint.registrationCount, category: current.hasMovedWorktrees ? "moved" : "consent")
                        self.finish(operation) { self.prunePreviews.insert(current.identifier); completion(current, nil) }; return
                    }
                    self.executeTask(.prune, operation: operation) { result in
                        switch result {
                        case let .failure(error): self.finish(operation) { completion(nil, self.operationError(error)) }
                        case .success:
                            self.discover(operation: operation, reconciling: true) { result in
                                self.finish(operation) {
                                    switch result {
                                    case .success: completion(nil, nil)
                                    case let .failure(error): completion(nil, self.reconciliationError("prune", error: error))
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
        let context = operation.context
        evidence(operation: operation, { try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory) }) { initial in
            switch initial {
            case let .failure(error): completion(.failure(error))
            case let .success(fingerprint):
                self.discover(operation: operation) { discovered in
                    switch discovered {
                    case let .failure(error): completion(.failure(error))
                    case let .success(records):
                        self.evidence(operation: operation, { try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: records) }) { links in
                            switch links {
                            case let .failure(error): completion(.failure(error))
                            case let .success(checkoutLinks):
                                self.capturePruneReport(operation: operation, fingerprint: fingerprint, records: records, checkoutLinks: checkoutLinks, completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private func capturePruneReport(operation: WorktreeOperation, fingerprint: WorktreeAdministrativeFingerprint, records: [GitWorktree], checkoutLinks: WorktreeCheckoutLinkEvidence, completion: @escaping @MainActor @Sendable (Result<PBWorktreePrunePreview, Error>) -> Void) {
        let context = operation.context
        executeTask(.pruneReport, operation: operation) { report in
            switch report {
            case let .failure(error): completion(.failure(error))
            case let .success(bytes):
                self.evidence(operation: operation, {
                    guard let text = String(data: bytes, encoding: .utf8) else { throw WorktreeParseError.malformedRecord }
                    let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: context.commonDirectory, currentPath: context.inspectionLocation)
                    let current = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)
                    let currentLinks = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: inspected)
                    guard fingerprint.hasSameConsentEvidence(as: current), checkoutLinks == currentLinks,
                          records.map(WorktreeConsentRecord.init) == inspected.map(WorktreeConsentRecord.init)
                    else { throw WorktreeEvidenceError.changed(context.commonDirectory) }
                    return WorktreePruneEvidence(report: text, bytes: bytes, fingerprint: current, checkoutLinks: currentLinks, records: inspected)
                }) { checked in
                    completion(checked.map { PBWorktreePrunePreview(report: $0.report, rawReport: $0.bytes, context: context, fingerprint: $0.fingerprint, checkoutLinks: $0.checkoutLinks, records: $0.records) })
                }
            }
        }
    }

    @objc(prepareRepairWorktree:movedTo:completion:)
    func prepareRepair(worktree: PBGitWorktree, movedTo path: String, completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void) {
        requestRepair(selection: WorktreeRepairSelection(originalPath: worktree.path, path: path), style: nil, completion: completion)
    }

    @objc(prepareRepairLinksWithRelativePaths:completion:)
    func prepareRepairLinks(relativePaths: Bool, completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void) {
        prepareRepairLinks(style: relativePaths ? .relative : .absolute, completion: completion)
    }

    func prepareRepairLinks(style: WorktreeLinkStyle, completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void) {
        requestRepair(selection: nil, style: style, completion: completion)
    }

    @objc(discardRepairPreview:)
    func discardRepairPreview(_ preview: PBWorktreeRepairPreview) {
        repairPreviews.remove(preview.identifier)
    }

    @objc(repairWithConfirmedPreview:completion:)
    func repair(confirmedPreview preview: PBWorktreeRepairPreview, completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void) {
        guard repairPreviews.remove(preview.identifier) != nil else {
            completion(nil, failure("This repair preview was cancelled, consumed, or belongs to another repository. Review the repair again.")); return
        }
        enqueueOperation(context: preview.plan.context, onFailure: { completion(nil, $0) }) { operation in
            self.discover(operation: operation) { discovered in
                switch discovered {
                case let .failure(error): self.finish(operation) { completion(nil, self.operationError(error)) }
                case let .success(records):
                    let old = preview.plan
                    self.evidence(operation: operation, {
                        try old.context.validate()
                        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: old.context.commonDirectory, mainPath: records.first(where: \.isMain)?.path, selection: old.selection)
                        guard scope.canRenew(from: old.scope) else { throw WorktreeEvidenceError.changed(old.context.commonDirectory) }
                        return WorktreeRepairPlan(context: old.context, scope: scope, selection: old.selection, style: old.style, fallbackStyle: old.fallbackStyle)
                    }) { result in
                        switch result {
                        case let .failure(error):
                            self.logEvent(["worktree", "repair"], stage: "rejected", count: old.scope.targets.count, category: "ownership")
                            self.finish(operation) { completion(nil, self.operationError(error)) }
                        case let .success(current):
                            guard current.scope.hasSameConsentEvidence(as: old.scope) else {
                                let renewed = PBWorktreeRepairPreview(plan: current)
                                self.logEvent(["worktree", "repair"], stage: "rejected", count: current.scope.targets.count, category: "consent")
                                self.finish(operation) { self.repairPreviews.insert(renewed.identifier); completion(renewed, nil) }; return
                            }
                            self.performRepair(current, operation: operation) { error in self.finish(operation) { completion(nil, error) } }
                        }
                    }
                }
            }
        }
    }

    @objc(repairWorktree:movedTo:completion:)
    func repair(worktree: PBGitWorktree, movedTo path: String, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        requestRepair(selection: WorktreeRepairSelection(originalPath: worktree.path, path: path), style: nil, legacyCompletion: completion)
    }

    @objc(repairLinksWithRelativePaths:completion:)
    func repairLinks(relativePaths: Bool, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        repairLinks(style: relativePaths ? .relative : .absolute, completion: completion)
    }

    func repairLinks(style: WorktreeLinkStyle, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        requestRepair(selection: nil, style: style, legacyCompletion: completion)
    }

    /// Legacy proven repairs and preparation share initial capture, but proven repairs never release and re-enqueue.
    private func requestRepair(selection: WorktreeRepairSelection?, style: WorktreeLinkStyle?, completion: (@MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void)? = nil, legacyCompletion: (@MainActor @Sendable (NSError?) -> Void)? = nil) {
        let fail: @MainActor @Sendable (NSError) -> Void = { error in
            self.logEvent(["worktree", "repair"], stage: "rejected", category: "ownership")
            completion?(nil, error)
            legacyCompletion?(error)
        }
        do {
            let context = try captureContext()
            let records = snapshot
            let main = records.first(where: \.isMain)?.path
            let fallbackStyle = WorktreePolicy.preferredRepairStyle(records.map(\.linkStyle))
            let anchor = try WorktreeAdministrativeAnchor.capture(commonDirectory: context.commonDirectory)
            let selectedIdentity = try selection.map { try WorktreeFileIdentity.capture(path: $0.path) }
            let preparationObserver = repairPreparationObserver
            enqueuePrepared(context: context, onFailure: fail, preparing: {
                try context.validate()
                try anchor.validate(commonDirectory: context.commonDirectory)
                if let selection, let selectedIdentity {
                    guard try WorktreeFileIdentity.capture(path: selection.path) == selectedIdentity else { throw WorktreeEvidenceError.changed(selection.path) }
                }
                preparationObserver?()
                let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: context.commonDirectory, mainPath: main, selection: selection)
                try anchor.validate(commonDirectory: context.commonDirectory)
                try context.validate()
                return WorktreeRepairPlan(context: context, scope: scope, selection: selection, style: style, fallbackStyle: fallbackStyle)
            }) { operation, plan in
                if let legacyCompletion {
                    guard !plan.scope.requiresReclaim else {
                        self.logEvent(["worktree", "repair"], stage: "rejected", count: plan.scope.targets.count, category: "consent")
                        self.finish(operation) { legacyCompletion(self.failure("These checkout links require explicit Reclaim approval. Review a fresh repair preview before replacing them.")) }; return
                    }
                    self.performRepair(plan, operation: operation) { error in self.finish(operation) { legacyCompletion(error) } }
                } else {
                    self.evidence(operation: operation, { try WorktreeLinkInspector.validateRepairScope(plan.scope, commonDirectory: context.commonDirectory) }) { validation in
                        switch validation {
                        case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                        case .success:
                            let preview = PBWorktreeRepairPreview(plan: plan)
                            self.logEvent(["worktree", "repair"], stage: "completed", count: plan.scope.targets.count)
                            self.finish(operation) { self.repairPreviews.insert(preview.identifier); completion?(preview, nil) }
                        }
                    }
                }
            }
        } catch { fail(operationError(error)) }
    }

    private func performRepair(_ plan: WorktreeRepairPlan, operation: WorktreeOperation, completion: @escaping @MainActor @Sendable (NSError?) -> Void) {
        // Fresh validation and launch retain one admission, without a consent callback or re-enqueue between them.
        evidence(operation: operation, { try WorktreeLinkInspector.validateRepairScope(plan.scope, commonDirectory: plan.context.commonDirectory) }) { validation in
            switch validation {
            case let .failure(error):
                self.logEvent(["worktree", "repair"], stage: "rejected", count: plan.scope.targets.count, category: "ownership")
                completion(self.operationError(error))
            case .success:
                self.executeTask(plan.command, operation: operation) { written in
                    switch written {
                    case let .failure(error): completion(self.operationError(error))
                    case .success:
                        self.discover(operation: operation, reconciling: true) { discovered in
                            switch discovered {
                            case let .failure(error): completion(self.reconciliationError("repair", error: error))
                            case let .success(records):
                                self.evidence(operation: operation, {
                                    try plan.context.validate()
                                    try WorktreeLinkInspector.verifyRepairScope(plan.scope, records: records, commonDirectory: plan.context.commonDirectory, style: plan.style)
                                }) { verified in
                                    switch verified {
                                    case .success: completion(nil)
                                    case let .failure(error):
                                        self.logEvent(["worktree", "repair"], stage: "failed", phase: "reconciling", count: plan.scope.targets.count, category: "ownership")
                                        completion(self.failure("Git completed repair, but the captured registrations and checkouts do not have exact bidirectional links.", underlying: error))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func enqueueOperation(context requested: WorktreeOperationContext? = nil, onFailure: @escaping @MainActor @Sendable (NSError) -> Void, body: @escaping @MainActor (WorktreeOperation) -> Void) -> WorktreeOperation? {
        do {
            let context = try captureContext()
            guard requested == nil || requested == context else { throw WorktreeEvidenceError.changed(context.gitDirectory) }
            guard let repository else { throw Self.cancelledError() }
            let operation = WorktreeOperation(context: context, repository: repository)
            operations[operation.identifier] = operation
            operation.cancellation = { self.finish(operation) { onFailure(Self.cancelledError()) } }
            // The job retains the service and repository until the reserved admission is released.
            WorktreeMutationGate.enqueue(key: context.commonIdentity.pathIdentity) { finished in
                operation.admit(release: finished)
                guard operation.isActive else { return }
                do { try self.validateCurrentContext(context) } catch {
                    self.finish(operation) { onFailure(self.operationError(error)) }; return
                }
                body(operation)
            }
            return operation
        } catch { onFailure(operationError(error)); return nil }
    }

    /// Reserve synchronously, then begin capture immediately even when an earlier writer owns admission.
    private func enqueuePrepared<Value: Sendable>(context: WorktreeOperationContext, onFailure: @escaping @MainActor @Sendable (NSError) -> Void, preparing: @escaping @Sendable () throws -> Value, body: @escaping @MainActor (WorktreeOperation, Value) -> Void) {
        let reservation = WorktreePreparedReservation<Value>()
        var operation: WorktreeOperation?
        let run: @MainActor () -> Void = {
            guard let operation, operation.isActive, let result = reservation.takeReadyResult() else { return }
            switch result {
            case let .success(value): body(operation, value)
            case let .failure(error):
                self.finish(operation) { onFailure(self.operationError(error)) }
            }
        }
        let reserved = enqueueOperation(context: context, onFailure: onFailure) { admitted in
            operation = admitted
            reservation.isAdmitted = true
            run()
        }
        guard let reserved else { return }
        evidence(operation: reserved, preparing) { result in
            if case .success = result {
                self.repairPreparationCount &+= 1
            }
            reservation.result = result
            run()
        }
    }

    private func finish(_ operation: WorktreeOperation, deliver: () -> Void) {
        operation.complete {
            operations.removeValue(forKey: operation.identifier)
            deliver()
        }
    }

    private func executeTask(_ command: WorktreeCommand, operation: WorktreeOperation, completion: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void) {
        guard operation.isActive, operation.repository != nil else { return }
        do { try validateCurrentContext(operation.context) } catch { completion(.failure(error)); return }
        let readOnly = command == .pruneReport
        if !readOnly {
            operation.beginWriter()
            operation.eventArguments = Array(command.arguments.prefix(2))
        }
        let task = makeTask(command.arguments, context: operation.context)
        task.additionalEnvironment = (task.additionalEnvironment ?? [:]).merging(["LC_ALL": "C"]) { _, value in value }
        task.timeout = 120
        operation.task = task
        operation.taskCompletion = completion
        logEvent(command.arguments, stage: "started", phase: readOnly ? "preparing" : "writing", count: 1)
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees main-queue delivery.
            MainActor.assumeIsolated {
                guard let self, operation.isActive, let deliver = operation.taskCompletion else { return }
                operation.taskCompletion = nil
                let ownedTask = operation.task
                operation.task = nil
                if let error {
                    let cocoaError = error as NSError
                    if readOnly, error is CancellationError || (cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) {
                        self.logEvent(command.arguments, stage: "cancelled", phase: "preparing", count: 1)
                        deliver(.failure(Self.cancelledError())); return
                    }
                    let output = String(decoding: data ?? ownedTask?.standardOutputData ?? Data(), as: UTF8.self)
                    self.logEvent(command.arguments, stage: "failed", phase: readOnly ? "preparing" : "writing", count: 1, category: "task")
                    self.logger.debug("Worktree private diagnostic: \(PBTaskDiagnostics.redacted(output), privacy: .private)")
                    deliver(.failure(self.failure(output.isEmpty ? error.localizedDescription : output, underlying: error)))
                } else if let data, ownedTask?.standardOutputTruncated == false, ownedTask?.standardErrorTruncated == false {
                    self.logEvent(command.arguments, stage: "completed", phase: readOnly ? "preparing" : "writing", count: 1)
                    deliver(.success(data))
                } else {
                    deliver(.failure(self.failure("Git's worktree response could not be read completely.")))
                }
            }
        }
    }

    /// The operation owns this discovery; ordinary refresh, close and preferences cannot cancel reconciliation.
    private func discover(operation: WorktreeOperation, reconciling: Bool = false, completion: @escaping @MainActor @Sendable (Result<[GitWorktree], Error>) -> Void) {
        guard operation.isActive, operation.repository != nil else { return }
        if reconciling {
            operation.beginReconciliation()
        }
        let context = operation.context
        do {
            if reconciling {
                try context.validate()
            } else {
                try validateCurrentContext(context)
            }
        } catch { completion(.failure(error)); return }
        let arguments = ["worktree", "list", "--porcelain", "-z"]
        let task = makeTask(arguments, context: context)
        task.separatesStandardError = true
        task.timeout = 10
        operation.task = task
        operation.discoveryCompletion = completion
        logEvent(arguments, stage: "started", phase: reconciling ? "reconciling" : "preparing")
        task.perform { [weak self] data, error in
            // swift6-safety-justification: PBTask’s PBMainQueuePerform category guarantees main-queue delivery.
            MainActor.assumeIsolated {
                guard let self, operation.isActive, let deliver = operation.discoveryCompletion else { return }
                operation.discoveryCompletion = nil
                let complete = operation.task?.standardOutputTruncated == false && operation.task?.standardErrorTruncated == false
                operation.task = nil
                self.evidence(operation: operation, {
                    if let error {
                        throw error
                    }
                    guard let data, complete else { throw WorktreeParseError.malformedRecord }
                    try context.validate()
                    return try WorktreeLinkInspector.inspect(WorktreeParser.parse(data), commonDirectory: context.commonDirectory, currentPath: context.inspectionLocation)
                }) { result in
                    if case let .success(records) = result, self.canPublish(context) {
                        self.publish(records)
                    }
                    deliver(result)
                }
            }
        }
    }

    private func canPublish(_ context: WorktreeOperationContext) -> Bool {
        !state.isClosed && isSupported && versionGeneration == context.generation && (try? captureContext()) == context
    }

    private func evidence<Value: Sendable>(operation: WorktreeOperation, _ work: @escaping @Sendable () throws -> Value, completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        let context = operation.context
        let delivery = WorktreeEvidenceDelivery(completion)
        let identifier = UUID()
        operation.evidenceCancellations[identifier] = { delivery.completion = nil }
        Self.evidence({
            try context.validate()
            let value = try work()
            try context.validate()
            return value
        }) { [weak delivery] result in
            guard let delivery else { return }
            let completion = delivery.completion
            delivery.completion = nil
            operation.evidenceCancellations.removeValue(forKey: identifier)
            guard operation.isActive, !operation.isCancelled else { return }
            completion?(result)
        }
    }

    private nonisolated static func evidence<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value, completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Constant-size filesystem anchors are captured before worker dispatch; inventories never run on the main actor.
    private func captureContext() throws -> WorktreeOperationContext {
        guard !state.isClosed else { throw Self.cancelledError() }
        guard !refreshCapabilityIfChanged(), isSupported, let gitDirectory = repository?.gitURL()?.path, let checkedExecutable else { throw failure("The repository or selected Git is unavailable or changed. Review it after Git is checked.") }
        let common = Self.commonDirectory(gitDirectory: gitDirectory)
        let commonIdentity = try WorktreeFileIdentity.capture(path: common)
        let gitIdentity = try WorktreeFileIdentity.capture(path: gitDirectory)
        let working = (repository?.workingDirectoryURL()?.path).map(WorktreePaths.canonical)
        let workingIdentity = try working.map { try WorktreeFileIdentity.capture(path: $0) }
        guard commonIdentity.kind == .directory, gitIdentity.kind == .directory, workingIdentity == nil || workingIdentity?.kind == .directory else { throw WorktreeEvidenceError.unsupportedObject(gitDirectory) }
        return WorktreeOperationContext(commonDirectory: WorktreePaths.canonical(common), commonIdentity: commonIdentity, gitDirectory: WorktreePaths.canonical(gitDirectory), gitIdentity: gitIdentity, executable: checkedExecutable, workingDirectory: working, workingIdentity: workingIdentity, generation: versionGeneration)
    }

    private func validateCurrentContext(_ context: WorktreeOperationContext) throws {
        guard try captureContext() == context else { throw WorktreeEvidenceError.changed(context.gitDirectory) }
        try context.validate()
    }

    private func reconciliationError(_ operation: String, error: Error) -> NSError {
        failure("Git completed \(operation), but worktree state could not be reread: \(error.localizedDescription)", underlying: error)
    }

    private func operationError(_ error: Error) -> NSError {
        if error is CancellationError {
            return Self.cancelledError()
        }
        let value = error as NSError
        return value.domain == PBGitXErrorDomain || (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError) ? value : failure(value.localizedFailureReason ?? value.localizedDescription, underlying: value)
    }

    private func failure(_ message: String, underlying: Error? = nil) -> NSError {
        RepositoryServiceError.make(description: "Worktree operation failed", failureReason: PBTaskDiagnostics.redacted(message), underlyingError: underlying)
    }

    private func logEvent(_ arguments: [String], stage: String, phase: String = "preparing", count: Int = 0, category: String = "none") {
        let event = PBWorktreeLifecycleDiagnostics.publicEvent(arguments: arguments, stage: stage, phase: phase, count: count, category: category)
        if stage == "failed" || stage == "rejected" {
            logger.error("\(event, privacy: .public)")
        } else {
            logger.info("\(event, privacy: .public)")
        }
        logger.debug("Worktree private arguments: \(PBTaskDiagnostics.displayArguments(arguments), privacy: .private)")
    }

    private nonisolated static func cancelledError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
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

private nonisolated struct WorktreePruneEvidence: Sendable {
    let report: String
    let bytes: Data
    let fingerprint: WorktreeAdministrativeFingerprint
    let checkoutLinks: WorktreeCheckoutLinkEvidence
    let records: [GitWorktree]
}

/// Linked windows share one FIFO for lifecycle changes in their common Git directory.
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
        job { jobs[key]?.removeFirst(); start(key: key) }
    }
}

// swiftlint:enable unused_declaration
