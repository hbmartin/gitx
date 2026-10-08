import Dispatch
import Foundation

// Objective-C facade consumers are invisible to the Swift analyzer.
// swiftlint:disable unused_declaration

@objc(PBIndexMutationRequest)
final nonisolated class IndexMutationRequest: NSObject, Sendable {
    enum Operation: Sendable { case paths, discard, patch }
    let operation: Operation
    let stagePaths: [Data]
    let unstagePaths: [Data]
    let parentTree: String
    let patch: String
    let stage: Bool
    let reverse: Bool

    @objc(initWithStagePaths:unstagePaths:parentTree:)
    init(stagePaths: [Data], unstagePaths: [Data], parentTree: String) {
        operation = .paths
        self.stagePaths = stagePaths.map(Self.copy)
        self.unstagePaths = unstagePaths.map(Self.copy)
        self.parentTree = parentTree
        patch = ""; stage = false; reverse = false
        super.init()
    }

    @objc(initWithDiscardPaths:)
    init(discardPaths: [Data]) {
        operation = .discard
        stagePaths = discardPaths.map(Self.copy); unstagePaths = []
        parentTree = ""; patch = ""; stage = false; reverse = false
        super.init()
    }

    @objc(initWithPatch:stage:reverse:)
    init(patch: String, stage: Bool, reverse: Bool) {
        operation = .patch
        stagePaths = []; unstagePaths = []; parentTree = ""
        self.patch = patch; self.stage = stage; self.reverse = reverse
        super.init()
    }

    private static func copy(_ data: Data) -> Data {
        data.withUnsafeBytes { Data($0) }
    }
}

// swift6-safety-justification: Immutable callbacks cross the writer queue only to be invoked on main, and the repository token is released after that delivery.
private final nonisolated class IndexMutationDelivery: @unchecked Sendable {
    let repository: PBGitRepository
    let completion: (Bool, NSError?) -> Void
    init(repository: PBGitRepository, completion: @escaping (Bool, NSError?) -> Void) {
        self.repository = repository
        self.completion = completion
    }
}

// swift6-safety-justification: The lock protects closure; admitted work is serialized by the shared writer, and all callbacks and final repository releases happen on main.
@objc(PBIndexMutationCoordinator)
final nonisolated class IndexMutationCoordinator: NSObject, @unchecked Sendable {
    private weak var repository: PBGitRepository?
    private let service: IndexMutationService
    private let writer: IndexWriterCoordinator
    private let lock = NSLock()
    private var closed = false
    private var observation: UUID?
    private var deliveries: [UUID: IndexMutationDelivery] = [:]

    @objc(initWithRepository:service:stateHandler:)
    init(repository: PBGitRepository, service: IndexMutationService, stateHandler: @escaping @MainActor @Sendable (IndexWriterState) -> Void) {
        self.repository = repository
        self.service = service
        writer = IndexRepositoryCommandRunner(repository: repository).writerCoordinator
        super.init()
        observation = writer.observe(stateHandler)
    }

    deinit {
        if let observation {
            writer.removeObserver(observation)
        }
    }

    @objc func close() {
        lock.lock()
        closed = true
        let observation = self.observation
        self.observation = nil
        lock.unlock()
        if let observation {
            writer.removeObserver(observation)
        }
    }

    @objc(scheduleRequest:completion:)
    func schedule(request: IndexMutationRequest, completion: @escaping (Bool, NSError?) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let repository else { return false }
        let identity = UUID()
        deliveries[identity] = IndexMutationDelivery(repository: repository, completion: completion)
        writer.schedule("interactive mutation", work: { [self] in
            let result: (Bool, NSError?)
            lock.lock(); let isClosed = closed; lock.unlock()
            if isClosed {
                result = (false, NSError(domain: "PBGitIndexMutationError", code: 7, userInfo: [NSLocalizedDescriptionKey: "The repository closed before this operation could start."]))
            } else {
                var error: NSError?
                let success: Bool
                switch request.operation {
                case .paths: success = service.mutate(stageRawPaths: request.stagePaths, unstageRawPaths: request.unstagePaths, parentTree: request.parentTree, error: &error)
                case .discard: success = service.discardRawPaths(request.stagePaths, error: &error)
                case .patch: success = service.applyPatch(request.patch, stage: request.stage, reverse: request.reverse, error: &error)
                }
                result = (success, error)
            }
            return result
        }, completion: { [self] result in
            DispatchQueue.main.async {
                self.lock.lock()
                let delivery = self.deliveries.removeValue(forKey: identity)
                self.lock.unlock()
                if let delivery {
                    withExtendedLifetime(delivery) { delivery.completion(result.0, result.1) }
                }
            }
        })
        return true
    }
}
