import Dispatch
import Foundation

@objc(PBIndexCommandRunning)
protocol IndexCommandRunning: AnyObject {
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

final nonisolated class IndexRepositoryCommandRunner: NSObject, IndexCommandRunning {
    private unowned let repository: PBGitRepository

    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    func output(
        arguments: [String],
        input: String?,
        environment: [String: Any]?
    ) throws -> String {
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

    func data(
        arguments: [String],
        completion: @escaping @Sendable (Data?, Error?) -> Void
    ) {
        let task = repository.task(withArguments: arguments)
        task.perform(on: DispatchQueue.global(qos: .userInitiated)) { data, error in
            completion(data, error)
        }
    }
}
