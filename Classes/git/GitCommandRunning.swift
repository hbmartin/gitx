import Foundation

@objc(PBGitCommandRunning)
protocol GitCommandRunning: AnyObject {
    nonisolated func output(arguments: [String]) throws -> String
    nonisolated func launch(arguments: [String]) throws
    nonisolated var lastOutput: String? { get }
}

final nonisolated class RepositoryGitCommandRunner: GitCommandRunning {
    private unowned let repository: PBGitRepository
    private(set) var lastOutput: String?

    init(repository: PBGitRepository) {
        self.repository = repository
    }

    func output(arguments: [String]) throws -> String {
        try repository.outputOfTask(withArguments: arguments)
    }

    func launch(arguments: [String]) throws {
        let task = repository.task(withArguments: arguments)
        _ = try task.launch()
        lastOutput = task.standardOutputString()
    }
}

nonisolated enum RepositoryServiceError {
    static func make(
        description: String,
        failureReason: String,
        underlyingError: Error? = nil,
        userInfo: [String: Any] = [:]
    ) -> NSError {
        var info = userInfo
        info[NSLocalizedDescriptionKey] = description
        info[NSLocalizedFailureReasonErrorKey] = failureReason
        if let underlyingError {
            info[NSUnderlyingErrorKey] = underlyingError
        }
        return NSError(domain: PBGitXErrorDomain, code: 0, userInfo: info)
    }

    static func assign(_ error: NSError, to output: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        output?.pointee = error
        return false
    }
}
