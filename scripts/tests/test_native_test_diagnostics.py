"""Separate native logging characterization from deterministic raw-pipe capture contracts."""

import json
import os
import pathlib
import platform
import selectors
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "requires Apple's native logging runtime")
class NativeTestDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="gitx-native-log-probe-")
        cls.executable = pathlib.Path(cls.build.name) / "probe"
        main = pathlib.Path(cls.build.name) / "main.swift"
        main.write_text(r'''
import Darwin
import Foundation
import OSLog
import Synchronization

func checkpoint(_ text: String) { print(text); fflush(stdout) }
let mode = CommandLine.arguments[1]
let environment = ProcessInfo.processInfo.environment
let directory = environment["GITX_TEST_STDERR_DIRECTORY"]
if mode == "attachment-recovered-baseline" {
    let file = URL(fileURLWithPath: directory!).appendingPathComponent("GitX-42-a.stderr.log")
    try Data("before-case".utf8).write(to: file)
    let attachments = GitXManagedTestObserver.CaseAttachments(candidates: [], preexistingNames: [file.lastPathComponent])
    let initial = GitXManagedTestObserver.AttachmentState.inspect(file)!
    precondition(attachments.take(candidates: [initial]).isEmpty, "unvalidated pre-case bytes must not become a new launch")
    let writer = try FileHandle(forWritingTo: file)
    try writer.seekToEnd()
    let tail = Data([0, 255, 65])
    try writer.write(contentsOf: tail)
    try writer.close()
    precondition(attachments.take(candidates: [GitXManagedTestObserver.AttachmentState.inspect(file)!]).first?.data == tail)
    let index = GitXManagedTestObserver.LogIndex(directory: directory)!
    let delayed = URL(fileURLWithPath: directory!).appendingPathComponent("GitX-43-b.stderr.log")
    try Data("unproven-pre-case".utf8).write(to: delayed)
    precondition(chmod(delayed.path, 0) == 0)
    precondition(chmod(directory!, 0) == 0)
    let failed = index.caseSnapshot()
    precondition(!failed.complete)
    let uncertain = GitXManagedTestObserver.CaseAttachments(candidates: failed.candidates, preexistingNames: failed.names, needsBaselineRecovery: true)
    precondition(chmod(directory!, 0o700) == 0)
    precondition(uncertain.take(snapshot: index.caseSnapshot()).isEmpty)
    precondition(chmod(delayed.path, 0o600) == 0)
    precondition(uncertain.take(snapshot: index.caseSnapshot()).isEmpty, "a partial recovery cannot forget unreadable old names")
    let delayedWriter = try FileHandle(forWritingTo: delayed)
    try delayedWriter.seekToEnd()
    try delayedWriter.write(contentsOf: tail)
    try delayedWriter.close()
    precondition(uncertain.take(snapshot: index.caseSnapshot()).first?.data == tail)
    let append = try FileHandle(forWritingTo: file)
    try append.seekToEnd()
    try append.write(contentsOf: tail)
    try append.close()
    precondition(uncertain.take(snapshot: index.caseSnapshot()).first?.data == tail)
    index.close()
    checkpoint("recovered baseline excludes old bytes and retains exact new binary tail")
    exit(0)
}
if mode == "log-index-retry" || mode == "log-index-churn" {
    let root = URL(fileURLWithPath: directory!)
    var files: [URL] = []
    for pid in 1 ... 21 {
        let file = root.appendingPathComponent("GitX-\(pid)-retry.stderr.log")
        try Data([0, 255, 65]).write(to: file)
        precondition(chmod(file.path, 0) == 0)
        files.append(file)
    }
    let interrupt = Mutex(false)
    let index = GitXManagedTestObserver.LogIndex(directory: directory, invalidateSnapshot: { interrupt.withLock { $0 } })!
    precondition(index.snapshot().isEmpty)
    for file in files { precondition(chmod(file.path, 0o600) == 0) }
    interrupt.withLock { $0 = mode == "log-index-churn" }
    var seen = Set<String>()
    var batches: [Int] = []
    for _ in 0 ..< 4 {
        let previous = index.retryInspectionCount
        seen.formUnion(index.snapshot().map(\.identity))
        let retried = index.retryInspectionCount - previous
        precondition(retried <= 16)
        batches.append(retried)
    }
    precondition(seen.count == 21, "permission restoration must retry without directory events")
    // Active validated files may also be refreshed; only failed entries use the retry budget.
    let log = root.appendingPathComponent("GitX-\(getpid())-record.stderr.log")
    try Data([66]).write(to: log)
    let record = try GitXTestProgressRecords.write(["schemaVersion": 1, "event": "capture", "state": "captured", "filename": log.lastPathComponent,
        "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture"], prefix: "capture", directory: directory!)
    precondition(chmod(record.path, 0) == 0)
    let records = GitXManagedTestObserver.LogIndex(directory: directory, invocationID: "fixture", verificationSession: "fixture", progressDirectory: nil)!
    precondition(records.snapshot().first { $0.file == log }?.finalized == false)
    precondition(chmod(record.path, 0o600) == 0)
    precondition(records.snapshot().first { $0.file == log }?.finalized == true, "capture metadata must retry")
    index.close()
    records.close()
    checkpoint("retry recovered=\(seen.count) inspections=\(batches)")
    exit(0)
}
if mode == "attachment-delivery" {
    let file = URL(fileURLWithPath: directory!).appendingPathComponent("GitX-42-a.stderr.log")
    try Data([0, 255, 65]).write(to: file)
    let candidate = GitXManagedTestObserver.AttachmentState.inspect(file)!
    let attachments = GitXManagedTestObserver.CaseAttachments(candidates: [])
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let count = Mutex(0)
    DispatchQueue.global().async {
        let caller = Thread.current
        attachments.deliver(candidates: [candidate]) { excerpt in
            precondition(Thread.current === caller)
            precondition(excerpt.data == Data([0, 255, 65]))
            count.withLock { $0 += 1 }
            attachments.deliver(candidates: [candidate]) { _ in preconditionFailure("duplicate reentrant delivery") }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        finished.signal()
    }
    precondition(entered.wait(timeout: .now() + 5) == .success)
    DispatchQueue.global().async { attachments.close(); closed.signal() }
    let result = closed.wait(timeout: .now() + 5)
    release.signal()
    precondition(finished.wait(timeout: .now() + 5) == .success)
    precondition(result == .success, "closure must not await external delivery")
    attachments.deliver(candidates: [candidate]) { _ in preconditionFailure("delivery admitted after close") }
    precondition(count.withLock { $0 } == 1)
    checkpoint("closure completed while admitted delivery waited; caller thread and bytes preserved")
    exit(0)
}
if mode == "log-index" {
    let root = URL(fileURLWithPath: directory!)
    for pid in 1 ... 20 {
        let name = "GitX-\(getpid())-\(pid).stderr.log"
        try Data(repeating: 65, count: 70000).write(to: root.appendingPathComponent(name))
        try GitXTestProgressRecords.write(["schemaVersion": 1, "event": "capture", "state": "captured", "filename": name,
            "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture"], prefix: "capture", directory: directory!)
    }
    let changed = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let index = GitXManagedTestObserver.LogIndex(directory: directory, invocationID: "fixture", verificationSession: "fixture", progressDirectory: nil, onDirectoryChange: { changed.signal() }, onClosed: { closed.signal() })!
    let baseline = index.snapshot()
    let initial = index.inspectionCount
    for _ in 0 ..< 30 { precondition(index.snapshot().count == 20) }
    precondition(index.inspectionCount == initial)
    let current = root.appendingPathComponent("GitX-\(getpid())-ffff.stderr.log")
    try Data().write(to: current)
    precondition(index.snapshot().first { $0.file == current }?.finalized == false)
    try FileManager.default.removeItem(at: current)
    let writer = current.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600) }
    precondition(writer >= 0 && flock(writer, LOCK_SH | LOCK_NB) == 0)
    let prefix = Data("before-case".utf8)
    prefix.withUnsafeBytes { precondition(Darwin.write(writer, $0.baseAddress, $0.count) == $0.count) }
    precondition(changed.wait(timeout: .now() + 5) == .success)
    let session = GitXManagedTestObserver.CaseAttachments(candidates: index.snapshot())
    precondition(session.take(candidates: index.snapshot()).isEmpty)
    let sentinel = Data([0, 255]) + Data("AddressSanitizer: current case".utf8)
    sentinel.withUnsafeBytes { precondition(Darwin.write(writer, $0.baseAddress, $0.count) == $0.count) }
    let candidates = index.snapshot()
    let count = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        let bytes = session.take(candidates: candidates).reduce(0) { $0 + $1.data.count }
        count.withLock { $0 += bytes }
    }
    precondition(count.withLock { $0 } == sentinel.count)
    session.close()
    precondition(session.take(candidates: candidates).isEmpty)
    try GitXTestProgressRecords.write(["schemaVersion": 1, "event": "capture", "state": "captured", "filename": current.lastPathComponent,
        "pid": getpid(), "invocationID": "fixture", "verificationSession": "fixture"], prefix: "capture", directory: directory!)
    precondition(index.snapshot().first { $0.file == current }?.finalized == false)
    Darwin.close(writer)
    _ = index.snapshot()
    let finalized = index.inspectionCount
    for _ in 0 ..< 30 { _ = index.snapshot() }
    precondition(index.inspectionCount == finalized)
    index.close()
    precondition(closed.wait(timeout: .now() + 5) == .success)
    precondition(index.snapshot().isEmpty)
    precondition(baseline.count == 20)
    checkpoint("indexed historical=20 inspections=\(initial) final=\(finalized) concurrent-bytes=\(sentinel.count)")
    exit(0)
}
if mode == "attachment-baseline" {
    var state = GitXManagedTestObserver.AttachmentState(in: directory)
    precondition(state.take(in: directory).isEmpty)
    let file = URL(fileURLWithPath: directory!).appendingPathComponent("GitX-999-a.stderr.log")
    try Data([0, 255, 65]).write(to: file)
    let first = state.take(in: directory)
    precondition(first.count == 1 && first[0].data == Data([0, 255, 65]))
    precondition(state.take(in: directory).isEmpty)
    checkpoint("case baseline preserves current binary tail")
    exit(0)
}
if mode == "attachments" {
    var state = GitXManagedTestObserver.AttachmentState()
    let names = state.take(in: directory).map(\.filename)
    checkpoint(names.joined(separator: ","))
    exit(0)
}
if mode == "publication" {
    let record: [String: Any] = ["schemaVersion": 1, "event": "capture", "pid": getpid(),
                               "invocationID": "probe", "verificationSession": "session", "state": "unavailable"]
    GitXTestProcessDiagnostics.publishCaptureRecord(record, progressDirectory: directory! + "/missing", fallbackDirectory: directory)
    var attempts = 0
    GitXTestProcessDiagnostics.publishCaptureRecord(record, progressDirectory: "/missing", fallbackDirectory: directory) { _, _ in
        attempts += 1
        throw GitXTestProgressRecords.PublicationError(operation: "publish-record", category: "system", posixCode: EIO)
    }
    precondition(attempts == 2)
    checkpoint("publication warning retained; app continues")
    exit(0)
}
if mode == "environment" {
    checkpoint(GitXTestGitEnvironment.isolated([:])["GITX_TEST_STDERR_DIRECTORY"] ?? "unowned")
    exit(0)
}
if mode == "lease" {
    do {
        let lease = try GitXTestInvocationLease(progressDirectory: environment["GITX_TEST_PROGRESS_DIRECTORY"]!)
        withExtendedLifetime(lease) { checkpoint("lease-acquired") }
    } catch let failure as GitXTestProgressRecords.PublicationError {
        checkpoint(failure.description)
    }
    exit(0)
}
if mode == "seams" {
    let root = directory!
    let install = GitXTestProcessDiagnostics.install
    let first = install(root, 42, UUID().uuidString, nil, { $0 })
    let second = install(root, 42, UUID().uuidString, nil, { $0 })
    precondition(first.state == "captured" && second.state == "captured" && first.filename != second.filename)
    precondition(install(root, 42, UUID().uuidString, { _, _ in -1 }, { $0 }).category == "open")
    precondition(install(root, 42, UUID().uuidString, nil, { _ in -1 }).category == "redirect")
    checkpoint("seams retained original stderr")
} else if mode == "collision" || mode == "symlink" {
    let identity = "00000000-0000-0000-0000-000000000001"
    let path = directory! + "/GitX-42-" + identity + ".stderr.log"
    if mode == "symlink" {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: directory! + "/sentinel")
    } else {
        try Data("keep-existing".utf8).write(to: URL(fileURLWithPath: path))
    }
    let result = GitXTestProcessDiagnostics.install(directory: directory, processIdentifier: 42, launchID: identity)
    precondition(result.state == "unavailable")
    checkpoint("capture unavailable; app continues")
} else {
    let logger = Logger(subsystem: "com.gitx.gitx.tests", category: "NativeCapture")
    logger.info("prime native logging")
    if ["logging-only", "raw-only", "capture"].contains(mode) {
        let flags = fcntl(STDERR_FILENO, F_GETFL)
        _ = fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)
        let filler = [UInt8](repeating: 120, count: 4096)
        while filler.withUnsafeBytes({ Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }) > 0 {}
        _ = fcntl(STDERR_FILENO, F_SETFL, flags)
    }
    if mode == "logging-only" {
        checkpoint("before-native-log")
        logger.info("native logging probe")
        checkpoint("after-native-log")
        exit(0) // No raw stderr operation can explain a logging-only stall.
    }
    GitXTestProcessDiagnostics.installAtApplicationStartup()
    GitXTestProcessDiagnostics.installAtApplicationStartup()
    if mode == "capture" {
        logger.info("native logging continues after capture")
        NSLog("NSLog retained after capture")
    }
    checkpoint("before-raw-write")
}
let bytes = Array("raw-stderr-".utf8) + [0, 255] + Array("-end\nAddressSanitizer: fixture\nMain Thread Checker: fixture\ncrash-output: fixture\n".utf8)
_ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
checkpoint("after-raw-write")
''')
        sdk_platform = pathlib.Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip())
        frameworks = sdk_platform / "Developer/Library/Frameworks"
        cls.required_runtime_paths = [frameworks.parent / "PrivateFrameworks", sdk_platform.parents[2] / "SharedFrameworks"]
        libraries = frameworks.parent.parent / "usr/lib"
        runtime_arguments = [argument for directory in cls.required_runtime_paths
                             for argument in ("-Xlinker", "-rpath", "-Xlinker", str(directory))]
        compiled = subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", "-I", str(libraries), "-L", str(libraries),
                        "-Xlinker", "-rpath", "-Xlinker", str(libraries), "-F", str(frameworks),
                        "-Xlinker", "-rpath", "-Xlinker", str(frameworks), *runtime_arguments, "-D", "DEBUG", "-D", "GITX_APP_TARGET",
                        str(ROOT / "GitXTests/GitXTestGitEnvironment.swift"),
                        str(ROOT / "GitXTests/GitXManagedTestObserver.swift"), str(main),
                        "-o", str(cls.executable)], capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def test_probe_embeds_xctest_dependency_runtime_paths(self):
        commands = subprocess.check_output(["otool", "-l", str(self.executable)], text=True)
        paths = {line.strip().removeprefix("path ").split(" (offset ")[0]
                 for line in commands.splitlines() if line.strip().startswith("path ")}
        for directory in self.required_runtime_paths:
            self.assertIn(str(directory), paths, "Probe must resolve XCTest dependencies without inherited dyld paths")

    def environment(self, directory=None, progress=None):
        environment = dict(os.environ, OS_ACTIVITY_DT_MODE="YES")
        environment.pop("OS_ACTIVITY_MODE", None)
        for key in ("GITX_TEST_STDERR_DIRECTORY", "GITX_TEST_PROGRESS_DIRECTORY", "GITX_TEST_INVOCATION_ID"):
            environment.pop(key, None)
        if directory is not None:
            environment["GITX_TEST_STDERR_DIRECTORY"] = str(directory)
        if progress is not None:
            environment.update(GITX_TEST_PROGRESS_DIRECTORY=str(progress), GITX_TEST_INVOCATION_ID="probe")
        return environment

    def wait_checkpoint(self, process, expected):
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.select(5):
                line = process.stdout.readline()
                if not line:
                    break
                if expected in line:
                    return
        self.fail(f"Missing checkpoint {expected!r}")

    def test_recovered_inspection_never_includes_unvalidated_pre_case_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'attachment-recovered-baseline'], env=self.environment(directory),
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('recovered baseline excludes old bytes', result.stdout)

    def test_transient_index_inspection_recovers_without_directory_events(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'log-index-retry'], env=self.environment(directory),
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('retry recovered=21', result.stdout)
            print(json.dumps({'nativeRetryIndex': result.stdout.strip()}))

    def test_transient_index_retry_rotation_survives_directory_churn(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'log-index-churn'], env=self.environment(directory),
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('retry recovered=21', result.stdout)
            print(json.dumps({'nativeRetryIndexChurn': result.stdout.strip()}))

    def test_attachment_close_does_not_wait_for_admitted_external_callbacks(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'attachment-delivery'], env=self.environment(directory),
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('closure completed while admitted delivery waited', result.stdout)

    def test_log_index_reuses_quiescent_logs_and_serializes_case_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'log-index'], env=self.environment(directory),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('indexed historical=20 inspections=20', result.stdout)
            self.assertIn('concurrent-bytes=', result.stdout)
            print(json.dumps({'nativeLogIndex': result.stdout.strip()}))

    def test_failure_attachment_budget_prioritizes_the_latest_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for pid in range(10, 15):
                old = root / f'GitX-{pid}-a.stderr.log'
                old.write_bytes(b'x' * 65536)
                os.utime(old, ns=(1_000_000_000, 1_000_000_000))
            current = root / 'GitX-999-a.stderr.log'
            current.write_bytes(b'AddressSanitizer: current-launch\n' + b'y' * 65500)
            result = subprocess.run([self.executable, 'attachments'], env=self.environment(directory),
                                    capture_output=True, timeout=5, check=True)
            self.assertEqual(result.stdout.decode().strip().split(',')[0], current.name)

    def test_attachment_case_baseline_excludes_older_unchanged_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            for pid in range(10, 15):
                (pathlib.Path(directory) / f'GitX-{pid}-a.stderr.log').write_bytes(b'x' * 65536)
            result = subprocess.run([self.executable, 'attachment-baseline'], env=self.environment(directory),
                                    capture_output=True, timeout=5, check=True)
            self.assertIn(b'case baseline preserves current binary tail', result.stdout)

    def test_capture_publication_failure_retains_exact_error_in_owned_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([self.executable, 'publication'], env=self.environment(directory),
                                    capture_output=True, timeout=5, check=True)
            self.assertEqual(result.stderr, b'')
            self.assertIn(b'app continues', result.stdout)
            records = [json.loads(path.read_text()) for path in pathlib.Path(directory).glob('capture-*.json')]
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]['publicationError'],
                             {'operation': 'open-directory', 'category': 'system', 'errno': 2})
            self.assertFalse(list(pathlib.Path(directory).glob('.pending-*')))

    def test_logging_only_characterizes_native_behavior_without_raw_write(self):
        process = subprocess.Popen([self.executable, "logging-only"], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0, env=self.environment())
        try:
            self.wait_checkpoint(process, b"before-native-log")
            try:
                process.wait(timeout=2)
                outcome = "native-call-returned-without-drain"
            except subprocess.TimeoutExpired:
                outcome = "native-call-required-drain"
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertIn(b"after-native-log", output)
            print(json.dumps({"nativeLoggingObservation": outcome, "platform": platform.platform()}))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_raw_write_blocks_until_pipe_is_drained(self):
        process = subprocess.Popen([self.executable, "raw-only"], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0, env=self.environment())
        try:
            self.wait_checkpoint(process, b"before-raw-write")
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=2)
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertIn(b"after-raw-write", output)
            self.assertIn(b"raw-stderr-\x00\xff-end", error)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_capture_finishes_without_draining_runner_pipe_and_retains_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen([self.executable, "capture"], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, bufsize=0, env=self.environment(directory))
            try:
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                output, _ = process.communicate(timeout=5)
            self.assertIn(b"after-raw-write", output)
            captures = list(pathlib.Path(directory).glob("*.stderr.log"))
            self.assertEqual(len(captures), 1, "Repeated installation is idempotent")
            captured = captures[0].read_bytes()
            for marker in (b"native logging continues", b"NSLog retained", b"raw-stderr-\x00\xff-end",
                           b"AddressSanitizer: fixture", b"Main Thread Checker: fixture", b"crash-output: fixture"):
                self.assertIn(marker, captured)
            self.assertEqual(captures[0].stat().st_mode & 0o777, 0o600)

    def test_unset_empty_and_unavailable_capture_preserve_original_stderr_and_startup(self):
        for selected_kind in ("unset", "empty", "relative", "missing"):
            with self.subTest(kind=selected_kind), tempfile.TemporaryDirectory() as progress:
                selected = {"unset": None, "empty": "", "relative": "relative", "missing": progress + "/missing"}[selected_kind]
                result = subprocess.run([self.executable, "plain"], env=self.environment(selected, progress),
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"raw-stderr-\x00\xff-end", result.stderr)
                records = list(pathlib.Path(progress).glob("capture-*.json"))
                self.assertEqual(len(records), 1)
                record = json.loads(records[0].read_text())
                self.assertEqual(record["state"], "not-requested" if selected in (None, "") else "unavailable")

    def test_unique_launches_descriptor_failures_and_existing_evidence_do_not_abort(self):
        for mode in ("seams", "collision", "symlink"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                sentinel = pathlib.Path(directory) / "sentinel"
                sentinel.write_bytes(b"keep-sentinel")
                result = subprocess.run([self.executable, mode], env=self.environment(directory),
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"raw-stderr-\x00\xff-end", result.stderr)
                self.assertEqual(sentinel.read_bytes(), b"keep-sentinel")
                if mode == "collision":
                    self.assertEqual(next(pathlib.Path(directory).glob("*.stderr.log")).read_bytes(), b"keep-existing")

    def test_unwritable_directory_and_symlink_directory_warn_without_crashing(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root)
            denied = base / "denied"
            denied.mkdir(mode=0o500)
            alias = base / "alias"
            alias.symlink_to(denied, target_is_directory=True)
            try:
                for directory in (denied, alias):
                    result = subprocess.run([self.executable, "plain"], env=self.environment(directory, base),
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(b"raw-stderr-\x00\xff-end", result.stderr)
            finally:
                denied.chmod(0o700)

    def test_native_directory_reaches_an_empty_ui_launch_environment(self):
        for selected in (None, "", "/fixture/native"):
            result = subprocess.run([self.executable, "environment"], env=self.environment(selected),
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertIn((selected or "unowned").encode(), result.stdout)

    def test_invocation_lease_rejects_fifo_symlink_directory_and_missing_file_without_blocking(self):
        for kind in ('regular', 'fifo', 'symlink', 'directory', 'missing'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                progress = root / 'Progress'
                progress.mkdir()
                lease = root / 'invocation.lease'
                sentinel = root / 'sentinel'
                sentinel.write_bytes(b'keep-original')
                if kind == 'regular':
                    lease.write_bytes(b'')
                elif kind == 'fifo':
                    os.mkfifo(lease)
                elif kind == 'symlink':
                    lease.symlink_to(sentinel)
                elif kind == 'directory':
                    lease.mkdir()
                result = subprocess.run([self.executable, 'lease'], env=self.environment(progress=progress),
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                if kind == 'regular':
                    self.assertIn(b'lease-acquired', result.stdout)
                else:
                    operation = 'validate-lease' if kind in ('fifo', 'directory') else 'open-lease'
                    category = 'ownership' if kind in ('fifo', 'directory') else 'system'
                    self.assertIn(f'operation={operation} category={category}'.encode(), result.stdout)
                    self.assertNotIn(b'lease-acquired', result.stdout)
                self.assertEqual(sentinel.read_bytes(), b'keep-original')


if __name__ == "__main__":
    unittest.main()
