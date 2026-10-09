import Darwin
import Dispatch
import Foundation

// Objective-C callers are not visible to SwiftLint's analyzer.
// swiftlint:disable unused_declaration

// swift6-safety-justification: The lock protects the child owner's asynchronous completion snapshot.
private final nonisolated class ReferenceTransactionExit: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (Int32, NSError?)?
    private var observed = false
    let semaphore = DispatchSemaphore(value: 0)

    func complete(status: Int32, error: NSError?) {
        lock.lock()
        result = (status, error)
        lock.unlock()
        semaphore.signal()
    }

    var value: (Int32, NSError?)? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func observeLeader() {
        lock.lock(); observed = true; lock.unlock()
    }

    var leaderObserved: Bool {
        lock.lock(); defer { lock.unlock() }; return observed
    }
}

/// All pipe I/O belongs to the commit worker. The existing process owner holds
/// the process-group identity and enforces the independent publication backstop.
final nonisolated class IndexReferenceTransaction {
    private let owner = PBChildProcessOwner()
    private let exit = ReferenceTransactionExit()
    private let deadline: DispatchTime
    private var backstop: DispatchWorkItem?
    private var descriptors: Set<Int32> = []
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var diagnostic: Int32 = -1
    private var outputBytes = Data()
    private var diagnosticBytes = Data()
    private var diagnosticTruncated = false
    private var diagnosticEOF = false
    private var outputEOF = false
    private var committed = false
    private var commitAcknowledged = false
    private var launched = false
    private var closed = false
    private let checkCancellation: () throws -> Void

    init(timeout: TimeInterval = 30, checkCancellation: @escaping () throws -> Void = {}) {
        deadline = .now() + (timeout.isFinite ? max(0, timeout) : 30)
        self.checkCancellation = checkCancellation
    }

    deinit { abortAndClose() }

    func launch(context: PBTaskExecutionContext) throws {
        guard !launched, !closed else { throw failure("The commit publication transaction is already closed or running.") }
        let stdin = try pipePair()
        let stdout = try pipePair()
        let stderr = try pipePair()
        input = stdin.1
        output = stdout.0
        diagnostic = stderr.0
        for descriptor in [input, output, diagnostic] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure("Could not configure commit publication pipes.") }
        }
        guard fcntl(input, F_SETNOSIGPIPE, 1) == 0 else { throw failure("Could not protect commit publication input.") }
        let completion = exit
        try owner.launch(configuration: context.configuration(stdin: stdin.0, stdout: stdout.1, stderr: stderr.1),
                         retainLeaderUntilReleased: true, leaderExitHandler: { completion.observeLeader() })
        { status, error in
            completion.complete(status: status, error: error)
        }
        launched = true
        for descriptor in [stdin.0, stdout.1, stderr.1] {
            close(descriptor)
        }
        let processOwner = owner
        let timer = DispatchWorkItem {
            processOwner.requestTermination(gracePeriod: 0, forceKillDelay: 0.2)
            processOwner.releaseLeaderRetention()
        }
        backstop = timer
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: timer)
    }

    var remainingTime: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline.uptimeNanoseconds > now ? Double(deadline.uptimeNanoseconds - now) / Double(NSEC_PER_SEC) : 0
    }

    func send(_ command: String) throws {
        guard launched, !closed, input >= 0 else { throw failure("The commit publication transaction is closed.") }
        let bytes = Data(command.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard remainingTime > 0 else { throw failure("Commit publication timed out after 30 seconds.") }
                try checkCancellation()
                let count = Darwin.write(input, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN {
                    try waitForIO(writing: true)
                } else {
                    throw failure("Git closed the commit publication transaction.")
                }
            }
        }
    }

    func acknowledge(_ expected: String) throws {
        guard launched, !closed else { throw failure("The commit publication transaction is closed.") }
        while true {
            try checkCancellation()
            try readAvailable()
            if let newline = outputBytes.firstIndex(of: 10) {
                let line = String(decoding: outputBytes[..<newline], as: UTF8.self)
                outputBytes.removeSubrange(...newline)
                guard line == expected else { throw failure("Git returned an unexpected commit publication acknowledgement.") }
                if expected == "commit: ok" {
                    commitAcknowledged = true
                }
                return
            }
            guard remainingTime > 0 else { throw failure("Commit publication timed out after 30 seconds.") }
            guard !outputEOF, !exit.leaderObserved, exit.value == nil else { throw failure("Git stopped before acknowledging commit publication.") }
            try waitForIO(writing: false)
        }
    }

    func finish() throws {
        guard launched, !closed else { throw failure("The commit publication transaction is closed.") }
        close(input)
        input = -1
        while !outputEOF || !diagnosticEOF {
            try readAvailable()
            if !outputEOF || !diagnosticEOF {
                try waitForIO(writing: false)
            }
        }
        owner.releaseLeaderRetention()
        while exit.value == nil {
            try checkCancellation()
            guard remainingTime > 0 else { throw failure("Commit publication timed out after 30 seconds.") }
            _ = exit.semaphore.wait(timeout: .now() + min(0.1, remainingTime))
        }
        let (status, error) = exit.value!
        try readAvailable()
        if let error {
            throw error
        }
        guard status == 0, outputBytes.isEmpty else { throw failure("Git could not complete commit publication.") }
        committed = true
        backstop?.cancel()
        closeAll()
    }

    func abortAndClose() {
        guard !closed else { return }
        backstop?.cancel()
        guard !committed else { closeAll(); return }
        if input >= 0 {
            // EOF also aborts an uncommitted transaction; this best-effort abort
            // must never wait for a child that has already stopped responding.
            let bytes = Data("abort\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
            close(input)
            input = -1
        }
        if launched, exit.value == nil {
            owner.requestTermination(gracePeriod: 0, forceKillDelay: 0.2)
            owner.releaseLeaderRetention()
            _ = exit.semaphore.wait(timeout: .now() + 0.5)
        }
        closeAll()
    }

    private func pipePair() throws -> (Int32, Int32) {
        var values: [Int32] = [-1, -1]
        guard pipe(&values) == 0 else { throw failure("Could not prepare commit publication pipes.") }
        descriptors.formUnion(values)
        for descriptor in values {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw failure("Could not protect commit publication descriptors.") }
        }
        return (values[0], values[1])
    }

    private func readAvailable() throws {
        try read(descriptor: output, isDiagnostic: false)
        try read(descriptor: diagnostic, isDiagnostic: true)
    }

    private func read(descriptor: Int32, isDiagnostic: Bool) throws {
        guard descriptor >= 0, !(isDiagnostic ? diagnosticEOF : outputEOF) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard remainingTime > 0 else { throw failure("Commit publication timed out after 30 seconds.") }
            try checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if isDiagnostic {
                    let available = 64 * 1024 - diagnosticBytes.count
                    diagnosticTruncated = diagnosticTruncated || count > available
                    diagnosticBytes.append(contentsOf: buffer.prefix(min(count, available)))
                } else {
                    guard outputBytes.count + count <= 64 * 1024 else { throw failure("Git returned excessive commit publication acknowledgements.") }
                    outputBytes.append(contentsOf: buffer.prefix(count))
                }
            } else if count == 0 {
                if isDiagnostic {
                    diagnosticEOF = true
                } else {
                    outputEOF = true
                }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                throw failure("Could not read commit publication acknowledgement.")
            }
        }
    }

    private func waitForIO(writing: Bool) throws {
        var descriptors = [pollfd(fd: output, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: diagnostic, events: Int16(POLLIN), revents: 0)]
        if writing {
            descriptors.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0))
        }
        let milliseconds = Int32(min(1000, max(1, remainingTime * 1000)))
        let result = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
        if result < 0, errno != EINTR {
            throw failure("Could not wait for commit publication acknowledgement.")
        }
        if writing {
            try readAvailable()
        }
    }

    private func close(_ descriptor: Int32) {
        if descriptors.remove(descriptor) != nil {
            _ = Darwin.close(descriptor)
        }
    }

    private func closeAll() {
        for descriptor in descriptors {
            _ = Darwin.close(descriptor)
        }
        descriptors.removeAll()
        input = -1
        output = -1
        diagnostic = -1
        closed = true
    }

    private func failure(_ description: String) -> NSError {
        let diagnostic = PBTaskDiagnosticRedactor.redacted(String(decoding: diagnosticBytes, as: UTF8.self), incomplete: diagnosticTruncated || !diagnosticEOF)
        let description = commitAcknowledged
            ? description + " Git acknowledged the commit; it may already be published. Review the refreshed repository before submitting again."
            : description
        return NSError(domain: "PBGitCommitPublicationError", code: 1, userInfo: [
            NSLocalizedDescriptionKey: description,
            NSLocalizedFailureReasonErrorKey: diagnostic.isEmpty ? description : diagnostic,
        ])
    }
}

#if GITX_APP_TARGET && DEBUG
    /// Exercise the production pipe owner with controlled peers, never a second implementation.
    @objc(PBIndexReferenceTransactionTestHarness)
    final nonisolated class IndexReferenceTransactionTestHarness: NSObject {
        @objc(exerciseWithLaunchPath:arguments:workingDirectory:commands:acknowledgements:timeout:cancelAfterAcknowledgement:error:)
        static func exercise(launchPath: String, arguments: [String], workingDirectory: String?, commands: [String], acknowledgements: [String], timeout: TimeInterval, cancelAfterAcknowledgement: Int) throws {
            guard commands.count == acknowledgements.count else {
                throw NSError(domain: "PBGitCommitPublicationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Each test command requires one acknowledgement."])
            }
            let cancellation = IndexCommitCancellation()
            let transaction = IndexReferenceTransaction(timeout: timeout, checkCancellation: cancellation.check)
            defer { transaction.abortAndClose() }
            let context = PBTaskExecutionContext(launchPath: launchPath, arguments: arguments,
                                                 environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], workingDirectory: workingDirectory)
            try transaction.launch(context: context)
            for (index, command) in commands.enumerated() {
                try transaction.send(command)
                try transaction.acknowledge(acknowledgements[index])
                if index == cancelAfterAcknowledgement {
                    cancellation.cancel()
                }
            }
            try transaction.finish()
        }
    }
#endif
