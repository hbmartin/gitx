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

final nonisolated class IndexRepositoryCommandRunner: NSObject, IndexBinaryCommandRunning {
    private weak var repository: PBGitRepository?
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let launch = { try transfer.task.launch(); return transfer.task.standardOutputData }
                let data = try IndexWriterCoordinator.writesIndex(arguments)
                    ? coordinator.perform(arguments.joined(separator: " "), launch) : launch()
                completion(data, nil)
            } catch {
                completion(transfer.task.standardOutputData, error)
            }
        }
    }

    private func perform<Value>(arguments: [String], _ body: () throws -> Value) rethrows -> Value {
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

// swift6-safety-justification: The recursive lock protects process ordering; synchronous nested commit commands stay on the owning thread.
final nonisolated class IndexWriterCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var ordinal: UInt = 0

    func perform<Value>(_ operation: String, _ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        ordinal &+= 1
        let sequence = ordinal
        NSLog("[GitX] Index writer %llu began %@", UInt64(sequence), operation)
        defer { NSLog("[GitX] Index writer %llu completed %@", UInt64(sequence), operation) }
        return try body()
    }

    static func writesIndex(_ arguments: [String]) -> Bool {
        guard !arguments.contains("-h"), !arguments.contains("--help") else { return false }
        let command = arguments.first { !$0.hasPrefix("-") } ?? ""
        return ["update-index", "reset", "apply", "checkout-index", "write-tree", "commit-tree", "update-ref"].contains(command)
    }
}

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
        let key = repository.gitURL()?.standardizedFileURL.path ?? "repository:\(ObjectIdentifier(repository))"
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
