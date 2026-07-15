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

    def test_app_and_unit_tests_use_swift_6_complete_concurrency(self) -> None:
        project = (ROOT / "GitX.xcodeproj" / "project.pbxproj").read_text()

        self.assertNotIn("SWIFT_VERSION = 5.0", project)
        self.assertEqual(project.count("SWIFT_VERSION = 6.0"), 4)
        self.assertEqual(project.count("SWIFT_STRICT_CONCURRENCY = complete"), 4)
        self.assertEqual(project.count("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES"), 4)
        self.assertEqual(project.count("SWIFT_APPROACHABLE_CONCURRENCY = YES"), 4)
        self.assertEqual(project.count("SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor"), 2)
        self.assertEqual(project.count("-enable-actor-data-race-checks"), 2)
        self.assertEqual(project.count("-Wno-error=incomplete-umbrella"), 4)
        self.assertEqual(project.count("-Wno-error=quoted-include-in-framework-header"), 4)

    def test_ci_pins_the_swift_6_2_toolchain(self) -> None:
        build_workflow = (ROOT / ".github" / "workflows" / "BuildPR.yml").read_text()
        verify_workflow = (ROOT / ".github" / "workflows" / "Verify.yml").read_text()

        self.assertNotIn("26.3", build_workflow + verify_workflow)
        self.assertEqual(build_workflow.count("xcode: 26.2"), 2)
        self.assertEqual(verify_workflow.count('xcode-version: "26.2"'), 5)


if __name__ == "__main__":
    unittest.main()
