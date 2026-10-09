from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from support import fixture_git_environment

import workflow_records as records
import workflow_session as session


class WorkflowRecordsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.environment = fixture_git_environment()
        subprocess.run(["git", "init", "-q", self.root], check=True, env=self.environment)
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.root / "source.txt").write_text("first\n")
        self.git("add", ".")
        self.git("commit", "-qm", "first")
        self.first = session.git(self.root, "rev-parse", "HEAD")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(["git", "-C", self.root, *arguments], check=True, capture_output=True, env=self.environment)

    def test_repository_selectors_cannot_redirect_workflow_inspection(self):
        import regression_guardrails as guardrails
        foreign = self.root.parent / "foreign"
        subprocess.run(["git", "clone", "-q", str(self.root), str(foreign)], check=True, env=self.environment)
        (self.root / "source.txt").write_text("second\n")
        self.git("commit", "-qam", "second")
        head = session.git(self.root, "rev-parse", "HEAD")
        expected_patch = records.patch_id(self.root, self.first, head)
        foreign_index = (foreign / ".git/index").read_bytes()
        with mock.patch.dict(os.environ, {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                                         "GIT_INDEX_FILE": str(foreign / ".git/index")}):
            self.assertEqual(session.git(self.root, "rev-parse", "HEAD"), head)
            self.assertEqual(guardrails.git(self.root, "rev-parse", "HEAD").decode().strip(), head)
            self.assertEqual(records.patch_id(self.root, self.first, head), expected_patch)
            with records.Ledger(self.root) as ledger:
                self.assertEqual(ledger.path.parent.parent, (self.root / ".git").resolve())
                ledger.register("selected", "fixture", base=self.first)
                scan = ledger.inventory()
                self.assertEqual(scan["observations"]["selected"]["head"], head)
                self.assertTrue(scan["observations"]["selected"]["ancestorOfCurrentHead"])
        self.assertEqual((foreign / ".git/index").read_bytes(), foreign_index)

    def test_fixture_commands_ignore_foreign_repository_and_global_config(self):
        with mock.patch.dict(os.environ, {"GIT_DIR": "/gitx-nonexistent", "GIT_CONFIG_GLOBAL": "/gitx-nonexistent"}):
            environment = fixture_git_environment()
        self.assertNotIn("GIT_DIR", environment)
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_SYSTEM"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")

    def test_ledger_shared_ownership_dirty_missing_and_export_import(self):
        other = self.root.parent / "other"
        self.git("worktree", "add", "-qb", "other", str(other))
        (other / "source.txt").write_text("dirty\n")
        with records.Ledger(self.root) as ledger:
            ledger.register("owned", "work", owner="chat-one", worktree=other)
            with self.assertRaisesRegex(ValueError, "owned"):
                ledger.update("owned", {"lifecycle": "done"}, owner="chat-two")
            scan = ledger.inventory()
            self.assertTrue(scan["observations"]["owned"]["dirtyState"])
            self.assertTrue(scan["duplicates"])
            output = self.root.parent / "export.json"
            ledger.export(output)
        with records.Ledger(other) as shared:
            self.assertIn("owned", shared.data["items"])
            shared.import_export(output)
            shared.update("owned", {"worktree": str(self.root.parent / "missing")}, owner="chat-one")
            scan = shared.inventory()
            self.assertFalse(scan["observations"]["owned"]["exists"])
            self.assertIn("owned", scan["changedSincePrevious"])

    def test_archive_seed_preserves_evidence_and_marks_uncertain(self):
        archive = self.root.parent / "recovery.tar.gz"
        archive.write_bytes(b"fixture")
        manifest = self.root.parent / "manifest.json"
        manifest.write_text(json.dumps({"records": [{"path": "/missing/checkout", "head": self.first,
            "archive": archive.name, "archive_sha256": session.digest(archive.read_bytes()), "action": "removed"}]}))
        with records.Ledger(self.root) as ledger:
            ledger.seed(manifest)
            item = next(iter(ledger.data["items"].values()))
            self.assertEqual(item["lifecycle"], "archived")
            self.assertEqual(item["conclusions"]["featureEquivalence"], "needs-review")
            self.assertTrue(archive.exists())
            export = ledger.export(self.root.parent / "export.json")
            self.assertIn(str(archive.resolve()), export["evidence"])

    def prepare(self, comments, target=None):
        source = self.root.parent / "comments.json"
        source.write_text(json.dumps(comments))
        self.record = self.root.parent / "review.json"
        return records.prepare_review(self.root, source, self.record, target)

    def test_missing_and_unresolvable_targets_prevent_classification(self):
        for metadata in ({}, {"commit_id": "deadbeef"}):
            prepared = self.prepare([{"id": "one", "body": "feedback", **metadata}])
            self.assertEqual(prepared["status"], "needs-target")
            with self.assertRaisesRegex(ValueError, "needs-target"):
                records.reconcile_review(self.root, self.record, [])
        ambiguous = self.prepare([{"id": "one", "body": "feedback"}], "ambiguous")
        self.assertEqual(ambiguous["status"], "needs-target")
        self.assertEqual(ambiguous["recoverableCandidates"][0]["candidate"], "ambiguous")

    def test_exact_review_target_duplicates_and_head_change(self):
        comments = [{"id": identity, "body": "feedback", "path": "source.txt", "line": 1,
                     "originalCommit": {"oid": self.first}} for identity in ("one", "two")]
        prepared = self.prepare(comments)
        self.assertEqual(prepared["comments"][1]["duplicateOf"], "one")
        decisions = [{"id": c["id"], "reviewedSHA": self.first, "currentHEAD": self.first,
                      "validityAtTarget": "confirmed", "currentActionability": "fix-now",
                      "evidence": ["source.txt:1 at reviewed commit"], "disposition": "should-be-fixed"} for c in comments]
        self.assertEqual(records.reconcile_review(self.root, self.record, decisions)["status"], "reconciled")
        (self.root / "source.txt").write_text("second\n")
        self.git("commit", "-qam", "second")
        with self.assertRaisesRegex(ValueError, "HEAD changed"):
            records.reconcile_review(self.root, self.record)
        refreshed = records.reconcile_review(self.root, self.record, refresh=True)
        self.assertEqual(refreshed["status"], "awaiting-classification")
        self.assertEqual(refreshed["comments"][0]["reviewedSHA"], self.first)
        self.assertTrue(refreshed["comments"][0]["sourceEvidence"]["changed"])
        with self.assertRaisesRegex(ValueError, "provenance"):
            records.reconcile_review(self.root, self.record, decisions)
