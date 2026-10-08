from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest

import workflow_records as records
import workflow_session as session


class WorkflowRecordsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", self.root], check=True)
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
        return subprocess.run(["git", "-C", self.root, *arguments], check=True, capture_output=True)

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
