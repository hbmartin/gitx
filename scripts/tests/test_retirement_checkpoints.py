"""Durable retirement certificates distinguish deletion from namespace changes."""
import errno
import json
import os
import pathlib
import unittest
from unittest import mock

import test_workflow_session as fixtures
import workflow_session as session


class RetirementCheckpointTests(unittest.TestCase):
    def completed(self):
        return fixtures.WorkflowSessionTests().completed_native_fixture()

    def interrupt(self, native, *, final=False):
        if not final:
            with mock.patch.object(session, 'remove_native_quarantine', side_effect=OSError(errno.EIO, 'interrupted removal')):
                result = session.retire_registered_native_sources(native.registration)
        else:
            publish = session.NativeRegistration.publish
            def fail(transaction, value):
                if value.get('retirementState') == 'retired':
                    raise OSError(errno.ENOSPC, 'interrupted final publication')
                return publish(transaction, value)
            with mock.patch.object(session.NativeRegistration, 'publish', new=fail):
                result = session.retire_registered_native_sources(native.registration)
        self.assertEqual(result[0], 'deferred', result[1])
        return json.loads(native.registration.read_text())

    def test_moved_unfinished_parent_or_root_never_retires(self):
        for target in ('parent', 'root'):
            with self.subTest(target=target), self.completed() as (native, source):
                owner = self.interrupt(native)
                quarantine = pathlib.Path(owner['retirementPath'])
                selected = quarantine.parent if target == 'parent' else quarantine
                saved = selected.with_name('moved-' + target)
                selected.rename(saved)
                surviving = saved / quarantine.name if target == 'parent' else saved
                for retry in (False, True):
                    state, reason, _ = session.retire_registered_native_sources(native.registration, retry_retained=retry)
                    self.assertEqual(state, 'retained', reason)
                    self.assertEqual((surviving / 'Stderr' / source.name).read_bytes(), b'finalization-\x00\xff')
                    self.assertTrue(session.native_completion_path(native.registration).exists())

    def test_checkpoints_are_published_in_order_and_bound_to_evidence(self):
        with self.completed() as (native, _):
            writes = []
            publish = session.NativeRegistration.publish
            def observe(transaction, value):
                writes.append(json.loads(json.dumps(value)))
                return publish(transaction, value)
            with mock.patch.object(session.NativeRegistration, 'publish', new=observe):
                state, reason, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            phases = [(item['retirementPhase'], 'retirementValidation' in item, 'retirementCompletion' in item) for item in writes]
            self.assertEqual(phases, [('prepared', False, False), ('deleting', True, False), ('deleting', True, True), ('retired', True, True)])
            for field in ('retirementValidation', 'retirementCompletion'):
                self.assertEqual(after[field]['schemaVersion'], 1)
                self.assertEqual(len(after[field]['evidenceSHA256']), 64)
            self.assertEqual(after['retirementValidation']['evidenceSHA256'], after['retirementCompletion']['evidenceSHA256'])

    def test_loss_before_deleting_publication_cannot_gain_a_validation_checkpoint(self):
        with self.completed() as (native, source):
            rename = session.NativeRetirementDirectories.rename
            def lose(directories, destination):
                rename(directories, destination)
                (destination / 'Stderr' / source.name).unlink()
            with mock.patch.object(session.NativeRetirementDirectories, 'rename', new=lose):
                state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retained')
            self.assertNotIn('retirementValidation', after)
            self.assertNotEqual(after.get('retirementPhase'), 'deleting')
            self.assertEqual(session.retire_registered_native_sources(native.registration, retry_retained=True)[0], 'retained')

    def test_concurrent_approved_descendant_removal_is_idempotent(self):
        for boundary in ('stat', 'unlink', 'rmdir'):
            with self.subTest(boundary=boundary), self.completed() as (native, source):
                remove = session.remove_native_quarantine
                injected = []
                def removing(*args, **kwargs):
                    unlink, inspect, rmdir = os.unlink, os.stat, os.rmdir
                    def vanished(name, *positional, **options):
                        matches = str(name) == ('Stderr' if boundary == 'rmdir' else source.name)
                        function = {'stat': inspect, 'unlink': unlink, 'rmdir': rmdir}[boundary]
                        if matches and options.get('dir_fd') is not None and not injected:
                            injected.append(True)
                            (rmdir if boundary == 'rmdir' else unlink)(name, dir_fd=options['dir_fd'])
                        return function(name, *positional, **options)
                    with mock.patch.object(session.os, boundary, side_effect=vanished):
                        return remove(*args, **kwargs)
                with mock.patch.object(session, 'remove_native_quarantine', side_effect=removing):
                    state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertTrue(injected)
                self.assertEqual(state, 'retired', reason)

    def test_completed_deletion_recovers_missing_or_recreated_parent(self):
        for recreate in (False, True):
            with self.subTest(recreate=recreate), self.completed() as (native, _):
                owner = self.interrupt(native, final=True)
                self.assertIn('retirementCompletion', owner)
                native.root.parent.rmdir()
                if recreate:
                    native.root.parent.mkdir()
                with mock.patch.object(session.os, 'fsync', wraps=os.fsync) as flush:
                    state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertFalse(session.native_completion_path(native.registration).exists())

    def test_legacy_partial_or_absent_tree_stays_protected_on_explicit_retry(self):
        for contents in ('intact', 'partial', 'absent'):
            with self.subTest(contents=contents), self.completed() as (native, source):
                owner = self.interrupt(native)
                owner.pop('retirementValidation', None)
                owner.pop('retirementCompletion', None)
                quarantine = pathlib.Path(owner['retirementPath'])
                if contents == 'partial':
                    (quarantine / 'Stderr' / source.name).unlink()
                elif contents == 'absent':
                    session.shutil.rmtree(quarantine)
                session.atomic_json(native.registration, owner)
                for retry in (False, True):
                    state, reason, _ = session.retire_registered_native_sources(native.registration, retry_retained=retry)
                    self.assertEqual(state, 'retired' if contents == 'intact' else 'retained', reason)
                    self.assertEqual(session.native_completion_path(native.registration).exists(), contents != 'intact')

    def test_unknown_special_entries_keep_inventory_diagnostic(self):
        for kind in ('symlink', 'fifo'):
            with self.subTest(kind=kind), self.completed() as (native, source):
                extra = native.root / 'unexpected'
                if kind == 'symlink':
                    extra.symlink_to(native.archive, target_is_directory=True)
                else:
                    os.mkfifo(extra, 0o600)
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual((state, reason), ('retained', 'unexpected-source-content'))
                self.assertEqual(source.read_bytes(), b'finalization-\x00\xff')

    def test_completion_publication_failures_preserve_phase_errno_and_handoff(self):
        for code in (errno.EACCES, errno.EBUSY):
            with self.subTest(errno=code), self.completed() as (native, _):
                publish = session.NativeRegistration.publish
                def refuse(transaction, value):
                    if 'retirementCompletion' in value:
                        raise OSError(code, 'completion publisher refused')
                    return publish(transaction, value)
                with mock.patch.object(session.NativeRegistration, 'publish', new=refuse):
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                outcome = after['retirementOutcome']
                self.assertEqual((outcome['origin'], outcome['operation'], outcome['errno']),
                                 ('registration', 'publish-deletion-completion', code))
                durable = json.loads(native.registration.read_text())
                self.assertIn('retirementValidation', durable)
                self.assertNotIn('retirementCompletion', durable)
                self.assertTrue(session.native_completion_path(native.registration).exists())
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')

    def test_completion_checkpoint_requires_real_removal_and_pinned_parent_flush(self):
        for boundary in ('remove', 'flush'):
            with self.subTest(boundary=boundary), self.completed() as (native, _):
                if boundary == 'remove':
                    context = mock.patch.object(session, 'remove_native_quarantine', return_value=None)
                else:
                    flush = os.fsync
                    parent = native.root.parent.stat().st_ino
                    def refused(descriptor):
                        if os.fstat(descriptor).st_ino == parent and not list(native.root.parent.iterdir()):
                            raise OSError(errno.EIO, 'pinned parent flush refused')
                        return flush(descriptor)
                    context = mock.patch.object(session.os, 'fsync', side_effect=refused)
                with context:
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertNotIn('retirementCompletion', json.loads(native.registration.read_text()))
                self.assertTrue(session.native_completion_path(native.registration).exists())

    def test_completion_checkpoint_binds_manifest_identity_and_path(self):
        for field in ('retirementPath', 'retirementParentIdentity', 'directoryIdentity', 'files', 'deletionProof', 'retirementValidation', 'retirementCompletion'):
            with self.subTest(field=field), self.completed() as (native, _):
                owner = self.interrupt(native, final=True)
                if field == 'retirementPath':
                    owner[field] = str(pathlib.Path(owner[field]).with_name('.gitx-native-retired-' + 'f' * 32))
                elif field in ('retirementParentIdentity', 'directoryIdentity'):
                    owner[field][1] += 1
                elif field == 'files':
                    owner[field][0]['sha256'] = '0' * 64
                elif field == 'deletionProof':
                    owner[field]['entries'] = {}
                else:
                    owner[field] = {'schemaVersion': True, 'evidenceSHA256': '0' * 64}
                session.atomic_json(native.registration, owner)
                state, reason, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retained', reason)
                self.assertTrue(session.native_completion_path(native.registration).exists())

    def test_checkpoint_publications_cannot_drop_or_change_certificates(self):
        with self.completed() as (native, _):
            self.interrupt(native, final=True)
            before = native.registration.read_bytes()
            for field in ('retirementValidation', 'retirementCompletion'):
                for change in ('drop', 'replace', 'manifest'):
                    with self.subTest(field=field, change=change), session.NativeRegistration(native.registration) as transaction:
                        value = json.loads(before)
                        if change == 'drop':
                            value.pop(field)
                        elif change == 'replace':
                            value[field]['evidenceSHA256'] = '0' * 64
                        else:
                            value['files'][0]['sha256'] = '0' * 64
                        with self.assertRaises(session.NativeRegistrationChanged):
                            transaction.publish(value)
                    self.assertEqual(native.registration.read_bytes(), before)

    def test_recovery_uses_one_final_surviving_directory_flush(self):
        with self.completed() as (native, _):
            self.interrupt(native, final=True)
            native.root.parent.rmdir()
            ancestor = native.root.parent.parent.stat().st_ino
            flushed = []
            flush = os.fsync
            def observe(descriptor):
                if os.fstat(descriptor).st_ino == ancestor:
                    flushed.append(descriptor)
                return flush(descriptor)
            with mock.patch.object(session.os, 'fsync', side_effect=observe):
                state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(len(flushed), 1)

    def test_recovery_metadata_and_flush_errors_defer_without_sticky_registration(self):
        for boundary in ('inspect', 'flush'):
            for code in (errno.EACCES, errno.EIO):
                with self.subTest(boundary=boundary, errno=code), self.completed() as (native, _):
                    self.interrupt(native, final=True)
                    native.root.parent.rmdir()
                    before = native.registration.read_bytes()
                    ancestor = native.root.parent.parent.stat().st_ino
                    if boundary == 'inspect':
                        inspect = session.native_path_absent
                        def unavailable(path):
                            if pathlib.Path(path) == native.root:
                                raise OSError(code, 'absence inspection refused')
                            return inspect(path)
                        context = mock.patch.object(session, 'native_path_absent', side_effect=unavailable)
                    else:
                        flush = os.fsync
                        def unavailable(descriptor):
                            if os.fstat(descriptor).st_ino == ancestor:
                                raise OSError(code, 'absence flush refused')
                            return flush(descriptor)
                        context = mock.patch.object(session.os, 'fsync', side_effect=unavailable)
                    with context:
                        state, reason, _ = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'deferred', reason)
                    self.assertEqual(native.registration.read_bytes(), before)
                    self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_root_owned_surviving_ancestor_can_establish_absence(self):
        with self.completed() as (native, _):
            owner = self.interrupt(native, final=True)
            # Isolate the durability policy using a nonexistent child of a real
            # root-owned ancestor; no source deletion or system mutation occurs.
            original = pathlib.Path('/private/tmp') / ('gitx-absent-' + native.invocation) / 'cache' / native.root.name
            prepared = original.with_name(pathlib.Path(owner['retirementPath']).name)
            owner.update(sourceDirectory=str(original), retirementPath=str(prepared))
            certificate = session.native_retirement_checkpoint(owner)
            owner.update(retirementValidation=certificate, retirementCompletion=certificate)
            location = session.NativeRetirementLocation(original, prepared, tuple(owner['retirementParentIdentity']),
                                                        'deleting', True, tuple(owner['directoryIdentity']), prepared)
            self.assertEqual(pathlib.Path('/private/tmp').stat().st_uid, 0)
            with mock.patch.object(session.os, 'fsync') as flush:
                session.sync_native_absence(location, owner)
            flush.assert_called_once()

    def test_actual_atomic_publication_faults_keep_production_phase_and_errno(self):
        for phase in ('publish-prepared', 'publish-deleting', 'publish-deletion-completion', 'promote-completion'):
            with self.subTest(phase=phase), self.completed() as (native, _):
                if phase == 'promote-completion':
                    owner = json.loads(native.registration.read_text())
                    owner.update(status='running', collectionComplete=False, files=[])
                    session.atomic_json(native.registration, owner)
                atomic = session.atomic_json
                def fail(path, value):
                    if pathlib.Path(path) == native.registration:
                        selected = ('publish-deletion-completion' if 'retirementCompletion' in value else
                                    'publish-deleting' if value.get('retirementPhase') == 'deleting' else
                                    'publish-prepared' if value.get('retirementPhase') == 'prepared' else 'promote-completion')
                        if selected == phase:
                            raise OSError(errno.ENOSPC, 'actual atomic publication refused')
                    return atomic(path, value)
                with mock.patch.object(session, 'atomic_json', side_effect=fail):
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(after['retirementOutcome']['operation'], phase)
                self.assertEqual(after['retirementOutcome']['errno'], errno.ENOSPC)
                self.assertTrue(session.native_completion_path(native.registration).exists())

    def test_empty_replacement_at_final_rmdir_cannot_certify_relocated_root(self):
        with self.completed() as (native, _):
            rmdir = os.rmdir
            moved = []
            def replace(name, *args, **kwargs):
                if str(name).startswith('.gitx-native-retired-') and not moved:
                    quarantine = native.root.parent / name
                    saved = quarantine.with_name('relocated-approved-root')
                    quarantine.rename(saved)
                    quarantine.mkdir()
                    moved.append(saved)
                return rmdir(name, *args, **kwargs)
            with mock.patch.object(session.os, 'rmdir', side_effect=replace):
                state, reason, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retained', reason)
            self.assertTrue(moved[0].is_dir())
            self.assertNotIn('retirementCompletion', after)
            self.assertTrue(session.native_completion_path(native.registration).exists())
