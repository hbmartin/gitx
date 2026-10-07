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

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    func output(
        arguments: [String],
        input: String?,
        environment: [String: Any]?
    ) throws -> String {
        guard let repository else { throw Self.closedRepositoryError() }
        let task = repository.task(withArguments: arguments)
        if let input {
            task.standardInputData = Data(input.utf8)
        }
        if let environment {
            task.additionalEnvironment = environment
        }
        try task.launch()
        return task.standardOutputString() ?? ""
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
        try task.launch()
        return task.standardOutputString() ?? ""
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
        task.perform(on: DispatchQueue.global(qos: .userInitiated)) { data, error in
            completion(data, error)
        }
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
