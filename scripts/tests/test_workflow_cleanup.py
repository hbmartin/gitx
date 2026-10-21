from __future__ import annotations

import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from support import ROOT, fixture_git_environment, load_script
import dev_workflow as workflow
import workflow_cleanup as cleanup
import workflow_session as session


class CleanupTests(unittest.TestCase):
    def test_native_scratch_registration_respects_incomplete_and_live_writer_evidence(self):
        logs = self.root / 'artifacts/verification/native-fixture/Logs/Native'
        native = session.NativeTestDiagnostics(self.base / 'custom-native-cache', logs, 'session', ['bundle'], True)
        source = native.stderr_directory / 'GitX-42-a.stderr.log'
        source.write_bytes(b'preserve-native')
        lease = os.open(native.root / 'invocation.lease', os.O_RDONLY)
        import fcntl
        fcntl.flock(lease, fcntl.LOCK_SH)
        try:
            result = native.close()
            self.assertEqual(result['retirementState'], 'deferred')
            discovered = session.registered_native_sources(self.root)
            self.assertEqual([path for path, _ in discovered], [native.registration])
            report = cleanup.inventory(self.root)
            self.assertTrue(any(item['paths'] == [str(native.root)] for item in report['nativeSources']))
            owner = discovered[0][1]
            owner['collectionComplete'] = False
            state, _ = session.retire_native_sources(owner, checkout=self.root)
            self.assertEqual(state, 'deferred')
            self.assertEqual(source.read_bytes(), b'preserve-native')
        finally:
            os.close(lease)

    def test_native_cleanup_does_not_adopt_unmarked_historical_fixtures(self):
        legacy = self.root / 'build/Fixtures/old/Native/invocation-legacy'
        legacy.mkdir(parents=True)
        sentinel = legacy / 'GitX-42-a.stderr.log'
        sentinel.write_bytes(b'historical-diagnostics')
        self.assertEqual(session.registered_native_sources(self.root), [])
        report = cleanup.inventory(self.root)
        self.assertEqual(report['nativeSources'], [])
        self.assertEqual(sentinel.read_bytes(), b'historical-diagnostics')

    def test_inline_citations_retain_old_runs_during_actual_cleanup(self):
        cited = self.run_directory('cited')
        double = self.run_directory('double')
        unrelated = self.run_directory('unrelated')
        (self.root / 'REVIEW.md').write_text('Verified with `cited` unrelated `cited` and ``double``.\n')
        self.git('add', 'REVIEW.md')
        self.git('commit', '-qm', 'inline citation fixture')
        cleanup.queue_commit(self.root)
        report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertTrue(cited.exists())
        self.assertTrue(double.exists())
        self.assertFalse(unrelated.exists())

    def test_legacy_active_steps_accept_missing_or_null_selection(self):
        steps = [{'name': 'correctness'}, {'name': 'historical'}]
        for payload in ({'steps': steps}, {'steps': steps, 'selectedChecks': None}):
            self.assertEqual(session.active_workflow_steps(payload), steps)
        self.assertEqual(session.active_workflow_steps({'steps': steps, 'selectedChecks': ['correctness']}), steps[:1])

    def test_inline_citation_delimiters_conservatively_protect_known_runs(self):
        aliases = {'known', 'known-extra', 'other', 'a+b'}
        for text, expected in [
            ('`verify\nknown`', {'known'}),
            ('stray ` before `known`', {'known'}),
            ('unclosed `known\nand other\n\nknown-extra is ordinary prose', {'known', 'other'}),
            ('\\`known in ordinary prose', set()),
            ('\\\\`known`', {'known'}),
            ('\\`stray and then `known`', {'known'}),
            ('\\```known``', {'known'}),
            ('``verify ` known-extra\nother``', {'known-extra', 'other'}),
            ('``unmatched known` then other', {'known', 'other'}),
            ('`prefix-known known-suffix known-extra a+b`', {'known-extra', 'a+b'}),
            ('`unrelated` known', set()),
            ('`unrelated` known `unrelated`', set()),
            ('`known` other `known`', {'known'}),
            ('``unrelated`` known ``unrelated``', set()),
            ('```md\n`known`\n```\nordinary other', set()),
            ('~~~md\n`known`\n~~~~\n`other`', {'other'}),
            ('ordinary known and other', set()),
        ]:
            with self.subTest(text=text):
                self.assertEqual(cleanup.cited_run_ids(text, None, aliases, self.artifact, self.root), expected)
        self.assertEqual(cleanup.cited_run_ids('`known`', None, set(), self.artifact, self.root), set())

    def test_ambiguous_and_multiline_citations_retain_runs_during_cleanup(self):
        cited = self.run_directory('cited')
        ambiguous = self.run_directory('ambiguous')
        unclosed = self.run_directory('unclosed')
        unrelated = self.run_directory('unrelated')
        (self.root / 'REVIEW.md').write_text('`verify\ncited`\n\nstray ` before `ambiguous`\n\nopen `unclosed\n')
        self.git('add', 'REVIEW.md')
        self.git('commit', '-qm', 'ambiguous citation fixture')
        cleanup.queue_commit(self.root)
        report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertTrue(all(path.exists() for path in (cited, ambiguous, unclosed)))
        self.assertFalse(unrelated.exists())

    def test_cleanup_requires_explicit_well_formed_selection(self):
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.read_json(receipt)
        for selection in ('missing', None, 'correctness', [None], [], ['correctness', 'correctness']):
            with self.subTest(selection=selection):
                value = json.loads(json.dumps(original))
                if selection == 'missing':
                    value.pop('selectedChecks')
                else:
                    value['selectedChecks'] = selection
                self.write(receipt, value)
                self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'incomplete-profile')
                if selection in ('missing', None, 'correctness') or selection == [None]:
                    with self.assertRaises(ValueError):
                        session.active_workflow_steps(value, require_selected_checks=True)

    def test_binary_attachment_without_known_extension_does_not_block_cleanup(self):
        old = self.run_directory('old')
        attachment = self.root / 'docs/diagnostics/capture.data'
        attachment.parent.mkdir(parents=True)
        attachment.write_bytes(b'\xff\xfe\x00capture')
        self.git('add', 'docs'); self.git('commit', '-qm', 'binary diagnostic attachment')
        cleanup.queue_commit(self.root)
        report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(old.exists())
        self.assertFalse(report['discoveryErrors'])

    def test_incidental_words_do_not_protect_run_ids_but_explicit_citations_do(self):
        run = self.run_directory('test')
        review = self.root / 'REVIEW.md'
        for text, protected in [('The test suite passed.\n', False),
                                ('Verified run ID: test\n', True),
                                (f'Build receipt `{run}/receipt.json` passed.\n', True)]:
            review.write_text(text)
            self.git('add', 'REVIEW.md'); self.git('commit', '-qm', 'diagnostic citation fixture')
            report = cleanup.preview(self.root, now=self.now)
            self.assertEqual(str(run) not in self.candidate_paths(report), protected)

    def test_live_run_is_protected_before_recursive_fingerprinting(self):
        live = self.run_directory('live', status='running')
        old = self.run_directory('old')
        original = cleanup.fingerprint
        def inspect(path):
            if pathlib.Path(path) == live:
                raise ValueError('live output changed during discovery')
            return original(path)
        with mock.patch.object(session, 'producer_state', return_value='live'), mock.patch.object(
                cleanup, 'fingerprint', side_effect=inspect):
            cleanup.queue_commit(self.root)
            report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertTrue(live.exists())
        self.assertFalse(old.exists())
        self.assertFalse(report['discoveryErrors'])
        self.assertFalse(report['diagnosticBytesComplete'])

    def test_accounting_only_failure_does_not_block_unrelated_candidates(self):
        old = self.run_directory('old')
        container = self.artifact / 'diagnostics'
        (container / 'unknown').mkdir(parents=True)
        original = cleanup.fingerprint
        def inspect(path):
            if pathlib.Path(path) == container:
                raise ValueError('diagnostic log changed during accounting')
            return original(path)
        cleanup.queue_commit(self.root)
        with mock.patch.object(cleanup, 'fingerprint', side_effect=inspect):
            report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(old.exists())
        self.assertFalse(report['discoveryErrors'])
        self.assertTrue(report['accountingErrors'])
        self.assertFalse(report['diagnosticBytesComplete'])

    def test_candidate_fingerprint_failure_retains_only_that_entry(self):
        broken = self.run_directory('broken')
        old = self.run_directory('old')
        original = cleanup.fingerprint
        def inspect(path):
            if pathlib.Path(path) == broken:
                raise ValueError('candidate changed during discovery')
            return original(path)
        cleanup.queue_commit(self.root)
        with mock.patch.object(cleanup, 'fingerprint', side_effect=inspect):
            report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertTrue(broken.exists())
        self.assertFalse(old.exists())
        self.assertFalse(report['discoveryErrors'])
        self.assertTrue(report['entryErrors'])
        self.assertEqual(report['status'], 'partial')

    def test_corrupt_regular_pending_records_are_replaced_but_links_refused(self):
        for data in ['{', '[]', '{"head": 1}', 'null']:
            cleanup.queue_commit(self.root)
            cleanup.pending_path(self.root).write_text(data)
            queued = cleanup.queue_commit(self.root)
            self.assertEqual(queued['head'], session.git(self.root, 'rev-parse', 'HEAD'))
            self.assertTrue(queued['token'])
        path = cleanup.pending_path(self.root)
        path.unlink()
        outside = self.base / 'outside.json'
        outside.write_text('leave unchanged')
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            cleanup.queue_commit(self.root)
        self.assertTrue(path.is_symlink())
        self.assertEqual(outside.read_text(), 'leave unchanged')

    def test_completed_absent_journal_does_not_require_original_parent(self):
        for recreate in [False, True]:
            old, receipt, journal, value = self.prepare_original_journal()
            relocated = self.artifact.with_name('relocated-' + journal.stem)
            self.artifact.rename(relocated)
            if recreate:
                self.artifact.mkdir()
            self.assertIsNone(cleanup.quarantine_journal(journal, value, cleanup.state_directory(self.root)))
            self.assertEqual(cleanup.read_json(journal)['state'], 'complete')
            self.assertTrue((relocated / old.name).exists())
            if self.artifact.exists():
                self.artifact.rmdir()

    def test_already_absent_journal_reports_zero_newly_reclaimed_bytes(self):
        old, receipt, journal, value = self.prepare_original_journal()
        shutil.rmtree(old)
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(report['reclaimedBytes'], 0)
        self.assertFalse(report['deleted'])
        self.assertEqual(cleanup.read_json(journal)['state'], 'complete')

    def test_quarantine_retry_counts_remaining_bytes_and_accepts_legacy_protection(self):
        old, receipt, journal, value = self.interrupted_journal()
        quarantine = pathlib.Path(value['quarantinePath'])
        (quarantine / 'Results/output').unlink()
        remaining = cleanup.fingerprint(quarantine)['bytes']
        value['authorization']['protection'] = cleanup.protection_token(self.root)
        value['authorization'].pop('protectionDigest', None)
        self.write(journal, value)
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(report['reclaimedBytes'], remaining)
        self.assertLess(remaining, value['authorization']['snapshot']['bytes'])

    def test_cleanup_inherits_authenticated_environment_proof_leases(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        with session.Leases([str(self.root / 'build/GitX.app')],
                            {'runId': 'parent', 'pid': os.getpid(), 'receipt': 'parent'}, inherited={}) as parent:
            with mock.patch.dict(os.environ, parent.environment()):
                report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(old.exists())

    def test_final_resource_contention_persists_deletion_report(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        finish = cleanup.finish_journal
        leases = []
        def contend(*args):
            result = finish(*args)
            lease = session.Leases([str(self.root / 'build/GitX.app')],
                                   {'runId': 'other', 'pid': os.getpid(), 'receipt': 'other'}, inherited={})
            lease.__enter__()
            leases.append(lease)
            return result
        try:
            with mock.patch.object(cleanup, 'finish_journal', side_effect=contend):
                report = cleanup.run_cleanup(self.root, receipt)
        finally:
            for lease in leases:
                lease.__exit__(None, None, None)
        self.assertFalse(old.exists())
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(report['deleted'])
        self.assertIn('Resource busy', report['reason'])
        self.assertEqual(cleanup.read_json(report['report'])['deleted'], report['deleted'])
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_removed_bytes_are_reported_when_journal_completion_cannot_be_saved(self):
        old = self.run_directory('old')
        expected_bytes = cleanup.fingerprint(old)['bytes']
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        persist = cleanup.persist_journal
        def fail_completion(path, value):
            if pathlib.Path(path).parent.name == 'journals' and value.get('state') == 'complete':
                raise OSError('completion publication failed')
            return persist(path, value)
        with mock.patch.object(cleanup, 'persist_journal', side_effect=fail_completion):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertFalse(old.exists())
        self.assertEqual(report['reclaimedBytes'], expected_bytes)
        self.assertEqual({p for item in report['deleted'] for p in item['paths']}, {str(old)})
        journal = next((cleanup.state_directory(self.root) / 'journals').glob('*.json'))
        self.assertEqual(cleanup.read_json(journal)['state'], 'quarantined')
        self.assertEqual(report['failed'][0]['journal'], str(journal))
        self.assertEqual(cleanup.read_json(report['report'])['reclaimedBytes'], expected_bytes)
        retry = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(retry['status'], 'complete')
        self.assertEqual(retry['reclaimedBytes'], 0)
        self.assertFalse(retry['deleted'])

    def test_linked_group_failure_reports_only_paths_not_already_removed(self):
        first = self.run_directory('first', 12)
        second = self.run_directory('second', 10)
        self.write(first / 'workflow.json', {'schemaVersion': 2, 'status': 'passed',
                                          'steps': [{'receipt': str(second / 'receipt.json')}]})
        self.stamp(first, 12)
        expected_second_bytes = cleanup.fingerprint(second)['bytes']
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        finish = cleanup.finish_journal
        def fail_second(journal, value, directory):
            if value['originalPath'] == str(second):
                raise OSError('second removal failed')
            return finish(journal, value, directory)
        with mock.patch.object(cleanup, 'finish_journal', side_effect=fail_second):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertEqual({p for item in report['deleted'] for p in item['paths']}, {str(first)})
        self.assertEqual(report['failed'][0]['paths'], [str(second)])
        self.assertEqual(report['failed'][0]['bytes'], expected_second_bytes)

    def test_journal_completion_requires_quarantine_to_be_absent(self):
        self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        with mock.patch.object(cleanup.shutil, 'rmtree', return_value=None):
            report = cleanup.run_cleanup(self.root, receipt)
        journal = next((cleanup.state_directory(self.root) / 'journals').glob('*.json'))
        value = cleanup.read_json(journal)
        self.assertEqual(report['status'], 'partial')
        self.assertEqual(value['state'], 'quarantined')
        self.assertTrue(pathlib.Path(value['quarantinePath']).exists())
        self.assertEqual(report['reclaimedBytes'], 0)
        self.assertFalse(report['deleted'])
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_recreated_original_preserves_new_references_to_known_objects(self):
        first = self.run_directory('first', 12)
        cache = self.legacy_cache('referenced')
        value = cleanup.read_json(first / 'receipt.json')
        value['buildPaths'] = {'derivedData': str(cache)}
        self.write(first / 'receipt.json', value)
        self.stamp(first, 12)
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        finish = cleanup.finish_journal
        def recreate_original(journal, journal_value, directory):
            result = finish(journal, journal_value, directory)
            if journal_value['originalPath'] == str(first):
                self.write(first / 'receipt.json', value | {'status': 'running'})
                (first / 'new-output').write_text('new producer output')
            return result
        with mock.patch.object(cleanup, 'finish_journal', side_effect=recreate_original):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(cache.exists())
        self.assertEqual((first / 'new-output').read_text(), 'new producer output')
        self.assertIn('removed-output-reappeared', str(report['skipped']))
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_original_recreated_during_removal_is_preserved_with_traceable_accounting(self):
        old = self.run_directory('old')
        expected_bytes = cleanup.fingerprint(old)['bytes']
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def recreate_original(path, **kwargs):
            remove(path, **kwargs)
            if pathlib.Path(path).name.startswith('.gitx-cleanup-trash-'):
                old.mkdir()
                (old / 'new-output').write_text('preserve newly created output')
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=recreate_original):
            report = cleanup.run_cleanup(self.root, receipt)
        journal = next((cleanup.state_directory(self.root) / 'journals').glob('*.json'))
        self.assertEqual(report['status'], 'partial')
        self.assertEqual(cleanup.read_json(journal)['state'], 'quarantined')
        self.assertEqual((old / 'new-output').read_text(), 'preserve newly created output')
        self.assertEqual(report['reclaimedBytes'], expected_bytes)
        self.assertEqual(report['failed'][0]['journal'], str(journal))
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_removed_sole_referrer_does_not_block_second_candidate(self):
        first = self.run_directory('first', age=12)
        second = self.run_directory('second', age=10)
        scratch = self.base / 'scratch'
        scratch.mkdir()
        value = cleanup.read_json(first / 'receipt.json')
        value['buildPaths'] = {'derivedData': str(scratch)}
        self.write(first / 'receipt.json', value)
        self.stamp(first, 12)
        cleanup.queue_commit(self.root)
        report = cleanup.run_cleanup(self.root, self.valid_receipt())
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue(scratch.exists())

    def test_removed_referrers_only_relax_missing_object_keys(self):
        removed = self.artifact / 'removed'
        surviving = self.artifact / 'surviving/receipt.json'
        source = removed / 'receipt.json'
        object_path = str(self.base / 'scratch')
        expected = {'files': {str(source): 'old', str(surviving): 'unchanged'},
                    'objects': {object_path: [1, 2]}, 'other': 'unchanged'}
        current = {'files': {str(surviving): 'unchanged'}, 'objects': {}, 'other': 'unchanged'}
        referrers = {object_path: {('file', str(source))}}
        self.assertTrue(cleanup.protection_matches(expected, current, {removed}, referrers))
        self.assertFalse(cleanup.protection_matches(expected, current | {'files': {str(surviving): 'edited'}},
                                                    {removed}, referrers))
        self.assertFalse(cleanup.protection_matches(expected, current | {'objects': {object_path: [1, 3]}},
                                                    {removed}, referrers))
        self.assertFalse(cleanup.protection_matches(expected, current | {'objects': {'new': [1, 2]}},
                                                    {removed}, referrers))
        referrers[object_path].add(('file', str(surviving)))
        self.assertFalse(cleanup.protection_matches(expected, current, {removed}, referrers))

    def test_linked_group_rechecks_protection_before_each_quarantine(self):
        first = self.run_directory('first', 12)
        second = self.run_directory('second', 10)
        self.write(first / 'workflow.json', {'schemaVersion': 2, 'status': 'passed',
                                          'steps': [{'receipt': str(second / 'receipt.json')}]})
        self.stamp(first, 12)
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        quarantine = cleanup.quarantine_journal
        def change_after_quarantine(*args):
            target = quarantine(*args)
            (self.root / 'source.txt').write_text('changed before the next quarantine')
            return target
        with mock.patch.object(cleanup, 'quarantine_journal', side_effect=change_after_quarantine):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertEqual({p for item in report['deleted'] for p in item['paths']}, {str(first)})
        self.assertEqual({p for item in report['skipped'] for p in item['paths']}, {str(second)})

    def test_invalid_and_produced_blocked_coordination_receipts_are_managed(self):
        paths = []
        for name, status, extra in [
                ('invalid', 'invalid', {'evidence': {'inputsBefore': {'root': str(self.root)}}}),
                ('busy', 'blocked', {'schemaVersion': 2, 'exitCode': 75, 'category': 'resource-busy'}),
                ('changed', 'blocked', {'schemaVersion': 2, 'exitCode': 2, 'category': 'resource-definition-changed'}),
                ('unavailable', 'blocked', {'schemaVersion': 2, 'exitCode': 2, 'category': 'resource-definition-unavailable'})]:
            path = self.artifact / f'Coordination/{name}.json'
            self.write(path, {'runId': name, 'receipt': str(path),
                             'entry': str(self.root / 'scripts/dev_workflow.py'), 'status': status} | extra)
            paths.append(path)
        unknown = self.artifact / 'Coordination/unknown.json'
        self.write(unknown, {'runId': 'unknown', 'receipt': str(unknown),
                            'entry': str(self.root / 'scripts/dev_workflow.py'), 'status': 'blocked'})
        self.stamp(self.artifact, 10)
        report = cleanup.preview(self.root, now=self.now)
        # The newest invalid receipt is deliberately protected as the newest failure.
        self.assertTrue(set(map(str, paths[1:])).issubset(self.candidate_paths(report)))
        self.assertFalse(any(str(paths[0]) in item['paths'] and 'unmanaged' in item['reason']
                             for item in report['retained']))
        self.assertNotIn(str(unknown), self.candidate_paths(report))

    def test_linked_build_root_and_cache_leaves_are_not_candidates(self):
        legacy = self.legacy_cache('legacy')
        outside = self.base / 'outside-build'
        (self.root / 'build').rename(outside)
        (self.root / 'build').symlink_to(outside, target_is_directory=True)
        leaf = pathlib.Path(self.cache_paths()['derivedData']).parents[3] / ('b' * 16) / 'Debug/plain/DerivedData'
        leaf.parent.mkdir(parents=True)
        leaf.symlink_to(outside, target_is_directory=True)
        when = self.now - 10 * 86400
        os.utime(leaf, (when, when), follow_symlinks=False)
        report = cleanup.preview(self.root, now=self.now)
        self.assertNotIn(str(legacy), self.candidate_paths(report))
        self.assertNotIn(str(leaf), self.candidate_paths(report))

    def test_invalid_journal_path_is_rejected_before_persistence(self):
        legacy = self.legacy_cache('legacy')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        outside = self.base / 'outside-build'
        (self.root / 'build').rename(outside)
        (self.root / 'build').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            cleanup.prepare_journal(legacy, cleanup.fingerprint(legacy), self.root, receipt,
                                    cleanup.read_json(cleanup.pending_path(self.root)), cleanup.protection_token(self.root))
        self.assertFalse(list((cleanup.state_directory(self.root) / 'journals').glob('*.json')))

    def test_new_journals_store_protection_digest_and_completed_history_is_bounded(self):
        old, receipt, journal, value = self.prepare_original_journal()
        self.assertNotIn('protection', value['authorization'])
        self.assertRegex(value['authorization']['protectionDigest'], r'^[0-9a-f]{64}$')
        directory = cleanup.state_directory(self.root)
        incomplete = directory / 'journals/incomplete.json'
        self.write(incomplete, {'state': 'prepared'})
        invalid = directory / 'journals/invalid-complete.json'
        self.write(invalid, {'schemaVersion': 1, 'state': 'complete'})
        for index in range(25):
            self.write(directory / f'journals/completed-{index:02}.json',
                       value | {'state': 'complete', 'finishedAt': f'2020-01-01T00:00:{index:02}Z'})
            self.write(directory / f'reports/partial-{index:02}.json', {'status': 'partial'})
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(len(list((directory / 'reports').glob('*.json'))), 20)
        completed = [p for p in (directory / 'journals').glob('*.json')
                     if p != invalid and cleanup.read_json(p).get('state') == 'complete']
        self.assertEqual(len(completed), 20)
        self.assertTrue(journal.exists())
        self.assertTrue(incomplete.exists())
        self.assertTrue(invalid.exists())
        self.assertTrue(pathlib.Path(report['report']).exists())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        (self.root / '.git/hooks').mkdir(exist_ok=True)
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'maintenance.auto', 'false')
        self.git('config', 'gc.auto', '0')
        (self.root / '.gitignore').write_text('artifacts/\nbuild/\n__pycache__/\n')
        (self.root / 'source.txt').write_text('source')
        (self.root / 'scripts').mkdir()
        for name in ('dev_workflow.py', 'workflow_session.py', 'workflow_records.py', 'workflow_feedback.py', 'workflow_cleanup.py', 'verification-config.json'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.commands = [('check', ['fixture-check']), ('stage-debug', ['fixture-stage'])]
        self.locks = self.base / 'Locks'
        real_leases = session.Leases
        patches = [mock.patch.object(session, 'ROOT', self.root),
                   mock.patch.object(session, 'LOCK_ROOT', self.locks),
                   mock.patch.object(session, 'Leases', side_effect=lambda *a, **kw: real_leases(*a, lock_root=self.locks, **kw)),
                   mock.patch.dict(os.environ, {'GITX_VERIFICATION_CACHE_ROOT': str(self.base / 'cache')}, clear=True),
                   mock.patch.object(workflow, 'full_profile', return_value=self.commands)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.artifact = self.root / 'artifacts/verification'
        self.now = time.time()
        # Avoid executing Xcode for path calculations without interfering with Git.
        self.cache_paths_patch = mock.patch.object(session, 'cache_paths', side_effect=self.cache_paths)
        self.cache_paths_patch.start()
        self.addCleanup(self.cache_paths_patch.stop)

    def cache_paths(self, root=None, configuration='Debug', instrumentation='plain', developer=None, toolchain=None):
        root = pathlib.Path(root or self.root).resolve()
        base = session.verification_cache_root(root) / session.digest(str(root).encode())[:16] / ('a' * 16)
        p = base / configuration / instrumentation
        return {'derivedData': str(p / 'DerivedData'), 'swiftPM': str(p / 'SwiftPM'),
                'sourcePackages': str(base / 'SourcePackages'), 'toolchain': 'fixture'}

    def git(self, *args):
        # Fingerprint fixtures must stay quiescent after Git returns, without detached housekeeping.
        return subprocess.run(['git', '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
                               '-C', str(self.root), *args], env=fixture_git_environment(),
                              check=True, capture_output=True, text=True)

    def stamp(self, path, age):
        when = self.now - age * 86400
        for p in sorted(path.rglob('*'), reverse=True) + [path]:
            if not p.is_symlink():
                os.utime(p, (when, when))

    def run_directory(self, name, age=10, status='passed', size=16384):
        path = self.artifact / name
        path.mkdir(parents=True)
        (path / 'Results').mkdir()
        (path / 'Results/output').write_bytes(b'x' * size)
        self.write(path / 'receipt.json', {'schemaVersion': 2, 'status': status,
                    'startedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.now - age * 86400)),
                    'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.now - age * 86400)),
                    'buildPaths': {}, 'artifacts': []})
        self.stamp(path, age)
        return path

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def candidate_paths(self, report):
        return {p for c in report['candidates'] for p in c['paths']}

    def valid_receipt(self):
        app = self.root / 'build/GitX.app'
        app.mkdir(parents=True, exist_ok=True)
        (app / 'binary').write_bytes(b'app')
        current = session.inputs(self.root)
        steps = [{'name': name, 'command': command, 'status': 'passed', 'evidenceStatus': 'valid',
                  'inputsAfter': current, 'toolchain': 'fixture', 'outputs': {}} for name, command in self.commands]
        steps[-1]['outputs'][str(app)] = session.tree_identity(app)
        path = self.artifact / 'current/workflow.json'
        self.write(path, {'schemaVersion': 2, 'status': 'passed', 'profile': 'full', 'scope': 'full',
                        'deliveryEligible': True, 'evidenceStatus': 'valid', 'inputsBefore': current,
                        'inputsAfter': current, 'selectedChecks': [n for n, _ in self.commands], 'steps': steps})
        return path

    def test_gate_accepts_reordered_resumed_checks_by_name(self):
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        value['steps'].reverse()
        value['selectedChecks'].reverse()
        self.write(receipt, value)
        self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])

    def test_full_resume_ignores_retained_feedback_evidence_but_requires_every_active_check(self):
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        valid = cleanup.read_json(receipt)
        valid['steps'].append({'name': 'whitespace', 'status': 'failed', 'receipt': '/missing-feedback.json'})
        self.write(receipt, valid)
        self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])
        for defect in ('missing', 'duplicate', 'failed', 'invalid', 'stale', 'malformed', 'selection'):
            with self.subTest(defect=defect):
                value = json.loads(json.dumps(valid))
                if defect == 'missing': value['steps'].pop(0)
                elif defect == 'duplicate': value['steps'].append(value['steps'][0])
                elif defect == 'failed': value['steps'][0]['status'] = 'failed'
                elif defect == 'invalid': value['steps'][0]['evidenceStatus'] = 'invalid'
                elif defect == 'stale': value['steps'][0]['inputsAfter']['head'] = 'stale'
                elif defect == 'malformed': value['steps'][0] = None
                else: value['selectedChecks'] = 'check'
                self.write(receipt, value)
                self.assertIsNotNone(cleanup.eligibility(self.root, receipt)[1])

    def test_legacy_and_modern_citations_match_exact_known_identifiers(self):
        aliases = {'workflow-xyz', 'workflow-xyz-extra', 'other'}
        for text, expected in [
            ('Run: workflow-xyz', {'workflow-xyz'}),
            ('RUN-ID = workflow-xyz, other', {'workflow-xyz', 'other'}),
            ('Run IDs: "workflow-xyz", `other`', {'workflow-xyz', 'other'}),
            ('Verified with `workflow-xyz`.', {'workflow-xyz'}),
            ('Verified with ``run workflow-xyz``.', {'workflow-xyz'}),
            ('`workflow-xyz-extra`', {'workflow-xyz-extra'}),
            ('`prefix-workflow-xyz` or `workflow-xyz-suffix`', set()),
            ('Ordinary prose mentions workflow-xyz.', set()),
            ('```\nworkflow-xyz\n```', set()),
            ('artifacts/verification/workflow-xyz/receipt.json', {'workflow-xyz'}),
        ]:
            with self.subTest(text=text):
                self.assertEqual(cleanup.cited_run_ids(text, None, aliases, self.artifact, self.root), expected)
        self.assertEqual(cleanup.cited_run_ids('', {'runId': 'workflow-xyz', 'runIds': ['other'], 'runs': ['workflow-xyz-extra']}, aliases, self.artifact, self.root), aliases)

    def test_proof_resources_discovers_toolchain_once_for_all_commands(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('check', [command, 'test', 'core']),
                            ('stage-debug', [command, 'build', '--stage-app'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        with mock.patch.object(session, 'entry_resources', wraps=session.entry_resources) as entries, \
                mock.patch.object(session, 'toolchain_identity', return_value='fixture') as probes:
            resources = cleanup.proof_resources(self.root, receipt)
        self.assertIn(str(self.root / 'build/GitX.app'), resources)
        self.assertEqual(entries.call_count, 2)
        self.assertTrue(all(call.kwargs.get('toolchain') == 'fixture' for call in entries.call_args_list))
        probes.assert_not_called()

    def test_real_full_profile_inventory_uses_an_explicit_toolchain_for_static_and_native_checks(self):
        self.commands[:] = load_script('dev_workflow.py').full_profile(self.root)
        old = self.run_directory('old')
        warm = pathlib.Path(self.cache_paths()['derivedData'])
        warm.mkdir(parents=True)
        self.stamp(warm, 10)
        with mock.patch.object(session, 'entry_resources', wraps=session.entry_resources) as entries, \
                mock.patch.object(session, 'toolchain_identity', side_effect=AssertionError('unexpected probe')):
            report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(old), self.candidate_paths(report))
        self.assertNotIn(str(warm), self.candidate_paths(report))
        self.assertTrue(any(call.args[0] == 'verify_static.sh' for call in entries.call_args_list))
        self.assertTrue(all(call.kwargs.get('toolchain') == 'fixture' for call in entries.call_args_list))

    def test_protection_boundary_reads_duplicate_metadata_only_once(self):
        path = self.artifact / 'diagnostics/diagnostic-owner.json'
        self.write(path, {'schemaVersion': 1, 'kind': 'gitx-diagnostics', 'runId': 'legacy',
                          'checkout': str(self.root), 'status': 'passed'})
        with mock.patch.object(cleanup, 'read_json', wraps=cleanup.read_json) as reads, \
                mock.patch.object(session, 'tree_identity', wraps=session.tree_identity) as hashes:
            cleanup.protection_token(self.root)
        self.assertEqual(sum(pathlib.Path(call.args[0]) == path for call in reads.call_args_list), 1)
        self.assertEqual(sum(pathlib.Path(call.args[0]) == path for call in hashes.call_args_list), 1)

    def test_gate_reuses_receipts_and_hashes_only_within_one_authorization(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('check', [command, 'build-tests']),
                            ('stage-debug', [command, 'build', '--stage-app'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        current = session.inputs(self.root)
        result = self.artifact / 'child/Results/test.xcresult'
        result.mkdir(parents=True)
        (result / 'data').write_text('original')
        identity = session.tree_identity(result)
        child = result.parents[1] / 'receipt.json'
        self.write(child, {'schemaVersion': 2, 'status': 'passed',
                           'evidence': {'status': 'valid', 'inputsBefore': current, 'inputsAfter': current,
                                        'dependencyProducts': {}, 'results': {str(result): identity}}})
        for step in value['steps']:
            step['receipt'] = str(child)
        value['steps'][0]['outputs'][str(result)] = identity
        self.write(receipt, value)
        with mock.patch.object(cleanup, 'read_json', wraps=cleanup.read_json) as reads, \
                mock.patch.object(session, 'tree_identity', wraps=session.tree_identity) as hashes:
            self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])
            self.assertEqual(sum(pathlib.Path(call.args[0]) == child for call in reads.call_args_list), 1)
            self.assertEqual(sum(pathlib.Path(call.args[0]) == result for call in hashes.call_args_list), 1)
            app = self.root / 'build/GitX.app'
            self.assertEqual(sum(pathlib.Path(call.args[0]) == app for call in hashes.call_args_list), 1)
            (result / 'data').write_text('changed before the next authorization')
            self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'child-artifacts-changed')
            self.assertEqual(sum(pathlib.Path(call.args[0]) == child for call in reads.call_args_list), 2)
            self.assertEqual(sum(pathlib.Path(call.args[0]) == result for call in hashes.call_args_list), 2)

    def test_untracked_fingerprinted_inputs_cannot_authorize_cleanup(self):
        (self.root / 'Classes').mkdir()
        (self.root / 'Classes/New.swift').write_text('struct New {}')
        cleanup.queue_commit(self.root)
        self.assertEqual(cleanup.eligibility(self.root, self.valid_receipt())[1], 'uncommitted-build-inputs')

    def test_untracked_research_stays_outside_the_commit_gate(self):
        (self.root / 'research').mkdir()
        (self.root / 'research/notes.txt').write_text('unrelated notes')
        cleanup.queue_commit(self.root)
        self.assertIsNone(cleanup.eligibility(self.root, self.valid_receipt())[1])

    def test_dirty_dependency_cannot_authorize_cleanup_when_diff_ignores_submodules(self):
        dependency = self.base / 'dependency'
        dependency.mkdir()
        def dependency_git(*args):
            return subprocess.run(['git', '-C', str(dependency), *args], check=True, capture_output=True, text=True)
        dependency_git('init', '-q')
        dependency_git('config', 'user.name', 'Fixture')
        dependency_git('config', 'user.email', 'fixture@example.invalid')
        dependency_git('config', 'commit.gpgsign', 'false')
        dependency_git('config', 'maintenance.auto', 'false')
        dependency_git('config', 'gc.auto', '0')
        (dependency / 'source.c').write_text('int value = 1;\n')
        dependency_git('add', '.')
        dependency_git('commit', '-qm', 'dependency fixture')
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', str(dependency), 'External/Fixture')
        for key, value in [('maintenance.auto', 'false'), ('gc.auto', '0')]:
            self.git('-C', str(self.root / 'External/Fixture'), 'config', key, value)
        self.git('commit', '-qam', 'add dependency')
        self.git('config', 'diff.ignoreSubmodules', 'all')
        (self.root / 'External/Fixture/source.c').write_text('int value = 2;\n')
        self.assertEqual(self.git('diff', 'HEAD', '--binary').stdout, '')
        cleanup.queue_commit(self.root)
        self.assertEqual(cleanup.eligibility(self.root, self.valid_receipt())[1], 'uncommitted-tracked-changes')

    def test_embedded_repository_is_protected_at_any_depth(self):
        old = self.run_directory('old')
        (old / 'Results/nested/.git').mkdir(parents=True)
        self.stamp(old, 10)
        self.assertNotIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_filesystem_aliases_protect_the_same_directory(self):
        old = self.run_directory('MixedCase')
        alias = old.with_name('mixedcase')
        if not alias.exists() or not os.path.samefile(alias, old):
            self.skipTest('Fixture volume is case-sensitive')
        self.write(self.root / '.git/gitx-workflow/ledger.json', {'items': {'work': {'recoverySources': [str(alias / 'Results/output')]}}})
        self.assertNotIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_ancestor_worktree_does_not_protect_owned_child_output(self):
        old = self.run_directory('old')
        with mock.patch.object(cleanup.records, 'worktrees', return_value=[{'worktree': str(self.base)}, {'worktree': str(self.root)}]):
            self.assertIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_tracked_provenance_paths_and_exact_run_ids_are_protected(self):
        for content in [{'verificationReceipts': ['artifacts/verification/old/receipt.json']}, {'runs': ['old']}, 'Verified run ID: old\n']:
            old = self.artifact / 'old'
            if not old.exists():
                self.run_directory('old')
            provenance = self.root / 'docs/diagnostics/verification.json'
            if isinstance(content, str):
                provenance = provenance.with_name('REVIEW.md')
                provenance.parent.mkdir(parents=True, exist_ok=True)
                provenance.write_text(content)
            else:
                self.write(provenance, content)
            self.git('add', 'docs')
            self.git('commit', '-qm', 'tracked diagnostic provenance')
            self.assertNotIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))
            shutil.rmtree(self.root / 'docs')
            self.git('add', '-u')
            self.git('commit', '-qm', 'remove diagnostic provenance fixture')

    def test_discovery_failure_retains_uncertainty_and_reports_remaining_inventory(self):
        broken = self.run_directory('broken')
        remaining = self.run_directory('remaining')
        original = cleanup.fingerprint
        def inspect(path):
            if pathlib.Path(path) == broken:
                raise FileNotFoundError('entry disappeared')
            return original(path)
        with mock.patch.object(cleanup, 'fingerprint', side_effect=inspect):
            report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(remaining), self.candidate_paths(report))
        self.assertFalse(report['discoveryErrors'])
        self.assertTrue(report['entryErrors'])
        self.assertTrue(any(str(broken) in item['paths'] for item in report['retained']))

    def test_conclusively_abandoned_run_enters_retention(self):
        abandoned = self.run_directory('abandoned', status='running')
        value = cleanup.read_json(abandoned / 'receipt.json')
        value['producer'] = {'pid': 999999999, 'started': 'old identity'}
        self.write(abandoned / 'receipt.json', value)
        self.stamp(abandoned, 10)
        with mock.patch.object(session, 'producer_state', return_value='abandoned'):
            self.assertIn(str(abandoned), self.candidate_paths(cleanup.preview(self.root, now=self.now)))
        for state in ['live', 'uncertain']:
            with mock.patch.object(session, 'producer_state', return_value=state):
                self.assertNotIn(str(abandoned), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_discovery_holds_no_desktop_product_or_ledger_lease(self):
        self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def inspect(*args, **kwargs):
            resources = [str(self.root / 'build/GitX.app'), str(cleanup.records.common_directory(self.root) / 'ledger.json'), f'desktop:{os.getuid()}']
            with session.Leases(resources, {'runId': 'independent', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
                pass
            return original(*args, **kwargs)
        with mock.patch.object(cleanup, 'inventory', side_effect=inspect):
            self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')

    def prepare_original_journal(self):
        old = self.run_directory('prepared-original')
        pending = cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        report = cleanup.inventory(self.root, receipt)
        self.assertIn(str(old), self.candidate_paths(report))
        journal, value = cleanup.prepare_journal(old, cleanup.fingerprint(old), self.root,
                                                 receipt, pending, report['protectionToken'])
        self.assertTrue(old.is_dir())
        self.assertFalse(pathlib.Path(value['quarantinePath']).exists())
        return old, receipt, journal, value

    def test_prepared_original_journal_retries_under_unchanged_authorization(self):
        old, receipt, journal, value = self.prepare_original_journal()
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(old.exists())
        self.assertFalse(pathlib.Path(value['quarantinePath']).exists())
        self.assertEqual(cleanup.read_json(journal)['state'], 'complete')
        self.assertFalse(cleanup.pending_path(self.root).exists())

    def test_prepared_journal_retains_original_after_retention_policy_change(self):
        old, _, journal, value = self.prepare_original_journal()
        policy_path = self.root / 'scripts/verification-config.json'
        policy = cleanup.read_json(policy_path)
        policy['cleanup']['retentionDays'] = 365
        self.write(policy_path, policy)
        self.git('add', str(policy_path))
        self.git('commit', '-qm', 'Retain diagnostics for one year')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        self.assertNotIn(str(old), self.candidate_paths(cleanup.inventory(self.root, receipt)))

        report = cleanup.run_cleanup(self.root, receipt)
        self.assertTrue(old.is_dir(), 'A prepared journal is not current deletion authorization')
        self.assertFalse(pathlib.Path(value['quarantinePath']).exists())
        self.assertEqual(cleanup.read_json(journal)['state'], 'prepared')
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(any('no longer eligible' in item['reason'] for item in report['failed']))
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_prepared_journal_records_current_authorization_before_new_quarantine(self):
        old, _, journal, value = self.prepare_original_journal()
        (self.root / 'source.txt').write_text('new verified source')
        self.git('commit', '-qam', 'New verified commit')
        pending = cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        self.assertNotEqual(value['authorization']['head'], pending['head'])
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertFalse(old.exists())
        recorded = cleanup.read_json(journal)['authorization']
        self.assertEqual(recorded['head'], pending['head'])
        self.assertEqual(recorded['pendingToken'], pending['token'])
        self.assertEqual(recorded['receiptIdentity'], session.tree_identity(receipt))

    def test_interrupted_removal_is_retried_from_an_external_journal(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def fail(path, **kwargs):
            target = pathlib.Path(path)
            if target == old or target.name.startswith('.gitx-cleanup-trash-'):
                for name in ['receipt.json', 'workflow.json', 'info.plist']:
                    (target / name).unlink(missing_ok=True)
                raise OSError('interrupted removal after metadata loss')
            return remove(path, **kwargs)
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=fail):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        journals = list((cleanup.state_directory(self.root) / 'journals').glob('*.json'))
        self.assertTrue(journals)
        journal = cleanup.read_json(journals[0])
        self.assertEqual(journal['originalPath'], str(old))
        self.assertTrue(pathlib.Path(journal['quarantinePath']).is_dir())
        self.assertTrue(cleanup.pending_path(self.root).exists())
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')
        self.assertFalse(pathlib.Path(journal['quarantinePath']).exists())

    def test_queue_notifications_are_idempotent_for_one_commit(self):
        first = cleanup.queue_commit(self.root)
        second = cleanup.queue_commit(self.root)
        self.assertEqual(first['token'], second['token'])

    def test_owned_hooks_are_repaired_and_cover_commit_transitions(self):
        cleanup.install_hook(self.root)
        for name in ['post-commit', 'post-merge', 'post-applypatch', 'post-rewrite']:
            hook = self.root / '.git/hooks' / name
            self.assertTrue(hook.exists())
            self.assertIn('python3 ', hook.read_text())
        hook = self.root / '.git/hooks/post-commit'
        legacy = ('#!/bin/sh\n# GitX commit-triggered cleanup v1\n'
                  'checkout=$(git rev-parse --show-toplevel) || exit 0\n'
                  'if [ -f "$checkout/scripts/workflow_cleanup.py" ] && [ -f "$checkout/scripts/dev_workflow.py" ]; then\n'
                  '    /defunct/python "$checkout/scripts/dev_workflow.py" cleanup queue >/dev/null ||\n'
                  '        echo "GitX: cleanup could not be queued; the commit is preserved." >&2\n'
                  'fi\nexit 0\n')
        hook.write_text(legacy)
        cleanup.install_hook(self.root)
        self.assertIn('python3 ', hook.read_text())
        self.assertNotIn('/defunct/python', hook.read_text())

    def test_owned_coordination_receipts_are_retention_candidates(self):
        receipt = self.artifact / 'Coordination/old.json'
        self.write(receipt, {'runId': 'old', 'pid': 999999999, 'receipt': str(receipt), 'entry': str(self.root / 'scripts/dev_workflow.py'),
                            'status': 'passed', 'resources': [f'desktop:{os.getuid()}', self.cache_paths()['derivedData']], 'evidence': {'inputsBefore': {'root': str(self.root)}}})
        self.stamp(receipt.parent, 10)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(receipt), self.candidate_paths(report))
        self.assertIn('protectedDiagnosticBytes', report)
        self.assertIn('reclaimableDiagnosticBytes', report)
        candidate = next(c for c in cleanup.inventory(self.root, now=self.now)['candidates'] if str(receipt) in c['paths'])
        self.assertEqual(candidate['resources'], [str(receipt)])

    def test_exclusive_quarantine_does_not_replace_an_existing_destination(self):
        original, destination = self.base / 'original', self.base / 'destination'
        original.mkdir(); destination.mkdir()
        with self.assertRaises(FileExistsError):
            cleanup.rename_exclusive(original, destination)
        self.assertTrue(original.is_dir())
        self.assertTrue(destination.is_dir())

    def interrupted_journal(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def interrupt(path, **kwargs):
            if pathlib.Path(path).name.startswith('.gitx-cleanup-trash-'):
                raise OSError('interrupted')
            return remove(path, **kwargs)
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=interrupt):
            self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'partial')
        journal = next((cleanup.state_directory(self.root) / 'journals').glob('*.json'))
        return old, receipt, journal, cleanup.read_json(journal)

    def test_retry_refuses_replaced_quarantine_and_preserves_journal(self):
        old, receipt, journal, value = self.interrupted_journal()
        quarantine = pathlib.Path(value['quarantinePath'])
        preserved = self.base / 'preserved-quarantine'
        quarantine.rename(preserved)
        quarantine.mkdir()
        (quarantine / 'foreign').write_text('keep')
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue((quarantine / 'foreign').exists())
        self.assertTrue(preserved.exists())
        self.assertTrue(journal.exists())
        self.assertFalse(old.exists())

    def test_retry_refuses_original_redirect_and_symlinked_quarantine(self):
        old, receipt, journal, value = self.interrupted_journal()
        quarantine = pathlib.Path(value['quarantinePath'])
        outside = self.base / 'preserved'
        quarantine.rename(outside)
        quarantine.symlink_to(outside)
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'partial')
        self.assertTrue((outside / 'receipt.json').exists())
        quarantine.unlink(); outside.rename(quarantine)
        old.mkdir(); (old / 'foreign').write_text('keep')
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'partial')
        self.assertTrue((old / 'foreign').exists())
        self.assertTrue(journal.exists())

    def test_journal_retries_the_crash_between_rename_and_state_publication(self):
        old, receipt, journal, value = self.interrupted_journal()
        value['state'] = 'prepared'
        self.write(journal, value)
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')
        self.assertFalse(pathlib.Path(value['quarantinePath']).exists())
        self.assertEqual(cleanup.read_json(journal)['state'], 'complete')

    def test_new_protection_references_during_discovery_defer_deletion(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def discover(*args, **kwargs):
            report = original(*args, **kwargs)
            self.write(cleanup.records.common_directory(self.root) / 'ledger.json',
                       {'items': {'new': {'recoverySources': [str(old)]}}})
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=discover):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertIn('protection-boundaries-changed', str(report['skipped']))

    def test_reference_alias_retargeted_during_discovery_defers_deletion(self):
        old = self.run_directory('old')
        outside = self.base / 'outside'
        (outside / 'Results').mkdir(parents=True)
        (outside / 'Results/output').write_text('keep')
        alias = self.base / 'alias'
        alias.symlink_to(outside)
        self.write(cleanup.records.common_directory(self.root) / 'ledger.json',
                   {'items': {'reference': {'recoverySources': [str(alias / 'Results/output')]}}})
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def discover(*args, **kwargs):
            report = original(*args, **kwargs)
            alias.unlink(); alias.symlink_to(old)
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=discover):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertTrue((outside / 'Results/output').exists())

    def test_recursive_removal_holds_only_candidate_and_cleanup_state(self):
        self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def inspect(path, **kwargs):
            if not pathlib.Path(path).name.startswith('.gitx-cleanup-trash-'):
                return remove(path, **kwargs)
            with session.Leases([str(self.root / 'build/GitX.app'),
                                 str(cleanup.records.common_directory(self.root) / 'ledger.json'),
                                 f'desktop:{os.getuid()}'],
                                {'runId': 'independent', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
                pass
            return remove(path, **kwargs)
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=inspect):
            self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')

    def test_unfinished_reports_and_journals_survive_report_rotation(self):
        _, receipt, journal, _ = self.interrupted_journal()
        reports = cleanup.state_directory(self.root) / 'reports'
        for index in range(23):
            self.write(reports / f'old-{index:02}.json', {'status': 'complete'})
        partial = reports / 'pending-recovery.json'
        self.write(partial, {'status': 'partial'})
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')
        self.assertTrue(partial.exists())
        self.assertTrue(journal.exists())
        self.assertEqual(len(list(reports.glob('*.json'))), 20)
        self.assertEqual(sum(cleanup.read_json(p)['status'] == 'complete' for p in reports.glob('*.json')), 19)

    def test_foreign_hook_with_owned_marker_is_preserved(self):
        hook = self.root / '.git/hooks/post-commit'
        content = '#!/bin/sh\n# GitX commit-triggered cleanup v1\necho foreign\n'
        hook.write_text(content)
        with self.assertRaises(ValueError):
            cleanup.install_hook(self.root)
        self.assertEqual(hook.read_text(), content)

    def test_merge_applypatch_and_rewrite_notifications_queue_current_head(self):
        cleanup.install_hook(self.root)
        branch = session.git(self.root, 'branch', '--show-current')
        self.git('checkout', '-qb', 'side')
        (self.root / 'side.txt').write_text('side')
        self.git('add', 'side.txt'); self.git('commit', '-qm', 'side')
        patch = self.git('format-patch', '-1', '--stdout').stdout
        self.git('checkout', '-q', branch)
        cleanup.pending_path(self.root).unlink()
        self.git('merge', '--no-ff', '-qm', 'merged', 'side')
        self.assertEqual(cleanup.read_json(cleanup.pending_path(self.root))['head'], session.git(self.root, 'rev-parse', 'HEAD'))
        self.git('checkout', '-qb', 'apply', 'HEAD~1')
        cleanup.pending_path(self.root).unlink()
        subprocess.run(['git', '-C', str(self.root), 'am'], input=patch, text=True, capture_output=True, check=True)
        queued = cleanup.read_json(cleanup.pending_path(self.root))
        self.assertEqual(queued['head'], session.git(self.root, 'rev-parse', 'HEAD'))
        subprocess.run([str(self.root / '.git/hooks/post-rewrite'), 'rebase'], cwd=self.root,
                       input='old new\n', text=True, capture_output=True, check=True)
        self.assertEqual(cleanup.read_json(cleanup.pending_path(self.root))['token'], queued['token'])

    def test_owned_generic_diagnostics_and_legacy_inventory_are_distinguished(self):
        owned = self.artifact / 'diagnostics/owned'
        self.write(owned / 'diagnostic-owner.json', {'schemaVersion': 1, 'kind': 'gitx-diagnostics',
            'checkout': str(self.root), 'runId': 'owned', 'status': 'passed'})
        (owned / 'output').write_bytes(b'x' * 16384)
        legacy = self.artifact / 'diagnostics/legacy'
        legacy.mkdir(); (legacy / 'output').write_bytes(b'x' * 16384)
        self.stamp(self.artifact / 'diagnostics', 10)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(owned), self.candidate_paths(report))
        self.assertNotIn(str(legacy), self.candidate_paths(report))
        self.assertTrue(any(str(legacy) in item['paths'] and 'unmanaged' in item['reason'] for item in report['retained']))
        self.assertGreater(report['protectedDiagnosticBytes'], 0)

    def test_malformed_coordination_and_generic_metadata_is_isolated(self):
        remaining = self.run_directory('remaining')
        coordination = self.artifact / 'Coordination/broken.json'
        self.write(coordination, {'runId': 'broken', 'receipt': str(coordination),
            'entry': str(self.root / 'scripts/dev_workflow.py'), 'status': 'passed', 'evidence': []})
        generic = self.artifact / 'diagnostics/broken'
        self.write(generic / 'diagnostic-owner.json', {'schemaVersion': 1, 'kind': 'gitx-diagnostics',
            'checkout': str(self.root), 'runId': 'broken', 'status': 'passed', 'buildPaths': []})
        self.stamp(self.artifact, 10)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(remaining), self.candidate_paths(report))
        self.assertTrue(report['discoveryErrors'])
        self.assertTrue(any(str(coordination) in str(item['paths']) for item in report['retained']))
        self.assertTrue(any(str(generic) in str(item['paths']) for item in report['retained']))

    def test_vanished_cache_is_isolated_from_the_remaining_inventory(self):
        remaining = self.run_directory('remaining')
        cache = self.legacy_cache('vanished')
        identity = cleanup.directory_identity
        def inspect(path):
            if pathlib.Path(path) == cache:
                raise FileNotFoundError('cache vanished')
            return identity(path)
        with mock.patch.object(cleanup, 'directory_identity', side_effect=inspect):
            report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(remaining), self.candidate_paths(report))
        self.assertFalse(report['discoveryErrors'])
        self.assertTrue(report['entryErrors'])

    def test_tracked_binary_screenshots_do_not_create_false_discovery_failures(self):
        old = self.run_directory('old')
        screenshot = self.root / 'docs/diagnostics/screenshot.png'
        screenshot.parent.mkdir(parents=True)
        screenshot.write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        self.git('add', 'docs'); self.git('commit', '-qm', 'tracked screenshot')
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(old), self.candidate_paths(report))
        self.assertFalse(report['discoveryErrors'])

    def test_hook_queues_commits_and_amend_without_pruning(self):
        old = self.run_directory('old')
        cleanup.install_hook(self.root)
        cleanup.install_hook(self.root)
        self.git('commit', '--allow-empty', '-qm', 'work')
        first = cleanup.read_json(cleanup.pending_path(self.root))
        self.assertEqual(first['head'], session.git(self.root, 'rev-parse', 'HEAD'))
        self.assertTrue(old.exists())
        self.git('commit', '--amend', '--allow-empty', '-qm', 'amended work')
        second = cleanup.read_json(cleanup.pending_path(self.root))
        self.assertNotEqual(first['head'], second['head'])
        self.assertNotEqual(first['token'], second['token'])
        self.assertTrue(old.exists())

    def test_hook_refuses_conflicts_and_configured_hooks(self):
        hook = self.root / '.git/hooks/post-commit'
        hook.write_text('# unrelated hook')
        with self.assertRaisesRegex(ValueError, 'Refusing'):
            cleanup.install_hook(self.root)
        self.assertEqual(hook.read_text(), '# unrelated hook')
        hook.unlink()
        self.git('config', 'core.hooksPath', 'my-hooks')
        with self.assertRaisesRegex(ValueError, 'core.hooksPath'):
            cleanup.install_hook(self.root)

    def test_preview_is_read_only_and_observes_seven_day_boundary(self):
        old = self.run_directory('old', 8)
        recent = self.run_directory('recent', 6)
        boundary = self.run_directory('boundary', 7)
        before = cleanup.fingerprint(self.root)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(old), self.candidate_paths(report))
        self.assertNotIn(str(recent), self.candidate_paths(report))
        self.assertNotIn(str(boundary), self.candidate_paths(report))
        self.assertEqual(cleanup.fingerprint(self.root), before)
        self.assertFalse(self.locks.exists())
        self.assertFalse(cleanup.state_directory(self.root).exists())

    def test_budget_evicts_oldest_recent_unprotected_runs(self):
        first = self.run_directory('first', 5)
        second = self.run_directory('second', 4)
        config = json.loads((self.root / 'scripts/verification-config.json').read_text())
        config['cleanup']['diagnosticBudgetBytes'] = cleanup.fingerprint(second)['bytes'] + 8192
        self.write(self.root / 'scripts/verification-config.json', config)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(first), self.candidate_paths(report))
        self.assertNotIn(str(second), self.candidate_paths(report))

    def test_workflow_children_and_ledger_dependencies_are_protected_together(self):
        parent = self.run_directory('parent')
        child = self.run_directory('child')
        legacy = self.legacy_cache('protected-legacy')
        self.write(parent / 'workflow.json', {'schemaVersion': 2, 'status': 'failed', 'steps': [{'receipt': str(child / 'receipt.json')}]})
        child_value = cleanup.read_json(child / 'receipt.json')
        child_value['buildPaths'] = {'derivedData': str(legacy)}
        self.write(child / 'receipt.json', child_value)
        self.write(self.root / '.git/gitx-workflow/ledger.json', {'items': {'work': {'verificationReceipts': [str(child / 'receipt.json')]}}})
        self.stamp(parent, 10)
        self.stamp(child, 10)
        report = cleanup.preview(self.root, now=self.now)
        candidates = self.candidate_paths(report)
        self.assertFalse({str(parent), str(child), str(legacy)} & candidates)

    def test_unprotected_workflow_is_evicted_as_a_group(self):
        parent = self.run_directory('parent')
        child = self.run_directory('child')
        self.write(parent / 'workflow.json', {'schemaVersion': 2, 'status': 'passed', 'steps': [{'receipt': str(child / 'receipt.json')}]})
        self.stamp(parent, 10)
        report = cleanup.preview(self.root, now=self.now)
        group = next(c for c in report['candidates'] if str(parent) in c['paths'])
        self.assertEqual(set(group['paths']), {str(parent), str(child)})

    def test_newest_failure_backup_unknown_and_symlink_are_preserved(self):
        failed = self.run_directory('failed', 10, 'failed')
        older_failed = self.run_directory('older-failed', 12, 'failed')
        backup_run = self.run_directory('backup')
        backup = backup_run / 'previous-Half Dark.app'
        backup.mkdir()
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'valuable').write_text('keep')
        (self.artifact / 'alias').symlink_to(outside)
        unknown = self.artifact / 'unknown'
        unknown.mkdir()
        self.stamp(backup_run, 10)
        report = cleanup.preview(self.root, now=self.now)
        self.assertNotIn(str(failed), self.candidate_paths(report))
        self.assertIn(str(older_failed), self.candidate_paths(report))
        self.assertNotIn(str(backup_run), self.candidate_paths(report))
        self.assertNotIn(str(unknown), self.candidate_paths(report))
        self.assertTrue((outside / 'valuable').exists())

    def legacy_cache(self, name):
        p = self.root / 'build' / name
        p.mkdir(parents=True)
        (p / 'Build').mkdir()
        (p / 'Build/object').write_bytes(b'object')
        (p / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(self.root / 'GitX.xcworkspace')}))
        self.stamp(p, 10)
        return p

    def test_relocated_cache_legacy_cache_and_other_checkout_boundaries(self):
        warm = pathlib.Path(self.cache_paths()['derivedData'])
        warm.mkdir(parents=True)
        self.stamp(warm, 10)
        obsolete = warm.parents[3] / ('b' * 16) / 'Debug/plain/DerivedData'
        obsolete.mkdir(parents=True)
        self.stamp(obsolete, 10)
        other = session.verification_cache_root(self.root) / ('c' * 16) / ('b' * 16) / 'Debug/plain/DerivedData'
        other.mkdir(parents=True)
        self.stamp(other, 10)
        legacy = self.legacy_cache('old-build')
        foreign = self.legacy_cache('foreign-build')
        (foreign / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': '/another/repository/project'}))
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(obsolete), self.candidate_paths(report))
        self.assertIn(str(legacy), self.candidate_paths(report))
        self.assertNotIn(str(warm), self.candidate_paths(report))
        self.assertNotIn(str(other), self.candidate_paths(report))
        self.assertNotIn(str(foreign), self.candidate_paths(report))

    def test_legacy_metadata_link_is_unknown(self):
        cache = self.root / 'build/legacy'
        cache.mkdir(parents=True)
        (cache / 'source.txt').write_text('unknown contents')
        outside = self.base / 'ownership.plist'
        outside.write_bytes(plistlib.dumps({'WorkspacePath': str(self.root / 'GitX.xcworkspace')}))
        metadata = cache / 'info.plist'
        metadata.symlink_to(outside)
        self.stamp(cache, 10)
        when = self.now - 10 * 86400
        os.utime(metadata, (when, when), follow_symlinks=False)
        report = cleanup.preview(self.root, now=self.now)
        self.assertNotIn(str(cache), self.candidate_paths(report))
        self.assertTrue(any(str(cache) in item['paths'] and item['reason'] == 'unknown build directory'
                            for item in report['retained']))

    def test_unknown_receipt_metadata_is_retained(self):
        paths = []
        for i, value in enumerate(({}, {'schemaVersion': 999, 'status': 'passed'},
                                   {'schemaVersion': 2, 'status': 'unknown'},
                                   {'schemaVersion': True, 'status': 'passed'},
                                   {'schemaVersion': 2, 'status': []})):
            path = self.run_directory(f'unknown-{i}')
            self.write(path / 'receipt.json', value)
            self.stamp(path, 10)
            paths.append(str(path))
        report = cleanup.preview(self.root, now=self.now)
        self.assertFalse(set(paths) & self.candidate_paths(report))
        self.assertTrue(all(any(path in item['paths'] and 'unknown' in item['reason']
                                for item in report['retained']) for path in paths))

    def test_gate_rejects_partial_failed_stale_inputs_and_changed_app(self):
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.read_json(receipt)
        for changes in ({'scope': 'partial'}, {'status': 'failed'}, {'evidenceStatus': 'invalid'}, {'selectedChecks': []}):
            self.write(receipt, original | changes)
            self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'deferred')
            self.assertTrue(cleanup.pending_path(self.root).exists())
        self.write(receipt, original)
        (self.root / 'source.txt').write_text('changed')
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'deferred')
        (self.root / 'source.txt').write_text('source')
        receipt = self.valid_receipt()
        (self.root / 'build/GitX.app/binary').write_text('replaced')
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'deferred')

    def test_successful_cleanup_clears_pending_and_preserves_current_proof(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'complete')
        self.assertGreater(report['reclaimedBytes'], 0)
        self.assertFalse(old.exists())
        self.assertTrue(receipt.exists())
        self.assertTrue((self.root / 'build/GitX.app/binary').exists())
        self.assertFalse(cleanup.pending_path(self.root).exists())
        self.assertTrue(pathlib.Path(report['report']).exists())

    def test_busy_run_is_skipped_then_retried(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        with session.Leases([str(old)], {'runId': 'other', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')
        self.assertFalse(old.exists())

    def test_deletion_error_preserves_pending_for_retry(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def fail_candidate(path, **kwargs):
            if pathlib.Path(path).name.startswith('.gitx-cleanup-trash-'):
                raise OSError('disk error')
            return remove(path, **kwargs)
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=fail_candidate):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertFalse(old.exists())
        self.assertTrue(list(old.parent.glob('.gitx-cleanup-trash-*')))
        self.assertTrue(cleanup.pending_path(self.root).exists())
        self.assertEqual(cleanup.run_cleanup(self.root, receipt)['status'], 'complete')

    def test_newer_commit_during_inventory_defers_deletion(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def changed(*args, **kwargs):
            report = original(*args, **kwargs)
            self.git('commit', '--allow-empty', '-qm', 'new work')
            cleanup.queue_commit(self.root)
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=changed):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_source_edit_during_inventory_prevents_deletion(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def changed(*args, **kwargs):
            report = original(*args, **kwargs)
            (self.root / 'source.txt').write_text('edited during inventory')
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=changed):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_staged_app_change_during_inventory_prevents_deletion(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def changed(*args, **kwargs):
            report = original(*args, **kwargs)
            (self.root / 'build/GitX.app/binary').write_bytes(b'changed app')
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=changed):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_manual_cleanup_requires_lease_on_verified_app(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        app = self.root / 'build/GitX.app'
        with session.Leases([str(app)], {'runId': 'staging', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
            with self.assertRaises(session.ResourceBusy):
                cleanup.run_cleanup(self.root, receipt, inherited={})
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_source_edit_between_deletions_preserves_remaining_candidates(self):
        first = self.run_directory('first', 12)
        second = self.run_directory('second', 10)
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        remove = shutil.rmtree
        def changed(path, **kwargs):
            remove(path, **kwargs)
            if pathlib.Path(path).name.startswith('.gitx-cleanup-trash-'):
                (self.root / 'source.txt').write_text('edited during deletion')
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=changed):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())

    def test_directory_replacement_after_inventory_is_skipped(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        original = cleanup.inventory
        def changed(*args, **kwargs):
            report = original(*args, **kwargs)
            (old / 'Results/output').write_text('changed after inventory')
            return report
        with mock.patch.object(cleanup, 'inventory', side_effect=changed):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())

    def test_commit_verify_cleanup_flow_and_report_retention(self):
        self.commands[:] = [('check', ['fixture-check.sh']), ('stage-debug', ['fixture-stage.sh'])]
        old = self.run_directory('old')
        cleanup.install_hook(self.root)
        self.git('commit', '--allow-empty', '-qm', 'verified work')
        reports = cleanup.state_directory(self.root) / 'reports'
        for i in range(22):
            self.write(reports / f'20000101-{i:02}.json', {'old': True, 'status': 'complete'})
        def execute(command, **kwargs):
            self.assertTrue(old.exists())
            if command == ['fixture-stage.sh']:
                app = self.root / 'build/GitX.app'
                app.mkdir(parents=True)
                (app / 'binary').write_bytes(b'verified app')
            return 0
        args = workflow.parser().parse_args(['verify', '--run-id', 'end-to-end'])
        with mock.patch.object(session, 'supervise', side_effect=execute), \
                mock.patch.object(session, 'toolchain_identity', return_value='fixture'):
            self.assertEqual(workflow.verify(args), 0)
        self.assertFalse(old.exists())
        self.assertFalse(cleanup.pending_path(self.root).exists())
        self.assertEqual(len(list(reports.glob('*.json'))), 20)
        receipt = cleanup.read_json(self.artifact / 'end-to-end/workflow.json')
        self.assertEqual(receipt['status'], 'passed')
        self.assertTrue((self.root / 'build/GitX.app/binary').exists())

    def test_newest_report_survives_reports_created_in_the_same_second(self):
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        reports = cleanup.state_directory(self.root) / 'reports'
        instant = cleanup.dt.datetime(2026, 10, 9, 12, 0, 0, 500000, tzinfo=cleanup.dt.timezone.utc)
        prefix = instant.strftime('%Y%m%dT%H%M%S')
        for i in range(20):
            self.write(reports / f'{prefix}-f{i:07}.json', {'old': True, 'status': 'complete'})
        with mock.patch.object(cleanup.dt, 'datetime', wraps=cleanup.dt.datetime) as clock, \
                mock.patch.object(cleanup.uuid, 'uuid4', return_value=mock.Mock(hex='0' * 32)):
            clock.now.return_value = instant
            result = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(pathlib.Path(result['report']).is_file(), 'The newly saved report must survive retention')
        self.assertEqual(len(list(reports.glob('*.json'))), 20)

    def test_report_directory_symlink_prevents_deletion_and_external_writes(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        reports = cleanup.state_directory(self.root) / 'reports'
        outside = self.base / 'outside-reports'
        outside.mkdir()
        for i in range(21):
            self.write(outside / f'20000101-{i:02}.json', {'source': True})
        reports.symlink_to(outside, target_is_directory=True)
        original = {p.name: p.read_bytes() for p in outside.iterdir()}
        with self.assertRaisesRegex(ValueError, 'symlink cleanup state'):
            cleanup.run_cleanup(self.root, receipt)
        self.assertTrue(old.exists())
        self.assertEqual({p.name: p.read_bytes() for p in outside.iterdir()}, original)

    def test_queue_refuses_symlink_workflow_state(self):
        outside = self.base / 'outside-state'
        outside.mkdir()
        cleanup.records.common_directory(self.root).symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink cleanup state'):
            cleanup.queue_commit(self.root)
        self.assertEqual(list(outside.iterdir()), [])

    def test_busy_cache_inside_run_prevents_parent_deletion(self):
        old = self.run_directory('old')
        cache = old / 'DerivedData'
        cache.mkdir()
        value = cleanup.read_json(old / 'receipt.json')
        value['buildPaths'] = {'derivedData': str(cache)}
        self.write(old / 'receipt.json', value)
        self.stamp(old, 10)
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        with session.Leases([str(cache)], {'runId': 'cache-owner', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(cache.exists())

    def test_ledger_symlink_reference_protects_its_container(self):
        old = self.run_directory('old')
        outside = self.base / 'outside'
        outside.write_text('keep')
        link = old / 'attachment'
        link.symlink_to(outside)
        self.write(self.root / '.git/gitx-workflow/ledger.json', {'items': {'work': {'verificationReceipts': [str(link)]}}})
        self.stamp(old, 10)
        self.assertNotIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_tracked_generated_file_is_never_pruned(self):
        old = self.run_directory('old')
        self.git('add', '-f', str(old / 'Results/output'))
        self.git('commit', '-qm', 'tracked recovery file')
        self.stamp(old, 10)
        self.assertNotIn(str(old), self.candidate_paths(cleanup.preview(self.root, now=self.now)))

    def test_soft_budget_reports_protected_excess(self):
        failed = self.run_directory('failed', 10, 'failed')
        config_path = self.root / 'scripts/verification-config.json'
        config = cleanup.read_json(config_path)
        config['cleanup']['diagnosticBudgetBytes'] = 1
        self.write(config_path, config)
        report = cleanup.preview(self.root, now=self.now)
        self.assertGreater(report['protectedExcessBytes'], 0)
        self.assertNotIn(str(failed), self.candidate_paths(report))

    def test_fingerprint_rejects_a_lock_removed_after_directory_enumeration(self):
        directory = self.base / 'changing-inventory'
        directory.mkdir()
        lock = directory / 'maintenance.lock'
        lock.write_text('owned by another writer')
        unrelated = self.base / 'unrelated'
        unrelated.write_text('preserve')
        listdir = os.listdir

        def remove_after_enumeration(descriptor):
            entries = listdir(descriptor)
            if 'maintenance.lock' in entries:
                lock.unlink()
            return entries

        with mock.patch.object(cleanup.os, 'listdir', side_effect=remove_after_enumeration):
            with self.assertRaises(FileNotFoundError) as failure:
                cleanup.fingerprint(directory)
        self.assertEqual(failure.exception.filename, 'maintenance.lock')
        self.assertEqual(unrelated.read_text(), 'preserve')

    def test_independent_fixture_git_mutations_inherit_persisted_maintenance_suppression(self):
        environment = fixture_git_environment()
        for key, expected in [('maintenance.auto', 'false'), ('gc.auto', '0')]:
            result = subprocess.run(['git', '-C', str(self.root), 'config', '--local', '--get', key],
                                    env=environment, check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), expected)
        trace = self.base / 'independent-git-events.jsonl'
        subprocess.run(['git', '-C', str(self.root), 'commit', '--allow-empty', '-qm', 'independent mutation'],
                       env=environment | {'GIT_TRACE2_EVENT': str(trace)}, check=True, capture_output=True, text=True)
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        automatic = [event for event in events if event.get('event') == 'child_start'
                     and '--auto' in event.get('argv', [])
                     and any(name in event.get('argv', []) for name in ['maintenance', 'gc'])]
        self.assertEqual(automatic, [])
        self.assertEqual(self.git('log', '-1', '--format=%s').stdout.strip(), 'independent mutation')

    def test_fixture_git_commits_do_not_start_background_housekeeping(self):
        self.git('config', 'maintenance.auto', 'true')
        self.git('config', 'gc.auto', '1')
        trace = self.base / 'fixture-git-events.jsonl'
        run = subprocess.run

        def traced(command, *args, **kwargs):
            kwargs['env'] = dict(kwargs.get('env', os.environ)) | {'GIT_TRACE2_EVENT': str(trace)}
            return run(command, *args, **kwargs)

        with mock.patch.object(subprocess, 'run', side_effect=traced):
            self.git('commit', '--allow-empty', '-qm', 'housekeeping fixture')
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        self.assertTrue(any(event.get('event') == 'start' and 'commit' in event.get('argv', [])
                            for event in events))
        automatic = [event for event in events if event.get('event') == 'child_start'
                     and '--auto' in event.get('argv', [])
                     and any(name in event.get('argv', []) for name in ['maintenance', 'gc'])]
        self.assertEqual(automatic, [], 'Fixture Git must not leave a writer racing read-only fingerprints')
        self.assertEqual(self.git('log', '-1', '--format=%s').stdout.strip(), 'housekeeping fixture')
        self.assertEqual(self.git('status', '--porcelain').stdout, '')

    def test_cli_preview_does_not_create_bytecode_or_cleanup_state(self):
        self.run_directory('old')
        before = cleanup.fingerprint(self.root)
        result = subprocess.run([session.sys.executable, str(self.root / 'scripts/dev_workflow.py'), 'cleanup', 'preview'],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['status'], 'preview')
        self.assertEqual(cleanup.fingerprint(self.root), before)

    def test_invalid_policy_and_corrupt_ledger_prevent_deletion(self):
        old = self.run_directory('old')
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        ledger = self.root / '.git/gitx-workflow/ledger.json'
        ledger.write_text('broken JSON')
        report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(report['discoveryErrors'])
        self.assertTrue(old.exists())
        self.assertTrue(cleanup.pending_path(self.root).exists())
        ledger.unlink()
        config_path = self.root / 'scripts/verification-config.json'
        config = cleanup.read_json(config_path)
        config['cleanup']['retentionDays'] = -1
        self.write(config_path, config)
        with self.assertRaisesRegex(ValueError, 'positive integers'):
            cleanup.preview(self.root)

    def test_run_without_pending_commit_creates_nothing(self):
        before = cleanup.fingerprint(self.root)
        report = cleanup.run_cleanup(self.root, self.artifact / 'absent/workflow.json')
        self.assertEqual(report['reason'], 'no-pending-commit')
        self.assertEqual(cleanup.fingerprint(self.root), before)

    def test_verification_producer_holds_its_run_directory_lease(self):
        entry = self.root / 'scripts/xcodebuild.sh'
        entry.write_text('#!/bin/sh\nexit 0\n')
        run = self.artifact / 'leased-run'
        def execute(*args, **kwargs):
            with self.assertRaises(session.ResourceBusy):
                with session.Leases([str(run)], {'runId': 'competitor', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
                    pass
            return 0
        with mock.patch.object(session, 'supervise', side_effect=execute):
            self.assertEqual(session.guard(entry, ['build', '--run-id', 'leased-run']), 0)
        receipt = cleanup.read_json(self.artifact / 'Coordination/leased-run.json')
        self.assertIn(str(run), receipt['resources'])
        with session.Leases([str(run)], {'runId': 'after', 'pid': os.getpid(), 'receipt': 'other'}, inherited={}):
            pass

    def test_gate_checks_final_shared_cache_state_and_every_test_result(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('check', [command, 'build-tests']), ('stage-debug', [command, 'build', '--stage-app'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        current = session.inputs(self.root)
        cache = self.legacy_cache('shared')
        result = self.artifact / 'first/Results/test.xcresult'
        result.mkdir(parents=True)
        (result / 'test-data').write_text('original result')
        for i, step in enumerate(value['steps']):
            child_path = self.artifact / f'child-{i}/receipt.json'
            evidence = {'status': 'valid', 'inputsBefore': current, 'inputsAfter': current,
                        'dependencyProducts': {}, 'products': {'snapshot': i}, 'results': {}}
            if i == 0:
                evidence['dependencyProducts'] = {'earlier-build': 'superseded'}
                evidence['results'][str(result.relative_to(self.root))] = session.tree_identity(result)
            self.write(child_path, {'schemaVersion': 2, 'status': 'passed', 'evidence': evidence,
                                  'finishedAt': f'2026-10-09T12:00:0{i}Z', 'buildPaths': {'derivedData': str(cache)}})
            step['receipt'] = str(child_path)
        self.write(receipt, value)
        with mock.patch.object(session, 'product_identity', return_value={'snapshot': 1}):
            self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])
            (result / 'test-data').write_text('changed result')
            self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'child-artifacts-changed')
        (result / 'test-data').write_text('original result')
        # Restore the result identity after rewriting; mutable caches must still match.
        first = self.artifact / 'child-0/receipt.json'
        child = cleanup.read_json(first)
        child['evidence']['results'][str(result.relative_to(self.root))] = session.tree_identity(result)
        self.write(first, child)
        with mock.patch.object(session, 'product_identity', return_value={'snapshot': 2}):
            self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'final-cache-products-changed')
        with mock.patch.object(session, 'product_identity', return_value={'snapshot': 1}), mock.patch.object(
                session, 'dependency_products', return_value={'modified-library': {}}):
            self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'final-cache-products-changed')

    def test_child_receipt_and_profile_guards_preserve_pending_work(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('check', [command, 'test', 'core']), ('stage-debug', [command, 'build', '--stage-app'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'missing-child-receipt')
        value['steps'][0]['receipt'] = str(self.base / 'external/receipt.json')
        self.write(receipt, value)
        self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'child-receipt-outside-checkout')
        child_path = self.artifact / 'child/receipt.json'
        value['steps'][0]['receipt'] = str(child_path)
        self.write(receipt, value)
        self.write(child_path, {'schemaVersion': 2, 'status': 'failed'})
        self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'invalid-child-evidence')
        self.assertTrue(cleanup.pending_path(self.root).exists())
        self.write(receipt, value | {'profile': 'partial'})
        self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'full-successful-verification-required')

    def test_final_package_products_are_validated_after_all_package_checks(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('check', [command, 'test', 'core']), ('stage-debug', [command, 'build', '--stage-app'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        current = session.inputs(self.root)
        scratch = self.base / 'scratch'
        for i, step in enumerate(value['steps']):
            child_path = self.artifact / f'child-{i}/receipt.json'
            self.write(child_path, {'schemaVersion': 2, 'status': 'passed', 'finishedAt': f'2026-10-09T12:00:0{i}Z', 'buildPaths': {'swiftPM': str(scratch)},
                       'evidence': {'status': 'valid', 'inputsBefore': current, 'inputsAfter': current,
                                    'dependencyProducts': {}, 'packageProducts': {'snapshot': i}, 'results': {}}})
            step['receipt'] = str(child_path)
        self.write(receipt, value)
        with mock.patch.object(session, 'package_products', return_value={'snapshot': 1}):
            self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])
        with mock.patch.object(session, 'package_products', return_value={'snapshot': 2}):
            self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'final-cache-products-changed')

    def test_newest_backup_uses_staging_run_time_not_original_bundle_time(self):
        older = self.run_directory('older-stage', 12)
        newer = self.run_directory('newer-stage', 10)
        for run in (older, newer):
            (run / 'previous-Half Dark.app').mkdir()
        self.stamp(older, 12)
        self.stamp(newer, 10)
        os.utime(older / 'previous-Half Dark.app', (self.now, self.now))
        config_path = self.root / 'scripts/verification-config.json'
        config = cleanup.read_json(config_path)
        config['cleanup']['diagnosticBudgetBytes'] = 1
        self.write(config_path, config)
        report = cleanup.preview(self.root, now=self.now)
        self.assertIn(str(older), self.candidate_paths(report))
        self.assertNotIn(str(newer), self.candidate_paths(report))

    def test_completed_analyzer_does_not_require_its_deleted_temporary_products(self):
        command = str(self.root / 'scripts/xcodebuild.sh')
        self.commands[:] = [('analyze', [command, 'analyze']), ('stage-debug', ['fixture-stage'])]
        cleanup.queue_commit(self.root)
        receipt = self.valid_receipt()
        value = cleanup.read_json(receipt)
        current = session.inputs(self.root)
        child = self.artifact / 'analyzer/receipt.json'
        logs = []
        artifacts = {}
        for name in ('analyze', 'analyzer-policy', 'swiftlint-analyze'):
            log = child.parent / (name + '.log')
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text('passed diagnostic')
            logs.append({'name': name, 'status': 'passed', 'exitCode': 0, 'log': str(log)})
            artifacts[str(log)] = session.tree_identity(log)
        self.write(child, {'schemaVersion': 2, 'status': 'passed', 'invocation': {'preset': 'analyze'},
                          'steps': logs,
                          'buildPaths': {'derivedData': str(self.base / 'AnalyzerDerivedData.deleted')},
                          'evidence': {'status': 'valid', 'inputsBefore': current, 'inputsAfter': current,
                                       'dependencyProducts': {}, 'products': {'temporary.app': 'removed'},
                                       'results': {}, 'analysisArtifacts': artifacts}})
        value['steps'][0]['receipt'] = str(child)
        self.write(receipt, value)
        self.assertIsNone(cleanup.eligibility(self.root, receipt)[1])
        log.write_text('changed diagnostic')
        self.assertEqual(cleanup.eligibility(self.root, receipt)[1], 'child-artifacts-changed')

    def test_registered_nested_worktree_is_preserved_under_budget_pressure(self):
        old = self.run_directory('old')
        checkout = old / 'checkout'
        self.git('worktree', 'add', '-qb', 'nested', str(checkout))
        config_path = self.root / 'scripts/verification-config.json'
        config = cleanup.read_json(config_path)
        config['cleanup']['diagnosticBudgetBytes'] = 1
        self.write(config_path, config)
        report = cleanup.preview(self.root, now=self.now)
        self.assertNotIn(str(old), self.candidate_paths(report))
        self.assertTrue((checkout / '.git').exists())


if __name__ == '__main__':
    unittest.main()
