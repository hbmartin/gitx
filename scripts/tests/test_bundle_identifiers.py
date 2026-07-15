from __future__ import annotations

import pathlib
import plistlib
import tempfile
import unittest

from support import ROOT, load_script


class BundleIdentifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_bundle_identifiers.py")

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.app = pathlib.Path(self.temporary_directory.name) / "GitX.app"
        self.write_bundle(self.app, "net.phere.GitX")

    def write_bundle(self, bundle: pathlib.Path, identifier: str | None) -> None:
        if bundle.suffix == ".framework":
            plist_path = bundle / "Resources" / "Info.plist"
        else:
            plist_path = bundle / "Contents" / "Info.plist"
        plist_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {} if identifier is None else {"CFBundleIdentifier": identifier}
        with plist_path.open("wb") as plist_file:
            plistlib.dump(payload, plist_file)

    def inspect(self):
        return self.module.inspect_bundle_identifiers(self.app)

    def failures(self) -> list[str]:
        return self.module.evaluate_bundle_identifiers(self.inspect())

    def add_distinct_embedded_bundles(self) -> None:
        frameworks = self.app / "Contents" / "Frameworks"
        self.write_bundle(
            frameworks / "ObjectiveGit.framework",
            "org.libgit2.ObjectiveGit",
        )
        sparkle = frameworks / "Sparkle.framework"
        self.write_bundle(sparkle, "org.sparkle-project.Sparkle")
        self.write_bundle(
            sparkle / "Versions" / "B" / "Updater.app",
            "org.sparkle-project.Sparkle.Updater",
        )
        self.write_bundle(
            sparkle / "Versions" / "B" / "XPCServices" / "Downloader.xpc",
            "org.sparkle-project.DownloaderService",
        )

    def test_accepts_distinct_root_and_embedded_bundle_identifiers(self) -> None:
        self.add_distinct_embedded_bundles()

        self.assertEqual(self.failures(), [])

    def test_rejects_embedded_bundle_reusing_gitx_identifier(self) -> None:
        self.write_bundle(
            self.app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "Updater.app",
            "net.phere.GitX",
        )

        failures = self.failures()

        self.assertTrue(any("reuses the root identifier" in failure for failure in failures))
        self.assertTrue(any("Duplicate bundle identifier" in failure for failure in failures))

    def test_rejects_duplicate_identifiers_between_embedded_bundles(self) -> None:
        frameworks = self.app / "Contents" / "Frameworks"
        self.write_bundle(frameworks / "First.framework", "org.example.Duplicate")
        self.write_bundle(frameworks / "Second.framework", "org.example.Duplicate")

        self.assertTrue(
            any(
                "Duplicate bundle identifier org.example.Duplicate" in failure
                for failure in self.failures()
            )
        )

    def test_rejects_empty_embedded_identifier(self) -> None:
        self.write_bundle(
            self.app / "Contents" / "Frameworks" / "Missing.framework",
            None,
        )

        self.assertTrue(
            any("CFBundleIdentifier is missing or empty" in failure for failure in self.failures())
        )

    def test_rejects_wrong_root_identifier(self) -> None:
        self.write_bundle(self.app, "org.example.NotGitX")
        self.write_bundle(
            self.app / "Contents" / "Frameworks" / "Dependency.framework",
            "org.example.Dependency",
        )

        self.assertTrue(
            any("Root application identifier" in failure for failure in self.failures())
        )

    def test_archive_workflow_uses_verifier_without_global_identifier_override(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "BuildPR.yml").read_text()

        self.assertNotIn("PRODUCT_BUNDLE_IDENTIFIER=", workflow)
        self.assertIn(
            "scripts/check_bundle_identifiers.py "
            "GitX.xcarchive/Products/Applications/GitX.app",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
