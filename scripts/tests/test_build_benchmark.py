from __future__ import annotations

import unittest
import pathlib
import subprocess
import tempfile

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


if __name__ == "__main__":
    unittest.main()
