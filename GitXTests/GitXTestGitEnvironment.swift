#if !GITX_APP_TARGET || DEBUG
    import Darwin
    import Foundation

    /// Shared by diagnostic harnesses and XCTest fixtures, never by ordinary repository operations.
    nonisolated enum GitXTestGitEnvironment {
        static func isolated(
            _ inherited: [String: String] = ProcessInfo.processInfo.environment,
            verificationSession: String? = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"],
            nativeDiagnosticDirectory: String? = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"]
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
            if let nativeDiagnosticDirectory {
                environment["GITX_TEST_STDERR_DIRECTORY"] = nativeDiagnosticDirectory
            }
            return environment
        }
    }

    /// XCTest's app stderr pipe can stop draining while it processes activity
    /// events. Keep native diagnostics in a run-owned file before any fixture
    /// starts work, without changing unified logging or the runner's stdout.
    nonisolated enum GitXTestProcessDiagnostics {
        private static let installation: Result<URL?, Error> = Result {
            guard let directory = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"] else { return nil }
            guard directory.hasPrefix("/") else { throw POSIXError(.EINVAL) }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("GitX-\(getpid()).stderr.log")
            let descriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_APPEND, 0o600)
            }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            guard dup2(descriptor, STDERR_FILENO) >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return url
        }

        static func installIfRequested() throws {
            _ = try installation.get()
        }

        static func installAtApplicationStartup() {
            do {
                try installIfRequested()
            } catch {
                fatalError("Could not retain native test stderr: \(error)")
            }
        }
    }
#endif
