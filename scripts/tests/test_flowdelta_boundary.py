from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


class FlowDeltaBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_flowdelta_boundary.py")

    def make_approved_seams(self, root: pathlib.Path) -> None:
        controllers = root / "Controllers"
        controllers.mkdir()
        (controllers / "FlowDeltaAdapters.swift").write_text("import FlowDeltaUI\n")
        (controllers / "HistoryFlowRevisionProvider.swift").write_text("import FlowDeltaGit\n")

    def test_only_the_two_approved_integration_files_may_import_flowdelta(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_approved_seams(root)

            self.assertEqual(self.module.boundary_failures(root), [])

            (root / "Controller.swift").write_text("@preconcurrency import FlowDeltaCore\n")
            failures = self.module.boundary_failures(root)

        self.assertEqual(
            failures,
            ["Controller.swift: imports FlowDelta outside an approved integration seam"],
        )

    def test_missing_integration_seams_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            root.mkdir(exist_ok=True)

            failures = self.module.boundary_failures(root)

        self.assertEqual(
            failures,
            [
                "Missing FlowDelta integration seam Controllers/FlowDeltaAdapters.swift",
                "Missing FlowDelta integration seam Controllers/HistoryFlowRevisionProvider.swift",
            ],
        )


if __name__ == "__main__":
    unittest.main()
