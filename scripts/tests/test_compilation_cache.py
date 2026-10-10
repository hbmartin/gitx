from __future__ import annotations

import unittest
from support import load_script


class CompilationCacheTests(unittest.TestCase):
    def policy(self, mode="auto", toolchain="Xcode 27.0\nBuild version 27A266a", action="build", validated=()):
        compilation_cache = load_script("compilation_cache.py")
        return compilation_cache.policy(mode, toolchain, "arm64", "Debug", "plain", action,
                                        {"compilationCache": {"validated": list(validated)}})

    def test_unknown_toolchain_is_off_until_validated(self):
        result = self.policy()
        self.assertFalse(result["enabled"])
        self.assertEqual(result["reason"], "not-validated")

    def test_explicit_on_and_off_and_unsupported_versions(self):
        self.assertTrue(self.policy("on")["enabled"])
        self.assertFalse(self.policy("off")["enabled"])
        with self.assertRaises(ValueError):
            self.policy("on", "Xcode 25.0\nBuild version 25A1")
        for value in ("unknown", "", "yes"):
            with self.assertRaises(ValueError):
                self.policy(value)

    def test_validated_context_is_exact_and_package_tests_are_not_applicable(self):
        context = {"xcodeBuild": "27A266a", "architecture": "arm64", "configuration": "Debug", "instrumentation": "plain", "action": "build"}
        self.assertTrue(self.policy(validated=[context])["enabled"])
        self.assertFalse(self.policy(action="analyze", validated=[context])["enabled"])
        self.assertFalse(self.policy(toolchain="Xcode 27.1\nBuild version 27B1", validated=[context])["enabled"])
        result = self.policy("on", action="test:core")
        self.assertFalse(result["enabled"])
        self.assertEqual(result["reason"], "not-applicable-package")

    def test_qualification_requires_hits_five_samples_and_no_regressions(self):
        compilation_cache = load_script("compilation_cache.py")
        off = [{"cold": 100, "warm": 10} for _ in range(5)]
        on = [{"cold": 80, "warm": 10} for _ in range(5)]
        self.assertTrue(compilation_cache.qualify(off, on, 1)["passed"])
        self.assertFalse(compilation_cache.qualify(off, on, 0)["passed"])
        self.assertFalse(compilation_cache.qualify(off[:4], on[:4], 1)["passed"])
        self.assertFalse(compilation_cache.qualify(off, [{"cold": 80, "warm": 11} for _ in range(5)], 1)["passed"])
        self.assertFalse(compilation_cache.qualify(off, [{"cold": 99, "warm": 10} for _ in range(5)], 1)["passed"])

    def test_qualification_preserves_the_existing_absolute_ceilings(self):
        compilation_cache = load_script("compilation_cache.py")
        self.assertFalse(compilation_cache.qualify(
            [{"cold": 160, "warm": 30} for _ in range(5)],
            [{"cold": 120, "warm": 25} for _ in range(5)], 5)["passed"])

    def test_invalid_measurements_cannot_qualify(self):
        compilation_cache = load_script("compilation_cache.py")
        valid = [{"cold": 100, "warm": 10} for _ in range(5)]
        for value in (float("nan"), float("inf"), -1, 0, True):
            with self.subTest(value=value):
                self.assertFalse(compilation_cache.qualify(valid, [{"cold": value, "warm": 10}] * 5, 1)["passed"])


if __name__ == "__main__":
    unittest.main()
