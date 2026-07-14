from __future__ import annotations

import pathlib
import unittest

from support import ROOT


class PinnedToolsTests(unittest.TestCase):
    def test_mintfile_pins_swiftlint_and_swiftformat(self) -> None:
        entries = {
            line.strip()
            for line in (ROOT / "Mintfile").read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }

        self.assertIn("realm/SwiftLint@0.63.2", entries)
        self.assertIn("nicklockwood/SwiftFormat@0.62.1", entries)

    def test_swiftformat_rejects_older_binaries(self) -> None:
        configuration = (ROOT / ".swiftformat").read_text()

        self.assertIn("--minversion 0.62.1", configuration)

    def test_swiftlint_configuration_keeps_analyzer_rules_in_ci(self) -> None:
        configuration = (ROOT / ".swiftlint.yml").read_text()

        self.assertIn("analyzer_rules:", configuration)
        self.assertIn("unused_declaration", configuration)


if __name__ == "__main__":
    unittest.main()
