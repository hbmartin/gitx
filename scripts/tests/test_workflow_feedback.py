from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from support import ROOT, fixture_git_environment
import workflow_session as session
import dev_workflow as workflow


class FeedbackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.env = fixture_git_environment()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("README.md", "fixture\n")
        self.write(".swiftlint.yml", (ROOT / ".swiftlint.yml").read_text())
        self.commit()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True,
                              capture_output=True, env=self.env).stdout

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")

    def feedback(self):
        import workflow_feedback
        return workflow_feedback

    def test_change_groups_are_combined_and_unknowns_expand(self):
        feedback = self.feedback()
        names = [name for name, _ in workflow.full_profile(self.root)]
        selected, _ = feedback.select_checks(["GitXCore/Tests/A.swift", "ForgeKit/Sources/B.swift"], names)
        self.assertEqual(selected, ["static", "debug-test-build", "core", "forgekit"])
        selected, _ = feedback.select_checks(["README.md"], names)
        self.assertEqual(selected, ["whitespace"])
        for path in ("AGENTS.md", "Classes/GitX-Bridging-Header.h", "new.unknown", "ForgeKit/Package.swift"):
            self.assertEqual(feedback.select_checks([path], names)[0], names)

    def test_paths_include_deletions_renames_and_new_source_with_nul_safety(self):
        feedback = self.feedback()
        old = "Classes/old café\nfile.swift"
        self.write(old, "old\n")
        self.write("GitXTests/deleted.swift", "deleted\n")
        self.commit()
        base = self.git("rev-parse", "HEAD").decode().strip()
        self.git("mv", old, "Classes/new café\nfile.swift")
        self.git("rm", "GitXTests/deleted.swift")
        self.write("Resources/new file.xib", "resource\n")
        self.write("research/private.md", "ignore\n")
        self.write("GitXCore/.swiftpm/xcode/xcuserdata/a/file", "ignore\n")
        _, paths = feedback.changed_paths(self.root, base)
        self.assertEqual(set(paths), {old, "Classes/new café\nfile.swift", "GitXTests/deleted.swift", "Resources/new file.xib"})

    def test_invalid_explicit_base_is_rejected_and_initial_commit_is_supported(self):
        feedback = self.feedback()
        with self.assertRaisesRegex(ValueError, "comparison"):
            feedback.changed_paths(self.root, "missing-ref")
        _, paths = feedback.changed_paths(self.root)
        self.assertEqual(paths, [])

    def test_focused_selectors_apply_to_the_matching_target_only(self):
        feedback = self.feedback()
        commands = workflow.full_profile(self.root)
        focused = feedback.focus_commands(commands, ["GitXTests/A/testA", "GitXUITests/B"])
        mapping = dict(focused)
        self.assertIn("-only-testing:GitXTests/A/testA", mapping["correctness"])
        self.assertNotIn("-only-testing:GitXUITests/B", mapping["correctness"])
        self.assertIn("-only-testing:GitXUITests/B", mapping["ui"])
        self.assertNotIn("-only-testing:GitXTests/A/testA", mapping["ui"])
        for selector in ("Unknown/A", "GitXTests", "GitXTests//bad", "GitXTests/A/test/extra"):
            with self.assertRaises(ValueError):
                feedback.focus_commands(commands, [selector])
        with self.assertRaises(ValueError):
            feedback.focus_commands([("core", ["test", "core"])], ["GitXTests/A"])

    def test_static_feedback_uses_file_lists_and_skips_script_suite_for_app_edits(self):
        feedback = self.feedback()
        self.write("Classes/new file.swift", "let a = 1\n")
        calls = []
        with mock.patch.object(feedback, "execute", side_effect=lambda command, root, env=None: calls.append((command, env))):
            feedback.static_feedback(self.root, "HEAD")
        lint, env = next(item for item in calls if "swiftlint" in item[0])
        self.assertIn("--use-script-input-files", lint)
        self.assertEqual(env["SCRIPT_INPUT_FILE_0"], str(self.root / "Classes/new file.swift"))
        self.assertFalse(any("unittest" in command for command, _ in calls))
        self.assertFalse(any("analyze" in command for command, _ in calls))

    def test_feedback_dry_run_does_not_write_receipts_or_bytecode(self):
        for path in (ROOT / "scripts").glob("*.py"):
            self.write("scripts/" + path.name, path.read_text())
        shutil.copy2(ROOT / "scripts/verification-config.json", self.root / "scripts/verification-config.json")
        before = set(self.root.rglob("*"))
        command = [sys.executable, str(self.root / "scripts/dev_workflow.py"), "verify", "--profile", "feedback", "--base-ref", "HEAD", "--dry-run"]
        result = subprocess.run(command, cwd=self.root, capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["deliveryEligible"])
        self.assertIn("selectedChecks", report)
        self.assertEqual(set(self.root.rglob("*")), before)

    def test_nib_inputs_are_absolute_and_preserve_spaces(self):
        feedback = self.feedback()
        self.write("Resources/new nib.xib", "fixture\n")
        calls = []
        with mock.patch.object(feedback, "execute", side_effect=lambda command, root, env=None: calls.append(command)):
            feedback.static_feedback(self.root, "HEAD")
        command = next(command for command in calls if "ibtool" in command)
        self.assertEqual(command[-1], str(self.root / "Resources/new nib.xib"))

    def test_static_does_not_claim_build_caches_or_desktop(self):
        resources, _ = session.entry_resources("verify_static.sh", [])
        self.assertEqual(resources, [])


if __name__ == "__main__":
    unittest.main()
