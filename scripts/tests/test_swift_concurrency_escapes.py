from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import ROOT, load_script


checker = load_script("check_swift_concurrency_escapes.py")


class SwiftConcurrencyEscapeTests(unittest.TestCase):
    def test_rejects_undocumented_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = pathlib.Path(temporary_directory) / "Unsafe.swift"
            source.write_text("final class Cache: @unchecked Sendable {}\n")

            findings = checker.scan([source])

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0][1:], (1, "@unchecked Sendable"))

    def test_accepts_nearby_justification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = pathlib.Path(temporary_directory) / "Reviewed.swift"
            source.write_text(
                "// swift6-safety-justification: guarded by a process-wide mutex.\n"
                "final class Cache: @unchecked Sendable {}\n"
            )

            self.assertEqual(checker.scan([source]), [])

    def test_repository_has_no_undocumented_escapes(self) -> None:
        self.assertEqual(checker.scan([ROOT / "Classes", ROOT / "GitXTests"]), [])


if __name__ == "__main__":
    unittest.main()
