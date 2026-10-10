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

from support import ROOT
import dev_workflow as workflow
import workflow_cleanup as cleanup
import workflow_session as session


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        (self.root / '.gitignore').write_text('artifacts/\nbuild/\n__pycache__/\n')
        (self.root / 'source.txt').write_text('source')
        (self.root / 'scripts').mkdir()
        for name in ('dev_workflow.py', 'workflow_session.py', 'workflow_records.py', 'workflow_cleanup.py', 'verification-config.json'):
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
        return subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True, text=True)

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
        (dependency / 'source.c').write_text('int value = 1;\n')
        dependency_git('add', '.')
        dependency_git('commit', '-qm', 'dependency fixture')
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', str(dependency), 'External/Fixture')
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
        self.assertTrue(report['discoveryErrors'])
        self.assertTrue(any(str(broken) in item['paths'] for item in report['retained']))

    def test_conclusively_abandoned_run_enters_retention(self):
        abandoned = self.run_directory('abandoned', status='running')
        value = cleanup.read_json(abandoned / 'receipt.json')
        value['producer'] = {'pid': 999999999, 'started': 'old identity'}
        self.write(abandoned / 'receipt.json', value)
        self.stamp(abandoned, 10)
        with mock.patch.object(session, 'producer_state', return_value='abandoned', create=True):
            self.assertIn(str(abandoned), self.candidate_paths(cleanup.preview(self.root, now=self.now)))
        for state in ['live', 'uncertain']:
            with mock.patch.object(session, 'producer_state', return_value=state, create=True):
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
        self.assertEqual(sum(cleanup.read_json(p)['status'] == 'complete' for p in reports.glob('*.json')), 20)

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
        self.assertTrue(report['discoveryErrors'])

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
        old = self.run_directory('old')
        cleanup.install_hook(self.root)
        self.git('commit', '--allow-empty', '-qm', 'verified work')
        reports = cleanup.state_directory(self.root) / 'reports'
        for i in range(22):
            self.write(reports / f'20000101-{i:02}.json', {'old': True, 'status': 'complete'})
        def execute(command, **kwargs):
            self.assertTrue(old.exists())
            if command == ['fixture-stage']:
                app = self.root / 'build/GitX.app'
                app.mkdir(parents=True)
                (app / 'binary').write_bytes(b'verified app')
            return 0
        args = workflow.parser().parse_args(['verify', '--run-id', 'end-to-end'])
        with mock.patch.object(session, 'supervise', side_effect=execute):
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
