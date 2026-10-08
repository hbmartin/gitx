import Darwin
import Foundation

#if GITX_APP_TARGET
    import os

    // Objective-C task and sheet callers are not visible to SwiftLint's analyzer.
    // swiftlint:disable unused_declaration

    @objc(PBTaskDiagnosticPrefix)
    final nonisolated class PBTaskDiagnosticPrefix: NSObject {
        @objc let data: Data
        @objc let complete: Bool

        init(data: Data, complete: Bool) {
            self.data = data
            self.complete = complete
        }
    }

    /// Its only public identity is an opaque capture; private paths never enter errors.
    // swift6-safety-justification: All mutable state and file access belong to the locked store.
    @objc(PBTaskDiagnosticArtifact)
    final nonisolated class PBTaskDiagnosticArtifact: NSObject, @unchecked Sendable {
        fileprivate let store: PBTaskDiagnosticStore

        fileprivate init(store: PBTaskDiagnosticStore) {
            self.store = store
        }

        @objc var redactedSummary: String {
            store.withLock {
                store.prepareReport()
                return store.summary
            }
        }

        @objc var captureComplete: Bool {
            store.withLock { store.complete }
        }

        @objc var captureFailureDescription: String? {
            store.withLock { store.failure }
        }

        override var description: String {
            "<private push diagnostic capture>"
        }

        @objc(rawStandardOutputPrefixWithMaximumBytes:)
        func rawStandardOutputPrefix(maximumBytes: Int) -> PBTaskDiagnosticPrefix {
            store.withLock {
                do {
                    let bytes = try store.readPrefix(stream: .output, maximumBytes: min(64 * 1024, max(0, maximumBytes)))
                    return PBTaskDiagnosticPrefix(data: bytes, complete: store.outputPrefixComplete && Int64(bytes.count) == store.outputBytes)
                } catch {
                    return PBTaskDiagnosticPrefix(data: Data(), complete: false)
                }
            }
        }

        @objc(forEachRawStandardErrorLineWithMaximumLineBytes:body:)
        func forEachRawStandardErrorLine(maximumLineBytes: Int, body: (String) -> Void) {
            _ = firstRawStandardErrorLine(maximumLineBytes: maximumLineBytes) { line in
                body(line)
                return false
            }
        }

        @objc(firstRawStandardErrorLineWithMaximumLineBytes:matching:)
        func firstRawStandardErrorLine(maximumLineBytes: Int, matching body: (String) -> Bool) -> String? {
            guard maximumLineBytes > 0,
                  let source = store.withLock({ try? store.source(stream: .error) }) else { return nil }
            let finalLineComplete = store.withLock { store.errorPrefixComplete }
            let lineLimit = min(64 * 1024, maximumLineBytes)
            var offset: Int64 = 0
            var line = Data()
            var oversized = false
            while offset < source.length {
                guard let chunk = try? store.withLock({ try source.read(offset, Int(min(Int64(PBTaskDiagnosticRedactor.bufferSize), source.length - offset))) }), !chunk.isEmpty else { return nil }
                for byte in chunk {
                    if byte == 10 {
                        if !oversized {
                            let text = String(decoding: line, as: UTF8.self)
                            if body(text) {
                                return text
                            }
                        }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                    } else if !oversized {
                        if line.count < lineLimit {
                            line.append(byte)
                        } else {
                            line.removeAll(keepingCapacity: true)
                            oversized = true
                        }
                    }
                }
                offset += Int64(chunk.count)
            }
            if finalLineComplete, !oversized, !line.isEmpty {
                let text = String(decoding: line, as: UTF8.self)
                if body(text) {
                    return text
                }
            }
            return nil
        }

        @objc(writeRedactedReportToURL:error:)
        func writeRedactedReport(to destination: URL) throws {
            try store.withLock { try store.export(to: destination) }
        }

        @objc func discard() {
            store.withLock { store.remove() }
        }
    }

    // swift6-safety-justification: The store lock protects all file, completion and artifact state.
    @objc(PBTaskDiagnosticCapture)
    final nonisolated class PBTaskDiagnosticCapture: NSObject, @unchecked Sendable {
        fileprivate let store: PBTaskDiagnosticStore
        private var sealedArtifact: PBTaskDiagnosticArtifact?

        @objc override convenience init() {
            self.init(fault: "")
        }

        fileprivate init(fault: String) {
            store = PBTaskDiagnosticStore(fault: fault)
        }

        @objc var artifact: PBTaskDiagnosticArtifact? {
            store.withLock { sealedArtifact }
        }

        override var description: String {
            "<private push diagnostic capture>"
        }

        @objc(appendStandardOutput:)
        func appendStandardOutput(_ data: Data) {
            store.withLock { store.append(data, stream: .output) }
        }

        @objc(appendStandardError:)
        func appendStandardError(_ data: Data) {
            store.withLock { store.append(data, stream: .error) }
        }

        @objc(finishStandardOutputWithReachedEOF:)
        func finishStandardOutput(reachedEOF: Bool) {
            store.withLock { store.finish(stream: .output, reachedEOF: reachedEOF) }
        }

        @objc(finishStandardErrorWithReachedEOF:)
        func finishStandardError(reachedEOF: Bool) {
            store.withLock { store.finish(stream: .error, reachedEOF: reachedEOF) }
        }

        @objc func seal() -> PBTaskDiagnosticArtifact {
            store.withLock {
                if let sealedArtifact {
                    return sealedArtifact
                }
                store.seal()
                let artifact = PBTaskDiagnosticArtifact(store: store)
                sealedArtifact = artifact
                return artifact
            }
        }

        @objc static func cleanupStaleCaptures() {
            PBTaskDiagnosticStore.cleanupStaleCaptures()
        }
    }

    fileprivate nonisolated enum PBTaskDiagnosticStream { case output, error }

    // swift6-safety-justification: The owning capture/artifact confines every access to `lock`.
    fileprivate final nonisolated class PBTaskDiagnosticStore: @unchecked Sendable {
        private static let logger = os.Logger(subsystem: "com.gitx.gitx", category: "PushDiagnostics")
        private static let base = FileManager.default.temporaryDirectory.appendingPathComponent("GitX-Push-Diagnostics", isDirectory: true)
        private let lock = NSLock()
        private let io: PBTaskDiagnosticIO
        private var directory: URL?
        private var outputDescriptor: Int32 = -1
        private var errorDescriptor: Int32 = -1
        private var leaseDescriptor: Int32 = -1
        private var sealed = false
        private var reportAvailable = false
        private var reportPreparationAttempted = false
        var outputBytes: Int64 = 0
        private var outputCaptureFailed = false
        private var errorBytes: Int64 = 0
        private var errorCaptureFailed = false
        var outputEOF = false
        var errorEOF = false
        var failure: String?
        var summary = "Push output has not finished."
        var complete: Bool {
            sealed && outputEOF && errorEOF && failure == nil && directory != nil
        }

        var outputPrefixComplete: Bool {
            sealed && outputEOF && !outputCaptureFailed && directory != nil
        }

        var errorPrefixComplete: Bool {
            sealed && errorEOF && !errorCaptureFailed && directory != nil
        }

        init(fault: String) {
            io = PBTaskDiagnosticIO(fault: fault)
            do {
                try Self.prepareBase()
                try io.failIfRequested("createDirectory")
                let directory = Self.base.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard mkdir(directory.path, 0o700) == 0 else { throw Self.error() }
                self.directory = directory
                leaseDescriptor = try io.create(directory.appendingPathComponent("lease"), operation: "createLease")
                guard flock(leaseDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw Self.error() }
                outputDescriptor = try io.create(directory.appendingPathComponent("stdout"), operation: "createOutput")
                errorDescriptor = try io.create(directory.appendingPathComponent("stderr"), operation: "createError")
                Self.logger.debug("Created private push capture")
            } catch {
                failure = "Full push output could not be captured."
                outputCaptureFailed = true
                errorCaptureFailed = true
                remove()
                Self.logger.error("Private push capture could not be created")
            }
        }

        deinit { remove() }

        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        func append(_ data: Data, stream: PBTaskDiagnosticStream) {
            guard !sealed, failure == nil, !data.isEmpty else { return }
            let descriptor = stream == .output ? outputDescriptor : errorDescriptor
            do {
                let count = try io.write(data, descriptor: descriptor, operation: "append")
                if stream == .output {
                    outputBytes += Int64(count)
                } else {
                    errorBytes += Int64(count)
                }
            } catch {
                // Include any prefix committed before the failed write, then stop both streams.
                outputBytes = Self.size(descriptor: outputDescriptor)
                errorBytes = Self.size(descriptor: errorDescriptor)
                failure = "Only part of the push output could be captured."
                if !outputEOF {
                    outputCaptureFailed = true
                }
                if !errorEOF {
                    errorCaptureFailed = true
                }
                Self.logger.error("Private push capture stopped after a write failure")
            }
        }

        func finish(stream: PBTaskDiagnosticStream, reachedEOF: Bool) {
            guard !sealed else { return }
            if stream == .output {
                outputEOF = outputEOF || reachedEOF
            } else {
                errorEOF = errorEOF || reachedEOF
            }
        }

        func seal() {
            guard !sealed else { return }
            sealed = true
            closeWriter(&outputDescriptor, stream: .output)
            closeWriter(&errorDescriptor, stream: .error)
            // Successful pushes need only their bounded status and server hint.
            // The full escaped/redacted copy is deferred until presentation/export.
            Self.logger.info("Sealed private push capture without preparing a report")
        }

        func prepareReport() {
            guard sealed, !reportPreparationAttempted else { return }
            reportPreparationAttempted = true
            let state = complete ? "complete" : "incomplete"
            var sections = ["Push output capture: \(state)."]
            if let failure {
                sections.append(failure)
            }
            if !outputEOF || !errorEOF {
                sections.append("One or more streams stopped before end-of-file.")
            }
            guard let directory else {
                summary = sections.joined(separator: "\n")
                return
            }
            var reportDescriptor: Int32 = -1
            do {
                reportDescriptor = try io.create(directory.appendingPathComponent("report"), operation: "createReport")
                _ = try io.write(Data("GitX push output\nCapture: \(state)\nInvalid UTF-8 and control bytes are escaped as \\xNN.\n".utf8), descriptor: reportDescriptor, operation: "redactionWrite")
                for stream in [PBTaskDiagnosticStream.output, .error] {
                    let title = stream == .output ? "Standard output" : "Standard error"
                    let reachedEOF = stream == .output ? outputEOF : errorEOF
                    let byteCount = stream == .output ? outputBytes : errorBytes
                    let metadata = "\(title): \(byteCount) bytes; EOF: \(reachedEOF ? "yes" : "no")"
                    _ = try io.write(Data("\n\n\(metadata)\n".utf8), descriptor: reportDescriptor, operation: "redactionWrite")
                    var preview = PBTaskDiagnosticPreview()
                    var renderer = PBTaskDiagnosticUTF8Renderer()
                    let source = try source(stream: stream)
                    let renderedOutput: (Data) throws -> Void = { chunk in
                        // swiftformat:disable:next redundantSelf
                        _ = try self.io.write(chunk, descriptor: reportDescriptor, operation: "redactionWrite")
                        preview.append(chunk)
                    }
                    try PBTaskDiagnosticRedactor.redact(source: source, incomplete: !reachedEOF || failure != nil) { chunk in
                        try renderer.append(chunk, output: renderedOutput)
                    }
                    try renderer.finish(output: renderedOutput)
                    sections.append(metadata + "\n" + preview.text)
                }
                let completedReportDescriptor = reportDescriptor
                reportDescriptor = -1
                try io.close(completedReportDescriptor)
                reportAvailable = true
                summary = PBTaskDiagnosticPreview.bounded(sections.joined(separator: "\n\n"), maximumBytes: 16 * 1024)
                // Swift's logger interpolation captures these values in an escaping autoclosure.
                // swiftformat:disable:next redundantSelf
                Self.logger.info("Sealed private push capture; complete=\(self.complete, privacy: .public), stdoutBytes=\(self.outputBytes, privacy: .public), stdoutEOF=\(self.outputEOF, privacy: .public), stderrBytes=\(self.errorBytes, privacy: .public), stderrEOF=\(self.errorEOF, privacy: .public)")
            } catch {
                if reportDescriptor >= 0 {
                    _ = Darwin.close(reportDescriptor)
                }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("report"))
                failure = "Push output could not be prepared safely."
                summary = "Push output capture: incomplete.\n" + (failure ?? "")
                Self.logger.error("Private push capture could not be redacted")
            }
        }

        func readPrefix(stream: PBTaskDiagnosticStream, maximumBytes: Int) throws -> Data {
            let source = try source(stream: stream)
            return try source.read(0, Int(min(Int64(maximumBytes), source.length)))
        }

        func source(stream: PBTaskDiagnosticStream) throws -> PBTaskDiagnosticByteSource {
            guard let directory else { throw Self.error() }
            let url = directory.appendingPathComponent(stream == .output ? "stdout" : "stderr")
            let length = stream == .output ? outputBytes : errorBytes
            return PBTaskDiagnosticByteSource(length: length) { [io] offset, count in
                try io.read(url, offset: offset, count: count)
            }
        }

        func export(to destination: URL) throws {
            prepareReport()
            guard reportAvailable, let directory, destination.isFileURL else { throw Self.error() }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".gitx-push-output-\(UUID().uuidString)")
            let descriptor = try io.create(temporary, operation: "exportOpen")
            var needsClose = true
            defer {
                if needsClose {
                    _ = Darwin.close(descriptor)
                }
                try? FileManager.default.removeItem(at: temporary)
            }
            let report = directory.appendingPathComponent("report")
            let length = try io.fileSize(report)
            var offset: Int64 = 0
            while offset < length {
                let chunk = try io.read(report, offset: offset, count: Int(min(Int64(PBTaskDiagnosticRedactor.bufferSize), length - offset)))
                guard !chunk.isEmpty else { throw Self.error() }
                _ = try io.write(chunk, descriptor: descriptor, operation: "exportWrite")
                offset += Int64(chunk.count)
            }
            try io.synchronize(descriptor)
            needsClose = false
            try io.close(descriptor)
            guard rename(temporary.path, destination.path) == 0 else { throw Self.error() }
            Self.logger.info("Saved redacted push output")
        }

        func remove() {
            if outputDescriptor >= 0 {
                _ = Darwin.close(outputDescriptor); outputDescriptor = -1
            }
            if errorDescriptor >= 0 {
                _ = Darwin.close(errorDescriptor); errorDescriptor = -1
            }
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
            directory = nil
            reportAvailable = false
            if leaseDescriptor >= 0 {
                _ = Darwin.close(leaseDescriptor); leaseDescriptor = -1
            }
        }

        private func closeWriter(_ descriptor: inout Int32, stream: PBTaskDiagnosticStream) {
            let old = descriptor
            descriptor = -1
            guard old >= 0 else { return }
            do { try io.close(old) } catch {
                failure = "Only part of the push output could be captured."
                if stream == .output {
                    outputCaptureFailed = true
                } else {
                    errorCaptureFailed = true
                }
            }
        }

        private static func prepareBase() throws {
            if mkdir(base.path, 0o700) != 0, errno != EEXIST {
                throw error()
            }
            var metadata = stat()
            guard lstat(base.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700
            else { throw error() }
        }

        static func cleanupStaleCaptures() {
            guard (try? prepareBase()) != nil,
                  let directories = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            else { return }
            for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
                var metadata = stat()
                guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                      metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700
                else { continue }
                // Lease creation and flock are separate syscalls. A fresh unlocked
                // lease may still belong to its creator; apply the orphan grace to
                // both registered and not-yet-registered directories.
                let age = Date().timeIntervalSince1970 - Double(metadata.st_mtimespec.tv_sec)
                guard age >= 24 * 60 * 60 else { continue }
                let descriptor = Darwin.open(directory.appendingPathComponent("lease").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    // A crash can precede lease creation. A day-old orphan is safe to
                    // remove; fresh directories may belong to an in-progress creator.
                    let missingLease = errno == ENOENT
                    let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                    if missingLease,
                       let names, Set(names).isSubset(of: ["stdout", "stderr", "report"])
                    {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    continue
                }
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    try? FileManager.default.removeItem(at: directory)
                }
                _ = Darwin.close(descriptor)
            }
        }

        private static func size(descriptor: Int32) -> Int64 {
            var metadata = stat()
            return descriptor >= 0 && fstat(descriptor, &metadata) == 0 ? metadata.st_size : 0
        }

        static func error() -> NSError {
            NSError(domain: "PBTaskDiagnosticCaptureError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Push output could not be saved safely."])
        }

        #if DEBUG
            func lifetimeProbe() -> PBTaskDiagnosticCaptureLifetimeProbe? {
                guard let directory else { return nil }
                let descriptors = [outputDescriptor, errorDescriptor, leaseDescriptor]
                let closeOnExec = descriptors.allSatisfy { $0 >= 0 && fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }
                return PBTaskDiagnosticCaptureLifetimeProbe(directory: directory, store: self, closeOnExec: closeOnExec)
            }

            var writersClosed: Bool {
                outputDescriptor < 0 && errorDescriptor < 0
            }

            static func orphanProbe(age: TimeInterval, hasUnlockedLease: Bool = false) throws -> PBTaskDiagnosticCaptureLifetimeProbe {
                guard age.isFinite, age >= 0 else { throw error() }
                try prepareBase()
                let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard mkdir(directory.path, 0o700) == 0 else { throw error() }
                do {
                    if hasUnlockedLease {
                        let io = PBTaskDiagnosticIO(fault: "")
                        let descriptor = try io.create(directory.appendingPathComponent("lease"), operation: "createLease")
                        try io.close(descriptor)
                    }
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: directory.path)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw Self.error()
                }
                return PBTaskDiagnosticCaptureLifetimeProbe(directory: directory, store: nil, closeOnExec: false)
            }
        #endif
    }

    private nonisolated struct PBTaskDiagnosticPreview {
        private var head = Data()
        private var tail = Data()
        private var byteCount: Int64 = 0

        mutating func append(_ data: Data) {
            byteCount += Int64(data.count)
            if head.count < 2048 {
                head.append(data.prefix(2048 - head.count))
            }
            tail.append(data)
            if tail.count > 4096 {
                tail = Data(tail.suffix(4096))
            }
        }

        var text: String {
            if byteCount <= 4096 {
                return String(decoding: tail, as: UTF8.self)
            }
            if byteCount <= 6144 {
                let overlap = head.count + tail.count - Int(byteCount)
                return String(decoding: head + tail.dropFirst(overlap), as: UTF8.self)
            }
            var safeHead = head
            while String(data: safeHead, encoding: .utf8) == nil {
                safeHead.removeLast()
            }
            var safeTail = tail
            while safeTail.first.map({ $0 & 0xC0 == 0x80 }) == true {
                safeTail.removeFirst()
            }
            let omitted = byteCount - Int64(safeHead.count + safeTail.count)
            return "Head (\(safeHead.count) display bytes):\n" + String(decoding: safeHead, as: UTF8.self)
                + "\n[\(omitted) display bytes omitted]\nTail (\(safeTail.count) display bytes):\n"
                + String(decoding: safeTail, as: UTF8.self)
        }

        static func bounded(_ text: String, maximumBytes: Int) -> String {
            let bytes = Array(text.utf8)
            guard bytes.count > maximumBytes else { return text }
            var end = maximumBytes
            while end > 0, bytes[end] & 0xC0 == 0x80 {
                end -= 1
            }
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private final nonisolated class PBTaskDiagnosticIO {
        let fault: String
        private var faultWasTriggered = false

        init(fault: String) {
            self.fault = fault
        }

        func failIfRequested(_ operation: String) throws {
            if fault == operation, !faultWasTriggered {
                faultWasTriggered = true
                throw PBTaskDiagnosticStore.error()
            }
        }

        func create(_ url: URL, operation: String) throws -> Int32 {
            try failIfRequested(operation)
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw PBTaskDiagnosticStore.error() }
            return descriptor
        }

        func write(_ data: Data, descriptor: Int32, operation: String) throws -> Int {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try failIfRequested(operation)
                    var count = buffer.count - offset
                    if fault == "partialAppend", operation == "append", faultWasTriggered {
                        throw PBTaskDiagnosticStore.error()
                    }
                    if fault == "shortWrite" || fault == "partialAppend", !faultWasTriggered {
                        faultWasTriggered = true
                        count = min(count, 1)
                    }
                    let written: Int
                    if fault == "interruptedWrite", !faultWasTriggered {
                        faultWasTriggered = true
                        errno = EINTR
                        written = -1
                    } else {
                        written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), count)
                    }
                    if written < 0, errno == EINTR {
                        continue
                    }
                    guard written > 0 else { throw PBTaskDiagnosticStore.error() }
                    offset += written
                }
                return offset
            }
        }

        func close(_ descriptor: Int32) throws {
            let result = Darwin.close(descriptor)
            try failIfRequested("close")
            guard result == 0 else { throw PBTaskDiagnosticStore.error() }
        }

        func synchronize(_ descriptor: Int32) throws {
            try failIfRequested("exportSync")
            while fsync(descriptor) != 0 {
                if errno != EINTR {
                    throw PBTaskDiagnosticStore.error()
                }
            }
        }

        func read(_ url: URL, offset: Int64, count: Int) throws -> Data {
            try failIfRequested("read")
            guard count > 0 else { return Data() }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw PBTaskDiagnosticStore.error() }
            defer { _ = Darwin.close(descriptor) }
            var result = Data(count: count)
            let readCount = try result.withUnsafeMutableBytes { buffer in
                var total = 0
                while total < count {
                    let actual = pread(descriptor, buffer.baseAddress!.advanced(by: total), count - total, offset + Int64(total))
                    if actual < 0, errno == EINTR {
                        continue
                    }
                    guard actual >= 0 else { throw PBTaskDiagnosticStore.error() }
                    if actual == 0 {
                        break
                    }
                    total += actual
                }
                return total
            }
            result.removeSubrange(readCount ..< result.count)
            return result
        }

        func fileSize(_ url: URL) throws -> Int64 {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw PBTaskDiagnosticStore.error() }
            return metadata.st_size
        }
    }

    #if DEBUG
        /// Reports ownership facts without exporting the private capture location.
        @objc(PBTaskDiagnosticCaptureLifetimeProbe)
        final nonisolated class PBTaskDiagnosticCaptureLifetimeProbe: NSObject {
            private let directory: URL
            private weak var store: PBTaskDiagnosticStore?
            @objc let writerDescriptorsAreCloseOnExec: Bool

            fileprivate init(directory: URL, store: PBTaskDiagnosticStore?, closeOnExec: Bool) {
                self.directory = directory
                self.store = store
                writerDescriptorsAreCloseOnExec = closeOnExec
            }

            override var description: String {
                "<private capture lifetime probe>"
            }

            @objc var directoryExists: Bool {
                var metadata = stat()
                return lstat(directory.path, &metadata) == 0
            }

            @objc var directoryMode: UInt {
                Self.mode(directory)
            }

            @objc var rawFileModes: [NSNumber] {
                ["stdout", "stderr", "lease"].map { NSNumber(value: Self.mode(directory.appendingPathComponent($0))) }
            }

            @objc var writersClosed: Bool {
                guard let store else { return true }
                return store.withLock { store.writersClosed }
            }

            @objc(markStaleForCleanupAndReturnError:)
            func markStaleForCleanup() throws {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)], ofItemAtPath: directory.path)
            }

            @objc func discardFixture() {
                // Only orphan probes may remove their fixture directly.
                guard store == nil else { return }
                try? FileManager.default.removeItem(at: directory)
            }

            private static func mode(_ url: URL) -> UInt {
                var metadata = stat()
                return lstat(url.path, &metadata) == 0 ? UInt(metadata.st_mode & 0o777) : 0
            }
        }

        @objc(PBTaskDiagnosticCaptureTestHarness)
        final nonisolated class PBTaskDiagnosticCaptureTestHarness: NSObject {
            @objc(captureWithFault:)
            static func capture(fault: String) -> PBTaskDiagnosticCapture {
                PBTaskDiagnosticCapture(fault: fault)
            }

            @objc(lifetimeProbeForCapture:)
            static func lifetimeProbe(for capture: PBTaskDiagnosticCapture) -> PBTaskDiagnosticCaptureLifetimeProbe? {
                capture.store.withLock { capture.store.lifetimeProbe() }
            }

            @objc(orphanProbeWithAge:error:)
            static func orphanProbe(age: TimeInterval) throws -> PBTaskDiagnosticCaptureLifetimeProbe {
                try PBTaskDiagnosticStore.orphanProbe(age: age)
            }

            @objc(unlockedLeasedOrphanProbeWithAge:error:)
            static func unlockedLeasedOrphanProbe(age: TimeInterval) throws -> PBTaskDiagnosticCaptureLifetimeProbe {
                try PBTaskDiagnosticStore.orphanProbe(age: age, hasUnlockedLease: true)
            }
        }
    #endif
    // swiftlint:enable unused_declaration
#endif
