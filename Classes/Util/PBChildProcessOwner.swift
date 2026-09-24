import Darwin
import Dispatch
import Foundation
import os

nonisolated struct PBChildProcessConfiguration: Sendable {
    let launchPath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String?
    let standardInputFileDescriptor: Int32?
    let standardOutputFileDescriptor: Int32
}

nonisolated protocol PBChildProcessExitMonitoring: AnyObject, Sendable {
    func activate()
    func cancel()
}

nonisolated enum PBChildProcessExitState: Equatable, Sendable {
    case running
    case terminal
}

nonisolated protocol PBChildProcessSystem: Sendable {
    func spawn(configuration: PBChildProcessConfiguration) throws -> pid_t
    func makeExitMonitor(
        processIdentifier: pid_t,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> any PBChildProcessExitMonitoring
    func exitStateWithoutReaping(processIdentifier: pid_t) throws -> PBChildProcessExitState
    func reapIfExited(processIdentifier: pid_t) throws -> Int32?
    func send(signal: Int32, toProcessGroup processGroup: pid_t) throws
    func processGroupMembers(processGroup: pid_t) throws -> [pid_t]
}

nonisolated struct PBChildProcessTerminationSchedule: Equatable, Sendable {
    private(set) var terminationDeadline: UInt64?
    private(set) var forceKillDeadline: UInt64?

    mutating func mergeRequest(
        now: UInt64,
        gracePeriod: TimeInterval,
        forceKillDelay: TimeInterval?,
        terminationWasSent: Bool
    ) {
        let requestedTermination = Self.adding(Self.nanoseconds(for: gracePeriod), to: now)
        terminationDeadline = min(terminationDeadline ?? requestedTermination, requestedTermination)

        guard let forceKillDelay else { return }
        let forceKillBase = terminationWasSent ? now : terminationDeadline ?? requestedTermination
        let requestedForceKill = Self.adding(Self.nanoseconds(for: forceKillDelay), to: forceKillBase)
        forceKillDeadline = min(forceKillDeadline ?? requestedForceKill, requestedForceKill)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite else { return interval.sign == .minus ? 0 : .max }
        guard interval > 0 else { return 0 }
        let nanoseconds = interval * Double(NSEC_PER_SEC)
        return nanoseconds >= Double(UInt64.max) ? .max : UInt64(nanoseconds)
    }

    private static func adding(_ delay: UInt64, to now: UInt64) -> UInt64 {
        let (deadline, overflow) = now.addingReportingOverflow(delay)
        return overflow ? .max : deadline
    }
}

// swift6-safety-justification: Mutable lifecycle state is confined to the private serial queue.
final nonisolated class PBChildProcessOwner: @unchecked Sendable {
    typealias TerminationHandler = @Sendable (Int32, NSError?) -> Void

    private struct RunningProcess {
        let processIdentifier: pid_t
        let processGroup: pid_t
        let terminationHandler: TerminationHandler
        var exitMonitor: (any PBChildProcessExitMonitoring)?
        var schedule = PBChildProcessTerminationSchedule()
        var terminationWasSent = false
        var forceKillWasSent = false
        var leaderExitWasObserved = false
        var terminationTimerGeneration = 0
        var forceKillTimerGeneration = 0
        var reapRetryGeneration = 0
    }

    private enum State {
        case idle
        case running(RunningProcess)
        case finished
    }

    private static let reapRetryInterval: TimeInterval = 0.01
    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "PBChildProcess")

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let system: any PBChildProcessSystem
    private var state: State = .idle

    init(
        system: any PBChildProcessSystem = PBPosixChildProcessSystem(),
        queueLabel: String = "org.gitx.PBChildProcessOwner"
    ) {
        self.system = system
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: true)
    }

    func launch(
        configuration: PBChildProcessConfiguration,
        terminationHandler: @escaping TerminationHandler
    ) throws {
        try queue.sync {
            guard case .idle = state else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EALREADY),
                    userInfo: [NSLocalizedDescriptionKey: "Child process has already been launched"]
                )
            }

            let processIdentifier = try system.spawn(configuration: configuration)
            var process = RunningProcess(
                processIdentifier: processIdentifier,
                processGroup: processIdentifier,
                terminationHandler: terminationHandler
            )
            let exitMonitor = system.makeExitMonitor(
                processIdentifier: processIdentifier,
                queue: queue
            ) { [weak self] in
                self?.observeLeaderExit()
            }
            process.exitMonitor = exitMonitor
            state = .running(process)
            Self.logger.info(
                "Spawned child pid=\(processIdentifier, privacy: .public) pgid=\(processIdentifier, privacy: .public)"
            )
            exitMonitor.activate()

            // A child can exit between posix_spawn returning and the dispatch source
            // becoming active. It remains a zombie until this owner reaps it, so this
            // immediate non-reaping probe closes that notification-registration race.
            observeLeaderExit()
        }
    }

    @discardableResult
    func requestTermination(gracePeriod: TimeInterval, forceKillDelay: TimeInterval?) -> Bool {
        syncOnQueue {
            guard case var .running(process) = state else { return false }
            process.schedule.mergeRequest(
                now: DispatchTime.now().uptimeNanoseconds,
                gracePeriod: gracePeriod,
                forceKillDelay: forceKillDelay,
                terminationWasSent: process.terminationWasSent
            )
            state = .running(process)
            observeLeaderExit()
            guard case .running = state else { return false }
            scheduleTerminationTimer()
            scheduleForceKillTimer()
            return true
        }
    }

    private func syncOnQueue<Result>(_ body: () -> Result) -> Result {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return body()
        }
        return queue.sync(execute: body)
    }

    private func scheduleTerminationTimer() {
        guard case var .running(process) = state,
              !process.terminationWasSent,
              let deadline = process.schedule.terminationDeadline
        else { return }

        if deadline <= DispatchTime.now().uptimeNanoseconds {
            sendTerminationSignal()
            return
        }

        process.terminationTimerGeneration += 1
        let generation = process.terminationTimerGeneration
        state = .running(process)
        queue.asyncAfter(deadline: dispatchDeadline(deadline)) { [weak self] in
            guard let self,
                  case let .running(current) = state,
                  current.terminationTimerGeneration == generation,
                  !current.terminationWasSent
            else { return }
            sendTerminationSignal()
        }
    }

    private func scheduleForceKillTimer() {
        guard case var .running(process) = state,
              !process.forceKillWasSent,
              let deadline = process.schedule.forceKillDeadline
        else { return }

        if deadline <= DispatchTime.now().uptimeNanoseconds {
            sendForceKillSignal()
            return
        }

        process.forceKillTimerGeneration += 1
        let generation = process.forceKillTimerGeneration
        state = .running(process)
        queue.asyncAfter(deadline: dispatchDeadline(deadline)) { [weak self] in
            guard let self,
                  case let .running(current) = state,
                  current.forceKillTimerGeneration == generation,
                  !current.forceKillWasSent
            else { return }
            sendForceKillSignal()
        }
    }

    private func dispatchDeadline(_ uptimeNanoseconds: UInt64) -> DispatchTime {
        uptimeNanoseconds == .max ? .distantFuture : DispatchTime(uptimeNanoseconds: uptimeNanoseconds)
    }

    private func sendTerminationSignal() {
        guard case var .running(process) = state else { return }

        if observeLeaderExitBeforeSignal() {
            return
        }

        process.terminationWasSent = true
        process.terminationTimerGeneration += 1
        state = .running(process)
        signalProcessGroup(SIGTERM, label: "SIGTERM")
        observeLeaderExit()
    }

    private func sendForceKillSignal() {
        guard case var .running(process) = state else { return }

        if !process.terminationWasSent {
            process.terminationWasSent = true
            process.terminationTimerGeneration += 1
            state = .running(process)
            signalProcessGroup(SIGTERM, label: "SIGTERM")
            guard case let .running(updatedProcess) = state else { return }
            process = updatedProcess
        }

        if observeLeaderExitBeforeForceKill() {
            return
        }

        guard case var .running(current) = state else { return }
        current.forceKillWasSent = true
        current.forceKillTimerGeneration += 1
        state = .running(current)
        signalProcessGroup(SIGKILL, label: "SIGKILL")
        observeLeaderExit()
    }

    private func observeLeaderExitBeforeSignal() -> Bool {
        observeLeaderExit()
        guard case .running = state else { return true }
        return false
    }

    private func observeLeaderExitBeforeForceKill() -> Bool {
        observeLeaderExit()
        guard case let .running(process) = state else { return true }
        if process.leaderExitWasObserved, groupHasNoDescendants(process) {
            reapLeader(process)
            return true
        }
        return false
    }

    private func signalProcessGroup(_ signal: Int32, label: String) {
        guard case let .running(process) = state else { return }
        do {
            try system.send(signal: signal, toProcessGroup: process.processGroup)
            Self.logger.info(
                "Sent \(label, privacy: .public) to pgid=\(process.processGroup, privacy: .public)"
            )
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain &&
            (error.code == Int(ESRCH) || (error.code == Int(EPERM) && process.leaderExitWasObserved))
        {
            Self.logger.info(
                "Process group pgid=\(process.processGroup, privacy: .public) was gone before \(label, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                "Failed to send \(label, privacy: .public) to pgid=\(process.processGroup, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func observeLeaderExit() {
        guard case var .running(process) = state else { return }
        do {
            guard try system.exitStateWithoutReaping(processIdentifier: process.processIdentifier) == .terminal else {
                return
            }
            if !process.leaderExitWasObserved {
                process.leaderExitWasObserved = true
                state = .running(process)
                Self.logger.info(
                    "Observed child exit pid=\(process.processIdentifier, privacy: .public) without reaping"
                )
            }

            if shouldRetainLeaderForScheduledGroup(process) {
                return
            }
            reapLeader(process)
        } catch {
            finishWithSupervisionError(error, operation: "observe", process: process)
        }
    }

    private func shouldRetainLeaderForScheduledGroup(_ process: RunningProcess) -> Bool {
        guard process.schedule.terminationDeadline != nil,
              !groupHasNoDescendants(process)
        else { return false }
        if !process.terminationWasSent {
            return true
        }
        return process.schedule.forceKillDeadline != nil && !process.forceKillWasSent
    }

    private func groupHasNoDescendants(_ process: RunningProcess) -> Bool {
        do {
            let members = try system.processGroupMembers(processGroup: process.processGroup)
            return !members.contains { $0 > 0 && $0 != process.processIdentifier }
        } catch {
            Self.logger.error(
                "Could not inspect pgid=\(process.processGroup, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func reapLeader(_ process: RunningProcess) {
        do {
            guard let rawWaitStatus = try system.reapIfExited(processIdentifier: process.processIdentifier) else {
                scheduleReapRetry(process)
                return
            }
            Self.logger.info("Reaped child pid=\(process.processIdentifier, privacy: .public)")
            finish(process: process, rawWaitStatus: rawWaitStatus, error: nil)
        } catch {
            finishWithSupervisionError(error, operation: "reap", process: process)
        }
    }

    private func scheduleReapRetry(_ process: RunningProcess) {
        guard case var .running(current) = state,
              current.processIdentifier == process.processIdentifier,
              current.leaderExitWasObserved
        else { return }

        current.reapRetryGeneration += 1
        let generation = current.reapRetryGeneration
        state = .running(current)
        queue.asyncAfter(deadline: .now() + Self.reapRetryInterval) { [weak self] in
            guard let self,
                  case let .running(latest) = state,
                  latest.reapRetryGeneration == generation,
                  latest.leaderExitWasObserved
            else { return }
            reapLeader(latest)
        }
    }

    private func finishWithSupervisionError(_ error: Error, operation: String, process: RunningProcess) {
        let error = error as NSError
        Self.logger.error(
            "Could not \(operation, privacy: .public) child pid=\(process.processIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        finish(process: process, rawWaitStatus: 0, error: error)
    }

    private func finish(process: RunningProcess, rawWaitStatus: Int32, error: NSError?) {
        guard case let .running(current) = state,
              current.processIdentifier == process.processIdentifier
        else { return }
        current.exitMonitor?.cancel()
        state = .finished
        current.terminationHandler(rawWaitStatus, error)
    }
}

// swift6-safety-justification: The immutable dispatch source is thread-safe and owns its handler.
private final nonisolated class PBDispatchProcessExitMonitor: PBChildProcessExitMonitoring, @unchecked Sendable {
    private let source: DispatchSourceProcess

    init(source: DispatchSourceProcess, handler: @escaping @Sendable () -> Void) {
        self.source = source
        source.setEventHandler(handler: handler)
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

nonisolated struct PBPosixChildProcessSystem: PBChildProcessSystem {
    private struct PreparedDescriptors {
        let standardInput: Int32?
        let standardOutput: Int32
        let duplicatedDescriptors: [Int32]
    }

    func spawn(configuration: PBChildProcessConfiguration) throws -> pid_t {
        try validate(configuration: configuration)
        let descriptors = try prepareDescriptors(configuration: configuration)
        defer { descriptors.duplicatedDescriptors.forEach { Darwin.close($0) } }

        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions), operation: "initialize spawn file actions")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory = configuration.workingDirectory {
            try workingDirectory.withCString { path in
                if #available(macOS 26.0, *) {
                    try check(
                        posix_spawn_file_actions_addchdir(&fileActions, path),
                        operation: "configure child working directory"
                    )
                } else {
                    try check(
                        posix_spawn_file_actions_addchdir_np(&fileActions, path),
                        operation: "configure child working directory"
                    )
                }
            }
        }

        if let inputFileDescriptor = descriptors.standardInput {
            try check(
                posix_spawn_file_actions_adddup2(&fileActions, inputFileDescriptor, STDIN_FILENO),
                operation: "configure child standard input"
            )
        } else {
            errno = 0
            if fcntl(STDIN_FILENO, F_GETFD) == -1 {
                let code = errno
                guard code == EBADF else { throw posixError(code, operation: "inspect child standard input") }
                try "/dev/null".withCString { path in
                    try check(
                        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, path, O_RDONLY, 0),
                        operation: "open null child standard input"
                    )
                }
            } else {
                try check(
                    posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO),
                    operation: "inherit child standard input"
                )
            }
        }

        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                descriptors.standardOutput,
                STDOUT_FILENO
            ),
            operation: "configure child standard output"
        )
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                descriptors.standardOutput,
                STDERR_FILENO
            ),
            operation: "configure child standard error"
        )
        let childSourceDescriptors = Set([descriptors.standardInput, descriptors.standardOutput].compactMap { $0 })
        for descriptor in childSourceDescriptors {
            try check(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close child pipe source"
            )
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try check(
            posix_spawnattr_setsigmask(&attributes, &signalMask),
            operation: "configure child signal mask"
        )

        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        try check(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            operation: "configure child signal defaults"
        )
        try check(posix_spawnattr_setpgroup(&attributes, 0), operation: "create child process group")

        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETPGROUP |
                POSIX_SPAWN_SETSIGDEF |
                POSIX_SPAWN_SETSIGMASK
        )
        try check(posix_spawnattr_setflags(&attributes, flags), operation: "configure spawn flags")

        let argumentStrings = [configuration.launchPath] + configuration.arguments
        let environmentStrings = configuration.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        return try withCStringArray(argumentStrings) { arguments in
            try withCStringArray(environmentStrings) { environment in
                var processIdentifier = pid_t()
                let result = configuration.launchPath.withCString { executable in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
                try check(result, operation: "spawn child process")
                return processIdentifier
            }
        }
    }

    func makeExitMonitor(
        processIdentifier: pid_t,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> any PBChildProcessExitMonitoring {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        return PBDispatchProcessExitMonitor(source: source, handler: handler)
    }

    func exitStateWithoutReaping(processIdentifier: pid_t) throws -> PBChildProcessExitState {
        var information = siginfo_t()
        while true {
            if waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT) == 0 {
                guard information.si_pid == processIdentifier else { return .running }
                switch information.si_code {
                case CLD_EXITED, CLD_KILLED, CLD_DUMPED:
                    return .terminal
                default:
                    return .running
                }
            }
            if errno != EINTR {
                throw posixError(errno, operation: "observe child exit")
            }
        }
    }

    func reapIfExited(processIdentifier: pid_t) throws -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                return status
            }
            if result == 0 {
                return nil
            }
            if result == -1, errno != EINTR {
                throw posixError(errno, operation: "reap child process")
            }
        }
    }

    func send(signal: Int32, toProcessGroup processGroup: pid_t) throws {
        guard killpg(processGroup, signal) == 0 else {
            throw posixError(errno, operation: "signal child process group")
        }
    }

    func processGroupMembers(processGroup: pid_t) throws -> [pid_t] {
        var capacity = 16
        while true {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let processCount = processIdentifiers.withUnsafeMutableBytes { buffer in
                proc_listpgrppids(
                    processGroup,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard processCount >= 0, processCount != 0 || errno == 0 else {
                throw posixError(errno, operation: "inspect child process group")
            }
            let count = Int(processCount)
            if count < capacity {
                return Array(processIdentifiers.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
    }

    private func validate(configuration: PBChildProcessConfiguration) throws {
        let strings = [configuration.launchPath] + configuration.arguments +
            configuration.environment.map { "\($0.key)=\($0.value)" } +
            [configuration.workingDirectory].compactMap { $0 }
        if strings.contains(where: { $0.utf8.contains(0) }) {
            throw posixError(EINVAL, operation: "validate child process configuration")
        }
        if let workingDirectory = configuration.workingDirectory {
            try workingDirectory.withCString { path in
                guard access(path, F_OK) == 0 else {
                    throw posixError(errno, operation: "validate child working directory")
                }
            }
        }
    }

    private func prepareDescriptors(configuration: PBChildProcessConfiguration) throws -> PreparedDescriptors {
        var duplicatedDescriptors: [Int32] = []
        do {
            let standardInput = try configuration.standardInputFileDescriptor.map {
                try prepareSourceDescriptor($0, operation: "prepare child standard input", owned: &duplicatedDescriptors)
            }
            let standardOutput = try prepareSourceDescriptor(
                configuration.standardOutputFileDescriptor,
                operation: "prepare child standard output",
                owned: &duplicatedDescriptors
            )
            return PreparedDescriptors(
                standardInput: standardInput,
                standardOutput: standardOutput,
                duplicatedDescriptors: duplicatedDescriptors
            )
        } catch {
            duplicatedDescriptors.forEach { Darwin.close($0) }
            throw error
        }
    }

    private func prepareSourceDescriptor(
        _ descriptor: Int32,
        operation: String,
        owned duplicatedDescriptors: inout [Int32]
    ) throws -> Int32 {
        errno = 0
        guard fcntl(descriptor, F_GETFD) != -1 else {
            throw posixError(errno == 0 ? EBADF : errno, operation: operation)
        }
        guard descriptor <= STDERR_FILENO else { return descriptor }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicate != -1 else {
            throw posixError(errno, operation: operation)
        }
        duplicatedDescriptors.append(duplicate)
        return duplicate
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for value in strings {
            guard let pointer = strdup(value) else {
                throw posixError(ENOMEM, operation: "allocate child process arguments")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw posixError(result, operation: operation) }
    }

    private func posixError(_ code: Int32, operation: String) -> NSError {
        let reason = String(cString: strerror(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation): \(reason)",
                NSLocalizedFailureReasonErrorKey: reason,
            ]
        )
    }
}

#if GITX_APP_TARGET
    // This bridge is referenced only by Objective-C PBTask.m.
    // swiftlint:disable unused_declaration
    @objc(PBChildProcessSupervisor)
    final nonisolated class PBChildProcessSupervisor: NSObject {
        private let configuration: PBChildProcessConfiguration
        private let terminationHandler: PBChildProcessOwner.TerminationHandler
        private let owner = PBChildProcessOwner()

        @objc(
            initWithLaunchPath:arguments:environment:workingDirectory:standardInputFileDescriptor:standardOutputFileDescriptor:terminationHandler:
        )
        init(
            launchPath: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: String?,
            standardInputFileDescriptor: NSNumber?,
            standardOutputFileDescriptor: Int32,
            terminationHandler: @escaping @Sendable (Int32, NSError?) -> Void
        ) {
            configuration = PBChildProcessConfiguration(
                launchPath: launchPath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                standardInputFileDescriptor: standardInputFileDescriptor?.int32Value,
                standardOutputFileDescriptor: standardOutputFileDescriptor
            )
            self.terminationHandler = terminationHandler
        }

        @objc(launchAndReturnError:)
        func launch() throws {
            try owner.launch(configuration: configuration, terminationHandler: terminationHandler)
        }

        @objc(requestTerminationAfterGracePeriod:forceKillAfter:)
        func requestTermination(gracePeriod: TimeInterval, forceKillDelay: NSNumber?) {
            owner.requestTermination(
                gracePeriod: gracePeriod,
                forceKillDelay: forceKillDelay?.doubleValue
            )
        }

        @objc(requestImmediateTermination)
        func requestImmediateTermination() {
            owner.requestTermination(gracePeriod: 0, forceKillDelay: nil)
        }

        @objc(requestTimeoutTerminationWithForceKillAfter:)
        func requestTimeoutTermination(forceKillDelay: TimeInterval) -> Bool {
            owner.requestTermination(gracePeriod: 0, forceKillDelay: forceKillDelay)
        }
    }
    // swiftlint:enable unused_declaration
#endif
