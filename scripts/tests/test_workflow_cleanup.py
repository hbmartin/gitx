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
        self.write(parent / 'workflow.json', {'status': 'failed', 'steps': [{'receipt': str(child / 'receipt.json')}]})
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
        self.write(parent / 'workflow.json', {'status': 'passed', 'steps': [{'receipt': str(child / 'receipt.json')}]})
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
            if pathlib.Path(path) == old:
                raise OSError('disk error')
            return remove(path, **kwargs)
        with mock.patch.object(cleanup.shutil, 'rmtree', side_effect=fail_candidate):
            report = cleanup.run_cleanup(self.root, receipt)
        self.assertEqual(report['status'], 'partial')
        self.assertTrue(old.exists())
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
            self.write(reports / f'20000101-{i:02}.json', {'old': True})
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
        with self.assertRaises(ValueError):
            cleanup.run_cleanup(self.root, receipt)
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


if __name__ == '__main__':
    unittest.main()
