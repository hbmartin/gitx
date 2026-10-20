#if !GITX_APP_TARGET || DEBUG
    import Darwin
    import Foundation

    /// Shared by diagnostic harnesses and XCTest fixtures, never by ordinary repository operations.
    nonisolated enum GitXTestGitEnvironment {
        static func isolated(
            _ inherited: [String: String] = ProcessInfo.processInfo.environment,
            verificationSession: String? = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"],
            nativeDiagnosticDirectory: String? = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"],
            progressDirectory: String? = ProcessInfo.processInfo.environment["GITX_TEST_PROGRESS_DIRECTORY"],
            invocationID: String? = ProcessInfo.processInfo.environment["GITX_TEST_INVOCATION_ID"]
        ) -> [String: String] {
            var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }.merging([
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false",
                "GIT_CONFIG_KEY_1": "tag.gpgsign", "GIT_CONFIG_VALUE_1": "false",
                "GIT_CONFIG_KEY_2": "init.templateDir", "GIT_CONFIG_VALUE_2": "/dev/null",
                "GIT_AUTHOR_NAME": "GitX Tests", "GIT_AUTHOR_EMAIL": "gitx-tests@example.invalid",
                "GIT_COMMITTER_NAME": "GitX Tests", "GIT_COMMITTER_EMAIL": "gitx-tests@example.invalid",
                "GCM_INTERACTIVE": "never", "GIT_ASKPASS": "/usr/bin/false", "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            ]) { _, value in value }
            if let verificationSession {
                environment["GITX_VERIFICATION_SESSION"] = verificationSession
            }
            for (key, selected) in [
                ("GITX_TEST_STDERR_DIRECTORY", nativeDiagnosticDirectory),
                ("GITX_TEST_PROGRESS_DIRECTORY", progressDirectory),
                ("GITX_TEST_INVOCATION_ID", invocationID),
            ] {
                if let selected, !selected.isEmpty {
                    environment[key] = selected
                } else {
                    environment.removeValue(forKey: key)
                }
            }
            return environment
        }
    }

    /// Publish complete records atomically without replacing any previous evidence.
    nonisolated enum GitXTestProgressRecords {
        @discardableResult
        static func write(_ record: [String: Any], prefix: String, directory: String) throws -> URL {
            let parent = directory.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard parent >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(parent) }
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == geteuid() else { throw POSIXError(.EIO) }
            let identity = UUID().uuidString
            let temporary = ".pending-\(identity)"
            let filename = "\(prefix)-\(getpid())-\(identity).json"
            let descriptor = temporary.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer {
                Darwin.close(descriptor)
                _ = temporary.withCString { unlinkat(parent, $0, 0) }
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
            let linked = temporary.withCString { temporaryName in
                filename.withCString { linkat(parent, temporaryName, parent, $0, 0) }
            }
            guard linked == 0 else { throw POSIXError(.EIO) }
            return URL(fileURLWithPath: directory).appendingPathComponent(filename)
        }
    }
#endif

#if GITX_APP_TARGET && DEBUG
    /// Optional managed-test diagnostics. File failures never abort application startup.
    // The Objective-C main entry point owns installation, outside Swift's call graph.
    // swiftlint:disable unused_declaration
    @objc(PBGitXTestProcessDiagnostics)
    final nonisolated class GitXTestProcessDiagnostics: NSObject {
        struct Outcome: Sendable {
            let state: String
            let category: String?
            let filename: String?
        }

        private static let installation: Outcome = {
            let environment = ProcessInfo.processInfo.environment
            let launchID = UUID().uuidString
            let outcome = install(directory: environment["GITX_TEST_STDERR_DIRECTORY"], launchID: launchID)
            if let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"], directory.hasPrefix("/"),
               let invocation = environment["GITX_TEST_INVOCATION_ID"], !invocation.isEmpty {
                var record: [String: Any] = [
                    "schemaVersion": 1, "event": "capture", "invocationID": invocation,
                    "verificationSession": environment["GITX_VERIFICATION_SESSION"] ?? "",
                    "pid": getpid(), "state": outcome.state,
                ]
                record["category"] = outcome.category
                record["filename"] = outcome.filename
                try? GitXTestProgressRecords.write(record, prefix: "capture", directory: directory)
            }
            return outcome
        }()

        @objc static func installAtApplicationStartup() {
            _ = installation
        }

        /// Injectable descriptor operations allow failure coverage without replacing XCTest's stderr.
        static func install(
            directory: String?, processIdentifier: Int32 = getpid(), launchID: String = UUID().uuidString,
            openCapture: ((Int32, String) -> Int32)? = nil,
            redirect: (Int32) -> Int32 = { dup2($0, STDERR_FILENO) }
        ) -> Outcome {
            guard let directory, !directory.isEmpty else {
                return Outcome(state: "not-requested", category: nil, filename: nil)
            }
            guard directory.hasPrefix("/"), UUID(uuidString: launchID) != nil else {
                return Outcome(state: "unavailable", category: "configuration", filename: nil)
            }
            let parent = directory.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard parent >= 0 else { return Outcome(state: "unavailable", category: "directory", filename: nil) }
            defer { Darwin.close(parent) }
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == geteuid() else {
                return Outcome(state: "unavailable", category: "directory", filename: nil)
            }
            let filename = "GitX-\(processIdentifier)-\(launchID).stderr.log"
            let descriptor = openCapture?(parent, filename) ?? filename.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_APPEND, 0o600)
            }
            guard descriptor >= 0 else { return Outcome(state: "unavailable", category: "open", filename: nil) }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid() else {
                return Outcome(state: "unavailable", category: "open", filename: nil)
            }
            guard redirect(descriptor) >= 0 else {
                return Outcome(state: "unavailable", category: "redirect", filename: filename)
            }
            return Outcome(state: "captured", category: nil, filename: filename)
        }
    }
    // swiftlint:enable unused_declaration
#endif
