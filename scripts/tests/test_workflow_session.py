from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from support import ROOT
import workflow_session as session
import dev_workflow as workflow


class WorkflowSessionTests(unittest.TestCase):
    def test_collision_alias_nested_ownership_and_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / "products"
            target.mkdir()
            alias = root / "alias"
            alias.symlink_to(target)
            owner = {"runId": "first", "pid": os.getpid(), "receipt": "receipt.json"}
            with session.Leases([str(target)], owner, root / "locks", inherited={}) as parent:
                with self.assertRaises(session.ResourceBusy) as raised:
                    with session.Leases([str(alias)], owner, root / "locks", inherited={}):
                        pass
                self.assertEqual(raised.exception.owner["runId"], "first")
                with session.Leases([str(alias)], owner, root / "locks", inherited=parent.held):
                    pass
                with self.assertRaises(session.ResourceBusy):
                    with session.Leases([str(target)], owner, root / "locks", inherited={}):
                        pass
            with session.Leases([str(alias)], owner, root / "locks", inherited={}):
                pass

    def test_forged_nested_environment_does_not_claim_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = {"runId": "run", "pid": os.getpid(), "receipt": "receipt"}
            resource = str(pathlib.Path(directory) / "resource")
            with session.Leases([resource], owner, pathlib.Path(directory) / "locks", inherited={}) as parent:
                forged = {resource: {"socket": next(iter(parent.held.values()))["socket"], "token": "wrong"}}
                with self.assertRaises(session.ResourceBusy):
                    with session.Leases([resource], owner, pathlib.Path(directory) / "locks", inherited=forged):
                        pass

    def test_interrupted_process_releases_kernel_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resource = str(root / "resource")
            script = "import sys,time;sys.path.insert(0,sys.argv[1]);import workflow_session as s;" \
                     "l=s.Leases([sys.argv[2]],{'runId':'child','pid':1,'receipt':'receipt'},sys.argv[3],inherited={});" \
                     "l.__enter__();print('ready',flush=True);time.sleep(30)"
            child = subprocess.Popen([sys.executable, "-c", script, str(ROOT / "scripts"), resource, str(root / "locks")], stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), "ready")
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=5)
                with session.Leases([resource], {"runId": "new", "pid": 1, "receipt": "new"}, root / "locks", inherited={}):
                    pass
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                child.stdout.close()

    def test_persistent_external_worker_cannot_inherit_a_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resource = str(root / "resource")
            script = "import sys,time,subprocess,os;sys.path.insert(0,sys.argv[1]);import workflow_session as s;" \
                "l=s.Leases([sys.argv[2]],{'runId':'owner','pid':os.getpid(),'receipt':'receipt'},sys.argv[3],inherited={});" \
                "l.__enter__();p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],close_fds=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);" \
                "print(p.pid,flush=True);time.sleep(30)"
            owner = subprocess.Popen([sys.executable, "-c", script, str(ROOT / "scripts"), resource, str(root / "locks")], stdout=subprocess.PIPE, text=True)
            worker = None
            try:
                worker = int(owner.stdout.readline())
                owner.kill()
                owner.wait(timeout=5)
                os.kill(worker, 0)  # The external worker is still alive.
                with session.Leases([resource], {"runId": "next", "pid": os.getpid(), "receipt": "next"}, root / "locks", inherited={}):
                    pass
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait()
                if worker:
                    try:
                        os.kill(worker, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                owner.stdout.close()

    def test_partitioned_paths_and_explicit_alias(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode Test"):
            first = session.cache_paths(pathlib.Path(directory) / "first", "Debug", "plain")
            other = session.cache_paths(pathlib.Path(directory) / "second", "Debug", "plain")
            sanitized = session.cache_paths(pathlib.Path(directory) / "first", "Debug", "thread-sanitizer")
            release = session.cache_paths(pathlib.Path(directory) / "first", "Release", "plain")
            self.assertEqual(len({p["derivedData"] for p in (first, other, sanitized, release)}), 4)
            with mock.patch.dict(os.environ, {"GITX_DERIVED_DATA": directory}):
                self.assertEqual(session.cache_paths()["derivedData"], str(pathlib.Path(directory).resolve()))

    def test_raw_test_execution_owns_desktop_but_compilation_does_not(self):
        with mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode Test"):
            for action in ("test", "test-without-building"):
                resources, _ = session.entry_resources("xcodebuild.sh", ["raw", "--", action])
                self.assertIn(f"desktop:{os.getuid()}", resources)
            resources, _ = session.entry_resources("xcodebuild.sh", ["raw", "--", "build-for-testing"])
            self.assertNotIn(f"desktop:{os.getuid()}", resources)

    def test_cache_root_override_preserves_partitions_and_individual_overrides(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode Test"):
            root = pathlib.Path(directory).resolve()
            cache = root / "protected"
            cache.mkdir()
            alias = root / "alias"
            alias.symlink_to(cache)
            with mock.patch.dict(os.environ, {"GITX_VERIFICATION_CACHE_ROOT": str(alias)}):
                paths = [session.cache_paths(root / checkout, configuration, instrumentation)
                         for checkout, configuration, instrumentation in (
                             ("first", "Debug", "plain"), ("second", "Debug", "plain"),
                             ("first", "Release", "plain"), ("first", "Debug", "correctness"))]
                self.assertEqual(len({value["derivedData"] for value in paths}), 4)
                for value in paths:
                    for key in ("derivedData", "swiftPM", "sourcePackages"):
                        self.assertTrue(pathlib.Path(value[key]).is_relative_to(cache))
                self.assertIn("correctness-atomic", pathlib.Path(paths[-1]["derivedData"]).parts)
                with mock.patch.dict(os.environ, {"GITX_DERIVED_DATA": str(root / "explicit")}):
                    self.assertEqual(session.cache_paths(root)["derivedData"], str(root / "explicit"))

    def test_relative_cache_root_is_resolved_against_checkout(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"GITX_VERIFICATION_CACHE_ROOT": "verification-cache"}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode Test"):
            root = pathlib.Path(directory).resolve()
            result = session.cache_paths(root)
            self.assertTrue(pathlib.Path(result["derivedData"]).is_relative_to(root / "verification-cache"))

    def test_interruption_stops_descendants_in_separate_process_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            pid_file = root / "grandchild.pid"
            command = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True);" \
                "open(sys.argv[1],'w').write(str(p.pid));time.sleep(30)"
            supervisor = subprocess.Popen([sys.executable, str(ROOT / "scripts/workflow_session.py"), "run", "--diagnostics", str(root), "--", sys.executable, "-c", command, str(pid_file)], stdout=subprocess.DEVNULL)
            grandchild = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and (not pid_file.exists() or not pid_file.read_text()):
                    time.sleep(.01)
                grandchild = int(pid_file.read_text())
                supervisor.terminate()
                supervisor.wait(timeout=15)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    state = subprocess.run(["ps", "-p", str(grandchild), "-o", "stat="], capture_output=True, text=True).stdout.strip()
                    if not state or state.startswith("Z"):
                        break
                    time.sleep(.02)
                self.assertTrue(not state or state.startswith("Z"), "Nested owned process survived interruption")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait()
                if grandchild:
                    try:
                        os.kill(grandchild, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_source_and_product_replacement_invalidate_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q", root], check=True)
            (root / "Classes").mkdir()
            source = root / "Classes/A.swift"
            source.write_text("first")
            before = session.inputs(root)
            source.write_text("second")
            self.assertIn("source", session.changed_inputs(before, session.inputs(root)))
            product = root / "Build/Products/Debug/Test.app"
            product.mkdir(parents=True)
            (product / "binary").write_text("first")
            identity = session.product_identity(root)
            (product / "binary").write_text("second")
            self.assertNotEqual(identity, session.product_identity(root))

    def test_generated_header_touch_is_valid_but_content_or_product_replacement_is_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q", root], check=True)
            (root / "Resources").mkdir()
            header = root / "Resources/GitX.h"
            header.write_text("generated bridge")
            subprocess.run(["git", "-C", root, "add", "Resources/GitX.h"], check=True)
            before = session.inputs(root)
            os.utime(header, ns=(header.stat().st_atime_ns, header.stat().st_mtime_ns + 1000000))
            self.assertFalse(session.changed_inputs(before, session.inputs(root)))
            header.write_text("changed bridge")
            self.assertIn("source", session.changed_inputs(before, session.inputs(root)))
            product = root / "Build/Products/Debug/Test.app"
            product.mkdir(parents=True)
            binary = product / "binary"
            binary.write_bytes(b"identical bytes")
            identity = session.product_identity(root)
            replacement = product / "replacement"
            replacement.write_bytes(binary.read_bytes())
            replacement.replace(binary)
            self.assertNotEqual(identity, session.product_identity(root))

    def test_historical_or_changed_resume_is_rejected(self):
        current = {"head": "a", "source": "b", "dependencies": "c", "plans": "d"}
        self.assertFalse(workflow.reusable({"status": "passed"}, current, ["test"]))
        step = {"status": "passed", "evidenceStatus": "valid", "command": ["test"], "inputsAfter": current, "toolchain": "test"}
        with mock.patch.object(session, "cache_paths", return_value={"toolchain": "test"}):
            self.assertTrue(workflow.reusable(step, current, ["test"]))
            self.assertFalse(workflow.reusable(step, current | {"source": "changed"}, ["test"]))
            self.assertFalse(workflow.reusable(step, current | {"head": "new-commit"}, ["test"]))

    def test_unavailable_desktop_reports_concrete_blocker(self):
        with mock.patch.object(session.platform, "system", return_value="Linux"):
            self.assertEqual(session.desktop_checks()[0]["name"], "desktop-unavailable")

    def test_signature_failure_is_distinct_from_unknown_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            product = pathlib.Path(directory) / "Build/Products/Debug/Test.app"
            product.mkdir(parents=True)
            with mock.patch.object(session.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "invalid signature")):
                with self.assertRaisesRegex(ValueError, "signature"):
                    session.verify_signatures(directory)

    def test_hardened_ad_hoc_host_signature_incompatibility_is_reported_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / "Build/Products/Release/Test.app"
            (app / "Contents/Frameworks/Dependency.framework").mkdir(parents=True)
            def signing(command, **kwargs):
                if "--verbose=4" in command:
                    return subprocess.CompletedProcess(command, 0, "", "flags=0x10002(adhoc,runtime)\nTeamIdentifier=not set\n")
                if "--xml" in command:
                    return subprocess.CompletedProcess(command, 0, b'<plist version="1.0"><dict/></plist>', b"")
                return subprocess.CompletedProcess(command, 0, "", "")
            with mock.patch.object(session.subprocess, "run", side_effect=signing):
                with self.assertRaisesRegex(ValueError, "signature-incompatible"):
                    session.verify_signatures(directory)

    def test_detached_hosts_require_session_evidence_and_pid_identity(self):
        table = "11 11 /app/GitX\n12 12 /app/GitX\n13 13 /app/GitX\n"
        responses = [subprocess.CompletedProcess([], 0, table, ""),
                     subprocess.CompletedProcess([], 0, "GitX GITX_VERIFICATION_SESSION=our-run", ""),
                     subprocess.CompletedProcess([], 0, "original-start", ""),
                     subprocess.CompletedProcess([], 0, "GitX GITX_VERIFICATION_SESSION=other-run", "")]
        with mock.patch.object(session.subprocess, "run", side_effect=responses):
            owned = session.detached_owned_processes("our-run", {"12"})
        self.assertEqual([p["pid"] for p in owned], [11])
        with mock.patch.object(session.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "new-start", "")), mock.patch.object(session.os, "kill") as kill:
            session.stop_detached(owned)
            kill.assert_not_called()

    def test_watchdog_preserves_failure_and_bounds_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            failed = session.supervise([sys.executable, "-c", "raise SystemExit(9)"], timeout=2, directory=directory)
            self.assertEqual(failed, 9)
            status = session.supervise([sys.executable, "-c", "import time;time.sleep(30)"], timeout=2, startup_timeout=.1, directory=directory)
            self.assertEqual(status, 124)
            self.assertEqual(json.loads((pathlib.Path(directory) / "blocker.json").read_text())["category"], "unknown-host-startup-timeout")
            status = session.supervise([sys.executable, "-c", "print('Test Suite started',flush=True)"], timeout=2, startup_timeout=1, directory=directory)
            self.assertEqual(status, 0)
