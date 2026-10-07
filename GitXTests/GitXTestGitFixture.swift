import Foundation

nonisolated struct GitXTestGitFixtureOutput {
    let standardOutput: String
    let standardError: String
}

/// PBTask drains both pipes while Git runs and owns timeout cleanup, including hook descendants.
nonisolated enum GitXTestGitFixture {
    @discardableResult
    static func run(
        _ arguments: [String],
        in directory: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: Data? = nil,
        timeout: TimeInterval = 10
    ) throws -> GitXTestGitFixtureOutput {
        let task = PBTask(launchPath: "/usr/bin/git", arguments: arguments, inDirectory: directory.path)
        task.setValue(GitXTestGitEnvironment.isolated(inheritedEnvironment), forKey: "environment")
        task.standardInputData = standardInput
        task.separatesStandardError = true
        task.timeout = timeout
        do {
            try task.launch()
        } catch {
            let diagnostic = String(decoding: task.standardErrorData, as: UTF8.self)
            throw NSError(
                domain: "GitXTestGitFixture", code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: "Git fixture command failed: \(diagnostic)", NSUnderlyingErrorKey: error]
            )
        }
        return GitXTestGitFixtureOutput(
            standardOutput: String(decoding: task.standardOutputData, as: UTF8.self),
            standardError: String(decoding: task.standardErrorData, as: UTF8.self)
        )
    }
}
