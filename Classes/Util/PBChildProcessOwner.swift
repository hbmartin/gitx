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

nonisolated protocol PBChildProcessSystem: Sendable {
    func spawn(configuration: PBChildProcessConfiguration) throws -> pid_t
    func makeExitMonitor(
        processIdentifier: pid_t,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> any PBChildProcessExitMonitoring
    func hasExitedWithoutReaping(processIdentifier: pid_t) throws -> Bool
    func reap(processIdentifier: pid_t) throws -> Int32
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

final nonisolated class PBChildProcessOwner: @unchecked Sendable {
    typealias TerminationHandler = @Sendable (Int32) -> Void

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
        var exitPollGeneration = 0
        var groupPollGeneration = 0
    }

    private enum State {
        case idle
        case running(RunningProcess)
        case finished
    }

    private static let pollInterval: TimeInterval = 0.05
    private static let logger = Logger(subsystem: "net.phere.GitX", category: "PBChildProcess")

    private let queue: DispatchQueue
    private let system: any PBChildProcessSystem
    private var state: State = .idle

    init(
        system: any PBChildProcessSystem = PBPosixChildProcessSystem(),
        queueLabel: String = "org.gitx.PBChildProcessOwner"
    ) {
        self.system = system
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
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
            scheduleExitPoll()
        }
    }

    func requestTermination(gracePeriod: TimeInterval, forceKillDelay: TimeInterval?) {
        queue.async { [weak self] in
            guard let self, case var .running(process) = state else { return }
            process.schedule.mergeRequest(
                now: DispatchTime.now().uptimeNanoseconds,
                gracePeriod: gracePeriod,
                forceKillDelay: forceKillDelay,
                terminationWasSent: process.terminationWasSent
            )
            state = .running(process)
            scheduleTerminationTimer()
            scheduleForceKillTimer()
        }
    }

    private func scheduleTerminationTimer() {
        guard case var .running(process) = state,
              !process.terminationWasSent,
              let deadline = process.schedule.terminationDeadline
        else { return }

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
        current.groupPollGeneration += 1
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
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ESRCH) {
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
            guard try system.hasExitedWithoutReaping(processIdentifier: process.processIdentifier) else { return }
            if !process.leaderExitWasObserved {
                process.leaderExitWasObserved = true
                state = .running(process)
                Self.logger.info(
                    "Observed child exit pid=\(process.processIdentifier, privacy: .public) without reaping"
                )
            }

            guard process.terminationWasSent,
                  process.schedule.forceKillDeadline != nil,
                  !process.forceKillWasSent
            else {
                reapLeader(process)
                return
            }

            if groupHasNoDescendants(process) {
                reapLeader(process)
            } else {
                scheduleGroupPoll()
            }
        } catch {
            Self.logger.error(
                "Could not observe child pid=\(process.processIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleExitPoll() {
        guard case var .running(process) = state,
              !process.leaderExitWasObserved
        else { return }

        process.exitPollGeneration += 1
        let generation = process.exitPollGeneration
        state = .running(process)
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            guard let self,
                  case let .running(current) = state,
                  current.exitPollGeneration == generation,
                  !current.leaderExitWasObserved
            else { return }
            observeLeaderExit()
            scheduleExitPoll()
        }
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

    private func scheduleGroupPoll() {
        guard case var .running(process) = state,
              process.leaderExitWasObserved,
              !process.forceKillWasSent
        else { return }

        process.groupPollGeneration += 1
        let generation = process.groupPollGeneration
        state = .running(process)
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            guard let self,
                  case let .running(current) = state,
                  current.groupPollGeneration == generation,
                  current.leaderExitWasObserved,
                  !current.forceKillWasSent
            else { return }
            if groupHasNoDescendants(current) {
                reapLeader(current)
            } else {
                scheduleGroupPoll()
            }
        }
    }

    private func reapLeader(_ process: RunningProcess) {
        do {
            let rawWaitStatus = try system.reap(processIdentifier: process.processIdentifier)
            process.exitMonitor?.cancel()
            state = .finished
            Self.logger.info("Reaped child pid=\(process.processIdentifier, privacy: .public)")
            process.terminationHandler(rawWaitStatus)
        } catch {
            Self.logger.error(
                "Could not reap child pid=\(process.processIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

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
    func spawn(configuration: PBChildProcessConfiguration) throws -> pid_t {
        try validate(configuration: configuration)

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

        if let inputFileDescriptor = configuration.standardInputFileDescriptor {
            try check(
                posix_spawn_file_actions_adddup2(&fileActions, inputFileDescriptor, STDIN_FILENO),
                operation: "configure child standard input"
            )
            try check(
                posix_spawn_file_actions_addclose(&fileActions, inputFileDescriptor),
                operation: "close child input pipe source"
            )
        } else {
            try check(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO),
                operation: "inherit child standard input"
            )
        }

        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                configuration.standardOutputFileDescriptor,
                STDOUT_FILENO
            ),
            operation: "configure child standard output"
        )
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                configuration.standardOutputFileDescriptor,
                STDERR_FILENO
            ),
            operation: "configure child standard error"
        )
        try check(
            posix_spawn_file_actions_addclose(
                &fileActions,
                configuration.standardOutputFileDescriptor
            ),
            operation: "close child output pipe source"
        )

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

    func hasExitedWithoutReaping(processIdentifier: pid_t) throws -> Bool {
        var information = siginfo_t()
        while true {
            if waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return information.si_pid == processIdentifier
            }
            if errno != EINTR {
                throw posixError(errno, operation: "observe child exit")
            }
        }
    }

    func reap(processIdentifier: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier {
                return status
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
            let processCount = processIdentifiers.withUnsafeMutableBytes { buffer in
                proc_listpgrppids(
                    processGroup,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard processCount >= 0 else {
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
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: operation,
                NSLocalizedFailureReasonErrorKey: String(cString: strerror(code)),
            ]
        )
    }
}

#if GITX_APP_TARGET
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
            terminationHandler: @escaping PBChildProcessOwner.TerminationHandler
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
    }
#endif
