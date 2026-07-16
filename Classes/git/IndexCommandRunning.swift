import Foundation

@objc(PBIndexCommandRunning)
protocol IndexCommandRunning: AnyObject {
    nonisolated func output(
        arguments: [String],
        input: String?,
        environment: [String: String]?
    ) throws -> String
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
        environment: [String: String]?
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
}
