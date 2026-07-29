from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from support import load_script


checker = load_script("check_forgekit_coverage.py")


def subprocess_result(output: str):
    return checker.subprocess.CompletedProcess(
        args=[],
        returncode=0,
        stdout=output,
        stderr="",
    )


def coverage_item(path: pathlib.Path, covered: int, executable: int) -> dict[str, object]:
    return {
        "filename": str(path),
        "summary": {
            "lines": {
                "covered": covered,
                "count": executable,
                "percent": covered / executable * 100,
            }
        },
    }


def run_git(root: pathlib.Path, *arguments: str) -> None:
    subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )


def commit_all(root: pathlib.Path, message: str) -> None:
    run_git(root, "add", ".")
    run_git(
        root,
        "-c",
        "user.name=GitX Tests",
        "-c",
        "user.email=gitx-tests@example.invalid",
        "commit",
        "-q",
        "-m",
        message,
    )


def write_policy(
    path: pathlib.Path,
    *,
    aggregate: float,
    file_floor: float,
) -> checker.ForgeCoveragePolicy:
    policy = checker.ForgeCoveragePolicy(
        "ForgeKit handwritten sources",
        aggregate,
        {"ForgeKit/Sources/ForgeKit/Identity.swift": file_floor},
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(checker.policy_payload(policy), indent=2) + "\n")
    return policy


class ForgeKitCoverageTests(unittest.TestCase):
    def test_combined_export_uses_both_swiftpm_test_products(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory)
            profile = scratch / "out/Products/Debug/codecov/default.profdata"
            profile.parent.mkdir(parents=True)
            profile.write_bytes(b"profile")
            products = []
            for name in checker.TEST_PRODUCTS:
                product = (
                    scratch
                    / "out/Products/Debug"
                    / f"{name}.xctest/Contents/MacOS"
                    / name
                )
                product.parent.mkdir(parents=True)
                product.write_bytes(b"binary")
                products.append(product)
            payload = {"data": [{"files": []}]}
            completed = subprocess_result(json.dumps(payload))

            with mock.patch.object(checker.subprocess, "run", return_value=completed) as run:
                report, raw_report = checker.export_swiftpm_coverage(scratch)

        self.assertEqual(report, payload)
        self.assertEqual(raw_report, json.dumps(payload))
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["xcrun", "llvm-cov", "export", str(products[0])])
        self.assertEqual(command[4:6], ["-object", str(products[1])])
        self.assertIn(f"-instr-profile={profile}", command)

    def test_combined_export_fails_closed_when_adapter_product_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scratch = pathlib.Path(directory)
            profile = scratch / "out/Products/Debug/codecov/default.profdata"
            profile.parent.mkdir(parents=True)
            profile.write_bytes(b"profile")
            core = (
                scratch
                / "out/Products/Debug/ForgeKitTests.xctest/Contents/MacOS/ForgeKitTests"
            )
            core.parent.mkdir(parents=True)
            core.write_bytes(b"binary")

            with self.assertRaisesRegex(ValueError, "GitHubForgeAdapterTests"):
                checker.swiftpm_coverage_artifacts(scratch)

    def test_extracts_both_targets_and_exactly_excludes_generated_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            forge = root / "ForgeKit" / "Sources" / "ForgeKit" / "Identity.swift"
            adapter = (
                root
                / "ForgeKit"
                / "Sources"
                / "GitHubForgeAdapter"
                / "Client.swift"
            )
            generated = adapter.parent / "Generated" / "RepositoryQuery.graphql.swift"
            generated_sibling = adapter.parent / "GeneratedSupport" / "Mapper.swift"
            test = root / "ForgeKit" / "Tests" / "ForgeKitTests" / "IdentityTests.swift"
            for path in (forge, adapter, generated, generated_sibling, test):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("struct Example {}\n")
            report = {
                "data": [{
                    "files": [
                        coverage_item(forge, 19, 20),
                        coverage_item(adapter, 20, 20),
                        coverage_item(generated, 0, 1_000),
                        coverage_item(generated_sibling, 20, 20),
                        coverage_item(test, 100, 100),
                    ]
                }]
            }

            aggregate, files = checker.extract_coverage(report, root)

        self.assertEqual(aggregate, 59 / 60)
        self.assertEqual(
            files,
            {
                "ForgeKit/Sources/ForgeKit/Identity.swift": 0.95,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift": 1.0,
                "ForgeKit/Sources/GitHubForgeAdapter/GeneratedSupport/Mapper.swift": 1.0,
            },
        )

    def test_missing_handwritten_source_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "ForgeKit" / "Sources" / "ForgeKit" / "Identity.swift"
            missing = source.with_name("Destination.swift")
            source.parent.mkdir(parents=True)
            source.write_text("struct Identity {}\n")
            missing.write_text("struct Destination {}\n")
            report = {"data": [{"files": [coverage_item(source, 10, 10)]}]}

            with self.assertRaisesRegex(ValueError, "Destination.swift"):
                checker.extract_coverage(report, root)

    def test_aggregate_and_each_file_must_reach_ninety_five_percent(self) -> None:
        policy = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.95,
            {
                "ForgeKit/Sources/ForgeKit/Identity.swift": 0.95,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift": 0.95,
            },
        )

        failures = checker.evaluate_coverage(
            policy,
            target_coverage=0.96,
            file_coverage={
                "ForgeKit/Sources/ForgeKit/Identity.swift": 1.0,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift": 0.94,
            },
        )

        self.assertEqual(len(failures), 1)
        self.assertIn("Client.swift", failures[0])

    def test_new_handwritten_file_requires_a_ratchet_entry(self) -> None:
        policy = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.95,
            {"ForgeKit/Sources/ForgeKit/Identity.swift": 0.95},
        )

        failures = checker.evaluate_coverage(
            policy,
            target_coverage=1.0,
            file_coverage={
                "ForgeKit/Sources/ForgeKit/Identity.swift": 1.0,
                "ForgeKit/Sources/ForgeKit/Destination.swift": 1.0,
            },
        )

        self.assertEqual(
            failures,
            ["Coverage policy is missing ForgeKit/Sources/ForgeKit/Destination.swift"],
        )

    def test_ratchet_adds_new_files_without_lowering_or_dropping_floors(self) -> None:
        policy = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.96,
            {"ForgeKit/Sources/ForgeKit/Identity.swift": 0.98},
        )

        ratcheted = checker.ratchet_policy(
            policy,
            target_coverage=0.97,
            file_coverage={
                "ForgeKit/Sources/ForgeKit/Identity.swift": 0.97,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift": 0.96559,
            },
        )

        self.assertEqual(ratcheted.minimum_line_coverage, 0.97)
        self.assertEqual(ratcheted.files["ForgeKit/Sources/ForgeKit/Identity.swift"], 0.98)
        self.assertEqual(
            ratcheted.files["ForgeKit/Sources/GitHubForgeAdapter/Client.swift"],
            0.9655,
        )

    def test_ancestor_ratchet_rejects_lowering_ninety_eight_to_ninety_seven(self) -> None:
        path = "ForgeKit/Sources/ForgeKit/Identity.swift"
        ancestor = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.98,
            {path: 0.98},
        )
        current = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.97,
            {path: 0.97},
        )

        failures = checker.ancestor_floor_failures(
            current,
            [ancestor],
            applicable_files={path},
        )

        self.assertEqual(len(failures), 2)
        self.assertTrue(any("aggregate floor" in failure for failure in failures))
        self.assertTrue(any(path in failure for failure in failures))

    def test_ancestor_ratchet_uses_maximum_across_commits_and_only_current_sources(self) -> None:
        current_path = "ForgeKit/Sources/ForgeKit/Identity.swift"
        deleted_path = "ForgeKit/Sources/ForgeKit/Deleted.swift"
        ancestors = [
            checker.ForgeCoveragePolicy(
                "ForgeKit handwritten sources",
                0.98,
                {current_path: 0.99, deleted_path: 1.0},
            ),
            checker.ForgeCoveragePolicy(
                "ForgeKit handwritten sources",
                0.99,
                {current_path: 0.97, deleted_path: 0.98},
            ),
            checker.ForgeCoveragePolicy(
                "Renamed display label",
                0.985,
                {current_path: 0.985},
            ),
        ]
        current = checker.ForgeCoveragePolicy(
            "ForgeKit handwritten sources",
            0.985,
            {current_path: 0.985},
        )

        failures = checker.ancestor_floor_failures(
            current,
            ancestors,
            applicable_files={current_path},
        )

        self.assertEqual(len(failures), 2)
        self.assertTrue(any("99.00%" in failure for failure in failures))
        self.assertFalse(any(deleted_path in failure for failure in failures))

    def test_initial_untracked_policy_has_no_ancestor_floor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            run_git(root, "init", "-q")
            (root / "README.md").write_text("fixture\n")
            commit_all(root, "initial")
            policy_path = root / "scripts/forgekit-coverage-baseline.json"
            write_policy(policy_path, aggregate=0.98, file_floor=0.98)

            policies = checker.checked_in_ancestor_policies(root, policy_path)

        self.assertEqual(policies, [])

    def test_history_ratchet_finds_maximum_after_multi_commit_introduction(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            run_git(root, "init", "-q")
            (root / "README.md").write_text("merge base without policy\n")
            commit_all(root, "initial")
            policy_path = root / "scripts/forgekit-coverage-baseline.json"
            write_policy(policy_path, aggregate=0.98, file_floor=0.98)
            commit_all(root, "introduce policy")
            write_policy(policy_path, aggregate=0.99, file_floor=0.995)
            commit_all(root, "ratchet policy")
            (root / "README.md").write_text("unrelated later commit\n")
            commit_all(root, "unrelated")
            current = write_policy(policy_path, aggregate=0.985, file_floor=0.99)

            policies = checker.checked_in_ancestor_policies(root, policy_path)
            failures = checker.ancestor_floor_failures(
                current,
                policies,
                applicable_files={"ForgeKit/Sources/ForgeKit/Identity.swift"},
            )

        self.assertEqual(len(policies), 2)
        self.assertEqual(len(failures), 2)
        self.assertTrue(any("99.00%" in failure for failure in failures))
        self.assertTrue(any("99.50%" in failure for failure in failures))

    def test_history_ratchet_fails_closed_for_invalid_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            run_git(root, "init", "-q")
            policy_path = root / "scripts/forgekit-coverage-baseline.json"
            write_policy(policy_path, aggregate=0.98, file_floor=0.98)
            commit_all(root, "introduce policy")

            with self.assertRaisesRegex(ValueError, "Could not inspect"):
                checker.checked_in_ancestor_policies(
                    root,
                    policy_path,
                    revision="refs/heads/missing",
                )

    def test_history_ratchet_fails_closed_for_shallow_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            policy_path = root / "scripts/forgekit-coverage-baseline.json"
            with mock.patch.object(
                checker,
                "run_git",
                side_effect=["true\n", "true\n"],
            ):
                with self.assertRaisesRegex(ValueError, "shallow Git checkout"):
                    checker.checked_in_ancestor_policies(root, policy_path)

    def test_history_ratchet_fails_closed_for_malformed_ancestor_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            run_git(root, "init", "-q")
            policy_path = root / "scripts/forgekit-coverage-baseline.json"
            policy_path.parent.mkdir(parents=True)
            policy_path.write_text("{not-json}\n")
            commit_all(root, "malformed policy")
            write_policy(policy_path, aggregate=0.98, file_floor=0.98)

            with self.assertRaisesRegex(ValueError, "Malformed ancestor"):
                checker.checked_in_ancestor_policies(root, policy_path)

    def test_policy_cannot_lower_or_expand_the_exact_exclusion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            policy_path = pathlib.Path(directory) / "coverage.json"
            policy_path.write_text(json.dumps({
                "version": 1,
                "target": "ForgeKit handwritten sources",
                "minimumLineCoverage": 0.94,
                "files": {},
            }))
            with self.assertRaisesRegex(ValueError, "aggregate floor"):
                checker.load_policy(policy_path)

            policy_path.write_text(json.dumps({
                "version": 1,
                "target": "ForgeKit handwritten sources",
                "minimumLineCoverage": 0.95,
                "files": {
                    "ForgeKit/Sources/GitHubForgeAdapter/Generated/API.swift": 1.0,
                },
            }))
            with self.assertRaisesRegex(ValueError, "non-handwritten"):
                checker.load_policy(policy_path)

            policy_path.write_text(json.dumps({
                "version": 1,
                "target": "ForgeKit handwritten sources",
                "minimumLineCoverage": float("nan"),
                "files": {},
            }))
            with self.assertRaisesRegex(ValueError, "finite number"):
                checker.load_policy(policy_path)


if __name__ == "__main__":
    unittest.main()
