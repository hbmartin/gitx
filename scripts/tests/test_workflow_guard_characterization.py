"""Passing receipt and lease contracts before tightening resource refresh."""
from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from support import load_script
import workflow_session as session


class WorkflowGuardCharacterizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "verification-config.json").write_text('{"artifactRoot":"artifacts/verification"}')
        self.entry = scripts / "fixture.sh"
        self.resource = str(self.root / "cache")
        self.paths = {"derivedData": self.resource, "swiftPM": "packages", "sourcePackages": "sources"}
        self.inputs = {"root": str(self.root), "head": "head", "source": "source",
                       "dependencies": "dependencies", "plans": "plans"}
        self.receipt = self.root / "artifacts/verification/Coordination/fixture.json"
        self.lease = mock.MagicMock()
        held = self.lease.__enter__.return_value
        held.held = {self.resource: {}}
        held.wait_seconds = 0
        held.environment.return_value = {}
        held.descriptors.return_value = ()
        for patch in (
            mock.patch.dict(os.environ, {"GITX_SESSION_ID": "fixture"}, clear=True),
            mock.patch.object(session, "producer_identity", return_value={"pid": 123, "started": "birth"}),
            mock.patch.object(session, "entry_resources", return_value=([self.resource], self.paths)),
            mock.patch.object(session, "inputs", return_value=self.inputs),
            mock.patch.object(session, "Leases", return_value=self.lease),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def test_stable_resources_publish_passed_completion_after_execution(self):
        with mock.patch.object(session, "supervise", return_value=0) as execute:
            self.assertEqual(session.guard(self.entry, []), 0)
        value = json.loads(self.receipt.read_text())
        self.assertEqual(value["status"], "passed")
        self.assertEqual(value["exitCode"], 0)
        self.assertEqual(value["resources"], [self.resource])
        self.assertEqual(value["evidence"]["inputsBefore"], self.inputs)
        self.assertEqual(value["evidence"]["inputsAfter"], self.inputs)
        self.assertTrue(value["finishedAt"])
        execute.assert_called_once()

    def test_resource_conflict_records_owner_and_never_starts_command(self):
        owner = {"runId": "other", "pid": 456, "receipt": "other.json"}
        self.lease.__enter__.side_effect = session.ResourceBusy(self.resource, owner)
        with mock.patch.object(session, "supervise") as execute:
            self.assertEqual(session.guard(self.entry, []), 75)
        value = json.loads(self.receipt.read_text())
        self.assertEqual(value["status"], "blocked")
        self.assertEqual(value["exitCode"], 75)
        self.assertEqual(value["category"], "resource-busy")
        self.assertEqual(value["owner"], owner)
        self.assertNotIn("evidence", value)
        execute.assert_not_called()
