import Foundation

@objc(PBGitCommandRunning)
protocol GitCommandRunning: AnyObject {
    func output(arguments: [String]) throws -> String
    func launch(arguments: [String]) throws
}

final class RepositoryGitCommandRunner: GitCommandRunning {
    private unowned let repository: PBGitRepository

    init(repository: PBGitRepository) {
        self.repository = repository
    }

    func output(arguments: [String]) throws -> String {
        try repository.outputOfTask(withArguments: arguments)
    }

    func launch(arguments: [String]) throws {
        _ = try repository.launchTask(withArguments: arguments)
    }
}

enum RepositoryServiceError {
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
