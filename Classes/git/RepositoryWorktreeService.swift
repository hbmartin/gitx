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

private nonisolated struct WorktreeContextError: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private nonisolated struct WorktreeCapabilityError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
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
        do {
            guard try WorktreeFileIdentity.capture(path: commonDirectory) == commonIdentity,
                  try WorktreeFileIdentity.capture(path: gitDirectory) == gitIdentity,
                  try WorktreeFileFingerprint.capture(path: executable.path) == executable
            else { throw WorktreeEvidenceError.changed(gitDirectory) }
            if let workingDirectory, let workingIdentity {
                guard try WorktreeFileIdentity.capture(path: workingDirectory) == workingIdentity else { throw WorktreeEvidenceError.changed(workingDirectory) }
            }
        } catch { throw WorktreeContextError(underlying: error) }
    }
}

/// Consent binds raw Git output to complete ownership, locks and candidates; history is informational.
@objc(PBWorktreePrunePreview)
final nonisolated class PBWorktreePrunePreview: NSObject {
    @objc let report: String
    @objc var hasMovedWorktrees: Bool {
        records.contains { $0.movedPath != nil }
    }

    let rawReport: Data
    fileprivate let identifier = UUID()
    fileprivate let context: WorktreeOperationContext
    fileprivate let fingerprint: WorktreeAdministrativeFingerprint
    fileprivate let checkoutLinks: WorktreeCheckoutLinkEvidence
    fileprivate let records: [GitWorktree]
    fileprivate let consentRecords: [WorktreeConsentRecord]

    fileprivate init(report: String, rawReport: Data, context: WorktreeOperationContext, fingerprint: WorktreeAdministrativeFingerprint, checkoutLinks: WorktreeCheckoutLinkEvidence, records: [GitWorktree], consentRecords: [WorktreeConsentRecord]) {
        self.report = report
        self.rawReport = rawReport
        self.context = context
        self.fingerprint = fingerprint
        self.checkoutLinks = checkoutLinks
        self.records = records
        self.consentRecords = consentRecords
        super.init()
    }

    fileprivate func matches(_ other: PBWorktreePrunePreview) -> Bool {
        rawReport == other.rawReport && context == other.context && fingerprint.hasSameConsentEvidence(as: other.fingerprint)
            && checkoutLinks == other.checkoutLinks && consentRecords == other.consentRecords
    }
}

private nonisolated struct WorktreeRepairPlan: Sendable {
    let context: WorktreeOperationContext
    let scope: WorktreeRepairScope
    let selection: WorktreeRepairSelection?
    let style: WorktreeLinkStyle?
    let effectiveStyle: WorktreeLinkStyle

    init(context: WorktreeOperationContext, scope: WorktreeRepairScope, selection: WorktreeRepairSelection?, style: WorktreeLinkStyle?) {
        self.context = context
        self.scope = scope
        self.selection = selection
        self.style = style
        effectiveStyle = style ?? scope.preferredRepairStyle
    }

    var command: WorktreeCommand {
        var paths = scope.mainPath.map { [$0] } ?? []
        paths += scope.targets.filter { !$0.originalPath.utf8.elementsEqual($0.path.utf8) }.map(\.path)
        var seen: Set<Data> = []
        paths = paths.filter { seen.insert(Data($0.utf8)).inserted }
        return .repairLinks(style: effectiveStyle, movedPaths: paths)
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

/// Acknowledgements outlive cancelled callbacks without retaining their service.
@MainActor
private final class WorktreeActivityDrain {
    #if DEBUG
        private var active: Set<UUID> = []
        private var completions: [@MainActor @Sendable () -> Void] = []
        private var scheduled = false

        func begin() -> @MainActor @Sendable () -> Void {
            let identifier = UUID()
            active.insert(identifier)
            return { [self] in
                guard active.remove(identifier) != nil else { return }
                scheduleIfIdle()
            }
        }

        func drain(completion: @escaping @MainActor @Sendable () -> Void) {
            completions.append(completion)
            NSLog("[GitX] Worktree fixture drain waits for %ld activity acknowledgements", active.count)
            scheduleIfIdle()
        }

        private func scheduleIfIdle() {
            guard active.isEmpty, !completions.isEmpty, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [self] in
                scheduled = false
                guard active.isEmpty else { return }
                let ready = completions
                completions.removeAll()
                NSLog("[GitX] Worktree fixture drain completed %ld waiter(s)", ready.count)
                ready.forEach { $0() }
            }
        }
    #else
        func begin() -> @MainActor @Sendable () -> Void {
            {}
        }
    #endif
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
    private var acknowledged: (@MainActor @Sendable () -> Void)?
    var task: PBTask?
    var cancellation: (() -> Void)?
    var evidenceCancellations: [UUID: () -> Void] = [:]
    var eventArguments: [String] = []
    var afterRelease: [@MainActor @Sendable () -> Void] = []

    init(context: WorktreeOperationContext, repository: PBGitRepository, acknowledged: @escaping @MainActor @Sendable () -> Void) {
        self.context = context
        self.repository = repository
        self.acknowledged = acknowledged
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
        let acknowledged = acknowledged
        self.acknowledged = nil
        let afterRelease = afterRelease
        self.afterRelease.removeAll()
        deliver()
        release?()
        afterRelease.forEach { $0() }
        acknowledged?()
    }

    func markPreparationCancelled() {
        guard isActive, !drainsAfterOwnerChange else { return }
        isCancelled = true
        evidenceCancellations.values.forEach { $0() }
        evidenceCancellations.removeAll()
    }

    func cancelPreparation() {
        markPreparationCancelled()
        guard isActive, isCancelled, phase != .reserved else { return }
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

// swift6-safety-justification: NSLock protects the only mutable field across main and utility queues.
private final nonisolated class WorktreeEvidenceTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }
}

private nonisolated struct WorktreeDiscoveryEvidence: Sendable {
    let identifier = UUID()
    let generation: Int
    let records: [GitWorktree]
    let ownership: Result<WorktreeRepairOwnershipSeeds, Error>

    init(records: [GitWorktree], commonDirectory: String, generation: Int,
         checkCancellation: () throws -> Void = {}) throws
    {
        self.generation = generation
        self.records = records
        try checkCancellation()
        ownership = Result {
            try WorktreeLinkInspector.captureRepairOwnershipSeeds(records: records, commonDirectory: commonDirectory,
                                                                  checkCancellation: checkCancellation)
        }
        try checkCancellation()
    }
}

private nonisolated struct WorktreeEvidenceOrigin: Equatable, Sendable {
    let identifier: UUID?
    let generation: Int
}

private nonisolated struct WorktreePreferenceSelection: Equatable, Sendable {
    let executable: String
    let preference: String?
    let generation: Int
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

enum WorktreeRepairStartResult {
    case completed
    case requiresConsent(PBWorktreeRepairPreview)
}

struct WorktreeRepairReview {
    let preview: PBWorktreeRepairPreview
    let changed: Bool
}

@objc(PBRepositoryWorktreeService)
final class PBRepositoryWorktreeService: NSObject {
    private weak var repository: PBGitRepository?
    private let taskFactory: (([String]) -> PBTask)?
    #if DEBUG
        private let repairPreparationObserver: (@Sendable () -> Void)?
    #endif
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "PBGitWorktrees")
    private var state = WorktreeRefreshState()
    private let activityDrain = WorktreeActivityDrain()
    private var discovery: PBTask?
    private var discoveryTicket: WorktreeEvidenceTicket?
    private var deferredDiscoveryGeneration: UInt64?
    private var versionTask: PBTask?
    private var executable = ""
    private var lastProbeExecutable: WorktreeFileFingerprint?
    private var checkedExecutable: WorktreeFileFingerprint?
    private var versionGeneration = 0
    private var snapshot: [GitWorktree] = []
    private var repairOwnershipEvidence: WorktreeDiscoveryEvidence?
    private var lastRecoveredEvidence: UUID?
    private var recoveredMissingEvidence = false
    private var recoveryScheduled = false
    private var recoveryNeedsRead = false
    private var recoveryNeedsProbe = false
    private var operations: [UUID: WorktreeOperation] = [:]
    private var prunePreviews: Set<UUID> = []
    private var repairPreviews: Set<UUID> = []
    private var legacyPrunePreview: PBWorktreePrunePreview?
    private var configuredPreference: String?
    private var started = false
    private var preferenceCheckInFlight = false
    private var preferenceCheckPending = false
    @objc private(set) dynamic var isSnapshotStale = true
    @objc private(set) dynamic var hasPublishedSnapshot = false
    #if DEBUG
        @objc var discoveryEvidenceObserver: (@Sendable () -> Void)?
        @objc private(set) var ownershipCaptureCount: UInt = 0

        @objc var repairValidationObserver: (@Sendable () -> Void)?
        @objc var repairValidationResultObserver: (@MainActor @Sendable () -> Void)?
        @objc var repairPreparationResultObserver: (@MainActor @Sendable () -> Void)?
        @objc var preferenceFingerprintObserver: (@Sendable () -> Void)?
        @objc var preferenceFingerprintResultObserver: (@MainActor @Sendable () -> Void)?
        @objc var acceptedDiscoveryObserver: (@MainActor @Sendable () -> Void)?
        @objc private(set) dynamic var repairPreparationCount: UInt64 = 0
    #endif
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
        #if DEBUG
            repairPreparationObserver = nil
        #endif
        super.init()
    }

    @objc(initWithRepository:taskFactory:)
    init(repository: PBGitRepository, taskFactory: @escaping ([String]) -> PBTask) {
        self.repository = repository
        self.taskFactory = taskFactory
        #if DEBUG
            repairPreparationObserver = nil
        #endif
        super.init()
    }

    #if DEBUG
        @objc(initWithRepository:taskFactory:repairPreparationObserver:)
        init(repository: PBGitRepository, taskFactory: @escaping ([String]) -> PBTask, repairPreparationObserver: @escaping @Sendable () -> Void) {
            self.repository = repository
            self.taskFactory = taskFactory
            self.repairPreparationObserver = repairPreparationObserver
            super.init()
        }
    #endif

    private var preparationObserverForTesting: (@Sendable () -> Void)? {
        #if DEBUG
            repairPreparationObserver
        #else
            nil
        #endif
    }

    private var discoveryObserverForTesting: (@Sendable () -> Void)? {
        #if DEBUG
            discoveryEvidenceObserver
        #else
            nil
        #endif
    }

    private var validationObserverForTesting: (@Sendable () -> Void)? {
        #if DEBUG
            repairValidationObserver
        #else
            nil
        #endif
    }

    private var validationResultForTesting: (@MainActor @Sendable () -> Void)? {
        #if DEBUG
            repairValidationResultObserver
        #else
            nil
        #endif
    }

    private var preparationResultForTesting: (@MainActor @Sendable () -> Void)? {
        #if DEBUG
            repairPreparationResultObserver
        #else
            nil
        #endif
    }

    private var preferenceObserverForTesting: (@Sendable () -> Void)? {
        #if DEBUG
            preferenceFingerprintObserver
        #else
            nil
        #endif
    }

    private var preferenceResultForTesting: (@MainActor @Sendable () -> Void)? {
        #if DEBUG
            preferenceFingerprintResultObserver
        #else
            nil
        #endif
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
        DispatchQueue.main.async { [weak self] in self?.schedulePreferenceCheck() }
    }

    private func schedulePreferenceCheck() {
        guard !state.isClosed else { return }
        guard !preferenceCheckInFlight else { preferenceCheckPending = true; return }
        preferenceCheckInFlight = true
        preferenceCheckPending = false
        let selection = preferenceSelection()
        let observer = preferenceObserverForTesting
        let acknowledged = preferenceResultForTesting
        captureEvidence({
            observer?()
            return try WorktreeFileFingerprint.capture(path: selection.executable)
        }) { [weak self] result in
            defer { acknowledged?() }
            guard let self else { return }
            self.preferenceCheckInFlight = false
            guard !self.state.isClosed else {
                self.preferenceCheckPending = false
                self.logEvent(["--version"], stage: "cancelled", phase: "capability")
                return
            }
            guard selection == self.preferenceSelection() else {
                self.logEvent(["--version"], stage: "cancelled", phase: "capability", category: "context")
                if self.preferenceCheckPending {
                    self.schedulePreferenceCheck()
                }
                return
            }
            let fingerprint = try? result.get()
            if !selection.executable.utf8.elementsEqual(self.executable.utf8)
                || selection.preference != self.configuredPreference || fingerprint != self.lastProbeExecutable
            {
                self.checkVersion()
            }
            if self.preferenceCheckPending {
                self.schedulePreferenceCheck()
            }
        }
    }

    private func preferenceSelection() -> WorktreePreferenceSelection {
        WorktreePreferenceSelection(executable: Self.selectedExecutable(), preference: UserDefaults.standard.string(forKey: "gitExecutable"), generation: versionGeneration)
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
            || (try? WorktreeFileFingerprint.capture(path: selected)) != lastProbeExecutable
        if changed {
            checkVersion()
        }
        return changed
    }

    private func checkVersion() {
        defer { synchronizeFreshness() }
        guard !state.isClosed else { return }
        versionGeneration += 1
        let generation = versionGeneration
        // Cancellation and availability observers may synchronously enter this
        // service again. Publish the attempted selection before either callback.
        executable = Self.selectedExecutable()
        configuredPreference = UserDefaults.standard.string(forKey: "gitExecutable")
        let checking = try? WorktreeFileFingerprint.capture(path: executable)
        lastProbeExecutable = checking
        checkedExecutable = nil
        repairOwnershipEvidence = nil
        prunePreviews.removeAll()
        repairPreviews.removeAll()
        legacyPrunePreview = nil
        let retiredVersion = versionTask
        let retiredDiscovery = discovery
        versionTask = nil
        discovery = nil
        state.invalidate()
        discoveryTicket?.cancel()
        discoveryTicket = nil
        deferredDiscoveryGeneration = nil
        retiredVersion?.terminate()
        retiredDiscovery?.terminate()
        setAvailability(version: nil, supported: false)
        guard generation == versionGeneration, !state.isClosed else { return }
        cancelPreparationOperations()
        guard generation == versionGeneration, !state.isClosed, !executable.isEmpty else { return }
        let task = makeTask(["--version"])
        task.timeout = 10
        versionTask = task
        logEvent(["--version"], stage: "started", phase: "capability")
        performTask(task) { [weak self] data, error in
            guard let self, generation == self.versionGeneration, !self.state.isClosed else { return }
            let complete = self.versionTask?.standardOutputTruncated == false && self.versionTask?.standardErrorTruncated == false
            self.versionTask = nil
            let version = error == nil && complete ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let stable = checking != nil && (try? WorktreeFileFingerprint.capture(path: self.executable)) == checking
            self.checkedExecutable = stable ? checking : nil
            self.setAvailability(version: version, supported: stable && WorktreePolicy.supports(version: version))
            guard generation == self.versionGeneration, !self.state.isClosed else { return }
            self.logEvent(["--version"], stage: self.isSupported ? "completed" : "failed", phase: "capability", category: self.isSupported ? "none" : "capability")
            if self.isSupported {
                self.refresh()
            }
        }
    }

    private func setAvailability(version: String?, supported: Bool) {
        guard gitVersion != version || isSupported != supported else { return }
        let generation = versionGeneration
        let repository = repository
        repository?.willChangeValue(forKey: "worktreeFeatureAvailable")
        defer { repository?.didChangeValue(forKey: "worktreeFeatureAvailable") }
        guard generation == versionGeneration, !state.isClosed else { return }
        isSupported = supported
        guard generation == versionGeneration, !state.isClosed else { return }
        gitVersion = version
    }

    @objc(refresh)
    nonisolated func refresh() {
        onMain { self.refreshOnMain() }
    }

    private func refreshOnMain() {
        defer { synchronizeFreshness() }
        guard !refreshCapabilityIfChanged(), isSupported else { return }
        if let deferred = deferredDiscoveryGeneration {
            deferredDiscoveryGeneration = nil
            if state.accepts(deferred) {
                beginDiscovery(generation: deferred)
                return
            }
        }
        guard let generation = state.request() else { return }
        beginDiscovery(generation: generation)
    }

    private func beginDiscovery(generation: UInt64) {
        let capabilityGeneration = versionGeneration
        let ticket = WorktreeEvidenceTicket()
        discoveryTicket = ticket
        let task = makeTask(["worktree", "list", "--porcelain", "-z"])
        task.separatesStandardError = true
        task.timeout = 10
        discovery = task
        let common = Self.commonDirectory(gitDirectory: repository?.gitURL()?.path ?? "")
        let current = repository?.workingDirectoryURL()?.path ?? repository?.gitURL()?.path
        let observer = discoveryObserverForTesting
        logEvent(["worktree", "list"], stage: "started", phase: "discovery")
        performTask(task) { [weak self] data, error in
            guard let self, state.accepts(generation) else { return }
            let complete = discovery?.standardOutputTruncated == false && discovery?.standardErrorTruncated == false
            captureEvidence({
                if let error {
                    throw error
                }
                guard let data, complete else { throw WorktreeParseError.malformedRecord }
                try ticket.check()
                observer?()
                try ticket.check()
                return try WorktreeLinkInspector.inspect(WorktreeParser.parse(data), commonDirectory: common, currentPath: current)
            }) { [weak self] parsed in
                guard let self, state.accepts(generation) else { return }
                switch parsed {
                case let .failure(error): self.complete(.failure(error), generation: generation)
                case let .success(records):
                    // A retired parsed result never starts the ownership scan.
                    #if DEBUG
                        ownershipCaptureCount &+= 1
                    #endif
                    captureEvidence({
                        try WorktreeDiscoveryEvidence(records: records, commonDirectory: common, generation: capabilityGeneration,
                                                      checkCancellation: { try ticket.check() })
                    }) { [weak self] result in self?.complete(result, generation: generation) }
                }
            }
        }
    }

    private func complete(_ result: Result<WorktreeDiscoveryEvidence, Error>, generation: UInt64) {
        defer { synchronizeFreshness() }
        guard state.accepts(generation) else { return }
        discovery = nil
        discoveryTicket = nil
        lastRecoveredEvidence = nil
        recoveredMissingEvidence = false
        let succeeded: Bool
        switch result {
        case let .success(evidence):
            succeeded = true
            publish(evidence)
        case .failure:
            succeeded = false
            logEvent(["worktree", "list"], stage: "failed", phase: "discovery", category: "task")
        }
        if let next = state.complete(generation, succeeded: succeeded) {
            beginDiscovery(generation: next)
        }
    }

    private func synchronizeFreshness() {
        if isSnapshotStale != state.isStale {
            isSnapshotStale = state.isStale
        }
    }

    private func publish(_ evidence: WorktreeDiscoveryEvidence) {
        if !hasPublishedSnapshot {
            hasPublishedSnapshot = true
        }
        state.didPublishSnapshot()
        synchronizeFreshness()
        let records = evidence.records
        repairOwnershipEvidence = evidence
        lastRecoveredEvidence = nil
        recoveredMissingEvidence = false
        if case let .failure(error) = evidence.ownership {
            logEvent(["worktree", "list"], stage: "failed", phase: "discovery", count: records.count, category: "ownership")
            logger.debug("Worktree ownership capture failed: \(PBTaskDiagnostics.redacted(error.localizedDescription), privacy: .private)")
        }
        #if DEBUG
            defer { acceptedDiscoveryObserver?() }
        #endif
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
        defer { synchronizeFreshness() }
        state.close()
        discoveryTicket?.cancel()
        discoveryTicket = nil
        deferredDiscoveryGeneration = nil
        prunePreviews.removeAll()
        repairPreviews.removeAll()
        legacyPrunePreview = nil
        repairOwnershipEvidence = nil
        preferenceCheckPending = false
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
        let pending = Array(operations.values)
        // A read's completion can release the FIFO synchronously. Every queued
        // reservation must already be cancelled before that release admits it.
        pending.forEach { $0.markPreparationCancelled() }
        for operation in pending {
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
        case .prune, .repairLinks:
            completion(nil, failure("This operation requires a captured prune preview or repair ownership target.")); return
        default: break
        }
        let fail = requestFailure(command.arguments) { completion(nil, $0) }
        enqueueOperation(onFailure: fail) { operation in
            let requiresFreshInventory = self.state.isStale && self.hasPublishedSnapshot
            let previousRecords = self.snapshot
            let execute: @MainActor ([GitWorktree]) -> Void = { records in
                guard !requiresFreshInventory || WorktreeEligibility.allows(command, records: records, supported: self.isSupported, previousRecords: previousRecords) else {
                    self.finish(operation) { fail(self.failure("The worktree registration or eligibility changed. Review the refreshed worktree list before trying again.")) }
                    return
                }
                if case let .remove(path, _) = command,
                   let tree = records.first(where: { WorktreePaths.identity($0.path) == WorktreePaths.identity(path) }),
                   !WorktreeEligibility(tree, supported: self.isSupported).canRemove
                {
                    self.finish(operation) { completion(nil, self.failure("The main, current, or locked worktree cannot be removed. Unlock a linked worktree first.")) }; return
                }
                self.executeTask(command, operation: operation) { result in
                    switch result {
                    case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
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
            if requiresFreshInventory {
                self.discover(operation: operation) { result in
                    switch result {
                    case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                    case let .success(records): execute(records)
                    }
                }
            } else {
                execute(self.snapshot)
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
        let fail = requestFailure(["worktree", "prune"]) { completion(nil, $0) }
        enqueueOperation(onFailure: fail) { operation in
            self.capturePrunePreview(operation: operation) { result in
                self.finish(operation) {
                    switch result {
                    case let .success(preview): self.prunePreviews.insert(preview.identifier); completion(preview, nil)
                    case let .failure(error): fail(self.operationError(error))
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
        reviewPrunePreview(preview, refreshOnly: false, ownerIsCurrent: nil, completion: completion)
    }

    @objc(confirmPrune:ownerIsCurrent:completion:)
    func confirmPrune(_ preview: PBWorktreePrunePreview, ownerIsCurrent: @escaping @MainActor () -> Bool,
                      completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void)
    {
        reviewPrunePreview(preview, refreshOnly: false, ownerIsCurrent: ownerIsCurrent, completion: completion)
    }

    @objc(refreshPrunePreview:ownerIsCurrent:completion:)
    func refreshPrunePreview(_ preview: PBWorktreePrunePreview, ownerIsCurrent: @escaping @MainActor () -> Bool,
                             completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, Bool, NSError?) -> Void)
    {
        reviewPrunePreview(preview, refreshOnly: true, ownerIsCurrent: ownerIsCurrent) { updated, error in
            completion(updated, updated.map { !$0.matches(preview) } ?? false, error)
        }
    }

    private func reviewPrunePreview(_ preview: PBWorktreePrunePreview, refreshOnly: Bool,
                                    ownerIsCurrent: (@MainActor () -> Bool)?,
                                    completion: @escaping @MainActor @Sendable (PBWorktreePrunePreview?, NSError?) -> Void)
    {
        guard ownerIsCurrent?() != false else {
            discardPrunePreview(preview); completion(nil, Self.cancelledError()); return
        }
        guard prunePreviews.remove(preview.identifier) != nil else {
            completion(nil, failure("This prune preview was cancelled, consumed, or belongs to another repository. Preview it again.")); return
        }
        let fail = requestFailure(["worktree", "prune"]) { completion(nil, $0) }
        enqueueOperation(context: preview.context, onFailure: fail) { operation in
            guard ownerIsCurrent?() != false else { self.finish(operation) { fail(Self.cancelledError()) }; return }
            self.capturePrunePreview(operation: operation) { result in
                switch result {
                case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                case let .success(current):
                    guard ownerIsCurrent?() != false else { self.finish(operation) { fail(Self.cancelledError()) }; return }
                    guard !refreshOnly, current.matches(preview), current.checkoutLinks.permitsPrune, !current.rawReport.isEmpty else {
                        self.logEvent(["worktree", "prune"], stage: refreshOnly ? "completed" : "rejected", count: current.fingerprint.registrationCount, category: current.hasMovedWorktrees ? "moved" : "consent")
                        self.finish(operation) { self.prunePreviews.insert(current.identifier); completion(current, nil) }; return
                    }
                    self.executeTask(.prune, operation: operation) { result in
                        switch result {
                        case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
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
                        self.evidence(operation: operation, {
                            try WorktreePruneCheckoutEvidence(links: WorktreeLinkInspector.captureCheckoutLinkEvidence(records: records), consentRecords: records.map(WorktreeConsentRecord.init))
                        }) { links in
                            switch links {
                            case let .failure(error): completion(.failure(error))
                            case let .success(evidence):
                                self.capturePruneReport(operation: operation, fingerprint: fingerprint, records: records, checkoutEvidence: evidence, completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private func capturePruneReport(operation: WorktreeOperation, fingerprint: WorktreeAdministrativeFingerprint, records: [GitWorktree], checkoutEvidence: WorktreePruneCheckoutEvidence, completion: @escaping @MainActor @Sendable (Result<PBWorktreePrunePreview, Error>) -> Void) {
        let context = operation.context
        executeTask(.pruneReport, operation: operation) { report in
            switch report {
            case let .failure(error): completion(.failure(error))
            case let .success(bytes):
                self.evidence(operation: operation, {
                    guard let text = String(data: bytes, encoding: .utf8) else { throw WorktreeParseError.malformedRecord }
                    let inspected = WorktreeLinkInspector.inspect(records, commonDirectory: context.commonDirectory, currentPath: context.inspectionLocation)
                    let currentConsent = inspected.map(WorktreeConsentRecord.init)
                    let current = try WorktreeLinkInspector.administrativeFingerprint(commonDirectory: context.commonDirectory)
                    let currentLinks = try WorktreeLinkInspector.captureCheckoutLinkEvidence(records: inspected)
                    guard fingerprint.hasSameConsentEvidence(as: current), checkoutEvidence.links == currentLinks,
                          checkoutEvidence.consentRecords == currentConsent
                    else { throw WorktreeEvidenceError.changed(context.commonDirectory) }
                    return WorktreePruneEvidence(report: text, bytes: bytes, fingerprint: current, checkoutLinks: currentLinks, records: inspected, consentRecords: currentConsent)
                }) { checked in
                    completion(checked.map { PBWorktreePrunePreview(report: $0.report, rawReport: $0.bytes, context: context, fingerprint: $0.fingerprint, checkoutLinks: $0.checkoutLinks, records: $0.records, consentRecords: $0.consentRecords) })
                }
            }
        }
    }

    func beginRepair(worktree: PBGitWorktree, movedTo path: String,
                     ownerIsCurrent: @escaping @MainActor () -> Bool,
                     completion: @escaping @MainActor @Sendable (Result<WorktreeRepairStartResult, NSError>) -> Void)
    {
        requestRepair(selection: WorktreeRepairSelection(originalPath: worktree.path, path: path), style: nil,
                      ownerIsCurrent: ownerIsCurrent, startCompletion: completion)
    }

    func beginRepairLinks(style: WorktreeLinkStyle, ownerIsCurrent: @escaping @MainActor () -> Bool,
                          completion: @escaping @MainActor @Sendable (Result<WorktreeRepairStartResult, NSError>) -> Void)
    {
        requestRepair(selection: nil, style: style, ownerIsCurrent: ownerIsCurrent, startCompletion: completion)
    }

    #if DEBUG
        @objc(beginRepairForTestingWithWorktree:movedTo:relativePaths:ownerIsCurrent:completion:)
        func beginRepairForTesting(worktree: PBGitWorktree?, movedTo path: String?, relativePaths: Bool,
                                   ownerIsCurrent: @escaping @MainActor () -> Bool,
                                   completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, Bool, NSError?) -> Void)
        {
            let deliver: @MainActor @Sendable (Result<WorktreeRepairStartResult, NSError>) -> Void = { result in
                switch result {
                case .success(.completed): completion(nil, true, nil)
                case let .success(.requiresConsent(preview)): completion(preview, false, nil)
                case let .failure(error): completion(nil, false, error)
                }
            }
            if let worktree, let path {
                beginRepair(worktree: worktree, movedTo: path, ownerIsCurrent: ownerIsCurrent, completion: deliver)
            } else {
                beginRepairLinks(style: relativePaths ? .relative : .absolute, ownerIsCurrent: ownerIsCurrent, completion: deliver)
            }
        }

        @objc(refreshRepairPreviewForTesting:ownerIsCurrent:completion:)
        func refreshRepairPreviewForTesting(_ preview: PBWorktreeRepairPreview, ownerIsCurrent: @escaping @MainActor () -> Bool,
                                            completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, Bool, NSError?) -> Void)
        {
            refreshRepairPreview(preview, ownerIsCurrent: ownerIsCurrent) { result in
                switch result {
                case let .success(review): completion(review.preview, review.changed, nil)
                case let .failure(error): completion(nil, false, error)
                }
            }
        }
    #endif

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
        reviewRepairPreview(preview, refreshOnly: false, ownerIsCurrent: nil) { updated, _, error in completion(updated, error) }
    }

    func confirmRepair(_ preview: PBWorktreeRepairPreview, ownerIsCurrent: @escaping @MainActor () -> Bool,
                       completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void)
    {
        reviewRepairPreview(preview, refreshOnly: false, ownerIsCurrent: ownerIsCurrent) { updated, _, error in completion(updated, error) }
    }

    func refreshRepairPreview(_ preview: PBWorktreeRepairPreview, ownerIsCurrent: @escaping @MainActor () -> Bool,
                              completion: @escaping @MainActor @Sendable (Result<WorktreeRepairReview, NSError>) -> Void)
    {
        reviewRepairPreview(preview, refreshOnly: true, ownerIsCurrent: ownerIsCurrent) { updated, changed, error in
            if let error {
                completion(.failure(error))
            } else if let updated {
                completion(.success(WorktreeRepairReview(preview: updated, changed: changed)))
            } else {
                completion(.failure(self.failure("A fresh repair preview could not be prepared. Review the repair again.")))
            }
        }
    }

    private func reviewRepairPreview(_ preview: PBWorktreeRepairPreview, refreshOnly: Bool,
                                     ownerIsCurrent: (@MainActor () -> Bool)?,
                                     completion: @escaping @MainActor @Sendable (PBWorktreeRepairPreview?, Bool, NSError?) -> Void)
    {
        guard ownerIsCurrent?() != false else {
            discardRepairPreview(preview)
            completion(nil, false, Self.cancelledError())
            return
        }
        guard repairPreviews.remove(preview.identifier) != nil else {
            completion(nil, false, failure("This repair preview was cancelled, consumed, or belongs to another repository. Review the repair again."))
            return
        }
        let fail = requestFailure(["worktree", "repair"]) { completion(nil, false, $0) }
        enqueueOperation(context: preview.plan.context, onFailure: fail) { operation in
            self.discover(operation: operation) { discovered in
                switch discovered {
                case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                case let .success(records):
                    let old = preview.plan
                    self.evidence(operation: operation, {
                        let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: old.context.commonDirectory,
                                                                                 mainPath: records.first(where: \.isMain)?.path, selection: old.selection)
                        guard scope.canRenew(from: old.scope) else { throw WorktreeEvidenceError.changed(old.context.commonDirectory) }
                        return WorktreeRepairPlan(context: old.context, scope: scope, selection: old.selection, style: old.style)
                    }) { result in
                        switch result {
                        case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                        case let .success(current):
                            guard ownerIsCurrent?() != false else {
                                self.finish(operation) { fail(Self.cancelledError()) }
                                return
                            }
                            let changed = !current.scope.hasSameConsentEvidence(as: old.scope)
                            if refreshOnly || changed {
                                if changed {
                                    self.logEvent(["worktree", "repair"], stage: "rejected", count: current.scope.targets.count, category: "consent")
                                }
                                let renewed = PBWorktreeRepairPreview(plan: current)
                                self.finish(operation) {
                                    self.repairPreviews.insert(renewed.identifier)
                                    completion(renewed, changed, nil)
                                }
                            } else {
                                self.performRepair(current, operation: operation, ownerIsCurrent: ownerIsCurrent) { error in
                                    let reconciled = operation.phase == .reconciling
                                    self.finish(operation) {
                                        if let error, !reconciled {
                                            fail(error)
                                        } else {
                                            completion(nil, false, error)
                                        }
                                    }
                                }
                            }
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

    /// Request-bound identities precede the wait; the complete touch scope is captured after admission.
    private func requestRepair(selection: WorktreeRepairSelection?, style: WorktreeLinkStyle?,
                               completion: (@MainActor @Sendable (PBWorktreeRepairPreview?, NSError?) -> Void)? = nil,
                               legacyCompletion: (@MainActor @Sendable (NSError?) -> Void)? = nil,
                               ownerIsCurrent: (@MainActor () -> Bool)? = nil,
                               startCompletion: (@MainActor @Sendable (Result<WorktreeRepairStartResult, NSError>) -> Void)? = nil)
    {
        let fail = requestFailure(["worktree", "repair"]) { error in
            completion?(nil, error)
            legacyCompletion?(error)
            startCompletion?(.failure(error))
        }
        do {
            let context = try requestContext()
            guard let evidence = repairOwnershipEvidence, evidence.generation == versionGeneration else {
                throw failure("Worktree ownership evidence is unavailable. Refresh the repository before repairing its links.", underlying: WorktreeEvidenceError.unidentifiedRegistrations(context.commonDirectory))
            }
            let seeds: WorktreeRepairOwnershipSeeds
            do { seeds = try evidence.ownership.get() } catch {
                throw failure("Worktree ownership evidence could not be captured. Refresh the repository and review the repair again. " + error.localizedDescription,
                              underlying: error)
            }
            let selectedIdentity = try selection.map { try WorktreeFileIdentity.capture(path: $0.path) }
            let preparationObserver = preparationObserverForTesting
            let acknowledged = preparationResultForTesting
            enqueuePrepared(context: context, onFailure: fail, acknowledged: acknowledged, preparing: {
                preparationObserver?()
                return try WorktreeLinkInspector.captureRepairPreparation(seeds: seeds, commonDirectory: context.commonDirectory, selection: selection, selectedIdentity: selectedIdentity)
            }) { operation, preparation in
                self.discover(operation: operation) { discovered in
                    switch discovered {
                    case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                    case let .success(records):
                        self.evidence(operation: operation, {
                            let scope = try WorktreeLinkInspector.captureRepairScope(records: records, commonDirectory: context.commonDirectory, mainPath: records.first(where: \.isMain)?.path, preparation: preparation)
                            return WorktreeRepairPlan(context: context, scope: scope, selection: selection, style: style)
                        }) { captured in
                            switch captured {
                            case let .failure(error): self.finish(operation) { fail(self.operationError(error)) }
                            case let .success(plan):
                                guard ownerIsCurrent?() != false else {
                                    self.finish(operation) { fail(Self.cancelledError()) }
                                    return
                                }
                                if legacyCompletion != nil || startCompletion != nil, !plan.scope.requiresReclaim {
                                    self.performRepair(plan, operation: operation, ownerIsCurrent: ownerIsCurrent) { error in
                                        let reconciled = operation.phase == .reconciling
                                        self.finish(operation) {
                                            if let error, !reconciled {
                                                fail(error)
                                            } else if let error {
                                                legacyCompletion?(error); startCompletion?(.failure(error))
                                            } else {
                                                legacyCompletion?(nil); startCompletion?(.success(.completed))
                                            }
                                        }
                                    }
                                } else if let legacyCompletion {
                                    self.logEvent(["worktree", "repair"], stage: "rejected", count: plan.scope.targets.count, category: "consent")
                                    self.finish(operation) { legacyCompletion(self.failure("These checkout links require explicit Reclaim approval. Review a fresh repair preview before replacing them.")) }
                                } else {
                                    let preview = PBWorktreeRepairPreview(plan: plan)
                                    self.logEvent(["worktree", "repair"], stage: "completed", count: plan.scope.targets.count)
                                    self.finish(operation) {
                                        self.repairPreviews.insert(preview.identifier)
                                        completion?(preview, nil)
                                        startCompletion?(.success(.requiresConsent(preview)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch { fail(operationError(error)) }
    }

    private func performRepair(_ plan: WorktreeRepairPlan, operation: WorktreeOperation,
                               ownerIsCurrent: (@MainActor () -> Bool)? = nil, completion: @escaping @MainActor @Sendable (NSError?) -> Void)
    {
        // Fresh validation and launch retain one admission, without a consent callback or re-enqueue between them.
        let observer = validationObserverForTesting
        let acknowledged = validationResultForTesting
        evidence(operation: operation, {
            observer?()
            try WorktreeLinkInspector.validateRepairScope(plan.scope, commonDirectory: plan.context.commonDirectory)
        }, acknowledged: acknowledged) { validation in
            switch validation {
            case let .failure(error):
                self.logRejection(["worktree", "repair"], error: self.operationError(error), count: plan.scope.targets.count)
                completion(self.operationError(error))
            case .success:
                guard ownerIsCurrent?() != false else {
                    self.logEvent(["worktree", "repair"], stage: "cancelled", phase: "preparing", count: plan.scope.targets.count)
                    completion(Self.cancelledError())
                    return
                }
                self.executeTask(plan.command, operation: operation) { written in
                    switch written {
                    case let .failure(error): completion(self.operationError(error))
                    case .success:
                        self.discover(operation: operation, reconciling: true) { discovered in
                            switch discovered {
                            case let .failure(error): completion(self.reconciliationError("repair", error: error))
                            case let .success(records):
                                self.evidence(operation: operation, {
                                    try WorktreeLinkInspector.verifyRepairScope(plan.scope, records: records, commonDirectory: plan.context.commonDirectory, style: plan.effectiveStyle)
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
            let context = try requestContext()
            guard requested == nil || requested == context else { throw WorktreeEvidenceError.changed(context.gitDirectory) }
            guard let repository else { throw Self.cancelledError() }
            let operation = WorktreeOperation(context: context, repository: repository, acknowledged: activityDrain.begin())
            operations[operation.identifier] = operation
            operation.cancellation = { self.finish(operation) { onFailure(Self.cancelledError()) } }
            // The job retains the service and repository until the reserved admission is released.
            WorktreeMutationGate.enqueue(key: context.commonIdentity.pathIdentity) { finished in
                operation.admit(release: finished)
                guard operation.isActive else { return }
                do { try self.validateCurrentContext(context) } catch {
                    let failure = self.operationError(error)
                    self.finish(operation) { onFailure(failure) }
                    return
                }
                body(operation)
            }
            return operation
        } catch { onFailure(operationError(error)); return nil }
    }

    /// Reserve synchronously, then begin capture immediately even when an earlier writer owns admission.
    private func enqueuePrepared<Value: Sendable>(context: WorktreeOperationContext, onFailure: @escaping @MainActor @Sendable (NSError) -> Void, acknowledged: (@MainActor @Sendable () -> Void)? = nil, preparing: @escaping @Sendable () throws -> Value, body: @escaping @MainActor (WorktreeOperation, Value) -> Void) {
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
        evidence(operation: reserved, preparing, acknowledged: acknowledged) { result in
            if case .success = result {
                #if DEBUG
                    self.repairPreparationCount &+= 1
                #endif
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
        performTask(task) { [weak self] data, error in
            guard let self, operation.isActive, let deliver = operation.taskCompletion else { return }
            operation.taskCompletion = nil
            let ownedTask = operation.task
            operation.task = nil
            if let error {
                if readOnly, error is CancellationError || WorktreePresentationPolicy.isExpectedCancellation(error as NSError) {
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

    /// The operation owns this discovery; ordinary refresh, close and preferences cannot cancel reconciliation.
    private func discover(operation: WorktreeOperation, reconciling: Bool = false, completion: @escaping @MainActor @Sendable (Result<[GitWorktree], Error>) -> Void) {
        guard operation.isActive, operation.repository != nil else { return }
        defer { synchronizeFreshness() }
        let context = operation.context
        let reconciliationGeneration = reconciling ? state.beginReconciliation() : nil
        if reconciling {
            operation.beginReconciliation()
            let retired = discovery
            discovery = nil
            discoveryTicket?.cancel()
            discoveryTicket = nil
            retired?.terminate()
            if retired != nil {
                logEvent(["worktree", "list"], stage: "cancelled", phase: "discovery")
            }
            // A supported replacement must reread the completed write even if
            // the original executable can no longer perform reconciliation.
            if context.generation != versionGeneration {
                refreshOnMain()
            }
        }
        do {
            if reconciling {
                try context.validate()
            } else {
                try validateCurrentContext(context)
            }
        } catch {
            deliverDiscovery(.failure(error), context: context, operation: operation, reconciliationGeneration: reconciliationGeneration, completion: completion)
            return
        }
        let arguments = ["worktree", "list", "--porcelain", "-z"]
        let task = makeTask(arguments, context: context)
        task.separatesStandardError = true
        task.timeout = 10
        operation.task = task
        operation.discoveryCompletion = completion
        logEvent(arguments, stage: "started", phase: reconciling ? "reconciling" : "preparing")
        performTask(task) { [weak self] data, error in
            guard let self, operation.isActive, let deliver = operation.discoveryCompletion else { return }
            operation.discoveryCompletion = nil
            let complete = operation.task?.standardOutputTruncated == false && operation.task?.standardErrorTruncated == false
            operation.task = nil
            self.evidence(operation: operation, {
                if let error {
                    throw error
                }
                guard let data, complete else { throw WorktreeParseError.malformedRecord }
                return try WorktreeLinkInspector.inspect(WorktreeParser.parse(data), commonDirectory: context.commonDirectory, currentPath: context.inspectionLocation)
            }) { parsed in
                switch parsed {
                case let .failure(error):
                    self.deliverDiscovery(.failure(error), context: context, operation: operation, reconciliationGeneration: reconciliationGeneration, completion: deliver)
                case let .success(records):
                    guard self.canPublish(context) else {
                        self.finishReconciliation(operation: operation, generation: reconciliationGeneration, published: false)
                        deliver(.success(records))
                        return
                    }
                    #if DEBUG
                        self.ownershipCaptureCount &+= 1
                    #endif
                    self.evidence(operation: operation, checking: { check in
                        try WorktreeDiscoveryEvidence(records: records, commonDirectory: context.commonDirectory, generation: context.generation,
                                                      checkCancellation: check)
                    }) { result in
                        self.deliverDiscovery(result, context: context, operation: operation, reconciliationGeneration: reconciliationGeneration, completion: deliver)
                    }
                }
            }
        }
    }

    private func deliverDiscovery(_ result: Result<WorktreeDiscoveryEvidence, Error>, context: WorktreeOperationContext,
                                  operation: WorktreeOperation, reconciliationGeneration: UInt64?,
                                  completion: @escaping @MainActor @Sendable (Result<[GitWorktree], Error>) -> Void)
    {
        let published: Bool
        if case let .success(evidence) = result, canPublish(context) {
            publish(evidence)
            published = true
        } else {
            published = false
        }
        finishReconciliation(operation: operation, generation: reconciliationGeneration, published: published)
        completion(result.map(\.records))
    }

    private func finishReconciliation(operation: WorktreeOperation, generation: UInt64?, published: Bool) {
        defer { synchronizeFreshness() }
        if let generation,
           let next = state.completeReconciliation(generation, succeeded: published)
        {
            // The operation still owns admission. Enqueue its follow-up only
            // after release, before the operation's drainage acknowledgement.
            operation.afterRelease.append { [weak self] in
                guard let self, !state.isClosed else { return }
                let acknowledged = activityDrain.begin()
                DispatchQueue.main.async { [weak self] in
                    defer { acknowledged() }
                    guard let self, state.accepts(next) else { return }
                    deferredDiscoveryGeneration = next
                    logger.info("Rereading worktrees after owned reconciliation (published: \(published))")
                    refreshOnMain()
                }
            }
        }
    }

    private func canPublish(_ context: WorktreeOperationContext) -> Bool {
        !state.isClosed && isSupported && versionGeneration == context.generation && (try? captureContext()) == context
    }

    private func evidence<Value: Sendable>(operation: WorktreeOperation, _ work: @escaping @Sendable () throws -> Value, acknowledged: (@MainActor @Sendable () -> Void)? = nil, completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        evidence(operation: operation, checking: { _ in try work() }, acknowledged: acknowledged, completion: completion)
    }

    private func evidence<Value: Sendable>(operation: WorktreeOperation,
                                           checking work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value,
                                           acknowledged: (@MainActor @Sendable () -> Void)? = nil,
                                           completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void)
    {
        guard operation.isActive, !operation.isCancelled else { acknowledged?(); return }
        let context = operation.context
        let delivery = WorktreeEvidenceDelivery(completion)
        let identifier = UUID()
        let ticket = WorktreeEvidenceTicket()
        operation.evidenceCancellations[identifier] = { ticket.cancel(); delivery.completion = nil }
        captureEvidence({
            try ticket.check()
            try context.validate()
            let value = try work { try ticket.check() }
            try ticket.check()
            try context.validate()
            return value
        }) { [weak delivery] result in
            defer { acknowledged?() }
            guard let delivery else { return }
            let completion = delivery.completion
            delivery.completion = nil
            operation.evidenceCancellations.removeValue(forKey: identifier)
            guard operation.isActive, !operation.isCancelled else { return }
            completion?(result)
        }
    }

    #if DEBUG
        /// Fixtures cancel first, then wait for tasks, reservations and worker-result acknowledgements.
        @objc(drainForTestingWithCompletion:)
        func drainForTesting(completion: @escaping @MainActor @Sendable () -> Void) {
            activityDrain.drain(completion: completion)
        }
    #endif

    private func performTask(_ task: PBTask, completion: @escaping @MainActor @Sendable (Data?, Error?) -> Void) {
        let acknowledged = activityDrain.begin()
        task.perform { data, error in
            defer { acknowledged() }
            completion(data, error)
        }
    }

    private func captureEvidence<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value,
                                                  completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void)
    {
        let acknowledged = activityDrain.begin()
        Self.evidence(work) { result in
            defer { acknowledged() }
            completion(result)
        }
    }

    private nonisolated static func evidence<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value, completion: @escaping @MainActor @Sendable (Result<Value, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Only a new request may retire old consent and start a capability probe.
    private func requestContext() throws -> WorktreeOperationContext {
        guard !state.isClosed else { throw Self.cancelledError() }
        guard !refreshCapabilityIfChanged() else { throw WorktreeCapabilityError(message: "The selected Git executable changed. Review the operation again after Git is checked.") }
        return try captureContext()
    }

    /// Constant-size anchors are captured without changing availability or cancelling other operations.
    /// Complete inventories and repeated operation-owned validation run on the utility worker.
    private func captureContext() throws -> WorktreeOperationContext {
        guard !state.isClosed else { throw Self.cancelledError() }
        guard isSupported, let gitDirectory = repository?.gitURL()?.path, let checkedExecutable else { throw WorktreeCapabilityError(message: "The repository or selected Git is unavailable or changed. Review it after Git is checked.") }
        guard Self.selectedExecutable().utf8.elementsEqual(executable.utf8),
              configuredPreference == UserDefaults.standard.string(forKey: "gitExecutable"),
              try WorktreeFileFingerprint.capture(path: executable) == checkedExecutable
        else { throw WorktreeCapabilityError(message: "The selected Git executable changed. Review the operation again after Git is checked.") }
        let common = Self.commonDirectory(gitDirectory: gitDirectory)
        let commonIdentity = try WorktreeFileIdentity.capture(path: common)
        let gitIdentity = try WorktreeFileIdentity.capture(path: gitDirectory)
        let working = (repository?.workingDirectoryURL()?.path).map(WorktreePaths.canonical)
        let workingIdentity = try working.map { try WorktreeFileIdentity.capture(path: $0) }
        guard commonIdentity.kind == .directory, gitIdentity.kind == .directory, workingIdentity == nil || workingIdentity?.kind == .directory else { throw WorktreeEvidenceError.unsupportedObject(gitDirectory) }
        return WorktreeOperationContext(commonDirectory: WorktreePaths.canonical(common), commonIdentity: commonIdentity, gitDirectory: WorktreePaths.canonical(gitDirectory), gitIdentity: gitIdentity, executable: checkedExecutable, workingDirectory: working, workingIdentity: workingIdentity, generation: versionGeneration)
    }

    private func validateCurrentContext(_ context: WorktreeOperationContext) throws {
        do {
            guard try captureContext() == context else { throw WorktreeEvidenceError.changed(context.gitDirectory) }
        } catch let error as WorktreeCapabilityError { throw error }
        catch {
            if error is CancellationError || WorktreePresentationPolicy.isExpectedCancellation(error as NSError) {
                throw error
            }
            throw WorktreeContextError(underlying: error)
        }
    }

    private func requestFailure(_ arguments: [String], deliver: @escaping @MainActor @Sendable (NSError) -> Void) -> @MainActor @Sendable (NSError) -> Void {
        let origin = WorktreeEvidenceOrigin(identifier: repairOwnershipEvidence?.identifier, generation: versionGeneration)
        return { error in
            self.logRejection(arguments, error: error)
            deliver(error)
            self.scheduleRecovery(after: error, origin: origin)
        }
    }

    /// Recovery refreshes evidence, never the rejected request or its consent.
    private func scheduleRecovery(after error: NSError, origin: WorktreeEvidenceOrigin) {
        guard !state.isClosed, !WorktreePresentationPolicy.isExpectedCancellation(error) else { return }
        var cause: Error = error
        while let underlying = (cause as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            cause = underlying
        }
        let captureFailed = repairOwnershipEvidence.map { evidence in
            if case .failure = evidence.ownership {
                return true
            }
            return false
        } ?? false
        if cause is WorktreeCapabilityError {
            guard origin.generation == versionGeneration else { return }
            recoveryNeedsProbe = true
        } else if cause is WorktreeEvidenceError || captureFailed {
            let current = WorktreeEvidenceOrigin(identifier: repairOwnershipEvidence?.identifier, generation: versionGeneration)
            guard current == origin else { return }
            if let identifier = repairOwnershipEvidence?.identifier {
                guard lastRecoveredEvidence != identifier else { return }
                lastRecoveredEvidence = identifier
            } else {
                guard !recoveredMissingEvidence else { return }
                recoveredMissingEvidence = true
            }
            recoveryNeedsRead = true
        } else {
            return
        }
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        let acknowledged = activityDrain.begin()
        DispatchQueue.main.async { [weak self] in
            defer { acknowledged() }
            guard let self else { return }
            recoveryScheduled = false
            let probe = recoveryNeedsProbe
            let read = recoveryNeedsRead
            recoveryNeedsProbe = false
            recoveryNeedsRead = false
            guard !state.isClosed else { return }
            logger.info("Recovering worktree evidence after a rejected request (probe: \(probe), read: \(read))")
            if probe, refreshCapabilityIfChanged() {
                return
            }
            if read {
                refreshOnMain()
            }
        }
    }

    private func reconciliationError(_ operation: String, error: Error) -> NSError {
        failure("Git completed \(operation), but worktree state could not be reread: \(error.localizedDescription)", underlying: error)
    }

    private func operationError(_ error: Error) -> NSError {
        if error is CancellationError {
            return Self.cancelledError()
        }
        let value = error as NSError
        return value.domain == PBGitXErrorDomain || WorktreePresentationPolicy.isExpectedCancellation(value) ? value : failure(value.localizedFailureReason ?? value.localizedDescription, underlying: value)
    }

    private func failure(_ message: String, underlying: Error? = nil) -> NSError {
        RepositoryServiceError.make(description: "Worktree operation failed", failureReason: PBTaskDiagnostics.redacted(message), underlyingError: underlying)
    }

    private func logRejection(_ arguments: [String], error: NSError, count: Int = 0) {
        if WorktreePresentationPolicy.isExpectedCancellation(error) {
            logEvent(arguments, stage: "cancelled", count: count); return
        }
        var cause: Error = error
        while let underlying = (cause as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            cause = underlying
        }
        let category = cause is WorktreeCapabilityError ? "capability" : cause is WorktreeEvidenceError ? "ownership" : "context"
        logEvent(arguments, stage: "rejected", count: count, category: category)
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
    let consentRecords: [WorktreeConsentRecord]
}

private nonisolated struct WorktreePruneCheckoutEvidence: Sendable {
    let links: WorktreeCheckoutLinkEvidence
    let consentRecords: [WorktreeConsentRecord]
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
