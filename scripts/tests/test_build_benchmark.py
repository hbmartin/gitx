from __future__ import annotations

import unittest
import pathlib
import subprocess
import tempfile
from unittest import mock

from support import load_script, fixture_git_environment


class BuildBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("benchmark_build.py")

    def test_medians_use_all_samples(self) -> None:
        samples = [
            self.module.BuildSample(1, 120, 20),
            self.module.BuildSample(2, 80, 10),
            self.module.BuildSample(3, 100, 15),
        ]

        self.assertEqual(self.module.medians(samples), (100, 15))

    def test_thresholds_report_each_regression(self) -> None:
        failures = self.module.threshold_failures(
            11,
            6,
            cold_ceiling=10,
            warm_ceiling=5,
        )

        self.assertEqual(len(failures), 2)

    def test_current_or_faster_medians_pass(self) -> None:
        self.assertEqual(
            self.module.threshold_failures(
                self.module.COLD_CEILING_SECONDS,
                self.module.WARM_CEILING_SECONDS,
            ),
            [],
        )

    def test_cache_hits_count_diagnostic_hits_only(self):
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "build.log"
            log.write_text("remark: cache hit for key 123\nremark: CACHE HIT for key 456\ncache miss\n")
            self.assertEqual(self.module.cache_hits(log), 2)

    def test_short_cache_experiments_cannot_qualify(self):
        with self.assertRaisesRegex(ValueError, "five paired"):
            self.module.compare_cache(pathlib.Path("missing"), pathlib.Path("unused.json"), 4)

    def test_setup_failure_publishes_a_failed_experiment_before_cloning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "artifacts/results.json"
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text('{"defaultDeveloperDirectory":"/Xcode"}')
            with mock.patch.object(self.module.session, "cache_paths", return_value={"toolchain": "Xcode 27.0\nBuild version 27A1"}), \
                    mock.patch.object(self.module, "environment_fingerprint", return_value={}), \
                    mock.patch.object(self.module, "snapshot_checkout") as snapshot:
                status = self.module.compare_cache(root, output, 5)
            import json
            report = json.loads(output.read_text())
            self.assertEqual(status, 2)
            self.assertFalse(report["passed"])
            self.assertEqual(report["category"], "setup-failed")
            self.assertIn("libgit2.a", report["failures"][0])
            snapshot.assert_not_called()
            self.assertFalse(list(output.parent.glob("cache-logs-*")))

    def test_resource_contention_is_reported_without_allocating_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "artifacts/results.json"
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text('{"defaultDeveloperDirectory":"/Xcode"}')
            libraries = root / "External/objective-git/External"
            libraries.mkdir(parents=True)
            for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
                (libraries / name).write_text("owned dependency")
            lease = mock.MagicMock()
            lease.__enter__.side_effect = self.module.session.ResourceBusy("benchmark", {"runId": "other"})
            with mock.patch.object(self.module.session, "cache_paths", return_value={"toolchain": "Xcode 27.0\nBuild version 27A1"}), \
                    mock.patch.object(self.module, "environment_fingerprint", return_value={}), \
                    mock.patch.object(self.module.session, "inputs", return_value={}), \
                    mock.patch.object(self.module.session, "Leases", return_value=lease):
                status = self.module.compare_cache(root, output, 5)
            import json
            report = json.loads(output.read_text())
            self.assertEqual(status, 75)
            self.assertEqual(report["category"], "resource-busy")
            self.assertTrue(report["finishedAt"])
            self.assertFalse(list(output.parent.glob("cache-logs-*")))

    def test_malformed_configuration_publishes_a_setup_failure(self):
        for value in ("{}", "[]", '{"defaultDeveloperDirectory":null}'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory).resolve()
                output = root / "artifacts/report.json"
                (root / "scripts").mkdir()
                (root / "scripts/verification-config.json").write_text(value)
                with mock.patch.dict(self.module.os.environ, {}, clear=True):
                    self.assertEqual(self.module.compare_cache(root, output, 5), 2)
                import json
                report = json.loads(output.read_text())
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["category"], "setup-failed")
                self.assertTrue(report["finishedAt"])

    def test_edit_probes_use_an_independent_snapshot_with_current_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / "original"
            root.mkdir()
            environment = fixture_git_environment()
            def git(*arguments):
                subprocess.run(["git", "-C", str(root), *arguments], check=True,
                               capture_output=True, env=environment)
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (root / "Classes").mkdir()
            (root / "Classes/old.swift").write_text("old\n")
            (root / ".gitignore").write_text("*.a\n*.stamp\n")
            git("add", ".")
            git("commit", "-qm", "Fixture")
            git("mv", "Classes/old.swift", "Classes/renamed.swift")
            (root / "Classes/renamed.swift").write_text("current\n")
            (root / "Classes/new.swift").write_text("new\n")
            libraries = root / "External/objective-git/External"
            libraries.mkdir(parents=True)
            for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
                (libraries / name).write_text("dependency\n")
            destination = pathlib.Path(directory) / "snapshot"
            self.module.snapshot_checkout(root, destination)
            self.assertFalse((destination / "Classes/old.swift").exists())
            self.assertEqual((destination / "Classes/renamed.swift").read_text(), "current\n")
            self.assertEqual((destination / "Classes/new.swift").read_text(), "new\n")
            (destination / "Classes/renamed.swift").write_text("probe\n")
            self.assertEqual((root / "Classes/renamed.swift").read_text(), "current\n")

    def test_snapshot_and_execution_failures_are_typed_and_checkout_environment_is_sanitized(self):
        for snapshot_fails in (True, False):
            with self.subTest(snapshot_fails=snapshot_fails), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory).resolve()
                output = root / "artifacts/report.json"
                (root / "scripts").mkdir()
                (root / "scripts/verification-config.json").write_text('{"defaultDeveloperDirectory":"/Xcode"}')
                libraries = root / "External/objective-git/External"
                libraries.mkdir(parents=True)
                for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
                    (libraries / name).write_text("dependency")
                lease = mock.MagicMock()
                lease.__enter__.return_value.environment.return_value = {
                    "GIT_DIR": "/foreign", "GIT_INDEX_FILE": "/foreign-index",
                    "GIT_CONFIG_COUNT": "1", "GITX_RESOURCE_LEASES": "authenticated"}
                def run(*args, **options):
                    self.assertNotIn("GIT_DIR", options["env"])
                    self.assertNotIn("GIT_INDEX_FILE", options["env"])
                    self.assertEqual(options["env"]["GIT_CONFIG_COUNT"], "1")
                    self.assertEqual(options["env"]["GITX_RESOURCE_LEASES"], "authenticated")
                    return 19
                with mock.patch.object(self.module.session, "cache_paths", return_value={"toolchain": "Xcode 27.0\nBuild version 27A1"}), \
                        mock.patch.object(self.module, "environment_fingerprint", return_value={}), \
                        mock.patch.object(self.module.session, "inputs", return_value={}), \
                        mock.patch.object(self.module.session, "Leases", return_value=lease), \
                        mock.patch.object(self.module, "snapshot_checkout", side_effect=OSError("snapshot unavailable") if snapshot_fails else None), \
                        mock.patch.object(self.module.session, "supervise", side_effect=run):
                    status = self.module.compare_cache(root, output, 5)
                import json
                report = json.loads(output.read_text())
                self.assertEqual(status, 2 if snapshot_fails else 1)
                self.assertEqual(report["category"], "snapshot-failed" if snapshot_fails else "build-failed")
                self.assertTrue(report["finishedAt"])
                if not snapshot_fails:
                    self.assertEqual(len(report["logs"]), 1)
                    self.assertIn("exit 19", report["failures"][0])

    def test_fresh_products_preserve_the_owned_native_compilation_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = pathlib.Path(directory).resolve()
            derived = workspace / "DerivedData"
            cache = derived / "CompilationCache.noindex/builtin"
            cache.mkdir(parents=True)
            (cache / "cached-result").write_text("cache\n")
            products = derived / "Build/Products"
            products.mkdir(parents=True)
            (products / "app").write_text("product\n")
            self.module.reset_products(derived, workspace)
            self.assertEqual((cache / "cached-result").read_text(), "cache\n")
            self.assertFalse(products.exists())
            with self.assertRaises(ValueError):
                self.module.reset_products(workspace.parent, workspace)


    def assert_snapshot_symlink_preserves_metadata(self, *, tracked, source_referent_exists):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory).resolve()
            root = base / "source-root/repo"
            root.mkdir(parents=True)
            outside_source = base / "sentinel"
            if source_referent_exists:
                outside_source.write_text("source data")
            output = base / "output"
            output.mkdir()
            outside_destination = output / "sentinel"
            outside_destination.write_text("preserve destination")
            workspace = output / "owned-workspace"
            workspace.mkdir()
            destination = workspace / "source"
            link = root / "Resources/link.swift"
            link.parent.mkdir()
            (root / "source.txt").write_text("fixture")
            (root / ".gitignore").write_text("*.a\n*.stamp\n")
            if tracked:
                link.symlink_to("../../../sentinel")
            environment = fixture_git_environment()
            for arguments in (("init", "-q"), ("config", "user.name", "Fixture"),
                              ("config", "user.email", "fixture@example.invalid"),
                              ("add", "."), ("commit", "-qm", "Fixture")):
                subprocess.run(["git", "-C", str(root), *arguments], check=True,
                               capture_output=True, env=environment)
            if not tracked:
                link.symlink_to("../../../sentinel")
            libraries = root / "External/objective-git/External"
            libraries.mkdir(parents=True)
            for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
                (libraries / name).write_text("dependency")
            self.module.snapshot_checkout(root, destination)
            self.assertTrue((destination / "Resources/link.swift").is_symlink(), "Snapshot must preserve link metadata")
            self.assertEqual((destination / "Resources/link.swift").readlink().as_posix(), "../../../sentinel")
            self.assertEqual(outside_destination.read_text(), "preserve destination")
            if source_referent_exists:
                self.assertEqual(outside_source.read_text(), "source data")
            else:
                self.assertFalse(outside_source.exists())

    def test_tracked_snapshot_symlinks_preserve_metadata_and_external_referents(self):
        for exists in (True, False):
            with self.subTest(source_referent_exists=exists):
                self.assert_snapshot_symlink_preserves_metadata(tracked=True, source_referent_exists=exists)

    def test_untracked_snapshot_symlinks_preserve_metadata_and_external_referents(self):
        for exists in (True, False):
            with self.subTest(source_referent_exists=exists):
                self.assert_snapshot_symlink_preserves_metadata(tracked=False, source_referent_exists=exists)

    def test_edit_probe_refuses_external_symlink_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory).resolve()
            output = root / "artifacts/report.json"
            outside = root / "outside.swift"
            original = b"preserve unrelated source\n"
            outside.write_bytes(original)
            (root / "scripts").mkdir()
            (root / "scripts/verification-config.json").write_text('{"defaultDeveloperDirectory":"/Xcode"}')
            libraries = root / "External/objective-git/External"
            libraries.mkdir(parents=True)
            for name in ("libgit2.a", "libssh2.a", "libcrypto.a", ".libgit2-build.stamp"):
                (libraries / name).write_text("dependency")
            def snapshot(_, destination):
                (destination / "Classes/git").mkdir(parents=True)
                (destination / "Classes/git/IndexSnapshot.swift").symlink_to(outside)
                (destination / "Classes/PBChangedFile.h").write_text("header")
            observed = []
            def build(*args, **kwargs):
                observed.append(outside.read_bytes())
                return 0
            lease = mock.MagicMock()
            lease.__enter__.return_value.environment.return_value = {}
            with mock.patch.dict(self.module.os.environ, {}, clear=True), \
                    mock.patch.object(self.module.session, "cache_paths", return_value={"toolchain": "fixture"}), \
                    mock.patch.object(self.module, "environment_fingerprint", return_value={}), \
                    mock.patch.object(self.module.session, "inputs", return_value={}), \
                    mock.patch.object(self.module.session, "Leases", return_value=lease), \
                    mock.patch.object(self.module, "snapshot_checkout", side_effect=snapshot), \
                    mock.patch.object(self.module.session, "supervise", side_effect=build), \
                    mock.patch.object(self.module, "cache_hits", return_value=1), \
                    mock.patch.object(self.module.compilation_cache, "policy", return_value={"context": {}}), \
                    mock.patch.object(self.module.compilation_cache, "qualify", return_value={"passed": True}):
                status = self.module.compare_cache(root, output, 5)
            import json
            report = json.loads(output.read_text())
            self.assertTrue(all(value == original for value in observed), "An edit probe wrote outside its owned snapshot")
            self.assertEqual(outside.read_bytes(), original)
            self.assertEqual(status, 1)
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["category"], "build-failed")
            self.assertIn("owned source snapshot", report["failures"][0])


if __name__ == "__main__":
    unittest.main()
