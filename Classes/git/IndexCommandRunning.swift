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

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        writerCoordinator = IndexWriterRegistry.shared.coordinator(for: repository)
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
    private var ordinal: UInt = 0
    private var pending = 0
    private var depth = 0
    private var observers: [UUID: Observer] = [:]

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

    func perform<Value>(_ operation: String, _ body: () throws -> Value) throws -> Value {
        guard lock.try() else { throw Self.busyError() }
        stateLock.lock()
        let queuedOwner = depth == 0 && pending > 0
        stateLock.unlock()
        if queuedOwner {
            lock.unlock()
            throw Self.busyError()
        }
        return try withOwnedState(operation, scheduled: false, body)
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
        NSError(domain: "PBGitIndexMutationError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Another operation owns the Git index. Use the asynchronous operation or try again after it finishes."])
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
    @objc(PBIndexWriterCommandTestHarness)
    final nonisolated class IndexWriterCommandTestHarness: NSObject {
        @objc(writesIndexWithArguments:)
        static func writesIndex(arguments: [String]) -> Bool {
            IndexWriterCoordinator.writesIndex(arguments)
        }
    }
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

    func coordinator(for repository: PBGitRepository) -> IndexWriterCoordinator {
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
        if let existing = coordinators[key]?.value {
            return existing
        }
        coordinators = coordinators.filter { $0.value.value != nil }
        let coordinator = IndexWriterCoordinator()
        coordinators[key] = WeakIndexWriter(coordinator)
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
