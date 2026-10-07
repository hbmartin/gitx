import Foundation

@MainActor
final class GitXUITestFixtureWorkspace {
    private let prefix: String
    private(set) var directories: [URL] = []

    init(prefix: String) {
        self.prefix = prefix
    }

    func makeDirectory(named name: String) throws -> URL {
        // The app cannot read the runner's container when macOS protects another app's data.
        let directory = URL(fileURLWithPath: "/private/tmp/gitx-ui-fixtures", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    func makeIsolatedHome(named name: String = "isolated-home") throws -> URL {
        let home = try makeDirectory(named: name)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    func removeAll() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let selectedGit = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/git")
        process.executableURL = FileManager.default.isExecutableFile(atPath: selectedGit.path)
            ? selectedGit
            : URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }.merging([
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false",
            "GIT_CONFIG_KEY_1": "tag.gpgsign", "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "init.templateDir", "GIT_CONFIG_VALUE_2": "/dev/null",
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitXUITestFixtureError.commandFailed(arguments, result)
        }
        return result
    }
}

private enum GitXUITestFixtureError: Error {
    case commandFailed([String], String)
}
