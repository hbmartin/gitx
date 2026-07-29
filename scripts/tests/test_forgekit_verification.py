from __future__ import annotations

import unittest

from support import ROOT


class ForgeKitVerificationIntegrationTests(unittest.TestCase):
    def test_static_verifier_runs_all_forgekit_policy_checks(self) -> None:
        verifier = (ROOT / "scripts" / "verify_static.sh").read_text()

        for script in (
            "check_forgekit_boundary.py",
            "check_forgekit_exports.py",
            "check_forge_codegen_drift.py",
            "check_swift_concurrency_escapes.py",
        ):
            self.assertIn(f"python3 scripts/{script}", verifier)

    def test_generated_graphql_is_exactly_excluded_from_source_tools(self) -> None:
        verifier = (ROOT / "scripts" / "verify_static.sh").read_text()
        swiftlint = (ROOT / ".swiftlint.yml").read_text()
        generated_root = "ForgeKit/Sources/GitHubForgeAdapter/Generated"

        self.assertIn(f"{generated_root}/*.swift)", verifier)
        self.assertIn(f"- {generated_root}", swiftlint)
        self.assertIn("- ForgeKit", swiftlint)


if __name__ == "__main__":
    unittest.main()
