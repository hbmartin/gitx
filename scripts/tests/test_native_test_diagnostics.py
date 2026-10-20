"""Exercise the real Debug capture with a deliberately undrained XCTest-style pipe."""

import os
import pathlib
import platform
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

let logger = Logger(subsystem: "com.gitx.gitx.tests", category: "NativeCapture")
let mode = CommandLine.arguments[1]
if mode == "environment" {
    let inherited = GitXTestGitEnvironment.isolated([:])
    print(inherited["GITX_TEST_STDERR_DIRECTORY"] ?? "unowned")
}
logger.info("prime the logging runtime before changing stderr")
if mode == "blocked" || mode == "capture" {
    let flags = fcntl(STDERR_FILENO, F_GETFL)
    _ = fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)
    let filler = [UInt8](repeating: 120, count: 4096)
    while filler.withUnsafeBytes({ Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }) > 0 {}
    _ = fcntl(STDERR_FILENO, F_SETFL, flags)
}
if mode == "collision" || mode == "symlink" {
    let directory = ProcessInfo.processInfo.environment["GITX_TEST_STDERR_DIRECTORY"]!
    let path = directory + "/GitX-\(getpid()).stderr.log"
    if mode == "symlink" {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: directory + "/sentinel")
    } else {
        try Data("keep-existing".utf8).write(to: URL(fileURLWithPath: path))
    }
}
do {
    try GitXTestProcessDiagnostics.installIfRequested()
    GitXTestProcessDiagnostics.installAtApplicationStartup()
} catch {
    print("capture failed")
    exit(74)
}
logger.info("native logging continues after capture")
let bytes = Array("raw-stderr-".utf8) + [0, 255] + Array("-end\n".utf8)
_ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
print("finished")
''')
        subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-D", "GITX_APP_TARGET",
                        str(ROOT / "GitXTests/GitXTestGitEnvironment.swift"), str(main),
                        "-o", str(cls.executable)], check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def environment(self, directory=None):
        environment = dict(os.environ, OS_ACTIVITY_DT_MODE="YES")
        environment.pop("OS_ACTIVITY_MODE", None)
        environment.pop("GITX_TEST_STDERR_DIRECTORY", None)
        if directory is not None:
            environment["GITX_TEST_STDERR_DIRECTORY"] = str(directory)
        return environment

    def test_undrained_pipe_blocks_original_native_logging(self):
        process = subprocess.Popen([self.executable, "blocked"], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.environment())
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=2)
        finally:
            process.kill()
            process.communicate(timeout=5)

    def test_capture_finishes_without_draining_runner_pipe_and_retains_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen([self.executable, "capture"], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, env=self.environment(directory))
            try:
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                output, original_stderr = process.communicate(timeout=5)
            self.assertIn(b"finished", output)
            self.assertIn(b"prime the logging runtime", original_stderr)
            captures = list(pathlib.Path(directory).glob("*.stderr.log"))
            self.assertEqual(len(captures), 1)
            captured = captures[0].read_bytes()
            self.assertIn(b"native logging continues after capture", captured)
            self.assertIn(b"raw-stderr-\x00\xff-end\n", captured)
            self.assertEqual(captures[0].stat().st_mode & 0o777, 0o600)

    def test_no_request_preserves_original_stderr(self):
        result = subprocess.run([self.executable, "plain"], env=self.environment(),
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"native logging continues after capture", result.stderr)
        self.assertIn(b"raw-stderr-\x00\xff-end\n", result.stderr)

    def test_native_directory_reaches_an_empty_ui_launch_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            for selected in (None, directory):
                with self.subTest(directory=selected):
                    result = subprocess.run([self.executable, "environment"], env=self.environment(selected),
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn((selected or "unowned").encode(), result.stdout)

    def test_invalid_or_existing_destinations_fail_without_replacing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            sentinel = pathlib.Path(directory) / "sentinel"
            sentinel.write_bytes(b"keep-sentinel")
            for mode, selected in (("plain", "relative"), ("plain", directory + "/missing"),
                                   ("collision", directory), ("symlink", directory)):
                with self.subTest(mode=mode, directory=selected):
                    result = subprocess.run([self.executable, mode], env=self.environment(selected),
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 74, result.stderr)
                    self.assertIn(b"capture failed", result.stdout)
                    self.assertEqual(sentinel.read_bytes(), b"keep-sentinel")
            existing = [p for p in pathlib.Path(directory).glob("*.stderr.log") if not p.is_symlink()]
            self.assertEqual([p.read_bytes() for p in existing], [b"keep-existing"])
            self.assertFalse((pathlib.Path(directory) / "missing").exists())


if __name__ == "__main__":
    unittest.main()
