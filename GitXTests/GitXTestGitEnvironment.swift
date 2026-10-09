#if !GITX_APP_TARGET || DEBUG
    import Foundation

    /// Shared by diagnostic harnesses and XCTest fixtures, never by ordinary repository operations.
    nonisolated enum GitXTestGitEnvironment {
        static func isolated(
            _ inherited: [String: String] = ProcessInfo.processInfo.environment,
            verificationSession: String? = ProcessInfo.processInfo.environment["GITX_VERIFICATION_SESSION"]
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
            return environment
        }
    }
#endif
