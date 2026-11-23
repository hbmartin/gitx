from __future__ import annotations

import copy
import json
import pathlib
import plistlib
import signal
import subprocess
import sys
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

    def test_debug_staging_requires_matching_child_provenance(self):
        receipt = pathlib.Path("artifacts/verification/child/receipt.json")
        digest = {"sha256": "debug"}
        step = {"outputs": {"build/GitX.app": digest}}
        child = {"runId": "child", "status": "passed", "invocation": {"configuration": "Debug", "preset": "build"},
                 "evidence": {"stagedApp": digest}}
        self.assertTrue(workflow.staged_debug_matches(step, child, receipt))
        self.assertFalse(workflow.staged_debug_matches(step, child | {"runId": "other"}, receipt))
        self.assertFalse(workflow.staged_debug_matches(step, child | {
            "invocation": {"configuration": "Release", "preset": "build"}}, receipt))
        self.assertFalse(workflow.staged_debug_matches(step, child | {"evidence": {"stagedApp": {}}}, receipt))

    def test_supervisor_cancels_before_launch_and_reaps_a_started_child(self):
        original = signal.getsignal(signal.SIGTERM)

        def interrupt():
            handler = signal.getsignal(signal.SIGTERM)
            self.assertNotEqual(handler, original)
            handler(signal.SIGTERM, None)

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.object(session, "producer_identity", side_effect=lambda: interrupt() or {}), \
                    mock.patch.object(session.subprocess, "Popen") as spawn:
                self.assertEqual(session.supervise(["/usr/bin/true"], directory=root / "before"), 130)
                spawn.assert_not_called()
            self.assertEqual(signal.getsignal(signal.SIGTERM), original)
            spawn = session.subprocess.Popen
            children = []

            def launch(*args, **kwargs):
                child = spawn(*args, **kwargs)
                if kwargs.get("start_new_session"):
                    children.append(child)
                    interrupt()
                return child

            with mock.patch.object(session.subprocess, "Popen", side_effect=launch):
                self.assertEqual(session.supervise([sys.executable, "-c", "import time; time.sleep(30)"],
                                                   timeout=5, directory=root / "after"), 130)
            self.assertEqual(len(children), 1)
            self.assertIsNotNone(children[0].returncode)
            self.assertEqual(signal.getsignal(signal.SIGTERM), original)

    def test_contended_shared_build_lease_preserves_blocked_status(self):
        with tempfile.TemporaryDirectory() as directory:
            argv = ["workflow_session", "run", "--diagnostics", directory, "--timeout", "0", "--xcode-build",
                    "--", "/usr/bin/true"]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(session, "supervise") as launch, \
                    mock.patch.object(session.Leases, "__enter__",
                                      side_effect=session.ResourceBusy("/fixture", {"runId": "holding"})):
                self.assertEqual(session.main(), 75)
                launch.assert_not_called()
            blocker = json.loads((pathlib.Path(directory) / "blocker.json").read_text())
            self.assertEqual(blocker["category"], "resource-busy")
            self.assertEqual(blocker["owner"]["runId"], "holding")

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
            root = pathlib.Path(directory).resolve()
            artifacts = root / "artifacts"
            path = artifacts / "fixture/receipt.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"status": "passed", "evidence": {"status": "valid"}}))
            with mock.patch.object(fixtures.session, "verification_artifact_root", return_value=artifacts), \
                    mock.patch.object(fixtures, "observed_tests", return_value=[("GitXTests/Case/testA", "passed")]):
                with self.assertRaisesRegex(ValueError, "testB"):
                    fixtures.verify_pass(root, "fixture", ["GitXTests/Case/testA", "GitXTests/Case/testB"])

    def test_broken_prior_receipt_does_not_hide_valid_failure_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            artifacts = root / "artifacts"
            bad = artifacts / "bad/receipt.json"
            good = artifacts / "good/receipt.json"
            workflow = artifacts / "prior/workflow.json"
            for path, contents in ((bad, "{"), (good, "{}"), (workflow, json.dumps({"steps": [
                    {"name": "correctness", "status": "failed", "receipt": str(bad)},
                    {"name": "thread-sanitizer", "status": "failed", "receipt": str(good)},
            ]}))):
                path.parent.mkdir(parents=True)
                path.write_text(contents)
            test = next(iter(fixtures.DISCOVERY))
            with mock.patch.object(session, "verification_artifact_root", return_value=artifacts), \
                    mock.patch.object(fixtures, "observed_tests", return_value=[(test, "failed")]) as observe:
                self.assertEqual(list(fixtures.failed_tests(root, workflow)), [test])
                observe.assert_called_once_with(root, {}, good)

    def test_fixture_subruns_own_rebuilt_cache_without_replacing_carried_test_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            artifacts = root / "artifacts"
            source = {"head": "source"}
            current = {"head": "evidence-only-descendant"}
            cache = root / "DerivedData"
            inputs_for_cache = {"derivedData": str(cache), "swiftPM": str(root / "SwiftPM"),
                                "sourcePackages": str(root / "SourcePackages")}
            selector = "GitXTests/Fixtures/testWorktree"
            preset = "thread-sanitizer"

            def leaf(run_id, stamp, inputs, arguments, products):
                path = artifacts / run_id / "receipt.json"
                result = path.parent / "Results/Run.xcresult"
                result.mkdir(parents=True)
                (result / "result").write_text(run_id)
                evidence = {"status": "valid", "inputsBefore": inputs, "inputsAfter": inputs, "products": products,
                            "dependencyProducts": {}, "results": {str(result): session.tree_identity(result)}}
                session.atomic_json(path, {"runId": run_id, "finishedAt": stamp, "status": "passed", "exitCode": 0,
                                    "invocation": {"configuration": "Debug", "preset": "test:" + preset, "arguments": arguments},
                                    "buildPaths": {"derivedData": str(cache)}, "steps": [
                                        {"name": "test:" + preset, "status": "passed", "xcresult": str(result)}],
                                    "evidence": evidence})
                return path, result

            original, original_result = leaf("original", "2026-11-18T00:00:00Z", source, [preset], {"old": {}})
            manifest = artifacts / "fixtures/receipt.json"
            runs = []
            for i in session.FIXTURE_REPETITIONS:
                run_id = f"fixtures-{preset}-{i}"
                path, _ = leaf(run_id, f"2026-11-19T00:00:0{i}Z", current, [preset, "-only-testing:" + selector],
                               {"descendant": i})
                runs.append({"runId": run_id, "preset": preset, "selectors": [selector],
                             "receiptIdentity": session.file_identity(path)})
            session.atomic_json(manifest, {"runId": "fixtures", "status": "passed", "entry": str(root / "scripts/check_fixture_stability.py"),
                                "selectedFixtures": {preset: [selector]}, "fixtureRuns": runs,
                                "evidence": {"status": "valid", "inputsAfter": current}})
            workflow_receipt = {"artifactProofVersion": session.ARTIFACT_PROOF_VERSION, "steps": [
                {"name": preset, "status": "passed", "receipt": str(original), "toolchain": "fixture"},
                {"name": "fixture-stability", "status": "passed", "receipt": str(manifest), "toolchain": "fixture",
                 "fixtureReceiptIdentity": session.file_identity(manifest)},
            ]}
            with mock.patch.object(session, "verification_artifact_root", return_value=artifacts), \
                    mock.patch.object(session, "cache_paths", return_value=inputs_for_cache):
                receipts = list(session.workflow_child_receipts(workflow_receipt, root))
                self.assertEqual(len(receipts), 5)
                caches = session.workflow_cache_snapshots(workflow_receipt, root)
                self.assertEqual(caches["products"], {str(cache): {"descendant": 3}})
                original_child = receipts[0][2]
                self.assertEqual(session.receipt_artifact_problems(original_child, root, caches), [])
                (original_result / "result").write_text("unverified")
                self.assertTrue(session.receipt_artifact_problems(original_child, root, caches))
                (artifacts / "fixtures-thread-sanitizer-3/receipt.json").write_text("{}")
                with self.assertRaisesRegex(ValueError, "Fixture child receipt changed"):
                    session.workflow_cache_snapshots(workflow_receipt, root)

    def test_receipts_and_results_are_fenced_before_content_is_accessed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            artifacts = root / "artifacts"
            artifacts.mkdir()
            (root / "other").mkdir()
            (artifacts / "redirected").symlink_to(root / "other")
            with mock.patch.object(session, "verification_artifact_root", return_value=artifacts):
                for path in (root / "other/receipt.json", artifacts / "redirected/receipt.json"):
                    with self.subTest(path=path), self.assertRaises(ValueError):
                        session.workflow_receipt_path(root, path)
                with self.assertRaises(ValueError):
                    session.owned_result_path(root, artifacts / "producer/receipt.json",
                                              artifacts / "sibling/Results/Result.xcresult")

    def test_discovery_failure_checks_neighboring_tests_too(self):
        selected = fixtures.select([], failed=fixtures.DISCOVERY)
        self.assertEqual(set(selected), {"correctness", "address-undefined", "thread-sanitizer"})
        self.assertTrue(all(selectors == ["GitXTests/GitBinaryReliabilityTests"] for selectors in selected.values()))


if __name__ == "__main__":
    unittest.main()
