import Foundation

/// Finder can create metadata while a fixture's document window is open.
/// Keep that ambient output out of fixture status without hiding tracked files.
@objc(GitXUITestRepositoryPolicy)
public final nonisolated class GitXUITestRepositoryPolicy: NSObject {
    @objc(excludeFinderMetadataInRepositoryAtPath:error:)
    public static func excludeFinderMetadata(inRepositoryAtPath path: String) throws {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let location = try executeGit(["rev-parse", "--git-path", "info/exclude"], in: root).trimmingCharacters(in: .newlines)
        let exclude = location.hasPrefix("/") ? URL(fileURLWithPath: location) : root.appendingPathComponent(location)
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        var contents = FileManager.default.fileExists(atPath: exclude.path) ? try Data(contentsOf: exclude) : Data()
        let rule = Data(".DS_Store".utf8)
        let exists = contents.split(separator: 10).contains { line in
            let bytes = line.last == 13 ? line.dropLast() : line[...]
            return Data(bytes) == rule
        }
        guard !exists else { return }
        if !contents.isEmpty, contents.last != 10 {
            contents.append(10)
        }
        contents.append(rule); contents.append(10)
        try contents.write(to: exclude, options: .atomic)
    }

    /// All UI fixture creation goes through this command boundary, including
    /// clones and the Objective-C screenshot fixtures.
    @objc(runGitArguments:inDirectory:error:)
    @discardableResult
    public static func runGit(_ arguments: [String], inDirectory path: String) throws -> String {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let result = try executeGit(arguments, in: directory)
        if let target = createdWorkingRepository(arguments, in: directory) {
            try excludeFinderMetadata(inRepositoryAtPath: target.path)
        }
        return result
    }

    private static func createdWorkingRepository(_ arguments: [String], in directory: URL) -> URL? {
        guard let command = arguments.first, ["init", "clone"].contains(command), !arguments.contains("--bare"), !arguments.contains("--mirror") else { return nil }
        let valuedOptions = Set(["-b", "--initial-branch", "--template", "--separate-git-dir", "--object-format", "--ref-format", "--branch", "-c", "--config", "-o", "--origin", "--depth", "--reference"])
        var operands: [String] = []; var position = 1
        while position < arguments.count {
            let argument = arguments[position]
            if valuedOptions.contains(argument) {
                position += 2; continue
            }
            if !argument.hasPrefix("-") {
                operands.append(argument)
            }
            position += 1
        }
        let destination: String?
        if command == "init" {
            destination = operands.last
        } else {
            // Fixture clones always specify their isolated destination.
            guard operands.count >= 2 else { return nil }
            destination = operands.last
        }
        guard let destination else { return directory }
        return destination.hasPrefix("/") ? URL(fileURLWithPath: destination, isDirectory: true) : directory.appendingPathComponent(destination, isDirectory: true)
    }

    private static func executeGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let selectedGit = URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/git")
        process.executableURL = FileManager.default.isExecutableFile(atPath: selectedGit.path) ? selectedGit : URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = GitXTestGitEnvironment.isolated()
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw GitXUITestFixtureError.commandFailed(arguments, result) }
        return result
    }
}

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
        try GitXUITestRepositoryPolicy.runGit(arguments, inDirectory: directory.path)
    }
}

private enum GitXUITestFixtureError: Error {
    case commandFailed([String], String)
}
