"""Content retirement remains durable independently of empty-container cleanup."""
import errno
import json
import os
import pathlib
import unittest
from unittest import mock

import test_workflow_session as fixtures
import workflow_session as session


class ContentRetirementTests(unittest.TestCase):
    def completed(self):
        return fixtures.WorkflowSessionTests().completed_native_fixture()

    def contents_waiting(self, native):
        publish = session.NativeRegistration.publish
        def refuse(transaction, value):
            if value.get('retirementState') == 'retired':
                raise OSError(errno.ENOSPC, 'terminal publication refused')
            return publish(transaction, value)
        with mock.patch.object(session.NativeRegistration, 'publish', new=refuse):
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'deferred')
        owner = json.loads(native.registration.read_text())
        self.assertIn('retirementContents', owner)
        return owner

    def container_waiting(self, native):
        with mock.patch.object(session.NativeRetirementDirectories, 'remove_empty', side_effect=OSError(errno.EIO, 'retry container')):
            state, reason, owner = session.retire_registered_native_sources(native.registration)
        self.assertEqual(state, 'retired', reason)
        self.assertEqual(owner['containerCleanup']['state'], 'deferred')
        return owner

    def test_content_certificate_and_terminal_audit_precede_final_rmdir(self):
        with self.completed() as (native, source):
            remove = session.os.rmdir
            observed = []
            def inspect(name, *args, **kwargs):
                if str(name).startswith('.gitx-native-retired-'):
                    owner = json.loads(native.registration.read_text())
                    self.assertIn('retirementContents', owner)
                    self.assertEqual(owner['retirementState'], 'retired')
                    observed.append(owner)
                return remove(name, *args, **kwargs)
            with mock.patch.object(session.os, 'rmdir', side_effect=inspect):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(len(observed), 1)
            self.assertEqual(owner['containerCleanup']['state'], 'removed')
            self.assertFalse(native.root.exists())
            self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_parent_sync_failure_cannot_undo_content_retirement(self):
        with self.completed() as (native, _):
            sync = session.os.fsync
            parent = session.native_directory_identity(native.root.parent)
            def fail_after_removal(fd):
                info = os.fstat(fd)
                if [info.st_dev, info.st_ino] == parent and not list(native.root.parent.iterdir()):
                    raise OSError(errno.EIO, 'container sync failed')
                return sync(fd)
            with mock.patch.object(session.os, 'fsync', side_effect=fail_after_removal):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(owner['containerCleanup']['state'], 'deferred')
            self.assertIn('retirementContents', json.loads(native.registration.read_text()))
            self.assertFalse(session.native_completion_path(native.registration).exists())
            state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired')
            self.assertEqual(after['containerCleanup']['reason'], 'empty-container-location-unproven')

    def test_rejected_content_publication_keeps_an_empty_root_for_retry(self):
        with self.completed() as (native, _):
            atomic = session.atomic_json
            def fail(path, value):
                if pathlib.Path(path) == native.registration and 'retirementContents' in value:
                    raise OSError(errno.ENOSPC, 'content checkpoint refused')
                return atomic(path, value)
            with mock.patch.object(session, 'atomic_json', side_effect=fail):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'deferred', reason)
            self.assertEqual(owner['retirementOutcome']['operation'], 'publish-retirement-contents')
            quarantine = pathlib.Path(owner['retirementPath'])
            self.assertTrue(quarantine.is_dir())
            self.assertEqual(list(quarantine.iterdir()), [])
            self.assertNotIn('retirementContents', json.loads(native.registration.read_text()))
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_archive_timestamp_change_after_draining_recovers_on_explicit_retry(self):
        with self.completed() as (native, source):
            remove = session.remove_native_quarantine
            def touch(*args, **kwargs):
                remove(*args, **kwargs)
                path = native.archive / source.name
                info = path.stat()
                os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
            with mock.patch.object(session, 'remove_native_quarantine', side_effect=touch):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual((state, reason), ('retained', 'archive-invalid'))
            self.assertTrue(pathlib.Path(owner['retirementPath']).is_dir())
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')
            self.assertEqual(session.retire_registered_native_sources(native.registration, retry_retained=True)[0], 'retired')

    def test_container_permission_failure_preserves_audit_and_handoff_cleanup(self):
        with self.completed() as (native, _):
            remove = session.os.rmdir
            def refuse(name, *args, **kwargs):
                if str(name).startswith('.gitx-native-retired-'):
                    raise PermissionError(errno.EACCES, 'container is inaccessible')
                return remove(name, *args, **kwargs)
            with mock.patch.object(session.os, 'rmdir', side_effect=refuse):
                state, reason, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(owner['containerCleanup']['state'], 'deferred')
            self.assertFalse(session.native_completion_path(native.registration).exists())
            before = native.registration.read_bytes()
            self.assertEqual(session.retire_registered_native_sources(native.registration)[2]['containerCleanup']['state'], 'removed')
            self.assertEqual(native.registration.read_bytes(), before)

    def test_missing_journal_is_discovered_after_the_handoff_has_gone(self):
        with self.completed() as (native, _):
            self.container_waiting(native)
            session.native_container_path(native.registration).unlink()
            self.assertFalse(session.native_completion_path(native.registration).exists())
            self.assertEqual([path for path, _ in session.registered_native_containers(session.ROOT)], [native.registration])
            before = native.registration.read_bytes()
            state, _, owner = session.retire_registered_native_sources(native.registration)
            self.assertEqual((state, owner['containerCleanup']['state']), ('retired', 'removed'))
            self.assertEqual(session.registered_native_containers(session.ROOT), [])
            self.assertEqual(native.registration.read_bytes(), before)

    def test_late_parent_or_root_moves_only_retain_container_cleanup(self):
        for target in ('root', 'parent'):
            with self.subTest(target=target), self.completed() as (native, source):
                owner = self.contents_waiting(native)
                root = pathlib.Path(owner['retirementPath'])
                selected = root if target == 'root' else root.parent
                saved = selected.with_name('moved-' + target)
                selected.rename(saved)
                state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertEqual(after['containerCleanup']['reason'], 'empty-container-location-unproven')
                self.assertFalse(session.native_completion_path(native.registration).exists())
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
                surviving = saved if target == 'root' else saved / root.name
                self.assertEqual(list(surviving.iterdir()), [])

    def test_content_recovery_after_archive_repair_does_not_require_the_root(self):
        with self.completed() as (native, source):
            owner = self.contents_waiting(native)
            root = pathlib.Path(owner['retirementPath'])
            root.rmdir()
            archived = native.archive / source.name
            original = archived.read_bytes()
            archived.write_bytes(b'changed archive')
            state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual((state, reason), ('retained', 'archive-invalid'))
            archived.write_bytes(original)
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retained')
            state, reason, after = session.retire_registered_native_sources(native.registration, retry_retained=True)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(after['containerCleanup']['reason'], 'empty-container-location-unproven')
            self.assertFalse(session.native_completion_path(native.registration).exists())

    def test_retained_container_requires_explicit_retry_after_repair(self):
        with self.completed() as (native, _):
            owner = self.container_waiting(native)
            root = pathlib.Path(owner['retirementPath'])
            unexpected = root / 'unexpected'
            unexpected.write_bytes(b'preserve this')
            state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual((state, after['containerCleanup']['state']), ('retired', 'retained'))
            self.assertEqual(after['containerCleanup']['entry'], 'unexpected')
            unexpected.unlink()
            before = native.registration.read_bytes()
            self.assertEqual(session.retire_registered_native_sources(native.registration)[2]['containerCleanup']['state'], 'retained')
            self.assertTrue(root.is_dir())
            self.assertEqual(session.retire_registered_native_sources(native.registration, retry_retained=True)[2]['containerCleanup']['state'], 'removed')
            self.assertEqual(native.registration.read_bytes(), before)

    def test_directory_and_symlink_replacements_remain_untouched_after_content_retirement(self):
        for target in ('root', 'parent'):
            for kind in ('directory', 'symlink'):
                with self.subTest(target=target, kind=kind), self.completed() as (native, _):
                    owner = self.container_waiting(native)
                    root = pathlib.Path(owner['retirementPath'])
                    selected = root if target == 'root' else root.parent
                    saved = selected.with_name('approved-saved')
                    selected.rename(saved)
                    foreign = saved.parent / 'foreign-container'
                    foreign.mkdir()
                    replacement = foreign if target == 'root' else foreign / root.name
                    if target == 'parent':
                        replacement.mkdir()
                    sentinel = replacement / 'keep'
                    sentinel.write_bytes(b'foreign bytes')
                    if kind == 'symlink':
                        selected.symlink_to(foreign, target_is_directory=True)
                    else:
                        selected.mkdir()
                        replacement = selected if target == 'root' else selected / root.name
                        if target == 'parent':
                            replacement.mkdir()
                        (replacement / 'keep').write_bytes(b'foreign bytes')
                    before = native.registration.read_bytes()
                    state, _, after = session.retire_registered_native_sources(native.registration)
                    self.assertEqual(state, 'retired')
                    self.assertEqual(after['containerCleanup']['state'], 'retained')
                    self.assertEqual(sentinel.read_bytes(), b'foreign bytes')
                    self.assertEqual(native.registration.read_bytes(), before)
                    if kind == 'directory':
                        self.assertEqual((replacement / 'keep').read_bytes(), b'foreign bytes')

    def test_invalid_journals_are_protected_and_never_overwritten(self):
        for variant in ('json', 'array', 'kind', 'version', 'invocation', 'digest', 'outcome', 'errno', 'symlink'):
            with self.subTest(variant=variant), self.completed() as (native, _):
                self.container_waiting(native)
                path = session.native_container_path(native.registration)
                value = json.loads(path.read_text())
                if variant == 'json':
                    path.write_bytes(b'{broken')
                elif variant == 'symlink':
                    foreign = path.with_name('foreign')
                    path.rename(foreign)
                    path.symlink_to(foreign)
                else:
                    if variant == 'array':
                        value = []
                    elif variant == 'outcome':
                        value['outcome'] = {'state': 'removed'}
                    elif variant == 'errno':
                        value['outcome']['errno'] = True
                    else:
                        key = {'kind': 'kind', 'version': 'schemaVersion', 'invocation': 'invocationID', 'digest': 'evidenceSHA256'}[variant]
                        value[key] = True if variant == 'version' else 'invalid'
                    session.atomic_json(path, value)
                before = path.read_bytes()
                state, _, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired')
                self.assertEqual(after['containerCleanup']['state'], 'retained')
                self.assertEqual(path.read_bytes(), before)
                self.assertTrue(pathlib.Path(after['retirementPath']).is_dir())

    def test_redirected_journal_directory_cannot_hide_pending_cleanup(self):
        with self.completed() as (native, _):
            self.container_waiting(native)
            path = session.native_container_path(native.registration)
            saved = path.parent.with_name('saved-containers')
            path.parent.rename(saved)
            value = json.loads((saved / path.name).read_text())
            value['outcome']['state'] = 'removed'
            session.atomic_json(saved / path.name, value)
            path.parent.symlink_to(saved, target_is_directory=True)
            before = path.read_bytes()
            self.assertEqual([item for item, _ in session.registered_native_containers(session.ROOT)], [native.registration])
            state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired')
            self.assertEqual(after['containerCleanup']['state'], 'retained')
            self.assertEqual(path.read_bytes(), before)

    def test_file_replacing_container_parent_is_a_retained_conflict(self):
        with self.completed() as (native, _):
            owner = self.container_waiting(native)
            parent = pathlib.Path(owner['retirementPath']).parent
            saved = parent.with_name('saved-parent')
            parent.rename(saved)
            parent.write_bytes(b'foreign parent')
            state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired')
            self.assertEqual(after['containerCleanup']['state'], 'retained')
            self.assertEqual(after['containerCleanup']['errno'], errno.ENOTDIR)
            self.assertEqual(parent.read_bytes(), b'foreign parent')

    def test_disappearance_during_child_enumeration_is_certified_progress(self):
        with self.completed() as (native, _):
            remove, enumerate_directory = session.remove_native_quarantine, session.os.listdir
            intercepted = []
            def draining(root, owner, *, directories):
                def enumerate_child(fd):
                    info = os.fstat(fd)
                    expected = owner['deletionProof']['entries']['Stderr']
                    if [info.st_dev, info.st_ino] == expected[:2] and not intercepted:
                        intercepted.append(True)
                        session.shutil.rmtree(pathlib.Path(root) / 'Stderr')
                        raise FileNotFoundError(errno.ENOENT, 'approved child disappeared')
                    return enumerate_directory(fd)
                with mock.patch.object(session.os, 'listdir', side_effect=enumerate_child):
                    return remove(root, owner, directories=directories)
            with mock.patch.object(session, 'remove_native_quarantine', side_effect=draining):
                state, reason, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertTrue(intercepted)
            self.assertEqual(after['containerCleanup']['state'], 'removed')

    def test_content_checkpoint_survives_atomic_replacement_before_parent_sync_failure(self):
        with self.completed() as (native, _):
            sync = session.sync_native_directory
            failed = []
            def refuse(path):
                value = json.loads(native.registration.read_text())
                if pathlib.Path(path) == native.registration.parent and 'retirementContents' in value and not failed:
                    failed.append(True)
                    raise OSError(errno.EIO, 'checkpoint directory sync failed after replacement')
                return sync(path)
            with mock.patch.object(session, 'sync_native_directory', side_effect=refuse):
                state, reason, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'deferred', reason)
            self.assertEqual(after['retirementOutcome']['operation'], 'publish-retirement-contents')
            self.assertIn('retirementContents', json.loads(native.registration.read_text()))
            self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_journal_publication_failure_does_not_reopen_content_retirement(self):
        for boundary in ('before-replace', 'after-replace'):
            with self.subTest(boundary=boundary), self.completed() as (native, _):
                atomic = session.atomic_json
                journal = session.native_container_path(native.registration)
                def refuse(path, value):
                    if pathlib.Path(path) == journal:
                        if boundary == 'after-replace':
                            atomic(path, value)
                        raise OSError(errno.ENOSPC, 'journal publication failed')
                    return atomic(path, value)
                with mock.patch.object(session, 'atomic_json', side_effect=refuse):
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired', reason)
                self.assertEqual(after['containerCleanup']['operation'], 'publish-container-outcome')
                self.assertEqual(after['containerCleanup']['errno'], errno.ENOSPC)
                before = native.registration.read_bytes()
                state, _, retry = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retired')
                self.assertEqual(retry['containerCleanup']['state'], 'retained' if boundary == 'before-replace' else 'removed')
                self.assertEqual(native.registration.read_bytes(), before)

    def test_content_checkpoint_cannot_be_dropped_or_rebound_and_digests_are_shared(self):
        with self.completed() as (native, _):
            self.contents_waiting(native)
            before = native.registration.read_bytes()
            for variant in ('drop', 'digest', 'manifest'):
                with self.subTest(variant=variant), session.NativeRegistration(native.registration) as transaction:
                    value = json.loads(before)
                    if variant == 'drop':
                        value.pop('retirementContents')
                    elif variant == 'digest':
                        value['retirementContents']['evidenceSHA256'] = '0' * 64
                    else:
                        value['files'][0]['sha256'] = '0' * 64
                    with self.assertRaises(session.NativeRegistrationChanged):
                        transaction.publish(value)
                self.assertEqual(native.registration.read_bytes(), before)
            with session.NativeRegistration(native.registration) as transaction:
                with mock.patch.object(session, 'native_retirement_checkpoint', wraps=session.native_retirement_checkpoint) as checkpoint:
                    transaction.publish(dict(transaction.current, retirementReason='metadata-only change'))
                self.assertEqual(checkpoint.call_count, 2)

    def test_root_flush_failure_leaves_a_linked_empty_root_and_retries(self):
        for code in (errno.EACCES, errno.EIO):
            with self.subTest(errno=code), self.completed() as (native, _):
                identity = session.native_directory_identity(native.root)
                sync = session.os.fsync
                def refuse(fd):
                    info = os.fstat(fd)
                    if [info.st_dev, info.st_ino] == identity:
                        raise OSError(code, 'root flush refused')
                    return sync(fd)
                with mock.patch.object(session.os, 'fsync', side_effect=refuse):
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(after['retirementOutcome']['operation'], 'sync-retirement-root')
                self.assertNotIn('retirementContents', json.loads(native.registration.read_text()))
                self.assertEqual(list(pathlib.Path(after['retirementPath']).iterdir()), [])
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')

    def test_terminal_publication_interruptions_preserve_content_proof_and_discovery(self):
        for boundary in ('before-replace', 'after-replace'):
            with self.subTest(boundary=boundary), self.completed() as (native, _):
                atomic = session.atomic_json
                def refuse(path, value):
                    if pathlib.Path(path) == native.registration and value.get('retirementState') == 'retired':
                        if boundary == 'after-replace':
                            atomic(path, value)
                        raise OSError(errno.ENOSPC, 'terminal publication interrupted')
                    return atomic(path, value)
                with mock.patch.object(session, 'atomic_json', side_effect=refuse):
                    state, reason, after = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'deferred', reason)
                self.assertEqual(after['retirementOutcome']['operation'], 'publish-retirement-outcome')
                durable = json.loads(native.registration.read_text())
                self.assertIn('retirementContents', durable)
                self.assertEqual(list(pathlib.Path(durable['retirementPath']).iterdir()), [])
                discovered = session.registered_native_sources(session.ROOT) if boundary == 'before-replace' else session.registered_native_containers(session.ROOT)
                self.assertEqual([path for path, _ in discovered], [native.registration])
                self.assertEqual(session.retire_registered_native_sources(native.registration)[2]['containerCleanup']['state'], 'removed')

    def test_corrupt_content_certificates_never_authorize_container_deletion(self):
        for variant in ('digest', 'version', 'proof', 'manifest'):
            with self.subTest(variant=variant), self.completed() as (native, source):
                owner = self.contents_waiting(native)
                if variant == 'digest':
                    owner['retirementContents']['evidenceSHA256'] = '0' * 64
                elif variant == 'version':
                    owner['retirementContents']['schemaVersion'] = True
                elif variant == 'proof':
                    owner['deletionProof']['entries'] = {}
                else:
                    owner['files'][0]['sha256'] = '0' * 64
                session.atomic_json(native.registration, owner)
                root = pathlib.Path(owner['retirementPath'])
                state, _, _ = session.retire_registered_native_sources(native.registration)
                self.assertEqual(state, 'retained')
                self.assertTrue(root.is_dir())
                self.assertTrue(session.native_completion_path(native.registration).exists())
                self.assertEqual((native.archive / source.name).read_bytes(), b'finalization-\x00\xff')
                self.assertEqual(session.retire_registered_native_sources(native.registration, retry_retained=True)[0], 'retained')

    def test_container_authorization_refusal_changes_neither_audit_nor_journal(self):
        import contextlib
        with self.completed() as (native, _):
            self.container_waiting(native)
            journal = session.native_container_path(native.registration)
            before = (native.registration.read_bytes(), journal.read_bytes())
            @contextlib.contextmanager
            def refuse():
                raise session.NativeRetirementDeferred('newer commit queued')
                yield
            state, _, after = session.retire_registered_native_sources(native.registration, authorize=refuse)
            self.assertEqual(state, 'retired')
            self.assertEqual(after['containerCleanup']['reason'], 'newer commit queued')
            self.assertEqual((native.registration.read_bytes(), journal.read_bytes()), before)

    def test_legacy_admission_shares_its_inventory_and_reads_the_owner_once(self):
        with self.completed() as (native, _):
            with mock.patch.object(session, 'remove_native_quarantine', side_effect=OSError(errno.EIO, 'legacy deletion interrupted')):
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'deferred')
            owner = json.loads(native.registration.read_text())
            owner.pop('retirementValidation')
            session.atomic_json(native.registration, owner)
            opened = session.open_owned_regular
            manifests = []
            def opening(path, *args, **kwargs):
                if pathlib.Path(path).name == 'native-owner.json':
                    manifests.append(path)
                return opened(path, *args, **kwargs)
            with mock.patch.object(session, 'open_owned_regular', side_effect=opening), \
                    mock.patch.object(session, 'native_deletion_proof', wraps=session.native_deletion_proof) as proof, \
                    mock.patch.object(session, 'validate_native_deletion', wraps=session.validate_native_deletion) as inventory:
                state, reason, _ = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retired', reason)
            self.assertEqual(len(manifests), 1)
            self.assertEqual(proof.call_count, 1)
            self.assertEqual([call.kwargs['allow_missing'] for call in inventory.call_args_list], [False, True])

    def test_legacy_inventory_cannot_silently_replace_a_changed_old_proof(self):
        with self.completed() as (native, source):
            with mock.patch.object(session, 'remove_native_quarantine', side_effect=OSError(errno.EIO, 'legacy deletion interrupted')):
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'deferred')
            owner = json.loads(native.registration.read_text())
            owner.pop('retirementValidation')
            owner['deletionProof']['entries']['Stderr/' + source.name][-1] += 1000000
            session.atomic_json(native.registration, owner)
            state, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(state, 'retained')
            self.assertNotIn('retirementContents', after)
            self.assertEqual((pathlib.Path(owner['retirementPath']) / 'Stderr' / source.name).read_bytes(), b'finalization-\x00\xff')

    def test_journal_publication_flushes_its_surviving_parent(self):
        with self.completed() as (native, _):
            publish = session.NativeContainerJournal.publish
            observed = []
            def inspect(journal, outcome):
                with mock.patch.object(session, 'sync_native_directory', wraps=session.sync_native_directory) as sync:
                    result = publish(journal, outcome)
                observed.extend(call.args[0] for call in sync.call_args_list)
                return result
            with mock.patch.object(session.NativeContainerJournal, 'publish', new=inspect):
                self.assertEqual(session.retire_registered_native_sources(native.registration)[0], 'retired')
            self.assertEqual(observed, [native.registration.parent])


    def test_replaced_journal_parent_is_retained(self):
        with self.completed() as (native, _):
            self.container_waiting(native)
            path = session.native_container_path(native.registration)
            path.parent.rename(path.parent.with_name('saved-containers'))
            path.parent.write_bytes(b'foreign parent')
            _, _, after = session.retire_registered_native_sources(native.registration)
            self.assertEqual(after['containerCleanup']['state'], 'retained')
            self.assertEqual(path.parent.read_bytes(), b'foreign parent')



if __name__ == '__main__':
    unittest.main()
