from __future__ import annotations

import json
import os
import pathlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from types import SimpleNamespace

from support import ROOT
import workflow_session as session
import dev_workflow as workflow


class WorkflowSessionTests(unittest.TestCase):
    def capture_fixture(self, root):
        scripts = root / 'scripts'
        scripts.mkdir()
        for name in ['workflow_session.py', 'verification-config.json']:
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        run = root / 'artifacts/verification/capture'
        (run / 'Logs').mkdir(parents=True)
        return scripts / 'workflow_session.py', run / 'Logs/command.log', run / 'Diagnostics/command'

    def test_wait_acquires_only_after_the_owner_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            resource = str(pathlib.Path(directory) / "resource")
            owner = {"runId": "first", "pid": os.getpid(), "receipt": "receipt"}
            first = session.Leases([resource], owner, directory, inherited={})
            first.__enter__()
            release = threading.Timer(.15, first.__exit__)
            release.start()
            self.addCleanup(release.join)
            try:
                with session.Leases([resource], owner | {"runId": "next"}, directory,
                                    inherited={}, wait_seconds=2) as waiting:
                    self.assertGreaterEqual(waiting.wait_seconds, .1)
                    self.assertEqual(set(waiting.held), {session.canonical_resource(resource)})
            finally:
                release.join()

    def test_resource_wait_is_bounded_and_invalid_waits_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = {"runId": "first", "pid": os.getpid(), "receipt": "receipt"}
            resource = str(pathlib.Path(directory) / "resource")
            with session.Leases([resource], owner, pathlib.Path(directory) / "locks", inherited={}):
                started = time.monotonic()
                with self.assertRaises(session.ResourceBusy):
                    with session.Leases([resource], owner, pathlib.Path(directory) / "locks", inherited={}, wait_seconds=.1):
                        pass
                self.assertGreaterEqual(time.monotonic() - started, .1)
                self.assertLess(time.monotonic() - started, 2)
            for value in (-1, float("nan"), float("inf")):
                with self.assertRaises(ValueError):
                    session.Leases([], owner, wait_seconds=value)

    def test_analyzer_requires_retained_identities_for_every_referenced_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            log = root / 'analyze.log'
            policy = root / 'policy.log'
            log.write_text('passed analysis')
            policy.write_text('passed policy')
            payload = {'invocation': {'preset': 'analyze'}, 'steps': [{'log': str(log)}, {'log': str(policy)}],
                       'evidence': {'dependencyProducts': {}, 'analysisArtifacts': {str(log): session.tree_identity(log)}}}
            self.assertTrue(session.receipt_artifact_problems(payload, root))
            payload['evidence']['analysisArtifacts'][str(policy)] = session.tree_identity(policy)
            self.assertEqual(session.receipt_artifact_problems(payload, root), [])
            policy.write_text('changed policy')
            self.assertTrue(session.receipt_artifact_problems(payload, root))
            payload['evidence']['analysisArtifacts'] = {}
            payload['steps'] = []
            self.assertTrue(session.receipt_artifact_problems(payload, root))

    def test_producer_pid_and_start_identity_distinguish_live_abandoned_and_uncertain(self):
        identity = {'pid': 123, 'started': 'birth', 'startedFormat': session.PRODUCER_START_FORMAT}
        with mock.patch.object(os, 'kill'), mock.patch.object(session, 'process_started', return_value='birth'):
            self.assertEqual(session.producer_state(identity), 'live')
        with mock.patch.object(os, 'kill'), mock.patch.object(session, 'process_started', return_value='reused'):
            self.assertEqual(session.producer_state(identity), 'abandoned')
        with mock.patch.object(os, 'kill', side_effect=ProcessLookupError):
            self.assertEqual(session.producer_state(identity), 'abandoned')
        with mock.patch.object(os, 'kill', side_effect=PermissionError):
            self.assertEqual(session.producer_state(identity), 'uncertain')
        self.assertEqual(session.producer_state({'pid': 123}), 'uncertain')

    def test_broker_authentication_accepts_a_partial_framed_reply(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.recv.side_effect = [b'o', b'wn', b'ed', b'\n']
        with mock.patch.object(session.socket, 'socket', return_value=connection):
            self.assertTrue(session.Leases.authenticated('/resource', {'socket': '/socket', 'token': 'token'}))
        self.assertTrue(connection.sendall.call_args.args[0].endswith(b'\n'))
        connection.shutdown.assert_not_called()

    def test_final_cache_ownership_compares_instants_with_timezone_offsets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            steps = []
            for index, (stamp, products) in enumerate([('2026-10-09T10:00:00+00:00', {'latest': True}),
                                                      ('2026-10-09T11:00:00+02:00', {'earlier': True})]):
                path = root / f'{index}.json'
                path.write_text(json.dumps({'finishedAt': stamp, 'buildPaths': {'derivedData': '/cache'},
                                            'evidence': {'products': products}}))
                steps.append({'receipt': str(path)})
            self.assertEqual(session.workflow_cache_snapshots({'steps': steps}, root)['products']['/cache'], {'latest': True})

    def test_lease_releases_descriptors_when_broker_cleanup_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = {'runId': 'fixture', 'pid': os.getpid(), 'receipt': 'fixture'}
            lease = session.Leases(['/fixture'], owner, lock_root=directory, inherited={})
            lease.__enter__()
            streams = list(lease.opened)
            broker_directory = lease.broker_directory
            with mock.patch.object(broker_directory, 'cleanup', side_effect=OSError('disk failure')):
                with self.assertRaises(OSError):
                    lease.__exit__()
            self.assertTrue(all(stream.closed for stream in streams))
            with session.Leases(['/fixture'], owner, lock_root=directory, inherited={}):
                pass
            broker_directory.cleanup()

    def test_supervisor_preserves_legacy_diagnostics_and_records_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / 'legacy.log').write_text('keep')
            self.assertEqual(session.supervise([sys.executable, '-c', 'print("done")'], directory=path), 0)
            self.assertFalse((path / 'diagnostic-owner.json').exists())
            manifest = next(path.glob('owned-*/diagnostic-owner.json'))
            value = json.loads(manifest.read_text())
            self.assertEqual(value['status'], 'passed')
            self.assertEqual(value['producer']['pid'], os.getpid())
            self.assertTrue(value['producer']['started'])
            self.assertEqual((path / 'legacy.log').read_text(), 'keep')

    def test_supervisor_preserves_complete_binary_output_and_failure_status(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = bytes(range(256)) * 4096
            command = 'import os; os.write(1, bytes(range(256)) * 4096); os.write(2, b"failure\\n"); raise SystemExit(7)'
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/workflow_session.py'), 'run',
                                     '--diagnostics', directory, '--', sys.executable, '-c', command],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(result.stdout, payload + b'failure\n')
            self.assertEqual(json.loads((pathlib.Path(directory) / 'diagnostic-owner.json').read_text())['status'], 'failed')

    def test_captured_output_keeps_every_byte_and_the_child_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            payload = bytes(range(256)) * 4096 + b'failure\n'
            command = 'import os; os.write(1, bytes(range(256)) * 4096); os.write(2, b"failure\\n"); raise SystemExit(7)'
            result = subprocess.run([sys.executable, str(entry), 'run',
                                     '--diagnostics', str(diagnostics), '--output-log', str(output),
                                     '--', sys.executable, '-c', command], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(result.stdout, payload)
            self.assertEqual(output.read_bytes(), payload)
            manifest = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            self.assertEqual(manifest['status'], 'failed')
            self.assertTrue(manifest['outputCapture']['consoleComplete'])

    def test_blocked_console_cannot_delay_child_completion_or_lose_the_raw_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            progress = root / 'progress'
            os.mkfifo(progress)
            descriptor = os.open(progress, os.O_RDWR | os.O_NONBLOCK)
            self.addCleanup(os.close, descriptor)
            command = ('import sys; sys.stdout.buffer.write(bytes(range(256)) * 16384); sys.stdout.flush(); '
                       'open(sys.argv[1], "w").write("finished"); raise SystemExit(7)')
            with subprocess.Popen([sys.executable, str(entry), 'run',
                                   '--diagnostics', str(diagnostics), '--output-log', str(output),
                                   '--', sys.executable, '-c', command, str(progress)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                try:
                    # Neither console stream is drained before the independent
                    # progress signal and the supervisor's exit are observed.
                    self.assertTrue(select.select([descriptor], [], [], 5)[0], 'Child stalled behind the console')
                    self.assertEqual(os.read(descriptor, 32), b'finished')
                    self.assertEqual(process.wait(timeout=5), 7)
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.communicate(timeout=10)
            self.assertEqual(output.read_bytes(), bytes(range(256)) * 16384)
            manifest = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            self.assertFalse(manifest['outputCapture']['consoleComplete'])
            self.assertEqual(manifest['outputCapture']['capturedBytes'], output.stat().st_size)
            self.assertEqual(json.loads(output.with_name(output.name + '.capture.json').read_text()), manifest['outputCapture'])

    def test_captured_output_retains_watchdog_failure_and_rejects_symlink_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            result = subprocess.run([sys.executable, str(entry), 'run',
                                     '--timeout', '0.2', '--diagnostics', str(diagnostics),
                                     '--output-log', str(output), '--', sys.executable, '-c',
                                     'import time; print("started", flush=True); time.sleep(30)'],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertIn(b'started\n', output.read_bytes())
            self.assertIn(b'Verification blocker: command-timeout', output.read_bytes())
            target = output.parent / 'preserve.log'
            target.write_text('keep')
            output.unlink()
            output.symlink_to(target)
            marker = root / 'child-started'
            with mock.patch.object(session, 'ROOT', root), self.assertRaisesRegex(ValueError, 'symlink'):
                session.supervise([sys.executable, '-c', f'open({str(marker)!r}, "w").close()'],
                                  directory=root / 'symlink-diagnostics', output_log=output)
            self.assertFalse(marker.exists())
            self.assertEqual(target.read_text(), 'keep')

    def test_raw_capture_failure_stops_the_owned_child_and_fails_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, diagnostics = self.capture_fixture(root)
            child = None
            spawn = session.subprocess.Popen
            fsync = os.fsync
            def fail_capture_flush(descriptor):
                if output.exists() and os.fstat(descriptor).st_ino == output.stat().st_ino:
                    raise OSError('injected capture flush failure')
                return fsync(descriptor)
            def remember(*arguments, **keywords):
                nonlocal child
                process = spawn(*arguments, **keywords)
                if keywords.get('start_new_session'):
                    child = process
                return process
            with mock.patch.object(session, 'ROOT', root), \
                    mock.patch.object(session.subprocess, 'Popen', side_effect=remember), \
                    mock.patch.object(session.os, 'fsync', side_effect=fail_capture_flush), \
                    mock.patch.object(session.CapturedConsole, 'write', side_effect=OSError('disk full')):
                status = session.supervise([sys.executable, '-c', 'import time; print("started", flush=True); time.sleep(30)'],
                                           timeout=5, directory=diagnostics, output_log=output)
            self.assertEqual(status, 74)
            self.assertIsNotNone(child.returncode)
            self.assertEqual(json.loads((diagnostics / 'blocker.json').read_text())['category'], 'output-capture-failed')
            manifest = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            self.assertEqual(manifest['status'], 'failed')
            self.assertEqual(manifest['outputCapture']['flushError'], 'OSError')

    def test_failed_capture_flush_preserves_child_status_and_reports_capture_failure(self):
        for child_status in [0, 7]:
            with self.subTest(child_status=child_status), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, diagnostics = self.capture_fixture(root)
                fsync = os.fsync
                def fail_capture_flush(descriptor):
                    if output.exists() and os.fstat(descriptor).st_ino == output.stat().st_ino:
                        raise OSError('injected capture flush failure')
                    return fsync(descriptor)
                with mock.patch.object(session, 'ROOT', root), \
                        mock.patch.object(session.os, 'fsync', side_effect=fail_capture_flush):
                    status = session.supervise([sys.executable, '-c', f'print("fixture", flush=True); raise SystemExit({child_status})'],
                                               directory=diagnostics, output_log=output)
                self.assertEqual(status, 74)
                manifest = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                self.assertEqual(manifest['status'], 'failed')
                self.assertEqual(manifest['category'], 'output-capture-failed')
                self.assertEqual(manifest['childExitCode'], child_status)
                self.assertEqual(manifest['outputCapture']['flushError'], 'OSError')
                self.assertFalse(manifest['outputCapture']['captureComplete'])
                self.assertEqual(output.read_bytes(), b'fixture\n')

    def test_capture_destination_cannot_escape_the_configured_artifact_directory(self):
        for variant in ['absolute', 'traversal', 'prefix', 'parent-symlink']:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                entry, output, diagnostics = self.capture_fixture(root)
                foreign = root / 'foreign/keep.log'
                foreign.parent.mkdir()
                foreign.write_text('keep')
                marker = root / 'child-started'
                if variant == 'absolute':
                    destination = foreign
                elif variant == 'traversal':
                    destination = output.parent / '../../../../foreign/keep.log'
                elif variant == 'prefix':
                    foreign = root / 'artifacts/verification-foreign/keep.log'
                    foreign.parent.mkdir()
                    foreign.write_text('keep')
                    destination = foreign
                else:
                    alias = output.parent / 'alias'
                    alias.symlink_to(foreign.parent, target_is_directory=True)
                    destination = alias / foreign.name
                result = subprocess.run([sys.executable, str(entry), 'run', '--diagnostics', str(diagnostics),
                                         '--output-log', str(destination), '--', sys.executable, '-c',
                                         f'open({str(marker)!r}, "w").close(); print("replace")'],
                                        capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(foreign.read_text(), 'keep')
                self.assertFalse(marker.exists())

    def test_git_environment_scrubs_repository_selectors_but_preserves_configuration(self):
        selectors = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH", "GIT_NAMESPACE")
        inherited = {key: "foreign" for key in selectors} | {"GIT_CONFIG_GLOBAL": "configured", "GIT_AUTHOR_NAME": "Author", "PATH": "/usr/bin"}
        with mock.patch.dict(os.environ, inherited, clear=True):
            environment = session.git_environment()
            self.assertEqual(os.environ["GIT_DIR"], "foreign")
        self.assertFalse(set(selectors) & environment.keys())
        self.assertEqual(environment, {"GIT_CONFIG_GLOBAL": "configured", "GIT_AUTHOR_NAME": "Author", "PATH": "/usr/bin"})

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

    def test_inherited_lease_authentication_survives_fast_broker_close(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resource = session.canonical_resource(str(root / "resource"))
            owner = {"runId": "parent", "pid": os.getpid(), "receipt": "receipt"}
            with session.Leases([resource], owner, root / "locks", inherited={}) as parent:
                for _ in range(200):
                    self.assertTrue(session.Leases.authenticated(resource, parent.held[resource]))

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
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Test"):
            first = session.cache_paths(pathlib.Path(directory) / "first", "Debug", "plain")
            other = session.cache_paths(pathlib.Path(directory) / "second", "Debug", "plain")
            sanitized = session.cache_paths(pathlib.Path(directory) / "first", "Debug", "thread-sanitizer")
            release = session.cache_paths(pathlib.Path(directory) / "first", "Release", "plain")
            self.assertEqual(len({p["derivedData"] for p in (first, other, sanitized, release)}), 4)
            with mock.patch.dict(os.environ, {"GITX_DERIVED_DATA": directory}):
                self.assertEqual(session.cache_paths()["derivedData"], str(pathlib.Path(directory).resolve()))

    def test_raw_test_execution_owns_desktop_but_compilation_does_not(self):
        with mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Test"):
            for action in ("test", "test-without-building"):
                resources, _ = session.entry_resources("xcodebuild.sh", ["raw", "--", action])
                self.assertIn(f"desktop:{os.getuid()}", resources)
            resources, _ = session.entry_resources("xcodebuild.sh", ["raw", "--", "build-for-testing"])
            self.assertNotIn(f"desktop:{os.getuid()}", resources)

    def test_cache_root_override_preserves_partitions_and_individual_overrides(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Test"):
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
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"GITX_VERIFICATION_CACHE_ROOT": "verification-cache"}, clear=True), mock.patch.object(session.subprocess, "check_output", return_value=b"Xcode 26.6\nBuild version Test"):
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

    def test_lock_state_belongs_to_the_current_console_session(self):
        import plistlib
        for key_style in [False, True]:
            user = "kCGSSessionUserIDKey" if key_style else "CGSSessionUserID"
            console = "kCGSSessionOnConsoleKey" if key_style else "CGSSessionOnConsole"
            for locked in [False, True]:
                properties = plistlib.dumps([{"IOConsoleUsers": [
                    {user: os.getuid() + 1, console: False, "CGSSessionScreenIsLocked": True},
                    {user: os.getuid(), console: True, "CGSSessionScreenIsLocked": locked}]}])
                outputs = [f"Name : fixture\nUID : {os.getuid()}\n", "display", properties, ""]
                responses = [subprocess.CompletedProcess([], 0, value, "") for value in outputs]
                with mock.patch.object(session.platform, "system", return_value="Darwin"), mock.patch.object(session.subprocess, "run", side_effect=responses):
                    display = next(check for check in session.desktop_checks() if check["name"] == "display")
                self.assertEqual(display["status"], "failed" if locked else "passed")
        self.assertTrue(session.console_session_locked(b"broken", os.getuid()))
        self.assertTrue(session.console_session_locked(plistlib.dumps([]), os.getuid()))

    def test_registry_console_lock_is_scoped_to_the_matched_console_user(self):
        import plistlib
        for locked in [False, True]:
            properties = plistlib.dumps([{"IOConsoleLocked": locked, "IOConsoleUsers": [
                {"kCGSSessionUserIDKey": os.getuid(), "kCGSSessionOnConsoleKey": True}]}])
            self.assertEqual(session.console_session_locked(properties, os.getuid()), locked)
        properties = plistlib.dumps([{"IOConsoleLocked": False, "IOConsoleUsers": [
            {"kCGSSessionUserIDKey": os.getuid() + 1, "kCGSSessionOnConsoleKey": True}]}])
        self.assertTrue(session.console_session_locked(properties, os.getuid()))

    def test_registry_lock_does_not_leak_between_session_subtrees(self):
        import plistlib
        properties = plistlib.dumps([
            {"IOConsoleLocked": True, "IOConsoleUsers": [
                {"kCGSSessionUserIDKey": os.getuid() + 1, "kCGSSessionOnConsoleKey": False}]},
            {"IOConsoleLocked": False, "IOConsoleUsers": [
                {"kCGSSessionUserIDKey": os.getuid(), "kCGSSessionOnConsoleKey": True}]}])
        self.assertFalse(session.console_session_locked(properties, os.getuid()))
        properties = plistlib.dumps([{"IOConsoleLocked": False, "IOConsoleUsers": [
            {"kCGSSessionUserIDKey": os.getuid(), "kCGSSessionOnConsoleKey": True,
             "kCGSSessionScreenIsLockedKey": True}]}])
        self.assertTrue(session.console_session_locked(properties, os.getuid()))

    def test_broker_accepts_fragmented_framed_requests(self):
        import socket
        with tempfile.TemporaryDirectory() as directory:
            resource = session.canonical_resource(str(pathlib.Path(directory) / "resource"))
            owner = {"runId": "owner", "pid": os.getpid(), "receipt": "receipt"}
            with session.Leases([resource], owner, pathlib.Path(directory) / "locks", inherited={}) as parent:
                prior = parent.held[resource]
                request = json.dumps({"resource": session.digest(resource.encode()), "token": prior["token"]}).encode() + b"\n"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(2)
                    client.connect(prior["socket"])
                    for offset in range(0, len(request), 3):
                        client.sendall(request[offset:offset + 3])
                    self.assertEqual(client.recv(128), b"owned\n")

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

    def test_native_progress_requires_a_fresh_regular_file_and_complete_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            native = root / 'Native'
            native.mkdir()
            (native / 'GitX-1.stderr.log').write_bytes(b'Test Suite old probe started')
            foreign = root / 'foreign'
            foreign.write_bytes(b'Test Suite foreign source started')
            progress = session.NativeTestProgress(native)
            try:
                (native / 'unrelated.log').write_bytes(b'Test Suite wrong filename started')
                (native / 'GitX-2.stderr.log').symlink_to(foreign)
                os.mkfifo(native / 'GitX-3.stderr.log')
                self.assertFalse(progress.observed())
                current = native / 'GitX-4.stderr.log'
                current.write_bytes(b'Test Sui')
                self.assertFalse(progress.observed())
                with current.open('ab') as stream:
                    stream.write(b'te current tests started')
                self.assertTrue(progress.observed())
            finally:
                progress.close()

    def test_native_startup_written_before_deadline_survives_a_late_selector_wakeup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            _, output, diagnostics = self.capture_fixture(root)
            native = output.parent / 'Native'
            native.mkdir()
            manifest = diagnostics / 'diagnostic-owner.json'
            reader, writer = os.pipe()
            clock = [0.0]
            emitted = []
            real_selector = session.selectors.DefaultSelector
            event_read = session.selectors.EVENT_READ

            class ControlledSelector:
                def __init__(self):
                    self.base = real_selector()
                    self.did_emit = False

                def register(self, *arguments):
                    return self.base.register(*arguments)

                def unregister(self, *arguments):
                    return self.base.unregister(*arguments)

                def get_map(self):
                    return self.base.get_map()

                def close(self):
                    self.base.close()

                def select(self, timeout):
                    if not self.did_emit:
                        self.did_emit = True
                        clock[0] = .9
                        (native / 'GitX-999.stderr.log').write_bytes(b'Test Suite selected tests started\n')
                        emitted.append(clock[0])
                        clock[0] = 1.1
                        return []
                    return self.base.select(timeout)

            def release_after_acknowledgment():
                deadline = time.monotonic() + 4
                wake = threading.Event()
                while time.monotonic() < deadline:
                    if manifest.exists():
                        state = json.loads(manifest.read_text())
                        if state.get('hostStartup', {}).get('source') == 'native-stderr':
                            os.write(writer, b'1')
                            return
                        if state.get('status') == 'failed':
                            return
                    wake.wait(.01)

            observer = threading.Thread(target=release_after_acknowledgment)
            observer.start()
            child = f'import os,select,sys; ready=select.select([{reader}],[],[],5)[0]; sys.exit(71) if not ready else os.read({reader},1)'
            environment = dict(os.environ, TEST_RUNNER_GITX_TEST_STDERR_DIRECTORY=str(native))
            controlled_time = SimpleNamespace(monotonic=lambda: clock[0], sleep=time.sleep, time=time.time)
            controlled_selectors = SimpleNamespace(DefaultSelector=ControlledSelector, EVENT_READ=event_read)
            try:
                with mock.patch.object(session, 'ROOT', root), \
                        mock.patch.object(session, 'time', controlled_time), \
                        mock.patch.object(session, 'selectors', controlled_selectors):
                    status = session.supervise([sys.executable, '-c', child], startup_timeout=1, timeout=10,
                                               directory=diagnostics, output_log=output, env=environment,
                                               pass_fds=(reader,))
            finally:
                observer.join(timeout=6)
                os.close(reader)
                os.close(writer)
            self.assertFalse(observer.is_alive())
            self.assertEqual(emitted, [.9])
            self.assertEqual(clock[0], 1.1)
            self.assertEqual(status, 0, 'A startup marker emitted before the deadline must survive selector scheduling')
            self.assertEqual(json.loads(manifest.read_text())['hostStartup']['source'], 'native-stderr')

    def native_startup_probe(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            native = output.parent / 'Native'
            native.mkdir()
            selected = root / 'ForeignNative' if mode == 'foreign' else native
            selected.mkdir(exist_ok=True)
            if mode == 'prior':
                (native / 'GitX-123.stderr.log').write_bytes(b'Test Suite previous host started\n')
            sentinel = root / 'sentinel'
            sentinel.write_bytes(b'Test Suite foreign source started\n')
            fifo = root / 'release'
            os.mkfifo(fifo)
            gate = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            command = r'''
import os, pathlib, sys
native, mode, fifo, sentinel = map(str, sys.argv[1:])
path = pathlib.Path(native) / ('GitX-123.stderr.log' if mode == 'prior' else f'GitX-{os.getpid()}.stderr.log')
if mode == 'symlink':
    path.symlink_to(sentinel)
else:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, b'Test Sui' if mode == 'split' else b'app launched without XCTest\n' if mode == 'quiet' else b'Test Suite selected tests started\n')
reader = os.open(fifo, os.O_RDONLY)
if mode == 'split':
    os.read(reader, 1)
    os.write(fd, b'te selected tests started\n')
os.read(reader, 1)
print('completed', flush=True)
'''
            environment = dict(os.environ, TEST_RUNNER_GITX_TEST_STDERR_DIRECTORY=str(selected))
            process = subprocess.Popen([sys.executable, str(entry), 'run', '--timeout', '10',
                                        '--startup-timeout', '2', '--diagnostics', str(diagnostics),
                                        '--output-log', str(output), '--', sys.executable, '-c', command,
                                        str(selected), mode, str(fifo), str(sentinel)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            manifest = diagnostics / 'diagnostic-owner.json'
            split_released = released = False
            deadline = time.monotonic() + 15
            try:
                while process.poll() is None and time.monotonic() < deadline:
                    if mode == 'split' and not split_released and any(
                            p.read_bytes() == b'Test Sui' for p in native.glob('*.log')):
                        os.write(gate, b'1')
                        split_released = True
                    if manifest.exists():
                        state = json.loads(manifest.read_text())
                        if state.get('hostStartup') and not released:
                            os.write(gate, b'2')
                            released = True
                    threading.Event().wait(.01)
                self.assertIsNotNone(process.poll(), 'The owned supervisor must finish within its backstop')
            finally:
                if process.poll() is None:
                    process.terminate()
                stdout, stderr = process.communicate(timeout=10)
                os.close(gate)
            state = json.loads(manifest.read_text())
            blocker = json.loads((diagnostics / 'blocker.json').read_text()) if (diagnostics / 'blocker.json').exists() else None
            return process.returncode, state, blocker, stdout, stderr

    def test_fresh_native_xctest_startup_is_observed_without_console_output(self):
        for mode in ('live', 'split'):
            with self.subTest(mode=mode):
                status, state, blocker, stdout, stderr = self.native_startup_probe(mode)
                self.assertEqual(status, 0, stderr)
                self.assertEqual(state['hostStartup']['source'], 'native-stderr')
                self.assertIsNone(blocker)
                self.assertIn(b'completed', stdout)

    def test_prior_native_host_and_foreign_logs_cannot_hide_missing_startup(self):
        for mode in ('prior', 'foreign', 'quiet', 'symlink'):
            with self.subTest(mode=mode):
                status, state, blocker, stdout, stderr = self.native_startup_probe(mode)
                self.assertEqual(status, 124, stderr)
                self.assertNotIn('hostStartup', state)
                self.assertEqual(blocker['category'], 'unknown-host-startup-timeout')
                self.assertNotIn(b'completed', stdout)

    def test_watchdog_preserves_failure_and_bounds_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            failed = session.supervise([sys.executable, "-c", "raise SystemExit(9)"], timeout=2, directory=directory)
            self.assertEqual(failed, 9)
            status = session.supervise([sys.executable, "-c", "import time;time.sleep(30)"], timeout=2, startup_timeout=.1, directory=directory)
            self.assertEqual(status, 124)
            self.assertEqual(json.loads((pathlib.Path(directory) / "blocker.json").read_text())["category"], "unknown-host-startup-timeout")
            status = session.supervise([sys.executable, "-c", "print('Test Suite started',flush=True)"], timeout=2, startup_timeout=1, directory=directory)
            self.assertEqual(status, 0)
