from __future__ import annotations

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
        self.assertEqual(build_workflow.count("xcode: 26.2"), 1)
        self.assertEqual(verify_workflow.count('xcode-version: "26.2"'), 6)

    def test_verify_workflow_pins_actions_and_does_not_persist_checkout_credentials(self) -> None:
        verify_workflow = (ROOT / ".github" / "workflows" / "Verify.yml").read_text()
        pinned_actions = {
            "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0": 6,
            "maxim-lobanov/setup-xcode@ed7a3b1fda3918c0306d1b724322adc0b8cc0a90": 6,
            "actions/cache@caa296126883cff596d87d8935842f9db880ef25": 2,
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a": 5,
        }

        for action, expected_count in pinned_actions.items():
            self.assertEqual(verify_workflow.count(action), expected_count)
        self.assertEqual(verify_workflow.count("persist-credentials: false"), 6)
        for mutable_tag in [
            "actions/checkout@v7",
            "maxim-lobanov/setup-xcode@v1",
            "actions/cache@v5",
            "actions/upload-artifact@v7",
        ]:
            self.assertNotIn(mutable_tag, verify_workflow)

    def test_performance_suite_keeps_trusted_scheduled_and_manual_execution(self) -> None:
        verify_workflow = (ROOT / ".github" / "workflows" / "Verify.yml").read_text()
        performance_job = verify_workflow.split("\n  performance:\n", maxsplit=1)[1]
        condition = next(
            line.strip()
            for line in performance_job.splitlines()
            if line.lstrip().startswith("if:")
        )

        self.assertIn("github.event_name == 'schedule'", condition)
        self.assertIn("github.event_name == 'workflow_dispatch'", condition)
        self.assertIn("runs-on: [self-hosted, macOS, ARM64]", performance_job)
        self.assertIn("-testPlan GitXPerformance", performance_job)

    def test_performance_suite_rejects_pull_requests_on_self_hosted_runner(self) -> None:
        verify_workflow = (ROOT / ".github" / "workflows" / "Verify.yml").read_text()
        performance_job = verify_workflow.split("\n  performance:\n", maxsplit=1)[1]
        condition = next(
            line.strip()
            for line in performance_job.splitlines()
            if line.lstrip().startswith("if:")
        )

        self.assertNotIn("github.event_name == 'pull_request'", condition)


if __name__ == "__main__":
    unittest.main()
