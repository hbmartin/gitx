from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


class GitXCoreBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_gitxcore_boundary.py")

    def test_foundation_only_source_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Policy.swift").write_text("import Foundation\nstruct Policy {}\n")

            self.assertEqual(self.module.boundary_failures(root), [])

    def test_ui_and_global_runtime_dependencies_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Leaky.swift").write_text(
                "import AppKit\n"
                "let defaults = UserDefaults.standard\n"
                "let notifications = NotificationCenter.default\n"
                "let process = Process()\n"
            )

            failures = self.module.boundary_failures(root)

        self.assertTrue(any("disallowed module AppKit" in failure for failure in failures))
        self.assertTrue(any("global defaults" in failure for failure in failures))
        self.assertTrue(any("global notifications" in failure for failure in failures))
        self.assertTrue(any("process execution" in failure for failure in failures))

    def test_attributed_and_access_modified_imports_cannot_bypass_the_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Attributed.swift").write_text(
                "@preconcurrency internal import AppKit\n"
                "private import WebKit\n"
                "@_exported public import GitX\n"
            )

            failures = self.module.boundary_failures(root)

        self.assertTrue(any("disallowed module AppKit" in failure for failure in failures))
        self.assertTrue(any("disallowed module WebKit" in failure for failure in failures))
        self.assertTrue(any("disallowed module GitX" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
