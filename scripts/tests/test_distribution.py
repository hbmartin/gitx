from __future__ import annotations

import pathlib
import tempfile
import unittest

from distribution_fixture import DistributionFixture


class DistributionTests(unittest.TestCase):
    def test_release_validates_original_and_both_packaged_apps(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.release()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            validations = [command[-1] for command in fixture.commands if command[:3] == ["xcrun", "stapler", "validate"]]
            self.assertEqual(len(validations), 3)
            self.assertIn("/zip/", validations[1])
            self.assertIn("/mounted-dmg/", validations[2])
            for suffix in ("zip", "dmg", "sha256"):
                self.assertTrue((fixture.output / f"HalfDark-arm64.{suffix}").exists())

    def test_unverified_app_never_reaches_packaging(self):
        for failure in ("signature", "ticket", "gatekeeper"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(pathlib.Path(directory))
                result = fixture.release(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(command[:2] == ["hdiutil", "create"] for command in fixture.commands))
                self.assertFalse((fixture.output / "HalfDark-arm64.sha256").exists())

    def test_failed_mounted_payload_validation_detaches_without_publishing_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DistributionFixture(pathlib.Path(directory))
            result = fixture.release("mounted")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(any(command[:2] == ["hdiutil", "detach"] for command in fixture.commands))
            self.assertFalse((fixture.output / "HalfDark-arm64.sha256").exists())


if __name__ == "__main__":
    unittest.main()
