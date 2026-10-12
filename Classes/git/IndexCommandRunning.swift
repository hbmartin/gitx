import Dispatch
import Foundation

@objc(PBIndexCommandRunning)
protocol IndexCommandRunning: NSObjectProtocol {
    nonisolated func output(
        arguments: [String],
        input: String?,
        environment: [String: Any]?
    ) throws -> String

    nonisolated func data(
        arguments: [String],
        completion: @escaping @Sendable (Data?, Error?) -> Void
    )
}

/// Byte input is an explicit capability. Existing text adapters keep their
/// protocol; filename mutations require this protocol for non-UTF-8 paths.
@objc(PBIndexBinaryCommandRunning)
protocol IndexBinaryCommandRunning: IndexCommandRunning {
    nonisolated func output(
        arguments: [String],
        inputData: Data?,
        environment: [String: Any]?
    ) throws -> String
}

/// Synchronous byte output preserves NUL-delimited status records, including
/// rename sources that cannot be decoded as UTF-8. Text adapters remain valid.
@objc(PBIndexRawOutputCommandRunning)
protocol IndexRawOutputCommandRunning: IndexCommandRunning {
    nonisolated func rawOutput(arguments: [String], environment: [String: Any]?) throws -> Data
}

final nonisolated class IndexRepositoryCommandRunner: NSObject, IndexBinaryCommandRunning, IndexRawOutputCommandRunning {
    private weak var repository: PBGitRepository?
    var repositoryForCommit: PBGitRepository? {
        repository
    }

    let writerCoordinator: IndexWriterCoordinator
    @objc var isWriterBusy: Bool {
        writerCoordinator.isBusy
    }

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        writerCoordinator = IndexWriterCoordinator.coordinator(for: repository)
        super.init()
    }

    func output(
        arguments: [String],
        input: String?,
        environment: [String: Any]?
    ) throws -> String {
        try output(arguments: arguments, inputData: input.map { Data($0.utf8) }, environment: environment)
    }

    func output(
        arguments: [String],
        inputData: Data?,
        environment: [String: Any]?
    ) throws -> String {
        guard let repository else { throw Self.closedRepositoryError() }
        let task = repository.task(withArguments: arguments)
        task.standardInputData = inputData
        if let environment {
            task.additionalEnvironment = environment
        }
        return try perform(arguments: arguments) {
            try task.launch()
            return task.standardOutputString() ?? ""
        }
    }

    func data(
        arguments: [String],
        completion: @escaping @Sendable (Data?, Error?) -> Void
    ) {
        guard let repository else {
            completion(nil, Self.closedRepositoryError())
            return
        }
        let task = repository.task(withArguments: arguments)
        task.separatesStandardError = true
        let transfer = IndexCommandTask(task)
        let coordinator = writerCoordinator
        let launch: @Sendable () -> Void = {
            do {
                try transfer.task.launch()
                completion(transfer.task.standardOutputData, nil)
            } catch { completion(transfer.task.standardOutputData, error) }
        }
        if IndexWriterCoordinator.writesIndex(arguments) {
            coordinator.schedule(arguments.joined(separator: " "), launch)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: launch)
        }
    }

    func rawOutput(arguments: [String], environment: [String: Any]?) throws -> Data {
        guard let repository else { throw Self.closedRepositoryError() }
        let task = repository.task(withArguments: arguments)
        task.separatesStandardError = true
        if let environment {
            task.additionalEnvironment = environment
        }
        return try perform(arguments: arguments) {
            try task.launch()
            return task.standardOutputData
        }
    }

    private func perform<Value>(arguments: [String], _ body: () throws -> Value) throws -> Value {
        if IndexWriterCoordinator.writesIndex(arguments) {
            return try writerCoordinator.perform(arguments.joined(separator: " "), body)
        }
        return try body()
    }

    private static func closedRepositoryError() -> NSError {
        NSError(domain: "PBGitIndexCommandError", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The repository closed before this operation could start.",
                comment: "Index command cancelled after repository close"
            ),
        ])
    }
}

@objc(PBIndexWriterState)
final nonisolated class IndexWriterState: NSObject, Sendable {
    @objc let pendingCount: Int
    @objc let activeCount: Int
    init(pendingCount: Int, activeCount: Int) {
        self.pendingCount = pendingCount
        self.activeCount = activeCount
        super.init()
    }
}

// swift6-safety-justification: The recursive writer lock protects nested ownership and command ordering. The state lock protects scheduling and observer snapshots.
final nonisolated class IndexWriterCoordinator: @unchecked Sendable {
    typealias Observer = @MainActor @Sendable (IndexWriterState) -> Void
    private let lock = NSRecursiveLock()
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "org.gitx.index-writer", qos: .userInitiated)
    private let queueIdentity = DispatchSpecificKey<Bool>()
    private var ordinal: UInt = 0
    private var pending = 0
    private var depth = 0
    private var observers: [UUID: Observer] = [:]

    init() {
        queue.setSpecific(key: queueIdentity, value: true)
    }

    var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pending > 0 || depth > 0
    }

    func observe(_ observer: @escaping Observer) -> UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        let identity = UUID()
        observers[identity] = observer
        let state = snapshot()
        DispatchQueue.main.async { observer(state) }
        return identity
    }

    func removeObserver(_ identity: UUID) {
        stateLock.lock()
        observers.removeValue(forKey: identity)
        stateLock.unlock()
    }

    func schedule(_ operation: String, _ body: @escaping @Sendable () -> Void) {
        schedule(operation, work: body, completion: { _ in })
    }

    func schedule<Value: Sendable>(_ operation: String, work: @escaping @Sendable () -> Value,
                                   completion: @escaping @Sendable (Value) -> Void)
    {
        stateLock.lock()
        pending += 1
        publishState()
        queue.async { [self] in
            lock.lock()
            let result = withOwnedState(operation, scheduled: true, work)
            // The writer and its idle observation are released before delivery.
            completion(result)
        }
        stateLock.unlock()
    }

    static func coordinator(for repository: PBGitRepository) -> IndexWriterCoordinator {
        IndexWriterRegistry.shared.coordinator(for: repository)
    }

    /// Synchronous admission for user submissions. Rejected work never joins
    /// the FIFO, while calls made by the owning thread remain reentrant.
    func performIfAvailable<Value>(_ operation: String, _ body: () throws -> Value) throws -> Value {
        guard lock.try() else {
            NSLog("[GitX] Index writer refused %@: another thread owns the index", operation)
            throw Self.busyError()
        }
        stateLock.lock()
        let available = depth > 0 || pending == 0
        stateLock.unlock()
        guard available else {
            lock.unlock()
            NSLog("[GitX] Index writer refused %@: earlier work is queued", operation)
            throw Self.busyError()
        }
        return try withOwnedState(operation, scheduled: false, body)
    }

    func perform<Value>(_ operation: String, _ body: () throws -> Value) throws -> Value {
        let onWriterQueue = DispatchQueue.getSpecific(key: queueIdentity) == true
        if lock.try() {
            stateLock.lock()
            let nested = depth > 0
            let queuedOwner = pending > 0
            stateLock.unlock()
            if nested || ((Thread.isMainThread || onWriterQueue) && !queuedOwner) {
                return try withOwnedState(operation, scheduled: false, body)
            }
            lock.unlock()
        }
        guard !Thread.isMainThread, !onWriterQueue else { throw Self.busyError() }
        // Background Git commands join the same FIFO as scheduled staging.
        // Its nonescaping body cannot outlive this call: wait completes before
        // withoutActuallyEscaping returns, including when the body throws.
        return try withoutActuallyEscaping(body) { work in
            let transfer = SynchronousIndexWriterWork(work)
            schedule(operation, work: { transfer.run() }, completion: { _ in transfer.signalCompletion() })
            return try transfer.wait()
        }
    }

    private func withOwnedState<Value>(_ operation: String, scheduled: Bool, _ body: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        if scheduled {
            pending -= 1
        }
        depth += 1
        publishState()
        stateLock.unlock()
        ordinal &+= 1
        let sequence = ordinal
        NSLog("[GitX] Index writer %llu began %@", UInt64(sequence), operation)
        defer {
            NSLog("[GitX] Index writer %llu completed %@", UInt64(sequence), operation)
            stateLock.lock()
            depth -= 1
            publishState()
            stateLock.unlock()
            lock.unlock()
        }
        return try body()
    }

    private func snapshot() -> IndexWriterState {
        IndexWriterState(pendingCount: pending, activeCount: depth > 0 ? 1 : 0)
    }

    /// Called under the state lock, which also fixes the order of main deliveries.
    private func publishState() {
        let state = snapshot()
        let deliveries = Array(observers.values)
        DispatchQueue.main.async { for observer in deliveries {
            observer(state)
        } }
    }

    static func busyError() -> NSError {
        NSError(domain: "PBGitIndexMutationError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Another operation owns the Git index. Wait for it to finish, then try again."])
    }

    static func writesIndex(_ arguments: [String]) -> Bool {
        var position = 0
        while position < arguments.count, arguments[position].hasPrefix("-") {
            let option = arguments[position]
            if ["-h", "--help", "--version"].contains(option) {
                return false
            }
            position += ["-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env"].contains(option) ? 2 : 1
        }
        guard position < arguments.count else { return false }
        let command = arguments[position]
        let options = arguments.dropFirst(position + 1).prefix { $0 != "--" }
        if options.contains("-h") || options.contains("--help") {
            return false
        }
        return ["update-index", "reset", "apply", "checkout-index", "write-tree", "commit-tree", "update-ref",
                "checkout", "switch", "restore", "stash", "merge", "cherry-pick", "rebase", "revert", "am", "pull", "branch", "tag"].contains(command)
    }
}

#if GITX_APP_TARGET && DEBUG
    extension IndexWriterCoordinator {
        nonisolated func withSuspendedQueueForTesting(_ body: () -> Void) {
            queue.suspend()
            defer { queue.resume() }
            body()
        }
    }

#endif

#if GITX_APP_TARGET && (DEBUG || GITX_PERFORMANCE_TEST_SUPPORT)
    // SwiftLint cannot follow XCTest's Objective-C bridge declarations.
    // swiftlint:disable unused_declaration
    @objc(PBIndexWriterCommandTestHarness)
    final nonisolated class IndexWriterCommandTestHarness: NSObject {
        @objc(allowsMutationForIndex:)
        static func allowsMutation(index: PBGitIndex) -> Bool {
            CommitSubmissionEligibility.allowsMutation(index)
        }

        #if DEBUG
            @objc(exerciseNonwaitingAdmissionAndReturnError:)
            static func exerciseNonwaitingAdmission() throws -> [NSNumber] {
                let writer = IndexWriterCoordinator()
                let finished = DispatchSemaphore(value: 0)
                var refusal: NSError?
                var executed = false
                writer.withSuspendedQueueForTesting {
                    writer.schedule("test queued admission", work: { 42 }, completion: { _ in finished.signal() })
                    do { try writer.performIfAvailable("test refused submission") { executed = true } }
                    catch { refusal = error as NSError }
                }
                let drained = finished.wait(timeout: .now() + 3) == .success
                let nested = try writer.performIfAvailable("test outer submission") {
                    try writer.performIfAvailable("test nested submission") { 7 }
                }
                var propagated = false
                do { try writer.performIfAvailable("test failed submission") { throw NSError(domain: "admission.fixture", code: 17) } }
                catch { propagated = (error as NSError).code == 17 }
                let recovered = try writer.performIfAvailable("test recovered submission") { 9 }
                return [NSNumber(value: refusal?.code ?? 0), NSNumber(value: executed), NSNumber(value: drained),
                        NSNumber(value: nested), NSNumber(value: propagated), NSNumber(value: recovered)]
            }

            @objc(exerciseSynchronousResultLifetimeAndReturnError:)
            static func exerciseSynchronousResultLifetime() throws -> NSNumber {
                var source: NSObject? = NSObject()
                weak let observed = source
                let transfer = SynchronousIndexWriterWork { source! }
                transfer.run()
                transfer.signalCompletion()
                source = nil
                try autoreleasepool { _ = try transfer.wait() }
                return withExtendedLifetime(transfer) { NSNumber(value: observed == nil) }
            }

            @objc(performFromCompletionForRepository:pendingWriter:completion:)
            @MainActor static func performFromCompletion(repository: PBGitRepository, pendingWriter: Bool,
                                                         completion: @escaping @MainActor @Sendable (NSError?) -> Void)
            {
                let writer = IndexWriterCoordinator.coordinator(for: repository)
                let task = IndexCommandTask(repository.task(withArguments: ["update-index"]))
                writer.schedule("test completion boundary", work: {
                    if pendingWriter {
                        writer.schedule("test pending completion writer") {}
                    }
                }, completion: { _ in
                    let error: NSError?
                    do {
                        try writer.perform("test completion command") { try task.task.launch() }
                        error = nil
                    } catch let failure { error = failure as NSError }
                    writer.schedule("test completion drained", work: {}, completion: { _ in
                        DispatchQueue.main.async { completion(error) }
                    })
                })
            }

            @objc(holdWriterForRepository:duringOwnership:)
            @MainActor static func holdWriter(repository: PBGitRepository, duringOwnership: @MainActor () -> Void) {
                let entered = DispatchSemaphore(value: 0)
                let release = DispatchSemaphore(value: 0)
                IndexWriterCoordinator.coordinator(for: repository).schedule("test held writer") {
                    entered.signal(); _ = release.wait(timeout: .now() + 10)
                }
                if entered.wait(timeout: .now() + 3) == .success {
                    duringOwnership()
                }
                release.signal()
            }

            @objc(writesIndexWithArguments:)
            static func writesIndex(arguments: [String]) -> Bool {
                IndexWriterCoordinator.writesIndex(arguments)
            }
        #endif
    }
    // swiftlint:enable unused_declaration
#endif

private final nonisolated class WeakIndexWriter {
    weak var value: IndexWriterCoordinator?
    init(_ value: IndexWriterCoordinator) {
        self.value = value
    }
}

// swift6-safety-justification: The registry lock protects weak coordinator lookup and creation; it never owns repositories.
private final nonisolated class IndexWriterRegistry: @unchecked Sendable {
    static let shared = IndexWriterRegistry()
    private let lock = NSLock()
    private var coordinators: [String: WeakIndexWriter] = [:]
    private var repositories: [ObjectIdentifier: WeakRepositoryIndexWriter] = [:]

    func coordinator(for repository: PBGitRepository) -> IndexWriterCoordinator {
        let identity = ObjectIdentifier(repository)
        lock.lock()
        if let cached = repositories[identity], cached.repository === repository, let writer = cached.writer {
            lock.unlock()
            return writer
        }
        lock.unlock()
        let directory = repository.gitURL()?.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = directory.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let key: String
        if let device = attributes?[.systemNumber], let inode = attributes?[.systemFileNumber] {
            key = "device:\(device):inode:\(inode)"
        } else {
            key = directory?.path ?? "repository:\(ObjectIdentifier(repository))"
        }
        lock.lock()
        defer { lock.unlock() }
        repositories = repositories.filter { $0.value.repository != nil && $0.value.writer != nil }
        if let existing = coordinators[key]?.value {
            repositories[identity] = WeakRepositoryIndexWriter(repository: repository, writer: existing)
            return existing
        }
        coordinators = coordinators.filter { $0.value.value != nil }
        let coordinator = IndexWriterCoordinator()
        coordinators[key] = WeakIndexWriter(coordinator)
        repositories[identity] = WeakRepositoryIndexWriter(repository: repository, writer: coordinator)
        return coordinator
    }
}

// swift6-safety-justification: A newly configured task is transferred once to a background queue; no other caller accesses or reuses it.
private final nonisolated class IndexCommandTask: @unchecked Sendable {
    let task: PBTask
    init(_ task: PBTask) {
        self.task = task
    }
}

private final nonisolated class WeakRepositoryIndexWriter {
    weak var repository: PBGitRepository?
    weak var writer: IndexWriterCoordinator?
    init(repository: PBGitRepository, writer: IndexWriterCoordinator) {
        self.repository = repository; self.writer = writer
    }
}

// swift6-safety-justification: The body is transferred to one serial writer. The semaphore publishes its result and guarantees both body and result are released before the synchronous caller returns.
private final nonisolated class SynchronousIndexWriterWork<Value>: @unchecked Sendable {
    private var body: (() throws -> Value)?
    private let completed = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?
    init(_ body: @escaping () throws -> Value) {
        self.body = body
    }

    func run() {
        executeAndReleaseBody()
    }

    func signalCompletion() {
        completed.signal()
    }

    private func executeAndReleaseBody() {
        result = Result(catching: body!)
        body = nil
    }

    func wait() throws -> Value {
        completed.wait()
        let delivered = result!
        result = nil
        return try delivered.get()
    }
}
