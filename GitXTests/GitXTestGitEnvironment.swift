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
            for (key, selected) in [
                ("GITX_VERIFICATION_SESSION", verificationSession),
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
        struct PublicationError: Error, Sendable, CustomStringConvertible {
            let operation: String
            let category: String
            let posixCode: Int32?

            var description: String {
                "Native progress publication failed: operation=\(operation) category=\(category) errno=\(posixCode.map(String.init) ?? "none")"
            }

            static func system(_ operation: String, code: Int32 = errno) -> Self {
                Self(operation: operation, category: "system", posixCode: code)
            }
        }

        @discardableResult
        static func write(
            _ record: [String: Any], prefix: String, directory: String,
            identity: String = UUID().uuidString,
            writeBytes: (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) },
            publish: (Int32, String, String) -> Int32 = { parent, source, destination in
                source.withCString { temporary in
                    destination.withCString { renameatx_np(parent, temporary, parent, $0, UInt32(RENAME_EXCL)) }
                }
            }
        ) throws -> URL {
            guard ["startup", "capture"].contains(prefix), UUID(uuidString: identity) != nil else {
                throw PublicationError(operation: "validate-record", category: "configuration", posixCode: nil)
            }
            let parent = directory.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard parent >= 0 else { throw PublicationError.system("open-directory") }
            defer { Darwin.close(parent) }
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0 else { throw PublicationError.system("inspect-directory") }
            guard parentInfo.st_uid == geteuid() else {
                throw PublicationError(operation: "validate-directory", category: "ownership", posixCode: nil)
            }
            let temporary = ".pending-\(identity)"
            let filename = "\(prefix)-\(getpid())-\(identity).json"
            let descriptor = temporary.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard descriptor >= 0 else { throw PublicationError.system("create-record") }
            defer {
                Darwin.close(descriptor)
                _ = temporary.withCString { unlinkat(parent, $0, 0) }
            }
            let data: Data
            do {
                data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            } catch {
                throw PublicationError(operation: "encode-record", category: "serialization", posixCode: nil)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = writeBytes(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw PublicationError.system("write-record", code: count == 0 ? EIO : errno) }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw PublicationError.system("flush-record") }
            guard publish(parent, temporary, filename) == 0 else { throw PublicationError.system("publish-record") }
            return URL(fileURLWithPath: directory).appendingPathComponent(filename)
        }
    }

    /// The supervisor creates this lease; observers hold it for their process lifetime.
    nonisolated final class GitXTestInvocationLease: Sendable {
        private let descriptor: Int32

        init(progressDirectory: String) throws {
            let root = URL(fileURLWithPath: progressDirectory).deletingLastPathComponent().path
            let parent = root.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard parent >= 0 else { throw GitXTestProgressRecords.PublicationError.system("open-lease-directory") }
            defer { Darwin.close(parent) }
            let descriptor = openat(parent, "invocation.lease", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GitXTestProgressRecords.PublicationError.system("open-lease") }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid(),
                  flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw GitXTestProgressRecords.PublicationError(operation: "validate-lease", category: "ownership", posixCode: code)
            }
            self.descriptor = descriptor
        }

        deinit { Darwin.close(descriptor) }
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

        struct Installation: Sendable {
            let outcome: Outcome
            let lease: GitXTestInvocationLease?
            let publicationFailure: GitXTestProgressRecords.PublicationError?
        }

        private static let installation: Installation = {
            let environment = ProcessInfo.processInfo.environment
            let launchID = UUID().uuidString
            var lease: GitXTestInvocationLease?
            if let directory = environment["GITX_TEST_PROGRESS_DIRECTORY"], !directory.isEmpty {
                // Capture remains optional; the test observer owns required startup reporting.
                lease = try? GitXTestInvocationLease(progressDirectory: directory)
            }
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
                do {
                    try GitXTestProgressRecords.write(record, prefix: "capture", directory: directory)
                } catch let error as GitXTestProgressRecords.PublicationError {
                    return Installation(outcome: outcome, lease: lease, publicationFailure: error)
                } catch {
                    return Installation(outcome: outcome, lease: lease, publicationFailure: .init(
                        operation: "publish-record", category: "unexpected", posixCode: nil
                    ))
                }
            }
            return Installation(outcome: outcome, lease: lease, publicationFailure: nil)
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
            // flock follows the open file description through dup2 and inherited stderr.
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                return Outcome(state: "unavailable", category: "lease", filename: filename)
            }
            guard redirect(descriptor) >= 0 else {
                return Outcome(state: "unavailable", category: "redirect", filename: filename)
            }
            return Outcome(state: "captured", category: nil, filename: filename)
        }
    }
    // swiftlint:enable unused_declaration
#endif
