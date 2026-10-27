from __future__ import annotations

import contextlib
import io
import json
import pathlib
import subprocess
import tempfile
import unittest

from support import load_script


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script("notarize_distribution.py")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.identifier = "12345678-1234-1234-1234-123456789abc"
        self.environment = dict(APPLE_ID="fixture", TEAM_ID="fixture", APPLE_PASSWORD="private",
                                GITX_NOTARIZATION_TIMEOUT_SECONDS="4", GITX_NOTARIZATION_POLL_SECONDS="1")
        self.clock = 0
        self.commands = []
        self.initial = {"id": self.identifier}
        self.information = [(0, {"id": self.identifier, "status": "Accepted"})]
        self.submit_status = 0
        self.log_status = 0
        self.wait_timeout = False

    def run_command(self, command, **options):
        self.commands.append(command)
        self.assertGreater(options["timeout"], 0)
        operation = command[2]
        if operation == "log":
            if self.log_status == 0:
                pathlib.Path(command[-1]).write_text('{"issues": []}')
            return subprocess.CompletedProcess(command, self.log_status, "", "")
        if operation == "submit":
            result, status = self.initial, self.submit_status
        elif operation == "wait":
            self.assertEqual(command[3], self.identifier)
            if self.wait_timeout:
                self.clock += options["timeout"]
                raise subprocess.TimeoutExpired(command, options["timeout"], output=b"interrupted", stderr=b"transport")
            return subprocess.CompletedProcess(command, 23, "wait ended early", "transport")
        else:
            self.assertEqual(command[3], self.identifier)
            status, result = self.information[0]
            if len(self.information) > 1:
                self.information.pop(0)
        output = result if isinstance(result, str) else json.dumps(result)
        return subprocess.CompletedProcess(command, status, output, "")

    def sleep(self, duration):
        self.assertGreater(duration, 0)
        self.clock += duration

    def perform(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.module.notarize("fixture.zip", self.directory, self.environment,
                                 run=self.run_command, now=lambda: self.clock, sleep=self.sleep)

    def test_wait_and_info_failures_retry_without_resubmitting(self):
        self.information.insert(0, (24, "transport failure"))
        self.information.insert(1, (0, {"id": self.identifier, "status": "In Progress"}))
        self.perform()
        self.assertEqual(sum(command[2] == "submit" for command in self.commands), 1)
        self.assertEqual(sum(command[2] == "wait" for command in self.commands), 3)
        self.assertTrue((self.directory / "notary-info-1.stderr").exists())
        self.assertTrue((self.directory / "notary-details.json").exists())

    def test_pending_submission_stops_at_the_overall_deadline(self):
        self.information = [(0, {"id": self.identifier, "status": "In Progress"})]
        with self.assertRaisesRegex(self.module.NotarizationError, "within 4 seconds"):
            self.perform()
        self.assertEqual(self.clock, 4)
        self.assertEqual(sum(command[2] == "submit" for command in self.commands), 1)

    def test_process_timeout_retains_partial_bytes_and_stops_waiting(self):
        self.wait_timeout = True
        with self.assertRaisesRegex(self.module.NotarizationError, "within 4 seconds"):
            self.perform()
        self.assertEqual((self.directory / "notary-wait-1.json").read_text(), "interrupted")
        self.assertEqual((self.directory / "notary-wait-1.stderr").read_text(), "transport")

    def test_terminal_rejections_fetch_diagnostics(self):
        for status in ("Invalid", "Rejected"):
            with self.subTest(status=status):
                self.information = [(0, {"id": self.identifier, "status": status})]
                with self.assertRaisesRegex(self.module.NotarizationError, status):
                    self.perform()
                self.assertEqual(self.commands[-1][2], "log")

    def test_malformed_submission_and_status_responses_never_succeed(self):
        for value in ("not-json", [], {}, {"id": 42}, {"id": "not-a-uuid"},
                      {"id": self.identifier, "status": "Unknown"}):
            with self.subTest(value=value):
                self.initial = value
                with self.assertRaises(self.module.NotarizationError):
                    self.perform()
        self.initial = {"id": self.identifier}
        for value in ("not-json", [], {}, {"id": self.identifier, "status": "Unknown"},
                      {"id": "87654321-1234-1234-1234-123456789abc", "status": "Accepted"}):
            with self.subTest(value=value):
                self.information = [(0, value)]
                with self.assertRaises(self.module.NotarizationError):
                    self.perform()

    def test_failed_submission_preserves_its_exit_status_and_available_diagnostics(self):
        self.submit_status = 21
        with self.assertRaises(self.module.NotarizationError) as raised:
            self.perform()
        self.assertEqual(raised.exception.status, 21)
        self.assertEqual(self.commands[-1][2], "log")
        self.initial = "bad JSON"
        with self.assertRaises(self.module.NotarizationError) as raised:
            self.perform()
        self.assertEqual(raised.exception.status, 21)

    def test_accepted_submission_is_not_failed_by_unavailable_diagnostics(self):
        self.initial["status"] = "Accepted"
        self.log_status = 22
        self.perform()
        self.assertEqual([command[2] for command in self.commands], ["submit", "log"])

    def test_configuration_requires_credentials_and_positive_ascii_integers(self):
        for key in ("GITX_NOTARIZATION_TIMEOUT_SECONDS", "GITX_NOTARIZATION_POLL_SECONDS"):
            for value in ("0", "-1", "1.5", "２"):
                with self.subTest(key=key, value=value):
                    self.environment[key] = value
                    with self.assertRaisesRegex(self.module.NotarizationError, "positive integer"):
                        self.perform()
            self.environment[key] = "4"
        self.environment.pop("APPLE_PASSWORD")
        with self.assertRaisesRegex(self.module.NotarizationError, "Missing APPLE_PASSWORD"):
            self.perform()


if __name__ == "__main__":
    unittest.main()
