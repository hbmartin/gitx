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

func checkpoint(_ text: String) { print(text); fflush(stdout) }
let mode = CommandLine.arguments[1]
let environment = ProcessInfo.processInfo.environment
let directory = environment["GITX_TEST_STDERR_DIRECTORY"]
if mode == "environment" {
    checkpoint(GitXTestGitEnvironment.isolated([:])["GITX_TEST_STDERR_DIRECTORY"] ?? "unowned")
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
        subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-D", "GITX_APP_TARGET",
                        str(ROOT / "GitXTests/GitXTestGitEnvironment.swift"), str(main),
                        "-o", str(cls.executable)], check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

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


if __name__ == "__main__":
    unittest.main()
