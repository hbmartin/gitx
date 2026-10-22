from __future__ import annotations

import json
import errno
import fcntl
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
import workflow_cleanup as cleanup
import dev_workflow as workflow


class WorkflowSessionTests(unittest.TestCase):
    def test_native_failure_preserves_a_natural_positive_exit_during_diagnostics(self):
        for category in ('native-progress-unavailable', 'native-startup-publication-failed'):
            for natural_exit in (65, 0, None):
                with self.subTest(category=category, exit=natural_exit), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    _, output, diagnostics = self.capture_fixture(root)
                    ready_reader, ready_writer = os.pipe()
                    release_reader, release_writer = os.pipe()
                    child = None
                    spawn, poll = session.subprocess.Popen, session.NativeTestDiagnostics.poll
                    ready = False
                    def remember(*arguments, **keywords):
                        nonlocal child
                        process = spawn(*arguments, **keywords)
                        if keywords.get('start_new_session'):
                            child = process
                        return process
                    def check_progress(native):
                        nonlocal ready
                        if not ready:
                            self.assertTrue(select.select([ready_reader], [], [], 5)[0])
                            self.assertEqual(os.read(ready_reader, 1), b'R')
                            ready = True
                            if category == 'native-progress-unavailable':
                                raise session.NativeProgressSetupError('read-progress', OSError(errno.EIO, 'fixture'))
                        return poll(native)
                    def finish_during_diagnostics(*_):
                        os.write(release_writer, b'X')
                        child.wait(timeout=5)
                    command = '''
import os, signal, sys
signal.signal(signal.SIGTERM, lambda *_: os._exit(7))
os.write(int(sys.argv[1]), b'R')
if sys.argv[4] == 'native-startup-publication-failed':
    print('GitXNativeStartupFailure invocation=' + os.environ['GITX_TEST_INVOCATION_ID'] +
          ' operation=publish-record category=system errno=28', flush=True)
os.read(int(sys.argv[2]), 1)
if sys.argv[3] == 'signal':
    os.kill(os.getpid(), signal.SIGUSR1)
os._exit(int(sys.argv[3]))
'''
                    try:
                        with mock.patch.object(session, 'ROOT', root), \
                                mock.patch.object(session.subprocess, 'Popen', side_effect=remember), \
                                mock.patch.object(session.NativeTestDiagnostics, 'poll', check_progress), \
                                mock.patch.object(session, 'diagnostics', side_effect=finish_during_diagnostics):
                            status = session.supervise(
                                [sys.executable, '-c', command, str(ready_writer), str(release_reader),
                                 str(natural_exit) if natural_exit is not None else 'signal', category],
                                directory=diagnostics, output_log=output, native_test_root=root / 'cache',
                                pass_fds=(ready_writer, release_reader))
                        metadata = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                        actual_exit = natural_exit if natural_exit is not None else -signal.SIGUSR1
                        self.assertEqual(status, natural_exit if natural_exit else 2)
                        self.assertEqual(metadata['category'], category)
                        self.assertIsNone(metadata['childExitCodeAtFailure'])
                        self.assertEqual(metadata['childExitCodeBeforeStop'], actual_exit)
                        self.assertEqual(metadata['childExitCode'], actual_exit)
                    finally:
                        if child is not None and child.poll() is None:
                            child.kill()
                            child.wait(timeout=5)
                        for descriptor in (ready_reader, ready_writer, release_reader, release_writer):
                            os.close(descriptor)

    def test_durable_cross_directory_rename_syncs_both_parents_and_preserves_sync_errno(self):
        for fail_destination in (False, True):
            with self.subTest(failure=fail_destination), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                left, right = root / 'left', root / 'right'
                left.mkdir()
                right.mkdir()
                source, destination = left / 'record', right / 'record'
                source.write_bytes(b'published')
                observed = []
                def sync(descriptor):
                    identity = os.fstat(descriptor).st_ino
                    observed.append(identity)
                    if fail_destination and identity == right.stat().st_ino:
                        raise OSError(errno.EIO, 'fixture-destination-sync')
                with mock.patch.object(session.os, 'fsync', side_effect=sync):
                    if fail_destination:
                        with self.assertRaises(OSError) as raised:
                            session.exclusive_native_rename(source, destination, sync_parent=True)
                        self.assertEqual(raised.exception.errno, errno.EIO)
                    else:
                        session.exclusive_native_rename(source, destination, sync_parent=True)
                self.assertEqual(observed, [left.stat().st_ino, right.stat().st_ino])
                self.assertFalse(source.exists())
                self.assertEqual(destination.read_bytes(), b'published')

    def test_exclusive_rename_without_durability_supports_distinct_parent_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            left, right = root / 'left', root / 'right'
            left.mkdir()
            right.mkdir()
            source, destination = left / 'source', right / 'destination'
            source.write_bytes(b'complete-record')
            with mock.patch.object(session.os, 'fsync') as sync:
                session.exclusive_native_rename(source, destination)
            sync.assert_not_called()
            self.assertFalse(source.exists())
            self.assertEqual(destination.read_bytes(), b'complete-record')

    def test_native_failure_status_uses_the_child_state_before_termination(self):
        outcomes = [('running-positive', 7, False), ('running-zero', 0, False),
                    ('running-signal', None, False), ('already-failed', 9, True)]
        for category in ('native-progress-unavailable', 'native-startup-publication-failed', 'interrupted'):
            for label, exit_code, already_exited in outcomes:
                if category == 'interrupted' and already_exited:
                    continue
                with self.subTest(category=category, outcome=label), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    _, output, diagnostics = self.capture_fixture(root)
                    reader, writer = os.pipe()
                    child = None
                    spawn, poll = session.subprocess.Popen, session.NativeTestDiagnostics.poll
                    observed_ready = False

                    def remember(*arguments, **keywords):
                        nonlocal child
                        process = spawn(*arguments, **keywords)
                        if keywords.get('start_new_session'):
                            child = process
                        return process

                    def ready_then_poll(native):
                        nonlocal observed_ready
                        if not observed_ready:
                            self.assertTrue(select.select([reader], [], [], 5)[0], 'child installed its termination policy')
                            self.assertEqual(os.read(reader, 1), b'R')
                            observed_ready = True
                            if already_exited:
                                child.wait(timeout=5)
                            if category == 'native-progress-unavailable':
                                raise session.NativeProgressSetupError('read-progress', OSError(errno.EIO, 'fixture'))
                            if category == 'interrupted':
                                os.kill(os.getpid(), signal.SIGTERM)
                        return poll(native)

                    command = '''
import os, signal, sys
code = sys.argv[2]
if code != 'signal':
    signal.signal(signal.SIGTERM, lambda *_: os._exit(int(code)))
os.write(int(sys.argv[1]), b'R')
if sys.argv[3] == 'native-startup-publication-failed':
    print('GitXNativeStartupFailure invocation=' + os.environ['GITX_TEST_INVOCATION_ID'] +
          ' operation=publish-record category=system errno=28', flush=True)
if sys.argv[4] == 'exited':
    sys.exit(int(code))
while True:
    signal.pause()
'''
                    try:
                        with mock.patch.object(session, 'ROOT', root), \
                                mock.patch.object(session.subprocess, 'Popen', side_effect=remember), \
                                mock.patch.object(session.NativeTestDiagnostics, 'poll', ready_then_poll), \
                                mock.patch.object(session, 'diagnostics'):
                            status = session.supervise(
                                [sys.executable, '-c', command, str(writer), str(exit_code) if exit_code is not None else 'signal',
                                 category, 'exited' if already_exited else 'running'],
                                directory=diagnostics, output_log=output, native_test_root=root / 'cache', pass_fds=(writer,))
                        state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                        self.assertEqual(status, 130 if category == 'interrupted' else 9 if already_exited else 2)
                        self.assertEqual(state['category'], category)
                        self.assertEqual(state['childExitCodeBeforeStop'], 9 if already_exited else None)
                        self.assertEqual(state['childExitCode'], -signal.SIGTERM if exit_code is None else exit_code)
                        self.assertNotIn('hostStartup', state)
                    finally:
                        if child is not None and child.poll() is None:
                            child.kill()
                            child.wait(timeout=5)
                        os.close(reader)
                        os.close(writer)

    def test_exclusive_rename_callers_preserve_collisions_and_parent_sync_policy(self):
        for caller in ('native', 'native-durable', 'cleanup'):
            with self.subTest(caller=caller), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                source, destination = root / 'source', root / 'destination'
                source.write_bytes(b'new')
                destination.write_bytes(b'keep-existing')
                rename = cleanup.rename_exclusive if caller == 'cleanup' else session.exclusive_native_rename
                options = {'sync_parent': True} if caller == 'native-durable' else {}
                with mock.patch.object(session.os, 'fsync', wraps=os.fsync) as sync:
                    with self.assertRaises(FileExistsError) as raised:
                        rename(source, destination, **options)
                    self.assertEqual(raised.exception.filename, str(destination))
                    sync.assert_not_called()
                    self.assertEqual(source.read_bytes(), b'new')
                    self.assertEqual(destination.read_bytes(), b'keep-existing')
                    destination.unlink()
                    rename(source, destination, **options)
                    self.assertEqual(sync.call_count, 0 if caller == 'native' else 1)
                self.assertFalse(source.exists())
                self.assertEqual(destination.read_bytes(), b'new')

    def test_exclusive_rename_preserves_syscall_errno_and_closes_parent_on_sync_failure(self):
        for use_cleanup in (False, True):
            with self.subTest(cleanup=use_cleanup), tempfile.TemporaryDirectory() as directory:
                source, destination = pathlib.Path(directory) / 'source', pathlib.Path(directory) / 'destination'
                source.write_bytes(b'keep')
                rename = cleanup.rename_exclusive if use_cleanup else session.exclusive_native_rename
                syscall = mock.Mock(return_value=-1)
                library = SimpleNamespace(renamex_np=syscall)
                with mock.patch.object(session.sys, 'platform', 'darwin'), \
                        mock.patch.object(session.ctypes, 'CDLL', return_value=library), \
                        mock.patch.object(session.ctypes, 'get_errno', return_value=errno.ENOTSUP):
                    with self.assertRaises(OSError) as raised:
                        rename(source, destination)
                self.assertEqual(raised.exception.errno, errno.ENOTSUP)
                self.assertEqual(raised.exception.filename, str(destination))
                self.assertEqual(source.read_bytes(), b'keep')
                inspected = []
                def fail_sync(descriptor):
                    inspected.append(descriptor)
                    self.assertTrue(pathlib.Path(directory).stat().st_ino == os.fstat(descriptor).st_ino)
                    raise OSError(errno.EIO, 'fixture-sync')
                with mock.patch.object(session.os, 'fsync', side_effect=fail_sync):
                    with self.assertRaises(OSError) as raised:
                        if use_cleanup:
                            rename(source, destination)
                        else:
                            rename(source, destination, sync_parent=True)
                self.assertEqual(raised.exception.errno, errno.EIO)
                self.assertEqual(len(inspected), 1)
                with self.assertRaises(OSError) as closed:
                    os.fstat(inspected[0])
                self.assertEqual(closed.exception.errno, errno.EBADF)
                self.assertEqual(destination.read_bytes(), b'keep')
                self.assertFalse(source.exists())

    def test_exclusive_rename_unavailable_platform_retains_each_callers_error_contract(self):
        with mock.patch.object(session.sys, 'platform', 'fixture-unsupported'), \
                mock.patch.object(session.ctypes, 'CDLL', return_value=SimpleNamespace()):
            with self.assertRaises(session.ExclusiveRenameUnavailable) as raised:
                session.exclusive_native_rename('source', 'destination')
            self.assertEqual(raised.exception.errno, errno.ENOTSUP)
            with self.assertRaisesRegex(ValueError, 'exclusive quarantine rename') as raised:
                cleanup.rename_exclusive('source', 'destination')
            self.assertIsInstance(raised.exception.__cause__, session.ExclusiveRenameUnavailable)

    @staticmethod
    def startup_child():
        return """
import json, os, pathlib
record = {'schemaVersion': 1, 'event': 'bundle-start', 'pid': os.getpid(), 'bundleID': 'net.phere.GitXTests',
          'invocationID': os.environ['GITX_TEST_INVOCATION_ID'], 'verificationSession': os.environ['GITX_VERIFICATION_SESSION']}
progress = pathlib.Path(os.environ['GITX_TEST_PROGRESS_DIRECTORY'])
(progress / f'startup-{os.getpid()}-a.json').write_text(json.dumps(record))
"""

    def test_managed_success_requires_startup_even_before_deadline_but_preserves_real_failure(self):
        for child_status in (0, 9):
            with self.subTest(child_status=child_status), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, diagnostics = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    status = session.supervise([sys.executable, '-c', f'raise SystemExit({child_status})'],
                                               directory=diagnostics, native_test_root=root / 'cache',
                                               native_artifact_directory=output.parent / 'Native', startup_timeout=120)
                self.assertEqual(status, 2 if child_status == 0 else child_status)
                state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                self.assertEqual(state['childExitCode'], child_status)
                self.assertEqual(state['status'], 'failed')
                if child_status == 0:
                    self.assertEqual(state['category'], 'native-startup-unconfirmed')

    def test_progress_setup_failure_launches_no_child_and_starts_no_reporting_thread(self):
        for operation in ('probe-publication', 'open-progress'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, diagnostics = self.capture_fixture(root)
                target = 'exclusive_native_rename' if operation == 'probe-publication' else 'NativeTestProgress'
                with mock.patch.object(session, 'ROOT', root), mock.patch.object(session, target, side_effect=OSError(28, 'fixture-full')), \
                        mock.patch.object(session.pathlib.Path, 'home', return_value=root), \
                        mock.patch.object(session, 'producer_identity', return_value={'pid': 42}), \
                        mock.patch.object(session.subprocess, 'Popen') as launch, \
                        mock.patch.object(session.threading, 'Thread') as worker:
                    status = session.supervise(['must-not-launch'], directory=diagnostics,
                                               native_test_root=root / 'cache', native_artifact_directory=output.parent / 'Native')
                self.assertEqual(status, 2)
                launch.assert_not_called()
                worker.assert_not_called()
                state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                self.assertEqual(state['category'], 'native-progress-setup-failed')
                self.assertEqual(state['infrastructureError'], {'operation': operation, 'errno': 28})

    def test_progress_stops_rescanning_after_accepted_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            record = self.startup_record()
            (root / 'startup-42-a.json').write_text(json.dumps(record))
            progress = session.NativeTestProgress(root, 'invocation-1', 'session-1', ['net.phere.GitXTests'])
            self.addCleanup(progress.close)
            self.assertTrue(progress.observed())
            with mock.patch.object(session.os, 'listdir', side_effect=AssertionError('Startup was already accepted')):
                self.assertTrue(progress.observed())

    def test_matching_publication_failure_is_an_infrastructure_error_and_never_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, diagnostics = self.capture_fixture(root)
            reader, writer = os.pipe()
            self.addCleanup(os.close, reader)
            self.addCleanup(os.close, writer)
            command = """
import os, sys
print('GitXNativeStartupFailure invocation=' + os.environ['GITX_TEST_INVOCATION_ID'] +
      ' operation=publish-record category=system errno=28', flush=True)
os.read(int(sys.argv[1]), 1)
"""
            with mock.patch.object(session, 'ROOT', root):
                status = session.supervise([sys.executable, '-c', command, str(reader)], directory=diagnostics,
                                           output_log=output, native_test_root=root / 'cache', startup_timeout=120,
                                           pass_fds=(reader,))
            state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            self.assertEqual(status, 2)
            self.assertEqual(state['category'], 'native-startup-publication-failed')
            self.assertEqual(state['infrastructureError']['errno'], 28)
            self.assertNotIn('hostStartup', state)

    def test_native_record_requires_filename_pid_and_owned_invocation_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            self.addCleanup(os.close, descriptor)
            record = {'schemaVersion': 1, 'event': 'bundle-start', 'pid': 42,
                      'bundleID': 'bundle', 'invocationID': 'invocation', 'verificationSession': 'session'}
            source = root / 'startup-42-a.json'
            source.write_text(json.dumps(record))
            self.assertEqual(session.read_native_record(descriptor, source.name, 'invocation', 'session'), record)
            for name, invocation, verification in [('startup-43-a.json', 'invocation', 'session'),
                                                    (source.name, 'other', 'session'),
                                                    (source.name, 'invocation', 'other')]:
                with self.subTest(name=name, invocation=invocation, verification=verification):
                    if name != source.name:
                        (root / name).write_bytes(source.read_bytes())
                    self.assertIsNone(session.read_native_record(descriptor, name, invocation, verification))
            self.assertEqual(json.loads(source.read_text()), record)

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

    def test_canonical_capture_close_and_metadata_failures_keep_child_status_in_metadata(self):
        for failure in ('close', 'metadata'):
            for child_status in (0, 7):
                with self.subTest(failure=failure, child_status=child_status), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    _, output, diagnostics = self.capture_fixture(root)
                    close, publish = session.CapturedConsole.close, session.atomic_json
                    def failed_close(capture):
                        metrics = close(capture)
                        if failure == 'close':
                            metrics['closeError'] = 'OSError'
                        return metrics
                    def failed_metadata(path, value):
                        if failure == 'metadata' and pathlib.Path(path).name.endswith('.capture.json'):
                            raise OSError(errno.ENOSPC, 'fixture-metadata-full')
                        return publish(path, value)
                    with mock.patch.object(session, 'ROOT', root), \
                            mock.patch.object(session.CapturedConsole, 'close', failed_close), \
                            mock.patch.object(session, 'atomic_json', side_effect=failed_metadata):
                        status = session.supervise([sys.executable, '-c', f'raise SystemExit({child_status})'],
                            directory=diagnostics, output_log=output)
                    state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                    self.assertEqual(status, 74)
                    self.assertEqual(state['childExitCode'], child_status)
                    self.assertEqual(state['category'], 'output-capture-failed')
                    self.assertFalse(state['outputCapture']['captureComplete'])

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

    def test_generic_console_startup_recognizes_xctest_spellings_and_requires_complete_marker(self):
        for marker in (b"Test Suite selected started", b"Test Case '-[Suite test]' started", b"Test case 'test' started"):
            with self.subTest(marker=marker):
                self.assertTrue(session.test_output_started(marker))
        self.assertFalse(session.test_output_started(b"Test Sui"))
        self.assertFalse(session.test_output_started(b"application launched without tests"))

    @staticmethod
    def startup_record(invocation='invocation-1', verification_session='session-1', **changes):
        return {'schemaVersion': 1, 'event': 'bundle-start', 'invocationID': invocation,
                'verificationSession': verification_session, 'bundleID': 'net.phere.GitXTests',
                'pid': 42} | changes

    def test_authenticated_startup_remains_observed_after_record_retirement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            record = root / 'startup-42-a.json'
            record.write_text(json.dumps(self.startup_record()))
            progress = session.NativeTestProgress(root, 'invocation-1', 'session-1', ['net.phere.GitXTests'])
            try:
                self.assertTrue(progress.observed())
                record.unlink()
                with mock.patch.object(session, 'read_native_record', side_effect=AssertionError('accepted startup was reread')):
                    self.assertTrue(progress.observed(), 'Startup is an authenticated historical event')
            finally:
                progress.close()

    def test_native_progress_requires_matching_complete_owned_xctest_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            progress = session.NativeTestProgress(root, 'invocation-1', 'session-1', ['net.phere.GitXTests'])
            try:
                foreign = root / 'foreign'
                foreign.write_text(json.dumps(self.startup_record()))
                (root / 'startup-42-a.json').symlink_to(foreign)
                os.mkfifo(root / 'startup-42-b.json')
                (root / 'GitX-42-c.stderr.log').write_text("Test Suite selected started\n")
                for index, changes in enumerate(({'invocationID': 'old'}, {'verificationSession': 'foreign'},
                                                 {'bundleID': 'net.phere.GitXUITests'}, {'event': 'capture'},
                                                 {'schemaVersion': True}, {'pid': '42'})):
                    (root / f'startup-42-{index}.json').write_text(json.dumps(self.startup_record(**changes)))
                (root / 'capture-42-c.json').write_text(json.dumps(self.startup_record(event='capture', state='captured')))
                self.assertFalse(progress.observed(), 'A valid capture record is not a bundle-start event')
                current = root / 'startup-42-c.json'
                data = json.dumps(self.startup_record()).encode()
                current.write_bytes(data[:20])
                self.assertFalse(progress.observed())
                with current.open('ab') as stream:
                    stream.write(data[20:])
                self.assertTrue(progress.observed())
                foreign_progress = session.NativeTestProgress(root, 'invocation-1', 'session-1', ['net.phere.GitXTests'])
                try:
                    with mock.patch.object(session.os, 'getuid', return_value=os.getuid() + 1):
                        self.assertFalse(foreign_progress.observed(), 'Foreign-owned records never establish startup')
                finally:
                    foreign_progress.close()
            finally:
                progress.close()

    def test_native_startup_written_before_deadline_survives_a_late_selector_wakeup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            _, output, diagnostics = self.capture_fixture(root)
            native = root / 'cache/Native'
            manifest = diagnostics / 'diagnostic-owner.json'
            reader, writer = os.pipe()
            clock, emitted = [0.0], []
            real_selector = session.selectors.DefaultSelector
            event_read = session.selectors.EVENT_READ
            test = self

            class ControlledSelector:
                def __init__(self):
                    self.base = real_selector()
                    self.did_emit = False
                def register(self, *args):
                    return self.base.register(*args)
                def unregister(self, *args):
                    return self.base.unregister(*args)
                def get_map(self):
                    return self.base.get_map()
                def close(self):
                    self.base.close()
                def select(self, timeout):
                    if not self.did_emit:
                        self.did_emit = True
                        state = json.loads(manifest.read_text())
                        native_state = state['nativeDiagnostics']
                        clock[0] = .9
                        record = test.startup_record(native_state['invocationID'], state['runId'])
                        (pathlib.Path(native_state['progressDirectory']) / 'startup-42-a.json').write_text(json.dumps(record))
                        emitted.append(clock[0])
                        clock[0] = 1.1
                        return []
                    return self.base.select(timeout)

            def release_after_acknowledgment():
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    if manifest.exists():
                        state = json.loads(manifest.read_text())
                        if state.get('hostStartup', {}).get('source') == 'xctest-observer':
                            os.write(writer, b'1')
                            return
                        if state.get('status') == 'failed':
                            return
                    threading.Event().wait(.01)

            observer = threading.Thread(target=release_after_acknowledgment)
            observer.start()
            child = f'import os,select,sys; ready=select.select([{reader}],[],[],5)[0]; sys.exit(71) if not ready else os.read({reader},1)'
            controlled_time = SimpleNamespace(monotonic=lambda: clock[0], sleep=time.sleep, time=time.time)
            try:
                with mock.patch.object(session, 'ROOT', root), mock.patch.object(session, 'time', controlled_time), \
                        mock.patch.object(session, 'selectors', SimpleNamespace(DefaultSelector=ControlledSelector, EVENT_READ=event_read)):
                    status = session.supervise([sys.executable, '-c', child], startup_timeout=1, timeout=10,
                                               directory=diagnostics, native_test_root=native,
                                               native_artifact_directory=output.parent / 'Native', pass_fds=(reader,))
            finally:
                observer.join(timeout=6)
                os.close(reader)
                os.close(writer)
            self.assertFalse(observer.is_alive())
            self.assertEqual(emitted, [.9])
            self.assertEqual(clock[0], 1.1)
            self.assertEqual(status, 0)
            state = json.loads(manifest.read_text())
            self.assertEqual(state['hostStartup']['source'], 'xctest-observer')
            self.assertIn('outputCapture', state, 'Managed startup and reporting share one canonical capture')

    def native_startup_probe(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            fifo = root / 'release'
            os.mkfifo(fifo)
            gate = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            command = r'''
import json, os, pathlib, sys
mode, fifo = sys.argv[1:]
progress = pathlib.Path(os.environ['GITX_TEST_PROGRESS_DIRECTORY'])
record = {'schemaVersion': 1, 'event': 'bundle-start', 'pid': os.getpid(),
          'bundleID': 'net.phere.GitXTests', 'invocationID': os.environ['GITX_TEST_INVOCATION_ID'],
          'verificationSession': os.environ['GITX_VERIFICATION_SESSION']}
path = progress / f'startup-{os.getpid()}-a.json'
if mode == 'prior': record['invocationID'] = 'old-invocation'
if mode == 'foreign': record['verificationSession'] = 'foreign-session'
if mode == 'wrong-bundle': record['bundleID'] = 'net.phere.GitXUITests'
if mode == 'capture':
    record['event'] = 'capture'
    record['state'] = 'captured'
    path = progress / f'capture-{os.getpid()}-a.json'
if mode == 'symlink':
    source = progress / 'foreign'
    source.write_text(json.dumps(record))
    path.symlink_to(source)
elif mode == 'quiet':
    native = pathlib.Path(os.environ['GITX_TEST_STDERR_DIRECTORY'])
    (native / f'GitX-{os.getpid()}-a.stderr.log').write_bytes(b'Test Suite fake started\n')
    print('Test Suite fake console started', flush=True)
else:
    encoded = json.dumps(record)
    path.write_text(encoded[:20] if mode == 'split' else encoded)
reader = os.open(fifo, os.O_RDONLY)
if mode == 'split':
    os.read(reader, 1)
    with path.open('a') as stream: stream.write(encoded[20:])
os.read(reader, 1)
print('completed', flush=True)
'''
            process = subprocess.Popen([sys.executable, str(entry), 'run', '--timeout', '10',
                                        '--startup-timeout', '2', '--diagnostics', str(diagnostics),
                                        '--native-test-root', str(root / 'cache/Native'),
                                        '--native-artifact-directory', str(output.parent / 'Native'),
                                        '--native-test-bundle', 'net.phere.GitXTests', '--capture-native-stderr',
                                        '--', sys.executable, '-c', command, mode, str(fifo)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            manifest = diagnostics / 'diagnostic-owner.json'
            split_released = released = False
            deadline = time.monotonic() + 15
            try:
                while process.poll() is None and time.monotonic() < deadline:
                    if manifest.exists():
                        state = json.loads(manifest.read_text())
                        if mode == 'split' and not split_released and state.get('nativeDiagnostics'):
                            progress = pathlib.Path(state['nativeDiagnostics']['progressDirectory'])
                            if list(progress.glob('startup-*.json')):
                                os.write(gate, b'1')
                                split_released = True
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
                self.assertEqual(state['hostStartup']['source'], 'xctest-observer')
                self.assertIsNone(blocker)
                self.assertIn(b'completed', stdout)

    def test_prior_native_host_and_foreign_logs_cannot_hide_missing_startup(self):
        for mode in ('prior', 'foreign', 'wrong-bundle', 'capture', 'quiet', 'symlink'):
            with self.subTest(mode=mode):
                status, state, blocker, stdout, stderr = self.native_startup_probe(mode)
                self.assertEqual(status, 124, stderr)
                self.assertNotIn('hostStartup', state)
                self.assertEqual(blocker['category'], 'unknown-host-startup-timeout')
                self.assertNotIn(b'completed', stdout)

    def test_fallback_capture_record_reports_publication_error_without_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                record = self.startup_record(native.invocation, 'session', event='capture', state='captured',
                    publicationError={'operation': 'publish-record', 'category': 'system', 'errno': errno.ENOSPC})
                filename = 'capture-42-a.json'
                (native.stderr_directory / filename).write_text(json.dumps(record))
                emitted = []
                native.output = emitted.append
                self.assertFalse(native.poll(), 'Capture fallback is never startup evidence')
                result = native.close()
                self.assertEqual(result['captures'], [record])
                self.assertIn('capture-publication', result['warnings'])
                self.assertTrue((native.archive / filename).is_file())
                self.assertNotIn(json.dumps(record).encode(), b''.join(emitted))

    def test_foreign_and_malformed_fallback_records_cannot_establish_capture(self):
        for changes in ({'invocationID': 'foreign'}, {'verificationSession': 'foreign'},
                        {'publicationError': {'operation': '/private/path', 'category': 'system', 'errno': 5}},
                        {'event': 'bundle-start'}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    record = self.startup_record(native.invocation, 'session', event='capture', state='captured') | changes
                    (native.stderr_directory / 'capture-42-a.json').write_text(json.dumps(record))
                    self.assertFalse(native.poll())
                    result = native.close()
                    self.assertEqual(result['captures'], [])
                    self.assertIn('capture-unconfirmed', result['warnings'])

    def test_optional_native_capture_failures_and_collection_do_not_replace_child_status(self):
        for exit_code in (0, 9):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, diagnostics = self.capture_fixture(root)
                command = r'''
import json, os, pathlib, sys
record = {'schemaVersion': 1, 'event': 'capture', 'pid': os.getpid(), 'state': 'unavailable', 'category': 'open',
          'invocationID': os.environ['GITX_TEST_INVOCATION_ID'], 'verificationSession': os.environ['GITX_VERIFICATION_SESSION']}
progress = pathlib.Path(os.environ['GITX_TEST_PROGRESS_DIRECTORY'])
(progress / f'capture-{os.getpid()}-a.json').write_text(json.dumps(record))
record.update(event='bundle-start', bundleID='net.phere.GitXTests')
(progress / f'startup-{os.getpid()}-b.json').write_text(json.dumps(record))
print('original stderr retained', file=sys.stderr)
sys.exit(int(sys.argv[1]))
'''
                with mock.patch.object(session, 'ROOT', root):
                    status = session.supervise([sys.executable, '-c', command, str(exit_code)], directory=diagnostics,
                                               output_log=output, native_test_root=root / 'cache/Native',
                                               native_artifact_directory=output.parent / 'Native', capture_native_stderr=True)
                self.assertEqual(status, exit_code)
                state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                self.assertIn('capture-unavailable', state['nativeDiagnostics']['warnings'])
                self.assertIn('original stderr retained', output.read_text())

    def test_native_checkpoint_precedes_close_and_inherited_writer_lease_defers_retirement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'custom-cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                writer = os.open(source, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                fcntl.flock(writer, fcntl.LOCK_SH)
                reader, release = os.pipe()
                child = subprocess.Popen([sys.executable, '-c', f'import os; os.read({reader},1)'], pass_fds=(reader, writer))
                os.close(reader)
                try:
                    os.write(writer, b'checkpoint-before-supervisor-exit\x00\xff')
                    native.poll()
                    archived = native.archive / source.name
                    self.assertEqual(archived.read_bytes(), source.read_bytes())
                    os.write(writer, b'\nlast-bytes')
                    os.close(writer)
                    writer = None
                    result = native.close()
                    self.assertEqual(result['retirementState'], 'deferred')
                    self.assertEqual(result['retirementReason'], 'producer-lease-held')
                    self.assertTrue(native.root.exists())
                    self.assertEqual(archived.read_bytes(), source.read_bytes())
                    os.write(release, b'1')
                    child.wait(timeout=5)

                    owner = json.loads(native.registration.read_text())
                    state, reason = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                    self.assertEqual((state, reason), ('retired', None))
                    self.assertFalse(native.root.exists())
                    self.assertTrue(archived.read_bytes().endswith(b'last-bytes'))
                finally:
                    if writer is not None:
                        os.close(writer)
                    os.close(release)
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)

    def test_native_poll_rotates_launches_and_bounds_each_source_chunk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                for pid in range(1, 21):
                    (native.stderr_directory / f'GitX-{pid}-a.stderr.log').write_bytes(b'x' * 131072)
                native.poll()
                self.assertEqual(sum(state['mirrored'] for state in native.sources.values()), 16 * 65536)
                self.assertTrue(all(state['mirrored'] <= 65536 for state in native.sources.values()))
                native.poll()
                self.assertTrue(all(state['mirrored'] > 0 for state in native.sources.values()))
                native.close()

    def test_command_and_native_bytes_have_one_console_writer_and_complete_raw_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, diagnostics = self.capture_fixture(root)
            command = self.startup_child() + """
import sys
native = pathlib.Path(os.environ['GITX_TEST_STDERR_DIRECTORY'])
(native / f'GitX-{os.getpid()}-b.stderr.log').write_bytes(b'native-sentinel\\x00\\xff' * 8192)
sys.stdout.buffer.write(b'command-sentinel' * 8192)
"""
            writers = set()
            write = session.os.write
            def observe_write(descriptor, data):
                if descriptor == sys.stdout.fileno():
                    writers.add(threading.current_thread().name)
                    return len(data)
                return write(descriptor, data)
            with mock.patch.object(session, 'ROOT', root), mock.patch.object(session.os, 'write', side_effect=observe_write):
                status = session.supervise([sys.executable, '-c', command], output_log=output, directory=diagnostics,
                                           native_test_root=root / 'cache', native_artifact_directory=output.parent / 'Native',
                                           capture_native_stderr=True)
            self.assertEqual(status, 0)
            self.assertEqual(writers, {'verification-console'})
            data = output.read_bytes()
            self.assertEqual(data.count(b'command-sentinel'), 8192)
            self.assertEqual(data.count(b'native-sentinel\x00\xff'), 8192)

    def test_native_retirement_refuses_replaced_sources_archives_and_unknown_content(self):
        for replacement in ('source', 'archive', 'unexpected'):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(b'original-evidence')
                    lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                    fcntl.flock(lease, fcntl.LOCK_SH)
                    result = native.close()
                    os.close(lease)
                    self.assertTrue(result['collectionComplete'])
                    if replacement == 'unexpected':
                        (native.root / 'unrelated-user-file').write_bytes(b'preserve')
                    else:
                        target = source if replacement == 'source' else native.archive / source.name
                        target.unlink()
                        target.write_bytes(b'replacement-data')
                    owner = json.loads(native.registration.read_text())
                    state, _ = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                    self.assertEqual(state, 'deferred')
                    self.assertTrue(native.root.exists())

    def test_partial_native_removal_preserves_durable_intent_and_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'keep-archive-\x00\xff')
                def partial_removal(path):
                    (path / 'invocation.lease').unlink()
                    raise OSError(errno.EIO, 'fixture-after-first-unlink')
                with mock.patch.object(session.shutil, 'rmtree', side_effect=partial_removal):
                    native.close()
                durable = json.loads(native.registration.read_text())
                self.assertEqual(durable['retirementPhase'], 'deleting')
                self.assertTrue(pathlib.Path(durable['retirementPath']).exists())
                self.assertEqual((native.archive / source.name).read_bytes(), b'keep-archive-\x00\xff')

    def test_native_final_checkpoint_matches_source_and_registration_while_writer_holds_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                (native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'complete-manifest')
                lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                try:
                    fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    result = native.close()
                    source = json.loads((native.root / 'native-owner.json').read_text())
                    registered = json.loads(native.registration.read_text())
                    self.assertTrue(result['collectionComplete'])
                    for value in (source, registered):
                        self.assertTrue(value['collectionComplete'])
                        self.assertEqual(value['status'], 'passed')
                        self.assertEqual(value['files'], result['files'])
                    self.assertEqual(result['retirementReason'], 'producer-lease-held')
                finally:
                    os.close(lease)

    def test_native_retirement_resumes_registered_quarantine_after_interrupted_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                (native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'retained')
                with mock.patch.object(session.shutil, 'rmtree', side_effect=OSError('interrupted-removal')):
                    native.close()
                owner = json.loads(native.registration.read_text())
                self.assertTrue(pathlib.Path(owner['retirementPath']).exists())
                state, _ = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                self.assertEqual(state, 'retired')
                self.assertFalse(pathlib.Path(owner['retirementPath']).exists())

    def test_native_retirement_rechecks_source_after_registered_rename_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'archived-original')
                lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                fcntl.flock(lease, fcntl.LOCK_SH)
                native.close()
                os.close(lease)
                owner = json.loads(native.registration.read_text())
                def replace_after_validation(value):
                    session.atomic_json(native.registration, value)
                    source.unlink()
                    source.write_bytes(b'preserve-new-source')
                state, reason = session.retire_native_sources(owner, persist=replace_after_validation)
                self.assertEqual((state, reason), ('deferred', 'source-changed-during-retirement'))
                retained = pathlib.Path(owner['retirementPath']) / 'Stderr' / source.name
                self.assertEqual(retained.read_bytes(), b'preserve-new-source')
                self.assertEqual((native.archive / source.name).read_bytes(), b'archived-original')

    def test_native_raw_binary_files_are_archived_even_if_console_or_collection_is_incomplete(self):
        for degraded in (False, True):
            with self.subTest(degraded=degraded), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    raw = b'raw\x00\xff\nAddressSanitizer: fixture\ncrash-output: fixture\n'
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(raw)
                    native.poll()
                    if degraded:
                        native.warnings.add('capture-unconfirmed')
                    result = native.close()
                self.assertEqual((pathlib.Path(result['artifactDirectory']) / source.name).read_bytes(), raw)
                self.assertTrue(result['collectionComplete'])
                if degraded:
                    self.assertIn('capture-unconfirmed', result['warnings'])

    def test_unavailable_native_cache_keeps_independent_startup_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            blocked = root / 'not-a-directory'
            blocked.write_text('keep-existing')
            with mock.patch.object(session, 'ROOT', root), mock.patch.object(session.pathlib.Path, 'home', return_value=root):
                native = session.NativeTestDiagnostics(blocked, output.parent / 'Native', 'session-1', ['net.phere.GitXTests'], True)
                self.addCleanup(shutil.rmtree, native.root, ignore_errors=True)
                environment = {}
                native.configure(environment)
                self.assertEqual(environment['GITX_TEST_STDERR_DIRECTORY'], '')
                record = self.startup_record(native.invocation)
                (native.progress_directory / 'startup-42-a.json').write_text(json.dumps(record))
                self.assertTrue(native.poll())
                result = native.close()
            self.assertIn('cache-directory', result['warnings'])
            self.assertEqual(blocked.read_text(), 'keep-existing')

    def test_partial_native_collection_warns_without_failing_the_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, diagnostics = self.capture_fixture(root)
            child = self.startup_child() + "\np=pathlib.Path(os.environ['GITX_TEST_STDERR_DIRECTORY']); (p/f'GitX-{os.getpid()}-a.stderr.log').write_bytes(b'keep-native-evidence')"
            with mock.patch.object(session, 'ROOT', root), mock.patch.object(session.NativeTestDiagnostics, '_archive_chunk', return_value=None):
                status = session.supervise([sys.executable, '-c', child], directory=diagnostics,
                                           native_test_root=root / 'cache', native_artifact_directory=output.parent / 'Native',
                                           capture_native_stderr=True)
            self.assertEqual(status, 0)
            state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            native = state['nativeDiagnostics']
            self.assertEqual(state['status'], 'passed')
            self.assertFalse(native['collectionComplete'])
            self.assertIn('collection-incomplete', native['warnings'])
            self.assertEqual(next((pathlib.Path(native['sourceDirectory']) / 'Stderr').glob('*.log')).read_bytes(), b'keep-native-evidence')

    def test_native_console_backpressure_cannot_hold_child_completion_or_raw_archival(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            raw = b'native-diagnostic\x00\xff' * 32768
            child = self.startup_child() + "\np=pathlib.Path(os.environ['GITX_TEST_STDERR_DIRECTORY']); (p/f'GitX-{os.getpid()}-a.stderr.log').write_bytes(b'native-diagnostic\\x00\\xff'*32768)"
            process = subprocess.Popen([sys.executable, str(entry), 'run', '--diagnostics', str(diagnostics),
                                        '--native-test-root', str(root / 'cache'), '--native-artifact-directory', str(output.parent / 'Native'),
                                        '--capture-native-stderr', '--', sys.executable, '-c', child],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
            native = json.loads((diagnostics / 'diagnostic-owner.json').read_text())['nativeDiagnostics']
            self.assertFalse(native['consoleComplete'])
            self.assertTrue(native['collectionComplete'])
            self.assertEqual(next(pathlib.Path(native['artifactDirectory']).glob('*.stderr.log')).read_bytes(), raw)

    def test_native_interruption_retains_final_bytes_and_original_interruption_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            entry, output, diagnostics = self.capture_fixture(root)
            ready = root / 'ready'
            child = r'''
import os, pathlib, signal, sys
native = pathlib.Path(os.environ['GITX_TEST_STDERR_DIRECTORY'])
fd = os.open(native / f'GitX-{os.getpid()}-a.stderr.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, b'before-cancel\n')
def finish(*_):
    os.write(fd, b'final-before-exit\n')
    os.close(fd)
    sys.exit(0)
signal.signal(signal.SIGTERM, finish)
pathlib.Path(sys.argv[1]).write_text('ready')
signal.pause()
'''
            process = subprocess.Popen([sys.executable, str(entry), 'run', '--diagnostics', str(diagnostics),
                                        '--native-test-root', str(root / 'cache'), '--native-artifact-directory', str(output.parent / 'Native'),
                                        '--capture-native-stderr', '--', sys.executable, '-c', child, str(ready)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    threading.Event().wait(.01)
                self.assertTrue(ready.exists())
                process.terminate()
                process.communicate(timeout=15)
                self.assertEqual(process.returncode, 130)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
            state = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
            self.assertEqual(state['category'], 'interrupted')
            native = state['nativeDiagnostics']
            self.assertEqual(next(pathlib.Path(native['artifactDirectory']).glob('*.stderr.log')).read_bytes(),
                             b'before-cancel\nfinal-before-exit\n')

    def test_watchdog_preserves_failure_and_bounds_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            failed = session.supervise([sys.executable, "-c", "raise SystemExit(9)"], timeout=2, directory=directory)
            self.assertEqual(failed, 9)
            status = session.supervise([sys.executable, "-c", "import time;time.sleep(30)"], timeout=2, startup_timeout=.1, directory=directory)
            self.assertEqual(status, 124)
            self.assertEqual(json.loads((pathlib.Path(directory) / "blocker.json").read_text())["category"], "unknown-host-startup-timeout")
            status = session.supervise([sys.executable, "-c", "print('Test Suite started',flush=True)"], timeout=2, startup_timeout=1, directory=directory)
            self.assertEqual(status, 0)
