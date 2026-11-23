from __future__ import annotations

import copy
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from support import fixture_git_environment
import check_fixture_stability as fixtures
import dev_workflow as workflow
import workflow_evidence_reuse as reuse
import workflow_feedback as feedback
import workflow_session as session


class EvidenceLineageTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name).resolve()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("Classes/Example.swift", "enum Example {}\n")
        self.write("CONTEXT.md", "Original\n")
        self.commit()
        self.before = session.inputs(self.root)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=fixture_git_environment(), capture_output=True, check=True).stdout

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")

    def test_clean_evidence_child_accepts_only_its_committed_paths(self):
        self.write("CONTEXT.md", "New definition\n")
        self.write("docs/diagnostics/measurement.json", '{"time": 42}')
        self.commit()
        self.assertEqual(reuse.lineage(self.root, self.before, session.inputs(self.root)),
                         ["CONTEXT.md", "docs/diagnostics/measurement.json"])
        self.write("Classes/New.swift", "Untracked\n")
        with self.assertRaisesRegex(ValueError, "untracked"):
            reuse.lineage(self.root, self.before, session.inputs(self.root))

    def test_reverted_executable_edit_still_rejects_reuse(self):
        self.write("Classes/Example.swift", "enum Different {}\n")
        self.commit()
        self.write("Classes/Example.swift", "enum Example {}\n")
        self.write("CONTEXT.md", "New definition\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "Classes/Example.swift"):
            reuse.lineage(self.root, self.before, session.inputs(self.root))

    def test_dirty_source_receipt_cannot_authorize_reuse(self):
        self.write("CONTEXT.md", "Version present only during original run\n")
        dirty = session.inputs(self.root)
        self.write("CONTEXT.md", "Actually committed evidence\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "recorded commit"):
            reuse.lineage(self.root, dirty, session.inputs(self.root))

    def test_path_mode_change_does_not_qualify(self):
        (self.root / "CONTEXT.md").chmod(0o755)
        self.commit()
        with self.assertRaisesRegex(ValueError, "CONTEXT.md"):
            reuse.lineage(self.root, self.before, session.inputs(self.root))

    def test_staged_bundle_must_use_current_commit_version(self):
        self.write("CONTEXT.md", "New definition\n")
        self.commit()
        head = self.git("rev-parse", "HEAD").decode().strip()
        info = self.root / "build/GitX.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        tag = self.git("describe", "--tags", "--always").decode().strip()
        branch = self.git("rev-parse", "--abbrev-ref", "HEAD").decode().strip()
        info.write_bytes(plistlib.dumps({"CFBundleBuildVersion": f"{tag}-{branch}", "CFBundleVersion": "0.0.2 [arm]"}))
        reuse.verify_staged_version(self.root, head)
        info.write_bytes(plistlib.dumps({"CFBundleBuildVersion": f"{tag}-{branch}", "CFBundleVersion": "0.0.1 [arm]"}))
        with self.assertRaisesRegex(ValueError, "version"):
            reuse.verify_staged_version(self.root, head)

    def test_coverage_ratchet_keeps_file_and_group_floors(self):
        original = {"version": 1, "target": "GitX", "minimumLineCoverage": .94, "files": {"file": .9},
                    "groups": {"group": {"minimumLineCoverage": .8, "files": ["file"]}}}
        candidate = copy.deepcopy(original)
        candidate["files"]["file"] += .01
        reuse.validate_floors(original, candidate)
        candidate["groups"]["group"]["minimumLineCoverage"] -= .01
        with self.assertRaisesRegex(ValueError, "lowered"):
            reuse.validate_floors(original, candidate)
        candidate = copy.deepcopy(original)
        candidate["files"].pop("file")
        with self.assertRaisesRegex(ValueError, "removed"):
            reuse.validate_floors(original, candidate)


class VerificationSchedulingTests(unittest.TestCase):
    def test_independent_checks_overlap_while_native_check_owns_its_lane(self):
        overrides = ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE")
        clean_environment = {key: value for key, value in workflow.os.environ.items() if key not in overrides}
        with mock.patch.dict(workflow.os.environ, clean_environment, clear=True):
            self.assertTrue(workflow.permitted_check("analyze", {"correctness"}, {"analyze", "ui"}))
            self.assertFalse(workflow.permitted_check("ui", {"correctness"}, {"ui"}))
            self.assertFalse(workflow.permitted_check("analyze", {"debug-test-build"}, {"analyze"}))
            self.assertFalse(workflow.permitted_check("performance", {"analyze"}, {"performance", "stage-debug"}))
            self.assertFalse(workflow.permitted_check("stage-debug", set(), {"performance", "stage-debug"}))
            self.assertTrue(workflow.permitted_check("stage-debug", set(), {"stage-debug"}))
            for key in overrides:
                with self.subTest(override=key), mock.patch.dict(workflow.os.environ, {key: "/a/shared/path"}):
                    self.assertFalse(workflow.permitted_check("analyze", {"correctness"}, {"analyze"}))
                    self.assertFalse(workflow.permitted_check("analyze", set(), {"analyze", "correctness"}))
                    self.assertTrue(workflow.permitted_check("analyze", set(), {"analyze"}))

    def test_failure_stops_admission_and_settles_running_peer(self):
        def job(exit_code, waits):
            child = mock.Mock()
            child.poll.side_effect = [None] * waits + [exit_code] * 3
            return child

        commands = [(name, [name]) for name in ("static", "interop", "correctness")]
        static_pass, interop_failure = job(0, 1), job(9, 0)
        record = mock.Mock(side_effect=lambda *args: (args[-1], {"name": args[3]}))
        inputs = {"head": "candidate", "source": "same"}
        run = {"runId": "fixture", "inputsBefore": inputs}
        with mock.patch.object(workflow.subprocess, "Popen", side_effect=[static_pass, interop_failure]) as launch, \
                mock.patch.object(workflow, "record_check", record), \
                mock.patch.object(workflow.session, "inputs", return_value=inputs), \
                mock.patch.object(workflow.time, "sleep"):
            status, failed = workflow.execute_parallel(pathlib.Path("/tmp"), pathlib.Path("/tmp/workflow.json"), run,
                                                       SimpleNamespace(timeout=1, resume=None), commands,
                                                       {"toolchain": "fixture"}, {}, {}, None)
        self.assertEqual((status, failed), (9, {"name": "interop"}))
        self.assertEqual(launch.call_count, 2)
        self.assertEqual([call.args[3] for call in record.call_args_list], ["interop", "static"])
        static_pass.terminate.assert_not_called()


class FeedbackAndFixtureSelectionTests(unittest.TestCase):
    def test_test_file_feedback_uses_discovered_classes_and_conservative_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "GitXTests/Fixture.swift"
            path.parent.mkdir()
            path.write_text("@MainActor\nfinal class FixtureTests: XCTestCase {}\n")
            self.assertEqual(feedback.test_file_selectors(root, ["GitXTests/Fixture.swift"]), ["GitXTests/FixtureTests"])
            self.assertEqual(feedback.test_file_selectors(root, ["GitXTests/Fixture.swift", "GitXTests/Removed.swift"]), [])

    def test_focused_feedback_discovers_same_line_actor_attributes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "GitXTests/Mixed.swift"
            path.parent.mkdir()
            path.write_text("final class A: XCTestCase {}\n@MainActor final class B: XCTestCase {}\n")
            self.assertEqual(feedback.test_file_selectors(root, ["GitXTests/Mixed.swift"]),
                             ["GitXTests/A", "GitXTests/B"])
            path.write_text("final class A: XCTestCase {}\nfinal class B: SharedTestCase {}\n")
            args = workflow.parser().parse_args(["verify", "--profile", "feedback"])
            with mock.patch.object(feedback, "changed_paths", return_value=("base", ["GitXTests/Mixed.swift"])), \
                    mock.patch.object(feedback, "contract_selectors", return_value=["GitXTests/A"]):
                commands, selection = workflow.selected_commands(args, root)
            self.assertIn("correctness", dict(commands))
            self.assertEqual(selection["testSelectors"], [])

    def test_deleted_script_test_uses_broad_discovery_even_after_rename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "scripts/tests/test_destination.py"
            path.parent.mkdir(parents=True)
            path.touch()
            self.assertEqual(feedback.script_test_patterns(["scripts/tests/test_destination.py"], root),
                             ["test_destination.py"])
            self.assertEqual(feedback.script_test_patterns(
                ["scripts/tests/test_original.py", "scripts/tests/test_destination.py"], root), ["test*.py"])

    def test_shared_fixture_changes_cover_every_relevant_plan_but_ordinary_changes_do_not(self):
        self.assertEqual(fixtures.select(["Classes/Unrelated.swift"]), {})
        shared = fixtures.select(["GitXTests/GitXTestGitFixture.swift"])
        self.assertEqual(set(shared), {"correctness", "address-undefined", "thread-sanitizer", "ui"})
        self.assertTrue(fixtures.WORKTREE <= set(shared["thread-sanitizer"]))
        self.assertEqual(set(shared["ui"]), fixtures.QUIT_UI)

    def test_fixture_pass_requires_every_selected_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "fixture/receipt.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"status": "passed", "evidence": {"status": "valid"}}))
            with mock.patch.object(fixtures.session, "verification_artifact_root", return_value=root), \
                    mock.patch.object(fixtures, "observed_tests", return_value=[("GitXTests/Case/testA", "passed")]):
                with self.assertRaisesRegex(ValueError, "testB"):
                    fixtures.verify_pass(root, "fixture", ["GitXTests/Case/testA", "GitXTests/Case/testB"])

    def test_discovery_failure_checks_neighboring_tests_too(self):
        selected = fixtures.select([], failed=fixtures.DISCOVERY)
        self.assertEqual(set(selected), {"correctness", "address-undefined", "thread-sanitizer"})
        self.assertTrue(all(selectors == ["GitXTests/GitBinaryReliabilityTests"] for selectors in selected.values()))


if __name__ == "__main__":
    unittest.main()
