from __future__ import annotations

import json
import contextlib
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
    @contextlib.contextmanager
    def completed_native_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'finalization-\x00\xff')
                lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                try:
                    fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    native.close()
                finally:
                    os.close(lease)
                yield native, source

    def test_retirement_controls_release_and_keep_persistent_inode(self):
        with self.completed_native_fixture() as (native, source):
            control = native.registration.with_name(native.registration.name + '.retirement.lock')
            identity = session.native_stat_snapshot(control.stat())[:2]
            with session.NativeControlLease(control):
                with self.assertRaises(BlockingIOError):
                    with session.NativeControlLease(control):
                        self.fail('A second retirement acquired the same control')
            with session.NativeControlLease(control):
                self.assertEqual(session.native_stat_snapshot(control.stat())[:2], identity)
            state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(owner['deletionProof']['parentIdentity'], owner['retirementParentIdentity'])
            self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_retirement_rejects_parent_replacement_after_promotion(self):
        with self.completed_native_fixture() as (native, source):
            promote = session.promote_native_completion
            original = native.registration.read_bytes()
            def replace_parent(*args, **kwargs):
                result = promote(*args, **kwargs)
                parent = native.root.parent
                saved = parent.with_name('saved-parent')
                parent.rename(saved)
                parent.mkdir()
                (saved / native.root.name).rename(native.root)
                return result
            with mock.patch.object(session, 'promote_native_completion', side_effect=replace_parent):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retained', reason)
            self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')
            self.assertNotIn('deletionProof', owner)
            self.assertNotIn('retirementPath', owner)
            self.assertEqual(owner['retirementOutcome']['origin'], 'source')
            self.assertEqual(json.loads(original)['directoryIdentity'], owner['directoryIdentity'])

    def test_absent_recovery_rechecks_paths_after_authorization(self):
        for change in ('original', 'quarantine', 'parent'):
            with self.subTest(change=change), self.completed_native_fixture() as (native, _):
                owner = json.loads(native.registration.read_text())
                quarantine = native.root.with_name('.gitx-native-retired-' + 'd' * 32)
                owner.update(retirementState='deferred', retirementPhase='deleting', retirementPath=str(quarantine),
                             retirementParentIdentity=session.native_directory_identity(native.root.parent))
                session.shutil.rmtree(native.root)
                session.atomic_json(native.registration, owner)
                changed = False
                @contextlib.contextmanager
                def change_at_admission():
                    nonlocal changed
                    if not changed:
                        changed = True
                        if change == 'parent':
                            native.root.parent.rename(native.root.parent.with_name('saved-parent'))
                            native.root.parent.mkdir()
                        else:
                            (native.root if change == 'original' else quarantine).mkdir()
                    yield
                state, reason, after = session.retire_registered_native_sources(native.registration, authorize=change_at_admission)
                self.assertEqual(state, 'retained', reason)
                self.assertNotEqual(after.get('retirementPhase'), 'retired')

    def test_invalid_invocation_controls_are_report_only_and_repairable(self):
        for suffix in ('.lock', '.retirement.lock'):
            for kind in ('fifo', 'directory', 'symlink', 'mode', 'links'):
                with self.subTest(suffix=suffix, kind=kind), self.completed_native_fixture() as (native, source):
                    control = native.registration.with_name(native.registration.name + suffix)
                    control.unlink(missing_ok=True)
                    if kind == 'fifo':
                        os.mkfifo(control, 0o600)
                    elif kind == 'directory':
                        control.mkdir()
                    elif kind == 'symlink':
                        control.symlink_to(source)
                    else:
                        control.write_bytes(b'')
                        control.chmod(0o644 if kind == 'mode' else 0o600)
                        if kind == 'links':
                            os.link(control, control.with_name('unrelated-link'))
                    before = native.registration.read_bytes()
                    checkpoint = (native.root / 'native-owner.json').read_bytes()
                    for _ in range(2):
                        state, reason, owner = session.retire_registered_native_sources(native.registration)
                        self.assertEqual(state, 'retained', reason)
                        self.assertTrue(owner['retirementOutcome']['reportOnly'])
                        self.assertEqual(native.registration.read_bytes(), before)
                        self.assertEqual((native.root / 'native-owner.json').read_bytes(), checkpoint)
                        self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')
                    if kind == 'directory':
                        control.rmdir()
                    else:
                        control.unlink()
                    self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_outcome_retryability_and_publication_are_independent(self):
        for origin in ('authorization', 'registration', 'durability', 'producer', 'source', 'archive'):
            for state in ('retained', 'deferred'):
                with self.subTest(origin=origin, state=state):
                    outcome = session.NativeRetirementOutcome(state, origin=origin)
                    self.assertEqual(session.native_outcome_is_publishable(outcome),
                                     not (state == 'deferred' and origin in {'authorization', 'registration', 'producer'}))
                    report = session.NativeRetirementOutcome(state, origin=origin, report_only=True)
                    self.assertFalse(session.native_outcome_is_publishable(report))
            self.assertEqual(session.native_evidence_failure_state(origin),
                             'deferred' if origin in {'authorization', 'registration', 'durability'} else 'retained')

    def test_location_replacement_at_hash_and_authorization_boundaries(self):
        for boundary in ('hash', 'authorize', 'rename', 'publish-deleting'):
            for replacement in ('root', 'parent'):
                with self.subTest(boundary=boundary, replacement=replacement), self.completed_native_fixture() as (native, source):
                    changed = False
                    def replace():
                        nonlocal changed
                        if changed:
                            return
                        changed = True
                        if replacement == 'parent':
                            parent = native.root.parent
                            saved = parent.with_name('saved-parent')
                            parent.rename(saved)
                            parent.mkdir()
                            # Preserve either the original or the renamed approved root.
                            for child in list(saved.iterdir()):
                                child.rename(parent / child.name)
                        else:
                            root = next(iter(native.root.parent.glob('.gitx-native-retired-*')), native.root)
                            root.rename(root.with_name('saved-root'))
                            root.mkdir()
                            (root / 'keep').write_bytes(b'replacement')
                    digest, rename, publish = session.descriptor_digest, session.exclusive_native_rename, session.NativeRegistrationSnapshot.publish
                    def hashing(descriptor):
                        result = digest(descriptor)
                        if boundary == 'hash':
                            replace()
                        return result
                    def renaming(*args, **kwargs):
                        result = rename(*args, **kwargs)
                        if boundary == 'rename':
                            replace()
                        return result
                    def publishing(transaction, value):
                        result = publish(transaction, value)
                        if boundary == 'publish-deleting' and value.get('retirementPhase') == 'deleting':
                            replace()
                        return result
                    @contextlib.contextmanager
                    def authorize():
                        if boundary == 'authorize':
                            replace()
                        yield
                    with mock.patch.object(session, 'descriptor_digest', side_effect=hashing), \
                            mock.patch.object(session, 'exclusive_native_rename', side_effect=renaming), \
                            mock.patch.object(session.NativeRegistrationSnapshot, 'publish', new=publishing):
                        state, reason, owner = session.retire_registered_native_sources(native.registration, authorize=authorize)
                    self.assertTrue(changed)
                    self.assertEqual(state, 'retained', reason)
                    self.assertNotEqual(owner.get('retirementPhase'), 'retired')
                    self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
                    if replacement == 'root':
                        self.assertTrue(any(path.name == 'keep' for path in native.root.parent.rglob('keep')))

    def test_foreign_control_is_report_only_but_uncertain_access_is_retryable(self):
        for condition in ('foreign-owner', 'access-denied'):
            with self.subTest(condition=condition), self.completed_native_fixture() as (native, _):
                control = native.registration.with_name(native.registration.name + '.retirement.lock')
                before = native.registration.read_bytes()
                inspect, opening = session.os.stat, session.os.open
                def stat_control(path, *args, **kwargs):
                    result = inspect(path, *args, **kwargs)
                    if condition == 'foreign-owner' and path == control.name:
                        return SimpleNamespace(st_mode=result.st_mode, st_uid=result.st_uid ^ 1, st_nlink=result.st_nlink)
                    return result
                def open_control(path, *args, **kwargs):
                    if condition == 'access-denied' and path == control.name:
                        raise PermissionError(errno.EACCES, 'injected uncertain control access')
                    return opening(path, *args, **kwargs)
                with mock.patch.object(session.os, 'stat', side_effect=stat_control), \
                        mock.patch.object(session.os, 'open', side_effect=open_control):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                outcome = owner['retirementOutcome']
                self.assertEqual(state, 'retained' if condition == 'foreign-owner' else 'deferred', reason)
                self.assertEqual(outcome.get('reportOnly', False), condition == 'foreign-owner')
                self.assertEqual(outcome['operation'], 'acquire-retirement-lease')
                self.assertEqual(outcome['errno'], errno.EPERM if condition == 'foreign-owner' else errno.EACCES)
                self.assertEqual(native.registration.read_bytes(), before)

    def test_registered_quarantine_recovery_preserves_archived_bytes(self):
        for phase in ('prepared', 'deleting'):
            with self.subTest(phase=phase), self.completed_native_fixture() as (native, source):
                archived = (native.archive / source.name).read_bytes()
                publish = session.NativeRegistrationSnapshot.publish
                def interrupt_publication(registration, value):
                    if phase == 'prepared' and value.get('retirementPhase') == 'deleting':
                        raise OSError(errno.ENOSPC, 'characterization publication interrupted')
                    return publish(registration, value)
                remove = session.shutil.rmtree
                def interrupt_removal(path, *args, **kwargs):
                    if phase == 'deleting' and pathlib.Path(path).name.startswith('.gitx-native-retired-'):
                        raise OSError(errno.EINTR, 'characterization removal interrupted')
                    return remove(path, *args, **kwargs)
                with mock.patch.object(session.NativeRegistrationSnapshot, 'publish', new=interrupt_publication), \
                        mock.patch.object(session.shutil, 'rmtree', side_effect=interrupt_removal):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(owner['retirementPhase'], phase)
                quarantine = pathlib.Path(owner['retirementPath'])
                self.assertFalse(native.root.exists())
                self.assertTrue(quarantine.is_dir())
                state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertFalse(quarantine.exists())
                self.assertEqual((native.archive / source.name).read_bytes(), archived)
                self.assertEqual(json.loads(native.registration.read_text())['retirementState'], 'retired')

    def test_genuine_legacy_intact_quarantine_needs_no_new_metadata(self):
        for state in ('prepared', 'deferred'):
            with self.subTest(state=state), self.completed_native_fixture() as (native, source):
                owner = json.loads(native.registration.read_text())
                for field in ('retirementPhase', 'retirementParentIdentity', 'deletionProof'):
                    owner.pop(field, None)
                quarantine = native.root.with_name('.gitx-native-retired-' + 'b' * 32)
                owner.update(retirementState=state, retirementPath=str(quarantine))
                session.exclusive_native_rename(native.root, quarantine)
                session.atomic_json(native.registration, owner)
                state_after, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state_after, 'retired', reason)
                self.assertFalse(quarantine.exists())
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_legacy_registered_quarantines_recover_without_phase(self):
        for state in ('prepared', 'deferred', 'retained'):
            for contents in ('intact', 'partial', 'controls-only', 'log-missing', 'directory-missing', 'absent'):
                with self.subTest(state=state, contents=contents), self.completed_native_fixture() as (native, source):
                    owner = json.loads(native.registration.read_text())
                    quarantine = native.root.with_name('.gitx-native-retired-' + 'a' * 32)
                    for field in ('retirementPhase', 'retirementParentIdentity', 'deletionProof'):
                        owner.pop(field, None)
                    owner.update(retirementState=state, retirementPath=str(quarantine))
                    session.exclusive_native_rename(native.root, quarantine)
                    if contents == 'partial':
                        (quarantine / 'invocation.lease').unlink()
                        (quarantine / 'native-owner.json').unlink()
                    elif contents == 'controls-only':
                        for folder in ('Stderr', 'Progress'):
                            session.shutil.rmtree(quarantine / folder)
                    elif contents == 'log-missing':
                        (quarantine / 'Stderr' / source.name).unlink()
                    elif contents == 'directory-missing':
                        session.shutil.rmtree(quarantine / 'Stderr')
                    elif contents == 'absent':
                        session.shutil.rmtree(quarantine)
                    session.atomic_json(native.registration, owner)
                    if state == 'retained':
                        before = native.registration.read_bytes()
                        with mock.patch.object(session, 'descriptor_digest', side_effect=AssertionError('Default retained retry hashed evidence')):
                            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')
                        self.assertEqual(native.registration.read_bytes(), before)
                    state_after, reason, _ = session.retire_registered_native_sources(native.registration, retry_retained=state == 'retained')
                    self.assertEqual(state_after, 'retired', reason)
                    self.assertFalse(quarantine.exists())
                    self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_genuine_legacy_recovery_rejects_changed_evidence(self):
        for variant in ('archive', 'identity', 'unexpected', 'replacement', 'original-reappeared'):
            with self.subTest(variant=variant), self.completed_native_fixture() as (native, source):
                owner = json.loads(native.registration.read_text())
                for field in ('retirementPhase', 'retirementParentIdentity', 'deletionProof'):
                    owner.pop(field, None)
                quarantine = native.root.with_name('.gitx-native-retired-' + 'c' * 32)
                owner.update(retirementState='deferred', retirementPath=str(quarantine))
                session.exclusive_native_rename(native.root, quarantine)
                (quarantine / 'invocation.lease').unlink()
                if variant == 'archive':
                    (native.archive / source.name).write_bytes(b'changed archive')
                elif variant == 'identity':
                    owner['directoryIdentity'] = [0, 0]
                elif variant == 'unexpected':
                    (quarantine / 'unapproved').write_bytes(b'keep')
                elif variant == 'replacement':
                    path = quarantine / 'Stderr' / source.name
                    saved = quarantine.parent / 'saved-log'
                    path.rename(saved)
                    path.write_bytes(saved.read_bytes())
                else:
                    native.root.mkdir()
                session.atomic_json(native.registration, owner)
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retained', reason)
                self.assertTrue(quarantine.exists())
                self.assertTrue((quarantine / 'native-owner.json').exists())
                self.assertEqual(session.retire_registered_native_sources(native.registration, retry_retained=True)[0], 'retained')
                self.assertTrue(quarantine.exists())

    def test_typed_invalid_evidence_respects_retryable_metadata_boundaries(self):
        for origin in ('authorization', 'registration', 'durability', 'source', 'archive', 'producer'):
            with self.subTest(origin=origin):
                with self.assertRaises(session.NativeRetirementFault) as caught:
                    with session.native_retirement_boundary(origin, 'injected-boundary', evidence=origin in {'source', 'archive'}):
                        raise session.NativeEvidenceError('invalid inspected identity')
                outcome = caught.exception.outcome
                self.assertEqual(outcome.state, 'deferred' if origin in {'authorization', 'registration', 'durability'} else 'retained')
                self.assertEqual((outcome.origin, outcome.operation, outcome.error_number), (origin, 'injected-boundary', errno.EPERM))

    def test_invalid_writer_inventory_is_retained_but_uncertain_access_is_deferred(self):
        for kind in ('fifo', 'directory', 'foreign-owner'):
            with self.subTest(kind=kind), self.completed_native_fixture() as (native, source):
                invalid = native.stderr_directory / 'unexpected'
                if kind == 'fifo':
                    os.mkfifo(invalid)
                elif kind == 'directory':
                    invalid.mkdir()
                else:
                    invalid.write_bytes(b'foreign')
                inspect = session.os.fstat
                inode = invalid.stat().st_ino
                def foreign_info(descriptor):
                    info = inspect(descriptor)
                    if kind == 'foreign-owner' and info.st_ino == inode:
                        values = list(info); values[4] = os.getuid() + 1
                        return os.stat_result(values)
                    return info
                with mock.patch.object(session.os, 'fstat', side_effect=foreign_info):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retained', reason)
                self.assertEqual(owner['retirementOutcome']['errno'], errno.EPERM)
                self.assertEqual(owner['retirementOutcome']['operation'], 'inspect-writer-file')
                self.assertTrue(source.exists())
                with mock.patch.object(session, 'descriptor_digest', side_effect=AssertionError('retained evidence rehashed')):
                    self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')

    def test_invalid_inventory_does_not_poison_uncertain_running_registration(self):
        with self.completed_native_fixture() as (native, _):
            owner = json.loads(native.registration.read_text())
            owner.update(status='running', collectionComplete=False, files=[])
            session.atomic_json(native.registration, owner)
            before = native.registration.read_bytes()
            os.mkfifo(native.stderr_directory / 'unproven-writer')
            state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'deferred', reason)
            self.assertEqual(native.registration.read_bytes(), before)

    def test_inaccessible_writer_directory_remains_retryable_without_sticky_publication(self):
        with self.completed_native_fixture() as (native, source):
            before = native.registration.read_bytes()
            mode = native.stderr_directory.stat().st_mode & 0o777
            native.stderr_directory.chmod(0)
            try:
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            finally:
                native.stderr_directory.chmod(mode)
            self.assertEqual(state, 'deferred', reason)
            self.assertEqual(owner['retirementOutcome']['operation'], 'inspect-writer-directory')
            self.assertEqual(owner['retirementOutcome']['errno'], errno.EACCES)
            self.assertEqual(native.registration.read_bytes(), before)
            self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_post_removal_sync_permission_failure_is_retryable_without_manual_retry(self):
        for code in (errno.EACCES, errno.EPERM):
            with self.subTest(errno=code), self.completed_native_fixture() as (native, source):
                sync = session.sync_native_directory
                def fail_removed_parent(path):
                    if pathlib.Path(path) == native.root.parent and not native.root.exists():
                        quarantine = list(native.root.parent.glob('.gitx-native-retired-*'))
                        if not quarantine:
                            raise OSError(code, 'removed parent sync failed')
                    return sync(path)
                with mock.patch.object(session, 'sync_native_directory', side_effect=fail_removed_parent):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(owner['retirementPhase'], 'deleting')
                self.assertEqual(owner['retirementOutcome']['operation'], 'sync-retirement-parent')
                calls = []
                def record_sync(path):
                    calls.append(pathlib.Path(path)); return sync(path)
                with mock.patch.object(session, 'sync_native_directory', side_effect=record_sync):
                    state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertIn(native.root.parent, calls)
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_missing_registration_does_not_create_retirement_controls(self):
        for parent_exists in (False, True):
            with self.subTest(parent_exists=parent_exists), tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory) / 'NativeSources'
                if parent_exists:
                    parent.mkdir()
                state, _, _ = session.retire_registered_native_sources(parent / ('a' * 32 + '.json'))
                self.assertEqual(state, 'deferred')
                self.assertEqual(parent.exists(), parent_exists)
                if parent_exists:
                    self.assertEqual(list(parent.iterdir()), [])

    def test_retirement_reuses_owned_descriptors_under_a_256_descriptor_limit(self):
        script = r'''
import fcntl, json, os, pathlib, resource, sys
import workflow_session as s
root = pathlib.Path(sys.argv[1]).resolve()
(root / 'scripts').mkdir()
(root / 'scripts/verification-config.json').write_text(json.dumps({'artifactRoot': 'artifacts/verification'}))
s.ROOT = root
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (min(1024, hard) if hard != resource.RLIM_INFINITY else 1024, hard))
native = s.NativeTestDiagnostics(root / 'cache', root / 'artifacts/verification/run/Logs/Native', 'session', ['bundle'], True)
for number in range(130):
    (native.stderr_directory / ('GitX-%d-a.stderr.log' % number)).write_bytes(bytes([number, 0, 255]))
lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
assert native.close()['collectionComplete']
os.close(lease)
resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard))
opened, peak, source_opens = s.open_owned_regular, 0, 0
def measure(path, *args, **kwargs):
    global peak, source_opens
    result = opened(path, *args, **kwargs)
    peak = max(peak, len(os.listdir('/dev/fd')))
    if pathlib.Path(path).parent == native.stderr_directory:
        source_opens += 1
    return result
s.open_owned_regular = measure
state, reason, owner = s.retire_registered_native_sources(native.registration)
assert state == 'retired', (state, reason, owner.get('retirementOutcome'))
assert source_opens == 130, source_opens
for number in range(130):
    assert (native.archive / ('GitX-%d-a.stderr.log' % number)).read_bytes() == bytes([number, 0, 255])
print(json.dumps({'diagnosticFiles': 130, 'sourceOpens': source_opens, 'peakDescriptors': peak, 'softLimit': 256}))
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-c', script, directory], env=os.environ | {'PYTHONPATH': str(ROOT / 'scripts')},
                                    capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr[-4000:])
        if result.returncode == 0:
            print(result.stdout.splitlines()[-1])

    def test_empty_checkpoint_recovers_only_with_authenticated_handoff_and_authorization(self):
        for variant in ('registered-complete', 'registered-running', 'invalid-handoff', 'refused-authorization'):
            with self.subTest(variant=variant), self.completed_native_fixture() as (native, source):
                checkpoint = native.root / 'native-owner.json'
                session.atomic_json(checkpoint, {})
                if variant == 'registered-running':
                    owner = json.loads(native.registration.read_text())
                    owner.update(status='running', collectionComplete=False, files=[])
                    session.atomic_json(native.registration, owner)
                if variant == 'invalid-handoff':
                    session.atomic_json(session.native_completion_path(native.registration), {})
                before = native.registration.read_bytes()
                @contextlib.contextmanager
                def authorize():
                    if variant == 'refused-authorization':
                        raise session.NativeRetirementDeferred('newer commit queued')
                    yield
                state, reason, _ = session.retire_registered_native_sources(native.registration, authorize=authorize)
                if variant in ('registered-complete', 'registered-running'):
                    self.assertEqual(state, 'retired', reason)
                    self.assertFalse(native.root.exists())
                else:
                    self.assertEqual(state, 'deferred' if variant == 'refused-authorization' else 'retained', reason)
                    self.assertEqual(json.loads(checkpoint.read_text()), {})
                    if variant == 'refused-authorization':
                        self.assertEqual(native.registration.read_bytes(), before)
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_empty_checkpoint_replacement_before_repair_is_not_overwritten(self):
        with self.completed_native_fixture() as (native, source):
            checkpoint = native.root / 'native-owner.json'
            session.atomic_json(checkpoint, {})
            foreign = {'invocationID': 'foreign'}
            @contextlib.contextmanager
            def authorize():
                session.atomic_json(checkpoint, foreign)
                yield
            state, reason, _ = session.retire_registered_native_sources(native.registration, authorize=authorize)
            self.assertEqual(state, 'deferred', reason)
            self.assertEqual(json.loads(checkpoint.read_text()), foreign)
            self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')

    def test_retirement_admission_refusal_does_not_hash_or_publish(self):
        for reason in ('newer commit queued', 'commit-or-inputs-changed', 'protected native source', 'protection-discovery-incomplete'):
            with self.subTest(reason=reason), self.completed_native_fixture() as (native, source):
                before = native.registration.read_bytes()
                with mock.patch.object(session, 'descriptor_digest', side_effect=AssertionError('refused admission hashed files')):
                    state, actual, _ = session.retire_registered_native_sources(native.registration, admit=lambda: reason)
                self.assertEqual((state, actual), ('deferred', reason))
                self.assertEqual(native.registration.read_bytes(), before)
                self.assertTrue(source.exists())

    def test_concurrent_retirement_is_nonblocking_without_blocking_registry_publishers(self):
        with self.completed_native_fixture() as (native, _):
            digest = session.descriptor_digest
            results = []
            def overlap(descriptor):
                if not results:
                    results.append(session.retire_registered_native_sources(native.registration))
                    with session.NativeRegistration(native.registration) as writer:
                        self.assertEqual(writer.current['status'], 'passed')
                return digest(descriptor)
            with mock.patch.object(session, 'descriptor_digest', side_effect=overlap):
                state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(results[0][:2], ('deferred', 'registration-busy'))

    def test_completion_recovery_hashes_each_source_and_archive_once(self):
        with self.completed_native_fixture() as (native, source):
            before = json.loads(native.registration.read_text())
            before.update(status='running', collectionComplete=False, files=[])
            session.atomic_json(native.registration, before)
            expected = {source.stat().st_ino, (native.archive / source.name).stat().st_ino}
            digest, counts, durations = session.descriptor_digest, {}, []
            def measured(descriptor):
                inode = os.fstat(descriptor).st_ino
                counts[inode] = counts.get(inode, 0) + 1
                start = time.monotonic()
                try:
                    return digest(descriptor)
                finally:
                    durations.append(time.monotonic() - start)
            with mock.patch.object(session, 'descriptor_digest', side_effect=measured):
                state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual({inode: counts[inode] for inode in expected}, dict.fromkeys(expected, 1))
            print(json.dumps({'completionRecovery': {'digestCalls': counts, 'digestSeconds': durations}}))

    def test_retired_invocation_removes_redundant_handoff_and_keeps_audit_registration(self):
        with self.completed_native_fixture() as (native, source):
            completion = session.native_completion_path(native.registration)
            self.assertTrue(completion.exists())
            state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(owner['handoffCleanup']['state'], 'removed')
            self.assertFalse(completion.exists())
            self.assertEqual(json.loads(native.registration.read_text())['retirementState'], 'retired')
            self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
            print(json.dumps({'handoffCounts': {'before': 1, 'after': len(list(completion.parent.glob('*.json')))}}))

    def test_redundant_handoff_cleanup_is_authorized_and_independent_of_source_status(self):
        for refusal in ('authorization', 'unlink', 'symlink', 'malformed', 'source-reappeared'):
            with self.subTest(refusal=refusal), self.completed_native_fixture() as (native, _):
                completion = session.native_completion_path(native.registration)
                envelope = json.loads(completion.read_text())
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')
                session.atomic_json(completion, envelope)
                audit = native.registration.read_bytes()
                @contextlib.contextmanager
                def authorize():
                    if refusal == 'authorization':
                        raise session.NativeRetirementDeferred('newer commit queued')
                    yield
                if refusal == 'symlink':
                    foreign = completion.with_name('foreign')
                    foreign.write_bytes(b'foreign-evidence')
                    completion.unlink()
                    completion.symlink_to(foreign)
                elif refusal == 'malformed':
                    session.atomic_json(completion, [])
                elif refusal == 'source-reappeared':
                    native.root.mkdir()
                unlink = session.os.unlink
                def refuse_unlink(path, *args, **kwargs):
                    if refusal == 'unlink' and pathlib.Path(path).name == completion.name:
                        raise PermissionError(errno.EACCES, 'handoff-unavailable')
                    return unlink(path, *args, **kwargs)
                with mock.patch.object(session.os, 'unlink', side_effect=refuse_unlink):
                    state, _, owner = session.retire_registered_native_sources(native.registration, authorize=authorize)
                self.assertEqual(state, 'retired')
                self.assertEqual(native.registration.read_bytes(), audit)
                self.assertTrue(completion.exists())
                self.assertIn(owner['handoffCleanup']['state'], {'deferred', 'retained'})
                if refusal == 'authorization':
                    self.assertEqual(owner['handoffCleanup']['reason'], 'newer commit queued')
                if refusal == 'unlink':
                    self.assertEqual(owner['handoffCleanup']['errno'], errno.EACCES)
                # Only this isolated fixture repairs the rejected evidence.
                if completion.is_symlink():
                    self.assertEqual(completion.read_bytes(), b'foreign-evidence')
                    completion.unlink()
                if native.root.exists():
                    native.root.rmdir()
                session.atomic_json(completion, envelope)
                state, _, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired')
                self.assertEqual(owner['handoffCleanup']['state'], 'removed')
                self.assertFalse(completion.exists())

    def test_finalization_repairs_both_checkpoint_orders_and_explicit_retained_retry(self):
        for variant in ('registry-running', 'source-running', 'source-missing', 'retained-repaired'):
            with self.subTest(variant=variant), self.completed_native_fixture() as (native, source):
                registered = json.loads(native.registration.read_text())
                checkpoint = native.root / 'native-owner.json'
                if variant in ('registry-running', 'retained-repaired'):
                    registered.update(status='running', collectionComplete=False, files=[])
                    if variant == 'retained-repaired':
                        registered.update(retirementState='retained', retirementReason='completion-invalid')
                    session.atomic_json(native.registration, registered)
                elif variant == 'source-running':
                    owner = json.loads(checkpoint.read_text())
                    owner.update(status='running', collectionComplete=False, files=[])
                    session.atomic_json(checkpoint, owner)
                else:
                    checkpoint.unlink()
                state, reason, result = session.retire_registered_native_sources(native.registration, retry_retained=True)
                self.assertEqual(state, 'retired', reason)
                self.assertTrue(result['collectionComplete'])
                self.assertFalse(native.root.exists())
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_default_retained_skip_does_not_require_new_mutation_admission(self):
        with self.completed_native_fixture() as (native, _):
            owner = json.loads(native.registration.read_text())
            owner.update(retirementState='retained', retirementReason='archive-incomplete')
            session.atomic_json(native.registration, owner)
            before = native.registration.read_bytes()
            with mock.patch.object(session, 'descriptor_digest', side_effect=AssertionError('retained evidence rehashed')):
                state, reason, _ = session.retire_registered_native_sources(native.registration, admit=lambda: 'protected native source')
            self.assertEqual((state, reason), ('retained', 'archive-incomplete'))
            self.assertEqual(native.registration.read_bytes(), before)
            state, reason, _ = session.retire_registered_native_sources(native.registration, admit=lambda: 'protected native source', retry_retained=True)
            self.assertEqual((state, reason), ('deferred', 'protected native source'))
            self.assertEqual(native.registration.read_bytes(), before)

    def test_unprovable_writer_lease_does_not_publish_sticky_evidence(self):
        for boundary in ('invocation', 'file'):
            with self.subTest(boundary=boundary), self.completed_native_fixture() as (native, source):
                before = native.registration.read_bytes()
                opened, locked = session.open_owned_regular, session.fcntl.flock
                def fail_open(path, *args, **kwargs):
                    if boundary == 'invocation' and pathlib.Path(path) == native.root / 'invocation.lease':
                        raise PermissionError(errno.EACCES, 'unprovable-invocation-writer')
                    return opened(path, *args, **kwargs)
                def fail_lock(descriptor, flags):
                    if boundary == 'file' and os.fstat(descriptor).st_ino == source.stat().st_ino:
                        raise PermissionError(errno.EACCES, 'unprovable-file-writer')
                    return locked(descriptor, flags)
                with mock.patch.object(session, 'open_owned_regular', side_effect=fail_open), \
                        mock.patch.object(session.fcntl, 'flock', side_effect=fail_lock), \
                        mock.patch.object(session, 'descriptor_digest', side_effect=AssertionError('unproven writer allowed hashing')):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(owner['retirementOutcome']['errno'], errno.EACCES)
                self.assertEqual(native.registration.read_bytes(), before)
                self.assertTrue(source.exists())

    def test_finalization_never_classifies_or_mutates_an_active_writer(self):
        for inherited in (False, True):
            with self.subTest(inherited=inherited), self.completed_native_fixture() as (native, source):
                before = json.loads(native.registration.read_text())
                before.update(status='running', collectionComplete=False, files=[])
                session.atomic_json(native.registration, before)
                session.atomic_json(session.native_completion_path(native.registration), [])
                lease = os.open(source if inherited else native.root / 'invocation.lease', os.O_RDONLY)
                try:
                    fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    state, reason, _ = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'deferred', reason)
                    self.assertEqual(json.loads(native.registration.read_text()), before)
                finally:
                    os.close(lease)
                # A live PID with no usable final handoff still cannot be poisoned.
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(json.loads(native.registration.read_text()), before)

    def test_refused_authorization_cannot_publish_completion_or_retained_state(self):
        for fault in ('valid-completion', 'invalid-archive', 'changed-owner'):
            with self.subTest(fault=fault), self.completed_native_fixture() as (native, source):
                before = json.loads(native.registration.read_text())
                before.update(status='running', collectionComplete=False, files=[])
                session.atomic_json(native.registration, before)
                checkpoint = native.root / 'native-owner.json'
                owner = json.loads(checkpoint.read_text())
                owner.update(status='running', collectionComplete=False, files=[])
                if fault == 'changed-owner':
                    owner['invocationID'] = 'foreign'
                session.atomic_json(checkpoint, owner)
                if fault == 'invalid-archive':
                    (native.archive / source.name).write_bytes(b'changed')
                source_before = checkpoint.read_bytes()
                @contextlib.contextmanager
                def refuse():
                    raise session.NativeRetirementDeferred('newer commit queued')
                    yield
                state, reason, _ = session.retire_registered_native_sources(native.registration, authorize=refuse)
                self.assertEqual((state, reason), ('deferred', 'newer commit queued'))
                self.assertEqual(json.loads(native.registration.read_text()), before)
                self.assertEqual(checkpoint.read_bytes(), source_before)
                self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')

    def test_finalization_publishes_registration_before_repair_and_recovers_repair_failure(self):
        with self.completed_native_fixture() as (native, source):
            checkpoint = native.root / 'native-owner.json'
            owner = json.loads(checkpoint.read_text())
            owner.update(status='running', collectionComplete=False, files=[])
            session.atomic_json(checkpoint, owner)
            registry = json.loads(native.registration.read_text())
            registry.update(status='running', collectionComplete=False, files=[])
            session.atomic_json(native.registration, registry)
            publish = session.atomic_json
            def fail_repair(path, value):
                if pathlib.Path(path) == checkpoint:
                    self.assertEqual(json.loads(native.registration.read_text())['status'], 'passed')
                    raise OSError(errno.ENOSPC, 'repair-full')
                return publish(path, value)
            with mock.patch.object(session, 'atomic_json', side_effect=fail_repair):
                state, _, result = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'deferred')
            self.assertEqual(result['retirementOutcome']['errno'], errno.ENOSPC)
            self.assertTrue(session.native_completion_path(native.registration).exists())
            state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_permanent_deletion_permissions_require_explicit_repaired_retry(self):
        for code in (errno.EACCES, errno.EPERM):
            with self.subTest(errno=code), self.completed_native_fixture() as (native, source):
                with mock.patch.object(session.shutil, 'rmtree', side_effect=OSError(code, 'manual-repair')):
                    state, reason, result = session.retire_registered_native_sources(native.registration)
                self.assertEqual((state, reason), ('retained', 'deletion-unavailable'))
                self.assertEqual(result['retirementOutcome']['errno'], code)
                quarantine = pathlib.Path(result['retirementPath'])
                self.assertTrue(quarantine.exists())
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')
                state, reason, _ = session.retire_registered_native_sources(native.registration, retry_retained=True)
                self.assertEqual(state, 'retired', reason)
                self.assertFalse(quarantine.exists())

    def test_retirement_does_not_hold_registration_lock_during_hash_or_deletion(self):
        for boundary in ('hash', 'delete'):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    (native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'lock-progress')
                    lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                    try:
                        fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                        native.close()
                    finally:
                        os.close(lease)
                    original = session.descriptor_digest if boundary == 'hash' else session.shutil.rmtree
                    observations = []
                    def inspect(*args, **kwargs):
                        with session.NativeRegistration(native.registration) as transaction:
                            observations.append(transaction.current['status'])
                        return original(*args, **kwargs)
                    owner, method = (session, 'descriptor_digest') if boundary == 'hash' else (session.shutil, 'rmtree')
                    with mock.patch.object(owner, method, side_effect=inspect):
                        state, reason, _ = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'retired', reason)
                    self.assertTrue(observations)
                    self.assertEqual(set(observations), {'passed'})

    def test_retirement_preserves_a_registration_published_while_hashing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'preserve-newer')
                lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                try:
                    fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    native.close()
                finally:
                    os.close(lease)
                digest = session.descriptor_digest
                advanced = None
                def advance(descriptor):
                    nonlocal advanced
                    if advanced is None:
                        with session.NativeRegistration(native.registration) as transaction:
                            advanced = dict(transaction.current, fixtureNewer=True)
                            transaction.publish(advanced)
                    return digest(descriptor)
                with mock.patch.object(session, 'descriptor_digest', side_effect=advance):
                    state, _, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred')
                self.assertEqual(json.loads(native.registration.read_text()), advanced)
                self.assertEqual(source.read_bytes(), b'preserve-newer')

    def test_source_ownership_snapshots_after_excluding_the_last_writer(self):
        for phase in (None, 'prepared'):
            for append in (False, True):
                with self.subTest(phase=phase, append=append), self.completed_native_fixture() as (native, source):
                    if phase:
                        owner = json.loads(native.registration.read_text())
                        owner.update(retirementPhase=phase, retirementState=phase,
                                     retirementPath=str(native.root.with_name('.gitx-native-retired-' + 'd' * 32)))
                        session.atomic_json(native.registration, owner)
                    flock = session.fcntl.flock
                    inode = source.stat().st_ino
                    changed = False
                    def finish_writer(descriptor, operation):
                        nonlocal changed
                        if operation == fcntl.LOCK_EX | fcntl.LOCK_NB and os.fstat(descriptor).st_ino == inode and not changed:
                            changed = True
                            if append:
                                with source.open('ab') as stream:
                                    stream.write(b'new bytes')
                            else:
                                info = source.stat()
                                os.utime(source, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
                        return flock(descriptor, operation)
                    with mock.patch.object(session.fcntl, 'flock', side_effect=finish_writer):
                        state, reason, _ = session.retire_registered_native_sources(native.registration)
                    self.assertTrue(changed)
                    self.assertEqual(state, 'retained' if append else 'retired', reason)
                    self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
                    if append:
                        self.assertEqual(source.read_bytes(), b'finalization-\x00\xffnew bytes')

    def test_locked_source_path_replacement_survives_ordinary_and_prepared_retirement(self):
        for phase in (None, 'prepared'):
            with self.subTest(phase=phase), self.completed_native_fixture() as (native, source):
                if phase:
                    owner = json.loads(native.registration.read_text())
                    owner.update(retirementPhase=phase, retirementState=phase,
                                 retirementPath=str(native.root.with_name('.gitx-native-retired-' + 'e' * 32)))
                    session.atomic_json(native.registration, owner)
                flock = session.fcntl.flock
                inode = source.stat().st_ino
                replaced = False
                def replace_before_lock(descriptor, operation):
                    nonlocal replaced
                    if operation == fcntl.LOCK_EX | fcntl.LOCK_NB and os.fstat(descriptor).st_ino == inode and not replaced:
                        replaced = True
                        source.rename(native.root.parent / 'saved-original')
                        source.write_bytes(b'unapproved replacement bytes')
                    return flock(descriptor, operation)
                with mock.patch.object(session.fcntl, 'flock', side_effect=replace_before_lock):
                    state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertTrue(replaced)
                self.assertEqual(state, 'retained', reason)
                self.assertEqual(source.read_bytes(), b'unapproved replacement bytes')
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
                self.assertEqual(owner['retirementOutcome']['origin'], 'source')
                self.assertEqual(owner['retirementOutcome']['errno'], errno.EPERM)

    def test_registration_publish_parses_once_and_detects_external_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'record.json'
            owner = {'kind': 'gitx-native-invocation', 'schemaVersion': 1, 'invocationID': 'fixture',
                     'status': 'running', 'collectionComplete': False, 'files': []}
            session.persist_native_registration(path, owner)
            loads = session.json.loads
            with mock.patch.object(session.json, 'loads', wraps=loads) as parses:
                with session.NativeRegistration(path) as transaction:
                    transaction.publish(dict(owner, marker=True))
                self.assertEqual(parses.call_count, 1)
            print(json.dumps({'registrationPublication': {'jsonParses': parses.call_count}}))
            with session.NativeRegistration(path) as transaction:
                advanced = dict(transaction.current, external=True)
                session.atomic_json(path, advanced)
                with self.assertRaises(session.NativeRegistrationChanged):
                    transaction.publish(dict(transaction.current, external=False))
            self.assertEqual(json.loads(path.read_text()), advanced)

    def test_registered_retirement_selects_its_location_once(self):
        with self.completed_native_fixture() as (native, _):
            with mock.patch.object(session, 'native_retirement_location', wraps=session.native_retirement_location) as select:
                state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(select.call_count, 1)

    def test_handoff_replacement_during_authorization_is_not_removed(self):
        with self.completed_native_fixture() as (native, _):
            completion = session.native_completion_path(native.registration)
            envelope = completion.read_bytes()
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')
            completion.write_bytes(envelope)
            audit = native.registration.read_bytes()
            @contextlib.contextmanager
            def replace_during_authorization():
                session.atomic_json(completion, json.loads(envelope))
                yield
            outcome = session.cleanup_native_completion(native.registration, json.loads(audit), authorize=replace_during_authorization)
            self.assertEqual(outcome.state, 'deferred')
            self.assertTrue(completion.exists())
            self.assertEqual(native.registration.read_bytes(), audit)

    def test_handoff_validation_precedes_full_authorization(self):
        for kind in ('absent', 'malformed', 'symlink'):
            with self.subTest(kind=kind), self.completed_native_fixture() as (native, _):
                completion = session.native_completion_path(native.registration)
                envelope = completion.read_bytes()
                state, reason, owner = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                if kind == 'malformed':
                    completion.write_bytes(b'{bad')
                elif kind == 'symlink':
                    target = completion.with_name('foreign')
                    target.write_bytes(envelope)
                    completion.symlink_to(target)
                @contextlib.contextmanager
                def forbid_expensive_authorization():
                    self.fail('Read-only refusal or absence required a full authorization')
                    yield
                outcome = session.cleanup_native_completion(native.registration, owner, authorize=forbid_expensive_authorization)
                self.assertEqual(outcome.state, 'absent' if kind == 'absent' else 'retained')

    def test_registration_transactions_release_and_preserve_completed_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'NativeSources' / 'invocation.json'
            running = {'kind': 'gitx-native-invocation', 'schemaVersion': 1,
                       'invocationID': 'invocation', 'status': 'running', 'collectionComplete': False}
            session.persist_native_registration(path, running)
            with session.NativeRegistration(path) as first:
                self.assertEqual(first.current, running)
                completed = dict(running, status='passed', collectionComplete=True)
                first.publish(completed)
            with session.NativeRegistration(path) as following:
                self.assertEqual(following.current, completed)
                with self.assertRaises(session.NativeRegistrationChanged):
                    following.publish(running)
            self.assertEqual(json.loads(path.read_text()), completed)

    def test_completion_handoff_is_exclusive_and_keeps_the_final_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            registration = pathlib.Path(directory) / 'invocation.json'
            final = {'invocationID': 'invocation', 'status': 'passed', 'collectionComplete': True,
                     'files': [{'name': 'GitX-42-a.stderr.log', 'bytes': 7, 'sha256': 'fixture'}]}
            session.publish_native_completion(registration, final)
            path = session.native_completion_path(registration)
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                session.publish_native_completion(registration, dict(final, status='failed'))
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(json.loads(original)['owner'], final)
            self.assertEqual(list(path.parent.glob('.pending-*')), [])

    def test_native_capture_metadata_channels_fail_independently(self):
        for failed in ('primary', 'fallback'):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(b'good-binary-\x00\xff')
                    record = self.startup_record(native.invocation, native.session)
                    record.update(event='capture', state='captured', filename=source.name)
                    target = native.stderr_directory if failed == 'primary' else native.progress_directory
                    (target / 'capture-42-a.json').write_text(json.dumps(record))
                    owner, method = (native.progress, 'records') if failed == 'primary' else (native, '_fallback_capture_records')
                    with mock.patch.object(owner, method, side_effect=OSError(errno.EIO, 'fixture-channel')):
                        result = native.close()
                    self.assertEqual(result['captures'], [record])
                    self.assertTrue(result['collectionComplete'])
                    self.assertFalse(result['captureMetadataComplete'])
                    self.assertIn('capture-record-' + failed, result['warnings'])
                    self.assertEqual((native.archive / source.name).read_bytes(), b'good-binary-\x00\xff')

    def test_diagnostics_samples_each_owned_pid_only_once(self):
        with tempfile.TemporaryDirectory() as directory:
            duplicate = '42 42 fixture'
            with mock.patch.object(session, 'owned_processes', return_value=[duplicate]), \
                    mock.patch.object(session.platform, 'system', return_value='Darwin'), \
                    mock.patch.object(session.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
                session.diagnostics(directory, 42, 'unknown-host-startup-timeout', [{'process': duplicate}])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(json.loads((pathlib.Path(directory) / 'blocker.json').read_text())['processes'], [duplicate])

    def test_interruption_never_signals_a_child_reaped_during_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, diagnostics = self.capture_fixture(root)
            reader, writer = os.pipe()
            release_reader, release_writer = os.pipe()
            child, ready = None, False
            spawn, kill = session.subprocess.Popen, session.os.kill
            def remember(*args, **kwargs):
                nonlocal child
                process = spawn(*args, **kwargs)
                if kwargs.get('start_new_session'):
                    child = process
                return process
            def progress():
                nonlocal ready
                if not ready:
                    self.assertTrue(select.select([reader], [], [], 5)[0])
                    os.read(reader, 1)
                    ready = True
                    kill(os.getpid(), signal.SIGINT)
                return False
            def finish_during_diagnostics(*_):
                os.write(release_writer, b'X')
                child.wait(timeout=5)
            def refuse_reaped(pid, signum):
                if child is not None and pid == child.pid and child.returncode is not None:
                    self.fail('A reaped child PID must not be signalled')
                return kill(pid, signum)
            command = 'import os,sys; os.write(int(sys.argv[1]),b"R"); os.read(int(sys.argv[2]),1); sys.exit(65)'
            try:
                with mock.patch.object(session, 'ROOT', root), \
                        mock.patch.object(session.subprocess, 'Popen', side_effect=remember), \
                        mock.patch.object(session.NativeTestDiagnostics, 'poll', side_effect=progress), \
                        mock.patch.object(session, 'diagnostics', side_effect=finish_during_diagnostics), \
                        mock.patch.object(session.os, 'kill', side_effect=refuse_reaped):
                    status = session.supervise([sys.executable, '-c', command, str(writer), str(release_reader)],
                        directory=diagnostics, output_log=output, native_test_root=root / 'cache', pass_fds=(writer, release_reader))
                self.assertEqual(status, 130)
                metadata = json.loads((diagnostics / 'diagnostic-owner.json').read_text())
                self.assertEqual(metadata['childExitCodeBeforeStop'], 65)
                self.assertEqual(metadata['childExitCode'], 65)
            finally:
                if child is not None and child.poll() is None:
                    child.kill(); child.wait(timeout=5)
                for descriptor in (reader, writer, release_reader, release_writer):
                    os.close(descriptor)

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
                    outcome = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                    state, reason = outcome.state, outcome.reason
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
                    outcome = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                    state = outcome.state
                    self.assertEqual(state, 'retained')
                    self.assertTrue(native.root.exists())

    def test_killed_partial_deletion_resumes_from_durable_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            self.capture_fixture(root)
            reader, writer = os.pipe()
            command = r"""
import errno, json, os, pathlib, sys
import workflow_session as session
root = pathlib.Path(sys.argv[1]); session.ROOT = root
native = session.NativeTestDiagnostics(root / 'cache', root / 'artifacts/verification/run/Logs/Native', 'session', ['bundle'], True)
(native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'complete-before-kill')
def interrupted(path):
    (path / 'invocation.lease').unlink()
    os.write(int(sys.argv[2]), (str(native.registration) + '\n').encode())
    os.read(int(sys.argv[3]), 1)
session.shutil.rmtree = interrupted
native.close()
"""
            gate_reader, gate_writer = os.pipe()
            child = subprocess.Popen([sys.executable, '-c', command, str(root), str(writer), str(gate_reader)],
                env=dict(os.environ, PYTHONPATH=str(ROOT / 'scripts')), pass_fds=(writer, gate_reader))
            try:
                self.assertTrue(select.select([reader], [], [], 5)[0], 'deleting checkpoint precedes interruption')
                path = pathlib.Path(os.read(reader, 4096).decode().strip())
                child.kill()
                child.wait(timeout=5)
                with mock.patch.object(session, 'ROOT', root):
                    state, reason, owner = session.retire_registered_native_sources(path)
                self.assertEqual(state, 'retired', reason)
                self.assertEqual((pathlib.Path(owner['artifactDirectory']) / 'GitX-42-a.stderr.log').read_bytes(), b'complete-before-kill')
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                for descriptor in (reader, writer, gate_reader, gate_writer):
                    os.close(descriptor)

    def test_deleting_proof_rejects_replacements_new_contents_and_changed_archives(self):
        for variant in ('root', 'extra', 'symlink', 'archive', 'original'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(b'original')
                    with mock.patch.object(session.shutil, 'rmtree', side_effect=OSError(errno.EIO, 'interrupted')):
                        native.close()
                    owner = json.loads(native.registration.read_text())
                    quarantine = pathlib.Path(owner['retirementPath'])
                    if variant == 'root':
                        quarantine.rename(quarantine.with_name('original-quarantine'))
                        quarantine.mkdir()
                    elif variant == 'extra':
                        (quarantine / 'foreign').write_bytes(b'preserve')
                    elif variant == 'symlink':
                        (quarantine / 'Stderr' / source.name).unlink()
                        (quarantine / 'Stderr' / source.name).symlink_to(native.archive / source.name)
                    elif variant == 'archive':
                        (native.archive / source.name).write_bytes(b'changed')
                    else:
                        native.root.mkdir()
                    state, _, _ = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'retained')
                    self.assertTrue(quarantine.exists())

    def test_partial_native_deletion_resumes_without_removed_controls(self):
        for removed in ('invocation.lease', 'native-owner.json', 'Stderr', 'all'):
            with self.subTest(removed=removed), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(b'archived-\x00\xff')
                    remove = session.shutil.rmtree
                    def partial(path):
                        for name in ('invocation.lease', 'native-owner.json', 'Stderr', 'Progress') if removed == 'all' else (removed,):
                            entry = path / name
                            remove(entry) if entry.is_dir() else entry.unlink()
                        raise OSError(errno.EIO, 'partial-delete')
                    with mock.patch.object(session.shutil, 'rmtree', side_effect=partial):
                        native.close()
                    state, reason, _ = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'retired', reason)
                    self.assertEqual((native.archive / source.name).read_bytes(), b'archived-\x00\xff')

    def test_legacy_deletion_rejects_nonobject_owners_and_recovers_valid_evidence(self):
        for variant in ('valid', 'missing-controls', None, [], 7, 'invalid'):
            with self.subTest(owner=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    contents = b'legacy-archive-\x00\xff'
                    source.write_bytes(contents)
                    with mock.patch.object(session.shutil, 'rmtree', side_effect=OSError(errno.EIO, 'legacy-partial')):
                        native.close()
                    owner = json.loads(native.registration.read_text())
                    owner.pop('deletionProof')
                    session.atomic_json(native.registration, owner)
                    quarantine = pathlib.Path(owner['retirementPath'])
                    if variant == 'missing-controls':
                        for name in ('native-owner.json', 'invocation.lease'):
                            (quarantine / name).unlink()
                    elif variant != 'valid':
                        session.atomic_json(quarantine / 'native-owner.json', variant)
                    state, reason, recovered = session.retire_registered_native_sources(native.registration)
                    if variant in ('valid', 'missing-controls'):
                        self.assertEqual(state, 'retired', reason)
                        self.assertFalse(quarantine.exists())
                    else:
                        self.assertEqual((state, reason), ('retained', 'source-invalid'))
                        self.assertEqual(recovered['retirementOutcome']['operation'], 'upgrade-legacy-deletion-proof')
                        self.assertEqual((quarantine / 'Stderr' / source.name).read_bytes(), contents)
                        self.assertEqual(json.loads((quarantine / 'native-owner.json').read_text()), variant)
                    self.assertEqual((native.archive / source.name).read_bytes(), contents)

    def test_finalization_rejects_malformed_or_redirected_evidence_without_deletion(self):
        for variant in ('envelope', 'source-owner', 'completion-directory'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                _, output, _ = self.capture_fixture(root)
                with mock.patch.object(session, 'ROOT', root):
                    native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                    source = native.stderr_directory / 'GitX-42-a.stderr.log'
                    source.write_bytes(b'protected-finalization')
                    with session.NativeRegistration(native.registration):
                        native.close()
                    completion = session.native_completion_path(native.registration)
                    if variant == 'envelope':
                        session.atomic_json(completion, {'schemaVersion': 1, 'kind': 'gitx-native-completion', 'owner': []})
                    elif variant == 'source-owner':
                        session.atomic_json(native.root / 'native-owner.json', [])
                    else:
                        moved = completion.parent.with_name('saved-completions')
                        completion.parent.rename(moved)
                        completion.parent.symlink_to(moved, target_is_directory=True)
                    # This oracle concerns abandoned malformed evidence, distinct
                    # from the live-producer refusal regression above.
                    with mock.patch.object(session, 'producer_state', return_value='abandoned'):
                        state, reason, owner = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'retained', reason)
                    self.assertEqual(owner['retirementOutcome']['origin'], 'completion')
                    self.assertEqual(source.read_bytes(), b'protected-finalization')

    def test_completed_registration_does_not_depend_on_an_unused_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                (native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'complete')
                lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
                try:
                    fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    native.close()
                    session.atomic_json(session.native_completion_path(native.registration), [])
                finally:
                    os.close(lease)
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)

    def test_invalid_deletion_proof_shape_is_protected_not_an_uncaught_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                (native.stderr_directory / 'GitX-42-a.stderr.log').write_bytes(b'keep')
                with mock.patch.object(session.shutil, 'rmtree', side_effect=OSError(errno.EIO, 'partial')):
                    native.close()
                owner = json.loads(native.registration.read_text())
                owner['deletionProof']['entries'] = []
                session.atomic_json(native.registration, owner)
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retained', reason)
                self.assertTrue(pathlib.Path(owner['retirementPath']).exists())

    def test_finalization_handoff_recovers_a_failed_source_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'final-without-source-checkpoint')
                publish = session.atomic_json
                def fail_source(path, value):
                    if pathlib.Path(path) == native.root / 'native-owner.json' and value.get('status') == 'passed':
                        raise OSError(errno.ENOSPC, 'source-checkpoint-full')
                    return publish(path, value)
                with session.NativeRegistration(native.registration), mock.patch.object(session, 'atomic_json', side_effect=fail_source):
                    result = native.close()
                self.assertTrue(result['collectionComplete'])
                self.assertIn('metadata-retention', result['warnings'])
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertEqual((native.archive / source.name).read_bytes(), b'final-without-source-checkpoint')

    def test_final_completion_survives_registration_lock_contention(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, output, _ = self.capture_fixture(root)
            with mock.patch.object(session, 'ROOT', root):
                native = session.NativeTestDiagnostics(root / 'cache', output.parent / 'Native', 'session', ['bundle'], True)
                source = native.stderr_directory / 'GitX-42-a.stderr.log'
                source.write_bytes(b'completed-under-contention')
                with session.NativeRegistration(native.registration):
                    result = native.close()
                self.assertTrue(result['collectionComplete'])
                state, reason, registered = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertTrue(registered['collectionComplete'])
                self.assertEqual((native.archive / source.name).read_bytes(), b'completed-under-contention')

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
                outcome = session.retire_native_sources(owner, persist=lambda value: session.atomic_json(native.registration, value))
                state = outcome.state
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
                outcome = session.retire_native_sources(owner, persist=replace_after_validation)
                state, reason = outcome.state, outcome.reason
                self.assertEqual((state, reason), ('retained', 'source-changed-during-retirement'))
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
